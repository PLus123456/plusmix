// 输入缩略图格子：标题条（编号、名字、tally 色）、缩略图（多画面纹理里这一路的格子，切掉渲染器画在格子底部的名字条——名字只在标题条出现一次，
// W3-E3；≤ 24 fps）、底行 Overlay 1–4 小按钮 + 静音小按钮。点缩略图 = 选 PVW，Shift 点 = 直切 PGM。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputCellView: NSView {
    let number: Int
    var send: ((Command) -> Void)?
    /// 右键"设置…"。
    var onOpenSettings: ((Int) -> Void)?
    /// 底行 Overlay k 小按钮的右键"叠加设置…"（W5-K / I1：直达第 k 路）。
    var onOverlaySettings: ((Int) -> Void)?
    /// 删这一路会碰到的地方（InputStripView 按快照填；空 = 直接删，W5-B）。
    var removalImpacts: [InputRemovalImpact] = []
    let display = MetalDisplayView(frame: .zero)
    private let titleBar = PanelView(color: Theme.tallyOff)
    private let numberLabel = Theme.monoLabel("", size: 12, color: .white)
    private let nameLabel = Theme.label("", size: 11, weight: .semibold, color: .white)
    private let statusLabel = Theme.label("", size: 10, color: .white)
    let overlayButtons: [NSButton]
    let muteButton: NSButton
    /// 纯音频输入的占位（W3-E2 / W2-A2 口径：没有画面，画话筒 + 名字 + 电平表，不显示成"无信号"的黑块）。
    private let audioPlaceholder = NSStackView()
    private let audioIcon = NSImageView()
    private let audioName = Theme.label("", size: 11, weight: .semibold, color: .white)
    /// 电平表（推子后峰值，-60 … 0 dBFS；读调音台同一份 AudioEngineStatus）。
    let audioMeter = NSLevelIndicator()
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
        muteButton = Theme.toggleButton(L("mixer.mute"), target: nil, action: nil)
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
            b.menu = OverlaySettingsMenu.make(channel: b.tag, target: self, action: #selector(overlaySettingsPressed(_:)))
        }
        muteButton.target = self
        muteButton.action = #selector(mutePressed)
        audioIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: L("cell.audioOnly"))
        audioIcon.contentTintColor = Theme.dimText
        audioIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        audioMeter.levelIndicatorStyle = .continuousCapacity
        audioMeter.minValue = 0
        audioMeter.maxValue = 1
        audioMeter.warningValue = 0.7     // −18 dBFS：与调音台 MeterBar / 多画面电平表同一套分段（设计方案 §7，2026-09-24 定）
        audioMeter.criticalValue = 0.9    // −6 dBFS
        audioMeter.setAccessibilityLabel(L("mixer.meter"))
        audioMeter.widthAnchor.constraint(equalToConstant: Theme.thumbnailWidth - 40).isActive = true
        for v in [audioIcon, audioName, audioMeter] as [NSView] { audioPlaceholder.addArrangedSubview(v) }
        audioPlaceholder.orientation = .vertical
        audioPlaceholder.spacing = 6
        audioPlaceholder.alignment = .centerX
        audioPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        audioPlaceholder.isHidden = true

        let buttonRow = NSStackView(views: overlayButtons + [muteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 2
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar)
        titleBar.addSubview(numberLabel)
        titleBar.addSubview(nameLabel)
        addSubview(display)
        addSubview(audioPlaceholder)
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
            audioPlaceholder.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            audioPlaceholder.centerYAnchor.constraint(equalTo: display.centerYAnchor, constant: -8),
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
        self.runtime = runtime
        audioName.stringValue = config.name
        updateStatus()
        toolTip = L("cell.tooltip", config.number, config.name, L("addInput.kind.\(config.kind.rawValue)"))
    }

    /// 缩略图取多画面纹理里的哪一块（InputStripView.thumbnailRect：按当前布局算好的内框、去掉底部名字条）；nil = 布局里没有这一路（自定义格子没放它），不画、写一句说明。
    func setThumbnail(rect: NormalizedRect?) {
        isOutsideMultiviewLayout = rect == nil
        display.sourceRect = rect ?? .full
        updateStatus()
    }

    /// 布局里没有这一路（缩略图画不出来）。
    private(set) var isOutsideMultiviewLayout = false
    private var runtime: InputState?

    /// 纯音频输入（没有画面）：格子画占位，不画多画面格子。视频文件输入选的是 mp3 / wav / m4a / aac 也算（W5-K，04 Q57）。
    var isAudioOnly: Bool {
        if config.kind == .audio { return true }
        if case .file(let path, _, _) = config.source { return MediaFileInfo.isAudioFile(path) }
        return false
    }

    /// 电平（推子后峰值 dBFS，[L, R]；nil = 没有读数）→ 占位里的表（-60 … 0 dBFS 线性映射到 0 … 1）。只对纯音频输入有意义。
    func applyAudioLevel(_ peakDb: [Double]?) {
        guard isAudioOnly else { return }
        let level = peakDb?.max().map { min(max(1 + $0 / 60, 0), 1) } ?? 0
        if abs(audioMeter.doubleValue - level) > 0.001 { audioMeter.doubleValue = level }
    }

    /// 格子中间那行字：运行状态（无信号 / 错误文案）优先，其次"不在多画面布局里"。纯音频输入没有画面不算无信号：
    /// 设备不在（noSignal）写"等音频设备"，权限被拒等（error）照样显示文案。
    private func updateStatus() {
        let audioOnly = isAudioOnly
        display.isHidden = audioOnly || isOutsideMultiviewLayout
        audioPlaceholder.isHidden = !audioOnly
        let text: String?
        switch runtime {
        case .noSignal?: text = audioOnly ? L("input.audioWaiting") : L("input.noSignal")
        case .error(let message)?: text = message
        case .live?, nil: text = (!audioOnly && isOutsideMultiviewLayout) ? L("cell.notInMultiview") : nil
        }
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    /// 格子上现在显示的状态文字（没有为空串；测试看）。
    var displayedStatus: String { statusLabel.isHidden ? "" : statusLabel.stringValue }

    /// 搜索匹配：编号或名字包含关键字。
    func matches(search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return "\(config.number)" == q || config.name.localizedCaseInsensitiveContains(q)
    }

    /// 右键：设置 / 重命名 / 删除（稿子里每格的 Close；完整的输入设置在 W3-E）。"删除"和前两项之间隔一条线（W5-B，D9）。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L("cell.menu.settings"), action: #selector(settingsPressed), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("cell.menu.rename"), action: #selector(renamePressed), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("cell.menu.remove", number), action: #selector(removePressed), keyEquivalent: "").target = self
        return menu
    }

    @objc private func settingsPressed() { onOpenSettings?(number) }

    @objc private func renamePressed() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("cell.rename.title", number)
        let field = NSTextField(string: config.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel(L("cell.rename.field"))
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { self.send?(.renameInput(input: self.number, name: name)) }
            }
        }
    }

    @objc private func removePressed() { requestRemoval() }

    /// 删这一路（右键"删除输入 n"）：在 PGM / PVW / 叠加 / Stinger / ISO 录制上时先确认、写明后果；其余直接删（W5-B，D9 / X13）。
    func requestRemoval() {
        guard !removalImpacts.isEmpty, let window else {
            send?(.removeInput(input: number))
            return
        }
        let message = (removalImpacts.map(\.text) + [L("confirm.removeInput.noUndo")]).joined(separator: "\n")
        let request = ConfirmationCenter.Request(kind: .removeInput, title: L("confirm.removeInput.title", number, config.name), message: message,
                                                 buttons: [.init(title: L("confirm.removeInput.button"), choice: .confirm, destructive: true),
                                                           .init(title: L("common.cancel"), choice: .cancel)],
                                                 defaultChoice: nil)
        let number = number
        let send = send
        ConfirmationCenter.shared.ask(request, in: window) { choice in
            if choice == .confirm { send?(.removeInput(input: number)) }
        }
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

    @objc private func overlaySettingsPressed(_ sender: NSMenuItem) { onOverlaySettings?(sender.tag) }

    @objc private func mutePressed() {
        send?(.mute(input: number, on: !config.settings.audio.muted))
    }

    var displayedName: String { nameLabel.stringValue }
    var titleColor: NSColor { titleBar.backgroundColor }
}
