# W1-D4 音频收口：Cut / Auto 起点统一替换淡变、120 留下的三条、压缩器换掉后清旧实测值 —— 报告（分支 w1-audio-4）

日期 2026-10-24。prompt 125（用户 2026-10-18 裁定 #17；120 §3 第 4–6 条；115 §5 第 3 条）。机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.1（27A9275）/ Swift 6.4，
接电源（AC，电池 95%）。同机并行 123 / 124 / 126 三个会话（负载 2–7；整包测试前 `ps -axo comm` 看过没有别的 xctest / xcodebuild）；没跑 gate4 / perf-baseline / soak。
worktree `.claude/worktrees/nostalgic-merkle-3d9175`，harness 分支 `claude/nostalgic-merkle-3d9175`，从 main 2ec2c05 开（= G10 快进的 1f9be64 + 一个只动 reports/ 的 docs 提交，
`git merge-base --is-ancestor 1f9be64 HEAD` 过）；**`w1-audio-4` 指向同一提交**（每次提交后 `git branch -f w1-audio-4 HEAD`）。不 push、不 merge，交 127 G11。

提交（先红后绿，小步；`git log --oneline 2ec2c05..w1-audio-4`）：红用例 → 第 3 条（状态机）→ 第 1、2 条（C 替换语义 + 跟随命令 + 集成层）→ 第 4 条 →
第 2 条补两处（跟随不撤之后的切换；Auto 走着时 PGM / PVW 照发门控，各自先红后绿）→ 本报告。
动的文件全在 OWNERSHIP W1-D4 行内：StateMachine.swift；SwitcherAudio 的 sw_audio_rt.h / sw_mix_internal.h / sw_mix.c、AudioMixer.swift、Integration/AudioEngine.swift、Integration/InputEffects.swift；
用例 StateMachineTests.swift、CrossfadeReplaceTests.swift、InputEffectsIntegrationTests.swift（各加一段）与新建的 AFVCloseoutTests.swift / FTBRealtimeFollowTests.swift。
SwitcherEngine/Audio/（AudioStateBridge、AudioControlEvent）、SwitcherContracts、docs/、App 没动。

## 1. 做了什么

### 1.1 先复现（红）

五条都按触发条件在**真状态机 → AudioStateBridge → AudioEngine → C 混音 → 消费者**整条链上量（离线 EngineRig；第 5 条另有空设备 + 控制线程的实时版），
"录音轨"取消费者流：Master、每路 `.inputProgram`（推子后含 AFV）、每路 `.input`（ISO：推子后 AFV 前），按 PTS 逐样本判；AFV 增益曲线 = `.inputProgram ÷ .input`（同一个推子后信号，只差 AFV 门控）。
修前（对着 2ec2c05 的代码跑，提交 3d70ad1 单独跑过）：

- **第 1 条**：两次 Cut 隔 2 拍（33 ms）：两次之间 1 号一直在（1344 个样本不是 0）、2 号一个样本都没有——**画面切过去 2 拍、声音没动**。不是 120 报告说的"回弹"那一种：
  离线台里第 t 拍的事件在"块尾 ≥ 第 t − 1 拍"那一块到、命令在那一块开头应用，而第一条短淡的起点是第 t₁ 拍 + 2048 帧（42.7 ms）——**隔 1–3 拍时第二条到的那一刻第一条一定还没开始**，
  默认语义和 W1-B5 的替换语义都在应用时把"还没开始的同槽位淡变"撤掉，第一次切换整个丢了；隔 4 拍、第一拍 b mod 8 ∈ 1…5 时第二条正赶上第一条在走——默认语义撤掉它，
  afv 向转场前的目标回弹（实测 0.019）、第二条起点再跳回（Master 相邻样本跳 0.22）。扫描 14 组（Cut→Cut 隔 1–5 拍、Cut→Auto 1–4、Auto→Cut 1–4，起始拍按 mod 8 挑过）**11 组红**。
  所以"只把 `.cut` / `.transitionStarted` 改成 `replacing: true`"不够（§1.2）。
- **第 2 条**：Auto 60 拍第 30 拍才开 AFV：第 152 拍起逐块 87 块里 86 块超 ±0.5 dB、最大差 **16.8 dB**；逐样本 AFV 增益与曲线最大差 0.71；旧源 t_e **+5.333 ms** 才到 −∞（走满那一拍补的短淡）。
- **第 3 条**：状态机排程路报 `[started, cancelled]`、每拍观察者注入的报 `[started, cut(2→1), cancelled]`（多报一次）；命令路本来就对。录音轨里 1 号在第 149.68 拍就回来了（AFV 增益与曲线差 0.98）。
  同一个根还量出一条：走满那一拍再排一条新 Auto，前后都是"进行中"，**一个事件都不发**（音频既不收口也不起新淡变）。
