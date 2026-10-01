# W5-C 音频总线效果链接线 —— 报告（分支 w5-audio-bus-effects）

日期 2026-10-01。机器 Apple M5 Max（18 核，128 GB）/ macOS 27.0（26A428）/ Xcode 27.0 / Swift 6.4，电源适配器。
worktree `.claude/worktrees/w5-app-visual-c6c35d`，harness 分支 `claude/w5-audio-bus-effects-32d90a`，从 main 25af61f 开；
收尾时另建本地分支 `w5-audio-bus-effects` 指向同一提交（`make lint BRANCH=…` 与检查点按 OWNERSHIP 的分支名找）。不 push、不 merge。
提交（小步，先测试后实现）：`git log --oneline main..w5-audio-bus-effects`。

## 1. 做了什么

只动了 prompt 88 允许的文件：`Packages/SwitcherAudio/Sources/Integration/`（AudioEngine / AudioEngineStatus / ConsumerPump 改、BusEffects 新增）、
`Packages/SwitcherAudio/Tests/IntegrationTests/BusEffectsTests.swift`（新）、`Packages/SwitcherAudio/Sources/SwitcherAudio/BusEffectChain.swift`、
`Packages/SwitcherAudio/Tests/SwitcherAudioTests/EffectChainTests.swift`、App 的 `AudioEffectsSupport.swift`（新）/ `EffectChainView.swift` / `AudioEffectParams.swift` /
`App/Tests/AudioEffectsTests.swift`（新）；另有提案 `docs/contract-changes/024-dynamics-ratio.md` 与本报告。C 热路径（sw_mix.c 等）一行没动。

### 1.1 探针结论与选型（铁律 10，写代码之前做）

探针在 scratchpad（三个 Swift 小程序：参数表 / 延迟 / 响应 / 旁路 / 自建线程渲染；Q 口径与超范围；压缩曲线 vs 比例），我们依赖的结论钉成了
`EffectChainTests.testProbe_*` 回归（换 macOS 版本先看它们）。全部在 macOS 27.0 上量。

**EQ：选 AUNBandEQ（Q09 (b)）**，一个 EQ 格 = 一个 AUNBandEQ，最多 16 段；契约里连续的 parametricEQ 格映射成它的各段。

| 项 | AUNBandEQ | AUParametricEQ（W1-D 的 EQ 格，对照） |
|---|---|---|
| 在我们线程里 AudioUnitRender | 可行：C 输入回调、48 k float32 非交错 2 声道、MaximumFramesPerSlice 4096；自建线程渲染正常；**先 initialize 再装渲染回调也能用**（四种 AU 都验过，换格的"准备好再挂"靠它） | 同左 |
| 段数 | MaxNumberOfBands = **16**，默认 8；NumberOfBands 头文件写"只能未初始化时设"（27 上初始化后设也返回 0、读回生效，不依赖）→ 固定建 16 段，段数增减只改段的 BypassBand 参数，不动拓扑 | 1 段 |
| 每段范围 | 频率：头文件 20…SR/2，27 上报 10…23520 → 取 **20…23520 Hz**；增益 **−96…+24 dB**；带宽 **0.05…5 oct**；类型 0 = Parametric（`kAUNBandEQFilterType_*` 常量在头文件里标弃用，参数本身没有，写字面量 0）；**BypassBand 默认 1（段默认是旁路的）** | 频率 20…23760；Q 头文件 0.1…20（27 的 ParameterInfo 报 1…20，但 0.5 实际生效）；增益 ±20 |
| 带宽 / Q 口径 | 带宽 = 增益为峰值一半（dB）处的上下边频之比（头文件原话）；实测设 1 / 2 / 0.333 oct → 1.000 / 1.998 / 0.333 oct，**与增益无关**（+12、+6、−12 都是 1.000） | Q **不是经典口径**：Q = 1 时半增益带宽 +12 dB 2.12 oct、+6 dB 2.42 oct（随增益变）；Q = 4 → 1.39 oct，Q = 10 → 0.56 oct |
| 契约 q 的换算 | 经典 Q：BW = 2/ln2 · asinh(1/(2q))（q = √2 → 1 oct，q = 4.32 → 1/3 oct）；带宽 0.05…5 oct ↔ **q 0.1826…28.85**。与 RBJ 数字峰值滤波器（同 q）比：f0 ≤ 1 kHz 处处差 ≤ 0.06 dB；f0 = 8 kHz 时差到 0.9–1.9 dB（两边对高频"挤压"的处理不同，NBandEQ 的半增益边频是准的） | — |
| 延迟 / 尾巴 | Latency **0**（3 段 200 / 1000 / 5000 Hz 的冲激峰在第 0 帧）；TailTime 0.05 s | Latency 0；TailTime 0.001 s |
| 3 段时的处理延迟 / 开销 | 0 帧；每 256 帧块 2.3 µs（3 段）/ 4.4 µs（16 段建好、3 段开、13 段旁路）；16 段建好与只建 3 段的输出逐样本相同 | 1.2 µs |
| 旁路 | 段旁路：逐样本相同；段开、增益 0 dB：逐样本相同 | 增益 0：逐样本相同 |
| 建 + 配格式 + initialize | 中位 0.009 ms，最大 0.017 ms（20 次） | 0.007 / 0.129 ms |
| +12 dB @ 1 kHz | 实测 12.00 dB；设 +24 → 24.00 dB | 设 ±24 读回 ±24、实测 24.00（超出它自己报的 ±20） |

