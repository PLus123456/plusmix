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
`uptime_s`（这一路本次运行了多少秒，从开始那一刻算，推流含握手 / 退避 / 重连期间；idle / stopped / failed 为 0）、`disconnects`（推流连上之后掉线的次数累计，录制 / NDI 为 0；断了没连回来的只在这里看得出）、`last_error`（最近一次错误的原文，空 = 没出过错，下一次开始时清空）、`attempt`（推流这一轮连接是第几次尝试，从 1 起；在推 / 空闲 / 停止 / failed 时 0）——App 的底栏时长、"连接中 / 重连中（第 n 次）"和推流 / 录制状态窗都读这几个 |
| `encoder[].state` | 录制 idle / recording / stopping / stopped / failed；推流 idle / connecting / publishing / backoff / stopping / stopped / failed；NDI publishing / idle / **unavailable**（SDK 不在）/ **failed**（SDK 在但起不来，或在发但连续 10 帧送不出去——送出去一帧回到 publishing，`last_error` 写原因、留到下一次开始） |
| `display[]` | 每个显示类输出一项（`output` 编号，主界面监视器用 0）：`kind` ∈ externalDisplay / virtualCamera / multiviewWindow / monitor；`frames` 已呈现 / 已送出累计；`dropped` 在呈现 / 发布时没赶上的；`undelivered` 不在呈现 / 发布（显示器不在、扩展没连上、窗口收起）时没送出去的；`state` ∈ idle / presenting / noDisplay / waitingExtension / publishing / stopped / failed |
| `audio{dropouts, underruns, discontinuities, meters}` | 输出回调超时累计、缓冲欠载累计、Master 流上相邻样本跳变 > 0.5 满幅的次数（流式启发式，信息项）；`meters.buses[{bus, peak_db, rms_db, true_peak_db, lufs_m, lufs_s, lufs_i, lra}]`（顺序 master / busA / busB / headphones，dB 下限 −120）、`meters.inputs{n: {peak_db, rms_db}}` |
| `audio.effects{buses[{bus, latency_ms, measured_latency_ms}], inputs{n: {latency_ms, measured_latency_ms}}}` | 采样那一刻各效果链的处理延迟（毫秒，瞬时值、不累计；提案 030）。有音频引擎时 `buses` 总是四条（master / busA / busB / headphones，没装效果 = 0；没有音频引擎的组装方写空表）；`inputs` 只列装了均衡或动态格的那几路（键 = 输入编号）。`latency_ms` = 链上打开的格的延迟之和（`dynamicsProcessor` 5.3 ms、限幅 = 起音，`compressor` 0）；`measured_latency_ms` 只在链里装着 `compressor` 时有（它装上 / 改参数时的冲激法自测，按设计 0），别的时候不写这个键。Master 那一条就是监听同步要补的那一段（实际延后了多少看 `video_delay_ms`） |
| `rss_mb`、`cpu_pct`、`gpu_pct` | 进程常驻内存、进程 CPU、GPU 利用率（IOKit Device Utilization） |
| `video_delay_ms` | 采样那一刻为监听同步把视频延后的毫秒数（= Master 效果链的实测延迟；没开压缩 / 限幅为 0，无界面引擎 `--av-compensation audioPTS` 或组装方没接视频延后时也是 0）。瞬时值，不累计 |

老文件缺键时按 0 / "idle" / 空解；写出总是写全。字段的正式口径与阈值在 [测试标准](../testing/测试标准.md)。

## 6. 几条命令的现行口径

[命令参考](../api.md) 由代码生成，只写命令的形态；下面几条是实现上的口径，写代码时会碰到：

