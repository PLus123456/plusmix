import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs

/// 包一层真帧槽（LockFreeFrameSlot），记下"第 n 拍返回了哪一帧（ingressTime、序号、是不是新帧）"，给 L1 测量用。
///
/// L1（测试标准 §1）= 帧出现在编码器输入的时刻 − 该帧的 ingressTime。引擎每拍对每路调 `latest(forTick:)`（带到达余量）
/// 或 `latest(atOrBefore:)`，这里把返回的帧按拍号记进一个 256 项的环（原子量，渲染线程写、消费者线程读）；
/// `LatencyConsumer` 在 `consume(RenderedFrame)` 里按 `frame.tick` 查表算差。只有"第一次被用到"的帧计入 L1
/// （30 fps 摄像头进 60 fps 节目，同一帧第二次被用是帧率转换，不是内部延迟）。
/// 渲染线程上的额外工作：几次原子写，零分配。
public final class LatencyFrameSlot: FrameSlot, ArrivalPacedFrameSlot, @unchecked Sendable {
    public let inner: LockFreeFrameSlot
    public let timing: ProgramTiming
    static let ringSize = 256
    private let ticks: UnsafeMutablePointer<Atomic<Int64>>
    private let ingress: UnsafeMutablePointer<Atomic<UInt64>>
    private let flags: UnsafeMutablePointer<Atomic<UInt64>>   // 0 = 没帧，1 = 重复上一帧，2 = 新帧
    private var lastSequence: UInt64 = 0
    private var hasLast = false

    public init(inner: LockFreeFrameSlot, timing: ProgramTiming) {
        self.inner = inner
        self.timing = timing
        ticks = .allocate(capacity: Self.ringSize)
        ingress = .allocate(capacity: Self.ringSize)
        flags = .allocate(capacity: Self.ringSize)
        for i in 0..<Self.ringSize {
            (ticks + i).initialize(to: Atomic(Int64.min))
            (ingress + i).initialize(to: Atomic(0))
            (flags + i).initialize(to: Atomic(0))
        }
    }

    deinit {
        ticks.deinitialize(count: Self.ringSize); ticks.deallocate()
        ingress.deinitialize(count: Self.ringSize); ingress.deallocate()
        flags.deinitialize(count: Self.ringSize); flags.deallocate()
    }

    public var capacity: Int { inner.capacity }
    public func push(_ frame: Frame) { inner.push(frame) }
    public var stats: FrameSlotStats { inner.stats }
    public func configurePacing(_ options: PacingOptions) { inner.configurePacing(options) }
    public var pacingStats: PacingStats { inner.pacingStats }

    public func latest(atOrBefore time: HostTime) -> Frame? {
        let f = inner.latest(atOrBefore: time)
        record(tick: timing.tick(at: time), frame: f)
        return f
    }

    public func latest(forTick tickTime: HostTime) -> Frame? {
        let f = inner.latest(forTick: tickTime)
        record(tick: timing.tick(at: tickTime), frame: f)
        return f
    }

    @inline(__always)
    private func record(tick: Tick, frame: Frame?) {
        let i = Int(tick.rawValue & Int64(Self.ringSize - 1))
        var flag: UInt64 = 0
        var ing: UInt64 = 0
        if let frame {
            ing = frame.ingressTime.ticks
            flag = (hasLast && frame.sequence == lastSequence) ? 1 : 2
            lastSequence = frame.sequence
            hasLast = true
        }
        (ingress + i).pointee.store(ing, ordering: .relaxed)
        (flags + i).pointee.store(flag, ordering: .relaxed)
        (ticks + i).pointee.store(tick.rawValue, ordering: .releasing)
    }

    /// 第 tick 拍的记录：nil = 没记过（或已被 256 拍后的覆盖）。
    public func entry(forTick tick: Tick) -> (ingressTime: HostTime, isNew: Bool)? {
        let i = Int(tick.rawValue & Int64(Self.ringSize - 1))
        guard (ticks + i).pointee.load(ordering: .acquiring) == tick.rawValue else { return nil }
        let flag = (flags + i).pointee.load(ordering: .relaxed)
        guard flag != 0 else { return nil }
        return (HostTime(ticks: (ingress + i).pointee.load(ordering: .relaxed)), flag == 2)
    }
}

/// L1 的统计结果。
public struct LatencyStats: Sendable, Hashable {
    public var samples: Int
    public var meanMs: Double
    public var p50Ms: Double
    public var p99Ms: Double
    public var maxMs: Double
    public var minMs: Double
    /// 用到这路但帧槽没帧的拍数。
    public var ticksWithoutFrame: Int
    /// 用到这路且返回重复帧的拍数（帧率转换）。
    public var ticksReused: Int
    /// 进帧槽时刻早于 t0（引擎还没起）的新帧数，不计入样本。
    public var framesBeforeT0: Int

    public func frames(at frameRate: FrameRate) -> (mean: Double, p99: Double, max: Double) {
        let f = frameRate.approximateFramesPerSecond / 1000
        return (meanMs * f, p99Ms * f, maxMs * f)
    }
}

