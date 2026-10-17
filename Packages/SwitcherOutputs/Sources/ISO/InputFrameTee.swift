import Synchronization
import SwitcherContracts
import SwitcherEngine

/// 输入帧的分流器（FrameSlot 装饰器）：输入把它当帧槽 push；每帧先进主槽（引擎注册的那个，挑帧带到达余量），再进每个分支。
/// 分支是独立的 `LockFreeFrameSlot`（W1-B），各有自己的单消费者：ISO 录制的 tap、Aux 显示……互不干扰，也不碰主槽的 SPSC 约束。
///
/// 线程：`push` 只在输入线程，零分配、无锁：主槽 push + 最多 `maxBranches` 次原子读 + 分支 push。
/// `addBranch` / `removeBranch` 在普通线程；摘下的分支不立刻释放（输入线程可能正拿着它 push），先放进 retired 表，
/// 一秒后（下一次增删时）或 deinit 再释放——静默期回收，push 的临界区只有微秒级。
public final class InputFrameTee: FrameSlot, @unchecked Sendable {
    /// 最多几个分支。
    public static let maxBranches = 4
    /// 主槽（引擎挑帧用的那个）。
    public let primary: LockFreeFrameSlot

    private final class Cell: Sendable {
        let slot = Atomic<Unmanaged<LockFreeFrameSlot>?>(nil)
    }
    private let cells: [Cell]
    private let retired = Mutex<[(slot: Unmanaged<LockFreeFrameSlot>, at: HostTime)]>([])
    /// 摘下的分支保留多久再释放。
    static let retireGrace = HostDuration(seconds: 1)

    /// 建分支槽（参数 = 容量）。生产代码就是 `LockFreeFrameSlot(capacity:)`；测试换成记下弱引用的工厂，数每个槽是否销毁（D12）。
    private let makeBranchSlot: @Sendable (Int) -> LockFreeFrameSlot

    public convenience init(primary: LockFreeFrameSlot) {
        self.init(primary: primary, makeBranchSlot: { LockFreeFrameSlot(capacity: $0) })
    }

    init(primary: LockFreeFrameSlot, makeBranchSlot: @escaping @Sendable (Int) -> LockFreeFrameSlot) {
        self.primary = primary
        self.makeBranchSlot = makeBranchSlot
        cells = (0..<InputFrameTee.maxBranches).map { _ in Cell() }
    }

    deinit {
        for c in cells {
            if let u = c.slot.exchange(nil, ordering: .acquiringAndReleasing) { u.release() }
        }
        retired.withLock { list in
            for e in list { e.slot.release() }
            list.removeAll()
        }
    }

    // MARK: FrameSlot（输入线程 push；latest / stats 转给主槽）

    public var capacity: Int { primary.capacity }

    public func push(_ frame: Frame) {
        primary.push(frame)
        var i = 0
        while i < InputFrameTee.maxBranches {
            if let u = cells[i].slot.load(ordering: .acquiring) { u.takeUnretainedValue().push(frame) }
            i += 1
        }
    }

    public func latest(atOrBefore time: HostTime) -> Frame? { primary.latest(atOrBefore: time) }

    public var stats: FrameSlotStats { primary.stats }

    // MARK: 分支（普通线程）

    /// 开一个分支；已有 `maxBranches` 个时返回 nil。
    public func addBranch(capacity: Int = 3) -> LockFreeFrameSlot? {
        reclaimRetired(now: .now(), force: false)
        let slot = makeBranchSlot(capacity)
        var i = 0
        while i < InputFrameTee.maxBranches {
            let (exchanged, _) = cells[i].slot.compareExchange(expected: nil, desired: Unmanaged.passRetained(slot), ordering: .acquiringAndReleasing)
            if exchanged { return slot }
            i += 1
        }
        return nil
    }

    /// 摘掉一个分支（之后的帧不再进它）；不是本分流器的分支则无事。
    public func removeBranch(_ slot: LockFreeFrameSlot) {
        let now = HostTime.now()
        var i = 0
        while i < InputFrameTee.maxBranches {
            if let u = cells[i].slot.load(ordering: .acquiring), u.takeUnretainedValue() === slot {
                let (exchanged, _) = cells[i].slot.compareExchange(expected: u, desired: nil, ordering: .acquiringAndReleasing)
                if exchanged { retired.withLock { $0.append((u, now)) } }
            }
            i += 1
        }
        reclaimRetired(now: now, force: false)
    }

    /// 当前分支数。
    public var branchCount: Int {
        var n = 0, i = 0
        while i < InputFrameTee.maxBranches {
            if cells[i].slot.load(ordering: .relaxed) != nil { n += 1 }
            i += 1
        }
        return n
    }

    /// 等待释放的分支数（测试看）。
    public var retiredCount: Int { retired.withLock { $0.count } }

    /// 释放静默期已过的分支。
    func reclaimRetired(now: HostTime, force: Bool) {
        retired.withLock { list in
            var keep: [(slot: Unmanaged<LockFreeFrameSlot>, at: HostTime)] = []
            for e in list {
                if force || now - e.at >= InputFrameTee.retireGrace { e.slot.release() } else { keep.append(e) }
            }
            list = keep
        }
    }
}
