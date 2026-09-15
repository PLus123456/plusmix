// OfflineAudioDriver.swift —— 离线工装：同一个 sw_mix_block 按确定时序跑，不用真设备（prompt 第 6 条）。
//
// 输出设备时间线是合成的：第 n 块首样本 host time = start + n × blockFrames × 每帧 tick（128 位整数算，不累加浮点）。
// 供测试和 headless 用；块之间调用方可以往输入环里写数据（OfflineAudioSource 按 host time 决定该写到第几个样本）。
import SwitcherContracts
import CSwitcherAudioRT

/// 一块的输出视图（指向驱动内部缓冲，下一块会被覆盖，要留就拷走）。
public struct OfflineBlock {
    public let index: Int
    public let hostTime: HostTime
    public let frames: Int
    /// 8 个平面：[Master L, R, A L, R, B L, R, HP L, R]。
    public let planes: [UnsafeBufferPointer<Float>]
    /// 某条总线的左右声道。
    public func bus(_ b: Bus) -> (left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        (planes[2 * b.rawValue], planes[2 * b.rawValue + 1])
    }
}

/// 离线驱动：调用方线程上按块推进合成时间线。
public final class OfflineAudioDriver {
    public let mixer: AudioMixer
    public let blockFrames: Int
    public let timebase: MachTimebase
    public let startHostTime: HostTime
    public private(set) var blockIndex: Int = 0
    private let storage: UnsafeMutablePointer<Float>
    private var planes: [UnsafeMutablePointer<Float>?]

    public init(mixer: AudioMixer, blockFrames: Int = AudioFormat.defaultBlockFrames, startHostTime: HostTime,
                timebase: MachTimebase = HostClock.timebase) {
        precondition(blockFrames > 0 && blockFrames <= mixer.maxBlockFrames)
        self.mixer = mixer
        self.blockFrames = blockFrames
        self.timebase = timebase
        self.startHostTime = startHostTime
        let mb = mixer.maxBlockFrames
        let st = UnsafeMutablePointer<Float>.allocate(capacity: 8 * mb)
        st.initialize(repeating: 0, count: 8 * mb)
        storage = st
        planes = (0..<8).map { st + $0 * mb }
        mixer.setTimingCheck(false)
    }

    deinit { storage.deallocate() }

    /// 第 n 块首样本的 host time。
    public func hostTime(ofBlock n: Int) -> HostTime {
        let frames = UInt128(n) * UInt128(blockFrames)
        let ticks = frames * UInt128(timebase.denom) * 1_000_000_000 / (UInt128(timebase.numer) * UInt128(AudioFormat.sampleRate))
        return HostTime(ticks: startHostTime.ticks + UInt64(ticks))
    }
    /// 下一块的首样本 host time。
    public var nextBlockHostTime: HostTime { hostTime(ofBlock: blockIndex) }
    /// 下一块结束（最后一个样本之后）的 host time。
    public var nextBlockEndHostTime: HostTime { hostTime(ofBlock: blockIndex + 1) }

    /// 渲染下一块。
    @discardableResult
    public func renderNext() -> OfflineBlock {
        let t = nextBlockHostTime
        planes.withUnsafeBufferPointer { mixer.render(into: $0.baseAddress!, frames: blockFrames, hostTime: t) }
        let idx = blockIndex
        blockIndex += 1
        return OfflineBlock(index: idx, hostTime: t, frames: blockFrames,
                            planes: planes.map { UnsafeBufferPointer(start: $0, count: blockFrames) })
    }

    /// 跑 n 块。`beforeEach` 在每块渲染前调（参数：本块首样本 host time、本块结束 host time），一般用来喂输入；
    /// `afterEach` 拿输出。
    public func run(blocks: Int, beforeEach: ((HostTime, HostTime) -> Void)? = nil, afterEach: ((OfflineBlock) -> Void)? = nil) {
        for _ in 0..<blocks {
            beforeEach?(nextBlockHostTime, nextBlockEndHostTime)
            let b = renderNext()
            afterEach?(b)
        }
    }
}

/// 离线合成输入：按 host time 把一个信号生成器的样本写进环，模拟"设备采到一块就交一块"（含 ±ppm 时钟漂移）。
/// 生成器无状态：给绝对样本序号与数量，写单声道样本；多声道每路各调一次（channel 参数）。
public final class OfflineAudioSource {
    public let ring: CAudioRing
    /// 生产者块大小（帧）。
    public let producerBlockFrames: Int
    /// 样本时间线（含漂移）：样本 i 的 host time 与"时刻 t 该到第几个样本"都由它算。
    public let timeline: TestSignal
    private let generator: (_ channel: Int, _ start: Int64, _ count: Int, _ buffer: UnsafeMutablePointer<Float>) -> Void
    /// 下一个要写的样本序号。
    public private(set) var nextSample: Int64 = 0
    /// 写了多少块。
    public private(set) var blocksWritten = 0
    private var scratch: [[Float]]

    /// - Parameters:
    ///   - t0: 第 0 个样本的 host time
    ///   - driftPpm: 源时钟相对 host 的漂移（+100 = 源快 100 ppm，每秒多产 4.8 个样本）
    ///   - generator: 默认用 TestSignal 本身（1 kHz −20 dBFS + click）
    public init(channels: Int, t0: HostTime, driftPpm: Double = 0, producerBlockFrames: Int = AudioFormat.defaultBlockFrames,
                capacityFrames: Int = 16_384, timebase: MachTimebase = HostClock.timebase,
                generator: ((_ channel: Int, _ start: Int64, _ count: Int, _ buffer: UnsafeMutablePointer<Float>) -> Void)? = nil) {
        ring = CAudioRing(channelCount: channels, capacityFrames: capacityFrames,
                          stampCapacity: max(64, capacityFrames / max(16, producerBlockFrames) * 2), timebase: timebase)
        self.producerBlockFrames = producerBlockFrames
        let tl = TestSignal(t0: t0, driftPpm: driftPpm, timebase: timebase)
        timeline = tl
        self.generator = generator ?? { _, start, count, buf in tl.render(into: buf, frameCount: count, startingAt: start) }
        scratch = [[Float]](repeating: [Float](repeating: 0, count: producerBlockFrames), count: channels)
    }

    /// 把"最后一帧 host time ≤ now"的整块全部写进环（设备在采完一块后交付）。返回写了几块。
    @discardableResult
    public func deliver(upTo now: HostTime) -> Int {
        var n = 0
        while true {
            let lastSample = nextSample + Int64(producerBlockFrames) - 1
            if timeline.hostTime(ofSample: lastSample) > now { break }
            writeBlock()
            n += 1
        }
        return n
    }

    /// 无条件写一块。
    public func writeBlock() {
        let start = nextSample
        for c in 0..<ring.channelCount {
            scratch[c].withUnsafeMutableBufferPointer { generator(c, start, producerBlockFrames, $0.baseAddress!) }
        }
        ring.write(scratch, hostTime: timeline.hostTime(ofSample: start))
        nextSample += Int64(producerBlockFrames)
        blocksWritten += 1
    }
}
