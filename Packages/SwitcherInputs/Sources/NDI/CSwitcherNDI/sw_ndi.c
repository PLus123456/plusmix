// NDI SDK 的 C 封装实现。SDK 头只在这里包含（原因见 sw_ndi.h 头注释）。
#include "sw_ndi.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#if SWITCHER_HAS_NDI_SDK
#include <Processing.NDI.Lib.h>

_Static_assert(SW_NDI_FOURCC_UYVY == (uint32_t)NDIlib_FourCC_video_type_UYVY, "UYVY FourCC");
_Static_assert(SW_NDI_FOURCC_UYVA == (uint32_t)NDIlib_FourCC_video_type_UYVA, "UYVA FourCC");
_Static_assert(SW_NDI_FOURCC_BGRA == (uint32_t)NDIlib_FourCC_video_type_BGRA, "BGRA FourCC");
_Static_assert(SW_NDI_FOURCC_BGRX == (uint32_t)NDIlib_FourCC_video_type_BGRX, "BGRX FourCC");
_Static_assert(SW_NDI_FOURCC_RGBA == (uint32_t)NDIlib_FourCC_video_type_RGBA, "RGBA FourCC");
_Static_assert(SW_NDI_FOURCC_RGBX == (uint32_t)NDIlib_FourCC_video_type_RGBX, "RGBX FourCC");
_Static_assert(SW_NDI_FOURCC_NV12 == (uint32_t)NDIlib_FourCC_video_type_NV12, "NV12 FourCC");
_Static_assert(SW_NDI_FOURCC_I420 == (uint32_t)NDIlib_FourCC_video_type_I420, "I420 FourCC");
_Static_assert(SW_NDI_FOURCC_P216 == (uint32_t)NDIlib_FourCC_video_type_P216, "P216 FourCC");
_Static_assert(SW_NDI_FOURCC_PA16 == (uint32_t)NDIlib_FourCC_video_type_PA16, "PA16 FourCC");
_Static_assert(SW_NDI_BANDWIDTH_LOWEST == (int)NDIlib_recv_bandwidth_lowest, "bandwidth lowest");
_Static_assert(SW_NDI_BANDWIDTH_AUDIO_ONLY == (int)NDIlib_recv_bandwidth_audio_only, "bandwidth audio only");
_Static_assert(SW_NDI_BANDWIDTH_HIGHEST == (int)NDIlib_recv_bandwidth_highest, "bandwidth highest");
_Static_assert(SW_NDI_FRAME_STATUS_CHANGE == (int)NDIlib_frame_type_status_change, "status change");
_Static_assert(SW_NDI_FRAME_SOURCE_CHANGE == (int)NDIlib_frame_type_source_change, "source change");

int sw_ndi_sdk_compiled(void) { return 1; }
const char* sw_ndi_version(void) { return NDIlib_version(); }

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static int g_init_ok = 0;
static void sw_ndi_do_initialize(void) { g_init_ok = NDIlib_initialize() ? 1 : 0; }
int sw_ndi_initialize(void) {
    pthread_once(&g_init_once, sw_ndi_do_initialize);
    return g_init_ok;
}

// ---- 发现 ----

struct sw_ndi_finder {
    NDIlib_find_instance_t f;
};

sw_ndi_finder* sw_ndi_finder_create(int show_local_sources, const char* groups, const char* extra_ips) {
    if (!sw_ndi_initialize()) return NULL;
    NDIlib_find_create_t desc;
    memset(&desc, 0, sizeof desc);
    desc.show_local_sources = show_local_sources != 0;
    desc.p_groups = groups;
    desc.p_extra_ips = extra_ips;
    NDIlib_find_instance_t f = NDIlib_find_create_v2(&desc);
    if (!f) return NULL;
    sw_ndi_finder* out = (sw_ndi_finder*)calloc(1, sizeof *out);
    out->f = f;
    return out;
}

void sw_ndi_finder_destroy(sw_ndi_finder* finder) {
    if (!finder) return;
    NDIlib_find_destroy(finder->f);
    free(finder);
}

int sw_ndi_finder_wait(sw_ndi_finder* finder, uint32_t timeout_ms) {
    return finder && NDIlib_find_wait_for_sources(finder->f, timeout_ms) ? 1 : 0;
}

