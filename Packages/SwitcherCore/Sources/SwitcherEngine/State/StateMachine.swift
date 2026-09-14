import Foundation
import Synchronization
import SwitcherContracts

// 单一状态机（设计方案 §9.1、§12 决策 3；CONTRACTS.md §2.5、§2.6）。
//
// 一个 actor 持有 MixerState，跑在专用线程执行器上（StateThreadExecutor）。所有修改都是命令 → reduce → 新快照 → 发布。
//   - 命令：`submit(IssuedCommand)` 按 sequence 严格顺序应用，乱序到达的排队等前一条（C4 的基础）；
//     `schedule(_:at:)` 把命令排在某一拍（场景脚本）；`apply(_:)` 本地直接应用（不经总线，测试 / 单机 UI）。
//   - 拍：渲染线程每拍 `noteRendered(n)` + `requestPrepare(n + 1)`（无锁无分配）；状态机线程随即 `prepare(upTo:)`：
//     逐拍 advance → 应用该拍的排程命令 → 发布快照 → preparedTick = n。命令应用在"渲染线程还没消费的最早一拍"
//     （max(currentTick, renderedTick + 1)），所以回执里的 appliedTick 就是画面上生效的拍（拍点边界的微小竞争窗口
//     除外，见报告）。
//   - 发布：`publisher`（HazardPublisher）原子指针交换；渲染线程 / 音频线程借用指针，不进 actor。
//   - 事件：转场开始 / 完成 / 瞬时切换随每次状态变化发给 TransitionEventSink（AFV，W2-E）。

/// 状态机对一次 `submit` 的答复。
public enum SubmitOutcome: Sendable, Hashable {
    /// 已应用，回执带生效拍。
    case applied(CommandReceipt)
    /// sequence 前面还有没到的命令，先排队；到齐后自动按序应用（回执可用 `receipt(forSequence:)` 查）。
    case queued
    /// sequence 已经处理过（重复投递或过期），忽略。
    case stale
}

/// 转场事件（AFV 用）：随状态变化在状态机线程上发出。
public enum TransitionEvent: Sendable, Hashable {
    /// 瞬时切换（cut / setProgram / 时长 0 的 auto）：from → to。
    case cut(tick: Tick, from: Int, to: Int)
    /// 转场开始：from（当前 PGM）→ to（PVW）。
    case started(tick: Tick, type: TransitionType, durationTicks: Int, from: Int, to: Int, source: TransitionSource)
    /// 转场完成（对调已发生）。
    case completed(tick: Tick, from: Int, to: Int)
    /// 转场被取消（例如中途 removeInput）。
    case cancelled(tick: Tick)
}

/// 转场事件的接收方。在状态机线程上被同步调用，必须快速返回。
public protocol TransitionEventSink: AnyObject, Sendable {
    func stateMachine(_ machine: StateMachine, didEmit event: TransitionEvent, afv: Bool)
}

/// 每拍观察者（场景执行器 / 录制脚本这类"按拍发命令"的东西挂这里）。
/// 状态机线程上、第 tick 拍 advance 之后、应用该拍排程命令之前同步调用；参数是隔离的状态机，
/// 可以直接 `machine.schedule(cmd, at: tick)` 把命令加进这一拍（tick == 当前准备中的拍时立即应用）。不是实时线程，但要快。
public protocol TickObserver: AnyObject, Sendable {
    func stateMachine(_ machine: isolated StateMachine, willApplyTick tick: Tick)
}

