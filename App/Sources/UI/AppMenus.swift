// 菜单栏与工具条共用的几份菜单（W5-G，01a F2 / F3 / O2 / O3，docs/ui-study/01-菜单逻辑.md §5）：项都是 nil target 的 AppDelegate 动作
// （菜单栏和工具条点下去走同一段代码，灰不灰由 AppDelegate.validateMenuItem 定），每次现建。
// - 设置▾（工具条右组）：设置… ─ 输出设置的七页 ─ 快捷键… / MIDI 映射…。96 合窗之前设置是几扇窗，这里就是窗口 / 页的列表（01a F2"不合并时是窗口列表"）；
//   App 菜单的"设置… / 快捷键… / MIDI 映射…"与"输出"菜单里的设置页是同样的项。
// - 帮助（菜单栏"帮助"与工具条"?"）：PlusMix 使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹。手册不在包里（103 之前）时灰着、标题写明"手册尚未随包"。
import AppKit

@MainActor
enum SettingsMenu {
    /// 输出设置窗的页（"输出"菜单与设置▾ 用同一张表）。
    static let outputPages: [(key: String, tab: OutputSettingsModel.Tab)] = [
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

    /// 工具条"设置▾"。
    static func make() -> NSMenu {
        let menu = NSMenu(title: L("toolbar.settings"))
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for page in outputPages { menu.addItem(outputPageItem(key: page.key, tab: page.tab)) }
        menu.addItem(.separator())
        menu.addItem(hotkeysItem())
        menu.addItem(midiItem())
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
