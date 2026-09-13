import Foundation
import SwitcherContracts

/// frameprobe 的分析算法（纯函数，输入是解码好的 `ProbeFrame` / `ClickEvent` 序列）。
/// 口径对应测试标准：stats = V4 / V5，switches = V6，fade = V7，av = A2 / A3，avMulti = A4。
public enum FrameAnalysis {
    // MARK: - V4 / V5

    /// 一段重复：从 `index` 起连续 `length` 帧是同一输入帧（length ≥ 2）。
    public struct DuplicateRun: Hashable, Codable, Sendable {
        public var index: Int
        public var length: Int
        public var frameNumber: UInt32
    }
    /// 一处缺口：输出第 `index` 帧的帧号是 `to`，上一帧同输入的帧号是 `from`，中间缺了 `missing` 帧。
    public struct DropGap: Hashable, Codable, Sendable {
        public var index: Int
        public var from: UInt32
        public var to: UInt32
        public var missing: Int
    }

    /// 每路输入的重复 / 丢弃统计。
    public struct InputStats: Hashable, Codable, Sendable {
        public var inputID: Int
        /// 带这个 ID 且帧号可读的输出帧数。
        public var frames: Int
        /// 不同帧号的个数。
        public var uniqueFrames: Int
        /// 与上一帧同帧号的输出帧数。
        public var duplicateFrames: Int
        /// 重复段（可能被 maxEvents 截断）。
        public var duplicateRuns: [DuplicateRun]
        /// 缺口里丢掉的输入帧总数。
        public var droppedFrames: Int
        /// 缺口列表（可能被截断）。
        public var dropGaps: [DropGap]
        /// 帧号倒退（非回绕）的次数——正常永远是 0。
        public var backwardJumps: Int
        /// duplicateFrames / frames。
        public var duplicateRatio: Double
        /// droppedFrames / (uniqueFrames + droppedFrames)。
        public var dropRatio: Double
        /// 传入的该路帧率。
        public var inputFps: Double?
        /// 设计内重复比例 = max(0, 1 − inputFps / programFps)。
        public var designDuplicateRatio: Double?
        /// 设计内丢弃比例 = max(0, 1 − programFps / inputFps)。
        public var designDropRatio: Double?
        /// 设计外重复 = max(0, 实测 − 设计内)。
        public var excessDuplicateRatio: Double?
        /// 设计外丢弃 = max(0, 实测 − 设计内)。
        public var excessDropRatio: Double?
        /// V4：设计外重复与丢弃都 ≤ 0.05%（没给帧率时为 nil）。
        public var passV4: Bool?
    }

    public struct StatsReport: Hashable, Codable, Sendable {
        public var totalFrames: Int
        /// 帧号读不出（CRC 错）的帧数。
        public var undecodableFrames: Int
        /// 输入 ID 读不出（混合 / 黑场）的帧数。
        public var unidentifiedFrames: Int
        /// 文件时长（最后一帧 pts − 第一帧 pts + 一帧）。
        public var durationSeconds: Double
        public var programFps: Double
        /// round(时长 × 帧率)。
        public var expectedFrames: Int
        /// V5：totalFrames − expectedFrames。
        public var frameCountDelta: Int
        public var inputs: [InputStats]
        /// 序列是否被 maxEvents 截断。
        public var truncated: Bool
    }

    /// V4 的阈值（必须档）：设计外 ≤ 0.05%。
    public static let v4MaximumExcessRatio = 0.0005

