# W1-D3 每路音频效果格 / 自写压缩器 / 监听来源 —— 报告（分支 w1-audio-3）

日期 2026-10-11。机器 Apple M5 Max（18 核，128 GB）/ macOS 27.0.1（26A434）/ Xcode 27 / Swift 6.4，电源适配器。
worktree `.claude/worktrees/w1-audio-3-effects-60bcbe`，harness 分支 `claude/w1-audio-3-effects-60bcbe`，从 main 30e4659（G8a 快进后）开；
收尾时另建本地分支 `w1-audio-3` 指向同一提交（`make lint BRANCH=…` 与检查点按 OWNERSHIP 的分支名找）。不 push、不 merge。
提交（小步，先测试后实现）：`git log --oneline main..w1-audio-3`。

## 1. 做了什么

只动了 prompt 102 允许的目录：`Packages/SwitcherAudio/`（CSwitcherAudioRT / CSwitcherAudioHost / SwitcherAudio / Integration 与两个测试 target）、
`App/Sources/Engine/AudioEffectsSupport.swift`（只翻 `inputEffectsApplied = true`）；另有本报告与一张问题单 `reports/issues/W1D3-app-monitor-source-and-input-effects-wiring.md`。
SwitcherContracts 一个字没动（023 / 024 / 026 的契约 P5 已落地，直接用）。

### 1.1 每路输入的两格（交付 1、2、4）

| 项 | 做法 |
|---|---|
| C 结构 | `sw_input_slot` 加 `fx[2]`（`sw_effect_slot`，与总线三格同一种结构）+ `fxwork[2]` 乒乓缓冲 + `fx_sample_time`；`sw_effect_slot` 加 `kind`（AU / 自写压缩器）、内嵌的 `sw_compressor` 状态、`post_gain`（ceilingDb）。全部在 `sw_mix_ctx_create` 时分配 |
| 顺序 / **tap 点** | 固定 EQ（0 号格）→ 动态（1 号格）。处理在**重采样之后、延迟线之前**（`sw_process_input` 第 2b 步）：延迟线 → 推子（增益 / 静音 / AFV / 声像）→ 送总线 → 耳机 → 两种输入 tap 都在它之后。所以 **ISO 音轨（推子后、AFV 前）、含 AFV 的节目信号、耳机（延迟线前 / 后两种取点）、表，看到的都是效果后的信号**；效果不另加一条路，与 ISO 的 tap 点一致 |
| 单声道输入 | AU / 压缩器拿两路一样的输入（第二路指向第一路），输出第二路落在空闲的 [1] 暂存里，下游只用 [0]；立体声正常两路 |
| 预建 | `AudioMixer.installInputEffects()`：32 槽位 × （AUNBandEQ 16 段全旁路 + DynamicsProcessor 参数显式设成编辑器默认）= **64 个 AU，0.8 ms，RSS 增量 0.0 MB**（`testInputEffects_prebuildCostReport`；AU 实例本身很小，缓冲是 `fxwork` 32 × 2 × 4096 × 4 B = 1 MB，算在 `sw_mix_ctx_create` 里）。引擎创建时由 `InputEffectsController` 调一次 |
| 运行期 | 只有命令：`SW_CMD_EFFECT_ENABLE`（i2 = 宿主：0 总线 / 1 输入）、`SW_CMD_FX_KIND`（这一格跑 AU 还是压缩器，只改指向）、`SW_CMD_FX_PARAM`（压缩器 6 个系数）、`SW_CMD_FX_POST_GAIN`；AU 参数照旧 `AudioUnitSetParameter`。不改拓扑 |
| 增删输入时的复位 | 不在回调里：`AudioEngine.finishRemovals` 发 detach 后把槽位记进 `pendingFreeSlots`，**等实时线程确认（commandsApplied ≥ 序号）才还给空闲表**并清 `InputEffectsController` 的记录；下次 attach 前的 `sw_mix_ctx_prepare_slot`（Host）把两格关掉、kind 回 AU、`AudioUnitReset` + 压缩器包络清零。改之前 `freeSlots` 在 detach 入队那一刻就还了，`prepare_slot` 的 `AudioUnitReset` 可能和还在 render 的 AU 并发 |
| 集成层映射 | `InputEffectsController.apply(slot:inputNumber:effects:)`：`InputEffectPlan.parse`——所有 `parametricEQ` 格（不论链里是否连续）按顺序合成 EQ 格的各段（≤ 16，多的不装）；第一个动态格（`compressor` / `dynamicsProcessor` 二选一）进动态格，第二个不装；`peakLimiter` / 认不出的 id 不装；都记一次日志（`AudioEngine.effectNotes`，总线 / 每路共用一份 `EffectNoteLog`）。钳位表同 88（`EffectParameterRanges`，加了 `compressor` 六键与 `peakLimiter.ceilingDb`） |
| 事件来路 | `AudioStateBridge` 不发 effects / monitorSource 事件（只 diff `settings.audio`），引擎每个控制周期在 `pollSnapshot()` 返回"有新快照"时自己 diff `lastSeenState`（`syncSnapshotExtras`）；注册时取缓存或最新快照。`inputsChanged` 事件里的 effects **不用**（start 时排队的全量事件会比按最新快照落好的链更旧、把它盖掉——集成用例撞到，§5） |
| 延迟口径（交付 4） | 这一路已开格的延迟之和（NBandEQ 0 / DynamicsProcessor 256 / 压缩器实测）**从这一路的对齐延迟线里扣**：`alignmentDelayFrames = 对齐延迟 − 就绪年龄 − 效果延迟`（效果在延迟线之前，总时长不变），补不齐的进 `residualFrames`；与 88 的总线口径同一算法（补偿量 = 已开格延迟之和），只是落点不同：总线补在 PTS / 视频延后，每路补在自己的延迟线上，**总线时间线与 PTS 不动**。开 / 关动态 AU 的那一下该路内容跳 256 帧（一次性，与总线效果的拼接同一性质） |
| 状态 | `AudioEngineStatus.InputStatus.effects`（`InputEffects`：eqEnabled / eqBands / dynamicsKind / dynamicsEnabled / latencyFrames / compressorMeasuredLatencyFrames / ignored）、`AudioEngine.inputEffectsStatus(_:)`；`BusEffects.compressorMeasuredLatencyFrames` |

