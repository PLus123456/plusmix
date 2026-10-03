// 主窗口（设计方案 §10）：NSSplitView 分区——上 PVW / PGM 双监 + 中间转场列，下输入缩略图条，右侧可收起的调音台，底部输出栏 + 状态行
// （W5-F：底栏按钮是"⚙ ｜ 主体 ｜ ▴"分体按钮，状态行独立成窗口最底一行；底栏的菜单 / 面板入口都从这里接到 session、面板总管与添加输入的本机记忆）。
// W5-G：标题栏那一行是工具条（MainToolbar，`.unified`）；监视器标题条的齿轮 / 右键接到面板总管与外部显示路由。工具条那一行算在窗口外框里：
// 最小窗口按"内容区仍是原来 1100×700 时那么大"定（macOS 27 上外框 1100×720），转场列 / 输入条 / 底栏在最小窗口里的保证不变。
// W5-H：输入条的占位格 / 拖放 / 分类 / 缩略图三档接到这里（分类存 Show.layout，见 InputCategories；缩略图大小存本机）；输入条最小高跟格子算，
// 最小窗口在大档放不下时跟着长高（中 / 小档仍是 W5-G 定的内容区 668）。
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
    // 分隔视图里这两块开始时给个像样的 frame：NSSplitView 按当时的 frame 生成自动尺寸约束，0 高 / 0 宽会和它们自己的最小高 / 宽撞，
    // 启动时日志里一串约束冲突（W5-G 报告 §5 第 9 条，W5-H 修）
    let inputStrip = InputStripView(frame: NSRect(x: 0, y: 0, width: 1100, height: Theme.inputStripInitialHeight))
    let mixerPanel = MixerPanelView(frame: NSRect(x: 0, y: 0, width: Theme.mixerPanelWidth, height: 600))
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
    /// 叠加面板（底栏右组"叠加"弹出，W5-F 起是 BottomBarPanel：贴按钮上沿、整块在窗口里）。
    private var overlayPanel: BottomBarPanel?
    private var externalMenuBuilder: ExternalOutputMenuBuilder?
    /// 最近一次从底栏弹出的菜单（模态；测试开着时量位置、量完 cancelTracking）。
    private(set) var activeBottomMenu: NSMenu?
    /// 上半区（双监 + 转场列）的最小高 = 转场列的最小高（W5-A 起 ≤ 409）。
    private lazy var monitorsMinimumHeight: CGFloat = max(300, transitionPanel.fittingSize.height)
    private(set) var multiviewWindow: MultiviewWindowController?
    /// 新 ISO 路的默认录制目录（AppController 按测试宿主 / 正常设）。
    var defaultRecordDirectory: String = ShowDocuments.defaultRecordDirectory
    /// 叠加面板（弹出期间存在；测试驱动它的模型）。
    private(set) var overlayPanelController: OverlayPanelController?
    private var addInputSheet: AddInputSheetController?
    /// 面板总管（AppController 挂上来；输入设置窗 / 多画面 / 外部显示菜单从这里开）。
    weak var panels: PanelCoordinator?
    /// 添加输入的本机记忆（上次的类型、最近添加的来源；AppController 挂上来，W5-F）。
    var addInputHistory: AddInputHistory?
    /// 输入条的本机偏好（缩略图大小；AppController 挂上来，W5-H）。
    var stripPreferences: InputStripPreferences? {
        didSet { if let stripPreferences { applyThumbnailSize(stripPreferences.thumbnailSize) } }
    }
    /// 节目内容在快照以外变了（分类存在 Show.layout 里，W5-H）：AppController 重算未保存。
    var onDocumentContentChanged: (() -> Void)?
    /// 输入条最小高的约束（跟格子大小变，W5-H）。
    private var inputStripMinimumConstraint: NSLayoutConstraint?
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
            mixerPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.mixerPanelWidth),
            monitors.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        // 999 不是 required：输入条的 frame 由分隔视图直接设（自动尺寸约束是 required），换缩略图大小那一下两条 required 会在日志里撞；
        // 真正守最小高的是分隔条的 constrainMaxCoordinate、最小窗口与 updateInputStripMinimum
        let stripMinimum = inputStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: inputStrip.minimumHeight)
        stripMinimum.priority = NSLayoutConstraint.Priority(999)
        stripMinimum.isActive = true
        inputStripMinimumConstraint = stripMinimum
        window.layoutIfNeeded()
        // 输入条开始时 197 高（W5-A 原型实测的值）。原来写成"窗口外框高 − 底栏 − 230"，230 里暗含了 32 pt 的标题栏；W5-G 加了工具条之后
        // 那一行是 52 pt，输入条就少了 20、被下面的最大坐标夹到 189（全量第一遍 MainWindowLayoutTests 红出来的）。改按内容区算，和标题栏多高无关。
        // W5-H：格子多了一行按钮、缩略图框按裁切比例变矮，"中"档贴着格子的高仍是 197（inputStripPreferredHeight）
        centerSplit.setPosition(content.bounds.height - Theme.bottomBarHeight - max(Theme.inputStripInitialHeight, inputStripPreferredHeight) - centerSplit.dividerThickness,
                                ofDividerAt: 0)
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
        bottomBar.onOverlayPanel = { [weak self] anchor in self?.presentOverlayPanel(relativeTo: anchor) }
        bottomBar.externalMenu = { [weak self] in self?.externalOutputMenu() }
        bottomBar.onExternalToggle = { [weak self] in self?.toggleExternalDisplays() ?? true }
        bottomBar.onMultiview = { [weak self] in self?.toggleMultiviewWindow() }
        bottomBar.onOutputSettings = { [weak self] tab in self?.panels?.showOutputSettings(tab: tab) }
        bottomBar.onAddStreamDestination = { [weak self] in self?.panels?.showStreamAddDestination() }
        bottomBar.willPopUpMenu = { [weak self] menu in self?.activeBottomMenu = menu }
        inputStrip.onOpenSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
        // 输入条（W5-H）：换来源… 直达输入设置的"来源"一节；占位格 = 添加输入主体；拖文件直接加；分类写回 Show.layout；三档存本机
        inputStrip.onChangeSource = { [weak self] number in self?.panels?.showInputSettings(input: number)?.model.section = .source }
        inputStrip.onAddInput = { [weak self] in self?.presentAddInput() }
        inputStrip.onDropFiles = { [weak self] result in self?.addInputs(from: result) }
        inputStrip.onNotice = { [weak self] message in self?.bottomBar.showNotice(message) }
        inputStrip.onCategoriesChange = { [weak self] categories in self?.storeCategories(categories) }
        inputStrip.onRenameCategory = { [weak self] color in self?.presentRenameCategory(color) }
        inputStrip.onClearCategoryName = { [weak self] color in self?.renameCategory(color, to: "") }
        inputStrip.onThumbnailSizeChange = { [weak self] size in self?.setThumbnailSize(size) }
        inputStrip.onMinimumHeightChange = { [weak self] in self?.updateInputStripMinimum() }
        inputStrip.setMixerVisible(isMixerPanelVisible)
        mixerPanel.onOpenInputSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
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
        overlayPanel?.close()   // 叠加面板的模型绑的是旧 session（W5-F 起它不像 NSPopover 那样碰一下别处就自己收）
        let send: ((Command) -> Void)? = session.map { s in { [weak s] c in s?.send(c) } }
        transitionPanel.send = send
        if let session { transitionPanel.hotkeyTable = session.control.hotkeyTable }
        inputStrip.send = send
        // 分类先换成新节目的（快照观察者一挂上就会回调一次：先挂会把旧节目的分类按新输入表清理后写进新节目）
        inputStrip.categories = session.map { InputCategories(layout: $0.layout.values) } ?? InputCategories()
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
        session?.control.onUIAction = { [weak self] name in self?.perform(uiAction: name) }   // 快捷键 / MIDI 绑的界面动作（W5-J / Q53）
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
        overlayPanelController?.apply(state: state)
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
        let initial = kind ?? addInputHistory?.lastKind ?? .synthetic
        let sheet = AddInputSheetController(state: session.state, maxInputs: session.engine.maxInputs, kind: initial) { [weak self, weak session] config in
            session?.send(.addInput(config: config))
            self?.addInputHistory?.noteAdded(config)
        }
        addInputSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            MainActor.assumeIsolated { self?.addInputSheet = nil }
        }
    }

    func presentOverlayPanel(relativeTo anchor: NSView) {
        guard let session else { return }
        if let overlayPanel {
            let wasOpen = overlayPanel.isVisible
            overlayPanel.close()
            if wasOpen { return }   // 再点一次 = 收起
        }
        let controller = OverlayPanelController(state: session.state)
        controller.send = { [weak session] c in session?.send(c) }
        // 内容尺寸 400 × min(640, 窗口内容高 − 120)：原来没设，NSPopover 把 400×640 的表单压进 320×320，每行标签头一两个字被裁（X63）
        controller.preferredContentSize = BottomBarPopup.overlayPanelSize(windowContentHeight: window?.contentLayoutRect.height ?? 900)
        // 朝上开、整块在窗口里（W5-A 原来用 NSPopover；W5-F 叠加挪到右组以后 NSPopover 以按钮为中心会伸出窗口右沿，换成 BottomBarPanel）
        let panel = BottomBarPanel(content: controller)
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.overlayPanel === panel else { return }
            self.overlayPanel = nil
            self.overlayPanelController = nil
        }
        panel.show(from: anchor)
        overlayPanel = panel
        overlayPanelController = controller
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
        for kind in AddInputModel.Kind.allCases {
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
    /// 快捷键 / MIDI 音符绑的界面动作（W5-J / Q53，UIAction）：显示 / 隐藏调音台、多画面窗口开关、多画面窗口全屏。认不出的名字（手写的表）状态行提示。
    func perform(uiAction name: String) {
        switch UIAction(rawValue: name) {
        case .toggleMixer?: toggleMixerPanel()
        case .toggleMultiviewWindow?: toggleMultiviewWindow()
        case .fullscreenMultiview?:
            if !isMultiviewWindowVisible { toggleMultiviewWindow() }
            multiviewWindow?.window?.toggleFullScreen(nil)
        case nil: bottomBar.showNotice(L("notice.unknownUIAction", name))
        }
    }

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

    // MARK: 输入条（W5-H）

    /// 视频 / 图片文件直接加一路（拖到输入条 / 占位格，G13）：编号依次取空号、名字用文件名、不弹面板；视频 = 文件输入（循环、1 倍速，同添加面板默认），
    /// 图片 = 图片输入。不认得的文件跳过、状态行说一句；号用满了停下并提示。返回发出去的配置。
    @discardableResult
    func addInputs(from drop: MediaFileDrop.Result) -> [InputConfig] {
        guard let session else { return [] }
        var used = Set(session.state.inputs.map(\.number))
        var added: [InputConfig] = []
        for file in drop.accepted {
            guard let number = (1...max(1, session.engine.maxInputs)).first(where: { !used.contains($0) }) else {
                bottomBar.showNotice(L("addInput.full", session.engine.maxInputs))
                return added
            }
            var model = AddInputModel()
            model.number = number
            switch file.kind {
            case .video:
                model.kind = .file
                model.filePath = file.url.path
            case .image:
                model.kind = .image
                model.imagePath = file.url.path
            }
            guard let config = try? model.makeConfig() else { continue }
            used.insert(number)
            session.send(.addInput(config: config))
            addInputHistory?.noteAdded(config)
            added.append(config)
        }
        if !drop.skipped.isEmpty {
            bottomBar.showNotice(L("strip.drop.skipped", drop.skipped.count, drop.skipped.map(\.lastPathComponent).joined(separator: L("list.separator"))))
        }
        return added
    }

    /// 分类数据写回 Show.layout（键见 InputCategories），算节目内容。
    private func storeCategories(_ categories: InputCategories) {
        guard let session else { return }
        var values = session.layout.values
        categories.write(into: &values)
        guard values != session.layout.values else { return }
        session.layout = ShowLayout(values: values)
        onDocumentContentChanged?()
    }

    /// 分类改名（空 = 清除名字，回到"红色"这样的叫法）。
    func renameCategory(_ color: InputCategories.Color, to name: String) {
        var categories = inputStrip.categories
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        categories.names[color] = trimmed.isEmpty ? nil : trimmed
        inputStrip.categories = categories
        storeCategories(categories)
    }

    /// 分类标签右键"改名…"：sheet 里一个文本框（空着 = 清除名字）。
    func presentRenameCategory(_ color: InputCategories.Color) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("category.renameTitle", color.defaultTitle)
        alert.informativeText = L("category.renameInfo")
        let field = NSTextField(string: inputStrip.categories.names[color] ?? "")
        field.placeholderString = color.defaultTitle
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel(L("category.renameField"))
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.renameCategory(color, to: field.stringValue)
            }
        }
    }

    /// 缩略图三档（输入条右键 / 窗口 › 输入缩略图 ▸）：存本机，马上生效，输入条贴回格子的高。
    func setThumbnailSize(_ size: ThumbnailSize) {
        stripPreferences?.thumbnailSize = size
        applyThumbnailSize(size)
    }

    private func applyThumbnailSize(_ size: ThumbnailSize) {
        inputStrip.thumbnailSize = size
        fitInputStrip()
    }

    /// 输入条贴着格子的高：最小高 + 2（"中"档 = 197，W5-A 定的初始高）。
    private var inputStripPreferredHeight: CGFloat { inputStrip.minimumHeight + 2 }

    /// 分隔条挪到"输入条 = 贴着格子的高"（换缩略图大小时：大档换回中档不留一截空，最小窗口里上半区也不被挤）。拖分隔条得到的高度留到下次换大小。
    private func fitInputStrip() {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard centerSplit.frame.height > 0, abs(inputStrip.frame.height - inputStripPreferredHeight) > 0.5 else { return }
        centerSplit.setPosition(max(monitorsMinimumHeight, centerSplit.frame.height - inputStripPreferredHeight - centerSplit.dividerThickness), ofDividerAt: 0)
    }
    private var protectingMonitorsHeight = false

    /// 输入条最小高跟格子变（三档 / 裁切比例）：约束、分隔条、最小窗口一起跟上。中 / 小档在 W5-G 定的最小内容区（668）里放得下，
    /// 大档放不下时最小窗口跟着长高（窗口现在比它矮就长高到它）；输入条比新的最小高矮时分隔条往上挪。
    private func updateInputStripMinimum() {
        let minimum = inputStrip.minimumHeight
        guard let window, let content = window.contentView else {
            inputStripMinimumConstraint?.constant = minimum
            return
        }
        var size = Self.minimumContentSize
        size.height = max(size.height, ceil(monitorsMinimumHeight + centerSplit.dividerThickness + minimum + Theme.bottomBarHeight))
        if window.contentMinSize != size { window.contentMinSize = size }
        if content.bounds.height < size.height {
            var frame = window.frame
            let grow = size.height - content.bounds.height
            frame.origin.y -= grow
            frame.size.height += grow
            window.setFrame(frame, display: true)
            content.layoutSubtreeIfNeeded()
        }
        // 先挪分隔条、再改约束：反过来那一次布局里格子已经变高、输入条还是原来的高
        if inputStrip.frame.height < minimum - 0.5, centerSplit.frame.height > 0 {
            centerSplit.setPosition(centerSplit.frame.height - minimum - centerSplit.dividerThickness, ofDividerAt: 0)
        }
        inputStripMinimumConstraint?.constant = minimum
    }

    /// 收起 / 展开调音台。
    func toggleMixerPanel() {
        let collapsed = outerSplit.isSubviewCollapsed(mixerPanel)
        if collapsed {
            outerSplit.setPosition(outerSplit.frame.width - Theme.mixerPanelWidth - outerSplit.dividerThickness, ofDividerAt: 0)
        } else {
            outerSplit.setPosition(outerSplit.frame.width, ofDividerAt: 0)
        }
        inputStrip.setMixerVisible(isMixerPanelVisible)
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
        splitView === centerSplit ? splitView.frame.height - inputStrip.minimumHeight - splitView.dividerThickness
                                  : splitView.frame.width - Theme.mixerPanelWidth - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }

    /// 拖分隔条把调音台收起 / 拉出来：输入条右端的"调音台"开关跟着亮灭（W5-H）。
    /// 窗口缩小时输入条保持原高（差额给上半区）；上半区因此放不下转场列、而输入条又比它的最小高高（拖高过、大档换回中档）时，
    /// 先让输入条退回最小高——转场列不被压扁（V-32 那类），输入条最下一行按钮仍点得到。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView else { return }
        if split === outerSplit {
            inputStrip.setMixerVisible(isMixerPanelVisible)
            return
        }
        guard split === centerSplit, !protectingMonitorsHeight, let upper = centerSplit.arrangedSubviews.first else { return }
        let slack = inputStrip.frame.height - inputStrip.minimumHeight
        guard upper.frame.height < monitorsMinimumHeight - 0.5, slack > 0.5 else { return }
        protectingMonitorsHeight = true
        centerSplit.setPosition(min(monitorsMinimumHeight, centerSplit.frame.height - inputStrip.minimumHeight - centerSplit.dividerThickness), ofDividerAt: 0)
        protectingMonitorsHeight = false
    }
}
