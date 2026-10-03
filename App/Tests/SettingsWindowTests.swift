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

    /// 打开的是这一页：当前页对、那一页所在的窗显示着；合窗之后一律是同一个设置窗（第一次打开时记下）。
    private var firstSettingsWindow: NSWindow?
    private func assertOpened(_ page: SettingsPage, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let panels = AppTest.controller.panels
        XCTAssertEqual(panels.currentSettingsPage, page, "\(what) → \(page.id)", file: file, line: line)
        let window = panels.settingsWindow(showing: page)
        XCTAssertTrue(window?.isVisible == true, "\(what)：\(page.id) 所在的窗显示着", file: file, line: line)
        if firstSettingsWindow == nil { firstSettingsWindow = window }
        XCTAssertTrue(window === firstSettingsWindow, "\(what)：和别的入口是同一个设置窗", file: file, line: line)
        XCTAssertTrue(window === panels.settingsWindow?.window, "\(what)：就是设置窗", file: file, line: line)
        XCTAssertEqual(panels.settingsWindow?.model.page, page, "\(what)：侧栏选中的就是这一页", file: file, line: line)
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

        // 合成的窗：标题"设置"，侧栏两组、页序；App 菜单"所有设置页 ▸"与设置▾ 是同一批项；页头写明存在哪
        let settings = try XCTUnwrap(panels.settingsWindow)
        XCTAssertEqual(settings.window?.title, "设置")
        XCTAssertEqual(settings.model.sidebar.map(\.group), [.show, .machine])
        XCTAssertEqual(settings.model.sidebar[0].pages.map(\.title), ["节目格式", "输出总览", "录制", "ISO 分路", "推流", "外部显示", "NDI® 发送", "虚拟摄像头", "多画面布局", "节目音频"])   // "输出总览"是 W5-I 的页（G7 合并时补进期望）
        XCTAssertEqual(settings.model.sidebar[1].pages.map(\.title), ["常规", "音频设备", "远程控制", "Tally", "快捷键", "MIDI", "性能与电源", "更新与诊断", "高级"])
        XCTAssertEqual(SettingsPage.Group.show.title, "本节目")
        XCTAssertEqual(SettingsPage.Group.machine.title, "本机")
        panels.showSettings(page: .output(.stream))
        XCTAssertEqual(settings.model.storageNote, "本节目 · 随节目文件保存：另存、换节目时跟着节目走")
        panels.showSettings(page: .advanced)
        XCTAssertEqual(settings.model.storageNote, "本机 · 存在这台 Mac 上，所有节目共用")
        let allPages = try XCTUnwrap(app.items.first { $0.submenu != nil && MenuKeyColumn.title(of: $0) == "所有设置页" }?.submenu, "App 菜单有“所有设置页 ▸”")
        func signature(_ i: NSMenuItem) -> String { i.isSeparatorItem ? "—" : "\(MenuKeyColumn.title(of: i)) → \(i.action.map(NSStringFromSelector) ?? "nil") \(i.representedObject.map { "\($0)" } ?? "")" }
        let toolbarPages = toolbarMenu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && MenuKeyColumn.title(of: $0) != "设置…" }.map(signature)
        XCTAssertEqual(toolbarPages.count, SettingsPage.all.count, "设置▾ 每页一项：\(toolbarPages)")
        XCTAssertEqual(allPages.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }.map(signature), toolbarPages, "App 菜单“所有设置页”= 设置▾ 的页")
        for page in SettingsPage.all {
            let entry = try XCTUnwrap(allPages.items.first { signature($0) == toolbarPages[SettingsPage.all.firstIndex(of: page)!] })
            perform(allPages, entry)
            assertOpened(page, "所有设置页 › \(page.title)")
        }
    }

    // MARK: 2. 快捷键 / MIDI 有未存改动：关窗 / 切页先问 保存 / 放弃 / 取消（X29）

    func testPanels_settingsUnsavedHotkeysAskOnClose() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        let panels = controller.panels
        panels.closeAll()
        defer {
            AppTest.dismissConfirmations()
            panels.closeAll()
            try? controller.applyHotkeyTable(.default)
            try? HotkeyTable.default.save(to: controller.hotkeyFileURL)
        }
        panels.showSettings(page: .hotkeys)
        let settings = try XCTUnwrap(panels.settingsWindow)
        let window = try XCTUnwrap(settings.window)
        let model = settings.model.hotkeys
        model.resetToDefault()
        XCTAssertTrue(model.save())
        XCTAssertFalse(model.isDirty)
        let saved = model.rows.count

        // 关窗：没改过 = 直接关
        window.performClose(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { !window.isVisible }, "没改过就直接关")
        XCTAssertNil(ConfirmationCenter.shared.pending(.unsavedSettings))

        // 改了没存：关窗先问；取消 = 窗还在、改动还在
        panels.showSettings(page: .hotkeys)
        let settings2 = try XCTUnwrap(panels.settingsWindow)
        let window2 = try XCTUnwrap(settings2.window)
        let hotkeys = settings2.model.hotkeys
        hotkeys.addRow(key: "k", action: .command(.cut))
        XCTAssertTrue(hotkeys.isDirty)
        window2.performClose(nil)
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.unsavedSettings), "关窗前先问")
        XCTAssertEqual(ask.request.title, "快捷键有没保存的改动")
        XCTAssertEqual(ask.buttonTitles, ["保存", "取消", "放弃改动"])
        XCTAssertTrue(ask.window === window2, "问在设置窗上")
        AppTest.answer(.cancel)
        XCTAssertTrue(AppTest.waitUntil(2) { ConfirmationCenter.shared.pending(.unsavedSettings) == nil && window2.attachedSheet == nil })   // sheet 挂着时 performClose 不做事：等它收起
        XCTAssertTrue(window2.isVisible, "取消 = 不关")
        XCTAssertEqual(hotkeys.rows.count, saved + 1, "改动还在")

        // 切页同样先问；取消 = 留在快捷键页
        settings2.model.select(.general)
        XCTAssertNotNil(AppTest.waitForConfirmation(.unsavedSettings), "切页前先问")
        AppTest.answer(.cancel)
        XCTAssertTrue(AppTest.waitUntil(2) { ConfirmationCenter.shared.pending(.unsavedSettings) == nil && window2.attachedSheet == nil })   // sheet 挂着时 performClose 不做事：等它收起
        XCTAssertEqual(settings2.model.page, .hotkeys)

        // 放弃 = 关窗、改动丢掉；再打开是存过的那张表
        window2.performClose(nil)
        XCTAssertNotNil(AppTest.waitForConfirmation(.unsavedSettings))
        AppTest.answer(.alternate)
        XCTAssertTrue(AppTest.waitUntil(3) { !window2.isVisible }, "放弃 = 关窗")
        panels.showSettings(page: .hotkeys)
        let reopened = try XCTUnwrap(panels.settingsWindow).model.hotkeys
        XCTAssertEqual(reopened.rows.count, saved, "放弃的改动不在了")
        XCTAssertFalse(reopened.isDirty)
        XCTAssertNil(session.control.hotkeys.table.action(for: KeyCombo(key: "k")))

        // 保存 = 写文件、换给派发器、关窗
        reopened.addRow(key: "k", action: .command(.cut))
        let window3 = try XCTUnwrap(panels.settingsWindow?.window)
        window3.performClose(nil)
        XCTAssertNotNil(AppTest.waitForConfirmation(.unsavedSettings))
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(3) { !window3.isVisible }, "保存 = 存完关窗")
        XCTAssertEqual(session.control.hotkeys.table.action(for: KeyCombo(key: "k")), .command(.cut))
        XCTAssertEqual(try HotkeyTable.load(from: controller.hotkeyFileURL).action(for: KeyCombo(key: "k")), .command(.cut))

        // 存不了（冲突）：点保存也不关，错误写在表下面
        XCTAssertTrue(AppTest.waitUntil(2) { window3.attachedSheet == nil })
        panels.showSettings(page: .hotkeys)
        let conflicted = try XCTUnwrap(panels.settingsWindow)
        conflicted.model.hotkeys.addRow(key: "K", action: .toggleFTB)
        conflicted.window?.performClose(nil)
        XCTAssertNotNil(AppTest.waitForConfirmation(.unsavedSettings))
        AppTest.answer(.confirm)
        AppTest.pump(seconds: 0.3)
        XCTAssertTrue(conflicted.window?.isVisible == true, "冲突存不了：不关")
        XCTAssertNotNil(conflicted.model.hotkeys.errorMessage)
        XCTAssertTrue(AppTest.waitUntil(2) { conflicted.window?.attachedSheet == nil })

        // MIDI 页同一条规则
        conflicted.model.hotkeys.revert()
        conflicted.model.select(.midi)
        XCTAssertEqual(conflicted.model.page, .midi)
        conflicted.model.midi.addRow(trigger: .note(channel: 1, note: 70), action: .action(.command(.cut)))
        conflicted.model.select(.advanced)
        let midiAsk = try XCTUnwrap(AppTest.waitForConfirmation(.unsavedSettings))
        XCTAssertEqual(midiAsk.request.title, "MIDI 映射有没保存的改动")
        AppTest.answer(.alternate)
        XCTAssertTrue(AppTest.waitUntil(2) { conflicted.model.page == .advanced }, "放弃 = 切过去")
        XCTAssertFalse(conflicted.model.midi.isDirty)
    }

    // MARK: 3. 高级页（F7 / Q64）

    func testPanels_advancedPageWritesRecordMinimumFree() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let panels = controller.panels
        let original = controller.settings
        defer {
            panels.closeAll()
            controller.updateSettings(original)
        }
        panels.showSettings(page: .advanced)
        let prefs = try XCTUnwrap(panels.settingsWindow).model.preferences
        // 磁盘下限：即时生效（写 UserDefaults、换给 AppController、跑着的引擎下一次开录起用），不算要重起引擎的项
        prefs.recordMinimumFreeMB = 750
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.recordMinimumFreeMB), 750)
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, 750)
        XCTAssertEqual(session.outputs.minimumFreeBytes, 750 * 1024 * 1024)
        XCTAssertTrue(prefs.pendingRestart.isEmpty, "磁盘下限不用重起引擎")
        XCTAssertEqual(AppSettings.load(arguments: [], defaults: controller.defaults).recordMinimumFreeMB, 750, "下次启动读得回来")
        prefs.recordMinimumFreeMB = -5
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, 0, "负数按 0")
        // 备用目录：即时生效；清空 = 只停录制
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5j-fallback").path
        prefs.recordFallbackDirectory = dir
        XCTAssertEqual(controller.defaults.string(forKey: AppSettings.Keys.recordFallbackDirectory), dir)
        XCTAssertEqual(session.outputs.fallbackDirectory, dir)
        prefs.recordFallbackDirectory = ""
        XCTAssertNil(controller.defaults.string(forKey: AppSettings.Keys.recordFallbackDirectory))
        XCTAssertNil(session.outputs.fallbackDirectory)
        // 监听地址（先能填；98 做"仅本机 / 允许局域网"）：写对了存、要重起引擎；写错了不存、提示
        prefs.apiListenText = "0.0.0.0:9876"
        XCTAssertNil(prefs.listenError)
        XCTAssertEqual(controller.defaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:9876")
        XCTAssertTrue(prefs.pendingRestart.contains(.api), "改了 API 监听地址：要重起引擎")
        prefs.apiListenText = "nope:99999"
        XCTAssertNotNil(prefs.listenError, "端口超范围：提示")
        XCTAssertEqual(controller.defaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:9876", "写错的不存")
        prefs.compatListenText = "0.0.0.0:8100"
        XCTAssertEqual(controller.defaults.string(forKey: AppSettings.Keys.compatLayerHost), "0.0.0.0")
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.compatLayerPort), 8100)
        XCTAssertEqual(controller.settings.compatConfiguration?.host ?? AppSettings.load(arguments: [], defaults: controller.defaults).compatLayerHost, "0.0.0.0")
        // 数字不加千分位
        XCTAssertEqual(PreferencesModel.plainInteger.format(1500), "1500")
    }

    // MARK: 4. 换引擎时窗不关、只重绑；要换引擎的项集中到页底（F4 / F5）

    func testPanels_settingsWindowRebindsAcrossEngineRestart() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let controller = AppTest.controller
        let panels = controller.panels
        defer { panels.closeAll() }
        panels.showSettings(page: .showFormat)
        let settings = try XCTUnwrap(panels.settingsWindow)
        let prefs = settings.model.preferences
        XCTAssertTrue(prefs.pendingRestart.isEmpty)
        XCTAssertEqual(settings.model.pendingSummary, "")
        // 分辨率有 2560×1440 和自定义
        XCTAssertTrue(PreferencesModel.resolutions.contains { $0 == (2560, 1440) })
        prefs.selectFormatPreset(ProgramFormat(width: 2560, height: 1440, frameRate: .fps30))
        XCTAssertEqual(prefs.pendingRestart, [.format])
        prefs.overlaysInPreview.toggle()
        XCTAssertEqual(prefs.pendingRestart, [.format, .overlaysInPreview])
        XCTAssertEqual(settings.model.pendingSummary, "有 2 项待应用：节目格式、PVW 预览全部叠加")
        prefs.overlaysInPreview.toggle()
        XCTAssertEqual(prefs.pendingRestart, [.format], "改回去就不算")
        prefs.setCustomResolution(width: 1000, height: 600)
        XCTAssertEqual(prefs.programFormat, ProgramFormat(width: 1000, height: 600, frameRate: .fps30))
        XCTAssertTrue(prefs.isCustomResolution)
        prefs.selectFormatPreset(ProgramFormat(width: 2560, height: 1440, frameRate: .fps30))
        // 应用并重起引擎：没在录 / 推，直接换；窗不关、页不变，格式读新 session
        XCTAssertTrue(prefs.applyPendingAndRestart())
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session !== session && controller.session?.isRunning == true }, "换了 session")
        XCTAssertEqual(controller.session?.format, ProgramFormat(width: 2560, height: 1440, frameRate: .fps30))
        XCTAssertEqual(controller.session?.state.inputs.count, 1, "输入带过去")
        XCTAssertTrue(panels.settingsWindow === settings && settings.window?.isVisible == true, "换引擎窗不关")
        XCTAssertEqual(settings.model.page, .showFormat)
        XCTAssertTrue(AppTest.waitUntil(2) { prefs.pendingRestart.isEmpty }, "应用完没有待应用的了")
        // 输出页重绑到新 session：加一路推流落在新 session 上
        panels.showSettings(page: .output(.stream))
        let n = settings.model.outputs.addStream(url: AppTest.closedRTMP("w5j"), key: "")
        XCTAssertTrue(AppTest.waitUntil(3) { controller.session?.state.output(n)?.kind == .stream }, "输出页发的命令到新 session")
        // 录 / 推在跑：先确认；取消 = 不换
        let current = try XCTUnwrap(controller.session)
        current.send(.startStream(output: n))
        XCTAssertTrue(AppTest.waitUntil(3) { current.state.output(n)?.enabled == true })
        prefs.selectFormatPreset(.hd1080p60)
        XCTAssertTrue(prefs.applyPendingAndRestart())
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.restartEngine), "推流在跑：先问")
        XCTAssertTrue(ask.window === settings.window, "问在设置窗上")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.3)
        XCTAssertTrue(controller.session === current, "取消 = 不换")
        XCTAssertEqual(prefs.pendingRestart, [.format], "还在待应用")
        current.send(.stopStream(output: n))
    }

    // MARK: 5. 导出 / 导入 / 恢复默认（F6：只动本机级）

    func testPanels_settingsExportImportAndRestoreDefaults() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let panels = controller.panels
        let original = controller.settings
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5j-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppTest.dismissConfirmations()
            panels.closeAll()
            controller.updateSettings(original)
            try? controller.applyHotkeyTable(.default)
            try? HotkeyTable.default.save(to: controller.hotkeyFileURL)
            try? MIDIMapTable.default.save(to: controller.midiFileURL)
            try? controller.applyMIDITable(.default)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panels.showSettings(page: .general)
        let settings = try XCTUnwrap(panels.settingsWindow)
        let prefs = settings.model.preferences
        prefs.confirmBeforeStop = false
        prefs.recordMinimumFreeMB = 321
        prefs.apiToken = "秘密"
        var table = HotkeyTable.default
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "k"), action: .recordAll(mode: .toggle), note: "全部录制"))
        try table.save(to: controller.hotkeyFileURL)
        try controller.applyHotkeyTable(table)
        let midi = MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 40), action: .action(.overlaysOff))])
        try midi.save(to: controller.midiFileURL)
        try controller.applyMIDITable(midi)
        settings.model.reloadTables()

        let url = dir.appendingPathComponent("设置.json")
        try SettingsTransfer.export(controller: controller, to: url)
        let package = try SettingsTransfer.Package.load(from: url)
        XCTAssertEqual(package.defaults[AppSettings.Keys.recordMinimumFreeMB], .int(321))
        XCTAssertEqual(package.defaults[AppSettings.Keys.confirmBeforeStop], .bool(false))
        XCTAssertNil(package.defaults[AppSettings.Keys.apiToken], "访问令牌不导出")
        XCTAssertEqual(package.hotkeys, table)
        XCTAssertEqual(package.midi, midi)
        XCTAssertNil(package.defaults["showName"], "节目里的东西不在包里")

        // 恢复默认：先问；只动本机级（节目格式不动）
        let formatBefore = session.format
        settings.model.restoreDefaults()
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.resetSettings))
        XCTAssertTrue(ask.request.message.contains("快捷键表") && ask.request.message.contains("MIDI 映射"), ask.request.message)
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(2) { controller.settings.confirmBeforeStop && controller.settings.recordMinimumFreeMB == 200 }, "本机设置回到默认")
        XCTAssertEqual(controller.hotkeyTable, .default)
        XCTAssertEqual(controller.midiTable, .default)
        XCTAssertTrue(prefs.confirmBeforeStop, "页面跟着读回")
        XCTAssertEqual(settings.model.hotkeys.rows.count, HotkeyTable.default.bindings.count)
        XCTAssertTrue(controller.session === session && session.format == formatBefore, "节目不动、不换引擎")

        // 导入：先列出要覆盖什么，确认后写回
        settings.model.importSettings(from: url)
        let importAsk = try XCTUnwrap(AppTest.waitForConfirmation(.resetSettings))
        XCTAssertTrue(importAsk.request.message.contains("快捷键表（32 条）"), importAsk.request.message)
        XCTAssertTrue(importAsk.request.message.contains("MIDI 映射（1 条）"), importAsk.request.message)
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(2) { !controller.settings.confirmBeforeStop && controller.settings.recordMinimumFreeMB == 321 })
        XCTAssertEqual(controller.hotkeyTable.action(for: KeyCombo(key: "k")), .recordAll(mode: .toggle))
        XCTAssertEqual(controller.midiTable, midi)
        XCTAssertEqual(try HotkeyTable.load(from: controller.hotkeyFileURL), table, "表也写回文件")
        // 坏文件：报错、什么都不改
        let bad = dir.appendingPathComponent("坏的.json")
        try Data("{".utf8).write(to: bad)
        settings.model.importSettings(from: bad)
        XCTAssertNotNil(settings.model.transferError)
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, 321)
    }
}
