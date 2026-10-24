import Foundation
import Synchronization
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle
import SwitcherControl

/// HTTP 入口（Hummingbird 2）：GET /api（也认 /api/、/API、/API/）。
///   带 Function=… → 执行，200 "OK <名字>[ (no change)]"；出错按错误码给状态码，正文 "<码>: <文案>"（text/plain）。
///   不带 → XML 状态（text/xml）。
///   浏览器来源（Origin 不在 `allowedOrigins`、或 Sec-Fetch-Site 不是 none / same-origin）→ 403 "Forbidden"（text/plain），什么都不执行。
final class CompatHTTPServer: Sendable {
    let core: CompatCore
    let host: String
    let port: Int
    private let bound = Mutex<Int?>(nil)
    private let runner = Mutex<(group: ServiceGroup, task: Task<Void, any Error>)?>(nil)

    init(core: CompatCore, host: String, port: Int) {
        self.core = core
        self.host = host
        self.port = port
    }

    var boundPort: Int? { bound.withLock { $0 } }

    enum StartError: Error { case stoppedBeforeListening }

    func start() async throws {
        let router = Router()
        // 浏览器来源（NS05）：与主 API 同一套规则；上游协议就是 GET、没有 token，网页一个 <img> 就能切节目，所以连 XML 状态一起拦
        router.add(middleware: BrowserRequestGuard(allowedOrigins: core.configuration.allowedOrigins) { Self.text("Forbidden", status: 403) })
        for path in ["/api", "/API"] {   // Hummingbird 把结尾斜杠归一：/api/ 也落到 /api
            router.get(RouterPath(path)) { [core] request, _ in
                await Self.handle(request, core: core)
            }
        }
        let ready = ReadyBox()
        let app = Application(router: router,
                              configuration: .init(address: .hostname(host, port: port), serverName: "Switcher"),
                              onServerRunning: { channel in ready.resolve(.success(channel.localAddress?.port ?? -1)) },
                              logger: core.logger)
        let group = ServiceGroup(configuration: .init(services: [app], logger: core.logger))
        let task = Task {
            do {
                try await group.run()
            } catch {
                ready.resolve(.failure(error))
                throw error
            }
            ready.resolve(.failure(StartError.stoppedBeforeListening))
        }
        runner.withLock { $0 = (group, task) }
        do {
            let p = try await ready.wait()
            bound.withLock { $0 = p }
        } catch {
            runner.withLock { $0 = nil }
            throw error
        }
    }

    func stop() async {
        guard let (group, task) = runner.withLock({ r -> (ServiceGroup, Task<Void, any Error>)? in
            defer { r = nil }
            return r.map { ($0.group, $0.task) }
        }) else { return }
        await group.triggerGracefulShutdown()
        _ = try? await task.value
        bound.withLock { $0 = nil }
    }

    static func handle(_ request: Request, core: CompatCore) async -> Response {
        let query = request.uri.query
        guard let function = FunctionRequest(httpQuery: query) else {
            if let query, FunctionRequest.parseQuery(query).contains(where: { $0.0.lowercased() == "function" }) {
                return text("BadParameter: missing function name", status: 400)
            }
            return Response(status: .ok, headers: [.contentType: "text/xml; charset=utf-8", .cacheControl: "no-store"],
                            body: .init(byteBuffer: ByteBuffer(string: core.statusXML())))
        }
        guard !function.name.isEmpty else { return text("BadParameter: missing function name", status: 400) }
        let outcome = await core.execute(function)
        switch outcome {
        case .completed:
            return text("OK \(outcome.text)", status: 200)
        case .failed(let e):
            return text(e.wireText, status: e.httpStatus)
        }
    }

    static func text(_ body: String, status: Int) -> Response {
        Response(status: .init(code: status), headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
                 body: .init(byteBuffer: ByteBuffer(string: body)))
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
