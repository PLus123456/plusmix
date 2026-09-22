# W2-A2 纯音频设备输入（Core Audio 输入设备 → 音频环）—— 报告（分支 w2-inputs-2）

日期 2026-09-23。机器 Apple M5 Max 18 核 / 128 GB，macOS 26.6.2 (25G83)，Xcode 27.0 (27A266a)，Swift 6.4，电源适配器，load average 2.9–3.4。
worktree `.claude/worktrees/w2-inputs-audio-device-2ef9a9`，分支 `claude/w2-inputs-audio-device-2ef9a9`（桌面端自动起的名），从 `main`（367bbb9 = G4 合入后）开；
**`w2-inputs-2` 这个分支名指向同一个 HEAD**（`git branch -f w2-inputs-2 HEAD`），`make lint BRANCH=w2-inputs-2` 和检查点合并用它。
提交 2 个（`git log main..w2-inputs-2`）。改动 16 个文件 / +2647 −17 行，全部在 `Packages/SwitcherInputs/Sources/SwitcherInputs/`、
`Sources/SwitcherInputsHarness/`、`Tests/SwitcherInputsTests/` 和 `docs/contract-changes/`、`reports/issues/` 里。

本机的音频输入设备（`AudioDeviceProbe.deviceLines()`）：

| # | 名字 | uid | 声道 | 采样率 | 可选 | IO 块 | 传输 |
|---|---|---|---|---|---|---|---|
| 0 | MacBook Pro麦克风（系统默认输入） | `BuiltInMicrophoneDevice` | 1 | 48000 | 44100/48000/88200/96000 | 512 | bltn |
| 1 | iPhone 的麦克风（连续互通） | `05D5AC85-…0003` | 1 | 48000 | 48000 | 512 | ccwd |
| 2 | HP Thunderbolt Dock Audio Headset | `AppleUSBAudioEngine:Generic:USB Audio:201604140001:1` | 2 | 48000 | 48000 | 512 | usb |
| 3 | NDI Audio（虚拟） | `BF568F24-…C71A` | 2 | **44100** | 44100/48000 | 512 | virt |

---

## 1. 做了什么

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 `AudioDeviceInput` | `Sources/SwitcherInputs/Audio/AudioDeviceInput.swift`（665 行）、`AudioCaptureFIFO.swift`（IOProc 本体 + 交接区）、`AudioRateConverter.swift` | 见 §1.1–§1.4 |
| 2 `AudioInputDevices` | `Sources/SwitcherInputs/Audio/AudioInputDevices.swift` | `list()`（uid / 名字 / 厂商 / 输入声道 / 当前采样率 / 可选采样率 / 是否系统默认输入 / 在线 / 传输四字码 / IO 块大小）、`deviceID(uid:)`（空串 = 系统默认输入，"0"/"1" 下标也认）、`nominalSampleRate` / `setNominalSampleRate`（异步生效，轮询等）、`inputStreamFormat`、`inputBufferChannelCounts`、`observeChanges(queue:onChange:)`（订 `kAudioHardwarePropertyDevices` + `kAudioHardwarePropertyDefaultInputDevice`，返回可 `stop()` 的订阅） |
| 3 时间戳 | `AudioCaptureFIFO.swift` 的 IOProc | 每块的 hostTime = 回调给的 `AudioTimeStamp.mHostTime`（设备侧采样时刻），不是回调到达时刻（铁律 5）。标志位没置 `hostTimeValid` 时退回"到达时刻 − 本块时长"并计数（`hostTimeFallbacks`，本机实测 0 次） |
| 4 `audio-device` 子命令 | `Sources/SwitcherInputsHarness/AudioDeviceProbe.swift`（列设备 / 跑 N 秒 / 出报告）+ `HarnessAudioRing.swift`（组装方建的真环） | **命令行入口没接**：`Sources/switcher-input-probe/main.swift` 不在本会话的可改目录里，差 3 行 case，抄好放在 `reports/issues/W2A2-probe-audio-device-subcommand.md` |
| 共用件 | `Common/Hotplug.swift`（`InputHotplugEvents` + `HotplugMonitorable`），`Camera/HotplugTimer.swift` 泛型化，`CameraInput` 的嵌套 `HotplugEvents` 改成 typealias | 摄像头 S5 和音频 S4 共用同一套计时器；`CameraInput.HotplugEvents` 名字保留，`switcher-input-probe` 不用改 |

