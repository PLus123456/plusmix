// W3-E3 交付第 2 条（Aux 文案、主屏层级开关）与第 6 条（App 侧过渡键后备删掉）。
// - 外部输出菜单 / 外部显示设置页 / NDI 页选"输入 n"时注明"Aux = 原始画面（抠像 / 裁切 / 变换不生效）"（G4 裁定，W3-C2 问题单 §3）；
// - 偏好设置"外部输出在主屏上不盖住主界面"→ ExternalDisplayManager.mainScreenLayering（包内选项；UserDefaults 键 App 自定，不进 OutputSettings）；
// - OutputExtras.displayNumber(of:) 只读正式字段 OutputSettings.display（包的 ExternalDisplaySpec 与契约都已不读 extra["displayID"]）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherExternal
@testable import Switcher

@MainActor
final class AuxLayeringAppTests: XCTestCase {
    /// 菜单里能选的源不变（PGM / PVW / 多画面 / 各输入），输入那一组前面一行说明、每个输入项的提示都是这句；设置页（外部显示 / NDI）选输入时显示同一句。
    func testAux_rawPictureNoteInExternalMenuAndSettingsPages() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let wc = AppTest.controller.windowController
        let note = L("aux.rawPictureNote")
        XCTAssertEqual(note, "Aux = 原始画面（抠像 / 裁切 / 变换不生效）")

        let menu = try XCTUnwrap(wc.externalOutputMenu())
        let sub = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(sub.items.filter { $0.action != nil }.map(\.title), ["PGM", "PVW", "多画面", "输入 1 合成 1", "输入 2 合成 2"], "能选的源不变")
        let header = try XCTUnwrap(sub.items.first { $0.title == note }, "输入那一组前面应有说明：\(sub.items.map(\.title))")
        XCTAssertNil(header.action, "说明行不能点")
        let headerIndex = sub.index(of: header)
        let inputIndices = sub.items.indices.filter { sub.items[$0].title.hasPrefix("输入 ") }
        XCTAssertEqual(inputIndices.count, 2)
        XCTAssertTrue(inputIndices.allSatisfy { $0 > headerIndex }, "说明在输入项前面")
        for i in inputIndices { XCTAssertEqual(sub.items[i].toolTip, note, "输入项的提示") }
        for item in sub.items where ["PGM", "PVW", "多画面"].contains(item.title) { XCTAssertNil(item.toolTip, "PGM / PVW / 多画面不是 Aux") }
        // 选 PVW 的那一项位置没变（旧用例按下标点）
        XCTAssertEqual(sub.items[1].title, "PVW")

        let page = AppTest.controller.panels.showOutputSettings(tab: .external).model
        XCTAssertEqual(page.sourceNote(for: .input(number: 1)), note)
        for source in [OutputSource.program, .preview, .multiview] { XCTAssertNil(page.sourceNote(for: source)) }
        page.tab = .ndi
        XCTAssertEqual(page.sourceNote(for: .input(number: 2)), note, "NDI 送输入 n 也是原始画面（该路帧槽分支）")

        L10n.languageOverride = "en"
        defer { L10n.languageOverride = "zh-Hans" }
        let en = L("aux.rawPictureNote")
        XCTAssertTrue(en.hasPrefix("Aux = "), en)
        XCTAssertNil(en.range(of: #"[一-鿿]"#, options: .regularExpression), "英文文案里没有中文：\(en)")
        AppTest.controller.panels.closeAll()
    }

    /// 偏好设置的开关 → UserDefaults 键（App 自定）→ 跑着的 session 立刻生效（包内选项可运行时改），主屏上的外部窗口垫到普通窗口下面；
    /// 换 session 也带着；输出设置不动。关掉恢复盖住（W3-C 起的默认行为）。
    func testExternal_mainScreenLayeringPreferenceReachesManager() throws {
        guard let menuScreen = NSScreen.screens.first, let screenID = menuScreen.displayNumber else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        XCTAssertFalse(controller.settings.externalBehindInterface, "默认关")
        XCTAssertEqual(session.aux.external.mainScreenLayering, .front, "默认盖住主界面（W3-C 起的行为）")

        // 主屏（带菜单栏的那块）上开一路 PGM 外部显示
        let page = controller.panels.showOutputSettings(tab: .external).model
        let number = page.addExternalDisplay(screenNumber: screenID, source: .program)
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[number]?.isShowing == true }, "外部窗口应开在主屏上")
        let external = try XCTUnwrap(session.aux.external.windows[number])
        XCTAssertEqual(external.window?.level, .normal)
        let settingsBefore = try XCTUnwrap(session.state.output(number)?.settings)

