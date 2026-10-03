// W5-L（prompt 98）：防睡眠 / App Nap（P1）、App 起只读 tally 流（P2 / X32）、远程控制页（P3 / X33）、界面内提醒（N02）、
// 统计窗（E5 / N15）、界面锁（E8 / N04）。默认值按 04 Q42–Q47、Q50。
import AppKit
import IOKit
import Metal
import XCTest
import SwitcherContracts
import SwitcherControl
import SwitcherTally
import SwitcherTestKit
@testable import Switcher

// MARK: - 1. 防睡眠 / App Nap（P1，Q47）

@MainActor
final class EngineActivityTests: XCTestCase {
    /// 引擎起 → 进程挂着两条电源断言：PreventUserIdleSystemSleep（beginActivity 的 userInitiated + latencyCritical + idleSystemSleepDisabled，
    /// App Nap 跟着不来）与 PreventUserIdleDisplaySleep（显示器休眠，单独一个开关，默认也阻止）；停引擎 → 两条都放掉。
    /// 设置"性能与电源"两个开关即时生效、互不牵连，存进本机设置。
    func testApp_engineRunningHoldsActivityAssertion() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        addTeardownBlock { @MainActor in
            AppTest.controller.updateSettings({ $0.preventSleepWhileRunning = true; $0.preventDisplaySleepWhileRunning = true }, saving: { $0.savePower(to: $1) })
            AppTest.controller.panels.closeAll()
            if AppTest.controller.session == nil { AppTest.restartEngine() }
        }
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(controller.settings.preventSleepWhileRunning, "默认开（Q47）")
        XCTAssertTrue(controller.settings.preventDisplaySleepWhileRunning, "显示器休眠默认也阻止（Q47）")
        XCTAssertEqual(EngineActivity.systemOptions, [.userInitiated, .latencyCritical, .idleSystemSleepDisabled])
        XCTAssertEqual(EngineActivity.displayOptions, [.idleDisplaySleepDisabled])
        let activity = controller.engineActivity
        let system = EngineActivity.PowerAssertion(type: "PreventUserIdleSystemSleep", name: EngineActivity.systemReason)
        let display = EngineActivity.PowerAssertion(type: "PreventUserIdleDisplaySleep", name: EngineActivity.displayReason)
        func held() -> [EngineActivity.PowerAssertion] { EngineActivity.processAssertions() }
        XCTAssertTrue(AppTest.waitUntil(2) { activity.holdsSystemActivity && activity.holdsDisplayActivity }, "引擎在跑 → 两条都拿着")
        XCTAssertTrue(held().contains(system), "系统里看得到（pmset -g assertions 同一份数据）：\(held())")
        XCTAssertTrue(held().contains(display), "\(held())")

        // 设置"性能与电源"：两个开关 + 只读机型 / GPU；即时生效
        let power = controller.panels.showPreferences().model.power
        XCTAssertTrue(power.preventSleep)
        XCTAssertTrue(power.preventDisplaySleep)
        XCTAssertGreaterThanOrEqual(power.machineRows.count, 2, "只读机型 / GPU：\(power.machineRows)")
        XCTAssertTrue(power.machineRows.contains { $0.value.contains(MTLCreateSystemDefaultDevice()?.name ?? "?") }, "GPU 那一行：\(power.machineRows)")
        // 即时生效的开关只写自己的键：内存里有启动参数带进来的值（这里用 API token 模拟 --api-token），不会顺手存成本机设置
        let beforeArgs = controller.settings
        let storedToken = controller.defaults.string(forKey: AppSettings.Keys.apiToken)
        var withArgument = beforeArgs
        withArgument.apiToken = "from-command-line"
        controller.settings = withArgument
        power.preventDisplaySleep = false
        XCTAssertTrue(AppTest.waitUntil(2) { !held().contains(display) }, "关掉显示器那个开关 → 只放显示器那一条：\(held())")
        XCTAssertTrue(held().contains(system), "系统那一条不动")
        XCTAssertEqual(controller.defaults.object(forKey: AppSettings.Keys.preventDisplaySleep) as? Bool, false, "存进本机设置")
        XCTAssertEqual(controller.defaults.string(forKey: AppSettings.Keys.apiToken), storedToken, "启动参数带进来的值没被顺手写进本机设置")
        controller.settings = beforeArgs
        power.preventDisplaySleep = true
        XCTAssertTrue(AppTest.waitUntil(2) { held().contains(display) })
        power.preventSleep = false
        XCTAssertTrue(AppTest.waitUntil(2) { !held().contains(system) && !activity.holdsSystemActivity }, "\(held())")
        XCTAssertTrue(held().contains(display), "显示器那一条是另一个开关")
        power.preventSleep = true
        XCTAssertTrue(AppTest.waitUntil(2) { held().contains(system) && activity.holdsSystemActivity })

        // 停引擎 → 两条都放掉；再起 → 又拿上
        AppTest.stopEngine()
        XCTAssertNil(controller.session)
        XCTAssertFalse(activity.holdsSystemActivity, "停引擎 → endActivity")
        XCTAssertFalse(activity.holdsDisplayActivity)
        XCTAssertFalse(held().contains(system), "停了就不再阻止睡眠：\(held())")
        XCTAssertFalse(held().contains(display), "\(held())")
        AppTest.restartEngine()
        XCTAssertTrue(AppTest.waitUntil(3) { held().contains(system) && held().contains(display) }, "新引擎起来又拿上：\(held())")
    }
}

// MARK: - 2. 只读 tally 流（P2 / X32，Q46）

