// sw_mix.c —— 混音块（热路径）。设计方案 §3.5 / §3.6 / §7；W1-D。
//
// 每块的顺序（sw_mix_block）：
//   命令 → 对每路输入：环取样 + 异步重采样（比率来自速率估计器）→ 延迟线 → 增益 / 静音 / AFV / 声像 → 送四条总线
//   → 对每条总线：效果链（AudioUnitRender）→ 总线增益 / 静音 → 表 → 写输出 → 消费者队列。
//
// 速率估计器（每路一个；prompt 第 4 条）：
//   控制量 = "重采样器当前输入位置的年龄"（帧）：age = (块首样本 host time − 该位置对应帧的 host time) / 每帧 tick，
//   位置 input_pos 按 frames / ratio 积分（与 libsamplerate 内部 input_index += 1/ratio 同一件事），并钳到
//   [handed − hf − chunk, handed − hf]（hf = sinc 半长；libsamplerate 只在手里 ≤ hf 帧时才取下一段 chunk）。
//   用它而不用原始环占用，原因有二：
//   (1) 输入按块到达、输出按块消费，两个块时钟相差 ±100 ppm 时原始占用是周期几十秒的方波（相位拍频），PI 会去追它；
//   (2) 环的 read 位置（handed）按 chunk 量化，用它算的年龄有周期几秒的锯齿（幅度 = chunk），PI 也会去追。
//   年龄由 stamp 外推 + 连续位置，是平滑量。设定点 = 就绪那一刻的年龄（此时环里正好 target + hf + chunk/2 帧），
//   所以稳态下环里的原始占用平均 ≈ target_frames，波动 ±生产者块 / 2（相位）。
//   前馈 ratio_ff = 输出速率 / 输入速率，两者都是"帧 / host tick"：输入用 stamps（帧序号 vs host time），
//   输出用块的 host time；每 rate_window_s 测一次，一阶低通 rate_tau_s（第一次测到直接采用）。
//   PI：ratio = ratio_ff − (kp·e + ki·∫e)，e = 低通后的年龄 − 设定点，kp = 2ζωn / fs，ki = ωn² / fs，
//   ζ = 1（临界阻尼）、ωn = 1 / loop_tau_s。限幅 ±max_deviation（默认 ±0.1%），限幅时不积分。
//   时间常数取值理由见报告"估计器参数"。
#include "sw_mix_internal.h"
#include "sw_rt_extern.h"
#include <string.h>
#include <math.h>
#include "sw_rt_pragma.h"

#define SW_GAIN_SMOOTH_TAU_S   0.003   ///< 增益 / AFV 目标的一阶平滑时间常数（3 ms：无 zipper 噪声，21 ms 内到 0.1%）
#define SW_PAN_SMOOTH_PER_BLOCK 0.3f   ///< 声像每块向目标走 30%
#define SW_STALL_BLOCKS_LIMIT  190u    ///< write_index 连续 ~1 s（190 × 5.3 ms）没动 → 视为源停了，回到未就绪
#define SW_PI_F 3.14159265358979323846f
#define SW_INPUT_TAP_BASE 16

// ---------------------------------------------------------------------------
// 命令队列（实时侧：消费者）
// ---------------------------------------------------------------------------

static inline bool sw_cmd_pop(sw_cmd_queue *q, sw_cmd *out) SW_NONBLOCKING {
    const uint64_t head = q->head;
    const uint64_t tail = __atomic_load_n(&q->tail, __ATOMIC_ACQUIRE);
    if (head == tail) return false;
    *out = q->cmds[head & (SW_MIX_CMD_CAPACITY - 1u)];
    __atomic_store_n(&q->head, head + 1u, __ATOMIC_RELEASE);
    return true;
}

// ---------------------------------------------------------------------------
// 块队列（实时侧：生产者；消费者侧也在这里，都无锁）
// ---------------------------------------------------------------------------

bool sw_block_queue_push(sw_block_queue *q, const float *const *planes, uint32_t channels, uint32_t frames,
                         uint64_t host_time, uint64_t sequence) SW_NONBLOCKING {
    const uint64_t w = q->write;
    const uint64_t r = __atomic_load_n(&q->read, __ATOMIC_ACQUIRE);
    if (w - r >= (uint64_t)q->capacity) { __atomic_store_n(&q->dropped, q->dropped + 1u, __ATOMIC_RELAXED); return false; }
    if (frames > q->max_frames) frames = q->max_frames;
    const uint32_t idx = (uint32_t)(w & (uint64_t)q->mask);
    float *dst = q->data + (size_t)idx * q->channels * q->max_frames;
    for (uint32_t c = 0; c < q->channels; c++) {
        const float *src = (c < channels) ? planes[c] : NULL;
        if (src) memcpy(dst + (size_t)c * q->max_frames, src, (size_t)frames * sizeof(float));
        else memset(dst + (size_t)c * q->max_frames, 0, (size_t)frames * sizeof(float));
    }
    q->frames[idx] = frames;
    q->host_times[idx] = host_time;
    q->sequences[idx] = sequence;
    __atomic_store_n(&q->write, w + 1u, __ATOMIC_RELEASE);
    return true;
}

bool sw_block_queue_pop(sw_block_queue *q, float *const *planes, uint32_t *frames, uint64_t *host_time,
                        uint64_t *sequence) SW_NONBLOCKING {
    const uint64_t r = q->read;
    const uint64_t w = __atomic_load_n(&q->write, __ATOMIC_ACQUIRE);
    if (r == w) return false;
    const uint32_t idx = (uint32_t)(r & (uint64_t)q->mask);
    const uint32_t n = q->frames[idx];
    const float *src = q->data + (size_t)idx * q->channels * q->max_frames;
    for (uint32_t c = 0; c < q->channels; c++) {
        if (planes[c]) memcpy(planes[c], src + (size_t)c * q->max_frames, (size_t)n * sizeof(float));
    }
    if (frames) *frames = n;
    if (host_time) *host_time = q->host_times[idx];
    if (sequence) *sequence = q->sequences[idx];
    __atomic_store_n(&q->read, r + 1u, __ATOMIC_RELEASE);
    return true;
}

