# 022 输出统计补字段：`Stats.encoder[].uptime_s` / `disconnects` / `last_error`（顺带：`attempt`、顶层 `video_delay_ms`）

提出会话 / 分支：P5（prompt 99）/ `p5-contracts`；来源 docs/ui-study/01a 第 5 节候选 5、E10 / L11、04 Q13（用户按落地方案 §8.5 默认 (a)）、R7-E6；读数方归 prompt 101（推流状态面板、底栏时长），顺带两项分别来自 W5-B §4 第 1 条（G6 追加）与 prompt 105 交付 4
状态：**已落地**（P5-2 / prompt 108，2026-10-11，提交 9adf144；文字 9ecc22a）。原状态：**已批**（用户 2026-10-11 看完 reports/G8.md 后原话"提案 020 / 021 / 022 / 023 二–五落地"，没批注——"请用户定的点"每条按本提案写的默认；落地归 P5-2，prompt 108，分支 `p5-contracts-2`。原状态行：（批了由 P5 落契约 + 填数方 + StatsWriter / StatsSummary + 测试标准 §7 字段表；App 把起不来的原因填进 last_error 归 101 或 App 胶水；`video_delay_ms` 的填数归 105）

## 改什么

### A. `Stats.EncoderEntry` 三个字段（提案正文）

| JSON 键 | 类型 | 含义 | 填数方 | 缺键 |
|---|---|---|---|---|
| `uptime_s` | number（秒） | 这一路**本次运行**的时长 = 现在 − `start()` 成功那一刻（host time 差）；推流含握手 / 退避 / 重连期间（"运行着"就算，与 state 一起看）；idle / stopped / failed 写 0 | 录制 `Recorder`（startedAt）、推流 `StreamOutput`（startedAt）、NDI `NDISender`（startedAt） | 0 |
| `disconnects` | integer（累计） | 推流连上之后掉线 / 停滞被判断线的次数，自启动累计（`StreamCounters.disconnects` 已有）；录制 / NDI 写 0 | `StreamCounters.statsEntry` | 0 |
| `last_error` | string | 最近一次错误的文案，空串 = 没出过错；推流 = 最近一次断线 / 连接失败的原因（`ExitReason` / 连接错误的描述）或 failed 的原因；录制 = `State.failed(String)` 的文案或 writer 失败的原因；NDI = SDK 不在 / initialize / send_create 失败的文案；**下一次 `start()` 清空**（与 019 的 `startFailed` 同口径） | 各输出的 `statsEntry`；起不来的路（`start()` 抛错，Stats 里报 failed）由组装方把原因填进去（App `OutputRuntime.failureReason`，W5-B §4 第 2 条） | "" |

`jsonKeys` 顺序：`["output", "skipped", "bitrate", "frames", "dropped", "disk_free_mb", "reconnects", "connections", "state", "uptime_s", "disconnects", "last_error"]`（新键排在 state 之后）。
显式 `init(from:)` 用 `decodeIfPresent`，写出总是写全；`StatsWriter.sanitized` 把非有限的 uptime 换 0；`Stats.EncoderEntry.init` 三个参数带默认值（现有调用点不改）。

### B. 顺带（请一并定，可单独批 / 驳）

| # | 字段 | 含义 | 来源 |
|---|---|---|---|
| B1 | `encoder[].attempt`（integer） | 推流**这一轮**连接是第几次尝试（`StreamState.connecting(attempt)` / `.backoff(attempt)` 的 attempt；在推 / 空闲 / 停止 = 0）。底栏"连接中 / 重连中（第 n 次）"现在读 App 运行表 `OutputRuntime.streamConnectAttempt`，API / stats.jsonl 看不到同一个数（铁律 4） | W5-B §4 第 1 条、G6 追加；录制 / NDI 写 0，缺键 0 |
| B2 | 顶层 `video_delay_ms`（number） | 当前为监听同步把视频延后的毫秒数（prompt 105 的 W1-B4：按总线效果链实测延迟延后派发；补偿方式 `audioPTS` 或没有效果时为 0）。105 先放 `EngineCounters`，字段按它的交付 4 归本提案 | prompt 105；填数归 105 / W1-B4，P5 只开字段、引擎没接之前写 0；缺键 0；`Stats.jsonKeys` 末尾加一项 |

