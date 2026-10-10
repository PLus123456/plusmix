# W1-B4 监听同步：按总线效果链的实测延迟把视频延后同样的毫秒数 —— 报告（分支 w1-core-4）

日期 2026-10-10。机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.0 / Swift 6.4，电源适配器。
worktree `.claude/worktrees/w1-core-4-listen-sync-5e151a`，harness 分支 `claude/w1-core-4-listen-sync-5e151a`，从 main 93f50d9（G7 快进后）开；
收尾时另建本地分支 `w1-core-4` 指向同一提交（OWNERSHIP / 检查点按这个名字找）。不 push、不 merge。102 晚开要叠在本分支头上，**分支头没有 rebase 重写**。
提交（小步，先红后绿）：`git log --oneline main..w1-core-4`。

## 1. 做了什么

### 1.1 两个裁定（开工前问了用户，2026-10-10）

1. **补偿方式 videoDelay 的口径照 prompt 字面**：音频 PTS 不再前移、视频延后 L。这样录制 / 推流 / NDI 要对齐，交给消费者的视频时间戳也得是"拍点 + L"——
   改了契约里两处时间戳的口径（不加字段），按铁律 1 写了 **提案 028**（`docs/contract-changes/028-video-delay-output-timeline.md`）停下来问，**用户批了**：
   定义"节目输出时间线 = 采集（拍点）时刻 + L"；`RenderedFrame.tickTime` = 拍点 + Lₙ（严格递增），`program.pts` 仍是拍点；
   `AudioBlockConsumer.hostTime` 走同一条线（Master 不前移，Bus A / B / 耳机平移 L_m − L_bus，输入来源平移 +L_m）；L1 含 L。
   同时定了：ISOFrameTap 挑帧那一行本会话改；开录起点按输出时间线**只写进报告**（§5）。
   （另一个选项是"只延后派发、PTS 不动"，契约不用改；用户选了字面。）
2. **显示延后扩到 SwitcherRender**：主界面监视器 / 外部显示 / 多画面窗口不走 FrameConsumer，`MetalDisplayView` 直接从渲染器拿"最新完成的纹理"，
   引擎延后不了它；渲染器原来只留 3 格纹理，延后 35 ms 要多留 3 格并按到期时刻挑。用户批本会话改 MetalRenderer。

所以本会话实际动了 prompt 列的五处之外的四个文件（MetalRenderer.swift、ISOFrameTap.swift 与各自一个用例文件），都是用户当场批的；
`make lint` 的 check-ownership 对这四个文件报越界，问题单 `reports/issues/W1B4-g8-ownership-and-glue.md` 请 G8 在 OWNERSHIP 的 W1-B4 行补上（§2.3 的 lint 一行）。

### 1.2 引擎：延迟队列的实现与深度（交付 1）

`Packages/SwitcherCore/Sources/SwitcherEngine/Engine/VideoDelay.swift`（新）+ Engine.swift 的完成回调 / 派发拆开：

- **GPU 完成线程**（RenderSink 回调）先照旧计 render_ms / 派发抖动（用原帧），然后 `VideoDelayLine.admit`：
  算这一帧的 Lₙ（§1.3）→ tickTime 改成拍点 + Lₙ（program / preview / multiview 的 pts 不动）→
  **延迟队列空着（派发线程闲）且这一帧已到期**（Lₙ = 0 时总是）：**当场派发**，与以前同一条路——gate4 不带效果就走这里，计数 framesDelayed 为 0；
  否则入队 + 信号量叫醒派发线程。
- **派发线程** `switcher.engine.dispatch`（NativeThread，time-constraint 实时，参数同时钟线程：period = 拍长、computation 1/4、constraint 1/2）：
  看队头的到期时刻 → `mach_wait_until` → 出队 → L1 记账 + 逐个消费者 consume。实测派发 − 到期中位 0.009–0.017 ms、最大 0.040 ms（§2.2）。
- **两条线程不会同时调消费者**：只有完成线程入队，它只在"入队数 = 派发线程已派完数"（派发线程 release 写、完成线程 acquire 读）时当场派发；
  入队 / 出队的 head / tail 也是 release / acquire。消费者（ISOFrameTap 的分支槽、QueuedFrameConsumer 的 SPSC 环）的"单一消费者"要求照样成立。
