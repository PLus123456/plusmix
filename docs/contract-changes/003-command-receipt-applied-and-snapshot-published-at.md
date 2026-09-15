# 003 CommandReceipt.applied、MixerSnapshot.publishedAt、issuedAt 的口径；附：状态机的快照观察者与 Stats 发布器（引擎接口，非契约）

提出会话 / 分支：W2-C / w2-control（worktree 分支 claude/w2-control-command-bus-api-8f81c2）
状态：**已落地**（用户 2026-09-15 先同意按 W2-C 的想法来，再指示"提案 003 你直接落地吧，改契约和状态机"；W2-C 在 w2-control 分支提交 `契约 + 状态机：落地提案 003`）。
A / B / C 在 SwitcherContracts（Command.swift、MixerState.swift、CONTRACTS.md），D1 / D2 在 SwitcherEngine（StateMachine.swift、Engine/StatsPublisher.swift），
下游 SwitcherControl / headless / scripts/apitest 已跟上。其他 W2 分支合并时不用改代码：加的都是带默认值的字段和新类型，
只有直接比较 `CommandReceipt` 相等或钉回执 JSON 字面量的测试会红（本仓库只有 SwitcherContractsTests.CodableTests 一处，已改）。
下面是当时的提案原文（落地的形态与之一致）。

## 改什么

### A. `CommandReceipt` 加 `applied: Bool`（Command.swift）

```swift
public struct CommandReceipt: Hashable, Codable, Sendable {
    public var sequence: UInt64
    public var appliedTick: Tick
    /// 状态是否真的变了。false = reducer 按规则忽略了它（转场进行中再 fade、FTB 目标已相同、mute 已是该值……），状态原样。
    public var applied: Bool
    public init(sequence: UInt64, appliedTick: Tick, applied: Bool = true) { … }
}
```

- `StateMachine.applyNow`（SwitcherEngine）已经有 `before` 和 `current`：`applied = before != current`（MixerState 是 Hashable，一次比较；8 路输入的状态几 KB，每条命令一次，可以接受；要省的话比 program / preview / transition / ftb / overlays / audio / outputs 各字段的哈希也行）。
- Codable：`decodeIfPresent(Bool.self, forKey: .applied) ?? true`，老的 JSON 读得回来（回执不落盘，只是保险）。
- 现在的困境：API 对"语义上被忽略"的命令只能回 200 + appliedTick，客户端分不清"生效"和"被忽略"（reports/w2-control.md §4 第 3 条）。结构性非法已在总线入口 400，这条补的是剩下那一类。

### B. `MixerSnapshot` 加 `publishedAt: HostTime`（MixerState.swift）

```swift
public final class MixerSnapshot: Sendable {
    public let state: MixerState
    public let sequence: UInt64
    public let tick: Tick
    /// 状态机发布这个快照的时刻（host time）。
    public let publishedAt: HostTime
    public init(state: MixerState, sequence: UInt64, tick: Tick, publishedAt: HostTime = .now()) { … }
}
```

- `StateMachine.publish()` 传 `HostClock.now()`；其他构造点用默认值即可。
- 用途：C2 的"纯传输"口径现在用推送线程序列化时刻 `sentAt`（比发布晚几十微秒到一拍不等——推送线程要等 `preparedTick` 追上）；有了 `publishedAt`，`SnapshotMessage` 加同名字段，客户端能算"状态机发布 → 客户端"的真延迟。App 的主线程分发（W2-B 每秒最多 60 次合并）也能用它量"快照到 UI"。

### C. `IssuedCommand.issuedAt` 的口径（只改注释：Command.swift + docs/CONTRACTS.md §2.6）

现在注释写"发出时刻（host time）。C1 命令延迟 = 生效拍点时刻 − issuedAt"。实际只能是**进总线的时刻**（服务端 host time）：HTTP / WS 请求里没有客户端时间戳，也不该信它。建议改成：

> `issuedAt`：命令进总线的时刻（服务端 host time）。`生效拍点时刻 − issuedAt` 是"服务端收到 → 生效"；C1 的客户端侧口径（客户端发出 → 画面生效）由客户端自己记发送时刻（scripts/apitest），比它多一个单程网络延迟（本机 ≈ 0.15 ms）。

### D. 引擎接口补充（SwitcherEngine，不是契约；W1-B 或 G3 的 ≤ 50 行胶水）

