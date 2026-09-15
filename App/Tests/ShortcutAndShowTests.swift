// 快捷键默认表（KeyCommandMap）和节目文件（ShowDocuments：新建 / 保存 / 打开 / 最近 / 上次 / 自动保存）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class ShortcutAndShowTests: XCTestCase {
    private func key(_ chars: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = [], repeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: `repeat`, keyCode: 0)!
    }

    func testShortcuts_defaultTable() {
        var state = MixerState()
        state.transition.durationTicks = 45
        state.ftb.on = true
        XCTAssertEqual(KeyCommandMap.command(for: key("2"), state: state), .setPreview(input: 2))
        XCTAssertEqual(KeyCommandMap.command(for: key("0"), state: state), .setPreview(input: 10))
        XCTAssertEqual(KeyCommandMap.command(for: key("@", ignoring: "2", flags: [.shift]), state: state), .setProgram(input: 2))
        XCTAssertEqual(KeyCommandMap.command(for: key(" "), state: state), .cut)
        XCTAssertEqual(KeyCommandMap.command(for: key("\r"), state: state), .fade(durationTicks: 45), "回车用当前时长")
        XCTAssertEqual(KeyCommandMap.command(for: key("f"), state: state), .ftb(on: false), "FTB 是开关")
        XCTAssertEqual(KeyCommandMap.command(for: key("F", ignoring: "f", flags: [.shift]), state: state), .ftb(on: false))
        XCTAssertNil(KeyCommandMap.command(for: key("2", flags: [.command]), state: state), "带 ⌘ 的交给菜单")
        XCTAssertNil(KeyCommandMap.command(for: key("2", repeat: true), state: state), "自动重复不触发")
        XCTAssertNil(KeyCommandMap.command(for: key("x"), state: state))
        XCTAssertEqual(KeyCommandMap.table.count, 5)
    }

    func testShow_newSaveOpenRecentAndAutosave() throws {
        let suite = "com.example.switcher.tests.show-\(UUID().uuidString)"
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
        XCTAssertEqual(AppTest.controller.windowController.window?.title, "Switcher \(SwitcherVersion.current) — round")
    }

    /// 摄像头等 W2-A 的输入现在是占位：加进去不崩，格子显示提示。
    func testShow_unsupportedInputKindIsPlaceholder() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: InputConfig(number: 5, name: "相机", source: .camera(uniqueID: "fake"))))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.count == 1 })
        XCTAssertTrue(AppTest.waitUntil(5) {
            if case .error? = session.inputs.runtimeState(of: 5) { return true }
            return false
        }, "W2-A 合并前摄像头输入应是带文案的占位：\(String(describing: session.inputs.runtimeState(of: 5)))")
        XCTAssertEqual(AppTest.controller.windowController.inputStrip.cells[5]?.displayedName, "相机")
        session.send(.removeInput(input: 5))
        XCTAssertTrue(AppTest.waitUntil(5) { session.state.inputs.isEmpty && session.inputs.runtimeState(of: 5) == nil })
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
        var state = MixerState()
        state.inputs = [AppTest.syntheticConfig(number: 1), AppTest.syntheticConfig(number: 2), AppTest.syntheticConfig(number: 4)]
        XCTAssertEqual(AddInputModel.nextFreeNumber(in: state, maxInputs: 16), 3)
        XCTAssertFalse(AddInputModel.cameras().contains { $0.name.isEmpty }, "摄像头列表（可以为空）")
        XCTAssertGreaterThanOrEqual(AddInputModel.displays().count, 1)
    }
}
