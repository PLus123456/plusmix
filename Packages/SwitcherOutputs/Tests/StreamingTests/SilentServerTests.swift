import Foundation
import XCTest
import SwitcherContracts
import SwitcherOutputs
@testable import SwitcherStreaming

/// W2-D6（prompt 138，问题单 W2D5-w2-stream-connect-hangs-on-silent-server）：对端接受了 TCP、但一个字节都不回
/// （只 listen 不 accept 的端口——内核替它完成三次握手；现实里是"接 TCP 等对方先说话"的服务、替死后端接连接的负载均衡 / 防火墙）。
/// 修前（macOS 27 / HaishinKit 2.2.5）：HaishinKit 的 connect 握手没有超时、不理取消，RTMPS 在 TLS 阶段连它的 close() 都不起作用
/// （抛 invalidState，要等它写死的 15 s socket 超时）；我们的 withTimeout 任务组陪着挂 → StreamOutput 一直 connecting(1)、
/// last_error 空、stop() 永远回不来。
///
/// 每条都带看门狗：挂住（回归）的操作放在 detached Task / 后台线程里、有限时等，超时用例红，不陪着挂。
/// 跑完查 `ps -axo pid,etime,comm | awk '$3 ~ /xctest/'` 没有孤儿（swift test 外面再套 `perl -e 'alarm N; exec @ARGV'`）。
/// 端口 19501–19506（StreamingTests 别处已占 19466–19497）。
final class SilentServerTests: XCTestCase {
    private var outputs: [StreamOutput] = []

    override func tearDown() {
        // 修前 stop() 会永远挂住：tearDown 也只在后台线程有限时等，别把整个进程拖住
        for o in outputs where o.isRunning { _ = stopWithWatchdog(o, limit: 3) }
        outputs = []
    }

    // MARK: ① 传输层

    /// ① RTMP：套 StreamOutput 同款 withTimeout（超时先取消 connect、再 close 传输层），3 s 连接超时在 4 s 内报"连接超时（服务器没回）"；
    /// 只靠取消（不给 onTimeout）也一样——RTMPTransport 自己理取消。关掉之后 HaishinKit 那一次 connect 立刻返回、对端那条 TCP 连接已关。
    func testW2D6_rtmpTransport_silentServer_connectTimesOutWithinTimeoutPlusOne() throws {
        let server = try SilentServer(port: 19501)
        defer { server.close() }
        try assertTransportTimesOut(url: "rtmp://127.0.0.1:19501/live/k", unwindLimit: 2)
        XCTAssertEqual(server.openConnections(), 0, "对端那几条 TCP 连接都应当已经关了（没有泄漏的连接）")
    }

    /// ① RTMPS 连同一种端口（不另搭 TLS：ClientHello 发出去没人回，TLS 握手挂着）：同样 4 s 内报连接超时。
    /// HaishinKit 那一次 connect 在 TLS 阶段关不掉，被放手、交给后台每 0.2 s 关一次，等它自己 15 s 的 socket 超时返回（pendingHaishinKitConnects 回 0）。
    func testW2D6_rtmpsTransport_silentServer_connectTimesOutWithinTimeoutPlusOne() throws {
        let server = try SilentServer(port: 19502)
        defer { server.close() }
        try assertTransportTimesOut(url: "rtmps://127.0.0.1:19502/live/k", unwindLimit: 17)
        XCTAssertEqual(server.openConnections(), 0, "HaishinKit 15 s 超时之后对端那几条 TCP 连接都应当已经关了")
    }