        let p = controller.panels.showPreferences()
        XCTAssertFalse(p.model.externalBehindInterface)
        p.model.externalBehindInterface = true
        p.model.apply()
        XCTAssertTrue(controller.defaults.bool(forKey: AppSettings.Keys.externalBehindInterface), "写进 UserDefaults")
        XCTAssertTrue(controller.settings.externalBehindInterface)
        XCTAssertEqual(session.aux.external.mainScreenLayering, .behindInterface, "跑着的 session 立刻生效")
        XCTAssertTrue(AppTest.waitUntil(2) { external.window?.level == ExternalDisplayWindow.behindInterfaceLevel },
                      "主屏上的外部窗口垫到普通窗口下面：\(String(describing: external.window?.level))")
        XCTAssertEqual(session.state.output(number)?.settings, settingsBefore, "不进 OutputSettings")
        XCTAssertTrue(AppSettings.load(arguments: [], defaults: controller.defaults).externalBehindInterface, "下次启动读回同一个键")

        // 换 session（带着外部输出）：新 session 一建好就是 behindInterface
        let done = AppTest.expectationBox()
        Task { await controller.restartSession(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value && controller.session?.isRunning == true && controller.session !== session })
        let next = try XCTUnwrap(controller.session)
        XCTAssertEqual(next.aux.external.mainScreenLayering, .behindInterface)
        XCTAssertTrue(AppTest.waitUntil(3) { next.aux.external.windows[number]?.window?.level == ExternalDisplayWindow.behindInterfaceLevel })

        // 关掉：恢复盖住
        let p2 = controller.panels.showPreferences()
        XCTAssertTrue(p2.model.externalBehindInterface)
        p2.model.externalBehindInterface = false
        p2.model.apply()
        XCTAssertFalse(controller.defaults.bool(forKey: AppSettings.Keys.externalBehindInterface))
        XCTAssertEqual(next.aux.external.mainScreenLayering, .front)
        XCTAssertTrue(AppTest.waitUntil(2) { next.aux.external.windows[number]?.window?.level == .normal })
        next.send(.removeOutput(output: number))
        XCTAssertTrue(AppTest.waitUntil(3) { next.aux.external.windows.isEmpty })
        controller.panels.closeAll()
    }

    /// 交付第 6 条：显示器编号只读正式字段；只带过渡键 extra["displayID"] 的输出读不到——与包的 ExternalDisplaySpec 一致（两边都不读）。
    func testOutputExtras_displayNumberReadsFormalFieldOnly() {
        let formal = OutputState(number: 1, kind: .externalDisplay, name: "formal",
                                 settings: OutputSettings(source: .program, display: DisplayOutputSettings(displayID: 7)))
        XCTAssertEqual(OutputExtras.displayNumber(of: formal), 7)
        let legacy = OutputState(number: 2, kind: .externalDisplay, name: "legacy",
                                 settings: OutputSettings(source: .program, extra: ["displayID": .number(9), "fallbackToMain": .bool(true)]))
        XCTAssertNil(OutputExtras.displayNumber(of: legacy), "过渡键不再读（W3-C2 起包不读、契约也不读）")
        XCTAssertEqual(ExternalDisplaySpec(settings: legacy.settings).displayID, OutputExtras.displayNumber(of: legacy), "与包的读法一致")
        XCTAssertEqual(ExternalDisplaySpec(settings: formal.settings).displayID, OutputExtras.displayNumber(of: formal))
        // 旧节目文件由 Show.load 一次性搬进正式字段（同一套规则），搬完就读得到
        let migrated = OutputState(number: 2, kind: .externalDisplay, name: "legacy", settings: legacy.settings.migratingLegacyKeys())
        XCTAssertEqual(OutputExtras.displayNumber(of: migrated), 9)
    }
}
