// W5-B（prompt 87）直播安全：一步就停直播的五条（02 X01–X05）——底栏停录制 / 推流先确认（E11）、起不来的推流路不让主体按钮误伤（X02 / L4 / L13）、
// 新建 / 打开 / 换格式先确认且未保存先问（A3 / F5 / X03 / X04，Q67 (a)）、在推的路锁住（L12 / X24）；顺带：删输入确认（D9 / X13）、
// 退出不静默写回已打开的文件（X30）、窗口标题用产品名并标未保存（A4 / X42）。
// 确认框是真的 NSAlert sheet（ConfirmationCenter），测试按按钮回答。推流不依赖 MediaMTX：在跑的路连本机一个没人听的端口（一直连接中 / 退避），
// 起不来的路用不认的 scheme / 空地址。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class LiveSafetyTests: XCTestCase {
    // MARK: 1. 停止前确认（E11 / X01）

    func testUI_stopRecordAsksConfirmation() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let wc = controller.windowController
        let bar = wc.bottomBar
        defer {
            AppTest.dismissConfirmations()
            controller.settings.confirmBeforeStop = true
        }
        XCTAssertTrue(controller.settings.confirmBeforeStop, "停止前确认默认开（04 Q41）")
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        AppTest.pump(seconds: 0.5)

        // 开始不问
        let asked = ConfirmationCenter.shared.askedCount[.stopRecord] ?? 0
        bar.recordButton.performClick(nil)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "开始录制不问")
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil && bar.recordButton.title == "● 录制中" }, bar.recordButton.title)

        // 停：先弹 sheet，确认之前不发 stopRecord；取消 = 照录
        bar.recordButton.performClick(nil)
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.stopRecord), "停止录制前应弹确认")
        XCTAssertEqual(ask.request.title, "确定停止录制（1 路）？")
        XCTAssertTrue(wc.window?.attachedSheet === ask.alert.window, "sheet 挂在主窗口上")
        XCTAssertTrue(ask.request.buttons.contains { $0.choice == .confirm && $0.destructive }, "停止是破坏性按钮")
        XCTAssertNil(ask.request.defaultChoice, "回车不落在“停止”上：误按回车不会停")
        AppTest.pump(seconds: 0.3)
        XCTAssertEqual(session.state.output(1)?.enabled, true, "确认之前不发 stopRecord")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.5)
        XCTAssertEqual(session.state.output(1)?.enabled, true, "取消 = 照录")
        XCTAssertNotNil(session.outputs.recorders[1])

        // 再按、点"停止录制" = 停并封口
        bar.recordButton.performClick(nil)
        XCTAssertNotNil(AppTest.waitForConfirmation(.stopRecord))
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(1)?.enabled == false && session.outputs.recorders[1] == nil && session.outputs.lastResults[1] != nil },
                      "确定后停并封口：\(bar.recordButton.title)")
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.stopRecord] ?? 0, asked + 2)

        // 推流同一口径：开始不问，停先问（在跑的路连一个没人听的端口）
        session.send(.addOutput(config: AppTest.streamOutput(number: 2, url: AppTest.closedRTMP("stop"))))
        XCTAssertTrue(AppTest.waitUntil(3) { bar.streamButton.isEnabled })
        bar.streamButton.performClick(nil)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "开始推流不问")
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.streams[2] != nil }, "推流应起来（连接中 / 退避）")
        bar.streamButton.performClick(nil)
        let streamAsk = try XCTUnwrap(AppTest.waitForConfirmation(.stopStream), "停止推流前应弹确认")
        XCTAssertEqual(streamAsk.request.title, "确定停止推流（1 路）？")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(2)?.enabled == false && session.outputs.streams[2] == nil })

        // 偏好设置里有开关、默认开；关掉 = 一按就停、不问
        let prefs = controller.panels.showPreferences()
        XCTAssertTrue(prefs.model.confirmBeforeStop)
        prefs.model.confirmBeforeStop = false
        prefs.model.apply()
        XCTAssertFalse(controller.settings.confirmBeforeStop)
        XCTAssertEqual(controller.defaults.object(forKey: AppSettings.Keys.confirmBeforeStop) as? Bool, false, "写进 UserDefaults")
        bar.recordButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil })
        bar.recordButton.performClick(nil)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "关了就不问")
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(1)?.enabled == false && session.outputs.recorders[1] == nil })
        prefs.model.confirmBeforeStop = true
        prefs.model.apply()
        XCTAssertTrue(controller.settings.confirmBeforeStop)
        controller.panels.closeAll()
    }

    /// 快捷键 / MIDI / API 停录制一律不弹（E11：确认只管底栏按钮）。
    func testHotkeys_stopRecordNeverAsks() throws {
        let midiName = "PlusMix 停录制 \(UUID().uuidString.prefix(6))"
        let midiSource = try? VirtualMIDISource(name: midiName)   // 起 session 之前建：起的时候枚举现有源
        defer { midiSource?.dispose() }
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        XCTAssertTrue(controller.settings.confirmBeforeStop)
        let asked = ConfirmationCenter.shared.askedCount[.stopRecord] ?? 0

        // 快捷键：r = 录制开关（toggleRecord 1）
        var table = HotkeyTable.default
        table.bindings.append(HotkeyBinding(key: KeyCombo(key: "r"), action: .toggleRecord(output: 1)))
        try controller.applyHotkeyTable(table)
        defer { try? controller.applyHotkeyTable(.default) }
        AppTest.press("r", keyCode: 15)
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.output(1)?.enabled == true && session.outputs.recorders[1] != nil }, "快捷键开录")
        AppTest.press("r", keyCode: 15)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "快捷键停录制不问")
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(1)?.enabled == false && session.outputs.recorders[1] == nil }, "快捷键直接停")

        // API：POST stopRecord
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil })
        let port = try XCTUnwrap(session.control.apiServer?.boundPort, "API 应起来：\(session.control.apiError ?? "?")")
        let r = try AppTest.http("POST", "http://127.0.0.1:\(port)/api/v1/command", body: #"{"command":{"stopRecord":{"output":1}}}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "API 停录制不问")
        XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(1)?.enabled == false && session.outputs.recorders[1] == nil }, "API 直接停")

        // MIDI：Note 60 → 录制开关（与快捷键同一类动作）
        let midi = session.control.midi
        if let midiSource, midi.isRunning, AppTest.waitUntil(5, { midi.sources.contains { $0.name == midiName && $0.connected } }) {
            try controller.applyMIDITable(MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.toggleRecord(output: 1)))]))
            defer { try? controller.applyMIDITable(MIDIMapTable(mappings: [])) }
            try midiSource.send(noteOn: 60, velocity: 100)
            XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil }, "MIDI 开录")
            try midiSource.send(noteOff: 60)
            AppTest.pump(seconds: 0.3)
            try midiSource.send(noteOn: 60, velocity: 100)
            XCTAssertNil(ConfirmationCenter.shared.pending(), "MIDI 停录制不问")
            XCTAssertTrue(AppTest.waitUntil(10) { session.state.output(1)?.enabled == false && session.outputs.recorders[1] == nil }, "MIDI 直接停")
        } else {
            print("MIDI 这一段没跑：MIDI 控制器没起来或虚拟源没连上（\(session.control.midiError ?? "?")）")
        }
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.stopRecord] ?? 0, asked, "这几条路一次都没问")
    }

    // MARK: 2. 换节目 / 换格式前确认，未保存先问（A3 / F5 / X03 / X04，Q67 (a)）

    func testUI_newShowWhileLiveAsksConfirmation() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let window = try XCTUnwrap(controller.windowController.window)
        defer { AppTest.dismissConfirmations() }
        XCTAssertFalse(controller.isDocumentEdited, "新建的空节目没有改动")
        XCTAssertFalse(window.isDocumentEdited)
        try AppTest.addSynthetics(session, count: 1)
        session.send(.addOutput(config: AppTest.streamOutput(number: 2, url: AppTest.closedRTMP("new"))))
        XCTAssertTrue(AppTest.waitUntil(3) { controller.isDocumentEdited && window.isDocumentEdited }, "加了输入 / 推流目的地 = 有未保存的改动，窗口标出来")
        session.send(.startRecord(output: 1))
        session.send(.startStream(output: 2))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil && session.outputs.streams[2] != nil })

        // 节目 › 新建（菜单与 ⌘N 同一个入口）：先问"会停止 1 路录制、1 路推流"；取消 = 什么都不动
        controller.requestNewShow()
        let live = try XCTUnwrap(AppTest.waitForConfirmation(.replaceShow), "录制 / 推流在跑时新建应先确认")
        XCTAssertEqual(live.request.title, "新建节目会停止 1 路录制、1 路推流")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.5)
        XCTAssertTrue(controller.session === session, "取消 = 不换节目")
        XCTAssertNotNil(session.outputs.recorders[1])
        XCTAssertNotNil(session.outputs.streams[2])

        // 确定停止 → 再问保存；这一问取消也什么都不动
        controller.requestNewShow()
        XCTAssertNotNil(AppTest.waitForConfirmation(.replaceShow))
        AppTest.answer(.confirm)
        let save = try XCTUnwrap(AppTest.waitForConfirmation(.saveChanges), "有未保存的改动应问保存")
        XCTAssertEqual(save.request.title, "要保存对“未命名”的改动吗？")
        XCTAssertEqual(save.buttonTitles, ["保存…", "取消", "不保存"])
        XCTAssertEqual(save.request.defaultChoice, .confirm, "回车 = 保存（mac 文档类 App 的惯例）")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.5)
        XCTAssertTrue(controller.session === session, "保存那一问取消也不换")
        XCTAssertNotNil(session.outputs.recorders[1], "也没停")

        // 确定 + 不保存 → 换成空节目
        controller.requestNewShow()
        XCTAssertNotNil(AppTest.waitForConfirmation(.replaceShow))
        AppTest.answer(.confirm)
        XCTAssertNotNil(AppTest.waitForConfirmation(.saveChanges))
        AppTest.answer(.alternate)
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session !== session && controller.session?.isRunning == true }, "不保存 → 新建")
        let fresh = try XCTUnwrap(controller.session)
        XCTAssertEqual(fresh.state.inputs.count, 0)
        XCTAssertNotNil(session.outputs.lastResults[1], "旧节目的录制已封口")
        XCTAssertFalse(controller.isDocumentEdited)
        XCTAssertFalse(window.isDocumentEdited)

        // 没在跑、没改动：直接新建，一句都不问
        let replaceAsked = ConfirmationCenter.shared.askedCount[.replaceShow] ?? 0
        let saveAsked = ConfirmationCenter.shared.askedCount[.saveChanges] ?? 0
        controller.requestNewShow()
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session !== fresh && controller.session?.isRunning == true })
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.replaceShow] ?? 0, replaceAsked)
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.saveChanges] ?? 0, saveAsked)

        // 打开（打开… / 打开最近 / Finder 双击都走 requestOpenShow）：同一口径，标题带文件名
        let quiet = try XCTUnwrap(controller.session)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5b-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("另一个.\(ShowDocuments.fileExtension)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try controller.documents.save(ShowDocuments.emptyShow(name: "另一个"), to: url)
        quiet.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { quiet.outputs.recorders[1] != nil })
        controller.requestOpenShow(url: url)
        let open = try XCTUnwrap(AppTest.waitForConfirmation(.replaceShow))
        XCTAssertEqual(open.request.title, "打开“另一个.switcher.json”会停止 1 路录制")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.3)
        XCTAssertTrue(controller.session === quiet)
        quiet.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(10) { quiet.outputs.recorders[1] == nil })
    }

    /// 退出：不再静默写回已打开的节目文件；有改动先问（保存 / 不保存 / 取消），LastSession 照存（崩溃恢复）。
    func testShow_quitDoesNotOverwriteOpenedFileSilently() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        defer {
            AppTest.dismissConfirmations()
            if controller.session == nil {
                let done = AppTest.expectationBox()
                Task { await controller.newShow(); done.value = true }
                AppTest.waitUntil(20) { done.value && controller.session?.isRunning == true }
            }
        }
        try AppTest.addSynthetics(session, count: 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5b-quit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("模板.\(ShowDocuments.fileExtension)")
        controller.write(session.makeShow(), to: url)
        XCTAssertEqual(controller.documents.currentURL, url)
        XCTAssertFalse(controller.isDocumentEdited, "刚存过")
        let onDisk = try Data(contentsOf: url)

        // 临时改两处（加一路、改名）
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        session.send(.renameInput(input: 1, name: "临时改的"))
        XCTAssertTrue(AppTest.waitUntil(3) { controller.isDocumentEdited }, "改了就标未保存")

        // 退出前问；取消 = 不退
        var decision: Bool?
        controller.prepareToQuit { decision = $0 }
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.saveChanges), "有改动时退出应问")
        XCTAssertEqual(ask.request.title, "要保存对“模板”的改动吗？")
        XCTAssertEqual(ask.buttonTitles, ["保存", "取消", "不保存"], "有文件：保存直接写回，不弹存储面板")
        AppTest.answer(.cancel)
        XCTAssertTrue(AppTest.waitUntil(2) { decision == false }, "取消 = 不退出")

        // 不保存 → 可以退；退出流程（shutdown）不碰原文件，LastSession 照存
        decision = nil
        controller.prepareToQuit { decision = $0 }
        XCTAssertNotNil(AppTest.waitForConfirmation(.saveChanges))
        AppTest.answer(.alternate)
        XCTAssertTrue(AppTest.waitUntil(2) { decision == true })
        let autosave = controller.documents.autosaveURL
        XCTAssertTrue(autosave.path.contains("switcher-tests"), "测试宿主的 LastSession 在临时目录：\(autosave.path)")
        try? FileManager.default.removeItem(at: autosave)
        let done = AppTest.expectationBox()
        Task { await controller.shutdown(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value })
        XCTAssertNil(controller.session)
        XCTAssertEqual(try Data(contentsOf: url), onDisk, "退出不再静默写回已打开的文件（X30）")
        let last = try XCTUnwrap(controller.documents.loadAutosave(), "LastSession 照存（崩溃恢复）")
        XCTAssertEqual(last.inputs.count, 2)
        XCTAssertEqual(last.inputs.first?.name, "临时改的")

        // 选"保存"：写回原文件（是用户点的，不是静默）
        let reopened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); reopened.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { reopened.value && controller.session?.isRunning == true })
        let s2 = try XCTUnwrap(controller.session)
        XCTAssertEqual(s2.state.inputs.count, 1)
        XCTAssertFalse(controller.isDocumentEdited, "刚打开")
        s2.send(.addInput(config: AppTest.syntheticConfig(number: 5)))
        XCTAssertTrue(AppTest.waitUntil(3) { controller.isDocumentEdited })
        decision = nil
        controller.prepareToQuit { decision = $0 }
        XCTAssertNotNil(AppTest.waitForConfirmation(.saveChanges))
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(3) { decision == true })
        XCTAssertEqual(try controller.documents.load(from: url).inputs.map(\.number), [1, 5], "选了保存才写回")
        XCTAssertFalse(controller.isDocumentEdited)

        // 没改动：退出不问
        let asked = ConfirmationCenter.shared.askedCount[.saveChanges] ?? 0
        decision = nil
        controller.prepareToQuit { decision = $0 }
        XCTAssertTrue(AppTest.waitUntil(2) { decision == true })
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.saveChanges] ?? 0, asked)
    }

    /// 偏好设置里换引擎的三个按钮：录制 / 推流在跑时先确认；换完设置窗不关，只重绑模型。
    func testUI_applyFormatKeepsPreferencesWindowOpen() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        defer {
            AppTest.dismissConfirmations()
            controller.panels.closeAll()
        }
        try AppTest.addSynthetics(session, count: 1)
        let prefs = controller.panels.showPreferences()
        let prefsWindow = try XCTUnwrap(prefs.window)
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil })

        // 节目格式"应用"：先问；取消 = 不换
        prefs.model.selectFormatPreset(.hd720p60)
        XCTAssertTrue(prefs.model.applyProgramFormat())
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.restartEngine), "录制在跑时换格式应先确认")
        XCTAssertEqual(ask.request.title, "换节目格式要重起引擎，会停止 1 路录制")
        XCTAssertTrue(prefsWindow.attachedSheet === ask.alert.window, "sheet 挂在偏好设置窗上")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.5)
        XCTAssertTrue(controller.session === session && session.format == .hd1080p60, "取消 = 不换")
        XCTAssertNotNil(session.outputs.recorders[1], "也没停")

        // 确定 → 换；设置窗不关、模型重绑到新 session
        XCTAssertTrue(prefs.model.applyProgramFormat())
        XCTAssertNotNil(AppTest.waitForConfirmation(.restartEngine))
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session !== session && controller.session?.isRunning == true && controller.session?.format == .hd720p60 },
                      "\(String(describing: controller.session?.format))")
        XCTAssertTrue(controller.panels.preferencesWindow === prefs, "换引擎后设置窗不关（X04）")
        XCTAssertTrue(prefsWindow.isVisible)
        XCTAssertEqual(prefs.model.formatWidth, 1280, "模型重绑到新 session")
        XCTAssertEqual(prefs.model.status, "已重起引擎")
        XCTAssertFalse(prefs.model.applyProgramFormat(), "格式没变：不换")
        let s2 = try XCTUnwrap(controller.session)

        // 节目音频"应用"、"应用并重起引擎"：同一口径
        s2.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { s2.outputs.recorders[1] != nil })
        prefs.model.alignmentFrames = 4096
        XCTAssertTrue(prefs.model.applyShowAudio())
        let audioAsk = try XCTUnwrap(AppTest.waitForConfirmation(.restartEngine))
        XCTAssertEqual(audioAsk.request.title, "改节目音频要重起引擎，会停止 1 路录制")
        AppTest.answer(.cancel)
        prefs.model.applyAndRestart()
        let restartAsk = try XCTUnwrap(AppTest.waitForConfirmation(.restartEngine))
        XCTAssertEqual(restartAsk.request.title, "重起引擎会停止 1 路录制")
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.5)
        XCTAssertTrue(controller.session === s2, "两次都取消：不换")
        XCTAssertNotNil(s2.outputs.recorders[1])

        // 没在跑：直接换，不问；设置窗照样开着
        s2.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(10) { s2.outputs.recorders[1] == nil })
        let asked = ConfirmationCenter.shared.askedCount[.restartEngine] ?? 0
        prefs.model.applyAndRestart()
        XCTAssertTrue(AppTest.waitUntil(20) { controller.session !== s2 && controller.session?.isRunning == true })
        XCTAssertEqual(ConfirmationCenter.shared.askedCount[.restartEngine] ?? 0, asked)
        XCTAssertTrue(controller.panels.preferencesWindow === prefs && prefsWindow.isVisible)
    }

    // MARK: 3. 失败的推流路与按钮状态（X02 / L4 / L13 / K11 / X11 / X37 / X38）

    private func route(_ n: Int, _ enabled: Bool, _ state: String?, frames: UInt64 = 0, attempt: Int? = nil, failure: String? = nil) -> OutputRouteStatus {
        OutputRouteStatus(number: n, name: "推流 \(n)", enabled: enabled, state: state, frames: frames, attempt: attempt, failure: failure)
    }

    func testUI_streamButtonAggregatesWorstState() {
        let pub1 = route(1, true, "publishing", frames: 600), pub2 = route(2, true, "publishing", frames: 600)
        var s = OutputButtonSummary.stream([route(1, false, "idle")])
        XCTAssertEqual(s.title, "推流")
        XCTAssertEqual(s.severity, .off)
        s = .stream([pub1])
        XCTAssertEqual(s.title, "● 推流中", "单个目的地")
        XCTAssertEqual(s.severity, .live)
        s = .stream([pub1, pub2, route(3, false, "idle")])
        XCTAssertEqual(s.title, "● 推流中 2/3", "三个目的地两个在推（第三个没开）")
        XCTAssertEqual(s.severity, .live)
        s = .stream([pub1, pub2, route(3, true, "publishing", frames: 600)])
        XCTAssertEqual(s.title, "● 推流中 3/3")
        // 首连第 1 次 = 正常的"连接中"，不算异常；n/m 只数在推的
        s = .stream([pub1, route(2, true, "connecting", attempt: 1)])
        XCTAssertEqual(s.title, "● 推流中 1/2")
        XCTAssertEqual(s.severity, .live)
        // 一路在重连（连上过、正在第 2 次重连）→ 橙，"1 路异常"，提示里列各路
        s = .stream([pub1, pub2, route(3, true, "backoff", frames: 900, attempt: 3)])
        XCTAssertEqual(s.title, "推流 · 1 路异常")
        XCTAssertEqual(s.severity, .warning)
        XCTAssertEqual(s.color, Theme.outputWarning)
        XCTAssertTrue(s.toolTip?.contains("推流 3：重连中（第 2 次）") == true, s.toolTip ?? "")
        XCTAssertTrue(s.toolTip?.contains("推流 1：推流中") == true, s.toolTip ?? "")
        // 一路起不来 → 红，提示写原因
        s = .stream([pub1, pub2, route(3, true, "failed", failure: "推流 3 没有地址")])
        XCTAssertEqual(s.title, "推流 · 1 路异常")
        XCTAssertEqual(s.severity, .error)
        XCTAssertEqual(s.color, Theme.outputError)
        XCTAssertTrue(s.toolTip?.contains("推流 3：起不来 — 推流 3 没有地址") == true, s.toolTip ?? "")
        XCTAssertTrue(s.toolTip?.contains("点一下：重试起不来的路") == true, "提示点主体的作用：\(s.toolTip ?? "")")
        // 最差的那一路定颜色，异常路数按路数算
        s = .stream([pub1, route(2, true, "backoff", frames: 10, attempt: 2), route(3, true, "idle", failure: "x")])
        XCTAssertEqual(s.title, "推流 · 2 路异常")
        XCTAssertEqual(s.severity, .error)
        // 单个目的地：直接写它的状态
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "connecting", attempt: 1)]).title, "推流 · 连接中", "首次连接叫“连接中”，不叫重连")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "connecting", attempt: 1)]).severity, .pending)
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "backoff", attempt: 3)]).title, "推流 · 连接中（第 3 次）", "一直连不上：真实尝试次数")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "backoff", attempt: 3)]).severity, .warning)
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "connecting", frames: 5, attempt: 2)]).title, "推流 · 重连中（第 1 次）")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "connecting", frames: 5, attempt: 4)]).title, "推流 · 重连中（第 3 次）")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "idle", failure: "推流 1 没有地址")]).title, "推流 · 起不来", "原来显示“推流 · idle”")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "idle", failure: "推流 1 没有地址")]).severity, .error)
        // 录制同一套：PGM + 两路 ISO 都在录 →"● 录制中（3 路）"；一路起不来 → 红
        let rec = { (n: Int) in OutputRouteStatus(number: n, name: "录制 \(n)", enabled: true, state: "recording") }
        XCTAssertEqual(OutputButtonSummary.record([rec(1)]).title, "● 录制中")
        XCTAssertEqual(OutputButtonSummary.record([rec(1), rec(2), rec(3)]).title, "● 录制中（3 路）")
        let recFailed = OutputButtonSummary.record([rec(1), rec(2), OutputRouteStatus(number: 3, name: "ISO 3", enabled: true, state: "idle", failure: "分支用完了")])
        XCTAssertEqual(recFailed.title, "录制 · 1 路异常")
        XCTAssertEqual(recFailed.severity, .error)
        XCTAssertTrue(recFailed.toolTip?.contains("ISO 3：起不来 — 分支用完了") == true, recFailed.toolTip ?? "")
    }

    func testUI_streamRetryDoesNotStopHealthyRoutes() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        let bar = wc.bottomBar
        defer { AppTest.dismissConfirmations() }
        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }
        // 2 号：在跑（连一个没人听的端口，一直连接中 / 退避）；3 号：地址的 scheme 不认 → 起不来
        session.send(.addOutput(config: AppTest.streamOutput(number: 2, url: AppTest.closedRTMP("healthy"), name: "主平台")))
        session.send(.addOutput(config: AppTest.streamOutput(number: 3, url: "foo://example.com/live", name: "备用")))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.filter { $0.kind == .stream }.count == 2 })
        bar.streamButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.streams[2] != nil && session.outputs.failureReason(output: 3) != nil }, "\(session.outputs.failed)")
        let healthy = try XCTUnwrap(session.outputs.streams[2])
        let reason = try XCTUnwrap(session.outputs.failureReason(output: 3))
        XCTAssertTrue(reason.contains("foo"), "原因写明 scheme 不认：\(reason)")
        XCTAssertFalse(reason.contains("unsupportedScheme"), "原因是人话，不是 Swift 枚举：\(reason)")
        // Stats 里起不来的那一路报 failed（原来报 idle，按钮显示"推流 · idle"）
        XCTAssertTrue(AppTest.waitUntil(3) { bar.encoderEntry(forOutput: 3)?.state == "failed" }, "\(String(describing: bar.encoderEntry(forOutput: 3)))")
        XCTAssertTrue(AppTest.waitUntil(3) { bar.streamButton.title.contains("异常") }, bar.streamButton.title)
        XCTAssertEqual(bar.streamSummary.severity, .error)
        XCTAssertTrue(bar.streamButton.toolTip?.contains(reason) == true, "底栏提示写原因：\(bar.streamButton.toolTip ?? "")")
        // X37：没连上就不提示"已开始"，只提示"连接中"
        XCTAssertTrue(notices.contains("推流 2 连接中…"), "\(notices)")
        XCTAssertFalse(notices.contains { $0.contains("已开始") }, "没连上不能说已开始：\(notices)")

        // 有起不来的路时点主体 = 只重试它，不停正常的那一路，也不问
        let failures = notices.filter { $0.contains("推流 3") }.count
        bar.streamButton.performClick(nil)
        AppTest.pump(seconds: 0.5)
        XCTAssertNil(ConfirmationCenter.shared.pending(), "重试不是停：不问")
        XCTAssertTrue(session.outputs.streams[2] === healthy, "正常的那一路没被停、没被重建")
        XCTAssertEqual(session.state.output(2)?.enabled, true)
        XCTAssertEqual(session.state.output(3)?.enabled, true)
        XCTAssertGreaterThan(notices.filter { $0.contains("推流 3") }.count, failures, "起不来的那一路重试过（又报了一次原因）：\(notices)")

        // 推流页把地址改对（setOutputSettings）→ enabled 仍为真，自动重试、起来
        var fixed = try XCTUnwrap(session.state.output(3)?.settings)
        fixed.stream?.url = AppTest.closedRTMP("backup")
        session.send(.setOutputSettings(output: 3, settings: fixed))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.streams[3] != nil && session.outputs.failureReason(output: 3) == nil }, "地址改对后应自动重试：\(session.outputs.failed)")
        XCTAssertTrue(session.outputs.streams[2] === healthy)

        // 都在跑（没有起不来的）：点主体 = 停全部，先问
        bar.streamButton.performClick(nil)
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.stopStream))
        XCTAssertEqual(ask.request.title, "确定停止推流（2 路）？")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(10) { session.outputs.streams.isEmpty && session.state.outputs.allSatisfy { !$0.enabled } })
        XCTAssertEqual(bar.streamButton.title, "推流")
    }

    func testUI_streamStateTextLocalized() {
        let streamStates = ["idle", "connecting", "publishing", "backoff", "stopping", "stopped", "failed"]   // Stats.EncoderEntry.state 的推流取值
        let recordStates = ["idle", "recording", "stopping", "stopped", "failed"]
        // 原样的 state 词（整词、区分大小写：英文译名首字母大写，"Reconnecting" 里的 connecting 不算）
        func rawWords(_ s: String) -> [String] {
            Set(streamStates + recordStates).sorted().filter { s.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        }
        func check(_ language: String) {
            for st in streamStates {
                for routes in [[route(1, true, st, attempt: 1)], [route(1, true, st, frames: 9, attempt: 2), route(2, true, "publishing", frames: 9)]] {
                    let s = OutputButtonSummary.stream(routes)
                    XCTAssertEqual(rawWords(s.title), [], "\(language) 推流按钮原样显示了英文 state：\(s.title)")
                    XCTAssertEqual(rawWords(s.toolTip ?? ""), [], "\(language) 推流提示原样显示了英文 state：\(s.toolTip ?? "")")
                    XCTAssertFalse(s.title.contains("output.state") || s.title.contains("bottom."), "缺键：\(s.title)")
                }
            }
            for st in recordStates {
                let s = OutputButtonSummary.record([OutputRouteStatus(number: 1, name: "R", enabled: true, state: st)])
                XCTAssertEqual(rawWords(s.title), [], "\(language) 录制按钮原样显示了英文 state（K11）：\(s.title)")
                XCTAssertFalse(s.title.contains("output.state") || s.title.contains("bottom."), "缺键：\(s.title)")
            }
        }
        check("zh-Hans")
        XCTAssertEqual(OutputButtonSummary.record([OutputRouteStatus(number: 1, name: "R", enabled: true, state: "stopping")]).title, "录制 · 封口中")
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "stopping")]).title, "推流 · 正在停")
        // X38：推流页"重连上限"改叫"重试间隔最长"（App 里推流一直重试，不是"超过就放弃"）
        XCTAssertEqual(L("outputSettings.stream.reconnect", 30.0), "重试间隔最长 30 s（一直重试）")
        // X37："推流 n 开始"只在连上时提示
        XCTAssertEqual(L("notice.streamConnecting", 2), "推流 2 连接中…")
        XCTAssertEqual(L("notice.streamStarted", 2), "推流 2 已开始")
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = "zh-Hans" }
        check("en")
        let cjk = try! NSRegularExpression(pattern: #"[一-鿿　-〿！-～]"#)
        for st in streamStates {
            let t = OutputButtonSummary.stream([route(1, true, st, attempt: 2)]).title
            XCTAssertNil(cjk.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), "英文界面里有中文：\(t)")
        }
        XCTAssertEqual(OutputButtonSummary.stream([route(1, true, "connecting", attempt: 1)]).title, "Stream · Connecting")
    }

    // MARK: 4. 在推的路锁住（L12 / X05 / X24），录制页在录时提示（K6）

    func testUI_streamingDestinationLockedWhileLive() throws {
        let session = try AppTest.freshSession()
        let panels = AppTest.controller.panels
        defer {
            AppTest.dismissConfirmations()
            panels.closeAll()
        }
        let page = panels.showOutputSettings(tab: .stream).model
        let n = page.addStream(url: AppTest.closedRTMP("lock"), key: "k1")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) != nil })
        XCTAssertFalse(page.isStreamLocked(n), "没在推：能改")
        // 地址 / 密钥：回车或失焦才提交（commitStreamAddress），不再每个键发一次
        page.commitStreamAddress(n, url: AppTest.closedRTMP("lock2"), key: "k2")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n)?.settings.stream?.url == AppTest.closedRTMP("lock2") && session.state.output(n)?.settings.stream?.streamKey == "k2" })

        session.send(.startStream(output: n))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.streams[n] != nil && page.isStreamLocked(n) }, "在推的路应锁住")
        XCTAssertEqual(page.streamLockNote(n), "正在推流：地址、密钥和编码停止后可改。")
        var sent: [Command] = []
        let forward = page.send
        page.send = { c in sent.append(c); forward?(c) }
        page.commitStreamAddress(n, url: "rtmp://127.0.0.1:1/live/other", key: "zzz")
        page.updateOutput(n) { $0.video?.bitrateBps = 1_000_000 }
        page.removeOutput(n)
        XCTAssertEqual(sent, [], "在推的路：地址 / 编码 / 删除目的地都锁住（X05 / X24）")
        AppTest.pump(seconds: 0.3)
        XCTAssertNotNil(session.state.output(n))
        XCTAssertNotNil(session.outputs.streams[n], "没被断流")
        XCTAssertEqual(page.state.output(n)?.settings.stream?.url, AppTest.closedRTMP("lock2"))

        // 停了就能改、能删
        session.send(.stopStream(output: n))
        XCTAssertTrue(AppTest.waitUntil(10) { !page.isStreamLocked(n) && session.outputs.streams[n] == nil })
        XCTAssertNil(page.streamLockNote(n))
        page.removeOutput(n)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(n) == nil })

        // 起不来的路不锁（要能把地址改对），页上写明原因
        let bad = page.addStream(url: "", key: "")
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(bad) != nil })
        session.send(.startStream(output: bad))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.failureReason(output: bad) != nil })
        XCTAssertTrue(AppTest.waitUntil(3) { page.streamStatus(output: bad).hasPrefix("起不来") }, page.streamStatus(output: bad))
        XCTAssertTrue(page.streamStatus(output: bad).contains("没有地址"), page.streamStatus(output: bad))
        XCTAssertFalse(page.isStreamLocked(bad), "起不来的路不锁：要能改对地址")
        page.disableStream(bad)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(bad)?.enabled == false && session.outputs.failureReason(output: bad) == nil }, "停用这一路")

        // 录制页：在录时提示"改动从下一次开录起生效"（K6）
        XCTAssertNil(page.recordLiveNote)
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { page.recordLiveNote == "正在录制：改动从下一次开录起生效。" }, String(describing: page.recordLiveNote))
        session.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(10) { page.recordLiveNote == nil && session.outputs.recorders[1] == nil })
    }

    // MARK: 5. 删除输入确认（D9 / X13）

    func testUI_deleteInputOnProgramAsksConfirmation() throws {
        let session = try AppTest.freshSession()
        defer { AppTest.dismissConfirmations() }
        try AppTest.addSynthetics(session, count: 3)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.program == 1 && session.state.preview == 2 })
        let strip = AppTest.controller.windowController.inputStrip
        let window = try XCTUnwrap(AppTest.controller.windowController.window)
        let cell1 = try XCTUnwrap(strip.cells[1])

        // 右键菜单："删除"前有分隔线
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(cell1.menu(for: event))
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, true, false], menu.items.map(\.title).description)
        XCTAssertEqual(menu.items.last?.title, "删除输入 1")

        // 哪儿都没用的 3 号：直接删，不问
        try XCTUnwrap(strip.cells[3]).requestRemoval()
        XCTAssertNil(ConfirmationCenter.shared.pending())
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(3) == nil })

        // PGM 上的 1 号：先问，写明后果；取消 = 不删
        cell1.requestRemoval()
        let ask = try XCTUnwrap(AppTest.waitForConfirmation(.removeInput), "删 PGM 上的那一路应先确认")
        XCTAssertEqual(ask.request.title, "删除输入 1 · 合成 1？")
        XCTAssertTrue(ask.request.message.contains("PGM 会变成黑场"), ask.request.message)
        AppTest.answer(.cancel)
        AppTest.pump(seconds: 0.3)
        XCTAssertNotNil(session.state.input(1))
        XCTAssertEqual(session.state.program, 1)
        cell1.requestRemoval()
        XCTAssertNotNil(AppTest.waitForConfirmation(.removeInput))
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1) == nil && session.state.program == MixerState.noInput }, "确定后删，PGM 变黑场")

        // 判定口径：PGM / PVW / 叠加（开着的通道）/ Stinger / ISO 录制中
        var state = MixerState()
        state.inputs = (1...6).map { AppTest.syntheticConfig(number: $0) }
        state.program = 1
        state.preview = 2
        state.overlays[2].input = 3
        state.overlays[2].on = true
        state.overlays[3].input = 6   // 关着的通道里放着的不算"在叠加中"
        state.transition.stinger = StingerParams(input: 4, cutAtTick: 10)
        var iso = ISORoutes.makeISOOutput(for: state.inputs[4], in: state, defaultDirectory: "/tmp")
        iso.number = 7
        iso.enabled = true
        state.outputs = [iso]
        XCTAssertEqual(InputRemovalImpact.impacts(of: 1, in: state), [.program])
        XCTAssertEqual(InputRemovalImpact.impacts(of: 2, in: state), [.preview])
        XCTAssertEqual(InputRemovalImpact.impacts(of: 3, in: state), [.overlay(channel: 3)])
        XCTAssertEqual(InputRemovalImpact.impacts(of: 4, in: state), [.stinger])
        XCTAssertEqual(InputRemovalImpact.impacts(of: 5, in: state), [.isoRecording(output: 7, name: iso.name)])
        XCTAssertEqual(InputRemovalImpact.impacts(of: 6, in: state), [])
        state.preview = 1
        XCTAssertEqual(InputRemovalImpact.impacts(of: 1, in: state), [.program, .preview])
        XCTAssertEqual(InputRemovalImpact.preview.text, "它在 PVW 上：删掉后 PVW 变成黑场")
    }

    // MARK: 9. 窗口标题（A4 / X42）

    func testUI_windowTitleUsesProductNameAfterSave() throws {
        let session = try AppTest.freshSession()
        let controller = AppTest.controller
        let window = try XCTUnwrap(controller.windowController.window)
        let version = SwitcherVersion.current
        XCTAssertEqual(window.title, "PlusMix \(version) — 未命名")
        XCTAssertFalse(window.isDocumentEdited)
        try AppTest.addSynthetics(session, count: 1)
        XCTAssertTrue(AppTest.waitUntil(3) { window.isDocumentEdited }, "未保存的改动：窗口标出来")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w5b-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("周日礼拜.\(ShowDocuments.fileExtension)")
        controller.write(session.makeShow(), to: url)
        XCTAssertEqual(window.title, "PlusMix \(version) — 周日礼拜", "保存后仍是产品名（原来被写成代码名）")
        XCTAssertFalse(window.title.contains("Switcher"))
        XCTAssertFalse(window.isDocumentEdited, "存过 = 没有未保存的改动")

        // 切换（PGM / PVW / Cut）不算改动
        session.send(.setPreview(input: 1))
        session.send(.cut)
        AppTest.pump(seconds: 0.5)
        XCTAssertFalse(window.isDocumentEdited, "切换动作不算未保存的改动")
        // 改设置算
        session.send(.renameInput(input: 1, name: "讲台"))
        XCTAssertTrue(AppTest.waitUntil(3) { window.isDocumentEdited })
        controller.save()   // 有文件：直接写回
        XCTAssertEqual(window.title, "PlusMix \(version) — 周日礼拜")
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertEqual(try controller.documents.load(from: url).inputs.first?.name, "讲台")
    }
}
