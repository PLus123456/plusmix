// AudioRingImpl.swift —— 契约 `AudioRing` 协议的实现：包一个 C 布局的 sw_audio_ring（CSwitcherAudioRT 读写，CSwitcherAudioHost 分配）。
//
// 线程规则（契约 Slots.swift）：write 只能由该输入的采集线程调，read 只能由混音 / 离线工装线程调；
// 两者都不锁、不分配、不日志。混音热路径不经过这个类：拿 `raw` 直接读。
import SwitcherContracts
import CSwitcherAudioRT
import CSwitcherAudioHost

/// 每路输入一个的 SPSC 音频环。`capacityFrames` / `stampCapacity` 向上取到 2 的幂。
public final class CAudioRing: AudioRing, @unchecked Sendable {
    /// C 环本体（64 字节对齐，Host target 分配）。
    public let raw: UnsafeMutablePointer<sw_audio_ring>
    /// 每帧 host tick 数（读时把 stamp 外推成首帧 host time 用）。
    public let hostTicksPerFrame: Double

    /// - Parameters:
    ///   - channelCount: 1 … AudioFormat.maxChannels
    ///   - capacityFrames: 容量（帧），默认 16384（341 ms）；会向上取到 2 的幂
    ///   - stampCapacity: stamp 条数，默认 256；每写一块加一条，所以要 ≥ 容量 / 最小块大小
    public init(channelCount: Int, capacityFrames: Int = 16_384, stampCapacity: Int = 256,
                timebase: MachTimebase = HostClock.timebase) {
        precondition((1...AudioFormat.maxChannels).contains(channelCount), "声道数 1…\(AudioFormat.maxChannels)")
        precondition(capacityFrames > 0 && stampCapacity > 0)
        guard let p = sw_audio_ring_create(UInt32(channelCount), UInt32(capacityFrames), UInt32(stampCapacity)) else {
            fatalError("sw_audio_ring_create 失败（内存不足）")
        }
        raw = p
        hostTicksPerFrame = Double(timebase.denom) * 1e9 / (Double(timebase.numer) * Double(AudioFormat.sampleRate))
    }

    deinit { sw_audio_ring_destroy(raw) }

    public var channelCount: Int { Int(raw.pointee.channels) }
    public var sampleRate: Int { Int(raw.pointee.sample_rate) }
    public var capacityFrames: Int { Int(raw.pointee.capacity_frames) }
    /// stamp 条数。
    public var stampCapacity: Int { Int(raw.pointee.stamp_capacity) }
    public var availableFrames: Int { Int(sw_audio_ring_available(raw)) }
    /// 可写帧数。
    public var freeFrames: Int { Int(sw_audio_ring_free_space(raw)) }

    public var stats: AudioRingStats {
        AudioRingStats(framesWritten: atomicLoad(&raw.pointee.write_index),
                       framesRead: atomicLoad(&raw.pointee.read_index),
                       overruns: atomicLoad(&raw.pointee.overruns),
                       underruns: atomicLoad(&raw.pointee.underruns))
    }

    @discardableResult
    public func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
        // C 侧是 `const float *const *`，Swift 导成 UnsafePointer<UnsafePointer<Float>?>；指针布局相同，重绑定
        let p = UnsafeRawPointer(planes).assumingMemoryBound(to: UnsafePointer<Float>?.self)
        return Int(sw_audio_ring_write(raw, p, UInt32(frameCount), hostTime.ticks))
    }

    public func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult {
        var first: UInt64 = 0
        var valid = false
        let p = UnsafeRawPointer(planes).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
        let n = sw_audio_ring_read(raw, p, UInt32(frameCount), hostTicksPerFrame, &first, &valid)
        return AudioReadResult(framesRead: Int(n), firstFrameHostTime: valid ? HostTime(ticks: first) : nil)
    }

    /// 最近一条 stamp。
    public var latestStamp: (frameIndex: UInt64, hostTime: HostTime)? {
        var s = sw_audio_stamp()
        guard sw_audio_ring_latest_stamp(raw, &s) else { return nil }
        return (s.frame_index, HostTime(ticks: s.host_time))
    }

    /// 累计帧序号对应的 host time（按 stamp 外推）。
    public func hostTime(ofFrame frameIndex: UInt64) -> HostTime? {
        var t: UInt64 = 0
        guard sw_audio_ring_host_time_of(raw, frameIndex, hostTicksPerFrame, &t) else { return nil }
        return HostTime(ticks: t)
    }

    // 方便测试 / 工装：用 Swift 数组读写
    /// 写一块（每个数组一个声道，长度相同）。
    @discardableResult
    public func write(_ channels: [[Float]], hostTime: HostTime) -> Int {
        precondition(channels.count == channelCount)
        let n = channels.first?.count ?? 0
        return withPlanePointers(channels) { ptrs in write(planes: ptrs, frameCount: n, hostTime: hostTime) }
    }

    /// 读一块成数组。
    public func read(frameCount: Int) -> (planes: [[Float]], result: AudioReadResult) {
        let n = channelCount
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frameCount) * n)
        defer { storage.deallocate() }
        var ptrs = (0..<n).map { storage + $0 * frameCount }
        let result = ptrs.withUnsafeMutableBufferPointer { read(into: UnsafePointer($0.baseAddress!), frameCount: frameCount) }
        let planes = (0..<n).map { Array(UnsafeBufferPointer(start: storage + $0 * frameCount, count: frameCount)) }
        return (planes, result)
    }

    private func withPlanePointers<R>(_ channels: [[Float]], _ body: (UnsafePointer<UnsafePointer<Float>>) -> R) -> R {
        var ptrs = [UnsafePointer<Float>]()
        ptrs.reserveCapacity(channels.count)
        func recurse(_ i: Int) -> R {
            if i == channels.count {
                return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
            }
            return channels[i].withUnsafeBufferPointer { buf in
                ptrs.append(buf.baseAddress!)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }
}

@inline(__always)
func atomicLoad(_ p: UnsafeMutablePointer<UInt64>) -> UInt64 { sw_atomic_load_u64(p) }
