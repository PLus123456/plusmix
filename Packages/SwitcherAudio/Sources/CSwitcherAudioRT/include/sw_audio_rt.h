// sw_audio_rt.h —— SwitcherAudio 热路径（实时线程）的 C 接口。W1-D。
//
// 这个 target 里的每个函数都可能跑在输出设备的 IOProc（实时线程）上，规则（设计方案 §3.5）：
// 无锁、无分配、无日志、无系统调用、无 Swift / ObjC 运行时。机械检查：
//   - scripts/check-rt-symbols.sh 对本 target 的目标文件做 nm -u（禁止 malloc / 锁 / os_log / objc / swift 符号）；
//   - 每个源文件 [[clang::nonblocking]] + -Wfunction-effects 升级成错误（sw_rt_pragma.h）；
//   - sw_rt_guard 运行期守卫 + 测试里的 malloc_logger 钩子（sw_rt_guard.h）。
// 分配 / 释放 / 创建 / 销毁一律在 CSwitcherAudioHost（sw_audio_host.h），由非实时线程调用。
//
// 结构布局约定：所有跨线程字段都是单写者（写方注明），读方用 __atomic_load；
// 混音上下文 sw_mix_ctx 对 Swift 不透明，读统计 / 表走 Host target 的快照函数。
#ifndef SW_AUDIO_RT_H
#define SW_AUDIO_RT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreAudio/CoreAudio.h>
#include "sw_audio_ring.h"
#include "sw_rt_attr.h"
#include "sw_rt_guard.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Swift 侧读 64 位计数用的原子读（Swift 没有 __atomic_load_n）。
static inline uint64_t sw_atomic_load_u64(const uint64_t *p) SW_NONBLOCKING { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
/// 原子加（非实时线程用，例如设备 overload 通知计数）。
static inline void sw_atomic_add_u64(uint64_t *p, uint64_t v) SW_NONBLOCKING { __atomic_fetch_add(p, v, __ATOMIC_RELAXED); }

// ============================================================================
// 1. 音频环（契约 sw_audio_ring.h 的实现；SPSC；float32 非交错；每块带 host time）
// ============================================================================

/// 生产者：写一块（`planes[c]` 指向 frames 个 float，c < ring->channels）。
/// 环满时只写放得下的部分，其余丢掉并累计 overruns。追加一条 stamp（首帧序号 + host_time）。
/// 返回实际写入帧数。只能由该环唯一的生产者线程调用。
uint32_t sw_audio_ring_write(sw_audio_ring *ring, const float *const *planes, uint32_t frames, uint64_t host_time) SW_NONBLOCKING;

/// 消费者：读 frames 帧到 `planes`（每个平面至少 frames 个 float）。不够的补零并累计 underruns。
/// 返回实际读到帧数；*first_host_time 是读到的第一帧的 host time（按最近 stamp 外推，需要 host_ticks_per_frame）；
/// 一帧都没读到或没有 stamp 时 *first_valid = false。只能由该环唯一的消费者线程调用。
uint32_t sw_audio_ring_read(sw_audio_ring *ring, float *const *planes, uint32_t frames, double host_ticks_per_frame,
                            uint64_t *first_host_time, bool *first_valid) SW_NONBLOCKING;

/// 消费者：跳过 frames 帧（不拷贝）；不够的只跳到有的位置。返回实际跳过帧数。
uint32_t sw_audio_ring_skip(sw_audio_ring *ring, uint32_t frames) SW_NONBLOCKING;

/// 最近一条 stamp（任何线程可调；无 stamp 返回 false）。
bool sw_audio_ring_latest_stamp(const sw_audio_ring *ring, sw_audio_stamp *out) SW_NONBLOCKING;
/// 倒数第 n 条 stamp（n = 0 最新）。没有那么多条时返回 false。
bool sw_audio_ring_stamp_from_latest(const sw_audio_ring *ring, uint32_t n, sw_audio_stamp *out) SW_NONBLOCKING;
/// 累计帧序号 frame_index 的 host time：找 frame_index ≤ 它的最近一条 stamp 外推；stamp 已被覆盖或不存在时返回 false。
bool sw_audio_ring_host_time_of(const sw_audio_ring *ring, uint64_t frame_index, double host_ticks_per_frame,
                                uint64_t *out) SW_NONBLOCKING;

// ============================================================================
// 2. 混音上下文的常量与公开的值类型
// ============================================================================

#define SW_MIX_MAX_INPUTS        32u   ///< 输入槽位上限（上下文创建时可少于它）
#define SW_MIX_BUS_COUNT         4u    ///< Master / A / B / Headphones（顺序 = 契约 Bus.rawValue）
#define SW_MIX_BUS_CHANNELS      2u    ///< 总线都是立体声
#define SW_MIX_MAX_BLOCK_FRAMES  4096u ///< 一次 sw_mix_block 最多的帧数（设备 buffer size 上限）
#define SW_MIX_MAX_DELAY_MS      500u  ///< 延迟补偿上限（契约 InputAudioSettings.delayRangeMs）
#define SW_MIX_MAX_DELAY_FRAMES  24000u ///< 500 ms @ 48 kHz
#define SW_MIX_EFFECTS_PER_BUS   3u    ///< EQ → Dynamics → Limiter
#define SW_MIX_EFFECTS_PER_INPUT 2u    ///< 每路输入两格：EQ → 动态（W1-D3，prompt 102）；重采样之后、延迟线之前
#define SW_MIX_MAX_TAPS          8u    ///< 消费者队列（编码 / 录制 / 表线程 / 测试）上限
#define SW_MIX_CMD_CAPACITY      256u  ///< 命令队列容量（2 的幂）
#define SW_MIX_MAX_CROSSFADES    8u    ///< 同时进行的 AFV 交叉淡变上限

enum sw_bus { SW_BUS_MASTER = 0, SW_BUS_A = 1, SW_BUS_B = 2, SW_BUS_HEADPHONES = 3 };
enum sw_effect { SW_EFFECT_EQ = 0, SW_EFFECT_DYNAMICS = 1, SW_EFFECT_LIMITER = 2 };
/// 每路输入的两格（W1-D3）：顺序固定 EQ → 动态；动态格里是苹果 DynamicsProcessor 还是自写压缩器由 sw_fx_kind 定。
enum sw_input_effect { SW_INPUT_EFFECT_EQ = 0, SW_INPUT_EFFECT_DYNAMICS = 1 };
/// 效果格的宿主（W1-D3 起效果类命令的 i2）：总线（index = 总线号，格 0…2）或输入槽位（index = 槽位，格 0…1）。0 = 总线，老命令兼容。
enum sw_fx_target { SW_FX_TARGET_BUS = 0, SW_FX_TARGET_INPUT = 1 };
/// 一格里跑什么：装着的 AudioUnit（NULL = 旁路），或自写 C 压缩器（提案 024 (b)）。运行期切换只改这一位，不动拓扑。
enum sw_fx_kind { SW_FX_KIND_AU = 0, SW_FX_KIND_COMPRESSOR = 1 };
/// 自写压缩器的参数编号（SW_CMD_FX_PARAM 的 i1）。时间常数在控制线程算成一阶系数再送进来（expf 不进回调）。
enum sw_comp_param {
    SW_COMP_THRESHOLD_DB = 0, SW_COMP_INV_RATIO = 1, SW_COMP_KNEE_DB = 2, SW_COMP_ALPHA_ATTACK = 3, SW_COMP_ALPHA_RELEASE = 4, SW_COMP_MAKEUP_LIN = 5,
};
enum sw_monitor_mode { SW_MONITOR_AFL = 0, SW_MONITOR_PFL = 1 };
/// 耳机总线从每路输入的哪一点取信号（W1-D2）：延迟线之前 = 不带对齐延迟 / 延迟补偿的低延迟监听（默认），之后 = 与节目同刻。
enum sw_monitor_point { SW_MONITOR_PRE_DELAY = 0, SW_MONITOR_POST_DELAY = 1 };
/// 消费者队列的来源编号：0…3 总线（总线增益之后）；SW_TAP_INPUT_BASE + 槽位 = 该输入推子后（含 AFV 门控，= 它送进总线的信号）；
/// SW_TAP_INPUT_PRE_AFV_BASE + 槽位 = 该输入推子后、AFV 门控前（含增益 / 静音 / 声像 / 延迟线；ISO 音轨用，W1-D2）。
#define SW_TAP_INPUT_BASE          16
#define SW_TAP_INPUT_PRE_AFV_BASE  64
/// 每路输入的重采样方式。
enum sw_resample_mode {
    SW_RESAMPLE_ESTIMATED = 0, ///< 异步重采样，比率由速率估计器给（默认）
    SW_RESAMPLE_LOCKED = 1,    ///< 比率锁 1.0，经过重采样器（测试用：确定性延迟）
    SW_RESAMPLE_BYPASS = 2,    ///< 不重采样直接拷贝（与输出设备同时钟的输入，例如聚合设备自己的输入）
};
/// 路由位（契约 BusRouting → 位）。
enum sw_routing_bits { SW_ROUTE_MASTER = 1u << 0, SW_ROUTE_A = 1u << 1, SW_ROUTE_B = 1u << 2, SW_ROUTE_HEADPHONES = 1u << 3 };

/// 速率估计器参数（W1-D 报告"估计器参数"一节；默认值见 sw_rate_params_default）。
typedef struct sw_rate_params {
    double level_tau_s;     ///< 占用（最老未消费帧的年龄）一阶低通时间常数，默认 0.25 s
    double rate_tau_s;      ///< 前馈速率比（stamps 测得）一阶低通时间常数，默认 10 s
    double rate_window_s;   ///< 每隔多久测一次前馈速率比，默认 1 s
    double loop_tau_s;      ///< PI 环自然时间常数 1/ωn，默认 8 s（临界阻尼）
    double max_deviation;   ///< 比率限幅 ±，默认 1e-3（±0.1%）
    uint32_t target_frames; ///< 设定点：环里平均保有帧数，默认 2 × 块
} sw_rate_params;

/// 一路输入槽位的公开统计（RT 写，快照读）。
typedef struct sw_input_stats {
    uint32_t attached;          ///< 有环挂着
    uint32_t primed;            ///< 已经填到设定点、正在稳定输出
    double   ratio;             ///< 当前重采样比（输出 / 输入）
    double   ratio_feedforward; ///< 前馈估计
    double   age_frames;        ///< 最老未消费帧的年龄（帧，含 stamps 外推），估计器控制的量
    double   age_setpoint;      ///< 它的设定点
    double   occupancy_filtered;///< 环占用的一阶低通（帧）
    uint64_t occupancy_frames;  ///< 本块开始时环里未消费的帧数（原始）
    uint32_t producer_block;    ///< 从 stamps 测出的生产者块大小（帧）
    uint64_t underrun_blocks;   ///< 已就绪后环不够用的块数（A1 口径）
    uint64_t reprimes;          ///< 掉出就绪后重新填充的次数
    uint64_t frames_consumed;   ///< 从环消费的帧数
    uint64_t frames_output;     ///< 重采样后送出的帧数
} sw_input_stats;

/// 一条总线的表读数（RT 写，快照读；线性峰值，LUFS / LU 响度）。
typedef struct sw_bus_meter {
    float  peak[SW_MIX_BUS_CHANNELS];       ///< 本块采样峰值（线性）
    float  mean_square[SW_MIX_BUS_CHANNELS];///< 推子后均方（线性功率，300 ms 一阶平均；提案 017 的 rms_db = 10·log10 在 Swift 侧算）
    float  true_peak[SW_MIX_BUS_CHANNELS];  ///< 本块真峰值（线性，4× 过采样，libebur128）
    float  peak_max[SW_MIX_BUS_CHANNELS];   ///< 自复位以来的最大采样峰值
    float  true_peak_max[SW_MIX_BUS_CHANNELS]; ///< 自复位以来的最大真峰值
    double momentary_lufs;   ///< EBU R128 M（400 ms），每 100 ms 更新
    double short_term_lufs;  ///< S（3 s）
    double integrated_lufs;  ///< I（门限积分，自复位起）
    double loudness_range_lu;///< LRA（Tech 3342）
} sw_bus_meter;

/// 一路输入的表读数。
typedef struct sw_input_meter {
    float peak[SW_MIX_BUS_CHANNELS];     ///< 推子后（含 AFV 增益）采样峰值
    float mean_square[SW_MIX_BUS_CHANNELS]; ///< 推子后均方（线性功率，300 ms 一阶平均，提案 017）
    float peak_max[SW_MIX_BUS_CHANNELS];
} sw_input_meter;

/// 表读数快照。
typedef struct sw_mix_meters {
    uint64_t block_sequence;                 ///< 快照对应的块序号
    sw_bus_meter bus[SW_MIX_BUS_COUNT];
    sw_input_meter input[SW_MIX_MAX_INPUTS];
} sw_mix_meters;

/// 混音器统计快照（累计值；audio{dropouts, underruns} 从这里进 Stats）。
typedef struct sw_mix_stats {
    uint64_t blocks_rendered;
    uint64_t frames_rendered;
    uint64_t dropouts;          ///< 回调超时（块处理时间 > 块时长）+ 设备 overload 通知
    uint64_t underruns;         ///< 已就绪输入的环欠载块数之和（A1）
    uint64_t rt_violations;     ///< 守卫记到的实时违规（A7）
    uint64_t commands_applied;  ///< 已应用的命令数（控制侧等确认用）
    uint64_t commands_dropped;  ///< 队列满而入队失败的命令数
    uint64_t tap_drops;         ///< 消费者队列满被丢的块数（不计入 A1）
    uint64_t max_block_ticks;   ///< 最长一次块处理时间（host tick）
    uint64_t last_block_ticks;  ///< 最近一次块处理时间
    uint64_t last_host_time;    ///< 最近一块的首样本 host time
    uint32_t last_block_frames;
    uint32_t input_count;
    sw_input_stats input[SW_MIX_MAX_INPUTS];
} sw_mix_stats;

// ============================================================================
// 2b. 自写压缩器（提案 024 (b)，W1-D3）：总线三格里的 1 号格与每路输入的动态格共用这一份实现
// ============================================================================

/// 前馈压缩器，不用前瞻、组延迟按设计 0 帧（装格 / 改参数时控制线程用 sw_compressor_probe_latency 冲激法复核）。
/// 检测器：立体声联动（取两路 |x| 的较大者）的"解耦峰值检测器"——释放级 r = max(d, αR·r + (1 − αR)·d)（瞬时起音、指数释放），
/// 再过一级起音一阶平滑 e += (r − e)(1 − αA)；稳态正弦的包络 ≈ 峰值（1 kHz / 释放 100 ms 时纹波 0.04 dB），静态曲线因此对得上 R:1。
/// 增益计算在 dB 域（Giannoulis / Massberg / Reiss 2012 的静态曲线）：阈值 T、比例 R、拐点宽 W：
///   over = x − T；over > W/2：y = T + over / R；|over| ≤ W/2：y = x + (1/R − 1)(over + W/2)² / (2W)；over < −W/2：y = x；增益 = y − x（≤ 0）+ 补偿。
/// 每样本一次 log2f + exp2f（libm 纯函数，check-rt-symbols 的允许清单内）；包络低于拐点下沿时不进 log。
/// 字段由命令在块边界改（RT 线程写），时间常数的一阶系数在控制线程算好（sw_compressor_alpha）。
typedef struct sw_compressor {
    float threshold_db;     ///< 阈值（dBFS，峰值口径）
    float inv_ratio;        ///< 1 / 比例（1…20 → 1…0.05）
    float knee_db;          ///< 拐点宽度 W（dB），0 = 硬拐点
    float alpha_attack;     ///< exp(−1 / (起音 · fs))
    float alpha_release;    ///< exp(−1 / (释放 · fs))
    float makeup_lin;       ///< 补偿增益（线性）
    float knee_lo_lin;      ///< 10^((T − W/2) / 20)：包络不超过它时增益恒 = 补偿（不进 log）
    float env_release;      ///< 状态：释放级（线性峰值）
    float env;              ///< 状态：起音平滑后的包络（线性）
} sw_compressor;

/// 跑一块。in / out 各 channels 个平面（1 或 2；可同址）；两路共用一个增益。
void sw_compressor_process(sw_compressor *c, const float *const *in, float *const *out, uint32_t channels, uint32_t frames) SW_NONBLOCKING;
/// 阈值 / 拐点改了之后重算 knee_lo_lin（命令应用处与 Host 初始化都调；exp2f 在允许清单内）。
static inline void sw_compressor_update_derived(sw_compressor *c) SW_NONBLOCKING {
    const float lo_db = c->threshold_db - 0.5f * c->knee_db;
    c->knee_lo_lin = exp2f(lo_db * 0.166096404744368f);   // 10^(dB/20) = 2^(dB · log2(10) / 20)
}

// ============================================================================
// 3. 命令（控制线程 → 实时线程，SPSC 队列，块开始时全部应用）
// ============================================================================

enum sw_cmd_type {
    SW_CMD_NONE = 0,
    SW_CMD_ATTACH_INPUT,      ///< index=槽位 ptr=sw_audio_ring* i0=重采样方式 i1=target_frames(0=默认)
                              ///< i2=目标年龄（帧；W1-D2）：就绪时从"host_time − 目标年龄"那一刻采到的帧起消费（按 stamps 找），
                              ///< 各路年龄一致且不带生产者相位；0 = 旧规则（从 write_index − back 起，年龄 = back + 相位）。
                              ///< 目标低于安全下限（back + 生产者块，见 sw_mix_ctx_deterministic_age_frames）时按下限就绪，年龄 > 目标。
    SW_CMD_DETACH_INPUT,      ///< index=槽位（应用后 ring 指针不再被读；控制侧等 commands_applied 再释放）
    SW_CMD_INPUT_GAIN,        ///< index=槽位 f0=线性增益
    SW_CMD_INPUT_MUTE,        ///< index=槽位 i0=0/1
    SW_CMD_INPUT_SOLO,        ///< index=槽位 i0=0/1
    SW_CMD_INPUT_PAN,         ///< index=槽位 f0=−1…1
    SW_CMD_INPUT_ROUTING,     ///< index=槽位 i0=sw_routing_bits
    SW_CMD_INPUT_DELAY,       ///< index=槽位 i0=延迟帧数 0…24000
    SW_CMD_INPUT_AFV_GAIN,    ///< index=槽位 f0=AFV 增益目标（立即，不经曲线）
    SW_CMD_INPUT_RESAMPLE,    ///< index=槽位 i0=sw_resample_mode
    SW_CMD_BUS_GAIN,          ///< index=总线 f0=线性增益
    SW_CMD_BUS_MUTE,          ///< index=总线 i0=0/1
    SW_CMD_EFFECT_ENABLE,     ///< index=宿主编号 i0=格 i1=0/1 i2=sw_fx_target（0 = 总线：老用法；1 = 输入槽位，W1-D3）
    SW_CMD_MONITOR_MODE,      ///< i0=sw_monitor_mode
    SW_CMD_CROSSFADE,         ///< i0=from 槽位(−1 无) i1=to 槽位(−1 无) i2=时长（帧，≥ 1；W1-D2 前是块） u0=起始 host time
    SW_CMD_TAP_ATTACH,        ///< index=tap 序号 ptr=sw_block_queue* i0=来源（0…3 总线；SW_TAP_INPUT_BASE / SW_TAP_INPUT_PRE_AFV_BASE + 槽位）
    SW_CMD_TAP_DETACH,        ///< index=tap 序号
    SW_CMD_RESET_METERS,      ///< 清 peak_max / 积分响度
    SW_CMD_RESET_STATS,       ///< 清计数（不清 blocks_rendered）
    SW_CMD_MONITOR_POINT,     ///< i0=sw_monitor_point（耳机总线取延迟线前 / 后；W1-D2）
    // ---- W1-D3（prompt 102）起 ----
    SW_CMD_FX_KIND,           ///< index=宿主编号 i0=格 i1=sw_fx_kind i2=sw_fx_target：这一格跑 AU 还是自写压缩器（只改指向，不动拓扑）
    SW_CMD_FX_PARAM,          ///< index=宿主编号 i0=格 i1=sw_comp_param i2=sw_fx_target f0=值（压缩器参数；阈值 / 拐点改了顺手重算 knee_lo_lin）
    SW_CMD_FX_POST_GAIN,      ///< index=宿主编号 i0=格 i2=sw_fx_target f0=线性：格内输出增益（peakLimiter.ceilingDb，渲染完乘系数，一阶平滑）
    SW_CMD_MONITOR_SOURCE,    ///< i0=总线号：耳机出口（out 平面 6 / 7）放这条总线（0 Master / 1 A / 2 B）；3 = 耳机总线自己（旧行为，默认）。有独听时总是耳机总线（提案 026）
    SW_CMD_MONITOR_BORROW_MASTER, ///< i0=0/1：开着且有独听时 Master 出口（out 平面 0 / 1）放耳机总线（2 声道设备上听独听，X09）；消费者队列不受影响
    // ---- W1-B5（prompt 120，D10）起 ----
    SW_CMD_CROSSFADE_REPLACE, ///< 参数同 SW_CMD_CROSSFADE，替换语义（Auto 中途按 Cut 的短淡收口；W1-D4 起 Cut / Auto 起点也用）：同槽位上**已经开始**的、
                              ///< 和**还没开始但起点比新的一条早**的淡变都照走到新淡变的起点，起点那一块里取消它们、从那一刻的 afv 起按 cos / sin
                              ///< 走到 0 / 1（起点之前不回弹到转场前的增益、起点不跳变，隔不到 ~60 ms 的两次切换前一条也听得到）；
                              ///< 同槽位上还没开始、起点不早于新的一条的在应用时就取消（最新的命令说了算）
    // ---- W1-D4（prompt 125）起 ----
    SW_CMD_CROSSFADE_FOLLOW,  ///< 参数同 SW_CMD_CROSSFADE，跟随曲线（Auto 进行中才开 AFV）：from 走 cos、to 走 sin 的绝对值（不乘起点 afv；
                              ///< 起点在过去时从该在的相位接上），接上那一刻与当时 afv 的差按增益平滑的 τ（3 ms）衰减掉——跟剩下的曲线走、不跳变。
                              ///< 接管同替换语义；应用时只撤同槽位上还没开始、起点**不晚于**它的（这条 Auto 原来那条），起点更晚的是之后的切换，留着接管它
};

typedef struct sw_cmd {
    uint32_t type;
    int32_t  index;
    int32_t  i0, i1, i2;
    float    f0;
    uint64_t u0;
    void    *ptr;
} sw_cmd;

// ============================================================================
// 4. 块队列（实时线程 → 消费者，SPSC；Master 块首样本 host time 作 PTS）
// ============================================================================

typedef struct sw_block_queue sw_block_queue; ///< 由 Host target 创建 / 销毁

/// 实时侧：推一块（拷贝）。队列满则丢并返回 false（消费者慢是消费者的问题，不拖实时线程）。
bool sw_block_queue_push(sw_block_queue *q, const float *const *planes, uint32_t channels, uint32_t frames,
                         uint64_t host_time, uint64_t sequence) SW_NONBLOCKING;
/// 消费者侧：弹一块到 planes（每个平面至少 max_block_frames 个 float）。空返回 false。
bool sw_block_queue_pop(sw_block_queue *q, float *const *planes, uint32_t *frames, uint64_t *host_time,
                        uint64_t *sequence) SW_NONBLOCKING;
/// 队列里等待的块数。
uint32_t sw_block_queue_count(const sw_block_queue *q) SW_NONBLOCKING;
/// 累计被丢的块数。
uint64_t sw_block_queue_dropped(const sw_block_queue *q) SW_NONBLOCKING;
/// 队列参数。
uint32_t sw_block_queue_channels(const sw_block_queue *q) SW_NONBLOCKING;
uint32_t sw_block_queue_max_frames(const sw_block_queue *q) SW_NONBLOCKING;

// ============================================================================
// 5. 混音块（热路径入口）
// ============================================================================

typedef struct sw_mix_ctx sw_mix_ctx; ///< 由 Host target 创建 / 销毁

/// 混一块。`out` 是 8 个平面指针：[Master L, Master R, A L, A R, B L, B R, HP L, HP R]，为 NULL 的不写。
/// frames ≤ max_block_frames；host_time = 本块首样本在输出设备时间线上的 host time（IOProc 的 inOutputTime，
/// 离线 / 空设备驱动用合成时间线）。做的事按设计方案 §3.5 顺序：命令 → 每路 取样 / 重采样 / 延迟 / 增益静音独听声像 /
/// 送总线 → 每条总线 效果链 / 总线增益 / 表 → 写输出 → 送消费者队列。
void sw_mix_block(sw_mix_ctx *ctx, float *const *out, uint32_t frames, uint64_t host_time) SW_NONBLOCKING;

/// 混音块的大小上限（创建时定）。
uint32_t sw_mix_ctx_max_block_frames(const sw_mix_ctx *ctx) SW_NONBLOCKING;
/// 每帧 host tick（实时侧可调）。
double sw_mix_ctx_host_ticks_per_frame_rt(const sw_mix_ctx *ctx) SW_NONBLOCKING;
/// 已应用的命令数（release 发布；控制侧 acquire 读）。
uint64_t sw_mix_ctx_commands_applied(const sw_mix_ctx *ctx) SW_NONBLOCKING;
/// 设备层报告一次 overload（kAudioDeviceProcessorOverload），计进 dropouts。任何线程。
void sw_mix_ctx_note_overload(sw_mix_ctx *ctx) SW_NONBLOCKING;

// ============================================================================
// 6. 设备 IOProc（CoreAudio HAL；设备层 Swift 用 AudioDeviceCreateIOProcID 把它挂到设备上）
// ============================================================================

/// 设备通道在 AudioBufferList 里的位置：mBuffers[buffer].mData 的第 offset 个 float 起、每帧跨 stride 个 float。
/// HAL 给的是设备原生布局（内置扬声器是 1 个 buffer 2 声道交错；有些接口每声道一个 buffer），Swift 从 StreamConfiguration 算好。
typedef struct sw_channel_location {
    uint32_t buffer;
    uint32_t offset;
    uint32_t stride;
} sw_channel_location;

/// 一个 IOProc 客户端：可同时带输出（混音 → 设备）与输入（设备 → 环，聚合设备 / 带输入的接口）。Host target 创建 / 配置。
typedef struct sw_device_client sw_device_client;

/// IOProc 本体。输出：调 sw_mix_block（host_time = inOutputTime->mHostTime，首样本呈现时刻）后按布局散到设备缓冲；
/// 输入：按布局收集到非交错缓冲后 sw_audio_ring_write（host_time = inInputTime->mHostTime）。
/// 参数可空性照 CoreAudio 的 AudioDeviceIOProc typedef 标（Swift 才能把它当 AudioDeviceIOProc 传）。
OSStatus sw_device_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now, const AudioBufferList *_Nonnull input,
                          const AudioTimeStamp *_Nonnull input_time, AudioBufferList *_Nonnull output,
                          const AudioTimeStamp *_Nonnull output_time, void *_Nullable client) SW_NONBLOCKING;

/// 客户端统计（RT 写，快照读）。
typedef struct sw_device_client_stats {
    uint64_t callbacks;             ///< 回调次数
    uint64_t frames;                ///< 输出帧数
    uint32_t last_frames;           ///< 最近一次回调的帧数（= 实际 buffer size）
    uint32_t reserved0;
    uint64_t nominal_period_ticks;  ///< 按最近帧数算的名义回调周期
    uint64_t max_jitter_ticks;      ///< |两次回调间隔 − 名义周期| 的最大值
    uint64_t jitter_hist[32];       ///< 直方图：每桶 100 µs（桶 31 = ≥ 3.1 ms）
    uint64_t max_lead_ticks;        ///< 回调进入时刻到 inOutputTime 的最大提前量
    uint64_t min_lead_ticks;        ///< 最小提前量（越小越接近欠载）
    uint64_t input_frames_written;  ///< 写进环的输入帧数
    uint64_t input_overruns;        ///< 环满被丢
    uint64_t timestamp_fallbacks;   ///< 时间戳没有 HostTimeValid、用 mach_absolute_time 兜底的次数
} sw_device_client_stats;

#ifdef __cplusplus
}
#endif
#endif /* SW_AUDIO_RT_H */
