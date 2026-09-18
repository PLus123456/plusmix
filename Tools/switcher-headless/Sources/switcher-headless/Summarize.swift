import Foundation
import SwitcherContracts
import SwitcherTestKit

/// baselines/<检查点>-<机器>.json 的结构：元数据 + W1-A 的 StatsSummary 原样（字段名与 stats.jsonl 一致）。
struct Baseline: Codable {
    var checkpoint: String
    var machine: String
    var commit: String
    var date: String
    var scenario: String
    var durationSeconds: Double
    /// 其他说明（macOS、电源、frameprobe 的关键数……），--meta k=v 传进来的全在这里。
    var notes: [String: String]
    var summary: StatsSummary
}

/// summarize 子命令：stats.jsonl → §7 表格（可对比上一版本基线）+ 关键数字 JSON；可写新基线。
enum Summarize {
    static func run(_ p: ParsedArguments) throws {
        guard let statsURL = p.url("stats") else { throw CLIError("summarize 需要 --stats <stats.jsonl>") }
        let summary = try StatsSummary.load(url: statsURL)
        guard summary.lineCount > 0 else { throw CLIError("\(statsURL.path) 没有一行统计") }
        var previous: StatsSummary?
        if let b = p.url("baseline") {
            previous = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: b)).summary
        }
        var markdown = summary.markdown(previous: previous)
        let v1Local = try p.double("v1-avg-ms")
        if let v1Local {
            let pass = summary.renderMs.avg <= v1Local
            markdown += "\n本机参考线：V1 avg ≤ \(v1Local) ms（G2 prompt 加的，M5 Max）：实测 \(String(format: "%.3f", summary.renderMs.avg)) ms → \(pass ? "✅" : "❌")\n"
        }
        if p.has("json") {
            let key: [String: Double] = [
                "lines": Double(summary.lineCount), "duration_s": summary.durationSeconds, "ticks": Double(summary.tickSpan),
                "v1_avg_ms": summary.renderMs.avg, "v1_p99_ms": summary.renderMs.p99, "v1_max_ms": summary.renderMs.max,
                "v2_missed": Double(summary.missedRender), "v2_ratio": summary.missedRenderRatio,
                "v3_p99_ms": summary.jitterMs.p99, "v3_max_ms": summary.jitterMs.max,
                "cpu_avg_pct": summary.cpuPct.avg, "cpu_p99_pct": summary.cpuPct.p99,
                "gpu_avg_pct": summary.gpuPct.avg, "gpu_p99_pct": summary.gpuPct.p99,
                "rss_min_mb": summary.rssMb.min, "rss_max_mb": summary.rssMb.max, "rss_slope_mb_per_h": summary.rssSlopeMbPerHour ?? 0,
                "audio_dropouts": Double(summary.audioDropouts), "audio_underruns": Double(summary.audioUnderruns),
                "e1_skipped": Double(summary.encoders.reduce(0) { $0 + $1.skipped }),
                "v4_worst_excess": summary.perInput.values.map { max($0.excessDupRatio, $0.excessDropRatio) }.max() ?? 0,
                // P2（提案 001 / 002 / 004 / 005）：落地帧数 / 丢帧 / 重连、不连续、Master 表、L1（W1-B2 之前引擎写 0）
                "encoder_frames": Double(summary.encoders.reduce(0) { $0 + ($1.delivery?.frames ?? 0) }),
                "encoder_dropped": Double(summary.encoders.reduce(0) { $0 + ($1.delivery?.dropped ?? 0) }),
                "encoder_reconnects": Double(summary.encoders.reduce(0) { $0 + ($1.delivery?.reconnects ?? 0) }),
                "audio_discontinuities": Double(summary.audioDiscontinuities ?? 0),
                "master_peak_db_max": summary.masterMeters?.peakDb.max ?? Stats.AudioCounters.Meters.floorDb,
                "master_true_peak_db_max": summary.masterMeters?.truePeakDb.max ?? Stats.AudioCounters.Meters.floorDb,
                "master_lufs_s_min": summary.masterMeters?.lufsS.min ?? Stats.AudioCounters.Meters.floorDb,
                "master_lufs_s_max": summary.masterMeters?.lufsS.max ?? Stats.AudioCounters.Meters.floorDb,
                "master_lufs_i": summary.masterMeters?.lufsI ?? Stats.AudioCounters.Meters.floorDb,
                "l1_avg_ms_max": summary.perInput.values.compactMap { $0.latency?.ms.avg }.max() ?? 0,
                "l1_max_ms": summary.perInput.values.compactMap { $0.latency?.maxMs }.max() ?? 0,
            ]
            struct Out: Encodable {
                var key: [String: Double]
                var verdicts: [StatsSummary.Verdict]
                var perInput: [Int: StatsSummary.InputSummary]
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try enc.encode(Out(key: key, verdicts: summary.verdicts(), perInput: summary.perInput)), as: UTF8.self))
        } else {
            print(markdown)
        }
        if let out = p.url("write-baseline") {
            var notes: [String: String] = [:]
            for kv in p.repeated["meta"] ?? [] {
                guard let eq = kv.firstIndex(of: "=") else { throw CLIError("--meta 形如 key=value，收到 \(kv)") }
                notes[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
            let baseline = Baseline(checkpoint: notes.removeValue(forKey: "checkpoint") ?? "G2",
                                    machine: notes.removeValue(forKey: "machine") ?? "unknown",
                                    commit: notes.removeValue(forKey: "commit") ?? "unknown",
                                    date: notes.removeValue(forKey: "date") ?? ISO8601DateFormatter().string(from: Date()),
                                    scenario: notes.removeValue(forKey: "scenario") ?? "",
                                    durationSeconds: summary.durationSeconds, notes: notes, summary: summary)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(baseline).write(to: out, options: .atomic)
            FileHandle.standardError.write(Data("基线写入 \(out.path)\n".utf8))
        }
    }
}
