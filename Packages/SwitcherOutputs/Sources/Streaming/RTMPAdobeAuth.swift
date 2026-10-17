import CryptoKit
import Foundation
import Network
import RTMPHaishinKit

/// RTMP 的 Adobe 鉴权（authmod=adobe：FMS / Wowza / Nimble 一类服务器在 connect 阶段做的 challenge-response），地址里写 user:pass@ 时用。
///
/// HaishinKit 2.2.5 自带一套（RTMPAuthenticator：connect 的地址带 userinfo 就自动做），探针实测不能用（reports/w5-stream-auth.md §1）：
/// 1. 拿 `URL.password` 算 MD5，这个属性不解码：密码里有 @ : / % 空格 中文…（地址里必须转义的字符）就算错；
/// 2. 服务器回 reason=authfailed / nosuchuser 时（描述里也带 authmod=adobe）它在 connect() 里从第 2 轮重来、地址越拼越长、不看取消：
///    服务器 20 ms 往返时 13 s 连了 430 次、100 ms 时 43 s 380 次，直到撞上第 3 条的竞态才停——StreamOutput 的连接超时拦不住，stop() 被拖住；
/// 3. 每轮被拒之后的递归 connect 和旧连接的收尾有竞态，约一成以 socketErrorOccurred(nil) 失败；
/// 4. 描述里有 reason=needauth 时强制解包 user / password / salt（地址没写密码就崩）。
/// 所以 user:pass@ 不交给它：这里用一个只会"握手 + connect + 读回复"的最小客户端做前两轮（问服务器要不要鉴权、拿 salt / challenge / opaque），
/// 用解码后的密码自己算应答，把第三轮的参数拼进不带 userinfo 的地址交给 HaishinKit 连（app / tcUrl 跟 ffmpeg 一样带上鉴权参数）。
/// 地址里没有 userinfo，它的鉴权逻辑在 authfailed / nosuchuser 时只会抛 noCredential，不会重连。剩下的口子是第 4 条：第三轮服务器回 needauth
/// （挑战过期才会）它照样崩，要在 HaishinKit 里修。不支持 llnw（Limelight）：HaishinKit 也不支持，服务器要它时报"不支持"。
enum RTMPAdobeAuth {
    /// 失败原因（描述给日志 / 状态行，不带密码）。
    enum Failure: Swift.Error, CustomStringConvertible, Equatable {
        /// 服务器拒绝了这套账号：类型化的原因（nosuchuser / authfailed）+ 服务器回的原文（状态码 + 描述），W2-D4 原样进 last_error。
        case badCredentials(StreamAuthFailure, String)
        case unsupported(String)
        case rejected(String)
        case protocolError(String)
        case timedOut

        var description: String {
            switch self {
            case .badCredentials(let reason, let s): return "\(reason.summary)：\(s)"
            case .unsupported(let s): return "\(StreamAuthFailure.unsupportedMethod.summary)：\(s)"
            case .rejected(let s): return "服务器拒绝连接：\(s)"
            case .protocolError(let s): return "RTMP 协议错误：\(s)"
            case .timedOut: return "鉴权超时"
            }
        }
    }

    /// connect 的回复（txid 1 的 _result / _error 的状态对象）。
    struct ConnectReply: Sendable, Equatable {
        var command: String
        var level: String
        var code: String
        var description: String

        var isSuccess: Bool { command == "_result" && code == "NetConnection.Connect.Success" }
    }

    /// connect 命令里的 flashVer：跟 HaishinKit 的一样（服务器看到的两种连接是同一个客户端）。
    static let flashVer = RTMPConnection.defaultFlashVer

