import CoreVideo
import Foundation
@preconcurrency import Metal
import os
import Synchronization
import SwitcherContracts
import SwitcherOutputs
#if canImport(NDI)
import NDI
#endif

/// NDI 发送的错误。
public enum NDISendError: Swift.Error, Equatable {
    /// 编译时没有 NDI SDK（Package.swift 没探测到 /Library/NDI SDK for Apple）。
    case sdkUnavailable
    /// NDIlib_initialize 失败（CPU 不支持或库版本不对）。
    case initializeFailed
    /// NDIlib_send_create 失败。
    case createFailed
    case alreadyRunning
}

/// NDI 发送的累计计数（值快照）。
public struct NDISendCounters: Hashable, Sendable {
    /// `consume` 收到的帧。
    public var framesReceived: UInt64 = 0
    /// 送出去的视频帧。
    public var framesSent: UInt64 = 0
    /// 队列满丢的最旧帧（E1 口径，Stats.encoder[i].skipped）。
    public var skipped: UInt64 = 0
    /// 没送出去的帧：NV12 → UYVY 转换失败、直送的像素缓冲锁不住、像素格式送不了（D08）。
    public var conversionFailures: UInt64 = 0
    /// 连续 `NDISender.failureStreakLimit` 帧没送出去（D08）：Stats 的 state = failed、last_error 写像素格式；送出去一帧就清，下一次 start 也清。
    public var sendFailing: Bool = false
    /// 送出去的音频块。
    public var audioBlocksSent: UInt64 = 0
    /// 音频环满丢的块。
    public var audioBlocksDropped: UInt64 = 0
    /// 最近一帧 NV12 → UYVY 的耗时（ms）；`maxConvertMs` 是最大值。
    public var lastConvertMs: Double = 0
    public var maxConvertMs: Double = 0
    /// 当前用的是 GPU 还是 CPU 转换。
    public var usingGPU: Bool = false
    /// 转换方式（auto / gpu / cpu，`setConversion` 可运行时改）。
    public var conversion: String = "auto"
    /// auto 模式最近一次探测：同一帧两种方法各转一次的耗时（ms）；没探过为 0。
    public var lastCPUProbeMs: Double = 0
    public var lastGPUProbeMs: Double = 0
    /// auto 模式切换过几次。
    public var autoSwitches: UInt64 = 0
    /// 当前 NDI 接收方数量（NDIlib_send_get_no_connections，每秒查一次）。
    public var connections: Int = 0
    /// SDK 不在 / 初始化失败：Stats 里标 unavailable（初始化失败时 `startFailed` 也为 true，Stats 里 failed 优先）。
    public var unavailable: Bool = false
    /// SDK 在、但 NDIlib_initialize / NDIlib_send_create 失败（提案 019）：Stats 的 state = failed，与"SDK 不在"的 unavailable 分开；
    /// 下一次 start() 清掉。
    public var startFailed: Bool = false
    /// 提案 022：start() 那一刻（uptime_s 的起点；没起过 = nil）与最近一次错误文案（SDK 不在 / initialize / send_create 失败；下一次 start 清）。
    public var startedAt: HostTime? = nil
    public var lastError: String = ""

    public init() {}

    /// Stats.encoder 的一项：NDI 没有码率控制，bitrate = 窗口内送出的 UYVY 字节 × 8 / 秒（原始码率，报告用）。
    /// 提案 001 + 002（P2 落地）：frames = framesSent、dropped = skipped（NDI 没有编码器，队列满丢的帧就是"落地之前丢的"）、
    /// reconnects = 0、disk_free_mb = 0、state = startFailed ? "failed" : unavailable ? "unavailable" : (running ? (sendFailing ? "failed" : "publishing") : "idle")。
    /// 提案 019：output = 这路在 MixerState.outputs 里的编号（组装方给，不给 = 0）；connections = 当前接收方数（SDK 没给 / 负数当 0）。
    /// D08：在跑但连续送不出去（`sendFailing`，比如源是送不了的像素格式）也报 failed，last_error 写像素格式；uptime_s 与其他 failed 一样写 0。
    public func statsEntry(previous: NDISendCounters?, windowSeconds: Double, bytesPerFrame: Int, running: Bool = true, output: Int = 0) -> Stats.EncoderEntry {
        let frames = framesSent &- (previous?.framesSent ?? 0)
        let bitrate = windowSeconds > 0 ? Double(frames * UInt64(bytesPerFrame)) * 8 / windowSeconds : 0
        let publishing = !startFailed && !unavailable && running && !sendFailing
        return Stats.EncoderEntry(output: output, skipped: skipped, bitrate: bitrate, frames: framesSent, dropped: skipped, diskFreeMb: 0, reconnects: 0,
                                  connections: UInt64(max(0, connections)),
                                  state: startFailed ? "failed" : (unavailable ? "unavailable" : (running ? (sendFailing ? "failed" : "publishing") : "idle")),
                                  uptimeS: publishing ? (startedAt.map { max(0, (HostClock.now() - $0).seconds) } ?? 0) : 0, lastError: lastError)   // 022
    }
}