int sw_ndi_finder_sources(sw_ndi_finder* finder, sw_ndi_source* out, int max_count) {
    if (!finder) return 0;
    uint32_t n = 0;
    const NDIlib_source_t* list = NDIlib_find_get_current_sources(finder->f, &n);
    for (int i = 0; i < (int)n && i < max_count; i++) {
        out[i].name = list[i].p_ndi_name;
        out[i].url = list[i].p_url_address;
    }
    return (int)n;
}

// ---- 接收 ----

struct sw_ndi_recv {
    NDIlib_recv_instance_t r;
    NDIlib_video_frame_v2_t video;
    NDIlib_audio_frame_v3_t audio;
    int has_video;
    int has_audio;
};

sw_ndi_recv* sw_ndi_recv_create(const char* source_name, const char* source_url, sw_ndi_bandwidth bandwidth,
                                int allow_video_fields, const char* receiver_name) {
    if (!sw_ndi_initialize()) return NULL;
    NDIlib_recv_create_v3_t desc;
    memset(&desc, 0, sizeof desc);
    desc.source_to_connect_to.p_ndi_name = source_name;
    desc.source_to_connect_to.p_url_address = source_url;
    desc.color_format = NDIlib_recv_color_format_UYVY_BGRA;
    desc.bandwidth = (NDIlib_recv_bandwidth_e)bandwidth;
    desc.allow_video_fields = allow_video_fields != 0;
    desc.p_ndi_recv_name = receiver_name;
    NDIlib_recv_instance_t r = NDIlib_recv_create_v3(&desc);
    if (!r) return NULL;
    sw_ndi_recv* out = (sw_ndi_recv*)calloc(1, sizeof *out);
    out->r = r;
    return out;
}

void sw_ndi_recv_destroy(sw_ndi_recv* recv) {
    if (!recv) return;
    sw_ndi_recv_free_video(recv);
    sw_ndi_recv_free_audio(recv);
    NDIlib_recv_destroy(recv->r);
    free(recv);
}

void sw_ndi_recv_connect(sw_ndi_recv* recv, const char* source_name, const char* source_url) {
    if (!recv) return;
    if (!source_name) {
        NDIlib_recv_connect(recv->r, NULL);
        return;
    }
    NDIlib_source_t src;
    memset(&src, 0, sizeof src);
    src.p_ndi_name = source_name;
    src.p_url_address = source_url;
    NDIlib_recv_connect(recv->r, &src);
}

int sw_ndi_recv_connections(sw_ndi_recv* recv) { return recv ? NDIlib_recv_get_no_connections(recv->r) : 0; }

int sw_ndi_recv_set_tally(sw_ndi_recv* recv, int on_program, int on_preview) {
    if (!recv) return 0;
    NDIlib_tally_t t;
    t.on_program = on_program != 0;
    t.on_preview = on_preview != 0;
    return NDIlib_recv_set_tally(recv->r, &t) ? 1 : 0;
}

sw_ndi_frame_type sw_ndi_recv_capture(sw_ndi_recv* recv, sw_ndi_video_frame* video, sw_ndi_audio_frame* audio, uint32_t timeout_ms) {
    if (!recv) return SW_NDI_FRAME_NONE;
    sw_ndi_recv_free_video(recv);
    sw_ndi_recv_free_audio(recv);
    memset(&recv->video, 0, sizeof recv->video);
    memset(&recv->audio, 0, sizeof recv->audio);
    NDIlib_frame_type_e t = NDIlib_recv_capture_v3(recv->r, &recv->video, &recv->audio, NULL, timeout_ms);
    switch (t) {
    case NDIlib_frame_type_video:
        recv->has_video = 1;
        if (video) {
            video->width = recv->video.xres;
            video->height = recv->video.yres;
            video->fourcc = (uint32_t)recv->video.FourCC;
            video->frame_rate_n = recv->video.frame_rate_N;
            video->frame_rate_d = recv->video.frame_rate_D;
            video->progressive = recv->video.frame_format_type == NDIlib_frame_format_type_progressive ? 1 : 0;
            video->timecode = recv->video.timecode;
            video->timestamp = recv->video.timestamp;
            video->data = recv->video.p_data;
            video->line_stride = recv->video.line_stride_in_bytes;
            video->metadata = recv->video.p_metadata;
        }
        return SW_NDI_FRAME_VIDEO;
    case NDIlib_frame_type_audio:
        recv->has_audio = 1;
        if (audio) {
            audio->sample_rate = recv->audio.sample_rate;
            audio->channels = recv->audio.no_channels;
            audio->samples = recv->audio.no_samples;
            audio->timecode = recv->audio.timecode;
            audio->timestamp = recv->audio.timestamp;
            audio->data = recv->audio.p_data;
            audio->channel_stride = recv->audio.channel_stride_in_bytes;
        }
        return SW_NDI_FRAME_AUDIO;
    case NDIlib_frame_type_metadata:
        return SW_NDI_FRAME_METADATA;
    case NDIlib_frame_type_error:
        return SW_NDI_FRAME_ERROR;
    case NDIlib_frame_type_status_change:
        return SW_NDI_FRAME_STATUS_CHANGE;
    case NDIlib_frame_type_source_change:
        return SW_NDI_FRAME_SOURCE_CHANGE;
    default:
        return SW_NDI_FRAME_NONE;
    }
}

