import Foundation
import Hummingbird
import Logging

// 浏览器来源拦截（Codex 10-24 网络审计 NS02 / NS05，prompt 131）：主 API 的 HTTP 路由、WS 升级与兼容层 HTTP 三处共用。
// 默认本机 API 没 token，任何网页都能让浏览器往 127.0.0.1 发 WS 握手 / fetch / <img>：原来读得到全量状态、切得了节目。
// 浏览器发的请求带 `Origin`（WS 握手、跨源 fetch、非 GET 一定带）和 `Sec-Fetch-Site`（主流浏览器每个请求都带）；
// Stream Deck 插件（ws 包）、Companion / Node 的 fetch 与 WebSocket、curl、URLSession 两个都不带（探针见 reports/w2-control-5.md §2），不受影响。
// 规则：
//   - 带 Origin：在白名单里才放（不分大小写，结尾的 / 与默认端口不算差别）；`null`（沙箱 iframe、file:// 页面）永远不算在白名单里；
//   - 不带 Origin、带 Sec-Fetch-Site：放 `none`（地址栏直接打开）；`same-origin` 只在 Host 是 IP 字面量 / localhost 时放；
//     `cross-site` / `same-site`（<img>、链接、表单）拦。same-origin 看 Host 是防 DNS 重绑定：网页把自己的域名改解析到 127.0.0.1 之后，
//     它对 API 的 GET 在浏览器看来是同源、不带 Origin——兼容层的 GET /api?Function=Cut 就这么能切节目；而这两个服务不出网页，
//     真同源只可能是地址栏里本机地址开的页面，Host 是 IP 或 localhost（比 prompt 131 写的"none / same-origin 都放"严一点，报告里有记）；
//   - 两个都不带：不是浏览器，放（token 照旧另查）。不带 Fetch Metadata 的老浏览器（2023 年以前的 Safari 之类）的 <img> 拦不住——macOS 15 起的系统浏览器都带。
// 拦下 = 403，命令不进总线、WS 不升级不订阅。token 配了也照拦（token 可能被嵌进网页），所以它装在 token 之前。
// 同一个头出现多次时按 ", " 拼起来比，拼出来的不会等于任何白名单项 / none——宁可拦。

/// 浏览器来源的放行规则。
public struct BrowserOriginPolicy: Sendable, Hashable {
    /// 规范化之后的白名单。
    public let allowedOrigins: Set<String>

    /// - Parameter allowedOrigins: 放行的 `Origin` 值（"http://panel.local:8080"）；空 = 不放任何网页。
    public init(allowedOrigins: [String]) {
        self.allowedOrigins = Set(allowedOrigins.map(Self.normalize).filter { $0 != "null" && !$0.isEmpty })
    }

    /// 这个请求放不放。`origin` / `secFetchSite` 是两个头的原值、`host` 是 Host 头（HTTP/1.1 的 authority，可带端口），没有给 nil。
    public func allows(origin: String?, secFetchSite: String?, host: String?) -> Bool {
        if let origin { return allowedOrigins.contains(Self.normalize(origin)) }
        guard let site = secFetchSite?.trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        switch site {
        case "none": return true
        case "same-origin": return Self.isLiteralLocalHost(host)
        default: return false
        }
    }

    /// Host（去掉端口）是不是外面的域名重绑定不成的：IP 字面量（IPv4 点分、[IPv6]）、localhost、*.localhost（RFC 6761 固定指本机）。
    public static func isLiteralLocalHost(_ host: String?) -> Bool {
        guard var h = host?.trimmingCharacters(in: .whitespaces).lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return false }
            let inside = h[h.index(after: h.startIndex)..<close]
            return !inside.isEmpty && inside.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber } && (Int(p) ?? 256) <= 255 }
    }

    /// "HTTP://Panel.Local:80/" → "http://panel.local"：小写、去掉结尾的 /、去掉 scheme 的默认端口（浏览器写 Origin 时本来就不带）。
    public static func normalize(_ origin: String) -> String {
        var s = origin.trimmingCharacters(in: .whitespaces).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        for (scheme, port) in [("http://", ":80"), ("https://", ":443")] where s.hasPrefix(scheme) && s.hasSuffix(port) {
            s.removeLast(port.count)
        }
        return s
    }
}

/// 中间件：不放的请求直接回 `forbidden()`（主 API 是 JSON，兼容层是纯文本），不往下走。
public struct BrowserRequestGuard<Context: RequestContext>: RouterMiddleware {
    public let policy: BrowserOriginPolicy
    let forbidden: @Sendable () -> Response

    public init(allowedOrigins: [String], forbidden: @escaping @Sendable () -> Response) {
        policy = BrowserOriginPolicy(allowedOrigins: allowedOrigins)
        self.forbidden = forbidden
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let origin = request.headers[.origin]
        // Sec-Fetch-Site 没有现成的名字常量（Hummingbird 只导出 HTTPFields）：按规范名找
        let sites = request.headers.filter { $0.name.canonicalName == "sec-fetch-site" }.map(\.value)
        let site = sites.isEmpty ? nil : sites.joined(separator: ", ")
        let host = request.head.authority   // HTTP/1.1 的 Host 头（NIO 换成 HTTPRequest 时挪进 authority）
        guard policy.allows(origin: origin, secFetchSite: site, host: host) else {
            context.logger.debug("refused browser request", metadata: ["origin": "\(origin ?? "-")", "sec-fetch-site": "\(site ?? "-")",
                                                                       "host": "\(host ?? "-")", "path": "\(request.uri.path)"])
            return forbidden()
        }
        return try await next(request, context)
    }
}
