# W1-D2 混音器收口 / 就绪年龄 / 耳机与 ISO tap 点 —— 报告（分支 w1-audio-2）

日期 2026-09-18 → 19。机器 Apple M5 Max / macOS 26.6.2 / Xcode 27.0 (27A266a) / Swift 6.4，电源适配器，室温，用户桌面在用。
worktree `.claude/worktrees/mixer-tap-points-439a11`，分支 `w1-audio-2`（harness 建的 `claude/mixer-tap-points-439a11` 改名），从 main 2fdf52d（P2 合入后）开。
提交：`git log main..w1-audio-2`（小步；报告在最后一个）。`make lint` 绿（禁词 / 版本 / 依赖方向 / 归属 15 个文件 / check-rt-symbols debug + release）。
只动了归属表允许的五个目录：`CSwitcherAudioRT/`、`SwitcherAudio/`、`Tests/SwitcherAudioTests/`、`Integration/`、`Tests/IntegrationTests/`；`CSwitcherAudioHost/` 一行没动
（中途为临时缓冲改过它，check-ownership 拦下后改成不用临时缓冲的写法收回，见 §5）。

## 1. 做了什么

W2-E 退回单 3-1…3-5（`reports/issues/W2E-w1-audio-crossfade-tail-block-duration-monitor.md`）五条全部落地，C 侧改的命令：

| # | 交付 | C 侧（`CSwitcherAudioRT`） | Swift / 集成层 |
|---|---|---|---|
| 1 | 淡变收帧数 | `SW_CMD_CROSSFADE.i2` 改成帧数（≥ 1；原来是块）；`sw_xfade_block` 按帧算 p，走满处写精确 0 / 1（`cosf(π/2) = −4.4e-8` 不是 0） | `AudioMixer.crossfade(from:to:durationFrames:startHostTime:)`；`durationBlocks:` 留作便利写法 = 块 × blockFrames（逐样本一致，有用例钉住）。集成层 auto 转场时长按帧：30 拍 @60 = 24000、@59.94 = 24024；Cut = cutFadeBlocks × blockFrames |
| 2 | 终值不被覆盖 | `sw_xfade_block` 不再直接写 afv，改报 `ended`；`sw_mix_block` 把终值（每路一个 uint8：0 无 / 1 → 0.0 / 2 → 1.0）交给 `sw_process_input`，在推子之后钉 `afv = afv_target = 终值` | — |
| 3 | 就绪目标年龄 | `SW_CMD_ATTACH_INPUT.i2` = 目标年龄（帧，0 = 旧规则）。`sw_slot_try_prime`：数据够旧门限时，目标年龄模式沿 stamps 从最新往回找 `host_time − 目标年龄` 那一刻采到的帧（`sw_slot_find_target_start`），从它起消费；设定点仍按最新 stamp 算年龄 → = 目标 ± 半帧。规则：目标 < 安全下限 back（= target + P/2 + hf + chunk/2，旧规则的回退量）直接走旧规则；目标那一帧之后的数据 < back（相位不利）或目标时刻落在 stamps 的时间空洞里（源停过又回来）就等，等满 目标/块 + 16 块仍不行退回旧规则；等的期间环若快被就绪前的数据塞满（停摆后涌入的陈旧块）先把 read_index 推到 `write − (容量 − 2P)` 腾位置，否则生产者写不进、永远就绪不了 | `AudioMixer.attach(..., targetAgeFrames:)`、`deterministicAgeFrames(targetFrames:producerBlockFrames:resampled:)` = back + P（任何相位都能命中的最小值；P 256 默认 959 帧 = 20 ms）。集成层 `AudioInputHints.targetAgeFrames`（nil = min(deterministic + 真设备的输出提前量 buffer + 安全偏移, alignmentFrames)，0 = 旧规则）；`maintainAlignment` 公式不变（延迟线 = alignment − 年龄），只是年龄现在是确定值，延迟线也是（离线 / 空设备 2048 − 959 = 1089，内置扬声器 2048 − 1263 = 785）；`AudioEngineStatus.InputStatus.targetAgeFrames` |
| 4 | 耳机取延迟线前 / 后 | 新命令 `SW_CMD_MONITOR_POINT`（`sw_monitor_point`：PRE = 0 默认、POST = 1，calloc 的 0 就是默认，Host 不用改）。`sw_process_input` 里推子（增益 / 静音一阶平滑 + AFV 曲线或平滑 + 声像插值）对延迟线后的信号算 post，耳机取延迟线前时从同一初值重放同一条递推（逐位相同）乘到 `resampled` 上；PFL 取延迟线前的原始信号 | `AudioMixer.setMonitorPoint(_:)`、`MonitorPoint`；集成层 `AudioEngineConfiguration.monitorPoint` 默认 `.preDelayLine`（耳机不走对齐延迟线也不走用户延迟补偿），`AudioEngineStatus.monitorPoint`；A5 脚本改回默认对齐（只留 buffer 128 + 就绪目标 1 块） |
| 5 | ISO tap 来源 | tap 来源加 `SW_TAP_INPUT_PRE_AFV_BASE (64) + 槽位` = 推子后、AFV 前（含增益 / 静音 / 声像 / 延迟线）；`SW_TAP_INPUT_BASE (16) + 槽位` 仍是含 AFV 的节目信号。ISO 信号写在本块已经用完的 `post` 上推出去，不另开缓冲 | `TapSource.inputPreAFV(slot:)`；集成层 `AudioTapSource.input(number:)` 改成这个口径（headless 的 `--iso-audio` 不用改就换了来源），新增 `.inputProgram(number:)` 给 AFV 用例量含 AFV 的信号 |
| 附 | 声像两端精确 | `sw_pan_coeffs` pan = ±1 时直接给 0 / 1：全右的信号原来以 cosf(π/2) = −147 dB 漏进左声道，"Cut 后严格 0" 的用例撞到 | — |
| 附 | 每块顺序 | 独听状态先扫一遍，每路输入在 `sw_process_input` 里一次做完：取样 → 延迟线 → 推子 → 送 Master / A / B → 送耳机 → 推两种 tap；原来的第二个循环没了 | — |

