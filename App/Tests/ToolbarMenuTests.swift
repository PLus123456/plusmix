// W5-G（prompt 93）：顶部工具条（A1 / A2 / A5 / A6 / C9 / F2 / M1 / Q28）、监视器标题条齿轮与右键（B1–B4 / Q27）、菜单栏重排（O1–O4 / F3 / Q33 / Q48 / V-24）。
// 工具条按钮与菜单项走同一个 selector（nil target → 响应链 → AppDelegate），所以"工具条点 = 菜单点"在两处是同一段代码；
// "切换"菜单右列的键从当前快捷键表反查，只显示、不设 keyEquivalent（HotkeyDispatcher 才是唯一的触发口）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
import SwitcherExternal
@testable import Switcher

@MainActor
final class ToolbarMenuTests: XCTestCase {
    // MARK: 工具

    private func menu(_ title: String) throws -> NSMenu {
        try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "菜单栏缺“\(title)”：\(NSApp.mainMenu?.items.map(\.title) ?? [])")
    }

    private var appMenu: NSMenu {
        get throws { try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu) }
    }

    /// 按标题（不含右列的键）找菜单项。
    private func item(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { MenuKeyColumn.title(of: $0) == title },
                      "菜单“\(menu.title)”里没有“\(title)”：\(menu.items.map { MenuKeyColumn.title(of: $0) })", file: file, line: line)
    }

    /// 点一项（= 用户点菜单：target 为 nil 时走响应链）。
    private func perform(_ menu: NSMenu, _ item: NSMenuItem) {
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// 菜单要弹出来之前的那次刷新（menuNeedsUpdate，谁是 delegate 就问谁）。
    private func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    /// 一行"标题 | 键"（分隔线写 "—"、段标题写 "# 标题"、子菜单后面加 " ▸"）。
    private func rows(_ menu: NSMenu) -> [String] {
        menu.items.map { i in
            if i.isSeparatorItem { return "—" }
            if i.isSectionHeader { return "# " + i.title }
            let keys = MenuKeyColumn.keys(of: i).map { " | " + $0 } ?? ""
            return MenuKeyColumn.title(of: i) + (i.submenu != nil ? " ▸" : "") + keys
        }
    }

    /// 菜单项摘要（标题、selector、representedObject）——"同一份菜单"按它比。
    private func signature(_ i: NSMenuItem) -> String {
        if i.isSeparatorItem { return "—" }
        let represented = i.representedObject.map { "\($0)" } ?? ""
        return "\(MenuKeyColumn.title(of: i)) → \(i.action.map(NSStringFromSelector) ?? "nil") \(represented)"
    }

    /// 一个装着一路"不存在的显示器"的外部显示输出：开着也不会真弹全屏窗（等显示器、不退回主屏）。
    private func phantomExternalOutput(number: Int, enabled: Bool) -> OutputState {
        let spec = ExternalDisplaySpec(displayID: 0x7EAD_0001, source: .program, fallbackToMain: false)
        return OutputState(number: number, kind: .externalDisplay, name: "测试屏 · PGM", enabled: enabled, settings: spec.outputSettings)
    }

    private func tempDirectory(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5g-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 1. 工具条按钮 = 菜单项（A1 / A2 / F2 / M1 / O3）

    func testUI_toolbarItemsMirrorMenuActions() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let window = try XCTUnwrap(wc.window)
        let bar = wc.mainToolbar
        defer { controller.panels.closeAll() }

        // 一行 .unified：左"节目"组 ｜ 正中 外部显示▾ ｜ 右 录制 / 推流状态 ｜ 设置▾ ｜ ?；没有"暂停输入""精简"（A5 / A6）
        XCTAssertTrue(window.toolbar === bar.toolbar, "主窗口挂着工具条")
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(bar.toolbar.displayMode, .iconOnly, "按钮自己写字，下面不再挂一行标签")
        let ids = bar.toolbar.items.map(\.itemIdentifier)
        let expected: [NSToolbarItem.Identifier] = [MainToolbar.Item.newShow.identifier, MainToolbar.Item.openShow.identifier, MainToolbar.Item.saveShow.identifier,
                                                    MainToolbar.Item.saveShowAs.identifier, .flexibleSpace, MainToolbar.Item.external.identifier, .flexibleSpace,
                                                    MainToolbar.Item.outputStatus.identifier, MainToolbar.Item.settings.identifier, MainToolbar.Item.help.identifier]
        XCTAssertEqual(ids, expected)
        XCTAssertEqual(bar.toolbar.centeredItemIdentifiers, [MainToolbar.Item.external.identifier], "外部显示▾ 居中")
        let titles = AppTest.descendants(of: try XCTUnwrap(window.contentView?.superview), as: NSButton.self).map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("暂停") || $0.contains("精简") }, "不放暂停输入 / 精简：\(titles)")
        XCTAssertEqual(bar.newButton.title, "新建")
        XCTAssertEqual(bar.open.bodyButton.title, "打开")
        XCTAssertEqual(bar.saveButton.title, "保存")
        XCTAssertEqual(bar.saveAsButton.title, "另存为")
        XCTAssertEqual(bar.external.bodyButton.title, "外部显示")
        XCTAssertEqual(bar.settings.bodyButton.title, "设置")
        XCTAssertTrue(bar.open.showsMenu && bar.external.showsMenu && bar.settings.showsMenu, "打开 / 外部显示 / 设置 带 ▾")
        XCTAssertFalse(bar.open.showsGear || bar.external.showsGear || bar.settings.showsGear, "工具条上不放 ⚙（▾ 就是它们的菜单）")

        // 主体按钮的 selector 与菜单项相同，target 都是 nil（响应链 → AppDelegate）
        let show = try menu("节目")
        let output = try menu("输出")
        refresh(output)
        let pairs: [(String, NSButton, NSMenuItem)] = [
            ("新建", bar.newButton, try item(show, "新建")),
            ("打开", bar.open.bodyButton, try item(show, "打开…")),
            ("保存", bar.saveButton, try item(show, "保存")),
            ("另存为", bar.saveAsButton, try item(show, "另存为…")),
            ("设置", bar.settings.bodyButton, try item(try appMenu, "设置…")),
            ("外部显示", bar.external.bodyButton, try XCTUnwrap(output.items.first { $0.action == #selector(AppDelegate.toggleExternalDisplays(_:)) },
                                                            "输出菜单里有外部显示的全部开 / 关：\(rows(output))")),
        ]
        for (name, button, menuItem) in pairs {
            XCTAssertNotNil(button.action, "\(name) 有动作")
            XCTAssertEqual(button.action, menuItem.action, "\(name)：工具条与菜单项同一个 selector")
            XCTAssertNil(button.target, "\(name)：工具条按钮走响应链")
            XCTAssertNil(menuItem.target, "\(name)：菜单项走响应链")
        }
        XCTAssertEqual(try item(show, "新建").keyEquivalent, "n", "⌘N 还在菜单项上")

        // 打开▾ = "打开最近"那一份数据 + 打开上次退出时的节目 + 清除列表
        let dir = try tempDirectory("toolbar")
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.documents.clearRecents()   // 测试宿主的最近列表跨用例共用：上一遍的同名文件会让标题带上目录名
        let url = dir.appendingPathComponent("工具条.\(ShowDocuments.fileExtension)")
        XCTAssertTrue(controller.write(session.makeShow(), to: url))
        let recentItem = try item(show, "打开最近")
        let recent = try XCTUnwrap(recentItem.submenu)
        refresh(recent)
        let openMenu = bar.openMenu()
        let recentRows = recent.items.filter { !$0.isSeparatorItem }.map(signature)
        let openRows = openMenu.items.map(signature)
        for row in recentRows { XCTAssertTrue(openRows.contains(row), "打开▾ 里有“打开最近”的这一项：\(row)\n打开▾：\(openRows)") }
        XCTAssertTrue(openRows.contains(signature(try item(show, "打开上次退出时的节目"))), "打开▾ 里有“打开上次退出时的节目”：\(openRows)")
        XCTAssertTrue(openRows.contains { $0.hasPrefix("工具条.switcher.json → ") }, "刚存的文件在最近列表里：\(openRows)")
        XCTAssertTrue(openRows.contains { $0.hasPrefix("清除列表 → ") })

        // 设置▾ = App 菜单"设置… / 快捷键… / MIDI 映射…"与输出菜单里各设置页的同一批项
        let settingsRows = bar.settingsMenu().items.filter { !$0.isSeparatorItem }.map(signature)
        let menuRows = (try appMenu).items.map(signature) + output.items.map(signature)
        XCTAssertGreaterThanOrEqual(settingsRows.count, 10, "设置▾：设置… + 七个输出设置页 + 快捷键… + MIDI 映射…：\(settingsRows)")
        for row in settingsRows { XCTAssertTrue(menuRows.contains(row), "设置▾ 的“\(row)”在菜单栏里有同样的一项") }
        for name in ["设置…", "快捷键…", "MIDI 映射…", "录制设置…", "推流设置…", "外部显示设置…"] {
            XCTAssertTrue(settingsRows.contains { $0.hasPrefix(name + " → ") }, "设置▾ 有“\(name)”：\(settingsRows)")
        }

        // ? = 帮助菜单同一份（手册那一项的标题随"在不在包里"变，两边都先按同一口径校一次）
        let help = try menu("帮助")
        let toolbarHelp = bar.helpMenu()
        for i in help.items + toolbarHelp.items where i.action != nil { _ = AppTest.delegate.validateMenuItem(i) }
        XCTAssertEqual(toolbarHelp.items.map(signature), help.items.filter { $0.action != nil || $0.isSeparatorItem }.map(signature), "? 弹的就是帮助菜单")

        // 真点：工具条和菜单走同一条路——有未保存的改动时，新建都先问保存（W5-B 的确认，A3）
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1)))
        XCTAssertTrue(AppTest.waitUntil(3) { controller.isDocumentEdited })
        bar.newButton.performClick(nil)
        let asked = try XCTUnwrap(AppTest.waitForConfirmation(.saveChanges), "工具条“新建”先问保存")
        XCTAssertEqual(asked.request.title, "要保存对“工具条”的改动吗？")
        AppTest.answer(.cancel)
        XCTAssertTrue(controller.session === session, "取消 = 不换节目")
        perform(show, try item(show, "新建"))
        XCTAssertNotNil(AppTest.waitForConfirmation(.saveChanges), "菜单“新建”同一问")
        AppTest.answer(.cancel)
        XCTAssertTrue(controller.session === session)
        // sheet 挂着的时候系统把整条工具条置灰（和用户看到的一样），等它收起再点
        XCTAssertTrue(AppTest.waitUntil(2) { window.attachedSheet == nil })

        // 保存：有文件就写回（不弹面板）
        bar.saveButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !controller.isDocumentEdited }, "工具条“保存”写回原文件")
        let saved = try Show.load(from: Data(contentsOf: url))
        XCTAssertEqual(saved.inputs.map(\.number), [1])

        // 外部显示主体 = 菜单"全部开 / 关"（共用开关状态，开着时主体高亮，底栏同一个口径）
        session.send(.addOutput(config: phantomExternalOutput(number: 7, enabled: false)))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(7) != nil })
        bar.external.bodyButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(7)?.enabled == true }, "工具条主体：全部开")
        XCTAssertTrue(AppTest.waitUntil(2) { bar.isExternalHighlighted && bar.external.showsIndicator }, "开着时工具条主体高亮")
        XCTAssertEqual(bar.external.bodyButton.title, "外部显示", "标题文字不变")
        XCTAssertEqual(bar.external.bodyButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.accent,
                       "开着 = 字是强调色（工具条的玻璃外框不画 bezelColor）")
        XCTAssertEqual(wc.bottomBar.external.bodyButton.bezelColor, Theme.accent, "底栏主体同样高亮（同一份开关状态）")
        refresh(output)
        let toggle = try XCTUnwrap(output.items.first { $0.action == #selector(AppDelegate.toggleExternalDisplays(_:)) })
        XCTAssertTrue(AppTest.delegate.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, "关闭全部外部显示", "开着时菜单项写“关闭”")
        perform(output, toggle)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(7)?.enabled == false }, "菜单项：全部关（配置留着）")
        XCTAssertNotNil(session.state.output(7))
        XCTAssertTrue(AppTest.waitUntil(2) { !bar.isExternalHighlighted && !bar.external.showsIndicator })
        XCTAssertNotEqual(bar.external.bodyButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.accent,
                          "关了字色回到系统的")

        // 设置主体 = 设置窗（与 ⌘, 同一个动作：回到上次那一页，W5-J）
        controller.panels.closeAll()
        bar.settings.bodyButton.performClick(nil)
        let page = try XCTUnwrap(controller.panels.currentSettingsPage, "工具条“设置”打开设置窗")
        XCTAssertTrue(controller.panels.settingsWindow(showing: page)?.isVisible == true, "工具条“设置”打开设置窗（\(page.id)）")

        // 打开▾ 里点最近的那一项 = 打开那个文件（与菜单"打开最近"同一条路）；先把测试屏那一路删掉，回到存过的样子（不然要先问保存）
        controller.panels.closeAll()
        session.send(.removeOutput(output: 7))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(7) == nil && !controller.isDocumentEdited })
        let reopenMenu = bar.openMenu()
        let before = controller.session
        perform(reopenMenu, try item(reopenMenu, "工具条.switcher.json"))
        XCTAssertNil(ConfirmationCenter.shared.pending(), "没在跑、没改动：不问")
        XCTAssertTrue(AppTest.waitUntil(15) { controller.session !== before && controller.session?.isRunning == true }, "打开▾ 的最近项打开了那个文件")
        XCTAssertEqual(controller.session?.name, "工具条")
        XCTAssertEqual(controller.session?.state.inputs.map(\.number), [1])
        XCTAssertEqual(controller.session?.control.bus.counters.rejected ?? 0, 0)
    }

    // MARK: 2. 工具条按钮都不抢焦点（C9）

    func testUI_toolbarButtonsRefuseFirstResponder() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let bar = wc.mainToolbar
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })

        // 工具条上能看到的每个按钮（含分体按钮隐藏的那一段）+ 两个监视器的齿轮
        var buttons = bar.allButtons
        XCTAssertEqual(buttons.count, 13, "新建 / 保存 / 另存为 / ? 四个 + 打开 / 外部显示 / 设置三个分体按钮各三段：\(buttons.map(\.title))")
        for item in bar.toolbar.items {
            guard let view = item.view else { continue }
            for b in AppTest.descendants(of: view, as: NSButton.self) where !buttons.contains(where: { $0 === b }) {
                XCTFail("工具条项 \(item.itemIdentifier.rawValue) 里有没列进 allButtons 的按钮：\(b)")
                buttons.append(b)
            }
        }
        buttons += [wc.previewMonitor.gearButton, wc.programMonitor.gearButton]
        for b in buttons {
            XCTAssertTrue(b.refusesFirstResponder, "\(b.title.isEmpty ? (b.accessibilityLabel() ?? "?") : b.title) 应 refusesFirstResponder")
            XCTAssertFalse(b.acceptsFirstResponder, "\(b.title) 不接焦点")
        }
        // ⚙ / ▾ / ? 只有图标：辅助功能名写全
        XCTAssertEqual(bar.open.menuButton.accessibilityLabel(), "打开快捷菜单")
        XCTAssertEqual(bar.external.menuButton.accessibilityLabel(), "外部显示快捷菜单")
        XCTAssertEqual(bar.settings.menuButton.accessibilityLabel(), "设置快捷菜单")
        XCTAssertEqual(bar.helpButton.accessibilityLabel(), "帮助")
        // AccessibilityTests 只走主窗口的内容区，工具条在内容区外面：这里把每一项单独走一遍（按钮都要有名字）
        for item in bar.toolbar.items {
            guard let view = item.view else { continue }
            XCTAssertEqual(AppTest.accessibilityViolations(in: view), [], "工具条项 \(item.itemIdentifier.rawValue) 里缺辅助功能名的控件")
        }
        for monitor in [wc.previewMonitor, wc.programMonitor] {
            XCTAssertEqual(AppTest.accessibilityViolations(in: monitor), [], "监视器标题条（齿轮 / 徽标）缺辅助功能名")
        }

        // 点过工具条按钮之后，空格仍是 Cut（没被按钮吃掉）
        let dir = try tempDirectory("focus")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AppTest.controller.write(session.makeShow(), to: dir.appendingPathComponent("焦点.\(ShowDocuments.fileExtension)")))
        bar.saveButton.performClick(nil)   // 有文件：直接写回，不弹面板
        XCTAssertFalse(window.firstResponder is NSButton, "点按钮后焦点不在按钮上：\(String(describing: window.firstResponder))")
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "空格 = Cut")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 3. "切换"菜单：重排 + 右列从快捷键表反查（O1）

    func testUI_switchMenuShowsHotkeysFromTable() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        let controller = AppTest.controller
        defer { try? controller.applyHotkeyTable(.default) }
        try controller.applyHotkeyTable(.default)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        session.send(.setTransition(type: .fade, durationTicks: 30))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 && session.state.transition.durationTicks == 30 })

        let menu = try menu("切换")
        refresh(menu)
        // Cut ／ 执行当前转场（类型 · 时长）／ ─ ／ 五种类型（T-bar 与回车用，只选不执行）／ ─ ／ FTB ／ Overlay ▸
        // 默认表 W5-J 起有 ⌥1–⌥4（转场槽落地前 = 执行当前转场）与 ⌃1–⌃4（叠加开关）：右列照实写，连号写成"⌥1–⌥4"
        XCTAssertEqual(rows(menu), ["Cut | 空格", "执行当前转场（Fade · 0.5 秒） | 回车、⌥1–⌥4", "—", "# T-bar 和回车用（只选，不执行）",
                                    "Cut", "Fade", "Wipe", "Zoom", "Stinger", "—", "FTB | F", "Overlay ▸"])
        XCTAssertFalse(menu.items.contains { ["快捷键…", "MIDI 映射…"].contains(MenuKeyColumn.title(of: $0)) }, "快捷键 / MIDI 映射挪出了“切换”")
        let cut = try item(menu, "Cut")
        let auto = menu.items[1]
        let typeItems = menu.items.filter { $0.action == #selector(AppDelegate.pickTransitionType(_:)) }
        XCTAssertEqual(typeItems.map { MenuKeyColumn.title(of: $0) }, ["Cut", "Fade", "Wipe", "Zoom", "Stinger"])
        XCTAssertEqual(typeItems.filter { $0.state == .on }.map { MenuKeyColumn.title(of: $0) }, ["Fade"], "当前类型打勾")
        let ftb = try item(menu, "FTB")
        let overlay = try XCTUnwrap(try item(menu, "Overlay").submenu)
        refresh(overlay)
        XCTAssertEqual(rows(overlay), ["Overlay 1（未指定，开 = 用 PVW） | ⌃1", "Overlay 2（未指定，开 = 用 PVW） | ⌃2", "Overlay 3（未指定，开 = 用 PVW） | ⌃3",
                                       "Overlay 4（未指定，开 = 用 PVW） | ⌃4"])
        // 一个 keyEquivalent 都不设（HotkeyDispatcher 是唯一的触发口），子菜单也一样
        func allItems(_ m: NSMenu) -> [NSMenuItem] { m.items + m.items.compactMap(\.submenu).flatMap(allItems) }
        for i in allItems(menu) where !i.isSeparatorItem {
            XCTAssertEqual(i.keyEquivalent, "", "“\(MenuKeyColumn.title(of: i))”不设 keyEquivalent")
        }

        // 改两条快捷键（Cut 从空格换成 C、Overlay 1 从 ⌃1 换成 ⌥⇧1）：菜单右列跟着变
        var table = HotkeyTable.default
        let cutIndex = try XCTUnwrap(table.bindings.firstIndex { $0.action == .command(.cut) })
        table.bindings[cutIndex].key = try XCTUnwrap(KeyCombo("c"))
        let overlayIndex = try XCTUnwrap(table.bindings.firstIndex { $0.action == .toggleOverlay(channel: 1) })
        table.bindings[overlayIndex].key = try XCTUnwrap(KeyCombo("alt+shift+1"))
        try controller.applyHotkeyTable(table)
        refresh(menu)
        refresh(overlay)
        XCTAssertEqual(MenuKeyColumn.keys(of: cut), "C", "Cut 的键跟着表变：\(rows(menu))")
        XCTAssertEqual(MenuKeyColumn.keys(of: auto), "回车、⌥1–⌥4")
        XCTAssertEqual(MenuKeyColumn.keys(of: overlay.items[0]), "⌥⇧1", "Overlay 1 的键：\(rows(overlay))")
        XCTAssertEqual(MenuKeyColumn.keys(of: overlay.items[1]), "⌃2", "Overlay 2 没动")

        // 按一次 C：菜单不认这个键（不会各触发一次），只有快捷键表那一路 → 恰好一次 Cut，来源 hotkey
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        let handled = session.control.hotkeys.counters.handled
        let uiSent = session.commandsSent
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: controller.windowController.window?.windowNumber ?? 0, context: nil,
                                                   characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertFalse(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? true, "菜单栏不认 C（右列只是显示）")
        AppTest.press("c", keyCode: 8)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "C = Cut")
        AppTest.pump(seconds: 0.3)
        let cuts = session.control.bus.recentEntries().filter { $0.sequence > since && $0.command == .cut }
        XCTAssertEqual(cuts.map(\.source), [.hotkey], "只触发一次、来自快捷键表：\(cuts)")
        XCTAssertEqual(session.control.hotkeys.counters.handled, handled + 1)
        XCTAssertEqual(session.commandsSent, uiSent, "菜单那一路没发")

        // 菜单项自己点：选类型只改设置、不执行（与 T-bar 上方那行同一口径）；执行当前转场 = 按当前类型与时长做；FTB / Overlay 是开关、勾 = 开着
        let wipe = typeItems[2]
        refresh(menu)
        XCTAssertTrue(AppTest.delegate.validateMenuItem(wipe))
        perform(menu, wipe)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.type == .wipe }, "选 Wipe = setTransition")
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.transition.isActive, "只选、不执行")
        XCTAssertEqual(session.state.program, 2)
        refresh(menu)
        XCTAssertEqual(MenuKeyColumn.title(of: auto), "执行当前转场（Wipe · 0.5 秒）", "标题写出类型与时长")
        XCTAssertEqual(typeItems.filter { $0.state == .on }.map { MenuKeyColumn.title(of: $0) }, ["Wipe"])
        perform(menu, auto)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive }, "执行当前转场")
        XCTAssertFalse(AppTest.delegate.validateMenuItem(wipe), "转场进行中不能改类型（状态机会拒）")
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.transition.isActive && session.state.program == 1 }, "Wipe 做完，PGM = 原 PVW（1）")
        perform(menu, ftb)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.ftb.on })
        refresh(menu)
        XCTAssertEqual(ftb.state, .on, "FTB 开着 → ✓")
        perform(menu, ftb)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.ftb.on })
        refresh(menu)
        XCTAssertEqual(ftb.state, .off)
        perform(overlay, overlay.items[0])
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[0].on && session.state.overlays[0].input == session.state.preview }, "空通道用 PVW 那一路打开（C6 同口径）")
        refresh(overlay)
        let name = try XCTUnwrap(session.state.input(session.state.preview)?.name)
        XCTAssertEqual(MenuKeyColumn.title(of: overlay.items[0]), "Overlay 1 · \(name)", "标题带输入名")
        XCTAssertEqual(overlay.items[0].state, .on)
        perform(overlay, overlay.items[0])
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[0].on })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 4–5. 监视器齿轮（B1 / B2）、右键（B3）、PGM 叠加徽标（B4）

    func testPanels_pvwGearOpensInputSettingsOfPreview() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        let controller = AppTest.controller
        let wc = controller.windowController
        let pvw = wc.previewMonitor
        defer { controller.panels.closeAll() }
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 3))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 3 })
        AppTest.pump(seconds: 0.1)

        // 标题条右端一个齿轮（标题条里，最右）
        XCTAssertTrue(pvw.gearButton.isDescendant(of: pvw), "齿轮在 PVW 监视器里")
        let gearFrame = pvw.gearButton.convert(pvw.gearButton.bounds, to: pvw)
        XCTAssertGreaterThan(gearFrame.minX, pvw.bounds.width - 40, "齿轮在标题条右端：\(gearFrame) / \(pvw.bounds)")
        XCTAssertLessThanOrEqual(gearFrame.height, Theme.monitorTitleHeight, "齿轮不比标题条高")
        XCTAssertTrue(pvw.gearButton.isEnabled)
        XCTAssertEqual(pvw.gearButton.accessibilityLabel(), "PVW 那一路的输入设置")
        pvw.gearButton.performClick(nil)
        XCTAssertNotNil(controller.panels.inputSettingsWindows[3], "PVW 齿轮 = 打开 PVW 那一路（3）的输入设置")
        XCTAssertNil(controller.panels.inputSettingsWindows[1], "不是 PGM 那一路")
        XCTAssertTrue(controller.panels.inputSettingsWindows[3]?.window?.isVisible == true)

        // 右键 = 小菜单"输入设置… / 全屏输出到 ▸"；画面区（MetalDisplayView）自己不给菜单，右键落到监视器上
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(pvw.display.menu(for: right), "画面区不另给菜单")
        let context = try XCTUnwrap(pvw.menu(for: right), "监视器右键有菜单")
        XCTAssertEqual(rows(context).map { $0.replacingOccurrences(of: " ▸", with: "") }, ["输入设置…", "全屏输出到"])
        controller.panels.closeAll()
        perform(context, context.items[0])
        XCTAssertNotNil(controller.panels.inputSettingsWindows[3], "右键“输入设置…”= 同一路")
        let screens = try XCTUnwrap(context.items[1].submenu)
        XCTAssertEqual(screens.items.filter { !$0.isSeparatorItem }.count, ExternalDisplays.all().count, "全屏输出到 ▸ 每块屏一项：\(rows(screens))")

        // "全屏输出到 ▸"的点法：这块屏没有输出 = 加一路（来源 = 这个监视器的 PVW），有了 = 换源；已经在出 PVW 的那块 = 关（配置留着）
        let fake = DisplayInfo(id: 0x7EAD_0002, name: "测试屏", frame: CGRect(x: 5000, y: 0, width: 1920, height: 1080), isMain: false,
                               maximumFramesPerSecond: 60, backingScaleFactor: 1)
        var sent: [Command] = []
        let builder = ExternalOutputMenuBuilder(state: session.state, displays: [fake])
        builder.send = { sent.append($0) }
        let fullscreen = builder.fullscreenMenu(source: .preview)
        XCTAssertEqual(fullscreen.items.map { MenuKeyColumn.title(of: $0) }, ["测试屏（1920×1080 60 Hz）"])
        XCTAssertEqual(fullscreen.items[0].state, .off)
        perform(fullscreen, fullscreen.items[0])
        guard case .addOutput(let config)? = sent.first else { return XCTFail("没有输出的屏：加一路，\(sent)") }
        XCTAssertEqual(config.kind, .externalDisplay)
        XCTAssertEqual(ExternalDisplaySpec(settings: config.settings).displayID, fake.id)
        XCTAssertEqual(config.settings.source, .preview, "来源 = PVW")
        var on = session.state
        on.outputs.append(config)
        sent.removeAll()
        let builder2 = ExternalOutputMenuBuilder(state: on, displays: [fake])
        builder2.send = { sent.append($0) }
        let fullscreen2 = builder2.fullscreenMenu(source: .preview)
        XCTAssertEqual(fullscreen2.items[0].state, .on, "这块屏正在出 PVW → ✓")
        perform(fullscreen2, fullscreen2.items[0])
        XCTAssertEqual(sent, [.setOutputEnabled(output: config.number, on: false)], "再点 = 关这块屏（配置留着）")

        // 单击监视器不绑动作（防误触）
        controller.panels.closeAll()
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        pvw.display.mouseDown(with: click)
        AppTest.pump(seconds: 0.2)
        XCTAssertTrue(controller.panels.inputSettingsWindows.isEmpty, "单击 / 双击监视器都不开设置")
        XCTAssertEqual(session.state.preview, 3)

        // PVW 黑场：齿轮灰、右键的"输入设置…"灰
        session.send(.setPreview(input: MixerState.noInput))
        XCTAssertTrue(AppTest.waitUntil(2) { !pvw.gearButton.isEnabled }, "PVW 黑场 → 齿轮灰")
        let black = try XCTUnwrap(pvw.menu(for: right))
        XCTAssertFalse(black.items[0].isEnabled, "黑场时右键“输入设置…”灰")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_pgmGearOpensInputSettingsOfProgram() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        let controller = AppTest.controller
        let wc = controller.windowController
        let pgm = wc.programMonitor
        defer { controller.panels.closeAll() }
        session.send(.setProgram(input: 2))
        session.send(.setPreview(input: 3))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 3 })
        AppTest.pump(seconds: 0.1)

        // PGM 齿轮直接开 PGM 那一路（Q27 1-(i)），不弹菜单
        XCTAssertTrue(pgm.gearButton.isEnabled)
        XCTAssertEqual(pgm.gearButton.accessibilityLabel(), "PGM 那一路的输入设置")
        pgm.gearButton.performClick(nil)
        XCTAssertNotNil(controller.panels.inputSettingsWindows[2], "PGM 齿轮 = 打开 PGM 那一路（2）的输入设置")
        XCTAssertNil(controller.panels.inputSettingsWindows[3])

        // 叠加徽标（B4）：每个开着的通道一个"通道号 · 输入名"，只在 PGM 标题条上、不画进画面
        XCTAssertEqual(pgm.overlayBadgeTexts, [], "没有开着的叠加")
        session.send(.overlay(channel: 3, on: true, input: 1))
        session.send(.overlay(channel: 1, on: true, input: 3))
        XCTAssertTrue(AppTest.waitUntil(2) { pgm.overlayBadgeTexts == ["1 · 合成 3", "3 · 合成 1"] }, "通道顺序、带输入名：\(pgm.overlayBadgeTexts)")
        XCTAssertEqual(wc.previewMonitor.overlayBadgeTexts, [], "PVW 不画徽标")
        pgm.layoutSubtreeIfNeeded()   // 刚显示出来的徽标要等下一次布局才有位置（窗口被盖住时不画，这里直接排一次）
        let badgeFrames = pgm.overlayBadgeViews.map { $0.convert($0.bounds, to: pgm) }
        XCTAssertEqual(badgeFrames.count, 2)
        let titleBottom = Theme.monitorTitleHeight
        for f in badgeFrames {
            XCTAssertLessThanOrEqual(f.maxY, pgm.isFlipped ? titleBottom : pgm.bounds.height, "徽标在标题条里")
            XCTAssertGreaterThanOrEqual(f.minY, pgm.isFlipped ? 0 : pgm.bounds.height - titleBottom - 0.5)
        }
        session.send(.overlay(channel: 1, on: false, input: nil))
        XCTAssertTrue(AppTest.waitUntil(2) { pgm.overlayBadgeTexts == ["3 · 合成 1"] }, "关了就不画：\(pgm.overlayBadgeTexts)")
        session.send(.ftb(on: true))
        XCTAssertTrue(AppTest.waitUntil(2) { pgm.roleText == "PGM · FTB" }, "FTB 照旧写在角色那一格")
        session.send(.ftb(on: false))

        // 右键：同样的小菜单，"输入设置…"开的是 PGM 那一路；"全屏输出到 ▸"的来源是 PGM
        controller.panels.closeAll()
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let context = try XCTUnwrap(pgm.menu(for: right))
        perform(context, context.items[0])
        XCTAssertNotNil(controller.panels.inputSettingsWindows[2])

        // PGM 黑场：齿轮灰
        session.send(.setProgram(input: MixerState.noInput))
        XCTAssertTrue(AppTest.waitUntil(2) { !pgm.gearButton.isEnabled }, "PGM 黑场 → 齿轮灰")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    // MARK: 6. "输入 › 输入设置…"写出是哪一路（O4）

    func testUI_inputSettingsMenuTitleNamesInput() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let delegate = AppTest.delegate
        defer { controller.panels.closeAll() }
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 2 })
        let input = try menu("输入")
        refresh(input)
        let settings = try XCTUnwrap(input.items.first { $0.action == #selector(AppDelegate.inputSettings(_:)) }, "\(rows(input))")
        XCTAssertEqual(settings.title, "输入 2「合成 2」设置…")
        XCTAssertEqual(settings.keyEquivalent, "I", "⇧⌘I 不变")
        XCTAssertTrue(delegate.validateMenuItem(settings))
        perform(input, settings)
        XCTAssertNotNil(controller.panels.inputSettingsWindows[2], "开的是 PVW 那一路")
        XCTAssertNil(controller.panels.inputSettingsWindows[1])

        // 改名后标题跟着变
        session.send(.renameInput(input: 2, name: "讲台机位"))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(2)?.name == "讲台机位" })
        refresh(input)
        XCTAssertEqual(settings.title, "输入 2「讲台机位」设置…")

        // PVW 黑场：灰（不再悄悄换成第一路）
        controller.panels.closeAll()
        session.send(.setPreview(input: MixerState.noInput))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == MixerState.noInput })
        refresh(input)
        XCTAssertEqual(settings.title, "输入设置…")
        XCTAssertFalse(delegate.validateMenuItem(settings), "PVW 空时置灰")
        perform(input, settings)
        XCTAssertTrue(controller.panels.inputSettingsWindows.isEmpty, "PVW 空时不开任何一路")
    }

    // MARK: 补充：节目菜单（A2 / V-24）、App 菜单（O2 / F3）、帮助（O3 / Q33）、最小窗口

    /// "打开最近"同名文件带上级目录名（V-24）；节目菜单与 打开▾ 都有"打开上次退出时的节目"，打开的是退出时自动存的那份（LastSession）。
    func testUI_recentMenuDisambiguatesSameNamesAndOpensLastSession() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let dir = try tempDirectory("recent")
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.documents.clearRecents()   // 测试宿主的最近列表跨用例、跨 worktree 共用：上一遍留下的同名文件会让目录名再往上加一级
        let a = dir.appendingPathComponent("周日/节目.\(ShowDocuments.fileExtension)")
        let b = dir.appendingPathComponent("周三/节目.\(ShowDocuments.fileExtension)")
        let c = dir.appendingPathComponent("周三/独一份.\(ShowDocuments.fileExtension)")
        for u in [a, b, c] {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(controller.write(session.makeShow(), to: u))
        }
        XCTAssertEqual(ShowMenu.recentTitles([c, b, a]), ["独一份.switcher.json", "节目.switcher.json — 周三", "节目.switcher.json — 周日"])
        XCTAssertEqual(ShowMenu.recentTitles([a]), ["节目.switcher.json"], "不重名就只写文件名")
        let show = try menu("节目")
        let recent = try XCTUnwrap(try item(show, "打开最近").submenu)
        refresh(recent)
        XCTAssertEqual(Array(recent.items.prefix(3).map { MenuKeyColumn.title(of: $0) }), ["独一份.switcher.json", "节目.switcher.json — 周三", "节目.switcher.json — 周日"])
        XCTAssertEqual(recent.items[1].toolTip, b.path, "提示是完整路径")
        XCTAssertEqual(recent.items[1].representedObject as? URL, b)

        // 节目菜单的顺序（01 §5）：新建 / 打开… / 打开最近 ▸ / 打开上次退出时的节目 / ─ / 保存 / 另存为…
        XCTAssertEqual(rows(show), ["新建", "打开…", "打开最近 ▸", "打开上次退出时的节目", "—", "保存", "另存为…"])

        // 打开上次退出时的节目：没有 LastSession 时灰；有就打开它（没存成文件 = 未保存，和启动时恢复同一口径）
        let last = try item(show, "打开上次退出时的节目")
        try? FileManager.default.removeItem(at: controller.documents.autosaveURL)
        XCTAssertFalse(AppTest.delegate.validateMenuItem(last), "没有退出时自动存的节目 → 灰")
        var saved = ShowDocuments.emptyShow(name: "上次那一场")
        saved.inputs = [AppTest.syntheticConfig(number: 4)]
        controller.documents.autosave(saved)
        defer { try? FileManager.default.removeItem(at: controller.documents.autosaveURL) }
        XCTAssertTrue(AppTest.delegate.validateMenuItem(last))
        let before = controller.session
        perform(show, last)
        XCTAssertTrue(AppTest.waitUntil(15) { controller.session !== before && controller.session?.isRunning == true }, "打开了上次退出时的节目")
        XCTAssertEqual(controller.session?.state.inputs.map(\.number), [4])
        XCTAssertEqual(controller.session?.name, "上次那一场")
        XCTAssertNil(controller.documents.currentURL, "不是文件：保存时要另存")
        XCTAssertTrue(controller.isDocumentEdited, "有内容就算未保存（与启动时从 LastSession 恢复同一口径）")
    }

    /// App 菜单："偏好设置…"改叫"设置…"（⌘, 不变）；快捷键… / MIDI 映射… 挪到它下面（Q48 / F3）。
    func testUI_appMenuSettingsRenamedAndHotkeysMoved() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        defer { controller.panels.closeAll() }
        let app = try appMenu
        let titles = app.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertFalse(titles.contains("偏好设置…"), "不再叫偏好设置：\(titles)")
        let settings = try item(app, "设置…")
        XCTAssertEqual(settings.keyEquivalent, ",")
        let index = app.index(of: settings)
        XCTAssertEqual(Array(titles[index...(index + 2)]), ["设置…", "快捷键…", "MIDI 映射…"], "快捷键 / MIDI 映射挂在“设置…”下面")
        XCTAssertEqual(L10n.string("menu.settings", language: "en"), "Settings…")
        perform(app, try item(app, "快捷键…"))
        XCTAssertNotNil(controller.panels.hotkeyWindow)
        perform(app, try item(app, "MIDI 映射…"))
        XCTAssertNotNil(controller.panels.midiWindow)
        // 转场列按钮提示里"去哪改快捷键"跟着改（原来写"切换 › 快捷键…"）
        XCTAssertFalse(L("transition.tip.noKeys", "x").contains("切换 ›"), L("transition.tip.noKeys", "x"))
    }

    /// 帮助菜单：PlusMix 使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹（O3）；手册不在包里时灰、写"手册尚未随包"（Q33）；
    /// 快捷键一览按当前表生成一页 HTML（临时文件）再打开。
    func testUI_helpMenuOffersManualAndHotkeyList() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let delegate = AppTest.delegate
        defer { try? controller.applyHotkeyTable(.default) }
        var opened: [URL] = []
        let savedOpener = HelpBook.open
        HelpBook.open = { opened.append($0) }
        defer { HelpBook.open = savedOpener; HelpBook.resourceURLOverride = nil }

        let help = try menu("帮助")
        XCTAssertTrue(NSApp.helpMenu === help)
        // 系统会往帮助菜单里塞一个搜索框（没有 action），只看我们自己的项
        let ours = help.items.filter { $0.action != nil || $0.isSeparatorItem }
        XCTAssertEqual(ours.map { $0.action.map(NSStringFromSelector) ?? "—" },
                       ["showManual:", "showHotkeyList:", "—", "exportDiagnostics:", "showDiagnosticsFolder:"], "使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹")
        XCTAssertEqual(ours.dropFirst().map { $0.isSeparatorItem ? "—" : $0.title }, ["快捷键一览", "—", "导出诊断包…", "打开诊断文件夹"])

        // 手册不在：灰、写明（测试宿主包里没有 Help/）
        let empty = try tempDirectory("nohelp")
        defer { try? FileManager.default.removeItem(at: empty) }
        HelpBook.resourceURLOverride = empty
        let manual = try XCTUnwrap(help.items.first { $0.action == #selector(AppDelegate.showManual(_:)) })
        XCTAssertFalse(delegate.validateMenuItem(manual), "手册不在包里 → 灰")
        XCTAssertEqual(manual.title, "PlusMix 使用手册（手册尚未随包）")
        // 手册在：可点，打开 Help/<语言>/index.html（没有分语言的就 Help/index.html）
        let bundle = try tempDirectory("help")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let page = bundle.appendingPathComponent("Help/zh-Hans/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: page)
        HelpBook.resourceURLOverride = bundle
        XCTAssertTrue(delegate.validateMenuItem(manual))
        XCTAssertEqual(manual.title, "PlusMix 使用手册")
        perform(help, manual)
        XCTAssertEqual(opened.last?.standardizedFileURL, page.standardizedFileURL)
        try FileManager.default.removeItem(at: page)
        let root = bundle.appendingPathComponent("Help/index.html")
        try Data("<html></html>".utf8).write(to: root)
        XCTAssertEqual(HelpBook.manualURL()?.standardizedFileURL, root.standardizedFileURL, "没有分语言的目录就用 Help/index.html")

        // 快捷键一览：按当前表生成（改了表就跟着变）
        var table = HotkeyTable.default
        table.bindings.append(HotkeyBinding(key: try XCTUnwrap(KeyCombo("alt+3")), action: .toggleOverlay(channel: 3), note: "台标"))
        try controller.applyHotkeyTable(table)
        perform(help, try item(help, "快捷键一览"))
        let list = try XCTUnwrap(opened.last)
        XCTAssertEqual(list.pathExtension, "html")
        XCTAssertTrue(list.path.hasPrefix(FileManager.default.temporaryDirectory.path) || list.path.contains("/T/"), "临时文件：\(list.path)")
        let html = try String(contentsOf: list, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>PlusMix 快捷键一览</title>"), html.prefix(300).description)
        for text in ["空格", "回车", "⇧1", "⌥3", "台标", "叠加开关", "Cut"] {
            XCTAssertTrue(html.contains(text), "一览里有“\(text)”")
        }
        XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, table.bindings.count + 1, "表头 + 每条绑定一行")
        XCTAssertFalse(html.contains("<script"), "静态页")
        XCTAssertTrue(HotkeyListPage.html(table: HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo(key: "x"), action: .command(.cut), note: "<b>&</b>")])).contains("&lt;b&gt;&amp;&lt;/b&gt;"), "备注转义")
    }

    /// 最小窗口：工具条八项都在（不挤进溢出菜单）、外部显示▾ 居中；内容区的最小高跟没有工具条时 1100×700 的一样（转场列 / 输入条的保证不变）。
    func testUI_toolbarFitsMinimumWindow() throws {
        _ = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        let plainContent = NSWindow.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: window.styleMask)
        XCTAssertEqual(window.contentMinSize.width, 1100)
        XCTAssertEqual(window.contentMinSize.height, plainContent.height, accuracy: 0.5, "内容区最小高 = 原来 1100×700 时的内容高")
        XCTAssertEqual(AppTest.minimumMainWindowSize, window.minSize)
        for size in [AppTest.minimumMainWindowSize, NSSize(width: 1440, height: 900)] {
            AppTest.setMainWindowSize(size)
            let label = "\(Int(size.width))×\(Int(size.height))"
            let visible = wc.mainToolbar.toolbar.visibleItems?.map(\.itemIdentifier) ?? []
            XCTAssertEqual(visible, wc.mainToolbar.toolbar.items.map(\.itemIdentifier), "[\(label)] 工具条每一项都在，没有挤进溢出菜单")
            let ext = wc.mainToolbar.external
            let mid = ext.convert(ext.bounds, to: nil).midX
            XCTAssertEqual(mid, window.frame.width / 2, accuracy: size.width < 1200 ? 60 : 4, "[\(label)] 外部显示▾ 在正中附近")
            XCTAssertEqual(window.contentLayoutRect.height, max(size.height - (window.frame.height - window.contentLayoutRect.height), 0), accuracy: 0.5)
        }
        XCTAssertGreaterThanOrEqual(AppTest.minimumMainWindowSize.height - plainContent.height, 40, "工具条那一行算在窗口外框里")
    }
}
