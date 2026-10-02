import Foundation

/// 推流地址脱敏：日志、错误文字、诊断包（App 的 ShowRedaction）共用这一份口径。
/// - userinfo（user:pass@）整段换成标记；
/// - 查询串里名字像密钥的参数（`secretQueryParams`）值换成标记；
/// - scheme、主机、端口、路径保留（排障要看往哪推）。
/// 不经 URLComponents（它会把标记里的 < > 百分号编码，解析不了的地址也就打不了码）。
public enum StreamURLRedaction {
    public static let marker = "<redacted>"

    /// 查询参数里值要换掉的名字（不分大小写）。streamid 也算：SRT 的 streamid 常带 publish:路径:用户:密码；
    /// user / pass 是 MediaMTX 一类的 ?user=&pass=；response 是 Adobe 鉴权的应答（配上 salt / challenge 能离线猜密码）。
    public static let secretQueryParams: Set<String> = ["passphrase", "key", "token", "password", "secret", "streamid", "auth", "user", "pass", "pwd", "response"]

    /// 一个地址。不是 `scheme://…` 的原样返回。
    public static func redact(url s: String, marker: String = marker) -> String {
        var out = s
        if let r = userinfoRange(in: out) { out.replaceSubrange(r, with: marker) }
        return redactQuery(out, marker: marker)
    }

    /// 一段文字（错误描述、日志行）：里面每个 `scheme://` 地址都按 `redact(url:)` 处理。
    /// 地址到空白或 URL 里不会原样出现的字符（" < > \ ^ ` { | }）为止——Swift 打印字符串关联值时引号前的反斜杠也在其中。
    public static func redact(text: String, marker: String = marker) -> String {
        var result = ""
        var cursor = text.startIndex
        while let sep = text.range(of: "://", range: cursor..<text.endIndex) {
            var start = sep.lowerBound
            while start > cursor {
                let p = text.index(before: start)
                guard text[p].isASCII, text[p].isLetter || text[p].isNumber || "+-.".contains(text[p]) else { break }
                start = p
            }
            let end = text[sep.upperBound...].firstIndex { $0.isWhitespace || "\"<>\\^`{|}".contains($0) } ?? text.endIndex
            result += text[cursor..<start]
            result += redact(url: String(text[start..<end]), marker: marker)
            cursor = end
        }
        return result + text[cursor...]
    }

    /// userinfo 的范围（不含 @）。按 RFC 3986：authority 到第一个 / ? # 为止，userinfo 到 authority 里最后一个 @
    /// （Foundation 对没转义的 @ 也是这么分的）。解析不了的地址（密码里有没转义的 / ? #）保守些："://" 到整串最后一个 @ 都算。
    static func userinfoRange(in s: String) -> Range<String.Index>? {
        guard let sep = s.range(of: "://") else { return nil }
        let start = sep.upperBound
        let authorityEnd = s[start...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? s.endIndex
        if let at = s[start..<authorityEnd].lastIndex(of: "@") { return start..<at }
        if URLComponents(string: s)?.host == nil, let at = s[start...].lastIndex(of: "@") { return start..<at }
        return nil
    }

    /// 查询串：`…?a=1&passphrase=x#frag` → passphrase 的值换成标记。没有 `?` 原样返回。
    static func redactQuery(_ s: String, marker: String) -> String {
        guard let q = s.firstIndex(of: "?") else { return s }
        let prefix = s[..<q]
        var rest = s[s.index(after: q)...]
        var fragment = Substring("")
        if let h = rest.firstIndex(of: "#") { fragment = rest[h...]; rest = rest[..<h] }
        let items = rest.split(separator: "&", omittingEmptySubsequences: false).map { item -> String in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(item) }
            let name = String(parts[0])
            return secretQueryParams.contains(name.lowercased()) ? "\(name)=\(marker)" : String(item)
        }
        return prefix + "?" + items.joined(separator: "&") + fragment
    }
}
