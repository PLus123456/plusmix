// 转场列的分体按钮（W5-M，docs/ui-study/01-菜单逻辑.md §1 规则 1、01a C2）：主体 = 执行 / 开关 ｜ ▾ = 这件事的菜单（向下开、左缘对齐主体）。
// 右键主体 = 同一份菜单（主体的 menu 是常驻的一份，打开前按当前状态重建：makeMenu 填它）。转场 1–4 与 FTB 用它；底栏的 SplitBarButton 是另一种（⚙ ｜ 主体 ｜ ▴）。
// 两个按钮同一档（regular 24 pt、13 pt 字），▾ 只有 SF Symbols 的下箭头、窄（主体吃掉剩下的宽度），都 refusesFirstResponder（空格 / 回车永远走快捷键表，C9）。
// 当前槽的"常亮标记"画在主体左内边距里（一条竖的小条，不占标题的宽度）：平时强调色，主体高亮（执行中蓝底）时白色。
import AppKit

@MainActor
final class ColumnSplitButton: NSView, NSMenuDelegate {
    let bodyButton: NSButton
    let menuButton: NSButton
    /// 主体左内边距里的小竖条（当前槽的常亮标记）。
    let marker = NSView()
    /// 点主体做什么。
    var bodyAction: (@MainActor () -> Void)?
    /// ▾ / 右键弹的菜单：每次打开现建（▾）或就地重建（右键）。
    var makeMenu: (@MainActor () -> NSMenu)?
    /// 点 ▾ 弹菜单之前（菜单是模态的：转场列记下它，测试开着时量位置、量完 cancelTracking）。
    var willPopUp: ((NSMenu) -> Void)?
    /// ▾ 的宽（主体吃掉剩下的宽度）。
    static let menuButtonWidth: CGFloat = 24

    /// 标记亮着。
    var showsMarker: Bool { !marker.isHidden }

    private let contextMenu = NSMenu()

    init(title: String, menuLabel: String) {
        bodyButton = Theme.button(title, target: nil, action: nil)
        menuButton = Theme.button("", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        menuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: menuLabel)?.withSymbolConfiguration(config)
        menuButton.imagePosition = .imageOnly
        menuButton.setAccessibilityLabel(menuLabel)
        menuButton.toolTip = menuLabel
        for b in [bodyButton, menuButton] {
            b.refusesFirstResponder = true
            b.controlSize = .regular
            b.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
            b.lineBreakMode = .byTruncatingTail
        }
        bodyButton.target = self; bodyButton.action = #selector(bodyPressed)
        menuButton.target = self; menuButton.action = #selector(menuPressed)
        contextMenu.delegate = self
        bodyButton.menu = contextMenu

        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1.5
        marker.layer?.backgroundColor = Theme.accent.cgColor
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.isHidden = true
        marker.setAccessibilityElement(false)

        bodyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        menuButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(bodyButton)
        addSubview(menuButton)
        bodyButton.addSubview(marker)
        NSLayoutConstraint.activate([
            bodyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyButton.topAnchor.constraint(equalTo: topAnchor),
            bodyButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.leadingAnchor.constraint(equalTo: bodyButton.trailingAnchor, constant: 1),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.centerYAnchor.constraint(equalTo: bodyButton.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: Self.menuButtonWidth),
            marker.leadingAnchor.constraint(equalTo: bodyButton.leadingAnchor, constant: 5),
            marker.centerYAnchor.constraint(equalTo: bodyButton.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 对齐矩形 = 主体左边到 ▾ 右边（两个推按钮的对齐矩形就是画出来的边框）。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// 当前槽的常亮标记；主体高亮（蓝底）时标记换白色。没变就不动。
    func setMarker(_ on: Bool, onHighlightedBody highlighted: Bool) {
        if marker.isHidden == on { marker.isHidden = !on }
        let color = (highlighted ? NSColor.white : Theme.accent).cgColor
        if marker.layer?.backgroundColor != color { marker.layer?.backgroundColor = color }
    }

    @objc private func bodyPressed() { bodyAction?() }

    @objc private func menuPressed() {
        guard let menu = makeMenu?() else { return }
        willPopUp?(menu)
        ScreenMenu.popUpBelow(menu, bodyButton)
    }

    // MARK: NSMenuDelegate（右键主体：常驻的一份菜单，打开前按当前状态重建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu, let fresh = makeMenu?() else { return }
        menu.removeAllItems()
        menu.title = fresh.title
        menu.autoenablesItems = fresh.autoenablesItems
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}
