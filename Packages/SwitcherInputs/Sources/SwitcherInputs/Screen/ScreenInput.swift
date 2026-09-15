import CoreGraphics
import CoreMedia
import Dispatch
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization
import SwitcherContracts

/// 屏幕 / 窗口 / 应用输入（设计方案 §6 "屏幕 / 窗口"；W2-A 第 2 条）：ScreenCaptureKit。
///
/// - 三种过滤：显示器（`SCContentFilter(display:excludingWindows:)`）、窗口（`desktopIndependentWindow`）、应用（`including:`）。
/// - 零拷贝：SCK 给的 CMSampleBuffer 就是 IOSurface 背后的 CVPixelBuffer，直接 push；默认 BGRA（RGB 内容、文字不被 4:2:0 抽色）
///   sRGB，也可要 '420v'（BT.709 limited）。源比节目大时让 SCK 缩到节目框内（保持长宽比）。
/// - 帧率：`source.frameRate`，nil = 节目帧率（minimumFrameInterval）。
/// - 时间戳：SCK 的 pts 在 host clock 上（探针，报告 §5），直接换成 host tick；离现在超过 1 s 的当异常，退回帧附件 displayTime
///   （mach 时刻），再退回现在（都计数）。
/// - 画面不动时 SCK 不给新帧（status idle）：一个与采集同队列的定时器每个节目拍把最后一帧以 pts = 现在 重新 push
///   （帧槽不靠 reused 撑画面，Stats 里 dup = 0；同一串行队列 = 单生产者）。
/// - 系统音频：`capturesAudio`，48 kHz、环的声道数，排除本进程自己的声音；块首 host time 写环。
/// - 无信号：流停止（didStopWithError）立即 noSignal 并重试；看门狗兜底。
/// - 权限：`CGPreflightScreenCaptureAccess()` 为假 → `.error(文案)`，请求一次（系统提示 / 打开系统设置），每秒轮询，授权后自动建流。
public final class ScreenInput: NSObject, Input, @unchecked Sendable {
    public struct Options: Sendable, Hashable {
        /// 输出像素格式：BGRA（默认）或 '420v'。
        public var pixelFormat: OSType = kCVPixelFormatType_32BGRA
        /// 缩放上限；nil = 节目分辨率。
        public var maxWidth: Int?
        public var maxHeight: Int?
        /// 画面不动时每拍重推最后一帧。
        public var refreshWhenIdle = true
        /// 无信号门限倍数。
        public var noSignalMultiplier = 3
        /// SCK 队列深度（3–8）。
        public var queueDepth = 3
        /// 显示鼠标。
        public var showsCursor = true
        /// 轮询间隔（权限 / 重试）。
        public var pollInterval = HostDuration(milliseconds: 1000)
        public init() {}
    }

    /// 时间戳诊断。
    public struct TimestampStats: Hashable, Sendable {
        public var frames: UInt64
        /// d = ingress − pts（ms）。
        public var meanDelayMs: Double
        public var maxDelayMs: Double
        public var minDelayMs: Double
        /// pts 异常、退回 displayTime 附件的帧数。
        public var fallbackToDisplayTime: UInt64
        /// 两者都异常、用"现在"打戳的帧数。
        public var fallbackToNow: UInt64
        /// idle（没变化）帧数。
        public var idleFrames: UInt64
        /// 定时器重推的帧数。
        public var refreshedFrames: UInt64
    }

    public let number: Int
    public let name: String
    public let kind: InputKind = .screen
    public let videoSlot: (any FrameSlot)?
    public let audioRing: (any AudioRing)?
    public var state: InputState { stateBox.value }
    public let target: ScreenTarget
    public let frameRate: FrameRate?
    public let captureAudio: Bool
    public let options: Options
    public var timing: ProgramTiming {
        get { timingBox.withLock { $0 } }
        set { timingBox.withLock { $0 = newValue } }
    }
    public var lastError: String? { errorBox.withLock { $0 } }
    public var counters: InputCounters { countersBox.snapshot(state: stateBox) }
    /// 流建好后：目标描述与输出尺寸。
    public var targetDescription: String? { descriptionBox.withLock { $0 } }
    public var outputWidth: Int { sizeBox.withLock { $0.0 } }
    public var outputHeight: Int { sizeBox.withLock { $0.1 } }
    public var timestampStats: TimestampStats {
        let n = tsCount.load(ordering: .relaxed)
        return TimestampStats(frames: n,
                              meanDelayMs: n == 0 ? 0 : Double(tsSum.load(ordering: .relaxed)) / Double(n) / 1e6,
                              maxDelayMs: n == 0 ? 0 : Double(tsMax.load(ordering: .relaxed)) / 1e6,
                              minDelayMs: n == 0 ? 0 : Double(tsMin.load(ordering: .relaxed)) / 1e6,
                              fallbackToDisplayTime: fallbackDisplay.load(ordering: .relaxed),
                              fallbackToNow: fallbackNow.load(ordering: .relaxed),
                              idleFrames: idleCount.load(ordering: .relaxed),
                              refreshedFrames: refreshCount.load(ordering: .relaxed))
    }

