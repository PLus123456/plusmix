// sw_rt_extern.h —— 热路径允许调用的外部函数，每个都经过审计后用显式函数指针转换标成 nonblocking。
//
// -Wfunction-effects 对"本翻译单元没有定义"的函数一律报错；这里是唯一的例外入口，
// 审计结论逐条写在函数上方；scripts/check-rt-symbols.sh 的允许清单和这里一一对应。
// 别处不许再直接调用未标注的外部函数。
#ifndef SW_RT_EXTERN_H
#define SW_RT_EXTERN_H
#include <stdint.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <samplerate.h>
#include <ebur128.h>
#include <AudioToolbox/AudioUnit.h>
#include "sw_rt_attr.h"

#ifdef __cplusplus
extern "C" {
#endif

/// mach_absolute_time：commpage 读取，不进内核（Darwin libsystem_kernel），所有音频引擎都在回调里用它。
static inline uint64_t sw_rt_now(void) SW_NONBLOCKING {
    typedef uint64_t (*fn)(void) SW_NONBLOCKING;
    return ((fn)mach_absolute_time)();
}

/// pthread_self：读线程自身结构（TSD），不进内核、不分配。
static inline uintptr_t sw_rt_thread_id(void) SW_NONBLOCKING {
    typedef pthread_t (*fn)(void) SW_NONBLOCKING;
    return (uintptr_t)((fn)pthread_self)();
}

/// libsamplerate 0.2.2 src_callback_read：只调 src_process → sinc_*_vari_process → prepare_data（memcpy / memmove）。
/// 分配只发生在 src_new / src_callback_new / src_clone（Host target 调）。审计：src/samplerate.c、src/src_sinc.c 通读，
/// 无 malloc / 锁 / IO；assert 只在调试构建且只在内部不变量被破坏时触发。
static inline long sw_rt_src_callback_read(SRC_STATE *state, double ratio, long frames, float *out) SW_NONBLOCKING {
    typedef long (*fn)(SRC_STATE *, double, long, float *) SW_NONBLOCKING;
    return ((fn)src_callback_read)(state, ratio, frames, out);
}
/// src_reset：memset 内部缓冲，无分配。
static inline int sw_rt_src_reset(SRC_STATE *state) SW_NONBLOCKING {
    typedef int (*fn)(SRC_STATE *) SW_NONBLOCKING;
    return ((fn)src_reset)(state);
}

/// libebur128 1.2.6，仅在 EBUR128_MODE_HISTOGRAM 下审计通过：
/// add_frames_float → filter（双二阶）+ 真峰值插值（缓冲在 ebur128_init 预分配，容量 = samples_in_100ms × 4）
/// + calc_gating_block（直方图模式只做 ++histogram[idx]；非直方图模式会 malloc 链表节点，所以禁用）。
/// loudness_momentary / shortterm：对 audio_data 求和；loudness_global：遍历 1000 个直方图桶；
/// loudness_range：直方图模式走栈上 unsigned long hist[1000]（8 KB 栈），无 malloc；prev_*_peak：读数组。
static inline int sw_rt_ebur128_add_frames_float(ebur128_state *st, const float *src, size_t frames) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, const float *, size_t) SW_NONBLOCKING;
    return ((fn)ebur128_add_frames_float)(st, src, frames);
}
static inline int sw_rt_ebur128_loudness_momentary(ebur128_state *st, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, double *) SW_NONBLOCKING;
    return ((fn)ebur128_loudness_momentary)(st, out);
}
static inline int sw_rt_ebur128_loudness_shortterm(ebur128_state *st, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, double *) SW_NONBLOCKING;
    return ((fn)ebur128_loudness_shortterm)(st, out);
}
static inline int sw_rt_ebur128_loudness_global(ebur128_state *st, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, double *) SW_NONBLOCKING;
    return ((fn)ebur128_loudness_global)(st, out);
}
static inline int sw_rt_ebur128_loudness_range(ebur128_state *st, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, double *) SW_NONBLOCKING;
    return ((fn)ebur128_loudness_range)(st, out);
}
static inline int sw_rt_ebur128_prev_sample_peak(ebur128_state *st, unsigned int ch, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, unsigned int, double *) SW_NONBLOCKING;
    return ((fn)ebur128_prev_sample_peak)(st, ch, out);
}
static inline int sw_rt_ebur128_prev_true_peak(ebur128_state *st, unsigned int ch, double *out) SW_NONBLOCKING {
    typedef int (*fn)(ebur128_state *, unsigned int, double *) SW_NONBLOCKING;
    return ((fn)ebur128_prev_true_peak)(st, ch, out);
}

/// AudioUnitRender（AudioToolbox）：苹果自带效果 AU 在已 initialize、格式与 MaximumFramesPerSlice 固定、
/// 运行期不改属性的前提下，render 就是为 IOProc 线程设计的（所有宿主都这么做）。
/// 注意事项见 reports/w1-audio.md：输入回调是 C 函数、同一线程同步调用；时间戳要带 mSampleTime；
/// 不能与 AudioUnitUninitialize / 属性设置并发。
static inline OSStatus sw_rt_audio_unit_render(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                               const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                                               AudioBufferList *list) SW_NONBLOCKING {
    typedef OSStatus (*fn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32,
                           AudioBufferList *) SW_NONBLOCKING;
    return ((fn)AudioUnitRender)(unit, flags, ts, bus, frames, list);
}

#ifdef __cplusplus
}
#endif
#endif /* SW_RT_EXTERN_H */
