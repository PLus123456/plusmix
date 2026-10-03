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
            XCTAssertEqual(number(after: "渲染 ", in: entry.text).map { abs($0 - line.renderMs) < 0.006 }, true, "render_ms：显示 \(entry.text) vs 文件 \(line.renderMs)")
            XCTAssertEqual(number(after: "丢帧 ", in: entry.text), Double(line.missedRender), "missed_render")
            XCTAssertEqual(number(after: "GPU ", in: entry.text).map { abs($0 - line.gpuPct.rounded()) < 0.5 }, true, "gpu_pct")
            XCTAssertEqual(number(after: "CPU ", in: entry.text).map { abs($0 - line.cpuPct.rounded()) < 0.5 }, true, "cpu_pct")
            if i > 0, let fps = number(after: "帧率 ", in: entry.text) {
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

    /// 纯函数部分：字段顺序、格式、没有编码器在跑时的 —、磁盘剩余（P2 的 disk_free_mb）。
    func testStatus_formatterFields() {
        let a = Stats(ts: 100, tick: Tick(600), renderMs: 1.2345, missedRender: 3, jitterMs: 0.1, perInput: [:], encoder: [],
                      audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        // 第一项是没在录的录制输出（idle，但报了所在卷的剩余），第二项是在录的
        let b = Stats(ts: 101, tick: Tick(660), renderMs: 2, missedRender: 3, jitterMs: 0.1, perInput: [:],
                      encoder: [Stats.EncoderEntry(skipped: 9, bitrate: 0, diskFreeMb: 123_456, state: "idle"),
                                Stats.EncoderEntry(skipped: 2, bitrate: 6_000_000, frames: 60, state: "recording")],
                      audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        let fields = StatusLineFormatter.fields(current: b, previous: a, format: .hd1080p60)
        // W5-F（E9 / V-22）：字段名统一走本地化表（原来"fps / render"是英文），节目格式写短"1080p60"（原来"1920×1080 60"）
        XCTAssertEqual(fields.map(\.label), ["节目", "帧率", "渲染", "GPU", "CPU", "丢帧", "编码跳帧", "码率", "磁盘"])
        XCTAssertEqual(fields.map(\.value), ["1080p60", "60.0", "2.00 ms", "27%", "12%", "3", "2", "6.00 Mb/s", "120.6 GB"])
        let first = StatusLineFormatter.fields(current: a, previous: nil, format: .hd1080p60)
        XCTAssertEqual(first[1].value, "—", "第一行没有上一行，fps 显示 —")
        XCTAssertEqual(first[6].value, "—", "没有编码器时显示 —")
        XCTAssertEqual(StatusLineFormatter.line(current: a, previous: nil, format: .hd1080p60),
                       "节目 1080p60  ·  帧率 —  ·  渲染 1.23 ms  ·  GPU 27%  ·  CPU 12%  ·  丢帧 3  ·  编码跳帧 —  ·  码率 —  ·  磁盘 —")
        // 只有 idle 的录制输出：编码字段 —，磁盘照报
        let idle = Stats(ts: 102, tick: Tick(720), renderMs: 2, missedRender: 3, jitterMs: 0.1, perInput: [:],
                         encoder: [Stats.EncoderEntry(skipped: 0, bitrate: 0, diskFreeMb: 512, state: "idle")],
                         audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        XCTAssertEqual(StatusLineFormatter.fields(current: idle, previous: b, format: .hd1080p60).map(\.value).suffix(3), ["—", "—", "512 MB"])

        // W3-E3：NDI 发送进了 encoder[]（码率 = UYVY 原始码率）。给了输出类型时先找录制 / 推流，NDI 排在前面也不顶掉它们；
        // 只有 NDI 在发时才显示 NDI 的；unavailable（没有 SDK）不算在跑。W3-E5 起类型按每项的 output 编号查（[编号: 类型]），见 testW3E5_statusLinePicksEncoderByOutputNumber
        let ndiFirst = Stats(ts: 103, tick: Tick(780), renderMs: 2, missedRender: 3, jitterMs: 0.1, perInput: [:],
                             encoder: [Stats.EncoderEntry(output: 1, skipped: 1, bitrate: 1_990_000_000, frames: 60, dropped: 1, state: "publishing"),
                                       Stats.EncoderEntry(output: 2, skipped: 2, bitrate: 6_000_000, frames: 60, state: "recording")],
                             audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 12.4, gpuPct: 26.6)
        XCTAssertEqual(StatusLineFormatter.fields(current: ndiFirst, previous: b, format: .hd1080p60, kinds: [1: .ndi, 2: .record]).map(\.value)[6...7], ["2", "6.00 Mb/s"])
        XCTAssertEqual(StatusLineFormatter.fields(current: ndiFirst, previous: b, format: .hd1080p60).map(\.value)[6...7], ["1", "1990.00 Mb/s"], "不给类型 = 旧行为")
        XCTAssertEqual(StatusLineFormatter.fields(current: ndiFirst, previous: b, format: .hd1080p60, kinds: [1: .ndi]).map(\.value)[6...7], ["1", "1990.00 Mb/s"],
                       "表里没有录制 / 推流的编号 = 退到第一个在跑的")
        var onlyNDI = ndiFirst
        onlyNDI.encoder[1].state = "idle"
        XCTAssertEqual(StatusLineFormatter.fields(current: onlyNDI, previous: b, format: .hd1080p60, kinds: [1: .ndi, 2: .record]).map(\.value)[6...7], ["1", "1990.00 Mb/s"],
                       "只有 NDI 在发：显示它")
        onlyNDI.encoder[0].state = "unavailable"
        XCTAssertEqual(StatusLineFormatter.fields(current: onlyNDI, previous: b, format: .hd1080p60, kinds: [1: .ndi, 2: .record]).map(\.value)[6...7], ["—", "—"],
                       "unavailable 不算在跑")
    }

    /// W3-E5 交付 2：底栏"编码跳帧 / 码率"按 `Stats.encoder[].output` 查 `state.outputs` 的 kind 对号（提案 019），不再按顺序：
    /// 一行顺序颠倒的 Stats（NDI 的项排最前、录制的在后）也显示录制 / 推流的码率，不是 NDI 的原始码率（按顺序对号会把第 0 项当成输出 1 = 录制）。
    func testW3E5_statusLinePicksEncoderByOutputNumber() {
        let previous = Stats(ts: 100, tick: Tick(600), renderMs: 1, missedRender: 0, jitterMs: 0.1, perInput: [:], encoder: [],
                             audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 10, gpuPct: 20)
        func stats(_ encoder: [Stats.EncoderEntry]) -> Stats {
            Stats(ts: 101, tick: Tick(660), renderMs: 1, missedRender: 0, jitterMs: 0.1, perInput: [:], encoder: encoder,
                  audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 100, cpuPct: 10, gpuPct: 20)
        }
        func shown(_ s: Stats, _ kinds: [Int: OutputKind]?) -> [String] {
            Array(StatusLineFormatter.fields(current: s, previous: previous, format: .hd1080p60, kinds: kinds).map(\.value)[6...7])
        }
        // 输出表：1 录制、2 推流、3 NDI
        let kinds: [Int: OutputKind] = [1: .record, 2: .stream, 3: .ndi]
        let ndi = Stats.EncoderEntry(output: 3, skipped: 1, bitrate: 1_990_000_000, frames: 60, dropped: 1, state: "publishing")
        let record = Stats.EncoderEntry(output: 1, skipped: 2, bitrate: 6_000_000, frames: 60, diskFreeMb: 2048, state: "recording")
        let stream = Stats.EncoderEntry(output: 2, skipped: 4, bitrate: 4_000_000, frames: 60, state: "publishing")
        var idleStream = stream
        idleStream.state = "idle"
        idleStream.bitrate = 0
        var idleRecord = record
        idleRecord.state = "idle"
        idleRecord.bitrate = 0

        // 顺序颠倒 [NDI, 录制, 推流(没开)] → 录制的
        XCTAssertEqual(StatusLineFormatter.activeEncoder(in: stats([ndi, record, idleStream]), kinds: kinds)?.output, 1)
        XCTAssertEqual(shown(stats([ndi, record, idleStream]), kinds), ["2", "6.00 Mb/s"])
        // 录制 / 推流都在跑：Stats 里先出现的那个
        XCTAssertEqual(shown(stats([ndi, stream, record]), kinds), ["4", "4.00 Mb/s"])
        XCTAssertEqual(shown(stats([record, ndi, stream]), kinds), ["2", "6.00 Mb/s"])
        // 只有 NDI 在发：显示它；谁都不在跑：—
        XCTAssertEqual(shown(stats([ndi, idleRecord, idleStream]), kinds), ["1", "1990.00 Mb/s"])
        XCTAssertEqual(shown(stats([idleRecord, ndi, idleStream]), kinds), ["1", "1990.00 Mb/s"])
        XCTAssertEqual(shown(stats([idleRecord, idleStream]), kinds), ["—", "—"])
        // 不给类型 = 不分类型：第一个在跑的
        XCTAssertEqual(shown(stats([ndi, record, idleStream]), nil), ["1", "1990.00 Mb/s"])
        // 表里没有的编号（输出刚删、这行 Stats 还是上一秒的）不算录制 / 推流：有对得上号的录制在跑就显示录制的；都没有才退到第一个在跑的
        let stale = Stats.EncoderEntry(output: 9, skipped: 7, bitrate: 1_000, state: "recording")
        XCTAssertEqual(StatusLineFormatter.activeEncoder(in: stats([stale, record]), kinds: kinds)?.output, 1)
        XCTAssertEqual(StatusLineFormatter.activeEncoder(in: stats([stale, ndi]), kinds: kinds)?.output, 9)

        // 端到端：底栏拿快照 [录制 1, 推流 2, NDI 3] + 顺序颠倒的 Stats → 状态行显示录制的跳帧 / 码率
        let bar = BottomBarView(frame: NSRect(x: 0, y: 0, width: 1400, height: 44))
        let state = MixerState(outputs: [
            OutputState(number: 1, kind: .record, name: "录制", enabled: true),
            OutputState(number: 2, kind: .stream, name: "推流", enabled: false),
            OutputState(number: 3, kind: .ndi, name: "NDI", enabled: true),
        ])
        bar.apply(state: state)
        bar.apply(stats: previous)
        bar.apply(stats: stats([ndi, record, idleStream]))
        XCTAssertTrue(bar.statusLabel.stringValue.contains("编码跳帧 2  ·  码率 6.00 Mb/s"), "状态行：\(bar.statusLabel.stringValue)")
        bar.apply(stats: stats([ndi, idleRecord, idleStream]))
        XCTAssertTrue(bar.statusLabel.stringValue.contains("编码跳帧 1  ·  码率 1990.00 Mb/s"), "只有 NDI 在发：\(bar.statusLabel.stringValue)")
    }
}
