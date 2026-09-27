import XCTest
import SwitcherContracts
@testable import SwitcherNDISend

/// 提案 019（用户 2026-09-27 批，G4 落地）：encoder[] 的一项带输出编号 `output` 与接收方数 `connections`；
/// SDK 在但起不来 = state failed（与 SDK 不在的 unavailable 分开）。纯结构映射，不需要 SDK。
final class Stats019Tests: XCTestCase {
    func test019_ndiStatsEntryCarriesOutputConnectionsAndFailedState() {
        var c = NDISendCounters()
        c.framesSent = 120
        c.skipped = 2
        c.connections = 3
        c.unavailable = false
        let e = c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100, running: true, output: 7)
        XCTAssertEqual(e.output, 7, "组装方给的输出编号原样进 Stats")
        XCTAssertEqual(e.connections, 3, "接收方数 = NDIlib_send_get_no_connections 的值")
        XCTAssertEqual(e.state, "publishing")
        XCTAssertEqual(e.frames, 120)
        XCTAssertEqual(e.dropped, 2)
        XCTAssertEqual(e.bitrate, 120 * 100 * 8, accuracy: 1e-6, "previous 为 nil 时按 0 起算")
        XCTAssertEqual(c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100, running: false).state, "idle")
        XCTAssertEqual(c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100).output, 0, "不给编号 = 0 = 不知道")

        var unavailable = c
        unavailable.unavailable = true
        XCTAssertEqual(unavailable.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100).state, "unavailable", "SDK 不在")

        var failed = c
        failed.startFailed = true
        failed.unavailable = true   // 起失败时 counters.unavailable 也置了（老口径），Stats 里 failed 优先
        let f = failed.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100)
        XCTAssertEqual(f.state, "failed", "SDK 在、initialize / send_create 失败")
        XCTAssertEqual(f.connections, 3)

        var negative = c
        negative.connections = -1
        XCTAssertEqual(negative.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100).connections, 0, "SDK 没给（负数）当 0")

        // 新起的 sender：没起过 = 空实现 / 没 SDK 的口径不变（unavailable），startFailed 为 false
        let fresh = NDISender(configuration: NDISender.Configuration(name: "019-fresh", format: .hd1080p60, source: .program)).countersSnapshot
        XCTAssertFalse(fresh.startFailed)
        XCTAssertNotEqual(fresh.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 1).state, "failed")
    }
}
