import Foundation
import SwitcherContracts

// MIDI 映射表（设计方案 §9.4：T-bar 映射 CC，按钮映射 Note）。JSON，存在用户配置目录（节目文件之外）。
// 触发：CC（通道 1–16，控制器 0–127）、14-bit CC（控制器 0–31 为 MSB、+32 为 LSB，推杆用）或 Note（通道 1–16，音符 0–127）。
// 动作：CC → tbar / inputGain / busGain（值 0–127 线性映射），Note（按下，力度 > 0）→ ControlAction（同快捷键）。

/// 触发源。JSON：{"cc": {"channel": 1, "controller": 1}} / {"cc14": {"channel": 1, "controller": 1}} / {"note": {"channel": 1, "note": 60}}。
public enum MIDITrigger: Hashable, Codable, Sendable, CustomStringConvertible {
    /// 7-bit CC（0–127）。
    case cc(channel: Int, controller: Int)
    /// 14-bit CC：controller（0–31）收 MSB，controller + 32 收 LSB，合成 0–16383（MIDI 1.0 规范的粗 / 细配对；推杆用）。
    case cc14(channel: Int, controller: Int)
    case note(channel: Int, note: Int)

    public var description: String {
        switch self {
        case .cc(let ch, let cc): return "CC \(cc) @ ch\(ch)"
        case .cc14(let ch, let cc): return "CC \(cc)/\(cc + 32) (14-bit) @ ch\(ch)"
        case .note(let ch, let n): return "Note \(n) @ ch\(ch)"
        }
    }

    /// 通道 1–16、控制器 / 音符 0–127（14-bit 的 MSB 号 0–31）。
    public var isValid: Bool {
        switch self {
        case .cc(let ch, let cc): return (1...16).contains(ch) && (0...127).contains(cc)
        case .cc14(let ch, let cc): return (1...16).contains(ch) && (0...31).contains(cc)
        case .note(let ch, let n): return (1...16).contains(ch) && (0...127).contains(n)
        }
    }
}

/// 动作。JSON：{"tbar": {}} / {"inputGain": {"input": 1, "minDb": -60, "maxDb": 12}} / {"busGain": {"bus": 0, …}} / {"action": {<ControlAction>}}。
public enum MIDIAction: Hashable, Sendable {
    /// CC → 推杆；到两端提交并换向（真 T-bar 的手感：推上去是一次转场，拉回来是下一次）。
    case tbar
    /// CC → 某路输入增益，值 0–127 线性映射到 [minDb, maxDb]。
    case inputGain(input: Int, minDb: Double, maxDb: Double)
    /// CC → 总线增益。
    case busGain(bus: Bus, minDb: Double, maxDb: Double)
    /// Note 按下 → 动作（命令或开关）。
    case action(ControlAction)
}

extension MIDIAction: Codable {
    // 手写 Codable：合成的会把无标签的 action 编成 {"action": {"_0": …}}。
    private enum Key: String, CodingKey { case tbar, inputGain, busGain, action }
    private enum Arg: String, CodingKey { case input, bus, minDb, maxDb }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "MIDI 动作要恰好一个键：tbar / inputGain / busGain / action"))
        }
        switch key {
        case .tbar:
            _ = try? c.nestedContainer(keyedBy: Arg.self, forKey: .tbar)
            self = .tbar
        case .inputGain:
            let n = try c.nestedContainer(keyedBy: Arg.self, forKey: .inputGain)
            self = .inputGain(input: try n.decode(Int.self, forKey: .input), minDb: try n.decode(Double.self, forKey: .minDb), maxDb: try n.decode(Double.self, forKey: .maxDb))
        case .busGain:
            let n = try c.nestedContainer(keyedBy: Arg.self, forKey: .busGain)
            self = .busGain(bus: try n.decode(Bus.self, forKey: .bus), minDb: try n.decode(Double.self, forKey: .minDb), maxDb: try n.decode(Double.self, forKey: .maxDb))
        case .action:
            self = .action(try c.decode(ControlAction.self, forKey: .action))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .tbar:
            _ = c.nestedContainer(keyedBy: Arg.self, forKey: .tbar)
        case .inputGain(let input, let minDb, let maxDb):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .inputGain)
            try n.encode(input, forKey: .input)
            try n.encode(minDb, forKey: .minDb)
            try n.encode(maxDb, forKey: .maxDb)
        case .busGain(let bus, let minDb, let maxDb):
            var n = c.nestedContainer(keyedBy: Arg.self, forKey: .busGain)
            try n.encode(bus, forKey: .bus)
            try n.encode(minDb, forKey: .minDb)
            try n.encode(maxDb, forKey: .maxDb)
        case .action(let a):
            try c.encode(a, forKey: .action)
        }
    }
}

