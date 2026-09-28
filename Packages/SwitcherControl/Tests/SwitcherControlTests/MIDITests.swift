import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// MIDI：映射表 JSON、纯函数的映射（CC → T-bar / 推子，Note → 动作，T-bar 换向）、CoreMIDI 虚拟端点自测（热插拔、CC → tbar、Note → 命令、learn）。
final class MIDITests: XCTestCase {
    // MARK: 映射表

    func testMIDI_mapTableJSONRoundTripAndConflicts() throws {
        let t = MIDIMapTable(mappings: [
            MIDIMapping(trigger: .cc(channel: 1, controller: 1), action: .tbar, note: "推杆"),
            MIDIMapping(trigger: .cc(channel: 1, controller: 7), action: .inputGain(input: 1, minDb: -60, maxDb: 12)),
            MIDIMapping(trigger: .cc(channel: 1, controller: 8), action: .busGain(bus: .master, minDb: -60, maxDb: 6)),
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut))),
            MIDIMapping(trigger: .note(channel: 1, note: 61), action: .action(.toggleFTB)),
        ])
        XCTAssertTrue(t.conflicts().isEmpty)
        let data = try t.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"cc\""), text)
        XCTAssertTrue(text.contains("\"tbar\""))
        XCTAssertEqual(try MIDIMapTable.load(from: data), t)
        // 手写
        let hand = """
        {"version": 1, "mappings": [
          {"trigger": {"cc": {"channel": 2, "controller": 16}}, "action": {"tbar": {}}},
          {"trigger": {"note": {"channel": 1, "note": 36}}, "action": {"action": {"command": {"setPreview": {"input": 3}}}}},
          {"trigger": {"cc": {"channel": 2, "controller": 16}}, "action": {"inputGain": {"input": 2, "minDb": -60, "maxDb": 0}}}
        ]}
        """
        XCTAssertThrowsError(try MIDIMapTable.load(from: Data(hand.utf8))) { e in
            guard case MIDIMapTableError.conflicts(let c) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(c.count, 1)
            XCTAssertEqual(c[0].trigger, .cc(channel: 2, controller: 16))
        }
        let loose = try MIDIMapTable.load(from: Data(hand.utf8), allowConflicts: true)
        XCTAssertEqual(loose.mappings[1].action, .action(.command(.setPreview(input: 3))))
        // 范围检查：通道 1–16、控制器 / 音符 0–127
        XCTAssertThrowsError(try MIDIMapTable.load(from: Data(#"{"version":1,"mappings":[{"trigger":{"cc":{"channel":17,"controller":1}},"action":{"tbar":{}}}]}"#.utf8)))
        XCTAssertThrowsError(try MIDIMapTable.load(from: Data(#"{"version":1,"mappings":[{"trigger":{"note":{"channel":1,"note":128}},"action":{"tbar":{}}}]}"#.utf8)))
        XCTAssertTrue(MIDIMapTable.defaultFileURL.path.hasSuffix("Switcher/midi.json"))
    }

    // MARK: 纯函数映射

    func testMIDI_ccToTbar_flipsDirectionAtEachEnd() {
        var m = MIDIMapper(table: MIDIMapTable(mappings: [MIDIMapping(trigger: .cc(channel: 1, controller: 1), action: .tbar)]))
        let s = TestStates.base()
        func cc(_ v: Int) -> Command? { m.command(for: MIDIMessage(trigger: .cc(channel: 1, controller: 1), value: v, timestamp: .zero), state: s) }
        XCTAssertEqual(cc(0), .tbar(progress: 0))
        XCTAssertEqual(cc(64), .tbar(progress: 64.0 / 127.0))
        XCTAssertEqual(cc(127), .tbar(progress: 1))        // 提交
        // 换向：从顶端往回拉是下一次转场的 0 → 1
        XCTAssertEqual(cc(127), .tbar(progress: 0))
        if case .tbar(let p)? = cc(100) { XCTAssertEqual(p, 27.0 / 127.0, accuracy: 1e-12) } else { XCTFail() }
        XCTAssertEqual(cc(0), .tbar(progress: 1))          // 提交
        XCTAssertEqual(cc(1), .tbar(progress: 1.0 / 127.0))
        // 别的 CC / 通道不匹配
        XCTAssertNil(m.command(for: MIDIMessage(trigger: .cc(channel: 2, controller: 1), value: 5, timestamp: .zero), state: s))
        XCTAssertNil(m.command(for: MIDIMessage(trigger: .cc(channel: 1, controller: 2), value: 5, timestamp: .zero), state: s))
    }

    func testMIDI_ccToGains_andNoteToActions() {
        var m = MIDIMapper(table: MIDIMapTable(mappings: [
            MIDIMapping(trigger: .cc(channel: 1, controller: 7), action: .inputGain(input: 1, minDb: -60, maxDb: 12)),
            MIDIMapping(trigger: .cc(channel: 1, controller: 8), action: .busGain(bus: .master, minDb: -60, maxDb: 6)),
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut))),
            MIDIMapping(trigger: .note(channel: 1, note: 61), action: .action(.toggleFTB)),
        ]))
        var s = TestStates.base()
        func msg(_ t: MIDITrigger, _ v: Int, off: Bool = false) -> MIDIMessage { MIDIMessage(trigger: t, value: v, isNoteOff: off, timestamp: .zero) }
        XCTAssertEqual(m.command(for: msg(.cc(channel: 1, controller: 7), 0), state: s), .audioGain(input: 1, dB: -60))
        XCTAssertEqual(m.command(for: msg(.cc(channel: 1, controller: 7), 127), state: s), .audioGain(input: 1, dB: 12))
        if case .audioGain(_, let dB)? = m.command(for: msg(.cc(channel: 1, controller: 7), 64), state: s) {
            XCTAssertEqual(dB, -60 + 72 * 64.0 / 127.0, accuracy: 1e-9)
        } else { XCTFail() }
        XCTAssertEqual(m.command(for: msg(.cc(channel: 1, controller: 8), 127), state: s), .busGain(bus: .master, dB: 6))
        XCTAssertEqual(m.command(for: msg(.note(channel: 1, note: 60), 100), state: s), .cut)
        XCTAssertNil(m.command(for: msg(.note(channel: 1, note: 60), 0), state: s), "力度 0 = 松开，不触发")
        XCTAssertNil(m.command(for: msg(.note(channel: 1, note: 60), 100, off: true), state: s), "Note Off 不触发")
        XCTAssertEqual(m.command(for: msg(.note(channel: 1, note: 61), 1), state: s), .ftb(on: true))
        s.ftb.on = true
        XCTAssertEqual(m.command(for: msg(.note(channel: 1, note: 61), 1), state: s), .ftb(on: false))
    }

    /// 14-bit CC：控制器 n 是 MSB、n + 32 是 LSB；MSB 到了先按粗值发（LSB 归零），LSB 到了再按细值发。
    func testMIDI_cc14_fineTbarAndGain() {
        var m = MIDIMapper(table: MIDIMapTable(mappings: [
            MIDIMapping(trigger: .cc14(channel: 1, controller: 1), action: .tbar),
            MIDIMapping(trigger: .cc14(channel: 1, controller: 7), action: .inputGain(input: 1, minDb: -60, maxDb: 12)),
            MIDIMapping(trigger: .cc(channel: 1, controller: 40), action: .busGain(bus: .master, minDb: -60, maxDb: 6)),   // 显式映射的 LSB 号优先当普通 CC
        ]))
        let s = TestStates.base()
        func cc(_ n: Int, _ v: Int) -> Command? { m.command(for: MIDIMessage(trigger: .cc(channel: 1, controller: n), value: v, timestamp: .zero), state: s) }
        // MSB 64 → 8192/16383；LSB 100 → (64<<7 | 100)/16383
        if case .tbar(let p)? = cc(1, 64) { XCTAssertEqual(p, 8192.0 / 16383.0, accuracy: 1e-12) } else { XCTFail() }
        if case .tbar(let p)? = cc(33, 100) { XCTAssertEqual(p, Double(64 << 7 | 100) / 16383.0, accuracy: 1e-12) } else { XCTFail() }
        // 到顶：MSB 127 + LSB 127 = 16383 → 提交并换向
        if case .tbar(let p)? = cc(1, 127) { XCTAssertEqual(p, Double(127 << 7) / 16383.0, accuracy: 1e-12) } else { XCTFail() }
        XCTAssertEqual(cc(33, 127), .tbar(progress: 1))
        if case .tbar(let p)? = cc(1, 127) { XCTAssertEqual(p, 1 - Double(127 << 7) / 16383.0, accuracy: 1e-12, "换向后 MSB 127 / LSB 0 是 127/16383") } else { XCTFail() }
        // 没有 MSB 先到的 LSB：当 MSB = 0
        if case .audioGain(_, let dB)? = cc(39, 127) { XCTAssertEqual(dB, -60 + 72 * 127.0 / 16383.0, accuracy: 1e-9) } else { XCTFail() }
        if case .audioGain(_, let dB)? = cc(7, 127) { XCTAssertEqual(dB, -60 + 72 * Double(127 << 7) / 16383.0, accuracy: 1e-9) } else { XCTFail() }
        // 显式映射的 40 号（= 8 + 32）走自己的映射，不当 8 号的 LSB
        XCTAssertEqual(cc(40, 127), .busGain(bus: .master, dB: 6))
        // 表里 cc14 的 controller 必须 0–31
        XCTAssertThrowsError(try MIDIMapTable.load(from: Data(#"{"version":1,"mappings":[{"trigger":{"cc14":{"channel":1,"controller":32}},"action":{"tbar":{}}}]}"#.utf8)))
        let t = try? MIDIMapTable.load(from: Data(#"{"version":1,"mappings":[{"trigger":{"cc14":{"channel":2,"controller":3}},"action":{"tbar":{}}}]}"#.utf8))
        XCTAssertEqual(t?.mappings.first?.trigger, .cc14(channel: 2, controller: 3))
        XCTAssertEqual(MIDITrigger.cc14(channel: 2, controller: 3).description, "CC 3/35 (14-bit) @ ch2")
    }

    func testMIDI_umpParsing() {
        // MIDI 1.0 channel voice（UMP MT=2）：CC1=64 ch1、Note On 60 vel 100 ch1、Note Off 60 ch2、Note On vel 0、别的消息类型跳过
        let words: [UInt32] = [0x20B00140, 0x20903C64, 0x20813C40, 0x20903C00, 0x10F80000, 0x40903C00, 0x00000000]
        let msgs = MIDIUMP.parse(words: words, timestamp: HostTime(ticks: 7))
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0], MIDIMessage(trigger: .cc(channel: 1, controller: 1), value: 64, timestamp: HostTime(ticks: 7)))
        XCTAssertEqual(msgs[1], MIDIMessage(trigger: .note(channel: 1, note: 60), value: 100, timestamp: HostTime(ticks: 7)))
        XCTAssertEqual(msgs[2], MIDIMessage(trigger: .note(channel: 2, note: 60), value: 64, isNoteOff: true, timestamp: HostTime(ticks: 7)))
        XCTAssertEqual(msgs[3], MIDIMessage(trigger: .note(channel: 1, note: 60), value: 0, timestamp: HostTime(ticks: 7)))
    }

    // MARK: CoreMIDI 虚拟端点

    func testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let table = MIDIMapTable(mappings: [
            MIDIMapping(trigger: .cc(channel: 1, controller: 1), action: .tbar),
            MIDIMapping(trigger: .cc(channel: 1, controller: 7), action: .inputGain(input: 1, minDb: -60, maxDb: 12)),
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut))),
        ])
        let controller = MIDIController(bus: f.bus, table: table, clientName: "Switcher 测试 \(UUID().uuidString.prefix(8))")
        do { try controller.start() } catch {
            throw XCTSkip("CoreMIDI 不可用：\(error)")
        }
        defer { controller.stop() }
        let before = controller.sources.count
        let name = "Switcher 虚拟源 \(UUID().uuidString.prefix(8))"
        let source = try VirtualMIDISource(name: name)
        // 热插拔：新源出现后自动连上
        let connected = await waitUntil(timeout: 5) { controller.sources.contains { $0.name == name && $0.connected } }
        XCTAssertTrue(connected, "虚拟源应被自动连接；现有：\(controller.sources)")
        XCTAssertEqual(controller.sources.count, before + 1)

        // CC1 = 64 → tbar 0.504
        try source.send(cc: 1, value: 64, channel: 1)
        var ok = await waitUntil { f.bus.lastSequence >= 1 }
        XCTAssertTrue(ok)
        var state = await f.stateMachine.state
        XCTAssertEqual(state.transition.source, .tbar)
        XCTAssertEqual(state.transition.progress, 64.0 / 127.0, accuracy: 1e-9)
        XCTAssertEqual(f.bus.recentEntries().last?.source, .midi)
        // 推到顶：提交（对调）
        try source.send(cc: 1, value: 127, channel: 1)
        ok = await waitUntil { f.bus.lastSequence >= 2 }
        XCTAssertTrue(ok)
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
        XCTAssertEqual(state.preview, 1)
        XCTAssertFalse(state.transition.isActive)
        // 往回拉一半：换向后是新转场的一半
        try source.send(cc: 1, value: 64, channel: 1)
        ok = await waitUntil { f.bus.lastSequence >= 3 }
        XCTAssertTrue(ok)
        state = await f.stateMachine.state
        XCTAssertEqual(state.transition.progress, 63.0 / 127.0, accuracy: 1e-9)
        try source.send(cc: 1, value: 0, channel: 1)      // 到底：提交回来
        ok = await waitUntil { f.bus.lastSequence >= 4 }
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 1)
        // 推子
        try source.send(cc: 7, value: 127, channel: 1)
        ok = await waitUntil { f.bus.lastSequence >= 5 }
        XCTAssertTrue(ok)
        state = await f.stateMachine.state
        XCTAssertEqual(state.input(1)?.settings.audio.gainDb, 12)
        // Note On 60 → cut；Note Off 不动
        try source.send(noteOn: 60, velocity: 100, channel: 1)
        ok = await waitUntil { f.bus.lastSequence >= 6 }
        XCTAssertTrue(ok)
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
        try source.send(noteOff: 60, channel: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.bus.lastSequence, 6)
        // 顺序：连发 20 个 CC，命令按发送顺序进总线
        for v in stride(from: 0, through: 95, by: 5) { try source.send(cc: 1, value: v, channel: 1) }
        ok = await waitUntil { f.bus.lastSequence >= 26 }
        XCTAssertTrue(ok)
        let progresses = f.bus.recentEntries().suffix(20).compactMap { e -> Double? in if case .tbar(let p) = e.command { return p } else { return nil } }
        XCTAssertEqual(progresses, progresses.sorted(), "CC 顺序不能乱")
        XCTAssertEqual(progresses.count, 20)
        // learn：下一条消息被捕获、不派发
        let learned = LearnBox()
        controller.startLearn { learned.set($0) }
        XCTAssertTrue(controller.isLearning)
        try source.send(cc: 9, value: 33, channel: 3)
        ok = await waitUntil { learned.value != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(learned.value?.trigger, .cc(channel: 3, controller: 9))
        XCTAssertEqual(learned.value?.value, 33)
        XCTAssertFalse(controller.isLearning)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.bus.lastSequence, 26, "learn 期间的消息不派发")
        XCTAssertEqual(controller.counters.learned, 1)
        // 没映射的消息：计 ignored
        try source.send(cc: 100, value: 1, channel: 16)
        ok = await waitUntil { controller.counters.ignored >= 1 }
        XCTAssertTrue(ok)
        // 拔掉：源列表更新
        source.dispose()
        let gone = await waitUntil(timeout: 5) { !controller.sources.contains { $0.name == name } }
        XCTAssertTrue(gone, "源消失后应从列表移除")
    }

    // MARK: W2-C2 换过节目之后的热插拔

    /// W2-C2：控制器停过一次（同一个实例重起）、或换了一个全新的控制器（App 换节目就是这样）之后，新出现的源仍要热插拔连上、
    /// 能收 CC / Note、learn 照常；三轮起停都要收到源的增删通知。
    /// 修前：CoreMIDI 把通知派到"进程里第一次建客户端那条线程的 run loop"上，第一个控制器的线程退出后再也收不到 msgObjectAdded
    /// （reports/issues/W3E-w2-control-midi-hotplug-after-restart.md）。
    func testW2C2_midiHotplug_survivesControllerRestart() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let table = MIDIMapTable(mappings: [
            MIDIMapping(trigger: .cc(channel: 1, controller: 1), action: .tbar),
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut))),
        ])
        let tag = UUID().uuidString.prefix(8)
        let first = MIDIController(bus: f.bus, table: table, clientName: "PlusMix 测试 A \(tag)")
        do { try first.start() } catch { throw XCTSkip("CoreMIDI 不可用：\(error)") }
        // 第 1 轮：同一个控制器起 → 停 → 再起；第 2、3 轮：前一个停了之后换全新的控制器
        first.stop()
        XCTAssertFalse(first.isRunning)
        try first.start()
        let second = MIDIController(bus: f.bus, table: table, clientName: "PlusMix 测试 B \(tag)")
        let third = MIDIController(bus: f.bus, table: table, clientName: "PlusMix 测试 C \(tag)")
        for (index, controller) in [first, second, third].enumerated() {
            let round = index + 1
            if round > 1 { try controller.start() }
            XCTAssertTrue(controller.isRunning, "第 \(round) 轮")
            let before = controller.sources.count
            let seq0 = f.bus.lastSequence
            let name = "PlusMix 虚拟源 \(round) \(tag)"
            let source = try VirtualMIDISource(name: name)
            // 增通知：新源自动连上
            let connected = await waitUntil(timeout: 5) { controller.sources.contains { $0.name == name && $0.connected } }
            XCTAssertTrue(connected, "第 \(round) 轮：换过控制器之后新建的源应自动连上；现有：\(controller.sources)")
            XCTAssertEqual(controller.sources.count, before + 1, "第 \(round) 轮")
            // CC1 = 64 → tbar 64/127
            try source.send(cc: 1, value: 64, channel: 1)
            var ok = await waitUntil { f.bus.lastSequence >= seq0 + 1 }
            XCTAssertTrue(ok, "第 \(round) 轮：CC 应派发")
            var state = await f.stateMachine.state
            XCTAssertEqual(state.transition.source, .tbar, "第 \(round) 轮")
            XCTAssertEqual(state.transition.progress, 64.0 / 127.0, accuracy: 1e-9, "第 \(round) 轮")
            // 推到顶提交：对调
            try source.send(cc: 1, value: 127, channel: 1)
            ok = await waitUntil { f.bus.lastSequence >= seq0 + 2 }
            XCTAssertTrue(ok, "第 \(round) 轮")
            state = await f.stateMachine.state
            XCTAssertEqual(state.program, 2, "第 \(round) 轮")
            XCTAssertEqual(state.preview, 1, "第 \(round) 轮")
            // Note 60 → cut：换回来
            try source.send(noteOn: 60, velocity: 100, channel: 1)
            ok = await waitUntil { f.bus.lastSequence >= seq0 + 3 }
            XCTAssertTrue(ok, "第 \(round) 轮：Note 应派发")
            state = await f.stateMachine.state
            XCTAssertEqual(state.program, 1, "第 \(round) 轮")
            XCTAssertEqual(state.preview, 2, "第 \(round) 轮")
            // learn 照常：捕获、不派发
            let learned = LearnBox()
            controller.startLearn { learned.set($0) }
            try source.send(cc: 9, value: 33, channel: 3)
            ok = await waitUntil { learned.value != nil }
            XCTAssertTrue(ok, "第 \(round) 轮：learn 应收到")
            XCTAssertEqual(learned.value?.trigger, .cc(channel: 3, controller: 9))
            XCTAssertEqual(learned.value?.value, 33)
            XCTAssertFalse(controller.isLearning)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(f.bus.lastSequence, seq0 + 3, "第 \(round) 轮：learn 的消息不派发")
            // 删通知：源销毁后从列表移除
            source.dispose()
            let gone = await waitUntil(timeout: 5) { !controller.sources.contains { $0.name == name } }
            XCTAssertTrue(gone, "第 \(round) 轮：源销毁后应收到删通知并移除；现有：\(controller.sources)")
            XCTAssertEqual(controller.sources.count, before, "第 \(round) 轮")
            controller.stop()
            XCTAssertFalse(controller.isRunning, "第 \(round) 轮")
        }
    }

}

final class LearnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: MIDIMessage?
    var value: MIDIMessage? { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ m: MIDIMessage) { lock.lock(); v = m; lock.unlock() }
}
