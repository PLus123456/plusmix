import Synchronization
import SwitcherContracts

// FrameSlot 协议的实现（设计方案 §3.2、§12 决策 1；CONTRACTS.md §2.3 的统计口径）。
//
// 两级结构：
//   1. 传输环 `SPSCOverwriteRing<Frame>`（容量 = capacity）：采集线程 push，满则挤最旧（dropped += 1）。
//   2. 消费者私有的候选表（容量 = capacity，只有渲染线程碰）：每次 latest 先把传输环里的帧全部搬进来，
//      再按"pts ≤ 拍点的最新一帧"挑；被跳过的旧帧算 dropped；pts 还在拍点之后的帧留到下一拍。
// 为什么分两级：挑帧要看 pts 决定"取还是留"，而无锁环只能按顺序取；先取到私有表再挑，就不需要在环里"窥视"，
// 也就不存在生产者覆盖时的撕裂读。私有表满（输入时钟超前 ≥ capacity 帧，病态）同样挤最旧。
//
// 线程规则：push 只在采集线程；latest 只在渲染线程（零分配：所有存储预分配，帧的存取只是 retain / release）；
// stats 任何线程读（原子量的非事务快照）。

/// 无锁的每路帧槽。
public final class LockFreeFrameSlot: FrameSlot, @unchecked Sendable {
    public let capacity: Int
    private let ring: SPSCOverwriteRing<Frame>
    // 渲染线程私有：候选表（环形），从 pendingStart 起 pendingCount 个
    private let pending: UnsafeMutablePointer<Frame?>
    private var pendingStart = 0
    private var pendingCount = 0
    private var lastReturned: Frame?
    // 统计
    private let pushedCount = Atomic<UInt64>(0)
    private let consumedCount = Atomic<UInt64>(0)
    private let droppedCount = Atomic<UInt64>(0)
    private let reusedCount = Atomic<UInt64>(0)

    /// capacity 2–3（契约）；默认 3。
    public init(capacity: Int = 3) {
        precondition((2...3).contains(capacity), "帧槽容量 2–3")
        self.capacity = capacity
        ring = SPSCOverwriteRing(capacity: capacity)
        pending = .allocate(capacity: capacity)
        pending.initialize(repeating: nil, count: capacity)
    }

    deinit {
        pending.deinitialize(count: capacity)
        pending.deallocate()
    }

    /// 采集线程：放入一帧。
    public func push(_ frame: Frame) {
        pushedCount.add(1, ordering: .relaxed)
        switch ring.push(frame) {
        case .stored: break
        case .storedEvictingOldest, .droppedIncoming: droppedCount.add(1, ordering: .relaxed)
        }
    }

    /// 渲染线程：取 pts ≤ time 的最新帧；没有新帧时重复上一帧（reused += 1）；从未有帧返回 nil。
    public func latest(atOrBefore time: HostTime) -> Frame? {
        // 1. 搬运
        while let f = ring.pop() { append(f) }
        // 2. 挑：候选表里最后一个 pts ≤ time 的
        var pick = -1
        for k in 0..<pendingCount where pending[(pendingStart + k) % capacity]!.pts <= time { pick = k }
        if pick >= 0 {
            // pick 之前的从未被返回就被更新的帧跳过 → dropped
            if pick > 0 { droppedCount.add(UInt64(pick), ordering: .relaxed) }
            let frame = pending[(pendingStart + pick) % capacity]!
            for k in 0...pick { pending[(pendingStart + k) % capacity] = nil }
            pendingStart = (pendingStart + pick + 1) % capacity
            pendingCount -= pick + 1
            lastReturned = frame
            consumedCount.add(1, ordering: .relaxed)
            return frame
        }
        if let last = lastReturned {
            consumedCount.add(1, ordering: .relaxed)
            reusedCount.add(1, ordering: .relaxed)
            return last
        }
        return nil
    }

    private func append(_ frame: Frame) {
        if pendingCount == capacity {
            // 候选表满：挤最旧（输入时钟超前的病态情况）
            pending[pendingStart] = nil
            pendingStart = (pendingStart + 1) % capacity
            pendingCount -= 1
            droppedCount.add(1, ordering: .relaxed)
        }
        pending[(pendingStart + pendingCount) % capacity] = frame
        pendingCount += 1
    }

    /// 累计统计（任何线程；四个数分别原子读，不是一个事务）。
    public var stats: FrameSlotStats {
        FrameSlotStats(pushed: pushedCount.load(ordering: .acquiring),
                       consumed: consumedCount.load(ordering: .acquiring),
                       dropped: droppedCount.load(ordering: .acquiring),
                       reused: reusedCount.load(ordering: .acquiring))
    }
}
