import Foundation
import Synchronization
import SwitcherContracts

// 引擎骨架（设计方案 §2、§3.2、§3.4；CONTRACTS.md §7 的调用链）。
//
// 每拍（时钟线程 = 渲染线程，零分配、不进 actor、无 async）：
//   时钟到期 tick n → 确认状态机已准备到 n（否则短暂等，超时用旧快照并计数）→ 借用快照（原子指针）
//   → noteRendered(n) + requestPrepare(n + 1)（原子量 + 信号量）→ 借用输入表，对每路挑帧填 RenderInputTable：
//     实现了 ArrivalPacedFrameSlot 的槽走 latest(forTick: t_n)（带到达余量，V4 退回单的修法，见 Slots/ArrivalPacing.swift），
//     其他槽走契约的 latest(atOrBefore: t_n)
//   → renderer.render(...)：.skipped 记 missed_render → 归还借用。
//   → 每路记下这拍用的帧（InputLatencyRecorder，提案 005 的 L1）。
// GPU 完成回调线程（RenderSink）：取 now → 计 render_ms / 派发抖动 / 帧数 → 视频延后（W1-B4，Engine/VideoDelay.swift）：
//   Lₙ = 0 且延迟队列空：当场派发（下一行）；否则 tickTime 改成拍点 + Lₙ、入队，派发线程到期再派。
// 派发（完成线程当场或派发线程到期，同一时刻只有一条）：每路 L1（派发那一刻 − 新帧的 ingressTime）
//   → 对每个 FrameConsumer 调 consume（必须立即返回，各自入队；引擎给每次 consume 计时，超过 1 ms 计入 slowConsumeCalls 供诊断）。
// 输入表与消费者表：不可变对象 + 原子指针发布（HazardPublisher），注册 / 注销在普通线程换表。
// Stats：`makeStats()` 在普通线程从 EngineCounters 组装（铁律 4）。

/// 引擎选项。
public struct EngineOptions: Sendable {
    /// 时钟线程选项。
    public var clock = ProgramClockOptions()
    /// 渲染线程等状态机快照的上限；超时用上一拍的快照（计 snapshotStale）。
    public var snapshotWaitLimit = HostDuration(milliseconds: 1)
    /// consume 超过这个时长算"慢消费者"（诊断计数）。
    public var slowConsumeThreshold = HostDuration(milliseconds: 1)
    /// 到达余量参数（注册输入时交给实现了 ArrivalPacedFrameSlot 的槽；initialFloor / maxRaise / programFrame 为 nil 时按节目帧率填；
    /// `registerInput(number:slot:pacing:)` 可按输入另给一份）。
    public var pacing = PacingOptions()
    /// 视频延后（W1-B4，提案 028）：最大延后（队列深度按它算）、每拍最多改多少、派发线程的实时策略。
    public var videoDelay = VideoDelayOptions()
    public init() {}
}

/// 引擎错误。
public enum EngineError: Error, Equatable {
    case alreadyStarted
    case notStarted
    case inputNumberOutOfRange(Int)
}

/// 引擎。组装方（headless / App / 测试）创建：状态机 + 渲染器 + 每路帧槽 + 消费者。
public final class Engine: @unchecked Sendable, ProgramClockHandler, RenderSink, VideoDelayControl, VideoDelayDispatching {
    public let stateMachine: StateMachine
    public let renderer: any Renderer
    public let format: ProgramFormat
    /// 最大输入编号（RenderInputTable 容量 = maxInputs + 1）。
    public let maxInputs: Int
    public let options: EngineOptions
    public let counters: EngineCounters
    /// 时钟；start 之后可用。
    public private(set) var clock: ProgramClock?
    /// 编码器统计来源（W1-E 的消费者提供；G2 接线）。
    public var encoderStatsProvider: (@Sendable () -> [Stats.EncoderEntry])?
    /// 音频统计来源（W2-E 接线）。
    public var audioStatsProvider: (@Sendable () -> Stats.AudioCounters)?
    /// Stats.display[] 的供数方（提案 013）：显示类输出（外部显示窗口、虚拟摄像头、多画面窗口、主界面监视器）。
    /// 组装方（App 的 StatsHub）设；headless 不设 = 空数组。采样线程上调，要快。
    public var displayStatsProvider: (@Sendable () -> [Stats.DisplayEntry])?
    /// GPU 占用来源（没有公开 API；G2 若用 powermetrics / IOKit 采到就从这里灌，否则 0）。
    public var gpuPercentProvider: (@Sendable () -> Double)?