uint32_t sw_block_queue_count(const sw_block_queue *q) SW_NONBLOCKING {
    const uint64_t w = __atomic_load_n(&q->write, __ATOMIC_ACQUIRE);
    const uint64_t r = __atomic_load_n(&q->read, __ATOMIC_ACQUIRE);
    return (uint32_t)(w - r);
}
uint64_t sw_block_queue_dropped(const sw_block_queue *q) SW_NONBLOCKING { return __atomic_load_n(&q->dropped, __ATOMIC_RELAXED); }
uint32_t sw_block_queue_channels(const sw_block_queue *q) SW_NONBLOCKING { return q->channels; }
uint32_t sw_block_queue_max_frames(const sw_block_queue *q) SW_NONBLOCKING { return q->max_frames; }

// ---------------------------------------------------------------------------
// 延迟线
// ---------------------------------------------------------------------------

static inline void sw_delay_process(sw_delay_line *d, uint32_t channels, float *const *in, float *const *out,
                                    uint32_t frames) SW_NONBLOCKING {
    const uint32_t mask = d->mask;
    const uint32_t delay = d->delay_frames;
    for (uint32_t c = 0; c < channels; c++) {
        float *buf = d->buf[c];
        uint32_t wp = d->write_pos;
        const float *x = in[c];
        float *y = out[c];
        for (uint32_t i = 0; i < frames; i++) {
            buf[wp & mask] = x[i];
            y[i] = buf[(wp - delay) & mask];
            wp++;
        }
    }
    d->write_pos += frames;
}

// ---------------------------------------------------------------------------
// 重采样器的取样回调：把环里下一段连续数据交给 libsamplerate；环空则交零块
// （不许返回 0：src_callback_read 会把 end_of_input 传给 sinc，进入终止态直到 src_reset）
// ---------------------------------------------------------------------------

long sw_input_pull(void *cb_data, float **data) SW_NONBLOCKING {
    sw_pull_ctx *pc = (sw_pull_ctx *)cb_data;
    sw_input_slot *slot = pc->slot;
    sw_audio_ring *ring = slot->ring;
    // libsamplerate 只在上一段吃完后才再要数据 → 上一段确认消费
    pc->handed += pc->pending;
    pc->pending = 0;
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    const uint64_t avail = w - pc->handed;
    uint32_t n = slot->chunk_frames;
    if (avail == 0) {
        *data = (float *)slot->zeros;
        if (pc->channel == 0) slot->underrun_frames_block += n;
        return (long)n;
    }
    if ((uint64_t)n > avail) n = (uint32_t)avail;
    const uint32_t pos = (uint32_t)(pc->handed & (uint64_t)slot->ring_mask);
    const uint32_t to_end = slot->ring_mask + 1u - pos;
    if (n > to_end) n = to_end;
    *data = ring->planes[pc->channel] + pos;
    pc->pending = n;
    return (long)n;
}

// ---------------------------------------------------------------------------
// AU 输入回调：把当前效果格的输入指针交给 AU（mData 为 NULL 时给指针，否则拷贝）
// ---------------------------------------------------------------------------

OSStatus sw_effect_input_proc(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 bus, UInt32 frames, AudioBufferList *ioData) SW_NONBLOCKING {
    (void)flags; (void)ts; (void)bus;
    sw_effect_slot *fx = (sw_effect_slot *)refCon;
    const UInt32 nbuf = ioData->mNumberBuffers < SW_MIX_BUS_CHANNELS ? ioData->mNumberBuffers : SW_MIX_BUS_CHANNELS;
    if (frames > fx->in_frames) frames = fx->in_frames;
    for (UInt32 c = 0; c < nbuf; c++) {
        AudioBuffer *b = &ioData->mBuffers[c];
        const size_t bytes = (size_t)frames * sizeof(float);
        if (b->mData == NULL) {
            b->mData = (void *)fx->in[c];
        } else {
            memcpy(b->mData, fx->in[c], bytes);
        }
        b->mDataByteSize = (UInt32)bytes;
        b->mNumberChannels = 1;
    }
    return noErr;
}

// ---------------------------------------------------------------------------
// 命令应用
// ---------------------------------------------------------------------------

static inline float sw_clampf(float v, float lo, float hi) SW_NONBLOCKING { return v < lo ? lo : (v > hi ? hi : v); }

static void sw_rate_reset(sw_rate_state *r) SW_NONBLOCKING {
    r->level_filt = 0; r->integ = 0; r->ratio = 1.0; r->have_level = 0; r->win_valid = 0;
    r->age_setpoint = 0; r->producer_block = 0;
}

static void sw_slot_unprime(sw_input_slot *slot) SW_NONBLOCKING {
    slot->primed = 0;
    slot->stall_blocks = 0;
    sw_rate_reset(&slot->rate);
}

static void sw_slot_attach(struct sw_mix_ctx *ctx, sw_input_slot *slot, sw_audio_ring *ring, uint32_t mode, uint32_t target) SW_NONBLOCKING {
    slot->ring = ring;
    slot->channels = ring->channels >= 2u ? 2u : 1u;
    slot->ring_mask = ring->capacity_frames - 1u;
    slot->resample_mode = mode;
    slot->target_frames = target ? target : ctx->rate_defaults.target_frames;
    if (slot->target_frames > ring->capacity_frames / 2u) slot->target_frames = ring->capacity_frames / 2u;
    slot->attached = 1;
    slot->last_write_index = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    slot->rate.ratio_ff = 1.0;
    slot->rate.have_ff = 0;
    sw_slot_unprime(slot);
    slot->st.underrun_blocks = 0;
    slot->st.reprimes = 0;
    slot->st.frames_consumed = 0;
    slot->st.frames_output = 0;
}

