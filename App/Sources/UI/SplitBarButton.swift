// 底栏的分体按钮（W5-F，docs/ui-study/01-菜单逻辑.md §1 规则 1）：⚙ = 打开这件事的设置 ｜ 主体 = 执行 / 开关 ｜ ▴ = 快捷菜单，三段各自可隐藏（没给动作的那段不显示、不占位）。
// ⚙ 与 ▴ 要么弹菜单、要么直接做一件事（打开设置页）；菜单每次现建、一律走 BottomBarPopup 朝上开（W5-A：换算到屏幕坐标再弹，贴按钮上沿、不出窗口）。
// 三个按钮都 refusesFirstResponder（01a C9）：空格 / 回车永远落到主窗口的快捷键表，不会被某个按钮吃掉（探针结论见 reports/w5-app-bottom-bar.md §5）。
// ⚙ / ▴ 只有图标（SF Symbols 的通用齿轮与上箭头），辅助功能名与提示写全"录制设置 / 录制菜单"。
import AppKit
import SwitcherContracts

@MainActor
final class SplitBarButton: NSView {
    /// ⚙ / ▴ 点了做什么：弹一个现建的菜单（朝上），或直接执行。
    enum Action {
        case menu(@MainActor () -> NSMenu?)
        case perform(@MainActor () -> Void)
    }

    /// 这件事叫什么（"录制"），辅助功能名与提示用。
    let name: String
    let gearButton: NSButton
    let bodyButton: NSButton
    let menuButton: NSButton
    /// 三个按钮（⚙ / 主体 / ▴），隐藏的也在里面。
    var allButtons: [NSButton] { [gearButton, bodyButton, menuButton] }

    var gearAction: Action? { didSet { gearButton.isHidden = gearAction == nil } }
    var bodyAction: (@MainActor () -> Void)?
    var menuAction: Action? { didSet { menuButton.isHidden = menuAction == nil } }
    /// 弹菜单之前（菜单是模态的：MainWindowController 记下它，测试开着时量位置、量完 cancelTracking）。
    var willPopUp: ((NSMenu) -> Void)?

    var showsGear: Bool { !gearButton.isHidden }
    var showsBody: Bool {
        get { !bodyButton.isHidden }
        set { bodyButton.isHidden = !newValue }
    }
    var showsMenu: Bool { !menuButton.isHidden }

    private let stack = NSStackView()

    init(name: String, title: String) {
        self.name = name
        gearButton = Self.iconButton(symbol: "gearshape", label: L("bottom.gear.a11y", name))
        bodyButton = Theme.button(title, target: nil, action: nil)
        menuButton = Self.iconButton(symbol: "chevron.up", label: L("bottom.menu.a11y", name))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for b in allButtons { b.refusesFirstResponder = true }
        gearButton.target = self; gearButton.action = #selector(gearPressed)
        bodyButton.target = self; bodyButton.action = #selector(bodyPressed)
        menuButton.target = self; menuButton.action = #selector(menuPressed)
        gearButton.isHidden = true
        menuButton.isHidden = true
        // 隐藏的视图 NSStackView 不给它排位置（detachesHiddenViews 默认就是 true）：可见的几段挨着排
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        for b in allButtons { stack.addArrangedSubview(b) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// ⚙ / ▴：只有图标的小按钮（和主体同一种外框，挨着主体）。
    private static func iconButton(symbol: String, label: String) -> NSButton {
        let b = Theme.button("", target: nil, action: nil)
        let config = NSImage.SymbolConfiguration(pointSize: symbol == "chevron.up" ? 9 : 12, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        b.imagePosition = .imageOnly
        b.setAccessibilityLabel(label)
        b.toolTip = label
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// 主体按钮的高亮（开着 / 在录 / 在推）。
    func setBodyHighlighted(_ on: Bool, color: NSColor = Theme.accent) {
        Theme.setHighlighted(bodyButton, on, color: color)
    }

    @objc private func gearPressed() { run(gearAction, from: gearButton) }
    @objc private func bodyPressed() { bodyAction?() }
    @objc private func menuPressed() { run(menuAction, from: menuButton) }

    private func run(_ action: Action?, from anchor: NSButton) {
        switch action {
        case .menu(let make)?:
            guard let menu = make() else { return }
            popUp(menu, from: anchor)
        case .perform(let block)?:
            block()
        case nil:
            break
        }
    }

    /// 从某一段朝上弹菜单（主体的"一路都没配时弹菜单"也走这里）。
    func popUp(_ menu: NSMenu, from anchor: NSButton) {
        willPopUp?(menu)
        BottomBarPopup.popUp(menu, from: anchor)
    }
}

/// 带闭包的菜单项：target 是闭包盒子，盒子挂在 representedObject 上跟菜单项同生共死（菜单项对 target 是弱引用）。
@MainActor
final class MenuActionBox: NSObject {
    let block: @MainActor () -> Void
    init(_ block: @escaping @MainActor () -> Void) { self.block = block }
    @objc func fire(_ sender: Any?) { block() }
}

extension NSMenuItem {
    /// 一个点了就执行闭包的菜单项（所在菜单要关掉 autoenablesItems，isEnabled 才算数）。
    @MainActor
    static func action(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off, toolTip: String? = nil,
                       _ block: @escaping @MainActor () -> Void) -> NSMenuItem {
        let box = MenuActionBox(block)
        let item = NSMenuItem(title: title, action: #selector(MenuActionBox.fire(_:)), keyEquivalent: "")
        item.target = box
        item.representedObject = box
        item.isEnabled = enabled
        item.state = state
        item.toolTip = toolTip
        return item
    }
}

// —— 红灯轮的签名（实现前）——
struct StreamMenuRow: Equatable {
    enum Click: Equatable { case start, stop, retry }
    var number: Int
    var title: String
    var check: NSControl.StateValue
    var click: Click
    var toolTip: String?
    static func rows(state: MixerState, encoder: [Stats.EncoderEntry], detail: (Int) -> (failure: String?, attempt: Int?)) -> [StreamMenuRow] { [] }
}
@MainActor enum StatusBarView { static var machineInfo: String { "" } }
extension StatusLineFormatter { static func formatText(_ f: ProgramFormat) -> String { "\(f.width)×\(f.height) \(f.frameRate)" } }
@MainActor final class AddInputHistory {
    private(set) var recentSources: [InputSource] = []
    func reset() {}
    func noteAdded(_ config: InputConfig) {}
}
extension AppController { var addInputHistory: AddInputHistory { AddInputHistory() } }
extension MainWindowController { func addInputMenu() -> NSMenu? { NSMenu() } }
extension OutputSettingsModel { var addDestinationFocusRequests: Int { 0 } }
