// W2-C6（prompt 137）：提案 035 第 ② 步 = Codex 10-24 网络审计 NS03——App 实际起的本机 API（AppSettings 默认 127.0.0.1、没 token）：
// GET state / GET log 里推流密钥、地址里的密码、密钥栏空时路径里的发布名都打码；没配 token 时 `?secrets=1` → 403 secrets-require-token；
// 从打码的状态里拿 settings 改个别字段写回（setOutputSettings 带标记）= 密钥 / 地址保留原值；addOutput 带标记 → 400。界面里的值不变。
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import Switcher

@MainActor
final class W2C6StreamCredentialAppTests: XCTestCase {
    static let key = "sk_live_W2C6_APPKEY"
    static let user = "w2c6user"
    static let pass = "W2C6AppPass"
    static let publish = "W2C6-APP-PUBLISH-NAME"
    static let secrets = [key, user, pass, publish]
    static let markerRejection = "推流设置里有打码标记：原文用 ?secrets=1 读"

    func testNS03_appAPI_redactsStreamCredentials_secretsNeedToken_roundTripKeepsOriginals() throws {
        let session = try AppTest.freshSession()
        guard let server = session.control.apiServer, let port = server.boundPort else {
            XCTFail("API 应已起：\(session.control.apiError ?? "无错误")")
            return
        }
        // 测试宿主的设置可能被别的用例写过 token（W5-L 的坑）：有就带上，`?secrets=1` 的期望跟着变
        let token = server.configuration.token
        let auth = token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
        let base = "http://127.0.0.1:\(port)"
        let n1 = (session.state.outputs.map(\.number).max() ?? 0) + 1
        let n2 = n1 + 1
        let url1 = "rtmp://\(Self.user):\(Self.pass)@ingest.example.com/live/app"
        let url2 = "rtmp://a.rtmp.youtube.com/live2/\(Self.publish)"
        session.send(.addOutput(config: OutputState(number: n1, kind: .stream, name: "W2C6 推流 1",
                                                    settings: OutputSettings(stream: StreamSettings(url: url1, streamKey: Self.key)))))
        session.send(.addOutput(config: OutputState(number: n2, kind: .stream, name: "W2C6 推流 2",
                                                    settings: OutputSettings(stream: StreamSettings(url: url2, streamKey: "")))))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.contains { $0.number == n2 } }, "两路推流加上了")
        defer {
            session.send(.removeOutput(output: n1))
            session.send(.removeOutput(output: n2))
        }

        // GET state：打码，键名照旧
        let state = try request("GET", base + "/api/v1/state", headers: auth)
        XCTAssertEqual(state.status, 200, state.text)
        XCTAssertEqual(Self.secrets.filter { state.text.contains($0) }, [], "App 的 GET state 漏了凭据")
        let outputs = try XCTUnwrap((state.json?["state"] as? [String: Any])?["outputs"] as? [[String: Any]])
        func stream(_ n: Int) -> [String: Any]? { (outputs.first { $0["number"] as? Int == n }?["settings"] as? [String: Any])?["stream"] as? [String: Any] }
        XCTAssertEqual(stream(n1)?["url"] as? String, "rtmp://<redacted>@ingest.example.com/live/app")
        XCTAssertEqual(stream(n1)?["streamKey"] as? String, StreamURLRedaction.marker)
        XCTAssertEqual(stream(n2)?["url"] as? String, "rtmp://a.rtmp.youtube.com/live2/<redacted>", "密钥栏空：发布名打码")
        XCTAssertEqual(stream(n2)?["streamKey"] as? String, "")
        XCTAssertEqual(stream(n1).map { Set($0.keys) }, Set(StreamSettings.jsonKeys))
        XCTAssertEqual(session.state.outputs.first { $0.number == n1 }?.settings.stream?.streamKey, Self.key, "界面 / 状态里的值不变")

        // GET log：界面加输出走总线进了日志，API 写出去打码
        let log = try request("GET", base + "/api/v1/log", headers: auth)
        XCTAssertEqual(log.status, 200)
        XCTAssertTrue(log.text.contains("W2C6 推流 1"), "日志里有这两条 addOutput")
        XCTAssertEqual(Self.secrets.filter { log.text.contains($0) }, [], "App 的 GET log 漏了凭据")
        XCTAssertTrue(session.control.bus.recentEntries().contains {
            if case .addOutput(let c) = $0.command { return c.settings.stream?.streamKey == Self.key } else { return false }
        }, "总线日志本身是原文")

        // ?secrets=1：没 token → 403；有 token → 原文
        for path in ["/api/v1/state?secrets=1", "/api/v1/log?secrets=1"] {
            let raw = try request("GET", base + path, headers: auth)
            if token == nil {
                XCTAssertEqual(raw.status, 403, "\(path)：\(raw.text)")
                XCTAssertEqual(raw.json?["error"] as? String, "secrets-require-token")
                XCTAssertEqual(Self.secrets.filter { raw.text.contains($0) }, [])
            } else {
                XCTAssertEqual(raw.status, 200, path)
                XCTAssertTrue(raw.text.contains(Self.key) && raw.text.contains(Self.pass), "\(path)：配了 token 给原文")
            }
        }

        // 往返：打码的 settings 改重连上限写回 → 地址 / 密钥保留原值
        var settings = try XCTUnwrap(outputs.first { $0["number"] as? Int == n1 }?["settings"] as? [String: Any])
        var s1 = try XCTUnwrap(settings["stream"] as? [String: Any])
        s1["reconnectMaxSeconds"] = 12.0
        settings["stream"] = s1
        let command: [String: Any] = ["command": ["setOutputSettings": ["output": n1, "settings": settings]]]
        let set = try request("POST", base + "/api/v1/command", body: String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self),
                              headers: auth.merging(["Content-Type": "application/json"]) { a, _ in a })
        XCTAssertEqual(set.status, 200, set.text)
        XCTAssertTrue(AppTest.waitUntil(2) { session.state.outputs.first { $0.number == n1 }?.settings.stream?.reconnectMaxSeconds == 12 }, "别的字段照改")
        let kept = session.state.outputs.first { $0.number == n1 }?.settings.stream
        XCTAssertEqual(kept?.url, url1, "地址保留原值")
        XCTAssertEqual(kept?.streamKey, Self.key, "密钥保留原值")

        // addOutput 带标记 → 400、没加上
        let bad = OutputState(number: n2 + 1, kind: .stream, name: "带标记", settings: OutputSettings(stream: StreamSettings(url: "rtmp://h.example.com/app", streamKey: StreamURLRedaction.marker)))
        let add = try request("POST", base + "/api/v1/command", body: String(decoding: try APIJSON.encoder.encode(["command": Command.addOutput(config: bad)]), as: UTF8.self),
                              headers: auth.merging(["Content-Type": "application/json"]) { a, _ in a })
        XCTAssertEqual(add.status, 400, add.text)
        XCTAssertEqual(add.json?["error"] as? String, Self.markerRejection)
        AppTest.pump(seconds: 0.2)
        XCTAssertFalse(session.state.outputs.contains { $0.number == n2 + 1 }, "带标记的输出没加上")
    }

    /// 同 AppTest.http，多带几个请求头（token）。
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
