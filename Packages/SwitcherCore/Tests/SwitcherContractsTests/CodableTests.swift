import XCTest
@testable import SwitcherContracts

/// Stats / Show / Scenario / MixerState / Command 的 Codable 往返与键名快照。
final class CodableTests: XCTestCase {
    private var sortedEncoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }

    // MARK: Stats

    /// 键名写死在测试里：与测试标准 §7 那一行逐字一致，改了就红。
    func testP1_stats_jsonKeysSnapshot() throws {
        let line = try Samples.stats().jsonLine()
        XCTAssertEqual(line, #"{"audio":{"dropouts":0,"underruns":1},"cpu_pct":12.5,"encoder":[{"bitrate":6000000,"skipped":0},{"bitrate":2500000,"skipped":3}],"gpu_pct":30,"jitter_ms":0.42,"missed_render":0,"per_input":{"1":{"drop":0,"dup":30,"fps":30},"2":{"drop":1,"dup":0,"fps":60}},"render_ms":1.75,"rss_mb":512.25,"tick":216000,"ts":1757690000.5}"#)
        XCTAssertFalse(line.contains("\n"), "一行一个 JSON")
        XCTAssertEqual(Stats.jsonKeys, ["ts", "tick", "render_ms", "missed_render", "jitter_ms", "per_input", "encoder", "audio", "rss_mb", "cpu_pct", "gpu_pct"])
        XCTAssertEqual(Stats.PerInput.jsonKeys, ["fps", "dup", "drop"])
        XCTAssertEqual(Stats.EncoderEntry.jsonKeys, ["skipped", "bitrate"])
        XCTAssertEqual(Stats.AudioCounters.jsonKeys, ["dropouts", "underruns"])
        // 顶层键集合与 jsonKeys 完全一致（没多没少）
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(Stats.jsonKeys))
    }

    func testP1_stats_roundTrip() throws {
        let s = Samples.stats()
        XCTAssertEqual(try Stats.parse(line: try s.jsonLine()), s)
        XCTAssertEqual(try JSONDecoder().decode(Stats.self, from: try JSONEncoder().encode(s)), s)
        // 多行文件
        let text = try [s, s].map { try $0.jsonLine() }.joined(separator: "\n") + "\n"
        XCTAssertEqual(try Stats.parse(lines: text), [s, s])
    }

    // MARK: MixerState / Show / Scenario

    func testP1_mixerState_roundTrip() throws {
        let s = Samples.mixerState()
        let data = try sortedEncoder.encode(s)
        XCTAssertEqual(try JSONDecoder().decode(MixerState.self, from: data), s)
        XCTAssertNoThrow(try s.validate())
    }

    func testP1_show_roundTrip() throws {
        let show = Samples.show()
        let data = try show.save()
        let back = try Show.load(from: data)
        XCTAssertEqual(back, show)
        XCTAssertEqual(back.schemaVersion, 1)
        XCTAssertEqual(Show.currentSchemaVersion, 1)
        // 顶层键固定：schemaVersion, name, inputs, mixer, audio, outputs, layout
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["schemaVersion", "name", "inputs", "mixer", "audio", "outputs", "layout"])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        // layout 原样保留（不解释）
        XCTAssertEqual(back.layout.values["mixerVisible"], .bool(true))
        // Show ↔ MixerState：makeState 清掉瞬态（转场进度、动画进度、startTick）
        let state = back.makeState()
        XCTAssertEqual(state.inputs, show.inputs)
        XCTAssertEqual(state.outputs, show.outputs)
        XCTAssertEqual(state.audio, show.audio)
        XCTAssertEqual(state.program, 1)
        XCTAssertEqual(state.transition.type, .wipe)
        XCTAssertEqual(state.transition.progress, 0)
        XCTAssertNil(state.transition.startTick)
        XCTAssertEqual(state.ftb.level, 1, "ftb.on = true 时 level 直接落到 1")
        XCTAssertEqual(state.overlays[0].animProgress, 1)
        XCTAssertEqual(state.overlays[2].animProgress, 0)
        XCTAssertNil(state.overlays[2].startTick)
    }

    func testP1_show_migratePlaceholder() throws {
        XCTAssertThrowsError(try Show.load(from: #"{"schemaVersion": 2, "name": "x"}"#.data(using: .utf8)!)) { error in
            guard case ShowError.unsupportedSchemaVersion(let v) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(v, 2)
        }
        XCTAssertThrowsError(try Show.load(from: #"{"name": "x"}"#.data(using: .utf8)!)) { error in
            guard case ShowError.malformed = error else { return XCTFail("\(error)") }
        }
        // v1 文档经 migrate 走一遍恒等
        let show = Samples.show()
        let doc = try JSONDecoder().decode(JSONValue.self, from: try show.save())
        XCTAssertEqual(try Show.migrate(from: doc, schemaVersion: 1), show)
        XCTAssertThrowsError(try Show.migrate(from: doc, schemaVersion: 0))
    }

    func testP1_scenario_roundTrip() throws {
        let sc = Samples.scenario()
        let data = try sortedEncoder.encode(sc)
        XCTAssertEqual(try JSONDecoder().decode(Scenario.self, from: data), sc)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix(#"{"durationTicks":216000,"events":[{"command":{"cut":{}},"tick":1000},{"command":{"fade":{"durationTicks":30}},"tick":3000}"#), text)
        // 事件按 tick 排序的视图
        let unsorted = Scenario(durationTicks: 10, events: [ScenarioEvent(tick: Tick(5), command: .cut), ScenarioEvent(tick: Tick(1), command: .autoTransition)])
        XCTAssertEqual(unsorted.sortedEvents.map(\.tick), [Tick(1), Tick(5)])
    }

    // MARK: Command

    /// 每个 case 至少一个构造样例并往返 JSON。
    func testP1_command_everyCaseRoundTrips() throws {
        let samples = Samples.commands()
        XCTAssertEqual(Set(samples.map(Samples.caseName(of:))).count, Samples.commandCaseCount, "每个 case 都要有样例")
        for c in samples {
            let data = try sortedEncoder.encode(c)
            let back = try JSONDecoder().decode(Command.self, from: data)
            XCTAssertEqual(back, c, String(data: data, encoding: .utf8)!)
        }
        // 信封与回执
        let issued = IssuedCommand(sequence: 7, issuedAt: HostTime(ticks: 99), command: .tbar(progress: 0.25))
        XCTAssertEqual(try JSONDecoder().decode(IssuedCommand.self, from: try sortedEncoder.encode(issued)), issued)
        XCTAssertEqual(String(data: try sortedEncoder.encode(issued), encoding: .utf8), #"{"command":{"tbar":{"progress":0.25}},"issuedAt":99,"sequence":7}"#)
        let receipt = CommandReceipt(sequence: 7, appliedTick: Tick(1234))
        XCTAssertEqual(String(data: try sortedEncoder.encode(receipt), encoding: .utf8), #"{"appliedTick":1234,"sequence":7}"#)
    }

    /// 命令 JSON 形态快照（HTTP API 的 wire format，改了 W2-C 的客户端就断）。
    func testP1_command_jsonShapeSnapshot() throws {
        func json(_ c: Command) throws -> String { String(data: try sortedEncoder.encode(c), encoding: .utf8)! }
        XCTAssertEqual(try json(.cut), #"{"cut":{}}"#)
        XCTAssertEqual(try json(.fade(durationTicks: 30)), #"{"fade":{"durationTicks":30}}"#)
        XCTAssertEqual(try json(.setPreview(input: 2)), #"{"setPreview":{"input":2}}"#)
        XCTAssertEqual(try json(.tbar(progress: 0.5)), #"{"tbar":{"progress":0.5}}"#)
        XCTAssertEqual(try json(.overlay(channel: 1, on: true, input: nil)), #"{"overlay":{"channel":1,"on":true}}"#)
        XCTAssertEqual(try json(.overlay(channel: 1, on: true, input: 4)), #"{"overlay":{"channel":1,"input":4,"on":true}}"#)
        XCTAssertEqual(try json(.audioGain(input: 3, dB: -6)), #"{"audioGain":{"dB":-6,"input":3}}"#)
        XCTAssertEqual(try json(.busGain(bus: .busA, dB: 1)), #"{"busGain":{"bus":1,"dB":1}}"#)
        XCTAssertEqual(try json(.setTransition(type: .wipe, durationTicks: 20)), #"{"setTransition":{"durationTicks":20,"type":"wipe"}}"#)
        XCTAssertEqual(try json(.startStream(output: 2)), #"{"startStream":{"output":2}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: #"{"cut":{}}"#.data(using: .utf8)!), .cut)
        XCTAssertThrowsError(try JSONDecoder().decode(Command.self, from: #"{"nope":{}}"#.data(using: .utf8)!))
    }

    // MARK: 其他类型

    func testP1_inputTypes_codable() throws {
        for input in Samples.inputs() {
            XCTAssertEqual(try JSONDecoder().decode(InputConfig.self, from: try sortedEncoder.encode(input)), input)
        }
        for state in [InputState.live, .noSignal, .error(message: "无权限")] {
            XCTAssertEqual(try JSONDecoder().decode(InputState.self, from: try sortedEncoder.encode(state)), state)
        }
        XCTAssertEqual(String(data: try sortedEncoder.encode(InputState.error(message: "x")), encoding: .utf8), #"{"error":{"message":"x"}}"#)
        XCTAssertEqual(String(data: try sortedEncoder.encode(InputKind.decklink), encoding: .utf8), #""decklink""#)
        XCTAssertEqual(InputKind.allCases.count, 8)
    }

    func testP1_jsonValue_roundTrip() throws {
        let v: JSONValue = .object(["a": 1, "b": "s", "c": .array([true, .null, 2.5]), "d": .object([:])])
        let data = try sortedEncoder.encode(v)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"a":1,"b":"s","c":[true,null,2.5],"d":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
    }
}
