import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl
#if canImport(AppKit)
import AppKit
#endif

/// 快捷键：组合键解析 / 归一化、表的 JSON 往返、默认表（设计方案 §9.4 / W2-B）、冲突检测、动作解析（含开关型）、派发到总线。
final class HotkeyTests: XCTestCase {
    // MARK: KeyCombo

    func testHotkey_keyComboParsesAliasesAndNormalizes() {
        let cases: [(String, KeyCombo?)] = [
            ("1", KeyCombo(key: "1")),
            ("shift+1", KeyCombo(key: "1", modifiers: [.shift])),
            ("Shift+1", KeyCombo(key: "1", modifiers: [.shift])),
            ("⇧1", KeyCombo(key: "1", modifiers: [.shift])),
            ("cmd+shift+f", KeyCombo(key: "f", modifiers: [.command, .shift])),
            ("shift+cmd+F", KeyCombo(key: "f", modifiers: [.command, .shift])),   // 顺序、大小写无关
            ("⌘⌥⌃⇧a", KeyCombo(key: "a", modifiers: [.command, .option, .control, .shift])),
            ("ctrl+alt+space", KeyCombo(key: "space", modifiers: [.control, .option])),
            ("Return", KeyCombo(key: "return")),
            ("enter", KeyCombo(key: "return")),
            ("esc", KeyCombo(key: "escape")),
            ("F5", KeyCombo(key: "f5")),
            ("up", KeyCombo(key: "up")),
            ("", nil),
            ("shift+", nil),
            ("foo+1", nil),
            ("shift", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(KeyCombo(text), expected, "解析「\(text)」")
        }
        XCTAssertEqual(KeyCombo(key: "1", modifiers: [.shift, .command]).description, "shift+cmd+1")
        XCTAssertEqual(KeyCombo("⌘⌥⌃⇧a")!.description, "ctrl+alt+shift+cmd+a", "描述的修饰键顺序固定")
        // 往返
        for text in ["1", "shift+1", "ctrl+alt+shift+cmd+a", "space", "return", "f12"] {
            let c = KeyCombo(text)!
            XCTAssertEqual(KeyCombo(c.description), c)
        }
    }

    // MARK: 表

    func testHotkey_defaultTableMatchesDesignAndHasNoConflicts() {
        let t = HotkeyTable.default
        XCTAssertTrue(t.conflicts().isEmpty)
        XCTAssertEqual(t.action(for: KeyCombo("1")!), .command(.setPreview(input: 1)))
        XCTAssertEqual(t.action(for: KeyCombo("9")!), .command(.setPreview(input: 9)))
        XCTAssertEqual(t.action(for: KeyCombo("0")!), .command(.setPreview(input: 10)))
        XCTAssertEqual(t.action(for: KeyCombo("shift+1")!), .command(.setProgram(input: 1)))
        XCTAssertEqual(t.action(for: KeyCombo("shift+0")!), .command(.setProgram(input: 10)))
        XCTAssertEqual(t.action(for: KeyCombo("space")!), .command(.cut))
        XCTAssertEqual(t.action(for: KeyCombo("return")!), .command(.autoTransition))
        XCTAssertEqual(t.action(for: KeyCombo("f")!), .toggleFTB)
        XCTAssertNil(t.action(for: KeyCombo("cmd+q")!))
        XCTAssertEqual(t.bindings.count, 10 + 10 + 3 + 4 + 4, "W5-J 按 04 Q29 补了 ⌥1–⌥4（执行转场）与 ⌃1–⌃4（叠加开关），见 ControlActionTests")
    }

    func testHotkey_tableJSONRoundTripAndUserFile() throws {
        let t = HotkeyTable.default
        let data = try t.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"key\" : \"shift+1\""), "组合键在 JSON 里是字符串")
        XCTAssertTrue(text.contains("\"toggleFTB\""))
        let back = try HotkeyTable.load(from: data)
        XCTAssertEqual(back, t)
        // 用户文件：写、读、缺省位置在 Show 之外
        let dir = FileManager.default.temporaryDirectory.appending(path: "hotkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "hotkeys.json")
        try t.save(to: url)
        XCTAssertEqual(try HotkeyTable.load(from: url), t)
        XCTAssertTrue(HotkeyTable.defaultFileURL.path.contains("Application Support"))
        XCTAssertFalse(HotkeyTable.defaultFileURL.path.contains(".show"))
        // 手写的 JSON 也能读（宽松：大小写、别名）
        let handwritten = """
        {"version": 1, "bindings": [
          {"key": "Shift+Space", "action": {"command": {"cut": {}}}, "note": "直切"},
          {"key": "F", "action": {"toggleFTB": {}}},
          {"key": "cmd+1", "action": {"toggleOverlay": {"channel": 1}}},
          {"key": "m", "action": {"toggleMute": {"input": 1}}},
          {"key": "r", "action": {"toggleRecord": {"output": 1}}}
        ]}
        """
        let h = try HotkeyTable.load(from: Data(handwritten.utf8))
        XCTAssertEqual(h.bindings[0].key, KeyCombo(key: "space", modifiers: [.shift]))
        XCTAssertEqual(h.bindings[0].note, "直切")
        XCTAssertEqual(h.bindings[2].action, .toggleOverlay(channel: 1))
        XCTAssertEqual(h.bindings[4].action, .toggleRecord(output: 1))
    }