    /// 前两轮。`connectURL` 不带 userinfo；返回交给 HaishinKit 的 connect 地址（也不带 userinfo）：
    /// - 第 1 轮就被接受（connect 阶段不要鉴权；MediaMTX 这种在 publish 时查 ?user=&pass= 的也是）→ 原地址，userinfo 用不上；
    /// - 要 adobe → 原地址 + "authmod=adobe&user=…&challenge=…&response=…&opaque=…"（有原查询串就用 & 接）。
    static func authorize(connectURL: String, credentials: StreamDestination.Credentials, timeoutSeconds: Double) async throws -> String {
        let first = try await probeConnect(url: connectURL, timeoutSeconds: timeoutSeconds)
        if first.isSuccess { return connectURL }
        guard first.description.contains("authmod=adobe") else {
            if first.description.contains("authmod=llnw") { throw Failure.unsupported("服务器要 Limelight（authmod=llnw）") }
            throw Failure.rejected("\(first.code) \(first.description)")
        }
        let user = escapeQueryValue(credentials.user)
        var params = parameters(inDescription: first.description)
        if params["reason"] != "needauth" {
            let withUser = appendingQuery(connectURL, "authmod=adobe&user=\(user)")
            let second = try await probeConnect(url: withUser, timeoutSeconds: timeoutSeconds)
            if second.isSuccess { return withUser }
            params = parameters(inDescription: second.description)
            let reply = StreamURLRedaction.redact(text: "\(second.code) \(second.description)")
            switch params["reason"] {
            case "needauth": break
            case "nosuchuser": throw Failure.badCredentials(.noSuchUser, reply)
            case "authfailed": throw Failure.badCredentials(.badCredentials, reply)
            default: throw Failure.rejected(reply)
            }
        }
        guard let salt = params["salt"] else { throw Failure.protocolError("needauth 回复里没有 salt") }
        let clientChallenge = String(format: "%08x", UInt32.random(in: .min ... .max))
        let opaque = params["opaque"]
        let r = response(user: credentials.user, password: credentials.password, salt: salt, opaque: opaque, challenge: params["challenge"],
                         clientChallenge: clientChallenge)
        var query = "authmod=adobe&user=\(user)&challenge=\(clientChallenge)&response=\(r)"
        if let opaque { query += "&opaque=\(opaque)" }
        return appendingQuery(connectURL, query)
    }

    /// Adobe 公式（ffmpeg rtmpproto.c do_adobe_auth 同一套）：base64(md5(base64(md5(user + salt + password)) + (opaque ?? challenge) + 客户端 challenge))。
    /// user / password 用解码后的原文（UTF-8）。
    static func response(user: String, password: String, salt: String, opaque: String?, challenge: String?, clientChallenge: String) -> String {
        var h = md5Base64(user + salt + password)
        if let opaque { h += opaque } else if let challenge { h += challenge }
        return md5Base64(h + clientChallenge)
    }

    /// 服务器描述里 "?" 之后的参数（原样，不解码：salt / opaque 原样进 MD5 和查询串，ffmpeg 也是这样）。
    static func parameters(inDescription d: String) -> [String: String] {
        guard let q = d.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for item in d[d.index(after: q)...].split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            out[String(kv[0])] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return out
    }

    /// 一轮：连上（rtmps 走 TLS）→ 简单握手 → connect → 读到 txid 1 的回复 → 关。
    static func probeConnect(url: String, timeoutSeconds: Double) async throws -> ConnectReply {
        guard let u = URLComponents(string: url), let scheme = u.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps",
              let host = u.host, !host.isEmpty else {
            throw Failure.protocolError("地址解析不了：\(StreamURLRedaction.redact(url: url))")
        }
        let secure = scheme == "rtmps"
        // app / tcUrl 跟 HaishinKit 拼的一样：app = 路径（解码）去掉开头的 / + "?" + 查询串；tcUrl = 整个地址
        var app = String(u.path.drop { $0 == "/" })
        if let q = u.percentEncodedQuery { app += "?" + q }
        let probe = RTMPConnectProbe(host: host, port: u.port ?? (secure ? 443 : 1935), secure: secure, timeoutSeconds: timeoutSeconds)
        return try await probe.run(app: app, tcUrl: url)
    }

    private static func md5Base64(_ s: String) -> String {
        Data(Insecure.MD5.hash(data: Data(s.utf8))).base64EncodedString()
    }

    private static func appendingQuery(_ url: String, _ query: String) -> String {
        url + (url.contains("?") ? "&" : "?") + query
    }

