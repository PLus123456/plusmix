import XCTest
import SwitcherContracts
@testable import SwitcherAudio

/// 音频环（契约 AudioRing / sw_audio_ring.h）的实现测试：SPSC 语义、回绕、溢出 / 欠载计数、stamp 外推、跨线程。
final class RingTests: XCTestCase {
    /// 时基 1/1：1 tick = 1 ns，48 kHz 下每帧 20833.33 tick
    let tb = MachTimebase(numer: 1, denom: 1)

    func testRing_layoutAndAlignment() {
        let ring = CAudioRing(channelCount: 2, capacityFrames: 1000, stampCapacity: 10, timebase: tb)
        XCTAssertEqual(ring.capacityFrames, 1024, "容量向上取 2 的幂")
        XCTAssertEqual(ring.stampCapacity, 16)
        XCTAssertEqual(ring.channelCount, 2)
        XCTAssertEqual(ring.sampleRate, 48_000)
        XCTAssertEqual(ring.raw.pointee.layout_version, SW_AUDIO_RING_LAYOUT_VERSION)
        XCTAssertEqual(Int(bitPattern: ring.raw) % 64, 0, "环头必须 64 字节对齐")
        XCTAssertEqual(ring.availableFrames, 0)
        XCTAssertEqual(ring.freeFrames, 1024)
        XCTAssertNil(ring.latestStamp)
        XCTAssertEqual(ring.hostTicksPerFrame, 1e9 / 48_000, accuracy: 1e-9)
        let planes = ring.raw.pointee.planes
        XCTAssertNotNil(planes.0); XCTAssertNotNil(planes.1)
        XCTAssertNil(planes.2, "未用声道应为 NULL"); XCTAssertNil(planes.7)
    }

    func testRing_writeReadRoundTripAcrossWrap() {
        let ring = CAudioRing(channelCount: 2, capacityFrames: 4096, stampCapacity: 64, timebase: tb)
        var expectedL = [Float](), expectedR = [Float]()
        var readL = [Float](), readR = [Float]()
        var frame: Float = 0
        // 写 300 读 256，跑 50 轮（净累积 2200 < 4096），写指针绕环 3 圈多
        for k in 0..<50 {
            var l = [Float](), r = [Float]()
            for _ in 0..<300 { l.append(frame); r.append(-frame); frame += 1 }
            let wrote = ring.write([l, r], hostTime: HostTime(ticks: UInt64(k) * 1_000_000))
            XCTAssertEqual(wrote, 300, "第 \(k) 轮环不该满")
            expectedL += l; expectedR += r
            let (planes, res) = ring.read(frameCount: 256)
            XCTAssertEqual(res.framesRead, 256)
            readL += planes[0]; readR += planes[1]
        }
        XCTAssertEqual(readL, Array(expectedL[0..<readL.count]))
        XCTAssertEqual(readR, Array(expectedR[0..<readR.count]))
        let s = ring.stats
        XCTAssertEqual(s.framesWritten, 15_000)
        XCTAssertEqual(s.framesRead, 12_800)
        XCTAssertEqual(s.overruns, 0)
        XCTAssertEqual(s.underruns, 0)
        XCTAssertEqual(ring.availableFrames, 2200)
    }

    func testRing_overrunWritesPartialAndCounts() {
        let ring = CAudioRing(channelCount: 1, capacityFrames: 512, stampCapacity: 8, timebase: tb)
        let block = [Float](repeating: 1, count: 300)
        XCTAssertEqual(ring.write([block], hostTime: .zero), 300)
        XCTAssertEqual(ring.write([block], hostTime: .zero), 212, "只写放得下的")
        XCTAssertEqual(ring.write([block], hostTime: .zero), 0)
        let s = ring.stats
        XCTAssertEqual(s.framesWritten, 512)
        XCTAssertEqual(s.overruns, 88 + 300)
        XCTAssertEqual(ring.freeFrames, 0)
        // 读 100 之后又能写 100
        _ = ring.read(frameCount: 100)
        XCTAssertEqual(ring.write([block], hostTime: .zero), 100)
    }

    func testRing_underrunZeroFillsAndCounts() {
        let ring = CAudioRing(channelCount: 2, capacityFrames: 256, stampCapacity: 8, timebase: tb)
        ring.write([[Float](repeating: 0.5, count: 10), [Float](repeating: -0.5, count: 10)], hostTime: HostTime(ticks: 100))
        let (planes, res) = ring.read(frameCount: 64)
        XCTAssertEqual(res.framesRead, 10)
        XCTAssertEqual(Array(planes[0][0..<10]), [Float](repeating: 0.5, count: 10))
        XCTAssertEqual(Array(planes[0][10..<64]), [Float](repeating: 0, count: 54), "不够的补零")
        XCTAssertEqual(Array(planes[1][10..<64]), [Float](repeating: 0, count: 54))
        XCTAssertEqual(ring.stats.underruns, 54)
        let (_, res2) = ring.read(frameCount: 16)
        XCTAssertEqual(res2.framesRead, 0)
        XCTAssertNil(res2.firstFrameHostTime)
        XCTAssertEqual(ring.stats.underruns, 70)
    }

