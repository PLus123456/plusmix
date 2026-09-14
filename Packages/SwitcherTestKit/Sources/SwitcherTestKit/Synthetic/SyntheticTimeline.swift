import SwitcherContracts

/// 合成源共用的时间线：一个 t0 + 节目帧率。视频闪光在 t0 + k × 闪光周期，音频 click 也在同一时刻（测试标准 §2.2）。
/// 同一台"虚拟设备"的视频与音频、或多路要求同步的合成源，都拿同一个 `SyntheticTimeline`。
public struct SyntheticTimeline: Hashable, Sendable {
    /// 第 0 帧 / 第 0 个样本 / 第 0 个 click 的 host time。
    public var t0: HostTime
    /// 合成源帧率（30 / 59.94 / 60）。
    public var frameRate: FrameRate

    public init(t0: HostTime, frameRate: FrameRate) {
        self.t0 = t0
        self.frameRate = frameRate
    }

    /// 从"现在"起 `leadMilliseconds` 后开始的时间线。
    public static func startingSoon(frameRate: FrameRate, leadMilliseconds: Double = 20) -> SyntheticTimeline {
        SyntheticTimeline(t0: HostClock.now() + HostDuration(milliseconds: leadMilliseconds), frameRate: frameRate)
    }

    /// 带时钟漂移的视频拍点时钟：第 n 帧在 t0 + n × T / (1 + ppm/10⁶)。ppm 量化到 0.001 ppm，全程有理数。
    public func videoClock(driftPpm: Double) -> TickClockSpec {
        TickClockSpec(t0: t0, frameDuration: SyntheticTimeline.driftedDuration(frameRate.frameDuration, ppm: driftPpm))
    }

    /// 与闪光共用 t0 的合成音频信号；click 周期 = `TestPattern.flashPeriod(frameRate:)`。
    public func audioSignal(driftPpm: Double, sampleRate: Int = AudioFormat.sampleRate) -> TestSignal {
        TestSignal(t0: t0, sampleRate: sampleRate, driftPpm: driftPpm, clickPeriod: TestPattern.flashPeriod(frameRate: frameRate))
    }

    /// T × 10⁹ / (10⁹ + ppm × 10³)：设备时钟快 ppm 时，每帧在 host 上更短。
    static func driftedDuration(_ nominal: Rational, ppm: Double) -> Rational {
        let milli = Int64((ppm * 1000).rounded())
        precondition(milli > -1_000_000_000, "漂移不能 ≤ −100%")
        return nominal * Rational(1_000_000_000, 1_000_000_000 + milli)
    }
}
