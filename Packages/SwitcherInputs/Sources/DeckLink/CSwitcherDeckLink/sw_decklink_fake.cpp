// Fake IDeckLinkInput：实现 SDK 的 COM 接口（IDeckLinkInput / DisplayModeIterator / DisplayMode / VideoInputFrame / AudioInputPacket），
// 桥接层对它和对真卡走同一段代码。测试用 sw_decklink_fake_emit_* 在调用线程上同步触发桥接层的回调。
#include "sw_decklink.h"

#if SWITCHER_HAS_DECKLINK_SDK
#include "sw_decklink_internal.hpp"

#include <atomic>
#include <mutex>
#include <vector>

namespace {

/// 纳秒 → 请求的 timeScale（真驱动内部怎么算不管，假设备别在 1e14 × 1e9 上溢出）。
inline int64_t to_scale(int64_t ns, BMDTimeScale scale) { return (int64_t)((__int128)ns * scale / 1000000000LL); }

template <typename Iface>
class ComBase : public Iface {
public:
    HRESULT QueryInterface(REFIID, LPVOID* ppv) override {
        if (ppv) *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refcount_; }
    ULONG Release() override {
        ULONG r = --refcount_;
        if (r == 0) delete this;
        return r;
    }

protected:
    ~ComBase() override = default;
    std::atomic<ULONG> refcount_{1};
};

struct ModeSpec {
    BMDDisplayMode mode;
    int32_t width, height;
    BMDTimeValue duration;
    BMDTimeScale scale;
    BMDFieldDominance field;
    const char* name;
};

const ModeSpec kModes[] = {
    {bmdModeHD1080p5994, 1920, 1080, 1001, 60000, bmdProgressiveFrame, "1080p59.94"},
    {bmdModeHD1080p6000, 1920, 1080, 1000, 60000, bmdProgressiveFrame, "1080p60"},
    {bmdModeHD1080p30, 1920, 1080, 1000, 30000, bmdProgressiveFrame, "1080p30"},
    {bmdModeHD720p60, 1280, 720, 1000, 60000, bmdProgressiveFrame, "720p60"},
    {bmdModeHD1080i5994, 1920, 1080, 1001, 30000, bmdUpperFieldFirst, "1080i59.94"},
};

class FakeDisplayMode : public ComBase<IDeckLinkDisplayMode> {
public:
    explicit FakeDisplayMode(ModeSpec spec) : spec_(spec) {}
    HRESULT GetName(CFStringRef* name) override {
        if (!name) return E_POINTER;
        *name = CFStringCreateWithCString(kCFAllocatorDefault, spec_.name ? spec_.name : "fake", kCFStringEncodingUTF8);
        return S_OK;
    }
    BMDDisplayMode GetDisplayMode() override { return spec_.mode; }
    long GetWidth() override { return spec_.width; }
    long GetHeight() override { return spec_.height; }
    HRESULT GetFrameRate(BMDTimeValue* d, BMDTimeScale* s) override {
        if (d) *d = spec_.duration;
        if (s) *s = spec_.scale;
        return S_OK;
    }
    BMDFieldDominance GetFieldDominance() override { return spec_.field; }
    BMDDisplayModeFlags GetFlags() override { return 0; }

private:
    ModeSpec spec_;
};

class FakeModeIterator : public ComBase<IDeckLinkDisplayModeIterator> {
public:
    HRESULT Next(IDeckLinkDisplayMode** out) override {
        if (!out) return E_POINTER;
        if (index_ >= sizeof(kModes) / sizeof(kModes[0])) {
            *out = nullptr;
            return S_FALSE;
        }
        *out = new FakeDisplayMode(kModes[index_++]);
        return S_OK;
    }

private:
    size_t index_ = 0;
};

class FakeVideoFrame : public ComBase<IDeckLinkVideoInputFrame> {
public:
    explicit FakeVideoFrame(const sw_decklink_fake_frame& f) : f_(f) {}
    long GetWidth() override { return f_.width; }
    long GetHeight() override { return f_.height; }
    long GetRowBytes() override { return f_.row_bytes; }
    BMDPixelFormat GetPixelFormat() override { return f_.pixel_format; }
    BMDFrameFlags GetFlags() override { return f_.flags; }
    HRESULT GetBytes(void** buffer) override {
        if (!buffer) return E_POINTER;
        *buffer = const_cast<void*>(f_.bytes);
        return f_.bytes ? S_OK : E_FAIL;
    }
    HRESULT GetTimecode(BMDTimecodeFormat, IDeckLinkTimecode** t) override {
        if (t) *t = nullptr;
        return S_FALSE;
    }
    HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary** a) override {
        if (a) *a = nullptr;
        return E_NOTIMPL;
    }
    HRESULT GetStreamTime(BMDTimeValue* t, BMDTimeValue* d, BMDTimeScale scale) override {
        if (t) *t = to_scale(f_.stream_time_ns, scale);
        if (d) *d = to_scale(f_.hw_duration_ns, scale);
        return S_OK;
    }
    HRESULT GetHardwareReferenceTimestamp(BMDTimeScale scale, BMDTimeValue* t, BMDTimeValue* d) override {
        if (!f_.hw_timestamp_supported) return E_NOTIMPL;
        if (t) *t = to_scale(f_.hw_time_ns, scale);
        if (d) *d = to_scale(f_.hw_duration_ns, scale);
        return S_OK;
    }

private:
    sw_decklink_fake_frame f_;
};

