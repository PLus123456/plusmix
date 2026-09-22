import AudioToolbox
import CoreAudio
import Foundation
import SwitcherContracts

/// 采样率转换（float32 非交错，N 声道，设备采样率 → 48 kHz）。
///
/// **只在泵线程用**（`AudioDeviceInput` 的专用线程），绝不在 IOProc 里调：AudioConverter 会分配、会走锁，
/// 违反设计方案 §3.5。设备能设成 48 kHz 时根本不会建它（见 `AudioDeviceInput.Options.forceSampleRate48k`）。
///
/// 时间戳：转换器有群延迟 + 起头的预充（priming），直接拿输入块的 hostTime 盖在输出块上会整体偏几毫秒
/// （A2 是 ms 级的指标；44.1 k → 48 k 实测偏 0.72 ms）。所以建好之后**在这个转换器实例自己身上**用一个脉冲实测
/// （喂法、每次要的输出帧数都和正式跑的时候一样），量完 `AudioConverterReset` 复位、计数清零，
/// 之后按 `输入帧号 = 输出帧号 / 比值 + latencyInputFrames` 把输出块的首帧映射回设备时间轴。
/// 为什么不能拿另建一个转换器"一次喂 8192 帧"去量：预充的帧数和喂法有关（实测一次喂完量出 0.1 帧、
/// 按 512 帧流式喂是 −31.8 帧），量的喂法必须和用的喂法一致。
/// `@unchecked Sendable`：只有泵线程碰它（建在 sessionQueue、用在泵线程、拆之前先 join 泵线程）。
final class AudioRateConverter: @unchecked Sendable {
    /// 源采样率。
    let sourceRate: Double
    /// 目标采样率（恒 48 kHz）。
    let destinationRate: Double
    /// 声道数。
    let channels: Int
    /// 输出缓冲能装的帧数。
    let maxOutputFrames: Int
    /// 实测群延迟（输入帧；输出第 0 帧对应输入第 latencyInputFrames 帧）。
    private(set) var latencyInputFrames: Double = 0
    /// 累计送进去的输入帧数。
    private(set) var sourceFramesConsumed: UInt64 = 0
    /// 累计取出来的输出帧数。
    private(set) var destinationFramesProduced: UInt64 = 0

    private var converter: AudioConverterRef?
    private var outputPlanes: [UnsafeMutablePointer<Float>] = []
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let outputPlaneTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private var feed = Feed()

    /// 输入回调的上下文：一次 Fill 只喂一块。
    private final class Feed {
        var planes: UnsafePointer<UnsafePointer<Float>>?
        var frames: Int = 0
        var delivered = false
        var list: UnsafeMutableAudioBufferListPointer?
    }

    enum ConverterError: Error, CustomStringConvertible {
        case create(OSStatus)
        case convert(OSStatus)
        public var description: String {
            switch self {
            case .create(let s): "建采样率转换器失败（OSStatus \(s)）"
            case .convert(let s): "采样率转换失败（OSStatus \(s)）"
            }
        }
    }

