import XCTest
import CoreAudio
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 实时：空设备（W1-D 假设备时钟，CI）与真设备（系统默认输出，扬声器静音、Master 照常送消费者）。
/// 时长由环境变量控制（默认短跑）：SW_AUDIO_A1_SECONDS、SW_AUDIO_A2_SECONDS、SW_AUDIO_A3_REAL_SECONDS；真设备用例要 SW_AUDIO_REAL_DEVICE=1。
final class IntegrationRealtimeTests: XCTestCase {
    struct Rig {
        let sm: StateMachine
        let engine: AudioEngine
        let clock: TickClockSpec
        let t0: HostTime
        var sources: [Int: RealtimeSource] = [:]
    }

    func makeRig(output: AudioEngineConfiguration.Output, afv: Bool = false, configure: ((inout AudioEngineConfiguration) -> Void)? = nil) async throws -> Rig {
        let sm = StateMachine(initialState: States.fourInputs(afv: afv))
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = output
        cfg.outputChannelMap = BusChannelMap(master: nil)      // 真设备时扬声器静音
        configure?(&cfg)
        let engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        let clock = TickClockSpec(t0: t0, frameRate: .fps60)
        try await engine.start(clock: clock)
        return Rig(sm: sm, engine: engine, clock: clock, t0: t0)
    }

