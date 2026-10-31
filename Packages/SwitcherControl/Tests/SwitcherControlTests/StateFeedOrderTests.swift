import Foundation
import Synchronization
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// Codex 10-22 审查 N12（= reports/bug-audit-20261022-control-tools.md CT01）：`StateFeed.loop()` 在订阅表锁外编码旧快照，
/// 这期间来的 `subscribe()` 先补发最新的，随后旧的扇出到它——新订阅收到 `[2, 1, 2]`，Stream Deck 直接覆盖快照、窗口内 toggle 按旧目标算。
/// 修法：每个订阅者记最后发出的快照键 (sequence, tick)，比它旧的不发；同 sequence 的新拍（转场 / 动画每拍一条）照发。
final class StateFeedOrderTests: XCTestCase {
    /// 把推送线程卡在"编码旧快照"里：`clockProvider` 是生产注入点，编码时在推送线程上调（Codex 原样）。
    final class EncodeGate: @unchecked Sendable {
        let blockNext = Atomic<Bool>(true)
        let entered = Atomic<Bool>(false)
        let release = DispatchSemaphore(value: 0)
        func clock() -> TickClockSpec? {
            if Thread.current.name == "switcher.state-feed", blockNext.exchange(false, ordering: .acquiringAndReleasing) {
                entered.store(true, ordering: .releasing)
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        }
    }

    /// 快照消息的 (sequence, tick)；别的消息给 nil。
    static func snapshotKey(_ text: String) -> (sequence: UInt64, tick: Int64)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["type"] as? String == "snapshot",
              let sequence = (object["sequence"] as? NSNumber)?.uint64Value,
              let tick = (object["tick"] as? NSNumber)?.int64Value else { return nil }
        return (sequence, tick)
    }

    /// Codex 的红用例原样搬来（reports/codex-bug-audit-20261022-tests/Audit20261022ControlTests.swift.txt 的
    /// `testAudit20261022_newSubscriberNeverReceivesOlderSnapshotAfterCurrent`）：第 1 条变更进推送线程、卡在编码里；
    /// 第 2 条变更完成后订阅；再放行推送线程。修前收到 `[2, 1, 2]`。多断言两句：一条 1 都不该收到、开头就是 2。
    func testN12_newSubscriberNeverReceivesOlderSnapshotAfterCurrent() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let gate = EncodeGate()
        let feed = StateFeed(stateMachine: f.stateMachine) { gate.clock() }
        await feed.start()
        try await Task.sleep(for: .milliseconds(30))
        _ = try await f.bus.submit(.setPreview(input: 3), source: .api)
        for _ in 0..<100 where !gate.entered.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered.load(ordering: .acquiring))
        _ = try await f.bus.submit(.setPreview(input: 4), source: .api)
        let subscription = feed.subscribe()
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        await feed.stop()
        var sequences: [UInt64] = []
        for await text in subscription.stream {
            if let key = Self.snapshotKey(text) { sequences.append(key.sequence) }
        }
        print("N12 StateFeed snapshot sequences = \(sequences)")
        XCTAssertEqual(sequences, sequences.sorted(), "Subscription must not regress after sending its current snapshot")
        XCTAssertEqual(sequences.first, 2, "订阅时补发的就是最新的")
        XCTAssertFalse(sequences.contains(1), "比已发的旧的一条都不发")
    }

    /// 同 sequence 的新拍照发：一条命令（sequence 1）之后转场每拍推进不带新命令，快照的 sequence 都是 1、tick 递增——
    /// 只比 sequence 的话这些全被当成"不新"丢掉，面板上转场进度不动。
    func testN12_sameSequenceNewerTickStillSent() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let feed = StateFeed(stateMachine: f.stateMachine) { nil }
        await feed.start()
        let subscription = feed.subscribe()
        _ = try await f.bus.submit(.setPreview(input: 3), source: .api)
        let afterCommand = await waitUntil { feed.counters.snapshots >= 1 }
        XCTAssertTrue(afterCommand)
        await f.stateMachine.schedule(.fade(durationTicks: 30), at: Tick(10))
        for (k, tick) in [Int64(12), 14, 16].enumerated() {
            await f.stateMachine.prepare(upTo: Tick(tick))
            let picked = await waitUntil { feed.counters.snapshots >= UInt64(k + 2) }   // 推送线程取走这一拍再推下一拍（它只发最新的）
            XCTAssertTrue(picked, "第 \(tick) 拍")
        }
        await feed.stop()
        var keys: [String] = []
        for await text in subscription.stream {
            if let key = Self.snapshotKey(text) { keys.append("\(key.sequence)@\(key.tick)") }
        }
        XCTAssertEqual(keys, ["0@0", "1@0", "1@12", "1@14", "1@16"], "订阅时补发 0@0、命令 1@0，之后同 sequence 的三拍都要发")
    }
}
