import CoreVideo
import Darwin
import Foundation
import SwitcherContracts
import Synchronization

/// 合成视频源（测试标准 §2.1）：实现 `Input`，kind = .synthetic。
///
/// - 自带线程（`RealtimeThread`）和自己的时钟：第 n 帧的 pts = t0 + n × T / (1 + 漂移)，有理数一次乘除（`TickClockSpec`）。
/// - 每帧从预热的 NV12 / IOSurface 池取缓冲，`TestPattern` 写帧号（= n）、时间戳（= pts 的毫秒）、输入 ID、闪光（n % 整数帧率 == 0），
///   `ingressTime` 在 push 前用 `HostClock.now()` 打，push 进注入的 `FrameSlot`。
/// - 人为抖动：第 n 帧在 pts + U(−jitterMs, +jitterMs) 时刻推入（pts 本身不抖——模拟"采集时刻准、送达时刻晃"的设备）。
/// - 人为丢帧：dropEveryN > 0 时每 N 帧丢 1（n % N == N − 1 的那帧不产，帧号照跳，frameprobe 看到缺口）。
/// - 每帧不分配：像素缓冲来自池（超过阈值时这帧跳过并计 `poolStarved`），随机数、内容结构全是值类型。
///   （`TestPattern.draw` 内部有一个两元素数组字面量，release 下栈分配；见报告"契约疑问"。）
/// - 噪声底纹（`.noise`，提案 006）默认在 GPU 上画（`NoisePatternRenderer`，逐像素与契约 `TestPattern.draw` 相同）：CPU 参考实现 1080p 一帧
///   1–4 ms，8 路 1080p60 就会把 S3 的 CPU 撑爆；GPU 版每帧 GPU 0.07 ms、线程 CPU 0.06 ms。`noise` 参数可以强制 CPU（对照 / 没有 Metal 时）。
/// - settings.audio 且注入了 `AudioRing` 时，自带一路 `SyntheticAudioInput`，与视频共用 t0（click 与闪光同刻）。
public final class SyntheticVideoInput: Input, @unchecked Sendable {
    /// 自启动以来的计数（原子读；这是合成源自己的诊断，不是 Stats 的一部分）。
    public struct Counters: Hashable, Sendable {
        /// 实际画出并 push 的帧数。
        public var generated: UInt64 = 0
        /// 按 dropEveryN 故意不产的帧数。
        public var droppedByDesign: UInt64 = 0
        /// 池达到阈值取不到缓冲而跳过的帧数（下游持帧太多）。
        public var poolStarved: UInt64 = 0
        /// push 时刻比 pts + 抖动幅度 + 一帧还晚的帧数（线程被抢占 / 画得太慢）。
        public var late: UInt64 = 0
        /// 唤醒延迟（实际醒来 − 目标时刻）的累计纳秒；除以 generated + droppedByDesign + poolStarved 得平均。
        public var wakeLatencySumNs: UInt64 = 0
        /// 最大唤醒延迟（纳秒）。
        public var wakeLatencyMaxNs: UInt64 = 0
        /// 画一帧图案的累计墙钟纳秒（除以 generated 得平均；GPU 路径含等 GPU 完成）。
        public var drawSumNs: UInt64 = 0
        /// 画图案花掉的生产者线程 CPU 时间累计（纳秒；GPU 路径 = 编码命令 + 提交 + 等待期间被调度到的时间）。
        public var drawCPUSumNs: UInt64 = 0
        /// 噪声在 GPU 上画时 GPU 忙的累计纳秒（CPU 路径为 0）。
        public var gpuBusySumNs: UInt64 = 0
        public init() {}
        /// 平均唤醒延迟（ms）。
        public var meanWakeLatencyMs: Double {
            let n = generated + droppedByDesign + poolStarved
            return n == 0 ? 0 : Double(wakeLatencySumNs) / Double(n) / 1e6
        }
        /// 平均画帧耗时（ms，墙钟）。
        public var meanDrawMs: Double { generated == 0 ? 0 : Double(drawSumNs) / Double(generated) / 1e6 }
        /// 平均画帧 CPU 时间（ms）。
        public var meanDrawCPUMs: Double { generated == 0 ? 0 : Double(drawCPUSumNs) / Double(generated) / 1e6 }
        /// 平均每帧 GPU 忙（ms）。
        public var meanGPUBusyMs: Double { generated == 0 ? 0 : Double(gpuBusySumNs) / Double(generated) / 1e6 }
    }