void sw_ndi_recv_free_video(sw_ndi_recv* recv) {
    if (recv && recv->has_video) {
        NDIlib_recv_free_video_v2(recv->r, &recv->video);
        recv->has_video = 0;
    }
}

void sw_ndi_recv_free_audio(sw_ndi_recv* recv) {
    if (recv && recv->has_audio) {
        NDIlib_recv_free_audio_v3(recv->r, &recv->audio);
        recv->has_audio = 0;
    }
}

void sw_ndi_recv_get_stats(sw_ndi_recv* recv, sw_ndi_recv_stats* out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!recv) return;
    NDIlib_recv_performance_t total, dropped;
    memset(&total, 0, sizeof total);
    memset(&dropped, 0, sizeof dropped);
    NDIlib_recv_get_performance(recv->r, &total, &dropped);
    NDIlib_recv_queue_t q;
    memset(&q, 0, sizeof q);
    NDIlib_recv_get_queue(recv->r, &q);
    out->video_total = total.video_frames;
    out->video_dropped = dropped.video_frames;
    out->audio_total = total.audio_frames;
    out->audio_dropped = dropped.audio_frames;
    out->queue_video = q.video_frames;
    out->queue_audio = q.audio_frames;
}

// ---- 发送 ----

struct sw_ndi_send {
    NDIlib_send_instance_t s;
};

sw_ndi_send* sw_ndi_send_create(const char* name, const char* groups, int clock_video, int clock_audio) {
    if (!sw_ndi_initialize()) return NULL;
    NDIlib_send_create_t desc;
    memset(&desc, 0, sizeof desc);
    desc.p_ndi_name = name;
    desc.p_groups = groups;
    desc.clock_video = clock_video != 0;
    desc.clock_audio = clock_audio != 0;
    NDIlib_send_instance_t s = NDIlib_send_create(&desc);
    if (!s) return NULL;
    sw_ndi_send* out = (sw_ndi_send*)calloc(1, sizeof *out);
    out->s = s;
    return out;
}

void sw_ndi_send_destroy(sw_ndi_send* send) {
    if (!send) return;
    NDIlib_send_destroy(send->s);
    free(send);
}

void sw_ndi_send_video(sw_ndi_send* send, const sw_ndi_video_frame* frame) {
    if (!send || !frame) return;
    NDIlib_video_frame_v2_t v;
    memset(&v, 0, sizeof v);
    v.xres = frame->width;
    v.yres = frame->height;
    v.FourCC = (NDIlib_FourCC_video_type_e)frame->fourcc;
    v.frame_rate_N = frame->frame_rate_n;
    v.frame_rate_D = frame->frame_rate_d;
    v.picture_aspect_ratio = 0.0f;
    v.frame_format_type = frame->progressive ? NDIlib_frame_format_type_progressive : NDIlib_frame_format_type_interleaved;
    v.timecode = frame->timecode ? frame->timecode : NDIlib_send_timecode_synthesize;
    v.p_data = (uint8_t*)frame->data;
    v.line_stride_in_bytes = frame->line_stride;
    v.p_metadata = frame->metadata;
    NDIlib_send_send_video_v2(send->s, &v);
}

