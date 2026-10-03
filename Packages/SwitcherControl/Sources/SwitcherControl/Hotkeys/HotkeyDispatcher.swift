import Foundation
import Synchronization
import SwitcherContracts

// 快捷键派发：App（W2-B）在 keyDown 里 `KeyCombo(event:)` → `dispatcher.handle(combo)`；有绑定就解析动作（开关型看最新快照）
// 并投给总线（来源 hotkey），返回 true 表示这个键被吃掉了。派发是异步的（键盘事件在主线程，总线是 async）；测试用 handleAndWait。
// W5-J：一个动作可以是几条命令（组合动作，ControlAction.resolve 返回数组）——同一个任务里按顺序逐条 submit，前一条被拒就不发后面的
// （"选进 PVW 并转场"的 setPreview 被拒时，autoTransition 会把原来的 PVW 推上去）；界面动作（.ui）不进总线，交给 App 设的 handler。

/// 快捷键派发器。
public final class HotkeyDispatcher: Sendable {
    public struct Counters: Hashable, Sendable {
        public var handled: UInt64 = 0
        public var rejected: UInt64 = 0
        public var unresolved: UInt64 = 0
    }

    public let bus: CommandBus
    private let tableBox: Mutex<HotkeyTable>
    private let uiHandler = Mutex<(@Sendable (String) -> Void)?>(nil)
    private let handled = Atomic<UInt64>(0)
    private let rejected = Atomic<UInt64>(0)
    private let unresolved = Atomic<UInt64>(0)

    public init(bus: CommandBus, table: HotkeyTable = .default) {
        self.bus = bus
        tableBox = Mutex(table)
    }

    /// 当前表（可换）。
    public var table: HotkeyTable {
        get { tableBox.withLock { $0 } }
        set { tableBox.withLock { $0 = newValue } }
    }

    public var counters: Counters {
        Counters(handled: handled.load(ordering: .relaxed), rejected: rejected.load(ordering: .relaxed), unresolved: unresolved.load(ordering: .relaxed))
    }

    /// 界面动作（ControlAction.ui）交给谁：App 设（在调 handle 的线程上同步调，App 的键盘事件在主线程）；nil = 吃掉、什么都不做。
    public func setUIActionHandler(_ handler: (@Sendable (String) -> Void)?) {
        uiHandler.withLock { $0 = handler }
    }

    /// 解析组合键对应的命令（不投递；组合动作按顺序多条）。没绑定、解析不出、界面动作为空。
    public func commands(for combo: KeyCombo) -> [Command] {
        guard let action = table.action(for: combo) else { return [] }
        guard let state = bus.stateMachine.publisher.latest?.state else { return [] }
        return action.resolve(in: state)
    }

    /// 解析组合键对应的第一条命令（老调用方）。
    public func command(for combo: KeyCombo) -> Command? { commands(for: combo).first }

    /// 有绑定就异步投递并返回 true；没绑定返回 false（让事件继续传）。
    @discardableResult
    public func handle(_ combo: KeyCombo) -> Bool {
        guard let action = table.action(for: combo) else { return false }
        handled.add(1, ordering: .relaxed)
        if case .ui(let name) = action {
            uiHandler.withLock { $0 }?(name)
            return true
        }
        let commands = commands(for: combo)
        guard !commands.isEmpty else {
            unresolved.add(1, ordering: .relaxed)
            return true
        }
        Task { [bus] in
            do { _ = try await Self.submitInOrder(commands, to: bus, source: .hotkey) } catch { self.rejected.add(1, ordering: .relaxed) }
        }
        return true
    }

    /// 组合动作按顺序逐条进总线：前一条被拒（抛 CommandRejection）就停，后面的不发。返回已应用的回执。MIDI 走自己的派发 Task，口径相同。
    static func submitInOrder(_ commands: [Command], to bus: CommandBus, source: CommandSource) async throws -> [CommandReceipt] {
        var receipts: [CommandReceipt] = []
        for command in commands { receipts.append(try await bus.submit(command, source: source)) }
        return receipts
    }

    /// 同步版：等回执（测试 / 脚本用），组合动作给最后一条的回执。没绑定或解析不出返回 nil；结构性非法抛 CommandRejection。
    public func handleAndWait(_ combo: KeyCombo) async throws -> CommandReceipt? {
        try await handleAllAndWait(combo).last
    }

    /// 同步版：组合动作的每一条回执（按顺序）。没绑定、解析不出、界面动作返回空；某一条结构性非法就抛 CommandRejection、后面的不发。
    public func handleAllAndWait(_ combo: KeyCombo) async throws -> [CommandReceipt] {
        guard let action = table.action(for: combo) else { return [] }
        handled.add(1, ordering: .relaxed)
        if case .ui(let name) = action {
            uiHandler.withLock { $0 }?(name)
            return []
        }
        let commands = commands(for: combo)
        guard !commands.isEmpty else {
            unresolved.add(1, ordering: .relaxed)
            return []
        }
        do {
            return try await Self.submitInOrder(commands, to: bus, source: .hotkey)
        } catch {
            rejected.add(1, ordering: .relaxed)
            throw error
        }
    }
}
