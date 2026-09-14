// sw_rt_guard.h —— 实时线程守卫（测试标准 §2.9 的"进入回调时置标志"方案）。
//
// sw_mix_block 进入时 sw_rt_guard_enter()、退出时 sw_rt_guard_exit()。守卫记录"当前在实时块里的线程"。
// 非实时侧的封装（CSwitcherAudioHost 的 sw_host_alloc / sw_host_lock / sw_host_log）调用 sw_rt_guard_check()：
// 如果调用线程正处于实时块内，违规计数 +1（A7 的口径）。测试里另外挂 libmalloc 的 malloc_logger 钩子
// （sw_rt_probe_*，在 Host target），把实时块内任何 malloc / free 也记进同一个计数。
// 只用全局原子量，不用线程局部存储：Darwin 的 __thread 首次访问会分配 TLS 块，本身就违规。
#ifndef SW_RT_GUARD_H
#define SW_RT_GUARD_H
#include <stdint.h>
#include <stdbool.h>
#include "sw_rt_attr.h"
#include "sw_rt_extern.h"

#ifdef __cplusplus
extern "C" {
#endif

/// 当前处于实时块内的线程（pthread_self 的值；0 = 无）。
extern uintptr_t sw_rt_guard_thread;
/// 嵌套深度（同一线程可嵌套）。
extern uint32_t sw_rt_guard_depth;
/// 违规计数（累计，任何线程原子加）。
extern uint64_t sw_rt_guard_violations;

/// 进入实时块。pthread_self 在 Darwin 上只读线程结构，不进内核。
static inline void sw_rt_guard_enter(void) SW_NONBLOCKING {
    __atomic_store_n(&sw_rt_guard_thread, sw_rt_thread_id(), __ATOMIC_RELAXED);
    __atomic_fetch_add(&sw_rt_guard_depth, 1u, __ATOMIC_RELEASE);
}
/// 退出实时块。
static inline void sw_rt_guard_exit(void) SW_NONBLOCKING {
    if (__atomic_sub_fetch(&sw_rt_guard_depth, 1u, __ATOMIC_ACQ_REL) == 0) {
        __atomic_store_n(&sw_rt_guard_thread, (uintptr_t)0, __ATOMIC_RELAXED);
    }
}
/// 调用线程此刻是否在实时块内。
static inline bool sw_rt_guard_active_on_this_thread(void) SW_NONBLOCKING {
    return __atomic_load_n(&sw_rt_guard_depth, __ATOMIC_ACQUIRE) != 0 &&
           __atomic_load_n(&sw_rt_guard_thread, __ATOMIC_RELAXED) == sw_rt_thread_id();
}
/// 非实时封装在入口调用：在实时块内被调到就记一次违规。返回是否违规。
static inline bool sw_rt_guard_check(void) SW_NONBLOCKING {
    if (sw_rt_guard_active_on_this_thread()) {
        __atomic_fetch_add(&sw_rt_guard_violations, 1u, __ATOMIC_RELAXED);
        return true;
    }
    return false;
}
/// 读违规计数。
static inline uint64_t sw_rt_guard_violation_count(void) SW_NONBLOCKING {
    return __atomic_load_n(&sw_rt_guard_violations, __ATOMIC_RELAXED);
}
/// 清零（测试用，非实时线程）。
static inline void sw_rt_guard_reset(void) {
    __atomic_store_n(&sw_rt_guard_violations, (uint64_t)0, __ATOMIC_RELAXED);
}

#ifdef __cplusplus
}
#endif
#endif /* SW_RT_GUARD_H */