    /// 每路输入的重复 / 丢弃序列与比例（V4）、总帧数 vs 时长 × 帧率（V5）。
    /// - Parameters:
    ///   - programFps: 节目（输出文件）帧率。
    ///   - inputFps: 每路输入的帧率（键 = 输入 ID），用来区分设计内 / 设计外。
    ///   - maxEvents: 每路最多列出多少段重复 / 缺口（防止 1 小时文件输出几十万条）。
    public static func stats(frames: [ProbeFrame], programFps: Double, inputFps: [Int: Double] = [:], maxEvents: Int = 200) -> StatsReport {
        // 按输入分组，但切走再切回来算新的一段：节目输出里某路不在播的那段不是它"丢帧"。
        // 规则：只有相邻输出帧（中间最多隔着读不出 ID 的帧）且同一输入，帧号才连着比。
        var byInput: [Int: [[ProbeFrame]]] = [:]
        var undecodable = 0, unidentified = 0
        var lastID: Int?
        for f in frames {
            if f.frameNumber == nil { undecodable += 1 }
            guard let id = f.inputID else { unidentified += 1; continue }
            if lastID != id || byInput[id] == nil { byInput[id, default: []].append([]) }
            lastID = id
            guard f.frameNumber != nil else { continue }
            byInput[id]![byInput[id]!.count - 1].append(f)
        }
        var truncated = false
        var inputs: [InputStats] = []
        for id in byInput.keys.sorted() {
            var frames = 0, unique = 0, dupFrames = 0, dropped = 0, backward = 0
            var runs: [DuplicateRun] = [], gaps: [DropGap] = []
            for segment in byInput[id]! {
                var prev: UInt32?
                var runStart = -1, runLength = 0
                for f in segment {
                    frames += 1
                    let n = f.frameNumber!
                    if let p = prev {
                        if n == p {
                            dupFrames += 1
                            if runLength == 0 { runStart = f.index - 1; runLength = 2 } else { runLength += 1 }
                        } else {
                            if runLength > 0 {
                                if runs.count < maxEvents { runs.append(DuplicateRun(index: runStart, length: runLength, frameNumber: p)) } else { truncated = true }
                                runLength = 0
                            }
                            unique += 1
                            var delta = Int64(n) - Int64(p)
                            if delta < 0 {
                                // 28 位回绕：从接近 2^28 跳回接近 0 算正常；否则算倒退
                                let wrapped = delta + Int64(TestPattern.dataMask) + 1
                                if wrapped >= 1 && wrapped < 1_000_000 { delta = wrapped } else { backward += 1; delta = 1 }
                            }
                            if delta > 1 {
                                dropped += Int(delta - 1)
                                if gaps.count < maxEvents { gaps.append(DropGap(index: f.index, from: p, to: n, missing: Int(delta - 1))) } else { truncated = true }
                            }
                        }
                    } else {
                        unique += 1
                    }
                    prev = n
                }
                if runLength > 0, let p = prev {
                    if runs.count < maxEvents { runs.append(DuplicateRun(index: runStart, length: runLength, frameNumber: p)) } else { truncated = true }
                }
            }
            let dupRatio = frames > 0 ? Double(dupFrames) / Double(frames) : 0
            let dropRatio = (unique + dropped) > 0 ? Double(dropped) / Double(unique + dropped) : 0
            var s = InputStats(inputID: id, frames: frames, uniqueFrames: unique, duplicateFrames: dupFrames, duplicateRuns: runs,
                               droppedFrames: dropped, dropGaps: gaps, backwardJumps: backward, duplicateRatio: dupRatio, dropRatio: dropRatio,
                               inputFps: nil, designDuplicateRatio: nil, designDropRatio: nil, excessDuplicateRatio: nil, excessDropRatio: nil, passV4: nil)
            if let fps = inputFps[id], fps > 0, programFps > 0 {
                let designDup = max(0, 1 - fps / programFps)
                let designDrop = max(0, 1 - programFps / fps)
                s.inputFps = fps
                s.designDuplicateRatio = designDup
                s.designDropRatio = designDrop
                s.excessDuplicateRatio = max(0, dupRatio - designDup)
                s.excessDropRatio = max(0, dropRatio - designDrop)
                s.passV4 = s.excessDuplicateRatio! <= v4MaximumExcessRatio && s.excessDropRatio! <= v4MaximumExcessRatio
            }
            inputs.append(s)
        }
        var duration = 0.0
        if let first = frames.first, let last = frames.last {
            duration = last.ptsSeconds - first.ptsSeconds + (programFps > 0 ? 1 / programFps : 0)
        }
        let expected = Int((duration * programFps).rounded())
        return StatsReport(totalFrames: frames.count, undecodableFrames: undecodable, unidentifiedFrames: unidentified,
                           durationSeconds: duration, programFps: programFps, expectedFrames: expected,
                           frameCountDelta: frames.count - expected, inputs: inputs, truncated: truncated)
    }


    // MARK: - V6

