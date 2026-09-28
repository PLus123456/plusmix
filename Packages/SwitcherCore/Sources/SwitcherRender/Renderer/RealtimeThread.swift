// 完成线程用的原生线程：pthread + QoS + THREAD_TIME_CONSTRAINT_POLICY（W1-B3）。
//
// 为什么完成线程也要实时策略：它在 waitUntilCompleted 上等 GPU，醒来后放行在途计数（渲染线程按它判 .skipped）。
// 桌面 / 系统守护进程突发时普通 user-interactive 线程可能晚几毫秒才被调度，在途计数就晚几毫秒才减；实时策略让"GPU 完成 → 放行"
// 的延迟只剩微秒级，剩下的跳拍就只可能是 GPU 侧的（MetalRenderer 的跳拍归因计数据此分类）。参数与节目时钟线程同一套口径：
// period = 拍长，computation / constraint 按拍长的比例。SwitcherRender 只见 Contracts，不能用 SwitcherEngine 的 NativeThread，这里是同一做法的独立实现。
import Darwin
import Foundation

/// 线程配置。
struct RealtimeThreadConfig: Sendable {
    var name: String
    var qos: qos_class_t = QOS_CLASS_USER_INTERACTIVE
    /// THREAD_TIME_CONSTRAINT_POLICY 参数，单位 host tick；nil = 不挂实时策略。
    var timeConstraint: TimeConstraint?
    var stackSize: Int = 512 * 1024

    struct TimeConstraint: Sendable, Hashable {
        var period: UInt32
        var computation: UInt32
        var constraint: UInt32
        var preemptible: Bool = true
    }
}

/// pthread 的薄封装：创建前设 QoS，进线程后挂实时策略，`start` 返回时策略结果已可读。
final class RealtimeThread: @unchecked Sendable {
    let config: RealtimeThreadConfig
    private var body: (@Sendable () -> Void)?
    private var thread: pthread_t?
    private var joined = false
    private let ready = DispatchSemaphore(value: 0)
    /// 实时策略是否设置成功（没申请为 false）。
    private(set) var appliedTimeConstraint = false
    private(set) var timeConstraintResult: kern_return_t = KERN_SUCCESS
    /// 线程的 mach 端口（start 之后有效；测试用它读回策略）。
    private(set) var machPort: thread_t = 0

    init(config: RealtimeThreadConfig, body: @escaping @Sendable () -> Void) {
        self.config = config
        self.body = body
    }

    enum StartError: Error { case createFailed(Int32), alreadyStarted }

    func start() throws {
        guard thread == nil else { throw StartError.alreadyStarted }
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        pthread_attr_set_qos_class_np(&attr, config.qos, 0)
        pthread_attr_setstacksize(&attr, max(config.stackSize, 64 * 1024))
        let context = Unmanaged.passRetained(self).toOpaque()
        var t: pthread_t?
        let rc = pthread_create(&t, &attr, { raw in
            let me = Unmanaged<RealtimeThread>.fromOpaque(raw).takeRetainedValue()
            me.run()
            return nil
        }, context)
        guard rc == 0, let t else {
            Unmanaged<RealtimeThread>.fromOpaque(context).release()
            throw StartError.createFailed(rc)
        }
        thread = t
        ready.wait()
    }

    private func run() {
        var name = config.name
        if name.utf8.count > 63 { name = String(name.utf8.prefix(63))! }
        pthread_setname_np(name)
        machPort = pthread_mach_thread_np(pthread_self())
        if let tc = config.timeConstraint {
            var policy = thread_time_constraint_policy_data_t(period: tc.period, computation: tc.computation,
                                                              constraint: tc.constraint, preemptible: tc.preemptible ? 1 : 0)
            let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &policy) { p in
                p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                    thread_policy_set(machPort, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, count)
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
    func join() {
        guard let t = thread, !joined else { return }
        joined = true
        pthread_join(t, nil)
    }
}

/// 读回一条线程的 time-constraint 策略（thread_policy_get，get_default = false）。
/// 探针（reports/w1-core-3.md §1）：挂了策略的线程返回 get_default = 0 与设置的参数；普通线程返回 get_default = 1 与内核默认值。
enum ThreadPolicyProbe {
    struct TimeConstraintReadback: Equatable {
        var isDefault: Bool
        var period: UInt32
        var computation: UInt32
        var constraint: UInt32
    }
    static func timeConstraint(of port: thread_t) -> TimeConstraintReadback? {
        var policy = thread_time_constraint_policy_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var getDefault: boolean_t = 0
        let kr = withUnsafeMutablePointer(to: &policy) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                thread_policy_get(port, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), ip, &count, &getDefault)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return TimeConstraintReadback(isDefault: getDefault != 0, period: policy.period, computation: policy.computation, constraint: policy.constraint)
    }
}
