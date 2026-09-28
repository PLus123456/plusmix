import Darwin
import Synchronization
import SwitcherContracts

// 节目时钟（设计方案 §3.1）。一条专用线程：
//   循环 { 算第 n 拍的理想时刻 → mach_wait_until → 记录唤醒抖动 → 调 handler（渲染线程的工作就在这里做）→ 若下一拍已到期则跳拍 }
// 理想时刻每拍都用 TickClockSpec.time(of:) 一次乘除算出（t0 + ⌊n × T⌋），不累加，所以不累积误差。
//
// 线程属性（探针数据见 reports/w1-core.md）：QoS user-interactive + THREAD_TIME_CONSTRAINT_POLICY。
// 本机 macOS 26 上非实时线程的 mach_wait_until 会被内核定时器合并（kern.timer.coalescing_enabled=1，
// latency tier 0 也有 1 ms leeway）：普通 user-interactive 线程 p99 3.7–7.2 ms，连"必须"档 4 ms 都过不了；
// 挂实时策略后 p99 ≈ 30 µs，且每拍忙 30 ms 远超申报 computation 也没被降级。所以默认开实时策略，
// 设置失败时退回 QoS（isRealtime = false，进报告）。

/// 时钟每拍的回调对象（引擎实现）。在时钟线程（= 渲染线程）上被调，必须零分配、不进 actor。
public protocol ProgramClockHandler: AnyObject {
    /// 第 tick 拍到期。ideal = 理想拍点，wake = 实际唤醒时刻（≥ ideal）。返回前这一拍算"未提交"。
    func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime)
    /// 上一拍返回时后面 count 拍已经到期，被跳过（missed_render 口径，V2）；upTo = 最后一个被跳过的拍。
    func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick)
}

/// 时钟线程的选项。
public struct ProgramClockOptions: Sendable {
    /// 挂 time-constraint 实时策略（默认开；为什么见文件头）。
    public var realtime: Bool = true
    /// 申报的每拍计算量，占拍长的比例。
    public var computationFraction: Double = 0.25
    /// 申报的完成期限，占拍长的比例。
    public var constraintFraction: Double = 0.5
    /// 抖动样本环的容量（拍）；65536 拍 @ 60 fps ≈ 18 分钟，之后循环覆盖。
    public var jitterHistory: Int = 65_536
    /// 线程名。
    public var threadName: String = "switcher.program-clock"
    public init() {}
}

/// 唤醒抖动记录：每拍一个样本（实际唤醒 − 理想拍点，纳秒），预分配环；另有窗口最大值给 Stats.jitter_ms。
/// `record` 在时钟线程调（无分配）；其余方法在普通线程调。
public final class JitterRecorder: @unchecked Sendable {
    public let capacity: Int
    /// 样本用原子量存：时钟线程写、统计线程读，避免裸 Int64 的数据竞争。
    private let storage: UnsafeMutablePointer<Atomic<Int64>>
    private let count = Atomic<Int>(0)
    private let windowMaxNs = Atomic<Int64>(0)
    private let allTimeMaxNs = Atomic<Int64>(0)

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = .allocate(capacity: self.capacity)
        for i in 0..<self.capacity { (storage + i).initialize(to: Atomic(0)) }
    }
    deinit {
        for i in 0..<capacity { (storage + i).deinitialize(count: 1) }
        storage.deallocate()
    }

    /// 时钟线程：记一个样本。
    @inline(__always)
    public func record(_ jitter: HostDuration) {
        let ns = jitter.nanoseconds
        let n = count.load(ordering: .relaxed)
        storage[n % capacity].store(ns, ordering: .relaxed)
        count.store(n &+ 1, ordering: .releasing)
        let mag = ns < 0 ? -ns : ns
        _ = windowMaxNs.max(mag, ordering: .relaxed)
        _ = allTimeMaxNs.max(mag, ordering: .relaxed)
    }

    /// 样本总数（含被覆盖的）。
    public var sampleCount: Int { count.load(ordering: .acquiring) }

    /// 取走窗口最大值（|抖动|），并把窗口清零。Stats.jitter_ms 用它。
    public func takeWindowMax() -> HostDuration { HostDuration(nanoseconds: windowMaxNs.exchange(0, ordering: .acquiringAndReleasing)) }
    /// 自启动以来的最大值。
    public var allTimeMax: HostDuration { HostDuration(nanoseconds: allTimeMaxNs.load(ordering: .acquiring)) }

    /// 最近 min(总数, 容量) 个样本（时间顺序）。普通线程，会分配。
    public func samples() -> [HostDuration] {
        let n = count.load(ordering: .acquiring)
        let available = min(n, capacity)
        var out: [HostDuration] = []
        out.reserveCapacity(available)
        let start = n - available
        for i in start..<n { out.append(HostDuration(nanoseconds: storage[i % capacity].load(ordering: .relaxed))) }
        return out
    }

    /// 最近样本的分位数（最近秩法：排序后取第 ⌈p × N⌉ 个）。没有样本为 nil。
    public func percentile(_ p: Double) -> HostDuration? {
        let s = samples().sorted()
        guard !s.isEmpty else { return nil }
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))]
    }
}

