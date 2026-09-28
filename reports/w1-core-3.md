# W1-B3 引擎启动第一秒的停顿 + 系统守护进程突发时成串跳拍 —— 报告（分支 w1-core-3）

日期 2026-09-28。机器 Apple M5 Max / macOS 27.0（Darwin 27.0.0）/ Xcode 27 / Swift 6.4；AC 电源；温度未记录。
worktree `.claude/worktrees/w1-core-3`，从 `main`（95757f7）开；分支 `w1-core-3`（prompt 81）。
只动了 `Packages/SwitcherCore/Sources/SwitcherEngine/`（Engine/Engine.swift、Clock/ProgramClock.swift、Clock/RealtimeThread.swift）、
`Tests/SwitcherEngineTests/`（EngineTests.swift、Fakes.swift、ClockTests.swift）、`Packages/SwitcherCore/Sources/SwitcherRender/`（Renderer/MetalRenderer.swift、
新文件 Renderer/RealtimeThread.swift）、`Tests/SwitcherRenderTests/`（RealtimeRendererTests.swift）与本报告 / reports/w1-core-3-run.md。
契约、参考图、headless、App 一个字节没动（量测时给 App 与引擎加过临时探针，量完 `git checkout` 还原，不在任何提交里）。

## 1. 做了什么

### 1.1 启动"停顿"的定位：不是停顿，是节目时钟起在 t0 之后（App 侧的 control.start 吃掉了提前量）

先按 prompt 量 headless（release，g4 节目 + g4 脚本，`--audio-device null`）：

| 运行 | 提前量 | engine.start 之后 t0 距现在 | 第 1 行 stats | 结论 |
|---|---|---|---|---|
| m1（修前，默认 `--lead-ms 1000`） | 1000 ms | 864 ms | tick 8：render_ms 4.31、missed 0、jitter 0.02、drop 全 0 | headless 没有停顿；第 1 行 render_ms 偏高是头几帧的首次代价（下面 1.2） |
| m3（修前，`--lead-ms 100`） | 100 ms | 46 ms | tick 57：missed 0、jitter 0.01 | 100 ms 提前量也够 |

再给引擎与渲染器加临时探针（各阶段耗时、前 6 帧的 CPU / GPU 时间，最后删掉），headless 里 `Engine.start` 总共 **~2 ms**：
`renderer.prepare` 1.6–2.0 ms（着色器库 + 4 个管线状态 0.8 ms、3 重缓冲纹理 0.08 ms、纹理表 + 输出环 0.7 ms、aux 0.001 ms、标签 + 线程 0.06 ms）、
`stateMachine.start` 0.015 ms、`prepare(upTo:)` 0.02 ms、`clock.start` 0.02 ms。着色器源码在 headless 里是运行时编译，但系统着色器缓存按二进制路径命中；
探针程序（scratchpad/probe-shader）量到**缓存未命中时 `makeLibrary(source:)` 600–1055 ms**、命中 0.5 ms（同一路径的二进制重编译后仍命中；App 用 default.metallib，不编译）。

App 才是问题单的现场，所以用带探针的引擎编了 Debug App（`make gen && make build-app`，产物 PlusMix.app），并在 `SwitcherSession.start` 里临时打点
（m0 节目 8 路合成源、`--no-api --audio-device null`，跑完还原 App 源码）：

| App 运行 | inputs.reconcile | control.start | audio.start | 到 engine.start 时 t0 距现在 | engine.start 自己 | 第 1 行 stats |
|---|---|---|---|---|---|---|
| 第 1 次（冷） | 21 ms | **686 ms** | 65 ms | **−472 ms** | prepare 2.2 ms + 状态机 0.06 ms | tick 90：**jitter 479 / missed 28**，30 fps 路 drop 12、60 fps 路 drop 28，fps 44.7 / 89.5 |
| 第 2 次（2 s 后再起，热） | 20 ms | 57 ms | 54 ms | +169 ms | prepare 1.8 ms | tick 54：**jitter 0.0 / missed 0**、drop 0 |
| 未打 App 点的一次（只有引擎探针） | | | | −477 ms | prepare 2.0 ms | tick 90：jitter 482 / missed 28；第 0 拍 wake − ideal = 482.06 ms |

