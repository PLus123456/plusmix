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
/// - 停止：`stop(atTick:)` 之后 tick ≥ 该拍的帧与 host time ≥ 该拍时刻的音频样本都不进文件，两轨时长同源相等。
///
/// 线程：`consume` 只转给编码器（立即返回）；`consumeAudio` 只拷进环（立即返回）；writer 的所有调用都在 `writerQueue` 上串行。
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
        /// 音频硬校正阈值；nil = 不校正只监控。默认一帧。
        public var audioResyncThreshold: HostDuration?
        /// 名字（消费者名 / 线程名）。
        public var name: String

        public init(url: URL, format: ProgramFormat, video: VideoEncodeSettings = VideoEncodeSettings(),
                    audio: AudioEncodeSettings? = AudioEncodeSettings(), audioChannels: Int = 2,
                    fragmentIntervalSeconds: Double = 1, remuxToMP4: Bool = false, queueDepth: Int = 3,
                    dataRateLimitFactor: Double = 1.5, minimumFreeBytes: UInt64 = 200 * 1024 * 1024,
                    audioResyncThreshold: HostDuration? = nil, name: String = "record") {
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
            self.audioResyncThreshold = audioResyncThreshold ?? HostDuration(seconds: format.frameDuration.doubleValue)
            self.name = name
        }
    }

    /// 状态。
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case stopping
        case finished
        case failed(String)
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
    private var stopTick: Tick?                // stateLock；tick ≥ 它的帧不进文件
    private var stopTime: HostTime?            // 同上，音频用
    private let stopTickAtomic = Atomic<Int64>(Int64.max)

    // 以下只在 writerQueue 上碰
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pcmFormat: CMAudioFormatDescription?
    private var trackTimescale: Int32 = 60000
    private var originNs: Int64 = 0
    private var audioAnchored = false
    private var audioFramesAppended: Int64 = 0
    private var lastDiskCheck: HostTime = .zero
    private var finishRequested = false
    private var pendingVideo: [EncodedVideoSample] = []
    private var completion: (@Sendable (Result<RecordingResult, Swift.Error>) -> Void)?
    private var failure: String?

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
    /// 计数快照。
    public var counters: RecorderCounters {
        var c = countersSnapshot()
        c.encoder = encoder.counters
        return c
    }
    /// 编码队列是否已满（喂料背压用）。
    public var isQueueFull: Bool { encoder.isQueueFull }
    /// 起点。
    public var recordingStart: RecordingStart? { stateLock.withLock { start } }

    private func countersSnapshot() -> RecorderCounters { atomicCounters.snapshot() }

    private func setState(_ s: State) { stateLock.withLock { stateValue = s } }

    // MARK: 开始 / 停止

    /// 开始：`start.tickTime` 成为文件时间 0；之后 tick ≥ start.tick 的帧进文件。
    public func start(at start: RecordingStart) throws {
        try stateLock.withLock {
            guard stateValue == .idle else { throw Error.notIdle }
            self.start = start
            stopTick = nil
            stopTime = nil
            stopTickAtomic.store(Int64.max, ordering: .relaxed)
            stateValue = .recording
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

    /// 停止。`atTick` 给出边界（tick ≥ 它的帧不进文件），nil = 此刻起不再收帧。
    /// 假定 tick < atTick 的帧此时都已经 consume 过（喂料方先停喂再停录制）。
    /// completion 在 writer 队列上被调；转封装（若配置）完成后才调。
    public func stop(atTick tick: Tick? = nil, completion: @escaping @Sendable (Result<RecordingResult, Swift.Error>) -> Void) {
        let proceed: Bool = stateLock.withLock {
            guard stateValue == .recording, let start else { return false }
            stateValue = .stopping
            let boundary = tick ?? Tick(Int64.max)
            stopTick = boundary
            if boundary.rawValue != Int64.max {
                let spec = TickClockSpec(t0: start.tickTime, frameDuration: configuration.format.frameDuration)
                stopTime = start.tickTime + spec.duration(ofTicks: Int(boundary - start.tick))
            } else {
                stopTime = HostClock.now()
            }
            stopTickAtomic.store(boundary.rawValue, ordering: .relaxed)
            return true
        }
        guard proceed else {
            completion(.failure(Error.notRecording))
            return
        }
        writerQueue.async { [self] in self.completion = completion }
        // 编码器的 stop 会阻塞到队列排空、在途帧回调完；不占调用方线程
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            encoder.stop()
            writerQueue.async { [self] in
                finishRequested = true
                drainAudio()
                finishIfReady()
            }
        }
    }

    // MARK: FrameConsumer

    public func consume(_ frame: RenderedFrame) {
        guard let start = stateLock.withLock({ stateValue == .recording ? self.start : nil }) else { return }
        guard frame.tick >= start.tick, frame.tick.rawValue < stopTickAtomic.load(ordering: .relaxed) else { return }
        encoder.consume(frame)
    }

    // MARK: AudioBlockConsumer

    public func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        guard let audioRing, channelCount == configuration.audioChannels else { return }
        let s = stateLock.withLock { stateValue }
        guard s == .recording || s == .stopping else { return }
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

    /// 把环里的音频块写进去（第一块裁到起点；末块裁到终点；样本计数连续）。
    private func drainAudio() {
        guard let audioRing, let w = writer, let ain = audioInput, let pcmFormat, failure == nil else { return }
        let stopNs: Int64? = stateLock.withLock { stopTime.map { Int64($0.nanoseconds) } }
        let rate = Int64(AudioFormat.sampleRate)
        while let block = audioRing.pop() {
            var blockStartNs = Int64(block.hostTime.nanoseconds)
            var skip = 0
            var n = block.frameCount
            if !audioAnchored {
                if blockStartNs < originNs {
                    skip = Int(((originNs - blockStartNs) * rate + 500_000_000) / 1_000_000_000)
                    if skip >= n { continue }   // 整块都在起点之前
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
                        // 音频晚到：中间空了一段，补静音
                        let silence = Int(driftNs * rate / 1_000_000_000)
                        appendSilence(frames: silence, w: w, ain: ain, format: pcmFormat)
                    } else {
                        // 音频早到 / 重叠：丢掉重叠的样本
                        skip = min(n, Int(-driftNs * rate / 1_000_000_000))
                    }
                }
            }
            blockStartNs += Int64(skip) * 1_000_000_000 / rate
            if let stopNs {
                if blockStartNs >= stopNs { continue }
                let maxFrames = Int(((stopNs - blockStartNs) * rate + 999_999_999) / 1_000_000_000)
                n = min(n, skip + maxFrames)
            }
            let frames = n - skip
            guard frames > 0 else { continue }
            var planes: [UnsafeMutableRawPointer] = []
            planes.reserveCapacity(configuration.audioChannels)
            for ch in 0..<configuration.audioChannels { planes.append(UnsafeMutableRawPointer(block.planes[ch] + skip)) }
            appendPCM(planes: planes, frames: frames, w: w, ain: ain, format: pcmFormat)
            if failure != nil { return }
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
        var waited = 0
        while !ain.isReadyForMoreMediaData && waited < 400 { usleep(500); waited += 1 }
        guard ain.isReadyForMoreMediaData else { return }
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
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
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
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(0, cap))
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

    func snapshot() -> RecorderCounters {
        var c = RecorderCounters()
        c.videoFrames = videoFrames.load(ordering: .relaxed)
        c.videoFramesRejected = videoFramesRejected.load(ordering: .relaxed)
        c.audioFrames = audioFrames.load(ordering: .relaxed)
        c.audioBlocksDropped = audioBlocksDropped.load(ordering: .relaxed)
        c.audioDrift = HostDuration(ticks: audioDriftTicks.load(ordering: .relaxed))
        c.audioCorrections = audioCorrections.load(ordering: .relaxed)
        c.diskFreeBytes = diskFreeBytes.load(ordering: .relaxed)
        return c
    }
}