static void sw_apply_command(struct sw_mix_ctx *ctx, const sw_cmd *c) SW_NONBLOCKING {
    const uint32_t idx = (uint32_t)c->index;
    switch (c->type) {
    case SW_CMD_ATTACH_INPUT:
        if (idx < ctx->input_capacity && c->ptr) sw_slot_attach(ctx, &ctx->inputs[idx], (sw_audio_ring *)c->ptr, (uint32_t)c->i0, (uint32_t)c->i1);
        break;
    case SW_CMD_DETACH_INPUT:
        if (idx < ctx->input_capacity) {
            sw_input_slot *s = &ctx->inputs[idx];
            s->attached = 0; s->primed = 0;
            __atomic_store_n(&s->ring, (sw_audio_ring *)NULL, __ATOMIC_RELEASE);
            for (int k = 0; k < (int)SW_MIX_MAX_CROSSFADES; k++) {
                if (ctx->xfades[k].from == (int32_t)idx) ctx->xfades[k].from = -1;
                if (ctx->xfades[k].to == (int32_t)idx) ctx->xfades[k].to = -1;
            }
        }
        break;
    case SW_CMD_INPUT_GAIN:    if (idx < ctx->input_capacity) ctx->inputs[idx].gain_target = c->f0 < 0 ? 0 : c->f0; break;
    case SW_CMD_INPUT_MUTE:    if (idx < ctx->input_capacity) ctx->inputs[idx].muted = c->i0 != 0; break;
    case SW_CMD_INPUT_SOLO:    if (idx < ctx->input_capacity) ctx->inputs[idx].solo = c->i0 != 0; break;
    case SW_CMD_INPUT_PAN:     if (idx < ctx->input_capacity) ctx->inputs[idx].pan_target = sw_clampf(c->f0, -1, 1); break;
    case SW_CMD_INPUT_ROUTING: if (idx < ctx->input_capacity) ctx->inputs[idx].routing = (uint32_t)c->i0; break;
    case SW_CMD_INPUT_DELAY:
        if (idx < ctx->input_capacity) {
            uint32_t d = c->i0 < 0 ? 0 : (uint32_t)c->i0;
            if (d > SW_MIX_MAX_DELAY_FRAMES) d = SW_MIX_MAX_DELAY_FRAMES;
            ctx->inputs[idx].delay.delay_frames = d;
        }
        break;
    case SW_CMD_INPUT_AFV_GAIN:
        if (idx < ctx->input_capacity) {
            ctx->inputs[idx].afv_target = sw_clampf(c->f0, 0, 1);
            for (int k = 0; k < (int)SW_MIX_MAX_CROSSFADES; k++) {   // 直接设定会取消该槽位正在进行的淡变
                if (ctx->xfades[k].from == (int32_t)idx) ctx->xfades[k].from = -1;
                if (ctx->xfades[k].to == (int32_t)idx) ctx->xfades[k].to = -1;
            }
        }
        break;
    case SW_CMD_INPUT_RESAMPLE:
        if (idx < ctx->input_capacity) { ctx->inputs[idx].resample_mode = (uint32_t)c->i0; sw_slot_unprime(&ctx->inputs[idx]); }
        break;
    case SW_CMD_BUS_GAIN:      if (idx < SW_MIX_BUS_COUNT) ctx->buses[idx].gain_target = c->f0 < 0 ? 0 : c->f0; break;
    case SW_CMD_BUS_MUTE:      if (idx < SW_MIX_BUS_COUNT) ctx->buses[idx].muted = c->i0 != 0; break;
    case SW_CMD_EFFECT_ENABLE:
        if (idx < SW_MIX_BUS_COUNT && c->i0 >= 0 && c->i0 < (int)SW_MIX_EFFECTS_PER_BUS) ctx->buses[idx].fx[c->i0].enabled = c->i1 != 0;
        break;
    case SW_CMD_MONITOR_MODE:  ctx->monitor_mode = (uint32_t)c->i0; break;
    case SW_CMD_CROSSFADE: {
        // 同一槽位只允许一条在进行：旧的取消
        for (int k = 0; k < (int)SW_MIX_MAX_CROSSFADES; k++) {
            sw_crossfade *x = &ctx->xfades[k];
            if (!x->active) continue;
            if (c->i0 >= 0 && (x->from == c->i0 || x->to == c->i0)) { if (x->from == c->i0) x->from = -1; else x->to = -1; }
            if (c->i1 >= 0 && (x->from == c->i1 || x->to == c->i1)) { if (x->from == c->i1) x->from = -1; else x->to = -1; }
            if (x->from < 0 && x->to < 0) x->active = 0;
        }
        for (int k = 0; k < (int)SW_MIX_MAX_CROSSFADES; k++) {
            sw_crossfade *x = &ctx->xfades[k];
            if (x->active) continue;
            x->from = (c->i0 >= 0 && (uint32_t)c->i0 < ctx->input_capacity) ? c->i0 : -1;
            x->to = (c->i1 >= 0 && (uint32_t)c->i1 < ctx->input_capacity) ? c->i1 : -1;
            uint32_t blocks = c->i2 <= 0 ? 1u : (uint32_t)c->i2;
            x->duration_frames = blocks * ctx->default_block_frames;
            x->start_host = c->u0;
            x->elapsed_frames = 0;
            x->started = 0;
            x->active = (x->from >= 0 || x->to >= 0);
            if (x->from >= 0) ctx->inputs[x->from].afv_fade_start = ctx->inputs[x->from].afv;
            if (x->to >= 0) ctx->inputs[x->to].afv_fade_start = ctx->inputs[x->to].afv;
            break;
        }
        break;
    }
    case SW_CMD_TAP_ATTACH:
        if (idx < SW_MIX_MAX_TAPS) { ctx->taps[idx].source = c->i0; __atomic_store_n(&ctx->taps[idx].q, (sw_block_queue *)c->ptr, __ATOMIC_RELEASE); }
        break;
    case SW_CMD_TAP_DETACH:
        if (idx < SW_MIX_MAX_TAPS) __atomic_store_n(&ctx->taps[idx].q, (sw_block_queue *)NULL, __ATOMIC_RELEASE);
        break;
    case SW_CMD_RESET_METERS:
        for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) {
            sw_bus_state *bus = &ctx->buses[b];
            for (uint32_t ch = 0; ch < SW_MIX_BUS_CHANNELS; ch++) { bus->m.peak_max[ch] = 0; bus->m.true_peak_max[ch] = 0; }
            // 积分响度的复位需要 ebur128 重建（分配），留给 Host：这里只清峰值保持
        }
        for (uint32_t i = 0; i < ctx->input_capacity; i++) { ctx->inputs[i].peak_max[0] = 0; ctx->inputs[i].peak_max[1] = 0; }
        break;
    case SW_CMD_RESET_STATS:
        ctx->stats.dropouts = 0; ctx->stats.underruns = 0; ctx->stats.tap_drops = 0; ctx->stats.max_block_ticks = 0;
        __atomic_store_n(&ctx->overloads, (uint64_t)0, __ATOMIC_RELAXED);
        for (uint32_t i = 0; i < ctx->input_capacity; i++) { ctx->inputs[i].st.underrun_blocks = 0; ctx->inputs[i].st.reprimes = 0; }
        sw_rt_guard_reset();
        break;
    default: break;
    }
}

// ---------------------------------------------------------------------------
// 速率估计器
// ---------------------------------------------------------------------------