/// 持有 MixerState 的 actor。
public actor StateMachine {
    /// 选项。
    public struct Options: Sendable {
        /// 快照发布器的实时读槽数（渲染线程 1 个，音频 1 个，余量）。
        public var readerCapacity: Int = 4
        /// 保留最近多少条回执 / 已应用序号。
        public var historyLimit: Int = 4096
        public init() {}
    }

    private let executor: StateThreadExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// 快照发布器：渲染线程用 `makeReaderSlot()` 借用；普通线程用 `latest`。
    public nonisolated let publisher: HazardPublisher<MixerSnapshot>
    private let reducer = MixerReducer()
    private let options: Options
    private var current: MixerState
    private var publishedState: MixerState
    private var currentTick: Tick
    private var lastSequence: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var waiting: [UInt64: IssuedCommand] = [:]
    private var scheduled: [Tick: [Command]] = [:]
    private var receipts: [UInt64: CommandReceipt] = [:]
    private var applied: [UInt64] = []
    private var sinks: [any TransitionEventSink] = []
    private var tickObservers: [any TickObserver] = []
    private nonisolated let preparedTickValue: Atomic<Int64>
    private nonisolated let renderedTickValue = Atomic<Int64>(Int64.min)

    public init(initialState: MixerState, startTick: Tick = .zero, options: Options = Options()) {
        self.options = options
        executor = StateThreadExecutor()
        current = initialState
        publishedState = initialState
        currentTick = startTick
        preparedTickValue = Atomic(startTick.rawValue)
        publisher = HazardPublisher(initial: MixerSnapshot(state: initialState, sequence: 0, tick: startTick), readerCapacity: options.readerCapacity)
        executor.tickWork = { [unowned self] tick in
            self.assumeIsolated { $0.prepare(upTo: tick) }
        }
    }

    // MARK: 生命周期（任何线程）

    /// 起状态机线程。没 start 也能用（job 不会被执行），所以 Engine.start 会调它。
    public nonisolated func start() { executor.start() }
    /// 停线程（队列里的 job 跑完再停）。
    public nonisolated func stop() { executor.stop() }

    // MARK: 渲染线程入口（nonisolated，无锁无分配）

    /// 请求把状态准备到第 tick 拍（含）。渲染线程每拍调一次（下一拍）。
    public nonisolated func requestPrepare(_ tick: Tick) { executor.wake(tick: tick) }

    /// 已准备好（快照可用）的最新拍。
    public nonisolated var preparedTick: Tick { Tick(preparedTickValue.load(ordering: .acquiring)) }

    /// 渲染线程借到第 tick 拍的快照后立刻调：之后的命令只能落在 tick + 1 及以后。
    public nonisolated func noteRendered(_ tick: Tick) { renderedTickValue.store(tick.rawValue, ordering: .releasing) }

    /// 渲染线程最近消费的拍（没有为 nil）。
    public nonisolated var renderedTick: Tick? {
        let v = renderedTickValue.load(ordering: .acquiring)
        return v == Int64.min ? nil : Tick(v)
    }

    // MARK: 读

    /// 当前状态。
    public var state: MixerState { current }
    /// 当前拍（最近准备到的拍）。
    public var tick: Tick { currentTick }
    /// 最近应用的命令 sequence。
    public var sequence: UInt64 { lastSequence }
    /// 排队等前序的命令数。
    public var pendingCount: Int { waiting.count }
    /// 最近应用的命令序号（按应用顺序，最多 historyLimit 条）。
    public var appliedSequences: [UInt64] { applied }
    /// 某条命令的回执。
    public func receipt(forSequence sequence: UInt64) -> CommandReceipt? { receipts[sequence] }

    public func addTransitionSink(_ sink: any TransitionEventSink) { sinks.append(sink) }
    public func removeTransitionSink(_ sink: any TransitionEventSink) { sinks.removeAll { $0 === sink } }
    public func addTickObserver(_ observer: any TickObserver) { tickObservers.append(observer) }
    public func removeTickObserver(_ observer: any TickObserver) { tickObservers.removeAll { $0 === observer } }

    // MARK: 命令

    /// 总线投递：按 sequence 严格顺序应用。
    public func submit(_ issued: IssuedCommand) -> SubmitOutcome {
        guard issued.sequence >= nextSequence else { return .stale }
        if waiting[issued.sequence] != nil, issued.sequence != nextSequence { return .stale }
        waiting[issued.sequence] = issued
        var mine: CommandReceipt?
        while let next = waiting.removeValue(forKey: nextSequence) {
            let receipt = applyNow(next.command, sequence: next.sequence)
            if next.sequence == issued.sequence { mine = receipt }
            nextSequence += 1
        }
        if let mine { return .applied(mine) }
        return .queued
    }

    /// 本地直接应用（不经总线，不占 sequence）。
    @discardableResult
    public func apply(_ command: Command) -> CommandReceipt {
        applyNow(command, sequence: nil)
    }

    /// 把命令排在第 tick 拍应用（场景脚本）；tick 不晚于当前拍则立即应用。
    public func schedule(_ command: Command, at tick: Tick) {
        if tick <= currentTick {
            _ = applyNow(command, sequence: nil)
        } else {
            scheduled[tick, default: []].append(command)
        }
    }

    /// 命令落在"渲染线程还没消费的最早一拍"。
    private func applyNow(_ command: Command, sequence: UInt64?) -> CommandReceipt {
        let rendered = renderedTickValue.load(ordering: .acquiring)
        let target = rendered == Int64.min ? currentTick : max(currentTick, Tick(rendered + 1))
        if target > currentTick { prepare(upTo: target) }
        let before = current
        current = reducer.reduce(current, command, at: target)
        if let sequence {
            lastSequence = sequence
            let receipt = CommandReceipt(sequence: sequence, appliedTick: target)
            receipts[sequence] = receipt
            applied.append(sequence)
            trimHistory()
        }
        emitEvents(from: before, to: current, tick: target)
        // 每条命令都发布一个新快照（即使被拒、状态没变）：快照的 sequence 就是"已处理到哪条命令"，API / WS 靠它确认
        publish()
        return CommandReceipt(sequence: sequence ?? lastSequence, appliedTick: target)
    }

    private func trimHistory() {
        guard applied.count > options.historyLimit else { return }
        let drop = applied.count - options.historyLimit
        for seq in applied.prefix(drop) { receipts.removeValue(forKey: seq) }
        applied.removeFirst(drop)
    }

    // MARK: 拍

    /// 把状态逐拍推进到第 tick 拍（含）：每拍先 advance 再应用该拍的排程命令，最后发布快照。
    /// 通常由执行器线程在渲染线程 `requestPrepare` 之后调；测试可直接 await。
    public func prepare(upTo tick: Tick) {
        guard tick > currentTick else { return }
        var t = currentTick + 1
        while t <= tick {
            let before = current
            current = reducer.advance(current, to: t)
            currentTick = t
            for observer in tickObservers { observer.stateMachine(self, willApplyTick: t) }
            if let commands = scheduled.removeValue(forKey: t) {
                for c in commands { current = reducer.reduce(current, c, at: t) }
            }
            emitEvents(from: before, to: current, tick: t)
            t += 1
        }
        publishIfChanged()
    }

    /// 空闲拍不发布新对象（渲染线程按 preparedTick 判断新旧），只有状态变了才换指针。
    private func publishIfChanged() {
        if current != publishedState { publish() } else { preparedTickValue.store(currentTick.rawValue, ordering: .releasing) }
    }

    private func publish() {
        publishedState = current
        publisher.publish(MixerSnapshot(state: current, sequence: lastSequence, tick: currentTick))
        preparedTickValue.store(currentTick.rawValue, ordering: .releasing)
    }

    // MARK: 事件

    private func emitEvents(from before: MixerState, to after: MixerState, tick: Tick) {
        guard !sinks.isEmpty else { return }
        for event in Self.events(from: before, to: after, tick: tick) {
            for sink in sinks { sink.stateMachine(self, didEmit: event, afv: after.audio.afv) }
        }
    }

    /// 由前后状态推导转场事件。
    static func events(from b: MixerState, to a: MixerState, tick: Tick) -> [TransitionEvent] {
        var out: [TransitionEvent] = []
        let wasActive = b.transition.isActive, isActive = a.transition.isActive
        let swapped = a.program == b.preview && a.preview == b.program && a.program != b.program
        if wasActive && !isActive {
            if swapped {
                out.append(.completed(tick: tick, from: b.program, to: a.program))
            } else if a.program != b.program {
                out.append(.cut(tick: tick, from: b.program, to: a.program))
            } else {
                out.append(.cancelled(tick: tick))
            }
        } else if !wasActive && isActive {
            out.append(.started(tick: tick, type: a.transition.type, durationTicks: a.transition.durationTicks,
                                from: a.program, to: a.preview, source: a.transition.source))
        } else if !isActive && a.program != b.program {
            out.append(.cut(tick: tick, from: b.program, to: a.program))
        }
        return out
    }
}
