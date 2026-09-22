import Foundation
import Synchronization
import SwitcherContracts
import SwitcherEngine

/// 挂状态机的 SnapshotObserver：每次发布在状态机线程上只做一次 yield，给每个 TCP 连接一条自己的 AsyncStream（最新 64 条，慢的丢旧）。
final class SnapshotWatcher: @unchecked Sendable, SnapshotObserver {
    private let subscribers = Mutex<[UInt64: AsyncStream<MixerSnapshot>.Continuation]>([:])
    private let nextID = Atomic<UInt64>(0)

    func subscribe() -> (id: UInt64, stream: AsyncStream<MixerSnapshot>) {
        let id = nextID.add(1, ordering: .relaxed).newValue
        let (stream, continuation) = AsyncStream<MixerSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64))
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return (id, stream)
    }

    func unsubscribe(_ id: UInt64) {
        let c = subscribers.withLock { $0.removeValue(forKey: id) }
        c?.finish()
    }

    func finishAll() {
        let all = subscribers.withLock { s -> [AsyncStream<MixerSnapshot>.Continuation] in
            let v = Array(s.values)
            s.removeAll()
            return v
        }
        for c in all { c.finish() }
    }

    func stateMachine(_ machine: StateMachine, didPublish snapshot: MixerSnapshot) {
        subscribers.withLock { subs in
            for c in subs.values { _ = c.yield(snapshot) }
        }
    }
}
