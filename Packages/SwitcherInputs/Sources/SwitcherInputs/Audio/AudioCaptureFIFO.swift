import AudioToolbox
import CoreAudio
import Darwin
import Synchronization
import SwitcherContracts

/// 一块采集音频的头（IOProc 写、泵线程读；纯 POD，没有引用类型）。
struct AudioCaptureBlockHeader {
    /// 本块帧数。
    var frameCount: UInt32 = 0
    /// 0 = 正常；非 0 的位：1 = 有声道取不到数据（已补零）、2 = hostTime 无效（用到达时刻倒推）。
    var status: UInt32 = 0
    /// 块首帧的设备侧时刻（`AudioTimeStamp.mHostTime`，铁律 5）。
    var hostTime: UInt64 = 0
    /// 回调到达时刻（`mach_absolute_time()`），只作诊断（A2 用它和 hostTime 的差）。
    var arrival: UInt64 = 0
    /// 设备采样时钟（`mSampleTime`），只作诊断。
    var sampleTime: Double = 0
}

/// IOProc（实时线程）→ 泵线程 的单生产者单消费者交接区。
///
/// 为什么要它：IOProc 是系统的音频实时线程，规则是无锁、无分配、无日志、无系统调用、无 ARC（设计方案 §3.5、铁律 3）。
/// 注入进来的 `AudioRing` 是 Swift 协议（存在类型派发 + ARC），采样率不是 48 kHz 时还要过 AudioConverter，
/// 两样都不能在回调里做。所以回调只做"打戳 + 按声道映射拷进这块预分配内存"，别的交给泵线程
/// （`AudioDeviceInput` 的 `pumpThread`，普通线程，可以锁、可以分配）。
///
/// 结构本身手工分配（`UnsafeMutablePointer<AudioCaptureFIFO>`），回调只经这个裸指针访问：不碰任何 Swift 对象，
/// 也就没有 retain / release。跨线程的发布靠 `Atomic` 的 acquire / release（与契约 sw_audio_ring.h 规则 4 同一套写法）。
struct AudioCaptureFIFO: ~Copyable {
    /// 采样格式（设备虚拟格式；macOS 上几乎总是 float32）。
    enum SampleFormat: Int32 {
        case float32 = 0, int16 = 1, int32 = 2
        var bytes: Int32 { self == .int16 ? 2 : 4 }
    }

    // ---- 生产者 / 消费者计数（acquire-release）----
    /// 累计写入的块数（生产者 release 发布）。
    let writeIndex = Atomic<UInt64>(0)
    /// 累计读走的块数（消费者 release 发布）。
    let readIndex = Atomic<UInt64>(0)
    // ---- 诊断计数（relaxed）----
    /// 回调次数。
    let callbacks = Atomic<UInt64>(0)
    /// 交接区满而丢掉的块 / 帧（泵线程没跟上）。
    let blocksDropped = Atomic<UInt64>(0)
    let framesDropped = Atomic<UInt64>(0)
    /// 一块比槽还大（设备中途改了 buffer size）而丢掉的块。
    let oversizeBlocks = Atomic<UInt64>(0)
    /// 没有输入缓冲 / 帧数为 0 的回调。
    let emptyCallbacks = Atomic<UInt64>(0)
    /// hostTime 标志位无效、用到达时刻倒推的块数。
    let hostTimeFallbacks = Atomic<UInt64>(0)
    /// 回调线程的 mach 端口（RT 分配探针用；第一次回调时填）。
    let callbackThread = Atomic<UInt32>(0)

    // ---- 常量（建好后不改）----
    /// 槽数（2 的幂）。
    var slotCount: UInt64 = 0
    /// slotCount − 1。
    var slotMask: UInt64 = 0
    /// 每槽能装的帧数。
    var slotFrames: Int = 0
    /// 目标声道数（= 环的声道数）。
    var channels: Int = 0
    /// 设备输入声道数。
    var deviceChannels: Int = 0
    /// 设备采样格式。
    var sampleFormat: Int32 = 0
    /// 一个样本的字节数。
    var bytesPerSample: Int = 0
    /// 设备采样率下每帧多少 host tick（hostTime 无效时倒推用）。
    var hostTicksPerFrame: Double = 0

