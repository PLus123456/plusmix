import Foundation
import Synchronization
import SwitcherContracts
import SwitcherAudio

// 消费者泵（设计方案 §3.4 / W1-E 报告要求由组装方提供的"非实时泵"）：把混音器消费者队列（实时线程写的 SPSC）里的块搬给
// 各消费者。一个来源（Master / 总线 / 某路输入）一个 tap，多个消费者共享（扇出拷贝），tap 数 ≤ 8 不再受消费者数限制。
//
// 每块：PTS = 块首样本 host time − 对齐延迟（= 内容被采集的时刻，与视频拍点同一时基）；真设备时经 HostClockResampler
// 把设备时钟重采样到 host 时钟（PTS 按计数连续）；Master 流顺便做波形不连续检测（A1 第三项）。
final class ConsumerPump: @unchecked Sendable {
    struct SourceStatus: Hashable, Sendable {
        var source: AudioTapSource
        var consumers: [String]
        var blocksPopped: UInt64
        var framesDelivered: UInt64
        var tapDropped: UInt64
        var resampler: HostClockResampler.Snapshot?
        var discontinuities: UInt64
    }

    private final class Source {
        let key: AudioTapSource
        let tap: AudioBlockTap
        var consumers: [(token: AudioConsumerToken, consumer: any AudioBlockConsuming)] = []
        var resampler: HostClockResampler?
        var detector: DiscontinuityDetector?
        var blocksPopped: UInt64 = 0
        var framesDelivered: UInt64 = 0
        init(key: AudioTapSource, tap: AudioBlockTap) { self.key = key; self.tap = tap }
    }

    private let mixer: AudioMixer
    private let alignment: HostDuration
    let resample: Bool
    private let detectDiscontinuities: Bool
    private let period: HostDuration
    private let timebase: MachTimebase
    private let tapCapacity: Int
    private let lock = NSLock()
    private var sources: [AudioTapSource: Source] = [:]
    private var nextToken: UInt64 = 1
    private var thread: Thread?
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    // 一次分配的弹块缓冲
    private let channels: Int
    private let maxFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let mutablePlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let constPlanes: UnsafeMutablePointer<UnsafePointer<Float>>
    /// 到目前为止检出的不连续（所有来源之和）。
    private let discontinuityTotal = Atomic<UInt64>(0)

    init(mixer: AudioMixer, alignment: HostDuration, resample: Bool, detectDiscontinuities: Bool, period: HostDuration,
         tapCapacity: Int, timebase: MachTimebase) {
        self.mixer = mixer
        self.alignment = alignment
        self.resample = resample
        self.detectDiscontinuities = detectDiscontinuities
        self.period = period
        self.tapCapacity = tapCapacity
        self.timebase = timebase
        channels = 2
        maxFrames = mixer.maxBlockFrames
        storage = .allocate(capacity: channels * maxFrames)
        storage.initialize(repeating: 0, count: channels * maxFrames)
        mutablePlanes = .allocate(capacity: channels)
        constPlanes = .allocate(capacity: channels)
        for c in 0..<channels {
            mutablePlanes[c] = storage + c * maxFrames
            constPlanes[c] = UnsafePointer(storage + c * maxFrames)
        }
    }

    deinit {
        stop()
        lock.lock()
        for (_, s) in sources { mixer.removeTap(s.tap) }
        sources.removeAll()
        lock.unlock()
        mutablePlanes.deallocate()
        constPlanes.deallocate()
        storage.deallocate()
    }

    var discontinuities: UInt64 { discontinuityTotal.load(ordering: .relaxed) }

    // MARK: 注册（任意非实时线程）

