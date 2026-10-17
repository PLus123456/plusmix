// sw_mix_internal.h —— 混音上下文的内部布局。RT target 读写，Host target 分配 / 释放 / 拷快照（通过 headerSearchPath 引用）。
// 故意不放在 include/ 里：Swift 不看这个文件（sw_mix_ctx / sw_block_queue 对 Swift 是 OpaquePointer）。字段的"写者"注明在注释里；跨线程读的字段用原子读。
#ifndef SW_MIX_INTERNAL_H
#define SW_MIX_INTERNAL_H

#include "sw_audio_rt.h"
#include <samplerate.h>
#include <ebur128.h>
#include <AudioToolbox/AudioUnit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 延迟线：容量 2 的幂 ≥ 最大延迟 + 最大块；write_pos 单调递增（取模）。
typedef struct sw_delay_line {
    float   *buf[SW_MIX_BUS_CHANNELS];
    uint32_t capacity;
    uint32_t mask;
    uint32_t write_pos;
    uint32_t delay_frames;   ///< 当前延迟（帧）；命令改，块边界生效
} sw_delay_line;

/// 一格效果：装着的 AudioUnit（kind = AU；NULL = 旁路）或自写压缩器（kind = COMPRESSOR，状态内嵌、预分配）。总线三格与每路两格同一种结构（W1-D3）。
typedef struct sw_effect_slot {
    AudioUnit unit;               ///< NULL = 未装（Host 原子换指针）
    uint8_t   enabled;            ///< 命令改，块边界生效
    uint8_t   kind;               ///< sw_fx_kind（命令改）
    sw_compressor comp;           ///< 自写压缩器（提案 024 (b)）：参数由命令改，状态只在 RT 写；Host 只在该格不被 render 时复位
    float     post_gain_target;   ///< 格内输出增益（peakLimiter.ceilingDb）目标（线性，默认 1）
    float     post_gain;          ///< 一阶平滑后的当前值
    const float *in[SW_MIX_BUS_CHANNELS]; ///< 输入回调交给 AU 的指针
    uint32_t  in_frames;
    struct {
        AudioBufferList list;     ///< mNumberBuffers = 2
        AudioBuffer     second;
    } out_list;
} sw_effect_slot;

struct sw_input_slot;

/// libsamplerate 回调上下文（每声道一个）：记录"已交给重采样器"的帧序号。
typedef struct sw_pull_ctx {
    struct sw_input_slot *slot;
    uint32_t channel;
    uint64_t handed;     ///< 已确认被重采样器吞掉的累计帧序号（与 ring 的帧序号同一计数）
    uint32_t pending;    ///< 上一次交出去、尚未确认的帧数（libsamplerate 下次要数据时即已消费）
} sw_pull_ctx;

/// 速率估计器状态（每路一个）。算法与参数见 sw_mix.c 顶部注释和报告。
typedef struct sw_rate_state {
    sw_rate_params p;
    double alpha_level;     ///< 年龄低通系数（每块）
    double alpha_rate;      ///< 前馈低通系数（每个测量窗）
    double kp, ki;          ///< PI 增益：每帧误差 → 比率；每帧·秒 → 比率
    double level_filt;      ///< 年龄的低通值（帧）
    double integ;           ///< 误差积分（帧·秒）
    double ratio_ff;        ///< 前馈：输出速率 / 输入速率
    double ratio;           ///< 当前给重采样器的比率
    double age_setpoint;    ///< 年龄设定点（帧）
    double block_seconds;   ///< 上一块的时长（秒），积分用
    uint32_t producer_block;///< 从 stamps 测出的生产者块大小
    int      have_level;
    int      have_ff;
    int      win_valid;
    uint64_t win_in_frame, win_in_host, win_out_frame, win_out_host;
} sw_rate_state;

