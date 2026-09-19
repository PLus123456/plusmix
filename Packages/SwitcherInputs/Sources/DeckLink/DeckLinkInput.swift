import CSwitcherDeckLink
import CoreVideo
import Dispatch
import Foundation
import Synchronization
import SwitcherContracts
import SwitcherInputs

/// DeckLink 输入的错误。
public enum DeckLinkInputError: Error, Equatable, CustomStringConvertible {
    /// 编译时没有 DeckLink SDK。
    case sdkUnavailable
    case notADeckLinkSource(InputKind)

    public var description: String {
        switch self {
        case .sdkUnavailable: SwitcherDeckLinkInfo.unavailableMessage
        case .notADeckLinkSource(let k): "不是 DeckLink 来源：\(k)"
        }
    }
}

/// DeckLink SDI / HDMI 输入（设计方案 §6 DeckLink 行；W3-A 交付 1）。
///
/// - 会话由 C++ 桥接（CSwitcherDeckLink）管：格式自动检测、帧拷贝、时间戳校准、音频转换都在驱动线程的回调里做完，
///   这里只把结果放进帧槽 / 环（回调线程 = 这路输入的线程；只有它 push / write）。
/// - 状态：起流后 noSignal，直到第一帧带信号 → live；帧带 bmdFrameHasNoInputSource → noSignal（帧槽保留最后一帧）；
///   看门狗兜底：连续 N 个帧间隔一次回调都没有（驱动停了 / 卡被拔） → noSignal 并检查设备是否还在。
/// - 热插拔：IDeckLinkDiscovery 通知 + 每秒轮询兜底；设备被拔 → 关会话、noSignal、文案；回来（同一持久 ID）→ 自动重开，
///   编号和 InputSettings 不变（不在这个对象里）。设备一开始不在：noSignal，等它来。驱动没装：noSignal + 指到 Desktop Video 的文案。
/// - 时间戳：pts = 帧的硬件参考时间经一阶滤波校准到 host time（方法见 sw_decklink.h 校准器一节）；ingressTime = push 前一刻。
/// - 音频：内嵌音频（options.audioChannels 路，int16 / int32）由桥接层转成 float32 平面，按环的声道数映射后写环，
///   块首 host time 由包的流时间换到硬件钟再校准。
public final class DeckLinkInput: Input, @unchecked Sendable {
    /// 可调参数。
    public struct Options: Sendable, Hashable {
        /// 输入接口；nil = 不改卡上的当前设置。进契约要走提案 008。
        public var connection: DeckLinkConnection? = nil
        /// 内嵌音频声道数（2–16）；0 = 不开。环的声道数少于它时多的丢。
        public var audioChannels = 2
        /// 音频样本类型：16 或 32（bmdAudioSampleType）。
        public var audioSampleType = 32
        /// 无信号看门狗门限：帧间隔 × N。
        public var noSignalMultiplier = 3
        /// 设备轮询间隔（热插拔兜底）。
        public var pollInterval = HostDuration(milliseconds: 1000)
        /// 校准一阶滤波 α = 1 / 2^shift。
        public var calibrationShift = 5
        /// 像素池上限。
        public var poolMaxBuffers = 8
        /// 起始显示模式（BMDDisplayMode 四字码）；0 = 设备列表第一个（格式检测会立刻改过来）。
        public var initialDisplayMode: UInt32 = 0
        public init() {}
    }

