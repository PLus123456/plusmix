// 一路 DeckLink 输入会话：IDeckLinkInputCallback 的实现。
//
// - 格式自动检测：EnableVideoInput 带 bmdVideoInputEnableFormatDetection；VideoInputFormatChanged 里 Pause → Enable(新模式, 按检测标志选
//   8-bit YUV / BGRA) → Flush → Start，然后报 format_changed。
// - 帧：VideoInputFrameArrived 里把 UYVY / BGRA 拷进 CVPixelBufferPool（IOSurface、Metal 可用）的缓冲，一次 memcpy（逐行或整块）。
//   bmdFrameHasNoInputSource 的帧不拷、只报 signal_changed(0)。
// - 时间戳：回调入口背靠背读 mach_absolute_time 和 GetHardwareReferenceClock，一阶滤波校准（sw_decklink_calibrator）；
//   帧的 pts = GetHardwareReferenceTimestamp + 偏移。设备不支持硬件参考钟时 pts = 入口时刻。
// - 音频：IDeckLinkAudioInputPacket 的 int16 / int32 交错 → float32 平面（scratch 复用）；包的流时间经"同一回调里视频帧的
//   硬件时间 − 流时间"换到硬件钟再校准到 host。
// - 线程：回调都在驱动线程；stop() 先置 running = false 再 StopStreams（不在持锁时调 SDK 的流控制，避免与回调死锁）。
#include "sw_decklink.h"

#include <cstdio>
#include <cstring>

#if SWITCHER_HAS_DECKLINK_SDK
#include "sw_decklink_internal.hpp"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <vector>
#include <mach/mach_time.h>

namespace {

constexpr BMDTimeScale kNanoScale = 1000000000LL;

int64_t host_now_ns(mach_timebase_info_data_t tb) {
    return (int64_t)((__uint128_t)mach_absolute_time() * tb.numer / tb.denom);
}
uint64_t host_ticks_from_ns(int64_t ns, mach_timebase_info_data_t tb) {
    if (ns < 0) return 0;
    return (uint64_t)((__uint128_t)ns * tb.denom / tb.numer);
}

class Session : public IDeckLinkInputCallback {
public:
    Session(IDeckLinkInput* input, IDeckLinkConfiguration* config, IDeckLinkStatus* status,
            const sw_decklink_session_config& cfg, const sw_decklink_callbacks& cb)
        : input_(input), config_(config), status_(status), cfg_(cfg), cb_(cb) {
        input_->AddRef();
        if (config_) config_->AddRef();
        if (status_) status_->AddRef();
        mach_timebase_info(&timebase_);
        sw_decklink_calibrator_init(&calib_, cfg.calibration_shift);
        max_pool_ = cfg.max_pool_buffers > 0 ? cfg.max_pool_buffers : 8;
        std::memset(&current_, 0, sizeof current_);
    }

    ~Session() override {
        stop();
        if (pool_) CVPixelBufferPoolRelease(pool_);
        input_->Release();
        if (config_) config_->Release();
        if (status_) status_->Release();
    }

