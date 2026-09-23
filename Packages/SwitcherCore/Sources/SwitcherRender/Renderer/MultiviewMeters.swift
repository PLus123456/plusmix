// 多画面电平表的数据通道（W3-B2 交付 2）：`Stats.audio.meters`（提案 004）的峰值以不分配的方式递给渲染线程。
//
// 线程约定：
// - 写端 = 组装方（App / headless）在**非实时线程**调 `setMeters`：每秒 Stats 发布时，或更密（App 可以按 50 ms 的表读数喂，
//   形态照样是 `Stats.AudioCounters.Meters`）。写端把读数换成定长表（最多 64 路输入 + 节目 Master），顺手算峰值保持（1 s），
//   写进自己手里那块缓冲，再用一次原子交换发布。写端之间用锁串行；渲染线程从不拿这把锁。不许在音频实时回调里调（它分配）。
// - 读端 = 渲染线程：每帧开头看一眼有没有新发布的，有就原子交换接手；之后只读自己手里那块。零分配、不等、不锁。
// 三块定长缓冲（写端一块、读端一块、交接一块）：写端与读端各持一块、互不等待，写端连写几次读端只拿最新那次。
// 纯双缓冲做不到"两边都不等"：写端要复用读端刚放下的那块，就得先确认读端读完了。第三块就是省掉这一步的交接位。
//
// 数的口径（峰值保持、过期）都在写端和这里定，画法（刻度、颜色分段）在 CompositorPasses.drawMeter。
// 契约里没有 RMS（`Stats.AudioCounters.InputMeter` 只有 peak_db，总线也只有峰值 / 真峰值 / 响度），这里只画峰值 + 峰值保持；
// 要加 RMS 见 docs/contract-changes/017（本会话写的提案，等批；W3-E2 先占了 016）。
import Foundation
import Synchronization
import SwitcherContracts

/// 电平表的刻度与颜色分段（dBFS）。设计方案 §7 只写了"表：峰值 + 真峰值 + 响度"，没有颜色表；分段点在报告里写明，等用户定。
enum MeterScale {
    /// 表的下端（上端 0 dBFS）。
    static let floorDb: Float = -60
    /// 从这里往上是黄区（EBU R68 的对齐电平 −18 dBFS）。
    static let yellowFromDb: Float = -18
    /// 从这里往上是红区（与 App 调音台 MeterBar 的红线同一处）。
    static let redFromDb: Float = -6

    /// dBFS → 表高的比例（0 = 下端，1 = 0 dBFS），钳到 0–1。
    @inline(__always)
    static func fraction(_ db: Float) -> Float {
        min(max((db - floorDb) / (0 - floorDb), 0), 1)
    }

    static let yellowFrom = fraction(yellowFromDb)
    static let redFrom = fraction(redFromDb)
}

/// 一块定长电平表（渲染线程读的那种）。dB 全是 dBFS；非有限数已换成 Stats 的下限 −120，其余原样（钳在画的时候做）。
/// 只被一条线程碰：写端写它的时候读端碰不到，反之亦然（MultiviewMeterFeed 的交换保证）。
final class MultiviewMeterTable: @unchecked Sendable {
    static let capacity = 64
    /// false = 没有数据（没给表 / 清掉了）→ 多画面退回占位。
    fileprivate(set) var valid = false
    /// 写端喂这份数的时刻（读端据此判过期）。
    fileprivate(set) var fedAt = HostTime.zero
    fileprivate(set) var count = 0
    fileprivate var hasProgram = false
    fileprivate var program = SIMD4<Float>(repeating: -120)
    /// 输入编号（按编号升序）。
    private let numbers: UnsafeMutablePointer<Int32>
    /// (峰值 L, 峰值 R, 保持 L, 保持 R)。
    private let levels: UnsafeMutablePointer<SIMD4<Float>>

    init() {
        numbers = .allocate(capacity: MultiviewMeterTable.capacity)
        numbers.initialize(repeating: 0, count: MultiviewMeterTable.capacity)
        levels = .allocate(capacity: MultiviewMeterTable.capacity)
        levels.initialize(repeating: SIMD4(repeating: -120), count: MultiviewMeterTable.capacity)
    }

    deinit {
        numbers.deallocate()
        levels.deallocate()
    }

    fileprivate func clear() {
        valid = false
        count = 0
        hasProgram = false
    }

    fileprivate func append(number: Int, levels l: SIMD4<Float>) {
        guard count < MultiviewMeterTable.capacity else { return }
        numbers[count] = Int32(truncatingIfNeeded: number)
        levels[count] = l
        count += 1
    }

    /// 输入 n 的读数；表里没有为 nil。线性查找（≤ 64 项），渲染线程每格调一次，零分配。
    @inline(__always)
    func levels(forInput n: Int) -> SIMD4<Float>? {
        guard n > 0 else { return nil }
        let key = Int32(truncatingIfNeeded: n)
        var i = 0
        while i < count {
            if numbers[i] == key { return levels[i] }
            i += 1
        }
        return nil
    }

