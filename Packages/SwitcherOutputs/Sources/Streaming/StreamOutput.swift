import Foundation
import os
import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 一个推流目的地（设计方案 §8 推流行；prompt 交付 1、2）。
///
/// 线程 / 任务：
/// - `consume`（引擎派发线程）：只转给自己的 VideoEncoder（有界队列 push，立即返回）。
/// - VideoEncoder 的回调线程：`EncodedVideoSample` → `SendQueue.pushVideo`（锁内几个下标操作）→ 唤醒发送 Task。
/// - `consumeAudio`（组装方的泵线程，非实时）：PCM 块拷进 `PCMBlockRing`，唤醒音频编码线程。
/// - 音频编码线程（自己的 Thread）：AudioEncoder → `SendQueue.pushAudio` → 唤醒发送 Task。
/// - 发送 Task（Swift 并发，每路一个）：状态机 —— 连接 → 起步对齐 → 按时间交错送样本 → 停滞 / 断线检测 → 退避重连。
///   传输层（HaishinKit）的调用都是 actor 跳转，返回即入了它的队列；真正的网络背压靠它每秒上报的队列字节做"门"（见 publishLoop）。
///
/// 多目的地互不影响：每个实例自己的编码器、队列、Task、连接对象；没有任何共享锁或共享队列（E7）。
public final class StreamOutput: FrameConsumer, AudioBlockConsumer, @unchecked Sendable {
    /// 队列与门的参数（"每路队列深度与延迟的取舍"见报告）。
    public struct QueuePolicy: Hashable, Sendable {
        /// 视频发送队列容量（帧）。nil = 1 秒的帧数。
        public var videoFrames: Int?
        /// 音频发送队列容量（包，1024 帧一个 ≈ 21.3 ms）。默认 256 ≈ 5.5 s。
        public var audioPackets: Int
        /// 门：传输层"已交但未发出"的字节估计超过它就不再往里交（队列在生产者侧满了自己丢）。nil = 2 秒的码率。
        public var maxInFlightBytes: Int?
        /// 停滞判定：传输层累计发出字节连续这么多秒不涨（且有待发数据）就当断线。
        public var stallSeconds: Double
        /// 起步时等音频包到齐的最长时间（ms）；超时按无音频起步。
        public var audioStartWaitMs: Double
        /// 停止时等传输层排空的最长秒数。
        public var drainSeconds: Double
        /// 排空后再等一会儿让内核发送缓冲清掉（HaishinKit 关连接是 forceCancel，会丢内核缓冲里的数据）。
        public var lingerSeconds: Double
        /// 发送 Task 的周期检查间隔（ms）：停滞、断线、门。
        public var pollIntervalMs: Double

        public init(videoFrames: Int? = nil, audioPackets: Int = 256, maxInFlightBytes: Int? = nil, stallSeconds: Double = 5,
                    audioStartWaitMs: Double = 250, drainSeconds: Double = 3, lingerSeconds: Double = 1, pollIntervalMs: Double = 100) {
            self.videoFrames = videoFrames
            self.audioPackets = audioPackets
            self.maxInFlightBytes = maxInFlightBytes
            self.stallSeconds = stallSeconds
            self.audioStartWaitMs = audioStartWaitMs
            self.drainSeconds = drainSeconds
            self.lingerSeconds = lingerSeconds
            self.pollIntervalMs = pollIntervalMs
        }
    }

    /// 参数。
    public struct Configuration: Sendable {
        /// 消费者名字（Stats / 日志）。
        public var name: String
        /// 节目格式。
        public var format: ProgramFormat
        /// 视频编码参数（每个目的地自己一个编码器）。
        public var video: VideoEncodeSettings
        /// 音频编码参数；nil = 不带音频。
        public var audio: AudioEncodeSettings?
        /// 音频声道数。
        public var audioChannels: Int
        /// 目的地（url / key / 重连上限）。
        public var stream: StreamSettings
        /// 重连策略；nil = 1、2、4 … 到 stream.reconnectMaxSeconds。
        public var reconnect: ReconnectPolicy?
        /// 队列与门。
        public var queue: QueuePolicy
        /// 视频编码器的有界队列深度（2–3）。
        public var encoderQueueDepth: Int
        /// VT DataRateLimits 倍数（W1-E 实测 1.5 最好）。
        public var dataRateLimitFactor: Double
        /// 连接超时（秒）。
        public var connectTimeoutSeconds: Double

