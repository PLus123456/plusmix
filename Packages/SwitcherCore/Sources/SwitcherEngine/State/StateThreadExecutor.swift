import Darwin
import Foundation
import Synchronization
import SwitcherContracts

// 状态机 actor 的专用串行执行器：一条 user-interactive 线程。
//
// 两种入口：
//   1. 普通 Swift 并发：任何线程 `await stateMachine.xxx()`，运行时调 `enqueue(job)`，job 进队列、信号量唤醒线程。
//   2. 渲染线程（实时，不许 async / 分配）：`wake(tick:)` 只做一次原子 max + 一次信号量 signal（系统调用，无锁无分配），
//      线程醒来后在 job 之外用 `assumeIsolated` 直接跑 actor 隔离的"准备第 n 拍"。`checkIsolated` 按线程身份放行
//      （SE-0424；探针验证 Swift 6.3 / macOS 26 可用）。
// 为什么不让渲染线程 `Task { await ... }`：创建 Task 会分配。为什么不用 DispatchQueue：拿不到 QoS 之外的线程控制，
// 且要和 actor 隔离对上。

/// 专用线程执行器。
final class StateThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let jobs = Mutex<[UnownedJob]>([])
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var thread: NativeThread?
    private let requestedTick = Atomic<Int64>(Int64.min)
    private var servedTick = Int64.min
    /// 线程醒来发现有新的拍请求时调（执行器线程上）；由 StateMachine 在 init 里设置。
    nonisolated(unsafe) var tickWork: ((Tick) -> Void)?
    private let name: String

    init(name: String = "switcher.state-machine") { self.name = name }

    func start() {
        guard !running.load(ordering: .acquiring) else { return }
        running.store(true, ordering: .releasing)
        let t = NativeThread(config: NativeThreadConfig(name: name, qos: QOS_CLASS_USER_INTERACTIVE)) { [self] in loop() }
        do { try t.start() } catch { running.store(false, ordering: .releasing); return }
        thread = t
    }

    /// 停线程（先把队列里剩下的 job 跑完）。
    func stop() {
        guard running.load(ordering: .acquiring) else { return }
        running.store(false, ordering: .releasing)
        semaphore.signal()
        thread?.join()
        thread = nil
    }

    var isRunning: Bool { running.load(ordering: .acquiring) }

    private func loop() {
        while true {
            semaphore.wait()
            let alive = running.load(ordering: .acquiring)
            // 拍请求优先：渲染线程在等它
            let r = requestedTick.load(ordering: .acquiring)
            if r > servedTick {
                servedTick = r
                tickWork?(Tick(r))
            }
            let batch = jobs.withLock { j -> [UnownedJob] in
                let b = j
                j.removeAll(keepingCapacity: true)
                return b
            }
            for job in batch { job.runSynchronously(on: asUnownedSerialExecutor()) }
            if !alive && jobs.withLock({ $0.isEmpty }) { break }
        }
    }

    // MARK: SerialExecutor

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        jobs.withLock { $0.append(unowned) }
        semaphore.signal()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }

    func checkIsolated() {
        precondition(isCurrentThread, "不在状态机线程上")
    }

    var isCurrentThread: Bool { thread?.isCurrent ?? false }

    // MARK: 渲染线程入口

    /// 请求准备到第 tick 拍（单调）；无锁、无分配。
    func wake(tick: Tick) {
        _ = requestedTick.max(tick.rawValue, ordering: .acquiringAndReleasing)
        semaphore.signal()
    }
}