- **第 4 条**：每路链换成 dynamicsProcessor / 只剩 EQ / 清空后 `compressorMeasuredLatencyFrames` 还是 0（上一次的实测值）；总线那份本来就是 nil。

### 1.2 第 1 条：Cut / Auto 起点统一替换淡变（裁定 #17）——C 侧改替换语义

- **集成层**（AudioEngine.handle）：`.cut` 与 `.transitionStarted` 的 `crossfade` 加 `replacing: true`（短淡收口本来就是）。
- **C 侧**（`SW_CMD_CROSSFADE_REPLACE` 的语义，sw_mix.c `sw_apply_command` / `sw_xfade_take_over`）：
  - 应用时只撤同槽位上"**还没开始、且起点不早于新的一条**"的淡变（最新的命令说了算）；已经开始的、**和还没开始但起点更早的**都照走到新淡变的起点，在那一块被接管（取当时的 afv 作起点）。
    原来（W1-B5）应用时撤所有还没开始的——两次切换隔不到 ~60 ms 时前一次整个丢。
  - 接管时不碰"还没开始、起点比它晚"的同槽位淡变：那是更新的切换，到它自己的起点再接管这一条（两条可以同时排着）。
  - 默认语义（`SW_CMD_CROSSFADE`）一个字节没变：应用时撤同槽位所有淡变、起点 afv 在应用时取；引擎里已经没有路径用它（只剩 `AudioMixer.crossfade` 不带参数的老调用）。
- **改了一条既有用例**：`CrossfadeReplaceTests.testD10_pendingReplaceIsCancelledByANewerOne` 钉的正是旧语义（"两条替换都还没开始，前一条应用时被后一条取消"——前一条起点更早），
  与裁定 #17 直接冲突，按新语义改写成 `testW1D4_1_pendingEarlierReplaceRunsAtItsStart_newerTakesOverAtItsOwn`（前一条到自己的起点照走、走满后 from 严格 0）；
  另加 `testW1D4_1_pendingLaterReplaceIsSupersededByANewerOne`（起点更晚的被新命令盖掉，钉"最新的命令说了算"）、`testW1D4_1_reverseReplaceWhileTheFirstIsRunning_noRebound`（反方向接管正在走的，钉现状）。
  **这是改语义，不是放宽判据**：没有动任何阈值；这条改动请 G11 / 用户知悉（§4 第 2 条）。
- 自然走满的 Auto、T-bar 提交（120 已改）不受影响：AFVTests 9 条、AFVInterruptTests 8 条（含 `testAFV_tbar_gainsFollowTheBar`、`testD10_naturalLongAuto_endsOnItsOwnCurve_noShortFade`）全过。

### 1.3 第 2 条：Auto 进行中才打开 AFV——跟随淡变（新实时命令）

- **C 侧**：新命令 `SW_CMD_CROSSFADE_FOLLOW`（加在 `sw_cmd_type` 末尾，原有命令值没动）= 替换语义 + **跟随曲线**：from 走 cos、to 走 sin 的**绝对值**（不乘起点 afv），
  起点给转场的起点（在过去也行——C 侧原有的"迟到跳到该在的位置"让它从当前相位接上）；接上那一刻与当时 afv 的差（`resid_from / resid_to`）每样本乘 `1 − gain_smooth_k`（τ 3 ms）衰减，
  每块末小于 1e-6 归零（之后走满那一刻是精确的 0 / 1，也不会乘进非规格化数）。起点还没到时（开 AFV 恰在 Auto 起点附近）保持接管时的 afv。`sw_crossfade` 多一个 uint8 和两个 float。
- **集成层**（`AudioEngine.applyGates`）：照旧按最新状态直接门控（其余各路、以及跟随起点没到之前 PGM / PVW 先向那一刻的 cos / sin 平滑），
  然后若状态里有正在走的 Auto（全局 AFV 开、source = auto、PGM ≠ PVW）就对 PGM / PVW（参与 AFV 的）补一条跟随淡变：起点 = 转场起点拍点 + 对齐延迟、时长同它（与 transitionStarted 同一算法）。
  开 AFV、每路 AFV 位途中翻过（`inputAudioSettings` → applyGates）都走这里；T-bar 带着的（含接管了 Auto 的）不算。记录照 crossfade 写成终值，所以自然走满时 `gatesAtFinal` 不再补短淡。
