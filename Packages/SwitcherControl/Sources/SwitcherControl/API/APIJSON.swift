import Foundation

/// API 用的 JSON 编解码器：键排序、不转义斜杠（与 Stats.lineEncoder 同样的设置，状态 / 命令 / 统计一种写法）。
public enum APIJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// 人读版（docs/api.md 的样例）。
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }()
    public static let decoder = JSONDecoder()

    public static func string<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        String(decoding: try (pretty ? prettyEncoder : encoder).encode(value), as: UTF8.self)
    }
}
