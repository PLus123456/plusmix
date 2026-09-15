import XCTest
import SwitcherContracts
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 设备时钟 → host 时钟重采样（A3 的录制路径）：块 stamp 按设备 ppm 排，内容里的 click 在 host 整秒；
/// 重采样后按"首块 PTS + 样本计数"的时间轴，click 必须仍在整秒（误差 ≤ 2 样本），并且不随时间漂。
final class HostClockResamplerTests: XCTestCase {
    let t0 = HostTime(nanoseconds: 5_000_000_000, timebase: IT.tb)

    /// 合成一台 ppm 偏差的设备输出的 Master 流：块 k 的 stamp = 设备样本 256k 的 host time；内容 = TestSignal（click 在 host 整秒）。
    func run(devicePpm: Double, seconds: Double, blockFrames: Int = 256) -> (capture: TimedCapture, resampler: HostClockResampler) {
        let signal = TestSignal(t0: t0, driftPpm: devicePpm, timebase: IT.tb)
        let r = HostClockResampler(channels: 2, timebase: IT.tb)
        let cap = TimedCapture(timebase: IT.tb)
        let blocks = Int(seconds * signal.effectiveSampleRate / Double(blockFrames))
        var mono = [Float](repeating: 0, count: blockFrames)
        for k in 0..<blocks {
            let start = Int64(k * blockFrames)
            mono.withUnsafeMutableBufferPointer { signal.render(into: $0.baseAddress!, frameCount: blockFrames, startingAt: start) }
            mono.withUnsafeBufferPointer { m in
                var planes: [UnsafePointer<Float>] = [m.baseAddress!, m.baseAddress!]
                planes.withUnsafeMutableBufferPointer { p in
                    r.push(planes: UnsafePointer(p.baseAddress!), frameCount: blockFrames, hostTime: signal.hostTime(ofSample: start)) { pl, n, t in
                        cap.append(planes: pl, frames: n, hostTime: t)
                    }
                }
            }
        }
        return (cap, r)
    }

    /// click 相对 host 整秒的偏差（样本），按输出时间轴。
    func clickErrors(_ cap: TimedCapture) -> [(second: Int, errorSamples: Double)] {
        let onsets = IT.clickOnsets(cap.left)
        return onsets.compactMap { i in
            let t = cap.hostTime(ofSample: i)
            let rel = Double((t - t0).nanoseconds(timebase: IT.tb)) / 1e9
            let k = Int(rel.rounded())
            guard k >= 1 else { return nil }
            return (k, (rel - Double(k)) * 48000)
        }
    }

    func testA3_hostClockResampler_zeroPpm_isTransparentInTime() {
        let (cap, r) = run(devicePpm: 0, seconds: 20)
        XCTAssertEqual(cap.gaps.count, 0, "输出时间轴按计数连续")
        XCTAssertEqual(r.snapshot.starvedPulls, 0)
        let errs = clickErrors(cap)
        XCTAssertGreaterThanOrEqual(errs.count, 18)
        for e in errs { XCTAssertLessThanOrEqual(abs(e.errorSamples), 1.5, "第 \(e.second) 秒 click 偏 \(e.errorSamples) 样本") }
        XCTAssertEqual(r.ratio, 1, accuracy: 2e-6)
    }

    func testA3_hostClockResampler_plus30ppm_clicksStayOnHostSeconds_noDrift() {
        let seconds = IT.seconds("SW_AUDIO_RESAMPLE_SECONDS", default: 120)
        let (cap, r) = run(devicePpm: 30, seconds: seconds)
        XCTAssertEqual(cap.gaps.count, 0)
        XCTAssertEqual(r.snapshot.starvedPulls, 0, "输入余量足够，回调从不挨饿")
        let errs = clickErrors(cap)
        XCTAssertGreaterThanOrEqual(Double(errs.count), seconds - 3)
        let maxErr = errs.map { abs($0.errorSamples) }.max() ?? 0
        let tail = errs.filter { Double($0.second) > seconds - 30 }
        let tailMax = tail.map { abs($0.errorSamples) }.max() ?? 0
        // 不重采样的话 30 ppm × 120 s = 173 样本；这里全程 ≤ 3 样本、稳态 ≤ 1.5 样本
        XCTAssertLessThanOrEqual(maxErr, 3, "全程最大偏差 \(maxErr) 样本：\(errs.suffix(5))")
        XCTAssertLessThanOrEqual(tailMax, 1.5, "稳态偏差 \(tailMax) 样本")
        // 斜率（A3 口径）：ms/s × 8 h
        let xs = errs.map { Double($0.second) }, ys = errs.map { $0.errorSamples / 48 }   // ms
        let slope = slopeOf(x: xs, y: ys)
        XCTAssertLessThanOrEqual(abs(slope * 8 * 3600), 1, "拟合斜率换算 8 小时 \(slope * 8 * 3600) ms")
        XCTAssertEqual(r.snapshot.devicePpm ?? 0, 30, accuracy: 3)
    }

    func testA3_hostClockResampler_minus50ppm_clicksStayOnHostSeconds() {
        let (cap, r) = run(devicePpm: -50, seconds: 60)
        XCTAssertEqual(r.snapshot.starvedPulls, 0)
        let errs = clickErrors(cap)
        let maxErr = errs.map { abs($0.errorSamples) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxErr, 3, "\(errs.suffix(5))")
        XCTAssertEqual(r.snapshot.devicePpm ?? 0, -50, accuracy: 3)
    }

    func testA3_hostClockResampler_ptsIsOriginPlusCount_andDeliveryLagIsBounded() {
        let (cap, r) = run(devicePpm: 0, seconds: 5)
        XCTAssertEqual(cap.firstHostTime, t0)
        // 产出数 = 输入数 − 交付余量（±1）
        XCTAssertEqual(Double(r.framesProduced), Double(r.framesReceived - Int64(r.deliveryMarginFrames)), accuracy: 2)
        XCTAssertEqual(cap.left.count, Int(r.framesProduced))
    }

    private func slopeOf(x: [Double], y: [Double]) -> Double {
        guard x.count >= 2 else { return 0 }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<x.count { sxx += (x[i] - mx) * (x[i] - mx); sxy += (x[i] - mx) * (y[i] - my) }
        return sxx > 0 ? sxy / sxx : 0
    }
}
