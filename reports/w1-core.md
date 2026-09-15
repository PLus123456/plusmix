# W1-B 核心逻辑 —— 报告（分支 w1-core）

日期 2026-09-14；2026-09-15 按 G2 退回单修 V4（§1.4，问题单 `reports/issues/G2-w1-core-phase-crossing-dup-drop.md`）。机器 Apple M5 Max（6P + 12E）/ macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3；电源、温度未记录（桌面机；9-14 的测试全程无其他负载，9-15 的复测与端到端验证期间 G2 会话的 frameprobe 在另外两核上跑分析，load 2.7–3.8）。
worktree `.claude/worktrees/w1-core-f4b7cf`，从 `main`（bdab613）开；分支 `claude/w1-core-f4b7cf`，另打了同一提交的 `w1-core` 引用给 `make lint BRANCH=w1-core` 和 G2 合并用。
提交：`git log main..w1-core`，9-14 为 11 个（engine × 9 + reports × 2），9-15 再加 engine × 2 + reports × 1。`make lint BRANCH=w1-core` 绿（禁词 / 版本 / 依赖方向 / 归属 23 个文件全在范围内）；`make build-packages build-tools` 绿；SwitcherCore `swift test` 96 个全过（其中 SwitcherEngineTests 47 个，约 70 s；整包 110 s，大头是实跑）；9-15 之后 SwitcherEngineTests 59 个（+12 个 V4 到达余量用例）全过。

## 1. 做了什么

全部在 `Packages/SwitcherCore/Sources/SwitcherEngine/`（13 个文件，1899 行）+ `Tests/SwitcherEngineTests/`（9 个文件，1575 行）。没动 `Package.swift`（`Synchronization` 是标准库，不需要 swift-atomics，也没加 C target）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 ProgramClock | `Clock/ProgramClock.swift`、`Clock/RealtimeThread.swift` | 每拍理想时刻 = `TickClockSpec.time(of:)` 一次乘除，不累加；`mach_wait_until`；返回时已到期的拍全部跳过并回调 `didSkipTicks`（V2）；`JitterRecorder` 预分配环记每拍 wake − ideal（V3）+ 窗口最大值给 Stats。线程属性见 §1.1 |
| 2 FrameSlot | `Slots/LockFreeFrameSlot.swift`、`Sync/SPSCOverwriteRing.swift` | 传输环（无锁 SPSC，满挤最旧）+ 渲染线程私有候选表两级；`latest(atOrBefore:)` 取 pts ≤ 拍点的最新帧，跳过的算 dropped，未来帧留到下一拍，无新帧重复上一帧算 reused；零分配 |
| 3 StateMachine | `State/MixerReducer.swift`、`State/StateMachine.swift`、`State/StateThreadExecutor.swift`、`Sync/HazardPublisher.swift` | actor 持有 MixerState，跑在专用线程执行器上；`reduce` / `advance` 纯函数覆盖 27 条命令；Cut 原子换号；auto 转场第 s+k 拍 progress = k/d，到 d 对调；tbar 直接映射、≥ 1 提交；FTB / 叠加动画逐拍推进，中途反转从当前电平继续；`submit(IssuedCommand)` 按 sequence 严格顺序、乱序排队；`schedule(_:at:)` 按拍排程；`TickObserver` 每拍挂点；转场事件 `TransitionEventSink`（AFV）；每次 reduce 后 `HazardPublisher` 原子指针发布快照，渲染线程只借指针 |
| 4 Engine 骨架 | `Engine/Engine.swift`、`Engine/EngineCounters.swift`、`Engine/QueuedFrameConsumer.swift` | 时钟 → 确认状态机准备到本拍 → 借快照 → `noteRendered` + `requestPrepare(n+1)` → 每路 `latest(atOrBefore: t_n)` 填 `RenderInputTable` → `renderer.render`（.skipped 计 missed_render）→ GPU 完成回调派发给每个 `FrameConsumer` → 原子计数 → `makeStats()` 组 stats.jsonl 一行。`QueuedFrameConsumer` = 消费者侧有界队列 + 工作线程（慢了丢自己的） |
| 5 Show 读写 + 迁移 | `Show/ShowStore.swift` | 读头部 schemaVersion → 注册的 k→k+1 迁移步逐级升级 JSONValue 文档 → `Show.migrate` 解码校验；原子写文件。现在只有 v1，用一步假迁移测框架 |

### 1.1 实时线程属性：用了什么、为什么

节目时钟线程 = 渲染线程：pthread，创建时 `QOS_CLASS_USER_INTERACTIVE`，进线程后 `thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY)`，period = 拍长，computation = 拍长 × 0.25，constraint = 拍长 × 0.5，preemptible = 1（`ProgramClockOptions` 可关、可调）。设置失败退回纯 QoS，`ProgramClock.isRealtime = false` 让测试 / G2 看得见。

**为什么必须用实时策略（探针 2 / 3，60 Hz 拍点各跑 5–30 s，wake − ideal）**：

