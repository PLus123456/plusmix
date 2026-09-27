import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 虚拟摄像头输出 = PGM 帧的消费者（设计方案 §3.4、§8）：`consume` 在引擎派发线程只入有界队列（满了丢最旧）立即返回；
/// 自己的线程把 NV12 IOSurface 包成 CMSampleBuffer（PTS = 拍点时刻，不拷像素，挂 CMIO 序号）经 sink（`CMIOSinkStreamClient`）
/// 排进扩展的 sink stream。帧率跟节目（每个 PGM 帧送一次）。扩展没装 / 没激活时找不到设备：状态 `.searching`，每秒重试一次，
/// 期间的帧丢掉计数；连上之后连续 `sinkLossThreshold` 帧排不进（扩展停了 / 被卸载）就关掉重找。
/// 统计：`counters` 与 `Stats.display[]` 的一项（`statsEntry`，提案 013；W3-C2 复核了 dropped 与 state 的口径）。
public final class VirtualCameraOutput: FrameConsumer, @unchecked Sendable {
    /// 状态。
    public enum State: Hashable, Sendable {
        case idle
        /// 在找设备（扩展没装 / 没激活 / 刚拔）。
        case searching
        /// 已连上 sink stream，正在送。
        case connected
        case stopped
    }

    /// 计数（值快照）。
    public struct Counters: Hashable, Sendable {
        /// 收到的 PGM 帧。
        public var framesIn: UInt64 = 0
        /// 排进 sink stream 的帧。
        public var framesSent: UInt64 = 0
        /// 连着的时候本对象的有界队列满了挤掉的。
        public var droppedQueueFull: UInt64 = 0
        /// 没连上（扩展没装 / 没激活 / 连不上）时丢的——含那段时间队列满挤掉的。
        public var droppedNoDevice: UInt64 = 0
        /// sink stream 队列满 / 排队失败丢的（扩展没及时取走）。
        public var droppedSink: UInt64 = 0
        /// 扩展收了却没输出的（CMIO"已输出"通知的序号跳过数，`ScheduledOutputTracker`）。扩展不回报时恒 0。
        public var droppedExtension: UInt64 = 0
        /// 扩展回报已输出的帧。
        public var framesOutput: UInt64 = 0
        /// 扩展在回报（"已输出"通知注册上了）。
        public var extensionReports = false
        /// 扩展回报里对不上的（序号不是本连接排过的，见 `SinkOutputReport.unmatched`）；不进 dropped。
        public var extensionUnmatched: UInt64 = 0
        /// 找设备的次数。
        public var connectAttempts: UInt64 = 0
        /// 连上之后因为连续排不进而关掉重找的次数。
        public var sinkLosses: UInt64 = 0
        /// 最近一次没连上 / 断开的原因（连上了清掉）。
        public var lastFailure: ConnectionFailure?
        public init() {}
    }

    /// 没连上 / 断开的原因（W3-C3：以前是包拼好的中文句子；包只给枚举，文字由组装方查表）。
    public enum ConnectionFailure: Hashable, Sendable {
        /// 打开 sink 失败：CMIO 客户端的错误（deviceNotFound = 扩展没装 / 没激活 → waitingExtension；其余 = 设备在但连不上 → failed）。
        case open(CMIOSinkStreamClient.Error)
        /// 打开时抛了别的错误（不是 CMIO 客户端的 sink，例如测试的假 sink）：错误的调试描述，只给日志。
        case openOther(String)
        /// 连上之后连续 `frames` 帧排不进 sink（扩展停了 / 被卸载），已关掉重找。
        case sinkStalled(frames: Int)
    }

    public let consumerName: String
    /// 找不到设备时多久重试一次。
    public var retryInterval = HostDuration(seconds: 1)
    /// 连上之后连续这么多帧排不进 sink 就当扩展没了（停了 / 被卸载），关掉重找；默认 = 节目一秒的帧数。
    public var sinkLossThreshold: Int
    private let sink: any VirtualCameraSink
    private let frameDuration: CMTime
    private let queue: FrameQueue
    private let wakeup = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stateValue: State = .idle
    private var counters = Counters()
    private var thread: Thread?
    private var stopRequested = false
    private let accepting = Atomic<Bool>(false)
    private let group = DispatchGroup()
    private var formatDescription: CMVideoFormatDescription?
    private var formatKey: (OSType, Int, Int) = (0, 0, 0)
    private var lastAttempt: HostTime = .zero
    /// 没连上时是在等扩展（找不到设备 / 还没找过 / 刚掉线）还是设备在但连不上；由 lock 保护。
    private var waitingForExtension = true
    // 以下只在本对象的线程上碰
    private var nextSequence: UInt64 = 0
    private var consecutiveSendFailures = 0

