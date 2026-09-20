// 把 SDK 自带的 DeckLinkAPIDispatch.cpp 编进来（它在运行时 CFBundle 加载 /Library/Frameworks/DeckLinkAPI.framework，
// 没装驱动时 CreateDeckLinkIteratorInstance() 返回 NULL、IsDeckLinkAPIPresent() 返回 false）。头文件目录由 Package.swift 的 -I 给。
#include "sw_decklink.h"
#if SWITCHER_HAS_DECKLINK_SDK
#include "DeckLinkAPIDispatch.cpp"
#endif
