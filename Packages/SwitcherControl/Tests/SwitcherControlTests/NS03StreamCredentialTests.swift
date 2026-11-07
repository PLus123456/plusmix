import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// Codex 10-24 网络安全审计 NS03 = 提案 035 第 ② 步（W2-C6，prompt 137）：API 对外的状态（GET state、WS snapshot）与命令日志（GET log）里
/// 推流凭据打码——`streamKey` 非空 → `<redacted>`、`url` 按 `StreamURLRedaction.redact(url:publishNameInPath: streamKey.isEmpty)`；
/// 键名 / 层级与 `MixerState` 的 Codable 一致；`?secrets=1` 只在配了 token 时给原文，没配 → 403 `secrets-require-token`、WS 不升级；
/// `setOutputSettings` 带标记 = 保留原值（API 层换回再进总线），`addOutput` / `loadShow` 带标记 → 400。
final class NS03StreamCredentialTests: XCTestCase {
    // MARK: 夹具：五路推流把各种凭据摆一遍

    static let marker = StreamURLRedaction.marker
    static let markerRejection = "推流设置里有打码标记：原文用 ?secrets=1 读"
    static let token = "ns03-token"

    static let key2 = "sk_live_NS03KEY_two"
    static let user3 = "ns03bob"
    static let pass3 = "NS03-S3cretPass"
    static let key3 = "NS03KEY_three"
    static let user4 = "ns03user"
    static let pass4 = "NS03PassValue"
    static let publish5 = "NS03-PUBLISH-NAME-five"
    static let streamid6 = "publish:ns03cam"
    static let phrase6 = "NS03PhraseSix"
    /// 测试密钥、userinfo 的用户名 / 密码、`user=` / `pass=` 的值、密钥栏空时路径里的发布名、SRT 的 streamid / passphrase：哪一个都不许出现在打码的应答里。
    static let secrets = [key2, user3, pass3, key3, user4, pass4, publish5, streamid6, phrase6]

    static let url2 = "rtmp://live.example.com/app"
    static let url3 = "rtmp://\(user3):\(pass3)@ingest.example.com/live/app"
    static let url4 = "rtmp://mediamtx.local:1935/cam?user=\(user4)&pass=\(pass4)"
    static let url5 = "rtmp://a.rtmp.youtube.com/live2/\(publish5)"
    static let url6 = "srt://srt.example.com:9000?streamid=\(streamid6)&passphrase=\(phrase6)&latency=200"

    /// 打码之后应该长这样（scheme / 主机 / 端口 / 其余路径 / 不打码的参数原样）。
    static let redactedURL = [
        2: url2,
        3: "rtmp://<redacted>@ingest.example.com/live/app",
        4: "rtmp://mediamtx.local:1935/cam?user=<redacted>&pass=<redacted>",
        5: "rtmp://a.rtmp.youtube.com/live2/<redacted>",
        6: "srt://srt.example.com:9000?streamid=<redacted>&passphrase=<redacted>&latency=200",
    ]
    static let redactedKey = [2: marker, 3: marker, 4: "", 5: "", 6: ""]

    static func streamOutput(_ number: Int, url: String, key: String, reconnect: Double = 30) -> OutputState {
        OutputState(number: number, kind: .stream, name: "推流 \(number)",
                    settings: OutputSettings(video: VideoEncodeSettings(codec: .h264, bitrateBps: 6_000_000, keyframeIntervalFrames: 120),
                                             stream: StreamSettings(url: url, streamKey: key, reconnectMaxSeconds: reconnect)))
    }

    static func state() -> MixerState {
        var s = TestStates.base()
        s.outputs = [
            OutputState(number: 1, kind: .record, name: "录制", settings: OutputSettings(record: RecordSettings(directory: "/tmp"))),
            streamOutput(2, url: url2, key: key2),
            streamOutput(3, url: url3, key: key3, reconnect: 20),
            streamOutput(4, url: url4, key: ""),
            streamOutput(5, url: url5, key: ""),
            streamOutput(6, url: url6, key: ""),
        ]
        return s
    }

    // MARK: 小工具

