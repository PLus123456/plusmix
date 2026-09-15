import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import SwitcherContracts

/// 文件输入（设计方案 §6 "视频文件"）：AVAssetReader（内部 VideoToolbox 硬解）+ 时钟从属。
///
/// 时钟从属：播放位置 = 节目时钟经过的拍数 × 一拍秒数 × 速率（`FileTimeline`，全有理数）。推帧线程每拍醒一次
/// （拍点 − 相位提前量 − 推送提前量），把"位置 ≤ 本拍"的最新解码帧推进帧槽，pts = 拍点 − 相位提前量（默认半个节目帧），
/// 这样在引擎带到达余量的入口（`latest(forTick:)`，余量 ≥ 1/4 帧）当拍就合格；被速率跳过的帧计 `framesRejected`。
/// 60 fps 文件在 60 fps 节目里每拍恰好一帧；在 30 fps 节目里每拍前进两帧、每个帧号只出现一次；24 fps 文件在 60 fps
/// 节目里有的拍没有新帧，帧槽自然重复上一帧（设计内）。
///
/// - 预解码：解码线程领先推帧线程 `predecodeDepth`（3）帧；音频解成 float32 非交错 48 kHz 进 FIFO，最多囤 0.5 s。
/// - 循环：解码到结尾时立刻重开一个 reader（探针：2 ms + 首帧），展开后的媒体位置连续（第 k 圈 + k × 时长）。
/// - 定位 `seek`：换代——解码线程重开 reader，队列作废；新锚点 = 现在 + seekLead 之后的第一拍显示目标位置，所以定位到
///   第 300 帧后首帧就是 300。暂停：位置冻结，每拍把停住的帧以 pts = 拍点 重新推（帧槽不靠 reused 撑画面）。
/// - 结束动作：holdLastFrame → 末帧显示期结束时置 noSignal、不再推（帧槽保留末帧）；black → 推一帧黑场再置 noSignal；
///   loop → 循环。运行中可改。
/// - 音频：每 256 帧一块，块首 host time = 锚点拍时刻 + 块序号 × 256 / 48000，块在它的样本"发生之后"写（像真设备，
///   混音器的年龄设定点才对得上）；速率 ≠ 1 时按有理数位置线性插值变速（音调随之变）。
/// - 带 alpha 的素材（ProRes 4444 / HEVC alpha）输出 BGRA；解码器标 StraightAlpha 的就地预乘（渲染器约定预乘）。
/// - 线程：解码线程（普通优先级）+ 推帧线程（time-constraint，周期 = 一拍）。都允许锁和分配；帧槽 push / 环 write 无锁。
public final class FileInput: Input, @unchecked Sendable {
    /// 可调参数。
    public struct Options: Sendable, Hashable {
        /// 帧的 pts 相对拍点提前多少；nil = 半个节目帧。
        public var phaseLead: HostDuration?
        /// 比 pts 再早多久推进帧槽。
        public var pushLead = HostDuration(milliseconds: 2)
        /// 预解码深度（帧）。
        public var predecodeDepth = 3
        /// 音频块大小（帧）。
        public var audioChunkFrames = 256
        /// 音频解码领先上限（帧）。
        public var audioAheadFrames = AudioFormat.sampleRate / 2
        /// 定位 / 恢复后多久的第一拍作为新锚点。
        /// 目标位置的第一帧解出来之后，多久之后的第一拍作为新锚点。
        public var seekLead = HostDuration(milliseconds: 30)
        public init() {}
    }

