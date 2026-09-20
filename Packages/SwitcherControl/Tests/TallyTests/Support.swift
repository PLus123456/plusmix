import Foundation
import XCTest
import Synchronization
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherTally

/// 测试公用状态：4 路合成源 + 录制 / 推流输出（PGM 1、PVW 2），与 SwitcherControlTests.TestStates.base 同形。
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

/// 状态机 + tally 发布器（+ 可选服务，端口 0）。
struct TallyFixture {
    let stateMachine: StateMachine
    let publisher: TallyPublisher
    let server: TallyServer?
    let clock: TickClockSpec

    static func start(state: MixerState = TestStates.base(), serve: Bool = true, heartbeat: Double = 5) async throws -> TallyFixture {
        let sm = StateMachine(initialState: state)
        sm.start()
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: state.format.frameRate)
        let publisher = TallyPublisher(stateMachine: sm) { clock }
        await publisher.start()
        var server: TallyServer? = nil
        if serve {
            let s = TallyServer(publisher: publisher, configuration: TallyServerConfiguration(host: "127.0.0.1", port: 0, heartbeatSeconds: heartbeat))
            try await s.start()
            server = s
        }
        return TallyFixture(stateMachine: sm, publisher: publisher, server: server, clock: clock)
    }

    func stop() async {
        await server?.stop()
        await publisher.stop()
        stateMachine.stop()
    }

    var wsURL: URL { URL(string: "ws://127.0.0.1:\(server!.boundPort!)/tally")! }
    var httpURL: URL { URL(string: "http://127.0.0.1:\(server!.boundPort!)/tally")! }
}

/// 最简 WebSocket 客户端：常驻接收任务 + 队列（URLSessionWebSocketTask.receive 不能被取消，所以不拿它赛跑）。
final class WSClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let queue = Mutex<[String]>([])
    private let failure = Mutex<(any Error)?>(nil)
    private var reader: Task<Void, Never>?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let t = task
        reader = Task { [self] in
            while true {
                do {
                    let m = try await t.receive()
                    if case .string(let s) = m { self.queue.withLock { $0.append(s) } }
                } catch {
                    self.failure.withLock { $0 = error }
                    return
                }
            }
        }
    }

    var error: (any Error)? { failure.withLock { $0 } }

    func next(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let s = queue.withLock({ q -> String? in q.isEmpty ? nil : q.removeFirst() }) { return s }
            if Date() >= deadline || error != nil { return nil }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func close() {
        reader?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

extension XCTestCase {
    func receive(_ ws: WSClient, timeout: TimeInterval = 5) async throws -> [String: Any] {
        guard let text = await ws.next(timeout: timeout) else { throw NSError(domain: "ws", code: 2, userInfo: [NSLocalizedDescriptionKey: "超时没收到消息"]) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// 收到第一条 type 匹配的消息（其他类型丢掉）。
    func receive(_ ws: WSClient, type: String, timeout: TimeInterval = 5) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let m = try await receive(ws, timeout: max(0.05, deadline.timeIntervalSinceNow))
            if m["type"] as? String == type { return m }
        }
        throw NSError(domain: "ws", code: 3, userInfo: [NSLocalizedDescriptionKey: "超时没收到 \(type)"])
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
