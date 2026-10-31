import Foundation

/// 推流地址脱敏：日志、错误文字、诊断包（App 的 ShowRedaction）共用这一份口径。
/// - userinfo（user:pass@）整段换成标记；
/// - 查询串里名字像密钥的参数（`secretQueryParams`，名字按百分号解码后比）值换成标记；
/// - scheme、主机、端口、路径保留（排障要看往哪推）；只有诊断包在密钥栏空时让 RTMP 路径的最后一段（发布名 = 密钥）也换掉（`publishNameInPath`）。
/// 不经 URLComponents（它会把标记里的 < > 百分号编码，解析不了的地址也就打不了码）。
public enum StreamURLRedaction {
    public static let marker = "<redacted>"

    /// 查询参数里值要换掉的名字（不分大小写，比之前先百分号解码）。streamid 也算：SRT 的 streamid 常带 publish:路径:用户:密码；
    /// user / pass 是 MediaMTX 一类的 ?user=&pass=；response 是 Adobe 鉴权的应答（配上 salt / challenge 能离线猜密码）。
    public static let secretQueryParams: Set<String> = ["passphrase", "key", "token", "password", "secret", "streamid", "auth", "user", "pass", "pwd", "response"]

    /// 一个地址。不是 `scheme://…` 的原样返回。
    /// `publishNameInPath`：RTMP / RTMPS 地址路径 ≥ 2 段时最后一段换成标记——密钥栏空着的时候 StreamDestination 把它当发布名（密钥）用
    /// （rtmp://h/live2/xxxx-xxxx 整条粘贴），诊断包看同层的 streamKey 为空就传 true（NS09）；日志 / 错误文字本来就不带发布名，默认 false。
    public static func redact(url s: String, marker: String = marker, publishNameInPath: Bool = false) -> String {
        var out = s
        if let r = userinfoRange(in: out) { out.replaceSubrange(r, with: marker) }
        if publishNameInPath, let r = publishNameRange(in: out) { out.replaceSubrange(r, with: marker) }
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

    /// RTMP / RTMPS 地址里发布名那一段（原文）的范围；不是 RTMP、路径不到 2 段为 nil。在 userinfo 换过标记之后的串上找（密码里没转义的 / 已经不在了）。
    /// 拆法与 StreamDestination 一致：它按解码后的路径以 / 拆、空段不算，≥ 2 段时最后一段是发布名；%2F 解出来也是分隔，
    /// 所以这里返回"含最后一个解码段"的整个原文段（a%2Fb 整段算，只多盖、不漏），后面解出来全是 / 的原文段跳过。
    static func publishNameRange(in s: String) -> Range<String.Index>? {
        guard let sep = s.range(of: "://") else { return nil }
        let scheme = s[..<sep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // StreamDestination 先去掉首尾的空白 / 换行再解析："…/KEY/ " 的末段是 KEY，不是那个空白
        let blank: (Character) -> Bool = { $0.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) }
        guard scheme == "rtmp" || scheme == "rtmps", let last = s.lastIndex(where: { !blank($0) }) else { return nil }
        let contentEnd = s.index(after: last)
        guard sep.upperBound < contentEnd,
              let pathStart = s[sep.upperBound..<contentEnd].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }), s[pathStart] == "/" else { return nil }
        let pathEnd = s[pathStart..<contentEnd].firstIndex { $0 == "?" || $0 == "#" } ?? contentEnd
        var segments: [(range: Range<String.Index>, decodedSegments: Int)] = []
        var start = pathStart
        while start < pathEnd {
            let end = s[start..<pathEnd].firstIndex(of: "/") ?? pathEnd
            if start < end {
                let raw = String(s[start..<end])
                segments.append((start..<end, (raw.removingPercentEncoding ?? raw).split(separator: "/").count))
            }
            start = end < pathEnd ? s.index(after: end) : pathEnd
        }
        guard segments.reduce(0, { $0 + $1.decodedSegments }) >= 2 else { return nil }
        return segments.last { $0.decodedSegments > 0 }?.range
    }

    /// 查询串：`…?a=1&passphrase=x#frag` → passphrase 的值换成标记。没有 `?` 原样返回。
    /// 名字先百分号解码（解不开按原文）再比名单：`pa%73s` Foundation / 服务器解出来就是 pass（NS12）；参数名和不打码的项照原文留着。
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
            return secretQueryParams.contains((name.removingPercentEncoding ?? name).lowercased()) ? "\(name)=\(marker)" : String(item)
        }
        return prefix + "?" + items.joined(separator: "&") + fragment
    }
}
