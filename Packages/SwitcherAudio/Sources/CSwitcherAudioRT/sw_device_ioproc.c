// sw_device_ioproc.c —— CoreAudio HAL 的 IOProc（实时线程）。
//
// W1-D 探针（macOS 26.6、内置扬声器）：1 个 buffer 2 声道交错；AudioTimeStamp 标志 0x7（Sample / Host / RateScalar 都有效）；
// inOutputTime.mHostTime 比回调进入时刻早约 buffer + safety offset（256 + 48 帧 ≈ 6.3 ms）；buffer size 可设 15…4096。
#include "sw_device_internal.h"
#include "sw_rt_extern.h"
#include <string.h>
#include "sw_rt_pragma.h"

static inline uint32_t sw_abl_frames(const AudioBufferList *abl) SW_NONBLOCKING {
    if (!abl || abl->mNumberBuffers == 0) return 0;
    const AudioBuffer *b = &abl->mBuffers[0];
    const uint32_t ch = b->mNumberChannels ? b->mNumberChannels : 1;
    return b->mDataByteSize / (ch * (uint32_t)sizeof(float));
}

static inline uint64_t sw_ts_host(const AudioTimeStamp *ts, uint64_t fallback, uint64_t *fallbacks) SW_NONBLOCKING {
    if (ts && (ts->mFlags & kAudioTimeStampHostTimeValid)) return ts->mHostTime;
    (*fallbacks)++;
    return fallback;
}

OSStatus sw_device_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now, const AudioBufferList *_Nonnull input,
                          const AudioTimeStamp *_Nonnull input_time, AudioBufferList *_Nonnull output,
                          const AudioTimeStamp *_Nonnull output_time, void *_Nullable client_ptr) SW_NONBLOCKING {
    (void)device;
    sw_device_client *c = (sw_device_client *)client_ptr;
    const uint64_t entry = sw_rt_now();
    sw_device_client_stats *st = &c->st;

    // ---- 输入 → 环 ----
    sw_audio_ring *ring = __atomic_load_n(&c->in_ring, __ATOMIC_ACQUIRE);
    if (ring && input && input->mNumberBuffers > 0) {
        uint32_t frames = sw_abl_frames(input);
        if (frames > c->max_block) frames = c->max_block;
        for (uint32_t ch = 0; ch < ring->channels; ch++) {
            const int32_t dev_ch = c->in_map[ch];
            float *dst = c->in_scratch[ch];
            if (dev_ch < 0 || (uint32_t)dev_ch >= c->in_channel_count) { memset(dst, 0, (size_t)frames * sizeof(float)); continue; }
            const sw_channel_location loc = c->in_layout[dev_ch];
            if (loc.buffer >= input->mNumberBuffers) { memset(dst, 0, (size_t)frames * sizeof(float)); continue; }
            const float *src = (const float *)input->mBuffers[loc.buffer].mData + loc.offset;
            const uint32_t stride = loc.stride ? loc.stride : 1;
            for (uint32_t i = 0; i < frames; i++) dst[i] = src[i * stride];
        }
        const uint64_t t = sw_ts_host(input_time, entry, &st->timestamp_fallbacks);
        const float *const *planes = (const float *const *)c->in_scratch;
        const uint32_t wrote = sw_audio_ring_write(ring, planes, frames, t);
        st->input_frames_written += wrote;
        if (wrote < frames) st->input_overruns += frames - wrote;
    }

    // ---- 混音 → 输出 ----
    if (c->ctx && output && output->mNumberBuffers > 0) {
        uint32_t frames = sw_abl_frames(output);
        if (frames > c->max_block) frames = c->max_block;
        const uint64_t t = sw_ts_host(output_time, entry, &st->timestamp_fallbacks);
        sw_mix_block(c->ctx, c->out_scratch, frames, t);
        // 散到设备布局
        for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) {
            const int32_t dev_ch = c->out_map[k];
            if (dev_ch < 0 || (uint32_t)dev_ch >= c->out_channel_count) continue;
            const sw_channel_location loc = c->out_layout[dev_ch];
            if (loc.buffer >= output->mNumberBuffers) continue;
            float *dst = (float *)output->mBuffers[loc.buffer].mData + loc.offset;
            const uint32_t stride = loc.stride ? loc.stride : 1;
            const float *src = c->out_scratch[k];
            for (uint32_t i = 0; i < frames; i++) dst[i * stride] = src[i];
        }
        if (c->out_zero_unmapped) {
            for (uint32_t dev_ch = 0; dev_ch < c->out_channel_count; dev_ch++) {
                int mapped = 0;
                for (uint32_t k = 0; k < SW_DEVICE_OUT_LOGICAL; k++) if (c->out_map[k] == (int32_t)dev_ch) { mapped = 1; break; }
                if (mapped) continue;
                const sw_channel_location loc = c->out_layout[dev_ch];
                if (loc.buffer >= output->mNumberBuffers) continue;
                float *dst = (float *)output->mBuffers[loc.buffer].mData + loc.offset;
                const uint32_t stride = loc.stride ? loc.stride : 1;
                for (uint32_t i = 0; i < frames; i++) dst[i * stride] = 0.0f;
            }
        }
        // 统计：帧数、周期抖动、提前量
        st->frames += frames;
        st->last_frames = frames;
        const double tpf = c->ctx ? sw_mix_ctx_host_ticks_per_frame_rt(c->ctx) : 0.0;
        const uint64_t nominal = (uint64_t)((double)frames * tpf + 0.5);
        st->nominal_period_ticks = nominal;
        if (c->last_entry) {
            const uint64_t delta = entry - c->last_entry;
            const uint64_t jitter = delta > nominal ? delta - nominal : nominal - delta;
            if (jitter > st->max_jitter_ticks) st->max_jitter_ticks = jitter;
            uint64_t bucket = (uint64_t)((double)jitter / (tpf * 4.8));   // 100 µs = 4.8 帧
            if (bucket > 31) bucket = 31;
            st->jitter_hist[bucket]++;
        }
        if (t > entry) {
            const uint64_t lead = t - entry;
            if (lead > st->max_lead_ticks) st->max_lead_ticks = lead;
            if (st->min_lead_ticks == 0 || lead < st->min_lead_ticks) st->min_lead_ticks = lead;
        }
    }
    c->last_entry = entry;
    st->callbacks++;
    (void)now;
    return noErr;
}