    /// 查询串里的用户名：常见的（字母数字、邮箱）原样，跟 ffmpeg / HaishinKit 一样；& = + # % ? 空格和非 ASCII 才转义。
    private static func escapeQueryValue(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$'()*,;:@/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// 一次性的最小 RTMP 客户端（Network.framework）：握手、发 connect、读到 txid 1 的回复就关。只给 Adobe 鉴权的前两轮用。
/// 所有 await 在同一个 Task 里依次走，收包缓冲不用锁；超时和 Task 取消都是 cancel 掉连接，挂着的收发随之以错误返回。
final class RTMPConnectProbe: @unchecked Sendable {
    private struct ChunkHeader {
        var length: Int
        var type: UInt8
        var streamId: UInt32
        var extended: Bool
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "switcher.stream.rtmp-auth")
    private let timeoutSeconds: Double
    private let timedOut = Flag()
    private let cancelled = Flag()
    private var buffer = Data()
    private var inChunkSize = 128
    private var headers: [Int: ChunkHeader] = [:]
    private var partial: [Int: Data] = [:]

    init(host: String, port: Int, secure: Bool, timeoutSeconds: Double) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 1935,
                                  using: secure ? .tls : .tcp)
        self.timeoutSeconds = timeoutSeconds
    }

    func run(app: String, tcUrl: String) async throws -> RTMPAdobeAuth.ConnectReply {
        let connection = connection, timedOut = timedOut, cancelled = cancelled
        let timer = DispatchWorkItem { timedOut.set(); connection.cancel() }
        queue.asyncAfter(deadline: .now() + max(0.1, timeoutSeconds), execute: timer)
        defer {
            timer.cancel()
            connection.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await exchange(app: app, tcUrl: tcUrl)
            } onCancel: {
                cancelled.set()
                connection.cancel()
            }
        } catch {
            if timedOut.isSet { throw RTMPAdobeAuth.Failure.timedOut }
            if cancelled.isSet { throw CancellationError() }
            if let e = error as? RTMPAdobeAuth.Failure { throw e }
            throw RTMPAdobeAuth.Failure.protocolError("\(error)")
        }
    }

    private func exchange(app: String, tcUrl: String) async throws -> RTMPAdobeAuth.ConnectReply {
        try await start()
        // 简单握手：C0C1 → S0S1 → C2（回显 S1）→ S2（有的服务器不等 C2 就发 S2，按顺序读一样）
        var c0c1 = Data(count: 1537)
        c0c1[0] = 3
        for i in 9..<1537 { c0c1[i] = UInt8.random(in: 0...255) }
        try await send(c0c1)
        let s0s1 = try await receive(1537)
        guard s0s1[0] == 3 else { throw RTMPAdobeAuth.Failure.protocolError("服务器的 RTMP 版本是 \(s0s1[0])") }
        var c2 = s0s1.subdata(in: 1..<1537)
        c2.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        try await send(c2)
        _ = try await receive(1536)
        try await send(RTMPConnectCommand.chunks(app: app, tcUrl: tcUrl, flashVer: RTMPAdobeAuth.flashVer))
        while true {
            let message = try await nextMessage()
            switch message.type {
            case 1:      // Set Chunk Size
                guard message.payload.count >= 4 else { throw RTMPAdobeAuth.Failure.protocolError("Set Chunk Size 不够 4 字节") }
                let p = message.payload
                inChunkSize = max(1, Int((UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])) & 0x7FFF_FFFF))
            case 20, 17: // AMF0 / AMF3 命令（AMF3 命令第一个字节是 0，后面还是 AMF0）
                let body = message.type == 17 ? Data(message.payload.dropFirst()) : message.payload
                if let reply = try RTMPConnectCommand.reply(body), reply.txid == 1 { return reply.reply }
            default:     // Window Ack Size / Set Peer Bandwidth / User Control / 数据消息……
                continue
            }
        }
    }

    // MARK: 分块（收）

    /// 下一条完整消息。块头 fmt 0–3、扩展时间戳、多个块流交错都按 RTMP 规范处理。
    private func nextMessage() async throws -> (type: UInt8, payload: Data) {
        while true {
            let b0 = try await receive(1)[0]
            let fmt = b0 >> 6
            var csid = Int(b0 & 0x3F)
            if csid == 0 {
                csid = 64 + Int(try await receive(1)[0])
            } else if csid == 1 {
                let b = try await receive(2)
                csid = 64 + Int(b[0]) + Int(b[1]) * 256
            }
            var header = headers[csid]
            switch fmt {
            case 0:
                let m = try await receive(11)
                header = ChunkHeader(length: Int(m[3]) << 16 | Int(m[4]) << 8 | Int(m[5]), type: m[6],
                                     streamId: UInt32(m[7]) | UInt32(m[8]) << 8 | UInt32(m[9]) << 16 | UInt32(m[10]) << 24,
                                     extended: m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF)
            case 1:
                guard let previous = header else { throw RTMPAdobeAuth.Failure.protocolError("块流 \(csid) 的第一块不是 fmt 0") }
                let m = try await receive(7)
                header = ChunkHeader(length: Int(m[3]) << 16 | Int(m[4]) << 8 | Int(m[5]), type: m[6], streamId: previous.streamId,
                                     extended: m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF)
            case 2:
                guard let previous = header else { throw RTMPAdobeAuth.Failure.protocolError("块流 \(csid) 的第一块不是 fmt 0") }
                let m = try await receive(3)
                header = ChunkHeader(length: previous.length, type: previous.type, streamId: previous.streamId,
                                     extended: m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF)
            default:
                guard header != nil else { throw RTMPAdobeAuth.Failure.protocolError("块流 \(csid) 的第一块不是 fmt 0") }
            }
            guard let h = header else { continue }
            if h.extended { _ = try await receive(4) }
            headers[csid] = h
            var body = partial[csid] ?? Data()
            let n = min(inChunkSize, h.length - body.count)
            if n > 0 { body.append(try await receive(n)) }
            if body.count >= h.length {
                partial[csid] = nil
                return (h.type, body)
            }
            partial[csid] = body
        }
    }

    // MARK: Network.framework 的 async 包装

    private func start() async throws {
        let connection = connection, cancelled = cancelled
        let once = Flag()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { c.resume() }
                case .failed(let e), .waiting(let e): if once.take() { c.resume(throwing: e) }
                case .cancelled: if once.take() { c.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
            // start 之前就被取消了：cancel() 可能不会再触发 .cancelled
            if cancelled.isSet, once.take() { c.resume(throwing: CancellationError()) }
        }
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// 正好 n 个字节（下标从 0 开始）。
    private func receive(_ n: Int) async throws -> Data {
        let connection = connection
        while buffer.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        c.resume(returning: data)
                    } else if let error {
                        c.resume(throwing: error)
                    } else if isComplete {
                        c.resume(throwing: RTMPAdobeAuth.Failure.protocolError("服务器关了连接"))
                    } else {
                        c.resume(throwing: RTMPAdobeAuth.Failure.protocolError("空读"))
                    }
                }
            }
            buffer.append(chunk)
        }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
        /// 第一次调用返回 true。
        func take() -> Bool { lock.withLock { defer { value = true }; return !value } }
    }
}

