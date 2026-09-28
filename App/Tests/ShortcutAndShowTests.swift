// 快捷键（W2-C 的 HotkeyDispatcher + 默认表，经 MainWindow.keyDown → CommandBus）和节目文件（ShowDocuments：新建 / 保存 / 打开 / 最近 / 上次 / 自动保存）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
import SwitcherInputs
@testable import Switcher

@MainActor
final class ShortcutAndShowTests: XCTestCase {
    private func key(_ chars: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0, repeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: `repeat`, keyCode: keyCode)!
    }

    /// 主窗口的按键经 KeyCombo(event:) → HotkeyDispatcher（默认表）解析成命令；带 ⌘ 的、自动重复的、没绑定的不吃。
    func testHotkeys_defaultTableResolvesThroughDispatcher() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let dispatcher = session.control.hotkeys
        XCTAssertEqual(dispatcher.table, HotkeyTable.default, "测试宿主固定用默认表")
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key("2", keyCode: 19))!), .setPreview(input: 2))
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key("0", keyCode: 29))!), .setPreview(input: 10))
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key("@", ignoring: "2", flags: [.shift], keyCode: 19))!), .setProgram(input: 2))
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key(" ", keyCode: 49))!), .cut)
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key("\r", keyCode: 36))!), .autoTransition, "回车 = 按已选转场执行")
        XCTAssertEqual(dispatcher.command(for: KeyCombo(event: key("f", keyCode: 3))!), .ftb(on: true), "FTB 是开关（现在关着 → 开）")
        XCTAssertFalse(session.control.handleKey(key("2", flags: [.command], keyCode: 19)), "带 ⌘ 的交给菜单")
        XCTAssertFalse(session.control.handleKey(key("2", keyCode: 19, repeat: true)), "自动重复不触发")
        XCTAssertFalse(session.control.handleKey(key("x", keyCode: 7)), "没绑定的键交回响应链")
        XCTAssertEqual(session.control.hotkeyTable.bindings.count, 23, "默认表：10 数字 + 10 Shift 数字 + 空格 + 回车 + F")
    }

    func testShow_newSaveOpenRecentAndAutosave() throws {
        let suite = "com.plusmix.switcher.tests.show-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let docs = ShowDocuments(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-show-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var show = ShowDocuments.emptyShow(name: "测试节目")
        XCTAssertEqual(show.outputs.count, 1)
        XCTAssertEqual(show.outputs[0].kind, .record)
        XCTAssertNil(docs.currentURL)
        XCTAssertNil(docs.lastURL)
        XCTAssertEqual(docs.recentURLs, [])

        show.inputs = [AppTest.syntheticConfig(number: 3)]
        show.mixer.program = 3
        show.layout = ShowLayout(values: ["mixerPanelVisible": .bool(false)])
        let url = dir.appendingPathComponent("a.\(ShowDocuments.fileExtension)")
        try docs.save(show, to: url)
        XCTAssertEqual(docs.currentURL, url)
        XCTAssertEqual(docs.lastURL, url)
        XCTAssertEqual(docs.recentURLs, [url])

        let loaded = try docs.load(from: url)
        XCTAssertEqual(loaded, show, "保存 → 打开应原样")
        XCTAssertEqual(loaded.makeState().program, 3)

        let url2 = dir.appendingPathComponent("b.\(ShowDocuments.fileExtension)")
        try docs.save(show, to: url2)
        XCTAssertEqual(docs.recentURLs, [url2, url], "最近列表：最新在前")
        try docs.save(show, to: url)
        XCTAssertEqual(docs.recentURLs, [url, url2], "重复打开只提到最前")
        docs.startNew()
        XCTAssertNil(docs.currentURL)
        XCTAssertEqual(docs.lastURL, url, "上次文件仍记得")
        docs.clearRecents()
        XCTAssertEqual(docs.recentURLs, [])

        // 自动保存：退出时存、启动时读
        docs.autosave(show)
        XCTAssertEqual(docs.loadAutosave(), show)
    }

    /// 打开文件不自动起输出（G3 2026-09-19 定）：保存时录制 / 推流 enabled 的节目，load / loadAutosave 回来 enabled 都是 false，其余字段原样。
    func testShow_openedFileDoesNotAutoStartOutputs() throws {
        let suite = "com.plusmix.switcher.tests.show-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let docs = ShowDocuments(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-show-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var show = ShowDocuments.emptyShow(name: "录着存的")
        show.outputs[0].enabled = true
        show.outputs.append(OutputState(number: 2, kind: .stream, name: "推流", enabled: true,
                                        settings: OutputSettings(video: VideoEncodeSettings(), audio: AudioEncodeSettings(), stream: StreamSettings(url: "rtmp://127.0.0.1/live/x"))))
        let url = dir.appendingPathComponent("rec.\(ShowDocuments.fileExtension)")
        try docs.save(show, to: url)
        let loaded = try docs.load(from: url)
        XCTAssertEqual(loaded.outputs.map(\.enabled), [false, false])
        var expected = show
        expected.outputs[0].enabled = false
        expected.outputs[1].enabled = false
        XCTAssertEqual(loaded, expected, "只清 enabled，其余原样")
        docs.autosave(show)
        XCTAssertEqual(docs.loadAutosave()?.outputs.map(\.enabled), [false, false])
    }

    /// 通过 AppController：新建 → 加输入 → 写文件 → 打开回来，session 换成文件里的状态；布局键进 Show.layout。
    func testShow_controllerRoundTripReplacesSession() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 })
        let controller = AppTest.controller
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-show-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("round.\(ShowDocuments.fileExtension)")
        controller.write(session.makeShow(), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.documents.currentURL, url)
        let saved = try controller.documents.load(from: url)
        XCTAssertEqual(saved.inputs.count, 2)
        XCTAssertEqual(saved.mixer.program, 2)
        XCTAssertEqual(saved.layout.values["mixerPanelVisible"], .bool(true))
        XCTAssertNotNil(saved.layout.values["mainWindowFrame"])

        // 新建 → 空；打开 → 回来
        let done = AppTest.expectationBox()
        Task { await controller.newShow(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { done.value && controller.session?.isRunning == true })
        XCTAssertEqual(controller.session?.state.inputs.count, 0)
        XCTAssertTrue(controller.session !== session, "新建应换一个 session")
        let opened = AppTest.expectationBox()
        Task { await controller.openShow(url: url); opened.value = true }
        XCTAssertTrue(AppTest.waitUntil(15) { opened.value && controller.session?.isRunning == true })
        let reopened = try XCTUnwrap(controller.session)
        XCTAssertEqual(reopened.state.inputs.count, 2)
        XCTAssertEqual(reopened.state.program, 2)
        XCTAssertTrue(AppTest.waitUntil(10) { reopened.inputs.runtimeState(of: 1) == .live && reopened.inputs.runtimeState(of: 2) == .live }, "打开后输入应重新跑起来")
        XCTAssertEqual(AppTest.controller.windowController.inputStrip.cells.count, 2, "缩略图条应跟着新 session")
        XCTAssertEqual(AppTest.controller.windowController.window?.title, "PlusMix \(SwitcherVersion.current) — round", "窗口标题用产品名（W4-D）")
    }

    /// 还没实现的输入类型（DeckLink / NDI 在 W3-A）是占位：加进去不崩，格子显示提示；不存在的摄像头 uniqueID 是无信号（等它出现），不是占位。
    /// G4 合并前这条测的是"NDI 输入是带 W3-A 文案的占位"；W3-A 接上后（G4 胶水）源不在 = noSignal + 等它出现（W3-A 报告 §4 第 4 条的口径），
    /// 没 SDK 的机器上是 error + "NDI SDK 未编译进来" 文案；两种都不是"占位"。
    func testShow_ndiInputWithoutSourceWaitsAsNoSignal() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 5, name: "NDI 源", source: .ndi(sourceName: "MACHINE (src)"))))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.count == 1 })
        XCTAssertTrue(AppTest.waitUntil(5) {
            switch session.inputs.runtimeState(of: 5) {
            case .noSignal?: return true
            case .error(let m)?: return m.contains("SDK")
            default: return false
            }
        }, "NDI 源不在应是 noSignal（等源出现）或无 SDK 文案：\(String(describing: session.inputs.runtimeState(of: 5)))")
        XCTAssertEqual(AppTest.controller.windowController.inputStrip.cells[5]?.displayedName, "NDI 源")
        session.send(.removeInput(input: 5))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.isEmpty && session.inputs.runtimeState(of: 5) == nil })
        // 摄像头走真实现：uniqueID 不存在 → 无信号（热插拔会等它来）或权限文案，不是"占位"
        session.send(.addInput(config: InputConfig(number: 6, name: "相机", source: .camera(uniqueID: "fake"))))
        XCTAssertTrue(AppTest.waitUntil(5) {
            switch session.inputs.runtimeState(of: 6) {
            case .noSignal?: return true
            case .error(let m)?: return m.contains("权限")
            default: return false
            }
        }, "假 uniqueID 的摄像头应是无信号或权限文案：\(String(describing: session.inputs.runtimeState(of: 6)))")
        session.send(.removeInput(input: 6))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.isEmpty })
    }

    /// Add Input 表单模型：五种类型都能出 InputConfig；缺参数报错；空闲编号。
    func testAddInput_modelMakesConfigs() throws {
        var m = AddInputModel()
        m.number = 4
        XCTAssertEqual(try m.makeConfig().kind, .synthetic)
        XCTAssertEqual(try m.makeConfig().name, "合成 4 · 60")
        m.name = "  自定义 "
        XCTAssertEqual(try m.makeConfig().name, "  自定义 ")
        m.kind = .camera
        XCTAssertThrowsError(try m.makeConfig())
        m.cameraUniqueID = "cam-1"
        XCTAssertEqual(try m.makeConfig().source, .camera(uniqueID: "cam-1"))
        m.kind = .screen
        m.displayID = 7
        XCTAssertEqual(try m.makeConfig().source, .screen(target: .display(id: 7), frameRate: nil, captureAudio: false))
        m.kind = .file
        XCTAssertThrowsError(try m.makeConfig())
        m.filePath = "/tmp/a.mov"
        m.name = ""
        XCTAssertEqual(try m.makeConfig().source, .file(path: "/tmp/a.mov", endAction: .loop, rate: 1))
        XCTAssertEqual(try m.makeConfig().name, "a.mov")
        m.kind = .image
        m.imagePath = "/tmp/b.png"
        XCTAssertEqual(try m.makeConfig().source, .image(path: "/tmp/b.png"))
        // W3-E 补的三种：DeckLink / NDI / 纯音频设备（W3-E2：提案 008 的接口 / 带宽 / 抖动缓冲、014 的声道映射）
        m.kind = .decklink
        XCTAssertEqual(try m.makeConfig().source, .decklink(deviceID: ""), "空串 = 第一台有输入的卡（契约 InputSource.decklink 的口径）")
        m.decklinkDeviceID = "decklink-0"
        XCTAssertEqual(try m.makeConfig().source, .decklink(deviceID: "decklink-0"))
        m.decklinkConnection = .sdi
        m.decklinkChannels = [4, 5]
        XCTAssertEqual(try m.makeConfig().source, .decklink(deviceID: "decklink-0", connection: .sdi, channels: [4, 5]))
        m.kind = .ndi
        XCTAssertThrowsError(try m.makeConfig())
        m.ndiSourceName = "MACHINE (Cam)"
        XCTAssertEqual(try m.makeConfig().source, .ndi(sourceName: "MACHINE (Cam)"))
        m.ndiBandwidth = .lowest
        m.ndiJitterBufferFrames = 7
        XCTAssertEqual(try m.makeConfig().source, .ndi(sourceName: "MACHINE (Cam)", bandwidth: .lowest, jitterBufferFrames: 2), "抖动缓冲钳到 0–2 帧")
        m.kind = .audio
        XCTAssertEqual(try m.makeConfig().source, .audio(deviceUID: ""), "空串 uid = 跟随系统默认输入（W2-A2 口径）")
        m.audioDeviceUID = "AppleUSBAudioEngine:1"
        XCTAssertEqual(try m.makeConfig().source, .audio(deviceUID: "AppleUSBAudioEngine:1"))
        m.audioChannels = [4]
        XCTAssertEqual(try m.makeConfig().source, .audio(deviceUID: "AppleUSBAudioEngine:1", channels: [4]))
        // 屏幕：窗口 / 应用 + 帧率 + 系统音频
        m.kind = .screen
        m.screenKind = .window
        XCTAssertThrowsError(try m.makeConfig(), "还没选窗口")
        m.windowID = 4242
        m.screenFrameRate = .fps30
        m.captureAudio = true
        XCTAssertEqual(try m.makeConfig().source, .screen(target: .window(id: 4242), frameRate: .fps30, captureAudio: true))
        m.screenKind = .application
        m.applicationBundleID = "com.apple.Keynote"
        XCTAssertEqual(try m.makeConfig().source, .screen(target: .application(bundleID: "com.apple.Keynote"), frameRate: .fps30, captureAudio: true))
        // 合成源的全部参数
        m.kind = .synthetic
        m.syntheticBackground = .noise
        m.noiseAmplitude = 20
        m.noiseSeed = 9
        m.patternID = 5
        m.jitterMs = 2
        m.dropEveryN = 100
        m.clockDriftPpm = 50
        m.syntheticAudio = true
        m.audioDriftPpm = -30
        m.syntheticWidth = 1280
        m.syntheticHeight = 720
        if case .synthetic(let s) = try m.makeConfig().source {
            XCTAssertEqual(s, SyntheticSourceSettings(frameRate: .fps60, width: 1280, height: 720, background: .noise(level: 128, amplitude: 20, seed: 9),
                                                      patternID: 5, jitterMs: 2, dropEveryN: 100, clockDriftPpm: 50, audio: true, audioDriftPpm: -30))
        } else {
            XCTFail("应是合成源")
        }
        XCTAssertEqual(AddInputModel.Kind.allCases.count, 8, "设计方案 §6 的八种输入")
        XCTAssertEqual(AddInputModel.Kind.allCases.map(\.inputKind), [.synthetic, .camera, .decklink, .screen, .file, .image, .ndi, .audio])
        var state = MixerState()
        state.inputs = [AppTest.syntheticConfig(number: 1), AppTest.syntheticConfig(number: 2), AppTest.syntheticConfig(number: 4)]
        XCTAssertEqual(AddInputModel.nextFreeNumber(in: state, maxInputs: 16), 3)
        XCTAssertFalse(AddInputModel.cameras().contains { $0.name.isEmpty }, "摄像头列表（可以为空）")
        XCTAssertGreaterThanOrEqual(AddInputModel.displays().count, 1)
    }

    /// 输入设置窗"来源"一节复用 Add Input 的表单（W3-E2 交付第 6 条 / 提案 012）：从现有来源填回表单，再出来的来源逐字段相同。
    func testAddInput_modelRoundTripsExistingSources() throws {
        let sources: [InputSource] = [
            .camera(uniqueID: "cam-1"),
            .decklink(deviceID: "peid:42", connection: .hdmi, channels: [2, 3]),
            .decklink(deviceID: ""),
            .screen(target: .window(id: 77), frameRate: .fps30, captureAudio: true),
            .screen(target: .application(bundleID: "com.apple.Keynote"), frameRate: nil, captureAudio: false),
            .file(path: "/tmp/a.mov", endAction: .holdLastFrame, rate: 0.5),
            .image(path: "/tmp/b.png"),
            .ndi(sourceName: "HOST (Cam)", bandwidth: .audioOnly, jitterBufferFrames: 0),
            .audio(deviceUID: "BuiltInMicrophoneDevice", channels: [4, 5]),
            .audio(deviceUID: ""),
            .synthetic(settings: SyntheticSourceSettings(frameRate: .fps30, width: 1280, height: 720, background: .noise(level: 96, amplitude: 12, seed: 3),
                                                         patternID: 4, jitterMs: 1, dropEveryN: 0, clockDriftPpm: 10, audio: true, audioDriftPpm: 5)),
        ]
        for source in sources {
            var m = AddInputModel(source: source)
            m.number = 3
            m.name = "x"
            XCTAssertEqual(try m.makeConfig().source, source, "\(source)")
            XCTAssertEqual(m.kind.inputKind, source.kind)
        }
    }

    /// 声道映射（提案 014）的表单口径：前两路 / 选两路（左、右）/ 单声道一路；摘要"第 5、6 路"。
    func testAddInput_channelMapChoices() {
        XCTAssertEqual(ChannelMapChoice(channels: []).mode, .firstTwo)
        XCTAssertEqual(ChannelMapChoice(channels: [4, 5]).mode, .pair)
        XCTAssertEqual(ChannelMapChoice(channels: [4]).mode, .mono)
        var c = ChannelMapChoice(channels: [])
        c.mode = .pair
        XCTAssertEqual(c.channels, [0, 1], "切到选两路：默认第 1、2 路")
        c.left = 4
        c.right = 5
        XCTAssertEqual(c.channels, [4, 5])
        c.mode = .mono
        XCTAssertEqual(c.channels, [4], "单声道取左边那一路")
        c.mode = .firstTwo
        XCTAssertEqual(c.channels, [])
        XCTAssertEqual(ChannelMapChoice.summary([4, 5]), "第 5、6 路")
        XCTAssertEqual(ChannelMapChoice.summary([4]), "第 5 路（单声道）")
        XCTAssertEqual(ChannelMapChoice.summary([]), "")
        L10n.languageOverride = "en"
        defer { L10n.languageOverride = "zh-Hans" }
        XCTAssertEqual(ChannelMapChoice.summary([4, 5]), "channels 5, 6")
    }

    /// W3-E5 交付 3：退出时自动存的 LastSession 与 hotkeys.json / midi.json / Diagnostics/ 同一个配置目录（SwitcherControl 的 `UserConfig.directory`
    /// = ~/Library/Application Support/PlusMix，W2-C2 改的），App 不再自己拼 Application Support/Switcher（代码与注释都不留）；
    /// App 侧的 MIDI 锚（MIDINotificationAnchor）删了，热插拔通知由包里的进程级 MIDIHost 锚接管（守门用例 testMIDI_hotplugAfterShowReplaced_newSourceConnects）。
    func testW3E5_lastSessionLivesInUserConfigDirectory() throws {
        let url = ShowDocuments.autosaveURL
        XCTAssertEqual(url, UserConfig.directory.appending(path: "LastSession.\(ShowDocuments.fileExtension)"))
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        XCTAssertEqual(dir, HotkeyTable.defaultFileURL.deletingLastPathComponent().standardizedFileURL.path, "与 hotkeys.json 同目录")
        XCTAssertEqual(dir, MIDIMapTable.defaultFileURL.deletingLastPathComponent().standardizedFileURL.path, "与 midi.json 同目录")
        XCTAssertEqual(dir, CrashDiagnosticsStore.defaultDirectory.deletingLastPathComponent().standardizedFileURL.path, "与 Diagnostics/ 同目录")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "PlusMix")
        XCTAssertEqual(url.lastPathComponent, "LastSession.switcher.json")
        XCTAssertFalse(url.pathComponents.contains("Switcher"), url.path)

        let sources = try AppTest.repoRoot().appendingPathComponent("App/Sources")
        var stale: [String] = []
        for file in try AppTest.swiftFiles(in: sources) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("Application Support/Switcher") || line.contains("MIDINotificationAnchor") {
                stale.append("\(file.lastPathComponent):\(i + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(stale, [], "旧目录 / 旧锚仍在：\n" + stale.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent("Engine/MIDINotificationAnchor.swift").path), "App 侧的锚应删掉")
    }
}

