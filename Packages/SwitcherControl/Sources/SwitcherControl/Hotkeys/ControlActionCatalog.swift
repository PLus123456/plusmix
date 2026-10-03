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
        }
    }

    /// 参数（JSON 那一层的键与类型）。`command` 的参数看所包命令的 CommandCatalog 描述，这里为空。
    public var fields: [CommandField] { [] }   // 红灯轮：只有签名

    /// 按下时可能发的命令（选动作面板的小字 API 键名、"按下时会发什么"）。界面动作不发命令。
    public var emits: [CommandKind] { [] }   // 红灯轮：只有签名

    /// 分组（与 CommandCatalog 同一套：切换 / 叠加 / 音频 / 输出，另加"界面"）。
    public var group: String { "" }   // 红灯轮：只有签名
}
