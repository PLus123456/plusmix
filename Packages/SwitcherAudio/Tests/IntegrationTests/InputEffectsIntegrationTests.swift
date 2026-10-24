import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W1-D3（prompt 102）集成层：`InputSettings.effects` → 该路的两格（EQ / 动态；桥不发 effects 事件，引擎每个控制周期自己对快照 diff）；
/// 每路效果延迟计入该路的对齐延迟线；自写压缩器在总线 / 每路都能装，实测延迟进 `EffectLatencyTimeline`（A2 不漂）；
/// `compressor` 与 `dynamicsProcessor` 二选一占总线 1 号格；`peakLimiter.ceilingDb`；监听来源（提案 026）与借 Master 声道（X09）从状态 / 开关落到混音器。
final class InputEffectsIntegrationTests: XCTestCase {
    typealias FX = BusEffectsTests

    static func compressor(thresholdDb: Double = -20, ratio: Double = 4, kneeDb: Double = 6, attackSeconds: Double = 0.005, releaseSeconds: Double = 0.1,
                           makeupGainDb: Double = 0, enabled: Bool = true) -> EffectSlot {
        EffectSlot(id: "compressor", enabled: enabled, params: [
            "thresholdDb": .number(thresholdDb), "ratio": .number(ratio), "kneeDb": .number(kneeDb),
            "attackSeconds": .number(attackSeconds), "releaseSeconds": .number(releaseSeconds), "makeupGainDb": .number(makeupGainDb),
        ])
    }

    func setInputEffects(_ rig: EngineRig, _ number: Int, _ effects: [EffectSlot], routing: BusRouting? = nil) async {
        var s = (await rig.sm.state).input(number)?.settings ?? InputSettings()
        s.effects = effects
        if let routing { s.audio.routing = routing }
        _ = await rig.sm.apply(.setInputSettings(input: number, settings: s))
    }

    override func tearDown() {
        CompressorLatencyProbe.measure = CompressorLatencyProbe.defaultMeasure
        super.tearDown()
    }

    // MARK: - testA_inputEffects_eqChangesResponse

