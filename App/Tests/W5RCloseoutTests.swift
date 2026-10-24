// W5-R（prompt 130）App 收口二：Codex 2026-10-22 全仓审查与 10-24 网络安全审计里归 App 的四条（G11 排进 128 前）。
// N04 录制磁盘下限 MB → 字节换算溢出：defaults / 启动参数 / 设置窗 / 设置导入都钳到 AppSettings.maxRecordMinimumFreeMB，字节只在 recordMinimumFreeBytes 一处算；
// N06 ISO 切备用目录：旧录制器封口时把它的分支还给那一路；这一路分支开不到（4 个占满）就不切、停这一路并提示，绝不退成 PGM 录制器 + Master 音频；
// N07 纯音频输入的 ISO：开分支时往分支里推一帧黑，tap 每拍重复它 → 黑画面 + 本路声音；ISO 行副标题写明"画面为黑"；
// NS08 远程控制页允许局域网时提醒令牌和全部状态走明文（有没有 token 都提醒）。
// N06 两条与 N07 一条从 Codex 的红用例搬来（reports/codex-bug-audit-20261022-tests/ 的 testS7_ISOFallback… 两条与
// testAudioOnlyISOSelectedInSettingsMustProduceRecording）：DiskMonitor.onEvent 注入、独立临时目录、合成 PCM 工厂照旧；满额那条按本路的修法
// 改成"不切 + 提示"（原断言要求切过去且仍是 ISO，开不到分支时做不到）。
import AppKit
import AVFoundation
import XCTest
import SwitcherContracts
import SwitcherAudio
import SwitcherEngine
import SwitcherISO
import SwitcherInputs
import SwitcherTestKit
@testable import Switcher

@MainActor
final class W5RCloseoutTests: XCTestCase {
    /// 16 TiB（= 2^24 MB）：换算成字节 2^44，离 UInt64 的上限远着；溢出点是 2^44 MB。
    private static let limitMB = 16_777_216

    /// 自己起的 session 用的设置：不出声、不起 API / 兼容层 / tally、不防睡眠（不碰宿主那一个）。
    private static func isolatedSettings(_ base: AppSettings = AppSettings()) -> AppSettings {
        var s = base
        s.audioDevice = .null
        s.apiEnabled = false
        s.compatLayerEnabled = false
        s.tallyEnabled = false
        s.preventSleepWhileRunning = false
        s.preventDisplaySleepWhileRunning = false
        return s
    }

    // MARK: N04 录制磁盘下限

    /// N04：defaults 里存着 2^44 − 1 / 2^44 / Int.max MB（上一次在设置窗填超了、commitSettings 先落盘再崩；或手改 defaults）——读回来钳到上限，
    /// 建 session 不 trap，下限字节 = 上限 × 1 MiB。启动参数同一条路。
    func testN04_hugeMinimumFreeFromDefaultsClampsAndSessionBuilds() throws {
        _ = try AppTest.runningSession()
        let suite = "com.plusmix.tests.w5r-n04-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [17_592_186_044_415, 17_592_186_044_416, Int.max] {
            defaults.set(value, forKey: AppSettings.Keys.recordMinimumFreeMB)
            let loaded = AppSettings.load(arguments: [], defaults: defaults)
            XCTAssertEqual(loaded.recordMinimumFreeMB, Self.limitMB, "defaults 里的 \(value) MB 读回来钳到上限")
            let session = try SwitcherSession(show: ShowDocuments.emptyShow(name: "w5r-n04"), settings: Self.isolatedSettings(loaded),
                                              hotkeyTable: .init(bindings: []), midiTable: .init(mappings: []))
            XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576, "\(value) MB：建 session 不 trap，字节 = 上限 × 1 MiB")
        }
        let cli = AppSettings.load(arguments: ["--record-min-free-mb", "\(Int.max)"], defaults: defaults)
        XCTAssertEqual(cli.recordMinimumFreeMB, Self.limitMB, "--record-min-free-mb 同样钳")
        defaults.set(-5, forKey: AppSettings.Keys.recordMinimumFreeMB)
        XCTAssertEqual(AppSettings.load(arguments: [], defaults: defaults).recordMinimumFreeMB, 0, "负数照旧按 0")
    }

    /// N04：设置 › 高级的数字框填 2^44（UI 的格式能解析）——失焦提交时钳到上限：框里显示钳后的值、内存 / 落盘 / 跑着的引擎都是钳后的值，不 trap。
    func testN04_settingsFieldClampsHugeValueAndShowsClampedValue() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let panels = controller.panels
        let original = controller.settings
        defer {
            panels.closeAll()
            controller.updateSettings(original)
        }
        panels.showSettings(page: .advanced)
        let settingsWindow = try XCTUnwrap(panels.settingsWindow)
        let prefs = settingsWindow.model.preferences
        let window = try XCTUnwrap(settingsWindow.window)
        prefs.recordMinimumFreeMB = 4321   // 认得出是哪个框
        var found: NSTextField?
        XCTAssertTrue(AppTest.waitUntil(3) {
            found = AppTest.descendants(of: window.contentView!, as: NSTextField.self) { $0.isEditable && $0.stringValue == "4321" }.first
            return found != nil
        }, "高级页的磁盘下限框")
        let field = try XCTUnwrap(found)
        window.makeKeyAndOrderFront(nil)
        func type(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)   // 失焦 = 提交
            AppTest.pump(seconds: 0.2)
        }
        try type("17592186044416")
        XCTAssertTrue(AppTest.waitUntil(2) { prefs.recordMinimumFreeMB == Self.limitMB }, "提交的是钳后的值：\(prefs.recordMinimumFreeMB)")
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.recordMinimumFreeMB), Self.limitMB, "落盘的也是钳后的值（下次启动不再崩）")
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "框里显示钳后的值：\(field.stringValue)")
        // 已经是上限时再填超的（值没变）、填一串比 Int 还长的数字：框里照样回到钳后的值
        try type("17592186044416")
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "再填一次超的：\(field.stringValue)")
        try type("99999999999999999999999")
        XCTAssertTrue(AppTest.waitUntil(2) { field.stringValue == "\(Self.limitMB)" }, "比 Int 还长：\(field.stringValue)")
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        try type("750")
        XCTAssertTrue(AppTest.waitUntil(2) { controller.settings.recordMinimumFreeMB == 750 }, "范围里的照常")
        XCTAssertEqual(session.outputs.minimumFreeBytes, 750 * 1_048_576)
        // 模型直接写（导入 / 恢复之后的重读也走这里）同样钳
        prefs.recordMinimumFreeMB = Int.max
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
    }

    /// N04：设置导入的包里带着 Int.max MB（别的机器手改过 / 旧版本存下的）——导进来钳到上限，跑着的引擎不 trap。
    func testN04_importedSettingsPackageClampsMinimumFree() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let original = controller.settings
        let saved = SettingsTransfer.makePackage(controller: controller)
        defer { try? SettingsTransfer.apply(saved, controller: controller); controller.updateSettings(original) }
        var package = saved
        package.defaults[AppSettings.Keys.recordMinimumFreeMB] = .int(Int.max)
        try SettingsTransfer.apply(package, controller: controller)
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, Self.limitMB)
        XCTAssertEqual(controller.defaults.integer(forKey: AppSettings.Keys.recordMinimumFreeMB), Self.limitMB, "导进来落盘的是钳后的值")
        XCTAssertEqual(session.outputs.minimumFreeBytes, UInt64(Self.limitMB) * 1_048_576)
    }
}