@MainActor
final class TallyAppTests: XCTestCase {
    /// 设置 › Tally 开关打开 → App 起 TallyServer（与 headless 同一套接法）：ws://<地址>:<端口>/tally 收到 hello + 当前 tally 帧、之后每次变化一帧，
    /// GET /tally 轮询；页上两行只读地址就是真在听的那个、连接数跟着变；换节目时旧的按 tally → API → 引擎停、新的照开关再起；关掉 → 端口不再监听。
    func testTally_appServesReadOnlyStream() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        addTeardownBlock { @MainActor in
            AppTest.controller.updateSettings({ $0.tallyEnabled = false; $0.tallyPort = nil }, saving: { $0.saveTally(to: $1) })
            AppTest.controller.panels.closeAll()
        }
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })

        // 默认：关；端口 = API 端口 + 1（8766）；打开 = 听局域网
        XCTAssertFalse(AppSettings().tallyEnabled, "默认关（Q46）")
        XCTAssertNil(AppSettings().tallyConfiguration)
        var defaultOn = AppSettings()
        defaultOn.tallyEnabled = true
        XCTAssertEqual(defaultOn.tallyConfiguration?.port, TallyServerConfiguration.defaultPort, "默认端口 = API 端口 + 1")
        XCTAssertEqual(defaultOn.tallyConfiguration?.host, "0.0.0.0", "打开即听局域网（docs/integrations/tally.md）")
        defaultOn.apiPort = 9000
        XCTAssertEqual(defaultOn.effectiveTallyPort, 9001, "没单独设端口就跟着 API 端口 + 1")
        XCTAssertFalse(controller.settings.tallyEnabled)
        XCTAssertNil(session.control.tallyServer, "关着不起")

        let page = controller.panels.showPreferences().model.tally
        XCTAssertFalse(page.enabled)
        page.enabled = true
        XCTAssertTrue(AppTest.waitUntil(5) { session.control.tallyServer?.boundPort != nil }, "打开 → 起 TallyServer：\(session.control.tallyError ?? "无错误")")
        let port = try XCTUnwrap(session.control.tallyServer?.boundPort)
        XCTAssertEqual(session.control.tallyServer?.configuration.host, "127.0.0.1", "测试宿主只听本机（防火墙会弹框；正式 App 听 0.0.0.0）")
        XCTAssertEqual(controller.defaults.object(forKey: AppSettings.Keys.tallyEnabled) as? Bool, true, "开关存进本机设置")
        // 只读地址两行：就是真在听的那个
        XCTAssertTrue(AppTest.waitUntil(3) { page.wsAddress == "ws://127.0.0.1:\(port)/tally" }, page.wsAddress)
        XCTAssertEqual(page.httpAddress, "http://127.0.0.1:\(port)/tally")

        // WS：hello → 当前帧（PGM 1 / PVW 2）→ 变化帧
        let ws = WebSocketProbe(url: try XCTUnwrap(URL(string: page.wsAddress)))
        defer { ws.close() }
        XCTAssertTrue(AppTest.waitUntil(5) { ws.texts.count >= 2 || ws.error != nil }, "\(ws.texts) \(String(describing: ws.error))")
        XCTAssertGreaterThanOrEqual(ws.texts.count, 2)
        let hello = try XCTUnwrap(AppTest.jsonObject(ws.texts[0]))
        XCTAssertEqual(hello["type"] as? String, "hello")
        let frame = try XCTUnwrap(AppTest.jsonObject(ws.texts[1]))
        XCTAssertEqual(frame["type"] as? String, "tally")
        XCTAssertEqual(frame["program"] as? Int, 1)
        XCTAssertEqual(frame["preview"] as? Int, 2)
        XCTAssertTrue(AppTest.waitUntil(3) { page.connections == 1 }, "连接数：\(page.connections)")
        session.send(.cut)
        XCTAssertTrue(AppTest.waitUntil(3) { ws.texts.dropFirst(2).contains { AppTest.jsonObject($0)?["program"] as? Int == 2 } }, "Cut 之后来一帧：\(ws.texts)")
        let poll = try AppTest.http("GET", page.httpAddress)
        XCTAssertEqual(poll.status, 200, poll.text)
        XCTAssertEqual(poll.json?["program"] as? Int, 2)
        XCTAssertEqual(session.control.bus.counters.rejected, 0)

        // 换节目：旧 session 按 tally → API → 引擎停；开关开着，新 session 照起
        let fresh = try AppTest.freshSession()
        XCTAssertTrue(fresh !== session)
        XCTAssertEqual(session.stopSequence, [.tally, .api, .engine], "停机顺序 tally → API → 引擎")
        XCTAssertFalse(AppTest.isListening(port: port), "旧的 tally 端口关了")
        XCTAssertTrue(AppTest.waitUntil(5) { fresh.control.tallyServer?.boundPort != nil }, "新节目照开关起：\(fresh.control.tallyError ?? "")")
        let port2 = try XCTUnwrap(fresh.control.tallyServer?.boundPort)
        XCTAssertTrue(AppTest.isListening(port: port2))
        XCTAssertTrue(AppTest.waitUntil(3) { page.wsAddress == "ws://127.0.0.1:\(port2)/tally" }, "页上的地址跟着新 session：\(page.wsAddress)")

        // 关掉 → 停，端口不再监听
        page.enabled = false
        XCTAssertTrue(AppTest.waitUntil(5) { fresh.control.tallyServer == nil }, "关掉 → 停")
        XCTAssertFalse(AppTest.isListening(port: port2), "关掉后端口不监听")
        XCTAssertEqual(controller.defaults.object(forKey: AppSettings.Keys.tallyEnabled) as? Bool, false)
        XCTAssertEqual(page.connections, 0)
    }
}

// MARK: - 3. 远程控制页（P3 / X33）