| 线程属性 | p50 | p99 | max |
|---|---|---|---|
| 默认 QoS | 2733 µs | 7214 µs | 7256 µs |
| user-interactive QoS | 4501 µs（另一次 2510） | 7184 µs（另一次 3692） | 7297 µs |
| user-interactive + `THREAD_LATENCY_QOS_POLICY` tier 0 | 1008 µs | 1034 µs | 1099 µs |
| user-interactive + time-constraint（30 s） | 8.6 µs | 32.3 µs | 62.2 µs |
| time-constraint，每拍忙 30 ms（申报 computation 2 ms） | 15.6 µs | 21.3 µs | 28.5 µs |

本机 macOS 26.6 `kern.timer.coalescing_enabled = 1`：非实时线程的 `mach_wait_until` 按 latency tier 加 leeway（tier0 最多 1 ms、tier1 5 ms……），命令行进程的 user-interactive 线程落在 tier1，p99 7 ms —— 连 V3 的"必须"档 4 ms 都过不了；tier0 也是恒定 ≈ 1 ms。只有 time-constraint 线程不被合并，p99 ≈ 30 µs。实测每拍忙 30 ms 远超申报的 computation 也没有被降级（跳拍数精确 300/600）。`DispatchSource` leeway 0 / `usleep` 走同一套定时器，一样被合并。代价：实时线程不该做无界的工作；渲染线程本来就只做"编码命令缓冲区 + 提交"，而且每拍都在 `mach_wait_until` 里阻塞让出，符合实时线程的用法。

状态机线程：user-interactive QoS，没挂实时策略（它靠信号量被唤醒，不做定时等待；唤醒延迟几十 µs，每拍有 16 ms 余量）。

### 1.2 原子指针发布快照的内存序论证（`Sync/HazardPublisher.swift`）

问题：读方 `load` 到指针 p 之后要用它（读字段 / retain），但在 load 与使用之间写方可能已经 `exchange` 了新指针并 release 旧对象，读方就碰了已释放的内存。所以不能"load 再 retain"。

做法（hazard pointer）：
- 读方（渲染线程，`ReaderSlot.borrow`）：① `p = published.load(seq_cst)`；② `hazard[i].store(p, seq_cst)`；③ `q = published.load(seq_cst)`；q ≠ p 则 p = q 回到 ②；相同则 p 受保护。用完 `hazard[i].store(nil, seq_cst)`。
- 写方（状态机线程，`publish`）：④ `old = published.exchange(new, seq_cst)`；old 进 retired 表；⑤ 逐个 `hazard[k].load(seq_cst)`，retired 里没被任何槽登记的对象才 release。

正确性：取 seq_cst 全序 S。设读方最终使用的是 p（旧对象），要证写方的 ⑤ 一定看到 hazard = p。
- 若 ② <ₛ ④：⑤ 在 ④ 之后，而读方在用完之前不会改 hazard，所以 ⑤ 读到 p，写方不释放 ✓。
- 若 ④ <ₛ ②：则 ③ 在 ④ 之后，③ 读到的是 new（或更新），≠ p，读方重试，不会用 p ✓。
两种情况穷尽，所以"读方在用的对象"永远在写方的扫描里可见。为什么必须 seq_cst：读方是 store(hazard) 后 load(published)，写方是 store(published) 后 load(hazard)，这是 Dekker / store-buffering 模式；acquire-release 允许 store 与其后的 load 重排，两边各自重排后就可能读方拿到 p、写方看到 hazard 为空、同时成立，然后 use-after-free。arm64 上 seq_cst store = `stlr`、seq_cst load = `ldar`，`ldar` 不会越过前面的 `stlr`（RCsc），代价是每次 borrow 两条带屏障的指令，可忽略。
- 对象内容可见性：写方构造 new 在 ④ 之前（程序序 + release 语义），读方 ①/③ 是 acquire 以上，所以看到完整构造的对象。
- 释放安全：读方对 *p 的读全部在 `hazard = nil`（release）之前；写方某次 ⑤ 观察到 nil（acquire）才 release 对象，所以读方的读 happens-before 释放。
- 有界性：每次 publish 后扫描，能释放的立刻释放；任一时刻被登记的对象 ≤ 读槽数 R，所以 retired 表长度 ≤ R（测试里稳态为 0）。写方从不等读方，读方从不等写方（重试只发生在写方恰好换了指针，每次重试对应写方一次进展）。
- 渲染线程借用期间只是 +0 引用；`takeUnretainedValue()` 是 retain / release，不分配。非实时读者（UI / API）用 `latest`，一把只护一个强引用的互斥锁。
- 测试：`testW1B_hazardPublisher_stress_noUseAfterFree_noLeak` 写方连发 20 万对象、3 条读线程不停借用校验 magic 与单调，0 错，结束时只剩当前对象；`testW1B_hazardPublisher_writerReleasesOnlyUnborrowedObjects` 证明被借的对象活到归还。

`SPSCOverwriteRing`（帧槽底层）的序：每格一个原子序号 seq 编进逻辑下标（Vyukov 有界队列思路）杜绝 ABA；生产者写元素后 `seq.store(L+1, release)`，消费者 `CAS(seq, L+1 → (L+1)|R, acq_rel)` 成功后才拷贝，拷完 `seq.store(L+cap, release)`；生产者挤最旧是 `CAS(seq, t+1 → t+cap)`，只可能与消费者的 claim 二选一成功，所以消费者拷贝中的格子永远不会被覆盖（帧里有 CVPixelBuffer，撕裂读会 retain 到垃圾指针）。唯一的等待是生产者撞上"消费者正拷这一格"（几十条指令），有界自旋 4096 次后改丢来帧并计数（100 万次压力里 0–6 次）。

