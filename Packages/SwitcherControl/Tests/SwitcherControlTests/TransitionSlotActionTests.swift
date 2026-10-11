import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// 转场槽的控制层动作（W5-M，prompt 100 交付 3；01a N6，04 Q29）：执行转场 n、选中转场 n（不执行），默认表 ⌥1–⌥4 = 执行转场 1–4、
/// 回车 = 执行当前槽，MIDI 音符同一套动作，选动作面板按 ControlActionKind 的目录归进"切换"组。
final class TransitionSlotActionTests: XCTestCase {
    /// 默认表 ⌥1–⌥4 = 执行转场 1–4：一条 useTransitionSlot(n, start: true)，一拍内选中并开始；转场进行中再按被状态机忽略；回车 = 按当前槽执行。
    func testHotkeys_optionDigitExecutesSlot() async throws {
        let t = HotkeyTable.default
        for n in 1...4 {
            XCTAssertEqual(t.action(for: KeyCombo(key: String(n), modifiers: [.option])), .transitionSlot(slot: n), "⌥\(n) = 执行转场 \(n)")
        }
        XCTAssertEqual(t.action(for: KeyCombo("return")!), .command(.autoTransition), "回车 = 执行当前槽（当前那组就是当前槽的配置）")
        XCTAssertTrue(t.conflicts().isEmpty)
        XCTAssertEqual(t.bindings.count, 10 + 10 + 3 + 4 + 4)

        let f = BusFixture()
        defer { f.stop() }
        let d = HotkeyDispatcher(bus: f.bus)
        let before = f.bus.lastSequence
        let receipts = try await d.handleAllAndWait(KeyCombo("alt+3")!)
        XCTAssertEqual(receipts.map(\.applied), [true], "⌥3 一条命令就选中并开始")
        let entries = f.bus.recentEntries().filter { $0.sequence > before }
        XCTAssertEqual(entries.map(\.command), [.useTransitionSlot(slot: 3, start: true)])
        XCTAssertEqual(entries.map(\.source), [.hotkey])
        var s = await f.stateMachine.state
        XCTAssertEqual(s.transition.currentSlot, 3, "执行过的槽成了当前槽（T-bar / 回车跟它）")
        XCTAssertEqual(s.transition.type, .zoom, "出厂槽 3 = Zoom")
        XCTAssertEqual(s.transition.durationTicks, 60, "Zoom 1 s @ 60 = 60 拍")
        XCTAssertTrue(s.transition.isActive, "start = true：同一拍开始")

        // 转场进行中按 ⌥1：状态机忽略（与 autoTransition 同口径），当前槽不变
        let busy = try await d.handleAllAndWait(KeyCombo("alt+1")!)
        XCTAssertEqual(busy.map(\.applied), [false], "转场进行中再执行别的槽被忽略")
        s = await f.stateMachine.state
        XCTAssertEqual(s.transition.currentSlot, 3)

        // 回车 = 按当前槽（3 · Zoom）再做一次：没有渲染线程，手动推拍把这次做完
        await f.stateMachine.prepare(upTo: Tick(80))
        s = await f.stateMachine.state
        XCTAssertFalse(s.transition.isActive)
        XCTAssertEqual(s.program, 2, "Zoom 做完，PGM = 原 PVW（2）")
        let enter = try await d.handleAllAndWait(KeyCombo("return")!)
        XCTAssertEqual(enter.map(\.applied), [true])
        s = await f.stateMachine.state
        XCTAssertEqual(s.transition.type, .zoom, "回车用的是当前槽 3 的 Zoom")
        XCTAssertEqual(s.transition.currentSlot, 3)
        XCTAssertTrue(s.transition.isActive)
        XCTAssertEqual(d.counters.rejected, 0)
    }

