import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

// tally 发布器：挂状态机的 SnapshotObserver（提案 003 §D1），每次发布在状态机线程上只做一次 yield 进 AsyncStream；
// 消费任务把快照变成 TallyFrame，与上一帧比 tally 内容，变了才编码一次、扇出给所有订阅者。
// 订阅者各有一个缓冲（最新 64 条），慢客户端丢旧的，永远不拖发布器，更不拖状态机。

/// tally 发布器。
public final class TallyPublisher: @unchecked Sendable, SnapshotObserver {
    /// 一个订阅：已编码的 JSON 帧流（开头补发当前帧）。
    public struct Subscription: Sendable {
        public let id: UInt64
        public let stream: AsyncStream<String>
    }

    /// 诊断计数。
    public struct Counters: Hashable, Sendable {
        /// 出过的帧数（订阅时补发的不算）。
        public var frames: UInt64 = 0
        /// 看过的快照数。
        public var snapshotsSeen: UInt64 = 0
        public var subscribers: Int = 0
    }

    public let stateMachine: StateMachine
    private let clockProvider: @Sendable () -> TickClockSpec?
    private let running = Atomic<Bool>(false)
    private let frames = Atomic<UInt64>(0)
    private let seen = Atomic<UInt64>(0)
    private let nextSubscriberID = Atomic<UInt64>(0)
    private let subscribers = Mutex<[UInt64: AsyncStream<String>.Continuation]>([:])
    private let latestBox = Mutex<(frame: TallyFrame, json: String)?>(nil)
    private let inbox = Mutex<(stream: AsyncStream<MixerSnapshot>, continuation: AsyncStream<MixerSnapshot>.Continuation)?>(nil)
    private let consumer = Mutex<Task<Void, Never>?>(nil)
    /// 每个订阅者的缓冲深度。
    public var bufferDepth = 64

    public init(stateMachine: StateMachine, clock: @escaping @Sendable () -> TickClockSpec?) {
        self.stateMachine = stateMachine
        clockProvider = clock
    }

    public var counters: Counters {
        Counters(frames: frames.load(ordering: .relaxed), snapshotsSeen: seen.load(ordering: .relaxed), subscribers: subscribers.withLock { $0.count })
    }

    /// 最近一帧（tally 内容最后一次变化时的帧）。
    public var latest: TallyFrame? { latestBox.withLock { $0?.frame } }
    /// 最近一帧的 JSON。
    public var latestJSON: String? { latestBox.withLock { $0?.json } }
    /// 当前时钟规格。
    public var clock: TickClockSpec? { clockProvider() }

    // MARK: 生命周期

    /// 用当前快照做第一帧，挂上观察者，起消费任务。
    public func start() async {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if let snap = stateMachine.publisher.latest { _ = ingest(snap) }
        let (stream, continuation) = AsyncStream<MixerSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(16))
        inbox.withLock { $0 = (stream, continuation) }
        let task = Task { [weak self] in
            for await snap in stream {
                guard let self else { return }
                _ = self.ingest(snap)
            }
        }
        consumer.withLock { $0 = task }
        await stateMachine.addSnapshotObserver(self)
    }

    /// 摘掉观察者、停消费任务、结束所有订阅流。
    public func stop() async {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.removeSnapshotObserver(self)
        inbox.withLock { $0?.continuation.finish(); $0 = nil }
        let task = consumer.withLock { t -> Task<Void, Never>? in defer { t = nil }; return t }
        await task?.value
        let subs = subscribers.withLock { s -> [AsyncStream<String>.Continuation] in
            let all = Array(s.values)
            s.removeAll()
            return all
        }
        for c in subs { c.finish() }
    }

    // MARK: 信号（状态机线程）

    public func stateMachine(_ machine: StateMachine, didPublish snapshot: MixerSnapshot) {
        _ = inbox.withLock { $0?.continuation.yield(snapshot) }
    }

    // MARK: 帧

    /// 快照 → 帧；tally 内容变了才成为新的 latest 并扇出。返回是否出了新帧。
    @discardableResult
    func ingest(_ snapshot: MixerSnapshot) -> Bool {
        seen.add(1, ordering: .relaxed)
        let frame = TallyFrame(snapshot: snapshot, clock: clockProvider())
        guard let json = try? TallyJSON.string(frame) else { return false }
        let changed = latestBox.withLock { box -> Bool in
            if let old = box?.frame, old.sameTally(as: frame) { return false }
            box = (frame, json)
            return true
        }
        guard changed else { return false }
        frames.add(1, ordering: .relaxed)
        subscribers.withLock { subs in
            for c in subs.values { _ = c.yield(json) }
        }
        return true
    }

    // MARK: 订阅

    /// 订阅帧流；开头是当前帧（如有）。
    public func subscribe() -> Subscription {
        let id = nextSubscriberID.add(1, ordering: .relaxed).newValue
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(bufferDepth))
        // 在订阅表的锁内补发当前帧并登记：扇出也在同一把锁内，"补发的帧"和"之后的帧"之间不会漏一条
        subscribers.withLock { subs in
            if let json = latestBox.withLock({ $0?.json }) { continuation.yield(json) }
            subs[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UInt64) {
        let c = subscribers.withLock { $0.removeValue(forKey: id) }
        c?.finish()
    }

    /// hello 报文（服务端连接建立时发）。
    public func hello(now: HostTime = .now()) -> String {
        (try? TallyJSON.string(TallyHelloMessage(now: now, clock: clockProvider()))) ?? #"{"type":"hello"}"#
    }

    /// 心跳报文。
    public func heartbeat(now: HostTime = .now()) -> String {
        (try? TallyJSON.string(TallyHeartbeatMessage(now: now, sequence: latest?.sequence ?? 0))) ?? #"{"type":"heartbeat"}"#
    }
}
