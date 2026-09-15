import CoreMedia
import SwitcherContracts

// host time ↔ CMTime。整个输出层只用两种 CMTime：
//   绝对时刻：纳秒，timescale 1e9（编码器给 VT 的 PTS，就是拍点时刻）；
//   相对时刻：录制起点为 0，换算到轨道 timescale（Recorder 自己算）。

extension HostTime {
    /// 绝对 host time → CMTime（纳秒，timescale 1 000 000 000）。
    public var cmTime: CMTime { CMTime(value: Int64(nanoseconds), timescale: 1_000_000_000) }

    /// 从 `cmTime` 的逆换算（timescale 必须是 1e9 或能整换算；其他 timescale 先 CMTimeConvertScale）。
    public init?(cmTime: CMTime) {
        guard cmTime.isNumeric, cmTime.value >= 0 else { return nil }
        let ns: Int64 = cmTime.timescale == 1_000_000_000
            ? cmTime.value
            : CMTimeConvertScale(cmTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
        self.init(nanoseconds: UInt64(ns))
    }
}

extension HostDuration {
    /// 时长 → CMTime（纳秒）。
    public var cmTime: CMTime { CMTime(value: nanoseconds, timescale: 1_000_000_000) }
}

extension Rational {
    /// 有理数秒 → CMTime（分子 / 分母直接映射；分母超过 Int32 时按纳秒）。
    public var cmTime: CMTime {
        if denominator <= Int64(Int32.max) {
            return CMTime(value: numerator, timescale: Int32(denominator))
        }
        return CMTime(value: Int64((Double(numerator) / Double(denominator) * 1e9).rounded()), timescale: 1_000_000_000)
    }
}

extension ProgramFormat {
    /// 轨道 timescale：frameDuration 分母的 10 的幂倍数，≥ 10 000，使一帧恰好是整数个单位
    /// （60 fps → 60000 / 1000 单位一帧；59.94 → 60000 / 1001；30 → 30000 / 1000；23.976 → 24000 / 1001）。
    public var trackTimescale: Int32 {
        var ts = frameDuration.denominator
        while ts < 10_000 { ts *= 10 }
        return Int32(clamping: ts)
    }
}
