# W2-E 音频集成 —— 报告（分支 w2-audio-integ）

日期 2026-09-15。机器 Apple M5 Max / macOS 26.6 / Xcode 26.6 / Swift 6.3.3，电源适配器，室温；同一台机器上另有四个 W2 会话在编译 / 跑测试（load 2–7），
用户桌面在用。worktree `.claude/worktrees/w2-audio-integ-00e60c`，harness 分支 `claude/w2-audio-integ-00e60c`（= 引用 `w2-audio-integ`），从 main 2290b4e 开。
提交：见 `git log main..w2-audio-integ`（11 个，小步；报告在最后一个）。`make lint BRANCH=w2-audio-integ` 绿（禁词 / 依赖方向 / 归属 / 实时符号）。

## 1. 做了什么

只动了 OWNERSHIP 允许的目录：`Packages/SwitcherCore/Sources/SwitcherEngine/Audio/`（2 个文件）+ `Tests/SwitcherEngineTests/AudioBridgeTests.swift`、
`Packages/SwitcherAudio/Sources/Integration/`（7 个文件，target `SwitcherAudioIntegration`）+ `Tests/IntegrationTests/`（9 个文件）、`Packages/SwitcherAudio/Package.swift`（只加这一个 target）、
`docs/contract-changes/004`、`reports/issues/W2E-*`。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 引擎里挂音频 | `AudioEngine.registerInput(number:ring:hints:)` / `unregisterInput`：槽位表 + `AudioMixer.attach`（先 attach、对齐前静音、就绪后放音）；摘除先把 AFV 增益淡到 0、3 块后 `detach`，环对象等实时线程确认后在控制线程释放（W1-D 的 pendingRelease） | `AudioInputHints{producerBlockFrames, deliveryJitterFrames, sameClockAsOutput, targetFramesOverride}` 决定就绪目标：max(2 块, P + 1 块, 抖动 + 1 块) |
| 2 AFV | 引擎侧 `AudioStateBridge`（`TransitionEventSink` + 快照 diff）→ `AudioControlEvent`（拍点已换成 host time）→ `AudioEngine`：auto 转场 = `crossfade(from:to:durationBlocks:startHostTime:)`，Cut = 1 块短淡（可配），T-bar 按推杆设 cos / sin 增益，FTB 线性淡出 Master（可配关）。**所有动作在混音时间 = 拍点 + 对齐延迟 处应用**（块 T 里的内容是 T − 对齐延迟 采集的，文件里才同刻） | 门控与 FTB 斜坡是纯函数 `AudioProgramGate`，测试与实现共用 |
| 3 音频 PTS | 每路就绪后读 `InputSlotStats.ageSetpoint`，用延迟线补到统一的 `alignmentFrames`（默认 2048 = 42.67 ms）；消费者块 PTS = 块首 host time − 对齐延迟 = 内容采集时刻，与视频拍点同一 host 时基；录制器两轨零点同源（W1-E 的 RecordingStart） | 真设备时泵线程把设备时钟重采样到 host 时钟（`HostClockResampler`，纯前馈，A3）；空设备 / 离线不重采样（bit 精确） |
| 4 监听 | 每路 solo / routing / pan / gain / mute / delayMs、总线增益 / 静音、PFL / AFL 从快照 diff 落到混音命令；表读数与对齐 / AFV / 设备 / 计数在 `AudioEngineStatus`（50 ms 刷新）；`audioCounters` 是 `Stats.audio` | 表进 Stats 要契约加字段：提案 004 待批 |
| 5 headless `--audio-device` | G2 的 headless 已有 null / default / 名字；换用 AudioEngine 的接线补丁在 `reports/issues/W2E-g3-headless-audio-engine-wiring.md`（Tools/ 不是本会话目录） | 本会话在 scratchpad 里用打了补丁的副本跑了全部文件级测试 |
| 6 A2 路径 | 合成视频闪光 + 合成音频 click → 引擎 → Recorder → `frameprobe av`：见 §2 | 另有 `a1check` 探针（scratchpad）：读音轨按已知 click 位置排除后数不连续 |

