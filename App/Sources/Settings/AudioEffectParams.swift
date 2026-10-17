// 效果链（EQ / 压缩 / 限幅）的参数模式：契约里 `EffectSlot` 的 id 与自由 JSON 参数由这里定（设计方案 §7 用苹果的
// ParametricEQ / DynamicsProcessor / PeakLimiter），键名与 SwitcherAudio.BusEffectChain 的三个 setter 一一对应，
// 音频会话接线时按这套键读（报告 §4 有说明）：
//   parametricEQ      { centerHz, q, gainDb }
//   dynamicsProcessor { thresholdDb, headroomDb, expansionRatio, attackSeconds, releaseSeconds, overallGainDb }
//   peakLimiter       { attackSeconds, decaySeconds, preGainDb, ceilingDb? }（ceilingDb：提案 024 顺带 (2)，0 = 默认、不写键）
//   compressor        { thresholdDb, ratio, kneeDb, attackSeconds, releaseSeconds, makeupGainDb }（提案 024 (b) 的自写压缩器，与 dynamicsProcessor 二选一占同一格）
// 一条链 = [EffectSlot]，顺序就是处理顺序（EQ 可多格，动态（压缩器 / 动态处理器二选一）/ 限幅各一格）。
// W5-C（prompt 88）接线：总线的链装进混音器三格，连续的 EQ 格合成一个 AUNBandEQ（一格最多 16 段）；q 是经典口径
// （带宽 = 半增益边频之比，BW = 2/ln2 · asinh(1/(2q)) 倍频程，q = √2 → 1 oct）。滑块范围收进引擎送进 AU 之前的钳位范围
// （SwitcherAudio.EffectParameterRanges = SDK 头文件范围 ∩ macOS 27 ParameterInfo），超范围的老值读进来就钳，界面值 = AU 值。
import Foundation
import SwitcherContracts

enum AudioEffectParams {
    static let parametricEQID = "parametricEQ"
    static let dynamicsProcessorID = "dynamicsProcessor"
    static let peakLimiterID = "peakLimiter"
    static let compressorID = "compressor"

    static func parametricEQ(centerHz: Double, q: Double, gainDb: Double, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: parametricEQID, enabled: enabled, params: ["centerHz": .number(centerHz), "q": .number(q), "gainDb": .number(gainDb)])
    }

    static func dynamicsProcessor(thresholdDb: Double, headroomDb: Double, expansionRatio: Double, attackSeconds: Double, releaseSeconds: Double,
                                  overallGainDb: Double, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: dynamicsProcessorID, enabled: enabled, params: [
            "thresholdDb": .number(thresholdDb), "headroomDb": .number(headroomDb), "expansionRatio": .number(expansionRatio),
            "attackSeconds": .number(attackSeconds), "releaseSeconds": .number(releaseSeconds), "overallGainDb": .number(overallGainDb),
        ])
    }

    /// ceilingDb = 限幅之后同一格内的输出增益（天花板，−20…0 dBFS）；0 是默认、不写键（老链原样）。
    static func peakLimiter(attackSeconds: Double, decaySeconds: Double, preGainDb: Double, ceilingDb: Double = 0, enabled: Bool = true) -> EffectSlot {
        var params: [String: JSONValue] = ["attackSeconds": .number(attackSeconds), "decaySeconds": .number(decaySeconds), "preGainDb": .number(preGainDb)]
        if ceilingDb != 0 { params["ceilingDb"] = .number(ceilingDb) }
        return EffectSlot(id: peakLimiterID, enabled: enabled, params: params)
    }

    /// 自写压缩器（提案 024 (b)，W1-D3 的 C 实现）：阈值 + 比例（n:1）+ 拐点 + 起音 / 释放 + 补偿；前瞻 0，组延迟按设计 0 帧（装格时引擎用冲激法量一次）。
    static func compressor(thresholdDb: Double, ratio: Double, kneeDb: Double, attackSeconds: Double, releaseSeconds: Double, makeupGainDb: Double,
                           enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: compressorID, enabled: enabled, params: [
            "thresholdDb": .number(thresholdDb), "ratio": .number(ratio), "kneeDb": .number(kneeDb),
            "attackSeconds": .number(attackSeconds), "releaseSeconds": .number(releaseSeconds), "makeupGainDb": .number(makeupGainDb),
        ])
    }

    /// 读一个数值参数；没有或不是数字给 nil。
    static func number(_ slot: EffectSlot, _ key: String) -> Double? {
        if case .number(let v)? = slot.params[key] { return v }
        return nil
    }
}

