import Foundation
import SwitcherContracts

/// 推流目的地：由契约 `StreamSettings{url, streamKey}` 解析出协议和各层要的地址形态。
///
/// - RTMP / RTMPS：`url` = rtmp://[user:pass@]host[:port]/app[/name][?query]；`streamKey` 非空时作为 name（发布名），
///   否则 url 最后一段是 name、前面是 app（只有一段时 app = 那一段、name 为空，MediaMTX 的 rtmp://host/path 就是这种）。
///   user:pass@ 留在 connectURL 里（W5-D），用户名 / 密码按 RFC 3986 只转义一次；连接时由 RTMPTransport 拿去做 Adobe 鉴权（RTMPAdobeAuth）。
/// - SRT：`url` = srt://host:port?streamid=…&passphrase=…&latency=…；`streamKey` 非空且 url 没带 streamid 时补成 streamid=streamKey。
public struct StreamDestination: Hashable, Sendable, CustomStringConvertible {
    /// 协议。
    public enum Scheme: String, Hashable, Sendable {
        case rtmp, rtmps, srt
    }

    /// 解析错误。带的地址是打过码的（`StreamURLRedaction`）：App 会把错误原文写进日志和提示。
    public enum Error: Swift.Error, Equatable {
        case invalidURL(String)
        case unsupportedScheme(String)
        case missingHost
    }

    /// 地址里写的用户名 / 密码（已解码）。
    public struct Credentials: Hashable, Sendable {
        public var user: String
        public var password: String

        public init(user: String, password: String) {
            self.user = user
            self.password = password
        }
    }

    public let scheme: Scheme
    /// 主机名（日志 / 测试用）。
    public let host: String
    /// 端口（url 没写就是协议默认：rtmp 1935、rtmps 443、srt 9710）。
    public let port: Int
    /// RTMP：connect 命令用的地址（rtmp://[user:pass@]host:port/app[?query]）；SRT：完整地址（含 streamid）。
    public let connectURL: String
    /// connectURL 去掉 user:pass@。RTMP 交给 HaishinKit 的是这个（加上 Adobe 鉴权参数）：它看到 userinfo 就会走自带的那套鉴权（见 RTMPAdobeAuth）。
    public let connectURLWithoutCredentials: String
    /// RTMP / RTMPS 地址里的 user:pass@（只写了用户名时密码为空串）；没写、用户名为空、或 SRT → nil。
    public let credentials: Credentials?
    /// RTMP 的发布名（publish name）；SRT 为空。
    public let streamName: String

    public init(settings: StreamSettings) throws {
        let trimmed = settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let schemeText = comps.scheme?.lowercased() else {
            throw Error.invalidURL(StreamURLRedaction.redact(url: trimmed))
        }
        guard let scheme = Scheme(rawValue: schemeText) else { throw Error.unsupportedScheme(schemeText) }
        guard let host = comps.host, !host.isEmpty else { throw Error.missingHost }
        self.scheme = scheme
        self.host = host
        switch scheme {
        case .rtmp, .rtmps:
            port = comps.port ?? (scheme == .rtmp ? 1935 : 443)
            var segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let key = settings.streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if !key.isEmpty {
                name = key
            } else if segments.count >= 2 {
                name = segments.removeLast()
            } else {
                name = ""
            }
            var c = URLComponents()
            c.scheme = schemeText
            c.host = host
            c.port = comps.port
            c.path = "/" + segments.joined(separator: "/")
            c.percentEncodedQuery = comps.percentEncodedQuery      // 查询串原样（解码再编码会把 %26 变成 &）
            let bare = c.string ?? trimmed
            // 用户名 / 密码：先解码再交给 URLComponents 编码 = 只转义一次（已转义的不会变成 %2540，手敲的 @ 空格 中文转一次）
            c.user = comps.user
            c.password = comps.password
            connectURL = c.string ?? trimmed
            connectURLWithoutCredentials = bare
            credentials = comps.user.flatMap { $0.isEmpty ? nil : Credentials(user: $0, password: comps.password ?? "") }
            streamName = name
        case .srt:
            port = comps.port ?? 9710
            var items = comps.queryItems ?? []
            let key = settings.streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !items.contains(where: { $0.name == "streamid" }) {
                items.append(URLQueryItem(name: "streamid", value: key))
            }
            var c = comps
            c.queryItems = items.isEmpty ? nil : items
            connectURL = c.string ?? trimmed
            connectURLWithoutCredentials = connectURL
            credentials = nil
            streamName = ""
        }
    }

    /// 不带密钥的描述（日志用）。
    public var description: String {
        switch scheme {
        case .rtmp, .rtmps: return "\(scheme.rawValue)://\(host):\(port)/…"
        case .srt: return "srt://\(host):\(port)"
        }
    }
}