    /// 文件输入自己的计数（InputCounters 之外）。
    public struct FileCounters: Hashable, Sendable {
        /// 该拍该有新帧但解码器还没给（解码跟不上 / 定位后重开中）的拍数。
        public var ticksStarved: UInt64 = 0
        /// 写进环的音频块数。
        public var audioChunksWritten: UInt64 = 0
        /// 到点了但 FIFO 里没有样本、被跳过的音频块数。
        public var audioChunksSkipped: UInt64 = 0
        /// 循环次数。
        public var loops: UInt64 = 0
        /// 定位次数。
        public var seeks: UInt64 = 0
        /// 推帧线程实际醒来比目标晚超过 1 ms 的次数。
        public var lateWakes: UInt64 = 0
        public init() {}
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .file
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)?
    public var state: InputState { stateBox.value }
    /// 文件路径。
    public let path: String
    /// 参数。
    public let options: Options
    /// 节目时钟；start 前可换。
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }

    private let timingBox: Mutex<ProgramTiming>
    private let slot: any FrameSlot
    private let stateBox = InputStateBox()
    private let countersBox = InputCountersBox()
    private let fileCounters = FileCountersBox()
    private let playback: Mutex<Playback>
    private let assetBox = Mutex<FileAsset?>(nil)
    private let errorBox = Mutex<String?>(nil)
    private var decoderThread: InputThread?
    private var pacerThread: InputThread?
    private var videoQueue: DecodedVideoQueue?
    private var audioFIFO: DecodedAudioFIFO?
    private let running = Atomic<Bool>(false)
    private let hasPushed = Atomic<Bool>(false)

    /// 播放状态（API 线程写，两条线程读）。
    struct Playback: Sendable {
        var timeline: FileTimeline
        var paused: Bool
        /// 解码器代数：seek 时 +1，解码线程重开 reader，旧代的帧作废。
        var generation: UInt64
        /// 解码器（重）开始的位置（文件内秒）。
        var restartMedia: Rational
        /// 时间线版本：锚点 / 速率 / 暂停任何变化 +1（音频输出块序号从新锚点重数）。
        var version: UInt64
        var endAction: FileEndAction
        /// start / seek 之后：锚点拍要等解码线程给出目标位置的第一帧才定（进程里第一个 reader 要 ~85 ms，定位要从关键帧解到目标帧，
        /// 时间不定；等到帧再定锚点，"定位到第 300 帧后首帧就是 300"才不依赖 GOP 长度）。
        var anchorPending: Bool
        /// 暂停已由推帧线程落实（位置冻结在它最近推出的那一帧；推帧线程才知道哪一帧是最后推出的，API 线程读它会差一拍）。
        var pauseApplied: Bool
    }

    /// - Parameters:
    ///   - path: 文件路径。
    ///   - endAction: 结束动作。
    ///   - rate: 播放速率（> 0；按分母 ≤ 1000 的有理数近似）。
    ///   - timing: 节目时钟。
    ///   - videoSlot / audioRing: 组装方注入。audioRing 为 nil 时不解音频。
    public init(number: Int, name: String, path: String, endAction: FileEndAction = .loop, rate: Double = 1,
                timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil, options: Options = Options()) throws {
        precondition(number >= 1, "输入编号从 1 起")
        precondition(rate > 0 && rate.isFinite, "速率必须为正")
        self.number = number
        self.name = name
        self.path = path
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        let r = Rational(approximating: rate)
        let tl = FileTimeline(anchorTick: .zero, anchorMedia: .zero, rate: r, programFrame: timing.format.frameDuration)
        playback = Mutex(Playback(timeline: tl, paused: false, generation: 0, restartMedia: .zero, version: 0, endAction: endAction, anchorPending: true, pauseApplied: false))
    }

    /// 从 InputSource.file 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil,
                            options: Options = Options()) throws {
        guard case .file(let path, let endAction, let rate) = config.source else {
            throw FileInputError.notAFileSource(config.source.kind)
        }
        try self.init(number: config.number, name: config.name, path: path, endAction: endAction, rate: rate,
                      timing: timing, videoSlot: videoSlot, audioRing: audioRing, options: options)
    }

    public enum FileInputError: Error, CustomStringConvertible {
        case notAFileSource(InputKind)
        case open(String)
        public var description: String {
            switch self {
            case .notAFileSource(let k): "不是文件来源：\(k)"
            case .open(let m): m
            }
        }
    }

    // MARK: 信息

    /// 打开后的文件信息。
    public var info: FileInfo? { assetBox.withLock { $0?.info } }
    /// 素材带 alpha（输出 BGRA）。
    public var hasAlpha: Bool { info?.hasAlpha ?? false }
    /// 时长（秒）。
    public var durationSeconds: Double { info?.duration.doubleValue ?? 0 }
    /// 结束动作（可运行中改）。
    public var endAction: FileEndAction {
        get { playback.withLock { $0.endAction } }
        set { playback.withLock { $0.endAction = newValue } }
    }
    /// 播放速率。设置时在下一拍重新锚定。
    public var rate: Double {
        get { playback.withLock { $0.timeline.rate.doubleValue } }
        set {
            precondition(newValue > 0 && newValue.isFinite)
            let timing = self.timing
            playback.withLock { p in
                let tick = max(timing.nextTick(atOrAfter: HostClock.now() + options.seekLead), .zero)
                if !p.paused { p.timeline.anchorMedia = p.timeline.position(at: tick) }
                p.timeline.anchorTick = tick
                p.timeline.rate = Rational(approximating: newValue)
                p.version += 1
            }
        }
    }
    /// 是否暂停。
    public var isPaused: Bool { playback.withLock { $0.paused } }
    /// 当前时间线的锚点拍：start / seek / resume / 改速率之后，从这一拍起按新时间线出帧。
    /// start / seek 后要等目标位置的第一帧解出来才定，之前为 nil。
    public var playbackStartTick: Tick? {
        guard running.load(ordering: .relaxed) else { return nil }
        return playback.withLock { $0.anchorPending ? nil : $0.timeline.anchorTick }
    }
    /// 当前播放位置（文件内秒）。
    public var positionSeconds: Double {
        let timing = self.timing
        let pos = playback.withLock { p in p.paused ? p.timeline.anchorMedia : p.timeline.position(at: timing.tick(at: HostClock.now())) }
        guard let d = info?.duration, d.numerator > 0 else { return max(0, pos.doubleValue) }
        let v = pos.doubleValue
        return v < 0 ? 0 : v.truncatingRemainder(dividingBy: d.doubleValue)
    }
    /// 最近一次错误文案。
    public var lastError: String? { errorBox.withLock { $0 } }
    /// 计数。
    public var counters: InputCounters { countersBox.snapshot(state: stateBox) }
    /// 文件专属计数。
    public var fileCountersSnapshot: FileCounters { fileCounters.snapshot() }

    // MARK: 生命周期

    /// 打开文件（同步）、起解码线程和推帧线程。播放起点 = 第一帧解出来之后 seekLead 之后的第一拍。打不开时 state = error 并抛出。
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let asset: FileAsset
        do {
            asset = try FileAsset(url: URL(fileURLWithPath: path))
        } catch {
            let message = "\(error)"
            errorBox.withLock { $0 = message }
            stateBox.set(.error(message: message))
            running.store(false, ordering: .releasing)
            throw FileInputError.open(message)
        }
        assetBox.withLock { $0 = asset }
        errorBox.withLock { $0 = nil }
        let timing = self.timing
        let vq = DecodedVideoQueue(depth: options.predecodeDepth)
        let channels = audioRing?.channelCount ?? 0
        let fifo = audioRing != nil && asset.info.hasAudio ? DecodedAudioFIFO(channels: channels, maxFrames: options.audioAheadFrames) : nil
        videoQueue = vq
        audioFIFO = fifo
        playback.withLock { p in
            p.timeline.anchorTick = timing.tick(at: HostClock.now())
            p.timeline.anchorMedia = .zero
            p.timeline.programFrame = timing.format.frameDuration
            p.paused = false
            p.generation += 1
            p.restartMedia = .zero
            p.version += 1
            p.anchorPending = true
        }
        hasPushed.store(false, ordering: .relaxed)
        let d = InputThread(name: "file-decode-\(number)", period: nil, qos: QOS_CLASS_USER_INITIATED) { [self] t in
            decodeLoop(thread: t, asset: asset, queue: vq, fifo: fifo)
        }
        let p = InputThread(name: "file-pace-\(number)", period: timing.frameDuration) { [self] t in
            paceLoop(thread: t, asset: asset, queue: vq, fifo: fifo)
        }
        decoderThread = d
        pacerThread = p
        d.start()
        p.start()
    }

    /// 停两条线程；state 回 noSignal。
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        videoQueue?.close()
        audioFIFO?.close()
        pacerThread?.stop()
        decoderThread?.stop()
        pacerThread = nil
        decoderThread = nil
        videoQueue = nil
        audioFIFO = nil
        stateBox.set(.noSignal)
    }

    // MARK: 控制

    /// 定位到文件内某秒（钳到 [0, 时长)）。目标帧解出来之后 seekLead 之后的第一拍生效，从那一拍起显示目标位置的帧；
    /// 之前帧槽里还是旧帧。
    public func seek(toSeconds seconds: Double) {
        guard let info else { return }
        var target = Rational(approximating: max(0, seconds), maxDenominator: 1_000_000)
        if info.duration.numerator > 0, target >= info.duration { target = .zero }
        seek(toMedia: target)
    }

    /// 定位到第 n 帧（按文件的帧时长）。
    public func seek(toFrame n: Int) {
        guard let info else { return }
        var target = info.frameDuration.scaled(by: Int64(max(0, n)))
        if info.duration.numerator > 0, target >= info.duration { target = .zero }
        seek(toMedia: target)
    }

    private func seek(toMedia target: Rational) {
        let timing = self.timing
        playback.withLock { p in
            p.timeline.anchorTick = timing.tick(at: HostClock.now())
            p.timeline.anchorMedia = target
            p.generation += 1
            p.restartMedia = target
            p.version += 1
            p.anchorPending = true
        }
        fileCounters.seeks.add(1, ordering: .relaxed)
    }

    /// 暂停：位置冻结在推帧线程最近推出的那一帧（由推帧线程在下一次醒来时落实）；每拍把它以 pts = 拍点 重新推。
    public func pause() {
        playback.withLock { p in
            guard !p.paused else { return }
            p.paused = true
            p.pauseApplied = false
            p.version += 1
        }
    }

    /// 恢复：从停住的帧继续，锚到现在 + seekLead 之后的第一拍。
    public func resume() {
        let timing = self.timing
        playback.withLock { p in
            guard p.paused else { return }
            p.timeline.anchorTick = max(timing.nextTick(atOrAfter: HostClock.now() + options.seekLead), .zero)
            p.paused = false
            p.version += 1
        }
    }

    // MARK: 解码线程

    private func decodeLoop(thread: InputThread, asset: FileAsset, queue: DecodedVideoQueue, fifo: DecodedAudioFIFO?) {
        var seenGeneration: UInt64 = 0
        var reader: FileReader?
        var loopBase = Rational.zero          // 本圈的展开偏移
        var videoDone = false, audioDone = false
        var audioPlanes: [[Float]] = Array(repeating: [], count: fifo?.channels ?? 0)
        let sampleRate = Int64(AudioFormat.sampleRate)
        let duration = asset.info.duration
        while !thread.isStopRequested {
            let (generation, restartMedia, endAction) = playback.withLock { ($0.generation, $0.restartMedia, $0.endAction) }
            if generation != seenGeneration {
                seenGeneration = generation
                reader?.cancel()
                reader = nil
                queue.flush()
                fifo?.reset(generation: generation)
                loopBase = .zero
                videoDone = false
                audioDone = false
                do {
                    reader = try asset.makeReader(from: restartMedia)
                } catch {
                    fail("\(error)")
                    thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 200))
                    seenGeneration = 0
                    continue
                }
            }
            guard let r = reader else {
                thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 20))
                continue
            }
            var didWork = false
            if !videoDone && !queue.isFull {
                if let (t, pb) = r.nextVideo() {
                    countersBox.framesReceived.add(1, ordering: .relaxed)
                    countersBox.surfaces.note(pb)
                    _ = queue.push(.init(media: loopBase + t, buffer: pb, generation: generation, isEnd: false))
                    resolveAnchorIfPending(generation: generation)
                } else {
                    videoDone = true
                    if let e = r.error { fail("解码出错：\(e)") }
                }
                didWork = true
            }
            if let fifo, !audioDone, fifo.status.frames < fifo.maxFrames {
                if let sb = r.nextAudio() {
                    for c in 0..<audioPlanes.count { audioPlanes[c].removeAll(keepingCapacity: true) }
                    let frames = LPCM.append(sampleBuffer: sb, to: &audioPlanes)
                    if frames > 0 {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        let mediaSeconds = loopBase + Rational(pts.value, Int64(max(pts.timescale, 1)))
                        let startSample = (mediaSeconds.scaled(by: sampleRate) + Rational(1, 2)).floorValue
                        _ = fifo.append(generation: generation, start: startSample, planes: audioPlanes, frames: frames)
                    }
                } else {
                    audioDone = true
                }
                didWork = true
            }
            if videoDone && (fifo == nil || audioDone) {
                if endAction == .loop && duration.numerator > 0 {
                    loopBase = loopBase + duration
                    r.cancel()
                    do {
                        reader = try asset.makeReader(from: .zero)
                        videoDone = false
                        audioDone = false
                        fileCounters.loops.add(1, ordering: .relaxed)
                    } catch {
                        fail("循环重开失败：\(error)")
                        reader = nil
                    }
                } else {
                    _ = queue.push(.init(media: loopBase + duration, buffer: nil, generation: generation, isEnd: true))
                    // 等换代（seek）或停止
                    while !thread.isStopRequested && playback.withLock({ $0.generation }) == generation {
                        thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 20))
                    }
                }
                continue
            }
            if !didWork { thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 2)) }
        }
        reader?.cancel()
    }

    /// 本代的第一帧已解出：把锚点定在 seekLead 之后的第一拍（不早于第 0 拍：引擎还没开始挑帧之前推的帧只会被帧槽挤掉）。
    private func resolveAnchorIfPending(generation: UInt64) {
        let timing = self.timing
        playback.withLock { p in
            guard p.anchorPending, p.generation == generation else { return }
            p.timeline.anchorTick = max(timing.nextTick(atOrAfter: HostClock.now() + options.seekLead), .zero)
            p.anchorPending = false
            p.version += 1
        }
    }

    private func fail(_ message: String) {
        errorBox.withLock { $0 = message }
        stateBox.set(.error(message: message))
    }

    // MARK: 推帧线程

    private func paceLoop(thread: InputThread, asset: FileAsset, queue: DecodedVideoQueue, fifo: DecodedAudioFIFO?) {
        let timing = self.timing
        let info = asset.info
        let phaseLead = options.phaseLead ?? timing.frameDuration / 2
        let pushLead = options.pushLead
        let frameTicks = timing.frameDuration
        let chunk = options.audioChunkFrames
        let sampleRate = Int64(AudioFormat.sampleRate)
        let chunkDuration = Rational(Int64(chunk), sampleRate).hostDuration
        var held: (media: Rational, buffer: CVPixelBuffer)?
        var ended = false
        var seenGeneration: UInt64 = 0
        var seenVersion: UInt64 = 0
        var sequence: UInt64 = 0
        var nextTick: Tick?
        var chunkIndex: Int64 = 0
        var trimmedTo: Int64 = 0
        var black: CVPixelBuffer?
        var audioOut: [UnsafeMutablePointer<Float>] = []
        var audioSrc: [UnsafeMutablePointer<Float>] = []
        var planeTable: UnsafeMutablePointer<UnsafePointer<Float>>?
        let maxSrc = chunk * 17 + 4   // 速率 ≤ 16
        if let fifo {
            audioOut = (0..<fifo.channels).map { _ in .allocate(capacity: chunk) }
            audioSrc = (0..<fifo.channels).map { _ in .allocate(capacity: maxSrc) }
            planeTable = .allocate(capacity: fifo.channels)
            for c in 0..<fifo.channels { planeTable![c] = UnsafePointer(audioOut[c]) }
        }
        defer {
            for p in audioOut { p.deallocate() }
            for p in audioSrc { p.deallocate() }
            planeTable?.deallocate()
        }
        let writer = audioRing.map { AudioSampleWriter(ring: $0) }

        while !thread.isStopRequested {
            var p = playback.withLock { $0 }
            if p.generation != seenGeneration {
                seenGeneration = p.generation
                ended = false
                nextTick = nil
            }
            if p.version != seenVersion {
                seenVersion = p.version
                chunkIndex = 0
                nextTick = nil
            }
            let now = HostClock.now()
            if p.anchorPending {
                // 等解码线程给出目标位置的第一帧再定锚点；期间不推帧（帧槽保留旧帧）
                thread.sleep(until: now + HostDuration(milliseconds: 2))
                continue
            }
            // 下一拍：锚点拍之后没处理过的第一拍；落后 2 拍以上直接跳到当前拍
            var tick = nextTick ?? max(p.timeline.anchorTick, timing.tick(at: now))
            if tick + 2 < timing.tick(at: now) { tick = timing.tick(at: now) }
            let videoWake = timing.time(of: tick) - phaseLead - pushLead
            var audioWake: HostTime?
            let audioActive = fifo != nil && writer != nil && !p.paused && !ended
            if audioActive {
                audioWake = p.timeline.hostTime(ofOutputSample: chunkIndex * Int64(chunk), sampleRate: sampleRate, timing: timing) + chunkDuration
            }
            var wake = videoWake
            if let a = audioWake, a < wake { wake = a }
            let bound = now + HostDuration(milliseconds: 20)
            if wake > bound { wake = bound }
            thread.sleep(until: wake, slice: HostDuration(milliseconds: 20))
            if thread.isStopRequested { break }
            let woke = HostClock.now()
            if woke - wake > HostDuration(milliseconds: 1) { fileCounters.lateWakes.add(1, ordering: .relaxed) }

            // ---- 视频：本拍 ----
            if woke >= videoWake {
                let tickTime = timing.time(of: tick)
                if p.paused && !p.pauseApplied {
                    // 落实暂停：位置冻结在最近推出的那一帧（没有推过就冻结在本拍的位置）
                    let frozen = held?.media ?? p.timeline.position(at: tick)
                    playback.withLock { q in
                        guard q.paused, !q.pauseApplied else { return }
                        q.timeline.anchorMedia = frozen
                        q.timeline.anchorTick = tick
                        q.pauseApplied = true
                    }
                    p.timeline.anchorMedia = frozen
                    p.timeline.anchorTick = tick
                }
                let position = p.paused ? p.timeline.anchorMedia : p.timeline.position(at: tick)
                var newest: DecodedVideoQueue.Item?
                var rejected: UInt64 = 0
                var endItem: DecodedVideoQueue.Item?
                while let head = queue.peek() {
                    if head.generation != p.generation { _ = queue.pop(); continue }   // 旧代
                    if head.isEnd { endItem = head; break }
                    if head.media <= position {
                        _ = queue.pop()
                        if newest != nil { rejected += 1 }
                        newest = head
                    } else {
                        break
                    }
                }
                if rejected > 0 { countersBox.framesRejected.add(rejected, ordering: .relaxed) }
                if let f = newest, let pb = f.buffer {
                    let nextMedia = queue.secondMedia().map { $0 } ?? queue.peek().flatMap { $0.isEnd ? nil : $0.media }
                    var dur = info.frameDuration
                    if let nm = nextMedia, nm > f.media { dur = nm - f.media }
                    let hostDur = (dur / p.timeline.rate).hostDuration
                    if info.hasAlpha, PixelBuffers.isStraightAlpha(pb) { PixelBuffers.premultiplyInPlace(pb) }
                    sequence += 1
                    let ingress = HostClock.now()
                    slot.push(Frame(pixelBuffer: pb, pts: tickTime - phaseLead, duration: hostDur, color: info.color,
                                    inputNumber: number, sequence: sequence, ingressTime: ingress))
                    countersBox.framesPushed.add(1, ordering: .relaxed)
                    held = (f.media, pb)
                    hasPushed.store(true, ordering: .releasing)
                    if ended { ended = false }
                    stateBox.set(.live)
                } else if p.paused, let h = held {
                    sequence += 1
                    slot.push(Frame(pixelBuffer: h.buffer, pts: tickTime, duration: frameTicks, color: info.color,
                                    inputNumber: number, sequence: sequence, ingressTime: HostClock.now()))
                    countersBox.framesPushed.add(1, ordering: .relaxed)
                } else if let e = endItem, !ended, position >= e.media {
                    // 末帧显示期结束：按结束动作收尾（loop 的话解码线程不会给哨兵）
                    ended = true
                    if p.endAction == .black {
                        if black == nil, let b = try? PixelBuffers.make(width: max(info.width, 2), height: max(info.height, 2), format: asset.videoPixelFormat) {
                            PixelBuffers.fill(black: b)
                            black = b
                        }
                        if let b = black {
                            sequence += 1
                            slot.push(Frame(pixelBuffer: b, pts: tickTime - phaseLead, duration: frameTicks, color: info.color,
                                            inputNumber: number, sequence: sequence, ingressTime: HostClock.now()))
                            countersBox.framesPushed.add(1, ordering: .relaxed)
                            held = (e.media, b)
                        }
                    }
                    stateBox.set(.noSignal)
                } else if !p.paused, !ended, endItem == nil, newest == nil, queue.count == 0,
                          position >= p.timeline.anchorMedia, hasPushed.load(ordering: .relaxed) {
                    // 位置已经过了、队列却空：解码器没跟上（定位后重开中也算）
                    fileCounters.ticksStarved.add(1, ordering: .relaxed)
                }
                nextTick = tick + 1
            }

            // ---- 音频：所有"样本已发生"的块 ----
            if audioActive, let fifo, let writer, let table = planeTable {
                var budget = 8
                while budget > 0 {
                    budget -= 1
                    let j0 = chunkIndex * Int64(chunk)
                    let due = p.timeline.hostTime(ofOutputSample: j0, sampleRate: sampleRate, timing: timing) + chunkDuration
                    if HostClock.now() < due { break }
                    // 源样本位置：pos(j) = anchorMedia × 48000 + j × rate，用公共分母做整数运算
                    let pos0 = p.timeline.sourceSamplePosition(ofOutputSample: j0, sampleRate: sampleRate)
                    let rate = p.timeline.rate
                    let den = Int128(pos0.denominator) * Int128(rate.denominator)
                    let base = Int128(pos0.numerator) * Int128(rate.denominator)
                    let step = Int128(rate.numerator) * Int128(pos0.denominator)
                    let firstIndex = Int64(FileInput.floorDiv(base, den))
                    let lastPos = base + step * Int128(chunk - 1)
                    let lastIndex = Int64(FileInput.floorDiv(lastPos, den)) + 1
                    let srcCount = Int(lastIndex - firstIndex + 1)
                    if srcCount > maxSrc { chunkIndex += 1; continue }
                    if fifo.copy(start: firstIndex, count: srcCount, into: audioSrc) {
                        let exact = rate.isInteger && rate.numerator == 1 && (base % den == 0)
                        for c in 0..<fifo.channels {
                            let src = audioSrc[c], dst = audioOut[c]
                            if exact {
                                dst.update(from: src, count: chunk)
                            } else {
                                var num = base
                                for i in 0..<chunk {
                                    let q = FileInput.floorDiv(num, den)
                                    let frac = Float(Double(num - q * den) / Double(den))
                                    let k = Int(q - Int128(firstIndex))
                                    dst[i] = src[k] + (src[k + 1] - src[k]) * frac
                                    num += step
                                }
                            }
                        }
                        let hostTime = p.timeline.hostTime(ofOutputSample: j0, sampleRate: sampleRate, timing: timing)
                        let n = writer.write(planes: UnsafePointer(table), frameCount: chunk, hostTime: hostTime)
                        countersBox.audioBlocksWritten.add(1, ordering: .relaxed)
                        countersBox.audioFramesWritten.add(UInt64(n), ordering: .relaxed)
                        if n < chunk { countersBox.audioFramesRejected.add(UInt64(chunk - n), ordering: .relaxed) }
                        fileCounters.audioChunksWritten.add(1, ordering: .relaxed)
                        chunkIndex += 1
                        if firstIndex - 2 > trimmedTo {
                            trimmedTo = firstIndex - 2
                            fifo.trim(before: trimmedTo)
                        }
                    } else if HostClock.now() > due + chunkDuration * 4 {
                        // 样本迟迟不来（定位后重开 / 音轨比视频短）：跳过这块
                        fileCounters.audioChunksSkipped.add(1, ordering: .relaxed)
                        chunkIndex += 1
                    } else {
                        break
                    }
                }
            }
        }
    }

    static func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }
}

/// FileCounters 的原子存放处。
final class FileCountersBox: @unchecked Sendable {
    let ticksStarved = Atomic<UInt64>(0)
    let audioChunksWritten = Atomic<UInt64>(0)
    let audioChunksSkipped = Atomic<UInt64>(0)
    let loops = Atomic<UInt64>(0)
    let seeks = Atomic<UInt64>(0)
    let lateWakes = Atomic<UInt64>(0)
    func snapshot() -> FileInput.FileCounters {
        var c = FileInput.FileCounters()
        c.ticksStarved = ticksStarved.load(ordering: .relaxed)
        c.audioChunksWritten = audioChunksWritten.load(ordering: .relaxed)
        c.audioChunksSkipped = audioChunksSkipped.load(ordering: .relaxed)
        c.loops = loops.load(ordering: .relaxed)
        c.seeks = seeks.load(ordering: .relaxed)
        c.lateWakes = lateWakes.load(ordering: .relaxed)
        return c
    }
}
