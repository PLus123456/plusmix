// 控制层接线（W2-B2 接缝 2、3）：W2-C 的 CommandBus（UI / 快捷键 / MIDI / API 的统一入口）+ StateFeed（状态推送源）+ APIServer
// （HTTP / WS，默认 127.0.0.1:8765）+ HotkeyDispatcher（用户表 ~/Library/Application Support/Switcher/hotkeys.json，没有就默认表）
// + MIDIController（映射编辑是 W3-E；这里只起来）。
// 起停顺序（reports/w2-control.md §5 第 1 条）：feed.start → api.start（先于引擎，客户端第 0 拍前就能连上）；停：api → 引擎 → feed。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherControl

/// 一条命令走完总线之后给 UI 的反馈（状态行提示用）。
enum CommandFeedback: Equatable {
    /// 总线结构校验拒绝（引用不存在的输入 / 输出等）。
    case rejected(Command, reason: String)
    /// 状态机按规则忽略（回执 applied == false：转场进行中再 fade、FTB 目标已相同……）。
    case ignored(Command)

    var message: String {
        switch self {
        case .rejected(let c, let reason): "命令被拒：\(Self.describe(c)) — \(reason)"
        case .ignored(let c): "命令被忽略：\(Self.describe(c))（状态没变）"
        }
    }

    static func describe(_ c: Command) -> String {
        let text = "\(c)"
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }
}

@MainActor
final class ControlRuntime {
    let bus: CommandBus
    let feed: StateFeed
    let apiServer: APIServer?
    let hotkeys: HotkeyDispatcher
    let midi: MIDIController
    /// API 起不来的原因（端口被占等）；起来了为 nil。
    private(set) var apiError: String?
    /// MIDI 起不来的原因。
    private(set) var midiError: String?
    private(set) var isRunning = false
    /// UI 命令的串行投递（保持发出顺序：两个 Task 各自 submit 会抢 sequence，setProgram 与 setPreview 可能颠倒）。
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var commandTask: Task<Void, Never>?
    /// 回执反馈（主线程）。
    var onFeedback: ((CommandFeedback) -> Void)?
    /// 已发出的 UI 命令数（测试看）。
    private(set) var commandsSent: UInt64 = 0

    init(stateMachine: StateMachine, engine: Engine, api: APIServerConfiguration?, hotkeyTable: HotkeyTable) {
        let bus = CommandBus(stateMachine: stateMachine)
        let feed = StateFeed(stateMachine: stateMachine) { [weak engine] in engine?.clock?.spec }
        self.bus = bus
        self.feed = feed
        apiServer = api.map { APIServer(bus: bus, feed: feed, configuration: $0) }
        hotkeys = HotkeyDispatcher(bus: bus, table: hotkeyTable)
        midi = MIDIController(bus: bus, table: MIDIMapTable.loadUserTableOrDefault())
    }

    /// 起：命令循环 → 推送源 → API → MIDI。API / MIDI 起不来不算错（记原因，节目照跑）。
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        startCommandLoop()
        await feed.start()
        if let server = apiServer {
            do {
                try await server.start()
                apiError = nil
            } catch {
                apiError = "API 起不来（\(server.configuration.host):\(server.configuration.port)）：\(error)"
                NSLog("%@", apiError!)
            }
        }
        do {
            try midi.start()
            midiError = nil
        } catch {
            midiError = "MIDI 起不来：\(error)"
            NSLog("%@", midiError!)
        }
    }

    /// 先停 API（不再收命令、关掉 WS）；引擎停了之后再 `finish()` 停推送源。
    func stopAPI() async {
        await apiServer?.stop()
        midi.stop()
    }

    /// 引擎停了之后：停推送源、结束命令循环。
    func finish() async {
        guard isRunning else { return }
        commandContinuation?.finish()
        commandContinuation = nil
        commandTask?.cancel()
        commandTask = nil
        await feed.stop()
        isRunning = false
    }

    // MARK: UI 命令

    /// UI 唯一的写入口：进总线（来源 ui），按发出顺序串行提交；回执 applied == false / 被拒时回调 onFeedback。
    func send(_ command: Command) {
        commandsSent &+= 1
        if let commandContinuation {
            commandContinuation.yield(command)
        } else {
            // 还没 start：直接走总线一次
            let bus = self.bus
            Task { @MainActor [weak self] in
                await self?.deliver(command, via: bus)
            }
        }
    }

    private func startCommandLoop() {
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        commandContinuation = continuation
        let bus = self.bus
        commandTask = Task { @MainActor [weak self] in
            for await command in stream {
                await self?.deliver(command, via: bus)
            }
        }
    }

    private func deliver(_ command: Command, via bus: CommandBus) async {
        do {
            let receipt = try await bus.submit(command, source: .ui)
            if !receipt.applied { onFeedback?(.ignored(command)) }
        } catch let rejection as CommandRejection {
            onFeedback?(.rejected(command, reason: rejection.reason))
        } catch {
            onFeedback?(.rejected(command, reason: "\(error)"))
        }
    }

    // MARK: 快捷键

    /// 主窗口 keyDown：有绑定就投给总线（来源 hotkey）并返回 true。
    func handleKey(_ event: NSEvent) -> Bool {
        guard let combo = KeyCombo(event: event), !event.isARepeat else { return false }
        return hotkeys.handle(combo)
    }

    /// 快捷键表（菜单里列出来）。
    var hotkeyTable: HotkeyTable { hotkeys.table }
}
