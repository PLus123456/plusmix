// 主窗口（设计方案 §10）：NSSplitView 分区——上 PVW / PGM 双监 + 中间转场列，下输入缩略图条，右侧可收起的调音台，底部输出栏 + 状态行。
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
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    let previewMonitor = MonitorView(target: .preview)
    let programMonitor = MonitorView(target: .program)
    let transitionPanel = TransitionPanelView(frame: .zero)
    let inputStrip = InputStripView(frame: .zero)
    let mixerPanel = MixerPanelView(frame: .zero)
    let bottomBar = BottomBarView(frame: .zero)
    private let outerSplit = NSSplitView()
    private let centerSplit = NSSplitView()
    private(set) var session: SwitcherSession?
    private var stateToken: ObserverToken?
    private var statsToken: ObserverToken?
    private var noticeToken: ObserverToken?
    private var meterToken: ObserverToken?
    private var overlayPopover: NSPopover?
    private var externalMenuBuilder: ExternalOutputMenuBuilder?
    private(set) var multiviewWindow: MultiviewWindowController?
    /// 新 ISO 路的默认录制目录（AppController 按测试宿主 / 正常设）。
    var defaultRecordDirectory: String = ShowDocuments.defaultRecordDirectory
    /// 叠加面板（弹出期间存在；测试驱动它的模型）。
    private(set) var overlayPanelController: OverlayPanelController?
    private var addInputSheet: AddInputSheetController?
    /// 面板总管（AppController 挂上来；输入设置窗 / 多画面 / 外部显示菜单从这里开）。
    weak var panels: PanelCoordinator?
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

    init() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        window.title = "Switcher \(SwitcherVersion.current)"
        window.minSize = NSSize(width: 1100, height: 700)
        window.backgroundColor = Theme.windowBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SwitcherMainWindow")
        super.init(window: window)
        buildLayout()
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.center()
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
            inputStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            mixerPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.mixerPanelWidth),
            monitors.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.layoutIfNeeded()
        centerSplit.setPosition(window.frame.height - Theme.bottomBarHeight - 230, ofDividerAt: 0)
        outerSplit.setPosition(window.frame.width - Theme.mixerPanelWidth, ofDividerAt: 0)

        bottomBar.onAddInput = { [weak self] in self?.presentAddInput() }
        bottomBar.onOverlayPanel = { [weak self] anchor in self?.presentOverlayPanel(relativeTo: anchor) }
        bottomBar.onExternalMenu = { [weak self] anchor in self?.presentExternalMenu(relativeTo: anchor) }
        bottomBar.onMultiview = { [weak self] in self?.toggleMultiviewWindow() }
        bottomBar.onISOSettings = { [weak self] in self?.panels?.showOutputSettings(tab: .iso) }   // ISO 只留输出设置里那一页（W3-E2）
        inputStrip.onOpenSettings = { [weak self] number in self?.panels?.showInputSettings(input: number) }
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
        let send: ((Command) -> Void)? = session.map { s in { [weak s] c in s?.send(c) } }
        transitionPanel.send = send
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
        guard let session else {
            window?.title = "Switcher \(SwitcherVersion.current)"
            return
        }
        inputStrip.setTextureSize(width: session.format.width, height: session.format.height)
        window?.title = "Switcher \(SwitcherVersion.current) — \(session.name)"
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
        overlayPanelController?.apply(state: state)
    }

    private func apply(stats: Stats) {
        bottomBar.apply(stats: stats)
        mixerPanel.apply(stats: stats)
    }

    // MARK: 快捷键（W2-C 的 HotkeyDispatcher：用户表 hotkeys.json，没有就默认表；命令来源 hotkey）

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        return session.control.handleKey(event)
    }

    // MARK: 面板

    func presentAddInput() {
        guard let session, let window, addInputSheet == nil else { return }
        let sheet = AddInputSheetController(state: session.state, maxInputs: session.engine.maxInputs) { [weak session] config in
            session?.send(.addInput(config: config))
        }
        addInputSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            MainActor.assumeIsolated { self?.addInputSheet = nil }
        }
    }

    func presentOverlayPanel(relativeTo anchor: NSView) {
        guard let session else { return }
        if let overlayPopover, overlayPopover.isShown {
            overlayPopover.close()
            return
        }
        let controller = OverlayPanelController(state: session.state)
        controller.send = { [weak session] c in session?.send(c) }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        overlayPopover = popover
        overlayPanelController = controller
    }

    /// 外部输出菜单（底栏按钮 / 菜单栏都用它）。
    func externalOutputMenu() -> NSMenu? {
        guard let session else { return nil }
        let builder = ExternalOutputMenuBuilder(state: session.state, displayStats: session.stats?.display ?? [])
        builder.send = { [weak session] c in session?.send(c) }
        externalMenuBuilder = builder   // 菜单项的 target 是它，得活到菜单关掉
        return builder.makeMenu()
    }

    func presentExternalMenu(relativeTo anchor: NSView) {
        guard let menu = externalOutputMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    /// 多画面独立窗口开 / 关。
    func toggleMultiviewWindow() {
        if multiviewWindow == nil {
            let w = MultiviewWindowController(source: session?.displaySource)
            if let session { w.restore(from: session.layout) }
            multiviewWindow = w
        }
        multiviewWindow?.toggle()
    }

    var isMultiviewWindowVisible: Bool { multiviewWindow?.isShowing ?? false }

    /// 收起 / 展开调音台。
    func toggleMixerPanel() {
        let collapsed = outerSplit.isSubviewCollapsed(mixerPanel)
        if collapsed {
            outerSplit.setPosition(outerSplit.frame.width - Theme.mixerPanelWidth, ofDividerAt: 0)
        } else {
            outerSplit.setPosition(outerSplit.frame.width, ofDividerAt: 0)
        }
    }

    var isMixerPanelVisible: Bool { !outerSplit.isSubviewCollapsed(mixerPanel) }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === mixerPanel
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === centerSplit ? 300 : 700
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === centerSplit ? splitView.frame.height - 190 : splitView.frame.width - Theme.mixerPanelWidth
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }
}
