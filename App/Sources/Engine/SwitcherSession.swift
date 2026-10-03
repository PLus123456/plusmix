// 一次运行 = 一个节目文件跑起来：状态机 + 渲染器 + 引擎 + 各路输入 + 音频引擎 + 输出（录制 / 推流）+ 控制层（总线 / API / 快捷键 / MIDI）
// + Stats 采样（设计方案 §2、§9.1、§10）。W2-B2 把 G3 清单末表的七个接缝都接上了（docs/checklists/G3.md）。
//
// 绑定规则（W2-B prompt 第 3 条）：
// - UI 只发 Command（`send` → CommandBus，来源 ui），只读快照（`state`）和 Stats（`stats`），不碰引擎内部。
// - 快照变化经主线程分发：主线程每 1/60 s 看一次 `publisher.latest`，指针变了才通知观察者，所以每秒最多 60 次，
//   同一帧内的多次状态变化合并成一次（渲染线程 / 音频线程各自走 HazardPublisher 的实时读槽，与这里无关）。
// - 状态行 1 Hz：StatsPublisher 每秒一行，同一个 Stats 送 UI、stats.jsonl 和 API（铁律 4）。
//
// 起停顺序（W3-E6：慢活在定 t0 之前做完，reports/w1-core-3.md §5 第 1 条）：
//   预热（与节目时钟无关）：控制层（推送源、API、MIDI；进程里第一次连 MIDIServer ≈ 0.6 s）→ 引擎 warmUp（渲染器 prepare + 首帧空渲染、状态机线程、第 0 拍快照）。
//   起：（没预热就先预热）→ 定 t0 = now + 提前量 → 输入建好并注册（帧槽 → 引擎，音频环 → 音频引擎；输入按 t0 建时间线）
//      → 音频引擎 start(clock:) → 引擎 start(t0:)（这两步在同一个非主线程任务里接着做）→ 输入 start → Stats 采样 → 输出按快照起（录制 / 推流）。
//   停：tally 流（W5-L）→ API → 输出封口（录制到拍边界）→ Stats → 输入 → 引擎 → 音频引擎 → 推送源。只预热没起的、起到一半失败的也走同一条（没起的部分是空操作）；
//      预热 / 起进行中来停，等它在定 t0 之前的检查点停下再收。
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
    /// 生命周期阶段：idle（没起 / 已停）→ warm（控制层起了、引擎预热了，时钟没起）→ running。stop 按它收拾。
    enum Stage: Equatable { case idle, warm, running }
    private(set) var stage: Stage = .idle
    var isRunning: Bool { stage == .running }
    /// 引擎第 0 拍的时刻（start 定 t0 时定；只预热没起的为 .zero）。
    private(set) var t0: HostTime = .zero
    /// 最近一次起好的起步记录（start 成功后有；诊断 / 测试看）。
    private(set) var startReport: StartReport?
    /// 停机走过的几步（W5-L：tally → API → 引擎；测试看顺序）。
    enum StopStep: Equatable { case tally, api, engine }
    private(set) var stopSequence: [StopStep] = []

    /// 一次起步的记录（诊断，W3-E6）：各段耗时、定 t0 之后花掉多少提前量、引擎报的时钟起晚。W1-B3 当时靠临时探针才量到这几个数
    /// （reports/w1-core-3.md §1.1），现在每次起都记下并打一行日志；AppController 另存进程里第一次起好的那份（冷启动只在它身上）。
    struct StartReport: Equatable, Sendable {
        /// 控制层 start（推送源 / API / MIDI）。进程里第一次连 MIDIServer 时 ≈ 0.6 s。
        var controlMs: Double
        /// 引擎预热（渲染器 prepare + 首帧空渲染、状态机线程、第 0 拍快照）；0 = 没单独预热（在引擎 start 里顺带做了）。
        var warmUpMs: Double
        /// 建输入并注册（帧槽 → 引擎、音频环 → 音频引擎）。
        var inputsMs: Double
        /// 音频引擎 start(clock:)。
        var audioMs: Double
        /// 引擎 start(t0:)。
        var engineStartMs: Double
        /// 提前量：t0 = 定 t0 那一刻 + 它。
        var leadMs: Double
        /// 定 t0 之后到调引擎 start 之前花掉的时间（超过提前量，时钟就起在 t0 之后）。
        var spentAfterT0Ms: Double
        /// 引擎报的时钟起晚（Engine.clockStartLag）；准时为 0。
        var clockStartLagMs: Double
    }

    private var lastSnapshot: MixerSnapshot?
    private var pollTimer: Timer?
    /// warmUp / start / stop 串行：主线程上的 await 之间会交错（退出 App 时第一个会话可能还在起控制层），同一时刻只让一个在走。
    private var lifecycleBusy = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    /// 有 stop 在排队：进行中的 start 在定 t0 之前的检查点看到它就不起时钟，已起的部分由排着的 stop 收。
    private var stopRequested = false
    /// 预热两段的耗时（写进起步记录）。
    private var warmUpTimes: (controlMs: Double, warmUpMs: Double) = (0, 0)
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

    /// 素材（图片 / 视频文件）相对路径的基准目录：节目文件所在目录，没保存过 = 默认录制目录（W3-E5）。另存后 AppController 换成新位置，只影响之后建的输入。
    var mediaBaseDirectory: URL {
        get { inputs.mediaBaseDirectory }
        set { inputs.mediaBaseDirectory = newValue }
    }

    /// - Parameter mediaBaseDirectory: 素材相对路径的基准目录（nil = 默认录制目录 ~/Movies/PlusMix）。
    init(show: Show, settings: AppSettings = AppSettings(), inputFactory: any InputFactory = DefaultInputFactory(),
         hotkeyTable: HotkeyTable = HotkeyTable.loadUserTableOrDefault(), midiTable: MIDIMapTable = MIDIMapTable.loadUserTableOrDefault(),
         mediaBaseDirectory: URL? = nil) throws {
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
        let audio = AudioRuntime(stateMachine: stateMachine, device: settings.audioDevice, audioState: initial.audio, busOutputMap: settings.busOutputMap)
        self.audio = audio
        let inputs = InputRuntime(engine: engine, factory: inputFactory, audio: audio)
        if let mediaBaseDirectory { inputs.mediaBaseDirectory = mediaBaseDirectory }
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
                                 compat: settings.compatConfiguration, tally: settings.tallyConfiguration)
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

    /// 预热：定 t0 之前的慢活——控制层（推送源 / API / MIDI）+ 引擎 warmUp。幂等；start 没预热会自己调。
    /// 失败时把已起的部分收掉再抛；只预热没起的会话用 stop 收（engine.stop 放掉预热过的渲染器与状态机线程）。
    func warmUp() async throws {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        do { try await warmUpLocked() } catch {
            await teardownLocked()
            throw error
        }
    }

    private func warmUpLocked() async throws {
        guard stage == .idle else { return }
        let begin = HostClock.now()
        await control.start()   // 冷启动 ≈ 0.7 s（第一次连 MIDIServer 0.58 s）：以前排在定 t0 之后，吃掉 300 ms 提前量还起晚 400–500 ms
        let afterControl = HostClock.now()
        if let e = control.apiError { notify(e) }
        if let e = control.midiError { notify(e) }
        if let e = control.tallyError { notify(e) }
        stage = .warm   // 从这里起 stop 就有东西要收（引擎预热失败也一样）
        try await engine.warmUp()
        warmUpTimes = ((afterControl - begin).milliseconds, (HostClock.now() - afterControl).milliseconds)
    }

    /// 起引擎：（没预热先预热）→ 定 t0 → 按初始快照建好输入并注册 → 音频 / 引擎 → start 输入（合成源到 t0 才出第一帧）→ 按快照起输出。
    /// 定 t0 之后只剩建输入与两个 start（几十 ms，远小于提前量），时钟准时起在 t0 之前（W3-E6）。起到一半被 stop 叫停：在定 t0 之前停下、正常返回
    /// （isRunning 仍为 false，由排着的 stop 收）；失败：收掉已起的部分再抛。
    func start(leadMilliseconds: Double = 300) async throws {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        guard stage != .running else { return }
        do {
            try await warmUpLocked()
            // 定 t0 之前最后看一眼：有 stop 在排队（退出 App 时第一个会话还在起）就不起时钟
            if stopRequested { return }
            let begin = HostClock.now()
            t0 = begin + HostDuration(milliseconds: leadMilliseconds)
            let spec = TickClockSpec(t0: t0, frameRate: format.frameRate)
            inputs.reconcile(state, timing: programTiming())   // 输入按 t0 建时间线，只能在定 t0 之后
            let afterInputs = HostClock.now()
            if let reason = audio.fallbackReason { notify(reason) }
            let clockSide = try await Self.startClock(audio: audio, engine: engine, spec: spec)
            if let error = clockSide.audioError { notify(L("notice.audioFailed", "\(error)")) }
            record(StartReport(controlMs: warmUpTimes.controlMs, warmUpMs: warmUpTimes.warmUpMs, inputsMs: (afterInputs - begin).milliseconds,
                               audioMs: clockSide.audioMs, engineStartMs: clockSide.engineMs, leadMs: leadMilliseconds,
                               spentAfterT0Ms: (clockSide.engineCalledAt - begin).milliseconds, clockStartLagMs: engine.clockStartLag.milliseconds))
            stage = .running
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
        } catch {
            await teardownLocked()
            throw error
        }
    }

    /// 定 t0 之后、时钟起来之前的两步：音频引擎 start(clock:) → 引擎 start(t0:)。放在同一个非主线程任务里接着做、中间不回主线程——
    /// 主线程这时可能正忙（启动时建窗口 / 首次布局、测试宿主开跑用例），回一次主线程就可能把引擎的 start 往后拖、吃掉提前量。
    /// 音频引擎起不来不算错（节目照跑，同原来：带回原因，回主线程后提示）。
    private struct ClockSideStart: Sendable {
        var audioError: (any Error)?
        var audioMs: Double
        var engineMs: Double
        /// 调引擎 start 的时刻（起步记录的"定 t0 之后用掉多少"量到这里）。
        var engineCalledAt: HostTime
    }

    @concurrent
    private nonisolated static func startClock(audio: AudioRuntime, engine: Engine, spec: TickClockSpec) async throws -> ClockSideStart {
        let begin = HostClock.now()
        var audioError: (any Error)?
        do { try await audio.start(clock: spec) } catch { audioError = error }
        let engineCalledAt = HostClock.now()
        try await engine.start(t0: spec.t0)
        return ClockSideStart(audioError: audioError, audioMs: (engineCalledAt - begin).milliseconds,
                              engineMs: (HostClock.now() - engineCalledAt).milliseconds, engineCalledAt: engineCalledAt)
    }

    /// 记下起步记录并打一行日志（与 headless 起步时打的"t0 距现在 … ⚠️ 起晚了"同一个用途）。
    private func record(_ r: StartReport) {
        startReport = r
        NSLog("节目起步：控制层 %.1f ms、引擎预热 %.1f ms、输入 %.1f ms、音频 %.1f ms、引擎 start %.1f ms；定 t0 之后用掉 %.1f ms（提前量 %.0f ms），时钟起晚 %.1f ms",
              r.controlMs, r.warmUpMs, r.inputsMs, r.audioMs, r.engineStartMs, r.spentAfterT0Ms, r.leadMs, r.clockStartLagMs)
    }

    /// 停：tally → API → 输出封口 → Stats → 输入 → 引擎（排空在途帧）→ 音频引擎 → 推送源 / 命令循环。运行中、只预热没起的都能停；
    /// 预热 / 起进行中来停：先让它在定 t0 之前停下（已经定了 t0 就等它起完），再收。
    func stop() async {
        stopRequested = true
        await acquireLifecycle()
        defer {
            stopRequested = false
            releaseLifecycle()
        }
        await teardownLocked()
    }

    /// 按停的顺序收掉已起的部分（运行中、只预热没起、起到一半失败都走这里；没起的部分每一步都是空操作）。
    private func teardownLocked() async {
        guard stage != .idle else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        meterFeed.stop()   // 显式 setMeters(nil)：音频引擎要停了，多画面退回占位
        await control.stopTally()   // W5-L：只读 tally 流最先断
        stopSequence.append(.tally)
        await control.stopAPI()
        stopSequence.append(.api)
        await outputs.stopAll()
        aux.stopAll()
        statsHub?.stop()
        statsHub = nil
        inputs.stopAll()
        await engine.stop()   // 只预热没起的引擎也在这里放掉渲染器与状态机线程（Engine.stop 自己认）
        stopSequence.append(.engine)
        await audio.stop()
        await control.finish()
        stage = .idle
    }

    /// 轮到自己才返回（busy 在交接时保持 true）。
    private func acquireLifecycle() async {
        guard lifecycleBusy else {
            lifecycleBusy = true
            return
        }
        await withCheckedContinuation { lifecycleWaiters.append($0) }
    }

    private func releaseLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleBusy = false } else { lifecycleWaiters.removeFirst().resume() }
    }

    // MARK: 命令

    /// UI 唯一的写入口（→ CommandBus，来源 ui）。
    func send(_ command: Command) { control.send(command) }

    /// 重试起不来的录制 / 推流（底栏推流主体按钮、推流页"重试"；W5-B）。这几路的目标开关本来就是开着的（快照里 enabled 为真），
    /// 是运行表没把它们起来，所以不是一条命令，直接叫运行表再试；正常在跑的路不碰。
    func retryFailedOutputs(_ numbers: [Int]) { outputs.retry(numbers) }

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
        outputs.noteStats(stats)   // 推流第一次报 publishing → "已开始"（W5-B，X37）
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
        case .streamConnecting(let n): notify(L("notice.streamConnecting", n))
        case .streamStarted(let n): notify(L("notice.streamStarted", n))
        case .streamStopped(let n): notify(L("notice.streamStopped", n))
        case .streamFailed(_, let message): notify(message)
        case .ndiStarted(let n, let name): notify(L("notice.ndiStarted", n, name))
        case .ndiStopped(let n): notify(L("notice.ndiStopped", n))
        case .ndiFailed(_, let message): notify(message)
        case .ndiBranchRestored(let n, let m): notify(L("notice.ndiBranchRestored", n, m))
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
