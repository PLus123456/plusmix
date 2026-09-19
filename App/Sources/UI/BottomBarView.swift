// 底栏：添加输入 / 录制 / 推流 / 外部输出 / 多画面 / 叠加 按钮 + 状态行（1 Hz，全部读 Stats）+ 提示（命令被忽略、录制起停、重连……）。
// 录制 / 推流按钮只发 startRecord / stopRecord / startStream / stopStream；文案 = 快照里输出的 enabled（目标）× Stats.encoder[i].state（实际）：
//   录制：目标关 → "录制"；目标开、实际 recording → "● 录制中"；目标开、实际还没到（idle / stopping / failed）→ "录制 · <state>"。
//   推流：目标关 → "推流"；publishing → "● 推流中"；connecting / backoff → "推流 · 重连中（第 n 次）"（n = Stats.encoder[i].reconnects）。
// 外部输出、多画面窗口是 W3-C / W3-E 的，按钮先置灰。
import AppKit
import SwitcherContracts

@MainActor
final class BottomBarView: NSView {
    var send: ((Command) -> Void)?
    var onAddInput: (() -> Void)?
    var onOverlayPanel: ((NSView) -> Void)?

    let addInputButton: NSButton
    let recordButton: NSButton
    let streamButton: NSButton
    let externalButton: NSButton
    let multiviewButton: NSButton
    let overlayButton: NSButton
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
        addInputButton = Theme.button("添加输入…", target: nil, action: nil)
        recordButton = Theme.toggleButton("录制", target: nil, action: nil)
        streamButton = Theme.toggleButton("推流", target: nil, action: nil)
        externalButton = Theme.button("外部输出", target: nil, action: nil)
        multiviewButton = Theme.button("多画面", target: nil, action: nil)
        overlayButton = Theme.button("叠加…", target: nil, action: nil)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor
        addInputButton.target = self; addInputButton.action = #selector(addInputPressed)
        recordButton.target = self; recordButton.action = #selector(recordPressed)
        streamButton.target = self; streamButton.action = #selector(streamPressed)
        overlayButton.target = self; overlayButton.action = #selector(overlayPressed)
        externalButton.isEnabled = false
        externalButton.toolTip = "外部输出窗口在 W3-C"
        multiviewButton.isEnabled = false
        multiviewButton.toolTip = "多画面窗口在 W3-E"
        addInputButton.keyEquivalent = "i"
        addInputButton.keyEquivalentModifierMask = [.command]

        let buttons = NSStackView(views: [addInputButton, recordButton, streamButton, externalButton, multiviewButton, overlayButton])
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
        statusLabel.stringValue = "等待第一行 Stats…"
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
        // 录制：第一个录制输出
        if let record = state.outputs.first(where: { $0.kind == .record }) {
            let actual = encoderEntry(forOutput: record.number)?.state ?? "idle"
            switch (record.enabled, actual) {
            case (true, "recording"):
                recordButton.title = "● 录制中"
                recordButton.toolTip = nil
            case (true, let s):
                recordButton.title = "录制 · \(s)"
                recordButton.toolTip = "录制输出已打开，录制器状态 \(s)"
            default:
                recordButton.title = "录制"
                recordButton.toolTip = nil
            }
            Theme.setHighlighted(recordButton, record.enabled, color: Theme.recording)
        } else {
            recordButton.title = "录制"
            recordButton.toolTip = "节目里没有录制输出：点一下会加一个默认的（~/Movies/Switcher）"
            Theme.setHighlighted(recordButton, false, color: Theme.recording)
        }
        // 推流：第一个推流输出
        if let stream = state.outputs.first(where: { $0.kind == .stream }) {
            let entry = encoderEntry(forOutput: stream.number)
            let actual = entry?.state ?? "idle"
            switch (stream.enabled, actual) {
            case (true, "publishing"):
                streamButton.title = "● 推流中"
            case (true, "connecting"), (true, "backoff"):
                streamButton.title = "推流 · 重连中（第 \((entry?.reconnects ?? 0) + 1) 次）"
            case (true, let s):
                streamButton.title = "推流 · \(s)"
            default:
                streamButton.title = "推流"
            }
            streamButton.isEnabled = true
            streamButton.toolTip = stream.settings.stream?.url
            Theme.setHighlighted(streamButton, stream.enabled, color: Theme.recording)
        } else {
            streamButton.title = "推流"
            streamButton.isEnabled = false
            streamButton.toolTip = "节目里没有推流输出（推流设置面板在 W3-E；节目文件里加一路 stream 输出即可）"
            Theme.setHighlighted(streamButton, false, color: Theme.recording)
        }
    }

    /// 新 session：忘掉上一行（fps 要重新算）。
    func resetStats() {
        previousStats = nil
        lastStatusLine = nil
        encoderStates = []
        statusLabel.stringValue = "等待第一行 Stats…"
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
        if let record = state.outputs.first(where: { $0.kind == .record }) {
            send?(record.enabled ? .stopRecord(output: record.number) : .startRecord(output: record.number))
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

    @objc private func streamPressed() {
        guard let stream = state.outputs.first(where: { $0.kind == .stream }) else { return }
        send?(stream.enabled ? .stopStream(output: stream.number) : .startStream(output: stream.number))
    }

    @objc private func overlayPressed() { onOverlayPanel?(overlayButton) }
}
