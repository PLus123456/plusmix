// 右侧可收起的调音台：Master 推子（busGain）+ 静音（busMute）+ 表 + A1 计数。每路条子由 W3-E 做。
// 表的数字只有一个来源（AudioMixer.meters，铁律 4）：1 Hz 的 Stats.audio.meters（提案 004，P2 落地）给读数文字和 A1；
// 表的条子按 AudioEngineStatus（控制循环每 50 ms 刷新的同一份读数）每 50 ms 刷，UI 高刷新率的表允许另读这一份（Stats.swift 的说明）。
import AppKit
import SwitcherContracts

@MainActor
final class MixerPanelView: NSView {
    var send: ((Command) -> Void)?
    /// 音频引擎（换 session 时换）；nil = 表不动。
    var audio: AudioRuntime? {
        didSet { restartMeterTimer() }
    }
    let fader = NSSlider()
    let muteButton: NSButton
    let meter = LevelMeterView(frame: .zero)
    private let gainLabel = Theme.monoLabel("0.0 dB", size: 12)
    private let meterLabel = Theme.monoLabel("−∞ dBFS", size: 10, color: Theme.dimText)
    private let audioStatsLabel = Theme.monoLabel("A1 — / —", size: 10, color: Theme.dimText)
    private var muted = false
    private var meterTimer: Timer?
    /// 最近一次从 Stats 读到的 Master 峰值（dBFS，[L, R]；nil = 还没有）。测试看。
    private(set) var masterPeakDb: [Double]?
    /// 推子范围（dB）。
    static let faderRange = -60.0...12.0
    /// 表的刷新间隔（与 AudioEngine.statusInterval 一样 50 ms）。
    static let meterInterval: TimeInterval = 0.05
    /// 低于它显示 −∞（Stats 的 dB 下限是 −120）。
    static let silenceDb = -119.0

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
        meterLabel.alignment = .center
        meterLabel.toolTip = "Master 峰值（Stats.audio.meters，1 Hz）"
        audioStatsLabel.alignment = .center
        audioStatsLabel.toolTip = "Stats.audio：dropouts / underruns / discontinuities 累计"
        meter.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [fader, meter])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let placeholder = Theme.label("每路条子：W3-E", size: 10, color: Theme.dimText)
        placeholder.alignment = .center
        let stack = NSStackView(views: [title, row, gainLabel, meterLabel, muteButton, audioStatsLabel, placeholder])
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

    /// 1 Hz：读数文字 + A1。
    func apply(stats: Stats) {
        let a = stats.audio
        audioStatsLabel.stringValue = "A1 \(a.dropouts) / \(a.underruns) / \(a.discontinuities)"
        if let master = a.meters.buses.first(where: { $0.bus == Bus.master.name }) {
            masterPeakDb = master.peakDb
            meterLabel.stringValue = Self.peakText(master.peakDb)
        } else {
            masterPeakDb = nil
            meterLabel.stringValue = "−∞ dBFS"
        }
    }

    /// "−20.1 dBFS"（取 L / R 的最大值）；静音显示 −∞。
    static func peakText(_ peakDb: [Double]) -> String {
        guard let m = peakDb.max(), m > silenceDb else { return "−∞ dBFS" }
        return String(format: "%.1f dBFS", m)
    }

    // MARK: 表的条子（50 ms，AudioEngineStatus）

    private func restartMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        meter.level = nil
        guard audio != nil else { return }
        let t = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeter() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func refreshMeter() {
        guard let audio, let master = audio.status.buses.first(where: { $0.bus == .master }) else { meter.level = nil; return }
        let peak = master.peakDb.max() ?? Self.silenceDb
        meter.level = peak > Self.silenceDb ? peak : nil
    }

    @objc private func faderChanged() {
        let v = (fader.doubleValue * 10).rounded() / 10
        send?(.busGain(bus: .master, dB: v <= Self.faderRange.lowerBound ? InputAudioSettings.gainRangeDb.lowerBound : v))
    }

    @objc private func mutePressed() { send?(.busMute(bus: .master, on: !muted)) }

    var displayedGain: String { gainLabel.stringValue }
    var displayedPeak: String { meterLabel.stringValue }
}

/// 竖表：0 … −60 dBFS 刻度，level = nil 画 −∞。
@MainActor
final class LevelMeterView: NSView {
    var level: Double? {
        didSet { if level != oldValue { needsDisplay = true } }
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
