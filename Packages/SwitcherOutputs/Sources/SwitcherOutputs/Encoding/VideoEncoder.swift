import Foundation
import Synchronization
import SwitcherContracts

/// 视频编码器 = FrameConsumer（契约 §7）：有界队列 + 自己的线程 + 一个后端会话。
///
/// 线程：
/// - `consume` 在引擎派发线程调：push 进有界队列（满了丢最旧并 skipped += 1），signal 编码线程，立即返回。
///   不在这里调 EncodeFrame —— 探针实测它平均要 80–350 µs、首帧 20–30 ms、饱和时阻塞 6 ms。
/// - 编码线程：pop → backend.encode。VT 饱和时 encode 阻塞，队列随之变满，丢帧发生在队列而不是渲染线程（T7）。
/// - `output` 在后端的回调线程被调（VT 自己的线程），接收方必须立即返回（Recorder 是 async 到自己的 writer 队列）。
///
/// 多个编码器可以 consume 同一个 RenderedFrame：CVPixelBuffer 只加引用计数，不拷贝。
public final class VideoEncoder: FrameConsumer, @unchecked Sendable {
    /// 参数。
    public struct Configuration: Sendable {
        /// 消费者名字（Stats / 日志）。
        public var name: String
        /// 节目格式。
        public var format: ProgramFormat
        /// 编码设置。
        public var settings: VideoEncodeSettings
        /// 有界队列深度，2–3。
        public var queueDepth: Int
        /// DataRateLimits 倍数。
        public var dataRateLimitFactor: Double
        /// 硬件编码器必需。
        public var requireHardware: Bool

        public init(name: String, format: ProgramFormat, settings: VideoEncodeSettings, queueDepth: Int = 3,
                    dataRateLimitFactor: Double = 1.5, requireHardware: Bool = false) {
            precondition((1...8).contains(queueDepth), "队列深度 1–8（设计值 2–3）")
            self.name = name
            self.format = format
            self.settings = settings
            self.queueDepth = queueDepth
            self.dataRateLimitFactor = dataRateLimitFactor
            self.requireHardware = requireHardware
        }
    }

    public let consumerName: String
    public let configuration: Configuration
    /// 后端（默认 VT）。
    public let backend: any VideoEncoderBackend

    private let queue: BoundedFrameQueue
    private let wakeup = DispatchSemaphore(value: 0)
    private let atomicCounters = AtomicEncoderCounters()
    private let stateLock = NSLock()
    private var thread: Thread?
    private var running = false          // stateLock：start 到线程退出、会话释放为止
    private var stopRequested = false    // stateLock
    private var keyframeRequested = false // stateLock
    private var firstFrame = true
    private let acceptingFrames = Atomic<Bool>(false)   // consume 的快速门：只有 start 后、stop 前才收帧
    private let threadGroup = DispatchGroup()           // 线程退出的等待点（多个 stop 调用都能等）
    private var outputHandler: (@Sendable (EncodedVideoSample) -> Void)?

    /// 用 VT 后端。
    public convenience init(configuration: Configuration) {
        let backend = VTCompressionBackend(configuration: .init(
            format: configuration.format, settings: configuration.settings,
            dataRateLimitFactor: configuration.dataRateLimitFactor, requireHardware: configuration.requireHardware))
        self.init(configuration: configuration, backend: backend)
    }

    /// 指定后端（测试用）。
    public init(configuration: Configuration, backend: any VideoEncoderBackend) {
        self.configuration = configuration
        self.consumerName = configuration.name
        self.backend = backend
        queue = BoundedFrameQueue(capacity: configuration.queueDepth)
    }

    /// 每编出一帧调一次（后端回调线程）。start 前设置。
    public var output: (@Sendable (EncodedVideoSample) -> Void)? {
        get { stateLock.withLock { outputHandler } }
        set { stateLock.withLock { outputHandler = newValue } }
    }

    /// 计数快照。
    public var counters: EncoderCounters { atomicCounters.snapshot() }
    /// 队列是否已满（喂料器做背压用；生产路径不看它）。
    public var isQueueFull: Bool { queue.depth >= queue.capacity }
    /// 是否在运行。
    public var isRunning: Bool { stateLock.withLock { running } }

    /// 建会话、起线程。
    public func start() throws {
        try stateLock.withLock {
            precondition(!running, "已经在运行")
            let counters = atomicCounters
            let handler = outputHandler
            try backend.prepare(
                output: { [counters] sample in
                    counters.encoded.add(1, ordering: .relaxed)
                    counters.bytes.add(UInt64(sample.byteCount), ordering: .relaxed)
                    if sample.isKeyframe { counters.keyframes.add(1, ordering: .relaxed) }
                    counters.recordLatency(sample.encodeLatency)
                    handler?(sample)
                },
                dropped: { [counters] in counters.droppedByEncoder.add(1, ordering: .relaxed) })
            running = true
            stopRequested = false
            firstFrame = true
            threadGroup.enter()
            let t = Thread { [weak self] in
                self?.encodeLoop()
                self?.threadGroup.leave()
            }
            t.name = "switcher.encoder.\(consumerName)"
            t.qualityOfService = .userInteractive
            thread = t
            acceptingFrames.store(true, ordering: .releasing)
            t.start()
        }
    }

    /// 停：不再收帧，把队列里剩下的帧编完、flush 在途帧、释放会话。阻塞到线程退出；重复调用安全（后来的调用一起等）。
    public func stop() {
        let firstStopper: Bool? = stateLock.withLock {
            guard running else { return nil }
            let first = !stopRequested
            stopRequested = true
            return first
        }
        guard let firstStopper else { return }
        acceptingFrames.store(false, ordering: .releasing)
        wakeup.signal()
        threadGroup.wait()
        if firstStopper {
            backend.invalidate()
            stateLock.withLock { running = false; thread = nil }
        }
    }

    /// 下一帧强制关键帧（推流重连后起步用）。
    public func requestKeyframe() {
        stateLock.withLock { keyframeRequested = true }
    }

    // MARK: FrameConsumer

    public func consume(_ frame: RenderedFrame) {
        guard acceptingFrames.load(ordering: .acquiring) else { return }
        atomicCounters.pushed.add(1, ordering: .relaxed)
        let evicted = queue.push(frame)
        if let evicted {
            atomicCounters.skipped.add(1, ordering: .relaxed)
            atomicCounters.recordSkip(tick: evicted.tick)
        }
        atomicCounters.queueDepth.store(queue.depth, ordering: .relaxed)
        wakeup.signal()
        // evicted 在这里出作用域释放（锁外）
    }

    // MARK: 编码线程

    private func encodeLoop() {
        while true {
            wakeup.wait()
            let stopping = stateLock.withLock { stopRequested }
            while let frame = queue.pop() {
                atomicCounters.submitted.add(1, ordering: .relaxed)
                atomicCounters.queueDepth.store(queue.depth, ordering: .relaxed)
                let force: Bool = stateLock.withLock {
                    let f = keyframeRequested || firstFrame
                    keyframeRequested = false
                    firstFrame = false
                    return f
                }
                let t0 = HostClock.now()
                do {
                    try backend.encode(frame, forceKeyframe: force)
                } catch {
                    atomicCounters.failed.add(1, ordering: .relaxed)
                }
                atomicCounters.recordEncodeCall(HostClock.now() - t0)
            }
            if stopping {
                backend.flush()
                return
            }
        }
    }
}
