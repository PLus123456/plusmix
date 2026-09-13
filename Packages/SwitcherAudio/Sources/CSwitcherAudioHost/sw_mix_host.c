// sw_mix_host.c —— 混音上下文的创建 / 销毁 / 命令入队 / 快照（非实时线程）。
#include "sw_audio_host.h"
#include "sw_mix_internal.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <AudioToolbox/AudioToolbox.h>

// libmalloc 的分配日志钩子（MallocStackLogging / Instruments 用的那个）。macOS 26 SDK 的 malloc/malloc.h 不再声明它，
// 但 libsystem_malloc 仍导出 _malloc_logger；这里自己声明。只在测试里挂（sw_rt_probe_*），产品代码不碰。
typedef void (sw_malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                                  uint32_t num_hot_frames_to_skip);
extern sw_malloc_logger_t *malloc_logger;

static uint32_t sw_pow2_ceil_u32(uint32_t v) {
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

// ---------------------------------------------------------------------------
// 守卫封装与 malloc 钩子
// ---------------------------------------------------------------------------

void *sw_host_alloc(size_t bytes) {
    sw_rt_guard_check();
    return malloc(bytes);
}
void sw_host_free(void *p) {
    sw_rt_guard_check();
    free(p);
}

static uint64_t sw_rt_probe_alloc_count = 0;
static sw_malloc_logger_t *sw_rt_probe_prev_logger = NULL;

static void sw_rt_probe_logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result, uint32_t skip) {
    (void)type; (void)a1; (void)a2; (void)a3; (void)result; (void)skip;
    if (sw_rt_guard_active_on_this_thread()) {
        __atomic_fetch_add(&sw_rt_probe_alloc_count, 1u, __ATOMIC_RELAXED);
        __atomic_fetch_add(&sw_rt_guard_violations, 1u, __ATOMIC_RELAXED);
    }
}

void sw_rt_probe_install_malloc_hook(void) {
    if (malloc_logger == sw_rt_probe_logger) return;
    sw_rt_probe_prev_logger = malloc_logger;
    malloc_logger = sw_rt_probe_logger;
}
void sw_rt_probe_remove_malloc_hook(void) {
    if (malloc_logger == sw_rt_probe_logger) malloc_logger = sw_rt_probe_prev_logger;
}
uint64_t sw_rt_probe_allocations_in_rt(void) { return __atomic_load_n(&sw_rt_probe_alloc_count, __ATOMIC_RELAXED); }
void sw_rt_probe_reset(void) { __atomic_store_n(&sw_rt_probe_alloc_count, (uint64_t)0, __ATOMIC_RELAXED); sw_rt_guard_reset(); }

// ---------------------------------------------------------------------------
// 块队列
// ---------------------------------------------------------------------------

sw_block_queue *sw_block_queue_create(uint32_t capacity_blocks, uint32_t channels, uint32_t max_block_frames) {
    if (channels == 0 || max_block_frames == 0) return NULL;
    sw_block_queue *q = (sw_block_queue *)calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->capacity = sw_pow2_ceil_u32(capacity_blocks);
    q->mask = q->capacity - 1u;
    q->channels = channels;
    q->max_frames = max_block_frames;
    q->data = (float *)calloc((size_t)q->capacity * channels * max_block_frames, sizeof(float));
    q->frames = (uint32_t *)calloc(q->capacity, sizeof(uint32_t));
    q->host_times = (uint64_t *)calloc(q->capacity, sizeof(uint64_t));
    q->sequences = (uint64_t *)calloc(q->capacity, sizeof(uint64_t));
    if (!q->data || !q->frames || !q->host_times || !q->sequences) { sw_block_queue_destroy(q); return NULL; }
    return q;
}

void sw_block_queue_destroy(sw_block_queue *q) {
    if (!q) return;
    free(q->data); free(q->frames); free(q->host_times); free(q->sequences);
    free(q);
}

// ---------------------------------------------------------------------------
// 参数默认值
// ---------------------------------------------------------------------------

