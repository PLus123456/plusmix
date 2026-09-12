// sw_audio_ring.h —— 音频环形缓冲的内存布局（契约，P1 冻结）。
//
// 这是 SwitcherContracts 里唯一的 C 头文件。它只定义"布局"，不定义实现：
//   - 实现（分配、write / read、SPSC 内存序）由 W1-D 在 SwitcherAudio 里用 C 写；
//   - Swift 侧的 `AudioRing` 协议要求实现暴露一个指向这个结构的指针（`raw`），
//     混音热路径（C，音频实时线程）拿这个指针直接读，不经过任何 Swift 对象。
// 为什么布局要冻结在契约里：写端（输入，Swift / C）和读端（混音，C）属于不同的包和不同的会话，
// 两边编译在同一份 offset 上，才能保证零拷贝、零 ARC、零锁（设计方案 §3.5）。
//
// 规则：
//   1. 采样格式：float32、非交错（每声道一个平面）、标称 48 kHz（SW_AUDIO_SAMPLE_RATE）。
//      输入设备不是 48 kHz 的，由输入侧先转成 48 kHz 再写；±ppm 级的时钟漂移由混音器的异步重采样吸收（§3.6）。
//   2. 单生产者单消费者（SPSC）。write_index 只有生产者写，read_index 只有消费者写，
//      都是单调递增的"累计帧数"（不取模）；位置 = index & (capacity_frames - 1)，所以容量必须是 2 的幂。
//   3. 每块带 host time：生产者每写一块，就在 stamps 环里追加一条 (首帧累计序号, 该帧的 host time)。
//      消费者按"最近一条 stamp 的 host_time + (帧序号差) × 每帧 host tick 数"算出任意一帧的 host time。
//      stamps 也是 SPSC 环，位置 = stamp_write & (stamp_capacity - 1)。
//   4. 计数字段的原子访问：生产者以 release 语义发布 write_index / stamp_write，消费者以 acquire 读；
//      read_index 反之。这里故意不用 C11 `_Atomic`（Swift 导不进来），用 __atomic_* 内建函数，见下面的内联辅助。
//   5. 生产者和消费者各自写的计数分在两条 64 字节缓存线上（偏移 128 和 192），避免伪共享。
//      用显式 padding 而不是 _Alignas(64)：Swift 不导入过度对齐的 C 结构（"record is over aligned"，P1 实测）。
//      结构自然对齐是 8；实现分配时必须自己保证 64 字节对齐（posix_memalign 或 allocate(byteCount:alignment: 64)）。
//   6. 任何字段的增删、顺序、对齐改动都是契约变更：改 SW_AUDIO_RING_LAYOUT_VERSION，并走 docs/contract-changes/。
//      Sources/CSwitcherContracts/layout.c 里的 _Static_assert 和 SwitcherContractsTests 各自钉死 offset。
#ifndef SW_AUDIO_RING_H
#define SW_AUDIO_RING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 内部标称采样率。
#define SW_AUDIO_SAMPLE_RATE 48000u
/// 一个环最多的声道数（planes 数组长度）。
#define SW_AUDIO_MAX_CHANNELS 8u
/// 布局版本。结构体任何改动都要 +1。
#define SW_AUDIO_RING_LAYOUT_VERSION 1u
/// 默认混音块大小（帧），等于设备 buffer size 的默认值（设计方案 §3.5）。
#define SW_AUDIO_DEFAULT_BLOCK_FRAMES 256u

/// 一块音频的时间戳：写入时该块首帧的累计序号和 host time（mach_absolute_time）。
typedef struct sw_audio_stamp {
    uint64_t frame_index;   ///< 该块第一帧的累计帧序号（与 write_index 同一计数）
    uint64_t host_time;     ///< 该帧的 host time（入口换算后的 mach 绝对时间，铁律 5）
} sw_audio_stamp;

/// 环形缓冲头。planes / stamps 指向的存储由实现分配（非实时线程），生命周期由实现管理。
typedef struct sw_audio_ring {
    // ---- 常量区：创建后不再改，两端都只读 ----
    uint32_t layout_version;    ///< == SW_AUDIO_RING_LAYOUT_VERSION
    uint32_t channels;          ///< 1 … SW_AUDIO_MAX_CHANNELS
    uint32_t sample_rate;       ///< 标称采样率，第一版恒为 SW_AUDIO_SAMPLE_RATE
    uint32_t capacity_frames;   ///< 每个平面的容量（帧），2 的幂
    uint32_t stamp_capacity;    ///< stamps 的条数，2 的幂
    uint32_t reserved0;         ///< 对齐占位，写 0
    float   *planes[SW_AUDIO_MAX_CHANNELS]; ///< 每声道 capacity_frames 个 float；未用的声道为 NULL（偏移 24）
    sw_audio_stamp *stamps;     ///< stamp_capacity 条（偏移 88）
    uint8_t  pad0[32];          ///< 填到 128

    // ---- 生产者区（偏移 128 起）：只有写线程改；独占一条缓存线 ----
    uint64_t write_index;       ///< 累计写入帧数（release 发布）
    uint64_t stamp_write;       ///< 累计写入的 stamp 条数（release 发布，在 write_index 之前发布）
    uint64_t overruns;          ///< 因环满而被生产者丢掉的帧数（累计）
    uint8_t  pad1[40];          ///< 填到 192

    // ---- 消费者区（偏移 192 起）：只有读线程改；独占一条缓存线 ----
    uint64_t read_index;        ///< 累计读出帧数（release 发布）
    uint64_t underruns;         ///< 读时不够而补零的帧数（累计）
    uint8_t  pad2[48];          ///< 填到 256
} sw_audio_ring;

// ---- 只读辅助（两端都可调；不改任何字段）----

/// 当前可读帧数（消费者视角：acquire 读 write_index）。
static inline uint64_t sw_audio_ring_available(const sw_audio_ring *ring) {
    uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_ACQUIRE);
    uint64_t r = __atomic_load_n(&ring->read_index, __ATOMIC_RELAXED);
    return w - r;
}

/// 当前可写帧数（生产者视角：acquire 读 read_index）。
static inline uint64_t sw_audio_ring_free_space(const sw_audio_ring *ring) {
    uint64_t r = __atomic_load_n(&ring->read_index, __ATOMIC_ACQUIRE);
    uint64_t w = __atomic_load_n(&ring->write_index, __ATOMIC_RELAXED);
    return (uint64_t)ring->capacity_frames - (w - r);
}

/// 累计帧序号 → 平面内偏移。
static inline uint32_t sw_audio_ring_offset(const sw_audio_ring *ring, uint64_t frame_index) {
    return (uint32_t)(frame_index & (uint64_t)(ring->capacity_frames - 1u));
}

/// 布局版本符号（layout.c 里定义），供运行期核对头文件与库是否一致。
extern const uint32_t sw_audio_ring_layout_version;

#ifdef __cplusplus
}
#endif

#endif /* SW_AUDIO_RING_H */