    // ---- 预分配的存储 ----
    /// slotCount 条块头。
    var headers: UnsafeMutablePointer<AudioCaptureBlockHeader>
    /// slotCount × channels × slotFrames 个 float（非交错）。
    var samples: UnsafeMutablePointer<Float>
    /// 每个目标声道取设备的第几个 AudioBuffer。
    var srcBuffer: UnsafeMutablePointer<Int32>
    /// 每个目标声道在那个 AudioBuffer 内的声道下标。
    var srcChannel: UnsafeMutablePointer<Int32>
}

/// IOProc 侧的诊断计数（探针 / 报告用）。
public struct AudioCaptureCounters: Hashable, Sendable {
    /// IOProc 被调用的次数。
    public var callbacks: UInt64 = 0
    /// 回调写进交接区的块数。
    public var blocksProduced: UInt64 = 0
    /// 泵线程取走的块数。
    public var blocksConsumed: UInt64 = 0
    /// 交接区满而丢掉的块数（泵线程没跟上）。
    public var blocksDropped: UInt64 = 0
    /// 丢掉的帧数。
    public var framesDropped: UInt64 = 0
    /// 一块比槽还大而丢掉的块数（设备中途改了 IO 块大小）。
    public var oversizeBlocks: UInt64 = 0
    /// 没有输入缓冲 / 帧数为 0 的回调次数。
    public var emptyCallbacks: UInt64 = 0
    /// hostTime 标志位无效、用到达时刻倒推的块数。
    public var hostTimeFallbacks: UInt64 = 0
    public init() {}
    init(callbacks: UInt64, blocksProduced: UInt64, blocksConsumed: UInt64, blocksDropped: UInt64,
         framesDropped: UInt64, oversizeBlocks: UInt64, emptyCallbacks: UInt64, hostTimeFallbacks: UInt64) {
        self.callbacks = callbacks
        self.blocksProduced = blocksProduced
        self.blocksConsumed = blocksConsumed
        self.blocksDropped = blocksDropped
        self.framesDropped = framesDropped
        self.oversizeBlocks = oversizeBlocks
        self.emptyCallbacks = emptyCallbacks
        self.hostTimeFallbacks = hostTimeFallbacks
    }
}

/// 拥有 `AudioCaptureFIFO` 的那块内存；负责分配 / 释放和（泵线程侧的）读。
final class AudioCaptureBuffer: @unchecked Sendable {
    /// 传给 IOProc 的 clientData 就是它。
    let fifo: UnsafeMutablePointer<AudioCaptureFIFO>
    let channels: Int
    let slotFrames: Int
    let slotCount: Int

