// W2-B2 接缝 5：录制按钮 → Recorder（W1-E）。录 5 s：ffprobe 无错、两轨、视频时长 = 起止拍差（精确）、起止拍差 = 按钮间隔 ± 1 帧
// （起点 = 按下后第 3 拍、终点 = 按下后第 3 拍，两头相互抵消），两轨时长差 ≤ 20 ms（E5 口径），停止后按钮回"录制"。
import AppKit
import XCTest
import SwitcherContracts
@testable import Switcher

@MainActor
final class RecordingTests: XCTestCase {
    func testRecord_5sTwoTracksDurationExact() throws {
        try AppTest.requireFFprobe()
        let session = try AppTest.freshSession()
        let wc = AppTest.controller.windowController
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        AppTest.pump(seconds: 1.5)   // 音频对齐、第一行 Stats
        XCTAssertEqual(wc.bottomBar.recordButton.title, "录制")

        let clickStart = Date()
        wc.bottomBar.recordButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(3) { wc.bottomBar.recordButton.title == "● 录制中" }, "应显示录制中：\(wc.bottomBar.recordButton.title)")
        XCTAssertNotNil(session.outputs.recorders[1], "录制器应在跑")
        while Date().timeIntervalSince(clickStart) < 5 { AppTest.pump(seconds: 0.005) }
        let clickStop = Date()
        wc.bottomBar.recordButton.performClick(nil)
        XCTAssertTrue(AppTest.waitUntil(15) { wc.bottomBar.recordButton.title == "录制" && session.outputs.lastResults[1] != nil },
                      "封口后按钮应回「录制」：\(wc.bottomBar.recordButton.title)")
        let result = try XCTUnwrap(session.outputs.lastResults[1])
        let ticks = Int(result.stopTick.rawValue - result.start.tick.rawValue)
        let interval = clickStop.timeIntervalSince(clickStart)
        print("录制：\(result.url.path)，起 \(result.start.tick) 止 \(result.stopTick) = \(ticks) 拍，视频 \(result.videoFrames) 帧 / 音频 \(result.audioFrames) 样本 = \(String(format: "%.4f", Double(result.audioFrames) / 48000)) s，"
              + "按钮间隔 \(String(format: "%.3f", interval)) s，编码 skipped \(result.encoder.skipped)，rec.start 花 \(String(format: "%.1f", session.outputs.lastStartCost.milliseconds)) ms")
        XCTAssertEqual(Int(result.audioFrames), ticks * 800, accuracy: 1, "音频样本数应 = 拍差 × 800（48 kHz / 60 fps），两轨同源")
        XCTAssertEqual(Int(result.videoFrames), ticks, "视频帧数应恰等于起止拍差")
        XCTAssertLessThanOrEqual(abs(Double(ticks) - interval * 60), 1.0, "起止拍差应 = 按钮间隔 ± 1 帧（实际 \(ticks) 拍 vs \(interval * 60)）")
        XCTAssertEqual(result.encoder.skipped, 0, "编码不应跳帧")

        let probe = try AppTest.ffprobeStreams(result.url)
        XCTAssertEqual(probe.errors, "", "ffprobe 应无错")
        XCTAssertEqual(probe.streams.count, 2, "应有两轨：\(probe.streams)")
        let video = try XCTUnwrap(probe.streams.first { $0.type == "video" })
        let audio = try XCTUnwrap(probe.streams.first { $0.type == "audio" })
        print("ffprobe：视频 \(video.duration) s / \(video.frames ?? -1) 帧，音频 \(audio.duration) s")
        XCTAssertEqual(video.frames, ticks, "ffprobe 视频帧数")
        XCTAssertEqual(video.duration, Double(ticks) / 60, accuracy: 1.0 / 60, "视频时长 = 拍差 / 60")
        XCTAssertEqual(audio.duration, video.duration, accuracy: 0.020, "两轨时长差 ≤ 20 ms（E5 口径）")
        XCTAssertNil(session.outputs.recorders[1], "封口后运行表里没有它")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }
}

@MainActor
final class RecordingShutdownTests: XCTestCase {
    /// 录着的时候换节目（= 退出时的路径）：session.stop 里录制器封口完成，文件是好的，没有"封口后按 enabled 再起一次"。
    func testRecord_stopSessionWhileRecordingFinalizesFile() throws {
        try AppTest.requireFFprobe()
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        session.send(.setProgram(input: 1))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 5), .live)
        AppTest.pump(seconds: 1)
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { session.outputs.recorders[1] != nil })
        AppTest.pump(seconds: 1.5)
        let began = Date()
        let done = AppTest.expectationBox()
        Task { await AppTest.controller.newShow(); done.value = true }
        XCTAssertTrue(AppTest.waitUntil(20) { done.value && AppTest.controller.session?.isRunning == true }, "换节目应完成")
        let took = Date().timeIntervalSince(began)
        let result = try XCTUnwrap(session.outputs.lastResults[1], "旧 session 的录制应封口完成")
        XCTAssertTrue(session.outputs.recorders.isEmpty, "封口后不能再起一次")
        XCTAssertFalse(session.isRunning)
        let probe = try AppTest.ffprobeStreams(result.url)
        print("录着换节目：用时 \(String(format: "%.2f", took)) s，\(result.videoFrames) 帧 / \(result.audioFrames) 样本，ffprobe \(probe.streams.map { "\($0.type) \($0.duration)" })")
        XCTAssertEqual(probe.errors, "")
        XCTAssertEqual(probe.streams.count, 2)
        XCTAssertGreaterThanOrEqual(result.videoFrames, 60)
        XCTAssertEqual(Int(result.audioFrames), Int(result.videoFrames) * 800, accuracy: 1)
        XCTAssertLessThan(took, 5, "换节目不该被封口拖太久")
    }
}
