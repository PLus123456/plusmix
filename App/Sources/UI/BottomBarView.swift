// 底栏（W5-F 起两行）：上一行是输出按钮，左组 添加输入 ▴ ｜ ⚙ 录制 ▴ ｜ ⚙ 外部显示 ｜ ⚙ 推流 ▴ ｜ ⚙ 多画面，右组 叠加（97 之前仍是弹出层）｜ 统计 ｜ 锁（W5-L：
// "统计"开只读统计窗（E5），最右的锁 = 锁定界面（E8：锁着时主窗口的鼠标点击不生效，按钮金色高亮；拦点击在 MainWindow.sendEvent）；
// 下一行是状态行（StatusBarView：窗口最底一行、全宽，左边 1 Hz 读 Stats，右端提示文字 / 本机信息，E9）。
// 每个输出都是分体按钮（SplitBarButton，docs/ui-study/01-菜单逻辑.md §1 规则 1）：⚙ = 这件事的设置，主体 = 执行 / 开关，▴ = 快捷菜单（朝上开，BottomBarPopup）。
// - 录制（K1 / K2 / K3）：⚙ 菜单"录制设置… / ISO 分路录制…"（单独的"ISO…"按钮去掉）；主体照旧 PGM + ISO 同一拍一起起停（有意保留，测试标准 A4 的前提）；
//   ▴ 每个录制输出一行（名字 · 状态，读 Stats.encoder 按 output 对号），点 = 只停这一路（不给中途单独开始），末尾"全部停止"。
// - 推流（L1 / L2）：⚙ = 输出设置 › 推流；主体维持 W5-B 的口径（都没开 → 全起；有起不来的 → 只重试它们；否则停全部，先确认）；没有目的地时主体不灰，
//   点了打开推流页、焦点放在"添加目的地"；▴ = 全部开始 / 全部停止 ｜ 每个目的地一项（✓ = 在推，标题 = 名字 · 状态 · 码率，点 = 只起停这一路，起不来的那一路 = 重试）｜
//   推流设置… / 推流状态…（状态面板归 101，先指向推流页）；菜单栏"输出 › 推流 ▸"用同一份（streamMenu）。
// - 外部显示（M1–M4）：⚙ = 路由菜单（每块屏单选，ExternalOutputMenuBuilder），主体 = 全部外部显示一起开 / 关、配置保留（开着高亮）；一路都没配时第一次点 =
//   在第一块非主屏上开 PGM，没有第二块屏就弹路由菜单（MainWindowController 接）。
// - 多画面（E3）：⚙ = 多画面布局页，主体 = 窗口开 / 关（开着高亮）。添加输入（G1）：主体 = 添加面板停在上次的类型，▴ = 八种类型直达 + 最近添加的来源。
// 录制 / 推流只发 startRecord / stopRecord / startStream / stopStream；文案 = 快照里输出的 enabled（目标）× Stats.encoder[i].state（实际）× 起不来的原因，
// 按最差的那一路汇总、state 查本地化表（W5-B，OutputButtonSummary）。停之前先确认（偏好设置里可关，默认开；开始不问）：底栏主体、▴ 里的单路停 / 全部停止、
// 菜单栏"输出 › 推流 ▸"都是界面入口，都问；快捷键 / MIDI / API 不走这里，一律不问。菜单与提示只写目的地的名字和打过码的地址（G6 追加 ①）。
import AppKit
import SwitcherContracts
import SwitcherStreaming