**D1. `StateMachine` 的快照观察者。** 现在状态机只有 `TickObserver`（advance 之后、发布之前）和 `TransitionEventSink`（只报转场），没有"快照已发布"的观察点；W2-C 的 `StateFeed` 用 TickObserver + 总线观察者 + `preparedTick` 追赶拼出来，能用但绕。建议：

```swift
/// 快照发布观察者：每次 publish 之后在状态机线程上同步调（不是实时线程，但要快）。
public protocol SnapshotObserver: AnyObject, Sendable {
    func stateMachine(_ machine: StateMachine, didPublish snapshot: MixerSnapshot)
}
// StateMachine：
private var snapshotObservers: [any SnapshotObserver] = []
public func addSnapshotObserver(_ o: any SnapshotObserver) { snapshotObservers.append(o) }
public func removeSnapshotObserver(_ o: any SnapshotObserver) { snapshotObservers.removeAll { $0 === o } }
private func publish() {
    publishedState = current
    let snapshot = MixerSnapshot(state: current, sequence: lastSequence, tick: currentTick)
    publisher.publish(snapshot)
    preparedTickValue.store(currentTick.rawValue, ordering: .releasing)
    for o in snapshotObservers { o.stateMachine(self, didPublish: snapshot) }
}
```

落地后 `StateFeed` 只挂这一个观察者（把 `MixerSnapshot` 放进它的信箱，推送线程直接编码），删掉 preparedTick 追赶那段；App 的主线程分发也挂它。

**D2. Stats 发布器。** 铁律 4 的"只有一份"现在靠约定：谁采样谁把同一行灌给 StatsWriter / UI / `StateFeed.publish(stats:)`（headless 是 StatsWriter 的采样闭包顺手推；App 那边 G3 接线时要保证状态行、jsonl、API 是同一次 `engine.makeStats()` 的结果）。建议 Engine 提供：

```swift
/// 每秒一行 Stats 的唯一来源：一条采样线程调 engine.makeStats()，扇出给所有消费者。
public final class StatsPublisher: Sendable {
    public init(engine: Engine, interval: TimeInterval = 1)
    public func addConsumer(_ consumer: @escaping @Sendable (Stats) -> Void)   // StatsWriter.submit、UI 状态行、StateFeed.publish(stats:)
    public func start() / stop()
    public var latest: Stats?
}
```

headless 的 `StatsWriter.startSampling` 那条采样线程可以直接改成它的一个消费者（W1-A 的 StatsWriter 本身不用动）。

## 为什么

- A：API 用户（Stream Deck / Companion 模块）要知道按钮按下有没有效果；现在只能靠再 GET 一次状态比对。
- B：C2 的定义是"状态变化 → 客户端收到"，状态变化的准确时刻只有状态机知道。
- C：契约注释和实际口径对不上，测试标准 §1 C1 的两种读法要写清楚。
- D1：三处（API 推送、App 主线程分发、将来的 vMix 兼容层 / TSL tally）都需要"快照发布"事件，各自拼一遍不如状态机给一个钩子。
- D2：Stats 三方同一份是铁律，靠约定迟早被打破。

## 影响谁

- A：`Command.swift`、`SwitcherContractsTests` 的回执快照测试；SwitcherEngine `StateMachine.applyNow`；SwitcherControl 的 `CommandResponse` / `ReceiptMessage` / docs/api.md（加一个字段 + 一个测试）。
- B：`MixerState.swift`；SwitcherEngine `StateMachine.publish`；SwitcherControl `SnapshotMessage`（加 `publishedAt`）；scripts/apitest 的 C2 多一列。
- C：只改注释和 CONTRACTS.md。
- D：SwitcherEngine；SwitcherControl `StateFeed`（简化）；headless / App 接线。

## 怎么迁移

- A / B 都是加字段带默认值，源码兼容；JSON 里多一个键，老客户端忽略即可。Show 文件不含这两个类型，schemaVersion 不动。
- 落地顺序建议：契约会话改 A / B / C → W1-B（或 G3 胶水）改 StateMachine（applied、publishedAt、D1）→ W2-C 分支 rebase 后把 `CommandResponse` / `SnapshotMessage` / `StateFeed` 跟上（每处几行，测试已有骨架）。
- 不批 D2 的话：G3 接 App 时按 reports/w2-control.md §5 第 1 条保证三方同一行。
