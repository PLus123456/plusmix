# W1-B5 音画同步止血：D10 Auto 中按 Cut 声音同一拍收口、D11 FTB 途中改时长声音跟画面 —— 报告（分支 w1-core-5）

日期 2026-10-18。prompt 120（Codex 2026-10-13 审查的 D10 / D11，用户 2026-10-17 定）。机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.1 / Swift 6.4，
接电源（AC，电池 95%）。同机并行 115 / 118 / 119 三个会话（另有 xcodebuild / xctest 在跑，负载 1.5–9；整包测试前看过 `ps -axo comm`）；没跑 gate4 / perf-baseline / soak。
worktree `.claude/worktrees/agent-a60ca103f38352a1c`，harness 分支 `worktree-agent-a60ca103f38352a1c`，从 main 358517f（G9 合入后）开；**`w1-core-5` 指向同一提交**
（每次提交后 `git branch -f w1-core-5 HEAD`）。不 push、不 merge。提交（先红后绿，小步）：`git log --oneline main..w1-core-5`——
红用例 → C 替换淡变 → FTB 提前量补半块 → D10 / D11 主修 → 用例打印实测值 → 本报告。
动的文件全在 OWNERSHIP W1-B5 行内：SwitcherEngine 三个源文件（StateMachine.swift、Audio/AudioStateBridge.swift、Audio/AudioControlEvent.swift；**MixerReducer.swift 一个字没动**）、
SwitcherEngineTests 三个（AudioSyncEventTests.swift 新建，AudioBridgeTests / StateMachineTests 跟改事件形状）、SwitcherAudio 五个源文件（CSwitcherAudioRT 的 sw_audio_rt.h / sw_mix_internal.h / sw_mix.c、
SwitcherAudio/AudioMixer.swift、Integration/AudioEngine.swift——只改 handle 里 cut / transitionEnded / fadeToBlack 三个分支、crossfade、延后门控、stepFadeToBlack 开头和几个新的小函数，没重排文件，
115 的 030 填数那一处（audioCounters / refreshStatus）没碰）与三个用例文件（新建）。SwitcherContracts、docs/、App 没动。

## 1. 做了什么

### 1.1 先复现（红）

两条都按 Codex 的触发条件在**真状态机 → AudioStateBridge → AudioEngine → C 混音 → 消费者**整条链上量（离线驱动 EngineRig，另有空设备 + 控制线程的实时版），
"录音轨采样"取消费者流（Master = 送录制 / 编码的那一轨，`.inputProgram` = 每路推子后含 AFV，`.input` = ISO：推子后 AFV 前），按 PTS（内容时刻，与画面拍点同一时基）逐样本判：

- **D10**（`AFVInterruptTests`）：AFV 开、10 s Auto（600 拍）第 1 秒 Cut。修前旧源在录音轨里一直到末尾（t_cut + 1458.7 ms，再往后还要淡 9 s）都没到 −∞，新源停在 −16 dB 往上爬——
  与 Codex 的调用链结论一致（"未做最终音轨采样"那一步补上了）。T-bar 一下推到底、`apply(.cut)`（API / 键盘那条命令路）同样红；空设备实时版 t_cut + 1465.5 ms 仍未到 −∞。
- **D11**（`FTBRetargetTests`）：缩短 / 拉长 / 归零 / 反向淡回 / 淡回途中改时长五条，Master 逐块电平对 reducer 逐拍算出的画面电平。修前五条全红（缩短 62 处、拉长 146 处、归零 3 处、反向 11 处、淡回改时长 110 处断言），
  缩短那条正是 Codex 探针：120 拍渐黑走到 30 拍改成 30 拍，画面第 172 拍全黑，声音在第 180 拍（相对起点第 60 拍）之后那一拍实测还在 −6.2 dB（旧斜坡的一半）。
- 同一处（"转场结束后音频收不到终值"）顺带量出三条别的红，一并修了（§1.2 末尾）：T-bar 快推到底 / 快拉回 0 后 −16 dB 残留、T-bar 接管 Auto 再推到底后旧源 −4.6 dB 残留、Auto 途中才开 AFV 后停在 cos / sin。
  这三条 Codex 报告里没有，KNOWN_ISSUES 也没有，**G10 记账时请当新发现、本分支已修**。

