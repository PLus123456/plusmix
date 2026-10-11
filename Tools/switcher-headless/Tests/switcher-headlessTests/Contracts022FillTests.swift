import XCTest
import Foundation
import SwitcherContracts
import SwitcherOutputs
import SwitcherStreaming
import SwitcherNDISend
import SwitcherTestKit
@testable import switcher_headless

/// 提案 022（P5-2 落地）的填数方：录制 / 推流 / NDI 各自的 statsEntry 把 uptime_s / disconnects / last_error / attempt 带出来，
/// StatsSummary 的可选汇总与老摘要兼容，StatsWriter 把非有限的 uptime / video_delay 换 0。headless 透传（EncoderStatsSource）。
/// make test 不跑工具的用例，改这里时手跑：swift test --package-path Tools/switcher-headless --filter Contracts022FillTests
final class Contracts022FillTests: XCTestCase {
    func test022_recorderCounters_statsEntryCarriesUptimeAndLastError() {
        var c = RecorderCounters()
        c.videoFrames = 10; c.uptimeSeconds = 12.5; c.lastError = "磁盘剩余 0 字节"
        let e = c.statsEntry(previous: nil, windowSeconds: 1, state: "failed", output: 3)
        XCTAssertEqual(e.output, 3); XCTAssertEqual(e.frames, 10); XCTAssertEqual(e.state, "failed")
        XCTAssertEqual(e.uptimeS, 12.5); XCTAssertEqual(e.lastError, "磁盘剩余 0 字节"); XCTAssertEqual(e.disconnects, 0); XCTAssertEqual(e.attempt, 0)
        let idle = RecorderCounters().statsEntry(previous: nil, windowSeconds: 1, state: "idle")
        XCTAssertEqual(idle.uptimeS, 0); XCTAssertEqual(idle.lastError, "")
    }

    func test022_streamCounters_statsEntryDisconnectsAndAttempt() {
        var c = StreamCounters()
        c.disconnects = 3
        c.state = .connecting(attempt: 2)
        var e = c.statsEntry(previous: nil, windowSeconds: 1, encoderSkipped: 0)
        XCTAssertEqual(e.disconnects, 3); XCTAssertEqual(e.attempt, 2); XCTAssertEqual(e.state, "connecting")
        c.state = .backoff(attempt: 2, seconds: 4)
        e = c.statsEntry(previous: nil, windowSeconds: 1, encoderSkipped: 0)
        XCTAssertEqual(e.attempt, 3, "退避期间 = 即将进行的那一次（failures + 1），与 App 底栏的读法一致")
        for s in [StreamState.publishing, .idle, .stopped, .stopping, .failed("x")] {
            c.state = s
            XCTAssertEqual(c.statsEntry(previous: nil, windowSeconds: 1, encoderSkipped: 0).attempt, 0, "\(s)：在推 / 空闲 / 停止 / failed = 0")
        }
    }

