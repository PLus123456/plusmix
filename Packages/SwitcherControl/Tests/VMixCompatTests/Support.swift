import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
import SwitcherControl
@testable import VMixCompat

/// 测试公用状态：4 路合成源 + 录制 / 推流输出，与 SwitcherControlTests.TestStates.base 同形（PGM 1、PVW 2）。
enum TestStates {
    static func base(inputs: Int = 4) -> MixerState {
        var s = MixerState(format: .hd1080p60)
        s.inputs = (1...inputs).map { InputConfig(number: $0, name: "机位 \($0)", source: .synthetic(settings: SyntheticSourceSettings())) }
        s.outputs = [
            OutputState(number: 1, kind: .record, name: "录制", settings: OutputSettings(record: RecordSettings(directory: "/tmp"))),
            OutputState(number: 2, kind: .stream, name: "推流", settings: OutputSettings(stream: StreamSettings(url: "rtmp://x/y"))),
        ]
        s.program = 1
        s.preview = 2
        return s
    }
}

/// 起好的一整套：状态机 + 总线 + 推送源 + 兼容层（端口 0）+ 可选的拍推进器。
struct CompatFixture {
    let stateMachine: StateMachine
    let bus: CommandBus
    let feed: StateFeed
    let server: VMixCompatServer
    let clock: TickClockSpec
    let ticker: TickDriver?

    static func start(state: MixerState = TestStates.base(), ticking: Bool = false,
                      configure: (inout VMixCompatConfiguration) -> Void = { _ in }) async throws -> CompatFixture {
        let sm = StateMachine(initialState: state)
        sm.start()
        let bus = CommandBus(stateMachine: sm)
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: state.format.frameRate)
        let feed = StateFeed(stateMachine: sm) { clock }
        await feed.start()
        var config = VMixCompatConfiguration()
        config.enabled = true
        config.host = "127.0.0.1"
        config.httpPort = 0
        config.tcpPort = 0
        configure(&config)
        let server = VMixCompatServer(bus: bus, feed: feed, configuration: config)
        try await server.start()
        let ticker = ticking ? TickDriver(stateMachine: sm, clock: clock) : nil
        return CompatFixture(stateMachine: sm, bus: bus, feed: feed, server: server, clock: clock, ticker: ticker)
    }

    func stop() async {
        ticker?.stop()
        await server.stop()
        await feed.stop()
        stateMachine.stop()
    }

    var tcpPort: Int { server.boundTCPPort! }
    var httpBase: URL { URL(string: "http://127.0.0.1:\(server.boundHTTPPort!)")! }
}

/// 没有引擎时的拍推进器：按时钟规格每拍 `prepare(upTo:)`，转场 / FTB / 叠加动画才会走完。
final class TickDriver: Sendable {
    private let task: Task<Void, Never>

    init(stateMachine: StateMachine, clock: TickClockSpec) {
        task = Task {
            while !Task.isCancelled {
                let target = clock.tick(at: HostClock.now())
                if target.rawValue >= 0 { await stateMachine.prepare(upTo: target) }
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    func stop() { task.cancel() }
}

/// 行协议的 TCP 客户端（POSIX socket，读有超时）。
final class LineClient: @unchecked Sendable {
    private var fd: Int32
    private var buffer = Data()

    init(port: Int, host: String = "127.0.0.1") throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket 失败"]) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw NSError(domain: "tcp", code: Int(e), userInfo: [NSLocalizedDescriptionKey: "connect \(host):\(port) 失败：\(String(cString: strerror(e)))"])
        }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { if fd >= 0 { close(fd) } }

    func closeNow() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// 发一行（自动补 \r\n）。
    func send(_ line: String) throws {
        try sendRaw(line + "\r\n")
    }

    func sendRaw(_ text: String) throws {
        var data = Array(text.utf8)
        while !data.isEmpty {
            let n = data.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "send 失败"]) }
            data.removeFirst(n)
        }
    }

    /// 读一行（去掉 \r\n）；超时给 nil；对端关闭且缓冲空给 nil。
    func readLine(timeout: TimeInterval = 5) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let r = buffer.firstRange(of: Data("\n".utf8)) {
                var line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            guard try fill(until: deadline) else { return nil }
        }
    }

    /// 读恰好 n 字节。
    func readBytes(_ n: Int, timeout: TimeInterval = 5) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < n {
            guard try fill(until: deadline) else { break }
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(min(n, buffer.count))
        return Data(out)
    }

    /// 等到对端关闭（读到 EOF）；超时返回 false。
    func waitForClose(timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let rc = poll(&p, 1, ms)
            if rc <= 0 { continue }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &tmp, tmp.count, 0)
            if n == 0 { return true }
            if n < 0 { return true }
            buffer.append(contentsOf: tmp[0..<n])
        }
        return false
    }

    /// 从 socket 补一些字节进缓冲；到 deadline 没数据返回 false；EOF 返回 false。
    private func fill(until deadline: Date) throws -> Bool {
        let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&p, 1, ms)
        if rc <= 0 { return false }
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &tmp, tmp.count, 0)
        if n <= 0 { return false }
        buffer.append(contentsOf: tmp[0..<n])
        return true
    }
}

/// 在 127.0.0.1 上找一个此刻空闲的端口（绑 0 再关）。
func freeLocalPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}

extension XCTestCase {
    /// 轮询等条件成立（默认 5 s）。
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// 读 TCP 行直到出现满足条件的一行（中间的行丢掉），超时返回 nil。
    func readLine(_ client: LineClient, timeout: TimeInterval = 5, where predicate: (String) -> Bool) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = try client.readLine(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { return nil }
            if predicate(line) { return line }
        }
        return nil
    }

    /// 读 `XML <n>` 应答并返回 XML 正文（去掉结尾的 CRLF）。
    func readXML(_ client: LineClient) throws -> (declaredLength: Int, body: String) {
        let header = try XCTUnwrap(try client.readLine(), "没收到 XML 头")
        XCTAssertTrue(header.hasPrefix("XML "), "XML 头：\(header)")
        let n = try XCTUnwrap(Int(header.dropFirst(4)), "长度不是数字：\(header)")
        let data = try client.readBytes(n)
        XCTAssertEqual(data.count, n, "XML 正文长度")
        XCTAssertTrue(data.suffix(2) == Data("\r\n".utf8), "长度要含结尾的 CRLF")
        return (n, String(decoding: data.dropLast(2), as: UTF8.self))
    }
}

/// XML 断言辅助（Foundation XMLDocument + XPath）。
struct StatusDocument {
    let document: XMLDocument
    init(_ text: String) throws { document = try XMLDocument(xmlString: text, options: []) }
    var rootName: String? { document.rootElement()?.name }
    func text(_ xpath: String) throws -> String? { try document.nodes(forXPath: xpath).first?.stringValue }
    func nodes(_ xpath: String) throws -> [XMLNode] { try document.nodes(forXPath: xpath) }
    func attribute(_ xpath: String, _ name: String) throws -> String? {
        (try document.nodes(forXPath: xpath).first as? XMLElement)?.attribute(forName: name)?.stringValue
    }
    /// inputs/input[@number=n] 的属性。
    func input(_ number: Int, _ name: String) throws -> String? { try attribute("/*/inputs/input[@number='\(number)']", name) }
}
