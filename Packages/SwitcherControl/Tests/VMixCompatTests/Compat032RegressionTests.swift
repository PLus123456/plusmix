import Foundation
import XCTest
import SwitcherContracts
import SwitcherControl
@testable import VMixCompat

/// 提案 032 的兼容层回归用例（P5-5 的探针原样搬进来，用例全文与修前 / 修后结果在 reports/issues/ 里 P55 开头的那张问题单；G11 胶水）：
/// 修前主 API `addInput` 放进 2^62 之后 TCP `TALLY` 的 `reserveCapacity(最大编号)` 会带走整个 xctest 进程、`XML` 卡死；修后越界编号进不了状态。
final class Compat032RegressionTests: XCTestCase {
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
        XCTAssertEqual(try c.readLine(), "TALLY OK 1200")
        try c.send("XML")
        let (n, body) = try readXML(c)
        XCTAssertEqual(n, body.utf8.count + 2)
        var req = URLRequest(url: f.httpBase.appending(path: "/api/"))
        req.timeoutInterval = 5
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
    }
}