        public init(name: String, format: ProgramFormat, video: VideoEncodeSettings, audio: AudioEncodeSettings? = AudioEncodeSettings(),
                    audioChannels: Int = 2, stream: StreamSettings, reconnect: ReconnectPolicy? = nil, queue: QueuePolicy = QueuePolicy(),
                    encoderQueueDepth: Int = 3, dataRateLimitFactor: Double = 1.5, connectTimeoutSeconds: Double = 5) {
            self.name = name
            self.format = format
            self.video = video
            self.audio = audio
            self.audioChannels = audioChannels
            self.stream = stream
            self.reconnect = reconnect
            self.queue = queue
            self.encoderQueueDepth = encoderQueueDepth
            self.dataRateLimitFactor = dataRateLimitFactor
            self.connectTimeoutSeconds = connectTimeoutSeconds
        }

        /// 实际生效的重连策略。
        public var effectiveReconnect: ReconnectPolicy {
            reconnect ?? ReconnectPolicy(initialSeconds: 1, multiplier: 2, maxSeconds: stream.reconnectMaxSeconds)
        }
        /// 实际生效的视频队列容量。
        public var effectiveVideoFrames: Int {
            queue.videoFrames ?? max(8, format.frameRate.nominalFramesPerSecond)
        }
        /// 实际生效的门。
        public var effectiveMaxInFlightBytes: Int {
            queue.maxInFlightBytes ?? max(256 * 1024, (video.bitrateBps + (audio?.bitrateBps ?? 0)) / 8 * 2)
        }
    }

    /// 错误。
    public enum Error: Swift.Error, Equatable {
        case alreadyRunning
        case notRunning
        case audioEncoderFailed(String)
    }

    public let consumerName: String
    public let configuration: Configuration
    public let destination: StreamDestination
    /// 本路的视频编码器（引擎把它的 skipped 汇总进 Stats.encoder[i].skipped）。
    public let videoEncoder: VideoEncoder
    /// 传输层工厂（生产：HaishinKitTransportFactory；测试：FakeTransportFactory）。
    public let transportFactory: any StreamTransportFactory

    private let queue: SendQueue
    private let atomicCounters = AtomicStreamCounters()
    private let stateLock = NSLock()
    private var running = false                 // stateLock
    private var senderTask: Task<Void, Never>?  // stateLock
    private let stopInitiated = Atomic<Bool>(false)   // stop() 的幂等门
    private let stopRequested = Atomic<Bool>(false)   // 编码器已停、尾巴已进队列：发送 Task 可以排空并退出
    private let stopped = DispatchGroup()
    private let wake: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private let logger = Logger(subsystem: "switcher.streaming", category: "StreamOutput")
    // 音频
    private let pcmRing: PCMBlockRing?
    private var audioEncoder: AudioEncoder?      // 音频线程之外只在 start / stop 碰
    private let audioWakeup = DispatchSemaphore(value: 0)
    private var audioThread: Thread?
    private let audioStopRequested = Atomic<Bool>(false)
    private let audioAccepting = Atomic<Bool>(false)
    private let audioThreadGroup = DispatchGroup()
    // 诊断：最近一次退出发布循环的原因
    private let lastExitReason = Mutex<String>("")

    /// 用 VideoToolbox 编码器。
    public convenience init(configuration: Configuration, transportFactory: any StreamTransportFactory) throws {
        try self.init(configuration: configuration, transportFactory: transportFactory, videoBackend: nil)
    }

