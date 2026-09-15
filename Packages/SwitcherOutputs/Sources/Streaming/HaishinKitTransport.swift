import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import SwitcherContracts
import SwitcherOutputs

// HaishinKit 2.2.5 当传输层（reports/w2-stream.md 第 1 节的结论 a）：
//   RTMPStream.append(压缩 CMSampleBuffer) → RTMPVideoMessage → 连接；append(AVAudioCompressedBuffer, when:) → RTMPAudioMessage。
//   SRTStream.append(压缩 CMSampleBuffer) → TSWriter → libsrt；音频同上 → ADTS PES。
// 它不再编码；编码器（VideoEncoder / AudioEncoder）是我们的，PTS 是拍点时刻。
//
// 已知的三处细节（都在这里兜住）：
//   1. 它的发送队列无界、不丢、无超时，只每秒通过 StreamBitRateStrategy 上报一次队列字节 —— QueueReporter 把上报存下来，
//      StreamOutput 用它做门和停滞判定；真正的有界队列和丢帧在 StreamOutput 的 SendQueue。
//   2. 音视频各自以"第一个样本"为时间 0（RTMPTimestamp / TSWriter 都是）：RTMP 用 DTS + CTS 把视频原点搬到音频原点包上（精确到 1 ms）；
//      TS 只能挑最近的包（≤ 10.7 ms），且第一个音频包会被它当格式热身丢掉（expectedMedias 齐了才写），所以要一个 preroll 包。
//   3. AudioSpecificConfig 从 ASBD.mFormatFlags 取 AAC object type：flags 必须是 AAC_LC(2)，W1-E 的格式描述里是 0，这里自己造。

/// 存 HaishinKit 每秒一次的网络上报（NetworkMonitorEvent），供 StreamOutput 读。不调 setVideoSettings（我们不让它改码率）。
final actor QueueReporter: StreamBitRateStrategy {
    nonisolated let mamimumVideoBitRate: Int = 0
    nonisolated let mamimumAudioBitRate: Int = 0
    private var latest = TransportReport(queuedBytes: 0, totalBytesOut: 0, totalBytesIn: 0, updatedAt: .zero)

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let r), .publishInsufficientBWOccured(let r):
            latest = TransportReport(queuedBytes: r.currentQueueBytesOut, totalBytesOut: r.totalBytesOut, totalBytesIn: r.totalBytesIn,
                                     updatedAt: HostClock.now())
        case .reset:
            break
        }
    }

    var report: TransportReport { latest }
}

/// AAC 包 → AVAudioCompressedBuffer（HaishinKit 的音频入口类型）。
enum HKAudioBridge {
    /// AAC-LC 的 AVAudioFormat：HaishinKit 只看 ASBD（采样率、声道、mFormatFlags = object type），不看 magic cookie。
    static func makeFormat(sampleRate: Int, channelCount: Int) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    static func makeBuffer(_ packet: EncodedAudioPacket, format: AVAudioFormat) -> AVAudioCompressedBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(packet.sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length > 0 else { return nil }
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: length)
        buffer.data.copyMemory(from: pointer, byteCount: length)
        buffer.byteLength = UInt32(length)
        buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(length))
        return buffer
    }
}

/// 给压缩样本换时间：DTS = PTS − offset（RTMP 起步对齐用）。浅拷贝，数据不动。
func retimed(_ sample: CMSampleBuffer, dts: CMTime) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                                    decodeTimeStamp: dts)
    var copy: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                sampleBufferOut: &copy) == noErr else { return nil }
    return copy
}

/// RTMP / RTMPS。
final class RTMPTransport: StreamTransport, @unchecked Sendable {
    /// HaishinKit 给带 DTS 的样本加的固定 CTS（RTMPVideoMessage.ctsOffset = 0.066 s，不是 public）；
    /// 我们要的 CTS = 拍点时刻 − 音频原点，所以 DTS = PTS − 期望 CTS + 这个常量。E2E 测试（A/V 对齐）会盯住它。
    static let haishinKitCTSOffset = HostDuration(milliseconds: 66)

