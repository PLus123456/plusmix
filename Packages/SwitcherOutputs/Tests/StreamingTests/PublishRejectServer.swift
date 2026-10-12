import Darwin
import Foundation

/// 测试用的最小 RTMP 服务器（W2-D4）：connect / createStream 照回成功，收到 publish 之后等 `publishReplyDelay` 秒再回一条 onStatus
/// （默认 level error、NetStream.Publish.Unauthorized、"authentication failed"——MediaMTX 1.21 查询串账号不对时回的就是这三样），然后断开。
/// 为什么要它：MediaMTX 鉴权失败先随机等 0–4 s 才回（防暴力猜，internal/auth/log_and_delay_error.go），HaishinKit 的 publish 请求 3 s 就超时；
/// "回复比 3 s 晚"这条路在 MediaMTX 上只有约四分之一的概率碰上，这里把它变成确定的。
/// 与 SwitcherStreaming 不共享代码：收方向自己解块（fmt 0–3、扩展时间戳、客户端的 Set Chunk Size），AMF0 的小工具用 AdobeAuthGateway 那份。
final class PublishRejectServer: @unchecked Sendable {
    let port: Int
    let publishReplyDelay: TimeInterval
    let code: String
    let level: String
    let replyDescription: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var running = true             // lock
    private var open: Set<Int32> = []      // lock；关 fd 也在锁里
    private var connections = 0            // lock
    private var publishes = 0              // lock