### 1.1 为什么用 `AudioDeviceIOProcID` 而不是 AUHAL（先探针，铁律 10）

prompt 给的是"AudioUnit（`kAudioUnitSubType_HALOutput` 的输入侧）或 AVAudioEngine"。写正式代码之前先拿探针比了三条路
（探针源码在 scratchpad，结论抄在这里）：

| 路子 | 回调线程每 3 秒的 malloc 次数 | 拷贝次数 | 备注 |
|---|---|---|---|
| AUHAL，客户端格式 float32 **非交错**，设备是 2 声道交错（坞站耳麦） | **58–59**（扣掉探针自己数组增长的 13 次） | 2（HAL → 自己的缓冲 → 环） | `AudioUnitRender` 要做交错 → 非交错的转换，转换器在回调里分配 |
| AUHAL，跟设备原格式（交错） | 59（同上量级） | 2 | 同样有分配 |
| AUHAL，1 声道设备（内置麦克风） | 0 | 2 | 单声道不用转换，才没有分配 |
| **`AudioDeviceIOProcID`** | **0**（1 声道和 2 声道设备都是 0） | 1（HAL 缓冲 → 环） | 直接拿 `inInputData` 的 `AudioBufferList`，不用 `AudioUnitRender` |

所以选 IOProc。AVAudioEngine 直接排除：`installTap` 每次回调要新建一个 `AVAudioPCMBuffer`，分配在我们的代码之前就发生了，
"回调内无分配"根本无从谈起。

三条路的时间戳都一样好：`inInputTime->mFlags` 是 7（sampleTime | hostTime | rateScalar），`mHostTime` 的步进恒等于块时长
（内置麦克风 ΔmHostTime 10.667 / 10.668 ms，而回调到达时刻 Δ 是 9.63–10.89 ms），说明它就是设备时间轴上的时刻。

### 1.2 回调里为什么一行 `for i in 0..<n` 都没有（本会话最值得别人知道的一条）

第一版回调写成了普通的 `for d in 0..<channels { … }`，真机上量出来**每次回调正好 2 次 malloc + 2 次 free**。
拿 malloc 钩子单独量各种循环形式（探针结论）：

| 写法（debug / `-Onone`） | 100000 轮的 malloc 次数 |
|---|---|
| `for i in 0..<100_000 { … }`（Range 迭代） | **100001**（每轮一次 malloc + 一次 free） |
| `while i < 100_000 { … }` | 3 |
| `for i in stride(from:to:by:)` | 8 |
| 同样的代码用 `-O` 编 | 0 |

也就是 **debug 构建里 Range 的 `for-in` 每轮堆分配一次**（release 会被优化掉）。渲染 / 音频这种"每帧 / 每块零分配"的热路径
在 debug 下要能自证，就不能用它。改成 `while` 之后：合成 ABL 5000 次回调 malloc **0**，真设备 10 秒 954 次回调 malloc **0**。
`AudioCaptureFIFO.swift` 里就地写了注释。**别的会话写 Swift 热路径时注意这一条**（W1-B / W1-C 的零分配断言如果是在 debug 下跑的，值得照这个口径复核一遍）。

### 1.3 采样率：先把设备固定到 48 kHz，做不到才在泵线程上转（两条都做了）

prompt 给的是"优先把设备固定到 48 kHz（失败 = noSignal + 文案），**或**在专用线程用 AudioConverter 转"。两条都实现了，串起来用：

