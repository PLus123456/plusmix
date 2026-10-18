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


    // MARK: - 节目拍号（W1-A6，Codex T02）

    /// 一帧的节目拍号 = startTick + round((pts − 第一帧 pts) × fps)。`av` 的闪光拍号、`switches` / `fade` 的转场落点共用这一个式子。
    /// 转场分析原来拿数组下标当拍号：文件里漏了帧（missed_render），下标就比拍号小，正确的第 60 拍 Cut 前面漏两帧就报成第 58 拍、
    /// 30 拍 Fade 被判 2 帧偏差（reports/codex-debug-audit-20261013.md §1.5 T02）。拍号来源本身（第一帧 = 第 startTick 拍、帧距均匀）不改，
    /// 理由见 reports/issues/W1B4-w1-testkit-frameprobe-delayed-video-start.md。
    static func programTick(pts: Double, pts0: Double, fps: Double, startTick: Int64) -> Int64 {
        startTick + Int64(((pts - pts0) * fps).rounded())
    }

    /// 每帧的节目拍号（`programTick`，pts0 = 第一帧的 pts）。
    public static func programTicks(_ frames: [ProbeFrame], fps: Double, startTick: Int64 = 0) -> [Int64] {
        let pts0 = frames.first?.ptsSeconds ?? 0
        return frames.map { programTick(pts: $0.ptsSeconds, pts0: pts0, fps: fps, startTick: startTick) }
    }

    /// 节目帧率的估计：相邻帧 pts 差里正常的那些（< 1.5 × 中位数；漏帧留下的 2 帧、3 帧空档不算）求平均再取倒数。
    /// 转场分析没给帧率（`--fps`）时用它，不用容器的 nominalFrameRate：AVFoundation 给的是"样本数 / 时长"，漏了帧就偏低
    /// （W1-A6 探针：60 fps 3600 帧漏 2 帧 → 59.967、漏 60 帧 → 59.0，minFrameDuration 仍是 1/60），10 分钟的文件后面差出好几拍；
    /// minFrameDuration 对推流落盘的毫秒时间戳（16 / 17 ms 交替）又偏高。一半以上的帧都漏了的文件估不对，要给 `--fps`。
    public static func programFps(_ frames: [ProbeFrame]) -> Double? {
        guard frames.count >= 2 else { return nil }
        var deltas: [Double] = []
        deltas.reserveCapacity(frames.count - 1)
        for i in 1..<frames.count {
            let d = frames[i].ptsSeconds - frames[i - 1].ptsSeconds
            if d > 0 { deltas.append(d) }
        }
        guard !deltas.isEmpty else { return nil }
        let median = deltas.sorted()[deltas.count / 2]
        var sum = 0.0, n = 0
        for d in deltas where d < 1.5 * median { sum += d; n += 1 }
        return n > 0 && sum > 0 ? Double(n) / sum : nil
    }

    /// 拍号序列里漏掉的拍：相邻两帧拍号差 > 1 时中间那些拍（文件里没有这些拍的帧）。`window` 给了只数落在里面的；
    /// `list` 最多 `limit` 个，`count` 是全部。文件头尾之外的拍不算（看不见）。
    static func missingTicks(_ ticks: [Int64], within window: ClosedRange<Int64>? = nil, limit: Int = .max) -> (list: [Int64], count: Int) {
        var list: [Int64] = []
        var count = 0
        guard ticks.count >= 2 else { return (list, count) }
        for i in 1..<ticks.count where ticks[i] - ticks[i - 1] > 1 {
            var lo = ticks[i - 1] + 1, hi = ticks[i] - 1
            if let w = window { lo = max(lo, w.lowerBound); hi = min(hi, w.upperBound) }
            guard lo <= hi else { continue }
            count += Int(hi - lo + 1)
            var t = lo
            while t <= hi && list.count < limit { list.append(t); t += 1 }
        }
        return (list, count)
    }

    // MARK: - V6

    /// 某路输入的标称灰度（该 ID 帧的众数）。
    public struct NominalGray: Hashable, Codable, Sendable {
        public var inputID: Int
        public var gray: Double
    }
    /// 一次切换。
    public struct Switch: Hashable, Codable, Sendable {
        /// 新输入 ID 出现的第一帧（文件里的序号）。
        public var index: Int
        /// 这一帧的节目拍号：startTick + round((pts − 第一帧 pts) × fps)（`programTick`；W1-A6 之前是 startTick + index，漏帧之后就错开了）。
        public var tick: Int64
        public var ptsSeconds: Double
        public var from: Int?
        public var to: Int
        /// 旧输入最后出现的帧。
        public var lastFromIndex: Int?
        /// 两者之间读不出 ID 的帧数（文件里实有的帧）：0 = Cut，> 0 = 转场。
        public var betweenFrames: Int
        /// "cut" 或 "transition"。
        public var kind: String
        /// 切换前一帧（文件里的上一帧）灰度是否不等于任一输入标称灰度。
        public var mixedBefore: Bool
        /// 切换帧灰度是否不等于任一输入标称灰度。
        public var mixedAt: Bool
        /// 切换后一帧是否混合。
        public var mixedAfter: Bool
        /// Cut 且前后都无混合帧（V6 硬性）。
        public var cleanCut: Bool
        /// 旧输入最后一帧与新输入第一帧之间漏掉的拍数（文件里没有这些拍的帧）；没漏为 nil。
        /// Cut 的这一项不为 nil 时，新画面第一帧仍是 `tick`，但真正换过去的那一拍可能落在漏掉的拍里——缺帧单独报，不改落点与 cleanCut。
        public var missingBetween: Int? = nil
    }
    public struct SwitchesReport: Hashable, Codable, Sendable {
        public var startTick: Int64
        public var grayTolerance: Double
        public var nominalGrays: [NominalGray]
        public var switches: [Switch]
        /// 所有 Cut 都干净。
        public var allCutsClean: Bool
        /// 拍号用的帧率：给了就是给的，没给按相邻帧 pts 差估（`programFps`）。老版本 JSON 没有。
        public var fps: Double? = nil
        /// 文件里漏掉的拍（相邻两帧拍号差 > 1 的中间那些拍），最多列 maxEvents 个。
        public var missingFrames: [Int64]? = nil
        /// 漏掉的拍数（全部）。
        public var missingFrameCount: Int? = nil
    }

    /// 输入 ID 变化的帧、Cut 前后有无混合帧（判据：帧灰度不等于任一输入的标称灰度）。
    ///
    /// 几种转场在这里各是什么样（W1-A3）：
    /// - **Cut**：`betweenFrames == 0`，`cleanCut` 要为真（V6 硬性）。
    /// - **Fade / Wipe / Zoom**：中间帧解不出输入身份（自证解码判掉，见 `SelfCheck`），所以是一条 `betweenFrames > 0` 的 transition。
    ///   Wipe 走到解码区整幅都是新画面之后（leftToRight 上是 progress ≥ 0.625）就认出新输入了，`betweenFrames` 会比转场时长短，这是对的。
    /// - **静态 PNG 的 Stinger**：叠层只盖画面的一部分，底下的输入照常解得出，所以它在这里就是**第 cutAtTick 拍的一次 Cut**
    ///   （实测 g4：第 9900 拍发 Stinger、cutAtTick = 12 → 第 9912 拍一条 cut，cleanCut 为真）。
    ///   判据是叠层在**解码区**（帧号行、时间戳行、ID 块、中心采样区、ID 邻域条，见 `PatternProbe.decodeRects`）上必须是透明的——
    ///   G4Factory 的 PNG 就是按这个画的（只占下 20% 与左右两侧）。叠层要是盖住了解码区，那几帧会被自证判成解不出，
    ///   这里就变成一条 `betweenFrames > 0` 的 transition，而不是 Cut。动画 stinger（文件输入）落地后再看。
    /// - Parameters:
    ///   - startTick: 输出第 0 帧对应的节目拍（默认 0）。
    ///   - fps: 拍号用的节目帧率；nil = 按相邻帧 pts 差估（`programFps`）。tick = startTick + round((pts − 第一帧 pts) × fps)，
    ///     不再是 startTick + index（W1-A6，Codex T02）：文件里漏的帧单独列在 `missingFrames`，不挪后面转场的落点。
    ///   - maxEvents: `missingFrames` 最多列多少个。
    public static func switches(frames: [ProbeFrame], startTick: Int64 = 0, grayTolerance: Double = 6,
                                fps: Double? = nil, maxEvents: Int = 200) -> SwitchesReport {
        let nominal = nominalGrays(frames)
        let nominalValues = nominal.map(\.gray)
        let tickFps = fps ?? programFps(frames) ?? 60
        let ticks = programTicks(frames, fps: tickFps, startTick: startTick)
        // 下标是数组位置（文件里的相邻帧），拍号是 ticks[位置]
        func isMixed(_ i: Int) -> Bool {
            guard i >= 0 && i < frames.count else { return false }
            let g = frames[i].gray
            return !nominalValues.contains { abs($0 - g) <= grayTolerance }
        }
        var switches: [Switch] = []
        var lastID: Int?
        var lastPosition: Int?
        for (i, f) in frames.enumerated() {
            guard let id = f.inputID else { continue }
            if let l = lastID, let p = lastPosition, l != id {
                let between = i - (p + 1)
                let missing = Int(ticks[i] - ticks[p] - 1) - between
                var sw = Switch(index: f.index, tick: ticks[i], ptsSeconds: f.ptsSeconds, from: l, to: id,
                                lastFromIndex: frames[p].index, betweenFrames: between, kind: between == 0 ? "cut" : "transition",
                                mixedBefore: isMixed(i - 1), mixedAt: isMixed(i), mixedAfter: isMixed(i + 1),
                                cleanCut: between == 0 && !isMixed(i - 1) && !isMixed(i) && !isMixed(i + 1))
                if missing > 0 { sw.missingBetween = missing }
                switches.append(sw)
            } else if lastID == nil {
                // 第一路出现也记一条（from nil）
                switches.append(Switch(index: f.index, tick: ticks[i], ptsSeconds: f.ptsSeconds, from: nil, to: id,
                                       lastFromIndex: nil, betweenFrames: 0, kind: "start", mixedBefore: false, mixedAt: isMixed(i),
                                       mixedAfter: isMixed(i + 1), cleanCut: true))
            }
            lastID = id
            lastPosition = i
        }
        let cuts = switches.filter { $0.kind == "cut" }
        let missing = missingTicks(ticks, limit: maxEvents)
        return SwitchesReport(startTick: startTick, grayTolerance: grayTolerance, nominalGrays: nominal, switches: switches,
                              allCutsClean: cuts.allSatisfy(\.cleanCut), fps: tickFps, missingFrames: missing.list,
                              missingFrameCount: missing.count)
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
        /// 文件里的序号。
        public var index: Int
        /// 节目拍号（`programTick`）。
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
        /// 第一个混合帧（文件里的序号）。
        public var startIndex: Int
        /// 最后一个混合帧。
        public var endIndex: Int
        /// 第一个混合帧的节目拍号。
        public var startTick: Int64
        /// "A→B" 或 "B→A"。
        public var direction: String
        /// 混合帧数（文件里实有的帧）。
        public var mixedFrames: Int
        /// 转场时长 D（拍）：给定值，或 末个混合帧拍号 − 首个混合帧拍号 + 2（没漏帧时 = mixedFrames + 1）。
        public var durationTicks: Int
        public var samples: [FadeSample]
        /// 与线性曲线的最大偏差（帧）。
        public var maxDeviationFrames: Double
        /// 最大进度误差（0–1）。
        public var maxProgressError: Double
        /// 进度是否单调不减。
        public var monotonic: Bool
        /// V7：曲线误差 ≤ 1 帧（只在有样本的拍上判；漏掉的拍见 missingFrames）。
        public var passV7: Bool
        /// 这次 Fade 的窗口里漏掉的拍（指定模式 [s, s + D]；自动模式是混合段前后两个纯色帧之间）：那些拍没有样本，单独列，不占 k。
        public var missingFrames: [Int64]? = nil
        public var missingFrameCount: Int? = nil
    }
    public struct FadeReport: Hashable, Codable, Sendable {
        public var grayA: Double
        public var grayB: Double
        public var fades: [Fade]
        public var allPassV7: Bool
        /// 拍号用的帧率（给的，或按相邻帧 pts 差估的）。老版本 JSON 没有。
        public var fps: Double? = nil
        /// 整个文件漏掉的拍（最多列 maxEvents 个）与拍数。
        public var missingFrames: [Int64]? = nil
        public var missingFrameCount: Int? = nil
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
    ///
    /// 拍号按 pts（`programTick`，W1-A6，Codex T02）：指定模式按拍号找第 s + k 拍那一帧（不是下标 s + k），
    /// 自动模式的 k = 这一帧的拍号 − s（s = 第一个混合帧的拍号 − 1）、D = 末拍 − 首拍 + 2。漏掉的拍没有样本、不占 k，单独列在 `missingFrames`。
    /// - Parameter fps: 拍号用的节目帧率；nil = 按相邻帧 pts 差估（`programFps`）。
    public static func fade(frames: [ProbeFrame], grayA: Double = 64, grayB: Double = 192, durationTicks: Int? = nil,
                            at commandTick: Int64? = nil, tolerance: Double = 2, startTick: Int64 = 0,
                            fps: Double? = nil, maxEvents: Int = 200) -> FadeReport {
        precondition(grayA != grayB)
        let span = grayB - grayA
        let tickFps = fps ?? programFps(frames) ?? 60
        let ticks = programTicks(frames, fps: tickFps, startTick: startTick)
        func ratio(_ g: Double) -> Double { (g - grayA) / span }
        func isMixed(_ f: ProbeFrame) -> Bool {
            let tol = tolerance / abs(span)
            let r = ratio(f.gray)
            return r > tol && r < 1 - tol
        }
        /// points：(数组位置, k)，k = 拍号 − s。
        func evaluate(_ points: [(position: Int, k: Int)], before: Double, after: Double, d: Int, window: ClosedRange<Int64>) -> Fade {
            let aToB = after >= before
            var samples: [FadeSample] = []
            var maxDev = 0.0, maxErr = 0.0, monotonic = true
            var lastProgress = -1.0
            for (i, k) in points {
                let f = frames[i]
                let r = ratio(f.gray)
                let p = aToB ? r : 1 - r
                let expected = Double(k) / Double(d)
                let dev = abs(p * Double(d) - Double(k))
                maxDev = max(maxDev, dev)
                maxErr = max(maxErr, abs(p - expected))
                if p < lastProgress - 1e-9 { monotonic = false }
                lastProgress = p
                samples.append(FadeSample(index: f.index, tick: ticks[i], gray: f.gray, ratio: r, progress: p,
                                          expectedProgress: expected, deviationFrames: dev))
            }
            let first = points.first!.position, last = points.last!.position
            let missing = missingTicks(ticks, within: window, limit: maxEvents)
            return Fade(startIndex: frames[first].index, endIndex: frames[last].index, startTick: ticks[first], direction: aToB ? "A→B" : "B→A",
                        mixedFrames: points.count, durationTicks: d, samples: samples, maxDeviationFrames: maxDev,
                        maxProgressError: maxErr, monotonic: monotonic, passV7: maxDev <= v7MaximumDeviationFrames,
                        missingFrames: missing.list, missingFrameCount: missing.count)
        }
        var fades: [Fade] = []
        if let s = commandTick {
            guard let d = durationTicks, d >= 2 else { preconditionFailure("指定 at 时必须给 durationTicks ≥ 2") }
            let end = s + Int64(d)
            var positionByTick: [Int64: Int] = [:]
            for (i, t) in ticks.enumerated() where (s...end).contains(t) && positionByTick[t] == nil { positionByTick[t] = i }
            let points = (1..<d).compactMap { k in positionByTick[s + Int64(k)].map { (position: $0, k: k) } }
            // 文件要盖住第 s 拍（纯旧画面）到第 s + D − 1 拍，与原来"下标 s 到 s + D − 1 都在文件里"同一个条件
            if let firstTick = ticks.first, let lastTick = ticks.last, firstTick <= s, lastTick >= end - 1, !points.isEmpty,
               let beforePosition = positionByTick[s] ?? ticks.lastIndex(where: { $0 < s }) {
                let before = ratio(frames[beforePosition].gray)
                let afterPosition = positionByTick[end] ?? ticks.firstIndex { $0 > end }
                let after = afterPosition.map { ratio(frames[$0].gray) } ?? 1 - before
                fades.append(evaluate(points, before: before, after: after, d: d, window: s...end))
            }
        } else {
            var i = 0
            while i < frames.count {
                guard isMixed(frames[i]) else { i += 1; continue }
                var j = i
                while j + 1 < frames.count && isMixed(frames[j + 1]) { j += 1 }
                let before = i > 0 ? ratio(frames[i - 1].gray) : ratio(frames[i].gray)
                let after = j + 1 < frames.count ? ratio(frames[j + 1].gray) : ratio(frames[j].gray)
                let s = ticks[i] - 1
                let points = (i...j).map { (position: $0, k: Int(ticks[$0] - s)) }
                // 漏帧窗口：混合段前一个纯色帧与后一个纯色帧之间（段头段尾漏了帧时，段的起止本身就不确定）
                let window = (i > 0 ? ticks[i - 1] + 1 : ticks[i])...(j + 1 < frames.count ? ticks[j + 1] - 1 : ticks[j])
                fades.append(evaluate(points, before: before, after: after, d: durationTicks ?? Int(ticks[j] - ticks[i]) + 2, window: window))
                i = j + 1
            }
        }
        let missing = missingTicks(ticks, limit: maxEvents)
        return FadeReport(grayA: grayA, grayB: grayB, fades: fades, allPassV7: fades.allSatisfy(\.passV7), fps: tickFps,
                          missingFrames: missing.list, missingFrameCount: missing.count)
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
        /// 闪光帧的节目拍号 = startTick + round((pts − 第一帧 pts) × fps)（`programTick`，与转场分析同一个式子）。
        public var tick: Int64
        /// 闪光是否落在整秒拍上（拍号是标称整数帧率的倍数）。59.94 的路在 60 fps 节目里在播时闪光周期 1.001 s（契约定的），
        /// 相对整秒的 click 逐秒滞后，这些配对只报不判（G2 报告第 5 条、W2-E 清单 3-10）。
        public var onSecondTick: Bool
    }

    /// 一组配对的统计。
    public struct AVStats: Hashable, Codable, Sendable {
        public var count: Int
        public var meanMs: Double
        public var stdMs: Double
        public var maxAbsMs: Double
        /// 偏移对时间的最小二乘斜率（ms / s）。
        public var slopeMsPerSecond: Double
        /// 斜率 × 首尾事件间隔（A3 口径）。
        public var driftOverSpanMs: Double
        public var spanSeconds: Double

        public static let empty = AVStats(count: 0, meanMs: 0, stdMs: 0, maxAbsMs: 0, slopeMsPerSecond: 0, driftOverSpanMs: 0, spanSeconds: 0)

        /// 由 (时刻, 偏移) 序列算。
        public init(times: [Double], offsets: [Double]) {
            count = offsets.count
            let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
            let variance = offsets.isEmpty ? 0 : offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(offsets.count)
            meanMs = mean
            stdMs = variance.squareRoot()
            maxAbsMs = offsets.map(abs).max() ?? 0
            slopeMsPerSecond = FrameAnalysis.linearFit(x: times, y: offsets).slope
            spanSeconds = (times.last ?? 0) - (times.first ?? 0)
            driftOverSpanMs = slopeMsPerSecond * spanSeconds
        }
        init(count: Int, meanMs: Double, stdMs: Double, maxAbsMs: Double, slopeMsPerSecond: Double, driftOverSpanMs: Double, spanSeconds: Double) {
            self.count = count; self.meanMs = meanMs; self.stdMs = stdMs; self.maxAbsMs = maxAbsMs
            self.slopeMsPerSecond = slopeMsPerSecond; self.driftOverSpanMs = driftOverSpanMs; self.spanSeconds = spanSeconds
        }
    }

    public struct AVReport: Hashable, Codable, Sendable {
        public var pairs: [AVPair]
        public var flashCount: Int
        public var clickCount: Int
        public var matchedCount: Int
        /// 以下六项是**全部配对**的统计（含 59.94 在播段的假象；gate 脚本在读，字段保留）。
        public var meanMs: Double
        public var stdMs: Double
        public var maxAbsMs: Double
        /// 偏移对时间的最小二乘斜率（ms / s）。
        public var slopeMsPerSecond: Double
        /// 斜率 × 首尾事件间隔（A3 口径）。
        public var driftOverSpanMs: Double
        public var spanSeconds: Double
        /// **整秒拍配对**的统计：A2 / A3 的判定口径。
        public var onSecond: AVStats
        /// 配上了但闪光不在整秒拍上的数量（59.94 在播段）。
        public var offSecondCount: Int
        /// 判整秒拍用的节目帧率与第 0 帧的拍号。
        public var programFps: Double
        public var startTick: Int64
        /// A2 阈值（1 帧，ms）。
        public var thresholdMs: Double
        /// A2：整秒拍配对的最大绝对值 ≤ 阈值；一个整秒配对都没有时为 nil。
        public var passA2: Bool?
        /// 有不在整秒拍上的配对时的说明。
        public var note: String?
    }

    /// 每个闪光帧 ↔ 最近 click 的时间差序列。A2 / A3 按整秒拍配对判（`onSecond`），全部配对另报。
    /// - Parameters:
    ///   - maxMatchSeconds: click 离闪光超过这个距离就算没配上。
    ///   - frameDurationSeconds: 节目帧时长；A2 阈值 = 1 帧，整秒拍 = 拍号是 round(1 / 帧时长) 的倍数。
    ///   - startTick: 文件第一帧对应的节目拍（推流落盘从关键帧起录时用 `--start-tick` 对上）。录制文件从第 0 拍起：G8b 起开录起点按节目输出时间线，
    ///     带视频延后（Master 效果 L > 0）录的也是，默认 0 就对；录制中途 L 变了的话之后的拍号整体错开 ΔL（> 半帧时整秒判定失效，配对本身仍对齐）。
    public static func av(frames: [ProbeFrame], clicks: [ClickEvent], maxMatchSeconds: Double = 0.5,
                          frameDurationSeconds: Double = 1.0 / 60, startTick: Int64 = 0) -> AVReport {
        let clickTimes = clicks.map(\.timeSeconds)
        let fps = 1 / frameDurationSeconds
        let nominal = Int64(max(1, fps.rounded()))
        let pts0 = frames.first?.ptsSeconds ?? 0
        var pairs: [AVPair] = []
        var prevFlash = false
        for f in frames {
            defer { prevFlash = f.flash }
            guard f.flash && !prevFlash else { continue }
            let tick = programTick(pts: f.ptsSeconds, pts0: pts0, fps: fps, startTick: startTick)
            var pair = AVPair(flashIndex: f.index, flashTimeSeconds: f.ptsSeconds, genTimeMs: f.genTimeMs, clickTimeSeconds: nil, offsetMs: nil,
                              tick: tick, onSecondTick: ((tick % nominal) + nominal) % nominal == 0)
            if let c = nearest(clickTimes, to: f.ptsSeconds), abs(c - f.ptsSeconds) <= maxMatchSeconds {
                pair.clickTimeSeconds = c
                pair.offsetMs = (f.ptsSeconds - c) * 1000
            }
            pairs.append(pair)
        }
        let matched = pairs.filter { $0.offsetMs != nil }
        let all = AVStats(times: matched.map(\.flashTimeSeconds), offsets: matched.map { $0.offsetMs! })
        let onPairs = matched.filter(\.onSecondTick)
        let on = AVStats(times: onPairs.map(\.flashTimeSeconds), offsets: onPairs.map { $0.offsetMs! })
        let off = matched.count - onPairs.count
        let threshold = frameDurationSeconds * 1000
        var note: String?
        if off > 0 {
            note = "\(off) 个配对的闪光不在整秒拍上（拍号不是 \(nominal) 的倍数，如 59.94 的路在播时闪光周期 1.001 s 逐秒滞后），只报不判；" +
                   "全部配对均值 \(String(format: "%.3f", all.meanMs)) ms vs 整秒配对 \(String(format: "%.3f", on.meanMs)) ms" +
                   (onPairs.isEmpty ? "；一个整秒配对都没有——文件不从第 0 拍起时用 --start-tick 给出第一帧的拍号" : "")
        }
        return AVReport(pairs: pairs, flashCount: pairs.count, clickCount: clicks.count, matchedCount: matched.count,
                        meanMs: all.meanMs, stdMs: all.stdMs, maxAbsMs: all.maxAbsMs, slopeMsPerSecond: all.slopeMsPerSecond,
                        driftOverSpanMs: all.driftOverSpanMs, spanSeconds: all.spanSeconds,
                        onSecond: on, offSecondCount: off, programFps: fps, startTick: startTick, thresholdMs: threshold,
                        passA2: onPairs.isEmpty ? nil : on.maxAbsMs <= threshold, note: note)
    }

    // MARK: - A1 第三项：波形不连续

    /// 一次不连续（相邻样本跳变 > 阈值且不在 click 位置）。
    public struct DiscontinuityEvent: Hashable, Codable, Sendable {
        /// 音轨样本序号（跳到的那个样本）。
        public var sampleIndex: Int64
        /// 文件时间线上的时刻（秒）。
        public var timeSeconds: Double
        /// 跳变量（有符号，满幅比例）。
        public var jump: Float
    }

    public struct DiscontinuityReport: Hashable, Codable, Sendable {
        /// 不连续次数（A1 的第三个加数）。
        public var count: Int
        /// 前 maxEvents 条。
        public var events: [DiscontinuityEvent]
        public var truncated: Bool
        /// 落在 click 窗口内而被排除的 > 阈值跳变数（合成 click 每个进 / 出各一次；AAC 解码后边沿多几个台阶也在这里）。
        public var jumpsAtClicks: Int
        public var threshold: Float
        public var clickCount: Int
        /// 排除窗口：click 起点前 marginMs 到起点 + clickMs + marginMs。
        public var clickMs: Double
        public var marginMs: Double
        public var sampleCount: Int
        /// A1 第三项：0 次（硬性）。
        public var passA1: Bool
    }

    /// 离线口径（搬自 W2-E `DiscontinuityDetector.analyze(samples:isExcluded:)`）：相邻样本跳变 > threshold 满幅，跳入 / 跳出落在任一 click 窗口
    /// [click − margin, click + clickSeconds + margin] 内的不算。计的是"跳变"次数：一次台阶 = 1，单个样本的毛刺 = 2（进、出）。
    public static func discontinuities(samples: [Float], sampleRate: Double, startSeconds: Double, clicks: [ClickEvent],
                                       threshold: Float = 0.5, clickSeconds: Double = 0.001, marginSeconds: Double = 0.001,
                                       maxEvents: Int = 200) -> DiscontinuityReport {
        let margin = Int64((marginSeconds * sampleRate).rounded(.up))
        let clickLen = Int64((clickSeconds * sampleRate).rounded(.up))
        // 排除区间（已排序、可能重叠）；走一个游标
        let windows = clicks.map { ($0.sampleIndex - margin, $0.sampleIndex + clickLen + margin) }.sorted { $0.0 < $1.0 }
        var cursor = 0
        func excluded(_ i: Int64) -> Bool {
            while cursor < windows.count && windows[cursor].1 < i - 1 { cursor += 1 }
            var k = cursor
            while k < windows.count && windows[k].0 <= i {
                if i >= windows[k].0 && i <= windows[k].1 { return true }
                k += 1
            }
            return false
        }
        var events: [DiscontinuityEvent] = []
        var count = 0, atClicks = 0
        if samples.count >= 2 {
            for i in 1..<samples.count {
                let jump = samples[i] - samples[i - 1]
                guard abs(jump) > threshold else { continue }
                let idx = Int64(i)
                if excluded(idx) || excluded(idx - 1) { atClicks += 1; continue }
                count += 1
                if events.count < maxEvents { events.append(DiscontinuityEvent(sampleIndex: idx, timeSeconds: startSeconds + Double(idx) / sampleRate, jump: jump)) }
            }
        }
        return DiscontinuityReport(count: count, events: events, truncated: count > events.count, jumpsAtClicks: atClicks, threshold: threshold,
                                   clickCount: clicks.count, clickMs: clickSeconds * 1000, marginMs: marginSeconds * 1000,
                                   sampleCount: samples.count, passA1: count == 0)
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
        /// 每个文件里对应的 click 时刻：锚文件是它自己配上的那个，其他文件是离锚最近的那个（W1-A5，见 `avMulti`）。
        public var clickTimes: [Double?]
        /// 闪光时刻的极差（ms）。
        public var flashSpreadMs: Double?
        /// click 时刻的极差（ms）。
        public var clickSpreadMs: Double?
        /// 锚文件序号：按传入顺序第一个给这个事件配上 click 的文件（gate4 里是 [0] PGM）；一个都没配上时为 nil。
        public var anchorFile: Int?
        /// 闪光离锚 click 在半秒 ±1 帧内（没有 click 时按离最近的整秒算）：前后两个 click 差不多一样近，配哪一秒是平局——只列不判。
        public var halfSecond: Bool?
        /// 有这个事件的闪光、但锚 ±maxMatchSeconds 内没有 click 的文件序号（那一格 clickTimes 是 nil，极差只在剩下的文件里算）；没有为 nil。
        /// 判定事件（非半秒）里有这样的文件 = A4 不过（用户 2026-10-17 定，测试标准 §2.3）；没有锚的事件（一个文件都没配上 click）不算缺。
        public var missingClickFiles: [Int]? = nil
        /// 别的文件有这个事件的闪光、这个文件没有（那一格 flashTimes 是 nil）的文件序号；判定事件里有 = A4 不过（用户 2026-10-18 裁定 #22，G10 胶水 ⑥）。
        public var missingFlashFiles: [Int]? = nil
    }
    public struct MultiFileAVReport: Hashable, Codable, Sendable {
        public var files: [String]
        public var events: [MultiFileEvent]
        /// 判定事件（不含半秒事件）里闪光时刻的最大极差（ms）：A4 的判定口径，gate 脚本读它。
        public var maxFlashSpreadMs: Double
        /// 判定事件里 click 时刻的最大极差（ms）：A4 的判定口径，gate 脚本读它。缺 click 的那一格不进极差（看 missingClickEventCount / passA4）。
        public var maxClickSpreadMs: Double
        public var thresholdMs: Double
        /// A4：判定事件里各文件同一事件的时间差 ≤ 1 帧，且没有文件缺 click；一个可比的判定事件都没有（也没有缺 click 的）时为 nil。
        public var passA4: Bool?
        /// 半秒事件数（只列不判）。
        public var halfSecondEventCount: Int?
        /// 含半秒事件的最大闪光极差（ms，只报不判）。
        public var allEventsMaxFlashSpreadMs: Double?
        /// 含半秒事件的最大 click 极差（ms，只报不判）。
        public var allEventsMaxClickSpreadMs: Double?
        /// 有半秒事件 / 缺 click / 没有锚的事件时的说明。
        public var note: String?
        /// 判定事件里有文件缺 click 的事件数：> 0 时 passA4 = false（W1-A6）。老版本 JSON 没有。
        public var missingClickEventCount: Int? = nil
        /// 没有锚的事件数（一个文件都没配上 click，只比闪光；G8 / G9 的第 0 s 就是这样）。
        public var unanchoredEventCount: Int? = nil
        /// 判定事件里有文件缺闪光的事件数：> 0 时 passA4 = false（G10 胶水 ⑥）。老版本 JSON 没有。
        public var missingFlashEventCount: Int? = nil
    }

    /// 多文件模式比较同一事件（A4）。事件按闪光帧的 genTimeMs 对齐（±1 帧内算同一事件）；读不到时按序号。
    ///
    /// click 不是各文件各自配"离自己闪光最近的"（W1-A5，reports/issues/G8b-w1-testkit-frameprobe-a4-halfsecond-click-tie.md）：闪光落在半秒时
    /// 前后两个整秒 click 差不多一样近，某路 click 晚几十微秒（消费者流 ±100 ppm）就配到另一秒，G8b 的 gate4 因此报了 999.979 ms。
    /// 现在以**锚**为准：按传入顺序第一个给这个事件配上 click 的文件（gate4 里 [0] 是 PGM）用它自己配的那个（与它的 A2 配对相同），
    /// 其他文件取**离锚最近**的 click（±maxMatchSeconds 内）；真错位照样体现在极差里（30 ms 就是 30 ms），不会因为离锚远就当成"没找到"藏掉。
    /// 闪光离锚 click 在半秒 ±1 帧内的事件（60 fps 节目从第 0 拍起的文件就是 |flash − round(flash)| ≈ 0.5）照常算、列在 events 里，
    /// 但不进 maxFlashSpreadMs / maxClickSpreadMs / passA4，含它们的最大值另报（A2 本来就只用整秒配对判）。
    /// 判定事件里某个文件有闪光、锚 ±maxMatchSeconds 内却没有 click（W1-A6，用户 2026-10-17 定）：那一格照旧 nil、极差只在剩下的文件里算，
    /// 事件里列出是哪个文件（`missingClickFiles`），passA4 = false。半秒事件里缺的照样列、不判；没有锚的事件不算缺（只比闪光，另计数）。
    public static func avMulti(files: [(name: String, frames: [ProbeFrame], clicks: [ClickEvent])],
                               frameDurationSeconds: Double = 1.0 / 60, maxMatchSeconds: Double = 0.5) -> MultiFileAVReport {
        let reports = files.map { av(frames: $0.frames, clicks: $0.clicks, maxMatchSeconds: maxMatchSeconds, frameDurationSeconds: frameDurationSeconds) }
        let clickTimes = files.map { $0.clicks.map(\.timeSeconds).sorted() }
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
        var maxFlash = 0.0, maxClick = 0.0, allFlash = 0.0, allClick = 0.0
        var halfCount = 0, unanchored = 0
        var missingJudged: [(key: String, files: [Int])] = [], missingFlashJudged: [(key: String, files: [Int])] = []
        for k in keys {
            let pairs = pairsByFile.map { list in list.first { $0.key == k.key }?.pair }
            let flashes = pairs.map { $0?.flashTimeSeconds }
            var clicks = [Double?](repeating: nil, count: pairs.count)
            var missing: [Int] = []
            let anchorFile = pairs.firstIndex { $0?.clickTimeSeconds != nil }
            // 判半秒用的 (闪光, click)：锚文件那一对；没有 click 时用第一个闪光和离它最近的整秒
            var reference: (flash: Double, click: Double)?
            if let a = anchorFile, let ap = pairs[a], let anchor = ap.clickTimeSeconds {
                reference = (ap.flashTimeSeconds, anchor)
                for i in pairs.indices where pairs[i] != nil {
                    if i == a { clicks[i] = anchor; continue }
                    if let c = nearest(clickTimes[i], to: anchor), abs(c - anchor) <= maxMatchSeconds { clicks[i] = c } else { missing.append(i) }
                }
            } else if let f = flashes.compactMap({ $0 }).first {
                reference = (f, f.rounded())
                unanchored += 1
            }
            let half = reference.map { abs(abs($0.flash - $0.click) - 0.5) <= frameDurationSeconds + 1e-9 } ?? false
            let fv = flashes.compactMap { $0 }, cv = clicks.compactMap { $0 }
            let fs = fv.count >= 2 ? (fv.max()! - fv.min()!) * 1000 : nil
            let cs = cv.count >= 2 ? (cv.max()! - cv.min()!) * 1000 : nil
            if let fs { allFlash = max(allFlash, fs); if !half { maxFlash = max(maxFlash, fs) } }
            if let cs { allClick = max(allClick, cs); if !half { maxClick = max(maxClick, cs) } }
            if half { halfCount += 1 }
            if !half && !missing.isEmpty { missingJudged.append((k.key, missing)) }
            let noFlash = flashes.indices.filter { flashes[$0] == nil }
            if !half && !noFlash.isEmpty { missingFlashJudged.append((k.key, noFlash)) }
            events.append(MultiFileEvent(key: k.key, flashTimes: flashes, clickTimes: clicks, flashSpreadMs: fs, clickSpreadMs: cs,
                                         anchorFile: anchorFile, halfSecond: half, missingClickFiles: missing.isEmpty ? nil : missing,
                                         missingFlashFiles: noFlash.isEmpty ? nil : noFlash))
        }
        let threshold = frameDurationSeconds * 1000
        let comparable = events.contains { $0.flashSpreadMs != nil && $0.halfSecond != true }
        var notes: [String] = []
        if !missingJudged.isEmpty {
            let shown = missingJudged.prefix(8).map { "\($0.key) 缺 " + $0.files.map { "[\($0)]" }.joined(separator: " ") }.joined(separator: "、")
            notes.append("\(missingJudged.count) 个判定事件里有文件在锚 ±\(String(format: "%.1f", maxMatchSeconds)) s 内没有 click（那一格空着、极差只在剩下的文件里算），A4 不过：" +
                         shown + (missingJudged.count > 8 ? " …" : ""))
        }
        if !missingFlashJudged.isEmpty {
            notes.append("\(missingFlashJudged.count) 个判定事件里有文件缺闪光，A4 不过：" + missingFlashJudged.prefix(8).map { "\($0.key) 缺 " + $0.files.map { "[\($0)]" }.joined(separator: " ") }.joined(separator: "、"))
        }
        if halfCount > 0 {
            notes.append("\(halfCount) 个事件的闪光离锚 click 在半秒 ±1 帧内（如 PGM 上 59.94 的路在播时闪光落在 .5 s），前后两个 click 差不多一样近，只列不判；" +
                         "含它们的最大闪光极差 \(String(format: "%.3f", allFlash)) ms、click 极差 \(String(format: "%.3f", allClick)) ms" +
                         (comparable ? "" : "；没有可判的整秒事件"))
        }
        if unanchored > 0 {
            notes.append("\(unanchored) 个事件一个文件都没配上 click（没有锚：只比闪光，不算缺 click）")
        }
        let passA4: Bool? = !(missingJudged.isEmpty && missingFlashJudged.isEmpty) ? false : (comparable ? (maxFlash <= threshold && maxClick <= threshold) : nil)
        return MultiFileAVReport(files: files.map(\.name), events: events, maxFlashSpreadMs: maxFlash, maxClickSpreadMs: maxClick,
                                 thresholdMs: threshold, passA4: passA4,
                                 halfSecondEventCount: halfCount, allEventsMaxFlashSpreadMs: allFlash, allEventsMaxClickSpreadMs: allClick,
                                 note: notes.isEmpty ? nil : notes.joined(separator: "；"), missingClickEventCount: missingJudged.count,
                                 unanchoredEventCount: unanchored, missingFlashEventCount: missingFlashJudged.count)
    }
}