/// 一条映射。
public struct MIDIMapping: Hashable, Codable, Sendable {
    public var trigger: MIDITrigger
    public var action: MIDIAction
    public var note: String?
    public init(trigger: MIDITrigger, action: MIDIAction, note: String? = nil) {
        self.trigger = trigger
        self.action = action
        self.note = note
    }
}

/// 表的错误。
public enum MIDIMapTableError: Error, CustomStringConvertible {
    case conflicts([MIDIMapTable.Conflict])
    case invalidTrigger(MIDITrigger)
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .conflicts(let list): return "MIDI 映射冲突：" + list.map { "\($0.trigger) 映射了 \($0.mappings.count) 次" }.joined(separator: "；")
        case .invalidTrigger(let t): return "MIDI 触发超出范围（通道 1–16、控制器 / 音符 0–127、14-bit 的 MSB 号 0–31）：\(t)"
        case .unsupportedVersion(let v): return "MIDI 映射表版本 \(v) 不支持（当前 \(MIDIMapTable.currentVersion)）"
        }
    }
}

/// 映射表。
public struct MIDIMapTable: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var mappings: [MIDIMapping]

    public init(version: Int = MIDIMapTable.currentVersion, mappings: [MIDIMapping]) {
        self.version = version
        self.mappings = mappings
    }

    /// 空表（没有"默认 MIDI 映射"：设备各不相同，用 learn 配）。
    public static let `default` = MIDIMapTable(mappings: [])

    public struct Conflict: Hashable, Sendable {
        public var trigger: MIDITrigger
        public var mappings: [Int]
    }

    public func conflicts() -> [Conflict] {
        var seen: [MIDITrigger: [Int]] = [:]
        for (i, m) in mappings.enumerated() { seen[m.trigger, default: []].append(i) }
        return seen.filter { $0.value.count > 1 }.map { Conflict(trigger: $0.key, mappings: $0.value) }.sorted { $0.mappings[0] < $1.mappings[0] }
    }

    public func mapping(for trigger: MIDITrigger) -> MIDIMapping? { mappings.first { $0.trigger == trigger } }

    public func jsonData() throws -> Data { try APIJSON.prettyEncoder.encode(self) }

    public static func load(from data: Data, allowConflicts: Bool = false) throws -> MIDIMapTable {
        let t = try APIJSON.decoder.decode(MIDIMapTable.self, from: data)
        guard t.version == currentVersion else { throw MIDIMapTableError.unsupportedVersion(t.version) }
        if let bad = t.mappings.first(where: { !$0.trigger.isValid }) { throw MIDIMapTableError.invalidTrigger(bad.trigger) }
        let c = t.conflicts()
        if !allowConflicts, !c.isEmpty { throw MIDIMapTableError.conflicts(c) }
        return t
    }

    public static func load(from url: URL, allowConflicts: Bool = false) throws -> MIDIMapTable {
        try load(from: try Data(contentsOf: url), allowConflicts: allowConflicts)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    /// ~/Library/Application Support/Switcher/midi.json。
    public static var defaultFileURL: URL { UserConfig.directory.appending(path: "midi.json") }

    public static func loadUserTableOrDefault() -> MIDIMapTable {
        (try? load(from: defaultFileURL)) ?? .default
    }
}
