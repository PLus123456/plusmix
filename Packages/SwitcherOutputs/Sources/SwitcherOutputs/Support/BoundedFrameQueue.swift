import os
import SwitcherContracts

/// 消费者自己的有界帧队列（设计方案 §3.4）：容量 2–3，生产者（引擎派发线程）push，消费者（编码线程）pop。
///
/// 满了丢最旧的一帧：`push` 把被挤掉的帧返回给调用方，调用方在锁外释放（CVPixelBuffer 回池发生在锁外）。
/// 锁是 os_unfair_lock，临界区只有几个下标操作，生产者最坏也只等消费者 pop 一次（纳秒级），
/// 满足"consume 立即返回"（E1 的 push 耗时 p99 < 0.1 ms 由测试证明）。存储在 init 时分配好，之后零分配。
final class BoundedFrameQueue: @unchecked Sendable {
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private var slots: [RenderedFrame?]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity >= 1)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    /// 放入一帧；队列满时返回被挤掉的最旧帧（调用方负责释放），否则 nil。
    func push(_ frame: RenderedFrame) -> RenderedFrame? {
        lock.lock()
        defer { lock.unlock() }
        var evicted: RenderedFrame?
        if count == capacity {
            evicted = slots[head]
            slots[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        slots[(head + count) % capacity] = frame
        count += 1
        return evicted
    }

    /// 取最旧的一帧；空则 nil。
    func pop() -> RenderedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let f = slots[head]
        slots[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return f
    }

    /// 当前帧数。
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// 清空，返回被丢的帧数。
    @discardableResult
    func removeAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = count
        for i in slots.indices { slots[i] = nil }
        head = 0
        count = 0
        return n
    }
}
