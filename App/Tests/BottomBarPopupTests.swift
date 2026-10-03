// W5-A（prompt 86）交付 1 与第 6 条第 1 项：底栏弹出物一律朝上开、整块留在主窗口里（01a E1 / X50 / X63）；外部输出菜单拍平（不用子菜单）、
// 勾按 enabled 打、点 = setOutputEnabled 开关、删除单独一项（UIA-w3-app-misc-logic-bugs 第 1 条）。
// 量法：菜单真弹出来，开着时用 CGWindowList 取本进程弹出菜单窗口的边界（只要窗口边界，不要屏幕录制权限），和窗口服务器给的主窗口边界比（同一个来源：
// 测试宿主不在前台时 setFrame 之后两边会差一拍，见 AppTest.windowServerFrame）；菜单没真弹出来时退到按帮助函数算的位置（BottomBarPopup.menuFrameInScreen，
// 与 popUp 用的是同一个定位点）和 window.frame 比，并打印出来是哪一种。叠加 W5-K 起是独立的叠加设置窗（不是弹出层），只查它不挂在主窗口上。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherExternal
@testable import Switcher

@MainActor
final class BottomBarPopupTests: XCTestCase {
    func testUI_bottomBarPopupsStayInsideWindow() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSyntheticInputs(session, count: 6)   // 调研同一口径：6 路合成源，菜单项最多的情况
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        let saved = window.frame
        defer { window.setFrame(saved, display: true) }

