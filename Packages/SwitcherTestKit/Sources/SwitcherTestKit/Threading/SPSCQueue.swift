import Synchronization

/// 单生产者单消费者的无锁有界队列。容量向上取到 2 的幂；满了 `push` 返回 false（生产者自己决定丢）。
/// 存储是预分配的裸内存，push / pop 只做一次 initialize / move，不分配。
/// 线程规则：`push` 只能一个线程调，`pop` 只能另一个线程调；两端各自的计数用 release / acquire 发布。
public final class SPSCQueue<Element>: @unchecked Sendable {
    /// 实际容量（2 的幂）。
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    private let head = Atomic<Int>(0) // 消费者写
    private let tail = Atomic<Int>(0) // 生产者写

    public init(capacity requested: Int) {
        var c = 1
        while c < max(2, requested) { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = UnsafeMutablePointer<Element>.allocate(capacity: c)
    }

    deinit {
        while pop() != nil {}
        storage.deallocate()
    }

    /// 当前元素个数（近似值，任一线程可读）。
    public var count: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }
    /// 是否为空。
    public var isEmpty: Bool { count == 0 }

    /// 生产者：入队；满则返回 false。
    @discardableResult
    public func push(_ element: consuming Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t - h >= capacity { return false }
        (storage + (t & mask)).initialize(to: element)
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// 消费者：出队；空则 nil。
    public func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if t == h { return nil }
        let e = (storage + (h & mask)).move()
        head.store(h + 1, ordering: .releasing)
        return e
    }
}