    /// 噪声底纹在哪画（只对 `.noise` 底色有意义）。
    public enum NoiseBackend: Hashable, Sendable {
        /// 有 Metal 就 GPU，没有就 CPU；环境变量 `SW_SYNTHETIC_NOISE=cpu|gpu` 可以改（组装方不用加参数就能做 A/B，gate 用）。
        case auto
        /// 契约的 CPU 参考实现（`TestPattern.draw`）。
        case cpu
        /// Metal 计算着色器；没有 Metal / 编译失败时 init 抛错。
        case gpu
    }

    /// 每帧内容的纯函数，线程和离线素材生成共用同一份。
    public struct Generator: Hashable, Sendable {
        /// 拍点时钟（含漂移）。
        public let clock: TickClockSpec
        /// 标称帧率（决定闪光周期）。
        public let frameRate: FrameRate
        /// 烧进画面的调色板索引。
        public let patternID: Int
        /// 底色。
        public let background: TestPattern.Background
        /// 每 N 帧丢 1；0 = 不丢。
        public let dropEveryN: Int

        public init(timeline: SyntheticTimeline, settings: SyntheticSourceSettings, patternID: Int) {
            clock = timeline.videoClock(driftPpm: settings.clockDriftPpm)
            frameRate = timeline.frameRate
            self.patternID = patternID
            background = settings.background
            dropEveryN = settings.dropEveryN
        }

        /// 第 n 帧的 pts（host time）。
        @inline(__always)
        public func pts(of n: Int64) -> HostTime { clock.time(of: Tick(n)) }
        /// 一帧的时长（host tick）。
        public var frameDuration: HostDuration { clock.duration(ofTicks: 1) }
        /// 第 n 帧是否按设定丢掉。
        @inline(__always)
        public func isDropped(_ n: Int64) -> Bool { dropEveryN > 0 && n % Int64(dropEveryN) == Int64(dropEveryN - 1) }
        /// 第 n 帧要烧的内容。
        @inline(__always)
        public func content(of n: Int64) -> TestPattern.Content {
            TestPattern.Content(frameNumber: UInt32(truncatingIfNeeded: n), hostTime: pts(of: n), inputID: patternID,
                                flash: TestPattern.isFlashTick(Tick(n), frameRate: frameRate), background: background)
        }
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .synthetic
    /// 合成源配置。
    public let settings: SyntheticSourceSettings
    /// 实际烧进画面的调色板索引：settings.patternID，或 (number − 1) mod 16。
    public let patternID: Int
    public let videoSlot: (any FrameSlot)?
    public var audioRing: (any AudioRing)? { audio?.audioRing }
    public var state: InputState { stateBox.withLock { $0 } }
    /// start 之后有值：本次运行的时间线（t0 + 帧率）。
    public var timeline: SyntheticTimeline? { timelineBox.withLock { $0 } }
    /// 自带的合成音频源（settings.audio 且注入了环时才有）。
    public let audio: SyntheticAudioInput?
    /// 噪声底纹的 GPU 渲染器；nil = 在 CPU 上画（底色不是噪声、或 `noise: .cpu`、或没有 Metal）。
    public let noiseRenderer: NoisePatternRenderer?
    /// 噪声是否在 GPU 上画。
    public var usesGPUNoise: Bool { noiseRenderer != nil }

