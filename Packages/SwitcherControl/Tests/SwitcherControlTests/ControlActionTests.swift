import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// W5-J（prompt 96，01a N2 / N3，04 Q29 / Q52 / Q53）：可绑动作补齐——开关与组合动作、resolve 返回命令数组且按顺序逐条进总线、
/// 按毫秒存的 Fade、按下时才定的输入（当前 PVW / PGM）、每行"启用"、界面动作、默认表按 Q29 补键；旧的 hotkeys.json / midi.json 照读。
final class ControlActionTests: XCTestCase {
    // MARK: prompt 96 的四条

    /// "选进 PVW 并按已选转场执行" = setPreview 后 autoTransition，两条在总线上序号连续、来源 hotkey。
    func testHotkeys_compoundActionEmitsCommandsInOrder() async throws {
        var start = TestStates.base()
        start.transition.durationTicks = 4   // 转场快点做完
        let f = BusFixture(state: start)
        defer { f.stop() }
        let action = ControlAction.previewAndTransition(input: 3)
        XCTAssertEqual(action.resolve(in: start), [.setPreview(input: 3), .autoTransition], "组合动作按顺序解析成两条")
        let d = HotkeyDispatcher(bus: f.bus, table: HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("alt+3")!, action: action)]))
        let receipts = try await d.handleAllAndWait(KeyCombo("alt+3")!)
        XCTAssertEqual(receipts.count, 2)
        guard receipts.count == 2 else { return }
        XCTAssertEqual(receipts.map(\.sequence), [receipts[0].sequence, receipts[0].sequence + 1], "序号连续")
        let entries = f.bus.recentEntries().suffix(2)
        XCTAssertEqual(entries.map(\.command), [.setPreview(input: 3), .autoTransition])
        XCTAssertEqual(entries.map(\.source), [.hotkey, .hotkey])
        XCTAssertEqual(entries.map(\.sequence), receipts.map(\.sequence))
        await f.stateMachine.prepare(upTo: Tick(20))   // 没有渲染线程：手动推拍，4 拍的转场做完
        let state = await f.stateMachine.state
        XCTAssertEqual(state.program, 3, "转场做完 PGM = 3")
        XCTAssertEqual(state.preview, 1, "原 PGM 回到 PVW")
        // 异步入口同样按顺序
        d.table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("alt+4")!, action: .previewAndTransition(input: 4))])
        let before = f.bus.lastSequence
        XCTAssertTrue(d.handle(KeyCombo("alt+4")!))
        let both = await waitUntil { f.bus.recentEntries().filter { $0.sequence > before }.count == 2 }
        XCTAssertTrue(both)
        let later = f.bus.recentEntries().filter { $0.sequence > before }
        XCTAssertEqual(later.map(\.command), [.setPreview(input: 4), .autoTransition])
        XCTAssertEqual(later.map(\.sequence), [before + 1, before + 2])
        // 输入 9 不存在：解析不出，一条都不发（不会只发出 autoTransition 把原来的 PVW 推上去）
        d.table = HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("alt+9")!, action: .previewAndTransition(input: 9))])
        let beforeMissing = f.bus.lastSequence
        let none = try await d.handleAllAndWait(KeyCombo("alt+9")!)
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(f.bus.lastSequence, beforeMissing)
        XCTAssertEqual(d.counters.unresolved, 1)
        // 逐条提交的口径：前一条被总线拒（抛 CommandRejection）就停，后一条不发
        let beforeRejected = f.bus.lastSequence
        do {
            _ = try await HotkeyDispatcher.submitInOrder([.setPreview(input: 9), .autoTransition], to: f.bus, source: .hotkey)
            XCTFail("应抛")
        } catch is CommandRejection {}
        XCTAssertEqual(f.bus.lastSequence, beforeRejected, "被拒的那条不占序号，后一条没发")
        XCTAssertFalse(f.bus.recentEntries().contains { $0.sequence > beforeRejected })
    }

    /// 按毫秒存的 Fade（Q52）：按下时按当前节目帧率换成拍——30p 与 60p 下同一条"Fade 1000 ms"都是 1 s。
    func testHotkeys_millisecondFadeConvertsByCurrentFrameRate() async throws {
        let action = ControlAction.fadeMs(durationMs: 1000)
        for (rate, ticks) in [(FrameRate.fps30, 30), (.fps60, 60), (.fps5994, 60), (.fps25, 25), (.fps2997, 30)] {
            var s = TestStates.base()
            s.format = ProgramFormat(width: 1920, height: 1080, frameRate: rate)
            XCTAssertEqual(action.resolve(in: s), [.fade(durationTicks: ticks)], "\(rate) 下 1000 ms")
        }
        var s30 = TestStates.base()
        s30.format = ProgramFormat(width: 1920, height: 1080, frameRate: .fps30)
        XCTAssertEqual(ControlAction.fadeMs(durationMs: 500).resolve(in: s30), [.fade(durationTicks: 15)])
        XCTAssertEqual(ControlAction.fadeMs(durationMs: 0).resolve(in: s30), [.fade(durationTicks: 0)], "0 = Cut（与命令同口径）")
        XCTAssertEqual(ControlAction.fadeMs(durationMs: -20).resolve(in: s30), [.fade(durationTicks: 0)], "负数钳到 0")
        // 真走总线：30p 与 60p 两个节目，转场时长（拍）× 每拍时长 = 1 s
        for (rate, ticks) in [(FrameRate.fps30, 30), (.fps60, 60)] {
            var start = TestStates.base()
            start.format = ProgramFormat(width: 1920, height: 1080, frameRate: rate)
            let f = BusFixture(state: start)
            defer { f.stop() }
            let d = HotkeyDispatcher(bus: f.bus, table: HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("g")!, action: action)]))
            let r = try await d.handleAndWait(KeyCombo("g")!)
            XCTAssertNotNil(r)
            XCTAssertEqual(f.bus.recentEntries().last?.command, .fade(durationTicks: ticks))
            let state = await f.stateMachine.state
            XCTAssertEqual(state.transition.type, .fade)
            XCTAssertEqual(state.transition.durationTicks, ticks)
            XCTAssertEqual(Double(state.transition.durationTicks) / rate.framesPerSecond.doubleValue, 1.0, accuracy: 0.001, "\(rate)：1 s")
        }
        // JSON：新键 fadeMs，按毫秒存
        let data = try HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("g")!, action: action)]).jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"fadeMs\""), text)
        XCTAssertTrue(text.contains("\"durationMs\" : 1000"), text)
        XCTAssertEqual(try HotkeyTable.load(from: data).bindings[0].action, action)
    }

    /// 旧的按拍存的 Fade 照读、照发（时长跟着节目帧率走，这正是 Q52 加毫秒动作的原因）；旧文件里没有 enabled 键 = 启用。
    func testHotkeys_legacyTickFadeStillLoads() throws {
        let legacy = """
        {"version": 1, "bindings": [
          {"key": "g", "action": {"command": {"fade": {"durationTicks": 30}}}, "note": "老的 Fade 30 拍"},
          {"key": "m", "action": {"toggleMute": {"input": 2}}},
          {"key": "shift+space", "action": {"command": {"cut": {}}}}
        ]}
        """
        let t = try HotkeyTable.load(from: Data(legacy.utf8))
        XCTAssertEqual(t.bindings.count, 3)
        XCTAssertEqual(t.bindings[0].action, .command(.fade(durationTicks: 30)))
        XCTAssertEqual(t.bindings[0].note, "老的 Fade 30 拍")
        XCTAssertTrue(t.bindings.allSatisfy(\.enabled), "没有 enabled 键 = 启用")
        XCTAssertEqual(t.bindings[1].action, .toggleMute(input: .number(2)), "旧的整数输入照读成编号")
        var s30 = TestStates.base()
        s30.format = ProgramFormat(width: 1920, height: 1080, frameRate: .fps30)
        var s60 = s30
        s60.format = ProgramFormat(width: 1920, height: 1080, frameRate: .fps60)
        XCTAssertEqual(t.bindings[0].action.resolve(in: s30), [.fade(durationTicks: 30)])
        XCTAssertEqual(t.bindings[0].action.resolve(in: s60), [.fade(durationTicks: 30)], "按拍存的照拍数发（60p 下是 0.5 s）")
        // 存回去不改写旧动作、也不多写 enabled（只在停用时写）
        let back = String(decoding: try t.jsonData(), as: UTF8.self)
        XCTAssertTrue(back.contains("\"durationTicks\" : 30"), back)
        XCTAssertFalse(back.contains("\"enabled\""), "启用的行不写 enabled 键：\(back)")
        XCTAssertFalse(back.contains("fadeMs"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(back.utf8)) as? [String: Any])
        let bindings = try XCTUnwrap(object["bindings"] as? [[String: Any]])
        let mute = try XCTUnwrap((bindings[1]["action"] as? [String: Any])?["toggleMute"] as? [String: Any])
        XCTAssertEqual(mute["input"] as? Int, 2, "整数输入照写成整数（旧版本读得回去）：\(back)")
        XCTAssertEqual(try HotkeyTable.load(from: Data(back.utf8)), t)
        // MIDI 表同样：旧文件没有 enabled 键
        let midi = try MIDIMapTable.load(from: Data(#"{"version":1,"mappings":[{"trigger":{"note":{"channel":1,"note":60}},"action":{"action":{"command":{"fade":{"durationTicks":20}}}}}]}"#.utf8))
        XCTAssertTrue(midi.mappings[0].enabled)
        XCTAssertEqual(midi.mappings[0].action, .action(.command(.fade(durationTicks: 20))))
        XCTAssertFalse(String(decoding: try midi.jsonData(), as: UTF8.self).contains("\"enabled\""))
    }

    /// 默认表（Q29）：录制 / 推流一律不给默认键（快捷键不弹确认，误按就停录）；⌥1–⌥4 = 执行转场（100 之前先绑"执行当前类型"）、
    /// ⌃1–⌃4 = 叠加 1–4 开关；原有的数字 / ⇧数字 / 空格 / 回车 / F 不变、不冲突。
    func testHotkeys_defaultTableHasNoRecordOrStreamKeys() {
        let t = HotkeyTable.default
        XCTAssertTrue(t.conflicts().isEmpty)
        let state = TestStates.base()
        for b in t.bindings {
            switch b.action {
            case .toggleRecord, .toggleStream, .recordAll, .recordISO, .streamAll:
                XCTFail("默认表不该有录制 / 推流的键：\(b.key) → \(b.action)")
            case .command(let c):
                switch c {
                case .startRecord, .stopRecord, .startStream, .stopStream: XCTFail("默认表不该有录制 / 推流的键：\(b.key) → \(c)")
                default: break
                }
            default: break
            }
            for c in b.action.resolve(in: state) {
                switch c {
                case .startRecord, .stopRecord, .startStream, .stopStream: XCTFail("\(b.key) 按下会发录制 / 推流命令：\(c)")
                default: break
                }
            }
        }
        for n in 1...4 {
            XCTAssertEqual(t.action(for: KeyCombo(key: String(n), modifiers: [.option])), .command(.autoTransition), "⌥\(n) = 执行当前转场（100 改成转场 \(n)）")
            XCTAssertEqual(t.action(for: KeyCombo(key: String(n), modifiers: [.control])), .toggleOverlay(channel: n), "⌃\(n) = 叠加 \(n) 开关")
        }
        XCTAssertEqual(t.action(for: KeyCombo("1")!), .command(.setPreview(input: 1)))
        XCTAssertEqual(t.action(for: KeyCombo("shift+1")!), .command(.setProgram(input: 1)))
        XCTAssertEqual(t.action(for: KeyCombo("space")!), .command(.cut))
        XCTAssertEqual(t.action(for: KeyCombo("return")!), .command(.autoTransition))
        XCTAssertEqual(t.action(for: KeyCombo("f")!), .toggleFTB)
        XCTAssertEqual(t.bindings.count, 10 + 10 + 3 + 4 + 4)
        XCTAssertTrue(t.bindings.allSatisfy(\.enabled))
        XCTAssertTrue(t.bindings.allSatisfy { !($0.note ?? "").isEmpty }, "每条默认键都有备注")
    }

    // MARK: 开关与组合动作（N2）

    func testHotkeys_switchActionsResolveAgainstState() {
        var s = TestStates.base()
        s.outputs += [
            OutputState(number: 3, kind: .record, name: "ISO 1", settings: OutputSettings(source: .input(number: 1), record: RecordSettings(directory: "/tmp"))),
            OutputState(number: 4, kind: .record, name: "ISO 2", settings: OutputSettings(source: .input(number: 2), record: RecordSettings(directory: "/tmp"))),
            OutputState(number: 5, kind: .stream, name: "推流 2", settings: OutputSettings(stream: StreamSettings(url: "rtmp://x/z"))),
            OutputState(number: 6, kind: .externalDisplay, name: "大屏", settings: OutputSettings(source: .program)),
            OutputState(number: 7, kind: .externalDisplay, name: "侧屏", settings: OutputSettings(source: .preview)),
            OutputState(number: 8, kind: .ndi, name: "NDI", settings: OutputSettings(source: .program)),
            OutputState(number: 9, kind: .virtualCamera, name: "虚拟摄像头", settings: OutputSettings(source: .program)),
            OutputState(number: 10, kind: .multiview, name: "多画面", settings: OutputSettings(source: .multiview)),
        ]
        // 输出开关：单路（显式目标照发，同 ftb(on:)）；录制 / 推流不走这里
        XCTAssertEqual(ControlAction.outputSwitch(output: 6, mode: .toggle).resolve(in: s), [.setOutputEnabled(output: 6, on: true)])
        XCTAssertEqual(ControlAction.outputSwitch(output: 8, mode: .on).resolve(in: s), [.setOutputEnabled(output: 8, on: true)])
        XCTAssertEqual(ControlAction.outputSwitch(output: 9, mode: .off).resolve(in: s), [.setOutputEnabled(output: 9, on: false)])
        XCTAssertEqual(ControlAction.outputSwitch(output: 10, mode: .toggle).resolve(in: s), [.setOutputEnabled(output: 10, on: true)])
        XCTAssertEqual(ControlAction.outputSwitch(output: 1, mode: .toggle).resolve(in: s), [], "录制输出走 recordAll / toggleRecord")
        XCTAssertEqual(ControlAction.outputSwitch(output: 42, mode: .toggle).resolve(in: s), [])
        // 一类输出全部开 / 关：切换 = 有开着的就全关，否则全开；只发要变的那几路
        XCTAssertEqual(ControlAction.outputKindSwitch(kind: .externalDisplay, mode: .toggle).resolve(in: s),
                       [.setOutputEnabled(output: 6, on: true), .setOutputEnabled(output: 7, on: true)])
        s.outputs[s.outputs.firstIndex { $0.number == 7 }!].enabled = true
        XCTAssertEqual(ControlAction.outputKindSwitch(kind: .externalDisplay, mode: .toggle).resolve(in: s), [.setOutputEnabled(output: 7, on: false)])
        XCTAssertEqual(ControlAction.outputKindSwitch(kind: .externalDisplay, mode: .on).resolve(in: s), [.setOutputEnabled(output: 6, on: true)])
        XCTAssertEqual(ControlAction.outputKindSwitch(kind: .record, mode: .on).resolve(in: s), [], "录制 / 推流不在这里")
        // 全部录制输出（PGM + ISO 同一拍：OutputRuntime 把同一次 reconcile 里打开的录制当一批）/ 只起停 ISO
        XCTAssertEqual(ControlAction.recordAll(mode: .toggle).resolve(in: s), [.startRecord(output: 1), .startRecord(output: 3), .startRecord(output: 4)])
        XCTAssertEqual(ControlAction.recordISO(mode: .toggle).resolve(in: s), [.startRecord(output: 3), .startRecord(output: 4)])
        s.outputs[s.outputs.firstIndex { $0.number == 3 }!].enabled = true
        XCTAssertEqual(ControlAction.recordAll(mode: .toggle).resolve(in: s), [.stopRecord(output: 3)], "有在录的就全停（只发在录的）")
        XCTAssertEqual(ControlAction.recordAll(mode: .on).resolve(in: s), [.startRecord(output: 1), .startRecord(output: 4)])
        XCTAssertEqual(ControlAction.recordISO(mode: .off).resolve(in: s), [.stopRecord(output: 3)])
        XCTAssertEqual(ControlAction.recordISO(mode: .toggle).resolve(in: s), [.stopRecord(output: 3)])
        // 推流全部开始 / 全部停止
        XCTAssertEqual(ControlAction.streamAll(mode: .on).resolve(in: s), [.startStream(output: 2), .startStream(output: 5)])
        s.outputs[s.outputs.firstIndex { $0.number == 5 }!].enabled = true
        XCTAssertEqual(ControlAction.streamAll(mode: .off).resolve(in: s), [.stopStream(output: 5)])
        XCTAssertEqual(ControlAction.streamAll(mode: .toggle).resolve(in: s), [.stopStream(output: 5)])
        // 每路跟随视频 / 总线路由 / 独听：按快照改一位、整体写回这一路的设置（没有单独的命令）
        var expect = s.inputs[1].settings
        expect.audio.afv = false
        XCTAssertEqual(ControlAction.inputAFV(input: 2, mode: .toggle).resolve(in: s), [.setInputSettings(input: 2, settings: expect)])
        XCTAssertEqual(ControlAction.inputAFV(input: 2, mode: .on).resolve(in: s), [], "已经是开：不发")
        expect = s.inputs[0].settings
        expect.audio.routing.busA = true
        XCTAssertEqual(ControlAction.busRoute(input: 1, bus: .busA, mode: .toggle).resolve(in: s), [.setInputSettings(input: 1, settings: expect)])
        expect = s.inputs[0].settings
        expect.audio.solo = true
        XCTAssertEqual(ControlAction.solo(input: 1, mode: .on).resolve(in: s), [.setInputSettings(input: 1, settings: expect)])
        XCTAssertEqual(ControlAction.solo(input: 42, mode: .on).resolve(in: s), [])
        // 总线静音
        XCTAssertEqual(ControlAction.busMuteSwitch(bus: .busB, mode: .toggle).resolve(in: s), [.busMute(bus: .busB, on: true)])
        s.audio.buses[s.audio.buses.firstIndex { $0.bus == .busB }!].muted = true
        XCTAssertEqual(ControlAction.busMuteSwitch(bus: .busB, mode: .toggle).resolve(in: s), [.busMute(bus: .busB, on: false)])
        XCTAssertEqual(ControlAction.busMuteSwitch(bus: .busB, mode: .on).resolve(in: s), [.busMute(bus: .busB, on: true)])
        // 叠加全关 / 叠加 N 换成输入 X 并开
        XCTAssertEqual(ControlAction.overlaysOff.resolve(in: s), [], "都关着：不发")
        s.overlays[0].on = true
        s.overlays[2].on = true
        XCTAssertEqual(ControlAction.overlaysOff.resolve(in: s), [.overlay(channel: 1, on: false, input: nil), .overlay(channel: 3, on: false, input: nil)])
        XCTAssertEqual(ControlAction.overlayInput(channel: 2, input: 4).resolve(in: s), [.overlay(channel: 2, on: true, input: 4)])
        XCTAssertEqual(ControlAction.overlayInput(channel: 5, input: 4).resolve(in: s), [])
        // 按下时才定的输入：当前 PVW / 当前 PGM（黑场 = 解析不出）
        XCTAssertEqual(ControlAction.overlayInput(channel: 1, input: .preview).resolve(in: s), [.overlay(channel: 1, on: true, input: 2)])
        XCTAssertEqual(ControlAction.toggleMute(input: .program).resolve(in: s), [.mute(input: 1, on: true)])
        XCTAssertEqual(ControlAction.previewAndTransition(input: .program).resolve(in: s), [.setPreview(input: 1), .autoTransition])
        s.preview = MixerState.noInput
        XCTAssertEqual(ControlAction.overlayInput(channel: 1, input: .preview).resolve(in: s), [], "PVW 黑场：解析不出")
        // 界面动作不发命令（App 自己派发）
        XCTAssertEqual(ControlAction.ui(name: "toggleMixer").resolve(in: s), [])
    }

    func testHotkeys_newActionsJSONRoundTrip() throws {
        let actions: [ControlAction] = [
            .fadeMs(durationMs: 750), .previewAndTransition(input: 3), .previewAndTransition(input: .program), .overlayInput(channel: 2, input: .preview),
            .overlaysOff, .outputSwitch(output: 6, mode: .toggle), .outputKindSwitch(kind: .externalDisplay, mode: .on), .recordAll(mode: .off),
            .recordISO(mode: .toggle), .streamAll(mode: .on), .inputAFV(input: 2, mode: .off), .busRoute(input: 1, bus: .headphones, mode: .on),
            .solo(input: .program, mode: .toggle), .busMuteSwitch(bus: .master, mode: .toggle), .ui(name: "toggleMixer"), .toggleMute(input: .preview),
        ]
        let table = HotkeyTable(bindings: actions.enumerated().map { i, a in HotkeyBinding(key: KeyCombo(key: "f\(i + 1)"), action: a) })
        let data = try table.jsonData()
        XCTAssertEqual(try HotkeyTable.load(from: data), table)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["fadeMs", "previewAndTransition", "overlayInput", "overlaysOff", "outputSwitch", "outputKindSwitch", "recordAll", "recordISO",
                    "streamAll", "inputAFV", "busRoute", "solo", "busMuteSwitch", "\"ui\""] {
            XCTAssertTrue(text.contains(key), "JSON 里有 \(key)")
        }
        XCTAssertTrue(text.contains("\"input\" : \"program\""), "当前 PGM 写成字符串：\(text)")
        XCTAssertTrue(text.contains("\"mode\" : \"toggle\""))
        // 手写：mode 缺省 = 切换；输入写 "preview" / "program"
        let hand = #"{"version":1,"bindings":[{"key":"x","action":{"recordAll":{}}},{"key":"y","action":{"overlayInput":{"channel":1,"input":"preview"}}}]}"#
        let h = try HotkeyTable.load(from: Data(hand.utf8))
        XCTAssertEqual(h.bindings[0].action, .recordAll(mode: .toggle))
        XCTAssertEqual(h.bindings[1].action, .overlayInput(channel: 1, input: .preview))
        // 认不出的输入引用 / 模式：报错
        XCTAssertThrowsError(try HotkeyTable.load(from: Data(#"{"version":1,"bindings":[{"key":"x","action":{"overlayInput":{"channel":1,"input":"pvw"}}}]}"#.utf8)))
        XCTAssertThrowsError(try HotkeyTable.load(from: Data(#"{"version":1,"bindings":[{"key":"x","action":{"recordAll":{"mode":"maybe"}}}]}"#.utf8)))
        // MIDI 音符同样能绑
        let midi = MIDIMapTable(mappings: [MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.previewAndTransition(input: 2)))])
        XCTAssertEqual(try MIDIMapTable.load(from: try midi.jsonData()), midi)
    }

    // MARK: 每行"启用"（N5）

    func testHotkeys_disabledBindingIsIgnoredAndDoesNotConflict() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let table = HotkeyTable(bindings: [
            HotkeyBinding(key: KeyCombo("k")!, action: .command(.cut), enabled: false),
            HotkeyBinding(key: KeyCombo("k")!, action: .toggleFTB),
            HotkeyBinding(key: KeyCombo("j")!, action: .command(.cut), enabled: false),
        ])
        XCTAssertTrue(table.conflicts().isEmpty, "停用的行不参与冲突检查")
        XCTAssertEqual(table.action(for: KeyCombo("k")!), .toggleFTB, "停用的行跳过")
        XCTAssertNil(table.action(for: KeyCombo("j")!))
        let d = HotkeyDispatcher(bus: f.bus, table: table)
        XCTAssertFalse(d.handle(KeyCombo("j")!), "停用的键不吃")
        let text = String(decoding: try table.jsonData(), as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\"enabled\" : false").count - 1, 2, text)
        XCTAssertEqual(try HotkeyTable.load(from: Data(text.utf8)), table)
        // 两条都启用才算冲突
        var both = table
        both.bindings[0].enabled = true
        XCTAssertEqual(both.conflicts().count, 1)
        // MIDI：停用的映射不派发、不算冲突
        var m = MIDIMapper(table: MIDIMapTable(mappings: [
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.command(.cut)), enabled: false),
            MIDIMapping(trigger: .note(channel: 1, note: 60), action: .action(.toggleFTB)),
            MIDIMapping(trigger: .cc(channel: 1, controller: 1), action: .tbar, enabled: false),
        ]))
        XCTAssertTrue(m.table.conflicts().isEmpty)
        let s = TestStates.base()
        XCTAssertEqual(m.commands(for: MIDIMessage(trigger: .note(channel: 1, note: 60), value: 100, timestamp: .zero), state: s), [.ftb(on: true)])
        XCTAssertEqual(m.commands(for: MIDIMessage(trigger: .cc(channel: 1, controller: 1), value: 64, timestamp: .zero), state: s), [])
    }

    // MARK: MIDI 音符的组合动作

    func testMIDI_noteCompoundActionResolvesInOrder() {
        var m = MIDIMapper(table: MIDIMapTable(mappings: [
            MIDIMapping(trigger: .note(channel: 1, note: 36), action: .action(.previewAndTransition(input: 4))),
            MIDIMapping(trigger: .note(channel: 1, note: 37), action: .action(.overlaysOff)),
        ]))
        var s = TestStates.base()
        s.overlays[1].on = true
        s.overlays[3].on = true
        func note(_ n: Int, off: Bool = false) -> [Command] {
            m.commands(for: MIDIMessage(trigger: .note(channel: 1, note: n), value: off ? 0 : 100, isNoteOff: off, timestamp: .zero), state: s)
        }
        XCTAssertEqual(note(36), [.setPreview(input: 4), .autoTransition])
        XCTAssertEqual(note(36, off: true), [], "松开不发")
        XCTAssertEqual(note(37), [.overlay(channel: 2, on: false, input: nil), .overlay(channel: 4, on: false, input: nil)])
        XCTAssertEqual(m.command(for: MIDIMessage(trigger: .note(channel: 1, note: 36), value: 100, timestamp: .zero), state: s), .setPreview(input: 4),
                       "单条入口给第一条（老调用方）")
    }

    // MARK: 动作目录（选动作面板生成表单用，N3）

    /// 每种动作（除了包一条命令的 command）的类型化参数 = 它 JSON 那一层的键；能发哪些命令也写明（面板的小字 API 键名）。
    func testHotkeys_actionKindsDescribeFieldsLikeJSON() throws {
        let samples: [ControlAction] = [
            .toggleFTB, .toggleOverlay(channel: 1), .toggleMute(input: 2), .toggleRecord(output: 1), .toggleStream(output: 2), .toggleAFV,
            .fadeMs(durationMs: 500), .previewAndTransition(input: 3), .overlayInput(channel: 1, input: .preview), .overlaysOff,
            .outputSwitch(output: 6, mode: .toggle), .outputKindSwitch(kind: .ndi, mode: .on), .recordAll(mode: .toggle), .recordISO(mode: .on),
            .streamAll(mode: .off), .inputAFV(input: 1, mode: .toggle), .busRoute(input: 1, bus: .busA, mode: .on), .solo(input: 2, mode: .off),
            .busMuteSwitch(bus: .master, mode: .toggle), .ui(name: "toggleMixer"),
        ]
        XCTAssertEqual(Set(samples.map(ControlActionKind.init(of:))), Set(ControlActionKind.allCases).subtracting([.command]), "每种都有样本")
        for a in samples {
            let kind = ControlActionKind(of: a)
            let json = try APIJSON.encoder.encode(a)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            XCTAssertEqual(Array(object.keys), [kind.rawValue], "\(a) 的 JSON 顶层键 = 种类名")
            let body = try XCTUnwrap(object[kind.rawValue] as? [String: Any])
            XCTAssertEqual(Set(kind.fields.map(\.name)), Set(body.keys), "\(kind) 的参数描述")
            XCTAssertEqual(kind.emits.isEmpty, kind == .ui, "\(kind) 能发的命令（只有界面动作不发）")
            XCTAssertFalse(kind.group.isEmpty)
        }
        XCTAssertEqual(ControlActionKind(of: .command(.cut)), .command)
        XCTAssertEqual(ControlActionKind.previewAndTransition.emits, [.setPreview, .autoTransition])
        XCTAssertEqual(ControlActionKind.fadeMs.fields, [CommandField(name: "durationMs", type: .durationMs)])
        XCTAssertEqual(ControlActionKind.overlayInput.fields, [CommandField(name: "channel", type: .overlayChannel), CommandField(name: "input", type: .inputRef)])
        XCTAssertEqual(ControlActionKind.outputSwitch.fields, [CommandField(name: "output", type: .output(kinds: [.ndi, .externalDisplay, .virtualCamera, .multiview])),
                                                               CommandField(name: "mode", type: .switchMode)])
        XCTAssertEqual(ControlActionKind.busRoute.fields.map(\.type), [.inputRef, .bus, .switchMode])
    }

    // MARK: 界面动作（Q53）：进快捷键表，只在 App 里派发

    func testHotkeys_uiActionGoesToHandlerNotBus() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let d = HotkeyDispatcher(bus: f.bus, table: HotkeyTable(bindings: [HotkeyBinding(key: KeyCombo("ctrl+m")!, action: .ui(name: "toggleMixer"))]))
        let seen = Mutex<[String]>([])
        XCTAssertTrue(d.handle(KeyCombo("ctrl+m")!), "没装 handler 也吃掉这个键（不让它落到别处）")
        d.setUIActionHandler { name in seen.withLock { $0.append(name) } }
        let before = f.bus.lastSequence
        XCTAssertTrue(d.handle(KeyCombo("ctrl+m")!))
        let got = await waitUntil { seen.withLock { $0 } == ["toggleMixer"] }
        XCTAssertTrue(got)
        XCTAssertEqual(f.bus.lastSequence, before, "界面动作不进总线")
        XCTAssertEqual(d.counters.unresolved, 0, "界面动作不算解析不出")
    }
}