    /// 节目（Master 总线）的读数，PGM 格用；这次没有 master 总线为 nil。
    @inline(__always)
    var programLevels: SIMD4<Float>? { hasProgram ? program : nil }
}

/// 写端 → 渲染线程的电平表通道（三块定长缓冲）。实时渲染器、离线渲染器各一份。
final class MultiviewMeterFeed: @unchecked Sendable {
    /// 峰值保持多久（设计：1 s）。
    static let holdDuration = HostDuration(seconds: 1)
    /// 多久没喂新数就当没有表（音频停了表不该冻在最后一个值上；headless 1 Hz 喂，留 3 次的余量）。
    static let staleDuration = HostDuration(seconds: 3)

    private let tables = [MultiviewMeterTable(), MultiviewMeterTable(), MultiviewMeterTable()]
    /// 交接位：低两位 = 交接中的那块的下标，dirtyBit = 写端放了新的、读端还没接。
    private let handoff = Atomic<Int>(2)
    private static let dirtyBit = 4
    /// 写端手里那块（只在 writeLock 里碰）。
    private var back = 1
    /// 读端手里那块（只有读端碰：实时路径是渲染线程，离线路径是调用线程）。
    private var front = 0
    private let writeLock = NSLock()
    /// 峰值保持的状态（写端，锁里）：键 = 输入编号，0 = Master。
    private var holds: [Int: Hold] = [:]
    /// 读端接手新表的次数（测试看渲染线程确实在读新数；原子加，零分配）。
    let adoptions = Atomic<Int>(0)

    private struct Hold {
        var db: SIMD2<Float>
        var at: (HostTime, HostTime)
    }

    /// 写端：换成定长表并发布。nil = 清掉（多画面退回占位）。非实时线程；分配、拿锁都在这里。
    func write(_ meters: Stats.AudioCounters.Meters?, at time: HostTime) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let t = tables[back]
        t.clear()
        t.fedAt = time
        if let meters {
            var seen = Set<Int>()
            for n in meters.inputs.keys.sorted() where n > 0 && t.count < MultiviewMeterTable.capacity {
                guard let peak = MultiviewMeterFeed.pair(meters.inputs[n]?.peakDb ?? []) else { continue }
                let hold = updateHold(key: n, peak: peak, at: time)
                t.append(number: n, levels: SIMD4(peak.x, peak.y, hold.x, hold.y))
                seen.insert(n)
            }
            if let master = meters.buses.first(where: { $0.bus == Bus.master.name }), let peak = MultiviewMeterFeed.pair(master.peakDb) {
                let hold = updateHold(key: 0, peak: peak, at: time)
                t.program = SIMD4(peak.x, peak.y, hold.x, hold.y)
                t.hasProgram = true
                seen.insert(0)
            }
            holds = holds.filter { seen.contains($0.key) }   // 这次没出现的路，保持从头算
            t.valid = true
        } else {
            holds.removeAll()
        }
        let old = handoff.exchange(back | MultiviewMeterFeed.dirtyBit, ordering: .acquiringAndReleasing)
        back = old & 3
    }

    /// 读端：有新发布的就接手；返回手里那块。没有数据、或 now 给了且喂数已经超过 3 s → nil（画占位）。
    /// 渲染线程每帧调一次：一次原子读，有新数时再一次原子交换；零分配、不等、不锁。now = nil（离线渲染）不判过期。
    @inline(__always)
    func acquire(now: HostTime?) -> MultiviewMeterTable? {
        if handoff.load(ordering: .relaxed) & MultiviewMeterFeed.dirtyBit != 0 {
            let old = handoff.exchange(front, ordering: .acquiringAndReleasing)
            front = old & 3
            adoptions.wrappingAdd(1, ordering: .relaxed)
        }
        let t = tables[front]
        guard t.valid else { return nil }
        if let now, now - t.fedAt > MultiviewMeterFeed.staleDuration { return nil }
        return t
    }

    /// Stats 的 peak_db 数组 → (L, R)：一个数 = 单声道（两边都是它），空 = 没有这一路；非有限数当 −120。
    private static func pair(_ db: [Double]) -> SIMD2<Float>? {
        guard let first = db.first else { return nil }
        func f(_ v: Double) -> Float { v.isFinite ? Float(v) : Float(Stats.AudioCounters.Meters.floorDb) }
        return SIMD2(f(first), f(db.count >= 2 ? db[1] : first))
    }

    /// 峰值保持（每个声道各算）：新峰值 ≥ 保持值，或保持值定下已满 1 s → 保持值换成新峰值。
    private func updateHold(key: Int, peak: SIMD2<Float>, at time: HostTime) -> SIMD2<Float> {
        var h = holds[key] ?? Hold(db: peak, at: (time, time))
        if peak.x >= h.db.x || time - h.at.0 >= MultiviewMeterFeed.holdDuration { h.db.x = peak.x; h.at.0 = time }
        if peak.y >= h.db.y || time - h.at.1 >= MultiviewMeterFeed.holdDuration { h.db.y = peak.y; h.at.1 = time }
        holds[key] = h
        return h.db
    }
}
