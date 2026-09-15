import Darwin
import Foundation
import XCTest
@testable import SwitcherStreaming

/// 用户态代理自身的行为（它是 E7 / E8 / E9 无 sudo 版的地基）。
final class ThrottleProxyTests: XCTestCase {
    /// 本地"黑洞服务器"：accept 后只读不回。
    private func makeSink(port: Int) -> (Int32, Thread) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        let t = Thread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                Thread {
                    let buf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
                    defer { buf.deallocate(); close(c) }
                    while read(c, buf, 65536) > 0 {}
                }.start()
            }
        }
        t.start()
        return (fd, t)
    }

    private func connectTo(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(r, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 限速 500 KB/s 送 4 MB：应当用 7–10 s（不限速时 < 1 s）。
    func testRateLimitPaces() throws {
        let (sinkFD, _) = makeSink(port: 41001)
        defer { close(sinkFD) }
        let proxy = try ThrottleProxy(listenPort: 41002, targetPort: 41001)
        defer { proxy.stop() }
        proxy.rateBytesPerSecond = 500_000
        let fd = connectTo(port: 41002)
        defer { close(fd) }
        let chunk = [UInt8](repeating: 0x47, count: 65536)
        let t0 = Date()
        var sent = 0
        while sent < 4_000_000 {
            let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            XCTAssertGreaterThan(n, 0)
            sent += n
        }
        // 等代理转发完
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, proxy.bytesForwarded < sent { Thread.sleep(forTimeInterval: 0.05) }
        let elapsed = Date().timeIntervalSince(t0)
        print("限速：\(sent) 字节用了 \(String(format: "%.2f", elapsed)) s（≈ \(Int(Double(sent) / elapsed / 1000)) KB/s）")
        XCTAssertEqual(proxy.bytesForwarded, sent)
        XCTAssertGreaterThan(elapsed, 6.5)
        XCTAssertLessThan(elapsed, 11)
    }

    /// 封住：写端很快被 TCP 流控堵住（发送缓冲填满后 write 阻塞或不再前进）；放开后旧连接被关掉。
    func testBlockStopsForwardingAndCloses() throws {
        let (sinkFD, _) = makeSink(port: 41003)
        defer { close(sinkFD) }
        let proxy = try ThrottleProxy(listenPort: 41004, targetPort: 41003)
        defer { proxy.stop() }
        let fd = connectTo(port: 41004)
        defer { close(fd) }
        var flags = fcntl(fd, F_GETFL)
        flags |= O_NONBLOCK
        fcntl(fd, F_SETFL, flags)
        let chunk = [UInt8](repeating: 0x47, count: 65536)
        proxy.blocked = true
        var accepted = 0
        var wouldBlock = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { accepted += n } else if errno == EAGAIN { wouldBlock = true; break } else { break }
        }
        XCTAssertTrue(wouldBlock, "封住后发送缓冲应当填满（已接受 \(accepted) 字节）")
        XCTAssertEqual(proxy.bytesForwarded, 0)
        proxy.blocked = false
        Thread.sleep(forTimeInterval: 0.3)
        // 旧连接被关：再写会失败（EPIPE / ECONNRESET）
        var failed = false
        for _ in 0..<50 {
            let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno != EAGAIN { failed = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(failed, "放开后旧连接应当已被代理关掉")
    }
}
