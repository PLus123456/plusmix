import Synchronization

// 无锁 SPSC 环，满则挤掉最旧（设计方案 §3.2 帧槽、§3.4 消费者队列的底层）。
//
// 难点：元素带引用计数（Frame 里的 CVPixelBuffer），生产者覆盖某格时消费者不能正在拷贝那一格，否则拷到撕裂的指针。
// 做法：每格一个原子序号 seq（Vyukov 有界队列的思路），用序号区分"空、满、消费者正在读"，并把逻辑下标编进序号里
// 杜绝 ABA：
//   seq[i] == L        ：空，等生产者写逻辑下标 L 的元素（初始 seq[i] = i）
//   seq[i] == L + 1    ：满，装着下标 L
//   seq[i] == (L+1)|R  ：消费者正在拷贝下标 L（R = 最高位）
//   消费者拷完：seq[i] = L + capacity（空，等下标 L + capacity）
// 满时生产者挤掉最旧（下标 t）：CAS seq[t%cap] 从 t+1 直接改成 t+cap（等于替消费者"消费"掉它），成功后释放旧元素、
// 推进 tail。CAS 失败只可能是消费者正在读（等它几十条指令）或已经读完还没推进 tail（帮它推进）。
// tail 两边都用 CAS 推进，谁先成功都一样；head 只有生产者写。
// 内存序：写元素 → seq.store(release)；读方 CAS seq(acquire) 后才碰元素；读完 seq.store(release) 交还，
// 生产者以 acquire 读 seq / tail 后才覆盖。生产者 "等消费者放手" 是唯一的（有界）自旋，超过阈值改丢来帧。

/// `push` 的结果。
public enum RingPushOutcome: Sendable, Hashable {
    /// 存进去了。
    case stored
    /// 存进去了，但挤掉了最旧的一个。
    case storedEvictingOldest
    /// 消费者卡在最旧那格上没放手，来的这个被丢掉了（极少见）。
    case droppedIncoming
}

/// 单生产者单消费者、满则挤最旧的无锁环。`push` 只能在一条线程调，`pop` 只能在另一条线程调。
public final class SPSCOverwriteRing<Element>: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Element?>
    private let seqs: UnsafeMutablePointer<Atomic<UInt64>>
    private let head = Atomic<UInt64>(0)
    private let tail = Atomic<UInt64>(0)
    private static var readingBit: UInt64 { 1 << 63 }
    /// 生产者等消费者放手的自旋上限。
    private let evictSpinLimit = 4096

    public init(capacity: Int) {
        precondition(capacity >= 1)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: nil, count: capacity)
        seqs = .allocate(capacity: capacity)
        for i in 0..<capacity { (seqs + i).initialize(to: Atomic(UInt64(i))) }
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        for i in 0..<capacity { (seqs + i).deinitialize(count: 1) }
        seqs.deallocate()
    }

    /// 当前元素数（近似值，任何线程可读）。
    public var count: Int {
        let h = head.load(ordering: .acquiring), t = tail.load(ordering: .acquiring)
        return h >= t ? Int(h &- t) : 0
    }

    /// 生产者：放一个元素。
    public func push(_ element: Element) -> RingPushOutcome {
        let cap = UInt64(capacity)
        let h = head.load(ordering: .relaxed)
        var t = tail.load(ordering: .acquiring)
        var outcome = RingPushOutcome.stored
        var spins = 0
        while h &- t >= cap {
            // 满：挤掉下标 t
            let i = Int(t % cap)
            let cur = seqs[i].load(ordering: .acquiring)
            if cur == t &+ 1 {
                let (ok, _) = seqs[i].compareExchange(expected: t &+ 1, desired: t &+ cap, ordering: .acquiringAndReleasing)
                if ok {
                    storage[i] = nil
                    _ = tail.compareExchange(expected: t, desired: t &+ 1, ordering: .acquiringAndReleasing)
                    outcome = .storedEvictingOldest
                    t = tail.load(ordering: .acquiring)
                    continue
                }
                continue
            }
            if cur == (t &+ 1) | Self.readingBit {
                // 消费者正在拷贝这一格
                spins += 1
                if spins > evictSpinLimit { return .droppedIncoming }
                continue
            }
            // cur ≥ t + capacity：消费者已经拿走下标 t，帮它推进 tail
            _ = tail.compareExchange(expected: t, desired: t &+ 1, ordering: .acquiringAndReleasing)
            t = tail.load(ordering: .acquiring)
        }
        let i = Int(h % cap)
        storage[i] = element
        seqs[i].store(h &+ 1, ordering: .releasing)
        head.store(h &+ 1, ordering: .releasing)
        return outcome
    }

    /// 消费者：取最旧的一个；空则 nil。
    public func pop() -> Element? {
        let cap = UInt64(capacity)
        while true {
            let t = tail.load(ordering: .acquiring)
            let i = Int(t % cap)
            let cur = seqs[i].load(ordering: .acquiring)
            if cur == t &+ 1 {
                let (ok, _) = seqs[i].compareExchange(expected: t &+ 1, desired: (t &+ 1) | Self.readingBit, ordering: .acquiringAndReleasing)
                if !ok { continue }
                let element = storage[i]
                storage[i] = nil
                seqs[i].store(t &+ cap, ordering: .releasing)
                _ = tail.compareExchange(expected: t, desired: t &+ 1, ordering: .acquiringAndReleasing)
                return element
            }
            if cur == t { return nil }
            // 生产者挤掉了下标 t（cur ≥ t + capacity）：帮它推进 tail 再看下一格
            _ = tail.compareExchange(expected: t, desired: t &+ 1, ordering: .acquiringAndReleasing)
        }
    }
}
