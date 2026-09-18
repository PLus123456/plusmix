import Foundation
import SwitcherContracts

/// 读 stats.jsonl，算 avg / p99 / max，按测试标准 §4 阈值表判定，输出 §7 报告表格的 markdown。
///
/// 口径：
/// - 每秒量（render_ms、jitter_ms、cpu_pct、gpu_pct、rss_mb、每路 fps、每路码率）按行做序列：min / avg / p99 / max。
/// - **p99 用最近秩法**：升序排序后取第 ceil(0.99 × N) 个（从 1 数），不插值。N = 5 时是第 5 个（最大值），N = 100 时是第 99 个。
/// - 累计量（missed_render、dup、drop、skipped、dropouts、underruns）取末行 − 首行（文件覆盖的这一段）。
/// - 拍数 = 末行 tick − 首行 tick；节目帧率 = 拍数 / 时长；V2 比例 = missed / 拍数；每路 dup 比例 = dup / 拍数（每拍每路取一帧），
///   drop 比例 = drop / Σ(fps × 窗口秒数)（≈ 该路 push 的帧数）。
/// - 设计内重复 = max(0, 1 − 输入 fps / 节目 fps)，设计内丢弃 = max(0, 1 − 节目 fps / 输入 fps)；设计外 = 实测 − 设计内（V4）。
/// - S2：RSS 对时间线性拟合；文件 ≥ 1 h 时丢掉前 30 min 预热再拟合（§3 S2），否则整段拟合并标注。
/// - jitter_ms 在 Stats 里已是"窗口内最大值"，这里的 p99 是各窗口最大值的 p99，比逐帧 p99 严。
/// - P2 起（提案 001 / 002 / 004 / 005）多出的汇总都是可选字段：encoder 的 `delivery`（frames / dropped / reconnects 取末行 − 首行、disk_free_mb 序列、状态）、
///   每路的 `latency`（L1 序列 + 全程最大）、`audioDiscontinuities`、`masterMeters`（Master 峰值 / 真峰值 / LUFS 的序列）。
///   老基线（baselines/*.json）没有这些键，解码为 nil；与上一版本比较时只比 verdicts 的 primary，不受影响。
public struct StatsSummary: Hashable, Codable, Sendable {
    /// 一列数的统计。
    public struct Series: Hashable, Codable, Sendable {
        public var count: Int
        public var min: Double
        public var avg: Double
        public var p99: Double
        public var max: Double
        public init(values: [Double]) {
            count = values.count
            if values.isEmpty {
                min = 0; avg = 0; p99 = 0; max = 0
            } else {
                min = values.min()!
                max = values.max()!
                avg = values.reduce(0, +) / Double(values.count)
                p99 = StatsSummary.percentile(values, 0.99)
            }
        }
    }

    /// 每路输入。
    public struct InputSummary: Hashable, Codable, Sendable {
        public var inputID: Int
        public var fps: Series
        /// 末行 − 首行。
        public var dup: UInt64
        public var drop: UInt64
        /// dup / 拍数。
        public var dupRatio: Double
        /// drop / 估算的 push 帧数。
        public var dropRatio: Double
        public var designDupRatio: Double
        public var designDropRatio: Double
        public var excessDupRatio: Double
        public var excessDropRatio: Double
        /// 提案 005 的 L1（P2 起才有；老基线为 nil）。
        public var latency: LatencySummary?
    }

    /// 一路输入的 L1：latency_ms 逐行序列（各窗口平均值的 min / avg / p99 / max）+ latency_max_ms 的全程最大。W1-B2 之前引擎写 0。
    public struct LatencySummary: Hashable, Codable, Sendable {
        public var ms: Series
        public var maxMs: Double
    }

    /// 每个编码器。
    public struct EncoderSummary: Hashable, Codable, Sendable {
        public var index: Int
        public var skipped: UInt64
        public var bitrate: Series
        /// 提案 001 / 002 的落地 / 传输统计（P2 起才有；老基线为 nil）。
        public var delivery: DeliverySummary?
    }

    /// 一个输出的落地 / 传输统计：frames / dropped / reconnects 取末行 − 首行；disk_free_mb 逐行序列；state 取末行与全程出现的状态（行数）。
    public struct DeliverySummary: Hashable, Codable, Sendable {
        public var frames: UInt64
        public var dropped: UInt64
        public var reconnects: UInt64
        public var diskFreeMb: Series
        public var lastState: String
        public var states: [String: Int]
    }

