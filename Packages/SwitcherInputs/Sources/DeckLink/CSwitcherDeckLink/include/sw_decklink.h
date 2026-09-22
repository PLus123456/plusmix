// CSwitcherDeckLink —— Blackmagic DeckLink SDK 的 C++ 桥接（W3-A），对 Swift 只暴露这份 C API。
//
// 层次：
//   Swift DeckLinkInput（状态、看门狗、热插拔、帧槽 / 环）
//     └─ 这份 C API
//          └─ C++ 桥接（sw_decklink_bridge.cpp）：IDeckLinkInputCallback 实现——格式自动检测重开、UYVY / BGRA 帧拷进 CVPixelBuffer 池、
//             硬件参考时钟 ↔ host time 一阶滤波校准、内嵌音频 int16 / int32 交错 → float32 平面、无信号标志
//               ├─ 真设备：sw_decklink_devices.cpp（IDeckLinkIterator 枚举、IDeckLinkDiscovery 热插拔）
//               └─ Fake IDeckLinkInput（sw_decklink_fake.cpp）：C++ 假对象，实现同一组 COM 接口，测试用它驱动三条路径
//
// SDK 不在（Package.swift 探测不到 DeckLinkAPI.h）时：sw_decklink_sdk_compiled() == 0，枚举返回 0 台，打开会话失败并给文案，
// Fake 相关函数返回 NULL。校准器（纯数学）任何时候都在。
// 所有回调都在 DeckLink 驱动自己的线程上发生（不是渲染 / 音频实时线程）；回调里允许拷贝 / 分配，但要快（一帧 1080p UYVY 4 MB 一次 memcpy）。
#ifndef SW_DECKLINK_H
#define SW_DECKLINK_H

#include <stddef.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 编译 / 运行环境 ----

/// 编译时是否带了 DeckLink SDK。
int sw_decklink_sdk_compiled(void);
/// 编进来的 SDK 头文件版本，如 "10.11.2"；没编进 SDK 时 ""。
const char* sw_decklink_sdk_version(void);
/// 运行时 Desktop Video 驱动（/Library/Frameworks/DeckLinkAPI.framework）是否能加载。
int sw_decklink_api_present(void);
/// 驱动版本字串（IDeckLinkAPIInformation）；没有驱动时 buf[0] = 0。返回 buf。
const char* sw_decklink_driver_version(char* buf, size_t size);

// ---- 设备 ----

/// 一台设备。persistent_id 是我们给 `InputSource.decklink(deviceID:)` 用的持久标识：
/// 有 BMDDeckLinkPersistentID 属性时 "peid:<十进制 int64>"；没有时 "model:<型号>#<同型号内序号>"。
typedef struct sw_decklink_device_info {
    char persistent_id[48];
    char model_name[128];
    char display_name[128];
    /// 输入接口位集（BMDVideoConnection：SDI 1, HDMI 2, OpticalSDI 4, Component 8, Composite 16, SVideo 32）。
    uint32_t input_connections;
    int supports_input_format_detection;
    /// 有 IDeckLinkInput 接口（纯输出卡没有）。
    int has_input;
    /// 迭代顺序。
    int index;
} sw_decklink_device_info;

/// 枚举设备：填最多 max_count 台到 out，返回总数。没有驱动 / SDK → 0。
int sw_decklink_enumerate(sw_decklink_device_info* out, int max_count);

/// 热插拔通知（IDeckLinkDiscovery）。arrived = 1 设备来了，0 被拔。回调在驱动线程上。
typedef void (*sw_decklink_hotplug_fn)(void* context, const sw_decklink_device_info* device, int arrived);
/// 订阅；返回 token（> 0），失败（没驱动 / SDK）返回 0。
int sw_decklink_hotplug_subscribe(sw_decklink_hotplug_fn fn, void* context);
void sw_decklink_hotplug_unsubscribe(int token);

// ---- 会话 ----

typedef struct sw_decklink_session sw_decklink_session;

/// 视频格式（检测结果）。
typedef struct sw_decklink_video_format {
    /// BMDDisplayMode 四字码（如 'Hp60'）。
    uint32_t display_mode;
    int32_t width;
    int32_t height;
    /// 帧率 = time_scale / frame_duration。
    int64_t frame_duration;
    int64_t time_scale;
    /// BMDPixelFormat：'2vuy'（UYVY）或 'BGRA'。
    uint32_t pixel_format;
    /// 1 = 隔行 / psf（场序不是 progressive）。
    int32_t interlaced;
    char name[64];
} sw_decklink_video_format;

/// 一帧视频的附带信息。
typedef struct sw_decklink_frame_info {
    /// 采集时刻：硬件参考时间经校准换算成的 host tick（没有硬件参考钟时 = arrival_host）。
    uint64_t pts_host;
    /// 回调入口的 host tick。
    uint64_t arrival_host;
    /// 帧时长（host tick）。
    int64_t duration_host;
    uint64_t sequence;
    int32_t width;
    int32_t height;
    uint32_t pixel_format;
    /// 1 = pts 经过硬件钟校准；0 = 退回到达时刻。
    int32_t calibrated;
    /// 本帧的校准残差 o_k − o（ns）。
    int64_t calibration_residual_ns;
} sw_decklink_frame_info;

