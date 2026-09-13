# W1-D 音频引擎 —— 报告（分支 w1-audio）

日期 2026-09-14。机器 Apple M5 Max / macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3 / Apple clang 21.0.0，电源适配器，室温。
worktree `.claude/worktrees/w1-audio-612658`，从 `main`（bdab613）开；分支已按 prompt 改名为 `w1-audio`。
提交：见 `git log main..w1-audio`（audio × 6、reports × 1）。

## 1. 做了什么

全部在 `Packages/SwitcherAudio/`（+ `THIRD_PARTY/`、`scripts/check-rt-symbols.sh`，都在 OWNERSHIP 允许范围内，`make lint` 绿）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 第三方内嵌 | `Sources/CLibSamplerate/`（libsamplerate 0.2.2，BSD-2）、`Sources/CLibEBUR128/`（libebur128 1.2.6，MIT）；许可证与来源 / SHA-256 在 `THIRD_PARTY/` | 上游源文件一行未改；libsamplerate 的 `config.h` 是本仓库手写的 |
| 2 AudioRing | `CSwitcherAudioRT/sw_audio_ring_rt.c`（write / read / skip / stamps，SPSC 内存序按契约：stamp 先于 write_index 发布）+ `CSwitcherAudioHost/sw_audio_ring_host.c`（posix_memalign 64 字节）+ `SwitcherAudio/AudioRingImpl.swift`（`CAudioRing: AudioRing`） | 容量 / stamp 数向上取 2 的幂 |
| 3 混音核心 | `CSwitcherAudioRT/sw_mix.c`：`sw_mix_block(ctx, out, frames, host_time)`。命令 → 每路（取样 + 异步重采样 → 延迟线 0–500 ms → 增益 / 静音 / AFV / 声像 → 送 Master / A / B / HP）→ 每条总线（EQ → Dynamics → Limiter 的 AudioUnitRender → 总线增益 / 静音 → 表 → 写输出 → 消费者队列） | 块大小 = 设备 buffer size（≤ 4096），默认 256；`out` 是 8 个平面指针 |
| 4 速率估计器 | `sw_mix.c` 顶部注释 + `sw_rate_step`；参数 `sw_rate_params`（Swift `RateEstimatorParameters`） | 见 §6 |
| 5 设备层 | `SwitcherAudio/AudioOutputDevice.swift`（`AudioOutputDevice` / `AudioInputDevice` / `NullOutputDevice`）、`AudioDevices.swift`（`AudioHAL` 枚举与属性）、IOProc 在 `CSwitcherAudioRT/sw_device_ioproc.c` | AudioDeviceCreateIOProcID；聚合设备 = 同一个 IOProc 同时收输入写环；默认设备变更监听 → 停旧建新，上下文不动 |
| 6 离线工装 | `OfflineAudioDriver`（合成输出时间线，128 位整数算块时刻）、`OfflineAudioSource`（按 host time 交付、含 ±ppm 漂移）、`NullOutputDevice`（time-constraint 线程 + mach_wait_until 的假设备时钟） | 三者都跑同一个 `sw_mix_block` |
| 7 AFV | `AudioMixer.crossfade(from:to:durationBlocks:startHostTime:)`，等幅 cos / sin，起点按 startHostTime 在块内按样本定位，迟到则跳到该在的位置（终点仍与视频对齐）；另有 `setAFVGain(slot:_:)` 给 Cut 用 | 每槽位一条，新的取消旧的 |
| 8 实时机械检查 | `scripts/check-rt-symbols.sh`（nm -u 禁止清单 + 允许清单 + pragma 检查，`make lint` 自动带上）；`[[clang::nonblocking]]` + `#pragma clang diagnostic error "-Wfunction-effects"`（`sw_rt_pragma.h`，每个热路径 .c）；运行期 `sw_rt_guard`（进入 / 退出标志 + 封装断言）+ 测试里挂 libmalloc `malloc_logger` 钩子（`RealtimeGuard`） | Apple clang 21 **不支持** `-fsanitize=realtime`（"unsupported option for target arm64-apple-darwin"，探针实测），用了 prompt 的兜底方案 |
| 9 Stats / 表 | `AudioMixer.stats`（`MixerStats`，`.audio` 就是契约 `Stats.AudioCounters{dropouts, underruns}`）、`AudioMixer.meters`（`MixerMeters`：每条总线 峰值 / 真峰值 / 保持 / M / S / I / LRA，每路输入推子后峰值），seqlock 读一致快照 | dropouts = 块处理超时 + HAL overload 通知；underruns = 已就绪输入的环欠载块数 |

