import Foundation
import SwitcherContracts

/// Wipe / Zoom 的进度曲线（V7，W1-A3）。Fade 看中心灰度就够了（`FrameAnalysis.fade`），这两种不行：
/// Wipe 的中心灰度在擦边过中心时翻转，Zoom 的中心灰度从第一帧起就是新画面的。
///
/// 量法（与 W3-B 渲染侧同口径：第 s + k 拍 progress = k / D，偏差换算成帧 ≤ 1）：
/// - **Wipe**：沿擦除方向找灰度阶跃的位置，软边取 50% 点（渲染器的软边是 `1 − smoothstep(e − s/2, e + s/2, f)`，
///   在 f = e 处正好 0.5，所以 50% 点就是擦边位置，与软边宽度无关）。进度 = 位置 / 画面尺寸。
/// - **Zoom**：中心行带上新画面的宽度 / 画面宽（新画面绕中心按进度缩放，`PixelRect.scaled`）。
///
/// 每一拍的剖面先用转场两端的两帧归一化：ν = (这一拍 − 第 s 拍) / (第 s + D 拍 − 第 s 拍)。
/// 这样不用知道两路的标称灰度，压在取样带上的叠加（PiP、边框）也会被约掉——它们在整段转场里不动，
/// 分子分母里各出现一次。对比度不够的位置（两端差 < `minimumContrast`）直接不参与。
extension FrameAnalysis {
    /// 曲线上的一点。
    public struct CurveSample: Hashable, Codable, Sendable {
        public var index: Int
        public var tick: Int64
        /// 量出来的进度（新画面盖住旧画面的比例）。
        public var progress: Double
        /// 契约的线性曲线 k / D。
        public var expectedProgress: Double
        /// |progress × D − k|：偏离线性曲线的帧数。
        public var deviationFrames: Double
        /// 参与这一拍判定的取样位置数（对比度够的列 / 行）。
        public var usable: Int
    }

    /// 一次 Wipe / Zoom 的曲线。
    public struct TransitionCurve: Hashable, Codable, Sendable {
        /// "wipe" / "zoom"。
        public var kind: String
        /// Wipe 的方向。
        public var direction: String?
        /// 发命令的拍 s。
        public var startTick: Int64
        /// 时长 D（拍）。
        public var durationTicks: Int
        /// 第 s + 1 … s + D − 1 拍每拍一个样本。
        public var samples: [CurveSample]
        /// 与线性曲线的最大偏差（帧）。
        public var maxDeviationFrames: Double
        /// 最大进度误差（0–1）。
        public var maxProgressError: Double
        /// 进度是否单调不减。
        public var monotonic: Bool
        /// V7：曲线误差 ≤ 1 帧且有样本。
        public var passV7: Bool
        /// 量不出来时的说明。
        public var note: String?
    }

    /// 两端归一化时要求的最小对比度（full-range 灰度电平）。
    public static let curveMinimumContrast = 8.0

    /// Wipe 的进度曲线。`profiles` 的键是帧序号（`ProbeFrame.index`）。
    public static func wipeCurve(frames: [ProbeFrame], profiles: [Int: ScanProfile], direction: WipeDirection,
                                 at commandTick: Int64, durationTicks d: Int, startTick: Int64 = 0, fps: Double = 60,
                                 minimumContrast: Double = curveMinimumContrast) -> TransitionCurve {
        curve(kind: "wipe", direction: direction.rawValue, frames: frames, profiles: profiles, at: commandTick, durationTicks: d,
              startTick: startTick, fps: fps) { p0, p1, pk in
            measureWipe(direction: direction, p0: p0, p1: p1, pk: pk, minimumContrast: minimumContrast)
        }
    }

    /// Zoom 的进度曲线。
    public static func zoomCurve(frames: [ProbeFrame], profiles: [Int: ScanProfile], at commandTick: Int64, durationTicks d: Int,
                                 startTick: Int64 = 0, fps: Double = 60, minimumContrast: Double = curveMinimumContrast) -> TransitionCurve {
        curve(kind: "zoom", direction: nil, frames: frames, profiles: profiles, at: commandTick, durationTicks: d,
              startTick: startTick, fps: fps) { p0, p1, pk in
            measureZoom(p0: p0, p1: p1, pk: pk, minimumContrast: minimumContrast)
        }
    }

    // MARK: - 实现

