// 一次运行 = 一个节目文件跑起来：状态机 + 渲染器 + 引擎 + 各路输入 + 音频引擎 + 输出（录制 / 推流）+ 控制层（总线 / API / 快捷键 / MIDI）
// + Stats 采样（设计方案 §2、§9.1、§10）。W2-B2 把 G3 清单末表的七个接缝都接上了（docs/checklists/G3.md）。
//
// 绑定规则（W2-B prompt 第 3 条）：
// - UI 只发 Command（`send` → CommandBus，来源 ui），只读快照（`state`）和 Stats（`stats`），不碰引擎内部。
// - 快照变化经主线程分发：主线程每 1/60 s 看一次 `publisher.latest`，指针变了才通知观察者，所以每秒最多 60 次，
//   同一帧内的多次状态变化合并成一次（渲染线程 / 音频线程各自走 HazardPublisher 的实时读槽，与这里无关）。
// - 状态行 1 Hz：StatsPublisher 每秒一行，同一个 Stats 送 UI、stats.jsonl 和 API（铁律 4）。
//
// 起停顺序：
//   起：输入建好并注册（帧槽 → 引擎，音频环 → 音频引擎）→ 控制层（推送源、API、MIDI）→ 音频引擎 start(clock:) → 引擎 start(t0:)
//      → 输入 start → Stats 采样 → 输出按快照起（录制 / 推流）。
//   停：API → 输出封口（录制到拍边界）→ 输入 → 引擎 → 音频引擎 → Stats → 推送源。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherRender
import SwitcherInputs
import SwitcherControl

/// 观察者的凭据：释放即取消。
final class ObserverToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
    func invalidate() { cancel() }
}

@MainActor
final class SwitcherSession {
    /// 节目名（保存时用；录制文件名模板的 {show}）。
    var name: String {
        didSet { outputs.showName = name }
    }
    let format: ProgramFormat
    let settings: AppSettings
    let stateMachine: StateMachine
    let renderer: MetalRenderer
    let engine: Engine
    let inputs: InputRuntime
    let audio: AudioRuntime
    let outputs: OutputRuntime
    /// 外部显示窗口 + 虚拟摄像头（W3-C）。
    let aux: AuxOutputRuntime
    let control: ControlRuntime
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
    private var noticeObservers: [(key: UInt64, block: @MainActor (String) -> Void)] = []
    private var observerCounter: UInt64 = 0
    private func nextObserverKey() -> UInt64 {
        observerCounter &+= 1
        return observerCounter
    }
    private var statsHub: StatsHub?
    /// 已发出的命令数（测试看）。
    var commandsSent: UInt64 { control.commandsSent }
    /// 最近一条提示（命令被忽略 / 录制起停 / API 起不来……；测试看）。
    private(set) var lastNotice: String?

    /// 多画面 / 显示视图的纹理来源。
    var displaySource: any DisplayFrameSource { renderer }

    init(show: Show, settings: AppSettings = AppSettings(), inputFactory: any InputFactory = DefaultInputFactory(),
         hotkeyTable: HotkeyTable = HotkeyTable.loadUserTableOrDefault()) throws {
        let initial = show.makeState()
        try initial.validate()
        name = show.name
        layout = show.layout
        format = initial.format
        state = initial
        self.settings = settings
        renderer = try MetalRenderer()
        stateMachine = StateMachine(initialState: initial)
        let maxNumber = initial.inputs.map(\.number).max() ?? 1
        let engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
        self.engine = engine
        audio = AudioRuntime(stateMachine: stateMachine, device: settings.audioDevice)
        let inputs = InputRuntime(engine: engine, factory: inputFactory, audio: audio)
        self.inputs = inputs
        outputs = OutputRuntime(engine: engine, audio: audio, inputs: inputs, format: format, showName: show.name)
        outputs.fallbackDirectory = settings.recordFallbackDirectory
        outputs.minimumFreeBytes = UInt64(max(0, settings.recordMinimumFreeMB)) * 1024 * 1024
        aux = AuxOutputRuntime(engine: engine, source: renderer, format: format)
        control = ControlRuntime(stateMachine: stateMachine, engine: engine, api: settings.apiConfiguration, hotkeyTable: hotkeyTable)
        lastSnapshot = stateMachine.publisher.latest
        let audioEngine = audio.engine
        engine.audioStatsProvider = { audioEngine.audioCounters }
        engine.encoderStatsProvider = outputs.statsProvider
        control.onFeedback = { [weak self] feedback in self?.notify(feedback.message) }
        outputs.onEvent = { [weak self] event in self?.handle(outputEvent: event) }
        outputs.sendCommand = { [weak self] command in self?.send(command) }
        aux.onEvent = { [weak self] event in self?.handle(auxEvent: event) }
        aux.sendCommand = { [weak self] command in self?.send(command) }
        control.bus.addObserver(outputs.commandTicks)   // 起停命令的生效拍 → 录制起止拍
    }

    // MARK: 生命周期

