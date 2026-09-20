import Foundation

/// 一次函数调用：名字 + 参数（参数名统一小写，取值时不分大小写）。
///
/// 两种来源同一种解析：TCP 的 `FUNCTION <名字> [key=value&key2=value2]`，HTTP 的 `?Function=<名字>&key=value`。
/// 值按查询串规则解码：`%XX` 百分号解码，`+` 当空格（表单编码；Companion 用 encodeURIComponent，空格是 %20）。
public struct FunctionRequest: Hashable, Sendable {
    /// 函数名（原样，匹配时不分大小写）。
    public let name: String
    /// 参数；键已小写。
    public let parameters: [String: String]

    public init(name: String, parameters: [String: String]) {
        self.name = name
        var lowered: [String: String] = [:]
        for (k, v) in parameters { lowered[k.lowercased()] = v }
        self.parameters = lowered
    }

    public init(name: String, queryItems: [(String, String)]) {
        self.init(name: name, parameters: Dictionary(queryItems.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }))
    }

    /// TCP 形式："Name key=value&key2=value2"（第一个空白之前是名字，之后整段是查询串）。名字为空给 nil。
    public init?(commandLine: String) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let name = String(trimmed[..<space])
            let query = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            self.init(name: name, queryItems: FunctionRequest.parseQuery(query))
        } else {
            self.init(name: trimmed, queryItems: [])
        }
    }

    /// HTTP 形式：整个查询串；`Function` 键（不分大小写）是名字，其余是参数。没有 Function 键（= 要 XML 状态）给 nil。
    public init?(httpQuery: String?) {
        guard let httpQuery else { return nil }
        let items = FunctionRequest.parseQuery(httpQuery)
        guard let function = items.first(where: { $0.0.lowercased() == "function" }) else { return nil }
        self.init(name: function.1, queryItems: items.filter { $0.0.lowercased() != "function" })
    }

    /// 取参数（不分大小写）。
    public func parameter(_ key: String) -> String? { parameters[key.lowercased()] }

    /// 查询串 → 键值对（顺序保留；`+` 当空格；百分号解码；没有 `=` 的项值为空串）。
    public static func parseQuery(_ query: String) -> [(String, String)] {
        query.split(separator: "&", omittingEmptySubsequences: true).compactMap { item -> (String, String)? in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = pair.first, !rawKey.isEmpty else { return nil }
            let key = decode(String(rawKey))
            let value = pair.count > 1 ? decode(String(pair[1])) : ""
            return (key, value)
        }
    }

    static func decode(_ s: String) -> String {
        let plusAsSpace = s.replacingOccurrences(of: "+", with: " ")
        return plusAsSpace.removingPercentEncoding ?? plusAsSpace
    }
}
