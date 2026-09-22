import Foundation
import SwitcherContracts

/// 解码自证（W1-A3）：让 frameprobe 自己认出转场合成帧，不再靠外部把拍段标成"解不出"（`--blank-ticks`）。
///
/// 判据是五样证据互相印证，任何一样不合就把整帧判成解不出（帧号 / ID / 时间戳置 nil、闪光置 false，灰度保留）：
/// 1. **齐全**：帧号行、时间戳行、ID 块三样都解得出（两行 CRC-4 都对、ID 离调色板色 ≤ 契约的 24）。
/// 2. **码字块纯度**（`blockImpurity`）：64 个块都得是纯黑（16）或纯白（235）。两路混合时同一个块的两路比特不同就落在中间，
///    Fade 中段、擦边压在块上的 Wipe 都在这里被抓住；CRC 只有 1/16 的漏网率，这一条没有。
/// 3. **ID 块四象限一致**（`idSpread`）：擦边扫过 ID 块时一半新一半旧。
/// 4. **底色一致**：中心采样区灰度 = ID 邻域条灰度 = 该输入的标称灰度（标称值取该 ID 所有候选帧灰度的众数）。
///    调色板有五对颜色的中点正好落在第三种颜色上（0 + 2 = 8、1 + 2 = 15、7 + 9 = 15、2 + 3 = 7、0 + 9 = 11），
///    光看 ID 块的颜色无论阈值多紧都躲不开；底色是独立的一票（测试标准给每路不同灰度就是为了这个）。
/// 5. **节奏**：(帧号, 时间戳) 落在该输入自己的直线上——合成源第 n 帧的时间戳 = t0 + n × T /(1 + 漂移)，
///    是一条精确的直线（`SyntheticVideoInput.Generator.content`），每路的 t0 / 帧率 / 漂移不同，直线就不同。
///    "旧 ID + 新帧号"（擦边先扫过码字行、后扫过 ID 块）在这里被抓住。两路的直线完全重合时（同 t0、同帧率、无漂移，
///    例如 g4 的 3、4 号）判不出来，但那时两路的帧号本来就一样，V4 不受影响。
///
/// 另有一项只报不判：**时间轴**（时间戳 − 1000 × pts 对该输入的中位数的偏离）。冻结的输入（时间戳不再前进）会在这里露头，
/// 但那正是 V4 要报的重复帧，判掉反而把真问题藏了，所以只计数。
public enum SelfCheck {
    /// 判据的阈值。
    public struct Options: Hashable, Sendable {
        /// 关掉自证（`--no-self-check`），回到只按契约解码的老口径。
        public var enabled = true
        /// 码字块离黑 / 白的最大容许距离（limited-range Y 电平）。40 ⇒ 混合比例在 [0.18, 0.82] 的 Fade 帧一定判掉；
        /// 第三色能被读出来的混合比例（ID 阈值 12 时）是 [0.39, 0.61]，在里面。
        public var blockImpurity = 40.0
        /// ID 块四象限之间的最大容许距离（调色板两两距离下限是 56.6）。
        public var idSpread = 12.0
        /// ID 块离最近调色板色的最大容许距离。契约的判据是 24（= 最小调色板距离的一半）；
        /// 自证用 12：第三色能被读出来的混合比例从 [0.29, 0.71] 收到 [0.39, 0.61]，两侧都在底色与纯度两条之内。
        public var idDistance = 12.0
        /// 中心 / ID 邻域 / 标称三处灰度两两之间的最大容许差（full-range 电平）。
        /// H.264 往返的灰度误差实测 ≤ 1.5（RoundTripTests），噪声底纹在这两块采样区上的标准差 < 0.2。
        public var grayTolerance = 5.0
        /// (帧号, 时间戳) 离该输入拟合直线的最大容许残差（ms）。图案里的毫秒是向下取整，理想残差在 [−1, 0]。
        public var rhythmToleranceMs = 3.0
        /// 时间轴偏离（只报不判）的门限（ms）：时间戳 − 1000 × pts 对该输入线性拟合后的残差。
        public var timelineToleranceMs = 250.0
        /// 一路输入至少要有这么多帧才拟合得出节奏；不够的整路判成解不出（第三色只在少数混合帧上出现，这一条兜底）。
        public var minimumAnchorFrames = 8
        public init() {}
    }

