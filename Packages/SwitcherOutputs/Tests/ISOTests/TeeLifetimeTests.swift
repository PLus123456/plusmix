import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherISO

/// D12（Codex 2026-10-13 审查 §1.3）：InputFrameTee.addBranch 每试一格 CAS 都 `passRetained` 一次，失败的那几次不 release——
/// 第二个分支多留 1 个引用、第三个 2 个、第四个 3 个，满额失败的申请留 4 个；回收（removeBranch / reclaimRetired / deinit）只放成功装上的那一次，
/// 于是这些槽（可能还拿着末帧像素缓冲）永远不销毁，反复开关 ISO / NDI / Aux 就一直涨。
/// 数法：tee 的分支槽工厂换成记弱引用的（`SlotTracker`），主槽也由它建；弱引用变 nil = 销毁了。
final class TeeLifetimeTests: XCTestCase {
    /// Codex 的触发条件：primary + 4 分支 + 1 次满额失败申请 = 6 个槽；tee 释放后 6 个全部销毁（原来只销毁 primary 和第一个分支，2 个）。
    func testD12_teeReleaseDestroysAllSixSlots_primaryFourBranchesAndRejectedRequest() throws {
        let tracker = SlotTracker()
        weak var weakTee: InputFrameTee?
        weak var first: LockFreeFrameSlot?
        weak var second: LockFreeFrameSlot?
        try autoreleasepool {
            let tee = InputFrameTee(primary: tracker.make(3), makeBranchSlot: { tracker.make($0) })
            weakTee = tee
            var branches: [LockFreeFrameSlot] = []
            for _ in 0..<InputFrameTee.maxBranches { branches.append(try XCTUnwrap(tee.addBranch())) }
            XCTAssertNil(tee.addBranch(), "第 5 个申请：四格都占着，返回 nil")
            first = branches[0]
            second = branches[1]
            XCTAssertEqual(tracker.created, 6, "primary + 4 分支 + 失败申请里建的那一个")
            tee.push(makeFrame(input: 1, sequence: 1, pts: .now(), buffer: makePixelBuffer()))   // 分支里拿着一帧（真实情况下是末帧像素缓冲）
        }
        XCTAssertNil(weakTee, "tee 本身释放了")
        XCTAssertNil(first, "第一个分支销毁")
        XCTAssertNil(second, "第二个分支销毁（原来 CAS 在第 0 格失败一次，多留一个引用，永远不放）")
        XCTAssertEqual(tracker.alive, 0, "6 个槽全部销毁：还活着 \(tracker.alive) 个（原实现 4 个：第 2–4 个分支 + 失败申请的那个）")
    }

    /// 满额失败的申请当场就把建出来的槽放掉，不用等 tee 释放；tee 还在用。
    func testD12_rejectedRequestReleasesItsSlotImmediately() throws {
        let tracker = SlotTracker()
        let tee = InputFrameTee(primary: tracker.make(3), makeBranchSlot: { tracker.make($0) })
        var branches: [LockFreeFrameSlot] = []
        for _ in 0..<InputFrameTee.maxBranches { branches.append(try XCTUnwrap(tee.addBranch())) }
        for attempt in 1...3 {
            XCTAssertNil(tee.addBranch())
            XCTAssertEqual(tracker.created, 5 + attempt)
            XCTAssertEqual(tracker.alive, 5, "第 \(attempt) 次失败申请之后活着的仍只有 primary + 4 分支")
        }
        XCTAssertEqual(tee.branchCount, InputFrameTee.maxBranches)
        withExtendedLifetime(branches) {}
    }

    /// 反复开关第 2–4 个分支（ISO / NDI / Aux 共用每路 4 格的常见用法）：摘下 → 过回收期 → 销毁；20 轮之后活着的只有 primary + 常驻的第一个分支。
    func testD12_repeatedOpenCloseOfLaterBranches_slotsReclaimedAfterGrace() throws {
        let tracker = SlotTracker()
        let tee = InputFrameTee(primary: tracker.make(3), makeBranchSlot: { tracker.make($0) })
        let resident = try XCTUnwrap(tee.addBranch())   // 第一个分支一直开着（例如 ISO）
        for round in 0..<20 {
            try autoreleasepool {
                var opened: [LockFreeFrameSlot] = []
                for _ in 0..<3 { opened.append(try XCTUnwrap(tee.addBranch(), "第 \(round) 轮")) }
                for b in opened { tee.removeBranch(b) }
            }
            tee.reclaimRetired(now: .now(), force: true)   // = 过了回收期（静默期一秒，测试直接强制）
            XCTAssertEqual(tracker.alive, 2, "第 \(round) 轮摘下回收之后：还活着 \(tracker.alive) 个（应只剩 primary + 常驻分支）")
            if tracker.alive != 2 { break }
        }
        XCTAssertEqual(tee.branchCount, 1)
        XCTAssertEqual(tee.retiredCount, 0)
        withExtendedLifetime(resident) {}
    }

    /// 摘下的分支在回收期内还活着（输入线程可能正拿着它 push），回收期过了才销毁；tee 释放时 retired 表里的也一并销毁。
    func testD12_retiredBranchLivesThroughGraceThenDies_deinitReleasesRetired() throws {
        let tracker = SlotTracker()
        weak var removedEarly: LockFreeFrameSlot?
        weak var retiredAtDeinit: LockFreeFrameSlot?
        try autoreleasepool {
            let tee = InputFrameTee(primary: tracker.make(3), makeBranchSlot: { tracker.make($0) })
            try autoreleasepool {
                let a = try XCTUnwrap(tee.addBranch())
                let b = try XCTUnwrap(tee.addBranch())
                removedEarly = a
                retiredAtDeinit = b
                tee.removeBranch(a)
                tee.removeBranch(b)
            }
            XCTAssertEqual(tee.retiredCount, 2)
            XCTAssertNotNil(removedEarly, "回收期内不销毁")
            tee.reclaimRetired(now: .now() + HostDuration(seconds: 2), force: false)
            XCTAssertNil(removedEarly, "回收期过了就销毁")
            XCTAssertNil(retiredAtDeinit, "同一批摘下的也一起")
            let c = try XCTUnwrap(tee.addBranch())
            retiredAtDeinit = c
            tee.removeBranch(c)
            XCTAssertNotNil(retiredAtDeinit)
        }
        XCTAssertNil(retiredAtDeinit, "tee 释放时 retired 表里的分支一并销毁")
        XCTAssertEqual(tracker.alive, 0)
    }
}

/// 建 LockFreeFrameSlot 并记一个弱引用：created = 建了几个，alive = 还没销毁的几个。
final class SlotTracker: @unchecked Sendable {
    private struct WeakSlot { weak var slot: LockFreeFrameSlot? }
    private let lock = NSLock()
    private var refs: [WeakSlot] = []

    func make(_ capacity: Int) -> LockFreeFrameSlot {
        let s = LockFreeFrameSlot(capacity: capacity)
        lock.withLock { refs.append(WeakSlot(slot: s)) }
        return s
    }

    var created: Int { lock.withLock { refs.count } }
    var alive: Int { lock.withLock { refs.filter { $0.slot != nil }.count } }
}
