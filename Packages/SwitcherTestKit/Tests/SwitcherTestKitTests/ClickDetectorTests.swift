import XCTest
import SwitcherContracts
@testable import SwitcherTestKit

/// click 检测：合成音轨 100 个 click 全部找到，时间误差 ≤ 0.05 ms；加 −40 dB 白噪声仍 100%。
final class ClickDetectorTests: XCTestCase {
    private func render(_ signal: TestSignal, seconds: Int) -> [Float] {
        let n = Int(Double(seconds) * signal.effectiveSampleRate) - 1000 // 不含第 seconds 秒那个 click
        var buf = [Float](repeating: 0, count: n)
        buf.withUnsafeMutableBufferPointer { signal.render(into: $0.baseAddress!, frameCount: n, startingAt: 0) }
        return buf
    }

    /// 高斯白噪声，RMS = 10^(dBFS/20)。
    private func addNoise(_ samples: inout [Float], dBFS: Double, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let sigma = pow(10, dBFS / 20)
        for i in 0..<samples.count {
            // Box–Muller
            let u1 = max(rng.nextUnit(), 1e-12), u2 = rng.nextUnit()
            let g = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            samples[i] += Float(g * sigma)
        }
    }

    private func check(_ signal: TestSignal, samples: [Float], expectedCount: Int, file: StaticString = #filePath, line: UInt = #line) {
        let events = ClickDetector.detect(samples: samples, sampleRate: Double(signal.sampleRate))
        XCTAssertEqual(events.count, expectedCount, "click 个数", file: file, line: line)
        var maxErrorMs = 0.0
        for (k, e) in events.enumerated() {
            let expected = signal.clickSampleIndex(k)
            let errorMs = abs(Double(e.sampleIndex - expected)) / Double(signal.sampleRate) * 1000
            maxErrorMs = max(maxErrorMs, errorMs)
            XCTAssertEqual(e.timeSeconds, Double(e.sampleIndex) / Double(signal.sampleRate), accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(maxErrorMs, 0.05, "时间误差 ≤ 0.05 ms", file: file, line: line)
    }

    func testW1A_clickDetector_100clicksClean_allFoundExact() {
        let signal = TestSignal(t0: .zero, clickPeriod: TestPattern.flashPeriod(frameRate: .fps60))
        check(signal, samples: render(signal, seconds: 100), expectedCount: 100)
    }

    func testW1A_clickDetector_100clicksWithMinus40dBNoise_allFound() {
        let signal = TestSignal(t0: .zero, clickPeriod: TestPattern.flashPeriod(frameRate: .fps60))
        var samples = render(signal, seconds: 100)
        addNoise(&samples, dBFS: -40, seed: 7)
        check(signal, samples: samples, expectedCount: 100)
    }

    func testW1A_clickDetector_5994AndDriftStillExact() {
        // 59.94 → click 周期 1.001 s；采样率漂移 +100 ppm → click 样本序号 = round(k × 1.001 × 48004.8)
        let signal = TestSignal(t0: .zero, driftPpm: 100, clickPeriod: TestPattern.flashPeriod(frameRate: .fps5994))
        var samples = render(signal, seconds: 100)
        addNoise(&samples, dBFS: -40, seed: 11)
        check(signal, samples: samples, expectedCount: 100)
        XCTAssertEqual(signal.clickSampleIndex(1), 48053, "1.001 × 48004.8 = 48052.8")
    }

    func testW1A_clickDetector_toneAndNoiseOnly_noFalsePositive() {
        let signal = TestSignal(t0: .zero, clickPeriod: .one, clickDurationFrames: 0)
        var samples = render(signal, seconds: 30)
        addNoise(&samples, dBFS: -40, seed: 3)
        XCTAssertEqual(ClickDetector.detect(samples: samples, sampleRate: 48000).count, 0)
        // 阈值余量：把噪声抬到 −12 dB（RMS 0.25，均方 0.0625）也不该误报
        var loud = render(signal, seconds: 30)
        addNoise(&loud, dBFS: -12, seed: 5)
        XCTAssertEqual(ClickDetector.detect(samples: loud, sampleRate: 48000).count, 0)
    }

    func testW1A_clickDetector_startOffsetAndHoldOff() {
        // 两个 click 相隔 10 ms（< holdOff 50 ms）只报第一个；startSeconds 加到时间上
        var s = [Float](repeating: 0, count: 48000)
        for i in 1000..<1048 { s[i] = 1 }
        for i in 1480..<1528 { s[i] = 1 }
        for i in 10000..<10048 { s[i] = -0.9 }
        let ev = ClickDetector.detect(samples: s, sampleRate: 48000, startSeconds: 2)
        XCTAssertEqual(ev.map(\.sampleIndex), [1000, 10000])
        XCTAssertEqual(ev[0].timeSeconds, 2 + 1000.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(ev[1].peak, 0.9)
    }
}