    func fetch(_ s: APIServerTests.Server, _ pathAndQuery: String, token: String? = nil) async throws -> (status: Int, text: String) {
        var req = URLRequest(url: URL(string: s.baseURL.absoluteString + pathAndQuery)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    func post(_ s: APIServerTests.Server, _ body: String) async throws -> (status: Int, text: String) {
        var req = URLRequest(url: s.baseURL.appending(path: "/api/v1/command"))
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func leaked(_ text: String) -> [String] { Self.secrets.filter { text.contains($0) } }

    func encodeJSON<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: APIJSON.encoder.encode(value))
    }

    /// 打码前后形状一样：同样的键、同样的数组长度、同样的值类型；值不同的叶子只能是 stream 的 url / streamKey。
    func assertSameShape(raw: Any, redacted: Any, file: StaticString = #filePath, line: UInt = #line) {
        var differing: [String] = []
        func walk(_ a: Any, _ b: Any, _ path: String) {
            switch (a, b) {
            case (let x as [String: Any], let y as [String: Any]):
                XCTAssertEqual(Set(x.keys), Set(y.keys), "\(path) 的键", file: file, line: line)
                for (k, v) in x { if let w = y[k] { walk(v, w, path + "." + k) } }
            case (let x as [Any], let y as [Any]):
                XCTAssertEqual(x.count, y.count, "\(path) 的长度", file: file, line: line)
                for (i, (v, w)) in zip(x, y).enumerated() { walk(v, w, path + "[\(i)]") }
            case (let x as String, let y as String):
                if x != y { differing.append(path) }
            case (is NSNull, is NSNull):
                break
            case (let x as NSNumber, let y as NSNumber):
                if x != y { differing.append(path) }
            default:
                XCTFail("\(path) 的类型变了：\(type(of: a)) → \(type(of: b))", file: file, line: line)
            }
        }
        walk(raw, redacted, "$")
        for p in differing {
            XCTAssertTrue(p.hasSuffix(".stream.url") || p.hasSuffix(".stream.streamKey"), "只许 stream.url / streamKey 不同，\(p) 也变了", file: file, line: line)
        }
    }

    /// 应答里 state.outputs 的每一路推流：键名 = `StreamSettings.jsonKeys`、`settings` 的键 ⊆ `OutputSettings.jsonKeys`、url / streamKey 是打码后的样子。
    func assertRedactedOutputs(_ state: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let outputs = try XCTUnwrap(state["outputs"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(outputs.count, 6, file: file, line: line)
        for o in outputs {
            let number = try XCTUnwrap(o["number"] as? Int, file: file, line: line)
            let settings = try XCTUnwrap(o["settings"] as? [String: Any], file: file, line: line)
            XCTAssertTrue(Set(settings.keys).isSubset(of: OutputSettings.jsonKeys), "输出 \(number) settings 的键 \(settings.keys.sorted())", file: file, line: line)
            guard number != 1 else {
                XCTAssertNil(settings["stream"], "录制输出没有 stream", file: file, line: line)
                continue
            }
            let stream = try XCTUnwrap(settings["stream"] as? [String: Any], file: file, line: line)
            XCTAssertEqual(Set(stream.keys), Set(StreamSettings.jsonKeys), "输出 \(number) stream 的键", file: file, line: line)
            XCTAssertEqual(stream["url"] as? String, Self.redactedURL[number], "输出 \(number) 的 url", file: file, line: line)
            XCTAssertEqual(stream["streamKey"] as? String, Self.redactedKey[number], "输出 \(number) 的 streamKey（空串照旧空串）", file: file, line: line)
            XCTAssertEqual(stream["reconnectMaxSeconds"] as? Double, number == 3 ? 20 : 30, "别的字段不动", file: file, line: line)
            XCTAssertEqual(stream["followFirst"] as? Bool, false, file: file, line: line)
        }
    }

    /// 下一条某类型的 WS 消息（跳过 stats 之类）。
    func next(_ ws: WSClient, type: String, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let text = await ws.next(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
            if (try? object(text))?["type"] as? String == type { return text }
        }
        throw NSError(domain: "ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(timeout) s 内没收到 \(type)"])
    }

    func output(_ s: APIServerTests.Server, _ number: Int) async -> OutputState? {
        await s.fixture.stateMachine.state.outputs.first { $0.number == number }
    }

    // MARK: 1. GET state

    /// GET /api/v1/state：五路推流的密钥 / 地址密码 / pass= / 发布名 / SRT 参数都找不到；键名、层级、类型与原文一致（只有 url / streamKey 的值不同）；
    /// 状态机里的值还是原文（只改 API 写出去的样子）。
    func testNS03_getState_redactsStreamCredentials_shapeUnchanged() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        let (status, text) = try await fetch(s, "/api/v1/state")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(leaked(text), [], "GET state 漏了凭据")
        let json = try object(text)
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        try assertRedactedOutputs(state)
        assertSameShape(raw: try encodeJSON(Self.state()), redacted: state)
        XCTAssertNotNil(json["tally"] as? [String: [String: Bool]], "tally 照旧")
        let machine = await s.fixture.stateMachine.state
        XCTAssertEqual(machine.outputs.first { $0.number == 3 }?.settings.stream?.url, Self.url3, "状态机里的值不变")
        XCTAssertEqual(machine.outputs.first { $0.number == 2 }?.settings.stream?.streamKey, Self.key2)
        // StateFeed 的同一个入口：默认打码，secrets: true 才是原文
        XCTAssertEqual(leaked(try APIJSON.string(s.feed.stateResponse())), [])
        XCTAssertEqual(Set(leaked(try APIJSON.string(s.feed.stateResponse(secrets: true)))), Set(Self.secrets))
    }

    // MARK: 2. WS snapshot

    /// WS：订阅时补发的快照、之后推送的快照都打码；没人要原文时 StateFeed 不多编原文那一份。
    func testNS03_wsSnapshot_redacted_noRawEncodingWithoutSecretsSubscriber() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await next(ws, type: "hello")
        let first = try await next(ws, type: "snapshot")
        XCTAssertEqual(leaked(first), [], "补发的快照漏了凭据")
        try assertRedactedOutputs(try XCTUnwrap(try object(first)["state"] as? [String: Any]))
        _ = try await s.fixture.bus.submit(.renameOutput(output: 2, name: "改了名"), source: .ui)
        let pushed = try await next(ws, type: "snapshot")
        XCTAssertEqual(leaked(pushed), [], "推送的快照漏了凭据")
        let state = try XCTUnwrap(try object(pushed)["state"] as? [String: Any])
        try assertRedactedOutputs(state)
        XCTAssertEqual((state["outputs"] as? [[String: Any]])?.first { $0["number"] as? Int == 2 }?["name"] as? String, "改了名")
        assertSameShape(raw: try encodeJSON(await s.fixture.stateMachine.state), redacted: state)
        XCTAssertEqual(s.feed.counters.secretSnapshots, 0, "没有 ?secrets=1 的订阅者就不编原文")
        XCTAssertGreaterThanOrEqual(s.feed.counters.snapshots, 1)
    }