    /// 输入表：下标 = 输入编号，不可变，整表替换。
    final class SlotTable: Sendable {
        let slots: [LockFreeFrameSlotBox?]
        init(slots: [LockFreeFrameSlotBox?]) { self.slots = slots }
    }
    /// 把 any FrameSlot 装箱成 Sendable 引用；带到达余量的槽另存一份协议引用，渲染线程按它分流。
    final class LockFreeFrameSlotBox: @unchecked Sendable {
        let slot: any FrameSlot
        let paced: (any ArrivalPacedFrameSlot)?
        init(_ slot: any FrameSlot, paced: (any ArrivalPacedFrameSlot)?) {
            self.slot = slot
            self.paced = paced
        }
    }

    private let inputTable: RenderInputTable
    /// 视频延后（W1-B4）：设定值、每帧的 Lₙ、延迟队列、派发线程。
    let videoDelayLine: VideoDelayLine
    /// 每路 L1 的记录环（提案 005）。
    private let latency: InputLatencyRecorder
    private let slotsPublisher: HazardPublisher<SlotTable>
    private let slotsReader: HazardPublisher<SlotTable>.ReaderSlot
    private let snapshotReader: HazardPublisher<MixerSnapshot>.ReaderSlot
    /// 把 any FrameConsumer 装箱成 Sendable 引用。
    final class ConsumerBox: @unchecked Sendable {
        let consumer: any FrameConsumer
        init(_ consumer: any FrameConsumer) { self.consumer = consumer }
    }
    private let registry = Mutex<[Int: LockFreeFrameSlotBox]>([:])
    private let consumers = Mutex<[ConsumerBox]>([])
    private var assembler: StatsAssembler?
    private let started = Atomic<Bool>(false)
    private var warmedUp = false
    private var startedAt = HostTime.zero
    /// 时钟线程起晚了多少：起时钟那一刻已经过了第 firstTick 拍的时刻多久（准时或提前为 0）。诊断量，start 之后有效：
    /// 非 0 说明组装方定 t0 之后做的事吃掉了提前量（见 warmUp）；开头会有 ⌊lag / 拍长⌋ 拍 missed_render、各路帧槽在这段时间挤掉的帧算 drop。
    public private(set) var clockStartLag: HostDuration = .zero

    /// - Parameters:
    ///   - stateMachine: 已构造的状态机（引擎 start 时起它的线程）。
    ///   - renderer: W1-C 的渲染器（或测试的假实现）。
    ///   - maxInputs: 最大输入编号。
    public init(stateMachine: StateMachine, renderer: any Renderer, maxInputs: Int = 16, options: EngineOptions = EngineOptions()) {
        precondition(maxInputs >= 1)
        self.stateMachine = stateMachine
        self.renderer = renderer
        self.maxInputs = maxInputs
        self.options = options
        format = stateMachine.publisher.latest?.state.format ?? .hd1080p60
        counters = EngineCounters(maxInputs: maxInputs)
        inputTable = RenderInputTable(capacity: maxInputs + 1)
        latency = InputLatencyRecorder(inputCapacity: maxInputs + 1)
        videoDelayLine = VideoDelayLine(options: options.videoDelay, frameRate: format.frameRate, counters: counters)
        slotsPublisher = HazardPublisher(initial: SlotTable(slots: Array(repeating: nil, count: maxInputs + 1)), readerCapacity: 2)
        slotsReader = slotsPublisher.makeReaderSlot()
        snapshotReader = stateMachine.publisher.makeReaderSlot()
    }

    // MARK: 组装（普通线程）

    /// 注册一路输入的帧槽（可在运行中调；换表走原子指针）。实现了 ArrivalPacedFrameSlot 的槽在这里拿到余量参数：
    /// `pacing` 为 nil 用引擎的 `options.pacing`，否则用给的那份（组装方按输入类型定，例如自由跑的源关掉）；
    /// 两种情况下 nil 的 initialFloor / maxRaise / programFrame 都按节目帧率填。
    public func registerInput(number: Int, slot: any FrameSlot, pacing: PacingOptions? = nil) {
        precondition(number >= 1 && number <= maxInputs, "输入编号 \(number) 超出 1…\(maxInputs)")
        var paced: (any ArrivalPacedFrameSlot)? = nil
        if let p = slot as? any ArrivalPacedFrameSlot {
            p.configurePacing(resolvePacingOptions(pacing ?? options.pacing))
            paced = p
        }
        let box = LockFreeFrameSlotBox(slot, paced: paced)
        registry.withLock { $0[number] = box }
        republishSlots()
    }