### 1.3 状态机与渲染线程的衔接（prompt 没写细、这里定下来的）

- actor 用自定义 `SerialExecutor`（`StateThreadExecutor`，一条 user-interactive 线程）。命令走普通 `await`。渲染线程每拍只做 `noteRendered(n)`（原子 store）+ `requestPrepare(n+1)`（原子 max + `DispatchSemaphore.signal`，一次系统调用，无锁无分配）；执行器线程醒来后在 job 之外 `assumeIsolated` 跑 `prepare(upTo:)`（`checkIsolated` 按线程身份放行，探针 4 验证 Swift 6.3 可用）。渲染线程不进 actor、不 async、不创建 Task。
- `prepare(upTo: n)` 逐拍：advance → 调 `TickObserver` → 应用该拍排程命令 → 发转场事件；有变化才换快照指针，空闲拍只推进 `preparedTick`。渲染线程醒来先看 `preparedTick ≥ n`，没到就催一下并最多等 1 ms（`snapshotWaits` / `snapshotStale` 计数；实跑 600 拍两者都是 0）。
- 命令落在"渲染线程还没消费的最早一拍"= max(currentTick, renderedTick + 1)，回执 `appliedTick` 就是它。
- 状态机线程没在跑（未 start / 已 stop）时 job 在调用方线程上串行执行（一把锁），`await` 不会挂起。

### 1.4 V4 退回：到达余量（问题单 `reports/issues/G2-w1-core-phase-crossing-dup-drop.md`，2026-09-15）

G2 10 分钟 release 运行：与节目时钟有相对漂移的四路（59.94 × 2、±100 ppm）每次到达相位穿过拍点边界就出成串 dup + drop 对，合计设计外 192 帧，单路最差 0.084%（必须档 0.05%，G2 要求 0）。

**根因**（同意问题单的分析）：`latest(atOrBefore: t_n)` 用 pts（确定量）判合格、用"已经 push 进槽"判可用（随机量：到达 = pts + 延迟 + 抖动）。pts 落在拍点附近的帧与到达赛跑：晚到一点 → 这拍重复上一帧，下一拍它和更新的帧一起在槽里 → 取最新、它被跳过。任何依赖到达时刻的规则都躲不掉；唯一的免疫办法是合格判据只用 pts、并留出 ≥ 到达延迟 + 抖动的余量 L，这样合格的帧一定已在槽里。我原来的 V4 测试用无抖动的到达序列，量不到（问题单说得对）。

**修法**（`Slots/ArrivalPacing.swift`、`Slots/LockFreeFrameSlot.swift`、`Engine/Engine.swift`；契约不动）：

- `LockFreeFrameSlot` 新增引擎入口 `latest(forTick: t_n)` = `latest(atOrBefore: t_n − L)`，L 由槽按每帧 d = ingressTime − pts（两者都是输入在入口打的戳）自估。契约入口 `latest(atOrBefore:)` 一字不改、不参与估计。引擎注册输入时按 `ArrivalPacedFrameSlot` 协议识别，识别不到的槽退回契约入口；headless 注入的就是 `LockFreeFrameSlot`，G2 不用改。
- L 从哪来：初值 = max(节目 1/4 帧, 2 × d_0 + 1 ms)；稳态目标 = 最近 8 块（每块 60 帧）的 d 最大值 + 保护带（1 ms + 15%）。用最大值不用分位数：真设备常有孤立尖峰，分位数盖不住，每个尖峰就是一次 dup，用最大值只多付延迟（一次大卡顿让余量抬高 ≈ 8 s 后收回）。前 2 块热身期只许抬不许减。
- **余量任何一次变化都是一次相位跳变**：增 δ 可能多一次 dup、减 δ 可能多一次 drop，概率 ≈ δ / 输入帧长，渐变也一样（总位移决定期望事件数）。所以只在"带内没有候选帧"的拍改——消费者线程看候选表就能精确判断：减时第一个不合格的候选帧不能被带进合格区，增时当前合格的最新帧仍须合格；这样改余量零代价。相位锁定的输入（60 fps 提前半帧）若帧相位正好在带内就永远不改，余量停在"刚好不把它带进来"的值，这只影响该路延迟、不出事件。
- 迟到帧（候选表最旧的帧 pts ≤ 上一拍的合格上限：本该上一拍返回、现在才到）：那次 dup 已躲不掉；把 L 抬到它的 d + 保护带、但不超过"让它此刻恰好合格"的值（否则又要多等一拍）、单次不超过一个节目帧、总量不超过 500 ms 和结构上限"最早到达 + (capacity − 1) × 帧长"（候选表只有 3 格，等着合格的帧再多就会挤掉本该返回的；抖动跨度超过 2 帧的输入该自己加抖动缓冲，设计方案 §3.6）。结果：迟到只花那一次 dup、不丢帧、以后不再迟到；晚到 ≥ 2 拍的帧（卡顿 ≥ 33 ms）被封顶后跳过，最多 1 drop。
- 延迟代价：帧在第一个 t_n ≥ pts + L 的拍被用。合成源 d ≈ 1–3 ms → L ≈ 2–4.5 ms（设计方案 §3.7 "输入帧槽 1–2 帧"预算内）；真设备 L ≈ 设备延迟 + 15% + 1 ms，即帧到达后再等 ≈ 0.5–1.5 拍——这是让挑帧不依赖到达时刻的最小代价。G2 默认提前量半帧 ≥ 初值下限 1/4 帧，30 fps / 60 fps 相位锁定的路的挑帧拍不变。
- 引擎新增 `EngineOptions.pacing`（参数）、`Engine.pacingStats(forInput:)`（余量 / 窗口延迟 / 迟到数 / 抬降次数，给 G2 的日志）。`Stats` 契约不变。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

