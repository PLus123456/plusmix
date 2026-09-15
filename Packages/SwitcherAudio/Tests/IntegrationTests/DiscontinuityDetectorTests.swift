import XCTest
import SwitcherContracts
@testable import SwitcherAudioIntegration

/// A1 的第三项：波形不连续检测器。合成信号的 click（48 个 +1.0）不算；孤立跳变、丢块、延迟线跳位都要算到。
final class DiscontinuityDetectorTests: XCTestCase {
    let t0 = HostTime(nanoseconds: 1_000_000_000)

    func render(seconds: Double) -> [Float] {
        let sig = TestSignal(t0: t0)
        var out = [Float](repeating: 0, count: Int(seconds * 48000))
        out.withUnsafeMutableBufferPointer { sig.render(into: $0.baseAddress!, frameCount: $0.count, startingAt: 0) }
        return out
    }

    func feed(_ det: inout DiscontinuityDetector, _ samples: [Float], blockFrames: Int = 256) {
        var i = 0
        while i < samples.count {
            let n = min(blockFrames, samples.count - i)
            samples.withUnsafeBufferPointer { buf in
                var planes: [UnsafePointer<Float>] = [buf.baseAddress! + i, buf.baseAddress! + i]
                planes.withUnsafeMutableBufferPointer { det.feed(planes: UnsafePointer($0.baseAddress!), frameCount: n) }
            }
            i += n
        }
    }

    func testA1_detector_cleanSignalWithClicks_countsZero() {
        let samples = render(seconds: 5)
        var det = DiscontinuityDetector(channels: 2)
        feed(&det, samples)
        XCTAssertEqual(det.count, 0, "\(det.recent)")
        // 离线口径：用已知 click 位置排除
        let sig = TestSignal(t0: t0)
        XCTAssertEqual(DiscontinuityDetector.analyze(samples: samples) { sig.isClick(sampleIndex: $0) }.count, 0)
    }

    func testA1_detector_isolatedJump_droppedBlock_andDelayJumpAreCounted() {
        var samples = render(seconds: 3)
        // 1. 孤立跳变：把第 1.5 s 处一个样本置 0.9（前后是 ±0.1 的正弦）
        samples[72_000] = 0.9
        // 2. 丢块：删掉 256 个样本（正弦相位跳变 ≈ 0.1 × 2 sin(...)，可能不到 0.5 —— 所以用满幅方波段来模拟真实节目）
        var det = DiscontinuityDetector(channels: 2)
        feed(&det, samples)
        XCTAssertEqual(det.count, 2, "进 0.9 一次、出 0.9 一次（单个样本不是平台）：\(det.recent)")
        // 3. 平台启发式：0.9 以上但只有 4 个样本 → 不是 click → 算
        var s2 = render(seconds: 1)
        for i in 24_000..<24_004 { s2[i] = 1.0 }
        var d2 = DiscontinuityDetector(channels: 2)
        feed(&d2, s2)
        XCTAssertEqual(d2.count, 2, "\(d2.recent)")
        // 4. 跨块边界的 click 仍不算：click 从块内第 250 个样本开始（48000 不是 256 的倍数，天然跨块）
        var d3 = DiscontinuityDetector(channels: 2)
        feed(&d3, render(seconds: 3), blockFrames: 250)
        XCTAssertEqual(d3.count, 0, "\(d3.recent)")
    }

    func testA1_detector_thresholdIsHalfFullScale() {
        var samples = [Float](repeating: 0, count: 1000)
        samples[500] = 0.49          // 不到阈值
        var det = DiscontinuityDetector(channels: 1)
        samples.withUnsafeBufferPointer { buf in
            var planes: [UnsafePointer<Float>] = [buf.baseAddress!]
            planes.withUnsafeMutableBufferPointer { det.feed(planes: UnsafePointer($0.baseAddress!), frameCount: 1000) }
        }
        XCTAssertEqual(det.count, 0)
        samples[500] = 0.51
        var d2 = DiscontinuityDetector(channels: 1)
        samples.withUnsafeBufferPointer { buf in
            var planes: [UnsafePointer<Float>] = [buf.baseAddress!]
            planes.withUnsafeMutableBufferPointer { d2.feed(planes: UnsafePointer($0.baseAddress!), frameCount: 1000) }
        }
        XCTAssertEqual(d2.count, 2)
        XCTAssertEqual(d2.recent.first?.sampleIndex, 500)
    }
}
