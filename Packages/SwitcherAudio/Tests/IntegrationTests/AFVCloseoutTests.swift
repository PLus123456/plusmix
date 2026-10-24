import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W1-D4（prompt 125）音频收口，AFV 的三条：
///   第 1 条（用户 2026-10-18 裁定 #17）：Cut / Auto 起点统一用替换淡变。两次切换隔不到 ~60 ms 时，后一条的命令到混音器那一刻前一条的淡变
///          还没开始（起点 = 拍点 + 对齐延迟 42.7 ms）或正在走：修前在应用时就把它撤掉——还没开始的整个听不见（画面切过去了、声音没动），
///          正在走的先向转场前的增益回弹、后一条起点再跳回。要求：前一条照走到后一条的起点，后一条从那一刻的增益接着走。
///   第 2 条（reports/w1-core-5.md §3 第 4 条）：Auto 进行中才打开 AFV，PGM / PVW 的增益跟剩下的等幅曲线走，不停在打开那一刻的 cos / sin。
///   第 3 条（同 §3 第 5 条）：Cut 恰好落在 Auto 走满那一拍，声音跟画面同一拍切回，不再比画面早一个对齐延迟回到旧源。
/// 量法同 AFVInterruptTests（录音轨采样）：每路 `.inputProgram`（推子后含 AFV）、`.input`（ISO：推子后 AFV 前）、Master，按 PTS（内容时刻，
/// 与画面拍点同一时基）逐样本看。"满" = 与 ISO 逐样本相同（AFV 增益恰好 1.0）；"−∞" = 样本严格 0；AFV 增益曲线 = 含 AFV 的那一路 ÷ ISO（逐样本）。
/// 判据先收集成"问题"清单、每个用例最后断言一次（逐样本的东西一红就是成千上万条，XCTest 也不会全记）。
final class AFVCloseoutTests: XCTestCase {
    typealias I = AFVInterruptTests