class FakeAudioPacket : public ComBase<IDeckLinkAudioInputPacket> {
public:
    explicit FakeAudioPacket(const sw_decklink_fake_frame& f) : f_(f) {}
    long GetSampleFrameCount() override { return f_.audio_frames; }
    HRESULT GetBytes(void** buffer) override {
        if (!buffer) return E_POINTER;
        *buffer = const_cast<void*>(f_.audio_bytes);
        return S_OK;
    }
    HRESULT GetPacketTime(BMDTimeValue* t, BMDTimeScale scale) override {
        if (t) *t = to_scale(f_.audio_packet_time_ns, scale);
        return S_OK;
    }

private:
    sw_decklink_fake_frame f_;
};

class FakeInput : public ComBase<IDeckLinkInput> {
public:
    HRESULT QueryInterface(REFIID iid, LPVOID* ppv) override {
        if (!ppv) return E_POINTER;
        if (swdl::iid_equal(iid, IID_IDeckLinkInput)) {
            AddRef();
            *ppv = static_cast<IDeckLinkInput*>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT DoesSupportVideoMode(BMDDisplayMode, BMDPixelFormat, BMDVideoInputFlags, BMDDisplayModeSupport* r, IDeckLinkDisplayMode** m) override {
        if (r) *r = bmdDisplayModeSupported;
        if (m) *m = nullptr;
        return S_OK;
    }
    HRESULT GetDisplayModeIterator(IDeckLinkDisplayModeIterator** it) override {
        if (!it) return E_POINTER;
        *it = new FakeModeIterator();
        return S_OK;
    }
    HRESULT SetScreenPreviewCallback(IDeckLinkScreenPreviewCallback*) override { return E_NOTIMPL; }
    HRESULT EnableVideoInput(BMDDisplayMode mode, BMDPixelFormat pf, BMDVideoInputFlags flags) override {
        std::lock_guard<std::mutex> lock(mutex);
        log.enable_video_calls++;
        log.last_display_mode = mode;
        log.last_pixel_format = pf;
        log.last_input_flags = flags;
        return S_OK;
    }
    HRESULT DisableVideoInput() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.disable_video_calls++;
        return S_OK;
    }
    HRESULT GetAvailableVideoFrameCount(uint32_t* n) override {
        if (n) *n = 0;
        return S_OK;
    }
    HRESULT SetVideoInputFrameMemoryAllocator(IDeckLinkMemoryAllocator*) override { return E_NOTIMPL; }
    HRESULT EnableAudioInput(BMDAudioSampleRate rate, BMDAudioSampleType type, uint32_t channels) override {
        std::lock_guard<std::mutex> lock(mutex);
        log.enable_audio_calls++;
        log.last_audio_sample_rate = rate;
        log.last_audio_sample_type = type;
        log.last_audio_channels = channels;
        return S_OK;
    }
    HRESULT DisableAudioInput() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.disable_audio_calls++;
        return S_OK;
    }
    HRESULT GetAvailableAudioSampleFrameCount(uint32_t* n) override {
        if (n) *n = 0;
        return S_OK;
    }
    HRESULT StartStreams() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.start_calls++;
        return S_OK;
    }
    HRESULT StopStreams() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.stop_calls++;
        return S_OK;
    }
    HRESULT PauseStreams() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.pause_calls++;
        return S_OK;
    }
    HRESULT FlushStreams() override {
        std::lock_guard<std::mutex> lock(mutex);
        log.flush_calls++;
        return S_OK;
    }
    HRESULT SetCallback(IDeckLinkInputCallback* cb) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (cb) cb->AddRef();
        if (callback) callback->Release();
        callback = cb;
        log.callback_set = cb ? 1 : 0;
        return S_OK;
    }
    HRESULT GetHardwareReferenceClock(BMDTimeScale scale, BMDTimeValue* hw, BMDTimeValue* in_frame, BMDTimeValue* per_frame) override {
        std::lock_guard<std::mutex> lock(mutex);
        log.hardware_clock_calls++;
        if (!hw_clock_supported) return E_NOTIMPL;
        if (hw) *hw = to_scale(hw_now_ns, scale);
        if (in_frame) *in_frame = 0;
        if (per_frame) *per_frame = 0;
        return S_OK;
    }

    IDeckLinkInputCallback* current_callback() {
        std::lock_guard<std::mutex> lock(mutex);
        if (callback) callback->AddRef();
        return callback;
    }

    std::mutex mutex;
    IDeckLinkInputCallback* callback = nullptr;
    sw_decklink_fake_log log{};
    int64_t hw_now_ns = 0;
    bool hw_clock_supported = true;

