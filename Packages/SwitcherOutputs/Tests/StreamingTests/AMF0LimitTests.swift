import Foundation
import XCTest
import RTMPHaishinKit
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// NS04（Codex 10-24 审计 [4]）：Adobe 鉴权前两轮的最小 RTMP 客户端解析服务器回的 `_result` / `_error`，AMF0 的对象 / 数组原来递归无上限——
/// 恶意服务器回 10 万层单元素严格数组（约 500 KB）就把栈打穿（SIGBUS，推流进程没了；debug 构建 1000 层就崩）。现在嵌套最多
/// `RTMPConnectCommand.maxNestingDepth`（32）层、一条回复最多 `maxElements`（1 万）个值，超了报 `Failure.protocolError`，进程照常。
/// RTMPS 走同一个 RTMPConnectProbe / RTMPConnectCommand.reply（只是连接换成 TLS），由下面的单元用例覆盖，不另搭 TLS 服务器。
/// HaishinKit 2.2.5 自己的 AMF0 解析同样递归无上限（W2-D5 探针：它自己 connect 也是 1000 层就 SIGBUS），所以超上限的回复不再退回交给它连。
final class AMF0LimitTests: XCTestCase {
    private var servers: [HostileRTMPServer] = []

    override func tearDown() {
        for s in servers { s.stop() }
        servers = []
    }

    private func server(_ port: Int, reply: @escaping @Sendable (Double) -> [UInt8]) throws -> HostileRTMPServer {
        let s = try HostileRTMPServer(port: port, reply: reply)
        servers.append(s)
        return s
    }

    /// `_result`(1, null, <value>)：value 放在第四个值（状态对象的位置）。
    private func result(_ value: [UInt8]) -> Data {
        Data(AMF0.string("_result") + AMF0.number(1) + [0x05] + value)
    }

