// SwitcherOutputs —— 编码、录制（W1-E 一期）；推流、NDI 发送（W2-D）；外部显示、虚拟摄像头、ISO（W3-C）。
//
// 一期的对象与线程（设计方案 §3.4、§8、§12 决策 7 / 10）：
//   VideoEncoder   FrameConsumer。`consume` 在引擎派发线程上只入有界队列（深度 2–3）立即返回，满了丢最旧并记 skipped（E1）；
//                  自己的线程把帧交给 VTCompressionSession；PTS = 拍点时刻（RenderedFrame.tickTime）。
//   AudioEncoder   AudioToolbox AudioConverter 的 AAC；输入 Master 块 + 块首样本 host time。给推流用（W2-D）。
//   Recorder       AVAssetWriter 写 .mov（movieFragmentInterval 1 s）；视频轨接 VideoEncoder 的压缩样本直通；
//                  音频轨接 PCM 块，writer 自己编 AAC / 写 LPCM（原因见 reports/w1-outputs.md 探针 7）。
//                  时间基：开始录制那一拍的拍点时刻 = 0。
//   PatternFeeder / SignalFeeder   测试喂料：TestPattern 写 NV12、TestSignal 写音频，按精确拍点喂，不需要合成引擎。
//
// 统计：每个对象只暴露原子计数（EncoderCounters / RecorderCounters），汇总进 Stats 的是引擎（铁律 4）；
// Stats.encoder[i] 只有 skipped / bitrate 两个字段，其余字段的去向见 docs/contract-changes/001-stats-encoder-fields.md。
import SwitcherContracts

/// 模块版本 = 契约版本（同一仓库、同一版本号）。
public enum SwitcherOutputsInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
