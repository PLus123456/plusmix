// CSwitcherDeckLink 内部共用声明（不在 include/ 里，Swift 看不到）。只在带 SDK 时有内容。
#pragma once
#include "sw_decklink.h"

#if SWITCHER_HAS_DECKLINK_SDK
#include "DeckLinkAPI.h"
#include "DeckLinkAPIVersion.h"

#include <cstring>
#include <string>

// 11.0 起 IDeckLinkAttributes 改名 IDeckLinkProfileAttributes（方法一样），IID 也换了；按头文件版本选。
#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0b000000
typedef IDeckLinkProfileAttributes SwDeckLinkAttributes;
#define SW_IID_ATTRIBUTES IID_IDeckLinkProfileAttributes
#else
typedef IDeckLinkAttributes SwDeckLinkAttributes;
#define SW_IID_ATTRIBUTES IID_IDeckLinkAttributes
#endif

// Dispatch.cpp 提供（头文件里没声明）
bool IsDeckLinkAPIPresent(void);

namespace swdl {

inline bool iid_equal(REFIID a, REFIID b) { return std::memcmp(&a, &b, sizeof(REFIID)) == 0; }
std::string cf_to_string(CFStringRef s);
void copy_string(char* dst, size_t size, const std::string& s);

/// 填一台设备的信息。same_model_index = 同型号里第几台（没有持久 ID 时拼进标识）。
void fill_device_info(IDeckLink* device, int index, int same_model_index, sw_decklink_device_info* out);
/// 按持久标识找设备（id 为空 = 第一台有输入的）；找到返回 true 并 AddRef 到 *out。
bool find_device(const char* persistent_id, IDeckLink** out, sw_decklink_device_info* info);
/// 建会话（input 必给，config / status 可为 NULL；会话内部 AddRef 它们）。
sw_decklink_session* make_session(IDeckLinkInput* input, IDeckLinkConfiguration* config, IDeckLinkStatus* status,
                                  const sw_decklink_session_config* cfg, const sw_decklink_callbacks* cb, char* err, size_t err_size);

}  // namespace swdl
#endif