- 修后：逐块最大差 **0.113 dB**（0 块超 ±0.5 dB），逐样本 AFV 增益与曲线最大差 **2.6e-7**，旧源 t_e **+0.000 ms** 到 −∞，开的那一下逐样本最大变化 0.006（τ 3 ms 平滑的量级）。
- **补一（复核时发现的竞态，C 侧）**：状态机先发事件、后发布快照，同一个控制周期里 Auto 刚被 Cut 打断（打断的短淡已经排上）、快照还说 Auto 在走时，applyGates 也会补一条跟随；
  跟随的起点在过去，套用替换的规矩（还没开始、起点不早于它的撤掉）会把打断的短淡撤了——D10 回退。跟随的应用规则反过来：**还没开始、起点比它晚的是之后的切换，留着**、到它们的起点再接管跟随；
  只撤起点不晚于它的（这条 Auto 原来那条还没开始的）。混音器用例 `testW1D4_2_followKeepsALaterPendingSwitch` 先红（短淡走满后 L 还有 4312 个样本在长曲线上）后绿。
- **补二（原有毛病，同一个函数）**：Auto 走着时 PGM / PVW 的门控记录是淡变的**终值**（PVW 记 1），applyGates 只在"新值 ≠ 记录"时发命令——PVW 的 AFV 位途中关掉、全局 AFV 途中关掉时新值恰好也是 1，
  不发，PVW 接着沿 sin 走、不回到"不跟随 = 恒 1"；PVW 位翻一下还把 PGM 直接门控成那一刻的 cos 停住。现在状态里 Auto 在走时这两路照发（参与的再由跟随接管）。
  `testW1D4_2_followThenInterrupt_andPerInputFlipMidAuto`（a 开 AFV 后被 Cut 打断、b PVW 的 AFV 位途中关再开、c 全局 AFV 途中关掉）在红用例提交的旧源码上（临时 worktree）跑过是红的：
  a 曲线差 0.20、b 的 PGM 差 0.71 / PVW 关着时离 1 差 0.59、c 的 PVW 离 1 差 0.29；修后三种都过。

### 1.4 第 3 条：Cut 恰好落在 Auto 走满的那一拍——状态机分两段推导事件

- `StateMachine.prepare(upTo:)`：每拍 advance 的事件先发（auto 走满 = `completed(.elapsed)`），每拍观察者在其后（它注入的命令走 applyNow、自己发事件），
  这一拍排程的命令一批、从 advance 之后的状态算。原来整拍前后只比一次。
- 结果：Cut 恰落在走满那一拍 = `completed(elapsed)` + 同一拍 `cut(2→1)`：音频那条等长淡变自己走满，再在这一拍的对齐时刻短淡切回——与画面同一拍（录音轨里走满之前逐样本在曲线上，差 3.0e-7）。
  每拍观察者注入的不再多报；走满那一拍再起 Auto 也有 `completed` + `started` 了。命令路（apply）原来就是先 prepare 到目标拍再 reduce，行为不变。
- `TransitionEvent` 的形状没变；同一拍里排程的多条命令仍合成一次前后比较（同一拍 Cut 两下 = 没切，照旧不发）。

### 1.5 第 4 条：压缩器换掉后清旧实测值

`InputEffectsController.status(slot:)` 的 `compressorMeasuredLatencyFrames` 按 `dynamicsKind == .compressor` 才给，`rack.measured` 缓存照留（换回同一组参数不重测，又给出来）。
总线那份（`BusEffectsController.status`）本来就取格里装着的效果的实测值，换格确认之后 nil——用例一并钉住。030 的 `statsEffects` 原来自己按种类判，现在状态已经是"装着压缩器才有"，改成照拷（同一份口径）；`test030_*` 照过。

### 1.6 第 5 条：实时模式下 FTB 跟随精度（只量不判）

`IntegrationRealtimeTests.testW1D4_5_nullDevice_ftbRetargetFollowAccuracy_measuredOnly`：D11 的四种改法在**空设备 + 控制线程**上各跑一次，同一份量法（FTBRetargetTests 的口径：Master 逐块 RMS ÷ 不淡时电平 vs reducer 逐拍的画面电平，
−20 dB 以上的块才比；全黑后看 +1 / +2 拍电平与 +3 拍起非零样本）对离线台也跑一遍并排。三次（14:27–14:29，负载 2.4–2.7）：