- App 定 `t0 = now + 300 ms` 之后先做 `inputs.reconcile` → `control.start()`（冷启动 686 ms：状态推送源 / MIDI / 快捷键；第二次 57 ms）→ `audio.start`，
  再调 `engine.start`，这时 t0 已过去 472–477 ms。时钟线程一起来就发现第 0 拍早过期：第 0 拍立即渲染（wake − ideal = 482 ms，这就是 jitter_ms），
  handler 返回后第 1–28 拍都已到期 → 一次跳 28 拍（`didSkipTicks`），**missed_render = ⌊起晚 / 16.67⌋ = 28**；W2-B2 的 377 ms / 22 拍、G4 的 467 ms / 28 拍
  全部满足同一公式。这 480 ms 里合成源按自己的时间线推进了 14（30 fps）/ 29（60 fps）帧，3 格传输环挤掉 12 / 28 帧 = 第一行的 drop；之后 dup +30/s 是设计内的。
- 所以"停顿"四个候选里的答案是**节目时钟起早了**（相对引擎与 App 的准备工作，t0 定得太早），不是 Metal 管线 / 着色器编译（App 里 2 ms）、
  不是纹理池 / 帧槽分配（0.8 ms）、不是音频引擎（54–65 ms，也在 t0 之后但不是大头）。渲染线程没有被拖住：第 0 拍 handler 0.4 ms，之后每拍 0.2–0.7 ms。
- 引擎不能动 t0（音频引擎、输入、录制都按它起）。引擎侧能做的两件事都做了（1.2、1.3）；**根治在 App：先起控制层 / 音频 / `engine.warmUp()`，再定 t0**
  （§5 第 1 条给了具体改法）。headless 早就是这个顺序（慢活在算 t0 之前、`⚠️ 起晚了` 警告），所以从不出现。

### 1.2 首帧的一次性代价与"起时钟之前预热"

探针（headless release，lead 1000）里时钟起来后前几帧：

| 帧 | render() CPU | gpuStart − 提交 | GPU 执行 | 完成线程醒来 − gpuEnd | 说明 |
|---|---|---|---|---|---|
| 0 | 2.41 ms（建 16 张输入纹理） | **12.93 ms** | 3.08 ms | 0.09 ms | 命令队列第一次提交 + 管线 / 私有纹理第一次用 |
| 1 | 0.63 ms（+14 张） | 1.51 ms | 1.77 ms | 0.10 ms | |
| 2–5 | 0.26–0.28 ms（每帧 +14–16 张，到第 5 帧 90 张） | 0.17–0.65 ms | 1.11–1.61 ms | 0.10–0.12 ms | 输入 IOSurface 逐个进纹理表（预热期允许分配，池深 8 × 9 路 × 2 平面） |

第 0 帧 2.4 + 12.9 + 3.1 = 18.4 ms 在第 1 拍到期之后才完成——60 fps、在途 ≤ 2 下不跳拍，但第一帧出画晚了一拍。
修法：`MetalRenderer.prepare` 末尾做一次**首帧空渲染**（`warmUpGPU`：空状态、空输入表，真走一遍 `encodeFrame` 到 slot 0 与输出环的一个缓冲，同步 `waitUntilCompleted`，
再放资源；不经过完成线程、不进提交 / 完成计数、不给 sink）。用例 `testW1B3_prepare_warmRender_firstRealFrameGpuStartLatencyUnder4ms`：修前第 0 帧 gpuStart − 提交
4.4 / 5.5 / 5.7 ms（测试宿主里）、修后 0.67 ms（稳态中位 0.9），预热帧自己付掉了 5.2 ms。输入纹理的首次创建不能预热（IOSurface 未知），
它每帧 0.3–2.4 ms、不超过一拍，留着。

引擎侧把 `renderer.prepare` + 状态机线程 + 第 0 拍快照独立成幂等的 **`Engine.warmUp()`**（`start` 没预热会自己调；`stop` 也能释放只预热没起的引擎），
并加 **`Engine.clockStartLag`**（起时钟那一刻已过第 firstTick 拍多久；准时为 0）给组装方看。用例 `testW1B3_startup_firstTwoSeconds_missedRenderAtMostTwo`
按 App 的顺序建模（假渲染器 prepare 600 ms 模拟着色器缓存未命中、300 ms 提前量、两路 30 fps 源从 t0 按自己的时钟推帧）：修前起晚 316 ms /
头 2 秒 missed_render 18 / 每路 drop 9 / jitter 316（红，与 App 同一签名）；改成先 `warmUp` 再定 t0 之后 0 / 0 / [0, 0] / 0。

### 1.3 到达余量对启动期的免疫

