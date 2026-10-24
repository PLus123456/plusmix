import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 提案 030（用户 2026-10-17 批，P5-4 / prompt 115）：`Stats.audio.effects` 由 `AudioEngine.audioCounters` 在出 Stats 行时从 `AudioEngineStatus` 拷（铁律 4：
/// App 音频设置窗的"延迟自测"读的也是这份状态）。buses = 四条总线总是列（含耳机总线，G10 胶水 ①；没装效果 = 0）；inputs 只列装了效果的路；
/// measured_latency_ms 只在链里有自写压缩器时写。
final class EffectsLatencyStatsTests: XCTestCase {
    typealias FX = BusEffectsTests
    typealias E = Stats.AudioCounters.EffectsLatency

    private func setInputEffects(_ rig: EngineRig, _ number: Int, _ effects: [EffectSlot]) async {
        var s = (await rig.sm.state).input(number)?.settings ?? InputSettings()
        s.effects = effects
        _ = await rig.sm.apply(.setInputSettings(input: number, settings: s))
    }

    private func ms(_ frames: Int) -> Double { Double(frames) / Double(AudioFormat.sampleRate) * 1000 }

    func test030_audioCountersEffects_masterLimiterInputEQ_copiedFromStatus_unlistedInputsAbsent() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        for n in 1...4 { try rig.addSource(number: n) }
        await rig.run(seconds: 0.5)

        // 没装任何效果：四条总线都列（含耳机总线，G10 胶水 ①）、延迟 0、没有 measured；inputs 空
        var c = rig.engine.audioCounters
        XCTAssertEqual(c.effects.buses.map(\.bus), ["master", "busA", "busB", "headphones"], "Bus.allCases 的顺序，耳机总线也列（用户 2026-10-18 裁定 #1）")
        XCTAssertEqual(c.effects.buses.map(\.bus), E.listedBuses.map(\.name), "填数与契约的 listedBuses 同一张表（P5-5 / prompt 123 把常量改成四条）")
        XCTAssertEqual(c.effects.buses, Bus.allCases.map { E.BusLatency(bus: $0.name, latencyMs: 0) })
        XCTAssertEqual(c.effects.inputs, [:])

