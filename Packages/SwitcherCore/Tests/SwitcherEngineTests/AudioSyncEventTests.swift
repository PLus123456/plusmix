import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

// W1-B5（prompt 120）：Codex 2026-10-13 审查的 D10 / D11 在引擎侧的口径。
//   D10：状态机区分"auto 走满"与"被 Cut / T-bar 推到底打断"与"T-bar 提交"（TransitionCompletion），音频侧据此决定要不要短淡收口。
//   D11：FTB 的目标斜坡变了（方向、起点、时长）就发事件，带改的那一拍；音频照事件分段重建的斜坡必须与画面逐拍相等。

final class AudioSyncEventTests: XCTestCase {
    /// 节目时钟：t0 = 10 s（等效起点可以是负拍），60 fps。
    let clock = TickClockSpec(t0: HostTime(nanoseconds: 10_000_000_000), frameRate: .fps60)

    func makeMachine(_ configure: (inout MixerState) -> Void = { _ in }) -> StateMachine {
        var s = ReducerTests.baseState()
        s.audio.afv = true
        configure(&s)
        let sm = StateMachine(initialState: s)
        sm.start()
        return sm
    }

    func completions(_ c: EventCollector) -> [TransitionEvent] {
        c.events.map(\.0).filter { if case .completed = $0 { return true } else { return false } }
    }

    // MARK: D10 完成的三种