G4 复核已经确认 W1-B2 的初值 / 上限 / 起流块作废让停顿后的恢复只损失停顿期间被传输环挤掉的帧（drop 停在第一秒），本次 App 探针再次看到同样的曲线
（第 2 行起 drop 不涨、dup +30/s）。停顿期间的 drop 是 SPSC 传输环在渲染线程看到之前就挤掉的，不是余量算法的选择，余量这边没有可改的；
先预热再定 t0 之后根本没有这段时间。没动 ArrivalPacing。

### 1.4 守护进程突发时成串跳拍：定位 = GPU 侧完成晚，渲染线程按时醒着

对 G4 的十次 10 分钟运行（10min-run1/2/3、10min、g4b–g4g 的 stats.jsonl，只读）逐秒对比 missed_render 增量与 jitter_ms / render_ms：

| 运行 | 行 / 拍 | +skipped | jitter_ms（该秒最大） | render_ms（该秒均值 / 全程中位） | 超出中位的总和 ≈ GPU 完成晚的总量 |
|---|---|---|---|---|---|
| run1 | 566 / 33970 | +1 | 0.019 | 3.05 / 1.96 | 64 ms |
| run1 | 567 / 34030 | +1 | 0.025 | 3.34 / 1.96 | 81 ms |
| run2 | 410 / 24609 | +1 | 0.018 | 2.66 / 2.00 | 39 ms |
| run3 | 538 / 32297 | +1 | 0.033 | 3.68 / 2.02 | 98 ms |
| run3 | 540 / 32416 | +4 | 0.029 | 5.39 / 2.02 | 185 ms |
| run3 | 548 / 32896 | +2 | 0.022 | 4.04 / 2.02 | 115 ms |
| run3 | 550 / 33017 | +1 | 0.021 | 2.63 / 2.02 | 36 ms |
| run3 | 554 / 33256 | +3 | 0.047 | 4.54 / 2.02 | 141 ms |
| g4d | 334 / 20050 | +1 | 0.026 | 3.08 / 2.10 | 58 ms |
| 其余六次 | — | 0 | 全程 max ≤ 0.143 | render_ms > 1.6 × 中位的秒只有 5 个（都是第 1 行或孤立的 3.4–3.7） | — |

- **跳拍秒的 jitter_ms 全部 ≤ 0.05 ms**：时钟线程（= 渲染线程，已是 time-constraint 实时线程）每一拍都准时醒；CPU 侧调度不是原因。
- **跳拍秒的 render_ms 均值全部抬高**（2.6–5.4 vs 中位 2.0），render_ms 取的是 GPU 时间戳 `gpuEnd − 拍点`，与完成线程何时醒无关；
  超出中位的总和 40–185 ms 与跳拍数成正比（+1 ≈ 40–100 ms，+4 ≈ 185 ms）：每一串就是一次 35–100 ms 的 GPU 完成延迟——在途 2 帧都没完成，
  之后 2–5 拍到期即跳。归因：**GPU 侧**（别的进程建 GPU 上下文 / WindowServer / Chrome 抢占，或驱动排队），与 load.log 里 tccd / peopled /
  AddressBookManager / Chrome 突发对齐，这些进程起来时正是创建 Metal / CoreAnimation 上下文的时刻。
- 修前从每秒平均值只能这样侧推；修后渲染器每次 `.skipped` 都按"跳拍时最旧在途帧的 gpuEnd 是否早于跳拍时刻"归因（1.5），下次再出现直接分类。
- **本次 gate4 第一次运行（w1b3，§2.3）又撞上两串（+2 / +6），现场比 G4 更完整**：跳拍那一秒时钟线程 jitter 0.020 ms（准时醒）、render_ms 3.97 / 4.58 ms；
  **同一秒每路 `latency_max_ms` 从 10 跳到 84 / 128 ms、合成源线程"唤醒 max 70–105 ms"（生产者线程晚醒 100 ms）、状态机快照过期 8 次（等于跳拍数）、
  各路 drop +3～+9（3 格传输环在生产者线程醒来一次推 8 帧时挤掉的）**，load.log 同时刻 opendirectoryd 18.5% / storagekitd 16.1% / WindowServer 21–26%（用户在用桌面，Claude 桌面端 12–42%）。
  即：**一次 100–130 ms 的全进程停顿——所有普通优先级线程（合成源、状态机、消费者派发）都没被调度，GPU 的完成也晚了 70–100 ms；只有实时的时钟线程按时醒**。
  G4 的十次运行交叉验证同一签名：V2 > 0 的五次（run1 / run2 / run3 / g4d / 本次）合成源"唤醒 max" 18.5 / 29.6 / 31.6 / 70.3 / 105 ms、快照过期 5 / 1 / 17 / 2 / 8；
  V2 = 0 的五次唤醒 max 0.15–0.27 ms、过期 0。所以问题单里"CPU 侧没被调度 vs GPU 侧积压"两者**同时发生、同一根因**：系统守护进程 / 桌面突发让整个进程的
  非实时线程与 GPU 一起停 100 ms 量级；渲染线程本身（实时）从未晚醒，跳拍是"在途 2 帧 100 ms 没完成"的必然结果，用户态改调度策略救不了 GPU 那一边。