    /// 指定视频编码后端（测试用可控后端）；nil = VideoToolbox。
    public init(configuration: Configuration, transportFactory: any StreamTransportFactory, videoBackend: (any VideoEncoderBackend)?) throws {
        self.configuration = configuration
        consumerName = configuration.name
        destination = try StreamDestination(settings: configuration.stream)
        self.transportFactory = transportFactory
        let encoderConfiguration = VideoEncoder.Configuration(
            name: configuration.name + ".video", format: configuration.format, settings: configuration.video,
            queueDepth: configuration.encoderQueueDepth, dataRateLimitFactor: configuration.dataRateLimitFactor)
        videoEncoder = videoBackend.map { VideoEncoder(configuration: encoderConfiguration, backend: $0) }
            ?? VideoEncoder(configuration: encoderConfiguration)
        queue = SendQueue(videoCapacity: configuration.effectiveVideoFrames, audioCapacity: configuration.queue.audioPackets)
        pcmRing = configuration.audio == nil ? nil
            : PCMBlockRing(channelCount: configuration.audioChannels, maxFrames: 4096, capacity: 128)
        (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let counters = atomicCounters
        let q = queue
        let wc = wakeContinuation
        videoEncoder.output = { [counters, q, wc] sample in
            counters.framesReceived.add(1, ordering: .relaxed)
            switch q.pushVideo(sample) {
            case .queued: wc.yield()
            case .droppedFull: counters.droppedQueueFull.add(1, ordering: .relaxed)
            case .droppedWaitingKeyframe: counters.droppedWaitingKeyframe.add(1, ordering: .relaxed)
            case .droppedNotAccepting: counters.droppedDisconnected.add(1, ordering: .relaxed)
            }
            counters.queueDepth.store(q.depth.video, ordering: .relaxed)
        }
    }

    /// 计数快照。
    public var counters: StreamCounters { atomicCounters.snapshot() }
    /// 当前状态。
    public var state: StreamState { atomicCounters.state }
    /// 是否在运行（start 之后、stop 完成之前）。
    public var isRunning: Bool { stateLock.withLock { running } }
    /// 最近一次退出发布循环的原因（诊断）。
    public var lastExitReasonDescription: String { lastExitReason.withLock { $0 } }

    /// Stats.encoder[i] 的一项：skipped = 本路编码器的 E1 计数；bitrate = 窗口内交给传输层的 bit/s。
    public func statsEntry(previous: StreamCounters?, windowSeconds: Double) -> Stats.EncoderEntry {
        counters.statsEntry(previous: previous, windowSeconds: windowSeconds, encoderSkipped: videoEncoder.counters.skipped)
    }

    // MARK: 生命周期

    /// 起编码器、音频线程、发送 Task。不阻塞；连接在 Task 里做，失败按退避重试。
    public func start() throws {
        try stateLock.withLock {
            guard !running else { throw Error.alreadyRunning }
            stopInitiated.store(false, ordering: .releasing)
            stopRequested.store(false, ordering: .releasing)
            try videoEncoder.start()
            if let audio = configuration.audio, let ring = pcmRing {
                let enc: AudioEncoder
                do {
                    enc = try AudioEncoder(configuration: .init(sampleRate: AudioFormat.sampleRate, channelCount: configuration.audioChannels,
                                                                bitrateBps: audio.bitrateBps, constantBitrate: true))
                } catch {
                    videoEncoder.stop()
                    throw Error.audioEncoderFailed("\(error)")
                }
                let counters = atomicCounters
                let q = queue
                let wc = wakeContinuation
                enc.output = { [counters, q, wc] packet in
                    guard !packet.isPreroll else { return }
                    counters.audioPacketsReceived.add(1, ordering: .relaxed)
                    switch q.pushAudio(packet) {
                    case .queued: wc.yield()
                    case .droppedFull: counters.audioDropped.add(1, ordering: .relaxed); wc.yield()
                    case .droppedWaitingKeyframe: break
                    case .droppedNotAccepting: counters.audioDropped.add(1, ordering: .relaxed)
                    }
                    counters.audioQueueDepth.store(q.depth.audio, ordering: .relaxed)
                }
                audioEncoder = enc
                audioStopRequested.store(false, ordering: .releasing)
                audioThreadGroup.enter()
                let t = Thread { [weak self] in
                    self?.audioLoop(encoder: enc, ring: ring)
                    self?.audioThreadGroup.leave()
                }
                t.name = "switcher.stream.audio.\(consumerName)"
                t.qualityOfService = .userInitiated
                audioThread = t
                t.start()
                audioAccepting.store(true, ordering: .releasing)
            }
            running = true
            stopped.enter()
            senderTask = Task.detached(priority: .userInitiated) { [self] in
                await self.run()
                self.stopped.leave()
            }
        }
    }

    /// 停：停编码器（把尾巴编完）、排空队列、关连接。阻塞到发送 Task 退出（最多 drain + linger + 连接超时）。
    /// 不要在 Swift 并发的协作线程上调它（会阻塞协作线程）；那边用 `stopAsync()`。
    public func stop() {
        guard beginStop() else { return }
        stopped.wait()
        finishStop()
    }

    /// `stop()` 的 async 版本。
    public func stopAsync() async {
        guard beginStop() else { return }
        let task = stateLock.withLock { senderTask }
        await task?.value
        finishStop()
    }

    /// 返回 false = 没在运行或已经在停。
    private func beginStop() -> Bool {
        let shouldStop: Bool = stateLock.withLock {
            guard running else { return false }
            let (exchanged, _) = stopInitiated.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
            return exchanged
        }
        guard shouldStop else { return false }
        atomicCounters.state = .stopping
        // 先停编码器：VideoEncoder.stop 会 flush，尾巴帧同步进队列；音频线程 finish 之后退出。
        // 尾巴都进了队列才置 stopRequested，否则发送 Task 可能先看到"停 + 队列空"就收尾，把随后到的尾巴当断线丢弃。
        videoEncoder.stop()
        audioAccepting.store(false, ordering: .releasing)
        audioStopRequested.store(true, ordering: .releasing)
        audioWakeup.signal()
        audioThreadGroup.wait()
        stopRequested.store(true, ordering: .releasing)
        wakeContinuation.yield()
        return true
    }

    private func finishStop() {
        stateLock.withLock {
            running = false
            senderTask = nil
            audioThread = nil
            audioEncoder = nil
        }
    }

    /// 下一帧强制关键帧（外部要求；重连时内部自己会调）。
    public func requestKeyframe() { videoEncoder.requestKeyframe() }

    // MARK: FrameConsumer / AudioBlockConsumer

    public func consume(_ frame: RenderedFrame) {
        videoEncoder.consume(frame)
    }

    public func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        guard let ring = pcmRing, audioAccepting.load(ordering: .acquiring) else { return }
        ring.push(planes: planes, channelCount: channelCount, frameCount: frameCount, hostTime: hostTime)
        audioWakeup.signal()
    }

