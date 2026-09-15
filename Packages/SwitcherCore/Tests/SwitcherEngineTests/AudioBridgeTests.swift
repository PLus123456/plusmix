import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

// W2-E 引擎侧：状态机 → 音频控制事件（AFV / FTB / 每路参数 / 总线 / 监听），拍点换算成 host time。
// 音频侧（SwitcherAudioIntegration）只认这些事件，不看拍；这里证明事件的拍、时刻、时长都和状态机的口径一致。

final class AudioControlEventCollector: AudioControlEventSink, @unchecked Sendable {
    private let lock = Mutex<[AudioControlEvent]>([])
    func audioControl(_ event: AudioControlEvent) { lock.withLock { $0.append(event) } }
    var events: [AudioControlEvent] { lock.withLock { $0 } }
    func reset() { lock.withLock { $0.removeAll() } }
}

final class AudioBridgeTests: XCTestCase {
    /// 节目时钟：t0 = 10 s，60 fps。
    let clock = TickClockSpec(t0: HostTime(nanoseconds: 10_000_000_000), frameRate: .fps60)

    func makeMachine(afv: Bool = true) -> StateMachine {
        var s = ReducerTests.baseState()
        s.audio.afv = afv
        let sm = StateMachine(initialState: s)
        sm.start()
        return sm
    }

    // MARK: AFV：转场事件 → 交叉淡变（起点 = 起始拍的拍点，长度 = 转场时长）

