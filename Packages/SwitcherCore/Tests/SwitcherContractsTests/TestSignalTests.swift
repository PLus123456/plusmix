import XCTest
@testable import SwitcherContracts

/// 合成音频契约：1 kHz −20 dBFS 正弦，闪光时刻叠加 1 ms 满幅 click，可加采样率漂移。
final class TestSignalTests: XCTestCase {
    func testP1_signal_toneLevelIsMinus20dBFS() {
        let s = TestSignal(t0: .zero)
        let n = 48_000
        var buf = [Float](repeating: 0, count: n)
        buf.withUnsafeMutableBufferPointer { s.render(into: $0.baseAddress!, frameCount: n, startingAt: 0) }
        // 跳过 click 窗口（第 0 个 click 在样本 0…47）后算 RMS
        let body = buf[48...]
        let rms = (body.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(body.count)).squareRoot()
        let dbfs = 20 * log10(rms * 2.0.squareRoot())   // 正弦 RMS = 峰值 / √2
        XCTAssertEqual(dbfs, -20, accuracy: 0.05)
        // 1 kHz：每 48 个样本一个周期
        XCTAssertEqual(Double(buf[48 + 12]), 0.1, accuracy: 1e-5)   // 四分之一周期处是峰值 0.1
        XCTAssertEqual(Double(buf[48 + 24]), 0, accuracy: 1e-5)
        XCTAssertEqual(Double(buf[48 + 48]), 0, accuracy: 1e-5)
    }

    func testP1_signal_clicksLandOnFlashInstants() {
        // 60 fps：闪光周期 1 s；59.94：1.001 s
        for (rate, period) in [(FrameRate.fps60, Rational(1, 1)), (.fps5994, Rational(1001, 1000))] {
            let s = TestSignal(t0: HostTime(ticks: 1000), clickPeriod: TestPattern.flashPeriod(frameRate: rate))
            XCTAssertEqual(s.clickPeriod, period)
            let expectedStride = Int64(period.numerator * 48_000 / period.denominator)   // 48000 / 48048
            for k in 0..<10 {
                XCTAssertEqual(s.clickSampleIndex(k), Int64(k) * expectedStride)
            }
            let n = Int(expectedStride) * 3
            var buf = [Float](repeating: 0, count: n)
            buf.withUnsafeMutableBufferPointer { s.render(into: $0.baseAddress!, frameCount: n, startingAt: 0) }
            for k in 0..<3 {
                let start = Int(expectedStride) * k
                for i in start..<(start + 48) { XCTAssertEqual(buf[i], 1.0, "click \(k) 样本 \(i) 应满幅") }
                XCTAssertLessThan(abs(buf[start + 48]), 0.11)
                XCTAssertLessThan(abs(buf[start - 1 < 0 ? start + expectedStrideMinusOne(expectedStride) : start - 1]), 0.11)
            }
            XCTAssertTrue(s.isClick(sampleIndex: 0))
            XCTAssertTrue(s.isClick(sampleIndex: 47))
            XCTAssertFalse(s.isClick(sampleIndex: 48))
            XCTAssertTrue(s.isClick(sampleIndex: expectedStride))
        }
    }
    private func expectedStrideMinusOne(_ s: Int64) -> Int { Int(s) - 1 }

    func testP1_signal_driftShiftsClickIndexAndHostTime() {
        let tb = MachTimebase(numer: 1, denom: 1)
        let s = TestSignal(t0: HostTime(ticks: 0), driftPpm: 100, timebase: tb)
        XCTAssertEqual(s.effectiveSampleRate, 48_004.8, accuracy: 1e-9)
        // 第 k 个 click 的样本序号 = round(k × 1 s × 48004.8)
        XCTAssertEqual(s.clickSampleIndex(1), 48_005)
        XCTAssertEqual(s.clickSampleIndex(5), 240_024)
        XCTAssertEqual(s.clickSampleIndex(10), 480_048)
        // 样本 i 的 host time = t0 + i / 48004.8 s；click 落在闪光时刻 ±1 个样本
        for k in 0..<50 {
            let t = s.hostTime(ofSample: s.clickSampleIndex(k))
            let flash = HostTime(nanoseconds: UInt64(k) * 1_000_000_000, timebase: tb)
            XCTAssertLessThanOrEqual(abs((t - flash).nanoseconds(timebase: tb)), 21_000, "click \(k) 偏离闪光时刻超过一个样本")
        }
        // 无漂移时精确相等
        let s0 = TestSignal(t0: HostTime(ticks: 0), timebase: tb)
        XCTAssertEqual(s0.hostTime(ofSample: 48_000 * 7), HostTime(nanoseconds: 7_000_000_000, timebase: tb))
        // 负漂移
        XCTAssertEqual(TestSignal(t0: .zero, driftPpm: -100).clickSampleIndex(1), 47_995)
    }

    /// 分块渲染与整段渲染逐样本一致（生成器无内部状态）。
    func testP1_signal_renderIsChunkIndependent() {
        let s = TestSignal(t0: .zero, driftPpm: 37, toneHz: 997)
        let total = 48_048
        var whole = [Float](repeating: 0, count: total)
        whole.withUnsafeMutableBufferPointer { s.render(into: $0.baseAddress!, frameCount: total, startingAt: 0) }
        var pieces = [Float](repeating: 0, count: total)
        var cursor = 0
        let sizes = [256, 1, 1023, 4096, 7, 500]
        var si = 0
        while cursor < total {
            let n = min(sizes[si % sizes.count], total - cursor); si += 1
            pieces.withUnsafeMutableBufferPointer { s.render(into: $0.baseAddress! + cursor, frameCount: n, startingAt: Int64(cursor)) }
            cursor += n
        }
        XCTAssertEqual(whole, pieces)
        // 从很大的样本序号开始也不出问题（8 小时）
        var late = [Float](repeating: 0, count: 256)
        late.withUnsafeMutableBufferPointer { s.render(into: $0.baseAddress!, frameCount: 256, startingAt: 48_000 * 3600 * 8) }
        XCTAssertTrue(late.allSatisfy { abs($0) <= 1.0 })
    }
}
