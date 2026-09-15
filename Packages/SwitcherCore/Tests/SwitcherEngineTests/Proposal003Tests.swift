import Foundation
import Synchronization
import XCTest
@testable import SwitcherEngine
import SwitcherContracts

/// 提案 003 在状态机 / 引擎侧的落地：回执 applied、快照 publishedAt、SnapshotObserver、StatsPublisher。
final class Proposal003Tests: XCTestCase {
    func makeMachine() -> StateMachine {
        let sm = StateMachine(initialState: ReducerTests.baseState())
        sm.start()
        return sm
    }

    func issued(_ seq: UInt64, _ c: Command) -> IssuedCommand { IssuedCommand(sequence: seq, issuedAt: .now(), command: c) }

    // MARK: A. applied

    func testP003_receiptApplied_falseWhenReducerIgnoresCommand() async {
        let sm = makeMachine()
        defer { sm.stop() }
        // 生效的
        guard case .applied(let r1) = await sm.submit(issued(1, .setPreview(input: 3))) else { return XCTFail() }
        XCTAssertTrue(r1.applied)
        // 被忽略的：mute 已经是 false → mute(on: false) 状态不变
        guard case .applied(let r2) = await sm.submit(issued(2, .mute(input: 1, on: false))) else { return XCTFail() }
        XCTAssertFalse(r2.applied)
        XCTAssertEqual(r2.appliedTick, r1.appliedTick)
        // 转场进行中再 fade：忽略
        guard case .applied(let r3) = await sm.submit(issued(3, .fade(durationTicks: 30))) else { return XCTFail() }
        XCTAssertTrue(r3.applied)
        guard case .applied(let r4) = await sm.submit(issued(4, .fade(durationTicks: 30))) else { return XCTFail() }
        XCTAssertFalse(r4.applied, "转场进行中再发 fade 被 reducer 忽略")
        // 回执历史里也是同样的值
        let h2 = await sm.receipt(forSequence: 2)
        XCTAssertEqual(h2?.applied, false)
        let h3 = await sm.receipt(forSequence: 3)
        XCTAssertEqual(h3?.applied, true)
        // 本地 apply 也带
        let local = await sm.apply(.setAFV(on: true))
        XCTAssertTrue(local.applied)
        let localAgain = await sm.apply(.setAFV(on: true))
        XCTAssertFalse(localAgain.applied)
        // 排队后连带应用的也有正确的 applied：seq 6 先到（排队），seq 5 到了一起应用
        guard case .queued = await sm.submit(issued(6, .setAFV(on: true))) else { return XCTFail() }   // 已经 true → 忽略
        guard case .applied = await sm.submit(issued(5, .cut)) else { return XCTFail() }
        let h6 = await sm.receipt(forSequence: 6)
        XCTAssertEqual(h6?.applied, false)
        let h5 = await sm.receipt(forSequence: 5)
        XCTAssertEqual(h5?.applied, true)
    }

    // MARK: B. publishedAt