    // ---- IUnknown ----
    HRESULT QueryInterface(REFIID iid, LPVOID* ppv) override {
        if (!ppv) return E_POINTER;
        if (swdl::iid_equal(iid, IID_IDeckLinkInputCallback)) {
            AddRef();
            *ppv = static_cast<IDeckLinkInputCallback*>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refcount_; }
    ULONG Release() override {
        ULONG r = --refcount_;
        if (r == 0) delete this;
        return r;
    }

    // ---- 控制 ----
    int start(char* err, size_t err_size) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (running_) return 0;
        if (cfg_.connection && config_) {
            if (config_->SetInt(bmdDeckLinkConfigVideoInputConnection, (int64_t)cfg_.connection) != S_OK) {
                report_error("设置输入接口失败（卡不支持这个接口）");
            }
        }
        BMDDisplayMode mode = pick_initial_mode();
        input_->SetCallback(this);
        BMDVideoInputFlags flags = bmdVideoInputEnableFormatDetection;
        HRESULT hr = input_->EnableVideoInput(mode, bmdFormat8BitYUV, flags);
        if (hr != S_OK) {
            flags = bmdVideoInputFlagDefault;
            hr = input_->EnableVideoInput(mode, bmdFormat8BitYUV, flags);
            if (hr == S_OK) report_error("这块卡不支持格式自动检测，按起始模式采集");
        }
        if (hr != S_OK) {
            input_->SetCallback(nullptr);
            std::snprintf(err, err_size, "EnableVideoInput 失败（hr=0x%08x）", (unsigned)hr);
            return -1;
        }
        current_.pixel_format = bmdFormat8BitYUV;
        audio_enabled_ = false;
        if (cfg_.audio_channels > 0) {
            BMDAudioSampleType st = cfg_.audio_sample_type == 16 ? bmdAudioSampleType16bitInteger : bmdAudioSampleType32bitInteger;
            hr = input_->EnableAudioInput(bmdAudioSampleRate48kHz, st, (uint32_t)cfg_.audio_channels);
            if (hr == S_OK) {
                audio_enabled_ = true;
                audio_sample_type_ = st;
            } else {
                report_error("EnableAudioInput 失败：这路没有内嵌音频");
            }
        }
        hr = input_->StartStreams();
        if (hr != S_OK) {
            input_->DisableVideoInput();
            if (audio_enabled_) input_->DisableAudioInput();
            input_->SetCallback(nullptr);
            std::snprintf(err, err_size, "StartStreams 失败（hr=0x%08x）", (unsigned)hr);
            return -1;
        }
        running_ = true;
        return 0;
    }

    void stop() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!running_) return;
            running_ = false;
        }
        input_->StopStreams();
        {
            // 等正在进行的回调退出
            std::lock_guard<std::mutex> lock(mutex_);
        }
        input_->SetCallback(nullptr);
        input_->DisableVideoInput();
        if (audio_enabled_) input_->DisableAudioInput();
        audio_enabled_ = false;
    }

    void get_stats(sw_decklink_session_stats* out) {
        std::memset(out, 0, sizeof *out);
        out->frames_received = frames_received_;
        out->frames_delivered = frames_delivered_;
        out->frames_no_source = frames_no_source_;
        out->frames_dropped_pool = frames_dropped_pool_;
        out->frames_dropped_format = frames_dropped_format_;
        out->audio_packets = audio_packets_;
        out->format_changes = format_changes_;
        out->reopen_failures = reopen_failures_;
        std::lock_guard<std::mutex> lock(mutex_);
        out->calibration_offset_ns = calib_.offset_ns;
        out->residual_max_abs_ns = calib_.max_abs_residual_ns;
        out->residual_rms_ns = sw_decklink_calibrator_residual_rms(&calib_);
        out->residual_samples = calib_.samples;
        out->has_hardware_clock = hw_clock_state_ == 1 ? 1 : 0;
        out->signal_present = signal_present_;
        out->current_format = current_;
    }

    // ---- IDeckLinkInputCallback ----
    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events, IDeckLinkDisplayMode* new_mode,
                                    BMDDetectedVideoInputFormatFlags flags) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || !new_mode) return S_OK;
        const BMDPixelFormat pf = (flags & bmdDetectedVideoInputRGB444) ? bmdFormat8BitBGRA : bmdFormat8BitYUV;
        const bool mode_changed = (events & (bmdVideoInputDisplayModeChanged | bmdVideoInputFieldDominanceChanged)) != 0;
        const bool color_changed = (events & bmdVideoInputColorspaceChanged) != 0 || pf != current_.pixel_format;
        if (!mode_changed && !color_changed) return S_OK;
        input_->PauseStreams();
        HRESULT hr = input_->EnableVideoInput(new_mode->GetDisplayMode(), pf, bmdVideoInputEnableFormatDetection);
        if (hr != S_OK) {
            reopen_failures_++;
            char msg[128];
            std::snprintf(msg, sizeof msg, "格式变更后重开失败（hr=0x%08x），保持原格式", (unsigned)hr);
            report_error(msg);
            input_->StartStreams();
            return S_OK;
        }
        input_->FlushStreams();
        input_->StartStreams();
        fill_format(new_mode, pf);
        hw_of_stream_known_ = false;
        format_changes_++;
        if (cb_.format_changed) cb_.format_changed(cb_.context, &current_);
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame* video, IDeckLinkAudioInputPacket* audio) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) return S_OK;
        const uint64_t arrival_ticks = mach_absolute_time();
        const int64_t arrival_ns = (int64_t)((__uint128_t)arrival_ticks * timebase_.numer / timebase_.denom);
        int64_t residual = 0;
        bool calibrated = false;
        if (hw_clock_state_ != 0) {
            BMDTimeValue hw_now = 0, time_in_frame = 0, ticks_per_frame = 0;
            HRESULT hr = input_->GetHardwareReferenceClock(kNanoScale, &hw_now, &time_in_frame, &ticks_per_frame);
            if (hr == S_OK) {
                hw_clock_state_ = 1;
                residual = sw_decklink_calibrator_observe(&calib_, arrival_ns, (int64_t)hw_now);
                calibrated = true;
            } else if (hw_clock_state_ == -1) {
                hw_clock_state_ = 0;
                report_error("设备没有硬件参考钟，帧时间戳退回到达时刻");
            }
        }
        if (video) handle_video(video, arrival_ticks, arrival_ns, calibrated, residual);
        if (audio && audio_enabled_) handle_audio(audio, arrival_ns, calibrated);
        return S_OK;
    }

