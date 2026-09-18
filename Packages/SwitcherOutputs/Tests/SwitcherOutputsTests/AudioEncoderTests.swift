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
        // 3 s = 144000 帧：finish 前 AudioConverter 内部还压着 1–3 包的输入（它按自己的节奏取），
        // 所以 flush 前 138–142 包；finish 后总数 = ceil((144000 + 2112) / 1024) = 143（尾部 + 编码器延迟）
        XCTAssertGreaterThanOrEqual(beforeFinish, 138, "finish 前的包数 \(beforeFinish)")
        XCTAssertLessThanOrEqual(beforeFinish, 142)
        XCTAssertEqual(all.count, 143)
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
        // 恒定码率：160 kbps × 3 s = 60 000 字节（±15%）
        let bytes = all.reduce(0) { $0 + $1.byteCount }
        XCTAssertGreaterThan(bytes, 51_000)
        XCTAssertLessThan(bytes, 69_000)
        print("AudioEncoder：\(all.count) 包，\(bytes) 字节 = \(bytes * 8 / seconds / 1000) kbps，priming \(enc.primingFrames)")
    }

    /// W2-D 发现（reports/issues/W2D-w1-outputs-audioencoder-finish-empty.md）：一块都没喂过就 finish()，emit 里
    /// stamp 环为空给出 host time 0、再减 priming 变负 → 崩。修后：没有输入就只置 finishing、不发包；之后再喂也不收。
    func testAudioEncoder_finishWithoutInput_doesNotCrash() throws {
        let enc = try AudioEncoder(configuration: .init())
        let packets = LockedArray<EncodedAudioPacket>()
        enc.output = { packets.append($0) }
        enc.finish()
        enc.finish()   // 重复 finish 也安全
        XCTAssertEqual(packets.values.count, 0, "没有输入就不该发包")
        XCTAssertEqual(enc.packetsEncoded, 0)
        XCTAssertEqual(enc.framesIn, 0)
        let signal = TestSignal(t0: HostTime(nanoseconds: 1_000_000_000))
        let feeder = SignalFeeder(signal: signal, channelCount: 2, blockFrames: 256)
        feeder.flush(upToSample: 256, to: [EncoderSink(enc)])
        XCTAssertEqual(enc.framesIn, 0, "finish 之后不再接受输入")
        XCTAssertEqual(packets.values.count, 0)
    }

    /// 输入块的 host time 比 priming（2112 帧 = 44 ms）还小：预卷包的 host time 钳在 0，不能因为减出负数崩。
    func testAudioEncoder_prerollHostTimeClampedAtZero() throws {
        let enc = try AudioEncoder(configuration: .init())
        let packets = LockedArray<EncodedAudioPacket>()
        enc.output = { packets.append($0) }
        let t0 = HostTime(nanoseconds: 1_000_000)   // 1 ms
        let signal = TestSignal(t0: t0)
        let feeder = SignalFeeder(signal: signal, channelCount: 2, blockFrames: 256)
        feeder.flush(upToSample: 1024, to: [EncoderSink(enc)])
        enc.finish()
        let all = packets.values
        XCTAssertGreaterThanOrEqual(all.count, 2, "1024 帧 + 尾部至少两个包")
        XCTAssertEqual(enc.framesIn, 1024)
        for (k, p) in all.enumerated() {
            XCTAssertEqual(p.firstFrameIndex, Int64(k * 1024 - 2112))
            if p.firstFrameIndex < 0 {
                XCTAssertLessThanOrEqual(p.hostTime, t0, "预卷包 \(k) 的 host time 不晚于首块")
            } else {
                XCTAssertEqual(p.hostTime, signal.hostTime(ofSample: p.firstFrameIndex))
            }
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(p.sampleBuffer).value, Int64(p.hostTime.nanoseconds))
        }
        XCTAssertEqual(all.first?.hostTime, .zero, "第一个包（首样本序号 −2112）的 host time 钳在 0")
        print("AudioEncoder 小 host time：\(all.count) 包，host time \(all.map { $0.hostTime.ticks })")
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
