# P5-5 → W2-C 系 / G11：VMixCompatTests 补一条"主 API 加极大编号后兼容层照常应答"（提案 032 的兼容层回归用例）

归属会话 / 分支：W2-C 系（下一张控制层会话）或 G11 胶水（VMixCompatTests 不在 P5-5 `p5-contracts-5` 的目录；prompt 123 第 3 条："用例若要进那边写进报告给 G 类会话或 W2-C 系"）
发现于：P5-5（prompt 123）落地提案 032 时；触发条件出自 reports/w2-control-4.md §3 第 4 条
严重级：修之前 S1（0.1.1 唯一挡发布的那一条）；P5-5 已在契约 / 校验器 / reducer 修好，本单只是补兼容层这一侧的回归用例，不是新缺陷

## 现象（修前，P5-5 在 1f9be64 + 2ec2c05 的树上复现）

同一套状态机 + 总线上起主 API 和兼容层，主 API `POST /api/v1/command` 发 `addInput`（编号 2^62）：
- 修前：`200 {"applied":true,…}`，状态里的编号 `[1, 2, 3, 4, 4611686018427387904]`；接着兼容层 TCP 发 `TALLY` → `Fatal error: failed to allocate 4611686018427387952 bytes of memory with alignment 8`，xctest 进程被杀（`TallyDigits.string` 的 `reserveCapacity(最大编号)`）。XML（`StatusXML` 按 1…最大编号写占位）没再试——它是卡死，不是崩。
- 修后（P5-5，`p5-contracts-5`）：2^62 / Int.max / 17 → `400 {"error":"输入编号必须在 1–16 之间：<n>"}`；绕过校验器直接发给状态机 → reducer 原样返回；兼容层 TCP `TALLY OK 1200`、TCP `XML` 与 HTTP `/api` 都照常应答（2056 字节）。

## 复现步骤 / 用例全文

P5-5 用下面这条做的临时探针（放在 `Packages/SwitcherControl/Tests/VMixCompatTests/`，用 VMixCompatTests 自己的 `CompatFixture` / `LineClient` / `readXML`；跑完删了、没提交）。
合入 P5-5 之后原样放进 VMixCompatTests（建议放 `CompatHardeningTests.swift`，名字改成 `test032_…` 或该会话的 ID）就是一条回归用例；在修前的树上它会把 xctest 进程带走（上面那行 Fatal error）。

```swift
final class Tmp032ProbeTests: XCTestCase {
    func test032_mainAPIHugeInputNumber_compatTallyAndXMLStillAnswer() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let api = APIServer(bus: f.bus, feed: f.feed, configuration: APIServerConfiguration(host: "127.0.0.1", port: 0, token: nil))
        try await api.start()
        defer { Task { await api.stop() } }

        // 主 API：POST addInput 2^62 / Int.max / 17 → 400，状态里没有
        for number in [1 << 62, Int.max, 17] {
            let command = Command.addInput(config: InputConfig(number: number, name: "极大", source: .image(path: "/a.png")))
            var req = URLRequest(url: api.baseURL!.appending(path: "/api/v1/command"))
            req.httpMethod = "POST"
            req.httpBody = Data((#"{"command":"# + String(decoding: try JSONEncoder().encode(command), as: UTF8.self) + "}").utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, resp) = try await URLSession.shared.data(for: req)
            XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 400, "\(number)：\(String(decoding: data, as: UTF8.self))")
            print("[032 探针] POST addInput \(number) → \((resp as! HTTPURLResponse).statusCode) \(String(decoding: data, as: UTF8.self))")
        }
        // 直接发给状态机（绕过校验器）：reducer 也不收
        _ = await f.stateMachine.submit(IssuedCommand(sequence: 99, issuedAt: .now(),
                                                      command: .addInput(config: InputConfig(number: 1 << 62, name: "极大", source: .image(path: "/a.png")))))
        let state = await f.stateMachine.state
        XCTAssertEqual(state.inputs.map(\.number), [1, 2, 3, 4])

        // 兼容层：TCP TALLY / XML、HTTP /api 照常应答
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("TALLY")
        let tally = try c.readLine()
        XCTAssertEqual(tally, "TALLY OK 1200")
        try c.send("XML")
        let (n, body) = try readXML(c)
        XCTAssertEqual(n, body.utf8.count + 2)
        var req = URLRequest(url: f.httpBase.appending(path: "/api/"))
        req.timeoutInterval = 5
        let (xml, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
        print("[032 探针] TCP \(tally ?? "nil")；XML \(body.utf8.count) 字节；HTTP /api \((resp as! HTTPURLResponse).statusCode) \(xml.count) 字节")
    }
}
```

运行：`swift test --package-path Packages/SwitcherControl --filter VMixCompatTests.Tmp032ProbeTests`（P5-5 本机 0.026 s 过）。