    func testHotkey_conflictDetection() throws {
        var t = HotkeyTable.default
        t.bindings.append(HotkeyBinding(key: KeyCombo("SHIFT+1")!, action: .command(.cut)))       // 与 shift+1 冲突
        t.bindings.append(HotkeyBinding(key: KeyCombo("space")!, action: .toggleFTB))            // 与 space 冲突
        t.bindings.append(HotkeyBinding(key: KeyCombo("cmd+space")!, action: .toggleFTB))        // 不冲突（修饰键不同）
        let conflicts = t.conflicts()
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(Set(conflicts.map(\.key)), [KeyCombo("shift+1")!, KeyCombo("space")!])
        for c in conflicts { XCTAssertEqual(c.bindings.count, 2) }
        // 带冲突的表读进来要报错，错误里点名
        let data = try t.jsonData()
        XCTAssertThrowsError(try HotkeyTable.load(from: data)) { error in
            guard case HotkeyTableError.conflicts(let list) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(list.count, 2)
            XCTAssertTrue("\(error)".contains("shift+1"))
        }
        XCTAssertNoThrow(try HotkeyTable.load(from: data, allowConflicts: true))
        // 坏的组合键：报错
        XCTAssertThrowsError(try HotkeyTable.load(from: Data(#"{"version":1,"bindings":[{"key":"hyper+1","action":{"command":{"cut":{}}}}]}"#.utf8)))
    }

    // MARK: 动作解析

    func testHotkey_toggleActionsResolveAgainstState() {
        // W5-J 起 resolve 返回命令数组（组合动作按顺序逐条进总线）：单条动作 = 一个元素，解析不出 = 空数组
        var s = TestStates.base()
        XCTAssertEqual(ControlAction.toggleFTB.resolve(in: s), [.ftb(on: true)])
        s.ftb.on = true
        XCTAssertEqual(ControlAction.toggleFTB.resolve(in: s), [.ftb(on: false)])
        // W5-O：通道没指定输入时用当前 PVW 那一路开（与转场列 / 菜单栏"切换 › Overlay"同一口径；testW5O8_toggleOverlayEmptyChannelUsesPreview）
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 2).resolve(in: s), [.overlay(channel: 2, on: true, input: 2)])
        s.overlays[1].on = true
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 2).resolve(in: s), [.overlay(channel: 2, on: false, input: nil)])
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 9).resolve(in: s), [])
        XCTAssertEqual(ControlAction.toggleMute(input: 1).resolve(in: s), [.mute(input: 1, on: true)])
        s.inputs[0].settings.audio.muted = true
        XCTAssertEqual(ControlAction.toggleMute(input: 1).resolve(in: s), [.mute(input: 1, on: false)])
        XCTAssertEqual(ControlAction.toggleMute(input: 42).resolve(in: s), [])
        XCTAssertEqual(ControlAction.toggleRecord(output: 1).resolve(in: s), [.startRecord(output: 1)])
        s.outputs[0].enabled = true
        XCTAssertEqual(ControlAction.toggleRecord(output: 1).resolve(in: s), [.stopRecord(output: 1)])
        XCTAssertEqual(ControlAction.toggleStream(output: 2).resolve(in: s), [.startStream(output: 2)])
        XCTAssertEqual(ControlAction.toggleStream(output: 1).resolve(in: s), [], "1 号不是推流输出")
        XCTAssertEqual(ControlAction.toggleAFV.resolve(in: s), [.setAFV(on: true)])
        XCTAssertEqual(ControlAction.command(.cut).resolve(in: s), [.cut])
    }

    // MARK: 派发

    func testHotkey_dispatcherSendsCommandsThroughBus() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let d = HotkeyDispatcher(bus: f.bus)
        XCTAssertFalse(d.handle(KeyCombo("cmd+q")!), "没绑定的键不吃")
        let r1 = try await d.handleAndWait(KeyCombo("3")!)
        XCTAssertEqual(r1?.sequence, 1)
        let r2 = try await d.handleAndWait(KeyCombo("space")!)
        XCTAssertEqual(r2?.sequence, 2)
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, 3)
        XCTAssertEqual(state.preview, 1)
        _ = try await d.handleAndWait(KeyCombo("f")!)
        state = await f.stateMachine.state
        XCTAssertTrue(state.ftb.on)
        _ = try await d.handleAndWait(KeyCombo("f")!)
        state = await f.stateMachine.state
        XCTAssertFalse(state.ftb.on)
        // 异步入口：handle 返回 true 并在后台投递
        XCTAssertTrue(d.handle(KeyCombo("shift+2")!))
        // 等回执进日志（lastSequence 在分配 sequence 时就变了，状态机可能还没应用；整包跑时撞过一次 program 仍是 3）
        let ok = await waitUntil { f.bus.recentEntries().count == 5 }
        XCTAssertTrue(ok)
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
        // 换表
        d.table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("x")!, action: .command(.setPreview(input: 4)))])
        XCTAssertFalse(d.handle(KeyCombo("3")!))
        _ = try await d.handleAndWait(KeyCombo("x")!)
        state = await f.stateMachine.state
        XCTAssertEqual(state.preview, 4)
        XCTAssertEqual(f.bus.recentEntries().last?.source, .hotkey)
        // 结构性非法（输入 9 不存在）：handleAndWait 抛，handle 吞掉并计数
        d.table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("9")!, action: .command(.setPreview(input: 9)))])
        do { _ = try await d.handleAndWait(KeyCombo("9")!); XCTFail("应抛") } catch is CommandRejection {}
        XCTAssertTrue(d.handle(KeyCombo("9")!))
        let rejected = await waitUntil { d.counters.rejected == 2 }
        XCTAssertTrue(rejected)
    }

    /// W5-O（prompt 112 第 8 项）：⌃1–⌃4（toggleOverlay）对没指定输入的通道用当前 PVW 那一路开——原来发 overlay(on, input: nil)，开了没画面；
    /// 与转场列 / 菜单栏"切换 › Overlay"同一口径（App 的 OverlayToggle）：开着 → 关（通道设置不清）；关着、指定了输入 → 开；
    /// 都没有、PVW 也是黑场 → 不发，派发器给一句 ControlFeedback.overlayNeedsPreview（状态行）。
    func testW5O8_toggleOverlayEmptyChannelUsesPreview() async throws {
        var s = TestStates.base()
        XCTAssertNil(s.overlays[2].input)
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 3).resolve(in: s), [.overlay(channel: 3, on: true, input: 2)], "空通道 = 用 PVW（2）开")
        s.overlays[2].input = 4
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 3).resolve(in: s), [.overlay(channel: 3, on: true, input: nil)], "指定了输入：照它开")
        s.overlays[2].on = true
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 3).resolve(in: s), [.overlay(channel: 3, on: false, input: nil)], "开着：关，输入留着")
        var black = TestStates.base()
        black.preview = MixerState.noInput
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 1).resolve(in: black), [], "空通道 + PVW 黑场：不发")
        XCTAssertEqual(ControlAction.toggleOverlay(channel: 1).unresolvedFeedback(in: black), .overlayNeedsPreview(channel: 1))
        XCTAssertNil(ControlAction.toggleOverlay(channel: 1).unresolvedFeedback(in: TestStates.base()), "解析得出来就不说")
        XCTAssertNil(ControlAction.toggleMute(input: 42).unresolvedFeedback(in: black), "别的解析不出（引用不存在）照旧不说")
        // 派发器：解析不出时把这一句交给 App 设的 handler（状态行）
        let f = BusFixture(state: black)
        defer { f.stop() }
        let d = HotkeyDispatcher(bus: f.bus)
        let got = Mutex<[ControlFeedback]>([])
        d.setFeedbackHandler { fb in got.withLock { $0.append(fb) } }
        let ok = await waitUntil { f.stateMachine.publisher.latest != nil }
        XCTAssertTrue(ok)
        let receipts = try await d.handleAllAndWait(try XCTUnwrap(KeyCombo("ctrl+1")))
        XCTAssertEqual(receipts, [], "PVW 黑场：一条都不发")
        XCTAssertEqual(got.withLock { $0 }, [.overlayNeedsPreview(channel: 1)])
        XCTAssertEqual(d.counters.unresolved, 1)
        XCTAssertTrue(d.handle(try XCTUnwrap(KeyCombo("ctrl+1"))), "异步入口同样吃掉这个键")
        XCTAssertEqual(got.withLock { $0 }.count, 2)
    }

    #if canImport(AppKit)
    func testHotkey_keyComboFromNSEvent() {
        func event(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
        }
        XCTAssertEqual(KeyCombo(event: event("1", keyCode: 18)), KeyCombo("1"))
        XCTAssertEqual(KeyCombo(event: event("1", keyCode: 18, flags: [.shift])), KeyCombo("shift+1"))
        XCTAssertEqual(KeyCombo(event: event("F", keyCode: 3, flags: [.shift])), KeyCombo("shift+f"))
        XCTAssertEqual(KeyCombo(event: event(" ", keyCode: 49)), KeyCombo("space"))
        XCTAssertEqual(KeyCombo(event: event("\r", keyCode: 36)), KeyCombo("return"))
        XCTAssertEqual(KeyCombo(event: event("\u{1B}", keyCode: 53)), KeyCombo("escape"))
        XCTAssertEqual(KeyCombo(event: event("\u{F704}", keyCode: 122)), KeyCombo("f1"))
        XCTAssertEqual(KeyCombo(event: event("\u{F700}", keyCode: 126, flags: [.command])), KeyCombo("cmd+up"))
        XCTAssertEqual(KeyCombo(event: event("a", keyCode: 0, flags: [.command, .option, .numericPad])), KeyCombo("cmd+alt+a"), "无关的标志位忽略")
    }
    #endif
}
