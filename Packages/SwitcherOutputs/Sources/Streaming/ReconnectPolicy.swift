import Foundation

/// 断线重连的指数退避：第 n 次重试前等 min(initial × multiplier^(n−1), max) 秒 —— 默认 1、2、4、8、16、30、30 …（prompt 交付 1）。
/// 连上之后计数归零；`maxAttempts` nil = 一直试。纯函数，方便测试。
public struct ReconnectPolicy: Hashable, Sendable {
    /// 第一次重试前的等待（秒）。
    public var initialSeconds: Double
    /// 每次失败乘的倍数。
    public var multiplier: Double
    /// 等待上限（秒）；对应 `StreamSettings.reconnectMaxSeconds`。
    public var maxSeconds: Double
    /// 最多连续尝试次数；nil = 无限。
    public var maxAttempts: Int?

    public init(initialSeconds: Double = 1, multiplier: Double = 2, maxSeconds: Double = 30, maxAttempts: Int? = nil) {
        precondition(initialSeconds >= 0 && multiplier >= 1 && maxSeconds >= 0)
        self.initialSeconds = initialSeconds
        self.multiplier = multiplier
        self.maxSeconds = max(maxSeconds, 0)
        self.maxAttempts = maxAttempts
    }

    /// 第 attempt 次重试（从 1 起）前要等的秒数。
    public func delay(forAttempt attempt: Int) -> Double {
        precondition(attempt >= 1)
        let raw = initialSeconds * pow(multiplier, Double(attempt - 1))
        return min(raw.isFinite ? raw : maxSeconds, maxSeconds)
    }

    /// 是否还允许第 attempt 次尝试。
    public func allows(attempt: Int) -> Bool {
        guard let maxAttempts else { return true }
        return attempt <= maxAttempts
    }
}