    private let slot: any FrameSlot
    private let pool: NV12PixelBufferPool
    private let stateBox = Mutex<InputState>(.noSignal)
    private let timelineBox: Mutex<SyntheticTimeline?>
    private var thread: RealtimeThread?
    private let seed: UInt64
    private let generatedCount = Atomic<UInt64>(0)
    private let droppedCount = Atomic<UInt64>(0)
    private let starvedCount = Atomic<UInt64>(0)
    private let lateCount = Atomic<UInt64>(0)
    private let wakeSum = Atomic<UInt64>(0)
    private let wakeMax = Atomic<UInt64>(0)
    private let drawSum = Atomic<UInt64>(0)
    private let drawCPUSum = Atomic<UInt64>(0)
    private let gpuBusySum = Atomic<UInt64>(0)

    /// - Parameters:
    ///   - videoSlot: 组装方注入的帧槽（契约 §2.3 注入规则）。
    ///   - audioRing: 注入的音频环；settings.audio 为 true 且非 nil 时自带合成音频。
    ///   - timeline: 共用时间线；nil = start() 时取"现在 + 20 ms"。多路要同步就传同一个。
    ///   - seed: 抖动随机序列的种子（同 seed 同序列）。
    ///   - poolBuffers: 像素池大小。W1-B 的引擎侧每路最多同时引用 8 帧（传输环 3 + 候选表 3 + 上一帧 1 + 渲染表 1），
    ///     加正在画的 1 和下游暂存 3，默认 12；不够时帧被跳过并计 `poolStarved`，不阻塞。
    ///   - noise: 噪声底纹在 GPU 还是 CPU 上画（底色不是 `.noise` 时无关）。
    public init(number: Int, name: String? = nil, settings: SyntheticSourceSettings, videoSlot: any FrameSlot,
                audioRing: (any AudioRing)? = nil, timeline: SyntheticTimeline? = nil, seed: UInt64 = 1,
                poolBuffers: Int = 12, noise: NoiseBackend = .auto) throws {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name ?? "Synthetic \(number)"
        self.settings = settings
        patternID = settings.patternID ?? ((number - 1) % TestPattern.paletteSize)
        precondition((0..<TestPattern.paletteSize).contains(patternID), "patternID 须在 0…15")
        slot = videoSlot
        self.videoSlot = videoSlot
        pool = try NV12PixelBufferPool(width: settings.width, height: settings.height, maximumBuffers: poolBuffers)
        timelineBox = Mutex(timeline)
        self.seed = seed
        var backend = noise
        if backend == .auto, let env = ProcessInfo.processInfo.environment["SW_SYNTHETIC_NOISE"] {
            if env == "cpu" { backend = .cpu } else if env == "gpu" { backend = .gpu }
        }
        if case .noise = settings.background, backend != .cpu {
            let renderer: NoisePatternRenderer?
            switch backend {
            case .gpu: renderer = try NoisePatternRenderer()
            default: renderer = try? NoisePatternRenderer()
            }
            if let renderer {
                try pool.forEachBuffer { try renderer.prepare($0) }
                // 预热：第一次真正派发（管线定型、纹理首次写入、队列首个命令缓冲）要几毫秒，8 路同时起时 30 fps 那路的第 0 帧会赶不上第 0 拍
                // （90 s 实跑：录制文件第 0 帧黑场）；在这里画一帧丢掉，start 之后每帧都是稳态成本。
                if let pb = pool.take() {
                    renderer.draw(TestPattern.Content(frameNumber: 0, hostTimeMs: 0, inputID: patternID, flash: false, background: settings.background), into: pb)
                }
            }
            noiseRenderer = renderer
        } else {
            noiseRenderer = nil
        }
        if settings.audio, let audioRing {
            audio = SyntheticAudioInput(number: number, name: "\(self.name) audio", frameRate: settings.frameRate,
                                        driftPpm: settings.audioDriftPpm, audioRing: audioRing, timeline: timeline)
        } else {
            audio = nil
        }
    }

