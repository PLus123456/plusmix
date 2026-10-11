// 输入缩略图格子：标题条（编号、分类色点、名字、tally 色）、缩略图（多画面纹理里这一路的格子，切掉渲染器画在格子底部的名字条——名字只在标题条出现一次，
// W3-E3；≤ 24 fps；W5-H 起显示框按裁切后的比例，上下不再留黑边，03 V-23）、两行按钮（W5-H，01a D4 / D6 / D7，04 Q26 (a) 两行常显）：
//   第一行 ×（删除：在 PGM / PVW / 叠加 / Stinger / ISO 录制上先确认，87 的口径，Q06 (a)）｜ 转场（按当前转场送上 PGM = setPreview + autoTransition，
//          W5-M 起 = 当前槽，与回车 / T-bar 同一个，Q39）｜ Cut（setProgram，直切、不经过 PVW）｜ 循环（只对文件输入：setInputSource 只改结束动作，运行表不重建）
//   第二行 Overlay 1–4 ｜ 静音（没有声音的输入灰着并说明，D7）｜ ⚙（这一路的输入设置，D6）
// 点缩略图 = 选 PVW，Shift 点 = 直切 PGM（保留）。**转场进行中**（快照 transition.isActive，T-bar 推到一半也算；90 报告 §5 第 1 条）："转场 / Cut"置灰，
// 点缩略图也不发命令、状态行说一句——reducer 已经拒收这两条，界面不发是因为"setPreview + autoTransition"这类组合在转场中前一条被拒、后一条会把正在进行的
// 那次做完，落在别的画面上。右键菜单补齐常用动作（D8）。所有按钮 refusesFirstResponder（空格仍是 Cut）。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class InputCellView: NSView {
    let number: Int
    var send: ((Command) -> Void)?
    /// ⚙ / 右键"设置…"。
    var onOpenSettings: ((Int) -> Void)?
    /// 右键"换来源…"：输入设置窗直接停在"来源"一节。
    var onChangeSource: ((Int) -> Void)?
    /// 右键"分类 ▸"选了一类（nil = 无）。
    var onSetCategory: ((Int, InputCategories.Color?) -> Void)?
    /// 状态行提示（转场进行中点了缩略图）。
    var onNotice: ((String) -> Void)?
    /// 底行 Overlay k 小按钮的右键"叠加设置…"（W5-K / I1：直达第 k 路）。
    var onOverlaySettings: ((Int) -> Void)?
    /// 删这一路会碰到的地方（InputStripView 按快照填；空 = 直接删，W5-B）。
    var removalImpacts: [InputRemovalImpact] = []
    let display = MetalDisplayView(frame: .zero)
    private let titleBar = PanelView(color: Theme.tallyOff)
    private let numberLabel = Theme.monoLabel("", size: 12, color: .white)
    private let categoryDot = CategoryDotView()
    private let nameLabel = Theme.label("", size: 11, weight: .semibold, color: .white)
    private let statusLabel = Theme.label("", size: 10, color: .white)
    // 第一行
    let removeButton: NSButton
    let transitionButton: NSButton
    let cutButton: NSButton
    let loopButton: NSButton
    let playButton: NSButton
    let restartButton: NSButton
    // 第二行
    let overlayButtons: [NSButton]
    let muteButton: NSButton
    let gearButton: NSButton
    var firstRowButtons: [NSButton] { [removeButton, transitionButton, cutButton, loopButton] }
    var secondRowButtons: [NSButton] { overlayButtons + [muteButton, gearButton] }
    /// 纯音频输入的占位（W3-E2 / W2-A2 口径：没有画面，画话筒 + 名字 + 电平表，不显示成"无信号"的黑块）。
    private let audioPlaceholder = NSStackView()
    private let audioIcon = NSImageView()
    private let audioName = Theme.label("", size: 11, weight: .semibold, color: .white)
    /// 电平表（推子后峰值，-60 … 0 dBFS；读调音台同一份 AudioEngineStatus）。
    let audioMeter = NSLevelIndicator()
    private var config: InputConfig
    private var tally = Tally.off
    private var widthConstraint: NSLayoutConstraint!
    private var displayHeightConstraint: NSLayoutConstraint!
    /// 缩略图刷新率上限（prompt：≤ 24 fps）。
    static let thumbnailFrameRate = 24
    /// 两行按钮的高（mini 推按钮）与行距 / 上下留白。
    static let buttonRowHeight: CGFloat = 16
    static let titleBarHeight: CGFloat = 20
    private static let rowGap: CGFloat = 2
    private static let rowInset: CGFloat = 3

    /// 格子总高：标题条 + 缩略图框 + 两行按钮（输入条按它算最小高）。
    static func height(thumbnailHeight: CGFloat) -> CGFloat {
        titleBarHeight + thumbnailHeight + rowInset + buttonRowHeight + rowGap + buttonRowHeight + rowInset
    }

    /// 缩略图框的高 = 宽 × 裁切后那块（纹理像素）的高宽比；裁不出来（布局里没有这一路）按 16:9。不高于 16:9 的框（自定义格子再高也只是左右留边）。
    static func thumbnailHeight(width: CGFloat, rect: NormalizedRect?, textureWidth: Int, textureHeight: Int) -> CGFloat {
        guard let rect, rect.width > 0, rect.height > 0, textureWidth > 0, textureHeight > 0 else { return (width * 9 / 16).rounded() }
        let aspect = (rect.height * Double(textureHeight)) / (rect.width * Double(textureWidth))
        return min(width * 9 / 16, max(width * 0.3, (width * CGFloat(aspect)).rounded()))
    }

    init(config: InputConfig) {
        number = config.number
        self.config = config
        removeButton = Self.cellButton("×")
        transitionButton = Self.cellButton(L("cell.transition"))
        cutButton = Self.cellButton(L("cell.cut"))
        loopButton = Self.cellButton(L("cell.loop"))
        playButton = Self.cellButton("▶")
        restartButton = Self.cellButton("⟲")
        overlayButtons = (1...MixerState.overlayCount).map { k in
            let b = Self.cellButton("\(k)")
            b.tag = k
            return b
        }
        muteButton = Self.cellButton(L("mixer.mute"))
        gearButton = Self.cellButton("")
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
        removeButton.action = #selector(removePressed)
        removeButton.setAccessibilityLabel(L("cell.remove.a11y", number))
        removeButton.toolTip = L("cell.remove.tip")
        transitionButton.action = #selector(transitionPressed)
        cutButton.action = #selector(cutPressed)
        loopButton.action = #selector(loopPressed)
        for b in overlayButtons {
            b.action = #selector(overlayPressed(_:))
            b.setAccessibilityLabel(L("cell.overlay.a11y", b.tag))
            b.menu = OverlaySettingsMenu.make(channel: b.tag, target: self, action: #selector(overlaySettingsPressed(_:)))
        }
        muteButton.action = #selector(mutePressed)
        gearButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("cell.gear.a11y", number))
        gearButton.imagePosition = .imageOnly
        gearButton.action = #selector(settingsPressed)
        gearButton.setAccessibilityLabel(L("cell.gear.a11y", number))
        gearButton.toolTip = L("cell.gear.tip")
        for b in firstRowButtons + secondRowButtons { b.target = self }
        audioIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: L("cell.audioOnly"))
        audioIcon.contentTintColor = Theme.dimText
        audioIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        audioMeter.levelIndicatorStyle = .continuousCapacity
        audioMeter.minValue = 0
        audioMeter.maxValue = 1
        audioMeter.warningValue = 0.7     // −18 dBFS：与调音台 MeterBar / 多画面电平表同一套分段（设计方案 §7，2026-09-24 定）
        audioMeter.criticalValue = 0.9    // −6 dBFS
        audioMeter.setAccessibilityLabel(L("mixer.meter"))
        for v in [audioIcon, audioName, audioMeter] as [NSView] { audioPlaceholder.addArrangedSubview(v) }
        audioPlaceholder.orientation = .vertical
        audioPlaceholder.spacing = 6
        audioPlaceholder.alignment = .centerX
        audioPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        audioPlaceholder.isHidden = true
        categoryDot.isHidden = true

        let firstRow = Self.row(firstRowButtons)
        let secondRow = Self.row(secondRowButtons)
        addSubview(titleBar)
        titleBar.addSubview(numberLabel)
        titleBar.addSubview(categoryDot)
        titleBar.addSubview(nameLabel)
        addSubview(display)
        addSubview(audioPlaceholder)
        addSubview(statusLabel)
        addSubview(firstRow)
        addSubview(secondRow)
        widthConstraint = widthAnchor.constraint(equalToConstant: Theme.thumbnailWidth)
        displayHeightConstraint = display.heightAnchor.constraint(equalToConstant: Theme.thumbnailHeight)
        NSLayoutConstraint.activate([
            widthConstraint,
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),
            numberLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 6),
            numberLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            categoryDot.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 5),
            categoryDot.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            categoryDot.widthAnchor.constraint(equalToConstant: 9),
            categoryDot.heightAnchor.constraint(equalToConstant: 9),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleBar.trailingAnchor, constant: -6),
            nameLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            display.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            display.leadingAnchor.constraint(equalTo: leadingAnchor),
            display.trailingAnchor.constraint(equalTo: trailingAnchor),
            displayHeightConstraint,
            audioPlaceholder.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            audioPlaceholder.centerYAnchor.constraint(equalTo: display.centerYAnchor, constant: -4),
            audioMeter.widthAnchor.constraint(equalTo: widthAnchor, constant: -40),
            statusLabel.centerXAnchor.constraint(equalTo: display.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: display.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: display.widthAnchor, constant: -8),
            firstRow.topAnchor.constraint(equalTo: display.bottomAnchor, constant: Self.rowInset),
            firstRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            firstRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            firstRow.heightAnchor.constraint(equalToConstant: Self.buttonRowHeight),
            secondRow.topAnchor.constraint(equalTo: firstRow.bottomAnchor, constant: Self.rowGap),
            secondRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            secondRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            secondRow.heightAnchor.constraint(equalToConstant: Self.buttonRowHeight),
            secondRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.rowInset),
            // 第一行：× 窄，其余三颗等宽；第二行：1–4 与 ⚙ 窄，静音吃剩下的
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            cutButton.widthAnchor.constraint(equalTo: transitionButton.widthAnchor),
            loopButton.widthAnchor.constraint(equalTo: transitionButton.widthAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 22),
        ] + overlayButtons.map { $0.widthAnchor.constraint(equalToConstant: 20) })
        let leading = nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 6)
        leading.isActive = true
        nameLabelLeading = leading
        apply(config: config, tally: .off, overlays: [], runtime: nil)
        applySwitching(program: MixerState.noInput, transitionActive: false, transitionLabel: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func cellButton(_ title: String) -> NSButton {
        let b = Theme.toggleButton(title, target: nil, action: nil)
        b.controlSize = .mini
        b.font = NSFont.systemFont(ofSize: 10)
        b.refusesFirstResponder = true
        return b
    }

    private static func row(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 2
        row.distribution = .fill
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// 快照里这一路的部分 + 运行状态。配置没变时只动 tally / 叠加 / 运行状态（快照 ≤ 60 Hz，别每次重设字和提示：92 的坑）。
    func apply(config: InputConfig, tally: Tally, overlays: [OverlayState], runtime: InputState?) {
        let configChanged = config != self.config || nameLabel.stringValue.isEmpty
        self.config = config
        if tally != self.tally || configChanged {
            self.tally = tally
            titleBar.backgroundColor = tally.program ? Theme.tallyProgram : (tally.preview ? Theme.tallyPreview : Theme.tallyOff)
            layer?.borderWidth = tally.program || tally.preview ? 2 : 0
            layer?.borderColor = (tally.program ? Theme.tallyProgram : Theme.tallyPreview).cgColor
        }
        for (i, b) in overlayButtons.enumerated() where i < overlays.count {
            Theme.setHighlighted(b, overlays[i].on && overlays[i].input == config.number)
        }
        Theme.setHighlighted(muteButton, config.settings.audio.muted, color: Theme.recording)
        if configChanged {
            numberLabel.stringValue = "\(config.number)"
            nameLabel.stringValue = config.name
            audioName.stringValue = config.name
            toolTip = L("cell.tooltip", config.number, config.name, L("addInput.kind.\(config.kind.rawValue)"))
            let silence = Self.silenceReason(config)
            muteButton.isEnabled = silence == nil
            muteButton.toolTip = silence ?? L("cell.mute.tip")
            let isFile: Bool
            if case .file = config.source { isFile = true } else { isFile = false }
            loopButton.isEnabled = isFile
            loopButton.toolTip = isFile ? L("cell.loop.tip") : L("cell.loop.onlyFile")
        }
        Theme.setHighlighted(loopButton, isLooping)
        if runtime != self.runtime || configChanged {
            self.runtime = runtime
            updateStatus()
        }
    }

    /// 切换相关的状态（每个快照由输入条给）：PGM 是哪一路、转场是否在进行、当前那组转场怎么写（"Fade · 0.5 秒" / "Cut"）。没变就不动按钮。
    func applySwitching(program: Int, transitionActive: Bool, transitionLabel: String) {
        let key = SwitchingKey(onProgram: program == number, transitionActive: transitionActive, label: transitionLabel)
        guard key != switching else { return }
        switching = key
        let enabled = !key.transitionActive && !key.onProgram
        transitionButton.isEnabled = enabled
        cutButton.isEnabled = enabled
        if key.transitionActive {
            transitionButton.toolTip = L("cell.busy.tip")
            cutButton.toolTip = L("cell.busy.tip")
        } else if key.onProgram {
            transitionButton.toolTip = L("cell.onProgram")
            cutButton.toolTip = L("cell.onProgram")
        } else {
            transitionButton.toolTip = L("cell.transition.tip", transitionLabel)
            cutButton.toolTip = L("cell.cut.tip")
        }
        transitionButton.setAccessibilityLabel(L("cell.transition.a11y", number))
        cutButton.setAccessibilityLabel(L("cell.cut.a11y", number))
    }

    private struct SwitchingKey: Equatable {
        var onProgram: Bool
        var transitionActive: Bool
        var label: String
    }
    private var switching: SwitchingKey?

    /// 没有声音的输入（图片、不采声音的屏幕、无声合成源，D7）：静音灰着，提示写原因。有声音为 nil。
    static func silenceReason(_ config: InputConfig) -> String? {
        switch config.source {
        case .image: L("cell.mute.noAudio.image")
        case .screen(_, _, let captureAudio) where !captureAudio: L("cell.mute.noAudio.screen")
        case .synthetic(let settings) where !settings.audio: L("cell.mute.noAudio.synthetic")
        default: nil
        }
    }

    private var isLooping: Bool {
        if case .file(_, .loop, _) = config.source { return true }
        return false
    }

    /// 缩略图取多画面纹理里的哪一块（InputStripView.thumbnailRect：按当前布局算好的内框、去掉底部名字条）；nil = 布局里没有这一路（自定义格子没放它），不画、写一句说明。
    func setThumbnail(rect: NormalizedRect?) {
        isOutsideMultiviewLayout = rect == nil
        display.sourceRect = rect ?? .full
        updateStatus()
    }

    /// 格子宽（三档）与缩略图框高（按裁切后的比例，输入条统一算好给每一格）。
    func setSize(width: CGFloat, thumbnailHeight: CGFloat) {
        if widthConstraint.constant != width { widthConstraint.constant = width }
        if displayHeightConstraint.constant != thumbnailHeight { displayHeightConstraint.constant = thumbnailHeight }
    }

    /// 分类（标题条上的色点；nil = 无）。
    func setCategory(_ color: InputCategories.Color?, title: String?) {
        guard color != categoryColor || categoryDot.toolTip != title else { return }
        categoryColor = color
        categoryDot.color = color?.nsColor
        categoryDot.isHidden = color == nil
        categoryDot.toolTip = title
        nameLabelLeading?.isActive = false
        nameLabelLeading = nameLabel.leadingAnchor.constraint(equalTo: (color == nil ? numberLabel : categoryDot).trailingAnchor, constant: color == nil ? 6 : 4)
        nameLabelLeading?.isActive = true
    }
    private(set) var categoryColor: InputCategories.Color?
    private var nameLabelLeading: NSLayoutConstraint?

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

    // MARK: 右键（D8）

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// 右键菜单：送到 PVW / Cut 到 PGM / 按当前转场送上 PGM / Overlay ▸ / 分类 ▸ / 静音 ─ 设置… / 换来源… / 重命名… ─ 删除输入 n。
    /// 前三项与格子按钮同一口径（转场进行中灰；已在 PGM 上的 Cut / 转场灰；已在 PVW 上的"送到 PVW"灰）。分类 ▸ 的名字跟标签走（categoryTitles）。
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let busy = switching?.transitionActive ?? false
        let onProgram = switching?.onProgram ?? false
        let label = switching?.label ?? ""
        menu.addItem(.action(L("cell.menu.preview"), enabled: !busy && !tally.preview) { [weak self] in self?.sendPreview() })
        menu.addItem(.action(L("cell.menu.cut"), enabled: !busy && !onProgram) { [weak self] in self?.cutPressed() })
        menu.addItem(.action(L("cell.transition.tip", label), enabled: !busy && !onProgram) { [weak self] in self?.transitionPressed() })
        let overlay = NSMenu(title: L("cell.menu.overlay"))
        overlay.autoenablesItems = false
        for b in overlayButtons {
            let on = b.bezelColor != nil
            overlay.addItem(.action(L("cell.overlay.a11y", b.tag), state: on ? .on : .off) { [weak self] in self?.toggleOverlay(b.tag) })
        }
        menu.addItem(Self.submenuItem(overlay))
        let category = NSMenu(title: L("cell.menu.category"))
        category.autoenablesItems = false
        category.addItem(.action(L("category.none"), state: categoryColor == nil ? .on : .off) { [weak self] in
            guard let self else { return }
            self.onSetCategory?(self.number, nil)
        })
        for color in InputCategories.Color.allCases {
            category.addItem(.action(categoryTitles(color), state: categoryColor == color ? .on : .off) { [weak self] in
                guard let self else { return }
                self.onSetCategory?(self.number, color)
            })
        }
        menu.addItem(Self.submenuItem(category))
        let silence = Self.silenceReason(config)
        menu.addItem(.action(L("mixer.mute"), enabled: silence == nil, state: config.settings.audio.muted ? .on : .off, toolTip: silence) { [weak self] in
            self?.mutePressed()
        })
        menu.addItem(.separator())
        menu.addItem(.action(L("cell.menu.settings")) { [weak self] in self?.settingsPressed() })
        menu.addItem(.action(L("cell.menu.changeSource"), toolTip: L("cell.menu.changeSource.tip")) { [weak self] in
            guard let self else { return }
            self.onChangeSource?(self.number)
        })
        menu.addItem(.action(L("cell.menu.rename")) { [weak self] in self?.renamePressed() })
        menu.addItem(.separator())
        menu.addItem(.action(L("cell.menu.remove", number)) { [weak self] in self?.requestRemoval() })
        return menu
    }

    /// 分类 ▸ 里每一类怎么写（起过名写名字；输入条给）。
    var categoryTitles: (InputCategories.Color) -> String = { $0.defaultTitle }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
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

    /// 删这一路（格子上的 × / 右键"删除输入 n"）：在 PGM / PVW / 叠加 / Stinger / ISO 录制上时先确认、写明后果；其余直接删（W5-B，D9 / X13）。
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

    // MARK: 切换

    /// 转场进行中：不发 setPreview / setProgram（reducer 也会拒），状态行说一句；返回 true = 挡下了。
    private func blockedByTransition() -> Bool {
        guard switching?.transitionActive == true else { return false }
        onNotice?(L("cell.busy.notice"))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard display.frame.contains(p) || titleBar.frame.contains(p) else { super.mouseDown(with: event); return }
        guard !blockedByTransition() else { return }
        if event.modifierFlags.contains(.shift) {
            send?(.setProgram(input: number))
        } else {
            send?(.setPreview(input: number))
        }
    }

    private func sendPreview() {
        guard !blockedByTransition() else { return }
        send?(.setPreview(input: number))
    }

    /// 转场：按当前转场送上 PGM（Q39；W5-M 起 = 当前槽，转场列 T-bar 那一行写着的那个）= 先送 PVW 再 autoTransition；已在 PVW 上就只 autoTransition。
    @objc private func transitionPressed() {
        guard !blockedByTransition(), switching?.onProgram != true else { return }
        if !tally.preview { send?(.setPreview(input: number)) }
        send?(.autoTransition)
    }

    /// Cut：直切到 PGM（setProgram，不经过 PVW）。
    @objc private func cutPressed() {
        guard !blockedByTransition(), switching?.onProgram != true else { return }
        send?(.setProgram(input: number))
    }

    /// 循环：只改结束动作（开 = loop，关 = 停在最后一帧），走 setInputSource——运行表看到"只有结束动作变了"不重建这一路（InputRuntime.reconcile）。
    @objc private func loopPressed() {
        guard case .file(let path, let endAction, let rate) = config.source else { return }
        send?(.setInputSource(input: number, source: .file(path: path, endAction: endAction == .loop ? .holdLastFrame : .loop, rate: rate)))
    }

    @objc private func overlayPressed(_ sender: NSButton) { toggleOverlay(sender.tag) }

    /// 已经是这一路且开着 → 关；否则把通道换成这一路并打开。
    private func toggleOverlay(_ channel: Int) {
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
        guard Self.silenceReason(config) == nil else { return }
        send?(.mute(input: number, on: !config.settings.audio.muted))
    }

    var displayedName: String { nameLabel.stringValue }
    var titleColor: NSColor { titleBar.backgroundColor }
}

/// 标题条上的分类色点（白边，压在红 / 绿 tally 底上也看得见）。
@MainActor
private final class CategoryDotView: NSView {
    var color: NSColor? {
        didSet { layer?.backgroundColor = color?.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4.5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
