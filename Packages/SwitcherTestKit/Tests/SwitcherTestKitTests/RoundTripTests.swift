import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherTestKit

/// 图案经 H.264 往返：1080p 2 Mbps 1200 帧解码率 100%；720p 4 Mbps 也过（prompt "测试"第 1 条）。
final class RoundTripTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1a-rt-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 纯 A 源（无切换）的 spec：每一帧都必须能解。
    private func plainSpec(width: Int, height: Int, bitrate: Int, seconds: Double, frameRate: FrameRate = .fps60) -> SampleMovieWriter.Spec {
        var spec = SampleMovieWriter.Spec()
        spec.width = width; spec.height = height; spec.bitrate = bitrate; spec.seconds = seconds; spec.frameRate = frameRate
        spec.sourceA = SyntheticSourceSettings(frameRate: frameRate, width: width, height: height, background: .gray(level: 64), patternID: 3, audio: false)
        spec.sourceB = SyntheticSourceSettings(frameRate: frameRate, width: width, height: height, background: .gray(level: 192), patternID: 4, audio: false)
        spec.events = []
        spec.audio = .none
        return spec
    }

    private func roundTrip(_ spec: SampleMovieWriter.Spec, name: String, file: StaticString = #filePath, line: UInt = #line) async throws -> SampleMovieWriter.Report {
        let url = tempDir().appendingPathComponent(name)
        let report = try await SampleMovieWriter.write(spec: spec, to: url)
        let program = SampleMovieWriter.Program(spec: spec)
        let result = try await MediaReader.readVideo(url: url)
        XCTAssertEqual(result.frames.count, report.frames, file: file, line: line)
        XCTAssertEqual(result.info.width, spec.width, file: file, line: line)
        XCTAssertEqual(result.info.nominalFps, spec.frameRate.approximateFramesPerSecond, accuracy: 0.01, file: file, line: line)
        var ok = 0, grayOK = 0
        var maxGrayError = 0.0
        for f in result.frames {
            let pick = program.pick(tick: f.index)
            let expected = program.a.content(of: pick.baseFrame)
            if f.frameNumber == expected.frameNumber && f.genTimeMs == expected.hostTimeMs && f.inputID == expected.inputID && f.flash == expected.flash { ok += 1 }
            XCTAssertEqual(f.ptsSeconds, Double(f.index) * spec.frameRate.frameDuration.doubleValue, accuracy: 1e-6, file: file, line: line)
            let err = abs(f.gray - 64)
            maxGrayError = max(maxGrayError, err)
            if err <= 1.5 { grayOK += 1 }
        }
        print("[W1-A] \(name)：\(spec.width)×\(spec.height) @ \(spec.bitrate / 1000) kbps：\(report.frames) 帧，实际 \(String(format: "%.0f", report.averageKbps)) kbps，编码 \(String(format: "%.2f", report.encodeSeconds)) s，文件 \(report.fileBytes) B；四项全对 \(ok)/\(report.frames)，灰度误差最大 \(String(format: "%.2f", maxGrayError))")
        XCTAssertEqual(ok, report.frames, "解码率必须 100%", file: file, line: line)
        XCTAssertEqual(grayOK, report.frames, "底色灰度经往返误差 ≤ 1.5 级", file: file, line: line)
        return report
    }

    func testW1A_h264RoundTrip_1080p2Mbps_1200frames_100pct() async throws {
        let report = try await roundTrip(plainSpec(width: 1920, height: 1080, bitrate: 2_000_000, seconds: 20), name: "1080p-2m.mov")
        XCTAssertEqual(report.frames, 1200)
        XCTAssertLessThan(report.fileBytes, 5 * 1024 * 1024, "样例 ≤ 5 MB")
    }

    func testW1A_h264RoundTrip_720p4Mbps_100pct() async throws {
        let report = try await roundTrip(plainSpec(width: 1280, height: 720, bitrate: 4_000_000, seconds: 20), name: "720p-4m.mov")
        XCTAssertEqual(report.frames, 1200)
    }

    func testW1A_h264RoundTrip_5994fpsTimescale() async throws {
        // 59.94：PTS 用 1001/60000，第 60 帧的 pts = 1.001 s；闪光在第 0 / 60 / 120 帧
        var spec = plainSpec(width: 1280, height: 720, bitrate: 2_000_000, seconds: 3, frameRate: .fps5994)
        spec.audio = .pcm16
        let url = tempDir().appendingPathComponent("5994.mov")
        let report = try await SampleMovieWriter.write(spec: spec, to: url)
        XCTAssertEqual(report.frames, 180)
        let v = try await MediaReader.readVideo(url: url)
        XCTAssertEqual(v.frames.filter(\.flash).map(\.index), [0, 60, 120])
        XCTAssertEqual(v.frames[60].ptsSeconds, 1.001, accuracy: 1e-6)
        XCTAssertEqual(v.frames.filter { $0.frameNumber == nil }.count, 0)
        // 音轨：click 在 0 / 1.001 / 2.002 s，PCM 无损 → 样本级精确
        let audio = try await MediaReader.readAudio(url: url)
        let a = try XCTUnwrap(audio)
        XCTAssertEqual(a.info.sampleRate, 48000); XCTAssertEqual(a.info.channels, 1); XCTAssertEqual(a.info.startSeconds, 0)
        let clicks = ClickDetector.detect(samples: a.samples, sampleRate: a.info.sampleRate, startSeconds: a.info.startSeconds)
        XCTAssertEqual(clicks.map(\.sampleIndex), [0, 48048, 96096])
        let av = FrameAnalysis.av(frames: v.frames, clicks: clicks, frameDurationSeconds: 1001.0 / 60000)
        XCTAssertEqual(av.matchedCount, 3)
        XCTAssertEqual(av.maxAbsMs, 0, accuracy: 0.001, "文件里闪光与 click 严格同刻")
    }

    func testW1A_rawNV12Directory_readsBackExactly() throws {
        var spec = plainSpec(width: 640, height: 360, bitrate: 0, seconds: 1)
        spec.events = [.cut(tick: 10)]
        let dir = tempDir().appendingPathComponent("raw")
        try SampleMovieWriter.writeRawFrames(spec: spec, to: dir, frames: 30)
        let r = try MediaReader.readRawNV12Directory(url: dir, width: 640, height: 360, fps: 60)
        XCTAssertEqual(r.frames.count, 30); XCTAssertEqual(r.info.pixelFormat, "nv12"); XCTAssertEqual(r.info.durationSeconds, 0.5)
        for f in r.frames {
            XCTAssertEqual(f.frameNumber, UInt32(f.index))
            XCTAssertEqual(f.inputID, f.index < 10 ? 3 : 4)
            XCTAssertEqual(f.gray, f.index < 10 ? 64 : 192, accuracy: 0.6, "limited Y 71 / 181 换算回 64 / 192")
            XCTAssertEqual(f.flash, f.index == 0)
        }
        XCTAssertEqual(FrameAnalysis.switches(frames: r.frames).switches.map(\.kind), ["start", "cut"])
        XCTAssertThrowsError(try MediaReader.readRawNV12Directory(url: dir, width: 320, height: 180, fps: 60))
    }
}