### 1.5 做了什么：完成线程实时策略 + 跳拍归因计数 + 诊断量

- **完成线程挂 time-constraint 实时策略**（新文件 `SwitcherRender/Renderer/RealtimeThread.swift`：pthread + QoS + `thread_policy_set`，SwitcherRender 只见 Contracts、
  不能用 SwitcherEngine 的 NativeThread，是同一做法的独立实现）。参数与时钟线程同一套：period = 拍长、computation 1/4 拍、constraint 半拍
  （申报 1/8 拍时内核读回来是 1/4 拍，它有下限）。它放行在途计数，普通 user-interactive 线程在守护进程突发时晚几毫秒醒就可能多跳一拍；
  实时之后 CPU 侧这一因素只剩微秒级（用例里放行延迟最大 0.175 ms）。
- **渲染线程（= 时钟线程）已经是实时的**（W1-B 起），本次加的是"读回来"的证明：`NativeThread.machPort` / `readBackTimeConstraint()`、`ProgramClock.readBackTimeConstraint()`，
  用例 `testW1B3_clockThread_timeConstraintPolicyReadsBackRealtime`（get_default = 0、period 400000 / computation 100000 / constraint 200000 = 申报值；
  对照普通线程读回 get_default = 1）。thread_policy_get 的语义先用探针程序验证（scratchpad/probe-policy）：挂了策略的线程 get_default = 0 且参数 = 设置值，
  普通线程 get_default = 1 与内核默认值（computation 120000 / constraint 240000）。
- **跳拍归因**（`MetalRenderer`，零分配：渲染线程把跳拍时刻写进 64 项预分配原子环；完成线程处理下一帧——它就是跳拍时最旧的在途帧——时按它的 gpuEnd 分类：
  gpuEnd ≤ 跳拍时刻 → `skippedCompletionLate`（GPU 早完成了、是放行晚），否则 `skippedGPULate`）。另有 `takeCompletionWakeLagMax()`（完成线程醒来 − gpuEnd）、
  `takeSkipOldestAgeMax()`（跳拍时最旧在途帧年龄），`SWITCHER_RENDER_DIAG=1` 时完成线程每归因一次打一行 stderr。都是诊断量，不进 Stats（铁律 4 的那份仍是引擎的 missed_render；
  加进 stats.jsonl 是契约，见 §4）。用例：`testW1B3_skipAttribution_classifiesByGpuEndVsSkipTime`（规则）、`testW1B3_skipAttribution_underGPUPressure_sumEqualsSkipped`
  （4K + 16 路每 0.5 ms 调一次：跳过 13 = GPU 侧 11 + 完成线程 2，两类之和 = skipped）。
