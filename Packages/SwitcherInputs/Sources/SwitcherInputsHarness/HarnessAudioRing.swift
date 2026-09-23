import CSwitcherContracts
import Foundation
import Synchronization
import SwitcherContracts

/// 组装方给的音频环（契约 §2.3 的"注入规则"：输入不自己 new 环）。
///
/// 真正跑在产品里的环是 SwitcherAudio（W1-D）的 C 实现；`SwitcherInputs` 这个包按依赖方向看不到它，
/// 所以探针和测试自己带一个同口径的：float32 非交错、48 kHz、SPSC、每块带 host time、满了记 overruns、
/// 读不够补零记 underruns。另外把每块的 (累计帧序号, 帧数, host time) 记进一张预分配的表，
/// 供 A1 / A2 检查块连续性与时间戳（只有生产者写这张表，读方按原子计数取快照，不上锁）。
///
/// `raw` 按 `sw_audio_ring.h` 的布局填好常量和平面指针，计数是 Swift 侧状态的镜像；
/// 本会话没有 C 混音热路径跑在它上面（那是 W1-D 的环），所以镜像够用。
public final class HarnessAudioRing: AudioRing, @unchecked Sendable {
    /// 一块的记录。
    public struct BlockRecord: Hashable, Sendable {
        /// 本块第一帧的累计帧序号。
        public var frameIndex: UInt64
        /// 帧数。
        public var frameCount: Int
        /// 块首帧的 host time。
        public var hostTime: HostTime
    }

    public let channelCount: Int
    public let sampleRate = AudioFormat.sampleRate
    public let capacityFrames: Int
    public let raw: UnsafeMutablePointer<sw_audio_ring>

    private let planes: [UnsafeMutablePointer<Float>]
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let overrunFrames = Atomic<UInt64>(0)
    private let underrunFrames = Atomic<UInt64>(0)
    private let logCount = Atomic<UInt64>(0)
    private let log: UnsafeMutablePointer<BlockRecord>
    private let logCapacity: Int