- **队列**：预分配的单生产者单消费者环（Lamport），元素是 `RenderedFrame?`（拷贝只有 retain / release），另存每格的到期时刻；不覆盖，满了不等。
  **深度 = ⌈maxDelay / 拍长⌉ + 1**（prompt 的"35 ms @ 60 fps = 3 帧 + 1"）：60 fps 4、30 fps 3、24 fps 2（maxDelay 默认 35 ms，`EngineOptions.videoDelay`）。
  正常最多压 ⌈(L − 渲染耗时) / 拍长⌉ 帧，+1 盖住"新帧入队时队头正在出队"；headless 实跑 L = 30 ms 时最多压 2 帧。
  满了 = 派发线程被饿了好几拍（正常不会），丢这一帧并计 `videoDelayOverflow`（本会话所有运行都是 0）。
- **停**：时钟停 → 渲染器 shutdown（完成回调全部到过）→ 派发线程把队列里剩下的帧不等到期全派掉 → 退出（停录制等最后一帧不会少）。
- **零分配**：渲染线程（没改）、完成线程、派发线程稳态 0 次 malloc，debug 与 release 都量了（§2.1 `testAV_videoDelayQueueZeroAllocation`，三条线程同时盯）。
- **设定入口**：`VideoDelayControl` 协议（`setVideoDelayTarget(_:)`，任意线程），Engine 实现；设定值钳到 [0, maxDelay]；没起也能设。
  读数：`Engine.videoDelayTarget` / `videoDelayApplied`（最近派发那一帧的 Lₙ）/ `videoDelayQueueCapacity`。
- **计数（交付 4，先放 EngineCounters）**：`videoDelayApplied` / `videoDelayMs`（运行量，进 Stats 归提案 022 的 B2 `video_delay_ms`，P5 开字段后 StatsAssembler 填一行）、
  `framesDelayed`、`videoDelayOverflow`、`videoDelayQueueMax`、`takeVideoDelayLateMax()`（派发 − 到期的窗口最大值）、`videoDelayPTSGuards`（单调保护触发次数，正常 0）。
- **L1**（提案 005 的 per_input.latency_ms）改在**真正派发的那一刻**记账（"帧交给第一个消费者的那一刻 − ingressTime"），所以 videoDelay 下含 L（§1.8）。
  `dispatchJitterMax`（V3 的另一种口径，完成回调时刻 − 拍点）口径不变，仍在完成回调里量。

### 1.3 切换过渡的做法

- **视频：每拍 Lₙ 最多改 1/4 拍**（`slewFraction`，60 fps 下 4.17 ms）：相邻 tickTime 的间隔留在 [¾, 1¼] 拍内，严格递增、一帧不丢不重；
  0 → 35 ms 要 9 拍（≈ 150 ms），12 ms 3 拍。时钟跳过的拍按拍数放宽（每拍 1/4）。第一帧直接用设定值（还没派发过东西，不从 0 爬）。
  单调保护（tickTime ≤ 上一帧就 +1 tick 并计数）在 slew 之下走不到，所有运行都是 0。
- **音频：当场拼接**（W5-C 的做法）：videoDelay 下非 Master 来源要减的延迟是 L_bus − L_m（输入来源 −L_m），L_m 变了在变化那一块按差值丢（变大）/ 补静音（变小），
  消费者看到的 PTS 连续；**Master 不拼接**（它的平移量恒为 0，内容在 AU 前瞻里本来就跳了 Δ）。补偿方式中途切换（接上 / 摘掉视频引擎）也走同一套拼接。
- 所以 L 变化之后约"对齐延迟 42.7 ms + 视频 slew ≤ 150 ms"的时间里音画最多差 |ΔL|，之后精确；设定值只在 Master 效果链的延迟变了时才变（开关格、换格、改限幅起音）。
  用例：引擎侧 0 → 35 → 0 → 20 → 5 ms 跳变（每帧最大改动 4.167 ms = 上限，0 丢 0 重 0 倒退）；集成侧真 AU 开关限幅 12 ms（0 丢 0 重 0 倒退）。

### 1.4 补偿方式一处开关（交付 2，SwitcherAudio/Integration）

- `AVCompensation`（`videoDelay` 默认 / `audioPTS`）在 `AudioEngineConfiguration.avCompensation`；`AudioEngine.videoDelay: (any VideoDelayControl)?` 是"接上视频引擎"的入口。
- **实际生效** = 配置是 videoDelay **且接了视频引擎** 才是 videoDelay（`avCompensationInEffect`，也进 `AudioEngineStatus.avCompensation`）。
  **没接时退回 audioPTS 的行为**——App 在接线之前（归检查点 / 97）录制 / 推流 / NDI 不会错位，只是监听照旧晚 L。