    func testAFV_fadeScheduledAtTickS_emitsCrossfadeStartingAtTickTime_lengthEqualsTransition() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        await bridge.attach()
        await sm.schedule(.fade(durationTicks: 30), at: Tick(300))
        await sm.prepare(upTo: Tick(340))
        let events = sink.events
        let started = events.first { if case .transitionStarted = $0 { return true } else { return false } }
        XCTAssertEqual(started, .transitionStarted(from: 1, to: 2, type: .fade, source: .auto, tick: Tick(300), at: clock.time(of: Tick(300)),
                                                   durationTicks: 30, duration: clock.duration(ofTicks: 30)))
        XCTAssertEqual(clock.duration(ofTicks: 30).milliseconds, 500, accuracy: 0.001)
        let ended = events.first { if case .transitionEnded = $0 { return true } else { return false } }
        XCTAssertEqual(ended, .transitionEnded(program: 2, preview: 1, tick: Tick(330), at: clock.time(of: Tick(330)), completed: true))
        await bridge.detach()
    }

    func testAFV_cut_emitsCutAtTheTickTime() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        await bridge.attach()
        await sm.schedule(.cut, at: Tick(1000))
        await sm.prepare(upTo: Tick(1000))
        XCTAssertEqual(sink.events, [.cut(from: 1, to: 2, tick: Tick(1000), at: clock.time(of: Tick(1000)))])
        // setProgram 也是瞬时切换
        sink.reset()
        _ = await sm.apply(.setProgram(input: 3))
        XCTAssertEqual(sink.events.count, 1)
        if case .cut(let from, let to, _, _)? = sink.events.first {
            XCTAssertEqual(from, 2); XCTAssertEqual(to, 3)
        } else { XCTFail("应是 cut 事件：\(sink.events)") }
    }

    func testAFV_5994_transitionStartAndDurationUseRationalTicks() async {
        var s = ReducerTests.baseState()
        s.format = .hd1080p5994
        s.audio.afv = true
        let sm = StateMachine(initialState: s)
        sm.start()
        defer { sm.stop() }
        let c = TickClockSpec(t0: HostTime(nanoseconds: 1_000_000), frameRate: .fps5994)
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: c, sink: sink)
        await bridge.attach()
        await sm.schedule(.fade(durationTicks: 30), at: Tick(216_000))   // 一小时后的拍
        await sm.prepare(upTo: Tick(216_000))
        guard case .transitionStarted(_, _, _, _, let tick, let at, let d, let duration)? = sink.events.first else {
            return XCTFail("没有 started 事件：\(sink.events)")
        }
        XCTAssertEqual(tick, Tick(216_000))
        XCTAssertEqual(at, c.time(of: Tick(216_000)))
        XCTAssertEqual(Double(at.nanoseconds - c.t0.nanoseconds) / 1e9, 216_000 * 1001.0 / 60_000, accuracy: 1e-6, "第 216000 拍 = 3603.6 s，有理数不漂")
        XCTAssertEqual(d, 30)
        XCTAssertEqual(duration.milliseconds, 30 * 1001.0 / 60, accuracy: 1e-6)
    }

    // MARK: T-bar：进度事件

    func testAFV_tbar_progressEventsFollowTheBar_thenEndedOnCommit() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        await bridge.attach()
        bridge.pollSnapshot()      // 初始快照（全量事件）
        sink.reset()
        _ = await sm.apply(.tbar(progress: 0.25))
        bridge.pollSnapshot()
        _ = await sm.apply(.tbar(progress: 0.5))
        bridge.pollSnapshot()
        _ = await sm.apply(.tbar(progress: 1.0))
        bridge.pollSnapshot()
        let e = sink.events
        XCTAssertTrue(e.contains(.tbarProgress(from: 1, to: 2, progress: 0.25)), "\(e)")
        XCTAssertTrue(e.contains(.tbarProgress(from: 1, to: 2, progress: 0.5)), "\(e)")
        XCTAssertTrue(e.contains { if case .transitionEnded(let p, let v, _, _, let done) = $0 { return p == 2 && v == 1 && done } else { return false } }, "\(e)")
        // started(tbar) 先于第一个进度
        let startedIndex = e.firstIndex { if case .transitionStarted(_, _, _, let src, _, _, _, _) = $0 { return src == .tbar } else { return false } }
        let progressIndex = e.firstIndex { if case .tbarProgress = $0 { return true } else { return false } }
        XCTAssertNotNil(startedIndex); XCTAssertNotNil(progressIndex)
        if let s = startedIndex, let p = progressIndex { XCTAssertLessThan(s, p) }
    }

    // MARK: 门控纯函数

    func testAFV_gate_programOne_previewByProgress_othersZero_offMeansAllOne() {
        var s = ReducerTests.baseState()
        s.audio.afv = true
        XCTAssertEqual(AudioProgramGate.gains(for: s), [1: 1, 2: 0, 3: 0, 4: 0])
        // 转场中：等幅曲线
        s.transition.startTick = Tick(0)
        s.transition.progress = 0.5
        let g = AudioProgramGate.gains(for: s)
        XCTAssertEqual(Double(g[1]!), cos(Double.pi / 4), accuracy: 1e-6)
        XCTAssertEqual(Double(g[2]!), sin(Double.pi / 4), accuracy: 1e-6)
        XCTAssertEqual(g[3], 0)
        // 黑场：PGM = 0 → 没人为 1
        var b = ReducerTests.baseState()
        b.audio.afv = true
        b.program = 0
        XCTAssertEqual(AudioProgramGate.gains(for: b), [1: 0, 2: 0, 3: 0, 4: 0])
        // AFV 关：全部 1
        var off = ReducerTests.baseState()
        off.audio.afv = false
        off.transition.startTick = Tick(0)
        off.transition.progress = 0.5
        XCTAssertEqual(AudioProgramGate.gains(for: off), [1: 1, 2: 1, 3: 1, 4: 1])
    }

    // MARK: FTB

    func testFTB_toggleEmitsRamp_startTickAndDurationMatchStateMachine_reversalKeepsLevel() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        bridge.pollSnapshot()
        sink.reset()
        await sm.schedule(.ftb(on: true), at: Tick(100))
        await sm.prepare(upTo: Tick(110))
        bridge.pollSnapshot()
        XCTAssertEqual(sink.events, [.fadeToBlack(on: true, startTick: Tick(100), at: clock.time(of: Tick(100)), durationTicks: 30,
                                                  duration: clock.duration(ofTicks: 30))])
        // 第 115 拍反转（level = 15/30 = 0.5）：状态机把起点回拨到 100（等效起点），我们照发
        sink.reset()
        await sm.schedule(.ftb(on: false), at: Tick(115))
        await sm.prepare(upTo: Tick(116))
        bridge.pollSnapshot()
        guard case .fadeToBlack(let on, let start, let at, let d, _)? = sink.events.first else { return XCTFail("\(sink.events)") }
        XCTAssertFalse(on)
        XCTAssertEqual(d, 30)
        XCTAssertEqual(start, Tick(100), "从 0.5 往回走：等效起点 = 115 − 15 = 100")
        XCTAssertEqual(at, clock.time(of: Tick(100)))
        // 期间没有 ftb 事件重复发（progress 变化不算）
        sink.reset()
        await sm.prepare(upTo: Tick(140))
        bridge.pollSnapshot()
        XCTAssertFalse(sink.events.contains { if case .fadeToBlack = $0 { return true } else { return false } })
    }

    func testFTB_levelAt_followsRamp() {
        let start = clock.time(of: Tick(100))
        let d = clock.duration(ofTicks: 30)
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: start, on: true, start: start, duration: d), 0)
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: clock.time(of: Tick(115)), on: true, start: start, duration: d), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: clock.time(of: Tick(130)), on: true, start: start, duration: d), 1)
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: clock.time(of: Tick(200)), on: true, start: start, duration: d), 1)
        // 反向
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: clock.time(of: Tick(115)), on: false, start: start, duration: d), 0.5, accuracy: 1e-9)
        // 时长 0：立即到位
        XCTAssertEqual(AudioProgramGate.fadeToBlackLevel(at: start, on: true, start: start, duration: .zero), 1)
    }

    // MARK: 快照 diff：每路参数 / 总线 / 监听 / AFV 开关 / 输入表

    func testDiff_initialPollEmitsFullState_thenOnlyChanges() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        XCTAssertTrue(bridge.pollSnapshot())
        let initial = sink.events
        XCTAssertTrue(initial.contains { if case .inputsChanged(let added, let removed) = $0 { return added.map(\.number) == [1, 2, 3, 4] && removed.isEmpty } else { return false } }, "\(initial)")
        XCTAssertTrue(initial.contains { if case .buses(let b) = $0 { return b.map(\.bus) == Bus.allCases } else { return false } })
        XCTAssertTrue(initial.contains(.monitorMode(.afl)))
        XCTAssertTrue(initial.contains(.afv(on: true)))
        XCTAssertFalse(bridge.pollSnapshot(), "没有新快照就没有事件")
        sink.reset()

        _ = await sm.apply(.audioGain(input: 2, dB: -6))
        XCTAssertTrue(bridge.pollSnapshot())
        var expected = InputAudioSettings()
        expected.gainDb = -6
        XCTAssertEqual(sink.events, [.inputAudioSettings(input: 2, settings: expected)])
        sink.reset()

        var settings = InputSettings()
        settings.audio = InputAudioSettings(routing: BusRouting(master: true, headphones: true), gainDb: 3, muted: true, solo: true, pan: -0.5, delayMs: 120)
        _ = await sm.apply(.setInputSettings(input: 3, settings: settings))
        _ = await sm.apply(.busGain(bus: .master, dB: -3))
        _ = await sm.apply(.busMute(bus: .headphones, on: true))
        _ = await sm.apply(.setAFV(on: false))
        bridge.pollSnapshot()
        let e = sink.events
        XCTAssertTrue(e.contains(.inputAudioSettings(input: 3, settings: settings.audio)), "\(e)")
        XCTAssertTrue(e.contains { if case .buses(let b) = $0 { return b[0].gainDb == -3 && b[3].muted } else { return false } }, "\(e)")
        XCTAssertTrue(e.contains(.afv(on: false)), "\(e)")
        sink.reset()

        _ = await sm.apply(.removeInput(input: 4))
        _ = await sm.apply(.addInput(config: InputConfig(number: 9, name: "新", source: .synthetic(settings: SyntheticSourceSettings()))))
        bridge.pollSnapshot()
        XCTAssertTrue(sink.events.contains { if case .inputsChanged(let a, let r) = $0 { return a.map(\.number) == [9] && r == [4] } else { return false } }, "\(sink.events)")
    }

    func testDiff_pureFunction_noChangeNoEvents_andCropChangeIsNotAnAudioEvent() {
        let a = ReducerTests.baseState()
        XCTAssertEqual(AudioStateBridge.diff(from: a, to: a, tick: .zero, clock: clock), [])
        var b = a
        b.inputs[0].settings.crop.left = 0.1
        XCTAssertEqual(AudioStateBridge.diff(from: a, to: b, tick: .zero, clock: clock), [], "裁切与音频无关")
        var c = a
        c.audio.monitorMode = .pfl
        XCTAssertEqual(AudioStateBridge.diff(from: a, to: c, tick: .zero, clock: clock), [.monitorMode(.pfl)])
    }

    // MARK: 线程：转场事件在状态机线程上同步到达，sink 不许阻塞——这里只证明事件在 prepare 返回前已经交付

    func testBridge_transitionEventsAreDeliveredBeforePrepareReturns() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let sink = AudioControlEventCollector()
        let bridge = AudioStateBridge(stateMachine: sm, clock: clock, sink: sink)
        await bridge.attach()
        await sm.schedule(.cut, at: Tick(7))
        await sm.prepare(upTo: Tick(7))
        XCTAssertEqual(sink.events.count, 1)
        await bridge.detach()
        await sm.schedule(.cut, at: Tick(9))
        await sm.prepare(upTo: Tick(9))
        XCTAssertEqual(sink.events.count, 1, "detach 之后不再收")
    }
}
