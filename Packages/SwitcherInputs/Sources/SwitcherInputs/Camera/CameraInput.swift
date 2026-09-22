@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import SwitcherContracts

/// 摄像头 / UVC 采集卡输入（设计方案 §6 第一行；W2-A 第 1、5 条）。
///
/// - AVCaptureSession + AVCaptureVideoDataOutput：请求 '420v'，alwaysDiscardsLateVideoFrames = true；格式按 `CameraFormatNegotiation`
///   协商（帧率优先匹配节目帧率，再分辨率，再原生 NV12），并把 activeVideoMin/MaxFrameDuration 锁到协商帧率。
/// - 时间戳：`CMSyncConvertTime(pts, from: session.synchronizationClock, to: host clock)`（设计方案 §3.6），再换成 host tick；
///   `ingressTime` = push 前一刻。探针（reports/w2-inputs.md §5）：macOS 26 上会话的 synchronizationClock 就是 host clock，
///   转换是恒等，但代码仍然走转换（外接设备 / 未来系统可能不是）。
/// - 设备自带麦克风（`device.linkedDevices` 里的音频设备）走 AVCaptureAudioDataOutput，要 float32 非交错 48 kHz，块首 host time 写环。
/// - 无信号：`NoSignalWatchdog`（期望帧间隔 × N，N 默认 3）；会话运行错误 / 设备断开立即 noSignal。
/// - 热插拔：`AVCaptureDevice.wasDisconnected / wasConnected` 通知（按 uniqueID）；断开拆会话进 noSignal，回来自动重建，
///   编号和 InputSettings 不变（它们不在这个对象里）。设备一开始不在：noSignal，等它来。
/// - 权限：未授权 → `.error(清楚文案)`，每秒轮询授权状态，授权后自动建会话，不用重启。
/// - 线程：会话管理在 `sessionQueue`（串行），采集回调在 `captureQueue`（串行，= 这路输入的线程；只有它 push / write）。
public final class CameraInput: NSObject, Input, HotplugMonitorable, @unchecked Sendable {
    /// 可调参数。
    public struct Options: Sendable, Hashable {
        /// 无信号门限：期望帧间隔 × N。
        public var noSignalMultiplier = 3
        /// 权限 / 设备轮询间隔。
        public var pollInterval = HostDuration(milliseconds: 1000)
        /// 请求的像素格式（'420v'）。
        public var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        /// 采集设备自带的麦克风（注入了音频环才有意义）。
        public var captureLinkedAudio = true
        public init() {}
    }

