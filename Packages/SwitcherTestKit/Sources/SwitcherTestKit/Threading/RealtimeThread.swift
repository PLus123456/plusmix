import Darwin
import Foundation
import SwitcherContracts
import Synchronization

/// 周期性工作线程：QoS userInteractive + Mach time-constraint 策略 + `mach_wait_until`。
///
/// 为什么要 time-constraint：macOS 26 / M5 Max 实测（W1-A 探针），普通 userInteractive 线程上 `mach_wait_until`
/// 平均晚醒 2.8 ms、最大 4.2 ms（定时器合并）；设了 `THREAD_TIME_CONSTRAINT_POLICY` 后平均 13 µs、最大 58 µs。
/// 合成源要模拟"准时到达 ± 指定抖动"的设备，没有这一步测出来的全是系统噪声。
///
/// 用法：`body` 在新线程上跑一次（自己循环），循环里用 `isStopRequested` 退出、用 `wait(until:)` 睡到某个 host time。
/// `stop()` 置位并等线程退出（阻塞，非实时线程调）。
public final class RealtimeThread: @unchecked Sendable {
    /// 线程名（调试器里看得到）。
    public let name: String
    /// time-constraint 策略参数：周期（纳秒）。计算 / 约束时长按周期的 1/8、1/2 取（够合成源用）。
    public let periodNanoseconds: UInt64

    private let stopFlag = Atomic<Bool>(false)
    private let policyApplied = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let body: @Sendable (RealtimeThread) -> Void
    private var thread: Thread?

    public init(name: String, periodNanoseconds: UInt64, body: @escaping @Sendable (RealtimeThread) -> Void) {
        self.name = name
        self.periodNanoseconds = periodNanoseconds
        self.body = body
    }

    /// 是否已请求停止（线程循环每圈查一次）。
    public var isStopRequested: Bool { stopFlag.load(ordering: .acquiring) }
    /// time-constraint 策略是否设置成功（沙盒里可能失败；失败只是精度变差，不是错误）。
    public var isRealtimePolicyApplied: Bool { policyApplied.load(ordering: .acquiring) }

    /// 起线程。重复调用无效。
    public func start() {
        guard thread == nil else { return }
        let t = Thread { [self] in
            policyApplied.store(RealtimeThread.applyTimeConstraintPolicy(periodNanoseconds: periodNanoseconds), ordering: .releasing)
            body(self)
            finished.signal()
        }
        t.name = name
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// 请求停止并等待线程退出。没 start 过直接返回。
    public func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .releasing)
        finished.wait()
        thread = nil
    }

    /// 睡到 host time `time`（已过则立即返回）。
    @inline(__always)
    public static func wait(until time: HostTime) {
        mach_wait_until(time.ticks)
    }

    /// 给当前线程设 THREAD_TIME_CONSTRAINT_POLICY。返回是否成功。
    static func applyTimeConstraintPolicy(periodNanoseconds: UInt64) -> Bool {
        let tb = HostClock.timebase
        func ticks(_ ns: UInt64) -> UInt32 { UInt32(clamping: ns * UInt64(tb.denom) / UInt64(tb.numer)) }
        var policy = thread_time_constraint_policy(
            period: ticks(periodNanoseconds),
            computation: ticks(max(periodNanoseconds / 8, 100_000)),
            constraint: ticks(max(periodNanoseconds / 2, 500_000)),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return result == KERN_SUCCESS
    }
}
