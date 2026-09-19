# W1-B2 到达余量修正 + L1 统计 —— 报告（分支 w1-core-2）

日期 2026-09-18 晚 – 09-19 凌晨。机器 Apple M5 Max / macOS 26.6.2 (25G83) / Xcode 27.0 (27A266a) / Swift 6.4；AC 电源；温度未记录。
**负载**：另外几个会话在同一台机器上编译 / 跑 xctest / 跑 headless，load 2.5–9.6（每段数据旁边注了当时的 load）。
worktree `.claude/worktrees/arrival-balance-l1-stats-3fe8df`，从 `main`（2fdf52d，P2 合入后）开；分支 `w1-core-2`（prompt 42 指定；worktree 的 `claude/…` 分支已改名）。
只动了 `Packages/SwitcherCore/Sources/SwitcherEngine/`（Slots/ArrivalPacing.swift、Slots/LockFreeFrameSlot.swift、Engine/Engine.swift、
Engine/EngineCounters.swift、新文件 Engine/InputLatencyRecorder.swift）和 `Tests/SwitcherEngineTests/`（ArrivalPacingTests.swift、EngineTests.swift、Fakes.swift）。
`scripts/check-ownership.sh w1-core-2 --include-working-tree` 绿，`scripts/lint-rules.sh` 绿。SwitcherCore `swift test`：SwitcherEngineTests **86 个全过**
（+12 个 L1 用例，+1 个每路参数用例；现有 testV4_* 19 个仍绿）。整包一次里 SwitcherRenderTests 的 `testDisplay_maxFrameRateCapsThumbnailBlits`
失败一次（"0 is not greater than 10"，display link 在其他会话把窗口占满时没回调），单独重跑过；不是本会话的改动（SwitcherRender 不依赖 SwitcherEngine）。

## 1. 做了什么

裁定（`reports/issues/W2A-w1-core-arrival-pacing-vs-camera-latency.md` 末尾第 2 条）7 条全部落地；余量算法的最终形式写在 `ArrivalPacing.swift` 文件头。

| 裁定 | 落点 | 做法 |
|---|---|---|
| 1 初值 | `LockFreeFrameSlot.observeArrival` | 第一帧 d₀ > 0 → `max(initialFloor, d₀ + guardAbsolute)`，否则 `initialFloor`；再钳到上限。删掉 `PacingOptions.initialFactor` |
| 2 饿死保护 / 不返回 nil | `latest(forTick:)` 末尾 | 候选表满且最旧候选不合格、或槽里有帧却从未返回过帧（起流）→ 这一拍没有合格帧时把余量降到 `ideal − pts(最旧)`（恰好合格），计 `decreases` + 新增的 `starvationRescues`；热身期也生效。槽里有帧不再返回 nil |
| 3 动态上限 | `marginCap(guard:)` | `min(maximumMargin, max(0, d_min) + 一个节目帧 + 保护带)`；**随时生效**（余量高于上限就减，不看滞回、不等热身；减仍守零代价规则）。一个节目帧 = 新增 `PacingOptions.programFrame`（nil 由引擎按节目帧率填，同 initialFloor / maxRaise） |
| 4 保护带 | `guardBand()` | `guardAbsolute + guardRelative × (可覆盖 d_max − d_min)`，不再乘 d_max 绝对值 |
| 5 估计器窗口 | `observeArrival` / `refreshWindow` | 按时间定长：8 块 × `blockDuration`（默认 **1 s**，按帧的 ingressTime 推进）；每块记最小值 + 最大的 8 个样本；"可覆盖最大值" = 每块最大样本里第一个 ≤ d_min + 一帧 的（8 个都超过就取第 8 个，保守）；起流块在窗口有两个完整块后作废。取舍理由见 §1.1 |
| 6 每路参数 | `Engine.registerInput(number:slot:pacing:)` | `pacing` 为 nil 用 `options.pacing`；两种情况下 nil 的 initialFloor / maxRaise / programFrame 都按节目帧率填 |
| 7 提案 005 引擎侧 | `Engine/InputLatencyRecorder.swift`、`EngineCounters`、`StatsAssembler` | 每路 256 项预分配环 (tick, ingressTime, 新帧 / 重复) 由渲染线程每拍写；`renderer(_:didComplete:)` 在取 `now` 之后、调第一个消费者之前按 `frame.tick` 查表，新帧就把 `now − ingressTime` 累进每路 sum / count / max（原子量）；`StatsAssembler` 每行出 `latency_ms`（窗口平均）/ `latency_max_ms`（窗口最大，读后清零），没样本写 0。同一帧的重复拍不算；引擎 t0 之前进槽的帧不算（同 W2-A 参考实现）。渲染线程零分配（`testW1B_renderPath_zeroAllocationsInSteadyState` 仍绿，路径含新增的环写） |

