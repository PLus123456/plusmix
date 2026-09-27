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
import SwitcherExternal   // AuxFrameTap（W3-C2 的 Aux 接线）
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
    /// 表读数的 50 ms 分发（W3-E3）：同一份 AudioEngineStatus 喂多画面电平表（renderer.setMeters）和调音台 / 缩略图的表。
    let meterFeed: AudioMeterFeed
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
         hotkeyTable: HotkeyTable = HotkeyTable.loadUserTableOrDefault(), midiTable: MIDIMapTable = MIDIMapTable.loadUserTableOrDefault()) throws {
        let initial = show.makeState()
        try initial.validate()
        name = show.name
        layout = show.layout
        format = initial.format
        state = initial
        self.settings = settings
        let renderer = try MetalRenderer(options: settings.rendererOptions)   // PVW 预览全部叠加（偏好设置）在这里定死，换 session 生效
        self.renderer = renderer
        stateMachine = StateMachine(initialState: initial)
        let maxNumber = initial.inputs.map(\.number).max() ?? 1
        let engine = Engine(stateMachine: stateMachine, renderer: renderer, maxInputs: max(16, maxNumber))
        self.engine = engine
        let audio = AudioRuntime(stateMachine: stateMachine, device: settings.audioDevice, audioState: initial.audio)
        self.audio = audio
        let inputs = InputRuntime(engine: engine, factory: inputFactory, audio: audio)
        self.inputs = inputs
        outputs = OutputRuntime(engine: engine, audio: audio, inputs: inputs, format: format, showName: show.name)
        outputs.fallbackDirectory = settings.recordFallbackDirectory
        outputs.minimumFreeBytes = UInt64(max(0, settings.recordMinimumFreeMB)) * 1024 * 1024
        aux = AuxOutputRuntime(engine: engine, source: renderer, format: format)
        // W3-C2：Aux = 本包自己画输入帧。每个 Aux 窗口给那一路开一个 InputFrameTee 分支（与 ISO 共用每路 4 个的额度），窗口换输入 / 关掉时还回去；
        // 占位与多画面缩略格子同一个来源、同一句文案（reports/issues/W3C2-app-aux-wiring.md，G4 续做合入时接的胶水）
        aux.external.auxFrames = AuxFrameTap(
            open: { [weak inputs] n in inputs?.openBranch(input: n) },
            close: { [weak inputs] n, slot in if let s = slot as? LockFreeFrameSlot { inputs?.releaseBranch(s, input: n) } })
        aux.external.inputStateProvider = { [weak inputs] n in inputs?.runtimeState(of: n) }
        aux.external.noSignalText = L("input.noSignal")
        // 外部输出开在主屏上时盖不盖住主界面（偏好设置，本机选项、不进节目文件；W3-E3）
        aux.external.mainScreenLayering = settings.externalMainScreenLayering
        aux.external.windowTitle = L("aux.external.windowTitle")   // W3-C3：包里的默认标题是 ASCII
        control = ControlRuntime(stateMachine: stateMachine, engine: engine, api: settings.apiConfiguration, hotkeyTable: hotkeyTable, midiTable: midiTable,
                                 compat: settings.compatConfiguration)
        meterFeed = AudioMeterFeed(status: { audio.status }, sink: { meters, at in renderer.setMeters(meters, at: at) })
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
            notify(L("notice.audioFailed", "\(error)"))
        }
        try await engine.start(t0: t0)
        isRunning = true
        inputs.startAll()
        // 多画面电平表不再挂在这里 1 Hz 喂（G4 检查点的胶水），改由 meterFeed 按 50 ms 的 AudioEngineStatus 喂（W3-E3）
        let hub = StatsHub(engine: engine, consumers: [
            { [weak self] stats in DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(stats: stats) } } },
            { [feed = control.feed] stats in feed.publish(stats: stats) },
        ])
        try hub.start()
        statsHub = hub
        meterFeed.start()
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
        meterFeed.stop()   // 显式 setMeters(nil)：音频引擎要停了，多画面退回占位
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
        statsHub?.update(displays: aux.statsEntries)   // 提案 013：显示类输出的读数进同一行 Stats（每次轮询都刷，不等快照变）
        guard let snapshot = stateMachine.publisher.latest, snapshot !== lastSnapshot else { return }
        lastSnapshot = snapshot
        let newState = snapshot.state
        // 输入表的"编号 + 来源"变了才动运行表（改名 / 改设置不重建输入）
        let inputsChanged = !newState.inputs.map(\.number).elementsEqual(state.inputs.map(\.number))
            || !newState.inputs.map(\.source).elementsEqual(state.inputs.map(\.source))
        let outputsChanged = newState.outputs != state.outputs
        state = newState
        if inputsChanged { inputs.reconcile(newState, timing: programTiming()) }
        // 输入表变了也让输出运行表看一眼：源是输入 n 的 NDI 发送要跟着那一路换 tee（运行表其余部分幂等）
        if outputsChanged || inputsChanged { outputs.reconcile(newState) }
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
        case .recordingStarted(let n, let url): notify(L("notice.recordingStarted", n, url.lastPathComponent))
        case .recordingStopped(let n, let url, let frames, let seconds): notify(L("notice.recordingStopped", n, url.lastPathComponent, Int(frames), seconds))
        case .recordingFailed(_, let message): notify(message)
        case .recordingDiskLow(let n, let mb): notify(L("notice.recordingDiskLow", n, Int(mb)))
        case .recordingSwitchedToFallback(let n, let url): notify(L("notice.recordingFallback", n, url.lastPathComponent))
        case .streamStarted(let n): notify(L("notice.streamStarted", n))
        case .streamStopped(let n): notify(L("notice.streamStopped", n))
        case .streamFailed(_, let message): notify(message)
        case .ndiStarted(let n, let name): notify(L("notice.ndiStarted", n, name))
        case .ndiStopped(let n): notify(L("notice.ndiStopped", n))
        case .ndiFailed(_, let message): notify(message)
        }
    }

    private func handle(auxEvent event: AuxOutputRuntime.Event) {
        switch event {
        case .externalDisplay(let n, let status): notify(L("notice.externalDisplay", n, OutputStatusText.externalWindow(status)))
        case .virtualCameraStarted: notify(L("notice.virtualCameraStarted"))
        case .virtualCameraStopped: notify(L("notice.virtualCameraStopped"))
        case .extensionStatus(let s): notify(L("notice.virtualCameraExtension", OutputStatusText.extensionStatus(s)))
        }
    }

    /// 虚拟摄像头输出的一行状态（菜单的状态行 / 输出设置页）：读 Stats.display[] 里它那一项（提案 013，铁律 4）。
    var virtualCameraStatusText: String {
        let output = state.outputs.first { $0.kind == .virtualCamera && $0.enabled }
        let entry = output.flatMap { o in stats?.display.first { $0.kind == "virtualCamera" && $0.output == o.number } }
        return OutputStatusText.virtualCamera(enabled: output != nil, entry: entry)
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

    /// 没有 session 时给面板用的空状态机（MIDI 映射面板要一个 MIDIController）。
    static func detachedStateMachine() -> StateMachine { StateMachine(initialState: MixerState()) }
}