/// 生产者块大小：最近两条 stamp 的帧序号差（没有就用名义块）。
static inline uint32_t sw_slot_producer_block(const struct sw_mix_ctx *ctx, const sw_audio_ring *ring) SW_NONBLOCKING {
    sw_audio_stamp s0, s1;
    if (sw_audio_ring_stamp_from_latest(ring, 0, &s0) && sw_audio_ring_stamp_from_latest(ring, 1, &s1) && s0.frame_index > s1.frame_index) {
        const uint64_t d = s0.frame_index - s1.frame_index;
        if (d <= (uint64_t)ring->capacity_frames / 2u) return (uint32_t)d;
    }
    return ctx->default_block_frames;
}

/// 就绪门限：环里要有 target + P/2 + hf + chunk 帧（P = 生产者块；重采样器一上来就会吞 hf + chunk）。
/// 就绪那一刻紧跟一次交付，所以之后原始占用在 [target − P/2, target + P/2] 之间随相位周期变化，平均 = target。
static inline uint64_t sw_slot_prime_threshold(const struct sw_mix_ctx *ctx, const sw_input_slot *slot) SW_NONBLOCKING {
    uint64_t n = (uint64_t)slot->target_frames + (uint64_t)sw_slot_producer_block(ctx, slot->ring) / 2u;
    if (!(slot->resample_mode == SW_RESAMPLE_BYPASS || slot->src[0] == NULL)) n += (uint64_t)ctx->resampler_latency + (uint64_t)slot->chunk_frames;
    return n;
}

/// 就绪：从 write_index − (target + P/2 + hf + chunk/2) 开始消费（丢掉更早的，保证延迟有界）；设定点 = 此刻的年龄。
static void sw_slot_prime(struct sw_mix_ctx *ctx, sw_input_slot *slot, uint64_t host_time) SW_NONBLOCKING {
    sw_audio_ring *ring = slot->ring;
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    const uint32_t pb = sw_slot_producer_block(ctx, ring);
    uint64_t back = (uint64_t)slot->target_frames + (uint64_t)pb / 2u;
    if (!(slot->resample_mode == SW_RESAMPLE_BYPASS || slot->src[0] == NULL)) back += (uint64_t)ctx->resampler_latency + (uint64_t)slot->chunk_frames / 2u;
    const uint64_t start = w - back;
    slot->consumed = start;
    slot->input_pos = (double)start;
    __atomic_store_n(&ring->read_index, start, __ATOMIC_RELEASE);
    for (uint32_t c = 0; c < slot->channels; c++) {
        slot->pull[c].handed = start;
        slot->pull[c].pending = 0;
        if (slot->src[c]) sw_rt_src_reset(slot->src[c]);
    }
    sw_rate_state *r = &slot->rate;
    sw_audio_stamp s0;
    r->producer_block = pb;
    // 设定点 = 此刻的年龄（stamp 可用时），否则退化为原始占用目标
    if (sw_audio_ring_latest_stamp(ring, &s0) && s0.host_time != 0) {
        const double dt_ticks = (double)(int64_t)(host_time - s0.host_time);
        r->age_setpoint = dt_ticks / ctx->host_ticks_per_frame - ((double)start - (double)s0.frame_index);
    } else {
        r->age_setpoint = (double)back;
    }
    r->have_level = 0;
    r->integ = 0;
    r->win_valid = 0;
    r->ratio = r->ratio_ff;
    slot->primed = 1;
    slot->stall_blocks = 0;
    slot->last_write_index = w;
}

/// 每块一次（消费之前）：算年龄、前馈、PI，更新 slot->rate.ratio。
static void sw_rate_step(struct sw_mix_ctx *ctx, sw_input_slot *slot, uint64_t host_time, uint32_t frames) SW_NONBLOCKING {
    sw_rate_state *r = &slot->rate;
    sw_audio_ring *ring = slot->ring;
    const double tpf = ctx->host_ticks_per_frame;
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    const double occupancy = (double)(int64_t)(w - slot->pull[0].handed - (uint64_t)slot->pull[0].pending);
    double age;
    int have_stamp = 0;
    sw_audio_stamp latest;
    if (sw_audio_ring_latest_stamp(ring, &latest) && latest.host_time != 0) {
        // 位置 input_pos 的 host time = 最新 stamp 外推；年龄 = (host_time − 它) / tpf
        const double dt_ticks = (double)(int64_t)(host_time - latest.host_time);
        age = dt_ticks / tpf - (slot->input_pos - (double)latest.frame_index);
        have_stamp = 1;
        sw_audio_stamp prev;
        if (sw_audio_ring_stamp_from_latest(ring, 1, &prev) && latest.frame_index > prev.frame_index) {
            const uint64_t d = latest.frame_index - prev.frame_index;
            if (d <= (uint64_t)ring->capacity_frames / 2u) r->producer_block = (uint32_t)d;
        }
    } else {
        // 没有可用 stamp：退化为位置占用控制（设定点 = 就绪时的占用），仍然收敛
        age = (double)(int64_t)w - slot->input_pos;
    }
    if (!r->have_level) { r->level_filt = age; r->have_level = 1; }
    else r->level_filt += r->alpha_level * (age - r->level_filt);

    // 前馈：每 rate_window_s 用 stamps 与输出时间线各测一次速率
    if (have_stamp) {
        if (!r->win_valid) {
            r->win_in_frame = latest.frame_index; r->win_in_host = latest.host_time;
            r->win_out_frame = ctx->stats.frames_rendered; r->win_out_host = host_time;
            r->win_valid = 1;
        } else {
            const double out_dt = (double)(int64_t)(host_time - r->win_out_host);
            const double window_ticks = r->p.rate_window_s * (double)ctx->sample_rate * tpf;
            if (out_dt >= window_ticks && latest.frame_index > r->win_in_frame && latest.host_time > r->win_in_host) {
                const double in_dt = (double)(int64_t)(latest.host_time - r->win_in_host);
                const double r_in = (double)(latest.frame_index - r->win_in_frame) / in_dt;
                const double r_out = (double)(ctx->stats.frames_rendered - r->win_out_frame) / out_dt;
                if (r_in > 0 && r_out > 0) {
                    double meas = r_out / r_in;
                    if (meas > 0.9 && meas < 1.1) {
                        if (!r->have_ff) { r->ratio_ff = meas; r->have_ff = 1; }
                        else r->ratio_ff += r->alpha_rate * (meas - r->ratio_ff);
                    }
                }
                r->win_in_frame = latest.frame_index; r->win_in_host = latest.host_time;
                r->win_out_frame = ctx->stats.frames_rendered; r->win_out_host = host_time;
            }
        }
    }

    // PI（限幅时不积分）
    const double e = r->level_filt - r->age_setpoint;
    const double block_s = (double)frames / (double)ctx->sample_rate;
    double ratio = r->ratio_ff - (r->kp * e + r->ki * r->integ);
    const double lo = 1.0 - r->p.max_deviation, hi = 1.0 + r->p.max_deviation;
    if (ratio > hi) ratio = hi;
    else if (ratio < lo) ratio = lo;
    else r->integ += e * block_s;
    r->ratio = ratio;

    slot->st.age_frames = age;
    slot->st.age_setpoint = r->age_setpoint;
    slot->st.occupancy_filtered = r->level_filt;
    slot->st.occupancy_frames = (uint64_t)(occupancy < 0 ? 0 : occupancy);
    slot->st.producer_block = r->producer_block;
    slot->st.ratio = ratio;
    slot->st.ratio_feedforward = r->ratio_ff;
}

