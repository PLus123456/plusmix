import SwitcherContracts

// 快捷键 / MIDI 按钮绑定的动作。多数就是一条 Command；开关型（FTB、叠加、静音、录制、推流、AFV）要看当前状态才知道发 on 还是 off，
// 所以单独列出，由派发方拿最新快照解析成 Command（状态只读快照、只发命令——设计方案 §9.1）。
// W5-J（prompt 96，01a N2 / N3，04 Q52 / Q53）：补开关与组合动作（输出开关、全部录制 / 只起停 ISO、推流全部开始 / 停止、每路跟随视频、
// 总线路由 / 独听 / 总线静音、叠加全关、"选进 PVW 并按已选转场执行"、"叠加 N 换成输入 X 并开"）、按毫秒存的 Fade、按下时才定的输入（当前 PVW / PGM）、
// 界面动作（只在 App 里派发，不进总线）。resolve 返回命令数组：组合动作按顺序逐条进总线（前一条被拒就不发后面的）。
// JSON 只加新键，旧的 hotkeys.json / midi.json 照读（旧的整数输入 = 编号）。

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

    /// 按当前状态解析成命令（按顺序逐条进总线）；引用不存在的通道 / 输入 / 输出、或没什么要变的，返回空数组。
    public func resolve(in state: MixerState) -> [Command] {
        switch self {
        case .command(let c):
            return [c]
        case .toggleFTB:
            return [.ftb(on: !state.ftb.on)]
        case .toggleOverlay(let channel):
            guard (1...MixerState.overlayCount).contains(channel) else { return [] }
            return [.overlay(channel: channel, on: !state.overlays[channel - 1].on, input: nil)]
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
    private enum Arg: String, CodingKey { case channel, input, output, durationMs, mode, kind, bus, name }

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
        }
    }
}