@MainActor
final class RemoteControlPageTests: XCTestCase {
    /// 本地 API 与兼容层各"仅本机 / 允许局域网"二选一（代替自由填地址），下面只读显示可访问地址带"复制"；允许局域网又没设 token 黄字提醒；
    /// 兼容层的 HTTP 端口可改（原来写死 127.0.0.1 / 8088）。测试宿主自己不在局域网上监听（防火墙会弹框），局域网那一档核对地址与存下来的设置。
    func testPanels_remoteControlPageShowsReachableAddress() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let defaults = controller.defaults
        let keys = [AppSettings.Keys.apiEnabled, AppSettings.Keys.apiListen, AppSettings.Keys.apiToken, AppSettings.Keys.compatLayerEnabled,
                    AppSettings.Keys.compatLayerPort, AppSettings.Keys.compatLayerHost, AppSettings.Keys.compatLayerHTTPPort]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let savedSettings = controller.settings
        addTeardownBlock { @MainActor in
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            AppTest.controller.settings = savedSettings
            AppTest.controller.panels.closeAll()
        }
        let m = controller.panels.showPreferences().model

        // 仅本机（默认）：显示的就是现在真在听的地址，照着连得上
        XCTAssertEqual(m.apiScope, .localOnly)
        let bound = try XCTUnwrap(session.control.apiServer?.boundPort, "API 应已起：\(session.control.apiError ?? "")")
        XCTAssertEqual(m.apiAddress, "http://127.0.0.1:\(bound)")
        XCTAssertEqual(try AppTest.http("GET", m.apiAddress + "/api/v1/state" + AppTest.tokenQuery(session)).status, 200, "页上的地址连得上")
        XCTAssertNil(m.apiWarning, "仅本机不提醒")

        // 允许局域网：监听 0.0.0.0，页上显示本机局域网 IP + 端口；没设 token → 黄字
        m.apiPort = 18765
        m.apiToken = ""
        m.apiScope = .lan
        XCTAssertEqual(m.apiHost, "0.0.0.0", "允许局域网 = 听 0.0.0.0")
        let lan = AppTest.lanIPv4Addresses()
        if lan.isEmpty {
            XCTAssertTrue(m.apiAddress.isEmpty, "没有局域网地址时不编一个：\(m.apiAddress)")
        } else {
            let url = try XCTUnwrap(URL(string: m.apiAddress), m.apiAddress)
            XCTAssertEqual(url.scheme, "http")
            XCTAssertTrue(lan.contains(url.host ?? ""), "\(m.apiAddress) 应是本机局域网地址之一：\(lan)")
            XCTAssertEqual(url.port, 18765)
            let all = Set(([m.apiAddress] + m.apiOtherAddresses).compactMap { URL(string: $0)?.host })
            XCTAssertEqual(all, lan, "其余局域网地址也列出来")
        }
        XCTAssertNotNil(m.apiWarning, "允许局域网又没设 token → 提醒")
        m.apiToken = "secret"
        XCTAssertNil(m.apiWarning, "设了 token 就不提醒")

        // 兼容层：同样二选一；HTTP 端口可改
        XCTAssertEqual(m.compatScope, .localOnly)
        XCTAssertEqual(m.compatLayerHTTPPort, 8088)
        m.compatLayerEnabled = true
        m.compatLayerPort = 18099
        m.compatLayerHTTPPort = 18088
        XCTAssertNil(m.compatWarning)
        m.compatScope = .lan
        XCTAssertEqual(m.compatLayerHost, "0.0.0.0")
        XCTAssertNotNil(m.compatWarning, "兼容层没有鉴权：允许局域网就提醒")
        if !lan.isEmpty {
            let http = try XCTUnwrap(URL(string: m.compatHTTPAddress), m.compatHTTPAddress)
            XCTAssertTrue(lan.contains(http.host ?? ""), m.compatHTTPAddress)
            XCTAssertEqual(http.port, 18088)
            XCTAssertEqual(http.path, "/api")
            XCTAssertTrue(m.compatTCPAddress.hasSuffix(":18099"), m.compatTCPAddress)
        }

        // 应用：写进本机设置，从设置读回的配置用上了地址与 HTTP 端口
        m.apply()
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.apiListen), "0.0.0.0:18765")
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.compatLayerHost), "0.0.0.0")
        XCTAssertEqual(defaults.integer(forKey: AppSettings.Keys.compatLayerHTTPPort), 18088)
        let loaded = AppSettings.load(arguments: [], defaults: defaults)
        XCTAssertEqual(loaded.apiConfiguration?.host, "0.0.0.0")
        XCTAssertEqual(loaded.compatConfiguration?.host, "0.0.0.0")
        XCTAssertEqual(loaded.compatConfiguration?.httpPort, 18088)
        XCTAssertEqual(loaded.compatConfiguration?.tcpPort, 18099)
        XCTAssertEqual(controller.settings.apiHost, "127.0.0.1", "测试宿主跑着的设置仍只听本机")
        XCTAssertEqual(controller.settings.compatLayerHost, "127.0.0.1")

        // 切回仅本机：地址回到 127.0.0.1，不再提醒；"复制"把那一行放进剪贴板（测试用私有剪贴板，不动用户的）
        m.compatScope = .localOnly
        XCTAssertEqual(m.compatLayerHost, "127.0.0.1")
        XCTAssertNil(m.compatWarning)
        XCTAssertEqual(m.compatHTTPAddress, "http://127.0.0.1:18088/api")
        m.apiScope = .localOnly
        XCTAssertEqual(m.apiHost, "127.0.0.1")
        XCTAssertEqual(m.apiAddress, "http://127.0.0.1:18765")
        let board = NSPasteboard(name: NSPasteboard.Name("com.plusmix.tests.w5l-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        RemoteAddressCopy.copy(m.apiAddress, to: board)
        XCTAssertEqual(board.string(forType: .string), "http://127.0.0.1:18765")
    }
}

// MARK: - 4. 界面内提醒（N02，Q50）

