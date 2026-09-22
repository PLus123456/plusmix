@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization
import SwitcherContracts

/// 纯音频设备输入（`InputSource.audio(deviceUID:)`、`InputKind.audio`；W2-A2）。
///
/// 典型用途：USB 声卡 / 小调音台上的主持人话筒，没有画面的音频源。
///
/// - 取样：Core Audio 的 `AudioDeviceIOProcID`（HAL 的 IO 回调，**系统的音频实时线程**）。回调里只做
///   "拿设备给的 `AudioTimeStamp.mHostTime` 打戳 + 按声道映射把样本拷进预分配的交接区"（`AudioCaptureFIFO`）：
///   无锁、无分配、无日志、无系统调用、不碰任何 Swift 对象（设计方案 §3.5、铁律 3）。
///   为什么不用 AUHAL（`kAudioUnitSubType_HALOutput` 的输入侧）：探针实测（reports/w2-inputs-2.md §1.1）在 2 声道设备上
///   `AudioUnitRender` 每 3 秒在回调线程上分配 58–59 次，IOProc 这条路 0 次；IOProc 还少一次拷贝。
/// - 写环：专用泵线程（`InputThread`，普通线程，可以锁 / 分配）把交接区里的块逐块写进注入的 `AudioRing`，
///   块边界与设备块一一对应，`hostTime` 就是回调给的设备侧时刻（铁律 5）。
/// - 采样率：设备不是 48 kHz 时先试着把它的标称采样率设成 48 kHz（`Options.forceSampleRate48k`，停的时候还原）；
///   设备做不到就在泵线程上用 `AudioRateConverter` 转（**不在回调里转**）；两样都不让做就 `noSignal` + 文案。
/// - 没有画面：`videoSlot` 恒为 nil，不推帧；`state` 只由音频决定——有块 = live；设备不在 / 被拔 = `noSignal` + 文案
///   （会自己好，G4 报告 §8 第 4 条的口径）；麦克风权限被拒 = `error`（不会自己好）。
/// - 线程：设备管理在 `sessionQueue`（串行），采集在 HAL 的 IO 线程，写环在泵线程。
public final class AudioDeviceInput: Input, HotplugMonitorable, @unchecked Sendable {
    /// 可调参数（包内选项，不进契约）。
    public struct Options: Sendable, Hashable {
        /// 无信号门限：期望块间隔 × N（期望块间隔取 max(块时长, 33 ms)，所以门限至少 100 ms）。
        public var noSignalMultiplier = 3
        /// 设备 / 权限轮询间隔。
        public var pollInterval = HostDuration(milliseconds: 1000)
        /// 设备不是 48 kHz 时，先试着把它的标称采样率设成 48 kHz（停的时候还原成原值）。
        public var forceSampleRate48k = true
        /// 上一条没成时，在泵线程上用 AudioConverter 转成 48 kHz；关掉的话直接 noSignal + "设备不支持 48 kHz"。
        public var convertSampleRate = true
        /// 目标声道取设备的哪几路（设备声道下标，长度应 = 环的声道数）。nil = 取前几路；
        /// 设备是单声道就复制到所有声道，设备声道比环少就复制最后一路（与 `LPCM` 同一口径）。
        public var channelMap: [Int]?
        /// 交接区槽数（2 的幂）。16 槽 × 一块 ≈ 170 ms，够泵线程被调度晚的余量。
        public var slotCount = 16
        /// 泵线程的唤醒周期 = 块时长 / 4，钳在这个范围里。
        public var pumpPeriodRange = HostDuration(milliseconds: 1)...HostDuration(milliseconds: 5)
        /// 逐块留痕的条数（0 = 不留）。测试 / 探针要自己算 d 的分布时打开；预分配，泵线程写。
        public var traceCapacity = 0
        public init() {}
    }

    /// 逐块留痕的一条（`Options.traceCapacity > 0` 时才有）。
    public struct BlockTraceEntry: Hashable, Sendable {
        /// 块首帧的设备侧时刻（写进环的就是它）。
        public var hostTime: HostTime
        /// IOProc 回调到达时刻。
        public var arrival: HostTime
        /// 写进环的帧数。
        public var frames: Int
    }

