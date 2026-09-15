// 叠加面板（底栏"叠加…"弹出）：Overlay 1–4 各选一路输入 + 开关。位置 / 动画在 W3-B / W3-E。
import AppKit
import SwitcherContracts

@MainActor
final class OverlayPanelController: NSViewController {
    var send: ((Command) -> Void)?
    private var state: MixerState
    private var popups: [NSPopUpButton] = []
    private var toggles: [NSButton] = []

    init(state: MixerState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for channel in 1...MixerState.overlayCount {
            let popup = NSPopUpButton()
            popup.addItem(withTitle: "（无）")
            for input in state.inputs { popup.addItem(withTitle: "\(input.number) \(input.name)") }
            popup.tag = channel
            popup.target = self
            popup.action = #selector(inputChanged(_:))
            let toggle = Theme.toggleButton("开", target: self, action: #selector(togglePressed(_:)))
            toggle.tag = channel
            toggle.controlSize = .small
            let row = NSStackView(views: [Theme.label("Overlay \(channel)", size: 12), popup, toggle])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
            popups.append(popup)
            toggles.append(toggle)
        }
        view = stack
        apply(state: state)
    }

    func apply(state: MixerState) {
        self.state = state
        guard !popups.isEmpty else { return }
        for (i, o) in state.overlays.enumerated() {
            if let input = o.input, let idx = state.inputs.firstIndex(where: { $0.number == input }) {
                popups[i].selectItem(at: idx + 1)
            } else {
                popups[i].selectItem(at: 0)
            }
            toggles[i].title = o.on ? "开" : "关"
            Theme.setHighlighted(toggles[i], o.on)
        }
    }

    @objc private func inputChanged(_ sender: NSPopUpButton) {
        let channel = sender.tag
        let idx = sender.indexOfSelectedItem - 1
        guard idx >= 0, idx < state.inputs.count else { return }
        send?(.overlay(channel: channel, on: state.overlays[channel - 1].on, input: state.inputs[idx].number))
    }

    @objc private func togglePressed(_ sender: NSButton) {
        let channel = sender.tag
        send?(.overlay(channel: channel, on: !state.overlays[channel - 1].on, input: nil))
    }
}
