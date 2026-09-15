// sw_device_internal.h —— IOProc 客户端的内部布局（RT 读，Host 分配 / 配置）。不放 include/：Swift 不看。
#ifndef SW_DEVICE_INTERNAL_H
#define SW_DEVICE_INTERNAL_H
#include "sw_audio_rt.h"

#define SW_DEVICE_MAX_CHANNELS 64u
#define SW_DEVICE_OUT_LOGICAL 8u   ///< Master L R / A L R / B L R / HP L R

struct sw_device_client {
    sw_mix_ctx *ctx;                                   ///< NULL = 纯输入客户端
    uint32_t max_block;
    // 输出
    int32_t out_map[SW_DEVICE_OUT_LOGICAL];            ///< 逻辑通道 → 设备通道（−1 不输出）
    sw_channel_location out_layout[SW_DEVICE_MAX_CHANNELS];
    uint32_t out_channel_count;
    float *out_scratch[SW_DEVICE_OUT_LOGICAL];
    uint8_t out_zero_unmapped;                         ///< 未映射的设备通道写 0
    // 输入
    sw_audio_ring *in_ring;                            ///< 原子读写；NULL 无输入
    int32_t in_map[SW_AUDIO_MAX_CHANNELS];             ///< 环声道 → 设备输入通道（−1 = 写 0）
    sw_channel_location in_layout[SW_DEVICE_MAX_CHANNELS];
    uint32_t in_channel_count;
    float *in_scratch[SW_AUDIO_MAX_CHANNELS];
    // 统计
    uint64_t last_entry;
    sw_device_client_stats st;
};

#endif