/// connect 命令（AMF0）与回复的编解码，只做这两样。
enum RTMPConnectCommand {
    /// connect(1, {app, type: nonprivate, flashVer, tcUrl})：发布端（FMLE / ffmpeg）发的就是这几个字段。
    /// 块流 3、消息类型 20、消息流 0、时间戳 0，按默认块大小 128 分块（connect 之前谁都没发 Set Chunk Size）。
    static func chunks(app: String, tcUrl: String, flashVer: String) -> Data {
        var p = string("connect") + number(1)
        p.append(0x03)
        for (k, v) in [("app", app), ("type", "nonprivate"), ("flashVer", flashVer), ("tcUrl", tcUrl)] {
            let kb = Data(k.utf8)
            p += Data([UInt8(kb.count >> 8 & 0xFF), UInt8(kb.count & 0xFF)]) + kb + string(v)
        }
        p += Data([0x00, 0x00, 0x09])
        var out = Data([0x03, 0, 0, 0, UInt8(p.count >> 16 & 0xFF), UInt8(p.count >> 8 & 0xFF), UInt8(p.count & 0xFF), 20, 0, 0, 0, 0])
        var i = 0
        while i < p.count {
            if i > 0 { out.append(0xC3) }
            let n = min(128, p.count - i)
            out += p[i..<i + n]
            i += n
        }
        return out
    }

