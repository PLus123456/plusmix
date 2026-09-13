import CoreMedia
import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// AudioEncoder（AAC，AudioConverter）：包节奏、priming、PTS 与块 host time 的关系、增量喂料。
final class AudioEncoderTests: XCTestCase {
    func testAudioEncoder_packetCadenceAndHostTimePTS() throws {
        let enc = try AudioEncoder(configuration: .init(channelCount: 2, bitrateBps: 160_000))
        XCTAssertEqual(enc.primingFrames, 2112, "AAC-LC 编码器前置延迟（macOS 26 实测 2112）")
        XCTAssertEqual(enc.framesPerPacket, 1024)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(enc.formatDescription)?.pointee
        XCTAssertEqual(asbd?.mFormatID, kAudioFormatMPEG4AAC)
        var cookieSize = 0
        XCTAssertNotNil(CMAudioFormatDescriptionGetMagicCookie(enc.formatDescription, sizeOut: &cookieSize))
        XCTAssertGreaterThan(cookieSize, 0)

        let packets = LockedArray<EncodedAudioPacket>()
        enc.output = { packets.append($0) }
        let t0 = HostTime(nanoseconds: 1_000_000_000_000)
        let signal = TestSignal(t0: t0)
        let feeder = SignalFeeder(signal: signal, channelCount: 2, blockFrames: 256)
        let seconds = 3
        let totalFrames = Int64(seconds * 48000)
        // 增量喂：每次喂到"下一拍"的时刻，模拟每拍一次的泵
        let clock = TickClockSpec(t0: t0, frameRate: .fps60)
        let sink = EncoderSink(enc)
        for tick in 0...(seconds * 60) { feeder.feed(upTo: clock.time(of: Tick(Int64(tick))), to: [sink]) }
        feeder.flush(upToSample: totalFrames, to: [sink])
        let beforeFinish = packets.values.count
        enc.finish()
        let all = packets.values
        // 3 s = 144000 帧 + 2112 priming = 146112 → 142 个整包（flush 前），finish 后补到 143 包（尾部 + 编码器延迟）
        XCTAssertEqual(beforeFinish, 142, "finish 前应当有 floor(144000 / 1024) 个包；实际 \(beforeFinish)")
        XCTAssertGreaterThanOrEqual(all.count, 143)
        XCTAssertLessThanOrEqual(all.count, 145)
        XCTAssertEqual(enc.framesIn, totalFrames)
        // 包 k 首样本序号 = 1024k − 2112；前两个包全是预卷
        for (k, p) in all.enumerated() {
            XCTAssertEqual(p.firstFrameIndex, Int64(k * 1024 - 2112))
            XCTAssertEqual(p.isPreroll, k * 1024 + 1024 <= 2112)
            let expected = signal.hostTime(ofSample: max(0, p.firstFrameIndex))
            let ns = Double(Int64(p.hostTime.nanoseconds) - Int64(expected.nanoseconds))
            if p.firstFrameIndex >= 0 {
                XCTAssertLessThanOrEqual(abs(ns), 1000, "包 \(k) 的 host time 应等于其首样本的时刻（误差 ≤ 1 µs），差 \(ns) ns")
            }
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(p.sampleBuffer).value, Int64(p.hostTime.nanoseconds))
            XCTAssertGreaterThan(p.byteCount, 0)
        }
        // 码率量级：160 kbps × 3 s ≈ 60 KB（±50%）
        let bytes = all.reduce(0) { $0 + $1.byteCount }
        XCTAssertGreaterThan(bytes, 30_000)
        XCTAssertLessThan(bytes, 90_000)
        print("AudioEncoder：\(all.count) 包，\(bytes) 字节，priming \(enc.primingFrames)")
    }

    /// 把 AudioEncoder 挂成 AudioBlockConsumer 用的小适配器。
    final class EncoderSink: AudioBlockConsumer {
        let consumerName = "aac"
        let encoder: AudioEncoder
        init(_ e: AudioEncoder) { encoder = e }
        func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
            encoder.encode(planes: planes, frameCount: frameCount, hostTime: hostTime)
        }
    }
}