sw_rate_params sw_rate_params_default(uint32_t block_frames) {
    sw_rate_params p;
    p.level_tau_s = 0.25;
    p.rate_tau_s = 10.0;
    p.rate_window_s = 1.0;
    p.loop_tau_s = 10.0;
    p.max_deviation = 1e-3;
    p.target_frames = 2u * (block_frames ? block_frames : SW_AUDIO_DEFAULT_BLOCK_FRAMES);
    return p;
}

sw_mix_ctx_config sw_mix_ctx_config_default(double host_ticks_per_frame) {
    sw_mix_ctx_config c;
    memset(&c, 0, sizeof c);
    c.sample_rate = SW_AUDIO_SAMPLE_RATE;
    c.max_block_frames = SW_MIX_MAX_BLOCK_FRAMES;
    c.max_inputs = SW_MIX_MAX_INPUTS;
    c.default_block_frames = SW_AUDIO_DEFAULT_BLOCK_FRAMES;
    c.host_ticks_per_frame = host_ticks_per_frame;
    c.resampler_converter = SRC_SINC_MEDIUM_QUALITY;
    c.resampler_chunk_frames = 32;
    c.rate = sw_rate_params_default(c.default_block_frames);
    c.meter_interval_ms = 100;
    return c;
}

// ---------------------------------------------------------------------------
// 上下文
// ---------------------------------------------------------------------------

static void sw_rate_state_init(sw_rate_state *r, const sw_rate_params *p, uint32_t sample_rate, uint32_t block_frames) {
    memset(r, 0, sizeof *r);
    r->p = *p;
    const double block_s = (double)block_frames / (double)sample_rate;
    r->alpha_level = 1.0 - exp(-block_s / p->level_tau_s);
    r->alpha_rate = 1.0 - exp(-p->rate_window_s / p->rate_tau_s);
    const double wn = 1.0 / p->loop_tau_s;
    r->kp = 2.0 * wn / (double)sample_rate;            // ζ = 1
    r->ki = wn * wn / (double)sample_rate;
    r->ratio_ff = 1.0;
    r->ratio = 1.0;
}

static int sw_slot_alloc(sw_mix_ctx *ctx, sw_input_slot *slot) {
    const uint32_t mb = ctx->max_block_frames;
    slot->delay.capacity = sw_pow2_ceil_u32(SW_MIX_MAX_DELAY_FRAMES + mb);
    slot->delay.mask = slot->delay.capacity - 1u;
    for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
        slot->delay.buf[c] = (float *)calloc(slot->delay.capacity, sizeof(float));
        slot->resampled[c] = (float *)calloc(mb, sizeof(float));
        slot->delayed[c] = (float *)calloc(mb, sizeof(float));
        slot->post[c] = (float *)calloc(mb, sizeof(float));
        if (!slot->delay.buf[c] || !slot->resampled[c] || !slot->delayed[c] || !slot->post[c]) return -1;
        slot->pull[c].slot = slot;
        slot->pull[c].channel = c;
        int err = 0;
        slot->src[c] = src_callback_new(sw_input_pull, ctx->resampler_converter_saved, 1, &err, &slot->pull[c]);
        if (!slot->src[c]) return -1;
    }
    slot->zeros = ctx->zeros;
    slot->chunk_frames = ctx->resampler_chunk;
    slot->gain = slot->gain_target = 1.0f;
    slot->afv = slot->afv_target = 1.0f;
    slot->pan = slot->pan_target = 0.0f;
    slot->routing = SW_ROUTE_MASTER;
    sw_rate_state_init(&slot->rate, &ctx->rate_defaults, ctx->sample_rate, ctx->default_block_frames);
    return 0;
}

static void sw_slot_free(sw_input_slot *slot) {
    for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
        free(slot->delay.buf[c]); free(slot->resampled[c]); free(slot->delayed[c]); free(slot->post[c]);
        if (slot->src[c]) src_delete(slot->src[c]);
    }
}