集成层的形状：`AudioEngine`（控制线程 2 ms 周期、转场事件到达即醒；所有混音命令都在非实时线程发）、`ConsumerPump`（一个来源一个 tap，多个消费者扇出；泵线程 2 ms；Master 流上做不连续检测）、
`HostClockResampler`、`DiscontinuityDetector`、`AudioEngineConfiguration`（`.offline` = 离线驱动 + 手动 `runControlCycle(now:)` / `pumpOnce()`，测试确定性）。
消费者协议 `AudioBlockConsuming` 与 W1-E 的 `AudioBlockConsumer` 逐字同签名，组装方写 `extension Recorder: AudioBlockConsuming {}` 一行即可（001 批后合并成契约协议）。

代码量：Engine 侧 Swift 215 行、集成层 Swift 1416 行、测试 1656 行（45 个用例：Engine 10 + Integration 35，其中 3 个按环境跳过：真设备 A2/A3、A5 回环）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherCore --filter AudioBridgeTests`（10 个，0.2 s）；`swift test --package-path Packages/SwitcherAudio --filter IntegrationTests`（35 个，90 s，含 30 s 空设备实时）。
长跑：`SW_AUDIO_A2_SECONDS=600` / `SW_AUDIO_REAL_DEVICE=1` / `SW_AUDIO_A3_REAL_SECONDS=3600` / `SW_AUDIO_RESAMPLE_SECONDS=600`。
文件级：scratchpad 里打了补丁的 headless（`SW_AUDIO_SILENT=1`，M0 标准负载 8 路合成源、每 30 s Cut / 每 5 min Fade、录制 + stats）+ 仓库的 `frameprobe av`。
整包回归：SwitcherCore 144 个全绿（含新 10 个）；SwitcherAudio 87 个（W1-D 52 + 本会话 35）全绿、5 个按环境跳过，281 s。

### A2 A/V 偏移（阈值 |均值| ≤ 16.7 ms，目标 ≤ 5；音频超前为正）

| 路径 | 时长 | 均值 | 标准差 | 最大 | 通过 |
|---|---|---|---|---|---|
| 文件级：空设备，M0 标准负载录制，`frameprobe av`（G2 同一条命令；G2 时 −18.3 ms） | 45 s（冒烟） | 0.000 ms | 0.000 | 0.000 | ✅ |
| 文件级：空设备，M0 标准负载录制，`frameprobe av` | 10 min | 0.000 ms | 0.000 | 0.000 | ✅（300 对整秒闪光；全部 600 对含 59.94 在播段的均值 −0.194 / 最大 466.7 ms 是那路闪光周期 1.001 s 的已知假象，G2 报告第 5 条） |
| 文件级：真设备（MacBook Pro 扬声器，buffer 256，−2.42 ppm），同上 | 10 min | −0.017 ms | 0.009 | 0.021 | ✅（300 对整秒闪光） |
| 引擎内（消费者流，无录制器）：空设备实时 `testA1A2_nullDevice_*` | 30 s | +0.002 ms | 0.000 | 0.002 | ✅ |
| 引擎内：离线搭台 `testA2_offline_*`（P 256 / 1024 两路、+100 ppm 源、用户延迟 100 ms、对齐补不齐的残差） | 5–60 s | 0 ± 0.02 ms（1 样本） | — | 0.05 | ✅ |

机理：混音器输入槽就绪那一刻的年龄 = 目标 512 + P/2 + 47 + 16 + 相位 [0, 256) 帧，空设备实测 749–900 帧（15.6–18.8 ms）——正是 G2 的 −16.6…−18.5 ms（G2 猜的"录制器首块锚定"不是主因，
录制器漂移 0.005 ms）。现在延迟线补到 2048 帧、PTS 扣 2048 帧，click 回到闪光帧那一拍，运行间不再随相位变。
真设备与空设备的差异：真设备（内置扬声器）的输出设备时钟相对 host −2.42 ppm（泵线程按 stamp 测得，重采样比 1.0000024；W1-D 报告里两路估计器读数反推也是 −2.5 ppm），不重采样的话录制音轨 10 分钟晚 1.45 ms、8 小时 70 ms（A3 不过）；重采样后 10 分钟 A2 −0.017 ms（1 样本）、斜率 × 8 h −1.09 ms。真设备的就绪年龄 1210 帧（空设备 749–900）：多出的 ~300 帧 = 回调提前量 6.3 ms（块 T 在 T − 6.3 ms 渲染、年龄按 T 算）+ 相位，对齐延迟照样补齐（838 帧），PTS 不变。两者的录制器漂移都 ≈ 0（0.005 / 0.010 ms，硬校正 0）。符号：真设备均值为负 = 音频晚 17 µs，在 click 定位 ±1 样本（21 µs）之内。

### A3 A/V 漂移（阈值 斜率 × 8 h ≤ 16 ms；8 小时实跑放 W4-A）

| 路径 | 时长 | 斜率 | × 8 h | 通过 |
|---|---|---|---|---|
| 文件级：真设备（MacBook Pro 扬声器，buffer 256，−2.42 ppm）录制，`frameprobe av` | 60 min | +0.00001（1823 对整秒闪光；均值 −0.065 ms，σ 0.042，最大 0.125；前 / 后半小时均值 −0.0658 / −0.0653） ms/s | +0.20 ms | ✅（设备 −2.57 ppm，不重采样会是 −74 ms / 8 h） |
| 文件级：空设备录制 | 10 min | 0.00000 ms/s | 0.00 ms | ✅（空设备时钟 = host 时钟） |
| 引擎内：`HostClockResampler` 合成 +30 ppm 设备时间线 | 10 min | 全程 click ≤ 3 样本、稳态 ≤ 1.5 样本，拟合 × 8 h ≤ 1 ms | | ✅（不重采样会漂 173 样本 / 2 min） |
| 引擎内：−50 ppm 60 s / 0 ppm 20 s | | ≤ 3 样本 / ≤ 1.5 样本 | | ✅ |
| 引擎内：源 +100 ppm 经混音器估计器（`testA3_offline_driftingSource`） | 60 s | 稳态 ≤ 0.1 ms，斜率 × 8 h 在 click 定位噪声内（±3.6 ms） | | ✅ |

### A1 音频断裂（阈值 0，硬性；= 超时 + 欠载 + 波形不连续）

| 路径 | 时长 | dropouts | underruns | 不连续 | 违规 | 通过 |
|---|---|---|---|---|---|---|
| 文件级：空设备 M0 标准负载录制；不连续用 `a1check` 对录制音轨按已知 click 位置排除 | 10 min | 0 | 0 | 0（1200 次 > 0.5 满幅的跳变全部在 click 位置） | 0 | ✅ |
| 文件级：真设备 | 10 min | 0 | 0 | 0（1312 次跳变全部在 click 位置：AAC 解码 + 重采样让边沿多出几个过 0.5 的台阶） | 0 | ✅ |
| 文件级：真设备 | 60 min | 0 | 0 | 0（9248 次跳变全部在 click 位置；泵线程流式启发式也是 0） | 0 | ✅ |
| 引擎内：空设备实时 30 s（2 路，其一 +100 ppm；流式检测按已知 click 排除） | 30 s | 0 | 0 | 0 | 0 | ✅ |
| 增删输入 100 次期间（空设备实时 ~22 s；离线 100 次 ~50 s 音频） | | 0 | 0 | 0 | 0 | ✅ |

不连续检测器：`DiscontinuityDetector`（`Sources/Integration/`）——相邻样本跳变 > 0.5 满幅；离线 `analyze(samples:isExcluded:)` 按已知 click 位置排除（正式口径），
流式 `feed` 给泵线程做诊断（平台启发式识别 click，Master 里 click 叠上更响的别路时会误报，见 §5）。prompt 说放 frameprobe / TestKit，那两个不是本会话目录：
文件级用的是 scratchpad 的 `a1check`（TestKit.MediaReader 解码 + 本检测器），W1-A / G3 可以把 `analyze` 搬进 frameprobe（30 行）。

### A4 多文件对齐（阈值 ≤ 1 帧，目标 ≤ 1 ms）

| 路径 | 结果 | 通过 |
|---|---|---|
| 文件级：4 个录制器（PGM 视频 + 输入 1–4 各自的 ISO 音轨，源时钟 0 / +100 / −100 / +50 ppm），`frameprobe av f1 f2 f3 f4` | 2 min，120 个事件：click 极差最大 0.208 ms（前 10 s，±100 ppm 两路的估计器还在收敛），12 s 之后最大 0.042 ms（2 样本）、均值 0.008 ms；闪光极差 0（四文件同一 PGM）；4 个文件视频 7200 帧 / 音频 5763426 样本完全一致，录制器漂移 −0.007 ms、硬校正 0 | ✅（目标 1 ms） |
| 引擎内：4 路 ISO tap，同一秒的 click 极差（`testA4_fourISOTaps_*`，20 s） | 0.042 ms | ✅ |

视频 ISO（每路自己的画面）是 W3-C 的；这里 4 个文件的视频都是 PGM，比的是音轨里同一事件（frameprobe 的 A4 口径就是各文件同一闪光 / click 的时刻极差）。

### AFV（阈值：Fade 30 拍逐块电平与等幅曲线误差 ≤ 0.5 dB；起点与视频转场同一拍 ≤ 1 块）

| 项 | 数值 | 通过 |
|---|---|---|
| Fade 30 拍 @60（500 ms）逐块 RMS vs cos / sin，期望增益 ≥ −20 dB 的 173 块 | 最大 0.361 dB | ✅ |
| 同上，−20…−40 dB 的尾巴 | 最大 0.843 dB | ⚠️ W1-D 的 crossfade 只收整块时长（94 块 = 501.33 ms，+0.27%），tan(θ)·dθ 在尾部放大；起点样本精确所以挪不动。问题单 `W2E-w1-audio-*` |
| 起点：t_s 之前 PVW 路严格 0，含 t_s 的块开始变化 | 误差 < 1 块 | ✅ |
| 与视频对照：首个混合帧是第 s + 1 拍（progress 1/30），含 t_{s+1} 的块电平 = sin(π/2 · 中心时刻/D) | ≤ 0.5 dB | ✅ |
| 等幅：两路不同频率，Master 全程电平 | ±0.5 dB | ✅ |
| 59.94：30 拍 = 500.5 ms（有理数） | 曲线同上 | ✅ |
| Cut：含 t_s 的块开始切，下一块之后 from 路 ≤ −48 dB 尾巴（τ 3 ms）、to 满；Master 电平不塌 | | ✅（尾巴是 W1-D 淡变收口被最后一个曲线样本覆盖，问题单） |
| T-bar 0.25 / 0.5 / 0.75 / 1.0 | 各 ≤ 0.5 dB | ✅ |
| AFV 关：全部可闻、Cut 不影响；开：非 PGM 静音 | | ✅ |
| FTB 30 拍：Master 逐块 RMS vs 1 − level（level ≤ 0.9 的 60+ 块） | ≤ 0.5 dB；全黑后 0；关回来 | ✅ |
| 实时（空设备、控制线程驱动）Fade 30 拍：起点块、中点 −3.01 ±0.5 dB、终点 | | ✅ |
| 桥（Engine 侧）：fade / cut / setProgram / tbar / FTB 反转 / 5994 拍点 / 全量与增量 diff / 事件在 prepare 返回前到达 | 10 个 | ✅ |

### A5 监听延迟

BLOCKED-硬件：需要音频接口回环线（耳机出 → 线路入）。脚本写好：`testA5_monitorLatency_loopback`（设 `SW_AUDIO_LOOPBACK_OUTPUT` / `SW_AUDIO_LOOPBACK_INPUT` 设备名 + 麦克风 TCC 权限后跑）：
低延迟配置（buffer 128、就绪目标 1 块、对齐延迟 0）下发 click → 耳机总线 → 设备 → 线 → 输入设备 → 环 → 输入 tap，测往返 / 2，判 ≤ 20 ms。
预算（W1-D 报告 §5 的核算）：输入 buffer + 安全偏移 + 环年龄（目标 1 块 + P/2 + 63 ≈ 5.3 ms）+ 输出 buffer + 输出延迟；buffer 128 时约 12–14 ms，buffer 256 约 22 ms（边上）。
**默认配置下耳机总线也经过对齐延迟（42.67 ms），A5 达不到**——对齐与低延迟监听在 W1-D 现在的信号链里二选一（§4 第 3 条）。

### 其他

| 项 | 数值 | 通过 |
|---|---|---|
| 监听：solo + PFL（推子前、不受 −6 dB）/ AFL（推子后）/ 取消独听按路由；Master 不受独听影响 | 各 ±0.3 dB | ✅ |
| 每路参数 / 总线：+6 dB 推子、全左声像、Master −12 dB / 静音、Bus A 独立、输入静音 | | ✅ |
| 延迟补偿 120 ms 经 `setInputSettings` 命令：click 晚 120.00 ms，改回 0 复原；PTS 不变 | ±0.05 ms | ✅ |
| 对齐：年龄 700–960 帧（P 256）、对齐延迟 = 2048 − 年龄；P 1024 的路年龄多 ≥ 300 帧，两路都回到整秒；`alignmentFrames = 512` 时 residual > 150 帧并如实晚 residual | | ✅ |
| 对齐前静音：前 ≥ 2 块为 0，第一块非硬起（3 ms 平滑），稳态 0.5 × 0.707 | | ✅ |
| 摘除：第一块内淡到 17%，第 3 块 < 1%，detach 后 0；`removeInput` 命令同样摘音频；槽位释放 | | ✅ |
| 消费者：同一来源两个消费者共享一个 tap、样本与 PTS 完全相同；没人要了摘 tap；未注册输入不能当 ISO 来源；重复注册报错 | | ✅ |
| 实时线程违规（W1-D 的守卫）：所有实时用例 0；`check-rt-symbols` 绿（集成层没有实时代码） | 0 | ✅ |

## 3. 没做的和原因

**所有需要别的会话 / 用户决定的修改汇总在一张单子里：`reports/issues/W2E-g3-pending-changes-checklist.md`（接线、契约提案、退回 W1-D / W1-E / W1-A 的问题、W2-E 自己等决定后的跟改、环境），验收时按它逐条定。** 下面是明细。


- **headless / App 的接线没进仓库**：`Tools/switcher-headless/` 是 W2-C / 检查点的目录。补丁（119 行 diff，`AudioPump.swift` 删掉）和步骤在 `reports/issues/W2E-g3-headless-audio-engine-wiring.md`，G3 合并时套上即可；本报告的文件级数字全部来自打了这个补丁的副本。
- **表读数进 Stats**：契约 `Stats.audio` 只有 dropouts / underruns，提案 004 待批；表和不连续计数现在在 `AudioEngineStatus`。
- **frameprobe / TestKit 里的不连续检测器**：不是本会话目录，检测器在集成层，文件级分析用 scratchpad 探针 `a1check`（见 §2 A1）。
- **A5 实测**：BLOCKED-硬件（无回环线）；脚本已写。
- **8 小时 A3**：按 prompt 放 W4-A；这里 1 小时真设备 + 10 分钟 +30 ppm 合成设备时间线。
- **视频 ISO 的 A4**：每路视频 ISO 是 W3-C 的；A4 这里是 4 个文件的 ISO 音轨对齐。
- **效果链参数（`BusState.effects` 自由 JSON → AU 参数）**：prompt 没列；W3-E / 后续。
- **每路 AFV 开关**：契约只有全局 `AudioState.afv`（W1-D 报告 §4 第 4 条同问），按全局做：开 = 只有 PGM（转场中 PGM + PVW 交叉）可闻，叠加通道不门控。
- **输入侧的重采样 / 声道映射**：W2-A 的输入写 48 kHz 环即可，集成层不管。

## 4. 对契约的疑问

1. **对齐延迟是不是应该进契约 / Show**：`alignmentFrames`（默认 2048 = 42.67 ms）决定了"节目音频相对采集晚多少"，扬声器监听与 PGM 画面的对时也靠它（视频内部 ≈ 3 帧 50 ms，两边同量级）。
   现在是 `AudioEngineConfiguration` 的一项，Show 里没有；如果用户要按场合改（低延迟监听 vs 大块生产者），需要进 `AudioState` 或 Show 的音频设置（提案）。
2. **`Stats.audio` 加表读数 / 不连续**：提案 004。
3. **A5 与对齐的矛盾**：W1-D 的延迟线在耳机送出之前，对齐延迟一并进了耳机；要同时满足 A5（≤ 20 ms）与节目对齐，耳机分支要能绕过延迟线（W1-D C 侧改动，问题单 `W2E-w1-audio-*` 第 4 条），
   或者由混音器按"目标年龄"就绪（同单第 3 条）让对齐延迟线归零。请拍板要不要把这两条交给 W1-D。
4. **ISO 音轨与 AFV**：输入 tap 在 AFV 增益之后，AFV 开着时非 PGM 路的 ISO 静音。ISO 应该录推子前还是推子后（含用户增益 / 静音）？我认为推子后但不含 AFV 门控——需要 W1-D 加"推子后、AFV 前"的 tap 点。
5. **`AudioBlockConsumer` 升契约（001 B）**：批了之后集成层的 `AudioBlockConsuming` 改成 typealias，组装方少写一行。
6. **FTB 是否淡出 Bus A / B**：现在只淡 Master（prompt 原话），A / B 送外部的话 FTB 时不黑不静，按需再说。
7. **录制器的停止边界**：W1-E `stop(atTick:)` 只能在到达边界之后调，之前到的越界块已经写进去（音轨多 50–150 ms，E5 的 20 ms 会不过）；建议给"预告停止拍"入口（问题单 `W2E-w1-outputs-*` 第 3 条）。

## 5. 下一个会话需要知道的坑

- **混音时间 vs 内容时间**：块 T 里流过的是 T − 对齐延迟 采集的内容，PTS 也是它。任何"要与画面同刻"的音频动作（AFV 淡变、Cut、T-bar、FTB）都要在 T = 拍点 + 对齐延迟 处应用；
  第一版没加这个偏移，逐块电平用例里音频转场领先画面 42.7 ms 才发现。开关类（AFV on/off、静音、增益）不需要。
- **年龄有随机相位**：就绪年龄 = 703 + [0, 256) 帧（P 256），每次运行不同、每次重就绪不同——所以不能预算，只能就绪后读 `ageSetpoint` 再设延迟线；控制线程每 8 ms 看一次统计。
  离线搭台喂源要喂到块首（真源在一块采完才交），喂到块尾会把年龄少算一块（447 vs 703）。
- **`HostClockResampler` 不要用 FIFO 占用做反馈**：回调 API 的取样按 chunk 走，占用是幅度 = chunk 的锯齿，PI 会追锯齿相位（实测积分绕到 100 ppm）。纯前馈够了：stamp 精度 µs 级，
  8 块就有 ~1 ppm、2 s 窗 0.02 ppm；第一次测到之前不产出（否则比率 1.0 那段的位置误差会冻结进去，−50 ppm × 2 s = 5 帧）。前 10 分钟累计平均、之后 τ = 10 min 指数窗跟晶振温漂。
- **libsamplerate 回调不能返回 0**（W1-D 也写过）：输出计数要比块尾留 半长 + 2 chunk 的余量，否则库要数据时 FIFO 空。
- **录制器封口**：见 `W2E-w1-outputs-recorder-drift-check-before-stop.md`——边界之后还在送块会拖死（先 `removeConsumer` 再 `stop(atTick:)`），越界块会多录 50–150 ms。
- **不连续检测的平台启发式在 Master 里靠不住**：单声道 click 居中声像后 0.707，再叠别路 ±0.14 就跌破电平；正式口径用已知 click 位置排除（`feed(..., isExcluded:)` / `analyze`）。
- **`TimedCapture` 一类按 PTS 排的采集：窗口要按 PTS 前沿（= 设备块首 − 对齐延迟）算**，按设备时间取窗会取到还没送到的地方（读到 0）。
- **W1-D 淡变的两个小尾巴**：时长整块量化（−20 dB 以下 0.5–0.9 dB）、结束那块 afv 被最后一个曲线样本覆盖（Cut 后 −44 dB、τ 3 ms 的尾巴）；判据里已按实际情况留出。
- **同名测试类会一起被 `--filter` 选中**：`RealtimeTests` 在 SwitcherAudioTests 也有一个（W1-D 的 A7 10 分钟），我的改名为 `IntegrationRealtimeTests`。
- **真设备用例会把系统默认输出设备设成 48 kHz、buffer 256**（W1-D 的 `AudioOutputDevice.start`），`BusChannelMap(master: nil)` 让它不出声；跑的时候别改默认设备。
- **Swift 6：`Task { }` 在 main.swift 顶层继承 MainActor**，主线程再 `sem.wait()` 就死锁（a1check 撞过）；用 `Task.detached` + `dispatchMain()`。
- **XCTest 里 `defer { Task { await rig.shutdown() } }` 过不了 sending 检查**，直接在末尾 `await rig.shutdown()`。
- 集成层每个 `AudioEngine`：一个 `AudioMixer`（W1-D 说 ~26 MB）+ 每个消费者来源一个 tap（64 块）+ 重采样器 FIFO；控制线程 + 泵线程各一条普通线程（userInteractive / userInitiated）。
- **录制音轨比名义时长多 54–102 ms**（10 min 空设备 +4910 样本、真设备 +1681、60 min +3519）：最后一拍到 `stop(atTick:)` 之间到达的越界块被 W1-E 的录制器照常写进去（问题单第 2 点）；
  G2 的 +3745 / +5306 同源。不影响 A2 / A3（偏移恒定），E5 的"两轨差 ≤ 20 ms"会不过，要 W1-E 改。
- **2026-09-15 14:43 本机 Xcode 被换成 27.0（27A266a）**，之后 `swift` / `xcodebuild` / Xcode 的 `python3` 都提示要 `sudo xcodebuild -license`。本报告的所有构建 / 测试都在换之前用 Xcode 26.6 / Swift 6.3.3 跑完
  （SwitcherAudio 全量 14:34–14:39 结束）；G3 合并前请先接受许可并确认工具链版本（CLAUDE.md / 记忆里写的是 26.6）。临时绕法：`DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3` 能跑脚本。
- 长跑素材（不入库）：`scratchpad/run-null10|real10|real60|a4/`（out.mov、stats.jsonl、av.md / av.json、log.txt），scratchpad 在 `/private/tmp/claude-501/.../785c488b-.../scratchpad/`，会话结束可能被清；
  `a2-headless/`（打补丁的 headless 副本）与 `a1check/`（文件级不连续探针，40 行）也在那里，G3 需要的话按问题单里的补丁重建。
