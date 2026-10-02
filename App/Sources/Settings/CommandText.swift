// "其他命令"的显示与 JSON 编辑（W5-B，01a N4，02 X10 / X41）：快捷键编辑器 / MIDI 映射里不在那十来种动作里的命令（从 hotkeys.json / midi.json 读来的，
// 或用"编辑 JSON…"填的）。显示 = SwitcherControl.CommandCatalog 的一句话说明（中文界面；目录只有中文，英文界面用命令名）+ 参数摘要（命令 JSON 里那一层的键值），
// 不再是 Swift 枚举原文；编辑 = 一条命令的 JSON（顶层键是命令名，与 HTTP API 的 command 同一个写法），解不出来就报错、不改那一行。
import Foundation
import SwitcherContracts
import SwitcherControl

enum CommandText {
    /// 说明 + 参数摘要："选下一次转场的类型和时长……（durationTicks: 30, type: wipe）"。
    static func summary(_ command: Command) -> String {
        let kind = CommandKind(of: command)
        let head = usesCatalogText ? CommandCatalog.entry(for: kind).summary : kind.rawValue
        let params = parameters(command)
        return params.isEmpty ? head : L("hotkeys.otherCommandDesc", head, params)
    }

    /// 参数摘要：命令 JSON 那一层的键值（键按字母序；字符串不带引号，嵌套的照 JSON 写）。没有参数为空串。
    static func parameters(_ command: Command) -> String {
        guard let data = try? encoder([.sortedKeys]).encode(command),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = top.values.first as? [String: Any] else { return "" }
        return body.keys.sorted().map { key -> String in
            let value = body[key]!
            if let s = value as? String { return "\(key): \(s)" }
            if value is NSNull { return "\(key): null" }
            if let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                return "\(key): \(String(decoding: d, as: UTF8.self))"
            }
            return "\(key): \(value)"
        }.joined(separator: ", ")
    }

    /// 编辑框里的文字：这条命令的 JSON（键按字母序、缩进）。
    static func json(_ command: Command) -> String {
        guard let data = try? encoder([.sortedKeys, .prettyPrinted]).encode(command) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 编辑框里的文字 → 命令；不是一条认得出的命令就抛（原因给人看）。
    static func parse(_ text: String) throws -> Command {
        do {
            return try JSONDecoder().decode(Command.self, from: Data(text.utf8))
        } catch let error as DecodingError {
            throw ParseError(reason: describe(error))
        }
    }

    struct ParseError: Error, CustomStringConvertible {
        var reason: String
        var description: String { L("hotkeys.json.invalid", reason) }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static var usesCatalogText: Bool {
        (L10n.languageOverride ?? Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }

    private static func encoder(_ formatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = formatting
        return e
    }
}
