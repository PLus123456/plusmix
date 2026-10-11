import XCTest
import Foundation
import SwitcherContracts
import SwitcherAudioIntegration
import SwitcherTestKit
@testable import switcher_headless

/// W1-B4（prompt 105 交付 5，提案 028）：`--av-compensation videoDelay|audioPTS`（默认 videoDelay），以及两种方式下录制文件的 A2。
/// 端到端用例真跑两次 headless（Metal 渲染 + VideoToolbox 录制 + 空设备混音），make test 不跑工具的用例，改这里时手跑：
///   swift test --package-path Tools/switcher-headless --filter AVCompensationTests
final class AVCompensationTests: XCTestCase {
    func testAV_headlessAVCompensationArgument() throws {
        func parse(_ args: [String]) throws -> AVCompensation {
            try HeadlessCLI.avCompensation(ParsedArguments(args, valueKeys: HeadlessCLI.valueKeys))
        }
        XCTAssertEqual(try parse(["--show", "s.json"]), .videoDelay, "默认 videoDelay")
        XCTAssertEqual(try parse(["--av-compensation", "videoDelay"]), .videoDelay)
        XCTAssertEqual(try parse(["--av-compensation", "audioPTS"]), .audioPTS)
        XCTAssertThrowsError(try parse(["--av-compensation", "both"]))
        XCTAssertEqual(RunOptions(showURL: URL(fileURLWithPath: "/tmp/x.json"), durationSeconds: 1, preview: false, audioDevice: "null",
                                  leadMs: 1000, gpuStats: false).avCompensation, .videoDelay)
    }

    /// prompt 105 的 testA2_videoDelayMode_recordingStaysAligned：M0 节目（1 号 = 30 fps 合成源带 click，在 PGM 上）、Master 限幅起音 30 ms（1440 帧），
    /// 两种补偿方式各录 12 s，frameprobe av 整秒配对 ≤ 1 ms，两种方式的均值差 ≤ 1 ms（不双重补偿）。
    /// videoDelay 那一份：开录起点按节目输出时间线（G8b 接的：RecordingStart(tick:tickTime: 拍点 + 当时的 videoDelayTarget)，提案 028 第 3 条），
    /// 视频按拍点 + 30 ms 打戳、文件时间 0 = 拍点 + 30 ms，所以视频轨从 0 开始、没有空 edit，frameprobe 按默认 startTick = 0 推拍号就对。
    /// 文件里每一对闪光 / click 本身都对齐。
    func testA2_videoDelayMode_recordingStaysAligned() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-w1b4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var show = M0Factory.show(width: 1280, height: 720)
        show.mixer.format = .hd720p60
        show.outputs = []
        let master = Bus.master.rawValue
        show.audio.buses[master].effects = [EffectSlot(id: "peakLimiter", params: ["attackSeconds": .number(0.03), "decaySeconds": .number(0.024), "preGainDb": .number(0)])]
        let showURL = dir.appendingPathComponent("show.json")
        try show.save().write(to: showURL)
        var results: [AVCompensation: FrameAnalysis.AVStats] = [:]
        for mode in [AVCompensation.audioPTS, .videoDelay] {
            let record = dir.appendingPathComponent("rec-\(mode.rawValue).mov")
            var options = RunOptions(showURL: showURL, durationSeconds: 12, preview: false, audioDevice: "null", leadMs: 1000, gpuStats: false)
            options.recordURL = record
            options.avCompensation = mode
            let session = try HeadlessSession(options: options)
            try await session.run()
            XCTAssertEqual(session.exitCode, 0, "\(mode)")
            XCTAssertEqual(session.engine.counters.videoDelayMs, mode == .videoDelay ? 30 : 0, accuracy: 0.001, "\(mode)：视频延后")
            XCTAssertEqual(session.engine.counters.videoDelayOverflow, 0)
            var probe = FrameProbe.Options()
            if mode == .videoDelay {
                let frames = try await FrameProbe.frames(record).frames
                let first = try XCTUnwrap(frames.first { $0.inputID != nil }, "有图案的第一帧")
                XCTAssertEqual(first.ptsSeconds, 0, accuracy: 0.0005, "videoDelay：开录起点按输出时间线（拍点 + 30 ms），视频轨从 0 开始、没有空 edit")
            }
            let out = try await FrameProbe.av(record, options: probe)
            let on = out.av.onSecond
            print("W1-B4 A2 录制（\(mode.rawValue)，Master 限幅 30 ms）：整秒配对 \(on.count) 对，均值 \(String(format: "%.3f", on.meanMs)) ms，σ \(String(format: "%.3f", on.stdMs))，最大 |\(String(format: "%.3f", on.maxAbsMs))| ms；全部配对 \(out.av.matchedCount)（不在整秒 \(out.av.offSecondCount)）")
            XCTAssertGreaterThanOrEqual(on.count, 9, "\(mode)：12 s 至少 9 个整秒配对")
            XCTAssertLessThanOrEqual(on.maxAbsMs, 1, "\(mode)：整秒配对 ≤ 1 ms")
            XCTAssertEqual(out.av.offSecondCount, 0, "\(mode)：没有不在整秒拍上的配对（延后恒定，视频 PTS 网格整齐）")
            results[mode] = on
        }
        XCTAssertEqual(results[.videoDelay]!.meanMs, results[.audioPTS]!.meanMs, accuracy: 1, "两种方式的 A2 相同")
    }
}