    /// 注册时交给槽的余量参数：nil 的 initialFloor / maxRaise / programFrame 按节目帧率填（1/4 帧 / 一帧 / 一帧）。
    var resolvedPacingOptions: PacingOptions { resolvePacingOptions(options.pacing) }

    func resolvePacingOptions(_ base: PacingOptions) -> PacingOptions {
        var o = base
        let period = TickClockSpec(t0: .zero, frameRate: format.frameRate).duration(ofTicks: 1)
        if o.initialFloor == nil { o.initialFloor = period / 4 }
        if o.maxRaise == nil { o.maxRaise = period }
        if o.programFrame == nil { o.programFrame = period }
        return o
    }

    /// 某路输入的到达余量状态（没注册或槽不带余量为 nil）。普通线程。
    public func pacingStats(forInput number: Int) -> PacingStats? {
        registry.withLock { $0[number]?.paced?.pacingStats }
    }

    /// 注销一路输入。
    public func unregisterInput(number: Int) {
        _ = registry.withLock { $0.removeValue(forKey: number) }
        republishSlots()
    }

    /// 在注册锁内发布：HazardPublisher 是单写方，锁把并发的注册 / 注销串成一条写线程。
    private func republishSlots() {
        registry.withLock { entries in
            var table = [LockFreeFrameSlotBox?](repeating: nil, count: maxInputs + 1)
            for (n, box) in entries where n >= 1 && n <= maxInputs { table[n] = box }
            slotsPublisher.publish(SlotTable(slots: table))
        }
    }

    /// 已注册的输入编号（升序）。
    public var registeredInputs: [Int] { registry.withLock { $0.keys.sorted() } }

    /// 加一个 PGM 消费者（可在运行中调）。
    public func addConsumer(_ consumer: any FrameConsumer) {
        let box = ConsumerBox(consumer)
        consumers.withLock { $0.append(box) }
    }

    /// 去掉一个消费者。
    public func removeConsumer(_ consumer: any FrameConsumer) {
        let id = ObjectIdentifier(consumer)
        consumers.withLock { $0.removeAll { ObjectIdentifier($0.consumer) == id } }
    }

    // MARK: 生命周期

    /// 预热：所有一次性的慢活——渲染器 prepare（管线状态、纹理池、输出环、首帧空渲染）、状态机线程、第 0 拍的快照。幂等；`start` 没预热会自己调。
    ///
    /// 组装方应**先 warmUp、再定 t0、再 start**（W1-B3）：t0 一旦定下（音频引擎、输入、录制都按它起），引擎起晚多少就有 ⌊晚 / 拍长⌋ 拍
    /// missed_render，这段时间进帧槽的帧也被挤掉算 drop。真 App 定 t0 = now + 300 ms 之后先做了 686 ms 的控制层启动才调 start，第一秒就是
    /// jitter 477 ms / missed_render 28 / 每路 drop 12（reports/w1-core-3.md §1）；引擎 prepare 本身只要 2 ms，但 headless 的着色器从源码
    /// 编译在系统缓存未命中时要 0.6–1 s。起晚了多少看 `clockStartLag`。warmUp / start / stop 由组装方顺序调用，不支持并发。
    public func warmUp() async throws {
        guard !warmedUp else { return }
        try renderer.prepare(format: format, maxInputs: maxInputs + 1)
        renderer.sink = self
        stateMachine.start()
        await stateMachine.prepare(upTo: .zero)
        warmedUp = true
    }