### 1.2 自写 C 压缩器（提案 024 (b)；G6 追加 ①–⑥）

`sw_compressor_process`（CSwitcherAudioRT，总线 1 号格与每路动态格共用这一份）：

- **拓扑**：前馈、**不用前瞻、组延迟按设计 0 帧**。检测器 = 立体声联动（取两路 |x| 的较大者）的解耦峰值检测器：释放级 r = max(d, αR·r + (1 − αR)·d)（瞬时起音、指数释放），再过一级起音一阶平滑 e += (r − e)(1 − αA)。
  稳态正弦的包络 ≈ 峰值（1 kHz / 释放 100 ms 时纹波 0.04 dB），所以静态曲线对得上 R:1，不像 AUDynamicsProcessor 那样没有固定比例。
- **增益计算**（dB 域，Giannoulis / Massberg / Reiss 2012 的静态曲线）：over = x − T；over > W/2 → y = T + over/R；|over| ≤ W/2 → y = x + (1/R − 1)(over + W/2)²/(2W)；over < −W/2 → y = x；增益 = y − x + 补偿。
  `CompressorParameters.staticGainDb(inputDb:)` 是同一公式的 Swift 版（测试 / 界面画曲线用）。
- **回调成本**：每样本一次 `log2f` + `exp2f`（libm 纯函数，check-rt-symbols 允许清单原来就有，清单没改）+ 几次乘加；包络低于拐点下沿时不进 log。系数（αA、αR、1/R、补偿线性值、拐点下沿线性值）在控制线程算（`sw_compressor_alpha`、`CompressorParameters.cValue`），expf 不进回调。
- **参数口径**（契约 §2.4 的六键，范围进 `EffectParameterRanges.table["compressor"]`）：阈值 = 峰值 dBFS；比例 n:1；kneeDb = 拐点宽 W（0 = 硬拐点）；起音 / 释放 = **线性域峰值包络的一阶时间常数**（不是 dB 域增益走到 63% 的时间——4:1 以上时后者约为前者的一半，见 §2）；补偿加在最后。
- **延迟自测**（②）：`sw_compressor_probe_latency`（Host）用同一份 `sw_compressor_process` 在**独立实例**上跑 4800 帧静音 + 第 1000 帧一个 0.25 的冲激，返回输出峰值位置 − 1000；
  集成层每次装格 / 改参数都量一次（`CompressorLatencyProbe.measured`），与自报 0 比，不一致按量到的记并记一条日志（含参数）。量不到（输出全零）按自报记并记日志。