    /// ④（stop 的传输层那一半）：connect 进行中另一个 Task 调 close()——RTMP / RTMPS、socket 起来之前（0 s）/ 握手挂着（1 s）——
    /// close 和 connect 都在 0.5 s 内返回。修前：RTMP 0 s 时 HaishinKit 的 close 落在 socket 起来之前不起作用（探针：永远挂），RTMPS 两种都要 15 s。
    func testW2D6_rtmpTransport_closeDuringConnect_bothReturnPromptly() throws {
        let server = try SilentServer(port: 19506)
        defer { server.close() }
        for scheme in ["rtmp", "rtmps"] {
            for delay in [0.0, 1.0] {
                let label = "\(scheme) close@\(delay)s"
                let t = try Self.transport("\(scheme)://127.0.0.1:19506/live/k", connectTimeout: 5)
                let connectDone = DispatchSemaphore(value: 0)
                let connectEnd = LockedBox<HostTime>()
                let connectError = LockedBox<String>()
                Task.detached {
                    do { try await t.connect(); connectError.set("连上了") } catch { connectError.set("\(error)") }
                    connectEnd.set(HostClock.now())
                    connectDone.signal()
                }
                Thread.sleep(forTimeInterval: delay)
                let closeStart = HostClock.now()
                guard let closeSeconds = runAsync(limit: 5, { () -> Double in await t.close(); return (HostClock.now() - closeStart).seconds }) else {
                    XCTFail("\(label)：close() 5 s 没返回"); continue
                }
                XCTAssertLessThan(closeSeconds, 0.5, "\(label)：close() 用时")
                guard connectDone.wait(timeout: .now() + 5) == .success, let end = connectEnd.value else {
                    XCTFail("\(label)：close() 之后 connect 5 s 还没返回"); continue
                }
                let after = (end - closeStart).seconds
                print("W2D6 \(label)：close \(String(format: "%.3f", closeSeconds)) s，connect 在 close 之后 \(String(format: "%.3f", after)) s 返回：\(connectError.value ?? "")")
                XCTAssertLessThan(after, 0.5, "\(label)：connect 在 close() 之后的返回用时")
                XCTAssertNotEqual(connectError.value, "连上了", label)
            }
        }
        XCTAssertTrue(waitUntil(timeout: 17) { RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed) == 0 },
                      "被放手的 HaishinKit connect 应当在它 15 s 的 socket 超时内都收完：还剩 \(RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed))")
        XCTAssertEqual(server.openConnections(), 0, "对端那几条 TCP 连接都应当已经关了")
    }

    // MARK: ② StreamOutput 进退避

    /// ② 生产路径（真编码器 + HaishinKit）：3 s 连接超时后 state 从 connecting(1) 进 backoff(1, 1 s)、last_error = "连接失败：连接超时（服务器没回）"；
    /// 1 s 后第 2 次连接、再超时进 backoff(2, 2 s)——按退避重试，不再一直"连接中"。
    func testW2D6_streamOutput_silentServer_backsOffWithChineseLastError() throws {
        let server = try SilentServer(port: 19503)
        defer { server.close() }
        let scene = try StreamScene()
        let o = try scene.makeOutput(name: "w2d6-backoff", url: "rtmp://127.0.0.1:19503/live/k", connectTimeout: 3)
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 1) { o.state == .connecting(attempt: 1) }, "\(o.state)")
        XCTAssertTrue(waitUntil(timeout: 4) { if case .backoff(attempt: 1, _) = o.state { return true }; return false },
                      "3 s 连接超时之后应当进退避：现在 \(o.state)，last_error = \(o.statsEntry(previous: nil, windowSeconds: 1).lastError)")
        XCTAssertEqual(o.statsEntry(previous: nil, windowSeconds: 1).lastError, "连接失败：连接超时（服务器没回）")
        XCTAssertTrue(waitUntil(timeout: 2) { o.counters.connectAttempts >= 2 }, "退避 1 s 之后应当第 2 次连接：\(o.counters.connectAttempts)，\(o.state)")
        XCTAssertTrue(waitUntil(timeout: 4.5) { if case .backoff(attempt: 2, _) = o.state { return true }; return false }, "第 2 次也超时、进 backoff(2)：\(o.state)")
        let c = o.counters
        XCTAssertEqual(c.connectAttempts, 2)
        XCTAssertEqual(c.reconnects, 0, "一次都没连上")
        XCTAssertEqual(o.statsEntry(previous: nil, windowSeconds: 1).lastError, "连接失败：连接超时（服务器没回）")
        guard let stopSeconds = stopWithWatchdog(o, limit: 5) else { return XCTFail("退避中 stop() 5 s 没返回") }
        XCTAssertLessThan(stopSeconds, 2)
        XCTAssertEqual(o.state, .stopped)
        XCTAssertTrue(waitUntil(timeout: 2) { RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed) == 0 })
        XCTAssertEqual(server.openConnections(), 0, "两次连接都应当已经关了")
    }

    // MARK: ③ connecting 期间 stop

    /// ③ RTMP（App 不用、headless / 测试用的同步 stop()）：握手挂着时 stop() 2 s 内返回、state = stopped、last_error 空（停不是错误）、
    /// 没有残留：HaishinKit 那一次 connect 已返回、对端那条 TCP 连接已关。
    func testW2D6_streamOutput_stopWhileConnecting_rtmp_returnsWithin2s() throws {
        try assertStopWhileConnecting(port: 19504, scheme: "rtmp", useAsync: false, unwindLimit: 2)
    }

    /// ③ RTMPS（App 的 stopAsync()）：TLS 握手挂着时同样 2 s 内返回；HaishinKit 那一次 connect 在后台等它自己 15 s 的超时收尾。
    func testW2D6_streamOutput_stopAsyncWhileConnecting_rtmps_returnsWithin2s() throws {
        try assertStopWhileConnecting(port: 19505, scheme: "rtmps", useAsync: true, unwindLimit: 17)
    }

    // MARK: 共用

    private func assertTransportTimesOut(url: String, unwindLimit: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        for useOnTimeout in [true, false] {
            let label = useOnTimeout ? "withTimeout(3 s, onTimeout: close)" : "withTimeout(3 s)（只靠取消）"
            let t = try Self.transport(url, connectTimeout: 3)
            let r = runAsync(limit: 12) { () -> ConnectOutcome in
                let t0 = HostClock.now()
                do {
                    if useOnTimeout {
                        try await withTimeout(seconds: 3, onTimeout: { await t.close() }) { try await t.connect() }
                    } else {
                        try await withTimeout(seconds: 3) { try await t.connect() }
                    }
                    return ConnectOutcome(error: "连上了", typed: nil, seconds: (HostClock.now() - t0).seconds)
                } catch {
                    return ConnectOutcome(error: "\(error)", typed: error as? StreamTransportError, seconds: (HostClock.now() - t0).seconds)
                }
            }
            guard let r else {
                XCTFail("\(url) \(label)：12 s 没返回（HaishinKit 的 connect 挂住、任务组陪着等）", file: file, line: line)
                continue
            }
            print("W2D6 \(url) \(label)：\(String(format: "%.2f", r.seconds)) s → \(r.error)")
            XCTAssertEqual(r.typed, .connectTimedOut, "\(url) \(label)", file: file, line: line)
            XCTAssertEqual(r.error, "连接超时（服务器没回）", "\(url) \(label)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(r.seconds, 2.9, "\(url) \(label)", file: file, line: line)
            XCTAssertLessThan(r.seconds, 4.0, "\(url) \(label)：连接超时 + 1 s 内", file: file, line: line)
            let closed: Bool? = runAsync(limit: 3) { await t.close(); return true }
            XCTAssertEqual(closed, true, "\(url) \(label)：超时之后再 close() 3 s 没返回", file: file, line: line)
        }
        XCTAssertTrue(waitUntil(timeout: unwindLimit) { RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed) == 0 },
                      "\(url)：HaishinKit 那一次 connect 应当在 \(unwindLimit) s 内收完：还剩 \(RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed))",
                      file: file, line: line)
    }

    private func assertStopWhileConnecting(port: Int, scheme: String, useAsync: Bool, unwindLimit: Double,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let server = try SilentServer(port: port)
        defer { server.close() }
        let scene = try StreamScene()
        // 连接超时 5 s：stop 落在握手挂着的那段，而不是超时之后的退避里
        let o = try scene.makeOutput(name: "w2d6-stop-\(scheme)", url: "\(scheme)://127.0.0.1:\(port)/live/k", connectTimeout: 5)
        outputs = [o]
        try o.start()
        XCTAssertTrue(waitUntil(timeout: 1) { o.state == .connecting(attempt: 1) }, "\(o.state)", file: file, line: line)
        Thread.sleep(forTimeInterval: 1.5)   // TCP 早连上了，握手 / TLS 挂着
        XCTAssertEqual(o.state, .connecting(attempt: 1), file: file, line: line)
        let stopSeconds: Double?
        if useAsync {
            let start = HostClock.now()
            stopSeconds = runAsync(limit: 8) { () -> Double in await o.stopAsync(); return (HostClock.now() - start).seconds }
        } else {
            stopSeconds = stopWithWatchdog(o, limit: 8)
        }
        guard let stopSeconds else {
            return XCTFail("connecting 期间 \(useAsync ? "stopAsync()" : "stop()") 8 s 没返回：state = \(o.state)", file: file, line: line)
        }
        print("W2D6 \(scheme) connecting 期间 \(useAsync ? "stopAsync()" : "stop()")：\(String(format: "%.3f", stopSeconds)) s")
        XCTAssertLessThan(stopSeconds, 2, "stop 用时", file: file, line: line)
        XCTAssertEqual(o.state, .stopped, file: file, line: line)
        XCTAssertFalse(o.isRunning, file: file, line: line)
        XCTAssertEqual(o.statsEntry(previous: nil, windowSeconds: 1).lastError, "", "停不是错误：last_error 不写", file: file, line: line)
        XCTAssertEqual(o.counters.connectAttempts, 1, file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: unwindLimit) { RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed) == 0 },
                      "HaishinKit 那一次 connect 应当在 \(unwindLimit) s 内收完：还剩 \(RTMPTransport.pendingHaishinKitConnects.load(ordering: .relaxed))",
                      file: file, line: line)
        XCTAssertEqual(server.openConnections(), 0, "对端那条 TCP 连接应当已经关了（没有泄漏的连接）", file: file, line: line)
    }

    private struct ConnectOutcome: Sendable {
        var error: String
        var typed: StreamTransportError?
        var seconds: Double
    }

    static func transport(_ url: String, connectTimeout: Int) throws -> any StreamTransport {
        try HaishinKitTransportFactory(format: .hd1080p60, video: VideoEncodeSettings(), connectTimeoutSeconds: connectTimeout)
            .makeTransport(for: StreamDestination(settings: StreamSettings(url: url)), audioFormat: nil)
    }
}

