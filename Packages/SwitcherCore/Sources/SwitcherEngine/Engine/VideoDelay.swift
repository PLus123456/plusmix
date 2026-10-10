import Darwin
import Foundation
import Synchronization
import SwitcherContracts

// 视频延后（W1-B4，prompt 105；提案 028 已批）。
//
// 为什么：总线效果（压缩 / 限幅的前瞻）让 Master 的声音比画面晚 L（AU 限幅器起音 1–30 ms、AU 压缩 5.3 ms，一条总线最多 35.3 ms）。
// 扬声器 / 耳机监听没有 PTS，只能让画面也晚 L——用户 2026-10-03 定"视频延后同样的毫秒数"，2026-10-10 定 videoDelay 下音频 PTS 不再前移。
//
// 口径（提案 028）：节目输出时间线 = 采集（拍点）时刻 + L。交给消费者的 RenderedFrame.tickTime = 拍点 + Lₙ（编码 PTS 用它，严格递增）；
// program / preview / multiview 的 pts 不动（仍是拍点 = 画面内容的时刻，tickTime − program.pts = Lₙ）；帧在 tickTime 到期时才派发。
// L 由音频引擎给（Master 当前效果链的实测延迟，`VideoDelayControl`），设定值钳到 [0, maxDelay]。
//
// 线程：
//   GPU 完成线程（RenderSink 回调，`admit`）：算 Lₙ——设定值变了每拍最多改 1/4 拍（35 ms 要 9 拍 ≈ 150 ms），tickTime 严格递增、不丢不重；
//     队列空着（派发线程闲）且这一帧已到期（Lₙ = 0 时总是）：当场派发，与以前同一条路（gate4 不带效果就走这里）；否则入队 + 叫醒派发线程。
//   派发线程（switcher.engine.dispatch，time-constraint 实时，参数同时钟线程）：看队头 → mach_wait_until(到期) → 出队 → 调消费者。
//   两条线程不会同时调消费者：只有完成线程入队，它也只在"入队数 = 派发线程已派完数"时当场派发（acquire 读派发线程 release 写的计数）。
//   深度 = ⌈maxDelay / 拍长⌉ + 1（35 ms @ 60 fps = 3 帧 + 1）：正常最多压 ⌈(L − 渲染耗时) / 拍长⌉ 帧，+1 盖住"新帧入队时队头正在出队"；
//   满了 = 派发线程被饿了好几拍（正常不会），丢这一帧并计 videoDelayOverflow，完成线程不等。
//   停：时钟停 → 渲染器排空（完成回调全部到过）→ 派发线程把队列里剩下的帧不等到期全派掉 → 退出（`stop`）。
// 零分配：队列是预分配的 RenderedFrame? 数组，拷贝只有 retain / release；等待用 mach_wait_until 与信号量；热路径上只有整数运算与原子量。

/// 视频延后的参数（`EngineOptions.videoDelay`）。
public struct VideoDelayOptions: Sendable {
    /// 最大延后：设定值钳到 [0, maxDelay]；延迟队列深度按它算（⌈maxDelay / 拍长⌉ + 1）。
    /// 默认 35 ms = 一条总线最大的效果链延迟（256 + 1440 帧 = 35.3 ms，取整到 35；W5-C 报告 §1.3）。
    public var maxDelay = HostDuration(milliseconds: 35)
    /// 设定值变了，Lₙ 每拍最多改多少（占拍长的比例）：相邻 tickTime 的间隔留在 [¾, 1¼] 拍，严格递增、不丢不重。
    public var slewFraction = 0.25
    /// 派发线程挂 time-constraint 实时策略（参数同时钟线程）：按到期时刻准时醒。
    public var realtime = true
    /// 派发线程名。
    public var threadName = "switcher.engine.dispatch"
    public init() {}
}

/// 视频延后的设定入口：音频引擎（SwitcherAudioIntegration）把 Master 效果链的实测延迟交给它（提案 028）。引擎实现；任意线程可调。
public protocol VideoDelayControl: AnyObject, Sendable {
    /// 设定视频延后（钳到 [0, maxDelay]）。运行中改了按每拍 1/4 拍平滑过去。
    func setVideoDelayTarget(_ delay: HostDuration)
}

