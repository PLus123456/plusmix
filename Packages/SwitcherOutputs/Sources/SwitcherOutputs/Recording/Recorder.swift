import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import SwitcherContracts

/// 录制器（设计方案 §8 录制行、§12 决策 7 / 10）：AVAssetWriter 写 QuickTime .mov，movieFragmentInterval 默认 1 s。
///
/// 时间基：`RecordingStart.tickTime`（开始录制那一拍的拍点时刻）= 0。
/// - 视频：压缩样本来自自己的 VideoEncoder（PTS = 拍点时刻），这里减去起点、换到轨道 timescale（一帧恰好整数个单位）后直通写入。
/// - 音频：PCM 块（非交错 float32 48 kHz）经入口环到 writer 队列，第一块按样本裁到起点，之后按样本计数连续追加，
///   writer 自己编 AAC 或写 LPCM。每块的 host time 用来监控与样本时间轴的偏差（`RecorderCounters.audioDrift`），
///   超过 `audioResyncThreshold` 就插静音 / 丢样本硬校正一次并计数 —— 这是安全网，正常情况下混音器已把设备时钟拉到 host 时钟（W2-E）。
///   为什么不用 AudioEncoder 直通：AVAssetWriter 对 AAC 直通包套自己的 priming 模型，实测 7 种约定里没有一种能既对齐又不截尾（报告探针 7）。
/// - 停止：边界 = 一个拍。tick ≥ 边界的帧、拍点时刻 ≥ 边界的音频样本都不进文件（只计数），两轨同源等长。边界由 `setStopTick`
///   预告或 `stop(atTick:)` 给，都可以在边界之前调：录制器等 tick = 边界 − 1 的帧和边界之前的音频到齐（最多 `stopGrace`）再封口，
///   组装方不用赌时序（W2-E / G2 的问题单：以前边界之后到达的块会触发补静音、每块等 200 ms，封口拖到分钟级）。
///
/// 线程：`consume` 只转给编码器（立即返回）；`consumeAudio` 只拷进环（立即返回；越界 / 封口后的块在入口就丢并计数）；
/// writer 的所有调用都在 `writerQueue` 上串行。
/// 出错（写失败、磁盘满）：只停本录制、状态置 `.failed`，其他消费者不受影响（S7 的基础）。
public final class Recorder: FrameConsumer, AudioBlockConsumer, @unchecked Sendable {
    /// 参数。
    public struct Configuration: Sendable {
        /// 输出 .mov 路径（已存在则覆盖）。
        public var url: URL
        /// 节目格式（帧率决定轨道 timescale）。
        public var format: ProgramFormat
        /// 视频编码设置。
        public var video: VideoEncodeSettings
        /// 音频编码设置；nil = 没有音轨。
        public var audio: AudioEncodeSettings?
        /// 音频声道数。
        public var audioChannels: Int
        /// movieFragmentInterval（秒）；≤ 0 = 不分片。
        public var fragmentIntervalSeconds: Double
        /// 停止后转封装成 MP4（失败保留 .mov）。
        public var remuxToMP4: Bool
        /// 编码器队列深度。
        public var queueDepth: Int
        /// DataRateLimits 倍数。
        public var dataRateLimitFactor: Double
        /// 剩余空间低于此值（字节）就停止并报错。
        public var minimumFreeBytes: UInt64
        /// 音频块 host time 与样本计数时间轴偏差超过多少就硬校正一次（插静音 / 丢样本）。
        public var audioResync: AudioResync
        /// 封口宽限：stop 之后（边界拍点之前调的，从边界拍点起算）最多等这么久，让 tick = 边界 − 1 的帧和边界之前的音频到齐，
        /// 到期就按已到的封口。集成层的音频块比拍点晚"对齐延迟 + 一块 + 泵周期"（约 50–60 ms）到，默认 250 ms 够用；对齐延迟更大的组装方调大。
        public var stopGrace: HostDuration
        /// 名字（消费者名 / 线程名）。
        public var name: String

        /// 音频硬校正策略。
        public enum AudioResync: Hashable, Sendable {
            /// 只监控（RecorderCounters.audioDrift），不校正。
            case off
            /// 阈值 = 一帧时长（默认）。
            case oneFrame
            /// 自定阈值。
            case threshold(HostDuration)
        }

        public init(url: URL, format: ProgramFormat, video: VideoEncodeSettings = VideoEncodeSettings(),
                    audio: AudioEncodeSettings? = AudioEncodeSettings(), audioChannels: Int = 2,
                    fragmentIntervalSeconds: Double = 1, remuxToMP4: Bool = false, queueDepth: Int = 3,
                    dataRateLimitFactor: Double = 1.5, minimumFreeBytes: UInt64 = 200 * 1024 * 1024,
                    audioResync: AudioResync = .oneFrame, stopGrace: HostDuration = HostDuration(milliseconds: 250),
                    name: String = "record") {
            self.url = url
            self.format = format
            self.video = video
            self.audio = audio
            self.audioChannels = audioChannels
            self.fragmentIntervalSeconds = fragmentIntervalSeconds
            self.remuxToMP4 = remuxToMP4
            self.queueDepth = queueDepth
            self.dataRateLimitFactor = dataRateLimitFactor
            self.minimumFreeBytes = minimumFreeBytes
            self.audioResync = audioResync
            self.stopGrace = stopGrace
            self.name = name
        }