    /// 块级诊断（探针 / 报告 / A1 / A2 用）。
    public struct BlockStats: Hashable, Sendable {
        /// 写进环的块数。
        public var blocks: UInt64 = 0
        /// 写进环的帧数。
        public var frames: UInt64 = 0
        /// 环满被拒的帧数。
        public var framesRejected: UInt64 = 0
        /// 设备块长（帧）与它对应的毫秒数。
        public var blockFrames: Int = 0
        public var blockMs: Double = 0
        /// d = 回调到达时刻 − 块首帧 hostTime：均值 / 标准差 / 最大 / 最小（ms）。A2 判标准差。
        public var meanDelayMs: Double = 0
        public var sdDelayMs: Double = 0
        public var maxDelayMs: Double = 0
        public var minDelayMs: Double = 0
        /// 相邻块 hostTime 之差 − 块时长（ms）的最大绝对值与极值。A1 判它 ≤ 1 ms。
        public var maxIntervalErrorMs: Double = 0
        public var minIntervalMs: Double = 0
        public var maxIntervalMs: Double = 0
        /// hostTime 没有严格递增的块数（虚拟设备可能给重复时间戳）。
        public var nonMonotonicBlocks: UInt64 = 0
        /// w = 写环时刻 − 块首 hostTime（ms）：包含设备管线延迟 d 和泵线程那一跳；w − d 就是泵这一跳的代价。
        public var meanWriteDelayMs: Double = 0
        public var maxWriteDelayMs: Double = 0
        /// 设备侧 IO 过载通知次数（`kAudioDeviceProcessorOverload`）。
        public var overloads: UInt64 = 0
        /// 采样率转换报错的次数。
        public var conversionErrors: UInt64 = 0
    }

    // MARK: 契约要求的成员

    public let number: Int
    public let name: String
    public let kind: InputKind = .audio
    /// 纯音频输入没有画面。
    public let videoSlot: (any FrameSlot)? = nil
    public let audioRing: (any AudioRing)?
    public var state: InputState { stateBox.value }

    // MARK: 本类的公开面

    /// Core Audio 设备 UID（空串 = 跟随系统默认输入）。
    public let deviceUID: String
    public let options: Options
    /// 最近一次的错误 / 提示文案。
    public var lastError: String? { errorBox.withLock { $0 } }
    /// 诊断计数。
    public var counters: InputCounters { countersBox.snapshot(state: stateBox) }
    /// 设备名（找到设备后有值）。
    public var deviceName: String? { deviceNameBox.withLock { $0 } }
    /// 当前会话的设备信息（跑起来后有值）。
    public var deviceInfo: AudioInputDeviceInfo? { deviceInfoBox.withLock { $0 } }
    /// 块级诊断。
    public var blockStats: BlockStats { statsBox.withLock { $0.snapshot() } }
    /// 正在走采样率转换（设备固定不到 48 kHz）。
    public var isConverting: Bool { convertingBox.load(ordering: .relaxed) }
    /// 设备的实际采样率（转换前）。
    public var deviceSampleRate: Double { deviceRateBox.withLock { $0 } }
    /// IO 回调线程的 mach 端口（还没回调过 = 0；RT 分配探针用）。
    public var callbackThreadPort: UInt32 { bufferBox.withLock { $0?.callbackThread ?? 0 } }
    /// 逐块留痕（按写入顺序；`Options.traceCapacity` 为 0 时是空表）。
    public var blockTrace: [BlockTraceEntry] {
        guard let trace else { return [] }
        let n = Int(min(traceCount.load(ordering: .acquiring), UInt64(options.traceCapacity)))
        return (0..<n).map { trace[$0] }
    }
    /// 交接区计数（回调侧）。
    public var fifoCounters: AudioCaptureCounters { bufferBox.withLock { $0?.counters ?? AudioCaptureCounters() } }
    /// 热插拔事件（S4 计时用）。
    public var hotplugEvents: InputHotplugEvents { hotplugBox.withLock { $0 } }
    /// `HotplugMonitorable`：提示语里的设备叫法。
    public var hotplugDeviceLabel: String { deviceName ?? (deviceUID.isEmpty ? "系统默认输入" : deviceUID) }

    // MARK: 内部状态

