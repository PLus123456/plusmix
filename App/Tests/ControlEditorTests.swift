// W3-E 交付第 6 条：快捷键编辑器、MIDI 映射面板（learn）。
// 表存在用户配置目录（节目文件之外）；测试宿主指到临时目录（AppController.hotkeyFileURL / midiFileURL），不碰 ~/Library。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class ControlEditorTests: XCTestCase {
    func testHotkeyEditor_addBindingConflictSaveApplyAndRecord() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        let controller = AppTest.controller
        XCTAssertTrue(controller.hotkeyFileURL.path.contains("switcher-tests"), "测试宿主的表文件在临时目录：\(controller.hotkeyFileURL.path)")
        let editor = controller.panels.showHotkeyEditor()
        let model = editor.model
        model.resetToDefault()   // 别的测试可能已经存过表
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.rows.count, 23, "默认表 23 条")
        XCTAssertTrue(model.conflicts.isEmpty)

        // 加一条 k → Cut；再加一条 k → FTB 就冲突，存不了
        model.addRow(key: "k", action: .command(.cut))
        XCTAssertTrue(model.conflicts.isEmpty)
        model.addRow(key: "K", action: .toggleFTB)
        XCTAssertEqual(model.conflicts.count, 1, "同一组合键（大小写无关）应冲突")
        XCTAssertFalse(model.save(), "有冲突不许存")
        XCTAssertNotNil(model.errorMessage)
        model.removeRow(model.rows.last!.id)
        XCTAssertTrue(model.conflicts.isEmpty)
        // 认不出的键：报错不存
        model.addRow(key: "cmd+", action: .command(.cut))
        XCTAssertFalse(model.save())
        model.removeRow(model.rows.last!.id)
        XCTAssertTrue(model.save(), "\(model.errorMessage ?? "")")
        XCTAssertNil(model.errorMessage)

        // 文件落盘、派发器换表、AppController 的表也换了（下次起 session 用）
        let saved = try HotkeyTable.load(from: controller.hotkeyFileURL)
        XCTAssertEqual(saved.action(for: KeyCombo(key: "k")), .command(.cut))
        XCTAssertEqual(session.control.hotkeys.table, saved)
        XCTAssertEqual(controller.hotkeyTable, saved)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        AppTest.press("k", keyCode: 40)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 && session.state.preview == 1 }, "新绑定的 k 应 Cut")

        // 录键：开始录后，编辑器窗口收到的下一个按键写进那一行
        let row = model.rows.last!.id
        model.beginRecording(row)
        XCTAssertEqual(model.recordingRow, row)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .command], timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
                                     context: nil, characters: "J", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        XCTAssertTrue(editor.handleRecordingKey(event))
        XCTAssertNil(model.recordingRow, "录完自动退出")
        XCTAssertEqual(model.rows.last?.keyText, "shift+cmd+j")
        // 动作编辑：换成 toggleOverlay(2)
        model.setAction(row, .toggleOverlay(channel: 2))
        XCTAssertEqual(model.rows.last?.action, .toggleOverlay(channel: 2))
        XCTAssertTrue(model.save())
        XCTAssertEqual(session.control.hotkeys.table.action(for: KeyCombo(key: "j", modifiers: [.shift, .command])), .toggleOverlay(channel: 2))

        // 恢复默认表并存
        model.resetToDefault()
        XCTAssertEqual(model.rows.count, 23)
        XCTAssertTrue(model.save())
        XCTAssertEqual(session.control.hotkeys.table, .default)
        XCTAssertNil(session.control.hotkeys.table.action(for: KeyCombo(key: "k")))
        // 每种动作都能来回：行 ↔ ControlAction
        for action in HotkeyEditorModel.sampleActions {
            let row = HotkeyEditorModel.Row(keyText: "x", action: action, note: "")
            XCTAssertEqual(row.action, action)
            XCTAssertFalse(HotkeyEditorModel.describe(action).isEmpty)
        }
    }

    func testMIDIMapping_learnFromVirtualSourceAndSave() throws {
        // 虚拟源要在 session 起来之前建：CoreMIDI 的热插拔通知只送到进程里第一次 MIDIClientCreate 时的 run loop，第一个 session 的
        // MIDI 线程停了之后再建的源收不到通知（W2-C 的坑，reports/issues/W3E-w2-control-midi-hotplug-after-restart.md）；起 session 时会枚举现有源
        let name = "Switcher 测试源 \(UUID().uuidString.prefix(6))"
        let source = try VirtualMIDISource(name: name)
        defer { source.dispose() }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        let controller = AppTest.controller
        let midi = session.control.midi
        guard midi.isRunning else { throw XCTSkip("BLOCKED-MIDI：MIDI 控制器没起来（\(session.control.midiError ?? "?")）") }
        XCTAssertTrue(controller.midiFileURL.path.contains("switcher-tests"))
        let editor = controller.panels.showMIDIMapping()
        let model = editor.model
        for r in model.rows { model.removeRow(r.id) }   // 别的测试可能已经存过映射
        XCTAssertTrue(model.save())
        XCTAssertEqual(model.rows.count, 0, "没有默认 MIDI 映射：设备各不相同，用 learn 配")

        XCTAssertTrue(AppTest.waitUntil(5) { midi.sources.contains { $0.name == name && $0.connected } }, "起 session 时应连上已有的虚拟源：\(midi.sources)")
        XCTAssertTrue(AppTest.waitUntil(3) { model.sources.contains { $0.name == name } }, "面板应列出来源")

        // learn：下一条 CC 写进那一行的触发；期间不派发
        model.addRow()
        let row = model.rows[0].id
        model.learn(row: row)
        XCTAssertEqual(model.learningRow, row)
        XCTAssertTrue(midi.isLearning)
        let before = session.control.bus.counters.applied
        try source.send(cc: 9, value: 33, channel: 3)
        XCTAssertTrue(AppTest.waitUntil(3) { model.rows[0].trigger == .cc(channel: 3, controller: 9) }, "learn 应填上 CC 9 @ ch3：\(String(describing: model.rows[0].trigger))")
        XCTAssertNil(model.learningRow)
        XCTAssertEqual(session.control.bus.counters.applied, before, "learn 期间的消息不派发")
        model.setAction(row, .tbar)
        XCTAssertTrue(model.save(), "\(model.errorMessage ?? "")")
        XCTAssertEqual(midi.table.mapping(for: .cc(channel: 3, controller: 9))?.action, .tbar)
        XCTAssertEqual(try MIDIMapTable.load(from: controller.midiFileURL).mappings.count, 1)

        // 学到的映射真的驱动 T-bar
        try source.send(cc: 9, value: 64, channel: 3)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.transition.source == .tbar && abs(session.state.transition.progress - 64.0 / 127.0) < 1e-6 },
                      "CC 9 应推 T-bar：\(session.state.transition)")
        try source.send(cc: 9, value: 0, channel: 3)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.transition.progress == 0 })

        // 冲突：同一触发两条 → 存不了；改成 Note 就行；无效通道也报错
        model.addRow(trigger: .cc(channel: 3, controller: 9), action: .action(.command(.cut)))
        XCTAssertFalse(model.save())
        XCTAssertNotNil(model.errorMessage)
        let second = model.rows[1].id
        model.setTrigger(second, .note(channel: 1, note: 60))
        XCTAssertTrue(model.save())
        model.setTrigger(second, .note(channel: 17, note: 60))
        XCTAssertFalse(model.save(), "通道 17 非法")
        model.removeRow(second)
        XCTAssertTrue(model.save())
        XCTAssertEqual(midi.table.mappings.count, 1)
        // 取消 learn
        model.learn(row: row)
        model.cancelLearn()
        XCTAssertFalse(midi.isLearning)
        XCTAssertNil(model.learningRow)
        // 动作种类都能描述
        for a in MIDIMappingModel.sampleActions { XCTAssertFalse(MIDIMappingModel.describe(a).isEmpty) }
    }
}