### 1.2 D10：状态机区分三种完成，强制完成在同一拍短淡收口

- **状态机**（StateMachine.swift）：`TransitionEvent.completed` 带上 `TransitionCompletion`，按**完成前那一拍**的转场状态判：
  `elapsed` = auto 且这一拍 ≥ 开始拍 + 时长（advance 走满的）；`interrupted` = auto 没走满就被对调（进行中 Cut、T-bar 一下推到底；排程路与命令路一样——
  排在第 t 拍的 Cut 先 advance 到 t、转场还在进行，再被 Cut 对调）；`tbar` = source 是 T-bar 的转场提交（推到底、推到一半按 Cut、T-bar 接管 auto 之后）。
  桥把它原样带进 `AudioControlEvent.transitionEnded(…, completion:)`（原来的 `completed: Bool` 换成 `TransitionCompletion?`，nil = 取消）。
- **AudioEngine**：`interrupted` 与 `tbar` → `shortFade`：旧 PGM → 新 PGM 在**这一拍的对齐时刻**（拍点 + 对齐延迟，与 Cut 同一口径）起一条短淡，
  长度 = cutFadeBlocks 块但**不超过 1 拍**（`cutFadeFrames`，默认 256 帧 = 5.33 ms，60 fps 一拍 800 帧；Cut 也改用它，默认参数下数不变）；
  它是**替换**淡变：还在走的 10 s 长淡变照走到短淡起点，起点那一刻才撤、短淡从当时的增益接着走到 0 / 1。`elapsed` 照旧不动（C 侧等长淡变 W1-D2 起按帧精确，同一刻自己走满），
  只在两路的门控记录对不上终值时（途中被直接门控过：AFV 中途才开、每路 AFV 位途中翻过——没有淡变会收口）补一条同样的短淡。取消仍是立即按最新状态门控。
- **C 热路径**（只加了一条实时命令，铁律 3）：`SW_CMD_CROSSFADE_REPLACE`。为什么不能用原来的 `SW_CMD_CROSSFADE`：它在**命令应用时**就撤掉同槽位的旧淡变、并在应用时取起点增益；
  短淡起点在 ≈ 60 ms 之后，这段时间 afv 向转场前的目标（旧 PGM 1、旧 PVW 0）一阶平滑回去，起点再跳回应用时取的值——新源先掉到 −∞ 再跳回 −16 dB（`CrossfadeReplaceTests` 的对照用例钉住了这个回弹）。
  替换语义：应用时只撤同槽位上**还没开始**的淡变；已经开始的留到新淡变起点那一块（`sw_xfade_take_over`）才去掉这个槽位、取槽位此刻的 afv 作起点（起点所在块里起点之前的几个样本按块首值保持，
  ≤ 1 块，10 s 长淡变在这一块里只动 ~0.01）；步骤 2 里后写的曲线连同"走满"标记一起覆盖先写的。只多了固定 8 格的遍历和一个 uint8 字段，无分配无锁，`check-rt-symbols` debug / release 都过。
  默认语义一个字节没变，Cut / Auto 起点照旧走它。`AudioMixer.crossfade` 加 `replacing:`（默认 false）。
- **顺带的三条**（同一个分支 / 同一个问题：转场结束后音频没收到终值）：
  1. T-bar 推杆位置排成"now + 对齐延迟"的延后门控；提交 / 取消时原来立即 applyGates，之后排着的那一档再落下去，旧源 / PVW 停在那一档（推到 0.9 后 42.7 ms 内推到底 → 旧源 −16 dB 一直不走）。
     现在 transitionEnded 时清掉排着的延后门控；到点时最新快照里已没有进行中的 T-bar 也丢（状态机先发事件后发布快照，同一轮轮询可能又读出结束前那一档）。
  2. T-bar 接管进行中的 Auto 不发事件，音频侧记的还是 auto，提交时 completed 只清标记 → 旧源停在最后一档（−4.6 dB），新源 −1.8 dB。现在按 `tbar` 收口。
  3. Auto 开始时 AFV 关、途中才开：开的那一刻按当前进度直接门控、没有 C 侧淡变，走满后停在 cos / sin。现在走满时补短淡。
  T-bar 提交因此从"立即门控（比画面早一个对齐延迟）"变成与 Cut 同一拍对齐的短淡（§4 第 2 条请用户确认）。
