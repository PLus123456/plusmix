import SwitcherContracts

/// 混音块（Master / 某条总线 / 某路输入推子后）的消费者：录制、编码、推流、NDI 发送。
///
/// 与 W1-E 的 `SwitcherOutputs.AudioBlockConsumer` 逐字同签名（`consumerName` + `consumeAudio(planes:channelCount:frameCount:hostTime:)`），
/// 所以组装方对 Recorder 写一行 `extension Recorder: AudioBlockConsuming {}` 就能接上；提案 001 把它升进契约后两边都改成 typealias。
/// 线程规则：在泵线程（非实时）上被调，必须立即返回（只拷进自己的有界缓冲）；永远不在音频实时回调里被调。
/// `hostTime` = 这块首样本的 host time，已按对齐延迟修正到"内容被采集的时刻"，与视频拍点同一时基（PTS 直接用）。
public protocol AudioBlockConsuming: AnyObject {
    var consumerName: String { get }
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime)
}

/// 消费者从哪里取块。
public enum AudioTapSource: Hashable, Sendable {
    /// Master 总线（总线增益之后）。
    case master
    /// 某条总线（总线增益之后）。`.bus(.master)` 与 `.master` 等价。
    case bus(Bus)
    /// 某路输入的推子后立体声（含增益 / 静音 / AFV 门控 / 声像 / 对齐延迟 / 延迟补偿）—— ISO 音轨。
    /// 注意：AFV 开着时非 PGM 输入的 ISO 是静音的（W1-D 的 tap 点在 AFV 之后；推子前 tap 要改 C，见报告 §4）。
    case input(number: Int)

    var normalized: AudioTapSource {
        if case .bus(.master) = self { return .master }
        return self
    }
}

/// 消费者注册凭据（removeConsumer 用）。
public struct AudioConsumerToken: Hashable, Sendable {
    let id: UInt64
    public let source: AudioTapSource
}

/// 集成层错误。
public enum AudioEngineError: Error, CustomStringConvertible, Equatable {
    case inputNotRegistered(Int)
    case inputAlreadyRegistered(Int)
    case noFreeSlot
    case tapUnavailable
    case notStarted
    case alreadyStarted
    public var description: String {
        switch self {
        case .inputNotRegistered(let n): "输入 \(n) 没有注册音频环"
        case .inputAlreadyRegistered(let n): "输入 \(n) 已经注册过音频环"
        case .noFreeSlot: "混音器槽位用完"
        case .tapUnavailable: "混音器消费者队列已满（最多 8 个来源）"
        case .notStarted: "音频引擎没有 start"
        case .alreadyStarted: "音频引擎已经 start"
        }
    }
}
