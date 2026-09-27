// W3-E4 交付第 4 条（提案 019 的 App 读法与文案；契约与包内填数 G4 已落地）：
// - Stats.encoder 的每一项带输出编号 `output`（OutputRuntime 三处 statsEntry 与两种 idle 项都填），`OutputRuntime.encoderEntry` 按它对号，
//   不再按"与 outputs 里带编码器的输出同序"（两次采样之间输出表变了会错一拍，W3-E3 报告 §4 第 2 条）；
// - NDI 页的状态行显示接收方数 `connections`；
// - state = failed（SDK 在但 initialize / send_create 失败）与 unavailable（SDK 不在）的文案分开：一个说装 SDK、一个说看日志，两种语言各一键。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class EncoderStatsLookupTests: XCTestCase {
    private func stats(_ encoder: [Stats.EncoderEntry]) -> Stats {
        Stats(ts: 1, tick: Tick(60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: encoder,
              audio: Stats.AudioCounters(dropouts: 0, underruns: 0), rssMb: 1, cpuPct: 1, gpuPct: 1)
    }

    func testW3E4_4_encoderEntriesCarryOutputNumber_lookupByOutput_ndiConnectionsAndFailedText() throws {
        // 1. 纯函数：按 output 对号。一行过期的 Stats（输出 1 刚删、encoder 里还有它那一项）配新的输出表 [2, 3]：
        //    老算法把输出 2 对到第 0 项（输出 1 的），新算法拿到 output == 2 的那一项
        let e1 = Stats.EncoderEntry(output: 1, skipped: 0, bitrate: 0, diskFreeMb: 100, state: "idle")
        let e2 = Stats.EncoderEntry(output: 2, skipped: 3, bitrate: 6_000_000, frames: 600, state: "publishing")
        let e3 = Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 0, state: "idle")
        XCTAssertEqual(OutputRuntime.encoderEntry([e1, e2, e3], forOutput: 2), e2)
        XCTAssertEqual(OutputRuntime.encoderEntry([e1, e2, e3], forOutput: 1), e1)
        XCTAssertNil(OutputRuntime.encoderEntry([e2, e3], forOutput: 1), "删掉的输出对不到任何项")
        XCTAssertEqual(OutputRuntime.encoderEntry(in: stats([e1, e2, e3]), forOutput: 3), e3)

        // 2. 活的：默认节目有录制输出（idle，报所在卷的剩余）；加推流与 NDI（都不开）→ encoder 三项 output = 各自的编号、state idle；
        //    删掉录制输出 → 下一行只剩两项；删之前那一行（过期的）按 output 对推流仍拿到它自己的项
        let session = try AppTest.freshSession()
        let record = try XCTUnwrap(session.state.outputs.first { $0.kind == .record }?.number)
        let page = AppTest.controller.panels.showOutputSettings(tab: .stream).model
        let streamNumber = page.addStream(url: "rtmp://127.0.0.1/live", key: "k")
        let ndiNumber = page.nextOutputNumber()
        session.send(.addOutput(config: OutputState(number: ndiNumber, kind: .ndi, name: "NDI", enabled: false,
                                                    settings: OutputSettings(source: .program, extra: [OutputExtras.ndiConversion: .string("auto")]))))
        XCTAssertTrue(AppTest.waitUntil(4) { session.stats?.encoder.map(\.output) == [record, streamNumber, ndiNumber] },
                      "encoder 三项按输出表顺序、各带自己的编号：\(String(describing: session.stats?.encoder))")
        let before = try XCTUnwrap(session.stats)
        XCTAssertEqual(before.encoder.map(\.state), ["idle", "idle", "idle"])
        XCTAssertGreaterThan(try XCTUnwrap(OutputRuntime.encoderEntry(in: before, forOutput: record)).diskFreeMb, 0, "没在录的录制输出报所在卷的剩余")
        XCTAssertEqual(OutputRuntime.encoderEntry(in: before, forOutput: streamNumber)?.diskFreeMb, 0)
        session.send(.removeOutput(output: record))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(record) == nil })
        XCTAssertEqual(OutputRuntime.encoderEntry(in: before, forOutput: streamNumber)?.output, streamNumber, "过期那一行按编号对，不会错一拍")
        XCTAssertTrue(AppTest.waitUntil(4) { session.stats?.encoder.map(\.output) == [streamNumber, ndiNumber] }, "\(String(describing: session.stats?.encoder))")
        page.removeOutput(streamNumber)
        page.removeOutput(ndiNumber)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.isEmpty })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()

        // 3. NDI 页状态行显示接收方数：给模型一行 Stats，encoder 顺序与输出表不同也按 output 对上（铁律 4：只读 Stats）
        var show = ShowDocuments.emptyShow()
        show.outputs.append(OutputState(number: 3, kind: .ndi, name: "NDI", enabled: true,
                                        settings: OutputSettings(source: .program, extra: [OutputExtras.ndiConversion: .string("auto")])))
        let model = OutputSettingsModel(state: show.makeState(), tab: .ndi, defaultRecordDirectory: "/tmp", showName: "t", queriesSystemExtensions: false)
        let publishing = Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 1.99e9, frames: 1200, dropped: 0, connections: 2, state: "publishing")
        model.apply(stats: stats([publishing, e1]))   // NDI 排在录制前面：顺序与输出表对不上，照样按编号
        XCTAssertEqual(model.ndiStatus(output: 3), OutputStatusText.ndi(enabled: true, entry: publishing))
        XCTAssertEqual(model.ndiStatus(output: 3), "发送中 · 1200 帧 · 接收方 2")
        model.apply(stats: stats([Stats.EncoderEntry(output: 3, skipped: 1, bitrate: 1.99e9, frames: 1300, dropped: 1, connections: 0, state: "publishing")]))
        XCTAssertEqual(model.ndiStatus(output: 3), "发送中 · 1300 帧 · 接收方 0（队列丢 1）")

        // 4. failed 与 unavailable 分开、两种语言各一键；NDI 的四个 state 都有文案（不是原样回显 state），英文没有中文
        let states = ["publishing", "idle", "unavailable", "failed"]
        let cjk = try NSRegularExpression(pattern: #"[一-鿿　-〿！-～]"#)
        for lang in L10n.supportedLanguages {
            L10n.languageOverride = lang
            defer { L10n.languageOverride = "zh-Hans" }
            let texts = states.map { OutputStatusText.ndi(enabled: true, entry: Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 0, frames: 5, connections: 1, state: $0)) }
            for (s, t) in zip(states, texts) {
                XCTAssertNotEqual(t, s, "\(lang)：state \(s) 应有文案")
                XCTAssertFalse(t.hasPrefix("ndi."), "\(lang)：缺键 \(t)")
            }
            XCTAssertEqual(Set(texts).count, texts.count, "\(lang)：四种 state 的文案各不相同：\(texts)")
            let unavailable = texts[2], failed = texts[3]
            if lang == "en" {
                for t in texts { XCTAssertNil(cjk.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), "英文文案里有中文：\(t)") }
                XCTAssertTrue(unavailable.lowercased().contains("install") && unavailable.contains("SDK"), "unavailable = 装 SDK：\(unavailable)")
                XCTAssertTrue(failed.lowercased().contains("log") && !failed.lowercased().contains("install"), "failed = 看日志：\(failed)")
            } else {
                XCTAssertTrue(unavailable.contains("装") && unavailable.contains("SDK"), "unavailable = 装 SDK：\(unavailable)")
                XCTAssertTrue(failed.contains("日志") && !failed.contains("装"), "failed = 看日志：\(failed)")
            }
        }
        print("019（App）：encoder 按 output 对号；NDI 页状态行「\(model.ndiStatus(output: 3))」；failed「\(OutputStatusText.ndi(enabled: true, entry: Stats.EncoderEntry(output: 3, skipped: 0, bitrate: 0, state: "failed")))」")
    }
}
