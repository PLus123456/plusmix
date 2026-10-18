// 推流地址里的鉴权（W5-I，prompt 95 G6 追加；01a L10，reports/w5-stream-auth.md §5 第 3 条）：
// - RTMP / RTMPS："鉴权…"写回地址的 userinfo（user:pass@）。写用 URLComponents 的 user / password setter（自动只转义一次，不手拼），
//   读用推流包的 StreamDestination(settings:).credentials（与连接层同一份解码）。这是 Adobe（FMLE 兼容）鉴权：Wowza / Nimble / FMS 与一部分 CDN 入口用；
//   MediaMTX / SRS / nginx-rtmp 这类自建服务器要的是地址后面的查询串（MediaMTX：?user=…&pass=…），填在鉴权框里对它们没用。
// - SRT：passphrase 写进查询串；只收字母数字和 - . _ ~、10–79 个字符（HaishinKit 不解码查询串，问题单 W5D-w2-stream-srt-passphrase-reserved-chars）。
// - 地址框里 user:pass@ 打码显示（`masked`），编辑时打码段原样留着就换回原来的 userinfo（`unmasked`）。
// - W5-N（2026-10-10 裁定 ①）：鉴权表加"写法"二选一——Adobe（user:pass@，上面那种）/ 查询串（?user=&pass=，参数名可改、默认 MediaMTX 的 user / pass）。
//   查询串写进地址的 query、不碰 userinfo；两种写法互斥（写一种时把另一种的账号去掉，免得两头都带）。地址框打码同时盖住 query 里名单内参数的值
//   （名单 = 推流包 StreamURLRedaction.secretQueryParams，日志 / 诊断包同一份），编辑时打码的值原样留着就换回原值。节目只存整条地址，不加字段。
import Foundation
import SwitcherContracts
import SwitcherStreaming

/// 查询串鉴权用过的参数名（W5-P，W4C3 第 9 条）：鉴权表里的"用户名参数 / 密码参数"可以改成任意名字（SRS、nginx-rtmp 按回调的规矩起名），
/// 节目里只存整条地址，重新读地址时原来只认 user / pass 那几个——用了别的名字，按钮旁写"没有鉴权"、再打开小表停在 Adobe，换写法也去不掉。
/// 表里存过的名字记在本机（最近 8 对，新的在前；不分大小写去重），认写法、换写法时先按它们。不进节目文件（契约不动）：换一台机器打开要重新在表里填一次。
struct StreamAuthParamMemory {
    static let key = "streamAuthQueryParams"
    static let limit = 8
    let defaults: UserDefaults

