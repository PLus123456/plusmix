import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// 测试公用：一个 4 路合成源 + 录制 / 推流输出的状态，与 SwitcherEngineTests.ReducerTests.baseState 同形。
enum TestStates {
    static func base(inputs: Int = 4) -> MixerState {
        var s = MixerState(format: .hd1080p60)
        s.inputs = (1...inputs).map { InputConfig(number: $0, name: "机位 \($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        s.outputs = [
            OutputState(number: 1, kind: .record, name: "录制", settings: OutputSettings(record: RecordSettings(directory: "/tmp"))),
            OutputState(number: 2, kind: .stream, name: "推流", settings: OutputSettings(stream: StreamSettings(url: "rtmp://x/y"))),
        ]
        s.program = 1
        s.preview = 2
        return s
    }
}

/// 起好线程的状态机 + 总线。
struct BusFixture {
    let stateMachine: StateMachine
    let bus: CommandBus

    init(state: MixerState = TestStates.base(), startTick: Tick = .zero) {
        stateMachine = StateMachine(initialState: state, startTick: startTick)
        stateMachine.start()
        bus = CommandBus(stateMachine: stateMachine)
    }

    func stop() { stateMachine.stop() }
}

extension XCTestCase {
    /// 轮询等条件成立（默认 5 s）。
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
