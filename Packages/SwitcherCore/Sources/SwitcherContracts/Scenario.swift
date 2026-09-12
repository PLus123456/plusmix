/// 场景脚本（测试标准 §2.4）：在指定拍发命令。ScenarioRunner（W1-A）读它，"当前拍"由引擎回调驱动。
public struct Scenario: Hashable, Codable, Sendable {
    /// 脚本总长（拍）；跑到这一拍结束。
    public var durationTicks: Int
    /// 事件列表（文件顺序）。
    public var events: [ScenarioEvent]

    public init(durationTicks: Int, events: [ScenarioEvent]) {
        self.durationTicks = durationTicks
        self.events = events
    }

    /// 按 tick 稳定排序的视图（同一拍的事件保持文件顺序）。
    public var sortedEvents: [ScenarioEvent] {
        events.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)
    }
}

/// 在某一拍发一条命令。
public struct ScenarioEvent: Hashable, Codable, Sendable {
    /// 哪一拍。
    public var tick: Tick
    /// 发什么。
    public var command: Command
    public init(tick: Tick, command: Command) {
        self.tick = tick
        self.command = command
    }
}
