// 底栏：添加输入 / 录制 / 推流 / 外部输出 / 多画面 / 叠加 按钮 + 状态行（1 Hz，全部读 Stats）+ 提示（命令被忽略、录制起停、重连……）。
// 录制 / 推流按钮只发 startRecord / stopRecord / startStream / stopStream；文案 = 快照里输出的 enabled（目标）× Stats.encoder[i].state（实际）× 起不来的原因，
// 按最差的那一路汇总、state 查本地化表（W5-B，OutputButtonSummary：X11 / K11 / L4）。
// W3-C：外部输出按钮弹显示器 × 源的菜单（ExternalOutputMenuBuilder），多画面按钮开独立窗口，ISO… 按钮打开输出设置的 ISO 页（W3-E2：ISO 只留一个入口）；录制按钮对全部录制输出
// （PGM + ISO 路）一起发 startRecord / stopRecord（同一拍起停），推流按钮起停全部目的地。文案走 L10n（W3-E）。
// W5-B（02 X01 / X02）：停之前先弹确认（偏好设置里可关，默认开；开始不问；快捷键 / MIDI / API 不走这里，一律不问）；
// 推流有起不来的路时点主体 = 只重试那几路，正常在推的不停（单路起停在 92 的 ▴ 里做）。
import AppKit
import SwitcherContracts

@MainActor
final class BottomBarView: NSView {
    var send: ((Command) -> Void)?
    var onAddInput: (() -> Void)?
    var onOverlayPanel: ((NSView) -> Void)?
    var onExternalMenu: ((NSView) -> Void)?
    var onMultiview: (() -> Void)?
    var onISOSettings: (() -> Void)?
    /// 停录制 / 停推流之前要不要先问（AppController 读偏好设置；W5-B）。
    var shouldConfirmStop: () -> Bool = { true }
    /// 一路起不来的原因 + 推流正在第几次连接（session 的运行表；W5-B）。
    var routeDetail: ((Int) -> (failure: String?, attempt: Int?))?
    /// 重试起不来的那几路（session.retryFailedOutputs）。
    var onRetryOutputs: (([Int]) -> Void)?

    let addInput = SplitBarButton(name: L("bottom.addInput"), title: L("bottom.addInput"))
    let record = SplitBarButton(name: L("bottom.record"), title: L("bottom.record"))
    let external = SplitBarButton(name: L("bottom.external"), title: L("bottom.external"))
    let stream = SplitBarButton(name: L("bottom.stream"), title: L("bottom.stream"))
    let multiview = SplitBarButton(name: L("bottom.multiview"), title: L("bottom.multiview"))
    var leftGroup: [SplitBarButton] { [addInput, record, external, stream, multiview] }
    var statusBar: NSView { self }
    func recordGearMenu() -> NSMenu { NSMenu() }
    func recordMenu() -> NSMenu { NSMenu() }
    func streamMenu() -> NSMenu { NSMenu() }
    var addInputButton: NSButton { addInput.bodyButton }
    var recordButton: NSButton { record.bodyButton }
    var streamButton: NSButton { stream.bodyButton }
    var externalButton: NSButton { external.bodyButton }
    var multiviewButton: NSButton { multiview.bodyButton }
    let overlayButton: NSButton
    let isoButton: NSButton
    let statusLabel = Theme.monoLabel("", size: 11, color: Theme.dimText)
    let noticeLabel = Theme.label("", size: 11, color: Theme.accent)
    private var state = MixerState()
    private var previousStats: Stats?
    /// 最近一行 Stats 里每个输出的状态（按 `EncoderEntry.output` 对号，提案 019）。
    private var encoderStates: [Stats.EncoderEntry] = []
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
        overlayButton = Theme.button(L("bottom.overlay"), target: nil, action: nil)
        isoButton = Theme.button("ISO…", target: nil, action: nil)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor
        addInputButton.target = self; addInputButton.action = #selector(addInputPressed)
        recordButton.target = self; recordButton.action = #selector(recordPressed)
        streamButton.target = self; streamButton.action = #selector(streamPressed)
        overlayButton.target = self; overlayButton.action = #selector(overlayPressed)
        externalButton.target = self; externalButton.action = #selector(externalPressed)
        externalButton.toolTip = L("bottom.externalTip")
        multiviewButton.target = self; multiviewButton.action = #selector(multiviewPressed)
        multiviewButton.toolTip = L("bottom.multiviewTip")
        isoButton.target = self; isoButton.action = #selector(isoPressed)
        isoButton.toolTip = L("menu.output.iso")
        statusLabel.setAccessibilityLabel(L("bottom.statusLine"))
        noticeLabel.setAccessibilityLabel(L("bottom.notice"))
        addInputButton.keyEquivalent = "i"
        addInputButton.keyEquivalentModifierMask = [.command]