代码量：C +180 / −70 行（`sw_mix.c`、两个头），Swift 控制面 +40，集成层 +45 / −15，测试 +560（新文件 `MixerTapAndAgeTests.swift` 10 个用例；改 AFV / Alignment / Monitoring / Realtime 四个集成用例文件）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherAudio`（全包）；`--filter MixerTapAndAgeTests`（本会话的混音器级用例，4 s）。
真设备：`SW_AUDIO_A7_DEVICE_SECONDS=60 swift test --filter testA7_realDevice`；`SW_AUDIO_REAL_DEVICE=1 swift test --filter testA2A3_realDevice`。

### AFV Fade 30 拍（阈值：逐块电平与 cos / sin 曲线误差 ≤ 0.5 dB，判到 −40 dB；Cut 之后 from 路下一块起严格 0）

| 项 | W2-E（前） | 本会话（后） | 通过 |
|---|---|---|---|
| 时长 | 94 块 = 24064 帧 = 501.33 ms（+0.27%） | 24000 帧 = 500.00 ms；59.94 时 24024 = 500.5 ms | ✅ |
| 逐块 RMS vs 曲线，期望增益 ≥ −20 dB 的 173 块 | 最大 0.361 dB | **0.113 dB** | ✅ |
| 同上，−20…−40 dB 的尾巴（9 块） | 最大 0.843 dB（只能判到 −20 dB） | **0.109 dB**，判到 −40 dB 也 ≤ 0.5 | ✅ |
| 同一段尾巴按 W2-E 的"块中心"模型算（用例里顺手打印作对照） | 0.843 dB | 0.105 dB | — |
| 混音器级：s0 + k 处 = cos / sin(π/2·k/24000)，k 判到 23999（from 增益 −84 dB） | — | 误差 ≤ 2e-6（float32） | ✅ |
| 终点：s0 + dur 起 from 严格 0、to 满，含终点块剩下的 156 个样本和后面 11 块 | 终值被最后一个曲线样本覆盖：Cut 后块 1 RMS 7.8e-4、块 2 1.4e-4、块 3 2.3e-5 | **全部严格 0（`XCTAssertEqual(x, 0)`）** | ✅ |
| Cut（1 块短淡从块中间起）：淡完之后每一块 RMS | ≤ 1e-3 | **严格 0**（集成层：含 t_s 块的再下一块起 `rms1 == 0`） | ✅ |
| 起点、与视频对照（第 s+1 拍）、等幅 Master ±0.5 dB、T-bar、FTB、AFV 开关 | 通过 | 通过（判据未动） | ✅ |

两点说明。(1) 尾巴的 0.843 → 0.105 dB 证实 W2-E 的诊断：就是整块量化（+0.27%）经 tan(θ)·dθ 放大（被比较的最低一块 g ≈ 0.025、θ = 1.546，tan θ ≈ 40，dθ = 0.27% × θ = 0.0041 → 16% ≈ 1.3 dB 量级）。
(2) 用例的期望值从"块中心的 cos / sin"改成了对块积分的曲线（cos² 的均值 = 1/2 + (sin πp₂ − sin πp₁)/(2π(p₂ − p₁))，sin² 反号）：越靠近 −40 dB，一块之内增益变化越大（256/24000 帧 = 0.0168 rad），
块 RMS 对应的是 √(mean g²) 不是 g(中心)，解析算 g_c = 0.01 处两者差 +0.9 dB、0.02 处 +0.25 dB；现在被比较的块最低到 0.025（循环不含淡变的最后一块），两种模型只差 0.004 dB，
但把判据推到 −40 dB 就必须用积分模型，否则模型自己的误差会吃掉阈值。改的是模型不是阈值（0.5 dB 不动），判到 −40 dB 的块 9 个。

### 就绪年龄（阈值：= 目标 ± 1 块，10 次重就绪；对齐延迟线残差 ≤ 1 块）

| 项 | 前 | 后 | 通过 |
|---|---|---|---|
| 混音器级：目标 1200 帧，源相对块网格的相位 0 / 25 / … / 225 帧共 10 种 | 旧规则：447.0 / 678.0 / 653.0 / … / 478.0（极差 231 ≈ 一个生产者块；离线搭台喂到块尾所以是 447 + 相位） | **10 次全部 1200.00**（极差 0；小数部分 < 1e-4） | ✅（± 1 块 → 实测 ± 0 帧） |
| 混音器级：源停 2 s 再回来 × 3 轮（涌入 375 块陈旧数据、环塞满） | 旧规则会拿陈旧数据就绪，设定点 80319 帧（1.67 s），之后估计器错 5 分钟才把环撑爆 | 每轮重新就绪年龄 = 1200.00，之后无欠载、有声；涌入的块按生产者侧 overruns 计 | ✅ |
| 混音器级：目标 300 < 下限 703 | — | 按下限就绪（603，含相位），无欠载；目标 = `deterministicAgeFrames` 959 时精确 959.0 | ✅ |
| 集成层：10 次重新注册（相位各不同），默认提示 P 256 | 年龄 703 + [0, 256)（W2-E 实测 700–960），延迟线每次不同 | **年龄 959.00 × 10，延迟线 1089 × 10，残差 年龄 + 延迟线 − 2048 = 0** | ✅ |
| 集成层：P 1024 的输入（确定年龄 2879 > 对齐 2048，目标压到 2048） | 年龄 1855 + [0, 1024)，残差靠相位碰运气 | **年龄 2048.0、延迟线 0、残差 0**（混音器等相位转到"最新数据够新"的那块，最多等 4 块） | ✅ |
| 集成层：对齐延迟 512 < 下限 | 残差 > 150、click 晚残差 | 同（目标 512 < 703 直接走旧规则，不多等） | ✅ |
| 空设备实时 30 s（A1/A2 用例顺带）：两路的年龄 / 延迟线 | 随机 | 959 / 1089 两路相同；click 均值 −0.010 ms | ✅ |
| 真设备（内置扬声器，`SW_AUDIO_REAL_DEVICE=1`）60 s + 12 s × 3：年龄 / 延迟线 | 第一版（目标 959 没算输出提前量）退回旧规则：1142 = 703 + 304 + 相位 | 目标 1263 = 959 + 输出提前量 304（buffer 256 + 安全偏移 48）：**1262 / 1263 / 1263 / 1262**，延迟线 785；A2 均值 0.011 / 0.002 / −0.003 / 0.008 ms，最大 0.031 | ✅ |

### 耳机与 A5

| 项 | 数值 | 通过 |
|---|---|---|
| 混音器级：延迟补偿 100 ms 的输入路由 Master + 耳机，默认（延迟线前）耳机 click 比 Master 早 4800 样本；`.postDelayLine` 差 0；独听 PFL / AFL 同样 | 4800 / 0 | ✅ |
| 混音器级：监听点不改电平（AFL 推子后 −6 dB 含声像、PFL 推子前满），延迟 37 ms 时 | ±0.05 dB | ✅ |
| 集成层：默认配置下耳机流里的 click 比 Master 早 对齐延迟线（1089 帧 = 22.7 ms），Master 仍回到整秒；`.postDelayLine` 同刻 | +22.69 ms / 0 ±0.05 | ✅ |
| A5 `testA5_monitorLatency_loopback`（默认对齐 2048，buffer 128，就绪目标 1 块） | **BLOCKED-硬件**：没有音频接口回环线。脚本已改回默认对齐并断言 `alignmentFrames == 2048`，设 `SW_AUDIO_LOOPBACK_OUTPUT` / `SW_AUDIO_LOOPBACK_INPUT` + 麦克风 TCC 后跑 | ⏸ |

A5 预算（解锁后该看到的数）：环年龄 = 目标 128 + P/2 64 + hf 47 + chunk/2 16 + P 128 + 输出提前量（buffer 128 + 安全偏移，内置扬声器 176）= 559 帧 = 11.6 ms（确定值，
其中提前量那一段就是"回调到呈现"的物理时间，不是白等；想再低可在 `AudioInputHints.targetAgeFrames` 指定，下限 = back 255 + 提前量 + 相位）。
一路麦克风从入口到耳机出口 = 输入 buffer + 输入安全偏移 + 环年龄里提前量之外的部分（383 帧 = 8 ms）+ 输出 buffer + 安全偏移 + 输出延迟 ≈ 2.7 + 1 + 8 + 2.7 + 1 + 1.3 ≈ 17 ms（buffer 128）；
≤ 20 能过，目标 12 要 buffer 64 或把就绪目标压到半块。对齐延迟线（默认 1089 帧）与用户延迟补偿都不在耳机通路里了，这是本会话之前做不到的（W2-E 只能把对齐延迟设 0）。

### ISO tap（AFV 开、非 PGM 路的 ISO 有信号，含推子 / 静音）

| 项 | 前 | 后 | 通过 |
|---|---|---|---|
| 混音器级：AFV 增益 0 的路，`.input` tap 全 0；`.inputPreAFV` = 推子 −6 dB × 全左（−6.00 dB / 0）；静音后 0；块带 host time / 序号 | — | 如期 | ✅ |
| 混音器级：淡变进行中 AFV 前的 tap 恒定 1.0（±1e-6），含 AFV 的 tap 跟曲线 | — | 如期 | ✅ |
| 集成层：AFV 开、PGM 1、输入 2 推子 −6 dB：ISO(2) −6.0 dB、program(2) 0、ISO(1) 0 dB；静音后 ISO(2) < 1e-4；Cut 到 2 后 ISO 不变、program 跟门控；表读数仍是含 AFV 口径 | 非 PGM 的 ISO 静音 | 如期（±0.3 dB） | ✅ |
| A4 四路 ISO tap 同一事件极差 | 0.04 ms | 0.042 ms | ✅ |

### A7 实时线程违规（阈值 0，硬性）

| 项 | 数值 | 通过 |
|---|---|---|
| W1-D 离线 10 分钟标准负载（8 路 ±100 ppm、全效果、4 个 tap、运行期改增益 + 淡变） | 违规 0、实时区分配 0、欠载 0、112 500 块、墙钟 67.4 / 69.3 s（8.7–8.9× 实时，跑了两遍）、最长块 1658 / 2697 µs（预算 5333；两遍系统负载不同，都是 libebur128 每秒的短期响度求和尖峰） | ✅ |
| 真设备 1 分钟（`SW_AUDIO_A7_DEVICE_SECONDS=60`，内置扬声器 Master 静音，4 路 + 全效果 + tap + 每秒改增益 / 淡变） | 违规 0、实时区分配 0、dropouts 0、underruns 0、11 345 块 | ✅ |
| `scripts/check-rt-symbols.sh` debug / release | 4 个目标文件全在审计清单内 | ✅ |
| 本会话所有离线 / 空设备用例的 `realtimeViolations` | 0 | ✅ |

一个坑（§5 有）：第一版 -O2 把两个新写的常量填充循环编译成了 `memset_pattern16`，check-rt-symbols 红；改写法后绿。

### 全包回归

`swift test --package-path Packages/SwitcherAudio`（最后一个提交上跑）：SwitcherAudioTests 62 个（W1-D 52 + 本会话 10；2 个按环境跳过：默认设备变更、麦克风），
IntegrationTests 39 个（W2-E 35 + 本会话 4；3 个按环境跳过：真设备 A2/A3、A3 长跑、A5），**0 失败**，194 + 93 s。
W1-D 的 ResampleTests（±100 ppm 5 min、其他生产者块、零漂移、停摆恢复）、MeterTests、DeviceTests、IOProcTests、RingTests、EffectChainTests 判据没动，全过。
`make build-packages build-tools`：六个包 + 两个工具编译通过（headless 用的 `.input(number:)` 换了 ISO 口径不用改代码）。

### 真设备（`SW_AUDIO_REAL_DEVICE=1`，内置扬声器 Master 静音，A2/A3 用例）

60 s：click 59 个，均值 0.011 ms（音频超前为正），σ 0.006，最大 |0.031|，斜率 × 8 h = −4.04 ms（60 s 拟合的噪声，W2-E 的 60 min 是 0.20 ms）；设备 −2.83 ppm、重采样比 1.0000028、挨饿 0；
dropouts 0、underruns 0、不连续 0、违规 0；回调 11 295、抖动 max 0.031 ms、重建 0；输入 1 年龄 1262、延迟线 785。12 s × 3 复跑年龄 1263 / 1263 / 1262（§2 就绪年龄表）。

## 3. 没做的和原因

- **效果链、每路 AFV 开关**：prompt 明说不做。
- **A5 实测**：BLOCKED-硬件（无回环线），脚本与预算见 §2。
- **`AudioInputHints.targetAgeFrames` 没进契约 / Show**：是集成层的注册提示，不是节目状态；对齐延迟是否进 Show 仍是 W2-E §4 第 1 条的悬案。
- **就绪目标年龄的默认值取"任何相位都能命中的最小值"（back + P = 959；真设备再加输出提前量 → 1263）而不是旧规则的平均（831 / 1135）**：多 2.7 ms 环年龄，换来年龄与相位无关；对节目通路总延迟没影响（总是 alignment），只影响耳机通路（真设备 26 ms vs 24 ms）。想要更低的监听延迟按 A5 脚本那样给 hints（目标 1 块、buffer 128 → 559 帧 = 11.6 ms）。
- **check-rt-symbols 的允许清单没加 `memset_pattern16`**：`scripts/` 不在本会话目录；改代码写法绕开了（§5）。
- **`.input(number:)` 语义变了没有兼容别名**：headless 的 ISO 录制器正是要这个新口径；AFV 用例改用 `.inputProgram`。App 没有用它。

## 4. 对契约的疑问

1. **ISO 音轨的口径**：本会话按 W2-E §4 第 4 条的建议做成"推子后、AFV 前"（含用户增益 / 静音 / 声像 / 延迟补偿 / 对齐延迟）。如果产品上 ISO 应该是"推子前"（纯净素材），C 侧再加一个来源即可（`delayed` 已经在），请拍板。
2. **监听点是否进 `AudioState` / Show**：现在是 `AudioEngineConfiguration.monitorPoint`（默认延迟线前）。它影响"耳机里听到的和画面对不对得上"，与对齐延迟一样是场合相关的设置；同 W2-E §4 第 1 条一起决定。
3. **就绪年龄目标是否要从 Show 里的对齐延迟推**：集成层已做成 min(确定最小值, alignmentFrames)，对齐延迟进 Show 之后自然跟着变，不需要额外字段。
4. 没有改任何 SwitcherContracts 类型、JSON 字段或测试图案。

## 5. 下一个会话需要知道的坑

- **`cosf(π/2)` 不是 0，`sinf(π)` 也不是 0**：任何"严格为 0"的路径都要在边界显式写 0 / 1（淡变走满、声像两端都改了）。旧的 −147 dB 漏音听不见，但 `XCTAssertEqual(x, 0)` 会抓到。
- **-O2 会把浮点常量填充循环认成 `memset_pattern16`**（Apple libc，不在 check-rt-symbols 的允许清单里）：`for (i) a[i] = −1.0f` 这种写法在 RT target 里不能用；字节填充（uint8）编译成 `bzero`（清单里有），或者让循环有数据依赖。本会话两处：淡变起点前的样本改成按 k = 0 走同一条 cos / sin，走满标记改 uint8。
- **"逐块 RMS 与曲线比"要对块积分**：cos / sin 在 −40 dB 附近一块之内变化 10%+，取块中心值在 g = 0.01 处本身就有 ~0.9 dB 误差（§2 有解析式；现在比较的块最低到 0.025，两种模型只差 0.004 dB）。以后判更低的电平用同样的模型。
- **目标年龄模式的就绪可能比旧规则晚**：要等 `host_time − 目标年龄` 那一帧存在（源开始后至少 目标年龄 那么久，959 帧 = 20 ms），P > 块的源还要等相位转到能命中的块（P 1024 最多 4 块）；源停过又回来时等目标时刻走进当前数据（≤ 目标年龄）。集成层对齐前是静音的，这段时间听不见差别；用例里 `run(blocks: 40)` 够。
- **真设备的混音块 host time 是呈现时刻，比回调早 buffer + 安全偏移**（内置扬声器 304 帧）：任何"相对混音时间线的年龄"都含这一段。目标年龄不加它就命中不了（第一版真设备实测退回旧规则 1142），集成层现在在 `registerInput` 时按输出设备算进去（`outputLeadFrames`）；默认设备变了（跟随 / 重建）提前量可能变，已注册的输入若因此命中不了会退回旧规则，对齐仍由延迟线兜住，只是年龄又带相位。空设备 / 离线的时间线就是"现在"。
- **停摆后涌入陈旧数据（OfflineAudioSource 的 `deliver` 会把停摆期间的块一次全写）**：旧规则会拿陈旧数据就绪，设定点算出 1.67 s 的年龄，估计器随后以 0.1% 的比率慢慢把环撑满（5 分钟后溢出）；`testResample_sourceStallRecovers` 只跑 10 s 所以没露。目标年龄模式在这条路上会等、会腾位置，重新就绪的年龄仍是目标。真设备重连不会涌入陈旧块，NDI 的乱序 / 迟到包会（几十 ms 量级）。
- **耳机通路的推子是"重放"同一条递推**，不是共用缓冲：改推子逻辑时两处要一起改（`sw_process_input` 第 5 步与第 7 步），否则耳机与节目的增益会对不上。ISO tap 只重放增益 / 声像，不放 AFV。
- **`post` 在推完含 AFV 的 tap 之后被 ISO 信号覆盖**：`sw_process_input` 里任何要读 post 的新逻辑都要放在第 8 步之前。
- **CSwitcherAudioHost 不在 W1-D2 的目录里**：需要新缓冲 / 新 Host 函数的改动得写提案或退回 W1-D；本会话所有新逻辑都做在 RT 与 Swift 侧。`sw_slot_back_frames`（RT）与 `AudioMixer.deterministicAgeFrames`（Swift）是同一条公式的两份拷贝，`MixerTapAndAgeTests.testAlignment_targetAge_belowSafeMinimumIsClampedWithoutUnderrun` 用"按它就绪年龄精确命中"钉住一致。
- **同名的 `RealtimeTests` 类两个 target 都有**（W1-D 与 W2-E 的 `IntegrationRealtimeTests`），`--filter RealtimeTests` 会同时选中。
- 真设备用例仍会把系统默认输出设备设成 48 kHz / buffer 256（W1-D `AudioOutputDevice.start`）；跑的时候别改默认设备。