/// 效果编辑器滑块的范围（W5-C）：都在 SwitcherAudio.EffectParameterRanges（引擎的钳位范围）里面，AudioEffectsTests 逐条钉住。
/// 自写压缩器与限幅天花板（W5-O）不是 AU 参数，范围就是契约 / 算法接受的范围（= 引擎表，CONTRACTS.md §2.4），界面不另收窄。
/// 比引擎窄的几处是界面取的常用段：EQ 频率到 20 kHz、增益 ±24（AU −96…+24）、q 0.2…10（AU 0.18…28.9）、压缩阈值 −40…0（AU 到 +20）。
/// 以前对不上 AU 的：阈值 −60（头文件下限 −40）、压缩起音 0.1 ms（27 上报 1 ms）、限幅衰减 60 ms（27 上报 40 ms）、q 0.1（带宽超 5 oct）。
enum EffectEditorRanges {
    static let eqCenterHz: ClosedRange<Double> = 20...20_000
    static let eqQ: ClosedRange<Double> = 0.2...10
    static let eqGainDb: ClosedRange<Double> = -24...24
    static let dynThresholdDb: ClosedRange<Double> = -40...0
    static let dynHeadroomDb: ClosedRange<Double> = 0.1...40
    static let dynExpansionRatio: ClosedRange<Double> = 1...50
    static let dynAttackSeconds: ClosedRange<Double> = 0.001...0.2
    static let dynReleaseSeconds: ClosedRange<Double> = 0.01...3
    static let dynOverallGainDb: ClosedRange<Double> = -40...40
    static let limAttackSeconds: ClosedRange<Double> = 0.001...0.03
    static let limDecaySeconds: ClosedRange<Double> = 0.001...0.04
    static let limPreGainDb: ClosedRange<Double> = -40...40
    static let limCeilingDb: ClosedRange<Double> = -20...0
    static let compThresholdDb: ClosedRange<Double> = -60...0
    static let compRatio: ClosedRange<Double> = 1...20
    static let compKneeDb: ClosedRange<Double> = 0...24
    static let compAttackSeconds: ClosedRange<Double> = 0.0001...0.2
    static let compReleaseSeconds: ClosedRange<Double> = 0.01...3
    static let compMakeupGainDb: ClosedRange<Double> = 0...24

