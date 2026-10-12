// W5-O（prompt 112）App 续做的用例：用例名带交付项编号（testW5O<n>_…）。各条的来由见 reports/w5-app-followups.md §1。
import AppKit
import XCTest
import SwitcherAudio
import SwitcherContracts
import SwitcherEngine
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
    /// 与 dynamicsProcessor 二选一占同一格（链里不会两个都在）；"延迟自测"一行读引擎冲激法量到的 compressorMeasuredLatencyFrames（调音台同一份 50 ms 状态）；
    /// 限幅页"天花板"写 peakLimiter.ceilingDb（−20…0）。总线与每路都能装。
    func testW5O6_compressorPageSimpleModeAndLimiterCeiling() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let meters = AppTest.controller.windowController.mixerPanel.meters
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
        // 延迟自测：引擎装上压缩器后冲激法量一次（按设计 0 帧）
        XCTAssertTrue(AppTest.waitUntil(5) { meters.busCompressorLatencyFrames[.master] != nil }, "引擎状态里应有实测延迟")
        XCTAssertEqual(meters.busCompressorLatencyFrames[.master], 0, "前瞻 0：按设计 0 帧")
        XCTAssertEqual(m.compressorLatencyText(meters), L("audioSettings.compressor.latency", 0, 0.0))
        // 二选一：换成苹果动态处理器 → 链里只剩 dynamicsProcessor（开关带过去）；再换回来
        m.setCompressorKind(.dynamicsProcessor)
        XCTAssertTrue(AppTest.waitUntil(3) { ids() == [AudioEffectParams.dynamicsProcessorID] }, "\(ids())")
        XCTAssertTrue(m.compressorEnabled)
        XCTAssertNil(m.compressorLatencyText(meters), "动态处理器是 AU、延迟进总线延迟：这一行只给自写压缩器")
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
        XCTAssertTrue(AppTest.waitUntil(5) { meters.inputCompressorLatencyFrames[1] != nil }, "每路的实测延迟也读得到")
        XCTAssertEqual(wi.model.compressorLatencyText(meters), L("audioSettings.compressor.latency", 0, 0.0))
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
}
