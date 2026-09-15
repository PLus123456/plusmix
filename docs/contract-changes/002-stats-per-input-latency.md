# 002 Stats.per_input 加 L1 内部延迟字段

提出会话 / 分支：W2-A / w2-inputs（worktree 分支 claude/w2-inputs-phase-one-2f34b3）
状态：待批

## 改什么

`Stats.PerInput`（Stats.swift；测试标准 §7 的 stats.jsonl 行 `per_input[n]`）：

现在：`per_input[n] = {fps, dup, drop}`
提议：`per_input[n] = {fps, dup, drop, latency_ms, latency_max_ms}`

| 键 | 类型 | 口径 |
|---|---|---|
| `latency_ms` | Double | 窗口内该输入的 L1 平均值（ms）：帧出现在编码器输入（引擎把 PGM 帧交给第一个 FrameConsumer 的那一刻）− 该帧的 `Frame.ingressTime`。只算"这一拍第一次用到的帧"（同一帧因帧率转换被重复使用的拍不算，那是设计内重复不是延迟）。窗口内没有样本写 0 |
| `latency_max_ms` | Double | 同口径的窗口最大值 |

## 为什么

- W2-A prompt 第 6 条："每种输入的 L1 打点：Frame.ingressTime 在进帧槽时填，引擎送编码器时记差（Stats.per_input 字段不够就写契约提案）"。
  输入侧的 `ingressTime` 已经按契约填了；"记差"要在引擎里做（只有引擎知道第 n 拍用了哪一帧、第 n 拍的 PGM 什么时候交给了编码器），
  结果没有地方放——`Stats.PerInput` 只有 fps / dup / drop。
- 铁律 4：所有数字进 Stats，UI / API / 测试三方读同一个结构。L1 是测试标准 §1 的正式指标（§4 阈值 ≤ 3 帧 / 目标 ≤ 2 帧，按输入类型分别报），
  没有 Stats 字段就只能像 W2-A 现在这样在探针 / 测试里另算（`SwitcherInputsHarness.LatencyFrameSlot` + `LatencyConsumer`），UI 和 API 看不到。

## 引擎侧怎么算（给 W1-B / G3 参考，不是契约的一部分）

- `Engine.programClock(_:tick:ideal:wake:)` 挑帧后已经把每路的 Frame 放进 `RenderInputTable`；同时把 `(tick, ingressTime, sequence)` 按
  `tick & 255` 写进一个每路 256 项的预分配环（三个原子量数组，渲染线程零分配）。序号与上一拍相同 = 重复帧，标记不计。
- `renderer(_:didComplete:)`（GPU 完成回调线程）在调第一个消费者之前取 `now`，按 `frame.tick` 查每路的环：新帧就把 `now − ingressTime`
  累加进 `EngineCounters`（每路 sum / count / max 三个原子量），`StatsAssembler` 每秒算窗口平均与最大值，读后清零。
- 没有消费者时（纯显示）口径不变：仍以"派发那一刻"为准。
- W2-A 的 `SwitcherInputsHarness/LatencyFrameSlot.swift` 就是这个算法的包外实现，可以直接搬进 Engine。

## 影响谁

- `Stats.swift`：`PerInput` 加两个字段 + `CodingKeys` + `jsonKeys`；`SwitcherContractsTests` 的键快照要更新。
- W1-A `StatsWriter` / `StatsSummary`（多两列；`StatsSummary` 可以顺手给 L1 出 avg / max 汇总）、`Tools/frameprobe` 的 stats 汇总（如果读 per_input）。
- W1-B `Engine` / `EngineCounters` / `StatsAssembler`：按上面的算法填。
- W2-B App 状态行 / 输入缩略图可以显示每路 L1；W2-C API 自动带出。
- 老 stats.jsonl：新字段 `decodeIfPresent` 默认 0，否则 G2 的记录读不回来。基线表（baselines/）不受影响。

## 怎么迁移

- Show 文件 schemaVersion 不动（Stats 不在 Show 里）。
- 写出时总是写全；读入缺字段给 0。
- 不批的话：L1 继续只由 W2-A 的探针 / 测试报（`switcher-input-probe run`），Stats 里没有，UI / API 看不到，S1 长稳时也没有逐秒 L1 记录。
