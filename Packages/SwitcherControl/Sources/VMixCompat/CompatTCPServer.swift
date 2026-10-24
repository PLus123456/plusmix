import Foundation
import Synchronization
import Logging
import NIOCore
import NIOPosix
import SwitcherContracts

// TCP 文本协议服务端（swift-nio，NIOAsyncChannel）。每条连接一个 TCPSession：
//   读方：按 \r\n（或 \n）切行 → 处理 → 写应答；QUIT 关连接。
//   推方：订阅快照流，SUBSCRIBE TALLY 后 TALLY 串变了推 `TALLY OK …`，SUBSCRIBE ACTS 后按前后状态差推 `ACTS OK …`。
// 应答格式：`<CMD> OK …` / `<CMD> ER <码>: <文案>` / `XML <长度>\r\n<正文>\r\n`（长度含结尾 CRLF，上游约定）。
// 上限（NS07）：一行超过 maxLineBytes 断开这条连接，同时开着 maxConnections 条之后新连接直接关；不设空闲超时（订阅者只收不发）。
final class CompatTCPServer: Sendable {
    /// 一行最长多少字节（不含行尾的 \r\n）：超过就断开这条连接、记一行日志（Codex 10-24 审计 NS07——原来不带换行的字节无限往 pending 里攒）。
    /// 上游协议最长的正常行是 FUNCTION 带一段文字（SetText 之类），远小于 64 KiB。
    static let maxLineBytes = 64 * 1024
    /// 同时开着的连接上限：满了新连接直接关、不发问候。不加空闲超时——订阅 TALLY 的客户端本来就只收不发。
    static let maxConnections = 64

    let core: CompatCore
    let host: String
    let port: Int
    private let state = Mutex<(task: Task<Void, Never>, port: Int)?>(nil)

    init(core: CompatCore, host: String, port: Int) {
        self.core = core
        self.host = host
        self.port = port
    }

    var boundPort: Int? { state.withLock { $0?.port } }

    func start() async throws {
        let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .bind(host: host, port: port) { child in
                child.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: child) }
            }
        let bound = server.channel.localAddress?.port ?? port
        let task = Task { await self.serve(server) }
        state.withLock { $0 = (task, bound) }
    }

    func stop() async {
        let task = state.withLock { s -> Task<Void, Never>? in defer { s = nil }; return s?.task }
        task?.cancel()
        await task?.value
    }

    private func serve(_ server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>) async {
        do {
            try await withThrowingDiscardingTaskGroup { group in
                try await server.executeThenClose { inbound in
                    for try await connection in inbound {
                        // 连接数上限（NS07）：计数只在这条循环里加，满了这一条不发问候、直接关
                        guard core.openConnection(limit: Self.maxConnections) else {
                            core.logger.notice("tcp connection refused: \(Self.maxConnections) connections already open")
                            group.addTask { try? await connection.executeThenClose { _, _ in } }
                            continue
                        }
                        group.addTask { await self.handle(connection) }
                    }
                }
            }
        } catch {
            // 取消（stop）或监听 socket 出错：连接任务已随任务组一起取消
        }
    }

    private func handle(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        defer { core.noteConnectionClosed() }   // 记开在 serve 的接连接循环里（openConnection）
        do {
            try await connection.executeThenClose { inbound, outbound in
                let session = TCPSession(core: core, outbound: outbound)
                try await session.run(inbound: inbound)
            }
        } catch {
            core.logger.debug("tcp connection ended: \(error)")
        }
    }
}

/// 一条连接。
final class TCPSession: Sendable {
    struct Subscriptions {
        var tally = false
        var acts = false
        /// 最近推给（或随 SUBSCRIBE OK 一起发给）客户端的 TALLY 串。
        var lastTally: String? = nil
    }

    let core: CompatCore
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let subscriptions = Mutex<Subscriptions>(Subscriptions())

    init(core: CompatCore, outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        self.core = core
        self.outbound = outbound
    }