1. 设备标称采样率 ≠ 48 kHz 且它的可选采样率里有 48 kHz → `AudioObjectSetPropertyData(kAudioDevicePropertyNominalSampleRate)`。
   HAL 是**异步生效**的（探针实测内置麦克风 ≈ 150 ms），所以要轮询等（上限 1.5 s）。`stop()` / 拆会话时**还原成原值**——
   设备是全系统共享的，别的程序还在用它。实测：NDI Audio 44100 → 48000 → 停之后回 44100。
2. 设成不了（设备根本不支持 48 kHz，或别的程序占着改不动）→ 在**泵线程**上用 `AudioConverter` 转（`Options.convertSampleRate`，默认开）。
3. 两样都关（`convertSampleRate = false`）→ `noSignal` + 文案「音频输入设备「X」不支持 48 kHz（当前 44100 Hz）」。

**为什么不只做第 1 条**：第 1 条的失败面是真实的——设备可能压根没有 48 kHz（老 USB 麦克风只有 44.1），也可能被别的程序占住改不了；
这种时候直接 noSignal 等于这路输入不能用，而转换的代价只是泵线程上几十微秒。第 3 条留着是给"我宁可不要转换"的人。
**为什么不在回调里转**：AudioConverter 会分配、会走锁，§3.5 明令禁止；AUHAL 自带的 SRC 也是在回调里转，同样出局。

转换器的时间戳是这条路上最容易错的地方：转换器有群延迟 + 起头的预充，直接把输入块的 hostTime 盖在输出块上会整体偏
（44.1k → 48k 实测偏 **0.72 ms**，A2 是 ms 级指标，不能不管）。做法：建好之后**在这个实例自己身上**用脉冲实测
（喂法、每次要的输出帧数都和正式跑的时候一样），量完 `AudioConverterReset` 复位、计数清零，之后按
`输入帧号 = 输出帧号 × 源采样率 / 48000 + 实测偏移` 把输出块的首帧映射回设备时间轴。
**不能另建一个转换器"一次喂 8192 帧"去量**：预充的帧数和喂法有关（一次喂完量出 0.1 帧，按 512 帧流式喂是 −31.7 帧）。
量完之后单元测试里脉冲反推的误差是 **0.0 输入帧**（量之前是 31.8 帧 = 0.72 ms）。

### 1.4 线程与数据流

```
Core Audio IO 线程（实时）        泵线程（InputThread，time-constraint，周期 = 块时长 / 4，钳 1–5 ms）
  audioDeviceInputIOProc            AudioCaptureBuffer.drain
  ├ mach_absolute_time() 打到达戳     ├ 每块一次 ring.write(planes:frameCount:hostTime:)（块边界与设备块一一对应）
  ├ 取 mHostTime 作块首时刻           ├ 采样率不是 48k 时先过 AudioRateConverter
  └ 按声道映射拷进交接区 ──SPSC──→    └ 喂看门狗、记 d / w 分布
     （while 循环 + 裸指针 + Atomic）
```

- 交接区 `AudioCaptureFIFO` 是**手工分配的 `~Copyable` 结构**（`UnsafeMutablePointer<AudioCaptureFIFO>`），里面是 POD 字段
  + `Synchronization.Atomic`（acquire / release，与契约 `sw_audio_ring.h` 规则 4 同一套写法）。回调只经这个裸指针访问，
  不碰任何 Swift 对象，也就没有 retain / release。16 个槽 × 设备块的两倍帧数 ≈ 170 ms 余量。
- **为什么不让回调直接写 `AudioRing`**：注入进来的是 `any AudioRing`（存在类型派发 + ARC），而契约的 C 布局只提供了
  只读辅助函数，release 语义的发布得自己按布局写一遍——等于在 Inputs 包里复制一份 W1-D 的环实现，且测试替身（`RecordingAudioRing`）
  全都失效。契约 §6 T4 那一行写的是"Swift `AudioRing` 协议只在写端 / 离线工装用"，所以写端走协议、回调走交接区。
  代价实测只有 **0.63 ms**（见 §2 的 w − d），换来的是回调侧真正的零分配零 ARC，和一条对所有 `AudioRing` 实现都成立的写路径。
