import Foundation
import Synchronization
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import ServiceLifecycle
import SwitcherContracts
import SwitcherEngine

// 本地 API（设计方案 §9.2）：HTTP + WebSocket，JSON。Hummingbird 2（Apache-2.0）。
//   GET  /api/v1/state     全量 MixerState + tally + Stats
//   POST /api/v1/command   {command} → {sequence, appliedTick, …}；结构性非法 400 带理由
//   GET  /api/v1/commands  命令目录
//   WS   /api/v1/events    hello → 快照（整快照 + 版本号）/ tally / 每秒 Stats；连接上也能发命令
// 默认只监听 127.0.0.1:8765；token 鉴权默认关。所有应答都是手工编码的 JSON（APIJSON：键排序、不转义斜杠），
// 不用 Hummingbird 的默认编码器，保证和 stats.jsonl / 节目文件同一种写法。

/// API 服务。
public final class APIServer: Sendable {
    public let bus: CommandBus
    public let feed: StateFeed
    public let configuration: APIServerConfiguration
    private let port = Mutex<Int?>(nil)
    private let runner = Mutex<(group: ServiceGroup, task: Task<Void, any Error>)?>(nil)
    private let logger: Logger

    public init(bus: CommandBus, feed: StateFeed, configuration: APIServerConfiguration = APIServerConfiguration()) {
        self.bus = bus
        self.feed = feed
        self.configuration = configuration
        var logger = Logger(label: "switcher.api")
        logger.logLevel = configuration.logLevel
        self.logger = logger
    }

    /// 实际监听的端口（start 之后）。
    public var boundPort: Int? { port.withLock { $0 } }
    /// http://host:port。
    public var baseURL: URL? { boundPort.map { URL(string: "http://\(configuration.host):\($0)")! } }
    public var isRunning: Bool { runner.withLock { $0 != nil } }

    // MARK: 生命周期

    /// 起服务；监听成功后返回（端口写进 boundPort）。
    public func start() async throws {
        guard !isRunning else { return }
        let router = Router()
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        if let token = configuration.token {
            router.add(middleware: TokenAuthMiddleware(token: token))
            wsRouter.add(middleware: TokenAuthMiddleware(token: token))
        }
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
                ready.resolve(.failure(error))     // 端口被占之类：run 先失败
                throw error
            }
            ready.resolve(.failure(APIServerError.stoppedBeforeListening))
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

    /// 优雅停机：停止接受连接、关掉 WS、等在途请求。
    public func stop() async {
        guard let (group, task) = runner.withLock({ r -> (ServiceGroup, Task<Void, any Error>)? in
            defer { r = nil }
            return r.map { ($0.group, $0.task) }
        }) else { return }
        await group.triggerGracefulShutdown()
        _ = try? await task.value
        port.withLock { $0 = nil }
    }

    public enum APIServerError: Error { case stoppedBeforeListening }

    // MARK: 路由

    private func addRoutes(_ router: Router<BasicRequestContext>) {
        router.get("/api/v1/state") { [feed] _, _ in
            Self.json(feed.stateResponse())
        }
        router.get("/api/v1/commands") { _, _ in
            Self.json(CommandCatalogResponse())
        }
        router.post("/api/v1/command") { [self] request, _ in
            var request = request
            let body = try await request.collectBody(upTo: 4 << 20)
            let command: Command
            do {
                command = try CommandEnvelope.decode(Data(buffer: body))
            } catch {
                return Self.json(ErrorResponse(CommandEnvelope.describe(error)), status: .badRequest)
            }
            return await self.execute(command, source: .api)
        }
    }

    /// 走总线，把结果编成 HTTP 应答。
    private func execute(_ command: Command, source: CommandSource) async -> Response {
        let issuedAt = HostClock.now()
        do {
            let receipt = try await bus.submit(command, source: source)
            return Self.json(CommandResponse(receipt: receipt, issuedAt: issuedAt, clock: feed.clock))
        } catch let e as CommandRejection {
            return Self.json(ErrorResponse(e.reason), status: .badRequest)
        } catch {
            return Self.json(ErrorResponse("\(error)"), status: .internalServerError)
        }
    }

    private func addWebSocket(_ router: Router<BasicWebSocketRequestContext>) {
        router.ws("/api/v1/events") { [self] inbound, outbound, _ in
            let subscription = feed.subscribe()
            defer { feed.unsubscribe(subscription.id) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 唯一的写方：订阅流（快照 / stats / 回执都经它）
                group.addTask {
                    for await text in subscription.stream {
                        try await outbound.write(.text(text))
                    }
                }
                // 读方：客户端发来的命令
                group.addTask {
                    for try await message in inbound.messages(maxSize: 4 << 20) {
                        guard case .text(let text) = message else { continue }
                        let reply = await self.handleWSCommand(text)
                        self.feed.send(reply, to: subscription.id)
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }

    /// WS 上的一条命令 → 回执或错误（JSON 文本）。
    func handleWSCommand(_ text: String) async -> String {
        let data = Data(text.utf8)
        let request: WSCommandRequest
        do {
            if let r = try? APIJSON.decoder.decode(WSCommandRequest.self, from: data) {
                request = r
            } else {
                request = WSCommandRequest(id: nil, command: try CommandEnvelope.decode(data))
            }
        } catch {
            let id = (try? APIJSON.decoder.decode(IDOnly.self, from: data))?.id
            return (try? APIJSON.string(WSErrorMessage(id: id, error: CommandEnvelope.describe(error)))) ?? #"{"type":"error","error":"bad json"}"#
        }
        let issuedAt = HostClock.now()
        do {
            let receipt = try await bus.submit(request.command, source: .api)
            let m = ReceiptMessage(id: request.id, sequence: receipt.sequence, appliedTick: receipt.appliedTick, issuedAt: issuedAt,
                                   appliedTickTime: feed.clock?.time(of: receipt.appliedTick))
            return (try? APIJSON.string(m)) ?? #"{"type":"error","error":"encode"}"#
        } catch {
            let reason = (error as? CommandRejection)?.reason ?? "\(error)"
            return (try? APIJSON.string(WSErrorMessage(id: request.id, error: reason))) ?? #"{"type":"error","error":"encode"}"#
        }
    }

    private struct IDOnly: Decodable { var id: JSONValue? }

    // MARK: 应答编码

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? APIJSON.encoder.encode(value)) ?? Data(#"{"error":"encode"}"#.utf8)
        return Response(status: (try? APIJSON.encoder.encode(value)) == nil ? .internalServerError : status,
                        headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                        body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}

/// 简单 token 鉴权：`Authorization: Bearer <token>` 或查询串 `token=<token>`（WS 用）。
struct TokenAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let auth = request.headers[.authorization], auth == "Bearer \(token)" { return try await next(request, context) }
        if let q = request.uri.queryParameters["token"], String(q) == token { return try await next(request, context) }
        return APIServer.json(ErrorResponse("unauthorized"), status: .unauthorized)
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