    static func curve(kind: String, direction: String?, frames: [ProbeFrame], profiles: [Int: ScanProfile],
                      at commandTick: Int64, durationTicks d: Int, startTick: Int64, fps: Double,
                      measure: (ScanProfile, ScanProfile, ScanProfile) -> (progress: Double, usable: Int)?) -> TransitionCurve {
        var report = TransitionCurve(kind: kind, direction: direction, startTick: commandTick, durationTicks: d, samples: [],
                                     maxDeviationFrames: 0, maxProgressError: 0, monotonic: true, passV7: false, note: nil)
        guard d >= 2 else { report.note = "时长要 ≥ 2 拍"; return report }
        var indexByTick: [Int64: Int] = [:]
        for f in frames { indexByTick[startTick + (fps > 0 ? Int64((f.ptsSeconds * fps).rounded()) : Int64(f.index))] = f.index }
        guard let i0 = indexByTick[commandTick], let p0 = profiles[i0] else {
            report.note = "第 \(commandTick) 拍（progress 0 的纯旧画面）没有剖面"; return report
        }
        guard let i1 = indexByTick[commandTick + Int64(d)], let p1 = profiles[i1] else {
            report.note = "第 \(commandTick + Int64(d)) 拍（转场完成的纯新画面）没有剖面"; return report
        }
        var last = -1.0
        for k in 1..<d {
            guard let ik = indexByTick[commandTick + Int64(k)], let pk = profiles[ik] else { continue }
            guard let m = measure(p0, p1, pk) else { continue }
            let expected = Double(k) / Double(d)
            let deviation = abs(m.progress - expected) * Double(d)
            report.samples.append(CurveSample(index: ik, tick: commandTick + Int64(k), progress: m.progress,
                                              expectedProgress: expected, deviationFrames: deviation, usable: m.usable))
            report.maxDeviationFrames = max(report.maxDeviationFrames, deviation)
            report.maxProgressError = max(report.maxProgressError, abs(m.progress - expected))
            if m.progress < last - 1e-9 { report.monotonic = false }
            last = m.progress
        }
        if report.samples.isEmpty && report.note == nil { report.note = "转场中间拍一帧剖面都没有" }
        if report.samples.count < d - 1 && report.note == nil { report.note = "只量到 \(report.samples.count) / \(d - 1) 拍" }
        report.passV7 = !report.samples.isEmpty && report.maxDeviationFrames <= v7MaximumDeviationFrames
        return report
    }

    /// 归一化：ν = (pk − p0) / (p1 − p0)，两端差不够大的位置不参与（nil）。
    /// 门限是 `max(minimumContrast, 0.35 × 中位对比度)`：被 PiP 盖住大半个取样带的列，两端差只剩三分之一，
    /// ν 的噪声被放大到 ±0.2，正好骑在判据上（g4 第 9300 拍那次 Wipe 的第 270 列就是这样，实测偏差 19.7 帧）。
    static func normalize(_ a0: [Double], _ a1: [Double], _ ak: [Double], _ minimumContrast: Double) -> [Double?] {
        let n = min(a0.count, min(a1.count, ak.count))
        let spans = (0..<n).map { abs(a1[$0] - a0[$0]) }
        let sorted = spans.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let threshold = max(minimumContrast, 0.35 * median)
        return (0..<n).map { i in
            let span = a1[i] - a0[i]
            return abs(span) >= threshold ? (ak[i] - a0[i]) / span : nil
        }
    }

    /// 一条边的位置。
    struct Edge {
        /// 连续坐标（像素）。
        var position: Double
        /// 这条边两侧最近的可用取样点之间隔了多少像素：1 = 紧挨着（可信），大 = 边落在被遮住的一段里（不可信）。
        var gap: Int
    }

    /// 找 ν 从 1 掉到 0 的那条边（低位是新画面那边）。
    /// 判据用最大似然的阶跃位置：让 Σ_{左}(2ν − 1) 最大的切点。等价于"左边尽量都是新、右边尽量都是旧"，
    /// 对个别噪声大的列免疫（单点穿过 0.5 不会把边拽过去），软边时因为 smoothstep 对称，最大值正好落在 50% 点那一格。
    static func fallingEdge(_ nu: [Double?]) -> Edge? {
        let points = nu.indices.compactMap { i in nu[i].map { (index: i, value: $0) } }
        guard points.count >= 8 else { return nil }
        var sum = 0.0, best = 0.0, cut = 0
        for (j, p) in points.enumerated() {
            sum += 2 * p.value - 1
            if sum > best { best = sum; cut = j + 1 }
        }
        if cut == 0 { return Edge(position: Double(points[0].index), gap: 1) }             // 全是旧画面
        if cut == points.count { return Edge(position: Double(points[cut - 1].index + 1), gap: 1) }  // 全是新画面
        let l = points[cut - 1], r = points[cut]
        let t = l.value > r.value ? min(max((l.value - 0.5) / (l.value - r.value), 0), 1) : 0.5
        return Edge(position: Double(l.index) + 0.5 + t * Double(r.index - l.index), gap: r.index - l.index)
    }