/// 一块音频的附带信息。
typedef struct sw_decklink_audio_info {
    /// 首样本 host tick。
    uint64_t host_time;
    int32_t channel_count;
    int32_t frame_count;
    int32_t sample_rate;
} sw_decklink_audio_info;

typedef struct sw_decklink_callbacks {
    void* context;
    /// 格式检测：重开完成后报新格式。
    void (*format_changed)(void* context, const sw_decklink_video_format* format);
    /// 一帧视频：pixel_buffer 在回调期间有效（+0），要留就自己 retain。
    void (*video_frame)(void* context, CVPixelBufferRef pixel_buffer, const sw_decklink_frame_info* info);
    /// 一块音频：planes 有 channel_count 个 float32 平面，只在回调期间有效。
    void (*audio_packet)(void* context, const float* const* planes, const sw_decklink_audio_info* info);
    /// 信号：1 = 有信号；0 = 帧带 bmdFrameHasNoInputSource（线拔了 / 没信号源）。只在变化时报。
    void (*signal_changed)(void* context, int present);
    /// 出错文案（重开失败之类），只报不停。
    void (*error)(void* context, const char* message);
} sw_decklink_callbacks;

typedef struct sw_decklink_session_config {
    /// 选哪台（sw_decklink_enumerate 的 persistent_id）；NULL 或 "" = 第一台有输入的。
    const char* persistent_id;
    /// 输入接口（BMDVideoConnection 单个位）；0 = 不改卡上的当前设置。
    uint32_t connection;
    /// 起始显示模式（BMDDisplayMode）；0 = 设备列表里第一个。格式检测一开就会改成真实的。
    uint32_t initial_display_mode;
    /// 内嵌音频声道数（2–16）；0 = 不开音频。
    int32_t audio_channels;
    /// bmdAudioSampleType：16 或 32。
    int32_t audio_sample_type;
    /// 校准一阶滤波 α = 1 / 2^shift；默认（0）= 5，即 1/32。
    int32_t calibration_shift;
    /// 像素池上限；默认（0）= 8。
    int32_t max_pool_buffers;
} sw_decklink_session_config;

/// 打开真设备的会话（不起流）。失败 NULL，文案写进 err。
sw_decklink_session* sw_decklink_session_open(const sw_decklink_session_config* config, const sw_decklink_callbacks* callbacks,
                                              char* err, size_t err_size);
/// 起流：SetCallback → EnableVideoInput(初始模式, 8-bit YUV, 格式检测) → EnableAudioInput → StartStreams。失败返回 -1 并写 err。
int sw_decklink_session_start(sw_decklink_session* session, char* err, size_t err_size);
/// 停流（StopStreams / Disable*），回调不再来。可重复。
void sw_decklink_session_stop(sw_decklink_session* session);
/// 释放（会先 stop）。
void sw_decklink_session_close(sw_decklink_session* session);

typedef struct sw_decklink_session_stats {
    uint64_t frames_received;        // VideoInputFrameArrived 给的视频帧
    uint64_t frames_delivered;       // 交给 video_frame 回调的帧
    uint64_t frames_no_source;       // 带 bmdFrameHasNoInputSource 的帧
    uint64_t frames_dropped_pool;    // 池到上限
    uint64_t frames_dropped_format;  // 尺寸 / 格式与当前不符（重开中间的帧）
    uint64_t audio_packets;
    uint64_t format_changes;
    uint64_t reopen_failures;
    int64_t calibration_offset_ns;   // 当前 o（host − hw）
    int64_t residual_max_abs_ns;     // |o_k − o| 的最大值
    double residual_rms_ns;
    uint64_t residual_samples;
    int has_hardware_clock;          // GetHardwareReferenceClock 可用
    int signal_present;              // -1 未知 / 0 无 / 1 有
    sw_decklink_video_format current_format;
} sw_decklink_session_stats;
void sw_decklink_session_get_stats(sw_decklink_session* session, sw_decklink_session_stats* out);