### C. 汇总与文档

- `StatsSummary.DeliverySummary` 加可选 `uptimeS`（末行）、`disconnects`（末行 − 首行）、`lastError`（最后一个非空）、（B1）`lastAttempt`（末行）；`StatsSummary` 顶层加可选 `videoDelayMs`（序列，B2）。老基线 JSON 缺这些键解出来 nil（与 P2 的 `delivery` 同做法）。
- docs/spec/导播台测试标准.md §7 字段一行：`encoder[{…, state, uptime_s, disconnects, last_error(, attempt)}]`、顶层加 `video_delay_ms`，各一句含义；**不动阈值**。
- CONTRACTS.md §2.7（Stats 行、"P5 加的字段"一段）、Stats.swift 注释；docs/api.md 的 `GET /state` 样例里 `stats` 是省略号，不变（`switcher-apidoc` 重生成一次核对）。

## 为什么

- 铁律 4：时长、断线次数、最后错误只能有一份——推流状态面板 / 底栏"● 录制 hh:mm:ss" / ISO 表的时长列（E10 / L11 / K9）要显示它们，W5-B / W5-F / W5-G 都被 G6 / G7 拦下"别在 App 里按起始拍推算"；界面自己从 state 变化推算就是第二份数字（R7-E6），API 与测试看不到同一个数。
- `disconnects` 引擎已经在数（`StreamCounters.disconnects`，E8 / E9 的工装用它），只是没进 Stats；`reconnects` 只记成功的，断了没连回来的只有它能看出来。
- `last_error`：起不来的录制 / 推流路现在 Stats 报 failed 但没原因，原因文字只在 App 运行表里（W5-B §4 第 2 条）；鉴权失败的三种文案 W5-D 已经能区分（reports/w5-stream-auth.md §3 第 6 条），状态面板直接显示 StreamOutput 打的那行。
- 不做：SRT 连接统计（RTT / 丢包，R3b-G14）以后照同一路子加；`uptime` 不按"在推时长"（排除退避期）算，那是面板从 `state` 的变化记事件就能算出来的展示量（101 的事件记录），统计只记运行时长。

## 影响谁

| 谁 | 改什么 | 归谁 |
|---|---|---|
| SwitcherContracts（Stats.swift）+ 测试 | 三个（+ 顺带两个）字段、`init(from:)`、`jsonKeys`、键名快照（`testP1_stats_jsonKeysSnapshot` 的整行字面量重生成）、老 stats.jsonl 照读（`App/Tests/Artifacts/w2-app-status-line-stats.jsonl`、P2 / P3 用例里的老行） | P5 |
| SwitcherOutputs `Streaming/StreamOutput.swift` + `StreamCounters`、`Recording/Recorder.swift` + `RecordingStart.swift`（RecorderCounters）、`NDISend/NDISender.swift`（≤ 50 行胶水） | 记 startedAt / lastError（Mutex 里的值，非实时线程写）、`statsEntry` 填三个字段；`StreamOutput` 的 lastError 在断线 / 连接失败 / failed 处写、`start()` 清 | P5（NDISender 走胶水额度） |
| SwitcherTestKit `Stats/`（StatsWriter / StatsSummary）+ StatsTests | sanitize、汇总字段、老基线兼容 | P5 |
| Tools/switcher-headless | `EncoderStatsSource` 透传（各 statsEntry 自带，预计不改） | P5 |
| App `OutputRuntime` | 起不来的路把 `failureReason` 填进 `last_error`；底栏 / 推流页 / 状态面板改读 `uptime_s` / `disconnects` / `last_error` / `attempt` | 101（App 胶水若 ≤ 50 行也可由 P5 做 last_error 这一处） |
| 测试标准 §7 | 字段表加字段、一句含义，不动阈值 | P5（OWNERSHIP P5 行已授权） |
| 引擎（B2） | `EngineCounters.videoDelayMs` → Stats | 105 |

