import SwitcherContracts
import Synchronization

/// 合成音频源（测试标准 §2.2）：`TestSignal`（1 kHz −20 dBFS + 每个闪光时刻 1 ms 满幅 click）按 256 帧一块写进注入的 `AudioRing`。
///
/// - 与视频共用 `SyntheticTimeline.t0`：第 k 个 click 在 t0 + k × 闪光周期，和第 k × 帧率 帧的闪光同一 host time。
/// - 采样率漂移 `driftPpm`：样本 i 的 host time = t0 + i / (48000 × (1 + ppm/10⁶))；块在其最后一个样本的时刻"到达"
///   （像真设备一样采完才交），写入时的 hostTime 是块首样本的时刻（契约 §2.3）。
/// - 每块零分配：样本缓冲和平面指针表在 start 时分配一次；所有声道写同一份单声道数据。
public final class SyntheticAudioInput: Input, @unchecked Sendable {
    /// 自启动以来的计数（原子读）。
    public struct Counters: Hashable, Sendable {
        /// 写进环的块数。
        public var blocksWritten: UInt64 = 0
        /// 写进环的帧数。
        public var framesWritten: UInt64 = 0
        /// 环满被拒的帧数。
        public var framesRejected: UInt64 = 0
        /// 写入时刻比块尾时刻晚超过一块的块数。
        public var late: UInt64 = 0
        public init() {}
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .synthetic
    public let videoSlot: (any FrameSlot)? = nil
    public let audioRing: (any AudioRing)?
    public var state: InputState { stateBox.withLock { $0 } }
    /// 决定 click 周期的帧率。
    public let frameRate: FrameRate
    /// 采样率漂移（ppm）。
    public let driftPpm: Double
    /// 每块帧数（默认 256）。
    public let blockFrames: Int
    /// start 之后有值。
    public var timeline: SyntheticTimeline? { timelineBox.withLock { $0 } }
    /// start 之后有值：本次运行的信号定义（click 样本序号等都从它算）。
    public var signal: TestSignal? { signalBox.withLock { $0 } }

    private let ring: any AudioRing
    private let stateBox = Mutex<InputState>(.noSignal)
    private let timelineBox: Mutex<SyntheticTimeline?>
    private let signalBox = Mutex<TestSignal?>(nil)
    private var thread: RealtimeThread?
    private let blocksCount = Atomic<UInt64>(0)
    private let framesCount = Atomic<UInt64>(0)
    private let rejectedCount = Atomic<UInt64>(0)
    private let lateCount = Atomic<UInt64>(0)

    public init(number: Int, name: String? = nil, frameRate: FrameRate, driftPpm: Double = 0, audioRing: any AudioRing,
                timeline: SyntheticTimeline? = nil, blockFrames: Int = AudioFormat.defaultBlockFrames) {
        precondition(number >= 1 && blockFrames > 0)
        self.number = number
        self.name = name ?? "Synthetic audio \(number)"
        self.frameRate = frameRate
        self.driftPpm = driftPpm
        ring = audioRing
        self.audioRing = audioRing
        timelineBox = Mutex(timeline)
        self.blockFrames = blockFrames
    }

    /// 计数快照。
    public var counters: Counters {
        var c = Counters()
        c.blocksWritten = blocksCount.load(ordering: .relaxed)
        c.framesWritten = framesCount.load(ordering: .relaxed)
        c.framesRejected = rejectedCount.load(ordering: .relaxed)
        c.late = lateCount.load(ordering: .relaxed)
        return c
    }

    public func start() throws {
        let tl = timelineBox.withLock { box -> SyntheticTimeline in
            if let t = box { return t }
            let t = SyntheticTimeline.startingSoon(frameRate: frameRate)
            box = t
            return t
        }
        try start(timeline: tl)
    }

    /// 用给定时间线起线程（视频源带音频时由它调，保证同一 t0）。
    func start(timeline tl: SyntheticTimeline) throws {
        guard thread == nil else { return }
        timelineBox.withLock { $0 = tl }
        let sig = tl.audioSignal(driftPpm: driftPpm)
        signalBox.withLock { $0 = sig }
        let periodNs = UInt64(Double(blockFrames) * 1e9 / sig.effectiveSampleRate)
        let t = RealtimeThread(name: "synthetic-audio-\(number)", periodNanoseconds: periodNs) { [self] thread in
            run(signal: sig, thread: thread)
        }
        thread = t
        stateBox.withLock { $0 = .live }
        t.start()
    }

    public func stop() {
        thread?.stop()
        thread = nil
        stateBox.withLock { $0 = .noSignal }
    }

    // MARK: 线程循环（每块零分配）

    private func run(signal: TestSignal, thread: RealtimeThread) {
        let channels = ring.channelCount
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        buffer.initialize(repeating: 0, count: blockFrames)
        let planes = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        for c in 0..<channels { planes[c] = UnsafePointer(buffer) }
        defer {
            planes.deallocate()
            buffer.deallocate()
        }
        let blockDuration = HostDuration(nanoseconds: Int64(Double(blockFrames) * 1e9 / signal.effectiveSampleRate))
        var next: Int64 = 0
        while !thread.isStopRequested {
            let due = signal.hostTime(ofSample: next + Int64(blockFrames))
            RealtimeThread.wait(until: due)
            if thread.isStopRequested { break }
            signal.render(into: buffer, frameCount: blockFrames, startingAt: next)
            let written = ring.write(planes: UnsafePointer(planes), frameCount: blockFrames, hostTime: signal.hostTime(ofSample: next))
            if HostClock.now() - due > blockDuration { lateCount.wrappingAdd(1, ordering: .relaxed) }
            blocksCount.wrappingAdd(1, ordering: .relaxed)
            framesCount.wrappingAdd(UInt64(written), ordering: .relaxed)
            if written < blockFrames { rejectedCount.wrappingAdd(UInt64(blockFrames - written), ordering: .relaxed) }
            next += Int64(blockFrames)
        }
    }
}