        let buttons = NSStackView(views: [addInput, record, isoButton, stream, external, multiview, overlayButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.alignment = .right
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(buttons)
        addSubview(statusLabel)
        addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.bottomBarHeight),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            noticeLabel.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 16),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            noticeLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
        statusLabel.stringValue = L("bottom.waitingStats")
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
        if encoderStates != stats.encoder {
            encoderStates = stats.encoder
            updateButtons()
        }
    }

    /// 某个输出在 Stats.encoder 里的项：按 `EncoderEntry.output` 对号（提案 019；不再按顺序）。
    func encoderEntry(forOutput number: Int) -> Stats.EncoderEntry? {
        OutputRuntime.encoderEntry(encoderStates, forOutput: number)
    }

    /// 一路在按钮眼里的样子：目标开关（快照）+ Stats.encoder 那一项 + 起不来的原因 / 正在第几次连接（运行表）。
    private func routeStatus(_ o: OutputState) -> OutputRouteStatus {
        let entry = encoderEntry(forOutput: o.number)
        let detail = routeDetail?(o.number)
        return OutputRouteStatus(number: o.number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0,
                                 attempt: detail?.attempt, failure: detail?.failure)
    }

    private func show(_ summary: OutputButtonSummary, on button: NSButton) {
        button.title = summary.title
        button.toolTip = summary.toolTip
        Theme.setHighlighted(button, summary.highlighted, color: summary.color)
    }

    private func updateButtons() {
        // 录制：全部录制输出（PGM + ISO 路）一起看，按最差的那一路汇总
        let records = state.outputs.filter { $0.kind == .record }
        if !records.isEmpty {
            recordSummary = OutputButtonSummary.record(records.map(routeStatus))
            show(recordSummary, on: recordButton)
        } else {
            recordSummary = OutputButtonSummary(title: L("bottom.record"), toolTip: L("bottom.noRecordOutputTip"), severity: .off)
            show(recordSummary, on: recordButton)
        }
        // 推流：所有推流目的地，按最差的那一路汇总（"● 推流中 2/3"、"推流 · 1 路异常"）；提示逐路列状态与原因
        let streams = state.outputs.filter { $0.kind == .stream }
        if !streams.isEmpty {
            streamSummary = OutputButtonSummary.stream(streams.map(routeStatus))
            show(streamSummary, on: streamButton)
            streamButton.isEnabled = true
        } else {
            streamSummary = OutputButtonSummary(title: L("bottom.stream"), toolTip: L("bottom.noStreamOutputTip"), severity: .off)
            show(streamSummary, on: streamButton)
            streamButton.isEnabled = false
        }
    }

    /// PGM 那一路的录制输出（source == .program 的第一个 record）。
    var programRecordOutput: OutputState? { state.outputs.first { $0.kind == .record && $0.settings.source == .program } }

    /// 新 session：忘掉上一行（fps 要重新算）。
    func resetStats() {
        previousStats = nil
        lastStatusLine = nil
        encoderStates = []
        statusLabel.stringValue = L("bottom.waitingStats")
        noticeLabel.stringValue = ""
    }

    /// 右上角提示一句（几秒后自动清掉）。
    func showNotice(_ message: String) {
        noticeLabel.stringValue = message
        noticeLabel.toolTip = message
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: Self.noticeSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.noticeLabel.stringValue = "" }
        }
    }

    var displayedNotice: String { noticeLabel.stringValue }

    @objc private func addInputPressed() { onAddInput?() }

    @objc private func recordPressed() {
        let records = state.outputs.filter { $0.kind == .record }
        if !records.isEmpty {
            // 有任何一路在录就全停（先确认），否则全起（同一拍发多条 = ISO 共用起点；开始不问）
            let running = records.filter(\.enabled)
            if running.isEmpty {
                for r in records { send?(.startRecord(output: r.number)) }
            } else {
                confirmStop(.stopRecord, routes: running) { [weak self] in
                    guard let self else { return }
                    for r in self.state.outputs where r.kind == .record && r.enabled { self.send?(.stopRecord(output: r.number)) }
                }
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
    /// 否则 → 停全部开着的（先确认）。单路起停在 92 的 ▴ 里做。
    @objc private func streamPressed() {
        let streams = state.outputs.filter { $0.kind == .stream }
        guard !streams.isEmpty else { return }
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
        confirmStop(.stopStream, routes: running) { [weak self] in
            guard let self else { return }
            for s in self.state.outputs where s.kind == .stream && s.enabled { self.send?(.stopStream(output: s.number)) }
        }
    }

    /// 停之前问一声（偏好设置里关了 / 没挂在窗口上就直接停）。确认时按当时的快照停（问的过程中 API 停了几路也不会多发）。
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
    @objc private func externalPressed() { onExternalMenu?(externalButton) }
    @objc private func multiviewPressed() { onMultiview?() }
    @objc private func isoPressed() { onISOSettings?() }
}
