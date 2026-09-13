import Foundation
import Synchronization
import SwitcherContracts

// 消费者侧"自己的有界队列 + 自己的线程"（设计方案 §3.4；CONTRACTS.md T7）的可复用实现。
// `consume` 在引擎的派发线程上被调：只往 SPSC 环里放（满则挤最旧并计 dropped）+ 一次信号量 signal，立即返回。
// 工作线程取出后调 handler 做真正的事（编码、写盘……）。W1-E 的编码器可以直接包一层，也可以自己实现。

/// 带有界队列和工作线程的 FrameConsumer。
public final class QueuedFrameConsumer: FrameConsumer, @unchecked Sendable {
    public let consumerName: String
    /// 队列统计。
    public struct QueueStats: Sendable, Hashable {
        /// consume 被调的次数。
        public var received: UInt64
        /// handler 处理完的帧数。
        public var processed: UInt64
        /// 队列满被挤掉的帧数（E1 skipped 的口径）。
        public var dropped: UInt64
        /// 还在队列里的帧数。
        public var pending: UInt64
    }

    private let ring: SPSCOverwriteRing<RenderedFrame>
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var worker: NativeThread?
    private let handler: @Sendable (RenderedFrame) -> Void
    private let qos: qos_class_t
    private let receivedCount = Atomic<UInt64>(0)
    private let processedCount = Atomic<UInt64>(0)
    private let droppedCount = Atomic<UInt64>(0)

    /// - Parameters:
    ///   - depth: 队列深度（2–3）。
    ///   - handler: 在工作线程上处理一帧。
    public init(name: String, depth: Int = 3, qos: qos_class_t = QOS_CLASS_USER_INITIATED, handler: @escaping @Sendable (RenderedFrame) -> Void) {
        consumerName = name
        ring = SPSCOverwriteRing(capacity: max(depth, 1))
        self.handler = handler
        self.qos = qos
    }

    /// 起工作线程。
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let t = NativeThread(config: NativeThreadConfig(name: "switcher.consumer.\(consumerName)", qos: qos)) { [self] in
            while running.load(ordering: .acquiring) {
                semaphore.wait()
                while let frame = ring.pop() {
                    handler(frame)
                    processedCount.add(1, ordering: .relaxed)
                }
            }
        }
        try t.start()
        worker = t
    }

    /// 停线程（队列里剩的丢弃）。
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        semaphore.signal()
        worker?.join()
        worker = nil
    }

    /// 派发线程：入队并唤醒工作线程，立即返回。
    public func consume(_ frame: RenderedFrame) {
        receivedCount.add(1, ordering: .relaxed)
        switch ring.push(frame) {
        case .stored: break
        case .storedEvictingOldest, .droppedIncoming: droppedCount.add(1, ordering: .relaxed)
        }
        semaphore.signal()
    }

    public var stats: QueueStats {
        QueueStats(received: receivedCount.load(ordering: .acquiring),
                   processed: processedCount.load(ordering: .acquiring),
                   dropped: droppedCount.load(ordering: .acquiring),
                   pending: UInt64(ring.count))
    }
}
