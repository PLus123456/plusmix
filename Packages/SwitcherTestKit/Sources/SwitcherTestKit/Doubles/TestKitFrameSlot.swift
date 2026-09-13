import SwitcherContracts
import Synchronization

/// `FrameSlot` 的测试替身。语义按契约（docs/CONTRACTS.md §2.3 口径）实现，但用互斥锁而不是无锁环——
/// 它只服务 TestKit 自己的测试和素材生成；引擎用的真帧槽在 SwitcherEngine（W1-B）。
///
/// - `push`：满则淘汰最旧一帧，若它从未被 `latest` 返回过，dropped += 1。
/// - `latest(atOrBefore:)`：返回 pts ≤ time 的最新帧；它之前的帧从此不再返回（其中没消费过的算 dropped）；
///   返回的是上一次同一帧时 reused += 1；没有合格帧返回 nil 且不清空。
/// - `onPush`：每次 push 后在生产者线程同步回调（收集全部帧用；回调自己保证不阻塞）。
public final class TestKitFrameSlot: FrameSlot, @unchecked Sendable {
    public let capacity: Int

    private struct Entry {
        var frame: Frame
        var consumed: Bool
    }
    private struct State {
        var entries: [Entry?]
        var head = 0
        var count = 0
        var lastReturned: UInt64?
    }
    private let state: Mutex<State>
    private let pushedCount = Atomic<UInt64>(0)
    private let consumedCount = Atomic<UInt64>(0)
    private let droppedCount = Atomic<UInt64>(0)
    private let reusedCount = Atomic<UInt64>(0)
    /// push 之后的回调（生产者线程）。start 之前设好，之后不要改。
    public var onPush: (@Sendable (Frame) -> Void)?

    public init(capacity: Int = 3) {
        precondition((2...3).contains(capacity) || capacity > 0, "容量 2–3")
        self.capacity = capacity
        state = Mutex(State(entries: Array(repeating: nil, count: capacity)))
    }

    public func push(_ frame: Frame) {
        var dropped = false
        state.withLock { s in
            if s.count == capacity {
                let oldest = s.entries[s.head]!
                if !oldest.consumed { dropped = true }
                s.entries[s.head] = nil
                s.head = (s.head + 1) % capacity
                s.count -= 1
            }
            s.entries[(s.head + s.count) % capacity] = Entry(frame: frame, consumed: false)
            s.count += 1
        }
        pushedCount.wrappingAdd(1, ordering: .relaxed)
        if dropped { droppedCount.wrappingAdd(1, ordering: .relaxed) }
        onPush?(frame)
    }

    public func latest(atOrBefore time: HostTime) -> Frame? {
        var result: Frame?
        var dropped: UInt64 = 0
        var reused = false
        state.withLock { s in
            // 从新到旧找第一个 pts ≤ time 的
            var pick = -1
            var i = s.count - 1
            while i >= 0 {
                let e = s.entries[(s.head + i) % capacity]!
                if e.frame.pts <= time { pick = i; break }
                i -= 1
            }
            guard pick >= 0 else { return }
            // 淘汰它之前的
            for _ in 0..<pick {
                let e = s.entries[s.head]!
                if !e.consumed { dropped += 1 }
                s.entries[s.head] = nil
                s.head = (s.head + 1) % capacity
                s.count -= 1
            }
            var e = s.entries[s.head]!
            if s.lastReturned == e.frame.sequence { reused = true }
            e.consumed = true
            s.entries[s.head] = e
            s.lastReturned = e.frame.sequence
            result = e.frame
        }
        if result != nil {
            consumedCount.wrappingAdd(1, ordering: .relaxed)
            if reused { reusedCount.wrappingAdd(1, ordering: .relaxed) }
            if dropped > 0 { droppedCount.wrappingAdd(dropped, ordering: .relaxed) }
        }
        return result
    }

    public var stats: FrameSlotStats {
        FrameSlotStats(pushed: pushedCount.load(ordering: .relaxed), consumed: consumedCount.load(ordering: .relaxed),
                       dropped: droppedCount.load(ordering: .relaxed), reused: reusedCount.load(ordering: .relaxed))
    }
}
