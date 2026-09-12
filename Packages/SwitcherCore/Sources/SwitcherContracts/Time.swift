import Darwin

// MARK: - Host 时钟

/// mach 时基（numer / denom）：1 个 host tick = numer / denom 纳秒。Apple Silicon 上是 125 / 3（24 MHz），Intel 上是 1 / 1。
/// 单独定义成 Swift 结构而不用 `mach_timebase_info_data_t`，是为了 Sendable 和可以在测试里伪造时基。
public struct MachTimebase: Hashable, Sendable {
    /// 1 个 host tick = numer / denom 纳秒：分子。
    public var numer: UInt32
    /// 分母。
    public var denom: UInt32
    public init(numer: UInt32, denom: UInt32) {
        precondition(numer > 0 && denom > 0, "时基分子分母必须为正")
        self.numer = numer
        self.denom = denom
    }
}

/// 进程内唯一的 host 时钟入口。所有换算都用 `timebase`，不许各自再调 mach_timebase_info。
public enum HostClock {
    /// 进程启动时读一次，之后不变。
    public static let timebase: MachTimebase = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return MachTimebase(numer: tb.numer, denom: tb.denom)
    }()

    /// 当前 host time（mach_absolute_time）。铁律 5：所有帧和音频块在入口用它打戳。
    @inline(__always)
    public static func now() -> HostTime { HostTime(ticks: mach_absolute_time()) }
}

/// 绝对 host time：mach_absolute_time 的原始 tick 数。整个系统只有这一种时间戳；
/// 和秒 / 纳秒的换算走 `MachTimebase`，用 128 位整数，不用浮点。
public struct HostTime: Hashable, Comparable, Sendable {
    /// mach_absolute_time 原始 tick 数。
    public var ticks: UInt64

    @inline(__always)
    public init(ticks: UInt64) { self.ticks = ticks }

    /// tick 0。
    public static let zero = HostTime(ticks: 0)

    /// 现在。
    @inline(__always)
    public static func now() -> HostTime { HostClock.now() }

    /// 由纳秒换算（向下取整）。
    public init(nanoseconds: UInt64, timebase: MachTimebase = HostClock.timebase) {
        ticks = UInt64(UInt128(nanoseconds) * UInt128(timebase.denom) / UInt128(timebase.numer))
    }

    /// 换算成纳秒（向下取整）。
    public func nanoseconds(timebase: MachTimebase = HostClock.timebase) -> UInt64 {
        UInt64(UInt128(ticks) * UInt128(timebase.numer) / UInt128(timebase.denom))
    }
    /// 换算成纳秒（进程时基）。
    public var nanoseconds: UInt64 { nanoseconds() }
    /// 换算成秒（仅供显示 / 日志，不许拿来做时钟运算）。
    public var seconds: Double { Double(nanoseconds) / 1e9 }
    /// 换算成毫秒（仅供显示 / 日志）。
    public var milliseconds: Double { Double(nanoseconds) / 1e6 }

    @inline(__always)
    public static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.ticks < rhs.ticks }

    /// 两个时刻之差，可为负。
    @inline(__always)
    public static func - (lhs: HostTime, rhs: HostTime) -> HostDuration {
        HostDuration(ticks: Int64(bitPattern: lhs.ticks &- rhs.ticks))
    }
    /// 时刻加时长；结果不能为负。
    @inline(__always)
    public static func + (lhs: HostTime, rhs: HostDuration) -> HostTime {
        HostTime(ticks: UInt64(Int128(lhs.ticks) + Int128(rhs.ticks)))
    }
    /// 时刻减时长；结果不能为负。
    @inline(__always)
    public static func - (lhs: HostTime, rhs: HostDuration) -> HostTime {
        HostTime(ticks: UInt64(Int128(lhs.ticks) - Int128(rhs.ticks)))
    }
    public static func += (lhs: inout HostTime, rhs: HostDuration) { lhs = lhs + rhs }
    public static func -= (lhs: inout HostTime, rhs: HostDuration) { lhs = lhs - rhs }
}

extension HostTime: Codable {
    /// JSON 里就是一个整数（host tick）。
    public init(from decoder: Decoder) throws { ticks = try decoder.singleValueContainer().decode(UInt64.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(ticks) }
}

extension HostTime: CustomStringConvertible {
    /// 调试用描述。
    public var description: String { "HostTime(\(ticks))" }
}

/// host tick 计的时长，有符号。`HostTime - HostTime` 得到它。
public struct HostDuration: Hashable, Comparable, Sendable {
    /// host tick 数，有符号。
    public var ticks: Int64

    @inline(__always)
    public init(ticks: Int64) { self.ticks = ticks }

    /// 0。
    public static let zero = HostDuration(ticks: 0)