    /// 判掉的理由。
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// 帧号 / 时间戳 / ID 三样没齐（CRC 错或 ID 离调色板太远）。
        case incomplete
        /// 码字块不纯或 ID 块四象限不一致：画面在解码区里是两路的混合。
        case blend
        /// 底色对不上（中心 / ID 邻域 / 标称三处不一致）。
        case background
        /// (帧号, 时间戳) 不在该输入的直线上。
        case rhythm
        /// 该 ID 的帧太少，拟合不出节奏。
        case unanchored
        /// `--blank-ticks` 标掉的拍。
        case blank
    }

    /// 一路输入的节奏拟合。
    public struct InputFit: Hashable, Codable, Sendable {
        public var inputID: Int
        /// 参与拟合的帧数。
        public var frames: Int
        /// 每帧多少毫秒（= 1000 / 实际帧率）。
        public var msPerFrame: Double
        /// 直线的常数项（相对该输入第一帧的帧号 / 时间戳）。
        public var interceptMs: Double
        /// 内点的最大残差（ms）。
        public var maxResidualMs: Double
        /// 标称灰度（候选帧灰度的众数）。
        public var nominalGray: Double
        /// 按这条直线判掉的帧数。
        public var rejected: Int
        /// 时间轴偏离超门限的帧数（只报不判）。
        public var timelineOutliers: Int
        /// 时间轴偏离的最大绝对值（ms）。
        public var maxTimelineDeviationMs: Double
    }

    /// 一帧被判掉的记录（报告里列前若干条）。
    public struct Rejection: Hashable, Codable, Sendable {
        public var index: Int
        public var tick: Int64
        public var reason: Reason
        /// 判掉前解出来的 ID（有的话）。
        public var inputID: Int?
        /// 判掉前解出来的帧号（有的话）。
        public var frameNumber: UInt32?
        /// 触发的那个量（纯度 / 四象限距离 / 灰度差 / 残差 ms）。
        public var value: Double
    }

    public struct Report: Hashable, Codable, Sendable {
        public var enabled: Bool
        /// 总帧数。
        public var frames: Int
        /// 判掉的帧数。
        public var rejected: Int
        /// 按理由分的计数。
        public var byReason: [String: Int]
        /// 每路的拟合。
        public var fits: [InputFit]
        /// 判掉的帧的例子（最多 maxEvents 条）。
        public var examples: [Rejection]
        /// 例子是否被截断。
        public var truncated: Bool
    }

    /// 28 位回绕的有符号差：把 (a − b) mod 2²⁸ 映到 (−2²⁷, 2²⁷]。
    static func wrapDelta(_ a: UInt32, _ b: UInt32) -> Int64 {
        let m = Int64(TestPattern.dataMask) + 1
        return ((Int64(a) - Int64(b) + m + m / 2) % m) - m / 2
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 按五样证据把合成帧判成解不出。`readings` 与 `frames` 一一对应。
    /// - Parameter startTick: 第 0 帧的拍号（只用于报告里的拍号）。
    public static func apply(frames: [ProbeFrame], readings: [PatternProbe.Reading], options: Options,
                             startTick: Int64 = 0, maxEvents: Int = 200) -> (frames: [ProbeFrame], report: Report) {
        var out = frames
        var reasons = [Reason?](repeating: nil, count: frames.count)
        var values = [Double](repeating: 0, count: frames.count)
        guard options.enabled, frames.count == readings.count else {
            return (frames, Report(enabled: false, frames: frames.count, rejected: 0, byReason: [:], fits: [], examples: [], truncated: false))
        }

        // 1–3：逐帧的齐全 / 纯度 / 四象限 / ID 距离
        for i in frames.indices {
            let r = readings[i]
            if r.decoded.frameNumber == nil || r.decoded.hostTimeMs == nil || r.decoded.inputID == nil {
                reasons[i] = .incomplete
            } else if r.blockImpurity > options.blockImpurity {
                reasons[i] = .blend; values[i] = r.blockImpurity
            } else if r.idSpread > options.idSpread {
                reasons[i] = .blend; values[i] = r.idSpread
            } else if r.idDistance > options.idDistance {
                reasons[i] = .incomplete; values[i] = r.idDistance
            } else if abs(r.centerGray - r.cornerGray) > options.grayTolerance {
                reasons[i] = .background; values[i] = abs(r.centerGray - r.cornerGray)
            }
        }

        // 4：标称灰度（候选帧灰度的众数）——众数对少数混合帧不敏感
        var histogram: [Int: [Int: Int]] = [:]
        for i in frames.indices where reasons[i] == nil {
            histogram[readings[i].decoded.inputID!, default: [:]][Int(readings[i].centerGray.rounded()), default: 0] += 1
        }
        var nominal: [Int: Double] = [:]
        for (id, h) in histogram {
            let best = h.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!
            nominal[id] = Double(best.key)
        }
        for i in frames.indices where reasons[i] == nil {
            let r = readings[i]
            if let n = nominal[r.decoded.inputID!], abs(r.centerGray - n) > options.grayTolerance {
                reasons[i] = .background; values[i] = abs(r.centerGray - n)
            }
        }

        // 5：每路的节奏直线（帧号 → 时间戳）
        var byInput: [Int: [Int]] = [:]
        for i in frames.indices where reasons[i] == nil { byInput[readings[i].decoded.inputID!, default: []].append(i) }
        var fits: [InputFit] = []
        for id in byInput.keys.sorted() {
            let indices = byInput[id]!
            let n0 = readings[indices[0]].decoded.frameNumber!, ms0 = readings[indices[0]].decoded.hostTimeMs!
            let n = indices.map { Double(wrapDelta(readings[$0].decoded.frameNumber!, n0)) }
            let ms = indices.map { Double(wrapDelta(readings[$0].decoded.hostTimeMs!, ms0)) }
            let pts = indices.map { frames[$0].ptsSeconds }
            var fit = InputFit(inputID: id, frames: indices.count, msPerFrame: 0, interceptMs: 0, maxResidualMs: 0,
                               nominalGray: nominal[id] ?? 0, rejected: 0, timelineOutliers: 0, maxTimelineDeviationMs: 0)
            guard indices.count >= options.minimumAnchorFrames else {
                for i in indices { reasons[i] = .unanchored; values[i] = Double(indices.count) }
                fit.rejected = indices.count
                fits.append(fit)
                continue
            }
            // 斜率：先用间隔一半序列长度的点对取中位数（量化误差 ≤ 1 ms / Δn，离群点不影响），再在内点上最小二乘精修
            let half = indices.count / 2
            var slopes: [Double] = []
            for j in 0..<half where n[j + half] != n[j] { slopes.append((ms[j + half] - ms[j]) / (n[j + half] - n[j])) }
            var slope = slopes.isEmpty ? 0 : median(slopes)
            var intercept = median(zip(ms, n).map { $0 - slope * $1 })
            if slope != 0 {
                let residual = zip(ms, n).map { $0 - (intercept + slope * $1) }
                let cut = max(options.rhythmToleranceMs, 4 * median(residual.map(abs)) + 2)
                let inliers = residual.indices.filter { abs(residual[$0]) <= cut }
                if inliers.count >= 2 {
                    let f = FrameAnalysis.linearFit(x: inliers.map { n[$0] }, y: inliers.map { ms[$0] })
                    if f.slope != 0 { slope = f.slope; intercept = f.intercept }
                }
            }
            fit.msPerFrame = slope
            fit.interceptMs = intercept
            var survivors: [Int] = []
            for (k, i) in indices.enumerated() {
                let residual = ms[k] - (intercept + slope * n[k])
                if abs(residual) > options.rhythmToleranceMs {
                    reasons[i] = .rhythm; values[i] = residual
                    fit.rejected += 1
                } else {
                    fit.maxResidualMs = max(fit.maxResidualMs, abs(residual))
                    survivors.append(k)
                }
            }
            // 时间轴（只报不判）：u = 时间戳 − 1000 × pts，也就是"这一帧比拍点早生成多久"。
            // 对 pts 做一次最小二乘（时钟漂移让 u 线性走，±100 ppm 的路在 10 分钟里就走 60 ms，那不是异常），看残差。
            // 只拿过了节奏这一关的帧来拟合，乱码的时间戳进不来。冻结的输入（时间戳不再前进）会在这里露头——
            // 但那正是 V4 要报的重复帧，判掉反而把真问题藏了，所以只计数。
            if survivors.count >= 2 {
                let u = survivors.map { ms[$0] - 1000 * pts[$0] }
                let x = survivors.map { pts[$0] }
                let line = FrameAnalysis.linearFit(x: x, y: u)
                for (k, v) in zip(x, u) {
                    let deviation = abs(v - (line.intercept + line.slope * k))
                    fit.maxTimelineDeviationMs = max(fit.maxTimelineDeviationMs, deviation)
                    if deviation > options.timelineToleranceMs { fit.timelineOutliers += 1 }
                }
            }
            fits.append(fit)
        }

        // 落实
        var byReason: [String: Int] = [:]
        var examples: [Rejection] = []
        var truncated = false
        var rejected = 0
        for i in frames.indices {
            guard let reason = reasons[i] else { continue }
            rejected += 1
            byReason[reason.rawValue, default: 0] += 1
            if examples.count < maxEvents {
                examples.append(Rejection(index: frames[i].index, tick: startTick + Int64(frames[i].index), reason: reason,
                                          inputID: readings[i].decoded.inputID, frameNumber: readings[i].decoded.frameNumber, value: values[i]))
            } else {
                truncated = true
            }
            // 闪光块自己是纯黑 / 纯白就保留闪光位：两路同时闪（合成源共用 t0）时它没被混脏，A2 的配对不该因为转场丢掉；
            // 混在中间的（两路闪光状态不同）才置 false。
            let flash = readings[i].flashImpurity <= options.blockImpurity && frames[i].flash
            out[i] = ProbeFrame(index: frames[i].index, ptsSeconds: frames[i].ptsSeconds, frameNumber: nil, inputID: nil,
                                genTimeMs: nil, flash: flash, gray: frames[i].gray)
        }
        let report = Report(enabled: true, frames: frames.count, rejected: rejected, byReason: byReason,
                            fits: fits.sorted { $0.inputID < $1.inputID }, examples: examples, truncated: truncated)
        return (out, report)
    }
}