/// 一路输入槽位。
typedef struct sw_input_slot {
    sw_audio_ring *ring;          ///< RT 写（attach / detach 命令），NULL = 空闲
    uint32_t channels;            ///< 参与混音的声道数：1 或 2（环声道数 > 2 时取前两路）
    uint32_t resample_mode;       ///< sw_resample_mode
    uint32_t target_frames;       ///< 估计器设定点（环里平均保有帧数）
    uint32_t target_age_frames;   ///< 就绪目标年龄（帧；0 = 旧规则）。W1-D2
    uint32_t prime_wait_blocks;   ///< 目标年龄模式下"数据够了但目标那一帧还不合适"已等了几块（超限退回旧规则）
    uint32_t chunk_frames;        ///< 每次交给重采样器的帧数（ctx->resampler_chunk 的拷贝）
    uint32_t ring_mask;           ///< ring->capacity_frames − 1 的拷贝
    SRC_STATE *src[SW_MIX_BUS_CHANNELS];
    sw_pull_ctx pull[SW_MIX_BUS_CHANNELS];
    uint64_t consumed;            ///< 已消费（已交给重采样器 / bypass 已读）的帧序号；发布成 ring->read_index
    double   input_pos;           ///< 重采样器 sinc 中心的输入位置（帧，含小数）：每块按 frames / ratio 积分，
                                  ///< 再钳到 [handed − 半长 − 块, handed − 半长]（libsamplerate 取样时的确定关系）
    sw_effect_slot fx[SW_MIX_EFFECTS_PER_INPUT]; ///< W1-D3：EQ → 动态，重采样之后、延迟线之前（延迟线 / 推子 / 耳机 / ISO 都看到效果后的信号）
    float *fxwork[SW_MIX_BUS_CHANNELS];    ///< 效果链乒乓（与 resampled 交替；单声道输入 [1] 当第二路暂存）
    uint64_t fx_sample_time;               ///< 每路效果格的 AU 渲染时间戳（帧）
    sw_delay_line delay;
    float gain_target, gain;      ///< 线性增益（静音时目标 0）
    float pan_target, pan;        ///< −1 … 1
    float afv_target, afv;        ///< AFV 增益（交叉淡变改它）
    float afv_fade_start;         ///< 本次淡变起点的 afv 值
    uint32_t routing;             ///< sw_routing_bits
    uint8_t  muted, solo;
    uint8_t  primed;              ///< 已填到设定点
    uint8_t  attached;
    uint32_t stall_blocks;        ///< write_index 连续多少块没动
    uint64_t last_write_index;
    uint32_t underrun_frames_block; ///< 本块补零帧数（回调里累加）
    sw_rate_state rate;
    sw_input_stats st;            ///< 快照读
    float peak_max[SW_MIX_BUS_CHANNELS];
    float peak_block[SW_MIX_BUS_CHANNELS];
    float rms_sq[SW_MIX_BUS_CHANNELS];      ///< 推子后均方的一阶平均（提案 017），每块更新
    float *resampled[SW_MIX_BUS_CHANNELS]; ///< 重采样输出（max_block）
    float *delayed[SW_MIX_BUS_CHANNELS];   ///< 延迟线输出
    float *post[SW_MIX_BUS_CHANNELS];      ///< 推子后（增益 / 静音 / AFV / 声像）立体声
    const float *zeros;                    ///< 欠载时交给重采样器的零块（ctx 共享）
} sw_input_slot;

/// 一条总线。
typedef struct sw_bus_state {
    float *sum[SW_MIX_BUS_CHANNELS];      ///< 输入送来的和
    float *work[SW_MIX_BUS_CHANNELS];     ///< 效果链乒乓
    float *interleaved;                   ///< 表用的交错缓冲（2 × max_block）
    sw_effect_slot fx[SW_MIX_EFFECTS_PER_BUS];
    float gain_target, gain;
    uint8_t muted;
    ebur128_state *meter;                 ///< EBUR128_MODE_HISTOGRAM
    uint32_t frames_since_meter_update;
    uint64_t sample_time;                 ///< AU 渲染时间戳（帧）
    sw_bus_meter m;
    float rms_sq[SW_MIX_BUS_CHANNELS];       ///< 总线均方的一阶平均（提案 017）
} sw_bus_state;

/// 一次 AFV 交叉淡变。
typedef struct sw_crossfade {
    int32_t  from, to;          ///< 槽位；−1 = 无
    uint32_t duration_frames;
    uint64_t start_host;        ///< 起点 host time（块首样本 ≥ 它的那一块里按样本定位）
    uint64_t elapsed_frames;    ///< 已走过的帧数
    uint8_t  active, started;
    uint8_t  replace;           ///< SW_CMD_CROSSFADE_REPLACE：起点那一块才接管同槽位上别的淡变、才取起点 afv（W1-B5，D10）
} sw_crossfade;

