import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 状态机 actor：按 sequence 严格顺序（C4）、快照原子发布、按拍准备（V6 / V7 的运行时形态）、转场事件。
final class StateMachineTests: XCTestCase {
    func makeMachine(startTick: Tick = .zero) -> StateMachine {
        let sm = StateMachine(initialState: ReducerTests.baseState(), startTick: startTick)
        sm.start()
        return sm
    }

    func issued(_ seq: UInt64, _ c: Command) -> IssuedCommand { IssuedCommand(sequence: seq, issuedAt: .now(), command: c) }

    // MARK: V6 / V7 运行时

    func testV6_scheduledCut_landsOnExactTick_noIntermediateSnapshot() async {
        let sm = makeMachine()
        defer { sm.stop() }
        await sm.schedule(.cut, at: Tick(1000))
        await sm.prepare(upTo: Tick(999))
        var snap = sm.publisher.latest!
        XCTAssertEqual(snap.state.program, 1)
        XCTAssertEqual(sm.preparedTick, Tick(999))
        await sm.prepare(upTo: Tick(1000))
        snap = sm.publisher.latest!
        XCTAssertEqual(snap.tick, Tick(1000))
        XCTAssertEqual(snap.state.program, 2)
        XCTAssertEqual(snap.state.preview, 1)
        XCTAssertFalse(snap.state.transition.isActive, "Cut 没有任何一拍处于混合态")
        let tickNow = await sm.tick
        XCTAssertEqual(tickNow, Tick(1000))
        // 排在过去的拍：立即应用在当前拍
        await sm.schedule(.setPreview(input: 3), at: Tick(5))
        XCTAssertEqual(sm.publisher.latest!.state.preview, 3)
        XCTAssertEqual(sm.publisher.latest!.tick, Tick(1000))
    }

    func testV7_scheduledFade_perTickSnapshots_progressIsKOver30() async {
        let sm = makeMachine()
        defer { sm.stop() }
        await sm.schedule(.fade(durationTicks: 30), at: Tick(10))
        for t in 0...45 {
            await sm.prepare(upTo: Tick(Int64(t)))
            XCTAssertEqual(sm.preparedTick, Tick(Int64(t)))
            let snap = sm.publisher.latest!
            if t < 10 {
                XCTAssertEqual(snap.tick, .zero, "没变化的拍不发布新快照")
                XCTAssertFalse(snap.state.transition.isActive)
                XCTAssertEqual(snap.state.program, 1)
            } else if t < 40 {
                XCTAssertEqual(snap.tick, Tick(Int64(t)), "转场中每拍一个新快照")
                XCTAssertEqual(snap.state.transition.progress, Double(t - 10) / 30.0, "第 \(t) 拍")
                XCTAssertEqual(snap.state.program, 1)
            } else {
                XCTAssertEqual(snap.tick, Tick(40), "第 40 拍对调，之后空闲不再发布")
                XCTAssertEqual(snap.state.program, 2)
                XCTAssertEqual(snap.state.preview, 1)
                XCTAssertFalse(snap.state.transition.isActive)
            }
        }
    }

    /// 一次 prepare 跨多拍（渲染线程跳拍后）：中间每一拍的排程命令都按序应用，转场也在正确的拍完成。
    func testV6_prepareAcrossSkippedTicks_appliesEveryTickInOrder() async {
        let sm = makeMachine()
        defer { sm.stop() }
        await sm.schedule(.setPreview(input: 3), at: Tick(3))
        await sm.schedule(.cut, at: Tick(4))          // PGM 3
        await sm.schedule(.setPreview(input: 4), at: Tick(6))
        await sm.schedule(.fade(durationTicks: 2), at: Tick(6)) // 8 拍完成：PGM 4
        await sm.prepare(upTo: Tick(20))
        let s = await sm.state
        XCTAssertEqual(s.program, 4)
        XCTAssertEqual(s.preview, 3)
        XCTAssertFalse(s.transition.isActive)
    }

    // MARK: C4 顺序