    func addSource(_ rig: inout Rig, number: Int, driftPpm: Double = 0, generator: ((Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) throws {
        let src = RealtimeSource(t0: rig.t0, driftPpm: driftPpm, generator: generator)
        var hints = AudioInputHints()
        hints.producerBlockFrames = 256
        try rig.engine.registerInput(number: number, ring: src.ring, hints: hints)
        rig.sources[number] = src
        src.start()
    }

    func shutdown(_ rig: Rig) async {
        for (_, s) in rig.sources { s.stop() }
        await rig.engine.stop()
        rig.sm.stop()
    }

    /// 状态机跟着墙钟走（引擎时钟的替身：渲染线程每拍 requestPrepare 下一拍）。
    func driveStateMachine(_ rig: Rig, until end: HostTime) async {
        while HostClock.now() < end {
            let tick = rig.clock.tick(at: HostClock.now()) + 1
            rig.sm.requestPrepare(tick)
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    // MARK: A1 / A2 空设备

    func testA1A2_nullDevice_clickOffsetAndContinuity() async throws {
        let seconds = IT.seconds("SW_AUDIO_A2_SECONDS", default: IT.seconds("SW_AUDIO_A1_SECONDS", default: 30))
        var rig = try await makeRig(output: .null)
        try addSource(&rig, number: 1)
        try addSource(&rig, number: 2, driftPpm: 100) { start, n, buf in
            for i in 0..<n { buf[i] = 0.2 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) }
        }
        let analyzer = StreamAnalyzer(name: "a1a2", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: seconds))
        let st = rig.engine.status
        let s = analyzer.summary
        print("""
            A1/A2 空设备 \(Int(seconds)) s：click \(s.count) 个，均值 \(String(format: "%.3f", s.meanMs)) ms（音频超前为正），σ \(String(format: "%.3f", s.stdMs))，\
            最大 |\(String(format: "%.3f", s.maxAbsMs))|，斜率 \(String(format: "%.5f", s.slopeMsPerS)) ms/s（× 8 h = \(String(format: "%.2f", s.slopeMsPerS * 28800)) ms）；\
            dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) 违规 \(st.realtimeViolations) tapDrops \(st.tapDrops)；\
            空设备块 \(st.device.callbacks) 最晚醒 \(String(format: "%.3f", st.device.maxJitterMs)) ms；源迟到 \(rig.sources.values.map { $0.late.load(ordering: .relaxed) })；\
            输入 \(st.inputs.map { "#\($0.number) age \(Int($0.ageSetpointFrames)) delay \($0.alignmentDelayFrames) ppm \(String(format: "%.1f", $0.ratioPpm))" })
            """)
        XCTAssertGreaterThanOrEqual(Double(s.count), seconds - 2)
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertEqual(analyzer.gaps, 0)
        XCTAssertLessThanOrEqual(abs(s.meanMs), 16.7, "A2 必须档")
        XCTAssertLessThanOrEqual(abs(s.meanMs), 5, "A2 目标档")
        XCTAssertLessThanOrEqual(s.maxAbsMs, 1, "空设备时钟 = host 时钟，对齐后应在 ±1 样本内")
        await shutdown(rig)
    }

    /// 增删输入 100 次（实时，空设备）：常驻路的 A1 = 0。
    func testLifecycle_nullDevice_addRemove100Times_A1Zero() async throws {
        var rig = try await makeRig(output: .null)
        try addSource(&rig, number: 1)
        let analyzer = StreamAnalyzer(name: "life", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        try await Task.sleep(for: .seconds(1))
        for k in 0..<100 {
            let src = RealtimeSource(t0: rig.t0) { start, n, buf in
                for i in 0..<n { buf[i] = 0.2 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) }
            }
            try rig.engine.registerInput(number: 2, ring: src.ring)
            src.start()
            try await Task.sleep(for: .milliseconds(120 + k % 50))
            rig.engine.unregisterInput(number: 2)
            try await Task.sleep(for: .milliseconds(40))
            src.stop()
            XCTAssertNil(rig.engine.slot(forInput: 2), "第 \(k) 次")
        }
        try await Task.sleep(for: .seconds(1))
        let st = rig.engine.status
        let s = analyzer.summary
        print("增删 100 次（空设备）：dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) 违规 \(st.realtimeViolations)；click 均值 \(String(format: "%.3f", s.meanMs)) 最大 \(String(format: "%.3f", s.maxAbsMs)) ms")
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertEqual(st.realtimeViolations, 0)
        XCTAssertLessThanOrEqual(s.maxAbsMs, 1)
        XCTAssertEqual(rig.engine.registeredInputs, [1])
        await shutdown(rig)
    }

    /// 实时 AFV：Fade 30 拍在空设备上由控制线程（不是手动循环）驱动，起点 / 长度对得上。
    func testAFV_nullDevice_controlThreadDeliversCrossfadeOnTime() async throws {
        var rig = try await makeRig(output: .null, afv: true)
        try addSource(&rig, number: 1) { start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) } }
        try addSource(&rig, number: 2) { start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) } }
        let cap2 = TimedCapture()
        try rig.engine.addConsumer(CaptureConsumer(name: "in2", capture: cap2), source: .inputProgram(number: 2))
        let s = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 30), at: s)
        await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: 4))
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: 30)
        // 起点：t_s 之前的两块为 0，含 t_s 的块开始有输出
        XCTAssertEqual(cap2.rms(from: tS - rig.engine.blockDuration * 2, to: tS - HostDuration(milliseconds: 0.1)), 0, accuracy: 1e-5)
        XCTAssertGreaterThan(cap2.rms(from: tS, to: tS + rig.engine.blockDuration), 0)
        // 中点 −3 dB（±0.5）
        let mid = tS + D / 2
        let base = 0.5 / sqrt(2.0) / sqrt(2.0)
        XCTAssertEqual(IT.db(cap2.rms(from: mid - rig.engine.blockDuration, to: mid + rig.engine.blockDuration) / base), -3.01, accuracy: 0.5)
        XCTAssertEqual(cap2.rms(from: tS + D + rig.engine.blockDuration * 2, to: tS + D + rig.engine.blockDuration * 6), base, accuracy: base * 0.03)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await shutdown(rig)
    }

    // MARK: 真设备

    func requireRealDevice() throws {
        guard IT.env["SW_AUDIO_REAL_DEVICE"] == "1" else {
            throw XCTSkip("真设备用例要 SW_AUDIO_REAL_DEVICE=1（用系统默认输出设备；扬声器静音）")
        }
        guard AudioHAL.defaultOutputDevice() != nil else { throw XCTSkip("没有默认输出设备") }
    }

    /// A2 真设备：click 相对整秒的偏移（音频超前为正），以及泵线程重采样测出的设备 ppm。
    func testA2A3_realDevice_clickOffsetMeanSignAndDevicePpm() async throws {
        try requireRealDevice()
        let seconds = IT.seconds("SW_AUDIO_A2_SECONDS", default: 60)
        var rig = try await makeRig(output: .systemDefault)
        try addSource(&rig, number: 1)
        let analyzer = StreamAnalyzer(name: "real", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: seconds))
        let st = rig.engine.status
        let s = analyzer.summary
        let dev = rig.engine.outputDevice!
        print("""
            A2/A3 真设备「\(dev.info.name)」buffer \(dev.actualBlockFrames) \(Int(seconds)) s：click \(s.count) 个，均值 \(String(format: "%.3f", s.meanMs)) ms（音频超前为正），\
            σ \(String(format: "%.3f", s.stdMs))，最大 |\(String(format: "%.3f", s.maxAbsMs))|，斜率 \(String(format: "%.5f", s.slopeMsPerS)) ms/s（× 8 h = \(String(format: "%.2f", s.slopeMsPerS * 28800)) ms）；\
            设备 ppm \(st.consumers.first?.devicePpm.map { String(format: "%.2f", $0) } ?? "—")，重采样比 \(st.consumers.first?.resampleRatio.map { String(format: "%.7f", $0) } ?? "—")，挨饿 \(st.consumers.first?.resamplerStarved ?? 0)；\
            dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities) 违规 \(st.realtimeViolations)；\
            回调 \(st.device.callbacks) 抖动 max \(String(format: "%.3f", st.device.maxJitterMs)) ms 重建 \(st.device.rebuilds)；\
            输入 \(st.inputs.map { "#\($0.number) age \(Int($0.ageSetpointFrames)) delay \($0.alignmentDelayFrames) ppm \(String(format: "%.1f", $0.ratioPpm))" })
            """)
        XCTAssertGreaterThanOrEqual(Double(s.count), seconds - 3)
        XCTAssertEqual(st.counters.dropouts, 0)
        XCTAssertEqual(st.counters.underruns, 0)
        XCTAssertEqual(analyzer.discontinuities, 0, "\(analyzer.recentDiscontinuities.prefix(5))")
        XCTAssertLessThanOrEqual(abs(s.meanMs), 16.7, "A2 必须档")
        XCTAssertLessThanOrEqual(abs(s.meanMs), 5, "A2 目标档")
        XCTAssertLessThanOrEqual(abs(s.slopeMsPerS * 28800), 16, "A3：斜率 × 8 h")
        await shutdown(rig)
    }

    /// A3 真设备长跑（1 小时要 SW_AUDIO_A3_REAL_SECONDS=3600）：不重采样的话设备 ppm × 时长会直接漂出来。
    func testA3_realDevice_longRunDrift() async throws {
        try requireRealDevice()
        guard let v = IT.env["SW_AUDIO_A3_REAL_SECONDS"], let seconds = Double(v) else { throw XCTSkip("要 SW_AUDIO_A3_REAL_SECONDS=秒数（1 小时 = 3600）") }
        var rig = try await makeRig(output: .systemDefault)
        try addSource(&rig, number: 1)
        let analyzer = StreamAnalyzer(name: "a3", t0: rig.t0)
        try rig.engine.addConsumer(analyzer, source: .master)
        await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: seconds))
        let st = rig.engine.status
        let s = analyzer.summary
        print("A3 真设备 \(Int(seconds)) s：均值 \(String(format: "%.3f", s.meanMs)) σ \(String(format: "%.3f", s.stdMs)) 最大 |\(String(format: "%.3f", s.maxAbsMs))| 斜率 \(String(format: "%.6f", s.slopeMsPerS)) ms/s × 8 h = \(String(format: "%.2f", s.slopeMsPerS * 28800)) ms；设备 ppm \(st.consumers.first?.devicePpm ?? .nan)；dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 不连续 \(analyzer.discontinuities)")
        XCTAssertLessThanOrEqual(abs(s.slopeMsPerS * 28800), 16)
        XCTAssertEqual(st.counters.dropouts + st.counters.underruns + analyzer.discontinuities, 0)
        await shutdown(rig)
    }

    // MARK: A5 监听延迟（回环线）

    /// A5：耳机输出用线回环到音频接口输入，发 click，测往返 / 2。要 SW_AUDIO_LOOPBACK_OUTPUT / SW_AUDIO_LOOPBACK_INPUT（设备名）；
    /// 输入设备要麦克风权限（W1-D 报告：没权限 AudioDeviceStart 等弹窗）。没有回环线 → BLOCKED-硬件。
    func testA5_monitorLatency_loopback() async throws {
        guard let outName = IT.env["SW_AUDIO_LOOPBACK_OUTPUT"], let inName = IT.env["SW_AUDIO_LOOPBACK_INPUT"] else {
            throw XCTSkip("BLOCKED-硬件：需要音频接口回环线（耳机出 → 线路入）；设 SW_AUDIO_LOOPBACK_OUTPUT / SW_AUDIO_LOOPBACK_INPUT 后跑")
        }
        guard let inInfo = AudioHAL.device(named: inName), inInfo.inputChannels > 0 else { throw XCTSkip("找不到输入设备 \(inName)") }
        // 对齐延迟用默认（2048 帧）：W1-D2 起耳机总线不经对齐延迟线（monitorPoint 默认 .preDelayLine），监听延迟 = 环年龄 + 设备；
        // 低延迟的部分只剩就绪目标 1 块、buffer 128（年龄 = 128 + 64 + 47 + 16 + 128 + 输出提前量（buffer 128 + 安全偏移）≈ 559 帧 = 11.6 ms，
        // 内置扬声器的安全偏移 48；再低用 hints.targetAgeFrames 指定）
        let sm = StateMachine(initialState: States.fourInputs(afv: false))
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = .device(name: outName)
        cfg.blockFrames = 128
        cfg.outputChannelMap = BusChannelMap(master: nil, headphones: (0, 1))   // 耳机总线 → 设备 0/1
        let engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        try await engine.start(clock: TickClockSpec(t0: t0, frameRate: .fps60))
        // 输入 1：合成 click，只送耳机；输入 2：回环采到的信号（纯输入设备 → 环）
        let click = RealtimeSource(t0: t0, blockFrames: 128)
        var h1 = AudioInputHints(); h1.producerBlockFrames = 128; h1.targetFramesOverride = 128
        try engine.registerInput(number: 1, ring: click.ring, hints: h1)
        var s1 = InputSettings(); s1.audio.routing = BusRouting(master: false, headphones: true)
        _ = await sm.apply(.setInputSettings(input: 1, settings: s1))
        let loopRing = CAudioRing(channelCount: 1)
        let inputDevice = try AudioInputDevice(deviceID: inInfo.id, ring: loopRing, channels: [0])
        var h2 = AudioInputHints(); h2.producerBlockFrames = 128; h2.targetFramesOverride = 128
        try engine.registerInput(number: 2, ring: loopRing, hints: h2)
        var s2 = InputSettings(); s2.audio.routing = BusRouting(master: false)
        _ = await sm.apply(.setInputSettings(input: 2, settings: s2))
        let returned = StreamAnalyzer(name: "loop", t0: t0)
        try engine.addConsumer(returned, source: .input(number: 2))
        click.start()
        try inputDevice.start(blockFrames: 128)
        try await Task.sleep(for: .seconds(12))
        click.stop()
        inputDevice.stop()
        let s = returned.summary
        // 回环里 click 相对发出时刻晚 = 往返；A5 = 往返 / 2（音频超前为正，所以取负）
        let roundTripMs = -s.meanMs
        let a5 = roundTripMs / 2
        let in1 = engine.status.inputs.first { $0.number == 1 }
        print("A5 回环：往返 \(String(format: "%.2f", roundTripMs)) ms（\(s.count) 个 click，σ \(String(format: "%.2f", s.stdMs))）→ 监听延迟 \(String(format: "%.2f", a5)) ms；输出设备延迟 \(engine.outputDevice?.outputLatencyFrames ?? 0) 帧，输入设备延迟 \(inputDevice.inputLatencyFrames) 帧；输入 1 年龄 \(in1?.ageSetpointFrames ?? -1) 帧（目标 \(in1?.targetAgeFrames ?? -1)）、对齐延迟线 \(in1?.alignmentDelayFrames ?? -1) 帧（耳机不走）")
        XCTAssertEqual(engine.configuration.alignmentFrames, 2048, "默认对齐配置")
        XCTAssertGreaterThan(s.count, 5)
        XCTAssertLessThanOrEqual(a5, 20, "A5 必须档（buffer 256）")
        await engine.stop()
        sm.stop()
    }
}
