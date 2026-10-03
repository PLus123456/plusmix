// PVW / PGM 监视器：标题条（编号、名字、tally 色）+ MetalDisplayView（全速，跟显示器刷新率）。
// W5-G（01a B1–B4，04 Q27）：标题条右端一个齿轮 = 打开这一路（PVW / PGM 上那一路）的输入设置，黑场时灰；PGM 不弹菜单、直接开（我们只有一路 PGM，
// 参考 PGM 齿轮那个菜单是给多路混合挑的）。右键监视器（画面或标题条）= 小菜单"输入设置… / 全屏输出到 ▸"（每块屏一项：这块屏改出这个监视器的画面，
// 已经在出它的那块再点 = 关，同外部显示路由菜单的口径）。单击、双击都不绑动作（直播中快点容易误触，Q27 2-(i)）。
// PGM 标题条右侧画开着的叠加通道小徽标"通道号 · 输入名"（读快照的 overlays，是标题条上的控件、不画进画面）。参考 PVW 标题条上另两个图标不放（Q27 3-(i)）。
// 快照每帧都来：标题条上的文字 / 徽标 / 齿轮的灰不灰都是没变就不动（W5-F 报告 §5 第 10 条：每帧重设会拖慢点按钮）。
// W5-L（N02）：FTB 开着时 PGM 标题条上"PGM · FTB"垫一块黑底并慢闪（图层的透明度动画，渲染服务器做，不占主线程），一眼看出"节目是黑的"。
import AppKit
import SwitcherContracts
import SwitcherRender

@MainActor
final class MonitorView: NSView {
    let target: DisplayTarget
    let display = MetalDisplayView(frame: .zero)
    private let titleBar = PanelView(color: Theme.tallyOff)
    private let numberLabel = Theme.monoLabel("—", size: 14, color: .white)
    private let nameLabel = Theme.label("", size: 13, weight: .semibold, color: .white)
    private let roleLabel = Theme.label("", size: 11, weight: .bold, color: .white)
    /// FTB 色块（垫在角色标签后面，FTB 开着时显示并闪，W5-L）。
    private let ftbBlock = PanelView(color: .black)
    static let ftbBlinkKey = "plusmix.ftbBlink"
    /// 标题条右端的齿轮：打开这一路的输入设置（黑场时灰）。
    let gearButton: NSButton
    /// PGM 标题条上的叠加徽标（四个，没开的藏着；PVW 不用）。
    private let badgeStack = NSStackView()
    private let badges: [OverlayBadge]
    /// 齿轮 / 右键"输入设置…"打开哪一路（MainWindowController 接到面板总管）。
    var onOpenInputSettings: ((Int) -> Void)?
    /// 右键"全屏输出到 ▸"的子菜单（MainWindowController 建：外部显示路由同一个构造器，来源 = 这个监视器）。
    var fullscreenMenu: ((OutputSource) -> NSMenu?)?
    /// 现在标题条上是哪一路（黑场 / 输入不在 = noInput）。
    private(set) var shownInput = MixerState.noInput
    /// 标题条上次按什么画的（编号 + 名字；nil = 还没画过）：没变就不重新拼字。
    private var shownTitle: TitleKey?
    private var shownBadgeKeys: [BadgeKey] = []
    private var shownBadges: [String] = []

    private struct TitleKey: Equatable {
        var number: Int
        /// nil = 这个编号的输入不在（或黑场）。
        var name: String?
    }

    private struct BadgeKey: Equatable {
        var channel: Int
        var input: Int?
        var name: String?
    }

