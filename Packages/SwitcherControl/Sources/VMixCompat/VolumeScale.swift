import Foundation
import SwitcherContracts

/// 音量三种表示的换算（上游的约定，Companion 模块按它算增减）：
/// - 推子 f：0–100，SetVolume / SetMasterVolume 的 Value；
/// - 幅度百分比 v：0–100，XML 的 volume 属性；v = 100 × (f / 100)⁴，也就是推子 100 = 0 dB、50 ≈ −24 dB；
/// - dB：内部 gainDb。dB = 20·log10(v / 100) = 80·log10(f / 100)。
/// 内部增益能到 +24 dB，上游表示不了 0 dB 以上：推子和幅度都顶格 100。
public enum VolumeScale {
    /// 推子 0–100 → dB（0 = 增益下限）。
    public static func dB(fromFader fader: Double) -> Double {
        let f = min(max(fader, 0), 100)
        guard f > 0 else { return InputAudioSettings.gainRangeDb.lowerBound }
        let dB = 80 * log10(f / 100)
        return min(max(dB, InputAudioSettings.gainRangeDb.lowerBound), InputAudioSettings.gainRangeDb.upperBound)
    }

    /// dB → 推子 0–100。
    public static func fader(fromDb dB: Double) -> Double {
        guard dB > InputAudioSettings.gainRangeDb.lowerBound else { return 0 }
        return min(100, max(0, 100 * pow(10, dB / 80)))
    }

    /// dB → 幅度百分比 0–100（XML volume）。
    public static func amplitudePercent(fromDb dB: Double) -> Double {
        min(100, max(0, 100 * pow(10, dB / 20)))
    }

    /// dB → 幅度 0–1（ACTS 的 Volume 值、表读数）。
    public static func amplitude(fromDb dB: Double) -> Double {
        min(1, max(0, pow(10, dB / 20)))
    }

    /// 数字的紧凑写法：最多 decimals 位小数，去掉末尾的 0（"100"、"6.31"、"0.5"）。
    public static func format(_ value: Double, decimals: Int = 2) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }
}