- **进对齐**（③）：总线上的压缩器走 `BusEffectsController.publishLatency` → `EffectLatencyTimeline` → 泵补 PTS / videoDelay 下交给视频引擎（与 88 / 105 同一条路，`AudioEngine.syncVideoDelay` 没改）；每路的进该路延迟线（§1.1）。
- **二选一**（⑤）：`BusEffectPlan.parse` 里第一个动态类组（`dynamicsProcessor` 或 `compressor`）占 1 号格，之后再出现另一个记日志不装；换种类走 88 的换格流程（关格 → 确认 → `SW_CMD_FX_KIND` + 参数 / 挂 AU → 开），压缩器格不建 AU（原来的 AU 卸下销毁）。
- **`peakLimiter.ceilingDb`**（⑥）：`sw_effect_slot.post_gain_target`，渲染完（AU 或压缩器）乘一个一阶平滑（τ 3 ms，与推子同一系数）的系数，无分配、不多占格；格关着时不作用（旁路 = 原样）；拆格 / 换成别的效果时回 0 dB。

### 1.3 监听来源（提案 026）与借 Master 声道（X09；G7 追加 ②、2026-10-10 裁定）

做在混音器而不是设备客户端（问题单建议的是 IOProc 散射时换指针；放在 `sw_mix_block` 的出口选路里一样零拷贝，但**空设备 / 离线也能测**，App 的设备层一行不用改）：

- `SW_CMD_MONITOR_SOURCE i0 = 总线号`：耳机出口（out 平面 6 / 7）= 所选总线（Master / A / B）的最终信号；`3` = 耳机总线自己（旧行为，**混音器的默认**，W1-D2 的用例不变）；
  **有独听时总是耳机总线**（只有独听的路；PFL / AFL 照旧）。实现：`sw_process_bus` 多一对"镜像出口"参数，所选总线把自己的输出同时写进耳机那对平面，耳机总线那一块不写平面——不多拷一块，消费者队列 / 表 / 总线自身处理不变。
- `SW_CMD_MONITOR_BORROW_MASTER i0 = 0/1`：开着且有独听时 Master 出口（平面 0 / 1）写耳机总线、Master 总线不写平面；录制 / 推流拿的 Master 消费者流不受影响（用例钉住）。
- 集成层：`AudioState.monitorSource` 由 `syncSnapshotExtras` 推给混音器（默认 master：**引擎起来后耳机出口默认就是 Master**，与契约一致；`headphones` 契约判无效，万一出现按 master）；
  `AudioEngine.borrowMasterForMonitor`（任意线程，App 按 `AppSettings.borrowMasterForMonitor` 设）；两样都进 `AudioEngineStatus`。
- **视频延后跟不跟监听的那条总线**（G8a 追加、reports/w1-core-4.md §5 第 9 条）：**不跟**。视频延后的定义是 Master 的效果链延迟（prompt 105 / 提案 028：节目输出时间线 = 采集 + L_m），录制 / 推流的 PTS 也按它补；
  监听 Bus A 而 Bus A 的效果延迟 ≠ Master 时，耳机里的声音与画面差 L_A − L_m，但这只是监听、不进文件。改口径要同时改泵的时间线，等用户定（§4 第 3 条）。`AudioEngine.syncVideoDelay` 没改。