sw_mix_ctx *sw_mix_ctx_create(const sw_mix_ctx_config *config) {
    if (!config || config->sample_rate == 0 || config->host_ticks_per_frame <= 0) return NULL;
    sw_mix_ctx *ctx = (sw_mix_ctx *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->sample_rate = config->sample_rate;
    ctx->max_block_frames = config->max_block_frames ? config->max_block_frames : SW_MIX_MAX_BLOCK_FRAMES;
    if (ctx->max_block_frames > SW_MIX_MAX_BLOCK_FRAMES) ctx->max_block_frames = SW_MIX_MAX_BLOCK_FRAMES;
    ctx->default_block_frames = config->default_block_frames ? config->default_block_frames : SW_AUDIO_DEFAULT_BLOCK_FRAMES;
    ctx->input_capacity = config->max_inputs ? config->max_inputs : SW_MIX_MAX_INPUTS;
    if (ctx->input_capacity > SW_MIX_MAX_INPUTS) ctx->input_capacity = SW_MIX_MAX_INPUTS;
    ctx->resampler_chunk = config->resampler_chunk_frames ? config->resampler_chunk_frames : 32;
    if (ctx->resampler_chunk > ctx->max_block_frames) ctx->resampler_chunk = ctx->max_block_frames;
    ctx->resampler_converter_saved = config->resampler_converter;
    ctx->host_ticks_per_frame = config->host_ticks_per_frame;
    ctx->rate_defaults = config->rate.loop_tau_s > 0 ? config->rate : sw_rate_params_default(ctx->default_block_frames);
    if (ctx->rate_defaults.target_frames == 0) ctx->rate_defaults.target_frames = 2u * ctx->default_block_frames;
    const uint32_t interval_ms = config->meter_interval_ms ? config->meter_interval_ms : 100;
    ctx->meter_interval_frames = (uint32_t)((uint64_t)ctx->sample_rate * interval_ms / 1000u);
    // sinc 半长 hf = lrint((coeff_half_len + 2) / index_inc) + 1（src_sinc.c 的 half_filter_chan_len，单声道，比率 ≈ 1）：
    // FASTEST (2463+2)/128 = 19.3 → 20；MEDIUM (22437+2)/491 = 45.7 → 47；BEST (340239+2)/2381 = 142.9 → 144。
    // 对齐延迟为 0（libsamplerate 前补零、sinc 中心对准输入帧）；hf 只是"手里要先有多少帧"，用于就绪门限与位置钳制。
    switch (config->resampler_converter) {
    case SRC_SINC_BEST_QUALITY: ctx->resampler_latency = 144; break;
    case SRC_SINC_FASTEST: ctx->resampler_latency = 20; break;
    case SRC_LINEAR: case SRC_ZERO_ORDER_HOLD: ctx->resampler_latency = 1; break;
    default: ctx->resampler_latency = 47; break;
    }
    ctx->zeros = (float *)calloc(ctx->max_block_frames, sizeof(float));
    if (!ctx->zeros) { sw_mix_ctx_destroy(ctx); return NULL; }
    for (uint32_t k = 0; k < SW_MIX_MAX_CROSSFADES; k++) {
        ctx->xfade_gain[k][0] = (float *)calloc(ctx->max_block_frames, sizeof(float));
        ctx->xfade_gain[k][1] = (float *)calloc(ctx->max_block_frames, sizeof(float));
        if (!ctx->xfade_gain[k][0] || !ctx->xfade_gain[k][1]) { sw_mix_ctx_destroy(ctx); return NULL; }
        ctx->xfades[k].from = ctx->xfades[k].to = -1;
    }
    for (uint32_t i = 0; i < ctx->input_capacity; i++) {
        if (sw_slot_alloc(ctx, &ctx->inputs[i]) != 0) { sw_mix_ctx_destroy(ctx); return NULL; }
    }
    for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) {
        sw_bus_state *bus = &ctx->buses[b];
        for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
            bus->sum[c] = (float *)calloc(ctx->max_block_frames, sizeof(float));
            bus->work[c] = (float *)calloc(ctx->max_block_frames, sizeof(float));
            if (!bus->sum[c] || !bus->work[c]) { sw_mix_ctx_destroy(ctx); return NULL; }
        }
        bus->interleaved = (float *)calloc((size_t)ctx->max_block_frames * SW_MIX_BUS_CHANNELS, sizeof(float));
        if (!bus->interleaved) { sw_mix_ctx_destroy(ctx); return NULL; }
        bus->gain = bus->gain_target = 1.0f;
        // 直方图模式：实时线程里不分配（非直方图模式每个 gating block 会 malloc 链表节点）
        bus->meter = ebur128_init(SW_MIX_BUS_CHANNELS, ctx->sample_rate,
                                  EBUR128_MODE_M | EBUR128_MODE_S | EBUR128_MODE_I | EBUR128_MODE_LRA |
                                  EBUR128_MODE_TRUE_PEAK | EBUR128_MODE_HISTOGRAM);
        if (!bus->meter) { sw_mix_ctx_destroy(ctx); return NULL; }
        bus->m.momentary_lufs = bus->m.short_term_lufs = bus->m.integrated_lufs = -HUGE_VAL;
        bus->m.loudness_range_lu = 0;
        // 四条总线的响度读数错开 1/4 个间隔更新：S 要对 3 s 音频求和（≈ 0.3 ms），四条挤在同一块会出 1.2 ms 的尖峰
        bus->frames_since_meter_update = (uint32_t)((uint64_t)ctx->meter_interval_frames * b / SW_MIX_BUS_COUNT);
        for (uint32_t t = 0; t < SW_MIX_MAX_TAPS; t++) ctx->taps[t].source = -1;
    }
    return ctx;
}

