import XCTest
@testable import SwitcherContracts

/// P2（提案 001 / 002 / 004 / 005）：Stats 新字段的 Codable 往返、缺键默认值、老 stats.jsonl 兼容；AudioBlockConsumer 升契约。
final class StatsP2Tests: XCTestCase {
    /// 新字段往返（Samples.stats 的每个新字段都是非默认值，往返才有意义）。
    func testP2_stats_newFieldsRoundTrip() throws {
        let s = Samples.stats()
        XCTAssertEqual(s.perInput[1]?.latencyMs, 33.4)
        XCTAssertEqual(s.perInput[2]?.latencyMaxMs, 18.2)
        XCTAssertEqual(s.encoder[0].frames, 215_990)
        XCTAssertEqual(s.encoder[0].diskFreeMb, 40_960.5)
        XCTAssertEqual(s.encoder[1].dropped, 12)
        XCTAssertEqual(s.encoder[1].reconnects, 2)
        XCTAssertEqual(s.audio.discontinuities, 2)
        XCTAssertEqual(s.audio.meters.buses.count, 4)
        XCTAssertEqual(s.audio.meters.inputs.count, 2)
        let back = try Stats.parse(line: try s.jsonLine())
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.encoder.map(\.state), ["recording", "publishing"])
        XCTAssertEqual(back.audio.meters.buses.map(\.bus), ["master", "busA", "busB", "headphones"])
        XCTAssertEqual(back.audio.meters.inputs[3]?.peakDb, [-120, -120])
        XCTAssertEqual(try JSONDecoder().decode(Stats.self, from: try JSONEncoder().encode(s)), s)
    }

    /// 缺键解码给默认值（0 / "idle" / 空）；写出时写全（新键一个不少，键名逐字）。
    func testP2_stats_missingKeysDecodeToDefaults_andEncodeWritesAll() throws {
        let old = #"{"audio":{"dropouts":0,"underruns":1},"cpu_pct":1,"encoder":[{"bitrate":6000000,"skipped":2}],"gpu_pct":0,"jitter_ms":0,"missed_render":0,"per_input":{"1":{"drop":0,"dup":3,"fps":30}},"render_ms":1,"rss_mb":1,"tick":1,"ts":1}"#
        let s = try Stats.parse(line: old)
        XCTAssertEqual(s.perInput[1], Stats.PerInput(fps: 30, dup: 3, drop: 0))
        XCTAssertEqual(s.perInput[1]?.latencyMs, 0)
        XCTAssertEqual(s.perInput[1]?.latencyMaxMs, 0)
        XCTAssertEqual(s.encoder[0], Stats.EncoderEntry(skipped: 2, bitrate: 6_000_000))
        XCTAssertEqual(s.encoder[0].frames, 0)
        XCTAssertEqual(s.encoder[0].dropped, 0)
        XCTAssertEqual(s.encoder[0].diskFreeMb, 0)
        XCTAssertEqual(s.encoder[0].reconnects, 0)
        XCTAssertEqual(s.encoder[0].state, "idle")
        XCTAssertEqual(s.audio, Stats.AudioCounters(dropouts: 0, underruns: 1))
        XCTAssertEqual(s.audio.discontinuities, 0)
        XCTAssertEqual(s.audio.meters, Stats.AudioCounters.Meters())
        XCTAssertTrue(s.audio.meters.buses.isEmpty && s.audio.meters.inputs.isEmpty)
        XCTAssertEqual(s.display, [], "提案 013：老行没有 display 键 → 空数组")
        // 写出写全：每一节的键集合 == jsonKeys
        let line = try s.jsonLine()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(Stats.jsonKeys))
        let perInput = try XCTUnwrap((obj["per_input"] as? [String: Any])?["1"] as? [String: Any])
        XCTAssertEqual(Set(perInput.keys), Set(Stats.PerInput.jsonKeys))
        let encoder = try XCTUnwrap((obj["encoder"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(encoder.keys), Set(Stats.EncoderEntry.jsonKeys))
        let audio = try XCTUnwrap(obj["audio"] as? [String: Any])
        XCTAssertEqual(Set(audio.keys), Set(Stats.AudioCounters.jsonKeys))
        let meters = try XCTUnwrap(audio["meters"] as? [String: Any])
        XCTAssertEqual(Set(meters.keys), Set(Stats.AudioCounters.Meters.jsonKeys))
        XCTAssertEqual(line, #"{"audio":{"discontinuities":0,"dropouts":0,"meters":{"buses":[],"inputs":{}},"underruns":1},"cpu_pct":1,"display":[],"encoder":[{"bitrate":6000000,"connections":0,"disk_free_mb":0,"dropped":0,"frames":0,"output":0,"reconnects":0,"skipped":2,"state":"idle"}],"gpu_pct":0,"jitter_ms":0,"missed_render":0,"per_input":{"1":{"drop":0,"dup":3,"fps":30,"latency_max_ms":0,"latency_ms":0}},"render_ms":1,"rss_mb":1,"tick":1,"ts":1}"#)
    }

    /// 表读数的嵌套形态（提案 004 逐字）：bus meter / input meter 的键名、inputs 以输入编号为键、Bus.name、dB 换算的下限。
    func testP2_stats_metersJsonShape() throws {
        let m = Stats.AudioCounters.BusMeter(bus: Bus.master.name, peakDb: [-6, -6.5], truePeakDb: [-5.8, -6.3], lufsM: -18, lufsS: -19, lufsI: -20, lra: 4)
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(m), as: UTF8.self),
                       #"{"bus":"master","lra":4,"lufs_i":-20,"lufs_m":-18,"lufs_s":-19,"peak_db":[-6,-6.5],"rms_db":[],"true_peak_db":[-5.8,-6.3]}"#)
        XCTAssertEqual(Stats.AudioCounters.BusMeter.jsonKeys, ["bus", "peak_db", "rms_db", "true_peak_db", "lufs_m", "lufs_s", "lufs_i", "lra"])   // 017 加 rms_db
        XCTAssertEqual(Stats.AudioCounters.InputMeter.jsonKeys, ["peak_db", "rms_db"])
        XCTAssertEqual(Stats.AudioCounters.Meters.jsonKeys, ["buses", "inputs"])
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(Stats.AudioCounters.InputMeter(peakDb: [-12, -120])), as: UTF8.self), #"{"peak_db":[-12,-120],"rms_db":[]}"#)
        let meters = Stats.AudioCounters.Meters(buses: [], inputs: [7: .init(peakDb: [-1, -2])])
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(meters), as: UTF8.self), #"{"buses":[],"inputs":{"7":{"peak_db":[-1,-2],"rms_db":[]}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.AudioCounters.Meters.self, from: try Stats.lineEncoder.encode(meters)), meters)
        // Bus.name：与 BusRouting 的 JSON 键一致，可逆
        XCTAssertEqual(Bus.allCases.map(\.name), ["master", "busA", "busB", "headphones"])
        for b in Bus.allCases { XCTAssertEqual(Bus(name: b.name), b) }
        XCTAssertNil(Bus(name: "sub"))
        // dB / LUFS 换算：下限 −120，非有限 → 下限（JSON 写不了 −inf）
        XCTAssertEqual(Stats.AudioCounters.Meters.decibels(fromLinear: 1), 0)
        XCTAssertEqual(Stats.AudioCounters.Meters.decibels(fromLinear: 0), -120)
        XCTAssertEqual(Stats.AudioCounters.Meters.decibels(fromLinear: 1e-9), -120)
        XCTAssertEqual(Stats.AudioCounters.Meters.decibels(fromLinear: 0.5), 20 * log10(0.5), accuracy: 1e-12)
        XCTAssertEqual(Stats.AudioCounters.Meters.loudness(-Double.infinity), -120)
        XCTAssertEqual(Stats.AudioCounters.Meters.loudness(.nan), -120)
        XCTAssertEqual(Stats.AudioCounters.Meters.loudness(-23), -23)
        XCTAssertEqual(Stats.AudioCounters.Meters.floorDb, -120)
    }

    /// G2 / G3 留下的老 stats.jsonl（.build/gate2、.build/gate3 下的 stats*.jsonl，不入库）每行都能 parse(line:)。
    /// 没有这些文件的机器只验证嵌入的老行（G2 10min、G3 10min 各一行的节选）。
    func testP2_stats_oldGateFilesParse() throws {
        let embedded = [
            #"{"audio":{"dropouts":0,"underruns":0},"cpu_pct":15.90925202238095,"encoder":[{"bitrate":35704,"skipped":0}],"gpu_pct":20,"jitter_ms":0.013916,"missed_render":0,"per_input":{"1":{"drop":0,"dup":11,"fps":11.952931352473495},"2":{"drop":0,"dup":11,"fps":11.952931352473495},"3":{"drop":0,"dup":0,"fps":22.909785092240867}},"render_ms":2.925098136363636,"rss_mb":700.5,"tick":60,"ts":1757900000.5}"#,
            #"{"audio":{"dropouts":0,"underruns":0},"cpu_pct":23.840288126146607,"encoder":[{"bitrate":24424,"skipped":0},{"bitrate":24424,"skipped":0},{"bitrate":24424,"skipped":0},{"bitrate":24424,"skipped":0},{"bitrate":24424,"skipped":0}],"gpu_pct":22,"jitter_ms":0.016916,"missed_render":0,"per_input":{"1":{"drop":0,"dup":5,"fps":5.943578600919102},"2":{"drop":0,"dup":0,"fps":10.896560768351687}},"render_ms":3.1,"rss_mb":800,"tick":60,"ts":1757950000.5}"#,
        ]
        for line in embedded {
            let s = try Stats.parse(line: line)
            XCTAssertTrue(s.encoder.allSatisfy { $0.state == "idle" && $0.frames == 0 && $0.dropped == 0 && $0.reconnects == 0 && $0.diskFreeMb == 0 })
            XCTAssertEqual(s.audio.meters, Stats.AudioCounters.Meters())
            XCTAssertEqual(s.audio.discontinuities, 0)
            XCTAssertTrue(s.perInput.values.allSatisfy { $0.latencyMs == 0 && $0.latencyMaxMs == 0 })
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }   // …/Packages/SwitcherCore/Tests/SwitcherContractsTests/本文件 → 仓库根
        var files: [URL] = []
        for dir in ["gate2", "gate3"] {
            let base = root.appendingPathComponent(".build").appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.lastPathComponent.hasPrefix("stats") && url.pathExtension == "jsonl" { files.append(url) }
        }
        var total = 0
        for f in files.sorted(by: { $0.path < $1.path }) {
            let text = try String(contentsOf: f, encoding: .utf8)
            var n = 0
            for l in text.split(separator: "\n") where !l.isEmpty {
                do { _ = try Stats.parse(line: String(l)) } catch { XCTFail("\(f.path) 第 \(n + 1) 行解析失败：\(error)"); return }
                n += 1
            }
            XCTAssertGreaterThan(n, 0, f.path)
            total += n
        }
        print("老 stats.jsonl：\(files.count) 个文件 \(total) 行全部解析（\(root.path)/.build/gate2、gate3）")
        if files.isEmpty { throw XCTSkip("本机没有 .build/gate2 / .build/gate3 下的老 stats.jsonl，只验证了嵌入的样行") }
    }

    /// 提案 001 B：AudioBlockConsumer 在契约里，签名逐字 = W1-E 原版；能按 `any AudioBlockConsumer` 派发。
    func testP2_audioBlockConsumer_isAContractProtocol() {
        final class Sink: AudioBlockConsumer {
            let consumerName = "sink"
            var frames = 0, channels = 0, firstSample: Float = 0
            var last: HostTime = .zero
            func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
                frames += frameCount; channels = channelCount; last = hostTime; firstSample = planes[1][1]
            }
        }
        let sink = Sink()
        let consumers: [any AudioBlockConsumer] = [sink]
        let left: [Float] = [0.25, 0.5], right: [Float] = [-0.25, -0.5]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                let planes: [UnsafePointer<Float>] = [l.baseAddress!, r.baseAddress!]
                planes.withUnsafeBufferPointer { p in
                    for c in consumers { c.consumeAudio(planes: p.baseAddress!, channelCount: 2, frameCount: 2, hostTime: HostTime(ticks: 42)) }
                }
            }
        }
        XCTAssertEqual(sink.consumerName, "sink")
        XCTAssertEqual(sink.frames, 2)
        XCTAssertEqual(sink.channels, 2)
        XCTAssertEqual(sink.last, HostTime(ticks: 42))
        XCTAssertEqual(sink.firstSample, -0.5)
    }
}
