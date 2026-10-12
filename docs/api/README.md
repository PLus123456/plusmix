# 本地 API

PlusMix 的官方控制接口：HTTP + WebSocket，JSON。Stream Deck 插件、MIDI 之外的一切外部控制都对着它写（[设计方案 §9.2](../spec/导播台设计方案.md)）。
它和界面、快捷键发的是**同一套命令**，读的是**同一份状态和统计**，所以任何一处改了状态，其他地方立刻一致。

| 文档 | 内容 |
|---|---|
| 本页 | 端点、鉴权、时间戳、WebSocket 事件格式、`stats` 字段、错误 |
| [命令参考 ../api.md](../api.md) | **从 `Command` 枚举生成**的 42 条命令：含义、参数、JSON 样例（`swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`，单元测试钉住它与代码一致） |
| [示例](examples.md) | curl、Python（只用标准库）、Bitfocus Companion |
| [第三方 API 兼容层](vmix-compat.md) | 让为别家导播软件写的控制面板配置直接可用：法律提示、开关、按 Companion 动作列的覆盖表 |

## 1. 地址与鉴权

- App：设置 › 远程控制 › 本地 API（默认开，`127.0.0.1:8765`）："谁能连"选仅本机 / 允许局域网（= `0.0.0.0`），端口、Token，页上显示别的机器该连的地址；要具体地址在 设置 › 高级 填 host:port；改了点窗口底部"应用并重起引擎"。启动参数 `--api-listen host:port`、`--api-token <token>`、`--no-api`（只管这一次运行）。
- 无界面引擎：`switcher-headless run … --api [--api-listen 0.0.0.0:8765] [--api-token <token>]`。
- 鉴权默认关。设了 token 之后每个请求带 `Authorization: Bearer <token>`，WebSocket 也可以用 `?token=<token>`，否则 401。
- 只在需要时监听 `0.0.0.0`：API 能改任何状态，没有 token 就等于局域网里谁都能切你的节目。

## 2. 时间戳

