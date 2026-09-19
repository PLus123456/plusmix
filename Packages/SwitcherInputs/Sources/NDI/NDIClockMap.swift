import Darwin
import SwitcherContracts

/// 发送端时间戳 → 抖动估计（NDI 抖动缓冲的数学；SwitcherNDI.swift 头注释有整体说明）。
///
/// NDI 每帧带 `timestamp`：发送端 SDK 在提交那一刻用发送端系统时钟打的戳（100 ns）。本机收到时读一次墙钟（CLOCK_REALTIME，
/// 与 host time 背靠背读），d_k = 墙钟 − 时间戳 = 网络传输时间 + 两台机器的钟差。钟差不知道也不用知道：只看 d 的**变化**——
/// 最近 1–2 s 内 d 的最小值 m 是"最快路径 + 钟差"，jitter_k = d_k − m 就是这一帧比最快的那帧多等了多久。
///
/// - 基线用两个 1 s 的块轮换取最小值：路径变慢 / 钟漂时 m 在 ≤ 2 s 内跟上；出现更小的 d 立刻采用（那帧 jitter = 0）。
/// - |d_k − m| > 1 s 视为钟跳变（发送端换机器、对时），基线重置，计 resets。
/// - 时间戳缺失（INT64_MAX）→ jitter 0（退化成"到达即 pts"）。
/// 全部整数运算（100 ns 单位）；不是热路径（接收线程），但也没有分配。
public struct NDIClockMap: Sendable {
    /// 基线块长（ns）。基线 = 当前块与上一块最小值中的较小者，所以跟随时间 1–2 个块长。
    public var blockDurationNs: Int64 = 1_000_000_000
    /// 钟跳变门限（100 ns 单位），默认 1 s。
    public var resetThreshold100ns: Int64 = 10_000_000

    private var currentMin: Int64 = .max
    private var previousMin: Int64 = .max
    private var blockStartHostTicks: UInt64 = 0

    /// 观察过的样本数（时间戳缺失的不算）。
    public private(set) var samples: UInt64 = 0
    /// 基线重置次数。
    public private(set) var resets: UInt64 = 0
    /// 最近一帧的抖动（100 ns）。
    public private(set) var lastJitter100ns: Int64 = 0
    /// 最大抖动（100 ns）。
    public private(set) var maxJitter100ns: Int64 = 0
    /// 抖动累计（100 ns），meanJitter 用。
    public private(set) var sumJitter100ns: Int64 = 0

    public init() {}

    /// 当前基线（100 ns），还没有样本时 nil。
    public var baseline100ns: Int64? {
        let b = min(currentMin, previousMin)
        return b == .max ? nil : b
    }
    /// 平均抖动（ms）。
    public var meanJitterMs: Double { samples == 0 ? 0 : Double(sumJitter100ns) / Double(samples) / 10_000 }
    /// 最大抖动（ms）。
    public var maxJitterMs: Double { Double(maxJitter100ns) / 10_000 }

    /// 本机墙钟（CLOCK_REALTIME）的 100 ns 值；与 `HostClock.now()` 背靠背读。
    @inline(__always)
    public static func wallClock100ns() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_REALTIME) / 100) }

    /// 记一帧。返回这帧的抖动（≥ 0）；时间戳缺失返回 0。
    /// - Parameters:
    ///   - ts: 发送端时间戳（100 ns）。
    ///   - arrivalHost: 到达时刻 host time。
    ///   - arrivalWall100ns: 同一刻的墙钟（`wallClock100ns()`）。
    @discardableResult
    public mutating func observe(senderTimestamp100ns ts: Int64, arrivalHost: HostTime, arrivalWall100ns: Int64) -> HostDuration {
        guard ts != Int64.max, ts > 0 else {
            lastJitter100ns = 0
            return .zero
        }
        let d = arrivalWall100ns &- ts
        // 块轮换（按 host time）
        if blockStartHostTicks == 0 {
            blockStartHostTicks = arrivalHost.ticks
        } else if HostDuration(ticks: Int64(bitPattern: arrivalHost.ticks &- blockStartHostTicks)).nanoseconds >= blockDurationNs {
            previousMin = currentMin
            currentMin = .max
            blockStartHostTicks = arrivalHost.ticks
        }
        var base = min(currentMin, previousMin)
        if base != .max, abs(d &- base) > resetThreshold100ns {
            currentMin = .max
            previousMin = .max
            base = .max
            resets += 1
        }
        if d < currentMin { currentMin = d }
        if base == .max || d < base { base = d }
        let jitter = max(0, d - base)
        samples += 1
        lastJitter100ns = jitter
        if jitter > maxJitter100ns { maxJitter100ns = jitter }
        sumJitter100ns += jitter
        return HostDuration(nanoseconds: jitter * 100)
    }
}

/// 线性插值重采样（非 48 kHz 的 NDI 源用；NDI 几乎总是 48 kHz，这是兜底，音质够第一版）。
/// 多声道共用一个相位；块与块之间连续（记住每声道最后一个样本）。不是热路径（接收线程）。
public struct NDILinearResampler: Sendable {
    public let sourceRate: Int
    public let targetRate: Int
    private var phase: Double = 0          // 下一个输出样本在源序列里的位置（相对本块首样本，可为负：落在上一块末样本与本块首样本之间）
    private var last: [Float]              // 每声道上一块的最后一个样本
    private var primed = false

    public init(sourceRate: Int, targetRate: Int, channels: Int) {
        precondition(sourceRate > 0 && targetRate > 0 && channels > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        last = Array(repeating: 0, count: channels)
    }

    /// 输出 / 输入采样率比。
    public var ratio: Double { Double(targetRate) / Double(sourceRate) }

    /// 把一块源样本重采样后**追加**进 `output[c]`。`input[c]` 各 `frames` 个样本。返回追加的帧数。
    @discardableResult
    public mutating func process(input: [UnsafePointer<Float>], frames: Int, into output: inout [[Float]]) -> Int {
        let channels = last.count
        guard frames > 0, input.count >= channels, output.count >= channels else { return 0 }
        let step = Double(sourceRate) / Double(targetRate)
        var produced = 0
        // 第一块：从位置 0 开始（没有上一块可插）
        if !primed {
            phase = 0
            primed = true
        }
        var pos = phase
        // 源位置 p ∈ [-1, frames-1) 可插：p < 0 用 last 与 input[0]
        while pos < Double(frames - 1) {
            let i = Int(pos.rounded(.down))
            let frac = Float(pos - Double(i))
            for c in 0..<channels {
                let a: Float = i < 0 ? last[c] : input[c][i]
                let b: Float = input[c][i + 1]
                output[c].append(a + (b - a) * frac)
            }
            produced += 1
            pos += step
        }
        // 下一块的位置相对下一块首样本：本块有 frames 个样本，位置 frames 就是下一块的 0
        phase = pos - Double(frames)
        for c in 0..<channels { last[c] = input[c][frames - 1] }
        return produced
    }
}