@MainActor
final class ReminderTests: XCTestCase {
    /// FTB 开着满 10 秒 → 主窗口状态行出提醒条（10 秒以内不提醒：正常的 FTB 进出不打扰）；PGM 标题条的 FTB 色块立刻亮。
    /// 设置里关掉这一条就不提醒；FTB 关了提醒消失。提醒只在主窗口里（不叠进多画面，不改契约）。
    func testUI_reminderShowsWhenFTBOnForTenSeconds() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        addTeardownBlock { @MainActor in
            AppTest.controller.updateSettings({ $0.reminders = ReminderSettings() }, saving: { $0.saveReminders(to: $1) })
            AppTest.controller.panels.closeAll()
        }
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 })
        XCTAssertTrue(controller.settings.reminders.ftbEnabled, "FTB 提醒默认开")
        XCTAssertFalse(controller.settings.reminders.notLiveEnabled, "没在录 / 推的提醒默认关")
        XCTAssertFalse(wc.activeReminders.contains(.ftb))
        XCTAssertFalse(wc.programMonitor.isFTBIndicatorShown)

        session.send(.ftb(on: true))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.ftb.on })
        XCTAssertTrue(AppTest.waitUntil(1) { wc.programMonitor.isFTBIndicatorShown }, "PGM 标题条的 FTB 色块立刻亮")
        XCTAssertEqual(wc.programMonitor.roleText, "PGM · FTB")
        AppTest.pump(seconds: 5)
        XCTAssertFalse(wc.activeReminders.contains(.ftb), "不到 10 秒不提醒")
        XCTAssertTrue(AppTest.waitUntil(8) { wc.activeReminders.contains(.ftb) }, "FTB 开着满 10 秒 → 提醒：\(wc.activeReminders)")
        let bar = wc.bottomBar.statusBar
        XCTAssertFalse(bar.reminderView.isHidden, "提醒条显示出来")
        XCTAssertTrue(bar.reminderText.contains("FTB"), bar.reminderText)
        XCTAssertTrue(bar.reminderView.isDescendant(of: try XCTUnwrap(wc.window?.contentView)), "提醒在主窗口里")

        // 设置里关掉这一条 → 立刻不提醒；再开回来
        let page = controller.panels.showPreferences().model.reminders
        XCTAssertTrue(page.ftbEnabled)
        page.ftbEnabled = false
        XCTAssertTrue(AppTest.waitUntil(2) { !wc.activeReminders.contains(.ftb) && bar.reminderView.isHidden }, "关掉这一条")
        XCTAssertEqual(controller.defaults.object(forKey: AppSettings.Keys.reminderFTB) as? Bool, false)
        page.ftbEnabled = true
        XCTAssertTrue(AppTest.waitUntil(2) { wc.activeReminders.contains(.ftb) })

        // FTB 关 → 提醒消失、色块灭
        session.send(.ftb(on: false))
        XCTAssertTrue(AppTest.waitUntil(4) { !wc.activeReminders.contains(.ftb) && bar.reminderView.isHidden }, "\(wc.activeReminders)")
        XCTAssertTrue(AppTest.waitUntil(2) { !wc.programMonitor.isFTBIndicatorShown })
    }

    /// 三条提醒的规则（纯逻辑，时间由调用方给）：FTB 满 10 s；Master 有声源时电平持续 30 s 低于 −50 dBFS；录制 / 推流都没开满 n 分钟（默认关）。
    func testUI_reminderTrackerRules() {
        var settings = ReminderSettings()
        var tracker = ReminderTracker()
        var state = MixerState()
        state.inputs = [AppTest.syntheticConfig(number: 1, audio: true)]
        tracker.engineStarted(at: 0)
        tracker.update(state: state, now: 0)
        func stats(masterDb: Double, inputs: [Int] = [1]) -> Stats {
            let master = Stats.AudioCounters.BusMeter(bus: "master", peakDb: [masterDb, masterDb], truePeakDb: [masterDb, masterDb],
                                                      lufsM: -120, lufsS: -120, lufsI: -120, lra: 0)
            let meters = Stats.AudioCounters.Meters(buses: [master], inputs: Dictionary(uniqueKeysWithValues: inputs.map { ($0, Stats.AudioCounters.InputMeter(peakDb: [masterDb, masterDb])) }))
            return Stats(ts: 0, tick: Tick(0), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                         audio: Stats.AudioCounters(dropouts: 0, underruns: 0, meters: meters), rssMb: 0, cpuPct: 0, gpuPct: 0)
        }
        // Master 低电平：29 s 不提醒，30 s 提醒；回到 −20 立刻消失
        for t in 0...29 { tracker.update(stats: stats(masterDb: -60), now: Double(t)) }
        XCTAssertFalse(tracker.active(now: 29, settings: settings).contains(.lowAudio))
        tracker.update(stats: stats(masterDb: -60), now: 30)
        XCTAssertTrue(tracker.active(now: 30, settings: settings).contains(.lowAudio))
        tracker.update(stats: stats(masterDb: -20), now: 31)
        XCTAssertFalse(tracker.active(now: 31, settings: settings).contains(.lowAudio))
        // 没有进 Master 的声源（纯画面节目 / 都静音 / 不送 Master）：不判低电平
        var silent = state
        silent.inputs[0].settings.audio.muted = true
        tracker.update(state: silent, now: 31)
        for t in 31...70 { tracker.update(stats: stats(masterDb: -120), now: Double(t)) }
        XCTAssertFalse(tracker.active(now: 70, settings: settings).contains(.lowAudio), "都静音了不算话筒没开")
        tracker.update(state: state, now: 70)
        for t in 70...101 { tracker.update(stats: stats(masterDb: -120, inputs: []), now: Double(t)) }
        XCTAssertFalse(tracker.active(now: 101, settings: settings).contains(.lowAudio), "没有一路带声音的输入：不判")
        for t in 101...132 { tracker.update(stats: stats(masterDb: -55), now: Double(t)) }
        XCTAssertTrue(tracker.active(now: 132, settings: settings).contains(.lowAudio))
        settings.lowAudioEnabled = false
        XCTAssertFalse(tracker.active(now: 132, settings: settings).contains(.lowAudio), "设置里关掉")

        // FTB：9.9 s 不提醒，10 s 提醒；关掉即消失
        var ftb = state
        ftb.ftb.on = true
        tracker.update(state: ftb, now: 200)
        XCTAssertFalse(tracker.active(now: 209.9, settings: settings).contains(.ftb))
        XCTAssertTrue(tracker.active(now: 210, settings: settings).contains(.ftb))
        tracker.update(state: state, now: 211)
        XCTAssertFalse(tracker.active(now: 211, settings: settings).contains(.ftb))

        // 没在录 / 推：默认关；开了之后从引擎起（或最后一路停）满 n 分钟才提醒，有一路在录 / 推就不提醒
        settings.notLiveEnabled = true
        settings.notLiveMinutes = 5
        var t2 = ReminderTracker()
        t2.engineStarted(at: 1000)
        t2.update(state: state, now: 1000)
        XCTAssertFalse(t2.active(now: 1000 + 299, settings: settings).contains(.notLive))
        XCTAssertTrue(t2.active(now: 1000 + 300, settings: settings).contains(.notLive))
        var recording = state
        recording.outputs = [OutputState(number: 1, kind: .record, name: "录制", enabled: true, settings: OutputSettings(source: .program))]
        t2.update(state: recording, now: 1400)
        XCTAssertFalse(t2.active(now: 1500, settings: settings).contains(.notLive), "在录就不提醒")
        recording.outputs[0].enabled = false
        t2.update(state: recording, now: 1600)
        XCTAssertFalse(t2.active(now: 1600 + 299, settings: settings).contains(.notLive), "从停的那一刻重新算")
        XCTAssertTrue(t2.active(now: 1600 + 300, settings: settings).contains(.notLive))
        XCTAssertFalse(t2.active(now: 1600 + 300, settings: ReminderSettings()).contains(.notLive), "默认关")
        t2.engineStopped()
        XCTAssertTrue(t2.active(now: 5000, settings: settings).isEmpty, "引擎没跑不提醒")
    }
}

