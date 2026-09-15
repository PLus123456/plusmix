// sw_audio_ring_host.c —— 音频环的分配 / 释放（非实时）。
#include "sw_audio_host.h"
#include <stdlib.h>
#include <string.h>

static uint32_t sw_pow2_ceil(uint32_t v) {
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

sw_audio_ring *sw_audio_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t stamp_capacity) {
    if (channels < 1 || channels > SW_AUDIO_MAX_CHANNELS) return NULL;
    capacity_frames = sw_pow2_ceil(capacity_frames);
    stamp_capacity = sw_pow2_ceil(stamp_capacity);
    void *raw = NULL;
    // 环头 64 字节对齐：生产者 / 消费者计数各占一条缓存线（契约规则 5）
    if (posix_memalign(&raw, 64, sizeof(sw_audio_ring)) != 0 || raw == NULL) return NULL;
    sw_audio_ring *ring = (sw_audio_ring *)raw;
    memset(ring, 0, sizeof(*ring));
    ring->layout_version = SW_AUDIO_RING_LAYOUT_VERSION;
    ring->channels = channels;
    ring->sample_rate = SW_AUDIO_SAMPLE_RATE;
    ring->capacity_frames = capacity_frames;
    ring->stamp_capacity = stamp_capacity;
    for (uint32_t c = 0; c < channels; c++) {
        ring->planes[c] = (float *)calloc(capacity_frames, sizeof(float));
        if (!ring->planes[c]) { sw_audio_ring_destroy(ring); return NULL; }
    }
    ring->stamps = (sw_audio_stamp *)calloc(stamp_capacity, sizeof(sw_audio_stamp));
    if (!ring->stamps) { sw_audio_ring_destroy(ring); return NULL; }
    return ring;
}

void sw_audio_ring_destroy(sw_audio_ring *ring) {
    if (!ring) return;
    for (uint32_t c = 0; c < SW_AUDIO_MAX_CHANNELS; c++) free(ring->planes[c]);
    free(ring->stamps);
    free(ring);
}