/// 消费之后：位置积分 + 钳到 libsamplerate 取样关系允许的范围。
/// libsamplerate 取到一段就整段拷进自己的缓冲（copied = handed + pending），只在手里 ≤ hf 帧时才取下一段，
/// 所以 sinc 中心位置 ∈ [copied − hf − chunk, copied − hf + 1]。
static inline void sw_rate_advance_position(struct sw_mix_ctx *ctx, sw_input_slot *slot, uint32_t frames, double ratio) SW_NONBLOCKING {
    slot->input_pos += (double)frames / ratio;
    const double hf = (double)ctx->resampler_latency;
    const double copied = (double)(slot->pull[0].handed + (uint64_t)slot->pull[0].pending);
    const double hi = copied - hf + 1.0, lo = copied - hf - (double)slot->chunk_frames;
    if (slot->input_pos > hi) slot->input_pos = hi;
    else if (slot->input_pos < lo) slot->input_pos = lo;
}

// ---------------------------------------------------------------------------
// 一路输入：取样 / 重采样 / 延迟 / 增益 → post[2]
// ---------------------------------------------------------------------------

static inline void sw_pan_coeffs(float pan, uint32_t channels, float *l, float *r) SW_NONBLOCKING {
    // 等功率声像：θ = (pan + 1) × π/4；单声道 L = cos θ、R = sin θ（中点各 −3 dB）；
    // 立体声当作平衡：L × min(1, √2 cos θ)、R × min(1, √2 sin θ)（中点各 1，不抬升）
    const float th = (pan + 1.0f) * (SW_PI_F * 0.25f);
    float cl = cosf(th), cr = sinf(th);
    if (channels >= 2) {
        cl *= 1.41421356f; cr *= 1.41421356f;
        if (cl > 1.0f) cl = 1.0f;
        if (cr > 1.0f) cr = 1.0f;
    }
    *l = cl; *r = cr;
}

static void sw_process_input(struct sw_mix_ctx *ctx, uint32_t slot_index, uint32_t frames, uint64_t host_time,
                             const float *xfade_gain /* 本块每样本的 AFV 增益，NULL = 平滑到目标 */) SW_NONBLOCKING {
    sw_input_slot *slot = &ctx->inputs[slot_index];
    sw_audio_ring *ring = slot->ring;
    const uint32_t ch = slot->channels;
    slot->underrun_frames_block = 0;

    // 1. 就绪 / 停摆判断
    const uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    if (w == slot->last_write_index) {
        if (slot->stall_blocks < 0xFFFFFFFFu) slot->stall_blocks++;
    } else { slot->stall_blocks = 0; slot->last_write_index = w; }
    if (slot->primed && slot->stall_blocks >= SW_STALL_BLOCKS_LIMIT) {
        sw_slot_unprime(slot);
    }
    if (!slot->primed) {
        const uint64_t avail = w - __atomic_load_n(&ring->read_index, __ATOMIC_RELAXED);
        if (avail >= sw_slot_prime_threshold(ctx, slot) && slot->stall_blocks == 0) {
            sw_slot_prime(ctx, slot, host_time);
            slot->st.reprimes++;
        }
    }

    // 2. 取样 + 重采样 → resampled[ch]
    if (slot->primed) {
        if (slot->resample_mode == SW_RESAMPLE_BYPASS || slot->src[0] == NULL) {
            const uint64_t avail = w - slot->consumed;
            uint32_t n = frames;
            if ((uint64_t)n > avail) n = (uint32_t)avail;
            const uint32_t pos = (uint32_t)(slot->consumed & (uint64_t)slot->ring_mask);
            const uint32_t cap = slot->ring_mask + 1u;
            for (uint32_t c = 0; c < ch; c++) {
                const float *plane = ring->planes[c];
                uint32_t first = cap - pos; if (first > n) first = n;
                memcpy(slot->resampled[c], plane + pos, (size_t)first * sizeof(float));
                if (n > first) memcpy(slot->resampled[c] + first, plane, (size_t)(n - first) * sizeof(float));
                if (n < frames) memset(slot->resampled[c] + n, 0, (size_t)(frames - n) * sizeof(float));
            }
            slot->underrun_frames_block = frames - n;
            slot->consumed += n;
            slot->input_pos = (double)slot->consumed;
            slot->rate.ratio = 1.0;
            slot->st.ratio = 1.0;
            slot->st.occupancy_frames = avail - n;
            slot->st.age_frames = 0; slot->st.age_setpoint = 0;
        } else {
            double ratio = 1.0;
            if (slot->resample_mode == SW_RESAMPLE_ESTIMATED) { sw_rate_step(ctx, slot, host_time, frames); ratio = slot->rate.ratio; }
            else { slot->rate.ratio = 1.0; slot->st.ratio = 1.0; }
            for (uint32_t c = 0; c < ch; c++) {
                long got = sw_rt_src_callback_read(slot->src[c], ratio, (long)frames, slot->resampled[c]);
                if (got < (long)frames) {
                    if (got < 0) got = 0;
                    memset(slot->resampled[c] + got, 0, (size_t)(frames - (uint32_t)got) * sizeof(float));
                }
            }
            // 发布已消费位置（两路声道消费一致；取较小者保险）
            uint64_t consumed = slot->pull[0].handed;
            if (ch > 1 && slot->pull[1].handed < consumed) consumed = slot->pull[1].handed;
            slot->consumed = consumed;
            sw_rate_advance_position(ctx, slot, frames, ratio);
            if (slot->resample_mode != SW_RESAMPLE_ESTIMATED) slot->st.occupancy_frames = w - consumed;
        }
        __atomic_store_n(&ring->read_index, slot->consumed, __ATOMIC_RELEASE);
        slot->st.frames_consumed = slot->consumed;
        slot->st.frames_output += frames;
        if (slot->underrun_frames_block) { slot->st.underrun_blocks++; ctx->stats.underruns++; }
    } else {
        for (uint32_t c = 0; c < ch; c++) memset(slot->resampled[c], 0, (size_t)frames * sizeof(float));
        slot->st.occupancy_frames = w - __atomic_load_n(&ring->read_index, __ATOMIC_RELAXED);
    }
    slot->st.attached = 1;
    slot->st.primed = slot->primed;

    // 3. 延迟线
    sw_delay_process(&slot->delay, ch, slot->resampled, slot->delayed, frames);

    // 4. 增益 / 静音 / AFV / 声像 → post（立体声）
    const float gt = slot->muted ? 0.0f : slot->gain_target;
    const float k = (float)(1.0 - exp(-1.0 / (SW_GAIN_SMOOTH_TAU_S * (double)ctx->sample_rate)));
    float g = slot->gain;
    float afv = slot->afv;
    const float afv_t = slot->afv_target;
    float pl0, pr0, pl1, pr1;
    sw_pan_coeffs(slot->pan, ch, &pl0, &pr0);
    slot->pan += (slot->pan_target - slot->pan) * SW_PAN_SMOOTH_PER_BLOCK;
    if (fabsf(slot->pan - slot->pan_target) < 1e-4f) slot->pan = slot->pan_target;
    sw_pan_coeffs(slot->pan, ch, &pl1, &pr1);
    const float inv = frames > 1 ? 1.0f / (float)(frames - 1) : 0.0f;
    const float *xl = slot->delayed[0];
    const float *xr = ch >= 2 ? slot->delayed[1] : slot->delayed[0];
    float *pl = slot->post[0], *pr = slot->post[1];
    float pk0 = 0, pk1 = 0;
    for (uint32_t i = 0; i < frames; i++) {
        g += (gt - g) * k;
        if (xfade_gain) afv = xfade_gain[i]; else afv += (afv_t - afv) * k;
        const float t = (float)i * inv;
        const float cl = pl0 + (pl1 - pl0) * t, cr = pr0 + (pr1 - pr0) * t;
        const float ga = g * afv;
        const float l = xl[i] * ga * cl, r = xr[i] * ga * cr;
        pl[i] = l; pr[i] = r;
        const float al = fabsf(l), ar = fabsf(r);
        if (al > pk0) pk0 = al;
        if (ar > pk1) pk1 = ar;
    }
    if (fabsf(g - gt) < 1e-7f) g = gt;
    if (!xfade_gain && fabsf(afv - afv_t) < 1e-7f) afv = afv_t;
    slot->gain = g;
    slot->afv = afv;
    slot->peak_block[0] = pk0; slot->peak_block[1] = pk1;
    if (pk0 > slot->peak_max[0]) slot->peak_max[0] = pk0;
    if (pk1 > slot->peak_max[1]) slot->peak_max[1] = pk1;
}