/// PGM 帧的消费者：在 consume 入口打戳（= "编码器入口"），对每路查 LatencyFrameSlot 的记录算 L1。consume 零分配、立即返回。
public final class LatencyConsumer: FrameConsumer, @unchecked Sendable {
    public let consumerName = "l1-probe"
    private let slots: [(number: Int, slot: LatencyFrameSlot)]
    private let samples: [UnsafeMutablePointer<Int64>]
    /// 每路一个：[样本数, 没帧的拍数, 重复帧的拍数]（原子 Int，用裸指针数组避免 Atomic 不可拷贝的问题）
    private let counters: UnsafeMutablePointer<Atomic<Int>>
    private let capacity: Int
    private let framesSeen = Atomic<UInt64>(0)
    private let t0: UInt64
    /// 离群样本（> outlierThreshold）：[输入下标, tick, 延迟 ticks, ingress ticks, 消费时刻 ticks]，最多 64 条
    private let outlierRing: UnsafeMutablePointer<Int64>
    private let outlierCount = Atomic<Int>(0)
    private let outlierThreshold: Int64
    public struct Outlier: Sendable, Hashable {
        public var inputNumber: Int
        public var tick: Tick
        public var latencyMs: Double
        public var ingressTime: HostTime
        public var consumeTime: HostTime
    }

    public init(slots: [(number: Int, slot: LatencyFrameSlot)], capacity: Int = 1 << 17, outlierThreshold: HostDuration = HostDuration(milliseconds: 100)) {
        self.slots = slots
        self.capacity = capacity
        self.outlierThreshold = outlierThreshold.ticks
        t0 = slots.first?.slot.timing.clock.t0.ticks ?? 0
        outlierRing = .allocate(capacity: 64 * 5)
        outlierRing.initialize(repeating: 0, count: 64 * 5)
        samples = slots.map { _ in
            let p = UnsafeMutablePointer<Int64>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
        counters = .allocate(capacity: slots.count * 4)
        for i in 0..<(slots.count * 4) { (counters + i).initialize(to: Atomic(0)) }
    }

    deinit {
        for p in samples { p.deallocate() }
        counters.deinitialize(count: slots.count * 4)
        counters.deallocate()
        outlierRing.deallocate()
    }

    @inline(__always) private func count(_ i: Int) -> UnsafeMutablePointer<Atomic<Int>> { counters + i * 4 }
    @inline(__always) private func noFrame(_ i: Int) -> UnsafeMutablePointer<Atomic<Int>> { counters + i * 4 + 1 }
    @inline(__always) private func reused(_ i: Int) -> UnsafeMutablePointer<Atomic<Int>> { counters + i * 4 + 2 }
    @inline(__always) private func beforeT0(_ i: Int) -> UnsafeMutablePointer<Atomic<Int>> { counters + i * 4 + 3 }

    public func consume(_ frame: RenderedFrame) {
        let now = HostClock.now()
        framesSeen.add(1, ordering: .relaxed)
        var i = 0
        while i < slots.count {
            if let e = slots[i].slot.entry(forTick: frame.tick) {
                if e.isNew, e.ingressTime.ticks < t0 {
                    // 引擎起来之前就进了帧槽的帧：它等的是引擎不是管线，不算 L1
                    beforeT0(i).pointee.add(1, ordering: .relaxed)
                } else if e.isNew {
                    let n = count(i).pointee.load(ordering: .relaxed)
                    let d = (now - e.ingressTime).ticks
                    if n < capacity {
                        samples[i][n] = d
                        count(i).pointee.store(n + 1, ordering: .releasing)
                    }
                    if d > outlierThreshold {
                        let k = outlierCount.load(ordering: .relaxed)
                        if k < 64 {
                            let p = outlierRing + k * 5
                            p[0] = Int64(i); p[1] = frame.tick.rawValue; p[2] = d; p[3] = Int64(bitPattern: e.ingressTime.ticks); p[4] = Int64(bitPattern: now.ticks)
                            outlierCount.store(k + 1, ordering: .releasing)
                        }
                    }
                } else {
                    reused(i).pointee.add(1, ordering: .relaxed)
                }
            } else {
                noFrame(i).pointee.add(1, ordering: .relaxed)
            }
            i += 1
        }
    }

    /// 已消费的 PGM 帧数。
    public var framesConsumed: UInt64 { framesSeen.load(ordering: .relaxed) }

    /// 离群样本列表。
    public var outliers: [Outlier] {
        let k = outlierCount.load(ordering: .acquiring)
        return (0..<k).map { j in
            let p = outlierRing + j * 5
            return Outlier(inputNumber: slots[Int(p[0])].number, tick: Tick(p[1]), latencyMs: HostDuration(ticks: p[2]).milliseconds,
                           ingressTime: HostTime(ticks: UInt64(bitPattern: p[3])), consumeTime: HostTime(ticks: UInt64(bitPattern: p[4])))
        }
    }

    /// 某路的 L1 统计（普通线程；拷贝样本再排序）。
    public func stats(forInput number: Int) -> LatencyStats? {
        guard let i = slots.firstIndex(where: { $0.number == number }) else { return nil }
        let n = count(i).pointee.load(ordering: .acquiring)
        var v = Array(UnsafeBufferPointer(start: samples[i], count: n)).map { HostDuration(ticks: $0).milliseconds }
        v.sort()
        func pct(_ p: Double) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))] }
        return LatencyStats(samples: n, meanMs: v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count), p50Ms: pct(0.5), p99Ms: pct(0.99),
                            maxMs: v.last ?? 0, minMs: v.first ?? 0,
                            ticksWithoutFrame: noFrame(i).pointee.load(ordering: .relaxed), ticksReused: reused(i).pointee.load(ordering: .relaxed),
                            framesBeforeT0: beforeT0(i).pointee.load(ordering: .relaxed))
    }
}
