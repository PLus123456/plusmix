import Darwin
import Foundation
import Synchronization
import SwitcherContracts

// 每秒一行 Stats 的唯一来源（铁律 4、提案 003 §D2）：一条采样线程按固定周期调 `engine.makeStats()`，把同一行扇出给所有消费者
// （StatsWriter.submit、UI 状态行、API 推送），`latest` 给随时来读的人。三方各自调 makeStats 会把窗口口径搞乱（窗口 = 上次调用到现在），
// 所以整个进程只该有一个 StatsPublisher 在采样。
//
// 线程：普通线程（QoS user-initiated），mach_wait_until 等下一个采样点（绝对时刻，不累积误差；DispatchSemaphore 的墙钟超时在
// 低 QoS 线程上会被定时器合并拖晚 30 ms 以上，测试里量到 50 ms 周期变 80 ms），每 50 ms 醒一次看要不要停；
// 消费者在采样线程上被同步调，必须快（写文件的用自己的队列）。

/// Stats 发布器。
public final class StatsPublisher: @unchecked Sendable {
    public let engine: Engine
    /// 采样周期。
    public let interval: HostDuration
    private let consumers = Mutex<[@Sendable (Stats) -> Void]>([])
    private let latestBox = Mutex<Stats?>(nil)
    private let rowCount = Atomic<UInt64>(0)
    private let stopFlag = Atomic<Bool>(false)
    private let sampleLock = Mutex<Void>(())
    /// 等待时每隔这么久看一次停机标志。
    private let stopCheck = HostDuration(milliseconds: 50)
    private var thread: NativeThread?

    /// - Parameter interval: 秒，默认 1（测试标准 §2.4 每秒一行）。
    public init(engine: Engine, interval: TimeInterval = 1) {
        precondition(interval > 0)
        self.engine = engine
        self.interval = HostDuration(seconds: interval)
    }

    deinit { stop() }

    /// 最近一行。
    public var latest: Stats? { latestBox.withLock { $0 } }
    /// 已发布的行数。
    public var rows: UInt64 { rowCount.load(ordering: .acquiring) }
    public var isRunning: Bool { thread != nil }

    /// 加一个消费者（在采样线程上被同步调；可在运行中加）。
    public func addConsumer(_ consumer: @escaping @Sendable (Stats) -> Void) {
        consumers.withLock { $0.append(consumer) }
    }

    /// 起采样线程；第一行在一个周期之后。
    public func start() throws {
        guard thread == nil else { return }
        stopFlag.store(false, ordering: .releasing)
        let t = NativeThread(config: NativeThreadConfig(name: "switcher.stats", qos: QOS_CLASS_USER_INITIATED, stackSize: 256 * 1024)) { [self] in loop() }
        try t.start()
        thread = t
    }

    /// 停采样线程（最多 50 ms 后退出，等它退出）。可重复调。
    public func stop() {
        guard let t = thread else { return }
        stopFlag.store(true, ordering: .releasing)
        t.join()
        thread = nil
    }

    /// 立刻采一行并扇出（停机前的最后一行 / 测试）。
    @discardableResult
    public func sampleNow() -> Stats {
        sampleLock.withLock { _ in
            let row = engine.makeStats()
            latestBox.withLock { $0 = row }
            rowCount.add(1, ordering: .relaxed)
            let list = consumers.withLock { $0 }
            for c in list { c(row) }
            return row
        }
    }

    private func loop() {
        var next = HostClock.now() + interval
        while !stopFlag.load(ordering: .acquiring) {
            let now = HostClock.now()
            if now < next {
                let until = min(next, now + stopCheck)
                mach_wait_until(until.ticks)
                continue
            }
            sampleNow()
            next += interval
            if next < HostClock.now() { next = HostClock.now() + interval }   // 掉队（睡眠 / 调试器）就重新对齐
        }
    }
}