    private let ring: any AudioRing
    private let stateBox = InputStateBox()
    private let countersBox = InputCountersBox()
    private let errorBox = Mutex<String?>(nil)
    private let deviceNameBox = Mutex<String?>(nil)
    private let deviceInfoBox = Mutex<AudioInputDeviceInfo?>(nil)
    private let deviceRateBox = Mutex<Double>(0)
    private let convertingBox = Atomic<Bool>(false)
    private let hotplugBox = Mutex<InputHotplugEvents>(InputHotplugEvents())
    private let statsBox = Mutex<DelayAccumulator>(DelayAccumulator())
    private let bufferBox = Mutex<AudioCaptureBuffer?>(nil)
    private let trace: UnsafeMutablePointer<BlockTraceEntry>?
    private let traceCount = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(false)
    private let sessionQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
    // 以下只在 sessionQueue 上碰
    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var pump: InputThread?
    private var watchdog: NoSignalWatchdog?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var hardwareSubscription: AudioInputDevices.Subscription?
    private var pollTimer: DispatchSourceTimer?
    private var restoreSampleRate: Double?

    // MARK: 生命周期

    public init(number: Int, name: String, deviceUID: String, audioRing: any AudioRing, options: Options = Options()) {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name
        self.deviceUID = deviceUID
        self.options = options
        self.audioRing = audioRing
        ring = audioRing
        if options.traceCapacity > 0 {
            let p = UnsafeMutablePointer<BlockTraceEntry>.allocate(capacity: options.traceCapacity)
            p.initialize(repeating: BlockTraceEntry(hostTime: .zero, arrival: .zero, frames: 0), count: options.traceCapacity)
            trace = p
        } else {
            trace = nil
        }
        sessionQueue = DispatchQueue(label: "switcher.audioinput.session.\(number)", qos: .userInitiated)
        listenerQueue = DispatchQueue(label: "switcher.audioinput.listener.\(number)", qos: .userInitiated)
    }

    deinit { trace?.deallocate() }

    /// 从 `InputSource.audio(deviceUID:)` 构造。
    public convenience init(config: InputConfig, audioRing: any AudioRing, options: Options = Options()) throws {
        guard case .audio(let uid) = config.source else { throw AudioDeviceInputError.notAnAudioSource(config.source.kind) }
        self.init(number: config.number, name: config.name, deviceUID: uid, audioRing: audioRing, options: options)
    }

    public enum AudioDeviceInputError: Error, CustomStringConvertible {
        case notAnAudioSource(InputKind)
        public var description: String {
            switch self {
            case .notAnAudioSource(let k): "不是音频设备来源：\(k)"
            }
        }
    }

