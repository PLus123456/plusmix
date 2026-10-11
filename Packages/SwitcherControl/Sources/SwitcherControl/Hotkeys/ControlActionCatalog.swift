import SwitcherContracts

// 动作目录（W5-J，01a N1 / N3）：ControlAction 每种 case 的 JSON 键、类型化参数（与 CommandCatalog 同一套 CommandField）、能发哪些命令、分组。
// App 的"选动作"面板按它生成参数表单、在小字里写 API 键名；包一条命令的 `command` 另按 CommandCatalog 的那条命令描述。
// `init(of:)` 是穷举 switch：ControlAction 加 case 这里编译就红（同 CommandKind(of:)）。

/// ControlAction 的 case 名（= JSON 顶层键）。
public enum ControlActionKind: String, CaseIterable, Sendable, CodingKey {
    case command, toggleFTB, toggleOverlay, toggleMute, toggleRecord, toggleStream, toggleAFV
    case fadeMs, previewAndTransition, overlayInput, overlaysOff
    case outputSwitch, outputKindSwitch, recordAll, recordISO, streamAll
    case inputAFV, busRoute, solo, busMuteSwitch
    case ui
    case transitionSlot, selectTransitionSlot

    public init(of action: ControlAction) {
        switch action {
        case .command: self = .command
        case .toggleFTB: self = .toggleFTB
        case .toggleOverlay: self = .toggleOverlay
        case .toggleMute: self = .toggleMute
        case .toggleRecord: self = .toggleRecord
        case .toggleStream: self = .toggleStream
        case .toggleAFV: self = .toggleAFV
        case .fadeMs: self = .fadeMs
        case .previewAndTransition: self = .previewAndTransition
        case .overlayInput: self = .overlayInput
        case .overlaysOff: self = .overlaysOff
        case .outputSwitch: self = .outputSwitch
        case .outputKindSwitch: self = .outputKindSwitch
        case .recordAll: self = .recordAll
        case .recordISO: self = .recordISO
        case .streamAll: self = .streamAll
        case .inputAFV: self = .inputAFV
        case .busRoute: self = .busRoute
        case .solo: self = .solo
        case .busMuteSwitch: self = .busMuteSwitch
        case .ui: self = .ui
        case .transitionSlot: self = .transitionSlot
        case .selectTransitionSlot: self = .selectTransitionSlot
        }
    }

    /// 参数（JSON 那一层的键与类型）。`command` 的参数看所包命令的 CommandCatalog 描述，这里为空。
    public var fields: [CommandField] {
        let mode = CommandField(name: "mode", type: .switchMode)
        let input = CommandField(name: "input", type: .inputRef)
        switch self {
        case .command, .toggleFTB, .toggleAFV, .overlaysOff: return []
        case .toggleOverlay: return [CommandField(name: "channel", type: .overlayChannel)]
        case .toggleMute: return [input]
        case .toggleRecord: return [CommandField(name: "output", type: .output(kinds: [.record]))]
        case .toggleStream: return [CommandField(name: "output", type: .output(kinds: [.stream]))]
        case .fadeMs: return [CommandField(name: "durationMs", type: .durationMs)]
        case .previewAndTransition: return [input]
        case .overlayInput: return [CommandField(name: "channel", type: .overlayChannel), input]
        case .outputSwitch: return [CommandField(name: "output", type: .output(kinds: ControlAction.switchableKinds)), mode]
        case .outputKindSwitch: return [CommandField(name: "kind", type: .outputKind(kinds: ControlAction.switchableKinds)), mode]
        case .recordAll, .recordISO, .streamAll: return [mode]
        case .inputAFV, .solo: return [input, mode]
        case .busRoute: return [input, CommandField(name: "bus", type: .bus), mode]
        case .busMuteSwitch: return [CommandField(name: "bus", type: .bus), mode]
        case .ui: return [CommandField(name: "name", type: .text)]
        case .transitionSlot, .selectTransitionSlot: return []   // 红灯轮的桩
        }
    }

    /// 按下时可能发的命令（选动作面板的小字 API 键名、"按下时会发什么"）。界面动作不发命令；`command` 看所包的那条。
    public var emits: [CommandKind] {
        switch self {
        case .command: []
        case .toggleFTB: [.ftb]
        case .toggleOverlay, .overlayInput, .overlaysOff: [.overlay]
        case .toggleMute: [.mute]
        case .toggleRecord, .recordAll, .recordISO: [.startRecord, .stopRecord]
        case .toggleStream, .streamAll: [.startStream, .stopStream]
        case .toggleAFV: [.setAFV]
        case .fadeMs: [.fade]
        case .previewAndTransition: [.setPreview, .autoTransition]
        case .outputSwitch, .outputKindSwitch: [.setOutputEnabled]
        case .inputAFV, .busRoute, .solo: [.setInputSettings]
        case .busMuteSwitch: [.busMute]
        case .ui: []
        case .transitionSlot, .selectTransitionSlot: []   // 红灯轮的桩
        }
    }

    /// 分组（与 CommandCatalog 同一套：切换 / 叠加 / 音频 / 输出，另加"界面"）。`command` 看所包命令的分组。
    public var group: String {
        switch self {
        case .command: "命令"
        case .toggleFTB, .fadeMs, .previewAndTransition: "切换"
        case .toggleOverlay, .overlayInput, .overlaysOff: "叠加"
        case .toggleMute, .toggleAFV, .inputAFV, .busRoute, .solo, .busMuteSwitch: "音频"
        case .toggleRecord, .toggleStream, .recordAll, .recordISO, .streamAll, .outputSwitch, .outputKindSwitch: "输出"
        case .ui: "界面"
        case .transitionSlot, .selectTransitionSlot: ""   // 红灯轮的桩
        }
    }
}
