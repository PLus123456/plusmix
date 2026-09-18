import SwitcherContracts

extension Rational {
    /// 秒 → 纳秒（向下取整）。
    var nanoseconds: Int64 {
        let n = Int128(numerator) * 1_000_000_000 / Int128(denominator)
        return Int64(clamping: n)
    }
    /// 秒 → host 时长。
    var hostDuration: HostDuration { HostDuration(nanoseconds: nanoseconds) }
    /// 向下取整到整数。
    var floorValue: Int64 {
        let q = numerator / denominator
        return (numerator % denominator != 0 && numerator < 0) ? q - 1 : q
    }
    /// 除法。
    static func / (lhs: Rational, rhs: Rational) -> Rational { lhs * rhs.reciprocal }
    /// 由 Double 近似成分母 ≤ maxDenominator 的有理数（播放速率用；1.5 → 3/2）。
    init(approximating value: Double, maxDenominator: Int64 = 1000) {
        precondition(value.isFinite)
        let d = maxDenominator
        self.init(Int64((value * Double(d)).rounded()), d)
    }
}

/// 文件播放的时钟从属关系（设计方案 §6 "文件是时钟从属"）：
/// 第 `anchorTick` 拍显示媒体位置 `anchorMedia`（秒，循环展开后的绝对位置），之后每拍前进 一拍秒数 × 速率。
/// 全部有理数运算：60 fps 文件在 60 fps 节目里第 k 帧恰好落在第 anchorTick + k 拍上，没有浮点边界问题。
struct FileTimeline: Sendable, Hashable {
    /// 锚点拍。
    var anchorTick: Tick
    /// 锚点拍显示的媒体位置（秒，展开后）。
    var anchorMedia: Rational
    /// 播放速率。
    var rate: Rational
    /// 一拍的秒数（节目帧率的倒数）。
    var programFrame: Rational

    /// 第 tick 拍的媒体位置（展开后）。
    func position(at tick: Tick) -> Rational {
        anchorMedia + programFrame.scaled(by: tick - anchorTick) * rate
    }

    /// 媒体位置 m（展开后）对应的 host 时刻 = 锚点拍时刻 + (m − anchorMedia) / rate。
    func hostTime(ofMedia m: Rational, timing: ProgramTiming) -> HostTime {
        let delta = (m - anchorMedia) / rate
        return timing.time(of: anchorTick) + delta.hostDuration
    }

    /// 第 j 个输出音频样本（48 kHz，从锚点起）对应的源样本位置（展开后的媒体秒 × 48000）。
    func sourceSamplePosition(ofOutputSample j: Int64, sampleRate: Int64) -> Rational {
        anchorMedia.scaled(by: sampleRate) + Rational(j) * rate
    }

    /// 第 j 个输出音频样本的 host 时刻。
    func hostTime(ofOutputSample j: Int64, sampleRate: Int64, timing: ProgramTiming) -> HostTime {
        timing.time(of: anchorTick) + Rational(j, sampleRate).hostDuration
    }
}
