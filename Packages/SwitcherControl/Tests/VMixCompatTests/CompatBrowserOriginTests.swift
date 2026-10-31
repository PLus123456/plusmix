import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// Codex 10-24 审计 NS05：兼容层开着时，带外部 Origin 的 `GET /api?Function=Cut` 200、program 变了——上游协议就是 GET、没有 token，
/// 任何网页一个 `<img src=…>` / fetch 就能切节目、停录制。修后与主 API 同一套 `BrowserRequestGuard`：带 Origin 不在白名单、
/// 或带 `Sec-Fetch-Site` 且不是 none / same-origin → 403 text/plain "Forbidden"，函数不执行。Companion（Node）/ curl / URLSession
/// 两个头都不带（探针见 reports/w2-control-5.md §2），C5 的用例一条不变。
final class CompatBrowserOriginTests: XCTestCase {
    func get(_ base: URL, _ pathAndQuery: String, headers: [String: String] = [:]) async throws -> (status: Int, contentType: String, body: String) {
        var req = URLRequest(url: URL(string: base.absoluteString + pathAndQuery)!)
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", String(decoding: data, as: UTF8.self))
    }

    /// 网页发来的 Function=Cut（带外来 Origin / `Origin: null` / `<img>` 那种只带 `Sec-Fetch-Site: cross-site` 的）→ 403，program 不变、
    /// 函数没到 execute；XML 状态同样 403；地址栏直接打开（`Sec-Fetch-Site: none`）与不带头的照旧。
    func testNS05_foreignOriginFunctionCut_403_programUnchanged() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let foreign: [[String: String]] = [["Origin": "https://attacker.invalid"], ["Origin": "null"], ["Sec-Fetch-Site": "cross-site"],
                                           ["Sec-Fetch-Site": "same-site"], ["Origin": "https://attacker.invalid", "Sec-Fetch-Site": "cross-site"]]
        for headers in foreign {
            let cut = try await get(f.httpBase, "/api/?Function=Cut", headers: headers)
            XCTAssertEqual(cut.status, 403, "\(headers)：\(cut.body)")
            XCTAssertTrue(cut.contentType.hasPrefix("text/plain"), "\(headers)：\(cut.contentType)")
            XCTAssertEqual(cut.body, "Forbidden", "\(headers)")
            let xml = try await get(f.httpBase, "/api", headers: headers)
            XCTAssertEqual(xml.status, 403, "\(headers)：XML 状态也不给")
        }
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, 1, "Cut 没执行")
        XCTAssertEqual(f.bus.lastSequence, 0, "一条命令都没进总线")
        XCTAssertEqual(f.server.counters.functions, 0, "没到 execute")
        XCTAssertEqual(f.server.counters.xmlServed, 0)

        let typed = try await get(f.httpBase, "/api", headers: ["Sec-Fetch-Site": "none"])
        XCTAssertEqual(typed.status, 200, "地址栏直接打开照旧")
        XCTAssertTrue(typed.contentType.hasPrefix("text/xml"))
        let cut = try await get(f.httpBase, "/api/?Function=Cut")
        XCTAssertEqual(cut.status, 200)
        XCTAssertEqual(cut.body, "OK Cut")
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
    }

    /// DNS 重绑定：网页把自己的域名改解析到 127.0.0.1 之后，它的 `GET /api?Function=Cut` 在浏览器看来是同源、不带 Origin，只有 Host 是它的域名——
    /// 403、Cut 不执行（这正是"GET 改状态"最怕的那一种）；Host 是本机地址的同源请求照旧。
    func testNS05_dnsRebindingSameOriginFunctionCut_403() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let port = try XCTUnwrap(f.server.boundHTTPPort)
        func statusLine(host: String) throws -> String? {
            let c = try LineClient(port: port)
            try c.sendRaw("GET /api/?Function=Cut HTTP/1.1\r\nHost: \(host)\r\nSec-Fetch-Site: same-origin\r\nConnection: close\r\n\r\n")
            return try c.readLine()
        }
        XCTAssertEqual(try statusLine(host: "rebind.attacker.invalid:\(port)"), "HTTP/1.1 403 Forbidden")
        var state = await f.stateMachine.state
        XCTAssertEqual(state.program, 1, "Cut 没执行")
        XCTAssertEqual(f.server.counters.functions, 0)
        XCTAssertEqual(try statusLine(host: "127.0.0.1:\(port)"), "HTTP/1.1 200 OK")
        state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2)
    }

    /// 白名单里的来源放行（跨站也放），白名单外的照拦。
    func testNS05_allowlistedOriginPasses_othersStillRefused() async throws {
        let f = try await CompatFixture.start { $0.allowedOrigins = ["http://companion.local:8000"] }
        defer { Task { await f.stop() } }
        let allowed = try await get(f.httpBase, "/api/?Function=Cut", headers: ["Origin": "http://companion.local:8000", "Sec-Fetch-Site": "cross-site"])
        XCTAssertEqual(allowed.status, 200, allowed.body)
        XCTAssertEqual(allowed.body, "OK Cut")
        let other = try await get(f.httpBase, "/api/?Function=Cut", headers: ["Origin": "http://companion.local:8001"])
        XCTAssertEqual(other.status, 403)
        let state = await f.stateMachine.state
        XCTAssertEqual(state.program, 2, "只有白名单那一次 Cut 生效")
    }
}
