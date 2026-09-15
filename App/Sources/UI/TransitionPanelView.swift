// 中列：转场按钮（Cut / Fade / Wipe / Zoom / Stinger / FTB）、时长预设、Overlay 1–4 开关、T-bar、时钟。
// 本期只有 Cut / Fade 可用，Wipe / Zoom / Stinger 置灰（W3-B 做渲染）；FTB 是开关；Overlay 开关只改 on，不改通道用的输入
// （给通道选输入在缩略图格子的小按钮和底栏的叠加面板）。所有动作只发 Command，显示只读快照。
import AppKit
import SwitcherContracts

@MainActor
final class TransitionPanelView: NSView {
    var send: ((Command) -> Void)?

    let cutButton: NSButton
    let fadeButton: NSButton
    let wipeButton: NSButton
    let zoomButton: NSButton
    let stingerButton: NSButton
    let ftbButton: NSButton
    let durationControl: NSSegmentedControl
    let overlayButtons: [NSButton]
    let tbar = TBarView(frame: .zero)
    let clock = ClockView(frame: .zero)

    /// 预设时长（秒）。
    static let durationPresets: [Double] = [0.5, 1, 2]
    private var frameRate: FrameRate = .fps60
    private var state = MixerState()

    override init(frame: NSRect) {
        cutButton = Theme.button("Cut", target: nil, action: nil)
        fadeButton = Theme.toggleButton("Fade", target: nil, action: nil)
        wipeButton = Theme.button("Wipe", target: nil, action: nil)
        zoomButton = Theme.button("Zoom", target: nil, action: nil)
        stingerButton = Theme.button("Stinger", target: nil, action: nil)
        ftbButton = Theme.toggleButton("FTB", target: nil, action: nil)
        durationControl = NSSegmentedControl(labels: Self.durationPresets.map { $0 == 0.5 ? "0.5s" : "\(Int($0))s" },
                                             trackingMode: .selectOne, target: nil, action: nil)
        overlayButtons = (1...MixerState.overlayCount).map { Theme.toggleButton("\($0)", target: nil, action: nil) }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panelBackground.cgColor

        cutButton.target = self; cutButton.action = #selector(cutPressed)
        fadeButton.target = self; fadeButton.action = #selector(fadePressed)
        ftbButton.target = self; ftbButton.action = #selector(ftbPressed)
        durationControl.target = self; durationControl.action = #selector(durationChanged)
        durationControl.translatesAutoresizingMaskIntoConstraints = false
        durationControl.controlSize = .small
        for (i, b) in overlayButtons.enumerated() {
            b.tag = i + 1
            b.target = self
            b.action = #selector(overlayPressed(_:))
            b.controlSize = .small
        }
        for b in [wipeButton, zoomButton, stingerButton] {
            b.isEnabled = false
            b.toolTip = "W3-B 做"
        }
        for b in [cutButton, fadeButton, wipeButton, zoomButton, stingerButton, ftbButton] {
            b.widthAnchor.constraint(equalToConstant: Theme.transitionColumnWidth - 16).isActive = true
        }
        cutButton.toolTip = "空格"
        fadeButton.toolTip = "回车"
        ftbButton.toolTip = "F"
        tbar.onProgress = { [weak self] p in self?.send?(.tbar(progress: p)) }

        let overlayRow = NSStackView(views: overlayButtons)
        overlayRow.orientation = .horizontal
        overlayRow.spacing = 2
        overlayRow.distribution = .fillEqually
        overlayRow.translatesAutoresizingMaskIntoConstraints = false
        let overlayLabel = Theme.label("Overlay", size: 10, color: Theme.dimText)
        overlayLabel.alignment = .center

        let stack = NSStackView(views: [cutButton, fadeButton, wipeButton, zoomButton, stingerButton, ftbButton,
                                        durationControl, overlayLabel, overlayRow, tbar, clock])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Theme.transitionColumnWidth),
            tbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            clock.heightAnchor.constraint(equalToConstant: 64),
        ])
        tbar.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 快照 → 按钮状态。
    func apply(state: MixerState) {
        self.state = state
        frameRate = state.format.frameRate
        Theme.setHighlighted(ftbButton, state.ftb.on, color: Theme.ftbActive)
        Theme.setHighlighted(fadeButton, state.transition.isActive && state.transition.type == .fade)
        let seconds = Double(state.transition.durationTicks) / Double(frameRate.nominalFramesPerSecond)
        if let i = Self.durationPresets.firstIndex(where: { abs($0 - seconds) < 0.01 }) {
            durationControl.selectedSegment = i
        } else {
            durationControl.selectedSegment = -1
        }
        for (i, b) in overlayButtons.enumerated() {
            let o = state.overlays[i]
            Theme.setHighlighted(b, o.on)
            b.toolTip = o.input.map { "Overlay \(i + 1)：输入 \($0)" } ?? "Overlay \(i + 1)：还没指定输入（在缩略图格子上点 \(i + 1)）"
        }
        tbar.apply(state: state)
    }

    /// 预设秒数换成拍数（按标称帧率取整：59.94 → 60）。
    func ticks(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(frameRate.nominalFramesPerSecond)).rounded())
    }

    @objc private func cutPressed() { send?(.cut) }

    @objc private func fadePressed() { send?(.fade(durationTicks: state.transition.durationTicks)) }

    @objc private func ftbPressed() { send?(.ftb(on: !state.ftb.on)) }

    @objc private func durationChanged() {
        let i = durationControl.selectedSegment
        guard i >= 0, i < Self.durationPresets.count else { return }
        send?(.setTransition(type: state.transition.type, durationTicks: ticks(forSeconds: Self.durationPresets[i])))
    }

    @objc private func overlayPressed(_ sender: NSButton) {
        let channel = sender.tag
        guard channel >= 1, channel <= MixerState.overlayCount else { return }
        send?(.overlay(channel: channel, on: !state.overlays[channel - 1].on, input: nil))
    }
}
