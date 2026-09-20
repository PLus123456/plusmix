// CSwitcherNDI —— NDI SDK 的 C 封装（W3-A）。
//
// 为什么要这一层而不是像 SwitcherOutputs 那样直接挂一个系统库模块 `NDI`：App 同时链接 SwitcherOutputs（NDI 发送）和本包（NDI 接收），
// SwiftPM 不许两个包有同名 target，clang 也不许同一份 SDK 头出现在两个模块里。所以 SDK 头只在 sw_ndi.c 里包含，
// 这里只暴露我们自己的类型和函数；Swift 侧（SwitcherNDI）只见这个头。
//
// SDK 不在（Package.swift 探测不到 Processing.NDI.Lib.h）时本层编成空实现：sw_ndi_sdk_compiled() == 0，其余函数返回 NULL / 0。
// 所有函数都不是实时热路径（在输入自己的接收线程上调），允许阻塞、分配。
#ifndef SW_NDI_H
#define SW_NDI_H

#include <stddef.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 编译时是否带了 NDI SDK。
int sw_ndi_sdk_compiled(void);
/// NDIlib_version() 的字串；没编进 SDK 时 ""。
const char* sw_ndi_version(void);
/// NDIlib_initialize()：进程内只真正调一次（之后返回同一结果）。1 = 成功。
int sw_ndi_initialize(void);

// ---- 源发现（NDIlib_find）----

typedef struct sw_ndi_finder sw_ndi_finder;
/// 建发现器；show_local_sources = 1 时本机的源也列出来。groups / extra_ips 可为 NULL。失败 NULL。
sw_ndi_finder* sw_ndi_finder_create(int show_local_sources, const char* groups, const char* extra_ips);
void sw_ndi_finder_destroy(sw_ndi_finder* finder);
/// 等源列表变化，最多 timeout_ms；变了返回 1。
int sw_ndi_finder_wait(sw_ndi_finder* finder, uint32_t timeout_ms);
/// 一个源：name = "机器名 (源名)"，url = 网络地址（可能为 NULL）。字串指向发现器内部缓冲，下次 sw_ndi_finder_sources 前有效。
typedef struct sw_ndi_source {
    const char* name;
    const char* url;
} sw_ndi_source;
/// 当前源列表（不等待）：填最多 max_count 个到 out，返回总数（可能 > max_count）。
int sw_ndi_finder_sources(sw_ndi_finder* finder, sw_ndi_source* out, int max_count);

// ---- 帧 ----

/// FourCC（与 NDIlib_FourCC_video_type_e 数值相同，sw_ndi.c 里有 _Static_assert 钉住）。
static const uint32_t SW_NDI_FOURCC_UYVY = 0x59565955u;   // 'UYVY'
static const uint32_t SW_NDI_FOURCC_UYVA = 0x41565955u;   // 'UYVA'：UYVY 平面后面紧跟一个 alpha 平面
static const uint32_t SW_NDI_FOURCC_BGRA = 0x41524742u;   // 'BGRA'
static const uint32_t SW_NDI_FOURCC_BGRX = 0x58524742u;   // 'BGRX'
static const uint32_t SW_NDI_FOURCC_RGBA = 0x41424752u;   // 'RGBA'
static const uint32_t SW_NDI_FOURCC_RGBX = 0x58424752u;   // 'RGBX'
static const uint32_t SW_NDI_FOURCC_NV12 = 0x3231564Eu;   // 'NV12'
static const uint32_t SW_NDI_FOURCC_I420 = 0x30323449u;   // 'I420'
static const uint32_t SW_NDI_FOURCC_P216 = 0x36313250u;   // 'P216'
static const uint32_t SW_NDI_FOURCC_PA16 = 0x36314150u;   // 'PA16'

/// 发送端没给时间戳时 timestamp 的值（NDIlib_recv_timestamp_undefined = INT64_MAX）。
static const int64_t SW_NDI_TIMESTAMP_UNDEFINED = INT64_MAX;

/// 一帧视频。接收时 data 由 SDK 持有，用完必须 sw_ndi_recv_free_video；发送时 data 由调用方给。
typedef struct sw_ndi_video_frame {
    int width;
    int height;
    uint32_t fourcc;
    int frame_rate_n;
    int frame_rate_d;
    /// 1 = 逐行；0 = 交错帧或单场。
    int progressive;
    /// 100 ns 单位的时间码（发送端给的）。
    int64_t timecode;
    /// 100 ns 单位：发送端 SDK 在提交这帧那一刻打的戳（发送端系统时钟）；没有 = SW_NDI_TIMESTAMP_UNDEFINED。发送时忽略。
    int64_t timestamp;
    const uint8_t* data;
    /// 行距（字节），0 = 紧凑。
    int line_stride;
    const char* metadata;
} sw_ndi_video_frame;

/// 一块音频：FLTP（float32 非交错），channels 个平面，每个 channel_stride 字节。
typedef struct sw_ndi_audio_frame {
    int sample_rate;
    int channels;
    int samples;
    int64_t timecode;
    int64_t timestamp;
    const uint8_t* data;
    int channel_stride;
} sw_ndi_audio_frame;

// ---- 接收（NDIlib_recv）----