        /// 实际阈值；nil = 不校正。
        public var audioResyncThreshold: HostDuration? {
            switch audioResync {
            case .off: nil
            case .oneFrame: HostDuration(seconds: format.frameDuration.doubleValue)
            case .threshold(let d): d
            }
        }
    }

    /// 状态。
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case stopping
        case finished
        case failed(String)

        /// Stats.encoder[i].state（提案 002）用的名字：idle / recording / stopping / stopped / failed。
        public var statsName: String {
            switch self {
            case .idle: "idle"
            case .recording: "recording"
            case .stopping: "stopping"
            case .finished: "stopped"
            case .failed: "failed"
            }
        }
    }

    /// 错误。
    public enum Error: Swift.Error, Equatable {
        case notIdle
        case writerCreateFailed(String)
        case writerFailed(String)
        case diskFull(freeBytes: UInt64)
        case notRecording
    }

    public let configuration: Configuration
    public let consumerName: String
    /// 视频编码器（可读它的计数）。
    public let encoder: VideoEncoder

    private let writerQueue: DispatchQueue
    private let stateLock = NSLock()
    private var stateValue: State = .idle
    private var start: RecordingStart?
    private var stopTick: Tick?                // stateLock；边界：tick ≥ 它的帧不进文件（setStopTick 或 stop 设）
    private var stopTime: HostTime?            // 同上，边界的拍点时刻，音频用
    private var stopAnnounced = false          // 同上，边界来自 setStopTick
    private let stopTickAtomic = Atomic<Int64>(Int64.max)          // consume 用
    private let stopTimeTicksAtomic = Atomic<UInt64>(UInt64.max)   // consumeAudio 用（host tick）
    private let lastConsumedTick = Atomic<Int64>(Int64.min)        // 最后一个交给编码器的帧的 tick
    private let audioSealedAtomic = Atomic<Bool>(false)            // writer 的音频输入已 markAsFinished
    private let stopSignal = DispatchSemaphore(value: 0)            // consume 在边界前一拍 / 越界帧到时叫醒 stop 的等待

    // 以下只在 writerQueue 上碰
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pcmFormat: CMAudioFormatDescription?
    private var trackTimescale: Int32 = 60000
    private var originNs: Int64 = 0
    private var audioAnchored = false
    private var audioFramesAppended: Int64 = 0
    private var audioSealed = false            // 音频输入已 markAsFinished：之后到的块只计数
    private var lastDiskCheck: HostTime = .zero
    private var finishRequested = false
    private var finishDeadline: HostTime = .zero   // 封口宽限到期时刻（stop 请求时定）
    private var completion: (@Sendable (Result<RecordingResult, Swift.Error>) -> Void)?
    private var failure: String?
    private var startedAt: HostTime?           // stateLock；提案 022 的 uptime_s 从它算
    private var lastErrorText = ""             // stateLock；提案 022 的 last_error：最近一次 .failed 的文案，start 清

    private let audioRing: AudioBlockRing?
    private let atomicCounters = AtomicRecorderCounters()
    private let audioBufferLists: UnsafeMutablePointer<AudioBufferList>?

    public init(configuration: Configuration) {
        self.configuration = configuration
        consumerName = configuration.name
        encoder = VideoEncoder(configuration: .init(
            name: configuration.name, format: configuration.format, settings: configuration.video,
            queueDepth: configuration.queueDepth, dataRateLimitFactor: configuration.dataRateLimitFactor))
        writerQueue = DispatchQueue(label: "switcher.recorder.\(configuration.name)", qos: .userInitiated)
        if configuration.audio != nil {
            audioRing = AudioBlockRing(channelCount: configuration.audioChannels, maxFrames: 4096, capacity: 256)
            // 非交错 ABL 需要 channelCount 个 AudioBuffer；AudioBufferList 本身只带 1 个，按字节多分配
            let bytes = MemoryLayout<AudioBufferList>.size + (configuration.audioChannels - 1) * MemoryLayout<AudioBuffer>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
            audioBufferLists = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        } else {
            audioRing = nil
            audioBufferLists = nil
        }
    }

    deinit {
        if let audioBufferLists { UnsafeMutableRawPointer(audioBufferLists).deallocate() }
    }

    /// 状态（任意线程）。
    public var state: State { stateLock.withLock { stateValue } }
    /// 计数快照（提案 022：uptimeSeconds 只在 recording / stopping 时非 0；lastError = 最近一次失败的文案，start 清）。
    public var counters: RecorderCounters {
        var c = countersSnapshot()
        c.encoder = encoder.counters
        let (state, started, lastError) = stateLock.withLock { (stateValue, startedAt, lastErrorText) }
        switch state {
        case .recording, .stopping: c.uptimeSeconds = started.map { max(0, (HostClock.now() - $0).seconds) } ?? 0
        default: c.uptimeSeconds = 0
        }
        c.lastError = lastError
        return c
    }
    /// Stats.encoder[i] 的一项（提案 001 / 002）：见 `RecorderCounters.statsEntry`；state 按录制状态。只在 Stats 采样线程上调（每秒一次）。
    public func statsEntry(previous: RecorderCounters?, windowSeconds: Double, output: Int = 0) -> Stats.EncoderEntry {
        counters.statsEntry(previous: previous, windowSeconds: windowSeconds, state: state.statsName, output: output)
    }
    /// 编码队列是否已满（喂料背压用）。
    public var isQueueFull: Bool { encoder.isQueueFull }
    /// 起点。
    public var recordingStart: RecordingStart? { stateLock.withLock { start } }

    private func countersSnapshot() -> RecorderCounters { atomicCounters.snapshot() }

    private func setState(_ s: State) {
        stateLock.withLock {
            stateValue = s
            if case .failed(let message) = s { lastErrorText = message }   // 022：last_error
        }
    }

    // MARK: 开始 / 停止

    /// 开始：`start.tickTime` 成为文件时间 0；之后 tick ≥ start.tick 的帧进文件。
    public func start(at start: RecordingStart) throws {
        try stateLock.withLock {
            guard stateValue == .idle else { throw Error.notIdle }
            self.start = start
            stopTick = nil
            stopTime = nil
            stopAnnounced = false
            stopTickAtomic.store(Int64.max, ordering: .relaxed)
            stopTimeTicksAtomic.store(UInt64.max, ordering: .relaxed)
            lastConsumedTick.store(Int64.min, ordering: .relaxed)
            audioSealedAtomic.store(false, ordering: .relaxed)
            stateValue = .recording
            startedAt = HostClock.now()   // 022：uptime_s 的起点；下一次 start 清上一次的错误
            lastErrorText = ""
        }
        let free = Recorder.freeBytes(for: configuration.url)
        atomicCounters.diskFreeBytes.store(free, ordering: .relaxed)
        if free < configuration.minimumFreeBytes {
            setState(.failed("磁盘剩余 \(free) 字节，低于下限 \(configuration.minimumFreeBytes)"))
            throw Error.diskFull(freeBytes: free)
        }
        try? FileManager.default.removeItem(at: configuration.url)
        trackTimescale = configuration.format.trackTimescale
        originNs = Int64(start.tickTime.nanoseconds)
        encoder.output = { [weak self] sample in self?.enqueueVideo(sample) }
        do {
            try encoder.start()
        } catch {
            setState(.failed("编码器启动失败：\(error)"))
            throw error
        }
    }

    /// 预告停止拍（边界），可以在边界之前调，录制照常继续：从此 tick ≥ 它的帧、拍点时刻 ≥ 它的音频样本都只计数不进文件，
    /// 两轨由录制器自己截到边界；组装方之后什么时候调 `stop`（nil 或同一拍）都行，不用等含边界的音频块到了再停。
    /// 返回实际生效的边界：可能比要求的晚（tick ≥ 要求值的帧已经进了文件时取最后一帧的下一拍）；
    /// nil = 没在录，或已按先前的边界丢过越界内容、改不了（改了中间会有洞）。
    @discardableResult
    public func setStopTick(_ tick: Tick) -> Tick? {
        stateLock.withLock {
            guard stateValue == .recording, let start else { return nil }
            guard let effective = applyBoundary(tick, start: start) else { return nil }
            stopAnnounced = true
            return effective
        }
    }

    /// 停止。`atTick` = 边界：tick ≥ 它的帧、拍点时刻 ≥ 它的音频样本都不进文件，两轨同源等长。
    /// - 边界之后调（tick < 边界的帧都已 consume 过）：立刻停编码器；音频若还差边界之前的那几块（集成层的块比拍点晚到），最多等 `stopGrace`。
    /// - 边界之前调（"停止"= 当前拍 + 1 的场景）：先等 tick = 边界 − 1 的帧（或越界帧、或宽限到期）再停编码器，然后同上。
    /// - nil：用 `setStopTick` 预告的边界；没预告则 = 最后一个已收帧的下一拍（一帧没收过 = 起始拍，封口会以"没有视频帧"失败）。
    /// 边界与预告的不同时按 `setStopTick` 的规则改，改不了就沿用预告的；实际用的边界在 `RecordingResult.stopTick`。
    /// completion 在 writer 队列上被调；转封装（若配置）完成后才调。
    public func stop(atTick tick: Tick? = nil, completion: @escaping @Sendable (Result<RecordingResult, Swift.Error>) -> Void) {
        let plan: (boundary: Tick, deadline: HostTime)? = stateLock.withLock {
            guard stateValue == .recording, let start else { return nil }
            if let tick {
                _ = applyBoundary(tick, start: start)
            } else if stopTick == nil {
                let last = lastConsumedTick.load(ordering: .relaxed)
                _ = applyBoundary(last == Int64.min ? start.tick : Tick(last + 1), start: start)
            }
            guard let boundary = stopTick, let stopTime else { return nil }
            stateValue = .stopping
            // 宽限从边界拍点起算（边界之前调的：先录到边界）；边界之后才调的从此刻起算。只有边界之前的帧 / 音频还没到齐才会真的等
            let deadline = max(stopTime, HostClock.now()) + configuration.stopGrace
            return (boundary, deadline)
        }
        guard let plan else {
            completion(.failure(Error.notRecording))
            return
        }
        writerQueue.async { [self] in self.completion = completion }
        // 编码器的 stop 会阻塞到队列排空、在途帧回调完；不占调用方线程
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 边界之前调的：等 tick = 边界 − 1 的帧（或越界帧）到齐，最多到宽限到期
            while !videoComplete(boundary: plan.boundary) {
                let remaining = plan.deadline - HostClock.now()
                guard remaining.ticks > 0 else { break }
                _ = stopSignal.wait(timeout: .now() + .nanoseconds(Int(remaining.nanoseconds)))
            }
            encoder.stop()
            writerQueue.async { [self] in
                finishRequested = true
                finishDeadline = plan.deadline
                drainAudio()
                scheduleFinish()
            }
        }
    }

    /// stateLock 内：把边界设成 `tick`，返回实际生效的边界。
    /// - 不早于已收的帧：tick ≥ 边界的帧不能已经进了文件，所以 clamp 到最后一个已收帧的下一拍（也不早于起始拍）。
    /// - 已有边界且要改：只有还没按旧边界丢过越界帧 / 样本才允许（丢过再往后挪，中间就是洞）；改不了返回 nil，旧边界保留。
    private func applyBoundary(_ tick: Tick, start: RecordingStart) -> Tick? {
        if let current = stopTick, current != tick {
            guard atomicCounters.videoFramesBeyondStop.load(ordering: .relaxed) == 0,
                  atomicCounters.audioFramesBeyondStop.load(ordering: .relaxed) == 0 else { return nil }
        }
        let last = lastConsumedTick.load(ordering: .relaxed)
        let floor = last == Int64.min ? start.tick : Tick(last + 1)
        let effective = max(tick, floor, start.tick)
        let spec = TickClockSpec(t0: start.tickTime, frameDuration: configuration.format.frameDuration)
        let time = start.tickTime + spec.duration(ofTicks: Int(effective - start.tick))
        stopTick = effective
        stopTime = time
        stopTickAtomic.store(effective.rawValue, ordering: .relaxed)
        stopTimeTicksAtomic.store(time.ticks, ordering: .relaxed)
        return effective
    }

    /// 边界之前的帧是否都到了（或不会再来）：收到过越界帧、最后一个已收帧 = 边界 − 1、或录制已不在 stopping（失败了）。
    private func videoComplete(boundary: Tick) -> Bool {
        if atomicCounters.videoFramesBeyondStop.load(ordering: .relaxed) > 0 { return true }
        let (startTick, stopping): (Tick?, Bool) = stateLock.withLock { (start?.tick, stateValue == .stopping) }
        guard stopping, let startTick else { return true }
        let last = lastConsumedTick.load(ordering: .relaxed)
        let next = last == Int64.min ? startTick.rawValue : last + 1
        return next >= boundary.rawValue
    }

    // MARK: FrameConsumer

    public func consume(_ frame: RenderedFrame) {
        let (start, state): (RecordingStart?, State) = stateLock.withLock { (self.start, stateValue) }
        guard let start, state == .recording || state == .stopping || state == .finished else { return }
        guard frame.tick >= start.tick else { return }
        let boundary = stopTickAtomic.load(ordering: .relaxed)
        if frame.tick.rawValue >= boundary {
            // 越界帧按设计不进文件（封口之后组装方还没摘消费者时照样计数）；它到了也说明边界之前的帧都到了，叫醒 stop 的等待
            atomicCounters.videoFramesBeyondStop.add(1, ordering: .relaxed)
            stopSignal.signal()
            return
        }
        guard state != .finished else { return }   // 封口之后才到的边界之前的帧：编码器已停（正常不会发生）
        lastConsumedTick.store(frame.tick.rawValue, ordering: .relaxed)
        encoder.consume(frame)
        if frame.tick.rawValue == boundary &- 1 { stopSignal.signal() }
    }

    // MARK: AudioBlockConsumer

    public func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        guard let audioRing else { return }
        let s = stateLock.withLock { stateValue }
        guard s == .recording || s == .stopping || s == .finished else { return }
        guard channelCount == configuration.audioChannels else {
            atomicCounters.audioBlocksDropped.add(1, ordering: .relaxed)
            return
        }
        // 越界的块（块首 PTS ≥ 边界拍点）在入口就丢：只计数，不进环、不占 writer 队列、不参与漂移 / 补静音
        if hostTime.ticks >= stopTimeTicksAtomic.load(ordering: .relaxed) {
            atomicCounters.audioFramesBeyondStop.add(UInt64(frameCount), ordering: .relaxed)
            return
        }
        // 音轨已封口：边界之前的样本来晚了（组装方送得比 stopGrace 还晚），丢并计数
        if audioSealedAtomic.load(ordering: .relaxed) {
            atomicCounters.audioFramesDroppedAfterStop.add(UInt64(frameCount), ordering: .relaxed)
            return
        }
        if audioRing.push(planes: planes, frameCount: frameCount, hostTime: hostTime) {
            atomicCounters.audioBlocksDropped.add(1, ordering: .relaxed)
        }
        writerQueue.async { [self] in drainAudio() }
    }

    // MARK: writer 队列

    private func enqueueVideo(_ sample: EncodedVideoSample) {
        writerQueue.async { [self] in
            guard failure == nil else { return }
            if writer == nil {
                do { try createWriter(firstSample: sample) } catch { fail("\(error)"); return }
            }
            appendVideo(sample)
            drainAudio()
            maybeCheckDisk(now: sample.outputTime)
        }
    }

    private func createWriter(firstSample: EncodedVideoSample) throws {
        guard let fmt = firstSample.formatDescription else { throw Error.writerCreateFailed("第一帧没有格式描述") }
        let w: AVAssetWriter
        do { w = try AVAssetWriter(outputURL: configuration.url, fileType: .mov) } catch { throw Error.writerCreateFailed("\(error)") }
        w.shouldOptimizeForNetworkUse = false
        w.movieTimeScale = CMTimeScale(trackTimescale)
        if configuration.fragmentIntervalSeconds > 0 {
            w.movieFragmentInterval = CMTime(seconds: configuration.fragmentIntervalSeconds, preferredTimescale: 1000)
        }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        vin.expectsMediaDataInRealTime = true
        vin.mediaTimeScale = CMTimeScale(trackTimescale)
        guard w.canAdd(vin) else { throw Error.writerCreateFailed("视频输入不被接受") }
        w.add(vin)
        if let audio = configuration.audio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(AudioFormat.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(configuration.audioChannels),
                mBitsPerChannel: 32, mReserved: 0)
            var pcm: CMAudioFormatDescription?
            let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &pcm)
            guard st == noErr, let pcm else { throw Error.writerCreateFailed("PCM 格式描述失败 \(st)") }
            pcmFormat = pcm
            let settings: [String: Any]
            switch audio.codec {
            case .aac:
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioFormat.sampleRate,
                            AVNumberOfChannelsKey: configuration.audioChannels, AVEncoderBitRateKey: audio.bitrateBps]
            case .pcm:
                settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioFormat.sampleRate,
                            AVNumberOfChannelsKey: configuration.audioChannels, AVLinearPCMBitDepthKey: 24,
                            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            }
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: pcm)
            ain.expectsMediaDataInRealTime = true
            guard w.canAdd(ain) else { throw Error.writerCreateFailed("音频输入不被接受") }
            w.add(ain)
            audioInput = ain
        }
        guard w.startWriting() else { throw Error.writerCreateFailed(w.error.map { "\($0)" } ?? "startWriting 失败") }
        w.startSession(atSourceTime: .zero)
        writer = w
        videoInput = vin
    }

    /// 绝对纳秒 PTS → 相对轨道时间（起点为 0，四舍五入到轨道 timescale）。
    private func trackTime(absoluteNs: Int64) -> CMTime {
        let rel = CMTime(value: absoluteNs - originNs, timescale: 1_000_000_000)
        return CMTimeConvertScale(rel, timescale: CMTimeScale(trackTimescale), method: .roundHalfAwayFromZero)
    }

    private func appendVideo(_ sample: EncodedVideoSample) {
        guard let w = writer, let vin = videoInput, failure == nil else { return }
        let pts = trackTime(absoluteNs: Int64(sample.tickTime.nanoseconds))
        let duration = CMTimeConvertScale(configuration.format.frameDuration.cmTime, timescale: CMTimeScale(trackTimescale), method: .roundHalfAwayFromZero)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample.sampleBuffer, sampleTimingEntryCount: 1,
                                                       sampleTimingArray: &timing, sampleBufferOut: &retimed)
        guard st == noErr, let retimed else { atomicCounters.videoFramesRejected.add(1, ordering: .relaxed); return }
        var waited = 0
        while !vin.isReadyForMoreMediaData && waited < 400 { usleep(500); waited += 1 }
        guard vin.isReadyForMoreMediaData else { atomicCounters.videoFramesRejected.add(1, ordering: .relaxed); return }
        if vin.append(retimed) {
            atomicCounters.videoFrames.add(1, ordering: .relaxed)
        } else {
            fail(w.error.map { "视频写入失败：\($0)" } ?? "视频写入失败")
        }
        if w.status == .failed { fail(w.error.map { "\($0)" } ?? "writer failed") }
    }

    /// 把环里的音频块写进去（第一块裁到起点；末块裁到边界；样本计数连续）。
    /// 边界之后的块先于漂移判断跳过并计数——否则它们每块都算成"晚到 5.33 ms"、累计超过一帧就补静音，补的长度随墙钟增长（W2-E 的问题单）。
    private func drainAudio() {
        guard let audioRing else { return }
        if audioSealed {
            // 音轨已封口：环里剩下的（封口那一刻之前刚进来的）只计数
            while let block = audioRing.pop() { atomicCounters.audioFramesDroppedAfterStop.add(UInt64(block.frameCount), ordering: .relaxed) }
            return
        }
        guard let w = writer, let ain = audioInput, let pcmFormat, failure == nil else { return }
        let stopNs: Int64? = stateLock.withLock { stopTime.map { Int64($0.nanoseconds) } }
        let rate = Int64(AudioFormat.sampleRate)
        while let block = audioRing.pop() {
            var blockStartNs = Int64(block.hostTime.nanoseconds)
            var skip = 0
            var n = block.frameCount
            if let stopNs, blockStartNs >= stopNs {
                atomicCounters.audioFramesBeyondStop.add(UInt64(n), ordering: .relaxed)
                continue
            }
            if !audioAnchored {
                if blockStartNs < originNs {
                    skip = Int(((originNs - blockStartNs) * rate + 500_000_000) / 1_000_000_000)
                    if skip >= n { continue }   // 整块都在起点之前
                } else if blockStartNs > originNs {
                    // 首块晚到（来源开录时没就绪 / 入口积压丢了最早的块）：先补起点到它之间的静音（不越过边界，同下面的漂移分支），
                    // 首样本落在它自己的时间戳上。原来直接写到样本 0、下一块才按漂移补，声音整体提前（N10）
                    var silence = Int(((blockStartNs - originNs) * rate + 500_000_000) / 1_000_000_000)
                    if let stopNs { silence = min(silence, max(0, Int((stopNs - originNs) * rate / 1_000_000_000))) }
                    appendSilence(frames: silence, w: w, ain: ain, format: pcmFormat)
                    if failure != nil { return }
                }
                audioAnchored = true
            } else {
                // 偏差监控：这一块首样本应当在的时刻 vs 实际打的戳
                let expectedNs = originNs + audioFramesAppended * 1_000_000_000 / rate
                let driftNs = blockStartNs - expectedNs
                atomicCounters.audioDriftTicks.store(HostDuration(nanoseconds: driftNs).ticks, ordering: .relaxed)
                if let threshold = configuration.audioResyncThreshold, abs(driftNs) > threshold.nanoseconds {
                    atomicCounters.audioCorrections.add(1, ordering: .relaxed)
                    if driftNs > 0 {
                        // 音频晚到：中间空了一段，补静音（不越过边界）
                        var silence = Int(driftNs * rate / 1_000_000_000)
                        if let stopNs { silence = min(silence, max(0, Int((stopNs - expectedNs) * rate / 1_000_000_000))) }
                        appendSilence(frames: silence, w: w, ain: ain, format: pcmFormat)
                    } else {
                        // 音频早到 / 重叠：丢掉重叠的样本
                        skip = min(n, Int(-driftNs * rate / 1_000_000_000))
                    }
                }
            }
            blockStartNs += Int64(skip) * 1_000_000_000 / rate
            if let stopNs {
                if blockStartNs >= stopNs {
                    atomicCounters.audioFramesBeyondStop.add(UInt64(n - skip), ordering: .relaxed)
                    continue
                }
                // 含边界的块：裁到边界（向上取整到样本），裁掉的尾巴计入越界
                let maxFrames = Int(((stopNs - blockStartNs) * rate + 999_999_999) / 1_000_000_000)
                if skip + maxFrames < n {
                    atomicCounters.audioFramesBeyondStop.add(UInt64(n - skip - maxFrames), ordering: .relaxed)
                    n = skip + maxFrames
                }
            }
            let frames = n - skip
            guard frames > 0 else { continue }
            var planes: [UnsafeMutableRawPointer] = []
            planes.reserveCapacity(configuration.audioChannels)
            for ch in 0..<configuration.audioChannels { planes.append(UnsafeMutableRawPointer(block.planes[ch] + skip)) }
            appendPCM(planes: planes, frames: frames, w: w, ain: ain, format: pcmFormat)
            if failure != nil { return }
        }
        // stop 已请求、音频写到边界了：现在就封口，不用等宽限到期
        if finishRequested, audioReachedStop() { finishIfReady() }
    }

    /// writer 队列：音轨是否已写到边界。差不到一个样本也算到了——喂到"边界之前最后一个样本"的组装方（SignalFeeder.flush）就是这样。
    private func audioReachedStop() -> Bool {
        guard let stopNs = stateLock.withLock({ stopTime.map { Int64($0.nanoseconds) } }) else { return true }
        let rate = Int64(AudioFormat.sampleRate)
        let endNs = originNs + audioFramesAppended * 1_000_000_000 / rate
        return endNs + 1_000_000_000 / rate >= stopNs
    }

    /// writer 队列，stop 请求之后：音轨还没到边界且宽限没到期就等（到期兜底封口；期间每块到了 drainAudio 都会再判一次），否则现在封口。
    private func scheduleFinish() {
        guard finishRequested else { return }
        let audioPending = writer != nil && audioInput != nil && failure == nil && !audioReachedStop()
        let remaining = finishDeadline - HostClock.now()
        if audioPending && remaining.ticks > 0 {
            writerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining.nanoseconds))) { [self] in finishIfReady() }
        } else {
            finishIfReady()
        }
    }

    private func appendSilence(frames: Int, w: AVAssetWriter, ain: AVAssetWriterInput, format: CMAudioFormatDescription) {
        guard frames > 0 else { return }
        let chunk = 4096
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: chunk * 4, alignment: 16)
        defer { zeros.deallocate() }
        zeros.initializeMemory(as: Float.self, repeating: 0, count: chunk)
        var left = frames
        while left > 0 && failure == nil {
            let n = min(left, chunk)
            appendPCM(planes: Array(repeating: zeros, count: configuration.audioChannels), frames: n, w: w, ain: ain, format: format)
            left -= n
        }
    }

    private func appendPCM(planes: [UnsafeMutableRawPointer], frames: Int, w: AVAssetWriter, ain: AVAssetWriterInput, format: CMAudioFormatDescription) {
        guard let abl = audioBufferLists else { return }
        let pts = CMTime(value: audioFramesAppended, timescale: CMTimeScale(AudioFormat.sampleRate))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(AudioFormat.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        var sampleSize = 4
        let st = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb)
        guard st == noErr, let sb else { return }
        abl.pointee.mNumberBuffers = UInt32(configuration.audioChannels)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for ch in 0..<configuration.audioChannels {
            buffers[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: planes[ch])
        }
        let dst = CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                 flags: 0, bufferList: abl)
        guard dst == noErr else { return }
        // expectsMediaDataInRealTime 的输入几乎总是 ready；这里的等待只是安全网，等不到就丢并计数（G2 的问题单：以前静默丢）
        var waited = 0
        while !ain.isReadyForMoreMediaData && waited < 400 { usleep(500); waited += 1 }
        guard ain.isReadyForMoreMediaData else {
            atomicCounters.audioFramesDroppedTimeout.add(UInt64(frames), ordering: .relaxed)
            return
        }
        if ain.append(sb) {
            audioFramesAppended += Int64(frames)
            atomicCounters.audioFrames.add(UInt64(frames), ordering: .relaxed)
        } else {
            fail(w.error.map { "音频写入失败：\($0)" } ?? "音频写入失败")
        }
    }

    private func maybeCheckDisk(now: HostTime) {
        guard (now - lastDiskCheck).seconds >= 1 else { return }
        lastDiskCheck = now
        let free = Recorder.freeBytes(for: configuration.url)
        atomicCounters.diskFreeBytes.store(free, ordering: .relaxed)
        if free < configuration.minimumFreeBytes {
            fail("磁盘剩余 \(free) 字节，低于下限 \(configuration.minimumFreeBytes)")
        }
    }

    /// 写失败：停编码器、取消 writer、状态置 error。只影响本录制。
    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        setState(.failed(message))
        stopTickAtomic.store(Int64.min, ordering: .relaxed)
        stopSignal.signal()
        if let w = writer, w.status == .writing { w.cancelWriting() }
        writer = nil
        DispatchQueue.global(qos: .utility).async { [self] in encoder.stop() }
        if let completion {
            self.completion = nil
            completion(.failure(Error.writerFailed(message)))
        }
    }

    private func finishIfReady() {
        guard finishRequested else { return }
        if let failure {
            if let completion { self.completion = nil; completion(.failure(Error.writerFailed(failure))) }
            return
        }
        guard let w = writer, let start = stateLock.withLock({ self.start }), let stopTick = stateLock.withLock({ self.stopTick }) else {
            // 一帧都没写进去（没起 writer）
            let msg = "没有写入任何视频帧"
            setState(.failed(msg))
            if let completion { self.completion = nil; completion(.failure(Error.writerFailed(msg))) }
            return
        }
        finishRequested = false
        drainAudio()   // 宽限到期那一刻刚到的块也写进去（finishRequested 已清，不会再回调到这里）
        guard failure == nil else { return }   // 排空时写失败：fail() 已经回调过 completion
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        audioSealed = true
        audioSealedAtomic.store(true, ordering: .relaxed)
        let snapshot = countersSnapshot()
        let enc = encoder.counters
        let base = RecordingResult(
            url: configuration.url, mp4URL: nil, remuxError: nil, videoFrames: snapshot.videoFrames,
            audioFrames: snapshot.audioFrames,
            durationSeconds: Double(snapshot.videoFrames) * configuration.format.frameDuration.doubleValue,
            videoBytes: enc.bytes, encoder: enc, start: start, stopTick: stopTick)
        w.finishWriting { [self] in
            writerQueue.async { [self] in finishWritingCompleted(base) }
        }
    }

    // finishWriting 的回调之后（writer 队列）：检查状态、可选转封装、回调 completion。
    private func finishWritingCompleted(_ base: RecordingResult) {
        guard let w = writer else { return }
        if w.status != .completed {
            let msg = w.error.map { "finishWriting 失败：\($0)" } ?? "finishWriting 失败：status \(w.status.rawValue)"
            setState(.failed(msg))
            if let completion { self.completion = nil; completion(.failure(Error.writerFailed(msg))) }
            return
        }
        writer = nil
        guard configuration.remuxToMP4 else {
            setState(.finished)
            if let completion { self.completion = nil; completion(.success(base)) }
            return
        }
        Remux.toMP4(movURL: configuration.url) { [self] outcome in
            writerQueue.async { [self] in
                var result = base
                switch outcome {
                case .success(let mp4): result.mp4URL = mp4
                case .failure(let e): result.remuxError = "\(e)"
                }
                setState(.finished)
                if let completion { self.completion = nil; completion(.success(result)) }
            }
        }
    }

    /// 录制目录所在卷的可用空间。
    public static func freeBytes(for url: URL) -> UInt64 {
        let dir = url.deletingLastPathComponent()
        // importantUsage 是启动卷的概念（含可清理空间），非启动卷（磁盘镜像 / 外置盘）上系统给 0：0 就退到 volumeAvailableCapacity，
        // 再退到 systemFreeSize（问题单 W3C-w1-outputs-recorder-freebytes-nonboot-volume；G4 2026-09-27 按胶水额度修）
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            if let cap = v.volumeAvailableCapacityForImportantUsage, cap > 0 { return UInt64(cap) }
            if let cap = v.volumeAvailableCapacity, cap > 0 { return UInt64(cap) }
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
           let free = attrs[.systemFreeSize] as? UInt64 {
            return free
        }
        return 0
    }
}

