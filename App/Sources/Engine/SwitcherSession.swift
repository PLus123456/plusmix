// 一次运行 = 一个节目文件跑起来：状态机 + 渲染器 + 引擎 + 各路输入 + Stats 采样（设计方案 §2、§9.1、§10）。
//
// 绑定规则（W2-B prompt 第 3 条）：
// - UI 只发 Command（`send`），只读快照（`state`）和 Stats（`stats`），不碰引擎内部。
// - 快照变化经主线程分发：主线程每 1/60 s 看一次 `publisher.latest`，指针变了才通知观察者，所以每秒最多 60 次，
//   同一帧内的多次状态变化合并成一次（渲染线程 / 音频线程各自走 HazardPublisher 的实时读槽，与这里无关）。
// - 状态行 1 Hz：StatsPump 每秒一行，同一个 Stats 送 UI 和 stats.jsonl。
// - 命令按发出顺序串行投给状态机（一条 AsyncStream 一个消费者）：W2-C 的 CommandBus 合并后换成它，UI 侧不用改。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherTestKit

/// 观察者的凭据：释放即取消。
final class ObserverToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
    func invalidate() { cancel() }
}

@MainActor
final class SwitcherSession {
    /// 节目名（保存时用）。
    var name: String
    let format: ProgramFormat
    let stateMachine: StateMachine
    let renderer: MetalRenderer
    let engine: Engine
    let inputs: InputRuntime
    /// 界面布局（Show.layout 原样带着）。
    var layout: ShowLayout
    /// 最新快照（主线程副本）。
    private(set) var state: MixerState
    /// 最新一行 Stats（起引擎一秒后才有）。
    private(set) var stats: Stats?
    private(set) var isRunning = false
    /// 引擎第 0 拍的时刻（start 时定）。
    private(set) var t0: HostTime = .zero

    private var lastSnapshot: MixerSnapshot?
    private var pollTimer: Timer?
    // 按登记顺序回调（字典的遍历顺序不定，测试对照状态行时要先让窗口更新再让测试读）
    private var stateObservers: [(key: UInt64, block: @MainActor (MixerState) -> Void)] = []
    private var statsObservers: [(key: UInt64, block: @MainActor (Stats) -> Void)] = []
    private var observerCounter: UInt64 = 0
    private func nextObserverKey() -> UInt64 {
        observerCounter &+= 1
        return observerCounter
    }
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var commandTask: Task<Void, Never>?
    private var pump: StatsPump?
    /// 已发出的命令数（测试看）。
    private(set) var commandsSent: UInt64 = 0

    /// 多画面 / 显示视图的纹理来源。
    var displaySource: any DisplayFrameSource { renderer }

    init(show: Show, inputFactory: any InputFactory = DefaultInputFactory()) throws {
        let initial = show.makeState()
        try initial.validate()
        name = show.name
        layout = show.layout
        format = initial.format
        state = initial
        renderer = try MetalRenderer()
        stateMachine = StateMachine(initialState: initial)
        let maxNumber = initial.inputs.map(\.number).max() ?? 1
        engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
        inputs = InputRuntime(engine: engine, factory: inputFactory)
        lastSnapshot = stateMachine.publisher.latest
    }

    // MARK: 生命周期

