// RealtimeGuard.swift —— 实时线程守卫的 Swift 入口（测试标准 §2.9；A7）。
//
// 编译期：热路径函数带 [[clang::nonblocking]]，-Wfunction-effects 升级为错误（sw_rt_pragma.h）。
// 链接期：scripts/check-rt-symbols.sh 对热路径目标文件 nm -u。
// 运行期：sw_mix_block 进出置守卫；本仓库的分配 / 锁 / 日志封装在守卫区内被调到就记违规；
//         测试里另挂 libmalloc 的 malloc_logger 钩子，守卫区内的任何 malloc / free 都记进同一个计数。
import CSwitcherAudioRT
import CSwitcherAudioHost

public enum RealtimeGuard {
    /// 累计违规次数（A7 的数）。
    public static var violations: UInt64 { sw_rt_guard_violation_count() }
    /// 清零（违规计数与钩子计数）。
    public static func reset() { sw_rt_probe_reset() }
    /// 挂 malloc 钩子（进程级；测试用）。
    public static func installMallocProbe() { sw_rt_probe_install_malloc_hook() }
    public static func removeMallocProbe() { sw_rt_probe_remove_malloc_hook() }
    /// 钩子记到的实时区内分配次数。
    public static var allocationsInRealtime: UInt64 { sw_rt_probe_allocations_in_rt() }
    /// 自检：守卫区里故意分配，返回钩子记到的次数（≥ 2 说明机制有效）。
    public static func selfTest() -> UInt64 { sw_rt_probe_selftest() }
    /// 当前线程是否在实时块内。
    public static var isActiveOnThisThread: Bool { sw_rt_guard_active_on_this_thread() }
}
