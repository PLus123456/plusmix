import SwitcherContracts

/// 同一拍起 / 停：给一批录制器同一个拍。ISO 分路 = 同一拍发多条 startRecord（CONTRACTS.md §8），各条命令的生效拍可能相邻、
/// 组装方看到它们也可能分在两次快照轮询里；这里的规则让它们仍共用一个拍：
/// - 一批（一次 `plan(batch:)`）：拍 = max(现在之后第 `minimumFutureTicks` 拍, 批里最晚的生效拍 + `leadTicks` + 每多一路加 `extraTicksPerRoute`)。
///   lead 要盖住 Recorder.start（VT 会话创建，实测 64–80 ms）和主线程的快照轮询；批里多路的 start 串行做，所以每多一路再加一点。
/// - 后来的一路：上一批的拍还在"现在之后至少 `reuseMinimumFutureTicks` 拍"就沿用它（同一拍起步），否则另起一批。
/// 起点用 `.start` 参数（lead 10 拍、沿用要求 ≥ 6 拍在未来），边界用 `.stop`（lead 10 拍、沿用要求 ≥ 1 拍）。
/// 纯逻辑，组装方持有一个实例；不涉及线程。
public struct SharedTickPlanner: Sendable, Hashable {
    /// 命令生效拍之后再等多少拍。
    public var leadTicks: Int
    /// 批里每多一路再加的拍数（Recorder.start 串行）。
    public var extraTicksPerRoute: Int
    /// 新批的拍至少在现在之后这么多拍。
    public var minimumFutureTicks: Int
    /// 沿用上一批的拍的条件：它至少还在现在之后这么多拍。
    public var reuseMinimumFutureTicks: Int
    /// 上一批的拍。
    public private(set) var pending: Tick?

    public init(leadTicks: Int, extraTicksPerRoute: Int, minimumFutureTicks: Int, reuseMinimumFutureTicks: Int) {
        self.leadTicks = leadTicks
        self.extraTicksPerRoute = extraTicksPerRoute
        self.minimumFutureTicks = minimumFutureTicks
        self.reuseMinimumFutureTicks = reuseMinimumFutureTicks
    }

    /// 起点：lead 10 拍（W2-B2 的提前量），每多一路 + 3 拍（50 ms），新批 ≥ 现在 + 2，沿用要求 ≥ 现在 + 6（100 ms，够 VT 会话创建）。
    public static let start = SharedTickPlanner(leadTicks: 10, extraTicksPerRoute: 3, minimumFutureTicks: 2, reuseMinimumFutureTicks: 6)
    /// 边界：lead 10 拍（与起点一样长，文件时长 = 两条命令生效拍之差），新批 ≥ 现在 + 1，沿用要求 ≥ 现在 + 1。
    public static let stop = SharedTickPlanner(leadTicks: 10, extraTicksPerRoute: 0, minimumFutureTicks: 1, reuseMinimumFutureTicks: 1)

    /// 给一批路（appliedTicks = 各路命令的生效拍，记不到的为 nil）一个共用的拍。
    public mutating func plan(batch appliedTicks: [Tick?], clock: TickClockSpec, now: HostTime) -> Tick {
        let nowTick = clock.tick(at: now)
        if let p = pending, p >= nowTick + reuseMinimumFutureTicks { return p }
        var tick = nowTick + minimumFutureTicks
        let routes = max(1, appliedTicks.count)
        if let latest = appliedTicks.compactMap({ $0 }).max() {
            tick = max(tick, latest + leadTicks + extraTicksPerRoute * (routes - 1))
        }
        pending = tick
        return tick
    }

    /// 一路的便利写法。
    public mutating func plan(appliedTick: Tick?, clock: TickClockSpec, now: HostTime) -> Tick {
        plan(batch: [appliedTick], clock: clock, now: now)
    }

    /// 忘掉上一批（换节目 / 停引擎）。
    public mutating func reset() { pending = nil }
}
