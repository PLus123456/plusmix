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
}
