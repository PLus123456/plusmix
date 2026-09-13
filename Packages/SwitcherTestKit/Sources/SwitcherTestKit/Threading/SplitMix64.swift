/// 确定性伪随机数（SplitMix64）：合成源的人为抖动用它，同一 seed 每次跑出同一序列；不分配、不加锁。
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// 下一个 64 位随机数。
    @inline(__always)
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 均匀分布。
    @inline(__always)
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// [−amplitude, +amplitude] 均匀分布。
    @inline(__always)
    public mutating func nextSymmetric(_ amplitude: Double) -> Double {
        (nextUnit() * 2 - 1) * amplitude
    }
}