    /// 默认的 sink = CoreMediaIO 客户端（按设备 UID 找扩展的设备）。
    public convenience init(format: ProgramFormat, deviceUID: String = VirtualCameraConstants.deviceUID, queueDepth: Int = 3, name: String = "virtual-camera") {
        self.init(format: format, sink: CMIOSinkStreamClient(deviceUID: deviceUID), queueDepth: queueDepth, name: name)
    }

    /// 指定 sink（测试给假的）。
    public init(format: ProgramFormat, sink: any VirtualCameraSink, queueDepth: Int = 3, name: String = "virtual-camera") {
        consumerName = name
        self.sink = sink
        frameDuration = format.frameDuration.cmTime
        queue = FrameQueue(capacity: queueDepth)
        sinkLossThreshold = max(1, format.frameRate.nominalFramesPerSecond)
    }

    public var state: State { lock.withLock { stateValue } }
    public var countersSnapshot: Counters { lock.withLock { counters } }

    /// 这个虚拟摄像头在 Stats 里的一项（提案 013，铁律 4：菜单 / API / 测试读同一个结构；W3-C2 复核）：
    /// - frames = 排进 sink stream 的帧（= 扩展收到的）；
    /// - dropped = "被扩展丢弃"（契约注释）= 连着的时候丢的：本对象队列满挤掉的 + 排不进 sink 的（扩展没及时取）+ 扩展收了没输出的
    ///   （CMIO"已输出"通知的序号跳过数；扩展侧 BLOCKED-签名、还没回报时为 0）。**不含**没连上时丢的；
    /// - undelivered（提案 018）= 没连上（扩展没装 / 没激活 / 连不上 / 刚掉线）期间收到就丢掉的帧 = `countersSnapshot.droppedNoDevice`；
    /// - state：idle → "idle"；searching → 找不到设备（扩展没装 / 没激活 / 刚掉线）"waitingExtension"，设备在但连不上（sink 流没了、
    ///   起流被拒）"failed"（仍在按间隔重试）；connected → "publishing"；stopped → "stopped"。
    public func statsEntry(output: Int) -> Stats.DisplayEntry {
        let (c, st, waiting) = lock.withLock { (counters, stateValue, waitingForExtension) }
        let name: String
        switch st {
        case .idle: name = "idle"
        case .searching: name = waiting ? "waitingExtension" : "failed"
        case .connected: name = "publishing"
        case .stopped: name = "stopped"
        }
        return Stats.DisplayEntry(output: output, kind: "virtualCamera", frames: c.framesSent,
                                  dropped: c.droppedQueueFull &+ c.droppedSink &+ c.droppedExtension,
                                  undelivered: c.droppedNoDevice, state: name)
    }

    /// 起线程；找设备在线程上做（找不到不算错）。
    public func start() {
        lock.withLock {
            guard thread == nil else { return }
            stopRequested = false
            stateValue = .searching
            group.enter()
            let t = Thread { [weak self] in
                self?.loop()
                self?.group.leave()
            }
            t.name = "switcher.virtual-camera"
            t.qualityOfService = .userInteractive
            thread = t
            accepting.store(true, ordering: .releasing)
            t.start()
        }
    }

    /// 停：不再收帧，线程退出，关流。
    public func stop() {
        let t: Thread? = lock.withLock {
            guard thread != nil else { return nil }
            stopRequested = true
            return thread
        }
        guard t != nil else { return }
        accepting.store(false, ordering: .releasing)
        wakeup.signal()
        group.wait()
        lock.withLock {
            thread = nil
            stateValue = .stopped
        }
    }

    // MARK: FrameConsumer

    public func consume(_ frame: RenderedFrame) {
        guard accepting.load(ordering: .acquiring) else { return }
        let evicted = queue.push(frame)
        lock.withLock {
            counters.framesIn += 1
            if evicted != nil {
                if stateValue == .connected { counters.droppedQueueFull += 1 } else { counters.droppedNoDevice += 1 }
            }
        }
        wakeup.signal()
    }

