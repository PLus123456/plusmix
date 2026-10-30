import Darwin
import Foundation

/// 测试用的恶意 RTMP 服务器（NS04：Codex 10-24 审计 [4] 的 C06-server.py 改写，reports/codex-network-security-audit-20261024-probes/）。
/// 每条连接照常握手（S0S1S2 一次写完）、读完客户端的 connect，然后回 Window Ack Size / Set Peer Bandwidth / Set Chunk Size 4096
/// + 一条 `reply(txid)` 给的命令消息（按 4096 分块），再等客户端关。不验鉴权：第几轮、带不带 authmod 都回同一条。
/// 握手 / 读 connect / 分块用 AdobeAuthGateway 那几个小工具，与 SwitcherStreaming 不共享代码。
final class HostileRTMPServer: @unchecked Sendable {
    let port: Int
    private let reply: @Sendable (Double) -> [UInt8]
    private let listenFD: Int32
    private let lock = NSLock()
    private var running = true            // lock
    private var open: Set<Int32> = []     // lock；关 fd 也在锁里
    private var apps: [String] = []       // lock；每条连接的 connect 里的 app（读到了才记）

    init(port: Int, reply: @escaping @Sendable (Double) -> [UInt8]) throws {
        self.port = port
        self.reply = reply
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw GatewayError("socket") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = AdobeAuthGateway.loopback(port: port)
        let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); throw GatewayError("bind/listen \(port): errno \(errno)") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "hostile-rtmp-server.accept.\(port)"
        t.start()
    }

    /// 读到了 connect 的连接（按时间）：connect 里的 app。
    var connectApps: [String] { lock.withLock { apps } }

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
            AdobeAuthGateway.configure(client)
            lock.withLock { _ = open.insert(client) }
            let t = Thread { [weak self] in self?.handle(client) }
            t.name = "hostile-rtmp-server.conn"
            t.start()
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
        guard let c0c1 = AdobeAuthGateway.read(fd, 1537), c0c1[0] == 3 else { return }
        var s = [UInt8](repeating: 0, count: 3073)
        s[0] = 3
        s.replaceSubrange(1537..<3073, with: c0c1[1...1536])
        guard AdobeAuthGateway.write(fd, s), AdobeAuthGateway.read(fd, 1536) != nil,
              let first = AdobeAuthGateway.readFirstMessage(fd), first.type == 20, let cmd = try? AMF0.parseConnect(first.payload) else { return }
        lock.withLock { apps.append(cmd.app) }
        _ = AdobeAuthGateway.write(fd, AMF0.serverPreamble + AMF0.chunks(payload: reply(cmd.txid), chunkSize: AMF0.serverChunkSize))
        while AdobeAuthGateway.read(fd, 1) != nil {}      // 等客户端关（读超时 5 s）
    }

    // MARK: 回复

    /// `depth` 层单元素严格数组（0x0A 00 00 00 01）套一个 null：C06 的写法，每层 5 字节，10 万层约 500 KB。
    static func nestedStrictArrays(depth: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(depth * 5 + 1)
        for _ in 0..<depth { out += [0x0A, 0, 0, 0, 1] }
        return out + [0x05]
    }

    /// `depth` 层单键对象（{"k": {"k": …}}）套一个 null。
    static func nestedObjects(depth: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(depth * 7 + 1)
        for _ in 0..<depth { out += [0x03, 0x00, 0x01, UInt8(ascii: "k")] }
        out.append(0x05)
        for _ in 0..<depth { out += [0x00, 0x00, 0x09] }
        return out
    }

    /// `_result`(txid, null, <嵌套>)：嵌套放在第四个值（状态对象的位置）——HaishinKit 的命令解析第三个值按 AMFObject 读、不是对象就整条丢掉，
    /// 第四个值才走它通用的递归；RTMPAdobeAuth 的最小客户端两个位置都递归。
    static func deepResult(depth: Int) -> @Sendable (Double) -> [UInt8] {
        let nested = nestedStrictArrays(depth: depth)
        return { txid in AMF0.string("_result") + AMF0.number(txid) + [0x05] + nested }
    }
}