// MARK: - 工装

/// 只 listen、从不 accept 也不回字节的 TCP 端口：内核替它完成三次握手，客户端看来"连上了、服务器不说话"（W2-D5 的探针）。
final class SilentServer {
    let port: Int
    private var fd: Int32

    struct BindFailed: Error, CustomStringConvertible {
        let port: Int, errno: Int32
        var description: String { "端口 \(port) 绑不上（errno \(errno)：\(String(cString: strerror(errno)))）——同机别的会话在用？" }
    }

    init(port: Int) throws {
        self.port = port
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = AdobeAuthGateway.loopback(port: port)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw BindFailed(port: port, errno: e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)   // openConnections 接排队的连接时不阻塞
    }

    /// 把排队的连接接出来，数还开着的：读到 EOF / 被重置 = 客户端关了；读 readTimeout 秒没动静 = 还开着（泄漏）。
    /// 客户端在排队时就关掉的连接，内核可能直接从队列里拿掉（accept 不到），不影响"还开着几条"。
    func openConnections(readTimeout: Double = 0.3) -> Int {
        var open = 0
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { break }   // EAGAIN：接完了
            defer { Darwin.close(c) }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)   // BSD 上接出来的连接继承 O_NONBLOCK：改回阻塞、按 SO_RCVTIMEO 等
            var tv = timeval(tv_sec: 0, tv_usec: Int32(readTimeout * 1_000_000))
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(c, &buf, buf.count)
                if n > 0 { continue }                 // 客户端先发的 C0C1 / TLS ClientHello
                if n == 0 || errno == ECONNRESET { break }
                open += 1                             // EAGAIN：超时，还开着
                break
            }
        }
        return open
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }
}

/// 跨线程交一个值（看门狗用）。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ v: T) { lock.withLock { stored = v } }
}

/// 看门狗：op 放在 detached Task 里跑，最多等 limit 秒。挂住（回归）→ 返回 nil、用例红，而不是陪着挂。
func runAsync<T: Sendable>(limit: Double, _ op: @escaping @Sendable () async -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    let box = LockedBox<T>()
    Task.detached {
        box.set(await op())
        done.signal()
    }
    guard done.wait(timeout: .now() + limit) == .success else { return nil }
    return box.value
}

/// 看门狗版 stop()：后台线程调，最多等 limit 秒；返回 stop() 用时，挂住返回 nil。
func stopWithWatchdog(_ o: StreamOutput, limit: Double) -> Double? {
    let done = DispatchSemaphore(value: 0)
    let seconds = LockedBox<Double>()
    DispatchQueue.global().async {
        let t0 = HostClock.now()
        o.stop()
        seconds.set((HostClock.now() - t0).seconds)
        done.signal()
    }
    guard done.wait(timeout: .now() + limit) == .success else { return nil }
    return seconds.value
}