/// NDI 发送（设计方案 §8 NDI 发送行；prompt 交付 3）。
///
/// 线程：`consume`（引擎派发线程）只入有界队列（深度 2–3，满了丢最旧计 skipped）并唤醒；`consumeAudio`（泵线程）拷进音频环。
/// 自己的线程：取帧 → 按像素格式分路（`VideoRoute`，D08）→ NDIlib_send_send_video_async_v2；取音频块 → NDIlib_send_send_audio_v3（同步，几十微秒）。
///   NV12（引擎的 PGM / PVW / 多画面，以及 NV12 的输入）：→ UYVY（GPU / CPU），按帧尺寸（不超过节目尺寸）送；
///   UYVY / BGRA 的输入（图片、屏幕、NDI / DeckLink 输入，源选"输入 n"时原样送进来）：不转、不拷，按帧的原尺寸直接交给 NDI；
///   别的格式送不了。没送出去的帧计 conversionFailures，连续 `failureStreakLimit` 帧 → Stats failed + last_error 写像素格式。
/// 视频异步发送要求缓冲在下一次调用前有效：GPU 版双缓冲、CPU 版双缓冲，都在 init 分配好；直送的输入帧锁着只读、留着引用，下一帧送出去（同步点）之后才放。
public final class NDISender: FrameConsumer, AudioBlockConsumer, @unchecked Sendable {
    /// 一帧怎么送（D08）：NV12（'420v' / '420f'）转 UYVY；UYVY（CoreVideo '2vuy'，字节序 Cb Y0 Cr Y1 = NDI 的 UYVY）与 BGRA 直接交给 NDI
    /// （SDK 原生认这两种）；别的格式送不了（输入只出这三种，见契约 `PixelFormat`；'yuvs' 之类以后有输入出了再加）。
    public enum VideoRoute: Equatable, Sendable {
        case convertNV12
        case directUYVY
        case directBGRA
        case unsupported

