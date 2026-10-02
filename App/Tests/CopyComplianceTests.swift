// W5-A（prompt 86）交付 5：文案合规与关于面板（01a P4 / X59 / X62 / V-13 / V-14）。
// - 两份 Localizable.strings 都不含竞品模块名（铁律 6 只放行代码里的模块名，界面文案不行）；
// - 关于面板走 orderFrontStandardAboutPanel(options:)，credits 带版本、Apache-2.0、NDI® 商标声明、"查看开源许可"；
// - NDI 在各处第一次出现写 NDI®；开发术语 / 规格号不进界面；音频设备的传输类型（bltn 之类的四字码）翻成人话。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class CopyComplianceTests: XCTestCase {
    private func tables() throws -> [(String, [String: String])] {
        [("zh-Hans", try XCTUnwrap(L10n.table(language: "zh-Hans"))), ("en", try XCTUnwrap(L10n.table(language: "en")))]
    }

    /// make lint 的禁词扫描（scripts/lint-rules.sh）覆盖 App/ 下所有文件里竞品名的其它写法，唯独放行模块名这个 token（代码里要用）；
    /// 它进了界面文案 lint 拦不住（X62），这里补上：两份 .strings 都不许有。
    func testL10n_noModuleNameInUserStrings() throws {
        for (lang, table) in try tables() {
            let hits = table.filter { $0.value.contains("VMixCompat") }.keys.sorted()
            XCTAssertEqual(hits, [], "\(lang) 文案里出现了模块名")
        }
        XCTAssertEqual(L("prefs.compat.title"), "第三方 API 兼容层")
        XCTAssertEqual(L10n.string("prefs.compat.title", language: "en"), "Third-party API compatibility layer")
    }

    func testL10n_ndiTrademarkInAboutCredits() throws {
        for lang in ["zh-Hans", "en"] {
            L10n.languageOverride = lang
            defer { L10n.languageOverride = "zh-Hans" }
            let credits = AboutPanel.credits()
            let text = credits.string
            XCTAssertTrue(text.contains("NDI® is a registered trademark of Vizrt NDI AB"), "[\(lang)] credits 缺 NDI® 商标声明：\(text)")
            XCTAssertTrue(text.contains("Apache License 2.0"), "[\(lang)] credits 缺许可证：\(text)")
            XCTAssertTrue(text.contains(SwitcherVersion.current), "[\(lang)] credits 缺版本：\(text)")
            XCTAssertTrue(text.contains(L("about.licenses")), "[\(lang)] credits 缺\"查看开源许可\"：\(text)")
            XCTAssertFalse(text.contains("Switcher"), "[\(lang)] 不出现代码名")
            // "查看开源许可"是链接：发布包 → Contents/Resources/Licenses/；开发构建 → 仓库的 THIRD_PARTY/README.md
            let range = (text as NSString).range(of: L("about.licenses"))
            let link = credits.attribute(.link, at: range.location, effectiveRange: nil) as? URL
            let expected = try XCTUnwrap(AboutPanel.licensesURL(), "开发构建在仓库里跑，应能找到 THIRD_PARTY/README.md")
            XCTAssertEqual(link, expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), expected.path)
        }
        // 发布包的位置优先：包里有 Licenses/ 就指向它
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("w5a-about-\(UUID().uuidString)/Fake.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let licenses = fake.appendingPathComponent("Contents/Resources/Licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        XCTAssertEqual(AboutPanel.licensesURL(bundleURL: fake, resourceURL: fake.appendingPathComponent("Contents/Resources"))?.standardizedFileURL, licenses.standardizedFileURL)
        // 都找不到：不给链接，写一句说明
        let lonely = FileManager.default.temporaryDirectory.appendingPathComponent("w5a-about-none-\(UUID().uuidString)/Lonely.app", isDirectory: true)
        XCTAssertNil(AboutPanel.licensesURL(bundleURL: lonely, resourceURL: lonely.appendingPathComponent("Contents/Resources")))

        // 关于面板用 options：credits 就是上面那段，系统那一行版本留空（版本在 credits 第一行，不重复）
        let options = AboutPanel.options()
        XCTAssertEqual((options[.credits] as? NSAttributedString)?.string, AboutPanel.credits().string)
        XCTAssertEqual(options[.applicationName] as? String, ProductName.display)
        // App 菜单的"关于"走新入口
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let about = try XCTUnwrap(appMenu.items.first { $0.title == L("menu.about") })
        XCTAssertEqual(about.action, #selector(AppDelegate.showAbout(_:)))
    }

    /// NDI 在各处界面第一次出现的地方写 NDI®（添加输入的类型 / 页标题、输出菜单、输出设置的页签、输入设置的来源行）。
    func testL10n_ndiTrademarkOnFirstUse() throws {
        let keys = ["addInput.kind.ndi", "addInput.ndi.title", "menu.output.ndi", "outputSettings.tab.ndi", "inputSettings.source.ndi"]
        for (lang, table) in try tables() {
            for key in keys {
                XCTAssertTrue(table[key]?.contains("NDI®") == true, "[\(lang)] \(key) 应写 NDI®：\(table[key] ?? "<缺键>")")
            }
        }
    }

    /// V-14：规格号、开发术语、类名 / 命令行参数不进界面文案（实现口径挪进手册）。
    func testL10n_noDevJargonInUserStrings() throws {
        let jargon = ["§", "BLOCKED", "AVCaptureDevice", "ParametricEQ", "DynamicsProcessor", "PeakLimiter", "--api-listen", "--api-token",
                      "--audio-device", "AppleLanguages", "环形缓冲", "ring buffer", "audio ring", "时钟从属", "scheme", "CMIO", "Team ID",
                      "Contents/Library", "bltn"]
        for (lang, table) in try tables() {
            var hits: [String] = []
            for (key, value) in table {
                for token in jargon where value.range(of: token, options: .caseInsensitive) != nil { hits.append("\(key) ← \(token)") }
            }
            XCTAssertEqual(hits.sorted(), [], "\(lang) 文案里的开发术语")
        }
    }

    /// V-14 / V-16：音频设备的传输类型是 CoreAudio 的四字码（"bltn"），界面上翻成人话；不认识的不写。
    func testL10n_audioTransportTypeTranslated() {
        XCTAssertEqual(AudioTransportName.title(fourCC: "bltn"), "内建")
        XCTAssertEqual(AudioTransportName.title(fourCC: "usb "), "USB")
        XCTAssertEqual(AudioTransportName.title(fourCC: "blue"), "蓝牙")
        XCTAssertEqual(AudioTransportName.title(fourCC: "virt"), "虚拟设备")
        XCTAssertNil(AudioTransportName.title(fourCC: "????"), "没有类型（0）不写")
        XCTAssertNil(AudioTransportName.title(fourCC: "zzzz"))
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = "zh-Hans" }
        XCTAssertEqual(AudioTransportName.title(fourCC: "bltn"), "Built-in")
        XCTAssertEqual(AudioTransportName.title(fourCC: "thun"), "Thunderbolt")
    }
}