void sw_mix_ctx_destroy(sw_mix_ctx *ctx) {
    if (!ctx) return;
    for (uint32_t i = 0; i < SW_MIX_MAX_INPUTS; i++) sw_slot_free(&ctx->inputs[i]);
    for (uint32_t b = 0; b < SW_MIX_BUS_COUNT; b++) {
        sw_bus_state *bus = &ctx->buses[b];
        for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) { free(bus->sum[c]); free(bus->work[c]); }
        free(bus->interleaved);
        if (bus->meter) ebur128_destroy(&bus->meter);
    }
    for (uint32_t k = 0; k < SW_MIX_MAX_CROSSFADES; k++) { free(ctx->xfade_gain[k][0]); free(ctx->xfade_gain[k][1]); }
    free(ctx->zeros);
    free(ctx);
}

int sw_mix_ctx_install_effect(sw_mix_ctx *ctx, uint32_t bus, uint32_t effect, void *audio_unit) {
    if (!ctx || bus >= SW_MIX_BUS_COUNT || effect >= SW_MIX_EFFECTS_PER_BUS || !audio_unit) return -1;
    sw_effect_slot *fx = &ctx->buses[bus].fx[effect];
    AURenderCallbackStruct cb;
    cb.inputProc = sw_effect_input_proc;
    cb.inputProcRefCon = fx;
    OSStatus st = AudioUnitSetProperty((AudioUnit)audio_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (st != noErr) return (int)st;
    __atomic_store_n(&fx->unit, (AudioUnit)audio_unit, __ATOMIC_RELEASE);
    return 0;
}

void sw_mix_ctx_remove_effect(sw_mix_ctx *ctx, uint32_t bus, uint32_t effect) {
    if (!ctx || bus >= SW_MIX_BUS_COUNT || effect >= SW_MIX_EFFECTS_PER_BUS) return;
    sw_effect_slot *fx = &ctx->buses[bus].fx[effect];
    fx->enabled = 0;
    __atomic_store_n(&fx->unit, (AudioUnit)NULL, __ATOMIC_RELEASE);
}

bool sw_mix_ctx_push_command(sw_mix_ctx *ctx, const sw_cmd *cmd) {
    sw_cmd_queue *q = &ctx->cmds;
    const uint64_t tail = q->tail;
    const uint64_t head = __atomic_load_n(&q->head, __ATOMIC_ACQUIRE);
    if (tail - head >= (uint64_t)SW_MIX_CMD_CAPACITY) {
        ctx->cmds_dropped++;
        ctx->stats.commands_dropped = ctx->cmds_dropped;
        return false;
    }
    q->cmds[tail & (SW_MIX_CMD_CAPACITY - 1u)] = *cmd;
    __atomic_store_n(&q->tail, tail + 1u, __ATOMIC_RELEASE);
    ctx->cmds_pushed++;
    return true;
}

uint64_t sw_mix_ctx_commands_pushed(const sw_mix_ctx *ctx) { return ctx->cmds_pushed; }

void sw_mix_ctx_copy_stats(const sw_mix_ctx *ctx, sw_mix_stats *out) {
    // 单写者的普通字段：整体拷贝（每个 64 位字段本身是原子写，字段之间可能不同块——监控用途可接受）
    *out = ctx->stats;
    out->rt_violations = sw_rt_guard_violation_count();
    out->commands_dropped = ctx->cmds_dropped;
}

void sw_mix_ctx_copy_meters(const sw_mix_ctx *ctx, sw_mix_meters *out) {
    for (int attempt = 0; attempt < 10000; attempt++) {
        const uint32_t s1 = __atomic_load_n(&ctx->meter_seq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;
        *out = ctx->meters;
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        const uint32_t s2 = __atomic_load_n(&ctx->meter_seq, __ATOMIC_ACQUIRE);
        if (s1 == s2) return;
    }
    *out = ctx->meters;   // 实时线程持续在写：给一份可能撕裂的
}

void sw_mix_ctx_prepare_slot(sw_mix_ctx *ctx, uint32_t slot_index) {
    if (!ctx || slot_index >= ctx->input_capacity) return;
    sw_input_slot *slot = &ctx->inputs[slot_index];
    for (uint32_t c = 0; c < SW_MIX_BUS_CHANNELS; c++) {
        memset(slot->delay.buf[c], 0, (size_t)slot->delay.capacity * sizeof(float));
        if (slot->src[c]) src_reset(slot->src[c]);
        slot->pull[c].handed = 0; slot->pull[c].pending = 0;
        slot->peak_max[c] = 0; slot->peak_block[c] = 0;
    }
    slot->delay.write_pos = 0;
    slot->consumed = 0;
    memset(&slot->st, 0, sizeof slot->st);
}

uint32_t sw_mix_ctx_input_capacity(const sw_mix_ctx *ctx) { return ctx->input_capacity; }
double sw_mix_ctx_host_ticks_per_frame(const sw_mix_ctx *ctx) { return ctx->host_ticks_per_frame; }
uint32_t sw_mix_ctx_sample_rate(const sw_mix_ctx *ctx) { return ctx->sample_rate; }
uint32_t sw_mix_ctx_resampler_latency_frames(const sw_mix_ctx *ctx) { return ctx->resampler_latency; }
void sw_mix_ctx_set_timing_check(sw_mix_ctx *ctx, bool on) { __atomic_store_n(&ctx->timing_check, on ? 1u : 0u, __ATOMIC_RELAXED); }

// ---------------------------------------------------------------------------
// 守卫自检（测试用）：在守卫区里故意 malloc，钩子应记到；返回记到的次数（期望 ≥ 1）
// ---------------------------------------------------------------------------
uint64_t sw_rt_probe_selftest(void) {
    const uint64_t before = sw_rt_probe_allocations_in_rt();
    sw_rt_guard_enter();
    void *p = malloc(64);
    void *q = sw_host_alloc(1);   // 封装：记违规 + 分配（钩子也记）
    free(p);
    sw_host_free(q);
    sw_rt_guard_exit();
    return sw_rt_probe_allocations_in_rt() - before;
}