@MainActor
final class AddInputSheetTests: XCTestCase {
    /// 设备列表（W3-E2 交付第 7 条 / 提案 008）：纯音频页第一项"系统默认输入"（空串 uid，默认选它），用 SwitcherInputs.AudioInputDevices 列、
    /// 插拔时刷新（observeChanges，关表单时 stop）；DeckLink 页第一项"第一台有输入的卡"（空串）；接口下拉按卡支持的列，不知道时列全部。
    func testAddInput_formDeviceListsHaveDefaultEntries() throws {
        let form = AddInputFormModel(state: MixerState(), maxInputs: 16)
        XCTAssertEqual(form.audioDevices.first?.id, "")
        XCTAssertEqual(form.audioDevices.first?.title, "系统默认输入")
        XCTAssertEqual(form.model.audioDeviceUID, "", "默认选系统默认输入")
        XCTAssertTrue(form.isObservingAudioDevices, "插拔要刷新列表")
        XCTAssertEqual(form.audioDevices.count - 1, AudioInputDevices.list().filter { $0.inputChannels > 0 }.count)
        XCTAssertEqual(form.decklinkDevices.first?.id, "")
        XCTAssertEqual(form.decklinkConnections(for: "不存在的卡"), DeckLinkConnection.allCases, "卡不在：接口全列")
        XCTAssertEqual(form.decklinkChannelCount, 16, "内嵌音频 1–16 路")
        form.close()
        XCTAssertFalse(form.isObservingAudioDevices, "关表单时 stop 订阅")
    }

