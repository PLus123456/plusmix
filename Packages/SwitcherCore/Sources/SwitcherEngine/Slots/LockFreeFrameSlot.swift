import Synchronization
import SwitcherContracts

// FrameSlot 协议的实现（设计方案 §3.2、§12 决策 1；CONTRACTS.md §2.3 的统计口径）。
//
// 两级结构：
//   1. 传输环 `SPSCOverwriteRing<Frame>`（容量 = capacity）：采集线程 push，满则挤最旧（dropped += 1）。
//   2. 消费者私有的候选表（容量 = capacity，只有渲染线程碰）：每次取帧先把传输环里的帧全部搬进来，
//      再按"pts ≤ 上限的最新一帧"挑；被跳过的旧帧算 dropped；pts 还在上限之后的帧留到下一拍。
// 为什么分两级：挑帧要看 pts 决定"取还是留"，而无锁环只能按顺序取；先取到私有表再挑，就不需要在环里"窥视"，
// 也就不存在生产者覆盖时的撕裂读。私有表满（输入时钟超前 ≥ capacity 帧，病态）同样挤最旧——带余量的入口在挤之前
// 先把余量降到让最旧帧合格（饿死保护，见 ArrivalPacing.swift）。
//
// 两个消费者入口：
//   - `latest(atOrBefore:)`：契约字面语义，上限 = 参数，不带余量、不参与余量估计。
//   - `latest(forTick:)`（ArrivalPacedFrameSlot）：上限 = 拍点 − 到达余量，余量自估；引擎用它。算法见 ArrivalPacing.swift。
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
    /// 每块保留的最大样本数（降序）：≤ blockTopCount − 1 个超过 d_min + 一帧 的孤立尖峰不计入可覆盖最大值。
    private static let blockTopCount = 8
    /// 每块最大的 blockTopCount 个到达延迟（host tick，降序，Int64.min = 空）；blockCount × blockTopCount。
    private let blockTop: UnsafeMutablePointer<Int64>
    /// 每块的最小到达延迟（Int64.max = 没样本）。
    private let blockMin: UnsafeMutablePointer<Int64>
    private var blockIndex = 0
    /// 当前块的起点（第一帧 / 上次推进时的 ingress host tick）。
    private var blockStart: Int64 = 0
    /// 自初始化以来推进过的块数（饱和在 blockCount）：热身用。
    private var blocksCompleted = 0
    /// 起流块（第 0 块，装着相机起流那几帧慢的）已在窗口有两个完整块后作废。
    private var startupBlockRetired = false
    private var observedFrames: UInt64 = 0
    private var pacingInitialized = false
    private var margin: Int64 = 0
    /// 上一拍的合格上限（host tick）；hasLastLimit = false 表示还没用引擎入口挑过。
    private var lastLimit: Int64 = 0
    private var hasLastLimit = false
    /// 窗口统计（每拍在 refreshWindow 里算一次）：最小值、可覆盖最大值、原始最大值。
    private var windowMin: Int64 = 0
    private var windowMax: Int64 = 0
    private var windowPeak: Int64 = 0
    private let marginMirror = Atomic<Int64>(0)
    private let windowMaxMirror = Atomic<Int64>(0)
    private let windowPeakMirror = Atomic<Int64>(0)
    private let windowMinMirror = Atomic<Int64>(0)
    private let capMirror = Atomic<Int64>(0)
    private let observedMirror = Atomic<UInt64>(0)
    private let initializedMirror = Atomic<Bool>(false)
    private let lateFrames = Atomic<UInt64>(0)
    private let raises = Atomic<UInt64>(0)
    private let decreases = Atomic<UInt64>(0)
    private let starvationRescues = Atomic<UInt64>(0)

    /// capacity 2–3（契约）；默认 3。
    public init(capacity: Int = 3, pacing: PacingOptions = PacingOptions()) {
        precondition((2...3).contains(capacity), "帧槽容量 2–3")
        self.capacity = capacity
        ring = SPSCOverwriteRing(capacity: capacity)
        pending = .allocate(capacity: capacity)
        pending.initialize(repeating: nil, count: capacity)
        pacingOptions = PacingOptionsAtomic(pacing)
        blockTop = .allocate(capacity: Self.blockCount * Self.blockTopCount)
        blockTop.initialize(repeating: Int64.min, count: Self.blockCount * Self.blockTopCount)
        blockMin = .allocate(capacity: Self.blockCount)
        blockMin.initialize(repeating: Int64.max, count: Self.blockCount)
    }

    deinit {
        pending.deinitialize(count: capacity)
        pending.deallocate()
        blockTop.deallocate()
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

    /// 渲染线程：第 tickTime 拍的挑帧，上限 = tickTime − 余量。余量的初值、抬高、降低、上限、饿死保护见 ArrivalPacing.swift。
    public func latest(forTick tickTime: HostTime) -> Frame? {
        drain(observe: true)
        let ideal = Int64(clamping: tickTime.ticks)
        guard pacingOptions.enabled.load(ordering: .relaxed), pacingInitialized else {
            return pick(limit: ideal)
        }
        refreshWindow()
        let band = guardBand()
        let cap = marginCap(guard: band)
        let minimum = pacingOptions.minimumMargin.load(ordering: .relaxed)
        var limit = ideal - margin
        if hasLastLimit, pendingCount > 0, let oldest = pending[pendingStart], Int64(clamping: oldest.pts.ticks) <= lastLimit {
            // 迟到：本该上一拍就返回。抬余量盖住它的 d，但不超过让它此刻恰好合格的值，单次不超过 maxRaise，不超过上限。
            let d = Int64(clamping: oldest.ingressTime.ticks) - Int64(clamping: oldest.pts.ticks)
            var target = max(margin, d + band)
            target = min(target, ideal - Int64(clamping: oldest.pts.ticks))
            target = min(target, margin + pacingOptions.maxRaise.load(ordering: .relaxed))
            target = min(target, cap)
            if target > margin {
                margin = target
                raises.add(1, ordering: .relaxed)
            }
            lateFrames.add(1, ordering: .relaxed)
            limit = ideal - margin
        } else {
            var desired = max(minimum, windowMax + band)
            desired = min(desired, cap)
            let hysteresis = pacingOptions.hysteresis.load(ordering: .relaxed)
            let warmedUp = blocksCompleted >= pacingOptions.warmupBlocks.load(ordering: .relaxed)
            // 减：上限随时生效（不看滞回、不等热身）；热身后再往下减到稳态目标（看滞回）。第一个不合格的候选帧不能被带进合格区
            var target = Int64.min
            if margin > cap {
                target = cap
            } else if warmedUp, margin > desired + hysteresis {
                target = desired
            }
            if target != Int64.min {
                var candidate = target
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
        // 饿死保护 / 起流出画：表满且最旧候选不合格（下一帧到就会把它挤掉），或槽里有帧却从未返回过帧 → 降到让最旧候选恰好合格
        if pendingCount > 0, pendingCount == capacity || lastReturned == nil, scan(limit: limit).pick < 0, let oldest = pending[pendingStart] {
            let forced = max(minimum, ideal - Int64(clamping: oldest.pts.ticks))
            if forced < margin {
                margin = forced
                decreases.add(1, ordering: .relaxed)
                starvationRescues.add(1, ordering: .relaxed)
                limit = ideal - margin
            }
        }
        lastLimit = limit
        hasLastLimit = true
        marginMirror.store(margin, ordering: .relaxed)
        capMirror.store(cap, ordering: .relaxed)
        return pick(limit: limit)
    }

    public func configurePacing(_ options: PacingOptions) {
        pacingOptions.store(options)
    }

    public var pacingStats: PacingStats {
        PacingStats(enabled: pacingOptions.enabled.load(ordering: .acquiring),
                    initialized: initializedMirror.load(ordering: .acquiring),
                    margin: HostDuration(ticks: marginMirror.load(ordering: .acquiring)),
                    windowMaxLatency: HostDuration(ticks: windowMaxMirror.load(ordering: .acquiring)),
                    windowPeakLatency: HostDuration(ticks: windowPeakMirror.load(ordering: .acquiring)),
                    windowMinLatency: HostDuration(ticks: windowMinMirror.load(ordering: .acquiring)),
                    marginCap: HostDuration(ticks: capMirror.load(ordering: .acquiring)),
                    observedFrames: observedMirror.load(ordering: .acquiring),
                    lateFrames: lateFrames.load(ordering: .acquiring),
                    raises: raises.load(ordering: .acquiring),
                    decreases: decreases.load(ordering: .acquiring),
                    starvationRescues: starvationRescues.load(ordering: .acquiring))
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

    // MARK: 到达延迟窗口

    /// 记一帧的到达延迟 d = ingressTime − pts（可为负：帧早于 pts 到达）。块按 ingressTime 定长推进。
    private func observeArrival(_ frame: Frame) {
        let ingress = Int64(clamping: frame.ingressTime.ticks)
        let d = ingress - Int64(clamping: frame.pts.ticks)
        if !pacingInitialized {
            pacingInitialized = true
            blockStart = ingress
            insertSample(d)
            // 初值：d > 0 → max(initialFloor, d + guardAbsolute)，否则 initialFloor；钳到 [minimumMargin, 上限]（窗口此时只有 d）
            let floor = pacingOptions.initialFloor.load(ordering: .relaxed)
            let guardAbs = pacingOptions.guardAbsolute.load(ordering: .relaxed)
            var m = d > 0 ? max(floor, d + guardAbs) : floor
            m = max(pacingOptions.minimumMargin.load(ordering: .relaxed), m)
            let cap = min(pacingOptions.maximumMargin.load(ordering: .relaxed),
                          max(0, d) + pacingOptions.programFrame.load(ordering: .relaxed) + guardAbs)
            margin = min(m, cap)
            marginMirror.store(margin, ordering: .relaxed)
            initializedMirror.store(true, ordering: .releasing)
        } else {
            let duration = pacingOptions.blockDuration.load(ordering: .relaxed)
            var advanced = 0
            while ingress - blockStart >= duration && advanced < Self.blockCount {
                blockIndex = (blockIndex + 1) % Self.blockCount
                clearBlock(blockIndex)
                blockStart += duration
                advanced += 1
            }
            if advanced == Self.blockCount { blockStart = ingress }   // 停了超过整个窗口：从这帧重新计块
            if advanced > 0, blocksCompleted < Self.blockCount { blocksCompleted = min(Self.blockCount, blocksCompleted + advanced) }
            if !startupBlockRetired, blocksCompleted >= 2 {
                // 起流块作废：相机起流的前几百毫秒是曝光 / 管线收敛，几帧 d 比稳态大 15–40 ms，不该再钉住余量一整个窗口
                startupBlockRetired = true
                if blockIndex != 0 { clearBlock(0) }
            }
            insertSample(d)
        }
        observedFrames += 1
        observedMirror.store(observedFrames, ordering: .relaxed)
    }

    private func clearBlock(_ k: Int) {
        var j = 0
        while j < Self.blockTopCount {
            blockTop[k * Self.blockTopCount + j] = Int64.min
            j += 1
        }
        blockMin[k] = Int64.max
    }

    /// 把一个样本记进当前块：最小值，以及最大的 blockTopCount 个（插入排序，降序）。
    private func insertSample(_ d: Int64) {
        if d < blockMin[blockIndex] { blockMin[blockIndex] = d }
        let base = blockIndex * Self.blockTopCount
        var j = 0
        while j < Self.blockTopCount {
            if d > blockTop[base + j] {
                var m = Self.blockTopCount - 1
                while m > j {
                    blockTop[base + m] = blockTop[base + m - 1]
                    m -= 1
                }
                blockTop[base + j] = d
                return
            }
            j += 1
        }
    }

    /// 窗口统计：最小值、原始最大值、可覆盖最大值（每块最大的几个样本里第一个 ≤ d_min + 一个节目帧 的；都超过就取最小的那个）。
    /// d_min 按 capAnchor：窗口最小值，或每块最小值里最大的（只看有样本的块）。
    private func refreshWindow() {
        var minimum = Int64.max
        var sustained = Int64.min
        var peak = Int64.min
        var k = 0
        while k < Self.blockCount {
            if blockMin[k] < minimum { minimum = blockMin[k] }
            if blockMin[k] != Int64.max, blockMin[k] > sustained { sustained = blockMin[k] }
            if blockTop[k * Self.blockTopCount] > peak { peak = blockTop[k * Self.blockTopCount] }
            k += 1
        }
        let anchor = pacingOptions.sustainedAnchor.load(ordering: .relaxed) ? sustained : minimum
        windowMin = (minimum == Int64.max || anchor == Int64.min) ? 0 : anchor
        windowPeak = peak == Int64.min ? 0 : peak
        let threshold = windowMin + pacingOptions.programFrame.load(ordering: .relaxed)
        var covered = Int64.min
        k = 0
        while k < Self.blockCount {
            let base = k * Self.blockTopCount
            var chosen = Int64.min
            var j = 0
            while j < Self.blockTopCount {
                let v = blockTop[base + j]
                if v == Int64.min { break }
                chosen = v
                if v <= threshold { break }
                j += 1
            }
            if chosen > covered { covered = chosen }
            k += 1
        }
        windowMax = covered == Int64.min ? 0 : covered
        windowMinMirror.store(windowMin, ordering: .relaxed)
        windowMaxMirror.store(windowMax, ordering: .relaxed)
        windowPeakMirror.store(windowPeak, ordering: .relaxed)
    }

    /// 保护带 = guardAbsolute + guardRelative × 抖动跨度（可覆盖最大值 − 最小值）。
    private func guardBand() -> Int64 {
        let abs = pacingOptions.guardAbsolute.load(ordering: .relaxed)
        let rel = pacingOptions.guardRelativePermille.load(ordering: .relaxed)
        let span = max(0, windowMax - windowMin)
        return abs + span * rel / 1000
    }

    /// 余量上限 = min(maximumMargin, max(0, d_min) + 一个节目帧 + 保护带)：最早到的帧也只多等一个节目帧 + 保护带。
    private func marginCap(guard band: Int64) -> Int64 {
        let dynamic = max(0, windowMin) + pacingOptions.programFrame.load(ordering: .relaxed) + band
        return min(pacingOptions.maximumMargin.load(ordering: .relaxed), dynamic)
    }
}
