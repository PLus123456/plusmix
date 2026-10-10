# 028 videoDelay 补偿下的时间戳口径：节目输出时间线 = 采集时刻 + L

提出会话 / 分支：W1-B4（prompt 105）/ `w1-core-4`

背景：prompt 105 第 2 条的补偿方式开关（`AudioEngineConfiguration.avCompensation`）——`videoDelay`（新，默认）= 音频 PTS 不再前移、视频延后 L；
`audioPTS` = W5-C 现状（音频 PTS 前移 L，视频不动）。L = Master 当前效果链的实测延迟（W5-C 量 AU 的值；102 自写压缩器自测的值），
一条总线最大 35.3 ms。用户 2026-10-10 在两种做法里定了**照 prompt 字面**：videoDelay 下音频 PTS 不前移，
录制 / 推流 / NDI 要对齐，视频的时间戳就跟着延后 L——这改了契约里两处时间戳的口径（字段不变），所以先写本提案。

## 改什么（只改口径文字，不加 / 不改字段）

定义**节目输出时间线**：videoDelay 下 = 内容被采集（拍点）的时刻 + L；audioPTS 下或没有效果时 L = 0，就是现在的拍点 / 采集时刻。

| # | 位置 | 现在 | 改成 |
|---|---|---|---|
| 1 | `RenderedFrame.tickTime`（Render.swift 注释、CONTRACTS.md §3 第一条、§7） | 这一拍的理想拍点时刻；编码 PTS 用它 | 这一拍在节目输出时间线上的时刻 = 理想拍点 + 这一帧的视频延后 Lₙ；编码 PTS 用它；**严格递增**。`tick` 不变；`program.pts` / `preview.pts` / `multiview.pts` **仍是理想拍点**（画面内容的时刻），`tickTime − program.pts` = 这一帧的 Lₙ |
| 2 | `RenderedFrame.renderMs`（Render.swift 的计算属性） | `gpuEnd − tickTime` | `gpuEnd − program.pts`（V1 口径不变：拍点 → GPU 完成；L = 0 时与现在逐值相同）。引擎的 `render_ms` 本来就按派发前的原帧算，不受影响；改它只是让延后过的帧读出来不是负数 |
| 3 | `AudioBlockConsumer.hostTime`（Render.swift 注释、CONTRACTS.md §7、`AudioBlockConsuming` 注释） | 块首样本 host time，已按对齐延迟修正到内容被采集的时刻 | 块首样本在节目输出时间线上的时刻（与 `RenderedFrame.tickTime` 同一条线）= 内容被采集的时刻 + L。各来源怎么来见下表 |
| 4 | CONTRACTS.md §2.7 / `Stats.PerInput.latencyMs` 注释（提案 005 的 L1） | 帧交给第一个 FrameConsumer 的那一刻 − ingressTime | 不改定义，补一句：videoDelay 下"交给第一个 FrameConsumer 的那一刻"在延后之后，所以 L1 含 L（开着压缩 / 限幅时 L1 多 5–35 ms） |

第 3 条各来源的 PTS（L_bus = 该总线效果链延迟，L_m = Master 的；块号精确，沿用 W5-C 的 `EffectLatencyTimeline`）：

| 来源 | audioPTS（现在，不变） | videoDelay |
|---|---|---|
| Master | 块首 − 对齐延迟 − L_m | 块首 − 对齐延迟（**不再前移**；内容经 Master 效果链本来就晚 L_m） |
| Bus A / B / 耳机 | 块首 − 对齐延迟 − L_bus | 块首 − 对齐延迟 − L_bus + L_m |
| 输入（ISO `.input`、`.inputProgram`） | 块首 − 对齐延迟 | 块首 − 对齐延迟 + L_m |

L 变了：非 Master 来源在变化那一块按差值拼接（变大丢、变小补静音，W5-C 的做法），消费者看到的 PTS 连续；Master 不拼接（AU 自己的前瞻在开 / 关那一刻已经跳了 Δ）。
视频的 Lₙ 每帧最多改 1/4 拍（60 fps 下 35 ms 要 9 帧 ≈ 150 ms），tickTime 严格递增、不丢帧不重复；音频是当场拼接，所以 L 变化后约"对齐延迟 + 过渡"（≤ 200 ms）内音画差最多 |ΔL|，之后精确。

不在契约里、但口径跟着走的（本会话实现）：
- 引擎派发：渲染完成的帧在 `tickTime`（= 拍点 + Lₙ）到期时才交给 FrameConsumer；Lₙ = 0 且队列空时仍在完成线程直接派发（与现在逐行相同）。
- 显示（用户 2026-10-10 批扩到 SwitcherRender）：`MetalRenderer` 的 `latestDisplayFrame` 给"拍点 + L 已到期"的最新一帧，主界面监视器 / 外部显示 / 多画面窗口跟编码器同一时刻看到同一帧。
- 当前延后值进 `EngineCounters`；进 Stats 是提案 022 的 B2 `video_delay_ms`（P5 开字段，本会话填数）。

## 为什么

- 用户 2026-10-03：监听也要同步，办法是把视频延后同样的毫秒数；接受 PGM 端到端多 L。扬声器 / 耳机没有 PTS，只能让画面晚 L。
- 用户 2026-10-10：videoDelay 照 prompt 字面——音频 PTS 不前移。那么 Master 块的时间戳就落在"采集 + L"上，视频、其他音频来源必须跟它在同一条线上，录制 / 推流 / NDI 文件里的 A/V 才对得上（prompt：两种方式下录制 A/V 偏移都 ≤ 1 ms、不许双重补偿）。
- 两种方式互斥由一处开关保证：audioPTS 下视频不延后（Lₙ ≡ 0），videoDelay 下 Master 不前移——不会出现"音频前移 + 视频后移"的双重补偿。