/// 录制器的原子计数。
final class AtomicRecorderCounters: Sendable {
    let videoFrames = Atomic<UInt64>(0)
    let videoFramesRejected = Atomic<UInt64>(0)
    let audioFrames = Atomic<UInt64>(0)
    let audioBlocksDropped = Atomic<UInt64>(0)
    let audioDriftTicks = Atomic<Int64>(0)
    let audioCorrections = Atomic<UInt64>(0)
    let diskFreeBytes = Atomic<UInt64>(0)
    let videoFramesBeyondStop = Atomic<UInt64>(0)
    let audioFramesBeyondStop = Atomic<UInt64>(0)
    let audioFramesDroppedAfterStop = Atomic<UInt64>(0)
    let audioFramesDroppedTimeout = Atomic<UInt64>(0)

    func snapshot() -> RecorderCounters {
        var c = RecorderCounters()
        c.videoFrames = videoFrames.load(ordering: .relaxed)
        c.videoFramesRejected = videoFramesRejected.load(ordering: .relaxed)
        c.audioFrames = audioFrames.load(ordering: .relaxed)
        c.audioBlocksDropped = audioBlocksDropped.load(ordering: .relaxed)
        c.audioDrift = HostDuration(ticks: audioDriftTicks.load(ordering: .relaxed))
        c.audioCorrections = audioCorrections.load(ordering: .relaxed)
        c.diskFreeBytes = diskFreeBytes.load(ordering: .relaxed)
        c.videoFramesBeyondStop = videoFramesBeyondStop.load(ordering: .relaxed)
        c.audioFramesBeyondStop = audioFramesBeyondStop.load(ordering: .relaxed)
        c.audioFramesDroppedAfterStop = audioFramesDroppedAfterStop.load(ordering: .relaxed)
        c.audioFramesDroppedTimeout = audioFramesDroppedTimeout.load(ordering: .relaxed)
        return c
    }
}