@MainActor
final class BottomBarView: NSView {
    var send: ((Command) -> Void)?
    /// 添加输入：nil = 停在上次的类型；给了类型 = 直达那一页。
    var onAddInput: ((AddInputModel.Kind?) -> Void)?
    /// 添加输入 ▴ 的菜单（MainWindowController 建：类型直达 + 最近添加的来源；菜单栏"输入 › 按类型添加 ▸"同一份）。
    var addInputMenu: (() -> NSMenu?)?
    var onOverlayPanel: ((NSView) -> Void)?
    /// 外部显示 ⚙ 的路由菜单（MainWindowController 建）。
    var externalMenu: (() -> NSMenu?)?
    /// 外部显示主体：全部开 / 关；返回 false = 一路都没配、也没有第二块屏（底栏弹路由菜单）。
    var onExternalToggle: (() -> Bool)?
    var onMultiview: (() -> Void)?
    /// 打开输出设置的某一页（⚙ 直达、菜单里的"…设置…"）。
    var onOutputSettings: ((OutputSettingsModel.Tab) -> Void)?
    /// 没有推流目的地时点推流主体：打开推流页、焦点放在"添加目的地"（L1）。
    var onAddStreamDestination: (() -> Void)?
    /// 弹菜单之前（MainWindowController 记下 activeBottomMenu：菜单是模态的，测试开着时量位置）。
    var willPopUpMenu: ((NSMenu) -> Void)? {
        didSet { for b in leftGroup { b.willPopUp = willPopUpMenu } }
    }
    /// 停录制 / 停推流之前要不要先问（AppController 读偏好设置；W5-B）。
    var shouldConfirmStop: () -> Bool = { true }
    /// 一路起不来的原因 + 推流正在第几次连接（session 的运行表；W5-B）。
    var routeDetail: ((Int) -> (failure: String?, attempt: Int?))?
    /// 重试起不来的那几路（session.retryFailedOutputs）。
    var onRetryOutputs: (([Int]) -> Void)?

    let addInput = SplitBarButton(name: L("bottom.addInput.name"), title: L("bottom.addInput"))
    let record = SplitBarButton(name: L("bottom.record"), title: L("bottom.record"))
    let external = SplitBarButton(name: L("bottom.external"), title: L("bottom.external"))
    let stream = SplitBarButton(name: L("bottom.stream"), title: L("bottom.stream"))
    let multiview = SplitBarButton(name: L("bottom.multiview"), title: L("bottom.multiview"))
    /// 右组：叠加（97 之前仍是弹出层）。
    let overlayButton = Theme.button(L("bottom.overlay"), target: nil, action: nil)
    /// 右组："统计"开只读统计窗（W5-L，E5）。
    let statsButton = Theme.button(L("bottom.stats"), target: nil, action: nil)
    /// 底栏最右：锁定界面（W5-L，E8）。
    let lockButton = Theme.button("", target: nil, action: nil)
    /// 点"统计"。
    var onStats: (() -> Void)?
    /// 点锁（MainWindowController 翻主窗口的锁）。
    var onToggleLock: (() -> Void)?
    /// 锁按钮现在是不是高亮（= 锁着）。
    private(set) var isLockHighlighted = false
    /// 左组，从左到右（E2）。
    var leftGroup: [SplitBarButton] { [addInput, record, external, stream, multiview] }
    /// 状态行：窗口最底一行、全宽（E9）。
    let statusBar = StatusBarView()
    var statusLabel: NSTextField { statusBar.statusLabel }
    /// 状态行右端：提示文字，平时是本机信息。
    var noticeLabel: NSTextField { statusBar.noticeLabel }
    private let buttonRow = NSView()
    private var state = MixerState()
    private var previousStats: Stats?
    /// 最近一行 Stats 里每个输出的状态（按 `EncoderEntry.output` 对号，提案 019）。
    private var encoderStates: [Stats.EncoderEntry] = []
    /// 最近一行 Stats 的 display[]（外部显示主体的提示读它，提案 013）。
    private var displayStates: [Stats.DisplayEntry] = []
    private var format: ProgramFormat = .hd1080p60
    /// 最近一次显示的状态行（测试对照 stats.jsonl 用）。
    private(set) var lastStatusLine: (stats: Stats, text: String)?
    private var noticeTimer: Timer?
    /// 最近一次给两个主体按钮算的汇总（测试看严重程度）。
    private(set) var recordSummary = OutputButtonSummary(title: L("bottom.record"), toolTip: nil, severity: .off)
    private(set) var streamSummary = OutputButtonSummary(title: L("bottom.stream"), toolTip: nil, severity: .off)
    /// 提示保留多久。
    static let noticeSeconds: TimeInterval = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor

        addInput.bodyAction = { [weak self] in self?.onAddInput?(nil) }
        addInput.menuAction = .menu { [weak self] in self?.addInputMenu?() }
        addInput.bodyButton.keyEquivalent = "i"
        addInput.bodyButton.keyEquivalentModifierMask = [.command]
        addInput.bodyButton.toolTip = L("bottom.addInputTip")

        record.gearAction = .menu { [weak self] in self?.recordGearMenu() }
        record.bodyAction = { [weak self] in self?.recordPressed() }
        record.menuAction = .menu { [weak self] in self?.recordMenu() }

        external.gearAction = .menu { [weak self] in self?.externalMenu?() }
        external.bodyAction = { [weak self] in self?.externalPressed() }

        stream.gearAction = .perform { [weak self] in self?.onOutputSettings?(.stream) }
        stream.bodyAction = { [weak self] in self?.streamPressed() }
        stream.menuAction = .menu { [weak self] in self?.streamMenu() }

        multiview.gearAction = .perform { [weak self] in self?.onOutputSettings?(.multiview) }
        multiview.bodyAction = { [weak self] in self?.onMultiview?() }
        multiview.bodyButton.toolTip = L("bottom.multiviewTip")

        overlayButton.target = self
        overlayButton.action = #selector(overlayPressed)
        overlayButton.refusesFirstResponder = true
        statsButton.target = self
        statsButton.action = #selector(statsPressed)
        statsButton.refusesFirstResponder = true
        statsButton.toolTip = L("bottom.statsTip")
        lockButton.target = self
        lockButton.action = #selector(lockPressed)
        lockButton.refusesFirstResponder = true
        lockButton.imagePosition = .imageOnly
        lockButton.setContentHuggingPriority(.required, for: .horizontal)
        setLocked(false)