    /// 不阻塞：权限检查、找设备、建会话都在 sessionQueue 上做；结果看 `state` / `lastError`。
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.async { [self] in
            installHardwareObserver()
            attempt()
            startPolling()
        }
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.sync { [self] in
            pollTimer?.cancel()
            pollTimer = nil
            hardwareSubscription?.stop()
            hardwareSubscription = nil
            teardownSession()
            setState(.noSignal)
        }
    }

    // MARK: 状态

    private func setState(_ new: InputState) {
        if stateBox.set(new) {
            let now = HostClock.now()
            hotplugBox.withLock { e in
                e.lastStateChangeAt = now
                if new == .live { e.lastLiveAt = now }
            }
        }
    }

    private func setError(_ message: String) {
        errorBox.withLock { $0 = message }
        setState(.error(message: message))
    }

    private func setNoSignal(_ message: String?) {
        errorBox.withLock { $0 = message }
        setState(.noSignal)
    }

    // MARK: 建 / 拆会话（sessionQueue）

    /// 一次尝试：权限 → 设备 → 会话。失败只改状态，不抛（轮询会再试）。
    private func attempt() {
        guard running.load(ordering: .acquiring), procID == nil else { return }
        let status = CapturePermission.status(for: .audio)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            setError(CapturePermission.message(for: .notDetermined, mediaType: .audio))
            AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
                sessionQueue.async { [self] in
                    guard running.load(ordering: .acquiring) else { return }
                    if granted {
                        attempt()
                    } else {
                        let after = CapturePermission.status(for: .audio)
                        setError(CapturePermission.message(for: after == .notDetermined ? .deniedWithoutPrompt : after, mediaType: .audio))
                    }
                }
            }
            return
        case .denied, .restricted, .deniedWithoutPrompt:
            setError(CapturePermission.message(for: status, mediaType: .audio))
            return
        }
        let device = AudioInputDevices.deviceID(uid: deviceUID)
        guard device != 0, let info = AudioInputDevices.info(of: device) else {
            setNoSignal("找不到音频输入设备「\(deviceUID.isEmpty ? "系统默认输入" : deviceUID)」（未连接）；"
                        + "已连接的输入设备：\(AudioInputDevices.list().map(\.name).joined(separator: "、"))")
            return
        }
        guard info.isAlive else {
            setNoSignal("音频输入设备「\(info.name)」不在线，等待它回来")
            return
        }
        buildSession(device: device, info: info)
    }

    private func buildSession(device: AudioObjectID, info: AudioInputDeviceInfo) {
        deviceNameBox.withLock { $0 = info.name }
        var format = AudioInputDevices.inputStreamFormat(device)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame > 0 else {
            setNoSignal("音频输入设备「\(info.name)」的格式不是 LPCM，暂不支持")
            return
        }
        guard let sampleFormat = Self.sampleFormat(of: format) else {
            setNoSignal("音频输入设备「\(info.name)」的采样格式暂不支持（\(format.mBitsPerChannel) bit，"
                        + "\(format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "浮点" : "整数")）")
            return
        }

        // ---- 采样率：先试着把设备固定到 48 kHz，不行再在泵线程上转 ----
        let target = Double(AudioFormat.sampleRate)
        var rate = AudioInputDevices.nominalSampleRate(device)
        if abs(rate - target) >= 0.5, options.forceSampleRate48k, info.supports48k {
            let previous = rate
            if AudioInputDevices.setNominalSampleRate(device, target, timeout: HostDuration(milliseconds: 1500)) {
                restoreSampleRate = previous
                rate = target
                format = AudioInputDevices.inputStreamFormat(device)
            }
        }
        var converter: AudioRateConverter?
        if abs(rate - target) >= 0.5 {
            guard options.convertSampleRate else {
                restoreDeviceSampleRate()
                setNoSignal("音频输入设备「\(info.name)」不支持 48 kHz（当前 \(Int(rate.rounded())) Hz）")
                return
            }
            do {
                converter = try AudioRateConverter(sourceRate: rate, channels: ring.channelCount,
                                                   maxOutputFrames: Self.slotFrames(for: info, options: options) * 2,
                                                   measurementBlockFrames: max(info.bufferFrameSize, 1))
            } catch {
                restoreDeviceSampleRate()
                setNoSignal("音频输入设备「\(info.name)」是 \(Int(rate.rounded())) Hz，建采样率转换器失败：\(error)")
                return
            }
        }
        deviceRateBox.withLock { $0 = rate }
        convertingBox.store(converter != nil, ordering: .relaxed)

        // ---- 交接区 ----
        let deviceChannels = info.inputChannels
        let slotFrames = Self.slotFrames(for: info, options: options)
        let map = options.channelMap ?? Array(0..<ring.channelCount)
        let buffer = AudioCaptureBuffer(channels: ring.channelCount, deviceChannels: deviceChannels, channelMap: map,
                                        bufferChannelCounts: AudioInputDevices.inputBufferChannelCounts(device),
                                        sampleFormat: sampleFormat, sampleRate: rate,
                                        slotFrames: slotFrames, slotCount: options.slotCount)
        bufferBox.withLock { $0 = buffer }

        // ---- IOProc ----
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(device, audioDeviceInputIOProc, UnsafeMutableRawPointer(buffer.fifo), &proc)
        guard status == noErr, let proc else {
            bufferBox.withLock { $0 = nil }
            restoreDeviceSampleRate()
            setNoSignal("音频输入设备「\(info.name)」建 IOProc 失败（OSStatus \(status)），将重试")
            return
        }
        deviceID = device
        procID = proc
        deviceInfoBox.withLock { $0 = info }
        statsBox.withLock { $0.reset() }

        // ---- 泵线程 ----
        let blockDuration = HostDuration(seconds: Double(max(info.bufferFrameSize, 1)) / max(rate, 1))
        let period = min(max(blockDuration / 4, options.pumpPeriodRange.lowerBound), options.pumpPeriodRange.upperBound)
        let watchdogInterval = max(blockDuration, HostDuration(milliseconds: 33))
        let wd = NoSignalWatchdog(expectedInterval: watchdogInterval, multiplier: options.noSignalMultiplier, queue: sessionQueue) { [weak self] present in
            guard let self, running.load(ordering: .acquiring), procID != nil else { return }
            if present {
                errorBox.withLock { $0 = nil }
                setState(.live)
            } else {
                setNoSignal("音频输入设备「\(deviceName ?? deviceUID)」没有新的音频块（超过 \(options.noSignalMultiplier) 个块间隔）")
            }
        }
        watchdog = wd
        let pumpConverter = converter
        let thread = InputThread(name: "switcher.audioinput.pump.\(number)", period: period) { [weak self] thread in
            self?.pumpLoop(thread: thread, buffer: buffer, converter: pumpConverter, watchdog: wd, period: period)
        }
        pump = thread
        installDeviceObservers(device: device)
        errorBox.withLock { $0 = nil }
        countersBox.rebuilds.add(1, ordering: .relaxed)
        thread.start()
        let startStatus = AudioDeviceStart(device, proc)
        if startStatus != noErr {
            setNoSignal("音频输入设备「\(info.name)」起流失败（OSStatus \(startStatus)），将重试")
            teardownSession()
            return
        }
        wd.start()
    }

    private func teardownSession() {
        if let proc = procID, deviceID != 0 {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
        }
        procID = nil
        watchdog?.stop()
        watchdog = nil
        pump?.stop()
        pump = nil
        removeDeviceObservers()
        bufferBox.withLock { $0 = nil }
        restoreDeviceSampleRate()
        deviceID = 0
        convertingBox.store(false, ordering: .relaxed)
    }

    /// 我们改过设备采样率就还原（别的程序还在用同一台设备）。
    private func restoreDeviceSampleRate() {
        if let previous = restoreSampleRate, deviceID != 0 {
            AudioInputDevices.setNominalSampleRate(deviceID, previous, timeout: HostDuration(milliseconds: 500))
        }
        restoreSampleRate = nil
    }

    /// 交接区每槽的帧数：设备块大小的两倍，钳在 1024…4096。
    private static func slotFrames(for info: AudioInputDeviceInfo, options: Options) -> Int {
        min(max(info.bufferFrameSize * 2, 1024), 4096)
    }

    private static func sampleFormat(of format: AudioStreamBasicDescription) -> AudioCaptureFIFO.SampleFormat? {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        switch (isFloat, format.mBitsPerChannel) {
        case (true, 32): return .float32
        case (false, 16): return .int16
        case (false, 32): return .int32
        default: return nil
        }
    }

    // MARK: 泵线程

    private func pumpLoop(thread: InputThread, buffer: AudioCaptureBuffer, converter: AudioRateConverter?,
                          watchdog: NoSignalWatchdog, period: HostDuration) {
        let channels = ring.channelCount
        let planeTable = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        defer { planeTable.deallocate() }
        let hostTicksPerSourceFrame = converter.map { Double(HostDuration(seconds: 1).ticks) / $0.sourceRate } ?? 0
        var next = HostClock.now() + period
        while !thread.isStopRequested {
            buffer.drain(planeTable: planeTable) { planes, frames, header in
                self.noteDelay(header: header)
                if let converter {
                    let outputIndexBefore = converter.destinationFramesProduced
                    let anchorSourceIndex = converter.sourceFramesConsumed
                    let anchorHost = Double(header.hostTime)
                    do {
                        try converter.convert(planes: planes, frameCount: frames) { outputPlanes, outputFrames in
                            let sourceFrame = converter.sourceFrame(forOutputFrame: outputIndexBefore)
                            let ticks = anchorHost + (sourceFrame - Double(anchorSourceIndex)) * hostTicksPerSourceFrame
                            self.writeToRing(planes: outputPlanes, frames: outputFrames,
                                             hostTime: HostTime(ticks: UInt64(max(ticks, 0).rounded())),
                                             arrival: HostTime(ticks: header.arrival), watchdog: watchdog)
                        }
                    } catch {
                        self.statsBox.withLock { $0.conversionErrors += 1 }
                    }
                } else {
                    self.writeToRing(planes: planes, frames: frames, hostTime: HostTime(ticks: header.hostTime),
                                     arrival: HostTime(ticks: header.arrival), watchdog: watchdog)
                }
            }
            let now = HostClock.now()
            if next < now { next = now + period }
            thread.sleep(until: next, slice: HostDuration(milliseconds: 5))
            next = next + period
        }
    }

    private func writeToRing(planes: UnsafePointer<UnsafePointer<Float>>, frames: Int, hostTime: HostTime,
                             arrival: HostTime, watchdog: NoSignalWatchdog) {
        guard frames > 0 else { return }
        if let trace {
            let index = traceCount.load(ordering: .relaxed)
            if index < UInt64(options.traceCapacity) { trace[Int(index)] = BlockTraceEntry(hostTime: hostTime, arrival: arrival, frames: frames) }
            traceCount.store(index + 1, ordering: .releasing)
        }
        let written = ring.write(planes: planes, frameCount: frames, hostTime: hostTime)
        let writtenAt = HostClock.now()
        countersBox.audioBlocksWritten.add(1, ordering: .relaxed)
        countersBox.audioFramesWritten.add(UInt64(written), ordering: .relaxed)
        if written < frames { countersBox.audioFramesRejected.add(UInt64(frames - written), ordering: .relaxed) }
        statsBox.withLock { $0.note(hostTime: hostTime, frames: frames, written: written, writtenAt: writtenAt) }
        watchdog.noteFrame(at: writtenAt)
    }

    private func noteDelay(header: AudioCaptureBlockHeader) {
        let delta = HostDuration(ticks: Int64(bitPattern: header.arrival &- header.hostTime))
        statsBox.withLock { $0.noteDelay(delta) }
    }

    // MARK: 通知与轮询（sessionQueue）

    /// 设备清单 / 默认输入变化：设备回来了就重建，没了就进 noSignal。
    private func installHardwareObserver() {
        hardwareSubscription = AudioInputDevices.observeChanges(queue: listenerQueue) { [weak self] in
            guard let self else { return }
            sessionQueue.async { [self] in
                guard running.load(ordering: .acquiring) else { return }
                let resolved = AudioInputDevices.deviceID(uid: deviceUID)
                if procID != nil, resolved != deviceID || resolved == 0 {
                    hotplugBox.withLock { $0.disconnects += 1; $0.lastDisconnectAt = HostClock.now() }
                    let label = deviceName ?? deviceUID
                    teardownSession()
                    setNoSignal("音频输入设备「\(label)」已断开，等待重新连接")
                } else if procID == nil, resolved != 0 {
                    hotplugBox.withLock { $0.connects += 1; $0.lastConnectAt = HostClock.now() }
                    attempt()
                }
            }
        }
    }

    /// 设备自己的通知：不在线了、IO 过载。
    private func installDeviceObservers(device: AudioObjectID) {
        addListener(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self else { return }
            sessionQueue.async { [self] in
                guard running.load(ordering: .acquiring), procID != nil, deviceID == device else { return }
                if AudioInputDevices.value(device, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) == 0 {
                    hotplugBox.withLock { $0.disconnects += 1; $0.lastDisconnectAt = HostClock.now() }
                    let label = deviceName ?? deviceUID
                    teardownSession()
                    setNoSignal("音频输入设备「\(label)」已断开，等待重新连接")
                }
            }
        }
        addListener(device, kAudioDeviceProcessorOverload) { [weak self] in
            self?.statsBox.withLock { $0.overloads += 1 }
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void) {
        var a = AudioInputDevices.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &a, listenerQueue, block) == noErr {
            listeners.append((object, a, block))
        }
    }

    private func removeDeviceObservers() {
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, listenerQueue, block)
        }
        listeners.removeAll()
    }

    /// 每秒一次：没会话就再试（权限恢复 / 设备回来的兜底）；有会话就看设备还在不在、块是不是一直被丢。
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        let ns = Int(max(options.pollInterval.nanoseconds, 100_000_000))
        timer.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, running.load(ordering: .acquiring) else { return }
            if procID == nil {
                // 权限刚拒过：状态变了才再试
                if case .error = stateBox.value, CapturePermission.status(for: .audio) != .authorized { return }
                attempt()
            } else {
                let resolved = AudioInputDevices.deviceID(uid: deviceUID)
                if resolved != deviceID || AudioInputDevices.value(deviceID, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) == 0 {
                    let label = deviceName ?? deviceUID
                    teardownSession()
                    setNoSignal("音频输入设备「\(label)」已断开，等待重新连接")
                } else if let buffer = bufferBox.withLock({ $0 }), buffer.counters.oversizeBlocks > 0 {
                    // 设备中途把 IO 块调大了（别的程序改的）：按新块大小重建
                    teardownSession()
                    setNoSignal("音频输入设备的 IO 块大小变了，正在按新块大小重建")
                    attempt()
                }
            }
        }
        pollTimer = timer
        timer.resume()
    }
}