另加：`PacingStats` 多了 `enabled` / `windowPeakLatency`（含尖峰的原始最大）/ `windowMinLatency` / `marginCap` / `starvationRescues`（原字段不动，headless / 探针的打印不受影响）；
`PacingOptions.capAnchor`（上限锚点：`.windowMinimum` 裁定原文 = 默认；`.sustainedMinimum` 每块最小值里最大的，§3 对照用，见 §4 第 1 条）。

### 1.1 第 5 条的取舍：按时间定长 + 每块 8 个最大样本 + 起流块作废

裁定给了两个方向（按时间定长的块 / 超过上限的样本不计入窗口最大值），我两个都做了，原因：

- **按时间定长（8 × 1 s）**：老窗口 8 × 60 帧在 30 fps 源上是 16 s、60 fps 上是 8 s，同一个尖峰影响的时长随输入帧率变。按时间定长后两种源都是 8 s，
  `testL1_estimatorWindow_timeBased_spikeLeavesWithin16s_sameForBothRates` 断言两种源尖峰后 ≤ 480 拍回落（prompt 要求 ≤ 16 s）。块长 1 s 而不是 prompt 例子里的 2 s：
  相机的起流瞬态（§1.2）要靠热身块结束才能离开余量，1 s 块让热身 = 1 s、起流块 2 s 作废；30 fps 源 1 s 有 30 个样本，估 ±1 ms 的抖动够用（60 fps 源 60 个，与老窗口的 60 帧块相同）。
- **超过 d_min + 一帧 的样本不计入可覆盖最大值**：推导——稳态目标 = M + guard，上限 = d_min + T + guard，两边的 guard 相同，所以"目标不超过上限"⟺ M ≤ d_min + T。
  超过这条线的样本即使被余量盖住也要让最早到的帧多等超过一帧，裁定第 3 条已经决定这种帧走迟到路径，那么它就不该再把余量钉在上限一整个窗口。
  实现：每块留最大的 8 个样本（降序插入，64 个 Int64，每拍扫 8 × 8 次比较），取第一个 ≤ 线的；8 个都超线就取第 8 个（保守：一块 1 s 里超过 7 个"尖峰"就不是尖峰而是水平变了，
  这时目标 ≥ 上限，余量钉在上限，和不排除时一样）。为什么不能在观察时判：第一帧（相机总是最慢的那帧）进窗口时窗口只有它，d_min 就是它，判不出来；要等 d_min 落下来再回头排除，所以得留样本。
- **起流块作废**：相机起流的前 5–7 帧（≈ 230 ms）d 比稳态大 15–40 ms（曝光 / 管线收敛，§1.2 实测），它们落在第一块里，虽然 ≥ 线的被排除，但 60–68 ms 那几帧刚好在线下，
  仍会把可覆盖最大值抬到 62 ms 一整个窗口（8 s）。第一块在窗口有两个完整块后作废（2 s），之后余量按稳态样本走。
  `testL1_cameraStartupTransient_doesNotPinMargin_forWholeWindow` 用实测的起流序列（92 / 57 / 73 / 71 / 70 / 71 / 62 → 54 ± 1）断言 3 s 后余量 ≤ 55 + 保护带 + 滞回。

代价：`LockFreeFrameSlot` 多 64 个 Int64 的预分配、每拍多 ~80 次整数比较；没有分配、没有锁。

### 1.2 真机相机的到达延迟长什么样（决定了下面所有数字）

`probe-app.sh clocks --camera 0`（裸帧槽、不起引擎）三次，内置相机 1080p@30 '420v'：

| 时间 / 负载 | d = ingress − pts | 说明 |
|---|---|---|
| 23:40，load 2.5，8 s | 第 0 帧 104；第 1 s 55–58；第 2–5 s **双峰 56 / 76**（每秒平均 63–73，Δingress 21–48 ms）；第 6 s 71–77 | 曝光 / AE 在收敛，d 在 56 和 76 两档之间跳 |
| 23:41，load 2.5，20 s | 第 0 帧 115；第 0–1 s 56–65；之后 **稳态 72–78**，第 12 / 15 / 18 s 各有 2–8 帧提前到 56–60 | 夜里室内灯下：主模态 75 ± 3，每隔 3 s 一批提前 20 ms 的帧 |
| 00:26，load 3.3，20 s | 第 0 帧 92，第 2–5 帧 70–74，第 6 帧 62；之后 **稳态 53–55**，无提前帧 | 用户回到机器前（灯光变了？）：W2-A 报告里的"54–58 稳态"就是这种 |

