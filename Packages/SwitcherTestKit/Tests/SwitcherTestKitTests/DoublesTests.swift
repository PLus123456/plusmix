import XCTest
import Synchronization
import CoreVideo
import SwitcherContracts
@testable import SwitcherTestKit

/// 帧槽 / 音频环测试替身的语义（契约 §2.3 口径）。它们是后面所有合成源测试的地基，先钉死。
final class DoublesTests: XCTestCase {
    private func makeFrame(_ seq: UInt64, ptsNs: UInt64) -> Frame {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        return Frame(pixelBuffer: pb!, pts: HostTime(nanoseconds: ptsNs), duration: HostDuration(nanoseconds: 16_666_667),
                     color: .bt709Limited, inputNumber: 1, sequence: seq, ingressTime: HostTime(nanoseconds: ptsNs + 1000))
    }

    func testW1A_frameSlotDouble_latestReusedDroppedSemantics() {
        let slot = TestKitFrameSlot(capacity: 3)
        XCTAssertNil(slot.latest(atOrBefore: HostTime(nanoseconds: 1_000_000)))
        slot.push(makeFrame(0, ptsNs: 0))
        slot.push(makeFrame(1, ptsNs: 10_000_000))
        // t = 5 ms：只有第 0 帧合格
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(nanoseconds: 5_000_000))?.sequence, 0)
        // 再取一次同一帧 → reused
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(nanoseconds: 5_000_000))?.sequence, 0)
        var s = slot.stats
        XCTAssertEqual(s.pushed, 2); XCTAssertEqual(s.consumed, 2); XCTAssertEqual(s.reused, 1); XCTAssertEqual(s.dropped, 0)
        // 推 2、3：槽满淘汰第 0 帧（已消费，不算 dropped）
        slot.push(makeFrame(2, ptsNs: 20_000_000))
        slot.push(makeFrame(3, ptsNs: 30_000_000))
        s = slot.stats
        XCTAssertEqual(s.dropped, 0)
        // t = 35 ms：返回第 3 帧，第 1、2 帧从未消费 → dropped 2
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(nanoseconds: 35_000_000))?.sequence, 3)
        s = slot.stats
        XCTAssertEqual(s.dropped, 2); XCTAssertEqual(s.consumed, 3); XCTAssertEqual(s.reused, 1)
        // 推 4、5、6：第 3 帧（已消费）被挤掉不算，第 4 帧从未消费被挤掉算 1
        slot.push(makeFrame(4, ptsNs: 40_000_000))
        slot.push(makeFrame(5, ptsNs: 50_000_000))
        slot.push(makeFrame(6, ptsNs: 60_000_000))
        slot.push(makeFrame(7, ptsNs: 70_000_000))
        XCTAssertEqual(slot.stats.dropped, 3)
        // 没有合格帧时返回 nil 且不清空
        XCTAssertNil(slot.latest(atOrBefore: HostTime(nanoseconds: 1_000)))
        XCTAssertEqual(slot.latest(atOrBefore: HostTime(nanoseconds: 100_000_000))?.sequence, 7)
        XCTAssertEqual(slot.stats.pushed, 8)
    }

    func testW1A_frameSlotDouble_onPushSeesEveryFrame() {
        let slot = TestKitFrameSlot(capacity: 2)
        let seen = Mutex<[UInt64]>([])
        slot.onPush = { f in seen.withLock { $0.append(f.sequence) } }
        for i in 0..<10 { slot.push(makeFrame(UInt64(i), ptsNs: UInt64(i) * 1_000_000)) }
        XCTAssertEqual(seen.withLock { $0 }, Array(0..<10))
    }

    func testW1A_audioRingDouble_layoutAndWriteRead() {
        let ring = TestKitAudioRing(channelCount: 2, capacityFrames: 1024, stampCapacity: 16)
        XCTAssertEqual(ring.raw.pointee.layout_version, UInt32(SW_AUDIO_RING_LAYOUT_VERSION))
        XCTAssertEqual(ring.raw.pointee.channels, 2)
        XCTAssertEqual(ring.raw.pointee.capacity_frames, 1024)
        XCTAssertEqual(Int(bitPattern: UnsafeMutableRawPointer(ring.raw)) % 64, 0, "环头必须 64 字节对齐")
        XCTAssertEqual(ring.availableFrames, 0)

        let n = 256
        let a = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { a.deallocate() }
        let b = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { b.deallocate() }
        for i in 0..<n { a[i] = Float(i); b[i] = Float(-i) }
        let planes = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2); defer { planes.deallocate() }
        planes[0] = UnsafePointer(a); planes[1] = UnsafePointer(b)
        let t = HostTime(nanoseconds: 5_000_000_000)
        XCTAssertEqual(ring.write(planes: UnsafePointer(planes), frameCount: n, hostTime: t), n)
        XCTAssertEqual(ring.availableFrames, n)
        XCTAssertEqual(ring.write(planes: UnsafePointer(planes), frameCount: n, hostTime: t + HostDuration(milliseconds: 5.333)), n)

        let oa = UnsafeMutablePointer<Float>.allocate(capacity: 600); defer { oa.deallocate() }
        let ob = UnsafeMutablePointer<Float>.allocate(capacity: 600); defer { ob.deallocate() }
        let out = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2); defer { out.deallocate() }
        out[0] = oa; out[1] = ob
        // 读 100 帧：首帧 host time = 第一块的 stamp
        var r = ring.read(into: UnsafePointer(out), frameCount: 100)
        XCTAssertEqual(r.framesRead, 100)
        XCTAssertEqual(r.firstFrameHostTime, t)
        XCTAssertEqual(oa[99], 99); XCTAssertEqual(ob[99], -99)
        // 再读 200 帧：跨块，首帧序号 100 → 由第一块 stamp 外推 100/48000 s
        r = ring.read(into: UnsafePointer(out), frameCount: 200)
        XCTAssertEqual(r.framesRead, 200)
        let expected = t + HostDuration(nanoseconds: Int64(100.0 * 1e9 / 48000))
        XCTAssertLessThanOrEqual((r.firstFrameHostTime! - expected).magnitude.ticks, 2)
        XCTAssertEqual(oa[155], 255); XCTAssertEqual(oa[156], 0); XCTAssertEqual(ob[156], 0)
        // 读超：补零并计 underruns
        r = ring.read(into: UnsafePointer(out), frameCount: 600)
        XCTAssertEqual(r.framesRead, 212)
        XCTAssertEqual(oa[212], 0)
        XCTAssertEqual(ring.stats.underruns, 388)
        XCTAssertEqual(ring.stats.framesWritten, 512)
        XCTAssertEqual(ring.stats.framesRead, 512)
        // 写超：环满少写并计 overruns
        for _ in 0..<4 { ring.write(planes: UnsafePointer(planes), frameCount: n, hostTime: t) }
        XCTAssertEqual(ring.write(planes: UnsafePointer(planes), frameCount: n, hostTime: t), 0)
        XCTAssertEqual(ring.stats.overruns, 256)
    }

    func testW1A_spscQueue_pushPopAcrossThreads() {
        let q = SPSCQueue<Int>(capacity: 100)
        XCTAssertEqual(q.capacity, 128)
        let total = 100_000
        let consumerSum = Mutex<Int>(0)
        let done = DispatchSemaphore(value: 0)
        let consumer = Thread {
            var sum = 0, got = 0
            while got < total {
                if let v = q.pop() { sum += v; got += 1 }
            }
            consumerSum.withLock { $0 = sum }
            done.signal()
        }
        consumer.start()
        var i = 0
        while i < total { if q.push(i) { i += 1 } }
        done.wait()
        XCTAssertEqual(consumerSum.withLock { $0 }, (0..<total).reduce(0, +))
        XCTAssertTrue(q.isEmpty)
    }

    func testW1A_splitMix64_deterministicAndBounded() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        for _ in 0..<1000 { XCTAssertEqual(a.next(), b.next()) }
        var sum = 0.0
        for _ in 0..<10_000 {
            let v = a.nextSymmetric(3)
            XCTAssertGreaterThanOrEqual(v, -3); XCTAssertLessThanOrEqual(v, 3)
            sum += v
        }
        XCTAssertLessThan(abs(sum / 10_000), 0.1)
    }
}