        // 两种窗口；再回到 1440×900 弹一次：程序改了窗口位置以后马上弹，菜单不能落在上一次的地方（按视图坐标弹会，BottomBarPopup.popUp 的说明）
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1100, height: 700), NSSize(width: 1440, height: 900)] {
            let frame = AppTest.setMainWindowSize(size)
            let label = "\(Int(size.width))×\(Int(size.height))"

            // 外部显示菜单（W5-F 起挂在"⚙ 外部显示"的齿轮上，主体 = 全部开 / 关）
            let anchor = wc.bottomBar.external.gearButton
            var computed = NSRect.zero
            let real = AppTest.measurePoppedMenu(open: {
                wc.presentExternalMenu(relativeTo: anchor)
            }, menu: { wc.activeBottomMenu })
            let menu = try XCTUnwrap(wc.activeBottomMenu ?? wc.externalOutputMenu())
            computed = BottomBarPopup.menuFrameInScreen(for: menu, from: anchor)
            let measured = real.max { $0.height < $1.height }
            let menuFrame = measured ?? computed
            // 参照系：实测菜单 → 窗口服务器的主窗口边界；按定位点算 → AppKit 的 window.frame
            let reference = measured != nil ? (AppTest.windowServerFrame(of: window) ?? frame) : frame
            let buttonInWindow = anchor.convert(anchor.bounds, to: nil)
            let buttonTop = reference.minY + buttonInWindow.maxY
            print("[\(label)] 外部输出菜单 \(measured == nil ? "（按定位点算）" : "（实测）") \(menuFrame)；主窗口 \(reference)（AppKit \(frame)）；按钮上沿 y = \(buttonTop)；"
                  + "伸出窗口下沿 \(reference.minY - menuFrame.minY) pt，底边在按钮上沿之上 \(menuFrame.minY - buttonTop) pt")
            XCTAssertTrue(reference.insetBy(dx: -0.5, dy: -0.5).contains(menuFrame), "[\(label)] 外部输出菜单 \(menuFrame) 应整块在主窗口 \(reference) 里")
            XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil }, "[\(label)] 底栏菜单不用子菜单（子菜单方向由系统定、会往下伸）")
            XCTAssertGreaterThanOrEqual(menuFrame.minY, buttonTop - 1, "[\(label)] 菜单朝上开：底边不低于按钮上沿（不盖住按钮）")

            // 叠加…：W5-K 起不再是弹出层，开的是独立的叠加设置窗（I1 / X21：浮层点一下格子的 1–4 就关，边切边调做不到）——
            // 不挂在主窗口上（不是子窗口、不是 sheet），底栏没有要"朝上开、整块在窗口里"的弹出物了
            wc.bottomBar.overlayButton.performClick(nil)
            let overlay = try XCTUnwrap(AppTest.controller.panels.overlaySettingsWindow, "[\(label)] 叠加按钮应打开叠加设置窗")
            XCTAssertTrue(AppTest.waitUntil(2) { overlay.window?.isVisible == true }, "[\(label)] 叠加设置窗应显示")
            XCTAssertNil(overlay.window?.parent, "[\(label)] 叠加设置窗是独立窗口，不是主窗口的子窗口")
            XCTAssertNil(window.attachedSheet, "[\(label)] 不是 sheet")
            overlay.close()
            XCTAssertTrue(AppTest.waitUntil(2) { AppTest.controller.panels.overlaySettingsWindow == nil })
        }
    }

    /// 菜单拍平：每块屏一段（段标题 = 显示器），下面列源；勾 = 那一路外部显示开着（enabled）；点有勾的 = 关（setOutputEnabled，配置留着），
    /// 再点 = 开（同一个输出编号，不新增）；删除是最后一段里单独的一项；"全部关闭"只关不删。
    func testUI_externalMenuFlatChecksEnabledAndTogglesOutput() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        func firstDisplaySection() throws -> [NSMenuItem] {
            let menu = try XCTUnwrap(wc.externalOutputMenu())
            XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil }, "拍平：没有子菜单")
            return try XCTUnwrap(AppTest.menuSections(menu).first)
        }
        let menu = try XCTUnwrap(wc.externalOutputMenu())
        let sections = AppTest.menuSections(menu)
        XCTAssertEqual(sections.count, NSScreen.screens.count + 1, "每块显示器一段 + 末尾设置段（W5-F / M3；没有外部输出时没有删除段）：\(menu.items.map(\.title))")
        for (section, display) in zip(sections, ExternalDisplays.all()) {
            XCTAssertTrue(section[0].isSectionHeader, "段首是显示器的段标题：\(section[0].title)")
            XCTAssertTrue(section[0].title.hasPrefix(display.name), "\(section[0].title) / \(display.name)")
        }
        var first = try firstDisplaySection()
        XCTAssertEqual(first.filter { $0.action != nil }.map(\.title), ["PGM", "PVW", "多画面", "输入 1 合成 1"])
        XCTAssertTrue(first.filter { $0.action != nil }.allSatisfy { $0.state == .off })

        // 选 PVW → 加一路开着的外部显示，菜单重建后打勾
        func pick(_ title: String) throws {
            let menu = try XCTUnwrap(wc.externalOutputMenu())   // 重建一次（菜单项的 target 是最近一次建的 builder）；菜单要留住，菜单项对它是弱引用
            let section = try XCTUnwrap(AppTest.menuSections(menu).first)
            let item = try XCTUnwrap(section.first { $0.title == title && $0.action != nil })
            menu.performActionForItem(at: menu.index(of: item))
        }
        try pick("PVW")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.kind == .externalDisplay && $0.enabled } })
        let output = try XCTUnwrap(session.state.outputs.first { $0.kind == .externalDisplay })
        XCTAssertEqual(ExternalDisplaySpec(settings: output.settings).displayID, ExternalDisplays.id(of: screen))
        first = try firstDisplaySection()
        XCTAssertEqual(first.first { $0.title == "PVW" }?.state, .on)
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] != nil }, "开着 = 有外部窗口")

        // "关闭" = 关掉（不删配置）：勾去掉、窗口关、输出还在（W5-F / M2 起每块屏单选，原来是再点 PVW）
        try pick("关闭")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number)?.enabled == false }, "点“关闭” = setOutputEnabled(false)")
        XCTAssertNotNil(session.state.output(output.number), "配置留着")
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] == nil }, "关掉 = 外部窗口收起")
        first = try firstDisplaySection()
        XCTAssertEqual(first.first { $0.title.hasPrefix("PVW") }?.state, .off, "勾按 enabled 打")
        XCTAssertEqual(first.first { $0.title.hasPrefix("PVW") }?.title, "PVW（已关）", "关着的那一路标（已关）")

        // 再点 PVW = 重新打开同一路（不新增输出）
        try pick("PVW（已关）")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number)?.enabled == true })
        XCTAssertEqual(session.state.outputs.filter { $0.kind == .externalDisplay }.count, 1, "同一个输出，不新增")

        // 删除是单独一项（倒数第二段；最后一段是"外部显示设置… / NDI® 发送设置…"，W5-F / M3）；状态与帧数只读 Stats.display[]
        XCTAssertTrue(AppTest.waitUntil(3) { session.stats?.display.contains { $0.kind == "externalDisplay" && $0.output == output.number } ?? false })
        let menu2 = try XCTUnwrap(wc.externalOutputMenu())
        let tail = try XCTUnwrap(AppTest.menuSections(menu2).dropLast().last)
        let entry = try XCTUnwrap(session.stats?.display.first { $0.kind == "externalDisplay" && $0.output == output.number })
        let remove = try XCTUnwrap(tail.first { $0.title.hasPrefix("删除 \(output.number) ") }, tail.map(\.title).description)
        XCTAssertTrue(remove.title.contains(OutputStatusText.display(entry)), "\(remove.title) / \(OutputStatusText.display(entry))")
        let closeAll = try XCTUnwrap(tail.first { $0.title == L("externalMenu.closeAll") }, "有开着的路时有\"全部关闭\"")
        menu2.performActionForItem(at: menu2.index(of: closeAll))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number)?.enabled == false }, "全部关闭 = 全部 setOutputEnabled(false)")
        XCTAssertNotNil(session.state.output(output.number), "全部关闭只关不删")
        let menu3 = try XCTUnwrap(wc.externalOutputMenu())
        let tail3 = try XCTUnwrap(AppTest.menuSections(menu3).dropLast().last)
        XCTAssertNil(tail3.first { $0.title == L("externalMenu.closeAll") }, "没有开着的路时不列\"全部关闭\"")
        let remove3 = try XCTUnwrap(tail3.first { $0.title.hasPrefix("删除 \(output.number) ") })
        menu3.performActionForItem(at: menu3.index(of: remove3))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number) == nil }, "删除 = removeOutput")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }
}