47 个全过，无 XCTSkip。实跑类在本机 debug 构建下的数值：

| 测试 | 数值 | 阈值 / 要求 | 通过 |
|---|---|---|---|
| `testV5_tickMath_5994_oneHourNoDrift` | 216001 拍每拍 deadline = 独立 128 位算式，误差 0；相邻间隔恒 400400 tick；1 h = 86 486 400 000 tick 整；`tick(at:)` 严格互逆 | 误差 0 | ✅ |
| `testV3_wakeJitter_30s_p99Under1ms` | 1800 拍：p50 0.008 ms，p99 0.025 ms，max 0.031 ms（另一次 0.013 / 0.047 / 0.065）；从不提前醒；跳拍 0；`isRealtime` = true | p99 ≤ 1 ms（本机目标）；必须档 4 ms | ✅ |
| `testV2_missedRender_30msRenderer_exactSkipCount` | 假渲染忙到 tickTime + 30 ms，600 拍：渲染 300、跳过 300，被渲染的恰是偶数拍 | = 理论值 ⌈30/16.67⌉ − 1 = 每拍跳 1 | ✅ |
| `testV3_clockDeadlinesComeFromSpecNotAccumulation` | 59.94 从第 5 拍起 120 拍，理想时刻全等于 `spec.time(of:)`，wake ≥ ideal | 精确 | ✅ |
| `testV4_30fpsInto60_reuseExactly50Percent_dropZero` | 6000 拍：consumed 6000、reused 3000、dropped 0，每帧恰好用 2 次 | 重复率恰好 50%，丢弃 0 | ✅ |
| `testV4_30fpsInto60_withArrivalLatency_stillExactly50Percent` | 到达延迟 2 ms 同上 | 同上 | ✅ |
| `testV4_5994Into60_oneReusePer1000Ticks` | 60001 拍：reused 60 = (T−1) − ⌊(T−1)·1000/1001⌋，dropped 0 | 每 1000 拍重复 1 次，精确 | ✅ |
| `testV4_60fpsPlus100ppmInto60_oneDropPer10000Ticks` | 60000 拍：dropped 5 = ⌊59999/10000⌋，reused 0，pushed = 60005 | 每 10000 拍丢 1 帧，精确 | ✅ |
| `testV4_pushWhenFull_evictsOldest_countsDropped` / `_futureFrameIsKept…` | 5 帧进容量 3：挤 2；取最新后跳过 2 → dropped 4；未来帧留到它的拍 | 契约口径 | ✅ |
| `testV4_twoThreadStress_invariantsHold` | 生产者 20 万帧 vs 消费者：序号单调、reused 计数一致、pushed = 返回过的不同帧数 + dropped | 不变量 | ✅ |
| `testV6_cut_isAtomicSwap_noIntermediateState` / `_effectiveOnTheTickItIsApplied` | 对调后 transition 空闲；其余字段不变；转场中 Cut 立即完成 | 无中间态 | ✅ |
| `testV6_scheduledCut_landsOnExactTick_noIntermediateSnapshot` | 排在 1000 拍：999 拍快照 PGM 1，1000 拍快照 PGM 2、无混合态 | 恰好第 n 拍 | ✅ |
| `testV6_prepareAcrossSkippedTicks_appliesEveryTickInOrder` / `testV6_tickObserver_…` | 一次跨 20 拍 / 3015 拍，每拍排程命令按序生效 | 按序 | ✅ |
| `testV7_fade30_progressIsKOver30_thenSwapAtTick30` | k = 0…29：progress 恰等于 Double(k)/30；第 30 拍对调、空闲；逐拍推进 = 一步到位 | k/30 精确 | ✅ |
| `testV7_scheduledFade_perTickSnapshots_progressIsKOver30` | 经状态机每拍一个新快照，progress 同上 | 同上 | ✅ |
| `testV7_autoTransition_wipeZoomStinger_sameProgressRule` | 三种类型同规则；cut 类型 / 时长 0 立即；进行中再发忽略 | — | ✅ |
| `testV7_tbar_25_50_75_mapping_andCommitAt1` | 0.25 / 0.5 / 0.75 直接映射；1.0 提交对调；钳 0…1；接管 auto | 映射误差 0 | ✅ |
| `testV7_ftb_levelRamps_andToggleContinuesFromCurrentLevel` | 20 拍 0 → 1 逐拍 k/20；0.4 处关掉 8 拍回 0 不跳变；tally 不变 | — | ✅ |
| `testV7_overlay_onOffWithAnimation_andInputSwitch` | fade 10 拍进出；退出期间可见；换输入不重启动画；通道 / 输入非法忽略 | — | ✅ |
| `testW1B_reduce_everyCommand_beforeAfterTable` | 43 行表，27 个 case 全覆盖（含非法变体） | 前后状态相等 | ✅ |
| `testC4_outOfOrder_seq3ArrivesFirst_waitsForSeq2` | seq 3 先到 → queued，状态不动；seq 2 到 → 2、3 按序；过期序号 stale | 严格顺序 | ✅ |
| `testC4_1000ConcurrentCommands_noLossNoReorder` | 8 个 task 乱序投 1000 条：应用序列 = 1…1000，快照 sequence 1000，排队 0 | 0 丢失 0 乱序 | ✅ |
| `testV5_fakeRendererAndConsumers_10s_frameCount600Exact` | 600 拍：派发 600、提交 600、完成 600、missed 0、两个消费者各 600 无乱序、snapshotStale 0、p99 抖动 < 4 ms | 600 ± 0 | ✅ |
| `testV5_slowConsumerDoesNotAffectOthers` | 慢消费者（50 ms/帧，队列 2）：consume 被调 600、处理 < 300、其余自己丢；快消费者 600；missed 0；无 consume > 1 ms | 其他消费者不受影响 | ✅ |
| `testV2_rendererSkipVerdictCountsAsMissedRender` | 每 10 拍返回 .skipped：missed 60，完成 540 | T3 口径 | ✅ |
| `testW1B_engine_picksFramesAtTickTime_30into60` | 真线程 30 fps 生产者进 60 fps 引擎 300 拍：每帧连续用两拍，reused ≈ consumed/2，dropped 0 | 挑帧规则 | ✅ |
| `testW1B_renderPath_zeroAllocationsInSteadyState` | malloc_logger 钩子盯渲染线程 + GPU 完成线程，稳态 220 拍（2 路 60 fps 真生产者、2 个消费者）：渲染线程 malloc 0、free 0；派发线程 malloc 0（**debug 构建**） | 零分配 | ✅ |
| `testW1B_engine_statsRow` / `_registerInputWhileRunning` | Stats 行字段来自计数、jsonl 往返；运行中注册 / 注销输入 | — | ✅ |
| `testW1B_ring_twoThreadStress_…` | 100 万次 push：popped ≈ 496k、evicted ≈ 504k、droppedIncoming 0–6，弹出序列严格递增无重复 | 不变量 | ✅ |
| `testW1B_hazardPublisher_stress_…` | 20 万次发布 × 3 读线程：0 次 magic / 单调错误，结束只剩当前对象 | 无 UAF 无泄漏 | ✅ |
| `testW1B_showStore_*` | 往返、v0 → v1 迁移链、缺环 / 未知版本 / 坏文件报错 | — | ✅ |
| `testW1B_stateMachine_usableWithoutExecutorThread` / `_requestPrepare_fromPlainThread_…` / `_submitLandsOnFirstUnrenderedTick` / `_snapshotPublished…` / `_transitionEvents_…` / `_queuedFrameConsumer_…` | 见名 | — | ✅ |

