import XCTest
import Foundation
import SwitcherContracts
@testable import SwitcherTestKit

/// ScenarioRunner：按拍发命令，"当前拍"由引擎回调驱动，不自带时钟。
final class ScenarioRunnerTests: XCTestCase {
    private let scenario = Scenario(durationTicks: 100, events: [
        ScenarioEvent(tick: Tick(20), command: .setPreview(input: 2)),
        ScenarioEvent(tick: Tick(10), command: .cut),
        ScenarioEvent(tick: Tick(10), command: .fade(durationTicks: 30)),
        ScenarioEvent(tick: Tick(-5), command: .ftb(on: false)),
    ])

    func testW1A_scenarioRunner_emitsInTickOrderWhenTicksArrive() {
        var log: [(Tick, Command)] = []
        let runner = ScenarioRunner(scenario: scenario) { log.append(($0, $1)) }
        XCTAssertEqual(runner.nextEventTick, Tick(-5))
        runner.advance(to: Tick(0))
        XCTAssertEqual(log.map(\.0), [Tick(0)], "负拍事件在第一次回调时补发")
        XCTAssertEqual(log[0].1, .ftb(on: false))
        XCTAssertEqual(runner.lateEvents, 1)
        runner.advance(to: Tick(9))
        XCTAssertEqual(log.count, 1)
        runner.advance(to: Tick(10))
        XCTAssertEqual(log.map(\.1), [.ftb(on: false), .cut, .fade(durationTicks: 30)], "同一拍按文件顺序")
        XCTAssertEqual(log[1].0, Tick(10))
        runner.advance(to: Tick(10))
        XCTAssertEqual(log.count, 3, "同一拍再回调不重发")
        runner.advance(to: Tick(30))
        XCTAssertEqual(log.count, 4); XCTAssertEqual(log[3].0, Tick(30)); XCTAssertEqual(log[3].1, .setPreview(input: 2))
        XCTAssertEqual(runner.lateEvents, 2, "第 20 拍没回调，事件在第 30 拍补发算迟到")
        XCTAssertFalse(runner.isFinished)
        XCTAssertNil(runner.nextEventTick)
        runner.advance(to: Tick(100))
        XCTAssertTrue(runner.isFinished)
        XCTAssertEqual(runner.emittedCount, 4)
    }

    func testW1A_scenarioRunner_loadsJSONFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1a-\(UUID().uuidString).json")
        try """
        {"durationTicks": 3000, "events": [{"tick": 1000, "command": {"cut": {}}}, {"tick": 3000, "command": {"fade": {"durationTicks": 30}}}]}
        """.write(to: url, atomically: true, encoding: .utf8)
        let s = try ScenarioRunner.load(from: url)
        XCTAssertEqual(s.durationTicks, 3000)
        XCTAssertEqual(s.events, [ScenarioEvent(tick: Tick(1000), command: .cut), ScenarioEvent(tick: Tick(3000), command: .fade(durationTicks: 30))])
        var fired: [Tick] = []
        let runner = ScenarioRunner(scenario: s) { t, _ in fired.append(t) }
        for t in stride(from: 0, through: 3000, by: 1) { runner.advance(to: Tick(Int64(t))) }
        XCTAssertEqual(fired, [Tick(1000), Tick(3000)])
        XCTAssertTrue(runner.isFinished); XCTAssertEqual(runner.lateEvents, 0)
    }

    func testW1A_scenarioRunner_emptyScenarioFinishesAtDuration() {
        let runner = ScenarioRunner(scenario: Scenario(durationTicks: 0, events: [])) { _, _ in XCTFail("没有事件") }
        XCTAssertFalse(runner.isFinished)
        runner.advance(to: Tick(0))
        XCTAssertTrue(runner.isFinished)
    }
}
