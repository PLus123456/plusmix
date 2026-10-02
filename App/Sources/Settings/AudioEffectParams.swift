// 效果链（EQ / 压缩 / 限幅）的参数模式：契约里 `EffectSlot` 的 id 与自由 JSON 参数由这里定（设计方案 §7 用苹果的
// ParametricEQ / DynamicsProcessor / PeakLimiter），键名与 SwitcherAudio.BusEffectChain 的三个 setter 一一对应，
// 音频会话接线时按这套键读（报告 §4 有说明）：
//   parametricEQ      { centerHz, q, gainDb }
//   dynamicsProcessor { thresholdDb, headroomDb, expansionRatio, attackSeconds, releaseSeconds, overallGainDb }
//   peakLimiter       { attackSeconds, decaySeconds, preGainDb }
// 一条链 = [EffectSlot]，顺序就是处理顺序（EQ 可多格，压缩 / 限幅各一格）。
// W5-C（prompt 88）接线：总线的链装进混音器三格，连续的 EQ 格合成一个 AUNBandEQ（一格最多 16 段）；q 是经典口径
// （带宽 = 半增益边频之比，BW = 2/ln2 · asinh(1/(2q)) 倍频程，q = √2 → 1 oct）。滑块范围收进引擎送进 AU 之前的钳位范围
// （SwitcherAudio.EffectParameterRanges = SDK 头文件范围 ∩ macOS 27 ParameterInfo），超范围的老值读进来就钳，界面值 = AU 值。
import Foundation
import SwitcherContracts

enum AudioEffectParams {
    static let parametricEQID = "parametricEQ"
    static let dynamicsProcessorID = "dynamicsProcessor"
    static let peakLimiterID = "peakLimiter"

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

    static func peakLimiter(attackSeconds: Double, decaySeconds: Double, preGainDb: Double, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: peakLimiterID, enabled: enabled, params: ["attackSeconds": .number(attackSeconds), "decaySeconds": .number(decaySeconds), "preGainDb": .number(preGainDb)])
    }

    /// 读一个数值参数；没有或不是数字给 nil。
    static func number(_ slot: EffectSlot, _ key: String) -> Double? {
        if case .number(let v)? = slot.params[key] { return v }
        return nil
    }
}

/// 效果编辑器滑块的范围（W5-C）：都在 SwitcherAudio.EffectParameterRanges（引擎的钳位范围）里面，AudioEffectsTests 逐条钉住。
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
    ]

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

/// 效果链编辑器的值模型：把 [EffectSlot] 摊成"最多三段 EQ + 一格压缩 + 一格限幅"，改完再收回 [EffectSlot]。
/// 没启用（且参数是默认）的格不写进链，所以空编辑器 = 空链。读进来的数值钳进 EffectEditorRanges（W5-C）。
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
    }

    var eq: [EQBand] = []
    var dynamics = Dynamics()
    var limiter = Limiter()
    /// 链里认不出 id 的格原样保留（别的会话定义的效果）。
    var others: [EffectSlot] = []

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
            case AudioEffectParams.dynamicsProcessorID:
                dynamics.present = true
                dynamics.enabled = s.enabled
                dynamics.thresholdDb = value(s, "thresholdDb", dynamics.thresholdDb, R.dynThresholdDb)
                dynamics.headroomDb = value(s, "headroomDb", dynamics.headroomDb, R.dynHeadroomDb)
                dynamics.expansionRatio = value(s, "expansionRatio", dynamics.expansionRatio, R.dynExpansionRatio)
                dynamics.attackSeconds = value(s, "attackSeconds", dynamics.attackSeconds, R.dynAttackSeconds)
                dynamics.releaseSeconds = value(s, "releaseSeconds", dynamics.releaseSeconds, R.dynReleaseSeconds)
                dynamics.overallGainDb = value(s, "overallGainDb", dynamics.overallGainDb, R.dynOverallGainDb)
            case AudioEffectParams.peakLimiterID:
                limiter.present = true
                limiter.enabled = s.enabled
                limiter.attackSeconds = value(s, "attackSeconds", limiter.attackSeconds, R.limAttackSeconds)
                limiter.decaySeconds = value(s, "decaySeconds", limiter.decaySeconds, R.limDecaySeconds)
                limiter.preGainDb = value(s, "preGainDb", limiter.preGainDb, R.limPreGainDb)
            default:
                others.append(s)
            }
        }
    }

    /// 收回成链：EQ 各段 → 压缩 → 限幅 → 其他。
    var slots: [EffectSlot] {
        var out: [EffectSlot] = eq.map { AudioEffectParams.parametricEQ(centerHz: $0.centerHz, q: $0.q, gainDb: $0.gainDb, enabled: $0.enabled) }
        if dynamics.present {
            out.append(AudioEffectParams.dynamicsProcessor(thresholdDb: dynamics.thresholdDb, headroomDb: dynamics.headroomDb, expansionRatio: dynamics.expansionRatio,
                                                           attackSeconds: dynamics.attackSeconds, releaseSeconds: dynamics.releaseSeconds,
                                                           overallGainDb: dynamics.overallGainDb, enabled: dynamics.enabled))
        }
        if limiter.present {
            out.append(AudioEffectParams.peakLimiter(attackSeconds: limiter.attackSeconds, decaySeconds: limiter.decaySeconds, preGainDb: limiter.preGainDb, enabled: limiter.enabled))
        }
        return out + others
    }
}