**9-15 V4 复测（到达余量，`ArrivalPacingTests` + `EngineTests`）**——模拟用例：固定种子，到达 = pts + U[30 µs, 3 ms]，渲染线程在 t_n + U[0, 50 µs] 调 `latest(forTick:)`；断言逐拍返回的帧号 = "当拍余量下 pts ≤ t_n − L_n 的最新帧"（参考模型），所以 reused / dropped 是精确值而不是范围：

| 测试 | 数值 | 阈值 / 要求 | 通过 |
|---|---|---|---|
| `testV4_5994Into60_withArrivalJitter_reusePer1000_dropZero` | 12000 拍（12 次穿越）：reused 12、dropped 0、迟到 0、余量 4.17 → 4.43 ms（1 次减小） | 每 1000 拍 1 reuse，drop 0 | ✅ |
| `testV4_60fpsPlus100ppmInto60_withArrivalJitter_dropPer10000_reuseZero` | 60000 拍（6 次穿越）：dropped 6、reused 0、迟到 0 | 每 10000 拍 1 drop，reuse 0 | ✅ |
| `testV4_60fpsMinus100ppmInto60_withArrivalJitter_reusePer10000_dropZero` | 60000 拍：reused 6、dropped 0 | 每 10000 拍 1 reuse，drop 0 | ✅ |
| `testV4_plus1000ppm_withArrivalJitter_manyCrossings` | 3 个种子 × 12000 拍（12 次穿越）：dropped 12、reused 0、迟到 0 | 精确 | ✅ |
| `testV4_phaseLocked60_withLeadAndJitter_noEvents` | 提前半帧 + ±3 ms 抖动 6000 拍：0 / 0，余量停在 4.17 ms | 0 事件 | ✅ |
| `testV4_30fpsInto60_withArrivalJitter_stillExactly50Percent` | 6000 拍：reused 2999（每帧两拍）、dropped 0 | 50% | ✅ |
| `testV4_marginDecreaseNeverCausesDrop` | 初始余量 20 ms：慢路 557 步减到 4.43 ms 全程 drop 0、快路 2 步减到 4.44 ms 全程 reuse 0，逐拍 = 参考模型 | 减余量零代价 | ✅ |
| `testV4_marginIncreaseOnGrowingLatency_noReuseOnFastInput` | 第 4000 帧起延迟 +3 ms：reuse 0、迟到 ≤ 1、余量抬到 > 6 ms | 抬余量零代价 | ✅ |
| `testV4_lateFrame_costsExactlyOneReuse_noDrop_thenMarginCovers` | 第 3500 帧晚到 20 ms：恰好多 1 次 reuse、drop 0，检测拍返回该帧本身，抬高 = 一个节目帧（封顶），8 s 后收回到 ~1 ms | 迟到 = 1 dup 0 drop | ✅ |
| `testV4_veryLateFrame_raiseIsCapped_atMostOneDrop` | 晚到 40 ms（≥ 2 拍）：抬高恰好一个节目帧，drop 1，之后收回 | 坏时间戳的损失有界 | ✅ |
| `testV4_contractLatest_isUnpaced_andBothEntriesShareState` | 契约入口无余量、不参与估计 | 契约不变 | ✅ |
| `testV4_engine_driftingInputWithArrivalJitter_designInOnly`（真线程） | 60 fps +1%（每 100 拍穿越）+ 到达 U[0.03, 3] ms，600 拍：reused 0，dropped = 合格帧数 − 拍数 = 6 ± 1，迟到 0 | 精确 | ✅ |
| `testW1B_renderPath_zeroAllocationsInSteadyState`（改后） | 渲染线程稳态 220 拍 malloc 0 / free 0，派发线程 0（挑帧含余量估计与调整） | 零分配 | ✅ |
| 原 `testV4_*`（无抖动，契约入口） | 不变，全过 | — | ✅ |
| 端到端（g2-m0 + w1-core 临时合并，release headless，`scenarios/m0.json`，200 s = 12000 拍，`--audio-device null`，G2 的 frameprobe 在旁边跑） | 输入 3 / 4（59.94）：dup 12（期望 11.9）drop 0；5（+100 ppm）：drop 1（期望 1.2）dup 0；6（−100 ppm）：dup 1（期望 1.2）drop 0；7 / 8：0 / 0；1 / 2（30 fps）：dup 5970 = 期望；**八路精确核算设计外全部 0**；missed_render 0，唤醒抖动 p99 0.023 ms，V1 avg 1.77 ms | G2 通过标准：设计外 0 | ✅ |
| 端到端 `make gate2`（10 分钟 = 36000 拍，同一临时合并，G2 的 frameprobe 在旁边跑，load 3.9） | V1 avg 1.66 / p99 2.03 ms，V2 0，V3 p99 0.049 ms，V5 +0；**V4 逐秒时间线 600 s 内只有设计内事件**：输入 3 / 4 每 ~1000 拍 dup +1（共 36 = 期望 36.0）、输入 5 每 ~10000 拍 drop +1（3 次）、输入 6 每 ~10000 拍 dup +1（4 次）、7 / 8 全程 0，没有任何一秒出现 dup+drop 成对；frameprobe 在播段设计外 0。报告生成器给的"精确核算设计外 10 帧"全部来自**最后一行**（t = 600 s、tick 35999，停机时写）：`engine.stop()` 期间视频源又推了 6 帧、传输环挤掉 3 帧（输入 3–8 各 drop +2/+3/+3/+3/+3/+3，pushed − consumed = 6），是停机顺序的记账副作用（headless 注释里已知"视频源在引擎之后停会多算几帧"），不是挑帧事件——见 §4 第 13 条 | 设计外 0；≤ 0.05% | ✅（运行期 0；停机行的 10 帧是 headless 记账，退回单的现象消失） |

