// W3-C ISO 分路（App 级 A4）：节目里 PGM 录制 + 输入 1 / 2 的 ISO 路（ISO 面板的同一条路：ISORoutes.makeISOOutput → addOutput），
// 底栏录制按钮一起起停 → 三个录制器同一起始拍 / 同一边界拍；每路自己的画面 + 自己的 ISO 音轨；frameprobe av 多文件同一事件极差 ≤ 1 帧。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherISO
@testable import Switcher

@MainActor
final class ISOAppTests: XCTestCase {
    func testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame() throws {
        try AppTest.requireFFprobe()
        let frameprobe = try AppTest.frameprobe()
        // 三路合成源（1 号 60 fps、2 号 30 fps、3 号 60 fps，都带音频）放进节目文件一起起：同一个 t0，各路的闪光 / click 才是同一事件
        var show = AppTest.controller.documents.emptyShow(name: "iso-a4")
        show.inputs = [
            AppTest.syntheticConfig(number: 1, frameRate: .fps60, gray: 96, audio: true),
            AppTest.syntheticConfig(number: 2, frameRate: .fps30, gray: 128, audio: true),
            AppTest.syntheticConfig(number: 3, frameRate: .fps60, gray: 160, audio: true),
        ]
        show.mixer.program = 1
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.replaceSession(show: show); done.value = true }
        guard AppTest.waitUntil(20, { done.value && AppTest.controller.session?.isRunning == true }) else { throw XCTSkip("节目没起来") }
        let session = try XCTUnwrap(AppTest.controller.session)
        XCTAssertTrue(AppTest.waitUntil(10) { (1...3).allSatisfy { session.inputs.runtimeState(of: $0) == .live } }, "三路应 live")
        let wc = AppTest.controller.windowController

        // ISO 面板：给 1、2 号各加一路（面板控制器 + 同一函数）
        for n in [1, 2] {
            let input = try XCTUnwrap(session.state.input(n))
            session.send(.addOutput(config: ISORoutes.makeISOOutput(for: input, in: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory)))
            XCTAssertTrue(AppTest.waitUntil(3) { ISORoutes.isoRecord(in: session.state, input: n) != nil })
        }
        let records = ISORoutes.allRecords(in: session.state)
        XCTAssertEqual(records.count, 3, "PGM + 2 路 ISO")
        XCTAssertEqual(ISORoutes.isoRecord(in: session.state, input: 2)?.settings.source, .input(number: 2))
        let panel = ISOPanelController(state: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory, reserveBytes: 0)
        _ = panel.view
        XCTAssertEqual(panel.toggle(for: 1)?.state, .on)
        XCTAssertEqual(panel.toggle(for: 3)?.state, .off)
        print("ISO 面板估算：\(ISORoutes.estimateText(state: session.state, defaultDirectory: AppTest.controller.documents.recordDirectory, reserveBytes: 0))")
        AppTest.pump(seconds: 1.5)

        // 录制按钮 → 三条 startRecord 同一拍起
        wc.bottomBar.recordButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders.count == 3 }, "三路录制器都应起来：\(session.outputs.recorders.keys.sorted())")
        let starts = Set(session.outputs.recorders.values.map { $0.start.tick })
        XCTAssertEqual(starts.count, 1, "同一起始拍：\(session.outputs.recorders.mapValues { $0.start.tick })")
        XCTAssertTrue(AppTest.waitUntil(5) { wc.bottomBar.recordButton.title.hasPrefix("● 录制中") }, wc.bottomBar.recordButton.title)
        XCTAssertEqual(wc.bottomBar.recordButton.title, "● 录制中（3 路）")
        print("ISO 起：起始拍 \(starts)，rec.start 批耗时 \(String(format: "%.1f", session.outputs.lastStartCost.milliseconds)) ms")
        AppTest.pump(seconds: 8)
        wc.bottomBar.recordButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(20) { session.outputs.recorders.isEmpty && session.outputs.lastResults.count == 3 }, "三路都应封口：\(session.outputs.lastResults.keys.sorted())")
        let results = records.map { session.outputs.lastResults[$0.number]! }
        let stops = Set(results.map(\.stopTick))
        XCTAssertEqual(stops.count, 1, "同一边界拍：\(results.map(\.stopTick))")
        for (r, o) in zip(results, records) {
            let probe = try AppTest.ffprobeStreams(r.url)
            XCTAssertEqual(probe.errors, "", "\(o.name) 文件有错")
            XCTAssertEqual(probe.streams.count, 2, "\(o.name) 应有视频 + ISO 音轨")
            print("ISO 文件 \(o.name)：\(r.url.lastPathComponent) \(r.videoFrames) 帧 / \(r.audioFrames) 样本，起 \(r.start.tick) 止 \(r.stopTick)，跳帧 \(r.encoder.skipped)")
            XCTAssertEqual(Int(r.videoFrames), Int(r.stopTick - r.start.tick), "\(o.name) 帧数 = 拍差（30 fps 的路重复帧补齐）")
            XCTAssertEqual(r.encoder.skipped, 0)
        }
        XCTAssertEqual(Set(results.map(\.videoFrames)).count, 1, "各文件帧数相同")

        // frameprobe av 多文件（A4）
        let out = AppTest.outputDirectory.appendingPathComponent("iso-a4-multi.json")
        try? FileManager.default.createDirectory(at: AppTest.outputDirectory, withIntermediateDirectories: true)
        let o = try AppTest.run(frameprobe.path, ["av"] + results.map(\.url.path) + ["--fps", "60", "--out", out.path, "--markdown"])
        print(String(decoding: o.stdout, as: UTF8.self))
        guard o.code == 0, let data = try? Data(contentsOf: out), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("frameprobe av 失败：\(o.stderr.prefix(500))")
            return
        }
        let multi = (obj["multi"] as? [String: Any]) ?? obj
        let maxFlash = multi["maxFlashSpreadMs"] as? Double ?? -1
        let maxClick = multi["maxClickSpreadMs"] as? Double ?? -1
        let events = (multi["events"] as? [[String: Any]])?.count ?? 0
        print("A4（App）：\(events) 个事件，闪光极差最大 \(maxFlash) ms，click 极差最大 \(maxClick) ms；阈值 ≤ 16.67 ms，目标 ≤ 1 ms")
        XCTAssertGreaterThanOrEqual(events, 5)
        XCTAssertGreaterThanOrEqual(maxFlash, 0)
        XCTAssertLessThanOrEqual(maxFlash, 1000.0 / 60, "A4：闪光极差 ≤ 1 帧")
        XCTAssertLessThanOrEqual(maxClick, 1000.0 / 60, "A4：click 极差 ≤ 1 帧")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }
}