/// 预分配的单生产者单消费者延迟队列（Lamport）：GPU 完成线程 push，派发线程 peekDue / pop。不覆盖：满了 push 返回 false。
final class VideoDelayQueue: @unchecked Sendable {
    let capacity: Int
    private let frames: UnsafeMutablePointer<RenderedFrame?>
    /// 每格的到期时刻（host tick）：生产者写元素后 release 发布 head，消费者 acquire 读 head 之后才读它。
    private let dues: UnsafeMutablePointer<UInt64>
    /// 生产者写。
    private let head = Atomic<UInt64>(0)
    /// 消费者写。
    private let tail = Atomic<UInt64>(0)

    init(capacity: Int) {
        precondition(capacity >= 1)
        self.capacity = capacity
        frames = .allocate(capacity: capacity)
        frames.initialize(repeating: nil, count: capacity)
        dues = .allocate(capacity: capacity)
        dues.initialize(repeating: 0, count: capacity)
    }

    deinit {
        frames.deinitialize(count: capacity)
        frames.deallocate()
        dues.deallocate()
    }

    /// 当前压着的帧数（近似值，任何线程可读）。
    var count: Int {
        let h = head.load(ordering: .acquiring), t = tail.load(ordering: .acquiring)
        return h >= t ? Int(h &- t) : 0
    }

    /// 生产者：入队；满了返回 false（不覆盖、不等）。
    @inline(__always)
    func push(_ frame: RenderedFrame, due: HostTime) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h &- t < UInt64(capacity) else { return false }
        let i = Int(h % UInt64(capacity))
        frames[i] = frame
        dues[i] = due.ticks
        head.store(h &+ 1, ordering: .releasing)
        return true
    }

    /// 消费者：队头的到期时刻；空为 nil。
    @inline(__always)
    func peekDue() -> HostTime? {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t != h else { return nil }
        return HostTime(ticks: dues[Int(t % UInt64(capacity))])
    }

    /// 消费者：出队；空为 nil。格子交还前清成 nil（释放对输出缓冲的引用，渲染器的输出环才能复用它）。
    @inline(__always)
    func pop() -> RenderedFrame? {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t != h else { return nil }
        let i = Int(t % UInt64(capacity))
        let frame = (frames + i).move()
        (frames + i).initialize(to: nil)
        tail.store(t &+ 1, ordering: .releasing)
        return frame
    }
}

/// 派发线程出队之后调它（引擎实现：L1 计数 + 逐个消费者 consume）。
protocol VideoDelayDispatching: AnyObject, Sendable {
    func dispatchDelayed(_ frame: RenderedFrame)
}

/// 延后线：设定值、每帧的 Lₙ、延迟队列、派发线程。引擎持有一份；`admit` 只在 GPU 完成线程上调，`run` 只在派发线程上跑。
final class VideoDelayLine: @unchecked Sendable {
    let options: VideoDelayOptions
    /// 拍长。
    let period: HostDuration
    let queue: VideoDelayQueue
    /// 每拍 Lₙ 最多改多少（host tick）。
    let maxStepTicks: Int64
    let maxDelayTicks: Int64
    private let counters: EngineCounters
    /// 设定值（host tick，已钳位）。任意线程写，完成线程读。
    private let target = Atomic<Int64>(0)

    // 完成线程私有
    private var started = false
    private var applied: Int64 = 0
    private var lastTick: Int64 = 0
    private var lastOut: UInt64 = 0
    /// 入队了多少帧（只有完成线程写、读）。
    private var pushed: UInt64 = 0

    /// 派发线程派完了多少帧（派发线程 release 写，完成线程 acquire 读）。
    private let dispatched = Atomic<UInt64>(0)
    private let wake = DispatchSemaphore(value: 0)
    private let stopping = Atomic<Bool>(false)
    private var thread: NativeThread?
    /// 派发线程的 mach 端口（测试的分配探针要它）；没起为 0。
    let threadPort = Atomic<UInt32>(0)

    init(options: VideoDelayOptions, frameRate: FrameRate, counters: EngineCounters) {
        self.options = options
        self.counters = counters
        period = TickClockSpec(t0: .zero, frameRate: frameRate).duration(ofTicks: 1)
        maxDelayTicks = max(0, options.maxDelay.ticks)
        let frames = Int((Double(maxDelayTicks) / Double(max(1, period.ticks))).rounded(.up))
        queue = VideoDelayQueue(capacity: frames + 1)
        maxStepTicks = max(1, Int64((Double(period.ticks) * min(max(options.slewFraction, 0.01), 0.5)).rounded(.down)))
    }

    /// 设定值（钳到 [0, maxDelay]）。任意线程。
    func setTarget(_ delay: HostDuration) {
        target.store(min(max(delay.ticks, 0), maxDelayTicks), ordering: .releasing)
    }

