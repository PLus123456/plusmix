import XCTest
@testable import SwitcherContracts

/// 提案 030（用户 2026-10-17 批，P5-4 / prompt 115 落地）：`Stats.audio.effects`——效果链的处理延迟进 Stats（铁律 4）。
/// `buses[{bus, latency_ms, measured_latency_ms?}]`（四条总线 Master / Bus A / Bus B / 耳机，没装效果 = 0；耳机总线是用户 2026-10-18 裁定 #1 加的，P5-5 / prompt 123）
/// + `inputs{"n": {latency_ms, measured_latency_ms?}}`（只列装了效果的路）；
/// `measured_latency_ms` = 自写压缩器冲激法自测的延迟，链里没有它就缺键。瞬时值；缺键 = 空，写出总是写全；不加命令、不进 per_input、顶层键不变。
final class Contracts030Tests: XCTestCase {
    typealias E = Stats.AudioCounters.EffectsLatency

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// JSON 形态逐字：buses 是数组（按 bus 认），inputs 以输入编号的字符串为键；measured 为 nil 不写键；在 audio 一节里的键是 effects，空也写。
    func test030_effectsJsonShape_busesArrayInputsByNumber_measuredOptional() throws {
        let fx = E(buses: [E.BusLatency(bus: Bus.master.name, latencyMs: 5.5, measuredLatencyMs: 0),
                           E.BusLatency(bus: Bus.busA.name, latencyMs: 0),
                           E.BusLatency(bus: Bus.busB.name, latencyMs: 12),
                           E.BusLatency(bus: Bus.headphones.name, latencyMs: 12)],   // 耳机条的"效果"（用户 2026-10-18 裁定 #1）
                   inputs: [3: E.InputLatency(latencyMs: 1.5, measuredLatencyMs: 0), 7: E.InputLatency(latencyMs: 0)])
        let json = String(decoding: try Stats.lineEncoder.encode(fx), as: UTF8.self)
        XCTAssertEqual(json, #"{"buses":[{"bus":"master","latency_ms":5.5,"measured_latency_ms":0},{"bus":"busA","latency_ms":0},{"bus":"busB","latency_ms":12},{"bus":"headphones","latency_ms":12}],"inputs":{"3":{"latency_ms":1.5,"measured_latency_ms":0},"7":{"latency_ms":0}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(E.self, from: Data(json.utf8)), fx)
        // audio 一节：默认空，写出总是写全（"effects":{"buses":[],"inputs":{}}）
        let audio = Stats.AudioCounters(dropouts: 0, underruns: 0)
        XCTAssertEqual(audio.effects, E())
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(audio), as: UTF8.self),
                       #"{"discontinuities":0,"dropouts":0,"effects":{"buses":[],"inputs":{}},"meters":{"buses":[],"inputs":{}},"underruns":0}"#)
        // 构造函数：effects 是最后一个、带默认值的参数（现有调用点不改）
        let filled = Stats.AudioCounters(dropouts: 1, underruns: 2, discontinuities: 3, meters: Stats.AudioCounters.Meters(), effects: fx)
        XCTAssertEqual(filled.effects, fx)
        // 整行往返
        var s = Samples.stats()
        s.audio.effects = fx
        XCTAssertEqual(try Stats.parse(line: try s.jsonLine()), s)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try s.jsonLine().utf8)) as? [String: Any])
        let audioObj = try XCTUnwrap(obj["audio"] as? [String: Any])
        XCTAssertEqual(Set(audioObj.keys), Set(Stats.AudioCounters.jsonKeys))
        let effectsObj = try XCTUnwrap(audioObj["effects"] as? [String: Any])
        XCTAssertEqual(Set(effectsObj.keys), Set(E.jsonKeys))
        let master = try XCTUnwrap((effectsObj["buses"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(master.keys), Set(E.BusLatency.jsonKeys), "measured 有值时三个键都写")
        let input3 = try XCTUnwrap((effectsObj["inputs"] as? [String: [String: Any]])?["3"])
        XCTAssertEqual(Set(input3.keys), Set(E.InputLatency.jsonKeys))
    }

    /// 缺键 = 空：030 之前的 audio 一节没有 effects；effects 里缺 buses / inputs 各自为空；measured_latency_ms 缺键 = nil；App 的老 stats.jsonl 照读。
    func test030_missingKeysDecodeToEmpty_legacyLinesStillParse() throws {
        let old = try JSONDecoder().decode(Stats.AudioCounters.self,
                                           from: Data(#"{"discontinuities":0,"dropouts":0,"meters":{"buses":[],"inputs":{}},"underruns":0}"#.utf8))
        XCTAssertEqual(old.effects, E())
        XCTAssertEqual(old.effects.buses, [])
        XCTAssertEqual(old.effects.inputs, [:])
        XCTAssertEqual(try JSONDecoder().decode(Stats.AudioCounters.self, from: Data(#"{"dropouts":0,"underruns":1}"#.utf8)).effects, E(), "P2 之前的最老形态")
        XCTAssertEqual(try JSONDecoder().decode(E.self, from: Data("{}".utf8)), E())
        XCTAssertEqual(try JSONDecoder().decode(E.self, from: Data(#"{"buses":[{"bus":"master","latency_ms":2}]}"#.utf8)),
                       E(buses: [E.BusLatency(bus: "master", latencyMs: 2)]))
        XCTAssertEqual(try JSONDecoder().decode(E.self, from: Data(#"{"inputs":{"2":{"latency_ms":0}}}"#.utf8)), E(inputs: [2: E.InputLatency(latencyMs: 0)]))
        XCTAssertNil(try JSONDecoder().decode(E.BusLatency.self, from: Data(#"{"bus":"busA","latency_ms":0}"#.utf8)).measuredLatencyMs)
        XCTAssertNil(try JSONDecoder().decode(E.InputLatency.self, from: Data(#"{"latency_ms":5.333}"#.utf8)).measuredLatencyMs)
        let url = Self.repoRoot.appendingPathComponent("App/Tests/Artifacts/w2-app-status-line-stats.jsonl")
        let lines = try Stats.parse(lines: String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(lines.isEmpty)
        for l in lines { XCTAssertEqual(l.audio.effects, E()) }
    }

    /// 键名快照、列哪几条总线（四条，含耳机总线：用户 2026-10-18 裁定 #1，P5-5）、帧 → 毫秒的口径（采样率 = AudioFormat.sampleRate）；Stats 顶层与 per_input 不变（effects 只在 audio 里）。
    func test030_jsonKeysSnapshot_listedBuses_millisecondsFromFrames() throws {
        XCTAssertEqual(Stats.AudioCounters.jsonKeys, ["dropouts", "underruns", "discontinuities", "meters", "effects"])
        XCTAssertEqual(E.jsonKeys, ["buses", "inputs"])
        XCTAssertEqual(E.BusLatency.jsonKeys, ["bus", "latency_ms", "measured_latency_ms"])
        XCTAssertEqual(E.InputLatency.jsonKeys, ["latency_ms", "measured_latency_ms"])
        XCTAssertEqual(E.listedBuses, Bus.allCases, "四条总线都列：耳机总线也能装效果（调音台耳机条有\"效果\"按钮），用户 2026-10-18 裁定 #1")
        XCTAssertEqual(E.listedBuses.map(\.name), ["master", "busA", "busB", "headphones"], "bus 的取值与 meters.buses[].bus 同一写法（Bus.name）")
        XCTAssertEqual(AudioFormat.sampleRate, 48_000)
        XCTAssertEqual(E.milliseconds(frames: 0), 0)
        XCTAssertEqual(E.milliseconds(frames: 48), 1, accuracy: 1e-12)
        XCTAssertEqual(E.milliseconds(frames: 256), 256_000.0 / 48_000.0, accuracy: 1e-12, "DynamicsProcessor 的 256 帧前瞻 = 5.333 ms")
        XCTAssertEqual(E.milliseconds(frames: 576), 12, accuracy: 1e-12, "PeakLimiter 起音 12 ms = 576 帧")
        XCTAssertEqual(Stats.jsonKeys, ["ts", "tick", "render_ms", "missed_render", "jitter_ms", "per_input", "encoder", "display", "audio", "rss_mb", "cpu_pct", "gpu_pct", "video_delay_ms"])
        XCTAssertEqual(Stats.PerInput.jsonKeys, ["fps", "dup", "drop", "latency_ms", "latency_max_ms"], "不进 per_input（那是视频计数）")
        XCTAssertEqual(Stats.AudioCounters.Meters.jsonKeys, ["buses", "inputs"])
    }
}