    /// 时间戳诊断（探针 / 报告用）。
    public struct TimestampStats: Hashable, Sendable {
        /// 会话的 synchronizationClock 是否就是 host clock（CFEqual）。
        public var syncClockIsHostClock: Bool?
        /// 样本数。
        public var frames: UInt64
        /// d = ingressTime − pts 的平均 / 最大 / 最小（ms）。
        public var meanDelayMs: Double
        public var maxDelayMs: Double
        public var minDelayMs: Double
        /// 采集回调报告的被丢帧数（alwaysDiscardsLateVideoFrames）。
        public var droppedByCapture: UInt64
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .camera
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)?
    public var state: InputState { stateBox.value }
    /// 设备 uniqueID（或探针给的下标）。
    public let uniqueID: String
    public let options: Options
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }
    public var lastError: String? { errorBox.withLock { $0 } }
    public var counters: InputCounters { countersBox.snapshot(state: stateBox) }
    /// 协商结果（会话建好后有值）。
    public var negotiated: CameraFormatNegotiation.Choice? { negotiatedBox.withLock { $0 } }
    /// 设备名（找到设备后有值）。
    public var deviceName: String? { deviceNameBox.withLock { $0 } }
    /// 热插拔事件记录（S5 计时用）。
    public typealias HotplugEvents = InputHotplugEvents
    public var hotplugEvents: InputHotplugEvents { hotplugBox.withLock { $0 } }
    /// `HotplugMonitorable`：提示语里的设备叫法。
    public var hotplugDeviceLabel: String { deviceName ?? uniqueID }
    private let hotplugBox = Mutex<InputHotplugEvents>(InputHotplugEvents())

    /// 置状态并记时刻。
    private func setState(_ new: InputState) {
        if stateBox.set(new) {
            let now = HostClock.now()
            hotplugBox.withLock { e in
                e.lastStateChangeAt = now
                if new == .live { e.lastLiveAt = now }
            }
        }
    }

    /// 时间戳诊断。
    public var timestampStats: TimestampStats {
        let n = tsCount.load(ordering: .relaxed)
        return TimestampStats(syncClockIsHostClock: syncIsHost.load(ordering: .relaxed) == 0 ? nil : syncIsHost.load(ordering: .relaxed) == 1,
                              frames: n,
                              meanDelayMs: n == 0 ? 0 : Double(tsSum.load(ordering: .relaxed)) / Double(n) / 1e6,
                              maxDelayMs: n == 0 ? 0 : Double(tsMax.load(ordering: .relaxed)) / 1e6,
                              minDelayMs: n == 0 ? 0 : Double(tsMin.load(ordering: .relaxed)) / 1e6,
                              droppedByCapture: droppedByCapture.load(ordering: .relaxed))
    }

    private let timingBox: Mutex<ProgramTiming>
    private let slot: any FrameSlot
    private let stateBox = InputStateBox()
    private let countersBox = InputCountersBox()
    private let errorBox = Mutex<String?>(nil)
    private let negotiatedBox = Mutex<CameraFormatNegotiation.Choice?>(nil)
    private let deviceNameBox = Mutex<String?>(nil)
    private let sessionQueue: DispatchQueue
    private let captureQueue: DispatchQueue
    private let running = Atomic<Bool>(false)
    private let tsCount = Atomic<UInt64>(0)
    private let tsSum = Atomic<Int64>(0)
    private let tsMax = Atomic<Int64>(Int64.min)
    private let tsMin = Atomic<Int64>(Int64.max)
    private let syncIsHost = Atomic<Int>(0)
    private let droppedByCapture = Atomic<UInt64>(0)
    // 以下只在 sessionQueue 上碰
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: DispatchSourceTimer?
    private var watchdog: NoSignalWatchdog?
    // 以下只在 captureQueue 上碰
    private var sequence: UInt64 = 0
    private var frameDuration = HostDuration.zero
    private var color = ColorInfo.bt709Limited
    private var colorResolved = false
    private var audioWriter: AudioSampleWriter?
    private var sessionClock: CMClock?

    public init(number: Int, name: String, uniqueID: String, timing: ProgramTiming, videoSlot: any FrameSlot,
                audioRing: (any AudioRing)? = nil, options: Options = Options()) {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name
        self.uniqueID = uniqueID
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        sessionQueue = DispatchQueue(label: "switcher.camera.session.\(number)", qos: .userInitiated)
        captureQueue = DispatchQueue(label: "switcher.camera.capture.\(number)", qos: .userInteractive)
        super.init()
    }

    /// 从 InputSource.camera 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil,
                            options: Options = Options()) throws {
        guard case .camera(let id) = config.source else { throw CameraInputError.notACameraSource(config.source.kind) }
        self.init(number: config.number, name: config.name, uniqueID: id, timing: timing, videoSlot: videoSlot, audioRing: audioRing, options: options)
    }

    public enum CameraInputError: Error, CustomStringConvertible {
        case notACameraSource(InputKind)
        public var description: String {
            switch self {
            case .notACameraSource(let k): "不是摄像头来源：\(k)"
            }
        }
    }

    // MARK: 生命周期

    /// 不阻塞：权限检查、设备查找、会话建立都在 sessionQueue 上做；结果看 `state` / `lastError`。
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.async { [self] in
            installObservers()
            attempt()
            startPolling()
        }
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.sync { [self] in
            pollTimer?.cancel()
            pollTimer = nil
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            teardownSession()
            setState(.noSignal)
        }
    }

    // MARK: 建 / 拆会话（sessionQueue）

    /// 一次尝试：权限 → 设备 → 会话。失败只改状态，不抛（轮询会再试）。
    private func attempt() {
        guard running.load(ordering: .acquiring), session == nil else { return }
        let status = CapturePermission.status(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // 请求一次；系统弹不弹提示都会回调。等用户回答期间先把文案挂出来（UI 有东西可显示）
            setError(CapturePermission.message(for: .notDetermined, mediaType: .video))
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                sessionQueue.async { [self] in
                    if granted {
                        attempt()
                    } else {
                        let after = CapturePermission.status(for: .video)
                        let s: CapturePermission.Status = after == .notDetermined ? .deniedWithoutPrompt : after
                        setError(CapturePermission.message(for: s, mediaType: .video))
                    }
                }
            }
            return
        case .denied, .restricted, .deniedWithoutPrompt:
            setError(CapturePermission.message(for: status, mediaType: .video))
            return
        }
        guard let dev = CameraDevices.device(uniqueID: uniqueID), dev.isConnected else {
            errorBox.withLock { $0 = "找不到摄像头 \(uniqueID)（未连接）" }
            setState(.noSignal)
            return
        }
        buildSession(device: dev)
    }

    private func setError(_ message: String) {
        errorBox.withLock { $0 = message }
        setState(.error(message: message))
    }

    private func buildSession(device dev: AVCaptureDevice) {
        let timing = self.timing
        let s = AVCaptureSession()
        s.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard s.canAddInput(input) else { throw CameraSessionError.cannotAddInput }
            s.addInput(input)
            // 协商格式 + 锁帧率
            let choice = CameraFormatNegotiation.choose(CameraDevices.candidates(of: dev), program: timing.format)
            if let choice {
                try dev.lockForConfiguration()
                dev.activeFormat = dev.formats[choice.candidate.index]
                let fps = choice.frameRate
                let dur = CMTime(value: 1001, timescale: Int32((fps * 1001).rounded()))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
            }
            negotiatedBox.withLock { $0 = choice }
            let vo = AVCaptureVideoDataOutput()
            vo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: options.pixelFormat]
            vo.alwaysDiscardsLateVideoFrames = true
            vo.setSampleBufferDelegate(self, queue: captureQueue)
            guard s.canAddOutput(vo) else { throw CameraSessionError.cannotAddOutput }
            s.addOutput(vo)
            videoOutput = vo
            // 自带麦克风
            if let ring = audioRing, options.captureLinkedAudio,
               let mic = dev.linkedDevices.first(where: { $0.hasMediaType(.audio) }) ?? (dev.hasMediaType(.audio) ? dev : nil) {
                let micStatus = CapturePermission.status(for: .audio)
                if micStatus == .authorized || micStatus == .notDetermined {
                    let micInput = try AVCaptureDeviceInput(device: mic)
                    if s.canAddInput(micInput) {
                        s.addInput(micInput)
                        let ao = AVCaptureAudioDataOutput()
                        ao.audioSettings = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: AudioFormat.sampleRate,
                            AVNumberOfChannelsKey: ring.channelCount,
                            AVLinearPCMBitDepthKey: 32,
                            AVLinearPCMIsFloatKey: true,
                            AVLinearPCMIsNonInterleaved: true,
                        ]
                        ao.setSampleBufferDelegate(self, queue: captureQueue)
                        if s.canAddOutput(ao) {
                            s.addOutput(ao)
                            audioOutput = ao
                            captureQueue.sync { audioWriter = AudioSampleWriter(ring: ring) }
                        }
                    }
                } else {
                    errorBox.withLock { $0 = CapturePermission.message(for: micStatus, mediaType: .audio) }
                }
            }
            s.commitConfiguration()
        } catch {
            s.commitConfiguration()
            setError("摄像头会话建立失败：\(error)")
            return
        }
        // 无信号看门狗按协商帧率
        let fps = negotiated?.frameRate ?? timing.format.frameRate.approximateFramesPerSecond
        let interval = HostDuration(seconds: 1 / max(fps, 1))
        captureQueue.sync {
            sequence = 0
            colorResolved = false
            frameDuration = interval
            sessionClock = nil
        }
        let wd = NoSignalWatchdog(expectedInterval: interval, multiplier: options.noSignalMultiplier, queue: sessionQueue) { [weak self] present in
            guard let self, running.load(ordering: .acquiring), session != nil else { return }
            if present {
                errorBox.withLock { $0 = nil }
                setState(.live)
            } else {
                errorBox.withLock { $0 = "摄像头 \(deviceName ?? uniqueID) 没有新帧（超过 \(options.noSignalMultiplier) 个帧间隔）" }
                setState(.noSignal)
            }
        }
        watchdog = wd
        session = s
        device = dev
        deviceNameBox.withLock { $0 = dev.localizedName }
        errorBox.withLock { $0 = nil }
        countersBox.rebuilds.add(1, ordering: .relaxed)
        s.startRunning()
        wd.start()
    }

    enum CameraSessionError: Error { case cannotAddInput, cannotAddOutput }

    private func teardownSession() {
        watchdog?.stop()
        watchdog = nil
        if let s = session {
            if s.isRunning { s.stopRunning() }
            videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
        session = nil
        device = nil
        videoOutput = nil
        audioOutput = nil
        captureQueue.sync { audioWriter = nil }
    }

    // MARK: 通知与轮询（sessionQueue）

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice else { return }
            let id = d.uniqueID
            sessionQueue.async { [self] in
                guard running.load(ordering: .acquiring), let cur = device, cur.uniqueID == id else { return }
                hotplugBox.withLock { $0.disconnects += 1; $0.lastDisconnectAt = HostClock.now() }
                teardownSession()
                errorBox.withLock { $0 = "摄像头 \(d.localizedName) 已断开，等待重新连接" }
                setState(.noSignal)
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice else { return }
            let id = d.uniqueID
            sessionQueue.async { [self] in
                guard running.load(ordering: .acquiring), session == nil else { return }
                if id == uniqueID || CameraDevices.device(uniqueID: uniqueID)?.uniqueID == id {
                    hotplugBox.withLock { $0.connects += 1; $0.lastConnectAt = HostClock.now() }
                    attempt()
                }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let s = note.object as? AVCaptureSession else { return }
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError).map { "\($0.localizedDescription)" } ?? "未知错误"
            sessionQueue.async { [self] in
                guard running.load(ordering: .acquiring), s === session else { return }
                teardownSession()
                errorBox.withLock { $0 = "摄像头会话运行错误：\(err)，将重试" }
                setState(.noSignal)
            }
        })
    }

    /// 每秒一次：没会话就再试（权限恢复 / 设备回来的兜底）。
    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        let ns = Int(max(options.pollInterval.nanoseconds, 100_000_000))
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, running.load(ordering: .acquiring) else { return }
            if session == nil {
                // 权限刚拒过：状态变了才再试，免得反复弹
                if case .error = stateBox.value, CapturePermission.status(for: .video) != .authorized { return }
                attempt()
            } else if let d = device, !d.isConnected {
                teardownSession()
                setState(.noSignal)
            }
        }
        pollTimer = t
        t.resume()
    }

    // MARK: 采集回调（captureQueue）

    /// 一帧 / 一块音频的入口打戳：CMSyncConvertTime → host clock → host tick。
    @inline(__always)
    private func hostTime(of sampleBuffer: CMSampleBuffer) -> HostTime {
        if sessionClock == nil, let s = session {
            sessionClock = s.synchronizationClock
            syncIsHost.store(sessionClock.map { CFEqual($0, CMClockGetHostTimeClock()) ? 1 : 2 } ?? 1, ordering: .relaxed)
        }
        return HostTime(time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: sessionClock)
    }

    fileprivate func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        countersBox.framesReceived.add(1, ordering: .relaxed)
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), CVPixelBufferGetIOSurface(pb) != nil else {
            countersBox.framesRejected.add(1, ordering: .relaxed)
            return
        }
        let pts = hostTime(of: sampleBuffer)
        if !colorResolved {
            color = PixelBuffers.colorInfo(of: pb, default: .bt709Limited)
            colorResolved = true
        }
        let sbDuration = HostDuration(cmDuration: CMSampleBufferGetDuration(sampleBuffer))
        let duration = sbDuration.ticks > 0 ? sbDuration : frameDuration
        sequence += 1
        countersBox.surfaces.note(pb)
        let ingress = HostClock.now()
        slot.push(Frame(pixelBuffer: pb, pts: pts, duration: duration, color: color, inputNumber: number, sequence: sequence, ingressTime: ingress))
        countersBox.framesPushed.add(1, ordering: .relaxed)
        watchdog?.noteFrame(at: ingress)
        let d = (ingress - pts).nanoseconds
        tsCount.add(1, ordering: .relaxed)
        tsSum.add(d, ordering: .relaxed)
        _ = tsMax.max(d, ordering: .relaxed)
        _ = tsMin.min(d, ordering: .relaxed)
    }

    fileprivate func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let w = audioWriter else { return }
        let t = hostTime(of: sampleBuffer)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let n = w.write(sampleBuffer: sampleBuffer, hostTime: t)
        countersBox.audioBlocksWritten.add(1, ordering: .relaxed)
        countersBox.audioFramesWritten.add(UInt64(n), ordering: .relaxed)
        if n < frames { countersBox.audioFramesRejected.add(UInt64(frames - n), ordering: .relaxed) }
    }

    fileprivate func noteDropped() { droppedByCapture.add(1, ordering: .relaxed) }
}

extension CameraInput: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { handleVideo(sampleBuffer) } else { handleAudio(sampleBuffer) }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        noteDropped()
    }
}
