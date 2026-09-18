import Foundation
import SwitcherContracts

/// 推流目的地：由契约 `StreamSettings{url, streamKey}` 解析出协议和各层要的地址形态。
///
/// - RTMP / RTMPS：`url` = rtmp://host[:port]/app[/name]；`streamKey` 非空时作为 name（发布名），
///   否则 url 最后一段是 name、前面是 app（只有一段时 app = 那一段、name 为空，MediaMTX 的 rtmp://host/path 就是这种）。
/// - SRT：`url` = srt://host:port?streamid=…&passphrase=…&latency=…；`streamKey` 非空且 url 没带 streamid 时补成 streamid=streamKey。
public struct StreamDestination: Hashable, Sendable, CustomStringConvertible {
    /// 协议。
    public enum Scheme: String, Hashable, Sendable {
        case rtmp, rtmps, srt
    }

    /// 解析错误。
    public enum Error: Swift.Error, Equatable {
        case invalidURL(String)
        case unsupportedScheme(String)
        case missingHost
    }

    public let scheme: Scheme
    /// 主机名（日志 / 测试用）。
    public let host: String
    /// 端口（url 没写就是协议默认：rtmp 1935、rtmps 443、srt 9710）。
    public let port: Int
    /// RTMP：connect 命令用的地址（rtmp://host:port/app）；SRT：完整地址（含 streamid）。
    public let connectURL: String
    /// RTMP 的发布名（publish name）；SRT 为空。
    public let streamName: String

    public init(settings: StreamSettings) throws {
        let trimmed = settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let schemeText = comps.scheme?.lowercased() else {
            throw Error.invalidURL(settings.url)
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
            c.query = comps.query
            connectURL = c.string ?? trimmed
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
