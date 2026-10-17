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
/// - 预解码：解码线程领先推帧线程 `predecodeDepth`（3）帧（速率高时加到"每拍要前进的帧数 + 2"）；音频解成 float32 非交错 48 kHz 进 FIFO，
///   最多囤 0.5 s。解出来的帧已经落后当前拍位置超过一帧的不入队直接丢（计 `framesRejected`），解码器才追得上时间线（W2-A4）。
/// - 循环：视频离尾不到 `loopPrerollSeconds` × 速率就把下一圈的 reader 开好（AVAssetReader startReading 之后自己预解首帧，
///   探针：等 300 ms 再取首帧 0.1 ms），视频 / 音频各自读到尾就各自换到下一圈的 reader，两圈的 reader 只在离尾那一小段并存（每个 reader
///   自己常驻约 10 帧预解，1080p ProRes 约 30–70 MB，所以不能常驻双 reader）；展开后的媒体位置连续（第 k 圈 + k × 时长）。
///   以前到尾才重开，"建 reader + 解首帧"ProRes 422 HQ 要 30–50 ms、赶不上 3 帧余量，每圈在循环点空一拍（W2-A4）。
/// - 定位 `seek`：换代——解码线程重开 reader，队列作废；新锚点 = 现在 + seekLead 之后的第一拍显示目标位置，所以定位到
///   第 300 帧后首帧就是 300。暂停：位置冻结，每拍把停住的帧以 pts = 拍点 重新推（帧槽不靠 reused 撑画面）。
/// - 结束动作：holdLastFrame → 末帧显示期结束时置 noSignal、不再推（帧槽保留末帧）；black → 推一帧黑场再置 noSignal；
///   loop → 循环。运行中可改。
/// - 音频：每 256 帧一块，块首 host time = 锚点拍时刻 + 块序号 × 256 / 48000，块在它的样本"发生之后"写（像真设备，
///   混音器的年龄设定点才对得上）；速率 ≠ 1 时按有理数位置线性插值变速（音调随之变）。
/// - 带 alpha 的素材（ProRes 4444 / HEVC alpha）输出 BGRA；解码器标 StraightAlpha 的就地预乘（渲染器约定预乘）。
/// - 方向：视频轨 `preferredTransform`（手机竖拍）归成 `FileOrientation`，解码帧先转正再进帧槽（`PixelRotator`，D15）；
///   用户在输入设置里设的旋转由渲染器叠在转正之后（这里不碰 InputSettings）。
/// - 速率 / 定位越界不崩：速率钳进 `FileSource.rateRange`、定位先在 Double 里钳到 [0, 时长]，`lastError` 说一句（提案 031，D01）。
/// - 线程：解码线程（普通优先级）+ 推帧线程（time-constraint，周期 = 一拍）。都允许锁和分配；帧槽 push / 环 write 无锁。
///   两条都是裸 pthread（InputThread），每轮迭代各包一个自动释放池：AVFoundation 每次 copyNextSampleBuffer 都会 autorelease
///   reader / track output，没有池就攒到停机（S2 每圈 +0.5 MB；W2-A3）。
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
        /// 循环时视频离尾多久（真实时间秒）开好下一圈的 reader；片段内的提前量 = 它 × 速率。建 reader 16–20 ms + 它自己预解首帧 15–42 ms（ProRes 1080p60 探针），
        /// 加上解码位置本来领先显示 3 帧，0.15 s 够用 2 倍以上；片段比它短就一直双 reader（小片段才会这样，代价小）。
        public var loopPrerollSeconds = 0.15
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
    /// 参数被钳的提示（速率 / 定位不在契约范围，提案 031、Codex D01）：不改 state、不算出错，`lastError` 在没有真错误时给它；
    /// 下一次合法的速率 / 定位清掉。start 不清（构造时钳的速率开播之后仍要看得见）。
    private let noteBox = Mutex<String?>(nil)
    /// 方向的提示（D15：方向矩阵认不出 / 转正器建不出来 / 有帧转正失败，这些帧按编码方向原样出）：start 按这次打开的文件重置，解码线程追加；
    /// 优先级在参数提示之后（合法的速率 / 定位不清它）。
    private let orientationNoteBox = Mutex<String?>(nil)
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
        /// 本代已经播完（推帧线程按结束动作收了尾：停在末帧 / 黑场）；start / seek 清掉。播完之后再把结束动作改成循环 = 从头来（W5-N）。
        var reachedEnd = false
        /// 不循环时解码线程读到尾、放了结尾哨兵（在等换代）那一刻记下的结尾位置（展开后）；接着下一圈 / 换代清掉。
        /// `positionSeconds` 用它判"已过尾"（推帧线程收尾那一拍之前的空档不取余）。
        var endMedia: Rational?
        /// D14：推帧线程播到结尾哨兵时循环已经开了——作废这个哨兵、接着下一圈，记下它的位置；解码线程看到它就接着读下一圈
        /// （哪怕之后又关了循环：推帧线程已经越过哨兵，这一圈得有人接上，不然一直空等）。换代清掉；每圈的结尾位置不同（k × 时长），旧值不会误配。
        var loopResumeEnd: Rational?
    }

    /// 推帧线程播到结尾哨兵时的判定（与 endAction setter 同一把锁：两边谁先谁后结果都自洽）。
    enum EndDecision {
        /// 按结束动作收尾（reachedEnd 已置上）；带当时的结束动作（hold / black）。
        case end(FileEndAction)
        /// 哨兵放下之后循环开了：作废哨兵、接着下一圈（D14）。
        case loopOn
        /// 已换代：哨兵是上一代的，下一轮按新代来。
        case stale
    }

    /// - Parameters:
    ///   - path: 文件路径。
    ///   - endAction: 结束动作。
    ///   - rate: 播放速率（`FileSource.rateRange` = 0.1…8，提案 031；越界 / 非有限的钳进去、`lastError` 说一句，不崩——Codex D01；
    ///     按分母 ≤ 1000 的有理数近似）。
    ///   - timing: 节目时钟。
    ///   - videoSlot / audioRing: 组装方注入。audioRing 为 nil 时不解音频。
    public init(number: Int, name: String, path: String, endAction: FileEndAction = .loop, rate: Double = 1,
                timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil, options: Options = Options()) throws {
        precondition(number >= 1, "输入编号从 1 起")
        let (clamped, note) = FileInput.clampRate(rate)
        self.number = number
        self.name = name
        self.path = path
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        let r = Rational(approximating: clamped)
        let tl = FileTimeline(anchorTick: .zero, anchorMedia: .zero, rate: r, programFrame: timing.format.frameDuration)
        playback = Mutex(Playback(timeline: tl, paused: false, generation: 0, restartMedia: .zero, version: 0, endAction: endAction, anchorPending: true, pauseApplied: false))
        noteBox.withLock { $0 = note }
    }

    /// 速率钳进 `FileSource.rateRange`（提案 031 第 5 条；Codex D01：0 / 负数原来在 precondition 崩、1e-4 近似成 0 后取倒数崩、1e300 换 Int64 溢出）。
    /// NaN 没有方向，按 1（正常速度）；±∞ 按两端。返回钳后的值与提示（合法值提示为 nil）。
    static func clampRate(_ rate: Double) -> (value: Double, note: String?) {
        let range = FileSource.rateRange
        if range.contains(rate) { return (rate, nil) }
        let value = rate.isNaN ? 1 : min(max(rate, range.lowerBound), range.upperBound)
        return (value, "播放速率 \(shortNumber(rate)) 不在 \(shortNumber(range.lowerBound))–\(shortNumber(range.upperBound)) 之间，按 \(shortNumber(value)) 播")
    }

    /// 定位秒数 → 文件内位置（Codex D01：原来 1e300 在钳到时长之前就 × 1e6 换 Int64，溢出崩）：先在 Double 里钳到 [0, 时长]
    /// （非有限 / 负数给 0，与 `InputSettings.clamped()` 同口径；时长未知时上限按 `PlaybackLimits.maxSeekSeconds`；再兜一道 Int64 能表示的上限），
    /// 再换 Rational。钳完 ≥ 时长（过尾、1e300）与原来一样 = 从头。
    static func seekTarget(seconds: Double, duration: Rational) -> Rational {
        guard seconds.isFinite, seconds > 0 else { return .zero }
        let known = duration.numerator > 0
        let upper = min(known ? duration.doubleValue : PlaybackLimits.maxSeekSeconds, Double(Int64.max) / 2_000_000)
        var target = Rational(approximating: min(seconds, upper), maxDenominator: 1_000_000)
        if known, target >= duration { target = .zero }
        return target
    }

    /// 提示里的数：1e+300、0.1、8、nan、inf。
    private static func shortNumber(_ v: Double) -> String { String(format: "%g", v) }

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
    /// 结束动作（可运行中改）。播完之后（停在末帧 / 黑场）改成循环 = 当场从头接着循环（"到尾从头来"，尾已经到了；W5-N，格子的"循环"开关）；
    /// 没播完时只换结束动作、位置接着走——包括解码线程已经读到尾、推帧线程还在播最后几帧的那个窗口（D14：解码线程等尾时也看循环开没开，
    /// 推帧线程到结尾哨兵时同一把锁里再看一次，开了就接着下一圈，不进 noSignal）。
    public var endAction: FileEndAction {
        get { playback.withLock { $0.endAction } }
        set {
            let restart = playback.withLock { p -> Bool in
                let ended = p.reachedEnd && p.endAction != .loop
                p.endAction = newValue
                return ended && newValue == .loop
            }
            if restart { seek(toMedia: .zero) }
        }
    }
    /// 播放速率。设置时在下一拍重新锚定。越界 / 非有限的钳进 `FileSource.rateRange` 并在 `lastError` 说一句（不崩，Codex D01）；读回来是钳后的值。
    public var rate: Double {
        get { playback.withLock { $0.timeline.rate.doubleValue } }
        set {
            let (clamped, note) = FileInput.clampRate(newValue)
            noteBox.withLock { $0 = note }
            let timing = self.timing
            playback.withLock { p in
                let tick = max(timing.nextTick(atOrAfter: HostClock.now() + options.seekLead), .zero)
                if !p.paused { p.timeline.anchorMedia = p.timeline.position(at: tick) }
                p.timeline.anchorTick = tick
                p.timeline.rate = Rational(approximating: clamped)
                p.version += 1
            }
        }
    }
    /// 是否暂停。
    public var isPaused: Bool { playback.withLock { $0.paused } }
    /// 暂停已由推帧线程落实（测试看 D13 的触发条件：暂停还没落实就来了定位）。
    var pauseIsApplied: Bool { playback.withLock { $0.paused && $0.pauseApplied } }
    /// 解码线程读到尾、放了结尾哨兵在等（测试看 D14 的触发条件：此刻推帧线程还没播到哨兵）。
    var decoderParkedAtEnd: Bool { playback.withLock { $0.endMedia != nil } }
    /// 当前时间线的锚点拍：start / seek / resume / 改速率之后，从这一拍起按新时间线出帧。
    /// start / seek 后要等目标位置的第一帧解出来才定，之前为 nil。
    public var playbackStartTick: Tick? {
        guard running.load(ordering: .relaxed) else { return nil }
        return playback.withLock { $0.anchorPending ? nil : $0.timeline.anchorTick }
    }
    /// 当前播放位置（文件内秒）。循环中对时长取余（展开后的位置折回文件内）；不循环播完（推帧线程已收尾，或解码线程放了结尾哨兵、
    /// 位置已过尾）= 时长、之后不变（Codex §5 末段：原来播完仍取余、继续走，1 s 文件读出 0.53）。
    public var positionSeconds: Double {
        let tick = timing.tick(at: HostClock.now())
        let (pos, ended, end) = playback.withLock { p in
            (p.paused ? p.timeline.anchorMedia : p.timeline.position(at: tick), p.reachedEnd, p.endMedia)
        }
        guard let d = info?.duration, d.numerator > 0 else { return max(0, pos.doubleValue) }
        if ended || end.map({ pos >= $0 }) == true { return d.doubleValue }
        let v = pos.doubleValue
        return v < 0 ? 0 : v.truncatingRemainder(dividingBy: d.doubleValue)
    }
    /// 最近一次错误文案；没有错误时是参数被钳的提示（速率 / 定位越界，见 `noteBox`），再没有是方向的提示（`orientationNoteBox`）。
    public var lastError: String? { errorBox.withLock { $0 } ?? noteBox.withLock { $0 } ?? orientationNoteBox.withLock { $0 } }
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
        orientationNoteBox.withLock { $0 = asset.orientationNote }
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
            p.reachedEnd = false
            p.endMedia = nil
            p.loopResumeEnd = nil
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

    /// 定位到文件内某秒：先在 Double 里钳到 [0, 时长]（非有限 / 负数 = 0），过尾（≥ 时长）= 从头（`seekTarget`）。不在契约范围
    /// （0…`PlaybackLimits.maxSeekSeconds`，提案 031）的照做、`lastError` 说一句；合法的定位清掉提示。
    /// 目标帧解出来之后 seekLead 之后的第一拍生效，从那一拍起显示目标位置的帧；之前帧槽里还是旧帧。暂停中定位 = 停在目标那一帧、仍暂停。
    public func seek(toSeconds seconds: Double) {
        guard let info else { return }
        let inContract = (0...PlaybackLimits.maxSeekSeconds).contains(seconds)
        noteBox.withLock {
            $0 = inContract ? nil : "定位秒数 \(FileInput.shortNumber(seconds)) 不在 0–\(FileInput.shortNumber(PlaybackLimits.maxSeekSeconds))（一周）之间，按从头处理"
        }
        seek(toMedia: FileInput.seekTarget(seconds: seconds, duration: info.duration))
    }

    /// 定位到第 n 帧（按文件的帧时长）。帧号先钳到文件的帧数（帧时长 × n 不在 Int64 里溢出，D01 同一类）；过尾 = 从头。
    public func seek(toFrame n: Int) {
        guard let info else { return }
        let frames = info.duration.numerator > 0 ? FileInput.ceilInt(info.duration / info.frameDuration) : Int(Int32.max)
        var target = info.frameDuration.scaled(by: Int64(min(max(0, n), frames)))
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
            p.reachedEnd = false
            p.endMedia = nil
            p.loopResumeEnd = nil
            // 暂停中定位 = 冻结在目标上，暂停就此落实——不管推帧线程落没落实之前那次暂停请求：新定位的代次优先于旧的暂停请求。
            // 原来留着"待落实"，推帧线程随后拿上一代最后推出的帧覆盖目标（D13：1 s 文件定位 0.5 s，0.4 s 后仍停在 0.1 s）
            if p.paused { p.pauseApplied = true }
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

    /// 一圈的 reader：展开偏移 + 视频 / 音频各自是否读到尾（各拉各的：音频领先 0.5 s，先到尾就先从下一圈拉，不等视频的尾巴）。
    private final class LoopReader {
        let reader: FileReader
        /// 本圈的展开偏移（第 k 圈 = k × 时长）。
        let base: Rational
        var videoDone = false
        var audioDone = false
        /// 最近解出的视频帧的文件内位置（判断离尾还有多远）。
        var lastVideoMedia = Rational.zero
        init(reader: FileReader, base: Rational) {
            self.reader = reader
            self.base = base
        }
        func cancel() { reader.cancel() }
    }

    private func decodeLoop(thread: InputThread, asset: FileAsset, queue: DecodedVideoQueue, fifo: DecodedAudioFIFO?) {
        let timing = self.timing
        var seenGeneration: UInt64 = 0
        var current: LoopReader?
        var next: LoopReader?              // 预开好的下一圈
        var prerollFailed = false          // 预开失败过：本圈不再试，交接时按老办法重开
        var pendingAudio: (start: Int64, frames: Int)?   // FIFO 前面的空洞比容量大、还没放进去的那块（audioPlanes 里）
        var audioPlanes: [[Float]] = Array(repeating: [], count: fifo?.channels ?? 0)
        var queueDepth = queue.depth
        var rotationFailuresSeen = 0
        let sampleRate = Int64(AudioFormat.sampleRate)
        let duration = asset.info.duration
        let frameDuration = asset.info.frameDuration
        let canLoop = duration.numerator > 0
        while !thread.isStopRequested {
            // 每轮一个自动释放池（S2，问题单 W4A-w2-inputs-file-loop-memory-and-prores-starve §3）：copyNextSampleBuffer() 等 AVFoundation 调用
            // 内部会 autorelease reader / track output（KVO 代理），这条线程是裸 pthread、没有池就永远不 release——每圈重开 reader 就多 0.5 MB。
            // 池写在循环里而不是 InputThread 里：每轮的状态都是局部变量，包一层闭包最小；闭包里的 `return` 就是原来的 `continue`。
            autoreleasepool {
                let p = playback.withLock { $0 }
                if p.generation != seenGeneration {
                    seenGeneration = p.generation
                    current?.cancel()
                    next?.cancel()
                    current = nil
                    next = nil
                    pendingAudio = nil
                    prerollFailed = false
                    queue.flush()
                    fifo?.reset(generation: p.generation)
                    do {
                        current = LoopReader(reader: try asset.makeReader(from: p.restartMedia), base: .zero)
                    } catch {
                        fail("\(error)")
                        thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 200))
                        seenGeneration = 0
                        return
                    }
                }
                guard let cur = current else {
                    thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 20))
                    return
                }
                let looping = p.endAction == .loop && canLoop
                // 队列深度跟着速率走：每拍前进 速率 × 一拍 / 帧时长 帧，推帧线程一拍要能把本拍的帧全 pop 到最新那帧（深度固定 3 时 4 帧 / 拍永远追不上）
                let perTick = p.timeline.rate * p.timeline.programFrame / frameDuration
                let want = options.predecodeDepth + max(0, FileInput.ceilInt(perTick) - 1)
                if want != queueDepth {
                    queueDepth = want
                    queue.setDepth(want)
                }
                // 预开下一圈：视频离尾不到 lead（真实时间 loopPrerollSeconds × 速率）就把下一圈的 reader 开好——AVAssetReader startReading 之后
                // 自己会把首帧预解出来（探针：等 300 ms 再取首帧 0.1 ms；同时另一个 reader 满速解也一样），交接时不用等。只看视频不看音频：音频领先 0.5 s，
                // next 的音频在它还是 next 时就会被拉完，交接后 cur.audioDone 立刻为真，拿它当触发条件双 reader 就常驻了（fileprobe 重 ProRes 212 MB）
                if looping, next == nil, !prerollFailed {
                    let lead = Rational(approximating: options.loopPrerollSeconds, maxDenominator: 1000) * p.timeline.rate
                    if cur.videoDone || cur.lastVideoMedia + lead >= duration {
                        do {
                            next = LoopReader(reader: try asset.makeReader(from: .zero), base: cur.base + duration)
                        } catch {
                            prerollFailed = true
                            fail("循环预开失败：\(error)")
                        }
                    }
                }
                var didWork = false
                // ---- 视频：本圈没到尾从本圈拉，到尾了从预开的下一圈拉（音频没到尾也不等它）----
                let videoSource: LoopReader? = !cur.videoDone ? cur : (looping ? next : nil)
                if !queue.isFull, let src = videoSource, !src.videoDone {
                    if let (t, pb) = src.reader.nextVideo() {
                        countersBox.framesReceived.add(1, ordering: .relaxed)
                        countersBox.surfaces.note(pb)   // 转正过的是池里的缓冲（推进帧槽的就是它）
                        if let r = asset.rotator, r.failures != rotationFailuresSeen {
                            rotationFailuresSeen = r.failures
                            let reason = r.lastFailure ?? "?"
                            orientationNoteBox.withLock { $0 = "转正失败 \(rotationFailuresSeen) 帧（\(reason)），这些帧按编码方向原样出" }
                        }
                        src.lastVideoMedia = t
                        let media = src.base + t
                        if shouldDrop(media: media, playback: p, timing: timing, frameDuration: frameDuration) {
                            countersBox.framesRejected.add(1, ordering: .relaxed)
                        } else {
                            _ = queue.push(.init(media: media, buffer: pb, generation: p.generation, isEnd: false))
                            resolveAnchorIfPending(generation: p.generation)
                        }
                    } else {
                        src.videoDone = true
                        if let e = src.reader.error { fail("解码出错：\(e)") }
                    }
                    didWork = true
                }
                // ---- 音频：同样各拉各的；FIFO 满了不放（推帧线程要不到样本会 trim，两边不互等）----
                if let fifo {
                    if let pa = pendingAudio {
                        // 这块前面的空洞比 FIFO 还大：等推帧线程把补的零消费掉一些再放（不阻塞，视频照拉）
                        if fifo.append(generation: p.generation, start: pa.start, planes: audioPlanes, frames: pa.frames) != .retry {
                            pendingAudio = nil
                            didWork = true
                        }
                    } else if fifo.status.frames < fifo.maxFrames {
                        let audioSource: LoopReader? = !cur.audioDone ? cur : (looping ? next : nil)
                        if let src = audioSource, !src.audioDone {
                            if let sb = src.reader.nextAudio() {
                                for c in 0..<audioPlanes.count { audioPlanes[c].removeAll(keepingCapacity: true) }
                                let frames = LPCM.append(sampleBuffer: sb, to: &audioPlanes)
                                if frames > 0 {
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                                    let mediaSeconds = src.base + Rational(pts.value, Int64(max(pts.timescale, 1)))
                                    let startSample = (mediaSeconds.scaled(by: sampleRate) + Rational(1, 2)).floorValue
                                    if fifo.append(generation: p.generation, start: startSample, planes: audioPlanes, frames: frames) == .retry {
                                        pendingAudio = (startSample, frames)
                                    }
                                }
                            } else {
                                src.audioDone = true
                            }
                            didWork = true
                        }
                    }
                }
                // ---- 本圈读完：交接到下一圈 / 放结尾哨兵 ----
                if cur.videoDone && (fifo == nil || cur.audioDone) {
                    if looping {
                        cur.cancel()
                        if let n = next {
                            current = n
                        } else {
                            do {
                                current = LoopReader(reader: try asset.makeReader(from: .zero), base: cur.base + duration)
                            } catch {
                                fail("循环重开失败：\(error)")
                                current = nil
                            }
                        }
                        next = nil
                        prerollFailed = false
                        fileCounters.loops.add(1, ordering: .relaxed)
                    } else {
                        next?.cancel()   // 预开之后结束动作改成了 hold / black
                        next = nil
                        let endMedia = cur.base + duration
                        _ = queue.push(.init(media: endMedia, buffer: nil, generation: p.generation, isEnd: true))
                        playback.withLock { q in if q.generation == p.generation { q.endMedia = endMedia } }
                        // 等换代（seek）/ 停止 / 循环开了（D14：哨兵放下、推帧线程还没播到它的那几帧里开的循环——原来这里只等换代，
                        // setter 又只在 reachedEnd 已为真时才从头来，哨兵照旧按"停在末帧"收尾、进 noSignal）。推帧线程到哨兵时同一把锁里
                        // 再看一次：开着就作废哨兵、记 loopResumeEnd，这边据此接着读下一圈（那之后哪怕又关了循环也照接——推帧线程已越过哨兵）。
                        // 5 ms 一看：窗口只有最后几帧（30 fps 文件 ≥ 33 ms），要在推帧线程播到下一圈第 0 帧之前把 reader 开好。
                        while !thread.isStopRequested {
                            let (generation, action, resumeAt) = playback.withLock { ($0.generation, $0.endAction, $0.loopResumeEnd) }
                            if generation != p.generation { break }
                            if canLoop && (action == .loop || resumeAt == endMedia) {
                                cur.cancel()
                                do {
                                    current = LoopReader(reader: try asset.makeReader(from: .zero), base: endMedia)
                                } catch {
                                    fail("循环重开失败：\(error)")
                                    current = nil
                                }
                                prerollFailed = false
                                playback.withLock { q in if q.generation == p.generation, q.endMedia == endMedia { q.endMedia = nil } }
                                fileCounters.loops.add(1, ordering: .relaxed)
                                break
                            }
                            thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 5))
                        }
                    }
                    return
                }
                if !didWork { thread.sleep(until: HostClock.now() + HostDuration(milliseconds: 2)) }
            }
        }
        current?.cancel()
        next?.cancel()
    }

    /// 解码线程侧丢帧：这帧已经落后当前拍的位置超过一帧（推帧线程反正只推"位置 ≤ 本拍"里最新的那帧），不入队直接丢，
    /// 解码器才能追上时间线（速率高 / 解码慢时不会越落越远）。只差不到一帧的留着——定位到非帧边界时首帧的 pts 略早于锚点，那帧正是要显示的。
    /// 锚点没定 / 暂停 / 还没到锚点拍时位置无意义，不丢。
    private func shouldDrop(media: Rational, playback p: Playback, timing: ProgramTiming, frameDuration: Rational) -> Bool {
        guard !p.anchorPending, !p.paused else { return false }
        let tick = timing.tick(at: HostClock.now())
        guard tick > p.timeline.anchorTick else { return false }
        return media + frameDuration <= p.timeline.position(at: tick)
    }

    /// 正有理数向上取整。
    static func ceilInt(_ r: Rational) -> Int {
        guard r.numerator > 0 else { return 0 }
        return Int((r.numerator + r.denominator - 1) / r.denominator)
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

    /// 推帧线程播到结尾哨兵（位置 `media`）时判定收尾还是接着循环——与 endAction setter 同一把锁：setter 先 = 这里看见循环、
    /// 作废哨兵（记 loopResumeEnd，解码线程据此接着读下一圈）；这里先 = reachedEnd 置上、setter 看见"已播完"再从头来。两种顺序都不会停在
    /// "开关开着却 noSignal"（D14）。
    private func endDecision(at media: Rational, generation: UInt64, canLoop: Bool) -> EndDecision {
        playback.withLock { q in
            guard q.generation == generation else { return .stale }
            if q.endAction == .loop && canLoop {
                q.loopResumeEnd = media
                q.endMedia = nil
                return .loopOn
            }
            q.reachedEnd = true
            return .end(q.endAction)
        }
    }

    // MARK: 推帧线程

    private func paceLoop(thread: InputThread, asset: FileAsset, queue: DecodedVideoQueue, fifo: DecodedAudioFIFO?) {
        let timing = self.timing
        let info = asset.info
        let canLoop = info.duration.numerator > 0
        let phaseLead = options.phaseLead ?? timing.frameDuration / 2
        let pushLead = options.pushLead
        let frameTicks = timing.frameDuration
        let chunk = options.audioChunkFrames
        let sampleRate = Int64(AudioFormat.sampleRate)
        let chunkDuration = Rational(Int64(chunk), sampleRate).hostDuration
        var held: (media: Rational, buffer: CVPixelBuffer)?
        var heldGeneration: UInt64 = 0   // held 是哪一代推出的（暂停落实只认本代的，D13）
        var ended = false
        var seenGeneration: UInt64 = 0
        var seenVersion: UInt64 = 0
        var sequence: UInt64 = 0
        var nextTick: Tick?
        var chunkIndex: Int64 = 0
        var trimmedTo = Int64.min
        var audioStalled = false   // 上一轮：当前音频块到点了但样本还没解到（循环点 / 定位后重开），下一轮按块周期轮询
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
            // 每轮一个自动释放池（同 decodeLoop）。这条线程现在只碰帧槽 / 环 / 计数、不调 ObjC 框架，包上是让以后加进来的
            // CoreMedia / AVFoundation 调用也按轮排水，不会又变成线程退出才释放。闭包返回 false = 原来的 `break`。
            let keepGoing: Bool = autoreleasepool {
                var p = playback.withLock { $0 }
                if p.generation != seenGeneration {
                    seenGeneration = p.generation
                    ended = false
                    nextTick = nil
                    trimmedTo = .min   // FIFO 换代清空；不重置的话往回定位后要等位置追过旧的 trim 点才会再 trim，FIFO 塞满、解码线程进不来
                }
                if p.version != seenVersion {
                    seenVersion = p.version
                    chunkIndex = 0
                    nextTick = nil
                    audioStalled = false
                }
                let now = HostClock.now()
                if p.anchorPending {
                    // 等解码线程给出目标位置的第一帧再定锚点；期间不推帧（帧槽保留旧帧）
                    thread.sleep(until: now + HostDuration(milliseconds: 2))
                    return true
                }
                // 下一拍：锚点拍之后没处理过的第一拍；落后 2 拍以上直接跳到当前拍
                var tick = nextTick ?? max(p.timeline.anchorTick, timing.tick(at: now))
                if tick + 2 < timing.tick(at: now) { tick = timing.tick(at: now) }
                let videoWake = timing.time(of: tick) - phaseLead - pushLead
                var audioWake: HostTime?
                let audioActive = fifo != nil && writer != nil && !p.paused && !ended
                if audioActive {
                    let due = p.timeline.hostTime(ofOutputSample: chunkIndex * Int64(chunk), sampleRate: sampleRate, timing: timing) + chunkDuration
                    if audioStalled && due <= now {
                        // 这块到点了但样本还没解到：按块周期轮询到跳过线，不把 wake 设在过去——那样 sleep 立刻返回、每轮都记一次晚醒，
                        // 循环点断供几十 ms 就自旋十几万次（问题单 W4A-…-prores-starve §2 的"晚醒"）
                        audioWake = max(now, min(due + chunkDuration * 4, now + chunkDuration))
                    } else {
                        audioWake = due
                    }
                }
                var wake = videoWake
                if let a = audioWake, a < wake { wake = a }
                let bound = now + HostDuration(milliseconds: 20)
                if wake > bound { wake = bound }
                thread.sleep(until: wake, slice: HostDuration(milliseconds: 20))
                if thread.isStopRequested { return false }
                let woke = HostClock.now()
                if woke - wake > HostDuration(milliseconds: 1) { fileCounters.lateWakes.add(1, ordering: .relaxed) }

                // ---- 视频：本拍 ----
                if woke >= videoWake {
                    let tickTime = timing.time(of: tick)
                    if p.paused && !p.pauseApplied {
                        // 落实暂停：位置冻结在本代最近推出的那一帧。本代还没推过（刚开播 / 刚定位）就冻结在本拍的位置、但不早于锚点位置
                        // （= 定位目标：锚点拍在 seekLead 之后时本拍位置比目标早，冻在那里就永远等不到目标那帧）。上一代推出的帧不算——
                        // 原来拿它冻结，"定位后紧跟暂停"会把位置冻回定位之前（D13 的反向顺序）
                        let heldMedia = heldGeneration == p.generation ? held?.media : nil
                        let frozen = heldMedia ?? max(p.timeline.position(at: tick), p.timeline.anchorMedia)
                        let generation = p.generation
                        let applied = playback.withLock { q -> Bool in
                            guard q.paused, !q.pauseApplied, q.generation == generation else { return false }
                            q.timeline.anchorMedia = frozen
                            q.timeline.anchorTick = tick
                            q.pauseApplied = true
                            return true
                        }
                        // 没落成 = 读快照之后来了定位 / 恢复（定位会把暂停直接落在目标上）：这一拍不按旧快照出帧，下一轮按新状态来
                        if !applied { return true }
                        p.timeline.anchorMedia = frozen
                        p.timeline.anchorTick = tick
                        p.pauseApplied = true
                    }
                    var position = p.paused ? p.timeline.anchorMedia : p.timeline.position(at: tick)
                    var newest: DecodedVideoQueue.Item?
                    var rejected: UInt64 = 0
                    var endItem: (item: DecodedVideoQueue.Item, action: FileEndAction)?   // 本拍按结束动作收尾的哨兵（锁里判定过）
                    drain: while let head = queue.peek() {
                        if head.generation < p.generation { _ = queue.pop(); continue }   // 旧代
                        // 比本轮快照还新的代：读快照、睡到拍点的这段时间里又定位了，解码线程已经给出新代的帧——留给下一轮。
                        // 原来按"代数不等 = 旧代"扔掉，定位目标那一帧就丢了（小文件重开 reader + 解首帧只要几 ms，比推帧线程的一拍短；D13 实测）
                        if head.generation > p.generation { break drain }
                        if head.isEnd {
                            // 末帧显示期结束：本拍没有别的帧要出时判定——按结束动作收尾，或者哨兵放下之后循环开了（D14）：作废它、
                            // 接着出后面下一圈的帧（解码线程按 loopResumeEnd / 循环开关接着读）
                            if !ended, newest == nil, head.media <= position {
                                switch endDecision(at: head.media, generation: p.generation, canLoop: canLoop) {
                                case .loopOn:
                                    _ = queue.pop()
                                    continue drain
                                case .end(let action):
                                    endItem = (head, action)
                                case .stale:
                                    break
                                }
                            }
                            break drain
                        }
                        if head.media <= position {
                            _ = queue.pop()
                            if newest != nil { rejected += 1 }
                            newest = head
                        } else if p.paused, newest == nil, heldGeneration != p.generation {
                            // 暂停中定位后，新代的第一帧比冻结位置还晚（目标早于文件首帧的 pts）：照样出它、冻结位置挪到它——
                            // 不然一直重推上一代的旧帧
                            _ = queue.pop()
                            newest = head
                            position = head.media
                            let generation = p.generation
                            playback.withLock { q in if q.paused, q.generation == generation { q.timeline.anchorMedia = head.media } }
                            p.timeline.anchorMedia = head.media
                            break drain
                        } else {
                            break drain
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
                        heldGeneration = p.generation
                        hasPushed.store(true, ordering: .releasing)
                        if ended { ended = false }
                        stateBox.set(.live)
                    } else if p.paused, let h = held {
                        sequence += 1
                        slot.push(Frame(pixelBuffer: h.buffer, pts: tickTime, duration: frameTicks, color: info.color,
                                        inputNumber: number, sequence: sequence, ingressTime: HostClock.now()))
                        countersBox.framesPushed.add(1, ordering: .relaxed)
                    } else if let (e, action) = endItem {
                        // 收尾（reachedEnd 已在 endDecision 里置上；循环着的话解码线程不会给哨兵）
                        ended = true
                        if action == .black {
                            if black == nil, let b = try? PixelBuffers.make(width: max(info.displayWidth, 2), height: max(info.displayHeight, 2),
                                                                            format: asset.videoPixelFormat) {
                                PixelBuffers.fill(black: b)
                                black = b
                            }
                            if let b = black {
                                sequence += 1
                                slot.push(Frame(pixelBuffer: b, pts: tickTime - phaseLead, duration: frameTicks, color: info.color,
                                                inputNumber: number, sequence: sequence, ingressTime: HostClock.now()))
                                countersBox.framesPushed.add(1, ordering: .relaxed)
                                held = (e.media, b)
                                heldGeneration = p.generation
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
                audioStalled = false
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
                        switch fifo.copy(start: firstIndex, count: srcCount, into: audioSrc) {
                        case .ok:
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
                        case .gone:
                            // 要的样本已经不在 FIFO 里（换代 / 大空洞之后队头在它后面）：永远不会再来，立刻跳过，别等到跳过线
                            fileCounters.audioChunksSkipped.add(1, ordering: .relaxed)
                            chunkIndex += 1
                        case .notYet:
                            // 样本还没解到：先把比这块还老的样本丢掉——FIFO 被旧样本塞满时解码线程进不来，不 trim 就两边互等（W2A3 的饿死）；
                            // 过了 due + 4 块还没来（定位后重开 / 音轨比视频短）就跳过，否则下一轮按块周期轮询
                            if firstIndex - 2 > trimmedTo {
                                trimmedTo = firstIndex - 2
                                fifo.trim(before: trimmedTo)
                            }
                            if HostClock.now() > due + chunkDuration * 4 {
                                fileCounters.audioChunksSkipped.add(1, ordering: .relaxed)
                                chunkIndex += 1
                            } else {
                                audioStalled = true
                                budget = 0
                            }
                        }
                    }
                }
                return true
            }
            if !keepGoing { break }
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
