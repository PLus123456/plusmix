// 输入缩略图格子：标题条（编号、名字、tally 色）、缩略图（多画面纹理里这一路的格子，≤ 24 fps）、
// 底行 Overlay 1–4 小按钮 + 静音小按钮。点缩略图 = 选 PVW，Shift 点 = 直切 PGM。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputCellView: NSView {
    let number: Int
    var send: ((Command) -> Void)?
    let display = MetalDisplayView(frame: .zero)
    private let titleBar = PanelView(color: Theme.tallyOff)
    private let numberLabel = Theme.monoLabel("", size: 12, color: .white)
    private let nameLabel = Theme.label("", size: 11, weight: .semibold, color: .white)
    private let statusLabel = Theme.label("", size: 10, color: .white)
    let overlayButtons: [NSButton]
    let muteButton: NSButton
    private var config: InputConfig
    private var tally = Tally.off
    /// 缩略图刷新率上限（prompt：≤ 24 fps）。
    static let thumbnailFrameRate = 24

    init(config: InputConfig) {
        number = config.number
        self.config = config
        overlayButtons = (1...MixerState.overlayCount).map { k in
            let b = Theme.toggleButton("\(k)", target: nil, action: nil)
            b.controlSize = .mini
            b.tag = k
            return b
        }
        muteButton = Theme.toggleButton("静音", target: nil, action: nil)
        muteButton.controlSize = .mini
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.cellBackground.cgColor
        display.target = .multiview
        display.maxFramesPerSecond = Self.thumbnailFrameRate
        display.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.backgroundColor = NSColor(white: 0, alpha: 0.6)
        statusLabel.drawsBackground = true
        statusLabel.isHidden = true
        for b in overlayButtons {
            b.target = self
            b.action = #selector(overlayPressed(_:))
        }
        muteButton.target = self
        muteButton.action = #selector(mutePressed)

        let buttonRow = NSStackView(views: overlayButtons + [muteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 2
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar)
        titleBar.addSubview(numberLabel)
        titleBar.addSubview(nameLabel)
        addSubview(display)
        addSubview(statusLabel)
        addSubview(buttonRow)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.thumbnailWidth),
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 20),
            numberLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 6),
            numberLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleBar.trailingAnchor, constant: -6),
            nameLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            display.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            display.leadingAnchor.constraint(equalTo: leadingAnchor),
            display.trailingAnchor.constraint(equalTo: trailingAnchor),
            display.heightAnchor.constraint(equalToConstant: Theme.thumbnailHeight),
            statusLabel.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: display.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: display.widthAnchor, constant: -8),
            buttonRow.topAnchor.constraint(equalTo: display.bottomAnchor, constant: 3),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        apply(config: config, tally: .off, overlays: [], runtime: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 快照里这一路的部分 + 运行状态。
    func apply(config: InputConfig, tally: Tally, overlays: [OverlayState], runtime: InputState?) {
        self.config = config
        self.tally = tally
        numberLabel.stringValue = "\(config.number)"
        nameLabel.stringValue = config.name
        titleBar.backgroundColor = tally.program ? Theme.tallyProgram : (tally.preview ? Theme.tallyPreview : Theme.tallyOff)
        layer?.borderWidth = tally.program || tally.preview ? 2 : 0
        layer?.borderColor = (tally.program ? Theme.tallyProgram : Theme.tallyPreview).cgColor
        for (i, b) in overlayButtons.enumerated() where i < overlays.count {
            Theme.setHighlighted(b, overlays[i].on && overlays[i].input == config.number)
        }
        Theme.setHighlighted(muteButton, config.settings.audio.muted, color: Theme.recording)
        switch runtime {
        case .live?, nil:
            statusLabel.isHidden = true
        case .noSignal?:
            statusLabel.stringValue = "无信号"
            statusLabel.isHidden = false
        case .error(let message)?:
            statusLabel.stringValue = message
            statusLabel.isHidden = false
        }
        toolTip = "\(config.number) \(config.name)（\(config.kind)）\n点击 = 选 PVW，Shift 点击 = 直切 PGM"
    }

    /// 缩略图取多画面纹理里的哪一块（index = 在 MixerState.inputs 里的序号）。
    func setThumbnail(index: Int, inputCount: Int, textureWidth: Int, textureHeight: Int) {
        display.sourceRect = MultiviewLayout.inputCell(index: index, inputCount: inputCount, width: textureWidth, height: textureHeight) ?? .full
    }

    /// 搜索匹配：编号或名字包含关键字。
    func matches(search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return "\(config.number)" == q || config.name.localizedCaseInsensitiveContains(q)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard display.frame.contains(p) || titleBar.frame.contains(p) else { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.shift) {
            send?(.setProgram(input: number))
        } else {
            send?(.setPreview(input: number))
        }
    }

    @objc private func overlayPressed(_ sender: NSButton) {
        let channel = sender.tag
        // 已经是这一路且开着 → 关；否则把通道换成这一路并打开
        if let on = overlayOn(channel), on {
            send?(.overlay(channel: channel, on: false, input: nil))
        } else {
            send?(.overlay(channel: channel, on: true, input: number))
        }
    }

    private func overlayOn(_ channel: Int) -> Bool? {
        guard channel >= 1, channel <= overlayButtons.count else { return nil }
        return overlayButtons[channel - 1].bezelColor != nil
    }

    @objc private func mutePressed() {
        send?(.mute(input: number, on: !config.settings.audio.muted))
    }

    var displayedName: String { nameLabel.stringValue }
    var titleColor: NSColor { titleBar.backgroundColor }
}
