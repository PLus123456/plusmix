// W5-C（prompt 88）：总线效果链接进了混音器（止血标签对总线撤掉、每路仍标）；效果编辑器的范围收进引擎送进 AU 之前的钳位范围
// （SwitcherAudio.EffectParameterRanges = SDK 头文件范围 ∩ macOS 27 ParameterInfo，探针见 reports/w5-audio-bus-effects.md §1）。
import XCTest
import SwitcherContracts
import SwitcherAudio
@testable import Switcher

@MainActor
final class AudioEffectsTests: XCTestCase {

    func testAudioEffects_busEffectsAppliedInputEffectsNotYet() {
        XCTAssertTrue(AudioEffectsSupport.busEffectsApplied, "W5-C 接好了四条总线的效果链")
        XCTAssertTrue(AudioEffectsSupport.inputEffectsApplied, "W1-D3（102）接好了每路两格（EQ + 动态，C 热路径）；G8b 合并时翻")
    }

    /// 界面上每个滑块的范围 ⊆ 引擎的钳位范围：界面上拖得到的值送进 AU 时不会再被钳（界面值 = AU 值）。
    func testAudioEffects_editorRangesWithinEngineClamp() {
        XCTAssertEqual(EffectEditorRanges.all.count, 19, "三种 AU 效果的 12 个参数 + 自写压缩器 6 个 + 限幅天花板（W5-O）都有界面范围")
        for (effect, key, ui) in EffectEditorRanges.all {
            guard let engine = EffectParameterRanges.range(effect: effect, key: key) else { XCTFail("\(effect).\(key) 引擎没有钳位范围"); continue }
            XCTAssertGreaterThanOrEqual(ui.lowerBound, engine.lowerBound, "\(effect).\(key)：界面 \(ui) 引擎 \(engine)")
            XCTAssertLessThanOrEqual(ui.upperBound, engine.upperBound, "\(effect).\(key)：界面 \(ui) 引擎 \(engine)")
        }
        // 收窄过的几个（以前对不上 AU：阈值 −60、压缩起音 0.1 ms、限幅衰减 60 ms、Q 0.1）
        XCTAssertEqual(EffectEditorRanges.dynThresholdDb, -40...0)
        XCTAssertEqual(EffectEditorRanges.dynAttackSeconds.lowerBound, 0.001)
        XCTAssertEqual(EffectEditorRanges.limDecaySeconds.upperBound, 0.04)
        XCTAssertEqual(EffectEditorRanges.eqQ.lowerBound, 0.2)
    }

    /// EQ 段数 ≤ 一个 AUNBandEQ 格的段数（探针：MaxNumberOfBands = 16）：界面的几段 EQ 全在一个格里。
    func testAudioEffects_eqBandLimitFitsOneNBandEQSlot() {
        XCTAssertLessThanOrEqual(EffectChainEditor.maxEQBands, EffectParameterRanges.nBandEQMaxBands)
        XCTAssertEqual(EffectChainEditor.maxEQBands, 3)
    }

    /// 老节目 / API 写进来的超范围值，编辑器读的时候钳进界面范围（滑块显示的 = 引擎送进 AU 的）；范围内的原样。
    func testAudioEffects_editorClampsOutOfRangeValuesOnLoad() {
        let slots = [
            AudioEffectParams.parametricEQ(centerHz: 30_000, q: 0.1, gainDb: 30),
            AudioEffectParams.dynamicsProcessor(thresholdDb: -60, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.0001, releaseSeconds: 0.05, overallGainDb: 0),
            AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.06, preGainDb: 50),
        ]
        let e = EffectChainEditor(slots: slots)
        XCTAssertEqual(e.eq[0].centerHz, 20_000)
        XCTAssertEqual(e.eq[0].q, 0.2)
        XCTAssertEqual(e.eq[0].gainDb, 24)
        XCTAssertEqual(e.dynamics.thresholdDb, -40)
        XCTAssertEqual(e.dynamics.attackSeconds, 0.001)
        XCTAssertEqual(e.dynamics.headroomDb, 5)
        XCTAssertEqual(e.limiter.decaySeconds, 0.04)
        XCTAssertEqual(e.limiter.preGainDb, 40)
        XCTAssertEqual(e.limiter.attackSeconds, 0.012)
        // 写回的链就是钳过的值
        let back = e.slots
        XCTAssertEqual(AudioEffectParams.number(back[1], "thresholdDb"), -40)
        XCTAssertEqual(AudioEffectParams.number(back[2], "decaySeconds"), 0.04)
        // 默认值都在范围里（新加一格不会一出来就被钳）
        let fresh = EffectChainEditor()
        XCTAssertTrue(EffectEditorRanges.eqQ.contains(EffectChainEditor.EQBand().q))
        XCTAssertTrue(EffectEditorRanges.dynThresholdDb.contains(fresh.dynamics.thresholdDb))
        XCTAssertTrue(EffectEditorRanges.dynAttackSeconds.contains(fresh.dynamics.attackSeconds))
        XCTAssertTrue(EffectEditorRanges.limDecaySeconds.contains(fresh.limiter.decaySeconds))
    }
}
