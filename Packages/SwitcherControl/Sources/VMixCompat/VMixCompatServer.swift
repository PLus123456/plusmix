// VMixCompat —— 第三方导播软件 API 的兼容层（W3-D；设计方案 §9.3）。
//
// 法律说明（设计方案 §0、落地方案 §2 决策 10）：这是一个适配器，只实现上游协议的一个子集，和上游产品没有任何关系；
// 实现时只读了公开的协议文档和 Companion 模块（MIT）的源码来学接口形状，没有复制任何代码或文案。
// 描述性地说"兼容某某 API"属于法律灰区：**独立 target、默认不启用（设置里显式打开）、发布前问律师**。
// 详细说明与函数覆盖表见 docs/integrations/ 里的兼容层文档。
//
// 做什么：
//   HTTP  GET /api/?Function=<名字>&Input=<n>…   调用函数；GET /api 不带参数 → XML 状态（默认端口 8088）
//   TCP   文本协议（默认 8099，\r\n 结尾）子集：FUNCTION、TALLY、XML、ACTS、SUBSCRIBE / UNSUBSCRIBE TALLY | ACTS、PING、VERSION、QUIT
//   函数名 → 内部 Command 的映射表只做 Companion 的模块用到的子集（FunctionTranslator）；没实现的返回明确错误码和文案，不静默。
// 怎么接：所有命令走 SwitcherControl 的 CommandBus（来源 .api），状态从 StateFeed 读同一份快照，表读数从同一份 Stats 拿（铁律 4）。
//
// 文件一览：
//   VMixCompatServer.swift        门面：配置、起停、计数；execute（函数 → 计划 → 逐条走总线）
//   VMixCompatConfiguration.swift 配置（默认关；HTTP / TCP 各自可关；录制 / 推流输出的选择；报告的版本号）
//   FunctionRequest.swift         "Name key=value&k2=v2" / HTTP 查询串的解析（百分号解码、参数名不分大小写）
//   FunctionTranslator.swift      函数名 → [Command] 的映射表；错误码
//   FunctionCatalog.swift         实现表 / 已知未实现表（文档与测试用）
//   InputReference.swift          Input 参数：编号 / 0 = PVW / -1 = PGM / GUID / 名字
//   VolumeScale.swift             推子 0–100 ↔ dB ↔ 幅度百分比
//   StatusXML.swift               XML 状态文档（Companion 模块解析所需的节点一个不少）
//   TallyDigits.swift             TALLY 串（0 关 / 1 PGM / 2 PVW，按输入位置）
//   Activators.swift              ACTS 查询值与前后状态差出来的事件
//   SnapshotWatcher.swift         SnapshotObserver → 每个连接一条 AsyncStream<MixerSnapshot>
//   CompatHTTPServer.swift        Hummingbird 路由
//   CompatTCPServer.swift         swift-nio 行协议服务端 + 每连接会话（订阅推送）
import Foundation
import Synchronization
import Logging
import SwitcherContracts
import SwitcherEngine
import SwitcherControl

/// 一次函数调用的结果。
public enum FunctionOutcome: Hashable, Sendable {
    /// 计划里的命令全部走完总线；applied = 真的改了状态的条数（0 = 全被 reducer 忽略，例如已经是目标状态）。
    case completed(name: String, applied: Int, total: Int)
    case failed(CompatError)

    /// 给人 / 客户端看的一句话："<名字>"、"<名字> (no change)" 或错误的 "<码>: <文案>"。
    public var text: String {
        switch self {
        case .completed(let name, let applied, _): applied == 0 ? "\(name) (no change)" : name
        case .failed(let e): e.wireText
        }
    }

    public var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// 兼容层服务：HTTP + TCP 两个入口共用一套执行逻辑。
public final class VMixCompatServer: Sendable {
    /// 诊断计数（正式指标在 Stats；这里是兼容层自己的账）。
    public struct Counters: Hashable, Sendable {
        /// 到达 execute 的函数调用数（含失败的）。
        public var functions: UInt64 = 0
        /// 出错的函数调用数（含 TCP 上格式不对的 FUNCTION 行）。
        public var functionErrors: UInt64 = 0
        public var tcpConnectionsAccepted: UInt64 = 0
        public var tcpConnectionsOpen: Int = 0
        /// 连接数满了（`CompatTCPServer.maxConnections`）被直接关掉的新连接。
        public var tcpConnectionsRefused: UInt64 = 0
        /// 一行超过 `CompatTCPServer.maxLineBytes` 被断开的连接。
        public var tcpLinesTooLong: UInt64 = 0
        /// 送出的 XML 状态次数（HTTP + TCP）。
        public var xmlServed: UInt64 = 0
        /// 推给订阅者的 TALLY 事件数。
        public var tallyEvents: UInt64 = 0
        /// 推给订阅者的 ACTS 事件行数。
        public var actsEvents: UInt64 = 0
    }

    public let configuration: VMixCompatConfiguration
    let core: CompatCore
    private let running = Mutex<(http: CompatHTTPServer?, tcp: CompatTCPServer?)?>(nil)

    public init(bus: CommandBus, feed: StateFeed, configuration: VMixCompatConfiguration) {
        self.configuration = configuration
        var logger = Logger(label: "switcher.compat")
        logger.logLevel = configuration.logLevel
        core = CompatCore(bus: bus, feed: feed, configuration: configuration, logger: logger)
    }

    public var isRunning: Bool { running.withLock { $0 != nil } }
    /// 实际监听的 HTTP 端口（没起 / 关着为 nil）。
    public var boundHTTPPort: Int? { running.withLock { $0?.http?.boundPort } }
    /// 实际监听的 TCP 端口。
    public var boundTCPPort: Int? { running.withLock { $0?.tcp?.boundPort } }
    public var counters: Counters { core.counters }