        // Master 一格限幅（起音 12 ms）、Bus A 一格自写压缩器；输入 2 一格 EQ、输入 3 动态格 = 压缩器、输入 4 动态格 = DynamicsProcessor；输入 1 不装
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [FX.limiter(attackSeconds: 0.012)]))
        _ = await rig.sm.apply(.setBusEffects(bus: .busA, effects: [InputEffectsIntegrationTests.compressor(thresholdDb: 0)]))
        _ = await rig.sm.apply(.setBusEffects(bus: .headphones, effects: [FX.limiter(attackSeconds: 0.012)]))   // 调音台耳机条的"效果"
        await setInputEffects(rig, 2, [FX.eq(1000, gainDb: 3)])
        await setInputEffects(rig, 3, [InputEffectsIntegrationTests.compressor(thresholdDb: 0)])
        await setInputEffects(rig, 4, [FX.dynamics(thresholdDb: 0, headroomDb: 5)])
        await rig.run(seconds: 0.5)

        c = rig.engine.audioCounters
        let st = rig.engine.status
        func busStatus(_ b: Bus) -> AudioEngineStatus.BusEffects { st.buses.first { $0.bus == b }!.effects }
        func inputStatus(_ n: Int) -> AudioEngineStatus.InputEffects { st.inputs.first { $0.number == n }!.effects }
        print("[030] Master \(busStatus(.master).latencyFrames) 帧、Bus A \(busStatus(.busA).latencyFrames) 帧（实测 \(busStatus(.busA).compressorMeasuredLatencyFrames.map(String.init) ?? "—")）；"
              + "输入 2/3/4 = \(inputStatus(2).latencyFrames) / \(inputStatus(3).latencyFrames) / \(inputStatus(4).latencyFrames) 帧 → \(c.effects)")

        // 总线：latency_ms = status.latencyFrames / 采样率 × 1000（同一份数）
        let master = try XCTUnwrap(c.effects.buses.first { $0.bus == "master" })
        XCTAssertGreaterThan(busStatus(.master).latencyFrames, 0, "限幅有前瞻")
        XCTAssertEqual(master.latencyMs, ms(busStatus(.master).latencyFrames), accuracy: 1e-9)
        XCTAssertEqual(master.latencyMs, 12, accuracy: 0.5, "PeakLimiter 的延迟 = 起音 12 ms")
        XCTAssertNil(master.measuredLatencyMs, "限幅不是自写压缩器：缺键")
        let busA = try XCTUnwrap(c.effects.buses.first { $0.bus == "busA" })
        XCTAssertEqual(busA.latencyMs, ms(busStatus(.busA).latencyFrames), accuracy: 1e-9)
        XCTAssertEqual(busA.measuredLatencyMs, busStatus(.busA).compressorMeasuredLatencyFrames.map(ms), "装着压缩器：写实测（按设计 0）")
        XCTAssertEqual(busA.measuredLatencyMs, 0)
        XCTAssertEqual(c.effects.buses.first { $0.bus == "busB" }, E.BusLatency(bus: "busB", latencyMs: 0), "没装效果 = 0")
        let phones = try XCTUnwrap(c.effects.buses.first { $0.bus == "headphones" }, "耳机总线也列")
        XCTAssertEqual(phones.latencyMs, ms(busStatus(.headphones).latencyFrames), accuracy: 1e-9)
        XCTAssertEqual(phones.latencyMs, 12, accuracy: 0.5, "耳机条一格限幅 = 起音 12 ms")

        // 每路：只列装了效果的路；值 = status 的 latencyFrames；measured 只在动态格是压缩器时写
        XCTAssertEqual(Set(c.effects.inputs.keys), [2, 3, 4], "没装效果的 1 号不列")
        XCTAssertEqual(c.effects.inputs[2], E.InputLatency(latencyMs: ms(inputStatus(2).latencyFrames)))
        XCTAssertEqual(c.effects.inputs[2]?.latencyMs, 0, "一格 EQ（NBandEQ 0 帧）也列")
        XCTAssertEqual(c.effects.inputs[3], E.InputLatency(latencyMs: ms(inputStatus(3).latencyFrames), measuredLatencyMs: inputStatus(3).compressorMeasuredLatencyFrames.map(ms)))
        XCTAssertEqual(c.effects.inputs[3]?.measuredLatencyMs, 0)
        XCTAssertEqual(c.effects.inputs[4]?.latencyMs ?? -1, ms(256), accuracy: 1e-9, "DynamicsProcessor 前瞻 256 帧 = 5.333 ms")
        XCTAssertNil(c.effects.inputs[4]?.measuredLatencyMs)

        // 整行能写成 JSON 并读回（stats.jsonl / API 同一份）
        let row = Stats(ts: 0, tick: .zero, renderMs: 0, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [], audio: c, rssMb: 0, cpuPct: 0, gpuPct: 0)
        XCTAssertEqual(try Stats.parse(line: try row.jsonLine()).audio.effects, c.effects)

        // 改链：输入 3 的压缩器换成 EQ（链里没有压缩器了 → measured 缺键）、输入 2 清空（不再列）、Master 拆掉限幅（回到 0）
        await setInputEffects(rig, 3, [FX.eq(500, gainDb: -3)])
        await setInputEffects(rig, 2, [])
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: []))
        await rig.run(seconds: 0.5)
        c = rig.engine.audioCounters
        XCTAssertEqual(Set(c.effects.inputs.keys), [3, 4])
        XCTAssertEqual(c.effects.inputs[3], E.InputLatency(latencyMs: 0), "压缩器换成 EQ 之后 measured 缺键（AudioEngineStatus 里留着的上一次实测不算：\(rig.engine.status.inputs.first { $0.number == 3 }!.effects)）")
        XCTAssertEqual(c.effects.buses.first { $0.bus == "master" }, E.BusLatency(bus: "master", latencyMs: 0))
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }
}
