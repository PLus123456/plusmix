import XCTest
import AudioToolbox
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W5-C（prompt 88）：`BusState.effects` 接进混音器的三格（EQ = AUNBandEQ 最多 16 段 / DynamicsProcessor / PeakLimiter），
/// 链顺序 = 处理顺序，enabled = false 旁路；拓扑只在格数 / id 变化时换（关格 → 实时线程确认 → 换 → 开格）；
/// 效果链延迟在泵里补（Master / 总线块的 PTS 再减去已启用 AU 的延迟之和，延迟变化时按差值丢 / 补样本，PTS 连续）。
final class BusEffectsTests: XCTestCase {

    // MARK: - 契约格（键名 = docs/CONTRACTS.md §2.4，与 App 的 AudioEffectParams 同一套）

    static func eq(_ hz: Double, q: Double = 1, gainDb: Double, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: "parametricEQ", enabled: enabled, params: ["centerHz": .number(hz), "q": .number(q), "gainDb": .number(gainDb)])
    }
    static func dynamics(thresholdDb: Double = -20, headroomDb: Double = 5, expansionRatio: Double = 1, attackSeconds: Double = 0.001,
                         releaseSeconds: Double = 0.05, overallGainDb: Double = 0, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: "dynamicsProcessor", enabled: enabled, params: [
            "thresholdDb": .number(thresholdDb), "headroomDb": .number(headroomDb), "expansionRatio": .number(expansionRatio),
            "attackSeconds": .number(attackSeconds), "releaseSeconds": .number(releaseSeconds), "overallGainDb": .number(overallGainDb),
        ])
    }
    static func limiter(attackSeconds: Double = 0.012, decaySeconds: Double = 0.024, preGainDb: Double = 0, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: "peakLimiter", enabled: enabled, params: ["attackSeconds": .number(attackSeconds), "decaySeconds": .number(decaySeconds), "preGainDb": .number(preGainDb)])
    }
    /// 不改 click 形状、但三格都有延迟的链：EQ 100 Hz +3（0 帧）→ 压缩阈值 0 dBFS（click −3 dBFS 不进压缩，256 帧）→ 限幅起音 12 ms（预增益 0，click 不到 0 dBFS，576 帧）。
    static var clickSafeChain: [EffectSlot] {
        [eq(100, q: 1, gainDb: 3), dynamics(thresholdDb: 0, headroomDb: 5), limiter(attackSeconds: 0.012, preGainDb: 0)]
    }

    static func sine(_ hz: Double, amplitude: Double) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in for i in 0..<n { buf[i] = Float(amplitude * sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) } }
    }

    /// 单频点的幅度（DFT 一个频点；窗内整数个周期时精确）。
    static func amplitude(_ x: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in x.enumerated() {
            let ph = 2 * Double.pi * hz * Double(k) / 48_000
            re += Double(v) * cos(ph); im += Double(v) * sin(ph)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    func setEffects(_ rig: EngineRig, _ effects: [EffectSlot], bus: Bus = .master) async {
        _ = await rig.sm.apply(.setBusEffects(bus: bus, effects: effects))
    }

    // MARK: - testA_busEffects_eqChangesResponse

    /// Master 加一段 1 kHz +12 dB（q 2 = 0.71 oct），离线跑 5 s：1 kHz 电平比关掉时高 12 ± 0.5 dB，200 Hz 不变（±0.5 dB；q 2 时理论 +0.17）。
    func testA_busEffects_eqChangesResponse() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: Self.sine(1000, amplitude: 0.1))
        try rig.addSource(number: 2, generator: Self.sine(200, amplitude: 0.1))
        let cap = try rig.capture(.master)
        await rig.run(seconds: 1)
        await setEffects(rig, [Self.eq(1000, q: 2, gainDb: 12)])
        await rig.run(seconds: 1)
        var start = cap.left.count
        await rig.run(seconds: 4)
        let on = cap.left[start..<(start + 192_000)]
        let st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, nil, nil])
        XCTAssertEqual(st.enabled, [true, false, false])
        XCTAssertEqual(st.latencyFrames, 0)
        await setEffects(rig, [Self.eq(1000, q: 2, gainDb: 12, enabled: false)])
        await rig.run(seconds: 1)
        start = cap.left.count
        await rig.run(seconds: 4)
        let off = cap.left[start..<(start + 192_000)]
        let d1k = IT.db(Self.amplitude(on, hz: 1000) / Self.amplitude(off, hz: 1000))
        let d200 = IT.db(Self.amplitude(on, hz: 200) / Self.amplitude(off, hz: 200))
        print("[W5-C] EQ 1 kHz +12 dB q 2：1 kHz \(String(format: "%+.3f", d1k)) dB，200 Hz \(String(format: "%+.3f", d200)) dB")
        XCTAssertEqual(d1k, 12, accuracy: 0.5)
        XCTAssertEqual(d200, 0, accuracy: 0.5)
        XCTAssertEqual(rig.engine.effectsStatus(.master).enabled, [false, false, false], "全部段关掉 = 格关掉（精确旁路）")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 别的总线同样生效、互不串：Bus A 的 EQ 只改 Bus A。
    func testA_busEffects_busAOnly() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: Self.sine(1000, amplitude: 0.1))
        var s = InputSettings(); s.audio.routing = BusRouting(master: true, busA: true)
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA))
        await rig.run(seconds: 1)
        await setEffects(rig, [Self.eq(1000, q: 2, gainDb: -12)], bus: .busA)
        await rig.run(seconds: 1)
        let m0 = master.left.count, a0 = busA.left.count
        await rig.run(seconds: 1)
        let gm = IT.db(Self.amplitude(master.left[m0..<(m0 + 48_000)], hz: 1000) / (0.1 * 0.5.squareRoot()))
        let ga = IT.db(Self.amplitude(busA.left[a0..<(a0 + 48_000)], hz: 1000) / (0.1 * 0.5.squareRoot()))
        XCTAssertEqual(gm, 0, accuracy: 0.05, "Master 不受 Bus A 的 EQ 影响")
        XCTAssertEqual(ga, -12, accuracy: 0.5)
        XCTAssertEqual(rig.engine.effectsStatus(.busA).slots, [.nBandEQ, nil, nil])
        XCTAssertEqual(rig.engine.effectsStatus(.master).slots, [nil, nil, nil])
        await rig.shutdown()
    }

    // MARK: - testA_busEffects_limiterHoldsCeiling

    /// 0 dBFS 正弦过限幅，−6 dB 天花板：AUPeakLimiter 的天花板固定在 0 dBFS、没有天花板参数（探针），所以 −6 dB 天花板 = 限幅之后的 Master 增益 −6 dB。
    /// 链 = EQ 1 kHz +6 dB（把 0 dBFS 正弦推到 +6 dBFS）→ 限幅；输出峰值 ≤ −6 + 0.3 dB。对照：限幅关掉，峰值回到 ≈ 0 dBFS（超天花板 6 dB）。
    func testA_busEffects_limiterHoldsCeiling() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, channels: 2, generator: Self.sine(1000, amplitude: 1.0))   // 立体声居中 = 每边 0 dBFS
        _ = await rig.sm.apply(.busGain(bus: .master, dB: -6))
        let cap = try rig.capture(.master)
        await rig.run(seconds: 1)
        await setEffects(rig, [Self.eq(1000, q: 1, gainDb: 6), Self.limiter(attackSeconds: 0.002, decaySeconds: 0.024, preGainDb: 0)])
        await rig.run(seconds: 1)
        var start = cap.left.count
        await rig.run(seconds: 1)
        let limited = IT.db(IT.peak(cap.left[start...]))
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 96, "限幅起音 2 ms = 96 帧前瞻")
        await setEffects(rig, [Self.eq(1000, q: 1, gainDb: 6), Self.limiter(attackSeconds: 0.002, decaySeconds: 0.024, preGainDb: 0, enabled: false)])
        await rig.run(seconds: 1)
        start = cap.left.count
        await rig.run(seconds: 1)
        let unlimited = IT.db(IT.peak(cap.left[start...]))
        print("[W5-C] 限幅：开 \(String(format: "%.3f", limited)) dBFS，关 \(String(format: "%.3f", unlimited)) dBFS（天花板 −6）")
        XCTAssertLessThanOrEqual(limited, -6 + 0.3)
        XCTAssertGreaterThan(unlimited, -6 + 3, "对照：没有限幅时峰值高出天花板")
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 0)
        await rig.shutdown()
    }

    // MARK: - testA_busEffects_bypassIsTransparent

    /// enabled = false：三格 AU 都装着（开过、有内部状态），Master 与没有效果的 Bus A 逐样本相同（同一路输入、同一块），延迟 0。
    func testA_busEffects_bypassIsTransparent() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)   // TestSignal：1 kHz −20 dBFS + 每秒 click
        var s = InputSettings(); s.audio.routing = BusRouting(master: true, busA: true)
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        let chainOn = [Self.eq(1000, q: 1, gainDb: 12), Self.dynamics(thresholdDb: -40), Self.limiter(preGainDb: 12)]
        await setEffects(rig, chainOn)
        await rig.run(seconds: 1)
        await setEffects(rig, chainOn.map { var e = $0; e.enabled = false; return e })
        await rig.run(seconds: 0.1)
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA))
        await rig.run(seconds: 3)
        let st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, .dynamicsProcessor, .peakLimiter], "AU 都装着")
        XCTAssertEqual(st.enabled, [false, false, false])
        XCTAssertEqual(st.latencyFrames, 0)
        XCTAssertEqual(master.firstHostTime, busA.firstHostTime)
        XCTAssertEqual(master.left.count, busA.left.count)
        var maxDiff: Float = 0
        for i in 0..<min(master.left.count, busA.left.count) {
            maxDiff = max(maxDiff, abs(master.left[i] - busA.left[i]), abs(master.right[i] - busA.right[i]))
        }
        XCTAssertGreaterThan(IT.peak(master.left[...]), 0.5, "有 click 通过")
        XCTAssertEqual(maxDiff, 0, "旁路逐样本相同（实测最大差 \(maxDiff)）")
        await rig.shutdown()
    }

    // MARK: - testA_busEffects_topologyChangeNoDropout

    /// 运行中（空设备的实时线程在 render）把 Master 的 effects 从 0 格改到 3 格再改回，反复 N 次：A1 的 dropouts / underruns = 0、不连续 0、违规 0、
    /// PTS 连续；补了延迟，click 仍在整秒（≤ 1 ms）。改动放在 x.5 s，避开整秒的 click。
    func testA_busEffects_topologyChangeNoDropout() async throws {
        let cycles = Int(IT.seconds("SW_AUDIO_FX_CYCLES", default: 8))
        let rig = try await RealtimeFXRig(afv: false)
        try rig.addSource(number: 1)
        try rig.addSource(number: 2, driftPpm: 100) { start, n, buf in
            for i in 0..<n { buf[i] = 0.2 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) }
        }
        let analyzer = StreamAnalyzer(name: "fx-topology", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        var schedule: [(Double, [EffectSlot])] = []
        for k in 0..<cycles {
            schedule.append((Double(2 * k) + 1.5, Self.clickSafeChain))
            schedule.append((Double(2 * k) + 2.5, []))
        }
        await rig.drive(until: Double(2 * cycles) + 2, schedule: schedule)
        let st = rig.engine.status
        let fx = rig.engine.effectsStatus(.master)
        let s = analyzer.summary
        print("""
            [W5-C] 拓扑 0 ↔ 3 格 × \(cycles)（空设备）：dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) \
            违规 \(st.realtimeViolations) PTS 断点 \(analyzer.gaps)；click \(s.count) 个 均值 \(String(format: "%.3f", s.meanMs)) 最大 |\(String(format: "%.3f", s.maxAbsMs))| ms；\
            装格 \(fx.installs) 换格 \(fx.swaps) 拆格 \(fx.removals)；泵丢 \(st.consumers.map(\.latencyFramesDropped)) 补 \(st.consumers.map(\.latencyFramesInserted)) 帧
            """)
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertEqual(analyzer.gaps, 0, "效果链延迟变化时泵丢 / 补样本，PTS 仍连续")
        XCTAssertGreaterThanOrEqual(Double(s.count), Double(2 * cycles))
        XCTAssertLessThanOrEqual(s.maxAbsMs, 1, "延迟补上了：开着效果的那几秒 click 也在整秒")
        XCTAssertEqual(fx.installs, 3 * cycles, "每次 0 → 3 格装 3 个 AU")
        XCTAssertEqual(fx.removals, 3 * cycles)
        XCTAssertEqual(fx.slots, [nil, nil, nil])
        XCTAssertEqual(fx.pendingSwaps, 0)
        await rig.shutdown()
    }

    /// 同一格换种类（[EQ, 压缩, 限幅] → [限幅, 压缩, EQ]：0 号格 EQ → 限幅、2 号格 限幅 → EQ，1 号格的压缩原样留着）：
    /// 换的格先关、等实时线程确认、换进准备好的 AU、再开——那一格旁路的块数记在状态里（≤ 3 块），其余照常；A1 = 0。
    func testA_busEffects_kindSwapBypassesOnlyThatSlotBriefly() async throws {
        let rig = try await RealtimeFXRig(afv: false)
        try rig.addSource(number: 1)
        let analyzer = StreamAnalyzer(name: "fx-swap", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        let forward = Self.clickSafeChain
        let reversed = Array(forward.reversed())
        await rig.drive(until: 1.0, schedule: [(0.5, forward)])
        let dynUnit = rig.engine.mixer.effectUnit(.master, .dynamicsProcessor)
        var bypass: [Int] = []
        var schedule: [(Double, [EffectSlot])] = []
        for k in 0..<6 { schedule.append((1.5 + Double(k), k % 2 == 0 ? reversed : forward)) }
        await rig.drive(until: 7.6, schedule: schedule) { fx in if let b = fx.lastBypassBlocks { bypass.append(b) } }
        let fx = rig.engine.effectsStatus(.master)
        let st = rig.engine.status
        print("[W5-C] 换格 \(fx.swaps) 次，旁路块数 \(Set(bypass).sorted())（最近一次 \(fx.lastBypassBlocks.map(String.init) ?? "—")），dropouts \(st.counters.dropouts) 不连续 \(analyzer.discontinuities)")
        XCTAssertEqual(fx.slots, [.nBandEQ, .dynamicsProcessor, .peakLimiter])
        XCTAssertEqual(fx.swaps, 12, "每次反转换两格（0 号、2 号）")
        XCTAssertTrue(rig.engine.mixer.effectUnit(.master, .dynamicsProcessor) === dynUnit, "压缩那一格从头到尾是同一个 AU")
        XCTAssertLessThanOrEqual(fx.lastBypassBlocks ?? 99, 3)
        XCTAssertLessThanOrEqual(bypass.max() ?? 0, 3)
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertEqual(analyzer.gaps, 0)
        await rig.shutdown()
    }

    // MARK: - A2：效果链延迟已补

    /// 三格都有延迟（0 + 256 + 576 = 832 帧 = 17.3 ms）：不补的话 Master 里的 click 晚 17.3 ms；补了（PTS 再减 832 帧）click 回到整秒（≤ 1 样本）。
    func testA2_busEffects_latencyCompensated_offline() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        await setEffects(rig, Self.clickSafeChain)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 6)
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 832)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 4, "\(offsets)")
        for o in offsets { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒的 click 偏 \(o.offsetMs) ms") }
        XCTAssertEqual(cap.gaps.count, 0)
        await rig.shutdown()
    }

    /// 运行中延迟变了（0 → 限幅 12 ms = 576 → 起音改 2 ms = 96 → 关 = 0）：泵在变化那一块丢 / 补差值，PTS 连续，前后的 click 都在整秒。
    func testA2_busEffects_latencyChangeMidStream_splicesKeepTimeline() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        await rig.run(until: rig.t0 + HostDuration(seconds: 2.5))
        await setEffects(rig, [Self.limiter(attackSeconds: 0.012)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 5.5))
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 576)
        await setEffects(rig, [Self.limiter(attackSeconds: 0.002)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 8.5))
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 96)
        await setEffects(rig, [Self.limiter(attackSeconds: 0.002, enabled: false)])
        await rig.run(until: rig.t0 + HostDuration(seconds: 11.5))
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 0)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 10, "\(offsets)")
        for o in offsets { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒的 click 偏 \(o.offsetMs) ms") }
        XCTAssertEqual(cap.gaps.count, 0, "PTS 连续")
        let consumer = try XCTUnwrap(rig.engine.status.consumers.first)
        XCTAssertEqual(consumer.latencyFramesDropped, 576, "延迟涨 576：丢掉限幅器前瞻垫的那 576 帧")
        XCTAssertEqual(consumer.latencyFramesInserted, 480 + 96, "延迟降 480、再降 96：补静音")
        await rig.shutdown()
    }

    /// A2 空设备（实时线程）：三格 832 帧延迟，click 均值 / 最大偏移与不开效果时一样（空设备时钟 = host 时钟，±1 样本）。
    func testA2_busEffects_latencyCompensated_nullDevice() async throws {
        let seconds = IT.seconds("SW_AUDIO_A2_SECONDS", default: 20)
        let rig = try await RealtimeFXRig(afv: false)
        try rig.addSource(number: 1)
        let analyzer = StreamAnalyzer(name: "fx-a2", t0: rig.t0)
        await rig.drive(until: 0.3, schedule: [(0.0, Self.clickSafeChain)])
        try rig.engine.addConsumer(analyzer, source: .master)
        await rig.drive(until: seconds, schedule: [])
        let st = rig.engine.status
        let s = analyzer.summary
        print("[W5-C] A2 空设备 + 三格效果（延迟 \(rig.engine.effectsStatus(.master).latencyFrames) 帧）\(Int(seconds)) s：click \(s.count) 个，均值 \(String(format: "%.3f", s.meanMs)) ms，σ \(String(format: "%.3f", s.stdMs))，最大 |\(String(format: "%.3f", s.maxAbsMs))|")
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 832)
        XCTAssertGreaterThanOrEqual(Double(s.count), seconds - 2)
        XCTAssertLessThanOrEqual(abs(s.meanMs), 1, "A2 不因开效果而漂（基线：不开效果时 ±1 样本）")
        XCTAssertLessThanOrEqual(s.maxAbsMs, 1)
        XCTAssertEqual(st.counters.dropouts + st.counters.underruns + analyzer.discontinuities, 0)
        XCTAssertEqual(analyzer.gaps, 0)
        XCTAssertEqual(st.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// A2 真设备（要 SW_AUDIO_REAL_DEVICE=1；系统默认输出，扬声器静音、Master 照常送消费者）：消费者流经 HostClockResampler（设备时钟 → host 时钟），
    /// 拼接在重采样之前做，PTS 连续进重采样器。前 10 s 不开效果、中间 10 s 三格（832 帧）、后 10 s 关掉：三段的 click 都在同一条时间线上（≤ 1 ms），A1 = 0。
    func testA2_busEffects_latencyCompensated_realDevice() async throws {
        guard IT.env["SW_AUDIO_REAL_DEVICE"] == "1" else { throw XCTSkip("真设备用例要 SW_AUDIO_REAL_DEVICE=1（系统默认输出设备；扬声器静音）") }
        guard AudioHAL.defaultOutputDevice() != nil else { throw XCTSkip("BLOCKED-硬件：没有默认输出设备") }
        let rig = try await RealtimeFXRig(afv: false, output: .systemDefault)
        try rig.addSource(number: 1)
        let analyzer = StreamAnalyzer(name: "fx-a2-real", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        await rig.drive(until: 31, schedule: [(10.5, Self.clickSafeChain), (20.5, [])])
        let st = rig.engine.status
        let s = analyzer.summary
        let early = analyzer.clickOffsetsMs.filter { $0.second <= 10 }.map(\.offsetMs)
        let middle = analyzer.clickOffsetsMs.filter { $0.second >= 12 && $0.second <= 20 }.map(\.offsetMs)
        let late = analyzer.clickOffsetsMs.filter { $0.second >= 22 }.map(\.offsetMs)
        func mean(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.reduce(0, +) / Double(a.count) }
        print("""
            [W5-C] A2 真设备「\(rig.engine.outputDevice?.info.name ?? "?")」：不开效果 \(String(format: "%.3f", mean(early))) ms、三格（832 帧）\(String(format: "%.3f", mean(middle))) ms、\
            关掉 \(String(format: "%.3f", mean(late))) ms；全部 click \(s.count) 个 最大 |\(String(format: "%.3f", s.maxAbsMs))|；设备 ppm \(st.consumers.first?.devicePpm.map { String(format: "%.2f", $0) } ?? "—")；\
            dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) PTS 断点 \(analyzer.gaps)；泵丢 \(st.consumers.map(\.latencyFramesDropped)) 补 \(st.consumers.map(\.latencyFramesInserted))
            """)
        XCTAssertGreaterThanOrEqual(early.count, 8); XCTAssertGreaterThanOrEqual(middle.count, 7); XCTAssertGreaterThanOrEqual(late.count, 7)
        XCTAssertLessThanOrEqual(abs(mean(middle) - mean(early)), 1, "开效果前后 A2 均值差 ≤ 1 ms")
        XCTAssertLessThanOrEqual(abs(mean(late) - mean(early)), 1)
        XCTAssertLessThanOrEqual(abs(s.meanMs), 5, "A2 目标档")
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(analyzer.gaps, 0)
        await rig.shutdown()
    }

    // MARK: - 钳位、不认识的格、超出三格

    /// 超出 AU 范围的参数钳位（AU 自己不钳：起音 0.05 s 照收、延迟变 2400 帧），每个键只记一次日志；改别的东西重发同一条链不再记。
    func testBusEffects_outOfRangeParamsClampedAndLoggedOnce() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let wild = [Self.eq(30_000, q: 0.1, gainDb: 30), Self.dynamics(thresholdDb: -60, attackSeconds: 0.0001),
                     Self.limiter(attackSeconds: 0.05, decaySeconds: 0.06, preGainDb: 0)]
        await setEffects(rig, wild)
        await rig.run(seconds: 0.2)
        let eq = try XCTUnwrap(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 0)))
        let dyn = try XCTUnwrap(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 1)))
        let lim = try XCTUnwrap(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 2)))
        XCTAssertEqual(Double(eq.parameter(kAUNBandEQParam_Frequency)!), 23_520, accuracy: 0.5)
        XCTAssertEqual(Double(eq.parameter(kAUNBandEQParam_Gain)!), 24, accuracy: 1e-4)
        XCTAssertEqual(Double(eq.parameter(kAUNBandEQParam_Bandwidth)!), 5, accuracy: 1e-3)
        XCTAssertEqual(Double(dyn.parameter(kDynamicsProcessorParam_Threshold)!), -40, accuracy: 1e-4)
        XCTAssertEqual(Double(dyn.parameter(kDynamicsProcessorParam_AttackTime)!), 0.001, accuracy: 1e-6)
        XCTAssertEqual(Double(lim.parameter(kLimiterParam_AttackTime)!), 0.03, accuracy: 1e-6)
        XCTAssertEqual(Double(lim.parameter(kLimiterParam_DecayTime)!), 0.04, accuracy: 1e-6)
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 256 + 1440, "钳到 30 ms 的起音 = 1440 帧，不是 2400")
        let notes = rig.engine.effectNotes
        XCTAssertEqual(notes.count, 7, "\(notes)")
        // 推子动了（.buses 事件，effects 没变）、同一条链只改一个范围内的值再发一次：都不再记
        _ = await rig.sm.apply(.busGain(bus: .master, dB: -3))
        await rig.run(seconds: 0.1)
        var again = wild
        again[2] = Self.limiter(attackSeconds: 0.05, decaySeconds: 0.06, preGainDb: 1)
        await setEffects(rig, again)
        await rig.run(seconds: 0.1)
        XCTAssertEqual(rig.engine.effectNotes.count, 7, "\(rig.engine.effectNotes)")
        XCTAssertEqual(Double(lim.parameter(kLimiterParam_PreGain)!), 1, accuracy: 1e-4, "范围内的改动照样生效")
        await rig.shutdown()
    }

    /// 不认识的 id（例如视频格 border）不装、超出三格的组不装，各记一次；装上的按链序占格。
    func testBusEffects_unknownIdsAndOverflowIgnored() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let chain = [Self.eq(1000, gainDb: 3), Self.dynamics(), Self.eq(4000, gainDb: -3), Self.limiter(),
                     EffectSlot(id: "border", params: ["width": .number(0.01)])]
        await setEffects(rig, chain)
        await rig.run(seconds: 0.1)
        let st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, .dynamicsProcessor, .nBandEQ], "EQ 被压缩隔开就是两组，各占一格")
        XCTAssertEqual(st.ignored, 2)
        XCTAssertEqual(rig.engine.effectNotes.count, 2, "\(rig.engine.effectNotes)")
        await setEffects(rig, chain)   // 同一条链再来一次：不再记
        XCTAssertEqual(rig.engine.effectNotes.count, 2)
        await rig.shutdown()
    }

    // MARK: - 拓扑：只在格数 / id 变化时换

    /// 改参数、增减 EQ 段（16 段以内）、开关：都不换 AU（同一个对象），不旁路；只有组的种类变了才换。
    func testBusEffects_paramChangesKeepTopology() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        await setEffects(rig, [Self.eq(1000, gainDb: 6), Self.limiter()])
        await rig.run(seconds: 0.1)
        let eqUnit = try XCTUnwrap(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 0)))
        let limUnit = try XCTUnwrap(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 2)))
        XCTAssertEqual(rig.engine.effectsStatus(.master).slots, [.nBandEQ, nil, .peakLimiter], "限幅放在它的默认格（2），前面留给以后加的压缩")
        for chain in [[Self.eq(1000, gainDb: 3), Self.limiter(preGainDb: 2)],
                      [Self.eq(1000, gainDb: 3), Self.eq(3000, gainDb: -2), Self.eq(8000, gainDb: 1), Self.limiter()],
                      [Self.eq(1000, gainDb: 3, enabled: false), Self.limiter(enabled: false)],
                      [Self.eq(500, gainDb: 1), Self.limiter()]] {
            await setEffects(rig, chain)
            await rig.run(seconds: 0.05)
            XCTAssertTrue(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 0)) === eqUnit)
            XCTAssertTrue(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 2)) === limUnit)
        }
        // 加一个压缩：放进空着的 1 号格，EQ / 限幅不动
        await setEffects(rig, [Self.eq(500, gainDb: 1), Self.dynamics(), Self.limiter()])
        await rig.run(seconds: 0.05)
        let st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, .dynamicsProcessor, .peakLimiter])
        XCTAssertTrue(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 0)) === eqUnit)
        XCTAssertTrue(rig.engine.mixer.effectUnit(.master, BusEffect(slot: 2)) === limUnit)
        XCTAssertEqual(st.swaps, 0)
        XCTAssertEqual(st.installs, 3)
        await rig.shutdown()
    }

    /// 三段 EQ 装在一个格里（200 Hz −6 / 1 kHz +12 / 5 kHz +6，q 4），三个频率各自的增益对得上。
    func testBusEffects_threeEQBandsShareOneSlot() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: Self.sine(200, amplitude: 0.05))
        try rig.addSource(number: 2, generator: Self.sine(1000, amplitude: 0.05))
        try rig.addSource(number: 3, generator: Self.sine(5000, amplitude: 0.05))
        let cap = try rig.capture(.master)
        await rig.run(seconds: 1)
        var start = cap.left.count
        await rig.run(seconds: 1)
        let dry = cap.left[start..<(start + 48_000)]
        await setEffects(rig, [Self.eq(200, q: 4, gainDb: -6), Self.eq(1000, q: 4, gainDb: 12), Self.eq(5000, q: 4, gainDb: 6)])
        await rig.run(seconds: 0.5)
        start = cap.left.count
        await rig.run(seconds: 1)
        let wet = cap.left[start..<(start + 48_000)]
        XCTAssertEqual(rig.engine.effectsStatus(.master).slots, [.nBandEQ, nil, nil])
        for (hz, g) in [(200.0, -6.0), (1000.0, 12.0), (5000.0, 6.0)] {
            XCTAssertEqual(IT.db(Self.amplitude(wet, hz: hz) / Self.amplitude(dry, hz: hz)), g, accuracy: 0.3, "\(hz) Hz")
        }
        await rig.shutdown()
    }

    // MARK: - 方案（纯函数）

    func testBusEffects_planGroupsConsecutiveEQsAndAssignsSlots() {
        let p = BusEffectPlan.parse([Self.eq(100, gainDb: 1), Self.eq(1000, gainDb: 2), Self.eq(5000, gainDb: 3, enabled: false), Self.dynamics(), Self.limiter()])
        XCTAssertEqual(p.groups.map(\.kind), [.nBandEQ, .dynamicsProcessor, .peakLimiter])
        if case .eq(let bands) = p.groups[0] {
            XCTAssertEqual(bands.map(\.centerHz), [100, 1000, 5000])
            XCTAssertEqual(bands.map(\.enabled), [true, true, false])
        } else { XCTFail() }
        XCTAssertTrue(p.notes.isEmpty)
        let many = BusEffectPlan.parse((0..<17).map { Self.eq(100 + Double($0) * 100, gainDb: 1) })
        XCTAssertEqual(many.groups.count, 2, "16 段一格，第 17 段进下一格")
        if case .eq(let b) = many.groups[1] { XCTAssertEqual(b.count, 1) } else { XCTFail() }
        // 缺键用默认值（EQ 1 kHz q 1 0 dB；压缩 −20 / 5 / 2 / 1 ms / 50 ms / 0；限幅 12 ms / 24 ms / 0）
        let bare = BusEffectPlan.parse([EffectSlot(id: "peakLimiter")])
        if case .limiter(let l, let on) = bare.groups[0] {
            XCTAssertEqual(l.attackSeconds, 0.012); XCTAssertEqual(l.decaySeconds, 0.024); XCTAssertEqual(l.preGainDb, 0); XCTAssertTrue(on)
        } else { XCTFail() }

        typealias K = EffectKind
        XCTAssertEqual(BusEffectPlan.assignSlots([.nBandEQ], installed: [nil, nil, nil]), [0])
        XCTAssertEqual(BusEffectPlan.assignSlots([.peakLimiter], installed: [nil, nil, nil]), [2], "空的时候放默认格")
        XCTAssertEqual(BusEffectPlan.assignSlots([.dynamicsProcessor, .peakLimiter], installed: [nil, nil, nil]), [1, 2])
        XCTAssertEqual(BusEffectPlan.assignSlots([.nBandEQ, .peakLimiter], installed: [nil, .dynamicsProcessor, .peakLimiter]), [0, 2], "沿用 2 号格的限幅")
        XCTAssertEqual(BusEffectPlan.assignSlots([.peakLimiter], installed: [.peakLimiter, nil, nil]), [0], "已装的同种 AU 优先于默认格")
        XCTAssertEqual(BusEffectPlan.assignSlots([.peakLimiter, .dynamicsProcessor, .nBandEQ], installed: [.nBandEQ, .dynamicsProcessor, .peakLimiter]), [0, 1, 2])
        XCTAssertEqual(BusEffectPlan.assignSlots([.nBandEQ, .nBandEQ], installed: [nil, nil, nil]), [0, 1])
    }
}

