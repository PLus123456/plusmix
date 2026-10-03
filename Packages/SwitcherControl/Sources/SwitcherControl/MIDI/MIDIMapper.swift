import SwitcherContracts

// MIDI 的纯函数部分：UMP 字解析成消息、消息按表映射成命令。不碰 CoreMIDI，单元测试直接测。

/// 一条收到的 MIDI 消息（只关心 CC 和 Note）。
public struct MIDIMessage: Hashable, Sendable {
    public var trigger: MIDITrigger
    /// CC 的值或 Note 的力度，0–127。
    public var value: Int
    /// Note Off（或力度 0 的 Note On 也当松开，但 isNoteOff 只标真正的 Note Off）。
    public var isNoteOff: Bool
    /// 收到时的 host time（CoreMIDI 的 timeStamp；0 表示"现在"时换成收到时刻）。
    public var timestamp: HostTime

    public init(trigger: MIDITrigger, value: Int, isNoteOff: Bool = false, timestamp: HostTime) {
        self.trigger = trigger
        self.value = value
        self.isNoteOff = isNoteOff
        self.timestamp = timestamp
    }
}

/// UMP（Universal MIDI Packet）解析：只认 MIDI 1.0 通道消息（消息类型 2），其余按各自字长跳过。
public enum MIDIUMP {
    /// 每种消息类型占几个 32 位字（MIDI 2.0 规范 2.1.4）。
    static func wordCount(ofType mt: UInt32) -> Int {
        switch mt {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    public static func parse(words: [UInt32], timestamp: HostTime) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let mt = w >> 28
            let n = wordCount(ofType: mt)
            if mt == 0x2 {
                let status = (w >> 16) & 0xFF
                let channel = Int(status & 0x0F) + 1
                let d1 = Int((w >> 8) & 0x7F)
                let d2 = Int(w & 0x7F)
                switch status & 0xF0 {
                case 0xB0: out.append(MIDIMessage(trigger: .cc(channel: channel, controller: d1), value: d2, timestamp: timestamp))
                case 0x90: out.append(MIDIMessage(trigger: .note(channel: channel, note: d1), value: d2, timestamp: timestamp))
                case 0x80: out.append(MIDIMessage(trigger: .note(channel: channel, note: d1), value: d2, isNoteOff: true, timestamp: timestamp))
                default: break
                }
            }
            i += n
        }
        return out
    }
}

/// T-bar 换向：推到一端提交，之后反向的行程是下一次转场的 0 → 1（真推杆的手感）。
public struct TBarMapper: Hashable, Sendable {
    public var inverted = false
    public init() {}

    /// 0…max → 进度 0–1（7-bit max = 127，14-bit max = 16383）。
    public mutating func progress(forValue value: Int, max: Int = 127) -> Double {
        let raw = Double(Swift.min(Swift.max(value, 0), max)) / Double(max)
        let p = inverted ? 1 - raw : raw
        if p >= 1 {
            inverted.toggle()
            return 1
        }
        return p
    }
}

/// 表 + T-bar 状态 → 命令。
public struct MIDIMapper: Sendable {
    public var table: MIDIMapTable
    public var tbar = TBarMapper()
    /// 14-bit 配对：最近收到的 MSB，键 = (通道, MSB 控制器号)。
    private var msb: [Pair: Int] = [:]

    private struct Pair: Hashable { let channel: Int; let controller: Int }

    public init(table: MIDIMapTable) { self.table = table }

    /// 一条消息对应的第一条命令（老调用方；组合动作用 commands）。
    public mutating func command(for message: MIDIMessage, state: MixerState) -> Command? {
        commands(for: message, state: state).first
    }

    /// 音符按下时绑的是界面动作（ControlAction.ui）就给它的名字（不进总线，MIDIController 交给 App 设的 handler）。
    public func uiAction(for message: MIDIMessage) -> String? {
        guard case .note = message.trigger, !message.isNoteOff, message.value > 0,
              case .action(.ui(let name))? = table.mapping(for: message.trigger)?.action else { return nil }
        return name
    }

    /// 一条消息对应的命令（W5-J：Note 绑的组合动作按顺序多条）；没映射、Note 松开、动作解析不出（引用不存在）都返回空。
    public mutating func commands(for message: MIDIMessage, state: MixerState) -> [Command] {
        switch message.trigger {
        case .note:
            guard let mapping = table.mapping(for: message.trigger), case .action(let action) = mapping.action else { return [] }
            guard !message.isNoteOff, message.value > 0 else { return [] }
            return action.resolve(in: state)
        case .cc, .cc14:
            return continuousCommand(for: message).map { [$0] } ?? []
        }
    }

    /// CC：推杆 / 推子（连续控制，一条消息至多一条命令）。
    private mutating func continuousCommand(for message: MIDIMessage) -> Command? {
        switch message.trigger {
        case .note:
            return nil
        case .cc(let channel, let controller):
            // 显式的 7-bit 映射优先；否则看它是不是某个 14-bit 映射的 MSB（0–31）或 LSB（32–63）
            if let mapping = table.mapping(for: message.trigger) {
                return continuous(mapping.action, value: message.value, max: 127)
            }
            if controller < 32, let mapping = table.mapping(for: .cc14(channel: channel, controller: controller)) {
                msb[Pair(channel: channel, controller: controller)] = message.value
                // MIDI 1.0：收到 MSB 时 LSB 视为 0，先按粗值动
                return continuous(mapping.action, value: message.value << 7, max: 16383)
            }
            if controller >= 32, controller < 64, let mapping = table.mapping(for: .cc14(channel: channel, controller: controller - 32)) {
                let high = msb[Pair(channel: channel, controller: controller - 32)] ?? 0
                return continuous(mapping.action, value: high << 7 | message.value, max: 16383)
            }
            return nil
        case .cc14:
            return nil   // 收到的消息永远是具体的 CC 号，cc14 只出现在表里
        }
    }

    /// 连续控制（推杆 / 推子）的动作。
    private mutating func continuous(_ action: MIDIAction, value: Int, max: Int) -> Command? {
        switch action {
        case .tbar:
            return .tbar(progress: tbar.progress(forValue: value, max: max))
        case .inputGain(let input, let minDb, let maxDb):
            return .audioGain(input: input, dB: Self.scale(value, max: max, minDb, maxDb))
        case .busGain(let bus, let minDb, let maxDb):
            return .busGain(bus: bus, dB: Self.scale(value, max: max, minDb, maxDb))
        case .action:
            return nil   // 按钮动作不接受连续控制
        }
    }

    static func scale(_ value: Int, max: Int = 127, _ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(Swift.min(Swift.max(value, 0), max)) / Double(max)
    }
}
