import Synchronization
import SwitcherContracts

// FrameSlot 协议的实现（设计方案 §3.2、§12 决策 1；CONTRACTS.md §2.3 的统计口径）。
//
// 两级结构：
//   1. 传输环 `SPSCOverwriteRing<Frame>`（容量 = capacity）：采集线程 push，满则挤最旧（dropped += 1）。
//   2. 消费者私有的候选表（容量 = capacity，只有渲染线程碰）：每次取帧先把传输环里的帧全部搬进来，
//      再按"pts ≤ 上限的最新一帧"挑；被跳过的旧帧算 dropped；pts 还在上限之后的帧留到下一拍。
// 为什么分两级：挑帧要看 pts 决定"取还是留"，而无锁环只能按顺序取；先取到私有表再挑，就不需要在环里"窥视"，
// 也就不存在生产者覆盖时的撕裂读。私有表满（输入时钟超前 ≥ capacity 帧，病态）同样挤最旧。
//
// 两个消费者入口：
//   - `latest(atOrBefore:)`：契约字面语义，上限 = 参数，不带余量、不参与余量估计。
//   - `latest(forTick:)`（ArrivalPacedFrameSlot）：上限 = 拍点 − 到达余量，余量自估；引擎用它。见 ArrivalPacing.swift。
//
// 线程规则：push 只在采集线程；两个 latest 只在渲染线程（零分配：所有存储预分配，帧的存取只是 retain / release；
// 循环一律整数 while，-Onone 下 for-in 会分配）；stats / pacingStats 任何线程读（原子量的非事务快照）。

/// 无锁的每路帧槽。
public final class LockFreeFrameSlot: FrameSlot, ArrivalPacedFrameSlot, @unchecked Sendable {
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
    // 到达余量（渲染线程私有状态 + 对外的原子镜像）
    private let pacingOptions: PacingOptionsAtomic
    private static let blockCount = 8
    /// 每块的最大 / 最小到达延迟（host tick），Int64.min / Int64.max = 没样本。
    private let blockMax: UnsafeMutablePointer<Int64>
    private let blockMin: UnsafeMutablePointer<Int64>
    /// 最近一帧的标称时长（host tick），算余量的结构上限用。
    private var lastFrameDuration: Int64 = 0
    private var blockIndex = 0
    private var blockFill = 0
    private var observedFrames: UInt64 = 0
    private var pacingInitialized = false
    private var margin: Int64 = 0
    /// 上一拍的合格上限（host tick）；hasLastLimit = false 表示还没用引擎入口挑过。
    private var lastLimit: Int64 = 0
    private var hasLastLimit = false
    private let marginMirror = Atomic<Int64>(0)
    private let windowMaxMirror = Atomic<Int64>(0)
    private let observedMirror = Atomic<UInt64>(0)
    private let initializedMirror = Atomic<Bool>(false)
    private let lateFrames = Atomic<UInt64>(0)
    private let raises = Atomic<UInt64>(0)
    private let decreases = Atomic<UInt64>(0)

    /// capacity 2–3（契约）；默认 3。
    public init(capacity: Int = 3, pacing: PacingOptions = PacingOptions()) {
        precondition((2...3).contains(capacity), "帧槽容量 2–3")
        self.capacity = capacity
        ring = SPSCOverwriteRing(capacity: capacity)
        pending = .allocate(capacity: capacity)
        pending.initialize(repeating: nil, count: capacity)
        pacingOptions = PacingOptionsAtomic(pacing)
        blockMax = .allocate(capacity: Self.blockCount)
        blockMax.initialize(repeating: Int64.min, count: Self.blockCount)
        blockMin = .allocate(capacity: Self.blockCount)
        blockMin.initialize(repeating: Int64.max, count: Self.blockCount)
    }

    deinit {
        pending.deinitialize(count: capacity)
        pending.deallocate()
        blockMax.deallocate()
        blockMin.deallocate()
    }

    // MARK: 生产者

    /// 采集线程：放入一帧。
    public func push(_ frame: Frame) {
        pushedCount.add(1, ordering: .relaxed)
        switch ring.push(frame) {
        case .stored: break
        case .storedEvictingOldest, .droppedIncoming: droppedCount.add(1, ordering: .relaxed)
        }
    }

    // MARK: 消费者：契约入口

    /// 渲染线程：取 pts ≤ time 的最新帧；没有新帧时重复上一帧（reused += 1）；从未有帧返回 nil。不带余量。
    public func latest(atOrBefore time: HostTime) -> Frame? {
        drain(observe: false)
        return pick(limit: Int64(clamping: time.ticks))
    }

    // MARK: 消费者：引擎入口（带到达余量）

