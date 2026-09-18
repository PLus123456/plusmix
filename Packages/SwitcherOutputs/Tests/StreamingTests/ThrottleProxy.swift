import Darwin
import Foundation
import Synchronization

/// 用户态 TCP 代理（BSD socket + 线程）：把 127.0.0.1:listenPort 转发到 127.0.0.1:targetPort，可限速、可"封"。
/// 没有 sudo 时代替 dummynet 跑 E7 / E8 / E9：
/// - `rateBytesPerSecond`：客户端 → 服务器方向按令牌桶限速（服务器回来的 ACK / 响应不限）；
/// - `blocked = true`：两个方向都不转发也不断开（像端口被黑洞：TCP 发送缓冲填满、无响应）；新连接被内核接受但代理不理它。
///   `blocked = false` 时把封住期间的旧连接全部关掉（旧连接已被 StreamOutput 判死并重连）。
/// 与真 dummynet 的差别：黑洞时新连接的三次握手仍会完成（内核 accept backlog），RTMP 握手超时由 StreamOutput 的连接超时兜住。
final class ThrottleProxy: @unchecked Sendable {
    let listenPort: Int
    let targetPort: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var connections: [(Int32, Int32)] = []
    private var running = true
    private var rate: Int?
    private var isBlocked = false
    private var acceptThread: Thread?
    private(set) var bytesForwarded: Int = 0      // lock
    private(set) var accepted: Int = 0            // lock

    init(listenPort: Int, targetPort: Int) throws {
        self.listenPort = listenPort
        self.targetPort = targetPort
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw TestFailure("socket") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(listenPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); throw TestFailure("bind/listen \(listenPort): errno \(errno)") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "throttle-proxy.accept.\(listenPort)"
        acceptThread = t
        t.start()
    }

    var rateBytesPerSecond: Int? {
        get { lock.withLock { rate } }
        set { lock.withLock { rate = newValue } }
    }

    var blocked: Bool {
        get { lock.withLock { isBlocked } }
        set {
            let toClose: [(Int32, Int32)] = lock.withLock {
                isBlocked = newValue
                guard !newValue else { return [] }
                let c = connections
                connections.removeAll()
                return c
            }
            for (a, b) in toClose { shutdown(a, SHUT_RDWR); shutdown(b, SHUT_RDWR) }
        }
    }

    func stop() {
        let toClose: [(Int32, Int32)] = lock.withLock {
            running = false
            let c = connections
            connections.removeAll()
            return c
        }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        for (a, b) in toClose { shutdown(a, SHUT_RDWR); shutdown(b, SHUT_RDWR) }
    }

    private func acceptLoop() {
        while lock.withLock({ running }) {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { break }
            let server = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(targetPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard ok == 0 else { close(client); close(server); continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { connections.append((client, server)); accepted += 1 }
            let up = Thread { [weak self] in self?.forward(from: client, to: server, paced: true) }
            let down = Thread { [weak self] in self?.forward(from: server, to: client, paced: false) }
            up.name = "throttle-proxy.up"
            down.name = "throttle-proxy.down"
            up.start()
            down.start()
        }
    }

    private func forward(from src: Int32, to dst: Int32, paced: Bool) {
        let bufSize = 16 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate(); shutdown(dst, SHUT_WR) }
        var tokens = 0.0
        var lastRefill = Date()
        while true {
            while lock.withLock({ isBlocked && running }) { Thread.sleep(forTimeInterval: 0.02) }
            guard lock.withLock({ running }) else { return }
            let n = read(src, buf, bufSize)
            guard n > 0 else { return }
            if paced, let r = lock.withLock({ rate }) {
                // 令牌桶：容量 = 0.25 s 的量
                let now = Date()
                tokens = min(Double(r) * 0.25, tokens + now.timeIntervalSince(lastRefill) * Double(r))
                lastRefill = now
                if tokens < Double(n) {
                    let wait = (Double(n) - tokens) / Double(r)
                    Thread.sleep(forTimeInterval: wait)
                    tokens = 0
                    lastRefill = now.addingTimeInterval(wait)   // 睡掉的时间已经"付"过了；多睡的部分下一轮照常记入
                } else {
                    tokens -= Double(n)
                }
            }
            var written = 0
            while written < n {
                let w = write(dst, buf + written, n - written)
                guard w > 0 else { return }
                written += w
            }
            lock.withLock { bytesForwarded += n }
        }
    }
}