    /// - Parameters:
    ///   - channelMap: 目标声道 d 取设备的哪一路（长度 = channels，值是设备声道下标）。
    ///   - bufferChannelCounts: 设备输入 AudioBufferList 里每个 buffer 的声道数（交错设备是 [N]，非交错是 [1, 1, …]）。
    init(channels: Int, deviceChannels: Int, channelMap: [Int], bufferChannelCounts: [Int],
         sampleFormat: AudioCaptureFIFO.SampleFormat, sampleRate: Double, slotFrames: Int, slotCount: Int) {
        precondition(channels >= 1 && slotFrames >= 1 && slotCount >= 2 && slotCount & (slotCount - 1) == 0)
        self.channels = channels
        self.slotFrames = slotFrames
        self.slotCount = slotCount
        let headers = UnsafeMutablePointer<AudioCaptureBlockHeader>.allocate(capacity: slotCount)
        headers.initialize(repeating: AudioCaptureBlockHeader(), count: slotCount)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: slotCount * channels * slotFrames)
        samples.initialize(repeating: 0, count: slotCount * channels * slotFrames)
        let srcBuffer = UnsafeMutablePointer<Int32>.allocate(capacity: channels)
        let srcChannel = UnsafeMutablePointer<Int32>.allocate(capacity: channels)
        // 设备声道号 → (第几个 buffer, buffer 内第几路)
        for d in 0..<channels {
            let wanted = d < channelMap.count ? channelMap[d] : max(deviceChannels - 1, 0)
            var remaining = min(max(wanted, 0), max(deviceChannels - 1, 0))
            var bufferIndex = -1
            var inBuffer = 0
            for (i, n) in bufferChannelCounts.enumerated() {
                if remaining < n { bufferIndex = i; inBuffer = remaining; break }
                remaining -= n
            }
            srcBuffer[d] = Int32(bufferIndex)
            srcChannel[d] = Int32(inBuffer)
        }
        var value = AudioCaptureFIFO(headers: headers, samples: samples, srcBuffer: srcBuffer, srcChannel: srcChannel)
        value.slotCount = UInt64(slotCount)
        value.slotMask = UInt64(slotCount - 1)
        value.slotFrames = slotFrames
        value.channels = channels
        value.deviceChannels = deviceChannels
        value.sampleFormat = sampleFormat.rawValue
        value.bytesPerSample = Int(sampleFormat.bytes)
        value.hostTicksPerFrame = sampleRate > 0 ? Double(HostDuration(seconds: 1).ticks) / sampleRate : 0
        fifo = .allocate(capacity: 1)
        fifo.initialize(to: value)
    }

    deinit {
        fifo.pointee.headers.deallocate()
        fifo.pointee.samples.deallocate()
        fifo.pointee.srcBuffer.deallocate()
        fifo.pointee.srcChannel.deallocate()
        fifo.deinitialize(count: 1)
        fifo.deallocate()
    }

    /// 回调线程的 mach 端口（还没回调过 = 0）。
    var callbackThread: UInt32 { fifo.pointee.callbackThread.load(ordering: .relaxed) }

    /// 诊断计数快照。
    var counters: AudioCaptureCounters {
        AudioCaptureCounters(callbacks: fifo.pointee.callbacks.load(ordering: .relaxed),
                 blocksProduced: fifo.pointee.writeIndex.load(ordering: .acquiring),
                 blocksConsumed: fifo.pointee.readIndex.load(ordering: .relaxed),
                 blocksDropped: fifo.pointee.blocksDropped.load(ordering: .relaxed),
                 framesDropped: fifo.pointee.framesDropped.load(ordering: .relaxed),
                 oversizeBlocks: fifo.pointee.oversizeBlocks.load(ordering: .relaxed),
                 emptyCallbacks: fifo.pointee.emptyCallbacks.load(ordering: .relaxed),
                 hostTimeFallbacks: fifo.pointee.hostTimeFallbacks.load(ordering: .relaxed))
    }

    /// 消费者（泵线程）：把攒下的块逐块交给 `body`（planes 指向本块的各声道平面，只在 body 内有效）。
    /// 返回处理的块数。
    @discardableResult
    func drain(planeTable: UnsafeMutablePointer<UnsafePointer<Float>>,
               _ body: (UnsafePointer<UnsafePointer<Float>>, Int, AudioCaptureBlockHeader) -> Void) -> Int {
        var r = fifo.pointee.readIndex.load(ordering: .relaxed)
        let w = fifo.pointee.writeIndex.load(ordering: .acquiring)
        var handled = 0
        while r < w {
            let slot = Int(r & fifo.pointee.slotMask)
            let header = fifo.pointee.headers[slot]
            let base = fifo.pointee.samples + slot * channels * slotFrames
            var c = 0
            while c < channels { planeTable[c] = UnsafePointer(base + c * slotFrames); c += 1 }
            body(UnsafePointer(planeTable), Int(header.frameCount), header)
            r += 1
            handled += 1
            // 每块都发布一次，生产者随时有位置
            fifo.pointee.readIndex.store(r, ordering: .releasing)
        }
        return handled
    }
}