    /// 某路输入的标称灰度（该 ID 帧的众数）。
    public struct NominalGray: Hashable, Codable, Sendable {
        public var inputID: Int
        public var gray: Double
    }
    /// 一次切换。
    public struct Switch: Hashable, Codable, Sendable {
        /// 新输入 ID 出现的第一帧。
        public var index: Int
        /// startTick + index。
        public var tick: Int64
        public var ptsSeconds: Double
        public var from: Int?
        public var to: Int
        /// 旧输入最后出现的帧。
        public var lastFromIndex: Int?
        /// 两者之间读不出 ID 的帧数：0 = Cut，> 0 = 转场。
        public var betweenFrames: Int
        /// "cut" 或 "transition"。
        public var kind: String
        /// 切换前一帧灰度是否不等于任一输入标称灰度。
        public var mixedBefore: Bool
        /// 切换帧灰度是否不等于任一输入标称灰度。
        public var mixedAt: Bool
        /// 切换后一帧是否混合。
        public var mixedAfter: Bool
        /// Cut 且前后都无混合帧（V6 硬性）。
        public var cleanCut: Bool
    }
    public struct SwitchesReport: Hashable, Codable, Sendable {
        public var startTick: Int64
        public var grayTolerance: Double
        public var nominalGrays: [NominalGray]
        public var switches: [Switch]
        /// 所有 Cut 都干净。
        public var allCutsClean: Bool
    }

    /// 输入 ID 变化的帧、Cut 前后有无混合帧（判据：帧灰度不等于任一输入的标称灰度）。
    /// - Parameter startTick: 输出第 0 帧对应的节目拍（默认 0）；tick = startTick + index。
    public static func switches(frames: [ProbeFrame], startTick: Int64 = 0, grayTolerance: Double = 6) -> SwitchesReport {
        let nominal = nominalGrays(frames)
        let nominalValues = nominal.map(\.gray)
        func isMixed(_ i: Int) -> Bool {
            guard i >= 0 && i < frames.count else { return false }
            let g = frames[i].gray
            return !nominalValues.contains { abs($0 - g) <= grayTolerance }
        }
        var switches: [Switch] = []
        var lastID: Int?
        var lastIDIndex: Int?
        for f in frames {
            guard let id = f.inputID else { continue }
            if let l = lastID, l != id {
                let between = f.index - (lastIDIndex! + 1)
                let sw = Switch(index: f.index, tick: startTick + Int64(f.index), ptsSeconds: f.ptsSeconds, from: l, to: id,
                                lastFromIndex: lastIDIndex, betweenFrames: between, kind: between == 0 ? "cut" : "transition",
                                mixedBefore: isMixed(f.index - 1), mixedAt: isMixed(f.index), mixedAfter: isMixed(f.index + 1),
                                cleanCut: between == 0 && !isMixed(f.index - 1) && !isMixed(f.index) && !isMixed(f.index + 1))
                switches.append(sw)
            } else if lastID == nil {
                // 第一路出现也记一条（from nil）
                switches.append(Switch(index: f.index, tick: startTick + Int64(f.index), ptsSeconds: f.ptsSeconds, from: nil, to: id,
                                       lastFromIndex: nil, betweenFrames: 0, kind: "start", mixedBefore: false, mixedAt: isMixed(f.index),
                                       mixedAfter: isMixed(f.index + 1), cleanCut: true))
            }
            lastID = id
            lastIDIndex = f.index
        }
        let cuts = switches.filter { $0.kind == "cut" }
        return SwitchesReport(startTick: startTick, grayTolerance: grayTolerance, nominalGrays: nominal, switches: switches,
                              allCutsClean: cuts.allSatisfy(\.cleanCut))
    }

    /// 每个输入 ID 的标称灰度 = 该 ID 帧灰度取整后的众数。
    public static func nominalGrays(_ frames: [ProbeFrame]) -> [NominalGray] {
        var hist: [Int: [Int: Int]] = [:]
        for f in frames {
            guard let id = f.inputID else { continue }
            hist[id, default: [:]][Int(f.gray.rounded()), default: 0] += 1
        }
        return hist.keys.sorted().map { id in
            let best = hist[id]!.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!
            return NominalGray(inputID: id, gray: Double(best.key))
        }
    }

    // MARK: - V7