- videoDelay 生效时：控制线程每个周期看 Master 的效果链延迟（`BusEffectsController` 已发布、与泵用的 `EffectLatencyTimeline` 同一个数，102 自测的延迟也会落到这里）
  变了就交给引擎（帧 × 每帧 host tick，与泵同一个换算）；接上的那一刻交一次，换掉 / 摘掉时旧的那个归零。泵里各来源按 §1.1 的表平移。
  audioPTS：W5-C 现状，接了引擎也只交 0——**两种方式互斥，不会出现"音频前移 + 视频后移"的双重补偿**（`testAV_compensation_audioPTSMode_*`、两种方式的 A2 对比）。
- `programPTS(forBlockHostTime:)` 跟着生效方式；`AudioEngineStatus.ConsumerStatus.latencyFrames` 的口径注释改成"audioPTS = L_bus，videoDelay = L_bus − L_m"。

### 1.5 显示延后（SwitcherRender，用户批扩）

- `MetalRendererOptions.videoDelayHeadroom`（默认 0）：> 0 时 PGM / PVW / 多画面三个 NV12 输出环各加深 ⌈余量 / 拍长⌉ + 1（35 ms @ 60 fps：8 → 12）——
  延迟队列扣着这些帧的输出缓冲，不加深的话环被扣满就退回池子分配（渲染线程上分配）。用例：消费者扣着 9 帧时默认环退回池子 18 次、加深后 0 次。
- `MetalRendererOptions.displayDelayHistory`（默认关）：再多留 ⌈余量 / 拍长⌉ 格合成目标（1080p 每格三张 BGRA ≈ 25 MB，35 ms 多 3 格 ≈ 75 MB）。
- `MetalRenderer.displayDelayProvider: (@Sendable () -> HostDuration)?`：组装方接 `{ engine.videoDelayApplied }`。`latestDisplayFrame` 给"拍点 + 延后 ≤ 现在"的最新一帧：
  完成线程按格记下"这一格装的是第几帧、拍、拍点"（先写内容再 release 发布序号，读方读完再核一次）；只看还完整的格（第 k 帧要等第 k + 格数帧提交才被覆盖，再留一帧余量：
  k ≥ 已提交 − 格数 + 2）；历史不够就给最旧的完整那一帧并计 `displayDelayShortfalls`；开头一帧都没到期给 nil（不提前显示）。没给来源或延后 0 就是以前的行为（逐行不变）。
  `version` = 帧序号 + 1（与以前"完成帧计数"同一个数），MetalDisplayView / DisplayFrameLedger 照旧用。
- 主界面监视器、外部显示（PGM / PVW / 多画面源，经 DisplayFrameLedger）、多画面窗口、输入缩略图（多画面纹理的格子）都走这个源，一起延后；
  **外部显示的 Aux（源是输入 n 的原始画面，AuxInputView 直接读帧槽）不延后**——它不是 PGM，与 Master 的声音无关。

### 1.6 ISO 抽帧（SwitcherOutputs/ISO，用户批改这一个文件）

`ISOFrameTap.consume` 挑这一路的帧改用 `frame.program.pts`（画面内容的时刻），打戳仍用 `frame.tickTime`。不改的话 videoDelay 下挑到拍点之后才到的帧，
ISO 画面比时间戳晚 L 采集，与平移了 +L 的 ISO 音轨差 L。L = 0 时两个时刻相等，行为不变（ISO A4 四路 + PGM 用例照过，极差 0.000 ms）。
源是输入 n 的 NDI 发送也走 ISOFrameTap，一起受益。

### 1.7 headless（交付 5，只加参数）

`--av-compensation videoDelay|audioPTS`（默认 videoDelay）：videoDelay 时 `audioEngine.videoDelay = engine`、渲染器 `videoDelayHeadroom = 35 ms`
（开 `--preview` 时再开 displayDelayHistory 并接 displayDelayProvider）；开头一行打补偿方式、收尾一行打延后计数。参数解析抽成 `HeadlessCLI.avCompensation(_:)` 好测。
gate4 场景不带效果：L = 0，走完成线程当场派发的老路（§2.4 的结果与 G7 基线比）。

### 1.8 端到端延迟多了多少

- **派发 / 显示**：帧在拍点 + L 到期时派发，以前在渲染完成（拍点 + 渲染耗时 r）时派发，所以多了 **L − r**（L > r 时；L ≤ r 不变）：
  L = 12 ms、假 GPU 2 ms 时派发 − 渲染完成实测 9.1–9.5 ms；真 AU 限幅 12 ms 时 9.3 ms。显示源按同一个到期时刻挑帧，监视器同样多 L − r。