    /// DeckLink 自己的计数（InputCounters 之外；值快照）。
    public struct DeckLinkCounters: Hashable, Sendable {
        public var framesReceived: UInt64 = 0
        public var framesDelivered: UInt64 = 0
        public var framesNoSource: UInt64 = 0
        public var framesDroppedPool: UInt64 = 0
        public var framesDroppedFormat: UInt64 = 0
        public var framesPushed: UInt64 = 0
        public var audioPackets: UInt64 = 0
        public var audioBlocksWritten: UInt64 = 0
        public var audioFramesWritten: UInt64 = 0
        public var audioFramesRejected: UInt64 = 0
        public var formatChanges: UInt64 = 0
        public var reopenFailures: UInt64 = 0
        /// 校准：当前偏移（host − 硬件钟，ns）、残差最大绝对值 / RMS（ns）、样本数、设备有没有硬件参考钟。
        public var calibrationOffsetNs: Int64 = 0
        public var residualMaxAbsNs: Int64 = 0
        public var residualRmsNs: Double = 0
        public var residualSamples: UInt64 = 0
        public var hasHardwareClock = false
        /// -1 未知 / 0 无 / 1 有。
        public var signalPresent = -1
        public var currentFormat: String = ""
        /// 会话（重）建次数、设备拔 / 插事件数、看门狗超时次数。
        public var rebuilds: UInt64 = 0
        public var deviceRemovals: UInt64 = 0
        public var deviceArrivals: UInt64 = 0
        public var watchdogTimeouts: UInt64 = 0
        /// d = ingress − pts（ms）。
        public var arrivalMinusPtsMeanMs: Double = 0
        public var arrivalMinusPtsMaxMs: Double = 0
        public var arrivalMinusPtsMinMs: Double = 0
        public init() {}
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .decklink
    /// 设备持久标识（`DeckLinkDeviceInfo.persistentID`）；空 = 第一台有输入的。
    public let deviceID: String
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)?
    public let options: Options
    public var state: InputState { stateBox.value }
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }
    public var lastError: String? { errorBox.withLock { $0 } }
    /// 找到的设备（会话建过后有值）。
    public var device: DeckLinkDeviceInfo? { deviceBox.withLock { $0 } }
    /// 当前检测到的格式。
    public var currentFormat: DeckLinkVideoFormat? { formatBox.withLock { $0 } }
    public var counters: InputCounters { makeInputCounters() }
    public var deckLinkCounters: DeckLinkCounters { makeCounters() }
    public static var isSDKAvailable: Bool { SwitcherDeckLinkInfo.isSDKAvailable }

    private let slot: any FrameSlot
    private let stateBox = DeckLinkStateBox()
    private let errorBox = Mutex<String?>(nil)
    private let timingBox: Mutex<ProgramTiming>
    private let deviceBox = Mutex<DeckLinkDeviceInfo?>(nil)
    private let formatBox = Mutex<DeckLinkVideoFormat?>(nil)
    private let running = Atomic<Bool>(false)
    private let sessionQueue: DispatchQueue
    private let fakeHandle: OpaquePointer?
    // 计数（回调线程写、任何线程读）
    private let framesPushed = Atomic<UInt64>(0)
    private let audioBlocksWritten = Atomic<UInt64>(0)
    private let audioFramesWritten = Atomic<UInt64>(0)
    private let audioFramesRejected = Atomic<UInt64>(0)
    private let rebuilds = Atomic<UInt64>(0)
    private let deviceRemovals = Atomic<UInt64>(0)
    private let deviceArrivals = Atomic<UInt64>(0)
    private let watchdogTimeouts = Atomic<UInt64>(0)
    private let dCount = Atomic<UInt64>(0)
    private let dSum = Atomic<Int64>(0)
    private let dMax = Atomic<Int64>(Int64.min)
    private let dMin = Atomic<Int64>(Int64.max)
    private let surfaces = DeckLinkSurfaceTracker()
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private let planeTableCapacity = AudioFormat.maxChannels
    // 以下只在 sessionQueue 上碰
    private var session: OpaquePointer?
    private var hotplugToken: Int32 = 0
    private var pollTimer: DispatchSourceTimer?
    private var watchdog: DeckLinkWatchdog?

    public convenience init(number: Int, name: String, deviceID: String, timing: ProgramTiming, videoSlot: any FrameSlot,
                            audioRing: (any AudioRing)? = nil, options: Options = Options()) {
        self.init(number: number, name: name, deviceID: deviceID, timing: timing, videoSlot: videoSlot, audioRing: audioRing,
                  options: options, fake: nil)
    }

    /// 测试：对着 Fake IDeckLinkInput（`sw_decklink_fake_create`）建输入，不经过设备枚举 / 驱动。
    init(number: Int, name: String, deviceID: String, timing: ProgramTiming, videoSlot: any FrameSlot,
         audioRing: (any AudioRing)?, options: Options, fake: OpaquePointer?) {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name
        self.deviceID = deviceID
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        fakeHandle = fake
        sessionQueue = DispatchQueue(label: "switcher.decklink.session.\(number)", qos: .userInitiated)
        planeTable = .allocate(capacity: planeTableCapacity)
        planeTable.initialize(repeating: UnsafePointer(bitPattern: 8)!, count: planeTableCapacity)
    }

    /// 从 InputSource.decklink 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil,
                            options: Options = Options()) throws {
        guard case .decklink(let id) = config.source else { throw DeckLinkInputError.notADeckLinkSource(config.source.kind) }
        self.init(number: config.number, name: config.name, deviceID: id, timing: timing, videoSlot: videoSlot, audioRing: audioRing, options: options)
    }

    deinit {
        stop()
        planeTable.deallocate()
    }

    // MARK: 生命周期

    /// 不阻塞：设备查找、会话建立在 sessionQueue 上做；结果看 `state` / `lastError`。SDK 不在：state = error 并抛错。
    public func start() throws {
        guard Self.isSDKAvailable else {
            setError(SwitcherDeckLinkInfo.unavailableMessage)
            throw DeckLinkInputError.sdkUnavailable
        }
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.async { [self] in
            if fakeHandle == nil { subscribeHotplug() }
            attempt()
            startPolling()
        }
    }

    /// 停：关会话、退订热插拔。没 start 过（或 start 因 SDK 不在抛了错）也把状态复位成 noSignal（契约：stop 后 noSignal）。
    public func stop() {
        if running.exchange(false, ordering: .acquiringAndReleasing) {
            sessionQueue.sync { [self] in
                pollTimer?.cancel()
                pollTimer = nil
                if hotplugToken != 0 {
                    sw_decklink_hotplug_unsubscribe(hotplugToken)
                    hotplugToken = 0
                }
                teardown()
            }
        }
        errorBox.withLock { $0 = nil }
        stateBox.set(.noSignal)
    }

    /// 桥接层的会话统计（没会话时全 0）。
    public var sessionStats: sw_decklink_session_stats {
        sessionQueue.sync {
            var s = sw_decklink_session_stats()
            sw_decklink_session_get_stats(session, &s)
            return s
        }
    }

    private func setError(_ message: String) {
        errorBox.withLock { $0 = message }
        stateBox.set(.error(message: message))
    }

    // MARK: 建 / 拆会话（sessionQueue）

    private func attempt() {
        guard running.load(ordering: .acquiring), session == nil else { return }
        var cfg = sw_decklink_session_config()
        cfg.connection = options.connection?.rawValue ?? 0
        cfg.initial_display_mode = options.initialDisplayMode
        cfg.audio_channels = audioRing == nil ? 0 : Int32(min(max(options.audioChannels, 0), 16))
        cfg.audio_sample_type = Int32(options.audioSampleType == 16 ? 16 : 32)
        cfg.calibration_shift = Int32(options.calibrationShift)
        cfg.max_pool_buffers = Int32(options.poolMaxBuffers)
        var callbacks = makeCallbacks()
        var err = [CChar](repeating: 0, count: 256)
        var persistentID = deviceID
        if fakeHandle == nil {
            guard SwitcherDeckLinkInfo.isDriverPresent else {
                errorBox.withLock { $0 = SwitcherDeckLinkInfo.driverMissingMessage }
                stateBox.set(.noSignal)
                return
            }
            let devices = DeckLinkDevices.list()
            guard let dev = deviceID.isEmpty ? devices.first(where: { $0.hasInput }) : devices.first(where: { $0.persistentID == deviceID }) else {
                let names = devices.map { "\($0.displayName)[\($0.persistentID)]" }.joined(separator: "、")
                errorBox.withLock { $0 = "找不到 DeckLink 设备 \(deviceID.isEmpty ? "(任意)" : deviceID)（已连接：\(names.isEmpty ? "无" : names)），等待它连接" }
                stateBox.set(.noSignal)
                return
            }
            deviceBox.withLock { $0 = dev }
            persistentID = dev.persistentID
        }
        let s: OpaquePointer? = persistentID.withCString { idPtr in
            cfg.persistent_id = idPtr
            if let fakeHandle {
                return sw_decklink_session_open_fake(fakeHandle, &cfg, &callbacks, &err, err.count)
            }
            return sw_decklink_session_open(&cfg, &callbacks, &err, err.count)
        }
        guard let s else {
            errorBox.withLock { $0 = "打开 DeckLink 会话失败：\(String(cString: err))" }
            stateBox.set(.noSignal)
            return
        }
        guard sw_decklink_session_start(s, &err, err.count) == 0 else {
            sw_decklink_session_close(s)
            setError("DeckLink 起流失败：\(String(cString: err))")
            return
        }
        session = s
        rebuilds.add(1, ordering: .relaxed)
        var stats = sw_decklink_session_stats()
        sw_decklink_session_get_stats(s, &stats)
        let format = DeckLinkVideoFormat(stats.current_format)
        formatBox.withLock { $0 = format }
        errorBox.withLock { $0 = "DeckLink \(device?.displayName ?? "假设备") 已起流，等待信号" }
        stateBox.set(.noSignal)
        startWatchdog(interval: format.frameInterval ?? timing.frameDuration)
    }

    private func teardown() {
        watchdog?.stop()
        watchdog = nil
        if let s = session {
            sw_decklink_session_close(s)
            session = nil
        }
    }

    private func startWatchdog(interval: HostDuration) {
        watchdog?.stop()
        let wd = DeckLinkWatchdog(expectedInterval: interval, multiplier: options.noSignalMultiplier, queue: sessionQueue) { [weak self] in
            self?.onWatchdogTimeout()
        }
        watchdog = wd
        wd.start()
    }

    /// 连续 N 个帧间隔一次回调都没有：noSignal；设备不在列表里了就拆会话等它回来。
    private func onWatchdogTimeout() {
        guard running.load(ordering: .acquiring), session != nil else { return }
        watchdogTimeouts.add(1, ordering: .relaxed)
        errorBox.withLock { $0 = "DeckLink \(device?.displayName ?? "假设备") 没有回调（超过 \(options.noSignalMultiplier) 个帧间隔）：驱动停了或设备被拔" }
        stateBox.set(.noSignal)
        if fakeHandle == nil, let dev = device, !DeckLinkDevices.list().contains(where: { $0.persistentID == dev.persistentID }) {
            deviceRemovals.add(1, ordering: .relaxed)
            teardown()
        }
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        let ns = Int(max(options.pollInterval.nanoseconds, 100_000_000))
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, running.load(ordering: .acquiring) else { return }
            if session == nil { attempt() }
        }
        pollTimer = t
        t.resume()
    }

    // MARK: 热插拔（驱动线程 → sessionQueue）

    private func subscribeHotplug() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        hotplugToken = sw_decklink_hotplug_subscribe({ ctx, info, arrived in
            guard let ctx, let info else { return }
            let me = Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue()
            me.onHotplug(DeckLinkDeviceInfo(info.pointee), arrived: arrived != 0)
        }, ctx)
    }

    private func onHotplug(_ info: DeckLinkDeviceInfo, arrived: Bool) {
        sessionQueue.async { [self] in
            guard running.load(ordering: .acquiring) else { return }
            let mine = deviceID.isEmpty ? info.hasInput : info.persistentID == deviceID
            guard mine else { return }
            if arrived {
                deviceArrivals.add(1, ordering: .relaxed)
                if session == nil { attempt() }
            } else if session != nil, device?.persistentID == info.persistentID || deviceID.isEmpty {
                deviceRemovals.add(1, ordering: .relaxed)
                teardown()
                errorBox.withLock { $0 = "DeckLink \(info.displayName) 已断开，等待重新连接" }
                stateBox.set(.noSignal)
            }
        }
    }

    // MARK: 回调（驱动线程 = 这路输入的线程）

    private func makeCallbacks() -> sw_decklink_callbacks {
        var cb = sw_decklink_callbacks()
        cb.context = Unmanaged.passUnretained(self).toOpaque()
        cb.format_changed = { ctx, fmt in
            guard let ctx, let fmt else { return }
            Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue().onFormatChanged(fmt.pointee)
        }
        cb.video_frame = { ctx, pb, info in
            guard let ctx, let pb, let info else { return }
            Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue().onVideo(pb, info.pointee)
        }
        cb.audio_packet = { ctx, planes, info in
            guard let ctx, let planes, let info else { return }
            Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue().onAudio(planes, info.pointee)
        }
        cb.signal_changed = { ctx, present in
            guard let ctx else { return }
            Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue().onSignal(present != 0)
        }
        cb.error = { ctx, msg in
            guard let ctx, let msg else { return }
            Unmanaged<DeckLinkInput>.fromOpaque(ctx).takeUnretainedValue().errorBox.withLock { $0 = String(cString: msg) }
        }
        return cb
    }

    private func onFormatChanged(_ c: sw_decklink_video_format) {
        let f = DeckLinkVideoFormat(c)
        formatBox.withLock { $0 = f }
        sessionQueue.async { [self] in
            guard running.load(ordering: .acquiring), session != nil else { return }
            startWatchdog(interval: f.frameInterval ?? timing.frameDuration)
        }
    }

    private func onSignal(_ present: Bool) {
        if present {
            errorBox.withLock { $0 = nil }
            stateBox.set(.live)
        } else {
            errorBox.withLock { $0 = "DeckLink \(device?.displayName ?? "假设备") 无信号：输入没有信号源（线没接、源没开或格式不支持）" }
            stateBox.set(.noSignal)
        }
    }

    private func onVideo(_ pb: CVPixelBuffer, _ info: sw_decklink_frame_info) {
        watchdog?.noteCallback()
        // 能到这里的帧都带信号。看门狗超时把状态置成 noSignal 后桥接层不会再发 signal_changed（它眼里信号没断过），所以这里也拉回 live
        if stateBox.value != .live {
            errorBox.withLock { $0 = nil }
            stateBox.set(.live)
        }
        let format = PixelFormat(cvPixelFormatType: OSType(info.pixel_format)) ?? .uyvy
        let color: ColorInfo = format == .bgra
            ? ColorInfo(primaries: .bt709, transfer: .bt709, matrix: .bt709, range: .full)
            : ColorInfo(primaries: .bt709, transfer: .bt709, matrix: info.height >= 720 ? .bt709 : .bt601, range: .limited)
        let pts = HostTime(ticks: info.pts_host)
        surfaces.note(pb)
        let ingress = HostClock.now()
        slot.push(Frame(pixelBuffer: pb, pts: pts, duration: HostDuration(ticks: info.duration_host), color: color,
                        inputNumber: number, sequence: info.sequence, ingressTime: ingress))
        framesPushed.add(1, ordering: .relaxed)
        let d = (ingress - pts).nanoseconds
        dCount.add(1, ordering: .relaxed)
        dSum.add(d, ordering: .relaxed)
        _ = dMax.max(d, ordering: .relaxed)
        _ = dMin.min(d, ordering: .relaxed)
    }

    private func onAudio(_ planes: UnsafePointer<UnsafePointer<Float>?>, _ info: sw_decklink_audio_info) {
        guard let ring = audioRing, info.frame_count > 0, info.channel_count > 0 else { return }
        let channels = min(ring.channelCount, planeTableCapacity)
        let src = Int(info.channel_count)
        for c in 0..<channels {
            let sc = src == 1 ? 0 : min(c, src - 1)
            guard let p = planes[sc] else { return }
            planeTable[c] = p
        }
        let n = ring.write(planes: UnsafePointer(planeTable), frameCount: Int(info.frame_count), hostTime: HostTime(ticks: info.host_time))
        audioBlocksWritten.add(1, ordering: .relaxed)
        audioFramesWritten.add(UInt64(n), ordering: .relaxed)
        if n < Int(info.frame_count) { audioFramesRejected.add(UInt64(Int(info.frame_count) - n), ordering: .relaxed) }
    }

    // MARK: 计数

    private func makeCounters() -> DeckLinkCounters {
        var c = DeckLinkCounters()
        let s = sessionStats
        c.framesReceived = s.frames_received
        c.framesDelivered = s.frames_delivered
        c.framesNoSource = s.frames_no_source
        c.framesDroppedPool = s.frames_dropped_pool
        c.framesDroppedFormat = s.frames_dropped_format
        c.audioPackets = s.audio_packets
        c.formatChanges = s.format_changes
        c.reopenFailures = s.reopen_failures
        c.calibrationOffsetNs = s.calibration_offset_ns
        c.residualMaxAbsNs = s.residual_max_abs_ns
        c.residualRmsNs = s.residual_rms_ns
        c.residualSamples = s.residual_samples
        c.hasHardwareClock = s.has_hardware_clock != 0
        c.signalPresent = Int(s.signal_present)
        c.currentFormat = currentFormat?.description ?? ""
        c.framesPushed = framesPushed.load(ordering: .relaxed)
        c.audioBlocksWritten = audioBlocksWritten.load(ordering: .relaxed)
        c.audioFramesWritten = audioFramesWritten.load(ordering: .relaxed)
        c.audioFramesRejected = audioFramesRejected.load(ordering: .relaxed)
        c.rebuilds = rebuilds.load(ordering: .relaxed)
        c.deviceRemovals = deviceRemovals.load(ordering: .relaxed)
        c.deviceArrivals = deviceArrivals.load(ordering: .relaxed)
        c.watchdogTimeouts = watchdogTimeouts.load(ordering: .relaxed)
        let n = dCount.load(ordering: .relaxed)
        if n > 0 {
            c.arrivalMinusPtsMeanMs = Double(dSum.load(ordering: .relaxed)) / Double(n) / 1e6
            c.arrivalMinusPtsMaxMs = Double(dMax.load(ordering: .relaxed)) / 1e6
            c.arrivalMinusPtsMinMs = Double(dMin.load(ordering: .relaxed)) / 1e6
        }
        return c
    }

    private func makeInputCounters() -> InputCounters {
        var c = InputCounters()
        let s = sessionStats
        c.framesReceived = s.frames_received
        c.framesPushed = framesPushed.load(ordering: .relaxed)
        c.framesRejected = s.frames_dropped_pool + s.frames_dropped_format
        c.audioBlocksWritten = audioBlocksWritten.load(ordering: .relaxed)
        c.audioFramesWritten = audioFramesWritten.load(ordering: .relaxed)
        c.audioFramesRejected = audioFramesRejected.load(ordering: .relaxed)
        c.stateTransitions = stateBox.transitions.load(ordering: .relaxed)
        c.liveTransitions = stateBox.liveCount.load(ordering: .relaxed)
        c.noSignalTransitions = stateBox.noSignalCount.load(ordering: .relaxed)
        c.errorTransitions = stateBox.errorCount.load(ordering: .relaxed)
        c.rebuilds = rebuilds.load(ordering: .relaxed)
        c.distinctSurfaces = surfaces.count
        return c
    }
}

