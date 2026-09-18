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
/// 重采样器需要预先看到的帧数（sinc 半长）；对齐延迟为 0（libsamplerate 前补零），这个数给就绪门限说明用。
uint32_t sw_mix_ctx_resampler_latency_frames(const sw_mix_ctx *ctx);
/// 指定目标年龄（SW_CMD_ATTACH_INPUT 的 i2）时，任何生产者相位都能精确命中的最小年龄（帧）：
/// back（= target + P/2 + hf + chunk/2，重采样时；bypass 时没有 hf + chunk/2）+ 生产者块 P。target_frames 0 = 默认（2 块）。
/// 比它小的目标在相位不利的块上会被钳到 back + 相位（年龄 > 目标）。W1-D2。
uint32_t sw_mix_ctx_deterministic_age_frames(const sw_mix_ctx *ctx, uint32_t target_frames, uint32_t producer_block, bool resampled);
/// 是否用真实时钟检查"块处理时间 > 块时长"（记 dropouts）。实时驱动开，离线驱动关。
void sw_mix_ctx_set_timing_check(sw_mix_ctx *ctx, bool on);

// ---- 设备 IOProc 客户端 ----

/// 创建（ctx 可为 NULL：纯输入客户端）。
sw_device_client *sw_device_client_create(sw_mix_ctx *ctx, uint32_t max_block_frames);
void sw_device_client_destroy(sw_device_client *c);
/// 输出：设备通道布局（从 kAudioDevicePropertyStreamConfiguration 算）与逻辑通道 → 设备通道映射（8 个，−1 不输出）。
void sw_device_client_set_output_layout(sw_device_client *c, const sw_channel_location *locs, uint32_t count);
void sw_device_client_set_output_map(sw_device_client *c, const int32_t *map8);
/// 输入：设备输入通道布局、环声道 → 设备输入通道映射、目标环（原子换，NULL 关）。
void sw_device_client_set_input_layout(sw_device_client *c, const sw_channel_location *locs, uint32_t count);
void sw_device_client_set_input_map(sw_device_client *c, const int32_t *map, uint32_t count);
void sw_device_client_set_input_ring(sw_device_client *c, sw_audio_ring *ring);
void sw_device_client_copy_stats(const sw_device_client *c, sw_device_client_stats *out);
void sw_device_client_reset_stats(sw_device_client *c);

// ---- 空输出设备驱动（timer 驱动的假设备时钟）----

typedef struct sw_null_driver sw_null_driver;
typedef struct sw_null_driver_stats {
    uint64_t blocks;
    uint64_t skipped_blocks;        ///< 线程被抢占太久、跳过的块
    uint64_t max_wake_late_ticks;   ///< mach_wait_until 醒来比目标晚的最大值
    uint64_t wake_hist[32];         ///< 每桶 100 µs
} sw_null_driver_stats;

sw_null_driver *sw_null_driver_create(sw_mix_ctx *ctx, uint32_t block_frames);
void sw_null_driver_destroy(sw_null_driver *d);
int  sw_null_driver_start(sw_null_driver *d);
void sw_null_driver_stop(sw_null_driver *d);
void sw_null_driver_copy_stats(const sw_null_driver *d, sw_null_driver_stats *out);
uint64_t sw_null_driver_period_ticks(const sw_null_driver *d);

// ---- 实时守卫的非实时封装（本仓库里所有会分配 / 加锁 / 打日志的 C 代码都走它们）----

/// malloc 的封装：在实时块内被调到记违规。
void *sw_host_alloc(size_t bytes);
void  sw_host_free(void *p);
/// 测试用：挂 / 卸 libmalloc 的 malloc_logger 钩子，实时块内的 malloc / free 都记进 sw_rt_guard_violations。
void sw_rt_probe_install_malloc_hook(void);
void sw_rt_probe_remove_malloc_hook(void);
/// 钩子记到的分配次数（与 violations 分开计，便于定位）。
uint64_t sw_rt_probe_allocations_in_rt(void);
/// 清零钩子计数与守卫违规计数。
void sw_rt_probe_reset(void);
/// 自检：守卫区内故意 malloc / free，返回钩子记到的次数（期望 ≥ 2）。
uint64_t sw_rt_probe_selftest(void);

#ifdef __cplusplus
}
#endif
#endif /* SW_AUDIO_HOST_H */
