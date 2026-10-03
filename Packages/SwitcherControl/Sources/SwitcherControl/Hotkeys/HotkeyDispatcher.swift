import Foundation
import Synchronization
import SwitcherContracts

// 快捷键派发：App（W2-B）在 keyDown 里 `KeyCombo(event:)` → `dispatcher.handle(combo)`；有绑定就解析动作（开关型看最新快照）
// 并投给总线（来源 hotkey），返回 true 表示这个键被吃掉了。派发是异步的（键盘事件在主线程，总线是 async）；测试用 handleAndWait。

/// 快捷键派发器。
public final class HotkeyDispatcher: Sendable {
    public struct Counters: Hashable, Sendable {
        public var handled: UInt64 = 0
        public var rejected: UInt64 = 0
        public var unresolved: UInt64 = 0
    }

    public let bus: CommandBus
    private let tableBox: Mutex<HotkeyTable>
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

    /// 解析组合键对应的命令（不投递）。
    public func command(for combo: KeyCombo) -> Command? {
        guard let action = table.action(for: combo) else { return nil }
        guard let state = bus.stateMachine.publisher.latest?.state else { return nil }
        return action.resolve(in: state).first
    }

    /// 界面动作（ControlAction.ui）交给谁（App 设；红灯轮：只有签名）。
    public func setUIActionHandler(_ handler: (@Sendable (String) -> Void)?) {}

    /// 同步版、组合动作的每一条回执（红灯轮：只有签名）。
    public func handleAllAndWait(_ combo: KeyCombo) async throws -> [CommandReceipt] {
        try await handleAndWait(combo).map { [$0] } ?? []
    }

    /// 有绑定就异步投递并返回 true；没绑定返回 false（让事件继续传）。
    @discardableResult
    public func handle(_ combo: KeyCombo) -> Bool {
        guard table.action(for: combo) != nil else { return false }
        handled.add(1, ordering: .relaxed)
        guard let command = command(for: combo) else {
            unresolved.add(1, ordering: .relaxed)
            return true
        }
        Task { [bus] in
            do { _ = try await bus.submit(command, source: .hotkey) } catch { self.rejected.add(1, ordering: .relaxed) }
        }
        return true
    }

    /// 同步版：等回执（测试 / 脚本用）。没绑定或解析不出返回 nil；结构性非法抛 CommandRejection。
    public func handleAndWait(_ combo: KeyCombo) async throws -> CommandReceipt? {
        guard table.action(for: combo) != nil else { return nil }
        handled.add(1, ordering: .relaxed)
        guard let command = command(for: combo) else {
            unresolved.add(1, ordering: .relaxed)
            return nil
        }
        do {
            return try await bus.submit(command, source: .hotkey)
        } catch {
            rejected.add(1, ordering: .relaxed)
            throw error
        }
    }
}
