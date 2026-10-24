import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// W1-D4 第 5 条（prompt 125；reports/w1-core-5.md §3 第 6 条）：FTB 声音跟画面的精度在**实时模式**（空设备 + 控制线程）下量一次，只量不判。
/// 离线台（EngineRig）每块恰在块首跑一次控制周期，D11 四种改法逐块最大差 0.11–0.12 dB；线程模式下控制周期（2 ms）与 IOProc 块不同相，
/// Master 增益目标在下一块开头才生效，FTB 的提前量（3 ms + 半块）没算这一段。口径同 FTBRetargetTests：Master 逐块 RMS ÷ 不淡时的电平 vs 画面电平
/// （reducer 逐拍算的 ftb.level，按生效拍分段），−20 dB 以上的块才比；归零那一拍的台阶不比；全黑之后看 +1 / +2 拍电平与 +3 拍起的非零样本。
/// 同一份量法对离线台也跑一遍，两边的数并排打印（报告用）。测试标准 §4 没有这一项的阈值，本用例不设阈值。
enum FTBFollowMeasure {
    struct Segment { let from: Tick; let on: Bool; let start: Tick; let durationTicks: Int }
    struct Case { let name: String; let initialDuration: Int; let commands: [(Int64, Command)]; let blackTick: Int64?; let stepTick: Int64? }

    /// D11 的四种改法（与 FTBRetargetTests 同一组命令）。
    static let cases: [Case] = [
        Case(name: "缩短 120→30（第 150 拍）", initialDuration: 120, commands: [(120, .ftb(on: true)), (150, .setFTBDuration(ticks: 30))], blackTick: 172, stepTick: nil),
        Case(name: "拉长 30→120（第 135 拍）", initialDuration: 30, commands: [(120, .ftb(on: true)), (135, .setFTBDuration(ticks: 120))], blackTick: 195, stepTick: nil),
        Case(name: "归零（第 150 拍）", initialDuration: 120, commands: [(120, .ftb(on: true)), (150, .setFTBDuration(ticks: 0))], blackTick: 150, stepTick: 150),
        Case(name: "反向淡回（第 135 拍）", initialDuration: 30, commands: [(120, .ftb(on: true)), (135, .ftb(on: false))], blackTick: nil, stepTick: nil),
    ]

    /// 画面：与状态机 prepare 同一顺序（先 advance 到这一拍、再应用这一拍的排程命令）逐拍算 ftb.level，记下斜坡分段（从生效拍起）。
    static func replay(_ state: MixerState, _ commands: [(Int64, Command)], through lastTick: Int64) -> (video: [Int64: Double], segments: [Segment]) {
        let reducer = MixerReducer()
        var s = state
        var video: [Int64: Double] = [:]
        var segments: [Segment] = []
        for n in Int64(0)...max(0, lastTick) {
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
        return (video, segments)
    }

    static func expectedLevel(_ segments: [Segment], clock: TickClockSpec, at x: HostTime) -> Double {
        guard let seg = segments.last(where: { clock.time(of: $0.from) <= x }) else { return 0 }
        return AudioProgramGate.fadeToBlackLevel(at: x, on: seg.on, start: clock.time(of: seg.start), duration: clock.duration(ofTicks: seg.durationTicks))
    }

    struct Result {
        var blocks = 0
        var maxErrDb = 0.0
        var meanAbsErrDb = 0.0
        /// 最大差那一块的中心（拍）。
        var worstTick = 0.0
        /// 全黑之后 +1 / +2 拍的电平（dB）、+3 拍起到 +60 拍的非零样本数。
        var blackPlus1Db: Double?
        var blackPlus2Db: Double?
        var blackNonzero: Int?
        var line: String {
            var s = "逐块 \(blocks) 块最大差 \(String(format: "%.3f", maxErrDb)) dB（第 \(String(format: "%.1f", worstTick)) 拍）、平均 |差| \(String(format: "%.3f", meanAbsErrDb)) dB"
            if let a = blackPlus1Db, let b = blackPlus2Db, let n = blackNonzero {
                s += "；全黑后 +1 拍 \(String(format: "%.1f", a)) dB、+2 拍 \(String(format: "%.1f", b)) dB、+3 拍起非零样本 \(n)"
            }
            return s
        }
    }

    /// 按 FTBRetargetTests.assertFollowsVideo / assertSilentWhenBlack 的口径量（不断言）。
    static func measure(_ c: Case, master: TimedCapture, video: [Int64: Double], segments: [Segment], clock: TickClockSpec,
                        block: HostDuration, end: HostTime, baseRMS: Double) -> Result {
        var r = Result()
        let tick = clock.duration(ofTicks: 1)
        let skip: ClosedRange<HostTime>? = c.stepTick.map { clock.time(of: Tick($0)) - block...clock.time(of: Tick($0)) + tick * 2 }
        var t = clock.time(of: Tick(120)) + block * 2
        var sumAbs = 0.0
        while t + block <= end {
            let e = t + block, mid = t + block / 2
            defer { t = e }
            if let skip, skip.overlaps(t...e) { continue }
            let level = expectedLevel(segments, clock: clock, at: mid)
            guard 1 - level >= 0.1 else { continue }
            let err = IT.db(master.rms(from: t, to: e) / (baseRMS * (1 - level)))
            r.blocks += 1
            sumAbs += abs(err)
            if abs(err) > r.maxErrDb { r.maxErrDb = abs(err); r.worstTick = Double((mid - clock.t0).ticks) / Double(tick.ticks) }
        }
        r.meanAbsErrDb = r.blocks > 0 ? sumAbs / Double(r.blocks) : 0
        if let n = c.blackTick, video[n] == 1 {
            r.blackPlus1Db = IT.db(master.rms(from: clock.time(of: Tick(n + 1)), to: clock.time(of: Tick(n + 2))) / baseRMS)
            r.blackPlus2Db = IT.db(master.rms(from: clock.time(of: Tick(n + 2)), to: clock.time(of: Tick(n + 3))) / baseRMS)
            let a = AFVInterruptTests.index(master, at: clock.time(of: Tick(n + 3)))
            let b = min(AFVInterruptTests.index(master, at: clock.time(of: Tick(n + 60))), master.left.count)
            r.blackNonzero = b > a ? master.left[a..<b].filter { $0 != 0 }.count : nil
        }
        return r
    }
}

extension IntegrationRealtimeTests {
    /// 带自定义初始状态的实时台（FTB 时长要在初始状态里设）。
    func makeRig(state: MixerState, output: AudioEngineConfiguration.Output) async throws -> Rig {
        let sm = StateMachine(initialState: state)
        sm.start()
        var cfg = AudioEngineConfiguration()
        cfg.output = output
        cfg.outputChannelMap = BusChannelMap(master: nil)
        let engine = try AudioEngine(stateMachine: sm, configuration: cfg)
        let t0 = HostClock.now() + HostDuration(milliseconds: 300)
        let clock = TickClockSpec(t0: t0, frameRate: .fps60)
        try await engine.start(clock: clock)
        return Rig(sm: sm, engine: engine, clock: clock, t0: t0)
    }