// ---------------------------------------------------------------------------
// AFV 交叉淡变：为本块算 from / to 两路的每样本增益（等幅：cos / sin）
// ---------------------------------------------------------------------------

static void sw_xfade_block(struct sw_mix_ctx *ctx, sw_crossfade *x, uint32_t frames, uint64_t host_time,
                           float *gain_from, float *gain_to, bool *has_from, bool *has_to) SW_NONBLOCKING {
    *has_from = *has_to = false;
    if (!x->active) return;
    const double tpf = ctx->host_ticks_per_frame;
    uint32_t s0 = 0;
    if (!x->started) {
        const double block_ticks = (double)frames * tpf;
        const double dt = (double)(int64_t)(x->start_host - host_time);   // 起点相对块首的 tick（可为负）
        if (dt >= block_ticks) return;                                   // 还没到
        x->started = 1;
        if (dt > 0) s0 = (uint32_t)(dt / tpf + 0.5);
        else x->elapsed_frames = (uint64_t)(-dt / tpf);                  // 迟到：跳到该在的位置，终点仍与视频对齐
        if (s0 >= frames) s0 = frames - 1u;
    }
    const float dur = (float)x->duration_frames;
    const float a_from = x->from >= 0 ? ctx->inputs[x->from].afv_fade_start : 0.0f;
    const float a_to = x->to >= 0 ? ctx->inputs[x->to].afv_fade_start : 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        float p;
        if (i < s0) p = 0.0f;
        else {
            p = ((float)x->elapsed_frames + (float)(i - s0)) / dur;
            if (p > 1.0f) p = 1.0f;
        }
        const float ang = p * (SW_PI_F * 0.5f);
        gain_from[i] = a_from * cosf(ang);
        gain_to[i] = a_to + (1.0f - a_to) * sinf(ang);
    }
    x->elapsed_frames += (uint64_t)(frames - s0);
    *has_from = x->from >= 0;
    *has_to = x->to >= 0;
    if (x->elapsed_frames >= (uint64_t)x->duration_frames) {
        if (x->from >= 0) { ctx->inputs[x->from].afv_target = 0.0f; ctx->inputs[x->from].afv = 0.0f; }
        if (x->to >= 0) { ctx->inputs[x->to].afv_target = 1.0f; ctx->inputs[x->to].afv = 1.0f; }
        x->active = 0;
    }
}

// ---------------------------------------------------------------------------
// 总线：效果链 → 增益 → 表 → 输出
// ---------------------------------------------------------------------------