    /// - Parameters:
    ///   - capacityFrames: 2 的幂；默认 1 << 16 ≈ 1.37 s @ 48 kHz。
    ///   - logCapacity: 记录多少块（够 60 s 的 A1；满了就只计数不记）。
    public init(channelCount: Int = 2, capacityFrames: Int = 1 << 16, logCapacity: Int = 1 << 17) {
        precondition(channelCount >= 1 && channelCount <= AudioFormat.maxChannels)
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0, "容量必须是 2 的幂")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.logCapacity = logCapacity
        var allocated: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<channelCount {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            allocated.append(p)
        }
        planes = allocated
        log = .allocate(capacity: logCapacity)
        log.initialize(repeating: BlockRecord(frameIndex: 0, frameCount: 0, hostTime: .zero), count: logCapacity)
        let stampCapacity = 1 << 12
        let stamps = UnsafeMutablePointer<sw_audio_stamp>.allocate(capacity: stampCapacity)
        stamps.initialize(repeating: sw_audio_stamp(), count: stampCapacity)
        raw = .allocate(capacity: 1)
        raw.initialize(to: sw_audio_ring())
        raw.pointee.layout_version = SW_AUDIO_RING_LAYOUT_VERSION
        raw.pointee.channels = UInt32(channelCount)
        raw.pointee.sample_rate = UInt32(AudioFormat.sampleRate)
        raw.pointee.capacity_frames = UInt32(capacityFrames)
        raw.pointee.stamp_capacity = UInt32(stampCapacity)
        raw.pointee.stamps = stamps
        withUnsafeMutablePointer(to: &raw.pointee.planes) { table in
            table.withMemoryRebound(to: UnsafeMutablePointer<Float>?.self, capacity: Int(SW_AUDIO_MAX_CHANNELS)) { slots in
                for c in 0..<channelCount { slots[c] = allocated[c] }
            }
        }
    }

    deinit {
        for p in planes { p.deallocate() }
        raw.pointee.stamps?.deallocate()
        log.deallocate()
        raw.deallocate()
    }

    public var availableFrames: Int {
        Int(writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed))
    }

    public var stats: AudioRingStats {
        AudioRingStats(framesWritten: writeIndex.load(ordering: .relaxed),
                       framesRead: readIndex.load(ordering: .relaxed),
                       overruns: overrunFrames.load(ordering: .relaxed),
                       underruns: underrunFrames.load(ordering: .relaxed))
    }

    /// 已经记下的块（按写入顺序）。
    public var blocks: [BlockRecord] {
        let n = Int(min(logCount.load(ordering: .acquiring), UInt64(logCapacity)))
        return (0..<n).map { log[$0] }
    }
    /// 写过的块总数（含没记进表的）。
    public var blockCount: UInt64 { logCount.load(ordering: .acquiring) }

    // MARK: 生产者

    @discardableResult
    public func write(planes source: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacityFrames - Int(w - r)
        let n = min(frameCount, max(free, 0))
        if n < frameCount { overrunFrames.add(UInt64(frameCount - n), ordering: .relaxed) }
        guard n > 0 else { return 0 }
        let position = Int(w & UInt64(capacityFrames - 1))
        let first = min(capacityFrames - position, n)
        for c in 0..<channelCount {
            planes[c].advanced(by: position).update(from: source[c], count: first)
            if n > first { planes[c].update(from: source[c].advanced(by: first), count: n - first) }
        }
        let index = logCount.load(ordering: .relaxed)
        if index < UInt64(logCapacity) {
            log[Int(index)] = BlockRecord(frameIndex: w, frameCount: n, hostTime: hostTime)
        }
        logCount.store(index + 1, ordering: .releasing)
        // raw 的镜像（形状 / 常量正确，计数跟着走）
        let stampCapacity = Int(raw.pointee.stamp_capacity)
        if let stamps = raw.pointee.stamps {
            stamps[Int(raw.pointee.stamp_write) & (stampCapacity - 1)] = sw_audio_stamp(frame_index: w, host_time: hostTime.ticks)
            raw.pointee.stamp_write &+= 1
        }
        writeIndex.store(w + UInt64(n), ordering: .releasing)
        raw.pointee.write_index = w + UInt64(n)
        raw.pointee.overruns = overrunFrames.load(ordering: .relaxed)
        return n
    }

    // MARK: 消费者

    public func read(into destination: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let available = Int(w - r)
        let n = min(frameCount, available)
        let position = Int(r & UInt64(capacityFrames - 1))
        let first = min(capacityFrames - position, max(n, 0))
        for c in 0..<channelCount {
            if n > 0 {
                destination[c].update(from: planes[c].advanced(by: position), count: first)
                if n > first { destination[c].advanced(by: first).update(from: planes[c], count: n - first) }
            }
            if n < frameCount { destination[c].advanced(by: max(n, 0)).update(repeating: 0, count: frameCount - max(n, 0)) }
        }
        if n < frameCount { underrunFrames.add(UInt64(frameCount - n), ordering: .relaxed) }
        var firstHostTime: HostTime?
        if n > 0 { firstHostTime = hostTime(ofFrame: r) }
        if n > 0 {
            readIndex.store(r + UInt64(n), ordering: .releasing)
            raw.pointee.read_index = r + UInt64(n)
        }
        raw.pointee.underruns = underrunFrames.load(ordering: .relaxed)
        return AudioReadResult(framesRead: n, firstFrameHostTime: firstHostTime)
    }

    /// 某个累计帧序号的 host time（按最近一条不晚于它的块记录外推；契约 §2.3 消费者的算法）。
    public func hostTime(ofFrame frameIndex: UInt64) -> HostTime? {
        let n = Int(min(logCount.load(ordering: .acquiring), UInt64(logCapacity)))
        guard n > 0 else { return nil }
        var low = 0, high = n - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if log[mid].frameIndex <= frameIndex { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let record = log[found]
        let ticksPerFrame = Double(HostDuration(seconds: 1).ticks) / Double(AudioFormat.sampleRate)
        return HostTime(ticks: record.hostTime.ticks &+ UInt64((Double(frameIndex - record.frameIndex) * ticksPerFrame).rounded()))
    }
}
