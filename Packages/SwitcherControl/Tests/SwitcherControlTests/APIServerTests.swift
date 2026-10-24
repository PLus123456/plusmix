import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import Synchronization
@testable import SwitcherControl

/// HTTP + WebSocket API：GET state、POST command（含 400）、WS 推送（hello / snapshot / stats / receipt）、鉴权、C2 进程内延迟。
final class APIServerTests: XCTestCase {
    /// 起好的一整套：状态机 + 总线 + 推送 + 服务（端口 0）。
    struct Server {
        let fixture: BusFixture
        let feed: StateFeed
        let server: APIServer
        let clock: TickClockSpec
        var baseURL: URL { server.baseURL! }
        var wsURL: URL { URL(string: "ws://127.0.0.1:\(server.boundPort!)/api/v1/events")! }

        static func start(token: String? = nil, state: MixerState = TestStates.base()) async throws -> Server {
            let f = BusFixture(state: state)
            let clock = TickClockSpec(t0: HostClock.now(), frameRate: .fps60)
            let feed = StateFeed(stateMachine: f.stateMachine) { clock }
            await feed.start()
            let server = APIServer(bus: f.bus, feed: feed, configuration: APIServerConfiguration(host: "127.0.0.1", port: 0, token: token))
            try await server.start()
            return Server(fixture: f, feed: feed, server: server, clock: clock)
        }

        func stop() async {
            await server.stop()
            await feed.stop()
            fixture.stop()
        }
    }

    // MARK: HTTP helpers

    func get(_ url: URL, token: String? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["_raw": String(decoding: data, as: UTF8.self)]
        return (status, object)
    }

    func post(_ url: URL, body: String, token: String? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["_raw": String(decoding: data, as: UTF8.self)]
        return (status, object)
    }