| 改法 | 实时：逐块最大差（三次） | 实时平均 \|差\| | 离线：逐块最大差 / 平均 | 全黑后（实时 / 离线） |
|---|---|---|---|---|
| 缩短 120→30（第 150 拍） | **0.292 / 0.350 / 0.314 dB**（最差都在第 168 拍附近，30 拍斜坡的 −20 dB 那头） | 0.089–0.091 dB | 0.114 / 0.075 dB | +1 拍 −104 dB、+2 拍起 0 / +1 拍 −110 dB、+2 拍起 0 |
| 拉长 30→120（第 135 拍） | 0.158 / 0.164 / 0.144 dB | 0.083–0.084 dB | 0.114 / 0.075 dB | +1 拍 −119 dB、+2 拍起 0 / −122 dB、0 |
| 归零（第 150 拍） | 0.111 / 0.112 / 0.112 dB | 0.077 dB | 0.113 / 0.075 dB | **+1 拍 −60.8 dB**、+2 拍 −109.5 dB、+3 拍起 0 / +1 拍 −72.6 dB、+2 拍 −121.4 dB、+3 拍起 0 |
| 反向淡回（第 135 拍） | 0.177 / 0.182 / 0.166 dB | 0.075 dB | 0.120 / 0.075 dB | — |

每次控制周期 ~1700 次、dropouts / underruns 0、空设备最晚醒 ≤ 0.11 ms、实时违规 0。离线的数与 W1-B5 报告一致（0.114 / 0.114 / — / 0.120），量法可信。
实时比离线差在"斜率最陡的那段"：Master 增益目标每个控制周期（2 ms）设一次、命令在下一个 IOProc 块开头才应用，相位与块不对齐，FTB 的提前量（3 ms + 半块）没算这段；
平均误差几乎不变，最大差在 30 拍斜坡的 −20 dB 那头到 0.35 dB。测试标准 §4 没有这一项的阈值，本会话**没设阈值**（要不要设 / 要不要把提前量再补"控制周期到下一块"那段，归用户定，§4 第 3 条）。

### 1.7 C 热路径动了什么（给 G11 的 8 小时长稳）

**动了 sw_mix.c**（G10 追加：G11 的 8 小时必须在合入后的树上跑）。只改 AFV 交叉淡变一处，回调里仍无分配、无锁、无日志、无系统调用：
1. `SW_CMD_CROSSFADE_REPLACE` 应用时多一个 `start_host < u0` 的比较（起点更早的不撤）；`sw_xfade_take_over` 多一个"还没开始且起点更晚"的跳过条件。
2. 新命令 `SW_CMD_CROSSFADE_FOLLOW`：应用时的比较反过来（`start_host > u0` 的不撤）；`sw_xfade_block` 多一个分支（跟随：每样本 cosf / sinf 各一次 + 两次乘加 + 两次钳位，与普通淡变同量级；起点那一块多两次 cosf / sinf）。
3. `sw_crossfade` 多 `follow`（uint8）、`resid_from / resid_to`（float）；8 格的表大小没变。
`scripts/check-rt-symbols.sh` 与 `--release` 都过（4 个目标文件，无 malloc / 锁 / 日志 / ObjC / Swift 运行时 / 系统调用符号；`[[clang::nonblocking]]` 照编过）。
同时排着的淡变会比原来多（起点更早的不再在应用时撤）：60 fps 下每拍都按 Cut 最多约 5 条同时在表里（事件领先 ~1 拍 + 对齐 42.7 ms + 短淡 5.3 ms ≈ 3.9 拍，再加一条长 Auto），8 格够；格满时新淡变静默丢掉（原有行为）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

"修前"列 = 同一用例对着 2ec2c05 的代码跑（红用例提交 3d70ad1）。阈值列里 ±0.5 dB 是 AFVTests / FTB 的既有口径；"严格 0 / 与 ISO 逐样本相同 / 曲线差 1e-3 / 回弹 1e-5 / 跳变 0.1 / 台阶 0.01"是本会话自定的判据
（测试标准 §4 没有这几项的阈值，**没改任何阈值**）。

