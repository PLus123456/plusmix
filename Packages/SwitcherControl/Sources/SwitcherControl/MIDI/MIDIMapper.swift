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

    /// 0–127 → 进度 0–1。
    public mutating func progress(forValue value: Int) -> Double {
        let raw = Double(min(max(value, 0), 127)) / 127
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

    public init(table: MIDIMapTable) { self.table = table }

    /// 一条消息对应的命令；没映射、Note 松开、动作解析不出（引用不存在）都返回 nil。
    public mutating func command(for message: MIDIMessage, state: MixerState) -> Command? {
        guard let mapping = table.mapping(for: message.trigger) else { return nil }
        switch mapping.action {
        case .tbar:
            guard case .cc = message.trigger else { return nil }
            return .tbar(progress: tbar.progress(forValue: message.value))
        case .inputGain(let input, let minDb, let maxDb):
            guard case .cc = message.trigger else { return nil }
            return .audioGain(input: input, dB: Self.scale(message.value, minDb, maxDb))
        case .busGain(let bus, let minDb, let maxDb):
            guard case .cc = message.trigger else { return nil }
            return .busGain(bus: bus, dB: Self.scale(message.value, minDb, maxDb))
        case .action(let action):
            guard case .note = message.trigger, !message.isNoteOff, message.value > 0 else { return nil }
            return action.resolve(in: state)
        }
    }

    static func scale(_ value: Int, _ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(min(max(value, 0), 127)) / 127
    }
}