    /// 收一条 WS 文本消息并解析成字典（超时抛错）。
    func receive(_ ws: WSClient, timeout: TimeInterval = 5) async throws -> [String: Any] {
        guard let text = await ws.next(timeout: timeout) else { throw NSError(domain: "ws", code: 2, userInfo: [NSLocalizedDescriptionKey: "超时没收到消息"]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: GET /api/v1/state

    func testAPI_getState_returnsStateTallyClockAndStats() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let (status, json) = try await get(s.baseURL.appending(path: "/api/v1/state"))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["version"] as? String, SwitcherVersion.current)
        // W2-C2：响应头里的服务器名是产品名
        let (_, raw) = try await URLSession.shared.data(from: s.baseURL.appending(path: "/api/v1/state"))
        XCTAssertEqual((raw as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server"), "PlusMix")
        XCTAssertEqual(json["sequence"] as? Int, 0)
        XCTAssertEqual(json["tick"] as? Int, 0)
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["program"] as? Int, 1)
        XCTAssertEqual(state["preview"] as? Int, 2)
        XCTAssertEqual((state["inputs"] as? [Any])?.count, 4)
        XCTAssertEqual((state["overlays"] as? [Any])?.count, 4, "键名与 Codable 一致")
        let tally = try XCTUnwrap(json["tally"] as? [String: [String: Bool]])
        XCTAssertEqual(tally["1"], ["program": true, "preview": false])
        XCTAssertEqual(tally["2"], ["program": false, "preview": true])
        XCTAssertEqual(tally["3"], ["program": false, "preview": false])
        XCTAssertTrue(json["stats"] is NSNull, "还没采到 stats 时是 null")
        let clock = try XCTUnwrap(json["clock"] as? [String: Any])
        XCTAssertEqual(clock["t0"] as? UInt64, s.clock.t0.ticks)
        let tb = try XCTUnwrap(json["timebase"] as? [String: Int])
        XCTAssertEqual(tb["numer"], Int(HostClock.timebase.numer))
        XCTAssertNotNil(json["now"] as? UInt64)
        XCTAssertNotNil(json["publishedAt"] as? UInt64, "提案 003：快照带发布时刻")
        // 状态与 API 数字同一份：灌一行 Stats 后 GET 能看到同一行
        let stats = Stats(ts: 1, tick: Tick(5), renderMs: 1.5, missedRender: 2, jitterMs: 0.1, perInput: [1: .init(fps: 60, dup: 3, drop: 4)],
                          encoder: [.init(skipped: 1, bitrate: 6e6)], audio: .init(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 20, gpuPct: 30)
        s.feed.publish(stats: stats)
        let (_, json2) = try await get(s.baseURL.appending(path: "/api/v1/state"))
        let got = try XCTUnwrap(json2["stats"] as? [String: Any])
        XCTAssertEqual(got["render_ms"] as? Double, 1.5)
        XCTAssertEqual(got["missed_render"] as? Int, 2)
        XCTAssertEqual((got["per_input"] as? [String: [String: Any]])?["1"]?["dup"] as? Int, 3)
        let line = try Stats.parse(line: String(decoding: try JSONSerialization.data(withJSONObject: got), as: UTF8.self))
        XCTAssertEqual(line, stats, "API 里的 stats 就是 stats.jsonl 那一行")
    }

    // MARK: POST /api/v1/command

    func testAPI_postCommand_receiptAnd400WithReason() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let url = s.baseURL.appending(path: "/api/v1/command")
        let (st1, r1) = try await post(url, body: #"{"command":{"cut":{}}}"#)
        XCTAssertEqual(st1, 200)
        XCTAssertEqual(r1["sequence"] as? Int, 1)
        XCTAssertEqual(r1["appliedTick"] as? Int, 0)
        XCTAssertEqual(r1["applied"] as? Bool, true)
        XCTAssertNotNil(r1["issuedAt"] as? UInt64)
        XCTAssertEqual(r1["appliedTickTime"] as? UInt64, s.clock.time(of: .zero).ticks)
        // 被 reducer 忽略的命令：200 但 applied == false（提案 003 §A）
        let (stIgnored, rIgnored) = try await post(url, body: #"{"command":{"mute":{"input":1,"on":false}}}"#)
        XCTAssertEqual(stIgnored, 200)
        XCTAssertEqual(rIgnored["applied"] as? Bool, false)
        XCTAssertEqual(rIgnored["sequence"] as? Int, 2)
        // 直接放 Command 也行
        let (st2, r2) = try await post(url, body: #"{"setPreview":{"input":3}}"#)
        XCTAssertEqual(st2, 200)
        XCTAssertEqual(r2["sequence"] as? Int, 3)
        XCTAssertEqual(r2["applied"] as? Bool, true)
        let state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.program, 2)
        XCTAssertEqual(state.preview, 3)
        // 非法：不存在的输入
        let (st3, r3) = try await post(url, body: #"{"command":{"setPreview":{"input":9}}}"#)
        XCTAssertEqual(st3, 400)
        XCTAssertTrue((r3["error"] as? String ?? "").contains("输入 9"), "\(r3)")
        // 非法：不认识的命令 / 坏 JSON
        let (st4, r4) = try await post(url, body: #"{"command":{"explode":{}}}"#)
        XCTAssertEqual(st4, 400)
        XCTAssertFalse((r4["error"] as? String ?? "").isEmpty)
        let (st5, _) = try await post(url, body: "{not json")
        XCTAssertEqual(st5, 400)
        XCTAssertEqual(s.fixture.bus.lastSequence, 3, "被拒的不占 sequence")
        XCTAssertEqual(s.fixture.bus.counters.ignored, 1)
        // 目录
        let (st6, r6) = try await get(s.baseURL.appending(path: "/api/v1/commands"))
        XCTAssertEqual(st6, 200)
        XCTAssertEqual((r6["commands"] as? [Any])?.count, 42)   // 提案 026（P5）：setMonitorSource → 35；P5-2：020 / 021 / 023 → 42
    }

    /// 提案 031（P5-4，Codex 审查 D01 的复现路径）：主 API 上 rate = 0 / −1 / 1e300、seconds = 1e300 → HTTP 400 带理由，不占 sequence；边界值 200。
    func test031_postCommand_fileRateAndSeekOutOfRange_400() async throws {
        var state = TestStates.base()
        state.inputs.append(InputConfig(number: 6, name: "片", source: .file(path: "/clip.mov", endAction: .loop, rate: 1)))
        let s = try await Server.start(state: state)
        defer { Task { await s.stop() } }
        let url = s.baseURL.appending(path: "/api/v1/command")
        for rate in ["0", "-1", "1e300"] {
            let body = #"{"command":{"setInputSource":{"input":6,"source":{"file":{"endAction":"loop","path":"/clip.mov","rate":"# + rate + "}}}}}"
            let (st, r) = try await post(url, body: body)
            XCTAssertEqual(st, 400, "rate \(rate)")
            XCTAssertTrue((r["error"] as? String ?? "").contains("播放速率必须在 0.1–8 之间"), "\(r)")
        }
        let (stSeek, rSeek) = try await post(url, body: #"{"command":{"seekPlayback":{"input":6,"seconds":1e300}}}"#)
        XCTAssertEqual(stSeek, 400)
        XCTAssertTrue((rSeek["error"] as? String ?? "").contains("定位秒数"), "\(rSeek)")
        XCTAssertEqual(s.fixture.bus.lastSequence, 0, "被拒的不占 sequence")
        let (stOK, rOK) = try await post(url, body: #"{"command":{"setInputSource":{"input":6,"source":{"file":{"endAction":"loop","path":"/clip.mov","rate":8}}}}}"#)
        XCTAssertEqual(stOK, 200)
        XCTAssertEqual(rOK["applied"] as? Bool, true)
        let after = await s.fixture.stateMachine.state
        XCTAssertEqual(after.input(6)?.source, .file(path: "/clip.mov", endAction: .loop, rate: 8))
    }

    /// 提案 032（用户 2026-10-18 批，P5-5）：W2-C4 报告 §3 第 4 条的触发条件——主 API `POST /api/v1/command` 加一路 2^62 号输入——现在回 400 带理由、不占 sequence、
    /// 状态里没有它（原来 200 照收，开着兼容层时 TALLY / XML 按编号分配崩或卡）；17 号同样 400；16 号 200；GET state 里的编号都在 1…16。
    func test032_postCommand_inputNumberAboveRange_400() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let url = s.baseURL.appending(path: "/api/v1/command")
        func addInput(_ number: Int) throws -> String {
            let command = Command.addInput(config: InputConfig(number: number, name: "极大", source: .image(path: "/a.png")))
            let body = #"{"command":"# + String(decoding: try JSONEncoder().encode(command), as: UTF8.self) + "}"
            XCTAssertTrue(body.contains(#""number":\#(number)"#), body)
            return body
        }
        for number in [1 << 62, 17] {
            let (st, r) = try await post(url, body: try addInput(number))
            XCTAssertEqual(st, 400, "\(number)：\(r)")
            XCTAssertTrue((r["error"] as? String ?? "").contains("输入编号必须在 1–16 之间：\(number)"), "\(r)")
        }
        XCTAssertEqual(s.fixture.bus.lastSequence, 0, "被拒的不占 sequence")
        let (stOK, rOK) = try await post(url, body: try addInput(16))
        XCTAssertEqual(stOK, 200, "\(rOK)")
        XCTAssertEqual(rOK["applied"] as? Bool, true)
        let (stState, state) = try await get(s.baseURL.appending(path: "/api/v1/state"))
        XCTAssertEqual(stState, 200)
        let inputs = try XCTUnwrap((state["state"] as? [String: Any])?["inputs"] as? [[String: Any]], "\(state.keys)")
        XCTAssertEqual(inputs.compactMap { $0["number"] as? Int }, [1, 2, 3, 4, 16])
    }

    // MARK: 批量、日志、tally

    func testAPI_batchCommands_logAndTally() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let url = s.baseURL.appending(path: "/api/v1/command")
        // 批量：顺序执行，sequence 连续
        let (st1, r1) = try await post(url, body: #"{"commands":[{"setPreview":{"input":3}},{"cut":{}},{"renameInput":{"input":1,"name":"甲"}}]}"#)
        XCTAssertEqual(st1, 200)
        let receipts = try XCTUnwrap(r1["receipts"] as? [[String: Any]])
        XCTAssertEqual(receipts.map { $0["sequence"] as? Int }, [1, 2, 3])
        XCTAssertEqual(receipts.map { $0["applied"] as? Bool }, [true, true, true])
        var state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.program, 3)
        XCTAssertEqual(state.input(1)?.name, "甲")
        // 中途一条非法：前面的已生效，返回 400 带 index 与已有回执
        let (st2, r2) = try await post(url, body: #"{"commands":[{"setPreview":{"input":4}},{"setPreview":{"input":99}},{"cut":{}}]}"#)
        XCTAssertEqual(st2, 400)
        XCTAssertEqual(r2["index"] as? Int, 1)
        XCTAssertEqual((r2["receipts"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue((r2["error"] as? String ?? "").contains("输入 99"))
        state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.preview, 4, "第一条生效")
        XCTAssertEqual(state.program, 3, "第三条没执行")
        XCTAssertEqual(s.fixture.bus.lastSequence, 4)
        // 空批量 / 不是数组：400
        let (st3, _) = try await post(url, body: #"{"commands":[]}"#)
        XCTAssertEqual(st3, 400)
        // 日志：最近的命令，带来源和拍
        let (st4, r4) = try await get(s.baseURL.appending(path: "/api/v1/log").appending(queryItems: [.init(name: "limit", value: "2")]))
        XCTAssertEqual(st4, 200)
        let entries = try XCTUnwrap(r4["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?["sequence"] as? Int, 4)
        XCTAssertEqual(entries.last?["source"] as? String, "api")
        XCTAssertEqual(entries.last?["applied"] as? Bool, true)
        XCTAssertNotNil((entries.last?["command"] as? [String: Any])?["setPreview"])
        XCTAssertNotNil(entries.last?["appliedTick"])
        let (_, r5) = try await get(s.baseURL.appending(path: "/api/v1/log"))
        XCTAssertEqual((r5["entries"] as? [Any])?.count, 4)
        // tally 快捷端点
        let (st6, r6) = try await get(s.baseURL.appending(path: "/api/v1/tally"))
        XCTAssertEqual(st6, 200)
        XCTAssertEqual(r6["program"] as? Int, 3)
        XCTAssertEqual(r6["preview"] as? Int, 4)
        XCTAssertEqual(r6["sequence"] as? Int, 4)
        XCTAssertEqual((r6["tally"] as? [String: [String: Bool]])?["3"], ["program": true, "preview": false])
        XCTAssertEqual((r6["tally"] as? [String: [String: Bool]])?["4"], ["program": false, "preview": true])
        // WS 上的批量
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await receive(ws); _ = try await receive(ws)
        try await ws.send(#"{"id":9,"commands":[{"setPreview":{"input":2}},{"cut":{}}]}"#)
        var got: [String: Any]? = nil
        for _ in 0..<4 {
            let m = try await receive(ws)
            if m["type"] as? String == "receipts" { got = m; break }
        }
        let batch = try XCTUnwrap(got)
        XCTAssertEqual(batch["id"] as? Int, 9)
        XCTAssertEqual((batch["receipts"] as? [[String: Any]])?.map { $0["sequence"] as? Int }, [5, 6])
        state = await s.fixture.stateMachine.state
        XCTAssertEqual(state.program, 2)
    }

    // MARK: WS /api/v1/events

    func testAPI_wsEvents_helloSnapshotStatsReceiptAndTally() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        let hello = try await receive(ws)
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["version"] as? String, SwitcherVersion.current)
        XCTAssertNotNil(hello["clock"] as? [String: Any])
        let first = try await receive(ws)
        XCTAssertEqual(first["type"] as? String, "snapshot")
        XCTAssertEqual(first["sequence"] as? Int, 0)
        XCTAssertEqual((first["state"] as? [String: Any])?["program"] as? Int, 1)
        XCTAssertEqual((first["tally"] as? [String: [String: Bool]])?["1"], ["program": true, "preview": false])

        // 总线上的命令 → 推送
        _ = try await s.fixture.bus.submit(.cut, source: .ui)
        let snap = try await receive(ws)
        XCTAssertEqual(snap["type"] as? String, "snapshot")
        XCTAssertEqual(snap["sequence"] as? Int, 1)
        XCTAssertEqual((snap["state"] as? [String: Any])?["program"] as? Int, 2)
        XCTAssertEqual((snap["tally"] as? [String: [String: Bool]])?["2"], ["program": true, "preview": false])
        XCTAssertEqual((snap["tally"] as? [String: [String: Bool]])?["1"], ["program": false, "preview": true])
        XCTAssertNotNil(snap["tickTime"] as? UInt64)
        XCTAssertNotNil(snap["sentAt"] as? UInt64)
        let publishedAt = try XCTUnwrap(snap["publishedAt"] as? UInt64)
        XCTAssertLessThanOrEqual(publishedAt, try XCTUnwrap(snap["sentAt"] as? UInt64), "先发布后序列化")

        // 拍推进带来的变化（转场进度）→ 推送：第 10 拍起 fade 30 拍，一次 prepare 到 20 → 一条快照（tick 20，progress 1/3）
        await s.fixture.stateMachine.schedule(.fade(durationTicks: 30), at: Tick(10))
        await s.fixture.stateMachine.prepare(upTo: Tick(20))
        let mid = try await receive(ws)
        XCTAssertEqual(mid["type"] as? String, "snapshot")
        XCTAssertEqual(mid["tick"] as? Int, 20)
        let tr = try XCTUnwrap((mid["state"] as? [String: Any])?["transition"] as? [String: Any])
        XCTAssertEqual(tr["progress"] as? Double ?? -1, 10.0 / 30.0, accuracy: 1e-9)
        // 转场中：PVW 也算在 PGM 上（tally 规则）
        XCTAssertEqual((mid["tally"] as? [String: [String: Bool]])?["1"], ["program": true, "preview": true])

        // stats
        let stats = Stats(ts: 2, tick: Tick(20), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [], audio: .init(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1)
        s.feed.publish(stats: stats)
        let st = try await receive(ws)
        XCTAssertEqual(st["type"] as? String, "stats")
        XCTAssertEqual((st["stats"] as? [String: Any])?["tick"] as? Int, 20)

        // 走 WS 发命令：Fade 还在进行（第 40 拍才对调），setPreview 被 reducer 拒（W5-E，Q66 (a)）——回执 applied = false，快照照推、PVW 仍是 1
        try await ws.send(#"{"id":7,"command":{"setPreview":{"input":4}}}"#)
        var seenReceipt = false, seenSnapshot = false
        for _ in 0..<2 {
            let m = try await receive(ws)
            switch m["type"] as? String {
            case "receipt":
                seenReceipt = true
                XCTAssertEqual(m["id"] as? Int, 7)
                XCTAssertEqual(m["sequence"] as? Int, 2)
                XCTAssertEqual(m["applied"] as? Bool, false, "转场进行中 setPreview 被拒")
            case "snapshot":
                seenSnapshot = true
                XCTAssertEqual((m["state"] as? [String: Any])?["preview"] as? Int, 1, "被拒的命令不改 PVW")
            default: XCTFail("\(m)")
            }
        }
        XCTAssertTrue(seenReceipt && seenSnapshot)
        try await ws.send(#"{"id":"x","command":{"setPreview":{"input":99}}}"#)
        let err = try await receive(ws)
        XCTAssertEqual(err["type"] as? String, "error")
        XCTAssertEqual(err["id"] as? String, "x")
        XCTAssertTrue((err["error"] as? String ?? "").contains("输入 99"))
        XCTAssertEqual(s.feed.counters.subscribers, 1)
    }

    // MARK: 鉴权

    func testAPI_tokenAuth_401WithoutToken() async throws {
        let s = try await Server.start(token: "secret")
        defer { Task { await s.stop() } }
        let url = s.baseURL.appending(path: "/api/v1/state")
        let (st1, e1) = try await get(url)
        XCTAssertEqual(st1, 401)
        XCTAssertNotNil(e1["error"])
        let (st2, _) = try await get(url, token: "wrong")
        XCTAssertEqual(st2, 401)
        let (st3, _) = try await get(url, token: "secret")
        XCTAssertEqual(st3, 200)
        let (st4, _) = try await post(s.baseURL.appending(path: "/api/v1/command"), body: #"{"cut":{}}"#)
        XCTAssertEqual(st4, 401)
        // WS：query token
        let ok = WSClient(url: URL(string: s.wsURL.absoluteString + "?token=secret")!)
        let hello = try await receive(ok)
        XCTAssertEqual(hello["type"] as? String, "hello")
        ok.close()
        let bad = WSClient(url: s.wsURL)
        do {
            _ = try await receive(bad, timeout: 3)
            XCTFail("没有 token 的 WS 应连不上")
        } catch {}
        XCTAssertNotNil(bad.error, "应以错误结束")
        bad.close()
    }

    // MARK: C2 进程内：状态变化 → 客户端收到 ≤ 50 ms（目标 20），报 p99

    func testC2_pushLatency_inProcess_p99() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await receive(ws)   // hello
        _ = try await receive(ws)   // 当前快照
        var transportMs: [Double] = []
        var fromPublishMs: [Double] = []
        var fromTickMs: [Double] = []
        let n = 200
        for k in 0..<n {
            // 一半走命令（立即发布），一半走拍推进（fade 每拍一条）
            if k % 2 == 0 {
                _ = try await s.fixture.bus.submit(.setPreview(input: k % 4 + 1), source: .api)
            } else {
                let tick = await s.fixture.stateMachine.tick
                await s.fixture.stateMachine.schedule(.setPreview(input: (k + 1) % 4 + 1), at: tick + 1)
                await s.fixture.stateMachine.prepare(upTo: tick + 1)
            }
            let timedOrNil = await ws.nextTimed(timeout: 5)
            let timed = try XCTUnwrap(timedOrNil)
            let m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(timed.text.utf8)) as? [String: Any])
            let recv = timed.receivedAt
            XCTAssertEqual(m["type"] as? String, "snapshot")
            let sentAt = HostTime(ticks: try XCTUnwrap(m["sentAt"] as? UInt64))
            let tickTime = HostTime(ticks: try XCTUnwrap(m["tickTime"] as? UInt64))
            let publishedAt = HostTime(ticks: try XCTUnwrap(m["publishedAt"] as? UInt64))
            transportMs.append((recv - sentAt).milliseconds)
            fromPublishMs.append((recv - publishedAt).milliseconds)
            fromTickMs.append((recv - tickTime).milliseconds)
            try await Task.sleep(for: .milliseconds(2))
        }
        func p99(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int((Double(s.count) * 0.99).rounded(.up)) - 1)] }
        let p = p99(transportMs)
        let pp = p99(fromPublishMs)
        print("C2 进程内 transport：p50 \(transportMs.sorted()[n / 2]) ms，p99 \(p) ms，max \(transportMs.max()!) ms；状态机发布 → 收到 p50 \(fromPublishMs.sorted()[n / 2]) / p99 \(pp) / max \(fromPublishMs.max()!) ms；相对拍点 p99 \(p99(fromTickMs)) ms")
        XCTAssertLessThanOrEqual(p, 50, "C2 必须 ≤ 50 ms")
        XCTAssertLessThanOrEqual(pp, 50, "C2（从状态机发布算）必须 ≤ 50 ms")
        XCTAssertGreaterThanOrEqual(fromPublishMs.min()!, 0, "发布时刻不会晚于收到时刻")
        XCTAssertEqual(s.feed.counters.snapshots, UInt64(n), "每次变化一条快照（订阅时补发的当前快照不计）")
    }

    /// 同一拍内多条命令只推最终状态；订阅者慢也不会拖住总线。
    func testAPI_wsSlowSubscriberDoesNotBlockBus() async throws {
        let s = try await Server.start()
        defer { Task { await s.stop() } }
        let ws = WSClient(url: s.wsURL)
        defer { ws.close() }
        _ = try await receive(ws); _ = try await receive(ws)
        // 不读 WS，猛发 2000 条命令：总线不能被订阅者的缓冲拖住
        let t = ContinuousClock.now
        for k in 0..<2000 { _ = try await s.fixture.bus.submit(.renameInput(input: 1, name: "n\(k)"), source: .api) }
        let elapsed = ContinuousClock.now - t
        XCTAssertLessThan(elapsed, .seconds(5), "2000 条用了 \(elapsed)")
        // 最后收到的快照一定是最终状态（缓冲丢的是旧的）
        var last: [String: Any] = [:]
        while let m = try? await receive(ws, timeout: 0.3) { last = m }
        XCTAssertEqual((last["state"] as? [String: Any])?["inputs"].flatMap { ($0 as? [[String: Any]])?.first?["name"] as? String }, "n1999")
        XCTAssertEqual(last["sequence"] as? Int, 2000)
    }
}

/// 测试用 WS 客户端：一条常驻接收任务把消息放进队列，`next(timeout:)` 轮询取——URLSessionWebSocketTask.receive() 不能被取消，
/// 直接在它上面做超时会把任务组挂死。
final class WSClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let queue = Mutex<[(text: String, receivedAt: HostTime)]>([])
    private let failure = Mutex<(any Error)?>(nil)
    private var reader: Task<Void, Never>?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let t = task
        reader = Task { [self] in
            while true {
                do {
                    let m = try await t.receive()
                    if case .string(let s) = m { let at = HostClock.now(); self.queue.withLock { $0.append((s, at)) } }
                } catch {
                    self.failure.withLock { $0 = error }
                    return
                }
            }
        }
    }

    var error: (any Error)? { failure.withLock { $0 } }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func next(timeout: TimeInterval) async -> String? { await nextTimed(timeout: timeout)?.text }

    /// 消息和它在接收任务里到达的时刻（C2 用这个时刻，不含轮询的等待）。
    func nextTimed(timeout: TimeInterval) async -> (text: String, receivedAt: HostTime)? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let s = queue.withLock({ q -> (text: String, receivedAt: HostTime)? in q.isEmpty ? nil : q.removeFirst() }) { return s }
            if Date() >= deadline || error != nil { return nil }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func close() {
        reader?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}