// MARK: - 支持件

/// `Input.state` 的存放处 + 转换计数（与 W2-A 的 InputStateBox 同构；那份是包内 internal）。
final class DeckLinkStateBox: @unchecked Sendable {
    private let box = Mutex<InputState>(.noSignal)
    let transitions = Atomic<UInt64>(0)
    let liveCount = Atomic<UInt64>(0)
    let noSignalCount = Atomic<UInt64>(0)
    let errorCount = Atomic<UInt64>(0)
    var value: InputState { box.withLock { $0 } }
    @discardableResult
    func set(_ new: InputState) -> Bool {
        let changed = box.withLock { old -> Bool in
            if old == new { return false }
            old = new
            return true
        }
        if changed {
            transitions.add(1, ordering: .relaxed)
            switch new {
            case .live: liveCount.add(1, ordering: .relaxed)
            case .noSignal: noSignalCount.add(1, ordering: .relaxed)
            case .error: errorCount.add(1, ordering: .relaxed)
            }
        }
        return changed
    }
}

/// 回调看门狗：期望帧间隔 × N 内一次回调都没有 → onTimeout（在 queue 上），之后每个周期再报一次直到有回调。
final class DeckLinkWatchdog: @unchecked Sendable {
    let expectedInterval: HostDuration
    let multiplier: Int
    private let queue: DispatchQueue
    private let onTimeout: @Sendable () -> Void
    private let lastCallback = Atomic<UInt64>(0)
    private var timer: DispatchSourceTimer?
    private var startedAt = HostTime.zero