- **L1（per_input.latency_ms）**：12 ms 时 +9.2 / +9.5 ms（release / debug）；限幅起音 30 ms 的话约 +28 ms。L1 的必须档是 3 帧（50 ms），慢输入在开着长前瞻的限幅时可能越线（§4 第 4 条）。
- **文件 / 流的时间戳**：整体晚 L（视频 tickTime、Master 与其他来源的 PTS 都在采集 + L 上），文件内 A/V 不变（§2.1 的录制 A2）。
- **监听同步的效果**（空设备模拟，§2.2 的 A5 模拟）：Master 限幅 30 ms 时（呈现 − 出声）与不开效果相比 videoDelay 差 −2.7 ms（= 被吸收的渲染耗时），audioPTS 差 −29.9 ms。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherCore --filter 'SwitcherEngineTests.VideoDelayTests'`（release：加 `-c release -Xswiftc -enable-testing`）、
`--filter 'SwitcherRenderTests.DisplayDelayTests'`；`swift test --package-path Packages/SwitcherAudio --filter 'IntegrationTests.VideoDelayCompensationTests'`；
`swift test --package-path Packages/SwitcherOutputs --filter 'ISOTests'`（A4 那条要先 `swift build -c release --package-path Tools/frameprobe`）；
`swift test --package-path Tools/switcher-headless --filter AVCompensationTests`（真跑两次 headless，make test 不跑工具的用例）。

### 2.1 prompt 点名的四条

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testAV_videoDelayFollowsBusEffectLatency`（IntegrationTests：真视频引擎 + 空设备音频引擎，Master 加 AU 限幅起音 12 ms 再关掉） | 设定值 12.000 → 关掉后 0.000 ms；开着时每帧 tickTime − 拍点 = 12 ms（精确，288000 tick），派发 − 渲染完成平均 9.286 ms；关掉后 tickTime = 拍点、派发 − 渲染完成 < 2 ms；全程 0 重复 / 0 乱序 / 0 倒退，派发帧数 + missed_render = 拍数 | 派发比渲染完成晚 12 ms ± 1 拍；关掉回 0；过渡无丢 / 重 / PTS 倒退 | ✅ |
| `testAV_videoDelayQueueZeroAllocation`（SwitcherEngineTests，AllocationProbe 同时盯完成线程 / 派发线程 / 渲染线程，盯的那段里设定值 12 → 30 → 0 → 20 ms） | 盯 380 拍、其中 365 帧经延迟队列：完成线程 malloc 0 / free 0，派发线程 malloc 0，渲染线程 malloc 0（**debug 与 release 都是 0**）；溢出 0 | 0 | ✅ |
| `testA2_videoDelayMode_recordingStaysAligned`（switcher-headless：M0 节目 720p60、Master 限幅起音 30 ms，两种方式各录 12 s，`FrameProbe.av`） | audioPTS：整秒配对 11 对，均值 0.000 / 最大 0.000 ms；videoDelay：11 对，均值 0.021 / 最大 0.021 ms（1 个样本）；两种均值差 0.021 ms；videoDelay 那份视频轨从 30 ms 开始（frameprobe 按 `startTick = −2`，§5 第 3 条） | 整秒配对 ≤ 1 ms，与 audioPTS 相同（差 ≤ 1 ms） | ✅ |
| `testA5_monitorSync_loopback` | **BLOCKED-硬件**：要音频接口线路回环 + 对着监视器的光电探头（或高速快门相机），本机没有；XCTSkip 里写了四步做法（开限幅 30 ms → 回环录 click、探头录监视器 → 整秒配对 → 减接口往返 / 2）。解锁条件：有接口和探头 | 呈现 − 出声 ≤ 1 帧 | ⏭ BLOCKED-硬件 |

### 2.2 本会话加的其他用例