    func test022_ndiSendCounters_uptimeOnlyWhilePublishing_andLastError() {
        var c = NDISendCounters()
        c.unavailable = false; c.startedAt = HostClock.now(); c.lastError = ""
        let e = c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100, running: true)
        XCTAssertEqual(e.state, "publishing"); XCTAssertGreaterThanOrEqual(e.uptimeS, 0); XCTAssertLessThan(e.uptimeS, 60); XCTAssertEqual(e.lastError, "")
        c.startFailed = true; c.lastError = "NDIlib_initialize 失败"
        let f = c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100, running: false)
        XCTAssertEqual(f.state, "failed"); XCTAssertEqual(f.uptimeS, 0); XCTAssertEqual(f.lastError, "NDIlib_initialize 失败")
        c.startFailed = false; c.unavailable = true; c.lastError = "NDI SDK 不在（编译时没探测到）"
        let u = c.statsEntry(previous: nil, windowSeconds: 1, bytesPerFrame: 100, running: true)
        XCTAssertEqual(u.state, "unavailable"); XCTAssertEqual(u.uptimeS, 0); XCTAssertEqual(u.lastError, "NDI SDK 不在（编译时没探测到）")
        XCTAssertNil(NDISendCounters().startedAt, "没起过 = nil")
    }

    /// 干跑起一次 NDISender：有 SDK 时 publishing 且 uptime 从 start 算、last_error 空；没 SDK 时 unavailable、uptime 0、last_error 写明 SDK 不在。
    func test022_ndiSender_dryRunStart_setsUptimeAndLastError() throws {
        let s = NDISender(configuration: .init(name: "p5-2-022", format: .hd720p60, conversion: .cpu, dryRun: true))
        try s.start()
        defer { s.stop() }
        let e = s.statsEntry(previous: nil, windowSeconds: 1)
        if NDISender.isAvailable {
            XCTAssertEqual(e.state, "publishing"); XCTAssertGreaterThanOrEqual(e.uptimeS, 0); XCTAssertLessThan(e.uptimeS, 60); XCTAssertEqual(e.lastError, "")
        } else {
            XCTAssertEqual(e.state, "unavailable"); XCTAssertEqual(e.uptimeS, 0); XCTAssertEqual(e.lastError, "NDI SDK 不在（编译时没探测到）")
        }
        XCTAssertNotNil(s.countersSnapshot.startedAt)
    }

    func test022_statsSummary_deliveryNewFieldsAndVideoDelay_oldSummaryDecodes_writerSanitizes() throws {
        func line(_ i: Int, uptime: Double, disc: UInt64, err: String, attempt: Int, delay: Double) -> Stats {
            Stats(ts: 1000 + Double(i), tick: Tick(Int64(i) * 60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:],
                  encoder: [Stats.EncoderEntry(output: 2, skipped: 0, bitrate: 1, state: "publishing", uptimeS: uptime, disconnects: disc, lastError: err, attempt: attempt)],
                  audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 0, videoDelayMs: delay)
        }
        let s = StatsSummary(lines: [line(0, uptime: 1, disc: 0, err: "", attempt: 0, delay: 0),
                                     line(1, uptime: 2, disc: 1, err: "断线：stalled", attempt: 2, delay: 30.1),
                                     line(2, uptime: 3, disc: 1, err: "", attempt: 0, delay: 12)])
        let d = try XCTUnwrap(s.encoders[0].delivery)
        XCTAssertEqual(d.uptimeS, 3, "末行")
        XCTAssertEqual(d.disconnects, 1, "末行 − 首行")
        XCTAssertEqual(d.lastError, "断线：stalled", "最后一个非空")
        XCTAssertEqual(d.lastAttempt, 0, "末行")
        let v = try XCTUnwrap(s.videoDelayMs)
        XCTAssertEqual(v.count, 3); XCTAssertEqual(v.min, 0); XCTAssertEqual(v.max, 30.1)
        XCTAssertEqual(try JSONDecoder().decode(StatsSummary.self, from: try JSONEncoder().encode(s)), s)
        // 022 之前的摘要（基线）没有这些键 → nil
        var old = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as! [String: Any]
        old["videoDelayMs"] = nil
        old["encoders"] = (old["encoders"] as! [[String: Any]]).map { e -> [String: Any] in
            var e = e
            var delivery = e["delivery"] as! [String: Any]
            for k in ["uptimeS", "disconnects", "lastError", "lastAttempt"] { delivery[k] = nil }
            e["delivery"] = delivery
            return e
        }
        let back = try JSONDecoder().decode(StatsSummary.self, from: try JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(back.videoDelayMs)
        XCTAssertNil(back.encoders[0].delivery?.uptimeS); XCTAssertNil(back.encoders[0].delivery?.lastError)
        XCTAssertEqual(back.encoders[0].delivery?.frames, s.encoders[0].delivery?.frames)
        // 没有 encoder 的空行也有 videoDelayMs 序列；空文件 nil
        XCTAssertNil(StatsSummary(lines: []).videoDelayMs)
        // StatsWriter：非有限的 uptime_s / video_delay_ms 换 0，整行仍能写出
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p5-2-022-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StatsWriter(url: url, append: false)
        writer.submit(line(3, uptime: .nan, disc: 0, err: "", attempt: 0, delay: .infinity))
        writer.close()
        XCTAssertEqual(writer.sanitizedLines, 1)
        let parsed = try Stats.parse(lines: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].encoder[0].uptimeS, 0); XCTAssertEqual(parsed[0].videoDelayMs, 0)
    }
}