    /// (契约 id, 参数键, 界面范围) 全表。
    static let all: [(effect: String, key: String, range: ClosedRange<Double>)] = [
        (AudioEffectParams.parametricEQID, "centerHz", eqCenterHz),
        (AudioEffectParams.parametricEQID, "q", eqQ),
        (AudioEffectParams.parametricEQID, "gainDb", eqGainDb),
        (AudioEffectParams.dynamicsProcessorID, "thresholdDb", dynThresholdDb),
        (AudioEffectParams.dynamicsProcessorID, "headroomDb", dynHeadroomDb),
        (AudioEffectParams.dynamicsProcessorID, "expansionRatio", dynExpansionRatio),
        (AudioEffectParams.dynamicsProcessorID, "attackSeconds", dynAttackSeconds),
        (AudioEffectParams.dynamicsProcessorID, "releaseSeconds", dynReleaseSeconds),
        (AudioEffectParams.dynamicsProcessorID, "overallGainDb", dynOverallGainDb),
        (AudioEffectParams.peakLimiterID, "attackSeconds", limAttackSeconds),
        (AudioEffectParams.peakLimiterID, "decaySeconds", limDecaySeconds),
        (AudioEffectParams.peakLimiterID, "preGainDb", limPreGainDb),
        (AudioEffectParams.peakLimiterID, "ceilingDb", limCeilingDb),
        (AudioEffectParams.compressorID, "thresholdDb", compThresholdDb),
        (AudioEffectParams.compressorID, "ratio", compRatio),
        (AudioEffectParams.compressorID, "kneeDb", compKneeDb),
        (AudioEffectParams.compressorID, "attackSeconds", compAttackSeconds),
        (AudioEffectParams.compressorID, "releaseSeconds", compReleaseSeconds),
        (AudioEffectParams.compressorID, "makeupGainDb", compMakeupGainDb),
    ]

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

/// 效果链编辑器的值模型：把 [EffectSlot] 摊成"最多三段 EQ + 一格动态（自写压缩器 compressor / 苹果动态处理器 dynamicsProcessor 二选一）+ 一格限幅"，
/// 改完再收回 [EffectSlot]。没有的格（present = false）不写进链，所以空编辑器 = 空链。读进来的数值钳进 EffectEditorRanges（W5-C）。
struct EffectChainEditor: Hashable {
    struct EQBand: Hashable, Identifiable {
        var id = UUID()
        var enabled = true
        var centerHz: Double = 1000
        var q: Double = 1
        var gainDb: Double = 0
    }
    struct Dynamics: Hashable {
        var present = false
        var enabled = true
        var thresholdDb: Double = -20
        var headroomDb: Double = 5
        var expansionRatio: Double = 2
        var attackSeconds: Double = 0.001
        var releaseSeconds: Double = 0.05
        var overallGainDb: Double = 0
    }
    struct Limiter: Hashable {
        var present = false
        var enabled = true
        var attackSeconds: Double = 0.012
        var decaySeconds: Double = 0.024
        var preGainDb: Double = 0
        /// 天花板（限幅之后的输出增益，提案 024 顺带 (2)）：0 dBFS = 默认。
        var ceilingDb: Double = 0
    }
    /// 自写压缩器（提案 024 (b)）：默认参数 = CONTRACTS.md §2.4 的默认值。
    struct Compressor: Hashable {
        var present = false
        var enabled = true
        var thresholdDb: Double = -20
        var ratio: Double = 4
        var kneeDb: Double = 6
        var attackSeconds: Double = 0.005
        var releaseSeconds: Double = 0.1
        var makeupGainDb: Double = 0
    }
    /// 动态格用哪一种（同一格二选一，引擎每条总线 / 每路都只装一个动态格）。
    enum DynamicsKind: String, CaseIterable, Identifiable, Sendable {
        case compressor, dynamicsProcessor
        var id: String { rawValue }
    }

    var eq: [EQBand] = []
    var dynamics = Dynamics()
    var compressor = Compressor()
    var limiter = Limiter()
    /// 链里认不出 id 的格原样保留（别的会话定义的效果；第 4 段起的 EQ、API 写进来的第二个动态 / 限幅格也在这里）。
    var others: [EffectSlot] = []

    /// 读进来时每一格在链里的位置（W5-P，W4C3 第 13 条）：收回成链时按它排，API 设的顺序原样保住——改哪一格就在原位改、删了就去掉，
    /// 新加的（原来没有的 EQ 段 / 动态格 / 限幅格）放在同类后面，没有同类按"EQ → 动态 → 限幅"的位置插。原来整条按 EQ → 动态 → 限幅 → 其他重排，
    /// 第 4 段起的 EQ 与认不出的格被挪到链尾（总线上链的顺序就是处理顺序，挪出去的 EQ 还可能成了第 4 格、装不上）。
    private enum Position: Hashable {
        case eq(UUID)
        case dynamics
        case limiter
        case other(Int)
    }
    private var layout: [Position] = []

    /// 界面最多几段 EQ（≤ 一个 AUNBandEQ 格的 16 段，全在一格里）。
    static let maxEQBands = 3

    init() {}