- **时间线没打破**（w1-core-4 §1）：短淡与 Cut 一样排在"拍点 + 对齐延迟"的混音时刻；AFV 增益在总线效果链之前，videoDelay 补偿下 Master 的效果链延迟 L_m 同时延后它和画面，
  所以录音轨里旧源到 −∞ 的时刻 = Cut 那一拍 + 5.33 ms，两种补偿方式都一样（`VideoDelayCompensationTests` 整组照过）。

### 1.3 D11：FTB 目标斜坡变了就同步，从改的那一拍起换

- **原因比"只比 on"多一层**：桥的快照轮询只比 `ftb.on`，途中改时长（提案 020：reducer 按当前电平回拨等效起点 + 换时长，或时长 0 直接到位）漏掉；
  而且轮询拿不到"改的那一拍"（快照的拍可能已往后走了），音频分段换斜坡要的正是它——拿快照的拍当换点，轮询晚一拍就是一个台阶。
- **状态机**：`StateMachine.events` 加一种事件 `TransitionEvent.fadeToBlack(tick:on:startTick:durationTicks:)`，与转场事件同一条路（状态机线程上同步到达，带确切的拍）；
  判"目标斜坡变了"（`ftbRampChanged`）：on 翻了；还在走时起点或时长变了（途中改时长、同一拍来回翻两下）；在走时时长变成 0（归零）。进度变化、自然走完、空闲时改时长不发。
- **桥**：转成 `AudioControlEvent.fadeToBlack(…, effectiveTick:, effectiveAt:)`（生效拍 = 改的那一拍）；快照 diff 只在全量（音频引擎起来的第一次轮询）时报 FTB，并补上"淡回画面途中"（on 关但斜坡还在走）。
- **AudioEngine**：新斜坡排进 `ftbPending`，内容时刻到了生效时刻才接替——之前那段内容按旧斜坡走。原来一收到就换：反向淡回时换点前约 60 ms 声音比画面低 4 dB（修前反向那条红在这里）。
  第一条 FTB 事件（全量同步）没有旧斜坡可续，立即用。
- **FTB 跟随的提前量补半块**（单独一个提交）：淡回那条在修 D11 之前就红在第 203 拍（−0.57 dB），不是改时长的问题——stepFadeToBlack 每块设一次 Master 增益目标，块内是台阶，
  原来只提前 3 ms 补总线增益一阶平滑的 τ，块内平均还落后半块（稳态推导：块内平均误差 = (提前量 − 3 ms − 半块) × 斜率），30 拍斜坡到 −20 dB 那头正好 ≈ 0.5 dB，原来的 FTB 用例是踩线过的。
  改成 3 ms + 半块后逐块最大差从踩 0.5 dB 降到 0.11–0.12 dB。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

"修前"列 = 同一用例对着 main 358517f 跑的结果（提交 30490b1 单独跑过）。阈值列里"≤ 1 拍"是 prompt 120 的要求；±0.5 dB / −20 dB 以上沿用 W2-E AFVTests 的 FTB 口径；
"−40 / −60 dB、严格 0"是本会话自定的判据（测试标准 §4 没有这两项的阈值，没改任何阈值）。