| 用例 | 数值 | 通过 |
|---|---|---|
| `testA5_monitorSync_nullDeviceSimulation`（prompt 交付 3 的模拟：扬声器出声 = 空设备混音块的输出时刻，直接挂 Master tap 找 click；监视器呈现 = 闪光帧的派发时刻） | 呈现 − 出声：不开效果 −39.951 ms（6 对）；videoDelay + 限幅 30 ms −42.658 ms（差 −2.707）；audioPTS + 限幅 30 ms −69.858 ms（差 −29.907）。绝对值 ≈ −对齐延迟：模拟里画面没有采集 / 显示器延迟 | ✅（判"与不开效果相差 ≤ 1 帧"；对照组 > 25 ms） |
| `testA2_videoDelayMode_videoAndAudioTimestampsAligned_nullDevice`（空设备 + 真视频引擎，Master 限幅 30 ms，两种方式各 8.6 s：闪光帧 tickTime − click PTS） | audioPTS 8 对 均值 0.008 / 最大 0.008 ms；videoDelay 8 对 均值 −0.009 / 最大 0.009 ms，视频延后 30.000 ms | ✅ |
| `testAV_videoDelay_dispatchAtTickTimePlusDelay`（引擎，假 GPU 2 ms，延后 12 ms，180 拍） | tickTime − pts = 12 ms 精确；派发 − 到期 中位 0.017 / 最大 0.040 ms（release 0.009 / 0.040）；派发 − 渲染完成 平均 9.53（release 9.11）ms；不在完成线程上派发 | ✅ |
| `testAV_videoDelay_zeroDelayDispatchesDirectlyOnCompletionThread` | L = 0：120 帧全在完成线程上当场派发、tickTime = 拍点、framesDelayed 0 | ✅ |
| `testAV_videoDelay_targetChangesSlewWithoutDropDupOrPTSRegression`（0 → 35 → 0 → 20 → 5 ms） | 420 帧 0 重复 / 0 乱序 / 0 倒退；相邻 tickTime 间隔 ∈ [¾, 1¼] 拍；Lₙ 每帧最大改动 4.167 ms（上限 4.167）；每段稳态 = 设定值 | ✅ |
| `testAV_videoDelay_stopDrainsPendingFrames`（延后 30 ms、跑满 60 拍马上停） | 60 / 60 派发 | ✅ |
| `testAV_videoDelay_targetClampedAndQueueDepthFromMaxDelay` | 100 ms → 35；−3 → 0；深度 60 fps 4 / 30 fps 3 / 24 fps 2 / maxDelay 100 ms 时 7 | ✅ |
| `testAV_videoDelay_l1LatencyIncludesDelay` | L1：不延后 9.52 → 延后 12 ms 19.00 ms（+9.48；release +9.24） | ✅（10 ± 2） |
| `testAV_compensation_defaultVideoDelay_fallsBackToAudioPTSUntilEngineAttached` | 默认 videoDelay；没接引擎时按 audioPTS（Master 的 click 在整秒 ±0.05 ms）；接上那一刻交 576 帧 = 12 ms，摘掉旧的归零 | ✅ |
| `testAV_compensation_audioPTSMode_keepsW5CBehaviourAndNeverDelaysVideo` | 三格 832 帧：click 在整秒 ±0.05 ms，交给引擎的全是 0 | ✅ |
| `testAV_videoDelayMode_allSourcesOnOutputTimeline`（Master 限幅 12 ms、Bus A 限幅 2 ms） | Master / Bus A / ISO 输入 1 的 click 全在 k s + 12 ms（±0.05），PTS 无断点；`programPTS` 不减效果延迟 | ✅ |
| `testAV_videoDelayMode_masterLatencyChange_splicesNonMasterSourcesOnly`（0 → 12 → 2 → 0 ms） | 设定值依次 0 / 12 / 2 / 0；每段 click 在 k s + 那段的 L；Master 丢 / 补 0，输入来源补 576 / 丢 576 帧；PTS 无断点 | ✅ |
| `testAV_displayDelay_headroomSizesSlotsAndOutputRing` | 默认 3 格 / 环 8；只开余量 3 / 12；再开显示历史 6 / 12；30 fps 5 / 11 | ✅ |
| `testAV_displayDelay_picksNewestDueFrameWithinHistory` | 延后 2.5 / 3.5 s 给第 7 / 6 帧（纹理 = 那一格的）；4.5 s 超出历史给第 6 帧并计 1 次不足；0 或没来源给最新第 9 帧；PGM / PVW / 多画面同一帧 | ✅ |
| `testAV_displayDelay_nothingDueYetReturnsNil` | 一帧都没到期给 nil、不计不足；延后 0 给最新 | ✅ |
| `testAV_videoDelayHeadroom_outputRingCoversHeldFrames`（消费者扣着 9 帧，720p 1.5 s） | 默认环退回池子 18 次，加深到 12 后 0 次 | ✅ |
| `testAV_isoTapPicksByContentTimeUnderVideoDelay`（ISOTests） | 第 1 拍挑序号 1（拍点前 4 ms），不是拍点 + 12 ms 时已到的序号 2；打戳 = 拍点 + 12 ms。改前跑：挑到 [2, 2]（红） | ✅ |
| `testAV_headlessAVCompensationArgument` | 默认 videoDelay；两个合法值；非法值报错 | ✅ |

### 2.3 既有用例（回归）

