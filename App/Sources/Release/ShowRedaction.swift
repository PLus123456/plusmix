// 节目文件去密钥（W4-B，后续方案 §8.1 诊断包：去掉密钥的节目文件）。在 JSON 层做，不依赖 Show 的具体字段：
// 名字在 secretKeys 里的字符串值（streamKey …）换成标记；名字是 url 的字符串值，查询参数里名字在 secretQueryParams 里的（passphrase / key / token /
// streamid …）值换成标记，主机、端口、路径保留（排障要看往哪推）。空字符串不动（"没设"不能变成"有值"）。
import Foundation

enum ShowRedaction {
    static let redactedMarker = "<redacted>"
    /// 值整个换掉的键（不分大小写）。
    static let secretKeys: Set<String> = ["streamkey", "apitoken", "password", "passphrase", "token", "secret"]
    /// url 查询参数里值换掉的名字（不分大小写）。streamid 也算：SRT 的 streamid 常带 publish:路径:用户:密码。
    static let secretQueryParams: Set<String> = ["passphrase", "key", "token", "password", "secret", "streamid", "auth", "user", "pass", "pwd"]

    /// 节目 JSON → 去掉密钥的节目 JSON（仍是合法的 Show 文件）。不是 JSON 对象就抛。
    static func redact(showData: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: showData)
        let cleaned = redact(json: object)
        return try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys])
    }

    /// 递归处理 JSONSerialization 的对象树。
    static func redact(json: Any) -> Any {
        switch json {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, value) in dict {
                if let s = value as? String {
                    if secretKeys.contains(key.lowercased()) {
                        out[key] = s.isEmpty ? s : redactedMarker
                    } else if key.lowercased() == "url" {
                        out[key] = redactURL(s)
                    } else {
                        out[key] = s
                    }
                } else {
                    out[key] = redact(json: value)
                }
            }
            return out
        case let array as [Any]:
            return array.map { redact(json: $0) }
        default:
            return json
        }
    }

    /// 只动查询串：`scheme://host:port/path?a=1&passphrase=x#frag` → passphrase 的值换成标记。没有 `?` 原样返回。
    /// 不经 URLComponents（它会把标记里的 < > 百分号编码）。
    static func redactURL(_ s: String) -> String {
        guard let q = s.firstIndex(of: "?") else { return s }
        let prefix = s[..<q]
        var rest = s[s.index(after: q)...]
        var fragment = Substring("")
        if let h = rest.firstIndex(of: "#") { fragment = rest[h...]; rest = rest[..<h] }
        let items = rest.split(separator: "&", omittingEmptySubsequences: false).map { item -> String in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(item) }
            let name = String(parts[0])
            return secretQueryParams.contains(name.lowercased()) ? "\(name)=\(redactedMarker)" : String(item)
        }
        return prefix + "?" + items.joined(separator: "&") + fragment
    }
}
