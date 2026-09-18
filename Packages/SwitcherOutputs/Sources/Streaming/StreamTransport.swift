import SwitcherContracts
import SwitcherOutputs

/// 传输层一次上报：还没发出去的字节、累计发出 / 收到的字节。HaishinKit 每秒给一次（NetworkMonitor），FakeTransport 精确给。
public struct TransportReport: Hashable, Sendable {
    /// 传输层队列里还没写进 socket 的字节。
    public var queuedBytes: Int
    /// 累计写进 socket 的字节（用来判断停滞：一直不涨 = 死连接）。
    public var totalBytesOut: Int
    /// 累计收到的字节。
    public var totalBytesIn: Int
    /// 这份上报产生的时刻。
    public var updatedAt: HostTime

    public init(queuedBytes: Int, totalBytesOut: Int, totalBytesIn: Int, updatedAt: HostTime) {
        self.queuedBytes = queuedBytes
        self.totalBytesOut = totalBytesOut
        self.totalBytesIn = totalBytesIn
        self.updatedAt = updatedAt
    }
}

/// 起步时音视频时间原点怎么对齐（HaishinKit 的两条封装层都把"各自第一个样本"当 0，见报告第 1 节）。
public enum StartAlignment: Hashable, Sendable {
    /// 视频用 DTS 作时间戳、PTS − DTS 写进 CTS（RTMP / FLV）：第一帧的 DTS 可以设成音频原点包的时刻，对齐精确到 1 ms。
    case dtsOffset
    /// 只能挑离关键帧最近的音频包当原点（误差 ≤ 半个 AAC 包 10.7 ms）；`prerollPackets` 个原点前的包也送（封装层要热身时用，TS 现在自己重发原点包，取 0）。
    case nearestPacket(prerollPackets: Int)
}

/// 传输层错误。
public enum StreamTransportError: Swift.Error, Equatable {
    case connectFailed(String)
    case connectTimedOut
    case notConnected
    case sendFailed(String)
}

/// 协议层抽象：连接 + 封装，接已编码样本。StreamOutput 的发送 Task 串行调用（一次只有一个 await 在途）。
/// 生产实现 HaishinKitTransport（RTMP / RTMPS / SRT），测试用 FakeTransport。
public protocol StreamTransport: AnyObject, Sendable {
    /// 协议名（rtmp / rtmps / srt / fake）。
    var protocolName: String { get }
    /// 起步对齐方式。
    var startAlignment: StartAlignment { get }
    /// 连接并进入发布状态；失败抛错。
    func connect() async throws
    /// 送一帧视频。`dtsOffset`：DTS = PTS − dtsOffset（只有 `.dtsOffset` 对齐的实现用它）。
    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws
    /// 送一个音频包，时间戳 = 包首样本 host time。
    func send(audio packet: EncodedAudioPacket) async throws
    /// 连接还活着吗（协议层自己的判断；停滞由 StreamOutput 用 report 判）。
    func isConnected() async -> Bool
    /// 最近一次上报。
    func report() async -> TransportReport
    /// 关闭；之后对象不再使用。
    func close() async
}

/// 造传输层对象（每次连接一个新对象：重连 = 新连接、新状态）。
public protocol StreamTransportFactory: Sendable {
    func makeTransport(for destination: StreamDestination, audioFormat: AudioEncoder.Configuration?) throws -> any StreamTransport
}