    func testRing_stampsGiveFirstFrameHostTime() {
        let ring = CAudioRing(channelCount: 1, capacityFrames: 4096, stampCapacity: 16, timebase: tb)
        let tpf = 1e9 / 48_000   // 每帧 20833.33 ns
        // 三块，每块 256 帧，首帧 host time 严格按 48 kHz 排
        for k in 0..<3 {
            ring.write([[Float](repeating: Float(k), count: 256)], hostTime: HostTime(ticks: 1_000_000 + UInt64(Double(k) * 256 * tpf)))
        }
        XCTAssertEqual(ring.latestStamp?.frameIndex, 512)
        XCTAssertEqual(ring.latestStamp?.hostTime.ticks, 1_000_000 + UInt64(512 * tpf))
        // 读 100：首帧 = 第 0 块首帧
        var r = ring.read(frameCount: 100)
        XCTAssertEqual(r.result.firstFrameHostTime?.ticks, 1_000_000)
        // 再读 200：首帧序号 100，在第 0 块里，外推 100 帧
        r = ring.read(frameCount: 200)
        XCTAssertEqual(Double(r.result.firstFrameHostTime!.ticks), 1_000_000 + 100 * tpf, accuracy: 1.0)
        // 再读 300：首帧序号 300，落在第 1 块（首帧 256），外推 44 帧
        r = ring.read(frameCount: 300)
        XCTAssertEqual(Double(r.result.firstFrameHostTime!.ticks), 1_000_000 + 300 * tpf, accuracy: 1.0)
        XCTAssertEqual(ring.hostTime(ofFrame: 700)!.ticks, 1_000_000 + UInt64(512 * tpf) + UInt64((188 * tpf).rounded()))
        // 还没写到的序号也按最新 stamp 外推（估计器用它算"现在该到第几帧"）
        XCTAssertEqual(Double(ring.hostTime(ofFrame: 100_000)!.ticks), 1_000_000 + 100_000 * tpf, accuracy: 1.0)
    }

    func testRing_stampRingWrapsKeepsRecentOnes() {
        let ring = CAudioRing(channelCount: 1, capacityFrames: 65_536, stampCapacity: 8, timebase: tb)
        for k in 0..<100 { ring.write([[Float](repeating: 0, count: 64)], hostTime: HostTime(ticks: UInt64(k) * 10)) }
        XCTAssertEqual(ring.latestStamp?.frameIndex, 99 * 64)
        XCTAssertEqual(ring.latestStamp?.hostTime.ticks, 990)
        // 最近 7 条（stamp_capacity − 1）可查，更早的查不到
        XCTAssertNotNil(ring.hostTime(ofFrame: 93 * 64))
        XCTAssertNil(ring.hostTime(ofFrame: 92 * 64), "被覆盖的 stamp 不许外推（可能撕裂）")
        // 序号在两条 stamp 之间：按较早那条外推
        XCTAssertEqual(ring.hostTime(ofFrame: 95 * 64 + 32)!.ticks, 950 + UInt64((32 * 1e9 / 48_000).rounded()))
    }

    func testRing_spscConcurrentProducerConsumerNoLoss() {
        // 生产者线程连续写 256 帧递增序列，消费者线程读；结束后全部数据按序无缺
        let ring = CAudioRing(channelCount: 1, capacityFrames: 8192, stampCapacity: 64, timebase: tb)
        let total = 256 * 8000
        let producer = Thread {
            var frame: Float = 0
            var buf = [Float](repeating: 0, count: 256)
            while Int(frame) < total {
                for i in 0..<256 { buf[i] = frame + Float(i) }
                let n = ring.write([buf], hostTime: .zero)
                if n == 256 { frame += 256 } else if n > 0 {
                    // 部分写：把没写进去的重新写（测试只验证顺序，实际输入不会这么做）
                    frame += Float(n)
                    var rest = Array(buf[n...])
                    while !rest.isEmpty {
                        let m = ring.write([rest], hostTime: .zero)
                        rest.removeFirst(m)
                        frame += Float(m)
                    }
                }
            }
        }
        var received = 0
        var next: Float = 0
        var mismatches = 0
        producer.start()
        let deadline = Date().addingTimeInterval(20)
        while received < total && Date() < deadline {
            let (planes, res) = ring.read(frameCount: 240)
            for i in 0..<res.framesRead {
                if planes[0][i] != next { mismatches += 1 }
                next += 1
            }
            received += res.framesRead
        }
        XCTAssertEqual(received, total)
        XCTAssertEqual(mismatches, 0)
        // 消费者比生产者快时的欠载在这个测试里是允许的，只验证数据顺序与无丢失
    }
}