    // MARK: 音频编码线程

    private func audioLoop(encoder: AudioEncoder, ring: PCMBlockRing) {
        while true {
            audioWakeup.wait()
            let stopping = audioStopRequested.load(ordering: .acquiring)
            while let block = ring.pop() {
                encoder.encode(planes: block.planes, frameCount: block.frameCount, hostTime: block.hostTime)
            }
            if stopping {
                // W1-E 的 AudioEncoder.finish() 在一块都没喂过时会在 emit 里算出负的 host time 而崩（reports/issues/W2D-w1-outputs-audioencoder-finish-empty.md）
                if encoder.framesIn > 0 { encoder.finish() }
                return
            }
        }
    }

    // MARK: 发送 Task：重连状态机

    private enum ExitReason: Equatable { case stopped, disconnected, stalled, sendFailed(String) }

    private func setState(_ s: StreamState) {
        atomicCounters.state = s
        logger.info("[\(self.consumerName, privacy: .public)] \(s.description, privacy: .public)")
    }

    private func run() async {
        let policy = configuration.effectiveReconnect
        var failures = 0              // 连续失败 / 断线次数（连上归零）
        var everConnected = false
        var disconnectedAt: HostTime?
        var finalState = StreamState.stopped
        var wakeIterator = wake.makeAsyncIterator()
        while !stopRequested.load(ordering: .acquiring) {
            guard policy.allows(attempt: failures + 1) else {
                finalState = .failed("连续 \(failures) 次连不上，超过最大尝试次数")
                break
            }
            if failures > 0 {
                let delay = policy.delay(forAttempt: failures)
                setState(.backoff(attempt: failures, seconds: delay))
                if await sleepUnlessStopped(seconds: delay) { break }
            }
            let attempt = failures + 1
            atomicCounters.connectAttempts.add(1, ordering: .relaxed)
            setState(.connecting(attempt: attempt))
            let transport: any StreamTransport
            do {
                transport = try transportFactory.makeTransport(for: destination, audioFormat: audioEncoder?.configuration)
            } catch {
                logger.error("[\(self.consumerName, privacy: .public)] 建传输层失败：\(String(describing: error), privacy: .public)")
                failures += 1
                continue
            }
            do {
                try await withTimeout(seconds: configuration.connectTimeoutSeconds) { try await transport.connect() }
            } catch {
                logger.warning("[\(self.consumerName, privacy: .public)] 连接失败：\(String(describing: error), privacy: .public)")
                await transport.close()
                failures += 1
                continue
            }
            if everConnected {
                atomicCounters.reconnects.add(1, ordering: .relaxed)
                if let at = disconnectedAt { atomicCounters.recordReconnect(seconds: (HostClock.now() - at).seconds) }
            }
            everConnected = true
            failures = 0
            setState(.publishing)
            queue.beginSession()
            videoEncoder.requestKeyframe()
            let reason = await publishLoop(transport, wake: &wakeIterator)
            lastExitReason.withLock { $0 = "\(reason)" }
            let discarded = queue.endSession()
            atomicCounters.discardedOnDisconnect.add(UInt64(discarded.video), ordering: .relaxed)
            atomicCounters.audioDropped.add(UInt64(discarded.audio), ordering: .relaxed)
            atomicCounters.queueDepth.store(0, ordering: .relaxed)
            atomicCounters.audioQueueDepth.store(0, ordering: .relaxed)
            await transport.close()
            if reason == .stopped { break }
            logger.warning("[\(self.consumerName, privacy: .public)] 断线：\(String(describing: reason), privacy: .public)")
            atomicCounters.disconnects.add(1, ordering: .relaxed)
            disconnectedAt = HostClock.now()
            failures = 1
        }
        queue.endSession()
        setState(finalState)
    }