    // MARK: 线程

    private func loop() {
        while true {
            wakeup.wait()
            if lock.withLock({ stopRequested }) { break }
            while let frame = queue.pop() {
                if !sink.isOpen { tryConnect() }
                guard sink.isOpen else {
                    lock.withLock { counters.droppedNoDevice += 1 }
                    continue
                }
                send(frame)
            }
        }
        queue.removeAll()
        sink.close()
    }

    /// 送一帧：挂 CMIO 序号（每个连接从 0 连续，排不进的不占号）→ 排进 sink；同步扩展的回报；连续排不进就当扩展没了。
    private func send(_ frame: RenderedFrame) {
        var ok = false
        if let sb = try? makeSampleBuffer(frame.program, tickTime: frame.tickTime) {
            CMIOSequenceNumber.set(sb, nextSequence)
            ok = sink.send(sb)
        }
        if ok {
            nextSequence &+= 1
            consecutiveSendFailures = 0
        } else {
            consecutiveSendFailures += 1
        }
        let report = sink.extensionReport
        lock.withLock {
            if ok { counters.framesSent += 1 } else { counters.droppedSink += 1 }
            if let report {
                counters.extensionReports = true
                counters.framesOutput = report.output
                counters.droppedExtension = report.dropped
                counters.extensionUnmatched = report.unmatched
            }
        }
        if consecutiveSendFailures >= sinkLossThreshold {
            sink.close()
            consecutiveSendFailures = 0
            lock.withLock {
                stateValue = .searching
                waitingForExtension = true
                counters.sinkLosses += 1
                counters.lastFailure = .sinkStalled(frames: sinkLossThreshold)
            }
        }
    }

    private func tryConnect() {
        let now = HostClock.now()
        guard now - lastAttempt >= retryInterval else { return }
        lastAttempt = now
        lock.withLock { counters.connectAttempts += 1 }
        do {
            try sink.open()
            nextSequence = 0
            consecutiveSendFailures = 0
            lock.withLock {
                stateValue = .connected
                waitingForExtension = false
                counters.lastFailure = nil
            }
        } catch {
            let clientError = error as? CMIOSinkStreamClient.Error
            lock.withLock {
                stateValue = .searching
                waitingForExtension = clientError == .deviceNotFound
                counters.lastFailure = clientError.map(ConnectionFailure.open) ?? .openOther(String(reflecting: error))
            }
        }
    }

    /// PGM 帧 → CMSampleBuffer：不拷像素，PTS = 拍点时刻，时长 = 一帧。格式描述按（格式、宽、高）缓存。
    public func makeSampleBuffer(_ frame: Frame, tickTime: HostTime) throws -> CMSampleBuffer {
        let pb = frame.pixelBuffer
        let key = (CVPixelBufferGetPixelFormatType(pb), CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        if formatDescription == nil || formatKey != key {
            var fd: CMVideoFormatDescription?
            let st = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
            guard st == noErr, let fd else { throw ConversionError.formatDescription(st) }
            formatDescription = fd
            formatKey = key
        }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: tickTime.cmTime, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: formatDescription!,
                                                          sampleTiming: &timing, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw ConversionError.sampleBuffer(st) }
        return sb
    }

    /// 转换错误。
    public enum ConversionError: Swift.Error, Equatable {
        case formatDescription(OSStatus)
        case sampleBuffer(OSStatus)
    }
}

/// 有界帧队列（与 SwitcherOutputs 的 BoundedFrameQueue 同一做法，那个是模块内部的）：满了返回被挤掉的最旧帧，调用方在锁外释放。
final class FrameQueue: @unchecked Sendable {
    let capacity: Int
    private let lock = OSAllocatedUnfairLock()
    private var slots: [RenderedFrame?]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity >= 1)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    func push(_ frame: RenderedFrame) -> RenderedFrame? {
        lock.lock()
        defer { lock.unlock() }
        var evicted: RenderedFrame?
        if count == capacity {
            evicted = slots[head]
            slots[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        slots[(head + count) % capacity] = frame
        count += 1
        return evicted
    }

    func pop() -> RenderedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let f = slots[head]
        slots[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return f
    }

    @discardableResult
    func removeAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = count
        for i in slots.indices { slots[i] = nil }
        head = 0
        count = 0
        return n
    }
}