protected:
    ~FakeInput() override {
        if (callback) callback->Release();
    }
};

}  // namespace

struct sw_decklink_fake {
    FakeInput* input;
};

extern "C" {

sw_decklink_fake* sw_decklink_fake_create(void) {
    sw_decklink_fake* f = new sw_decklink_fake();
    f->input = new FakeInput();
    return f;
}

void sw_decklink_fake_destroy(sw_decklink_fake* fake) {
    if (!fake) return;
    fake->input->Release();
    delete fake;
}

sw_decklink_session* sw_decklink_session_open_fake(sw_decklink_fake* fake, const sw_decklink_session_config* config,
                                                   const sw_decklink_callbacks* callbacks, char* err, size_t err_size) {
    if (err && err_size) err[0] = 0;
    if (!fake) return nullptr;
    return swdl::make_session(fake->input, nullptr, nullptr, config, callbacks, err, err_size);
}

void sw_decklink_fake_get_log(sw_decklink_fake* fake, sw_decklink_fake_log* out) {
    if (!out) return;
    if (!fake) {
        std::memset(out, 0, sizeof *out);
        return;
    }
    std::lock_guard<std::mutex> lock(fake->input->mutex);
    *out = fake->input->log;
}

void sw_decklink_fake_set_hardware_clock(sw_decklink_fake* fake, int64_t hw_now_ns) {
    if (!fake) return;
    std::lock_guard<std::mutex> lock(fake->input->mutex);
    fake->input->hw_now_ns = hw_now_ns;
}

void sw_decklink_fake_set_hardware_clock_supported(sw_decklink_fake* fake, int supported) {
    if (!fake) return;
    std::lock_guard<std::mutex> lock(fake->input->mutex);
    fake->input->hw_clock_supported = supported != 0;
}

void sw_decklink_fake_emit_format_changed(sw_decklink_fake* fake, uint32_t display_mode, int32_t width, int32_t height,
                                          int64_t frame_duration, int64_t time_scale, uint32_t field_dominance,
                                          uint32_t detected_flags, uint32_t events) {
    if (!fake) return;
    IDeckLinkInputCallback* cb = fake->input->current_callback();
    if (!cb) return;
    ModeSpec spec{display_mode, width, height, frame_duration, time_scale, field_dominance, "fake-detected"};
    FakeDisplayMode* mode = new FakeDisplayMode(spec);
    cb->VideoInputFormatChanged(events, mode, detected_flags);
    mode->Release();
    cb->Release();
}

void sw_decklink_fake_emit_frame(sw_decklink_fake* fake, const sw_decklink_fake_frame* frame) {
    if (!fake || !frame) return;
    IDeckLinkInputCallback* cb = fake->input->current_callback();
    if (!cb) return;
    FakeVideoFrame* video = new FakeVideoFrame(*frame);
    FakeAudioPacket* audio = frame->audio_bytes ? new FakeAudioPacket(*frame) : nullptr;
    cb->VideoInputFrameArrived(video, audio);
    if (audio) audio->Release();
    video->Release();
    cb->Release();
}

}  // extern "C"

#else

extern "C" {
sw_decklink_fake* sw_decklink_fake_create(void) { return nullptr; }
void sw_decklink_fake_destroy(sw_decklink_fake* f) { (void)f; }
sw_decklink_session* sw_decklink_session_open_fake(sw_decklink_fake* f, const sw_decklink_session_config* c, const sw_decklink_callbacks* cb, char* err, size_t err_size) {
    (void)f;
    (void)c;
    (void)cb;
    if (err && err_size) err[0] = 0;
    return nullptr;
}
void sw_decklink_fake_get_log(sw_decklink_fake* f, sw_decklink_fake_log* out) {
    (void)f;
    if (out) std::memset(out, 0, sizeof *out);
}
void sw_decklink_fake_set_hardware_clock(sw_decklink_fake* f, int64_t t) { (void)f; (void)t; }
void sw_decklink_fake_set_hardware_clock_supported(sw_decklink_fake* f, int s) { (void)f; (void)s; }
void sw_decklink_fake_emit_format_changed(sw_decklink_fake* f, uint32_t a, int32_t b, int32_t c, int64_t d, int64_t e, uint32_t g, uint32_t h, uint32_t i) {
    (void)f; (void)a; (void)b; (void)c; (void)d; (void)e; (void)g; (void)h; (void)i;
}
void sw_decklink_fake_emit_frame(sw_decklink_fake* f, const sw_decklink_fake_frame* fr) { (void)f; (void)fr; }
}

#endif
