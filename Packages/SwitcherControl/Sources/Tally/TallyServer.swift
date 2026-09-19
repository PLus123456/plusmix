import Foundation
import Synchronization
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import ServiceLifecycle
import SwitcherContracts

// tally 服务（Hummingbird 2，Apache-2.0）：
//   WS  /tally   hello → 当前帧 → 之后每次 tally 变化一帧；没有变化时每 heartbeatSeconds 一条心跳
//   GET /tally   最近一帧（轮询用；还没有帧时 503）
// 默认 0.0.0.0:8766（外部 tally 设备通常在局域网另一台机器上；只读、不收命令，所以不像 API 那样默认只听本机）。

/// tally 服务配置。
public struct TallyServerConfiguration: Sendable, Hashable {
    /// 默认端口：API（8765）+ 1。
    public static let defaultPort = 8766

    /// 监听地址。
    public var host: String = "0.0.0.0"
    /// 端口；0 = 系统分配（测试用），实际端口从 `TallyServer.boundPort` 读。
    public var port: Int = defaultPort
    /// 心跳间隔（秒）；≤ 0 = 不发。
    public var heartbeatSeconds: Double = 5
    /// Hummingbird 的日志级别。
    public var logLevel: Logger.Level = .warning

    public init(host: String = "0.0.0.0", port: Int = TallyServerConfiguration.defaultPort, heartbeatSeconds: Double = 5, logLevel: Logger.Level = .warning) {
        self.host = host
        self.port = port
        self.heartbeatSeconds = heartbeatSeconds
        self.logLevel = logLevel
    }
}

/// tally 服务。
public final class TallyServer: Sendable {
    public let publisher: TallyPublisher
    public let configuration: TallyServerConfiguration
    private let port = Mutex<Int?>(nil)
    private let runner = Mutex<(group: ServiceGroup, task: Task<Void, any Error>)?>(nil)
    private let logger: Logger

    public init(publisher: TallyPublisher, configuration: TallyServerConfiguration = TallyServerConfiguration()) {
        self.publisher = publisher
        self.configuration = configuration
        var logger = Logger(label: "switcher.tally")
        logger.logLevel = configuration.logLevel
        self.logger = logger
    }

    /// 实际监听的端口（start 之后）。
    public var boundPort: Int? { port.withLock { $0 } }
    public var isRunning: Bool { runner.withLock { $0 != nil } }

    public enum TallyServerError: Error { case stoppedBeforeListening }

    // MARK: 生命周期

    /// 起服务；监听成功后返回。
    public func start() async throws {
        guard !isRunning else { return }
        let router = Router()
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        addRoutes(router)
        addWebSocket(wsRouter)
        let ready = ReadyBox()
        let app = Application(router: router,
                              server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
                              configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: "Switcher"),
                              onServerRunning: { channel in ready.resolve(.success(channel.localAddress?.port ?? -1)) },
                              logger: logger)
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let task = Task {
            do {
                try await group.run()
            } catch {
                ready.resolve(.failure(error))
                throw error
            }
            ready.resolve(.failure(TallyServerError.stoppedBeforeListening))
        }
        runner.withLock { $0 = (group, task) }
        do {
            let bound = try await ready.wait()
            port.withLock { $0 = bound }
        } catch {
            runner.withLock { $0 = nil }
            throw error
        }
    }

    /// 优雅停机。
    public func stop() async {
        guard let (group, task) = runner.withLock({ r -> (ServiceGroup, Task<Void, any Error>)? in
            defer { r = nil }
            return r.map { ($0.group, $0.task) }
        }) else { return }
        await group.triggerGracefulShutdown()
        _ = try? await task.value
        port.withLock { $0 = nil }
    }

    // MARK: 路由

    private func addRoutes(_ router: Router<BasicRequestContext>) {
        router.get("/tally") { [publisher] _, _ in
            guard let json = publisher.latestJSON else {
                return Response(status: .serviceUnavailable, headers: [.contentType: "application/json; charset=utf-8"],
                                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"no tally yet"}"#)))
            }
            return Response(status: .ok, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                            body: .init(byteBuffer: ByteBuffer(string: json)))
        }
    }

    private func addWebSocket(_ router: Router<BasicWebSocketRequestContext>) {
        let heartbeat = configuration.heartbeatSeconds
        router.ws("/tally") { [publisher] inbound, outbound, _ in
            let subscription = publisher.subscribe()
            defer { publisher.unsubscribe(subscription.id) }
            try await outbound.write(.text(publisher.hello()))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await text in subscription.stream {
                        try await outbound.write(.text(text))
                    }
                }
                if heartbeat > 0 {
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .milliseconds(Int(heartbeat * 1000)))
                            try await outbound.write(.text(publisher.heartbeat()))
                        }
                    }
                }
                // 读方：客户端发什么都不管，但要把收到的消费掉，连接关闭时这里结束
                group.addTask {
                    for try await _ in inbound.messages(maxSize: 64 << 10) {}
                }
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }
}

/// 等 onServerRunning 的信箱：监听成功给端口，run 先失败给错误；只认第一次。
final class ReadyBox: @unchecked Sendable {
    private let state = Mutex<(result: Result<Int, any Error>?, waiter: CheckedContinuation<Int, any Error>?)>((nil, nil))

    func resolve(_ result: Result<Int, any Error>) {
        let waiter = state.withLock { s -> CheckedContinuation<Int, any Error>? in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }

    func wait() async throws -> Int {
        try await withCheckedThrowingContinuation { c in
            let immediate = state.withLock { s -> Result<Int, any Error>? in
                if let r = s.result { return r }
                s.waiter = c
                return nil
            }
            if let immediate { c.resume(with: immediate) }
        }
    }
}
