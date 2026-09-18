// 底栏：添加输入 / 录制 / 推流 / 外部输出 / 多画面 / 叠加 按钮 + 状态行（1 Hz，全部读 Stats）。
// 录制 / 推流按钮只发 startRecord / stopRecord / startStream / stopStream，按快照里输出的 enabled 显示状态；
// 真正的录制器 / 推流器由 G3 接线（W1-E / W2-D）。外部输出、多画面窗口是 W3-C / W3-E 的，按钮先置灰。
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
    private var state = MixerState()
    private var previousStats: Stats?
    /// 最近一行 Stats 里有没有编码器在跑（录制按钮的文案用；Stats.encoder 为空 = 没有编码器接上）。
    private var encodersRunning = false
    private var format: ProgramFormat = .hd1080p60
    /// 最近一次显示的状态行（测试对照 stats.jsonl 用）。
    private(set) var lastStatusLine: (stats: Stats, text: String)?

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
        addSubview(buttons)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.bottomBarHeight),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        statusLabel.stringValue = "等待第一行 Stats…"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: MixerState) {
        self.state = state
        format = state.format
        updateRecordButton()
        let streaming = state.outputs.contains { $0.kind == .stream && $0.enabled }
        streamButton.title = streaming ? "● 推流中" : "推流"
        Theme.setHighlighted(streamButton, streaming, color: Theme.recording)
        streamButton.isEnabled = state.outputs.contains { $0.kind == .stream }
        streamButton.toolTip = streamButton.isEnabled ? nil : "节目里没有推流输出（推流设置在 W2-D / W3-E）"
    }

    /// 1 Hz：状态行。
    func apply(stats: Stats) {
        let text = StatusLineFormatter.line(current: stats, previous: previousStats, format: format)
        statusLabel.stringValue = text
        lastStatusLine = (stats, text)
        previousStats = stats
        if encodersRunning != !stats.encoder.isEmpty {
            encodersRunning = !stats.encoder.isEmpty
            updateRecordButton()
        }
    }

    /// 录制按钮：快照里录制输出的目标开关 + Stats 里有没有编码器真在跑（W2-B 还没接 Recorder，G3 接上前显示"等编码器"）。
    private func updateRecordButton() {
        let wanted = state.outputs.contains { $0.kind == .record && $0.enabled }
        switch (wanted, encodersRunning) {
        case (true, true):
            recordButton.title = "● 录制中"
            recordButton.toolTip = nil
        case (true, false):
            recordButton.title = "录制 · 等编码器"
            recordButton.toolTip = "录制输出已打开，但 Stats 里没有编码器在跑：录制器由 G3 接线（W1-E 的 Recorder）"
        default:
            recordButton.title = "录制"
            recordButton.toolTip = nil
        }
        Theme.setHighlighted(recordButton, wanted, color: Theme.recording)
    }

    /// 新 session：忘掉上一行（fps 要重新算）。
    func resetStats() {
        previousStats = nil
        lastStatusLine = nil
        statusLabel.stringValue = "等待第一行 Stats…"
    }

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