private:
    void report_error(const char* msg) {
        if (cb_.error) cb_.error(cb_.context, msg);
    }

    BMDDisplayMode pick_initial_mode() {
        BMDDisplayMode wanted = cfg_.initial_display_mode;
        BMDDisplayMode chosen = 0;
        IDeckLinkDisplayModeIterator* it = nullptr;
        if (input_->GetDisplayModeIterator(&it) == S_OK && it) {
            IDeckLinkDisplayMode* m = nullptr;
            while (it->Next(&m) == S_OK && m) {
                if (chosen == 0 || m->GetDisplayMode() == wanted) {
                    chosen = m->GetDisplayMode();
                    fill_format(m, bmdFormat8BitYUV);
                    if (chosen == wanted) {
                        m->Release();
                        break;
                    }
                }
                m->Release();
            }
            it->Release();
        }
        if (chosen == 0) {
            chosen = wanted ? wanted : bmdModeHD1080p5994;
            current_.display_mode = chosen;
        }
        return chosen;
    }

    void fill_format(IDeckLinkDisplayMode* m, BMDPixelFormat pf) {
        current_.display_mode = m->GetDisplayMode();
        current_.width = (int32_t)m->GetWidth();
        current_.height = (int32_t)m->GetHeight();
        BMDTimeValue dur = 0;
        BMDTimeScale scale = 0;
        if (m->GetFrameRate(&dur, &scale) == S_OK && dur > 0 && scale > 0) {
            current_.frame_duration = dur;
            current_.time_scale = scale;
        } else {
            current_.frame_duration = 1001;
            current_.time_scale = 60000;
        }
        BMDFieldDominance fd = m->GetFieldDominance();
        current_.interlaced = (fd == bmdLowerFieldFirst || fd == bmdUpperFieldFirst || fd == bmdProgressiveSegmentedFrame) ? 1 : 0;
        current_.pixel_format = pf;
        CFStringRef name = nullptr;
        if (m->GetName(&name) == S_OK && name) {
            swdl::copy_string(current_.name, sizeof current_.name, swdl::cf_to_string(name));
            CFRelease(name);
        } else {
            current_.name[0] = 0;
        }
    }

    bool ensure_pool(int32_t w, int32_t h, OSType fmt) {
        if (pool_ && pool_w_ == w && pool_h_ == h && pool_fmt_ == fmt) return true;
        if (pool_) {
            CVPixelBufferPoolRelease(pool_);
            pool_ = nullptr;
        }
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFNumberRef nw = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &w);
        CFNumberRef nh = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &h);
        int32_t f = (int32_t)fmt;
        CFNumberRef nf = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &f);
        CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, nw);
        CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, nh);
        CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, nf);
        CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
        CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        CFMutableDictionaryRef pool_attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int32_t min_count = 3;
        CFNumberRef nmin = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &min_count);
        CFDictionarySetValue(pool_attrs, kCVPixelBufferPoolMinimumBufferCountKey, nmin);
        CVReturn r = CVPixelBufferPoolCreate(kCFAllocatorDefault, pool_attrs, attrs, &pool_);
        CFRelease(nw);
        CFRelease(nh);
        CFRelease(nf);
        CFRelease(empty);
        CFRelease(attrs);
        CFRelease(nmin);
        CFRelease(pool_attrs);
        if (r != kCVReturnSuccess) {
            pool_ = nullptr;
            return false;
        }
        pool_w_ = w;
        pool_h_ = h;
        pool_fmt_ = fmt;
        return true;
    }

    CVPixelBufferRef make_buffer() {
        CFMutableDictionaryRef aux = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int32_t threshold = max_pool_;
        CFNumberRef nt = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &threshold);
        CFDictionarySetValue(aux, kCVPixelBufferPoolAllocationThresholdKey, nt);
        CVPixelBufferRef pb = nullptr;
        CVReturn r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool_, aux, &pb);
        CFRelease(nt);
        CFRelease(aux);
        return r == kCVReturnSuccess ? pb : nullptr;
    }

    void handle_video(IDeckLinkVideoInputFrame* video, uint64_t arrival_ticks, int64_t arrival_ns, bool calibrated, int64_t residual) {
        frames_received_++;
        const BMDFrameFlags flags = video->GetFlags();
        if (flags & bmdFrameHasNoInputSource) {
            frames_no_source_++;
            if (signal_present_ != 0) {
                signal_present_ = 0;
                if (cb_.signal_changed) cb_.signal_changed(cb_.context, 0);
            }
            return;
        }
        if (signal_present_ != 1) {
            signal_present_ = 1;
            if (cb_.signal_changed) cb_.signal_changed(cb_.context, 1);
        }
        const int32_t w = (int32_t)video->GetWidth();
        const int32_t h = (int32_t)video->GetHeight();
        const BMDPixelFormat pf = video->GetPixelFormat();
        OSType cv_fmt;
        size_t bpp;
        if (pf == bmdFormat8BitYUV) {
            cv_fmt = kCVPixelFormatType_422YpCbCr8;
            bpp = 2;
        } else if (pf == bmdFormat8BitBGRA) {
            cv_fmt = kCVPixelFormatType_32BGRA;
            bpp = 4;
        } else {
            frames_dropped_format_++;
            return;
        }
        if (w <= 0 || h <= 0 || !ensure_pool(w, h, cv_fmt)) {
            frames_dropped_format_++;
            return;
        }
        // 当前格式跟着实际到的帧走（起始模式猜错、检测回调还没来时也能出画）
        if (current_.width != w || current_.height != h || current_.pixel_format != pf) {
            current_.width = w;
            current_.height = h;
            current_.pixel_format = pf;
        }
        void* src = nullptr;
        if (video->GetBytes(&src) != S_OK || !src) {
            frames_dropped_format_++;
            return;
        }
        CVPixelBufferRef pb = make_buffer();
        if (!pb) {
            frames_dropped_pool_++;
            return;
        }
        const size_t src_stride = (size_t)video->GetRowBytes();
        const size_t row_bytes = (size_t)w * bpp;
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(pb);
        const size_t dst_stride = CVPixelBufferGetBytesPerRow(pb);
        if (dst) {
            if (dst_stride == src_stride && src_stride == row_bytes) {
                std::memcpy(dst, src, row_bytes * (size_t)h);
            } else {
                for (int32_t y = 0; y < h; y++) std::memcpy(dst + (size_t)y * dst_stride, (const uint8_t*)src + (size_t)y * src_stride, row_bytes);
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
        // 时间戳
        sw_decklink_frame_info info;
        std::memset(&info, 0, sizeof info);
        info.arrival_host = arrival_ticks;
        info.pts_host = arrival_ticks;
        info.sequence = ++sequence_;
        info.width = w;
        info.height = h;
        info.pixel_format = pf;
        info.calibration_residual_ns = residual;
        BMDTimeValue frame_time = 0, frame_duration = 0;
        if (current_.frame_duration > 0 && current_.time_scale > 0) {
            info.duration_host = (int64_t)host_ticks_from_ns((int64_t)((__int128)kNanoScale * current_.frame_duration / current_.time_scale), timebase_);
        }
        if (calibrated && video->GetHardwareReferenceTimestamp(kNanoScale, &frame_time, &frame_duration) == S_OK) {
            info.pts_host = host_ticks_from_ns(sw_decklink_calibrator_map(&calib_, (int64_t)frame_time), timebase_);
            info.calibrated = 1;
            if (frame_duration > 0) info.duration_host = (int64_t)host_ticks_from_ns((int64_t)frame_duration, timebase_);
            BMDTimeValue stream_time = 0, stream_duration = 0;
            if (video->GetStreamTime(&stream_time, &stream_duration, kNanoScale) == S_OK) {
                hw_of_stream_zero_ns_ = (int64_t)frame_time - (int64_t)stream_time;
                hw_of_stream_known_ = true;
            }
        }
        if (cb_.video_frame) cb_.video_frame(cb_.context, pb, &info);
        frames_delivered_++;
        CVPixelBufferRelease(pb);
    }

    void handle_audio(IDeckLinkAudioInputPacket* audio, int64_t arrival_ns, bool calibrated) {
        const long frames = audio->GetSampleFrameCount();
        void* bytes = nullptr;
        if (frames <= 0 || audio->GetBytes(&bytes) != S_OK || !bytes) return;
        const int channels = cfg_.audio_channels;
        const size_t need = (size_t)frames * (size_t)channels;
        if (scratch_.size() < need) scratch_.resize(need);
        if (planes_.size() < (size_t)channels) planes_.resize((size_t)channels);
        for (int c = 0; c < channels; c++) planes_[(size_t)c] = scratch_.data() + (size_t)c * (size_t)frames;
        if (audio_sample_type_ == bmdAudioSampleType16bitInteger) {
            const int16_t* s = (const int16_t*)bytes;
            for (long i = 0; i < frames; i++)
                for (int c = 0; c < channels; c++) scratch_[(size_t)c * (size_t)frames + (size_t)i] = (float)s[i * channels + c] / 32768.0f;
        } else {
            const int32_t* s = (const int32_t*)bytes;
            for (long i = 0; i < frames; i++)
                for (int c = 0; c < channels; c++) scratch_[(size_t)c * (size_t)frames + (size_t)i] = (float)s[i * channels + c] / 2147483648.0f;
        }
        sw_decklink_audio_info info;
        std::memset(&info, 0, sizeof info);
        info.channel_count = channels;
        info.frame_count = (int32_t)frames;
        info.sample_rate = 48000;
        const int64_t packet_duration_ns = (int64_t)frames * kNanoScale / 48000;
        int64_t host_ns = arrival_ns - packet_duration_ns;
        BMDTimeValue packet_time = 0;
        if (calibrated && hw_of_stream_known_ && audio->GetPacketTime(&packet_time, kNanoScale) == S_OK) {
            host_ns = sw_decklink_calibrator_map(&calib_, (int64_t)packet_time + hw_of_stream_zero_ns_);
        }
        info.host_time = host_ticks_from_ns(host_ns, timebase_);
        audio_packets_++;
        if (cb_.audio_packet) cb_.audio_packet(cb_.context, planes_.data(), &info);
    }

    IDeckLinkInput* input_;
    IDeckLinkConfiguration* config_;
    IDeckLinkStatus* status_;
    sw_decklink_session_config cfg_;
    sw_decklink_callbacks cb_;
    std::atomic<ULONG> refcount_{1};
    std::mutex mutex_;
    bool running_ = false;
    bool audio_enabled_ = false;
    BMDAudioSampleType audio_sample_type_ = bmdAudioSampleType32bitInteger;
    mach_timebase_info_data_t timebase_{};
    sw_decklink_calibrator calib_{};
    int hw_clock_state_ = -1;   // -1 未探测 / 0 不支持 / 1 支持
    bool hw_of_stream_known_ = false;
    int64_t hw_of_stream_zero_ns_ = 0;
    sw_decklink_video_format current_{};
    int signal_present_ = -1;
    CVPixelBufferPoolRef pool_ = nullptr;
    int32_t pool_w_ = 0, pool_h_ = 0;
    OSType pool_fmt_ = 0;
    int max_pool_ = 8;
    uint64_t sequence_ = 0;
    std::vector<float> scratch_;
    std::vector<const float*> planes_;
    std::atomic<uint64_t> frames_received_{0}, frames_delivered_{0}, frames_no_source_{0}, frames_dropped_pool_{0},
        frames_dropped_format_{0}, audio_packets_{0}, format_changes_{0}, reopen_failures_{0};
};

}  // namespace

