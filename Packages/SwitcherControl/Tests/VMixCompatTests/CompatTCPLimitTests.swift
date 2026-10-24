import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import VMixCompat

/// Codex 10-24 审计 NS07：兼容层 TCP 一个连接只发不带换行的字节，`pending` 无界增长（2 MiB → RSS +4.2 MiB），也没有连接数上限。
/// 修后：一行超过 `CompatTCPServer.maxLineBytes`（64 KiB）断开这条连接；同时开着的连接到 `maxConnections`（64）后新连接直接关；
/// 不加空闲超时（订阅 TALLY 的客户端本来就只收不发）。
final class CompatTCPLimitTests: XCTestCase {
    /// 超过 64 KiB 不带换行 → 断开；超过 64 KiB 带换行（一次到齐）→ 同样断开、不当成命令；刚好 64 KiB 的行照常处理；服务照常接新连接。
    func testNS07_lineOverLimit_closesConnection_serverKeepsServing() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let version = "VERSION OK \(f.server.configuration.reportedVersion)"
        let ok = try LineClient(port: f.tcpPort)
        XCTAssertEqual(try ok.readLine(), version)
        try ok.send("PING" + String(repeating: " ", count: CompatTCPServer.maxLineBytes - 4))   // 行内空白会被去掉
        XCTAssertEqual(try ok.readLine(), "PING OK PONG", "刚好 64 KiB 的行照常")

        let unterminated = try LineClient(port: f.tcpPort)
        XCTAssertEqual(try unterminated.readLine(), version)
        do { try unterminated.sendRaw(String(repeating: "A", count: CompatTCPServer.maxLineBytes + 1024)) } catch { /* 服务端已经断了：发不完也算 */ }
        XCTAssertTrue(try unterminated.waitForClose(timeout: 5), "超过 64 KiB 还没换行：断开")

        let terminated = try LineClient(port: f.tcpPort)
        XCTAssertEqual(try terminated.readLine(), version)
        do { try terminated.sendRaw(String(repeating: "B", count: CompatTCPServer.maxLineBytes + 1) + "\r\n") } catch {}
        XCTAssertTrue(try terminated.waitForClose(timeout: 5), "超长行带着换行一起到：同样断开")
        XCTAssertEqual(f.server.counters.tcpLinesTooLong, 2)

        let fresh = try LineClient(port: f.tcpPort)
        XCTAssertEqual(try fresh.readLine(), version, "服务照常接新连接")
        try fresh.send("PING")
        XCTAssertEqual(try fresh.readLine(), "PING OK PONG")
        try ok.send("TALLY")
        XCTAssertEqual(try ok.readLine(), "TALLY OK 1200", "别的连接不受影响")
    }

    /// 开满 64 条：第 65 条连得上（内核替监听 socket 接了）但服务端不发问候、直接关；已有的照常；关掉一条之后新连接照常。
    func testNS07_connectionLimit_extraConnectionClosed_slotFreedAfterClose() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let version = "VERSION OK \(f.server.configuration.reportedVersion)"
        var clients: [LineClient] = []
        defer { for c in clients { c.closeNow() } }
        for i in 0..<CompatTCPServer.maxConnections {
            let c = try LineClient(port: f.tcpPort)
            XCTAssertEqual(try c.readLine(), version, "第 \(i + 1) 条")
            clients.append(c)
        }
        XCTAssertEqual(f.server.counters.tcpConnectionsOpen, CompatTCPServer.maxConnections)
        let extra = try LineClient(port: f.tcpPort)
        XCTAssertTrue(try extra.waitForClose(timeout: 5), "满了：新连接直接关")
        XCTAssertNil(try extra.readLine(timeout: 0.1), "不发问候")
        XCTAssertEqual(f.server.counters.tcpConnectionsRefused, 1)
        try clients[0].send("PING")
        XCTAssertEqual(try clients[0].readLine(), "PING OK PONG", "已有的连接照常")

        clients.removeLast().closeNow()
        let freed = await waitUntil { f.server.counters.tcpConnectionsOpen == CompatTCPServer.maxConnections - 1 }
        XCTAssertTrue(freed, "关掉的那条记成已关")
        let next = try LineClient(port: f.tcpPort)
        XCTAssertEqual(try next.readLine(), version, "空出位子之后新连接照常")
        clients.append(next)
    }

    /// 不加空闲超时：订阅 TALLY 之后只收不发的连接，静默 2 s 照样收到推送；正常命令照旧。
    func testNS07_idleTallySubscriberStillReceivesPushes() async throws {
        let f = try await CompatFixture.start()
        defer { Task { await f.stop() } }
        let c = try LineClient(port: f.tcpPort)
        _ = try c.readLine()
        try c.send("SUBSCRIBE TALLY")
        XCTAssertEqual(try c.readLine(), "SUBSCRIBE OK TALLY")
        XCTAssertEqual(try c.readLine(), "TALLY OK 1200")
        try await Task.sleep(for: .seconds(2))
        _ = try await f.bus.submit(.cut, source: .ui)
        XCTAssertEqual(try readLine(c) { $0.hasPrefix("TALLY OK") }, "TALLY OK 2100")
        try c.send("PING")
        XCTAssertEqual(try readLine(c) { $0.hasPrefix("PING") }, "PING OK PONG")
    }
}