        let left = NSStackView(views: leftGroup)
        left.orientation = .horizontal
        left.spacing = 10
        left.translatesAutoresizingMaskIntoConstraints = false
        let right = NSStackView(views: [overlayButton, statsButton, lockButton])
        right.orientation = .horizontal
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(left)
        buttonRow.addSubview(right)
        addSubview(buttonRow)
        addSubview(statusBar)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.bottomBarHeight),
            buttonRow.topAnchor.constraint(equalTo: topAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            left.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),
        ])
        statusLabel.stringValue = L("bottom.waitingStats")
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: MixerState) {
        self.state = state
        format = state.format
        updateButtons()
    }

    /// 1 Hz：状态行 + 按钮的实际状态。
    func apply(stats: Stats) {
        // encoder 的项不带类型：按每项的 output 编号查快照里的 kind（NDI 的原始码率不顶掉录制 / 推流的码率，W3-E3；W3-E5 起按编号对号、不再按顺序）
        let kinds = Dictionary(state.outputs.map { ($0.number, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let text = StatusLineFormatter.line(current: stats, previous: previousStats, format: format, kinds: kinds)
        statusLabel.stringValue = text
        lastStatusLine = (stats, text)
        previousStats = stats
        if encoderStates != stats.encoder || displayStates != stats.display {
            encoderStates = stats.encoder
            displayStates = stats.display
            updateButtons()
        }
    }

    /// 某个输出在 Stats.encoder 里的项：按 `EncoderEntry.output` 对号（提案 019；不再按顺序）。
    func encoderEntry(forOutput number: Int) -> Stats.EncoderEntry? {
        OutputRuntime.encoderEntry(encoderStates, forOutput: number)
    }

    /// 多画面窗口开着 / 关了（MainWindowController 在窗口开关、点了窗口的关闭按钮时告诉这里）：主体高亮。
    func setMultiviewOpen(_ open: Bool) {
        multiview.setBodyHighlighted(open)
    }

    /// 一路在按钮眼里的样子：目标开关（快照）+ Stats.encoder 那一项 + 起不来的原因 / 正在第几次连接（运行表）。
    private func routeStatus(_ o: OutputState) -> OutputRouteStatus {
        let entry = encoderEntry(forOutput: o.number)
        let detail = routeDetail?(o.number)
        return OutputRouteStatus(number: o.number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0,
                                 attempt: detail?.attempt, failure: detail?.failure)
    }

    /// 每个快照（≤ 60 Hz）都会调：标题 / 提示没变就不重设——重设标题会把白字的 attributedTitle 冲掉、按钮重算尺寸、整窗下一次画之前重新布局，
    /// 点按钮（performClick 先画高亮再发命令）就慢一截、还忽快忽慢（RecordingTests 的"起止拍差 = 按钮间隔 ± 1 帧"量得出来，报告 §5）。
    private func show(_ summary: OutputButtonSummary, on button: SplitBarButton) {
        if button.bodyButton.title != summary.title { button.bodyButton.title = summary.title }
        if button.bodyButton.toolTip != summary.toolTip { button.bodyButton.toolTip = summary.toolTip }
        button.setBodyHighlighted(summary.highlighted, color: summary.color)
    }

    private func updateButtons() {
        // 录制：全部录制输出（PGM + ISO 路）一起看，按最差的那一路汇总
        let records = state.outputs.filter { $0.kind == .record }
        recordSummary = records.isEmpty ? OutputButtonSummary(title: L("bottom.record"), toolTip: L("bottom.noRecordOutputTip"), severity: .off)
                                        : OutputButtonSummary.record(records.map(routeStatus))
        show(recordSummary, on: record)
        // 推流：所有推流目的地，按最差的那一路汇总（"● 推流中 2/3"、"推流 · 1 路异常"）；提示逐路列状态与原因。没有目的地时不灰（L1）
        let streams = state.outputs.filter { $0.kind == .stream }
        streamSummary = streams.isEmpty ? OutputButtonSummary(title: L("bottom.stream"), toolTip: L("bottom.noStreamOutputTip"), severity: .off)
                                        : OutputButtonSummary.stream(streams.map(routeStatus))
        show(streamSummary, on: stream)
        // 外部显示：有开着的就高亮；提示逐路写状态（Stats.display[]）
        let displays = state.outputs.filter { $0.kind == .externalDisplay }
        external.setBodyHighlighted(displays.contains(where: \.enabled))
        let tip = externalTip(displays)
        if external.bodyButton.toolTip != tip { external.bodyButton.toolTip = tip }
    }

    private func externalTip(_ outputs: [OutputState]) -> String {
        guard !outputs.isEmpty else { return L("bottom.externalTip.none") }
        let lines = outputs.map { o -> String in
            guard o.enabled else { return L("bottom.tip.line", o.name, L("output.state.off")) }
            let status = displayStates.first { $0.kind == "externalDisplay" && $0.output == o.number }.map(OutputStatusText.display) ?? L("output.state.on")
            return L("bottom.tip.line", o.name, status)
        }
        let hint = outputs.contains(where: \.enabled) ? L("bottom.externalTip.turnOff") : L("bottom.externalTip.turnOn")
        return (lines + [hint]).joined(separator: "\n")
    }

    /// 底栏眼里的推流目的地（最近一次快照；没有目的地时主体不灰、点了打开推流页，L1）。
    var streamDestinations: [OutputState] { state.outputs.filter { $0.kind == .stream } }

    /// PGM 那一路的录制输出（source == .program 的第一个 record）。
    var programRecordOutput: OutputState? { state.outputs.first { $0.kind == .record && $0.settings.source == .program } }

    /// 新 session：忘掉上一行（fps 要重新算）。
    func resetStats() {
        previousStats = nil
        lastStatusLine = nil
        encoderStates = []
        displayStates = []
        statusLabel.stringValue = L("bottom.waitingStats")
        noticeTimer?.invalidate()
        statusBar.showNotice("")
    }

    /// 状态行右端提示一句（几秒后回到本机信息）。
    func showNotice(_ message: String) {
        statusBar.showNotice(message)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: Self.noticeSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusBar.showNotice("") }
        }
    }

    /// 正在显示的提示（没有提示为空串；本机信息不算提示）。
    var displayedNotice: String { statusBar.notice }

    // MARK: 菜单（每次现建；关掉 autoenablesItems，灰不灰按 isEnabled）

    private static func menu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        return menu
    }

    private static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 录制 ⚙：录制设置… / ISO 分路录制…（输出设置对应的页，K1 / K2：ISO 页从这里进，不再有单独的按钮）。
    func recordGearMenu() -> NSMenu {
        let menu = Self.menu(L("bottom.record"))
        menu.addItem(.action(L("menu.output.record")) { [weak self] in self?.onOutputSettings?(.record) })
        menu.addItem(.action(L("menu.output.iso")) { [weak self] in self?.onOutputSettings?(.iso) })
        return menu
    }

    /// 录制 ▴（K3）：每个录制输出一行"名字 · 状态"，点 = 只停这一路（先确认）；没开的路灰着——录制中途不给单独开始（一起开始的那批才同拍，A4）；末尾"全部停止"。
    func recordMenu() -> NSMenu {
        let menu = Self.menu(L("bottom.record"))
        let records = state.outputs.filter { $0.kind == .record }
        if records.isEmpty { menu.addItem(Self.note(L("recordMenu.none"))) }
        for o in records {
            let route = routeStatus(o)
            let s = OutputButtonSummary.routeState(route, kind: .record)
            let tip = !o.enabled ? L("recordMenu.noSingleStart") : route.failure.map { L("recordMenu.tip.failed", $0) } ?? L("recordMenu.tip.stop")
            let number = o.number
            menu.addItem(.action(L("recordMenu.item", o.name, s.text), enabled: o.enabled, state: s.severity.menuState(enabled: o.enabled), toolTip: tip) { [weak self] in
                self?.stopRoutes([number], kind: .stopRecord)
            })
        }
        menu.addItem(.separator())
        menu.addItem(.action(L("recordMenu.stopAll"), enabled: records.contains(where: \.enabled)) { [weak self] in self?.stopRoutes(nil, kind: .stopRecord) })
        return menu
    }

    /// 推流 ▴（L2）：全部开始 / 全部停止 ｜ 每个目的地一项 ｜ 推流设置… / 推流状态…。菜单栏"输出 › 推流 ▸"也是它。
    func streamMenu() -> NSMenu {
        let menu = Self.menu(L("bottom.stream"))
        let streams = state.outputs.filter { $0.kind == .stream }
        let rows = StreamMenuRow.rows(state: state, encoder: encoderStates) { [weak self] n in self?.routeDetail?(n) ?? (failure: nil, attempt: nil) }
        menu.addItem(.action(L("streamMenu.startAll"), enabled: rows.contains { $0.click != .stop }) { [weak self] in self?.startAllStreams() })
        menu.addItem(.action(L("streamMenu.stopAll"), enabled: streams.contains(where: \.enabled)) { [weak self] in self?.stopRoutes(nil, kind: .stopStream) })
        menu.addItem(.separator())
        if rows.isEmpty {
            menu.addItem(Self.note(L("streamMenu.none")))
            menu.addItem(.action(L("streamMenu.addDestination")) { [weak self] in self?.onAddStreamDestination?() })
        }
        for row in rows {
            menu.addItem(.action(row.title, state: row.check, toolTip: row.toolTip) { [weak self] in self?.streamRowPicked(row) })
        }
        menu.addItem(.separator())
        menu.addItem(.action(L("menu.output.stream")) { [weak self] in self?.onOutputSettings?(.stream) })
        menu.addItem(.action(L("streamMenu.status")) { [weak self] in self?.onOutputSettings?(.stream) })   // 推流状态面板归 101，先指向推流页
        return menu
    }

    private func streamRowPicked(_ row: StreamMenuRow) {
        switch row.click {
        case .start: send?(.startStream(output: row.number))
        case .retry:
            onRetryOutputs?([row.number])
            updateButtons()
        case .stop: stopRoutes([row.number], kind: .stopStream)
        }
    }

    /// 全部开始：没开的都开，开着但起不来的重试；正常在推的不动。开始不问。
    private func startAllStreams() {
        let streams = state.outputs.filter { $0.kind == .stream }
        for s in streams where !s.enabled { send?(.startStream(output: s.number)) }
        let failed = streams.filter { $0.enabled && routeDetail?($0.number).failure != nil }.map(\.number)
        if !failed.isEmpty { onRetryOutputs?(failed) }
        updateButtons()
    }

    // MARK: 主体

    private func recordPressed() {
        let records = state.outputs.filter { $0.kind == .record }
        if !records.isEmpty {
            // 有任何一路在录就全停（先确认），否则全起（同一拍发多条 = ISO 共用起点；开始不问）
            if !records.contains(where: \.enabled) {
                for r in records { send?(.startRecord(output: r.number)) }
            } else {
                stopRoutes(nil, kind: .stopRecord)
            }
        } else {
            // 节目里没有录制输出：先加一个再开
            let number = (state.outputs.map(\.number).max() ?? 0) + 1
            let show = ShowDocuments.emptyShow()
            var output = show.outputs[0]
            output.number = number
            send?(.addOutput(config: output))
            send?(.startRecord(output: number))
        }
    }

    /// 主体只作用于在跑的路（W5-B，02 X02）：都没开 → 全起；开着的里有起不来的 → 只重试那几路，正常在推的不动、也不问；
    /// 否则 → 停全部开着的（先确认）。单路起停与"全部停止"在 ▴ 里（一直起不来的那一路不挡着停正常的几路，G6 追加 ②）。没有目的地 → 打开推流页添加（L1）。
    private func streamPressed() {
        let streams = state.outputs.filter { $0.kind == .stream }
        guard !streams.isEmpty else {
            onAddStreamDestination?()
            return
        }
        let running = streams.filter(\.enabled)
        if running.isEmpty {
            for s in streams { send?(.startStream(output: s.number)) }
            return
        }
        // 起不来的路按运行表认（不看 1 Hz 的 Stats：刚自动重试好的路，上一行 Stats 里可能还是 failed）
        let failed = running.filter { routeDetail?($0.number).failure != nil }
        if !failed.isEmpty {
            onRetryOutputs?(failed.map(\.number))
            updateButtons()
            return
        }
        stopRoutes(nil, kind: .stopStream)
    }

    /// 外部显示主体：全部开 / 关（配置保留）；一路都没配、也没有第二块屏 → 弹路由菜单（04 Q03 第 3 条）。
    private func externalPressed() {
        guard onExternalToggle?() == false, let menu = externalMenu?() else { return }
        external.popUp(menu, from: external.bodyButton)
    }

    /// 停这几路（nil = 全部开着的；先确认）。确认时按当时的快照停、只停仍开着的（问的过程中 API 停了几路也不会多发）。
    private func stopRoutes(_ numbers: [Int]?, kind: ConfirmationCenter.Kind) {
        let outputKind: OutputKind = kind == .stopRecord ? .record : .stream
        func targets(_ s: MixerState) -> [OutputState] {
            s.outputs.filter { $0.kind == outputKind && $0.enabled && (numbers?.contains($0.number) ?? true) }
        }
        let routes = targets(state)
        guard !routes.isEmpty else { return }
        confirmStop(kind, routes: routes) { [weak self] in
            guard let self else { return }
            for o in targets(self.state) { self.send?(kind == .stopRecord ? .stopRecord(output: o.number) : .stopStream(output: o.number)) }
        }
    }

    /// 停之前问一声（偏好设置里关了 / 没挂在窗口上就直接停）。
    private func confirmStop(_ kind: ConfirmationCenter.Kind, routes: [OutputState], perform: @escaping @MainActor () -> Void) {
        guard shouldConfirmStop(), let window else { perform(); return }
        let names = routes.map { o in
            let s = OutputButtonSummary.routeState(routeStatus(o), kind: kind == .stopRecord ? .record : .stream).text
            return L("bottom.tip.line", o.name, s)
        }.joined(separator: L("confirm.part.separator"))
        let title = kind == .stopRecord ? L("confirm.stopRecord.title", routes.count) : L("confirm.stopStream.title", routes.count)
        let button = kind == .stopRecord ? L("confirm.stopRecord.button") : L("confirm.stopStream.button")
        let request = ConfirmationCenter.Request(kind: kind, title: title, message: L("confirm.stop.message", names),
                                                 buttons: [.init(title: button, choice: .confirm, destructive: true), .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        ConfirmationCenter.shared.ask(request, in: window) { choice in
            if choice == .confirm { perform() }
        }
    }

    @objc private func overlayPressed() { onOverlayPanel?(overlayButton) }
    @objc private func statsPressed() { onStats?() }
    @objc private func lockPressed() { onToggleLock?() }

    /// 锁按钮跟着锁的状态：锁着 = 闭合的锁、金色高亮；开着 = 打开的锁。图标 / 提示 / 辅助功能名一起换。
    func setLocked(_ locked: Bool) {
        isLockHighlighted = locked
        let label = locked ? L("lock.unlock") : L("lock.lock")
        let symbol = locked ? "lock.fill" : "lock.open"
        lockButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        lockButton.setAccessibilityLabel(label)
        lockButton.toolTip = locked ? L("lock.unlockTip") : L("lock.lockTip")
        Theme.setHighlighted(lockButton, locked, color: Theme.lockActive)
    }
}

/// 推流 ▴ 里一个目的地那一项（纯函数，测试直接喂）：标题"名字 · 状态 · 码率"（码率只在推流中时写），勾 = 在推，点了做什么，提示（起不来的原因 + 打过码的地址）。
struct StreamMenuRow: Equatable {
    enum Click: Equatable {
        /// 没开：只开这一路。
        case start
        /// 开着、没起不来：只停这一路（先确认）。
        case stop
        /// 开着但起不来：只重试这一路（正常的不动）。
        case retry
    }
    var number: Int
    var title: String
    var check: NSControl.StateValue
    var click: Click
    var toolTip: String?

    @MainActor
    static func rows(state: MixerState, encoder: [Stats.EncoderEntry], detail: (Int) -> (failure: String?, attempt: Int?)) -> [StreamMenuRow] {
        state.outputs.filter { $0.kind == .stream }.map { o in
            let entry = OutputRuntime.encoderEntry(encoder, forOutput: o.number)
            let d = detail(o.number)
            let route = OutputRouteStatus(number: o.number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0,
                                          attempt: d.attempt, failure: d.failure)
            let s = OutputButtonSummary.routeState(route, kind: .stream)
            let title: String
            if s.severity == .live, let bitrate = entry?.bitrate, bitrate > 0 {
                title = L("streamMenu.itemBitrate", o.name, s.text, StatusLineFormatter.bitrateText(bitrate))
            } else {
                title = L("streamMenu.item", o.name, s.text)
            }
            let click: Click = !o.enabled ? .start : (d.failure != nil ? .retry : .stop)
            var tip: [String] = []
            if o.enabled, let failure = d.failure { tip.append(L("streamMenu.tip.failed", failure)) }
            // 地址只给打过码的（user:pass@ / passphrase / streamid / key 等换成 <redacted>，G6 追加 ①）
            if let url = o.settings.stream?.url, !url.isEmpty { tip.append(L("streamMenu.tip.address", StreamURLRedaction.redact(url: url))) }
            switch click {
            case .start: tip.append(L("streamMenu.tip.start"))
            case .stop: tip.append(L("streamMenu.tip.stop"))
            case .retry: tip.append(L("streamMenu.tip.retry"))
            }
            return StreamMenuRow(number: o.number, title: title, check: s.severity.menuState(enabled: o.enabled), click: click,
                                 toolTip: tip.joined(separator: "\n"))
        }
    }
}
