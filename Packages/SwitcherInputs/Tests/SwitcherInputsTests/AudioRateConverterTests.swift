import AudioToolbox
import CoreAudio
import XCTest
import SwitcherContracts
import SwitcherInputsHarness
@testable import SwitcherInputs

/// 采样率转换（泵线程那条路）：帧数比、音调、以及"输出帧号 → 输入帧号"的映射——后者决定写环时打什么 hostTime，
/// 直接影响 A2，所以单独钉住。全部是纯计算，不需要硬件。
final class AudioRateConverterTests: XCTestCase {
    /// 1 kHz 正弦（−6 dBFS）。
    private func sine(frames: Int, startingAt start: Int, rate: Double, hz: Double = 1000) -> [Float] {
        (0..<frames).map { Float(0.5 * sin(2 * Double.pi * hz * Double(start + $0) / rate)) }
    }

    /// 把一块单声道数据喂进转换器，收集输出。
    private func feed(_ converter: AudioRateConverter, _ block: [Float], into output: inout [Float]) throws {
        var input = block
        try input.withUnsafeMutableBufferPointer { buffer in
            let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 1)
            defer { table.deallocate() }
            table[0] = UnsafePointer(buffer.baseAddress!)
            var collected: [Float] = []
            _ = try converter.convert(planes: UnsafePointer(table), frameCount: buffer.count) { planes, frames in
                collected.append(contentsOf: UnsafeBufferPointer(start: planes[0], count: frames))
            }
            output.append(contentsOf: collected)
        }
    }

    // MARK: 帧数比与音调

    func testRateConverter_44100To48000_keepsFrameRatioAndTone() throws {
        let sourceRate = 44100.0
        let converter = try AudioRateConverter(sourceRate: sourceRate, channels: 1, maxOutputFrames: 4096)
        var output: [Float] = []
        let blockFrames = 512
        let blocks = 90                                  // ≈ 1.04 s
        for k in 0..<blocks {
            try feed(converter, sine(frames: blockFrames, startingAt: k * blockFrames, rate: sourceRate), into: &output)
        }
        let inputFrames = blocks * blockFrames
        let expected = Double(inputFrames) * 48000 / sourceRate
        print("采样率转换 44.1k → 48k：输入 \(inputFrames) 帧 → 输出 \(output.count) 帧（期望 ≈ \(Int(expected))），"
              + "群延迟 \(converter.latencyInputFrames) 输入帧")
        XCTAssertLessThan(abs(Double(output.count) - expected), 64, "输出帧数应接近 输入 × 48000 / 44100")
        // 音调：跳过起头的过渡段，数过零点（1 kHz 在 48 kHz 下每秒 2000 次过零）
        let tail = Array(output.dropFirst(4800))
        var crossings = 0
        for i in 1..<tail.count where (tail[i - 1] < 0) != (tail[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(tail.count) / 48000)
        print("  输出音调 \(hz) Hz（期望 1000）；峰值 \(tail.map { abs($0) }.max() ?? 0)（期望 ≈ 0.5）")
        XCTAssertLessThan(abs(hz - 1000), 5, "转换后不是 1 kHz")
        XCTAssertEqual(Double(tail.map { abs($0) }.max() ?? 0), 0.5, accuracy: 0.05, "电平变了")
    }

    // MARK: 输出帧号 → 输入帧号（决定写环的 hostTime）

    func testRateConverter_outputFrameMapsBackToTheSourceFrameOfTheImpulse() throws {
        let sourceRate = 44100.0
        let converter = try AudioRateConverter(sourceRate: sourceRate, channels: 1, maxOutputFrames: 4096)
        let blockFrames = 512
        let impulseBlock = 6
        let impulseOffset = 100
        let impulseSourceFrame = impulseBlock * blockFrames + impulseOffset
        var output: [Float] = []
        for k in 0..<20 {
            var block = [Float](repeating: 0, count: blockFrames)
            if k == impulseBlock { block[impulseOffset] = 1 }
            try feed(converter, block, into: &output)
        }
        var peak = 0
        var peakValue: Float = 0
        for i in 0..<output.count where abs(output[i]) > peakValue {
            peakValue = abs(output[i])
            peak = i
        }
        let mapped = converter.sourceFrame(forOutputFrame: UInt64(peak))
        print("脉冲在输入第 \(impulseSourceFrame) 帧 → 输出第 \(peak) 帧（峰值 \(peakValue)）；"
              + "sourceFrame(forOutputFrame:) 反推 \(mapped)，误差 \(mapped - Double(impulseSourceFrame)) 输入帧"
              + "（\((mapped - Double(impulseSourceFrame)) / sourceRate * 1000) ms）")
        XCTAssertGreaterThan(peakValue, 0.1, "没找到脉冲")
        XCTAssertLessThan(abs(mapped - Double(impulseSourceFrame)), 2,
                          "反推的输入帧号应落在脉冲那一帧 ±2 帧内（否则写环的 hostTime 会整体偏，A2 直接受影响）")
    }

    // MARK: 群延迟实测在别的采样率上也成立

    func testRateConverter_measuredLatencyIsSaneAtSeveralRates() throws {
        for rate in [44100.0, 32000.0, 88200.0, 96000.0] {
            let latency = AudioRateConverter.measureLatencyInputFrames(sourceRate: rate)
            print("  \(Int(rate)) Hz → 48 kHz 群延迟 \(latency) 输入帧 = \(latency / rate * 1000) ms")
            XCTAssertTrue(latency.isFinite)
            XCTAssertLessThan(abs(latency), rate * 0.05, "群延迟不该超过 50 ms")
        }
    }
}
