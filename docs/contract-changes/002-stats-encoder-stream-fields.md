# 002 Stats.encoder 的推流 / NDI 字段（在 001 之上追加）

提出会话 / 分支：W2-D / w2-stream（worktree 分支 claude/w2-stream-output-089d47）
状态：**已批**（用户 2026-09-15）。由契约会话在 SwitcherContracts 里落地（和 001 一起改 Stats.swift），其他分支 rebase。
落地后各输出这样填：推流 `StreamCounters.statsEntry`（注释里写了映射：frames = framesSent、dropped = networkDropped、reconnects、state = state.name）；
NDI `NDISendCounters`（frames = framesSent、dropped = skipped、reconnects = 0、state = unavailable ? "unavailable" : "publishing"）；录制按 001。

## 改什么

`Stats.EncoderEntry`（Stats.swift，测试标准 §7 的 stats.jsonl 行）：

现在：`encoder[{skipped, bitrate}]`。
001 提议：`encoder[{skipped, bitrate, frames, dropped, disk_free_mb}]`。
本案再加：

| 键 | 类型 | 口径 |
|---|---|---|
| `reconnects` | UInt64 累计 | 推流重连成功次数（`StreamCounters.reconnects`）；录制 / NDI 写 0 |
| `state` | String | 输出的运行状态：`idle` / `connecting` / `publishing` / `backoff` / `stopping` / `stopped` / `failed` / `unavailable`（NDI SDK 不在）。UI 底栏和 API 都要显示它；prompt 要求"SDK 不在时在 Stats 里标 unavailable"，现在没有地方放 |

`dropped`（001）的口径对推流就是 E9 网络丢帧：`StreamCounters.networkDropped`（队列满 + 等关键帧 + 断线期间 + 断线丢弃 + 传输层估算未发出）。
`frames`（001）对推流 = `StreamCounters.framesSent`（交给传输层的帧），对 NDI = `NDISendCounters.framesSent`。

## 为什么

- 铁律 4：帧数 / 网络丢帧 / 重连次数 / 状态是 prompt 明确要求进 Stats.encoder[i] 的（W2-D 交付 1、交付 3），E7 / E8 / E9 的判定脚本读的就是它们；
  现在只能读 `StreamOutput.counters`，UI / API 拿不到同一份。
- `state`：底栏要显示"重连中（第 3 次，8 s 后）"和"NDI 不可用"，API 的客户端（Companion）也要它来做 tally 之外的告警。

## 影响谁

- `Stats.swift`（加两个字段 + CodingKeys + jsonKeys）、`SwitcherContractsTests` 的 jsonKeys 快照；
- W1-A StatsWriter / StatsSummary（多两列）；W1-B / G3 的 Stats 汇总（从 `StreamOutput.counters` / `NDISender.countersSnapshot` 填）；
- 老 stats.jsonl：`decodeIfPresent`，缺省 0 / "idle"。

## 怎么迁移

- Show 文件不变（Stats 不在 Show 里）。
- stats.jsonl：新字段缺省；写出时总是写全。基线表不受影响。
- 不批的话：推流的这些数字继续留在 `StreamCounters`（`StreamOutput.counters`），Stats.encoder[i] 只有 skipped / bitrate；
  G3 的 E7–E9 判定脚本要直接读 StreamOutput 的计数（headless 加一条 API 或日志），违反"三方读同一个结构"。

## 附：W2-D 对 001 的补充意见

- 001 的 `dropped` 建议改名 `network_dropped` 或在文档里写明"录制 = writer 不接的帧，推流 = E9 网络丢帧"，避免和 E1 的 skipped 混淆。
- `AudioBlockConsumer` 升契约（001 B）：W2-D 的 StreamOutput / NDISender 都实现了它，赞成；升的时候签名不要动。
