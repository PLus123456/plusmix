import Logging
import SwitcherContracts

/// 兼容层配置。默认 **不启用**（设计方案 §0 / §9.3：法律灰区，用户在设置里显式打开）。
public struct VMixCompatConfiguration: Sendable, Hashable {
    /// 上游的 HTTP 默认端口。
    public static let defaultHTTPPort = 8088
    /// 上游的 TCP 默认端口。
    public static let defaultTCPPort = 8099

    /// 总开关；false 时 `VMixCompatServer.start()` 什么都不做，端口不监听。
    public var enabled = false
    /// 监听地址（HTTP 与 TCP 共用）；默认只听本机，Companion 在别的机器上时改 0.0.0.0。
    public var host = "127.0.0.1"
    /// HTTP 入口开关与端口（0 = 系统分配，测试用）。
    public var httpEnabled = true
    public var httpPort = VMixCompatConfiguration.defaultHTTPPort
    /// TCP 入口开关与端口。
    public var tcpEnabled = true
    public var tcpPort = VMixCompatConfiguration.defaultTCPPort
    /// StartRecording / StopRecording 操作哪个录制输出；nil = 编号最小的录制输出。
    public var recordOutput: Int? = nil
    /// StartStreaming / StopStreaming 没带 Value 时操作哪个推流输出；nil = 编号最小的推流输出（Value=k 选第 k 路，0 起）。
    public var streamOutput: Int? = nil
    /// XML `<version>` 与 TCP 问候里报的版本：就是本产品的版本，不冒充上游。
    public var reportedVersion = SwitcherVersion.current
    /// XML `<edition>`。
    public var edition = "Switcher"
    /// 日志级别。
    public var logLevel: Logger.Level = .warning

    public init() {}

    /// 解析 "host:port"、":port"、"port"、"host"（与 API 的写法一致）。
    public static func parseListen(_ text: String, defaultPort: Int) -> (host: String, port: Int)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let colon = s.lastIndex(of: ":") {
            let h = String(s[..<colon]), p = String(s[s.index(after: colon)...])
            guard let port = Int(p), (0...65535).contains(port) else { return nil }
            return (h.isEmpty ? "127.0.0.1" : h, port)
        }
        if let port = Int(s), (0...65535).contains(port) { return ("127.0.0.1", port) }
        return s.isEmpty ? nil : (s, defaultPort)
    }
}

/// 兼容层的错误码。TCP 上是 `<CMD> ER <码>: <文案>`，HTTP 上是对应状态码 + 同样的文本。
public enum CompatErrorCode: String, Hashable, Sendable, CaseIterable {
    /// 不认识的函数名（上游也没有这个名字）。
    case unknownFunction = "UnknownFunction"
    /// 上游有、这里没做的函数。
    case notImplemented = "NotImplemented"
    /// 参数缺失 / 格式不对 / 越界。
    case badParameter = "BadParameter"
    case inputNotFound = "InputNotFound"
    case outputNotFound = "OutputNotFound"
    /// 当前状态下做不了（没有录制输出、叠加通道没有输入、stinger 没设输入……）。
    case notConfigured = "NotConfigured"
    /// 命令总线的结构性拒绝（翻译层没拦住的）。
    case rejected = "Rejected"
    /// TCP 上不认识的命令字。
    case unknownCommand = "UnknownCommand"
    /// ACTS 不认识的激活器名。
    case unknownActivator = "UnknownActivator"
    case internalError = "InternalError"

    /// HTTP 状态码。
    public var httpStatus: Int {
        switch self {
        case .unknownFunction, .badParameter, .unknownCommand, .unknownActivator, .rejected: 400
        case .inputNotFound, .outputNotFound: 404
        case .notConfigured: 409
        case .notImplemented: 501
        case .internalError: 500
        }
    }
}

/// 兼容层错误：码 + 给人看的一句话。
public struct CompatError: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: CompatErrorCode
    public var message: String
    public init(code: CompatErrorCode, message: String) {
        self.code = code
        self.message = message
    }
    /// "NotImplemented: Merge is an upstream function this layer does not implement"。
    public var wireText: String { "\(code.rawValue): \(message)" }
    public var httpStatus: Int { code.httpStatus }
    public var description: String { wireText }
}
