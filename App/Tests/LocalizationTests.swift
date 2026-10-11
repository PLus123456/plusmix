// W3-E 交付第 8 条：本地化骨架——zh-Hans + en，字符串全部外置。
// 三个检查：两种语言的键集合相同且没有空值；源码里用到的每个键都在表里；App/Sources 里没有写死的中文文案（日志 / 断言除外）。
import Foundation
import XCTest
import SwitcherContracts
import SwitcherExternal
import SwitcherVirtualCamera
@testable import Switcher

@MainActor
final class LocalizationTests: XCTestCase {
    func testL10n_bothLanguagesHaveSameKeysAndNoEmptyValues() throws {
        let zh = try XCTUnwrap(L10n.table(language: "zh-Hans"), "应有 zh-Hans.lproj/Localizable.strings")
        let en = try XCTUnwrap(L10n.table(language: "en"), "应有 en.lproj/Localizable.strings")
        XCTAssertGreaterThan(zh.count, 100, "文案应全部外置（至少上百条），现在 \(zh.count) 条")
        let onlyZh = Set(zh.keys).subtracting(en.keys).sorted()
        let onlyEn = Set(en.keys).subtracting(zh.keys).sorted()
        XCTAssertEqual(onlyZh, [], "只在 zh-Hans 里的键")
        XCTAssertEqual(onlyEn, [], "只在 en 里的键")
        for (k, v) in zh where v.trimmingCharacters(in: .whitespaces).isEmpty { XCTFail("zh-Hans 空值：\(k)") }
        for (k, v) in en where v.trimmingCharacters(in: .whitespaces).isEmpty { XCTFail("en 空值：\(k)") }
        // 格式串的占位符两边一致（%d / %@ / %.1f 的个数与顺序）
        for (k, zhValue) in zh {
            guard let enValue = en[k] else { continue }
            XCTAssertEqual(AppTest.formatSpecifiers(zhValue), AppTest.formatSpecifiers(enValue), "键 \(k) 两种语言的占位符不一致：\(zhValue) / \(enValue)")
        }
        print("本地化：\(zh.count) 条")
    }

    func testL10n_everyKeyUsedInSourcesExists() throws {
        let root = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        let used = try AppTest.localizationKeysUsed(in: root)
        XCTAssertGreaterThan(used.count, 100, "源码里应有上百处 L(\"…\")：\(used.count)")
        let zh = try XCTUnwrap(L10n.table(language: "zh-Hans"))
        let missing = used.subtracting(zh.keys).sorted()
        XCTAssertEqual(missing, [], "源码里用了但表里没有的键")
        let unused = Set(zh.keys).subtracting(used).sorted()
        print("表里有但源码没直接引用的键（动态拼的键在这里，人工看）：\(unused)")
    }

    /// 反向：表里的键都有人用（源码里出现过这个字面串，或是某个动态拼键 `L("前缀.\(…)")` 的展开）。合并之后没人用的键不再越攒越多
    /// （问题单 G7-w5-app-unused-strings-keys-after-merge；W5-N 顺带删了 36 个，两份表同步）。
    func testL10n_everyKeyInTableIsReferenced() throws {
        let root = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        let refs = try AppTest.localizationReferences(in: root)
        XCTAssertGreaterThan(refs.prefixes.count, 10, "动态拼的键前缀应能认出一批：\(refs.prefixes.sorted())")
        let zh = try XCTUnwrap(L10n.table(language: "zh-Hans"))
        let unused = zh.keys.filter { k in !refs.literals.contains(k) && !refs.prefixes.contains { k.hasPrefix($0) } }.sorted()
        XCTAssertEqual(unused, [], "表里有、App/Sources 里没人用的键（两份表一起删）")
    }

    func testL10n_noHardcodedChineseInUISources() throws {
        let root = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        let violations = try AppTest.chineseLiteralViolations(in: root)
        XCTAssertEqual(violations, [], "App/Sources 里写死的中文文案（应改成 L(\"键\")）：\n" + violations.joined(separator: "\n"))
    }