        public init(pixelFormat: OSType) {
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .convertNV12
            case kCVPixelFormatType_422YpCbCr8: self = .directUYVY
            case kCVPixelFormatType_32BGRA: self = .directBGRA
            default: self = .unsupported
            }
        }
    }

    /// 连续多少帧没送出去就把这一路报成 failed（D08）。偶尔一两帧（GPU 纹理建不出来之类）不翻状态；源是送不了的格式时每拍都失败，60 fps 下约 0.17 s 就报。
    public static let failureStreakLimit = 10

    /// CoreVideo 像素格式的四字符名（'BGRA'、'2vuy'、'420v'、'yuvs'），不是可打印四字符的写十六进制（last_error 用）。
    public static func pixelFormatName(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF), UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return String(decoding: bytes, as: UTF8.self) }
        return String(format: "0x%08X", type)
    }

    /// 参数。
    public struct Configuration: Sendable {
        /// NDI 源名（在网络上显示为 "<机器名> (name)"）。
        public var name: String
        /// NDI 分组，nil = 默认组。
        public var groups: String?
        /// 节目格式（尺寸、帧率）。
        public var format: ProgramFormat
        /// 送什么：program（必送）/ preview / multiview 从 RenderedFrame 里挑；input(n) 由引擎用 `send(frame:)` 直接喂。
        public var source: OutputSource
        /// 转换方式。
        public var conversion: Conversion
        /// 有界队列深度（2–3）。
        public var queueDepth: Int
        /// 音频声道数。
        public var audioChannels: Int
        /// 干跑：走完队列 + 转换，不调 NDI（测试转换成本 / 队列行为用；SDK 不在时也能跑）。
        public var dryRun: Bool

        /// NV12 → UYVY 用什么算。低负载下 release 构建 CPU 逐行 0.09 ms / GPU 0.25 ms（提交 + 等完成），高负载下谁便宜说不准
        /// （合成器把 GPU 队列排满时 GPU 路径要等；CPU 被编码 / 音频挤时 CPU 路径变慢），所以默认 auto：定期两种都试、用便宜的。
        public enum Conversion: String, Hashable, Sendable, CaseIterable {
            /// 每 `autoProbeInterval` 帧把同一帧用两种方法各转一次，之后用便宜的（便宜 30% 以上才切，防抖）。没有 Metal 就是 cpu。
            case auto
            /// Metal kernel；没有 Metal 设备时退到 CPU。
            case gpu
            /// 逐行 CPU 转换。
            case cpu

            /// `OutputSettings.extra` 里的键：`"ndi.conversion": "auto" | "gpu" | "cpu"`（G3 接 Show 文件 / UI 用）。
            public static let extraKey = "ndi.conversion"

            /// 从 `OutputSettings.extra` 读；没有或不认识 = auto。
            public init(extra: [String: JSONValue]) {
                if case .string(let s)? = extra[Self.extraKey], let v = Conversion(rawValue: s.lowercased()) {
                    self = v
                } else {
                    self = .auto
                }
            }
        }

        /// auto 模式的探测间隔（帧）；默认 300 = 60 fps 下 5 s。
        public var autoProbeInterval: Int

        public init(name: String, groups: String? = nil, format: ProgramFormat, source: OutputSource = .program,
                    conversion: Conversion = .auto, queueDepth: Int = 3, audioChannels: Int = 2, dryRun: Bool = false,
                    autoProbeInterval: Int = 300) {
            precondition((1...8).contains(queueDepth) && autoProbeInterval >= 1)
            self.name = name
            self.groups = groups
            self.format = format
            self.source = source
            self.conversion = conversion
            self.queueDepth = queueDepth
            self.audioChannels = audioChannels
            self.dryRun = dryRun
            self.autoProbeInterval = autoProbeInterval
        }
    }

    /// 编译时是否有 SDK。
    public static var isAvailable: Bool { SwitcherNDISendInfo.isSDKAvailable }

    public let consumerName: String
    public let configuration: Configuration

    private let queue: FrameRing
    private let audioRing: PCMRing
    private let wakeup = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var running = false
    private var thread: Thread?
    private let stopRequested = Atomic<Bool>(false)
    private let acceptingFrames = Atomic<Bool>(false)
    private let threadGroup = DispatchGroup()
    private let counters = AtomicNDICounters()
    private let logger = Logger(subsystem: "switcher.ndisend", category: "NDISender")
    // 转换（只在发送线程和 start / stop 里碰；`conversionMode` 是外面可改的开关）
    private var gpu: NV12ToUYVY.GPU?
    private var cpuBuffers: [UnsafeMutableRawPointer] = []
    private var cpuNext = 0
    private let bytesPerFrame: Int
    private let conversionMode: Mutex<Configuration.Conversion>
    private var activeGPU = false          // 当前这帧用哪个（发送线程）
    private var framesSinceProbe = 0
    private var probedOnce = false
    /// 连续没送出去的帧数（发送线程；start 清）。到 `failureStreakLimit` 时翻 failed（D08）。
    private var failureStreak = 0
    #if canImport(NDI)
    private var sender: NDIlib_send_instance_t?
    private var nameCString: UnsafeMutablePointer<CChar>?
    private var groupsCString: UnsafeMutablePointer<CChar>?
    private var audioPlanar: UnsafeMutablePointer<Float>?    // no_channels × maxFrames，FLTP
    private let audioMaxFrames = 4096
    /// 上一帧直送的输入像素缓冲（D08）：NDI 异步发送要它的内存保持到下一次 send_video_async（同步点），所以锁着只读、留着引用，
    /// 下一帧送出去之后、或 stop 冲掉之后才解锁放掉。发送线程碰；stop 在发送线程退出之后碰。
    private var inFlightDirect: CVPixelBuffer?
    #endif

    public init(configuration: Configuration) {
        self.configuration = configuration
        consumerName = configuration.name
        queue = FrameRing(capacity: configuration.queueDepth)
        audioRing = PCMRing(channelCount: configuration.audioChannels, maxFrames: 4096, capacity: 64)
        bytesPerFrame = configuration.format.width * configuration.format.height * 2
        conversionMode = Mutex(configuration.conversion)
        counters.conversion = configuration.conversion
        counters.unavailable.store(!Self.isAvailable, ordering: .relaxed)
    }

    deinit {
        for b in cpuBuffers { b.deallocate() }
        #if canImport(NDI)
        audioPlanar?.deallocate()
        nameCString.map { free($0) }
        groupsCString.map { free($0) }
        #endif
    }

    /// 计数快照。
    public var countersSnapshot: NDISendCounters { counters.snapshot() }
    /// 是否在运行。
    public var isRunning: Bool { stateLock.withLock { running } }
    /// 每帧 UYVY 字节数（statsEntry 用）。
    public var uyvyBytesPerFrame: Int { bytesPerFrame }

    /// Stats.encoder 的一项（state：SDK 在但起不来 = failed（019）；SDK 不在 = unavailable；在跑 = publishing；没跑 = idle）。
    public func statsEntry(previous: NDISendCounters?, windowSeconds: Double, output: Int = 0) -> Stats.EncoderEntry {
        counters.snapshot().statsEntry(previous: previous, windowSeconds: windowSeconds, bytesPerFrame: bytesPerFrame, running: isRunning, output: output)
    }

    /// 起：初始化 NDI、建发送实例、建转换器、起线程。
    /// SDK 不在（编译时没探测到）：空实现 —— 不抛错、不起线程，`countersSnapshot.unavailable == true`，帧照收但直接丢（不计 skipped）；
    /// `dryRun` 时例外：起线程、做转换、不调 NDI（测试用）。SDK 在但初始化 / 建实例失败：抛错并标 unavailable。
    public func start() throws {
        try stateLock.withLock {
            guard !running else { throw NDISendError.alreadyRunning }
            let haveSDK = Self.isAvailable
            counters.startFailed.store(false, ordering: .relaxed)   // 019：上一次起失败的记号到这次 start 为止
            counters.sendFailing.store(false, ordering: .relaxed)   // D08：上一次连续送不出去的记号也到这次 start 为止
            failureStreak = 0
            counters.startedAtTicks.store(HostClock.now().ticks, ordering: .relaxed)   // 022：uptime_s 起点；上一次的错误到这次 start 为止
            counters.lastErrorText.withLock { $0 = haveSDK ? "" : "NDI SDK 不在（编译时没探测到）" }
            #if canImport(NDI)
            if !configuration.dryRun {
                guard NDIlib_initialize() else {
                    counters.unavailable.store(true, ordering: .relaxed)
                    counters.startFailed.store(true, ordering: .relaxed)   // 019：SDK 在但起不来 → Stats failed
                    counters.lastErrorText.withLock { $0 = "NDIlib_initialize 失败" }   // 022
                    throw NDISendError.initializeFailed
                }
                nameCString = strdup(configuration.name)
                groupsCString = configuration.groups.map { strdup($0) }
                var desc = NDIlib_send_create_t(p_ndi_name: UnsafePointer(nameCString), p_groups: UnsafePointer(groupsCString),
                                                clock_video: false, clock_audio: false)
                guard let s = NDIlib_send_create(&desc) else {
                    counters.unavailable.store(true, ordering: .relaxed)
                    counters.startFailed.store(true, ordering: .relaxed)   // 019
                    counters.lastErrorText.withLock { $0 = "NDIlib_send_create 失败" }   // 022
                    throw NDISendError.createFailed
                }
                sender = s
                if audioPlanar == nil {
                    audioPlanar = .allocate(capacity: configuration.audioChannels * audioMaxFrames)
                    audioPlanar?.initialize(repeating: 0, count: configuration.audioChannels * audioMaxFrames)
                }
            }
            #endif
            counters.unavailable.store(!haveSDK, ordering: .relaxed)
            guard haveSDK || configuration.dryRun else {
                running = true
                acceptingFrames.store(false, ordering: .releasing)   // 空实现：收到就丢
                return
            }
            try prepareConverter()
            stopRequested.store(false, ordering: .releasing)
            running = true
            threadGroup.enter()
            let t = Thread { [weak self] in
                self?.loop()
                self?.threadGroup.leave()
            }
            t.name = "switcher.ndisend.\(consumerName)"
            t.qualityOfService = .userInteractive
            thread = t
            acceptingFrames.store(true, ordering: .releasing)
            t.start()
        }
    }

    /// 停：不再收帧，线程退出，销毁发送实例。
    public func stop() {
        let wasRunning: Bool = stateLock.withLock {
            guard running else { return false }
            running = false
            return true
        }
        guard wasRunning else { return }
        acceptingFrames.store(false, ordering: .releasing)
        stopRequested.store(true, ordering: .releasing)
        wakeup.signal()
        if stateLock.withLock({ thread }) != nil { threadGroup.wait() }
        stateLock.withLock {
            thread = nil
            #if canImport(NDI)
            if let sender {
                NDIlib_send_send_video_async_v2(sender, nil)   // 让 SDK 放掉最后一帧的缓冲
                NDIlib_send_destroy(sender)
            }
            sender = nil
            releaseInFlightDirect()   // 冲掉之后 SDK 不再读最后一帧直送的输入缓冲
            #endif
        }
    }

    /// 运行时改转换方式（UI / API 调；发送线程下一帧生效）。
    public func setConversion(_ mode: Configuration.Conversion) {
        conversionMode.withLock { $0 = mode }
        counters.conversion = mode
    }

    /// 当前转换方式。
    public var conversion: Configuration.Conversion { conversionMode.withLock { $0 } }

    /// 转换器：CPU 双缓冲总是建（4 MB × 2）；GPU 在 gpu / auto 模式且有 Metal 设备时建。只在 start 里调（测试也可以单独调）。
    public func prepareConverter() throws {
        let f = configuration.format
        let mode = conversion
        if mode != .cpu, gpu == nil, let device = MTLCreateSystemDefaultDevice() {
            do {
                gpu = try NV12ToUYVY.GPU(device: device, width: f.width, height: f.height)
            } catch {
                logger.warning("Metal 转换器建不出来，退到 CPU：\(String(describing: error), privacy: .public)")
            }
        }
        if cpuBuffers.isEmpty {
            for _ in 0..<2 {
                let b = UnsafeMutableRawPointer.allocate(byteCount: bytesPerFrame, alignment: 64)
                b.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerFrame)
                cpuBuffers.append(b)
            }
        }
        activeGPU = gpu != nil && mode != .cpu
        counters.usingGPU.store(activeGPU, ordering: .relaxed)
    }

    /// 转一帧（按当前方式），返回的缓冲到该方式下下次 convert 之前有效。测试用；发送线程内部也用它。
    public func convert(_ pixelBuffer: CVPixelBuffer) throws -> NV12ToUYVY.UYVYBuffer {
        if cpuBuffers.isEmpty { try prepareConverter() }
        applyConversionMode()
        return activeGPU ? try convertGPU(pixelBuffer) : try convertCPU(pixelBuffer)
    }

    private func convertGPU(_ pixelBuffer: CVPixelBuffer) throws -> NV12ToUYVY.UYVYBuffer {
        guard let gpu else { return try convertCPU(pixelBuffer) }
        return try gpu.convert(pixelBuffer)
    }

    private func convertCPU(_ pixelBuffer: CVPixelBuffer) throws -> NV12ToUYVY.UYVYBuffer {
        // 按帧尺寸（不超过节目尺寸）转、行距紧排，与 GPU 版一样（D08：源是比节目小的 NV12 输入时，以前送的是节目尺寸、右边 / 下边是上一帧的残留）
        let out = NV12ToUYVY.UYVYBuffer(width: min(CVPixelBufferGetWidth(pixelBuffer), configuration.format.width),
                                        height: min(CVPixelBufferGetHeight(pixelBuffer), configuration.format.height), base: cpuBuffers[cpuNext])
        cpuNext = (cpuNext + 1) % cpuBuffers.count
        try NV12ToUYVY.convertCPU(pixelBuffer, into: out)
        return out
    }

    /// 把外面设的方式落到 activeGPU（gpu / cpu 立即；auto 由探测决定）。
    private func applyConversionMode() {
        switch conversion {
        case .gpu: activeGPU = gpu != nil
        case .cpu: activeGPU = false
        case .auto: if gpu == nil { activeGPU = false }
        }
        counters.usingGPU.store(activeGPU, ordering: .relaxed)
    }

    /// auto：到点就把这一帧用另一种方法也转一次，比耗时；便宜 30% 以上才切（防抖）。返回 true = 这次探测过了。
    /// 另一种方法的输出只用来计时，不送出去（它自己的双缓冲，不碰正在被 NDI 异步发送的那块）。
    private func autoProbeIfDue(_ pixelBuffer: CVPixelBuffer, currentMs: Double) {
        guard conversion == .auto, gpu != nil else { return }
        framesSinceProbe += 1
        guard !probedOnce || framesSinceProbe >= configuration.autoProbeInterval else { return }
        probedOnce = true
        framesSinceProbe = 0
        let t0 = HostClock.now()
        let otherOK = (try? (activeGPU ? convertCPU(pixelBuffer) : convertGPU(pixelBuffer))) != nil
        guard otherOK else { return }
        let otherMs = (HostClock.now() - t0).milliseconds
        let (cpuMs, gpuMs) = activeGPU ? (otherMs, currentMs) : (currentMs, otherMs)
        counters.lastCPUProbeMs.store(cpuMs, ordering: .relaxed)
        counters.lastGPUProbeMs.store(gpuMs, ordering: .relaxed)
        if otherMs < currentMs * 0.7 {
            activeGPU.toggle()
            counters.usingGPU.store(activeGPU, ordering: .relaxed)
            counters.autoSwitches.add(1, ordering: .relaxed)
            logger.info("[\(self.consumerName, privacy: .public)] NV12→UYVY 切到 \(self.activeGPU ? "GPU" : "CPU", privacy: .public)（CPU \(cpuMs, format: .fixed(precision: 2)) ms / GPU \(gpuMs, format: .fixed(precision: 2)) ms）")
        }
    }

    // MARK: FrameConsumer / AudioBlockConsumer

    public func consume(_ frame: RenderedFrame) {
        let picked: Frame?
        switch configuration.source {
        case .program: picked = frame.program
        case .preview: picked = frame.preview
        case .multiview: picked = frame.multiview
        case .input: picked = nil     // 输入画面由引擎用 send(frame:) 喂
        }
        guard let picked else { return }
        send(frame: picked, tickTime: frame.tickTime)
    }

    /// 直接喂一帧（`source = .input(n)` 时引擎从该输入的帧槽喂；时间戳用帧的 pts）。
    public func send(frame: Frame, tickTime: HostTime? = nil) {
        counters.framesReceived.add(1, ordering: .relaxed)
        guard acceptingFrames.load(ordering: .acquiring) else { return }
        if queue.push(QueuedFrame(frame: frame, time: tickTime ?? frame.pts)) != nil {
            counters.skipped.add(1, ordering: .relaxed)
        }
        wakeup.signal()
    }

    public func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        guard acceptingFrames.load(ordering: .acquiring) else { return }
        if audioRing.push(planes: planes, channelCount: channelCount, frameCount: frameCount, hostTime: hostTime) {
            counters.audioBlocksDropped.add(1, ordering: .relaxed)
        }
        wakeup.signal()
    }

    // MARK: 发送线程

    private func loop() {
        var lastConnectionsCheck = HostClock.now()
        while true {
            _ = wakeup.wait(timeout: .now() + .seconds(1))
            if stopRequested.load(ordering: .acquiring) { return }
            while let block = audioRing.pop() {
                sendAudio(block)
            }
            while let item = queue.pop() {
                sendVideo(item)
            }
            let now = HostClock.now()
            if (now - lastConnectionsCheck).seconds >= 1 {
                lastConnectionsCheck = now
                #if canImport(NDI)
                if let sender { counters.connections.store(Int(NDIlib_send_get_no_connections(sender, 0)), ordering: .relaxed) }
                #endif
            }
        }
    }

    /// 一帧：按像素格式分路（D08）。
    private func sendVideo(_ item: QueuedFrame) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(item.frame.pixelBuffer)
        switch VideoRoute(pixelFormat: pixelFormat) {
        case .convertNV12: sendConverted(item, pixelFormat: pixelFormat)
        case .directUYVY: sendDirect(item, route: .directUYVY, pixelFormat: pixelFormat)
        case .directBGRA: sendDirect(item, route: .directBGRA, pixelFormat: pixelFormat)
        case .unsupported: noteFailure(.unsupported(pixelFormat))
        }
    }

    /// NV12 → UYVY（GPU / CPU，双缓冲）→ 送。
    private func sendConverted(_ item: QueuedFrame, pixelFormat: OSType) {
        let t0 = HostClock.now()
        let out: NV12ToUYVY.UYVYBuffer
        do {
            out = try convert(item.frame.pixelBuffer)
        } catch let error as NV12ToUYVY.Error {
            noteFailure(.conversion(pixelFormat, error))
            return
        } catch {
            noteFailure(.conversion(pixelFormat, .metal("\(error)")))
            return
        }
        let convertMs = (HostClock.now() - t0).milliseconds
        counters.recordConvert(HostClock.now() - t0)
        autoProbeIfDue(item.frame.pixelBuffer, currentMs: convertMs)
        #if canImport(NDI)
        if let sender {   // dryRun 时是 nil：只转换、只计数
            var v = videoFrame(fourCC: NDIlib_FourCC_video_type_UYVY, width: out.width, height: out.height, stride: out.bytesPerRow,
                               data: out.base, time: item.time)
            NDIlib_send_send_video_async_v2(sender, &v)
            releaseInFlightDirect()   // 这次调用是同步点：上一帧要是直送的输入缓冲，SDK 已经用完
        }
        #endif
        noteSent()
    }

    /// UYVY / BGRA 的输入帧：不转、不拷，按帧的原尺寸与行距直接交给 NDI；缓冲锁着只读、留到下一帧送出去之后（NDI 异步发送的要求）。
    private func sendDirect(_ item: QueuedFrame, route: VideoRoute, pixelFormat: OSType) {
        let pb = item.frame.pixelBuffer
        let r = CVPixelBufferLockBaseAddress(pb, .readOnly)
        guard r == kCVReturnSuccess else {
            noteFailure(.lock(pixelFormat, r))
            return
        }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            noteFailure(.noBaseAddress(pixelFormat))
            return
        }
        #if canImport(NDI)
        if let sender {   // dryRun 时是 nil：只验能不能读、只计数
            var v = videoFrame(fourCC: route == .directBGRA ? NDIlib_FourCC_video_type_BGRA : NDIlib_FourCC_video_type_UYVY,
                               width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), stride: CVPixelBufferGetBytesPerRow(pb),
                               data: base, time: item.time)
            NDIlib_send_send_video_async_v2(sender, &v)
            releaseInFlightDirect()   // 上一帧直送的缓冲：这次调用之后 SDK 不再读（同一缓冲连送两拍时锁计数 2 → 1，照样平衡）
            inFlightDirect = pb
            noteSent()
            return
        }
        #endif
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        noteSent()
    }

    #if canImport(NDI)
    private func videoFrame(fourCC: NDIlib_FourCC_video_type_e, width: Int, height: Int, stride: Int, data: UnsafeMutableRawPointer,
                            time: HostTime) -> NDIlib_video_frame_v2_t {
        var v = NDIlib_video_frame_v2_t()
        v.xres = Int32(width)
        v.yres = Int32(height)
        v.FourCC = fourCC
        v.frame_rate_N = Int32(configuration.format.frameRate.framesPerSecond.numerator)
        v.frame_rate_D = Int32(configuration.format.frameRate.framesPerSecond.denominator)
        v.picture_aspect_ratio = height > 0 ? Float(width) / Float(height) : 0
        v.frame_format_type = NDIlib_frame_format_type_progressive
        v.timecode = NDIlib_send_timecode_synthesize
        v.p_data = data.assumingMemoryBound(to: UInt8.self)
        v.line_stride_in_bytes = Int32(stride)
        v.timestamp = NDITime.utc100ns(hostTime: time)
        return v
    }

    /// 解锁、放掉上一帧直送的输入缓冲（发送线程；stop 在发送线程退出、SDK 冲掉之后调）。
    private func releaseInFlightDirect() {
        guard let pb = inFlightDirect else { return }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        inFlightDirect = nil
    }
    #endif

    /// 没送出去的原因（文案只在翻 failed 那一帧拼，失败的每一帧本身不拼字符串）。
    private enum SendFailure {
        case unsupported(OSType)
        case conversion(OSType, NV12ToUYVY.Error)
        case lock(OSType, CVReturn)
        case noBaseAddress(OSType)

        func describe(streak: Int) -> String {
            switch self {
            case .unsupported(let t):
                "NDI 送不了像素格式 '\(NDISender.pixelFormatName(t))'（只认 NV12 / UYVY / BGRA），连续 \(streak) 帧没送出"
            case .conversion(let t, let e):
                "NDI 的 '\(NDISender.pixelFormatName(t))' → UYVY 转换失败（\(e)），连续 \(streak) 帧没送出"
            case .lock(let t, let r):
                "NDI 直送的 '\(NDISender.pixelFormatName(t))' 像素缓冲锁不住（CVReturn \(r)），连续 \(streak) 帧没送出"
            case .noBaseAddress(let t):
                "NDI 直送的 '\(NDISender.pixelFormatName(t))' 像素缓冲没有内存地址，连续 \(streak) 帧没送出"
            }
        }
    }

    /// 送出去一帧（发送线程）：计数；之前连续失败报了 failed 的，这里回到 publishing（last_error 留着，start 才清）。
    private func noteSent() {
        counters.framesSent.add(1, ordering: .relaxed)
        if failureStreak >= Self.failureStreakLimit {
            counters.sendFailing.store(false, ordering: .relaxed)
            logger.info("[\(self.consumerName, privacy: .public)] 恢复送出（之前连续 \(self.failureStreak) 帧没送出）")
        }
        failureStreak = 0
    }

    /// 一帧没送出去（发送线程）：计 conversionFailures；连续到 `failureStreakLimit` 那一帧翻 failed、写 last_error（只写一次）。
    private func noteFailure(_ failure: SendFailure) {
        counters.conversionFailures.add(1, ordering: .relaxed)
        failureStreak += 1
        guard failureStreak == Self.failureStreakLimit else { return }
        let text = failure.describe(streak: failureStreak)
        counters.lastErrorText.withLock { $0 = text }
        counters.sendFailing.store(true, ordering: .relaxed)
        logger.error("[\(self.consumerName, privacy: .public)] \(text, privacy: .public)")
    }

    private func sendAudio(_ block: PCMRing.Block) {
        #if canImport(NDI)
        if let sender, let audioPlanar {   // dryRun 时是 nil：只计数
        let n = min(block.frameCount, audioMaxFrames)
        for ch in 0..<configuration.audioChannels {
            (audioPlanar + ch * audioMaxFrames).update(from: block.planes[ch], count: n)
        }
        var a = NDIlib_audio_frame_v3_t()
        a.sample_rate = Int32(AudioFormat.sampleRate)
        a.no_channels = Int32(configuration.audioChannels)
        a.no_samples = Int32(n)
        a.timecode = NDIlib_send_timecode_synthesize
        a.FourCC = NDIlib_FourCC_audio_type_FLTP
        a.p_data = UnsafeMutableRawPointer(audioPlanar).assumingMemoryBound(to: UInt8.self)
        a.channel_stride_in_bytes = Int32(audioMaxFrames * MemoryLayout<Float>.size)
        a.timestamp = NDITime.utc100ns(hostTime: block.hostTime)
        NDIlib_send_send_audio_v3(sender, &a)
        }
        #endif
        counters.audioBlocksSent.add(1, ordering: .relaxed)
    }
}

