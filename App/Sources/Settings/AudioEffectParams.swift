// 效果链（EQ / 压缩 / 限幅）的参数模式：契约里 `EffectSlot` 的 id 与自由 JSON 参数由这里定（设计方案 §7 用苹果的
// ParametricEQ / DynamicsProcessor / PeakLimiter），键名与 SwitcherAudio.BusEffectChain 的三个 setter 一一对应，
// 音频会话接线时按这套键读（报告 §4 有说明）：
//   parametricEQ      { centerHz, q, gainDb }
//   dynamicsProcessor { thresholdDb, headroomDb, expansionRatio, attackSeconds, releaseSeconds, overallGainDb }
//   peakLimiter       { attackSeconds, decaySeconds, preGainDb }
// 一条链 = [EffectSlot]，顺序就是处理顺序（EQ 可多格，压缩 / 限幅各一格）。
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

/// 效果链编辑器的值模型：把 [EffectSlot] 摊成"最多三段 EQ + 一格压缩 + 一格限幅"，改完再收回 [EffectSlot]。
/// 没启用（且参数是默认）的格不写进链，所以空编辑器 = 空链。
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

    static let maxEQBands = 3

    init() {}

    init(slots: [EffectSlot]) {
        for s in slots {
            switch s.id {
            case AudioEffectParams.parametricEQID where eq.count < Self.maxEQBands:
                var b = EQBand()
                b.enabled = s.enabled
                b.centerHz = AudioEffectParams.number(s, "centerHz") ?? b.centerHz
                b.q = AudioEffectParams.number(s, "q") ?? b.q
                b.gainDb = AudioEffectParams.number(s, "gainDb") ?? b.gainDb
                eq.append(b)
            case AudioEffectParams.dynamicsProcessorID:
                dynamics.present = true
                dynamics.enabled = s.enabled
                dynamics.thresholdDb = AudioEffectParams.number(s, "thresholdDb") ?? dynamics.thresholdDb
                dynamics.headroomDb = AudioEffectParams.number(s, "headroomDb") ?? dynamics.headroomDb
                dynamics.expansionRatio = AudioEffectParams.number(s, "expansionRatio") ?? dynamics.expansionRatio
                dynamics.attackSeconds = AudioEffectParams.number(s, "attackSeconds") ?? dynamics.attackSeconds
                dynamics.releaseSeconds = AudioEffectParams.number(s, "releaseSeconds") ?? dynamics.releaseSeconds
                dynamics.overallGainDb = AudioEffectParams.number(s, "overallGainDb") ?? dynamics.overallGainDb
            case AudioEffectParams.peakLimiterID:
                limiter.present = true
                limiter.enabled = s.enabled
                limiter.attackSeconds = AudioEffectParams.number(s, "attackSeconds") ?? limiter.attackSeconds
                limiter.decaySeconds = AudioEffectParams.number(s, "decaySeconds") ?? limiter.decaySeconds
                limiter.preGainDb = AudioEffectParams.number(s, "preGainDb") ?? limiter.preGainDb
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
