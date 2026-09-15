import Foundation
import Darwin
import Synchronization
import SwitcherContracts
import SwitcherAudio
@testable import SwitcherAudioIntegration

/// 实时合成音频源（测试用，等价于 TestKit 的 SyntheticAudioInput——那个包在依赖图上层，这里看不到）：
/// 一条 time-constraint 线程按块周期 mach_wait_until，块在其末样本时刻"到达"（采完才交），写入时 hostTime = 块首样本时刻。
/// 普通线程的定时等待会晚醒 1–7 ms，超过环的交付余量（W1-D 报告 §5），所以必须是 time-constraint。
final class RealtimeSource: @unchecked Sendable {
    let ring: CAudioRing
    let signal: TestSignal
    let blockFrames: Int
    let channels: Int
    private var thread: Thread?
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    let blocksWritten = Atomic<UInt64>(0)
    let late = Atomic<UInt64>(0)
    /// 自定义生成器（nil = TestSignal）。
    private let generator: ((Int64, Int, UnsafeMutablePointer<Float>) -> Void)?

    init(t0: HostTime, driftPpm: Double = 0, channels: Int = 1, blockFrames: Int = 256, frameRate: FrameRate = .fps60,
         generator: ((Int64, Int, UnsafeMutablePointer<Float>) -> Void)? = nil) {
        ring = CAudioRing(channelCount: channels, capacityFrames: 65_536)
        signal = TestSignal(t0: t0, driftPpm: driftPpm, clickPeriod: TestPattern.flashPeriod(frameRate: frameRate))
        self.blockFrames = blockFrames
        self.channels = channels
        self.generator = generator
    }

    func start() {
        guard thread == nil else { return }
        stopFlag.store(false, ordering: .releasing)
        let t = Thread { [self] in run() }
        t.name = "it-realtime-source"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .releasing)
        finished.wait()
        thread = nil
    }

    private func run() {
        defer { finished.signal() }
        // time-constraint：周期 = 块，计算 1/4，约束 1/2（与 CoreAudio IO 线程同类）
        let tb = HostClock.timebase
        let periodTicks = UInt32(Double(blockFrames) * 1e9 / signal.effectiveSampleRate * Double(tb.denom) / Double(tb.numer))
        var policy = thread_time_constraint_policy(period: periodTicks, computation: periodTicks / 4, constraint: periodTicks / 2, preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        buffer.initialize(repeating: 0, count: blockFrames)
        let planes = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: channels)
        for c in 0..<channels { planes[c] = UnsafePointer(buffer) }
        defer { planes.deallocate(); buffer.deallocate() }
        let blockDuration = HostDuration(nanoseconds: Int64(Double(blockFrames) * 1e9 / signal.effectiveSampleRate))
        // 从"现在"之后的第一个块边界开始（不补历史）
        var next = max(0, signal.sampleIndex(at: HostClock.now()) / Int64(blockFrames) * Int64(blockFrames))
        while !stopFlag.load(ordering: .acquiring) {
            let due = signal.hostTime(ofSample: next + Int64(blockFrames))
            mach_wait_until(due.ticks)
            if stopFlag.load(ordering: .acquiring) { break }
            if let g = generator { g(next, blockFrames, buffer) } else { signal.render(into: buffer, frameCount: blockFrames, startingAt: next) }
            _ = ring.write(planes: UnsafePointer(planes), frameCount: blockFrames, hostTime: signal.hostTime(ofSample: next))
            if HostClock.now() - due > blockDuration { late.wrappingAdd(1, ordering: .relaxed) }
            blocksWritten.wrappingAdd(1, ordering: .relaxed)
            next += Int64(blockFrames)
        }
    }
}

/// 只累计统计不存样本的消费者（长跑）：click 偏移、不连续、块数。
final class StreamAnalyzer: AudioBlockConsuming, @unchecked Sendable {
    let consumerName: String
    let t0: HostTime
    private let lock = NSLock()
    private var firstHostTime: HostTime?
    private var framesSeen: Int64 = 0
    private var prevLeft: Float = 0
    private var holdOff = 0
    private var detector = DiscontinuityDetector(channels: 2)
    private(set) var clickOffsetsMs: [(second: Int, offsetMs: Double)] = []
    private(set) var blocks: UInt64 = 0
    private(set) var gaps = 0
    private var expectedNext: HostTime?
    let clickSignal: TestSignal

    init(name: String, t0: HostTime, frameRate: FrameRate = .fps60) {
        consumerName = name
        self.t0 = t0
        clickSignal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: frameRate))
    }

    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime) {
        lock.lock(); defer { lock.unlock() }
        if firstHostTime == nil { firstHostTime = hostTime }
        if let e = expectedNext, abs((hostTime - e).nanoseconds) > 12_000 { gaps += 1 }   // > 半个样本
        expectedNext = hostTime + HostDuration(nanoseconds: Int64((Double(frameCount) * 1e9 / 48000).rounded()))
        blocks += 1
        // 不连续：按已知 click 位置排除（流序号 → PTS → 源样本序号）
        let first = firstHostTime!
        let offsetSamples = Int64(((first - t0).seconds * 48000).rounded())
        let sig = clickSignal
        detector.feed(planes: planes, frameCount: frameCount) { sig.isClick(sampleIndex: $0 + offsetSamples) }
        let x = planes[0]
        for i in 0..<frameCount {
            if holdOff > 0 { holdOff -= 1 } else if abs(x[i]) >= 0.5 {
                // click 起点：按块 PTS + 样本序号算时刻
                let t = hostTime + HostDuration(nanoseconds: Int64((Double(i) * 1e9 / 48000).rounded()))
                let rel = (t - t0).seconds
                let k = Int(rel.rounded())
                if k >= 1 { clickOffsetsMs.append((k, (Double(k) - rel) * 1000)) }
                holdOff = 2400
            }
        }
        framesSeen += Int64(frameCount)
    }

    var discontinuities: UInt64 { lock.lock(); defer { lock.unlock() }; return detector.count }
    var recentDiscontinuities: [DiscontinuityDetector.Event] { lock.lock(); defer { lock.unlock() }; return detector.recent }

    struct Summary { var count: Int; var meanMs: Double; var stdMs: Double; var maxAbsMs: Double; var slopeMsPerS: Double }
    var summary: Summary {
        lock.lock(); defer { lock.unlock() }
        let ys = clickOffsetsMs.map(\.offsetMs), xs = clickOffsetsMs.map { Double($0.second) }
        guard !ys.isEmpty else { return Summary(count: 0, meanMs: 0, stdMs: 0, maxAbsMs: 0, slopeMsPerS: 0) }
        let n = Double(ys.count)
        let mean = ys.reduce(0, +) / n
        let variance = ys.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let mx = xs.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<ys.count { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - mean) }
        return Summary(count: ys.count, meanMs: mean, stdMs: variance.squareRoot(), maxAbsMs: ys.map(abs).max() ?? 0, slopeMsPerS: sxx > 0 ? sxy / sxx : 0)
    }
}
