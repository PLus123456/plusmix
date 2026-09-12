import Darwin

/// 合成音频信号（测试标准 §2.2）的 CPU 参考实现：1 kHz 正弦 −20 dBFS，每个闪光时刻叠加 1 ms 满幅 click，可加采样率漂移。
///
/// 时间模型：样本 i 的 host time = t0 + i / effectiveSampleRate，其中 effectiveSampleRate = sampleRate × (1 + driftPpm / 1e6)
/// （模拟一个时钟比 host 快 / 慢 ppm 的设备）。第 k 个 click 落在 host time t0 + k × clickPeriod，
/// 所以它的样本序号 = round(k × clickPeriod × effectiveSampleRate)。视频闪光与它共用同一个 t0（W1-A）。
/// click 窗口内的样本直接置为 +1.0（满幅），不与正弦相加，避免削波带来的不确定。
/// 生成器没有内部状态：任意分块、任意起点渲染出来的样本都一样。
public struct TestSignal: Hashable, Sendable {
    /// 第 0 个样本、第 0 个 click 的 host time。
    public var t0: HostTime
    /// 标称采样率（48000）。
    public var sampleRate: Int
    /// 采样率漂移（ppm，±100 量级）。
    public var driftPpm: Double
    /// 正弦频率；应为整数 Hz（相位按 1 s 周期计算才精确）。
    public var toneHz: Double
    /// 正弦电平（dBFS，峰值）。
    public var toneDbfs: Double
    /// click 周期（秒）：等于闪光周期 `TestPattern.flashPeriod(frameRate:)`（60 fps 为 1，59.94 为 1001/1000）。
    public var clickPeriod: Rational
    /// click 长度（样本）；48 = 1 ms。
    public var clickDurationFrames: Int
    /// 换算 host time 用的时基。
    public var timebase: MachTimebase

    public init(t0: HostTime, sampleRate: Int = AudioFormat.sampleRate, driftPpm: Double = 0, toneHz: Double = 1000,
                toneDbfs: Double = -20, clickPeriod: Rational = .one, clickDurationFrames: Int = 48,
                timebase: MachTimebase = HostClock.timebase) {
        precondition(sampleRate > 0 && clickPeriod.numerator > 0 && clickDurationFrames >= 0)
        self.t0 = t0
        self.sampleRate = sampleRate
        self.driftPpm = driftPpm
        self.toneHz = toneHz
        self.toneDbfs = toneDbfs
        self.clickPeriod = clickPeriod
        self.clickDurationFrames = clickDurationFrames
        self.timebase = timebase
    }

    /// 实际产样率（样本 / host 秒）。
    public var effectiveSampleRate: Double { Double(sampleRate) * (1 + driftPpm / 1e6) }
    /// 正弦峰值（−20 dBFS → 0.1）。
    public var toneAmplitude: Double { pow(10, toneDbfs / 20) }
    /// 每个 click 之间的样本数（实数）。
    public var samplesPerClick: Double { Double(clickPeriod.numerator) * effectiveSampleRate / Double(clickPeriod.denominator) }

    /// 第 k 个 click 的起始样本序号。
    public func clickSampleIndex(_ k: Int) -> Int64 { Int64((Double(k) * samplesPerClick).rounded()) }

    /// 样本 i 是否在某个 click 窗口内。
    public func isClick(sampleIndex i: Int64) -> Bool {
        guard i >= 0, clickDurationFrames > 0 else { return false }
        let k = Int((Double(i) / samplesPerClick).rounded(.down))
        for kk in max(0, k - 1)...(k + 1) {
            let s = clickSampleIndex(kk)
            if i >= s && i < s + Int64(clickDurationFrames) { return true }
        }
        return false
    }

    /// 样本 i 的 host time。
    public func hostTime(ofSample i: Int64) -> HostTime {
        t0 + HostDuration(nanoseconds: Int64((Double(i) * 1e9 / effectiveSampleRate).rounded()), timebase: timebase)
    }

    /// 时刻 t 之前（含）最后一个样本的序号（t0 之前为负）。合成源用它决定"现在该产到第几个样本"。
    public func sampleIndex(at time: HostTime) -> Int64 {
        let ns = Double((time - t0).nanoseconds(timebase: timebase))
        return Int64((ns * effectiveSampleRate / 1e9).rounded(.down))
    }

    /// 渲染 `frameCount` 个样本（单声道 float32）到 buffer，起点是绝对样本序号 `start`。不分配、不持状态。
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, startingAt start: Int64) {
        let amp = toneAmplitude
        let period = Int64(sampleRate)
        let phaseStep = 2 * Double.pi * toneHz / Double(sampleRate)
        for n in 0..<frameCount {
            let i = start + Int64(n)
            if isClick(sampleIndex: i) {
                buffer[n] = 1.0
            } else {
                let m = ((i % period) + period) % period
                buffer[n] = Float(amp * sin(phaseStep * Double(m)))
            }
        }
    }
}