另外：`BusEffectChain.swift`（AU 创建 / 配格式 / 装回调 / initialize / 调参）、`LoudnessMeter`（同一算法的非实时包装，给离线分析与 5.1 用例）、`AudioMixer.apply(_ InputAudioSettings, toSlot:)`（契约参数一次落地）。

代码量：热路径 C 1070 行（sw_mix.c 840）、Host C 480、Swift 1540、测试 52 个（9 个文件）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherAudio`（debug；三个 C target 在 debug 下也 -O2，见 §5）。52 个测试全套 182 s，其中 ±100 ppm 各 5 分钟音频（40 s 墙钟 / 个）、A7 离线 10 分钟音频（66 s 墙钟）、A6 用例合计 ~31 s、真设备短跑 ~34 s。时长可用环境变量缩短：`SW_AUDIO_RESAMPLE_SECONDS`、`SW_AUDIO_A7_SECONDS`、`SW_AUDIO_A1_SECONDS`、`SW_AUDIO_A7_DEVICE_SECONDS`。
真设备长跑默认短跑（10 s），`SW_AUDIO_FULL=1` 时按 prompt 时长；下表真设备行的数字是 FULL 跑出来的（命令：`SW_AUDIO_FULL=1 swift test --filter DeviceTests`）。

### A6 表的准确度（`MeterTests`；阈值：响度 ±0.1 LU，真峰值 +0.2 / −0.4 dB，LRA ±1 LU）

| 用例 | 读数 | 标称 | 通过 |
|---|---|---|---|
| 3341-1 −23 dBFS 1 kHz 立体声 20 s | M −22.993 / S −22.993 / I −22.951 | −23.0 | ✅ |
| 3341-2 −33 dBFS | M −32.993 / S −32.993 / I −32.951 | −33.0 | ✅ |
| 3341-3 −36 (10 s) / −23 (60 s) / −36 (10 s) | I −22.971 | −23.0 | ✅ |
| 3341-4 −72 / −36 / −23 (60 s) / −36 / −72 | I −22.971 | −23.0 | ✅ |
| 3341-5 −26 (20 s) / −20 (20.1 s) / −26 (20 s) | I −22.933 | −23.0 | ✅ |
| 3341-6 5.1（L/R −28、C −24、LFE −30 不计、Ls/Rs −30）经 `LoudnessMeter` | I −23.05 / M −23.016 / S −23.016 | −23.0 | ✅ |
| 3341 真峰值 997 Hz −6.0 dBTP，相位 0° / 45° / 60° / 67.5° | −5.979 / −5.979 / −5.981 / −5.995 dBTP | −6.0 (+0.2/−0.4) | ✅ |
| prompt 指定 +0.5 dBTP 997 Hz（0° / 45°） | +0.521 / +0.521 dBTP | +0.5 (+0.2/−0.4) | ✅ |
| 0.0 dBTP、−0.5 dBTP（60°） | +0.021 / −0.481 dBTP | (+0.2/−0.4) | ✅ |
| 3342-1 −20 / −30 各 20 s | LRA 10.0 | 10 ±1 | ✅ |
| 3342-2 −20 / −15 | 5.0 | 5 ±1 | ✅ |
| 3342-3 −40 / −20 | 20.0 | 20 ±1 | ✅ |
| 3342-4 −50 / −35 (60 s) / −20 (60 s) / −35 (60 s) / −50 | 15.0 | 15 ±1 | ✅ |

I 比 M / S 差 0.05 LU 的原因：信号开头有 ~10 ms 的静音（环就绪前），第一个 400 ms 门限块少了一点能量。不是表的误差。
3341 的 7、8（节目素材）和 3342 的 5–8 需要 EBU 的 wav 文件，不在代码生成范围内，没做。

### A7 实时线程违规（`RealtimeTests` / `DeviceTests`；阈值 0，硬性）

| 项 | 数值 | 通过 |
|---|---|---|
| 机制自检：守卫区内故意 malloc / free | 钩子记到 4 次、封装记到违规 ≥ 3 | ✅（机制有效） |
| 离线 10 分钟标准负载（8 路含 +100 / −100 / +50 / −50 ppm、一路生产者块 480、四总线 EQ + Dynamics + Limiter 全开、4 个消费者队列、表、运行期改增益 / AFV 淡变） | 违规 0、实时区 malloc / free 0、欠载 0、112 500 块、墙钟 70.5 s（8.5× 实时） | ✅ |
| 真设备 1 分钟（内置扬声器，4 路输入 + 全效果 + 消费者队列 + 运行期改增益 / 淡变） | 违规 0、实时区 malloc / free 0、dropouts 0、underruns 0、11 349 块（含消费者队列弹块、每秒改增益 + AFV 淡变） | ✅ |
| `scripts/check-rt-symbols.sh`（debug 与 release 各一次） | 3 个目标文件，未定义符号全部在审计清单内：memcpy / memset 一族、libm、`AudioUnitRender`、`src_callback_read` / `src_reset`、6 个 `ebur128_*`、`mach_absolute_time`、`pthread_self`、栈保护 | ✅ |
| `[[clang::nonblocking]]` 编译期检查 | 探针：nonblocking 函数里调 malloc / pthread_mutex_lock / free 都被 -Wfunction-effects 报出；热路径每个 .c 用 pragma 升级成错误 | ✅ |

每块耗时（离线，8 路立体声 + 全效果 + 表，debug -O2）：p50 350 µs、p90 614、p99 732、p99.9 1596、max 1703 µs（预算 5333）。尖峰是 libebur128 每秒对 3 s 音频求和算短期响度（上游代码），四条总线的读数已错开 1/4 间隔更新。

### 重采样对齐（`ResampleTests`；阈值：无欠载无溢出，占用稳定在设定点 ±1 块）

| 用例 | 欠载 / 溢出 | 占用 min / mean / max（设定点 512 帧 = 2 块） | 比率终值（期望） | 收敛（±5 ppm） | 通过 |
|---|---|---|---|---|---|
| +100 ppm，5 分钟 | 0 / 0 | 384 / 514.6 / 640 帧 | 0.9999000（0.9999000） | 10.0 s | ✅ |
| −100 ppm，5 分钟 | 0 / 0 | 384 / 513.4 / 640 帧 | 1.0001000（1.0001000） | 10.0 s | ✅ |
| 0 ppm，60 s | 0 / 0 | 640 / 640 / 640 | 1.0000000 | 1.0 s | ✅ |
| +60 ppm，生产者块 128 / 480 / 1024（设定点 512 / 512 / 2048） | 0 / 0 | 448–576 / 352–832 / 1632–2464 | 0.9999401（0.9999400） | 7.0 s | ✅ |
| 源停 2 s 再回来 | 停后回到未就绪、静音，回来后重新就绪，reprimes = 2 | — | — | — | ✅ |

收敛后比率抖动 < 0.5 ppm（5 分钟内 range 宽度 1e-7）；每秒 RMS 全程 0.07743–0.07745（无缝无跳）。占用的 ±128 波动是输入块与输出块相位拍频（周期 53 s @ 100 ppm），设计如此（§6）。

### A1 音频断裂（`DeviceTests.testA1_*`；阈值 0）

| 项 | 数值 | 通过 |
|---|---|---|
| 内置扬声器 600 s（10 分钟）（Master 静音不出声；2 路实时合成输入 ±100 ppm + 全效果） | dropouts 0、underruns 0、违规 0 | ✅ |
| 实际 buffer size | 请求 256 → 实际 256（设备范围 15…4096） | — |
| 回调抖动（相邻回调间隔 − 5.333 ms） | max 0.108 ms，p99 < 0.1 ms，直方图 [112 589, 2, 0, …]（112 592 次回调里只有 2 次落在 100–200 µs 桶） | — |
| 回调提前量（inOutputTime − 进入时刻） | min 6.23 / max 6.35 ms（= buffer 256 + safety offset 48 帧） | — |
| 最长一次块处理 | 2632 µs（预算 5333） | — |
| 两路输入的比率 | 0.9998976 / 1.0000975（源 +100 / −100 ppm） | — |

A1 第一次 10 分钟跑出过 **20 次欠载**（dropouts 0）：归因是测试的喂源线程——普通线程 + debug 下 `TestSignal.render` 一块立体声要 ~1 ms，两路同时交付时一次循环 2.7 ms，超过默认设定点（2 块）在最坏相位的 ~2.4 ms 交付余量。把喂源改成 time-constraint 线程 + 查表信号后循环最大间隔 1.10 ms，第二次 10 分钟 0 欠载（上表）。这条对 W2-E 有意义：见 §5 "设定点与交付抖动"。

### AFV 曲线（`testAFV_equalPowerCrossfadeMidpointIsMinus3dB`）

| 项 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| 中点 from / to | −3.01 / −3.01 dB | 各 −3 dB | ✅ |
| 起点前 / 终点后 | from 1.0 / 0.0，to 0.0 / 1.0（1e-7 内） | 精确 | ✅ |
| 全程功率和 l² + r² | 1.0 ± 1e-3，单调 | 等幅 | ✅ |
| 起点定位 | startHostTime 落在第 5 块第 100 样本：s0−1 仍 1.0，s0+k 处 = cos(π/2·k/dur)（k = 64 / 640 / 2048，2e-6 内） | 样本级 | ✅ |

### 四总线路由矩阵（`testRouting_matrixTableDriven`，表驱动 16 路由 × 独听 × PFL/AFL = 64 组合）

| 项 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| 只送 A 不送 Master 时 Master 里的信号 | −inf dB（浮点精确 0） | ≤ −120 dB | ✅ |
| 送出的总线电平 | −20 dBFS 正弦 × 推子 −6 dB × 居中声像 −3 dB = −32.02 dB RMS，误差 < 0.05 | 正确 | ✅ |
| 独听：PFL 推子前不受 −6 dB 影响、AFL 受；有独听时未独听的路即使路由到耳机也听不到 | 一致 | — | ✅ |

### 延迟补偿（`testDelay_100msMovesClickByExactly4800Samples`）

| 项 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| 100 ms | click 晚 4800 样本（对比 0 ms 同一输入） | 正好 4800 | ✅ |
| 500 ms（上限） | 24000 | 正好 | ✅ |
| 重采样器对齐延迟（比率锁 1.0） | 0（输出样本 k = 环第 起点+k 帧，无分数延迟；libsamplerate 前补零、sinc 中心对准） | — | ✅ |

### 其他（无测试 ID）

| 测试 | 内容 | 通过 |
|---|---|---|
| `RingTests` × 7 | 布局 / 64 字节对齐；回绕往返；溢出部分写 + 计数；欠载补零 + 计数；stamps 外推首帧 host time（含跨 stamp、未来序号）；stamp 环覆盖后不外推；跨线程 SPSC 2 048 000 帧无丢无乱序 | ✅ |
| `MixerTests` 其余 | 命令确认（attach / detach 序号）；声像律（单声道等功率、立体声平衡不抬升）；增益 / 静音 / 总线静音数值与无爆音平滑；消费者队列带首样本 host time、序号连续、满了丢块计数 | ✅ |
| `EffectChainTests` × 4 | 四总线 12 个 AU 建好并 initialize；关闭 = 精确旁路；EQ +12 dB @ 1 kHz 实测 +12 ±0.5、10 kHz 处不变；压缩把 −13 dBFS 压低 > 6 dB；限幅后峰值 < 0.5 dBFS；全链 2000 块 0 违规。延迟：EQ 0、DynamicsProcessor 256、PeakLimiter 96 帧 | ✅ |
| `IOProcTests` × 3 | 直接调 `sw_device_ioproc`：交错立体声散布、非交错 4 声道（未映射通道清零）、输入收集（通道映射、stamp = inInputTime、无 HostTimeValid 时兜底并计数、环满溢出计数、摘环后不写） | ✅ |
| `DeviceTests` 其余 | 空输出设备 6 s：1126 块（期望 1125）、跳块 0、醒来最晚 0.040 ms；私有聚合设备上 IOProc 376 回调、抖动 15 µs；运行中 rebuild 到聚合设备再回来：0 dropouts、0 违规、混音不断；默认设备变更监听：把系统默认输出改成一台（非私有）聚合设备再改回，监听触发、重建 2 次、0 dropouts、上下文不动（SW_AUDIO_FULL=1 时才跑，会让系统默认输出切走约 2 s） | ✅ |

### BLOCKED

| 测试 | 状态 | 解锁条件 |
|---|---|---|
| `testDevice_inputDeviceWritesRingWithStamps`（真麦克风 IOProc → 环，stamps 速率 48 kHz ± 500 ppm） | BLOCKED-权限：测试进程（xctest）没有麦克风 TCC 权限；本会话非交互，AudioDeviceStart 等弹窗 140 s 后返回 0x10000003 | 给 xctest / Terminal 授麦克风权限后 `SW_AUDIO_INPUT_DEVICE=1 swift test --filter testDevice_input`。输入路径本身已用合成 AudioBufferList 测过（IOProcTests） |
| 3341 用例 7 / 8、3342 用例 5–8 | 需要 EBU 的节目素材文件 | 下载 EBU 测试集后经文件输入播放（W2-A 之后） |

## 3. 没做的和原因

- **FTB 同步淡出 Master**：prompt 没列，W2-E 的事（`setBusGain` + AFV 增益已够用）。
- **效果参数与契约 `EffectSlot` 的映射**（`BusState.effects` 是自由 JSON 占位）：W2-E / W3-E 定 JSON 字段后接 `EffectUnit.setParameter`。
- **PFL / AFL 之外的监听源选择**（例如耳机默认听 Master）：契约 `BusRouting.headphones` 是每路显式送耳机，照契约做；耳机听 Master 的需求由 UI 把各路 headphones 路由打开实现，或 W2-E 提案加"监听源"。
- **>2 声道输入的声道对**：环最多 8 声道，混音只取前两路（SDI 内嵌音频选对的事留给 W3-A / 提案）。
- **重采样比率限幅 ±0.1% 之外的输入**（时钟差 > 1000 ppm 或标称不是 48 kHz）：跟不住，会周期性掉出就绪再填。契约规定输入侧先转成 48 kHz 再写环，这类源不该出现。
- **`swift test -c release` 全套**：只跑了 check-rt-symbols --release 与块耗时分布；功能测试都在 debug（C 已 -O2）。

## 4. 对契约的疑问

1. **`AudioRing.read` 的 host time 语义**：契约说"按最近一条 stamp 的 host_time + 帧序号差 × 每帧 host tick 数外推"。我实现为"找 frame_index ≤ 目标的最近一条 stamp 外推"，对已被覆盖的老 stamp（超过 stamp_capacity − 1 条之前）返回 nil，对还没写到的序号用最新 stamp 向后外推。实现细节，不改签名；写在这里备查。
2. **`Stats.audio.underruns` 的口径**：我记的是"已就绪（填到设定点后）输入的环欠载块数"，源停掉（write_index 1 s 不动）后回到未就绪、不再计。理由：输入拔掉是输入的问题（`InputState.noSignal`），不该把 A1 刷成失败。若要"任何补零都算"，改一行（`sw_process_input` 里的 `if (slot->primed)`）。
3. **`InputAudioSettings.solo` = "送耳机独听"**：实现为有任一路独听时耳机总线只放独听的路（PFL 推子前 / AFL 推子后），其余总线不受影响。契约注释"独听（送耳机）"与此一致，确认一下。
4. **`AudioState.afv: Bool` 是全局开关，没有每路 AFV 标志**：本会话只提供 crossfade / setAFVGain 原语，"哪些输入受 AFV 门控"由 W2-E 按 PGM / PVW 决定。若要每路 AFV 开关进 Show，需要在 `InputAudioSettings` 加字段（提案）。
5. **块队列的多消费者**：契约只说"送 SPSC 队列给编码 / 录制消费者"。我做成最多 8 个独立 SPSC 队列（每个消费者一个，来源可选总线或某路输入推子后），满了各丢各的。若 W1-E 的编码器 / 录制器想要别的形状（例如 CMSampleBuffer），在 `AudioBlockTap` 外再包一层，不动这里。

## 5. 下一个会话需要知道的坑

- **clang 模块缓存不认 umbrella 目录里新增的头文件**：往某 C target 的 `include/` 里加了新 .h，依赖它的 target 编译时报"incomplete type"，`rm -rf .build/*/debug/ModuleCache` 就好。W1-D 撞了两次。
- **`#pragma clang diagnostic error` 必须放在所有 `#include` 之后**：放前面会和预编译模块的诊断选项冲突（"-Werror=function-effects is currently enabled, but was not in the precompiled file"）。`sw_rt_pragma.h` 因此是每个热路径 .c 的最后一个 include。
- **Swift 导入 `const float *const *` 是 `UnsafePointer<UnsafePointer<Float>?>`**：契约 `AudioRing.write(planes: UnsafePointer<UnsafePointer<Float>>)` 传给 C 前要 `assumingMemoryBound(to: UnsafePointer<Float>?.self)`（`AudioRingImpl.swift` 就是这么做的）。
- **给 CoreAudio 传 C 函数当 `AudioDeviceIOProc`**：C 声明的指针参数要标 `_Nonnull` / `_Nullable` 与 typedef 一致，否则 Swift 拒绝转换。
- **macOS 26 SDK 的 `malloc/malloc.h` 不再声明 `malloc_logger`**，但 libsystem_malloc 仍导出；`sw_mix_host.c` 自己 extern 了一份。只在测试里挂。
- **libsamplerate 的取样回调不能返回 0**：`src_callback_read` 会把 end_of_input 传给 sinc，进入终止态直到 `src_reset`。环空时交零块（`slot->zeros`）。
- **libsamplerate 取一段就整段拷进内部缓冲，只在手里 ≤ hf 帧时再取**（hf = sinc 半长：FASTEST 20、MEDIUM 47、BEST 144）。用"已交出的帧数"当环读位置会有幅度 = chunk 的锯齿；估计器用按 frames/ratio 积分的连续位置，再钳到 [copied − hf − chunk, copied − hf + 1]。
- **libebur128 只能用 EBUR128_MODE_HISTOGRAM**：非直方图模式每个门限块在 `add_frames` 里 malloc 链表节点。`add_frames_float` 要交错输入。它每秒对 3 s 音频求一次和（短期块进直方图），是每块耗时的 p99.9 尖峰来源。
- **单样本脉冲经 sinc 重采样器峰值只剩 ~0.93**（90% 带宽限带）：测峰值 / 对齐用 `.locked`（比率 1.0，仍经重采样，无对齐延迟）或 `.bypass`。直流经它的增益是 Σh = 1 − 1.2e-7（float32 一个 ulp），断言别写 1e-7。
- **AudioUnitRender 在自有线程**：输入回调是 C 函数、同一线程同步调；StreamFormat 输入输出都要设 48 k float32 非交错 2 声道；MaximumFramesPerSlice ≥ 一次 render 的帧数（这里 4096）；AudioTimeStamp 至少带 mSampleTime 并每块递增；不能与 Uninitialize / 设属性并发（拓扑只在实时线程未跑或该格关闭时改）；参数 `AudioUnitSetParameter` 可以别的线程改；首次 render 不分配（malloc 钩子实测 0）；DynamicsProcessor 有 256 帧前瞻、PeakLimiter 96 帧（`EffectUnit.latencyFrames`），W2-E 算 A/V 偏移时要加上。
- **AU 关闭 = 跳过 render**（不用 kAudioUnitProperty_BypassEffect）：重新打开时 AU 内部状态是旧的（限幅器前瞻缓冲里是关闭前的数据），前 256 帧可能有一小段过渡。
- **HAL 事实（探针 + 测试）**：内置扬声器 1 个 buffer 2 声道交错；`inOutputTime.mHostTime` 比回调进入早 buffer + safety offset（256 + 48 帧 = 6.33 ms）；buffer size 范围 15…4096；时间戳标志 0x7（Sample / Host / RateScalar 都有效）；输出 latency 60 + safety 48 帧。
- **真麦克风要 TCC**：`AudioDeviceStart` 在没权限时会等弹窗（本会话 140 s 后 0x10000003）。W2-A / W2-E 跑输入设备前先给 Terminal / Xcode 授权。
- **`.unsafeFlags(["-O2"])`（debug 下 C target 优化）对本地路径依赖是允许的**（TestKit 能解析）；但若哪天某包改成 git 依赖会炸。-O0 的 sinc + K 加权每块 2 ms（8 路），真设备 debug 跑会贴近预算，所以留着。
- **`SwitcherAudioSkeleton` 还在**（标 deprecated）：TestKit 的 P0 骨架引用它，W1-A 删掉引用后可删。
- **默认设备变更测试会改系统默认输出设备约 2 s**（改到私有聚合再改回），只在 `SW_AUDIO_FULL=1` 时跑。
- **设定点与交付抖动**：稳态下混音位置落后"已写入的最新帧"约 target + P/2 + hf + chunk/2（默认 512 + 128 + 47 + 16 = 703 帧），每块要用掉 256 + hf + chunk ≈ 335 帧，所以生产者最坏相位下只能迟到 ~2.4 ms（P = 256 时）。HAL 输入 IOProc（实时线程、采完即交）没问题；NDI / 文件 / 非实时线程的合成源要把 `attach(..., targetFrames:)` 设成 ≥ 它的最坏交付抖动（例如 4–6 块）。生产者块大得多（文件读 4096 帧一块）时门限里的 P/2 会自动给出余量。
- **给 W2-E 的延迟核算**：某路输入在块 T 送出的音频，采样时刻 ≈ T − `InputSlotStats.ageSetpoint`（帧）− 该路延迟补偿 − 输入设备自身延迟（`AudioInputDevice.inputLatencyFrames`）；输出到扬声器再加 buffer + `AudioOutputDevice.outputLatencyFrames`（内置扬声器 256 + 108 帧）。效果链里 DynamicsProcessor +256、PeakLimiter +96 帧。
- 内存：一个 `AudioMixer`（32 槽位、max block 4096）约 26 MB（延迟线 8 MB、重采样器 4.5 MB、四条总线的 libebur128 3 s 窗口 9 MB）。

## 6. 估计器参数、buffer size 与回调抖动（prompt 要求写进报告）

**控制量**：每路"重采样器输入位置的年龄" age = (块首样本 host time − 该位置对应帧的 host time) / 每帧 tick。位置按 frames / ratio 积分并钳到 libsamplerate 的取样关系允许的范围；帧的 host time 用环里最新 stamp 外推。
不用原始环占用的原因：(1) 输入块与输出块两个时钟相差 ±100 ppm 时，块边界相位以 53 s 为周期滑动，原始占用是周期几十秒、幅度一块的方波，PI 会去追它（实测比率抖 ±70 ppm）；(2) 环读位置按 chunk（32 帧）量化，又有周期几秒的锯齿。年龄是连续量。
**设定点**：就绪那一刻的年龄。就绪门限 = target + P/2 + hf + chunk（P = 生产者块，从 stamps 测；hf = sinc 半长 47；chunk = 32），从 write_index − (target + P/2 + hf + chunk/2) 开始消费。这样稳态下环里原始占用在 [target − P/2, target + P/2] 之间随相位周期变化，平均 = target（默认 2 块 = 512 帧；每路可配）。
**前馈**：ratio_ff = 输出速率 / 输入速率（帧 / host tick）。输入用 stamps（帧序号 vs host time），输出用块的 host time，每 1 s 测一次，第一次直接采用，之后一阶低通 τ = 10 s。理由：stamps 是 HAL 对采样时刻的投影（抖动 µs 级），1 s 窗就有 ~10 ppm 精度；比"数到达帧数 / 回调经过时间"（每块 ±1 块的量化噪声，要平均几分钟）好几个量级。
**PI**：ratio = ratio_ff − (kp·e + ki·∫e)，e = 年龄的一阶低通（τ = 0.25 s，只滤 stamp 抖动）− 设定点。kp = 2ζωn / fs、ki = ωn² / fs，ζ = 1（临界阻尼，不过冲）、ωn = 1 / 10 s，即 kp = 4.17e-6 / 帧、ki = 2.08e-7 / (帧·s)。限幅 ±1e-3，限幅时不积分。10 s 的理由：比率变化 1 块误差 → 533 ppm（≈ 1 音分，听不出），10 s 内收敛，8 小时长稳里任何漂移都远慢于此；再快就把 stamp 抖动送进音高。
**实测**：±100 ppm 从就绪到 ±5 ppm 10 s，之后抖动 < 0.5 ppm；无漂移时比率恒 1.0000000。
**buffer size / 抖动**：内置扬声器请求 256 → 实际 256（范围 15…4096）；10 分钟 112 592 次回调，相邻回调间隔与 5.333 ms 的偏差 max 108 µs、p99 < 100 µs（直方图 100 µs/桶：[112 589, 2, 0, …]）；回调进入到 inOutputTime 的提前量 6.23–6.35 ms（= 256 + safety offset 48 帧 + 抖动）；单块处理最长 2.6 ms（预算 5.33 ms，debug 构建、2 路输入 + 全效果 + 表）。空输出设备（time-constraint 线程 + mach_wait_until）醒来最晚 57 µs，6 s 1127 块无跳块。
