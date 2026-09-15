import SwitcherContracts

/// Master 混音块的消费者（编码 / 录制）。与契约 `AudioRing.write` 同一签名风格：非交错 float32、48 kHz、块首样本 host time。
///
/// 线程规则：`consumeAudio` 在**非实时**线程被调（把混音回调产出的块从 SPSC 环搬过来的泵线程，由组装方提供）；
/// 实现必须立即返回：只拷贝进自己的有界缓冲。永远不在音频实时回调里直接调它（铁律 3）。
/// 这个协议目前只在 SwitcherOutputs 内；是否升到契约见 reports/w1-outputs.md 第 4 节。
public protocol AudioBlockConsumer: AnyObject {
    /// 名字。
    var consumerName: String { get }
    /// 一块：`planes` 有 channelCount 个指针，每个指向 frameCount 个 float；`hostTime` 是块首样本的 host time。
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime)
}