typedef enum sw_ndi_bandwidth {
    SW_NDI_BANDWIDTH_LOWEST = 0,        // 低带宽 / 低分辩率的视频 + 音频
    SW_NDI_BANDWIDTH_AUDIO_ONLY = 10,   // 只要音频
    SW_NDI_BANDWIDTH_HIGHEST = 100      // 全分辩率
} sw_ndi_bandwidth;

typedef enum sw_ndi_frame_type {
    SW_NDI_FRAME_NONE = 0,
    SW_NDI_FRAME_VIDEO = 1,
    SW_NDI_FRAME_AUDIO = 2,
    SW_NDI_FRAME_METADATA = 3,
    SW_NDI_FRAME_ERROR = 4,
    SW_NDI_FRAME_STATUS_CHANGE = 100,
    SW_NDI_FRAME_SOURCE_CHANGE = 101
} sw_ndi_frame_type;

typedef struct sw_ndi_recv sw_ndi_recv;
/// 建接收器：色彩格式固定 UYVY_BGRA（无 alpha 给 UYVY，有 alpha 给 BGRA）。source_url 可为 NULL（SDK 内部按名发现）。
/// receiver_name 是我们在发送端那里显示的名字，可为 NULL。失败 NULL。
sw_ndi_recv* sw_ndi_recv_create(const char* source_name, const char* source_url, sw_ndi_bandwidth bandwidth,
                                int allow_video_fields, const char* receiver_name);
void sw_ndi_recv_destroy(sw_ndi_recv* recv);
/// 换 / 重连源（源重开后地址变了时用）。source_name 为 NULL = 断开。
void sw_ndi_recv_connect(sw_ndi_recv* recv, const char* source_name, const char* source_url);
/// 当前连着的发送端数量（0 = 没连上）。
int sw_ndi_recv_connections(sw_ndi_recv* recv);
/// tally 回传给源。返回 1 = 已发出。
int sw_ndi_recv_set_tally(sw_ndi_recv* recv, int on_program, int on_preview);
/// 收一帧，最多等 timeout_ms。返回类型；VIDEO 时填 video、AUDIO 时填 audio。
/// 上一帧如果还没 free，这里会先 free 掉（防漏）。
sw_ndi_frame_type sw_ndi_recv_capture(sw_ndi_recv* recv, sw_ndi_video_frame* video, sw_ndi_audio_frame* audio, uint32_t timeout_ms);
void sw_ndi_recv_free_video(sw_ndi_recv* recv);
void sw_ndi_recv_free_audio(sw_ndi_recv* recv);

typedef struct sw_ndi_recv_stats {
    int64_t video_total;
    int64_t video_dropped;   // SDK 侧因为我们取得不够快而丢的
    int64_t audio_total;
    int64_t audio_dropped;
    int queue_video;         // SDK 队列里还没取的
    int queue_audio;
} sw_ndi_recv_stats;
void sw_ndi_recv_get_stats(sw_ndi_recv* recv, sw_ndi_recv_stats* out);

/// NV12（双平面）→ 紧凑 UYVY，逐像素打包（测试发送端 / 工具用；不在 SDK 也能用）。dst 至少 width × height × 2 字节。
void sw_ndi_pack_uyvy_from_nv12(const uint8_t* luma, int luma_stride, const uint8_t* chroma, int chroma_stride,
                                int width, int height, uint8_t* dst);
/// UYVY → NV12（双平面，色度取相邻两行平均）。测试解码用。
void sw_ndi_unpack_uyvy_to_nv12(const uint8_t* src, int src_stride, int width, int height,
                                uint8_t* luma, int luma_stride, uint8_t* chroma, int chroma_stride);

/// 把 UYVY / BGRA / BGRX 帧拷进已锁好尺寸的 CVPixelBuffer（'2vuy' 或 BGRA，尺寸相同）；行距不同时逐行拷。
/// 返回 0 成功，-1 格式 / 尺寸不匹配。不在 SDK 也能用（纯拷贝）。
int sw_ndi_copy_video(const sw_ndi_video_frame* frame, CVPixelBufferRef dst);

// ---- 发送（NDIlib_send；只给回环测试用，产品里的发送在 SwitcherOutputs 的 SwitcherNDISend）----

typedef struct sw_ndi_send sw_ndi_send;
sw_ndi_send* sw_ndi_send_create(const char* name, const char* groups, int clock_video, int clock_audio);
void sw_ndi_send_destroy(sw_ndi_send* send);
/// 同步发送一帧（SDK 拷走数据，返回后 data 可复用）。
void sw_ndi_send_video(sw_ndi_send* send, const sw_ndi_video_frame* frame);
void sw_ndi_send_audio(sw_ndi_send* send, const sw_ndi_audio_frame* frame);
/// 接收端回传的 tally，最多等 timeout_ms 变化。返回 1 = 有变化 / 有值。
int sw_ndi_send_get_tally(sw_ndi_send* send, int* on_program, int* on_preview, uint32_t timeout_ms);
int sw_ndi_send_connections(sw_ndi_send* send, uint32_t timeout_ms);
/// 这个发送端在网络上的完整源名（"机器名 (name)"），有效期到 destroy。
const char* sw_ndi_send_source_name(sw_ndi_send* send);

#ifdef __cplusplus
}
#endif
#endif
