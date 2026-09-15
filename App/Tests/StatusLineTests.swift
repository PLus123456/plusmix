// W2-B prompt："状态行数字与 stats.jsonl 同一秒一致"。同一个 Stats 对象一份送状态行、一份进 stats.jsonl（StatsPump），
// 这里把屏幕上的那行文字和文件里同一秒（同 ts）那一行重新格式化的结果逐字比，并用正则从显示文字里抠出数字与文件里的字段对。
// 截图（底栏）存 .build/app-test-output/status-line.png，报告引用。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class StatusLineTests: XCTestCase {
    func testStatus_lineMatchesStatsJsonlSameSecond() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        let wc = AppTest.controller.windowController
        let dir = AppTest.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("status-line-stats.jsonl")
        try session.startStatsLog(url: jsonl)

        // 每收到一行 Stats，记下状态行此刻显示的文字（与 ts 配对）
        var shown: [(ts: Double, text: String)] = []
        let token = session.observeStats { [weak wc] stats in
            guard let wc else { return }
            shown.append((stats.ts, wc.bottomBar.statusLabel.stringValue))
        }
        XCTAssertTrue(AppTest.waitUntil(8) { shown.count >= 5 }, "8 s 内应收到 5 行 Stats，收到 \(shown.count)")
        _ = AppTest.screenshot(wc.bottomBar, to: dir.appendingPathComponent("status-line.png"))
        token.invalidate()
        session.stopStatsLog()

        let lines = try Stats.parse(lines: String(contentsOf: jsonl, encoding: .utf8))
        XCTAssertGreaterThanOrEqual(lines.count, 5, "stats.jsonl 应至少 5 行")
        var compared = 0
        for (i, line) in lines.enumerated() {
            guard let entry = shown.first(where: { $0.ts == line.ts }) else { continue }
            // 1. 同一 (上一行, 这一行) 重新格式化，应与显示逐字相同
            let expected = StatusLineFormatter.line(current: line, previous: i > 0 ? lines[i - 1] : nil, format: session.format)
            XCTAssertEqual(entry.text, expected, "ts=\(line.ts) 状态行与 jsonl 重算不一致")
            // 2. 从显示文字里抠数字，对文件字段
            XCTAssertEqual(number(after: "render ", in: entry.text).map { abs($0 - line.renderMs) < 0.006 }, true, "render_ms：显示 \(entry.text) vs 文件 \(line.renderMs)")
            XCTAssertEqual(number(after: "丢帧 ", in: entry.text), Double(line.missedRender), "missed_render")
            XCTAssertEqual(number(after: "GPU ", in: entry.text).map { abs($0 - line.gpuPct.rounded()) < 0.5 }, true, "gpu_pct")
            XCTAssertEqual(number(after: "CPU ", in: entry.text).map { abs($0 - line.cpuPct.rounded()) < 0.5 }, true, "cpu_pct")
            if i > 0, let fps = number(after: "fps ", in: entry.text) {
                let expectedFPS = Double(line.tick.rawValue - lines[i - 1].tick.rawValue) / (line.ts - lines[i - 1].ts)
                XCTAssertEqual(fps, (expectedFPS * 10).rounded() / 10, accuracy: 0.11, "fps 由相邻两行 tick / ts 算")
            }
            compared += 1
            print("状态行 ts=\(line.ts)：\(entry.text)")
        }
        XCTAssertGreaterThanOrEqual(compared, 4, "至少 4 行能配上 ts；显示 \(shown.map(\.ts))，文件 \(lines.map(\.ts))")
        print("状态行对照：\(compared) 行一致；截图 \(dir.appendingPathComponent("status-line.png").path)，jsonl \(jsonl.path)")
    }

    private func number(after prefix: String, in text: String) -> Double? {
        guard let range = text.range(of: prefix) else { return nil }
        let rest = text[range.upperBound...]
        let token = rest.prefix { "0123456789.-".contains($0) }
        return Double(token)
    }

    /// 纯函数部分：字段顺序、格式、没有编码器时的 —。
    func testStatus_formatterFields() {
        let a = Stats(ts: 100, tick: Tick(600), renderMs: 1.2345, missedRender: 3, jitterMs: 0.1, perInput: [:], encoder: [],
                      audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        let b = Stats(ts: 101, tick: Tick(660), renderMs: 2, missedRender: 3, jitterMs: 0.1, perInput: [:],
                      encoder: [Stats.EncoderEntry(skipped: 2, bitrate: 6_000_000)],
                      audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        let fields = StatusLineFormatter.fields(current: b, previous: a, format: .hd1080p60)
        XCTAssertEqual(fields.map(\.label), ["节目", "fps", "render", "GPU", "CPU", "丢帧", "编码跳帧", "码率", "磁盘"])
        XCTAssertEqual(fields.map(\.value), ["1920×1080 60", "60.0", "2.00 ms", "27%", "12%", "3", "2", "6.00 Mb/s", "—"])
        let first = StatusLineFormatter.fields(current: a, previous: nil, format: .hd1080p60)
        XCTAssertEqual(first[1].value, "—", "第一行没有上一行，fps 显示 —")
        XCTAssertEqual(first[6].value, "—", "没有编码器时显示 —")
        XCTAssertEqual(StatusLineFormatter.line(current: a, previous: nil, format: .hd1080p60),
                       "节目 1920×1080 60  ·  fps —  ·  render 1.23 ms  ·  GPU 27%  ·  CPU 12%  ·  丢帧 3  ·  编码跳帧 —  ·  码率 —  ·  磁盘 —")
    }
}