    /// 加消费者；来源第一个消费者时向混音器要 tap。`slotOf` 把输入编号换成槽位。
    func add(_ consumer: any AudioBlockConsuming, source: AudioTapSource, slotOf: (Int) -> Int?) throws -> AudioConsumerToken {
        let key = source.normalized
        lock.lock(); defer { lock.unlock() }
        let src: Source
        if let existing = sources[key] {
            src = existing
        } else {
            let tapSource: TapSource
            switch key {
            case .master: tapSource = .bus(.master)
            case .bus(let b): tapSource = .bus(b)
            case .input(let n):
                guard let slot = slotOf(n) else { throw AudioEngineError.inputNotRegistered(n) }
                tapSource = .input(slot: slot)
            }
            guard let tap = mixer.addTap(source: tapSource, capacityBlocks: tapCapacity) else { throw AudioEngineError.tapUnavailable }
            src = Source(key: key, tap: tap)
            if resample { src.resampler = HostClockResampler(channels: channels, timebase: timebase) }
            if detectDiscontinuities && key == .master { src.detector = DiscontinuityDetector(channels: channels) }
            sources[key] = src
        }
        let token = AudioConsumerToken(id: nextToken, source: key)
        nextToken += 1
        src.consumers.append((token, consumer))
        return token
    }

    /// 去掉消费者；来源没人要了就摘 tap。
    func remove(_ token: AudioConsumerToken) {
        lock.lock(); defer { lock.unlock() }
        guard let src = sources[token.source] else { return }
        src.consumers.removeAll { $0.token == token }
        if src.consumers.isEmpty {
            mixer.removeTap(src.tap)
            sources.removeValue(forKey: token.source)
        }
    }

    var statuses: [SourceStatus] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.map {
            SourceStatus(source: $0.key, consumers: $0.consumers.map { $0.consumer.consumerName }, blocksPopped: $0.blocksPopped,
                         framesDelivered: $0.framesDelivered, tapDropped: $0.tap.dropped, resampler: $0.resampler?.snapshot,
                         discontinuities: $0.detector?.count ?? 0)
        }.sorted { "\($0.source)" < "\($1.source)" }
    }

    // MARK: 线程

    func start() {
        guard thread == nil else { return }
        stopFlag.store(false, ordering: .releasing)
        let t = Thread { [self] in loop() }
        t.name = "switcher.audio-pump"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// 停线程；退出前把队列里剩下的块全部搬完。
    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .releasing)
        finished.wait()
        thread = nil
    }

    private func loop() {
        defer { finished.signal() }
        let sleepMicros = UInt32(max(200, period.nanoseconds(timebase: timebase) / 1000))
        while true {
            let stopping = stopFlag.load(ordering: .acquiring)
            runOnce()
            if stopping { break }
            _ = usleep(sleepMicros)
        }
    }

    /// 把所有来源现有的块搬完（泵线程；离线测试直接调）。返回搬了几块。
    @discardableResult
    func runOnce() -> Int {
        lock.lock()
        let list = Array(sources.values)
        lock.unlock()
        var moved = 0
        for src in list {
            while let block = src.tap.pop(into: UnsafePointer(mutablePlanes)) {
                moved += 1
                src.blocksPopped += 1
                let pts = block.hostTime - alignment
                if let r = src.resampler {
                    r.push(planes: constPlanes, frameCount: block.frames, hostTime: pts) { planes, n, t in
                        deliver(src, planes: planes, frames: n, hostTime: t)
                    }
                } else {
                    deliver(src, planes: constPlanes, frames: block.frames, hostTime: pts)
                }
            }
        }
        return moved
    }

    private func deliver(_ src: Source, planes: UnsafePointer<UnsafePointer<Float>>, frames: Int, hostTime: HostTime) {
        if src.detector != nil {
            let added = src.detector!.feed(planes: planes, frameCount: frames)
            if added > 0 { discontinuityTotal.wrappingAdd(UInt64(added), ordering: .relaxed) }
        }
        lock.lock()
        let consumers = src.consumers
        lock.unlock()
        for (_, c) in consumers {
            c.consumeAudio(planes: planes, channelCount: channels, frameCount: frames, hostTime: hostTime)
        }
        src.framesDelivered += UInt64(frames)
    }
}
