import AVFoundation
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// Tests/Fixtures/pattern.mov：10 秒纯图案 1080p60 H.264 + click 音轨，W2-A 的文件输入用它当素材。
/// 由 `switcher-record-probe fixture --out Tests/Fixtures/pattern.mov` 生成一次并提交；这里只验证，不重新生成
/// （时间戳行每次生成都不同，重生成会让二进制文件天天变）。
final class FixtureTests: XCTestCase {

    func testFixture_patternMov_decodesFrameNumbersAndHasClicks() async throws {
        try FFprobe.requireAvailable()
        guard let root = TestPaths.repoRoot() else { throw XCTSkip("找不到仓库根") }
        let url = root.appendingPathComponent("Tests/Fixtures/pattern.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺 Tests/Fixtures/pattern.mov（用 switcher-record-probe fixture 生成）")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let probe = try FFprobe.probe(url)
        XCTAssertEqual(probe.stderr, "")
        XCTAssertEqual(probe.video?.codecName, "h264")
        XCTAssertEqual(probe.video?.width, 1920)
        XCTAssertEqual(probe.video?.height, 1080)
        XCTAssertEqual(probe.video?.nbFrames, 600)
        XCTAssertEqual(probe.video?.duration ?? 0, 10, accuracy: 1.0 / 60)
        XCTAssertEqual(probe.audio?.codecName, "aac")
        XCTAssertEqual(probe.audio?.duration ?? 0, 10, accuracy: 0.02)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 5 * 1024 * 1024, "Fixtures 里的样例应 ≤ 5 MB")

        // 解前 120 帧：帧号 = 序号，输入 ID 0，闪光只在第 0 / 60 帧
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var index = 0
        while index < 120, let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { XCTFail("没有像素"); break }
            let decoded = try XCTUnwrap(TestPattern.decode(pixelBuffer: pb))
            XCTAssertEqual(decoded.frameNumber, UInt32(index), "第 \(index) 帧的帧号")
            XCTAssertEqual(decoded.inputID, 0)
            XCTAssertEqual(decoded.flash, index % 60 == 0, "第 \(index) 帧闪光")
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            XCTAssertEqual(pts.seconds, Double(index) / 60, accuracy: 1e-6)
            index += 1
        }
        XCTAssertEqual(index, 120)
        reader.cancelReading()

        // click 在每个整秒
        let samples = try FFprobe.decodeAudioMono(url)
        XCTAssertEqual(samples.count, 480_000)
        for k in 0..<10 {
            let center = k * 48000
            let lo = max(0, center - 2000), hi = min(samples.count, center + 2000)
            var best = lo, bestV: Float = 0
            for i in lo..<hi where abs(samples[i]) > bestV { bestV = abs(samples[i]); best = i }
            XCTAssertLessThanOrEqual(abs(best - center), 48, "第 \(k) 个 click 在 \(best)")
        }
    }
}