**DynamicsProcessor / PeakLimiter**（W1-D 的两格不换，只补实测）：

| 项 | DynamicsProcessor | PeakLimiter |
|---|---|---|
| 27 上的 ParameterInfo（头文件） | 阈值 −100…20（−40…20）、headroom 0.1…40、扩展比 1…50、扩展阈值 −120…0、起音 0.001…0.3（0.0001…0.2）、释放 0.01…3、总增益 −40…40 | 起音 0.0005…0.03（0.001…0.03）、衰减（27 叫 Release）0.001…**0.04**（0.06）、预增益 −40…40 |
| 27 上的默认值 ≠ 头文件 | 阈值 −15（−20）、headroom 5.6（5）、扩展比 1（2）、起音 0.05（0.001）、释放 0.03（0.05） | 起音 0.002（0.012）、衰减 0.005（0.024）——**每个参数都要显式设** |
| Latency | **恒 256 帧**（5.33 ms），与起音无关（0.0001 / 0.001 / 0.05 / 0.2 都是 256）；冲激峰在 256 帧 | **= 起音 × 48000**：1 ms 48 帧、2 ms 96、12 ms 576、30 ms 1440；冲激峰位置与属性一致。**运行中改起音，属性立刻变，输出无跳变**（改前后相邻样本最大差与正弦本身相同） |
| TailTime | 0.2 s | 0.1 s |
| 曲线 | **没有固定比例**：阈值以上渐近到"阈值 + headroom"（头文件原话 "does not have fixed compression ratios"）；形状与阈值无关（平移）。headroom 5：阈值上 2 / 4 / 6 / 10 / 20 dB → 输出阈值上 2.00 / 3.15 / 3.72 / 4.28 / 4.74 dB | 天花板**固定 0 dBFS**，没有天花板参数；0 dBFS 正弦 + 预增益 +3 / +6 / +12 / +20 dB → 峰值 −0.34 / −0.66 / −1.35 / −2.27 dBFS（起音 2 ms、衰减 5 ms 的默认值下） |
| 阈值 −60 | 27 上实际生效（−30 dBFS 正弦、headroom 2 → 输出 −57.8，上限 −58）；**但头文件写 −40 起，最低支持 macOS 15，只用 −40…20** | — |
| 超范围的值 | AU **不钳**：起音 0.0001、headroom 0 照收 | AU **不钳**：起音 0.05 照收、延迟变 2400 帧；衰减 0.06 照收 |
| Reset | — | `AudioUnitReset` 清前瞻缓冲：不清时，关了再开会先放出关之前缓冲里的 0 dBFS 旧信号（静音输入的前 512 帧峰值 0 dBFS），清了是零 |
| kAudioUnitProperty_BypassEffect | 输出 = 输入（**不带延迟**，256 帧前瞻也没了） | 同左（96 帧） |

### 1.2 接线（交付 1）

数据流：状态机快照 → `AudioStateBridge` 的 `.buses` 事件 → `AudioEngine.applyBuses`（增益 / 静音照旧）→ `BusEffectsController.apply`：
effects 没变（推子 / 静音也会带来 `.buses`）就什么都不做；变了的那条总线：

1. **方案**（`BusEffectPlan.parse`，纯函数）：连续的 parametricEQ 格合成一组 = 一个 AUNBandEQ（≤ 16 段，各段可单独开关）；dynamicsProcessor / peakLimiter 各一组。
   **链的顺序 = 处理顺序**，所以被别的效果隔开的 EQ 另成一组。每条总线 3 格（C 的 `SW_MIX_EFFECTS_PER_BUS`），超出 3 组的、认不出的 id（例如视频格 border）不装，记日志、计进 `ignored`。
   缺键用编辑器的默认值；数值先钳到 `EffectParameterRanges`。
2. **组 → 格号**（`BusEffectPlan.assignSlots`）：严格递增（C 按 0 → 1 → 2 处理，保序）；在所有递增放法里挑"沿用已装同种 AU 的格"最多的（不换就不用旁路），
   其次"落在默认格"（EQ 0 / 压缩 1 / 限幅 2：只有限幅时它放 2 号格，以后往前加压缩 / EQ 不用挪它），再平手取字典序最前。