    /// 起引擎：先按初始快照建好输入并注册，再起引擎，再 start 输入（合成源到 t0 才出第一帧）。
    func start(leadMilliseconds: Double = 300) async throws {
        guard !isRunning else { return }
        t0 = HostClock.now() + HostDuration(milliseconds: leadMilliseconds)
        inputs.reconcile(state, timeline: syntheticTimeline())
        startCommandLoop()
        try await engine.start(t0: t0)
        isRunning = true
        inputs.startAll()
        let pump = StatsPump(engine: engine) { [weak self] stats in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(stats: stats) } }
        }
        pump.start()
        self.pump = pump
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)   // 拖窗口 / 模态期间也要分发
        pollTimer = timer
    }

    /// 停：Stats → 输入 → 引擎（引擎 stop 会排空在途帧）。
    func stop() async {
        guard isRunning else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pump?.stop()
        pump = nil
        inputs.stopAll()
        await engine.stop()
        commandContinuation?.finish()
        commandContinuation = nil
        commandTask?.cancel()
        commandTask = nil
        isRunning = false
    }

    // MARK: 命令

    /// UI 唯一的写入口。
    func send(_ command: Command) {
        commandsSent &+= 1
        if let commandContinuation {
            commandContinuation.yield(command)
        } else {
            // 引擎还没起：直接应用（状态机没 start 也能 apply）
            let machine = stateMachine
            Task { await machine.apply(command) }
        }
    }

    private func startCommandLoop() {
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        commandContinuation = continuation
        let machine = stateMachine
        commandTask = Task.detached(priority: .userInitiated) {
            for await command in stream {
                await machine.apply(command)
            }
        }
    }

    // MARK: 快照分发（≤ 60 Hz）

    private func pollSnapshot() {
        guard let snapshot = stateMachine.publisher.latest, snapshot !== lastSnapshot else { return }
        lastSnapshot = snapshot
        let newState = snapshot.state
        // 输入表的"编号 + 来源"变了才动运行表（改名 / 改设置不重建输入）
        let inputsChanged = !newState.inputs.map(\.number).elementsEqual(state.inputs.map(\.number))
            || !newState.inputs.map(\.source).elementsEqual(state.inputs.map(\.source))
        state = newState
        if inputsChanged { inputs.reconcile(newState, timeline: syntheticTimeline()) }
        for observer in stateObservers { observer.block(newState) }
    }

    /// 立刻用当前状态回调一次，之后每次快照变化都回调。
    @discardableResult
    func observeState(_ block: @escaping @MainActor (MixerState) -> Void) -> ObserverToken {
        let key = nextObserverKey()
        stateObservers.append((key, block))
        block(state)
        return ObserverToken { [weak self] in
            Task { @MainActor in self?.stateObservers.removeAll { $0.key == key } }
        }
    }

    // MARK: Stats（1 Hz）

    private func publish(stats: Stats) {
        self.stats = stats
        for observer in statsObservers { observer.block(stats) }
    }

    @discardableResult
    func observeStats(_ block: @escaping @MainActor (Stats) -> Void) -> ObserverToken {
        let key = nextObserverKey()
        statsObservers.append((key, block))
        if let stats { block(stats) }
        return ObserverToken { [weak self] in
            Task { @MainActor in self?.statsObservers.removeAll { $0.key == key } }
        }
    }

    /// 同一份 Stats 也写进 stats.jsonl（测试 / 排障用；`--stats <路径>` 启动参数也走这里）。
    func startStatsLog(url: URL) throws { try pump?.startLog(url: url) }
    func stopStatsLog() { pump?.closeLog() }
    var statsLogURL: URL? { pump?.logURL }

    // MARK: 合成源时间线

    /// 合成源的 t0：对齐到节目拍点、提前半个节目帧（headless 的 --input-lead-ms 默认值，理由见 HeadlessRun.swift 第 1 步）。
    /// 引擎已起：取"现在之后第 3 拍"，让新加的路从最近的拍点开始，不用从 t0 追帧；引擎未起：就是引擎的 t0。
    func syntheticTimeline() -> SyntheticTimeline {
        let halfFrame = HostDuration(seconds: format.frameDuration.doubleValue / 2)
        if let clock = engine.clock {
            let spec = clock.spec
            let next = spec.tick(at: HostClock.now()) + 3
            return SyntheticTimeline(t0: spec.time(of: next) - halfFrame, frameRate: format.frameRate)
        }
        return SyntheticTimeline(t0: t0 - halfFrame, frameRate: format.frameRate)
    }

    /// 当前状态存成节目文件。
    func makeShow() -> Show { Show(name: name, state: state, layout: layout) }
}
