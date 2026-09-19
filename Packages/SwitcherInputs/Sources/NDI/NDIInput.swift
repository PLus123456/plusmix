import CSwitcherNDI
import CoreVideo
import Darwin
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherInputs

/// NDI 输入的错误。
public enum NDIInputError: Error, Equatable, CustomStringConvertible {
    /// 编译时没有 NDI SDK。
    case sdkUnavailable
    /// NDIlib_initialize 失败（CPU 不支持或 libndi 版本不对）。
    case initializeFailed
    case finderCreateFailed
    case receiverCreateFailed
    case notAnNDISource(InputKind)

    public var description: String {
        switch self {
        case .sdkUnavailable: SwitcherNDIInfo.unavailableMessage
        case .initializeFailed: "NDI 初始化失败：CPU 不支持或 libndi 版本不对"
        case .finderCreateFailed: "建不出 NDI 发现器"
        case .receiverCreateFailed: "建不出 NDI 接收器"
        case .notAnNDISource(let k): "不是 NDI 来源：\(k)"
        }
    }
}

/// NDI 输入（设计方案 §6 NDI 行；W3-A 交付 2）。整体说明见 SwitcherNDI.swift 头注释。
///
/// - 线程：一条接收线程（`InputThread`，不挂实时策略：capture 本身带超时阻塞），只有它 push 帧 / 写环 / 调 SDK。
/// - 源：按 `InputSource.ndi(sourceName:)` 的名字（"机器名 (源名)"）连；起流时源不在也不报错，等它出现。
///   不 live 时每 `rediscoverInterval` 查一次发现器：源出现或地址变了就 `recv_connect`（源重开后端口会变）。
/// - 无信号：连续 `noSignalMultiplier` 个帧间隔没有视频帧 → noSignal（帧间隔取自最近一帧的帧率，没帧时用节目帧率）。
///   audioOnly 带宽时按音频块算。
/// - 帧：UYVY → '2vuy'；有 alpha 的源 SDK 给 BGRA → 32BGRA（按预乘 alpha 交给渲染器；NDI 的 RGBA 约定是预乘，见报告 §4）。
///   拷进池里的 IOSurface 缓冲（一次拷贝，SDK 的缓冲用完就还）。
/// - 时间戳：`pts = arrival − jitter + J × 帧间隔`（NDIClockMap），`ingressTime` = push 前一刻。
/// - 音频：FLTP → 环（声道按环的声道数映射：多的丢、单声道复制、少的复制最后一路）；非 48 kHz 线性重采样；
///   块首 host time = `arrival − jitter − 块时长 + J × 帧间隔`（与视频同一映射）。
/// - tally：`setTally(_:)` 存下、接收线程下一轮 `NDIlib_recv_set_tally`；重连后再发一次。
public final class NDIInput: Input, @unchecked Sendable {
    /// 带宽模式（NDIlib_recv_bandwidth）。进契约要走提案（docs/contract-changes/008）。
    public enum Bandwidth: String, Sendable, Hashable, CaseIterable, Codable {
        /// 全分辨率视频 + 音频。
        case highest
        /// 低分辨率预览流 + 音频（多画面缩略图够用，省带宽）。
        case lowest
        /// 只要音频。
        case audioOnly

        var raw: sw_ndi_bandwidth {
            switch self {
            case .highest: SW_NDI_BANDWIDTH_HIGHEST
            case .lowest: SW_NDI_BANDWIDTH_LOWEST
            case .audioOnly: SW_NDI_BANDWIDTH_AUDIO_ONLY
            }
        }
    }