    /// Master 表读数的逐行序列（提案 004）：峰值 / 真峰值取 L / R 的较大者；LUFS 瞬时 / 短期逐行；积分响度与 LRA 取末行。
    public struct MasterMeterSummary: Hashable, Codable, Sendable {
        public var peakDb: Series
        public var truePeakDb: Series
        public var lufsM: Series
        public var lufsS: Series
        public var lufsI: Double
        public var lra: Double
    }

    public var lineCount: Int
    public var firstTs: Double
    public var lastTs: Double
    public var durationSeconds: Double
    public var firstTick: Int64
    public var lastTick: Int64
    public var tickSpan: Int64
    public var programFps: Double
    public var renderMs: Series
    public var jitterMs: Series
    public var cpuPct: Series
    public var gpuPct: Series
    public var rssMb: Series
    public var missedRender: UInt64
    public var missedRenderRatio: Double
    public var perInput: [Int: InputSummary]
    public var encoders: [EncoderSummary]
    public var audioDropouts: UInt64
    public var audioUnderruns: UInt64
    /// A1 第三项（流式检测，末行 − 首行；提案 004，P2 起才有，老基线为 nil）。
    public var audioDiscontinuities: UInt64?
    /// Master 表读数序列（有 meters 的文件才有）。
    public var masterMeters: MasterMeterSummary?
    /// RSS 线性拟合斜率（MB / h）；不足两行为 nil。
    public var rssSlopeMbPerHour: Double?
    /// 是否按 §3 S2 丢掉了前 30 min 再拟合。
    public var rssFitAfterWarmup: Bool

    /// 读文件。
    public static func load(url: URL) throws -> StatsSummary {
        StatsSummary(lines: try Stats.parse(lines: String(contentsOf: url, encoding: .utf8)))
    }

