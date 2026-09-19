import Darwin
import Foundation
import Synchronization
import SwitcherContracts

// 引擎计数（铁律 4：所有数字进这里，Stats 行只从这里组装）。
// 热路径（渲染线程、GPU 完成线程）只做原子加 / 原子 max；组装 Stats 在普通线程，允许分配。

/// 引擎的原子计数。读到的是各字段的非事务快照。
public final class EngineCounters: @unchecked Sendable {
    let ticksDispatchedValue = Atomic<UInt64>(0)
    let ticksSkippedValue = Atomic<UInt64>(0)
    let renderSkippedValue = Atomic<UInt64>(0)
    let framesSubmittedValue = Atomic<UInt64>(0)
    let framesCompletedValue = Atomic<UInt64>(0)
    let framesDispatchedValue = Atomic<UInt64>(0)
    let renderNsSumValue = Atomic<UInt64>(0)
    let renderCountValue = Atomic<UInt64>(0)
    let dispatchJitterMaxNsValue = Atomic<Int64>(0)
    let snapshotWaitsValue = Atomic<UInt64>(0)
    let snapshotStaleValue = Atomic<UInt64>(0)
    let slowConsumeCallsValue = Atomic<UInt64>(0)
    let lastTickValue = Atomic<Int64>(Int64.min)
    /// 每路 L1（提案 005）：累计和（host tick）、样本数、窗口最大值（host tick，读后清零）；下标 = 输入编号，0 不用。
    let inputCapacity: Int
    let latencySumValue: UnsafeMutablePointer<Atomic<UInt64>>
    let latencyCountValue: UnsafeMutablePointer<Atomic<UInt64>>
    let latencyMaxValue: UnsafeMutablePointer<Atomic<Int64>>

    /// 时钟派发（调了渲染）的拍数。
    public var ticksDispatched: UInt64 { ticksDispatchedValue.load(ordering: .acquiring) }
    /// 时钟跳过的拍数（上一拍返回时已到期）。
    public var ticksSkipped: UInt64 { ticksSkippedValue.load(ordering: .acquiring) }
    /// 渲染器返回 .skipped 的拍数。
    public var renderSkipped: UInt64 { renderSkippedValue.load(ordering: .acquiring) }
    /// V2 missed_render = 时钟跳拍 + 渲染器 skipped。
    public var missedRender: UInt64 { ticksSkipped + renderSkipped }
    /// 已提交给 GPU 的帧数。
    public var framesSubmitted: UInt64 { framesSubmittedValue.load(ordering: .acquiring) }
    /// 完成回调收到的帧数（V5 的口径）。
    public var framesCompleted: UInt64 { framesCompletedValue.load(ordering: .acquiring) }
    /// 派发给消费者的帧数 × 消费者数。
    public var framesDispatched: UInt64 { framesDispatchedValue.load(ordering: .acquiring) }
    /// 渲染线程等状态机快照的次数（等到了）。
    public var snapshotWaits: UInt64 { snapshotWaitsValue.load(ordering: .acquiring) }
    /// 等超时、用了上一拍快照的次数。
    public var snapshotStale: UInt64 { snapshotStaleValue.load(ordering: .acquiring) }
    /// consume 调用超过 1 ms 的次数（消费者违反"立即返回"的诊断）。
    public var slowConsumeCalls: UInt64 { slowConsumeCallsValue.load(ordering: .acquiring) }
    /// 最近派发的拍。
    public var lastTick: Tick? {
        let v = lastTickValue.load(ordering: .acquiring)
        return v == Int64.min ? nil : Tick(v)
    }
    /// 自启动以来的平均 render_ms（拍点 → GPU 完成）。
    public var averageRenderMs: Double {
        let n = renderCountValue.load(ordering: .acquiring)
        guard n > 0 else { return 0 }
        return Double(renderNsSumValue.load(ordering: .acquiring)) / Double(n) / 1e6
    }

    /// 某路自启动以来的 L1 累计：和（host tick）与样本数。
    public func latencyTotals(forInput number: Int) -> (sum: HostDuration, count: UInt64) {
        guard number >= 0 && number < inputCapacity else { return (.zero, 0) }
        return (HostDuration(ticks: Int64(clamping: (latencySumValue + number).pointee.load(ordering: .acquiring))),
                (latencyCountValue + number).pointee.load(ordering: .acquiring))
    }

    /// 某路 L1 的窗口最大值，读后清零。
    public func takeLatencyMax(forInput number: Int) -> HostDuration {
        guard number >= 0 && number < inputCapacity else { return .zero }
        return HostDuration(ticks: (latencyMaxValue + number).pointee.exchange(0, ordering: .acquiringAndReleasing))
    }