    /// Fade 里的一帧。
    public struct FadeSample: Hashable, Codable, Sendable {
        public var index: Int
        public var tick: Int64
        public var gray: Double
        /// (gray − grayA) / (grayB − grayA)：画面里 B 的比例。
        public var ratio: Double
        /// 新画面盖在旧画面上的比例（A→B 时 = ratio，B→A 时 = 1 − ratio）。
        public var progress: Double
        /// 线性曲线的期望进度 k / D。
        public var expectedProgress: Double
        /// |progress × D − k|：偏离线性曲线的帧数。
        public var deviationFrames: Double
    }
    /// 一次 Fade。
    public struct Fade: Hashable, Codable, Sendable {
        /// 第一个混合帧。
        public var startIndex: Int
        /// 最后一个混合帧。
        public var endIndex: Int
        public var startTick: Int64
        /// "A→B" 或 "B→A"。
        public var direction: String
        /// 混合帧数。
        public var mixedFrames: Int
        /// 转场时长 D（拍）：给定值，或 mixedFrames + 1。
        public var durationTicks: Int
        public var samples: [FadeSample]
        /// 与线性曲线的最大偏差（帧）。
        public var maxDeviationFrames: Double
        /// 最大进度误差（0–1）。
        public var maxProgressError: Double
        /// 进度是否单调不减。
        public var monotonic: Bool
        /// V7：曲线误差 ≤ 1 帧。
        public var passV7: Bool
    }
    public struct FadeReport: Hashable, Codable, Sendable {
        public var grayA: Double
        public var grayB: Double
        public var fades: [Fade]
        public var allPassV7: Bool
    }

    /// V7 阈值（必须档）：曲线误差 ≤ 1 帧。
    public static let v7MaximumDeviationFrames = 1.0

    /// Fade 期间逐帧混合比例（A = 64、B = 192 时比例 = (gray − 64) / 128）与线性曲线的最大偏差帧数。
    ///
    /// 两种模式：
    /// - 自动（`at` 为 nil）：混合帧 = 灰度离 A、B 都超过 tolerance 的连续帧；D = 给定的 durationTicks 或 混合帧数 + 1。
    ///   只能量曲线形状，量不出"整体晚了几帧"（晚几帧看起来就是晚几帧开始）。
    /// - 指定（`at` = 发 Fade 命令的拍 s）：按契约"第 s + k 拍 progress = k / D"直接评估第 s + 1 … s + D − 1 帧，
    ///   形状和滞后都量得到；此时 durationTicks 必填。
    /// tolerance 默认 2：D = 30 时相邻两帧差 4.3 级，6 会把头尾两帧当成纯色；中心区均值对 H.264 噪声不敏感，2 够用。
    public static func fade(frames: [ProbeFrame], grayA: Double = 64, grayB: Double = 192, durationTicks: Int? = nil,
                            at commandTick: Int64? = nil, tolerance: Double = 2, startTick: Int64 = 0) -> FadeReport {
        precondition(grayA != grayB)
        let span = grayB - grayA
        func ratio(_ g: Double) -> Double { (g - grayA) / span }
        func isMixed(_ f: ProbeFrame) -> Bool {
            let tol = tolerance / abs(span)
            let r = ratio(f.gray)
            return r > tol && r < 1 - tol
        }
        func evaluate(run: ArraySlice<ProbeFrame>, before: Double, after: Double, d: Int) -> Fade {
            let aToB = after >= before
            var samples: [FadeSample] = []
            var maxDev = 0.0, maxErr = 0.0, monotonic = true
            var lastProgress = -1.0
            for (k, f) in run.enumerated() {
                let r = ratio(f.gray)
                let p = aToB ? r : 1 - r
                let expected = Double(k + 1) / Double(d)
                let dev = abs(p * Double(d) - Double(k + 1))
                maxDev = max(maxDev, dev)
                maxErr = max(maxErr, abs(p - expected))
                if p < lastProgress - 1e-9 { monotonic = false }
                lastProgress = p
                samples.append(FadeSample(index: f.index, tick: startTick + Int64(f.index), gray: f.gray, ratio: r, progress: p,
                                          expectedProgress: expected, deviationFrames: dev))
            }
            let first = run.first!.index, last = run.last!.index
            return Fade(startIndex: first, endIndex: last, startTick: startTick + Int64(first), direction: aToB ? "A→B" : "B→A",
                        mixedFrames: run.count, durationTicks: d, samples: samples, maxDeviationFrames: maxDev,
                        maxProgressError: maxErr, monotonic: monotonic, passV7: maxDev <= v7MaximumDeviationFrames)
        }
        var fades: [Fade] = []
        if let s = commandTick {
            guard let d = durationTicks, d >= 2 else { preconditionFailure("指定 at 时必须给 durationTicks ≥ 2") }
            let firstIndex = Int(s - startTick) + 1
            let lastIndex = Int(s - startTick) + d - 1
            if firstIndex >= 0 && lastIndex < frames.count && firstIndex <= lastIndex {
                let before = ratio(frames[firstIndex - 1].gray)
                let after = lastIndex + 1 < frames.count ? ratio(frames[lastIndex + 1].gray) : 1 - before
                fades.append(evaluate(run: frames[firstIndex...lastIndex], before: before, after: after, d: d))
            }
        } else {
            var i = 0
            while i < frames.count {
                guard isMixed(frames[i]) else { i += 1; continue }
                var j = i
                while j + 1 < frames.count && isMixed(frames[j + 1]) { j += 1 }
                let before = i > 0 ? ratio(frames[i - 1].gray) : ratio(frames[i].gray)
                let after = j + 1 < frames.count ? ratio(frames[j + 1].gray) : ratio(frames[j].gray)
                fades.append(evaluate(run: frames[i...j], before: before, after: after, d: durationTicks ?? (j - i + 2)))
                i = j + 1
            }
        }
        return FadeReport(grayA: grayA, grayB: grayB, fades: fades, allPassV7: fades.allSatisfy(\.passV7))
    }