    /// 起引擎：（没预热就先 warmUp）→ 状态机准备到 firstTick → 时钟线程。t0 = 第 firstTick 拍的时刻；lastTick 非 nil 时跑到它为止（测试）。
    /// 调用时 t0 应仍在未来：起时钟那一刻已过 t0 的话开头会跳拍（`clockStartLag`），先 warmUp 再定 t0 就不会。
    public func start(t0: HostTime = .now(), firstTick: Tick = .zero, lastTick: Tick? = nil) async throws {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { throw EngineError.alreadyStarted }
        do { try await warmUp() } catch {
            started.store(false, ordering: .releasing)
            throw error
        }
        await stateMachine.prepare(upTo: firstTick)
        startedAt = HostClock.now()
        assembler = StatsAssembler(counters: counters, startedAt: startedAt)
        let clock = ProgramClock(spec: TickClockSpec(t0: t0, frameRate: format.frameRate), options: options.clock)
        self.clock = clock
        latency.t0.store(clock.spec.time(of: firstTick).ticks, ordering: .releasing)
        do {
            try videoDelayLine.start(sink: self)
        } catch {
            started.store(false, ordering: .releasing)
            throw error
        }
        clockStartLag = max(.zero, HostClock.now() - clock.spec.time(of: firstTick))
        do {
            try clock.start(handler: self, firstTick: firstTick, lastTick: lastTick)
        } catch {
            videoDelayLine.stop()   // 派发线程已经起了：时钟起不来就收回去，不留一条空转的实时线程
            throw error
        }
    }

    /// 停引擎：时钟停 → 渲染器 shutdown（完成回调全部到过）→ 延迟队列里剩下的帧派完、派发线程停 → 状态机线程停。
    /// 只预热没起的引擎也用它释放渲染器与状态机线程。
    public func stop() async {
        guard started.load(ordering: .acquiring) || warmedUp else { return }
        clock?.stop()
        renderer.shutdown()
        videoDelayLine.stop()
        renderer.sink = nil
        stateMachine.stop()
        warmedUp = false
        started.store(false, ordering: .releasing)
    }

    public var isRunning: Bool { started.load(ordering: .acquiring) }

    // MARK: 视频延后（W1-B4，提案 028；任意线程）

    /// 设定视频延后（钳到 [0, options.videoDelay.maxDelay]）。音频引擎在 videoDelay 补偿方式下把 Master 效果链的实测延迟交过来；
    /// 运行中改了，Lₙ 按每拍最多 1/4 拍平滑过去（tickTime 严格递增、不丢不重）。没起也能设（下次起的第一帧就用它）。
    public func setVideoDelayTarget(_ delay: HostDuration) { videoDelayLine.setTarget(delay) }
    /// 设定值（已钳位）。
    public var videoDelayTarget: HostDuration { videoDelayLine.targetDuration }
    /// 实际在用的延后：最近派发的那一帧的 Lₙ（slew 过程中与设定值不同）。显示源（渲染器的 displayDelayProvider）读它。
    public var videoDelayApplied: HostDuration { counters.videoDelayApplied }
    /// 延迟队列深度（⌈maxDelay / 拍长⌉ + 1）。
    public var videoDelayQueueCapacity: Int { videoDelayLine.queue.capacity }
    /// 派发线程的 mach 端口（测试的分配探针）；没起为 0。
    var videoDelayDispatchThreadPort: UInt32 { videoDelayLine.threadPort.load(ordering: .acquiring) }

    // MARK: 渲染线程（ProgramClockHandler）

    public func programClock(_ clock: ProgramClock, tick: Tick, ideal: HostTime, wake: HostTime) {
        counters.ticksDispatchedValue.add(1, ordering: .relaxed)
        // 1. 快照：状态机应已准备到本拍；没有就催一下并短等
        if stateMachine.preparedTick < tick {
            stateMachine.requestPrepare(tick)
            let deadline = wake + options.snapshotWaitLimit
            while stateMachine.preparedTick < tick && HostClock.now() < deadline {}
            if stateMachine.preparedTick < tick {
                counters.snapshotStaleValue.add(1, ordering: .relaxed)
            } else {
                counters.snapshotWaitsValue.add(1, ordering: .relaxed)
            }
        }
        let snapshotRef = snapshotReader.borrow()
        stateMachine.noteRendered(tick)
        stateMachine.requestPrepare(tick + 1)
        // 2. 挑帧。热路径上不用 for-in：-Onone 下 Range 的 IndexingIterator 走未特化泛型，每次迭代会堆分配装箱
        //    （分配探针抓到的：每拍 32 次 malloc）；整数 while 循环在 debug 下也零分配。
        let tableRef = slotsReader.borrow()
        if let tableRef {
            let table = tableRef.takeUnretainedValue()
            var number = 1
            while number <= maxInputs {
                var frame: Frame? = nil
                if let box = table.slots[number] {
                    if let paced = box.paced {
                        frame = paced.latest(forTick: ideal)
                    } else {
                        frame = box.slot.latest(atOrBefore: ideal)
                    }
                }
                inputTable[inputNumber: number] = frame
                latency.record(input: number, tick: tick, frame: frame)
                number += 1
            }
        }
        // 3. 渲染
        if let snapshotRef {
            let snapshot = snapshotRef.takeUnretainedValue()
            switch renderer.render(tick: tick, at: ideal, snapshot: snapshot, inputs: inputTable) {
            case .submitted: counters.framesSubmittedValue.add(1, ordering: .relaxed)
            case .skipped: counters.renderSkippedValue.add(1, ordering: .relaxed)
            }
        }
        slotsReader.endBorrow()
        snapshotReader.endBorrow()
        counters.lastTickValue.store(tick.rawValue, ordering: .releasing)
    }

