// 设备枚举（IDeckLinkIterator）与热插拔通知（IDeckLinkDiscovery）。
#include "sw_decklink.h"

#if SWITCHER_HAS_DECKLINK_SDK
#include "sw_decklink_internal.hpp"

#include <atomic>
#include <cstdio>
#include <map>
#include <mutex>
#include <vector>

namespace swdl {

void fill_device_info(IDeckLink* d, int index, int same_model_index, sw_decklink_device_info* out) {
    std::memset(out, 0, sizeof *out);
    out->index = index;
    CFStringRef s = nullptr;
    std::string model;
    if (d->GetModelName(&s) == S_OK && s) {
        model = cf_to_string(s);
        CFRelease(s);
    }
    copy_string(out->model_name, sizeof out->model_name, model);
    s = nullptr;
    if (d->GetDisplayName(&s) == S_OK && s) {
        copy_string(out->display_name, sizeof out->display_name, cf_to_string(s));
        CFRelease(s);
    } else {
        copy_string(out->display_name, sizeof out->display_name, model);
    }
    SwDeckLinkAttributes* attrs = nullptr;
    if (d->QueryInterface(SW_IID_ATTRIBUTES, (void**)&attrs) == S_OK && attrs) {
        int64_t v = 0;
        if (attrs->GetInt(BMDDeckLinkPersistentID, &v) == S_OK) {
            std::snprintf(out->persistent_id, sizeof out->persistent_id, "peid:%lld", (long long)v);
        }
        v = 0;
        if (attrs->GetInt(BMDDeckLinkVideoInputConnections, &v) == S_OK) out->input_connections = (uint32_t)v;
        bool flag = false;
        if (attrs->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &flag) == S_OK) out->supports_input_format_detection = flag ? 1 : 0;
        attrs->Release();
    }
    if (!out->persistent_id[0]) {
        std::snprintf(out->persistent_id, sizeof out->persistent_id, "model:%.24s#%d", model.c_str(), same_model_index);
    }
    IDeckLinkInput* in = nullptr;
    if (d->QueryInterface(IID_IDeckLinkInput, (void**)&in) == S_OK && in) {
        out->has_input = 1;
        in->Release();
    }
}

template <typename F>
static void for_each_device(F f) {
    if (!IsDeckLinkAPIPresent()) return;
    IDeckLinkIterator* it = CreateDeckLinkIteratorInstance();
    if (!it) return;
    std::map<std::string, int> model_counts;
    IDeckLink* d = nullptr;
    int index = 0;
    while (it->Next(&d) == S_OK && d) {
        CFStringRef s = nullptr;
        std::string model;
        if (d->GetModelName(&s) == S_OK && s) {
            model = cf_to_string(s);
            CFRelease(s);
        }
        sw_decklink_device_info info;
        fill_device_info(d, index, model_counts[model]++, &info);
        bool stop = f(d, info);
        d->Release();
        d = nullptr;
        index++;
        if (stop) break;
    }
    it->Release();
}

bool find_device(const char* persistent_id, IDeckLink** out, sw_decklink_device_info* info_out) {
    bool found = false;
    const bool any = !persistent_id || !persistent_id[0];
    for_each_device([&](IDeckLink* d, const sw_decklink_device_info& info) {
        if (any ? info.has_input != 0 : std::strcmp(info.persistent_id, persistent_id) == 0) {
            d->AddRef();
            *out = d;
            if (info_out) *info_out = info;
            found = true;
            return true;
        }
        return false;
    });
    return found;
}

}  // namespace swdl

extern "C" int sw_decklink_enumerate(sw_decklink_device_info* out, int max_count) {
    int n = 0;
    swdl::for_each_device([&](IDeckLink*, const sw_decklink_device_info& info) {
        if (out && n < max_count) out[n] = info;
        n++;
        return false;
    });
    return n;
}

// ---- 热插拔 ----

namespace {

struct Subscriber {
    int token;
    sw_decklink_hotplug_fn fn;
    void* context;
};

class DiscoveryCallback : public IDeckLinkDeviceNotificationCallback {
public:
    HRESULT QueryInterface(REFIID iid, LPVOID* ppv) override {
        if (!ppv) return E_POINTER;
        if (swdl::iid_equal(iid, IID_IDeckLinkDeviceNotificationCallback)) {
            AddRef();
            *ppv = this;
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
    HRESULT DeckLinkDeviceArrived(IDeckLink* d) override { return notify(d, 1); }
    HRESULT DeckLinkDeviceRemoved(IDeckLink* d) override { return notify(d, 0); }

    std::mutex mutex;
    std::vector<Subscriber> subscribers;

private:
    HRESULT notify(IDeckLink* d, int arrived) {
        sw_decklink_device_info info;
        swdl::fill_device_info(d, -1, 0, &info);
        std::vector<Subscriber> copy;
        {
            std::lock_guard<std::mutex> lock(mutex);
            copy = subscribers;
        }
        for (auto& s : copy) s.fn(s.context, &info, arrived);
        return S_OK;
    }
    std::atomic<ULONG> refcount_{1};
};

std::mutex g_hotplug_mutex;
IDeckLinkDiscovery* g_discovery = nullptr;
DiscoveryCallback* g_callback = nullptr;
int g_next_token = 0;

}  // namespace

extern "C" int sw_decklink_hotplug_subscribe(sw_decklink_hotplug_fn fn, void* context) {
    if (!fn) return 0;
    std::lock_guard<std::mutex> lock(g_hotplug_mutex);
    if (!g_discovery) {
        if (!IsDeckLinkAPIPresent()) return 0;
        IDeckLinkDiscovery* disc = CreateDeckLinkDiscoveryInstance();
        if (!disc) return 0;
        DiscoveryCallback* cb = new DiscoveryCallback();
        if (disc->InstallDeviceNotifications(cb) != S_OK) {
            cb->Release();
            disc->Release();
            return 0;
        }
        g_discovery = disc;
        g_callback = cb;
    }
    int token = ++g_next_token;
    std::lock_guard<std::mutex> lock2(g_callback->mutex);
    g_callback->subscribers.push_back({token, fn, context});
    return token;
}

extern "C" void sw_decklink_hotplug_unsubscribe(int token) {
    std::lock_guard<std::mutex> lock(g_hotplug_mutex);
    if (!g_callback) return;
    bool empty;
    {
        std::lock_guard<std::mutex> lock2(g_callback->mutex);
        auto& v = g_callback->subscribers;
        for (auto it = v.begin(); it != v.end(); ++it) {
            if (it->token == token) {
                v.erase(it);
                break;
            }
        }
        empty = v.empty();
    }
    if (empty) {
        g_discovery->UninstallDeviceNotifications();
        g_discovery->Release();
        g_discovery = nullptr;
        g_callback->Release();
        g_callback = nullptr;
    }
}

#else

extern "C" {
int sw_decklink_enumerate(sw_decklink_device_info* out, int max_count) {
    (void)out;
    (void)max_count;
    return 0;
}
int sw_decklink_hotplug_subscribe(sw_decklink_hotplug_fn fn, void* context) {
    (void)fn;
    (void)context;
    return 0;
}
void sw_decklink_hotplug_unsubscribe(int token) { (void)token; }
}

#endif
