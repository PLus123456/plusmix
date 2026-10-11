import Foundation
import SwitcherContracts

// 快捷键表（设计方案 §9.4）：JSON，存在节目文件之外的用户配置（~/Library/Application Support/PlusMix/hotkeys.json）。
// 默认表（与 W2-B 硬编码的一致）：数字 → PVW（0 = 10 号），Shift + 数字 → PGM，空格 Cut，回车 Auto（按已选转场，默认 Fade 30 拍），F 键 FTB 开关；
// W5-J 按 04 Q29 补：⌥1–⌥4 = 执行转场 1–4（W5-M 起接到转场槽；之前先绑的是"执行当前转场"，= 回车）、⌃1–⌃4 = 叠加 1–4 开关；
// 录制 / 推流不给默认键（快捷键一律不弹确认，误按一个键就停录 / 停推）。⌃1–⌃4 与系统"切换到桌面 1–4"同键，那几项系统默认关着
// （本机实测，reports/w5-app-settings-actions.md §2），用户在系统设置里打开后这几个键会先被系统拿走。
// 自己定的表，不照抄别人的（铁律 6）。

/// 一条绑定。
public struct HotkeyBinding: Hashable, Codable, Sendable {
    public var key: KeyCombo
    public var action: ControlAction
    /// 给人看的备注。
    public var note: String?
    /// 启用（W5-J，01a N5：表里每行一个勾）。停用的行留在表里，不派发、不参与冲突检查。JSON 只在停用时写 "enabled": false，旧文件没有这个键 = 启用。
    public var enabled: Bool
    public init(key: KeyCombo, action: ControlAction, note: String? = nil, enabled: Bool = true) {
        self.key = key
        self.action = action
        self.note = note
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case key, action, note, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(KeyCombo.self, forKey: .key)
        action = try c.decode(ControlAction.self, forKey: .action)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(note, forKey: .note)
        if !enabled { try c.encode(false, forKey: .enabled) }
    }
}

/// 表的错误。
public enum HotkeyTableError: Error, CustomStringConvertible {
    /// 同一组合键绑了多次。
    case conflicts([HotkeyTable.Conflict])
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .conflicts(let list):
            return "快捷键冲突：" + list.map { "\($0.key) 绑了 \($0.bindings.count) 次（第 \($0.bindings.map { String($0 + 1) }.joined(separator: "、")) 条）" }.joined(separator: "；")
        case .unsupportedVersion(let v):
            return "快捷键表版本 \(v) 不支持（当前 \(HotkeyTable.currentVersion)）"
        }
    }
}

/// 快捷键表。
public struct HotkeyTable: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var bindings: [HotkeyBinding]

    public init(version: Int = HotkeyTable.currentVersion, bindings: [HotkeyBinding]) {
        self.version = version
        self.bindings = bindings
    }

    /// 一处冲突：同一组合键对应的绑定下标。
    public struct Conflict: Hashable, Sendable {
        public var key: KeyCombo
        public var bindings: [Int]
    }

    /// 默认表。
    public static let `default`: HotkeyTable = {
        var b: [HotkeyBinding] = []
        for n in 1...10 {
            let digit = n == 10 ? "0" : String(n)
            b.append(HotkeyBinding(key: KeyCombo(key: digit), action: .command(.setPreview(input: n)), note: "PVW 选 \(n) 号"))
        }
        for n in 1...10 {
            let digit = n == 10 ? "0" : String(n)
            b.append(HotkeyBinding(key: KeyCombo(key: digit, modifiers: [.shift]), action: .command(.setProgram(input: n)), note: "直切 PGM \(n) 号"))
        }
        b.append(HotkeyBinding(key: KeyCombo(key: "space"), action: .command(.cut), note: "Cut"))
        b.append(HotkeyBinding(key: KeyCombo(key: "return"), action: .command(.autoTransition), note: "执行当前槽（T-bar 也用它；新节目是转场 1 · Fade 0.5 秒）"))
        b.append(HotkeyBinding(key: KeyCombo(key: "f"), action: .toggleFTB, note: "FTB 开关"))
        for n in 1...4 {
            b.append(HotkeyBinding(key: KeyCombo(key: String(n), modifiers: [.option]), action: .transitionSlot(slot: n), note: "执行转场 \(n)"))
        }
        for n in 1...4 {
            b.append(HotkeyBinding(key: KeyCombo(key: String(n), modifiers: [.control]), action: .toggleOverlay(channel: n), note: "叠加 \(n) 开关"))
        }
        return HotkeyTable(bindings: b)
    }()

    /// 同一组合键绑了多次的地方（只看启用的行）。
    public func conflicts() -> [Conflict] {
        var seen: [KeyCombo: [Int]] = [:]
        for (i, b) in bindings.enumerated() where b.enabled { seen[b.key, default: []].append(i) }
        return seen.filter { $0.value.count > 1 }.map { Conflict(key: $0.key, bindings: $0.value) }.sorted { $0.bindings[0] < $1.bindings[0] }
    }

    /// 某个组合键的动作（第一条启用的匹配）。
    public func action(for combo: KeyCombo) -> ControlAction? {
        bindings.first { $0.enabled && $0.key == combo }?.action
    }

    // MARK: JSON

    /// 人读的 JSON。
    public func jsonData() throws -> Data { try APIJSON.prettyEncoder.encode(self) }

    /// 从 JSON 读；有冲突默认报错（allowConflicts 关掉）。
    public static func load(from data: Data, allowConflicts: Bool = false) throws -> HotkeyTable {
        let t = try APIJSON.decoder.decode(HotkeyTable.self, from: data)
        guard t.version == currentVersion else { throw HotkeyTableError.unsupportedVersion(t.version) }
        let c = t.conflicts()
        if !allowConflicts, !c.isEmpty { throw HotkeyTableError.conflicts(c) }
        return t
    }

    public static func load(from url: URL, allowConflicts: Bool = false) throws -> HotkeyTable {
        try load(from: try Data(contentsOf: url), allowConflicts: allowConflicts)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    /// 用户配置的缺省位置：~/Library/Application Support/PlusMix/hotkeys.json（节目文件之外）。
    public static var defaultFileURL: URL { UserConfig.directory.appending(path: "hotkeys.json") }

    /// 读用户文件；没有就用默认表。
    public static func loadUserTableOrDefault() -> HotkeyTable {
        (try? load(from: defaultFileURL)) ?? .default
    }
}

/// 用户配置目录（节目文件之外的东西：快捷键表、MIDI 映射）：~/Library/Application Support/PlusMix。
/// 目录名是产品名（W2-C2 跟 W4-D 的改名；0.1.0 之前没发布过，没有旧目录要迁移）。
public enum UserConfig {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "PlusMix")
    }
}
