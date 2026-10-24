import Logging

/// API 服务配置。
public struct APIServerConfiguration: Sendable, Hashable {
    /// 默认端口：8765（W2-C 选的，避开常见直播软件的默认端口，报告里有记录）。
    public static let defaultPort = 8765

    /// 监听地址；默认只监听本机回环，要给别的机器用改成 0.0.0.0。
    public var host: String = "127.0.0.1"
    /// 端口；0 = 系统分配（测试用），实际端口从 `APIServer.boundPort` 读。
    public var port: Int = defaultPort
    /// 简单 token 鉴权；nil = 关（默认）。
    public var token: String? = nil
    /// 放行的浏览器来源（`Origin` 头的值，例如 "http://panel.local:8080"）；默认空 = 不放任何网页（Codex 10-24 审计 NS02，见 `BrowserRequestGuard`）。
    public var allowedOrigins: [String] = []
    /// Hummingbird 的日志级别（默认只报 warning 以上，headless 的标准输出留给统计）。
    public var logLevel: Logger.Level = .warning

    public init(host: String = "127.0.0.1", port: Int = APIServerConfiguration.defaultPort, token: String? = nil, logLevel: Logger.Level = .warning,
                allowedOrigins: [String] = []) {
        self.host = host
        self.port = port
        self.token = token
        self.logLevel = logLevel
        self.allowedOrigins = allowedOrigins
    }

    /// 解析 "host:port"、":port"、"port"、"host"。
    public static func parseListen(_ text: String) -> (host: String, port: Int)? {
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