| 包 / 用例 | 数值 | 通过 |
|---|---|---|
| SwitcherCore 全量（debug） | SwitcherRenderTests 101 个、SwitcherEngineTests 107 个、SwitcherContractsTests 82 个（跳过 1），**0 失败**；V8 参考图、T1、V1、显示解耦都在里面 | ✅ |
| `testW1B_renderPath_zeroAllocationsInSteadyState`（release） | 渲染线程 + 完成线程稳态 0 | ✅ |
| SwitcherAudio 全量（debug） | SwitcherAudioTests 72 个（跳过 2）+ IntegrationTests 64 个（跳过 5：W2-E 的真设备 A2A3、真设备 A3 长跑、A5 回环、W5-C 真设备 A2——都按环境变量跳——与本会话的 `testA5_monitorSync_loopback`），**0 失败**。W5-C 的效果链用例一条没改（默认 videoDelay 但没接引擎 = audioPTS） | ✅ |
| SwitcherOutputs `ISOTests`（全部，含 `testA4_fourVideoISORoutesPlusPGM_sameEventWithin1Frame`，编好 frameprobe release 之后） | A4：10 个事件，闪光极差 / click 极差 0.000 ms；S7 / tee / tap 照过 | ✅ |
| App（`make gen && make build-app`） | 编过（PlusMix.app，Debug）。App 代码一行没改；默认不接视频引擎 = audioPTS、渲染器两个新选项默认关，行为与改前相同，所以 App 用例没跑（接线之后要跑，归检查点 / 97） | ✅ 编译 |
| `make lint BRANCH=w1-core-4` | 禁词、版本号、Package.swift 约束、依赖方向（8 个包）、check-links（174 个 Markdown）、check-rt-symbols 全绿；**check-ownership 报 4 个越界文件 = 用户批的扩范围**（§1.1，问题单） | ⚠️ 见 §1.1 |

### 2.4 gate4（场景不带效果，L = 0）

`scripts/gate4.sh --minutes 10 --label w1b4 --checkpoint W1B4 --baseline baselines/g7-m5max.json`（= `make gate4-run` 去掉写基线；`--checkpoint W1B4` 让它不碰
reports/G4.md 与 g4 基线），headless 用默认的 `--av-compensation videoDelay`。两次运行的整份报告留在 `.build/gate4/w1b4/`、`.build/gate4/w1b4-2/`
（`W1B4-assembled.md`、stats.jsonl、load.log、frameprobe 输出；脚本另写的 `reports/W1B4-run-*.md` 不在本分支的归属里，取完数删了）。
两次都是 **L = 0、经延迟队列 0 帧**（headless 收尾那一行），派发走的就是改前那条路——"与改前一致"要看的正是这一点。

| 指标 | 第一次（22:52，提交 b7d2571） | 第二次（23:15，提交 4bc258e） | 阈值 | G7 基线（g7-m5max） |
|---|---|---|---|---|
| V1 渲染耗时 | avg 2.125 / p99 4.256 ms ✅ | avg **1.871** / p99 2.950 ms ✅ | avg ≤ 6 / p99 ≤ 12 | 1.831 / 2.325 |
| V2 渲染滞后丢帧 | **1 / 35940 拍** ❌（22:54:37 第 5839 拍） | **0** ✅ | 10 分钟 0 | 0 |
| V3 抖动 | p99 0.059 / max 0.113 ms ✅ | p99 0.045 / max 0.144 ms ✅ | p99 ≤ 4 | p99 0.030 |
| V4 设计外 | 精确核算 30 帧（stats.jsonl）/ 0（frameprobe 在播段）❌ | 0 / 0 ✅ | 0 | 0 |
| V5 帧计数 | −1 ✅ | +0 ✅ | ≤ 2 | |
| V6 / V7 | Cut 第 1000 拍、90 次全干净；Fade 0.252 帧、Wipe 0.095、Zoom 0.003、T-bar 0.32% ✅ | 同左；Wipe 0.037、Zoom 0.002 ✅ | | |
| A1 | 0 ✅ | 0 ✅ | 0 | |
| A2（整秒配对） | 174 对：均值 +0.000 / 最大 0.000 ms ✅ | 264 对：+0.000 / 0.000 ms ✅ | ≤ 16.7 ms | |
| A3 | 0.00 ms / 8 h ✅ | 0.00 ✅ | ≤ 16 | |
| A4 | click 极差 0.208 ms、闪光 0.000 ✅ | 0.208 / 0.000 ✅ | ≤ 1 帧 | |
| E1 / E2 / E3 / E5 | 0 / 6.002 Mbps 峰 1.047× / 0 帧 / 音视频差 0.0 ms ✅ | 0 / 6.002 峰 1.052× / 0 / 0.0 ms ✅ | | |
| C1–C4 | 50/50（max 14.49 ms）、p99 0.14 ms、不一致 0、12000/12000 ✅ | 50/50（max 15.70）、0.13、0、12000/12000 ✅ | | |
| S3（信息） | CPU 47.5% / GPU 29.8% ✅ | CPU 37.1% / GPU 31.3% ✅ | ≤ 60 / ≤ 50 | 55.8 / 41.0 |
| S2（信息，不足 1 h 整段拟合） | 75.95 MB/h（RSS 884 → 907，300 s 后持平） | 70.75 MB/h（883 → 904，300 s 后持平） | ≤ 10 | 57.8（861 → 884） |
| 自动项总判定 | ❌（V2 / V4） | **✅ 全部满足** | | |

