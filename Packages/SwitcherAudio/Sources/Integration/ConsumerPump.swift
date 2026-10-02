import Foundation
import Synchronization
import SwitcherContracts
import SwitcherAudio

// 消费者泵（设计方案 §3.4 / W1-E 报告要求由组装方提供的"非实时泵"）：把混音器消费者队列（实时线程写的 SPSC）里的块搬给
// 各消费者。一个来源（Master / 总线 / 某路输入的 ISO 或节目信号）一个 tap，多个消费者共享（扇出拷贝），tap 数 ≤ 8 不再受消费者数限制。
//
// 每块：PTS = 块首样本 host time − 对齐延迟（= 内容被采集的时刻，与视频拍点同一时基）；真设备时经 HostClockResampler
// 把设备时钟重采样到 host 时钟（PTS 按计数连续）；Master 流顺便做波形不连续检测（A1 第三项）。
// 总线来源（Master / A / B / 耳机）再减去这条总线效果链的延迟（W5-C：已打开的 AU 的前瞻之和，EffectLatencyTimeline 按块序号查）：
// 块里的内容比没开效果时晚这么多采集，PTS 跟着往前挪，A/V 对齐不因开效果漂。延迟变了的那一块按差值拼接，让消费者看到的 PTS 仍连续：
//   变大 Δ：丢掉接下来的 Δ 帧——正是 AU 刚打开时前瞻缓冲垫出来的那一段（打开前 Reset 过，是零）；
//   变小 Δ：先补 Δ 帧静音——关掉 / 缩短前瞻时那 Δ 帧内容还在 AU 的缓冲里，丢了，用静音占住时间轴。
// 输入来源（ISO / 节目信号）不经总线效果，不补。
final class ConsumerPump: @unchecked Sendable {
    struct SourceStatus: Hashable, Sendable {
        var source: AudioTapSource
        var consumers: [String]
        var blocksPopped: UInt64
        var framesDelivered: UInt64
        var tapDropped: UInt64
        var resampler: HostClockResampler.Snapshot?
        var discontinuities: UInt64
        var latencyFrames: Int
        var latencyFramesDropped: UInt64
        var latencyFramesInserted: UInt64
    }

    private final class Source {
        let key: AudioTapSource
        let tap: AudioBlockTap
        var consumers: [(token: AudioConsumerToken, consumer: any AudioBlockConsuming)] = []
        var resampler: HostClockResampler?
        var detector: DiscontinuityDetector?
        var blocksPopped: UInt64 = 0
        var framesDelivered: UInt64 = 0
        /// 总线来源的总线（效果链延迟按它查）；输入来源 nil。
        let bus: Bus?
        /// 上一块用的效果链延迟（帧）；nil = 还没出过块。
        var appliedLatency: Int?
        /// 还要丢的帧（延迟变大时）。
        var pendingDrop = 0
        var droppedFrames: UInt64 = 0
        var insertedFrames: UInt64 = 0
        init(key: AudioTapSource, tap: AudioBlockTap) {
            self.key = key; self.tap = tap
            switch key {
            case .master: bus = .master
            case .bus(let b): bus = b
            case .input, .inputProgram: bus = nil
            }
        }
    }

    private let mixer: AudioMixer
    private let alignment: HostDuration
    private let latency: EffectLatencyTimeline
    private let ticksPerFrame: Double
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
    /// 丢掉块头若干帧后，余下部分的平面指针。
    private let offsetPlanes: UnsafeMutablePointer<UnsafePointer<Float>>
    /// 补静音用：maxFrames 个零，每个声道都指向它。
    private let silence: UnsafeMutablePointer<Float>
    private let silencePlanes: UnsafeMutablePointer<UnsafePointer<Float>>
    /// 到目前为止检出的不连续（所有来源之和）。
    private let discontinuityTotal = Atomic<UInt64>(0)

