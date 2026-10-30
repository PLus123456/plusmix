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
//   4. 它的 RTMP 鉴权（connect 地址带 user:pass@ 时自动走）不能用（W5-D 探针）：交给它的地址永远不带 userinfo，Adobe 鉴权的前两轮由 RTMPAdobeAuth 做。
//   5. 服务器拒绝鉴权（W2-D4）报类型化的 StreamTransportError.authenticationFailed（StreamOutput 第一次就停、不退避）：Adobe 的 authfailed /
//      nosuchuser / llnw、publish 的 NetStream.Publish.Unauthorized。publish 的回复可能晚于 HaishinKit 3 s 的请求超时（MediaMTX 随机等 0–4 s），
//      超时之后从流的状态流里接着等（RTMPTransport.connect）。
// 错误文字进日志 / 状态之前都过 StreamURLRedaction（HaishinKit 的错误里可能带整个地址：unsupportedCommand、SRT 的 unsupportedUri）。

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
    private let connectTimeout: Int

    init(destination: StreamDestination, audioFormat: AVAudioFormat?, metadata: AMFObject, connectTimeout: Int) {
        self.destination = destination
        protocolName = destination.scheme.rawValue
        self.audioFormat = audioFormat
        self.metadata = metadata
        self.connectTimeout = connectTimeout
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
        // 地址里写了 user:pass@：Adobe 鉴权的前两轮自己做，拿到第三轮的参数；交给 HaishinKit 的地址不带 userinfo（它自带的鉴权见 RTMPAdobeAuth）
        var target = destination.connectURLWithoutCredentials
        if let credentials = destination.credentials {
            do {
                target = try await RTMPAdobeAuth.authorize(connectURL: target, credentials: credentials, timeoutSeconds: Double(connectTimeout))
            } catch let e as RTMPAdobeAuth.Failure {
                switch e {
                case .badCredentials(let reason, _):
                    throw StreamTransportError.authenticationFailed(reason, message: e.description)
                case .unsupported:
                    throw StreamTransportError.authenticationFailed(.unsupportedMethod, message: e.description)
                case .protocolError(let m) where m == RTMPConnectCommand.tooDeepMessage || m == RTMPConnectCommand.tooManyElementsMessage:
                    // 回复超出 AMF0 上限（NS04：恶意 / 坏掉的服务器）：不退回交给 HaishinKit——它的 AMF0 解析同样递归无上限（2.2.5，W2-D5 探针：
                    // 它自己 connect 也是 1000 层就 SIGBUS），同一个服务器回同样的东西就把整个进程打崩。当连接失败（退避重试，每次都先过我们的解析）
                    throw StreamTransportError.connectFailed(e.description)
                case .rejected, .protocolError, .timedOut:
                    // 服务器不是 Adobe 那套、或者我们的最小客户端没看懂：退回改之前的做法，把不带 userinfo 的地址交给 HaishinKit（账号这时用不上）
                    break
                }
            }
        }
        do {
            let r = try await connection.connect(target)
            guard r.status?.code == RTMPConnection.Code.connectSuccess.rawValue else {
                throw StreamTransportError.connectFailed(r.status?.code ?? "connect 无状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch {
            let e = Self.transportError(error, phase: "")
            // 地址里写了账号、服务器却还在要 Adobe 鉴权：是我们的前两轮退回了（超时 / 没看懂），不是"没写账号"——照旧当连接失败、退避重试
            if case .authenticationFailed(.credentialsRequired, let m) = e, destination.credentials != nil { throw StreamTransportError.connectFailed(m) }
            throw e
        }
        // publish 之前先订阅流的状态：MediaMTX 一类按查询串鉴权的服务器，账号不对时先随机等 0–4 s 才回 NetStream.Publish.Unauthorized（防暴力猜），
        // HaishinKit 的 publish 请求 3 s 就按超时收场——之后那条迟到的回复只会出现在这里（W2-D4 探针，reports/w2-stream-4.md §1）。
        // 状态流无界缓冲，推流期间服务器几乎不再发 onStatus，留着不读也攒不下几条。
        let statuses = await s.status
        do {
            let r = try await s.publish(destination.streamName)
            guard r.status?.code == RTMPStream.Code.publishStart.rawValue else {
                throw StreamTransportError.connectFailed(r.status?.code ?? "publish 无状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch RTMPStream.Error.requestTimedOut {
            // 接着等迟到的回复，等多久由 StreamOutput 的连接超时管（超时取消本 Task，状态流随之结束）
            for await status in statuses {
                if status.code == RTMPStream.Code.publishStart.rawValue {
                    // 迟到的成功：HaishinKit 这边的 publish 已经按超时收场（流回到 idle），这条连接用不了，按一般失败重连
                    throw StreamTransportError.connectFailed("publish: 服务器 \(RTMPConnection.defaultRequestTimeout) ms 之后才回 \(status.code)")
                }
                if status.level != "status" { throw Self.error(code: status.code, description: status.description, phase: "publish") }
            }
            throw StreamTransportError.connectFailed("publish: requestTimedOut")
        } catch {
            throw Self.transportError(error, phase: "publish")
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

    /// 服务器回的状态是不是"拒绝鉴权"（W2-D4）；不是返回 nil（照旧当连接失败、退避重试）。只看协议字段：状态码，
    /// 加上 Adobe 那套写在 Rejected 描述里的参数——reason=authfailed / nosuchuser（第三轮 / 第二轮被拒）、authmod=llnw（要 Limelight）、
    /// 只有 authmod=adobe 没有 reason（服务器要账号、地址里没写，HaishinKit 拿不到 userinfo 只能就此失败）。
    /// MediaMTX 1.21 查询串账号不对 / 没给：publish 回 level error、NetStream.Publish.Unauthorized、"authentication failed"（探针）。
    static func authFailure(code: String, description: String) -> StreamAuthFailure? {
        switch code {
        case "NetStream.Publish.Unauthorized":
            return .publishUnauthorized
        case RTMPConnection.Code.connectRejected.rawValue:
            switch RTMPAdobeAuth.parameters(inDescription: description)["reason"] {
            case "authfailed": return .badCredentials
            case "nosuchuser": return .noSuchUser
            default:
                if description.contains("authmod=llnw") { return .unsupportedMethod }
                if description.contains("authmod=adobe") { return .credentialsRequired }
                return nil
            }
        default:
            return nil
        }
    }

    /// 服务器回的状态 → StreamTransportError：拒绝鉴权 → authenticationFailed（"鉴权失败（…）：<状态码> <描述>"，原文照留），
    /// 其余 → connectFailed（publish 阶段带 "publish: "）。文字里的地址一律打码。
    static func error(code: String, description: String, phase: String) -> StreamTransportError {
        let text = StreamURLRedaction.redact(text: "\(code) \(description)")
        if let reason = authFailure(code: code, description: description) {
            return .authenticationFailed(reason, message: "\(reason.summary)：\(text)")
        }
        return .connectFailed(phase.isEmpty ? text : "\(phase): \(text)")
    }

    /// HaishinKit 的错误 → StreamTransportError：服务器回了状态（connect 的 _error、publish 的 onStatus）按 `error(code:…)` 认，
    /// 其余（socket 错误、超时……）原样写进 connectFailed；地址一律打码。
    static func transportError(_ error: any Error, phase: String) -> StreamTransportError {
        let status: RTMPStatus?
        switch error {
        case RTMPConnection.Error.requestFailed(let response): status = response.status
        case RTMPStream.Error.requestFailed(let response): status = response.status
        default: status = nil
        }
        if let status { return Self.error(code: status.code, description: status.description, phase: phase) }
        let text = StreamURLRedaction.redact(text: "\(error)")
        return .connectFailed(phase.isEmpty ? text : "\(phase): \(text)")
    }
}

/// SRT（libsrt，HaishinKit 自带的二进制）。
///
/// TSWriter 的规矩：expectedMedias 里的格式都齐了才写；先到的那个样本被当格式热身丢掉。所以：
/// 1. 第一个音频包先 append 一次（被丢，但 audioFormat 记下了），再扣住等第一帧视频之后重发 —— 音频原点 = 这个包的真实时刻；
/// 2. 音频格式没记下之前收到的视频先扣住（≤ 64 帧；原点包离关键帧不超过半个包，实际最多扣 2–3 帧），有了再放；
/// 3. 之后直通。视频 PTS 以第一帧为原点、音频以原点包为原点，两者误差 = 原点包离关键帧的距离（≤ 10.7 ms，StartAlignment.nearestPacket）。
final class SRTTransport: StreamTransport, @unchecked Sendable {
    let protocolName = "srt"
    let startAlignment: StartAlignment = .nearestPacket(prerollPackets: 0)
    private let destination: StreamDestination
    private let connection = SRTConnection()
    private let reporter = QueueReporter()
    private var stream: SRTStream?
    private let audioFormat: AVAudioFormat?
    private var audioPrimed = false            // TSWriter 已记下音频格式
    private var videoStarted = false           // 第一帧视频已 append
    private var heldVideo: [(EncodedVideoSample, HostDuration)] = []
    private var heldAudio: [EncodedAudioPacket] = []

    init(destination: StreamDestination, audioFormat: AVAudioFormat?) {
        self.destination = destination
        self.audioFormat = audioFormat
    }

    func connect() async throws {
        do {
            try await connection.connect(URL(string: destination.connectURL))
        } catch {
            throw StreamTransportError.connectFailed(StreamURLRedaction.redact(text: "\(error)"))
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
        if audioFormat != nil && !audioPrimed {
            heldVideo.append((sample, dtsOffset))
            if heldVideo.count > 64 { heldVideo.removeFirst() }
            return
        }
        await stream.append(sample.sampleBuffer)
        if !videoStarted {
            videoStarted = true
            for p in heldAudio { await appendAudio(p, to: stream) }
            heldAudio.removeAll()
        }
    }

    func send(audio packet: EncodedAudioPacket) async throws {
        guard let stream else { throw StreamTransportError.notConnected }
        if !audioPrimed {
            // 热身：让 TSWriter 记下音频格式（这份会被它丢掉），真正的那份扣到第一帧视频之后
            await appendAudio(packet, to: stream)
            audioPrimed = true
            heldAudio.append(packet)
            for (v, _) in heldVideo { await stream.append(v.sampleBuffer); videoStarted = true }
            heldVideo.removeAll()
            if videoStarted {
                for p in heldAudio { await appendAudio(p, to: stream) }
                heldAudio.removeAll()
            }
            return
        }
        if !videoStarted {
            heldAudio.append(packet)
            if heldAudio.count > 64 { heldAudio.removeFirst() }
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