- **第一次的 V2 = 1 不是本改动**：那一秒时钟线程照样准点（jitter 0.017 ms）、render_ms 2.48 ms 不高，但**所有合成源线程晚醒 20–34 ms**（headless 收尾"唤醒 max"）、
  每路 latency_max 从 30 跳到 63–81 ms、各路 drop +2～+3（传输环在生产者醒来一次推几帧时挤掉的）、快照过期 3 次——W1-B3 报告 §1.4 记的"系统守护进程突发、整个进程的普通线程停顿"
  同一签名；load.log 同时刻 contactsd 7% → 13% → 23%、runningboardd 6.7%（W1-B3 列过的 Contacts / AddressBook 一族）。V4 的 30 帧全部派生自这一下。
  这一拍 L = 0、延迟队列一帧没走，派发路径与改前相同（完成线程上只多了几次原子读写）。第二次（代码只比第一次多了"时钟起不来时收回派发线程"与两处注释）V2 = 0、19 项自动项全过。
- V1 p99 第一次 4.256 ms 来自 22:55:16–21 那几秒 GPU 占用 65%（整场 GPU > 50% 的秒有 17 个；那段时间桌面在用，load.log 里有活动监视器、WindowServer），第二次 2.950 ms；avg 1.871 与 G7 基线差 +0.04 ms。
  渲染路径本会话没动（显示历史只在 `--preview` 时开；输出环加深不改每帧的 GPU 工作）。
- **RSS 起点比 G7 高约 22 MB**：headless 默认 videoDelay，渲染器 NV12 输出环 8 → 12（PGM 环 + 多画面环各多 4 个 1080p NV12 ≈ 12 MB），是常驻量、不随时间涨；
  两次都是前 5 分钟爬升、300 s 之后持平（907.9 → 907.4、904.2 → 903.9），拟合斜率是 W4-A 那类"不足 1 h 仅供参考"的数。要和改前逐字节比内存用 `--av-compensation audioPTS`。

## 3. 没做的和原因

| 项 | 原因 / 去向 |
|---|---|
| App 接线（`audio.engine.videoDelay = engine`、渲染器两个选项、displayDelayProvider） | prompt：App 归检查点胶水或 97。三行写在问题单 `W1B4-g8-ownership-and-glue.md` §2。不接 = audioPTS 行为（W5-C 现状），文件不会错位，只是监听照旧晚 L |
| 开录起点按节目输出时间线（`RecordingStart(tick:tickTime: 拍点 + 当前延后)`） | 提案 028 第 3 条用户定"只写进报告"。不改的后果见 §5 第 3 条；改法在问题单 §2 |
| Stats 的 `video_delay_ms` | 交付 4：先放 EngineCounters，字段归提案 022 的 B2（P5）；P5 开字段后 StatsAssembler 填 `counters.videoDelayMs` 一行 |
| 提案 028 的契约文字与 `renderMs` 一行 | 契约归 P5 / 契约会话（用户批口径时说明了） |
| A5 真回环 | BLOCKED-硬件（§2.1）；空设备模拟做了 |
| 每路效果、自写压缩器 | prompt 不做项（102）。102 把自测的延迟写进同一个 `EffectLatencyTimeline` 就自动进视频延后（§5 第 7 条） |
| 外部显示的 Aux（源是输入 n）延后 | 不是 PGM、与 Master 的声音无关，没动（§1.5） |

## 4. 对契约的疑问

1. **提案 028 已批，契约文字还没落**（Render.swift 两处注释与 `renderMs`、Stats.swift `latencyMs` 注释、CONTRACTS.md §3 / §7 / §2.7）。落之前，读契约的人会以为 tickTime 一定是拍点——
   本会话所有改动都在 L = 0 时与以前逐值相同，只有接了视频引擎且开了压缩 / 限幅才会看到拍点 + L。
2. **`video_delay_ms` 进 Stats**：P5 的提案 022 草稿 B2 已列；批了以后填数一行（§3）。顺带：要不要把 `videoDelayOverflow` / 显示的 `displayDelayShortfalls` 也进 Stats 只作诊断——本会话不建议，留在计数器里。
3. **API / tally 的 `tickTime`**（StateFeed / TallyFrame / docs/api.md）是"状态变化那一拍的拍点"，没跟着变（C1 / C2 量的是状态，不是输出）。videoDelay 下画面在输出里出现 = 它 + L，
   docs/api.md 要不要补一句，归 103 或检查点。