// MARK: - 5. 统计窗（E5 / N15，Q42 / Q44）

@MainActor
final class StatsWindowTests: XCTestCase {
    /// 底栏"统计"开只读窗：每路输入（fps / 重复 / 丢帧 / 延迟）、渲染、每个输出（按 EncoderEntry.output 对上名字 / 类型 / 来源）、显示、音频；
    /// "重置"只在界面记基线相减：窗里从 0 起，session 的 Stats（= stats.jsonl / API 那一份）累计值照涨、不被清零。
    func testUI_statsWindowResetKeepsStatsCumulative() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        addTeardownBlock { @MainActor in AppTest.controller.panels.closeAll() }
        // 30 fps 的合成源进 60p 节目：每秒约 30 次重复帧（per_input.dup 一直在涨）
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, frameRate: .fps30)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live)
        session.send(.setProgram(input: 1))
        // 一路连不上的推流（一直在连 / 退避）：Stats.encoder 里有它那一项，按 output 对号（空节目里已有 1 号录制输出，取空号）
        let streamNumber = (session.state.outputs.map(\.number).max() ?? 0) + 1
        session.send(.addOutput(config: AppTest.streamOutput(number: streamNumber, url: AppTest.closedRTMP("w5l-stats"), name: "推流 · 测试")))
        session.send(.startStream(output: streamNumber))

        XCTAssertEqual(wc.bottomBar.statsButton.title, "统计")
        wc.bottomBar.statsButton.performClick(nil)
        let w = try XCTUnwrap(controller.panels.statsWindow, "底栏统计 → 统计窗")
        XCTAssertTrue(w.window?.isVisible == true)
        XCTAssertFalse(w.window is MainWindow)
        let model = w.model
        func dup() -> UInt64? { model.inputRows.first { $0.number == 1 }?.dup }
        XCTAssertTrue(AppTest.waitUntil(8) { (dup() ?? 0) >= 30 }, "\(model.inputRows)")
        let input = try XCTUnwrap(model.inputRows.first { $0.number == 1 })
        XCTAssertEqual(input.name, "合成 1")
        XCTAssertEqual(input.fps, 30, accuracy: 3)
        XCTAssertNotNil(model.render)
        XCTAssertTrue(model.displayRows.contains { $0.kind == "monitor" }, "显示：PGM 监视器那一项：\(model.displayRows)")
        XCTAssertNotNil(model.audio)
        XCTAssertTrue(AppTest.waitUntil(5) { model.outputRows.contains { $0.number == streamNumber } }, "推流那一路：\(model.outputRows)")
        let stream = try XCTUnwrap(model.outputRows.first { $0.number == streamNumber })
        XCTAssertEqual(stream.name, "推流 · 测试", "按 EncoderEntry.output 对上名字")
        XCTAssertEqual(stream.kind, .stream)
        XCTAssertEqual(stream.source, L("source.program"))

        // 重置：只在界面记基线
        let before = try XCTUnwrap(session.stats?.perInput[1]?.dup)
        model.reset()
        let baseline = try XCTUnwrap(model.baseline?.perInput[1]?.dup)
        XCTAssertGreaterThanOrEqual(baseline, before)
        XCTAssertEqual(dup(), 0, "重置后窗里从 0 起")
        XCTAssertTrue(AppTest.waitUntil(5) { (session.stats?.perInput[1]?.dup ?? 0) >= baseline + 30 }, "Stats 自己照涨")
        let cumulative = try XCTUnwrap(session.stats?.perInput[1]?.dup)
        XCTAssertGreaterThan(cumulative, baseline, "Stats 的累计值单调不减，重置不碰它")
        XCTAssertTrue(AppTest.waitUntil(2) { dup() == (session.stats?.perInput[1]?.dup ?? 0) - baseline }, "窗里 = 当前累计 − 基线：\(String(describing: dup()))")
        // API 读到的也是累计口径（同一份 Stats）
        let port = try XCTUnwrap(session.control.apiServer?.boundPort)
        let state = try AppTest.http("GET", "http://127.0.0.1:\(port)/api/v1/state" + AppTest.tokenQuery(session))
        let perInput = ((state.json?["stats"] as? [String: Any])?["per_input"] as? [String: Any])?["1"] as? [String: Any]
        XCTAssertGreaterThanOrEqual((perInput?["dup"] as? NSNumber)?.uint64Value ?? 0, before, "API 的 dup 没被清零：\(String(describing: perInput))")
        // 再点一次 = 同一个窗；菜单栏"窗口 › 统计"也是它（规则 5）
        wc.bottomBar.statsButton.performClick(nil)
        XCTAssertTrue(controller.panels.statsWindow === w)
        AppTest.delegate.showStatistics(nil)
        XCTAssertTrue(controller.panels.statsWindow === w)
        session.send(.stopStream(output: streamNumber))
    }

    /// 基线相减的口径（纯逻辑）：累计量减基线；速率量（fps / 码率 / 渲染 ms）原样；重置之后才出现的输入 / 输出基线按 0；
    /// 换了 session（累计量变小）就把基线清掉，不出负数。
    func testUI_statsBaselineSubtractsOnlyCumulativeFields() {
        func stats(dup: UInt64, drop: UInt64, missed: UInt64, frames: UInt64, fps: Double, extraInput: Bool = false) -> Stats {
            var perInput: [Int: Stats.PerInput] = [1: Stats.PerInput(fps: fps, dup: dup, drop: drop, latencyMs: 2, latencyMaxMs: 3)]
            if extraInput { perInput[2] = Stats.PerInput(fps: 60, dup: 7, drop: 1) }
            return Stats(ts: 0, tick: Tick(0), renderMs: 1.5, missedRender: missed, jitterMs: 0.1, perInput: perInput,
                         encoder: [Stats.EncoderEntry(output: 3, skipped: 2, bitrate: 6e6, frames: frames, dropped: 1, state: "recording")],
                         audio: Stats.AudioCounters(dropouts: 4, underruns: 5), rssMb: 100, cpuPct: 50, gpuPct: 20,
                         display: [Stats.DisplayEntry(output: 0, kind: "monitor", frames: frames, dropped: 2, undelivered: 3, state: "presenting")])
        }
        var state = MixerState()
        state.inputs = [AppTest.syntheticConfig(number: 1), AppTest.syntheticConfig(number: 2)]
        state.outputs = [OutputState(number: 3, kind: .record, name: "录制", enabled: true, settings: OutputSettings(source: .program))]
        let model = StatsWindowModel()
        model.apply(stats: stats(dup: 100, drop: 10, missed: 5, frames: 600, fps: 30), state: state)
        model.reset()
        model.apply(stats: stats(dup: 130, drop: 11, missed: 6, frames: 660, fps: 29.5, extraInput: true), state: state)
        let row = model.inputRows.first { $0.number == 1 }
        XCTAssertEqual(row?.dup, 30)
        XCTAssertEqual(row?.drop, 1)
        XCTAssertEqual(row?.fps, 29.5, "速率量不减")
        XCTAssertEqual(row?.latencyMs, 2)
        XCTAssertEqual(model.inputRows.first { $0.number == 2 }?.dup, 7, "重置之后才有的输入：基线按 0")
        XCTAssertEqual(model.render?.missedRender, 1)
        XCTAssertEqual(model.render?.renderMs, 1.5)
        XCTAssertEqual(model.outputRows.first?.frames, 60)
        XCTAssertEqual(model.outputRows.first?.skipped, 0)
        XCTAssertEqual(model.outputRows.first?.bitrate, 6e6)
        XCTAssertEqual(model.outputRows.first?.name, "录制")
        XCTAssertEqual(model.displayRows.first?.frames, 60)
        XCTAssertEqual(model.audio?.dropouts, 0)
        // 换了 session：累计量从头来（比基线小）→ 基线作废，按新的原样显示
        model.apply(stats: stats(dup: 3, drop: 0, missed: 0, frames: 20, fps: 30), state: state)
        XCTAssertEqual(model.inputRows.first { $0.number == 1 }?.dup, 3)
        XCTAssertNil(model.baseline)
    }
}

