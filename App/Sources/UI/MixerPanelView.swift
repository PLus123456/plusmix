// 右侧可收起的调音台占位：Master 推子（busGain）+ 静音（busMute）+ 表。每路条子由 W3-E 做。
// 表读 Stats：现在 Stats 里没有电平字段（W2-E 的"表读数进 Stats 和快照"要走契约提案），所以表只显示 −∞ 和 A1 计数
// （dropouts / underruns），不在 UI 里另算电平（铁律 4）。
import AppKit
import SwitcherContracts

@MainActor
final class MixerPanelView: NSView {
    var send: ((Command) -> Void)?
    let fader = NSSlider()
    let muteButton: NSButton
    let meter = LevelMeterView(frame: .zero)
    private let gainLabel = Theme.monoLabel("0.0 dB", size: 12)
    private let audioStatsLabel = Theme.monoLabel("A1 — / —", size: 10, color: Theme.dimText)
    private var muted = false
    /// 推子范围（dB）。
    static let faderRange = -60.0...12.0

    override init(frame: NSRect) {
        muteButton = Theme.toggleButton("静音", target: nil, action: nil)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor
        let title = Theme.label("Master", size: 13, weight: .semibold)
        title.alignment = .center
        fader.isVertical = true
        fader.minValue = Self.faderRange.lowerBound
        fader.maxValue = Self.faderRange.upperBound
        fader.doubleValue = 0
        fader.numberOfTickMarks = 7
        fader.allowsTickMarkValuesOnly = false
        fader.target = self
        fader.action = #selector(faderChanged)
        fader.isContinuous = true
        fader.translatesAutoresizingMaskIntoConstraints = false
        muteButton.target = self
        muteButton.action = #selector(mutePressed)
        muteButton.controlSize = .small
        gainLabel.alignment = .center
        audioStatsLabel.alignment = .center
        audioStatsLabel.toolTip = "Stats.audio：dropouts / underruns 累计；电平表等 W2-E 把表读数放进 Stats"
        meter.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [fader, meter])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let placeholder = Theme.label("每路条子：W3-E", size: 10, color: Theme.dimText)
        placeholder.alignment = .center
        let stack = NSStackView(views: [title, row, gainLabel, muteButton, audioStatsLabel, placeholder])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 220),
            meter.widthAnchor.constraint(equalToConstant: 24),
            meter.heightAnchor.constraint(equalTo: row.heightAnchor),
            fader.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: MixerState) {
        guard let master = state.audio.buses.first(where: { $0.bus == .master }) else { return }
        if !fader.isHighlighted || abs(fader.doubleValue - master.gainDb) > 0.05 {
            fader.doubleValue = min(max(master.gainDb, Self.faderRange.lowerBound), Self.faderRange.upperBound)
        }
        gainLabel.stringValue = master.gainDb <= Self.faderRange.lowerBound ? "−∞ dB" : String(format: "%+.1f dB", master.gainDb)
        muted = master.muted
        Theme.setHighlighted(muteButton, muted, color: Theme.recording)
    }

    func apply(stats: Stats) {
        audioStatsLabel.stringValue = "A1 \(stats.audio.dropouts) / \(stats.audio.underruns)"
        meter.level = nil   // Stats 无电平字段
    }

    @objc private func faderChanged() {
        let v = (fader.doubleValue * 10).rounded() / 10
        send?(.busGain(bus: .master, dB: v <= Self.faderRange.lowerBound ? InputAudioSettings.gainRangeDb.lowerBound : v))
    }

    @objc private func mutePressed() { send?(.busMute(bus: .master, on: !muted)) }

    var displayedGain: String { gainLabel.stringValue }
}

/// 竖表：0 … −60 dBFS 刻度，level = nil 画 −∞。
@MainActor
final class LevelMeterView: NSView {
    var level: Double? {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        let inner = bounds.insetBy(dx: 4, dy: 4)
        Theme.divider.setFill()
        inner.fill()
        for (i, db) in [0, -6, -12, -24, -40].enumerated() {
            let y = inner.minY + inner.height * CGFloat(1 + Double(db) / 60)
            (i == 0 ? Theme.recording : Theme.dimText).setFill()
            NSRect(x: inner.minX, y: y, width: inner.width, height: 1).fill()
        }
        if let level {
            let h = inner.height * CGFloat(min(max(1 + level / 60, 0), 1))
            Theme.tallyPreview.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: h).fill()
        }
    }
}
