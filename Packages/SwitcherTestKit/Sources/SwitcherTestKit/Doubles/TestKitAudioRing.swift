import SwitcherContracts
import Synchronization

/// `AudioRing` 的测试替身：头部按 `sw_audio_ring.h` 的布局真实填写（64 字节对齐分配），planes / stamps 真实存在，
/// 但 write / read 用互斥锁串行化——它只服务 TestKit 的测试；混音热路径用的真环在 SwitcherAudio（W1-D，C）。
/// 读侧口径按契约：不够补零并计 underruns；`firstFrameHostTime` 由最近一条 stamp 外推（每帧按标称 48 kHz 换算）。
public final class TestKitAudioRing: AudioRing, @unchecked Sendable {
    public let channelCount: Int
    public let sampleRate: Int
    public let capacityFrames: Int
    public let raw: UnsafeMutablePointer<sw_audio_ring>

    private let stampCapacity: Int
    private let planeStorage: [UnsafeMutablePointer<Float>]
    private let stampStorage: UnsafeMutablePointer<sw_audio_stamp>
    private let lock = Mutex<Void>(())

    public init(channelCount: Int = 2, capacityFrames: Int = 1 << 16, stampCapacity: Int = 1 << 10) {
        precondition((1...AudioFormat.maxChannels).contains(channelCount))
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0, "容量须为 2 的幂")
        precondition(stampCapacity > 0 && stampCapacity & (stampCapacity - 1) == 0, "stamp 容量须为 2 的幂")
        self.channelCount = channelCount
        sampleRate = AudioFormat.sampleRate
        self.capacityFrames = capacityFrames
        self.stampCapacity = stampCapacity
        let rawMemory = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<sw_audio_ring>.size, alignment: 64)
        rawMemory.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<sw_audio_ring>.size)
        raw = rawMemory.bindMemory(to: sw_audio_ring.self, capacity: 1)
        planeStorage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
        stampStorage = UnsafeMutablePointer<sw_audio_stamp>.allocate(capacity: stampCapacity)
        stampStorage.initialize(repeating: sw_audio_stamp(frame_index: 0, host_time: 0), count: stampCapacity)
        raw.pointee.layout_version = UInt32(SW_AUDIO_RING_LAYOUT_VERSION)
        raw.pointee.channels = UInt32(channelCount)
        raw.pointee.sample_rate = UInt32(sampleRate)
        raw.pointee.capacity_frames = UInt32(capacityFrames)
        raw.pointee.stamp_capacity = UInt32(stampCapacity)
        withUnsafeMutablePointer(to: &raw.pointee.planes) { tuple in
            tuple.withMemoryRebound(to: UnsafeMutablePointer<Float>?.self, capacity: AudioFormat.maxChannels) { arr in
                for c in 0..<channelCount { arr[c] = planeStorage[c] }
            }
        }
        raw.pointee.stamps = stampStorage
    }

    deinit {
        for p in planeStorage { p.deallocate() }
        stampStorage.deallocate()
        UnsafeMutableRawPointer(raw).deallocate()
    }

    public var availableFrames: Int { Int(sw_audio_ring_available(raw)) }

    public var stats: AudioRingStats {
        lock.withLock { _ in
            AudioRingStats(framesWritten: raw.pointee.write_index, framesRead: raw.pointee.read_index,
                           overruns: raw.pointee.overruns, underruns: raw.pointee.underruns)
        }
    }

    @discardableResult
    public func write(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, hostTime: HostTime) -> Int {
        lock.withLock { _ in
            let free = Int(sw_audio_ring_free_space(raw))
            let n = min(frameCount, free)
            if n < frameCount { raw.pointee.overruns &+= UInt64(frameCount - n) }
            guard n > 0 else { return 0 }
            let w = raw.pointee.write_index
            let start = Int(w & UInt64(capacityFrames - 1))
            for c in 0..<channelCount {
                let src = planes[c]
                let dst = planeStorage[c]
                let first = min(n, capacityFrames - start)
                (dst + start).update(from: src, count: first)
                if first < n { dst.update(from: src + first, count: n - first) }
            }
            let si = Int(raw.pointee.stamp_write & UInt64(stampCapacity - 1))
            stampStorage[si] = sw_audio_stamp(frame_index: w, host_time: hostTime.ticks)
            raw.pointee.stamp_write &+= 1
            raw.pointee.write_index = w &+ UInt64(n)
            return n
        }
    }

    public func read(into planes: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> AudioReadResult {
        lock.withLock { _ in
            let avail = Int(sw_audio_ring_available(raw))
            let n = min(frameCount, avail)
            let r = raw.pointee.read_index
            let start = Int(r & UInt64(capacityFrames - 1))
            for c in 0..<channelCount {
                let dst = planes[c]
                let src = planeStorage[c]
                let first = min(n, capacityFrames - start)
                if first > 0 { dst.update(from: src + start, count: first) }
                if first < n { (dst + first).update(from: src, count: n - first) }
                if n < frameCount { (dst + n).update(repeating: 0, count: frameCount - n) }
            }
            if n < frameCount { raw.pointee.underruns &+= UInt64(frameCount - n) }
            var firstTime: HostTime?
            if n > 0 { firstTime = hostTimeLocked(ofFrame: r) }
            raw.pointee.read_index = r &+ UInt64(n)
            return AudioReadResult(framesRead: n, firstFrameHostTime: firstTime)
        }
    }

    /// 帧 index 的 host time：最近一条 frame_index ≤ index 的 stamp 外推（标称采样率）。
    private func hostTimeLocked(ofFrame index: UInt64) -> HostTime? {
        let written = raw.pointee.stamp_write
        guard written > 0 else { return nil }
        var i = written
        let oldest = written > UInt64(stampCapacity) ? written - UInt64(stampCapacity) : 0
        while i > oldest {
            i -= 1
            let s = stampStorage[Int(i & UInt64(stampCapacity - 1))]
            if s.frame_index <= index {
                let tb = HostClock.timebase
                let delta = Int128(index - s.frame_index) * 1_000_000_000 * Int128(tb.denom) / (Int128(tb.numer) * Int128(sampleRate))
                return HostTime(ticks: s.host_time) + HostDuration(ticks: Int64(delta))
            }
        }
        return nil
    }
}
