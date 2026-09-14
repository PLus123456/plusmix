import XCTest
import CoreAudio
import SwitcherContracts
@testable import SwitcherAudio
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 直接调 sw_device_ioproc（不用真设备、不要权限）：交错 / 非交错设备布局的散布与收集、输入写环带 host time、
/// 未映射通道清零、时间戳无 HostTimeValid 时的兜底。
final class IOProcTests: XCTestCase {

    /// 造一个 AudioBufferList：buffers[i] = (声道数, 帧数) 的交错 float 缓冲。返回指针与释放闭包。
    func makeABL(_ buffers: [(channels: Int, frames: Int)]) -> (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutablePointer<Float>], () -> Void) {
        let abl = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))
        abl.count = buffers.count      // 0 个 buffer = 没有这个方向（HAL 对纯输出设备就这么传）
        var datas = [UnsafeMutablePointer<Float>]()
        for (i, b) in buffers.enumerated() {
            let n = b.channels * b.frames
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            datas.append(p)
            abl[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(p))
        }
        return (abl.unsafeMutablePointer, datas, { for p in datas { p.deallocate() }; free(abl.unsafeMutablePointer) })
    }

    func timestamp(host: UInt64, sample: Double, valid: Bool = true) -> AudioTimeStamp {
        var ts = AudioTimeStamp()
        ts.mSampleTime = sample
        ts.mHostTime = host
        ts.mFlags = valid ? [.sampleTimeValid, .hostTimeValid] : [.sampleTimeValid]
        return ts
    }

    /// 输出：Master 恒定 0.25（单声道输入 pan −1 → 只在 L）散到"1 个 buffer 2 声道交错"（内置扬声器布局）；HP 映射到不存在的通道被忽略。
    func testIOProc_outputScatterInterleavedStereo() {
        let mixer = AudioMixer()
        let src = OfflineAudioSource(channels: 1, t0: HostClock.now(), generator: { _, _, n, buf in for i in 0..<n { buf[i] = 0.25 } })
        mixer.attach(ring: src.ring, toSlot: 0, resampling: .bypass)
        mixer.setPan(slot: 0, -1)
        let client = sw_device_client_create(mixer.context, 4096)!
        defer { sw_device_client_destroy(client) }
        var layout = [sw_channel_location(buffer: 0, offset: 0, stride: 2), sw_channel_location(buffer: 0, offset: 1, stride: 2)]
        layout.withUnsafeMutableBufferPointer { sw_device_client_set_output_layout(client, $0.baseAddress, 2) }
        var map: [Int32] = [0, 1, -1, -1, -1, -1, 2, 3]   // HP → 2,3 不存在
        map.withUnsafeMutableBufferPointer { sw_device_client_set_output_map(client, $0.baseAddress) }
        let (outABL, outData, freeOut) = makeABL([(2, 256)])
        defer { freeOut() }
        let (inABL, _, freeIn) = makeABL([])
        defer { freeIn() }
        // 先喂够环，再跑 200 块让增益 / 声像到位
        var host: UInt64 = 1_000_000_000
        for k in 0..<200 {
            for _ in 0..<2 { src.writeBlock() }
            var now = timestamp(host: host, sample: Double(k * 256))
            var inT = timestamp(host: host, sample: Double(k * 256))
            var outT = timestamp(host: host + 152_000, sample: Double(k * 256))
            let st = sw_device_ioproc(1, &now, inABL, &inT, outABL, &outT, UnsafeMutableRawPointer(client))
            XCTAssertEqual(st, noErr)
            host += 128_000
        }
        // 交错：偶数位 L = 0.25，奇数位 R = 0
        for i in 0..<256 {
            XCTAssertEqual(outData[0][2 * i], 0.25, accuracy: 1e-5, "L 样本 \(i)")
            XCTAssertEqual(outData[0][2 * i + 1], 0, accuracy: 1e-6, "R 样本 \(i)")
        }
        var cs = sw_device_client_stats()
        sw_device_client_copy_stats(client, &cs)
        XCTAssertEqual(cs.callbacks, 200)
        XCTAssertEqual(cs.frames, 200 * 256)
        XCTAssertEqual(cs.last_frames, 256)
        XCTAssertEqual(cs.timestamp_fallbacks, 0)
        XCTAssertEqual(mixer.stats.lastHostTime.ticks, host - 128_000 + 152_000, "混音块的 host time = inOutputTime")
    }

    /// 输出到"每声道一个 buffer"（非交错设备）的 4 声道设备：Master → 0,1，HP → 2,3；未映射通道写 0。
    func testIOProc_outputScatterNonInterleavedFourChannels() {
        let mixer = AudioMixer()
        let src = OfflineAudioSource(channels: 2, t0: HostClock.now(), generator: { c, _, n, buf in for i in 0..<n { buf[i] = c == 0 ? 0.5 : -0.5 } })
        mixer.attach(ring: src.ring, toSlot: 0, resampling: .bypass)
        mixer.setRouting(slot: 0, BusRouting(master: true, headphones: true))
        let client = sw_device_client_create(mixer.context, 4096)!
        defer { sw_device_client_destroy(client) }
        var layout = (0..<6).map { sw_channel_location(buffer: UInt32($0), offset: 0, stride: 1) }
        layout.withUnsafeMutableBufferPointer { sw_device_client_set_output_layout(client, $0.baseAddress, 6) }
        var map: [Int32] = [0, 1, -1, -1, -1, -1, 2, 3]
        map.withUnsafeMutableBufferPointer { sw_device_client_set_output_map(client, $0.baseAddress) }
        let (outABL, outData, freeOut) = makeABL(Array(repeating: (1, 128), count: 6))
        defer { freeOut() }
        for p in outData { for i in 0..<128 { p[i] = 9 } }   // 脏数据，未映射通道应被清零
        let (inABL, _, freeIn) = makeABL([])
        defer { freeIn() }
        var host: UInt64 = 5_000_000
        for k in 0..<200 {
            src.writeBlock()
            var now = timestamp(host: host, sample: Double(k * 128))
            var inT = now
            var outT = timestamp(host: host + 100_000, sample: Double(k * 128))
            _ = sw_device_ioproc(1, &now, inABL, &inT, outABL, &outT, UnsafeMutableRawPointer(client))
            host += 64_000
        }
        XCTAssertEqual(outData[0][10], 0.5, accuracy: 1e-5)     // Master L
        XCTAssertEqual(outData[1][10], -0.5, accuracy: 1e-5)    // Master R
        XCTAssertEqual(outData[2][10], 0.5, accuracy: 1e-5)     // HP L
        XCTAssertEqual(outData[3][10], -0.5, accuracy: 1e-5)    // HP R
        XCTAssertEqual(outData[4][10], 0)                        // 未映射：清零
        XCTAssertEqual(outData[5][10], 0)
    }

    /// 输入：设备 4 声道交错，环取通道 2、0 → 环声道 0、1；stamps = inInputTime 的 host time；无 HostTimeValid 时用进入时刻并计数。
    func testIOProc_inputGatherWritesRingWithStamps() {
        let ring = CAudioRing(channelCount: 2, capacityFrames: 4096, stampCapacity: 64)
        let client = sw_device_client_create(nil, 4096)!
        defer { sw_device_client_destroy(client) }
        var layout = (0..<4).map { sw_channel_location(buffer: 0, offset: UInt32($0), stride: 4) }
        layout.withUnsafeMutableBufferPointer { sw_device_client_set_input_layout(client, $0.baseAddress, 4) }
        var map: [Int32] = [2, 0]
        map.withUnsafeMutableBufferPointer { sw_device_client_set_input_map(client, $0.baseAddress, 2) }
        sw_device_client_set_input_ring(client, ring.raw)
        let (inABL, inData, freeIn) = makeABL([(4, 256)])
        defer { freeIn() }
        for i in 0..<256 { for c in 0..<4 { inData[0][i * 4 + c] = Float(c * 1000 + i) } }
        let (outABL, _, freeOut) = makeABL([])
        defer { freeOut() }
        var now = timestamp(host: 777_000, sample: 0)
        var inT = timestamp(host: 700_000, sample: 0)
        var outT = timestamp(host: 900_000, sample: 0)
        _ = sw_device_ioproc(1, &now, inABL, &inT, outABL, &outT, UnsafeMutableRawPointer(client))
        XCTAssertEqual(ring.availableFrames, 256)
        XCTAssertEqual(ring.latestStamp?.frameIndex, 0)
        XCTAssertEqual(ring.latestStamp?.hostTime.ticks, 700_000, "输入块的 host time = inInputTime")
        let (planes, _) = ring.read(frameCount: 256)
        for i in 0..<256 {
            XCTAssertEqual(planes[0][i], Float(2000 + i), "环声道 0 ← 设备通道 2")
            XCTAssertEqual(planes[1][i], Float(i), "环声道 1 ← 设备通道 0")
        }
        // 没有 HostTimeValid：用回调进入时刻兜底并计数
        var inT2 = timestamp(host: 0, sample: 256, valid: false)
        let before = HostClock.now().ticks
        _ = sw_device_ioproc(1, &now, inABL, &inT2, outABL, &outT, UnsafeMutableRawPointer(client))
        let after = HostClock.now().ticks
        var cs = sw_device_client_stats()
        sw_device_client_copy_stats(client, &cs)
        XCTAssertEqual(cs.timestamp_fallbacks, 1)
        XCTAssertEqual(cs.input_frames_written, 512)
        let t = ring.latestStamp!.hostTime.ticks
        XCTAssertTrue(t >= before && t <= after, "兜底时间戳应是回调进入时刻")
        // 环满：多余的丢并计 overruns
        for _ in 0..<20 { _ = sw_device_ioproc(1, &now, inABL, &inT, outABL, &outT, UnsafeMutableRawPointer(client)) }
        sw_device_client_copy_stats(client, &cs)
        XCTAssertGreaterThan(cs.input_overruns, 0)
        XCTAssertEqual(ring.stats.overruns, cs.input_overruns)
        sw_device_client_set_input_ring(client, nil)
        _ = sw_device_ioproc(1, &now, inABL, &inT, outABL, &outT, UnsafeMutableRawPointer(client))
        XCTAssertEqual(ring.stats.framesWritten + ring.stats.overruns, cs.input_frames_written + cs.input_overruns + 0, "摘掉环后不再写")
    }
}