| 测试 ID | 口径 | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|---|
| `AFVInterruptTests.testD10_cutDuringLongAuto_oldSourceSilentAndNewFullWithinOneTick` | Auto 600 拍第 60 拍 Cut：旧源最后一个非零样本之后的时刻；新源 t_cut + 1 拍起 vs ISO 逐样本；Master vs 新源逐样本；打断前 3 块长淡变 ±0.5 dB；t_cut 前 3 块到 +1 拍不回弹；±8 块相邻样本跳变 | t_cut + 1458.7 ms（录音轨末尾仍非 0）；新源 69216 / 69216 样本不同 | **t_cut + 5.333 ms**；新源 = ISO、Master = 新源（0 个样本不同）；不回弹；跳变 < 0.1 | 旧源 ≤ 1 拍（16.667 ms）到 −∞，新源 1 拍内到满 | ✅ |
| `…testD10_tbarToOneDuringLongAuto_sameShortFade` | 同上，第 60 拍 T-bar 1.0 | 1458.7 ms | **5.333 ms** | 同上 | ✅ |
| `…testD10_cutDuringLongAuto_viaApply_sameShortFade` | 同上，`apply(.cut)`（落在第 181 拍） | 1442.0 ms | **5.333 ms** | 同上 | ✅ |
| `…testD10_naturalLongAuto_endsOnItsOwnCurve_noShortFade` | 自然走满的 Auto 120 拍：终点前 4–8 块 from 在 cos 上 ±0.5 dB；from 到 −∞ 的时刻 | +0.000 ms | **+0.000 ms**（没被短淡打断） | t_s + D ± 0.05 ms | ✅（对照，修前修后都过） |
| `…testD10_afvTurnedOnMidAuto_naturalCompletionStillLandsOnProgram` | Auto 60 拍，第 30 拍才开 AFV，自然完成 | 1458.7 ms（停在 cos π/4） | **t_e + 5.333 ms** | ≤ 1 拍 | ✅ |
| `…testD10_tbarFastCommit_noStaleBarGateAfterCommit` | T-bar 0.9 → 2 块后推到底，提交后 32 块旧源 / 新源 | 旧源 −16.1 dB、afvGain 0.156 | **旧源 −∞、新源 −0.000 dB** | 旧源 0 | ✅ |
| `…testD10_tbarFastCancel_noStaleBarGateAfterCancel` | T-bar 0.1 → 2 块后拉回 0 | PVW −16.1 dB | **PVW −∞、PGM +0.003 dB** | PVW 0 | ✅ |
| `…testD10_tbarTakeoverOfAutoThenCommit_landsOnProgram` | Auto 600 拍走 1 s 后 T-bar 0.6 接管，再推到底 | 旧源 −4.6 dB、新源 −1.8 dB | **旧源 −∞、新源 −0.000 dB** | 旧源 0、新源 ±2% | ✅ |
| `IntegrationRealtimeTests.testD10_nullDevice_cutDuringLongAuto_shortFadeOnTheCutTick` | 空设备 + 控制线程，Auto 600 拍第 60 拍 Cut | 1465.5 ms | **5.337 ms**；新源 = ISO | ≤ 1 拍 | ✅ |
| `CrossfadeReplaceTests.testD10_replaceCrossfade_oldCurveRunsUntilTheNewStart_thenShortFadeFromThere` | 混音器两路直流逐样本：长淡变 24000 帧走到 ~40% 排替换短淡 256 帧 | —（新命令） | 起点前仍在长淡变 cos / sin ±2e-6；起点块保持；短淡曲线 ±2e-6；之后 from 严格 0；全程不回弹、跳变 < 0.01；rtViolations 0 | 同左 | ✅ |
| `CrossfadeReplaceTests.testD10_plainCrossfadeStillCancelsAtApply_contrast` | 默认语义（不改）：命令应用后 from 回弹 > 0.05、起点块跳回 | — | 回弹 / 跳回都在（默认语义没变） | 同左 | ✅ |
| `CrossfadeReplaceTests.testD10_pendingReplaceIsCancelledByANewerOne` | 两条替换都还没开始：前一条应用时被后一条取消 | — | 前一条起点处不起短淡、后一条走满后 0 | 同左 | ✅ |
| `AudioSyncEventTests.testD10_*`（7 条） | 引擎侧：排程 / 命令两路 Cut → interrupted；T-bar 推到底 → interrupted；走满（含 1 拍 auto）→ elapsed；s + d − 1 拍 Cut → interrupted；T-bar 提交 / 推到一半 Cut / 接管 auto 再提交 → tbar；桥照带 | — | 7 / 7 | 同左 | ✅ |
| `FTBRetargetTests.testD11_shortenMidFade_masterFollowsNewRamp_silentAtTick60` | 120 拍渐黑第 30 拍（第 150 拍）改 30 拍：Master 逐块 vs 画面；画面第 172 拍全黑后 +1 / +2 拍电平、+3 拍起非零样本；**第 180 拍（相对第 60 拍）** | 62 处红（第 181 拍 −6.2 dB） | 151 块最大差 **0.114 dB**；+1 拍 −110.0 dB、+2 拍起严格 0；第 180 拍起严格 0 | ±0.5 dB；−40 / −60 dB；0 | ✅ |
| `…testD11_lengthenMidFade_masterFollowsNewRamp` | 30 拍走到一半（第 135 拍）改 120 拍：等效起点 75、第 195 拍全黑 | 146 处红（声音第 150 拍就到底） | 195 块最大差 **0.114 dB**；全黑后 +1 拍 −121.6 dB、+2 拍起 0 | 同上 | ✅ |
| `…testD11_zeroMidFade_masterDropsOnTheSameTick` | 120 拍走到第 30 拍改 0：画面这一拍全黑 | 3 处红（+1 拍 −2.6 dB） | +1 拍 **−72.6 dB**、+2 拍 −121.4 dB、+3 拍起 0 | 同上 | ✅ |
| `…testD11_reverseMidFade_fadesBackWithTheVideo` | 30 拍走到一半反向（FTB 关），等效起点 120、第 150 拍回满 | 11 处红（换点前 −3.5 dB） | 477 块最大差 **0.120 dB**；第 152 拍起满 ±2% | ±0.5 dB | ✅ |
| `…testD11_fadeBackThenLengthen_masterFollowsNewRamp` | 全黑后淡回（第 200 拍，30 拍），第 210 拍改 60 拍：等效起点 190 | 110 处红 | 220 块最大差 **0.121 dB** | ±0.5 dB | ✅ |
| `AudioSyncEventTests.testD11_*`（5 条） | 引擎侧：Codex 探针（events 原来为空 → 现在 `fadeToBlack(tick 30, start 22, d 30)`，第 60 拍音频斜坡 = 画面 = 1）；不发的四种；全量含淡回途中；**七种场景跑真状态机，按事件分段重建的音频斜坡逐拍 = 画面 ftb.level（261 拍 × 7，差 < 1e-9）**；命令路生效拍 = 回执拍 | — | 5 / 5 | 同左 | ✅ |
| AFVTests 9 条（含 `testAFV_fade30_*` 两条、`testAFV_cut_*`、`testAFV_tbar_gainsFollowTheBar`、两条 FTB） | 自然完成 / Cut / T-bar / FTB 原有口径 | 过 | 过（fade30 逐块最大误差 0.113 dB 不变） | 原阈值 | ✅ |
| A1 | `testA1A2_nullDevice_clickOffsetAndContinuity`（30 s）、`testLifecycle_*_A1Zero` 两条、`DeviceTests.testA1_builtInOutput_dropoutsAndUnderrunsZero`（内建输出 10 s：dropouts 0、underruns 0、违规 0）；D10 用例里 Master ±8 块相邻跳变 < 0.1 | — | 全过 | A1 = 0 | ✅ |
| A5 | `VideoDelayCompensationTests.testA5_monitorSync_nullDeviceSimulation` 过；`testA5_monitorLatency_loopback` / `testA5_monitorSync_loopback` | — | 过；两条回环照旧 **BLOCKED-硬件**（要音频接口回环线） | ≤ 20 ms | ✅ / BLOCKED |
| SwitcherCore 整包 `swift test`（负载 ~5） | Render 101 / Engine 129 / Contracts 108 | — | **338 = 337 过 + 1 跳 + 0 红**（跳的是原有 `testP2_stats_oldGateFilesParse`：新 worktree 没有老 gate 产物）；显示类没红 | 全绿 | ✅ |
| SwitcherAudio 整包 `swift test`（负载 1.5–3） | SwitcherAudioTests 88 / IntegrationTests 89 | — | **177 = 170 过 + 7 跳 + 0 红**（跳的都是原有：真设备 A2 / A3 三条、回环 A5 两条 BLOCKED-硬件、改系统默认输出 / 麦克风权限两条） | 全绿 | ✅ |
| `scripts/check-rt-symbols.sh` / `--release` | CSwitcherAudioRT 4 个目标文件 | — | 无 malloc / 锁 / 日志 / ObjC / Swift 运行时 / 系统调用符号 | 0 违规 | ✅ |
| `make lint BRANCH=w1-core-5`（C locale 与 zh_CN.UTF-8 各一遍） | 禁词 / 版本号 / Package.swift / check-deps / check-ownership / check-help / check-links / check-rt-symbols | — | 全过；check-ownership："15 个改动文件都在允许范围内"（含本报告） | 全绿 | ✅ |
| 下游编译 | `swift build` SwitcherTestKit、Tools/switcher-headless（事件形状变了，确认没有别的包 switch 它们；App 源码 grep 过没有用户） | — | 两包都编过（18.0 s / 21.3 s） | 能编 | ✅ |