    func testP003_snapshotPublishedAt_isSetAtPublishAndMonotonic() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let initial = sm.publisher.latest!
        let before = HostClock.now()
        _ = await sm.submit(issued(1, .cut))
        let after = HostClock.now()
        let snap = sm.publisher.latest!
        XCTAssertGreaterThanOrEqual(snap.publishedAt, before)
        XCTAssertLessThanOrEqual(snap.publishedAt, after)
        XCTAssertGreaterThanOrEqual(snap.publishedAt, initial.publishedAt)
        // 拍推进带来的发布也打戳
        await sm.schedule(.setPreview(input: 4), at: Tick(10))
        let t1 = HostClock.now()
        await sm.prepare(upTo: Tick(10))
        let t2 = HostClock.now()
        let s2 = sm.publisher.latest!
        XCTAssertEqual(s2.tick, Tick(10))
        XCTAssertGreaterThanOrEqual(s2.publishedAt, t1)
        XCTAssertLessThanOrEqual(s2.publishedAt, t2)
    }

    // MARK: D1. SnapshotObserver

    final class Recorder: SnapshotObserver, @unchecked Sendable {
        let lock = NSLock()
        var seen: [MixerSnapshot] = []
        var threads: [String] = []
        var sameAsLatest = 0
        weak var machine: StateMachine?
        func stateMachine(_ machine: StateMachine, didPublish snapshot: MixerSnapshot) {
            lock.lock(); defer { lock.unlock() }
            seen.append(snapshot)
            threads.append(Thread.current.name ?? "")
            if machine.publisher.latest === snapshot { sameAsLatest += 1 }
        }
    }

    func testP003_snapshotObserver_calledAfterEveryPublish_withTheSameObjectAsLatest() async {
        let sm = makeMachine()
        defer { sm.stop() }
        let rec = Recorder()
        await sm.addSnapshotObserver(rec)
        _ = await sm.submit(issued(1, .setPreview(input: 3)))           // 命令 → 发布
        _ = await sm.submit(issued(2, .mute(input: 1, on: false)))      // 被忽略也发布（sequence 前进）
        await sm.schedule(.fade(durationTicks: 3), at: Tick(5))
        await sm.prepare(upTo: Tick(4))                                  // 没变化：不发布
        await sm.prepare(upTo: Tick(5))                                  // fade 开始：发布
        await sm.prepare(upTo: Tick(6))                                  // 进度：发布
        await sm.prepare(upTo: Tick(20))                                 // 跨多拍：一次发布（转场完成后的最终状态）
        let seen = rec.lock.withLock { rec.seen }
        XCTAssertEqual(seen.map(\.sequence), [1, 2, 2, 2, 2])
        XCTAssertEqual(seen.map(\.tick), [.zero, .zero, Tick(5), Tick(6), Tick(20)])
        XCTAssertEqual(rec.sameAsLatest, seen.count, "回调时 latest 已经是这个快照")
        XCTAssertEqual(seen.last?.state.program, 3)
        XCTAssertTrue(rec.threads.allSatisfy { $0 == "switcher.state-machine" }, "在状态机线程上调：\(rec.threads)")
        // 摘掉后不再收到
        await sm.removeSnapshotObserver(rec)
        _ = await sm.submit(issued(3, .cut))
        XCTAssertEqual(rec.lock.withLock { rec.seen.count }, 5)
        // publishedAt 单调不减
        let times = seen.map(\.publishedAt.ticks)
        XCTAssertEqual(times, times.sorted())
    }

    // MARK: D2. StatsPublisher

    func testP003_statsPublisher_oneRowPerInterval_fanOutAndLatest() async throws {
        let sm = makeMachine()
        defer { sm.stop() }
        let renderer = FakeRenderer()
        let engine = Engine(stateMachine: sm, renderer: renderer, maxInputs: 4)
        let publisher = StatsPublisher(engine: engine, interval: 0.05)
        final class Sink: @unchecked Sendable { let lock = NSLock(); var rows: [Stats] = []; var threads = Set<String>() }
        let a = Sink(), b = Sink()
        publisher.addConsumer { s in a.lock.lock(); a.rows.append(s); a.threads.insert(Thread.current.name ?? "?"); a.lock.unlock() }
        publisher.addConsumer { s in b.lock.lock(); b.rows.append(s); b.lock.unlock() }
        XCTAssertNil(publisher.latest)
        try publisher.start()
        try await Task.sleep(for: .milliseconds(330))
        publisher.stop()
        let rowsA = a.lock.withLock { a.rows }, rowsB = b.lock.withLock { b.rows }
        XCTAssertGreaterThanOrEqual(rowsA.count, 5, "0.33 s / 50 ms 至少 5 行，实际 \(rowsA.count)")
        XCTAssertLessThanOrEqual(rowsA.count, 8)
        XCTAssertEqual(rowsA, rowsB, "所有消费者拿到同一行")
        XCTAssertEqual(publisher.latest, rowsA.last)
        XCTAssertEqual(publisher.rows, UInt64(rowsA.count))
        // ts 单调、间隔约 50 ms
        let ts = rowsA.map(\.ts)
        XCTAssertEqual(ts, ts.sorted())
        for i in 1..<ts.count { XCTAssertEqual(ts[i] - ts[i - 1], 0.05, accuracy: 0.02) }
        XCTAssertEqual(a.lock.withLock { a.threads }, ["switcher.stats"], "在采样线程上调消费者")
        // 停了不再来；sampleNow 手动采一行也扇出
        let countBefore = a.lock.withLock { a.rows.count }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(a.lock.withLock { a.rows.count }, countBefore)
        let row = publisher.sampleNow()
        XCTAssertEqual(a.lock.withLock { a.rows.last }, row)
        XCTAssertEqual(publisher.latest, row)
        // 重复 start / stop 不崩
        try publisher.start()
        publisher.stop()
        publisher.stop()
    }
}