/// IOProc 本体：**实时线程**。只做"打戳 + 按声道映射把样本拷进交接区"。
///
/// 不许出现的东西：分配、锁、日志、系统调用、Swift 对象（ARC）。这里只有裸指针算术、`mach_absolute_time()`、
/// `pthread_mach_thread_np()` 和原子量——`testRT_audioDeviceCallbackAllocatesNothing` 用 malloc 钩子按线程钉死 0 次分配。
let audioDeviceInputIOProc: AudioDeviceIOProc = { _, _, inInputData, inInputTime, _, _, clientData in
    guard let clientData else { return noErr }
    let fifo = clientData.assumingMemoryBound(to: AudioCaptureFIFO.self)
    let arrival = mach_absolute_time()
    fifo.pointee.callbacks.add(1, ordering: .relaxed)
    if fifo.pointee.callbackThread.load(ordering: .relaxed) == 0 {
        fifo.pointee.callbackThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    }

    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    let bufferCount = list.count
    guard bufferCount > 0 else {
        fifo.pointee.emptyCallbacks.add(1, ordering: .relaxed)
        return noErr
    }
    let bytesPerSample = fifo.pointee.bytesPerSample
    let firstBuffer = list[0]
    let firstChannels = Int(firstBuffer.mNumberChannels)
    guard firstChannels > 0 else {
        fifo.pointee.emptyCallbacks.add(1, ordering: .relaxed)
        return noErr
    }
    let frames = Int(firstBuffer.mDataByteSize) / (firstChannels * bytesPerSample)
    guard frames > 0 else {
        fifo.pointee.emptyCallbacks.add(1, ordering: .relaxed)
        return noErr
    }
    guard frames <= fifo.pointee.slotFrames else {
        fifo.pointee.oversizeBlocks.add(1, ordering: .relaxed)
        fifo.pointee.framesDropped.add(UInt64(frames), ordering: .relaxed)
        return noErr
    }
    let w = fifo.pointee.writeIndex.load(ordering: .relaxed)
    let r = fifo.pointee.readIndex.load(ordering: .acquiring)
    guard w - r < fifo.pointee.slotCount else {
        fifo.pointee.blocksDropped.add(1, ordering: .relaxed)
        fifo.pointee.framesDropped.add(UInt64(frames), ordering: .relaxed)
        return noErr
    }

    let slot = Int(w & fifo.pointee.slotMask)
    let channels = fifo.pointee.channels
    let slotFrames = fifo.pointee.slotFrames
    let base = fifo.pointee.samples + slot * channels * slotFrames
    let format = fifo.pointee.sampleFormat
    var status: UInt32 = 0
    // 注意：这里全部用 while 循环。`for i in 0..<n`（Range 迭代）在 debug 构建（-Onone）里每轮会 malloc + free 一次
    // ——探针实测（reports/w2-inputs-2.md §1.2），while 循环和 stride 不会。实时回调里不许有这个。
    var d = 0
    while d < channels {
        let destination = base + d * slotFrames
        let bufferIndex = Int(fifo.pointee.srcBuffer[d])
        guard bufferIndex >= 0, bufferIndex < bufferCount, let data = list[bufferIndex].mData else {
            destination.update(repeating: 0, count: frames)
            status |= 1
            d += 1
            continue
        }
        let stride = Int(list[bufferIndex].mNumberChannels)
        let offset = Int(fifo.pointee.srcChannel[d])
        var i = 0
        switch format {
        case AudioCaptureFIFO.SampleFormat.float32.rawValue:
            let source = data.assumingMemoryBound(to: Float.self) + offset
            if stride == 1 {
                destination.update(from: source, count: frames)
            } else {
                while i < frames { destination[i] = source[i * stride]; i += 1 }
            }
        case AudioCaptureFIFO.SampleFormat.int16.rawValue:
            let source = data.assumingMemoryBound(to: Int16.self) + offset
            while i < frames { destination[i] = Float(source[i * stride]) * (1.0 / 32768.0); i += 1 }
        default:
            let source = data.assumingMemoryBound(to: Int32.self) + offset
            while i < frames { destination[i] = Float(source[i * stride]) * (1.0 / 2147483648.0); i += 1 }
        }
        d += 1
    }

    // 块首帧时刻：设备给的 mHostTime（铁律 5）。标志位没置时退回"到达时刻 − 本块时长"，并计数。
    var hostTime = inInputTime.pointee.mHostTime
    if inInputTime.pointee.mFlags.contains(.hostTimeValid), hostTime != 0 {
    } else {
        hostTime = arrival &- UInt64(Double(frames) * fifo.pointee.hostTicksPerFrame)
        fifo.pointee.hostTimeFallbacks.add(1, ordering: .relaxed)
        status |= 2
    }
    fifo.pointee.headers[slot] = AudioCaptureBlockHeader(frameCount: UInt32(frames), status: status, hostTime: hostTime,
                                                         arrival: arrival, sampleTime: inInputTime.pointee.mSampleTime)
    fifo.pointee.writeIndex.store(w &+ 1, ordering: .releasing)
    return noErr
}