    /// 计数快照。
    public var counters: Counters {
        var c = Counters()
        c.generated = generatedCount.load(ordering: .relaxed)
        c.droppedByDesign = droppedCount.load(ordering: .relaxed)
        c.poolStarved = starvedCount.load(ordering: .relaxed)
        c.late = lateCount.load(ordering: .relaxed)
        c.wakeLatencySumNs = wakeSum.load(ordering: .relaxed)
        c.wakeLatencyMaxNs = wakeMax.load(ordering: .relaxed)
        c.drawSumNs = drawSum.load(ordering: .relaxed)
        c.drawCPUSumNs = drawCPUSum.load(ordering: .relaxed)
        c.gpuBusySumNs = gpuBusySum.load(ordering: .relaxed)
        return c
    }

    /// 起线程（视频 + 自带音频共用 t0）。重复 start 无效。
    public func start() throws {
        guard thread == nil else { return }
        let tl = timelineBox.withLock { box -> SyntheticTimeline in
            if let t = box { return t }
            let t = SyntheticTimeline.startingSoon(frameRate: settings.frameRate)
            box = t
            return t
        }
        let generator = Generator(timeline: tl, settings: settings, patternID: patternID)
        let periodNs = UInt64(max(1, generator.frameDuration.nanoseconds))
        let t = RealtimeThread(name: "synthetic-video-\(number)", periodNanoseconds: periodNs) { [self] thread in
            run(generator: generator, thread: thread)
        }
        thread = t
        stateBox.withLock { $0 = .live }
        t.start()
        try audio?.start(timeline: tl)
    }

    /// 停线程并等它退出；state 回 noSignal。
    public func stop() {
        audio?.stop()
        thread?.stop()
        thread = nil
        stateBox.withLock { $0 = .noSignal }
    }

    // MARK: 线程循环（每帧零分配）

    private func run(generator g: Generator, thread: RealtimeThread) {
        var rng = SplitMix64(seed: seed)
        let jitterMs = settings.jitterMs
        let frameDuration = g.frameDuration
        let lateBudget = frameDuration + HostDuration(milliseconds: jitterMs)
        var n: Int64 = 0
        while !thread.isStopRequested {
            let pts = g.pts(of: n)
            var arrival = pts
            if jitterMs > 0 { arrival = pts + HostDuration(milliseconds: rng.nextSymmetric(jitterMs)) }
            RealtimeThread.wait(until: arrival)
            if thread.isStopRequested { break }
            let woke = HostClock.now()
            let wakeNs = UInt64(max(0, (woke - arrival).nanoseconds))
            wakeSum.wrappingAdd(wakeNs, ordering: .relaxed)
            if wakeNs > wakeMax.load(ordering: .relaxed) { wakeMax.store(wakeNs, ordering: .relaxed) }
            if g.isDropped(n) {
                droppedCount.wrappingAdd(1, ordering: .relaxed)
                n += 1
                continue
            }
            guard let pb = pool.take() else {
                starvedCount.wrappingAdd(1, ordering: .relaxed)
                n += 1
                continue
            }
            let content = g.content(of: n)
            if let r = noiseRenderer, r.draw(content, into: pb) {
                drawCPUSum.wrappingAdd(r.lastCost.cpuNanoseconds, ordering: .relaxed)
                gpuBusySum.wrappingAdd(r.lastCost.gpuNanoseconds, ordering: .relaxed)
            } else {
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                TestPattern.draw(content, into: pb)
                drawCPUSum.wrappingAdd(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0, ordering: .relaxed)
            }
            let now = HostClock.now()
            drawSum.wrappingAdd(UInt64(max(0, (now - woke).nanoseconds)), ordering: .relaxed)
            if now - pts > lateBudget { lateCount.wrappingAdd(1, ordering: .relaxed) }
            slot.push(Frame(pixelBuffer: pb, pts: pts, duration: frameDuration, color: .bt709Limited,
                            inputNumber: number, sequence: UInt64(n), ingressTime: now))
            generatedCount.wrappingAdd(1, ordering: .relaxed)
            n += 1
        }
    }
}
