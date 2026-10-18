import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// D11（Codex 2026-10-13 审查，W1-B5 / prompt 120）：FTB 渐变途中改时长（提案 020 允许）只改了画面，Master 的声音继续走旧斜坡。
/// 目标斜坡变了（缩短 / 拉长 / 归零 / 反向淡回 / 淡回途中改时长）声音都要跟画面同一条：
/// 画面电平 = 状态机 reducer 逐拍算出来的 `ftb.level`（这里用同一个 `MixerReducer` 照同样的命令走一遍）；
/// 声音 = Master 录音轨（PTS = 内容时刻）逐块 RMS ÷ 不淡时的电平。−20 dB 以上（1 − level ≥ 0.1）的块与画面电平差 ≤ 0.5 dB
/// （与 AFVTests.testFTB_masterFadesOutAlongTheVideoRamp_andBackIn 同口径），画面全黑那一拍 + 1 拍内 Master ≤ −60 dB、+ 3 拍起样本严格 0。
final class FTBRetargetTests: XCTestCase {
    let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)

    func sine(_ hz: Double) -> (Int, Int64, Int, UnsafeMutablePointer<Float>) -> Void {
        { _, start, n, buf in for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * hz * Double(start + Int64(i)) / 48_000)) } }
    }

    /// 一段斜坡：从第 `from` 拍起生效（命令落下那一拍），之前的内容按上一段走。
    struct Segment { let from: Tick; let on: Bool; let start: Tick; let durationTicks: Int }

    struct Run {
        let rig: EngineRig
        let master: TimedCapture
        /// 画面：第 n 拍的黑比例（reducer 逐拍）。
        let video: [Int64: Double]
        let segments: [Segment]
        let lastTick: Int64
    }

    /// 搭台（1 号 1 kHz 在 PGM、AFV 开 → Master 里只有 1 号），按拍排 FTB 命令跑；同时用同一个 reducer 照走一遍得到画面电平与斜坡分段。
    func run(initialDuration: Int, _ commands: [(Int64, Command)], seconds: Double = 4.6) async throws -> Run {
        var state = States.fourInputs(afv: true)
        state.ftb.durationTicks = initialDuration
        let rig = try await EngineRig(state: state)
        try rig.addSource(number: 1, generator: sine(1000))
        let master = try rig.capture(.master)
        for (t, c) in commands { await rig.sm.schedule(c, at: Tick(t)) }
        await rig.run(seconds: seconds)
        // 画面：与状态机 prepare 同一顺序（先 advance 到这一拍，再应用这一拍的排程命令）
        let reducer = MixerReducer()
        var s = state
        var video: [Int64: Double] = [:]
        var segments: [Segment] = []
        let lastTick = rig.clock.tick(at: rig.lastDeliveredWindow(blocks: 1).1).rawValue
        for n in Int64(0)...lastTick {
            s = reducer.advance(s, to: Tick(n))
            for (t, c) in commands where t == n {
                let before = s.ftb
                s = reducer.reduce(s, c, at: Tick(n))
                if s.ftb != before {
                    segments.append(Segment(from: Tick(n), on: s.ftb.on, start: s.ftb.startTick ?? Tick(n),
                                            durationTicks: s.ftb.startTick == nil ? 0 : s.ftb.durationTicks))
                }
            }
            video[n] = s.ftb.level
        }
        return Run(rig: rig, master: master, video: video, segments: segments, lastTick: lastTick)
    }

    /// 画面电平在内容时刻 x 的值（分段线性：每段从自己的生效拍起，用与音频同一个斜坡函数）。
    func expectedLevel(_ r: Run, at x: HostTime) -> Double {
        guard let seg = r.segments.last(where: { r.rig.clock.time(of: $0.from) <= x }) else { return 0 }
        return AudioProgramGate.fadeToBlackLevel(at: x, on: seg.on, start: r.rig.clock.time(of: seg.start), duration: r.rig.clock.duration(ofTicks: seg.durationTicks))
    }

    /// 逐块：Master 电平跟画面电平（±0.5 dB，−20 dB 以上）；`skip` 里的区间不判（归零那种一拍内的台阶）。返回判了多少块、最大误差。
    @discardableResult
    func assertFollowsVideo(_ r: Run, from: HostTime, skip: [ClosedRange<HostTime>] = [], label: String,
                            file: StaticString = #filePath, line: UInt = #line) -> (blocks: Int, maxErrDb: Double) {
        let block = r.rig.engine.blockDuration
        let end = r.rig.lastDeliveredWindow(blocks: 1).1
        var t = from, compared = 0, maxErr = 0.0
        while t + block <= end {
            let e = t + block, c = t + block / 2
            defer { t = e }
            if skip.contains(where: { $0.overlaps(t...e) }) { continue }
            let level = expectedLevel(r, at: c)
            guard 1 - level >= 0.1 else { continue }
            let err = IT.db(r.master.rms(from: t, to: e) / (baseRMS * (1 - level)))
            maxErr = max(maxErr, abs(err))
            compared += 1
            XCTAssertEqual(err, 0, accuracy: 0.5, "\(label)：拍 \(String(format: "%.2f", Double((c - r.rig.clock.t0).ticks) / Double(r.rig.clock.duration(ofTicks: 1).ticks)))，画面黑 \(String(format: "%.3f", level))，Master 差 \(String(format: "%.2f", err)) dB", file: file, line: line)
        }
        return (compared, maxErr)
    }

    /// 画面第 n 拍全黑：第 n + 1 拍那一拍 Master ≤ −40 dB、n + 2 拍那一拍 ≤ −60 dB，n + 3 拍起到 `until` 拍样本严格 0
    /// （Master 增益是 τ 3 ms 的一阶平滑、控制周期按块：归零这种台阶 −60 dB 要 21 ms + ≤ 1 块，吸到严格 0 要 41 ms + ≤ 1 块）。
    func assertSilentWhenBlack(_ r: Run, blackTick n: Int64, until: Int64, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.video[n], 1, "\(label)：第 \(n) 拍画面应全黑", file: file, line: line)
        let clock = r.rig.clock
        let rms1 = r.master.rms(from: clock.time(of: Tick(n + 1)), to: clock.time(of: Tick(n + 2)))
        XCTAssertLessThanOrEqual(IT.db(rms1 / baseRMS), -40, "\(label)：全黑后第 1 拍 Master 应 ≤ −40 dB（实测 \(IT.db(rms1 / baseRMS)) dB）", file: file, line: line)
        let rms2 = r.master.rms(from: clock.time(of: Tick(n + 2)), to: clock.time(of: Tick(n + 3)))
        XCTAssertLessThanOrEqual(IT.db(rms2 / baseRMS), -60, "\(label)：全黑后第 2 拍 Master 应 ≤ −60 dB（实测 \(IT.db(rms2 / baseRMS)) dB）", file: file, line: line)
        let a = AFVInterruptTests.index(r.master, at: clock.time(of: Tick(n + 3))), b = AFVInterruptTests.index(r.master, at: clock.time(of: Tick(until)))
        XCTAssertLessThan(a, b, file: file, line: line)
        if a < b, b <= r.master.left.count {
            let nonzero = r.master.left[a..<b].filter { $0 != 0 }.count
            XCTAssertEqual(nonzero, 0, "\(label)：第 \(n + 3)…\(until) 拍 Master 应严格 0（\(nonzero) 个样本不是）", file: file, line: line)
            print("D11 \(label)：画面第 \(n) 拍全黑；Master 第 +1 拍 \(String(format: "%.1f", IT.db(rms1 / baseRMS))) dB、第 +2 拍 \(String(format: "%.1f", IT.db(rms2 / baseRMS))) dB、第 +3…\(until - n) 拍非零样本 \(nonzero)")
        }
    }

    // MARK: 缩短（Codex 的触发条件）

    /// 120 拍渐黑走到 30 拍（电平 0.25）改成 30 拍：画面按等效起点 142 在第 172 拍全黑；第 60 拍（相对起点，= 第 180 拍）声音也到底。
    /// 修前：声音按旧斜坡第 240 拍才到底，第 180 拍还在 −6 dB。
    func testD11_shortenMidFade_masterFollowsNewRamp_silentAtTick60() async throws {
        let r = try await run(initialDuration: 120, [(120, .ftb(on: true)), (150, .setFTBDuration(ticks: 30))])
        XCTAssertEqual(r.segments.map(\.start), [Tick(120), Tick(142)], "等效起点：150 − round(0.25 × 30) = 142")
        let clock = r.rig.clock
        let (n, maxErr) = assertFollowsVideo(r, from: clock.time(of: Tick(120)) + r.rig.engine.blockDuration * 2, label: "缩短")
        XCTAssertGreaterThan(n, 30)
        assertSilentWhenBlack(r, blackTick: 172, until: 240, label: "缩短")
        assertSilentWhenBlack(r, blackTick: 180, until: 240, label: "缩短·第 60 拍")
        print("D11 缩短 120→30（第 30 拍）：逐块 \(n) 块最大差 \(String(format: "%.3f", maxErr)) dB；画面第 172 拍全黑")
        await r.rig.shutdown()
    }

    // MARK: 拉长

    /// 30 拍渐黑走到一半（第 135 拍，0.5）改成 120 拍：等效起点 75，第 195 拍才全黑。修前：声音第 150 拍就到底（比画面早 45 拍）。
    func testD11_lengthenMidFade_masterFollowsNewRamp() async throws {
        let r = try await run(initialDuration: 30, [(120, .ftb(on: true)), (135, .setFTBDuration(ticks: 120))])
        XCTAssertEqual(r.segments.map(\.start), [Tick(120), Tick(75)])
        let (n, maxErr) = assertFollowsVideo(r, from: r.rig.clock.time(of: Tick(120)) + r.rig.engine.blockDuration * 2, label: "拉长")
        XCTAssertGreaterThan(n, 60)
        XCTAssertLessThan(r.video[160]!, 1, "第 160 拍画面还没全黑")
        assertSilentWhenBlack(r, blackTick: 195, until: 250, label: "拉长")
        print("D11 拉长 30→120（第 135 拍）：逐块 \(n) 块最大差 \(String(format: "%.3f", maxErr)) dB")
        await r.rig.shutdown()
    }

    // MARK: 归零

    /// 120 拍渐黑走到 30 拍改成 0：画面这一拍直接全黑；声音这一拍的内容时刻起 1 拍内到底。修前：旧斜坡再走 90 拍。
    func testD11_zeroMidFade_masterDropsOnTheSameTick() async throws {
        let r = try await run(initialDuration: 120, [(120, .ftb(on: true)), (150, .setFTBDuration(ticks: 0))])
        let clock = r.rig.clock
        let tZ = clock.time(of: Tick(150))
        // 归零之前照旧斜坡；台阶那一拍不判
        let (n, _) = assertFollowsVideo(r, from: clock.time(of: Tick(120)) + r.rig.engine.blockDuration * 2,
                                        skip: [(tZ - r.rig.engine.blockDuration)...(tZ + clock.duration(ofTicks: 2))], label: "归零")
        XCTAssertGreaterThan(n, 20)
        assertSilentWhenBlack(r, blackTick: 150, until: 240, label: "归零")
        await r.rig.shutdown()
    }

    // MARK: 反向淡回

    /// 30 拍渐黑走到一半（第 135 拍）反向（FTB 关）：状态机把起点回拨到等效起点 120，电平从 0.5 按原时长走回 0（第 150 拍）。
    /// 声音要在第 135 拍那一刻（内容时刻）才换方向——修前：事件一到就换，换早了"对齐延迟 + 1 拍"，换点前约 60 ms 声音比画面低 4 dB。
    func testD11_reverseMidFade_fadesBackWithTheVideo() async throws {
        let r = try await run(initialDuration: 30, [(120, .ftb(on: true)), (135, .ftb(on: false))])
        XCTAssertEqual(r.segments.map(\.start), [Tick(120), Tick(120)])
        let (n, maxErr) = assertFollowsVideo(r, from: r.rig.clock.time(of: Tick(120)) + r.rig.engine.blockDuration * 2, label: "反向淡回")
        XCTAssertGreaterThan(n, 20)
        // 回到画面：第 150 拍起 Master 满
        let (a, b) = (r.rig.clock.time(of: Tick(152)), r.rig.clock.time(of: Tick(200)))
        XCTAssertEqual(r.master.rms(from: a, to: b), baseRMS, accuracy: baseRMS * 0.02)
        print("D11 反向淡回（第 135 拍）：逐块 \(n) 块最大差 \(String(format: "%.3f", maxErr)) dB")
        await r.rig.shutdown()
    }

    /// 淡回画面（FTB 关，30 拍）走到 10 拍改成 60 拍：等效起点 190，第 250 拍才全亮。修前：声音第 230 拍就满了（比画面早 20 拍）。
    func testD11_fadeBackThenLengthen_masterFollowsNewRamp() async throws {
        let r = try await run(initialDuration: 30, [(120, .ftb(on: true)), (200, .ftb(on: false)), (210, .setFTBDuration(ticks: 60))])
        XCTAssertEqual(r.segments.map(\.start), [Tick(120), Tick(200), Tick(190)])
        let (n, maxErr) = assertFollowsVideo(r, from: r.rig.clock.time(of: Tick(200)) + r.rig.engine.blockDuration * 2, label: "淡回途中拉长")
        XCTAssertGreaterThan(n, 60)
        XCTAssertGreaterThan(r.video[235]!, 0, "第 235 拍画面还没全亮")
        print("D11 淡回途中拉长 30→60（第 210 拍）：逐块 \(n) 块最大差 \(String(format: "%.3f", maxErr)) dB")
        await r.rig.shutdown()
    }
}