    /// 屏幕录制权限（不弹提示）。
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public enum ScreenInputError: Error, CustomStringConvertible {
        case notAScreenSource(InputKind)
        case targetNotFound(String)
        public var description: String {
            switch self {
            case .notAScreenSource(let k): "不是屏幕来源：\(k)"
            case .targetNotFound(let t): "找不到采集目标：\(t)"
            }
        }
    }

    private let timingBox: Mutex<ProgramTiming>
    private let slot: any FrameSlot
    private let stateBox = InputStateBox()
    private let countersBox = InputCountersBox()
    private let errorBox = Mutex<String?>(nil)
    private let descriptionBox = Mutex<String?>(nil)
    private let sizeBox = Mutex<(Int, Int)>((0, 0))
    private let sessionQueue: DispatchQueue
    private let captureQueue: DispatchQueue
    private let running = Atomic<Bool>(false)
    private let tsCount = Atomic<UInt64>(0)
    private let tsSum = Atomic<Int64>(0)
    private let tsMax = Atomic<Int64>(Int64.min)
    private let tsMin = Atomic<Int64>(Int64.max)
    private let fallbackDisplay = Atomic<UInt64>(0)
    private let fallbackNow = Atomic<UInt64>(0)
    private let idleCount = Atomic<UInt64>(0)
    private let refreshCount = Atomic<UInt64>(0)
    private let requestedAccess = Atomic<Bool>(false)
    // sessionQueue 私有
    private var stream: SCStream?
    private var building = false
    private var pollTimer: DispatchSourceTimer?
    private var watchdog: NoSignalWatchdog?
    private var generation: UInt64 = 0
    // captureQueue 私有
    private var sequence: UInt64 = 0
    private var frameDuration = HostDuration.zero
    private var color = ColorInfo.sRGBFull
    private var last: LastFrame?
    private var lastPushAt = HostTime.zero
    private var refreshTimer: DispatchSourceTimer?
    private var audioWriter: AudioSampleWriter?

