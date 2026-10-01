// 删一路输入会影响到哪儿（W5-B，01a D9 / 02 X13，04 Q06）：在 PGM / PVW / 开着的叠加通道 / Stinger / 正在录的 ISO 上时先确认、写明后果；
// 其余直接删（与参考截图时的设置一致）。删 PGM 那一路 = PGM 变黑场（Command.removeInput：那些位置变成 0 / null），又没有撤销，所以要问。
import SwitcherContracts

enum InputRemovalImpact: Equatable {
    case program
    case preview
    /// 开着的叠加通道（1–4）正用它。关着的通道里放着它不算：画面上没有它。
    case overlay(channel: Int)
    /// Stinger 转场用它。
    case stinger
    /// 正在录它的 ISO 路（录制输出编号、名字）。
    case isoRecording(output: Int, name: String)

    /// 确认框里的一行后果。
    var text: String {
        switch self {
        case .program: L("confirm.removeInput.program")
        case .preview: L("confirm.removeInput.preview")
        case .overlay(let channel): L("confirm.removeInput.overlay", channel)
        case .stinger: L("confirm.removeInput.stinger")
        case .isoRecording(_, let name): L("confirm.removeInput.iso", name)
        }
    }

    /// 按快照算：删 number 这一路会碰到的地方（空 = 直接删）。
    static func impacts(of number: Int, in state: MixerState) -> [InputRemovalImpact] {
        var out: [InputRemovalImpact] = []
        if state.program == number { out.append(.program) }
        if state.preview == number { out.append(.preview) }
        for (i, o) in state.overlays.enumerated() where o.on && o.input == number { out.append(.overlay(channel: i + 1)) }
        if state.transition.stinger.input == number { out.append(.stinger) }
        for o in state.outputs where o.kind == .record && o.enabled && o.settings.source == .input(number: number) {
            out.append(.isoRecording(output: o.number, name: o.name))
        }
        return out
    }
}