    /// 输入 1（Master）一段 1 kHz +12 dB：Master +12 ± 0.5；输入 2（Bus A，同一信号）频响不变（± 0.05）；状态里看得到格的开关。
    func testA_inputEffects_eqChangesResponse() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: FX.sine(1000, amplitude: 0.1))
        try rig.addSource(number: 2, generator: FX.sine(1000, amplitude: 0.1))
        await setInputEffects(rig, 2, [], routing: BusRouting(master: false, busA: true))
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA))
        await rig.run(seconds: 1)
        var m0 = master.left.count, a0 = busA.left.count
        await rig.run(seconds: 1)
        let dryM = FX.amplitude(master.left[m0..<(m0 + 48_000)], hz: 1000), dryA = FX.amplitude(busA.left[a0..<(a0 + 48_000)], hz: 1000)
        await setInputEffects(rig, 1, [FX.eq(1000, q: 2, gainDb: 12)])
        await rig.run(seconds: 0.5)
        m0 = master.left.count; a0 = busA.left.count
        await rig.run(seconds: 1)
        let wetM = FX.amplitude(master.left[m0..<(m0 + 48_000)], hz: 1000), wetA = FX.amplitude(busA.left[a0..<(a0 + 48_000)], hz: 1000)
        print("[W1-D3] 每路 EQ：输入 1 \(String(format: "%+.3f", IT.db(wetM / dryM))) dB，输入 2 \(String(format: "%+.3f", IT.db(wetA / dryA))) dB")
        XCTAssertEqual(IT.db(wetM / dryM), 12, accuracy: 0.5)
        XCTAssertEqual(IT.db(wetA / dryA), 0, accuracy: 0.05, "别的路不受影响")
        let fx1 = try XCTUnwrap(rig.engine.inputEffectsStatus(1)), fx2 = try XCTUnwrap(rig.engine.inputEffectsStatus(2))
        XCTAssertTrue(fx1.eqEnabled); XCTAssertEqual(fx1.eqBands, 1); XCTAssertNil(fx1.dynamicsKind); XCTAssertEqual(fx1.latencyFrames, 0)
        XCTAssertFalse(fx2.eqEnabled); XCTAssertEqual(fx2.eqBands, 0)
        XCTAssertEqual(rig.engine.status.inputs.first { $0.number == 1 }?.effects, fx1, "状态快照里的同一份")
        // 关掉（enabled = false）：格关、精确旁路
        await setInputEffects(rig, 1, [FX.eq(1000, q: 2, gainDb: 12, enabled: false)])
        await rig.run(seconds: 0.5)
        m0 = master.left.count
        await rig.run(seconds: 1)
        XCTAssertEqual(IT.db(FX.amplitude(master.left[m0..<(m0 + 48_000)], hz: 1000) / dryM), 0, accuracy: 0.05)
        XCTAssertFalse(rig.engine.inputEffectsStatus(1)!.eqEnabled)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    // MARK: - testA_inputEffects_bypassIsTransparent

    /// 输入 1 两格（EQ +12、压缩阈值 −40）开过再关：与输入 2（同一信号、无效果、Bus A）逐样本相同，PTS 起点相同。
    func testA_inputEffects_bypassIsTransparent() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        try rig.addSource(number: 2)
        await setInputEffects(rig, 2, [], routing: BusRouting(master: false, busA: true))
        let on = [FX.eq(1000, q: 1, gainDb: 12), Self.compressor(thresholdDb: -40, ratio: 10, kneeDb: 0)]
        await setInputEffects(rig, 1, on)
        await rig.run(seconds: 1)
        XCTAssertEqual(rig.engine.inputEffectsStatus(1)?.dynamicsKind, .compressor)
        await setInputEffects(rig, 1, on.map { var e = $0; e.enabled = false; return e })
        await rig.run(seconds: 0.1)
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA))
        await rig.run(seconds: 3)
        let fx = try XCTUnwrap(rig.engine.inputEffectsStatus(1))
        XCTAssertFalse(fx.eqEnabled); XCTAssertFalse(fx.dynamicsEnabled); XCTAssertEqual(fx.latencyFrames, 0)
        XCTAssertEqual(master.firstHostTime, busA.firstHostTime)
        XCTAssertEqual(master.left.count, busA.left.count)
        var maxDiff: Float = 0
        for i in 0..<min(master.left.count, busA.left.count) { maxDiff = max(maxDiff, abs(master.left[i] - busA.left[i]), abs(master.right[i] - busA.right[i])) }
        XCTAssertGreaterThan(IT.peak(master.left[...]), 0.5, "有 click 通过")
        XCTAssertEqual(maxDiff, 0, "旁路逐样本相同（实测最大差 \(maxDiff)）")
        await rig.shutdown()
    }

    // MARK: - 每路效果延迟计入该路的延迟补偿

    /// 动态格装苹果 DynamicsProcessor（前瞻 256 帧）：该路的对齐延迟线少 256 帧（1089 → 833），click 仍在整秒；状态里 latencyFrames = 256。
    /// 开 / 关的那一下该路内容跳 256 帧（一次性，与总线效果的拼接同一性质），比较只看切换前后各 2 s 之外的 click。
    func testA_inputEffects_latencyCountsAgainstAlignmentDelay() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 3)
        let before = rig.engine.status.inputs[0].alignmentDelayFrames
        XCTAssertEqual(before, 1089)
        await setInputEffects(rig, 1, [FX.dynamics(thresholdDb: 0, headroomDb: 5)])   // 阈值 0：click −3 dBFS 不进压缩，只有前瞻
        await rig.run(seconds: 4)
        let fx = try XCTUnwrap(rig.engine.inputEffectsStatus(1))
        XCTAssertEqual(fx.dynamicsKind, .dynamicsProcessor)
        XCTAssertEqual(fx.latencyFrames, 256)
        XCTAssertEqual(rig.engine.status.inputs[0].alignmentDelayFrames, before - 256, "延迟线吸收效果延迟")
        await setInputEffects(rig, 1, [])
        await rig.run(seconds: 4)
        XCTAssertEqual(rig.engine.status.inputs[0].alignmentDelayFrames, before)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        let steady = offsets.filter { $0.second <= 2 || (5...6).contains($0.second) || $0.second >= 9 }
        XCTAssertGreaterThanOrEqual(steady.count, 6, "\(offsets)")
        for o in steady { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒的 click 偏 \(o.offsetMs) ms") }
        XCTAssertEqual(cap.gaps.count, 0, "Master 的 PTS 连续（每路效果不动总线时间线）")
        await rig.shutdown()
    }

    // MARK: - testA_inputEffects_addRemoveInputNoDropout（W2-E 的用例扩一条：带效果链增删）

    /// 空设备实时：输入 2 的 effects 预先设好（EQ + 压缩），增删 100 次；常驻路的 A1 = 0、违规 0；每次挂上时格确实开着。
    func testA_inputEffects_addRemoveInputNoDropout() async throws {
        let sm = StateMachine(initialState: States.fourInputs(afv: false))
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = .null
        let engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        try await engine.start(clock: TickClockSpec(t0: t0, frameRate: .fps60))
        var s2 = InputSettings()
        s2.effects = [FX.eq(1000, q: 1, gainDb: 6), Self.compressor(thresholdDb: -30, ratio: 4)]
        _ = await sm.apply(.setInputSettings(input: 2, settings: s2))
        let resident = RealtimeSource(t0: t0)
        var hints = AudioInputHints(); hints.producerBlockFrames = 256
        try engine.registerInput(number: 1, ring: resident.ring, hints: hints)
        resident.start()
        let analyzer = StreamAnalyzer(name: "fx-life", t0: t0)
        try engine.addConsumer(analyzer, source: .master)
        try await Task.sleep(for: .seconds(1))
        var seenApplied = 0
        for k in 0..<100 {
            let src = RealtimeSource(t0: t0) { start, n, buf in
                for i in 0..<n { buf[i] = 0.2 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) }
            }
            try engine.registerInput(number: 2, ring: src.ring, hints: hints)
            src.start()
            try await Task.sleep(for: .milliseconds(120 + k % 50))
            if let fx = engine.inputEffectsStatus(2), fx.eqEnabled, fx.dynamicsEnabled, fx.dynamicsKind == .compressor { seenApplied += 1 }
            engine.unregisterInput(number: 2)
            try await Task.sleep(for: .milliseconds(40))
            src.stop()
            XCTAssertNil(engine.slot(forInput: 2), "第 \(k) 次")
        }
        try await Task.sleep(for: .seconds(1))
        let st = engine.status
        let s = analyzer.summary
        print("[W1-D3] 带效果增删 100 次（空设备）：dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) 违规 \(st.realtimeViolations)；格开着的次数 \(seenApplied)/100；click 均值 \(String(format: "%.3f", s.meanMs)) 最大 \(String(format: "%.3f", s.maxAbsMs)) ms")
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertEqual(seenApplied, 100, "每次挂上效果都接上了")
        XCTAssertLessThanOrEqual(s.maxAbsMs, 1)
        XCTAssertEqual(engine.registeredInputs, [1])
        resident.stop()
        await engine.stop()
        sm.stop()
    }

    // MARK: - 认不出的 / 装不下的格

    /// 每路只有 EQ（≤ 16 段）和一个动态格：限幅 / 第 17 段 / 第二个动态都不装，各记一次日志；重发同一条链不再记。
    /// 视频格 `border` 由状态机的 setInputSettings 清掉（P4 的搬迁口径），到不了引擎——引擎也认不出它，这里顺带钉住它确实没来。
    func testInputEffects_unsupportedSlotsIgnoredAndLoggedOnce() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        var chain = [FX.limiter(), EffectSlot(id: "border", params: ["width": .number(0.01)])]
        chain += (0..<17).map { FX.eq(100 + Double($0) * 100, gainDb: 1) }
        chain += [Self.compressor(), FX.dynamics()]
        await setInputEffects(rig, 1, chain)
        await rig.run(seconds: 0.2)
        let stateEffects = (await rig.sm.state).input(1)!.settings.effects
        XCTAssertFalse(stateEffects.contains { $0.id == "border" }, "border 格被状态机清掉")
        let fx = try XCTUnwrap(rig.engine.inputEffectsStatus(1))
        XCTAssertTrue(fx.eqEnabled); XCTAssertEqual(fx.eqBands, 16)
        XCTAssertEqual(fx.dynamicsKind, .compressor, "第一个动态占格，第二个（dynamicsProcessor）不装")
        XCTAssertEqual(fx.ignored, 3, "限幅、第 17 段、第二个动态")
        let notes = rig.engine.effectNotes.filter { $0.contains("输入 1") }
        XCTAssertEqual(notes.count, 3, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("peakLimiter") && $0.contains("没有限幅格") })
        XCTAssertTrue(notes.contains { $0.contains("最多 16 段") })
        XCTAssertTrue(notes.contains { $0.contains("dynamicsProcessor") && $0.contains("二选一") })
        await setInputEffects(rig, 1, chain)
        await rig.run(seconds: 0.1)
        XCTAssertEqual(rig.engine.effectNotes.filter { $0.contains("输入 1") }.count, 3)
        // 不认识的 id 真到了引擎（不经状态机）也只是不装 + 记一次
        let plan = InputEffectPlan.parse([EffectSlot(id: "border", params: ["width": .number(0.01)]), FX.eq(1000, gainDb: 1)])
        XCTAssertEqual(plan.ignored, 1); XCTAssertEqual(plan.bands.count, 1)
        XCTAssertTrue(plan.notes.contains { $0.message.contains("不认识的效果 id") })
        await rig.shutdown()
    }

    // MARK: - 压缩器：延迟自测进 EffectLatencyTimeline（testA2_compressor_latencyCompensated）

    /// Master 1 号格装压缩器：实测延迟 0 = 自报 0，click 在整秒；把探针换成"量到 48 帧"（模拟算法与自报不一致）：按量到的记（latencyFrames 48、日志一条），
    /// 泵把 Master 的 PTS 再减 48 帧 → click 早 1.0 ms（补偿路径确实走到了泵）。
    func testA2_compressor_latencyCompensated() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [Self.compressor(thresholdDb: 0, ratio: 4)]))   // 阈值 0：click −3 dBFS 不进压缩
        await rig.run(seconds: 5)
        let st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [nil, .compressor, nil])
        XCTAssertEqual(st.enabled, [false, true, false])
        XCTAssertEqual(st.latencyFrames, 0, "实测 = 自报 = 0")
        XCTAssertEqual(st.compressorMeasuredLatencyFrames, 0)
        XCTAssertTrue(rig.engine.effectNotes.allSatisfy { !$0.contains("延迟") }, "\(rig.engine.effectNotes)")
        var offsets = cap.clickOffsetsMs(t0: rig.t0)
        XCTAssertGreaterThanOrEqual(offsets.count, 3)
        for o in offsets { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "第 \(o.second) 秒") }
        // 模拟量到 48 帧
        CompressorLatencyProbe.measure = { _ in 48 }
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [Self.compressor(thresholdDb: 0, ratio: 2)]))
        await rig.run(seconds: 5)
        let st2 = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st2.latencyFrames, 48, "按量到的记")
        XCTAssertEqual(st2.compressorMeasuredLatencyFrames, 48)
        XCTAssertTrue(rig.engine.effectNotes.contains { $0.contains("48") && $0.contains("延迟") }, "\(rig.engine.effectNotes)")
        offsets = cap.clickOffsetsMs(t0: rig.t0).filter { $0.second >= 8 }
        XCTAssertGreaterThanOrEqual(offsets.count, 2)
        for o in offsets { XCTAssertEqual(o.offsetMs, 1.0, accuracy: 0.05, "泵按 48 帧补：click 早 1 ms（第 \(o.second) 秒）") }
        XCTAssertEqual(cap.gaps.count, 0, "PTS 连续（拼接）")
        XCTAssertEqual(rig.engine.status.consumers.first?.latencyFramesDropped, 48)
        await rig.shutdown()
    }

    /// 二选一：`compressor` 与 `dynamicsProcessor` 占同一格（1 号）；链里两个都有时第二个不装、记日志；来回换种类走换格流程。
    func testBusEffects_compressorAndDynamicsProcessorShareSlot() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [FX.eq(1000, gainDb: 3), Self.compressor(), FX.limiter()]))
        await rig.run(seconds: 0.2)
        var st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, .compressor, .peakLimiter])
        XCTAssertEqual(st.enabled, [true, true, true])
        XCTAssertEqual(st.ignored, 0)
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [FX.eq(1000, gainDb: 3), FX.dynamics(), Self.compressor(), FX.limiter()]))
        await rig.run(seconds: 0.5)
        st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [.nBandEQ, .dynamicsProcessor, .peakLimiter], "dynamicsProcessor 换进 1 号格，第二个动态（compressor）不装")
        XCTAssertEqual(st.ignored, 1)
        XCTAssertEqual(st.swaps, 1)
        XCTAssertTrue(rig.engine.effectNotes.contains { $0.contains("compressor") && $0.contains("二选一") }, "\(rig.engine.effectNotes)")
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [Self.compressor()]))
        await rig.run(seconds: 0.5)
        st = rig.engine.effectsStatus(.master)
        XCTAssertEqual(st.slots, [nil, .compressor, nil])
        XCTAssertEqual(st.swaps, 2)
        XCTAssertEqual(st.pendingSwaps, 0)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// `peakLimiter.ceilingDb`（024 顺带 (2)）：0 dBFS 正弦 → 预增益 +6 → 限幅 → 同一格内输出增益 −6：峰值 ≤ −6 + 0.3 dBFS，总线增益仍 0。
    func testA_busEffects_limiterCeilingDb() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, channels: 2, generator: FX.sine(1000, amplitude: 1.0))
        let cap = try rig.capture(.master)
        var lim = FX.limiter(attackSeconds: 0.002, decaySeconds: 0.024, preGainDb: 6)
        lim.params["ceilingDb"] = .number(-6)
        // 先让输入对齐、出声，再开限幅：AUPeakLimiter 在持续 +6 dB 过载的正弦上遇到对齐那一下的相位跳变会把增益收到 −34 dB 不回来（AU 自身行为，报告 §5）
        await rig.run(seconds: 1)
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [lim]))
        await rig.run(seconds: 1)
        var start = cap.left.count
        await rig.run(seconds: 1)
        let limited = IT.db(IT.peak(cap.left[start...]))
        XCTAssertLessThanOrEqual(limited, -6 + 0.3)
        XCTAssertGreaterThan(limited, -9)
        XCTAssertEqual(rig.engine.effectsStatus(.master).latencyFrames, 96)
        lim.params["ceilingDb"] = .number(-30)   // 越界：钳到 −20
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [lim]))
        await rig.run(seconds: 1)
        start = cap.left.count
        await rig.run(seconds: 1)
        XCTAssertLessThanOrEqual(IT.db(IT.peak(cap.left[start...])), -20 + 0.3)
        XCTAssertGreaterThan(IT.db(IT.peak(cap.left[start...])), -23)
        XCTAssertTrue(rig.engine.effectNotes.contains { $0.contains("ceilingDb") }, "\(rig.engine.effectNotes)")
        print("[W1-D3] ceilingDb −6：峰值 \(String(format: "%.3f", limited)) dBFS")
        await rig.shutdown()
    }

    // MARK: - 监听来源（提案 026）与借 Master 声道（X09）

    /// 状态里的 monitorSource（默认 master）落到混音器：耳机出口 = 所选总线；setMonitorSource(busA) 后 = Bus A；
    /// `borrowMasterForMonitor` + 独听 → Master 出口 = 耳机总线（独听信号），录制用的 Master 消费者流不变。
    func testMonitor_monitorSourceFromState_andBorrowMasterWhileSolo() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: FX.sine(1000, amplitude: 0.2))
        try rig.addSource(number: 2, generator: FX.sine(1500, amplitude: 0.2))
        await setInputEffects(rig, 2, [], routing: BusRouting(master: false, busA: true))
        var hp = [Float](), master = [Float](), busA = [Float]()
        rig.afterBlock = { b in
            hp.append(contentsOf: b.bus(.headphones).left); master.append(contentsOf: b.bus(.master).left); busA.append(contentsOf: b.bus(.busA).left)
        }
        let masterTap = try rig.capture(.master)
        await rig.run(seconds: 1)
        XCTAssertEqual(rig.engine.status.monitorSource, .master)
        hp.removeAll(); master.removeAll(); busA.removeAll()
        await rig.run(seconds: 0.5)
        XCTAssertEqual(hp, master, "默认监听 Master：耳机出口逐样本 = Master")
        _ = await rig.sm.apply(.setMonitorSource(bus: .busA))
        await rig.run(seconds: 0.2)
        XCTAssertEqual(rig.engine.status.monitorSource, .busA)
        hp.removeAll(); master.removeAll(); busA.removeAll()
        await rig.run(seconds: 0.5)
        XCTAssertEqual(hp, busA, "监听 Bus A：耳机出口逐样本 = Bus A")
        // 借 Master：独听输入 2 → Master 出口写耳机总线（1.5 kHz），消费者流仍是 Master（1 kHz）
        rig.engine.borrowMasterForMonitor = true
        XCTAssertTrue(rig.engine.borrowMasterForMonitor)
        await rig.run(seconds: 0.1)                       // 状态快照每 50 ms 刷一次
        XCTAssertTrue(rig.engine.status.borrowMasterForMonitor)
        var s2 = (await rig.sm.state).input(2)!.settings; s2.audio.solo = true
        _ = await rig.sm.apply(.setInputSettings(input: 2, settings: s2))
        await rig.run(seconds: 0.5)
        master.removeAll()
        let tapStart = masterTap.left.count
        await rig.run(seconds: 1)
        XCTAssertLessThan(IT.db(FX.amplitude(master[...], hz: 1000)), -80, "Master 出口上没有 1 kHz（写的是独听的耳机总线）")
        XCTAssertGreaterThan(IT.db(FX.amplitude(master[...], hz: 1500)), -30)
        XCTAssertGreaterThan(IT.db(FX.amplitude(masterTap.left[tapStart...], hz: 1000)), -30, "录制 / 推流拿的 Master 不受影响")
        s2.audio.solo = false
        _ = await rig.sm.apply(.setInputSettings(input: 2, settings: s2))
        await rig.run(seconds: 0.5)
        master.removeAll()
        await rig.run(seconds: 0.5)
        XCTAssertGreaterThan(IT.db(FX.amplitude(master[...], hz: 1000)), -30, "独听关：出口回到 Master")
        rig.engine.borrowMasterForMonitor = false
        await rig.run(seconds: 0.1)
        XCTAssertFalse(rig.engine.status.borrowMasterForMonitor)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }
}

