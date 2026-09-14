import XCTest
import AudioToolbox
import SwitcherContracts
@testable import SwitcherAudio

/// 总线效果链：苹果 AU 在我们的线程里 AudioUnitRender；关闭 = 精确旁路；EQ / 压缩 / 限幅各自可验证的效果；延迟可读。
final class EffectChainTests: XCTestCase {

    func makeRig(hz: Double = 1000, dbfs: Double = -20) -> OfflineRig {
        let rig = OfflineRig()
        let amp = pow(10, dbfs / 20)
        rig.addSource(slot: 0, channels: 2, generator: { _, start, n, buf in
            for i in 0..<n { buf[i] = Float(amp * sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
        })
        return rig
    }

    func testEffects_installStandardChainOnAllBuses() throws {
        let rig = makeRig()
        try rig.mixer.installStandardEffects()
        for b in Bus.allCases { for e in BusEffect.allCases {
            let eu = rig.mixer.effectUnit(b, e)
            XCTAssertNotNil(eu, "\(b) \(e)")
            XCTAssertTrue(eu!.initialized)
        } }
        // 关闭状态：输出 = 输入（精确旁路，不经 AU）
        rig.run(blocks: 100)
        let a = rig.collect(blocks: 20, bus: .master)
        XCTAssertEqual(T.db(T.rms(a.left)), -20 - 3.01, accuracy: 0.05)
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
        print("[fx] 延迟（帧）：EQ \(rig.mixer.effectUnit(.master, .parametricEQ)!.latencyFrames) " +
              "Dynamics \(rig.mixer.effectUnit(.master, .dynamicsProcessor)!.latencyFrames) " +
              "Limiter \(rig.mixer.effectUnit(.master, .peakLimiter)!.latencyFrames)")
    }

    /// EQ：1 kHz 处 +12 dB 峰值滤波 → 1 kHz 正弦电平 +12 dB（±0.5）；关掉又回到原电平。
    func testEffects_parametricEQBoostsBand() throws {
        let rig = makeRig(hz: 1000, dbfs: -30)
        let eq = try rig.mixer.installEffect(.master, .parametricEQ)
        eq.setParametricEQ(centerHz: 1000, q: 1.0, gainDb: 12)
        rig.mixer.setEffectEnabled(.master, .parametricEQ, true)
        rig.run(blocks: 200)
        var o = rig.collect(blocks: 40, bus: .master)
        let base = -30 - 3.01
        XCTAssertEqual(T.db(T.rms(o.left)), base + 12, accuracy: 0.5, "EQ +12 dB @ 1 kHz")
        XCTAssertEqual(T.db(T.rms(o.right)), base + 12, accuracy: 0.5)
        rig.mixer.setEffectEnabled(.master, .parametricEQ, false)
        rig.run(blocks: 50)
        o = rig.collect(blocks: 40, bus: .master)
        XCTAssertEqual(T.db(T.rms(o.left)), base, accuracy: 0.05, "关掉后精确旁路")
        // 远离中心频率不受影响（10 kHz，Q=1 的 1 kHz 峰值在 10 kHz 处 < 0.5 dB）
        let rig2 = makeRig(hz: 10_000, dbfs: -30)
        let eq2 = try rig2.mixer.installEffect(.master, .parametricEQ)
        eq2.setParametricEQ(centerHz: 1000, q: 1.0, gainDb: 12)
        rig2.mixer.setEffectEnabled(.master, .parametricEQ, true)
        rig2.run(blocks: 200)
        let o2 = rig2.collect(blocks: 40, bus: .master)
        XCTAssertEqual(T.db(T.rms(o2.left)), base, accuracy: 1.0)
    }

    /// 压缩：阈值 −40 dB、输入 −10 dBFS → 输出明显低于输入；限幅：0 dBFS 正弦 + 预增益 +6 dB → 峰值不超过 ~0 dBFS。
    func testEffects_dynamicsAndLimiterReduceLevel() throws {
        let rig = makeRig(hz: 1000, dbfs: -10)
        let dyn = try rig.mixer.installEffect(.master, .dynamicsProcessor)
        dyn.setDynamics(thresholdDb: -40, headroomDb: 5, expansionRatio: 1, attack: 0.001, release: 0.05, overallGainDb: 0)
        rig.mixer.setEffectEnabled(.master, .dynamicsProcessor, true)
        rig.run(blocks: 400)
        let o = rig.collect(blocks: 40, bus: .master)
        let base = -10 - 3.01
        let out = T.db(T.rms(o.left))
        XCTAssertLessThan(out, base - 6, "阈值 −40 dB 的压缩应把 −13 dBFS 压低至少 6 dB（实测 \(out)）")

        let rig2 = makeRig(hz: 1000, dbfs: 0)
        let lim = try rig2.mixer.installEffect(.master, .peakLimiter)
        lim.setLimiter(attack: 0.012, decay: 0.024, preGainDb: 6)
        rig2.mixer.setEffectEnabled(.master, .peakLimiter, true)
        rig2.run(blocks: 400)
        var pk: Float = 0
        rig2.run(blocks: 40) { b in pk = max(pk, Float(T.peak(Array(b.bus(.master).left)))) }
        XCTAssertLessThan(T.db(Double(pk)), 0.5, "限幅器后峰值不超过约 0 dBFS（实测 \(T.db(Double(pk)))）")
        XCTAssertGreaterThan(T.db(Double(pk)), -6, "但也不是把信号砍没了")
        XCTAssertEqual(rig2.mixer.stats.rtViolations, 0)
    }

    /// 三格串联顺序 EQ → 压缩 → 限幅，全开时链路能跑且无实时违规。
    func testEffects_fullChainRuns() throws {
        let rig = makeRig()
        try rig.mixer.installStandardEffects()
        for e in BusEffect.allCases { rig.mixer.setEffectEnabled(.master, e, true); rig.mixer.setEffectEnabled(.busA, e, true) }
        rig.mixer.effectUnit(.master, .parametricEQ)!.setParametricEQ(centerHz: 3000, q: 2, gainDb: -6)
        rig.run(blocks: 2000)
        let o = rig.collect(blocks: 40, bus: .master)
        XCTAssertGreaterThan(T.db(T.rms(o.left)), -40, "有信号通过")
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
        XCTAssertEqual(rig.mixer.stats.underruns, 0)
    }
}
