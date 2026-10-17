import SwitcherContracts

// 快捷键 / MIDI 按钮绑定的动作。多数就是一条 Command；开关型（FTB、叠加、静音、录制、推流、AFV）要看当前状态才知道发 on 还是 off，
// 所以单独列出，由派发方拿最新快照解析成 Command（状态只读快照、只发命令——设计方案 §9.1）。
// W5-J（prompt 96，01a N2 / N3，04 Q52 / Q53）：补开关与组合动作（输出开关、全部录制 / 只起停 ISO、推流全部开始 / 停止、每路跟随视频、
// 总线路由 / 独听 / 总线静音、叠加全关、"选进 PVW 并按已选转场执行"、"叠加 N 换成输入 X 并开"）、按毫秒存的 Fade、按下时才定的输入（当前 PVW / PGM）、
// 界面动作（只在 App 里派发，不进总线）。resolve 返回命令数组：组合动作按顺序逐条进总线（前一条被拒就不发后面的）。
// JSON 只加新键，旧的 hotkeys.json / midi.json 照读（旧的整数输入 = 编号）。
// W5-M（prompt 100，01a N6）：转场槽的两类动作——执行转场 n（useTransitionSlot(n, start: true)，一拍内选中并开始）、选中转场 n（start: false，
// 只换 T-bar / 回车用的当前槽）。回车仍是 autoTransition = 执行当前槽（当前那组就是当前槽的配置，提案 020）。
// W5-O（prompt 112）：⌃1–⌃4（toggleOverlay）对没指定输入的通道用当前 PVW 那一路开（与转场列 / 菜单栏"切换 › Overlay"同一口径）；
// 按下去没做成、要在状态行说一句的两种（叠加空通道 + PVW 黑场、执行没选输入的 Stinger——提案 029 起校验器拒）由派发器交给 App（ControlFeedback）。

/// 按下时才定的输入（N3）。JSON：整数 = 编号；"preview" / "program" = 按下那一刻 PVW / PGM 上的那一路（黑场 = 解析不出，这条动作不发）。
public enum InputRef: Hashable, Sendable, ExpressibleByIntegerLiteral {
    case number(Int)
    case preview
    case program

    public init(integerLiteral value: Int) { self = .number(value) }

    /// 按快照解析成输入编号；那一路不在、或当前 PVW / PGM 是黑场时为 nil。
    public func resolve(in state: MixerState) -> Int? {
        let n: Int
        switch self {
        case .number(let v): n = v
        case .preview: n = state.preview
        case .program: n = state.program
        }
        guard n != MixerState.noInput, state.input(n) != nil else { return nil }
        return n
    }
}

extension InputRef: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .number(n)
            return
        }
        switch try c.decode(String.self) {
        case "preview": self = .preview
        case "program": self = .program
        case let other: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "输入要么是编号，要么是 preview / program：\(other)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .preview: try c.encode("preview")
        case .program: try c.encode("program")
        }
    }
}

/// 开关动作的三种（N3：开 / 关 / 切换三段）。JSON："on" / "off" / "toggle"；缺省 = 切换。
public enum SwitchMode: String, Hashable, Sendable, Codable, CaseIterable {
    case on, off, toggle