    /// 可调参数。
    public struct Options: Sendable, Hashable {
        /// 带宽模式。
        public var bandwidth: Bandwidth = .highest
        /// 抖动缓冲深度（帧），0–2；pts 比"最快路径到达时刻"晚这么多帧。
        public var jitterBufferFrames: Int = 1
        /// 无信号门限：帧间隔 × N。
        public var noSignalMultiplier: Int = 3
        /// 我们在发送端那里显示的接收器名字；nil = SDK 默认。
        public var receiverName: String? = nil
        /// 允许 SDK 送单场（false = 交错源也按整帧给）。
        public var allowVideoFields = false
        /// 收音频（注入了环才有意义）。
        public var captureAudio = true
        /// 不 live 时多久查一次发现器。
        public var rediscoverInterval = HostDuration(milliseconds: 500)
        /// 像素池上限。
        public var poolMaxBuffers = 8
        /// 抖动缓冲的合法范围。
        public static let jitterBufferRange = 0...2
        public init() {}
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .ndi
    /// 源名（"机器名 (源名)"）。
    public let sourceName: String
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)?
    public let options: Options
    public var state: InputState { stateBox.value }
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }
    /// 最近一条错误 / 状态文案（UI 显示）。
    public var lastError: String? { errorBox.withLock { $0 } }
    /// 与其他输入同口径的计数。
    public var counters: InputCounters { countersBox.inputCounters(state: stateBox, surfaces: surfaces.count) }
    /// NDI 自己的计数。
    public var ndiCounters: NDIInputCounters { countersBox.snapshot(state: stateBox) }
    /// 最近一次我们主动连上的源（名字 + 地址）；SDK 自己按名连上的情况下为 nil。
    public var connectedSource: NDISource? { connectedBox.withLock { $0 } }
    /// 当前 tally（最近一次 setTally 的值）。
    public var tally: Tally { tallyBox.withLock { $0 } }
    /// 编译时是否有 SDK。
    public static var isSDKAvailable: Bool { SwitcherNDIInfo.isSDKAvailable }

    private let slot: any FrameSlot
    private let stateBox = NDIStateBox()
    private let countersBox = NDICountersBox()
    private let errorBox = Mutex<String?>(nil)
    private let tallyBox = Mutex<Tally>(Tally(program: false, preview: false))
    private let tallyDirty = Atomic<Bool>(false)
    private let timingBox: Mutex<ProgramTiming>
    private let running = Atomic<Bool>(false)
    private let threadBox = Mutex<InputThread?>(nil)
    private let surfaces = NDISurfaceTracker()
    private let connectedBox = Mutex<NDISource?>(nil)
    // 以下只在接收线程上碰
    private var recv: OpaquePointer?
    private var finder: NDIFinder?
    private let pool: NDIPixelBufferPool
    private var clockMap = NDIClockMap()
    private var sequence: UInt64 = 0
    private var frameInterval: HostDuration
    private var lastVideoArrival: HostTime?
    private var lastAudioArrival: HostTime?
    private var lastRediscover = HostTime.zero
    private var lastStatsRefresh = HostTime.zero
    private var resampler: NDILinearResampler?
    private var resampleScratch: [[Float]] = []
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private let planeTableCapacity = AudioFormat.maxChannels

    public init(number: Int, name: String, sourceName: String, timing: ProgramTiming, videoSlot: any FrameSlot,
                audioRing: (any AudioRing)? = nil, options: Options = Options()) {
        precondition(number >= 1, "输入编号从 1 起")
        precondition(Options.jitterBufferRange.contains(options.jitterBufferFrames), "抖动缓冲 0–2 帧")
        self.number = number
        self.name = name
        self.sourceName = sourceName
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        pool = NDIPixelBufferPool(maxBuffers: options.poolMaxBuffers)
        frameInterval = timing.frameDuration
        planeTable = .allocate(capacity: planeTableCapacity)
        planeTable.initialize(repeating: UnsafePointer(bitPattern: 8)!, count: planeTableCapacity)
    }

    /// 从 InputSource.ndi 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil,
                            options: Options = Options()) throws {
        guard case .ndi(let sourceName) = config.source else { throw NDIInputError.notAnNDISource(config.source.kind) }
        self.init(number: config.number, name: config.name, sourceName: sourceName, timing: timing, videoSlot: videoSlot,
                  audioRing: audioRing, options: options)
    }

    deinit {
        stop()
        planeTable.deallocate()
    }

    // MARK: 生命周期

    /// 不阻塞：接收线程自己初始化 SDK、找源、连接。SDK 不在：state = error 并抛错。
    public func start() throws {
        guard Self.isSDKAvailable else {
            setError(SwitcherNDIInfo.unavailableMessage)
            throw NDIInputError.sdkUnavailable
        }
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        errorBox.withLock { $0 = "等待 NDI 源 \(sourceName)…" }
        let t = InputThread(name: "switcher.ndi.\(number)", period: nil, qos: QOS_CLASS_USER_INTERACTIVE) { [self] thread in
            loop(thread)
        }
        threadBox.withLock { $0 = t }
        t.start()
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let t = threadBox.withLock { t -> InputThread? in
            let x = t
            t = nil
            return x
        }
        t?.stop()
        stateBox.set(.noSignal)
    }

    /// 我们的 PGM / PVW 状态回传给源（任何线程可调；接收线程下一轮发出）。
    public func setTally(_ tally: Tally) {
        tallyBox.withLock { $0 = tally }
        tallyDirty.store(true, ordering: .releasing)
    }

    private func setError(_ message: String) {
        errorBox.withLock { $0 = message }
        stateBox.set(.error(message: message))
    }

    // MARK: 接收线程

    private func loop(_ thread: InputThread) {
        guard sw_ndi_initialize() != 0 else {
            setError(NDIInputError.initializeFailed.description)
            return
        }
        finder = try? NDIFinder(showLocalSources: true)
        let r: OpaquePointer? = sourceName.withCString { s in
            options.receiverName.withOptionalCString { rn in
                sw_ndi_recv_create(s, nil, options.bandwidth.raw, options.allowVideoFields ? 1 : 0, rn)
            }
        }
        guard let r else {
            setError("\(NDIInputError.receiverCreateFailed.description)（源 \(sourceName)）")
            finder = nil
            return
        }
        recv = r
        defer {
            sw_ndi_recv_destroy(r)
            recv = nil
            finder = nil
        }
        sequence = 0
        clockMap = NDIClockMap()
        lastVideoArrival = nil
        lastAudioArrival = nil
        lastRediscover = .zero
        applyTally(r)
        var video = sw_ndi_video_frame()
        var audio = sw_ndi_audio_frame()
        while !thread.isStopRequested {
            if tallyDirty.exchange(false, ordering: .acquiringAndReleasing) { applyTally(r) }
            let waitMs = UInt32(min(max(frameInterval.milliseconds, 1), 100).rounded())
            let type = sw_ndi_recv_capture(r, &video, &audio, waitMs)
            let arrival = HostClock.now()
            let wall = NDIClockMap.wallClock100ns()
            switch type {
            case SW_NDI_FRAME_VIDEO:
                handleVideo(&video, arrival: arrival, wall: wall)
                sw_ndi_recv_free_video(r)
                lastVideoArrival = arrival
                goLive()
            case SW_NDI_FRAME_AUDIO:
                handleAudio(&audio, arrival: arrival, wall: wall)
                sw_ndi_recv_free_audio(r)
                lastAudioArrival = arrival
                if options.bandwidth == .audioOnly { goLive() }
            case SW_NDI_FRAME_SOURCE_CHANGE:
                countersBox.sourceChanges.add(1, ordering: .relaxed)
            case SW_NDI_FRAME_STATUS_CHANGE:
                countersBox.statusChanges.add(1, ordering: .relaxed)
            default:
                break
            }
            // 无信号
            let timeout = frameInterval * options.noSignalMultiplier
            let lastArrival = options.bandwidth == .audioOnly ? lastAudioArrival : lastVideoArrival
            if let last = lastArrival, stateBox.value == .live, arrival - last > timeout {
                errorBox.withLock { $0 = "NDI 源 \(sourceName) 没有新帧（超过 \(options.noSignalMultiplier) 个帧间隔）" }
                stateBox.set(.noSignal)
                lastVideoArrival = nil
                lastAudioArrival = nil
            }
            // 不 live 时盯发现器：源出现 / 换地址就重连
            if stateBox.value != .live, arrival - lastRediscover > options.rediscoverInterval {
                lastRediscover = arrival
                rediscover(r)
            }
            if arrival - lastStatsRefresh > HostDuration(milliseconds: 1000) {
                lastStatsRefresh = arrival
                refreshSDKStats(r)
            }
        }
        stateBox.set(.noSignal)
    }

    private func goLive() {
        if stateBox.value != .live {
            errorBox.withLock { $0 = nil }
            stateBox.set(.live)
        }
    }

    private func applyTally(_ r: OpaquePointer) {
        let t = tallyBox.withLock { $0 }
        _ = sw_ndi_recv_set_tally(r, t.program ? 1 : 0, t.preview ? 1 : 0)
    }

    private func refreshSDKStats(_ r: OpaquePointer) {
        var s = sw_ndi_recv_stats()
        sw_ndi_recv_get_stats(r, &s)
        countersBox.sdkVideoDropped.store(s.video_dropped, ordering: .relaxed)
        countersBox.sdkQueueVideo.store(Int(s.queue_video), ordering: .relaxed)
        countersBox.connections.store(Int(sw_ndi_recv_connections(r)), ordering: .relaxed)
        countersBox.jitter.withLock { $0 = (clockMap.meanJitterMs, clockMap.maxJitterMs, clockMap.resets) }
    }

    /// 源不在 / 换了地址：查发现器，必要时 recv_connect。
    private func rediscover(_ r: OpaquePointer) {
        countersBox.connections.store(Int(sw_ndi_recv_connections(r)), ordering: .relaxed)
        guard let finder else { return }
        guard let src = finder.source(named: sourceName) else {
            if connectedBox.withLock({ $0 }) == nil {
                errorBox.withLock { $0 = "网络上找不到 NDI 源 \(sourceName)（发送端没开、不在同一网段，或名字不对）" }
            }
            return
        }
        let previous = connectedBox.withLock { $0 }
        guard previous == nil || previous?.url != src.url else { return }
        src.name.withCString { n in
            src.url.withOptionalCString { u in sw_ndi_recv_connect(r, n, u) }
        }
        if previous != nil { countersBox.reconnects.add(1, ordering: .relaxed) }
        connectedBox.withLock { $0 = src }
        countersBox.connectedURL.withLock { $0 = src.url ?? "" }
        errorBox.withLock { $0 = "正在连接 NDI 源 \(sourceName)（\(src.url ?? "地址未知")）…" }
        tallyDirty.store(true, ordering: .releasing)
    }

    /// 一帧：拷进池缓冲、算 pts、push。
    private func handleVideo(_ v: inout sw_ndi_video_frame, arrival: HostTime, wall: Int64) {
        countersBox.framesReceived.add(1, ordering: .relaxed)
        let cvFormat: OSType
        let color: ColorInfo
        switch v.fourcc {
        case SW_NDI_FOURCC_UYVY, SW_NDI_FOURCC_UYVA:
            cvFormat = kCVPixelFormatType_422YpCbCr8
            color = ColorInfo(primaries: .bt709, transfer: .bt709, matrix: v.height >= 720 ? .bt709 : .bt601, range: .limited)
        case SW_NDI_FOURCC_BGRA, SW_NDI_FOURCC_BGRX:
            cvFormat = kCVPixelFormatType_32BGRA
            color = .sRGBFull
        default:
            countersBox.framesUnsupported.add(1, ordering: .relaxed)
            return
        }
        if v.frame_rate_n > 0, v.frame_rate_d > 0 {
            frameInterval = HostDuration(nanoseconds: 1_000_000_000 * Int64(v.frame_rate_d) / Int64(v.frame_rate_n))
        }
        guard v.width > 0, v.height > 0, let pb = pool.makeBuffer(width: Int(v.width), height: Int(v.height), format: cvFormat) else {
            countersBox.framesPoolExhausted.add(1, ordering: .relaxed)
            return
        }
        guard sw_ndi_copy_video(&v, pb) == 0 else {
            countersBox.framesUnsupported.add(1, ordering: .relaxed)
            return
        }
        let jitter = clockMap.observe(senderTimestamp100ns: v.timestamp, arrivalHost: arrival, arrivalWall100ns: wall)
        let pts = arrival - jitter + frameInterval * options.jitterBufferFrames
        sequence += 1
        surfaces.note(pb)
        countersBox.lastFormat.withLock {
            $0 = "\(v.width)x\(v.height) \(cvFormat == kCVPixelFormatType_32BGRA ? "BGRA" : "UYVY") \(v.frame_rate_n)/\(v.frame_rate_d) \(v.progressive != 0 ? "p" : "i")"
        }
        let ingress = HostClock.now()
        slot.push(Frame(pixelBuffer: pb, pts: pts, duration: frameInterval, color: color, inputNumber: number, sequence: sequence, ingressTime: ingress))
        countersBox.framesPushed.add(1, ordering: .relaxed)
        countersBox.noteArrivalMinusPts(ingress - pts)
    }

    /// 一块音频：声道映射（+ 重采样）→ 环。
    private func handleAudio(_ a: inout sw_ndi_audio_frame, arrival: HostTime, wall: Int64) {
        countersBox.audioFramesReceived.add(1, ordering: .relaxed)
        guard options.captureAudio, let ring = audioRing, let data = a.data, a.channels > 0, a.samples > 0, a.sample_rate > 0 else { return }
        let channels = min(ring.channelCount, planeTableCapacity)
        let srcChannels = Int(a.channels)
        let stride = Int(a.channel_stride)
        let jitter = clockMap.observe(senderTimestamp100ns: a.timestamp, arrivalHost: arrival, arrivalWall100ns: wall)
        let blockDuration = HostDuration(nanoseconds: 1_000_000_000 * Int64(a.samples) / Int64(a.sample_rate))
        let hostTime = arrival - jitter - blockDuration + frameInterval * options.jitterBufferFrames
        // 源声道 → 环声道：多的丢、单声道复制、少的复制最后一路
        var srcPlanes: [UnsafePointer<Float>] = []
        srcPlanes.reserveCapacity(channels)
        for c in 0..<channels {
            let sc = srcChannels == 1 ? 0 : min(c, srcChannels - 1)
            srcPlanes.append(UnsafeRawPointer(data + sc * stride).assumingMemoryBound(to: Float.self))
        }
        let written: Int
        let requested: Int
        if Int(a.sample_rate) == AudioFormat.sampleRate {
            for c in 0..<channels { planeTable[c] = srcPlanes[c] }
            requested = Int(a.samples)
            written = ring.write(planes: UnsafePointer(planeTable), frameCount: requested, hostTime: hostTime)
        } else {
            if resampler == nil || resampler?.sourceRate != Int(a.sample_rate) {
                resampler = NDILinearResampler(sourceRate: Int(a.sample_rate), targetRate: AudioFormat.sampleRate, channels: channels)
                resampleScratch = Array(repeating: [], count: channels)
            }
            for c in 0..<channels { resampleScratch[c].removeAll(keepingCapacity: true) }
            requested = resampler!.process(input: srcPlanes, frames: Int(a.samples), into: &resampleScratch)
            countersBox.audioBlocksResampled.add(1, ordering: .relaxed)
            guard requested > 0 else { return }
            written = withScratchPlanes(channels) { table in ring.write(planes: table, frameCount: requested, hostTime: hostTime) }
        }
        countersBox.audioBlocksWritten.add(1, ordering: .relaxed)
        countersBox.audioFramesWritten.add(UInt64(written), ordering: .relaxed)
        if written < requested { countersBox.audioFramesRejected.add(UInt64(requested - written), ordering: .relaxed) }
    }

    private func withScratchPlanes(_ channels: Int, _ body: (UnsafePointer<UnsafePointer<Float>>) -> Int) -> Int {
        func fill(_ c: Int) -> Int {
            if c == channels { return body(UnsafePointer(planeTable)) }
            return resampleScratch[c].withUnsafeBufferPointer { p in
                planeTable[c] = p.baseAddress ?? UnsafePointer(bitPattern: 8)!
                return fill(c + 1)
            }
        }
        return fill(0)
    }
}
