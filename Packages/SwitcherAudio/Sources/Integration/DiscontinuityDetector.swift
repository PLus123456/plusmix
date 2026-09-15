import Foundation

// 波形不连续检测（测试标准 A1 的第三项：输出中检出的不连续；W2-E prompt："相邻样本跳变 > 0.5 满幅且不在 click 位置"）。
//
// 两种用法：
//   - 流式（`feed`）：泵线程对 Master 块逐样本看，跨块边界连续；计数进状态快照（A1 的第三个加数）。
//     泵线程不知道 click 在哪，用"高电平平台"识别合成信号的 click：跳进去之后连续 ≥ 8 个样本 |x| ≥ 0.5（单声道 click +1.0
//     居中声像后每边 0.707，经 sinc 重采样有 ±0.03 的振铃，再叠别的输入 ±0.2 仍在线上），进平台 / 出平台的两次跳变不算不连续；
//     混音断裂 / 丢块 / 延迟线跳变产生的是一次孤立跳变，仍会被计到。Master 里 click 叠上更响的别路时启发式会失效（实测：
//     要求样本相同 → 100 次增删用例 60 个假阳性；电平 0.6 + 另一路 ±0.14 → 每秒 1 个假阳性），所以它只是给合成信号长跑看的
//     诊断数；正式的 A1 第三项按"已知 click 位置排除"的口径：`feed(..., isExcluded:)` 或离线 `analyze`。
//   - 离线（`analyze`）：测试对整段样本分析，用已知的 click 位置排除（TestSignal.isClick），不靠平台启发式。
public struct DiscontinuityDetector: Sendable {
    public struct Options: Hashable, Sendable {
        /// 跳变阈值（满幅比例）。
        public var threshold: Float = 0.5
        /// 是否忽略满幅平台的进出（流式用）。
        public var ignorePlateaus: Bool = true
        /// 平台最少样本数。
        public var plateauMinFrames: Int = 8
        /// 平台电平下限（|x|）：单声道 click 居中声像后 0.707，叠别路 ±0.2 仍 ≥ 0.5。
        public var plateauLevel: Float = 0.5
        public init() {}
    }

    /// 一次不连续。
    public struct Event: Hashable, Sendable {
        /// 自流起始的样本序号（跳到的那个样本）。
        public var sampleIndex: Int64
        public var channel: Int
        /// 跳变量（有符号）。
        public var jump: Float
    }

    private struct ChannelState {
        var prev: Float = 0
        /// 以 prev 结尾的平台长度（|x| ≥ 电平的样本数；允许单个样本掉下去——sinc 重采样后的 click 边沿有振铃——连续两个掉下去才清零）。
        var run: Int = 0
        var belowStreak: Int = 0
        /// 候选：跳进了一个可能的平台，还在数样本（seen = 在电平上的样本数，total = 跳变以来的样本数）。
        var pending: (index: Int64, jump: Float, seen: Int, total: Int)?
    }

    public let options: Options
    public let channels: Int
    /// 累计检出的不连续次数（同一样本序号上多个声道同时跳只算一次：混音断裂对所有声道同时发生）。
    public private(set) var count: UInt64 = 0
    /// 最近的事件（最多保留 64 个，够诊断用）。
    public private(set) var recent: [Event] = []
    /// 已处理的帧数。
    public private(set) var framesSeen: Int64 = 0
    private var states: [ChannelState]

    public init(channels: Int, options: Options = Options()) {
        precondition(channels >= 1)
        self.channels = channels
        self.options = options
        states = Array(repeating: ChannelState(), count: channels)
    }

    /// 流式喂一块（非交错平面）。返回本块新增的不连续数。
    /// `isExcluded(i)`（i = 自流起始的样本序号）为 true 的样本上的跳变不算（测试知道 click 在哪时用；跳入 / 跳出都排除）。
    @discardableResult
    public mutating func feed(planes: UnsafePointer<UnsafePointer<Float>>, frameCount: Int, isExcluded: ((Int64) -> Bool)? = nil) -> Int {
        var added = 0
        for c in 0..<channels {
            let x = planes[c]
            var s = states[c]
            for i in 0..<frameCount {
                let v = x[i]
                let idx = framesSeen + Int64(i)
                let jump = v - s.prev
                var big = abs(jump) > options.threshold
                if big, let ex = isExcluded, ex(idx) || ex(idx - 1) { big = false }
                let atLevel = abs(v) >= options.plateauLevel
                if big, var p = s.pending, atLevel {
                    // 两步上去的边沿（−0.10 → 0.42 → 1.03）：第二步仍在往电平上走，算同一个候选
                    p.total += 1; p.seen += 1
                    s.pending = p.seen >= options.plateauMinFrames ? nil : p
                } else if big {
                    if let p = s.pending {           // 候选平台被一次反向大跳变打断：候选是真不连续
                        added += countOnce(Event(sampleIndex: p.index, channel: c, jump: p.jump))
                        s.pending = nil
                    }
                    if options.ignorePlateaus && s.run >= options.plateauMinFrames {
                        // 出平台（click 结束）：忽略
                    } else if options.ignorePlateaus {
                        // 可能是进平台（click 开始；边沿落在两个样本之间时第一个样本可能还不到电平，AAC 解码后实测 −0.10 → 0.42 → 1.03）：
                        // 等 N + 4 个样本里 ≥ N 个在电平上
                        s.pending = (idx, jump, atLevel ? 1 : 0, 1)
                    } else {
                        added += countOnce(Event(sampleIndex: idx, channel: c, jump: jump))
                    }
                } else if var p = s.pending {
                    p.total += 1
                    if atLevel { p.seen += 1 }
                    if p.seen >= options.plateauMinFrames {
                        s.pending = nil
                    } else if p.total >= options.plateauMinFrames + 4 {
                        added += countOnce(Event(sampleIndex: p.index, channel: c, jump: p.jump))
                        s.pending = nil
                    } else {
                        s.pending = p
                    }
                }
                if atLevel {
                    s.run += 1; s.belowStreak = 0
                } else {
                    s.belowStreak += 1
                    if s.belowStreak >= 2 { s.run = 0 }
                }
                s.prev = v
            }
            states[c] = s
        }
        framesSeen += Int64(frameCount)
        return added
    }

    private var countedIndices: [Int64] = []
    private mutating func record(_ e: Event) {
        recent.append(e)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
    }
    /// 计一次（按样本序号去重：其他声道在同一序号已计过就不再加）。
    private mutating func countOnce(_ e: Event) -> Int {
        record(e)
        if countedIndices.contains(e.sampleIndex) { return 0 }
        countedIndices.append(e.sampleIndex)
        if countedIndices.count > 16 { countedIndices.removeFirst(countedIndices.count - 16) }
        count += 1
        return 1
    }

    /// 离线分析：单声道样本数组，`isExcluded(i)` 为 true 的位置（例如 click 窗口）不算（跳入 / 跳出都排除）。
    public static func analyze(samples: [Float], threshold: Float = 0.5, isExcluded: (Int64) -> Bool) -> [Event] {
        var events: [Event] = []
        guard samples.count >= 2 else { return events }
        for i in 1..<samples.count {
            let jump = samples[i] - samples[i - 1]
            guard abs(jump) > threshold else { continue }
            let idx = Int64(i)
            if isExcluded(idx) || isExcluded(idx - 1) { continue }
            events.append(Event(sampleIndex: idx, channel: 0, jump: jump))
        }
        return events
    }
}
