import XCTest
import AudioToolbox
import SwitcherContracts
@testable import SwitcherAudio

/// 总线效果链：苹果 AU 在我们的线程里 AudioUnitRender；关闭 = 精确旁路；EQ / 压缩 / 限幅各自可验证的效果；延迟可读。
/// W5-C 起 EQ 格是 AUNBandEQ（一个格最多 16 段，契约里连续的 parametricEQ 格映射成它的各段），探针结论见 reports/w5-audio-bus-effects.md §1；
/// 下面 testProbe_* 把探针里我们依赖的事实钉成回归（换 macOS 版本时先看它们）。
final class EffectChainTests: XCTestCase {

    func makeRig(hz: Double = 1000, dbfs: Double = -20, channels: Int = 2) -> OfflineRig {
        let rig = OfflineRig()
        let amp = pow(10, dbfs / 20)
        rig.addSource(slot: 0, channels: channels, generator: { _, start, n, buf in
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
            XCTAssertEqual(eu!.kind, AudioMixer.defaultEffectKind(for: e))
        } }
        XCTAssertEqual(rig.mixer.effectUnit(.master, .parametricEQ)!.kind, .nBandEQ, "W5-C：EQ 格换成 AUNBandEQ")
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

    // MARK: - W5-C：一个 EQ 格 = 最多 16 段（AUNBandEQ）

    /// 三段装在同一个格里：200 Hz −6、1 kHz +12、5 kHz +6，各自的增益对得上（每次只送一个频率），其余 13 段旁路。
    func testEffects_nBandEQ_threeBandsInOneSlot() throws {
        for (hz, expect) in [(200.0, -6.0), (1000.0, 12.0), (5000.0, 6.0), (2_800.0, Double.nan)] {
            let rig = makeRig(hz: hz, dbfs: -30)
            let eq = try rig.mixer.installEffect(.master, .parametricEQ)
            XCTAssertEqual(eq.kind, .nBandEQ)
            XCTAssertEqual(eq.bandCount, EffectParameterRanges.nBandEQMaxBands)
            eq.setEQBand(0, centerHz: 200, q: 4, gainDb: -6)
            eq.setEQBand(1, centerHz: 1000, q: 4, gainDb: 12)
            eq.setEQBand(2, centerHz: 5000, q: 4, gainDb: 6)
            eq.bypassEQBands(from: 3)
            rig.mixer.setEffectEnabled(.master, .parametricEQ, true)
            rig.run(blocks: 200)
            let o = rig.collect(blocks: 40, bus: .master)
            let gain = T.db(T.rms(o.left)) - (-30 - 3.01)
            if expect.isNaN {
                // 三段之间（1 kHz 与 5 kHz 的几何中点附近）几乎不受影响：q = 4 时 ≤ 0.6 dB
                XCTAssertLessThan(abs(gain), 0.6, "\(hz) Hz 实测 \(gain) dB")
            } else {
                XCTAssertEqual(gain, expect, accuracy: 0.3, "\(hz) Hz")
            }
        }
    }

    /// 契约 q 的口径（W5-C 定，经典 Q）：带宽 BW = 2/ln2 · asinh(1/(2q)) 倍频程，带宽 = 增益为峰值一半（dB）处的上下边频之比
    /// —— AUNBandEQ 的带宽参数就是这个定义（探针实测 1.000 / 1.998 / 0.333 oct 与设定一致、与增益无关）。q = √2 → 1 oct。
    func testEffects_nBandEQ_qMapsToHalfGainBandwidth() throws {
        XCTAssertEqual(EffectParameterRanges.eqBandwidthOctaves(q: 2.0.squareRoot()), 1.0, accuracy: 1e-3)
        XCTAssertEqual(EffectParameterRanges.eqQ(bandwidthOctaves: 1), 2.0.squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(EffectParameterRanges.eqBandwidthOctaves(q: 1), 1.388, accuracy: 1e-3)
        func gain(_ hz: Double) throws -> Double {
            let rig = makeRig(hz: hz, dbfs: -30)
            let eq = try rig.mixer.installEffect(.master, .parametricEQ)
            eq.setEQBand(0, centerHz: 1000, q: Float(2.0.squareRoot()), gainDb: 12)
            rig.mixer.setEffectEnabled(.master, .parametricEQ, true)
            rig.run(blocks: 100)
            return T.db(T.rms(rig.collect(blocks: 40, bus: .master).left)) - (-30 - 3.01)
        }
        // 1 oct 带宽的半增益边频 = 1000 / √2 与 1000 · √2
        XCTAssertEqual(try gain(1000 / 2.0.squareRoot()), 6, accuracy: 0.15)
        XCTAssertEqual(try gain(1000 * 2.0.squareRoot()), 6, accuracy: 0.15)
        XCTAssertEqual(try gain(1000), 12, accuracy: 0.1)
    }

    /// 准备好再装（W5-C 拓扑变化的做法）：先建好、initialize、设好参数，等格关掉并经实时线程确认后再挂进去——初始化之后装渲染回调要能用。
    func testEffects_attachPreparedUnitAfterInitialize() throws {
        let rig = makeRig(hz: 1000, dbfs: -30)
        rig.run(blocks: 50)
        // 自写压缩器不是 AU（W1-D3）：makeEffectUnit 要报 notAnAudioUnit
        XCTAssertThrowsError(try rig.mixer.makeEffectUnit(.compressor, bus: .master, slot: .dynamicsProcessor))
        for kind in EffectKind.allCases where kind.subtype != nil {
            let eu = try rig.mixer.makeEffectUnit(kind, bus: .master, slot: .dynamicsProcessor)
            XCTAssertTrue(eu.initialized)
            XCTAssertEqual(eu.effect, .dynamicsProcessor)
            switch kind {
            case .nBandEQ: eu.setEQBand(0, centerHz: 1000, q: 1, gainDb: 6)
            case .parametricEQ: eu.setParametricEQ(centerHz: 1000, q: 1, gainDb: 6)
            case .dynamicsProcessor: eu.setDynamics(thresholdDb: 0, headroomDb: 5, overallGainDb: 6)
            case .peakLimiter: eu.setLimiter(attack: 0.002, decay: 0.024, preGainDb: 6)
            case .compressor: continue
            }
            rig.mixer.setEffectEnabled(.master, .dynamicsProcessor, false)
            rig.run(blocks: 2)
            try rig.mixer.attachEffectUnit(eu)
            XCTAssertTrue(rig.mixer.effectUnit(.master, .dynamicsProcessor) === eu)
            rig.mixer.setEffectEnabled(.master, .dynamicsProcessor, true)
            rig.run(blocks: 100)
            let g = T.db(T.rms(rig.collect(blocks: 40, bus: .master).left)) - (-30 - 3.01)
            XCTAssertEqual(g, 6, accuracy: 0.5, "\(kind)：初始化之后装渲染回调，渲染照常（+6 dB）")
        }
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
    }

    /// AudioUnitReset 清掉限幅器的前瞻缓冲：关掉之后再打开前 Reset，不会把关掉之前的旧数据放出来（探针：不 Reset 时静音输入的前 512 帧是 0 dBFS 的旧信号）。
    func testEffects_resetClearsLimiterLookahead() throws {
        let eu = try AudioMixer(configuration: { var c = AudioMixerConfiguration(); c.timebase = T.tb; return c }())
            .makeEffectUnit(.peakLimiter, bus: .master, slot: .peakLimiter)
        let probe = UnitRenderer(eu)
        _ = probe.render(frames: 48_000) { i in Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }
        let stale = probe.render(frames: 512) { _ in 0 }
        XCTAssertGreaterThan(T.peak(stale), 0.5, "不 Reset：前瞻缓冲里是旧数据")
        _ = probe.render(frames: 48_000) { i in Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }
        eu.reset()
        let clean = probe.render(frames: 512) { _ in 0 }
        XCTAssertEqual(T.peak(clean), 0, "Reset 之后前瞻缓冲是零")
    }

    /// A7（W5-C）：运行中改参数——EQ 各段、压缩阈值、限幅起音（= 前瞻长度，AU 在 render 里换前瞻缓冲的长度）——AU 在我们的实时区里
    /// 重算系数 / 换前瞻时不许分配。守卫 + malloc 钩子下跑 2000 块、每块都改一次（推子 / 滑块拖动的最坏情况）。
    func testA7_paramChangesWhileRendering_noAllocationInRealtime() throws {
        RealtimeGuard.installMallocProbe()
        RealtimeGuard.reset()
        defer { RealtimeGuard.removeMallocProbe() }
        let rig = makeRig(hz: 997, dbfs: -6)
        try rig.mixer.installStandardEffects()
        for e in BusEffect.allCases { rig.mixer.setEffectEnabled(.master, e, true) }
        let eq = rig.mixer.effectUnit(.master, .parametricEQ)!
        let dyn = rig.mixer.effectUnit(.master, .dynamicsProcessor)!
        let lim = rig.mixer.effectUnit(.master, .peakLimiter)!
        var k = 0
        rig.run(blocks: 2000) { _ in
            k += 1
            eq.setEQBand(k % 3, centerHz: Float(200 + (k % 50) * 100), q: Float(0.5 + Double(k % 10) * 0.5), gainDb: Float(k % 25 - 12), enabled: k % 7 != 0)
            dyn.setDynamics(thresholdDb: Float(-(k % 40)), headroomDb: Float(1 + k % 10))
            lim.setLimiter(attack: Float(0.001 + Double(k % 30) * 0.001), decay: 0.024, preGainDb: Float(k % 12))
        }
        XCTAssertEqual(rig.mixer.stats.rtViolations, 0)
        XCTAssertEqual(RealtimeGuard.allocationsInRealtime, 0, "改参数后 AU 在实时区里不分配")
        XCTAssertEqual(rig.mixer.stats.underruns, 0)
    }

    // MARK: - 钳位表（界面 / 契约值 → 送进 AU 的值）

    func testEffects_clampTable() {
        typealias R = EffectParameterRanges
        XCTAssertEqual(R.clamp(-60, effect: "dynamicsProcessor", key: "thresholdDb").value, -40)
        XCTAssertTrue(R.clamp(-60, effect: "dynamicsProcessor", key: "thresholdDb").clamped)
        XCTAssertFalse(R.clamp(-20, effect: "dynamicsProcessor", key: "thresholdDb").clamped)
        XCTAssertEqual(R.clamp(0.06, effect: "peakLimiter", key: "decaySeconds").value, 0.04)
        XCTAssertEqual(R.clamp(0.05, effect: "peakLimiter", key: "attackSeconds").value, 0.03)
        XCTAssertEqual(R.clamp(30, effect: "parametricEQ", key: "gainDb").value, 24)
        XCTAssertEqual(R.clamp(0.1, effect: "parametricEQ", key: "q").value, R.eqQ(bandwidthOctaves: 5), accuracy: 1e-9)
        XCTAssertEqual(R.clamp(0.0001, effect: "dynamicsProcessor", key: "attackSeconds").value, 0.001)
        XCTAssertNil(R.range(effect: "parametricEQ", key: "nope"))
        XCTAssertNil(R.range(effect: "border", key: "width"))
        // q 的范围就是带宽 0.05…5 oct 换回来的
        XCTAssertEqual(R.range(effect: "parametricEQ", key: "q")!.lowerBound, 0.1826, accuracy: 1e-3)
        XCTAssertEqual(R.range(effect: "parametricEQ", key: "q")!.upperBound, 28.85, accuracy: 1e-2)
    }

    // MARK: - 探针回归（铁律 10 的结论钉在这里；reports/w5-audio-bus-effects.md §1）

    /// 钳位表的每个范围都要落在本机 AU 的 ParameterInfo 范围里（ParameterInfo 报 Q 下限 1.0 的 ParametricEQ 不在表里）；
    /// 换了 macOS 版本 AU 收窄了某个范围，这里先红。
    func testProbe_clampTableWithinAUParameterInfo() throws {
        let mixer = AudioMixer(configuration: { var c = AudioMixerConfiguration(); c.timebase = T.tb; return c }())
        let eq = try mixer.makeEffectUnit(.nBandEQ, bus: .master, slot: .parametricEQ)
        let dyn = try mixer.makeEffectUnit(.dynamicsProcessor, bus: .master, slot: .dynamicsProcessor)
        let lim = try mixer.makeEffectUnit(.peakLimiter, bus: .master, slot: .peakLimiter)
        func check(_ eu: EffectUnit, _ id: AudioUnitParameterID, _ effect: String, _ key: String, transform: (Double) -> Double = { $0 }) {
            guard let info = eu.parameterInfo(id) else { return XCTFail("\(effect).\(key) 读不到 ParameterInfo") }
            let r = EffectParameterRanges.range(effect: effect, key: key)!
            let lo = transform(r.lowerBound), hi = transform(r.upperBound)
            XCTAssertGreaterThanOrEqual(min(lo, hi), Double(info.minValue) - 1e-6, "\(effect).\(key)：表 \(r)，AU \(info.minValue)…\(info.maxValue)")
            XCTAssertLessThanOrEqual(max(lo, hi), Double(info.maxValue) + 1e-6, "\(effect).\(key)：表 \(r)，AU \(info.minValue)…\(info.maxValue)")
        }
        check(eq, kAUNBandEQParam_Frequency, "parametricEQ", "centerHz")
        check(eq, kAUNBandEQParam_Gain, "parametricEQ", "gainDb")
        check(eq, kAUNBandEQParam_Bandwidth, "parametricEQ", "q") { EffectParameterRanges.eqBandwidthOctaves(q: $0) }
        check(dyn, kDynamicsProcessorParam_Threshold, "dynamicsProcessor", "thresholdDb")
        check(dyn, kDynamicsProcessorParam_HeadRoom, "dynamicsProcessor", "headroomDb")
        check(dyn, kDynamicsProcessorParam_ExpansionRatio, "dynamicsProcessor", "expansionRatio")
        check(dyn, kDynamicsProcessorParam_AttackTime, "dynamicsProcessor", "attackSeconds")
        check(dyn, kDynamicsProcessorParam_ReleaseTime, "dynamicsProcessor", "releaseSeconds")
        check(dyn, kDynamicsProcessorParam_OverallGain, "dynamicsProcessor", "overallGainDb")
        check(lim, kLimiterParam_AttackTime, "peakLimiter", "attackSeconds")
        check(lim, kLimiterParam_DecayTime, "peakLimiter", "decaySeconds")
        check(lim, kLimiterParam_PreGain, "peakLimiter", "preGainDb")
        var maxBands: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(AudioUnitGetProperty(eq.unit, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &maxBands, &size), noErr)
        XCTAssertGreaterThanOrEqual(Int(maxBands), EffectParameterRanges.nBandEQMaxBands)
    }

    /// 延迟：NBandEQ 0（IIR，冲激峰在第 0 帧）；DynamicsProcessor 恒 256 帧（与起音无关）；PeakLimiter = 起音 × 48000（起音就是前瞻），
    /// 运行中改起音，Latency 属性立刻跟着变。集成层按这些数补 A/V 对齐（W5-C 交付 2）。
    func testProbe_latencies() throws {
        let mixer = AudioMixer(configuration: { var c = AudioMixerConfiguration(); c.timebase = T.tb; return c }())
        let eq = try mixer.makeEffectUnit(.nBandEQ, bus: .master, slot: .parametricEQ)
        eq.setEQBand(0, centerHz: 200, q: 1, gainDb: 6); eq.setEQBand(1, centerHz: 1000, q: 1, gainDb: 6); eq.setEQBand(2, centerHz: 5000, q: 1, gainDb: 6)
        XCTAssertEqual(eq.latencyFrames, 0)
        let r = UnitRenderer(eq)
        let impulse = r.render(frames: 4800) { $0 == 1000 ? 0.25 : 0 }
        XCTAssertEqual(impulse.indices.max { abs(impulse[$0]) < abs(impulse[$1]) }, 1000, "3 段 NBandEQ 的冲激峰不延迟")
        let dyn = try mixer.makeEffectUnit(.dynamicsProcessor, bus: .master, slot: .dynamicsProcessor)
        for a in [0.001, 0.05, 0.2] {
            dyn.setDynamics(thresholdDb: -20, attack: Float(a))
            XCTAssertEqual(dyn.latencyFrames, 256, "DynamicsProcessor 起音 \(a)")
        }
        let lim = try mixer.makeEffectUnit(.peakLimiter, bus: .master, slot: .peakLimiter)
        for a in [0.001, 0.002, 0.012, 0.03] {
            lim.setLimiter(attack: Float(a))
            XCTAssertEqual(lim.latencyFrames, Int((a * 48_000).rounded()), "PeakLimiter 起音 \(a)")
        }
        print("[probe] 尾巴（s）：NBandEQ \(eq.tailSeconds) Dynamics \(dyn.tailSeconds) Limiter \(lim.tailSeconds)")
    }

    /// 关闭 = 跳过 render（C 的 enable 位，块边界由实时线程自己应用）：输出与输入逐样本相同，延迟也随之消失。
    func testProbe_disabledSlotIsBitExact() throws {
        let rig = makeRig(hz: 997, dbfs: -6)
        rig.mixer.setRouting(slot: 0, BusRouting(master: true, busA: true))
        try rig.mixer.installStandardEffects()
        rig.mixer.effectUnit(.master, .parametricEQ)!.setParametricEQ(centerHz: 1000, q: 1, gainDb: 12)
        rig.mixer.effectUnit(.master, .peakLimiter)!.setLimiter(attack: 0.012, preGainDb: 12)
        // 开过再关：AU 渲染过、内部有状态，关掉之后照样不碰它
        for e in BusEffect.allCases { rig.mixer.setEffectEnabled(.master, e, true) }
        rig.run(blocks: 100)
        for e in BusEffect.allCases { rig.mixer.setEffectEnabled(.master, e, false) }
        rig.run(blocks: 2)
        var maxDiff: Float = 0
        // Master（三格装了 AU、关着）与 Bus A（同一路输入、没有效果）逐样本比
        rig.run(blocks: 100) { b in
            let (ml, mr) = b.bus(.master), (al, ar) = b.bus(.busA)
            for i in 0..<b.frames { maxDiff = max(maxDiff, abs(ml[i] - al[i]), abs(mr[i] - ar[i])) }
        }
        XCTAssertEqual(maxDiff, 0, "三格都装了 AU 但关着：Master 与没有效果的 Bus A 逐样本相同")
    }
}

/// 直接对一个 EffectUnit 跑 AudioUnitRender（不经混音器；探针回归用）。输入回调是 C 约定、不捕获上下文，refCon 指向两个平面指针。
final class UnitRenderer {
    let eu: EffectUnit
    private let input = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let outL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let outR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let refCon = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    private var sampleTime: Float64 = 0

    init(_ eu: EffectUnit) {
        self.eu = eu
        refCon.initialize(to: input)
        var cb = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, ioData in
            let src = ref.assumingMemoryBound(to: UnsafeMutablePointer<Float>.self).pointee
            let abl = UnsafeMutableAudioBufferListPointer(ioData!)
            for c in 0..<abl.count {
                if abl[c].mData == nil { abl[c].mData = UnsafeMutableRawPointer(src) } else { abl[c].mData!.copyMemory(from: src, byteCount: Int(frames) * 4) }
                abl[c].mDataByteSize = frames * 4
            }
            return noErr
        }, inputProcRefCon: UnsafeMutableRawPointer(refCon))
        AudioUnitSetProperty(eu.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }

    deinit { input.deallocate(); outL.deallocate(); outR.deallocate(); refCon.deallocate() }

    func render(frames: Int, block: Int = 256, _ gen: (Int) -> Float) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(frames)
        var done = 0
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        while done < frames {
            let n = min(block, frames - done)
            for i in 0..<n { input[i] = gen(done + i) }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: outL)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: outR)
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            XCTAssertEqual(AudioUnitRender(eu.unit, &flags, &ts, 0, UInt32(n), abl.unsafeMutablePointer), noErr)
            out.append(contentsOf: UnsafeBufferPointer(start: abl[0].mData!.assumingMemoryBound(to: Float.self), count: n))
            sampleTime += Float64(n)
            done += n
        }
        return out
    }
}
