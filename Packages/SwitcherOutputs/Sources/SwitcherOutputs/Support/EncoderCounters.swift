import Synchronization
import SwitcherContracts

/// 一个编码器的累计计数（值快照）。全部自启动累计，单调不减；窗口量由读方相减（同 Stats 的口径）。
public struct EncoderCounters: Hashable, Sendable {
    /// `consume` 收到的帧数。
    public var pushed: UInt64 = 0
    /// 编码器回调交出的帧数。
    public var encoded: UInt64 = 0
    /// E1 编码滞后跳帧：有界队列满时丢掉的最旧帧数（Stats.encoder[i].skipped）。
    public var skipped: UInt64 = 0
    /// 编码器自己丢的帧（VT 回调带 frameDropped）。
    public var droppedByEncoder: UInt64 = 0
    /// 编码出错的帧。
    public var failed: UInt64 = 0
    /// 累计输出字节；bitrate = 窗口内 Δbytes × 8 / 秒。
    public var bytes: UInt64 = 0
    /// 累计关键帧数。
    public var keyframes: UInt64 = 0
    /// 当前队列里等编码的帧数（瞬时值）。
    public var queueDepth: Int = 0
    /// 最近一帧"进编码器 → 回调"的延迟（host tick）。
    public var lastLatency: HostDuration = .zero
    /// 自启动以来的最大延迟。
    public var maxLatency: HostDuration = .zero

    public init() {}

    /// 恒等式：pushed == encoded + skipped + droppedByEncoder + failed + queueDepth + 在途帧。队列空且编码器 flush 后在途为 0。
    public var accountedFrames: UInt64 { encoded + skipped + droppedByEncoder + failed + UInt64(queueDepth) }

    /// 生成 Stats.encoder 的一项：skipped 直接用，bitrate 由与上一次快照的字节差算（previous 为 nil 时按 0 起算）。
    public func statsEntry(previous: EncoderCounters?, windowSeconds: Double) -> Stats.EncoderEntry {
        let delta = bytes &- (previous?.bytes ?? 0)
        let bitrate = windowSeconds > 0 ? Double(delta) * 8 / windowSeconds : 0
        return Stats.EncoderEntry(skipped: skipped, bitrate: bitrate)
    }
}

/// 原子计数器（编码线程 / 回调线程写，任意线程读）。`snapshot()` 逐字段 relaxed 读，不保证跨字段一致，够统计用。
final class AtomicEncoderCounters: Sendable {
    let pushed = Atomic<UInt64>(0)
    let encoded = Atomic<UInt64>(0)
    let skipped = Atomic<UInt64>(0)
    let droppedByEncoder = Atomic<UInt64>(0)
    let failed = Atomic<UInt64>(0)
    let bytes = Atomic<UInt64>(0)
    let keyframes = Atomic<UInt64>(0)
    let queueDepth = Atomic<Int>(0)
    let lastLatencyTicks = Atomic<Int64>(0)
    let maxLatencyTicks = Atomic<Int64>(0)

    func recordLatency(_ d: HostDuration) {
        lastLatencyTicks.store(d.ticks, ordering: .relaxed)
        var current = maxLatencyTicks.load(ordering: .relaxed)
        while d.ticks > current {
            let (exchanged, original) = maxLatencyTicks.compareExchange(expected: current, desired: d.ticks, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    func snapshot() -> EncoderCounters {
        var c = EncoderCounters()
        c.pushed = pushed.load(ordering: .relaxed)
        c.encoded = encoded.load(ordering: .relaxed)
        c.skipped = skipped.load(ordering: .relaxed)
        c.droppedByEncoder = droppedByEncoder.load(ordering: .relaxed)
        c.failed = failed.load(ordering: .relaxed)
        c.bytes = bytes.load(ordering: .relaxed)
        c.keyframes = keyframes.load(ordering: .relaxed)
        c.queueDepth = queueDepth.load(ordering: .relaxed)
        c.lastLatency = HostDuration(ticks: lastLatencyTicks.load(ordering: .relaxed))
        c.maxLatency = HostDuration(ticks: maxLatencyTicks.load(ordering: .relaxed))
        return c
    }
}
