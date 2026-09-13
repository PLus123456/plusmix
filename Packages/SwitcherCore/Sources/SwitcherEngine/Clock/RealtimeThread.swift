import Darwin
import Foundation

/// 一条原生线程的配置。
public struct NativeThreadConfig: Sendable {
    /// 线程名（pthread_setname_np，≤ 63 字节）。
    public var name: String
    /// QoS 等级，线程创建时设置。
    public var qos: qos_class_t
    /// 可选的 time-constraint 实时策略（thread_policy_set），进线程后立刻设置。
    public var timeConstraint: TimeConstraint?
    /// 栈大小（字节）。
    public var stackSize: Int

    /// THREAD_TIME_CONSTRAINT_POLICY 的四个参数，单位 host tick（mach_absolute_time 的单位）。
    public struct TimeConstraint: Sendable, Hashable {
        /// 周期：多久需要跑一次。
        public var period: UInt32
        /// 每周期预计的计算量。
        public var computation: UInt32
        /// 计算必须在周期开始后多久内完成。
        public var constraint: UInt32
        /// 计算期间是否可被抢占。
        public var preemptible: Bool
        public init(period: UInt32, computation: UInt32, constraint: UInt32, preemptible: Bool = true) {
            self.period = period
            self.computation = computation
            self.constraint = constraint
            self.preemptible = preemptible
        }
    }

    public init(name: String, qos: qos_class_t = QOS_CLASS_USER_INTERACTIVE, timeConstraint: TimeConstraint? = nil, stackSize: Int = 1 << 20) {
        self.name = name
        self.qos = qos
        self.timeConstraint = timeConstraint
        self.stackSize = stackSize
    }
}

/// 线程创建失败。
public enum NativeThreadError: Error, Equatable {
    case createFailed(Int32)
    case alreadyStarted
}

/// pthread 的薄封装：创建时设 QoS，进线程后可选地挂 time-constraint 实时策略，然后跑 body。
///
/// 为什么不用 Foundation.Thread：它不能在创建前设 QoS 属性，也拿不到 mach 线程端口去设实时策略；
/// 而且 body 里要能读到"实时策略是否设置成功"。
public final class NativeThread: @unchecked Sendable {
    public let config: NativeThreadConfig
    /// 跑完就释放：body 通常捕获了持有本对象的那个对象，不释放会成环。
    private var body: (@Sendable () -> Void)?
    private var thread: pthread_t?
    private var started = false
    private var joined = false
    /// 实时策略是否设置成功（没申请时为 false）。线程启动后有效。
    public private(set) var appliedTimeConstraint = false
    /// 设置实时策略的返回码（KERN_SUCCESS = 0）。
    public private(set) var timeConstraintResult: kern_return_t = KERN_SUCCESS
    private let ready = DispatchSemaphore(value: 0)

    public init(config: NativeThreadConfig, body: @escaping @Sendable () -> Void) {
        self.config = config
        self.body = body
    }

    /// 启动；返回时线程已经跑起来并完成了策略设置（appliedTimeConstraint 可读）。
    public func start() throws {
        guard !started else { throw NativeThreadError.alreadyStarted }
        started = true
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        pthread_attr_set_qos_class_np(&attr, config.qos, 0)
        pthread_attr_setstacksize(&attr, max(config.stackSize, 64 * 1024))
        let context = Unmanaged.passRetained(self).toOpaque()
        var t: pthread_t?
        let rc = pthread_create(&t, &attr, { raw in
            let me = Unmanaged<NativeThread>.fromOpaque(raw).takeRetainedValue()
            me.run()
            return nil
        }, context)
        guard rc == 0, let t else {
            Unmanaged<NativeThread>.fromOpaque(context).release()
            started = false
            throw NativeThreadError.createFailed(rc)
        }
        thread = t
        ready.wait()
    }

    private func run() {
        var name = config.name
        if name.utf8.count > 63 { name = String(name.utf8.prefix(63))! }
        pthread_setname_np(name)
        if let tc = config.timeConstraint {
            var policy = thread_time_constraint_policy_data_t(period: tc.period, computation: tc.computation,
                                                              constraint: tc.constraint, preemptible: tc.preemptible ? 1 : 0)
            let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &policy) { p in
                p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                    thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
                }
            }
            timeConstraintResult = kr
            appliedTimeConstraint = kr == KERN_SUCCESS
        }
        ready.signal()
        let work = body
        body = nil
        work?()
    }

    /// 等线程结束。可重复调。
    public func join() {
        guard let t = thread, !joined else { return }
        joined = true
        pthread_join(t, nil)
    }

    /// 当前线程就是这条线程。
    public var isCurrent: Bool {
        guard let t = thread else { return false }
        return pthread_equal(pthread_self(), t) != 0
    }
}
