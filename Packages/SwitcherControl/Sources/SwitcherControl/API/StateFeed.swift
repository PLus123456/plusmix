import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

// 状态推送源：把状态机发布的快照变成 WS 事件流（整快照 + 版本号），外加每秒一行 Stats。
//
// 怎么知道"状态变了"：挂状态机的 SnapshotObserver（提案 003 §D1）——每次 publish 之后在状态机线程上被调，只做一次信号量 signal；
// 推送线程醒来读 `publisher.latest`，对象身份和上次发的不同才编码一次、扇出给所有订阅者。所以同一拍内多条命令只发最终状态，
// 每拍最多一条（渲染线程也只看到每拍一个快照）；订阅者各有一个 AsyncStream 缓冲（最新 256 条），慢客户端丢旧的，
// 永远不拖推送线程，更不拖状态机。250 ms 轮询兜底（观察者还没挂上的窗口）。
// 每条快照带 publishedAt（状态机发布时刻）和 sentAt（这里序列化的时刻）：C2 的"状态变化 → 客户端"从 publishedAt 算。
// 顺序（Codex 10-22 审查 N12）：推送线程在订阅表锁外编码，编码旧快照的空当里新订阅会先补发到更新的那条；所以每个订阅者记着
// 最后发给它的快照键 (sequence, tick)，扇出时比它旧的不发——同 sequence 的新拍（转场 / 动画每拍一条、不带新命令）照发，键相同的也照发
// （不经总线的 apply / 每拍注入可以在同一拍、同一 sequence 再发布一次不同的状态）。

/// 状态推送源。
public final class StateFeed: @unchecked Sendable, SnapshotObserver {
    /// 一个订阅：已编码的 JSON 文本流。
    public struct Subscription: Sendable {
        public let id: UInt64
        public let stream: AsyncStream<String>
    }

    /// 诊断计数。
    public struct Counters: Hashable, Sendable {
        /// 发出去的快照条数（订阅时补发的当前快照不算）。
        public var snapshots: UInt64 = 0
        public var stats: UInt64 = 0
        public var wakeups: UInt64 = 0
        public var subscribers: Int = 0
    }

    /// 快照的先后（N12）：先比 sequence、再比 tick。
    struct SnapshotKey: Comparable, Sendable {
        let sequence: UInt64
        let tick: Tick
        init(_ snap: MixerSnapshot) {
            sequence = snap.sequence
            tick = snap.tick
        }
        static func < (a: Self, b: Self) -> Bool { (a.sequence, a.tick) < (b.sequence, b.tick) }
    }

    /// 一个订阅者：它的流 + 最后发给它的快照键（还没发过快照为 nil）。
    private struct Subscriber: Sendable {
        let continuation: AsyncStream<String>.Continuation
        var lastSnapshot: SnapshotKey?
    }

    public let stateMachine: StateMachine
    private let clockProvider: @Sendable () -> TickClockSpec?
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private let wakeups = Atomic<UInt64>(0)
    private let snapshotsSent = Atomic<UInt64>(0)
    private let statsSent = Atomic<UInt64>(0)
    private let nextSubscriberID = Atomic<UInt64>(0)
    private let subscribers = Mutex<[UInt64: Subscriber]>([:])
    private let latestStatsBox = Mutex<Stats?>(nil)
    private let lastSent = Mutex<MixerSnapshot?>(nil)
    private var thread: Thread?
    private let stopped = DispatchSemaphore(value: 0)
    /// 每个订阅者的缓冲深度。
    public var bufferDepth = 256

    /// - Parameter clock: 节目时钟规格的来源（引擎起了时钟才有；用来算 tickTime）。
    public init(stateMachine: StateMachine, clock: @escaping @Sendable () -> TickClockSpec?) {
        self.stateMachine = stateMachine
        clockProvider = clock
    }

    public var counters: Counters {
        Counters(snapshots: snapshotsSent.load(ordering: .relaxed), stats: statsSent.load(ordering: .relaxed),
                 wakeups: wakeups.load(ordering: .relaxed), subscribers: subscribers.withLock { $0.count })
    }

    /// 最近一行 Stats。
    public var latestStats: Stats? { latestStatsBox.withLock { $0 } }

    /// 当前时钟规格。
    public var clock: TickClockSpec? { clockProvider() }

    // MARK: 生命周期

    /// 挂上状态机的快照观察者并起推送线程。
    public func start() async {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let t = Thread { [self] in loop() }
        t.name = "switcher.state-feed"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        await stateMachine.addSnapshotObserver(self)
    }