// ---- 时间戳校准器（纯数学，SDK 不在也有）----
//
// 方法（设计方案 §3.6 "DeckLink 用回调给的参考时间加上入口时的 host time 校准"）：
//   每次回调入口背靠背读 host_now（mach_absolute_time）和 hw_now（IDeckLinkInput::GetHardwareReferenceClock，纳秒刻度），
//   o_k = host_now − hw_now 是两个钟的瞬时差；一阶低通 o ← o + (o_k − o) / 2^shift（第一个样本直接采用）。
//   帧的采集时刻 = 帧的硬件参考时间戳（GetHardwareReferenceTimestamp）+ o。残差 o_k − o 反映两次读钟之间的抢占抖动，
//   报告里写它的最大值 / RMS。
typedef struct sw_decklink_calibrator {
    int64_t offset_ns;
    int32_t shift;
    uint64_t samples;
    int64_t last_residual_ns;
    int64_t max_abs_residual_ns;
    double sum_sq_residual;
} sw_decklink_calibrator;
void sw_decklink_calibrator_init(sw_decklink_calibrator* c, int32_t shift);
/// 喂一对样本，返回残差 o_k − o（滤波前）。
int64_t sw_decklink_calibrator_observe(sw_decklink_calibrator* c, int64_t host_now_ns, int64_t hw_now_ns);
/// 硬件时间 → host 时间（ns）。
int64_t sw_decklink_calibrator_map(const sw_decklink_calibrator* c, int64_t hw_time_ns);
/// 残差 RMS（ns）。
double sw_decklink_calibrator_residual_rms(const sw_decklink_calibrator* c);

// ---- Fake IDeckLinkInput（SDK 在时才有）----
//
// 一个实现了 IDeckLinkInput / IDeckLinkDisplayModeIterator / IDeckLinkDisplayMode / IDeckLinkVideoInputFrame / IDeckLinkAudioInputPacket
// 的 C++ 假设备。桥接层对它和对真卡走同一段代码；测试用下面的 emit 函数在调用线程上同步触发桥接层的回调。
typedef struct sw_decklink_fake sw_decklink_fake;
sw_decklink_fake* sw_decklink_fake_create(void);
void sw_decklink_fake_destroy(sw_decklink_fake* fake);
/// 对着假设备打开会话（不经过设备枚举）。
sw_decklink_session* sw_decklink_session_open_fake(sw_decklink_fake* fake, const sw_decklink_session_config* config,
                                                   const sw_decklink_callbacks* callbacks, char* err, size_t err_size);
/// 假设备记下的调用（桥接层对它做了什么）。
typedef struct sw_decklink_fake_log {
    int32_t enable_video_calls;
    uint32_t last_display_mode;
    uint32_t last_pixel_format;
    uint32_t last_input_flags;
    int32_t disable_video_calls;
    int32_t enable_audio_calls;
    uint32_t last_audio_sample_rate;
    uint32_t last_audio_sample_type;
    uint32_t last_audio_channels;
    int32_t disable_audio_calls;
    int32_t start_calls;
    int32_t stop_calls;
    int32_t pause_calls;
    int32_t flush_calls;
    int32_t callback_set;      // 当前有没有回调对象挂着
    int32_t hardware_clock_calls;
} sw_decklink_fake_log;
void sw_decklink_fake_get_log(sw_decklink_fake* fake, sw_decklink_fake_log* out);
/// GetHardwareReferenceClock 返回什么（纳秒刻度；桥接层按请求的 timeScale 换算）。
void sw_decklink_fake_set_hardware_clock(sw_decklink_fake* fake, int64_t hw_now_ns);
/// 让假设备不支持硬件参考钟（GetHardwareReferenceClock 返回 E_NOTIMPL）。
void sw_decklink_fake_set_hardware_clock_supported(sw_decklink_fake* fake, int supported);
/// 触发 VideoInputFormatChanged。detected_flags：bmdDetectedVideoInputYCbCr422 = 1、RGB444 = 2；events：DisplayModeChanged = 1。
void sw_decklink_fake_emit_format_changed(sw_decklink_fake* fake, uint32_t display_mode, int32_t width, int32_t height,
                                          int64_t frame_duration, int64_t time_scale, uint32_t field_dominance,
                                          uint32_t detected_flags, uint32_t events);
/// 一帧（+ 可选音频包）。
typedef struct sw_decklink_fake_frame {
    int32_t width;
    int32_t height;
    int32_t row_bytes;
    uint32_t pixel_format;          // '2vuy' / 'BGRA'
    const void* bytes;              // 可为 NULL（无信号帧）
    uint32_t flags;                 // bmdFrameHasNoInputSource = 1u << 31
    int64_t hw_time_ns;             // GetHardwareReferenceTimestamp 给的帧时刻（纳秒刻度）
    int64_t hw_duration_ns;
    int64_t stream_time_ns;         // GetStreamTime
    int32_t hw_timestamp_supported; // 0 = GetHardwareReferenceTimestamp 返回 E_NOTIMPL
    // 音频（audio_bytes 为 NULL = 没有音频包）
    const void* audio_bytes;        // 交错 int16 / int32
    int32_t audio_frames;
    int32_t audio_channels;
    int32_t audio_sample_type;      // 16 / 32
    int64_t audio_packet_time_ns;   // GetPacketTime（流时间）
} sw_decklink_fake_frame;
void sw_decklink_fake_emit_frame(sw_decklink_fake* fake, const sw_decklink_fake_frame* frame);

#ifdef __cplusplus
}
#endif
#endif
