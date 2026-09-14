import CoreMedia
import SwitcherContracts

/// 编码器交出的一帧压缩视频。`sampleBuffer` 的 PTS = 拍点时刻（绝对 host time 纳秒，timescale 1e9），
/// 时长 = 节目一帧；接收方（录制 / 推流）自己减去各自的起点再换 timescale。
///
/// `@unchecked Sendable`：CMSampleBuffer 交出后只读；引用计数管理生命周期。
public struct EncodedVideoSample: @unchecked Sendable {
    /// 压缩样本（H.264 / HEVC / ProRes），带格式描述（参数集在里面）。
    public let sampleBuffer: CMSampleBuffer
    /// 哪一拍。
    public let tick: Tick
    /// 拍点时刻（= PTS）。
    public let tickTime: HostTime
    /// 是否关键帧（同步样本）。
    public let isKeyframe: Bool
    /// 压缩后的字节数。
    public let byteCount: Int
    /// 进编码器（EncodeFrame 调用）→ 回调 的延迟。
    public let encodeLatency: HostDuration
    /// 回调时刻（L3 编码器输出时刻用它）。
    public let outputTime: HostTime

    public init(sampleBuffer: CMSampleBuffer, tick: Tick, tickTime: HostTime, isKeyframe: Bool, byteCount: Int,
                encodeLatency: HostDuration, outputTime: HostTime) {
        self.sampleBuffer = sampleBuffer
        self.tick = tick
        self.tickTime = tickTime
        self.isKeyframe = isKeyframe
        self.byteCount = byteCount
        self.encodeLatency = encodeLatency
        self.outputTime = outputTime
    }

    /// 格式描述（第一帧的给 AVAssetWriter 当 sourceFormatHint）。
    public var formatDescription: CMFormatDescription? { CMSampleBufferGetFormatDescription(sampleBuffer) }
}
