import XCTest
@testable import SwitcherContracts

/// 提案 022（用户 2026-10-11 批，P5-2 落地）：`Stats.EncoderEntry` 加 `uptime_s`（本次运行时长，含重连期）/ `disconnects`（断线累计）/ `last_error`
///（最近一次错误文案，下一次 start 清；空串 = 没出过错）+ 顺带 B1 `attempt`（推流这一轮第几次尝试）与 B2 顶层 `video_delay_ms`（监听同步把视频延后的毫秒数，提案 028）。
/// 缺键 = 0 / "" / 0 / 0，写出总是写全；老 stats.jsonl 照读。
final class Contracts022Tests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func test022_encoderEntryNewFields_jsonKeysRoundTripMissingKeysAndWriteAll() throws {
        XCTAssertEqual(Stats.EncoderEntry.jsonKeys,
                       ["output", "skipped", "bitrate", "frames", "dropped", "disk_free_mb", "reconnects", "connections", "state", "uptime_s", "disconnects", "last_error", "attempt"])
        XCTAssertEqual(Stats.jsonKeys, ["ts", "tick", "render_ms", "missed_render", "jitter_ms", "per_input", "encoder", "display", "audio", "rss_mb", "cpu_pct", "gpu_pct", "video_delay_ms"])
        let e = Stats.EncoderEntry(output: 2, skipped: 1, bitrate: 2_500_000, frames: 160, dropped: 3, diskFreeMb: 0, reconnects: 2, connections: 0, state: "backoff",
                                   uptimeS: 125.5, disconnects: 3, lastError: "disconnected", attempt: 4)
        let line = String(decoding: try Stats.lineEncoder.encode(e), as: UTF8.self)
        XCTAssertEqual(line, #"{"attempt":4,"bitrate":2500000,"connections":0,"disconnects":3,"disk_free_mb":0,"dropped":3,"frames":160,"last_error":"disconnected","output":2,"reconnects":2,"skipped":1,"state":"backoff","uptime_s":125.5}"#)
        XCTAssertEqual(try JSONDecoder().decode(Stats.EncoderEntry.self, from: Data(line.utf8)), e)
        // 022 之前的行：四个键都缺 → 0 / 0 / "" / 0，其余照解
        let legacy = try JSONDecoder().decode(Stats.EncoderEntry.self,
                                              from: Data(#"{"bitrate":6000000,"connections":0,"disk_free_mb":40960.5,"dropped":0,"frames":215990,"output":1,"reconnects":0,"skipped":0,"state":"recording"}"#.utf8))
        XCTAssertEqual(legacy.uptimeS, 0)
        XCTAssertEqual(legacy.disconnects, 0)
        XCTAssertEqual(legacy.lastError, "")
        XCTAssertEqual(legacy.attempt, 0)
        XCTAssertEqual(legacy.frames, 215_990)
        // 现有调用点不改：三个参数带默认值
        XCTAssertEqual(Stats.EncoderEntry(skipped: 0, bitrate: 0), Stats.EncoderEntry(output: 0, skipped: 0, bitrate: 0, uptimeS: 0, disconnects: 0, lastError: "", attempt: 0))
        // 写出总是写全（默认值也写）
        XCTAssertEqual(String(decoding: try Stats.lineEncoder.encode(Stats.EncoderEntry(skipped: 0, bitrate: 0)), as: UTF8.self),
                       #"{"attempt":0,"bitrate":0,"connections":0,"disconnects":0,"disk_free_mb":0,"dropped":0,"frames":0,"last_error":"","output":0,"reconnects":0,"skipped":0,"state":"idle","uptime_s":0}"#)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(Stats.EncoderEntry.jsonKeys))
    }

    func test022_statsTopLevelVideoDelayMs_defaultMissingKeyAndWriteAll() throws {
        var s = Samples.stats()
        XCTAssertEqual(s.videoDelayMs, 12.5, "样例填非默认值")
        s.videoDelayMs = 0
        let line = try s.jsonLine()
        XCTAssertTrue(line.contains(#""video_delay_ms":0"#), "默认值也写：\(line)")
        // 022 之前的行没有 video_delay_ms → 0
        let old = #"{"audio":{"dropouts":0,"underruns":1},"cpu_pct":1,"encoder":[{"bitrate":6000000,"skipped":2}],"gpu_pct":0,"jitter_ms":0,"missed_render":0,"per_input":{"1":{"drop":0,"dup":3,"fps":30}},"render_ms":1,"rss_mb":1,"tick":1,"ts":1}"#
        let back = try Stats.parse(line: old)
        XCTAssertEqual(back.videoDelayMs, 0)
        XCTAssertEqual(back.encoder[0].uptimeS, 0)
        XCTAssertEqual(back.encoder[0].lastError, "")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try back.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), Set(Stats.jsonKeys))
        // 构造函数的默认值：老调用点（不给 videoDelayMs）= 0
        XCTAssertEqual(Stats(ts: 1, tick: Tick(1), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [], audio: Stats.AudioCounters(dropouts: 0, underruns: 0),
                             rssMb: 1, cpuPct: 1, gpuPct: 0).videoDelayMs, 0)
    }

    /// App 状态行用例留下的老 stats.jsonl（022 之前写的）照读，每行新字段都是默认值。
    func test022_legacyStatsJsonlStillParses() throws {
        let url = Self.repoRoot.appendingPathComponent("App/Tests/Artifacts/w2-app-status-line-stats.jsonl")
        let lines = try Stats.parse(lines: String(contentsOf: url, encoding: .utf8))
        XCTAssertFalse(lines.isEmpty)
        for l in lines {
            XCTAssertEqual(l.videoDelayMs, 0)
            for e in l.encoder {
                XCTAssertEqual(e.uptimeS, 0); XCTAssertEqual(e.disconnects, 0); XCTAssertEqual(e.lastError, ""); XCTAssertEqual(e.attempt, 0)
            }
        }
    }
}
