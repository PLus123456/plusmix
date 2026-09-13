import AudioToolbox
import CoreMedia
import Foundation
import SwitcherContracts

/// 编码器交出的一个 AAC 包（1024 帧）。
public struct EncodedAudioPacket: @unchecked Sendable {
    /// 压缩样本（一个包），PTS = 包首样本的 host time（绝对，纳秒 timescale 1e9）。
    public let sampleBuffer: CMSampleBuffer
    /// 包首样本在输入流里的序号（第一个输入样本 = 0；编码器 priming 使前几个包为负）。
    public let firstFrameIndex: Int64
    /// 包首样本对应的 host time（按输入块的时间戳插值）。
    public let hostTime: HostTime
    /// 字节数。
    public let byteCount: Int
    /// 包内没有任何真实样本（全是 priming 的预卷）。推流可以直接丢；写文件用 trim。
    public let isPreroll: Bool
}

/// AAC 编码器（AudioToolbox AudioConverter，设计方案 §8）。输入 Master 块（非交错 float32 48 kHz）+ 块首样本 host time。
///
/// 时间：内部按样本计数；每个输入块的 host time 存进一个小 stamp 环（同 sw_audio_ring 的思路），
/// 包的 host time = 最近一条不晚于包首样本的 stamp 的时间 + 样本差 / 采样率。输入应当连续（混音器输出天然连续）。
/// priming：AAC-LC 编码器有 2112 帧前置延迟（`primingFrames`），第 k 个包覆盖输入样本 [1024k − priming, 1024k − priming + 1024)。
///
/// 线程：`encode` / `finish` 在一个非实时线程上串行调（AudioConverter 不是线程安全的）；`output` 在同一线程同步回调。
/// 不给 Recorder 用（原因见报告探针 7：AVAssetWriter 对 AAC 直通的 priming 模型），给推流（W2-D）用。
public final class AudioEncoder: @unchecked Sendable {
    /// 参数。
    public struct Configuration: Hashable, Sendable {
        /// 采样率（48000）。
        public var sampleRate: Int
        /// 声道数（1–8）。
        public var channelCount: Int
        /// 码率（bit/s）。
        public var bitrateBps: Int
        public init(sampleRate: Int = AudioFormat.sampleRate, channelCount: Int = 2, bitrateBps: Int = 160_000) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitrateBps = bitrateBps
        }
    }

    /// 错误。
    public enum Error: Swift.Error, Equatable {
        case converterCreateFailed(OSStatus)
        case propertyFailed(String, OSStatus)
        case formatDescriptionFailed(OSStatus)
    }

    public let configuration: Configuration
    /// 输出格式描述（含 magic cookie），给 AVAssetWriter / 推流封装当 hint。
    public let formatDescription: CMAudioFormatDescription
    /// 编码器前置延迟（帧）。
    public let primingFrames: Int
    /// 每包帧数（AAC-LC = 1024）。
    public let framesPerPacket: Int
    /// 每编出一个包调一次（encode 的调用线程上同步调）。
    public var output: (@Sendable (EncodedAudioPacket) -> Void)?

    private let converter: AudioConverterRef
    private let maxPacketBytes: Int
    private let outBuffer: UnsafeMutableRawPointer
    // 待编码 PCM 环（每声道一个平面），容量 32768 帧；混音块 256 帧，AAC 包 1024 帧，够用。
    private let fifoCapacity = 32_768
    private let fifo: [UnsafeMutablePointer<Float>]
    private var fifoRead: Int64 = 0      // 累计读出（转换器已取走）的帧数
    private var fifoWrite: Int64 = 0     // 累计写入的帧数
    private var packetsOut: Int64 = 0
    private var finishing = false
    // stamp 环：(首帧累计序号, host time)
    private struct Stamp { var frameIndex: Int64; var hostTime: HostTime }
    private var stamps: [Stamp] = []
    private let stampCapacity = 64
    private var stampHead = 0
    private var stampCount = 0
    private var pendingReadForCallback: Int = 0   // 本次 Fill 里输入回调实际交出的帧数
    /// 输入不够时回调返回的自定义错误码（AudioConverter 会保留内部状态，下次接着来）。
    private static let needMoreInput: OSStatus = 0x6E6D6F72  // 'nmor'

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        var inASBD = AudioStreamBasicDescription(
            mSampleRate: Float64(configuration.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(configuration.channelCount),
            mBitsPerChannel: 32, mReserved: 0)
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: Float64(configuration.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(configuration.channelCount),
            mBitsPerChannel: 0, mReserved: 0)
        var c: AudioConverterRef?
        let st = AudioConverterNew(&inASBD, &outASBD, &c)
        guard st == noErr, let c else { throw Error.converterCreateFailed(st) }
        converter = c
        var br = UInt32(configuration.bitrateBps)
        let brSt = AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        guard brSt == noErr else { AudioConverterDispose(c); throw Error.propertyFailed("EncodeBitRate", brSt) }
        var prime = AudioConverterPrimeInfo()
        var psz = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        AudioConverterGetProperty(c, kAudioConverterPrimeInfo, &psz, &prime)
        primingFrames = Int(prime.leadingFrames)
        framesPerPacket = Int(outASBD.mFramesPerPacket)
        var maxOut: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(c, kAudioConverterPropertyMaximumOutputPacketSize, &sz, &maxOut)
        maxPacketBytes = Int(maxOut)
        outBuffer = .allocate(byteCount: max(Int(maxOut), 1) * 2, alignment: 16)
        var cookieSize: UInt32 = 0
        AudioConverterGetPropertyInfo(c, kAudioConverterCompressionMagicCookie, &cookieSize, nil)
        var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
        if cookieSize > 0 { AudioConverterGetProperty(c, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie) }
        var fmt: CMAudioFormatDescription?
        let fst = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &outASBD, layoutSize: 0, layout: nil,
                                           magicCookieSize: Int(cookieSize), magicCookie: cookieSize > 0 ? raw.baseAddress : nil,
                                           extensions: nil, formatDescriptionOut: &fmt)
        }
        guard fst == noErr, let fmt else { AudioConverterDispose(c); throw Error.formatDescriptionFailed(fst) }
        formatDescription = fmt
        fifo = (0..<configuration.channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 32_768)
            p.initialize(repeating: 0, count: 32_768)
            return p
        }
        stamps = Array(repeating: Stamp(frameIndex: 0, hostTime: .zero), count: stampCapacity)
    }

    deinit {
        AudioConverterDispose(converter)
        outBuffer.deallocate()
        for p in fifo { p.deallocate() }
    }

    /// 累计送入的帧数。
    public var framesIn: Int64 { fifoWrite }
    /// 累计交出的包数。
    public var packetsEncoded: Int64 { packetsOut }

    /// 喂一块 PCM（非交错，channelCount 个平面），块首样本 host time。同步编出所有能编的包。
    public func encode(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) {
        guard frameCount > 0, !finishing else { return }
        // 环容量不够就丢最旧（推流场景音频比视频更不该丢；容量 32768 帧 = 0.68 s，正常永远用不到）
        let free = Int64(fifoCapacity) - (fifoWrite - fifoRead)
        if Int64(frameCount) > free { fifoRead += Int64(frameCount) - free }
        pushStamp(frameIndex: fifoWrite, hostTime: hostTime)
        for ch in 0..<configuration.channelCount {
            let src = planes[ch]
            var written = 0
            while written < frameCount {
                let pos = Int((fifoWrite + Int64(written)) % Int64(fifoCapacity))
                let n = min(frameCount - written, fifoCapacity - pos)
                (fifo[ch] + pos).update(from: src + written, count: n)
                written += n
            }
        }
        fifoWrite += Int64(frameCount)
        drain()
    }

    /// 结束：把尾部（不足一包的部分 + 编码器延迟）全部编出。之后不再接受输入。
    public func finish() {
        guard !finishing else { return }
        finishing = true
        drain()
    }

    private func pushStamp(frameIndex: Int64, hostTime: HostTime) {
        let idx = (stampHead + stampCount) % stampCapacity
        if stampCount == stampCapacity { stampHead = (stampHead + 1) % stampCapacity } else { stampCount += 1 }
        stamps[idx] = Stamp(frameIndex: frameIndex, hostTime: hostTime)
    }

    /// 包首样本序号 → host time：找最近一条 frameIndex ≤ index 的 stamp（没有就用最早的一条）外推。
    private func hostTime(ofFrame index: Int64) -> HostTime {
        guard stampCount > 0 else { return .zero }
        var best = stamps[stampHead]
        for i in 0..<stampCount {
            let s = stamps[(stampHead + i) % stampCapacity]
            if s.frameIndex <= index { best = s } else { break }
        }
        let delta = index - best.frameIndex
        let ns = Int64((Double(delta) * 1e9 / Double(configuration.sampleRate)).rounded())
        return best.hostTime + HostDuration(nanoseconds: ns)
    }

    private func drain() {
        while true {
            let available = fifoWrite - fifoRead
            if !finishing && available < Int64(framesPerPacket) { break }
            var packets: UInt32 = 1
            var desc = AudioStreamPacketDescription()
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(configuration.channelCount), mDataByteSize: UInt32(maxPacketBytes * 2), mData: outBuffer))
            pendingReadForCallback = 0
            let st = AudioConverterFillComplexBuffer(converter, AudioEncoder.inputProc, Unmanaged.passUnretained(self).toOpaque(),
                                                     &packets, &abl, &desc)
            if packets == 0 {
                // needMoreInput：等下一块；finishing 时 0 包 = 尾部已清空
                _ = st
                break
            }
            emit(desc)
            if finishing && available <= 0 && packets == 0 { break }
        }
    }

    private func emit(_ desc: AudioStreamPacketDescription) {
        let k = packetsOut
        packetsOut += 1
        let firstFrame = k * Int64(framesPerPacket) - Int64(primingFrames)
        let isPreroll = firstFrame + Int64(framesPerPacket) <= 0
        let bytes = Int(desc.mDataByteSize)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        CMBlockBufferReplaceDataBytes(with: outBuffer + Int(desc.mStartOffset), blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var d = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: desc.mDataByteSize)
        let hostTime = hostTime(ofFrame: max(0, firstFrame)) - HostDuration(nanoseconds: firstFrame < 0
            ? Int64((Double(-firstFrame) * 1e9 / Double(configuration.sampleRate)).rounded()) : 0)
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1,
            presentationTimeStamp: hostTime.cmTime, packetDescriptions: &d, sampleBufferOut: &sb) == noErr, let sb else { return }
        output?(EncodedAudioPacket(sampleBuffer: sb, firstFrameIndex: firstFrame, hostTime: hostTime, byteCount: bytes, isPreroll: isPreroll))
    }

    // AudioConverter 拉输入：交出 fifo 里连续的一段；不够时返回 needMoreInput（finishing 时返回 0 包 + noErr 让它吐尾巴）。
    private static let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, user in
        let me = Unmanaged<AudioEncoder>.fromOpaque(user!).takeUnretainedValue()
        return me.provideInput(ioPackets: ioPackets, ioData: ioData)
    }

    private func provideInput(ioPackets: UnsafeMutablePointer<UInt32>, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let available = fifoWrite - fifoRead
        if available <= 0 {
            ioPackets.pointee = 0
            return finishing ? noErr : AudioEncoder.needMoreInput
        }
        let pos = Int(fifoRead % Int64(fifoCapacity))
        let contiguous = fifoCapacity - pos
        let n = min(Int(ioPackets.pointee), Int(available), contiguous)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for ch in 0..<min(buffers.count, configuration.channelCount) {
            buffers[ch].mNumberChannels = 1
            buffers[ch].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            buffers[ch].mData = UnsafeMutableRawPointer(fifo[ch] + pos)
        }
        fifoRead += Int64(n)
        ioPackets.pointee = UInt32(n)
        return noErr
    }
}
