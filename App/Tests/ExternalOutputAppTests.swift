// W3-C 外部显示 + 多画面窗口（App 级）：外部输出经命令加进节目 → 窗口在指定显示器全屏、跟着节目帧率 blit；拖主窗口不掉帧（missed_render 不增）；
// Aux 输入源取多画面格子；删输出关窗口；节目文件里带着外部输出。本机只有内置屏：指定显示器 = 主屏（外接屏 BLOCKED-硬件）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherRender
import SwitcherExternal
@testable import Switcher

@MainActor
final class ExternalOutputAppTests: XCTestCase {
    func testExternal_windowOnDisplay_followsProgram_dragMainWindowNoMissedRender_auxInput_closeByCommand() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        let wc = AppTest.controller.windowController
        let mainWindow = try XCTUnwrap(wc.window)
        let displayID = ExternalDisplays.id(of: screen)

        // 1. 底栏菜单的同一条路：addOutput(externalDisplay, 主屏, PGM)
        let output = ExternalOutputMenuBuilder.makeOutput(in: session.state, displayID: displayID, displayName: screen.localizedName, source: .program)
        session.send(.addOutput(config: output))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] != nil }, "外部窗口应随快照出现")
        let external = try XCTUnwrap(session.aux.external.windows[output.number])
        XCTAssertEqual(external.status, .showing(displayID: displayID))
        XCTAssertEqual(external.window?.frame, screen.frame, "盖满指定显示器")
        XCTAssertEqual(external.displayView.target, .program)
        AppTest.pump(seconds: 1.5)
        XCTAssertTrue(AppTest.waitUntil(3) { session.stats != nil })
        let baseline = session.stats!.missedRender
        let p0 = external.displayView.presentedFrames
        let t0 = Date()

        // 2. 拖主窗口 2 s（外部窗口在它下面 / 旁边，各自的 display link）
        let origin = mainWindow.frame.origin
        var phase = 0.0
        let dragEnd = Date().addingTimeInterval(2)
        while Date() < dragEnd {
            phase += 0.3
            mainWindow.setFrameOrigin(NSPoint(x: origin.x + 100 * sin(phase), y: origin.y + 60 * cos(phase)))
            AppTest.pump(seconds: 0.03)
        }
        mainWindow.setFrameOrigin(origin)
        AppTest.pump(seconds: 1.2)
        let elapsed = Date().timeIntervalSince(t0)
        let presented = external.displayView.presentedFrames - p0
        let after = session.stats!.missedRender
        print(String(format: "外部显示（App）：%.1f s 外部窗口 blit %d 次（%.1f fps，屏幕 %d Hz）；missed_render %d → %d；外接屏 BLOCKED-硬件（只有内置屏）",
                     elapsed, presented, Double(presented) / elapsed, screen.maximumFramesPerSecond, baseline, after))
        XCTAssertEqual(after, baseline, "拖主窗口期间 missed_render 不该增加")
        XCTAssertGreaterThan(Double(presented) / elapsed, 40, "外部窗口应接近节目帧率")
        XCTAssertLessThanOrEqual(Double(presented) / elapsed, 62)

        // 3. Aux：输入 2 → 多画面里第 2 格；换源走 setOutputSettings
        var aux = ExternalDisplaySpec(settings: output.settings)
        aux.source = .input(number: 2)
        var settings = output.settings
        aux.apply(to: &settings)
        session.send(.setOutputSettings(output: output.number, settings: settings))
        XCTAssertTrue(AppTest.waitUntil(3) { external.displayView.target == .multiview && external.displayView.sourceRect != .full })
        XCTAssertEqual(external.displayView.sourceRect, MultiviewLayout.inputCell(index: 1, inputCount: 2, width: 1920, height: 1080))
        XCTAssertFalse(external.auxUnresolved)
        AppTest.pump(seconds: 0.5)

        // 4. 节目文件里带着它；删输出 → 窗口关
        let show = session.makeShow()
        let saved = try XCTUnwrap(show.outputs.first { $0.number == output.number })
        XCTAssertEqual(saved.kind, .externalDisplay)
        XCTAssertEqual(ExternalDisplaySpec(settings: saved.settings).displayID, displayID)
        XCTAssertEqual(ExternalDisplaySpec(settings: saved.settings).source, .input(number: 2))
        XCTAssertTrue(session.lastNotice?.contains("外部输出") ?? false, "状态行应提示过外部输出状态：\(session.lastNotice ?? "")")
        session.send(.removeOutput(output: output.number))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows.isEmpty }, "删输出应关窗口")
        XCTAssertFalse(external.isShowing)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 外部输出菜单：显示器 × 源，已有的打勾；再选一次 = 删。
    func testExternal_menuListsDisplaysAndSources_marksExisting() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        let menu = try XCTUnwrap(wc.externalOutputMenu())
        XCTAssertEqual(menu.items.count, NSScreen.screens.count, "每块显示器一项（没有外部输出时没有关闭项）")
        let sub = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(sub.items.map(\.title), ["PGM", "PVW", "多画面", "输入 1 合成 1"])
        XCTAssertTrue(sub.items.allSatisfy { $0.state == .off })
        // 选 PVW → 加输出；菜单重建后打勾；再选 → 删
        sub.performActionForItem(at: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.kind == .externalDisplay } })
        let menu2 = try XCTUnwrap(wc.externalOutputMenu())
        let sub2 = try XCTUnwrap(menu2.items.first?.submenu)
        XCTAssertEqual(sub2.items[1].state, .on)
        XCTAssertEqual(menu2.items.count, NSScreen.screens.count + 3, "多了分隔线 + 关闭 x + 关闭全部")
        XCTAssertEqual(ExternalDisplaySpec(settings: session.state.outputs.first { $0.kind == .externalDisplay }!.settings).displayID, ExternalDisplays.id(of: screen))
        // "关闭 n …（状态）"那一项的状态与帧数只读 Stats.display[]（提案 013）
        let number = try XCTUnwrap(session.state.outputs.first { $0.kind == .externalDisplay }?.number)
        XCTAssertTrue(AppTest.waitUntil(3) { session.stats?.display.contains { $0.kind == "externalDisplay" && $0.output == number } ?? false },
                      "Stats.display[] 应有这路外部显示：\(String(describing: session.stats?.display))")
        let menu3 = try XCTUnwrap(wc.externalOutputMenu())   // 同一轮主线程里建菜单、再取同一行 Stats（中间不泵事件，session.stats 不会变）
        let entry = try XCTUnwrap(session.stats?.display.first { $0.kind == "externalDisplay" && $0.output == number })
        let closeItem = try XCTUnwrap(menu3.items.first { $0.action != nil && $0.title.hasPrefix("关闭 \(number) ") }, menu3.items.map(\.title).description)
        XCTAssertTrue(closeItem.title.contains(OutputStatusText.display(entry)), "\(closeItem.title) / \(OutputStatusText.display(entry))")
        XCTAssertTrue(closeItem.title.contains("显示中"), closeItem.title)
        // 菜单项的 target 是最近一次建的 builder（MainWindowController 只留最后一个），所以用 menu3 的子菜单去点
        let sub3 = try XCTUnwrap(menu3.items.first?.submenu)
        XCTAssertEqual(sub3.items[1].state, .on)
        sub3.performActionForItem(at: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.outputs.contains { $0.kind == .externalDisplay } })
    }

    func testMultiview_windowTogglesPresentsAndSavesFrame() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        XCTAssertFalse(wc.isMultiviewWindowVisible)
        wc.bottomBar.multiviewButton.performClick(nil)
        XCTAssertTrue(wc.isMultiviewWindowVisible)
        let mv = try XCTUnwrap(wc.multiviewWindow)
        XCTAssertEqual(mv.displayView.target, .multiview)
        AppTest.pump(seconds: 1.5)
        let p0 = mv.displayView.presentedFrames
        AppTest.pump(seconds: 1)
        XCTAssertGreaterThan(mv.displayView.presentedFrames - p0, 30, "多画面窗口应在刷新")
        mv.window?.setFrame(NSRect(x: 100, y: 100, width: 640, height: 360), display: true)
        let layout = AppTest.controller.currentLayout()
        XCTAssertEqual(layout.values["multiviewWindowVisible"], .bool(true))
        guard case .string(let frame)? = layout.values[MultiviewWindowController.layoutKey] else { return XCTFail("布局里应有多画面窗口位置") }
        XCTAssertEqual(NSRectFromString(frame).size.width, 640, accuracy: 1)
        wc.toggleMultiviewWindow()
        XCTAssertFalse(wc.isMultiviewWindowVisible)
        _ = session
    }
}