    /// 10 s Auto（600 拍）第 1 秒 Cut（排程路）：对调那一拍报 interrupted，不是 elapsed。
    func testD10_cutDuringAuto_completesAsInterrupted_scheduled() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        await sm.schedule(.fade(durationTicks: 600), at: Tick(120))
        await sm.schedule(.cut, at: Tick(180))
        await sm.prepare(upTo: Tick(800))
        XCTAssertEqual(c.events.map(\.0), [
            .started(tick: Tick(120), type: .fade, durationTicks: 600, from: 1, to: 2, source: .auto),
            .completed(tick: Tick(180), from: 1, to: 2, completion: .interrupted),
        ], "Cut 之后不再有第 720 拍的完成")
    }

    /// 命令路（API / 键盘：apply 落在渲染线程还没消费的最早一拍）同样是 interrupted；回执的拍 = 事件的拍。
    func testD10_cutDuringAuto_completesAsInterrupted_applied() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        await sm.schedule(.fade(durationTicks: 600), at: Tick(120))
        await sm.prepare(upTo: Tick(179))
        sm.noteRendered(Tick(179))
        let r = await sm.apply(.cut)
        XCTAssertEqual(r.appliedTick, Tick(180))
        XCTAssertEqual(completions(c), [.completed(tick: Tick(180), from: 1, to: 2, completion: .interrupted)])
    }

    /// Auto 进行中 T-bar 一下推到底（没有接管的中间态）：reducer 直接对调，同 Cut。
    func testD10_tbarToOneDuringAuto_completesAsInterrupted() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        await sm.schedule(.fade(durationTicks: 600), at: Tick(120))
        await sm.schedule(.tbar(progress: 1), at: Tick(180))
        await sm.prepare(upTo: Tick(200))
        XCTAssertEqual(completions(c), [.completed(tick: Tick(180), from: 1, to: 2, completion: .interrupted)])
    }

    /// 走满：完成拍 = 开始拍 + 时长，elapsed；时长 1 拍的 auto 也是（第 s + 1 拍完成）。
    func testD10_naturalCompletion_isElapsed() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        await sm.schedule(.fade(durationTicks: 30), at: Tick(300))
        await sm.schedule(.fade(durationTicks: 1), at: Tick(400))
        await sm.prepare(upTo: Tick(500))
        XCTAssertEqual(completions(c), [
            .completed(tick: Tick(330), from: 1, to: 2, completion: .elapsed),
            .completed(tick: Tick(401), from: 2, to: 1, completion: .elapsed),
        ])
    }

    /// 走满的前一拍按 Cut 仍是 interrupted（边界：第 s + d − 1 拍）。
    func testD10_cutOnTheLastTickBeforeTheEnd_isInterrupted() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        await sm.schedule(.fade(durationTicks: 30), at: Tick(300))
        await sm.schedule(.cut, at: Tick(329))
        await sm.prepare(upTo: Tick(400))
        XCTAssertEqual(completions(c), [.completed(tick: Tick(329), from: 1, to: 2, completion: .interrupted)])
    }

    /// T-bar：推到底提交 = tbar；推到一半按 Cut 也是 tbar；接管进行中的 auto 之后再推到底 = tbar（不是 elapsed / interrupted）。
    func testD10_tbarTransitions_completeAsTbar() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let c = EventCollector()
        await sm.addTransitionSink(c)
        _ = await sm.apply(.tbar(progress: 0.5))
        _ = await sm.apply(.tbar(progress: 1.0))                 // 1 → 2
        _ = await sm.apply(.tbar(progress: 0.3))
        _ = await sm.apply(.cut)                                 // 2 → 1
        await sm.schedule(.fade(durationTicks: 600), at: Tick(100))
        await sm.prepare(upTo: Tick(150))
        _ = await sm.apply(.tbar(progress: 0.6))                 // 接管 auto（1 → 2）
        _ = await sm.apply(.tbar(progress: 1.0))
        XCTAssertEqual(completions(c), [
            .completed(tick: .zero, from: 1, to: 2, completion: .tbar),
            .completed(tick: .zero, from: 2, to: 1, completion: .tbar),
            .completed(tick: Tick(150), from: 1, to: 2, completion: .tbar),
        ])
    }

    /// 桥照带：interrupted → transitionEnded(completion: .interrupted)，拍点 = Cut 那一拍；取消 = nil。
    func testD10_bridgeCarriesCompletion() {
        XCTAssertEqual(AudioStateBridge.convert(.completed(tick: Tick(180), from: 1, to: 2, completion: .interrupted), clock: clock),
                       .transitionEnded(program: 2, preview: 1, tick: Tick(180), at: clock.time(of: Tick(180)), completion: .interrupted))
        XCTAssertEqual(AudioStateBridge.convert(.completed(tick: Tick(330), from: 1, to: 2, completion: .elapsed), clock: clock),
                       .transitionEnded(program: 2, preview: 1, tick: Tick(330), at: clock.time(of: Tick(330)), completion: .elapsed))
        XCTAssertEqual(AudioStateBridge.convert(.cancelled(tick: Tick(5)), clock: clock),
                       .transitionEnded(program: 0, preview: 0, tick: Tick(5), at: clock.time(of: Tick(5)), completion: nil))
    }

    // MARK: D11 FTB 目标斜坡变了

    /// Codex 的探针：120 拍渐黑走到 30 拍（电平 0.25）改成 30 拍。修前：桥一个事件都不发，第 60 拍画面全黑、旧斜坡的声音还在 0.5。
    func testD11_codexProbe_shortenAtTick30_emitsNewRamp_audioAtBottomOnTick60() {
        let reducer = MixerReducer()
        var initial = ReducerTests.baseState()
        initial.ftb.durationTicks = 120
        let started = reducer.reduce(initial, .ftb(on: true), at: Tick(0))
        let mid = reducer.advance(started, to: Tick(30))
        let changed = reducer.reduce(mid, .setFTBDuration(ticks: 30), at: Tick(30))
        XCTAssertEqual(mid.ftb.level, 0.25)
        let events = StateMachine.events(from: mid, to: changed, tick: Tick(30))
        XCTAssertEqual(events, [.fadeToBlack(tick: Tick(30), on: true, startTick: Tick(22), durationTicks: 30)], "等效起点 30 − round(0.25 × 30) = 22")
        guard case .fadeToBlack(let on, _, let at, _, let duration, let effectiveTick, let effectiveAt)? = events.first.map({ AudioStateBridge.convert($0, clock: clock) }) else {
            return XCTFail("\(events)")
        }
        XCTAssertEqual(effectiveTick, Tick(30))
        XCTAssertEqual(effectiveAt, clock.time(of: Tick(30)))
        let videoAt60 = reducer.advance(changed, to: Tick(60)).ftb.level
        let audioAt60 = AudioProgramGate.fadeToBlackLevel(at: clock.time(of: Tick(60)), on: on, start: at, duration: duration)
        XCTAssertEqual(videoAt60, 1)
        XCTAssertEqual(audioAt60, 1, "第 60 拍画面全黑时音频斜坡也到底")
    }

    /// 什么时候不发：进度变化、自然走完、空闲时改时长、同值（reducer 原样返回）。
    func testD11_noEventForProgressNaturalEndOrIdleDurationChange() {
        let reducer = MixerReducer()
        var s = ReducerTests.baseState()
        s = reducer.reduce(s, .ftb(on: true), at: Tick(0))
        let progressed = reducer.advance(s, to: Tick(10))
        XCTAssertEqual(StateMachine.events(from: s, to: progressed, tick: Tick(10)), [], "进度变化")
        let before = reducer.advance(s, to: Tick(29)), done = reducer.advance(s, to: Tick(30))
        XCTAssertNil(done.ftb.startTick)
        XCTAssertEqual(StateMachine.events(from: before, to: done, tick: Tick(30)), [], "自然走完")
        let idle = reducer.reduce(done, .setFTBDuration(ticks: 45), at: Tick(40))
        XCTAssertEqual(idle.ftb.durationTicks, 45)
        XCTAssertEqual(StateMachine.events(from: done, to: idle, tick: Tick(40)), [], "空闲时改时长只是设置")
    }

    /// 全量（音频引擎起来时的第一次轮询）：on 或斜坡还在走（含淡回画面途中）就报告；生效拍 = 快照的拍。
    func testD11_fullSyncReportsRampInProgressIncludingFadeBack() {
        var s = ReducerTests.baseState()
        s.ftb = FadeToBlack(on: false, durationTicks: 30, level: 0.6, startTick: Tick(88))
        let events = AudioStateBridge.diff(from: nil, to: s, tick: Tick(100), clock: clock)
        XCTAssertTrue(events.contains(.fadeToBlack(on: false, startTick: Tick(88), at: clock.time(of: Tick(88)), durationTicks: 30,
                                                   duration: clock.duration(ofTicks: 30), effectiveTick: Tick(100), effectiveAt: clock.time(of: Tick(100)))), "\(events)")
        var idle = ReducerTests.baseState()
        idle.ftb = FadeToBlack(on: false, durationTicks: 30, level: 0, startTick: nil)
        XCTAssertFalse(AudioStateBridge.diff(from: nil, to: idle, tick: Tick(100), clock: clock).contains { if case .fadeToBlack = $0 { return true } else { return false } })
        // 增量 diff 不再发 FTB（走转场事件那条路）
        XCTAssertEqual(AudioStateBridge.diff(from: idle, to: s, tick: Tick(100), clock: clock), [])
    }

    /// 核心不变量：跑真的状态机（排程 + 命令两条路），桥收到的 FTB 事件按生效拍分段重建的音频斜坡，在每一拍的拍点 = 画面的 ftb.level。
    /// 缩短 / 拉长 / 归零 / 反向淡回 / 淡回途中改时长 / 同一拍来回翻 / 空闲改时长 七种。
    func testD11_audioRampRebuiltFromEvents_equalsVideoLevelOnEveryTick() async {
        struct Case { let name: String; let initialDuration: Int; let commands: [(Int64, Command)] }
        let cases: [Case] = [
            Case(name: "缩短 120→30", initialDuration: 120, commands: [(100, .ftb(on: true)), (130, .setFTBDuration(ticks: 30))]),
            Case(name: "拉长 30→120", initialDuration: 30, commands: [(100, .ftb(on: true)), (115, .setFTBDuration(ticks: 120))]),
            Case(name: "归零", initialDuration: 120, commands: [(100, .ftb(on: true)), (130, .setFTBDuration(ticks: 0))]),
            Case(name: "反向淡回", initialDuration: 30, commands: [(100, .ftb(on: true)), (115, .ftb(on: false))]),
            Case(name: "淡回途中拉长", initialDuration: 30, commands: [(100, .ftb(on: true)), (150, .ftb(on: false)), (160, .setFTBDuration(ticks: 60))]),
            Case(name: "同一拍来回翻", initialDuration: 30, commands: [(100, .ftb(on: true)), (110, .ftb(on: false)), (110, .ftb(on: true))]),
            Case(name: "空闲改时长再黑", initialDuration: 30, commands: [(100, .setFTBDuration(ticks: 12)), (120, .ftb(on: true)), (125, .setFTBDuration(ticks: 6))]),
        ]
        for c in cases {
            let sm = makeMachine { $0.ftb.durationTicks = c.initialDuration }
            let sink = AudioControlEventCollector()
            let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
            await bridge.attach()
            for (t, cmd) in c.commands { await sm.schedule(cmd, at: Tick(t)) }
            var video: [Double] = []
            for n in 0...260 {
                await sm.prepare(upTo: Tick(Int64(n)))
                video.append(await sm.state.ftb.level)
            }
            let ramps: [(effective: Tick, on: Bool, start: HostTime, duration: HostDuration)] = sink.events.compactMap {
                if case .fadeToBlack(let on, _, let at, _, let duration, let eff, _) = $0 { return (eff, on, at, duration) } else { return nil }
            }
            XCTAssertFalse(ramps.isEmpty, c.name)
            for n in 0...260 {
                let tick = Tick(Int64(n))
                let audio: Double
                if let r = ramps.last(where: { $0.effective <= tick }) {
                    audio = AudioProgramGate.fadeToBlackLevel(at: clock.time(of: tick), on: r.on, start: r.start, duration: r.duration)
                } else {
                    audio = 0
                }
                XCTAssertEqual(audio, video[n], accuracy: 1e-9, "\(c.name)：第 \(n) 拍音频斜坡 \(audio) ≠ 画面 \(video[n])")
            }
            await bridge.detach()
            sm.stop()
        }
    }

    /// 命令路：API 在渐变途中改时长（apply 落在渲染线程还没消费的最早一拍）——事件的生效拍 = 回执的拍。
    func testD11_appliedDurationChange_effectiveTickIsTheReceiptTick() async {
        let sm = makeMachine { $0.ftb.durationTicks = 120 }
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        await bridge.attach()
        await sm.schedule(.ftb(on: true), at: Tick(100))
        await sm.prepare(upTo: Tick(140))
        sm.noteRendered(Tick(140))
        sink.reset()
        let r = await sm.apply(.setFTBDuration(ticks: 30))
        XCTAssertTrue(r.applied)
        XCTAssertEqual(r.appliedTick, Tick(141))
        guard case .fadeToBlack(true, let start, _, 30, _, let eff, _)? = sink.events.first else { return XCTFail("\(sink.events)") }
        XCTAssertEqual(eff, Tick(141))
        XCTAssertEqual(start, Tick(141) - Int((Double(41) / 120 * 30).rounded()), "等效起点 = 141 − round(41/120 × 30)")
        await bridge.detach()
    }
}