void sw_ndi_send_audio(sw_ndi_send* send, const sw_ndi_audio_frame* frame) {
    if (!send || !frame) return;
    NDIlib_audio_frame_v3_t a;
    memset(&a, 0, sizeof a);
    a.sample_rate = frame->sample_rate;
    a.no_channels = frame->channels;
    a.no_samples = frame->samples;
    a.timecode = frame->timecode ? frame->timecode : NDIlib_send_timecode_synthesize;
    a.FourCC = NDIlib_FourCC_audio_type_FLTP;
    a.p_data = (uint8_t*)frame->data;
    a.channel_stride_in_bytes = frame->channel_stride;
    NDIlib_send_send_audio_v3(send->s, &a);
}

int sw_ndi_send_get_tally(sw_ndi_send* send, int* on_program, int* on_preview, uint32_t timeout_ms) {
    if (!send) return 0;
    NDIlib_tally_t t;
    memset(&t, 0, sizeof t);
    bool changed = NDIlib_send_get_tally(send->s, &t, timeout_ms);
    if (on_program) *on_program = t.on_program ? 1 : 0;
    if (on_preview) *on_preview = t.on_preview ? 1 : 0;
    return changed ? 1 : 0;
}

int sw_ndi_send_connections(sw_ndi_send* send, uint32_t timeout_ms) {
    return send ? NDIlib_send_get_no_connections(send->s, timeout_ms) : 0;
}

const char* sw_ndi_send_source_name(sw_ndi_send* send) {
    if (!send) return "";
    const NDIlib_source_t* s = NDIlib_send_get_source_name(send->s);
    return s && s->p_ndi_name ? s->p_ndi_name : "";
}

#else  // ---- 没有 SDK：空实现 ----

int sw_ndi_sdk_compiled(void) { return 0; }
const char* sw_ndi_version(void) { return ""; }
int sw_ndi_initialize(void) { return 0; }
sw_ndi_finder* sw_ndi_finder_create(int a, const char* b, const char* c) { (void)a; (void)b; (void)c; return NULL; }
void sw_ndi_finder_destroy(sw_ndi_finder* f) { (void)f; }
int sw_ndi_finder_wait(sw_ndi_finder* f, uint32_t t) { (void)f; (void)t; return 0; }
int sw_ndi_finder_sources(sw_ndi_finder* f, sw_ndi_source* o, int m) { (void)f; (void)o; (void)m; return 0; }
sw_ndi_recv* sw_ndi_recv_create(const char* a, const char* b, sw_ndi_bandwidth c, int d, const char* e) { (void)a; (void)b; (void)c; (void)d; (void)e; return NULL; }
void sw_ndi_recv_destroy(sw_ndi_recv* r) { (void)r; }
void sw_ndi_recv_connect(sw_ndi_recv* r, const char* a, const char* b) { (void)r; (void)a; (void)b; }
int sw_ndi_recv_connections(sw_ndi_recv* r) { (void)r; return 0; }
int sw_ndi_recv_set_tally(sw_ndi_recv* r, int a, int b) { (void)r; (void)a; (void)b; return 0; }
sw_ndi_frame_type sw_ndi_recv_capture(sw_ndi_recv* r, sw_ndi_video_frame* v, sw_ndi_audio_frame* a, uint32_t t) { (void)r; (void)v; (void)a; (void)t; return SW_NDI_FRAME_NONE; }
void sw_ndi_recv_free_video(sw_ndi_recv* r) { (void)r; }
void sw_ndi_recv_free_audio(sw_ndi_recv* r) { (void)r; }
void sw_ndi_recv_get_stats(sw_ndi_recv* r, sw_ndi_recv_stats* o) { (void)r; if (o) memset(o, 0, sizeof *o); }
sw_ndi_send* sw_ndi_send_create(const char* a, const char* b, int c, int d) { (void)a; (void)b; (void)c; (void)d; return NULL; }
void sw_ndi_send_destroy(sw_ndi_send* s) { (void)s; }
void sw_ndi_send_video(sw_ndi_send* s, const sw_ndi_video_frame* f) { (void)s; (void)f; }
void sw_ndi_send_audio(sw_ndi_send* s, const sw_ndi_audio_frame* f) { (void)s; (void)f; }
int sw_ndi_send_get_tally(sw_ndi_send* s, int* a, int* b, uint32_t t) { (void)s; (void)t; if (a) *a = 0; if (b) *b = 0; return 0; }
int sw_ndi_send_connections(sw_ndi_send* s, uint32_t t) { (void)s; (void)t; return 0; }
const char* sw_ndi_send_source_name(sw_ndi_send* s) { (void)s; return ""; }

