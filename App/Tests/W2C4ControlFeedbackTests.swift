// W2-C4（prompt 116）App 侧唯一一条用例：MIDI 的 029 提示接到状态行（ControlRuntime 接 MIDIController.setFeedbackHandler，回主线程）。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class W2C4ControlFeedbackTests: XCTestCase {
    /// MIDI 音符执行没选输入的 Stinger 槽（出厂槽 4）→ 校验器拒（提案 029）→ 状态行与快捷键同一句"转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路"，
    /// PGM / PVW 不动、没执行（原来照常被拒、但状态行什么都不说：reports/w5-app-followups.md §3 第 2 条）。真 CoreMIDI：虚拟源发 Note On。
    func testW2C4_midiStingerSlotRefusalShowsStatusLineNotice() throws {
        let midiName = "PlusMix Stinger 提示 \(UUID().uuidString.prefix(6))"
        let midiSource = try? VirtualMIDISource(name: midiName)   // 起 session 之前建：起的时候枚举现有源
        defer { midiSource?.dispose() }
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 3)
        let controller = AppTest.controller
        let midi = session.control.midi
        guard let midiSource, midi.isRunning else { throw XCTSkip("BLOCKED-MIDI：MIDI 控制器没起来（\(session.control.midiError ?? "?")）") }
        XCTAssertTrue(AppTest.waitUntil(5) { midi.sources.contains { $0.name == midiName && $0.connected } }, "起 session 时应连上虚拟源：\(midi.sources.map(\.name))")
        try controller.applyMIDITable(MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.transitionSlot(slot: 4)))]))
        defer { try? controller.applyMIDITable(MIDIMapTable(mappings: [])) }
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        XCTAssertTrue(session.state.transition.slots[3].isStingerWithoutInput, "出厂槽 4 = Stinger、没选输入")
        let expected = L("feedback.stingerSlotWithoutInput", 4)
        XCTAssertEqual(expected, "转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路")
        let bar = controller.windowController.bottomBar
        AppTest.pump(seconds: 0.1)
        bar.showNotice("")
        let rejected = midi.counters.rejected

        try midiSource.send(noteOn: 60, velocity: 100)
        XCTAssertTrue(AppTest.waitUntil(3) { session.lastNotice == expected }, "状态行：\(session.lastNotice ?? "nil")")
        XCTAssertEqual(bar.displayedNotice, expected, "底栏状态行显示同一句")
        XCTAssertEqual(midi.counters.rejected, rejected + 1, "照常被拒")
        XCTAssertFalse(session.state.transition.isActive, "没执行")
        XCTAssertEqual(session.state.program, 1, "PGM 不动")
        XCTAssertEqual(session.state.preview, 2, "PVW 不动")
        try midiSource.send(noteOff: 60)
    }
}
