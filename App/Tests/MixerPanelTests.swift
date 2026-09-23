// W3-E 交付第 4 条：调音台完整——每路条子（表、推子、静音、独听、声像、总线送出）、四总线、AFV、监听选择（PFL / AFL）、效果链。
// 条子的表读 AudioEngineStatus（50 ms，与 Stats 同源 AudioMixer.meters）；读数文字 / A1 仍从 Stats 来。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class MixerPanelTests: XCTestCase {
    func testMixer_stripsMetersAndCommands() throws {
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.addInput(config: AppTest.syntheticConfig(number: 2)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        let panel = wc.mixerPanel
        XCTAssertTrue(AppTest.waitUntil(3) { panel.model.state.inputs.count == 2 }, "条子应跟快照")
        XCTAssertEqual(panel.model.inputNumbers, [1, 2])

        // 表：1 号（1 kHz −20 dBFS）有电平，2 号（无音频）没有；Master 表也有
        XCTAssertTrue(AppTest.waitUntil(8) { (panel.meters.inputPeakDb[1]?.max() ?? -200) > -40 }, "1 号条子的表应有读数：\(String(describing: panel.meters.inputPeakDb[1]))")
        XCTAssertTrue(AppTest.waitUntil(3) { (panel.meters.busPeakDb[.master]?.max() ?? -200) > -40 }, "Master 表应有读数")
        XCTAssertNil(panel.meters.inputPeakDb[2], "没有音频环的路没有读数")
        XCTAssertTrue(AppTest.waitUntil(3) { panel.displayedPeak != "−∞ dBFS" }, "读数文字（Stats）：\(panel.displayedPeak)")
        XCTAssertNotNil(panel.masterPeakDb)

        // 每路条子的动作 → 命令 → 快照
        panel.model.setInputGain(1, dB: -6)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.gainDb == -6 }, "推子 → audioGain")
        panel.model.setMute(1, on: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.muted == true }, "静音 → mute")
        panel.model.setMute(1, on: false)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.muted == false })
        panel.model.setSolo(1, on: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.solo == true }, "独听 → setInputSettings")
        panel.model.setPan(1, value: -0.5)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.pan == -0.5 }, "声像")
        panel.model.setRouting(1, bus: .busA, on: true)
        panel.model.setRouting(1, bus: .master, on: false)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.routing == BusRouting(master: false, busA: true, busB: false, headphones: false) }, "总线送出")
        panel.model.setRouting(1, bus: .master, on: true)
        panel.model.setDelay(1, ms: 250)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.delayMs == 250 }, "延迟补偿")
        panel.model.setDelay(1, ms: 9999)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.delayMs == 500 }, "超范围由 reducer 钳到 500")
        panel.model.setInputEffects(1, [AudioEffectParams.dynamicsProcessor(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)])
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.effects.first?.id == AudioEffectParams.dynamicsProcessorID }, "每路效果链")

        // 四总线
        panel.model.setBusGain(.busB, dB: -3)
        panel.model.setBusMute(.headphones, on: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.buses[Bus.busB.rawValue].gainDb == -3 && session.state.audio.buses[Bus.headphones.rawValue].muted }, "总线推子 / 静音")
        panel.model.setBusGain(.master, dB: -12)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.buses[0].gainDb == -12 })
        XCTAssertEqual(panel.displayedGain, "-12.0 dB")

        // AFV：开 → 非 PGM 的 2 号门控为 0（AudioEngineStatus.afvGain 经 meters 透出）
        panel.model.setAFV(on: true)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.audio.afv })
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.status.afv })

        // 监听：PFL（提案 012 落地后走 setMonitorMode，不再 loadShow 整体替换）；输入 / PGM 不变
        panel.model.setMonitorMode(.pfl)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.monitorMode == .pfl }, "监听点应变成 PFL")
        XCTAssertEqual(session.state.inputs.count, 2)
        XCTAssertEqual(session.state.program, 1)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.status.monitorMode == .pfl }, "音频引擎应跟着换监听点")
        XCTAssertEqual(session.inputs.runtimeState(of: 1), .live, "改监听方式不重建输入")

        // 总线效果链（同样一条命令，提案 012）
        panel.model.setBusEffects(.master, [AudioEffectParams.peakLimiter(attackSeconds: 0.01, decaySeconds: 0.02, preGainDb: 1)])
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.first?.id == AudioEffectParams.peakLimiterID })
        XCTAssertEqual(AudioEffectParams.number(session.state.audio.buses[0].effects[0], "preGainDb"), 1)

        // FTB → Master 表落到 −∞
        session.send(.ftb(on: true))
        XCTAssertTrue(AppTest.waitUntil(4) { panel.displayedPeak == "−∞ dBFS" }, "FTB 后读数应 −∞：\(panel.displayedPeak)")
        session.send(.ftb(on: false))
        let a = session.stats!.audio
        print("调音台：A1 \(a.dropouts) / \(a.underruns) / \(a.discontinuities)；表 \(panel.meters.inputPeakDb)")
        XCTAssertEqual(a.dropouts, 0)
    }

    /// 每路 AFV（用户 2026-09-22 批，P3 落地 InputAudioSettings.afv；W3-E2 交付第 6 条）：条子上"跟随视频"开关（默认开）走 setInputSettings；
    /// 关掉某路后 PGM 切走，AudioEngineStatus 里该路 afvGain 仍为 1（看数，不听声）；跟随视频的路不在 PGM 就是 0。全局 AFV 开关不变。
    /// 条子上的门控显示读同一份 afvGain（dB）：afv = false 的路恒为 0 dB。
    func testMixer_perInputAFVToggle_gateStaysUnityAfterProgramCutsAway() throws {
        let session = try AppTest.freshSession()
        for n in 1...3 { session.send(.addInput(config: AppTest.syntheticConfig(number: n, audio: true))) }
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(8) { (1...3).allSatisfy { session.inputs.runtimeState(of: $0) == .live } && session.audio.registeredInputs == [1, 2, 3] },
                      "三路带音频的合成源应 live 并注册：\(session.audio.registeredInputs)")
        let panel = AppTest.controller.windowController.mixerPanel
        XCTAssertTrue(AppTest.waitUntil(2) { panel.model.state.inputs.count == 3 })
        XCTAssertTrue(session.state.inputs.allSatisfy { $0.settings.audio.afv }, "默认跟随视频")
        panel.model.setAFV(on: true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.audio.status.afv }, "全局 AFV 开")

        panel.model.setInputAFV(1, on: false)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.input(1)?.settings.audio.afv == false }, "条子开关 → setInputSettings")
        XCTAssertTrue(session.state.audio.afv, "全局开关不变")
        session.send(.cut)   // PGM 1 → 2
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 2 })
        func gain(_ n: Int) -> Float? { session.audio.status.inputs.first { $0.number == n && !$0.removing }?.afvGain }
        XCTAssertTrue(AppTest.waitUntil(4) { gain(3) == 0 && gain(2) == 1 }, "跟随视频的 3 号不在 PGM 应被门控到 0、PGM 上的 2 号为 1：\(String(describing: gain(3))) / \(String(describing: gain(2)))")
        XCTAssertEqual(gain(1), 1, "1 号不跟随视频：PGM 切走后门控仍为 1")
        XCTAssertTrue(AppTest.waitUntil(2) { panel.meters.afvGain[1] == 1 && panel.meters.afvGain[3] == 0 }, "条子读同一份 AudioEngineStatus：\(panel.meters.afvGain)")
        XCTAssertEqual(MixerModel.afvGateText(globalAFV: true, gain: panel.meters.afvGain[1]), "AFV 0 dB")
        XCTAssertEqual(MixerModel.afvGateText(globalAFV: true, gain: panel.meters.afvGain[3]), "AFV −∞ dB")
        XCTAssertEqual(MixerModel.afvGateText(globalAFV: false, gain: 1), "AFV 关")

        // 再打开：1 号不在 PGM → 门控回到 0
        panel.model.setInputAFV(1, on: true)
        XCTAssertTrue(AppTest.waitUntil(4) { gain(1) == 0 }, "1 号重新跟随视频、不在 PGM → 0：\(String(describing: gain(1)))")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    /// 效果参数的键名与 SwitcherAudio.BusEffectChain 的 setter 一一对应（W1-D 接线时照这个读）。
    func testMixer_effectParamsSchema() {
        let eq = AudioEffectParams.parametricEQ(centerHz: 1000, q: 1.5, gainDb: -3)
        XCTAssertEqual(eq.id, "parametricEQ")
        XCTAssertEqual(Set(eq.params.keys), ["centerHz", "q", "gainDb"])
        let dyn = AudioEffectParams.dynamicsProcessor(thresholdDb: -20, headroomDb: 5, expansionRatio: 2, attackSeconds: 0.001, releaseSeconds: 0.05, overallGainDb: 0)
        XCTAssertEqual(dyn.id, "dynamicsProcessor")
        XCTAssertEqual(Set(dyn.params.keys), ["thresholdDb", "headroomDb", "expansionRatio", "attackSeconds", "releaseSeconds", "overallGainDb"])
        let lim = AudioEffectParams.peakLimiter(attackSeconds: 0.012, decaySeconds: 0.024, preGainDb: 0)
        XCTAssertEqual(lim.id, "peakLimiter")
        XCTAssertEqual(Set(lim.params.keys), ["attackSeconds", "decaySeconds", "preGainDb"])
        XCTAssertEqual(AudioEffectParams.number(eq, "q"), 1.5)
        XCTAssertNil(AudioEffectParams.number(eq, "nope"))
        // 编辑器模型：从一条链读出三格，改一格再写回
        var chain = EffectChainEditor(slots: [eq, dyn, lim])
        XCTAssertEqual(chain.eq.count, 1)
        XCTAssertTrue(chain.dynamics.enabled)
        chain.limiter.preGainDb = 2
        chain.limiter.enabled = false
        let slots = chain.slots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(AudioEffectParams.number(slots[2], "preGainDb"), 2)
        XCTAssertFalse(slots[2].enabled)
        let empty = EffectChainEditor(slots: [])
        XCTAssertEqual(empty.slots, [], "什么都没开就是空链")
    }
}
