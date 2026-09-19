import Synchronization
import SwitcherContracts

/// 提案 005 的引擎侧（L1 内部延迟 = 帧交给第一个 FrameConsumer 的那一刻 − 该帧的 `Frame.ingressTime`）。
///
/// 每路一个 256 项的预分配环：渲染线程每拍挑完帧后按 `tick & 255` 记下 (tick, ingressTime, 新帧 / 重复帧)；
/// GPU 完成线程在调第一个消费者之前取 `now`，按 `frame.tick` 查各路的环，新帧就把 now − ingressTime 累进 `EngineCounters`
/// （每路 sum / count / max 三个原子量），`StatsAssembler` 每秒算窗口平均与最大值。同一帧因帧率转换被重复使用的拍不算
/// （序号与上一拍相同），引擎起来（t0）之前进槽的帧不算（它等的是引擎不是管线）。三个原子量数组，渲染线程零分配、无锁；
/// 与 W2-A 的 SwitcherInputsHarness/LatencyFrameSlot 同一算法（那是包外的参考实现，SwitcherEngineTests 抄了一份对照）。
final class InputLatencyRecorder: @unchecked Sendable {
    static let ringSize = 256
    /// 下标 = 输入编号（0 不用）。
    let inputCapacity: Int
    private let ticks: UnsafeMutablePointer<Atomic<Int64>>
    private let ingress: UnsafeMutablePointer<Atomic<UInt64>>
    /// 0 = 没帧，1 = 重复上一拍的帧，2 = 新帧。
    private let flags: UnsafeMutablePointer<Atomic<UInt8>>
    // 渲染线程私有：每路上一拍返回的序号
    private let lastSequence: UnsafeMutablePointer<UInt64>
    private let hasLast: UnsafeMutablePointer<Bool>
    /// 引擎第一拍的时刻；早于它进槽的帧不算 L1。start 时写。
    let t0 = Atomic<UInt64>(0)

    init(inputCapacity: Int) {
        self.inputCapacity = inputCapacity
        let n = inputCapacity * Self.ringSize
        ticks = .allocate(capacity: n)
        ingress = .allocate(capacity: n)
        flags = .allocate(capacity: n)
        var i = 0
        while i < n {
            (ticks + i).initialize(to: Atomic(Int64.min))
            (ingress + i).initialize(to: Atomic(0))
            (flags + i).initialize(to: Atomic(0))
            i += 1
        }
        lastSequence = .allocate(capacity: inputCapacity)
        lastSequence.initialize(repeating: 0, count: inputCapacity)
        hasLast = .allocate(capacity: inputCapacity)
        hasLast.initialize(repeating: false, count: inputCapacity)
    }

    deinit {
        let n = inputCapacity * Self.ringSize
        ticks.deinitialize(count: n); ticks.deallocate()
        ingress.deinitialize(count: n); ingress.deallocate()
        flags.deinitialize(count: n); flags.deallocate()
        lastSequence.deallocate()
        hasLast.deallocate()
    }

    /// 渲染线程：记下第 tick 拍这路用的帧（nil = 这路没帧）。
    @inline(__always)
    func record(input: Int, tick: Tick, frame: Frame?) {
        let i = input * Self.ringSize + Int(tick.rawValue & Int64(Self.ringSize - 1))
        var flag: UInt8 = 0
        var ing: UInt64 = 0
        if let frame {
            ing = frame.ingressTime.ticks
            flag = (hasLast[input] && frame.sequence == lastSequence[input]) ? 1 : 2
            lastSequence[input] = frame.sequence
            hasLast[input] = true
        }
        (ingress + i).pointee.store(ing, ordering: .relaxed)
        (flags + i).pointee.store(flag, ordering: .relaxed)
        (ticks + i).pointee.store(tick.rawValue, ordering: .releasing)
    }

    /// GPU 完成线程：第 tick 拍各路的新帧延迟 = now − ingressTime，累进 counters。
    @inline(__always)
    func account(tick: Tick, now: HostTime, into counters: EngineCounters) {
        let slot = Int(tick.rawValue & Int64(Self.ringSize - 1))
        let startTicks = t0.load(ordering: .relaxed)
        var input = 1
        while input < inputCapacity {
            let i = input * Self.ringSize + slot
            if (ticks + i).pointee.load(ordering: .acquiring) == tick.rawValue,
               (flags + i).pointee.load(ordering: .relaxed) == 2 {
                let ing = (ingress + i).pointee.load(ordering: .relaxed)
                if ing >= startTicks {
                    let d = Int64(clamping: now.ticks) - Int64(clamping: ing)
                    counters.addLatency(input: input, ticks: d)
                }
            }
            input += 1
        }
    }
}