    /// 渲染线程：第 tickTime 拍的挑帧，上限 = tickTime − 余量。余量的初值、抬高、降低规则见 ArrivalPacing.swift。
    public func latest(forTick tickTime: HostTime) -> Frame? {
        drain(observe: true)
        let ideal = Int64(clamping: tickTime.ticks)
        guard pacingOptions.enabled.load(ordering: .relaxed), pacingInitialized else {
            return pick(limit: ideal)
        }
        var limit = ideal - margin
        if hasLastLimit, pendingCount > 0, let oldest = pending[pendingStart], Int64(clamping: oldest.pts.ticks) <= lastLimit {
            // 迟到：本该上一拍就返回。抬余量盖住它的 d，但不超过让它此刻恰好合格的值，单次不超过 maxRaise。
            let d = Int64(clamping: oldest.ingressTime.ticks) - Int64(clamping: oldest.pts.ticks)
            var target = max(margin, d + guardBand(for: d))
            target = min(target, ideal - Int64(clamping: oldest.pts.ticks))
            target = min(target, margin + pacingOptions.maxRaise.load(ordering: .relaxed))
            target = min(target, marginCap())
            if target > margin {
                margin = target
                raises.add(1, ordering: .relaxed)
            }
            lateFrames.add(1, ordering: .relaxed)
            limit = ideal - margin
        } else {
            let windowMax = currentWindowMax()
            var desired = max(pacingOptions.minimumMargin.load(ordering: .relaxed), windowMax + guardBand(for: windowMax))
            desired = min(desired, marginCap())
            let hysteresis = pacingOptions.hysteresis.load(ordering: .relaxed)
            let warmedUp = observedFrames >= UInt64(pacingOptions.warmupBlocks.load(ordering: .relaxed) * pacingOptions.blockFrames.load(ordering: .relaxed))
            if warmedUp, margin > desired + hysteresis {
                // 减：第一个不合格的候选帧不能被带进合格区
                var candidate = desired
                let firstIneligible = scan(limit: limit).firstIneligible
                if firstIneligible >= 0, let f = pending[(pendingStart + firstIneligible) % capacity] {
                    candidate = max(candidate, ideal - Int64(clamping: f.pts.ticks) + 1)
                }
                if candidate < margin {
                    margin = candidate
                    decreases.add(1, ordering: .relaxed)
                    limit = ideal - margin
                }
            } else if desired > margin + hysteresis {
                // 增：当前合格的最新帧在新余量下仍须合格（否则这拍会没帧可返）
                let pickIndex = scan(limit: limit).pick
                var safe = true
                if pickIndex >= 0, let f = pending[(pendingStart + pickIndex) % capacity] {
                    safe = Int64(clamping: f.pts.ticks) <= ideal - desired
                }
                if safe {
                    margin = desired
                    raises.add(1, ordering: .relaxed)
                    limit = ideal - margin
                }
            }
        }
        lastLimit = limit
        hasLastLimit = true
        marginMirror.store(margin, ordering: .relaxed)
        return pick(limit: limit)
    }

    public func configurePacing(_ options: PacingOptions) {
        pacingOptions.store(options)
    }

    public var pacingStats: PacingStats {
        PacingStats(initialized: initializedMirror.load(ordering: .acquiring),
                    margin: HostDuration(ticks: marginMirror.load(ordering: .acquiring)),
                    windowMaxLatency: HostDuration(ticks: windowMaxMirror.load(ordering: .acquiring)),
                    observedFrames: observedMirror.load(ordering: .acquiring),
                    lateFrames: lateFrames.load(ordering: .acquiring),
                    raises: raises.load(ordering: .acquiring),
                    decreases: decreases.load(ordering: .acquiring))
    }

    /// 累计统计（任何线程；四个数分别原子读，不是一个事务）。
    public var stats: FrameSlotStats {
        FrameSlotStats(pushed: pushedCount.load(ordering: .acquiring),
                       consumed: consumedCount.load(ordering: .acquiring),
                       dropped: droppedCount.load(ordering: .acquiring),
                       reused: reusedCount.load(ordering: .acquiring))
    }

    // MARK: 内部（渲染线程）

