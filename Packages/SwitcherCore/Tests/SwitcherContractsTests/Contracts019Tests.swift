import XCTest
@testable import SwitcherContracts

/// 提案 019（用户 2026-09-27 批，G4 续做合入会话落地）：`Stats.EncoderEntry` 加 `output`（输出编号，与 display[] 同口径）与 `connections`（NDI 接收方数）；
/// NDI 的 state 多一个 failed（值表在注释与 CONTRACTS.md §2.7；这里只核键与缺键）。
final class Contracts019Tests: XCTestCase {
    func test019_encoderEntryOutputAndConnectionsRoundTrip_missingKeysDecodeToZero() throws {
        let e = Stats.EncoderEntry(output: 3, skipped: 1, bitrate: 1_990_000_000, frames: 160, dropped: 0, diskFreeMb: 0, reconnects: 0, connections: 2, state: "publishing")
        let line = String(decoding: try Stats.lineEncoder.encode(e), as: UTF8.self)
        XCTAssertEqual(line, #"{"bitrate":1990000000,"connections":2,"disk_free_mb":0,"dropped":0,"frames":160,"output":3,"reconnects":0,"skipped":1,"state":"publishing"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.EncoderEntry.self, from: Data(line.utf8)), e)

        // 019 之前的文件：没有 output / connections → 0，其余照解（老写法 `EncoderEntry(skipped:bitrate:)` 也是 0）
        let legacy = try JSONDecoder().decode(Stats.EncoderEntry.self,
                                              from: Data(#"{"bitrate":6000000,"disk_free_mb":40960.5,"dropped":0,"frames":215990,"reconnects":0,"skipped":0,"state":"recording"}"#.utf8))
        XCTAssertEqual(legacy.output, 0)
        XCTAssertEqual(legacy.connections, 0)
        XCTAssertEqual(legacy.frames, 215_990)
        XCTAssertEqual(legacy.state, "recording")
        XCTAssertEqual(Stats.EncoderEntry(skipped: 0, bitrate: 0), Stats.EncoderEntry(output: 0, skipped: 0, bitrate: 0, connections: 0), "默认参数 = 0")
        // P2 的最小形态照解
        XCTAssertEqual(try JSONDecoder().decode(Stats.EncoderEntry.self, from: Data(#"{"skipped":2,"bitrate":1}"#.utf8)), Stats.EncoderEntry(skipped: 2, bitrate: 1))

        // 写出总是写全：默认值也写 output / connections
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(Stats.EncoderEntry(skipped: 0, bitrate: 0)), as: UTF8.self),
                       #"{"bitrate":0,"connections":0,"disk_free_mb":0,"dropped":0,"frames":0,"output":0,"reconnects":0,"skipped":0,"state":"idle"}"#)
        XCTAssertEqual(Stats.EncoderEntry.jsonKeys, ["output", "skipped", "bitrate", "frames", "dropped", "disk_free_mb", "reconnects", "connections", "state"])
        XCTAssertEqual(Stats.EncoderEntry.jsonKeys.first, Stats.DisplayEntry.jsonKeys.first, "两个数组都以 output 开头，同口径对号")
    }
}
