// W5-O（prompt 112）App 续做的用例：用例名带交付项编号（testW5O<n>_…）。各条的来由见 reports/w5-app-followups.md §1。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherExternal
@testable import Switcher

@MainActor
final class W5OFollowupTests: XCTestCase {
    // MARK: 1. 外部显示 Esc 只关、不删（S2，问题单 W4C2-w5-app-inputs-outputs-gaps-found-by-docs 第 1 条）

    /// 外部显示窗口里按 Esc = 这一路 enabled = false（窗口收起、显示器 / 来源的配置留着），与路由菜单的"关闭"同一条命令；以前是 removeOutput。
    /// 路由菜单这块屏勾在"关闭"上、来源后面写"（已关）"，再点源按原配置开回来。
    func testW5O1_escOnExternalWindowOnlyTurnsOutputOff() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有显示器") }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let displayID = ExternalDisplays.id(of: screen)
        let output = ExternalOutputMenuBuilder.makeOutput(in: session.state, displayID: displayID, displayName: screen.localizedName, source: .input(number: 2))
        session.send(.addOutput(config: output))
        defer { session.send(.removeOutput(output: output.number)) }
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] != nil }, "外部窗口应随快照出现")
        let window = try XCTUnwrap(session.aux.external.windows[output.number]?.window)

        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53))
        window.keyDown(with: esc)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(output.number)?.enabled == false }, "Esc = 关这一路（enabled = false）")
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] == nil }, "窗口跟着快照收起")
        let kept = try XCTUnwrap(session.state.output(output.number), "配置留着，不删")
        XCTAssertEqual(kept.settings, output.settings, "显示器 / 来源都还在")
        XCTAssertEqual(kept.name, output.name)

        // 路由菜单：这块屏勾在"关闭"上，来源后面写"（已关）"（与菜单里点"关闭"之后一样）
        let display = try XCTUnwrap(ExternalDisplays.all().first { $0.id == displayID })
        let menu = ExternalOutputMenuBuilder(state: session.state, displays: [display]).makeMenu()
        XCTAssertEqual(menu.items.first { $0.title == "关闭" }?.state, .on)
        let offTitle = L("externalMenu.offSuffix", OutputSource.input(number: 2).title(in: session.state))
        XCTAssertNotNil(menu.items.first { $0.title == offTitle }, menu.items.map(\.title).description)

        // 开回来 = 同一块屏、同一个来源
        session.send(.setOutputEnabled(output: output.number, on: true))
        XCTAssertTrue(AppTest.waitUntil(3) { session.aux.external.windows[output.number] != nil }, "按原配置开回来")
        XCTAssertEqual(session.aux.external.windows[output.number]?.spec.source, .input(number: 2))
    }

    /// 设置 › 外部显示 每路底下的按钮做的是删除：字写"删除这一路"（与录制页同字、与路由菜单"删除 n …"同口径，都不问）；只关用这一节顶上的"启用"开关。
    /// 原来写"关闭这路"，字面像关掉、实际删了（W4-C2 查出）。
    func testW5O1_externalSettingsButtonSaysDelete() throws {
        XCTAssertEqual(L("outputSettings.external.remove"), "删除这一路")
        XCTAssertEqual(L10n.string("outputSettings.external.remove", language: "en"), "Remove This Output")
        for language in L10n.supportedLanguages {
            let table = try XCTUnwrap(L10n.table(language: language))
            XCTAssertNil(table["outputSettings.external.close"], "\(language)：字面像关掉、实际删除的老键不留")
        }
        XCTAssertEqual(L("outputSettings.external.enabled"), "启用（关掉 = 收起窗口，设置留着）", "只关用这个开关")
    }

    // MARK: 2. 设置页只写自己改的键：启动参数不顺手存成本机设置（S2，问题单 W4C2-w5-app-settings-gaps-found-by-docs 第 2 条）

    /// 带 --no-api / --api-token / --audio-device / --record-min-free-mb / --record-fallback / --tally-port 起（内存里的设置 = AppSettings.load(参数, 本机存的)），
    /// 在常规 / 音频设备 / 远程控制 / 高级 / Tally 页各改一项：存下来的只多了改的那一项，apiEnabled 仍是本机存的"开"，令牌 / 设备 / 下限 / 备用目录 / tally 端口都没写；
    /// 这一次运行里启动参数照样生效（内存里 API 仍关着）。
    func testW5O2_settingsPagesDoNotPersistLaunchArguments() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let defaults = controller.defaults
        typealias K = AppSettings.Keys
        let keys = [K.audioDevice, K.apiEnabled, K.apiListen, K.apiToken, K.recordFallbackDirectory, K.recordMinimumFreeMB, K.compatLayerEnabled,
                    K.compatLayerPort, K.compatLayerHost, K.compatLayerHTTPPort, K.overlaysInPreview, K.externalBehindInterface, K.confirmBeforeStop,
                    K.busOutputMap, K.borrowMasterForMonitor, K.tallyEnabled, K.tallyPort]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let savedSettings = controller.settings
        addTeardownBlock { @MainActor in
            AppTest.controller.panels.closeAll()
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            AppTest.controller.settings = savedSettings
        }
        // 本机存的：API 开着、监听 127.0.0.1:8765，别的都没存（= 默认）
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: K.apiEnabled)
        defaults.set("127.0.0.1:8765", forKey: K.apiListen)
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5o-fallback").path
        let launched = AppSettings.load(arguments: ["PlusMix", "--no-api", "--api-token", "from-command-line", "--audio-device", "null",
                                                    "--record-min-free-mb", "999", "--record-fallback", fallback, "--tally-port", "9911"], defaults: defaults)
        XCTAssertFalse(launched.apiEnabled)
        XCTAssertTrue(launched.tallyEnabled, "--tally-port 给了就开")
        controller.settings = launched
        func storedKeys() -> Set<String> { Set(keys.filter { defaults.object(forKey: $0) != nil }) }
        XCTAssertEqual(storedKeys(), [K.apiEnabled, K.apiListen])

        controller.panels.showSettings(page: .general)
        let prefs = try XCTUnwrap(controller.panels.settingsWindow).model.preferences
        // 常规：操作确认
        prefs.confirmBeforeStop = false
        XCTAssertEqual(defaults.object(forKey: K.confirmBeforeStop) as? Bool, false, "改的那一项存下")
        XCTAssertEqual(storedKeys(), [K.apiEnabled, K.apiListen, K.confirmBeforeStop], "常规页只写自己改的键")
        // 音频设备：Bus A 送 1/2（只改声道对）
        prefs.audioOutput.setPair(.busA, first: 0)
        XCTAssertTrue(AppTest.waitUntil(2) { defaults.data(forKey: K.busOutputMap) != nil }, "声道对存下")
        XCTAssertNil(defaults.object(forKey: K.audioDevice), "--audio-device 没被顺手存下")
        // 远程控制：兼容层 HTTP 端口
        prefs.compatLayerHTTPPort = 18_089
        XCTAssertEqual(defaults.integer(forKey: K.compatLayerHTTPPort), 18_089)
        // 高级：兼容层监听地址（只改了端口：host 没变就不写）
        prefs.compatListenText = "127.0.0.1:18100"
        XCTAssertEqual(defaults.integer(forKey: K.compatLayerPort), 18_100)
        XCTAssertNil(defaults.object(forKey: K.compatLayerHost), "没改的 host 不写")
        // Tally：关掉（--tally-port 带进来的端口不跟着存）
        prefs.tally.enabled = false
        XCTAssertEqual(defaults.object(forKey: K.tallyEnabled) as? Bool, false)

        XCTAssertEqual(storedKeys(), [K.apiEnabled, K.apiListen, K.confirmBeforeStop, K.busOutputMap, K.compatLayerHTTPPort, K.compatLayerPort,
                                      K.tallyEnabled], "每页只写自己改的键")
        XCTAssertEqual(defaults.object(forKey: K.apiEnabled) as? Bool, true, "--no-api 没被存成本机设置")
        XCTAssertNil(defaults.object(forKey: K.apiToken), "--api-token 没被存下")
        XCTAssertNil(defaults.object(forKey: K.recordMinimumFreeMB), "--record-min-free-mb 没被存下")
        XCTAssertNil(defaults.object(forKey: K.recordFallbackDirectory), "--record-fallback 没被存下")
        XCTAssertNil(defaults.object(forKey: K.tallyPort), "--tally-port 没被存下")
        XCTAssertEqual(AppSettings.load(arguments: [], defaults: defaults).apiEnabled, true, "下次不带参数起：API 照本机设置开着")
        // 这一次运行里启动参数照样生效
        XCTAssertFalse(controller.settings.apiEnabled)
        XCTAssertEqual(controller.settings.apiToken, "from-command-line")
        XCTAssertEqual(controller.settings.recordMinimumFreeMB, 999)
        XCTAssertEqual(controller.settings.recordFallbackDirectory, fallback)
    }

    /// AppSettings.save(to:changedFrom:)：只写与内存里那份不同的键；监听地址 host:port 是一个键，只变了一半时另一半按本机存的（--api-listen 带进来的那一半不存）。
    func testW5O2_saveChangedKeysKeepsStoredHalfOfListenAddress() throws {
        let suite = "com.plusmix.switcher.tests.w5o-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("127.0.0.1:8765", forKey: AppSettings.Keys.apiListen)
        let launched = AppSettings.load(arguments: ["--api-listen", "127.0.0.1:9900", "--tally-port", "9911"], defaults: defaults)
        XCTAssertEqual(launched.apiPort, 9900)
        var lan = launched
        lan.apiHost = "0.0.0.0"   // 远程控制页"允许局域网"
        lan.save(to: defaults, changedFrom: launched)
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:8765", "端口那一半来自 --api-listen，不存")
        XCTAssertNil(defaults.object(forKey: AppSettings.Keys.apiEnabled))
        XCTAssertNil(defaults.object(forKey: AppSettings.Keys.tallyPort))
        var port = lan
        port.apiPort = 9_000
        port.save(to: defaults, changedFrom: lan)
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:9000", "改了端口就存端口")
        var tallyOff = launched
        tallyOff.tallyEnabled = false
        tallyOff.save(to: defaults, changedFrom: launched)
        XCTAssertEqual(defaults.object(forKey: AppSettings.Keys.tallyEnabled) as? Bool, false)
        XCTAssertNil(defaults.object(forKey: AppSettings.Keys.tallyPort), "--tally-port 的端口不跟着存")
        // 安全闸（W5-O 安全复核）：带 --api-token 起、在远程控制页改"允许局域网"——页上因为内存里有令牌不提醒；只存地址不存令牌的话，
        // 下次不带参数起就成了局域网上没令牌的 API。存下来的会是"开着 + 非本机 + 没令牌"时，令牌跟着存
        let tokenSuite = suite + ".token"
        let tokenDefaults = try XCTUnwrap(UserDefaults(suiteName: tokenSuite))
        defer { tokenDefaults.removePersistentDomain(forName: tokenSuite) }
        let withToken = AppSettings.load(arguments: ["--api-token", "from-command-line"], defaults: tokenDefaults)
        var unrelated = withToken
        unrelated.confirmBeforeStop = false
        unrelated.save(to: tokenDefaults, changedFrom: withToken)
        XCTAssertNil(tokenDefaults.object(forKey: AppSettings.Keys.apiToken), "改别的项：令牌照旧不存")
        var widened = withToken
        widened.apiHost = "0.0.0.0"
        widened.save(to: tokenDefaults, changedFrom: withToken)
        XCTAssertEqual(tokenDefaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:8765")
        XCTAssertEqual(tokenDefaults.string(forKey: AppSettings.Keys.apiToken), "from-command-line", "放开到局域网时令牌一起存，不留没鉴权的口子")
        let reloaded = AppSettings.load(arguments: [], defaults: tokenDefaults)
        XCTAssertEqual(reloaded.apiConfiguration?.host, "0.0.0.0")
        XCTAssertEqual(reloaded.apiConfiguration?.token, "from-command-line", "下次不带参数起：局域网 + 令牌")
        // 整份写回（导入 / 恢复默认后重读、用例还原）照旧写全部
        let all = UserDefaults(suiteName: suite + ".all")!
        defer { all.removePersistentDomain(forName: suite + ".all") }
        launched.save(to: all)
        XCTAssertEqual(all.object(forKey: AppSettings.Keys.tallyPort) as? Int, 9911)
        XCTAssertEqual(all.string(forKey: AppSettings.Keys.apiListen), "127.0.0.1:9900")
    }
}
