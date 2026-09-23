import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// AFV（设计方案 §7）：转场事件 → 同一拍点的 host time 起做等幅交叉淡变，长度 = 转场时长；Cut = 1 块短淡；T-bar 跟推杆；FTB 淡出 Master。
/// 量法：每路输入挂"推子后、AFV 后"的 tap（`.inputProgram`，= 它送进节目总线的信号），逐块 RMS 与等幅曲线比；起点与视频转场同一拍。
/// （`.input(number:)` 从 W1-D2 起是 ISO 口径：推子后、AFV 前，见 MonitoringAndLifecycleTests.testISO_*。）
final class AFVTests: XCTestCase {
    /// 纯正弦生成器（无 click，便于量电平）。
    func sine(_ hz: Double, amplitude: Float = 0.5) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in
            for i in 0..<n { buf[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
        }
    }
    /// 单声道 0.5 幅正弦，居中声像（每边 −3 dB）后的稳态 RMS。
    let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)

    struct BlockLevel { let start: HostTime; let end: HostTime; let rms1: Double; let rms2: Double; let rmsMaster: Double }

    /// 搭台：输入 1（1 kHz）PGM、输入 2（1.5 kHz）PVW，AFV 开；每块记录两路 tap 与 Master 的 RMS。
    func makeRig(frameRate: FrameRate = .fps60) async throws -> (EngineRig, TimedCapture, TimedCapture, TimedCapture) {
        let rig = try await EngineRig(state: States.fourInputs(afv: true, frameRate: frameRate), frameRate: frameRate)
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        let c1 = try rig.capture(.inputProgram(number: 1))
        let c2 = try rig.capture(.inputProgram(number: 2))
        let cm = try rig.capture(.master)
        return (rig, c1, c2, cm)
    }

    /// 逐块电平（按 host time 切块，与混音块对齐）。
    func levels(_ rig: EngineRig, _ c1: TimedCapture, _ c2: TimedCapture, _ cm: TimedCapture, from: HostTime, to: HostTime) -> [BlockLevel] {
        var out: [BlockLevel] = []
        var t = from
        while t < to {
            let e = t + rig.engine.blockDuration
            out.append(BlockLevel(start: t, end: e, rms1: c1.rms(from: t, to: e), rms2: c2.rms(from: t, to: e), rmsMaster: cm.rms(from: t, to: e)))
            t = e
        }
        return out
    }

    func dB(_ x: Double) -> Double { IT.db(x) }

    /// 等幅曲线在一块 [t1, t2) 上的 RMS 增益：对块积分而不是取块中心（cos / sin 在 −40 dB 附近一块之内变化 10%+，
    /// 取中心值本身就有 ~0.9 dB 的模型误差）。cos² 的均值 = 1/2 + (sin πp₂ − sin πp₁) / (2π(p₂ − p₁))，sin² 反号。
    func curveRMS(from t1: HostTime, to t2: HostTime, tS: HostTime, D: HostDuration, toPath: Bool) -> Double {
        let p1 = Double((t1 - tS).ticks) / Double(D.ticks), p2 = Double((t2 - tS).ticks) / Double(D.ticks)
        let term = (sin(.pi * p2) - sin(.pi * p1)) / (2 * .pi * (p2 - p1))
        return sqrt(max(0, 0.5 + (toPath ? -term : term)))
    }

    // MARK: 每路 AFV 参与开关（用户 2026-09-22 批）

    /// 某路 `InputAudioSettings.afv = false`：门控增益恒 1，PGM 切走不变、转场中不进交叉淡变；
    /// 全局 `AudioState.afv` 关 / 开两种都验一遍。
    func testA_afvPerInputOffKeepsGainOne() async throws {
        // 3 号不跟随视频（主持人话筒）；1 号 PGM、2 号 PVW 正常参与
        var state = States.fourInputs(afv: true)
        state.inputs[2].settings.audio.afv = false
        let rig = try await EngineRig(state: state)
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        try rig.addSource(number: 3, generator: sine(2000))
        let c3 = try rig.capture(.inputProgram(number: 3))

        func gain(_ n: Int) -> Float {
            rig.engine.status.inputs.first { $0.number == n }?.afvGain ?? -1
        }

        // 1. 空闲：3 号恒 1，2 号（PVW，参与门控）是 0
        await rig.run(seconds: 0.5)
        XCTAssertEqual(gain(3), 1, "afv = false 的路门控增益恒 1")
        XCTAssertEqual(gain(1), 1, "PGM")
        XCTAssertEqual(gain(2), 0, "PVW 参与门控 → 0")
        let idleRMS = c3.rms(from: rig.t0 + rig.engine.blockDuration * 8, to: rig.t0 + rig.engine.blockDuration * 32)
        XCTAssertEqual(idleRMS, baseRMS, accuracy: baseRMS * 0.05, "3 号一直按推子出声")

        // 2. 转场 1 → 2：3 号不进 from / to，电平不动
        let s = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 30), at: s)
        await rig.run(seconds: 3)
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: 30)
        var t = tS
        while t < tS + D {
            let e = t + rig.engine.blockDuration
            XCTAssertEqual(c3.rms(from: t, to: e), baseRMS, accuracy: baseRMS * 0.05,
                           "转场中 3 号电平应不动（\((t - tS).milliseconds) ms）")
            t = e
        }
        XCTAssertEqual(gain(3), 1, "转场结束后仍是 1")
        XCTAssertEqual(gain(2), 1, "转场完成，2 号成了 PGM")
        XCTAssertEqual(gain(1), 0)
        // 转场之后一直到结束都不动
        XCTAssertEqual(c3.rms(from: tS + D, to: tS + D + rig.engine.blockDuration * 16), baseRMS, accuracy: baseRMS * 0.05)

        // 3. 全局 AFV 关：全部 1（每路那一位不起作用）。此时已跑到约 3.5 s ≈ 210 拍，所以排在 300 拍并多跑 2 s
        await rig.sm.schedule(.setAFV(on: false), at: Tick(300))
        await rig.run(seconds: 2)
        for n in 1...3 { XCTAssertEqual(gain(n), 1, "全局 AFV 关 → \(n) 号恒 1") }

        // 4. 全局 AFV 再开：3 号还是 1，别的按 PGM / PVW 门控（此时 PGM = 2）
        await rig.sm.schedule(.setAFV(on: true), at: Tick(420))
        await rig.run(seconds: 2)
        XCTAssertEqual(gain(3), 1)
        XCTAssertEqual(gain(2), 1)
        XCTAssertEqual(gain(1), 0)
        await rig.shutdown()
    }

    /// 运行中翻某路的 afv 位（走 setInputSettings）：立刻重算该路的门控增益。
    func testA_afvPerInputToggleAtRuntime() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: true))
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 3, generator: sine(2000))
        func gain(_ n: Int) -> Float { rig.engine.status.inputs.first { $0.number == n }?.afvGain ?? -1 }
        await rig.run(seconds: 0.5)
        XCTAssertEqual(gain(3), 0, "3 号不在 PGM / PVW 上、参与门控 → 0")
        // 关掉 3 号的 afv → 立刻变 1
        var settings = InputSettings()
        settings.audio.afv = false
        await rig.sm.schedule(.setInputSettings(input: 3, settings: settings), at: Tick(60))
        await rig.run(seconds: 1.5)
        XCTAssertEqual(gain(3), 1, "afv 关掉后门控增益立刻回 1")
        // 再打开 → 回 0
        await rig.sm.schedule(.setInputSettings(input: 3, settings: InputSettings()), at: Tick(120))
        await rig.run(seconds: 1.5)
        XCTAssertEqual(gain(3), 0)
        await rig.shutdown()
    }

    // MARK: Fade 30 拍

    func testAFV_fade30_levelsFollowEqualPowerCurveWithin0_5dB_onsetOnTheTransitionTick() async throws {
        let (rig, c1, c2, cm) = try await makeRig()
        let s = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 30), at: s)
        await rig.run(seconds: 4)
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: 30)
        XCTAssertEqual(D.milliseconds, 500, accuracy: 0.01)
        let blocks = levels(rig, c1, c2, cm, from: tS - rig.engine.blockDuration * 4, to: tS + D + rig.engine.blockDuration * 4)
        // 1. 起点：t_s 之前的块输入 2 严格为 0；含 t_s 的块开始有输入 2 → 起点误差 ≤ 1 块
        let before = blocks.filter { $0.end <= tS }
        XCTAssertFalse(before.isEmpty)
        for b in before { XCTAssertEqual(b.rms2, 0, "t_s 之前 PVW 输入应静音"); XCTAssertEqual(b.rms1, baseRMS, accuracy: baseRMS * 0.02) }
        let onset = try XCTUnwrap(blocks.first { $0.rms2 > 0 })
        XCTAssertTrue(onset.start <= tS && tS < onset.end, "音频电平开始变化的块 [\(onset.start.milliseconds - tS.milliseconds), \(onset.end.milliseconds - tS.milliseconds)) ms 应含 t_s")
        // 2. 曲线：逐块（块中心时刻）与 cos / sin 比，期望增益 ≥ −40 dB（0.01）的块误差 ≤ 0.5 dB（W1-D2 起淡变收帧数，
        //    500 ms = 24000 帧精确；W2-E 时只能判到 −20 dB，−20…−40 dB 的尾巴因整块量化有 0.5–0.9 dB）。
        var maxErr = 0.0, tailErr = 0.0, centerTailErr = 0.0
        var compared = 0, comparedTail = 0
        for b in blocks where b.start >= tS + rig.engine.blockDuration && b.end <= tS + D - rig.engine.blockDuration {
            let p = Double((b.start + (b.end - b.start) / 2 - tS).ticks) / Double(D.ticks)
            let gFrom = curveRMS(from: b.start, to: b.end, tS: tS, D: D, toPath: false)
            let gTo = curveRMS(from: b.start, to: b.end, tS: tS, D: D, toPath: true)
            for (rms, g, name) in [(b.rms2, gTo, "to"), (b.rms1, gFrom, "from")] where g >= 0.01 {
                let err = dB(rms / (baseRMS * g))
                XCTAssertEqual(err, 0, accuracy: 0.5, "p = \(p) \(name) 增益 \(dB(g)) dB 误差 \(err) dB")
                if g >= 0.1 { maxErr = max(maxErr, abs(err)); compared += 1 } else { tailErr = max(tailErr, abs(err)); comparedTail += 1 }
            }
            // 对照：W2-E 的块中心模型（cos / sin 取块中心）在同一段尾巴上的误差——那 0.5–0.9 dB 大半是模型自己的（块内变化 10%+），报告用
            let gFromC = cos(p * Double.pi / 2)
            if gFromC >= 0.01 && gFromC < 0.1 { centerTailErr = max(centerTailErr, abs(dB(b.rms1 / (baseRMS * gFromC)))) }
            // 等幅：不同频率的两路功率相加 → Master 功率恒定
            XCTAssertEqual(dB(b.rmsMaster / baseRMS), 0, accuracy: 0.5, "p = \(p) Master 电平 \(dB(b.rmsMaster / baseRMS)) dB")
        }
        XCTAssertGreaterThan(compared, 150)
        XCTAssertGreaterThanOrEqual(comparedTail, 4, "−20…−40 dB 之间应有块被判到")
        print("AFV fade30：逐块最大误差 \(String(format: "%.3f", maxErr)) dB（\(compared) 块，≥ −20 dB）；−20…−40 dB 尾巴最大 \(String(format: "%.3f", tailErr)) dB（\(comparedTail) 块，块积分模型；按 W2-E 的块中心模型算是 \(String(format: "%.3f", centerTailErr)) dB）")
        // 3. 与视频对照：首个混合帧是第 s + 1 拍（progress 1/30），此时 to 增益 = sin(π/2 × 1/30)；含 t_{s+1} 的块电平与它一致
        let t1 = rig.clock.time(of: s + 1)
        let frameBlock = try XCTUnwrap(blocks.first { $0.start <= t1 && t1 < $0.end })
        let expectedTo = sin(Double.pi / 2 * (Double((frameBlock.start + (frameBlock.end - frameBlock.start) / 2 - tS).ticks) / Double(D.ticks)))
        XCTAssertEqual(dB(frameBlock.rms2 / (baseRMS * expectedTo)), 0, accuracy: 0.5)
        // 4. 终点：含 t_s + D 的块之后 from 严格为 0（W1-D2：终值不再被最后一个曲线样本覆盖）、to 满
        let after = blocks.filter { $0.start >= tS + D + rig.engine.blockDuration }
        XCTAssertFalse(after.isEmpty)
        for b in after { XCTAssertEqual(b.rms1, 0, "\((b.start - tS - D).milliseconds) ms：from 应严格 0"); XCTAssertEqual(b.rms2, baseRMS, accuracy: baseRMS * 0.02) }
        // 状态机对调后 PGM = 2
        let state = await rig.sm.state
        XCTAssertEqual(state.program, 2)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    func testAFV_fade30_at5994_durationIsRational500_5ms() async throws {
        let (rig, c1, c2, cm) = try await makeRig(frameRate: .fps5994)
        let s = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 30), at: s)
        await rig.run(seconds: 4)
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: 30)
        XCTAssertEqual(D.milliseconds, 500.5, accuracy: 0.01)
        let blocks = levels(rig, c1, c2, cm, from: tS - rig.engine.blockDuration * 2, to: tS + D + rig.engine.blockDuration * 3)
        let onset = try XCTUnwrap(blocks.first { $0.rms2 > 0 })
        XCTAssertTrue(onset.start <= tS && tS < onset.end)
        var compared = 0
        for b in blocks where b.start >= tS + rig.engine.blockDuration && b.end <= tS + D - rig.engine.blockDuration {
            let p = Double((b.start + (b.end - b.start) / 2 - tS).ticks) / Double(D.ticks)
            let gTo = curveRMS(from: b.start, to: b.end, tS: tS, D: D, toPath: true)
            let gFrom = curveRMS(from: b.start, to: b.end, tS: tS, D: D, toPath: false)
            if gTo >= 0.01 { XCTAssertEqual(dB(b.rms2 / (baseRMS * gTo)), 0, accuracy: 0.5, "p = \(p) to"); compared += 1 }
            if gFrom >= 0.01 { XCTAssertEqual(dB(b.rms1 / (baseRMS * gFrom)), 0, accuracy: 0.5, "p = \(p) from"); compared += 1 }
        }
        XCTAssertGreaterThan(compared, 170)
        // 500.5 ms = 24024 帧：终点块之后 from 严格 0
        for b in blocks where b.start >= tS + D + rig.engine.blockDuration { XCTAssertEqual(b.rms1, 0, "\((b.start - tS - D).milliseconds) ms") }
        await rig.shutdown()
    }

    // MARK: Cut

    func testAFV_cut_switchesWithinOneBlockAtTheTickTime_noClickFade() async throws {
        let (rig, c1, c2, cm) = try await makeRig()
        let s = Tick(120)
        await rig.sm.schedule(.cut, at: s)
        await rig.run(seconds: 3)
        let tS = rig.clock.time(of: s)
        let blocks = levels(rig, c1, c2, cm, from: tS - rig.engine.blockDuration * 3, to: tS + rig.engine.blockDuration * 4)
        for b in blocks where b.end <= tS { XCTAssertEqual(b.rms2, 0); XCTAssertEqual(b.rms1, baseRMS, accuracy: baseRMS * 0.02) }
        let cutBlock = try XCTUnwrap(blocks.first { $0.start <= tS && tS < $0.end })
        XCTAssertGreaterThan(cutBlock.rms2, 0, "含 t_s 的块里输入 2 已经开始进来")
        // 1 块短淡（256 帧）从 t_s 所在块中间起、在下一块里走满：再下一块起 from 严格为 0（W1-D2：不再有 −44 dB、τ 3 ms 的尾巴）
        for b in blocks where b.start >= cutBlock.end + rig.engine.blockDuration {
            XCTAssertEqual(b.rms1, 0, "\((b.start - tS).milliseconds) ms：from 应严格 0")
            XCTAssertEqual(b.rms2, baseRMS, accuracy: baseRMS * 0.02)
        }
        // 短淡是等幅的：Master 电平不塌
        for b in blocks { XCTAssertEqual(dB(b.rmsMaster / baseRMS), 0, accuracy: 1.0, "\((b.start - tS).milliseconds) ms") }
        await rig.shutdown()
    }

    // MARK: T-bar

    func testAFV_tbar_gainsFollowTheBar() async throws {
        let (rig, c1, c2, _) = try await makeRig()
        await rig.run(seconds: 1)
        // 推杆位置晚对齐延迟才作用到音频（内容时间轴）：每次推完跑 对齐 + 平滑 + 余量，再量 PTS 前沿之前的 4 块
        let settle = Int(rig.engine.alignmentDuration.ticks / rig.engine.blockDuration.ticks) + 8
        for p in [0.25, 0.5, 0.75] {
            _ = await rig.sm.apply(.tbar(progress: p))
            await rig.run(blocks: settle)
            let (a, b) = rig.lastDeliveredWindow(blocks: 4)
            let r1 = c1.rms(from: a, to: b), r2 = c2.rms(from: a, to: b)
            XCTAssertEqual(dB(r1 / (baseRMS * cos(p * Double.pi / 2))), 0, accuracy: 0.5, "p = \(p) from")
            XCTAssertEqual(dB(r2 / (baseRMS * sin(p * Double.pi / 2))), 0, accuracy: 0.5, "p = \(p) to")
        }
        _ = await rig.sm.apply(.tbar(progress: 1.0))
        await rig.run(blocks: settle)
        let (a, b) = rig.lastDeliveredWindow(blocks: 4)
        XCTAssertEqual(c1.rms(from: a, to: b), 0, accuracy: 1e-4)
        XCTAssertEqual(c2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        let state = await rig.sm.state
        XCTAssertEqual(state.program, 2)
        await rig.shutdown()
    }

    // MARK: AFV 关 / 开

    func testAFV_off_allInputsAudibleRegardlessOfProgram_thenOnGatesToProgram() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: false))
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        let c1 = try rig.capture(.inputProgram(number: 1)), c2 = try rig.capture(.inputProgram(number: 2))
        let iso2 = try rig.capture(.input(number: 2))
        await rig.run(seconds: 1)
        var (a, b) = rig.lastDeliveredWindow(blocks: 4)
        XCTAssertEqual(c1.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        XCTAssertEqual(c2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02, "AFV 关：PVW 也出声")
        await rig.sm.schedule(.cut, at: Tick(90))
        await rig.run(seconds: 1)
        (a, b) = rig.lastDeliveredWindow(blocks: 4)
        XCTAssertEqual(c1.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02, "AFV 关：Cut 不影响音频")
        _ = await rig.sm.apply(.setAFV(on: true))       // PGM 现在是 2；开关不是转场，立即门控（不延后）
        await rig.run(blocks: 8)
        (a, b) = rig.lastDeliveredWindow(blocks: 4)
        XCTAssertEqual(c1.rms(from: a, to: b), 0, accuracy: 1e-4, "AFV 开：非 PGM 静音")
        XCTAssertEqual(c2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        XCTAssertEqual(iso2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02, "ISO 不受 AFV 影响")
        await rig.shutdown()
    }

    // MARK: FTB

    func testFTB_masterFadesOutAlongTheVideoRamp_andBackIn() async throws {
        let (rig, _, _, cm) = try await makeRig()
        let s = Tick(120)
        await rig.sm.schedule(.ftb(on: true), at: s)
        await rig.run(seconds: 3)
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: 30)
        var t = tS + rig.engine.blockDuration * 2
        var compared = 0
        while t + rig.engine.blockDuration < tS + D - rig.engine.blockDuration {
            let e = t + rig.engine.blockDuration
            let center = t + (e - t) / 2
            let level = AudioProgramGate.fadeToBlackLevel(at: center, on: true, start: tS, duration: D)
            if 1 - level >= 0.1 {
                let err = dB(cm.rms(from: t, to: e) / (baseRMS * (1 - level)))
                XCTAssertEqual(err, 0, accuracy: 0.5, "level \(level) 误差 \(err) dB")
                compared += 1
            }
            t = e
        }
        XCTAssertGreaterThan(compared, 60)
        // 全黑后 Master 静音
        let dark = tS + D + rig.engine.blockDuration * 3
        XCTAssertEqual(cm.rms(from: dark, to: dark + rig.engine.blockDuration * 4), 0, accuracy: 1e-4)
        XCTAssertEqual(rig.engine.status.ftbLevel, 1)
        // 回来
        _ = await rig.sm.apply(.ftb(on: false))
        await rig.run(seconds: 1)
        let (a, b) = rig.lastDeliveredWindow(blocks: 4)
        XCTAssertEqual(cm.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        await rig.shutdown()
    }

    func testFTB_disabledByConfiguration_masterUnaffected() async throws {
        let rig = try await EngineRig(state: States.fourInputs(afv: true)) { $0.fadeMasterWithFTB = false }
        try rig.addSource(number: 1, generator: sine(1000))
        let cm = try rig.capture(.master)
        await rig.sm.schedule(.ftb(on: true), at: Tick(60))
        await rig.run(seconds: 3)
        let t = rig.clock.time(of: Tick(150))
        XCTAssertEqual(cm.rms(from: t, to: t + rig.engine.blockDuration * 4), baseRMS, accuracy: baseRMS * 0.02)
        await rig.shutdown()
    }
}