3. **每格**：
   - 已是同种 AU：只设参数（AudioUnitSetParameter 可在别的线程改，AU 内部平滑；同值不重设）+ 开关；
   - **enabled = false = C 的格开关关掉**（`SW_CMD_EFFECT_ENABLE`，实时线程在块开头自己应用，跳过 render，逐样本旁路），不拆格。
     **没用 AU 的 kAudioUnitProperty_BypassEffect**（prompt 写的"AU bypass 属性"）：那是设属性，不能和 render 并发（W1-D 报告"AudioUnitRender 在自有线程"第 4 条），
     AUEffectBase 取消旁路时还会在设属性的线程上 Reset 内核；探针里 BypassEffect 的效果与 C 开关相同（输出 = 输入、延迟也没了），C 开关没有并发问题。
     再打开之前，若关格命令已被实时线程确认（commandsApplied ≥ 关格时的 commandsPushed），先 `AudioUnitReset`（实时线程此时不碰它）——不清会把关之前前瞻缓冲里的旧信号放出来；
   - 新装（格原来空着）：控制线程上建好 AU（0.01 ms 级）、initialize、设参数，当场挂进去（`attachEffectUnit`：装输入回调 + 换指针）再开——空格实时线程本来就不 render，**不用等，别的格照常**；
   - 换种类：先建好新 AU 并设好参数（不在旁路时间里做），**关掉这一格 → 等实时线程确认 → 挂新 AU、销毁旧的 → 开**（`BusEffectsController.step`，每个控制周期看一次确认）；
   - 拆格：关 → 确认 → 摘下销毁。
4. **拓扑（装 / 换 / 拆）只在快照里 effects 的组的种类或位置变了时发生**；改参数、开关、增减 EQ 段（16 段以内）都不换 AU（`testBusEffects_paramChangesKeepTopology` 用对象同一性钉住）。
   拓扑操作全在控制线程（非实时），实时回调里仍只有 W1-D 的 C 代码。
5. 钳了的参数、认不出 / 超三格的格、建不起来的 AU：**同一条（总线 + 格 + 键 + 原值）只记一次日志**（NSLog，控制线程，不在回调里），也留在 `AudioEngine.effectNotes`（最近 200 条）。

**装拆拓扑时的旁路时长**（`AudioEngineStatus.BusEffects.lastBypassBlocks`，上界 = 关 / 开两条命令入队之间混音器渲染的块数 + 1）：

| 情形 | 哪些格受影响 | 旁路 | 实测（空设备，256 帧块） |
|---|---|---|---|
| 往空格里装（0 → 3 格） | 只有新装的格（之前本来就没有它） | 0：当场装、下一块开 | `testA_busEffects_topologyChangeNoDropout` 8 次 × 3 格 |
| 同一格换种类（[EQ, 压缩, 限幅] → [限幅, 压缩, EQ]，换 0 号、2 号格，1 号的压缩不动） | 只有换的那一格 | 关格确认 + 下一个控制周期（≤ 2 ms）+ 下一块：**1 块（5.3 ms），最多 2 块（10.7 ms）** | `testA_busEffects_kindSwapBypassesOnlyThatSlotBriefly`：12 次换格，两轮读数上界分别是 1–2 块、全 2 块（入队间隔 0–1 块） |
| 拆格（3 → 0 格） | 拆的那一格 | 关格那一块起就是"没有它"（本来就要去掉） | 8 次 × 3 格，确认后摘下 |
| 改参数 / 开关 / 增减 EQ 段 | — | 无 | — |

### 1.3 效果链延迟与 A/V 对齐（交付 2）

| AU | Latency（帧 @48 k） | 说明 |
|---|---|---|
| AUNBandEQ | 0 | IIR，冲激不延迟 |
| DynamicsProcessor | 256（5.33 ms），恒定 | 前瞻 |
| PeakLimiter | 起音 × 48：1–30 ms → 48–1440 帧；编辑器默认 12 ms → 576（12 ms）；27 上 AU 自己的默认 2 ms → 96 | 起音就是前瞻 |
| 一条总线最大 | 256 + 1440 = 1696 帧 = 35.3 ms（EQ + 压缩 + 限幅起音 30 ms） | |

- **补在音频 PTS 一侧**（视频拍点不动）：每条总线已打开的 AU 的延迟之和由 `BusEffectsController` 记成"从第几块起"（`EffectLatencyTimeline`，块序号 = 消费者队列每块带的 sequence），
  泵（`ConsumerPump`）把 Master / Bus A / B / 耳机来源的块 PTS 再减去它：块里的内容就是比没开效果时晚这么多采集的，PTS 跟着往前挪，录制 / 推流 / NDI 的音画对齐不变。
- 延迟**运行中变了**（开 / 关格、换格、改限幅起音）：变化那一块按差值拼接，消费者看到的 PTS 仍连续——变大 Δ 丢掉接下来的 Δ 帧（正是 AU 刚打开时前瞻缓冲垫出来的零，打开前 Reset 过），
  变小 Δ 先补 Δ 帧静音（关掉 / 缩短前瞻时那 Δ 帧内容还在 AU 缓冲里、丢了，用静音占住时间轴）。离线驱动下拼接点精确；实时线程上命令可能晚一块应用，拼接点可能差一块，只影响那一刻的过渡，之后对齐是准的。
  录制器 / HostClockResampler 都按样本计数排时间轴，PTS 一跳就会把这 Δ 固化成偏差（或触发硬校正），所以不能只改 PTS 标签、要在泵里把样本也对上。