- 声道：环的声道数由组装方定（App / headless 现在都是 2）。默认取设备的前几路；单声道设备复制到所有声道；
  设备声道比环少时复制最后一路（与 `LPCM` 同一口径）；`Options.channelMap` 可以挑（包内选项，存不进节目文件 → **提案 014**）。
- 采样格式：设备虚拟格式支持 float32（交错 / 非交错都行）、int16、int32；别的格式 → `noSignal` + 文案。
- 状态（没有画面，只由音频决定）：有块 = `live`；设备不在 / 被拔 / 起流失败 / 格式不支持 = `noSignal` + `lastError` 文案
  （会自己好，G4 报告 §8 第 4 条的口径）；麦克风权限被拒 = `error`（不会自己好）。看门狗门限 = max(块时长, 33 ms) × 3 ≥ 100 ms。
- 热插拔：`kAudioHardwarePropertyDevices` / `kAudioHardwarePropertyDefaultInputDevice` 通知 + 设备自己的
  `kAudioDevicePropertyDeviceIsAlive` 通知 + 每秒轮询兜底。断开 → 拆 IOProc、`noSignal` + 文案；同 uid 回来 → 自动重建
  （`rebuilds` 计数），编号和 `InputSettings` 不在这个对象里所以不变。设备中途被别的程序改大了 IO 块（`oversizeBlocks > 0`）
  也按新块大小重建。

