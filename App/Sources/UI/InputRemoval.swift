// W5-B 桩：删输入会影响到哪儿（红测试阶段）。
import SwitcherContracts

enum InputRemovalImpact: Equatable {
    case program, preview, overlay(channel: Int), stinger, isoRecording(output: Int, name: String)
    var text: String { "" }
    static func impacts(of number: Int, in state: MixerState) -> [InputRemovalImpact] { [] }
}