    /// 停线程、摘掉观察者、结束所有订阅流。
    public func stop() async {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.removeSnapshotObserver(self)
        semaphore.signal()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [stopped] in
                stopped.wait()
                c.resume()
            }
        }
        thread = nil
        let subs = subscribers.withLock { s -> [AsyncStream<String>.Continuation] in
            let all = s.values.map(\.continuation)
            s.removeAll()
            return all
        }
        for c in subs { c.finish() }
    }

    // MARK: 信号（状态机线程）

    public func stateMachine(_ machine: StateMachine, didPublish snapshot: MixerSnapshot) {
        semaphore.signal()
    }

    // MARK: Stats

    /// 灌一行 Stats（引擎每秒汇总的那一行——StatsPublisher 的一个消费者；铁律 4：API 不另算）。
    public func publish(stats: Stats) {
        latestStatsBox.withLock { $0 = stats }
        guard let text = try? APIJSON.string(StatsMessage(stats: stats)) else { return }
        statsSent.add(1, ordering: .relaxed)
        fanOut(text)
    }

    // MARK: 订阅

    /// 订阅事件流。流的开头是 hello、当前快照、最近一行 Stats（如有）。
    public func subscribe() -> Subscription {
        let id = nextSubscriberID.add(1, ordering: .relaxed).newValue
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(bufferDepth))
        // 在订阅表的锁内补发当前状态并登记：扇出也在同一把锁内，所以"补发的快照"和"之后的推送"之间不会漏一条；
        // 补发的快照键一起登记，推送线程拿着锁外编好的旧快照来扇出时就不会发给它（N12）
        subscribers.withLock { subs in
            let now = HostClock.now()
            var sent: SnapshotKey? = nil
            if let hello = try? APIJSON.string(HelloMessage(now: now, clock: clockProvider())) { continuation.yield(hello) }
            if let snap = stateMachine.publisher.latest, let text = try? encode(snap, sentAt: now) {
                continuation.yield(text)
                sent = SnapshotKey(snap)
            }
            if let stats = latestStatsBox.withLock({ $0 }), let text = try? APIJSON.string(StatsMessage(stats: stats)) { continuation.yield(text) }
            subs[id] = Subscriber(continuation: continuation, lastSnapshot: sent)
        }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UInt64) {
        let c = subscribers.withLock { $0.removeValue(forKey: id)?.continuation }
        c?.finish()
    }

    /// 只发给一个订阅者（WS 命令的回执）。
    public func send(_ text: String, to id: UInt64) {
        subscribers.withLock { _ = $0[id]?.continuation.yield(text) }
    }

    // MARK: GET /state 用

    /// 当前状态的完整应答（GET /api/v1/state）。
    public func stateResponse(now: HostTime = .now()) -> StateResponse {
        let snap = stateMachine.publisher.latest
        let state = snap?.state ?? MixerState()
        let clock = clockProvider()
        return StateResponse(now: now, clock: clock, sequence: snap?.sequence ?? 0, tick: snap?.tick ?? .zero,
                             tickTime: snap.flatMap { s in clock?.time(of: s.tick) }, publishedAt: snap?.publishedAt ?? now,
                             state: state, tally: state.tallies, stats: latestStatsBox.withLock { $0 })
    }

    // MARK: 推送线程

    private func loop() {
        var lastSeen: MixerSnapshot? = stateMachine.publisher.latest
        lastSent.withLock { $0 = lastSeen }
        while true {
            _ = semaphore.wait(timeout: .now() + .milliseconds(250))
            if !running.load(ordering: .acquiring) { break }
            wakeups.add(1, ordering: .relaxed)
            guard let snap = stateMachine.publisher.latest, snap !== lastSeen else { continue }
            lastSeen = snap
            lastSent.withLock { $0 = snap }
            if let text = try? encode(snap, sentAt: HostClock.now()) {
                snapshotsSent.add(1, ordering: .relaxed)
                fanOut(text, snapshot: SnapshotKey(snap))
            }
        }
        stopped.signal()
    }

    private func encode(_ snap: MixerSnapshot, sentAt: HostTime) throws -> String {
        let clock = clockProvider()
        let message = SnapshotMessage(sequence: snap.sequence, tick: snap.tick, tickTime: clock?.time(of: snap.tick), publishedAt: snap.publishedAt,
                                      sentAt: sentAt, state: snap.state, tally: snap.state.tallies)
        return try APIJSON.string(message)
    }

    /// 扇出给所有订阅者。快照带上它的键：比某个订阅者已收到的旧就跳过它（N12），发了就记下。Stats 不带键，照发。
    private func fanOut(_ text: String, snapshot key: SnapshotKey? = nil) {
        subscribers.withLock { subs in
            for (id, sub) in subs {
                if let key {
                    if let last = sub.lastSnapshot, key < last { continue }
                    subs[id]?.lastSnapshot = key
                }
                _ = sub.continuation.yield(text)
            }
        }
    }
}