    /// _result / _error → (txid, 状态对象)；别的命令（onBWDone、onStatus…）返回 nil。
    static func reply(_ body: Data) throws -> (txid: Double, reply: RTMPAdobeAuth.ConnectReply)? {
        var r = Reader(bytes: [UInt8](body))
        guard case .string(let name) = try r.value(), name == "_result" || name == "_error" else { return nil }
        guard case .number(let txid) = try r.value() else { return nil }
        _ = try r.value()                       // 命令对象：_result 带 fmsVer / capabilities，_error 一般是 null
        var info: [String: Value] = [:]
        if !r.atEnd, case .object(let o) = try r.value() { info = o }
        func text(_ key: String) -> String {
            if case .string(let s)? = info[key] { return s }
            return ""
        }
        return (txid, RTMPAdobeAuth.ConnectReply(command: name, level: text("level"), code: text("code"), description: text("description")))
    }

    private static func string(_ s: String) -> Data {
        let u = Data(s.utf8)
        if u.count > 0xFFFF {
            return Data([0x0C, UInt8(u.count >> 24 & 0xFF), UInt8(u.count >> 16 & 0xFF), UInt8(u.count >> 8 & 0xFF), UInt8(u.count & 0xFF)]) + u
        }
        return Data([0x02, UInt8(u.count >> 8 & 0xFF), UInt8(u.count & 0xFF)]) + u
    }

    private static func number(_ v: Double) -> Data {
        Data([0x00]) + withUnsafeBytes(of: v.bitPattern.bigEndian) { Data($0) }
    }

    enum Value {
        case number(Double)
        case bool(Bool)
        case string(String)
        case object([String: Value])
        case array([Value])
        case null
        case other
    }

    struct Reader {
        let bytes: [UInt8]
        var i = 0

        var atEnd: Bool { i >= bytes.count }

        private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= bytes.count else { throw RTMPAdobeAuth.Failure.protocolError("AMF0 越界") }
            defer { i += n }
            return bytes[i..<i + n]
        }

        private mutating func u16() throws -> Int { try take(2).reduce(0) { $0 << 8 | Int($1) } }
        private mutating func u32() throws -> Int { try take(4).reduce(0) { $0 << 8 | Int($1) } }
        private mutating func utf8(_ n: Int) throws -> String { String(decoding: try take(n), as: UTF8.self) }

        mutating func value() throws -> Value {
            switch try take(1).first! {
            case 0x00: return .number(Double(bitPattern: try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }))
            case 0x01: return .bool(try take(1).first! != 0)
            case 0x02: return .string(try utf8(try u16()))
            case 0x03: return .object(try properties())
            case 0x05, 0x06: return .null
            case 0x08:
                _ = try take(4)
                return .object(try properties())
            case 0x0A:
                var items: [Value] = []
                for _ in 0..<(try u32()) { items.append(try value()) }
                return .array(items)
            case 0x0B:
                _ = try take(10)
                return .other
            case 0x0C: return .string(try utf8(try u32()))
            case 0x10:
                _ = try take(try u16())
                return .object(try properties())
            case let marker: throw RTMPAdobeAuth.Failure.protocolError("AMF0 类型 \(marker) 不认")
            }
        }

        /// 对象体：(键, 值)… 直到空键 + 0x09。
        private mutating func properties() throws -> [String: Value] {
            var out: [String: Value] = [:]
            while true {
                let key = try utf8(try u16())
                if key.isEmpty, i < bytes.count, bytes[i] == 0x09 {
                    i += 1
                    return out
                }
                out[key] = try value()
            }
        }
    }
}