    public init(lines: [Stats]) {
        lineCount = lines.count
        guard let first = lines.first, let last = lines.last else {
            firstTs = 0; lastTs = 0; durationSeconds = 0; firstTick = 0; lastTick = 0; tickSpan = 0; programFps = 0
            renderMs = Series(values: []); jitterMs = Series(values: []); cpuPct = Series(values: []); gpuPct = Series(values: []); rssMb = Series(values: [])
            missedRender = 0; missedRenderRatio = 0; perInput = [:]; encoders = []; audioDropouts = 0; audioUnderruns = 0
            audioDiscontinuities = nil; masterMeters = nil
            rssSlopeMbPerHour = nil; rssFitAfterWarmup = false
            return
        }
        firstTs = first.ts
        lastTs = last.ts
        durationSeconds = last.ts - first.ts
        firstTick = first.tick.rawValue
        lastTick = last.tick.rawValue
        tickSpan = lastTick - firstTick
        programFps = durationSeconds > 0 ? Double(tickSpan) / durationSeconds : 0
        renderMs = Series(values: lines.map(\.renderMs))
        jitterMs = Series(values: lines.map(\.jitterMs))
        cpuPct = Series(values: lines.map(\.cpuPct))
        gpuPct = Series(values: lines.map(\.gpuPct))
        rssMb = Series(values: lines.map(\.rssMb))
        missedRender = last.missedRender &- first.missedRender
        missedRenderRatio = tickSpan > 0 ? Double(missedRender) / Double(tickSpan) : 0
        audioDropouts = last.audio.dropouts &- first.audio.dropouts
        audioUnderruns = last.audio.underruns &- first.audio.underruns
        audioDiscontinuities = last.audio.discontinuities &- first.audio.discontinuities
        let masters = lines.compactMap { $0.audio.meters.buses.first { $0.bus == Bus.master.name } }
        if let lastMaster = masters.last {
            masterMeters = MasterMeterSummary(peakDb: Series(values: masters.map { $0.peakDb.max() ?? Stats.AudioCounters.Meters.floorDb }),
                                              truePeakDb: Series(values: masters.map { $0.truePeakDb.max() ?? Stats.AudioCounters.Meters.floorDb }),
                                              lufsM: Series(values: masters.map(\.lufsM)), lufsS: Series(values: masters.map(\.lufsS)),
                                              lufsI: lastMaster.lufsI, lra: lastMaster.lra)
        } else {
            masterMeters = nil
        }

        var inputs: [Int: InputSummary] = [:]
        let ids = Set(lines.flatMap { $0.perInput.keys })
        for id in ids {
            var fpsValues: [Double] = []
            var latencyValues: [Double] = []
            var latencyMax = 0.0
            var pushed = 0.0
            var prevTs: Double?
            for l in lines {
                guard let p = l.perInput[id] else { continue }
                fpsValues.append(p.fps)
                latencyValues.append(p.latencyMs)
                latencyMax = max(latencyMax, p.latencyMaxMs)
                if let pt = prevTs { pushed += p.fps * (l.ts - pt) } else if lines.count == 1 { pushed = p.fps }
                prevTs = l.ts
            }
            let firstP = lines.first { $0.perInput[id] != nil }!.perInput[id]!
            let lastP = lines.last { $0.perInput[id] != nil }!.perInput[id]!
            let dup = lastP.dup &- firstP.dup, drop = lastP.drop &- firstP.drop
            let fps = Series(values: fpsValues)
            let dupRatio = tickSpan > 0 ? Double(dup) / Double(tickSpan) : 0
            let dropRatio = pushed > 0 ? Double(drop) / pushed : 0
            let designDup = (programFps > 0 && fps.avg > 0) ? max(0, 1 - fps.avg / programFps) : 0
            let designDrop = (programFps > 0 && fps.avg > 0) ? max(0, 1 - programFps / fps.avg) : 0
            inputs[id] = InputSummary(inputID: id, fps: fps, dup: dup, drop: drop, dupRatio: dupRatio, dropRatio: dropRatio,
                                      designDupRatio: designDup, designDropRatio: designDrop,
                                      excessDupRatio: max(0, dupRatio - designDup), excessDropRatio: max(0, dropRatio - designDrop),
                                      latency: LatencySummary(ms: Series(values: latencyValues), maxMs: latencyMax))
        }
        perInput = inputs

        let encoderCount = lines.map(\.encoder.count).max() ?? 0
        encoders = (0..<encoderCount).map { i in
            let entries = lines.compactMap { i < $0.encoder.count ? $0.encoder[i] : nil }
            var states: [String: Int] = [:]
            for e in entries { states[e.state, default: 0] += 1 }
            let delivery = DeliverySummary(frames: (entries.last?.frames ?? 0) &- (entries.first?.frames ?? 0),
                                           dropped: (entries.last?.dropped ?? 0) &- (entries.first?.dropped ?? 0),
                                           reconnects: (entries.last?.reconnects ?? 0) &- (entries.first?.reconnects ?? 0),
                                           diskFreeMb: Series(values: entries.map(\.diskFreeMb)),
                                           lastState: entries.last?.state ?? "idle", states: states)
            return EncoderSummary(index: i, skipped: (entries.last?.skipped ?? 0) &- (entries.first?.skipped ?? 0),
                                  bitrate: Series(values: entries.map(\.bitrate)), delivery: delivery)
        }

        let warmup = durationSeconds >= 3600
        let fitLines = warmup ? lines.filter { $0.ts >= first.ts + 1800 } : lines
        rssFitAfterWarmup = warmup
        if fitLines.count >= 2 {
            let (slope, _) = FrameAnalysis.linearFit(x: fitLines.map(\.ts), y: fitLines.map(\.rssMb))
            rssSlopeMbPerHour = slope * 3600
        } else {
            rssSlopeMbPerHour = nil
        }
    }

