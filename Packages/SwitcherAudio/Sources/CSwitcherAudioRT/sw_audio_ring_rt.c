// sw_audio_ring_rt.c —— 音频环的实时侧实现（契约 sw_audio_ring.h 的布局；分配在 Host target）。
//
// SPSC 内存序（契约规则 4）：
//   生产者：写平面 → 写 stamp → release 发布 stamp_write → release 发布 write_index。
//   消费者：acquire 读 write_index（此后 stamp 与平面对它可见）→ 读平面 → release 发布 read_index。
//   生产者算空位时 acquire 读 read_index。
// 计数字段都是 64 位累计值，位置 = index & (capacity - 1)。
#include "sw_audio_rt.h"
#include <string.h>
#include "sw_rt_pragma.h"

static inline void sw_ring_copy_in(float *plane, uint32_t cap, uint32_t pos, const float *src, uint32_t n) SW_NONBLOCKING {
    uint32_t first = cap - pos;
    if (first > n) first = n;
    memcpy(plane + pos, src, (size_t)first * sizeof(float));
    if (n > first) memcpy(plane, src + first, (size_t)(n - first) * sizeof(float));
}

static inline void sw_ring_copy_out(const float *plane, uint32_t cap, uint32_t pos, float *dst, uint32_t n) SW_NONBLOCKING {
    uint32_t first = cap - pos;
    if (first > n) first = n;
    memcpy(dst, plane + pos, (size_t)first * sizeof(float));
    if (n > first) memcpy(dst + first, plane, (size_t)(n - first) * sizeof(float));
}

uint32_t sw_audio_ring_write(sw_audio_ring *ring, const float *const *planes, uint32_t frames, uint64_t host_time) SW_NONBLOCKING {
    const uint32_t cap = ring->capacity_frames;
    const uint64_t w = ring->write_index;                                   // 只有本线程写它
    const uint64_t r = __atomic_load_n(&ring->read_index, __ATOMIC_ACQUIRE);
    const uint64_t free_frames = (uint64_t)cap - (w - r);
    uint32_t n = frames;
    if ((uint64_t)n > free_frames) n = (uint32_t)free_frames;
    if (n < frames) ring->overruns += (uint64_t)(frames - n);               // 单写者，普通写即可
    if (n == 0) return 0;

    const uint32_t pos = (uint32_t)(w & (uint64_t)(cap - 1u));
    for (uint32_t c = 0; c < ring->channels; c++) {
        sw_ring_copy_in(ring->planes[c], cap, pos, planes[c], n);
    }
    // stamp 先于 write_index 发布（契约）
    const uint64_t sw = ring->stamp_write;
    sw_audio_stamp *s = &ring->stamps[sw & (uint64_t)(ring->stamp_capacity - 1u)];
    s->frame_index = w;
    s->host_time = host_time;
    __atomic_store_n(&ring->stamp_write, sw + 1u, __ATOMIC_RELEASE);
    __atomic_store_n(&ring->write_index, w + (uint64_t)n, __ATOMIC_RELEASE);
    return n;
}

bool sw_audio_ring_stamp_from_latest(const sw_audio_ring *ring, uint32_t n, sw_audio_stamp *out) SW_NONBLOCKING {
    const uint64_t sw = __atomic_load_n(&ring->stamp_write, __ATOMIC_ACQUIRE);
    // 最新的 (stamp_capacity - 1) 条是安全的：生产者此刻最多在写 (sw & mask) 那一条
    if ((uint64_t)n + 1u > sw) return false;
    if (n + 1u >= ring->stamp_capacity) return false;
    const sw_audio_stamp *s = &ring->stamps[(sw - 1u - (uint64_t)n) & (uint64_t)(ring->stamp_capacity - 1u)];
    out->frame_index = s->frame_index;
    out->host_time = s->host_time;
    return true;
}

bool sw_audio_ring_latest_stamp(const sw_audio_ring *ring, sw_audio_stamp *out) SW_NONBLOCKING {
    return sw_audio_ring_stamp_from_latest(ring, 0, out);
}

bool sw_audio_ring_host_time_of(const sw_audio_ring *ring, uint64_t frame_index, double host_ticks_per_frame,
                                uint64_t *out) SW_NONBLOCKING {
    // 从最新往回找第一条 frame_index ≤ 目标的 stamp（stamps 的 frame_index 单调递增），再按每帧 tick 数外推
    const uint64_t sw = __atomic_load_n(&ring->stamp_write, __ATOMIC_ACQUIRE);
    uint64_t scan = sw;
    if (scan > (uint64_t)ring->stamp_capacity - 1u) scan = (uint64_t)ring->stamp_capacity - 1u;
    for (uint64_t i = 0; i < scan; i++) {
        const sw_audio_stamp *s = &ring->stamps[(sw - 1u - i) & (uint64_t)(ring->stamp_capacity - 1u)];
        if (s->frame_index <= frame_index) {
            const double delta = (double)(frame_index - s->frame_index) * host_ticks_per_frame;
            *out = s->host_time + (uint64_t)(delta + 0.5);
            return true;
        }
    }
    return false;
}

uint32_t sw_audio_ring_read(sw_audio_ring *ring, float *const *planes, uint32_t frames, double host_ticks_per_frame,
                            uint64_t *first_host_time, bool *first_valid) SW_NONBLOCKING {
    const uint32_t cap = ring->capacity_frames;
    const uint64_t r = ring->read_index;                                    // 只有本线程写它
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    const uint64_t avail = w - r;
    uint32_t n = frames;
    if ((uint64_t)n > avail) n = (uint32_t)avail;

    const uint32_t pos = (uint32_t)(r & (uint64_t)(cap - 1u));
    for (uint32_t c = 0; c < ring->channels; c++) {
        if (n) sw_ring_copy_out(ring->planes[c], cap, pos, planes[c], n);
        if (n < frames) memset(planes[c] + n, 0, (size_t)(frames - n) * sizeof(float));
    }
    if (n < frames) ring->underruns += (uint64_t)(frames - n);

    bool valid = false;
    uint64_t t = 0;
    if (n > 0) valid = sw_audio_ring_host_time_of(ring, r, host_ticks_per_frame, &t);
    if (first_host_time) *first_host_time = t;
    if (first_valid) *first_valid = valid;

    if (n) __atomic_store_n(&ring->read_index, r + (uint64_t)n, __ATOMIC_RELEASE);
    return n;
}

uint32_t sw_audio_ring_skip(sw_audio_ring *ring, uint32_t frames) SW_NONBLOCKING {
    const uint64_t r = ring->read_index;
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    uint64_t n = frames;
    if (n > w - r) n = w - r;
    if (n) __atomic_store_n(&ring->read_index, r + n, __ATOMIC_RELEASE);
    return (uint32_t)n;
}