    // MARK: - A2 / A3

    /// 一个闪光帧和它最近的 click。
    public struct AVPair: Hashable, Codable, Sendable {
        /// 闪光起始帧（前一帧不闪）。
        public var flashIndex: Int
        public var flashTimeSeconds: Double
        public var genTimeMs: UInt32?
        public var clickTimeSeconds: Double?
        /// (闪光时刻 − click 时刻) ms：音频超前为正（测试标准 §0 第 6 条）。
        public var offsetMs: Double?
    }
    public struct AVReport: Hashable, Codable, Sendable {
        public var pairs: [AVPair]
        public var flashCount: Int
        public var clickCount: Int
        public var matchedCount: Int
        public var meanMs: Double
        public var stdMs: Double
        public var maxAbsMs: Double
        /// 偏移对时间的最小二乘斜率（ms / s）。
        public var slopeMsPerSecond: Double
        /// 斜率 × 首尾事件间隔（A3 口径）。
        public var driftOverSpanMs: Double
        public var spanSeconds: Double
        /// A2 阈值（1 帧，ms）。
        public var thresholdMs: Double
        /// A2：最大绝对值 ≤ 阈值。
        public var passA2: Bool?
    }

    /// 每个闪光帧 ↔ 最近 click 的时间差序列，均值 / 标准差 / 最大绝对值 / 线性拟合斜率。
    /// - Parameters:
    ///   - maxMatchSeconds: click 离闪光超过这个距离就算没配上。
    ///   - frameDurationSeconds: A2 阈值 = 1 帧。
    public static func av(frames: [ProbeFrame], clicks: [ClickEvent], maxMatchSeconds: Double = 0.5,
                          frameDurationSeconds: Double = 1.0 / 60) -> AVReport {
        let clickTimes = clicks.map(\.timeSeconds)
        var pairs: [AVPair] = []
        var prevFlash = false
        for f in frames {
            defer { prevFlash = f.flash }
            guard f.flash && !prevFlash else { continue }
            var pair = AVPair(flashIndex: f.index, flashTimeSeconds: f.ptsSeconds, genTimeMs: f.genTimeMs, clickTimeSeconds: nil, offsetMs: nil)
            if let c = nearest(clickTimes, to: f.ptsSeconds), abs(c - f.ptsSeconds) <= maxMatchSeconds {
                pair.clickTimeSeconds = c
                pair.offsetMs = (f.ptsSeconds - c) * 1000
            }
            pairs.append(pair)
        }
        let matched = pairs.filter { $0.offsetMs != nil }
        let offsets = matched.map { $0.offsetMs! }
        let times = matched.map(\.flashTimeSeconds)
        let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty ? 0 : offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(offsets.count)
        let (slope, _) = linearFit(x: times, y: offsets)
        let span = (times.last ?? 0) - (times.first ?? 0)
        let threshold = frameDurationSeconds * 1000
        let maxAbs = offsets.map(abs).max() ?? 0
        return AVReport(pairs: pairs, flashCount: pairs.count, clickCount: clicks.count, matchedCount: matched.count,
                        meanMs: mean, stdMs: variance.squareRoot(), maxAbsMs: maxAbs, slopeMsPerSecond: slope,
                        driftOverSpanMs: slope * span, spanSeconds: span, thresholdMs: threshold,
                        passA2: matched.isEmpty ? nil : maxAbs <= threshold)
    }

    /// 已排序数组里离 t 最近的值。
    static func nearest(_ sorted: [Double], to t: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best = sorted[min(lo, sorted.count - 1)]
        if lo > 0 && abs(sorted[lo - 1] - t) < abs(best - t) { best = sorted[lo - 1] }
        return best
    }