| 测试 ID | 口径 | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|---|
| `AFVCloseoutTests.testW1D4_1_twoCutsThirtyMsApart_secondTakesOverTheFirst_noReboundNoSkip` | 第 120 拍 1→2、第 122 拍 2→1（33 ms）：两次之间 1 号严格 0、2 号 = ISO、Master = 2 号；之后反过来；两段短淡逐样本单调；Master ±8 块跳变 | 两次之间 1 号 1344 个样本非 0、2 号全 0 | 两次之间 2 号满 **28.000 ms**、1 号严格 0；不回弹；跳变 < 0.1 | 严格 0 / 逐样本相同 / 回弹 ≤ 1e-5 / 跳变 < 0.1 | ✅ |
| `…testW1D4_1_twoCutsThirtyMsApart_viaApply` | 命令路：两次 apply(.cut) 之间跑 30 ms（6 块），落在第 121 / 122 拍 | 两次之间 1 号 544 个样本非 0、2 号全 0 | 通过 | 同上 | ✅ |
| `…testW1D4_1_quickSwitchSweep_oneToFiveTicks_audioFollowsBothSwitches` | 14 组：Cut→Cut 隔 1/2/3/4（b mod 8 = 1，正在走那一相）/4（= 7，已走完）/5 拍；Cut→Auto 隔 1–4 拍（第二次是 30 拍 Auto 切回）；Auto→Cut 第 1–4 拍打断 | **11 / 14 组红**：隔 1–3 拍整段丢第一次；隔 4 拍正在走那一相回弹 0.019、Master 跳 0.22；Cut→Auto 隔 1–3 拍 Auto 段曲线差 1.0；Auto→Cut 第 1–3 拍打断前曲线差 0.036–0.140（长 Auto 还没开始就被撤） | **14 / 14 组过**；Auto 段逐样本曲线最大差 1.5e-7–2.9e-7 | 同上；Auto 段逐样本曲线差 < 1e-3 | ✅ |
| `CrossfadeReplaceTests.testW1D4_1_pendingEarlierReplaceRunsAtItsStart_newerTakesOverAtItsOwn`（**改写自** `testD10_pendingReplaceIsCancelledByANewerOne`，§1.2） | 混音器两路直流：长淡变中排两条替换短淡（起点 6 块 / 12 块之后）：前一条到起点照走、走满后 from 严格 0 | 第一条起点处不起短淡（1556 个样本非 0） | 过 | 曲线 ±2e-6；严格 0 | ✅ |
| `…testW1D4_1_pendingLaterReplaceIsSupersededByANewerOne` | 新命令起点更早、方向相反：起点更晚的旧淡变在应用时撤（最新的说了算） | 过（旧语义也撤） | 过 | L 恒 1、R 恒 0 | ✅（钉语义） |
| `…testW1D4_1_reverseReplaceWhileTheFirstIsRunning_noRebound` | 第一条 4800 帧走到 ~30% 时排反方向替换短淡（~57% 处起）：起点前逐样本仍在第一条上、之后从当时增益走回 | 过（W1-B5 已支持正在走的接管） | 过 | 曲线 ±2e-6；回弹 ≤ 1e-6；跳变 < 0.01 | ✅（钉现状） |
| `CrossfadeReplaceTests` 原有 2 条（`testD10_replaceCrossfade_*`、`testD10_plainCrossfadeStillCancelsAtApply_contrast`） | W1-B5 的替换 / 默认语义 | 过 | 过 | 原判据 | ✅ |
| `AFVCloseoutTests.testW1D4_2_afvTurnedOnMidAuto_gainsFollowTheRemainingCurve` | Auto 60 拍第 30 拍才开 AFV：第 152 拍起逐块 vs 等幅曲线；逐样本 AFV 增益；t_e 旧源到 −∞；开的那一下逐样本变化 | 86 / 87 块超差、最大 **16.8 dB**；逐样本差 0.71；t_e **+5.333 ms** | 0 / 87 块超差、最大 **0.113 dB**；逐样本 **2.6e-7**；t_e **+0.000 ms**；台阶 0.006 | ±0.5 dB；t_e ± 0.05 ms；台阶 < 0.01 | ✅ |
| `CrossfadeReplaceTests.testW1D4_2_followCrossfade_lateJoinTracksTheAbsoluteCurve_smoothJoin` | 混音器：L = R = 1 时排起点在 47 块之前的跟随淡变：第一个样本 = 接上前的增益；接上后逐样本变化；50 ms 后 vs 绝对 cos / sin；走满后 0 / 1 | —（新命令） | 第一个样本 0.9999999 / 0.9999956（= 接上前）；最大变化 0.0021；50 ms 后差 **1.9e-7**；走满后 from 严格 0、to 1 ± 2e-7 | 不跳变 1e-6；< 0.003；< 2e-6 | ✅ |
| `CrossfadeReplaceTests.testW1D4_2_followKeepsALaterPendingSwitch` | 混音器：先排 12 块之后的替换短淡、再补起点在过去的跟随：短淡起点接管跟随、256 帧后 L 严格 0、R 满 | 跟随把短淡撤了：L 4312 个样本还在长曲线上 | 过 | 严格 0；1 ± 2e-7 | ✅ |
| `AFVCloseoutTests.testW1D4_2_followThenInterrupt_andPerInputFlipMidAuto` | a 第 150 拍开 AFV、第 160 拍 Cut：开后到打断逐样本在曲线上、打断 +1 块起旧 0 新满；b PVW 的 AFV 位第 135 拍关、第 150 拍开：PGM 全程在 cos 上、PVW 关着时恒 1、重新参与后在 sin 上、t_e 旧源到 −∞；c 第 150 拍关全局 AFV：两路恒 1 | a 曲线差 0.20；b PGM 差 **0.71**、PVW 关着时离 1 差 **0.59**、重新参与后差 0.29、t_e +5.333 ms；c PVW 离 1 差 **0.29** | a 2.3e-7；b PGM 2.1e-5、PVW 关着时离 1 4.4e-6、重新参与后 2.3e-7、t_e +0.000 ms；c 4.4e-6 / 4.4e-6 | 曲线差 < 1e-3；恒 1 差 < 1e-4；t_e ± 0.05 ms | ✅ |
| `StateMachineTests.testW1D4_3_cutOnTheTickTheAutoElapses_isElapsedThenCut_notCancelled` | 30 拍 Auto 第 330 拍走满、同一拍 Cut：排程路 / 每拍观察者注入 / 命令路三条事件序列；走满那一拍再起 Auto | 排程路 `[started, cancelled]`；观察者路 `[started, cut, cancelled]`；再起 Auto 只有 `[started]` | 四段都是 `started → completed(elapsed) → cut(2→1)` / `… → started(2→1) → completed` | 逐个相等 | ✅ |
| `AFVCloseoutTests.testW1D4_3_cutOnTheTickTheAutoElapses_audioSwitchesBackOnThatTick` | 录音轨：走满之前（前一块为止）逐样本在曲线上；第 150 拍 + 1 块起 1 号满、2 号严格 0；Master 跳变 | 曲线差 **0.98**（第 149.68 拍 1 号就回来了） | 曲线差 **3.0e-7**；之后 1 号满、2 号 0 | 曲线差 < 1e-3；严格 0 | ✅ |
| `InputEffectsIntegrationTests.testW1D4_4_compressorSwappedOut_measuredLatencyBackToNil` | 每路：压缩器 → dynamicsProcessor / 只剩 EQ / 清空 → 压缩器；总线：压缩器 → dynamicsProcessor → 清空；状态、状态快照、Stats 三处 | 每路三种都是 **0**（旧值） | 每路 / 总线 nil，换回压缩器又是 0（缓存）；Stats 照对 | nil | ✅ |
| `IntegrationRealtimeTests.testW1D4_5_nullDevice_ftbRetargetFollowAccuracy_measuredOnly` | 实时 FTB 跟随（§1.6 表） | — | 缩短 0.29–0.35 / 拉长 0.14–0.16 / 归零 0.11 / 反向 0.17–0.18 dB（离线 0.113–0.120） | **不设阈值**（只量） | 只量 |
| AFVTests 9 条 / AFVInterruptTests 8 条 / FTBRetargetTests 5 条 / VideoDelayCompensationTests 8 条（1 跳：回环 BLOCKED-硬件） | 既有口径（含 `testAFV_tbar_gainsFollowTheBar`、D10 / D11 全部） | 过 | 过 | 原阈值 | ✅ |
| `AudioSyncEventTests` 12 条 / `AudioBridgeTests` | 引擎侧 D10 / D11 事件口径 | 过 | 过 | 原判据 | ✅ |
| SwitcherCore 整包 `swift test`（14:38–14:47，负载 3–4.5，同机另有 App 的 xcodebuild） | Render 101 / Engine 131 / Contracts 115 | — | **347 = 346 过 + 1 跳 + 0 红**（跳的是原有 `testP2_stats_oldGateFilesParse`：新 worktree 没有老 gate 产物）；比 G10 多 1 条（StateMachineTests） | 全绿 | ✅ |
| SwitcherAudio 整包 `swift test`（14:47–14:55，负载 1–3） | SwitcherAudioTests 92 / IntegrationTests 98 | — | **190 = 183 过 + 7 跳 + 0 红**（跳的都是原有：真设备 A2 / A3 三条、回环 A5 两条 BLOCKED-硬件、改系统默认输出 / 输入设备两条）；比 G10 的 178 多 12 条（CrossfadeReplaceTests +4、AFVCloseoutTests 6、InputEffects +1、FTB 实时 +1）。A1：`testA1A2_nullDevice_clickOffsetAndContinuity` 30 s click 29 个均值 −0.006 ms、dropouts / underruns / 不连续 / 违规 0；`testLifecycle_nullDevice_addRemove100Times_A1Zero` 全 0；`DeviceTests.testA1_builtInOutput_dropoutsAndUnderrunsZero` 过 | 全绿；A1 = 0 | ✅ |
| `scripts/check-rt-symbols.sh` / `--release` | CSwitcherAudioRT 4 个目标文件 | — | 无 malloc / 锁 / 日志 / ObjC / Swift 运行时 / 系统调用符号 | 0 违规 | ✅ |
| `make lint BRANCH=w1-audio-4`（C locale 与 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8` 各一遍） | 禁词 / 版本号 / Package.swift / check-deps / check-ownership / check-help / check-links / check-rt-symbols | — | 两遍都过；check-ownership："13 个改动文件都在允许范围内"（含本报告）；check-deps 8 个包方向正确 | 全绿 | ✅ |
| 下游编译 | `swift build` SwitcherTestKit、Tools/switcher-headless（`AudioMixer.crossfade` 多了带默认值的参数、状态机事件推导变了；App 源码 grep 过不调 crossfade / TickObserver） | — | 两包都编过（47 s / 34 s） | 能编 | ✅ |

## 3. 没做的和原因

1. **8 小时长稳没跑**（prompt：G11 在合入后的树上跑）。**本会话动了 C 热路径（sw_mix.c，§1.7）**，G11 必须在合入后的树上用户终端 `make soak`；gate4 / perf 按指示也没跑。
2. **Auto 中途才注册的输入**仍按那一刻的进度直接门控（`registerInput` 没补跟随淡变）：走满那一拍 `gatesAtFinal` 对不上、短淡收到终值（W1-B5 的兜底）。边角（转场中途才给 PGM / PVW 挂音频环），prompt 没要，记一笔。
3. **同一拍里排程的"Cut + Auto"仍合成一次前后比较**：前后只看到"开始一条 2→1 的转场"，那一下 Cut 的 1→2 声音不切（画面那一拍从 2 起淡回 1）。`prepare` 只把 advance 和这一拍的命令分开，
   命令之间没拆（拆了"同一拍 Cut 两下"会变成两条事件）；场景脚本才会这样排，记一笔。
4. **实时 FTB 跟随的提前量没改**：prompt 只要量一次、写进报告（§1.6）；要不要补"控制周期到下一块"那段，等用户定。
5. **一阶平滑在 1 附近停住（原有）**：`afv += (目标 − afv)·k`（k = 0.0069）在离 1 还差约 4.3e-6 时增量小于半个 ulp、加不进去，"差 1e-6 以内吸到目标"永远到不了；
   直接门控到 1 的那一路之后与 ISO 不逐样本相同（−0.00004 dB，听不出）。推子增益 `g` 同理。不在本会话范围、也不影响任何用例判据（收口都走淡变、走满时钉死终值），没改，§5 第 3 条记坑。
6. **真设备 / 回环**：本会话改动在混音器里，空设备与离线都覆盖；A5 回环两条照旧 BLOCKED-硬件（要音频接口回环线）。

## 4. 对契约的疑问

1. **没改契约**：SwitcherContracts、JSON 字段、测试图案都没动。改了的公开接口都在 SwitcherAudio 包内：`sw_cmd_type` 末尾加 `SW_CMD_CROSSFADE_FOLLOW`（原有值不动）、
   `SW_CMD_CROSSFADE_REPLACE` 的语义（§1.2）、`AudioMixer.crossfade` 多一个默认 false 的 `following:`（源码兼容）；SwitcherEngine 的 `TransitionEvent` 形状没变，只是事件推导更细（§1.4）。
2. **请用户知悉：替换淡变的语义改了**（裁定 #17 的落法）。"还没开始、起点更早"的旧淡变不再在应用时撤（照走、到新的一条起点被接管）——这是让隔不到 ~60 ms 的两次切换都听得到的唯一改法；
   W1-B5 钉旧语义的那条混音器用例按新语义改写了（§1.2），不是放宽判据。
3. **要用户定：实时 FTB 跟随要不要阈值 / 要不要再补提前量**（§1.6）。离线 ≤ 0.12 dB，实时最差 0.35 dB（缩短到 30 拍那条的 −20 dB 一头），平均差不多；测试标准 §4 没有这一项。
4. **告知：Auto 中途开 AFV 的声音时刻**：开 AFV 本身照旧立即生效（不晚对齐延迟，用户 2026-09-22 的口径），之后的曲线按画面时间线（转场起点 + 对齐延迟）接上——两者叠起来是"立即平滑到当前进度，再跟着画面走"。
5. **告知：Auto 途中关掉 PVW 的 AFV 位 / 全局 AFV，PVW 现在立即（τ 3 ms）回到恒 1**——这是 2026-09-22 每路 AFV 开关裁定的本意（"翻了就立刻按最新状态重算"），原来 Auto 走着时因为比记录漏发（§1.3 补二）。

## 5. 下一个会话需要知道的坑

1. **离线台里事件领先多少**：第 t 拍的事件在"块尾 ≥ 第 t − 1 拍"的那一块到、命令在那一块开头应用（EngineRig.run：prepare 到"块尾所在拍 + 1"）。一拍 800 帧、一块 256 帧，相位 8 拍一循环：
   两次切换隔 1–3 拍时第二条到的那一刻第一条（起点 = 拍点 + 2048 帧）一定没开始；隔 4 拍时第一拍 b mod 8 ∈ 1…5 正赶上第一条短淡在走；≥ 5 拍已走完。要测"正在走"那一相得按 mod 8 挑起始拍（扫描用例的做法）。
2. **同一个用例里 XCTest 没记全失败**：扫描用例修前红了 11 组，日志里只有前 19 条失败（Auto→Cut 的几组一条都没记，打印的数却是红的）；第 2 条的逐块循环同一次跑却记了 161 条。原因没查清。
   **逐样本 / 逐块的判据先收集成问题清单、每个用例最后断言一次**（AFVCloseoutTests 的 `Problems`），否则红的时候既刷屏又可能漏。
3. **"满 = 与 ISO 逐样本相同"只在淡变走满（终值钉死）之后成立**：直接门控到 1（`SW_CMD_INPUT_AFV_GAIN`）的那一路因一阶平滑在 1 − 4.3e-6 停住（§3 第 5 条），与 ISO 差一点点。
   写判据时收口要走淡变；混音器层看稳态 1 用 ±2e-7（R 声道本来就是）。
4. **迟到接上的淡变相位可能差 1 帧**：C 侧按 tick 差换算已走帧数时截断取整（`(uint64_t)(−dt / tpf)`），逐样本比曲线要容 k / k − 1 两种（CrossfadeReplaceTests 的跟随用例）。
5. **淡变表现在会同时排好几条**（起点更早的不再在应用时撤）：`SW_MIX_MAX_CROSSFADES` = 8，60 fps 下每拍都按 Cut 最多约 5 条；格满时新淡变静默丢掉（原有行为）。谁要加大对齐延迟或加别的淡变用途，先算这个数。
6. **每拍观察者注入命令不再重复报事件**（§1.4）：原来观察者 apply 的那一下自己报一次、prepare 又从 advance 之前比一次（Cut 报两次、Auto 中打断报两次 completed）；场景执行器若数事件，数目会变（仓库里没有用户：grep 过 TickObserver / addTransitionSink 只在 SwitcherEngine 与其用例）。
7. **跟随淡变的残差**：接上时 = 当时 afv − 曲线值，按 τ 3 ms 衰减、每块末 < 1e-6 归零。开 AFV 若在 Auto 最后 ~10 ms，残差还没衰减完就走满，块末钉终值会有一个小台阶（边角）。
8. **实时用例在别的会话忙时偶发红**：`VideoDelayTests.testAV_videoDelay_zeroDelayDispatchesDirectlyOnCompletionThread` 在负载 6.7 下少收一帧（119 / 120）红过一次，单独复跑 7 / 7 绿——与本会话改动无关（视频时钟），属 KNOWN_ISSUES"测试与工具"那类。
9. **`swift test --filter` 只选中一个测试包时，另一个包也打一行 `Executed 0 tests`**，拿 `grep Executed | tail -1` 数可能正好取到它、看成 0 条（本会话 EffectsLatencyStatsTests 撞过一次）；数用例看对应包那几行。
10. **快照比事件晚**：状态机先发转场事件、后发布快照，音频控制线程同一个周期里可能已经处理了"转场结束"、`bridge.lastSeenState` 却还说转场在走。凡是按快照判"转场进行中"去发混音命令的，
   都要想清楚会不会盖掉事件路已经排好的东西（跟随淡变因此不撤起点更晚的，§1.3 补一）。
11. **验证"修前是红的"可以开临时 worktree**：`git worktree add --detach <scratchpad>/oldsrc <红用例提交>`，把新用例文件拷进去单独跑（编一次约 15 s），跑完 `git worktree remove --force` + `prune`。
   不要在本 worktree 里 checkout 旧源文件——别的测试包里用到新接口的用例会编不过。
12. **给 G11 记账（KNOWN_ISSUES 归 G11 改）**：S3"音频收口四条"可销号（第 1–4 条，用例见 §2）；"新发现、已修"两条：Auto 途中关掉 PVW 的 AFV 位 / 全局 AFV 时 PVW 不回到恒 1（§1.3 补二）、
   每拍观察者注入命令时转场事件重复报 / 走满那一拍再起 Auto 一个事件都不发（§1.4）；遗留进表：§3 第 2、3、5 条（Auto 中途注册的输入、同一拍排程的 Cut + Auto、一阶平滑在 1 附近停住），
   以及实时 FTB 跟随最差 0.35 dB 等用户定（§4 第 3 条）。