    /// 等 seconds 秒，期间 stop 了就提前返回 true。
    private func sleepUnlessStopped(seconds: Double) async -> Bool {
        let deadline = HostClock.now() + HostDuration(seconds: seconds)
        while HostClock.now() < deadline {
            if stopRequested.load(ordering: .acquiring) { return true }
            let remaining = (deadline - HostClock.now()).seconds
            try? await Task.sleep(for: .milliseconds(max(1, min(100, Int(remaining * 1000)))))
        }
        return stopRequested.load(ordering: .acquiring)
    }

    /// 起步对齐（HaishinKit 两条封装层都以"各自第一个样本"为 0，见 StartAlignment）。
    private struct Session {
        var dtsOffset: HostDuration = .zero
        var aligned = false
        var keyframeSeenAt: HostTime?
        var bytesHanded = 0               // 交给传输层的字节（本次连接）
        var bytesHandedAtReport = 0       // 上一份上报时的 bytesHanded
        var lastReportAt: HostTime = .zero
        var lastTotalOut = 0
        var lastProgressAt: HostTime       // totalBytesOut 上次增长的时刻
        var handedVideoSizes: [Int] = []   // 最近交出的视频帧大小（估算断线时未发出的帧数）
    }

    /// 发布循环：返回退出原因。
    private func publishLoop(_ transport: any StreamTransport, wake: inout AsyncStream<Void>.AsyncIterator) async -> ExitReason {
        let policy = configuration.queue
        let maxInFlight = configuration.effectiveMaxInFlightBytes
        let alignment = transport.startAlignment
        let hasAudio = audioEncoder != nil
        var s = Session(lastProgressAt: HostClock.now())
        s.handedVideoSizes.reserveCapacity(512)
        var draining = false
        var drainStartedAt: HostTime?
        while true {
            let now = HostClock.now()
            let stopping = stopRequested.load(ordering: .acquiring)
            // 1. 上报：门、停滞
            let report = await transport.report()
            if report.updatedAt != s.lastReportAt {
                s.lastReportAt = report.updatedAt
                s.bytesHandedAtReport = s.bytesHanded
            }
            if report.totalBytesOut > s.lastTotalOut {
                s.lastTotalOut = report.totalBytesOut
                s.lastProgressAt = now
            }
            let inFlight = max(0, report.queuedBytes + (s.bytesHanded - s.bytesHandedAtReport))
            atomicCounters.inFlightBytes.store(inFlight, ordering: .relaxed)
            if inFlight > 0, (now - s.lastProgressAt).seconds > policy.stallSeconds {
                estimateLoss(unsentBytes: inFlight, sizes: s.handedVideoSizes)
                return .stalled
            }
            if !(await transport.isConnected()) {
                estimateLoss(unsentBytes: inFlight, sizes: s.handedVideoSizes)
                return .disconnected
            }
            // 2. 停止：队列空了就等传输层排空、再 linger
            if stopping {
                let depth = queue.depth
                if depth.video == 0 && depth.audio == 0 {
                    if !draining { draining = true; drainStartedAt = now }
                    let waited = (now - (drainStartedAt ?? now)).seconds
                    if report.queuedBytes == 0 || waited > policy.drainSeconds {
                        let linger = report.queuedBytes == 0 ? policy.lingerSeconds : 0
                        if linger > 0 { try? await Task.sleep(for: .milliseconds(Int(linger * 1000))) }
                        if report.queuedBytes > 0 { estimateLoss(unsentBytes: report.queuedBytes, sizes: s.handedVideoSizes) }
                        return .stopped
                    }
                    try? await Task.sleep(for: .milliseconds(Int(policy.pollIntervalMs)))
                    continue
                }
            }
            // 3. 门关着：不 pop，队列在生产者侧满了自己丢
            if inFlight >= maxInFlight {
                await waitWake(&wake, ms: policy.pollIntervalMs)
                continue
            }
            // 4. 起步对齐：队头必须是关键帧（非关键帧在 push 时已丢）；有音频就等到关键帧时刻之后的音频包到了再定原点
            if !s.aligned {
                guard let k = queue.peekVideo() else {
                    if stopping { s.aligned = true } else { await waitWake(&wake, ms: policy.pollIntervalMs) }
                    continue
                }
                if hasAudio {
                    let seenAt = s.keyframeSeenAt ?? now
                    s.keyframeSeenAt = seenAt
                    let waitedMs = (now - seenAt).milliseconds
                    if queue.hasAudio(atOrAfter: k.tickTime) {
                        switch alignment {
                        case .dtsOffset:
                            // 原点 = 最后一个不晚于关键帧时刻的包；关键帧 DTS 设成它的时刻（CTS = 差值）。原点在关键帧之后（不该发生）就不偏移。
                            if let (origin, dropped) = queue.alignAudio(to: k.tickTime, nearest: false, preroll: 0) {
                                if origin <= k.tickTime { s.dtsOffset = k.tickTime - origin }
                                atomicCounters.audioDropped.add(UInt64(dropped), ordering: .relaxed)
                            }
                        case .nearestPacket(let preroll):
                            if let (_, dropped) = queue.alignAudio(to: k.tickTime, nearest: true, preroll: preroll) {
                                atomicCounters.audioDropped.add(UInt64(dropped), ordering: .relaxed)
                            }
                        }
                        s.aligned = true
                    } else if waitedMs < policy.audioStartWaitMs && !stopping {
                        await waitWake(&wake, ms: policy.pollIntervalMs)
                        continue
                    } else {
                        s.aligned = true   // 没音频（或音频没来）：无对齐起步
                    }
                } else {
                    s.aligned = true
                }
                atomicCounters.audioQueueDepth.store(queue.depth.audio, ordering: .relaxed)
                continue
            }
            // 5. 按时间交错：视频按 DTS（tickTime − dtsOffset），音频按包首时刻；相等音频先
            let v = queue.peekVideo()
            let a = queue.peekAudio()
            guard v != nil || a != nil else {
                await waitWake(&wake, ms: policy.pollIntervalMs)
                continue
            }
            let sendVideo: Bool
            if let v, let a {
                sendVideo = (v.tickTime - s.dtsOffset) < a.hostTime
            } else {
                sendVideo = v != nil
            }
            do {
                if sendVideo, let sample = queue.popVideo() {
                    try await transport.send(video: sample, dtsOffset: s.dtsOffset)
                    s.bytesHanded += sample.byteCount
                    if s.handedVideoSizes.count == 512 { s.handedVideoSizes.removeFirst(256) }
                    s.handedVideoSizes.append(sample.byteCount)
                    atomicCounters.framesSent.add(1, ordering: .relaxed)
                    if sample.isKeyframe { atomicCounters.keyframesSent.add(1, ordering: .relaxed) }
                    atomicCounters.bytesSent.add(UInt64(sample.byteCount), ordering: .relaxed)
                    atomicCounters.queueDepth.store(queue.depth.video, ordering: .relaxed)
                } else if let packet = queue.popAudio() {
                    try await transport.send(audio: packet)
                    s.bytesHanded += packet.byteCount
                    atomicCounters.audioPacketsSent.add(1, ordering: .relaxed)
                    atomicCounters.bytesSent.add(UInt64(packet.byteCount), ordering: .relaxed)
                    atomicCounters.audioQueueDepth.store(queue.depth.audio, ordering: .relaxed)
                }
            } catch {
                estimateLoss(unsentBytes: inFlight, sizes: s.handedVideoSizes)
                return .sendFailed("\(error)")
            }
        }
    }

    /// 断线时按"未发出字节"估算已交出但没发出去的视频帧数（从最新的往回累加）。
    private func estimateLoss(unsentBytes: Int, sizes: [Int]) {
        guard unsentBytes > 0 else { return }
        var acc = 0
        var n: UInt64 = 0
        for size in sizes.reversed() {
            acc += size
            if acc > unsentBytes { break }
            n += 1
        }
        if n > 0 { atomicCounters.lostInTransport.add(n, ordering: .relaxed) }
    }

    /// 等唤醒或超时（超时由一个定时 Task 补一个唤醒；被真唤醒时把它取消）。
    private func waitWake(_ wake: inout AsyncStream<Void>.AsyncIterator, ms: Double) async {
        let wc = wakeContinuation
        let timer = Task {
            try? await Task.sleep(for: .milliseconds(max(1, Int(ms))))
            if !Task.isCancelled { wc.yield() }
        }
        _ = await wake.next()
        timer.cancel()
    }
}

/// 带超时的 await。
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(max(1, Int(seconds * 1000))))
            throw StreamTransportError.connectTimedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