BLOCKED：无。

零分配那条值得单说：第一版实现在 debug 下被探针抓到渲染线程每拍 32 次 malloc、派发线程每帧 4 次，回溯全在 `IndexingIterator.next` / `ClosedRange.subscript` —— -Onone 下 `for x in 1...n` 走未特化的泛型见证，每次迭代给 Index 装箱。热路径全部改成整数 `while` 后归零。发布构建会特化掉，但热路径不该依赖优化器。

## 3. 没做的和原因

- **Instruments Allocations 走查**：没做，用 `malloc_logger` 钩子做了更严格的按线程计数断言（`Tests/SwitcherEngineTests/AllocationProbe.swift`，可复用给 W1-C）。
- **音频线程从 C 读快照**：`HazardPublisher.ReaderSlot` 是给它准备的（借用期间 +0 引用），但没写 C 侧的借用函数，也没验证过 C 调用；归 W2-E。
- **Package.swift**：没改（允许改但不需要）。
- **`Stats.gpu_pct`**：没有公开 API，留 `gpuPercentProvider` 钩子，默认 0；`encoder` / `audio` 同样由 provider 灌（W1-E / W2-E 的东西）。
- **`.loadShow` 换 format**：状态整体替换了，但引擎不重建时钟 / 渲染器（"改它等于重启管线"是 App / headless 的事）。
- **Wipe / Zoom / Stinger 的参数语义、叠加动画的 kind**：只做了进度规则，画面解释归 W1-C / W3-B。
- **命令回执的精确确认**：`appliedTick` 在拍点边界有 µs 级窗口可能比实际早一拍（见 §4 第 6 条），没做"渲染线程确认后再回执"。
- **headless 接线**：G2。
- **到达余量的手动覆盖**：没做（`InputSettings` 没有视频延迟字段，加字段是契约提案，见 §4 第 11 条）；目前只有自估 + `EngineOptions.pacing` 的全局参数。

