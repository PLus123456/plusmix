// 控制层接线（W2-B2 接缝 2、3）：W2-C 的 CommandBus（UI / 快捷键 / MIDI / API 的统一入口）+ StateFeed（状态推送源）+ APIServer
// （HTTP / WS，默认 127.0.0.1:8765）+ HotkeyDispatcher（用户表 ~/Library/Application Support/PlusMix/hotkeys.json，没有就默认表）
// + MIDIController（映射编辑是 W3-E；这里只起来）+ 第三方 API 兼容层（W3-D VMixCompat，偏好设置开关，默认关；G4 接线）。
// 起停顺序（reports/w2-control.md §5 第 1 条）：feed.start → api.start（先于引擎，客户端第 0 拍前就能连上）；停：api → 引擎 → feed。
// W5-L：只读 tally 流（SwitcherTally，设置 › Tally 打开时才有）与 headless --tally-port 同一套接法——TallyPublisher 挂状态机的快照观察者、
// TallyServer 起 WS /tally + GET /tally；起在 API / 兼容层之后，停在最前面（tally → API → 引擎）。运行中开关 / 换端口走 setTally，不用重起引擎。
import AppKit
import SwitcherContracts
import SwitcherEngine
import SwitcherControl
import SwitcherTally
import VMixCompat

/// 一条命令走完总线之后给 UI 的反馈（状态行提示用）。
enum CommandFeedback: Equatable {
    /// 总线结构校验拒绝（引用不存在的输入 / 输出等）。
    case rejected(Command, reason: String)
    /// 状态机按规则忽略（回执 applied == false：转场进行中再 fade、FTB 目标已相同……）。
    case ignored(Command)
    /// 快捷键 / MIDI 按下去没做成、要说一句的（W5-O / W2-C4：⌃n 开空叠加通道而 PVW 是黑场、执行没选输入的 Stinger 被拒——提案 029）。
    case control(ControlFeedback)