    /// W1-D4 第 5 条：空设备 + 控制线程跑 D11 的四种改法（缩短 / 拉长 / 归零 / 反向），Master 跟画面的逐块误差与全黑后的电平；离线台同一组并排。只量不判。
    func testW1D4_5_nullDevice_ftbRetargetFollowAccuracy_measuredOnly() async throws {
        let baseRMS = 0.5 / sqrt(2.0) / sqrt(2.0)
        let sine: (Int64, Int, UnsafeMutablePointer<Float>) -> Void = { start, n, buf in
            for i in 0..<n { buf[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(start + Int64(i)) / 48_000)) }
        }
        var lines: [String] = []
        for c in FTBFollowMeasure.cases {
            var state = States.fourInputs(afv: true)
            state.ftb.durationTicks = c.initialDuration
            // 离线台（每块一个控制周期、恰在块首）
            let off = try await EngineRig(state: state)
            try off.addSource(number: 1) { _, start, n, buf in sine(start, n, buf) }
            let offMaster = try off.capture(.master)
            for (t, cmd) in c.commands { await off.sm.schedule(cmd, at: Tick(t)) }
            await off.run(seconds: 4.6)
            let offEnd = off.lastDeliveredWindow(blocks: 1).1
            let offReplay = FTBFollowMeasure.replay(state, c.commands, through: off.clock.tick(at: offEnd).rawValue)
            let offResult = FTBFollowMeasure.measure(c, master: offMaster, video: offReplay.video, segments: offReplay.segments, clock: off.clock,
                                                     block: off.engine.blockDuration, end: offEnd, baseRMS: baseRMS)
            await off.shutdown()
            // 实时（空设备 + 控制线程）
            var rig = try await makeRig(state: state, output: .null)
            try addSource(&rig, number: 1, generator: sine)
            let master = TimedCapture()
            try rig.engine.addConsumer(CaptureConsumer(name: "ftb-master", capture: master), source: .master)
            for (t, cmd) in c.commands { await rig.sm.schedule(cmd, at: Tick(t)) }
            await driveStateMachine(rig, until: rig.t0 + HostDuration(seconds: 4.6))
            let st = rig.engine.status
            await shutdown(rig)
            XCTAssertGreaterThan(master.left.count, 48_000 * 3, "\(c.name)：实时录音轨太短")
            XCTAssertTrue(master.gaps.isEmpty, "\(c.name)：实时录音轨有缺口 \(master.gaps.prefix(3))")
            let end = master.hostTime(ofSample: master.left.count)
            let replay = FTBFollowMeasure.replay(state, c.commands, through: rig.clock.tick(at: end).rawValue)
            let result = FTBFollowMeasure.measure(c, master: master, video: replay.video, segments: replay.segments, clock: rig.clock,
                                                  block: rig.engine.blockDuration, end: end, baseRMS: baseRMS)
            XCTAssertGreaterThan(result.blocks, 20, "\(c.name)：实时比到的块太少")
            XCTAssertGreaterThan(offResult.blocks, 20, "\(c.name)：离线比到的块太少")
            XCTAssertEqual(st.realtimeViolations, 0)
            lines.append("\(c.name)\n    实时：\(result.line)；控制周期 \(rig.engine.controlCycles) 次、dropouts \(st.counters.dropouts) underruns \(st.counters.underruns) 空设备最晚醒 \(String(format: "%.3f", st.device.maxJitterMs)) ms\n    离线：\(offResult.line)")
        }
        print("W1-D4 第 5 条 FTB 跟随精度（实时 = 空设备 + 控制线程；只量不判）：\n" + lines.joined(separator: "\n"))
    }
}
