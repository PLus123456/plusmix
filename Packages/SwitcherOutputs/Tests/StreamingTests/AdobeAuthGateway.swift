import CryptoKit
import Darwin
import Foundation

/// 测试用的 RTMP Adobe 鉴权服务器端（"authmod=adobe"：FMS / Wowza 一类在 connect 阶段做的 challenge-response），独立于 SwitcherStreaming 的实现写，
/// 可以单独用（验过之后自己回 NetConnection.Connect.Success），也可以放在开了鉴权的 MediaMTX 前面当网关。
/// 为什么要它：MediaMTX 1.21 只认查询串里的 `?user=&pass=`（publish 时查），不发 Adobe 挑战；地址里的 user:pass@ 按惯例不上线
/// （HaishinKit / ffmpeg 都从 tcUrl 里去掉），只有服务器要 Adobe 鉴权时客户端才拿它算应答（reports/w5-stream-auth.md §1）。
///
/// 每个客户端连接：自己跟客户端做 RTMP 简单握手，读第一条消息（connect 命令），看 app 的查询串：
/// 1. 没有 authmod=adobe → 回 _error（NetConnection.Connect.Rejected，"code=403 need auth; authmod=adobe"），断开；
/// 2. 有 authmod=adobe&user=…、没有 response → 用户名不对回 reason=nosuchuser；对就发 salt / challenge / opaque（reason=needauth），断开；
/// 3. 带 response → 按 Adobe 公式验 base64(md5(base64(md5(user + salt + password)) + opaque + 客户端 challenge))：不对回 reason=authfailed 断开；
///    对了：没有上游就回 _result（Connect.Success）；有上游就连上游、握手，把 connect 的 app / tcUrl 里的 Adobe 参数换成 `upstreamQuery`
///    （MediaMTX 的 user=&pass=）转过去，之后两个方向原样转发。
/// 自己回的 _error / _result 之前先发 Window Ack Size / Set Peer Bandwidth / Set Chunk Size（4096），跟真服务器一样，客户端的分块解析也被走到。
/// 每次尝试记下 app、tcUrl、结果和客户端发来的 connect 原始字节（测试断言"密码不明文上线"）。
final class AdobeAuthGateway: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case askedForAuthmod           // 第 1 轮：没带 authmod，回"要 adobe 鉴权"
        case challenged                // 第 2 轮：发了 salt / challenge / opaque
        case noSuchUser
        case authFailed                // 第 3 轮：应答不对
        case accepted                  // 验过了（回了 Success 或转给了上游）
        case upstreamFailed(String)
        case protocolError(String)
    }

    struct Attempt: Sendable {
        var app: String
        var tcUrl: String
        var outcome: Outcome
        /// 客户端这次握手之后发来的 connect 消息原始字节（含块头）。
        var connectBytes: Data
    }

    let listenPort: Int
    /// 上游（MediaMTX）的 RTMP 端口；nil = 验过之后自己回 Success。
    let targetPort: Int?
    let user: String
    let password: String
    /// 验过之后转给上游的 connect：app / tcUrl 去掉 Adobe 参数、补上这个查询串（nil = 不补）。
    let upstreamQuery: String?
    private let listenFD: Int32
    private let lock = NSLock()
    private var running = true
    private var open: Set<Int32> = []                                      // lock；关 fd 也在锁里（stop 不会碰到被复用的 fd 号）
    private var issued: [String: (salt: String, challenge: String)] = [:]  // lock；opaque → 发出去的 salt / challenge
    private var log: [Attempt] = []                                        // lock
    private var delay: TimeInterval = 0                                    // lock

    init(listenPort: Int, targetPort: Int?, user: String, password: String, upstreamQuery: String?) throws {
        self.listenPort = listenPort
        self.targetPort = targetPort
        self.user = user
        self.password = password
        self.upstreamQuery = upstreamQuery
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw GatewayError("socket") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port: listenPort)
        let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); throw GatewayError("bind/listen \(listenPort): errno \(errno)") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "adobe-auth-gateway.accept.\(listenPort)"
        t.start()
    }

    /// 到目前为止的尝试（按时间）。
    var attempts: [Attempt] { lock.withLock { log } }

    /// 回 _error 之前等多久（模拟服务器在远端：网络往返 + 服务器处理）。
    var rejectDelay: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    func stop() {
        lock.withLock {
            running = false
            for fd in open { shutdown(fd, SHUT_RDWR) }
        }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    // MARK: 连接处理

    private func acceptLoop() {
        while lock.withLock({ running }) {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { break }
            Self.configure(client)
            lock.withLock { _ = open.insert(client) }
            let t = Thread { [weak self] in self?.handle(client: client) }
            t.name = "adobe-auth-gateway.conn"
            t.start()
        }
    }

    private func closeFD(_ fd: Int32) {
        lock.withLock {
            open.remove(fd)
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func handle(client: Int32) {
        var handedOff = false
        defer { if !handedOff { closeFD(client) } }
        // 握手：C0C1 → S0S1S2（一次写完：HaishinKit 要等 S2 的头几个字节到了才发 C2）→ C2
        guard let c0c1 = Self.read(client, 1537), c0c1[0] == 3 else { return record("", "", .protocolError("C0C1")) }
        var s = [UInt8](repeating: 0, count: 1 + 1536 + 1536)
        s[0] = 3
        for i in 9...1536 { s[i] = UInt8.random(in: 0...255) }
        s.replaceSubrange(1537..<3073, with: c0c1[1...1536])
        guard Self.write(client, s), Self.read(client, 1536) != nil else { return record("", "", .protocolError("C2")) }
        guard let first = Self.readFirstMessage(client) else { return record("", "", .protocolError("connect 消息")) }
        let raw = Data(first.raw)
        guard first.type == 20, let cmd = try? AMF0.parseConnect(first.payload) else {
            return record("", "", .protocolError("不是 AMF0 connect（类型 \(first.type)）"), raw)
        }
        let q = Self.query(cmd.app)
        func reply(_ payload: [UInt8], _ outcome: Outcome, delayed: Bool) {
            let d = rejectDelay
            if delayed, d > 0 { Thread.sleep(forTimeInterval: d) }
            _ = Self.write(client, AMF0.serverPreamble + AMF0.chunks(payload: payload, chunkSize: AMF0.serverChunkSize))
            record(cmd.app, cmd.tcUrl, outcome, raw)
        }
        func reject(_ description: String, _ outcome: Outcome) {
            reply(AMF0.connectError(txid: cmd.txid, description: description), outcome, delayed: true)
        }
        guard q["authmod"] == "adobe" else {
            return reject("[ AccessManager.Reject ] : [ code=403 need auth; authmod=adobe ] : ", .askedForAuthmod)
        }
        guard q["user"] == user else {
            return reject("[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=nosuchuser&opaque=\(Self.token())", .noSuchUser)
        }
        guard let response = q["response"] else {
            let salt = Self.token(), challenge = Self.token(), opaque = Self.token()
            lock.withLock { issued[opaque] = (salt, challenge) }
            return reject("[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=needauth&user=\(user)&salt=\(salt)&challenge=\(challenge)&opaque=\(opaque)",
                          .challenged)
        }
        let opaque = q["opaque"] ?? ""
        guard let sent = lock.withLock({ issued[opaque] }), let clientChallenge = q["challenge"],
              response == Self.adobeResponse(user: user, password: password, salt: sent.salt, opaqueOrChallenge: opaque.isEmpty ? sent.challenge : opaque,
                                             clientChallenge: clientChallenge) else {
            return reject("[ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=authfailed&opaque=\(opaque)", .authFailed)
        }
        guard let targetPort else {
            // 没有上游：自己回 Success，等客户端关
            reply(AMF0.connectSuccess(txid: cmd.txid), .accepted, delayed: false)
            _ = Self.read(client, 1)
            return
        }
        // 验过了：连上游、握手、改写 connect 转过去，之后原样转发
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var addr = Self.loopback(port: targetPort)
        let ok = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { close(server); return record(cmd.app, cmd.tcUrl, .upstreamFailed("connect errno \(errno)"), raw) }
        Self.configure(server)
        lock.withLock { _ = open.insert(server) }
        var c1 = [UInt8](repeating: 0, count: 1 + 1536)
        c1[0] = 3
        for i in 9...1536 { c1[i] = UInt8.random(in: 0...255) }
        guard Self.write(server, c1), let s012 = Self.read(server, 3073), Self.write(server, Array(s012[1...1536])) else {
            closeFD(server)
            return record(cmd.app, cmd.tcUrl, .upstreamFailed("握手"), raw)
        }
        let payload = AMF0.replacing(first.payload, [(cmd.appRange, rewrite(cmd.app)), (cmd.tcUrlRange, rewrite(cmd.tcUrl))])
        guard Self.write(server, AMF0.chunks(payload: payload, chunkSize: 128)) else {
            closeFD(server)
            return record(cmd.app, cmd.tcUrl, .upstreamFailed("转发 connect"), raw)
        }
        // 握手 / connect 阶段的读超时去掉，之后是长连接；两个方向都结束了再关两个 fd
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        record(cmd.app, cmd.tcUrl, .accepted, raw)
        handedOff = true
        let pair = PipePair()
        for (src, dst, name) in [(client, server, "up"), (server, client, "down")] {
            let t = Thread { [weak self] in
                self?.forward(from: src, to: dst)
                if pair.finishOne() { self?.closeFD(client); self?.closeFD(server) }
            }
            t.name = "adobe-auth-gateway.\(name)"
            t.start()
        }
    }

    private func record(_ app: String, _ tcUrl: String, _ outcome: Outcome, _ raw: Data = Data()) {
        lock.withLock { log.append(Attempt(app: app, tcUrl: tcUrl, outcome: outcome, connectBytes: raw)) }
    }

    /// app / tcUrl 去掉 Adobe 参数，补上 upstreamQuery。
    private func rewrite(_ s: String) -> String {
        let adobe: Set<String> = ["authmod", "user", "challenge", "response", "opaque"]
        var base = s
        var kept: [String] = []
        if let q = s.firstIndex(of: "?") {
            base = String(s[..<q])
            kept = s[s.index(after: q)...].split(separator: "&").map(String.init).filter { item in
                !adobe.contains(String(item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]))
            }
        }
        if let upstreamQuery { kept.append(upstreamQuery) }
        return kept.isEmpty ? base : base + "?" + kept.joined(separator: "&")
    }

    private func forward(from src: Int32, to dst: Int32) {
        let bufSize = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate(); shutdown(dst, SHUT_WR) }
        while lock.withLock({ running }) {
            let n = Darwin.read(src, buf, bufSize)
            guard n > 0 else { return }
            var written = 0
            while written < n {
                let w = Darwin.write(dst, buf + written, n - written)
                guard w > 0 else { return }
                written += w
            }
        }
    }

    private final class PipePair: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = 0
        /// 第二个方向结束时返回 true。
        func finishOne() -> Bool { lock.withLock { finished += 1; return finished == 2 } }
    }

    // MARK: 工具

    /// Adobe 公式（ffmpeg rtmpproto.c do_adobe_auth、HaishinKit RTMPAuthenticator 同一套）。
    static func adobeResponse(user: String, password: String, salt: String, opaqueOrChallenge: String, clientChallenge: String) -> String {
        let h1 = Data(Insecure.MD5.hash(data: Data((user + salt + password).utf8))).base64EncodedString()
        return Data(Insecure.MD5.hash(data: Data((h1 + opaqueOrChallenge + clientChallenge).utf8))).base64EncodedString()
    }

    /// 查询串（不解码：客户端怎么拼的就怎么比）。同名参数取最后一个。
    static func query(_ s: String) -> [String: String] {
        guard let q = s.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for item in s[s.index(after: q)...].split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            out[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        return out
    }

    /// 服务器风格的随机串（base64，Wowza 的 salt / opaque 就长这样，可能带 + / =）。
    private static func token() -> String {
        Data((0..<6).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    static func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var t = timeval(tv_sec: 5, tv_usec: 0)          // 握手 / connect 阶段：对端 5 s 不说话就放弃
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    }

    static func read(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return out
    }

    static func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// 客户端握手之后的第一条消息：块头 fmt 0，块大小还是默认的 128（connect 之前谁都没发 SetChunkSize）。
    static func readFirstMessage(_ fd: Int32) -> (type: UInt8, payload: [UInt8], raw: [UInt8])? {
        guard let b0 = read(fd, 1), b0[0] >> 6 == 0 else { return nil }
        var raw = b0
        let csidByte = b0[0] & 0x3f
        let extraBasic = csidByte == 0 ? 1 : csidByte == 1 ? 2 : 0
        if extraBasic > 0 { guard let b = read(fd, extraBasic) else { return nil }; raw += b }
        guard let h = read(fd, 11) else { return nil }
        raw += h
        let extended = h[0] == 0xFF && h[1] == 0xFF && h[2] == 0xFF
        let length = Int(h[3]) << 16 | Int(h[4]) << 8 | Int(h[5])
        if extended { guard let e = read(fd, 4) else { return nil }; raw += e }
        var payload: [UInt8] = []
        while payload.count < length {
            if !payload.isEmpty {
                // 续块：fmt 3、同一个块流
                guard let c = read(fd, 1 + extraBasic), c[0] >> 6 == 3, c[0] & 0x3f == csidByte else { return nil }
                raw += c
                if extended { guard let e = read(fd, 4) else { return nil }; raw += e }
            }
            guard let p = read(fd, min(128, length - payload.count)) else { return nil }
            raw += p
            payload += p
        }
        return (h[6], payload, raw)
    }
}

struct GatewayError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// 网关用到的那一点 AMF0 / 分块：解 connect 命令（找 app / tcUrl 的位置）、拼 _error / _result 回复、按块大小分块。
enum AMF0 {
    struct Connect {
        var txid: Double
        var app: String
        var appRange: Range<Int>        // 含类型标记的整个值
        var tcUrl: String
        var tcUrlRange: Range<Int>
    }

    struct Reader {
        let d: [UInt8]
        var i = 0

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= d.count else { throw GatewayError("AMF0 越界") }
            defer { i += n }
            return d[i..<i + n]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u16() throws -> Int { let b = try take(2); return Int(b[b.startIndex]) << 8 | Int(b[b.startIndex + 1]) }
        mutating func u32() throws -> Int { try take(4).reduce(0) { $0 << 8 | Int($1) } }
        mutating func utf8(_ n: Int) throws -> String { String(decoding: try take(n), as: UTF8.self) }

        /// 读一个值（带类型标记）；是字符串就返回它，其他类型跳过。
        @discardableResult
        mutating func value() throws -> String? {
            switch try u8() {
            case 0x00: _ = try take(8)
            case 0x01: _ = try take(1)
            case 0x02: return try utf8(try u16())
            case 0x03: try properties()
            case 0x05, 0x06: break
            case 0x08: _ = try take(4); try properties()
            case 0x0A: for _ in 0..<(try u32()) { try value() }
            case 0x0B: _ = try take(10)
            case 0x0C: return try utf8(try u32())
            case 0x10: _ = try take(try u16()); try properties()
            case let m: throw GatewayError("AMF0 类型 \(m) 不认")
            }
            return nil
        }

        /// 对象体：(键, 值)… 直到空键 + 0x09。
        mutating func properties(_ each: ((String, Range<Int>, String?) -> Void)? = nil) throws {
            while true {
                let key = try utf8(try u16())
                if key.isEmpty, d.indices.contains(i), d[i] == 0x09 { i += 1; return }
                let start = i
                let s = try value()
                each?(key, start..<i, s)
            }
        }
    }

    static func parseConnect(_ payload: [UInt8]) throws -> Connect {
        var r = Reader(d: payload)
        guard try r.value() == "connect", try r.u8() == 0x00 else { throw GatewayError("不是 connect") }
        let txid = Double(bitPattern: UInt64(try r.take(8).reduce(0) { $0 << 8 | UInt64($1) }))
        guard try r.u8() == 0x03 else { throw GatewayError("connect 没有命令对象") }
        var app: (String, Range<Int>)?, tcUrl: (String, Range<Int>)?
        try r.properties { key, range, s in
            guard let s else { return }
            if key == "app" { app = (s, range) }
            if key == "tcUrl" { tcUrl = (s, range) }
        }
        guard let app, let tcUrl else { throw GatewayError("connect 缺 app / tcUrl") }
        return Connect(txid: txid, app: app.0, appRange: app.1, tcUrl: tcUrl.0, tcUrlRange: tcUrl.1)
    }

    static func string(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        return [0x02, UInt8(u.count >> 8 & 0xFF), UInt8(u.count & 0xFF)] + u
    }

    static func number(_ v: Double) -> [UInt8] {
        [0x00] + withUnsafeBytes(of: v.bitPattern.bigEndian) { Array($0) }
    }

    static func object(_ props: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = [0x03]
        for (k, v) in props {
            let kb = Array(k.utf8)
            out += [UInt8(kb.count >> 8 & 0xFF), UInt8(kb.count & 0xFF)] + kb + v
        }
        return out + [0x00, 0x00, 0x09]
    }

    /// connect 的拒绝：_error(txid, null, {level, code: NetConnection.Connect.Rejected, description})。
    static func connectError(txid: Double, description: String) -> [UInt8] {
        string("_error") + number(txid) + [0x05] + object([
            ("level", string("error")),
            ("code", string("NetConnection.Connect.Rejected")),
            ("description", string(description)),
        ])
    }

    /// connect 成功：_result(txid, {fmsVer, capabilities}, {level, code: NetConnection.Connect.Success, description, objectEncoding})。
    static func connectSuccess(txid: Double) -> [UInt8] {
        string("_result") + number(txid) + object([("fmsVer", string("FMS/3,0,1,123")), ("capabilities", number(31))]) + object([
            ("level", string("status")),
            ("code", string("NetConnection.Connect.Success")),
            ("description", string("Connection succeeded.")),
            ("objectEncoding", number(0)),
        ])
    }

    /// 自己回话之前的协议控制消息（块流 2、消息流 0）：Window Ack Size 2500000、Set Peer Bandwidth 2500000（dynamic）、Set Chunk Size 4096。
    static let serverChunkSize = 4096
    static let serverPreamble: [UInt8] = {
        func control(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
            [0x02, 0, 0, 0, 0, 0, UInt8(body.count), type, 0, 0, 0, 0] + body
        }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return control(5, be32(2_500_000)) + control(6, be32(2_500_000) + [2]) + control(1, be32(UInt32(serverChunkSize)))
    }()

    /// 把若干个值（按范围）换成新的字符串值，范围可以是任意顺序。
    static func replacing(_ payload: [UInt8], _ edits: [(Range<Int>, String)]) -> [UInt8] {
        var out = payload
        for (range, s) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { out.replaceSubrange(range, with: string(s)) }
        return out
    }

    /// 一条命令消息（类型 20、消息流 0、块流 3、时间戳 0）按块大小分块。
    static func chunks(payload: [UInt8], chunkSize: Int) -> [UInt8] {
        var out: [UInt8] = [0x03, 0, 0, 0, UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF), 20, 0, 0, 0, 0]
        var i = 0
        while i < payload.count {
            if i > 0 { out.append(0xC3) }
            let n = min(chunkSize, payload.count - i)
            out += payload[i..<i + n]
            i += n
        }
        return out
    }
}