// MARK: - 6. 界面锁（E8 / N04，Q43）

@MainActor
final class InterfaceLockTests: XCTestCase {
    /// 底栏最右"锁定界面"：锁着时主窗口里的鼠标点击不生效（锁按钮本身除外；工具条也在主窗口里），快捷键 / 菜单栏 / API / MIDI 照常，
    /// 独立窗口不锁；锁着时按钮高亮，被拦时状态行说怎么解锁。合成的鼠标事件交给 MainWindow.sendEvent 看拦不拦（AppKit 不派发合成事件到视图）。
    func testUI_interfaceLockBlocksClicksNotHotkeys() throws {
        let midiName = "PlusMix 锁 \(UUID().uuidString.prefix(6))"
        let midiSource = try? VirtualMIDISource(name: midiName)   // 起 session 之前建：起的时候枚举现有源
        defer { midiSource?.dispose() }
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        addTeardownBlock { @MainActor in
            AppTest.controller.windowController.setInterfaceLocked(false)
            AppTest.controller.panels.closeAll()
        }
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        let window = try XCTUnwrap(wc.window as? MainWindow)
        let bar = wc.bottomBar
        let lock = bar.lockButton

        // 底栏最右
        let others = (bar.leftGroup.flatMap(\.allButtons) + [bar.overlayButton, bar.statsButton]).filter { !$0.isHidden }
        let lockFrame = lock.convert(lock.bounds, to: bar)
        XCTAssertTrue(others.allSatisfy { $0.convert($0.bounds, to: bar).maxX <= lockFrame.minX }, "锁在底栏最右")
        XCTAssertLessThanOrEqual(lockFrame.maxX, bar.bounds.maxX)
        XCTAssertFalse(wc.isInterfaceLocked)
        XCTAssertFalse(window.isInterfaceLocked)

        lock.performClick(nil)
        XCTAssertTrue(wc.isInterfaceLocked, "点锁 → 锁上")
        XCTAssertTrue(window.isInterfaceLocked)
        XCTAssertTrue(bar.isLockHighlighted, "锁着时按钮高亮")
        XCTAssertNotNil(lock.bezelColor)
        XCTAssertEqual(lock.title, "已锁定", "锁着时按钮上写明（窗口不在前台时系统不画底色，靠字认）")
        XCTAssertEqual(lock.accessibilityLabel(), "解锁界面")

        // 主窗口里的点击：拦
        let cut = wc.transitionPanel.cutButton
        let down = try XCTUnwrap(AppTest.mouseEvent(.leftMouseDown, at: cut))
        XCTAssertTrue(window.blocksForLock(down), "Cut 按钮的点击被拦")
        let blocked = window.blockedMouseEvents
        window.sendEvent(down)
        window.sendEvent(try XCTUnwrap(AppTest.mouseEvent(.leftMouseUp, at: cut)))
        XCTAssertEqual(window.blockedMouseEvents, blocked + 2, "按下 / 抬起都没往下传")
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.program, 1, "点击没生效")
        XCTAssertTrue(bar.displayedNotice.contains("锁"), "被拦时提示怎么解锁：\(bar.displayedNotice)")
        let cell = try XCTUnwrap(wc.inputStrip.cells[1])
        var targets: [NSView] = [cell, wc.transitionPanel.tbar, wc.mixerPanel, wc.programMonitor, wc.previewMonitor, bar.record.bodyButton,
                                 bar.statsButton, bar.overlayButton]
        if wc.mainToolbar.newButton.window === window { targets.append(wc.mainToolbar.newButton) }   // 工具条也在主窗口里
        for view in targets {
            for kind in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                XCTAssertTrue(window.blocksForLock(try XCTUnwrap(AppTest.mouseEvent(kind, at: view))), "\(type(of: view)) 的 \(kind) 被拦")
            }
        }
        // 锁按钮本身、鼠标移动不拦
        XCTAssertFalse(window.blocksForLock(try XCTUnwrap(AppTest.mouseEvent(.leftMouseDown, at: lock))), "锁按钮本身能点")
        XCTAssertFalse(window.blocksForLock(try XCTUnwrap(AppTest.mouseEvent(.mouseMoved, at: cut))), "悬停（提示）不拦")

        // 快捷键照常：空格 = Cut
        AppTest.press(" ")
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 }, "快捷键照常")
        // 菜单栏照常
        AppTest.delegate.transitionCut(nil)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 }, "菜单栏照常")
        // API 照常
        let port = try XCTUnwrap(session.control.apiServer?.boundPort)
        let api = try AppTest.http("POST", "http://127.0.0.1:\(port)/api/v1/command" + AppTest.tokenQuery(session), body: #"{"command":{"cut":{}}}"#)
        XCTAssertEqual(api.json?["applied"] as? Bool, true, api.text)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 }, "API 照常")
        // MIDI 照常（虚拟源连得上才跑这一段）
        let midi = session.control.midi
        if let midiSource, midi.isRunning, AppTest.waitUntil(5, { midi.sources.contains { $0.name == midiName && $0.connected } }) {
            try controller.applyMIDITable(MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 61), action: .action(.command(.cut)))]))
            defer { try? controller.applyMIDITable(MIDIMapTable(mappings: [])) }
            try midiSource.send(noteOn: 61, velocity: 100)
            XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 }, "MIDI 照常")
            try midiSource.send(noteOff: 61)
        } else {
            print("MIDI 这一段没跑：MIDI 控制器没起来或虚拟源没连上（\(session.control.midiError ?? "?")）")
        }
        // 独立窗口不锁
        let output = controller.panels.showOutputSettings(tab: .record)
        XCTAssertFalse(output.window is MainWindow, "输出设置是独立窗口，不受主窗口的锁管")

        // 再点锁 → 解开：同样的点击不再拦
        lock.performClick(nil)
        XCTAssertFalse(wc.isInterfaceLocked)
        XCTAssertFalse(window.blocksForLock(down), "解锁后点击照常")
        XCTAssertFalse(bar.isLockHighlighted)
        XCTAssertNil(lock.bezelColor)
        XCTAssertEqual(lock.title, "", "开着时只有图标")
        XCTAssertEqual(lock.accessibilityLabel(), "锁定界面")

        // 菜单栏"窗口 › 锁定界面"是同一个开关（规则 5），锁着时打勾；菜单栏不受锁影响，从这里也能解锁
        let lockSelector = #selector(AppDelegate.toggleInterfaceLock(_:))
        let lockItem = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == lockSelector })
        XCTAssertEqual(lockItem.title, "锁定界面")
        AppTest.delegate.toggleInterfaceLock(lockItem)
        XCTAssertTrue(wc.isInterfaceLocked && bar.isLockHighlighted)
        XCTAssertTrue(AppTest.delegate.validateMenuItem(lockItem))
        XCTAssertEqual(lockItem.state, .on, "锁着时打勾")
        AppTest.delegate.toggleInterfaceLock(lockItem)
        XCTAssertFalse(wc.isInterfaceLocked)
        _ = AppTest.delegate.validateMenuItem(lockItem)
        XCTAssertEqual(lockItem.state, .off)
    }
}