/// `BlockStats` 的累加器（只在泵线程 / 通知里改，外面读快照）。
struct DelayAccumulator {
    var blocks: UInt64 = 0
    var frames: UInt64 = 0
    var framesRejected: UInt64 = 0
    var blockFrames: Int = 0
    var blockMs: Double = 0
    var overloads: UInt64 = 0
    var conversionErrors: UInt64 = 0
    private var delayCount: UInt64 = 0
    private var delaySum: Double = 0
    private var delaySumSquares: Double = 0
    private var delayMax = -Double.infinity
    private var delayMin = Double.infinity
    private var writeDelayCount: UInt64 = 0
    private var writeDelaySum: Double = 0
    private var writeDelayMax = -Double.infinity
    private var lastHostTime: HostTime?
    private var lastFrames: Int = 0
    private var intervalMax = -Double.infinity
    private var intervalMin = Double.infinity
    private var intervalErrorMax: Double = 0
    private var nonMonotonic: UInt64 = 0

    mutating func reset() { self = DelayAccumulator() }

    mutating func noteDelay(_ delta: HostDuration) {
        let ms = delta.milliseconds
        delayCount += 1
        delaySum += ms
        delaySumSquares += ms * ms
        delayMax = max(delayMax, ms)
        delayMin = min(delayMin, ms)
    }

