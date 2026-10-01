// W2-B2 接缝 6：推流按钮 → StreamOutput（W2-D，HaishinKitTransportFactory）。推到本地 MediaMTX 10 s → 落盘帧号连续（frameprobe stats）。
// 需要 brew 的 mediamtx / ffprobe 和编好的 release frameprobe，没有就 XCTSkip（BLOCKED-工具）。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class StreamWiringTests: XCTestCase {
    func testStream_10sToLocalMediaMTX_framesContinuous() throws {
        try MediaMTXHarness.requireAvailable()
        try AppTest.requireFFprobe()
        let frameprobe = try AppTest.frameprobe()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-tests/stream-e2e", isDirectory: true)
        let mtx = try MediaMTXHarness(recordDir: dir)
        defer { mtx.stop() }

        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        XCTAssertFalse(wc.bottomBar.streamButton.isEnabled, "没有推流输出时置灰")
        let output = OutputState(number: 2, kind: .stream, name: "推流", enabled: false,
                                 settings: OutputSettings(source: .program, video: VideoEncodeSettings(), audio: AudioEncodeSettings(),
                                                          stream: StreamSettings(url: mtx.rtmpURL("s1"))))
        session.send(.addOutput(config: output))
        XCTAssertTrue(AppTest.waitUntil(2) { wc.bottomBar.streamButton.isEnabled }, "加了推流输出后按钮可用")
        AppTest.pump(seconds: 1.2)

        var notices: [String] = []
        let token = session.observeNotices { notices.append($0) }
        defer { token.invalidate() }
        wc.bottomBar.streamButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.outputs.first { $0.kind == .stream }?.enabled == true }, "按钮应发 startStream")
        XCTAssertTrue(AppTest.waitUntil(12) { wc.bottomBar.streamButton.title == "● 推流中" }, "应连上并显示推流中：\(wc.bottomBar.streamButton.title)")
        // W5-B（X37）：起的时候提示"连接中"，连上（Stats 报 publishing）之后才提示"已开始"
        XCTAssertTrue(AppTest.waitUntil(3) { notices.contains("推流 2 已开始") }, "\(notices)")
        XCTAssertEqual(notices.filter { $0.hasPrefix("推流 2") }.prefix(2), ["推流 2 连接中…", "推流 2 已开始"])
        AppTest.pump(seconds: 10)
        let entry = wc.bottomBar.encoderEntry(forOutput: 2)
        print("推流 10 s 时 Stats.encoder：\(String(describing: entry))")
        wc.bottomBar.streamButton.performClick(nil)
        XCTAssertEqual(AppTest.waitForConfirmation(.stopStream)?.request.title, "确定停止推流（1 路）？", "停止前先确认（W5-B）")
        AppTest.answer(.confirm)
        XCTAssertTrue(AppTest.waitUntil(15) { wc.bottomBar.streamButton.title == "推流" && session.outputs.streams[2] == nil },
                      "停止后按钮应回「推流」：\(wc.bottomBar.streamButton.title)")
        let stopped = wc.bottomBar.encoderEntry(forOutput: 2)
        XCTAssertEqual(entry?.state, "publishing")
        XCTAssertGreaterThanOrEqual(entry?.frames ?? 0, 500, "10 s 应送出约 600 帧")
        XCTAssertEqual(entry?.dropped, 0, "本机回环不应有网络丢帧")
        XCTAssertEqual(entry?.skipped, 0, "编码不应跳帧")
        print("停止后 Stats.encoder：\(String(describing: stopped))")

        // MediaMTX 落盘（发布者断开后关段）：frameprobe stats 帧号连续
        mtx.stop()
        var files: [URL] = []
        XCTAssertTrue(AppTest.waitUntil(10) { files = mtx.recordings("s1"); return !files.isEmpty }, "MediaMTX 应落盘 s1")
        guard let file = files.first else { return }
        let o = try AppTest.run(frameprobe.path, ["stats", file.path, "--fps", "60"])
        guard let obj = try? JSONSerialization.jsonObject(with: o.stdout) as? [String: Any], let st = obj["stats"] as? [String: Any] else {
            XCTFail("frameprobe stats 没有 JSON：\(o.stderr.prefix(500))")
            return
        }
        let inputs = st["inputs"] as? [[String: Any]] ?? []
        let dropped = inputs.reduce(0) { $0 + ($1["droppedFrames"] as? Int ?? 0) }
        let dup = inputs.reduce(0) { $0 + ($1["duplicateFrames"] as? Int ?? 0) }
        let gaps = inputs.reduce(0) { $0 + (($1["dropGaps"] as? [Any])?.count ?? 0) }
        let total = st["totalFrames"] as? Int ?? 0
        let undecodable = st["undecodableFrames"] as? Int ?? 0
        print("frameprobe stats：\(file.lastPathComponent) 共 \(total) 帧，丢 \(dropped)（缺口 \(gaps)），重复 \(dup)，解不出 \(undecodable)")
        XCTAssertGreaterThanOrEqual(total, 550, "10 s 应落盘 ≈ 600 帧")
        XCTAssertEqual(gaps, 0, "帧号应连续")
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(undecodable, 0)
        XCTAssertEqual(dup, 0, "60 fps 合成源 → 60 fps 节目不该有重复帧")
    }
}