    private func assertProtocolError(_ payload: Data, _ message: String, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RTMPConnectCommand.reply(payload), note, file: file, line: line) { error in
            XCTAssertEqual(error as? RTMPAdobeAuth.Failure, .protocolError(message), note, file: file, line: line)
        }
    }

    // MARK: 解析器（单元；RTMP / RTMPS 共用）

    /// 嵌套上限：容器（严格数组 0x0A / 对象 0x03 / ECMA 数组 0x08 / 类型对象 0x10）套容器最多 32 层，第 33 层就拒（空的也拒）；
    /// 第三个值（命令对象）和第四个值（状态对象）两个位置一样；10 万层（C06 的写法）也是立刻报错、不崩。
    func testNS04_reply_nestingDepthLimit() throws {
        let limit = RTMPConnectCommand.maxNestingDepth
        XCTAssertEqual(limit, 32)
        let tooDeep = RTMPConnectCommand.tooDeepMessage
        XCTAssertEqual(tooDeep, "AMF0 嵌套过深")
        // 32 层：照旧解析（第四个值不是对象 → 状态为空）
        XCTAssertNotNil(try RTMPConnectCommand.reply(result(HostileRTMPServer.nestedStrictArrays(depth: limit))))
        XCTAssertNotNil(try RTMPConnectCommand.reply(result(HostileRTMPServer.nestedObjects(depth: limit))))
        // 33 层：各种容器都拒
        assertProtocolError(result(HostileRTMPServer.nestedStrictArrays(depth: limit + 1)), tooDeep, "严格数组 33 层")
        assertProtocolError(result(HostileRTMPServer.nestedObjects(depth: limit + 1)), tooDeep, "对象 33 层")
        let emptyInnermost = [UInt8]((0..<limit).flatMap { _ in [0x0A, 0, 0, 0, 1] as [UInt8] }) + [0x0A, 0, 0, 0, 0]
        assertProtocolError(result(emptyInnermost), tooDeep, "第 33 层是空数组也拒：数的是容器层数")
        var ecma: [UInt8] = []
        for _ in 0...limit { ecma += [0x08, 0, 0, 0, 1, 0x00, 0x01, UInt8(ascii: "k")] }
        ecma.append(0x05)
        for _ in 0...limit { ecma += [0x00, 0x00, 0x09] }
        assertProtocolError(result(ecma), tooDeep, "ECMA 数组 33 层")
        var typed: [UInt8] = []
        for _ in 0...limit { typed += [0x10, 0x00, 0x01, UInt8(ascii: "T"), 0x00, 0x01, UInt8(ascii: "k")] }
        typed.append(0x05)
        for _ in 0...limit { typed += [0x00, 0x00, 0x09] }
        assertProtocolError(result(typed), tooDeep, "类型对象 33 层")
        // 第三个值（命令对象的位置）深嵌套：同样拒
        let third = Data(AMF0.string("_result") + AMF0.number(1) + HostileRTMPServer.nestedStrictArrays(depth: limit + 1) + AMF0.object([]))
        assertProtocolError(third, tooDeep, "第三个值")
        // C06：10 万层（约 500 KB），原来在这里把栈打穿
        let t0 = Date()
        assertProtocolError(result(HostileRTMPServer.nestedStrictArrays(depth: 100_000)), tooDeep, "10 万层严格数组")
        assertProtocolError(result(HostileRTMPServer.nestedObjects(depth: 100_000)), tooDeep, "10 万层对象")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "超上限要立刻报错")
    }

    /// 元素预算：一条回复最多解析 1 万个值（防一个百万元素的数组在超时之前同步空转）；数组声称的长度比剩下的字节还多 → 越界报错，不空转。
    func testNS04_reply_elementBudget() throws {
        let budget = RTMPConnectCommand.maxElements
        XCTAssertEqual(budget, 10_000)
        func nulls(_ n: Int) -> [UInt8] { [0x0A, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + [UInt8](repeating: 0x05, count: n) }
        // 名字 + txid + null + 数组本身 = 4 个值，数组里再放 budget - 4 个正好到上限
        XCTAssertNotNil(try RTMPConnectCommand.reply(result(nulls(budget - 4))), "正好 1 万个值：照旧解析")
        assertProtocolError(result(nulls(budget - 3)), RTMPConnectCommand.tooManyElementsMessage, "1 万零 1 个值")
        XCTAssertEqual(RTMPConnectCommand.tooManyElementsMessage, "AMF0 元素过多")
        var wide: [UInt8] = [0x03]
        for k in 0..<(budget + 1) {
            let key: [UInt8] = Array("k\(k)".utf8)
            wide += [UInt8(key.count >> 8), UInt8(key.count & 0xFF)]
            wide += key
            wide.append(0x05)
        }
        wide += [0x00, 0x00, 0x09]
        assertProtocolError(result(wide), RTMPConnectCommand.tooManyElementsMessage, "1 万多个键的对象")
        // 16 MB 的消息（24 位长度的上限）塞满 null：在预算处就停
        let t0 = Date()
        assertProtocolError(result(nulls(16 * 1024 * 1024 - 64)), RTMPConnectCommand.tooManyElementsMessage, "16 MB 的 null")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        assertProtocolError(result([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x05, 0x05]), "AMF0 越界", "声称 40 亿个元素、只有两个字节")
    }

    /// 真实的回复照旧：测试网关（独立实现）拼的 _result / _error、Wowza / FMS 那种状态对象里带 data（ECMA 数组）的、命令对象嵌 4 层的；
    /// 别的命令（onBWDone）照旧返回 nil。
    func testNS04_reply_realRepliesStillParse() throws {
        let ok = try XCTUnwrap(try RTMPConnectCommand.reply(Data(AMF0.connectSuccess(txid: 1))))
        XCTAssertEqual(ok.txid, 1)
        XCTAssertEqual(ok.reply, .init(command: "_result", level: "status", code: "NetConnection.Connect.Success", description: "Connection succeeded."))
        let description = "[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=needauth&user=pub&salt=c2FsdA==&challenge=Y2hhbA==&opaque=b3BhcXVl"
        let rejected = try XCTUnwrap(try RTMPConnectCommand.reply(Data(AMF0.connectError(txid: 1, description: description))))
        XCTAssertEqual(rejected.reply, .init(command: "_error", level: "error", code: "NetConnection.Connect.Rejected", description: description))
        // Wowza 风格：状态对象里有 data（ECMA 数组 {version}）；命令对象嵌 4 层
        let data: [UInt8] = [0x08, 0, 0, 0, 1] + [0x00, 0x07] + Array("version".utf8) + AMF0.string("4,0,0,1") + [0x00, 0x00, 0x09]
        let level4 = AMF0.object([("a", AMF0.object([("b", AMF0.object([("c", [0x0A, 0, 0, 0, 1] + AMF0.number(1))]))]))])
        let wowza = AMF0.string("_result") + AMF0.number(1) + AMF0.object([("fmsVer", AMF0.string("FMS/3,5,7,7009")), ("capabilities", AMF0.number(31)), ("nested", level4)])
            + AMF0.object([("level", AMF0.string("status")), ("code", AMF0.string("NetConnection.Connect.Success")),
                           ("description", AMF0.string("Connection succeeded.")), ("data", data), ("objectEncoding", AMF0.number(0))])
        let w = try XCTUnwrap(try RTMPConnectCommand.reply(Data(wowza)))
        XCTAssertTrue(w.reply.isSuccess, "\(w.reply)")
        XCTAssertNil(try RTMPConnectCommand.reply(Data(AMF0.string("onBWDone") + AMF0.number(0) + [0x05])), "别的命令返回 nil")
    }

    // MARK: 本机回环（Adobe 鉴权的最小客户端）

    /// C06 的场景走真网络：带账号的地址做 Adobe 鉴权第 1 轮，服务器回 100 / 1000 / 10 万层嵌套的 _result → authorize 报协议错误
    /// （"RTMP 协议错误：AMF0 嵌套过深"）、很快返回、进程在（原来 100 层走到"服务器拒绝"、1000 层起 SIGBUS）。
    func testNS04_adobeAuth_deepReplyOverLoopback_protocolErrorAndProcessSurvives() async throws {
        for (offset, depth) in [100, 1_000, 100_000].enumerated() {
            let s = try server(19471 + offset, reply: HostileRTMPServer.deepResult(depth: depth))
            let t0 = Date()
            do {
                _ = try await RTMPAdobeAuth.authorize(connectURL: "rtmp://127.0.0.1:\(s.port)/s1", credentials: .init(user: "pub", password: "secret"), timeoutSeconds: 5)
                XCTFail("\(depth) 层应该报协议错误")
            } catch let e as RTMPAdobeAuth.Failure {
                XCTAssertEqual(e, .protocolError("AMF0 嵌套过深"), "\(depth) 层")
                XCTAssertEqual(e.description, "RTMP 协议错误：AMF0 嵌套过深")
            }
            XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "\(depth) 层：不用等到超时")
            XCTAssertEqual(s.connectApps, ["s1"], "\(depth) 层：只连了第 1 轮")
        }
    }

    /// 正常的服务器照旧：第 1 轮就回 Connect.Success（命令对象嵌 4 层、状态对象带 data）→ authorize 原样返回不带 userinfo 的地址。
    func testNS04_adobeAuth_fourLevelSuccessOverLoopback_stillAccepted() async throws {
        let level4 = AMF0.object([("a", AMF0.object([("b", AMF0.object([("c", [0x0A, 0, 0, 0, 1] + AMF0.number(1))]))]))])
        let s = try server(19474) { txid in
            AMF0.string("_result") + AMF0.number(txid) + AMF0.object([("fmsVer", AMF0.string("FMS/3,0,1,123")), ("nested", level4)])
                + AMF0.object([("level", AMF0.string("status")), ("code", AMF0.string("NetConnection.Connect.Success")),
                               ("description", AMF0.string("Connection succeeded."))])
        }
        let target = try await RTMPAdobeAuth.authorize(connectURL: "rtmp://127.0.0.1:\(s.port)/s1", credentials: .init(user: "pub", password: "secret"), timeoutSeconds: 5)
        XCTAssertEqual(target, "rtmp://127.0.0.1:\(s.port)/s1", "connect 阶段不要鉴权：原地址")
    }

    // MARK: 经 RTMPTransport（生产路径）

    /// 带账号的 RTMP 推到回深嵌套的服务器：我们的解析器报协议错误之后不再退回交给 HaishinKit（它的 AMF0 解析同样递归无上限，
    /// 同一条回复会把进程打崩）——connect 报连接失败（StreamOutput 照旧退避重试，每次先过我们的解析），服务器只见过我们那一条连接。
    func testNS04_rtmpTransport_deepReply_failsWithoutHaishinKitFallback() async throws {
        let s = try server(19475, reply: HostileRTMPServer.deepResult(depth: 100_000))
        let d = try StreamDestination(settings: StreamSettings(url: "rtmp://pub:secret@127.0.0.1:\(s.port)/live/key"))
        let transport = try HaishinKitTransportFactory(format: .hd1080p60, video: VideoEncodeSettings(), connectTimeoutSeconds: 5)
            .makeTransport(for: d, audioFormat: nil)
        do {
            try await withTimeout(seconds: 8) { try await transport.connect() }
            XCTFail("应该连不上")
        } catch StreamTransportError.connectFailed(let m) {
            XCTAssertEqual(m, "RTMP 协议错误：AMF0 嵌套过深")
        } catch {
            XCTFail("应是连接失败：\(error)")
        }
        await transport.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.connectApps, ["live"], "只有我们的最小客户端连过，没有退回 HaishinKit")
    }

    /// HaishinKit 2.2.5 自己的 RTMPConnection.connect 遇到深嵌套的回复（不带账号的地址直接走它）：探针 1000 层就 SIGBUS——
    /// 它的 AMF0Serializer.deserialize 递归无上限（RTMPMessage.swift 的命令解析第四个值起走通用递归）。要改 HaishinKit（W4-B），本会话不做。
    /// 设 SWITCHER_PROBE_HK_AMF=1 才跑：没修之前会把整个测试进程打崩（单独跑：--filter AMF0LimitTests/testNS04_haishinKitOwnParser_deepReply）。
    func testNS04_haishinKitOwnParser_deepReply() async throws {
        guard ProcessInfo.processInfo.environment["SWITCHER_PROBE_HK_AMF"] == "1" else {
            throw XCTSkip("BLOCKED-SDK：HaishinKit 2.2.5 的 AMF0 解析递归无上限（reports/issues/W2D5-w4-release-haishinkit-amf0-unbounded-recursion.md），修了再去掉这一行")
        }
        let s = try server(19476, reply: HostileRTMPServer.deepResult(depth: 100_000))
        let connection = RTMPConnection(timeout: 5)
        _ = try? await connection.connect("rtmp://127.0.0.1:\(s.port)/s1")
        try? await connection.close()
        XCTAssertEqual(s.connectApps, ["s1"], "进程还在")
    }
}
