// 主窗口（设计方案 §10）：NSSplitView 分区——上 PVW / PGM 双监 + 中间转场列，下输入缩略图条，右侧可收起的调音台，底部输出栏 + 状态行
// （W5-F：底栏按钮是"⚙ ｜ 主体 ｜ ▴"分体按钮，状态行独立成窗口最底一行；底栏的菜单 / 面板入口都从这里接到 session、面板总管与添加输入的本机记忆）。
// W5-G：标题栏那一行是工具条（MainToolbar，`.unified`）；监视器标题条的齿轮 / 右键接到面板总管与外部显示路由。工具条那一行算在窗口外框里：
// 最小窗口按"内容区仍是原来 1100×700 时那么大"定（macOS 27 上外框 1100×720），转场列 / 输入条 / 底栏在最小窗口里的保证不变。
// 绑定：所有子视图只拿 `send`（发 Command）和快照 / Stats 观察者；换 session 时 `bind(session:)` 重挂一遍。
import AppKit
import SwitcherContracts
import SwitcherRender
import SwitcherExternal

/// 能收键盘的主窗口：不被文本框吃掉的按键走快捷键表。
@MainActor
final class MainWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSSplitViewDelegate, NSWindowDelegate {
    let previewMonitor = MonitorView(target: .preview)
    let programMonitor = MonitorView(target: .program)
    let transitionPanel = TransitionPanelView(frame: .zero)
    let inputStrip = InputStripView(frame: .zero)
    let mixerPanel = MixerPanelView(frame: .zero)
    let bottomBar = BottomBarView(frame: .zero)
    /// 顶部工具条（W5-G）。
    let mainToolbar: MainToolbar
    private let outerSplit = NSSplitView()
    private let centerSplit = NSSplitView()
    private(set) var session: SwitcherSession?
    private var stateToken: ObserverToken?
    private var statsToken: ObserverToken?
    private var noticeToken: ObserverToken?
    private var meterToken: ObserverToken?
    private var externalMenuBuilder: ExternalOutputMenuBuilder?
    /// 最近一次从底栏弹出的菜单（模态；测试开着时量位置、量完 cancelTracking）。
    private(set) var activeBottomMenu: NSMenu?
    /// 上半区（双监 + 转场列）的最小高 = 转场列的最小高（W5-A 起 ≤ 409）。
    private lazy var monitorsMinimumHeight: CGFloat = max(300, transitionPanel.fittingSize.height)
    private(set) var multiviewWindow: MultiviewWindowController?
    /// 新 ISO 路的默认录制目录（AppController 按测试宿主 / 正常设）。
    var defaultRecordDirectory: String = ShowDocuments.defaultRecordDirectory
    private var addInputSheet: AddInputSheetController?
    /// 面板总管（AppController 挂上来；输入设置窗 / 多画面 / 外部显示菜单从这里开）。
    weak var panels: PanelCoordinator?
    /// 添加输入的本机记忆（上次的类型、最近添加的来源；AppController 挂上来，W5-F）。
    var addInputHistory: AddInputHistory?
    /// 收到的快照次数（测试看 ≤ 60 Hz 合并）。
    private(set) var snapshotsReceived: UInt64 = 0
    private var snapshotWindowStart = Date()
    private var snapshotsInWindow = 0
    /// 最近一秒内快照回调的最大次数（测试用）。
    private(set) var maxSnapshotsPerSecond = 0
    /// PGM 监视器的记账源（W3-E3：DisplayFrameLedger 夹在渲染器与显示视图之间，Stats.display[] 的 monitor 项从它来；显示视图对来源是弱引用，这里持有）。
    private(set) var programLedger: DisplayFrameLedger?
    /// 换 session（= 换渲染器）之前的旧账，累计值不回退（frames 用的 presentedFrames 本来就跨 session 累计）。
    private var retiredProgramDropped: UInt64 = 0
    private var retiredProgramUndelivered: UInt64 = 0
    nonisolated(unsafe) private var occlusionObserver: (any NSObjectProtocol)?

    /// 测试用：清零快照分发的计数，让一条用例只量自己（UISmokeTests 的"每秒最多 60 次"，用户 2026-09-24 选的做法 (a)；
    /// 计数原来跨用例累计、以事件为锚的 1 s 窗口偶发数到 61，W3-E2 报告 §5 第 13 条）。
    func resetSnapshotRateStats() {
        snapshotsReceived = 0
        snapshotWindowStart = Date()
        snapshotsInWindow = 0
        maxSnapshotsPerSecond = 0
    }

