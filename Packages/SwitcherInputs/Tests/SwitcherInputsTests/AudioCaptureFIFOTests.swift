import AudioToolbox
import CoreAudio
import Darwin
import XCTest
import SwitcherContracts
@testable import SwitcherInputs

/// IOProc 本体的单元测试：不需要硬件，自己造 AudioBufferList 直接调 `audioDeviceInputIOProc`。
/// 管声道映射、采样格式、hostTime、交接区满、以及"回调里零分配"（RT 规则的无硬件版本）。
final class AudioCaptureFIFOTests: XCTestCase {
    /// 造一块交错的设备缓冲：第 c 声道第 i 帧 = base(c) + i。
    private final class FakeDeviceBuffer {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutableRawPointer] = []
        init(bufferChannelCounts: [Int], frames: Int, bytesPerSample: Int) {
            list = AudioBufferList.allocate(maximumBuffers: bufferChannelCounts.count)
            for (i, channels) in bufferChannelCounts.enumerated() {
                let bytes = frames * channels * bytesPerSample
                let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
                memset(p, 0, bytes)
                storage.append(p)
                list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes), mData: p)
            }
        }
        deinit {
            for p in storage { p.deallocate() }
            free(list.unsafeMutablePointer)
        }
        func data(_ bufferIndex: Int) -> UnsafeMutableRawPointer { storage[bufferIndex] }
    }

    /// 调一次 IOProc。
    private func fire(_ buffer: AudioCaptureBuffer, _ device: FakeDeviceBuffer, hostTime: UInt64, sampleTime: Double = 0,
                      hostTimeValid: Bool = true) {
        var input = AudioTimeStamp()
        input.mHostTime = hostTime
        input.mSampleTime = sampleTime
        input.mFlags = hostTimeValid ? [.hostTimeValid, .sampleTimeValid] : [.sampleTimeValid]
        var now = input
        var outputTime = input
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }
        outputList[0] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        _ = audioDeviceInputIOProc(0, &now, UnsafePointer(device.list.unsafeMutablePointer), &input,
                                   outputList.unsafeMutablePointer, &outputTime, UnsafeMutableRawPointer(buffer.fifo))
    }

    /// 取出交接区里的块。
    private func drain(_ buffer: AudioCaptureBuffer) -> [(frames: Int, header: AudioCaptureBlockHeader, planes: [[Float]])] {
        let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: buffer.channels)
        defer { table.deallocate() }
        var out: [(Int, AudioCaptureBlockHeader, [[Float]])] = []
        buffer.drain(planeTable: table) { planes, frames, header in
            var copied: [[Float]] = []
            for c in 0..<buffer.channels { copied.append(Array(UnsafeBufferPointer(start: planes[c], count: frames))) }
            out.append((frames, header, copied))
        }
        return out
    }

    // MARK: 交错 float32 + 声道映射

    func testIOProc_interleavedFloat32_mapsRequestedChannels() {
        let frames = 8
        let device = FakeDeviceBuffer(bufferChannelCounts: [4], frames: frames, bytesPerSample: 4)
        let samples = device.data(0).assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            for c in 0..<4 { samples[i * 4 + c] = Float(c) * 100 + Float(i) }
        }
        // 环 2 声道，取设备的第 2、0 路
        let buffer = AudioCaptureBuffer(channels: 2, deviceChannels: 4, channelMap: [2, 0], bufferChannelCounts: [4],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer, device, hostTime: 1_234_567, sampleTime: 4096)
        let blocks = drain(buffer)
        XCTAssertEqual(blocks.count, 1)
        guard let block = blocks.first else { return }
        XCTAssertEqual(block.frames, frames)
        XCTAssertEqual(block.header.hostTime, 1_234_567)
        XCTAssertEqual(block.header.sampleTime, 4096)
        XCTAssertEqual(block.header.status, 0)
        XCTAssertEqual(block.planes[0], (0..<frames).map { Float(200 + $0) })
        XCTAssertEqual(block.planes[1], (0..<frames).map { Float($0) })
        XCTAssertEqual(buffer.counters.blocksProduced, 1)
        XCTAssertEqual(buffer.counters.blocksDropped, 0)
    }

    // MARK: 非交错 float32（每声道一个 buffer）

    func testIOProc_nonInterleavedFloat32_copiesPlanes() {
        let frames = 16
        let device = FakeDeviceBuffer(bufferChannelCounts: [1, 1], frames: frames, bytesPerSample: 4)
        for c in 0..<2 {
            let samples = device.data(c).assumingMemoryBound(to: Float.self)
            for i in 0..<frames { samples[i] = Float(c) * 10 + Float(i) }
        }
        let buffer = AudioCaptureBuffer(channels: 2, deviceChannels: 2, channelMap: [0, 1], bufferChannelCounts: [1, 1],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer, device, hostTime: 42)
        let blocks = drain(buffer)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.planes[0], (0..<frames).map { Float($0) })
        XCTAssertEqual(blocks.first?.planes[1], (0..<frames).map { Float(10 + $0) })
    }

    // MARK: 单声道设备复制到所有声道；设备声道比环少时复制最后一路

    func testIOProc_monoDeviceIsCopiedToEveryChannel() {
        let frames = 4
        let device = FakeDeviceBuffer(bufferChannelCounts: [1], frames: frames, bytesPerSample: 4)
        let samples = device.data(0).assumingMemoryBound(to: Float.self)
        for i in 0..<frames { samples[i] = Float(i) + 0.5 }
        let buffer = AudioCaptureBuffer(channels: 2, deviceChannels: 1, channelMap: [0, 1], bufferChannelCounts: [1],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer, device, hostTime: 7)
        let blocks = drain(buffer)
        XCTAssertEqual(blocks.first?.planes[0], blocks.first?.planes[1])
        XCTAssertEqual(blocks.first?.planes[0], (0..<frames).map { Float($0) + 0.5 })
    }

    // MARK: int16 / int32 归一化

    func testIOProc_int16AndInt32AreNormalized() {
        let frames = 3
        let device16 = FakeDeviceBuffer(bufferChannelCounts: [2], frames: frames, bytesPerSample: 2)
        let s16 = device16.data(0).assumingMemoryBound(to: Int16.self)
        for i in 0..<frames { s16[i * 2] = Int16(16384); s16[i * 2 + 1] = Int16(-32768) }
        let buffer16 = AudioCaptureBuffer(channels: 2, deviceChannels: 2, channelMap: [0, 1], bufferChannelCounts: [2],
                                          sampleFormat: .int16, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer16, device16, hostTime: 1)
        let b16 = drain(buffer16)
        XCTAssertEqual(b16.first?.planes[0], [Float](repeating: 0.5, count: frames))
        XCTAssertEqual(b16.first?.planes[1], [Float](repeating: -1, count: frames))

        let device32 = FakeDeviceBuffer(bufferChannelCounts: [1], frames: frames, bytesPerSample: 4)
        let s32 = device32.data(0).assumingMemoryBound(to: Int32.self)
        for i in 0..<frames { s32[i] = Int32(1 << 29) }
        let buffer32 = AudioCaptureBuffer(channels: 1, deviceChannels: 1, channelMap: [0], bufferChannelCounts: [1],
                                          sampleFormat: .int32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer32, device32, hostTime: 1)
        XCTAssertEqual(drain(buffer32).first?.planes[0], [Float](repeating: 0.25, count: frames))
    }

    // MARK: hostTime 标志位无效时退回"到达 − 块时长"并记账

    func testIOProc_invalidHostTimeFallsBackAndCounts() {
        let frames = 480
        let device = FakeDeviceBuffer(bufferChannelCounts: [1], frames: frames, bytesPerSample: 4)
        let buffer = AudioCaptureBuffer(channels: 1, deviceChannels: 1, channelMap: [0], bufferChannelCounts: [1],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 512, slotCount: 4)
        let before = HostClock.now()
        fire(buffer, device, hostTime: 0, hostTimeValid: false)
        let after = HostClock.now()
        let blocks = drain(buffer)
        XCTAssertEqual(buffer.counters.hostTimeFallbacks, 1)
        guard let header = blocks.first?.header else { return XCTFail("没有块") }
        XCTAssertEqual(header.status & 2, 2)
        let blockDuration = HostDuration(seconds: Double(frames) / 48000)
        XCTAssertGreaterThanOrEqual(header.hostTime, (before - blockDuration).ticks)
        XCTAssertLessThanOrEqual(header.hostTime, after.ticks)
    }

    // MARK: 交接区满 = 丢块并记账（泵线程没跟上）

    func testIOProc_fifoFullDropsBlocksAndCounts() {
        let frames = 32
        let device = FakeDeviceBuffer(bufferChannelCounts: [1], frames: frames, bytesPerSample: 4)
        let buffer = AudioCaptureBuffer(channels: 1, deviceChannels: 1, channelMap: [0], bufferChannelCounts: [1],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        for k in 0..<6 { fire(buffer, device, hostTime: UInt64(1000 + k)) }
        let counters = buffer.counters
        XCTAssertEqual(counters.blocksProduced, 4)
        XCTAssertEqual(counters.blocksDropped, 2)
        XCTAssertEqual(counters.framesDropped, UInt64(2 * frames))
        XCTAssertEqual(drain(buffer).count, 4)
        // 取空之后又能写了
        fire(buffer, device, hostTime: 2000)
        XCTAssertEqual(drain(buffer).count, 1)
    }

    // MARK: 一块比槽还大 = 丢块并记账

    func testIOProc_oversizeBlockIsDropped() {
        let device = FakeDeviceBuffer(bufferChannelCounts: [1], frames: 256, bytesPerSample: 4)
        let buffer = AudioCaptureBuffer(channels: 1, deviceChannels: 1, channelMap: [0], bufferChannelCounts: [1],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 64, slotCount: 4)
        fire(buffer, device, hostTime: 1)
        XCTAssertEqual(buffer.counters.oversizeBlocks, 1)
        XCTAssertEqual(buffer.counters.blocksProduced, 0)
        XCTAssertEqual(drain(buffer).count, 0)
    }

    // MARK: RT —— 回调本体零分配（无硬件版；真设备上的 10 s 版在 AudioDeviceInputTests）

    func testRT_ioProcAllocatesNothing() throws {
        let frames = 512
        let device = FakeDeviceBuffer(bufferChannelCounts: [2], frames: frames, bytesPerSample: 4)
        let buffer = AudioCaptureBuffer(channels: 2, deviceChannels: 2, channelMap: [0, 1], bufferChannelCounts: [2],
                                        sampleFormat: .float32, sampleRate: 48000, slotFrames: 1024, slotCount: 4)
        let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        defer { table.deallocate() }
        // 先跑几次热身（第一次可能有惰性初始化）
        var warm = 0
        while warm < 4 {
            fire(buffer, device, hostTime: UInt64(warm + 1))
            buffer.drain(planeTable: table) { _, _, _ in }
            warm += 1
        }
        // 测量循环里一切预分配：时间戳、输出缓冲表都在外面建好，循环里只调 IOProc 本体
        let timeStamps = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 3)
        timeStamps.initialize(repeating: AudioTimeStamp(), count: 3)
        defer { timeStamps.deallocate() }
        for k in 0..<3 { timeStamps[k].mFlags = [.hostTimeValid, .sampleTimeValid] }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }
        outputList[0] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        let inputList = UnsafePointer(device.list.unsafeMutablePointer)
        let fifo = UnsafeMutableRawPointer(buffer.fifo)
        let calls = 5000
        guard AllocationProbe.start(watching: pthread_mach_thread_np(pthread_self())) else {
            throw XCTSkip("本系统没有 malloc_logger 钩子")
        }
        // 测量循环本身也必须零分配：`for i in 0..<n` 在 debug 里每轮 malloc 一次（见 AudioCaptureFIFO.swift 的注释），所以用 while
        var k = 0
        while k < calls {
            timeStamps[1].mHostTime = UInt64(10_000 + k)
            _ = audioDeviceInputIOProc(0, timeStamps, inputList, timeStamps + 1, outputList.unsafeMutablePointer, timeStamps + 2, fifo)
            buffer.drain(planeTable: table) { _, _, _ in }
            k += 1
        }
        let result = AllocationProbe.stop()
        print("RT（合成 ABL）：\(calls) 次回调，malloc \(result.allocations) 次 / free \(result.deallocations) 次")
        XCTAssertEqual(result.allocations, 0, "IOProc 本体不许分配（设计方案 §3.5、铁律 3）")
    }
}
