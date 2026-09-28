import Foundation
import SwitcherContracts

// 快捷键表（设计方案 §9.4）：JSON，存在节目文件之外的用户配置（~/Library/Application Support/PlusMix/hotkeys.json）。
// 默认表（与 W2-B 硬编码的一致）：数字 → PVW（0 = 10 号），Shift + 数字 → PGM，空格 Cut，回车 Auto（按已选转场，默认 Fade 30 拍），F 键 FTB 开关。
// 自己定的表，不照抄别人的（铁律 6）。

/// 一条绑定。
public struct HotkeyBinding: Hashable, Codable, Sendable {
    public var key: KeyCombo
    public var action: ControlAction
    /// 给人看的备注。
    public var note: String?
    public init(key: KeyCombo, action: ControlAction, note: String? = nil) {
        self.key = key
        self.action = action
        self.note = note
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
        b.append(HotkeyBinding(key: KeyCombo(key: "return"), action: .command(.autoTransition), note: "按已选转场执行（默认 Fade 30 拍）"))
        b.append(HotkeyBinding(key: KeyCombo(key: "f"), action: .toggleFTB, note: "FTB 开关"))
        return HotkeyTable(bindings: b)
    }()

    /// 同一组合键绑了多次的地方。
    public func conflicts() -> [Conflict] {
        var seen: [KeyCombo: [Int]] = [:]
        for (i, b) in bindings.enumerated() { seen[b.key, default: []].append(i) }
        return seen.filter { $0.value.count > 1 }.map { Conflict(key: $0.key, bindings: $0.value) }.sorted { $0.bindings[0] < $1.bindings[0] }
    }

    /// 某个组合键的动作（第一条匹配）。
    public func action(for combo: KeyCombo) -> ControlAction? {
        bindings.first { $0.key == combo }?.action
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
