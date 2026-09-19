import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherTestKit

/// frameprobe av 补课（prompt 44 交付 2 / 3 / 4）在真文件上的验证：
/// - 推流落盘的 fMP4（无 priming 信息、音轨 start_time ≠ 0）：AVFoundation 口径偏 +64 ms，修正后与 ffmpeg 口径差 ≤ 1 ms；
/// - 60 / 59.94 交替在播的合成文件：整秒配对均值 ≈ 0、全部配对均值明显偏；
/// - 不连续检测在 AAC 文件上 0 次、人为插跳变 → 1。
final class StreamRecordingProbeTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// W2-D `MediaMTXTests.testRTMP_endToEnd` 的 MediaMTX 落盘文件（本机 2026-09-18 13:20）在顶层 box 边界截到前 4 个分片（Tests/Fixtures/README.md）。
    static let streamFixture = repoRoot.appendingPathComponent("Tests/Fixtures/w2d-rtmp-stream-4s.mp4")
    static let sample20s = repoRoot.appendingPathComponent("Tests/Fixtures/w1a-sample-20s.mov")
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    // MARK: 容器索引

    func testW1A2_mp4Index_readsTracksEditListsAndFirstFragmentTimes() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.streamFixture.path), "样例不存在")
        let stream = try XCTUnwrap(MP4Index.scan(url: Self.streamFixture))
        XCTAssertTrue(stream.isFragmented); XCTAssertEqual(stream.scannedFragments, 1, "第一个 moof 就有两条轨的 tfdt，不用再读")
        XCTAssertEqual(stream.tracks.count, 2)
        let v = try XCTUnwrap(stream.videoTrack), a = try XCTUnwrap(stream.audioTrack)
        XCTAssertEqual(v.id, 1); XCTAssertEqual(v.codec, "avc1"); XCTAssertEqual(v.timescale, 90000); XCTAssertEqual(v.firstFragmentDecodeTime, 0); XCTAssertFalse(v.hasEditList)
        XCTAssertEqual(a.id, 2); XCTAssertEqual(a.codec, "mp4a"); XCTAssertEqual(a.timescale, 48000); XCTAssertEqual(a.firstFragmentDecodeTime, 960); XCTAssertFalse(a.hasEditList)
        XCTAssertEqual(stream.audioStartRelativeToVideoSeconds, 0.020, accuracy: 1e-9)
        // AVAssetWriter 写的录制 / 样例文件：非分片，音轨有 elst（media_time = 2112 priming）
        let mov = try XCTUnwrap(MP4Index.scan(url: Self.sample20s))
        XCTAssertFalse(mov.isFragmented)
        XCTAssertEqual(mov.videoTrack?.editList.map(\.mediaTime), [0])
        XCTAssertEqual(mov.audioTrack?.editList.map(\.mediaTime), [2112])
        XCTAssertEqual(mov.audioStartRelativeToVideoSeconds, 0)
        // 不是 MP4 的文件 → nil；不存在 → 抛错
        XCTAssertNil(try MP4Index.scan(url: Self.repoRoot.appendingPathComponent("Tests/Fixtures/README.md")))
        XCTAssertThrowsError(try MP4Index.scan(url: Self.repoRoot.appendingPathComponent("Tests/Fixtures/nope.mp4")))
    }

    // MARK: A2：推流落盘文件

    /// ffmpeg 口径（W2-D `AVOffsetFFmpeg` 的做法）：`aresample=first_pts=0` 补起始偏移、不裁 priming，解 PCM 找满幅样本当 click；闪光时刻用 frameprobe 的 ptsSeconds。
    func ffmpegOffsets(_ url: URL, flashes: [Double]) throws -> [Double] {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("w1a2-\(getpid()).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-map", "0:a:0", "-af", "aresample=async=1:first_pts=0", "-f", "f32le", "-ac", "1", "-ar", "48000", raw.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let data = try Data(contentsOf: raw)
        var clicks: [Double] = []
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let s = b.bindMemory(to: Float.self)
            var last = -1000
            for i in 0..<s.count where s[i] > 0.9 {
                if i - last > 100 { clicks.append(Double(i) / 48000) }
                last = i
            }
        }
        return flashes.compactMap { f in clicks.min { abs($0 - f) < abs($1 - f) }.flatMap { abs($0 - f) < 0.3 ? (f - $0) * 1000 : nil } }
    }

    func testA2_streamRecordingWithoutPriming_matchesFFmpeg() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.streamFixture.path), "样例不存在")
        var o = FrameProbe.Options()
        o.discontinuities = true
        let r = try await FrameProbe.av(Self.streamFixture, options: o)
        let tl = try XCTUnwrap(r.audio?.timeline)
        XCTAssertEqual(tl.codec, "aac"); XCTAssertTrue(tl.isFragmented); XCTAssertFalse(tl.hasEditList)
        XCTAssertEqual(tl.avfoundationStartSeconds, 0, accuracy: 1e-9, "AVFoundation 把没有编辑列表的分片轨归零")
        XCTAssertEqual(tl.containerOffsetSeconds, 0.020, accuracy: 1e-9, "容器里音轨 tfdt 960 = 20 ms")
        XCTAssertEqual(tl.primingTrimmedSamples, 2112); XCTAssertEqual(tl.primingAddedBackSamples, 2112)
        XCTAssertEqual(tl.correctionSeconds, 0.064, accuracy: 1e-9); XCTAssertEqual(tl.applied, "ffmpeg")
        XCTAssertEqual(r.audio?.startSeconds ?? 0, 0.064, accuracy: 1e-9)
        // 修正后：3 个整秒配对，偏移 0 ± 1 ms；AVFoundation 原生口径 +64 ms（W2-D 报的数字）
        XCTAssertEqual(r.av.onSecond.count, 3); XCTAssertEqual(r.av.offSecondCount, 0)
        XCTAssertEqual(r.av.onSecond.meanMs, 0, accuracy: 1); XCTAssertEqual(r.av.onSecond.maxAbsMs, 0, accuracy: 1)
        XCTAssertEqual(r.av.passA2, true)
        let c = try XCTUnwrap(r.timelines)
        XCTAssertEqual(c.avfoundation.meanMs, 64, accuracy: 1); XCTAssertEqual(c.ffmpeg.meanMs, 0, accuracy: 1); XCTAssertEqual(c.ffmpegCorrectionMs, 64, accuracy: 1e-6)
        // A1 第三项：0（AAC 解码后 click 边沿的台阶都在排除窗口里）
        let d = try XCTUnwrap(r.discontinuities)
        XCTAssertEqual(d.count, 0); XCTAssertEqual(d.clickCount, 3); XCTAssertGreaterThanOrEqual(d.jumpsAtClicks, 6); XCTAssertEqual(d.passA1, true)
        // --aac-priming 0：只加容器偏移 → +44 ms；--aac-priming 2112 = auto
        o.aacPriming = .samples(0)
        let zero = try await FrameProbe.av(Self.streamFixture, options: o)
        XCTAssertEqual(zero.av.onSecond.meanMs, 44, accuracy: 1); XCTAssertEqual(zero.audio?.timeline?.applied, "custom")
        o.aacPriming = .samples(2112)
        let n = try await FrameProbe.av(Self.streamFixture, options: o)
        XCTAssertEqual(n.av.onSecond.meanMs, 0, accuracy: 1); XCTAssertEqual(n.audio?.timeline?.applied, "ffmpeg")
        // ffmpeg 口径独立算一遍：两种口径差 ≤ 1 ms
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.ffmpeg), "没有 brew 的 ffmpeg，跳过独立口径对照")
        let flashes = r.av.pairs.filter { $0.offsetMs != nil }.map(\.flashTimeSeconds)
        let ff = try ffmpegOffsets(Self.streamFixture, flashes: flashes)
        XCTAssertEqual(ff.count, 3)
        let ffMean = ff.reduce(0, +) / Double(ff.count)
        print("[W1-A2 A2] 推流落盘样例：frameprobe（ffmpeg 口径）\(String(format: "%.3f", r.av.onSecond.meanMs)) ms，AVFoundation 原生 \(String(format: "%.3f", c.avfoundation.meanMs)) ms，ffmpeg 独立解码 \(String(format: "%.3f", ffMean)) ms（逐对 \(ff.map { String(format: "%.3f", $0) })）")
        XCTAssertEqual(r.av.onSecond.meanMs, ffMean, accuracy: 1.0, "frameprobe 修正后与 ffmpeg 口径差 ≤ 1 ms")
        for (p, f) in zip(r.av.pairs.filter { $0.offsetMs != nil }, ff) { XCTAssertEqual(p.offsetMs!, f, accuracy: 1.0) }
    }

    /// 录制路径（AVAssetWriter 写了编辑列表）不受修正影响：修正 0、两种口径相同，与 W1-A 的快照一致。
    func testA2_recordedFileWithEditList_correctionIsZero() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.sample20s.path), "样例不存在")
        let r = try await FrameProbe.av(Self.sample20s)
        let tl = try XCTUnwrap(r.audio?.timeline)
        XCTAssertTrue(tl.hasEditList); XCTAssertEqual(tl.editListMediaTime, 2112); XCTAssertEqual(tl.primingTrimmedSamples, 2112)
        XCTAssertEqual(tl.correctionSeconds, 0); XCTAssertEqual(tl.ffmpegCorrectionSeconds, 0); XCTAssertEqual(tl.applied, "avfoundation")
        XCTAssertEqual(r.av.onSecond.count, 20); XCTAssertLessThan(r.av.onSecond.maxAbsMs, 0.5); XCTAssertEqual(r.av.passA2, true)
        XCTAssertEqual(r.timelines?.avfoundation.meanMs ?? 1, r.timelines?.ffmpeg.meanMs ?? 2, accuracy: 1e-9)
    }

    // MARK: A2：60 / 59.94 交替在播

    func testA2_exactSecondPairing_ignores5994FlashDrift() async throws {
        // 30 s 360p：A = 60 fps（ID 0），B = 59.94（ID 1，闪光周期 1.001 s）；第 600 拍 Cut 到 B，第 1500 拍 Cut 回 A；click 按 60 fps 节目每整秒一个
        var spec = SampleMovieWriter.Spec()
        spec.width = 640; spec.height = 360; spec.seconds = 30; spec.bitrate = 800_000
        spec.sourceA = SyntheticSourceSettings(frameRate: .fps60, width: 640, height: 360, background: .gray(level: 64), patternID: 0, audio: false)
        spec.sourceB = SyntheticSourceSettings(frameRate: .fps5994, width: 640, height: 360, background: .gray(level: 192), patternID: 1, audio: false)
        spec.events = [.cut(tick: 600), .cut(tick: 1500)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1a2-5994-\(getpid()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await SampleMovieWriter.write(spec: spec, to: url)
        let r = try await FrameProbe.av(url)
        let t = r.av
        XCTAssertEqual(t.flashCount, 30, "A 段 15 个 + B 段 15 个闪光")
        XCTAssertEqual(t.onSecond.count, 15, "0–9 s 与 25–29 s 的闪光在整秒拍上")
        XCTAssertEqual(t.offSecondCount, 15, "B 在播的 10–24 s：闪光在 1.001 k s，拍号不是 60 的倍数")
        XCTAssertEqual(t.onSecond.meanMs, 0, accuracy: 0.5)
        XCTAssertLessThan(t.onSecond.maxAbsMs, 0.5)
        XCTAssertGreaterThan(t.meanMs, 5, "全部配对被 B 段拉偏（10…24 ms）")
        XCTAssertGreaterThan(t.maxAbsMs, 20)
        XCTAssertEqual(t.passA2, true)
        XCTAssertNotNil(t.note)
        for p in t.pairs where !p.onSecondTick {
            let k = Double((p.tick + 30) / 60)
            XCTAssertEqual(p.offsetMs ?? 0, k, accuracy: 0.5 + 1000.0 / 60, "B 段第 \(k) 个闪光晚 ≈ \(k) ms（再加最多一帧的挑帧量化）")
        }
        print("[W1-A2 A2] 60 / 59.94 交替：整秒配对 \(t.onSecond.count) 对均值 \(String(format: "%.3f", t.onSecond.meanMs)) ms，全部配对 \(t.matchedCount) 对均值 \(String(format: "%.3f", t.meanMs)) ms、最大 \(String(format: "%.3f", t.maxAbsMs)) ms")
    }

    // MARK: A1：文件级不连续

    func testA1_discontinuities_aacFileZero_andInjectedJumpIsFound() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.sample20s.path), "样例不存在")
        var o = FrameProbe.Options()
        o.discontinuities = true
        let r = try await FrameProbe.av(Self.sample20s, options: o)
        let d = try XCTUnwrap(r.discontinuities)
        XCTAssertEqual(d.count, 0, "\(d.events)"); XCTAssertEqual(d.clickCount, 20); XCTAssertEqual(d.passA1, true)
        XCTAssertGreaterThanOrEqual(d.jumpsAtClicks, 39, "每个 click 进 / 出各一次（第一个在样本 0 上没有进），AAC 解码后可能多几个台阶")
        // 同一批样本人为插一个台阶（12.3456 s 起 +0.6）：1 次，位置对
        let l = try await FrameProbe.load(Self.sample20s, options: o, withAudio: true)
        var samples = l.samples
        let at = Int(12.3456 * 48000)
        for i in at..<samples.count { samples[i] += 0.6 }
        let broken = FrameAnalysis.discontinuities(samples: samples, sampleRate: 48000, startSeconds: l.audio!.startSeconds, clicks: l.clicks)
        XCTAssertEqual(broken.count, 1, "\(broken.events)")
        XCTAssertEqual(broken.events.first?.sampleIndex, Int64(at))
        XCTAssertEqual(broken.events.first?.timeSeconds ?? 0, l.audio!.startSeconds + Double(at) / 48000, accuracy: 1e-9)
        XCTAssertEqual(broken.passA1, false)
    }
}
