import XCTest
import Foundation
import SwitcherContracts
import Synchronization
@testable import SwitcherTestKit

/// StatsWriter（SPSC → 写线程 → jsonl）与 StatsSummary（avg / p99 / max、§4 判定、§7 表格）。
final class StatsTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1a-stats-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func sample(ts: Double, tick: Int64, render: Double = 4, jitter: Double = 1, missed: UInt64 = 0, rss: Double = 300,
                        cpu: Double = 30, gpu: Double = 20, dup: UInt64 = 0, drop: UInt64 = 0, fps: Double = 60,
                        skipped: UInt64 = 0, dropouts: UInt64 = 0) -> Stats {
        Stats(ts: ts, tick: Tick(tick), renderMs: render, missedRender: missed, jitterMs: jitter,
              perInput: [1: .init(fps: fps, dup: dup, drop: drop), 2: .init(fps: 30, dup: dup, drop: 0)],
              encoder: [.init(skipped: skipped, bitrate: 6_000_000)], audio: .init(dropouts: dropouts, underruns: 0),
              rssMb: rss, cpuPct: cpu, gpuPct: gpu)
    }

    // MARK: StatsWriter

    func testW1A_statsWriter_linesRoundTripThroughFile() throws {
        let url = tempURL("stats.jsonl")
        let writer = try StatsWriter(url: url)
        let lines = (0..<5).map { sample(ts: 1000 + Double($0), tick: Int64($0) * 60, render: Double($0)) }
        for l in lines { XCTAssertTrue(writer.submit(l)) }
        writer.close()
        XCTAssertEqual(writer.writtenLines, 5); XCTAssertEqual(writer.droppedLines, 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(try Stats.parse(lines: text), lines)
        // 每行键序固定（Stats.lineEncoder 排序键），jsonl 一行一条不带缩进
        XCTAssertFalse(text.contains("\n\n")); XCTAssertFalse(text.contains("  "))
        // 追加模式：再开一次写 1 行 → 6 行
        let writer2 = try StatsWriter(url: url)
        writer2.submit(sample(ts: 2000, tick: 999))
        writer2.close()
        XCTAssertEqual(try Stats.parse(lines: String(contentsOf: url, encoding: .utf8)).count, 6)
    }

    func testW1A_statsWriter_submitNeverBlocks_dropsWhenQueueFull() throws {
        let url = tempURL("burst.jsonl")
        let writer = try StatsWriter(url: url, queueCapacity: 16)
        var accepted = 0
        let t0 = HostClock.now()
        for i in 0..<2000 where writer.submit(sample(ts: Double(i), tick: Int64(i))) { accepted += 1 }
        let elapsedMs = (HostClock.now() - t0).milliseconds
        writer.close()
        XCTAssertLessThan(elapsedMs, 200, "2000 次 submit 不该等写线程")
        XCTAssertEqual(writer.writtenLines + writer.droppedLines, 2000)
        XCTAssertEqual(writer.writtenLines, accepted)
        XCTAssertGreaterThan(writer.droppedLines, 0, "16 深的队列装不下 2000 条突发")
        XCTAssertEqual(try Stats.parse(lines: String(contentsOf: url, encoding: .utf8)).count, accepted)
    }

    func testW1A_statsWriter_samplingAt1HzUsesSamplerOnWriterSide() throws {
        let url = tempURL("sampled.jsonl")
        let writer = try StatsWriter(url: url)
        let counter = Atomic<Int>(0)
        writer.startSampling(every: 0.05) { [counter] in
            let n = counter.add(1, ordering: .relaxed).oldValue
            return Stats(ts: Double(n), tick: Tick(Int64(n)), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                         audio: .init(dropouts: 0, underruns: 0), rssMb: 0, cpuPct: 0, gpuPct: 0)
        }
        Thread.sleep(forTimeInterval: 0.5)
        writer.close()
        let lines = try Stats.parse(lines: String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThanOrEqual(lines.count, 7)
        XCTAssertLessThanOrEqual(lines.count, 12)
        XCTAssertEqual(lines.map { Int($0.ts) }, Array(0..<lines.count), "按顺序、不丢")
    }

    func testW1A_statsWriter_nonFiniteValuesSanitizedToZero() throws {
        let url = tempURL("nan.jsonl")
        let writer = try StatsWriter(url: url)
        writer.submit(sample(ts: 1, tick: 1, render: .nan, jitter: .infinity))
        writer.close()
        XCTAssertEqual(writer.sanitizedLines, 1)
        let s = try Stats.parse(lines: String(contentsOf: url, encoding: .utf8))[0]
        XCTAssertEqual(s.renderMs, 0); XCTAssertEqual(s.jitterMs, 0)
    }

    // MARK: StatsSummary

    /// p99 用最近秩法：升序排序后取第 ceil(0.99 × N) 个（1 起），不插值。
    func testW1A_statsSummary_percentileNearestRank() {
        XCTAssertEqual(StatsSummary.percentile((1...100).map(Double.init), 0.99), 99)
        XCTAssertEqual(StatsSummary.percentile((1...100).map(Double.init), 0.5), 50)
        XCTAssertEqual(StatsSummary.percentile([4, 1, 3, 2], 0.5), 2, "ceil(0.5 × 4) = 2 → 第 2 个 = 2，不是 2.5")
        XCTAssertEqual(StatsSummary.percentile([3.0, 5.0, 4.0, 6.5, 2.5], 0.99), 6.5, "ceil(4.95) = 5 → 最大值")
        XCTAssertEqual(StatsSummary.percentile([7], 0.99), 7)
        XCTAssertEqual(StatsSummary.percentile([], 0.99), 0)
        XCTAssertEqual(StatsSummary.percentile((1...1000).map(Double.init), 0.99), 990)
    }

    /// 提案 013：`StatsSummary.displays` 按 (output, kind) 分组——显示类输出会中途出现 / 消失，
    /// 不能像 encoder 那样按下标；frames / dropped 取末行 − 首行，state 取末行与全程出现过的状态。
    func testP3_statsSummary_displaysGroupedByOutputAndKind() throws {
        func line(_ i: Int, _ display: [Stats.DisplayEntry]) -> Stats {
            Stats(ts: 1000 + Double(i), tick: Tick(Int64(i) * 60), renderMs: 1, missedRender: 0, jitterMs: 0,
                  perInput: [:], encoder: [], audio: Stats.AudioCounters(dropouts: 0, underruns: 0),
                  rssMb: 1, cpuPct: 1, gpuPct: 0, display: display)
        }
        let s = StatsSummary(lines: [
            line(0, [Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 10, dropped: 0, state: "presenting"),
                     Stats.DisplayEntry(output: 0, kind: "monitor", frames: 5, dropped: 0, state: "presenting")]),
            // 第 2 行：外部显示掉线，虚拟摄像头才开起来（中途出现）
            line(1, [Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 70, dropped: 1, state: "noDisplay"),
                     Stats.DisplayEntry(output: 0, kind: "monitor", frames: 65, dropped: 0, state: "presenting"),
                     Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 0, dropped: 3, state: "waitingExtension")]),
            // 第 3 行：监视器这一项消失（窗口关了）
            line(2, [Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 130, dropped: 1, state: "presenting"),
                     Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 55, dropped: 3, state: "publishing")]),
        ])
        let d = try XCTUnwrap(s.displays)
        XCTAssertEqual(d.map { "\($0.output)/\($0.kind)" }, ["0/monitor", "3/externalDisplay", "4/virtualCamera"], "按输出编号升序、同编号按 kind")
        let ext = try XCTUnwrap(d.first { $0.kind == "externalDisplay" })
        XCTAssertEqual([ext.frames, ext.dropped], [120, 1], "末行 − 首行")
        XCTAssertEqual(ext.lastState, "presenting")
        XCTAssertEqual(ext.states, ["presenting": 2, "noDisplay": 1], "全程出现过的状态各几行")
        let cam = try XCTUnwrap(d.first { $0.kind == "virtualCamera" })
        XCTAssertEqual([cam.frames, cam.dropped], [55, 0], "中途出现的：只按它出现过的那几行算")
        XCTAssertEqual(cam.lastState, "publishing")
        let mon = try XCTUnwrap(d.first { $0.kind == "monitor" })
        XCTAssertEqual(mon.frames, 60, "中途消失的：末次出现 − 首次出现")
        // 往返
        XCTAssertEqual(try JSONDecoder().decode(StatsSummary.self, from: try JSONEncoder().encode(s)), s)
        // P3 之前的基线没有 displays 键：解出来是 nil（与 P2 的可选字段同一做法）
        var old = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as! [String: Any]
        old["displays"] = nil
        XCTAssertNil(try JSONDecoder().decode(StatsSummary.self, from: try JSONSerialization.data(withJSONObject: old)).displays)
        // 没有 display 项的文件：空数组而不是 nil
        XCTAssertEqual(StatsSummary(lines: [line(0, []), line(1, [])]).displays, [])
    }

    /// 提案 018：`DisplaySummary.undelivered` 与 frames / dropped 同一算法（末行 − 首行）；018 之前写的摘要没有这个键，按 0 解。
    func test018_statsSummary_displayUndelivered() throws {
        func line(_ i: Int, _ display: [Stats.DisplayEntry]) -> Stats {
            Stats(ts: 1000 + Double(i), tick: Tick(Int64(i) * 60), renderMs: 1, missedRender: 0, jitterMs: 0,
                  perInput: [:], encoder: [], audio: Stats.AudioCounters(dropouts: 0, underruns: 0),
                  rssMb: 1, cpuPct: 1, gpuPct: 0, display: display)
        }
        let s = StatsSummary(lines: [
            line(0, [Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 0, dropped: 0, undelivered: 60, state: "waitingExtension"),
                     Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 10, dropped: 0, undelivered: 0, state: "presenting")]),
            line(1, [Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 0, dropped: 0, undelivered: 120, state: "waitingExtension"),
                     Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 10, dropped: 0, undelivered: 45, state: "noDisplay")]),
            line(2, [Stats.DisplayEntry(output: 4, kind: "virtualCamera", frames: 60, dropped: 1, undelivered: 130, state: "publishing"),
                     Stats.DisplayEntry(output: 3, kind: "externalDisplay", frames: 55, dropped: 0, undelivered: 62, state: "presenting")]),
        ])
        let d = try XCTUnwrap(s.displays)
        let cam = try XCTUnwrap(d.first { $0.kind == "virtualCamera" })
        XCTAssertEqual([cam.frames, cam.dropped, cam.undelivered], [60, 1, 70], "末行 − 首行")
        let ext = try XCTUnwrap(d.first { $0.kind == "externalDisplay" })
        XCTAssertEqual([ext.frames, ext.dropped, ext.undelivered], [45, 0, 62])
        XCTAssertEqual(try JSONDecoder().decode(StatsSummary.self, from: try JSONEncoder().encode(s)), s)
        // 018 之前的摘要（displays 里没有 undelivered）照样能解，按 0
        var old = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as! [String: Any]
        old["displays"] = (old["displays"] as! [[String: Any]]).map { var e = $0; e["undelivered"] = nil; return e }
        let back = try JSONDecoder().decode(StatsSummary.self, from: try JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(back.displays?.map(\.undelivered), [0, 0])
        XCTAssertEqual(back.displays?.map(\.frames), [45, 60])
    }

    /// 手写 5 行 jsonl，avg / p99 / max 与手算一致。
    func testW1A_statsSummary_handWrittenJsonlMatchesHandCalculation() throws {
        let text = """
        {"audio":{"dropouts":0,"underruns":0},"cpu_pct":40,"encoder":[{"bitrate":6000000,"skipped":0}],"gpu_pct":20,"jitter_ms":1.0,"missed_render":0,"per_input":{"1":{"drop":0,"dup":0,"fps":60},"2":{"drop":0,"dup":0,"fps":30}},"render_ms":3.0,"rss_mb":300,"tick":0,"ts":1000}
        {"audio":{"dropouts":0,"underruns":0},"cpu_pct":50,"encoder":[{"bitrate":6100000,"skipped":0}],"gpu_pct":22,"jitter_ms":0.5,"missed_render":0,"per_input":{"1":{"drop":0,"dup":0,"fps":60},"2":{"drop":0,"dup":40,"fps":30}},"render_ms":5.0,"rss_mb":301,"tick":60,"ts":1001}
        {"audio":{"dropouts":0,"underruns":0},"cpu_pct":60,"encoder":[{"bitrate":5900000,"skipped":1}],"gpu_pct":24,"jitter_ms":3.5,"missed_render":1,"per_input":{"1":{"drop":1,"dup":0,"fps":60},"2":{"drop":0,"dup":80,"fps":30}},"render_ms":4.0,"rss_mb":302,"tick":120,"ts":1002}
        {"audio":{"dropouts":0,"underruns":1},"cpu_pct":30,"encoder":[{"bitrate":6000000,"skipped":1}],"gpu_pct":26,"jitter_ms":2.0,"missed_render":1,"per_input":{"1":{"drop":1,"dup":0,"fps":60},"2":{"drop":0,"dup":120,"fps":30}},"render_ms":6.5,"rss_mb":303,"tick":180,"ts":1003}
        {"audio":{"dropouts":0,"underruns":1},"cpu_pct":20,"encoder":[{"bitrate":6000000,"skipped":1}],"gpu_pct":28,"jitter_ms":1.5,"missed_render":1,"per_input":{"1":{"drop":1,"dup":0,"fps":60},"2":{"drop":0,"dup":160,"fps":30}},"render_ms":2.5,"rss_mb":304,"tick":240,"ts":1004}
        """
        let s = try StatsSummary(lines: Stats.parse(lines: text))
        XCTAssertEqual(s.lineCount, 5)
        XCTAssertEqual(s.durationSeconds, 4); XCTAssertEqual(s.tickSpan, 240); XCTAssertEqual(s.programFps, 60)
        // render_ms：3, 5, 4, 6.5, 2.5 → avg 4.2，p99 = 第 ceil(4.95)=5 个 = 6.5，max 6.5，min 2.5
        XCTAssertEqual(s.renderMs.avg, 4.2, accuracy: 1e-12); XCTAssertEqual(s.renderMs.p99, 6.5); XCTAssertEqual(s.renderMs.max, 6.5); XCTAssertEqual(s.renderMs.min, 2.5)
        // jitter：1, 0.5, 3.5, 2, 1.5 → avg 1.7，p99 3.5
        XCTAssertEqual(s.jitterMs.avg, 1.7, accuracy: 1e-12); XCTAssertEqual(s.jitterMs.p99, 3.5)
        XCTAssertEqual(s.cpuPct.avg, 40); XCTAssertEqual(s.gpuPct.avg, 24); XCTAssertEqual(s.rssMb.max, 304)
        // 累计量取末行 − 首行
        XCTAssertEqual(s.missedRender, 1); XCTAssertEqual(s.missedRenderRatio, 1.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(s.audioDropouts, 0); XCTAssertEqual(s.audioUnderruns, 1)
        XCTAssertEqual(s.encoders[0].skipped, 1); XCTAssertEqual(s.encoders[0].bitrate.avg, 6_000_000)
        XCTAssertEqual(s.perInput[1]!.drop, 1); XCTAssertEqual(s.perInput[2]!.dup, 160)
        XCTAssertEqual(s.perInput[2]!.dupRatio, 160.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(s.perInput[2]!.fps.avg, 30)
        // 30 fps 进 60 fps：设计内 50%，实测 66.7%，设计外 16.7%
        XCTAssertEqual(s.perInput[2]!.designDupRatio, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.perInput[2]!.excessDupRatio, 160.0 / 240 - 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.perInput[1]!.excessDupRatio, 0, accuracy: 1e-12)
        // 输入 1：4 s × 60 fps ≈ 240 帧 push，丢 1 → 0.42%，设计内 0 → 设计外 0.42%
        XCTAssertEqual(s.perInput[1]!.dropRatio, 1.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(s.perInput[1]!.excessDropRatio, 1.0 / 240, accuracy: 1e-12)
        // RSS 斜率：每秒 +1 MB → 3600 MB/h（不足 1 小时，整段拟合并注明）
        XCTAssertEqual(try XCTUnwrap(s.rssSlopeMbPerHour), 3600, accuracy: 1e-6)
        XCTAssertFalse(s.rssFitAfterWarmup)
    }

    func testW1A_statsSummary_verdictsFollowSection4Thresholds() throws {
        var lines: [Stats] = []
        for i in 0..<100 {
            lines.append(sample(ts: Double(i), tick: Int64(i) * 60, render: i == 99 ? 13 : 3, jitter: i == 99 ? 5 : 1,
                                missed: i >= 50 ? 2 : 0, rss: 300 + Double(i) * 0.001, cpu: 50, gpu: 40, dup: 0, drop: 0, skipped: 0, dropouts: 0))
        }
        let s = StatsSummary(lines: lines)
        let v = Dictionary(uniqueKeysWithValues: s.verdicts().map { ($0.id, $0) })
        // V1：avg 3.1 ≤ 6 但 p99（第 99 个 = 3？）：排序后第 ceil(99)=99 个是 3，第 100 个是 13 → p99 = 3 → 通过
        XCTAssertEqual(s.renderMs.p99, 3); XCTAssertEqual(v["V1"]!.pass, true)
        XCTAssertEqual(v["V1"]!.meetsTarget, true)
        // V2：2 / 5940 拍 = 0.034% > 0.02% → 失败
        XCTAssertEqual(v["V2"]!.pass, false)
        // V3：jitter p99 = 1 ≤ 4 通过；目标 ≤ 2 也过
        XCTAssertEqual(v["V3"]!.pass, true); XCTAssertEqual(v["V3"]!.meetsTarget, true)
        // V4：输入 2 是 30 fps 但 dup 全 0 → 设计外 0，通过
        XCTAssertEqual(v["V4"]!.pass, true)
        XCTAssertEqual(v["A1"]!.pass, true); XCTAssertEqual(v["E1"]!.pass, true)
        // S2：0.001 MB/s = 3.6 MB/h ≤ 10 通过，目标 ≤ 2 不达
        XCTAssertEqual(v["S2"]!.pass, true); XCTAssertEqual(v["S2"]!.meetsTarget, false)
        // S3：CPU 50 ≤ 60 通过，GPU 40 ≤ 50 通过；目标 40 / 35 不达
        XCTAssertEqual(v["S3"]!.pass, true); XCTAssertEqual(v["S3"]!.meetsTarget, false)
        XCTAssertEqual(StatsSummary.Thresholds.standard.v1MustAvgMs, 6)
        XCTAssertEqual(StatsSummary.Thresholds.standard.v2MustRatio, 0.0002)
        // 表格
        let md = s.markdown()
        XCTAssertTrue(md.contains("| V1 渲染耗时 |")); XCTAssertTrue(md.contains("| V2 渲染滞后丢帧 |"))
        XCTAssertTrue(md.contains("❌") && md.contains("✅"))
        let prev = StatsSummary(lines: lines.map { var l = $0; l.renderMs += 1; return l })
        let md2 = s.markdown(previous: prev)
        XCTAssertTrue(md2.contains("−1.000"), "与上一版本的差：avg 低了 1 ms\n\(md2)")
    }

    /// P2：新字段的汇总（frames / dropped / reconnects / state、L1、不连续、Master 表）、老基线（没有这些键）的解码、表里 −inf 的清洗。
    func testP2_statsSummary_newFieldsAndOldBaselineDecode() throws {
        func line(_ i: Int, frames: UInt64, dropped: UInt64, state: String, lat: Double, latMax: Double, disc: UInt64, peak: Double, lufs: Double) -> Stats {
            var s = sample(ts: 1000 + Double(i), tick: Int64(i) * 60)
            s.perInput[1]!.latencyMs = lat; s.perInput[1]!.latencyMaxMs = latMax
            s.encoder[0].frames = frames; s.encoder[0].dropped = dropped; s.encoder[0].state = state; s.encoder[0].diskFreeMb = 1000 - Double(i)
            s.audio.discontinuities = disc
            s.audio.meters.buses = [.init(bus: "master", peakDb: [peak, peak - 1], truePeakDb: [peak + 0.5, peak], lufsM: lufs, lufsS: lufs - 1, lufsI: lufs - 2, lra: 3)]
            return s
        }
        let s = StatsSummary(lines: [line(0, frames: 0, dropped: 0, state: "recording", lat: 30, latMax: 40, disc: 0, peak: -10, lufs: -20),
                                     line(1, frames: 60, dropped: 1, state: "recording", lat: 34, latMax: 50, disc: 1, peak: -6, lufs: -18),
                                     line(2, frames: 120, dropped: 1, state: "stopped", lat: 32, latMax: 45, disc: 1, peak: -8, lufs: -19)])
        let d = try XCTUnwrap(s.encoders[0].delivery), l = try XCTUnwrap(s.perInput[1]?.latency), m = try XCTUnwrap(s.masterMeters)
        XCTAssertEqual([d.frames, d.dropped, d.reconnects], [120, 1, 0]); XCTAssertEqual(d.lastState, "stopped"); XCTAssertEqual(d.states, ["recording": 2, "stopped": 1])
        XCTAssertEqual([d.diskFreeMb.min, d.diskFreeMb.max, l.ms.avg, l.ms.max, l.maxMs], [998, 1000, 32, 34, 50])
        XCTAssertEqual(s.audioDiscontinuities, 1)
        XCTAssertEqual([m.peakDb.min, m.peakDb.max, m.truePeakDb.max, m.lufsM.min, m.lufsM.max, m.lufsS.max, m.lufsI, m.lra], [-10, -6, -5.5, -20, -18, -19, -21, 3])
        XCTAssertTrue(s.verdicts().first { $0.id == "A1" }!.value.contains("不连续 1"))
        XCTAssertEqual(try JSONDecoder().decode(StatsSummary.self, from: try JSONEncoder().encode(s)), s)
        // 老基线（P2 之前的 StatsSummary JSON）没有 delivery / latency / audioDiscontinuities / masterMeters：照样解码，缺的为 nil
        var old = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as! [String: Any]
        old["audioDiscontinuities"] = nil; old["masterMeters"] = nil
        old["encoders"] = (old["encoders"] as! [[String: Any]]).map { var e = $0; e["delivery"] = nil; return e }
        old["perInput"] = (old["perInput"] as! [String: Any]).mapValues { var p = $0 as! [String: Any]; p["latency"] = nil; return p }
        let back = try JSONDecoder().decode(StatsSummary.self, from: try JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(back.encoders[0].delivery == nil && back.perInput[1]?.latency == nil && back.audioDiscontinuities == nil && back.masterMeters == nil)
        XCTAssertEqual(back.encoders[0].skipped, s.encoders[0].skipped)
        // sanitizer：表里的 −inf 换成 −120、其余非有限换 0，整行仍能写出
        var bad = line(3, frames: 0, dropped: 0, state: "idle", lat: .nan, latMax: 0, disc: 0, peak: -.infinity, lufs: -.infinity)
        bad.encoder[0].diskFreeMb = .infinity
        let fixed = StatsWriter.sanitized(bad)
        XCTAssertEqual([fixed.audio.meters.buses[0].peakDb[0], fixed.audio.meters.buses[0].lufsM, fixed.perInput[1]!.latencyMs, fixed.encoder[0].diskFreeMb], [-120, -120, 0, 0])
        XCTAssertNoThrow(try fixed.jsonLine())
    }

    func testW1A_statsSummary_loadFromFileAndEmpty() throws {
        let url = tempURL("s.jsonl")
        try "\n".write(to: url, atomically: true, encoding: .utf8)
        let empty = try StatsSummary.load(url: url)
        XCTAssertEqual(empty.lineCount, 0); XCTAssertEqual(empty.renderMs.count, 0)
        XCTAssertTrue(empty.verdicts().allSatisfy { $0.pass == nil })
        let writer = try StatsWriter(url: url)
        for i in 0..<3 { writer.submit(sample(ts: Double(i), tick: Int64(i) * 60)) }
        writer.close()
        XCTAssertEqual(try StatsSummary.load(url: url).lineCount, 3)
    }
}
