import Foundation

// 组合键（设计方案 §9.4：快捷键可配置）。文本形态 "ctrl+alt+shift+cmd+<键>"，键是小写字母 / 数字或命名键；
// 解析时接受别名（cmd / command / ⌘，alt / option / opt / ⌥，ctrl / control / ⌃，shift / ⇧；enter = return，esc = escape），
// 大小写和顺序无关，归一化后同一个组合键只有一种写法，冲突检测靠它。

/// 修饰键。
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// 一个组合键。
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible, LosslessStringConvertible {
    /// 归一化的键名：单个小写字母 / 数字 / 符号，或命名键（space, return, escape, tab, delete, forwarddelete, up, down, left, right,
    /// home, end, pageup, pagedown, f1…f20）。
    public var key: String
    public var modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = KeyCombo.normalizedKey(key) ?? key.lowercased()
        self.modifiers = modifiers
    }

    /// 解析 "cmd+shift+1"、"⇧1"、"Return" 之类；解析不了返回 nil。
    public init?(_ description: String) {
        var text = description.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var mods: KeyModifiers = []
        // 符号前缀：⌘⌥⌃⇧ 可连写
        while let first = text.first, let m = KeyCombo.symbolModifiers[first] {
            mods.insert(m)
            text.removeFirst()
        }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "shift++"（键本身是 +）：最后两段为空 → 键是 "+"
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.last, !last.isEmpty else { return nil }
        for p in parts.dropLast() {
            guard let m = KeyCombo.namedModifiers[p.lowercased()] else { return nil }
            mods.insert(m)
        }
        guard let key = KeyCombo.normalizedKey(last) else { return nil }
        self.key = key
        self.modifiers = mods
    }

    /// "ctrl+alt+shift+cmd+<键>"，顺序固定。
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static let namedModifiers: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command, "meta": .command,
        "alt": .option, "option": .option, "opt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
        "shift": .shift, "⇧": .shift,
    ]
    static let symbolModifiers: [Character: KeyModifiers] = ["⌘": .command, "⌥": .option, "⌃": .control, "⇧": .shift]
    static let keyAliases: [String: String] = [
        "enter": "return", "ret": "return", "esc": "escape", "spacebar": "space", "backspace": "delete", "del": "forwarddelete",
        "pgup": "pageup", "pgdn": "pagedown", "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
    ]
    static let namedKeys: Set<String> = [
        "space", "return", "escape", "tab", "delete", "forwarddelete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    ]

    /// 归一化键名；不认识的返回 nil。
    static func normalizedKey(_ raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.isEmpty { return nil }
        if let alias = keyAliases[lower] { return alias }
        if namedKeys.contains(lower) { return lower }
        if lower.count == 1 {
            // 单个字符：字母 / 数字 / 符号；修饰键名本身不是键
            if namedModifiers[lower] != nil { return nil }
            return lower
        }
        return nil
    }
}

extension KeyCombo: Codable {
    /// JSON 里就是一个字符串："shift+1"。
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let combo = KeyCombo(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "认不出的组合键：\(text)"))
        }
        self = combo
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

#if canImport(AppKit)
import AppKit

extension KeyCombo {
    /// 由键盘事件得到组合键：字符用 charactersIgnoringModifiers（Shift+1 仍是 "1"），特殊键按 keyCode；无关的标志位（数字小键盘、大写锁定）忽略。
    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if let named = KeyCombo.keyCodeNames[event.keyCode] {
            self.init(key: named, modifiers: mods)
            return
        }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first else { return nil }
        if let named = KeyCombo.functionKeyNames[first.value] {
            self.init(key: named, modifiers: mods)
            return
        }
        guard first.value >= 0x20, first.value < 0xF700 else { return nil }
        guard let key = KeyCombo.normalizedKey(String(first)) else { return nil }
        self.init(key: key, modifiers: mods)
    }

    /// 与布局无关的键码（Carbon kVK_*）。
    static let keyCodeNames: [UInt16: String] = [
        49: "space", 36: "return", 76: "return", 53: "escape", 48: "tab", 51: "delete", 117: "forwarddelete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]
    /// NSEvent 的功能键私有码点（NSUpArrowFunctionKey = 0xF700 起）。
    static let functionKeyNames: [UInt32: String] = [
        0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right", 0xF704: "f1", 0xF705: "f2", 0xF706: "f3", 0xF707: "f4", 0xF708: "f5",
        0xF709: "f6", 0xF70A: "f7", 0xF70B: "f8", 0xF70C: "f9", 0xF70D: "f10", 0xF70E: "f11", 0xF70F: "f12", 0xF710: "f13", 0xF711: "f14",
        0xF712: "f15", 0xF713: "f16", 0xF714: "f17", 0xF715: "f18", 0xF716: "f19", 0xF717: "f20", 0xF728: "forwarddelete", 0xF729: "home",
        0xF72B: "end", 0xF72C: "pageup", 0xF72D: "pagedown",
    ]
}
#endif