- App 侧（`MixerModel.listen` 发命令、`listenToOtherBusSupported` 翻 true、`AudioRuntime` 设 borrow、两处"尚未生效"文案）超出本会话目录，写了问题单 `W1D3-app-monitor-source-and-input-effects-wiring.md`（每项 ≤ 50 行）。

### 1.4 App（交付 3）

`AudioEffectsSupport.inputEffectsApplied = true`。87 的 `HonestUITests.testUI_effectChainMarkedNotEffectiveUntilSupported` 与 88 的 `AudioEffectsTests` 各有一条 `XCTAssertFalse(inputEffectsApplied)`
写着"102 接上时翻"——在 App/Tests 里，本会话不许动，合入后 `make test-app` 这两条会红，直到 App 会话 / G8 胶水翻过来（问题单第 3 条；与 88 对 87 的处理一样）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherAudio --filter "SwitcherAudioTests.InputEffectsTests"`（13 个，9 s）、`--filter "IntegrationTests.InputEffectsIntegrationTests"`（9 个，25 s）；
全包 `swift test --package-path Packages/SwitcherAudio`；真设备 A7：`SW_AUDIO_A7_DEVICE_SECONDS=60 swift test --filter "SwitcherAudioTests.DeviceTests/testA7_realDevice_zeroViolations"`；
真设备 A1：`SW_AUDIO_A1_SECONDS=600 swift test --filter "SwitcherAudioTests.DeviceTests/testA1_builtInOutput_dropoutsAndUnderrunsZero"`（两个真设备搭台现在都带每路两格 + Bus A 压缩器 + ceilingDb）。

### 2.1 prompt 列的测试

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testA_inputEffects_eqChangesResponse`（混音器级 + 集成级各一） | 输入 1 一段 1 kHz +12 dB（q 2）：Master **+12.000 dB**；输入 2（同一信号，Bus A）**−0.000 dB**；集成级关掉后 0 dB（±0.05）、状态 eqEnabled / eqBands 对得上 | 12 ± 0.5；别的路 ± 0.05 | ✅ |
| `testA_inputEffects_bypassIsTransparent`（两级） | 两格（EQ +12、压缩阈值 −40 / 10:1）开过（电平差 > 3 dB）再关：与同一信号的无效果路**逐样本最大差 0**，PTS 起点相同、延迟 0 | 逐样本相同 | ✅ |
| `testA_inputEffects_addRemoveInputNoDropout`（空设备实时，W2-E 用例扩一条） | 输入 2 带 [EQ, compressor] 增删 100 次：dropouts **0**、underruns **0**、不连续 **0**、违规 **0**；格开着 100/100 次；常驻路 click 均值 −0.008 ms、最大 0.008 ms | A1 三项 0 | ✅ |
| A7 离线 10 分钟（`testA7_offline10min_zeroViolations`，8 路每路两格全开：EQ 一段 + 偶数路压缩器 / 奇数路 DynamicsProcessor，Bus A 1 号格压缩器，Master ceilingDb −1，监听来源 Bus A，每 100 块改一路压缩器参数） | TODO | 0 | TODO |
| A7 真设备 1 分钟（`testA7_realDevice_zeroViolations`，内置扬声器，4 路每路两格 + 四总线三格 + Bus A 压缩器） | TODO | 0 | TODO |
| A7：`testA7_inputEffectsParamChangesWhileRendering_noAllocationInRealtime`（新；守卫 + malloc 钩子，2000 块每块改一路 EQ 段 / 压缩器六个参数 / 每 97 块切种类 / 改 ceilingDb / 换监听来源 / 翻借 Master） | 违规 0、实时区分配 0、欠载 0、丢命令 0 | 0 | ✅ |
| `scripts/check-rt-symbols.sh`（debug / release） | 4 个目标文件：无 malloc / 锁 / 日志 / ObjC / Swift 符号；新用的 `log2f` / `exp2f` 本来就在允许清单里，清单没改 | 绿 | ✅（debug）/ TODO（release） |
| W1-B 的 AllocationProbe（malloc 钩子）回调线程 malloc | 上面三条 A7 用例都挂着钩子：0 | 0 | ✅ |
| A2 回归（`scripts/gate4.sh --checkpoint W1D3 --label w1d3`，= `make gate4-run` 不写 G4 的入库文件） | TODO | 与基线均值差 ≤ 1 ms | TODO |
| A1 真设备 10 分钟（`testA1_builtInOutput_dropoutsAndUnderrunsZero`，`SW_AUDIO_A1_SECONDS=600`） | TODO | 0 | TODO |
| SwitcherAudio 全包 `swift test` | TODO | 全绿 | TODO |
| V1 / CPU：8 路全开效果（每路 EQ 一段 + 压缩器，Master EQ + 压缩器 + 限幅）vs 不开，空设备 20 s（`testCPU_eightInputsAllEffects_report`） | TODO | 报数；超 W4-A 基线 10% 要解释 | TODO |