    init(slots: [EffectSlot]) {
        typealias R = EffectEditorRanges
        /// 读一个数值并钳进界面范围；没有或不是数字用默认值。
        func value(_ s: EffectSlot, _ key: String, _ fallback: Double, _ r: ClosedRange<Double>) -> Double {
            guard let v = AudioEffectParams.number(s, key), v.isFinite else { return fallback }
            return R.clamp(v, r)
        }
        for s in slots {
            switch s.id {
            case AudioEffectParams.parametricEQID where eq.count < Self.maxEQBands:
                var b = EQBand()
                b.enabled = s.enabled
                b.centerHz = value(s, "centerHz", b.centerHz, R.eqCenterHz)
                b.q = value(s, "q", b.q, R.eqQ)
                b.gainDb = value(s, "gainDb", b.gainDb, R.eqGainDb)
                eq.append(b)
                layout.append(.eq(b.id))
            case AudioEffectParams.dynamicsProcessorID where !compressor.present && !dynamics.present:
                layout.append(.dynamics)
                dynamics.present = true
                dynamics.enabled = s.enabled
                dynamics.thresholdDb = value(s, "thresholdDb", dynamics.thresholdDb, R.dynThresholdDb)
                dynamics.headroomDb = value(s, "headroomDb", dynamics.headroomDb, R.dynHeadroomDb)
                dynamics.expansionRatio = value(s, "expansionRatio", dynamics.expansionRatio, R.dynExpansionRatio)
                dynamics.attackSeconds = value(s, "attackSeconds", dynamics.attackSeconds, R.dynAttackSeconds)
                dynamics.releaseSeconds = value(s, "releaseSeconds", dynamics.releaseSeconds, R.dynReleaseSeconds)
                dynamics.overallGainDb = value(s, "overallGainDb", dynamics.overallGainDb, R.dynOverallGainDb)
            case AudioEffectParams.compressorID where !compressor.present && !dynamics.present:
                // 链里第二个动态格（API 写进来的）落到 others 原样留着：引擎也只装第一个（W1-D3 记 ignored）
                layout.append(.dynamics)
                compressor.present = true
                compressor.enabled = s.enabled
                compressor.thresholdDb = value(s, "thresholdDb", compressor.thresholdDb, R.compThresholdDb)
                compressor.ratio = value(s, "ratio", compressor.ratio, R.compRatio)
                compressor.kneeDb = value(s, "kneeDb", compressor.kneeDb, R.compKneeDb)
                compressor.attackSeconds = value(s, "attackSeconds", compressor.attackSeconds, R.compAttackSeconds)
                compressor.releaseSeconds = value(s, "releaseSeconds", compressor.releaseSeconds, R.compReleaseSeconds)
                compressor.makeupGainDb = value(s, "makeupGainDb", compressor.makeupGainDb, R.compMakeupGainDb)
            case AudioEffectParams.peakLimiterID where !limiter.present:
                // 第二个限幅格（API 写进来的）原来会盖掉第一个的参数、第一个丢了；现在落到 others 原样留着（W4C3 第 13 条）
                layout.append(.limiter)
                limiter.present = true
                limiter.enabled = s.enabled
                limiter.attackSeconds = value(s, "attackSeconds", limiter.attackSeconds, R.limAttackSeconds)
                limiter.decaySeconds = value(s, "decaySeconds", limiter.decaySeconds, R.limDecaySeconds)
                limiter.preGainDb = value(s, "preGainDb", limiter.preGainDb, R.limPreGainDb)
                limiter.ceilingDb = value(s, "ceilingDb", limiter.ceilingDb, R.limCeilingDb)
            default:
                layout.append(.other(others.count))
                others.append(s)
            }
        }
    }

