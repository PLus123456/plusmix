// W5-J（prompt 96）：设置体系合窗（01a F1–F7，04 Q04 (a) / Q64）——⌘, / 工具条"设置▾" / 各 ⚙ / 菜单里的设置页都打开同一个设置窗的对应页。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class SettingsWindowTests: XCTestCase {
    // MARK: 工具

    private var appMenu: NSMenu {
        get throws { try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu) }
    }

    private func menu(_ title: String) throws -> NSMenu {
        try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "菜单栏缺“\(title)”")
    }

    private func item(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { MenuKeyColumn.title(of: $0) == title },
                      "菜单“\(menu.title)”里没有“\(title)”：\(menu.items.map { MenuKeyColumn.title(of: $0) })", file: file, line: line)
    }

    /// 点一项（= 用户点菜单：target 为 nil 时走响应链）。
    private func perform(_ menu: NSMenu, _ item: NSMenuItem) {
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// 打开的是这一页：当前页对、那一页所在的窗显示着。
    private func assertOpened(_ page: SettingsPage, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let panels = AppTest.controller.panels
        XCTAssertEqual(panels.currentSettingsPage, page, "\(what) → \(page.id)", file: file, line: line)
        XCTAssertTrue(panels.settingsWindow(showing: page)?.isVisible == true, "\(what)：\(page.id) 所在的窗显示着", file: file, line: line)
    }

    // MARK: 1. 入口

    /// ⌘, / 工具条设置主体 = 回到上次那一页（没开过 = 常规）；设置▾ 每一项、App 菜单的快捷键 / MIDI、输出菜单的设置页、底栏各 ⚙ 打开的页都对。
    func testPanels_settingsWindowOpensRequestedPage() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let panels = controller.panels
        let wc = controller.windowController
        panels.closeAll()
        panels.forgetLastSettingsPage()   // 上次那一页是本机记忆：从没开过开始
        defer { panels.closeAll() }

        // ⌘,（App 菜单"设置…"）：没开过 → 常规
        let app = try appMenu
        let settingsItem = try item(app, "设置…")
        XCTAssertEqual(settingsItem.keyEquivalent, ",")
        perform(app, settingsItem)
        assertOpened(.general, "⌘,（第一次）")

        // App 菜单"快捷键… / MIDI 映射…"
        perform(app, try item(app, "快捷键…"))
        assertOpened(.hotkeys, "App 菜单 快捷键…")
        perform(app, try item(app, "MIDI 映射…"))
        assertOpened(.midi, "App 菜单 MIDI 映射…")
        // ⌘, 回到上次那一页
        perform(app, settingsItem)
        assertOpened(.midi, "⌘,（上次是 MIDI）")

        // 工具条设置主体 = ⌘,；设置▾ 的每一项
        let bar = wc.mainToolbar
        panels.showSettings(page: .advanced)
        bar.settings.bodyButton.performClick(nil)
        assertOpened(.advanced, "工具条设置主体（上次是高级）")
        let toolbarMenu = bar.settingsMenu()
        let output = try menu("输出")
        output.delegate?.menuNeedsUpdate?(output)
        for tab in OutputSettingsModel.Tab.allCases {
            let page = SettingsPage.output(tab)
            let viaToolbar = try XCTUnwrap(toolbarMenu.items.first { $0.representedObject as? String == tab.rawValue || $0.representedObject as? String == page.id },
                                           "设置▾ 有 \(page.id)")
            perform(toolbarMenu, viaToolbar)
            assertOpened(page, "设置▾ \(viaToolbar.title)")
            panels.showSettings(page: .general)
            let viaMenu = try XCTUnwrap(output.items.first { ($0.representedObject as? String == tab.rawValue || $0.representedObject as? String == page.id) && $0.action != nil },
                                        "输出菜单有 \(page.id)")
            perform(output, viaMenu)
            assertOpened(page, "输出菜单 \(viaMenu.title)")
        }
        perform(toolbarMenu, try item(toolbarMenu, "快捷键…"))
        assertOpened(.hotkeys, "设置▾ 快捷键…")
        perform(toolbarMenu, try item(toolbarMenu, "MIDI 映射…"))
        assertOpened(.midi, "设置▾ MIDI 映射…")
        perform(toolbarMenu, try item(toolbarMenu, "设置…"))
        assertOpened(.midi, "设置▾ 设置…（回到上次那一页）")

        // 底栏各 ⚙：录制 ⚙ 菜单两项、推流 ⚙、多画面 ⚙、外部显示 ⚙ 菜单末尾两项
        let bottom = wc.bottomBar
        let recordGear = bottom.recordGearMenu()
        perform(recordGear, try item(recordGear, "录制设置…"))
        assertOpened(.output(.record), "录制 ⚙ › 录制设置…")
        perform(recordGear, try item(recordGear, "ISO 分路录制…"))
        assertOpened(.output(.iso), "录制 ⚙ › ISO 分路录制…")
        bottom.stream.gearButton.performClick(nil)
        assertOpened(.output(.stream), "推流 ⚙")
        bottom.multiview.gearButton.performClick(nil)
        assertOpened(.output(.multiview), "多画面 ⚙")
        let external = try XCTUnwrap(wc.externalOutputMenu())
        perform(external, try item(external, "外部显示设置…"))
        assertOpened(.output(.external), "外部显示 ⚙ › 外部显示设置…")
        perform(external, try item(external, "NDI® 发送设置…"))
        assertOpened(.output(.ndi), "外部显示 ⚙ › NDI® 发送设置…")
        // 推流主体在没有目的地时 = 推流页并把焦点放在"添加目的地"（W5-F）
        panels.showStreamAddDestination()
        assertOpened(.output(.stream), "推流主体（没有目的地）")
    }
}