#endif

// ---- 与 SDK 无关的拷贝 / 打包 ----

void sw_ndi_pack_uyvy_from_nv12(const uint8_t* luma, int luma_stride, const uint8_t* chroma, int chroma_stride,
                                int width, int height, uint8_t* dst) {
    for (int y = 0; y < height; y++) {
        const uint8_t* ly = luma + (size_t)y * (size_t)luma_stride;
        const uint8_t* cy = chroma + (size_t)(y / 2) * (size_t)chroma_stride;
        uint8_t* d = dst + (size_t)y * (size_t)width * 2;
        for (int x = 0; x + 1 < width; x += 2) {
            d[0] = cy[x];       // Cb
            d[1] = ly[x];       // Y0
            d[2] = cy[x + 1];   // Cr
            d[3] = ly[x + 1];   // Y1
            d += 4;
        }
    }
}

void sw_ndi_unpack_uyvy_to_nv12(const uint8_t* src, int src_stride, int width, int height,
                                uint8_t* luma, int luma_stride, uint8_t* chroma, int chroma_stride) {
    for (int y = 0; y < height; y++) {
        const uint8_t* s = src + (size_t)y * (size_t)src_stride;
        uint8_t* ly = luma + (size_t)y * (size_t)luma_stride;
        for (int x = 0; x + 1 < width; x += 2) {
            ly[x] = s[1];
            ly[x + 1] = s[3];
            s += 4;
        }
    }
    for (int cy = 0; cy < height / 2; cy++) {
        const uint8_t* s0 = src + (size_t)(cy * 2) * (size_t)src_stride;
        const uint8_t* s1 = src + (size_t)(cy * 2 + 1) * (size_t)src_stride;
        uint8_t* c = chroma + (size_t)cy * (size_t)chroma_stride;
        for (int x = 0; x + 1 < width; x += 2) {
            c[x] = (uint8_t)(((int)s0[0] + (int)s1[0] + 1) / 2);
            c[x + 1] = (uint8_t)(((int)s0[2] + (int)s1[2] + 1) / 2);
            s0 += 4;
            s1 += 4;
        }
    }
}

int sw_ndi_copy_video(const sw_ndi_video_frame* frame, CVPixelBufferRef dst) {
    if (!frame || !dst || !frame->data) return -1;
    OSType dst_format = CVPixelBufferGetPixelFormatType(dst);
    int bpp;
    if (frame->fourcc == SW_NDI_FOURCC_UYVY || frame->fourcc == SW_NDI_FOURCC_UYVA) {
        if (dst_format != kCVPixelFormatType_422YpCbCr8) return -1;
        bpp = 2;
    } else if (frame->fourcc == SW_NDI_FOURCC_BGRA || frame->fourcc == SW_NDI_FOURCC_BGRX) {
        if (dst_format != kCVPixelFormatType_32BGRA) return -1;
        bpp = 4;
    } else {
        return -1;
    }
    if ((int)CVPixelBufferGetWidth(dst) != frame->width || (int)CVPixelBufferGetHeight(dst) != frame->height) return -1;
    size_t src_stride = frame->line_stride > 0 ? (size_t)frame->line_stride : (size_t)frame->width * (size_t)bpp;
    size_t row_bytes = (size_t)frame->width * (size_t)bpp;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return -1;
    uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(dst);
    size_t dst_stride = CVPixelBufferGetBytesPerRow(dst);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return -1;
    }
    if (dst_stride == src_stride && src_stride == row_bytes) {
        memcpy(base, frame->data, row_bytes * (size_t)frame->height);
    } else {
        const uint8_t* src = frame->data;
        for (int y = 0; y < frame->height; y++) {
            memcpy(base + (size_t)y * dst_stride, src + (size_t)y * src_stride, row_bytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return 0;
}