    /// 主窗口位置的存档名（正式 App；老存档照用）。
    static let autosaveName = "SwitcherMainWindow"

    /// 先按存档摆（位置 + 大小），没有存档才居中，再挂上存档名（W5-A / X45：原来挂了存档名又调 center()，只记住了大小，每次启动都回正中）。
    /// saving = false：只读存档、不挂存档名（之后改窗口不写回）。
    static func placeWindow(_ window: NSWindow, autosaveName: String, saving: Bool = true) {
        if !window.setFrameUsingName(autosaveName) { window.center() }
        if saving { window.setFrameAutosaveName(autosaveName) }
    }

    /// 最小窗口时内容区要有多大：没有工具条时 1100×700 的窗口里的内容区（W5-A 的转场列 / 输入条 / 底栏都按它排过）。
    static var minimumContentSize: NSSize {
        NSWindow.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable]).size
    }

    init() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        window.title = Self.windowTitle(showName: nil)   // 产品名 PlusMix（W4-D）
        // 工具条先挂上、再按存档摆：存档里的是带工具条的外框，反过来挂会让窗口每次启动都高一截
        let toolbar = MainToolbar()
        mainToolbar = toolbar
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumContentSize
        window.backgroundColor = Theme.windowBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        // 测试宿主的 bundle id 和正式 App 相同（同一个 defaults 域）：照读用户真 App 的存档（窗口落在用户平时看得见的那块屏上），
        // 但不挂存档名，用例改窗口大小不会写回去
        Self.placeWindow(window, autosaveName: Self.autosaveName, saving: !AppDelegate.isTestHost)
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        // 主窗口被遮住 / 最小化 / 到别的 Space（监视器的 display link 随之暂停）和露出来：断开 PGM 监视器的连续呈现，这段记 undelivered（提案 018）
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.programLedger?.breakRun(countingUndelivered: true) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// 主窗口标题："PlusMix 0.1.0 — 节目名"：产品名，保存 / 另存之后也是它（W5-B 修 X42：保存后曾被写成代码名）；没有节目只写产品名 + 版本。
    /// 未保存的改动不写进标题，用 window.isDocumentEdited 标（关闭按钮上的点，AppController 按"节目内容"判定）。
    static func windowTitle(showName: String?) -> String {
        let base = "\(ProductName.display) \(SwitcherVersion.current)"
        guard let showName else { return base }
        return "\(base) — \(showName)"
    }

    /// 关主窗口 = 退出（applicationShouldTerminateAfterLastWindowClosed）：走退出那一问（录制 / 推流在跑、未保存），窗口先不关（W5-B，与菜单"退出"同一口径）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    private func buildLayout() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.windowBackground.cgColor

        // 上：PVW | 转场列 | PGM
        let monitors = NSStackView(views: [previewMonitor, transitionPanel, programMonitor])
        monitors.orientation = .horizontal
        monitors.spacing = 2
        monitors.distribution = .fill
        monitors.translatesAutoresizingMaskIntoConstraints = false
        previewMonitor.widthAnchor.constraint(equalTo: programMonitor.widthAnchor).isActive = true

        // 中列 = 上（双监）/ 下（缩略图条）
        centerSplit.isVertical = false
        centerSplit.dividerStyle = .thin
        centerSplit.delegate = self
        centerSplit.addArrangedSubview(monitors)
        centerSplit.addArrangedSubview(inputStrip)
        centerSplit.translatesAutoresizingMaskIntoConstraints = false
        centerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        centerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        // 外层 = 中列 | 调音台（可收起）
        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.addArrangedSubview(centerSplit)
        outerSplit.addArrangedSubview(mixerPanel)
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        outerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        outerSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        content.addSubview(outerSplit)
        content.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            outerSplit.topAnchor.constraint(equalTo: content.topAnchor),
            outerSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outerSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outerSplit.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inputStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.inputStripMinimumHeight),
            mixerPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.mixerPanelWidth),
            monitors.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.layoutIfNeeded()
        // 输入条开始时 197 高（W5-A 原型实测的值）。原来写成"窗口外框高 − 底栏 − 230"，230 里暗含了 32 pt 的标题栏；W5-G 加了工具条之后
        // 那一行是 52 pt，输入条就少了 20、被下面的最大坐标夹到 189（全量第一遍 MainWindowLayoutTests 红出来的）。改按内容区算，和标题栏多高无关。
        centerSplit.setPosition(content.bounds.height - Theme.bottomBarHeight - Theme.inputStripInitialHeight - centerSplit.dividerThickness, ofDividerAt: 0)
        // 分隔条 1 pt 不算在调音台里（W5-A 量出 339，G6 追加 ③）
        outerSplit.setPosition(window.frame.width - Theme.mixerPanelWidth - outerSplit.dividerThickness, ofDividerAt: 0)

        // 工具条（W5-G）：外部显示▾ 弹底栏 ⚙ 外部显示同一个路由菜单；其余按钮是 nil target 的 AppDelegate 动作（与菜单栏同一项）
        mainToolbar.externalMenuProvider = { [weak self] in self?.externalOutputMenu() }
        mainToolbar.willPopUpMenu = { [weak self] menu in self?.activeBottomMenu = menu }
        // 监视器标题条（W5-G，B1–B3）：齿轮 / 右键"输入设置…"开这一路的输入设置；右键"全屏输出到 ▸"按外部显示路由的口径
        for monitor in [previewMonitor, programMonitor] {
            monitor.onOpenInputSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
            monitor.fullscreenMenu = { [weak self] source in self?.fullscreenMenu(source: source) }
        }
        transitionPanel.onNotice = { [weak self] message in self?.bottomBar.showNotice(message) }
        // 底栏（W5-F）：添加输入停在上次的类型 / ▴ 类型直达 + 最近添加；外部显示 ⚙ 路由菜单、主体全部开关；各 ⚙ 与菜单里的"…设置…"打开输出设置对应的页
        bottomBar.onAddInput = { [weak self] kind in self?.presentAddInput(kind: kind) }
        bottomBar.addInputMenu = { [weak self] in self?.addInputMenu() }
        bottomBar.onOverlayPanel = { [weak self] _ in self?.panels?.showOverlaySettings(channel: nil) }   // 叠加设置独立窗（W5-K / I1，原来是 transient 浮层）
        transitionPanel.onOverlaySettings = { [weak self] channel in self?.panels?.showOverlaySettings(channel: channel) }   // 右键"叠加设置…"直达第 k 路
        inputStrip.onOverlaySettings = { [weak self] channel in self?.panels?.showOverlaySettings(channel: channel) }
        bottomBar.externalMenu = { [weak self] in self?.externalOutputMenu() }
        bottomBar.onExternalToggle = { [weak self] in self?.toggleExternalDisplays() ?? true }
        bottomBar.onMultiview = { [weak self] in self?.toggleMultiviewWindow() }
        bottomBar.onOutputSettings = { [weak self] tab in self?.panels?.showOutputSettings(tab: tab) }
        bottomBar.onAddStreamDestination = { [weak self] in self?.panels?.showStreamAddDestination() }
        bottomBar.willPopUpMenu = { [weak self] menu in self?.activeBottomMenu = menu }
        inputStrip.onOpenSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
        mixerPanel.onOpenInputSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
        mixerPanel.onOpenAudioSettings = { [weak self] strip, page in self?.panels?.showAudioSettings(strip, page: page) }   // 条子齿轮 → 音频设置窗（W5-K / J2）
        mixerPanel.onMeters = { [weak self] levels in self?.inputStrip.applyAudioLevels(levels) }   // 纯音频输入格子的电平表
    }

    // MARK: 绑定

    func bind(session: SwitcherSession?) {
        stateToken?.invalidate()
        statsToken?.invalidate()
        noticeToken?.invalidate()
        meterToken?.invalidate()
        stateToken = nil
        statsToken = nil
        noticeToken = nil
        meterToken = nil
        self.session = session
        let send: ((Command) -> Void)? = session.map { s in { [weak s] c in s?.send(c) } }
        transitionPanel.send = send
        if let session { transitionPanel.hotkeyTable = session.control.hotkeyTable }
        inputStrip.send = send
        mixerPanel.send = send
        bottomBar.send = send
        inputStrip.runtimeState = session.map { s in { [weak s] n in s?.inputs.runtimeState(of: n) } }
        let source = session?.displaySource
        previewMonitor.display.source = source
        bindProgramLedger(to: source)
        inputStrip.displaySource = source
        multiviewWindow?.source = source
        bottomBar.resetStats()
        mixerPanel.clearMeters()
        // 底栏主体按钮：起不来的原因 / 推流正在第几次连接（运行表）、重试起不来的那几路（W5-B）
        bottomBar.routeDetail = session.map { s in { [weak s] n in (s?.outputs.failureReason(output: n), s?.outputs.streamConnectAttempt(output: n)) } }
        bottomBar.onRetryOutputs = session.map { s in { [weak s] numbers in s?.retryFailedOutputs(numbers) } }
        mainToolbar.setSessionAvailable(session != nil)   // 没有 session 时节目组以外置灰（W5-G）
        refreshToolbarStatus()
        guard let session else {
            window?.title = Self.windowTitle(showName: nil)
            return
        }
        inputStrip.setTextureSize(width: session.format.width, height: session.format.height)
        window?.title = Self.windowTitle(showName: session.name)
        stateToken = session.observeState { [weak self] state in self?.apply(state: state) }
        statsToken = session.observeStats { [weak self] stats in self?.apply(stats: stats) }
        noticeToken = session.observeNotices { [weak self] message in self?.bottomBar.showNotice(message) }
        // 调音台条子 / 纯音频缩略图的表：session 的 50 ms 分发（与多画面电平表同一份 AudioEngineStatus，W3-E3）
        meterToken = session.meterFeed.observe { [weak self] status in self?.mixerPanel.apply(audioStatus: status) }
        if let notice = session.lastNotice { bottomBar.showNotice(notice) }
        multiviewWindow?.restore(from: session.layout)
        // 提案 013：主界面 PGM 监视器（output 0）与多画面窗口的呈现帧数进 Stats.display[]
        session.aux.uiDisplayEntries = { [weak self] in self?.displayStatsEntries ?? [] }
    }

    /// PGM 监视器换来源（换 session）：记账源包住新的渲染器交给显示视图，旧账并进 retired。
    private func bindProgramLedger(to source: (any DisplayFrameSource)?) {
        retiredProgramDropped &+= programLedger?.droppedFrames ?? 0
        retiredProgramUndelivered &+= programLedger?.undeliveredFrames ?? 0
        if let source {
            let ledger = DisplayFrameLedger(upstream: source, view: programMonitor.display)
            programLedger = ledger
            programMonitor.display.source = ledger
        } else {
            programLedger = nil
            programMonitor.display.source = nil
        }
    }

    /// 界面上两个显示视图在 Stats 里的项（提案 013）：PGM 监视器 kind "monitor"、多画面窗口 kind "multiviewWindow"，都不是输出表里的输出，output 用 0。
    /// dropped / undelivered 走 DisplayFrameLedger（W3-E3，与外部显示窗口同一个记账源、同一口径）：dropped = 两次显示刷新之间被覆盖的版本，
    /// undelivered = 窗口被遮住 / 最小化期间渲染器出了、视图没画的版本（提案 018）。多画面窗口没开过不报，关着报 idle（关着的那段两样都不记）。
    var displayStatsEntries: [Stats.DisplayEntry] {
        var out = [Stats.DisplayEntry(output: 0, kind: "monitor", frames: programMonitor.display.presentedFrames,
                                      dropped: retiredProgramDropped &+ (programLedger?.droppedFrames ?? 0),
                                      undelivered: retiredProgramUndelivered &+ (programLedger?.undeliveredFrames ?? 0), state: "presenting")]
        if let w = multiviewWindow {
            out.append(Stats.DisplayEntry(output: 0, kind: "multiviewWindow", frames: w.displayView.presentedFrames,
                                          dropped: w.droppedFrames, undelivered: w.undeliveredFrames,
                                          state: w.isOpen ? "presenting" : "idle"))
        }
        return out
    }

    private func apply(state: MixerState) {
        snapshotsReceived &+= 1
        let now = Date()
        if now.timeIntervalSince(snapshotWindowStart) >= 1 {
            snapshotWindowStart = now
            snapshotsInWindow = 0
        }
        snapshotsInWindow += 1
        maxSnapshotsPerSecond = max(maxSnapshotsPerSecond, snapshotsInWindow)
        previewMonitor.apply(state: state)
        programMonitor.apply(state: state)
        transitionPanel.apply(state: state)
        inputStrip.apply(state: state)
        mixerPanel.apply(state: state)
        bottomBar.apply(state: state)
        mainToolbar.apply(state: state)
        refreshToolbarStatus()
    }

    private func apply(stats: Stats) {
        bottomBar.apply(stats: stats)
        refreshToolbarStatus()
        mixerPanel.apply(stats: stats)
    }

    /// 工具条右组的录制 / 推流状态与外部显示主体的提示：读底栏刚算好的同一份汇总（铁律 4，不另算）。没变就不动。
    private func refreshToolbarStatus() {
        mainToolbar.showOutputStatus(record: bottomBar.recordSummary, stream: bottomBar.streamSummary)
        mainToolbar.setExternalToolTip(bottomBar.external.bodyButton.toolTip)
    }

    // MARK: 快捷键（W2-C 的 HotkeyDispatcher：用户表 hotkeys.json，没有就默认表；命令来源 hotkey）

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        return session.control.handleKey(event)
    }

    // MARK: 面板

    /// 添加输入面板：kind = nil 停在上次添加用的类型（底栏主体、⌘I），给了就直达那一页（▴ / 菜单栏"按类型添加"，G1）。
    func presentAddInput(kind: AddInputModel.Kind? = nil) {
        guard let session, let window, addInputSheet == nil else { return }
        let initial = kind ?? addInputHistory?.lastKind ?? AddInputHistory.defaultKind
        let sheet = AddInputSheetController(state: session.state, maxInputs: session.engine.maxInputs, kind: initial, history: addInputHistory) { [weak self, weak session] config in
            session?.send(.addInput(config: config))
            self?.addInputHistory?.noteAdded(config)
        }
        addInputSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            MainActor.assumeIsolated { self?.addInputSheet = nil }
        }
    }

    /// 外部显示路由菜单（底栏"⚙ 外部显示" / 菜单栏"输出 › 外部显示 ▸"都用它；93 的工具条正中也用这一个）。
    func externalOutputMenu() -> NSMenu? {
        guard let session else { return nil }
        let builder = ExternalOutputMenuBuilder(state: session.state, displayStats: session.stats?.display ?? [])
        builder.send = { [weak session] c in session?.send(c) }
        builder.onOutputSettings = { [weak self] tab in self?.panels?.showOutputSettings(tab: tab) }
        externalMenuBuilder = builder   // 菜单项的 target 是它，得活到菜单关掉
        return builder.makeMenu()
    }

    /// 监视器右键"全屏输出到 ▸"：每块屏一项，来源 = 这个监视器（W5-G，B3；外部显示路由同一个构造器）。
    func fullscreenMenu(source: OutputSource) -> NSMenu? {
        guard let session else { return nil }
        let builder = ExternalOutputMenuBuilder(state: session.state, displayStats: session.stats?.display ?? [])
        builder.send = { [weak session] c in session?.send(c) }
        externalMenuBuilder = builder   // 菜单项的 target 是它，得活到菜单关掉
        return builder.fullscreenMenu(source: source)
    }

    /// 从某个按钮朝上弹外部显示菜单（整块在窗口里，X50）。
    func presentExternalMenu(relativeTo anchor: NSView) {
        guard let menu = externalOutputMenu() else { return }
        activeBottomMenu = menu
        BottomBarPopup.popUp(menu, from: anchor)
    }

    /// 外部显示主体（M1，04 Q03 第 3 条）：全部开 / 关、配置保留；一路都没配时在第一块非主屏上开 PGM。
    /// 返回 false = 一路都没配、也没有第二块屏（底栏弹路由菜单）。
    @discardableResult
    func toggleExternalDisplays() -> Bool {
        guard let session else { return true }
        let result = ExternalOutputMenuBuilder.toggleAll(state: session.state, displays: ExternalDisplays.all()) { [weak session] c in session?.send(c) }
        return result != .needsMenu
    }

    /// 添加输入 ▴ / 菜单栏"输入 › 按类型添加 ▸"（同一份，G1 / Q59）：八种类型直达（添加面板停在那一页）─ 最近添加的来源（一键再加一路：编号取空号、名字自动取）。
    func addInputMenu() -> NSMenu? {
        let menu = NSMenu(title: L("menu.input.addByType"))
        menu.autoenablesItems = false
        for kind in AddInputModel.Kind.displayOrder {   // 和添加面板左栏同一顺序（W5-K：分组，合成测试源在最后）
            menu.addItem(.action(L("addInputMenu.kind", kind.title)) { [weak self] in self?.presentAddInput(kind: kind) })
        }
        guard let session, let history = addInputHistory else { return menu }
        let recents = history.availableRecents
        guard !recents.isEmpty else { return menu }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L("addInputMenu.recent")))
        let full = Self.freeInputNumber(in: session.state, maxInputs: session.engine.maxInputs) == nil
        for source in recents {
            let tip = full ? L("addInput.full", session.engine.maxInputs) : L("addInputMenu.recentTip")
            menu.addItem(.action(AddInputHistory.title(of: source), enabled: !full, toolTip: tip) { [weak self] in self?.reAddInput(source) })
        }
        return menu
    }

    /// 最小的空号；用满了为 nil（已有输入不挪位，01 §6）。
    static func freeInputNumber(in state: MixerState, maxInputs: Int) -> Int? {
        let used = Set(state.inputs.map(\.number))
        return (1...max(1, maxInputs)).first { !used.contains($0) }
    }

    /// 一键再加一路最近添加过的来源：编号取空号，名字按类型自动取（和添加面板的默认名一样）。
    func reAddInput(_ source: InputSource) {
        guard let session else { return }
        guard let number = Self.freeInputNumber(in: session.state, maxInputs: session.engine.maxInputs) else {
            bottomBar.showNotice(L("addInput.full", session.engine.maxInputs))
            return
        }
        var model = AddInputModel(source: source)
        model.number = number
        let config = InputConfig(number: number, name: model.defaultName, source: source)
        session.send(.addInput(config: config))
        addInputHistory?.noteAdded(config)
    }

    /// 多画面独立窗口开 / 关（底栏主体开着时高亮；点窗口的关闭按钮也会告诉底栏，E3）。
    func toggleMultiviewWindow() {
        if multiviewWindow == nil {
            let w = MultiviewWindowController(source: session?.displaySource)
            if let session { w.restore(from: session.layout) }
            w.onOpenChange = { [weak self] open in self?.bottomBar.setMultiviewOpen(open) }
            multiviewWindow = w
        }
        multiviewWindow?.toggle()
    }

    var isMultiviewWindowVisible: Bool { multiviewWindow?.isShowing ?? false }

    /// 收起 / 展开调音台。
    func toggleMixerPanel() {
        let collapsed = outerSplit.isSubviewCollapsed(mixerPanel)
        if collapsed {
            outerSplit.setPosition(outerSplit.frame.width - Theme.mixerPanelWidth - outerSplit.dividerThickness, ofDividerAt: 0)
        } else {
            outerSplit.setPosition(outerSplit.frame.width, ofDividerAt: 0)
        }
    }

    var isMixerPanelVisible: Bool { !outerSplit.isSubviewCollapsed(mixerPanel) }

    /// 打开节目时按 Show.layout 恢复界面（W5-A / X47：这几个键原来只写不读）：调音台显隐、多画面窗口开关、主窗口位置。
    /// 没有的键不动；mainWindowFrame 落在现在的屏幕外（别的机器存的、那块屏拔了）就不用，大小不小于主窗口的最小尺寸。
    func applyLayout(_ layout: ShowLayout) {
        if case .bool(let visible)? = layout.values["mixerPanelVisible"], visible != isMixerPanelVisible { toggleMixerPanel() }
        if case .bool(let visible)? = layout.values["multiviewWindowVisible"], visible != isMultiviewWindowVisible { toggleMultiviewWindow() }
        if case .string(let text)? = layout.values["mainWindowFrame"], let window {
            var frame = NSRectFromString(text)
            frame.size.width = max(frame.width, window.minSize.width)
            frame.size.height = max(frame.height, window.minSize.height)
            let onScreen = NSScreen.screens.contains { screen in
                let visible = screen.visibleFrame.intersection(frame)
                return visible.width >= 200 && visible.height >= 100
            }
            if onScreen, frame != window.frame { window.setFrame(frame, display: true) }
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === mixerPanel
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === centerSplit ? monitorsMinimumHeight : 700
    }

    /// 窗口缩放时输入条和调音台保持原来的尺寸，差额都给上半区 / 中列（W5-A / X61：原来按比例缩，1100×700 时输入条只剩 133–143、调音台 216–259，
    /// 头行和格子按钮被切，日志里一串约束冲突）。拖分隔条不受影响。
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== inputStrip && view !== mixerPanel
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // 分隔条 1 pt 不算在输入条里（和调音台那边 G6 追加 ③ 同一个口径；原来拖到底输入条是 189）
        splitView === centerSplit ? splitView.frame.height - Theme.inputStripMinimumHeight - splitView.dividerThickness
                                  : splitView.frame.width - Theme.mixerPanelWidth - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }
}