所以 W2-A 的模型"d = 55 固定 + 几 ms 抖动、偶尔尖峰"只在其中一种光照下成立；另一种光照下 d 是 75 ± 3 加**提前** 20 ms 的帧（不是尖峰，是提前），
抖动跨度 22–25 ms 超过一个节目帧。裁定第 3 条的上限 = d_min + 一帧 + 保护带 用的是窗口最小值，在这种源上被提前帧压到主模态 d_max 下面 1–2 ms，
主模态最高的那些帧在相位不巧时迟到——实测就是 §2 里"迟到 10–16 / 10 s"的那几次。§4 第 1 条讨论怎么办。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 2.1 SwitcherEngineTests（全部通过；确定性模拟：30 或 60 fps 源，d = U[52, 58] ms，第一帧 d₀ = 75，节目 60 fps）

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testL1_highLatencySource_30into60_noNilAfterFirstFrame_marginWithinBound` | 起流 nil 拍 0；初值 76.0 ms（= d₀ + 1）；每拍余量 ≤ 上限、上限 = d_min + 16.67 + 保护带；稳态余量 59.8 ms（= 58 + 1.9 + 滞回内）；迟到 0，drop 0，reuse 精确 50%，逐拍与参考模型一致 | nil = 0；≤ d_min + 1 帧 + 保护带（70.6） | ✅ |
| `testL1_highLatencySource_60into60_noNilAfterFirstFrame_marginWithinBound` | 同上（+33 ppm 的 60 fps 源）：nil 0、迟到 0、reuse 0、drop ≤ 1（快源的设计内 drop 提前一次，§5 第 2 条）、末尾余量 ≤ 60.95 | 同上 | ✅ |
| `testL1_highLatencySource_30into60_isolatedSpikeWithinOneTick_costsOneReuse_noDrop` | 第 600 帧 d = 75（晚 < 1 拍）：迟到 1、drop 0、无跳帧；节奏 2-2 → **3-1**（599 占 3 拍、600 / 601 合计 3 拍），reuse 总数不变；余量峰值 ≤ 上限；16 s 内回落 | 一次 dup、不丢帧 | ✅ |
| `testL1_highLatencySource_30into60_isolated100msSpike_oneLateEvent_atMostSpikeFrameDropped_marginRecovers` | 第 600 帧 d = 100（晚 2.4–3 拍）×3 种子：迟到 1；drop ≤ 1 且只能是尖峰帧自己；多 ≤ 3 次 reuse；余量峰值 ≤ 上限；≤ 960 拍回落 | prompt："只花一次 dup 不丢帧" | ✅（按 §3 第 1 条的口径） |
| `testL1_highLatencySource_60into60_isolated100msSpike_oneLateEvent_marginRecovers` | 60 fps 源同上：迟到 1，比基线多 ≤ 2 个 drop（尖峰帧 + 提前的设计内 drop），都在尖峰附近；回落 | 同上 | ✅ |
| `testL1_estimatorWindow_timeBased_spikeLeavesWithin16s_sameForBothRates` | 30 / 60 fps 源尖峰后回落用时均 ≤ 480 拍（8 s） | ≤ 16 s | ✅ |
| `testL1_cameraStartupTransient_doesNotPinMargin_forWholeWindow` | 实测起流序列：热身期 ≤ 上限；1 s 后 ≤ 62 + 保护带 + 滞回；3 s 后及之后每拍 ≤ 55 + 1.3 + 1.05；迟到 0 drop 0 | — | ✅ |
| `testL1_starvationGuard_fullTableNoEligible_lowersMarginInsteadOfDropping` | 保护带故意设 100 ms、30 fps d = 5 ms（表装不下）：drop 0、nil 0、`starvationRescues` ≥ 1、无跳帧 | drop 0 | ✅ |
| `testL1_neverNilWhenSlotHasFrames_firstFrameArrivingJustBeforeTick` | 第一帧到达 0.5 ms 前那拍：返回它，余量降到 55.5（恰好合格），rescues 1，drop 0 | 不返回 nil | ✅ |
| `testL1_guardBand_relativePartUsesJitterSpan_notAbsoluteLatency` | 稳态余量 = 窗口最大 + 1 + 0.15 × 6（± 滞回）；< 58 + 5 | 不按 d_max 绝对值 | ✅ |
| `testL1_stats_perInputLatency_matchesW2AReference_within0_2ms` | 假渲染器（GPU 2 ms）+ 30 fps / 60 fps 真线程生产者 10 s：引擎 `latency_ms` 9.878 / 7.883 vs 参考 9.881 / 7.886（差 **0.003 ms**）；`latency_max_ms` 差 0.005 / 0.007；30 进 60 样本 299（不是 599 拍）、重复拍 300 | 差 ≤ 0.2 ms | ✅ |
| `testL1_stats_windowResetsPerRow_zeroWhenNoSamples` | 第二行没有新完成帧 → latency_ms / latency_max_ms = 0；jsonl 往返相等 | — | ✅ |
| `testW1B_engine_registerInput_perInputPacingOptions` | 三路：引擎默认下限 6 ms、按路给 12 ms、按路关掉 → 余量 6.0 / 12.0、第三路 `enabled = false` | — | ✅ |
| `testW1B_renderPath_zeroAllocationsInSteadyState` | 渲染线程 + GPU 完成线程稳态 220 拍 malloc / free = 0（路径含 L1 环写与累计） | 0 | ✅ |
| 现有 `testV4_*`（ArrivalPacingTests 11 + FrameSlotTests 7 + EngineTests 1）| 全绿。`testV4_5994Into60…` 原断言"decreases ≥ 1（初值已收敛）"改成"余量 = 1/4 帧下限"：初值规则变了（d₀ + 1 ms ≤ 下限时初值就是下限，没有可收敛的），其余断言（reuse 12 ± 1、drop 0、逐拍精确）不动 | | ✅ |

### 2.2 真机：内置相机 1080p@30 → 1080p60（`probe-app.sh run --input camera:0 --seconds 10`，探针 = W2-A 的 `switcher-input-probe`，引擎换成本分支）

阈值（裁定第 3 条）：L1 avg ≤ 1.5 帧、p99 ≤ 2 帧、max ≤ 2.5 帧；起流 nil 拍 ≤ 2；dropped ≤ 2；对照 `--no-pacing` ≈ 0.53 帧。

| | 时间 / load | L1 avg ms（帧） | p99（帧） | max（帧） | nil 拍 | 迟到 | 余量 / 窗口最大 | 帧槽 dropped | 通过 |
|---|---|---|---|---|---|---|---|---|---|
| **修前** 1（main 2fdf52d） | 23:52 / 2.5 | 67.65（**4.06**） | 85.54（5.13） | 85.90（5.15） | 0 | 0 | 115.9 / 99.9 | 0 | ❌ |
| 修前 2 | 23:52 | 38.86（2.33） | 68.09（4.09） | 68.30（4.10） | 0 | 0 | 87.8 / 76.1 | 11 | ❌ |
| 修前 3 | 23:53 | 55.29（3.32） | 70.53（4.23） | 70.79（4.25） | 0 | 0 | 91.6 / 78.6 | 11 | ❌ |
| 修前对照 `--no-pacing` | 23:53 | 7.66（0.46） | 17.77（1.07） | 17.85（1.07） | 0 | — | — | 13 | ✅ |
| **修后**（每块 4 样本、2 s 块，中间版本）1 | 00:24 / 3.8 | 25.60（1.54） | 27.74（1.66） | 27.95（1.68） | 0 | 0 | 72.6 / 71.6 | 1 | avg ❌ 0.04 |
| 中间版本 2 | 00:24 | 7.17（0.43） | 18.50（1.11） | 18.66（1.12） | 0 | 1 | 64.1 / 61.7 | 13 | ✅ |
| 中间版本 3 | 00:24 | 12.53（0.75） | 15.18（0.91） | 16.87（1.01） | 0 | 0 | 63.0 / 61.8 | 12 | ✅ |
| 中间版本 4 | 00:25 | 33.32（2.00） | 35.51（2.13） | 35.73（2.14） | 0 | 0 | 72.8 / 71.6 | 2 | avg ❌ 0.50，p99 ❌ 0.13 |
| 中间版本 5 | 00:25 | 7.87（0.47） | 9.68（0.58） | 10.14（0.61） | 0 | 0 | 56.1 / 55.4 | 13 | ✅ |
| 中间版本 6 | 00:25 | 4.96（0.30） | 6.69（0.40） | 7.19（0.43） | 0 | 0 | 56.6 / 55.1 | 12 | ✅ |
| 修后对照 `--no-pacing` | 00:24 | 8.74（0.52） | 17.72（1.06） | 17.76（1.07） | 0 | — | — | 13 | ✅ |
| **修后最终**（556767e：8 样本、1 s 块、起流块作废）1 | 00:29 / 3.2 | 18.57（1.11） | 30.75（1.84） | 36.99（2.22） | 0 | **10** | 74.1 / 76.0 | 1 | ✅ |
| 最终 2 | 00:29 | 19.26（1.16） | 23.95（1.44） | 24.35（1.46） | 0 | 3 | 69.8 / 66.0 | 13 | ✅ |
| 最终 3 | 00:29 | 25.63（1.54） | 37.09（2.23） | 37.70（2.26） | 0 | 10 | 74.8 / 83.9 | 13 | avg ❌ 0.04，p99 ❌ 0.23 |
| 最终对照 `--no-pacing` | 00:30 | 10.07（0.60） | 17.65（1.06） | 17.76（1.07） | 0 | — | — | 13 | ✅ |
| 最终（l1compare，§2.3）win 1 | 00:31 / 3.5 | 14.91（0.89） | 34.39（2.06） | 35.19（2.11） | 0 | 0 | 66.6 / 64.5 | 1 | p99 ❌ 0.06 |
| win 2 | 00:32 | 9.17（0.55） | 15.41（0.92） | 16.12（0.97） | 0 | 0 | 64.4 / 61.8 | 12 | ✅ |
| win 3 | 00:32 | 13.67（0.82） | 25.03（1.50） | 25.96（1.56） | 0 | 16 | 85.6 / 83.5 | 13 | ✅ |

解读：

- 修前 → 修后：avg 4.06 / 2.33 / 3.32 帧 → 0.3–1.5 帧；p99 4.1–5.1 → 0.4–2.2；黑屏（nil 拍）0 → 0（今晚修前也没复现 W2-A 的 252 拍黑屏，那次是重负载下 d₀ = 157 的初值 2 × d₀）。
- 相机的两种光照 / AE 状态（§1.2）决定了通过与否：**单模态**（d 54 ± 1，中间版本 5 / 6、win 2）avg 0.3–0.55、p99 0.4–0.9、迟到 0，远在阈值内；
  **双峰**（75 ± 3 + 提前 20 ms 的帧，最终 1 / 3、win 3）avg 1.1–1.5、p99 1.4–2.2、迟到 10–16 / 10 s。avg ≤ 1.5 在 12 次修后运行里 10 次过（2 次 1.54，超 0.04 帧）；
  p99 ≤ 2 帧 9 次过（超的 2.06 / 2.22 / 2.23）；max ≤ 2.5 帧 12 次全过。
- **迟到 10–16 / 10 s 是裁定第 3 条在双峰源上的后果**（§1.2）：上限被提前帧压到主模态最高帧下面 1–2 ms。对 30 进 60 它们表现为 2-2 节奏变 3-1（reuse 总数不变、不丢帧），
  `--no-pacing` 对照里每一帧提前帧同样打乱节奏（它按到达显示）。是否换锚点见 §4 第 1 条。
- 起流后第一帧 ≤ 2 拍内出画：15 次修后运行 nil 拍全 0（相机比 t0 早起来，第 0 拍槽里就有帧）。
- **dropped ≤ 2 没做到，也不是引擎的事**：探针 t0 = 现在 + 800 ms，相机 ~350 ms 起来后到 t0 之前推了 ~13 帧，传输环容量 3 挤掉 10–12 帧；
  `--no-pacing` 对照同样 13（W2-A 那次 1 是相机起得晚）。修后的 dropped 与对照逐次相等，引擎起来后 0 drop。
- `--no-pacing` 对照 0.46 / 0.52 / 0.60 帧（W2-A 0.53）：输入侧不变。

### 2.3 提案 005：`per_input[n].latency_ms` 与 W2-A `LatencyFrameSlot` 同一运行内的差

探针不打印 `latency_ms`（`switcher-input-probe` 是 W2-A 的目录，我不能改），写了个不入库的工装 `l1compare`（scratchpad；真状态机 + 真 Metal 渲染器 + 真引擎 + 相机，
把 W2-A 的 `InputEngineHarness` / `LatencyFrameSlot` / `LatencyConsumer` 三个文件原样抄进来当参考，第一个消费者就是参考消费者），用 W2-A 授权过的 .app 启动器跑。
`makeStats()` 在结束时只调一次，窗口 = 整个运行，与参考的全程平均同口径：

| 运行 | 引擎 latency_ms / latency_max_ms | 参考 mean / max | 差 avg / max |
|---|---|---|---|
| win 1 | 14.911 / 35.190 | 14.913 / 35.191 | −0.001 / −0.001 |
| win 2 | 9.165 / 16.120 | 9.166 / 16.121 | −0.001 / −0.001 |
| win 3 | 13.672 / 25.958 | 13.673 / 25.959 | −0.001 / −0.001 |
| sus 1–3（§4 第 1 条的对照锚点） | 15.240 / 19.826；17.304 / 40.742；19.766 / 52.110 | 15.240 / 19.827；17.305 / 40.744；19.767 / 52.111 | −0.001 / ≤ 0.002 |

差 ≤ 0.002 ms（阈值 0.2；差的来源只是参考消费者在引擎取 now 之后几微秒再取一次 now）。单元测试里假渲染器的同类对照差 0.003 ms。
合成源的 stats.jsonl（gate2 / gate3 的 headless）现在每行带 latency_ms / latency_max_ms，见 §2.4。

### 2.4 `make gate2` / `make gate3-run`（V4 精确核算设计外 = 0，V1 / V3 不变）

（跑法：`scripts/gate2.sh --minutes 10 --label w1-core-2 --baseline baselines/m0-m5max.json`、`scripts/gate3.sh --minutes 10 --label w1-core-2 --baseline baselines/g3-m5max.json`，
不写基线；脚本生成的 `reports/G2-run-w1-core-2.md` / `G2.md` / `G3-run-…` / `G3.md` 不是本分支能改的文件，数据抄到这里后已还原，原始输出在
`.build/gate2/w1-core-2/`、`.build/gate3/w1-core-2/`。）

**gate2（M0，8 路合成源，00:34–00:49，load 跑前 9.64（别的会话在编译）→ 跑后 1.75）：✅ 通过标准全部满足**

| 指标 | 数值 | 阈值 | 通过 | 与基线（baselines/m0-m5max.json）的差 |
|---|---|---|---|---|
| V4 精确核算 | stats.jsonl 全程设计外 **0**（8 路：dup 17970 / 17970 / 36 / 36 / 0 / 4 / 0 / 0，drop 0 / 0 / 0 / 0 / 4 / 0 / 0 / 0，期望 17970 / 35.9 / 3.6）；frameprobe 在播段设计外 0；帧号倒退 0 | 0 | ✅ | — |
| V1 | avg 1.501 / p99 1.921 ms | avg ≤ 2（本机线） | ✅ | −0.606 ms |
| V2 | 0 / 35940 拍 | 0 | ✅ | — |
| V3 | p99 0.042 / max 0.144 ms | p99 ≤ 4 | ✅ | −0.018 ms |
| V5 | +0 帧 | ≤ 2 | ✅ | — |
| S2（信息） | 11.31 MB/h 拟合：RSS 761 → 770（前 100 s）→ 771（之后 8 min 平）| ≤ 10 | ❌ 拟合值 | 前 100 s 的启动爬升，之后平；本会话的分配全在 init（每槽 64 个 Int64、每引擎 17 × 256 × 3 个原子量），热路径零分配 |
| 到达余量（headless 打印） | 8 路余量 1.19–1.45 ms（±3 ms 的 7 号路 4.17 = 下限），窗口最大 0.17–0.25 ms（7 号 3.13），迟到 0 | — | — | 与修前相同的稳态值 |
| `per_input.latency_ms`（新字段） | 30 fps 路 9.8 ms（9.4–10.3）；60 fps 锁相路 9.8；漂移路 11.0–11.8（逐秒在 2.9–19.8 之间随相位扫）；latency_max_ms 最大 11.5–20.1 | — | — | 提前量 8.3 ms + render 1.5 ms，符合物理 |

**gate3（G3 场景，跑了三次：00:50–01:05、01:14–01:37、01:44–02:07）：V4 精确核算三次都是 0、V1 / V3 不变；前两次 V2 各出一次外部干扰（自动判定 ❌），第三次全过**

| 指标 | 第一次 | 第二次 | 阈值 | 说明 |
|---|---|---|---|---|
| V4 精确核算 | stats.jsonl 全程设计外 **0**（8 路 dup 17970 / 0 / 36 / 36 / 0 / 4 / 0 / 0，drop 0 / 0 / 0 / 0 / 3 / 0 / 0 / 0）；frameprobe 在播段 123（= 下面 V2 的 159 次卡顿在文件里的重复） | stats.jsonl 全程 **0**；frameprobe 在播段 3（= V2 的 4） | 0 | ✅ 引擎口径两次都 0 |
| V1 | avg 2.918 / p99 28.5 ms（被 00:56 的 11 s 卡顿抬高） | avg 1.829 / p99 1.926 ms | avg ≤ 2 | 第二次 ✅，与基线差 +0.052 ms |
| V2 | **159 / 35940**：00:56:02–00:56:13 连续 11 s 每秒 5–6 拍 render 20–28 ms，GPU 0%；load.log 同时刻 launchd 19%、ContinuityCaptureAgent 7%、WindowServer 20–28%、Claude 桌面端 31–39%（用户在用机器 / iPhone 连续互通相机上线） | **4 / 35941**：01:16:05 一次 +4，render 5.05 ms；load.log 01:16:03 contactsd 52.8% | 0 | ❌ 两次都是外部进程；渲染线程唤醒抖动 V3 两次都 ≤ 0.04 ms，说明不是渲染线程 CPU 侧（本会话在渲染线程只多了每路 3 次原子写、GPU 完成线程 16 次原子读） |
| V3 | p99 0.035 / max 0.074 ms | p99 0.040 / max 0.136 ms | p99 ≤ 4 | ✅ 与基线差 −0.002 / +0.003 |
| V5 | −159 | −4 | ≤ 2 | ❌（= V2） |
| V6 / V7 / A1–A4 / E1 / E3 / C1–C4 | 全 ✅（Cut 在第 1000 拍、147 次 Cut 干净；Fade 偏差 0.344 帧；T-bar 0.78%；A2 0.000；A4 0.208 ms；C3 不一致 0；C4 12000/12000） | 全 ✅ | | 与 G3 报告同 |
| `per_input.latency_ms` | 30 fps 路 11.2 ms（含卡顿段 37 ms）；latency_max_ms 最大 45–54（卡顿段） | — | — | 卡顿段被 L1 如实记下（GPU 完成晚了） |
| 到达余量 | 8 路 1.64–1.86 ms（7 号 4.17），迟到 0 | 同 | — | |

**gate3 第三次（01:44–02:07，load 跑前 3.9 → 跑后 2.1，机器上没有别的会话在跑）：✅ 自动项全部满足**：V4 精确核算 0（stats.jsonl 全程）/ 0（frameprobe 在播段）、帧号倒退 0；
V1 avg 1.872 / p99 1.983 ms（与基线差 +0.095）；V2 0 / 35940；V3 p99 0.039 / max 0.059 ms（+0.002）；V5 +0；V6 / V7 / A1–A4 / E1 / E3 / C1–C4 全 ✅；
S2 拟合 15.7 MB/h（819 → 834，前几分钟爬升；G3 基线自己也是 68.6 MB/h 拟合、❌，同类信息项）；S3 CPU 55.1%（基线 +10%，`--api` 的 apitest 客户端也在本机跑）。

两个 gate 的 V4 结论：引擎自己的精确核算（stats.jsonl，铁律 4 的那份）两个场景四次运行全是 0；frameprobe 在播段的非 0 只出现在 V2 卡顿的那几秒（PGM 没渲染 = 文件里重复上一帧），
与到达余量无关。V1 / V3 与基线同（gate2 V1 还低了 0.6 ms，是机器当时别的负载不同）。

## 3. 没做的和原因

1. **"孤立 100 ms 尖峰只花一次 dup 不丢帧"按字面做不到，测试按能做到的口径写**：d = 55 ± 3 的源来一帧 d = 100，它比余量（≈ 60）晚 40 ms = 2.4–3 拍。
   30 fps 源帧距 33 ms，它到达时下一帧（d = 55，pts + 33）多半已经到了；挑帧规则取 pts ≤ 上限 的最新帧，余量抬到"让它恰好合格"需要抬 40 ms，
   超过 maxRaise（一帧）也超过上限，只能抬到上限 → 上限下的合格线在它和下一帧之间的概率只有 ~23%（取决于相位）；其余情况它被下一帧跳过（1 drop，正是文件头注释
   "封顶时晚到 ≥ 2 拍的帧会被跳过"）。前一帧在这 2–3 拍里多重复 2–3 次。裁定的"一次 dup 不丢帧"对晚 < 1 拍的尖峰成立（`…isolatedSpikeWithinOneTick…` 用 d = 75 断言了 3-1 节奏、不丢帧），
   对 100 ms 的尖峰我断言：迟到恰好 1 次、最多丢尖峰帧自己、其它帧不丢、多 ≤ 3 次 reuse、余量不过上限、8 s 内回落。要让 100 ms 尖峰也不丢帧得允许迟到路径把余量临时抬过上限（≥ 2.4 帧），
   与裁定第 3 条"不再抬余量"相反，没做。
2. **真机验收的 dropped ≤ 2**：见 §2.2，是探针的 800 ms 提前量 vs 相机起流时间，与对照相等；引擎起来后 0 drop。
3. **App 没跑**（`make build` 的 xcodebuild 部分）：本会话只动了引擎包，App 只通过 SwitcherEngine 的公开接口用它，新增的都是可选参数 / 新字段；六个包 `swift build` + 两个工具见 §2.4 的 gate 编译。

## 4. 对契约的疑问

1. **上限锚点（裁定第 3 条的 d_min 取什么）——请裁**。裁定原文 = 窗口最小到达延迟。§1.2 的双峰相机上它把上限压到主模态 d_max 下面 1–2 ms，10 s 里 10–16 次迟到（3-1 节奏）。
   我加了 `PacingOptions.capAnchor = .sustainedMinimum`（每块最小值里最大的那个：只有每块都出现的提前帧才算稳态最小值）做对照，同一相机交替各跑 3 次（l1compare，00:31–00:33）：

   | 锚点 | avg（帧） | p99（帧） | max（帧） | 迟到 / 10 s | 余量 |
   |---|---|---|---|---|---|
   | windowMinimum（默认，裁定原文） | 0.89 / 0.55 / 0.82 | 2.06 / 0.92 / 1.50 | 2.11 / 0.97 / 1.56 | 0 / 0 / 16 | 66.6 / 64.4 / 85.6 |
   | sustainedMinimum | 0.91 / 1.04 / 1.19 | 1.15 / 2.38 / 2.53 | 1.19 / 2.44 / 3.13 | 0 / 24 / 2 | 62.6 / 83.7 / 91.0 |

   sustainedMinimum 延迟更高（p99 2.4–2.5、max 3.1 帧超阈值），而且提前帧每块都有时（sus 2：窗口 min 63.7）它退化成窗口最小值、照样迟到 24 次。
   **结论：默认保持裁定原文**（延迟更低、阈值内），双峰源的迟到是这种源抖动跨度（22–25 ms）超过一个节目帧的必然结果：要么多付 1 帧延迟，要么每秒 1–2 次 3-1 节奏。
   `.sustainedMinimum` 留着给组装方按输入选（不推荐），或者删掉，你定。
2. **"迟到"在 30 进 60 上的口径**：迟到一次 = 前一帧多占一拍、迟到帧少占一拍，`FrameSlotStats.reused` 总数不变、`dropped` 不变——V4 的 dup / drop 计数看不见它，只有 `PacingStats.lateFrames`
   和帧号序列的节奏看得见。要不要给 Stats 加 per_input 的 late 计数（契约字段）？现在只在 `PacingStats` 里（引擎内部接口，headless / 探针会打印）。
3. **`Stats.per_input[n].latency_ms` 排除 t0 之前进槽的帧**：与 W2-A 参考实现一致（"它等的是引擎不是管线"），提案 005 原文没写这条。如果希望产品里第一行如实反映（相机比引擎早起 800 ms 时第一行 latency_max 会是几百 ms），去掉 `InputLatencyRecorder.account` 里那个比较就行。
4. `PacingOptions` 的默认值（1 s 块、8 块、每块 8 个样本、热身 1 块、保护带 1 ms + 15% 跨度、maxRaise 一帧、上限 d_min + 一帧 + 保护带、绝对上限 500 ms）仍是引擎自己定的，测试标准 §2.1 没写；
   G3 报告若要把"合成源到达相位 / 余量参数"写进 §2.1 请一并定。

## 5. 下一个会话需要知道的坑

1. **TCC 会因为同 bundle ID、不同签名的 .app 重置摄像头授权**：我在本 worktree 第一次跑 `probe-app.sh` 新建的 .app（cdhash 与 W2-A 的不同）让 `com.switcher.input-probe` 的授权回到 notDetermined，
   连 W2-A 那个已授权的 .app 也一起失效，得用户重新点允许。以后各 worktree 别各建一个 .app：直接用已授权的那个启动器（它只是把 `--probe <路径>` 交给任意二进制），
   我的做法在 scratchpad 的 `probe-run.sh`：`open -W -n -a <已授权的 .app> --args --probe <本 worktree 编的探针> --log <日志> -- <参数>`。
2. **严格锁相的 60 fps 源，余量降不过拍点边界**：pts 恰好落在拍点上的 60 fps 源每一拍候选表里都有一帧正好卡在"下一条边界"上，余量往下减一步只能减到那条边界上方 41 ns（零代价规则：
   不能把它带进合格区，否则和已合格的那帧同拍 → drop）。于是余量卡在 66.67 + ε 而不是目标 60——显示拍数一样（拍点量化），L1 不多付，只是 `margin` 数字看着高。
   有一点漂移就解开：快源（+33 ppm）下一拍那帧自己过线，接着减到目标（那次设计内的 drop 提前发生、总数不变）；慢源余量跟着边界每拍降 0.55 µs。
   `ArrivalPacingTests.camera60` 因此用 `Rational(1000, 60_002)`；真相机时钟自由跑，不受影响。
3. **相机的 d 分布随光照 / AE 变**（§1.2）：同一台机器 40 分钟内量到 54 ± 1、75 ± 3 + 提前帧、56 / 76 双峰三种。验收数字要标明当时的状态（探针打印的"窗口 min / 可覆盖 max / 峰值"就是），
   一次运行过不过没有统计意义，要看 §2.2 那样的多次。
4. `probe-app.sh run` 的 `--seconds 10` 里前 1 s 是热身（余量在上限 ≈ d_min + 一帧 + 保护带），10 s 的平均里它占 10%：p99 / max 基本都来自这 1 s。想看稳态用 `--seconds 30`。
5. 另外几个会话同时在跑编译 / xctest / headless 时 load 3–10，gate 脚本会警告"V1/V3 的数字不可信"；本报告 §2.4 的 gate 数据注了 load。
6. `l1compare` 工装在 `/private/tmp/claude-501/…/scratchpad/l1compare/`（不入库）：如果 W2-A 想把 `Stats.per_input.latency_ms` 打进探针的 `run` 输出，只要在
   `switcher-input-probe/main.swift` 第 286 行那句 `Stats.per_input：fps … drop …` 后面加 `latency_ms \(p.latencyMs) latency_max_ms \(p.latencyMaxMs)`。