- **in-flight 深度没改**：默认 `maxInflight = 2` 是 CONTRACTS.md §6 T3"CPU 领先 GPU ≤ 2 帧"，改它是契约；判据与建议见 §4 第 2 条。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 2.1 新增用例（SwitcherCore `swift test`，debug；数字是本机单跑 / 整包跑的值）

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testW1B3_startup_firstTwoSeconds_missedRenderAtMostTwo`（Engine） | 修前（无 warmUp）：时钟起晚 316 ms、头 2 秒 missed_render 18、各路 drop [9, 9]、jitter_ms 316；修后：起晚 0.0 ms、missed 0、drop [0, 0]、jitter 0.0 | missed ≤ 2、drop 不因启动停顿而计（= 0）、起晚 ≤ 20 ms | ✅ |
| `testW1B3_prepare_warmRender_firstRealFrameGpuStartLatencyUnder4ms`（Render） | 修前第 0 帧 gpuStart − 提交 4.36 / 5.49 / 5.67 ms（稳态中位 0.87–0.91）；修后 0.67 / 0.93 / 0.74 ms（稳态 0.72–0.91），预热帧自己 4.9–5.5 ms | ≤ 4 ms；warmupFrames = 1；skipped 0 | ✅ |
| `testW1B3_clockThread_timeConstraintPolicyReadsBackRealtime`（Engine） | 读回 get_default = 0、period 400000 / computation 100000 / constraint 200000 tick = 申报值；普通线程对照 get_default = 1 | 实时（非默认策略）、参数一致 | ✅ |
| `testW1B3_completionThread_timeConstraintPolicyReadsBackRealtime`（Render） | 读回 get_default = 0、period 400000 / computation 100000 / constraint 200000（申报 1/8 拍时内核读回 1/4 拍，改成与时钟线程同参数） | 同上 | ✅ |
| `testW1B3_skipAttribution_classifiesByGpuEndVsSkipTime`（Render） | gpuEnd < / = 跳拍时刻 → completionLate，> → gpuLate | 规则 | ✅ |
| `testW1B3_skipAttribution_underGPUPressure_sumEqualsSkipped`（Render） | 4K + 16 路每 0.5 ms 调一次：跳过 13 = GPU 侧 11 + 完成线程 2（单跑）；整包跑 69 = 23 + 46；放行延迟最大 0.175–0.209 ms、跳拍时最旧在途帧年龄最大 6.2–7.0 ms | 两类之和 = skipped、gpuLate > 0、完成回调数 = 提交数 | ✅（比例不断言，原因见用例注释与 §5 第 4 条） |

### 2.2 既有用例（两包全过；参考图一张没动）

| 包 / 用例 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| SwitcherEngineTests 全量（debug） | 96 个（95 + 新增 1；第二次整包 82 个 Render + 96 Engine + Contracts）0 失败 | 0 失败 | ✅ |
| SwitcherRenderTests 全量（debug） | 82 个 0 失败 0 跳过（第一次整包 1 失败是压力用例的比例断言，已改，见 2.1） | 0 失败 | ✅ |
| `testV8_*`（Render 参考图） | 所有参考图 **PSNR ∞ dB / SSIM 1.0000**（逐像素一致，与 main 相同） | PSNR ≥ 40 / SSIM ≥ 0.98 | ✅ |
| `testT1_renderThreadSteadyStateAllocations`（debug） | 600 帧 SwitcherRender 代码直接引发 0 次分配（debug 下 Swift 泛型装箱 10818 次，只打印；release 数字见下） | own = 0 | ✅ |
| `testT1_renderThreadSteadyStateAllocations`（**release**） | 600 帧内渲染线程 SwitcherRender 代码直接引发 **0** 次、全部 Swift 代码 **0** 次；Metal / CoreVideo 内部 8414 次（每帧 14.02，命令缓冲区 / 编码器对象，与本次改动无关：render 路径只在 .skipped 时多写一个原子环，T1 里 skipped = 0）；纹理表预热期 64 张、输出环退回 0 | own = 0、Swift = 0 | ✅ |
| `testW1B_renderPath_zeroAllocationsInSteadyState`（Engine，**release**） | 渲染线程 + GPU 完成线程稳态 ≥ 200 拍 malloc / free = 0（路径含 warmUp 之后的 start、完成线程的归因读环） | 0 | ✅ |
| `testT3_cpuNeverLeadsGPUByMoreThanTwoFrames` | 提交 1849–1989、跳过 11–151、最大在途 2、完成 = 提交 | 在途 ≤ 2 | ✅ |
| `testV1_1080p60EightInputsFourOverlays_renderMs` | 平均 2.678 / p50 2.745 / p99 2.990 / max 3.065 ms（debug 宿主；提交→GPU 开始 0.713、GPU 执行 1.588） | 平均 ≤ 6、p99 ≤ 12 | ✅ |
| `testV2_missedRender_30msRenderer_exactSkipCount`、`testV3_wakeJitter_30s_p99Under1ms`、`testV3_clockDeadlinesComeFromSpecNotAccumulation` | 全过（V3 30 s p99 见日志，≤ 1 ms） | 精确跳拍数；p99 ≤ 1（本机）/ 4 | ✅ |
| `testL1_*`、`testV4_*`、`testV5_*`、`testV6_*`、`testV7_*`、`testV9_*`、AuxOutput / Multiview / Keyer / Transition / Display 用例 | 全过 | | ✅ |

### 2.3 `scripts/gate4.sh --minutes 10 --label w1b3 --baseline baselines/g4-m5max.json`（运行报告 reports/w1-core-3-run.md；产物 .build/gate4/w1b3/）

第一次运行 18:50–19:03（提交 db44acb，load 跑前 1.94 → 跑后 1.65；机器上没有别的编译 / 测试，用户在用桌面，Claude 桌面端 12–42% CPU）：

| 指标 | 数值 | 阈值 | 通过 | 与基线 g4-m5max 的差 |
|---|---|---|---|---|
| V1 | avg **1.956** / p99 2.751 ms | 必须 avg ≤ 6 / p99 ≤ 12；不比基线差 10% | ✅ | avg **−0.193 ms**（−9%）、p99 +0.107 |
| V2 | **8 / 35940 拍（0.0223%）**：19:59:35 拍 26248 +2、19:00:58 拍 31229 +6 | 10 分钟内 0 | **❌** | 两串都是 §1.4 的全进程停顿（同秒各路 latency_max 84 / 128 ms、合成源线程晚醒 105 ms、快照过期 8） |
| V3 | p99 **0.056** / max 0.089 ms | p99 ≤ 4 | ✅ | −0.036 ms |
| V4 | 精确核算设计外 118 帧（stats.jsonl 全程；全部是两串停顿里传输环挤掉的 drop 与之后的 dup）/ frameprobe 在播段 **0** | 0 | ❌（引擎口径）/ ✅（在播段） | 派生自 V2 |
| V5 | −8 帧 | ≤ 2 | ❌ | = V2 |
| V6 / V7 / A1–A4 / E1–E3 / E5 / C1–C4 | 全过（Cut 第 1000 拍、90 次干净；Fade 0.269 帧；T-bar 0.33%；A2 0.000；A4 0.208 ms；E5 0.0 ms；C3 不一致 0；C4 12000/12000） | | ✅ | |
| S3（信息） | CPU 42.8% / GPU 30.3% | ≤ 60 / ≤ 50 | ✅ | CPU −7.9%、GPU −0.2% |
| S2（信息） | 50.5 MB/h 拟合（861 → 882，前几分钟爬升，不足 1 h） | ≤ 10 | ❌ 拟合值 | 与 G3 / G4 同类信息项 |

**结论：V2 不是 0，做不到就直说**——两串跳拍是系统 / 桌面突发让整个进程停 100–130 ms 的那一类（§1.4），本次改动把 CPU 侧能做的都做了（完成线程实时、归因计数），
GPU 侧 100 ms 的完成延迟用户态没有办法；V1 / V3 比基线还好（−9% / −0.036 ms），V4 设计外与 V5 全部派生自这 8 拍。第一次运行没开 `SWITCHER_RENDER_DIAG`，
归因计数 headless 又不打印（§4 第 1 条），所以这 8 拍的分类只能从 render_ms 侧推（GPU 侧）；第二次运行开着诊断再跑一次，结果见下。

第二次运行 19:12–19:25（`--label w1b3-2 --no-build`，`SWITCHER_RENDER_DIAG=1`，同一提交，load 跑前 ≈ 1.7；机器上没有别的编译 / 测试）：**19 / 19 自动项全部通过**

| 指标 | 数值 | 阈值 | 通过 | 与基线 g4-m5max 的差 |
|---|---|---|---|---|
| V1 | avg **1.993** / p99 2.737 ms | 必须 avg ≤ 6 / p99 ≤ 12；不比基线差 10% | ✅ | avg **−0.157 ms**（−7%）、p99 +0.093 |
| V2 | **0 / 35940 拍** | 10 分钟内 0 | ✅ | — |
| V3 | p99 **0.083** / max 0.122 ms | p99 ≤ 4 | ✅ | −0.009 ms |
| V4 | 精确核算设计外 **0**（stats.jsonl 全程）/ **0**（frameprobe 在播段）；帧号倒退 0 | 0 | ✅ | — |
| V5 | +0 帧 | ≤ 2 | ✅ | — |
| V6 / V7 / A1–A4 / E1–E3 / E5 / C1–C4 | 全过 | | ✅ | |
| S3（信息） | CPU 42.8% / GPU 35.4% | ≤ 60 / ≤ 50 | ✅ | CPU −7.9%、GPU +4.9% |
| S2（信息） | 50.4 MB/h 拟合（858 → 873，不足 1 h） | ≤ 10 | ❌ 拟合值 | 同类信息项 |

这次没有全进程停顿（合成源线程唤醒 max 0.136 ms、快照过期 0、`render-diag` 0 行——没有跳拍就没有归因行），V1 / V3 都比基线好。
两次对照正好说明 §1.4 的结论：同一提交、同一场景，有没有跳拍取决于那 10 分钟里系统 / 桌面有没有把整个进程停 100 ms，不取决于渲染线程。

### 2.4 `make lint BRANCH=w1-core-3`

lint-rules（禁词 / 版本号 0.1.0 / Package.swift 约束）、check-deps（8 个包依赖方向）、check-rt-symbols 全绿；check-ownership 在三个代码提交上全绿（9 个改动文件都在范围内），
报告提交之后对 **`reports/w1-core-3-run.md` 一个文件报越界**：prompt 81 要求 gate4 的运行报告改成这个名字，但 docs/OWNERSHIP.md 的 `w1-core-3` 行与 check-ownership.sh 的
通用规则只放行 `reports/<分支名>.md`，两处都不在我的目录里，没有绕过检查——写了 reports/issues/W1B3-g5-ownership-run-report-file.md 请 G5 在 OWNERSHIP 行加一项（一行改动）。

## 3. 没做的和原因

1. **App 的启动顺序没改**（App 不在本会话范围）：根因是 `SwitcherSession.start` 定 t0 之后才做 686 ms 的 `control.start()`，引擎再快也补不回来。
   引擎给了 `warmUp()` 与 `clockStartLag`，改法写在 §5 第 1 条；改之前 App 第一秒仍会是 jitter ≈ 470 ms / missed 28。
2. **没把"起晚的拍"从 missed_render 里剔出去**：时钟起在 t0 之后时第 0 拍立即渲染、之后到期的拍照跳照记（V2 口径原文"下一拍到期时上一帧尚未提交"字面成立），
   jitter_ms 也如实记第 0 拍的晚醒。改口径会让 App 的症状从 stats 里消失而画面开头那 480 ms 照样缺，用户就看不见问题了；要改是测试标准的事（§4 第 3 条）。
3. **in-flight 深度没改**（T3 契约，§4 第 2 条）；也没给 GPU 侧的抢占找到用户态的修法（macOS 没有公开的 GPU 优先级 API；命令队列 / 命令缓冲区没有优先级参数）。
4. **App 没在本分支跑全量测试**：App 只通过 SwitcherEngine / SwitcherRender 的公开接口用引擎，本次新增的都是新方法 / 新属性（`warmUp`、`clockStartLag`、
   `skipAttribution`……），没改任何签名；App 在本 worktree 用改过的引擎编过两次（探针量测）都能起。
5. 输入 IOSurface 的首次纹理创建（时钟起来后前 6 帧每帧 0.3–2.4 ms）没预热：prepare 时不知道会来哪些 IOSurface；不超过一拍，不跳拍。
6. **gate4 "跑一次 V2 = 0"跑了两次才有**：第一次 V2 = 8（两串全进程停顿，§1.4 / §2.3），第二次 0 且 19 / 19 过。两次都原样写进 reports/w1-core-3-run.md，没有挑数据；
   第一次那 8 拍在这版引擎上仍无法避免（GPU 侧 100 ms 没完成），只是以后能被归因计数直接分类。
7. `make lint BRANCH=w1-core-3` 差一项：check-ownership 不认 prompt 指定的 reports/w1-core-3-run.md（§2.4），不是代码越界。

## 4. 对契约的疑问

1. **跳拍归因要不要进 stats.jsonl**：`MetalRenderer.skipAttribution`（gpuLate / completionLate）、完成线程放行延迟、跳拍时最旧在途帧年龄现在是渲染器上的诊断量，
   headless / App 都没打出来（它们不在我的目录）。要让 gate 报告直接分类，得给 `Stats` 加字段（例如 `missed_render_gpu_late` / `missed_render_completion_late`）——
   契约，请裁；批了我再写 docs/contract-changes/ 提案。不批的话建议 headless 收尾摘要打印 `renderer.skipAttribution`（headless 的会话一行代码）。
2. **in-flight 深度（CONTRACTS.md §6 T3"CPU 领先 GPU ≤ 2 帧"）**：G4 的每一串跳拍都是一次 35–185 ms 的 GPU 完成延迟，要"全吸收"需要 in-flight ≥ 跳拍数 + 2
   （+1 → 3、+4 → 6，§1.4 表），每加一重 = 3 张 1080p BGRA 纹理 ≈ 25 MB 常驻、消费者在停顿后要吃一串迟到的帧（PTS 仍是拍点，文件正确；NDI / 虚拟摄像头显示一次卡顿）。
   稳态延迟不变（帧在拍点提交、2 ms 完成）。判据建议：若 8 小时长稳（W4-A）里这类突发累计的 V2 超过必须档 0.02%，把默认 `maxInflight` 提到 4（吸收 ≤ 50 ms 的停顿，
   覆盖 G4 十次里 9 串中的 5 串）并把 T3 改成"≤ 4 帧"；否则维持 2。数据够不够，你定。
3. **起晚的拍算不算 V2**：见 §3 第 2 条。若要改，建议 stats.jsonl 加 `clock_start_lag_ms`（引擎已有 `clockStartLag`）而不是从 missed_render 里减。
4. `Engine.warmUp()` 是 SwitcherEngine 的公开方法（不是 SwitcherContracts），App / headless 会话可直接用，不需要契约变更。

## 5. 下一个会话需要知道的坑

1. **App（W3-E 系列 / W2-B）**：`SwitcherSession.start` 改成 `await control.start()` → `try await audio.???` 之前先 `try await engine.warmUp()`，然后再
   `t0 = HostClock.now() + lead`、`audio.start(clock:)`、`engine.start(t0:)`；`control.start()` 冷启动 686 ms（MIDI / 推送源 / API）也要挪到定 t0 之前。
   改完用 `PlusMix --show … --stats … --no-api --audio-device null` 看第一行：jitter_ms 应 < 1、missed 0、drop 0；`engine.clockStartLag` 应为 0。
   量测方法：本报告 §1.1 的两张表就是用引擎 / App 里的临时 `fputs` 探针得到的（探针没提交），照着打点 10 分钟能复现。
2. **headless 的着色器源码编译按二进制路径命中系统缓存**：同一路径重编译后仍命中（0.7 ms），换路径 / 新二进制第一次 600–1055 ms；`--lead-ms 1000` 盖得住，
   但若把 headless 拷到别处跑第一次会"起晚了"。App 用 default.metallib 不受影响。
3. **thread_policy_get 读回**：挂了 time-constraint 的线程 get_default = 0 且参数 = 设置值；普通线程 get_default = 1、返回内核默认（computation 120000 / constraint 240000 tick）。
   申报 computation = 1/8 拍时内核读回 1/4 拍（有下限），完成线程索性与时钟线程同参数。
4. **跳拍归因的口径**：只归因"在途满"的 `.skipped`（`skip-no-output-buffer` / `skip-resource` 不算）；渲染线程记跳拍时刻的环容量 64 ≈ 1 s 连续跳拍，超过会覆盖旧项
   （两类之和仍等于跳拍数，分类可能错位）。归因由跳拍之后**第一个完成的帧**做，所以读计数要等完成线程处理完（用例里 sleep 0.3 s）。
   `SWITCHER_RENDER_DIAG=1` 打印在实时的完成线程上做（会分配、拿锁），只在诊断时开。
5. **首帧空渲染在 prepare 里同步等 GPU（≈ 5–13 ms）**：prepare 本来就允许阻塞；离线渲染器（OfflineRenderer）不走它。`MetalRenderer.warmupFrames` 恒为 1。
6. **测试宿主里第 0 帧的 gpuStart − 提交 只有 4–6 ms（headless 里 13 ms）**：同一进程之前的用例已经用过 Metal；用例阈值 4 ms 是按宿主定的，
   要看真实数字用 headless + 探针。
7. **停顿之后 30 s 内每路 latency_max_ms 停在 30–38 ms**（w1b3 第一次运行 rows 438–466，停顿前 10 ms）：停顿时生产者线程醒来一次推 8 帧，d 最大 128 ms，
   迟到路径把余量抬了一帧（每路"抬 8–12"），之后 8 s 窗口过去才降回；W1-B2 报告 §5 第 2 条"锁相 60 fps 源余量降不过拍点边界"让降得更慢。不是本会话的交付，
   数据在 .build/gate4/w1b3/stats.jsonl；G4 问题单第 2 条猜的"跳拍后每路 dup 3 帧才追回"就是它。
8. gate4 / 10 分钟运行期间别在桌面上开新进程：G4 十次里 9 串跳拍全对得上别的进程起 GPU 上下文的时刻（§1.4）；修后跳拍归因计数能直接分类，但 headless 还没打印它（§4 第 1 条）。