    /// 由纳秒换算（向零取整）。
    public init(nanoseconds: Int64, timebase: MachTimebase = HostClock.timebase) {
        ticks = Int64(Int128(nanoseconds) * Int128(timebase.denom) / Int128(timebase.numer))
    }
    /// 由秒换算（四舍五入到 host tick）。只用于配置值（例如"延迟 100 ms"），不用于时钟累加。
    public init(seconds: Double, timebase: MachTimebase = HostClock.timebase) {
        self.init(nanoseconds: Int64((seconds * 1e9).rounded()), timebase: timebase)
    }
    /// 由毫秒换算（四舍五入到 host tick）。
    public init(milliseconds: Double, timebase: MachTimebase = HostClock.timebase) {
        self.init(seconds: milliseconds / 1e3, timebase: timebase)
    }

    /// 换算成纳秒（向零取整）。
    public func nanoseconds(timebase: MachTimebase = HostClock.timebase) -> Int64 {
        Int64(Int128(ticks) * Int128(timebase.numer) / Int128(timebase.denom))
    }
    /// 纳秒（进程时基）。
    public var nanoseconds: Int64 { nanoseconds() }
    /// 换算成毫秒。
    public func milliseconds(timebase: MachTimebase = HostClock.timebase) -> Double { Double(nanoseconds(timebase: timebase)) / 1e6 }
    /// 毫秒（进程时基）。
    public var milliseconds: Double { milliseconds() }
    /// 秒。
    public var seconds: Double { Double(nanoseconds) / 1e9 }

    public static func < (lhs: HostDuration, rhs: HostDuration) -> Bool { lhs.ticks < rhs.ticks }
    public static func + (lhs: HostDuration, rhs: HostDuration) -> HostDuration { HostDuration(ticks: lhs.ticks + rhs.ticks) }
    public static func - (lhs: HostDuration, rhs: HostDuration) -> HostDuration { HostDuration(ticks: lhs.ticks - rhs.ticks) }
    public static prefix func - (d: HostDuration) -> HostDuration { HostDuration(ticks: -d.ticks) }
    public static func * (lhs: HostDuration, rhs: Int) -> HostDuration { HostDuration(ticks: lhs.ticks * Int64(rhs)) }
    public static func / (lhs: HostDuration, rhs: Int) -> HostDuration { HostDuration(ticks: lhs.ticks / Int64(rhs)) }
    /// 绝对值（Int64.min 钳到 Int64.max）。
    public var magnitude: HostDuration { HostDuration(ticks: ticks == .min ? .max : abs(ticks)) }
}

extension HostDuration: Codable {
    public init(from decoder: Decoder) throws { ticks = try decoder.singleValueContainer().decode(Int64.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(ticks) }
}

extension HostDuration: CustomStringConvertible {
    /// 调试用描述。
    public var description: String { "HostDuration(\(ticks))" }
}

// MARK: - 有理数

/// 整数分子分母的有理数。永远是约分后的形式，分母为正，所以 `==` 和 `Hashable` 直接按字段比。
/// 帧率、帧时长、闪光周期都用它；乘除走 128 位中间值不溢出。
public struct Rational: Hashable, Comparable, Sendable {
    /// 分子（带符号）。
    public let numerator: Int64
    /// 分母（> 0）。
    public let denominator: Int64

    /// 分母不能为 0；负号归到分子；自动约分。
    public init(_ numerator: Int64, _ denominator: Int64) {
        precondition(denominator != 0, "Rational 分母不能为 0")
        var n = numerator, d = denominator
        if d < 0 { n = -n; d = -d }
        let g = Rational.gcd(n.magnitude, d.magnitude)
        if g > 1 { n /= Int64(g); d /= Int64(g) }
        self.numerator = n
        self.denominator = d
    }
    public init(_ integer: Int64) { self.init(integer, 1) }

    /// 0/1。
    public static let zero = Rational(0, 1)
    /// 1/1。
    public static let one = Rational(1, 1)

    /// 倒数。
    public var reciprocal: Rational {
        precondition(numerator != 0, "0 没有倒数")
        return Rational(denominator, numerator)
    }
    /// 浮点近似值，只给显示和粗略估算用。
    public var doubleValue: Double { Double(numerator) / Double(denominator) }
    /// 分母是否为 1。
    public var isInteger: Bool { denominator == 1 }
    /// 是否为 0。
    public var isZero: Bool { numerator == 0 }

