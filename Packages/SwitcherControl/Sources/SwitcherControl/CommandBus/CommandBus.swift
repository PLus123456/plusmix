import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

// 命令总线（设计方案 §9.1、§12 决策 3；CONTRACTS.md §2.6）：UI、快捷键、MIDI、API、脚本都从这里进，不直接碰状态机。
//
// 每条命令：结构校验（CommandValidator，引用不存在的输入 / 输出等直接拒绝，给 API 一个 400 的理由）→ 分配全局单调 sequence
// → 记 issuedAt（host time）→ `StateMachine.submit(IssuedCommand)` → 拿回执（appliedTick = 画面生效的拍）→ 通知观察者。
//
// 并发：多个任务同时 submit 时，sequence 由原子量分配，投进 actor 的先后可能与 sequence 相反；状态机把早到的高序号排队，
// 等低序号进来后连带按序应用（`SubmitOutcome.queued`），这里再从回执历史里把自己的取回来。所以两个客户端并发也是
// 全局一个顺序（C4）。一台状态机只配一条总线：状态机的 nextSequence 从 1 起，总线的计数器也从 1 起。

/// 命令来源。
public enum CommandSource: String, Codable, Sendable, CaseIterable {
    case ui, hotkey, midi, api, script
}

/// 总线拒绝一条命令的原因（结构性错误，状态机不会收到它）。
public struct CommandRejection: Error, Hashable, Sendable, CustomStringConvertible {
    /// 给人看的一句话。
    public var reason: String
    /// 被拒的命令。
    public var command: Command
    public init(reason: String, command: Command) {
        self.reason = reason
        self.command = command
    }
    public var description: String { reason }
}

/// 总线的运行错误（不是命令本身的问题）。
public enum CommandBusError: Error, Equatable {
    /// 状态机说这个 sequence 已经处理过：只会在一台状态机挂了两条总线时发生。
    case staleSequence(UInt64)
}

/// 一条走完总线的命令的记录。
public struct CommandLogEntry: Hashable, Sendable, Codable {
    public var sequence: UInt64
    /// 进总线的时刻（host time）。
    public var issuedAt: HostTime
    public var source: CommandSource
    public var command: Command
    /// 生效的拍。
    public var appliedTick: Tick
    /// 回执回到总线的时刻（host time）；appliedAt − issuedAt 是总线 + 状态机的处理耗时。
    public var appliedAt: HostTime
    public init(sequence: UInt64, issuedAt: HostTime, source: CommandSource, command: Command, appliedTick: Tick, appliedAt: HostTime) {
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.source = source
        self.command = command
        self.appliedTick = appliedTick
        self.appliedAt = appliedAt
    }
}

/// 命令应用后的观察者（状态推送挂这里）。在提交方的任务上、回执返回前同步调用，要快。
public protocol CommandBusObserver: AnyObject, Sendable {
    func commandBus(_ bus: CommandBus, didApply entry: CommandLogEntry)
}

/// 命令总线。
public final class CommandBus: Sendable {
    /// 计数（诊断用；正式指标在 Stats，铁律 4 只管 stats.jsonl 那些字段，这里是总线自己的账）。
    public struct Counters: Hashable, Sendable {
        public var submitted: UInt64 = 0
        public var applied: UInt64 = 0
        public var rejected: UInt64 = 0
        /// 到达 actor 时前序还没到、排过队的条数。
        public var queued: UInt64 = 0
    }

    public let stateMachine: StateMachine
    /// 是否做结构校验（关掉则一切交给 reducer 静默处理）。
    public let validates: Bool
    private let sequenceCounter = Atomic<UInt64>(0)
    private let submittedCount = Atomic<UInt64>(0)
    private let appliedCount = Atomic<UInt64>(0)
    private let rejectedCount = Atomic<UInt64>(0)
    private let queuedCount = Atomic<UInt64>(0)
    private let observers = Mutex<[any CommandBusObserver]>([])
    private let log = Mutex<RingLog>(RingLog(capacity: 256))

    public init(stateMachine: StateMachine, validates: Bool = true) {
        self.stateMachine = stateMachine
        self.validates = validates
    }

    /// 最近分配出去的 sequence（0 = 还没有）。
    public var lastSequence: UInt64 { sequenceCounter.load(ordering: .acquiring) }

    public var counters: Counters {
        Counters(submitted: submittedCount.load(ordering: .relaxed), applied: appliedCount.load(ordering: .relaxed),
                 rejected: rejectedCount.load(ordering: .relaxed), queued: queuedCount.load(ordering: .relaxed))
    }

    /// 最近的记录（按 sequence 升序，最多 256 条）。
    public func recentEntries(limit: Int = 256) -> [CommandLogEntry] {
        log.withLock { Array($0.entries.suffix(limit)) }
    }

    public func addObserver(_ observer: any CommandBusObserver) {
        observers.withLock { $0.append(observer) }
    }

    public func removeObserver(_ observer: any CommandBusObserver) {
        observers.withLock { list in list.removeAll { $0 === observer } }
    }

    /// 提交一条命令。结构性非法的抛 `CommandRejection`；否则返回状态机的回执。
    public func submit(_ command: Command, source: CommandSource) async throws -> CommandReceipt {
        submittedCount.add(1, ordering: .relaxed)
        if validates, let snapshot = stateMachine.publisher.latest,
           let reason = CommandValidator.reason(rejecting: command, in: snapshot.state) {
            rejectedCount.add(1, ordering: .relaxed)
            throw CommandRejection(reason: reason, command: command)
        }
        let sequence = sequenceCounter.add(1, ordering: .acquiringAndReleasing).newValue
        let issuedAt = HostClock.now()
        let issued = IssuedCommand(sequence: sequence, issuedAt: issuedAt, command: command)
        let receipt: CommandReceipt
        switch await stateMachine.submit(issued) {
        case .applied(let r):
            receipt = r
        case .queued:
            queuedCount.add(1, ordering: .relaxed)
            receipt = await waitForReceipt(sequence: sequence)
        case .stale:
            throw CommandBusError.staleSequence(sequence)
        }
        let entry = CommandLogEntry(sequence: sequence, issuedAt: issuedAt, source: source, command: command,
                                    appliedTick: receipt.appliedTick, appliedAt: HostClock.now())
        appliedCount.add(1, ordering: .relaxed)
        log.withLock { $0.append(entry) }
        let list = observers.withLock { $0 }
        for o in list { o.commandBus(self, didApply: entry) }
        return receipt
    }

    /// 前序命令的提交方还没进 actor；它进来时状态机会连带把本条应用掉，回执进历史。这里等它出现。
    private func waitForReceipt(sequence: UInt64) async -> CommandReceipt {
        while true {
            if let r = await stateMachine.receipt(forSequence: sequence) { return r }
            try? await Task.sleep(for: .microseconds(100))
        }
    }

    /// 定长环形记录。
    struct RingLog {
        let capacity: Int
        private(set) var entries: [CommandLogEntry] = []
        init(capacity: Int) { self.capacity = capacity; entries.reserveCapacity(capacity) }
        mutating func append(_ e: CommandLogEntry) {
            if entries.count >= capacity { entries.removeFirst(entries.count - capacity + 1) }
            entries.append(e)
        }
    }
}