4. **L1 含 L**（提案 028 第 4 条）：开着长前瞻限幅时 L1 可能越过 3 帧的必须档——这是用户接受的"PGM 端到端多 L"，但测试标准 §4 的 L1 阈值是否对 videoDelay 例外，要用户定。

## 5. 下一个会话需要知道的坑

1. **App 不接线就没有监听同步**（§3 第 1 行）：音频引擎默认 videoDelay，但"没接视频引擎时按 audioPTS 走"是有意的保险——别以为默认值就生效了，看 `audioEngine.avCompensationInEffect`。
   接了音频而渲染器没开 `videoDelayHeadroom`：延迟队列扣着输出缓冲，环（8）会被扣满、退回池子分配（渲染线程分配，T1 会红）；没开 `displayDelayHistory`：监视器拿不到延后的帧，
   `displayDelayShortfalls` 一直涨、显示退回最旧的完整那一帧（≈ 不延后）。三样要一起接。
2. **消费者可能在两条线程上被调**（完成线程当场派发 / 派发线程到期派发），从不同时，交接有 acquire / release；按线程 ID 做事的消费者（thread-local、"只在完成线程上"之类的断言）要注意。
3. **开录起点仍是拍点**（用户定只写报告）：videoDelay 下开录那一刻 L > 0，视频轨从 L 开始、**AVFoundation 在 0…L 读出一帧黑**（空 edit），两轨首尾各错 L；
   frameprobe 按"第一帧 = 第 startTick 拍"推拍号会把整秒配对全判成不在整秒——量的时候给 `--start-tick −round(L × fps)`（本会话的 headless 用例就是这样）。
   录制中途改 Master 效果（L 变了）之后 frameprobe 的拍号会整体错开 ΔL（> 半帧时整秒判定失效，配对本身仍对齐）。问题单 `W1B4-w1-testkit-frameprobe-delayed-video-start.md`。
4. **L 变化的那一下**：视频按 1/4 拍 slew（35 ms 要 150 ms），音频当场拼接，之间约"对齐延迟 + slew"的时间音画差最多 |ΔL|；非 Master 来源（ISO 音轨、Bus A / B / 耳机）
   在 L_m 变的那一块补静音 / 丢样本——**ISO 音轨也会因为开关 Master 的限幅而多一段静音 / 少一段**（提案 028 写明、用户批了）。
5. **headless 默认就是 videoDelay**：渲染器 NV12 环 8 → 12（1080p PGM 多 12 MB，PVW / 多画面的环建了再各多 12 MB）；gate4 / perf 的 RSS 绝对值会比 G7 基线高一点（S2 是斜率，不受影响）。
   要和改前逐项比，用 `--av-compensation audioPTS`（渲染器不加深）。
6. **派发线程是第二条 time-constraint 实时线程**（除时钟线程外，加上渲染器的完成线程一共三条）；L = 0 时它一直睡在信号量上，不占 CPU。
7. **102 叠在本分支上**：Integration 的 `ConsumerPump` / `AudioEngine` / `AudioEngineStatus` / `AudioEngineConfiguration` 本会话都改了；102 的自测延迟只要写进
   `EffectLatencyTimeline`（`BusEffectsController.publishLatency` 那条路），videoDelay 下就会自动交给引擎（`syncVideoDelay` 读的是 `effects.latencyFrames(.master)`）。
   自写压缩器按设计 0 延迟 → 不会产生视频延后。
8. **测试宿主**：`AVSyncRig`（IntegrationTests）用真 Engine + 假渲染器 + 空设备音频引擎共用一台状态机，起法见 `VideoDelaySupport.swift`；
   空设备的"扬声器出声"时刻 = 混音块 host time（直接挂 Master tap，不经泵），可以复用来量别的监听类指标。
9. **视频延后只跟 Master 的效果链延迟**（prompt 的定义）。提案 026 的监听总线（`AudioState.monitorSource`，引擎侧归 102）若选了别的总线、那条总线的效果延迟又与 Master 不同，
   耳机里的声音与画面差 L_bus − L_m；要不要让视频延后跟"当前监听的那条总线"，等 102 落地监听总线时一起定（`AudioEngine.syncVideoDelay` 一处）。
10. harness 分支是 `claude/w1-core-4-listen-sync-5e151a`，OWNERSHIP 按 `w1-core-4` 找：收尾建了同名本地分支指同一提交，检查点合并用哪个都行。