    /// float32 非交错的 ASBD。
    static func format(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// - Parameters:
    ///   - measurementBlockFrames: 实测群延迟时用的块大小；传设备的 IO 块大小（正式跑的时候就是它）。0 = 不实测。
    init(sourceRate: Double, channels: Int, maxOutputFrames: Int, measurementBlockFrames: Int = 512) throws {
        precondition(channels >= 1 && maxOutputFrames >= 1)
        self.sourceRate = sourceRate
        self.destinationRate = Double(AudioFormat.sampleRate)
        self.channels = channels
        self.maxOutputFrames = maxOutputFrames
        var source = Self.format(rate: sourceRate, channels: channels)
        var destination = Self.format(rate: destinationRate, channels: channels)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &ref)
        guard status == noErr, let ref else { throw ConverterError.create(status) }
        converter = ref
        var quality = UInt32(kAudioConverterQuality_High)
        AudioConverterSetProperty(ref, kAudioConverterSampleRateConverterQuality, 4, &quality)
        for _ in 0..<channels { outputPlanes.append(.allocate(capacity: maxOutputFrames)) }
        outputList = AudioBufferList.allocate(maximumBuffers: channels)
        outputPlaneTable = .allocate(capacity: channels)
        for c in 0..<channels {
            outputList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxOutputFrames * 4),
                                        mData: UnsafeMutableRawPointer(outputPlanes[c]))
            outputPlaneTable[c] = UnsafePointer(outputPlanes[c])
        }
        if measurementBlockFrames > 0 {
            latencyInputFrames = (try? measureLatencyInPlace(blockFrames: min(measurementBlockFrames, maxOutputFrames))) ?? 0
        }
    }

    /// 在本实例上实测群延迟 + 预充：按 `blockFrames` 一块喂 20 块，第 6 块里放一个脉冲，找输出峰值，
    /// 再 `AudioConverterReset` 复位、计数清零（复位后转换器回到初始状态，正式跑的时候会重走一遍同样的预充）。
    private func measureLatencyInPlace(blockFrames: Int) throws -> Double {
        guard let converter, blockFrames > 0 else { return 0 }
        let impulseBlock = 6
        let impulseOffset = min(100, blockFrames - 1)
        let impulseSourceFrame = impulseBlock * blockFrames + impulseOffset
        let input = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        input.initialize(repeating: 0, count: blockFrames)
        let table = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        defer {
            input.deallocate()
            table.deallocate()
        }
        var c = 0
        while c < channels { table[c] = UnsafePointer(input); c += 1 }
        var peak = 0
        var peakValue: Float = 0
        var produced = 0
        var block = 0
        while block < 20 {
            if block == impulseBlock { input[impulseOffset] = 1 } else if block == impulseBlock + 1 { input[impulseOffset] = 0 }
            try convert(planes: UnsafePointer(table), frameCount: blockFrames) { planes, frames in
                var i = 0
                while i < frames {
                    let v = abs(planes[0][i])
                    if v > peakValue { peakValue = v; peak = produced + i }
                    i += 1
                }
                produced += frames
            }
            block += 1
        }
        AudioConverterReset(converter)
        sourceFramesConsumed = 0
        destinationFramesProduced = 0
        guard peakValue > 1e-3 else { return 0 }
        return Double(impulseSourceFrame) - Double(peak) * sourceRate / destinationRate
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        for p in outputPlanes { p.deallocate() }
        free(outputList.unsafeMutablePointer)
        outputPlaneTable.deallocate()
    }

    /// 把一块输入送进去，取出这次能出的所有帧。`body` 拿到的指针只在回调期间有效。
    /// 返回输出帧数（转换器有内部缓冲，第一块通常少几帧，之后补回来）。
    @discardableResult
    func convert(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int,
                 _ body: (UnsafePointer<UnsafePointer<Float>>, Int) -> Void) throws -> Int {
        guard let converter, frameCount > 0 else { return 0 }
        let inputList = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(inputList.unsafeMutablePointer) }
        for c in 0..<channels {
            inputList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4),
                                       mData: UnsafeMutableRawPointer(mutating: planes[c]))
        }
        feed.planes = planes
        feed.frames = frameCount
        feed.delivered = false
        feed.list = inputList
        var wanted = UInt32(min(maxOutputFrames, Int((Double(frameCount) * destinationRate / sourceRate).rounded(.up)) + 32))
        for c in 0..<channels { outputList[c].mDataByteSize = UInt32(maxOutputFrames * 4) }
        let status = AudioConverterFillComplexBuffer(converter, { _, ioNumberDataPackets, ioData, _, userData in
            let feed = Unmanaged<Feed>.fromOpaque(userData!).takeUnretainedValue()
            guard !feed.delivered, let source = feed.list else {
                ioNumberDataPackets.pointee = 0
                return noErr
            }
            feed.delivered = true
            let destination = UnsafeMutableAudioBufferListPointer(ioData)
            destination.count = source.count
            for c in 0..<source.count { destination[c] = source[c] }
            ioNumberDataPackets.pointee = UInt32(feed.frames)
            return noErr
        }, Unmanaged.passUnretained(feed).toOpaque(), &wanted, outputList.unsafeMutablePointer, nil)
        guard status == noErr else { throw ConverterError.convert(status) }
        let produced = Int(wanted)
        sourceFramesConsumed &+= UInt64(frameCount)
        destinationFramesProduced &+= UInt64(produced)
        if produced > 0 { body(UnsafePointer(outputPlaneTable), produced) }
        return produced
    }

    /// 输出第 `outputFrameIndex` 帧（累计序号）对应的输入帧号（可能是小数）。
    func sourceFrame(forOutputFrame outputFrameIndex: UInt64) -> Double {
        Double(outputFrameIndex) * sourceRate / destinationRate + latencyInputFrames
    }

    /// 测试 / 报告用：新建一个同参数的转换器，按流式喂法量一遍群延迟（输入帧），量完丢掉。
    static func measureLatencyInputFrames(sourceRate: Double, channels: Int = 1, blockFrames: Int = 512) -> Double {
        guard let converter = try? AudioRateConverter(sourceRate: sourceRate, channels: channels,
                                                      maxOutputFrames: max(blockFrames * 2, 1024),
                                                      measurementBlockFrames: blockFrames) else { return 0 }
        return converter.latencyInputFrames
    }
}