    init(port: Int, publishReplyDelay: TimeInterval, code: String = "NetStream.Publish.Unauthorized", level: String = "error",
         description: String = "authentication failed") throws {
        self.port = port
        self.publishReplyDelay = publishReplyDelay
        self.code = code
        self.level = level
        replyDescription = description
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw GatewayError("socket") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); throw GatewayError("bind/listen \(port): errno \(errno)") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "publish-reject-server.accept.\(port)"
        t.start()
    }

    /// 到目前为止的 TCP 连接数 / 收到的 publish 数。
    var connectionCount: Int { lock.withLock { connections } }
    var publishCount: Int { lock.withLock { publishes } }

    func stop() {
        lock.withLock {
            running = false
            for fd in open { shutdown(fd, SHUT_RDWR) }
        }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func acceptLoop() {
        while lock.withLock({ running }) {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { break }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var t = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
            lock.withLock { open.insert(client); connections += 1 }
            let th = Thread { [weak self] in self?.handle(client) }
            th.name = "publish-reject-server.conn"
            th.start()
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            lock.withLock {
                open.remove(fd)
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
        }
        // 握手：C0C1 → S0S1S2 一次写完（HaishinKit 等 S2 的头几个字节到了才发 C2）→ C2
        guard let c0c1 = Self.read(fd, 1537), c0c1[0] == 3 else { return }
        var s = [UInt8](repeating: 0, count: 3073)
        s[0] = 3
        s.replaceSubrange(1537..<3073, with: c0c1[1...1536])
        guard Self.write(fd, s), Self.read(fd, 1536) != nil else { return }
        var reader = ChunkReader()
        while let m = reader.next(fd) {
            switch m.type {
            case 1 where m.payload.count >= 4:   // Set Chunk Size（客户端 → 我们）
                reader.chunkSize = max(1, Int(UInt32(m.payload[0]) << 24 | UInt32(m.payload[1]) << 16 | UInt32(m.payload[2]) << 8 | UInt32(m.payload[3])) & 0x7FFF_FFFF)
            case 20:
                var r = AMF0.Reader(d: m.payload)
                guard let name = try? r.value(), (try? r.u8()) == 0x00, let tx = try? r.take(8) else { continue }
                let txid = Double(bitPattern: tx.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                switch name {
                case "connect":
                    _ = Self.write(fd, AMF0.serverPreamble + AMF0.chunks(payload: AMF0.connectSuccess(txid: txid), chunkSize: AMF0.serverChunkSize))
                case "createStream":
                    let reply = AMF0.string("_result") + AMF0.number(txid) + [0x05] + AMF0.number(1)
                    _ = Self.write(fd, AMF0.chunks(payload: reply, chunkSize: AMF0.serverChunkSize))
                case "publish":
                    lock.withLock { publishes += 1 }
                    Thread.sleep(forTimeInterval: publishReplyDelay)
                    let status = AMF0.string("onStatus") + AMF0.number(0) + [0x05] + AMF0.object([
                        ("level", AMF0.string(level)), ("code", AMF0.string(code)), ("description", AMF0.string(replyDescription)),
                    ])
                    _ = Self.write(fd, Self.commandMessage(csid: 5, streamId: m.streamId, payload: status))
                    Thread.sleep(forTimeInterval: 0.3)   // 跟 MediaMTX 一样：回完就断
                    return
                default:
                    continue   // releaseStream / FCPublish / @setDataFrame……不回
                }
            default:
                continue
            }
        }
    }

    /// 一条命令消息（类型 20、时间戳 0、块头 fmt 0），消息流 = streamId（小端）；载荷不超过我们宣布的块大小 4096，不用分块。
    private static func commandMessage(csid: UInt8, streamId: UInt32, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= AMF0.serverChunkSize)
        return [csid, 0, 0, 0, UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF), 20,
                UInt8(streamId & 0xFF), UInt8(streamId >> 8 & 0xFF), UInt8(streamId >> 16 & 0xFF), UInt8(streamId >> 24 & 0xFF)] + payload
    }

    /// 收方向的分块：每个块流记上一个块头（fmt 1–3 沿用），扩展时间戳跳过，消息按块大小拼齐。
    private struct ChunkReader {
        struct Header {
            var length = 0
            var type: UInt8 = 0
            var streamId: UInt32 = 0
            var extended = false
        }
        var chunkSize = 128
        private var headers: [Int: Header] = [:]
        private var partial: [Int: [UInt8]] = [:]

        mutating func next(_ fd: Int32) -> (type: UInt8, streamId: UInt32, payload: [UInt8])? {
            while true {
                guard let b = PublishRejectServer.read(fd, 1) else { return nil }
                let fmt = b[0] >> 6
                var csid = Int(b[0] & 0x3F)
                if csid == 0 {
                    guard let x = PublishRejectServer.read(fd, 1) else { return nil }
                    csid = 64 + Int(x[0])
                } else if csid == 1 {
                    guard let x = PublishRejectServer.read(fd, 2) else { return nil }
                    csid = 64 + Int(x[0]) + Int(x[1]) * 256
                }
                var h = headers[csid] ?? Header()
                switch fmt {
                case 0:
                    guard let m = PublishRejectServer.read(fd, 11) else { return nil }
                    h = Header(length: Int(m[3]) << 16 | Int(m[4]) << 8 | Int(m[5]), type: m[6],
                               streamId: UInt32(m[7]) | UInt32(m[8]) << 8 | UInt32(m[9]) << 16 | UInt32(m[10]) << 24,
                               extended: m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF)
                case 1:
                    guard let m = PublishRejectServer.read(fd, 7) else { return nil }
                    h.length = Int(m[3]) << 16 | Int(m[4]) << 8 | Int(m[5])
                    h.type = m[6]
                    h.extended = m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF
                case 2:
                    guard let m = PublishRejectServer.read(fd, 3) else { return nil }
                    h.extended = m[0] == 0xFF && m[1] == 0xFF && m[2] == 0xFF
                default:
                    break
                }
                if h.extended { guard PublishRejectServer.read(fd, 4) != nil else { return nil } }
                headers[csid] = h
                var body = partial[csid] ?? []
                let n = min(chunkSize, h.length - body.count)
                if n > 0 {
                    guard let p = PublishRejectServer.read(fd, n) else { return nil }
                    body += p
                }
                if body.count >= h.length {
                    partial[csid] = nil
                    return (h.type, h.streamId, body)
                }
                partial[csid] = body
            }
        }
    }

    fileprivate static func read(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return out
    }

    private static func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }
}