- **输入编号 1–16**（`InputConfig.numberRange`，提案 032）：`addInput` 的编号不在 1–16（含 0 与负数）回 400"输入编号必须在 1–16 之间：<n>"；节目文件里有越界编号的整份不打开（`loadShow` 同样拒）。按编号取输入的命令遇到大于 16 的编号照旧回"输入 n 不存在"（越界的编号进不了状态；`setPreview` / `setProgram` 的 0 仍是黑场，负数回"输入编号不能为负：n"）。
- **转场进行中**（`transition.isActive`，T-bar 推到一半也算）`setPreview` / `setProgram` 被忽略（`applied = false`，PVW / PGM 不变）；`cut` 立即完成正在进行的转场。
- **转场槽**：`useTransitionSlot {slot, start}` 选中槽 n（`start: true` 同一拍开始 auto 转场 = 界面上点"转场 n"、⌥n；`false` = 只给 T-bar / 回车用），转场进行中被忽略；
  `setTransitionSlot` 改槽的整份配置，**转场进行中也收**（进行中的那一次按开始时的参数走完；改的是当前槽时，做完那一拍、或 `tbar` 拉回 0 取消的那一拍起按新配置）；`autoTransition` / T-bar 用的是当前那组 = 当前槽（`transition.currentSlot`；对不上任何槽时快照里没有这个键）。
  老命令 `fade` / `setTransition` / `setTransitionParams` 改的是当前那组，之后 `currentSlot` = 仍对得上的槽，对不上就没有这个键。**没选输入的 Stinger**（提案 029）不执行：`useTransitionSlot(start: true)` 对这种槽、`autoTransition` 在要执行的当前那组是这种时都回 400（"转场 n 是 Stinger、还没选输入"，当前那组不对应槽时"当前转场是…"）——不然画面在换底拍那一拍（出厂 0 = 第 1 拍）就硬切、状态机却要等满时长才对调；`start: false`、`tbar`、`cut`、`fade` 照常（App 的 T-bar 这时灰着不发 `tbar`；API / MIDI 推这种槽，推过换底拍对应的位置——出厂 0 = 一推动——画面就整幅硬切成 PVW，推到 1 PGM / PVW 才对调）。
- **AFV 的声音**：`cut` 打断进行中的 auto 转场或 T-bar 转场、`tbar` 推到 1 提交时，跟随视频的声音在画面对调的那一拍（拍点 + 对齐延迟）用一条约 5 ms 的短淡收口，不再接着走原来的长淡变。
- **FTB 的声音**（Master 跟着淡，与 AFV 开不开无关）：FTB 进行中改时长（`setFTBDuration`），声音从改的那一拍起跟着画面的新斜坡走。
- **文件播放**：`setPlayback {input, paused}` 暂停 / 继续（画面停在那一帧，仍每拍出帧）；`seekPlayback {input, seconds}` 定位（暂停中定位就停在那一帧）；
  `settings.playback.restartOnProgram` 开着的文件输入在被切上 PGM 的那一拍从头播（首帧晚约 3 拍）。只对文件输入有意义。
  - **定位秒数**收 0–604 800（一周，`PlaybackLimits.maxSeekSeconds`），非有限 / 负数 / 超上限回 400"定位秒数必须在 0–604800 之间（一周）：<值>"；在范围里但到了片长或更后面 = 从头播。`setInputSettings` 整体带进来的 `playback.seekSeconds` 不拒、钳进 [0, 一周]。
  - **播放速率**（`InputSource.file` 的 `rate`）收 0.1–8（`FileSource.rateRange`）：`addInput` / `setInputSource` 越界（含非有限）回 400"播放速率必须在 0.1–8 之间：<值>"；节目文件里有越界速率的整份不打开（`loadShow` 同样拒），老文件缺 `rate` 键按 1 读。（提案 031）
- **`setBusEffects`（总线效果链）已作用到声音**：
  - 链的顺序 = 处理顺序；连续的 `parametricEQ` 合成一格（一格最多 16 段），动态（`dynamicsProcessor` 或 `compressor` 二选一，第二个不装）、`peakLimiter` 各占一格；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格）。超出 3 格的、认不出的 `id` 不装（同一条只记一次日志）。
  - `enabled = false` = 旁路（输出逐样本等于输入），参数留着。
  - `parametricEQ.q` 是经典 Q（半增益处的带宽，q = √2 ≈ 1 个倍频程）。
  - 参数超出范围被钳：EQ 频率 20…23520 Hz、增益 −96…+24 dB、q 0.1826…28.85；`dynamicsProcessor` 阈值 −40…20 dB、起音 0.001…0.2 s；限幅起音 0.001…0.03 s、衰减 0.001…0.04 s、`ceilingDb` −20…0（`compressor` 的范围见下）。
  - 开了压缩 / 限幅的总线多出处理延迟（`dynamicsProcessor` 恒 256 帧 = 5.3 ms，`compressor` 0，每个限幅 = 它的起音 1–30 ms；一格动态 + 一格限幅——界面做得出来的链——最多约 35 ms，API 在一条链上放几个 `peakLimiter` 时延迟相加，视频延后最多只补 35 ms）。Master 的这段延迟（`video_delay_ms`）由**视频一起延后**来对齐：引擎按拍点 + 延迟派发画面，录制 / 推流 / NDI® 与 App 的监视器 / 外部显示 / 多画面都晚同样毫秒数，音频 PTS 不动、本机监听与画面同步（App 与无界面引擎的默认；无界面引擎 `--av-compensation audioPTS` 改回旧做法：音频 PTS 前移、画面不动、监听晚这么多）。Bus A / B 的延迟不补。
