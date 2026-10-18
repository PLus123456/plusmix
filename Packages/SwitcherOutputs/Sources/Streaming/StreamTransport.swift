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

/// 服务器拒绝鉴权的原因（W2-D4）。类型化：StreamOutput 按它"第一次就停在 failed、不再退避重试"（重试密码也不会自己变对，
/// 每次还白打服务器几个连接），App 按它给提示——都不按错误文字匹配。传输层从协议字段认：RTMP 的状态码，加上 Adobe 那套写在描述里的 reason / authmod 参数。
public enum StreamAuthFailure: Hashable, Sendable {
    /// 用户名或密码不对：Adobe 挑战的应答被拒（connect 回 NetConnection.Connect.Rejected，描述里 reason=authfailed）。
    case badCredentials
    /// 用户名不对：Adobe 第 2 轮服务器回 reason=nosuchuser。
    case noSuchUser
    /// publish 被拒：NetStream.Publish.Unauthorized（MediaMTX 一类按查询串 ?user=&pass= 鉴权的服务器，账号不对或没给）。
    case publishUnauthorized
    /// 服务器要 Adobe 鉴权、地址里没写账号（connect 回 Rejected，描述里有 authmod=adobe、没有 reason）。
    case credentialsRequired
    /// 服务器要的鉴权方式不支持（authmod=llnw，Limelight）。
    case unsupportedMethod

    /// last_error / 日志那一句的开头（后面接"：" + 服务器回的原文）。
    public var summary: String {
        switch self {
        case .badCredentials, .noSuchUser, .publishUnauthorized: return "鉴权失败（用户名或密码不对）"
        case .credentialsRequired: return "鉴权失败（服务器要用户名和密码，地址里没写）"
        case .unsupportedMethod: return "鉴权失败（服务器要的鉴权方式不支持）"
        }
    }
}

/// 传输层错误。
public enum StreamTransportError: Swift.Error, Equatable {
    case connectFailed(String)
    case connectTimedOut
    case notConnected
    case sendFailed(String)
    /// 服务器拒绝鉴权（W2-D4）。message = "鉴权失败（用户名或密码不对）：<服务器回的状态码与描述>"（打过码、不带密码），StreamOutput 原样写进 last_error。
    case authenticationFailed(StreamAuthFailure, message: String)
}

/// last_error / 日志用的一句：只取原因本身（W4C3 第 8 条，G10 胶水 ③：原来 `"\(error)"` 把 `connectFailed("…")` 的 case 名和引号带进状态窗）。
extension StreamTransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectFailed(let m), .sendFailed(let m), .authenticationFailed(_, let m): return m
        case .connectTimedOut: return "连接超时"
        case .notConnected: return "没连上"
        }
    }
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