    init(mixer: AudioMixer, alignment: HostDuration, latency: EffectLatencyTimeline, resample: Bool, detectDiscontinuities: Bool, period: HostDuration,
         tapCapacity: Int, timebase: MachTimebase) {
        self.mixer = mixer
        self.alignment = alignment
        self.latency = latency
        ticksPerFrame = mixer.hostTicksPerFrame
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
        offsetPlanes = .allocate(capacity: channels)
        silence = .allocate(capacity: maxFrames)
        silence.initialize(repeating: 0, count: maxFrames)
        silencePlanes = .allocate(capacity: channels)
        for c in 0..<channels {
            mutablePlanes[c] = storage + c * maxFrames
            constPlanes[c] = UnsafePointer(storage + c * maxFrames)
            offsetPlanes[c] = UnsafePointer(storage + c * maxFrames)
            silencePlanes[c] = UnsafePointer(silence)
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
        offsetPlanes.deallocate()
        silencePlanes.deallocate()
        silence.deallocate()
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
                tapSource = .inputPreAFV(slot: slot)
            case .inputProgram(let n):
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

    /// 设备换了：所有来源的重采样器重建（下一块起重新测速率、重新锚定 PTS；录制器会看到一次跳变并硬校正一次）。
    func resetResamplers() {
        lock.lock(); defer { lock.unlock() }
        guard resample else { return }
        for (_, s) in sources { s.resampler = HostClockResampler(channels: channels, timebase: timebase) }
    }

    var statuses: [SourceStatus] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.map {
            SourceStatus(source: $0.key, consumers: $0.consumers.map { $0.consumer.consumerName }, blocksPopped: $0.blocksPopped,
                         framesDelivered: $0.framesDelivered, tapDropped: $0.tap.dropped, resampler: $0.resampler?.snapshot,
                         discontinuities: $0.detector?.count ?? 0, latencyFrames: $0.appliedLatency ?? 0,
                         latencyFramesDropped: $0.droppedFrames, latencyFramesInserted: $0.insertedFrames)
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
                let lat = src.bus.map { latency.frames($0, atBlock: block.sequence) } ?? 0
                var pts = block.hostTime - alignment - duration(frames: lat)
                if let applied = src.appliedLatency, applied != lat {
                    if lat > applied {
                        src.pendingDrop += lat - applied
                    } else {
                        // 先抵掉还没丢完的，剩下的补静音：补在这一块之前，PTS 接上一块的末尾
                        var insert = applied - lat
                        let cancel = min(insert, src.pendingDrop)
                        src.pendingDrop -= cancel
                        insert -= cancel
                        if insert > 0 { pushSilence(src, frames: insert, before: pts) }
                    }
                }
                src.appliedLatency = lat
                var offset = 0
                if src.pendingDrop > 0 {
                    offset = min(src.pendingDrop, block.frames)
                    src.pendingDrop -= offset
                    src.droppedFrames += UInt64(offset)
                    pts = pts + duration(frames: offset)
                }
                let n = block.frames - offset
                guard n > 0 else { continue }
                if offset == 0 {
                    push(src, planes: constPlanes, frames: n, hostTime: pts)
                } else {
                    for c in 0..<channels { offsetPlanes[c] = UnsafePointer(storage + c * maxFrames + offset) }
                    push(src, planes: offsetPlanes, frames: n, hostTime: pts)
                }
            }
        }
        return moved
    }

    private func duration(frames: Int) -> HostDuration { HostDuration(ticks: Int64((Double(frames) * ticksPerFrame).rounded())) }

    /// 交给重采样器（真设备）或直接交给消费者。
    private func push(_ src: Source, planes: UnsafePointer<UnsafePointer<Float>>, frames: Int, hostTime: HostTime) {
        if let r = src.resampler {
            r.push(planes: planes, frameCount: frames, hostTime: hostTime) { p, n, t in
                deliver(src, planes: p, frames: n, hostTime: t)
            }
        } else {
            deliver(src, planes: planes, frames: frames, hostTime: hostTime)
        }
    }

    /// 在 PTS = before 的那一块之前补 frames 帧静音（PTS 从 before − frames 起）。
    private func pushSilence(_ src: Source, frames: Int, before: HostTime) {
        var left = frames
        var t = before - duration(frames: frames)
        while left > 0 {
            let n = min(left, maxFrames)
            push(src, planes: silencePlanes, frames: n, hostTime: t)
            t = t + duration(frames: n)
            left -= n
        }
        src.insertedFrames += UInt64(frames)
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