    /// 包里返回中文的状态文案（SystemExtensionInstaller / ExternalDisplayManager / ExternalDisplaySpec / DiskEstimate 的 describe）在 App 侧查表：
    /// 每个枚举值 / Stats.display 的每个 state 都有两种语言的文案，英文里没有中文（W3-E2 交付第 1 条，G4 问题单第 2 条）。
    func testL10n_packageStatusesLookedUpInApp() {
        let installer: [SystemExtensionInstaller.Status] = [.unknown, .notInstalled, .requesting, .needsUserApproval, .installed(version: "1.0"),
                                                            .installed(version: ""), .uninstalled, .needsReboot]
            + SystemExtensionInstaller.Failure.Reason.allCases.flatMap { reason -> [SystemExtensionInstaller.Status] in
                // W3-C3：失败 = 枚举原因（查表）+ 系统给的描述（原样附在后面）；不带描述的那条检查原因本身的英文
                [.failed(.init(reason: reason, domain: "x", code: 1, detail: "包给的诊断")), .failed(.init(reason: reason, domain: "x", code: 1, detail: ""))]
            }
        let windows: [ExternalDisplayWindow.Status] = [.showing(displayID: 2), .waitingForDisplay(displayID: 3), .fallbackToMain(displayID: 4)]
        func texts() -> [String] {
            installer.map(OutputStatusText.extensionStatus) + windows.map(OutputStatusText.externalWindow)
                + Stats.DisplayEntry.states.map(OutputStatusText.displayState)
                + Stats.DisplayEntry.states.map { OutputStatusText.display(Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 1234, dropped: 5, state: $0)) }
                + Stats.DisplayEntry.states.map { OutputStatusText.virtualCamera(enabled: true, entry: Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 9, dropped: 7, state: $0)) }
                + [OutputStatusText.virtualCamera(enabled: false, entry: nil), OutputStatusText.virtualCamera(enabled: true, entry: nil)]
                + [Double.infinity, 30, 600, 7_500].map(ISORoutes.remainingText)
        }
        let zh = texts()
        for t in zh {
            XCTAssertFalse(t.isEmpty)
            XCTAssertFalse(t.hasPrefix("aux.") || t.hasPrefix("disk."), "缺键：\(t)")
        }
        // 提案 018（W3-C2）：扩展没连上时丢的帧是 undelivered，dropped 只算连上之后被扩展丢的；waitingExtension 那句读 undelivered
        XCTAssertEqual(OutputStatusText.virtualCamera(enabled: true, entry: Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 0, dropped: 0, undelivered: 7, state: "waitingExtension")),
                       "找不到虚拟摄像头设备（扩展未安装 / 未激活）；已丢 7 帧")
        XCTAssertEqual(OutputStatusText.externalWindow(.showing(displayID: 2)), "显示中（显示器 2）")
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = "zh-Hans" }
        let en = texts()
        let cjk = try! NSRegularExpression(pattern: #"[一-鿿　-〿！-～]"#)
        for t in en where !t.contains("包给的诊断") {   // .failed 带的原因是包给的诊断文字，原样附在后面
            XCTAssertNil(cjk.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), "英文文案里有中文：\(t)")
        }
        XCTAssertEqual(OutputStatusText.externalWindow(.showing(displayID: 2)), "Showing (display 2)")
        XCTAssertNotEqual(Set(zh), Set(en))
    }

    func testL10n_lookupUsesOverrideAndFallsBackToKey() {
        // 测试宿主固定 zh-Hans（AppController 设的），中文断言在任何机器上都成立
        XCTAssertEqual(L10n.languageOverride, "zh-Hans")
        XCTAssertEqual(L("menu.show"), "节目")
        XCTAssertEqual(L10n.string("menu.show", language: "en"), "Show")
        XCTAssertEqual(L("this.key.does.not.exist"), "this.key.does.not.exist", "缺键返回键本身（测试 2 会抓）")
        XCTAssertEqual(L("addInput.defaultName.synthetic", 3, "60"), "合成 3 · 60")
        XCTAssertEqual(L10n.string("addInput.defaultName.synthetic", language: "en", 3, "60"), "Synthetic 3 · 60")
    }


    /// W4-D（prompt 75，用户 2026-09-28 定名 PlusMix）：界面文案里的产品名是 PlusMix，代码名 Switcher 不进两种语言的任何一条文案
    /// （模块名 / 命令行工具名 / 键名 / `show.switcher.json` 这种小写的文件后缀不在此列）。点名的几条：App 菜单（关于 / 隐藏 / 退出）、外部输出窗口标题、
    /// 诊断包的文件名与 README、底栏"没有录制输出"的提示里的默认目录（~/Movies/PlusMix）。
    func testW4D_uiStringsUseProductNameNotCodeName() throws {
        let zh = try XCTUnwrap(L10n.table(language: "zh-Hans"))
        let en = try XCTUnwrap(L10n.table(language: "en"))
        let named = ["menu.about", "menu.hide", "menu.quit", "aux.external.windowTitle", "diagnostics.save.name", "diagnostics.readme", "bottom.noRecordOutputTip"]
        for key in named {
            XCTAssertTrue(zh[key]?.contains("PlusMix") == true, "zh-Hans \(key) 该带产品名：\(zh[key] ?? "<缺键>")")
            XCTAssertTrue(en[key]?.contains("PlusMix") == true, "en \(key) 该带产品名：\(en[key] ?? "<缺键>")")
        }
        for (table, lang) in [(zh, "zh-Hans"), (en, "en")] {
            let leaks = table.filter { $0.value.contains("Switcher") }.keys.sorted()
            XCTAssertEqual(leaks, [], "\(lang) 文案里出现了代码名 Switcher（界面上该用 PlusMix）")
        }
        XCTAssertEqual(L("menu.about"), "关于 PlusMix")
        XCTAssertEqual(L10n.string("menu.about", language: "en"), "About PlusMix")
        XCTAssertEqual(L("aux.external.windowTitle"), "PlusMix 外部显示")   // W5-F / M4：统一叫外部显示
        XCTAssertEqual(L10n.string("bottom.noRecordOutputTip", language: "en"), "No record output in this show: clicking adds a default one (~/Movies/PlusMix)")
        XCTAssertEqual(L10n.string("diagnostics.save.name", language: "en", "20260928-1200"), "PlusMix-diagnostics-20260928-1200.zip")
    }

    /// W3-E4 交付第 3 条（reports/w3-outputs-4.md §5 第 6 条）：`// l10n-exempt` 标记原来在剥掉行尾注释之后才找、从来不起作用。
    /// 二选一选"修成先看标记"（整行、剥注释之前）：给将来确实不是界面文案的中文字面量留一个显式、code review 里看得见的豁免口子；现在 App/Sources 没人用它。
    func testW3E4_3_l10nExemptMarkerHonoredBeforeStrippingComments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-l10n-exempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = """
        let a = "写死的中文"
        let b = "豁免的中文"   // l10n-exempt：不是界面文案
        let c = "ascii only"   // 注释里的中文不算
        NSLog("日志里的中文不算")
        // let d = "整行注释里的中文不算"
        let e = \"\"\"
        多行字符串里的中文不算
        \"\"\"
        let f = "第二处写死的中文"
        """
        try sample.write(to: dir.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8)
        let violations = try AppTest.chineseLiteralViolations(in: dir)
        XCTAssertEqual(violations, ["Sample.swift:1 \"写死的中文\"", "Sample.swift:9 \"第二处写死的中文\""],
                       "只报没标记、不在注释 / 日志 / 多行字符串里的两处；带 // l10n-exempt 的那行要豁免")
    }
}