/// 空设备（W1-D 假设备时钟：time-constraint 线程按块 render；或真设备）上的引擎 + 实时合成源；按墙钟驱动状态机并在指定时刻改 Master 的效果链。
final class RealtimeFXRig {
    let sm: StateMachine
    let engine: AudioEngine
    let clock: TickClockSpec
    let t0: HostTime
    var sources: [Int: RealtimeSource] = [:]

    init(afv: Bool, output: AudioEngineConfiguration.Output = .null) async throws {
        sm = StateMachine(initialState: States.fourInputs(afv: afv))
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = output
        cfg.outputChannelMap = BusChannelMap(master: nil)      // 真设备时扬声器静音
        engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        t0 = HostClock.now() + HostDuration(milliseconds: 300)
        clock = TickClockSpec(t0: t0, frameRate: .fps60)
        try await engine.start(clock: clock)
    }

    func addSource(number: Int, driftPpm: Double = 0, generator: ((Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) throws {
        let src = RealtimeSource(t0: t0, driftPpm: driftPpm, generator: generator)
        var hints = AudioInputHints()
        hints.producerBlockFrames = 256
        try engine.registerInput(number: number, ring: src.ring, hints: hints)
        sources[number] = src
        src.start()
    }

    /// 驱动到 t0 + until 秒；schedule 里每一项到点时整体替换 Master 的效果链。每 8 ms 看一次效果状态（observe）。
    func drive(until: Double, schedule: [(Double, [EffectSlot])], observe: ((AudioEngineStatus.BusEffects) -> Void)? = nil) async {
        var pending = schedule.sorted { $0.0 < $1.0 }
        let end = t0 + HostDuration(seconds: until)
        while HostClock.now() < end {
            sm.requestPrepare(clock.tick(at: HostClock.now()) + 1)
            while let first = pending.first, HostClock.now() >= t0 + HostDuration(seconds: first.0) {
                pending.removeFirst()
                _ = await sm.apply(.setBusEffects(bus: .master, effects: first.1))
            }
            observe?(engine.effectsStatus(.master))
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    func shutdown() async {
        for (_, s) in sources { s.stop() }
        await engine.stop()
        sm.stop()
    }
}