    var pairs: [(user: String, pass: String)] {
        (defaults.array(forKey: Self.key) as? [[String]] ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// 记下一对（已有就挪到最前）；认得的默认名字（user / pass 那几个）不用记。
    func remember(user: String, pass: String) {
        guard !(StreamAddress.queryUserParamNames.contains(user.lowercased()) && StreamAddress.queryPassParamNames.contains(pass.lowercased())) else { return }
        var list = pairs.filter { $0.user.lowercased() != user.lowercased() || $0.pass.lowercased() != pass.lowercased() }
        list.insert((user, pass), at: 0)
        defaults.set(list.prefix(Self.limit).map { [$0.user, $0.pass] }, forKey: Self.key)
    }
}

enum StreamAddress {
    /// 地址框里代替 userinfo 的记号。
    static let maskToken = "•••"

    /// RTMP 鉴权的写法（2026-10-10 裁定 ①）。
    enum AuthStyle: Equatable {
        /// user:pass@（Adobe / FMLE 兼容鉴权：Wowza / Nimble / FMS 与一部分 CDN 入口）。
        case adobe
        /// 地址后面的查询串（MediaMTX / SRS / nginx-rtmp 一类自建服务器）；参数名按服务器的规矩。
        case query(userParam: String, passParam: String)
    }
    /// 查询串写法的默认参数名（MediaMTX：?user=…&pass=…）。
    static let defaultQueryUserParam = "user"
    static let defaultQueryPassParam = "pass"
    /// 认作"查询串里的账号"的参数名（不分大小写）：认写法、换写法时去掉旧账号都按它。
    static let queryUserParamNames: Set<String> = ["user", "username", "usr"]
    static let queryPassParamNames: Set<String> = ["pass", "password", "pwd", "passwd"]

    /// 地址现在是哪种写法：有 userinfo = Adobe；查询串里有认得的账号参数 = 查询串（参数名照地址里的）；都没有 = Adobe（默认）。
    /// remembered = 本机表里用过的参数名（StreamAuthParamMemory，W4C3 第 9 条），先按它们认（新的在前），再按默认那几个名字。
    static func authStyle(of url: String, remembered: [(user: String, pass: String)] = []) -> AuthStyle {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if userinfoRange(in: trimmed) != nil { return .adobe }
        let items = URLComponents(string: trimmed)?.percentEncodedQueryItems ?? []
        for pair in remembered {
            guard let user = items.first(where: { $0.name.lowercased() == pair.user.lowercased() }) else { continue }
            let pass = items.first { $0.name.lowercased() == pair.pass.lowercased() }
            return .query(userParam: user.name, passParam: pass?.name ?? pair.pass)
        }
        guard let user = items.first(where: { queryUserParamNames.contains($0.name.lowercased()) }) else { return .adobe }
        let pass = items.first { queryPassParamNames.contains($0.name.lowercased()) }
        return .query(userParam: user.name, passParam: pass?.name ?? defaultQueryPassParam)
    }

    /// 查询串里的账号（解码后）；没有用户名为 nil。
    static func queryCredentials(of url: String, userParam: String, passParam: String) -> StreamDestination.Credentials? {
        let items = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.queryItems ?? []
        guard let user = items.first(where: { $0.name == userParam })?.value, !user.isEmpty else { return nil }
        return StreamDestination.Credentials(user: user, password: items.first { $0.name == passParam }?.value ?? "")
    }

    /// 查询串的值只留 RFC 3986 的非保留字符，其余百分号编码（& = + # ? @ / 空格都编码，不同服务器对 + 的解释不一样）。
    private static let queryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 写查询串账号（RTMP / RTMPS）：去掉 userinfo（两种写法互斥）与查询串里旧的账号参数（新给的两个名字 + 认得的那几个 + alsoDrop——
    /// 换写法 / 换名字之前认出来的那一对，W4C3 第 9 条），别的查询项原样；用户名空 = 只去掉、不写；密码空 = 只写用户名。
    static func withQueryCredentials(_ url: String, user: String, password: String, userParam: String, passParam: String,
                                     alsoDrop: Set<String> = []) throws(EditError) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)), let scheme = c.scheme?.lowercased() else { throw .invalidURL }
        guard scheme == "rtmp" || scheme == "rtmps" else { throw .notRTMP }
        let u = userParam.trimmingCharacters(in: .whitespaces), p = passParam.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !p.isEmpty, u != p, (u + p).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else { throw .invalidParamName }
        c.user = nil
        c.password = nil
        let drop = queryUserParamNames.union(queryPassParamNames).union([u.lowercased(), p.lowercased()]).union(alsoDrop.map { $0.lowercased() })
        var items = (c.percentEncodedQueryItems ?? []).filter { !drop.contains($0.name.lowercased()) }
        if !user.isEmpty {
            items.append(URLQueryItem(name: u, value: user.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)))
            if !password.isEmpty { items.append(URLQueryItem(name: p, value: password.addingPercentEncoding(withAllowedCharacters: queryValueAllowed))) }
        }
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        guard let s = c.string else { throw .invalidURL }
        return s
    }

    /// 这个参数名的值在地址框 / 日志里会不会打码（名单 = StreamURLRedaction.secretQueryParams）。
    static func isMaskedQueryParam(_ name: String) -> Bool { StreamURLRedaction.secretQueryParams.contains(name.lowercased()) }

    /// scheme 之后、authority 里最后一个 @ 之前的那段（userinfo 原文，含百分号转义）的范围；没有为 nil。
    static func userinfoRange(in url: String) -> Range<String.Index>? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = url[schemeEnd.upperBound..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }
        return schemeEnd.upperBound..<at
    }

    /// 打码显示：rtmp://user:pass@host/app → rtmp://•••@host/app；查询串里名单内参数的值也换成记号（?user=•••&pass=•••，W5-N）。
    /// 与日志 / 诊断包同一个函数（StreamURLRedaction.redact），只是记号换成 •••。
    static func masked(_ url: String) -> String {
        StreamURLRedaction.redact(url: url, marker: maskToken)
    }

    /// 地址框编辑完的文字 → 要存的地址：打码段还在原位就换回原来的 userinfo / 查询值；用户把它删了 / 自己写了新的就照用户的。
    static func unmasked(_ edited: String, original: String) -> String {
        unmaskedQuery(unmaskedUserinfo(edited, original: original), original: original)
    }

    private static func unmaskedUserinfo(_ edited: String, original: String) -> String {
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

    /// 查询串里值还是记号的项：换回原地址里同名项的原值（百分号编码原样）；原地址里没有这一项就去掉它。按原文切，不经 URLComponents（不重新编码）。
    private static func unmaskedQuery(_ edited: String, original: String) -> String {
        guard let (prefix, items, fragment) = splitQuery(edited), items.contains(where: { $0.hasSuffix("=" + maskToken) }) else { return edited }
        var originals: [String: String] = [:]
        for item in splitQuery(original)?.items ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, originals[String(parts[0])] == nil { originals[String(parts[0])] = String(parts[1]) }
        }
        let restored = items.compactMap { item -> String? in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == maskToken[...] else { return item }
            return originals[String(parts[0])].map { "\(parts[0])=\($0)" }
        }
        return restored.isEmpty ? prefix + fragment : prefix + "?" + restored.joined(separator: "&") + fragment
    }

    /// 地址按原文切成"? 之前 / 查询项 / # 起的片段"；没有 ? 为 nil。
    private static func splitQuery(_ s: String) -> (prefix: String, items: [String], fragment: String)? {
        guard let q = s.firstIndex(of: "?") else { return nil }
        var rest = s[s.index(after: q)...]
        var fragment = ""
        if let h = rest.firstIndex(of: "#") { fragment = String(rest[h...]); rest = rest[..<h] }
        return (String(s[..<q]), rest.split(separator: "&", omittingEmptySubsequences: false).map(String.init), fragment)
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
        /// 查询串写法的参数名空了 / 两个一样 / 有不收的字符（只收字母数字和 - . _ ~）。
        case invalidParamName
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