    init(expectedInterval: HostDuration, multiplier: Int, queue: DispatchQueue, onTimeout: @escaping @Sendable () -> Void) {
        self.expectedInterval = HostDuration(ticks: max(expectedInterval.ticks, HostDuration(milliseconds: 1).ticks))
        self.multiplier = max(multiplier, 1)
        self.queue = queue
        self.onTimeout = onTimeout
    }

    @inline(__always)
    func noteCallback() { lastCallback.store(HostClock.now().ticks, ordering: .relaxed) }

    func start() {
        stop()
        startedAt = HostClock.now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ns = Int(max(expectedInterval.nanoseconds, 1_000_000))
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .nanoseconds(ns / 4))
        t.setEventHandler { [weak self] in self?.check() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        let last = lastCallback.load(ordering: .relaxed)
        let reference = last == 0 ? startedAt : HostTime(ticks: last)
        if HostClock.now() - reference > expectedInterval * multiplier { onTimeout() }
    }
}

/// 见过的不同 IOSurface 数。
final class DeckLinkSurfaceTracker: @unchecked Sendable {
    private var ids: [UInt32] = []
    private let total = Atomic<UInt64>(0)
    func note(_ pb: CVPixelBuffer) {
        guard let s = CVPixelBufferGetIOSurface(pb) else { return }
        let id = IOSurfaceGetID(s.takeUnretainedValue())
        if ids.contains(id) { return }
        if ids.count < 64 { ids.append(id) }
        total.add(1, ordering: .relaxed)
    }
    var count: UInt64 { total.load(ordering: .relaxed) }
}