extension InputEffectsIntegrationTests {
    /// W1-D4 第 4 条（prompt 125；reports/p5-contracts-4.md §5 第 3 条）：动态格换掉压缩器之后（换成 dynamicsProcessor / 链里只剩 EQ / 清空），
    /// 状态里的 `compressorMeasuredLatencyFrames` 回到 nil——文档注释"没装压缩器为 nil"。修前每路那一份留着上一次的实测值
    /// （`rack.measured` 是换回同一组参数时不重测的缓存）；换回压缩器又给出来。总线那一份跟着格里装着的效果走，一并钉住。
    /// 030 的 Stats（audio.effects.measured_latency_ms）一直按种类判，一并核对没受影响。
    func testW1D4_4_compressorSwappedOut_measuredLatencyBackToNil() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        func input() throws -> AudioEngineStatus.InputEffects { try XCTUnwrap(rig.engine.inputEffectsStatus(1)) }
        func snapshot() -> AudioEngineStatus.InputEffects? { rig.engine.status.inputs.first { $0.number == 1 }?.effects }
        // 每路：压缩器 → 有实测值
        await setInputEffects(rig, 1, [Self.compressor()])
        await rig.run(seconds: 0.2)
        XCTAssertEqual(try input().dynamicsKind, .compressor)
        let measured = try input().compressorMeasuredLatencyFrames
        XCTAssertNotNil(measured, "装着压缩器：有冲激法实测值")
        XCTAssertNotNil(rig.engine.audioCounters.effects.inputs[1]?.measuredLatencyMs)
        // 换成 dynamicsProcessor / 只剩 EQ / 清空：nil（状态快照里同一份）
        for (chain, what) in [([FX.dynamics()], "换成 dynamicsProcessor"), ([FX.eq(1000, gainDb: 3)], "只剩 EQ"), ([], "清空")] as [([EffectSlot], String)] {
            await setInputEffects(rig, 1, chain)
            await rig.run(seconds: 0.2)
            XCTAssertNotEqual(try input().dynamicsKind, .compressor, what)
            XCTAssertNil(try input().compressorMeasuredLatencyFrames, "\(what)：每路的压缩器实测值应回到 nil")
            XCTAssertNil(snapshot()?.compressorMeasuredLatencyFrames, "\(what)：状态快照里同一份")
            XCTAssertNil(rig.engine.audioCounters.effects.inputs[1]?.measuredLatencyMs, "\(what)：Stats 不列实测值（030 按种类判）")
        }
        // 换回压缩器（同一组参数，用缓存不重测）：又给出来
        await setInputEffects(rig, 1, [Self.compressor()])
        await rig.run(seconds: 0.2)
        XCTAssertEqual(try input().compressorMeasuredLatencyFrames, measured, "换回压缩器：实测值回来")
        // 总线：Master 的 1 号格装压缩器 → 有；换成 dynamicsProcessor（换格确认之后）/ 清空 → nil
        _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: [Self.compressor()]))
        await rig.run(seconds: 0.3)
        XCTAssertEqual(rig.engine.effectsStatus(.master).slots, [nil, .compressor, nil])
        XCTAssertNotNil(rig.engine.effectsStatus(.master).compressorMeasuredLatencyFrames)
        for (chain, what) in [([FX.dynamics()], "总线换成 dynamicsProcessor"), ([], "总线清空")] as [([EffectSlot], String)] {
            _ = await rig.sm.apply(.setBusEffects(bus: .master, effects: chain))
            await rig.run(seconds: 0.3)
            let st = rig.engine.effectsStatus(.master)
            XCTAssertEqual(st.pendingSwaps, 0, what)
            XCTAssertFalse(st.slots.contains(.compressor), what)
            XCTAssertNil(st.compressorMeasuredLatencyFrames, "\(what)：总线的压缩器实测值应是 nil")
            XCTAssertNil(rig.engine.audioCounters.effects.buses.first { $0.bus == Bus.master.name }?.measuredLatencyMs, "\(what)：Stats")
        }
        print("W1-D4 第 4 条：压缩器实测 \(measured.map(String.init) ?? "nil") 帧；换成 dynamicsProcessor / 只剩 EQ / 清空后每路与总线都是 nil，换回又是 \(measured.map(String.init) ?? "nil")")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }
}