    mutating func note(hostTime: HostTime, frames: Int, written: Int, writtenAt: HostTime) {
        blocks += 1
        let w = (writtenAt - hostTime).milliseconds
        writeDelayCount += 1
        writeDelaySum += w
        writeDelayMax = max(writeDelayMax, w)
        self.frames += UInt64(written)
        if written < frames { framesRejected += UInt64(frames - written) }
        if let last = lastHostTime {
            if hostTime.ticks <= last.ticks { nonMonotonic += 1 }
            let ms = (hostTime - last).milliseconds
            intervalMax = max(intervalMax, ms)
            intervalMin = min(intervalMin, ms)
            // 期望间隔 = 上一块的帧数 / 48 kHz（环里就是这个时间轴；转换路径上每块帧数可能差 1 帧）
            let expected = Double(lastFrames) / Double(AudioFormat.sampleRate) * 1000
            intervalErrorMax = max(intervalErrorMax, abs(ms - expected))
        }
        lastHostTime = hostTime
        lastFrames = written
        blockFrames = written
        blockMs = Double(written) / Double(AudioFormat.sampleRate) * 1000
    }

    func snapshot() -> AudioDeviceInput.BlockStats {
        var s = AudioDeviceInput.BlockStats()
        s.blocks = blocks
        s.frames = frames
        s.framesRejected = framesRejected
        s.blockFrames = blockFrames
        s.blockMs = blockMs
        s.overloads = overloads
        s.conversionErrors = conversionErrors
        if writeDelayCount > 0 {
            s.meanWriteDelayMs = writeDelaySum / Double(writeDelayCount)
            s.maxWriteDelayMs = writeDelayMax
        }
        s.nonMonotonicBlocks = nonMonotonic
        if delayCount > 0 {
            let n = Double(delayCount)
            let mean = delaySum / n
            s.meanDelayMs = mean
            s.sdDelayMs = max(delaySumSquares / n - mean * mean, 0).squareRoot()
            s.maxDelayMs = delayMax
            s.minDelayMs = delayMin
        }
        if blocks > 1 {
            s.maxIntervalErrorMs = intervalErrorMax
            s.minIntervalMs = intervalMin
            s.maxIntervalMs = intervalMax
        }
        return s
    }
}
