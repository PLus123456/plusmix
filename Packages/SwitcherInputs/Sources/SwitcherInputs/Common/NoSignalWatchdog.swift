import Dispatch
import Synchronization
import SwitcherContracts

/// 无信号检测（设计方案 §6）：期望帧间隔 × `multiplier`（默认 3）没有新帧 → `onChange(false)`；再来帧 → `onChange(true)`。
///
/// 生产者每推一帧调 `noteFrame(at:)`（原子写，不锁）。检查由一个 DispatchSourceTimer 做，周期 = 帧间隔、leeway = 1/4 间隔，
/// 所以置位时刻落在最后一帧之后 N … N + 1.25 个间隔之间。文件输入到结尾时不靠它——它自己知道没有下一帧，直接置位。
/// 回调在 `queue` 上串行执行；`onChange` 里可以改状态、可以锁。
final class NoSignalWatchdog: @unchecked Sendable {
    let expectedInterval: HostDuration
    let multiplier: Int
    private let queue: DispatchQueue
    private let onChange: @Sendable (Bool) -> Void
    private let lastFrame = Atomic<UInt64>(0)
    private let framesSeen = Atomic<UInt64>(0)
    private var timer: DispatchSourceTimer?
    private var signalPresent = false
    private var lastSeenCount: UInt64 = 0

    /// - Parameters:
    ///   - expectedInterval: 期望帧间隔（输入自己的帧率的倒数）。
    ///   - multiplier: N。
    ///   - queue: 回调队列（输入自己的串行队列）。
    ///   - onChange: true = 信号回来了，false = 超时没帧。
    init(expectedInterval: HostDuration, multiplier: Int = 3, queue: DispatchQueue, onChange: @escaping @Sendable (Bool) -> Void) {
        precondition(expectedInterval.ticks > 0 && multiplier >= 1)
        self.expectedInterval = expectedInterval
        self.multiplier = multiplier
        self.queue = queue
        self.onChange = onChange
    }

    /// 超时门限。
    var timeout: HostDuration { expectedInterval * multiplier }

    /// 生产者线程：来了一帧。
    @inline(__always)
    func noteFrame(at time: HostTime = .now()) {
        lastFrame.store(time.ticks, ordering: .relaxed)
        framesSeen.add(1, ordering: .releasing)
    }

    /// 最后一帧的时刻（没有过帧为 nil）。
    var lastFrameTime: HostTime? {
        let t = lastFrame.load(ordering: .acquiring)
        return t == 0 ? nil : HostTime(ticks: t)
    }

    /// 起定时器（在 queue 上跑）。初始视为无信号，第一帧到了才报 true。
    func start() {
        stop()
        signalPresent = false
        lastSeenCount = framesSeen.load(ordering: .acquiring)
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ns = Int(max(expectedInterval.nanoseconds, 1_000_000))
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .nanoseconds(ns / 4))
        t.setEventHandler { [weak self] in self?.check() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 定时器：比较最后一帧时刻与现在。
    private func check() {
        let seen = framesSeen.load(ordering: .acquiring)
        let now = HostClock.now()
        let last = lastFrame.load(ordering: .acquiring)
        let fresh = seen != lastSeenCount
        lastSeenCount = seen
        if fresh || (last != 0 && now - HostTime(ticks: last) <= timeout) {
            if !signalPresent && last != 0 {
                signalPresent = true
                onChange(true)
            }
        } else if signalPresent {
            signalPresent = false
            onChange(false)
        }
    }
}