    public static func < (lhs: Rational, rhs: Rational) -> Bool {
        Int128(lhs.numerator) * Int128(rhs.denominator) < Int128(rhs.numerator) * Int128(lhs.denominator)
    }
    public static func * (lhs: Rational, rhs: Rational) -> Rational {
        Rational.reduced(Int128(lhs.numerator) * Int128(rhs.numerator), Int128(lhs.denominator) * Int128(rhs.denominator))
    }
    public static func + (lhs: Rational, rhs: Rational) -> Rational {
        Rational.reduced(Int128(lhs.numerator) * Int128(rhs.denominator) + Int128(rhs.numerator) * Int128(lhs.denominator),
                         Int128(lhs.denominator) * Int128(rhs.denominator))
    }
    public static func - (lhs: Rational, rhs: Rational) -> Rational {
        Rational.reduced(Int128(lhs.numerator) * Int128(rhs.denominator) - Int128(rhs.numerator) * Int128(lhs.denominator),
                         Int128(lhs.denominator) * Int128(rhs.denominator))
    }
    /// 乘以整数。
    public func scaled(by k: Int64) -> Rational { Rational.reduced(Int128(numerator) * Int128(k), Int128(denominator)) }

    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
    static func gcd128(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
    static func reduced(_ n: Int128, _ d: Int128) -> Rational {
        precondition(d != 0)
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = gcd128(n.magnitude, d.magnitude)
        if g > 1 { n /= Int128(g); d /= Int128(g) }
        precondition(n >= Int128(Int64.min) && n <= Int128(Int64.max) && d <= Int128(Int64.max), "Rational 约分后仍超出 Int64")
        return Rational(Int64(n), Int64(d))
    }
}

extension Rational: Codable {
    enum CodingKeys: String, CodingKey { case numerator, denominator }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int64.self, forKey: .numerator)
        let d = try c.decode(Int64.self, forKey: .denominator)
        guard d != 0 else { throw DecodingError.dataCorruptedError(forKey: .denominator, in: c, debugDescription: "分母不能为 0") }
        self.init(n, d)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(numerator, forKey: .numerator)
        try c.encode(denominator, forKey: .denominator)
    }
}

extension Rational: CustomStringConvertible {
    /// "n" 或 "n/d"。
    public var description: String { isInteger ? "\(numerator)" : "\(numerator)/\(denominator)" }
}

// MARK: - 帧率

/// 帧率 = 每秒帧数的有理数。59.94 就是 60000/1001，不是 59.94。
public struct FrameRate: Hashable, Sendable {
    /// 每秒帧数。
    public let framesPerSecond: Rational

    public init(_ framesPerSecond: Rational) {
        precondition(framesPerSecond.numerator > 0, "帧率必须为正")
        self.framesPerSecond = framesPerSecond
    }
    public init(_ integerFramesPerSecond: Int64) { self.init(Rational(integerFramesPerSecond)) }

    /// 24 fps。
    public static let fps24 = FrameRate(24)
    /// 25 fps。
    public static let fps25 = FrameRate(25)
    /// 29.97 fps = 30000/1001。
    public static let fps2997 = FrameRate(Rational(30_000, 1_001))
    /// 30 fps。
    public static let fps30 = FrameRate(30)
    /// 50 fps。
    public static let fps50 = FrameRate(50)
    /// 59.94 fps = 60000/1001。
    public static let fps5994 = FrameRate(Rational(60_000, 1_001))
    /// 60 fps。
    public static let fps60 = FrameRate(60)
    /// 测试标准 §2.1 要求合成源支持的三档。
    public static let standard: [FrameRate] = [.fps30, .fps5994, .fps60]

