import Darwin
import Foundation
import Synchronization
import SwitcherContracts

/// 输入自己的线程：pthread + 可选的 time-constraint 实时策略 + 停止标志 + `wait(until:)`（mach_wait_until）。
///
/// 为什么要实时策略：普通线程的任何定时等待会被内核合并晚醒 1–7 ms（W1-A / W1-B 实测），文件 / 图片按拍点推帧、
/// 文件音频按块节拍写环，都要准点。这些线程每拍只做几十微秒的事（推帧、写环），不是渲染 / 音频热路径，允许锁和分配。
public final class InputThread: @unchecked Sendable {
    /// 线程名。
    public let name: String
    private let period: HostDuration?
    private let qos: qos_class_t
    private var body: (@Sendable (InputThread) -> Void)?
    private var thread: pthread_t?
    private let stopFlag = Atomic<Bool>(false)
    private let startedFlag = Atomic<Bool>(false)
    private let ready = DispatchSemaphore(value: 0)
    /// 实时策略是否设置成功（没申请时为 false）。
    public private(set) var appliedTimeConstraint = false

    /// - Parameters:
    ///   - period: 非 nil 时进线程后挂 THREAD_TIME_CONSTRAINT_POLICY（period = 它，computation = 1 ms，constraint = 2 ms 或 period 的一半）。
    public init(name: String, period: HostDuration? = nil, qos: qos_class_t = QOS_CLASS_USER_INTERACTIVE,
                body: @escaping @Sendable (InputThread) -> Void) {
        self.name = name
        self.period = period
        self.qos = qos
        self.body = body
    }

    /// 是否已请求停止（线程循环每轮检查）。
    public var isStopRequested: Bool { stopFlag.load(ordering: .relaxed) }

    /// 起线程；返回时线程已跑起来并完成策略设置。重复 start 无效。
    public func start() {
        guard !startedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        pthread_attr_set_qos_class_np(&attr, qos, 0)
        pthread_attr_setstacksize(&attr, 1 << 20)
        let context = Unmanaged.passRetained(self).toOpaque()
        var t: pthread_t?
        let rc = pthread_create(&t, &attr, { raw in
            let me = Unmanaged<InputThread>.fromOpaque(raw).takeRetainedValue()
            me.run()
            return nil
        }, context)
        guard rc == 0, let t else {
            Unmanaged<InputThread>.fromOpaque(context).release()
            startedFlag.store(false, ordering: .releasing)
            return
        }
        thread = t
        ready.wait()
    }

    /// 请求停止并等线程退出。可重复调。
    public func stop() {
        stopFlag.store(true, ordering: .releasing)
        if let t = thread, pthread_equal(pthread_self(), t) == 0 {
            pthread_join(t, nil)
            thread = nil
        }
    }

    private func run() {
        var n = name
        if n.utf8.count > 63 { n = String(n.utf8.prefix(63))! }
        pthread_setname_np(n)
        if let period, period.ticks > 0 {
            let computation = HostDuration(milliseconds: 1).ticks
            let constraint = max(min(HostDuration(milliseconds: 2).ticks, period.ticks / 2), computation)
            var policy = thread_time_constraint_policy_data_t(period: UInt32(clamping: period.ticks),
                                                              computation: UInt32(clamping: computation),
                                                              constraint: UInt32(clamping: constraint), preemptible: 1)
            let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &policy) { p in
                p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                    thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
                }
            }
            appliedTimeConstraint = kr == KERN_SUCCESS
        }
        ready.signal()
        let work = body
        body = nil
        work?(self)
    }

    /// 睡到某个 host time（已过去则立刻返回）。
    @inline(__always)
    public static func wait(until time: HostTime) {
        if HostClock.now() < time { mach_wait_until(time.ticks) }
    }

    /// 睡到某个时刻，但每 `slice` 醒一次看停止标志（长睡时用，停机不用等到点）。
    public func sleep(until time: HostTime, slice: HostDuration = HostDuration(milliseconds: 20)) {
        while !isStopRequested {
            let now = HostClock.now()
            if now >= time { return }
            let due = min(time, now + slice)
            mach_wait_until(due.ticks)
        }
    }
}