    /// 找 ν 从 0 升到 1 的那条边（高位是新画面那边）。
    static func risingEdge(_ nu: [Double?]) -> Edge? {
        guard var e = fallingEdge(nu.reversed().map { $0 }) else { return nil }
        e.position = Double(nu.count) - e.position
        return e
    }

    static func measureWipe(direction: WipeDirection, p0: ScanProfile, p1: ScanProfile, pk: ScanProfile,
                            minimumContrast: Double) -> (progress: Double, usable: Int)? {
        switch direction {
        case .leftToRight, .rightToLeft:
            let nu = normalize(p0.columns, p1.columns, pk.columns, minimumContrast)
            let oriented = direction == .leftToRight ? nu : nu.reversed().map { $0 }
            guard let e = fallingEdge(oriented) else { return nil }
            return (min(1, max(0, e.position / Double(pk.width))), oriented.compactMap { $0 }.count)
        case .topToBottom, .bottomToTop:
            let nu = normalize(p0.rows, p1.rows, pk.rows, minimumContrast)
            let oriented = direction == .topToBottom ? nu : nu.reversed().map { $0 }
            guard let e = fallingEdge(oriented) else { return nil }
            return (min(1, max(0, e.position / Double(pk.height))), oriented.compactMap { $0 }.count)
        case .diagonal:
            // f = (x / w + y / h) / 2：列剖面上是斜坡不是阶跃，改用取样窗口里的覆盖面积反推擦边位置。
            let nu = normalize(p0.columns, p1.columns, pk.columns, minimumContrast)
            let values = nu.compactMap { $0 }
            guard values.count >= 4 else { return nil }
            let coverage = values.reduce(0, +) / Double(values.count)
            return (diagonalEdge(coverage: coverage, profile: pk), values.count)
        }
    }

    /// 对角 Wipe：在取样窗口（列剖面的行带 × 全宽）里，遮罩覆盖的面积占比与擦边位置 e 的关系是分段二次的，
    /// 这里直接在采样网格上二分反推（窗口不是整幅画面，闭式解不好写，二分 40 次就到 1e-12）。
    static func diagonalEdge(coverage: Double, profile: ScanProfile) -> Double {
        let w = profile.width, h = profile.height
        let y0 = profile.columnBand.lowerBound, y1 = profile.columnBand.upperBound
        func predicted(_ e: Double) -> Double {
            var inside = 0, total = 0
            var y = y0
            while y <= y1 {
                let py = (Double(y) + 0.5) / Double(h)
                var x = 0
                while x < w {
                    let f = ((Double(x) + 0.5) / Double(w) + py) / 2
                    if f < e { inside += 1 }
                    total += 1
                    x += 4
                }
                y += 4
            }
            return total > 0 ? Double(inside) / Double(total) : 0
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if predicted(mid) < coverage { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// 边落在"被遮住的一段"里就不信这条边：两侧最近的可用取样点隔得比这还远（像素）就算遮住了。
    static let edgeMaximumGap = 8

    static func measureZoom(p0: ScanProfile, p1: ScanProfile, pk: ScanProfile, minimumContrast: Double) -> (progress: Double, usable: Int)? {
        let nu = normalize(p0.centerColumns, p1.centerColumns, pk.centerColumns, minimumContrast)
        let usable = nu.compactMap { $0 }.count
        guard usable >= 8 else { return nil }
        // 新画面是居中的一块：左边是 ν 从 0 升到 1，右边是从 1 掉回 0。
        // 哪条边落在被 PiP 盖住的一段里（gap 太大）就只用另一条边，按"居中"翻倍
        // （g4 第 9600 拍那次 Zoom：Overlay 3 正好压在中心行带的左半边，左边界从第 12 拍起就在它下面）。
        // 两条边各在自己那半边找：整条剖面是 0…0 1…1 0…0，不是单调的阶跃，
        // 最大似然的切点在半边之内才有定义（左半边是升、右半边是降）。
        let half = pk.width / 2
        let center = Double(pk.width) / 2
        var left = risingEdge(Array(nu[0..<half]))
        var right = fallingEdge(Array(nu[half...]))
        right?.position += center
        if left?.position ?? 0 >= center - 0.5 { left = nil }     // 左半边全是旧画面 → 这条边没落在这半边
        if (right?.position ?? Double(pk.width)) <= center + 0.5 { right = nil }
        let leftOK = (left?.gap ?? .max) <= edgeMaximumGap, rightOK = (right?.gap ?? .max) <= edgeMaximumGap
        let width: Double
        switch (leftOK, rightOK) {
        case (true, true): width = right!.position - left!.position
        case (true, false): width = 2 * (center - left!.position)
        case (false, true): width = 2 * (right!.position - center)
        case (false, false): return nil
        }
        return (min(1, max(0, width / Double(pk.width))), usable)
    }
}