    var message: String {
        switch self {
        case .rejected(let c, let reason): L("feedback.rejected", Self.describe(c), reason)
        case .ignored(let c): L("feedback.ignored", Self.describe(c))
        case .control(.overlayNeedsPreview(let channel)): L("transition.overlayNeedsPreview", channel, channel)   // 与转场列 / 菜单栏同一句
        case .control(.stingerWithoutInput(let slot?)): L("feedback.stingerSlotWithoutInput", slot)
        case .control(.stingerWithoutInput(nil)): L("feedback.stingerWithoutInput")
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
    /// 第三方 API 兼容层（nil = 偏好设置里关着）。
    let compat: VMixCompatServer?
    /// 只读 tally 流（W5-L）：发布器挂状态机、服务起 WS /tally + GET /tally；设置 › Tally 关着为 nil。
    private(set) var tallyPublisher: TallyPublisher?
    private(set) var tallyServer: TallyServer?
    /// tally 流起不来的原因（端口被占等）。
    private(set) var tallyError: String?
    /// 想要的 tally 配置（nil = 关）：start 时按它起，setTally 运行中改。
    private(set) var tallyConfiguration: TallyServerConfiguration?
    /// start 之后、stopTally 之前才让 tally 起来。
    private var tallyAllowed = false
    /// tally 的起停串行做（开关连点时后一次等前一次做完再对齐）。
    private var tallyQueue: Task<Void, Never>?
    private let stateMachine: StateMachine
    private let clockSpec: @Sendable () -> TickClockSpec?
    /// API 起不来的原因（端口被占等）；起来了为 nil。
    private(set) var apiError: String?
    /// 兼容层起不来的原因。
    private(set) var compatError: String?
    /// MIDI 起不来的原因。
    private(set) var midiError: String?
    private(set) var isRunning = false
    /// UI 命令的串行投递（保持发出顺序：两个 Task 各自 submit 会抢 sequence，setProgram 与 setPreview 可能颠倒）。
    private var commandContinuation: AsyncStream<Command>.Continuation?
    private var commandTask: Task<Void, Never>?
    /// 回执反馈（主线程）。
    var onFeedback: ((CommandFeedback) -> Void)?
    /// 快捷键 / MIDI 音符绑的界面动作（ControlAction.ui，W5-J / Q53：只在 App 里派发、不进总线）：主线程上交给主窗口。
    var onUIAction: ((String) -> Void)?
    /// 已发出的 UI 命令数（测试看）。
    private(set) var commandsSent: UInt64 = 0
    /// 测试用（W3-E6）：MIDI 起之前在调用线程（主线程）上同步卡住这么久，模拟进程里第一次连 MIDIServer 的冷启动。
    /// 真 App / 测试宿主启动时量到 582–592 ms、之后同一进程 0.2 ms（reports/w3-app-7.md §1）：测试宿主里只有启动时那个会话是真冷的，
    /// 之后的会话要测冷启动就设它（MIDIHost.shared 第一次建锚客户端时也是同步等，所以这里同样阻塞、不用 await）。nil = 不模拟。
    static var midiColdStartForTesting: TimeInterval?

    init(stateMachine: StateMachine, engine: Engine, api: APIServerConfiguration?, hotkeyTable: HotkeyTable, midiTable: MIDIMapTable = MIDIMapTable.loadUserTableOrDefault(),
         compat: VMixCompatConfiguration? = nil, tally: TallyServerConfiguration? = nil) {
        let bus = CommandBus(stateMachine: stateMachine)
        let clockSpec: @Sendable () -> TickClockSpec? = { [weak engine] in engine?.clock?.spec }
        let feed = StateFeed(stateMachine: stateMachine, clock: clockSpec)
        self.bus = bus
        self.feed = feed
        self.stateMachine = stateMachine
        self.clockSpec = clockSpec
        tallyConfiguration = tally
        apiServer = api.map { APIServer(bus: bus, feed: feed, configuration: $0) }
        self.compat = compat.map { VMixCompatServer(bus: bus, feed: feed, configuration: $0) }
        hotkeys = HotkeyDispatcher(bus: bus, table: hotkeyTable)
        midi = MIDIController(bus: bus, table: midiTable)
        // 界面动作：派发器在调 handle 的线程上（键盘在主线程）、MIDI 在 CoreMIDI 线程上调——一律回主线程再交给 onUIAction
        let ui: @Sendable (String) -> Void = { [weak self] name in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onUIAction?(name) } }
        }
        hotkeys.setUIActionHandler(ui)
        midi.setUIActionHandler(ui)
        // 快捷键 / MIDI 音符按下去没做成、要说一句的（W5-O；MIDI 是 W2-C4）：派发器在调 handle 的线程上、MIDI 在 CoreMIDI 接收线程上（解析不出），
        // 或各自的派发 Task 里（被拒）调——一律回主线程，状态行同一句
        let feedback: @Sendable (ControlFeedback) -> Void = { [weak self] feedback in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFeedback?(.control(feedback)) } }
        }
        hotkeys.setFeedbackHandler(feedback)
        midi.setFeedbackHandler(feedback)
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
                apiError = L("notice.apiFailed", "\(server.configuration.host):\(server.configuration.port)", "\(error)")
                NSLog("%@", apiError!)
            }
        }
        if let compat {
            do {
                try await compat.start()
                compatError = nil
            } catch {
                compatError = "\(error)"
                NSLog("第三方 API 兼容层起不来：%@", compatError!)
            }
        }
        do {
            if let cold = Self.midiColdStartForTesting { usleep(useconds_t(cold * 1_000_000)) }
            try midi.start()
            midiError = nil
        } catch {
            midiError = L("notice.midiFailed", "\(error)")
            NSLog("%@", midiError!)
        }
        tallyAllowed = true
        await reconcileTally()
    }

    /// 停 tally 流（停机第一步：只读流先断，客户端看到连接关掉）。
    func stopTally() async {
        tallyAllowed = false
        await reconcileTally()
    }

    /// 先停 API（不再收命令、关掉 WS）；引擎停了之后再 `finish()` 停推送源。tally 流若还开着先停它。
    func stopAPI() async {
        await stopTally()
        await apiServer?.stop()
        await compat?.stop()
        midi.stop()
    }

    // MARK: tally 流（W5-L）

    /// 运行中改 tally 配置（nil = 关）：起 / 停 / 换端口，不用重起引擎。还没 start 的只记下来，start 时按它起。
    func setTally(_ configuration: TallyServerConfiguration?) async {
        tallyConfiguration = configuration
        await reconcileTally()
    }

    /// 把 tally 服务对齐到"想要的配置 × 现在能不能起"（串行）。
    private func reconcileTally() async {
        let previous = tallyQueue
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyTallyState()
        }
        tallyQueue = task
        await task.value
    }

    private func applyTallyState() async {
        let desired = tallyAllowed ? tallyConfiguration : nil
        if let server = tallyServer, server.configuration == desired { return }
        if let server = tallyServer {
            tallyServer = nil
            await server.stop()
        }
        if let publisher = tallyPublisher {
            tallyPublisher = nil
            await publisher.stop()
        }
        guard let desired else {
            tallyError = nil
            return
        }
        let publisher = TallyPublisher(stateMachine: stateMachine, clock: clockSpec)
        await publisher.start()
        let server = TallyServer(publisher: publisher, configuration: desired)
        do {
            try await server.start()
            tallyPublisher = publisher
            tallyServer = server
            tallyError = nil
        } catch {
            await publisher.stop()
            tallyError = L("notice.tallyFailed", "\(desired.host):\(desired.port)", "\(error)")
            NSLog("%@", tallyError ?? "")
        }
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
            // 执行没选输入的 Stinger（提案 029 起校验器拒）：说人话的那一句（与快捷键同一句，W5-O）；别的照旧"命令被拒：…"
            if let state = bus.stateMachine.publisher.latest?.state, let feedback = ControlAction.rejectionFeedback(for: command, in: state) {
                onFeedback?(.control(feedback))
            } else {
                onFeedback?(.rejected(command, reason: rejection.reason))
            }
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