## 3. 没做的和原因

1. **020 的取消重拷**：prompt 写明归 115；MixerReducer.swift 没碰。
2. **真录像文件端到端**（Recorder 写 .mov → frameprobe 量 AFV）：录像在 SwitcherOutputs / App / Tools，不在本会话目录；本会话的"录音轨"是交给 Recorder 的那条消费者流（同一个 PTS）。
   G10 清单的人工项"Auto 中 Cut 声画同一拍"（prompt 122）覆盖端到端；gate4 / perf / soak 按指示没跑。**动了热路径（sw_mix.c），G10 要用户终端重跑 `make soak`**（prompt 122 已写）。
3. **普通 Cut 与 Auto 起点仍用默认淡变**（应用时就撤同槽位的旧淡变）：两次切换隔不到 ~60 ms（Cut 后马上 Auto、连按两下 Cut）时重叠的那一路还是会先回弹再跳回；prompt 只要求强制完成那条，
   为了不扩大行为变化面没改。要统一成替换语义只是 `.cut` / `.transitionStarted` 两处加 `replacing: true`（离线稳态逐位相同），等用户定（§4 第 3 条）。
4. **Auto 途中才开 AFV**：现在走满时补短淡收到终值，但开 AFV 之后到走满之间声音停在开的那一刻的 cos / sin、不跟剩下的曲线走；要跟得在开 AFV 时补一条"剩余时长"的淡变，没做（边角情况，记一笔）。
5. **Cut 恰好落在 Auto 走满的那一拍**：reducer 先走满对调、再被 Cut 对调回去，状态机报 `cancelled`（前后 PGM 相同），音频立即按最新状态门控、比画面早一个对齐延迟回到旧源——原有行为，没改。
6. **实时模式下 FTB 跟随精度没量**：离线 0.11–0.12 dB；线程模式下控制周期不在块首、命令在下一个 IOProc 块才生效，提前量没算这段，空设备 / 真设备没有 FTB 跟随的用例（D10 有空设备实时版）。

