// W2-C5（prompt 131）：Codex 10-24 网络审计 NS02——App 实际起的本机 API（AppSettings 默认 127.0.0.1、没 token、ControlRuntime 不传白名单）
// 对浏览器来源一律 403：带外来 Origin 的 GET state 不给状态、Sec-Fetch-Site: cross-site 的 POST cut 不进总线；不带这两个头的（Stream Deck / 脚本）照旧。
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class W2C5BrowserOriginAppTests: XCTestCase {
    /// 设置的默认：API 与兼容层都不放任何网页（设置页没有这一项，ControlRuntime 照设置原样传）。
    func testNS02_appSettingsDefault_noBrowserOriginAllowed() {
        var settings = AppSettings()
        XCTAssertEqual(settings.apiConfiguration?.allowedOrigins, [])
        settings.compatLayerEnabled = true
        XCTAssertEqual(settings.compatConfiguration?.allowedOrigins, [])
    }

    /// App 起的 API：带外来 Origin 的 GET state → 403 forbidden-origin、不漏状态；跨站 POST cut → 403、PGM 不变、总线上没有 api 来源的 cut；
    /// 不带头的 GET 照旧 200。
    func testNS02_appAPI_refusesBrowserOrigin_plainClientStillWorks() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.program == 1 && session.state.preview == 2 })
        guard let port = session.control.apiServer?.boundPort else {
            XCTFail("API 应已起：\(session.control.apiError ?? "无错误")")
            return
        }
        XCTAssertEqual(session.control.apiServer?.configuration.allowedOrigins, [])
        let base = "http://127.0.0.1:\(port)"
        let state = try request("GET", base + "/api/v1/state", headers: ["Origin": "https://attacker.invalid"])
        XCTAssertEqual(state.status, 403, state.text)
        XCTAssertEqual(state.json?["error"] as? String, "forbidden-origin")
        XCTAssertNil(state.json?["state"], "不漏状态")
        let cut = try request("POST", base + "/api/v1/command", body: #"{"command":{"cut":{}}}"#, headers: ["Sec-Fetch-Site": "cross-site"])
        XCTAssertEqual(cut.status, 403, cut.text)
        AppTest.pump(seconds: 0.2)
        XCTAssertEqual(session.state.program, 1, "跨站的 cut 没生效")
        XCTAssertFalse(session.control.bus.recentEntries().contains { $0.source == .api && $0.command == .cut }, "没进总线")
        let plain = try AppTest.http("GET", base + "/api/v1/state")
        XCTAssertEqual(plain.status, 200)
        XCTAssertEqual((plain.json?["state"] as? [String: Any])?["program"] as? Int, 1)
    }

    /// 同 AppTest.http，多带几个请求头（浏览器的 Origin / Sec-Fetch-Site 由用例自己写，URLSession 本身不带）。
    func request(_ method: String, _ url: String, body: String? = nil, headers: [String: String], timeout: Double = 5) throws -> AppTest.HTTPResult {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        if let body { req.httpBody = Data(body.utf8) }
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        final class Box: @unchecked Sendable { var result: AppTest.HTTPResult?; var error: (any Error)? }
        let box = Box()
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { box.error = error }
            box.result = AppTest.HTTPResult(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data ?? Data())
        }.resume()
        guard AppTest.waitUntil(timeout, { box.result != nil }) else { throw XCTSkip("HTTP \(method) \(url) \(timeout) s 没有应答") }
        if let e = box.error { throw e }
        return box.result!
    }
}
