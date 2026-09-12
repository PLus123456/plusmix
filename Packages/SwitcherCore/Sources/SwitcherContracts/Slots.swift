import CSwitcherContracts
// 帧槽与音频环的协议。只定协议（和 C 头文件里的布局），实现在别处：
//   FrameSlot  → SwitcherEngine（W1-B）
//   AudioRing  → SwitcherAudio（W1-D，C 实现，符合 sw_audio_ring.h）
// 输入实现（SwitcherInputs、TestKit）不自己 new 这两样：init 时由组装方注入 `any FrameSlot` / `any AudioRing`。

// MARK: - 帧槽

/// 帧槽统计（每路输入一份），全部是"自启动以来"的累计值，原子读。
///
/// 口径（测试标准 V4 的依据）：
/// - `pushed`：生产者 push 进来的帧数。
/// - `consumed`：`latest(atOrBefore:)` 返回了帧的次数（渲染线程每拍每路调一次，所以约等于用到这路的拍数）。
/// - `reused`：其中返回的是"上一次已经返回过的同一帧"的次数。30 fps 进 60 fps 节目 → reused / consumed = 50%（设计内）。
/// - `dropped`：从未被 `latest` 返回过就被淘汰的帧数（槽满被挤掉，或被更新的帧跳过）。
public struct FrameSlotStats: Hashable, Sendable, Codable {
    /// push 进来的帧数。
    public var pushed: UInt64
    /// latest 返回了帧的次数。
    public var consumed: UInt64
    /// 从未被消费就被淘汰的帧数。
    public var dropped: UInt64
    /// 返回的是上一次同一帧的次数。
    public var reused: UInt64
    public init(pushed: UInt64 = 0, consumed: UInt64 = 0, dropped: UInt64 = 0, reused: UInt64 = 0) {
        self.pushed = pushed
        self.consumed = consumed
        self.dropped = dropped
        self.reused = reused
    }
}

/// 每路输入一个的小队列（设计方案 §3.2、§12 决策 1）：采集线程写，渲染线程读，最多留 2–3 帧。
///
/// 线程规则：
/// - `push` 只能由该输入的采集线程调；`latest(atOrBefore:)` 只能由渲染线程调（单生产者单消费者）。
/// - 两者都不许加锁、不许分配（实现用无锁 SPSC + 原子量；Frame 是值类型，存取只是 retain / release）。
/// - `stats` 任何线程可读。
public protocol FrameSlot: AnyObject {
    /// 容量（帧），2–3。
    var capacity: Int { get }
    /// 生产者：放入一帧。槽满则淘汰最旧的一帧（若它从未被消费，dropped += 1）。
    func push(_ frame: Frame)
    /// 消费者：取 pts ≤ time 的最新帧；没有则返回 nil（保留旧帧不清空，方便无信号时显示最后一帧）。
    /// 返回的帧之前的旧帧从此不再返回（其中从未消费过的算 dropped）。
    func latest(atOrBefore time: HostTime) -> Frame?
    /// 累计统计。
    var stats: FrameSlotStats { get }
}

// MARK: - 音频环

/// 音频常量。采样格式：float32、非交错、48 kHz（sw_audio_ring.h 里的宏是同一组数）。
public enum AudioFormat {
    /// 内部采样率 48000。
    public static let sampleRate = Int(SW_AUDIO_SAMPLE_RATE)
    /// 一个环最多的声道数 8。
    public static let maxChannels = Int(SW_AUDIO_MAX_CHANNELS)
    /// 默认混音块大小 256。
    public static let defaultBlockFrames = Int(SW_AUDIO_DEFAULT_BLOCK_FRAMES)
}

/// 音频环统计（累计，原子读）。
public struct AudioRingStats: Hashable, Sendable, Codable {
    /// 累计写入帧数。
    public var framesWritten: UInt64
    /// 累计读出帧数。
    public var framesRead: UInt64
    /// 环满被丢的帧数（生产者侧）。
    public var overruns: UInt64
    /// 读不够补零的帧数（消费者侧）。
    public var underruns: UInt64
    public init(framesWritten: UInt64 = 0, framesRead: UInt64 = 0, overruns: UInt64 = 0, underruns: UInt64 = 0) {
        self.framesWritten = framesWritten
        self.framesRead = framesRead
        self.overruns = overruns
        self.underruns = underruns
    }
}

/// 一次 `read` 的结果。
public struct AudioReadResult: Hashable, Sendable {
    /// 实际读到的帧数（不够的部分实现已补零）。
    public var framesRead: Int
    /// 读到的第一帧的 host time；一帧都没读到时为 nil。
    public var firstFrameHostTime: HostTime?
    public init(framesRead: Int, firstFrameHostTime: HostTime?) {
        self.framesRead = framesRead
        self.firstFrameHostTime = firstFrameHostTime
    }
}

/// 每路输入一个的 SPSC 音频环（设计方案 §3.5、§3.6）。采集线程写，混音回调（实时线程，C）读。
///
/// 线程规则：
/// - `write` 只能由该输入的采集线程调，`read` 只能由混音线程调；都不许锁、不许分配、不许日志。
/// - 混音热路径不经过这个 Swift 协议：它拿 `raw` 指针，按 sw_audio_ring.h 的布局直接读。
///   `read` 是给 Swift 侧的离线工装 / 测试用的等价入口。
/// - 每块带 host time：`write` 的 `hostTime` 是该块首帧的时刻（入口换算后，铁律 5）。
public protocol AudioRing: AnyObject {
    /// 声道数（1 … AudioFormat.maxChannels）。
    var channelCount: Int { get }
    /// 标称采样率，第一版恒为 48000。
    var sampleRate: Int { get }
    /// 容量（帧），2 的幂。
    var capacityFrames: Int { get }
    /// 当前可读帧数。
    var availableFrames: Int { get }
    /// 累计统计。
    var stats: AudioRingStats { get }
    /// 生产者：写一块。`planes` 有 `channelCount` 个指针，每个指向 `frameCount` 个 float。
    /// 返回实际写入帧数；环满时少写并计 overruns。
    @discardableResult
    func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int
    /// 消费者：读 `frameCount` 帧进 `planes`（每个指针至少能放 `frameCount` 个 float）；不够补零并计 underruns。
    func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult
    /// C 布局的环本体，给混音热路径用；生命周期与本对象相同。
    var raw: UnsafeMutablePointer<sw_audio_ring> { get }
}