    // MARK: 3. GET log

    /// GET /api/v1/log：界面（App 设置页）走总线的 addOutput / setOutputSettings / loadShow 原文进了日志，API 写出去时打码；
    /// 别的字段原样，打码后的命令仍是合法的 Command JSON。
    func testNS03_getLog_redactsStreamSettingsInCommands() async throws {
        let s = try await APIServerTests.Server.start()
        defer { Task { await s.stop() } }
        let add = Command.addOutput(config: Self.streamOutput(7, url: Self.url3, key: Self.key2))
        let set = Command.setOutputSettings(output: 7, settings: Self.streamOutput(7, url: Self.url5, key: "", reconnect: 11).settings)
        let load = Command.loadShow(show: Show(name: "NS03", state: Self.state()))
        for c in [add, set, load] {
            let r = try await s.fixture.bus.submit(c, source: .ui)
            XCTAssertTrue(r.applied, "\(c)")
        }
        XCTAssertTrue(s.fixture.bus.recentEntries().contains { $0.command == set }, "总线日志本身是原文（App / 诊断用）")
        let (status, text) = try await fetch(s, "/api/v1/log")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(leaked(text), [], "GET log 漏了凭据")
        let entries = try XCTUnwrap(try object(text)["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 3)
        let commands = try entries.map { e -> Command in
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(e["command"]))
            return try APIJSON.decoder.decode(Command.self, from: data)
        }
        guard case .addOutput(let added) = commands[0], case .setOutputSettings(7, let settings) = commands[1], case .loadShow(let show) = commands[2] else {
            return XCTFail("日志里的命令种类变了：\(commands)")
        }
        XCTAssertEqual(added.settings.stream?.url, "rtmp://<redacted>@ingest.example.com/live/app")
        XCTAssertEqual(added.settings.stream?.streamKey, Self.marker)
        XCTAssertEqual(added.settings.video, Self.streamOutput(7, url: "", key: "").settings.video, "别的字段原样")
        XCTAssertEqual(added.name, "推流 7")
        XCTAssertEqual(settings.stream?.url, "rtmp://a.rtmp.youtube.com/live2/<redacted>", "密钥栏空：路径里的发布名打码")
        XCTAssertEqual(settings.stream?.streamKey, "")
        XCTAssertEqual(settings.stream?.reconnectMaxSeconds, 11)
        for o in show.outputs where o.kind == .stream {
            XCTAssertEqual(o.settings.stream?.url, Self.redactedURL[o.number], "loadShow 里输出 \(o.number)")
            XCTAssertEqual(o.settings.stream?.streamKey, Self.redactedKey[o.number])
        }
        XCTAssertEqual(show.inputs, Self.state().inputs, "节目的别的部分原样")
        // 键名：日志条目的键照旧
        XCTAssertEqual(Set(entries[1].keys), ["sequence", "issuedAt", "source", "command", "appliedTick", "applied", "appliedAt"])
        // ?limit 照旧
        let (_, one) = try await fetch(s, "/api/v1/log?limit=1")
        XCTAssertEqual((try object(one)["entries"] as? [Any])?.count, 1)
        XCTAssertEqual(leaked(one), [])
    }

    // MARK: 4. ?secrets=1 要 token

    /// 没配 token（只开本机也一样）：GET state / GET log 带 `?secrets=1` → 403 `secrets-require-token`、不漏状态；WS 带 `?secrets=1` 不升级、不订阅；
    /// 不带 secrets（或 secrets 不是 1）照旧 200 打码。
    func testNS03_secretsWithoutToken_403_wsNotUpgraded() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        _ = try await s.fixture.bus.submit(.setOutputSettings(output: 3, settings: Self.streamOutput(3, url: Self.url3, key: Self.key3).settings), source: .ui)
        for path in ["/api/v1/state?secrets=1", "/api/v1/log?secrets=1", "/api/v1/log?limit=5&secrets=1"] {
            let (status, text) = try await fetch(s, path)
            XCTAssertEqual(status, 403, path)
            XCTAssertEqual(try object(text)["error"] as? String, "secrets-require-token", path)
            XCTAssertEqual(leaked(text), [], path)
            XCTAssertFalse(text.contains("\"outputs\""), "\(path)：不给状态")
        }
        for path in ["/api/v1/state", "/api/v1/state?secrets=0", "/api/v1/state?secrets=true", "/api/v1/log"] {
            let (status, text) = try await fetch(s, path)
            XCTAssertEqual(status, 200, path)
            XCTAssertEqual(leaked(text), [], "\(path)：只认 secrets=1，别的照旧打码")
        }
        let port = try XCTUnwrap(s.server.boundPort)
        let ws = try RawWSClient(port: port, path: "/api/v1/events?secrets=1")
        defer { ws.close() }
        print("NS03 没 token 的 ?secrets=1 WS 握手应答 = \(ws.status)")
        XCTAssertNotEqual(ws.status, 101, "没配 token 的 ?secrets=1 不能升级")
        XCTAssertTrue((400..<500).contains(ws.status), "拒绝要是 4xx，实际 \(ws.status)")
        XCTAssertNil(try ws.nextText(timeout: 0.3), "没升级就收不到快照")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.feed.counters.subscribers, 0, "被拒的握手不订阅")
        XCTAssertEqual(s.feed.counters.secretSnapshots, 0)
        // 不带 secrets 的 WS 照旧升级、快照打码
        let plain = try RawWSClient(port: port)
        defer { plain.close() }
        XCTAssertEqual(plain.status, 101)
        _ = try plain.nextText(timeout: 5)   // hello
        let snap = try XCTUnwrap(try plain.nextText(timeout: 5))
        XCTAssertEqual(try object(snap)["type"] as? String, "snapshot")
        XCTAssertEqual(leaked(snap), [])
    }

    /// 配了 token：`?secrets=1` 三处给原文（与状态机里的值逐字相同）；不带 secrets 的照旧打码；token 不对的先 401。
    /// WS 上一个要原文、一个不要的同时订阅：推送时各拿各的，原文只编给要的那个。
    func testNS03_secretsWithToken_rawInStateLogAndWS() async throws {
        let s = try await APIServerTests.Server.start(token: Self.token, state: Self.state())
        defer { Task { await s.stop() } }
        _ = try await s.fixture.bus.submit(.setOutputSettings(output: 3, settings: Self.streamOutput(3, url: Self.url3, key: Self.key3, reconnect: 20).settings), source: .ui)

        let (st, rawState) = try await fetch(s, "/api/v1/state?secrets=1", token: Self.token)
        XCTAssertEqual(st, 200)
        XCTAssertEqual(Set(leaked(rawState)), Set(Self.secrets), "配了 token 的 ?secrets=1 给原文")
        let rawObject = try XCTUnwrap(try object(rawState)["state"] as? [String: Any])
        let machineJSON = try encodeJSON(await s.fixture.stateMachine.state) as? NSDictionary
        XCTAssertEqual(rawObject as NSDictionary, machineJSON, "原文 = 状态机里的值")
        let (stq, viaQuery) = try await fetch(s, "/api/v1/state?token=\(Self.token)&secrets=1")
        XCTAssertEqual(stq, 200)
        XCTAssertEqual(Set(leaked(viaQuery)), Set(Self.secrets), "查询串里的 token 也算")
        let (stPlain, plain) = try await fetch(s, "/api/v1/state", token: Self.token)
        XCTAssertEqual(stPlain, 200)
        XCTAssertEqual(leaked(plain), [], "有 token 不带 secrets 照旧打码")
        let (st401, body401) = try await fetch(s, "/api/v1/state?secrets=1", token: "wrong")
        XCTAssertEqual(st401, 401)
        XCTAssertEqual(leaked(body401), [])
        let (st401b, _) = try await fetch(s, "/api/v1/state?secrets=1")
        XCTAssertEqual(st401b, 401, "没带 token 先被 token 中间件挡")

        let (stLog, rawLog) = try await fetch(s, "/api/v1/log?secrets=1", token: Self.token)
        XCTAssertEqual(stLog, 200)
        XCTAssertTrue(rawLog.contains(Self.pass3) && rawLog.contains(Self.key3), "日志原文")
        let (_, plainLog) = try await fetch(s, "/api/v1/log", token: Self.token)
        XCTAssertEqual(leaked(plainLog), [])

        let wsPlain = WSClient(url: URL(string: s.wsURL.absoluteString + "?token=\(Self.token)")!)
        let wsRaw = WSClient(url: URL(string: s.wsURL.absoluteString + "?token=\(Self.token)&secrets=1")!)
        defer { wsPlain.close(); wsRaw.close() }
        let firstPlain = try await next(wsPlain, type: "snapshot")
        let firstRaw = try await next(wsRaw, type: "snapshot")
        XCTAssertEqual(leaked(firstPlain), [], "不要原文的补发快照打码")
        XCTAssertEqual(Set(leaked(firstRaw)), Set(Self.secrets), "?secrets=1 的补发快照是原文")
        _ = try await s.fixture.bus.submit(.renameOutput(output: 5, name: "改名 5"), source: .api)
        let pushedPlain = try await next(wsPlain, type: "snapshot")
        let pushedRaw = try await next(wsRaw, type: "snapshot")
        XCTAssertEqual(leaked(pushedPlain), [], "推送：不要原文的打码")
        XCTAssertEqual(Set(leaked(pushedRaw)), Set(Self.secrets), "推送：要原文的拿原文")
        XCTAssertTrue(pushedPlain.contains("改名 5") && pushedRaw.contains("改名 5"), "两份是同一个快照")
        XCTAssertEqual(try object(pushedPlain)["sequence"] as? Int, try object(pushedRaw)["sequence"] as? Int)
        XCTAssertGreaterThanOrEqual(s.feed.counters.secretSnapshots, 1, "有人要原文才编")
        // 要原文的走了之后不再编原文
        wsRaw.close()
        _ = await waitUntil { s.feed.counters.subscribers == 1 }
        let before = s.feed.counters.secretSnapshots
        _ = try await s.fixture.bus.submit(.renameOutput(output: 5, name: "再改 5"), source: .api)
        let lastPlain = try await next(wsPlain, type: "snapshot")
        XCTAssertEqual(leaked(lastPlain), [])
        XCTAssertTrue(lastPlain.contains("再改 5"))
        XCTAssertEqual(s.feed.counters.secretSnapshots, before, "没人要原文就不编")
    }

    // MARK: 5. 往返

    /// "读 → 改别的字段 → 整个写回"：GET state 拿到的打码 settings 改重连上限 / followFirst / 码率后原样 POST setOutputSettings——
    /// 密钥与地址保留原值、别的字段照改；总线日志 / 状态机里没有标记。地址换成新的、密钥给标记 = 新地址 + 原密钥。
    func testNS03_setOutputSettingsWithMarkers_keepsOriginals_appliesOtherFields() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        let (_, text) = try await fetch(s, "/api/v1/state")
        let outputs = try XCTUnwrap(try object(text)["state"] as? [String: Any])["outputs"] as? [[String: Any]]
        func redactedSettings(_ n: Int) throws -> [String: Any] {
            try XCTUnwrap(outputs?.first { $0["number"] as? Int == n }?["settings"] as? [String: Any])
        }
        func body(_ n: Int, _ settings: [String: Any]) throws -> String {
            let command: [String: Any] = ["command": ["setOutputSettings": ["output": n, "settings": settings]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        }
        let originals = Self.state().outputs
        for n in 2...6 {
            var settings = try redactedSettings(n)
            var stream = try XCTUnwrap(settings["stream"] as? [String: Any])
            XCTAssertTrue(stream["streamKey"] as? String == Self.marker || (stream["url"] as? String ?? "").contains(Self.marker),
                          "输出 \(n)：写回的是打码后的 settings（不然往返测不到东西）")
            stream["reconnectMaxSeconds"] = Double(40 + n)
            stream["followFirst"] = true
            settings["stream"] = stream
            var video = try XCTUnwrap(settings["video"] as? [String: Any])
            video["bitrateBps"] = 4_000_000 + n
            settings["video"] = video
            let (status, reply) = try await post(s, try body(n, settings))
            XCTAssertEqual(status, 200, "输出 \(n)：\(reply)")
            let nowSettings = await output(s, n)?.settings
            let now = try XCTUnwrap(nowSettings)
            let original = try XCTUnwrap(originals.first { $0.number == n }?.settings.stream)
            XCTAssertEqual(now.stream?.url, original.url, "输出 \(n)：地址保留原值")
            XCTAssertEqual(now.stream?.streamKey, original.streamKey, "输出 \(n)：密钥保留原值")
            XCTAssertEqual(now.stream?.reconnectMaxSeconds, Double(40 + n), "输出 \(n)：别的字段照改")
            XCTAssertEqual(now.stream?.followFirst, true)
            XCTAssertEqual(now.video?.bitrateBps, 4_000_000 + n)
            guard case .setOutputSettings(n, let logged)? = s.fixture.bus.recentEntries().last?.command else { return XCTFail("总线日志最后一条不是 setOutputSettings") }
            XCTAssertEqual(logged, now, "总线日志里是换回原值之后的命令")
        }
        let log = s.fixture.bus.recentEntries().map { String(describing: $0.command) }.joined()
        XCTAssertFalse(log.contains(Self.marker), "总线日志永远看不到标记")
        let machine = await s.fixture.stateMachine.state
        XCTAssertFalse(String(describing: machine.outputs).contains(Self.marker), "状态机永远看不到标记")

        // 密钥换了、地址还是打码的样子：地址换回原值（同一个目的地），密钥用新的
        var two = try redactedSettings(2)
        var stream2 = try XCTUnwrap(two["stream"] as? [String: Any])
        stream2["streamKey"] = "new-key-2"
        two["stream"] = stream2
        let (st2, r2) = try await post(s, try body(2, two))
        XCTAssertEqual(st2, 200, r2)
        let now2 = await output(s, 2)?.settings.stream
        XCTAssertEqual(now2?.url, Self.url2)
        XCTAssertEqual(now2?.streamKey, "new-key-2")

        // WS 上同样换回原值
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await next(ws, type: "snapshot")
        var four = try redactedSettings(4)
        var stream4 = try XCTUnwrap(four["stream"] as? [String: Any])
        stream4["reconnectMaxSeconds"] = 9.0
        four["stream"] = stream4
        let wsCommand: [String: Any] = ["id": 4, "command": ["setOutputSettings": ["output": 4, "settings": four]]]
        try await ws.send(String(decoding: try JSONSerialization.data(withJSONObject: wsCommand), as: UTF8.self))
        let receipt = try object(try await next(ws, type: "receipt"))
        XCTAssertEqual(receipt["id"] as? Int, 4)
        let now4 = await output(s, 4)?.settings.stream
        XCTAssertEqual(now4?.url, Self.url4, "WS：地址保留原值")
        XCTAssertEqual(now4?.reconnectMaxSeconds, 9)

        // 批量里一样（换回用的是执行到这一条时的值）
        var five = try redactedSettings(5)
        var stream5 = try XCTUnwrap(five["stream"] as? [String: Any])
        stream5["reconnectMaxSeconds"] = 5.0
        five["stream"] = stream5
        let batch: [String: Any] = ["commands": [["setPreview": ["input": 3]], ["setOutputSettings": ["output": 5, "settings": five]]]]
        let (stb, rb) = try await post(s, String(decoding: try JSONSerialization.data(withJSONObject: batch), as: UTF8.self))
        XCTAssertEqual(stb, 200, rb)
        let now5 = await output(s, 5)?.settings.stream
        XCTAssertEqual(now5?.url, Self.url5, "批量：密钥栏空时打码的发布名换回原值")
        XCTAssertEqual(now5?.reconnectMaxSeconds, 5)
    }

    /// 标记密钥只跟着原来的目的地走（安全复查，W2-C6）：地址换成别的（哪怕是干净的新地址）同时密钥给标记 → 400、状态不变——
    /// 否则不配 token、读不到原文的客户端发一条 `{url: 自己的服务器, streamKey: "<redacted>"}`，下次开推原密钥就推到了它那里，等于绕过 `?secrets=1`。
    /// 换地址就得连密钥原文一起给；地址不变（原样或打码的样子）照旧保留。
    func testNS03_markerKeyWithChangedURL_400_keyNeverFollowsToNewDestination() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        let before = await s.fixture.stateMachine.state
        let sequence = s.fixture.bus.lastSequence
        let cases: [(Int, String)] = [
            (2, "rtmp://attacker.invalid/app"),                       // 干净的新地址
            (3, "rtmp://attacker.invalid/live/app"),                  // userinfo 也没了
            (5, "rtmp://attacker.invalid/live2/x"),                    // 密钥栏空的那一路（原密钥是空串，也不许）
            (6, "srt://attacker.invalid:9000?latency=200"),            // SRT
            (2, "rtmp://live.example.com/app/"),                       // 只差一个斜杠也算换了
        ]
        for (n, url) in cases {
            let settings = OutputSettings(stream: StreamSettings(url: url, streamKey: Self.marker))
            let body = String(decoding: try APIJSON.encoder.encode(["command": Command.setOutputSettings(output: n, settings: settings)]), as: UTF8.self)
            let (status, text) = try await post(s, body)
            XCTAssertEqual(status, 400, "输出 \(n) → \(url)：\(text)")
            XCTAssertEqual(try object(text)["error"] as? String, Self.markerRejection)
        }
        let after = await s.fixture.stateMachine.state
        XCTAssertEqual(after, before, "状态不变：密钥没跟着去新地址")
        XCTAssertEqual(s.fixture.bus.lastSequence, sequence, "没进总线")
        // 地址原文 + 标记密钥（客户端自己知道地址、只是没有密钥）：同一个目的地，照旧保留
        let same = OutputSettings(stream: StreamSettings(url: Self.url3, streamKey: Self.marker, reconnectMaxSeconds: 8))
        let (st, text) = try await post(s, String(decoding: try APIJSON.encoder.encode(["command": Command.setOutputSettings(output: 3, settings: same)]), as: UTF8.self))
        XCTAssertEqual(st, 200, text)
        let three = await output(s, 3)?.settings.stream
        XCTAssertEqual(three?.streamKey, Self.key3)
        XCTAssertEqual(three?.reconnectMaxSeconds, 8)
    }

    /// 换不回去的标记一律 400、状态不变：地址带标记但不是"现在的地址打码后的样子"（主机改了 / 过期的快照）、没有推流设置的输出收到标记密钥。
    func testNS03_setOutputSettingsWithUnmatchedMarker_400_stateUnchanged() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        let forged = OutputSettings(stream: StreamSettings(url: "rtmp://<redacted>@evil.example.com/live/app", streamKey: Self.marker))
        let stale = OutputSettings(stream: StreamSettings(url: "rtmp://a.rtmp.youtube.com/live2/<redacted>", streamKey: ""))
        let noStream = OutputSettings(stream: StreamSettings(url: "rtmp://h.example.com/app", streamKey: Self.marker))
        let missing = OutputSettings(stream: StreamSettings(url: "rtmp://h.example.com/app", streamKey: Self.marker))
        let before = await s.fixture.stateMachine.state
        let sequence = s.fixture.bus.lastSequence
        for (n, settings) in [(3, forged), (2, stale), (1, noStream), (99, missing)] {
            let body = String(decoding: try APIJSON.encoder.encode(["command": Command.setOutputSettings(output: n, settings: settings)]), as: UTF8.self)
            let (status, text) = try await post(s, body)
            XCTAssertEqual(status, 400, "输出 \(n)：\(text)")
            XCTAssertEqual(try object(text)["error"] as? String, Self.markerRejection, "输出 \(n)")
        }
        let after = await s.fixture.stateMachine.state
        XCTAssertEqual(after, before, "状态不变")
        XCTAssertEqual(s.fixture.bus.lastSequence, sequence, "没进总线")
    }

    /// addOutput / loadShow 带标记（没有"现在的值"可保留）→ 400 "推流设置里有打码标记：原文用 ?secrets=1 读"、状态不变；HTTP 单条 / 批量、WS 都是。
    /// 不带标记的原文照收（API 写入本来就收原文）。
    func testNS03_addOutputAndLoadShowWithMarker_400_stateUnchanged() async throws {
        let s = try await APIServerTests.Server.start(state: Self.state())
        defer { Task { await s.stop() } }
        func body(_ c: Command) throws -> String { String(decoding: try APIJSON.encoder.encode(["command": c]), as: UTF8.self) }
        let before = await s.fixture.stateMachine.state
        let sequence = s.fixture.bus.lastSequence
        var redactedState = Self.state()
        for i in redactedState.outputs.indices where redactedState.outputs[i].kind == .stream {
            let n = redactedState.outputs[i].number
            redactedState.outputs[i].settings.stream?.url = Self.redactedURL[n]!
            redactedState.outputs[i].settings.stream?.streamKey = Self.redactedKey[n]!
        }
        let rejected: [Command] = [
            .addOutput(config: Self.streamOutput(7, url: "rtmp://h.example.com/app", key: Self.marker)),
            .addOutput(config: Self.streamOutput(7, url: "rtmp://<redacted>@h.example.com/app", key: "k")),
            .addOutput(config: Self.streamOutput(7, url: "rtmp://h.example.com/live/<redacted>", key: "")),
            .loadShow(show: Show(name: "读了打码状态存的节目", state: redactedState)),
        ]
        for c in rejected {
            let (status, text) = try await post(s, try body(c))
            XCTAssertEqual(status, 400, "\(c)：\(text)")
            XCTAssertEqual(try object(text)["error"] as? String, Self.markerRejection)
        }
        var after = await s.fixture.stateMachine.state
        XCTAssertEqual(after, before, "状态不变")
        XCTAssertEqual(s.fixture.bus.lastSequence, sequence, "没进总线")

        // 批量：第 1 条（setPreview）生效，第 2 条带标记 → 400 index 1
        let batch = String(decoding: try APIJSON.encoder.encode(["commands": [Command.setPreview(input: 3), rejected[0]]]), as: UTF8.self)
        let (stb, textb) = try await post(s, batch)
        XCTAssertEqual(stb, 400, textb)
        let ob = try object(textb)
        XCTAssertEqual(ob["error"] as? String, Self.markerRejection)
        XCTAssertEqual(ob["index"] as? Int, 1)
        XCTAssertEqual((ob["receipts"] as? [Any])?.count, 1)
        after = await s.fixture.stateMachine.state
        XCTAssertEqual(after.preview, 3)
        XCTAssertEqual(after.outputs, before.outputs, "带标记的那条没生效")

        // WS
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await next(ws, type: "snapshot")
        let inner = try body(rejected[3]).dropFirst(#"{"command":"#.count)   // {"command":<C>} → <C>}
        try await ws.send(#"{"id":"m","command":"# + inner)
        let err = try object(try await next(ws, type: "error"))
        XCTAssertEqual(err["id"] as? String, "m")
        XCTAssertEqual(err["error"] as? String, Self.markerRejection)
        after = await s.fixture.stateMachine.state
        XCTAssertEqual(after.outputs, before.outputs)

        // 原文照收
        let (stOK, textOK) = try await post(s, try body(.addOutput(config: Self.streamOutput(7, url: Self.url3, key: Self.key3))))
        XCTAssertEqual(stOK, 200, textOK)
        let seven = await output(s, 7)?.settings.stream
        XCTAssertEqual(seven?.url, Self.url3)
        XCTAssertEqual(seven?.streamKey, Self.key3)
    }
}