    /// 收回成链：按读进来时的位置排（layout），新加的放在同类后面；全新的编辑器 = EQ 各段 → 动态（压缩器 / 动态处理器）→ 限幅。
    var slots: [EffectSlot] {
        let eqSlot = { (b: EQBand) in AudioEffectParams.parametricEQ(centerHz: b.centerHz, q: b.q, gainDb: b.gainDb, enabled: b.enabled) }
        var dynamicsSlot: EffectSlot?
        if compressor.present {
            dynamicsSlot = AudioEffectParams.compressor(thresholdDb: compressor.thresholdDb, ratio: compressor.ratio, kneeDb: compressor.kneeDb,
                                                        attackSeconds: compressor.attackSeconds, releaseSeconds: compressor.releaseSeconds,
                                                        makeupGainDb: compressor.makeupGainDb, enabled: compressor.enabled)
        } else if dynamics.present {
            dynamicsSlot = AudioEffectParams.dynamicsProcessor(thresholdDb: dynamics.thresholdDb, headroomDb: dynamics.headroomDb, expansionRatio: dynamics.expansionRatio,
                                                               attackSeconds: dynamics.attackSeconds, releaseSeconds: dynamics.releaseSeconds,
                                                               overallGainDb: dynamics.overallGainDb, enabled: dynamics.enabled)
        }
        let limiterSlot: EffectSlot? = limiter.present
            ? AudioEffectParams.peakLimiter(attackSeconds: limiter.attackSeconds, decaySeconds: limiter.decaySeconds, preGainDb: limiter.preGainDb,
                                            ceilingDb: limiter.ceilingDb, enabled: limiter.enabled)
            : nil
        var out: [EffectSlot] = []
        var placedEQ = Set<UUID>()
        var placedDynamics = false, placedLimiter = false
        var eqEnd: Int?, dynamicsEnd: Int?   // 最后一个 EQ / 动态格之后的位置（插新格用）
        for p in layout {
            switch p {
            case .eq(let id):
                placedEQ.insert(id)
                guard let band = eq.first(where: { $0.id == id }) else { continue }   // 删了
                out.append(eqSlot(band))
                eqEnd = out.count
            case .dynamics:
                placedDynamics = true
                if let d = dynamicsSlot {
                    out.append(d)
                    dynamicsEnd = out.count
                }
            case .limiter:
                placedLimiter = true
                if let l = limiterSlot { out.append(l) }
            case .other(let k):
                if k < others.count { out.append(others[k]) }
            }
        }
        // 新加的 EQ 段：接在最后一个 EQ 后面，一个都没有就放最前
        let newBands = eq.filter { !placedEQ.contains($0.id) }.map(eqSlot)
        if !newBands.isEmpty {
            let at = eqEnd ?? 0
            out.insert(contentsOf: newBands, at: at)
            eqEnd = at + newBands.count
            if let d = dynamicsEnd, d > at { dynamicsEnd = d + newBands.count }
        }
        // 新加的动态格：EQ 后面；新加的限幅格：动态格后面，没有就 EQ 后面
        if !placedDynamics, let d = dynamicsSlot {
            let at = eqEnd ?? 0
            out.insert(d, at: at)
            dynamicsEnd = at + 1
        }
        if !placedLimiter, let l = limiterSlot {
            out.insert(l, at: dynamicsEnd ?? eqEnd ?? 0)
        }
        // 读进来时不在 layout 里的其他格（不会发生：others 只在 init 里加）——兜底接在最后，不丢
        let placedOthers = Set(layout.compactMap { if case .other(let k) = $0 { k } else { nil } })
        out += others.indices.filter { !placedOthers.contains($0) }.map { others[$0] }
        return out
    }

    /// 动态格现在是哪一种（没有 = nil）。
    var dynamicsKind: DynamicsKind? { compressor.present ? .compressor : dynamics.present ? .dynamicsProcessor : nil }

    /// 动态格换成另一种（同一格二选一，提案 024 (b)）：开关状态带过去、参数用这一种自己的，另一种从链里拿掉。
    /// 原来没有动态格：装一个旁路着的（开关仍是关，"关 = 旁路、参数留着"同一口径）。
    mutating func setDynamicsKind(_ kind: DynamicsKind) {
        guard kind != dynamicsKind else { return }
        let enabled = switch dynamicsKind {
        case .compressor?: compressor.enabled
        case .dynamicsProcessor?: dynamics.enabled
        case nil: false
        }
        switch kind {
        case .compressor:
            dynamics.present = false
            compressor.present = true
            compressor.enabled = enabled
        case .dynamicsProcessor:
            compressor.present = false
            dynamics.present = true
            dynamics.enabled = enabled
        }
    }
}
