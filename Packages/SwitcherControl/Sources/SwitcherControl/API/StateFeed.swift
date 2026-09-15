import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

// 状态推送源：把状态机发布的快照变成 WS 事件流（整快照 + 版本号），外加每秒一行 Stats。
//
// 怎么知道"状态变了"：状态机没有"快照已发布"的回调，这里用两个信号 + 一个兜底：
//   1. TickObserver：每拍 advance 之后（排程命令与发布之前）在状态机线程上被调，只做一次原子 max + 信号量；
//      推送线程醒来后等 `preparedTick ≥ 那一拍`（publish 之后才存 preparedTick），再读 `publisher.latest`。
//   2. CommandBusObserver：总线上每条命令回执返回前调；那时快照已经发布，直接唤醒。
//   3. 250 ms 轮询兜底（没有引擎时钟、也没有总线命令的场合）。
// 推送线程比较 `latest` 的对象身份，和上次发的不同才编码一次、扇出给所有订阅者；所以同一拍内多条命令只发最终状态，
// 每拍最多一条（渲染线程也只看到每拍一个快照）。订阅者各有一个 AsyncStream 缓冲（最新 256 条），慢客户端丢旧的，
// 永远不拖推送线程，更不拖状态机。

/// 状态推送源。
public final class StateFeed: @unchecked Sendable, TickObserver, CommandBusObserver {
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

    public let stateMachine: StateMachine
    private let clockProvider: @Sendable () -> TickClockSpec?
    private let semaphore = DispatchSemaphore(value: 0)
    private let requestedTick = Atomic<Int64>(Int64.min)
    private let running = Atomic<Bool>(false)
    private let wakeups = Atomic<UInt64>(0)
    private let snapshotsSent = Atomic<UInt64>(0)
    private let statsSent = Atomic<UInt64>(0)
    private let nextSubscriberID = Atomic<UInt64>(0)
    private let subscribers = Mutex<[UInt64: AsyncStream<String>.Continuation]>([:])
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

    /// 挂上状态机的每拍观察者并起推送线程。
    public func start() async {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.addTickObserver(self)
        let t = Thread { [self] in loop() }
        t.name = "switcher.state-feed"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// 停线程、摘掉观察者、结束所有订阅流。
    public func stop() async {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        await stateMachine.removeTickObserver(self)
        semaphore.signal()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [stopped] in
                stopped.wait()
                c.resume()
            }
        }
        thread = nil
        let subs = subscribers.withLock { s -> [AsyncStream<String>.Continuation] in
            let all = Array(s.values)
            s.removeAll()
            return all
        }
        for c in subs { c.finish() }
    }

    /// 让总线上每条命令都唤醒推送。
    public func attach(to bus: CommandBus) { bus.addObserver(self) }

    // MARK: 信号（状态机线程 / 提交方任务）

    public func stateMachine(_ machine: isolated StateMachine, willApplyTick tick: Tick) {
        _ = requestedTick.max(tick.rawValue, ordering: .acquiringAndReleasing)
        semaphore.signal()
    }

    public func commandBus(_ bus: CommandBus, didApply entry: CommandLogEntry) {
        semaphore.signal()
    }

    // MARK: Stats

    /// 灌一行 Stats（引擎每秒汇总的那一行；铁律 4：API 不另算）。
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
        // 在订阅表的锁内补发当前状态并登记：扇出也在同一把锁内，所以"补发的快照"和"之后的推送"之间不会漏一条
        subscribers.withLock { subs in
            let now = HostClock.now()
            if let hello = try? APIJSON.string(HelloMessage(now: now, clock: clockProvider())) { continuation.yield(hello) }
            if let snap = stateMachine.publisher.latest, let text = try? encode(snap, sentAt: now) { continuation.yield(text) }
            if let stats = latestStatsBox.withLock({ $0 }), let text = try? APIJSON.string(StatsMessage(stats: stats)) { continuation.yield(text) }
            subs[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UInt64) {
        let c = subscribers.withLock { $0.removeValue(forKey: id) }
        c?.finish()
    }

    /// 只发给一个订阅者（WS 命令的回执）。
    public func send(_ text: String, to id: UInt64) {
        subscribers.withLock { _ = $0[id]?.yield(text) }
    }

    // MARK: GET /state 用

    /// 当前状态的完整应答（GET /api/v1/state）。
    public func stateResponse(now: HostTime = .now()) -> StateResponse {
        let snap = stateMachine.publisher.latest
        let state = snap?.state ?? MixerState()
        let clock = clockProvider()
        return StateResponse(now: now, clock: clock, sequence: snap?.sequence ?? 0, tick: snap?.tick ?? .zero,
                             tickTime: snap.flatMap { s in clock?.time(of: s.tick) }, state: state, tally: state.tallies,
                             stats: latestStatsBox.withLock { $0 })
    }

    // MARK: 推送线程

    private func loop() {
        var lastSeen: MixerSnapshot? = stateMachine.publisher.latest
        lastSent.withLock { $0 = lastSeen }
        while true {
            _ = semaphore.wait(timeout: .now() + .milliseconds(250))
            if !running.load(ordering: .acquiring) { break }
            wakeups.add(1, ordering: .relaxed)
            // 每拍观察者报的拍还没准备完（快照还没发布）就再等一小会儿，别读到上一拍的
            let requested = requestedTick.load(ordering: .acquiring)
            if requested != Int64.min && stateMachine.preparedTick.rawValue < requested {
                var spins = 0
                while stateMachine.preparedTick.rawValue < requested && spins < 20 && running.load(ordering: .acquiring) {
                    _ = semaphore.wait(timeout: .now() + .microseconds(100))
                    spins += 1
                }
            }
            guard let snap = stateMachine.publisher.latest, snap !== lastSeen else { continue }
            lastSeen = snap
            lastSent.withLock { $0 = snap }
            if let text = try? encode(snap, sentAt: HostClock.now()) {
                snapshotsSent.add(1, ordering: .relaxed)
                fanOut(text)
            }
        }
        stopped.signal()
    }

    private func encode(_ snap: MixerSnapshot, sentAt: HostTime) throws -> String {
        let clock = clockProvider()
        let message = SnapshotMessage(sequence: snap.sequence, tick: snap.tick, tickTime: clock?.time(of: snap.tick), sentAt: sentAt,
                                      state: snap.state, tally: snap.state.tallies)
        return try APIJSON.string(message)
    }

    private func fanOut(_ text: String) {
        subscribers.withLock { subs in
            for c in subs.values { _ = c.yield(text) }
        }
    }
}