/// host time → NDI 时间戳（UTC，100 ns 单位）：用"现在"的墙钟与 host time 差换算。
enum NDITime {
    static func utc100ns(hostTime: HostTime) -> Int64 {
        let now = HostClock.now()
        let wallNow = Date().timeIntervalSince1970
        let delta = (hostTime - now).seconds
        return Int64((wallNow + delta) * 1e7)
    }
}

/// 队列里的一帧。
struct QueuedFrame {
    let frame: Frame
    let time: HostTime
}

/// 有界帧环（满了返回被挤掉的最旧帧）。
final class FrameRing: @unchecked Sendable {
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private var slots: [QueuedFrame?]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    func push(_ f: QueuedFrame) -> QueuedFrame? {
        lock.lock()
        defer { lock.unlock() }
        var evicted: QueuedFrame?
        if count == capacity {
            evicted = slots[head]
            slots[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        slots[(head + count) % capacity] = f
        count += 1
        return evicted
    }

    func pop() -> QueuedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let f = slots[head]
        slots[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return f
    }
}

/// 音频块环（同 SwitcherStreaming 的 PCMBlockRing；两个模块互不依赖，各自一份）。
/// 出口块（D05，Codex 2026-10-13 审查）：pop 在锁内把最旧那一槽拷进发送线程独占的出口块（init 时分配，push 从不碰它），
/// 交出去的是出口块的视图。以前交的是槽内指针：队列原本满时下一次 push（泵线程的 consumeAudio）的尾槽正好是刚 pop 出来的那一格，
/// 发送线程还没拷完就被覆盖。只许一个消费者（发送线程）；pop / push 都不分配。
final class PCMRing: @unchecked Sendable {
    /// pop 出来的块：planes 指向发送线程独占的出口块，到下一次 pop 之前有效，期间 push 不会改它。
    struct Block {
        var hostTime: HostTime
        var frameCount: Int
        var planes: UnsafePointer<UnsafePointer<Float>>
    }

    let channelCount: Int
    let maxFrames: Int
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Float>
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outStorage: UnsafeMutablePointer<Float>          // 出口块：channelCount × maxFrames，只有消费者碰
    private let outPlanes: UnsafeMutablePointer<UnsafePointer<Float>>
    private var hostTimes: [HostTime]
    private var frameCounts: [Int]
    private var head = 0
    private var count = 0

    init(channelCount: Int, maxFrames: Int, capacity: Int) {
        self.channelCount = channelCount
        self.maxFrames = maxFrames
        self.capacity = capacity
        storage = .allocate(capacity: capacity * channelCount * maxFrames)
        storage.initialize(repeating: 0, count: capacity * channelCount * maxFrames)
        planeTable = .allocate(capacity: capacity * channelCount)
        for slot in 0..<capacity {
            for ch in 0..<channelCount {
                planeTable[slot * channelCount + ch] = UnsafePointer(storage + (slot * channelCount + ch) * maxFrames)
            }
        }
        outStorage = .allocate(capacity: channelCount * maxFrames)
        outStorage.initialize(repeating: 0, count: channelCount * maxFrames)
        outPlanes = .allocate(capacity: channelCount)
        for ch in 0..<channelCount { outPlanes[ch] = UnsafePointer(outStorage + ch * maxFrames) }
        hostTimes = Array(repeating: .zero, count: capacity)
        frameCounts = Array(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        planeTable.deallocate()
        outStorage.deallocate()
        outPlanes.deallocate()
    }

    /// 返回 true = 满了丢了最旧的一块。
    func push(planes: UnsafePointer<UnsafePointer<Float>>, channelCount inChannels: Int, frameCount: Int, hostTime: HostTime) -> Bool {
        let n = min(frameCount, maxFrames)
        lock.lock()
        defer { lock.unlock() }
        var dropped = false
        if count == capacity {
            head = (head + 1) % capacity
            count -= 1
            dropped = true
        }
        let slot = (head + count) % capacity
        for ch in 0..<channelCount {
            let src = planes[min(ch, max(inChannels - 1, 0))]
            UnsafeMutablePointer(mutating: planeTable[slot * channelCount + ch]).update(from: src, count: n)
        }
        hostTimes[slot] = hostTime
        frameCounts[slot] = n
        count += 1
        return dropped
    }

    /// 取最旧的一块：锁内拷进出口块、把槽还给队列，返回出口块的视图（到下一次 pop 之前有效）。单消费者。
    func pop() -> Block? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let slot = head
        let n = frameCounts[slot]
        for ch in 0..<channelCount {
            (outStorage + ch * maxFrames).update(from: planeTable[slot * channelCount + ch], count: n)
        }
        head = (head + 1) % capacity
        count -= 1
        return Block(hostTime: hostTimes[slot], frameCount: n, planes: UnsafePointer(outPlanes))
    }
}

/// 原子计数。
final class AtomicNDICounters: @unchecked Sendable {
    let framesReceived = Atomic<UInt64>(0)
    let framesSent = Atomic<UInt64>(0)
    let skipped = Atomic<UInt64>(0)
    let conversionFailures = Atomic<UInt64>(0)
    let sendFailing = Atomic<Bool>(false)           // D08
    let audioBlocksSent = Atomic<UInt64>(0)
    let audioBlocksDropped = Atomic<UInt64>(0)
    let lastConvertTicks = Atomic<Int64>(0)
    let maxConvertTicks = Atomic<Int64>(0)
    let usingGPU = Atomic<Bool>(false)
    let connections = Atomic<Int>(0)
    let unavailable = Atomic<Bool>(true)
    let startFailed = Atomic<Bool>(false)
    let startedAtTicks = Atomic<UInt64>(0)          // 022：0 = 没起过
    let lastErrorText = Mutex<String>("")           // 022
    let lastCPUProbeMs = Atomic<Double>(0)
    let lastGPUProbeMs = Atomic<Double>(0)
    let autoSwitches = Atomic<UInt64>(0)
    private let conversionLock = Mutex<NDISender.Configuration.Conversion>(.auto)
    var conversion: NDISender.Configuration.Conversion {
        get { conversionLock.withLock { $0 } }
        set { conversionLock.withLock { $0 = newValue } }
    }

    func recordConvert(_ d: HostDuration) {
        lastConvertTicks.store(d.ticks, ordering: .relaxed)
        var current = maxConvertTicks.load(ordering: .relaxed)
        while d.ticks > current {
            let (done, original) = maxConvertTicks.compareExchange(expected: current, desired: d.ticks, ordering: .relaxed)
            if done { break }
            current = original
        }
    }

    func snapshot() -> NDISendCounters {
        var c = NDISendCounters()
        c.framesReceived = framesReceived.load(ordering: .relaxed)
        c.framesSent = framesSent.load(ordering: .relaxed)
        c.skipped = skipped.load(ordering: .relaxed)
        c.conversionFailures = conversionFailures.load(ordering: .relaxed)
        c.sendFailing = sendFailing.load(ordering: .relaxed)
        c.audioBlocksSent = audioBlocksSent.load(ordering: .relaxed)
        c.audioBlocksDropped = audioBlocksDropped.load(ordering: .relaxed)
        c.lastConvertMs = HostDuration(ticks: lastConvertTicks.load(ordering: .relaxed)).milliseconds
        c.maxConvertMs = HostDuration(ticks: maxConvertTicks.load(ordering: .relaxed)).milliseconds
        c.usingGPU = usingGPU.load(ordering: .relaxed)
        c.conversion = conversion.rawValue
        c.lastCPUProbeMs = lastCPUProbeMs.load(ordering: .relaxed)
        c.lastGPUProbeMs = lastGPUProbeMs.load(ordering: .relaxed)
        c.autoSwitches = autoSwitches.load(ordering: .relaxed)
        c.connections = connections.load(ordering: .relaxed)
        c.unavailable = unavailable.load(ordering: .relaxed)
        c.startFailed = startFailed.load(ordering: .relaxed)
        let started = startedAtTicks.load(ordering: .relaxed)
        c.startedAt = started == 0 ? nil : HostTime(ticks: started)   // 022
        c.lastError = lastErrorText.withLock { $0 }
        return c
    }
}
