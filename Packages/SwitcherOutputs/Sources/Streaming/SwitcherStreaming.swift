// SwitcherStreaming —— 推流（W2-D）。设计方案 §8 推流行、§3.4；测试标准 E7–E9。
//
// 对象与线程：
//   StreamOutput     每个目的地一个实例。FrameConsumer（自己的 VideoEncoder，深度 2–3 的有界队列，与录制共享同一块 NV12 IOSurface）
//                    + AudioBlockConsumer（自己的 AudioEncoder，AAC）。编码后的样本进 SendQueue（有界，满了按策略丢并计数），
//                    一个独立的发送 Task 按时间顺序交给 StreamTransport；断线指数退避重连，重连后关键帧起步。
//   SendQueue        视频帧 + 音频包各一个有界环；丢帧口径见 StreamCounters。
//   StreamTransport  协议层抽象。生产实现 HaishinKitTransport（RTMP / RTMPS / SRT，只借它的连接 + 封装，编码是我们的）；
//                    测试用 FakeTransport 模拟阻塞 / 断线 / 限速。
//   ReconnectPolicy  1、2、4 … 最长 reconnectMaxSeconds（StreamSettings），可配。
//
// 多目的地互不影响：每个 StreamOutput 自己的编码器、队列、Task、连接对象；没有任何共享锁或共享队列。
// 统计：StreamCounters（原子），`statsEntry` 给 Stats.encoder[i]（skipped / bitrate）；帧数 / 网络丢帧 / 重连次数等待契约提案 002。
import SwitcherContracts

/// 模块版本 = 契约版本。
public enum SwitcherStreamingInfo {
    /// 与 `SwitcherVersion.current` 相同。
    public static let version = SwitcherVersion.current
}
