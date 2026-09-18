import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 监听（PFL / AFL / 独听 / 延迟补偿 / 总线）从状态落到混音器；输入增删 100 次期间 A1 = 0；消费者扇出与 A4 多路对齐。
final class MonitoringAndLifecycleTests: XCTestCase {
    func sine(_ hz: Double, amplitude: Float = 0.5) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in
            for i in 0..<n { buf[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
        }
    }
    /// 单声道 0.5 幅正弦，居中声像后每边 RMS。
    let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)
    func dB(_ x: Double) -> Double { IT.db(x) }

    // MARK: 监听

    /// 独听 + PFL：耳机只有独听那一路、推子前电平；AFL：推子后；Master 不受独听影响；未独听但路由到耳机的路在有独听时听不到。
    func testMonitor_soloPFLandAFL_fromState() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        var s1 = InputSettings(); s1.audio.routing = BusRouting(master: true, headphones: true)
        var s2 = InputSettings(); s2.audio.gainDb = -6; s2.audio.solo = true
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s1))
        _ = await rig.sm.apply(.setInputSettings(input: 2, settings: s2))
        _ = await rig.sm.apply(.busGain(bus: .headphones, dB: 0))
        let hp = try rig.capture(.bus(.headphones)), master = try rig.capture(.master)
        let t1 = try rig.capture(.input(number: 1)), t2 = try rig.capture(.input(number: 2))
        // 默认 AFL
        await rig.run(seconds: 1)
        var (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertEqual(dB(hp.rms(from: a, to: b) / baseRMS), -6, accuracy: 0.3, "AFL：耳机 = 独听路推子后（−6 dB）")
        XCTAssertEqual(dB(master.rms(from: a, to: b) / baseRMS), dB(sqrt(1 + pow(10, -0.6))), accuracy: 0.3, "Master 两路功率相加，不受独听影响")
        XCTAssertEqual(dB(t1.rms(from: a, to: b) / baseRMS), 0, accuracy: 0.3)
        XCTAssertEqual(dB(t2.rms(from: a, to: b) / baseRMS), -6, accuracy: 0.3)
        // 切到 PFL：推子前，不受 −6 dB 影响；单声道推子前不经声像（每边满）
        var st = await rig.sm.state
        st.audio.monitorMode = .pfl
        _ = await rig.sm.apply(.loadShow(show: Show(name: "pfl", state: st)))
        await rig.run(seconds: 1)
        (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertEqual(dB(hp.rms(from: a, to: b) / (0.5 / sqrt(2.0))), 0, accuracy: 0.3, "PFL：耳机 = 独听路推子前")
        // 取消独听：耳机按路由（输入 1 路由到耳机，输入 2 没有）
        s2.audio.solo = false
        _ = await rig.sm.apply(.setInputSettings(input: 2, settings: s2))
        await rig.run(seconds: 1)
        (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertEqual(dB(hp.rms(from: a, to: b) / baseRMS), 0, accuracy: 0.3, "无独听：耳机 = 路由到耳机的输入 1")
        XCTAssertEqual(rig.engine.status.monitorMode, .pfl)
        await rig.shutdown()
    }

    /// 总线增益 / 静音、每路增益 / 静音 / 声像从状态落地。
    func testMonitor_busAndInputParametersFromState() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: sine(1000))
        let master = try rig.capture(.master), busA = try rig.capture(.bus(.busA))
        var s1 = InputSettings(); s1.audio.routing = BusRouting(master: true, busA: true); s1.audio.pan = -1   // 全左
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s1))
        _ = await rig.sm.apply(.busGain(bus: .master, dB: -12))
        _ = await rig.sm.apply(.audioGain(input: 1, dB: 6))
        await rig.run(seconds: 1)
        var (a, b) = rig.lastDeliveredWindow(blocks: 8)
        // 全左：左声道 = 0.5 × 推子 +6 dB（等功率声像全左 = 1.0）
        let leftRMS = master.rms(from: a, to: b)
        XCTAssertEqual(dB(leftRMS / (0.5 / sqrt(2.0))), 6 - 12, accuracy: 0.3, "Master 左 = 输入 +6 dB，总线 −12 dB")
        XCTAssertEqual(dB(busA.rms(from: a, to: b) / (0.5 / sqrt(2.0))), 6, accuracy: 0.3, "Bus A 总线 0 dB")
        let rightRMS = IT.rms(master.right[(master.right.count - 2048)...])
        XCTAssertLessThan(rightRMS, 1e-4, "全左时右声道为 0")
        _ = await rig.sm.apply(.busMute(bus: .master, on: true))
        _ = await rig.sm.apply(.mute(input: 1, on: false))
        await rig.run(seconds: 0.5)
        (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertLessThan(master.rms(from: a, to: b), 1e-4, "Master 静音")
        XCTAssertEqual(dB(busA.rms(from: a, to: b) / (0.5 / sqrt(2.0))), 6, accuracy: 0.3, "Bus A 不受 Master 静音影响")
        _ = await rig.sm.apply(.busMute(bus: .master, on: false))
        _ = await rig.sm.apply(.mute(input: 1, on: true))
        await rig.run(seconds: 0.5)
        (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertLessThan(busA.rms(from: a, to: b), 1e-4, "输入静音后哪条总线都没有它")
        let st = rig.engine.status
        XCTAssertEqual(st.buses[0].gainDb, -12)
        XCTAssertFalse(st.buses[0].muted)
        await rig.shutdown()
    }

    /// 延迟补偿经状态机命令生效（对齐之上 +120 ms），改回 0 也生效。
    func testMonitor_delayCompensationCommandMovesClick() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let cap = try rig.capture(.master)
        await rig.run(seconds: 3)
        var s = InputSettings(); s.audio.delayMs = 120
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        await rig.run(seconds: 3)
        s.audio.delayMs = 0
        _ = await rig.sm.apply(.setInputSettings(input: 1, settings: s))
        await rig.run(seconds: 3)
        let offsets = cap.clickOffsetsMs(t0: rig.t0)
        let early = offsets.filter { $0.second <= 2 }, mid = offsets.filter { (4...5).contains($0.second) }, late = offsets.filter { $0.second >= 7 }
        XCTAssertFalse(early.isEmpty); XCTAssertFalse(mid.isEmpty); XCTAssertFalse(late.isEmpty)
        for o in early { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "\(o)") }
        for o in mid { XCTAssertEqual(o.offsetMs, -120, accuracy: 0.05, "\(o)") }
        for o in late { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "\(o)") }
        await rig.shutdown()
    }

    /// P2（提案 004）：Stats.audio 带 discontinuities 与表读数，与 status 同源（AudioMixer.meters）；静音处钳到 −120 而不是 −inf，整行能写成 JSON。
    func testP2_audioCounters_carryMetersAndDiscontinuities() async throws {
        let rig = try await EngineRig(state: States.fourInputs())
        try rig.addSource(number: 1)
        try rig.addSource(number: 2)
        try rig.capture(.master)
        await rig.run(seconds: 2)
        let c = rig.engine.audioCounters, st = rig.engine.status
        XCTAssertEqual([c.dropouts, c.underruns, c.discontinuities], [st.counters.dropouts, st.counters.underruns, st.discontinuities])
        XCTAssertEqual(c.meters.buses.map(\.bus), Bus.allCases.map(\.name))
        XCTAssertGreaterThan(c.meters.buses[0].peakDb[0], -30, "Master 上有 1 号的 1 kHz −20 dBFS")
        XCTAssertEqual(c.meters.buses[0].peakDb[0], st.buses[0].peakDb[0], accuracy: 1e-9)
        XCTAssertGreaterThan(c.meters.buses[0].lufsM, -60)
        XCTAssertTrue(c.meters.buses.allSatisfy { b in (b.peakDb + b.truePeakDb + [b.lufsM, b.lufsS, b.lufsI, b.lra]).allSatisfy { $0.isFinite && $0 >= -120 } })
        XCTAssertEqual(Set(c.meters.inputs.keys), [1, 2])
        XCTAssertGreaterThan(c.meters.inputs[1]!.peakDb[0], -30)
        XCTAssertLessThan(c.meters.inputs[2]!.peakDb[0], -90, "AFV 开着，非 PGM 的 2 号推子后是静音")
        let row = Stats(ts: 0, tick: .zero, renderMs: 0, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [], audio: c, rssMb: 0, cpuPct: 0, gpuPct: 0)
        XCTAssertEqual(try Stats.parse(line: try row.jsonLine()).audio, c)
        await rig.shutdown()
    }

    // MARK: 增删输入

    /// 增删 100 次：另一路持续播放的 Master 上 dropouts / underruns / 不连续 = 0，实时违规 0；摘除先淡出再 detach，环在确认后释放。
    func testLifecycle_addRemove100Times_offline_A1Zero() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)      // 常驻：click 信号
        let cap = try rig.capture(.master)
        await rig.run(seconds: 2)
        for k in 0..<100 {
            try rig.addSource(number: 2, generator: sine(1500, amplitude: 0.3))
            await rig.run(blocks: 40 + (k % 7))                 // 就绪 + 对齐 + 出声
            rig.engine.unregisterInput(number: 2, now: rig.driver.nextBlockHostTime)
            await rig.run(blocks: 8)                            // 淡出 3 块 + detach
            rig.sources.removeValue(forKey: 2)
            XCTAssertNil(rig.engine.slot(forInput: 2), "第 \(k) 次摘除后槽位已释放")
        }
        await rig.run(seconds: 1)
        let st = rig.engine.status
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertEqual(st.discontinuities, 0, "泵线程的流式检测（平台启发式排除 click）")
        // 离线口径：整段 Master 用已知 click 位置排除后不连续为 0；常驻路的 click 全程对齐
        let sig = TestSignal(t0: rig.t0)
        let first = cap.firstHostTime!
        let offsetSamples = Int64(((first - rig.t0).seconds * 48000).rounded())
        let events = DiscontinuityDetector.analyze(samples: cap.left) { sig.isClick(sampleIndex: $0 + offsetSamples) }
        XCTAssertEqual(events.count, 0, "\(events.prefix(5))")
        for o in cap.clickOffsetsMs(t0: rig.t0) { XCTAssertEqual(o.offsetMs, 0, accuracy: 0.05, "\(o)") }
        XCTAssertEqual(rig.engine.registeredInputs, [1])
        await rig.shutdown()
    }

    /// 摘除的那一路先淡出（3 ms）再 detach：它的最后几块电平单调下降到 0，没有硬切。
    func testLifecycle_removalFadesOutBeforeDetach() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: sine(1000))
        var peaks: [Float] = []
        rig.afterBlock = { b in peaks.append(b.bus(.master).left.reduce(0) { max($0, abs($1)) }) }
        await rig.run(seconds: 1)
        peaks.removeAll()
        rig.engine.unregisterInput(number: 1, now: rig.driver.nextBlockHostTime)
        await rig.run(blocks: 10)
        // 第一块内从满电平往下淡（3 ms 时间常数：一块后 ≈ e^−1.78 = 17%），第 3 块后 < 1%，detach 之后全 0
        XCTAssertGreaterThan(peaks[0], 0.2)
        XCTAssertLessThan(peaks[1], 0.1)
        XCTAssertLessThan(peaks[3], 0.005)
        XCTAssertEqual(peaks[6], 0)
        XCTAssertNil(rig.engine.slot(forInput: 1))
        await rig.shutdown()
    }

    /// 状态机删掉输入（removeInput）也会摘掉它的音频。
    func testLifecycle_removeInputCommandDetachesAudio() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 3, generator: sine(1000))
        let master = try rig.capture(.master)
        await rig.run(seconds: 1)
        _ = await rig.sm.apply(.removeInput(input: 3))
        await rig.run(seconds: 0.5)
        XCTAssertNil(rig.engine.slot(forInput: 3))
        let (a, b) = rig.lastDeliveredWindow(blocks: 8)
        XCTAssertLessThan(master.rms(from: a, to: b), 1e-4)
        await rig.shutdown()
    }

    // MARK: 消费者

    /// 同一来源两个消费者共享一个 tap（扇出），两边收到完全相同的块与 PTS。
    func testConsumer_fanOutSharesOneTap() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1)
        let c1 = TimedCapture(), c2 = TimedCapture()
        let k1 = CaptureConsumer(name: "a", capture: c1), k2 = CaptureConsumer(name: "b", capture: c2)
        let tok1 = try rig.engine.addConsumer(k1, source: .master)
        let tok2 = try rig.engine.addConsumer(k2, source: .bus(.master))
        await rig.run(seconds: 1)
        XCTAssertEqual(c1.blocks, c2.blocks)
        XCTAssertEqual(c1.left, c2.left)
        XCTAssertEqual(c1.firstHostTime, c2.firstHostTime)
        XCTAssertEqual(rig.engine.status.consumers.count, 1, "一个来源一个 tap")
        XCTAssertEqual(rig.engine.status.consumers.first?.consumers.sorted(), ["a", "b"])
        rig.engine.removeConsumer(tok1)
        await rig.run(seconds: 0.2)
        XCTAssertEqual(rig.engine.status.consumers.count, 1)
        rig.engine.removeConsumer(tok2)
        await rig.run(seconds: 0.2)
        XCTAssertEqual(rig.engine.status.consumers.count, 0, "没人要了就摘 tap")
        XCTAssertEqual(rig.engine.status.tapDrops, 0)
        await rig.shutdown()
    }

    /// A4（音频部分）：4 路各自的 ISO tap（各带 click、时钟 0 / +100 / −100 / +50 ppm），同一事件在四路流里的时刻差 ≤ 1 ms（目标），
    /// 且都对齐到源时刻（与 Master 同一时间轴）。视频 ISO 由 W3-C 做；这里 4 路共用同一节目时钟的 click，就是 frameprobe av 多文件比的东西。
    func testA4_fourISOTaps_sameEventWithin1ms() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        let drifts: [Double] = [0, 100, -100, 50]
        for (i, d) in drifts.enumerated() { try rig.addSource(number: i + 1, driftPpm: d) }
        var caps: [TimedCapture] = []
        for n in 1...4 { caps.append(try rig.capture(.input(number: n))) }
        await rig.run(seconds: 20)
        var offsets: [[(second: Int, offsetMs: Double)]] = caps.map { $0.clickOffsetsMs(t0: rig.t0) }
        for (i, o) in offsets.enumerated() { XCTAssertGreaterThanOrEqual(o.count, 17, "输入 \(i + 1)：\(o.count) 个 click") }
        var maxSpread = 0.0
        for k in 14...18 {
            let atK = offsets.compactMap { list in list.first { $0.second == k }?.offsetMs }
            XCTAssertEqual(atK.count, 4)
            let spread = (atK.max() ?? 0) - (atK.min() ?? 0)
            maxSpread = max(maxSpread, spread)
            for o in atK { XCTAssertEqual(o, 0, accuracy: 0.1, "第 \(k) 秒：\(atK)") }
        }
        XCTAssertLessThanOrEqual(maxSpread, 1.0, "A4 目标 1 ms；实测极差 \(maxSpread) ms")
        print("A4 四路 ISO tap 同一事件极差 \(String(format: "%.3f", maxSpread)) ms")
        offsets.removeAll()
        let st = rig.engine.status
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(st.consumers.count, 4)
        await rig.shutdown()
    }

    /// 没注册的输入不能当 ISO 来源；最多 8 个来源。
    func testConsumer_errors() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        let c = CaptureConsumer(name: "x", capture: TimedCapture())
        XCTAssertThrowsError(try rig.engine.addConsumer(c, source: .input(number: 9))) { e in
            XCTAssertEqual(e as? AudioEngineError, .inputNotRegistered(9))
        }
        let ring = CAudioRing(channelCount: 1)
        try rig.engine.registerInput(number: 1, ring: ring)
        XCTAssertThrowsError(try rig.engine.registerInput(number: 1, ring: ring)) { e in
            XCTAssertEqual(e as? AudioEngineError, .inputAlreadyRegistered(1))
        }
        await rig.shutdown()
    }
}