- **每路输入的效果链**（`setInputSettings` 的 `settings.effects`）**已作用到声音**：所有 `parametricEQ` 合成一格（最多 16 段，多的不装）+ 一个动态格（`compressor` 或 `dynamicsProcessor`，第二个不装），处理顺序固定先 EQ 后动态、与链里的先后无关；
  `peakLimiter` 与认不出的 `id` 每路不装（各记一次日志）。效果在这一路的对齐延迟线之前，延迟从这一路的对齐延迟里扣，节目时间线与 PTS 不动。
- **`compressor`**（自写压缩器，总线与每路都能装、与 `dynamicsProcessor` 二选一占同一格）：`thresholdDb`（−60…0）、`ratio`（1…20，n:1）、`kneeDb`（0…24，0 = 硬拐点）、`attackSeconds`（0.0001…0.2）、`releaseSeconds`（0.01…3）、`makeupGainDb`（0…24）；
  不用前瞻、按设计 0 延迟（装格 / 改参数时实测，量到的进对齐）；起音 / 释放是线性域峰值包络的一阶时间常数（不是 dB 域增益走到 63% 的时间；两者差多少看信号超过阈值多少，超 20 dB 时后者约为前者的一半）。App 的压缩页两种都能选（新开默认 `compressor`）。
- **监听同步**：见上面总线那一条；录制文件从这条延后的输出时间线的 0 起（开头没有黑帧）。
- **`setMonitorSource {bus}`**：耳机出口放哪条总线——`0` Master（默认）/ `1` Bus A / `2` Bus B / `3` 耳机总线自己（提案 026 追加、P5-3 起允许，只听各路"送耳机"的那些；之前的版本回 400）；调音台里有独听时耳机出口总是放独听的路。快照里是 `audio.monitorSource`。
- **起不来的录制 / 推流路**：`stats.encoder[]` 里那一项报 `failed`（不是 `idle`），原因在那一项的 `last_error`（App 的界面提示与日志里也有）。
- **推流被服务器拒绝鉴权**：被拒的那一次就停在 `failed`（`attempt` 0），不按退避重试；`last_error` 以 `鉴权失败（用户名或密码不对）`、`鉴权失败（服务器要用户名和密码，地址里没写）` 或 `鉴权失败（服务器要的鉴权方式不支持）` 开头，冒号后面是服务器回的原文（不带密码；地址里写了 Adobe 账号而服务器要 Limelight 时是一句"服务器要 Limelight（authmod=llnw）"）。
  改对之后要重新开始这一路：App 里先 `stopStream`，等 `stats.encoder[]` 里这一路不再是 `failed` 再 `startStream`（两条紧挨着发，App 按 60 Hz 看快照、可能看不到中间那一下，就什么也不做），或点底栏推流主体；改设置本身不会让它重试。其余连不上 / 断线照旧在 `connecting` / `backoff` 之间一直重试。
- **推流 `last_error` 的另外几种**：连不上 `连接失败：<原因>`（如 `连接失败：连接超时`；服务器回了状态时是它的状态码（多数还带描述，开始推的阶段多数前面带 `publish: `）），推上过又断了 `断线：连接断开` / `断线：发送停滞` / `断线：发送失败：<原因>`。
  外层不再带程序内部的枚举写法；`<原因>` 是底层库或服务器的原话，个别是英文标识（如 `连接失败：publish: requestTimedOut`），按原文显示即可、别拿它做字符串匹配。
- **NDI 发送**：来源是 NV12 的画面（PGM / PVW / 多画面、摄像头 / 文件这类输入）转 UYVY 送，按帧尺寸、不超过节目尺寸（比节目大的 NV12 输入只送左上一块，已知问题）；UYVY / BGRA 的输入（图片、屏幕、NDI / DeckLink 接收）不转、按输入自己的尺寸直送，其中 BGRA 按 **BGRX**（不透明，下游没有 alpha）。`bitrate` 一律按节目尺寸的 UYVY 估。

## 7. 版本

`hello.version` / `state.version` = PlusMix 版本（0.1.0）。API 路径带 `v1`；字段只加不删，加字段不升版本号，客户端按键名读、忽略不认识的键。
