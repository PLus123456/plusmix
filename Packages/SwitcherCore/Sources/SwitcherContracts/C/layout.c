// layout.c —— 用 _Static_assert 把 sw_audio_ring.h 的布局钉死。
// 这些数字同时写在 docs/CONTRACTS.md 和 SwitcherContractsTests（MemoryLayout）里；三处不一致就是契约被改了。
#include "sw_audio_ring.h"

_Static_assert(sizeof(sw_audio_stamp) == 16, "sw_audio_stamp 应为 16 字节");
_Static_assert(offsetof(sw_audio_stamp, host_time) == 8, "sw_audio_stamp.host_time 偏移应为 8");

_Static_assert(offsetof(sw_audio_ring, layout_version) == 0, "layout_version 偏移");
_Static_assert(offsetof(sw_audio_ring, channels) == 4, "channels 偏移");
_Static_assert(offsetof(sw_audio_ring, sample_rate) == 8, "sample_rate 偏移");
_Static_assert(offsetof(sw_audio_ring, capacity_frames) == 12, "capacity_frames 偏移");
_Static_assert(offsetof(sw_audio_ring, stamp_capacity) == 16, "stamp_capacity 偏移");
_Static_assert(offsetof(sw_audio_ring, planes) == 24, "planes 偏移");
_Static_assert(offsetof(sw_audio_ring, stamps) == 88, "stamps 偏移");
_Static_assert(offsetof(sw_audio_ring, write_index) == 128, "write_index 必须独占第 3 条缓存线");
_Static_assert(offsetof(sw_audio_ring, stamp_write) == 136, "stamp_write 偏移");
_Static_assert(offsetof(sw_audio_ring, overruns) == 144, "overruns 偏移");
_Static_assert(offsetof(sw_audio_ring, read_index) == 192, "read_index 必须独占第 4 条缓存线");
_Static_assert(offsetof(sw_audio_ring, underruns) == 200, "underruns 偏移");
_Static_assert(sizeof(sw_audio_ring) == 256, "sw_audio_ring 应为 256 字节");
_Static_assert(_Alignof(sw_audio_ring) == 8, "sw_audio_ring 自然对齐 8（64 字节对齐由分配方保证；Swift 不导入过度对齐的结构）");

const uint32_t sw_audio_ring_layout_version = SW_AUDIO_RING_LAYOUT_VERSION;