    var targetDuration: HostDuration { HostDuration(ticks: target.load(ordering: .acquiring)) }

    // MARK: 生命周期（组装方线程）

    /// 起派发线程；每次 start 从头算 Lₙ（第一帧直接用设定值，不从 0 爬）。
    func start(sink: any VideoDelayDispatching) throws {
        guard thread == nil else { return }
        started = false
        applied = 0
        lastTick = 0
        lastOut = 0
        pushed = 0
        dispatched.store(0, ordering: .releasing)
        stopping.store(false, ordering: .releasing)
        counters.videoDelayAppliedTicksValue.store(0, ordering: .releasing)
        let periodTicks = UInt32(clamping: period.ticks)
        let tc = NativeThreadConfig.TimeConstraint(period: periodTicks, computation: max(1, periodTicks / 4), constraint: max(1, periodTicks / 2))
        let config = NativeThreadConfig(name: options.threadName, qos: QOS_CLASS_USER_INTERACTIVE, timeConstraint: options.realtime ? tc : nil)
        let t = NativeThread(config: config) { [self] in
            threadPort.store(pthread_mach_thread_np(pthread_self()), ordering: .releasing)
            run(sink)
        }
        try t.start()
        thread = t
    }

    /// 停：队列里剩下的帧不等到期全派掉，线程退出。调用前 GPU 完成回调必须已经停了（引擎在渲染器 shutdown 之后调）。
    func stop() {
        guard let t = thread else { return }
        stopping.store(true, ordering: .releasing)
        wake.signal()
        t.join()
        thread = nil
        threadPort.store(0, ordering: .releasing)
    }

    // MARK: GPU 完成线程

    /// 一帧渲染完了：算这一帧的 Lₙ、改写 tickTime；返回要当场派发的帧（队列空且已到期），nil = 已入队（或队列满丢了）。零分配。
    @inline(__always)
    func admit(_ frame: RenderedFrame, now: HostTime) -> RenderedFrame? {
        let tick = frame.tick.rawValue
        let goal = target.load(ordering: .acquiring)
        if !started {
            applied = goal
            started = true
        } else if goal != applied {
            let ticks = max(1, tick &- lastTick)
            let step = maxStepTicks &* ticks
            applied = goal > applied ? min(goal, applied &+ step) : max(goal, applied &- step)
        }
        lastTick = tick
        counters.videoDelayAppliedTicksValue.store(applied, ordering: .relaxed)
        var time = frame.tickTime.ticks &+ UInt64(applied)
        if time <= lastOut {
            // slew 把每拍改动限在 1/4 拍内，正常走不到这里；万一（拍号回退之类）也保证严格递增
            time = lastOut &+ 1
            counters.videoDelayPTSGuardValue.add(1, ordering: .relaxed)
        }
        lastOut = time
        let out: RenderedFrame
        if time == frame.tickTime.ticks {
            out = frame
        } else {
            out = RenderedFrame(tick: frame.tick, tickTime: HostTime(ticks: time), program: frame.program, preview: frame.preview,
                                multiview: frame.multiview, submitTime: frame.submitTime, gpuStart: frame.gpuStart, gpuEnd: frame.gpuEnd)
        }
        let idle = dispatched.load(ordering: .acquiring) == pushed
        if idle && time <= now.ticks { return out }
        if queue.push(out, due: HostTime(ticks: time)) {
            pushed &+= 1
            counters.framesDelayedValue.add(1, ordering: .relaxed)
            _ = counters.videoDelayQueueMaxValue.max(queue.count, ordering: .relaxed)
            wake.signal()
        } else {
            counters.videoDelayOverflowValue.add(1, ordering: .relaxed)
        }
        return nil
    }

    // MARK: 派发线程

    private func run(_ sink: any VideoDelayDispatching) {
        while true {
            if let due = queue.peekDue() {
                if !stopping.load(ordering: .acquiring) && HostClock.now() < due {
                    _ = mach_wait_until(due.ticks)
                    continue
                }
                guard let frame = queue.pop() else { continue }
                _ = counters.videoDelayLateMaxNsValue.max((HostClock.now() - due).nanoseconds, ordering: .relaxed)
                sink.dispatchDelayed(frame)
                dispatched.add(1, ordering: .releasing)
            } else {
                if stopping.load(ordering: .acquiring) { break }
                wake.wait()
            }
        }
    }
}
