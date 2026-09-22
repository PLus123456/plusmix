// 底栏：添加输入 / 录制 / 推流 / 外部输出 / 多画面 / 叠加 按钮 + 状态行（1 Hz，全部读 Stats）+ 提示（命令被忽略、录制起停、重连……）。
// 录制 / 推流按钮只发 startRecord / stopRecord / startStream / stopStream；文案 = 快照里输出的 enabled（目标）× Stats.encoder[i].state（实际）：
//   录制：目标关 → "录制"；目标开、实际 recording → "● 录制中"；目标开、实际还没到（idle / stopping / failed）→ "录制 · <state>"。
//   推流：目标关 → "推流"；publishing → "● 推流中"；connecting / backoff → "推流 · 重连中（第 n 次）"（n = Stats.encoder[i].reconnects）。
// W3-C：外部输出按钮弹显示器 × 源的菜单（ExternalOutputMenuBuilder），多画面按钮开独立窗口，ISO… 按钮弹选路面板；录制按钮对全部录制输出
// （PGM + ISO 路）一起发 startRecord / stopRecord（同一拍起停），推流按钮起停全部目的地。文案走 L10n（W3-E）。
import AppKit
import SwitcherContracts

@MainActor
final class BottomBarView: NSView {
    var send: ((Command) -> Void)?
    var onAddInput: (() -> Void)?
    var onOverlayPanel: ((NSView) -> Void)?
    var onExternalMenu: ((NSView) -> Void)?
    var onMultiview: (() -> Void)?
    var onISOPanel: ((NSView) -> Void)?

    let addInputButton: NSButton
    let recordButton: NSButton
    let streamButton: NSButton
    let externalButton: NSButton
    let multiviewButton: NSButton
    let overlayButton: NSButton
    let isoButton: NSButton
    let statusLabel = Theme.monoLabel("", size: 11, color: Theme.dimText)
    let noticeLabel = Theme.label("", size: 11, color: Theme.accent)
    private var state = MixerState()
    private var previousStats: Stats?
    /// 最近一行 Stats 里每个输出的状态（按 outputs 里带编码器的输出同序）。
    private var encoderStates: [Stats.EncoderEntry] = []
    private var format: ProgramFormat = .hd1080p60
    /// 最近一次显示的状态行（测试对照 stats.jsonl 用）。
    private(set) var lastStatusLine: (stats: Stats, text: String)?
    private var noticeTimer: Timer?
    /// 提示保留多久。
    static let noticeSeconds: TimeInterval = 4

    override init(frame: NSRect) {
        addInputButton = Theme.button(L("bottom.addInput"), target: nil, action: nil)
        recordButton = Theme.toggleButton(L("bottom.record"), target: nil, action: nil)
        streamButton = Theme.toggleButton(L("bottom.stream"), target: nil, action: nil)
        externalButton = Theme.button(L("bottom.external"), target: nil, action: nil)
        multiviewButton = Theme.button(L("bottom.multiview"), target: nil, action: nil)
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

        let buttons = NSStackView(views: [addInputButton, recordButton, isoButton, streamButton, externalButton, multiviewButton, overlayButton])
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
        let text = StatusLineFormatter.line(current: stats, previous: previousStats, format: format)
        statusLabel.stringValue = text
        lastStatusLine = (stats, text)
        previousStats = stats
        if encoderStates != stats.encoder {
            encoderStates = stats.encoder
            updateButtons()
        }
    }

    /// 某个输出在 Stats.encoder 里的项：encoder 与 outputs 里带编码器（record / stream / ndi）的输出同序。
    func encoderEntry(forOutput number: Int) -> Stats.EncoderEntry? {
        let withEncoders = state.outputs.filter { [.record, .stream, .ndi].contains($0.kind) }
        guard let i = withEncoders.firstIndex(where: { $0.number == number }), i < encoderStates.count else { return nil }
        return encoderStates[i]
    }

    private func updateButtons() {
        // 录制：全部录制输出（PGM + ISO 路）一起看；文案按第一个 enabled 的（没有就第一个）
        let records = state.outputs.filter { $0.kind == .record }
        if let record = records.first(where: \.enabled) ?? records.first {
            let actual = encoderEntry(forOutput: record.number)?.state ?? "idle"
            let enabledCount = records.filter(\.enabled).count
            switch (record.enabled, actual) {
            case (true, "recording"):
                // PGM + ISO 几路一起在录时带路数（W3-C）；文案键是 W3-E 的 L10n 表（G4 合并时加 bottom.recordingMany / recordStateMany）
                recordButton.title = enabledCount > 1 ? L("bottom.recordingMany", enabledCount) : L("bottom.recording")
                recordButton.toolTip = nil
            case (true, let s):
                recordButton.title = enabledCount > 1 ? L("bottom.recordStateMany", s, enabledCount) : L("bottom.recordState", s)
                recordButton.toolTip = L("bottom.recordStateTip", s)
            default:
                recordButton.title = L("bottom.record")
                recordButton.toolTip = nil
            }
            Theme.setHighlighted(recordButton, record.enabled, color: Theme.recording)
        } else {
            recordButton.title = L("bottom.record")
            recordButton.toolTip = L("bottom.noRecordOutputTip")
            Theme.setHighlighted(recordButton, false, color: Theme.recording)
        }
        // 推流：所有推流目的地；文案按第一个（多目的地时状态最差的那个）
        let streams = state.outputs.filter { $0.kind == .stream }
        if let stream = streams.first {
            let entry = encoderEntry(forOutput: stream.number)
            let actual = entry?.state ?? "idle"
            switch (stream.enabled, actual) {
            case (true, "publishing"):
                streamButton.title = streams.count > 1 ? L("bottom.streamingMany", streams.count) : L("bottom.streaming")
            case (true, "connecting"), (true, "backoff"):
                streamButton.title = L("bottom.streamReconnecting", (entry?.reconnects ?? 0) + 1)
            case (true, let s):
                streamButton.title = L("bottom.streamState", s)
            default:
                streamButton.title = L("bottom.stream")
            }
            streamButton.isEnabled = true
            streamButton.toolTip = streams.map { $0.settings.stream?.url ?? "" }.joined(separator: "\n")
            Theme.setHighlighted(streamButton, streams.contains { $0.enabled }, color: Theme.recording)
        } else {
            streamButton.title = L("bottom.stream")
            streamButton.isEnabled = false
            streamButton.toolTip = L("bottom.noStreamOutputTip")
            Theme.setHighlighted(streamButton, false, color: Theme.recording)
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
            // 有任何一路在录就全停，否则全起（同一拍发多条 = ISO 共用起点）
            if records.contains(where: \.enabled) {
                for r in records where r.enabled { send?(.stopRecord(output: r.number)) }
            } else {
                for r in records { send?(.startRecord(output: r.number)) }
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

    /// 有在跑的就全停，否则全起（多目的地一起）。
    @objc private func streamPressed() {
        let streams = state.outputs.filter { $0.kind == .stream }
        guard !streams.isEmpty else { return }
        if streams.contains(where: \.enabled) {
            for s in streams where s.enabled { send?(.stopStream(output: s.number)) }
        } else {
            for s in streams { send?(.startStream(output: s.number)) }
        }
    }

    @objc private func overlayPressed() { onOverlayPanel?(overlayButton) }
    @objc private func externalPressed() { onExternalMenu?(externalButton) }
    @objc private func multiviewPressed() { onMultiview?() }
    @objc private func isoPressed() { onISOPanel?(isoButton) }
}