    /// 起引擎：先按初始快照建好输入并注册，再起控制层 / 音频 / 引擎，再 start 输入（合成源到 t0 才出第一帧），最后按快照起输出。
    func start(leadMilliseconds: Double = 300) async throws {
        guard !isRunning else { return }
        t0 = HostClock.now() + HostDuration(milliseconds: leadMilliseconds)
        let spec = TickClockSpec(t0: t0, frameRate: format.frameRate)
        inputs.reconcile(state, timing: programTiming())
        await control.start()
        if let e = control.apiError { notify(e) }
        if let e = control.midiError { notify(e) }
        if let reason = audio.fallbackReason { notify(reason) }
        do {
            try await audio.start(clock: spec)
        } catch {
            notify("音频引擎起不来：\(error)")
        }
        try await engine.start(t0: t0)
        isRunning = true
        inputs.startAll()
        let hub = StatsHub(engine: engine, consumers: [
            { [weak self] stats in DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(stats: stats) } } },
            { [feed = control.feed] stats in feed.publish(stats: stats) },
        ])
        try hub.start()
        statsHub = hub
        outputs.clock = spec
        outputs.reconcile(state)
        aux.reconcile(state)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)   // 拖窗口 / 模态期间也要分发
        pollTimer = timer
    }

    /// 停：API → 输出封口 → Stats → 输入 → 引擎（排空在途帧）→ 音频引擎 → 推送源 / 命令循环。
    func stop() async {
        guard isRunning else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        await control.stopAPI()
        await outputs.stopAll()
        aux.stopAll()
        statsHub?.stop()
        statsHub = nil
        inputs.stopAll()
        await engine.stop()
        await audio.stop()
        await control.finish()
        isRunning = false
    }

    // MARK: 命令

    /// UI 唯一的写入口（→ CommandBus，来源 ui）。
    func send(_ command: Command) { control.send(command) }

    // MARK: 快照分发（≤ 60 Hz）

    private func pollSnapshot() {
        guard let snapshot = stateMachine.publisher.latest, snapshot !== lastSnapshot else { return }
        lastSnapshot = snapshot
        let newState = snapshot.state
        // 输入表的"编号 + 来源"变了才动运行表（改名 / 改设置不重建输入）
        let inputsChanged = !newState.inputs.map(\.number).elementsEqual(state.inputs.map(\.number))
            || !newState.inputs.map(\.source).elementsEqual(state.inputs.map(\.source))
        let outputsChanged = newState.outputs != state.outputs
        state = newState
        if inputsChanged { inputs.reconcile(newState, timing: programTiming()) }
        if outputsChanged { outputs.reconcile(newState) }
        if outputsChanged || inputsChanged { aux.reconcile(newState) }
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
    func startStatsLog(url: URL) throws { try statsHub?.startLog(url: url) }
    func stopStatsLog() { statsHub?.closeLog() }
    var statsLogURL: URL? { statsHub?.logURL }

    // MARK: 提示（状态行右侧）

    private func notify(_ message: String) {
        lastNotice = message
        NSLog("%@", message)
        for observer in noticeObservers { observer.block(message) }
    }

    @discardableResult
    func observeNotices(_ block: @escaping @MainActor (String) -> Void) -> ObserverToken {
        let key = nextObserverKey()
        noticeObservers.append((key, block))
        return ObserverToken { [weak self] in
            Task { @MainActor in self?.noticeObservers.removeAll { $0.key == key } }
        }
    }

    private func handle(outputEvent event: OutputRuntime.Event) {
        switch event {
        case .recordingStarted(let n, let url): notify("录制 \(n) 开始：\(url.lastPathComponent)")
        case .recordingStopped(let n, let url, let frames, let seconds): notify("录制 \(n) 已停：\(url.lastPathComponent)，\(frames) 帧 / \(String(format: "%.2f", seconds)) s")
        case .recordingFailed(_, let message): notify(message)
        case .recordingDiskLow(let n, let mb): notify("录制 \(n)：磁盘剩余 \(Int(mb)) MB")
        case .recordingSwitchedToFallback(let n, let url): notify("录制 \(n)：磁盘满，已切到备用目录：\(url.lastPathComponent)")
        case .streamStarted(let n): notify("推流 \(n) 开始")
        case .streamStopped(let n): notify("推流 \(n) 已停")
        case .streamFailed(_, let message): notify(message)
        }
    }

    private func handle(auxEvent event: AuxOutputRuntime.Event) {
        switch event {
        case .externalDisplay(let n, let status): notify("外部输出 \(n)：\(status)")
        case .virtualCameraStarted: notify("虚拟摄像头输出已启用")
        case .virtualCameraStopped: notify("虚拟摄像头输出已停")
        case .extensionStatus(let s): notify("虚拟摄像头扩展：\(s)")
        }
    }

    // MARK: 节目时钟

    /// 给输入的节目时钟（W2-A 的 ProgramTiming）：引擎已起 → t0 = "现在之后第 3 拍"（新加的路从最近的拍点开始，不用从 t0 追帧；
    /// 拍点仍在引擎的拍点网格上）；引擎未起 → 就是引擎的 t0。合成源视频在此基础上再提前半帧（DefaultInputFactory）。
    func programTiming() -> ProgramTiming {
        if let clock = engine.clock {
            let spec = clock.spec
            let next = spec.tick(at: HostClock.now()) + 3
            return ProgramTiming(format: format, t0: spec.time(of: next))
        }
        return ProgramTiming(format: format, t0: t0)
    }

    /// 当前状态存成节目文件。
    func makeShow() -> Show { Show(name: name, state: state, layout: layout) }
}