    // MARK: 生命周期

    /// 起服务。`configuration.enabled == false` 时什么都不做（端口不监听，isRunning 仍为 false）——这是默认。
    public func start() async throws {
        guard configuration.enabled, !isRunning else { return }
        await core.attach()
        var http: CompatHTTPServer? = nil
        var tcp: CompatTCPServer? = nil
        do {
            if configuration.httpEnabled {
                let s = CompatHTTPServer(core: core, host: configuration.host, port: configuration.httpPort)
                try await s.start()
                http = s
            }
            if configuration.tcpEnabled {
                let s = CompatTCPServer(core: core, host: configuration.host, port: configuration.tcpPort)
                try await s.start()
                tcp = s
            }
        } catch {
            await http?.stop()
            await tcp?.stop()
            await core.detach()
            throw error
        }
        running.withLock { $0 = (http, tcp) }
    }

    /// 停服务：关掉所有连接与监听。
    public func stop() async {
        guard let (http, tcp) = running.withLock({ r -> (CompatHTTPServer?, CompatTCPServer?)? in
            defer { r = nil }
            return r.map { ($0.http, $0.tcp) }
        }) else { return }
        await tcp?.stop()
        await http?.stop()
        await core.detach()
    }

    // MARK: 直接调用（测试 / 将来 App 内的调试面板）

    /// 执行一个函数调用（不经网络）。
    public func execute(_ request: FunctionRequest) async -> FunctionOutcome {
        await core.execute(request)
    }

    /// 当前 XML 状态。
    public func statusXML() -> String { core.statusXML() }

    /// 当前 TALLY 串。
    public func tallyString() -> String { core.tallyString() }
}

/// HTTP / TCP 共用的执行核心：状态从 StateFeed 读，命令走 CommandBus，快照变化经 SnapshotWatcher 推给连接。
final class CompatCore: Sendable {
    let bus: CommandBus
    let feed: StateFeed
    let configuration: VMixCompatConfiguration
    let logger: Logger
    let watcher = SnapshotWatcher()
    private let functions = Atomic<UInt64>(0)
    private let functionErrors = Atomic<UInt64>(0)
    private let tcpAccepted = Atomic<UInt64>(0)
    private let tcpOpen = Atomic<Int>(0)
    private let xmlServed = Atomic<UInt64>(0)
    private let tallyEvents = Atomic<UInt64>(0)
    private let actsEvents = Atomic<UInt64>(0)

    init(bus: CommandBus, feed: StateFeed, configuration: VMixCompatConfiguration, logger: Logger) {
        self.bus = bus
        self.feed = feed
        self.configuration = configuration
        self.logger = logger
    }

    var counters: VMixCompatServer.Counters {
        VMixCompatServer.Counters(functions: functions.load(ordering: .relaxed), functionErrors: functionErrors.load(ordering: .relaxed),
                                  tcpConnectionsAccepted: tcpAccepted.load(ordering: .relaxed), tcpConnectionsOpen: tcpOpen.load(ordering: .relaxed),
                                  xmlServed: xmlServed.load(ordering: .relaxed), tallyEvents: tallyEvents.load(ordering: .relaxed),
                                  actsEvents: actsEvents.load(ordering: .relaxed))
    }

    func attach() async { await feed.stateMachine.addSnapshotObserver(watcher) }
    func detach() async {
        await feed.stateMachine.removeSnapshotObserver(watcher)
        watcher.finishAll()
    }

    // MARK: 状态

    var state: MixerState { feed.stateMachine.publisher.latest?.state ?? MixerState() }
    var frameRate: FrameRate { feed.clock?.frameRate ?? state.format.frameRate }

    func statusXML() -> String {
        xmlServed.add(1, ordering: .relaxed)
        return StatusXML.document(state: state, frameRate: frameRate, stats: feed.latestStats, configuration: configuration)
    }

    func tallyString() -> String { TallyDigits.string(for: state) }

    func noteTallyEvent() { tallyEvents.add(1, ordering: .relaxed) }
    func noteActsEvents(_ n: Int) { actsEvents.add(UInt64(n), ordering: .relaxed) }
    func noteFunctionError() { functionErrors.add(1, ordering: .relaxed) }
    func noteConnectionOpened() {
        tcpAccepted.add(1, ordering: .relaxed)
        tcpOpen.add(1, ordering: .relaxed)
    }
    func noteConnectionClosed() { tcpOpen.subtract(1, ordering: .relaxed) }

    // MARK: 执行

    func execute(_ request: FunctionRequest) async -> FunctionOutcome {
        functions.add(1, ordering: .relaxed)
        let plan: FunctionPlan
        do {
            plan = try FunctionTranslator.plan(request, state: state, frameRate: frameRate, configuration: configuration)
        } catch {
            functionErrors.add(1, ordering: .relaxed)
            return .failed(error)
        }
        var applied = 0
        for command in plan.commands {
            do {
                let receipt = try await bus.submit(command, source: .api)
                if receipt.applied { applied += 1 }
            } catch let r as CommandRejection {
                functionErrors.add(1, ordering: .relaxed)
                return .failed(CompatError(code: .rejected, message: "\(plan.name): \(r.reason)"))
            } catch {
                functionErrors.add(1, ordering: .relaxed)
                return .failed(CompatError(code: .internalError, message: "\(plan.name): \(error)"))
            }
        }
        return .completed(name: plan.name, applied: applied, total: plan.commands.count)
    }
}