struct sw_decklink_session {
    Session* impl;
};

namespace swdl {

sw_decklink_session* make_session(IDeckLinkInput* input, IDeckLinkConfiguration* config, IDeckLinkStatus* status,
                                  const sw_decklink_session_config* cfg, const sw_decklink_callbacks* cb, char* err, size_t err_size) {
    if (!input || !cfg || !cb) {
        if (err && err_size) std::snprintf(err, err_size, "参数为空");
        return nullptr;
    }
    sw_decklink_session* s = new sw_decklink_session();
    s->impl = new Session(input, config, status, *cfg, *cb);
    return s;
}

}  // namespace swdl

extern "C" {

sw_decklink_session* sw_decklink_session_open(const sw_decklink_session_config* config, const sw_decklink_callbacks* callbacks,
                                              char* err, size_t err_size) {
    if (err && err_size) err[0] = 0;
    if (!IsDeckLinkAPIPresent()) {
        if (err && err_size) std::snprintf(err, err_size, "没有 DeckLink 驱动（DeckLinkAPI.framework 加载不了）");
        return nullptr;
    }
    IDeckLink* device = nullptr;
    sw_decklink_device_info info;
    if (!swdl::find_device(config ? config->persistent_id : nullptr, &device, &info)) {
        if (err && err_size) std::snprintf(err, err_size, "找不到 DeckLink 设备 %s", (config && config->persistent_id) ? config->persistent_id : "(第一台)");
        return nullptr;
    }
    IDeckLinkInput* input = nullptr;
    if (device->QueryInterface(IID_IDeckLinkInput, (void**)&input) != S_OK || !input) {
        device->Release();
        if (err && err_size) std::snprintf(err, err_size, "设备 %s 没有输入接口", info.display_name);
        return nullptr;
    }
    IDeckLinkConfiguration* cfg_if = nullptr;
    if (device->QueryInterface(IID_IDeckLinkConfiguration, (void**)&cfg_if) != S_OK) cfg_if = nullptr;
    IDeckLinkStatus* status = nullptr;
    if (device->QueryInterface(IID_IDeckLinkStatus, (void**)&status) != S_OK) status = nullptr;
    sw_decklink_session* s = swdl::make_session(input, cfg_if, status, config, callbacks, err, err_size);
    input->Release();
    if (cfg_if) cfg_if->Release();
    if (status) status->Release();
    device->Release();
    return s;
}

int sw_decklink_session_start(sw_decklink_session* session, char* err, size_t err_size) {
    if (err && err_size) err[0] = 0;
    if (!session || !session->impl) return -1;
    return session->impl->start(err, err_size);
}

void sw_decklink_session_stop(sw_decklink_session* session) {
    if (session && session->impl) session->impl->stop();
}

void sw_decklink_session_close(sw_decklink_session* session) {
    if (!session) return;
    if (session->impl) {
        session->impl->stop();
        session->impl->Release();
    }
    delete session;
}

void sw_decklink_session_get_stats(sw_decklink_session* session, sw_decklink_session_stats* out) {
    if (!out) return;
    if (!session || !session->impl) {
        std::memset(out, 0, sizeof *out);
        return;
    }
    session->impl->get_stats(out);
}

}  // extern "C"

#else

extern "C" {
sw_decklink_session* sw_decklink_session_open(const sw_decklink_session_config* config, const sw_decklink_callbacks* callbacks, char* err, size_t err_size) {
    (void)config;
    (void)callbacks;
    if (err && err_size) std::snprintf(err, err_size, "DeckLink SDK 未编译进来");
    return nullptr;
}
int sw_decklink_session_start(sw_decklink_session* s, char* err, size_t err_size) {
    (void)s;
    if (err && err_size) std::snprintf(err, err_size, "DeckLink SDK 未编译进来");
    return -1;
}
void sw_decklink_session_stop(sw_decklink_session* s) { (void)s; }
void sw_decklink_session_close(sw_decklink_session* s) { (void)s; }
void sw_decklink_session_get_stats(sw_decklink_session* s, sw_decklink_session_stats* out) {
    (void)s;
    if (out) std::memset(out, 0, sizeof *out);
}
}

#endif
