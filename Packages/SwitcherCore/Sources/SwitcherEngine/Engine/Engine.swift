import Foundation
import Synchronization
import SwitcherContracts

// 引擎骨架（设计方案 §2、§3.2、§3.4；CONTRACTS.md §7 的调用链）。
//
// 每拍（时钟线程 = 渲染线程，零分配、不进 actor、无 async）：
//   时钟到期 tick n → 确认状态机已准备到 n（否则短暂等，超时用旧快照并计数）→ 借用快照（原子指针）
//   → noteRendered(n) + requestPrepare(n + 1)（原子量 + 信号量）→ 借用输入表，对每路 slot.latest(atOrBefore: t_n) 填 RenderInputTable
//   → renderer.render(...)：.skipped 记 missed_render → 归还借用。
// GPU 完成回调线程（RenderSink）：计 render_ms / 派发抖动 / 帧数 → 对每个 FrameConsumer 调 consume（必须立即返回，
//   各自入队；引擎给每次 consume 计时，超过 1 ms 计入 slowConsumeCalls 供诊断）。
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
    public init() {}
}

/// 引擎错误。
public enum EngineError: Error, Equatable {
    case alreadyStarted
    case notStarted
    case inputNumberOutOfRange(Int)
}

/// 引擎。组装方（headless / App / 测试）创建：状态机 + 渲染器 + 每路帧槽 + 消费者。
public final class Engine: @unchecked Sendable, ProgramClockHandler, RenderSink {
    public let stateMachine: StateMachine
    public let renderer: any Renderer
    public let format: ProgramFormat
    /// 最大输入编号（RenderInputTable 容量 = maxInputs + 1）。
    public let maxInputs: Int
    public let options: EngineOptions
    public let counters = EngineCounters()
    /// 时钟；start 之后可用。
    public private(set) var clock: ProgramClock?
    /// 编码器统计来源（W1-E 的消费者提供；G2 接线）。
    public var encoderStatsProvider: (@Sendable () -> [Stats.EncoderEntry])?
    /// 音频统计来源（W2-E 接线）。
    public var audioStatsProvider: (@Sendable () -> Stats.AudioCounters)?
    /// GPU 占用来源（没有公开 API；G2 若用 powermetrics / IOKit 采到就从这里灌，否则 0）。
    public var gpuPercentProvider: (@Sendable () -> Double)?

    /// 输入表：下标 = 输入编号，不可变，整表替换。
    final class SlotTable: Sendable {
        let slots: [LockFreeFrameSlotBox?]
        init(slots: [LockFreeFrameSlotBox?]) { self.slots = slots }
    }
    /// 把 any FrameSlot 装箱成 Sendable 引用。
    final class LockFreeFrameSlotBox: @unchecked Sendable {
        let slot: any FrameSlot
        init(_ slot: any FrameSlot) { self.slot = slot }
    }

    private let inputTable: RenderInputTable
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
    private var startedAt = HostTime.zero

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
        inputTable = RenderInputTable(capacity: maxInputs + 1)
        slotsPublisher = HazardPublisher(initial: SlotTable(slots: Array(repeating: nil, count: maxInputs + 1)), readerCapacity: 2)
        slotsReader = slotsPublisher.makeReaderSlot()
        snapshotReader = stateMachine.publisher.makeReaderSlot()
    }

    // MARK: 组装（普通线程）

    /// 注册一路输入的帧槽（可在运行中调；换表走原子指针）。
    public func registerInput(number: Int, slot: any FrameSlot) {
        precondition(number >= 1 && number <= maxInputs, "输入编号 \(number) 超出 1…\(maxInputs)")
        let box = LockFreeFrameSlotBox(slot)
        registry.withLock { $0[number] = box }
        republishSlots()
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

    /// 起引擎：渲染器 prepare → 状态机线程 → 时钟线程。t0 = 第 firstTick 拍的时刻；lastTick 非 nil 时跑到它为止（测试）。
    public func start(t0: HostTime = .now(), firstTick: Tick = .zero, lastTick: Tick? = nil) async throws {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { throw EngineError.alreadyStarted }
        try renderer.prepare(format: format, maxInputs: maxInputs + 1)
        renderer.sink = self
        stateMachine.start()
        await stateMachine.prepare(upTo: firstTick)
        startedAt = HostClock.now()
        assembler = StatsAssembler(counters: counters, startedAt: startedAt)
        let clock = ProgramClock(spec: TickClockSpec(t0: t0, frameRate: format.frameRate), options: options.clock)
        self.clock = clock
        try clock.start(handler: self, firstTick: firstTick, lastTick: lastTick)
    }

    /// 停引擎：时钟停 → 渲染器 shutdown → 状态机线程停。
    public func stop() async {
        guard started.load(ordering: .acquiring) else { return }
        clock?.stop()
        renderer.shutdown()
        renderer.sink = nil
        stateMachine.stop()
        started.store(false, ordering: .releasing)
    }

    public var isRunning: Bool { started.load(ordering: .acquiring) }

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
                if let box = table.slots[number] {
                    inputTable[inputNumber: number] = box.slot.latest(atOrBefore: ideal)
                } else {
                    inputTable[inputNumber: number] = nil
                }
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
                              audio: audioStatsProvider?() ?? Stats.AudioCounters(dropouts: 0, underruns: 0),
                              gpuPct: gpuPercentProvider?() ?? 0)
    }

    /// 派发抖动（GPU 完成回调时刻 − 理想拍点）的窗口最大值，读后清零。V3 的另一种口径，给 G2 对照。
    public func takeDispatchJitterMax() -> HostDuration {
        HostDuration(nanoseconds: counters.dispatchJitterMaxNsValue.exchange(0, ordering: .acquiringAndReleasing))
    }
}