    func testC4_outOfOrder_seq3ArrivesFirst_waitsForSeq2() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let r1 = await sm.submit(issued(1, .renameInput(input: 1, name: "一")))
        guard case .applied(let receipt1) = r1 else { return XCTFail("seq 1 应立即应用") }
        XCTAssertEqual(receipt1.sequence, 1)
        let r3 = await sm.submit(issued(3, .renameInput(input: 1, name: "三")))
        guard case .queued = r3 else { return XCTFail("seq 3 要等 seq 2") }
        var name = await sm.state.inputs[0].name
        XCTAssertEqual(name, "一", "seq 3 未应用")
        XCTAssertEqual(sm.publisher.latest!.sequence, 1)
        let r2 = await sm.submit(issued(2, .renameInput(input: 1, name: "二")))
        guard case .applied = r2 else { return XCTFail("seq 2 应立即应用并带出 seq 3") }
        name = await sm.state.inputs[0].name
        XCTAssertEqual(name, "三")
        let appliedSeqs = await sm.appliedSequences
        XCTAssertEqual(appliedSeqs, [1, 2, 3])
        XCTAssertEqual(sm.publisher.latest!.sequence, 3)
        let receipt3 = await sm.receipt(forSequence: 3)
        XCTAssertNotNil(receipt3)
        // 重复 / 过期的序号被拒
        guard case .stale = await sm.submit(issued(2, .cut)) else { return XCTFail("过期序号应拒绝") }
        let programAfter = await sm.state.program
        XCTAssertEqual(programAfter, 1)
    }

    func testC4_1000ConcurrentCommands_noLossNoReorder() async {
        let sm = makeMachine()
        defer { sm.stop() }
        var all = Array(1...1000).map { UInt64($0) }
        all.shuffle()
        let batches = stride(from: 0, to: all.count, by: 125).map { Array(all[$0..<min($0 + 125, all.count)]) }
        await withTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask {
                    for seq in batch {
                        _ = await sm.submit(IssuedCommand(sequence: seq, issuedAt: .now(), command: .renameInput(input: 1, name: "\(seq)")))
                    }
                }
            }
        }
        let applied = await sm.appliedSequences
        XCTAssertEqual(applied.count, 1000, "0 丢失")
        XCTAssertEqual(applied, Array(1...1000), "0 乱序")
        let finalName = await sm.state.inputs[0].name
        XCTAssertEqual(finalName, "1000")
        XCTAssertEqual(sm.publisher.latest!.sequence, 1000)
        let pending = await sm.pendingCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: 快照发布

    func testW1B_snapshotPublishedAfterEachReduce_readableWithoutEnteringActor() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let initial = sm.publisher.latest!
        XCTAssertEqual(initial.sequence, 0)
        XCTAssertEqual(initial.tick, .zero)
        let reader = sm.publisher.makeReaderSlot()
        _ = await sm.apply(.setPreview(input: 4))
        // 渲染线程的读法：借用指针，不进 actor、不加锁、不分配
        let borrowed = reader.borrow()!
        XCTAssertEqual(borrowed._withUnsafeGuaranteedRef { $0.state.preview }, 4)
        reader.endBorrow()
        XCTAssertTrue(sm.publisher.latest! !== initial, "每次 reduce 发布新对象")
        // 空闲拍不发布新对象，只推进 preparedTick
        let before = sm.publisher.latest!
        await sm.prepare(upTo: Tick(3))
        XCTAssertTrue(sm.publisher.latest! === before)
        XCTAssertEqual(sm.preparedTick, Tick(3))
    }

    func testW1B_requestPrepare_fromPlainThread_drivesTicksWithoutEnteringActor() throws {
        let sm = makeMachine()
        defer { sm.stop() }
        let t = NativeThread(config: NativeThreadConfig(name: "fake-render", qos: QOS_CLASS_USER_INTERACTIVE)) {
            for n in 1...200 {
                sm.requestPrepare(Tick(Int64(n)))
                let deadline = HostClock.now() + HostDuration(milliseconds: 50)
                while sm.preparedTick < Tick(Int64(n)) && HostClock.now() < deadline {}
            }
        }
        try t.start()
        t.join()
        XCTAssertEqual(sm.preparedTick, Tick(200))
    }

    /// 命令应用在"渲染线程还没消费的最早一拍"：渲染线程已消费第 7 拍时，命令落在第 8 拍。
    func testW1B_submitLandsOnFirstUnrenderedTick() async {
        let sm = makeMachine()
        defer { sm.stop() }
        await sm.prepare(upTo: Tick(7))
        sm.noteRendered(Tick(7))
        guard case .applied(let r) = await sm.submit(issued(1, .cut)) else { return XCTFail() }
        XCTAssertEqual(r.appliedTick, Tick(8))
        XCTAssertEqual(sm.publisher.latest!.tick, Tick(8))
        XCTAssertEqual(sm.preparedTick, Tick(8))
        // 渲染线程还没消费第 8 拍：再来一条落在第 8 拍
        guard case .applied(let r2) = await sm.submit(issued(2, .setPreview(input: 3))) else { return XCTFail() }
        XCTAssertEqual(r2.appliedTick, Tick(8))
    }

    // MARK: 转场事件（AFV）

    func testW1B_transitionEvents_emittedWithAFVFlag() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let collector = EventCollector()
        await sm.addTransitionSink(collector)
        _ = await sm.apply(.setAFV(on: true))
        _ = await sm.apply(.cut)                       // 1↔2：cut 事件 from 1 to 2
        await sm.schedule(.fade(durationTicks: 3), at: Tick(5))
        await sm.prepare(upTo: Tick(10))               // started@5 (2→1)，completed@8
        _ = await sm.apply(.setProgram(input: 3))      // 瞬时切换也发 cut 事件（1→3）
        _ = await sm.apply(.tbar(progress: 0.5))       // started(tbar) 3→2
        _ = await sm.apply(.tbar(progress: 1.0))       // completed 3→2
        let events = collector.events
        XCTAssertTrue(events.allSatisfy { $0.1 }, "afv 标志随事件带出")
        XCTAssertEqual(events.map(\.0), [
            .cut(tick: .zero, from: 1, to: 2),
            .started(tick: Tick(5), type: .fade, durationTicks: 3, from: 2, to: 1, source: .auto),
            .completed(tick: Tick(8), from: 2, to: 1),
            .cut(tick: Tick(10), from: 1, to: 3),
            .started(tick: Tick(10), type: .fade, durationTicks: 3, from: 3, to: 2, source: .tbar),
            .completed(tick: Tick(10), from: 3, to: 2),
        ])
    }
}

extension StateMachineTests {
    /// 没 start 或已 stop 的状态机：await 不会挂起（job 在调用方线程串行执行），行为与线程模式一致。
    func testW1B_stateMachine_usableWithoutExecutorThread() async {
        let sm = StateMachine(initialState: ReducerTests.baseState())
        _ = await sm.apply(.cut)
        let program = await sm.state.program
        XCTAssertEqual(program, 2)
        sm.start()
        _ = await sm.apply(.cut)
        sm.stop()
        let after = await sm.state.program
        XCTAssertEqual(after, 1)
        await sm.prepare(upTo: Tick(5))
        XCTAssertEqual(sm.preparedTick, Tick(5))
    }
}
