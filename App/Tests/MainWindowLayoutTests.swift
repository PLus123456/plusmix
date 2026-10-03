// W5-A（prompt 86）交付 4：主窗口分栏缩放时输入条 / 调音台不被挤到下限以下（X61 / V-02）；主窗口位置记得住（X45，只在没有存档时居中）；
// 打开节目读回 Show.layout 的 mixerPanelVisible / multiviewWindowVisible / mainWindowFrame（X47）；输入设置窗存档名带编号、同时开的不叠在一起（X44）；
// 交付 6 的 V-31：窗口菜单"调音台 / 多画面"按可见性打勾。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class MainWindowLayoutTests: XCTestCase {
    /// 先 1440×900 再缩到最小窗口（原来 1100×700；W5-G 加了工具条之后外框高 20 pt、内容区不变）：输入条 ≥ 190、调音台 ≥ 340（原来按比例缩到 133 / 216）；
    /// 放回 1440×900 输入条高度不变（差额都给上半区）。
    func testUI_splitKeepsInputStripMinimum() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }
        XCTAssertTrue(wc.isMixerPanelVisible)
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        let strip900 = wc.inputStrip.frame.height
        print("1440×900：输入条 \(strip900)，调音台 \(wc.mixerPanel.frame.width)，上半区 \(wc.transitionPanel.frame.height)")
        XCTAssertGreaterThanOrEqual(strip900, 190)
        // 最小窗口（W5-G 起工具条那一行算在外框里：1100×700 时的内容区 → 外框 AppTest.minimumMainWindowSize，判据不变）
        let minimum = AppTest.minimumMainWindowSize
        AppTest.setMainWindowSize(minimum)
        print("最小窗口 \(Int(minimum.width))×\(Int(minimum.height))（内容区 \(window.contentLayoutRect.size)）：输入条 \(wc.inputStrip.frame.height)，调音台 \(wc.mixerPanel.frame.width)，上半区 \(wc.transitionPanel.frame.height)")
        XCTAssertGreaterThanOrEqual(wc.inputStrip.frame.height, 190, "最小窗口时输入条不低于 190（格子按钮点得到）")
        XCTAssertGreaterThanOrEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth - 1, "最小窗口时调音台不窄于 340")
        XCTAssertGreaterThanOrEqual(wc.transitionPanel.frame.height, wc.transitionPanel.fittingSize.height - 0.5, "上半区放得下转场列")
        AppTest.setMainWindowSize(NSSize(width: 1440, height: 900))
        XCTAssertEqual(wc.inputStrip.frame.height, strip900, accuracy: 1, "窗口放大的差额给上半区，输入条保持原高")
        XCTAssertEqual(wc.mixerPanel.frame.width, Theme.mixerPanelWidth, accuracy: 1, "调音台保持原宽")
    }

    /// 打开节目：调音台显隐、多画面窗口开关、主窗口位置按文件里的 Show.layout 恢复。
    func testShow_layoutKeysRestoredOnOpen() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer {
            window.setFrame(saved, display: true)
            if !wc.isMixerPanelVisible { wc.toggleMixerPanel() }
            if wc.isMultiviewWindowVisible { wc.toggleMultiviewWindow() }
        }
        XCTAssertTrue(wc.isMixerPanelVisible)
        XCTAssertFalse(wc.isMultiviewWindowVisible)
        let visible = (window.screen ?? NSScreen.screens[0]).visibleFrame
        let target = NSRect(x: visible.minX + 40, y: visible.minY + 30, width: 1200, height: 760)
        var show = ShowDocuments.emptyShow(name: "布局")
        show.inputs = [AppTest.syntheticConfig(number: 1)]
        show.layout = ShowLayout(values: ["mixerPanelVisible": .bool(false), "multiviewWindowVisible": .bool(true),
                                          "mainWindowFrame": .string(NSStringFromRect(target))])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("布局.\(ShowDocuments.fileExtension)")
        try show.save().write(to: url)

        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { opened.value && controller.session?.isRunning == true }, "\(String(describing: controller.lastError))")
        AppTest.pump(seconds: 0.3)
        XCTAssertFalse(wc.isMixerPanelVisible, "mixerPanelVisible = false → 调音台收起")
        XCTAssertTrue(wc.isMultiviewWindowVisible, "multiviewWindowVisible = true → 多画面窗口开着")
        XCTAssertEqual(window.frame.origin.x, target.origin.x, accuracy: 1, "mainWindowFrame → 主窗口位置：\(window.frame) / \(target)")
        XCTAssertEqual(window.frame.origin.y, target.origin.y, accuracy: 1)
        XCTAssertEqual(window.frame.size.width, target.size.width, accuracy: 1)
        XCTAssertEqual(window.frame.size.height, target.size.height, accuracy: 1)
        // 存回去还是同样的三个值
        let layout = controller.currentLayout()
        XCTAssertEqual(layout.values["mixerPanelVisible"], .bool(false))
        XCTAssertEqual(layout.values["multiviewWindowVisible"], .bool(true))

        // 屏幕外的位置（别的机器存的、那块屏已经拔了）不搬过去，其余照样恢复
        let offscreen = NSRect(x: -30_000, y: -30_000, width: 1200, height: 760)
        show.layout = ShowLayout(values: ["mixerPanelVisible": .bool(true), "multiviewWindowVisible": .bool(false), "mainWindowFrame": .string(NSStringFromRect(offscreen))])
        try show.save().write(to: url)
        let before = window.frame
        let reopened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); reopened.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { reopened.value && controller.session?.isRunning == true })
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(window.frame, before, "屏幕外的 mainWindowFrame 不用")
        XCTAssertTrue(wc.isMixerPanelVisible)
        XCTAssertFalse(wc.isMultiviewWindowVisible)
    }

    /// X45：有存档就按存档摆（位置 + 大小），没有存档才居中；测试宿主只读存档、不挂存档名，用例改窗口不写回用户真 App 的主窗口位置。
    func testUI_mainWindowRestoresSavedFrameInsteadOfCentering() throws {
        let name = "W5ATest-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let visible = NSScreen.screens[0].visibleFrame
        let savedFrame = NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 1100, height: 700)
        let writer = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        writer.setFrame(savedFrame, display: false)
        writer.saveFrame(usingName: name)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        MainWindowController.placeWindow(w, autosaveName: name)
        XCTAssertEqual(w.frame, savedFrame, "有存档：按存档摆，不再居中")
        XCTAssertEqual(w.frameAutosaveName, name)

        let fresh = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let centered = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        centered.center()
        let other = "W5ATest-none-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(other)") }
        MainWindowController.placeWindow(fresh, autosaveName: other)
        XCTAssertEqual(fresh.frame, centered.frame, "没有存档：居中")

        // saving = false：按存档摆，但不挂存档名（测试宿主就是这样，用例改主窗口不写回用户真 App 的存档）
        let readOnly = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        MainWindowController.placeWindow(readOnly, autosaveName: name, saving: false)
        XCTAssertEqual(readOnly.frame, savedFrame)
        XCTAssertEqual(readOnly.frameAutosaveName, "", "只读存档、不挂存档名")
        let main = try XCTUnwrap(AppTest.controller.windowController.window)
        XCTAssertEqual(main.frameAutosaveName, "", "测试宿主不写用户真 App 的主窗口位置")
        XCTAssertEqual(MainWindowController.autosaveName, "SwitcherMainWindow", "正式 App 的存档名不变（老存档照用）")
    }

    /// X44：输入设置窗的存档名带编号；同时开两路，第二个不叠在第一个上面。
    func testUI_inputSettingsWindowsHaveDistinctAutosaveNames() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let panels = AppTest.controller.panels
        func clearSavedFrames() { for n in 1...2 { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(InputSettingsWindowController.autosaveName(input: n))") } }
        defer {
            panels.closeAll()
            clearSavedFrames()
        }
        clearSavedFrames()
        let w1 = try XCTUnwrap(panels.showInputSettings(input: 1)?.window)
        let w2 = try XCTUnwrap(panels.showInputSettings(input: 2)?.window)
        XCTAssertEqual(w1.frameAutosaveName, "InputSettings-1")
        XCTAssertEqual(w2.frameAutosaveName, "InputSettings-2")
        XCTAssertNotEqual(w1.frame.origin, w2.frame.origin, "同时开的两个输入设置窗不应完全重叠：\(w1.frame) / \(w2.frame)")
    }

    /// V-31：窗口菜单"调音台 / 多画面"是开关，按可见性打勾。
    func testUI_windowMenuChecksMixerAndMultiview() throws {
        _ = try AppTest.freshSession()
        let delegate = AppTest.delegate
        let wc = AppTest.controller.windowController
        let main = try XCTUnwrap(NSApp.mainMenu)
        let windowMenu = try XCTUnwrap(main.items.first { $0.title == L("menu.window") }?.submenu)
        let mixerItem = try XCTUnwrap(windowMenu.items.first { $0.title == L("menu.window.mixer") })
        let multiviewItem = try XCTUnwrap(windowMenu.items.first { $0.title == L("menu.window.multiview") })
        defer {
            if !wc.isMixerPanelVisible { wc.toggleMixerPanel() }
            if wc.isMultiviewWindowVisible { wc.toggleMultiviewWindow() }
        }
        XCTAssertTrue(delegate.validateMenuItem(mixerItem))
        XCTAssertEqual(mixerItem.state, .on, "调音台开着 → ✓")
        XCTAssertTrue(delegate.validateMenuItem(multiviewItem))
        XCTAssertEqual(multiviewItem.state, .off)
        wc.toggleMixerPanel()
        wc.toggleMultiviewWindow()
        AppTest.pump(seconds: 0.2)
        _ = delegate.validateMenuItem(mixerItem)
        _ = delegate.validateMenuItem(multiviewItem)
        XCTAssertEqual(mixerItem.state, .off, "调音台收起 → 没有 ✓")
        XCTAssertEqual(multiviewItem.state, .on, "多画面窗口开着 → ✓")
    }
}