// MARK: - 报告 §2 的空闲复测（按环境变量开；平时跳过）

@MainActor
final class IdleWakeProbeTests: XCTestCase {
    /// W4-A / G4 记过：用户"空闲"时 macOS 把实时线程的唤醒拖 10–18 ms（reports/G4.md §11.3 g4c / g4d；caffeinate -u -i -d -s 包住才干净）。
    /// 这里在 App 里复测：G4 节目（8 路噪声合成源 + 抠像 + 叠加 + 多画面）跑 N 分钟、每 5 s 切一次，量合成源生产者的唤醒延迟 / 迟到、
    /// Stats 的 missed_render / jitter / 每路 drop；SWITCHER_IDLE_PROBE_MODE = activity（默认，App 的两条电源断言都拿着）/ none（都不拿）。
    /// 结果写 .build/app-test-output/idle-probe-<模式>-<时间>.json。用法：TEST_RUNNER_SWITCHER_IDLE_PROBE_MINUTES=10 xcodebuild test -only-testing:…
    func testW5L_idleWakeLatencyProbe() throws {
        guard let minutes = ProcessInfo.processInfo.environment["SWITCHER_IDLE_PROBE_MINUTES"].flatMap(Double.init), minutes > 0 else {
            throw XCTSkip("测量用例（reports/w5-app-misc.md §2 的空闲复测）：设 SWITCHER_IDLE_PROBE_MINUTES 才跑")
        }
        let mode = ProcessInfo.processInfo.environment["SWITCHER_IDLE_PROBE_MODE"] ?? "activity"
        let controller = AppTest.controller
        _ = try AppTest.freshSession()
        addTeardownBlock { @MainActor in
            AppTest.controller.updateSettings({ $0.preventSleepWhileRunning = true; $0.preventDisplaySleepWhileRunning = true }, saving: { $0.savePower(to: $1) })
        }
        let hold = mode != "none"
        controller.updateSettings({ $0.preventSleepWhileRunning = hold; $0.preventDisplaySleepWhileRunning = hold }, saving: { $0.savePower(to: $1) })
        let show = try AppTest.repoRoot().appendingPathComponent("scenarios/g4-show.json")
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: show); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(30) { opened.value && controller.session?.isRunning == true })
        let session = try XCTUnwrap(controller.session)
        let synthetic = session.state.inputs.filter { if case .synthetic = $0.source { true } else { false } }.map(\.number)
        XCTAssertTrue(AppTest.waitUntil(15) { synthetic.allSatisfy { session.inputs.runtimeState(of: $0) == .live } })
        XCTAssertEqual(controller.engineActivity.holdsSystemActivity, mode != "none")
        func counters() -> [Int: SyntheticVideoInput.Counters] {
            var out: [Int: SyntheticVideoInput.Counters] = [:]
            for n in synthetic {
                let input = session.inputs.entries[n]?.input
                if let v = input as? SyntheticVideoInput { out[n] = v.counters } else if let pair = input as? SyntheticPairInput { out[n] = pair.video.counters }
            }
            return out
        }
        AppTest.pump(seconds: 3)   // 起步那几秒不算
        let start = counters()
        let statsStart = try XCTUnwrap(session.stats)
        var rows: [Stats] = []
        let token = session.observeStats { rows.append($0) }
        var idle: [Double] = []
        var locked = 0
        let end = Date().addingTimeInterval(minutes * 60)
        var nextCut = Date().addingTimeInterval(5)
        while Date() < end {
            AppTest.pump(seconds: 1)
            idle.append(IdleProbe.hidIdleSeconds())
            if IdleProbe.screenLocked() { locked += 1 }
            if Date() >= nextCut {
                session.send(.cut)
                nextCut = nextCut.addingTimeInterval(5)
            }
        }
        token.invalidate()
        let finish = counters()
        let statsEnd = try XCTUnwrap(session.stats)
        var perInput: [[String: Any]] = []
        for n in synthetic {
            guard let a = start[n], let b = finish[n] else { continue }
            let wakes = Double((b.generated + b.droppedByDesign + b.poolStarved) - (a.generated + a.droppedByDesign + a.poolStarved))
            perInput.append(["input": n, "late": b.late - a.late, "wakeMaxMs": Double(b.wakeLatencyMaxNs) / 1e6,
                             "wakeMeanMs": wakes > 0 ? Double(b.wakeLatencySumNs - a.wakeLatencySumNs) / wakes / 1e6 : 0,
                             "drop": (statsEnd.perInput[n]?.drop ?? 0) - (statsStart.perInput[n]?.drop ?? 0)])
        }
        let jitters = rows.map(\.jitterMs).sorted()
        let result: [String: Any] = [
            "mode": mode, "minutes": minutes, "date": ISO8601DateFormatter().string(from: Date()),
            "assertions": EngineActivity.processAssertions().map { "\($0.type) \($0.name)" },
            "hidIdleMinSeconds": idle.min() ?? 0, "hidIdleMaxSeconds": idle.max() ?? 0, "screenLockedSeconds": locked,
            "missedRender": statsEnd.missedRender - statsStart.missedRender,
            "jitterMaxMs": jitters.last ?? 0, "jitterP99Ms": jitters.isEmpty ? 0 : jitters[min(jitters.count - 1, Int(Double(jitters.count) * 0.99))],
            "renderMsMean": rows.isEmpty ? 0 : rows.map(\.renderMs).reduce(0, +) / Double(rows.count),
            "perInput": perInput,
            "lateTotal": perInput.reduce(0) { $0 + (($1["late"] as? UInt64) ?? 0) },
            "wakeMaxMs": perInput.compactMap { $0["wakeMaxMs"] as? Double }.max() ?? 0,
        ]
        let url = AppTest.outputDirectory.appendingPathComponent("idle-probe-\(mode)-\(Int(Date().timeIntervalSince1970)).json")
        try FileManager.default.createDirectory(at: AppTest.outputDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("[W5-L 空闲复测] \(mode) \(minutes) min → \(url.path)\n\(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))")
    }
}

/// 复测时记的环境：用户多久没碰键鼠（HIDIdleTime）、会话是不是锁着。
enum IdleProbe {
    static func hidIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return -1 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return -1 }
        return value.doubleValue / 1e9
    }

    static func screenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
