// 菜单栏与工具条共用的几份菜单（W5-G，01a F2 / F3 / O2 / O3，docs/ui-study/01-菜单逻辑.md §5）：项都是 nil target 的 AppDelegate 动作
// （菜单栏和工具条点下去走同一段代码，灰不灰由 AppDelegate.validateMenuItem 定），每次现建。
// - 设置▾（工具条右组）：设置… ─ 按设置窗侧栏顺序分组的页（段标题 本节目 / 本机，01a F2；W5-J 合窗后每一项打开同一个设置窗的那一页）；
//   App 菜单"所有设置页 ▸"是同一批项，"设置… / 快捷键… / MIDI 映射…"与"输出"菜单里的设置页也是同样的项（标题、selector、representedObject 一样）。
// - 帮助（菜单栏"帮助"与工具条"?"）：PlusMix 使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹。手册不在包里（103 之前）时灰着、标题写明"手册尚未随包"。
import AppKit

@MainActor
enum SettingsMenu {
    /// 输出设置窗的页（"输出"菜单与设置▾ 用同一张表）。
    static let outputPages: [(key: String, tab: OutputSettingsModel.Tab)] = [
        ("menu.output.overview", .overview),   // W5-I 的总览页（设置窗侧栏第一项）；W5-I 报告 §3 第 5 条让 G7 补菜单项
        ("menu.output.record", .record), ("menu.output.iso", .iso), ("menu.output.stream", .stream), ("menu.output.external", .external),
        ("menu.output.ndi", .ndi), ("menu.output.virtualCamera", .virtualCamera), ("menu.output.multiview", .multiview),
    ]

    static func outputPageItem(key: String, tab: OutputSettingsModel.Tab) -> NSMenuItem {
        let item = NSMenuItem(title: L(key), action: #selector(AppDelegate.outputSettings(_:)), keyEquivalent: "")
        item.representedObject = tab.rawValue
        return item
    }

    static func hotkeysItem() -> NSMenuItem {
        NSMenuItem(title: L("menu.settings.hotkeys"), action: #selector(AppDelegate.showHotkeys(_:)), keyEquivalent: "")
    }

    static func midiItem() -> NSMenuItem {
        NSMenuItem(title: L("menu.settings.midi"), action: #selector(AppDelegate.showMIDI(_:)), keyEquivalent: "")
    }

    /// 设置窗某一页的菜单项（输出各页、快捷键、MIDI 与菜单栏里原有的那一项一模一样；别的页走 showSettingsPage(_:)）。
    static func pageItem(_ page: SettingsPage) -> NSMenuItem {
        switch page {
        case .output(let tab):
            if let known = outputPages.first(where: { $0.tab == tab }) { return outputPageItem(key: known.key, tab: tab) }
            let item = NSMenuItem(title: L("menu.settings.pageEllipsis", tab.title), action: #selector(AppDelegate.outputSettings(_:)), keyEquivalent: "")
            item.representedObject = tab.rawValue
            return item
        case .hotkeys: return hotkeysItem()
        case .midi: return midiItem()
        default:
            let item = NSMenuItem(title: L("menu.settings.pageEllipsis", page.title), action: #selector(AppDelegate.showSettingsPage(_:)), keyEquivalent: "")
            item.representedObject = page.id
            return item
        }
    }

    /// 按侧栏顺序分组的全部页（段标题 本节目 / 本机）。
    static func pageItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for group in SettingsPage.Group.allCases {
            if !items.isEmpty { items.append(.separator()) }
            items.append(NSMenuItem.sectionHeader(title: group.title))
            for page in SettingsPage.pages(in: group) { items.append(pageItem(page)) }
        }
        return items
    }

    /// App 菜单"所有设置页 ▸"。
    static func pagesSubmenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L("menu.settings.allPages"))
        for item in pageItems() { menu.addItem(item) }
        let item = NSMenuItem(title: L("menu.settings.allPages"), action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// 工具条"设置▾"。
    static func make() -> NSMenu {
        let menu = NSMenu(title: L("toolbar.settings"))
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for item in pageItems() { menu.addItem(item) }
        return menu
    }
}

@MainActor
enum HelpMenu {
    /// 手册那一项的标题：不在包里时写明。
    static func manualTitle(available: Bool) -> String {
        available ? L("menu.help.manual") : L("menu.help.manualMissing")
    }

    /// 帮助菜单的项（菜单栏与工具条"?"各建一份，项一样）。
    static func items() -> [NSMenuItem] {
        let manual = NSMenuItem(title: manualTitle(available: HelpBook.manualURL() != nil), action: #selector(AppDelegate.showManual(_:)), keyEquivalent: "")
        let hotkeys = NSMenuItem(title: L("menu.help.hotkeyList"), action: #selector(AppDelegate.showHotkeyList(_:)), keyEquivalent: "")
        hotkeys.toolTip = L("menu.help.hotkeyListTip")
        return [manual, hotkeys, .separator(),
                NSMenuItem(title: L("menu.help.exportDiagnostics"), action: #selector(AppDelegate.exportDiagnostics(_:)), keyEquivalent: ""),
                NSMenuItem(title: L("menu.help.showDiagnosticsFolder"), action: #selector(AppDelegate.showDiagnosticsFolder(_:)), keyEquivalent: "")]
    }

    static func make() -> NSMenu {
        let menu = NSMenu(title: L("menu.help"))
        for item in items() { menu.addItem(item) }
        return menu
    }
}
