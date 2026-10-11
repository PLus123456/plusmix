// 推流地址里的鉴权（W5-I，prompt 95 G6 追加；01a L10，reports/w5-stream-auth.md §5 第 3 条）：
// - RTMP / RTMPS："鉴权…"写回地址的 userinfo（user:pass@）。写用 URLComponents 的 user / password setter（自动只转义一次，不手拼），
//   读用推流包的 StreamDestination(settings:).credentials（与连接层同一份解码）。这是 Adobe（FMLE 兼容）鉴权：Wowza / Nimble / FMS 与一部分 CDN 入口用；
//   MediaMTX / SRS / nginx-rtmp 这类自建服务器要的是地址后面的查询串（MediaMTX：?user=…&pass=…），填在鉴权框里对它们没用。
// - SRT：passphrase 写进查询串；只收字母数字和 - . _ ~、10–79 个字符（HaishinKit 不解码查询串，问题单 W5D-w2-stream-srt-passphrase-reserved-chars）。
// - 地址框里 user:pass@ 打码显示（`masked`），编辑时打码段原样留着就换回原来的 userinfo（`unmasked`）。
import Foundation
import SwitcherContracts
import SwitcherStreaming

enum StreamAddress {
    /// 地址框里代替 userinfo 的记号。
    static let maskToken = "•••"

    enum AuthStyle: Equatable {
        case adobe
        case query(userParam: String, passParam: String)
    }
    static let defaultQueryUserParam = "user"
    static let defaultQueryPassParam = "pass"
    static func queryCredentials(of url: String, userParam: String, passParam: String) -> StreamDestination.Credentials? { nil }

    /// scheme 之后、authority 里最后一个 @ 之前的那段（userinfo 原文，含百分号转义）的范围；没有为 nil。
    static func userinfoRange(in url: String) -> Range<String.Index>? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = url[schemeEnd.upperBound..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }
        return schemeEnd.upperBound..<at
    }

    /// 打码显示：rtmp://user:pass@host/app → rtmp://•••@host/app。
    static func masked(_ url: String) -> String {
        guard let r = userinfoRange(in: url) else { return url }
        var s = url
        s.replaceSubrange(r, with: maskToken)
        return s
    }

    /// 地址框编辑完的文字 → 要存的地址：打码段还在原位就换回原来的 userinfo；用户把它删了 / 自己写了 user:pass@ 就照用户的。
    static func unmasked(_ edited: String, original: String) -> String {
        guard let r = userinfoRange(in: edited), edited[r] == maskToken[...] else { return edited }
        guard let o = userinfoRange(in: original) else {
            // 原来就没有账号：去掉记号
            var s = edited
            s.removeSubrange(r.lowerBound..<edited.index(after: r.upperBound))
            return s
        }
        var s = edited
        s.replaceSubrange(r, with: original[o])
        return s
    }

    /// 地址里的账号（解码后）：读法与连接层相同（StreamDestination.credentials）；地址还不完整时退回 URLComponents。
    static func credentials(of settings: StreamSettings) -> StreamDestination.Credentials? {
        if let d = try? StreamDestination(settings: settings) { return d.credentials }
        guard let c = URLComponents(string: settings.url.trimmingCharacters(in: .whitespaces)), let user = c.user, !user.isEmpty else { return nil }
        return StreamDestination.Credentials(user: user, password: c.password ?? "")
    }

    enum EditError: Error, Equatable {
        /// 地址解析不了（先把地址填对）。
        case invalidURL
        /// 只有 RTMP / RTMPS 用账号密码。
        case notRTMP
        /// SRT 的 passphrase 有不收的字符 / 长度不对。
        case invalidPassphrase
    }

    /// 写账号密码（用户名空 = 去掉整段 userinfo）。URLComponents 的 setter 自动转义一次。
    static func withCredentials(_ url: String, user: String, password: String) throws(EditError) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)), let scheme = c.scheme?.lowercased() else { throw .invalidURL }
        guard scheme == "rtmp" || scheme == "rtmps" else { throw .notRTMP }
        if user.isEmpty {
            c.user = nil
            c.password = nil
        } else {
            c.user = user
            c.password = password.isEmpty ? nil : password
        }
        guard let s = c.string else { throw .invalidURL }
        return s
    }

    /// SRT passphrase 允许的字符（字母数字和 - . _ ~）与长度（libsrt：10–79）。
    static func isValidSRTPassphrase(_ p: String) -> Bool {
        (10...79).contains(p.count) && p.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-._~".contains($0) }
    }

    /// 地址里的 SRT passphrase（没有为空串）。
    static func srtPassphrase(of url: String) -> String {
        URLComponents(string: url)?.percentEncodedQueryItems?.first { $0.name == "passphrase" }?.value ?? ""
    }

    /// 写 SRT passphrase（空 = 去掉）；别的查询项原样（percentEncodedQueryItems，不重新编码）。
    static func withSRTPassphrase(_ url: String, passphrase: String) throws(EditError) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)), c.scheme?.lowercased() == "srt" else { throw .invalidURL }
        guard passphrase.isEmpty || isValidSRTPassphrase(passphrase) else { throw .invalidPassphrase }
        var items = (c.percentEncodedQueryItems ?? []).filter { $0.name != "passphrase" }
        if !passphrase.isEmpty { items.append(URLQueryItem(name: "passphrase", value: passphrase)) }
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        guard let s = c.string else { throw .invalidURL }
        return s
    }

    /// 地址的协议（小写，没有为空串）。
    static func scheme(of url: String) -> String {
        url.trimmingCharacters(in: .whitespaces).components(separatedBy: "://").count > 1
            ? url.trimmingCharacters(in: .whitespaces).components(separatedBy: "://")[0].lowercased() : ""
    }
}
