import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import os
import RTMPHaishinKit
import SRTHaishinKit
import Synchronization
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
//   6. 它的 connect 握手 / connect 命令没有超时、不理取消；socket 还没起来（TCP / TLS 握手中）时它的 close() 直接抛 invalidState、什么都不做，
//      RTMPS 对端不回 TLS 要等它写死的 15 s socket 超时（RTMPConnection(timeout:) 没有传给 socket）——对端接了 TCP 不说话就一直挂着（W2-D6）。
//      RTMPTransport.connect 把整个连接过程放进自己的子 Task，调用方的取消和别的 Task 调的 close() 都转成取消它；
//      HaishinKit 那一次 connect 再放进一个能"放手"的 Task（haishinKitConnect），放手之后后台关到它返回为止。
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

    /// 被放手、还在等 HaishinKit 自己返回的 connect 调用个数（W2-D6，见 haishinKitConnect）：明文 RTMP 关一次就回，
    /// RTMPS 在 TLS 阶段最多等它 15 s 的 socket 超时。测试看它回到 0 = 没有残留的 Task / 连接。
    static let pendingHaishinKitConnects = Atomic<Int>(0)
    private static let logger = Logger(subsystem: "switcher.streaming", category: "Transport")

    let protocolName: String
    let startAlignment: StartAlignment = .dtsOffset
    private let destination: StreamDestination
    private let connection: RTMPConnection
    private let reporter = QueueReporter()
    private let audioFormat: AVAudioFormat?
    private let metadata: AMFObject
    private let connectTimeout: Int
    /// close() 可能在 connect() 进行中从别的 Task 来（StreamOutput 的连接超时、stop()，W2-D6），这几样都在锁里。
    private struct Lifecycle {
        var closed = false
        /// connect() 正在跑的连接过程（close() 取消它、等它收尾）。
        var connecting: Task<Void, any Error>?
        /// 发布成功的流（connect 成功之后才有）。
        var stream: RTMPStream?
    }
    private let lifecycle = Mutex(Lifecycle())

    init(destination: StreamDestination, audioFormat: AVAudioFormat?, metadata: AMFObject, connectTimeout: Int) {
        self.destination = destination
        protocolName = destination.scheme.rawValue
        self.audioFormat = audioFormat
        self.metadata = metadata
        self.connectTimeout = connectTimeout
        connection = RTMPConnection(timeout: connectTimeout)
    }

    /// 连接并开始发布。整个过程在一个子 Task（connectSteps）里跑：调用方的取消、别的 Task 调的 close() 都取消它（W2-D6）；
    /// 每一步都理取消——Adobe 鉴权、等 publish 的迟到回复本来就理，HaishinKit 的 connect 由 haishinKitConnect 放手——所以总能及时返回。
    /// connect 进行中被 close() → 抛 connectFailed("传输层已关闭")。
    func connect() async throws {
        let steps: Task<Void, any Error>? = lifecycle.withLock { l in
            guard !l.closed, l.connecting == nil else { return nil }
            let t = Task { try await self.connectSteps() }
            l.connecting = t
            return t
        }
        guard let steps else { throw StreamTransportError.connectFailed("传输层已关闭") }
        defer { lifecycle.withLock { $0.connecting = nil } }
        do {
            try await withTaskCancellationHandler {
                try await steps.value
            } onCancel: {
                steps.cancel()
            }
        } catch {
            if lifecycle.withLock({ $0.closed }) { throw StreamTransportError.connectFailed("传输层已关闭") }
            throw error
        }
    }

    private func connectSteps() async throws {
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
            let r = try await haishinKitConnect(target)
            guard let status = r.status, status.code == RTMPConnection.Code.connectSuccess.rawValue else {
                throw r.status.map { Self.error(code: $0.code, description: $0.description, phase: "") } ?? StreamTransportError.connectFailed("服务器回的 connect 里没有状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch {
            let e = Self.transportError(error, phase: "")
            // 地址里写了账号、服务器却还在要 Adobe 鉴权：是我们的前两轮退回了（超时 / 没看懂），不是"没写账号"——照旧当连接失败、退避重试
            // （原来照搬了 credentialsRequired 那句"地址里没写"）
            if case .authenticationFailed(.credentialsRequired, _) = e, destination.credentials != nil, let status = Self.status(of: error) {
                throw StreamTransportError.connectFailed("服务器还要 Adobe 鉴权（这次前两轮没走完，稍后重试）：" + StreamURLRedaction.redact(text: "\(status.code) \(status.description)"))
            }
            throw e
        }
        // publish 之前先订阅流的状态：MediaMTX 一类按查询串鉴权的服务器，账号不对时先随机等 0–4 s 才回 NetStream.Publish.Unauthorized（防暴力猜），
        // HaishinKit 的 publish 请求 3 s 就按超时收场——之后那条迟到的回复只会出现在这里（W2-D4 探针，reports/w2-stream-4.md §1）。
        // 状态流无界缓冲，推流期间服务器几乎不再发 onStatus，留着不读也攒不下几条。
        let statuses = await s.status
        do {
            let r = try await s.publish(destination.streamName)
            guard let status = r.status, status.code == RTMPStream.Code.publishStart.rawValue else {
                throw r.status.map { Self.error(code: $0.code, description: $0.description, phase: "publish") } ?? StreamTransportError.connectFailed("发布：服务器回的 publish 里没有状态")
            }
        } catch let e as StreamTransportError {
            throw e
        } catch RTMPStream.Error.requestTimedOut {
            // 接着等迟到的回复，等多久由 StreamOutput 的连接超时管（超时取消本 Task，状态流随之结束）
            for await status in statuses {
                if status.code == RTMPStream.Code.publishStart.rawValue {
                    // 迟到的成功：HaishinKit 这边的 publish 已经按超时收场（流回到 idle），这条连接用不了，按一般失败重连
                    throw StreamTransportError.connectFailed("发布：服务器 \(RTMPConnection.defaultRequestTimeout) ms 之后才回 \(status.code)，这条连接作废、重连")
                }
                if status.level != "status" { throw Self.error(code: status.code, description: status.description, phase: "publish") }
            }
            throw StreamTransportError.connectFailed("发布：服务器没回（请求超时）")
        } catch {
            throw Self.transportError(error, phase: "publish")
        }
        // 它自己发的 onMetaData 对压缩输入只有 duration；补一份带尺寸 / 码率 / 编码的
        try? await s.send("@setDataFrame", arguments: "onMetaData", metadata)
        // close() 刚好抢在这之前来过：这条流不留（close 已经在关连接），按被关处理
        let kept = lifecycle.withLock { l -> Bool in
            guard !l.closed else { return false }
            l.stream = s
            return true
        }
        if !kept {
            _ = try? await s.close()
            throw CancellationError()
        }
    }

    /// HaishinKit 的那一次 `RTMPConnection.connect`（W2-D6，探针结论见 reports/w2-stream-6.md）：
    /// - 握手 / connect 命令没有超时、不理取消：对端接了 TCP 不说话就一直挂着；
    /// - 它的 close() 能结束握手阶段的挂起（明文 RTMP 1 s 时关 → 立刻以 Connect.Failed 返回），但 socket 还没起来时（TCP / TLS 握手中，
    ///   readyState 还是 uninitialized）直接抛 invalidState、什么都不做：RTMPS 对端不回 TLS 要等它写死的 15 s socket 超时，
    ///   close 落在 TCP 连上之前也一样（明文 RTMP 0 s 时关 → 永远挂）。
    /// 所以这次调用放进自己的 Task，结果经 HaishinKitConnectCall 交回来；本 Task 被取消就立刻放手（抛 CancellationError、不等它），
    /// 那个 Task 交给收尾（closeUntilReturned）：每 0.2 s 关一次连接，直到 HaishinKit 的 connect 自己返回（明文 RTMP 第一次关就回；
    /// RTMPS 的 TLS 阶段最多它 15 s 的超时），晚到的成功也关掉作废。`pendingHaishinKitConnects` 记着还没返回的个数。
    private func haishinKitConnect(_ target: String) async throws -> RTMPResponse {
        try Task.checkCancellation()
        let connection = self.connection
        let call = HaishinKitConnectCall()
        Self.pendingHaishinKitConnects.add(1, ordering: .relaxed)
        Task {
            let result: Result<RTMPResponse, any Error>
            do { result = .success(try await connection.connect(target)) } catch { result = .failure(error) }
            if !call.deliver(result), case .success = result {
                try? await connection.close()   // 已经放手：晚到的成功作废
            }
            call.markReturned()
            Self.pendingHaishinKitConnects.subtract(1, ordering: .relaxed)
        }
        return try await withTaskCancellationHandler {
            try await call.value()
        } onCancel: {
            guard call.abandon() else { return }
            Task { await Self.closeUntilReturned(connection, call) }
        }
    }

    /// 放手之后的收尾：关到 HaishinKit 的 connect 返回为止（至少关一次——放手时它可能刚成功、结果没人取）。30 s 还没返回就不再管
    /// （它自己的 socket 超时是 15 s；只剩 HaishinKit 的一处竞态会这样：close 正好落在它发 C0C1 与登记续体之间，续体再没人收）。
    private static func closeUntilReturned(_ connection: RTMPConnection, _ call: HaishinKitConnectCall) async {
        let deadline = HostClock.now() + HostDuration(seconds: 30)
        repeat {
            try? await connection.close()
            if call.hasReturned { return }
            try? await Task.sleep(for: .milliseconds(200))
        } while !call.hasReturned && HostClock.now() < deadline
        if !call.hasReturned { logger.error("HaishinKit 的 connect 放手 30 s 后还没返回，不再关它") }
    }

    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws {
        guard let stream = lifecycle.withLock({ $0.stream }) else { throw StreamTransportError.notConnected }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
        let dts = CMTimeSubtract(CMTimeAdd(pts, Self.haishinKitCTSOffset.cmTime), dtsOffset.cmTime)
        guard let sb = retimed(sample.sampleBuffer, dts: dts) else { throw StreamTransportError.sendFailed("视频样本改时间戳失败") }
        await stream.append(sb)
    }

    func send(audio packet: EncodedAudioPacket) async throws {
        guard let stream = lifecycle.withLock({ $0.stream }) else { throw StreamTransportError.notConnected }
        guard let audioFormat, let buffer = HKAudioBridge.makeBuffer(packet, format: audioFormat) else { return }
        await stream.append(buffer, when: AVAudioTime(hostTime: packet.hostTime.ticks))
    }

    func isConnected() async -> Bool { await connection.connected }

    func report() async -> TransportReport { await reporter.report }

    /// 关闭。可以在 connect() 进行中从别的 Task 调（W2-D6）：先取消连接过程、等它收尾（HaishinKit 那一次 connect 已放手，很快），
    /// 再关流和连接；connect() 随之抛 connectFailed("传输层已关闭")。重复调用无害。
    func close() async {
        let steps = lifecycle.withLock { l -> Task<Void, any Error>? in
            l.closed = true
            return l.connecting
        }
        steps?.cancel()
        _ = await steps?.result
        let stream = lifecycle.withLock { l -> RTMPStream? in
            defer { l.stream = nil }
            return l.stream
        }
        if let stream { _ = try? await stream.close() }
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
    /// 其余 → connectFailed："服务器拒绝连接：<状态码> <描述>"，phase 是 "publish" 时"发布被拒：<状态码> <描述>"（W4-C4：原来只有原文、publish 阶段带英文 "publish: "）。
    /// 文字里的地址一律打码。
    static func error(code: String, description: String, phase: String) -> StreamTransportError {
        let text = StreamURLRedaction.redact(text: "\(code) \(description)")
        if let reason = authFailure(code: code, description: description) {
            return .authenticationFailed(reason, message: "\(reason.summary)：\(text)")
        }
        return .connectFailed(phase.isEmpty ? "服务器拒绝连接：\(text)" : "发布被拒：\(text)")
    }

    /// HaishinKit 的错误 → StreamTransportError：服务器回了状态（connect 的 _error、publish 的 onStatus）按 `error(code:…)` 认，
    /// 其余（socket 错误、超时……）给 TransportErrorText 的中文概括（publish 阶段前面加"发布："），原文记日志。
    static func transportError(_ error: any Error, phase: String) -> StreamTransportError {
        if let status = status(of: error) { return Self.error(code: status.code, description: status.description, phase: phase) }
        let text = TransportErrorText.summary(of: error, logContext: phase.isEmpty ? "rtmp connect" : "rtmp \(phase)")
        return .connectFailed(phase.isEmpty ? text : "发布：\(text)")
    }

    /// HaishinKit 的错误里服务器回的状态（connect 的 _error、publish 的 onStatus）；没有为 nil。
    static func status(of error: any Error) -> RTMPStatus? {
        switch error {
        case RTMPConnection.Error.requestFailed(let response): return response.status
        case RTMPStream.Error.requestFailed(let response): return response.status
        default: return nil
        }
    }
}

/// HaishinKit 的一次 connect 调用的结果交接（W2-D6，见 RTMPTransport.haishinKitConnect）：调用跑在自己的 Task 里，等的人可以先走（放手）。只用一次。
final class HaishinKitConnectCall: Sendable {
    private enum State {
        case running
        case waiting(CheckedContinuation<RTMPResponse, any Error>)
        case delivered(Result<RTMPResponse, any Error>)
        /// 结果交出去了，或已放手。
        case done
    }
    private let state = Mutex<State>(.running)
    private let returned = Atomic<Bool>(false)

    /// 等结果；已经放手（或等着时被放手）抛 CancellationError。
    func value() async throws -> RTMPResponse {
        try await withCheckedThrowingContinuation { c in
            let ready: Result<RTMPResponse, any Error>? = state.withLock { s in
                switch s {
                case .running: s = .waiting(c); return nil
                case .delivered(let r): s = .done; return r
                case .waiting, .done: return .failure(CancellationError())
                }
            }
            if let ready { c.resume(with: ready) }
        }
    }

    /// HaishinKit 返回了。false = 已经放手、没人要这个结果（成功的话调用方去关连接）。
    func deliver(_ result: Result<RTMPResponse, any Error>) -> Bool {
        let (accepted, waiter) = state.withLock { s -> (Bool, CheckedContinuation<RTMPResponse, any Error>?) in
            switch s {
            case .running: s = .delivered(result); return (true, nil)
            case .waiting(let c): s = .done; return (true, c)
            case .delivered, .done: return (false, nil)
            }
        }
        waiter?.resume(with: result)
        return accepted
    }

    /// 放手：等的人立刻以 CancellationError 返回。true = 这次放手生效（结果还没交给等的人），调用方负责收尾去关连接。
    func abandon() -> Bool {
        let (abandoned, waiter) = state.withLock { s -> (Bool, CheckedContinuation<RTMPResponse, any Error>?) in
            switch s {
            case .running: s = .done; return (true, nil)
            case .waiting(let c): s = .done; return (true, c)
            case .delivered: s = .done; return (true, nil)   // HaishinKit 已经返回、还没人取：作废（成功的连接由收尾关）
            case .done: return (false, nil)
            }
        }
        waiter?.resume(throwing: CancellationError())
        return abandoned
    }

    /// HaishinKit 的 connect 已经返回（不管有没有人要结果）。
    func markReturned() { returned.store(true, ordering: .releasing) }
    var hasReturned: Bool { returned.load(ordering: .acquiring) }
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
    /// close() 可能在 connect() 进行中从别的 Task 来（StreamOutput 的连接超时、stop()，W2-D6）：流和"已关"在锁里。
    /// SRT 的 connect 本身由 libsrt 自己的超时兜住（没人听 3 s 报错），这里不另做放手。
    private struct Lifecycle {
        var closed = false
        var stream: SRTStream?
    }
    private let lifecycle = Mutex(Lifecycle())
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
        guard !lifecycle.withLock({ $0.closed }) else { throw StreamTransportError.connectFailed("传输层已关闭") }
        do {
            try await connection.connect(URL(string: destination.connectURL))
        } catch {
            throw StreamTransportError.connectFailed(TransportErrorText.summary(of: error, logContext: "srt connect"))
        }
        guard await connection.connected else { throw StreamTransportError.connectFailed("SRT 未连接") }
        let s = SRTStream(connection: connection)
        await s.setBitRateStrategy(reporter)
        await s.setExpectedMedias(audioFormat == nil ? [.video] : [.video, .audio])
        await s.publish()
        let kept = lifecycle.withLock { l -> Bool in
            guard !l.closed else { return false }
            l.stream = s
            return true
        }
        if !kept {
            await s.close()
            throw StreamTransportError.connectFailed("传输层已关闭")
        }
    }

    func send(video sample: EncodedVideoSample, dtsOffset: HostDuration) async throws {
        guard let stream = lifecycle.withLock({ $0.stream }) else { throw StreamTransportError.notConnected }
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
        guard let stream = lifecycle.withLock({ $0.stream }) else { throw StreamTransportError.notConnected }
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
        let stream = lifecycle.withLock { l -> SRTStream? in
            l.closed = true
            defer { l.stream = nil }
            return l.stream
        }
        if let stream { await stream.close() }
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