    /// 最近秩法百分位：升序第 ceil(p × N) 个（1 起）。空数组返回 0。
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count, rank) - 1)]
    }

    // MARK: - §4 判定

    /// 测试标准 §4 的阈值（能从 stats.jsonl 判的那些）。数值抄自 §4，改它是用户的事（铁律 9）。
    public struct Thresholds: Hashable, Sendable {
        public var v1MustAvgMs = 6.0, v1MustP99Ms = 12.0, v1TargetAvgMs = 4.0, v1TargetP99Ms = 8.0
        public var v2MustRatio = 0.0002, v2TargetRatio = 0.0
        public var v3MustP99Ms = 4.0, v3TargetP99Ms = 2.0
        public var v4MustExcess = 0.0005, v4TargetExcess = 0.0
        public var s2MustMbPerHour = 10.0, s2TargetMbPerHour = 2.0
        public var s3MustCpu = 60.0, s3MustGpu = 50.0, s3TargetCpu = 40.0, s3TargetGpu = 35.0
        public init() {}
        public static let standard = Thresholds()
    }

    /// 一个指标的判定。
    public struct Verdict: Hashable, Codable, Sendable {
        public var id: String
        public var name: String
        /// 数值（人读）。
        public var value: String
        /// 用来和上一版本比的主数值。
        public var primary: Double?
        public var unit: String
        public var must: String
        public var target: String
        /// nil = 没数据判不了。
        public var pass: Bool?
        public var meetsTarget: Bool?
        public var note: String
    }

    public func verdicts(thresholds t: Thresholds = .standard) -> [Verdict] {
        let has = lineCount > 0
        func f(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }
        func pct(_ v: Double) -> String { String(format: "%.4f%%", v * 100) }
        var out: [Verdict] = []
        out.append(Verdict(id: "V1", name: "渲染耗时", value: "avg \(f(renderMs.avg)) ms / p99 \(f(renderMs.p99)) ms", primary: has ? renderMs.avg : nil, unit: "ms",
                           must: "avg ≤ \(f(t.v1MustAvgMs, 0)), p99 ≤ \(f(t.v1MustP99Ms, 0))", target: "avg ≤ \(f(t.v1TargetAvgMs, 0)), p99 ≤ \(f(t.v1TargetP99Ms, 0))",
                           pass: has ? (renderMs.avg <= t.v1MustAvgMs && renderMs.p99 <= t.v1MustP99Ms) : nil,
                           meetsTarget: has ? (renderMs.avg <= t.v1TargetAvgMs && renderMs.p99 <= t.v1TargetP99Ms) : nil, note: "p99 = 各秒平均值的 p99（逐帧 p99 由 W1-C 测）"))
        out.append(Verdict(id: "V2", name: "渲染滞后丢帧", value: "\(missedRender) 帧 / \(tickSpan) 拍（\(pct(missedRenderRatio))）", primary: has ? missedRenderRatio : nil, unit: "比例",
                           must: "≤ \(pct(t.v2MustRatio))", target: "0", pass: has ? missedRenderRatio <= t.v2MustRatio : nil,
                           meetsTarget: has ? missedRenderRatio <= t.v2TargetRatio : nil, note: ""))
        out.append(Verdict(id: "V3", name: "抖动", value: "p99 \(f(jitterMs.p99)) ms / max \(f(jitterMs.max)) ms", primary: has ? jitterMs.p99 : nil, unit: "ms",
                           must: "p99 ≤ \(f(t.v3MustP99Ms, 0))", target: "p99 ≤ \(f(t.v3TargetP99Ms, 0))", pass: has ? jitterMs.p99 <= t.v3MustP99Ms : nil,
                           meetsTarget: has ? jitterMs.p99 <= t.v3TargetP99Ms : nil, note: "jitter_ms 是窗口最大值，这里的 p99 比逐帧 p99 严"))
        let worst = perInput.values.map { max($0.excessDupRatio, $0.excessDropRatio) }.max()
        let inputNote = perInput.keys.sorted().map { id -> String in
            let p = perInput[id]!
            return "输入 \(id)：\(f(p.fps.avg, 2)) fps，重复 \(pct(p.dupRatio))（设计内 \(pct(p.designDupRatio))），丢弃 \(pct(p.dropRatio))（设计内 \(pct(p.designDropRatio))）"
        }.joined(separator: "；")
        out.append(Verdict(id: "V4", name: "设计外重复 / 丢弃", value: worst.map { "最大设计外 \(pct($0))" } ?? "无输入", primary: worst, unit: "比例",
                           must: "≤ \(pct(t.v4MustExcess))", target: "0", pass: worst.map { $0 <= t.v4MustExcess },
                           meetsTarget: worst.map { $0 <= t.v4TargetExcess }, note: inputNote))
        let a1 = audioDropouts + audioUnderruns
        let discNote = audioDiscontinuities.map { "；不连续 \($0)（流式检测，信息项）" } ?? ""
        out.append(Verdict(id: "A1", name: "音频断裂", value: "超时 \(audioDropouts) + 欠载 \(audioUnderruns)\(discNote)", primary: has ? Double(a1) : nil, unit: "次",
                           must: "0（硬性）", target: "0", pass: has ? a1 == 0 : nil, meetsTarget: has ? a1 == 0 : nil,
                           note: "判定只算超时 + 欠载；不连续以离线口径（frameprobe，按已知 click 位置排除）为准"))
        let e1 = encoders.reduce(0) { $0 + $1.skipped }
        let e1Note = encoders.compactMap { e in e.delivery.map { "#\(e.index) 帧 \($0.frames) 丢 \($0.dropped) 状态 \($0.lastState)" } }.joined(separator: "；")
        out.append(Verdict(id: "E1", name: "编码滞后跳帧", value: encoders.isEmpty ? "无编码器" : encoders.map { "#\($0.index) \($0.skipped)" }.joined(separator: ", "),
                           primary: encoders.isEmpty ? nil : Double(e1), unit: "帧", must: "标准负载下 0", target: "0",
                           pass: encoders.isEmpty ? nil : e1 == 0, meetsTarget: encoders.isEmpty ? nil : e1 == 0, note: e1Note))
        out.append(Verdict(id: "S2", name: "内存增长", value: rssSlopeMbPerHour.map { "\(f($0, 2)) MB/h（RSS \(f(rssMb.min, 0)) → \(f(rssMb.max, 0)) MB）" } ?? "不足两行",
                           primary: rssSlopeMbPerHour, unit: "MB/h", must: "≤ \(f(t.s2MustMbPerHour, 0)) MB/h", target: "≤ \(f(t.s2TargetMbPerHour, 0)) MB/h",
                           pass: rssSlopeMbPerHour.map { $0 <= t.s2MustMbPerHour }, meetsTarget: rssSlopeMbPerHour.map { $0 <= t.s2TargetMbPerHour },
                           note: rssFitAfterWarmup ? "已丢掉前 30 min 预热" : "文件不足 1 h，整段拟合，仅供参考"))
        out.append(Verdict(id: "S3", name: "占用", value: "CPU avg \(f(cpuPct.avg, 1))% / GPU avg \(f(gpuPct.avg, 1))%", primary: has ? cpuPct.avg : nil, unit: "%",
                           must: "CPU ≤ \(f(t.s3MustCpu, 0))%, GPU ≤ \(f(t.s3MustGpu, 0))%", target: "CPU ≤ \(f(t.s3TargetCpu, 0))%, GPU ≤ \(f(t.s3TargetGpu, 0))%",
                           pass: has ? (cpuPct.avg <= t.s3MustCpu && gpuPct.avg <= t.s3MustGpu) : nil,
                           meetsTarget: has ? (cpuPct.avg <= t.s3TargetCpu && gpuPct.avg <= t.s3TargetGpu) : nil, note: "CPU 100 = 一个核"))
        return out
    }

    // MARK: - §7 表格

    /// 测试标准 §7 报告里"每个指标：数值 · 阈值（必须 / 目标）· 通过或失败 · 与上一版本的差"那一段的 markdown。
    public func markdown(previous: StatsSummary? = nil, thresholds: Thresholds = .standard) -> String {
        var s = ""
        s += "| 项 | 值 |\n|---|---|\n"
        s += "| 行数 | \(lineCount) |\n"
        s += "| 时长 | \(String(format: "%.1f", durationSeconds)) s（\(String(format: "%.2f", durationSeconds / 3600)) h） |\n"
        s += "| 拍 | \(firstTick) → \(lastTick)（\(tickSpan) 拍，\(String(format: "%.3f", programFps)) fps） |\n\n"
        s += "| 指标 | 数值 | 必须 | 目标 | 通过 | 与上一版本的差 |\n|---|---|---|---|---|---|\n"
        let prev = previous.map { Dictionary(uniqueKeysWithValues: $0.verdicts(thresholds: thresholds).map { ($0.id, $0) }) }
        for v in verdicts(thresholds: thresholds) {
            let mark: String
            switch (v.pass, v.meetsTarget) {
            case (nil, _): mark = "—"
            case (true?, true?): mark = "✅ 达目标"
            case (true?, _): mark = "✅"
            case (false?, _): mark = "❌"
            }
            var delta = "—"
            if let p = prev?[v.id]?.primary, let cur = v.primary {
                let d = cur - p
                let sign = d < 0 ? "−" : "+"
                delta = "\(sign)\(String(format: "%.3f", abs(d))) \(v.unit)"
            }
            let note = v.note.isEmpty ? "" : "（\(v.note)）"
            s += "| \(v.id) \(v.name) | \(v.value)\(note) | \(v.must) | \(v.target) | \(mark) | \(delta) |\n"
        }
        return s
    }
}
