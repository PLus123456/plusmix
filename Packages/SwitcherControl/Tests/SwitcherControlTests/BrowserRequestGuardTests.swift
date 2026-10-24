import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// Codex 10-24 网络安全审计 NS02（high）：默认 127.0.0.1:8765、没 token 时，带 `Origin: https://attacker.invalid` 的 WS 升级 101、
/// 立刻收到全量快照、setPreview 生效——任何能让本机浏览器发回环 WS 的网页都能读状态、切节目。HTTP 路由同样不看来源。
/// 握手照 reports/codex-network-security-audit-20261024-probes/probe.py.txt；浏览器的跨站请求还带 `Sec-Fetch-Site: cross-site`。
/// Stream Deck（ws 包）/ URLSession / Node 的 WebSocket 与 fetch / curl 两个头都不带（探针见 reports/w2-control-5.md §2），不受影响。
final class BrowserRequestGuardTests: XCTestCase {
    static let attacker = "https://attacker.invalid"
    static let setPreview3 = #"{"setPreview":{"input":3}}"#

    func startServer(token: String? = nil, allowedOrigins: [String] = []) async throws -> APIServerTests.Server {
        let f = BusFixture()
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: .fps60)
        let feed = StateFeed(stateMachine: f.stateMachine) { clock }
        await feed.start()
        let server = APIServer(bus: f.bus, feed: feed,
                               configuration: APIServerConfiguration(host: "127.0.0.1", port: 0, token: token, allowedOrigins: allowedOrigins))
        try await server.start()
        return APIServerTests.Server(fixture: f, feed: feed, server: server, clock: clock)
    }

    /// URLSession 的请求：浏览器的两个头由用例自己写（URLSession 本身不带）。
    func http(_ url: URL, method: String = "GET", body: String? = nil, headers: [String: String] = [:]) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body { req.httpBody = Data(body.utf8) }
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    func json(_ text: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] }

    // MARK: 规则表

    /// `BrowserOriginPolicy` 的规则：带 Origin 只看白名单（`null` 永远不在）；不带 Origin 看 Sec-Fetch-Site——none 放、
    /// same-origin 只在 Host 是 IP 字面量 / localhost 时放（DNS 重绑定的网页 Host 是它自己的域名）、别的拦；都不带放。
    func testNS02_originPolicy_rules() {
        let local = "127.0.0.1:8765"
        let none = BrowserOriginPolicy(allowedOrigins: [])
        XCTAssertTrue(none.allows(origin: nil, secFetchSite: nil, host: "rebind.attacker.invalid:8765"), "不是浏览器：不看 Host")
        for site in ["none", "None", " none "] { XCTAssertTrue(none.allows(origin: nil, secFetchSite: site, host: "rebind.attacker.invalid"), site) }
        for site in ["same-origin", " same-origin "] { XCTAssertTrue(none.allows(origin: nil, secFetchSite: site, host: local), site) }
        for site in ["cross-site", "same-site", "", "none, cross-site"] { XCTAssertFalse(none.allows(origin: nil, secFetchSite: site, host: local), site) }
        for host in ["127.0.0.1", "127.0.0.1:8765", "192.168.1.20:8088", "[::1]:8765", "[fe80::1]", "localhost:8765", "LOCALHOST", "studio.localhost:1",
                     "localhost.:8765"] {
            XCTAssertTrue(none.allows(origin: nil, secFetchSite: "same-origin", host: host), "\(host)：本机 / IP 字面量上的同源")
        }
        for host: String? in ["rebind.attacker.invalid:8765", "attacker.invalid", "studio.local:8765", "127.0.0.1.attacker.invalid", "1.2.3", "1.2.3.256",
                              "[evil.example]", "", nil] {
            XCTAssertFalse(none.allows(origin: nil, secFetchSite: "same-origin", host: host), "\(host ?? "nil")：域名上的同源 = DNS 重绑定")
        }
        for origin in [Self.attacker, "null", "", "http://127.0.0.1:8765"] {
            XCTAssertFalse(none.allows(origin: origin, secFetchSite: nil, host: local), origin)
            XCTAssertFalse(none.allows(origin: origin, secFetchSite: "same-origin", host: local), "\(origin)：带 Origin 只看白名单")
        }
        let some = BrowserOriginPolicy(allowedOrigins: ["HTTP://Panel.Local:8080/", "https://ops.example:443", "http://lan.example:80", "null", " "])
        XCTAssertEqual(some.allowedOrigins, ["http://panel.local:8080", "https://ops.example", "http://lan.example"], "规范化；null / 空白不进白名单")
        for origin in ["http://panel.local:8080", "http://PANEL.local:8080", "https://ops.example", "https://ops.example:443", "http://lan.example"] {
            XCTAssertTrue(some.allows(origin: origin, secFetchSite: "cross-site", host: local), "\(origin)：白名单里的跨站也放")
        }
        for origin in ["null", "http://panel.local:8081", "https://panel.local:8080", "http://panel.local:8080, https://attacker.invalid", Self.attacker] {
            XCTAssertFalse(some.allows(origin: origin, secFetchSite: nil, host: local), origin)
        }
        XCTAssertEqual(BrowserOriginPolicy.normalize("https://x.example:4443/"), "https://x.example:4443", "非默认端口留着")
        XCTAssertEqual(BrowserOriginPolicy.normalize("http://[::1]:80"), "http://[::1]")
    }

    /// DNS 重绑定：网页 http://rebind.attacker.invalid:<端口> 把自己的域名改解析到 127.0.0.1 之后，它的 GET 在浏览器看来是同源、不带 Origin，
    /// 只有 Host 是它的域名——403、不漏状态；同样的请求 Host 是本机地址（地址栏 / 本机调试页）照旧 200。
    func testNS02_dnsRebindingSameOriginGet_403() async throws {
        let s = try await startServer()
        defer { Task { await s.stop() } }
        let port = try XCTUnwrap(s.server.boundPort)
        for (host, expected) in [("rebind.attacker.invalid:\(port)", 403), ("127.0.0.1:\(port)", 200), ("localhost:\(port)", 200)] {
            for path in ["/api/v1/state", "/api/v1/log"] {
                let (status, body) = try RawWSClient.httpGet(port: port, path: path, headers: ["Host": host, "Sec-Fetch-Site": "same-origin"])
                XCTAssertEqual(status, expected, "\(host) \(path)")
                if expected == 403 { XCTAssertFalse(body.contains("\"preview\""), "\(host) \(path)：不漏状态") }
            }
        }
        let (status, _) = try RawWSClient.httpGet(port: port, path: "/api/v1/state", headers: ["Host": "rebind.attacker.invalid:\(port)"])
        XCTAssertEqual(status, 200, "不带 Sec-Fetch-Site 的（不是浏览器）不看 Host")
    }

    // MARK: WS 升级

    /// 外来网页的 WS 握手（带 Origin / `Origin: null` / `Sec-Fetch-Site: cross-site`）不升级、收不到 hello 和快照、不订阅，
    /// 升级失败的连接上补发的 setPreview 也到不了总线；不带这两个头的客户端照旧 101 + hello + 快照、命令照收。
    func testNS02_wsUpgradeFromForeignOrigin_refusedWithoutSnapshot_plainClientStillUpgrades() async throws {
        let s = try await startServer()
        defer { Task { await s.stop() } }
        let port = try XCTUnwrap(s.server.boundPort)
        let foreign: [[String: String]] = [["Origin": Self.attacker], ["Origin": "null"], ["Sec-Fetch-Site": "cross-site"],
                                           ["Origin": Self.attacker, "Sec-Fetch-Site": "cross-site"]]
        for headers in foreign {
            let ws = try RawWSClient(port: port, headers: headers)
            defer { ws.close() }
            print("NS02 \(headers) 的 WS 握手应答 = \(ws.status)")
            XCTAssertNotEqual(ws.status, 101, "\(headers)：外来来源的握手不能升级")
            XCTAssertTrue((400..<500).contains(ws.status), "\(headers)：拒绝要是 4xx，实际 \(ws.status)")
            XCTAssertNil(try ws.nextText(timeout: 0.3), "\(headers)：没升级就收不到 hello / 快照")
            try? ws.sendText(#"{"id":1,"command":{"setPreview":{"input":4}}}"#)   // Codex 探针的第二步；连接已经被拒，发不出去也算
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.feed.counters.subscribers, 0, "被拒的握手不订阅")
        XCTAssertEqual(s.fixture.bus.lastSequence, 0, "外来来源的命令不进总线")
        var state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 2)

        // 不带 Origin / Sec-Fetch-Site（Stream Deck 的 ws 包、URLSession、Node）：照旧
        let plain = try RawWSClient(port: port)
        defer { plain.close() }
        XCTAssertEqual(plain.status, 101)
        XCTAssertEqual(json(try XCTUnwrap(try plain.nextText(timeout: 5)))?["type"] as? String, "hello")
        XCTAssertEqual(json(try XCTUnwrap(try plain.nextText(timeout: 5)))?["type"] as? String, "snapshot")
        try plain.sendText(#"{"id":1,"command":{"setPreview":{"input":3}}}"#)
        var receipt: [String: Any]? = nil
        for _ in 0..<4 {
            guard let m = json(try XCTUnwrap(try plain.nextText(timeout: 5))) else { continue }
            if m["type"] as? String == "receipt" { receipt = m; break }
        }
        XCTAssertEqual(receipt?["applied"] as? Bool, true)
        state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 3)
    }

    // MARK: HTTP

    /// 浏览器跨站的 POST /api/v1/command（`Sec-Fetch-Site: cross-site` / same-site，或带外来 Origin、`Origin: null`）→ 403
    /// `{"error":"forbidden-origin"}`，命令不进总线；GET state / tally / commands / log 同样 403（不漏状态）；
    /// `Sec-Fetch-Site: none`（地址栏直接打开）/ same-origin 与不带头的照旧。
    func testNS02_crossSiteCommandAndState_403_stateUnchanged() async throws {
        let s = try await startServer()
        defer { Task { await s.stop() } }
        let command = s.baseURL.appending(path: "/api/v1/command")
        let foreign: [[String: String]] = [["Sec-Fetch-Site": "cross-site"], ["Sec-Fetch-Site": "same-site"], ["Origin": Self.attacker],
                                           ["Origin": Self.attacker, "Sec-Fetch-Site": "cross-site"], ["Origin": "null"],
                                           ["Origin": "http://127.0.0.1:\(s.server.boundPort!)", "Sec-Fetch-Site": "same-origin"]]
        for headers in foreign {
            let (st, body) = try await http(command, method: "POST", body: Self.setPreview3, headers: headers)
            XCTAssertEqual(st, 403, "\(headers)：\(body)")
            XCTAssertEqual(json(body) as? [String: String], ["error": "forbidden-origin"], "\(headers)")
            for path in ["/api/v1/state", "/api/v1/tally", "/api/v1/commands", "/api/v1/log"] {
                let (stGet, bodyGet) = try await http(s.baseURL.appending(path: path), headers: headers)
                XCTAssertEqual(stGet, 403, "\(headers) GET \(path)")
                XCTAssertFalse(bodyGet.contains("\"preview\""), "\(headers) GET \(path)：不漏状态")
            }
        }
        XCTAssertEqual(s.fixture.bus.lastSequence, 0, "被拦的命令不进总线")
        var state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 2)

        for headers in [[:], ["Sec-Fetch-Site": "none"], ["Sec-Fetch-Site": "same-origin"]] as [[String: String]] {
            let (st, body) = try await http(s.baseURL.appending(path: "/api/v1/state"), headers: headers)
            XCTAssertEqual(st, 200, "\(headers)")
            XCTAssertEqual((json(body)?["state"] as? [String: Any])?["preview"] as? Int, 2, "\(headers)")
        }
        let (st, body) = try await http(command, method: "POST", body: Self.setPreview3)
        XCTAssertEqual(st, 200, body)
        XCTAssertEqual(json(body)?["applied"] as? Bool, true)
        state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 3)
    }

    // MARK: 白名单 / token

    /// 白名单里的来源放行（HTTP 与 WS 升级，跨站也放）：不分大小写、配置里多写的结尾 / 与默认端口不算差别；
    /// 白名单外的照拦；`Origin: null`（沙箱 iframe、file://）即使白名单里写了 "null" 也拦。
    func testNS02_allowlistedOrigin_passesHTTPAndWS_othersStillRefused() async throws {
        let s = try await startServer(allowedOrigins: ["HTTP://Panel.Local:8080/", "https://ops.example:443", "null"])
        defer { Task { await s.stop() } }
        let port = try XCTUnwrap(s.server.boundPort)
        let command = s.baseURL.appending(path: "/api/v1/command")
        for origin in ["http://panel.local:8080", "https://ops.example"] {
            let headers = ["Origin": origin, "Sec-Fetch-Site": "cross-site"]
            let (st, body) = try await http(command, method: "POST", body: Self.setPreview3, headers: headers)
            XCTAssertEqual(st, 200, "\(origin)：\(body)")
            let ws = try RawWSClient(port: port, headers: headers)
            defer { ws.close() }
            XCTAssertEqual(ws.status, 101, origin)
            XCTAssertEqual(json(try XCTUnwrap(try ws.nextText(timeout: 5)))?["type"] as? String, "hello", origin)
        }
        for origin in [Self.attacker, "null", "http://panel.local:8081", "https://panel.local:8080"] {
            let (st, _) = try await http(command, method: "POST", body: #"{"setPreview":{"input":4}}"#, headers: ["Origin": origin])
            XCTAssertEqual(st, 403, origin)
            let ws = try RawWSClient(port: port, headers: ["Origin": origin])
            defer { ws.close() }
            XCTAssertNotEqual(ws.status, 101, origin)
        }
        let state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 3, "白名单外的 setPreview 4 都没生效")
    }

    /// 配了 token 也照拦：token 可能被嵌进网页（查询串 / 脚本），来源不对就 403——先查来源再查 token；不带来源头的照旧按 token。
    func testNS02_tokenConfigured_foreignOriginStillRefused() async throws {
        let s = try await startServer(token: "secret")
        defer { Task { await s.stop() } }
        let port = try XCTUnwrap(s.server.boundPort)
        let foreign = try RawWSClient(port: port, path: "/api/v1/events?token=secret", headers: ["Origin": Self.attacker])
        defer { foreign.close() }
        XCTAssertNotEqual(foreign.status, 101, "带对的 token、来源不对：不升级")
        XCTAssertNil(try foreign.nextText(timeout: 0.3))
        let plain = try RawWSClient(port: port, path: "/api/v1/events?token=secret")
        defer { plain.close() }
        XCTAssertEqual(plain.status, 101)
        let command = s.baseURL.appending(path: "/api/v1/command")
        let (st1, body1) = try await http(command, method: "POST", body: Self.setPreview3,
                                          headers: ["Authorization": "Bearer secret", "Sec-Fetch-Site": "cross-site"])
        XCTAssertEqual(st1, 403, body1)
        XCTAssertEqual(json(body1) as? [String: String], ["error": "forbidden-origin"])
        let (st2, body2) = try await http(command, method: "POST", body: Self.setPreview3, headers: ["Origin": Self.attacker])
        XCTAssertEqual(st2, 403, "没 token、来源不对：先报来源（\(body2)）")
        XCTAssertEqual(s.fixture.bus.lastSequence, 0)
        let (st3, _) = try await http(command, method: "POST", body: Self.setPreview3, headers: ["Authorization": "Bearer secret"])
        XCTAssertEqual(st3, 200)
        let (st4, _) = try await http(command, method: "POST", body: Self.setPreview3)
        XCTAssertEqual(st4, 401, "不带来源头的照旧按 token")
    }
}

