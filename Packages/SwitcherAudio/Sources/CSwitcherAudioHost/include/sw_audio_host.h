// sw_audio_host.h —— SwitcherAudio 非实时侧的 C 接口：分配 / 释放、命令入队、统计与表的快照。
// 这里可以 malloc、可以锁；这里的函数不许被实时线程调用（sw_rt_guard_check 会记违规）。
#ifndef SW_AUDIO_HOST_H
#define SW_AUDIO_HOST_H

#include "sw_audio_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---- 音频环 ----

/// 创建一个环：channels 1…8，capacity_frames / stamp_capacity 都会向上取到 2 的幂。环头 64 字节对齐（契约规则 5）。
/// 失败返回 NULL。
sw_audio_ring *sw_audio_ring_create(uint32_t channels, uint32_t capacity_frames, uint32_t stamp_capacity);
/// 释放。调用方保证生产者 / 消费者都不再碰它。
void sw_audio_ring_destroy(sw_audio_ring *ring);

// ---- 块队列 ----

/// 创建：capacity_blocks 块（向上取 2 的幂），每块 channels × max_block_frames 个 float。
sw_block_queue *sw_block_queue_create(uint32_t capacity_blocks, uint32_t channels, uint32_t max_block_frames);
void sw_block_queue_destroy(sw_block_queue *q);

// ---- 混音上下文 ----

/// 创建参数。
typedef struct sw_mix_ctx_config {
    uint32_t sample_rate;          ///< 48000
    uint32_t max_block_frames;     ///< ≤ SW_MIX_MAX_BLOCK_FRAMES，默认 4096（设备 buffer size 上限）
    uint32_t max_inputs;           ///< ≤ SW_MIX_MAX_INPUTS
    uint32_t default_block_frames; ///< 名义块大小（速率估计器设定点的单位），默认 256
    double   host_ticks_per_frame; ///< 每帧 host tick：timebase.denom × 1e9 / (numer × sample_rate)
    int      resampler_converter;  ///< libsamplerate 的 SRC_SINC_* 常量，默认 SRC_SINC_MEDIUM_QUALITY
    uint32_t resampler_chunk_frames; ///< 重采样器每次向环要多少帧（越小环占用越准），默认 32
    sw_rate_params rate;           ///< 速率估计器参数（0 = 默认）
    uint32_t meter_interval_ms;    ///< 响度读数更新间隔，默认 100
} sw_mix_ctx_config;

/// 默认参数。
sw_mix_ctx_config sw_mix_ctx_config_default(double host_ticks_per_frame);
/// 默认估计器参数。
sw_rate_params sw_rate_params_default(uint32_t block_frames);

/// 创建（分配全部缓冲、重采样器、表；不碰设备）。失败返回 NULL。
sw_mix_ctx *sw_mix_ctx_create(const sw_mix_ctx_config *config);
/// 销毁。调用方保证实时线程已停。
void sw_mix_ctx_destroy(sw_mix_ctx *ctx);

/// 为某条总线装一个已 initialize 的 AudioUnit（AudioToolbox 的 AudioUnit 句柄，void* 传递避免 Host 头依赖框架）。
/// 只能在实时线程未跑、或该效果处于关闭状态时调用；运行期不改拓扑（设计方案 §7）。
/// 效果的输入回调由本函数装上（kAudioUnitProperty_SetRenderCallback），unit 的格式必须是 48 kHz float32 非交错 2 声道。
/// 返回 0 成功。
int sw_mix_ctx_install_effect(sw_mix_ctx *ctx, uint32_t bus, uint32_t effect, void *audio_unit);
/// 卸下（不销毁 unit）。
void sw_mix_ctx_remove_effect(sw_mix_ctx *ctx, uint32_t bus, uint32_t effect);

/// 入队一条命令（控制线程；多个控制线程要自己串行）。队列满返回 false 并累计 commands_dropped。
bool sw_mix_ctx_push_command(sw_mix_ctx *ctx, const sw_cmd *cmd);
/// 已入队的命令总数（每条命令的序号 = 入队后的这个值）。
uint64_t sw_mix_ctx_commands_pushed(const sw_mix_ctx *ctx);
/// 拷一份统计快照。
void sw_mix_ctx_copy_stats(const sw_mix_ctx *ctx, sw_mix_stats *out);
/// 拷一份表读数快照（seqlock，读到一致的一份）。
void sw_mix_ctx_copy_meters(const sw_mix_ctx *ctx, sw_mix_meters *out);
/// 输入槽位准备：把槽位的延迟线清零、重采样器复位（在 attach 之前、槽位空闲时由控制线程调）。
void sw_mix_ctx_prepare_slot(sw_mix_ctx *ctx, uint32_t slot);
/// 上下文参数。
uint32_t sw_mix_ctx_input_capacity(const sw_mix_ctx *ctx);
double   sw_mix_ctx_host_ticks_per_frame(const sw_mix_ctx *ctx);
uint32_t sw_mix_ctx_sample_rate(const sw_mix_ctx *ctx);
/// 重采样器固有延迟（帧）：sinc 半长；给延迟核算用。
uint32_t sw_mix_ctx_resampler_latency_frames(const sw_mix_ctx *ctx);

// ---- 实时守卫的非实时封装（本仓库里所有会分配 / 加锁 / 打日志的 C 代码都走它们）----

/// malloc 的封装：在实时块内被调到记违规。
void *sw_host_alloc(size_t bytes);
void  sw_host_free(void *p);
/// 测试用：挂 / 卸 libmalloc 的 malloc_logger 钩子，实时块内的 malloc / free 都记进 sw_rt_guard_violations。
void sw_rt_probe_install_malloc_hook(void);
void sw_rt_probe_remove_malloc_hook(void);
/// 钩子记到的分配次数（与 violations 分开计，便于定位）。
uint64_t sw_rt_probe_allocations_in_rt(void);

#ifdef __cplusplus
}
#endif
#endif /* SW_AUDIO_HOST_H */