### 2.2 压缩器（G6 追加 ①–⑥）

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testA_compressor_ratioCurveWithinHalfDb` | 阈值 −20，输入阈值下 12 dB → 上 20 dB 每 2 dB 一点，比例 2 / 4 / 10 / 20、拐点 0 / 6 / 12：与 R:1 硬拐点 / 软拐点理论曲线**最大偏差 0.008 dB**（4:1 硬拐点：+2 → −1.49 / −1.50 … +20 → −14.99 / −15.00；4:1 拐点 6：0 → −0.56 / −0.56） | ≤ 0.5 dB | ✅ |
| `testA_compressor_measuredLatencyEqualsReported` | 四组参数（默认、−60 / 20:1 / 硬拐点 / 起音 0.1 ms / 释放 10 ms、0 dB / 1:1 / 拐点 24 / 起音 200 ms / 释放 3 s、−40 / 4:1 / 补偿 24）冲激法量到的组延迟全部 **0** = 自报 0；冲激放 2000 处也是 0 | 一致 | ✅ |
| `testA2_compressor_latencyCompensated`（集成） | Master 压缩器（阈值 0，click 不进压缩）：latencyFrames **0**、compressorMeasuredLatencyFrames 0、无延迟日志，click 在整秒（≤ 0.05 ms）；把探针换成"量到 48 帧"（模拟算法与自报不一致）：latencyFrames **48**、日志一条（含两个数）、泵丢 48 帧、click 早 **1.000 ms**（= 48 帧，补偿路径走到了泵）、PTS 连续 | 实测进时间线 | ✅ |
| `testA_compressor_attackReleaseTimeConstants` | 阈值上 20 dB 台阶（−40 → 0 → −40 dBFS）、起音 20 ms / 释放 200 ms / 20:1：混音器输出的每毫秒包络与同一递推的 Swift 模型**最大偏差 0.005 dB**（样本级对齐）；增益走到终值 63% 用时：起音 11 ms（模型 11）、释放 313 ms（模型 313）——线性域包络的 τ 与 dB 域 63% 不是一回事，口径写在 §1.2 | 包络 ≤ 0.5 dB；63% 与模型 ±3 / ±10 ms | ✅ |
| `testA_compressor_sharedImplementationOnBusSlot` | Master 1 号格 kind = compressor（不装 AU）：−10 dBFS 立体声居中（检测器看到 −13 dBFS）、阈值 −20 / 4:1 → **−5.25 dB**（理论 −5.25） | ± 0.5 | ✅ |
| `testA_inputEffects_dynamicsSlotHoldsAUOrCompressor` | 动态格：DynamicsProcessor 阈值 −40 把 −10 dBFS 压低 > 6 dB；运行期切成压缩器（阈值 −20 / 4:1 硬拐点）→ −7.5 dB（理论 −7.5）；不换拓扑 | ± 0.5 | ✅ |
| `testBusEffects_compressorAndDynamicsProcessorShareSlot`（集成） | [EQ, compressor, limiter] → 格 [nBandEQ, compressor, peakLimiter]；再发 [EQ, dynamics, compressor, limiter] → 1 号格换成 dynamicsProcessor（swaps 1）、compressor 记"二选一"不装（ignored 1）；[compressor] 单独 → [nil, compressor, nil]（swaps 2） | — | ✅ |
| `testA_busEffects_limiterCeilingDb`（两级） | 0 dBFS 正弦 + 限幅预增益 +6 + ceilingDb −6（总线增益 0）：峰值 **−6.658 dBFS**（限幅器自己 −0.66，W5-C 量过它不是砖墙）；ceilingDb −30 钳到 −20 → ≤ −19.7、日志一条；格关掉 → 0 dBFS 原样 | ≤ −6 + 0.3 | ✅ |

### 2.3 监听来源 / 借 Master（两级）

| 测试 ID | 数值 | 通过 |
|---|---|---|
| `testMonitor_monitorSourceSelectsBusForHeadphoneOutput`（混音器级） | 默认耳机出口静音（没人路由到耳机）；选 Bus A → 耳机出口与 Bus A **逐样本相同**；选 Master → 同 Master；独听 1 号 → 耳机 = 独听路（Bus A 的电平 ±0.05 dB）、≠ Master；取消独听回 Master；选回 3 = 旧行为 | ✅ |
| `testMonitor_borrowMasterChannelsWhileSolo`（混音器级） | 借 Master 开 + 独听 1 号：Master 出口上 0 号的 1 kHz < −80 dB（整周期 DFT）、独听的 1.5 kHz 在；**Master 消费者队列仍有 1 kHz**；独听关 → 回 Master；开关关 → 独听时仍 Master | ✅ |
| `testMonitor_monitorSourceFromState_andBorrowMasterWhileSolo`（集成） | 状态默认 master：耳机出口逐样本 = Master；`setMonitorSource(busA)` → 逐样本 = Bus A、状态回显 busA；`borrowMasterForMonitor = true` + 独听 2 号 → Master 出口无 1 kHz、有 1.5 kHz，Master tap 仍有 1 kHz；独听关回 Master | ✅ |

### 2.4 其他新用例

| 用例 | 数值 | 通过 |
|---|---|---|
| `testA_inputEffects_sitBeforeDelayLine` | 延迟补偿 100 ms + EQ：click 位置与无 EQ 相同（效果在延迟线前、不另加延迟） | ✅ |
| `testA_inputEffects_latencyCountsAgainstAlignmentDelay`（集成） | 输入 1 装 DynamicsProcessor（256 帧）：对齐延迟线 1089 → **833**、状态 latencyFrames 256，拆掉回 1089；切换前后各 2 s 之外的 click 在整秒（≤ 0.05 ms）、Master PTS 连续 | ✅ |
| `testInputEffects_unsupportedSlotsIgnoredAndLoggedOnce`（集成） | [limiter, border, EQ × 17, compressor, dynamics]：EQ 16 段、动态 = compressor、ignored 3（限幅、第 17 段、第二个动态）、日志 3 条，重发不再记；`border` 格由状态机的 setInputSettings 清掉（到不了引擎），引擎自己也认不出它（纯函数钉住） | ✅ |
| `testInputEffects_prebuildCostReport` | 64 个 AU **0.8 ms**、RSS +0.0 MB | ✅（< 2 s） |
| EffectChainTests 一处跟改 | `makeEffectUnit(.compressor)` 报 `notAnAudioUnit`；四种 AU 的"初始化后挂回调"照旧 | ✅ |

### 2.5 收尾全量

TODO

## 3. 没做的和原因

| 项 | 原因 / 去向 |
|---|---|
| App 接线：`MixerModel.listen` 发 `setMonitorSource`、`listenToOtherBusSupported` 翻 true、`AudioRuntime` 设 `borrowMasterForMonitor`、音频设备页"尚未生效"文案、两个 App 用例翻 True、压缩器简单模式界面 | App 只许翻一个常量；每项 ≤ 50 行，写了问题单 `reports/issues/W1D3-app-monitor-source-and-input-effects-wiring.md`（引擎入口都列在里面） |
| 视频延后跟"当前监听的总线" | 定为不跟（§1.3）：视频延后 / 录制 PTS 都按 Master 的 L_m，监听别的总线只影响耳机；要改口径见 §4 第 3 条 |
| "听耳机总线自己"（每路 `routing.headphones` 送出的那条）的入口 | 契约 026 把 `monitorSource = headphones` 判无效，引擎按契约做：有独听听独听的，否则听所选总线（默认 Master）。混音器层保留了旧行为（`setMonitorSource(.headphones)`），只是状态里没有入口（§4 第 1 条） |
| 噪声门 / 图示 EQ / 每路限幅 | prompt 不做项（要新键，另提案）；每路链里的 `peakLimiter` 不装、记日志 |
| 手册 / API 文档改"每路效果已生效"、压缩器口径、监听来源 | 归 103 / 文档会话：`docs/user/概念.md` 与 `en/concepts.md`"每路输入的效果链 0.1.0 里仍只能编辑"那句、`docs/KNOWN_ISSUES.md` 的"每路效果链未生效（102）"、`docs/api.md` setInputSettings / setBusEffects 一节补 compressor / ceilingDb / 每路两格的限制 |
| 真设备 A2（开着每路效果） | 用例 `testA2_busEffects_latencyCompensated_realDevice` 是总线的；每路效果不动总线时间线，A2 由 gate4 回归与 A1 真设备覆盖 |

## 4. 对契约的疑问

1. **`monitorSource` 不许是 `headphones` 的后果**：026 之后耳机出口 = 所选总线 / 独听，`BusRouting.headphones`（每路"送耳机"）这一位只在耳机总线的录制轨 / 消费者 tap 里可见、扬声器 / 耳机听不到。
   W5-K 菜单里的"耳机总线（现在）"没有对应的状态。要么接受（并让文档把 `routing.headphones` 说成"送耳机总线的录制轨"），要么 026 放开 `headphones`（契约改一行 + reducer / 校验器各一行；引擎已支持，`setMonitorSource(.headphones)` 就是旧行为）。
2. **每路链的限制没写进契约**：每路只有 EQ（≤ 16 段，不要求连续，顺序照链里的先后）+ 一个动态格（compressor / dynamicsProcessor 二选一）；处理顺序固定 EQ → 动态，与链里的先后无关；`peakLimiter` 每路不装。建议 P5 在 CONTRACTS.md §2.4 "总线那一半 W5-C 起生效，每路的归 W1-D3"那句后面补这几条（与 88 §4 第 2 条同一处）。
3. **视频延后与监听总线**：现在跟 Master（提案 028 的定义）。若要"跟当前监听的那条总线"，泵的时间线也得换成那条总线的 L，录制 / 推流的 PTS 就不再按 Master——这是产品口径，请定；引擎侧改 `AudioEngine.syncVideoDelay` 与 `ConsumerPump` 的 `follow` 一处。
4. **压缩器起音 / 释放的口径**：实现为线性域峰值包络的一阶时间常数（§1.2），dB 域增益走到 63% 的时间约为它的一半（4:1 以上）。契约 §2.4 只给了范围与默认值，建议 P5 补一句口径（界面的"起音 5 ms"用户理解成哪种都行，但要一致）。
5. **效果延迟仍不进 Stats**（同 88 §4 第 5 条）：每路的 `InputEffects.latencyFrames` / 压缩器实测延迟只在 `AudioEngineStatus`，UI / API 要显示得加字段（铁律 4，要提案）。
6. 没改任何 SwitcherContracts 类型、JSON 字段、测试图案。

## 5. 下一个会话需要知道的坑

1. **AUPeakLimiter 会"卡"在 −34 dB**：持续 +6 dB 过载的 0 dBFS 正弦上，输入对齐那一下（延迟线 0 → 1089 帧 = 相位跳 0.69 周期、同时解除静音）之后限幅器的增益逐块收到 −34 dB 不回来（每块约 −6 dB，不是我们的 3 ms 平滑）；
   先等信号稳定再开限幅就没事（W5-C 的用例恰好是这个顺序）；静音 → 满幅（无相位跳变）也没事（`DebugLimiterTests` 探过，已删）。真节目有动态不会一直过载，但**节目里切换带延迟补偿的源时限幅器可能遇到同样的跳变**——没在真素材上复现，先记着；不是本会话改出来的（C 侧限幅路径只换了调用方式，逐样本行为由 W5-C 的旁路用例钉着）。
2. **`AudioStateBridge` 的 `inputsChanged` 事件可能比最新快照旧**：start 时第一次 `pollSnapshot()` 的全量事件在 `pendingEvents` 里排队，第一个控制周期先按最新快照做了 `syncSnapshotExtras`，再处理这条旧事件——如果从事件里取 effects 就把新链盖掉。
   每路 effects 现在只从 `lastSeenState` diff；`settingsCache`（`settings.audio`）仍从事件取，有同样的理论窗口（`.inputAudioSettings` 事件总是最新的，所以实际没撞到），W2-E 系以后改的话一并看。
3. **摘掉的槽位要等 detach 确认才能复用**（`pendingFreeSlots`）：32 路全占、刚摘一路立刻再注册会在 ≤ 1 块（5.3 ms）内 `noFreeSlot`；App 的 `AudioRuntime.register` 只对 `inputAlreadyRegistered` 重试，真撞到要加一条。
4. **状态机会清掉 `border` 格**（P4 的搬迁口径）：给输入设 effects 时 `border` 到不了引擎；引擎自己也认不出它，纯函数路径钉住了。
5. **`AudioEngine.status` 每 50 ms 刷一次**：设了 `borrowMasterForMonitor` / 发了 `setMonitorSource` 立刻读 `status` 可能还是旧值，读 `engine.borrowMasterForMonitor` 或跑几块再读。
6. **压缩器的时间常数口径**：线性域包络 τ；阈值上 20 dB 台阶、20:1 时 dB 域增益走到 63% 用时 ≈ 0.55 τ（11 ms vs 20 ms）。要"dB 域 τ"得把平滑挪到增益计算之后（Giannoulis 的 log-domain detector），但那样稳态正弦的曲线会差 1–2 dB（增益计算在检测器之前就没有峰值保持）——曲线 ±0.5 dB 优先。
7. **单声道输入过效果格**：第二路输入指向第一路，第二路输出落在 `resampled[1]` / `fxwork[1]`，下游只用 [0]；立体声联动的压缩器对单声道就是单声道。
8. **测整周期 DFT**：1 kHz 与 1.5 kHz 同时在场时窗长要是 96 样本的倍数（4800），否则 1.5 kHz 泄漏进 1 kHz 的读数（−67 dB），`testMonitor_borrowMasterChannelsWhileSolo` 第一版撞到。
9. **Swift 里 `where` 是关键字**：参数名 `at where:` 编不过（`expected expression`），用 `place`。
10. `EffectUnit.bus` / `.effect` 对输入格的 AU 是 `preconditionFailure`——拿位置用 `location`；`AudioMixer.effectUnitsStorage` 现在按 `EffectLocation` 存。
11. check-rt-symbols 的允许清单没改：`log2f` / `exp2f` / `fabsf` 原来就在；`sw_compressor_update_derived` 是头文件里的 inline，RT 命令应用处与 Host 初始化都调它。
12. harness 分支是 `claude/w1-audio-3-effects-60bcbe`，OWNERSHIP 按 `w1-audio-3` 找：收尾建了同名本地分支指同一提交，检查点合并用哪个都行。
