// 编译 / 运行环境信息。
#include "sw_decklink.h"

#include <cstdio>
#include <cstring>

#if SWITCHER_HAS_DECKLINK_SDK
#include "sw_decklink_internal.hpp"

extern "C" {

int sw_decklink_sdk_compiled(void) { return 1; }
const char* sw_decklink_sdk_version(void) { return BLACKMAGIC_DECKLINK_API_VERSION_STRING; }
int sw_decklink_api_present(void) { return IsDeckLinkAPIPresent() ? 1 : 0; }

const char* sw_decklink_driver_version(char* buf, size_t size) {
    if (!buf || size == 0) return buf;
    buf[0] = 0;
    if (!IsDeckLinkAPIPresent()) return buf;
    IDeckLinkAPIInformation* info = CreateDeckLinkAPIInformationInstance();
    if (!info) return buf;
    CFStringRef s = nullptr;
    if (info->GetString(BMDDeckLinkAPIVersion, &s) == S_OK && s) {
        CFStringGetCString(s, buf, (CFIndex)size, kCFStringEncodingUTF8);
        CFRelease(s);
    }
    info->Release();
    return buf;
}

}  // extern "C"

namespace swdl {

std::string cf_to_string(CFStringRef s) {
    if (!s) return "";
    char buf[512];
    if (CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) return buf;
    return "";
}

void copy_string(char* dst, size_t size, const std::string& s) {
    if (!dst || size == 0) return;
    std::strncpy(dst, s.c_str(), size - 1);
    dst[size - 1] = 0;
}

}  // namespace swdl

#else

extern "C" {
int sw_decklink_sdk_compiled(void) { return 0; }
const char* sw_decklink_sdk_version(void) { return ""; }
int sw_decklink_api_present(void) { return 0; }
const char* sw_decklink_driver_version(char* buf, size_t size) {
    if (buf && size) buf[0] = 0;
    return buf;
}
}

#endif
