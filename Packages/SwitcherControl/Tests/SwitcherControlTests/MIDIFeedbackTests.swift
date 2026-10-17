import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// W2-C4（prompt 116，reports/w5-app-followups.md §3 第 2 条）：MIDI 音符执行没选输入的 Stinger 槽被校验器拒（提案 029，P5-3）——照常没执行，
/// 但原来不提示（W5-O 只给 HotkeyDispatcher 接了 ControlFeedback，MIDI/ 不在它的目录）。现在 MIDIController.setFeedbackHandler 照 HotkeyDispatcher：
/// 同一个 ControlFeedback，被拒时（派发 Task 里）给 .stingerWithoutInput(slot:)、解析不出时（接收线程上）给 .overlayNeedsPreview(channel:)，别的拒绝不说。
final class MIDIFeedbackTests: XCTestCase {
    func testW2C4_midiNoteRunningStingerSlotWithoutInputGivesFeedback() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let ready = await waitUntil { f.stateMachine.publisher.latest != nil }
        XCTAssertTrue(ready)
        let base = try XCTUnwrap(f.stateMachine.publisher.latest?.state)
        XCTAssertTrue(base.transition.slots[3].isStingerWithoutInput, "出厂槽 4 = Stinger、没选输入")
        let table = MIDIMapTable(mappings: [
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.transitionSlot(slot: 4))),
            MIDIMapping(trigger: .note(channel: 1, note: 61), action: .action(.command(.autoTransition))),
            MIDIMapping(trigger: .note(channel: 1, note: 62), action: .action(.toggleOverlay(channel: 1))),
            MIDIMapping(trigger: .note(channel: 1, note: 63), action: .action(.command(.setPreview(input: 9)))),
        ])
        let controller = MIDIController(bus: f.bus, table: table, clientName: "Switcher 反馈测试 \(UUID().uuidString.prefix(8))")
        let got = Mutex<[ControlFeedback]>([])
        controller.setFeedbackHandler { fb in got.withLock { $0.append(fb) } }
        do { try controller.start() } catch {
            throw XCTSkip("CoreMIDI 不可用：\(error)")
        }
        defer { controller.stop() }

        // 真 CoreMIDI 路径：虚拟源发 Note On 60 → 执行转场 4 → 校验器拒 → 反馈带槽号；PGM / PVW 不动、没执行
        let name = "Switcher 反馈源 \(UUID().uuidString.prefix(8))"
        let source = try VirtualMIDISource(name: name)
        defer { source.dispose() }
        let connected = await waitUntil(timeout: 5) { controller.sources.contains { $0.name == name && $0.connected } }
        XCTAssertTrue(connected, "虚拟源应被自动连接：\(controller.sources)")
        try source.send(noteOn: 60, velocity: 100, channel: 1)
        var ok = await waitUntil { got.withLock { $0 } == [.stingerWithoutInput(slot: 4)] }
        XCTAssertTrue(ok, "反馈：\(got.withLock { $0 })")
        XCTAssertEqual(controller.counters.rejected, 1)
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, base.program, "PGM 不动")
        XCTAssertEqual(state.preview, base.preview)
        XCTAssertFalse(state.transition.isActive, "没执行")

        // 当前槽选成 4（只选中照常）再执行当前槽（autoTransition）：同样拒、同一句
        _ = try await f.bus.submit(.useTransitionSlot(slot: 4, start: false), source: .ui)
        controller.handle(MIDIMessage(trigger: .note(channel: 1, note: 61), value: 100, timestamp: .zero))
        ok = await waitUntil { got.withLock { $0 }.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(got.withLock { $0 }.last, .stingerWithoutInput(slot: 4))
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, base.program, "PGM 不动")

        // 别的拒绝（输入 9 不存在）不说，只记计数
        controller.handle(MIDIMessage(trigger: .note(channel: 1, note: 63), value: 100, timestamp: .zero))
        ok = await waitUntil { controller.counters.rejected == 3 }
        XCTAssertTrue(ok)
        XCTAssertEqual(got.withLock { $0 }.count, 2, "输入不存在：不给这句")

        // 解析不出（叠加 1 没指定输入、PVW 也是黑场）：照 ⌃n 那一句，一条都不发
        _ = try await f.bus.submit(.setPreview(input: MixerState.noInput), source: .ui)
        let sequence = f.bus.lastSequence
        controller.handle(MIDIMessage(trigger: .note(channel: 1, note: 62), value: 100, timestamp: .zero))
        XCTAssertEqual(got.withLock { $0 }.last, .overlayNeedsPreview(channel: 1), "接收线程上同步给")
        XCTAssertEqual(f.bus.lastSequence, sequence, "一条都不发")

        // Note Off 不算按下：不派发、不提示
        controller.handle(MIDIMessage(trigger: .note(channel: 1, note: 60), value: 0, isNoteOff: true, timestamp: .zero))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(got.withLock { $0 }.count, 3)

        // 槽 4 选了输入：照常执行，不再提示
        _ = try await f.bus.submit(.setPreview(input: 2), source: .ui)
        var slot4 = state.transition.slots[3]
        slot4.stinger.input = 3
        _ = try await f.bus.submit(.setTransitionSlot(slot: 4, config: slot4), source: .ui)
        try source.send(noteOn: 60, velocity: 100, channel: 1)
        ok = await waitUntil { f.stateMachine.publisher.latest?.state.transition.isActive == true }
        XCTAssertTrue(ok, "选了输入：执行")
        XCTAssertEqual(got.withLock { $0 }.count, 3)
    }
}