    init(target: DisplayTarget) {
        self.target = target
        let role = target == .program ? "PGM" : "PVW"
        gearButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("monitor.gear.a11y", role)) ?? NSImage(),
                              target: nil, action: nil)
        badges = (1...MixerState.overlayCount).map { _ in OverlayBadge() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        display.target = target
        display.translatesAutoresizingMaskIntoConstraints = false
        roleLabel.stringValue = role
        titleBar.backgroundColor = target == .program ? Theme.tallyProgram : Theme.tallyPreview
        gearButton.isBordered = false
        gearButton.imagePosition = .imageOnly
        gearButton.contentTintColor = .white
        gearButton.refusesFirstResponder = true
        gearButton.setButtonType(.momentaryChange)
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        gearButton.setAccessibilityLabel(L("monitor.gear.a11y", role))
        gearButton.target = self
        gearButton.action = #selector(gearPressed)
        gearButton.isEnabled = false
        gearButton.toolTip = L("monitor.gearTipBlack", role)
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 4
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        for b in badges {
            b.isHidden = true
            badgeStack.addArrangedSubview(b)
        }
        badgeStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(titleBar)
        addSubview(display)
        titleBar.addSubview(numberLabel)
        titleBar.addSubview(nameLabel)
        titleBar.addSubview(badgeStack)
        titleBar.addSubview(ftbBlock)
        titleBar.addSubview(roleLabel)
        ftbBlock.isHidden = true
        ftbBlock.layer?.cornerRadius = 3
        titleBar.addSubview(gearButton)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Theme.monitorTitleHeight),
            display.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            display.leadingAnchor.constraint(equalTo: leadingAnchor),
            display.trailingAnchor.constraint(equalTo: trailingAnchor),
            display.bottomAnchor.constraint(equalTo: bottomAnchor),
            numberLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -8),
            badgeStack.trailingAnchor.constraint(equalTo: roleLabel.leadingAnchor, constant: -8),
            badgeStack.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            roleLabel.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -6),
            roleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            ftbBlock.leadingAnchor.constraint(equalTo: roleLabel.leadingAnchor, constant: -5),
            ftbBlock.trailingAnchor.constraint(equalTo: roleLabel.trailingAnchor, constant: 5),
            ftbBlock.topAnchor.constraint(equalTo: titleBar.topAnchor, constant: 4),
            ftbBlock.bottomAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: -4),
            gearButton.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -6),
            gearButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 18),
            gearButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var roleName: String { target == .program ? "PGM" : "PVW" }

    /// 标题条内容：编号 + 名字；0 = 黑场。齿轮跟着这一路灰 / 亮，PGM 画开着的叠加徽标。每个快照都调：先比编号 / 名字，变了才拼字、改控件。
    func apply(state: MixerState) {
        let number = target == .program ? state.program : state.preview
        let input = number == MixerState.noInput ? nil : state.input(number)
        let title = TitleKey(number: number, name: input?.name)
        if title != shownTitle {
            shownTitle = title
            if number == MixerState.noInput {
                numberLabel.stringValue = "—"
                nameLabel.stringValue = L("monitor.black")
            } else {
                numberLabel.stringValue = "\(number)"
                nameLabel.stringValue = input?.name ?? L("monitor.missingInput", number)
            }
            shownInput = input == nil ? MixerState.noInput : number
            gearButton.isEnabled = input != nil
            gearButton.toolTip = input.map { L("monitor.gearTip", roleName, number, $0.name) } ?? L("monitor.gearTipBlack", roleName)
        }
        let ftb = target == .program && state.ftb.on
        if ftb != (roleLabel.stringValue != roleName) { roleLabel.stringValue = ftb ? "PGM · FTB" : roleName }
        if ftb != isFTBIndicatorShown { setFTBIndicator(ftb) }
        if target == .program { applyBadges(state) }
    }

    /// PGM 的叠加徽标：每个开着的通道一个"通道号 · 输入名"（按通道顺序）。
    private func applyBadges(_ state: MixerState) {
        let keys = state.overlays.enumerated().filter { $0.element.on }.map { index, overlay in
            BadgeKey(channel: index + 1, input: overlay.input, name: overlay.input.flatMap { state.input($0)?.name })
        }
        guard keys != shownBadgeKeys else { return }
        shownBadgeKeys = keys
        var texts: [String] = []
        var tips: [String] = []
        for key in keys {
            let name = key.input.map { key.name ?? L("monitor.missingInput", $0) } ?? "—"
            texts.append(L("monitor.overlayBadge", key.channel, name))
            tips.append(key.input.map { L("monitor.overlayBadgeTip", key.channel, $0, name) } ?? L("monitor.overlayBadgeTipEmpty", key.channel))
        }
        shownBadges = texts
        for (i, badge) in badges.enumerated() {
            if i < texts.count {
                badge.text = texts[i]
                badge.toolTip = tips[i]
                badge.isHidden = false
            } else {
                badge.isHidden = true
            }
        }
    }

    /// FTB 色块：显示并慢闪 / 藏起来（只在开关变化时调）。
    private func setFTBIndicator(_ on: Bool) {
        ftbBlock.isHidden = !on
        guard let layer = ftbBlock.layer else { return }
        if on {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0.25
            blink.duration = 0.6
            blink.autoreverses = true
            blink.repeatCount = .infinity
            layer.add(blink, forKey: Self.ftbBlinkKey)
        } else {
            layer.removeAnimation(forKey: Self.ftbBlinkKey)
        }
    }

    // MARK: 齿轮 / 右键

    @objc private func gearPressed() {
        guard shownInput != MixerState.noInput else { return }
        onOpenInputSettings?(shownInput)
    }

    /// 右键菜单：输入设置… / 全屏输出到 ▸。
    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: roleName)
        menu.autoenablesItems = false
        let number = shownInput
        menu.addItem(.action(L("monitor.menu.inputSettings"), enabled: number != MixerState.noInput,
                             toolTip: number == MixerState.noInput ? L("monitor.gearTipBlack", roleName) : nil) { [weak self] in
            self?.onOpenInputSettings?(number)
        })
        let fullscreen = NSMenuItem(title: L("monitor.menu.fullscreen"), action: nil, keyEquivalent: "")
        fullscreen.submenu = fullscreenMenu?(target == .program ? .program : .preview) ?? NSMenu(title: L("monitor.menu.fullscreen"))
        menu.addItem(fullscreen)
        return menu
    }

    /// 画面区和标题条自己都不给菜单，右键落到这里（探针：子视图 menu(for:) 为 nil 时 AppKit 问父视图）。
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    // MARK: 测试 / 别处看

    var displayedNumber: String { numberLabel.stringValue }
    var displayedName: String { nameLabel.stringValue }
    var roleText: String { roleLabel.stringValue }
    /// PGM 标题条上的 FTB 色块亮着没有（W5-L，N02）。
    var isFTBIndicatorShown: Bool { !ftbBlock.isHidden }
    /// 正在显示的叠加徽标文字（按通道顺序）。
    var overlayBadgeTexts: [String] { shownBadges }
    var overlayBadgeViews: [NSView] { badges.filter { !$0.isHidden } }
}

/// 标题条上的一枚小徽标（圆角底 + 白字），只读不点。
@MainActor
final class OverlayBadge: NSView {
    private let label = Theme.label("", size: 10, weight: .semibold, color: .white)

    var text: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue } }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        layer?.cornerRadius = 4
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityLabel() -> String? { text }
}