- **不补的**：输入来源（ISO 音轨 / 节目信号）不经总线效果，不补；扬声器 / 耳机的实时监听没有 PTS，开了压缩 / 限幅会晚 5–35 ms（不在 A2 口径里，手册要写）。
- **尾巴（TailTime）不进 A/V 对齐**：prompt 写"latency + tail"，但 tail 是输入停了之后还会响多久（NBandEQ 0.05 s、压缩 0.2 s、限幅 0.1 s），不让信号变晚；混音器是连续流，没有"结束"。只补 latency。
- `AudioEngine.programPTS(forBlockHostTime:)` 也减去 Master 当前的效果链延迟。

### 1.4 App（交付 3）

- `App/Sources/Engine/AudioEffectsSupport.swift`（87 若还没合入就本会话建，prompt 88 允许）：`busChainsApplied = true`、`inputChainsApplied = false`。87 的标签代码读这两个常量；87 与本文件会在 G6 撞同名新文件，取本会话的值。
- `EffectEditorRanges`（AudioEffectParams.swift）：滑块范围 ⊆ 引擎钳位范围（AudioEffectsTests 逐条钉住）；`EffectChainEditor(slots:)` 读老节目 / API 写进来的值时先钳进界面范围，界面值 = AU 值。
- **EQ 增益没收到 ±20**：prompt 的"增益 ±20"是单段 ParametricEQ 的范围；EQ 换成 AUNBandEQ 后 AU 是 −96…+24，界面原来的 ±24 已在里面。段数上限仍 3（≤ 16）。
- **压缩"阈值 + 比例 + 输出增益"简单模式没做**（Q61）：探针量出 AUDynamicsProcessor 没有固定比例，2:1–4:1 在最合适的 headroom 下仍差 1.6–2.0 dB（下表），按 prompt"换算不准就写提案加 ratio 键，不要硬凑"
  → `docs/contract-changes/024-dynamics-ratio.md`，**待用户定**。界面仍是原来的六个参数。

| 想要的比例 | 最合适的 headroom | 最大偏差（阈值上 0…20 dB） |
|---|---|---|
| 1.5:1 | 16.1 dB | 1.81 dB |
| 2:1 | 9.5 dB | 2.04 dB |
| 3:1 | 5.1 dB | 1.87 dB |
| 4:1 | 3.4 dB | 1.61 dB |
| 6:1 | 1.9 dB | 1.24 dB |
| 10:1 | 0.9 dB | 0.84 dB |
| 20:1 | 0.25 dB | 0.47 dB |

### 1.5 钳位表（界面值 → AU 值）

引擎钳位范围 = `SwitcherAudio.EffectParameterRanges` = 头文件范围 ∩ macOS 27 ParameterInfo（`testProbe_clampTableWithinAUParameterInfo` 钉住 ⊆ 本机 AU 的 ParameterInfo）。

| 契约键 | 以前的界面范围 | 现在的界面范围 | 引擎钳位（送进 AU） | 送进 AU 的是什么 |
|---|---|---|---|---|
| parametricEQ.centerHz | 20…20000 | 20…20000 | 20…23520 | 该段 Frequency |
| parametricEQ.q | 0.1…10 | **0.2…10** | 0.1826…28.85 | 该段 Bandwidth = 2/ln2·asinh(1/2q)，0.05…5 oct（q 0.1 → 6.67 oct 超上限） |
| parametricEQ.gainDb | ±24 | ±24 | −96…+24 | 该段 Gain |
| dynamicsProcessor.thresholdDb | −60…0 | **−40…0** | −40…20 | Threshold |
| dynamicsProcessor.headroomDb | 0.1…40 | 0.1…40 | 0.1…40 | HeadRoom |
| dynamicsProcessor.expansionRatio | 1…50 | 1…50 | 1…50 | ExpansionRatio（扩展阈值契约里没有，AU 默认 −100 dB，见 §4） |
| dynamicsProcessor.attackSeconds | 0.0001…0.2 | **0.001…0.2** | 0.001…0.2 | AttackTime |
| dynamicsProcessor.releaseSeconds | 0.01…3 | 0.01…3 | 0.01…3 | ReleaseTime |
| dynamicsProcessor.overallGainDb | ±40 | ±40 | ±40 | OverallGain |
| peakLimiter.attackSeconds | 0.001…0.03 | 0.001…0.03 | 0.001…0.03 | AttackTime（= 前瞻 = 延迟） |
| peakLimiter.decaySeconds | 0.001…0.06 | **0.001…0.04** | 0.001…0.04 | DecayTime |
| peakLimiter.preGainDb | ±40 | ±40 | ±40 | PreGain |

