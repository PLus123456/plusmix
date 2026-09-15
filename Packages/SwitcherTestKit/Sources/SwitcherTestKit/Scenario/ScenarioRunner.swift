import Foundation
import SwitcherContracts

/// 场景执行器（测试标准 §2.4）：引擎每拍回调 `advance(to:)`，到点的事件通过 `emit` 闭包发出。
/// 自己不带时钟；引擎跳拍时（missed render）落在被跳过的拍上的事件在下一次回调补发，并计 `lateEvents`。
/// 只能从一个线程调（引擎的拍回调线程）。
public final class ScenarioRunner {
    public let scenario: Scenario
    private let events: [ScenarioEvent]
    private var cursor = 0
    private var lastTick: Tick?
    private let emit: (Tick, Command) -> Void
    /// 已发出的事件数。
    public private(set) var emittedCount = 0
    /// 在比计划晚的拍上发出的事件数。
    public private(set) var lateEvents = 0

    public init(scenario: Scenario, emit: @escaping (Tick, Command) -> Void) {
        self.scenario = scenario
        events = scenario.sortedEvents
        self.emit = emit
    }

    /// 下一个未发事件的拍；全发完为 nil。
    public var nextEventTick: Tick? { cursor < events.count ? events[cursor].tick : nil }
    /// 是否已跑到 durationTicks（最近一次回调的拍 ≥ durationTicks）。
    public var isFinished: Bool { lastTick.map { $0.rawValue >= Int64(scenario.durationTicks) } ?? false }

    /// 引擎到了第 `tick` 拍：发出所有 tick ≤ 它的未发事件（同一拍按文件顺序）。
    public func advance(to tick: Tick) {
        lastTick = tick
        while cursor < events.count && events[cursor].tick <= tick {
            let e = events[cursor]
            cursor += 1
            if e.tick < tick { lateEvents += 1 }
            emittedCount += 1
            emit(tick, e.command)
        }
    }

    /// 读 JSON 场景文件。
    public static func load(from url: URL) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    }
}