## 怎么迁移

- Stats 不在 Show 里，`schemaVersion` 无关；老 stats.jsonl / 老基线缺键解出 0 / "" / nil，写出总是写全。
- stats.jsonl 的消费者（`scripts/gate*-report.py`、`frameprobe`、StatsSummary）按键名取值，多出的键不影响。
- 不批的话：101 的状态面板只能显示现有的 state / bitrate / dropped / reconnects，时长 / 断线 / 原因按 G6 / G7 的裁定不许在 App 里另算，界面上那几格留空。

## 请用户定的点

1. A 的三个字段——批 / 驳。
2. B1 `attempt`——要不要带（底栏"第 n 次"从此读 Stats）。
3. B2 `video_delay_ms`——要不要在本提案里开字段（105 填数）。
4. `uptime_s` 的口径：本次运行时长（含重连期间，默认）还是"在推 / 在录"时长（排除退避期）？

## 落地记录（P5-2 / prompt 108，2026-10-11，提交 9adf144）

A 三字段 + B1 `attempt` + B2 顶层 `video_delay_ms` 全落了，四个"请用户定的点"按默认（uptime 含重连期）。`jsonKeys` = `[…, "state", "uptime_s", "disconnects", "last_error", "attempt"]`、顶层末尾 `video_delay_ms`；
显式 `init(from:)` 缺键 0 / "" / 0，写出写全；`EncoderEntry.init` 四个参数带默认值，`Stats.init` 的 `videoDelayMs` 带默认值，现有调用点一个没改。
一处比提案多说明的：**`attempt` 在退避期间 = 即将进行的那一次 = failures + 1**（`backoff(attempt: failures)` 里的数 + 1），与 App 底栏原来 `streamConnectAttempt` 的读法一致，connecting(n) = n，两段连续。

填数方：`RecorderCounters.uptimeSeconds / lastError`（`Recorder.counters` 按 startedAt 算，recording / stopping 之外 0；最近一次 `.failed` 的文案，start 清）；
`StreamOutput`（startedAt / lastError 各一个 Mutex：断线原因、连接失败、建传输层失败、放弃；新加 `statsEntry(counters:previous:windowSeconds:output:)` 让组装方用同一份快照）；
`StreamCounters.statsEntry` 填 `disconnects` / `attempt`（胶水 4 行）；`NDISendCounters.startedAt / lastError`（SDK 不在 / NDIlib_initialize / NDIlib_send_create 失败的文案；publishing 之外 uptime 0；胶水 13 行）；
`EngineCounters.swift` 的 `StatsAssembler` 填 `videoDelayMs: counters.videoDelayMs` 一行；headless `EncoderStatsSource` 推流改走 StreamOutput 的快照版 statsEntry、其余透传；
App `OutputRuntime`：起不来的路把 `failureReason` 填进 `last_error`（`Source.failed(directory:reason:)`，胶水 4 行）；界面改读 uptime_s / disconnects / last_error / attempt 归 101。
`StatsWriter.sanitized` 把非有限的 uptime_s / video_delay_ms 换 0；`StatsSummary.DeliverySummary` 多可选 `uptimeS / disconnects / lastError / lastAttempt`，顶层多可选 `videoDelayMs` 序列，老基线缺键解 nil（StatsSummary 没有 L1 判定，不用扣）。
测试标准 §7 字段表加字段与一句含义、§3 L1 行加一句（9ecc22a）；CONTRACTS.md §2.7 一段；Stats.swift 注释。
用例：`Contracts022Tests`（3 条，含 App 的老 stats.jsonl 照读）、`CodableTests.testP1_stats_jsonKeysSnapshot` / `StatsP2Tests` / `Contracts019Tests` 字面量重生成、
headless 的 `Contracts022FillTests`（5 条：RecorderCounters / StreamCounters / NDISendCounters 的 statsEntry、NDISender 干跑起一次、StatsSummary 新字段 + 老摘要 + StatsWriter 清洗）。