## 影响谁

| 谁 | 要做什么 | 归谁 |
|---|---|---|
| SwitcherContracts（Render.swift 注释与 `renderMs`、Stats.swift `latencyMs` 注释）、CONTRACTS.md §3 / §7 / §2.7 | 上表 1–4 的文字；`renderMs` 一行实现 | P5（prompt 99，若还没收尾）或下一个契约会话 |
| SwitcherEngine（Engine 派发、延迟队列、计数） | 按 tickTime 到期派发、slew、零分配 | 本会话 |
| SwitcherAudio Integration（ConsumerPump、AudioEngine） | 开关；各来源按上表平移；把 L_m 交给引擎 | 本会话 |
| SwitcherRender（MetalRenderer 显示源） | 显示按拍点 + L 到期挑帧；多留 ⌈L_max / 拍长⌉ 格（1080p 约 75 MB，只在开了余量时建）；NV12 输出环同样加深 | 本会话（用户已批扩范围） |
| **SwitcherOutputs `ISO/ISOFrameTap.swift`**（ISO 录制、源是输入 n 的 NDI 发送） | 挑帧改用 `frame.program.pts`（内容时刻）、打戳仍用 `frame.tickTime`：一行。不改的话 videoDelay 下 ISO 画面比它的时间戳晚 L 采集（ISO 文件 A/V 差 L）。L = 0 时两者相等，行为不变 | 检查点胶水（1 行）或下一个 SwitcherOutputs 会话；请用户定 |
| 录制起止（App `OutputRuntime.swift:373 / 576`、headless `HeadlessRun.swift:449–450`） | `RecordingStart(clock:tick:)` 给的是拍点；开录那一刻 L > 0 时，视频轨从 L 开始、音轨从 0 开始，两轨首尾各错 L（文件内 A/V 仍对齐；E5"音视频轨道差 ≤ 20 ms"在 L > 20 ms 时会看到）。按输出时间线开录：`RecordingStart(tick: n, tickTime: 拍点 + 引擎当前的视频延后)` | App 归检查点胶水 / 97；headless 本会话只加参数，不改它（gate4 不带效果，L = 0） |
| App 接线 | `audioEngine.videoDelay = engine`、渲染器选项开显示余量、`renderer.displayDelayProvider` 接引擎；不接 = 音频引擎退回 audioPTS 行为（W5-C 现状），不会出现文件错位 | 检查点胶水 / 97 |
| API / tally 的 `tickTime`（StateFeed、TallyFrame） | 不变：仍是状态变化那一拍的拍点（C1 / C2 量的是状态，不是输出）；画面在输出里出现 = 它 + L，docs/api.md 一句话 | 103（文档）或检查点 |
| 测试标准 | A2 / A3 / A4 判法不变（同一条输出时间线上比）；L1 含 L 写进 §3 L1 行的备注 | 检查点 / 用户 |

## 怎么迁移

- 不加字段、不改 JSON 键、Show 的 `schemaVersion` 不动。
- L = 0（audioPTS、没有效果、或组装方没接 `audioEngine.videoDelay`）时，所有时间戳与现在逐值相同——gate4（场景不带效果）结果应不变。
- 老的消费者都按 `tickTime` / `hostTime` 当 PTS，不用改就落在新时间线上；唯一按 tickTime **挑输入帧**的是 ISOFrameTap（上表）。

## 请用户定

1. 批 / 驳上面 1–4 的口径（批了本会话按它实现；契约文字与 `renderMs` 一行由契约会话落）。
2. ISOFrameTap 那一行：检查点胶水改，还是本会话顺手扩到 SwitcherOutputs/ISO 这一个文件。
3. 录制起止按输出时间线：只在报告里写给 App / headless 的后续会话（建议），还是本会话在 headless 里也改（超出"只加参数"）。

状态：**已批**（用户 2026-10-10，W1-B4 会话里定）：
1. 上面 1–4 的口径批了：本会话按它实现引擎 / 音频集成层 / 显示 / headless 参数；契约文字（Render.swift、Stats.swift 注释，CONTRACTS.md §3 / §7 / §2.7）与 `renderMs` 一行由契约会话（P5 或之后的）落。
2. ISOFrameTap 那一行**本会话改**（扩到 `Packages/SwitcherOutputs/Sources/ISO/ISOFrameTap.swift` 这一个文件 + ISOTests 一条用例）。
3. 录制起止按输出时间线开录**只写进报告**（App / headless 的后续会话照改法改）；本会话的 headless 只加 `--av-compensation`。
同一天用户还批了把显示延后扩到 SwitcherRender（MetalRenderer 的显示源）。

2026-10-11（用户看完 reports/G8.md，"2–5 按 G8 的想法"）：① 契约文字、`renderMs` 一行、Stats 顶层 `video_delay_ms`（022 B2，同日批）归 **P5-2**（prompt 108）；② 测试标准 §3 的 L1 行加一句"videoDelay 下判定扣掉当时的 `video_delay_ms`，阈值数字不动"（P5-2）；③ 录制起止按输出时间线开录归 **G8b 的胶水**（App `OutputRuntime.swift` 两处 + headless `HeadlessRun.swift` 两处 + `AVCompensationTests` 去掉 `startTick = −2` 的变通），与 App 的三行接线一起做；④ W1-B4 已随 G8a 合入 main（f0c33ef）。
