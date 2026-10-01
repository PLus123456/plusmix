// 节目文件去密钥（W4-B，后续方案 §8.1 诊断包：去掉密钥的节目文件）。在 JSON 层做，不依赖 Show 的具体字段：
// 名字在 secretKeys 里的字符串值（streamKey …）换成标记；名字是 url 的字符串值按推流包的 StreamURLRedaction 打码：userinfo（user:pass@）整段换成标记
// （W5-D：地址里的账号密码与密钥同样处理），查询参数里名字像密钥的（passphrase / key / token / streamid …）值换成标记，主机、端口、路径保留（排障要看往哪推）。
// 名单与推流包写日志时的脱敏是同一份。空字符串不动（"没设"不能变成"有值"）。
import Foundation
import SwitcherStreaming

enum ShowRedaction {
    static let redactedMarker = StreamURLRedaction.marker
    /// 值整个换掉的键（不分大小写）。url 查询参数的名单在推流包（StreamURLRedaction.secretQueryParams）。
    static let secretKeys: Set<String> = ["streamkey", "apitoken", "password", "passphrase", "token", "secret"]

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

    /// `scheme://user:pass@host:port/path?a=1&passphrase=x#frag` → userinfo 与 passphrase 的值换成标记。不是 `scheme://` 地址的原样返回。
    static func redactURL(_ s: String) -> String {
        StreamURLRedaction.redact(url: s, marker: redactedMarker)
    }
}
