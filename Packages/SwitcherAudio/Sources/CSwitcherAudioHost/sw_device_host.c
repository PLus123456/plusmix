// sw_device_host.c —— IOProc 客户端的创建 / 配置，与"空输出设备"驱动（timer 驱动的假设备时钟；CI 无声卡也能跑）。
#include "sw_audio_host.h"
#include "sw_device_internal.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>

// ---------------------------------------------------------------------------
// IOProc 客户端
// ---------------------------------------------------------------------------

sw_device_client *sw_device_client_create(sw_mix_ctx *ctx, uint32_t max_block_frames) {
    sw_device_client *c = (sw_device_client *)calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->ctx = ctx;
    c->max_block = max_block_frames ? max_block_frames : SW_MIX_MAX_BLOCK_FRAMES;
    for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) {
        c->out_map[k] = -1;
        c->out_scratch[k] = (float *)calloc(c->max_block, sizeof(float));
        if (!c->out_scratch[k]) { sw_device_client_destroy(c); return NULL; }
    }
    for (uint32_t ch = 0; ch < SW_AUDIO_MAX_CHANNELS; ch++) {
        c->in_map[ch] = -1;
        c->in_scratch[ch] = (float *)calloc(c->max_block, sizeof(float));
        if (!c->in_scratch[ch]) { sw_device_client_destroy(c); return NULL; }
    }
    c->out_zero_unmapped = 1;
    return c;
}

void sw_device_client_destroy(sw_device_client *c) {
    if (!c) return;
    for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) free(c->out_scratch[k]);
    for (uint32_t ch = 0; ch < SW_AUDIO_MAX_CHANNELS; ch++) free(c->in_scratch[ch]);
    free(c);
}

void sw_device_client_set_output_layout(sw_device_client *c, const sw_channel_location *locs, uint32_t count) {
    if (count > SW_DEVICE_MAX_CHANNELS) count = SW_DEVICE_MAX_CHANNELS;
    memcpy(c->out_layout, locs, count * sizeof(*locs));
    c->out_channel_count = count;
}
void sw_device_client_set_output_map(sw_device_client *c, const int32_t *map8) {
    for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) c->out_map[k] = map8[k];
}
void sw_device_client_set_input_layout(sw_device_client *c, const sw_channel_location *locs, uint32_t count) {
    if (count > SW_DEVICE_MAX_CHANNELS) count = SW_DEVICE_MAX_CHANNELS;
    memcpy(c->in_layout, locs, count * sizeof(*locs));
    c->in_channel_count = count;
}
void sw_device_client_set_input_map(sw_device_client *c, const int32_t *map, uint32_t count) {
    for (uint32_t ch = 0; ch < SW_AUDIO_MAX_CHANNELS; ch++) c->in_map[ch] = ch < count ? map[ch] : -1;
}
void sw_device_client_set_input_ring(sw_device_client *c, sw_audio_ring *ring) {
    __atomic_store_n(&c->in_ring, ring, __ATOMIC_RELEASE);
}
void sw_device_client_copy_stats(const sw_device_client *c, sw_device_client_stats *out) { *out = c->st; }
void sw_device_client_reset_stats(sw_device_client *c) { memset(&c->st, 0, sizeof c->st); c->last_entry = 0; }

// ---------------------------------------------------------------------------
// 空输出设备：一个 time-constraint 线程按块周期 mach_wait_until，调 sw_mix_block（host_time = 名义块时刻）
// ---------------------------------------------------------------------------

struct sw_null_driver {
    sw_mix_ctx *ctx;
    uint32_t block_frames;
    uint64_t period_ticks;
    float *scratch[SW_DEVICE_OUT_LOGICAL];
    pthread_t thread;
    uint32_t running;          ///< 原子
    uint32_t started;
    sw_null_driver_stats st;   ///< RT 写
};

sw_null_driver *sw_null_driver_create(sw_mix_ctx *ctx, uint32_t block_frames) {
    if (!ctx || block_frames == 0) return NULL;
    sw_null_driver *d = (sw_null_driver *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->ctx = ctx;
    d->block_frames = block_frames;
    d->period_ticks = (uint64_t)((double)block_frames * sw_mix_ctx_host_ticks_per_frame(ctx) + 0.5);
    for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) {
        d->scratch[k] = (float *)calloc(block_frames, sizeof(float));
        if (!d->scratch[k]) { sw_null_driver_destroy(d); return NULL; }
    }
    return d;
}

void sw_null_driver_destroy(sw_null_driver *d) {
    if (!d) return;
    sw_null_driver_stop(d);
    for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) free(d->scratch[k]);
    free(d);
}

static void *sw_null_driver_thread(void *arg) {
    sw_null_driver *d = (sw_null_driver *)arg;
    // 与 CoreAudio 的 IO 线程同类的调度：time-constraint，周期 = 块周期，计算 1/4，约束 1/2
    thread_time_constraint_policy_data_t pol;
    pol.period = (uint32_t)d->period_ticks;
    pol.computation = (uint32_t)(d->period_ticks / 4);
    pol.constraint = (uint32_t)(d->period_ticks / 2);
    pol.preemptible = 1;
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    uint64_t next = mach_absolute_time() + d->period_ticks;
    while (__atomic_load_n(&d->running, __ATOMIC_ACQUIRE)) {
        mach_wait_until(next);
        const uint64_t entry = mach_absolute_time();
        const uint64_t late = entry > next ? entry - next : 0;
        if (late > d->st.max_wake_late_ticks) d->st.max_wake_late_ticks = late;
        uint64_t bucket = (uint64_t)((double)late / (sw_mix_ctx_host_ticks_per_frame(d->ctx) * 4.8));
        if (bucket > 31) bucket = 31;
        d->st.wake_hist[bucket]++;
        sw_mix_block(d->ctx, d->scratch, d->block_frames, next);
        d->st.blocks++;
        // 落后超过一个周期（被抢占太久）：跳过缺的块，重新对齐，记一次
        next += d->period_ticks;
        const uint64_t now2 = mach_absolute_time();
        if (now2 > next + d->period_ticks) {
            const uint64_t skipped = (now2 - next) / d->period_ticks;
            d->st.skipped_blocks += skipped;
            next += skipped * d->period_ticks;
        }
    }
    return NULL;
}

int sw_null_driver_start(sw_null_driver *d) {
    if (!d || d->started) return -1;
    sw_mix_ctx_set_timing_check(d->ctx, true);
    __atomic_store_n(&d->running, 1u, __ATOMIC_RELEASE);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    int rc = pthread_create(&d->thread, &attr, sw_null_driver_thread, d);
    pthread_attr_destroy(&attr);
    if (rc != 0) { __atomic_store_n(&d->running, 0u, __ATOMIC_RELEASE); return rc; }
    d->started = 1;
    return 0;
}

void sw_null_driver_stop(sw_null_driver *d) {
    if (!d || !d->started) return;
    __atomic_store_n(&d->running, 0u, __ATOMIC_RELEASE);
    pthread_join(d->thread, NULL);
    d->started = 0;
}

void sw_null_driver_copy_stats(const sw_null_driver *d, sw_null_driver_stats *out) { *out = d->st; }
uint64_t sw_null_driver_period_ticks(const sw_null_driver *d) { return d->period_ticks; }