## 4. 对契约的疑问

1. **`Stats.jitter_ms` 口径**：CONTRACTS.md 写"|派发时刻 − 理想拍点| 窗口最大值"，测试标准 V3 写"PGM 帧派发时刻与理想拍点之差"。若"派发"= GPU 完成后交给消费者的时刻，它 ≥ render_ms（1–4 ms），和 V1 重叠且真渲染器上必然逼近"必须"档 4 ms。我填的是**渲染线程唤醒时刻 − 理想拍点**（prompt 的"每拍记录实际唤醒时刻与理想拍点之差（V3 jitter）"），另留 `Engine.takeDispatchJitterMax()` 给完成时刻版本。请定一个。
2. **`Renderer.prepare(format:maxInputs:)` 的 maxInputs** 我传的是 `RenderInputTable` 容量（最大输入编号 + 1），按 CONTRACTS.md §7"maxInputs = RenderInputTable 容量"；W1-C 若按"输入路数"理解会差 1，合并时对一下。
3. **转场第 s 拍 progress = 0**（k/d，k = 0）：第一帧可见混合在 s+1，第 s+d 拍已对调。V7 的曲线是从 s 还是 s+1 起算？我按契约字面。
4. **`FrameConsumer.consume` 的派发**：引擎在 GPU 完成线程上直接逐个调（一把互斥锁串行），每次计时，> 1 ms 记 `slowConsumeCalls`。一个违约阻塞的消费者会拖住其他消费者的派发（不会拖渲染线程）。要不要引擎给每个消费者再包一层队列（`QueuedFrameConsumer` 现成）？我倾向不包：契约已经规定 consume 立即返回，多一层只多一跳延迟和 3 个缓冲。
5. **`MixerSnapshot.sequence` 在命令被拒时也推进**（快照照发，状态不变），API 靠它确认"处理到哪条"。若希望被拒的命令不推进 sequence，改一行。
6. **`CommandReceipt.appliedTick` 的精确性**：命令落在 max(currentTick, renderedTick + 1)。渲染线程"借快照 → noteRendered"之间有几条指令的窗口，此时到达的命令会被记在第 n 拍但画面上第 n+1 拍才见。C1 用帧号测不受影响；若 API 要严格回执，需要"渲染线程确认后回执"的异步形态（提案再说）。
7. **T-bar 提交后的下一次 tbar 值**：按契约"progress = 推杆位置，≥ 1 提交"，提交后再来 0.9 就会从 0.9 开始新转场。物理推杆回程要 W2-B 归一化方向；契约要不要写明？
8. **`TransitionEvent`（AFV）的形态**：`cut(from,to)` / `started(type, duration, from, to, source)` / `completed(from,to)` / `cancelled`，每个事件带当时的 `afv` 标志；转场中 Cut 发 `completed`（提前完成）。W2-E 若需要别的（例如 FTB 事件），提案加。
9. **`Show.migrate` 只认当前版本**：迁移链我放在引擎的 `ShowStore`，契约不用改；但"迁移步骤注册在哪"以后是 App 的事，先记着。
10. **`SwitcherEngineSkeleton`**：TestKit 的 P0 占位还引用它，我留了别名；G2 合并 w1-testkit 后一起删。
11. **到达余量的参数没有进契约**：L 由槽自估（`ingressTime − pts`），依赖输入把 `ingressTime` 打准（W1-A 的合成源是 push 前 `HostClock.now()`，对）。若以后某种输入要手动指定（比如 W2-A 想给 UVC 固定 100 ms），`InputSettings` 得加视频延迟字段——那是契约提案，现在不需要。`PacingOptions` 的默认值（1/4 帧下限、1 ms + 15% 保护带、8 × 60 帧窗口、单次抬高 ≤ 一帧、上限 500 ms）是我定的，测试标准没规定；G2 若要写进 §2.1（问题单第 5 条"合成源到达相位"）请一并定。
12. **V4 的"设计内"口径**：余量收敛时的每次减小会让慢输入少一次 reuse / 快输入的 drop 挪个位置（不是多事件），所以 dup 计数可能比 T × |1 − r/P| 少 1；G2 的"设计外 = max(0, 实测 − ceil(期望) − 1)"只罚超出，没问题。frameprobe 侧同理。
13. **headless 停机时最后一行 stats 把停机挤掉的帧算成 drop**（G2 的目录）：`engine.stop()` 先于 `input.stop()`，其间视频源继续 push，传输环容量 3 挤掉多出来的帧、`dropped` 计数；若 StatsWriter 的最后一行落在这之后（我这次 601 行、最后一行 tick 35999），精确核算就多出 2–3 帧/路。建议 headless 在 `engine.stop()` 之前写最后一行（或先停视频源再停引擎，代价是末尾几拍多 1–2 次 reuse）。这条不改引擎也能解决，我没动 Tools/。