    func run(inbound: NIOAsyncChannelInboundStream<ByteBuffer>) async throws {
        try await write("VERSION OK \(core.configuration.reportedVersion)\r\n")
        let (id, snapshots) = core.watcher.subscribe()
        defer { core.watcher.unsubscribe(id) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readLoop(inbound) }
            group.addTask { try await self.pushLoop(snapshots) }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: 读

    private func readLoop(_ inbound: NIOAsyncChannelInboundStream<ByteBuffer>) async throws {
        // 按字节切行：Swift 的 String 把 "\r\n" 当一个字符，firstIndex(of: "\n") 找不到它
        var pending: [UInt8] = []
        core.logger.trace("tcp read loop started")
        for try await buffer in inbound {
            core.logger.trace("tcp received \(buffer.readableBytes) bytes")
            pending.append(contentsOf: buffer.readableBytesView)
            while let newline = pending.firstIndex(of: 0x0A) {
                var lineBytes = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if lineBytes.last == 0x0D { lineBytes = lineBytes.dropLast() }
                guard lineBytes.count <= CompatTCPServer.maxLineBytes else {
                    lineTooLong(lineBytes.count)
                    return
                }
                let line = String(decoding: lineBytes, as: UTF8.self)
                core.logger.trace("tcp line: \(line)")
                if try await handle(line: line) == .quit { return }
            }
            // 还没等到换行的半行（NS07）：超过上限（多留一个 \r 的位置）就断开——原来不带换行的字节在这里无限往上攒
            if pending.count > CompatTCPServer.maxLineBytes + 1 {
                lineTooLong(pending.count)
                return
            }
        }
    }

    /// 一行超过 `CompatTCPServer.maxLineBytes`：计数、记一行日志；调用方随即从 readLoop 返回，这条连接收尾关掉。
    private func lineTooLong(_ bytes: Int) {
        core.noteLineTooLong()
        core.logger.warning("tcp line longer than \(CompatTCPServer.maxLineBytes) bytes (\(bytes) so far); closing connection")
    }

    enum Flow { case `continue`, quit }

    /// 一行命令 → 应答；QUIT 返回 .quit。
    func handle(line: String) async throws -> Flow {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .continue }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let command = String(parts[0]).uppercased()
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch command {
        case "PING":
            try await write("PING OK PONG\r\n")
        case "VERSION":
            try await write("VERSION OK \(core.configuration.reportedVersion)\r\n")
        case "TALLY":
            try await write("TALLY OK \(core.tallyString())\r\n")
        case "XML":
            let xml = core.statusXML()
            try await write("XML \(xml.utf8.count + 2)\r\n\(xml)\r\n")
        case "XMLTEXT":
            try await write("XMLTEXT ER NotImplemented: XMLTEXT (XPath lookup) is not implemented; request XML and parse it\r\n")
        case "FUNCTION":
            guard let request = FunctionRequest(commandLine: rest) else {
                core.noteFunctionError()
                try await write("FUNCTION ER BadParameter: missing function name (FUNCTION <name> [key=value&…])\r\n")
                break
            }
            let outcome = await core.execute(request)
            switch outcome {
            case .completed: try await write("FUNCTION OK \(outcome.text)\r\n")
            case .failed(let e): try await write("FUNCTION ER \(e.wireText)\r\n")
            }
        case "ACTS":
            let words = rest.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = words.first else {
                try await write("ACTS ER BadParameter: ACTS <activator> [input]\r\n")
                break
            }
            var input: Int? = nil
            if words.count > 1 {
                guard let n = Int(words[1]) else {
                    try await write("ACTS ER BadParameter: input must be a number (got \(words[1]))\r\n")
                    break
                }
                input = n
            }
            do {
                try await write("ACTS OK \(try Activators.value(name: String(name), input: input, state: core.state))\r\n")
            } catch let e as CompatError {
                try await write("ACTS ER \(e.wireText)\r\n")
            }
        case "SUBSCRIBE", "UNSUBSCRIBE":
            let event = rest.uppercased()
            let on = command == "SUBSCRIBE"
            switch event {
            case "TALLY":
                let current = core.tallyString()
                subscriptions.withLock {
                    $0.tally = on
                    $0.lastTally = on ? current : nil
                }
                try await write("\(command) OK TALLY\r\n")
                if on { try await write("TALLY OK \(current)\r\n") }
            case "ACTS":
                subscriptions.withLock { $0.acts = on }
                try await write("\(command) OK ACTS\r\n")
            default:
                try await write("\(command) ER BadParameter: unknown event \(rest) (TALLY | ACTS)\r\n")
            }
        case "QUIT":
            try await write("QUIT OK Bye\r\n")
            return .quit
        default:
            try await write("\(command) ER UnknownCommand: \(command)\r\n")
        }
        return .continue
    }

    // MARK: 推

    private func pushLoop(_ snapshots: AsyncStream<MixerSnapshot>) async throws {
        var lastState = core.state
        for await snap in snapshots {
            let subs = subscriptions.withLock { $0 }
            let state = snap.state
            if subs.tally {
                let digits = TallyDigits.string(for: state)
                if digits != subs.lastTally {
                    subscriptions.withLock { $0.lastTally = digits }
                    core.noteTallyEvent()
                    try await write("TALLY OK \(digits)\r\n")
                }
            }
            if subs.acts {
                let events = Activators.events(from: lastState, to: state)
                if !events.isEmpty {
                    core.noteActsEvents(events.count)
                    try await write(events.map { "ACTS OK \($0)\r\n" }.joined())
                }
            }
            lastState = state
        }
    }

    private func write(_ text: String) async throws {
        core.logger.trace("tcp write: \(text.prefix(60))")
        try await outbound.write(ByteBuffer(string: text))
    }
}