    func sine(_ hz: Double, amplitude: Float = 0.5) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in
            for i in 0..<n { buf[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) }
        }
    }
    /// 单声道 0.5 幅正弦，居中声像（每边 −3 dB）后的稳态 RMS。
    let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)

    struct Taps { let p1: TimedCapture; let p2: TimedCapture; let iso1: TimedCapture; let iso2: TimedCapture; let master: TimedCapture }

    /// 输入 1（1 kHz）PGM、输入 2（1.5 kHz）PVW。
    func makeRig(afv: Bool = true) async throws -> (EngineRig, Taps) {
        let rig = try await EngineRig(state: States.fourInputs(afv: afv))
        try rig.addSource(number: 1, generator: sine(1000))
        try rig.addSource(number: 2, generator: sine(1500))
        let taps = Taps(p1: try rig.capture(.inputProgram(number: 1)), p2: try rig.capture(.inputProgram(number: 2)),
                        iso1: try rig.capture(.input(number: 1)), iso2: try rig.capture(.input(number: 2)), master: try rig.capture(.master))
        return (rig, taps)
    }

    // MARK: 录音轨上的判据

    /// [a, b)（PTS，按 a 轨取下标）里两条轨逐样本相同；是返回 nil，否则返回哪里不同。
    static func same(_ a: TimedCapture, _ b: TimedCapture, from t1: HostTime, to t2: HostTime) -> String? {
        let i = I.index(a, at: t1), e = I.index(a, at: t2)
        guard e > i else { return "空区间" }
        let j = I.sameSample(i, of: a, in: b)
        guard i >= 0, e <= a.left.count, j >= 0, j + (e - i) <= b.left.count else { return "录音轨不够长（\(i)..<\(e) / \(a.left.count)，\(j) / \(b.left.count)）" }
        return I.sampleDiff(a.left[i..<e], b.left[j..<(j + e - i)])
    }
    /// [a, b)（PTS）里不是 0 的样本数。
    static func nonzero(_ p: TimedCapture, from a: HostTime, to b: HostTime) -> Int {
        let i = I.index(p, at: a), e = min(I.index(p, at: b), p.left.count)
        guard e > i else { return 0 }
        return p.left[i..<e].reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
    }
    /// p 轨第 i 个样本的 AFV 增益 = 含 AFV 的那一路 ÷ ISO（同一个推子后信号，只差 AFV 门控）；|ISO| < 0.05 的样本（过零附近）不算，返回 nil。
    static func afvGain(_ p: TimedCapture, _ iso: TimedCapture, _ i: Int) -> Double? {
        let j = I.sameSample(i, of: p, in: iso)
        guard i >= 0, i < p.left.count, j >= 0, j < iso.left.count else { return nil }
        let x = Double(iso.left[j])
        guard abs(x) >= 0.05 else { return nil }
        return Double(p.left[i]) / x
    }
    /// [a, b)（PTS）逐样本：AFV 增益与期望曲线的最大偏差、比了几个样本、最大偏差在哪。
    static func gainError(_ p: TimedCapture, _ iso: TimedCapture, from a: HostTime, to b: HostTime,
                          expected: (HostTime) -> Double) -> (maxErr: Double, n: Int, worstAt: HostTime?) {
        var maxErr = 0.0, n = 0
        var worst: HostTime?
        let lo = max(0, I.index(p, at: a)), hi = min(I.index(p, at: b), p.left.count)
        guard hi > lo else { return (0, 0, nil) }
        for i in lo..<hi {
            guard let g = afvGain(p, iso, i) else { continue }
            let e = abs(g - expected(p.hostTime(ofSample: i)))
            if e > maxErr { maxErr = e; worst = p.hostTime(ofSample: i) }
            n += 1
        }
        return (maxErr, n, worst)
    }
    /// [a, b)（PTS）逐样本：AFV 增益朝一个方向走（falling：不升；否则不降），返回最大的反向变化（回弹量）与相邻有效样本间的最大变化。
    static func gainTrend(_ p: TimedCapture, _ iso: TimedCapture, from a: HostTime, to b: HostTime, falling: Bool) -> (rebound: Double, maxStep: Double) {
        var prev: Double?
        var rebound = 0.0, maxStep = 0.0
        let lo = max(0, I.index(p, at: a)), hi = min(I.index(p, at: b), p.left.count)
        guard hi > lo else { return (0, 0) }
        for i in lo..<hi {
            guard let g = afvGain(p, iso, i) else { continue }
            if let q = prev {
                rebound = max(rebound, falling ? g - q : q - g)
                maxStep = max(maxStep, abs(g - q))
            }
            prev = g
        }
        return (rebound, maxStep)
    }
    /// 相邻样本最大跳变（[a, b)，PTS）。
    static func maxJump(_ c: TimedCapture, from a: HostTime, to b: HostTime) -> Float {
        let i = max(0, I.index(c, at: a)), e = min(I.index(c, at: b), c.left.count)
        guard e > i + 1 else { return 0 }
        var m: Float = 0
        for k in (i + 1)..<e { m = max(m, abs(c.left[k] - c.left[k - 1])) }
        return m
    }

    /// 等幅曲线：from 路 cos、to 路 sin（p = (t − 起点) / 时长，钳在 [0, 1]）。
    static func curve(_ t: HostTime, start: HostTime, duration: HostDuration, toPath: Bool) -> Double {
        let p = min(max(Double(t.ticks) - Double(start.ticks), 0) / Double(duration.ticks), 1)
        return toPath ? sin(p * Double.pi / 2) : cos(p * Double.pi / 2)
    }
    /// 等幅曲线在 [t1, t2) 上的 RMS 增益（块积分，同 AFVTests.curveRMS）。
    static func curveRMS(from t1: HostTime, to t2: HostTime, tS: HostTime, D: HostDuration, toPath: Bool) -> Double {
        let p1 = Double((t1 - tS).ticks) / Double(D.ticks), p2 = Double((t2 - tS).ticks) / Double(D.ticks)
        let term = (sin(.pi * p2) - sin(.pi * p1)) / (2 * .pi * (p2 - p1))
        return sqrt(max(0, 0.5 + (toPath ? -term : term)))
    }
    /// 最后一个非零样本之后的那一刻相对 t 的毫秒数（录音轨里这一路"到 −∞"的时刻，同 AFVInterruptTests.silenceMs）。
    static func silenceMs(_ c: TimedCapture, after t: HostTime) -> Double {
        guard let last = c.left.lastIndex(where: { $0 != 0 }) else { return -.infinity }
        return (c.hostTime(ofSample: last + 1) - t).milliseconds
    }

    /// 问题清单：check 不成立就记一条。
    struct Problems {
        var list: [String] = []
        mutating func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { list.append(what()) } }
        mutating func none(_ diff: String?, _ what: String) { if let diff { list.append("\(what)：\(diff)") } }
    }

    /// 1 号 → 2 号（at1）再切回 1 号（at2）：两次之间（第一次短淡走完 → 第二次起点）1 号严格 0、2 号满、Master = 2 号；
    /// 第二次短淡走完之后 1 号满、2 号严格 0；两次短淡各自单调（不回弹）；Master 没有跳变。短淡 = cutFadeFrames（1 块 256 帧，≤ 1 拍）。
    func cutThenBackProblems(_ rig: EngineRig, _ taps: Taps, at1: HostTime, at2: HostTime, until: HostTime? = nil) -> [String] {
        var p = Problems()
        let fade = rig.engine.blockDuration
        let end = min(until ?? at2 + HostDuration(seconds: 0.3), rig.lastDeliveredWindow(blocks: 1).1)
        p.check(end > at2 + fade * 4, "录音轨没盖住第二次之后")
        p.none(Self.same(taps.p1, taps.iso1, from: at1 - fade * 4, to: at1), "第一次之前 1 号应满")
        p.check(Self.nonzero(taps.p2, from: at1 - fade * 4, to: at1) == 0, "第一次之前 2 号应严格 0")
        // 两次之间：第一次切换要整段听得到（修前后一条在应用时撤掉还没开始的前一条：1 号一直在、2 号一个样本都没有；正在走的则回弹）
        let gap1 = Self.nonzero(taps.p1, from: at1 + fade, to: at2)
        p.check(gap1 == 0, "两次之间 1 号应严格 0（\(gap1) 个样本不是）")
        p.none(Self.same(taps.p2, taps.iso2, from: at1 + fade, to: at2), "两次之间 2 号应满")
        p.none(Self.same(taps.master, taps.p2, from: at1 + fade, to: at2), "两次之间 Master 应只有 2 号")
        p.none(Self.same(taps.p1, taps.iso1, from: at2 + fade, to: end), "第二次之后 1 号应满")
        p.check(Self.nonzero(taps.p2, from: at2 + fade, to: end) == 0, "第二次之后 2 号应严格 0")
        // 不回弹：第一次那段 1 号只降、2 号只升；第二次那段反过来
        let r1 = Self.gainTrend(taps.p1, taps.iso1, from: at1 - fade, to: at2, falling: true)
        let r2 = Self.gainTrend(taps.p2, taps.iso2, from: at1 - fade, to: at2, falling: false)
        let r3 = Self.gainTrend(taps.p2, taps.iso2, from: at2 - fade / 2, to: at2 + fade * 2, falling: true)
        let r4 = Self.gainTrend(taps.p1, taps.iso1, from: at2 - fade / 2, to: at2 + fade * 2, falling: false)
        for (r, what) in [(r1, "第一次 1 号"), (r2, "第一次 2 号"), (r3, "第二次 2 号"), (r4, "第二次 1 号")] {
            p.check(r.rebound <= 1e-5, "\(what) 回弹 \(String(format: "%.4f", r.rebound))")
        }
        // Master 没有跳变（A1 第三项口径 0.5 满幅；收紧到 0.1：0.35 幅的正弦硬切一下就是 0.3 量级）
        let jump = Self.maxJump(taps.master, from: at1 - fade * 8, to: at2 + fade * 8)
        p.check(jump < 0.1, "Master 跳变 \(jump)")
        return p.list
    }

    // MARK: 第 1 条：两次 Cut 隔 30 ms

    /// 裁定 #17 的用例：AFV 开，两次 Cut 隔 2 拍（33 ms，60 fps 下最接近 30 ms 的拍距）：第 120 拍 1→2、第 122 拍 2→1。
    /// 第二条的命令到混音器时第一条的短淡还没开始（离线台：事件比拍点早约 1 拍到、起点在拍点 + 42.7 ms）：
    /// 修前第一条在应用时就被撤掉，录音轨第 120…122 拍整段还是 1 号、2 号一个样本都没有（画面已切过去 2 拍）。
    func testW1D4_1_twoCutsThirtyMsApart_secondTakesOverTheFirst_noReboundNoSkip() async throws {
        let (rig, taps) = try await makeRig()
        let t1 = Tick(120), t2 = Tick(122)
        await rig.sm.schedule(.cut, at: t1)
        await rig.sm.schedule(.cut, at: t2)
        await rig.run(seconds: 3)
        let program = await rig.sm.state.program
        XCTAssertEqual(program, 1)
        let at1 = rig.clock.time(of: t1), at2 = rig.clock.time(of: t2)
        let problems = cutThenBackProblems(rig, taps, at1: at1, at2: at2)
        XCTAssertEqual(problems, [], "两次 Cut 隔 2 拍：\n" + problems.joined(separator: "\n"))
        print("W1-D4 第 1 条：两次 Cut 隔 2 拍（\(String(format: "%.3f", (at2 - at1).milliseconds)) ms）：\(problems.isEmpty ? "两次之间 2 号满 \(String(format: "%.3f", (at2 - at1 - rig.engine.blockDuration).milliseconds)) ms、1 号严格 0，不回弹" : problems.joined(separator: "；"))")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 同一条走命令路（API / 键盘：apply 落在渲染线程还没消费的最早一拍）：两次 apply(.cut) 之间跑 30 ms（6 块 = 32 ms）。
    func testW1D4_1_twoCutsThirtyMsApart_viaApply() async throws {
        let (rig, taps) = try await makeRig()
        await rig.run(seconds: 2)
        let r1 = await rig.sm.apply(.cut)
        await rig.run(blocks: Int((0.030 * 48_000 / Double(rig.blockFrames)).rounded(.up)))
        let r2 = await rig.sm.apply(.cut)
        XCTAssertTrue(r1.applied && r2.applied)
        XCTAssertGreaterThan(r2.appliedTick, r1.appliedTick)
        await rig.run(seconds: 1)
        let problems = cutThenBackProblems(rig, taps, at1: rig.clock.time(of: r1.appliedTick), at2: rig.clock.time(of: r2.appliedTick))
        XCTAssertEqual(problems, [], "apply 两次 Cut 隔 30 ms：\n" + problems.joined(separator: "\n"))
        print("W1-D4 第 1 条（命令路）：两次 apply(.cut) 隔 30 ms → 第 \(r1.appliedTick.rawValue) / \(r2.appliedTick.rawValue) 拍：\(problems.isEmpty ? "通过" : problems.joined(separator: "；"))")
        await rig.shutdown()
    }

    /// 第 1 条扫一遍边界：两次切换隔 1–5 拍，组合 Cut→Cut、Cut→Auto（第二次是 30 拍 Auto 切回）、Auto→Cut（30 拍 Auto 第 n 拍被 Cut 打断，D10 的短淡）。
    /// 离线台里第 t 拍的事件在"块尾 ≥ 第 t − 1 拍"的那一块到（早约 1 拍），命令在那一块开头应用；第一条的起点 = 第 t₁ 拍 + 2048 帧。
    /// 一拍 800 帧、一块 256 帧：隔 1–3 拍时第二条到的那一刻第一条一定还没开始；隔 4 拍时第一拍 b mod 8 ∈ 1…5 正赶上第一条短淡在走（回弹那一相），
    /// 其余已走完；隔 5 拍已走完。所以起始拍按 mod 8 挑过，三种相位都有。每组录音轨都要跟画面：两次切换之间是第一次切到的那一路
    /// （Auto 时逐样本在等幅曲线上），第二次从那一刻的增益接着走，不回弹、不跳过。
    func testW1D4_1_quickSwitchSweep_oneToFiveTicks_audioFollowsBothSwitches() async throws {
        let (rig, taps) = try await makeRig()
        enum Kind: String { case cutCut = "Cut→Cut", cutAuto = "Cut→Auto", autoCut = "Auto→Cut" }
        // (组合, 隔几拍, 第一次的拍)：两组之间至少隔 61 拍
        let plan: [(Kind, Int, Int64)] = [
            (.cutCut, 1, 120), (.cutCut, 2, 181), (.cutCut, 3, 242), (.cutCut, 4, 305), (.cutCut, 4, 367), (.cutCut, 5, 428),
            (.cutAuto, 1, 489), (.cutAuto, 2, 550), (.cutAuto, 3, 611), (.cutAuto, 4, 674),
            (.autoCut, 1, 735), (.autoCut, 2, 796), (.autoCut, 3, 857), (.autoCut, 4, 918),
        ]
        let d = 30
        for (kind, n, b) in plan {
            switch kind {
            case .cutCut:
                await rig.sm.schedule(.cut, at: Tick(b))
                await rig.sm.schedule(.cut, at: Tick(b + Int64(n)))
            case .cutAuto:
                await rig.sm.schedule(.cut, at: Tick(b))
                await rig.sm.schedule(.fade(durationTicks: d), at: Tick(b + Int64(n)))
            case .autoCut:
                await rig.sm.schedule(.fade(durationTicks: d), at: Tick(b))
                await rig.sm.schedule(.cut, at: Tick(b + Int64(n)))
                await rig.sm.schedule(.cut, at: Tick(b + 40))            // 切回 1 号，下一组从 PGM 1 起
            }
        }
        await rig.run(seconds: Double(plan.last!.2 + 50) / 60 + 1)
        let clock = rig.clock, fade = rig.engine.blockDuration, D = clock.duration(ofTicks: d)
        var report: [String] = [], failed: [String] = []
        for (kind, n, b) in plan {
            let at1 = clock.time(of: Tick(b)), at2 = clock.time(of: Tick(b + Int64(n)))
            let label = "\(kind.rawValue) 隔 \(n) 拍（第 \(b) 拍，b mod 8 = \(b % 8)）"
            var p = Problems()
            var note = ""
            switch kind {
            case .cutCut:
                p.list = cutThenBackProblems(rig, taps, at1: at1, at2: at2)
            case .cutAuto:
                // 两次之间 2 号满、1 号 0；Auto 起点起 2 号 cos、1 号 sin（逐样本），走满后 1 号满、2 号 0
                p.check(Self.nonzero(taps.p1, from: at1 + fade, to: at2) == 0, "两次之间 1 号应严格 0")
                p.none(Self.same(taps.p2, taps.iso2, from: at1 + fade, to: at2), "两次之间 2 号应满")
                let e2 = Self.gainError(taps.p2, taps.iso2, from: at2, to: at2 + D) { Self.curve($0, start: at2, duration: D, toPath: false) }
                let e1 = Self.gainError(taps.p1, taps.iso1, from: at2, to: at2 + D) { Self.curve($0, start: at2, duration: D, toPath: true) }
                p.check(e1.n > 10_000 && e2.n > 10_000, "Auto 段样本太少")
                p.check(e2.maxErr < 1e-3, "Auto 中 2 号应在 cos 上（最大差 \(String(format: "%.4f", e2.maxErr))）")
                p.check(e1.maxErr < 1e-3, "Auto 中 1 号应在 sin 上（最大差 \(String(format: "%.4f", e1.maxErr))）")
                let after = at2 + D + HostDuration(seconds: 0.2)
                p.none(Self.same(taps.p1, taps.iso1, from: at2 + D, to: after), "走满后 1 号应满")
                p.check(Self.nonzero(taps.p2, from: at2 + D, to: after) == 0, "走满后 2 号应严格 0")
                note = "曲线最大差 \(String(format: "%.1e", max(e1.maxErr, e2.maxErr)))"
            case .autoCut:
                // Auto 起点到被打断那一拍（前一块为止）逐样本在曲线上；打断那一拍的短淡之后 1 号 0、2 号满；2 号全程不降
                let e1 = Self.gainError(taps.p1, taps.iso1, from: at1, to: at2 - fade) { Self.curve($0, start: at1, duration: D, toPath: false) }
                let e2 = Self.gainError(taps.p2, taps.iso2, from: at1, to: at2 - fade) { Self.curve($0, start: at1, duration: D, toPath: true) }
                p.check(e1.n > 200 && e2.n > 200, "打断前样本太少")
                p.check(e1.maxErr < 1e-3, "打断前 1 号应在 cos 上（最大差 \(String(format: "%.4f", e1.maxErr))）")
                p.check(e2.maxErr < 1e-3, "打断前 2 号应在 sin 上（最大差 \(String(format: "%.4f", e2.maxErr))）")
                let after = at2 + HostDuration(seconds: 0.3)
                p.check(Self.nonzero(taps.p1, from: at2 + fade, to: after) == 0, "打断后 1 号应严格 0")
                p.none(Self.same(taps.p2, taps.iso2, from: at2 + fade, to: after), "打断后 2 号应满")
                let up = Self.gainTrend(taps.p2, taps.iso2, from: at1, to: at2 + fade * 2, falling: false)
                p.check(up.rebound <= 1e-5, "2 号回落 \(String(format: "%.4f", up.rebound))")
                note = "曲线最大差 \(String(format: "%.1e", max(e1.maxErr, e2.maxErr)))"
            }
            if p.list.isEmpty { report.append("\(label) 通过\(note.isEmpty ? "" : "（\(note)）")") }
            else { failed.append("\(label)：" + p.list.joined(separator: "；")) }
        }
        XCTAssertEqual(failed, [], "\(failed.count) / \(plan.count) 组不跟画面：\n" + failed.joined(separator: "\n"))
        print("W1-D4 第 1 条扫描 \(plan.count) 组：\n  " + (report + failed.map { "红 " + $0 }).joined(separator: "\n  "))
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    // MARK: 第 2 条：Auto 进行中才打开 AFV

    /// AFV 关着起一条 60 拍 Auto（第 120 拍），走到一半（第 150 拍）才开 AFV。修前：开的那一刻按当前进度直接门控（cos / sin(π/4)），
    /// 之后一直停在那儿，走满那一拍才短淡到终值（中段进度 0.5 → 1 声音不跟画面；终点晚 1 块）。要求：
    /// 1. 开 AFV 之后（第 152 拍起）PGM / PVW 的 AFV 增益跟剩下的等幅曲线走：逐块电平 ±0.5 dB（AFVTests 的口径），逐样本也看；
    /// 2. 走满那一刻（t_s + D）旧源到 −∞（± 0.05 ms，同自然完成），新源满；
    /// 3. 开的那一下增益是平滑过去的（逐样本变化不超过 τ 3 ms 一阶平滑的量级 0.01，没有台阶）。
    func testW1D4_2_afvTurnedOnMidAuto_gainsFollowTheRemainingCurve() async throws {
        let (rig, taps) = try await makeRig(afv: false)
        let s = Tick(120), d = 60
        await rig.sm.schedule(.fade(durationTicks: d), at: s)
        await rig.sm.schedule(.setAFV(on: true), at: Tick(150))
        await rig.run(seconds: 4.5)
        let clock = rig.clock, block = rig.engine.blockDuration, tick = clock.duration(ofTicks: 1)
        let tS = clock.time(of: s), D = clock.duration(ofTicks: d), tE = tS + D
        var p = Problems()
        // 1. 逐块：第 152 拍到走满前一块
        var t = clock.time(of: Tick(152)), compared = 0, outside = 0, worstDb = 0.0, worstTick = 0.0
        while t + block <= tE {
            let e = t + block
            let gFrom = Self.curveRMS(from: t, to: e, tS: tS, D: D, toPath: false), gTo = Self.curveRMS(from: t, to: e, tS: tS, D: D, toPath: true)
            var errs = [IT.db(taps.p2.rms(from: t, to: e) / (baseRMS * gTo))]
            if gFrom >= 0.1 { errs.append(IT.db(taps.p1.rms(from: t, to: e) / (baseRMS * gFrom))) }
            for err in errs where abs(err) > worstDb { worstDb = abs(err); worstTick = Double((t - clock.t0).ticks) / Double(tick.ticks) }
            if errs.contains(where: { abs($0) > 0.5 }) { outside += 1 }
            compared += 1
            t = e
        }
        p.check(compared > 40, "比到的块太少（\(compared)）")
        p.check(outside == 0, "\(outside) / \(compared) 块超出 ±0.5 dB，最大差 \(String(format: "%.2f", worstDb)) dB（第 \(String(format: "%.1f", worstTick)) 拍）")
        let e1 = Self.gainError(taps.p1, taps.iso1, from: clock.time(of: Tick(152)), to: tE) { Self.curve($0, start: tS, duration: D, toPath: false) }
        let e2 = Self.gainError(taps.p2, taps.iso2, from: clock.time(of: Tick(152)), to: tE) { Self.curve($0, start: tS, duration: D, toPath: true) }
        // 2. 终点
        let silent = Self.silenceMs(taps.p1, after: tE)
        p.check(abs(silent) <= 0.05, "走满那一刻旧源应到 −∞（实测 t_e \(String(format: "%+.3f", silent)) ms）")
        p.none(Self.same(taps.p2, taps.iso2, from: tE, to: rig.lastDeliveredWindow(blocks: 1).1), "t_e 起新源应满")
        // 3. 开的那一下平滑
        let s1 = Self.gainTrend(taps.p1, taps.iso1, from: clock.time(of: Tick(140)), to: clock.time(of: Tick(156)), falling: true)
        let s2 = Self.gainTrend(taps.p2, taps.iso2, from: clock.time(of: Tick(140)), to: clock.time(of: Tick(156)), falling: true)
        p.check(s1.maxStep < 0.01, "开 AFV 那一下 1 号增益台阶 \(String(format: "%.4f", s1.maxStep))")
        p.check(s2.maxStep < 0.01, "开 AFV 那一下 2 号增益台阶 \(String(format: "%.4f", s2.maxStep))")
        XCTAssertEqual(p.list, [], "Auto 中途才开 AFV：\n" + p.list.joined(separator: "\n"))
        print("""
            W1-D4 第 2 条：Auto 60 拍第 30 拍才开 AFV：第 152 拍起逐块 \(compared) 块最大差 \(String(format: "%.3f", worstDb)) dB（超 ±0.5 dB 的 \(outside) 块），\
            逐样本 AFV 增益与曲线最大差 PGM \(String(format: "%.1e", e1.maxErr)) / PVW \(String(format: "%.1e", e2.maxErr))（\(e1.n) / \(e2.n) 个样本）；\
            旧源 t_e \(String(format: "%+.3f", silent)) ms 到 −∞；开的那一下逐样本最大变化 \(String(format: "%.4f", s1.maxStep)) / \(String(format: "%.4f", s2.maxStep))
            """)
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }

    /// 第 2 条的延伸（Auto 途中 AFV 开关翻、与别的切换叠在一起）：
    ///   a. Auto 中途开 AFV（第 150 拍）之后又被 Cut 打断（第 160 拍）：开了之后到打断那一拍跟着曲线走，打断那一拍的短淡从那里接管，
    ///      +1 块起旧源严格 0、新源满（D10 不回退）；
    ///   b. 全局 AFV 一直开着，PVW 那一路的 AFV 位途中关掉再打开（第 135 拍关、第 150 拍开）：关着时它恒 1（不跟随）、PGM 照走 cos；重新参与之后两路都跟剩下的曲线走，
    ///      走满那一刻旧源到 −∞。修前：关掉时 PVW 的门控记录恰好是淡变终值 1，applyGates 比记录"没变"、不发命令，它接着沿 sin 走；打开时停在那一刻的 sin 上；
    ///   c. 全局 AFV 途中关掉（第 150 拍）：两路都回到恒 1（不跟随）。修前 PVW 同 b 的原因接着沿 sin 走。
    /// "恒 1" 按 AFV 增益与 1 差 1e-4 判（直接门控到 1 的一阶平滑停在 1 − 4.3e-6，不与 ISO 逐样本相同，见报告 §5）。
    func testW1D4_2_followThenInterrupt_andPerInputFlipMidAuto() async throws {
        let s = Tick(120), d = 60
        var problems: [String] = []
        // a
        do {
            let (rig, taps) = try await makeRig(afv: false)
            await rig.sm.schedule(.fade(durationTicks: d), at: s)
            await rig.sm.schedule(.setAFV(on: true), at: Tick(150))
            await rig.sm.schedule(.cut, at: Tick(160))
            await rig.run(seconds: 4)
            let clock = rig.clock, fade = rig.engine.blockDuration
            let tS = clock.time(of: s), D = clock.duration(ofTicks: d), tCut = clock.time(of: Tick(160))
            var p = Problems()
            let e1 = Self.gainError(taps.p1, taps.iso1, from: clock.time(of: Tick(152)), to: tCut - fade) { Self.curve($0, start: tS, duration: D, toPath: false) }
            let e2 = Self.gainError(taps.p2, taps.iso2, from: clock.time(of: Tick(152)), to: tCut - fade) { Self.curve($0, start: tS, duration: D, toPath: true) }
            p.check(e1.n > 3_000 && e2.n > 3_000, "样本太少")
            p.check(e1.maxErr < 1e-3 && e2.maxErr < 1e-3, "开 AFV 到打断之间应在曲线上（最大差 \(String(format: "%.4f / %.4f", e1.maxErr, e2.maxErr))）")
            let after = min(tCut + HostDuration(seconds: 0.5), rig.lastDeliveredWindow(blocks: 1).1)
            p.check(Self.nonzero(taps.p1, from: tCut + fade, to: after) == 0, "打断 + 1 块起旧源应严格 0")
            p.none(Self.same(taps.p2, taps.iso2, from: tCut + fade, to: after), "打断 + 1 块起新源应满")
            problems += p.list.map { "a（开 AFV 后打断）：" + $0 }
            print("W1-D4 第 2 条延伸 a：开 AFV（第 150 拍）到打断（第 160 拍）逐样本曲线最大差 \(String(format: "%.1e", max(e1.maxErr, e2.maxErr)))；\(p.list.isEmpty ? "打断 +1 块起旧源 0、新源满" : p.list.joined(separator: "；"))")
            await rig.shutdown()
        }
        // b
        do {
            let (rig, taps) = try await makeRig(afv: true)
            var off = InputSettings(); off.audio.afv = false
            await rig.sm.schedule(.fade(durationTicks: d), at: s)
            await rig.sm.schedule(.setInputSettings(input: 2, settings: off), at: Tick(135))
            await rig.sm.schedule(.setInputSettings(input: 2, settings: InputSettings()), at: Tick(150))
            await rig.run(seconds: 4.5)
            let clock = rig.clock
            let tS = clock.time(of: s), D = clock.duration(ofTicks: d), tE = tS + D
            var p = Problems()
            let e1 = Self.gainError(taps.p1, taps.iso1, from: tS, to: tE) { Self.curve($0, start: tS, duration: D, toPath: false) }
            let e2 = Self.gainError(taps.p2, taps.iso2, from: clock.time(of: Tick(152)), to: tE) { Self.curve($0, start: tS, duration: D, toPath: true) }
            p.check(e1.n > 20_000 && e2.n > 10_000, "样本太少")
            p.check(e1.maxErr < 1e-3, "PGM（没翻过）全程应在 cos 上（最大差 \(String(format: "%.4f", e1.maxErr))）")
            p.check(e2.maxErr < 1e-3, "PVW 重新参与之后应在 sin 上（最大差 \(String(format: "%.4f", e2.maxErr))）")
            let one = Self.gainError(taps.p2, taps.iso2, from: clock.time(of: Tick(136)), to: clock.time(of: Tick(145))) { _ in 1 }
            p.check(one.n > 3_000 && one.maxErr < 1e-4, "PVW 的 AFV 位关着时应恒 1（与 1 最大差 \(String(format: "%.4f", one.maxErr))）")
            let silent = Self.silenceMs(taps.p1, after: tE)
            p.check(abs(silent) <= 0.05, "走满那一刻旧源应到 −∞（实测 \(String(format: "%+.3f", silent)) ms）")
            problems += p.list.map { "b（PVW 的 AFV 位途中关再开）：" + $0 }
            print("W1-D4 第 2 条延伸 b：PGM 全程逐样本曲线最大差 \(String(format: "%.1e", e1.maxErr))、PVW 关着时与 1 差 \(String(format: "%.1e", one.maxErr))、重新参与后与曲线差 \(String(format: "%.1e", e2.maxErr))；旧源 t_e \(String(format: "%+.3f", silent)) ms 到 −∞")
            await rig.shutdown()
        }
        // c
        do {
            let (rig, taps) = try await makeRig(afv: true)
            await rig.sm.schedule(.fade(durationTicks: d), at: s)
            await rig.sm.schedule(.setAFV(on: false), at: Tick(150))
            await rig.run(seconds: 4)
            let clock = rig.clock
            var p = Problems()
            let from = clock.time(of: Tick(150)), to = clock.time(of: Tick(200))
            let g1 = Self.gainError(taps.p1, taps.iso1, from: from, to: to) { _ in 1 }
            let g2 = Self.gainError(taps.p2, taps.iso2, from: from, to: to) { _ in 1 }
            p.check(g1.n > 20_000 && g2.n > 20_000, "样本太少")
            p.check(g1.maxErr < 1e-4, "AFV 关掉之后 PGM 应恒 1（最大差 \(String(format: "%.4f", g1.maxErr))）")
            p.check(g2.maxErr < 1e-4, "AFV 关掉之后 PVW 应恒 1（最大差 \(String(format: "%.4f", g2.maxErr))）")
            problems += p.list.map { "c（全局 AFV 途中关掉）：" + $0 }
            print("W1-D4 第 2 条延伸 c：第 150 拍关 AFV，第 150–200 拍两路与 1 最大差 \(String(format: "%.1e / %.1e", g1.maxErr, g2.maxErr))")
            await rig.shutdown()
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    // MARK: 第 3 条：Cut 恰好落在 Auto 走满那一拍

    /// 30 拍 Auto（第 120 拍起，1→2），Cut 恰好排在走满那一拍（第 150 拍）：画面第 149 拍还差 1/30 走满、第 150 拍切回 1 号。
    /// 修前状态机报"取消"，音频立即按最新状态门控——录音轨里 1 号比画面早约 1 拍 + 对齐延迟就回来了（第 146 拍附近）。
    /// 要求：第 150 拍之前（前一块为止）两路逐样本都还在等幅曲线上（Auto 自己走满），第 150 拍起短淡切回，+1 块后 1 号满、2 号严格 0。
    func testW1D4_3_cutOnTheTickTheAutoElapses_audioSwitchesBackOnThatTick() async throws {
        let (rig, taps) = try await makeRig()
        let s = Tick(120), d = 30
        await rig.sm.schedule(.fade(durationTicks: d), at: s)
        await rig.sm.schedule(.cut, at: s + d)
        await rig.run(seconds: 3.5)
        let state = await rig.sm.state
        XCTAssertEqual([state.program, state.preview], [1, 2], "走满对调后又被 Cut 对调回去")
        let clock = rig.clock, fade = rig.engine.blockDuration, tick = clock.duration(ofTicks: 1)
        let tS = clock.time(of: s), D = clock.duration(ofTicks: d), tE = tS + D
        var p = Problems()
        let e1 = Self.gainError(taps.p1, taps.iso1, from: tS, to: tE - fade) { Self.curve($0, start: tS, duration: D, toPath: false) }
        let e2 = Self.gainError(taps.p2, taps.iso2, from: tS, to: tE - fade) { Self.curve($0, start: tS, duration: D, toPath: true) }
        let at: (HostTime?) -> String = { $0.map { String(format: "第 %.2f 拍", Double(($0 - clock.t0).ticks) / Double(tick.ticks)) } ?? "—" }
        p.check(e1.n > 10_000, "样本太少")
        p.check(e1.maxErr < 1e-3, "走满之前 1 号应在 cos 上（最大差 \(String(format: "%.4f", e1.maxErr))，在\(at(e1.worstAt))）")
        p.check(e2.maxErr < 1e-3, "走满之前 2 号应在 sin 上（最大差 \(String(format: "%.4f", e2.maxErr))，在\(at(e2.worstAt))）")
        let after = min(tE + HostDuration(seconds: 0.8), rig.lastDeliveredWindow(blocks: 1).1)
        p.none(Self.same(taps.p1, taps.iso1, from: tE + fade, to: after), "第 150 拍 + 1 块起 1 号应满")
        p.check(Self.nonzero(taps.p2, from: tE + fade, to: after) == 0, "第 150 拍 + 1 块起 2 号应严格 0")
        let jump = Self.maxJump(taps.master, from: tE - fade * 8, to: tE + fade * 8)
        p.check(jump < 0.1, "切回前后 Master 跳变 \(jump)")
        XCTAssertEqual(p.list, [], "Cut 恰落在 Auto 走满那一拍：\n" + p.list.joined(separator: "\n"))
        print("W1-D4 第 3 条：Auto 30 拍走满那一拍 Cut：走满之前逐样本 AFV 增益与曲线最大差 \(String(format: "%.1e", max(e1.maxErr, e2.maxErr)))；\(p.list.isEmpty ? "+1 块起 1 号满、2 号 0" : p.list.joined(separator: "；"))")
        XCTAssertEqual(rig.engine.status.realtimeViolations, 0)
        await rig.shutdown()
    }
}