    public func programClock(_ clock: ProgramClock, didSkipTicks count: Int, upTo tick: Tick) {
        counters.ticksSkippedValue.add(UInt64(count), ordering: .relaxed)
        // 下一拍要渲染的是 tick + 1，提前让状态机准备，免得到时候等
        stateMachine.requestPrepare(tick + 1)
    }

    // MARK: GPU 完成线程（RenderSink）

    public func renderer(_ renderer: any Renderer, didComplete frame: RenderedFrame) {
        let now = HostClock.now()
        counters.framesCompletedValue.add(1, ordering: .relaxed)
        let renderNs = (frame.gpuEnd - frame.tickTime).nanoseconds
        counters.renderNsSumValue.add(UInt64(max(renderNs, 0)), ordering: .relaxed)
        counters.renderCountValue.add(1, ordering: .relaxed)
        _ = counters.dispatchJitterMaxNsValue.max((now - frame.tickTime).magnitude.nanoseconds, ordering: .relaxed)
        // 视频延后：Lₙ = 0 且队列空时当场派发（与以前同一条路）；否则改好 tickTime 入队，派发线程到期再派
        if let out = videoDelayLine.admit(frame, now: now) { dispatch(out, now: now) }
    }

    // MARK: 派发（GPU 完成线程当场，或派发线程到期；同一时刻只有一条线程在这里）

    func dispatchDelayed(_ frame: RenderedFrame) { dispatch(frame, now: HostClock.now()) }

    @inline(__always)
    private func dispatch(_ frame: RenderedFrame, now: HostTime) {
        latency.account(tick: frame.tick, now: now, into: counters)   // 提案 005：派发那一刻 − 各路新帧的 ingressTime（延后之后量，含 L）
        let threshold = options.slowConsumeThreshold
        consumers.withLock { list in
            var i = 0
            while i < list.count {
                let before = HostClock.now()
                list[i].consumer.consume(frame)
                if HostClock.now() - before > threshold { counters.slowConsumeCallsValue.add(1, ordering: .relaxed) }
                counters.framesDispatchedValue.add(1, ordering: .relaxed)
                i += 1
            }
        }
    }

    // MARK: Stats（普通线程）

    /// 组装 stats.jsonl 的一行；窗口 = 上次调用到现在。
    public func makeStats(now: HostTime = .now(), wallClock: Date = Date()) -> Stats {
        let assembler = self.assembler ?? StatsAssembler(counters: counters, startedAt: now)
        self.assembler = assembler
        let inputs = registry.withLock { $0.map { (number: $0.key, stats: $0.value.slot.stats) } }.sorted { $0.number < $1.number }
        let jitter = clock?.jitter ?? JitterRecorder(capacity: 1)
        return assembler.make(now: now, wallClock: wallClock, jitter: jitter, inputs: inputs,
                              encoder: encoderStatsProvider?() ?? [],
                              display: displayStatsProvider?() ?? [],
                              audio: audioStatsProvider?() ?? Stats.AudioCounters(dropouts: 0, underruns: 0),
                              gpuPct: gpuPercentProvider?() ?? 0)
    }

    /// 派发抖动（GPU 完成回调时刻 − 理想拍点）的窗口最大值，读后清零。V3 的另一种口径，给 G2 对照。
    public func takeDispatchJitterMax() -> HostDuration {
        HostDuration(nanoseconds: counters.dispatchJitterMaxNsValue.exchange(0, ordering: .acquiringAndReleasing))
    }
}