static void sw_process_bus(struct sw_mix_ctx *ctx, uint32_t b, uint32_t frames, float *out_l, float *out_r) SW_NONBLOCKING {
    sw_bus_state *bus = &ctx->buses[b];
    float *cur[SW_MIX_BUS_CHANNELS] = { bus->sum[0], bus->sum[1] };
    float *other[SW_MIX_BUS_CHANNELS] = { bus->work[0], bus->work[1] };

    // 效果链：EQ → Dynamics → Limiter，各自可旁路；AU 从输入回调拿 cur，写到 other，然后交换
    for (uint32_t e = 0; e < SW_MIX_EFFECTS_PER_BUS; e++) {
        sw_effect_slot *fx = &bus->fx[e];
        if (!fx->enabled || fx->unit == NULL) continue;
        fx->in[0] = cur[0]; fx->in[1] = cur[1]; fx->in_frames = frames;
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts;
        memset(&ts, 0, sizeof ts);
        ts.mSampleTime = (Float64)bus->sample_time;
        ts.mFlags = kAudioTimeStampSampleTimeValid;
        AudioBufferList *list = &fx->out_list.list;
        list->mNumberBuffers = 2;
        AudioBuffer *bufs = list->mBuffers;
        for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
            bufs[c].mNumberChannels = 1;
            bufs[c].mDataByteSize = (UInt32)(frames * sizeof(float));
            bufs[c].mData = other[c];
        }
        const OSStatus st = sw_rt_audio_unit_render(fx->unit, &flags, &ts, 0, frames, list);
        if (st != noErr) {
            // 渲染失败：旁路本格（拷贝），不中断
            memcpy(other[0], cur[0], (size_t)frames * sizeof(float));
            memcpy(other[1], cur[1], (size_t)frames * sizeof(float));
        } else if (bufs[0].mData != other[0] || bufs[1].mData != other[1]) {
            // AU 可能把 mData 换成自己的缓冲：拷回来
            memcpy(other[0], bufs[0].mData, (size_t)frames * sizeof(float));
            memcpy(other[1], bufs[1].mData, (size_t)frames * sizeof(float));
        }
        float *t0 = cur[0], *t1 = cur[1];
        cur[0] = other[0]; cur[1] = other[1];
        other[0] = t0; other[1] = t1;
    }
    bus->sample_time += frames;

    // 总线增益 / 静音（平滑）
    const float gt = bus->muted ? 0.0f : bus->gain_target;
    const float k = (float)(1.0 - exp(-1.0 / (SW_GAIN_SMOOTH_TAU_S * (double)ctx->sample_rate)));
    float g = bus->gain;
    float *l = cur[0], *r = cur[1];
    float pk0 = 0, pk1 = 0;
    for (uint32_t i = 0; i < frames; i++) {
        g += (gt - g) * k;
        l[i] *= g; r[i] *= g;
        const float al = fabsf(l[i]), ar = fabsf(r[i]);
        if (al > pk0) pk0 = al;
        if (ar > pk1) pk1 = ar;
    }
    if (fabsf(g - gt) < 1e-7f) g = gt;
    bus->gain = g;

    // 表：采样峰值 + libebur128（交错输入）
    sw_bus_meter *m = &bus->m;
    m->peak[0] = pk0; m->peak[1] = pk1;
    if (pk0 > m->peak_max[0]) m->peak_max[0] = pk0;
    if (pk1 > m->peak_max[1]) m->peak_max[1] = pk1;
    if (bus->meter) {
        float *il = bus->interleaved;
        for (uint32_t i = 0; i < frames; i++) { il[2 * i] = l[i]; il[2 * i + 1] = r[i]; }
        sw_rt_ebur128_add_frames_float(bus->meter, il, (size_t)frames);
        double tp = 0;
        for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
            if (sw_rt_ebur128_prev_true_peak(bus->meter, c, &tp) == EBUR128_SUCCESS) {
                m->true_peak[c] = (float)tp;
                if ((float)tp > m->true_peak_max[c]) m->true_peak_max[c] = (float)tp;
            }
        }
        bus->frames_since_meter_update += frames;
        if (bus->frames_since_meter_update >= ctx->meter_interval_frames) {
            bus->frames_since_meter_update = 0;
            double v;
            if (sw_rt_ebur128_loudness_momentary(bus->meter, &v) == EBUR128_SUCCESS) m->momentary_lufs = v;
            if (sw_rt_ebur128_loudness_shortterm(bus->meter, &v) == EBUR128_SUCCESS) m->short_term_lufs = v;
            if (sw_rt_ebur128_loudness_global(bus->meter, &v) == EBUR128_SUCCESS) m->integrated_lufs = v;
            if (sw_rt_ebur128_loudness_range(bus->meter, &v) == EBUR128_SUCCESS) m->loudness_range_lu = v;
        }
    }

    // 写输出
    if (out_l) memcpy(out_l, l, (size_t)frames * sizeof(float));
    if (out_r) memcpy(out_r, r, (size_t)frames * sizeof(float));

    // 消费者队列
    const float *planes[SW_MIX_BUS_CHANNELS] = { l, r };
    for (uint32_t t = 0; t < SW_MIX_MAX_TAPS; t++) {
        sw_block_queue *q = __atomic_load_n(&ctx->taps[t].q, __ATOMIC_ACQUIRE);
        if (q && ctx->taps[t].source == (int32_t)b) {
            if (!sw_block_queue_push(q, planes, SW_MIX_BUS_CHANNELS, frames, ctx->stats.last_host_time, ctx->block_sequence)) ctx->stats.tap_drops++;
        }
    }
    // 留给下一块：cur 里是最终信号（sum 或 work），把它记在 sum 上没必要——每块 sum 都会清零
}

// ---------------------------------------------------------------------------
// 混音块
// ---------------------------------------------------------------------------