    /// 目标状态：切换 = 当前取反。
    public func target(current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

/// 快捷键按下去没做成、要在状态行说一句的几种（W5-O）：派发器解析不出命令、或命令被总线拒时交给 App 设的 handler（HotkeyDispatcher.setFeedbackHandler）。
/// 其余的"没做成"（引用不存在、已是目标状态、别的结构性错误）照旧只记计数。
public enum ControlFeedback: Hashable, Sendable {
    /// 叠加 n 没指定输入、PVW 也是黑场：⌃n 开不了（与转场列 / 菜单栏"切换 › Overlay"同一句提示）。
    case overlayNeedsPreview(channel: Int)
    /// 要执行的转场是没选输入的 Stinger（提案 029：useTransitionSlot(start: true) / autoTransition 被校验器拒）；slot = nil：当前那组不对应任何槽。
    case stingerWithoutInput(slot: Int?)
}

/// 一个可绑定的动作。JSON：{"command": {<Command>}}、{"toggleFTB": {}}、{"toggleOverlay": {"channel": 1}}……（键 = case 名，见 ControlActionKind）。
public enum ControlAction: Hashable, Sendable {
    case command(Command)
    case toggleFTB
    case toggleOverlay(channel: Int)
    case toggleMute(input: InputRef)
    case toggleRecord(output: Int)
    case toggleStream(output: Int)
    case toggleAFV
    /// Fade，时长按毫秒存、按下时按当前节目帧率换成拍（Q52：快捷键表跨节目共用，按拍存的话 30p 换 60p 时长就减半）。
    case fadeMs(durationMs: Int)
    /// 选进 PVW 并按已选转场执行：setPreview → autoTransition。
    case previewAndTransition(input: InputRef)
    /// 叠加通道换成这一路并打开（一条 overlay 命令带 input）。
    case overlayInput(channel: Int, input: InputRef)
    /// 开着的叠加通道全关。
    case overlaysOff
    /// 一个非录制 / 推流输出（NDI / 外部显示 / 虚拟摄像头 / 多画面）的开关（setOutputEnabled）。
    case outputSwitch(output: Int, mode: SwitchMode)
    /// 某一类输出（同上四类）一起开 / 关：切换 = 有开着的就全关，否则全开。
    case outputKindSwitch(kind: OutputKind, mode: SwitchMode)
    /// 全部录制输出（PGM + ISO，同一次发出 = 同一拍起停）。
    case recordAll(mode: SwitchMode)
    /// 只起停 ISO（来源是某一路输入的录制输出）。
    case recordISO(mode: SwitchMode)
    /// 推流全部开始 / 全部停止。
    case streamAll(mode: SwitchMode)
    /// 这一路跟不跟随视频（InputAudioSettings.afv）。
    case inputAFV(input: InputRef, mode: SwitchMode)
    /// 这一路送不送某条总线。
    case busRoute(input: InputRef, bus: Bus, mode: SwitchMode)
    /// 这一路独听。
    case solo(input: InputRef, mode: SwitchMode)
    /// 总线静音。
    case busMuteSwitch(bus: Bus, mode: SwitchMode)
    /// 界面动作（显示 / 隐藏调音台、多画面窗口……，Q53）：只在 App 里派发，不进 CommandCatalog、不进总线；名字由 App 定。
    case ui(name: String)
    /// 执行转场 n（槽 1–4，提案 020）：选中并同一拍开始 auto 转场；转场进行中被状态机忽略（与 autoTransition 同口径）。
    case transitionSlot(slot: Int)
    /// 选中转场 n、不执行：之后 T-bar / 回车按这个槽走。
    case selectTransitionSlot(slot: Int)

    /// 按当前状态解析成命令（按顺序逐条进总线）；引用不存在的通道 / 输入 / 输出、或没什么要变的，返回空数组。
    public func resolve(in state: MixerState) -> [Command] {
        switch self {
        case .command(let c):
            return [c]
        case .toggleFTB:
            return [.ftb(on: !state.ftb.on)]
        case .toggleOverlay(let channel):
            guard (1...MixerState.overlayCount).contains(channel) else { return [] }
            // 开着 → 关（通道设置不清）；关着、指定了输入 → 开；没指定 → 用当前 PVW 那一路开（原来 input: nil，开了没画面，W5-O）；
            // PVW 也是黑场 → 不发（unresolvedFeedback 给一句提示）
            let overlay = state.overlays[channel - 1]
            if overlay.on || overlay.input != nil { return [.overlay(channel: channel, on: !overlay.on, input: nil)] }
            guard let preview = InputRef.preview.resolve(in: state) else { return [] }
            return [.overlay(channel: channel, on: true, input: preview)]
        case .toggleMute(let ref):
            guard let n = ref.resolve(in: state), let i = state.input(n) else { return [] }
            return [.mute(input: n, on: !i.settings.audio.muted)]
        case .toggleRecord(let output):
            guard let o = state.output(output), o.kind == .record else { return [] }
            return [o.enabled ? .stopRecord(output: output) : .startRecord(output: output)]
        case .toggleStream(let output):
            guard let o = state.output(output), o.kind == .stream else { return [] }
            return [o.enabled ? .stopStream(output: output) : .startStream(output: output)]
        case .toggleAFV:
            return [.setAFV(on: !state.audio.afv)]
        case .fadeMs(let ms):
            return [.fade(durationTicks: Self.ticks(milliseconds: ms, at: state.format.frameRate))]
        case .previewAndTransition(let ref):
            guard let n = ref.resolve(in: state) else { return [] }
            return [.setPreview(input: n), .autoTransition]
        case .overlayInput(let channel, let ref):
            guard (1...MixerState.overlayCount).contains(channel), let n = ref.resolve(in: state) else { return [] }
            return [.overlay(channel: channel, on: true, input: n)]
        case .overlaysOff:
            return state.overlays.enumerated().filter(\.element.on).map { .overlay(channel: $0.offset + 1, on: false, input: nil) }
        case .outputSwitch(let number, let mode):
            // 单路：显式目标照发（同 ftb(on:)，脚本可重放）
            guard let o = state.output(number), Self.switchableKinds.contains(o.kind) else { return [] }
            return [.setOutputEnabled(output: number, on: mode.target(current: o.enabled))]
        case .outputKindSwitch(let kind, let mode):
            guard Self.switchableKinds.contains(kind) else { return [] }
            return Self.switchAll(state.outputs.filter { $0.kind == kind }, mode: mode) { o, on in .setOutputEnabled(output: o.number, on: on) }
        case .recordAll(let mode):
            return Self.switchAll(state.outputs.filter { $0.kind == .record }, mode: mode) { o, on in on ? .startRecord(output: o.number) : .stopRecord(output: o.number) }
        case .recordISO(let mode):
            let iso = state.outputs.filter { o in
                guard o.kind == .record, case .input = o.settings.source else { return false }
                return true
            }
            return Self.switchAll(iso, mode: mode) { o, on in on ? .startRecord(output: o.number) : .stopRecord(output: o.number) }
        case .streamAll(let mode):
            return Self.switchAll(state.outputs.filter { $0.kind == .stream }, mode: mode) { o, on in on ? .startStream(output: o.number) : .stopStream(output: o.number) }
        case .inputAFV(let ref, let mode):
            return Self.changeAudio(ref, in: state) { a in a.afv = mode.target(current: a.afv) }
        case .busRoute(let ref, let bus, let mode):
            return Self.changeAudio(ref, in: state) { a in a.routing[bus] = mode.target(current: a.routing[bus]) }
        case .solo(let ref, let mode):
            return Self.changeAudio(ref, in: state) { a in a.solo = mode.target(current: a.solo) }
        case .busMuteSwitch(let bus, let mode):
            let muted = state.audio.buses.first { $0.bus == bus }?.muted ?? false
            return [.busMute(bus: bus, on: mode.target(current: muted))]
        case .ui:
            return []   // App 自己派发（HotkeyDispatcher / MIDIController 交给它设的 handler）
        case .transitionSlot(let slot):
            guard TransitionSlot.indexRange.contains(slot) else { return [] }
            return [.useTransitionSlot(slot: slot, start: true)]
        case .selectTransitionSlot(let slot):
            guard TransitionSlot.indexRange.contains(slot) else { return [] }
            return [.useTransitionSlot(slot: slot, start: false)]
        }
    }

    /// 解析不出命令时要在状态行说的那一句：只有"⌃n 开一个没指定输入的叠加通道、PVW 也是黑场"这一种（别的解析不出 = 引用不存在 / 没什么要变，不说）。
    public func unresolvedFeedback(in state: MixerState) -> ControlFeedback? {
        guard case .toggleOverlay(let channel) = self, (1...MixerState.overlayCount).contains(channel) else { return nil }
        let overlay = state.overlays[channel - 1]
        return !overlay.on && overlay.input == nil && InputRef.preview.resolve(in: state) == nil ? .overlayNeedsPreview(channel: channel) : nil
    }

    /// 命令被总线拒（CommandRejection）时要在状态行说的那一句：执行的是没选输入的 Stinger（提案 029，校验器按同一判定拒）。别的拒绝不说（只记计数）。
    public static func rejectionFeedback(for command: Command, in state: MixerState) -> ControlFeedback? {
        let t = state.transition
        switch command {
        case .useTransitionSlot(let slot, true):
            guard slot >= 1, slot - 1 < t.slots.count, t.slots[slot - 1].isStingerWithoutInput else { return nil }
            return .stingerWithoutInput(slot: slot)
        case .autoTransition:
            // 与校验器同口径（P5-3）：按要执行的当前那组判，对应槽时带槽号
            guard !t.isActive, t.currentGroup.isStingerWithoutInput else { return nil }
            return .stingerWithoutInput(slot: t.currentSlot)
        default:
            return nil
        }
    }

    /// outputSwitch / outputKindSwitch 管的四类（录制 / 推流有自己的起停命令，setOutputEnabled 对它们会被拒）。
    public static let switchableKinds: [OutputKind] = [.ndi, .externalDisplay, .virtualCamera, .multiview]

    /// 毫秒 → 拍（四舍五入，负数按 0）：1000 ms 在 30p 是 30 拍、59.94p 是 60 拍。
    public static func ticks(milliseconds: Int, at rate: FrameRate) -> Int {
        Int((Double(max(0, milliseconds)) * rate.framesPerSecond.doubleValue / 1000).rounded())
    }

    /// 一组输出一起开 / 关：切换 = 有开着的就全关，否则全开；只发状态要变的那几路（按输出表的顺序）。
    private static func switchAll(_ outputs: [OutputState], mode: SwitchMode, _ make: (OutputState, Bool) -> Command) -> [Command] {
        let on = mode.target(current: outputs.contains(where: \.enabled))
        return outputs.filter { $0.enabled != on }.map { make($0, on) }
    }

    /// 改这一路音频设置里的一位：没有单独的命令，按快照整体写回这一路的设置（setInputSettings）；没变就不发。
    private static func changeAudio(_ ref: InputRef, in state: MixerState, _ change: (inout InputAudioSettings) -> Void) -> [Command] {
        guard let n = ref.resolve(in: state), let input = state.input(n) else { return [] }
        var settings = input.settings
        change(&settings.audio)
        return settings == input.settings ? [] : [.setInputSettings(input: n, settings: settings)]
    }
}

extension ControlAction: Codable {
    // 手写 Codable：合成的会把无标签的 command 编成 {"command": {"_0": …}}；这里 command 直接嵌 Command 的 JSON。
    private enum Arg: String, CodingKey { case channel, input, output, durationMs, mode, kind, bus, name, slot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ControlActionKind.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "动作要恰好一个键：\(ControlActionKind.allCases.map(\.rawValue).joined(separator: " / "))"))
        }
        if key == .command {
            self = .command(try c.decode(Command.self, forKey: .command))
            return
        }
        // 没有参数的动作写 {} 也行、写 null 也行
        let n = try? c.nestedContainer(keyedBy: Arg.self, forKey: key)
        func arg<T: Decodable>(_ a: Arg, _ type: T.Type = T.self) throws -> T {
            guard let n else { throw DecodingError.keyNotFound(a, .init(codingPath: decoder.codingPath + [key], debugDescription: "\(key.rawValue) 缺 \(a.rawValue)")) }
            return try n.decode(T.self, forKey: a)
        }
        func mode() throws -> SwitchMode { try n?.decodeIfPresent(SwitchMode.self, forKey: .mode) ?? .toggle }
        switch key {
        case .command: fatalError("上面已处理")
        case .toggleFTB: self = .toggleFTB
        case .toggleAFV: self = .toggleAFV
        case .overlaysOff: self = .overlaysOff
        case .toggleOverlay: self = .toggleOverlay(channel: try arg(.channel))
        case .toggleMute: self = .toggleMute(input: try arg(.input))
        case .toggleRecord: self = .toggleRecord(output: try arg(.output))
        case .toggleStream: self = .toggleStream(output: try arg(.output))
        case .fadeMs: self = .fadeMs(durationMs: try arg(.durationMs))
        case .previewAndTransition: self = .previewAndTransition(input: try arg(.input))
        case .overlayInput: self = .overlayInput(channel: try arg(.channel), input: try arg(.input))
        case .outputSwitch: self = .outputSwitch(output: try arg(.output), mode: try mode())
        case .outputKindSwitch: self = .outputKindSwitch(kind: try arg(.kind), mode: try mode())
        case .recordAll: self = .recordAll(mode: try mode())
        case .recordISO: self = .recordISO(mode: try mode())
        case .streamAll: self = .streamAll(mode: try mode())
        case .inputAFV: self = .inputAFV(input: try arg(.input), mode: try mode())
        case .busRoute: self = .busRoute(input: try arg(.input), bus: try arg(.bus), mode: try mode())
        case .solo: self = .solo(input: try arg(.input), mode: try mode())
        case .busMuteSwitch: self = .busMuteSwitch(bus: try arg(.bus), mode: try mode())
        case .ui: self = .ui(name: try arg(.name))
        case .transitionSlot: self = .transitionSlot(slot: try arg(.slot))
        case .selectTransitionSlot: self = .selectTransitionSlot(slot: try arg(.slot))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ControlActionKind.self)
        let key = ControlActionKind(of: self)
        if case .command(let cmd) = self {
            try c.encode(cmd, forKey: .command)
            return
        }
        var n = c.nestedContainer(keyedBy: Arg.self, forKey: key)
        switch self {
        case .command, .toggleFTB, .toggleAFV, .overlaysOff: break
        case .toggleOverlay(let channel): try n.encode(channel, forKey: .channel)
        case .toggleMute(let input): try n.encode(input, forKey: .input)
        case .toggleRecord(let output), .toggleStream(let output): try n.encode(output, forKey: .output)
        case .fadeMs(let ms): try n.encode(ms, forKey: .durationMs)
        case .previewAndTransition(let input): try n.encode(input, forKey: .input)
        case .overlayInput(let channel, let input):
            try n.encode(channel, forKey: .channel)
            try n.encode(input, forKey: .input)
        case .outputSwitch(let output, let mode):
            try n.encode(output, forKey: .output)
            try n.encode(mode, forKey: .mode)
        case .outputKindSwitch(let kind, let mode):
            try n.encode(kind, forKey: .kind)
            try n.encode(mode, forKey: .mode)
        case .recordAll(let mode), .recordISO(let mode), .streamAll(let mode): try n.encode(mode, forKey: .mode)
        case .inputAFV(let input, let mode), .solo(let input, let mode):
            try n.encode(input, forKey: .input)
            try n.encode(mode, forKey: .mode)
        case .busRoute(let input, let bus, let mode):
            try n.encode(input, forKey: .input)
            try n.encode(bus, forKey: .bus)
            try n.encode(mode, forKey: .mode)
        case .busMuteSwitch(let bus, let mode):
            try n.encode(bus, forKey: .bus)
            try n.encode(mode, forKey: .mode)
        case .ui(let name): try n.encode(name, forKey: .name)
        case .transitionSlot(let slot), .selectTransitionSlot(let slot): try n.encode(slot, forKey: .slot)
        }
    }
}
