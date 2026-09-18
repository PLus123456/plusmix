import Foundation
import SwitcherContracts

/// 开始录制的那一拍：时间基的 0 点。ISO 分路的多个 Recorder 用同一个值启动，起点就完全相同。
public struct RecordingStart: Hashable, Sendable, Codable {
    /// 起始拍（这一拍的帧是文件的第一帧）。
    public var tick: Tick
    /// 这一拍的拍点时刻 = 文件时间 0。
    public var tickTime: HostTime
    public init(tick: Tick, tickTime: HostTime) {
        self.tick = tick
        self.tickTime = tickTime
    }
    /// 从节目时钟取。
    public init(clock: TickClockSpec, tick: Tick) {
        self.init(tick: tick, tickTime: clock.time(of: tick))
    }
}

/// 录制结束后的结果。
public struct RecordingResult: Sendable {
    /// .mov 路径。
    public var url: URL
    /// 转封装成功时的 .mp4 路径。
    public var mp4URL: URL?
    /// 转封装失败的原因（.mov 保留）。
    public var remuxError: String?
    /// 写进文件的视频帧数。
    public var videoFrames: UInt64
    /// 写进文件的音频帧（样本）数。
    public var audioFrames: UInt64
    /// 按拍算的时长（秒）= 视频帧数 × 帧时长。
    public var durationSeconds: Double
    /// 编码器输出字节（≈ 视频轨大小）。
    public var videoBytes: UInt64
    /// 编码器计数快照。
    public var encoder: EncoderCounters
    /// 起点。
    public var start: RecordingStart
    /// 结束拍（不含）。
    public var stopTick: Tick
}

/// 录制器计数（值快照）。
public struct RecorderCounters: Hashable, Sendable {
    /// 写进文件的视频帧数。
    public var videoFrames: UInt64 = 0
    /// writer 不接（isReadyForMoreMediaData 长时间 false）而丢的视频帧。
    public var videoFramesRejected: UInt64 = 0
    /// 写进文件的音频帧（样本）数。
    public var audioFrames: UInt64 = 0
    /// 入口环满丢的音频块。
    public var audioBlocksDropped: UInt64 = 0
    /// 音频块 host time 与样本计数时间轴的最新偏差（host tick，正 = 音频块比样本计数晚到）。
    public var audioDrift: HostDuration = .zero
    /// 因偏差超阈值做过的硬校正次数（插静音 / 丢样本）。
    public var audioCorrections: UInt64 = 0
    /// 录制目录所在卷的剩余空间（字节），每秒刷新一次。
    public var diskFreeBytes: UInt64 = 0
    /// 编码器计数。
    public var encoder = EncoderCounters()
    public init() {}

    /// Stats.encoder 的一项（提案 001 / 002，P2 落地）：skipped / bitrate 来自编码器计数（`EncoderCounters.statsEntry`）；
    /// frames = videoFrames（写进文件的）；dropped = videoFramesRejected（writer 不接的）；disk_free_mb = diskFreeBytes / 2^20（与 rss_mb 同口径）；
    /// reconnects = 0；state 由录制器给（`Recorder.State.statsName`：idle / recording / stopping / stopped / failed）。
    public func statsEntry(previous: RecorderCounters?, windowSeconds: Double, state: String) -> Stats.EncoderEntry {
        var e = encoder.statsEntry(previous: previous?.encoder, windowSeconds: windowSeconds)
        e.frames = videoFrames
        e.dropped = videoFramesRejected
        e.diskFreeMb = Double(diskFreeBytes) / 1_048_576
        e.reconnects = 0
        e.state = state
        return e
    }
}
