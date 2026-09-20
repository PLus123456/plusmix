// 中列：转场按钮（Cut / Fade / Wipe / Zoom / Stinger / FTB）、时长预设、Overlay 1–4 开关、T-bar、时钟。
// Wipe / Zoom / Stinger 在 W3-B 合入后（G4）接通：点 = setTransition(type, 当前时长) + autoTransition，参数（Wipe 方向 / 软边、Stinger 输入 / 换底拍）
// 来自节目文件（控件归 W3-E2，prompt 55）；FTB 是开关；Overlay 开关只改 on，不改通道用的输入
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
        wipeButton.target = self; wipeButton.action = #selector(autoPressed(_:)); wipeButton.tag = 1
        zoomButton.target = self; zoomButton.action = #selector(autoPressed(_:)); zoomButton.tag = 2
        stingerButton.target = self; stingerButton.action = #selector(autoPressed(_:)); stingerButton.tag = 3
        ftbButton.target = self; ftbButton.action = #selector(ftbPressed)
        durationControl.target = self; durationControl.action = #selector(durationChanged)
        durationControl.translatesAutoresizingMaskIntoConstraints = false
        durationControl.controlSize = .small
        durationControl.setAccessibilityLabel(L("transition.durationLabel"))
        durationControl.cell?.setAccessibilityLabel(L("transition.durationLabel"))
        for (i, b) in overlayButtons.enumerated() {
            b.tag = i + 1
            b.target = self
            b.action = #selector(overlayPressed(_:))
            b.controlSize = .small
        }
        for b in [cutButton, fadeButton, wipeButton, zoomButton, stingerButton, ftbButton] {
            b.widthAnchor.constraint(equalToConstant: Theme.transitionColumnWidth - 16).isActive = true
        }
        cutButton.toolTip = L("key.space")
        fadeButton.toolTip = L("key.return")
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
        Theme.setHighlighted(wipeButton, state.transition.isActive && state.transition.type == .wipe)
        Theme.setHighlighted(zoomButton, state.transition.isActive && state.transition.type == .zoom)
        Theme.setHighlighted(stingerButton, state.transition.isActive && state.transition.type == .stinger)
        let seconds = Double(state.transition.durationTicks) / Double(frameRate.nominalFramesPerSecond)
        if let i = Self.durationPresets.firstIndex(where: { abs($0 - seconds) < 0.01 }) {
            durationControl.selectedSegment = i
        } else {
            durationControl.selectedSegment = -1
        }
        for (i, b) in overlayButtons.enumerated() {
            let o = state.overlays[i]
            Theme.setHighlighted(b, o.on)
            b.toolTip = o.input.map { L("transition.overlayInput", i + 1, $0) } ?? L("transition.overlayNoInput", i + 1, i + 1)
        }
        tbar.apply(state: state)
    }

    /// 预设秒数换成拍数（按标称帧率取整：59.94 → 60）。
    func ticks(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(frameRate.nominalFramesPerSecond)).rounded())
    }

    @objc private func cutPressed() { send?(.cut) }

    @objc private func fadePressed() { send?(.fade(durationTicks: state.transition.durationTicks)) }

    /// Wipe / Zoom / Stinger：先把类型（时长不变）写进状态，再起 auto 转场；之后 T-bar 也按这个类型推（G4 接通）。
    @objc private func autoPressed(_ sender: NSButton) {
        let type: TransitionType = sender.tag == 1 ? .wipe : (sender.tag == 2 ? .zoom : .stinger)
        send?(.setTransition(type: type, durationTicks: state.transition.durationTicks))
        send?(.autoTransition)
    }

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