    let protocolName: String
    let startAlignment: StartAlignment = .dtsOffset
    private let destination: StreamDestination
    private let connection: RTMPConnection
    private let reporter = QueueReporter()
    private var stream: RTMPStream?
    private let audioFormat: AVAudioFormat?
    private let metadata: AMFObject

    init(destination: StreamDestination, audioFormat: AVAudioFormat?, metadata: AMFObject, connectTimeout: Int) {
        self.destination = destination
        protocolName = destination.scheme.rawValue
        self.audioFormat = audioFormat
        self.metadata = metadata
        connection = RTMPConnection(timeout: connectTimeout)
    }

    func connect() async throws {
        // 先建流再 connect：RTMPConnection.connect 成功后会同步给每个已注册的流做 createStream；
        // 反过来（connect 之后再建流）createStream 在流的 init Task 里异步跑，publish 可能抢在它前面用 streamId 0 发出去而超时（E7 实测）。
        // fcPublishName：FMLE 序列（releaseStream / FCPublish / FCUnpublish），关流时不用等服务器回 Unpublish.Success（有的服务器不回，会等满 requestTimeout）
        let s = RTMPStream(connection: connection, fcPublishName: destination.streamName.isEmpty ? nil : destination.streamName)
        await s.setBitRateStrategy(reporter)
        for _ in 0..<5 { await Task.yield() }          // 让 init 里的 addStream Task 先跑
        try? await Task.sleep(for: .milliseconds(10))
        do {
            let r = try await connection.connect(destination.connectURL)
            guard r.status?.code == RTMPConnection.Code.connectSuccess.rawValue else {
                throw StreamTransportError.connectFailed(r.status?.code ?? "connect 无状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch {
            throw StreamTransportError.connectFailed("\(error)")
        }
        do {
            let r = try await s.publish(destination.streamName)
            guard r.status?.code == RTMPStream.Code.publishStart.rawValue else {
                throw StreamTransportError.connectFailed(r.status?.code ?? "publish 无状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch {
            throw StreamTransportError.connectFailed("publish: \(error)")
        }
        // 它自己发的 onMetaData 对压缩输入只有 duration；补一份带尺寸 / 码率 / 编码的
        try? await s.send("@setDataFrame", arguments: "onMetaData", metadata)
        stream = s
    }

    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws {
        guard let stream else { throw StreamTransportError.notConnected }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
        let dts = CMTimeSubtract(CMTimeAdd(pts, Self.haishinKitCTSOffset.cmTime), dtsOffset.cmTime)
        guard let sb = retimed(sample.sampleBuffer, dts: dts) else { throw StreamTransportError.sendFailed("retime") }
        await stream.append(sb)
    }

    func send(audio packet: EncodedAudioPacket) async throws {
        guard let stream else { throw StreamTransportError.notConnected }
        guard let audioFormat, let buffer = HKAudioBridge.makeBuffer(packet, format: audioFormat) else { return }
        await stream.append(buffer, when: AVAudioTime(hostTime: packet.hostTime.ticks))
    }

    func isConnected() async -> Bool { await connection.connected }

    func report() async -> TransportReport { await reporter.report }

    func close() async {
        if let stream { _ = try? await stream.close() }
        stream = nil
        try? await connection.close()
    }
}

/// SRT（libsrt，HaishinKit 自带的二进制）。
final class SRTTransport: StreamTransport, @unchecked Sendable {
    let protocolName = "srt"
    let startAlignment: StartAlignment = .nearestPacket(prerollPackets: 1)
    private let destination: StreamDestination
    private let connection = SRTConnection()
    private let reporter = QueueReporter()
    private var stream: SRTStream?
    private let audioFormat: AVAudioFormat?
    private var videoSent = false
    private var audioSentBeforeVideo = 0
    private var heldAudio: [EncodedAudioPacket] = []   // 第一帧视频之前收到的音频（除 preroll）先扣住：TSWriter 两种格式都有了才写

    init(destination: StreamDestination, audioFormat: AVAudioFormat?) {
        self.destination = destination
        self.audioFormat = audioFormat
    }

    func connect() async throws {
        do {
            try await connection.connect(URL(string: destination.connectURL))
        } catch {
            throw StreamTransportError.connectFailed("\(error)")
        }
        guard await connection.connected else { throw StreamTransportError.connectFailed("SRT 未连接") }
        let s = SRTStream(connection: connection)
        await s.setBitRateStrategy(reporter)
        await s.setExpectedMedias(audioFormat == nil ? [.video] : [.video, .audio])
        await s.publish()
        stream = s
    }

    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws {
        guard let stream else { throw StreamTransportError.notConnected }
        await stream.append(sample.sampleBuffer)
        if !videoSent {
            videoSent = true
            for p in heldAudio { await appendAudio(p, to: stream) }
            heldAudio.removeAll()
        }
    }

    func send(audio packet: EncodedAudioPacket) async throws {
        guard let stream else { throw StreamTransportError.notConnected }
        if !videoSent {
            // 第一个包是 preroll：直接送，让 TSWriter 记下音频格式（它会把这个包丢掉）；之后的扣到第一帧视频之后
            if audioSentBeforeVideo == 0 {
                audioSentBeforeVideo += 1
                await appendAudio(packet, to: stream)
            } else {
                heldAudio.append(packet)
                if heldAudio.count > 64 { heldAudio.removeFirst() }
            }
            return
        }
        await appendAudio(packet, to: stream)
    }

    private func appendAudio(_ packet: EncodedAudioPacket, to stream: SRTStream) async {
        guard let audioFormat, let buffer = HKAudioBridge.makeBuffer(packet, format: audioFormat) else { return }
        await stream.append(buffer, when: AVAudioTime(hostTime: packet.hostTime.ticks))
    }

    func isConnected() async -> Bool { await connection.connected }

    func report() async -> TransportReport { await reporter.report }

    func close() async {
        if let stream { await stream.close() }
        stream = nil
        await connection.close()
    }
}

/// 生产工厂：按目的地协议造 RTMPTransport / SRTTransport。
public struct HaishinKitTransportFactory: StreamTransportFactory {
    /// 节目格式（写进 RTMP onMetaData）。
    public var format: ProgramFormat
    /// 视频编码参数（onMetaData 的 videocodecid / videodatarate）。
    public var video: VideoEncodeSettings
    /// 连接超时（秒，整数）。
    public var connectTimeoutSeconds: Int

    public init(format: ProgramFormat, video: VideoEncodeSettings, connectTimeoutSeconds: Int = 5) {
        self.format = format
        self.video = video
        self.connectTimeoutSeconds = max(1, connectTimeoutSeconds)
    }

    public func makeTransport(for destination: StreamDestination, audioFormat: AudioEncoder.Configuration?) throws -> any StreamTransport {
        let hkAudio = audioFormat.flatMap { HKAudioBridge.makeFormat(sampleRate: $0.sampleRate, channelCount: $0.channelCount) }
        switch destination.scheme {
        case .rtmp, .rtmps:
            var metadata: AMFObject = [
                "width": Double(video.width ?? format.width),
                "height": Double(video.height ?? format.height),
                "framerate": format.frameRate.framesPerSecond.doubleValue,
                "videodatarate": Double(video.bitrateBps) / 1000,
                "videocodecid": video.codec == .hevc ? "hvc1" : 7.0,
                "encoder": "Switcher \(SwitcherVersion.current)",
            ]
            if let audioFormat {
                metadata["audiocodecid"] = 10.0
                metadata["audiodatarate"] = Double(audioFormat.bitrateBps) / 1000
                metadata["audiosamplerate"] = Double(audioFormat.sampleRate)
                metadata["audiosamplesize"] = 16.0
                metadata["stereo"] = audioFormat.channelCount == 2
            }
            return RTMPTransport(destination: destination, audioFormat: hkAudio, metadata: metadata, connectTimeout: connectTimeoutSeconds)
        case .srt:
            return SRTTransport(destination: destination, audioFormat: hkAudio)
        }
    }
}