    /// 选中转场 n（不执行）= useTransitionSlot(n, start: false)：只换当前槽，PGM / PVW 不动；槽号不在 1–4 解析不出（不发）。
    func testHotkeys_selectSlotWithoutExecuting() async throws {
        let s0 = TestStates.base()
        XCTAssertEqual(ControlAction.selectTransitionSlot(slot: 2).resolve(in: s0), [.useTransitionSlot(slot: 2, start: false)])
        XCTAssertEqual(ControlAction.transitionSlot(slot: 4).resolve(in: s0), [.useTransitionSlot(slot: 4, start: true)])
        XCTAssertEqual(ControlAction.transitionSlot(slot: 0).resolve(in: s0), [], "槽号不在 1–4：不发（校验器会拒）")
        XCTAssertEqual(ControlAction.selectTransitionSlot(slot: 5).resolve(in: s0), [])

        let f = BusFixture()
        defer { f.stop() }
        let d = HotkeyDispatcher(bus: f.bus, table: HotkeyTable(bindings: [
            HotkeyBinding(key: KeyCombo("ctrl+alt+2")!, action: .selectTransitionSlot(slot: 2)),
            HotkeyBinding(key: KeyCombo("ctrl+alt+9")!, action: .transitionSlot(slot: 9)),
        ]))
        let receipts = try await d.handleAllAndWait(KeyCombo("ctrl+alt+2")!)
        XCTAssertEqual(receipts.map(\.applied), [true])
        let s = await f.stateMachine.state
        XCTAssertEqual(s.transition.currentSlot, 2)
        XCTAssertEqual(s.transition.type, .wipe, "出厂槽 2 = Wipe")
        XCTAssertFalse(s.transition.isActive, "只选中、不执行")
        XCTAssertEqual(s.program, 1)
        XCTAssertEqual(s.preview, 2)
        let none = try await d.handleAllAndWait(KeyCombo("ctrl+alt+9")!)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(d.counters.unresolved, 1, "槽号不对 = 解析不出")
    }

    /// JSON：{"transitionSlot": {"slot": 2}} / {"selectTransitionSlot": {"slot": 4}}；MIDI 音符同一套动作；目录（面板的参数表单、小字、分组）。
    func testHotkeys_slotActionsJSONMIDIAndCatalog() throws {
        let table = HotkeyTable(bindings: [
            HotkeyBinding(key: KeyCombo("alt+shift+2")!, action: .transitionSlot(slot: 2)),
            HotkeyBinding(key: KeyCombo("alt+shift+4")!, action: .selectTransitionSlot(slot: 4)),
        ])
        let data = try table.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"transitionSlot\""), text)
        XCTAssertTrue(text.contains("\"selectTransitionSlot\""), text)
        XCTAssertTrue(text.contains("\"slot\" : 2"), text)
        XCTAssertEqual(try HotkeyTable.load(from: data), table)
        let hand = #"{"version":1,"bindings":[{"key":"alt+shift+3","action":{"transitionSlot":{"slot":3}}}]}"#
        XCTAssertEqual(try HotkeyTable.load(from: Data(hand.utf8)).bindings[0].action, .transitionSlot(slot: 3))
        XCTAssertThrowsError(try HotkeyTable.load(from: Data(#"{"version":1,"bindings":[{"key":"x","action":{"transitionSlot":{}}}]}"#.utf8)), "缺 slot")

        // MIDI 音符：按下 = 执行转场 4，松开不发
        var m = MIDIMapper(table: MIDIMapTable(mappings: [
            MIDIMapping(trigger: .note(channel: 1, note: 40), action: .action(.transitionSlot(slot: 4))),
            MIDIMapping(trigger: .note(channel: 1, note: 41), action: .action(.selectTransitionSlot(slot: 1))),
        ]))
        let s = TestStates.base()
        XCTAssertEqual(m.commands(for: MIDIMessage(trigger: .note(channel: 1, note: 40), value: 100, timestamp: .zero), state: s),
                       [.useTransitionSlot(slot: 4, start: true)])
        XCTAssertEqual(m.commands(for: MIDIMessage(trigger: .note(channel: 1, note: 40), value: 0, isNoteOff: true, timestamp: .zero), state: s), [])
        XCTAssertEqual(m.commands(for: MIDIMessage(trigger: .note(channel: 1, note: 41), value: 90, timestamp: .zero), state: s),
                       [.useTransitionSlot(slot: 1, start: false)])
        XCTAssertEqual(try MIDIMapTable.load(from: try m.table.jsonData()), m.table)

        // 目录：参数 = 槽号（四段）、发 useTransitionSlot、归"切换"
        for kind in [ControlActionKind.transitionSlot, .selectTransitionSlot] {
            XCTAssertEqual(kind.fields, [CommandField(name: "slot", type: .transitionSlot)], "\(kind)")
            XCTAssertEqual(kind.emits, [.useTransitionSlot], "\(kind)")
            XCTAssertEqual(kind.group, "切换", "\(kind)")
        }
        XCTAssertEqual(ControlActionKind(of: .transitionSlot(slot: 1)), .transitionSlot)
        XCTAssertEqual(ControlActionKind(of: .selectTransitionSlot(slot: 1)), .selectTransitionSlot)
    }
}
