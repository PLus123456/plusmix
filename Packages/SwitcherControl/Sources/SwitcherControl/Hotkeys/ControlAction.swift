import SwitcherContracts

// 快捷键 / MIDI 按钮绑定的动作。多数就是一条 Command；开关型（FTB、叠加、静音、录制、推流、AFV）要看当前状态才知道发 on 还是 off，
// 所以单独列出，由派发方拿最新快照解析成 Command（状态只读快照、只发命令——设计方案 §9.1）。

/// 一个可绑定的动作。JSON：{"command": {<Command>}}、{"toggleFTB": {}}、{"toggleOverlay": {"channel": 1}}……
public enum ControlAction: Hashable, Sendable {
    case command(Command)
    case toggleFTB
    case toggleOverlay(channel: Int)
    case toggleMute(input: Int)
    case toggleRecord(output: Int)
    case toggleStream(output: Int)
    case toggleAFV

    /// 按当前状态解析成一条命令；引用不存在的通道 / 输入 / 输出返回 nil。
    public func resolve(in state: MixerState) -> Command? {
        switch self {
        case .command(let c):
            return c
        case .toggleFTB:
            return .ftb(on: !state.ftb.on)
        case .toggleOverlay(let channel):
            guard (1...MixerState.overlayCount).contains(channel) else { return nil }
            return .overlay(channel: channel, on: !state.overlays[channel - 1].on, input: nil)
        case .toggleMute(let input):
            guard let i = state.input(input) else { return nil }
            return .mute(input: input, on: !i.settings.audio.muted)
        case .toggleRecord(let output):
            guard let o = state.output(output), o.kind == .record else { return nil }
            return o.enabled ? .stopRecord(output: output) : .startRecord(output: output)
        case .toggleStream(let output):
            guard let o = state.output(output), o.kind == .stream else { return nil }
            return o.enabled ? .stopStream(output: output) : .startStream(output: output)
        case .toggleAFV:
            return .setAFV(on: !state.audio.afv)
        }
    }
}

extension ControlAction: Codable {
    // 手写 Codable：合成的会把无标签的 command 编成 {"command": {"_0": …}}；这里 command 直接嵌 Command 的 JSON。
    private enum Key: String, CodingKey { case command, toggleFTB, toggleOverlay, toggleMute, toggleRecord, toggleStream, toggleAFV }
    private enum Arg: String, CodingKey { case channel, input, output }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "动作要恰好一个键：command / toggleFTB / toggleOverlay / toggleMute / toggleRecord / toggleStream / toggleAFV"))
        }
        switch key {
        case .command: self = .command(try c.decode(Command.self, forKey: .command))
        case .toggleFTB: _ = try? c.nestedContainer(keyedBy: Arg.self, forKey: .toggleFTB); self = .toggleFTB
        case .toggleAFV: _ = try? c.nestedContainer(keyedBy: Arg.self, forKey: .toggleAFV); self = .toggleAFV
        case .toggleOverlay: self = .toggleOverlay(channel: try c.nestedContainer(keyedBy: Arg.self, forKey: .toggleOverlay).decode(Int.self, forKey: .channel))
        case .toggleMute: self = .toggleMute(input: try c.nestedContainer(keyedBy: Arg.self, forKey: .toggleMute).decode(Int.self, forKey: .input))
        case .toggleRecord: self = .toggleRecord(output: try c.nestedContainer(keyedBy: Arg.self, forKey: .toggleRecord).decode(Int.self, forKey: .output))
        case .toggleStream: self = .toggleStream(output: try c.nestedContainer(keyedBy: Arg.self, forKey: .toggleStream).decode(Int.self, forKey: .output))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .command(let cmd): try c.encode(cmd, forKey: .command)
        case .toggleFTB: _ = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleFTB)
        case .toggleAFV: _ = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleAFV)
        case .toggleOverlay(let channel):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleOverlay)
            try n.encode(channel, forKey: .channel)
        case .toggleMute(let input):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleMute)
            try n.encode(input, forKey: .input)
        case .toggleRecord(let output):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleRecord)
            try n.encode(output, forKey: .output)
        case .toggleStream(let output):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .toggleStream)
            try n.encode(output, forKey: .output)
        }
    }
}
