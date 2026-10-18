import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// D10（Codex 2026-10-13 审查，W1-B5 / prompt 120）：AFV 开着、长 Auto 中途按 Cut（或 T-bar 一下推到底）——画面那一拍就全是新画面，
/// 声音也要在同一拍短淡收口：**旧源 1 拍内到 −∞、新源 1 拍内到满**，不能按原来的长斜坡再走 9 s。
/// 量法（录音轨采样）：每路挂 `.inputProgram`（推子后含 AFV，= 它送进节目总线的信号）、`.input`（ISO：推子后 AFV 前）与 Master
/// （= 送录制 / 编码的那一轨），全部按 PTS（内容时刻，与画面拍点同一时基）逐样本看："−∞" = 样本严格为 0；"满" = 与 AFV 前的 ISO 那一路
/// 逐样本相同（AFV 增益恰好 1.0）；Master 逐样本 = 新源（旧源一点不剩）。
final class AFVInterruptTests: XCTestCase {
    /// 纯正弦（无 click，便于量电平；两路频率不同，Master 里能分开）。
    func sine(_ hz: Double, amplitude: Float = 0.5) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in
            for i in 0..<n { buf[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
        }
    }
    /// 单声道 0.5 幅正弦，居中声像（每边 −3 dB）后的稳态 RMS。
    let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)

    struct Taps { let p1: TimedCapture; let p2: TimedCapture; let iso2: TimedCapture; let master: TimedCapture }

    /// 输入 1（1 kHz）PGM、输入 2（1.5 kHz）PVW，AFV 开（或关）。
    func makeRig(afv: Bool = true) async throws -> (EngineRig, Taps) {
        let rig = try await EngineRig(state: States.fourInputs(afv: afv))
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        let taps = Taps(p1: try rig.capture(.inputProgram(number: 1)), p2: try rig.capture(.inputProgram(number: 2)),
                        iso2: try rig.capture(.input(number: 2)), master: try rig.capture(.master))
        return (rig, taps)
    }

    /// 某个 host time 在这条录音轨里的样本下标（向上取整：落在 t 及之后的第一个样本）。
    static func index(_ c: TimedCapture, at t: HostTime) -> Int {
        max(0, Int((((t - c.firstHostTime!).seconds) * 48_000).rounded(.up)))
    }
    func index(_ c: TimedCapture, at t: HostTime) -> Int { Self.index(c, at: t) }
    /// a 里第 i 个样本在 b 里的下标（两条轨首块 PTS 之差按整样本换算；不各自取整，免得差一个样本）。
    static func sameSample(_ i: Int, of a: TimedCapture, in b: TimedCapture) -> Int {
        i + Int(((a.firstHostTime! - b.firstHostTime!).seconds * 48_000).rounded())
    }

    /// 最后一个非零样本之后的那一刻相对 t 的毫秒数（录音轨里这一路"到 −∞"的时刻）；从 t 起全是 0 返回 ≤ 0。
    func silenceMs(_ c: TimedCapture, after t: HostTime) -> Double {
        guard let last = c.left.lastIndex(where: { $0 != 0 }) else { return -.infinity }
        return (c.hostTime(ofSample: last + 1) - t).milliseconds
    }

    /// 两段样本逐个比（不用 XCTAssertEqual 比数组：失败时会打几万个样本）；相同返回 nil。
    static func sampleDiff(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> String? {
        guard a.count == b.count else { return "长度 \(a.count) ≠ \(b.count)" }
        let pairs = zip(a, b)
        guard let firstOffset = pairs.enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else { return nil }
        let n = pairs.reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
        let i = a.startIndex + firstOffset, j = b.startIndex + firstOffset
        return "\(n) / \(a.count) 个样本不同，第一个在 +\(firstOffset)：\(a[i]) vs \(b[j])"
    }

    /// 等幅曲线在 [t1, t2) 上的 RMS 增益（块积分，同 AFVTests.curveRMS）。
    func curveRMS(from t1: HostTime, to t2: HostTime, tS: HostTime, D: HostDuration, toPath: Bool) -> Double {
        let p1 = Double((t1 - tS).ticks) / Double(D.ticks), p2 = Double((t2 - tS).ticks) / Double(D.ticks)
        let term = (sin(.pi * p2) - sin(.pi * p1)) / (2 * .pi * (p2 - p1))
        return sqrt(max(0, 0.5 + (toPath ? -term : term)))
    }

    /// 相邻样本最大跳变（A1 第三项的口径是 > 0.5 满幅算不连续；这里的正弦 0.35 幅，硬切一下就是 0.3 量级）。
    func maxJump(_ a: ArraySlice<Float>) -> Float {
        var m: Float = 0
        var prev = a.first ?? 0
        for v in a.dropFirst() { m = max(m, abs(v - prev)); prev = v }
        return m
    }

    /// 打断之后的共同判据：t 起旧源（1）1 拍内严格 0、新源（2）1 拍内与 ISO 逐样本相同、Master 逐样本 = 新源；
    /// 打断之前长淡变照走（不提前、不回弹）；打断前后没有跳变。返回实测"到 −∞"的毫秒数。
    @discardableResult
    func assertShortFadeAt(_ rig: EngineRig, _ taps: Taps, tCut: HostTime, autoStart tS: HostTime, autoDuration D: HostDuration,
                           label: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        let oneTick = rig.clock.duration(ofTicks: 1)
        let block = rig.engine.blockDuration
        let end = rig.lastDeliveredWindow(blocks: 1).1
        XCTAssertGreaterThan(end, tCut + HostDuration(seconds: 1), "\(label)：录音轨要盖住打断之后至少 1 s", file: file, line: line)
        // 1. 打断之前：长淡变照走（含 t_cut 前一整块的电平与等幅曲线一致，±0.5 dB）
        for k in 2...4 {
            let a = tCut - block * k, b = a + block
            let gFrom = curveRMS(from: a, to: b, tS: tS, D: D, toPath: false), gTo = curveRMS(from: a, to: b, tS: tS, D: D, toPath: true)
            XCTAssertEqual(IT.db(taps.p1.rms(from: a, to: b) / (baseRMS * gFrom)), 0, accuracy: 0.5, "\(label)：打断前 \(k) 块旧源应在长淡变上", file: file, line: line)
            XCTAssertEqual(IT.db(taps.p2.rms(from: a, to: b) / (baseRMS * gTo)), 0, accuracy: 0.5, "\(label)：打断前 \(k) 块新源应在长淡变上", file: file, line: line)
        }
        // 2. 旧源 1 拍内到 −∞：t_cut + 1 拍起每个样本严格 0（一直到录音轨末尾）
        let silent = silenceMs(taps.p1, after: tCut)
        XCTAssertLessThanOrEqual(silent, oneTick.milliseconds, "\(label)：旧源应在 t_cut 之后 1 拍（\(oneTick.milliseconds) ms）内到 −∞，实测 \(silent) ms", file: file, line: line)
        // 3. 新源 1 拍内到满：t_cut + 1 拍起与 AFV 前的 ISO 那一路逐样本相同（AFV 增益恰好 1.0）
        let i2 = index(taps.p2, at: tCut + oneTick), j2 = Self.sameSample(i2, of: taps.p2, in: taps.iso2), e2 = index(taps.p2, at: end)
        let n = e2 - i2
        XCTAssertGreaterThan(n, 40_000, file: file, line: line)
        if n > 0, j2 + n <= taps.iso2.left.count, i2 + n <= taps.p2.left.count {
            XCTAssertNil(Self.sampleDiff(taps.p2.left[i2..<(i2 + n)], taps.iso2.left[j2..<(j2 + n)]), "\(label)：新源 t_cut + 1 拍起应满（= ISO）", file: file, line: line)
        }
        // 4. 录音轨（Master）：t_cut + 1 拍起逐样本 = 新源，没有旧源的 1 kHz
        let im = Self.sameSample(i2, of: taps.p2, in: taps.master)
        if n > 0, im + n <= taps.master.left.count {
            XCTAssertNil(Self.sampleDiff(taps.master.left[im..<(im + n)], taps.p2.left[i2..<(i2 + n)]), "\(label)：Master t_cut + 1 拍起应只剩新源", file: file, line: line)
        }
        // 5. 不回弹：t_cut 前 3 块到 t_cut + 1 拍，新源逐块不降、旧源逐块不升（若在新淡变起点之前就撤掉长淡变，增益会先弹回转场前的状态：
        //    新源 −16 dB → −∞ 再跳回来）。1.5 kHz 一块正好 8 个周期，块 RMS 与相位无关，判严；1 kHz 一块 5.33 个周期，块 RMS 随相位差 ±1.5%，放 3%
        var t = tCut - block * 3
        var prev1 = Double.infinity, prev2 = -Double.infinity
        while t < tCut + oneTick {
            let r1 = taps.p1.rms(from: t, to: t + block), r2 = taps.p2.rms(from: t, to: t + block)
            XCTAssertLessThanOrEqual(r1, prev1 * 1.03 + 1e-9, "\(label)：\((t - tCut).milliseconds) ms 旧源回弹", file: file, line: line)
            XCTAssertGreaterThanOrEqual(r2, prev2 * (1 - 1e-6) - 1e-9, "\(label)：\((t - tCut).milliseconds) ms 新源回落", file: file, line: line)
            prev1 = r1; prev2 = r2
            t = t + block
        }
        // 6. 没有跳变（A1 第三项口径 0.5 满幅；这里收紧到 0.1：0.35 幅的正弦硬切一下就是 0.3 量级，稳态最大 0.07）
        let a = index(taps.master, at: tCut - block * 8), b = index(taps.master, at: tCut + block * 8)
        if b <= taps.master.left.count { XCTAssertLessThan(maxJump(taps.master.left[a..<b]), 0.1, "\(label)：打断前后 Master 不该有跳变", file: file, line: line) }
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0, file: file, line: line)
        return silent
    }

    // MARK: Auto 中按 Cut

    /// Codex 的触发条件：AFV 开、10 s Auto（600 拍）第 1 秒按 Cut。修前：旧源按原斜坡再走约 9 s（t_cut + 1 拍时还在 −0.1 dB）。
    func testD10_cutDuringLongAuto_oldSourceSilentAndNewFullWithinOneTick() async throws {
        let (rig, taps) = try await makeRig()
        let s = Tick(120), cutTick = Tick(180)
        await rig.sm.schedule(.fade(durationTicks: 600), at: s)
        await rig.sm.schedule(.cut, at: cutTick)
        await rig.run(seconds: 4.5)
        let state = await rig.sm.state
        XCTAssertEqual(state.program, 2, "Cut 把转场提前切完：PGM = 2")
        XCTAssertFalse(state.transition.isActive)
        let tCut = rig.clock.time(of: cutTick)
        let silent = assertShortFadeAt(rig, taps, tCut: tCut, autoStart: rig.clock.time(of: s), autoDuration: rig.clock.duration(ofTicks: 600), label: "Auto 中 Cut")
        print("D10 Auto 600 拍第 60 拍 Cut：旧源 t_cut + \(String(format: "%.3f", silent)) ms 到 −∞（1 拍 = \(String(format: "%.3f", rig.clock.duration(ofTicks: 1).milliseconds)) ms）")
        await rig.shutdown()
    }

    /// 同一拍点的另一种打断：Auto 进行中 T-bar 一下推到底（MIDI 推子跳到顶 / API tbar 1.0）——reducer 直接对调，与 Cut 同一口径。
    func testD10_tbarToOneDuringLongAuto_sameShortFade() async throws {
        let (rig, taps) = try await makeRig()
        let s = Tick(120), cutTick = Tick(180)
        await rig.sm.schedule(.fade(durationTicks: 600), at: s)
        await rig.sm.schedule(.tbar(progress: 1), at: cutTick)
        await rig.run(seconds: 4.5)
        let program = await rig.sm.state.program
        XCTAssertEqual(program, 2)
        let silent = assertShortFadeAt(rig, taps, tCut: rig.clock.time(of: cutTick), autoStart: rig.clock.time(of: s), autoDuration: rig.clock.duration(ofTicks: 600), label: "Auto 中 T-bar 推到底")
        print("D10 Auto 600 拍第 60 拍 T-bar 推到底：旧源 t_cut + \(String(format: "%.3f", silent)) ms 到 −∞")
        await rig.shutdown()
    }

    /// 命令路（API / 键盘：`apply` 落在渲染线程还没消费的最早一拍，不是排程）：结果相同。
    func testD10_cutDuringLongAuto_viaApply_sameShortFade() async throws {
        let (rig, taps) = try await makeRig()
        let s = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 600), at: s)
        await rig.run(seconds: 3)
        let receipt = await rig.sm.apply(.cut)
        XCTAssertTrue(receipt.applied)
        await rig.run(seconds: 1.5)
        let silent = assertShortFadeAt(rig, taps, tCut: rig.clock.time(of: receipt.appliedTick), autoStart: rig.clock.time(of: s), autoDuration: rig.clock.duration(ofTicks: 600), label: "apply(.cut)")
        print("D10 Auto 600 拍途中 apply(.cut)（落在第 \(receipt.appliedTick.rawValue) 拍）：旧源 t_cut + \(String(format: "%.3f", silent)) ms 到 −∞")
        await rig.shutdown()
    }

    // MARK: 自然完成不受影响

    /// 自然走满的 Auto：C 侧的长淡变自己收口（终点 = t_s + D，帧精确），不被短淡打断——t_s + D 之前 from 还在曲线上（不提前到 0）、之后严格 0。
    func testD10_naturalLongAuto_endsOnItsOwnCurve_noShortFade() async throws {
        let (rig, taps) = try await makeRig()
        let s = Tick(120), d = 120
        await rig.sm.schedule(.fade(durationTicks: d), at: s)
        await rig.run(seconds: 5)
        let tS = rig.clock.time(of: s), D = rig.clock.duration(ofTicks: d), tE = tS + D
        let block = rig.engine.blockDuration
        // 终点前 4 块：from 仍在 cos 曲线上（−20 dB 以上的块 ±0.5 dB）
        for k in 4...8 {
            let a = tE - block * k, b = a + block
            let g = curveRMS(from: a, to: b, tS: tS, D: D, toPath: false)
            if g >= 0.1 { XCTAssertEqual(IT.db(taps.p1.rms(from: a, to: b) / (baseRMS * g)), 0, accuracy: 0.5, "终点前 \(k) 块") }
        }
        // 终点：from 最后一个非零样本就在 t_s + D（± 1 样本）
        let silent = silenceMs(taps.p1, after: tE)
        XCTAssertEqual(silent, 0, accuracy: 0.05, "自然完成：from 恰好在 t_s + D 到 −∞（实测 \(silent) ms）")
        print("D10 自然走满的 Auto 120 拍：from 在 t_s + D \(String(format: "%+.3f", silent)) ms 到 −∞（没被短淡打断）")
        let i2 = index(taps.p2, at: tE), j2 = Self.sameSample(i2, of: taps.p2, in: taps.iso2), n = index(taps.p2, at: rig.lastDeliveredWindow(blocks: 1).1) - i2
        XCTAssertNil(Self.sampleDiff(taps.p2.left[i2..<(i2 + n)], taps.iso2.left[j2..<(j2 + n)]), "t_s + D 起 to 满")
        await rig.shutdown()
    }

    // MARK: 转场途中才开 AFV

    /// AFV 在 Auto 进行中才打开：开的那一刻按当前进度门控（没有 C 侧淡变），自然完成那一拍也要收到终值——修前停在开 AFV 那一刻的 cos / sin 上。
    func testD10_afvTurnedOnMidAuto_naturalCompletionStillLandsOnProgram() async throws {
        let (rig, taps) = try await makeRig(afv: false)
        let s = Tick(120), d = 60
        await rig.sm.schedule(.fade(durationTicks: d), at: s)
        await rig.sm.schedule(.setAFV(on: true), at: Tick(150))      // 进度 0.5
        await rig.run(seconds: 4.5)
        let tE = rig.clock.time(of: s + d), oneTick = rig.clock.duration(ofTicks: 1)
        let silent = silenceMs(taps.p1, after: tE)
        XCTAssertLessThanOrEqual(silent, oneTick.milliseconds, "完成那一拍 + 1 拍内旧源到 −∞，实测 \(silent) ms")
        print("D10 Auto 途中才开 AFV、自然完成：旧源 t_e + \(String(format: "%.3f", silent)) ms 到 −∞")
        let i2 = index(taps.p2, at: tE + oneTick), j2 = Self.sameSample(i2, of: taps.p2, in: taps.iso2)
        let n = index(taps.p2, at: rig.lastDeliveredWindow(blocks: 1).1) - i2
        XCTAssertGreaterThan(n, 40_000)
        XCTAssertNil(Self.sampleDiff(taps.p2.left[i2..<(i2 + n)], taps.iso2.left[j2..<(j2 + n)]), "新源满")
        await rig.shutdown()
    }

    // MARK: T-bar 结束时的延后门控（D10 同一处：转场结束后音频要收到终值）

    /// T-bar 推杆位置晚对齐延迟（42.7 ms）才作用到音频；推到 0.9 之后不到 42.7 ms 就推到底提交：提交时的终值门控之后，
    /// 0.9 那一档排着的延后门控不能再落下去（修前：旧源停在 cos(0.45π) = −16 dB，直到下一次门控）。
    func testD10_tbarFastCommit_noStaleBarGateAfterCommit() async throws {
        let (rig, taps) = try await makeRig()
        await rig.run(seconds: 1)
        _ = await rig.sm.apply(.tbar(progress: 0.9))
        await rig.run(blocks: 2)                                    // 控制循环看到 0.9：排一档 now + 对齐延迟 的门控
        _ = await rig.sm.apply(.tbar(progress: 1.0))                // 42.7 ms 之内提交
        await rig.run(seconds: 1)
        let program = await rig.sm.state.program
        XCTAssertEqual(program, 2)
        let (a, b) = rig.lastDeliveredWindow(blocks: 32)
        XCTAssertEqual(taps.p1.rms(from: a, to: b), 0, "提交之后旧源应是 −∞（实测 \(IT.db(taps.p1.rms(from: a, to: b) / baseRMS)) dB）")
        XCTAssertEqual(taps.p2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        XCTAssertEqual(rig.engine.status.inputs.first { $0.number == 1 }?.afvGain, 0)
        print("D10 T-bar 0.9 后 2 块推到底：提交后旧源 \(IT.db(taps.p1.rms(from: a, to: b) / baseRMS)) dB、新源 \(String(format: "%+.3f", IT.db(taps.p2.rms(from: a, to: b) / baseRMS))) dB")
        await rig.shutdown()
    }

    /// T-bar 拉回 0（取消）同理：0.1 那一档的延后门控不能在取消之后落下去（修前：PVW 停在 sin(0.05π) = −16 dB）。
    func testD10_tbarFastCancel_noStaleBarGateAfterCancel() async throws {
        let (rig, taps) = try await makeRig()
        await rig.run(seconds: 1)
        _ = await rig.sm.apply(.tbar(progress: 0.1))
        await rig.run(blocks: 2)
        _ = await rig.sm.apply(.tbar(progress: 0))
        await rig.run(seconds: 1)
        let program = await rig.sm.state.program
        XCTAssertEqual(program, 1)
        let (a, b) = rig.lastDeliveredWindow(blocks: 32)
        XCTAssertEqual(taps.p2.rms(from: a, to: b), 0, "取消之后 PVW 应是 −∞（实测 \(IT.db(taps.p2.rms(from: a, to: b) / baseRMS)) dB）")
        XCTAssertEqual(taps.p1.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        print("D10 T-bar 0.1 后 2 块拉回 0：取消后 PVW \(IT.db(taps.p2.rms(from: a, to: b) / baseRMS)) dB、PGM \(String(format: "%+.3f", IT.db(taps.p1.rms(from: a, to: b) / baseRMS))) dB")
        await rig.shutdown()
    }

    /// T-bar 接管进行中的 Auto（推到一半）再推到底：提交那一刻也要收到终值（修前：音频侧记的还是 auto，completed 只清标记、不门控，
    /// 旧源停在最后一档推杆位置上）。
    func testD10_tbarTakeoverOfAutoThenCommit_landsOnProgram() async throws {
        let (rig, taps) = try await makeRig()
        await rig.sm.schedule(.fade(durationTicks: 600), at: Tick(60))
        await rig.run(seconds: 2)
        _ = await rig.sm.apply(.tbar(progress: 0.6))                // 接管：source = tbar
        await rig.run(seconds: 0.5)
        _ = await rig.sm.apply(.tbar(progress: 1.0))
        await rig.run(seconds: 1)
        let program = await rig.sm.state.program
        XCTAssertEqual(program, 2)
        let (a, b) = rig.lastDeliveredWindow(blocks: 32)
        XCTAssertEqual(taps.p1.rms(from: a, to: b), 0, "提交之后旧源应是 −∞（实测 \(IT.db(taps.p1.rms(from: a, to: b) / baseRMS)) dB）")
        XCTAssertEqual(taps.p2.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        print("D10 T-bar 接管 Auto（0.6）再推到底：提交后旧源 \(IT.db(taps.p1.rms(from: a, to: b) / baseRMS)) dB、新源 \(String(format: "%+.3f", IT.db(taps.p2.rms(from: a, to: b) / baseRMS))) dB")
        await rig.shutdown()
    }
}

// MARK: 实时（空设备、控制线程驱动）

extension IntegrationRealtimeTests {
    /// D10 实时版：10 s Auto 第 1 秒 Cut，空设备 + 控制线程（不是手动循环）。旧源 1 拍内到 −∞、新源满。
    func testD10_nullDevice_cutDuringLongAuto_shortFadeOnTheCutTick() async throws {
        var rig = try await makeRig(output: .null, afv: true)
        try addSource(&rig, number: 1) { start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) } }
        try addSource(&rig, number: 2) { start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1500 * Double(start + Int64(i)) / 48_000)) } }
        let p1 = TimedCapture(), p2 = TimedCapture(), iso2 = TimedCapture()
        try rig.engine.addConsumer(CaptureConsumer(name: "p1", capture: p1), source: .inputProgram(number: 1))
        try rig.engine.addConsumer(CaptureConsumer(name: "p2", capture: p2), source: .inputProgram(number: 2))
        try rig.engine.addConsumer(CaptureConsumer(name: "iso2", capture: iso2), source: .input(number: 2))
        let s = Tick(60), cutTick = Tick(120)
        await rig.sm.schedule(.fade(durationTicks: 600), at: s)
        await rig.sm.schedule(.cut, at: cutTick)
        await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: 3.5))
        let tCut = rig.clock.time(of: cutTick), oneTick = rig.clock.duration(ofTicks: 1)
        let base = 0.5 / sqrt(2.0) / sqrt(2.0)
        // 打断前一块：旧源还在长淡变上（进度 0.1 → −0.1 dB），没有提前到 0
        XCTAssertEqual(IT.db(p1.rms(from: tCut - rig.engine.blockDuration * 3, to: tCut - rig.engine.blockDuration * 2) / base), -0.1, accuracy: 0.5)
        // t_cut + 1 拍起旧源严格 0，新源与 ISO 逐样本相同
        guard let last = p1.left.lastIndex(where: { $0 != 0 }) else { return XCTFail("旧源一直是 0？") }
        let silentMs = (p1.hostTime(ofSample: last + 1) - tCut).milliseconds
        XCTAssertLessThanOrEqual(silentMs, oneTick.milliseconds, "旧源到 −∞ 晚了：t_cut + \(silentMs) ms")
        print("D10 空设备实时 Auto 600 拍第 60 拍 Cut：旧源 t_cut + \(String(format: "%.3f", silentMs)) ms 到 −∞")
        let a = AFVInterruptTests.index(p2, at: tCut + oneTick)
        let b = AFVInterruptTests.sameSample(a, of: p2, in: iso2)
        let n = min(p2.left.count - a, iso2.left.count - b)
        XCTAssertGreaterThan(n, 24_000)
        XCTAssertNil(AFVInterruptTests.sampleDiff(p2.left[a..<(a + n)], iso2.left[b..<(b + n)]), "新源满")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await shutdown(rig)
    }
}
