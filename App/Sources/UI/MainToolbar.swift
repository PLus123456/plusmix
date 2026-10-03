// 主窗口顶部工具条（W5-G，01a A1 / A2 / A5 / A6 / C9 / F2 / M1 / O3，04 Q28：NSToolbar `.unified` 一行）：
//   左"节目"组 新建 ｜ 打开▾ ｜ 保存 ｜ 另存为；正中 外部显示▾；右 录制 / 推流状态 ｜ 设置▾ ｜ ?。
// - 每个按钮的主体都是 nil target 的 AppDelegate selector，和菜单栏那一项同一个动作（新建 / 打开要先过 W5-B 的确认，工具条走的就是同一条路）。
// - 打开▾ = 最近打开的节目 + 打开上次退出时的节目 + 清除列表（ShowMenu，与"节目"菜单同一份数据）；设置▾ = 设置窗与各设置页（SettingsMenu）；
//   ? = 帮助菜单同一份（HelpMenu）；外部显示▾ = 底栏 ⚙ 外部显示的那个路由菜单（ExternalOutputMenuBuilder），主体 = 全部开 / 关（同底栏主体），开着高亮。
// - 分体按钮与底栏是同一个控件（SplitBarButton，placement = .toolbar：▾ 向下开、左缘对齐整个控件）。工具条上不放 ⚙（▾ 就是它们的菜单）。
// - 录制 / 推流状态只显示（底栏两个主体按钮的同一份汇总 OutputButtonSummary，铁律 4）；时长等 022 / 101。
// - 不放"暂停输入""精简"（A5 / A6：没有这两个功能，不放点了没反应的按钮）。全部按钮 refusesFirstResponder（C9）。
// - 没有 session（引擎起不来 / 正在换节目）时节目组以外置灰。
import AppKit
import SwitcherContracts