    /// 最小二乘：y = slope × x + intercept。少于 2 点返回 (0, mean)。
    public static func linearFit(x: [Double], y: [Double]) -> (slope: Double, intercept: Double) {
        let n = Double(x.count)
        guard x.count >= 2 else { return (0, y.first ?? 0) }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<x.count {
            sxx += (x[i] - mx) * (x[i] - mx)
            sxy += (x[i] - mx) * (y[i] - my)
        }
        guard sxx > 0 else { return (0, my) }
        let slope = sxy / sxx
        return (slope, my - slope * mx)
    }

    // MARK: - A4

    /// 多文件里的同一事件。
    public struct MultiFileEvent: Hashable, Codable, Sendable {
        /// 事件键：闪光帧的 genTimeMs（各文件共用 t0 时一致），否则序号。
        public var key: String
        /// 每个文件里的闪光时刻（没有为 nil）。
        public var flashTimes: [Double?]
        /// 每个文件里对应的 click 时刻。
        public var clickTimes: [Double?]
        /// 闪光时刻的极差（ms）。
        public var flashSpreadMs: Double?
        /// click 时刻的极差（ms）。
        public var clickSpreadMs: Double?
    }
    public struct MultiFileAVReport: Hashable, Codable, Sendable {
        public var files: [String]
        public var events: [MultiFileEvent]
        public var maxFlashSpreadMs: Double
        public var maxClickSpreadMs: Double
        public var thresholdMs: Double
        /// A4：各文件同一事件的时间差 ≤ 1 帧。
        public var passA4: Bool?
    }

    /// 多文件模式比较同一事件（A4）。事件按闪光帧的 genTimeMs 对齐（±1 帧内算同一事件）；读不到时按序号。
    public static func avMulti(files: [(name: String, frames: [ProbeFrame], clicks: [ClickEvent])],
                               frameDurationSeconds: Double = 1.0 / 60) -> MultiFileAVReport {
        let reports = files.map { av(frames: $0.frames, clicks: $0.clicks, frameDurationSeconds: frameDurationSeconds) }
        let toleranceMs = UInt32((frameDurationSeconds * 1000).rounded(.up))
        // 收集事件键
        var keys: [(key: String, gen: UInt32?, ordinal: Int)] = []
        var pairsByFile: [[(key: String, pair: AVPair)]] = []
        let useGen = reports.allSatisfy { $0.pairs.allSatisfy { $0.genTimeMs != nil } } && !reports.isEmpty
        for r in reports {
            var list: [(String, AVPair)] = []
            for (i, p) in r.pairs.enumerated() {
                let key: String
                if useGen, let g = p.genTimeMs {
                    if let existing = keys.first(where: { k in k.gen.map { abs(Int64($0) - Int64(g)) <= Int64(toleranceMs) } ?? false }) {
                        key = existing.key
                    } else {
                        key = "gen:\(g)"
                        keys.append((key, g, i))
                    }
                } else {
                    key = "#\(i)"
                    if !keys.contains(where: { $0.key == key }) { keys.append((key, nil, i)) }
                }
                list.append((key, p))
            }
            pairsByFile.append(list)
        }
        var events: [MultiFileEvent] = []
        var maxFlash = 0.0, maxClick = 0.0
        for k in keys {
            var flashes: [Double?] = [], clicks: [Double?] = []
            for list in pairsByFile {
                let p = list.first { $0.key == k.key }?.pair
                flashes.append(p?.flashTimeSeconds)
                clicks.append(p?.clickTimeSeconds)
            }
            let fv = flashes.compactMap { $0 }, cv = clicks.compactMap { $0 }
            let fs = fv.count >= 2 ? (fv.max()! - fv.min()!) * 1000 : nil
            let cs = cv.count >= 2 ? (cv.max()! - cv.min()!) * 1000 : nil
            if let fs { maxFlash = max(maxFlash, fs) }
            if let cs { maxClick = max(maxClick, cs) }
            events.append(MultiFileEvent(key: k.key, flashTimes: flashes, clickTimes: clicks, flashSpreadMs: fs, clickSpreadMs: cs))
        }
        let threshold = frameDurationSeconds * 1000
        let comparable = events.contains { $0.flashSpreadMs != nil }
        return MultiFileAVReport(files: files.map(\.name), events: events, maxFlashSpreadMs: maxFlash, maxClickSpreadMs: maxClick,
                                 thresholdMs: threshold, passA4: comparable ? (maxFlash <= threshold && maxClick <= threshold) : nil)
    }
}