    /// 一帧的时长（秒），例如 1001/60000。
    public var frameDuration: Rational { framesPerSecond.reciprocal }
    /// 四舍五入后的整数帧率：59.94 → 60。闪光周期（"每秒第 0 帧"）按它算，见 `TestPattern.isFlashTick`。
    public var nominalFramesPerSecond: Int { Int(framesPerSecond.doubleValue.rounded()) }
    /// 浮点近似，只供显示。
    public var approximateFramesPerSecond: Double { framesPerSecond.doubleValue }
    /// 是否分数帧率（59.94 / 29.97 / 23.976）。
    public var isFractional: Bool { !framesPerSecond.isInteger }
}

extension FrameRate: Codable {
    /// JSON 形态就是 Rational：{"numerator":60000,"denominator":1001}。
    public init(from decoder: Decoder) throws { self.init(try Rational(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try framesPerSecond.encode(to: encoder) }
}

extension FrameRate: CustomStringConvertible {
    /// "60" 或 "59.94"。
    public var description: String {
        isFractional ? String(format: "%.2f", approximateFramesPerSecond) : "\(framesPerSecond.numerator)"
    }
}

// MARK: - 拍

/// 节目时钟的一拍（§1.1：Tick = 一帧的时间）。第 0 拍在 t0，可以为负（t0 之前）。
public struct Tick: RawRepresentable, Hashable, Comparable, Sendable, Codable, Strideable {
    /// 步长是拍数。
    public typealias Stride = Int
    /// 拍序号。
    public var rawValue: Int64

    @inline(__always)
    public init(rawValue: Int64) { self.rawValue = rawValue }
    @inline(__always)
    public init(_ value: Int64) { rawValue = value }

    /// 第 0 拍。
    public static let zero = Tick(0)

    /// Strideable。
    public func advanced(by n: Int) -> Tick { Tick(rawValue + Int64(n)) }
    /// Strideable。
    public func distance(to other: Tick) -> Int { Int(other.rawValue - rawValue) }

    @inline(__always)
    public static func < (lhs: Tick, rhs: Tick) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func + (lhs: Tick, rhs: Int) -> Tick { Tick(lhs.rawValue + Int64(rhs)) }
    public static func - (lhs: Tick, rhs: Int) -> Tick { Tick(lhs.rawValue - Int64(rhs)) }
    /// 两拍之差（拍数）。
    public static func - (lhs: Tick, rhs: Tick) -> Int64 { lhs.rawValue - rhs.rawValue }
    public static func += (lhs: inout Tick, rhs: Int) { lhs = lhs + rhs }
}

extension Tick: CustomStringConvertible {
    /// "#n"。
    public var description: String { "#\(rawValue)" }
}

// MARK: - 拍点时钟

/// 节目时钟的定义：t_n = t0 + n × frameDuration（设计方案 §3.1）。
/// `time(of:)` 与 `tick(at:)` 全是整数运算：n × p × 1e9 × denom / (q × numer) 在 128 位里一次乘除，
/// 不做浮点累加，所以第 216000 拍和第 1 拍一样精确。
public struct TickClockSpec: Hashable, Sendable, Codable {
    /// 第 0 拍的 host time。
    public var t0: HostTime
    /// 一拍的时长（秒），例如 1001/60000。
    public var frameDuration: Rational

    public init(t0: HostTime, frameDuration: Rational) {
        precondition(frameDuration.numerator > 0, "帧时长必须为正")
        self.t0 = t0
        self.frameDuration = frameDuration
    }
    public init(t0: HostTime, frameRate: FrameRate) {
        self.init(t0: t0, frameDuration: frameRate.frameDuration)
    }

    /// 帧率视图（frameDuration 的倒数）。
    public var frameRate: FrameRate { FrameRate(frameDuration.reciprocal) }

    /// 第 n 拍的理想时刻 = t0 + floor(n × frameDuration)，单位 host tick。
    public func time(of tick: Tick, timebase: MachTimebase = HostClock.timebase) -> HostTime {
        let p = Int128(frameDuration.numerator), q = Int128(frameDuration.denominator)
        let num = Int128(tick.rawValue) * p * 1_000_000_000 * Int128(timebase.denom)
        let den = q * Int128(timebase.numer)
        let result = Int128(t0.ticks) + TickClockSpec.floorDiv(num, den)
        precondition(result >= 0 && result <= Int128(UInt64.max), "拍点时刻超出 HostTime 范围")
        return HostTime(ticks: UInt64(result))
    }

    /// 时刻 t 属于哪一拍：最大的 n 使 time(of: n) ≤ t（t0 之前为负拍）。
    /// 与 `time(of:)` 严格互逆：tick(at: time(of: n)) == n，tick(at: time(of: n+1) − 1 tick) == n。
    public func tick(at time: HostTime, timebase: MachTimebase = HostClock.timebase) -> Tick {
        let p = Int128(frameDuration.numerator), q = Int128(frameDuration.denominator)
        let elapsed = Int128(time.ticks) - Int128(t0.ticks)
        // time(of: n) = floor(n × T) ≤ t  ⟺  n × T < t + 1  ⟺  n ≤ ceil((t + 1) / T) − 1
        let num = (elapsed + 1) * q * Int128(timebase.numer)
        let den = p * 1_000_000_000 * Int128(timebase.denom)
        return Tick(Int64(TickClockSpec.ceilDiv(num, den) - 1))
    }

    /// n 拍对应的 host tick 数（向下取整）；用于"转场 30 拍等于多少 host time"这类换算。
    public func duration(ofTicks n: Int, timebase: MachTimebase = HostClock.timebase) -> HostDuration {
        let p = Int128(frameDuration.numerator), q = Int128(frameDuration.denominator)
        let num = Int128(n) * p * 1_000_000_000 * Int128(timebase.denom)
        let den = q * Int128(timebase.numer)
        return HostDuration(ticks: Int64(TickClockSpec.floorDiv(num, den)))
    }

    static func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
        precondition(b > 0)
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }
    static func ceilDiv(_ a: Int128, _ b: Int128) -> Int128 {
        precondition(b > 0)
        let q = a / b
        return (a % b != 0 && a > 0) ? q + 1 : q
    }
}