/// 节目时钟。`start` 起线程，`stop` 请求停止并等待，`join` 等待有界运行结束。
public final class ProgramClock: @unchecked Sendable {
    public let spec: TickClockSpec
    public let options: ProgramClockOptions
    public let jitter: JitterRecorder
    private let stopRequested = Atomic<Bool>(false)
    private let dispatched = Atomic<UInt64>(0)
    private let skipped = Atomic<UInt64>(0)
    private let lastDispatched = Atomic<Int64>(Int64.min)
    private let realtime = Atomic<Bool>(false)
    private var thread: NativeThread?
    private var handler: (any ProgramClockHandler)?
    private var firstTick = Tick.zero
    private var lastTick: Tick?

    public init(spec: TickClockSpec, options: ProgramClockOptions = ProgramClockOptions()) {
        self.spec = spec
        self.options = options
        jitter = JitterRecorder(capacity: options.jitterHistory)
    }

    /// 第 tick 拍的理想时刻（= spec.time(of:)，一次乘除，不累加）。
    @inline(__always)
    public func deadline(for tick: Tick, timebase: MachTimebase = HostClock.timebase) -> HostTime {
        spec.time(of: tick, timebase: timebase)
    }

    /// 已派发（调过 handler）的拍数。
    public var ticksDispatched: UInt64 { dispatched.load(ordering: .acquiring) }
    /// 跳过的拍数（V2 missed_render 的时钟侧来源）。
    public var ticksSkipped: UInt64 { skipped.load(ordering: .acquiring) }
    /// 最近派发的拍；还没派发过为 nil。
    public var lastDispatchedTick: Tick? {
        let v = lastDispatched.load(ordering: .acquiring)
        return v == Int64.min ? nil : Tick(v)
    }
    /// 实时策略是否生效（start 之后有效）。
    public var isRealtime: Bool { realtime.load(ordering: .acquiring) }
    /// 从内核读回时钟线程（= 渲染线程）的 time-constraint 策略（start 之后有效；线程结束后端口可能已失效，返回 nil）。
    public func readBackTimeConstraint() -> (isDefault: Bool, period: UInt32, computation: UInt32, constraint: UInt32)? {
        thread?.readBackTimeConstraint()
    }
    /// 线程是否在跑。
    public var isRunning: Bool { thread != nil && !stopRequested.load(ordering: .acquiring) }

    /// 实时策略参数：period = 拍长，computation / constraint 按选项比例。
    public var timeConstraint: NativeThreadConfig.TimeConstraint {
        let period = UInt32(clamping: spec.duration(ofTicks: 1).ticks)
        return NativeThreadConfig.TimeConstraint(
            period: period,
            computation: max(1, UInt32(Double(period) * options.computationFraction)),
            constraint: max(1, UInt32(Double(period) * options.constraintFraction)),
            preemptible: true)
    }

    /// 从 firstTick 起跑；lastTick 非 nil 时跑到它（含）为止后线程自行结束（测试用有界运行）。
    public func start(handler: any ProgramClockHandler, firstTick: Tick = .zero, lastTick: Tick? = nil) throws {
        guard thread == nil else { throw NativeThreadError.alreadyStarted }
        self.handler = handler
        self.firstTick = firstTick
        self.lastTick = lastTick
        stopRequested.store(false, ordering: .releasing)
        let config = NativeThreadConfig(name: options.threadName, qos: QOS_CLASS_USER_INTERACTIVE,
                                        timeConstraint: options.realtime ? timeConstraint : nil)
        let t = NativeThread(config: config) { [self] in loop() }
        try t.start()
        realtime.store(t.appliedTimeConstraint, ordering: .releasing)
        thread = t
    }

    /// 请求停止并等待线程退出（最多再等一拍）。
    public func stop() {
        stopRequested.store(true, ordering: .releasing)
        join()
    }

    /// 等线程结束（有界运行到 lastTick，或 stop 之后）。
    public func join() {
        thread?.join()
    }

    // 时钟线程主循环。零分配：只有原子量、整数运算和对 handler 的直接调用。
    private func loop() {
        guard let handler else { return }
        var n = firstTick
        while !stopRequested.load(ordering: .acquiring) {
            if let last = lastTick, n > last { break }
            let ideal = spec.time(of: n)
            // mach_wait_until 在目标已过时立即返回；不会提前醒
            _ = mach_wait_until(ideal.ticks)
            if stopRequested.load(ordering: .acquiring) { break }
            let wake = HostClock.now()
            jitter.record(wake - ideal)
            handler.programClock(self, tick: n, ideal: ideal, wake: wake)
            dispatched.add(1, ordering: .relaxed)
            lastDispatched.store(n.rawValue, ordering: .releasing)
            // 跳拍：handler 返回时已经到期的拍全部跳过（设计方案 §3.1）
            let after = HostClock.now()
            var next = n + 1
            let due = spec.tick(at: after)
            if due >= next {
                var count = Int(due - next) + 1
                if let last = lastTick, due > last { count = Int(last - next) + 1 }   // 有界运行：不算超出终点的
                if count > 0 {
                    skipped.add(UInt64(count), ordering: .relaxed)
                    handler.programClock(self, didSkipTicks: count, upTo: next + (count - 1))
                }
                next = due + 1
            }
            n = next
        }
        self.handler = nil
    }
}