/// 原始 WebSocket 客户端（POSIX socket）：浏览器会带的 Origin / Sec-Fetch-Site 原样写进握手（URLSessionWebSocketTask 两个都不带，
/// 也拿不到被拒时的状态码）。服务端的帧不加掩码、本客户端不协商压缩；发出去的帧按协议加掩码。
final class RawWSClient: @unchecked Sendable {
    private var fd: Int32
    private var buffer: [UInt8] = []
    /// 握手应答的状态码（101 = 升级了；0 = 没收到应答）。
    private(set) var status = 0

    init(port: Int, path: String = "/api/v1/events", headers: [String: String] = [:]) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.error("socket 失败") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(); throw Self.error("connect 127.0.0.1:\(port) 失败") }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { request += "\(name): \(value)\r\n" }
        try sendAll(Array((request + "\r\n").utf8))
        // 应答头读到空行为止；状态行 "HTTP/1.1 101 Switching Protocols"
        let deadline = Date().addingTimeInterval(5)
        var headEnd: Int? = nil
        while headEnd == nil {
            if let r = buffer.firstRange(of: Array("\r\n\r\n".utf8)) { headEnd = r.upperBound; break }
            guard fill(until: deadline) else { break }
        }
        guard let end = headEnd else { return }
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeFirst(end)
        status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        // 没升级：应答正文不是 WS 帧，丢掉（按 Content-Length 也好、读到关也好，用例只看状态码与"收不到帧"）
        if status != 101 { buffer.removeAll() }
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// 一次原始 HTTP GET（Host 也能写成别的——URLSession 不让改 Host）：读到对端关为止，回 (状态码, 正文)；`headers` 里没写 Host 就用本机地址。
    static func httpGet(port: Int, path: String, headers: [String: String]) throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw error("socket 失败") }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw error("connect 127.0.0.1:\(port) 失败") }
        var all = headers
        if all["Host"] == nil { all["Host"] = "127.0.0.1:\(port)" }
        var request = "GET \(path) HTTP/1.1\r\n"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { request += "\(name): \(value)\r\n" }
        request += "Connection: close\r\n\r\n"
        let bytes = Array(request.utf8)
        guard bytes.withUnsafeBufferPointer({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == bytes.count else { throw error("send 失败") }
        var response: [UInt8] = []
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &tmp, tmp.count, 0)
            guard n > 0 else { break }
            response += tmp[0..<n]
        }
        let text = String(decoding: response, as: UTF8.self)
        let status = text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return (status, body)
    }

    /// 下一条文本帧（跳过 ping / pong）；超时、对端关闭、没升级给 nil。
    func nextText(timeout: TimeInterval) throws -> String? {
        guard status == 101 else {
            // 没升级的连接上再读一次：服务端要是（错误地）推了东西，用例能看见
            let deadline = Date().addingTimeInterval(timeout)
            while fill(until: deadline) {}
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let frame = Self.parseFrame(buffer) {
                let (opcode, payload, used) = frame
                buffer.removeFirst(used)
                if opcode == 0x1 { return String(decoding: payload, as: UTF8.self) }
                if opcode == 0x8 { return nil }
                continue
            }
            guard fill(until: deadline) else { return nil }
        }
    }

    /// 发一条文本帧（客户端帧要加掩码）。
    func sendText(_ text: String) throws {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try sendAll(frame)
    }

    /// 服务端帧（不带掩码）：(opcode, 负载, 用掉的字节数)；不够一帧给 nil。
    static func parseFrame(_ b: [UInt8]) -> (UInt8, [UInt8], Int)? {
        guard b.count >= 2 else { return nil }
        var length = Int(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        guard b.count >= offset + length else { return nil }
        return (b[0] & 0x0F, Array(b[offset..<offset + length]), offset + length)
    }

    private func sendAll(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw Self.error("send 失败") }
            sent += n
        }
    }

    /// 从 socket 补一些字节；到 deadline 没数据、或对端关闭给 false。
    private func fill(until deadline: Date) -> Bool {
        guard fd >= 0 else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(max(0, deadline.timeIntervalSinceNow * 1000))) > 0 else { return false }
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &tmp, tmp.count, 0)
        guard n > 0 else { return false }
        buffer += tmp[0..<n]
        return true
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "rawws", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(text)：\(String(cString: strerror(errno)))"])
    }
}