所有时间戳都是 host time——`mach_absolute_time()` 的原始 tick 数（UInt64）。换算纳秒用 `hello` / `state` 里的 `timebase`：`ns = ticks × numer / denom`。
客户端在同一台 Mac 上可以直接与自己的 `mach_absolute_time()` 相减（[示例](examples.md#2-python)里的 Python 客户端就是这么量延迟的）。

## 3. HTTP 端点

| 方法 路径 | 用途 | 应答 |
|---|---|---|
| `GET /api/v1/state` | 全量状态 + 派生的 tally + 最近一行统计 | `{version, now, timebase, clock, sequence, tick, tickTime, publishedAt, state, tally, stats}` |
| `POST /api/v1/command` | 发一条命令 `{"command": <Command>}`（也接受直接放 `<Command>`），或一批 `{"commands": [<Command>, …]}` | 回执 `{sequence, appliedTick, applied, issuedAt, appliedTickTime}`；批量 `{"receipts": [...]}` |
| `GET /api/v1/commands` | 命令目录（[命令参考](../api.md)的机器可读版） | `{"commands": [{kind, group, summary, parameters, example}, …]}` |
| `GET /api/v1/log?limit=256` | 最近走过总线的命令（诊断） | `{"entries": [{sequence, issuedAt, source, command, appliedTick, applied, appliedAt}, …]}` |
| `GET /api/v1/tally` | 给面板轮询的小应答 | `{sequence, tick, program, preview, tally: {"1": {program, preview}, …}}` |

- `state` 的键名与节目文件一致（`MixerState` 原样）：`format / inputs / program / preview / transition / ftb / overlays / audio / outputs`。
- `tally` 由快照推导（全系统只算这一处）：在 PGM、或转场进行中在 PVW、或某个可见的叠加通道用了它 → `program: true`；在 PVW → `preview: true`。FTB 不改变 tally。
- `clock` 在引擎没起时钟时是 `null`；`stats` 在还没采到第一行时是 `null`。

### 回执

```json
{"sequence": 43, "appliedTick": 3601, "applied": true, "issuedAt": 123456100, "appliedTickTime": 123456700}
```

- `sequence`：全局序号，严格递增、无空洞；`appliedTick`：命令生效的拍（切换永远落在拍点边界），`appliedTickTime` 是那一拍的理想时刻。
- `applied = false`：状态机按规则忽略了它（转场进行中再发 fade、**转场进行中的 `setPreview` / `setProgram`**（T-bar 推到一半也算进行中）、FTB 目标已相同、mute 已是该值……），状态原样，**仍是 200**。回执不说原因：要区分"转场中被拒"看快照的 `transition.isActive`。
- 批量按顺序执行、sequence 连续（`setPreview` + `cut` 一次发就是一次"选 + 切"）；第 `index` 条被拒时 `400 {"error", "index", "receipts": [前面已生效的]}`。
  **转场进行中**这样发：`setPreview` 被状态机忽略（`applied = false`、仍是 200），`cut` 把正在进行的那次做完，PGM 落在原来那次的目标上、不是 n——看每条回执的 `applied`，或先等 `transition.isActive` 变回 false。

### 错误

| 状态码 | 什么时候 |
|---|---|
| 400 | JSON 解析失败、命令结构错、引用不存在的输入 / 输出、通道越界、负时长；正文 `{"error": "<理由>"}` |
| 401 | 设了 token 而请求没带或带错 |
| 404 | 路径不存在 |

## 4. WebSocket `/api/v1/events`

连接后依次收到 `hello`、当前 `snapshot`、最近一行 `stats`（如有）；之后每次状态变化推一条 `snapshot`（每拍最多一条，同一拍内多条命令只发最终状态），每秒一条 `stats`。
推的是**整快照 + 版本号**，不是增量：丢一条也能自愈，客户端只要保存最近一条。

```json
{"type": "hello", "version": "0.1.0", "now": 123456789, "timebase": {"numer": 125, "denom": 3}, "clock": {"t0": 123000000, "frameDuration": {"numerator": 1, "denominator": 60}}}
{"type": "snapshot", "sequence": 43, "tick": 3601, "tickTime": 123456700, "publishedAt": 123456120, "sentAt": 123456150, "state": {…}, "tally": {"1": {"program": true, "preview": false}}}
{"type": "stats", "stats": {…}}
```

- `tickTime` = 快照生效那一拍的理想时刻；`publishedAt` = 状态机发布它的时刻；`sentAt` = 服务端序列化这条消息的时刻。三者与客户端收到时刻相减就是三种延迟口径（[测试标准](../testing/测试标准.md) C2：`收到 − tickTime` ≤ 50 ms）。
- 同一条连接上也能发命令：`{"id": 7, "command": <Command>}` → `{"type": "receipt", "id": 7, …}`；出错 `{"type": "error", "id": 7, "error": "…"}`。`id` 原样带回，可省略。
  批量 `{"id": 8, "commands": [...]}` → `{"type": "receipts", "id": 8, "receipts": [...]}`。
- 慢客户端：服务端每连接缓冲有限，跟不上时丢旧快照（下一条仍是完整状态）。

给外部 tally 设备用的只读流（`ws://host:8766/tally`、`GET /tally`，默认监听所有网卡；App 里在 设置 › Tally 打开，默认关）在 [docs/integrations/tally.md](../integrations/tally.md)。

## 5. `stats`：每秒一行的统计

`GET /api/v1/state` 的 `stats`、WebSocket 的 `stats` 事件、`--stats` 写出的 `stats.jsonl`、界面状态行，四处是**同一个结构**（[docs/CONTRACTS.md §2.7](../CONTRACTS.md) 是权威定义，本表是它的摘要）。
计数类字段（`missed_render`、`dup`、`drop`、`skipped`、`frames`、`dropped`、`reconnects`、`disconnects`、`dropouts`、`underruns`、`discontinuities`）都是**自启动累计**，相邻两行相减得每秒增量。

| 键 | 含义 |
|---|---|
| `ts` | Unix 秒 |
| `tick` | 采样时的拍号 |
| `render_ms` | 窗口内"拍点 → GPU 完成"的平均毫秒（V1） |
| `missed_render` | 渲染没赶上而跳过的拍数累计（V2） |
| `jitter_ms` | 窗口内渲染线程唤醒时刻 − 理想拍点的最大值（V3） |
| `per_input{n: {fps, dup, drop, latency_ms, latency_max_ms}}` | 每路输入：窗口内推入帧数 / 秒；同一帧被合成两次以上的累计；到达但从未被合成的累计；窗口内内部延迟（入口打戳 → 交给第一个消费者）的平均 / 最大毫秒 |
| `encoder[]` | 每个编码类输出一项：`output`（输出编号，0 = 填数方没给）、`skipped`（编码器跟不上而丢的帧，E1）、`bitrate`（窗口平均 bit/s）、`frames`（写进文件 / 交给传输层的帧累计）、`dropped`（编码后落地前丢的：录制 = 写入器不接的，推流 = 网络丢帧 E9，NDI = 队列满丢的）、`disk_free_mb`（录制目录所在卷剩余 MB，非录制 0）、`reconnects`（推流重连成功次数）、`connections`（NDI 当前接收方数，其余 0）、`state`；
`uptime_s`（这一路本次运行了多少秒，从开始那一刻算，推流含握手 / 退避 / 重连期间；idle / stopped / failed 为 0）、`disconnects`（推流连上之后掉线的次数累计，录制 / NDI 为 0；断了没连回来的只在这里看得出）、`last_error`（最近一次错误的原文，空 = 没出过错，下一次开始时清空）、`attempt`（推流这一轮连接是第几次尝试，从 1 起；在推 / 空闲 / 停止时 0）——App 的底栏时长、"连接中 / 重连中（第 n 次）"和推流 / 录制状态窗都读这几个 |
| `encoder[].state` | 录制 idle / recording / stopping / stopped / failed；推流 idle / connecting / publishing / backoff / stopping / stopped / failed；NDI publishing / idle / **unavailable**（SDK 不在）/ **failed**（SDK 在但起不来） |
| `display[]` | 每个显示类输出一项（`output` 编号，主界面监视器用 0）：`kind` ∈ externalDisplay / virtualCamera / multiviewWindow / monitor；`frames` 已呈现 / 已送出累计；`dropped` 在呈现 / 发布时没赶上的；`undelivered` 不在呈现 / 发布（显示器不在、扩展没连上、窗口收起）时没送出去的；`state` ∈ idle / presenting / noDisplay / waitingExtension / publishing / stopped / failed |
| `audio{dropouts, underruns, discontinuities, meters}` | 输出回调超时累计、缓冲欠载累计、Master 流上相邻样本跳变 > 0.5 满幅的次数（流式启发式，信息项）；`meters.buses[{bus, peak_db, rms_db, true_peak_db, lufs_m, lufs_s, lufs_i, lra}]`（顺序 master / busA / busB / headphones，dB 下限 −120）、`meters.inputs{n: {peak_db, rms_db}}` |
| `rss_mb`、`cpu_pct`、`gpu_pct` | 进程常驻内存、进程 CPU、GPU 利用率（IOKit Device Utilization） |
| `video_delay_ms` | 采样那一刻为监听同步把视频延后的毫秒数（= Master 效果链的实测延迟；没开压缩 / 限幅为 0）。瞬时值，不累计 |

老文件缺键时按 0 / "idle" / 空解；写出总是写全。字段的正式口径与阈值在 [测试标准](../testing/测试标准.md)。

## 6. 几条命令的现行口径

[命令参考](../api.md) 由代码生成，只写命令的形态；下面几条是实现上的口径，写代码时会碰到：

- **转场进行中**（`transition.isActive`，T-bar 推到一半也算）`setPreview` / `setProgram` 被忽略（`applied = false`，PVW / PGM 不变）；`cut` 立即完成正在进行的转场。
- **转场槽**：`useTransitionSlot {slot, start}` 选中槽 n（`start: true` 同一拍开始 auto 转场 = 界面上点"转场 n"、⌥n；`false` = 只给 T-bar / 回车用），转场进行中被忽略；
  `setTransitionSlot` 改槽的整份配置，**转场进行中也收**（进行中的那一次按开始时的参数走完）；`autoTransition` / T-bar 用的是当前那组 = 当前槽（`transition.currentSlot`）。
  老命令 `fade` / `setTransition` / `setTransitionParams` 改的是当前那组，之后 `currentSlot` = 仍对得上的槽，对不上为 null。没选输入的 Stinger 槽 `start: true` 这一版照常开始（一次延迟的硬切）。
- **文件播放**：`setPlayback {input, paused}` 暂停 / 继续（画面停在那一帧，仍每拍出帧）；`seekPlayback {input, seconds}` 定位（暂停中定位就停在那一帧）；
  `settings.playback.restartOnProgram` 开着的文件输入在被切上 PGM 的那一拍从头播（首帧晚几拍）。只对文件输入有意义。
- **`setBusEffects`（总线效果链）已作用到声音**：
  - 链的顺序 = 处理顺序；连续的 `parametricEQ` 合成一格（一格最多 16 段），动态（`dynamicsProcessor` 或 `compressor` 二选一，第二个不装）、`peakLimiter` 各占一格；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格）。超出 3 格的、认不出的 `id` 不装（同一条只记一次日志）。
  - `enabled = false` = 旁路（输出逐样本等于输入），参数留着。
  - `parametricEQ.q` 是经典 Q（半增益处的带宽，q = √2 ≈ 1 个倍频程）。
  - 参数超出范围被钳：EQ 频率 20…23520 Hz、增益 −96…+24 dB、q 0.1826…28.85；`dynamicsProcessor` 阈值 −40…20 dB、起音 0.001…0.2 s；限幅起音 0.001…0.03 s、衰减 0.001…0.04 s、`ceilingDb` −20…0（`compressor` 的范围见下）。
  - 开了压缩 / 限幅的总线多 5–35 ms 处理延迟（`dynamicsProcessor` 恒 256 帧 = 5.3 ms，`compressor` 0，限幅 = 起音时长）。Master 的这段延迟（`video_delay_ms`）由**视频一起延后**来对齐：引擎按拍点 + 延迟派发画面，录制 / 推流 / NDI® 与 App 的监视器 / 外部显示 / 多画面都晚同样毫秒数，音频 PTS 不动、本机监听与画面同步（App 与无界面引擎的默认；无界面引擎 `--av-compensation audioPTS` 改回旧做法：音频 PTS 前移、画面不动、监听晚这么多）。Bus A / B 的延迟不补。
- **每路输入的效果链**（`setInputSettings` 的 `settings.effects`）**已作用到声音**：所有 `parametricEQ` 合成一格（最多 16 段，多的不装）+ 一个动态格（`compressor` 或 `dynamicsProcessor`，第二个不装），处理顺序固定先 EQ 后动态、与链里的先后无关；
  `peakLimiter` 与认不出的 `id` 每路不装（各记一次日志）。效果在这一路的对齐延迟线之前，延迟从这一路的对齐延迟里扣，节目时间线与 PTS 不动。
- **`compressor`**（自写压缩器，总线与每路都能装、与 `dynamicsProcessor` 二选一占同一格）：`thresholdDb`（−60…0）、`ratio`（1…20，n:1）、`kneeDb`（0…24，0 = 硬拐点）、`attackSeconds`（0.0001…0.2）、`releaseSeconds`（0.01…3）、`makeupGainDb`（0…24）；
  不用前瞻、按设计 0 延迟（装格 / 改参数时实测，量到的进对齐）；起音 / 释放是线性域峰值包络的一阶时间常数（不是 dB 域增益走到 63% 的时间，4:1 以上后者约为前者的一半）。App 的压缩页仍写 `dynamicsProcessor`。
- **监听同步**：见上面总线那一条；录制文件从这条延后的输出时间线的 0 起（开头没有黑帧）。
- **起不来的录制 / 推流路**：`stats.encoder[]` 里那一项报 `failed`（不是 `idle`），原因在那一项的 `last_error`（App 的界面提示与日志里也有）。

## 7. 版本

`hello.version` / `state.version` = PlusMix 版本（0.1.0）。API 路径带 `v1`；字段只加不删，加字段不升版本号，客户端按键名读、忽略不认识的键。