@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    enum Item: String, CaseIterable {
        case newShow, openShow, saveShow, saveShowAs, external, outputStatus, settings, help
        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("plusmix.toolbar.\(rawValue)") }
    }

    let toolbar = NSToolbar(identifier: "PlusMixMainToolbar")
    let newButton: NSButton
    let open = SplitBarButton(name: L("toolbar.open"), title: L("toolbar.open"), placement: .toolbar)
    let saveButton: NSButton
    let saveAsButton: NSButton
    let external = SplitBarButton(name: L("bottom.external"), title: L("bottom.external"), placement: .toolbar)
    let outputStatus = ToolbarOutputStatusView()
    let settings = SplitBarButton(name: L("toolbar.settings"), title: L("toolbar.settings"), placement: .toolbar)
    let helpButton: NSButton
    /// 打开▾ 的菜单（AppController 挂：最近列表在 ShowDocuments）。
    var openMenuProvider: (() -> NSMenu)?
    /// 外部显示▾ 的路由菜单（MainWindowController 挂：与底栏 ⚙ 外部显示同一个构造器）。
    var externalMenuProvider: (() -> NSMenu?)?
    /// 弹菜单之前（菜单是模态的：测试开着时量位置、量完 cancelTracking）。
    var willPopUpMenu: ((NSMenu) -> Void)?
    /// 最近一次从工具条弹出的菜单。
    private(set) var activeMenu: NSMenu?
    /// 外部显示有开着的（主体高亮；与底栏同一份开关状态 = 快照里外部显示输出的 enabled）。
    private(set) var isExternalHighlighted = false
    private(set) var isSessionAvailable = true

    /// 工具条上所有按钮（含分体按钮隐藏的那一段）。
    var allButtons: [NSButton] { [newButton, saveButton, saveAsButton, helpButton] + open.allButtons + external.allButtons + settings.allButtons }

    override init() {
        newButton = Self.button(L("toolbar.new"), action: #selector(AppDelegate.newShow(_:)), tip: L("toolbar.newTip"))
        saveButton = Self.button(L("toolbar.save"), action: #selector(AppDelegate.saveShow(_:)), tip: L("toolbar.saveTip"))
        saveAsButton = Self.button(L("toolbar.saveAs"), action: #selector(AppDelegate.saveShowAs(_:)), tip: L("toolbar.saveAsTip"))
        helpButton = NSButton(title: "", target: nil, action: nil)
        super.init()
        helpButton.bezelStyle = .helpButton
        helpButton.target = self
        helpButton.action = #selector(helpPressed)
        helpButton.setAccessibilityLabel(L("toolbar.help"))
        helpButton.toolTip = L("toolbar.helpTip")
        helpButton.translatesAutoresizingMaskIntoConstraints = false

        Self.route(open.bodyButton, #selector(AppDelegate.openShow(_:)))
        open.bodyButton.toolTip = L("toolbar.openTip")
        open.menuAction = .menu { [weak self] in self?.openMenu() }
        Self.route(external.bodyButton, #selector(AppDelegate.toggleExternalDisplays(_:)))
        external.bodyButton.toolTip = L("bottom.externalTip.none")
        external.menuAction = .menu { [weak self] in self?.externalMenuProvider?() }
        Self.route(settings.bodyButton, #selector(AppDelegate.showPreferences(_:)))
        settings.bodyButton.toolTip = L("toolbar.settingsTip")
        settings.menuAction = .menu { [weak self] in self?.settingsMenu() }
        for split in [open, external, settings] {
            split.willPopUp = { [weak self] menu in
                self?.activeMenu = menu
                self?.willPopUpMenu?(menu)
            }
        }
        for b in allButtons { b.refusesFirstResponder = true }

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Item.external.identifier]
    }

    /// 节目组的普通按钮：主体 = 菜单栏同一项的 selector，target 为 nil（响应链 → AppDelegate）。
    private static func button(_ title: String, action: Selector, tip: String) -> NSButton {
        let b = Theme.button(title, target: nil, action: action)
        b.bezelStyle = .toolbar
        b.toolTip = tip
        return b
    }

    /// 分体按钮的主体改走 nil target 的 selector（与菜单项同一个动作），不走它自己的 bodyAction 闭包。
    private static func route(_ body: NSButton, _ action: Selector) {
        body.target = nil
        body.action = action
    }

    // MARK: 菜单

    /// 打开▾：打开上次退出时的节目 ─ 最近打开的节目 ─ 清除列表。
    func openMenu() -> NSMenu { openMenuProvider?() ?? ShowMenu.openMenu(urls: []) }

    /// 设置▾：设置… ─ 各设置页 ─ 快捷键… / MIDI 映射…。
    func settingsMenu() -> NSMenu { SettingsMenu.make() }

    /// ?：帮助菜单同一份。
    func helpMenu() -> NSMenu { HelpMenu.make() }

    @objc private func helpPressed() {
        let menu = helpMenu()
        activeMenu = menu
        willPopUpMenu?(menu)
        ScreenMenu.popUpBelow(menu, helpButton)
    }

    // MARK: 状态

    /// 没有 session 时节目组以外置灰。
    func setSessionAvailable(_ available: Bool) {
        isSessionAvailable = available
        for b in external.allButtons + settings.allButtons + [helpButton] { b.isEnabled = available }
        outputStatus.alphaValue = available ? 1 : 0.4
    }

    /// 快照 → 外部显示主体高亮（有开着的外部显示输出；与底栏主体同一个口径）。每个快照都调：没变就不动。
    func apply(state: MixerState) {
        let on = state.outputs.contains { $0.kind == .externalDisplay && $0.enabled }
        guard on != isExternalHighlighted else { return }
        isExternalHighlighted = on
        external.setIndicator(on)   // 工具条的玻璃外框不画 bezelColor：开着把字换成强调色（SplitBarButton.setIndicator）
    }

    /// 外部显示主体的提示（底栏主体那一句，逐路写状态）。
    func setExternalToolTip(_ tip: String?) {
        if external.bodyButton.toolTip != tip { external.bodyButton.toolTip = tip }
    }

    /// 录制 / 推流状态（底栏两个主体按钮的同一份汇总）。
    func showOutputStatus(record: OutputButtonSummary, stream: OutputButtonSummary) {
        outputStatus.show(record: record, stream: stream)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.newShow.identifier, Item.openShow.identifier, Item.saveShow.identifier, Item.saveShowAs.identifier, .flexibleSpace,
         Item.external.identifier, .flexibleSpace, Item.outputStatus.identifier, Item.settings.identifier, Item.help.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let kind = Item.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let (view, label): (NSView, String) = switch kind {
        case .newShow: (newButton, L("toolbar.new"))
        case .openShow: (open, L("toolbar.open"))
        case .saveShow: (saveButton, L("toolbar.save"))
        case .saveShowAs: (saveAsButton, L("toolbar.saveAs"))
        case .external: (external, L("bottom.external"))
        case .outputStatus: (outputStatus, L("toolbar.outputStatus"))
        case .settings: (settings, L("toolbar.settings"))
        case .help: (helpButton, L("toolbar.help"))
        }
        item.view = view
        item.label = label
        item.paletteLabel = label
        item.autovalidates = false   // 灰不灰自己管（setSessionAvailable）：按钮挂的是 nil target 的 selector，系统按响应链校验会把"没有 session"覆盖掉
        // 窗口窄的时候先让状态那一格让位（它只是显示）；节目组、外部显示、设置、? 都要留着
        item.visibilityPriority = kind == .outputStatus ? .low : .high
        return item
    }
}

/// 工具条右组的录制 / 推流状态（只显示，W5-G）：两段文字，没开 = "未录制 / 未推流"（暗），开着 = 底栏主体同样的汇总（"● 录制中（2 路）""推流 · 1 路异常"），
/// 颜色按最差的那一路；提示逐路写状态。值没变就不重设（每个快照都会调）。
@MainActor
final class ToolbarOutputStatusView: NSView {
    let recordLabel = Theme.label("", size: 12, weight: .semibold, color: Theme.dimText)
    let streamLabel = Theme.label("", size: 12, weight: .semibold, color: Theme.dimText)
    private var shown: (OutputButtonSummary, OutputButtonSummary)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [recordLabel, streamLabel])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        for l in [recordLabel, streamLabel] {
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
            l.lineBreakMode = .byClipping
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("toolbar.outputStatus"))
        show(record: OutputButtonSummary(title: L("bottom.record"), toolTip: nil, severity: .off),
             stream: OutputButtonSummary(title: L("bottom.stream"), toolTip: nil, severity: .off))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(record: OutputButtonSummary, stream: OutputButtonSummary) {
        if let shown, shown.0 == record, shown.1 == stream { return }
        shown = (record, stream)
        set(recordLabel, record, off: L("toolbar.status.recordOff"))
        set(streamLabel, stream, off: L("toolbar.status.streamOff"))
    }

    private func set(_ label: NSTextField, _ summary: OutputButtonSummary, off: String) {
        let text = summary.severity == .off ? off : summary.title
        if label.stringValue != text { label.stringValue = text }
        label.textColor = summary.severity == .off ? Theme.dimText : summary.color
        label.toolTip = summary.toolTip
    }

    var recordText: String { recordLabel.stringValue }
    var streamText: String { streamLabel.stringValue }
}
