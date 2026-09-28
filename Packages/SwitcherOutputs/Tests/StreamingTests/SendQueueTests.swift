import CoreMedia
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// 收集编码器回调交出的包（闭包要 Sendable）。
final class PacketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EncodedAudioPacket] = []
    func append(_ p: EncodedAudioPacket) { lock.withLock { items.append(p) } }
    var packets: [EncodedAudioPacket] { lock.withLock { items } }
}

/// 用真 AudioEncoder 造 n 帧样本对应的包（hostTime 精确）。
func makeAACPackets(frames: Int, startHostTime: HostTime, includePreroll: Bool = true) -> [EncodedAudioPacket] {
    let enc = try! AudioEncoder(configuration: .init())
    let box = PacketBox()
    enc.output = { if includePreroll || !$0.isPreroll { box.append($0) } }
    let buf = [Float](repeating: 0.1, count: frames)
    buf.withUnsafeBufferPointer { p in
        var planes: [UnsafePointer<Float>] = [p.baseAddress!, p.baseAddress!]
        planes.withUnsafeMutableBufferPointer { pp in
            enc.encode(planes: UnsafePointer(pp.baseAddress!), frameCount: frames, hostTime: startHostTime)
        }
    }
    return box.packets
}

final class SendQueueTests: XCTestCase {
    private func sample(tick: Int, key: Bool) -> EncodedVideoSample {
        var sb: CMSampleBuffer?
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16, extensions: nil, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(tick), timescale: 60), decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
                             sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return EncodedVideoSample(sampleBuffer: sb!, tick: Tick(Int64(tick)), tickTime: HostTime(nanoseconds: UInt64(tick) * 16_666_667),
                                  isKeyframe: key, byteCount: 100, encodeLatency: .zero, outputTime: .zero)
    }

    /// 没开会话一律丢（stop 之后）；直播起步第一帧必须关键帧。
    func testNotAcceptingAndKeyframeGate() {
        let q = SendQueue(videoCapacity: 4, audioCapacity: 4)
        XCTAssertEqual(q.pushVideo(sample(tick: 0, key: true)), .droppedNotAccepting)
        q.beginBuffering()
        q.goLive()
        XCTAssertEqual(q.pushVideo(sample(tick: 1, key: false)), .droppedWaitingKeyframe)
        XCTAssertEqual(q.pushVideo(sample(tick: 2, key: true)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 3, key: false)), .queued)
        XCTAssertEqual(q.depth.video, 2)
        XCTAssertEqual(q.endSession().video, 2)
        XCTAssertEqual(q.depth.video, 0)
        XCTAssertEqual(q.pushVideo(sample(tick: 4, key: true)), .droppedNotAccepting)
    }

    /// 直播：满了丢新来的，之后到下一个关键帧之前都丢；队列里的帧原样保留（丢新不丢旧）。
    func testFullDropsNewestUntilNextKeyframe() {
        let q = SendQueue(videoCapacity: 3, audioCapacity: 4)
        q.beginBuffering()
        q.goLive()
        XCTAssertEqual(q.pushVideo(sample(tick: 0, key: true)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 1, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 2, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 3, key: false)), .droppedFull)
        XCTAssertEqual(q.popVideo()?.tick, Tick(0))
        XCTAssertEqual(q.pushVideo(sample(tick: 4, key: false)), .droppedWaitingKeyframe, "有位也不收非关键帧")
        XCTAssertEqual(q.pushVideo(sample(tick: 5, key: true)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 6, key: false)), .droppedFull)
        XCTAssertEqual([q.popVideo()?.tick, q.popVideo()?.tick, q.popVideo()?.tick], [Tick(1), Tick(2), Tick(5)])
        XCTAssertNil(q.popVideo())
    }

    /// 音频满丢最旧（直播 .droppedFull；缓冲 .bufferedDrop(discardedAudio: 1)）。
    func testAudioFullDropsOldest() {
        let q = SendQueue(videoCapacity: 2, audioCapacity: 2)
        q.beginBuffering()
        q.goLive()
        let packets = makeAACPackets(frames: 4096, startHostTime: HostTime(nanoseconds: 10_000_000_000))
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        XCTAssertEqual(q.pushAudio(packets[0]), .queued)
        XCTAssertEqual(q.pushAudio(packets[1]), .queued)
        XCTAssertEqual(q.pushAudio(packets[2]), .droppedFull)
        XCTAssertEqual(q.depth.audio, 2)
        XCTAssertEqual(q.popAudio()?.firstFrameIndex, packets[1].firstFrameIndex)
        let b = SendQueue(videoCapacity: 2, audioCapacity: 2)
        b.beginBuffering()
        XCTAssertEqual(b.pushAudio(packets[0]), .queued)
        XCTAssertEqual(b.pushAudio(packets[1]), .queued)
        XCTAssertEqual(b.pushAudio(packets[2]), .bufferedDrop(discardedVideo: 0, discardedAudio: 1, restarted: false))
        XCTAssertEqual(b.peekAudio()?.firstFrameIndex, packets[1].firstFrameIndex)
    }

    /// W2-D2：缓冲模式（还没连上 / 断线中）满了不是丢新的，而是清空、从下一个关键帧重来——连上时缓冲里永远是"从关键帧起的最近一段"；
    /// 转直播后内容保留、按直播策略丢新的。
    func testW2D2_bufferingRestartsAtKeyframeWhenFull() {
        let q = SendQueue(videoCapacity: 3, audioCapacity: 8)
        let packets = makeAACPackets(frames: 4096, startHostTime: HostTime(nanoseconds: 10_000_000_000), includePreroll: false)
        q.beginBuffering()
        XCTAssertEqual(q.currentMode, .buffering)
        XCTAssertEqual(q.pushVideo(sample(tick: 0, key: false)), .bufferedDrop(discardedVideo: 0, discardedAudio: 0, restarted: false), "队头必须关键帧")
        XCTAssertEqual(q.pushVideo(sample(tick: 1, key: true)), .queued)
        XCTAssertEqual(q.pushAudio(packets[0]), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 2, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 3, key: false)), .queued)
        // 满：清空（3 帧 + 1 包），这帧不是关键帧也没收，等关键帧（调用方去要）
        XCTAssertEqual(q.pushVideo(sample(tick: 4, key: false)), .bufferedDrop(discardedVideo: 3, discardedAudio: 1, restarted: true))
        XCTAssertEqual(q.depth.video, 0)
        XCTAssertEqual(q.depth.audio, 0)
        XCTAssertEqual(q.pushVideo(sample(tick: 5, key: false)), .bufferedDrop(discardedVideo: 0, discardedAudio: 0, restarted: false))
        XCTAssertEqual(q.pushAudio(packets[1]), .queued, "等关键帧期间音频照收（起步对齐时裁）")
        XCTAssertEqual(q.pushVideo(sample(tick: 6, key: true)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 7, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 8, key: false)), .queued)
        // 满且新来的是关键帧：清空后直接收下它
        XCTAssertEqual(q.pushVideo(sample(tick: 9, key: true)), .queuedAfterReset(discardedVideo: 3, discardedAudio: 1))
        XCTAssertEqual(q.peekVideo()?.tick, Tick(9))
        XCTAssertEqual(q.depth.audio, 0)
        // 转直播：内容保留，之后满了按直播策略丢新的
        q.goLive()
        XCTAssertEqual(q.currentMode, .live)
        XCTAssertEqual(q.pushVideo(sample(tick: 10, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 11, key: false)), .queued)
        XCTAssertEqual(q.pushVideo(sample(tick: 12, key: false)), .droppedFull)
        XCTAssertEqual(q.depth.video, 3)
        XCTAssertEqual(q.popVideo()?.tick, Tick(9))
        // 回到缓冲（断线）：清掉没送出的，返回数目
        XCTAssertEqual(q.beginBuffering().video, 2)
        XCTAssertEqual(q.depth.video, 0)
        XCTAssertEqual(q.currentMode, .buffering)
    }

    /// 起步对齐：dtsOffset 模式选最后一个不晚于关键帧的包；nearest 模式选最近的并保留 preroll。
    func testAlignAudio() {
        let packets = makeAACPackets(frames: 1024 * 8, startHostTime: HostTime(nanoseconds: 10_000_000_000), includePreroll: false)
        XCTAssertGreaterThanOrEqual(packets.count, 5)
        let times = packets.map(\.hostTime)
        // 关键帧时刻取第 3 个包之后 5 ms
        let k = times[2] + HostDuration(milliseconds: 5)
        do {
            let q = SendQueue(videoCapacity: 2, audioCapacity: 16)
            q.beginBuffering()
            packets.forEach { _ = q.pushAudio($0) }
            XCTAssertTrue(q.hasAudio(atOrAfter: k))
            let r = q.alignAudio(to: k, nearest: false, preroll: 0)
            XCTAssertEqual(r?.origin, times[2])
            XCTAssertEqual(r?.dropped, 2)
            XCTAssertEqual(q.depth.audio, packets.count - 2)
            XCTAssertEqual(q.peekAudio()?.hostTime, times[2])
        }
        do {
            // nearest：times[2] + 5 ms 离 times[2] 5 ms、离 times[3] 16.3 ms → 选 times[2]；preroll 1 → 保留 times[1]
            let q = SendQueue(videoCapacity: 2, audioCapacity: 16)
            q.beginBuffering()
            packets.forEach { _ = q.pushAudio($0) }
            let r = q.alignAudio(to: k, nearest: true, preroll: 1)
            XCTAssertEqual(r?.origin, times[2])
            XCTAssertEqual(r?.dropped, 1)
            XCTAssertEqual(q.peekAudio()?.hostTime, times[1])
            XCTAssertEqual(q.depth.audio, packets.count - 1)
        }
        do {
            // nearest：关键帧在 times[2] + 15 ms → 离 times[3]（+21.3）只有 6.3 ms → 选 times[3]
            let q = SendQueue(videoCapacity: 2, audioCapacity: 16)
            q.beginBuffering()
            packets.forEach { _ = q.pushAudio($0) }
            let r = q.alignAudio(to: times[2] + HostDuration(milliseconds: 15), nearest: true, preroll: 0)
            XCTAssertEqual(r?.origin, times[3])
            XCTAssertEqual(r?.dropped, 3)
            XCTAssertEqual(q.peekAudio()?.hostTime, times[3])
        }
    }
}