    /// Sheet 真的能弹出、切类型、取消；截图留档（AppKit 内容）。
    func testAddInput_sheetPresentsSwitchesKindsAndCancels() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let wc = AppTest.controller.windowController
        let window = try XCTUnwrap(wc.window)
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil }, "应弹出 sheet")
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.title, "添加输入")
        let controller = try XCTUnwrap(sheet.windowController as? AddInputSheetController)
        XCTAssertEqual(controller.model.number, 2, "默认编号 = 最小空闲编号")
        XCTAssertEqual(controller.model.kind, .synthetic)
        AppTest.pump(seconds: 0.3)
        // TEST_RUNNER_SWITCHER_HOLD=秒：让 sheet 停一会儿，好从外面用 screencapture 截真图（cacheDisplay 截不到 AppKit 的 SwiftUI 底控件）
        if let hold = ProcessInfo.processInfo.environment["SWITCHER_HOLD"].flatMap(Double.init) { AppTest.pump(seconds: hold) }
        // 走一遍五种类型的表单都建得出来
        for kind in AddInputModel.Kind.allCases {
            controller.selectKindForTesting(kind)
            AppTest.pump(seconds: 0.05)
            XCTAssertEqual(controller.model.kind, kind)
        }
        controller.cancelForTesting()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil }, "取消应收起 sheet")
        XCTAssertEqual(session.state.inputs.count, 1, "取消不加输入")
        // 确定：默认合成源 → 加了 2 号
        wc.presentAddInput()
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet != nil })
        let c2 = try XCTUnwrap(window.attachedSheet?.windowController as? AddInputSheetController)
        c2.confirmForTesting()
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.count == 2 && session.state.input(2)?.kind == .synthetic }, "确定应加一路合成源")
        XCTAssertTrue(AppTest.waitUntil(3) { window.attachedSheet == nil })
    }

}