## 4. 对契约的疑问

1. **没改契约**：SwitcherContracts、JSON 字段、测试图案都没动。改了形状的是 SwitcherEngine 的公开类型——`TransitionEvent.completed` 多一个 `completion:`、新 case `fadeToBlack(tick:on:startTick:durationTicks:)`、
   新 enum `TransitionCompletion`；`AudioControlEvent.transitionEnded` 的 `completed: Bool` 换成 `completion: TransitionCompletion?`、`.fadeToBlack` 多 `effectiveTick / effectiveAt`。
   它们不在 docs/CONTRACTS.md，全仓库用户只有 SwitcherAudio Integration 与 SwitcherEngineTests（grep 过 App / Tools / 其余各包）。若用户认为这是"引擎 ↔ 音频"的口径、该进 CONTRACTS.md，归契约会话补文字。
2. **请用户确认：T-bar 提交的声音时刻变了**。原来提交时立即按最新状态门控（τ 3 ms 平滑），比画面早一个对齐延迟（42.7 ms）+ ≤ 1 拍，且会被排着的旧推杆位置盖回去（§1.2 顺带第 1 条）；
   现在与 Cut 同一口径：提交那一拍的对齐时刻起一块短淡（≤ 1 拍）收到终值，与画面同一拍。推杆中途的位置口径（晚对齐延迟生效）没变。