    /// GPU 完成线程：记一个 L1 样本（host tick）。
    @inline(__always)
    func addLatency(input: Int, ticks: Int64) {
        (latencySumValue + input).pointee.add(UInt64(max(ticks, 0)), ordering: .relaxed)
        (latencyCountValue + input).pointee.add(1, ordering: .relaxed)
        _ = (latencyMaxValue + input).pointee.max(ticks, ordering: .relaxed)
    }

    /// - Parameter maxInputs: 最大输入编号（每路 L1 计数按它预分配）。
    public init(maxInputs: Int = 16) {
        inputCapacity = max(maxInputs, 0) + 1
        latencySumValue = .allocate(capacity: inputCapacity)
        latencyCountValue = .allocate(capacity: inputCapacity)
        latencyMaxValue = .allocate(capacity: inputCapacity)
        var i = 0
        while i < inputCapacity {
            (latencySumValue + i).initialize(to: Atomic(0))
            (latencyCountValue + i).initialize(to: Atomic(0))
            (latencyMaxValue + i).initialize(to: Atomic(0))
            i += 1
        }
    }

    deinit {
        latencySumValue.deinitialize(count: inputCapacity); latencySumValue.deallocate()
        latencyCountValue.deinitialize(count: inputCapacity); latencyCountValue.deallocate()
        latencyMaxValue.deinitialize(count: inputCapacity); latencyMaxValue.deallocate()
    }
}

/// 进程级指标（RSS、CPU）。普通线程调。
enum ProcessMetrics {
    /// 物理内存占用（MB），task_vm_info.phys_footprint。
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 进程累计 CPU 时间（秒，用户 + 系统，所有线程）。
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}

/// 把计数组装成 stats.jsonl 的一行。窗口 = 上一次 `makeStats` 到这一次；第一次从启动算。普通线程。
final class StatsAssembler: @unchecked Sendable {
    private let counters: EngineCounters
    private var lastHost: HostTime
    private var lastCPU: Double
    private var lastRenderNs: UInt64 = 0
    private var lastRenderCount: UInt64 = 0
    private var lastPushed: [Int: UInt64] = [:]
    private var lastLatencySum: [Int: Int64] = [:]
    private var lastLatencyCount: [Int: UInt64] = [:]

    init(counters: EngineCounters, startedAt: HostTime) {
        self.counters = counters
        lastHost = startedAt
        lastCPU = ProcessMetrics.cpuSeconds()
    }

    func make(now: HostTime, wallClock: Date, jitter: JitterRecorder, inputs: [(number: Int, stats: FrameSlotStats)],
              encoder: [Stats.EncoderEntry], audio: Stats.AudioCounters, gpuPct: Double) -> Stats {
        let windowSeconds = max((now - lastHost).seconds, 1e-6)
        let renderNs = counters.renderNsSumValue.load(ordering: .acquiring)
        let renderCount = counters.renderCountValue.load(ordering: .acquiring)
        let dn = renderNs &- lastRenderNs, dc = renderCount &- lastRenderCount
        let renderMs = dc > 0 ? Double(dn) / Double(dc) / 1e6 : 0
        lastRenderNs = renderNs
        lastRenderCount = renderCount
        var perInput: [Int: Stats.PerInput] = [:]
        for (number, s) in inputs {
            let prev = lastPushed[number] ?? 0
            lastPushed[number] = s.pushed
            // L1（提案 005）：窗口内新帧的平均 / 最大延迟；没有样本写 0
            let totals = counters.latencyTotals(forInput: number)
            let dSum = totals.sum.ticks &- (lastLatencySum[number] ?? 0)
            let dCount = totals.count &- (lastLatencyCount[number] ?? 0)
            lastLatencySum[number] = totals.sum.ticks
            lastLatencyCount[number] = totals.count
            let latencyMs = dCount > 0 ? HostDuration(ticks: dSum).milliseconds / Double(dCount) : 0
            let latencyMaxMs = counters.takeLatencyMax(forInput: number).milliseconds
            perInput[number] = Stats.PerInput(fps: Double(s.pushed &- prev) / windowSeconds, dup: s.reused, drop: s.dropped,
                                              latencyMs: latencyMs, latencyMaxMs: dCount > 0 ? latencyMaxMs : 0)
        }
        let cpu = ProcessMetrics.cpuSeconds()
        let cpuPct = max(0, (cpu - lastCPU) / windowSeconds * 100)
        lastCPU = cpu
        lastHost = now
        return Stats(ts: wallClock.timeIntervalSince1970,
                     tick: counters.lastTick ?? .zero,
                     renderMs: renderMs,
                     missedRender: counters.missedRender,
                     jitterMs: jitter.takeWindowMax().milliseconds,
                     perInput: perInput,
                     encoder: encoder,
                     audio: audio,
                     rssMb: ProcessMetrics.residentMB(),
                     cpuPct: cpuPct,
                     gpuPct: gpuPct)   // GPU 占用没有公开 API（powermetrics 要 root），由外部 provider 灌入，否则 0
    }
}