老值读进编辑器的例子（`testAudioEffects_editorClampsOutOfRangeValuesOnLoad`）：阈值 −60 → −40、压缩起音 0.0001 → 0.001、限幅衰减 0.06 → 0.04、q 0.1 → 0.2、增益 30 → 24、频率 30000 → 20000。
API / 节目文件直接写进来、没经过编辑器的值由引擎钳（`testBusEffects_outOfRangeParamsClampedAndLoggedOnce`：频率 30000 → 23520、q 0.1 → 0.1826（带宽 5 oct）、增益 30 → 24、阈值 −60 → −40、
压缩起音 0.0001 → 0.001、限幅起音 0.05 → 0.03（延迟 1440 帧，不是 AU 照收时的 2400）、衰减 0.06 → 0.04，七条日志各一次）。

### 1.6 手册（交付 4，归 103）

本会话不改文档，103 照这几处改：
- `docs/user/概念.md:78`："四条总线各有增益 / 静音；效果链（参量 EQ、动态、峰值限制器）在 0.1.0 里只能编辑、还没有作用到声音……接线归 prompt 88" →
  "四条总线各有增益 / 静音 / 效果链：参量 EQ（一格最多 16 段，界面给 3 段）、压缩、峰值限制器，按链的顺序处理，关掉的格旁路；开了压缩 / 限制器，这条总线会多 5–35 ms 处理延迟——
  录制 / 推流 / NDI 的音画对齐已经补上，扬声器 / 耳机监听会晚这么多。每路输入的效果链 0.1.0 里仍只能编辑、还没有作用到声音（prompt 102）。"；
- `docs/user/en/concepts.md:83` 同上英文；
- `docs/KNOWN_ISSUES.md:29`：总线一半去掉，只留"每路效果链未生效（102）"；
- `docs/api.md` `setBusEffects` 一节：补"q 为经典 Q（半增益带宽）；连续的 parametricEQ 合成一格、一格最多 16 段；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格），超出 / 认不出的不装；
  参数超出范围被钳（范围见 CONTRACTS.md §2.4）；开了压缩 / 限制器的总线，消费者流的 PTS 已扣掉处理延迟"。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherAudio --filter "IntegrationTests.BusEffectsTests"`（15 个，真设备那个要 `SW_AUDIO_REAL_DEVICE=1`）、`--filter "SwitcherAudioTests.EffectChainTests"`（14 个）；
真设备 A7：`SW_AUDIO_A7_DEVICE_SECONDS=60 swift test --package-path Packages/SwitcherAudio --filter "SwitcherAudioTests.DeviceTests/testA7_realDevice_zeroViolations"`；
App：`make gen && make test-app XCB_FLAGS="-quiet -only-testing:SwitcherTests/AudioEffectsTests …"`，计数用 `xcrun xcresulttool get test-results summary`（-quiet 吞用例行）。

