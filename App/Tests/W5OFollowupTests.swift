// W5-O（prompt 112）App 续做的用例：用例名带交付项编号（testW5O<n>_…）。各条的来由见 reports/w5-app-followups.md §1。
import AppKit
import XCTest
import SwitcherAudio
import SwitcherContracts
import SwitcherControl
import SwitcherEngine
import SwitcherExternal
import SwitcherNDI
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
            AppTest.pump(seconds: 0.1)   // 音频设备模型的提交是异步的：落地之后再还原
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
        let suite = "com.plusmix.switcher.tests.w5o-scratch"   // 固定名字、用前用后都清（UUID 名会在 ~/Library/Preferences 留一堆小 plist）
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
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
        // 本机从没存过监听地址（键不在 = 默认 127.0.0.1:8765）：带 --api-listen 0.0.0.0:9000 起、只改端口 → 存的 host 是默认的本机，不是启动参数的局域网
        let freshSuite = suite + ".fresh"
        let fresh = try XCTUnwrap(UserDefaults(suiteName: freshSuite))
        fresh.removePersistentDomain(forName: freshSuite)
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let lanArgs = AppSettings.load(arguments: ["--api-listen", "0.0.0.0:9000"], defaults: fresh)
        var newPort = lanArgs
        newPort.apiPort = 9_100
        newPort.save(to: fresh, changedFrom: lanArgs)
        XCTAssertEqual(fresh.string(forKey: AppSettings.Keys.apiListen), "127.0.0.1:9100", "没存过 = 默认本机；--api-listen 的局域网那一半不存")
        var tallyOff = launched
        tallyOff.tallyEnabled = false
        tallyOff.save(to: defaults, changedFrom: launched)
        XCTAssertEqual(defaults.object(forKey: AppSettings.Keys.tallyEnabled) as? Bool, false)
        XCTAssertNil(defaults.object(forKey: AppSettings.Keys.tallyPort), "--tally-port 的端口不跟着存")
        // 安全闸（W5-O 安全复核）：带 --api-token 起、在远程控制页改"允许局域网"——页上因为内存里有令牌不提醒；只存地址不存令牌的话，
        // 下次不带参数起就成了局域网上没令牌的 API。存下来的会是"开着 + 非本机 + 没令牌"时，令牌跟着存
        let tokenSuite = suite + ".token"
        let tokenDefaults = try XCTUnwrap(UserDefaults(suiteName: tokenSuite))
        tokenDefaults.removePersistentDomain(forName: tokenSuite)
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
        let all = try XCTUnwrap(UserDefaults(suiteName: suite + ".all"))
        all.removePersistentDomain(forName: suite + ".all")
        defer { all.removePersistentDomain(forName: suite + ".all") }
        launched.save(to: all)
        XCTAssertEqual(all.object(forKey: AppSettings.Keys.tallyPort) as? Int, 9911)
        XCTAssertEqual(all.string(forKey: AppSettings.Keys.apiListen), "127.0.0.1:9900")
    }

    // MARK: 5. 分类颜色切到 InputConfig.color（提案 023 四的 App 侧；名字留 Show.layout）

    /// 格子右键"分类 ▸"发 setInputColor（颜色进 InputConfig.color，API 全量状态里看得到），layout 里不再有 "inputCategories"；
    /// 别的客户端（API / 脚本）改的颜色格子跟着快照变；分类名字仍存 layout "inputCategoryNames"。
    func testW5O5_categoryColorLivesInInputConfig() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        AppTest.pump(seconds: 0.1)
        let strip = AppTest.controller.windowController.inputStrip
        func pick(_ number: Int, _ title: String) throws {
            let cell = try XCTUnwrap(strip.cells[number])
            let submenu = try XCTUnwrap(cell.contextMenu().items.first { $0.title == "分类" }?.submenu)
            let item = try XCTUnwrap(submenu.items.first { $0.title == title })
            _ = item.target?.perform(item.action, with: item)
        }
        try pick(1, "红色")
        try pick(2, "蓝色")
        XCTAssertEqual(strip.cells[1]?.categoryColor, .red, "格子马上有色点（不等快照）")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.color == .red && session.state.input(2)?.color == .blue },
                      "颜色走 setInputColor 进 InputConfig.color：\(session.state.inputs.map(\.color))")
        XCTAssertNil(session.state.input(3)?.color)
        XCTAssertNil(session.layout.values[InputConfig.legacyCategoriesLayoutKey], "layout 里不再存分类")
        XCTAssertTrue(AppTest.waitUntil(2) { AppTest.controller.isDocumentEdited }, "改分类算未保存的改动")
        // API 全量状态里看得到（多画面 / Stream Deck / 脚本都读这一份）
        let port = try XCTUnwrap(session.control.apiServer?.boundPort)
        let reply = try AppTest.http("GET", "http://127.0.0.1:\(port)/api/v1/state" + AppTest.tokenQuery(session))
        let state = try XCTUnwrap(reply.json?["state"] as? [String: Any], reply.text)
        let inputs = try XCTUnwrap(state["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.first { $0["number"] as? Int == 1 }?["color"] as? String, "red")
        XCTAssertNil(inputs.first { $0["number"] as? Int == 3 }?["color"], "没分类不写键")
        // 别的客户端改的：格子跟着快照
        session.send(.setInputColor(input: 3, color: .green))
        XCTAssertTrue(AppTest.waitUntil(2) { strip.cells[3]?.categoryColor == .green }, "外部改的颜色格子跟上")
        try pick(1, "无")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.color == nil && strip.cells[1]?.categoryColor == nil }, "无 = 清掉")
        // 名字留在 layout
        AppTest.controller.windowController.renameCategory(.blue, to: "嘉宾")
        XCTAssertEqual(session.layout.values[InputCategories.Keys.names], .object(["blue": .string("嘉宾")]))
        XCTAssertEqual(strip.categoryBar.button(for: .blue).title, "嘉宾")
        // 删掉一路：颜色跟着这一路的配置没了，编号再给别的输入用不继承
        session.send(.removeInput(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(2) == nil })
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(2) != nil })
        AppTest.pump(seconds: 0.1)
        XCTAssertNil(session.state.input(2)?.color)
        XCTAssertNil(strip.cells[2]?.categoryColor, "新的一路 2 没分类")
    }

    /// 老节目（W5-H 存在 layout "inputCategories" 里）打开时搬一次：读文件、读 LastSession 两处都走 ShowDocuments.prepared → Show.migratingLegacyInputCategories()；
    /// 搬完 layout 里没有那个键，名字键留着；认不出的颜色 / 不存在的编号跳过；刚打开不算未保存。
    func testW5O5_legacyLayoutCategoriesMigrateOnLoad() throws {
        _ = try AppTest.freshSession()
        var legacy = ShowDocuments.emptyShow(recordDirectory: FileManager.default.temporaryDirectory.path)
        for n in 1...3 { legacy.inputs.append(AppTest.syntheticConfig(number: n)) }
        legacy.layout = ShowLayout(values: [
            InputConfig.legacyCategoriesLayoutKey: .object(["1": .string("red"), "3": .string("purple"), "2": .string("nope"), "9": .string("green")]),
            InputCategories.Keys.names: .object(["red": .string("机位")]),
        ])
        // 读 LastSession（另一个 ShowDocuments，不碰测试宿主共用的那一份）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/w5o-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = ShowDocuments(defaults: AppTest.controller.defaults, recordDirectory: dir.path, autosaveURL: dir.appendingPathComponent("LastSession.switcher.json"))
        docs.autosave(legacy)
        let restored = try XCTUnwrap(docs.loadAutosave())
        XCTAssertEqual(restored.inputs.map(\.color), [.red, nil, .purple], "LastSession 读进来就搬")
        XCTAssertNil(restored.layout.values[InputConfig.legacyCategoriesLayoutKey])
        XCTAssertEqual(restored.layout.values[InputCategories.Keys.names], .object(["red": .string("机位")]), "名字键留着")
        // 读文件（打开节目）：走 App 的整条路
        let url = dir.appendingPathComponent("分类老节目.switcher.json")
        try ShowStore().save(legacy, to: url)
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.openShow(url: url); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { done.value && AppTest.controller.session?.isRunning == true })
        let session = try XCTUnwrap(AppTest.controller.session)
        XCTAssertEqual(session.state.inputs.map(\.color), [.red, nil, .purple])
        XCTAssertNil(session.layout.values[InputConfig.legacyCategoriesLayoutKey])
        let strip = AppTest.controller.windowController.inputStrip
        XCTAssertTrue(AppTest.waitUntil(2) { strip.cells[1]?.categoryColor == .red && strip.cells[3]?.categoryColor == .purple })
        XCTAssertNil(strip.cells[2]?.categoryColor)
        XCTAssertEqual(strip.categoryBar.button(for: .red).title, "机位")
        XCTAssertFalse(AppTest.controller.isDocumentEdited, "打开时搬迁不算改动")
    }

    // MARK: 6. 压缩器简单模式界面（提案 024 (b)；问题单 W1D3-app-monitor-source-and-input-effects-wiring 第 4 条）

    /// 音频设置窗压缩页：新开默认装自写压缩器 compressor（阈值 / 比例 / 拐点 / 起音 / 释放 / 补偿，范围 = 引擎的 EffectParameterRanges["compressor"]），
    /// 与 dynamicsProcessor 二选一占同一格（链里不会两个都在）；"延迟自测"一行读引擎冲激法量到的延迟（W5-Q 起读 Stats 的 audio.effects，提案 030）；
    /// 限幅页"天花板"写 peakLimiter.ceilingDb（−20…0）。总线与每路都能装。
    func testW5O6_compressorPageSimpleModeAndLimiterCeiling() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = try XCTUnwrap(panels.showAudioSettings(.bus(.master), page: .compressor))
        let m = w.model
        func master() -> [EffectSlot] { session.state.audio.buses[0].effects }
        func ids() -> [String] { master().map(\.id) }

        // 范围就是引擎的（不再是界面自己收窄的一段）
        let engine = try XCTUnwrap(EffectParameterRanges.table["compressor"])
        XCTAssertEqual(EffectEditorRanges.compThresholdDb, engine["thresholdDb"])
        XCTAssertEqual(EffectEditorRanges.compRatio, engine["ratio"])
        XCTAssertEqual(EffectEditorRanges.compKneeDb, engine["kneeDb"])
        XCTAssertEqual(EffectEditorRanges.compAttackSeconds, engine["attackSeconds"])
        XCTAssertEqual(EffectEditorRanges.compReleaseSeconds, engine["releaseSeconds"])
        XCTAssertEqual(EffectEditorRanges.compMakeupGainDb, engine["makeupGainDb"])
        XCTAssertEqual(EffectEditorRanges.limCeilingDb, EffectParameterRanges.range(effect: "peakLimiter", key: "ceilingDb"))
        XCTAssertEqual(EffectEditorRanges.limCeilingDb, -20...0)

        // 启用：默认装 compressor（契约默认参数）
        XCTAssertEqual(m.compressorKind, .compressor, "没装时显示默认的压缩器")
        m.setCompressorEnabled(true)
        XCTAssertTrue(AppTest.waitUntil(3) { ids() == [AudioEffectParams.compressorID] }, "\(ids())")
        let slot = try XCTUnwrap(master().first)
        XCTAssertTrue(slot.enabled)
        XCTAssertEqual(AudioEffectParams.number(slot, "thresholdDb"), -20)
        XCTAssertEqual(AudioEffectParams.number(slot, "ratio"), 4)
        XCTAssertEqual(AudioEffectParams.number(slot, "kneeDb"), 6)
        XCTAssertEqual(AudioEffectParams.number(slot, "attackSeconds"), 0.005)
        XCTAssertEqual(AudioEffectParams.number(slot, "releaseSeconds"), 0.1)
        XCTAssertEqual(AudioEffectParams.number(slot, "makeupGainDb"), 0)
        m.binding(\.compressor.ratio).wrappedValue = 8
        m.binding(\.compressor.thresholdDb).wrappedValue = -30
        m.binding(\.compressor.makeupGainDb).wrappedValue = 3
        XCTAssertTrue(AppTest.waitUntil(3) {
            let s = master().first
            return s.flatMap { AudioEffectParams.number($0, "ratio") } == 8 && s.flatMap { AudioEffectParams.number($0, "thresholdDb") } == -30
                && s.flatMap { AudioEffectParams.number($0, "makeupGainDb") } == 3
        }, "\(master())")
        // 延迟自测：引擎装上压缩器后冲激法量一次（按设计 0 帧）；W5-Q 起读 Stats 的 audio.effects（1 Hz，与 stats.jsonl / API 同一份）
        func masterMeasured() -> Double? { session.stats?.audio.effects.buses.first { $0.bus == Bus.master.name }?.measuredLatencyMs }
        XCTAssertTrue(AppTest.waitUntil(5) { masterMeasured() != nil }, "Stats 里应有实测延迟")
        XCTAssertEqual(masterMeasured(), 0, "前瞻 0：按设计 0 帧")
        XCTAssertTrue(AppTest.waitUntil(3) { m.compressorSelfTestText == L("audioSettings.compressor.latency", 0, 0.0) }, "\(String(describing: m.compressorSelfTestText))")
        // 二选一：换成苹果动态处理器 → 链里只剩 dynamicsProcessor（开关带过去）；再换回来
        m.setCompressorKind(.dynamicsProcessor)
        XCTAssertTrue(AppTest.waitUntil(3) { ids() == [AudioEffectParams.dynamicsProcessorID] }, "\(ids())")
        XCTAssertTrue(m.compressorEnabled)
        XCTAssertNil(m.compressorSelfTestText, "动态处理器是 AU、延迟进总线延迟：这一行只给自写压缩器")
        m.setCompressorKind(.compressor)
        XCTAssertTrue(AppTest.waitUntil(3) { ids() == [AudioEffectParams.compressorID] }, "\(ids())")
        // 复位：参数回默认，开关不动
        m.binding(\.compressor.kneeDb).wrappedValue = 12
        m.resetCompressor()
        XCTAssertTrue(AppTest.waitUntil(3) { master().first.flatMap { AudioEffectParams.number($0, "kneeDb") } == 6 })
        XCTAssertTrue(m.compressorEnabled, "复位不动开关")

        // 限幅页：天花板写 ceilingDb
        m.page = .limiter
        m.setLimiterEnabled(true)
        m.binding(\.limiter.ceilingDb).wrappedValue = -1.5
        XCTAssertTrue(AppTest.waitUntil(3) {
            master().first { $0.id == AudioEffectParams.peakLimiterID }.flatMap { AudioEffectParams.number($0, "ceilingDb") } == -1.5
        }, "\(master())")
        XCTAssertEqual(ids(), [AudioEffectParams.compressorID, AudioEffectParams.peakLimiterID], "顺序 = 动态格 → 限幅格")

        // 每路也能装（每路两格：EQ → 动态，W1-D3）
        let wi = try XCTUnwrap(panels.showAudioSettings(.input(1), page: .compressor))
        wi.model.setCompressorEnabled(true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.effects.map(\.id) == [AudioEffectParams.compressorID] })
        XCTAssertTrue(AppTest.waitUntil(5) { wi.model.compressorSelfTestText == L("audioSettings.compressor.latency", 0, 0.0) },
                      "每路的实测延迟也读得到（Stats 的 audio.effects.inputs）：\(String(describing: wi.model.compressorSelfTestText))")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 编辑器值模型：compressor 与 peakLimiter.ceilingDb 往返不丢；链里两个动态格（API 写进来的）时第一个算数、第二个原样留在"其他"（引擎也只装第一个）。
    func testW5O6_effectChainEditorRoundTripsCompressorAndCeiling() {
        let comp = AudioEffectParams.compressor(thresholdDb: -24, ratio: 6, kneeDb: 3, attackSeconds: 0.01, releaseSeconds: 0.2, makeupGainDb: 2)
        XCTAssertEqual(comp.id, "compressor")
        XCTAssertEqual(Set(comp.params.keys), ["thresholdDb", "ratio", "kneeDb", "attackSeconds", "releaseSeconds", "makeupGainDb"])
        let lim = AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0, ceilingDb: -3)
        XCTAssertEqual(AudioEffectParams.number(lim, "ceilingDb"), -3)
        XCTAssertNil(AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0).params["ceilingDb"], "天花板 0 = 默认，不写键（老链不变）")
        let eq = AudioEffectParams.parametricEQ(centerHz: 1000, q: 1, gainDb: 3)
        let editor = EffectChainEditor(slots: [eq, comp, lim])
        XCTAssertEqual(editor.dynamicsKind, .compressor)
        XCTAssertEqual(editor.compressor.ratio, 6)
        XCTAssertEqual(editor.limiter.ceilingDb, -3)
        XCTAssertEqual(editor.slots, [eq, comp, lim], "往返不丢")
        // 超范围的读进来钳进引擎范围
        let wild = EffectChainEditor(slots: [AudioEffectParams.compressor(thresholdDb: -90, ratio: 50, kneeDb: 30, attackSeconds: 0, releaseSeconds: 9, makeupGainDb: -5)])
        XCTAssertEqual(wild.compressor.thresholdDb, -60)
        XCTAssertEqual(wild.compressor.ratio, 20)
        XCTAssertEqual(wild.compressor.kneeDb, 24)
        XCTAssertEqual(wild.compressor.attackSeconds, 0.0001)
        XCTAssertEqual(wild.compressor.releaseSeconds, 3)
        XCTAssertEqual(wild.compressor.makeupGainDb, 0)
        // 两个动态格：第一个算数，第二个原样留着
        let dyn = AudioEffectParams.dynamicsProcessor(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)
        let both = EffectChainEditor(slots: [comp, dyn])
        XCTAssertEqual(both.dynamicsKind, .compressor)
        XCTAssertEqual(both.others, [dyn])
        XCTAssertEqual(both.slots, [comp, dyn])
        // 换种类：同一格二选一，开关带过去
        var e = EffectChainEditor(slots: [dyn])
        e.setDynamicsKind(.compressor)
        XCTAssertEqual(e.slots.map(\.id), ["compressor"])
        XCTAssertTrue(e.compressor.enabled)
        var off = EffectChainEditor()
        off.setDynamicsKind(.dynamicsProcessor)
        XCTAssertEqual(off.slots.map(\.id), ["dynamicsProcessor"])
        XCTAssertFalse(off.slots[0].enabled, "没启用时选种类：装一个旁路着的格，开关仍是关")
    }

    // MARK: 8. S3 一批（W4C2 两张问题单其余条 + 英文截断）

    /// 只改总线声道对也算"待应用"（声道对是建音频引擎时用的；原来只比设备，改完"应用并重起引擎"是灰的、要等下次起引擎才生效）。
    /// 借 Master 声道 G8b 起当场落到跑着的引擎（AudioEngine.borrowMasterForMonitor 任意线程可设），不算待应用。
    func testW5O8_busChannelPairChangeIsPendingRestart() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let saved = controller.settings
        addTeardownBlock { @MainActor in
            AppTest.controller.panels.closeAll()
            AppTest.pump(seconds: 0.1)   // 音频设备模型的提交是异步的：落地之后再还原
            AppTest.controller.updateSettings(saved)
        }
        controller.panels.showSettings(page: .audioDevice)
        let prefs = try XCTUnwrap(controller.panels.settingsWindow).model.preferences
        let running = session.settings.busOutputMap   // 测试宿主一般是 nil（跟设备默认）；按跑着的这份比
        XCTAssertEqual(prefs.audioOutput.storedMap, running)
        XCTAssertFalse(prefs.pendingRestart.contains(.audioDevice))
        let busB = prefs.audioOutput.map.busB
        prefs.audioOutput.setPair(.busB, first: busB == 4 ? 6 : 4)
        XCTAssertTrue(AppTest.waitUntil(2) { prefs.pendingRestart.contains(.audioDevice) }, "只改声道对：待应用（\(prefs.pendingRestart)）")
        if running == nil { prefs.audioOutput.resetToDeviceDefault() } else { prefs.audioOutput.setPair(.busB, first: running?.busB) }
        XCTAssertTrue(AppTest.waitUntil(2) { !prefs.pendingRestart.contains(.audioDevice) }, "改回跟跑着的一样：不再待应用")
        prefs.audioOutput.borrowMasterForMonitor = true
        XCTAssertTrue(AppTest.waitUntil(2) { session.audio.engine.borrowMasterForMonitor }, "借 Master 当场落到跑着的引擎")
        XCTAssertFalse(prefs.pendingRestart.contains(.audioDevice), "借 Master 不用重起引擎")
        prefs.audioOutput.borrowMasterForMonitor = false
        XCTAssertTrue(AppTest.waitUntil(2) { !session.audio.engine.borrowMasterForMonitor })
    }

    /// 导出 / 导入 / 恢复默认带上提醒（四个键）/ 电源（两个）/ Tally（两个）/ 兼容层 HTTP 端口；每条总线的声道对（Data）原来在键表里却导不出来
    /// （包的值类型认不出 Data，导入时又按"包里没有 = 默认"删了键），这里一起修。
    func testW5O8_settingsTransferCoversRemindersPowerTallyCompatPortAndBusMap() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let original = controller.settings
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5o-transfer-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppTest.dismissConfirmations()
            controller.updateSettings(original)
            try? controller.applyHotkeyTable(.default)
            try? HotkeyTable.default.save(to: controller.hotkeyFileURL)
            try? MIDIMapTable.default.save(to: controller.midiFileURL)
            try? controller.applyMIDITable(.default)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias K = AppSettings.Keys
        for key in [K.reminderNotLive, K.reminderNotLiveMinutes, K.reminderFTB, K.reminderLowAudio, K.preventSleep, K.preventDisplaySleep,
                    K.tallyEnabled, K.tallyPort, K.compatLayerHTTPPort, K.busOutputMap] {
            XCTAssertTrue(SettingsTransfer.keys.contains(key), "\(key) 在导出 / 导入 / 恢复默认的键表里")
        }
        var s = original
        s.reminders.notLiveEnabled = false
        s.reminders.notLiveMinutes = 7
        s.reminders.ftbEnabled = false
        s.reminders.lowAudioEnabled = false
        s.preventSleepWhileRunning = false
        s.preventDisplaySleepWhileRunning = false
        s.tallyEnabled = false
        s.tallyPort = 18_777
        s.compatLayerHTTPPort = 18_089
        s.busOutputMap = BusOutputMap(master: 0, busA: 2)
        controller.updateSettings(s)
        let url = dir.appendingPathComponent("设置.json")
        try SettingsTransfer.export(controller: controller, to: url)
        let package = try SettingsTransfer.Package.load(from: url)
        XCTAssertEqual(package.defaults[K.reminderNotLiveMinutes], .int(7))
        XCTAssertEqual(package.defaults[K.reminderFTB], .bool(false))
        XCTAssertEqual(package.defaults[K.preventDisplaySleep], .bool(false))
        XCTAssertEqual(package.defaults[K.tallyPort], .int(18_777))
        XCTAssertEqual(package.defaults[K.compatLayerHTTPPort], .int(18_089))
        XCTAssertNotNil(package.defaults[K.busOutputMap], "声道对导得出来")

        try SettingsTransfer.restoreDefaults(controller: controller)
        XCTAssertEqual(controller.settings.reminders, ReminderSettings(), "提醒回默认")
        XCTAssertTrue(controller.settings.preventSleepWhileRunning && controller.settings.preventDisplaySleepWhileRunning, "电源回默认")
        XCTAssertNil(controller.defaults.object(forKey: K.tallyPort), "tally 端口键清掉（测试宿主内存里一律是 0：不在局域网上听）")
        XCTAssertEqual(controller.settings.compatLayerHTTPPort, 8088)
        XCTAssertNil(controller.settings.busOutputMap)

        try SettingsTransfer.apply(try SettingsTransfer.Package.load(from: url), controller: controller)
        XCTAssertEqual(controller.settings.reminders.notLiveMinutes, 7)
        XCTAssertFalse(controller.settings.reminders.ftbEnabled)
        XCTAssertFalse(controller.settings.preventDisplaySleepWhileRunning)
        XCTAssertEqual(controller.defaults.object(forKey: K.tallyPort) as? Int, 18_777)
        XCTAssertEqual(controller.settings.compatLayerHTTPPort, 18_089)
        XCTAssertEqual(controller.settings.busOutputMap, BusOutputMap(master: 0, busA: 2), "声道对导入回来")
    }

    /// ⌃1–⌃4 对没指定输入的叠加通道用 PVW 那一路开（与转场列 / 格子一致）；PVW 也是黑场 → 状态行说一句（同转场列的提示）。
    func testW5O8_ctrlNumberOnEmptyOverlayUsesPreview() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == 2 && session.state.overlays[0].input == nil })
        let ctrl1 = try XCTUnwrap(KeyCombo("ctrl+1"))
        XCTAssertTrue(session.control.hotkeys.handle(ctrl1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.overlays[0].on && session.state.overlays[0].input == 2 }, "\(session.state.overlays[0])")
        XCTAssertTrue(session.control.hotkeys.handle(ctrl1))
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.overlays[0].on })
        // 通道 2 空、PVW 黑场：不开，状态行说一句
        session.send(.setPreview(input: MixerState.noInput))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.preview == MixerState.noInput })
        XCTAssertTrue(session.control.hotkeys.handle(try XCTUnwrap(KeyCombo("ctrl+2"))))
        XCTAssertTrue(AppTest.waitUntil(2) { session.lastNotice == L("transition.overlayNeedsPreview", 2, 2) }, "\(session.lastNotice ?? "nil")")
        XCTAssertFalse(session.state.overlays[1].on)
    }

    /// midi.json 读不出来（JSON 错 / 冲突）：退回空表并在状态行提示（同 hotkeys.json；原来静默退回空表，映射全没了也不知道为什么）。
    func testW5O8_unreadableMIDITableIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5o-midi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = AppController.loadMIDITable(from: dir.appendingPathComponent("midi.json"))
        XCTAssertEqual(missing.table, .default)
        XCTAssertNil(missing.error, "没有文件 = 空表，不提示")
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{ not json".utf8).write(to: bad)
        let broken = AppController.loadMIDITable(from: bad)
        XCTAssertEqual(broken.table, .default, "退回空表")
        let message = try XCTUnwrap(broken.error, "读不出来要提示")
        XCTAssertTrue(message.hasPrefix(L("notice.midiTableUnreadable", bad.path, "").prefix(12)), message)
        XCTAssertTrue(message.contains(bad.path), message)
        let good = dir.appendingPathComponent("good.json")
        let table = MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 40), action: .action(.overlaysOff))])
        try table.save(to: good)
        let ok = AppController.loadMIDITable(from: good)
        XCTAssertEqual(ok.table, table)
        XCTAssertNil(ok.error)
    }

    /// 无信号的格子把这一路的 lastError 作第二行（全文在悬停提示里）：原来只写"无信号"，在等什么看不出来（各输入的 lastError 界面不读）。
    func testW5O8_noSignalCellShowsInputLastError() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let strip = AppTest.controller.windowController.inputStrip
        XCTAssertTrue(AppTest.waitUntil(5) { (1...2).allSatisfy { session.inputs.runtimeState(of: $0) == .live } })
        let cell = try XCTUnwrap(strip.cells[2])
        let (realState, realDetail) = (strip.runtimeState, strip.runtimeDetail)
        // 运行表的读数换成假的：2 号无信号、带原因
        let reason = "网络上找不到 NDI 源 X（发送端没开、不在同一网段，或名字不对）"
        strip.runtimeState = { n in n == 2 ? .noSignal : .live }
        strip.runtimeDetail = { n in n == 2 ? reason : nil }
        strip.apply(state: session.state)
        XCTAssertEqual(cell.displayedStatus, L("input.noSignal") + "\n" + reason, "第二行是原因")
        XCTAssertEqual(cell.statusToolTip, reason, "全文在悬停提示")
        // 没有原因：只写无信号
        strip.runtimeDetail = { _ in nil }
        strip.apply(state: session.state)
        XCTAssertEqual(cell.displayedStatus, L("input.noSignal"))
        // 接回真的：InputRuntime 按每路输入对象的 lastError 给（合成源没有 = nil）
        strip.runtimeState = realState
        strip.runtimeDetail = realDetail
        XCTAssertNotNil(realDetail, "主窗口绑 session 时接上")
        XCTAssertNil(session.inputs.lastError(of: 1))
        guard SwitcherNDIInfo.isSDKAvailable else { return }
        session.send(.addInput(config: InputConfig(number: 3, name: "不存在的 NDI", source: .ndi(sourceName: "不存在的机器 (W5O)"))))
        XCTAssertTrue(AppTest.waitUntil(15) { (strip.cells[3]?.displayedStatus ?? "").contains("NDI 源") }, "真 NDI 输入找不到源：\(strip.cells[3]?.displayedStatus ?? "nil")")
    }

    /// NDI® 横幅照 DeckLink 那条写实：这是编译期开关（这一版没编进 SDK），装运行库也不会好——不再许诺"装好之后这一路会自己好"。
    func testW5O8_ndiBannerSaysBuildHasNoSDK() {
        XCTAssertEqual(L("addInput.banner.ndi.title"), "这一版没带 NDI® 支持")
        XCTAssertTrue(L("addInput.banner.ndi.message").contains("编译时没带 NDI® SDK"), L("addInput.banner.ndi.message"))
        XCTAssertFalse(L("addInput.banner.ndi.message").contains("自己好"))
        XCTAssertTrue(L10n.string("addInput.banner.ndi.message", language: "en").contains("without the NDI® SDK"))
        XCTAssertFalse(L10n.string("addInput.banner.ndi.message", language: "en").contains("once the runtime is installed"))
    }

    /// 英文界面中档格子（宽 200）第一行"Transition"不截断：转场 / Cut 按标题实际宽度分剩下的宽（原来等宽，"Transition"截成"Transiti…"）。
    func testW5O8_englishMediumCellTransitionTitleFits() throws {
        let previous = L10n.languageOverride
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = previous }
        let config = AppTest.syntheticConfig(number: 1)
        for size in [ThumbnailSize.medium, .large] {
            let cell = InputCellView(config: config)
            cell.setSize(width: size.width, thumbnailHeight: (size.width * 9 / 16).rounded())
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            host.addSubview(cell)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.transitionButton.title, "Transition")
            XCTAssertGreaterThanOrEqual(cell.transitionButton.frame.width + 0.5, cell.transitionButton.intrinsicContentSize.width,
                                        "\(size)：Transition 按钮 \(cell.transitionButton.frame.width) 放不下标题 \(cell.transitionButton.intrinsicContentSize.width)")
            XCTAssertGreaterThanOrEqual(cell.cutButton.frame.width + 0.5, cell.cutButton.intrinsicContentSize.width, "\(size)：Cut 也放得下")
            cell.removeFromSuperview()
        }
        // 小档（160）两颗加起来放不下：先截 Transition，Cut 保住全字（按比例硬分会把 Cut 挤成 "…"）
        let small = InputCellView(config: config)
        small.setSize(width: ThumbnailSize.small.width, thumbnailHeight: (ThumbnailSize.small.width * 9 / 16).rounded())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        host.addSubview(small)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(small.cutButton.frame.width + 0.5, small.cutButton.intrinsicContentSize.width, "小档：Cut 全字")
    }

    // MARK: 4. 没选输入的 Stinger 槽从外部执行被拒的提示（提案 029；拒收本身在 P5-3）

    /// ⌥4（出厂槽 4 = Stinger、没选输入）被拒：状态行"转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路"，转场没开始；
    /// 当前槽是这种槽时按格子上的"转场"：W5-P 起（112 留下的，用户 2026-10-17 定）不再发、不再被拒，先弹这个槽的输入选择、整条不发（PVW 不换）。
    /// 选了输入之后照常执行。
    func testW5O4_stingerSlotRefusalShowsStatusLineNotice() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        XCTAssertTrue(session.state.transition.slots[3].isStingerWithoutInput, "出厂槽 4")
        let expected = L("feedback.stingerSlotWithoutInput", 4)
        XCTAssertEqual(expected, "转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路")
        let bar = AppTest.controller.windowController.bottomBar
        XCTAssertTrue(session.control.hotkeys.handle(try XCTUnwrap(KeyCombo("alt+4"))))
        XCTAssertTrue(AppTest.waitUntil(2) { session.lastNotice == expected }, "\(session.lastNotice ?? "nil")")
        XCTAssertEqual(bar.displayedNotice, expected, "状态行")
        XCTAssertFalse(session.state.transition.isActive, "没执行")
        // 格子"转场" = 执行当前槽：当前槽选成 4 再按
        session.send(.useTransitionSlot(slot: 4, start: false))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.currentSlot == 4 })
        session.send(.setProgram(input: 1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 })
        AppTest.pump(seconds: 0.1)
        bar.showNotice("")
        let cell = try XCTUnwrap(AppTest.controller.windowController.inputStrip.cells[2])
        let panel = AppTest.controller.windowController.transitionPanel
        let previewBefore = session.state.preview
        _ = AppTest.measurePoppedMenu(open: { cell.transitionButton.performClick(nil) }, menu: { panel.activeMenu })
        XCTAssertEqual(panel.activeMenu?.items.first?.title, "转场 4 · Stinger：先选一路输入（选了才执行）", "格子转场先弹这个槽的输入选择")
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.transition.isActive)
        XCTAssertEqual(session.state.program, 1, "PGM 没换")
        XCTAssertEqual(session.state.preview, previewBefore, "整条不发：PVW 也不换")
        // 选了输入：照常执行
        var slot4 = session.state.transition.slots[3]
        slot4.stinger.input = 3
        session.send(.setTransitionSlot(slot: 4, config: slot4))
        XCTAssertTrue(AppTest.waitUntil(2) { !session.state.transition.slots[3].isStingerWithoutInput })
        XCTAssertTrue(session.control.hotkeys.handle(try XCTUnwrap(KeyCombo("alt+4"))))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.transition.isActive || session.state.program == 2 }, "选了输入：执行")
    }

    // MARK: 3. 监听菜单接 setMonitorSource（提案 026，2026-10-12 允许 headphones；问题单 W1D3-app-monitor-source-and-input-effects-wiring 第 1 条）

    /// Master 条的"监听"菜单四项都能选：Master / Bus A / Bus B / 耳机总线（= monitorSource .headphones，只听每路送耳机的那一条；不再叫"（现在）"）。
    /// 选了发 setMonitorSource，菜单的勾读快照 audio.monitorSource（API 改的也跟上），引擎的耳机出口跟着换（AudioEngineStatus.monitorSource）。
    func testW5O3_listenMenuSendsSetMonitorSourceIncludingHeadphones() throws {
        let session = try AppTest.freshSession()
        let model = AppTest.controller.windowController.mixerPanel.model
        XCTAssertTrue(MixerModel.listenToOtherBusSupported)
        XCTAssertEqual(MixerModel.listenBuses, [.master, .busA, .busB, .headphones])
        XCTAssertEqual(MixerModel.listenBuses.map(MixerModel.listenTitle), ["Master", "Bus A", "Bus B", "耳机总线"])
        XCTAssertEqual(model.listenBus, .master, "新节目默认听 Master（提案 026）")
        for bus in [Bus.busA, .busB, .headphones, .master] {
            XCTAssertTrue(model.listen(bus))
            XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.monitorSource == bus && model.listenBus == bus }, "\(bus)：\(session.state.audio.monitorSource)")
            XCTAssertTrue(AppTest.waitUntil(2) { session.audio.status.monitorSource == bus }, "引擎耳机出口跟着换：\(bus)")
        }
        // API / 脚本改的：菜单的勾跟上
        session.send(.setMonitorSource(bus: .headphones))
        XCTAssertTrue(AppTest.waitUntil(2) { model.listenBus == .headphones })
        // 再选当前那一项：不发（不在状态行冒"命令被忽略"）
        let sent = session.control.commandsSent
        XCTAssertTrue(model.listen(.headphones))
        AppTest.pump(seconds: 0.1)
        XCTAssertEqual(session.control.commandsSent, sent)
        model.listen(.master)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.monitorSource == .master })
        XCTAssertEqual(session.control.bus.counters.rejected, 0, "headphones 不再被拒（P5-3）")
    }

}
