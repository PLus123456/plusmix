import Foundation

/// 音轨里找 click（测试标准 §2.3）：1 ms 窗口的平均能量超过阈值即认为有 click，起点取窗口内第一个 |x| ≥ onsetLevel 的样本，
/// 输出样本级时间。合成信号的 click 是 48 个样本的 +1.0，正弦峰值 0.1（能量 0.005），−40 dB 白噪声 RMS 0.01，
/// 阈值 0.25（RMS 0.5）离两边都很远。找到一个后跳过 holdOff，避免同一个 click 被报两次。
public enum ClickDetector {
    public struct Options: Hashable, Sendable {
        /// 能量窗口（样本），48 = 48 kHz 下 1 ms。
        public var windowFrames: Int
        /// 窗口平均能量（均方）阈值。
        public var energyThreshold: Float
        /// 起点判据：|x| ≥ 它的第一个样本。
        public var onsetLevel: Float
        /// 找到后跳过的时长（秒）。
        public var holdOffSeconds: Double
        public init(windowFrames: Int = 48, energyThreshold: Float = 0.25, onsetLevel: Float = 0.5, holdOffSeconds: Double = 0.05) {
            self.windowFrames = windowFrames
            self.energyThreshold = energyThreshold
            self.onsetLevel = onsetLevel
            self.holdOffSeconds = holdOffSeconds
        }
        public static let `default` = Options()
    }

    /// - Parameters:
    ///   - samples: 单声道样本。
    ///   - startSeconds: 第 0 个样本在文件时间线上的时刻。
    public static func detect(samples: UnsafeBufferPointer<Float>, sampleRate: Double, startSeconds: Double = 0,
                              options: Options = .default) -> [ClickEvent] {
        let w = options.windowFrames
        let n = samples.count
        guard n >= w, w > 0 else { return [] }
        let threshold = options.energyThreshold * Float(w)
        let holdOff = max(w, Int(options.holdOffSeconds * sampleRate))
        var events: [ClickEvent] = []
        var i = 0
        while i + w <= n {
            // 从 i 起重建窗口和
            var sum: Float = 0
            for j in i..<(i + w) { sum += samples[j] * samples[j] }
            var end = i + w // 窗口 [end − w, end)
            var found = -1
            while true {
                if sum > threshold {
                    var onset = end - w
                    while onset < end && abs(samples[onset]) < options.onsetLevel { onset += 1 }
                    found = onset < end ? onset : end - w
                    break
                }
                if end >= n { break }
                sum += samples[end] * samples[end] - samples[end - w] * samples[end - w]
                end += 1
            }
            guard found >= 0 else { break }
            var peak: Float = 0
            for j in found..<min(n, found + w) { peak = max(peak, abs(samples[j])) }
            events.append(ClickEvent(sampleIndex: Int64(found), timeSeconds: startSeconds + Double(found) / sampleRate, peak: peak))
            i = found + holdOff
        }
        return events
    }

    /// 数组版。
    public static func detect(samples: [Float], sampleRate: Double, startSeconds: Double = 0, options: Options = .default) -> [ClickEvent] {
        samples.withUnsafeBufferPointer { detect(samples: $0, sampleRate: sampleRate, startSeconds: startSeconds, options: options) }
    }
}