### 2.1 prompt 列的测试

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testA_busEffects_eqChangesResponse` | Master 一段 1 kHz +12 dB（q 2 = 0.71 oct），离线各跑 5 s（取后 4 s，单频点 DFT）：1 kHz **+12.000 dB**，200 Hz **+0.172 dB**（理论 +0.17） | 12 ± 0.5 dB；200 Hz 不变（取 ±0.5 dB；prompt 没给 q，用 q 2——q 1 时 200 Hz 理论 +0.65） | ✅ |
| `testA_busEffects_limiterHoldsCeiling` | 0 dBFS 正弦（立体声居中）→ EQ 1 kHz +6（推到 +6 dBFS）→ 限幅（起音 2 ms）→ Master −6 dB：峰值 **−9.587 dBFS**；对照（限幅关）0.000 dBFS | ≤ −6 + 0.3 dB | ✅ |
| `testA_busEffects_bypassIsTransparent` | 三格 AU 都装着、开过（EQ +12 / 压缩 −40 / 限幅 +12）再关：Master 与没有效果的 Bus A 同一路输入 3 s **逐样本最大差 0**，PTS 起点相同，延迟 0 | 逐样本相同或 ≤ −120 dB | ✅ |
| `testA_busEffects_topologyChangeNoDropout` | 空设备（实时线程在 render）Master 0 ↔ 3 格 × 8（24 次装、24 次拆，改动放在 x.5 s）：dropouts **0**、underruns **0**、不连续 **0**、违规 0、PTS 断点 0；click 17 个最大偏差 0.002 ms；泵丢 6656 / 补 6656 帧（= 8 × 832） | A1 三项 0 | ✅ |
| A7：W1-D 离线 10 分钟（`testA7_offline10min_zeroViolations`，EQ 格现在是 NBandEQ） | 违规 0、实时区分配 0、欠载 0、112 500 块 | 0 | ✅ |
| A7：W1-D 真设备 1 分钟（`testA7_realDevice_zeroViolations`，`SW_AUDIO_A7_DEVICE_SECONDS=60`，内置扬声器，四总线 × 三格全开） | 违规 0、实时区分配 0、dropouts 0、underruns 0、11 349 块 | 0 | ✅ |
| A7：`testA7_paramChangesWhileRendering_noAllocationInRealtime`（新，守卫 + malloc 钩子，2000 块每块改 EQ 段 / 压缩阈值 / 限幅起音 = 前瞻长度） | 违规 0、实时区分配 0 | 0 | ✅ |
| `scripts/check-rt-symbols.sh`（debug / release） | 4 个目标文件，无 malloc / 锁 / 日志 / ObjC / Swift 符号，外部符号都在审计清单内（C 没改，AU 仍只经 AudioUnitRender 进来） | 绿 | ✅ |
| A2 回归：`scripts/gate4.sh --minutes 10 --label w5c-10min`（= `make gate4-run` 去掉写基线；G4 场景本身不带效果） | 整秒闪光 303 对：均值 **−0.001 ms**、σ 0.022、最大 0.375 ms；A3 0.36 ms / 8 h；A4 click 极差 0.208 ms；A1 0 | 与基线均值差 ≤ 1 ms（g4 基线那一轮 −0.001 ms；G5 final2 +0.000 ms） | ✅（差 0.000） |
| A2 回归（开着效果）：G4 场景 + Master 三格 832 帧（`.build/gate4/w5c-fx/`，5 分钟，同一套 headless + `frameprobe av`） | 整秒闪光 45 对：均值 **0.000 ms**、σ 0、最大 0.000；A4（PGM + 4 个 ISO 音轨）click 极差 0.208 ms；A1 0；录制器音频漂移 −0.003 ms、硬校正 0 | 同上 | ✅ |
| SwitcherAudio 全包 `swift test` | SwitcherAudioTests 72（跳过 2）+ IntegrationTests 56（跳过 4），**0 失败**（2.3） | 全绿 | ✅ |
| App `AudioEffectsTests` | 4 / 4 通过（xcresult 计数；同跑 MixerPanelTests 3 / 3） | 绿 | ✅ |

gate4 那一轮的 V1 / V2 / V4 / V5 / S2 是红的，**都不是音频、也不是本会话的改动**：V1 p99 31.4 ms、V2 85 帧集中在 17:15:37–45 这 9 s（每帧渲染 32 ms、GPU 0%），
同一时刻 `load.log` 里是另一个会话的 App 测试（SWBBuildService 92%、xctest、PlusMix 74%、两个 frameprobe）；V4 / V5 是同一段掉帧的后果。
S2 的 RSS 861 → 883 MB（+22 MB / 10 分钟）与 G5 final2（858 → 879，+21 MB）同量，不到 1 小时的拟合"仅供参考"。报告存在 `.build/gate4/w5c-10min/G4-run-w5c-10min.md`。

### 2.2 本会话加的其他用例

| 用例 | 数值 | 通过 |
|---|---|---|
| `testA2_busEffects_latencyCompensated_offline` | 三格 832 帧：每个 click 偏 ≤ 0.05 ms（1 样本 0.021 ms），PTS 断点 0 | ✅ |
| `testA2_busEffects_latencyChangeMidStream_splicesKeepTimeline` | 0 → 576（限幅 12 ms）→ 96（起音改 2 ms）→ 0：10 个 click 全 ≤ 0.05 ms，PTS 断点 0，泵丢 576、补 480 + 96 | ✅ |
| `testA2_busEffects_latencyCompensated_nullDevice` | 空设备 20 s：click 19 个，均值 0.004 ms、最大 0.004 ms；A1 0 | ✅ |
| `testA2_busEffects_latencyCompensated_realDevice`（`SW_AUDIO_REAL_DEVICE=1`，默认跳过） | 内置扬声器（−1.58 ppm，经 HostClockResampler）：不开 / 三格 / 关掉 A2 均值 −0.000 / −0.000 / −0.016 ms，30 个 click 最大 0.021 ms；A1 0、PTS 断点 0、泵丢 832 补 832 | ✅ |
| `testA_busEffects_kindSwapBypassesOnlyThatSlotBriefly` | 空设备，[EQ, 压缩, 限幅] ↔ [限幅, 压缩, EQ] × 6：换格 12 次，压缩那一格从头到尾是同一个 AU，换的那一格旁路上界 ≤ 2 块（10.7 ms）；A1 0、PTS 断点 0 | ✅ |
| `testA_busEffects_busAOnly` | Bus A 一段 −12 dB：Bus A −12（±0.5）、Master 0.000 dB（不串） | ✅ |
| `testBusEffects_outOfRangeParamsClampedAndLoggedOnce` | 七个越界键各钳一次、日志 7 条；推子动了、同一条链改一个范围内的值重发：仍 7 条，改动生效 | ✅ |
| `testBusEffects_unknownIdsAndOverflowIgnored` | [EQ, 压缩, EQ, 限幅, border] → 三格 [NBandEQ, 压缩, NBandEQ]，ignored 2，日志 2 条，重发不再记 | ✅ |
| `testBusEffects_paramChangesKeepTopology` | 改参数 / 加到 3 段 / 全关 / 改回：EQ、限幅格的 AU 对象不变；再加压缩进空着的 1 号格：swaps 0、installs 3 | ✅ |
| `testBusEffects_threeEQBandsShareOneSlot` | 200 Hz −6 / 1 kHz +12 / 5 kHz +6（q 4）装在一格：三个频率各 ±0.3 dB 内 | ✅ |
| `testBusEffects_planGroupsConsecutiveEQsAndAssignsSlots` | 分组、17 段拆两格、缺键默认值、七种放格情形 | ✅ |
| EffectChainTests（W1-D 4 个 + 新 10 个：NBandEQ 三段一格、q ↔ 半增益带宽、初始化后再挂、Reset 清前瞻、钳位表、探针回归 4 个、A7 改参数） | 全过 | ✅ |
| App `testAudioEffects_*` ×4 | 总线已接 / 每路未接；12 个界面范围 ⊆ 引擎钳位；EQ 段数 3 ≤ 16；超范围老值读进来就钳 | ✅ |

### 2.3 收尾全量

| 项 | 结果 |
|---|---|
| `swift test --package-path Packages/SwitcherAudio`（5 分 34 秒） | SwitcherAudioTests 72 个（跳过 2：改系统默认设备要 FULL、麦克风权限）+ IntegrationTests 56 个（跳过 4：W2-E 的真设备 A2A3、真设备 A3 长跑、A5 回环，本会话的真设备 A2——都按环境变量跳过；本会话那个单独跑过，见 2.2），**0 失败**；A7 离线 600 s 违规 0 / 分配 0（最长块 2049 µs，预算 5333）；换格旁路上界 2 块 |
| `make test-app`（全量，103 个） | 100 过、1 红、2 跳过（摄像头权限 BLOCKED-权限、虚拟摄像头 BLOCKED-签名）。红的是 `DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger`（显示类，窗口被盖住就红，坑见以往报告），**单独复跑 1 / 1 过**；与音频无关 |
| `make lint BRANCH=w5-audio-bus-effects` | 禁词、版本号、Package.swift 约束、依赖方向、归属（12 个改动文件都在允许范围内）、相对链接、实时符号：全绿 |

## 3. 没做的和原因

| 项 | 原因 / 去向 |
|---|---|
| 压缩简单模式"阈值 + 比例 + 输出增益" | AUDynamicsProcessor 没有固定比例，换算最大偏差 1.6–2.0 dB（§1.4）。按 prompt 不硬凑，写了 **提案 024，待用户定**（三个选项：加 ratio 键 + 自写压缩器、新 id compressor、不改契约只把文案写实）。界面维持原来六个参数 |
| prompt 写的"enabled = false 用 AU bypass 属性" | 用的是 C 混音器的格开关（§1.2）：设属性不能和 render 并发，C 开关由实时线程在块边界自己应用；输出同样逐样本 = 输入、延迟同样消失（探针对照过） |
| 手册 / API 文档 / KNOWN_ISSUES 改回"已生效" | prompt 交付 4：归 103，改法写在 §1.6 |
| 87 的"尚未生效"标签代码 | 归 87（只动 App/）；本会话按 prompt 只建了常量文件 `AudioEffectsSupport.swift`（87 没合入），87 合入前 App 里没有地方读它 |
| 每路效果格、图示 EQ / 噪声门等新键、界面形态改版 | prompt 不做项：102、提案 023 之后另提、97 |
| 扬声器 / 耳机实时监听的效果链延迟 | 监听没有 PTS，补不了；开了压缩 / 限幅晚 5–35 ms，写进手册（§1.6） |
| 真设备 A2（开着效果） | 用例 `testA2_busEffects_latencyCompensated_realDevice` 要 `SW_AUDIO_REAL_DEVICE=1`，本机跑过一次，数字见 §2 |

## 4. 对契约的疑问

1. **`parametricEQ.q` 的口径契约里没写**。本会话按经典 Q 实现（带宽 = 半增益边频之比，BW = 2/ln2 · asinh(1/(2q))；AUNBandEQ 的带宽参数就是这个定义）。
   设计方案 §7 / CONTRACTS.md §2.4 原来对的是 AUParametricEQ，它的 Q 不是这个口径（随增益变，§1.1）——W1-D 的单段 EQ 同一个 q 比现在宽（q 1：2.12 → 1.39 oct），
   但之前从没生效过，没有老行为要兼容。建议 P5 在 CONTRACTS.md §2.4 写进去（提案 024 "顺带"第 1 条）。
2. **每条总线最多 3 格、连续 EQ 合一格（≤ 16 段）、超出 / 认不出的不装**：契约说"一条链可多格 = 多段"，没说上限。建议同一处补注。
3. **dynamicsProcessor 没有 expansionThreshold 键**：AU 的扩展阈值在 27 上默认 −100 dBFS，所以 `expansionRatio` 在实际电平下不起作用（编辑器还给它 1…50 的滑块）。
   要做扩展 / 噪声门得加键——prompt 把"噪声门等新键"放到提案 023 之后另提，这里只记下。
4. **peakLimiter 没有天花板键**：AUPeakLimiter 天花板固定 0 dBFS。prompt 用例的"−6 dB 天花板"本会话用"限幅之后的 Master 增益 −6 dB"表达（§2）；要不要加 `ceilingDb` 见提案 024 "顺带"第 2 条。
5. **效果链延迟没进 Stats**：它在 `AudioEngineStatus.BusStatus.effects.latencyFrames`（与对齐延迟同一处）。它是配置推出来的量、不是运行统计；
   UI / API 若要显示"这条总线 +17 ms"，进 Stats 要加字段（铁律 4，要提案）。
6. `BusState.effects` / `EffectSlot` 的注释还写着"占位"，现在总线那一半已生效，P5 改契约注释时一起改。

## 5. 下一个会话需要知道的坑

1. **macOS 27 上 AU 的默认值和头文件不一样**（限幅起音 2 ms / 衰减 5 ms、压缩起音 50 ms / 阈值 −15 / 扩展比 1 …）：每个参数都要显式设（BusEffectChain 的 setter 就是这么做的）。
   **AUNBandEQ 的段默认是旁路的**（BypassBand 默认 1），每段要显式设 0。
2. **AU 不钳参数**：超范围照收（限幅起音 0.05 s → 延迟 2400 帧）。一律走 `EffectParameterRanges`；它 ⊆ 本机 ParameterInfo 由 `testProbe_clampTableWithinAUParameterInfo` 钉着，换 macOS 版本先跑它。
3. **限幅起音 = 前瞻 = 延迟**，运行中改起音延迟立刻变（泵会拼接）；编辑器默认 12 ms = 576 帧（AU 自己默认 2 ms）。界面改版想降默认延迟，改 `EffectChainEditor.Limiter` 的默认值即可。
   AUPeakLimiter 不是"输出 = 天花板"的砖墙：+6 dB 过载、衰减 24 ms 时峰值落在天花板下 3.6 dB，衰减越长压得越多。
4. **C 的三格是通用格**：`BusEffect` 的三个名字只是默认布局，`effectUnit(.master, .peakLimiter)` 取的是 2 号格，里面装什么看 `EffectUnit.kind`。
   `installEffect(bus, .parametricEQ)` 现在装的是 NBandEQ（`AudioMixer.defaultEffectKind`），要单段 ParametricEQ 用 `installEffect(_:_:kind: .parametricEQ)`。
5. **换格 / 拆格要等实时线程确认关格**：`AudioMixer.attachEffectUnit` / `removeEffectUnit` 在格开着时调会和 render 竞争（C 的 `sw_mix_ctx_remove_effect` 从控制线程写 enabled = 0、换指针，不等确认）。
   集成层之外直接调它们的代码（测试）要自己先关格、跑一块。混音器没人 render 时（引擎没起、离线驱动不推块）确认永远不来：换格 / 拆格挂着（`pendingSwaps`），往空格里装不受影响。
6. **泵在总线来源上会丢 / 补样本**（延迟变化那一刻）：总线来源交出去的帧数 ≠ 混音器渲染的帧数；`ConsumerStatus.latencyFramesDropped / Inserted` 是累计。拼接点在实时线程上可能差一块（命令晚一块应用），只影响那一刻的过渡。
   不连续检测在拼接之后做；补的静音段对 −20 dBFS 的测试信号是 0.1 的跳变，低于 A1 的 0.5 阈值，但对很响的节目会是一下"咔"——开关压缩 / 限幅本来就有这一下（AU 前瞻里的内容要么重放、要么丢）。
7. **`scripts/gate4.sh` 写死 `reports/G4-run-<label>.md` 与 `reports/G4.md`**，`make gate4-run` 还会 `--write-baseline baselines/g4-m5max.json`：检查点以外别用 make 目标跑。
   本会话用 `scripts/gate4.sh --label w5c-10min`（不写基线）跑完恢复了 G4.md、删了 G4-run-w5c-10min.md，数据留在 `.build/gate4/w5c-10min/`；开着效果的那一轮用 scratchpad 里的精简脚本，数据在 `.build/gate4/w5c-fx/`。
8. **87 与本会话都新建 `App/Sources/Engine/AudioEffectsSupport.swift`**：G6 合并时撞同名新文件，取 `busChainsApplied = true` 的版本，常量名以 87 实际用到的为准对一下。
9. harness 给的分支是 `claude/w5-audio-bus-effects-32d90a`，OWNERSHIP 按 `w5-audio-bus-effects` 找：收尾时建了同名本地分支指同一提交，检查点合并用哪个都行。
