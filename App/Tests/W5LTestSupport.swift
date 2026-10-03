// W5-L（prompt 98）用例的公共工具：WebSocket 收文本帧（边泵事件边等）、端口在不在听、本机局域网 IPv4（与 App 的实现分开算，
// 用来核对页上显示的地址）、合成鼠标事件（只交给 MainWindow.sendEvent 看锁拦不拦——合成事件 AppKit 不派发到视图，UISmokeTests 的结论）。
import AppKit
import Darwin
import XCTest
@testable import Switcher

/// 一个 WebSocket 客户端：连上就一直收，文本帧按到达顺序存下来。
final class WebSocketProbe: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var received: [String] = []
    private var failure: (any Error)?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        receiveNext()
    }

    var texts: [String] { lock.withLock { received } }
    var error: (any Error)? { lock.withLock { failure } }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: text = ""
                }
                self.lock.withLock { self.received.append(text) }
                self.receiveNext()
            case .failure(let e):
                self.lock.withLock { self.failure = e }
            }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

@MainActor
extension AppTest {
    /// 这个端口上有没有人在听（本机回环上 connect 一次：被拒 = 没人听）。
    static func isListening(port: Int, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// 本机的局域网 IPv4（getifaddrs：开着、在跑、不是回环 / 点对点隧道、不是 169.254 自分配）；与 App 的实现分开写，核对页上的地址用。
    static func lanIPv4Addresses() -> Set<String> {
        var out = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.hasPrefix("169.254.") { out.insert(ip) }
        }
        return out
    }

    /// 一个落在 view 中心的鼠标事件（窗口坐标）。
    static func mouseEvent(_ type: NSEvent.EventType, at view: NSView) -> NSEvent? {
        guard let window = view.window else { return nil }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    /// 这个 session 的 API 设了 token 时要拼在地址后面的查询串（API 也认 `?token=`；别的用例——ReleaseTests R7——可能给内存里的设置加过 token）。
    static func tokenQuery(_ session: SwitcherSession) -> String {
        session.control.apiServer?.configuration.token.map { "?token=\($0)" } ?? ""
    }

    /// 解析一帧 JSON 文本。
    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// 停引擎再起一个空节目（测"引擎停了"的用例用：App 里没有单独"停引擎"的入口，退出 / 换节目才停）。
    static func stopEngine() {
        let done = expectationBox()
        Task { await controller.shutdown(); done.value = true }
        waitUntil(15) { done.value }
    }

    /// 停了之后重新起一个空节目（下一条用例的 freshSession 要等到一个跑着的 session）。
    static func restartEngine() {
        let done = expectationBox()
        Task { await controller.newShow(); done.value = true }
        waitUntil(15) { done.value && controller.session?.isRunning == true }
    }
}