/// 消费者队列挂点。
typedef struct sw_tap {
    sw_block_queue *q;
    int32_t source;             ///< 0…3 总线；SW_TAP_INPUT_BASE + 槽位 = 该输入推子后（含 AFV）；SW_TAP_INPUT_PRE_AFV_BASE + 槽位 = 推子后 AFV 前
} sw_tap;

/// 命令队列（SPSC：控制线程写 tail，实时线程写 head）。
typedef struct sw_cmd_queue {
    sw_cmd   cmds[SW_MIX_CMD_CAPACITY];
    uint8_t  pad0[64];
    uint64_t tail;              ///< 生产者（控制线程）
    uint8_t  pad1[56];
    uint64_t head;              ///< 消费者（实时线程）
    uint8_t  pad2[56];
} sw_cmd_queue;

/// 块队列本体。
struct sw_block_queue {
    uint32_t capacity;          ///< 2 的幂
    uint32_t mask;
    uint32_t channels;
    uint32_t max_frames;
    float   *data;              ///< capacity × channels × max_frames
    uint32_t *frames;           ///< 每块帧数
    uint64_t *host_times;
    uint64_t *sequences;
    uint8_t  pad0[64];
    uint64_t write;             ///< 生产者（实时线程）
    uint64_t dropped;
    uint8_t  pad1[48];
    uint64_t read;              ///< 消费者
    uint8_t  pad2[56];
};

/// 混音上下文本体。
struct sw_mix_ctx {
    uint32_t sample_rate;
    uint32_t max_block_frames;
    uint32_t default_block_frames;
    uint32_t input_capacity;
    uint32_t resampler_chunk;
    int      resampler_converter_saved;
    uint32_t resampler_latency;   ///< sinc 半长 hf（帧）：libsamplerate 在"手里 ≤ hf 帧"时才取下一段
    uint32_t meter_interval_frames;
    uint32_t monitor_mode;
    uint32_t monitor_point;       ///< sw_monitor_point：耳机取延迟线前（0，calloc 的默认）/ 后。W1-D2
    uint32_t monitor_source;      ///< 耳机出口放哪条总线（0…2），SW_BUS_HEADPHONES = 耳机总线自己（旧行为；Host 创建时置它）。提案 026，W1-D3
    uint32_t borrow_master;       ///< 1 = 有独听时 Master 出口放耳机总线（X09）。W1-D3
    double   host_ticks_per_frame;
    float    gain_smooth_k;       ///< 增益 / AFV 一阶平滑每样本系数 1 − exp(−1 / (τ · fs))，τ = 3 ms，创建时算好
    sw_rate_params rate_defaults;
    sw_input_slot inputs[SW_MIX_MAX_INPUTS];
    sw_bus_state buses[SW_MIX_BUS_COUNT];
    sw_crossfade xfades[SW_MIX_MAX_CROSSFADES];
    sw_tap taps[SW_MIX_MAX_TAPS];
    sw_cmd_queue cmds;
    uint64_t cmds_pushed;         ///< 控制线程写
    uint64_t cmds_dropped;        ///< 控制线程写
    float   *zeros;               ///< max_block 个 0
    float   *xfade_gain[SW_MIX_MAX_CROSSFADES][2]; ///< 每条淡变 from / to 的每样本增益曲线（max_block）
    uint32_t timing_check;        ///< 1 = 用真实时钟检查块处理超时（实时驱动置 1，离线不置）
    uint64_t timeouts;            ///< 超时次数（dropouts 的一部分）
    // 表快照（seqlock：RT 写，其他线程读）
    uint32_t meter_seq;
    sw_mix_meters meters;
    // 统计（RT 写；overloads 由设备层线程原子加）
    sw_mix_stats stats;
    uint64_t overloads;
    uint64_t block_sequence;
};

/// AU 输入回调（RT target 定义，Host 装进 AU）。
OSStatus sw_effect_input_proc(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 bus, UInt32 frames, AudioBufferList *ioData);
/// libsamplerate 回调（RT target 定义，Host 建重采样器时传入）。
long sw_input_pull(void *cb_data, float **data);

#ifdef __cplusplus
}
#endif
#endif /* SW_MIX_INTERNAL_H */