3. **要用户定：普通 Cut / Auto 起点要不要也用替换语义**（§3 第 3 条）。默认参数、两次切换不重叠时结果逐位相同；只在 60 ms 内连续切换时不再回弹。
4. **告知：FTB 声音曲线整体晚了 2.67 ms**（提前量补半块，§1.3）——更贴画面；不是阈值，FTB 的音频跟随测试标准里也没有阈值。

## 5. 下一个会话需要知道的坑

1. **FTB 斜坡变化现在走状态机的转场事件那条路**（TransitionEventSink，状态机线程上同步到达），不走快照轮询：只 `pollSnapshot()`、不 `attach()` 的桥只在第一次全量时拿到 FTB。AudioEngine 照旧先 attach 再轮询，不受影响。
2. **事件形状**：模式匹配 `.completed` 要四个值、`.transitionEnded` 第五个是 `TransitionCompletion?`（nil = 取消）、`.fadeToBlack` 七个值。生效拍 ≠ 斜坡起点：反向 / 改时长时起点是 reducer 回拨的等效起点（≤ 生效拍），
   音频按"生效时刻之前用旧斜坡、之后用新斜坡"分段，不要拿起点当换点。
3. **替换淡变在起点前与旧淡变同时占两格**：`SW_MIX_MAX_CROSSFADES` = 8，格满时新淡变静默丢掉（原有行为）；四个以上转场同时重叠才会碰到。新命令值加在 `sw_cmd_type` 末尾，原有命令值没动。
4. **G10 / KNOWN_ISSUES**：D10、D11 可销号；另记三条本分支新发现并已修的（T-bar 快推到底 / 快拉回 0 的 −16 dB 残留、T-bar 接管 Auto 后提交的残留、Auto 途中才开 AFV 停在 cos / sin），以及 §3 第 3–6 条的遗留。
5. **`testAFV_tbar_gainsFollowTheBar` 的余量变小**：提交的短淡现在落在提交那一拍（用例里是第 76 拍，比 apply 那一刻晚 8 ms）的对齐时刻、5.33 ms 走完；
   按块 / 拍相位算，比用例判定窗口（settle 16 块之后最后 4 块）的起点早约 8 ms 结束——谁缩短 settle、改对齐延迟或块大小，先重算这段余量。
6. **跨两条录音轨逐样本比**：先按两条轨首块 PTS 之差换成整样本偏移（`AFVInterruptTests.sameSample`），不要各自 `(t − first) × 48000` 取整——会差一个样本、整段 sampleDiff 全红。
   比数组用 sampleDiff（只报个数和第一个），别用 XCTAssertEqual。
7. **FTB 提前量 = 3 ms + 半块**，块大小变了跟着变；归零这种台阶仍是 τ 3 ms 的一阶平滑：−60 dB 要 ~21 ms + ≤ 1 块、吸到严格 0 要 ~41 ms + ≤ 1 块（用例按 +2 拍 −60 dB、+3 拍起严格 0 判）。
8. 引擎侧不变量用例（音频斜坡逐拍 = 画面）在 60 fps 下能做到 1e-9：Apple Silicon 时基 125 / 3，一拍正好 400 000 host tick；59.94 fps 一拍不是整数 tick，要放宽容差再用。
9. `swift test --filter 'A|B'` 在本机 Swift 6.4 下能用（正则交替，两组都跑了）；写法仍是 `Module.Class/method`。