    final class LastFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ b: CVPixelBuffer) { buffer = b }
    }

    public init(number: Int, name: String, target: ScreenTarget, frameRate: FrameRate? = nil, captureAudio: Bool = false,
                timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil, options: Options = Options()) {
        precondition(number >= 1, "输入编号从 1 起")
        self.number = number
        self.name = name
        self.target = target
        self.frameRate = frameRate
        self.captureAudio = captureAudio
        self.options = options
        timingBox = Mutex(timing)
        slot = videoSlot
        self.videoSlot = videoSlot
        self.audioRing = audioRing
        sessionQueue = DispatchQueue(label: "switcher.screen.session.\(number)", qos: .userInitiated)
        captureQueue = DispatchQueue(label: "switcher.screen.capture.\(number)", qos: .userInteractive)
        super.init()
    }

    /// 从 InputSource.screen 构造。
    public convenience init(config: InputConfig, timing: ProgramTiming, videoSlot: any FrameSlot, audioRing: (any AudioRing)? = nil,
                            options: Options = Options()) throws {
        guard case .screen(let target, let fps, let audio) = config.source else { throw ScreenInputError.notAScreenSource(config.source.kind) }
        self.init(number: config.number, name: config.name, target: target, frameRate: fps, captureAudio: audio,
                  timing: timing, videoSlot: videoSlot, audioRing: audioRing, options: options)
    }

    // MARK: 生命周期

    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.async { [self] in
            attempt()
            startPolling()
        }
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        sessionQueue.sync { [self] in
            pollTimer?.cancel()
            pollTimer = nil
            teardown()
            stateBox.set(.noSignal)
        }
    }

    // MARK: 建 / 拆流（sessionQueue）

    private func attempt() {
        guard running.load(ordering: .acquiring), stream == nil, !building else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !requestedAccess.exchange(true, ordering: .acquiringAndReleasing) {
                _ = CGRequestScreenCaptureAccess()   // 只请求一次：弹系统提示 / 打开系统设置
            }
            setError("屏幕录制权限被拒。打开 系统设置 › 隐私与安全性 › 屏幕录制与系统录音，允许本程序后会自动恢复，不用重启。")
            return
        }
        building = true
        generation += 1
        let gen = generation
        let timing = self.timing
        let target = self.target
        Task.detached { [self] in
            do {
                let (filter, srcW, srcH, desc) = try await ScreenTargets.resolve(target)
                let cfg = makeConfiguration(sourceWidth: srcW, sourceHeight: srcH, timing: timing)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                if cfg.capturesAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
                try await s.startCapture()
                sessionQueue.async { [self] in
                    building = false
                    guard running.load(ordering: .acquiring), gen == generation else {
                        Task { try? await s.stopCapture() }
                        return
                    }
                    installStream(s, configuration: cfg, description: desc)
                }
            } catch {
                sessionQueue.async { [self] in
                    building = false
                    let e = error as NSError
                    if e.domain == SCStreamErrorDomain && e.code == -3801 {
                        setError("屏幕录制权限被拒（\(e.localizedDescription)）。打开 系统设置 › 隐私与安全性 › 屏幕录制与系统录音，允许本程序后会自动恢复。")
                    } else {
                        setError("屏幕采集流建立失败：\(error)，将重试")
                    }
                }
            }
        }
    }

    private func makeConfiguration(sourceWidth: Int, sourceHeight: Int, timing: ProgramTiming) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let maxW = options.maxWidth ?? timing.format.width
        let maxH = options.maxHeight ?? timing.format.height
        var w = max(sourceWidth, 2), h = max(sourceHeight, 2)
        if w > maxW || h > maxH {
            let scale = min(Double(maxW) / Double(w), Double(maxH) / Double(h))
            w = max(2, Int((Double(w) * scale).rounded(.down)))
            h = max(2, Int((Double(h) * scale).rounded(.down)))
        }
        w &= ~1; h &= ~1
        cfg.width = w
        cfg.height = h
        cfg.pixelFormat = options.pixelFormat
        let fps = (frameRate ?? timing.format.frameRate).framesPerSecond
        cfg.minimumFrameInterval = CMTime(value: fps.denominator, timescale: Int32(clamping: fps.numerator))
        cfg.queueDepth = max(3, min(8, options.queueDepth))
        cfg.showsCursor = options.showsCursor
        if options.pixelFormat == kCVPixelFormatType_32BGRA {
            cfg.colorSpaceName = CGColorSpace.sRGB
        } else {
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        if let ring = audioRing, captureAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = AudioFormat.sampleRate
            cfg.channelCount = min(max(ring.channelCount, 1), 2)
            cfg.excludesCurrentProcessAudio = true
        }
        return cfg
    }

    private func installStream(_ s: SCStream, configuration cfg: SCStreamConfiguration, description: String) {
        let timing = self.timing
        let fps = (frameRate ?? timing.format.frameRate).approximateFramesPerSecond
        let interval = HostDuration(seconds: 1 / max(fps, 1))
        let refreshInterval = timing.frameDuration
        captureQueue.sync { [self] in
            sequence = 0
            frameDuration = interval
            color = options.pixelFormat == kCVPixelFormatType_32BGRA ? .sRGBFull : .bt709Limited
            last = nil
            lastPushAt = .zero
            audioWriter = (cfg.capturesAudio ? audioRing : nil).map { AudioSampleWriter(ring: $0) }
            refreshTimer?.cancel()
            refreshTimer = nil
            if options.refreshWhenIdle {
                let t = DispatchSource.makeTimerSource(queue: captureQueue)
                let ns = Int(max(refreshInterval.nanoseconds, 1_000_000))
                t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .nanoseconds(ns / 4))
                t.setEventHandler { [weak self] in self?.refreshIfIdle() }
                refreshTimer = t
                t.resume()
            }
        }
        let wd = NoSignalWatchdog(expectedInterval: max(interval, refreshInterval), multiplier: options.noSignalMultiplier, queue: sessionQueue) { [weak self] present in
            guard let self, running.load(ordering: .acquiring), stream != nil else { return }
            if present {
                errorBox.withLock { $0 = nil }
                stateBox.set(.live)
            } else {
                errorBox.withLock { $0 = "屏幕采集没有新帧（超过 \(options.noSignalMultiplier) 个帧间隔）" }
                stateBox.set(.noSignal)
            }
        }
        watchdog = wd
        stream = s
        descriptionBox.withLock { $0 = description }
        sizeBox.withLock { $0 = (cfg.width, cfg.height) }
        errorBox.withLock { $0 = nil }
        countersBox.rebuilds.add(1, ordering: .relaxed)
        wd.start()
    }

    private func teardown() {
        watchdog?.stop()
        watchdog = nil
        generation += 1
        if let s = stream {
            let done = DispatchSemaphore(value: 0)
            Task { try? await s.stopCapture(); done.signal() }
            _ = done.wait(timeout: .now() + 3)
        }
        stream = nil
        captureQueue.sync { [self] in
            refreshTimer?.cancel()
            refreshTimer = nil
            last = nil
            audioWriter = nil
        }
    }

    private func setError(_ message: String) {
        errorBox.withLock { $0 = message }
        stateBox.set(.error(message: message))
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        let ns = Int(max(options.pollInterval.nanoseconds, 100_000_000))
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, running.load(ordering: .acquiring), stream == nil, !building else { return }
            attempt()
        }
        pollTimer = t
        t.resume()
    }

    // MARK: 采集回调（captureQueue）

    private func handleVideo(_ sb: CMSampleBuffer) {
        countersBox.framesReceived.add(1, ordering: .relaxed)
        var status = SCFrameStatus.complete
        var displayTime: UInt64 = 0
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let a = atts.first {
            if let s = a[.status] as? Int, let st = SCFrameStatus(rawValue: s) { status = st }
            if let t = a[.displayTime] as? UInt64 { displayTime = t }
        }
        guard status == .complete || status == .started, let pb = CMSampleBufferGetImageBuffer(sb), CVPixelBufferGetIOSurface(pb) != nil else {
            if status == .idle { idleCount.add(1, ordering: .relaxed) } else { countersBox.framesRejected.add(1, ordering: .relaxed) }
            return
        }
        let now = HostClock.now()
        var pts = HostTime(hostClockTime: CMSampleBufferGetPresentationTimeStamp(sb))
        let oneSecond = HostDuration(seconds: 1)
        if (now - pts).magnitude > oneSecond {
            if displayTime != 0, (now - HostTime(ticks: displayTime)).magnitude <= oneSecond {
                pts = HostTime(ticks: displayTime)
                fallbackDisplay.add(1, ordering: .relaxed)
            } else {
                pts = now
                fallbackNow.add(1, ordering: .relaxed)
            }
        }
        if pts > now { pts = now }
        push(pb, pts: pts, ingress: now)
        watchdog?.noteFrame(at: now)
        let d = (now - pts).nanoseconds
        tsCount.add(1, ordering: .relaxed)
        tsSum.add(d, ordering: .relaxed)
        _ = tsMax.max(d, ordering: .relaxed)
        _ = tsMin.min(d, ordering: .relaxed)
    }

    @inline(__always)
    private func push(_ pb: CVPixelBuffer, pts: HostTime, ingress: HostTime) {
        sequence += 1
        countersBox.surfaces.note(pb)
        slot.push(Frame(pixelBuffer: pb, pts: pts, duration: frameDuration, color: color, inputNumber: number, sequence: sequence, ingressTime: ingress))
        countersBox.framesPushed.add(1, ordering: .relaxed)
        last = LastFrame(pb)
        lastPushAt = ingress
    }

    /// 定时器（采集队列）：上一拍以来没新帧就把最后一帧重推。
    private func refreshIfIdle() {
        guard let l = last else { return }
        let now = HostClock.now()
        guard now - lastPushAt >= timing.frameDuration - HostDuration(milliseconds: 1) else { return }
        push(l.buffer, pts: now, ingress: now)
        refreshCount.add(1, ordering: .relaxed)
        watchdog?.noteFrame(at: now)
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let w = audioWriter else { return }
        let now = HostClock.now()
        var t = HostTime(hostClockTime: CMSampleBufferGetPresentationTimeStamp(sb))
        if (now - t).magnitude > HostDuration(seconds: 1) { t = now }
        let frames = CMSampleBufferGetNumSamples(sb)
        let n = w.write(sampleBuffer: sb, hostTime: t)
        countersBox.audioBlocksWritten.add(1, ordering: .relaxed)
        countersBox.audioFramesWritten.add(UInt64(n), ordering: .relaxed)
        if n < frames { countersBox.audioFramesRejected.add(UInt64(frames - n), ordering: .relaxed) }
    }
}

extension ScreenInput: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer)
        default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        sessionQueue.async { [self] in
            guard running.load(ordering: .acquiring), stream === self.stream else { return }
            self.stream = nil
            watchdog?.stop()
            watchdog = nil
            captureQueue.sync { [self] in refreshTimer?.cancel(); refreshTimer = nil; last = nil }
            errorBox.withLock { $0 = "屏幕采集流停止：\(error.localizedDescription)，将重试" }
            stateBox.set(.noSignal)
        }
    }
}