    /// 把传输环里的帧全部搬进候选表；observe = true 时顺便记每帧的到达延迟。
    private func drain(observe: Bool) {
        while let f = ring.pop() {
            if observe { observeArrival(f) }
            append(f)
        }
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

    /// 候选表扫描：pick = 最后一个 pts ≤ limit 的下标（-1 = 没有），firstIneligible = 它后面第一个（-1 = 没有）。
    private func scan(limit: Int64) -> (pick: Int, firstIneligible: Int) {
        var pick = -1
        var k = 0
        while k < pendingCount {
            if let f = pending[(pendingStart + k) % capacity], Int64(clamping: f.pts.ticks) <= limit { pick = k }
            k += 1
        }
        let next = pick + 1
        return (pick, next < pendingCount ? next : -1)
    }

    /// 挑 pts ≤ limit 的最新帧；跳过的旧帧算 dropped；没有则重复上一帧（reused）；从未有帧返回 nil。
    private func pick(limit: Int64) -> Frame? {
        let pickIndex = scan(limit: limit).pick
        if pickIndex >= 0 {
            if pickIndex > 0 { droppedCount.add(UInt64(pickIndex), ordering: .relaxed) }
            let frame = pending[(pendingStart + pickIndex) % capacity]!
            var k = 0
            while k <= pickIndex {
                pending[(pendingStart + k) % capacity] = nil
                k += 1
            }
            pendingStart = (pendingStart + pickIndex + 1) % capacity
            pendingCount -= pickIndex + 1
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

    /// 记一帧的到达延迟 d = ingressTime − pts（可为负：帧早于 pts 到达）。
    private func observeArrival(_ frame: Frame) {
        let d = Int64(clamping: frame.ingressTime.ticks) - Int64(clamping: frame.pts.ticks)
        if d > blockMax[blockIndex] { blockMax[blockIndex] = d }
        if d < blockMin[blockIndex] { blockMin[blockIndex] = d }
        lastFrameDuration = frame.duration.ticks
        if !pacingInitialized {
            pacingInitialized = true
            let factor = pacingOptions.initialFactorPermille.load(ordering: .relaxed)
            let floor = pacingOptions.initialFloor.load(ordering: .relaxed)
            let scaled = d > 0 ? d * factor / 1000 + pacingOptions.guardAbsolute.load(ordering: .relaxed) : 0
            margin = max(pacingOptions.minimumMargin.load(ordering: .relaxed), max(floor, scaled))
            margin = min(margin, marginCap())
            marginMirror.store(margin, ordering: .relaxed)
            initializedMirror.store(true, ordering: .releasing)
        }
        observedFrames += 1
        blockFill += 1
        if blockFill >= pacingOptions.blockFrames.load(ordering: .relaxed) {
            blockIndex = (blockIndex + 1) % Self.blockCount
            blockMax[blockIndex] = Int64.min
            blockMin[blockIndex] = Int64.max
            blockFill = 0
        }
        windowMaxMirror.store(currentWindowMax(), ordering: .relaxed)
        observedMirror.store(observedFrames, ordering: .relaxed)
    }

    /// 窗口统计：最近 blockCount 块的最大到达延迟；没有样本时 0。
    private func currentWindowMax() -> Int64 {
        var m = Int64.min
        var k = 0
        while k < Self.blockCount {
            if blockMax[k] > m { m = blockMax[k] }
            k += 1
        }
        return m == Int64.min ? 0 : m
    }

    /// 窗口内最小到达延迟；没有样本时 0。
    private func currentWindowMin() -> Int64 {
        var m = Int64.max
        var k = 0
        while k < Self.blockCount {
            if blockMin[k] < m { m = blockMin[k] }
            k += 1
        }
        return m == Int64.max ? 0 : m
    }

    /// 余量上限 = min(maximumMargin, 最早到达 + (capacity − 1) × 帧长)。候选表只有 capacity 格：余量不超过这个值时，
    /// "到了但还不合格"的帧最多 capacity − 1 个，候选表挤最旧时挤掉的一定是后面还有更新合格帧的那个（本来就要被跳过的），
    /// 结果与设计内的 drop 相同；余量再大就会挤掉本该返回的帧。抖动跨度超过 (capacity − 1) 帧的输入该在自己那边加抖动缓冲
    /// （设计方案 §3.6 NDI 那条），不是帧槽的事。
    private func marginCap() -> Int64 {
        let period = lastFrameDuration > 0 ? lastFrameDuration : pacingOptions.maxRaise.load(ordering: .relaxed)
        let structural = max(0, currentWindowMin()) + Int64(capacity - 1) * period
        return min(pacingOptions.maximumMargin.load(ordering: .relaxed), structural)
    }

    /// 保护带 = guardAbsolute + guardRelative × max(d, 0)。
    private func guardBand(for d: Int64) -> Int64 {
        let abs = pacingOptions.guardAbsolute.load(ordering: .relaxed)
        let rel = pacingOptions.guardRelativePermille.load(ordering: .relaxed)
        return abs + (d > 0 ? d * rel / 1000 : 0)
    }
}
