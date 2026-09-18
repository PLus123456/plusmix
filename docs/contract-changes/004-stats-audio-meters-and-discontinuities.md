# 004 Stats.audio 的表读数与不连续计数

提出会话 / 分支：W2-E / w2-audio-integ（worktree 分支 claude/w2-audio-integ-00e60c）
状态：**已批**（用户 2026-09-18，按 G3 报告 §7 第 2 条）。由契约会话 P2（docs/plan/prompts/41）落地。

## 改什么

`Stats.AudioCounters`（Stats.swift，测试标准 §7 的 `audio{dropouts, underruns}` 一节）加字段：

现在：`audio{dropouts, underruns}`
提议：`audio{dropouts, underruns, discontinuities, meters}`

| 键 | 类型 | 口径 |
|---|---|---|
| `discontinuities` | UInt64 累计 | A1 的第三个加数：Master 消费者流上相邻样本跳变 > 0.5 满幅的次数（`SwitcherAudioIntegration.DiscontinuityDetector`，泵线程上算；合成信号的 click 按平台启发式排除，正式判定用已知 click 位置排除的离线口径） |
| `meters` | 对象 | 采样那一刻的表读数，见下 |

`meters`：
```
{
  "buses": [ {"bus": "master", "peak_db": [L, R], "true_peak_db": [L, R], "lufs_m": x, "lufs_s": x, "lufs_i": x, "lra": x}, … 4 条，顺序 = Bus.allCases ],
  "inputs": { "1": {"peak_db": [L, R]}, … 键 = 输入编号 }
}
```
峰值 / 真峰值 dBFS / dBTP（`20·log10`，下限 −120），响度 LUFS，LRA LU；来源只有一处：`AudioMixer.meters`（W1-D 的 seqlock 快照）。

## 为什么

- 铁律 4：所有数字进 Stats，UI / API / 测试三方读同一个结构。W2-B 的调音台占位明确写"Master 推子 + 表，读 Stats"（prompt 31 第 1 条）；
  W2-C 的 HTTP / WS API 与 SwitcherAudio 同层，看不到 `AudioEngine.status`，只能从 Stats 拿表；测试标准 A6 的表准确度也要能从 stats.jsonl 核。
- A1 的定义是"超时 + 欠载 + 不连续"三项之和，现在 Stats 只有前两项，第三项没地方放。
- W2-E 目前把这些数放在 `AudioEngineStatus`（集成层的快照，App 可以 import 直接读，每 50 ms 刷新——表要 10–30 Hz，1 Hz 的 Stats 只是留档 / API / 测试用），
  提案批了之后 `Engine.makeStats()` 的 `audioStatsProvider` 换成整个 `AudioCounters`，UI 高刷新率的表继续读 `AudioEngineStatus`。

## 影响谁

- `Stats.swift`（`AudioCounters` 加两个字段 + 嵌套类型 + CodingKeys + jsonKeys）、`SwitcherContractsTests` 的 jsonKeys 快照字面量。
- W1-A 的 StatsWriter / StatsSummary：多一节，摘要里可以给 Master 峰值 / LUFS 的 min / max。
- W1-B `Engine.audioStatsProvider` 的类型不变（还是 `Stats.AudioCounters`），只是内容多了。
- W2-E 的 `AudioEngine.audioCounters` 填全部字段（改动在集成层，不动 SwitcherAudio）。
- 与 001 一样：老 stats.jsonl 解码时新字段 `decodeIfPresent` 默认 0 / 空。

## 怎么迁移

- Show 文件 schemaVersion 不动。
- stats.jsonl：新字段可缺省；写出时总是写全。基线表不受影响（不比较表读数）。
- 不批的话：表读数只在 `AudioEngineStatus`（App 直接 import 集成层）与 W2-C 需要另开一条只读路径 —— 违反"三方读同一个结构"，需要你拍板；
  `discontinuities` 不进 Stats 的话 A1 的第三项只能在报告里手填。