void sw_mix_block(sw_mix_ctx *ctx, float *const *out, uint32_t frames, uint64_t host_time) SW_NONBLOCKING {
    sw_rt_guard_enter();
    const uint64_t t_entry = sw_rt_now();
    if (frames > ctx->max_block_frames) frames = ctx->max_block_frames;
    ctx->stats.last_host_time = host_time;
    ctx->stats.last_block_frames = frames;

    // 0. 命令
    sw_cmd c;
    while (sw_cmd_pop(&ctx->cmds, &c)) {
        sw_apply_command(ctx, &c);
        __atomic_store_n(&ctx->stats.commands_applied, ctx->stats.commands_applied + 1u, __ATOMIC_RELEASE);
    }

    // 1. 清总线和
    for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) {
        memset(ctx->buses[b].sum[0], 0, (size_t)frames * sizeof(float));
        memset(ctx->buses[b].sum[1], 0, (size_t)frames * sizeof(float));
    }

    // 2. AFV 淡变的每样本增益（每条淡变有自己的 from / to 曲线缓冲，ctx 创建时分配）
    const float *slot_xf[SW_MIX_MAX_INPUTS];
    for (uint32_t i = 0; i < ctx->input_capacity; i++) slot_xf[i] = NULL;
    for (uint32_t k = 0; k < SW_MIX_MAX_CROSSFADES; k++) {
        sw_crossfade *x = &ctx->xfades[k];
        if (!x->active) continue;
        float *gf = ctx->xfade_gain[k][0];
        float *gt = ctx->xfade_gain[k][1];
        bool hf, ht;
        const int32_t from = x->from, to = x->to;
        sw_xfade_block(ctx, x, frames, host_time, gf, gt, &hf, &ht);
        if (hf && from >= 0) slot_xf[from] = gf;
        if (ht && to >= 0) slot_xf[to] = gt;
    }

    // 3. 每路输入
    bool solo_active = false;
    for (uint32_t i = 0; i < ctx->input_capacity; i++) {
        sw_input_slot *slot = &ctx->inputs[i];
        if (!slot->attached || !slot->ring) { slot->st.attached = 0; slot->st.primed = 0; continue; }
        sw_process_input(ctx, i, frames, host_time, slot_xf[i]);
        if (slot->solo) solo_active = true;
    }
    for (uint32_t i = 0; i < ctx->input_capacity; i++) {
        sw_input_slot *slot = &ctx->inputs[i];
        if (!slot->attached || !slot->ring) continue;
        const float *pl = slot->post[0], *pr = slot->post[1];
        float *ml = ctx->buses[SW_BUS_MASTER].sum[0], *mr = ctx->buses[SW_BUS_MASTER].sum[1];
        float *al = ctx->buses[SW_BUS_A].sum[0], *ar = ctx->buses[SW_BUS_A].sum[1];
        float *bl = ctx->buses[SW_BUS_B].sum[0], *br = ctx->buses[SW_BUS_B].sum[1];
        float *hl = ctx->buses[SW_BUS_HEADPHONES].sum[0], *hr = ctx->buses[SW_BUS_HEADPHONES].sum[1];
        const uint32_t rt = slot->routing;
        if (rt & SW_ROUTE_MASTER) for (uint32_t n = 0; n < frames; n++) { ml[n] += pl[n]; mr[n] += pr[n]; }
        if (rt & SW_ROUTE_A) for (uint32_t n = 0; n < frames; n++) { al[n] += pl[n]; ar[n] += pr[n]; }
        if (rt & SW_ROUTE_B) for (uint32_t n = 0; n < frames; n++) { bl[n] += pl[n]; br[n] += pr[n]; }
        // 耳机：有独听时只听独听的（PFL = 推子前 = 延迟线后原始信号；AFL = 推子后）；否则按路由
        if (solo_active) {
            if (slot->solo) {
                if (ctx->monitor_mode == SW_MONITOR_PFL) {
                    const float *xl = slot->delayed[0];
                    const float *xr = slot->channels >= 2 ? slot->delayed[1] : slot->delayed[0];
                    for (uint32_t n = 0; n < frames; n++) { hl[n] += xl[n]; hr[n] += xr[n]; }
                } else {
                    for (uint32_t n = 0; n < frames; n++) { hl[n] += pl[n]; hr[n] += pr[n]; }
                }
            }
        } else if (rt & SW_ROUTE_HEADPHONES) {
            for (uint32_t n = 0; n < frames; n++) { hl[n] += pl[n]; hr[n] += pr[n]; }
        }
        // 输入 tap（推子后）
        for (uint32_t t = 0; t < SW_MIX_MAX_TAPS; t++) {
            sw_block_queue *q = __atomic_load_n(&ctx->taps[t].q, __ATOMIC_ACQUIRE);
            if (q && ctx->taps[t].source == (int32_t)(SW_INPUT_TAP_BASE + i)) {
                const float *planes[SW_MIX_BUS_CHANNELS] = { pl, pr };
                if (!sw_block_queue_push(q, planes, SW_MIX_BUS_CHANNELS, frames, host_time, ctx->block_sequence)) ctx->stats.tap_drops++;
            }
        }
    }

    // 4. 总线
    for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) {
        sw_process_bus(ctx, b, frames, out ? out[2 * b] : NULL, out ? out[2 * b + 1] : NULL);
    }

    // 5. 表快照（seqlock）
    __atomic_store_n(&ctx->meter_seq, ctx->meter_seq + 1u, __ATOMIC_RELEASE);   // 奇数：写入中
    __atomic_thread_fence(__ATOMIC_RELEASE);
    ctx->meters.block_sequence = ctx->block_sequence;
    for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) ctx->meters.bus[b] = ctx->buses[b].m;
    for (uint32_t i = 0; i < ctx->input_capacity; i++) {
        ctx->meters.input[i].peak[0] = ctx->inputs[i].peak_block[0];
        ctx->meters.input[i].peak[1] = ctx->inputs[i].peak_block[1];
        ctx->meters.input[i].peak_max[0] = ctx->inputs[i].peak_max[0];
        ctx->meters.input[i].peak_max[1] = ctx->inputs[i].peak_max[1];
    }
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&ctx->meter_seq, ctx->meter_seq + 1u, __ATOMIC_RELEASE);   // 偶数：可读

    // 6. 统计
    ctx->block_sequence++;
    ctx->stats.blocks_rendered++;
    ctx->stats.frames_rendered += frames;
    for (uint32_t i = 0; i < ctx->input_capacity; i++) ctx->stats.input[i] = ctx->inputs[i].st;
    ctx->stats.input_count = ctx->input_capacity;
    const uint64_t elapsed = sw_rt_now() - t_entry;
    ctx->stats.last_block_ticks = elapsed;
    if (elapsed > ctx->stats.max_block_ticks) ctx->stats.max_block_ticks = elapsed;
    if (ctx->timing_check && (double)elapsed > (double)frames * ctx->host_ticks_per_frame) ctx->timeouts++;
    ctx->stats.dropouts = ctx->timeouts + __atomic_load_n(&ctx->overloads, __ATOMIC_RELAXED);
    ctx->stats.rt_violations = sw_rt_guard_violation_count();
    sw_rt_guard_exit();
}

uint32_t sw_mix_ctx_max_block_frames(const sw_mix_ctx *ctx) SW_NONBLOCKING { return ctx->max_block_frames; }
double sw_mix_ctx_host_ticks_per_frame_rt(const sw_mix_ctx *ctx) SW_NONBLOCKING { return ctx->host_ticks_per_frame; }
uint64_t sw_mix_ctx_commands_applied(const sw_mix_ctx *ctx) SW_NONBLOCKING { return __atomic_load_n(&ctx->stats.commands_applied, __ATOMIC_ACQUIRE); }
void sw_mix_ctx_note_overload(sw_mix_ctx *ctx) SW_NONBLOCKING { __atomic_fetch_add(&ctx->overloads, 1u, __ATOMIC_RELAXED); }
