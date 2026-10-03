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

        // 3. Aux：输入 2 → AuxInputView 画输入 2 的全分辨率帧（W3-C2，G4 裁定：Aux 不再用多画面格子）；换源走 setOutputSettings
        var aux = ExternalDisplaySpec(settings: output.settings)
        aux.source = .input(number: 2)
        var settings = output.settings
        aux.apply(to: &settings)
        session.send(.setOutputSettings(output: output.number, settings: settings))
        XCTAssertTrue(AppTest.waitUntil(3) { external.auxView.presenter.input == 2 && !external.auxView.isHidden })
        XCTAssertTrue(external.displayView.isHidden, "Aux 不再用多画面纹理")
        XCTAssertFalse(external.auxUnresolved)
        XCTAssertTrue(AppTest.waitUntil(3) { external.auxView.presentedFrames > 10 }, "分支接上了，输入 2 的帧在画")
        XCTAssertEqual(external.auxView.presenter.signal, .live)
        AppTest.pump(seconds: 0.5)

        // 4. 节目文件里带着它；删输出 → 窗口关
        let show = session.makeShow()
        let saved = try XCTUnwrap(show.outputs.first { $0.number == output.number })
        XCTAssertEqual(saved.kind, .externalDisplay)
        XCTAssertEqual(ExternalDisplaySpec(settings: saved.settings).displayID, displayID)
        XCTAssertEqual(ExternalDisplaySpec(settings: saved.settings).source, .input(number: 2))
        XCTAssertTrue(session.lastNotice?.contains("外部显示") ?? false, "状态行应提示过外部显示状态（W5-F / M4 起统一叫外部显示）：\(session.lastNotice ?? "")")
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
        // W5-A 起菜单拍平：每块显示器一段（段标题 = 显示器），没有子菜单；勾 = 开着；删除是倒数第二段单独一项。
        // W5-F（M2 / M3）：每块屏单选，这块屏有配置时最上一项"关闭"（关，不删）；最后一段是"外部显示设置… / NDI® 发送设置…"
        let menu = try XCTUnwrap(wc.externalOutputMenu())
        XCTAssertEqual(AppTest.menuSections(menu).count, NSScreen.screens.count + 1, "每块显示器一段 + 末尾设置段（没有外部输出时没有删除段）")
        let sub = try XCTUnwrap(AppTest.menuSections(menu).first)
        // 能选的源（有动作的项）；输入那一组前面另有一行"Aux = 原始画面"的说明（W3-E3 交付第 2 条，AuxLayeringAppTests 看它）
        XCTAssertEqual(sub.filter { $0.action != nil }.map(\.title), ["PGM", "PVW", "多画面", "输入 1 合成 1"])
        XCTAssertTrue(sub.allSatisfy { $0.state == .off })
        // 选 PVW → 加输出；菜单重建后打勾
        let pvw = try XCTUnwrap(sub.first { $0.title == "PVW" })
        menu.performActionForItem(at: menu.index(of: pvw))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.kind == .externalDisplay } })
        let menu2 = try XCTUnwrap(wc.externalOutputMenu())
        let sub2 = try XCTUnwrap(AppTest.menuSections(menu2).first)
        XCTAssertEqual(sub2.first { $0.title == "PVW" }?.state, .on)
        XCTAssertEqual(AppTest.menuSections(menu2).count, NSScreen.screens.count + 2, "多了一段：删除 x + 全部关闭")
        let sections2 = AppTest.menuSections(menu2)
        XCTAssertEqual(sections2[sections2.count - 2].count, 2, "删除段：删除 x + 全部关闭（最后一段是设置）")
        XCTAssertEqual(ExternalDisplaySpec(settings: session.state.outputs.first { $0.kind == .externalDisplay }!.settings).displayID, ExternalDisplays.id(of: screen))
        // "关闭 n …（状态）"那一项的状态与帧数只读 Stats.display[]（提案 013）
        let number = try XCTUnwrap(session.state.outputs.first { $0.kind == .externalDisplay }?.number)
        XCTAssertTrue(AppTest.waitUntil(3) { session.stats?.display.contains { $0.kind == "externalDisplay" && $0.output == number } ?? false },
                      "Stats.display[] 应有这路外部显示：\(String(describing: session.stats?.display))")
        let menu3 = try XCTUnwrap(wc.externalOutputMenu())   // 同一轮主线程里建菜单、再取同一行 Stats（中间不泵事件，session.stats 不会变）
        let entry = try XCTUnwrap(session.stats?.display.first { $0.kind == "externalDisplay" && $0.output == number })
        let removeItem = try XCTUnwrap(menu3.items.first { $0.action != nil && $0.title.hasPrefix("删除 \(number) ") }, menu3.items.map(\.title).description)
        XCTAssertTrue(removeItem.title.contains(OutputStatusText.display(entry)), "\(removeItem.title) / \(OutputStatusText.display(entry))")
        XCTAssertTrue(removeItem.title.contains("显示中"), removeItem.title)
        // 菜单项的 target 是最近一次建的 builder（MainWindowController 只留最后一个），所以用 menu3 去点："关闭" = 关（配置留着；W5-F 起单选，
        // 原来是再点 PVW），删除项 = 删
        let sub3 = try XCTUnwrap(AppTest.menuSections(menu3).first)
        let pvw3 = try XCTUnwrap(sub3.first { $0.title == "PVW" })
        XCTAssertEqual(pvw3.state, .on)
        let off3 = try XCTUnwrap(sub3.first { $0.title == "关闭" }, sub3.map(\.title).description)
        menu3.performActionForItem(at: menu3.index(of: off3))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(number)?.enabled == false }, "关闭 = 关，不删")
        let menu4 = try XCTUnwrap(wc.externalOutputMenu())
        let remove4 = try XCTUnwrap(menu4.items.first { $0.title.hasPrefix("删除 \(number) ") })
        menu4.performActionForItem(at: menu4.index(of: remove4))
        XCTAssertTrue(AppTest.waitUntil(3) { !session.state.outputs.contains { $0.kind == .externalDisplay } })
    }

    func testMultiview_windowTogglesPresentsAndSavesFrame() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        XCTAssertFalse(wc.isMultiviewWindowVisible)
        wc.bottomBar.multiview.bodyButton.performClick(nil)
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