---

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherInputs`（debug）。本包 49 个测试：43 通过、6 XCTSkip，约 119 s。
新增 21 个（音频设备 10、IOProc 单元 8、采样率转换 3）。A1 的设备是系统默认输入 **MacBook Pro 内置麦克风**（48 kHz、1 声道、IO 块 512 帧 = 10.667 ms）。

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| **A1** 60 s 无断裂 | `testA1_audioDeviceInputNoDiscontinuityFor60s` | 60 s：**5641 块 / 2888192 帧**（期望 ≈ 2880000，多出来的是收尾那 0.17 s）；环里块的累计帧序号**断裂 0 处**；hostTime **非严格递增 0 处**；**块间隔与块长的最大偏差 0.00121 ms**（块长 10.667 ms）；环 **overruns 0 / underruns 0**（消费者按 48 kHz 节奏读，预充 200 ms）；交接区丢 **0 块 / 0 帧**，超大块 0，空回调 0，hostTime 退回 0；设备 IO 过载 0 | 块连续、hostTime 单调、块间隔 = 块长 ± 1 ms、underrun 0 | ✅ |
| **A2** 块上打的是设备时刻 | `testA2_audioDeviceBlockHostTimeIsDeviceTimestamp` | 10 s / 949 块（掐掉起头 10 块）：**d = 到达 − 块首 hostTime 平均 12.028 ms，标准差 0.0769 ms**，min 11.826 / max 12.313；旁证：**ΔhostTime 的标准差 5.3×10⁻⁵ ms**（设备时间轴）vs **Δ到达 的标准差 0.0911 ms**（调度抖动），差三个数量级；`hostTimeFallbacks` 0 | 标准差 < 1 ms | ✅ |
| **S4** 拔掉 → noSignal → 插回恢复 | `testS4_audioDeviceUnplugGoesNoSignalThenRecovers` | — | 崩溃 0；恢复 ≤ 3 s；编号不变 | **BLOCKED-硬件**（见下） |
| **RT** 回调零分配（真设备） | `testRT_audioDeviceCallbackAllocatesNothing` | 10 s、**954 次 IOProc 回调**，回调线程 **malloc 0 次 / free 0 次**（malloc_logger 钩子按 mach 线程端口计） | 0 | ✅ |
| **RT** 回调零分配（合成 ABL，无硬件） | `AudioCaptureFIFOTests.testRT_ioProcAllocatesNothing` | 5000 次回调（512 帧 × 2 声道交错），**malloc 0 / free 0** | 0 | ✅ |
| **权限** 被拒 = error | `testPermission_microphoneDeniedIsError` | — | status = error + 文案 | **XCTSkip**（本进程已有麦克风权限，见下） |
| 探针 `audio-device` | `testAudioDeviceProbe_listsDevicesAndRunsOne` | 列出 4 台设备；跑内置麦克风 3 s：276 块 / 141312 帧，断裂 0、非单调 0、overruns 0、underruns 0；块间隔 min 10.667 / p50 10.667 / max 10.668 ms；**w = 写环时刻 − 块首 hostTime 平均 12.578 ms，泵这一跳 = w − d = 0.633 ms** | — | ✅ |
| 设备清单 | `testAudioDevices_listHasUIDsAndDefaultInput` | 4 台设备的 uid 都能找回设备；默认输入恰好 1 台；订阅建了能摘、重复摘不崩 | — | ✅ |
| 设备不在 = noSignal | `testAudioDevice_missingDeviceIsNoSignalWithMessage` | state = `noSignal`（不是 error），文案「找不到音频输入设备「switcher-no-such-audio-device」（未连接）；已连接的输入设备：…」；没有音频写进环 | 会自己好的用 noSignal | ✅ |
| 固定采样率 + 还原 | `testAudioDevice_forcesDeviceToFortyEightKHzAndRestoresOnStop` | NDI Audio 44100 → **48000**（转换器不启用）；`stop()` 之后设备回 **44100** | 固定得上、停了还原 | ✅ |
| 转换器那条路 | `testAudioDevice_converterPathProducesFortyEightKilohertz` | NDI Audio 44100 Hz 不动它（`forceSampleRate48k = false`）：5.11 s 写环 441 块 / **245760 帧**（期望 ≈ 245105，差 0.27%），转换报错 0，交接区丢 0，overruns 0 | 每秒 48000 帧 ± 2% | ✅ |
| 采样率转换帧数比与音调 | `AudioRateConverterTests.testRateConverter_44100To48000_keepsFrameRatioAndTone` | 输入 46080 帧 → 输出 **50155** 帧（理论 50155.1）；输出音调 **1000.11 Hz**（输入 1 kHz），峰值 0.4999（输入 0.5） | 帧数差 < 64；音调差 < 5 Hz | ✅ |
| 输出帧号 → 输入帧号（决定写环的 hostTime） | `…testRateConverter_outputFrameMapsBackToTheSourceFrameOfTheImpulse` | 脉冲在输入第 3172 帧 → 输出第 3487 帧；`sourceFrame(forOutputFrame:)` 反推 **3172.0**，误差 **0.0 输入帧**（补偿之前是 31.8 帧 = 0.72 ms） | ≤ 2 输入帧 | ✅ |
| 群延迟在别的采样率上也成立 | `…testRateConverter_measuredLatencyIsSaneAtSeveralRates` | 44100 → −31.68 输入帧（−0.718 ms）；32000 → −32.0（−1.000 ms）；88200 → −32.60（−0.370 ms）；96000 → −32.0（−0.333 ms） | 有限且 < 50 ms | ✅ |
| IOProc：交错 float32 + 声道映射 | `testIOProc_interleavedFloat32_mapsRequestedChannels` | 4 声道交错设备、`channelMap = [2, 0]`：平面 0 = 设备第 2 路、平面 1 = 设备第 0 路，逐样本精确；hostTime / sampleTime 原样带过 | — | ✅ |
| IOProc：非交错 float32 | `testIOProc_nonInterleavedFloat32_copiesPlanes` | 每声道一个 buffer，两路逐样本精确 | — | ✅ |
| IOProc：单声道复制 | `testIOProc_monoDeviceIsCopiedToEveryChannel` | 1 声道设备 → 两个平面完全相同 | — | ✅ |
| IOProc：int16 / int32 归一化 | `testIOProc_int16AndInt32AreNormalized` | 16384 → 0.5，−32768 → −1.0；1<<29 → 0.25 | — | ✅ |
| IOProc：hostTime 无效退回 | `testIOProc_invalidHostTimeFallsBackAndCounts` | 标志位没置 → hostTime 落在 [到达 − 块时长, 到达] 内，`status & 2` 置位，`hostTimeFallbacks` = 1 | — | ✅ |
| IOProc：交接区满 | `testIOProc_fifoFullDropsBlocksAndCounts` | 4 槽写 6 块 → 产出 4、丢 2 块 / 2×32 帧；取空之后又能写 | — | ✅ |
| IOProc：块比槽大 | `testIOProc_oversizeBlockIsDropped` | 256 帧进 64 帧的槽 → `oversizeBlocks` = 1，不产出 | — | ✅ |

**BLOCKED 汇总**

- **S4（热插拔）= BLOCKED-硬件**。本机能拔的只有 HP Thunderbolt 坞站上的耳麦（要拔整个坞站），会话里没法替用户拔插。
  代码和计时器都在（`HotplugTimer.run(input:cycles:cycleTimeoutSeconds:log:)`，和摄像头 S5 同一套）。**人工步骤**：
  ① `SWITCHER_AUDIO_HOTPLUG_UID=<uid> swift test --package-path Packages/SwitcherInputs --filter testS4`
     （uid 从 `AudioDeviceProbe.deviceLines()` 抄，例如坞站耳麦是 `AppleUSBAudioEngine:Generic:USB Audio:201604140001:1`）；
  ② 提示「请拔掉设备」时拔掉 USB 声卡 → 期望 `state` 进 `noSignal`、`lastError` 是「音频输入设备「X」已断开，等待重新连接」；
  ③ 提示「请插回」时插回 → 期望 **≤ 3 s** 回 `live`，输入编号不变、**不用重建输入对象**；
  ④ 默认 20 次，`SWITCHER_AUDIO_HOTPLUG_CYCLES` 可改。出表：断开→noSignal、连接→live、拔着时长、最大 / 平均恢复时间。
  解锁条件：一台能反复插拔的 USB 声卡 / 音频接口。
- **权限被拒路径 = XCTSkip**（不是 BLOCKED）。本进程（xctest，责任进程是 claude-code 辅助程序）**有**麦克风权限
  ——和摄像头不同：那个辅助程序的 Info.plist 有麦克风用途说明、没有摄像头用途说明（W2-A 报告 §3 第 1 条），
  所以摄像头的测试跳、麦克风的能跑。要验被拒路径，得先在 系统设置 › 隐私与安全性 › 麦克风 里关掉它再跑，
  期望：`start()` 不抛不崩，5 s 内 `state = error`，文案「麦克风权限被拒。打开 系统设置 › 隐私与安全性 › 麦克风，
  允许本程序后会自动恢复，不用重启。」，`stop()` 后回 `noSignal`。授权后自动恢复的那半边走的是和摄像头同一段轮询代码
  （每秒查 `AVCaptureDevice.authorizationStatus`，变 authorized 就建会话）。

`make lint BRANCH=w2-inputs-2` 全绿（禁词 / 版本号 / Package.swift 约束 / 依赖方向 / 归属 15 个文件 / RT 符号）。
`swift build`（全部 target）和 `swift build --build-tests` 无错无警告。

---

## 3. 没做的和原因

1. **`switcher-input-probe` 的命令行入口没接**：`Packages/SwitcherInputs/Sources/switcher-input-probe/` 不在 W2-A2 的可改目录里
   （docs/OWNERSHIP.md 的 W2-A2 行只有 `Sources/SwitcherInputs/`、`Sources/SwitcherInputsHarness/`、`Tests/SwitcherInputsTests/`、`Tests/Fixtures/`）。
   子命令的全部实现在 `SwitcherInputsHarness/AudioDeviceProbe.swift`，测试里跑过；差的 3 行 case 抄在
   `reports/issues/W2A2-probe-audio-device-subcommand.md`，谁拿到那个目录的归属就顺手加。
2. **App 接线没做**：归 W3-E2（prompt 63 第 7 条）。App 的 `InputFactory` 现在对 `.audio` 抛 unsupported，接法见 §5 第 1 条。
3. **契约没动**：声道映射确实需要一个能进节目文件的地方，按铁律 1 只写了提案 `docs/contract-changes/014-input-channel-map.md`，
   **停下来等用户批**，没碰 SwitcherContracts。
4. **DeckLink / NDI 没动**（prompt 明令）。
5. **没做异步重采样跟踪**：设备时钟和输出设备时钟的 ppm 级差由混音器的异步重采样吸收（设计方案 §3.6，W1-D 的活）。
   本会话只做"设备采样率 ≠ 48 kHz"的整数比转换（固定比值），不跟踪漂移——这和文件 / NDI 输入的口径一致。
6. **没做多于 2 声道的实机验证**：本机最多 2 声道输入设备。声道映射（4 声道设备取第 2、0 路）只有合成 ABL 的单元测试覆盖。
7. **IO 块大小没去改**：`kAudioDevicePropertyBufferFrameSize` 留给系统 / 别的程序定（本机都是 512 帧 = 10.7 ms）。
   要更低延迟可以设小，但那是全设备共享的属性，改它会影响别的程序，没有必要不动。

---

## 4. 对契约的疑问

1. **提案 014（待批）** `docs/contract-changes/014-input-channel-map.md`：`InputSource.audio` / `.decklink` 各加一个
   `channels: [Int] = []`（取设备的哪几路）。**W3-A 报告 §4 第 5 条提过同一件事**（DeckLink 的 SDI 内嵌音频 2–16 路），
   这次是第二次撞到，所以写成提案。不批的话两边都只能留在包内 `Options`：默认取前两路，节目文件记不住，
   W3-E2 的 Add Input 表单里那一项做不了。功能上不阻塞（单 / 双声道设备走默认就对）。
   提案里也说明了为什么放 `InputSource` 而不是 `InputAudioSettings`（前者是"接的是什么"、创建时定；
   后者是混音侧参数、运行中可改，而输入对象现在看不到 MixerState）。
2. **`Input.videoSlot` 为 nil 时引擎怎么办**：契约写了"纯音频输入为 nil"，但引擎 / 组装方那边"一路没有帧槽的输入"要不要
   `registerInput`、渲染时这一路画什么（黑场？不占多画面格子？）没有明文。本会话没有引擎接线（那是 App / headless 的事），
   `AudioDeviceInput.videoSlot` 就老老实实是 nil。**W3-E2 接线时要定**：多画面里这一路显示成什么、Program 能不能切到它。
   建议：能选进 Program（画面黑场，音频照走），多画面里画一个带电平表的占位格——但这是界面决定，请拍板。
3. **`InputState` 的 noSignal / error 口径**（G4 §8 第 4 条已定，这里只是确认落实）：设备不在 / 被拔 / 起流失败 / 格式不支持
   → `noSignal` + `lastError` 文案；麦克风权限被拒 / 被策略限制 → `error`。和 W3-A 的 DeckLink / NDI 一致。
   P3 把这条写进 `InputState` 注释之后，本文件的注释可以指过去。

---

## 5. 下一个会话需要知道的坑

1. **W3-E2 接线只要三样东西**（`InputFactory` 的 `.audio` 分支）：

   ```swift
   case .audio:
       return try AudioDeviceInput(config: config, audioRing: ring)   // ring 是组装方建的那一路环
   ```

   加上 Add Input 表单要的 `AudioInputDevices.list()`（每台有 `uid` / `name` / `inputChannels` / `sampleRate` /
   `availableSampleRates` / `supports48k` / `isDefaultInput` / `transportType` / `bufferFrameSize`）和
   `AudioInputDevices.observeChanges(queue:onChange:)`（设备插拔时刷新列表，记得 `stop()`）。
   `deviceUID` 传空串 = 跟随系统默认输入（默认输入变了会自动重建）。这一路**没有帧槽**，`videoSlot` 是 nil（见 §4 第 2 条）。

2. **Swift 的 `for i in 0..<n` 在 debug 构建里每轮堆分配一次**（§1.2 的表）。任何"每帧 / 每块零分配"的断言如果是在
   debug 下跑的，循环得写成 `while`，否则量出来的是循环本身的分配。`-O` 下没有这个问题，所以 release 跑的探针看不出来。
   本会话的 `AllocationProbe` 副本还改了一处：`dlsym` 的结果缓存起来——原件的 `stop()` 里会在钩子还挂着的时候再调一次
   `dlsym`，那次调用自己会分配一次，合成 ABL 的测试要精确到 0 就容不下它。

3. **改设备标称采样率是全系统副作用，务必还原**。HAL 是异步生效的（≈ 150 ms），设完要轮询等；
   设不支持的采样率会直接返回错误（本机坞站耳麦设 44100 返回 OSStatus 2003329396）。
   `AudioDeviceInput` 只在"自己改过"的时候还原，并且记的是**改过的那台设备**而不是 `deviceID`
   （会话在 IOProc 建起来之前失败时 `deviceID` 还是 0，用它判断就漏还原了——这个 bug 在本会话里出现过一次，已修）。

4. **虚拟音频设备的 mHostTime 可能很粗**。本机的 NDI Audio（NDI Tools 装的虚拟设备）实测
   **相邻两块的 ΔmHostTime 在 0 和 23.4 ms 之间跳**（两块共用一个时间戳，然后隔两块的量），
   而回调到达时刻是规整的 11.6 ms。真设备（内置麦克风、USB 坞站耳麦）都没有这个问题。
   所以 A1 的"块间隔 = 块长 ± 1 ms"只能在真设备上判；`AudioDeviceInput` 对这种设备不会崩，
   `nonMonotonicBlocks` 会计数（它只在 hostTime **不递增**时才计，Δ = 0 也算）。
   接虚拟设备（NDI Audio、Loopback、BlackHole 之类）时看这个计数。

5. **NDI 回环测试在重负载下会抖**：跑整包测试（含本会话 60 s 的 A1 + 一条 user-interactive 的消费线程）时，
   `NDITests.testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned` 失败过一次
   （最大块间隔 25.34 ms > 阈值 24.667 ms）；单独跑它稳过。不是本会话代码引起的（NDI 那条路没碰），
   但**整包测试的机器负载会影响它**，检查点跑 `make test` 时留意。

6. **`AudioDeviceIOProcID` 的回调签名参数顺序容易写反**：是
   `(deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData)`——
   第 3 个是输入缓冲、第 4 个才是输入时间戳。写反了编译器只会在类型不匹配时报错，顺序对但语义反的话会静默跑错。

7. **没有麦克风权限时 Core Audio 不报错，只给静音**。不能靠 `AudioDeviceStart` 的返回值判权限，
   必须显式查 `AVCaptureDevice.authorizationStatus(for: .audio)`（本会话复用 W2-A 的 `CapturePermission`）。

8. **`HotplugTimer.run` 改成泛型了**（`input: some HotplugMonitorable`）。`CameraInput.HotplugEvents` 保留成
   `InputHotplugEvents` 的 typealias，`switcher-input-probe` 的调用点不用改。新输入想用这套计时器，
   实现 `HotplugMonitorable`（`number` / `state` / `lastError` / `hotplugEvents` / `hotplugDeviceLabel`）即可。
