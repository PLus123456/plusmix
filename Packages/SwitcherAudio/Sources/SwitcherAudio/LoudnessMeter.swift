// LoudnessMeter.swift —— 非实时用的响度 / 真峰值表（libebur128 的 Swift 包装）。
//
// 总线上的表在 C 热路径里（sw_mix.c），这里是给离线分析（TestKit、frameprobe、A6 测试的多声道用例）用的同一套算法：
// ITU-R BS.1770-4 K 加权 + 门限，EBU R128 M / S / I，Tech 3342 LRA，真峰值 4× 过采样。
import Darwin
import SwitcherContracts
import CLibEBUR128

public final class LoudnessMeter {
    private var state: UnsafeMutablePointer<ebur128_state>?
    public let channelCount: Int
    public let sampleRate: Int
    private var interleaved: [Float]

    /// 声道映射按 libebur128 默认：1 = 中置（单声道），2 = L R，5 = L R C Ls Rs，6 = L R C LFE Ls Rs（LFE 不计）。
    public init(channelCount: Int, sampleRate: Int = AudioFormat.sampleRate) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        let mode = Int32(EBUR128_MODE_M.rawValue | EBUR128_MODE_S.rawValue | EBUR128_MODE_I.rawValue | EBUR128_MODE_LRA.rawValue |
                         EBUR128_MODE_TRUE_PEAK.rawValue | EBUR128_MODE_HISTOGRAM.rawValue)
        state = ebur128_init(UInt32(channelCount), UInt(sampleRate), mode)
        precondition(state != nil, "ebur128_init 失败")
        interleaved = []
    }

    deinit { if state != nil { ebur128_destroy(&state) } }

    /// 喂非交错样本（每个数组一个声道，等长）。
    public func add(planes: [[Float]]) {
        precondition(planes.count == channelCount)
        let n = planes.first?.count ?? 0
        if interleaved.count < n * channelCount { interleaved = [Float](repeating: 0, count: n * channelCount) }
        for c in 0..<channelCount {
            let p = planes[c]
            for i in 0..<n { interleaved[i * channelCount + c] = p[i] }
        }
        interleaved.withUnsafeBufferPointer { _ = ebur128_add_frames_float(state, $0.baseAddress, n) }
    }

    /// 喂交错样本。
    public func add(interleaved samples: [Float]) {
        samples.withUnsafeBufferPointer { _ = ebur128_add_frames_float(state, $0.baseAddress, samples.count / channelCount) }
    }

    private func read(_ f: (UnsafeMutablePointer<ebur128_state>?, UnsafeMutablePointer<Double>) -> Int32) -> Double {
        var v = -Double.infinity
        _ = f(state, &v)
        return v
    }
    /// M（LUFS）。
    public var momentary: Double { read { ebur128_loudness_momentary($0, $1) } }
    /// S（LUFS）。
    public var shortTerm: Double { read { ebur128_loudness_shortterm($0, $1) } }
    /// I（LUFS，门限积分）。
    public var integrated: Double { read { ebur128_loudness_global($0, $1) } }
    /// LRA（LU）。
    public var loudnessRange: Double { read { ebur128_loudness_range($0, $1) } }
    /// 各声道真峰值（线性，自开始以来的最大）。
    public var truePeak: [Double] {
        (0..<channelCount).map { c in var v = 0.0; _ = ebur128_true_peak(state, UInt32(c), &v); return v }
    }
    /// 各声道采样峰值。
    public var samplePeak: [Double] {
        (0..<channelCount).map { c in var v = 0.0; _ = ebur128_sample_peak(state, UInt32(c), &v); return v }
    }
    /// 最大真峰值（dBTP）。
    public var truePeakDb: Double { 20 * log10(max(truePeak.max() ?? 0, 1e-12)) }
}
