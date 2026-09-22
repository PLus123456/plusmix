import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization
import SwitcherContracts
import SwitcherOutputs

/// 虚拟摄像头输出 = PGM 帧的消费者（设计方案 §3.4、§8）：`consume` 在引擎派发线程只入有界队列（满了丢最旧）立即返回；
/// 自己的线程把 NV12 IOSurface 包成 CMSampleBuffer（PTS = 拍点时刻，不拷像素）经 `CMIOSinkStreamClient` 排进扩展的 sink stream。
/// 帧率跟节目（每个 PGM 帧送一次）。扩展没装 / 没激活时找不到设备：状态 `.searching`，每秒重试一次，期间的帧丢掉计数。
/// 统计：本对象的 `counters`（不是编码器输出，Stats.encoder 没有它的项，见报告 §4）。
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
        /// 队列满丢的（本对象的有界队列）。
        public var droppedQueueFull: UInt64 = 0
        /// 没有设备时丢的。
        public var droppedNoDevice: UInt64 = 0
        /// sink stream 队列满 / 排队失败丢的。
        public var droppedSink: UInt64 = 0
        /// 找设备的次数。
        public var connectAttempts: UInt64 = 0
        /// 最近一次找设备失败的原因。
        public var lastError: String?
        public init() {}
    }

    public let consumerName: String
    /// 找不到设备时多久重试一次。
    public var retryInterval = HostDuration(seconds: 1)
    private let client: CMIOSinkStreamClient
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

    public init(format: ProgramFormat, deviceUID: String = VirtualCameraConstants.deviceUID, queueDepth: Int = 3, name: String = "virtual-camera") {
        consumerName = name
        client = CMIOSinkStreamClient(deviceUID: deviceUID)
        frameDuration = format.frameDuration.cmTime
        queue = FrameQueue(capacity: queueDepth)
    }

    public var state: State { lock.withLock { stateValue } }
    public var countersSnapshot: Counters { lock.withLock { counters } }

    /// 这个虚拟摄像头在 Stats 里的一项（提案 013，铁律 4：菜单 / API / 测试读同一个结构）。
    /// frames = 排进 sink stream 的帧；dropped = 本对象队列满 + 没设备 + sink 队列满丢的三项之和；
    /// state：idle → "idle"、searching → "waitingExtension"（扩展没装 / 没激活 / 刚拔）、connected → "publishing"、stopped → "stopped"。
    public func statsEntry(output: Int) -> Stats.DisplayEntry {
        let (c, st) = lock.withLock { (counters, stateValue) }
        let name: String
        switch st {
        case .idle: name = "idle"
        case .searching: name = "waitingExtension"
        case .connected: name = "publishing"
        case .stopped: name = "stopped"
        }
        return Stats.DisplayEntry(output: output, kind: "virtualCamera", frames: c.framesSent,
                                  dropped: c.droppedQueueFull &+ c.droppedNoDevice &+ c.droppedSink, state: name)
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
            if evicted != nil { counters.droppedQueueFull += 1 }
        }
        wakeup.signal()
    }

    // MARK: 线程

    private func loop() {
        while true {
            wakeup.wait()
            if lock.withLock({ stopRequested }) { break }
            while let frame = queue.pop() {
                if !client.isOpen { tryConnect() }
                guard client.isOpen else {
                    lock.withLock { counters.droppedNoDevice += 1 }
                    continue
                }
                do {
                    let sb = try makeSampleBuffer(frame.program, tickTime: frame.tickTime)
                    let ok = client.send(sb)
                    lock.withLock { if ok { counters.framesSent += 1 } else { counters.droppedSink += 1 } }
                } catch {
                    lock.withLock { counters.droppedSink += 1 }
                }
            }
        }
        queue.removeAll()
        client.close()
    }

    private func tryConnect() {
        let now = HostClock.now()
        guard now - lastAttempt >= retryInterval else { return }
        lastAttempt = now
        lock.withLock { counters.connectAttempts += 1 }
        do {
            try client.open()
            lock.withLock {
                stateValue = .connected
                counters.lastError = nil
            }
        } catch {
            lock.withLock {
                stateValue = .searching
                counters.lastError = "\(error)"
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