## 5. 下一个会话需要知道的坑

- **定时器合并**：本机 macOS 26 上非实时线程的任何定时等待（`mach_wait_until` / `usleep` / `DispatchSource` / `Thread.sleep`）都有 ≥ 1 ms、通常 3–7 ms 的 leeway。凡是要"准点"的线程（W1-A 合成源的出帧线程、W1-E 按拍点喂帧的测试、W2-E 的假音频设备时钟）都用 `NativeThread(config: NativeThreadConfig(..., timeConstraint:))` 挂实时策略，或者接受 ms 级误差并在断言里留余量。我的引擎测试里 30 fps 生产者就是这么做的。
- **-Onone 下 `for-in` 遍历 Range / Array 会堆分配**（未特化的 `IndexingIterator`）。渲染线程、音频回调、派发线程上的循环一律写整数 `while`。W1-C 的合成循环尤其注意；证明用 `AllocationProbe`（按 mach 线程端口计 malloc，比 Instruments 严格且能进 CI），注意要在线程退出前停探针（`_pthread_exit` 会 free 一次 TLS）。
- **actor + 专用线程 + `assumeIsolated`**：`SerialExecutor.checkIsolated()` 按线程放行是 Swift 6.3 / macOS 26 上可用的（探针 4）。别的会话若也要"实时线程唤醒 actor"，抄 `StateThreadExecutor` 的模式，别在实时线程上 `Task {}`（会分配）。
- **`HazardPublisher<Object: AnyObject & Sendable>`**：发布的对象必须不可变；每条实时读线程各拿一个 `ReaderSlot`（单线程使用，`borrow` / `endBorrow` 成对）；非实时读者用 `latest`。`publish` 单写方，多线程写要自己加锁（`Engine.registerInput` 就是在锁内发布）。
- **帧槽会同时持有多少帧**：传输环 3 + 候选表 3 + 上一帧 1，加上渲染表里 1，每路最多 8 帧被引擎侧引用；CVPixelBufferPool 至少留 10 个，不然生产者拿不到缓冲。
- **`Engine.registerInput(number:)` 编号必须 1…maxInputs**（默认 16），越界是 precondition。`Renderer.prepare` 收到的 maxInputs = maxInputs + 1。
- **`Engine.start` 是 async**（要 await 状态机准备第 0 拍），`stop` 也是；`makeStats()` 单线程调（窗口状态在里面）。测试用 `start(t0:lastTick:)` 有界运行 + `engine.clock!.join()`。
- **`StateMachine.start()` 要调**（`Engine.start` 会调）；没调也能用（job 在调用方线程跑）。`stop` 后 `await` 不挂。
- **命令的两条入口**：`submit(IssuedCommand)` 走 sequence 门（总线用），`apply(_:)` / `schedule(_:at:)` / `TickObserver` 不占 sequence（脚本 / 本地用）；`MixerSnapshot.sequence` 只反映前者。
- **快照只在状态变化时换指针**：判断"状态机是否跟上"用 `preparedTick`，别比 `snapshot.tick`。
- **测试时长**：SwitcherEngineTests 约 70 s（30 s 抖动 + 4 × 10 s 引擎 + 5 s × 3）；整包 110 s。想快就 `--filter` 跳过 `ClockTests|EngineTests`，别改拍数。
- **分支名**：桌面端 worktree 的分支叫 `claude/w1-core-f4b7cf`，`w1-core` 是同一提交的引用；合并任一个都行，报告按 `w1-core` 命名。
- **挑帧现在带到达余量**：引擎对 `LockFreeFrameSlot` 走 `latest(forTick:)`，帧在第一个 t_n ≥ pts + L 的拍被用（合成源 L ≈ 2–4.5 ms）。给 W2-A：真设备的 L ≈ 设备延迟 + 15% + 1 ms，`ingressTime` 必须是进槽那一刻的 `HostClock.now()`，pts 必须是换算成 host time 的采集时刻——两者都乱打，余量估计就乱；`Engine.pacingStats(forInput:)` 能看到每路的 L / 迟到数。给 W2-E：某路的视频延迟 = L + 拍点相位，A/V 对齐要按这个算（不再是"pts ≤ 拍点就用"）。
- **相位锁定的输入（与节目同源时钟、固定提前量）**：余量减到"刚好不把下一帧带进合格区"就停，提前量 < 1/4 帧的路会比无余量时晚一拍（G2 默认提前半帧，不受影响）。
- **写模拟测试时到达顺序要按生产者线程的顺序**：一帧晚到会挡住它后面的帧（单线程生产者的真实行为），不是乱序到达。
