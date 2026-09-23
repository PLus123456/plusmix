# W2-A2 纯音频设备输入（Core Audio 输入设备 → 音频环）—— 报告（分支 w2-inputs-2）

日期 2026-09-23。机器 Apple M5 Max 18 核 / 128 GB，macOS 26.6.2 (25G83)，Xcode 27.0 (27A266a)，Swift 6.4，电源适配器，load average 2.9–3.4。
worktree `.claude/worktrees/w2-inputs-audio-device-2ef9a9`，分支 `claude/w2-inputs-audio-device-2ef9a9`（桌面端自动起的名），
**`w2-inputs-2` 这个分支名指向同一个 HEAD**（`git branch -f w2-inputs-2 HEAD`），检查点合并用它。

**第二轮（同日）用户批了提案 014 并指定本会话落地**（"014 批了，你来做"），同时定了 §4 第 2 条的口径、让没做的先归档。
014 改的是 P3 刚改过的 `InputSource`，所以本分支**从 main（367bbb9）挪到了 P3 的 `ca1baa5`（`claude/p3-contracts-phase-2-86a7c4`）之上**
（第一轮的 3 个提交原样 rebase 过去，没有冲突——两边不碰同一个文件）。**合并顺序：先 P3，再本分支**；
P3 合入 main 之前查归属用 `scripts/check-ownership.sh w2-inputs-2 --base claude/p3-contracts-phase-2-86a7c4`（`make lint` 以 main 为基线，会把 P3 的文件算进来）。
提交：`git log claude/p3-contracts-phase-2-86a7c4..w2-inputs-2`。可改目录按用户授权在 OWNERSHIP 的 W2-A2 行多了 7 个文件（§1.5）。

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
| 4 `audio-device` 子命令 | `Sources/SwitcherInputsHarness/AudioDeviceProbe.swift`（列设备 / 跑 N 秒 / 出报告）+ `HarnessAudioRing.swift`（组装方建的真环） | **命令行入口没接**：`Sources/switcher-input-probe/main.swift` 不在本会话的可改目录里，差一段 case，补丁放在 `reports/issues/W2A2-w2-inputs-probe-audio-device-subcommand.md` |
| 共用件 | `Common/Hotplug.swift`（`InputHotplugEvents` + `HotplugMonitorable`），`Camera/HotplugTimer.swift` 泛型化，`CameraInput` 的嵌套 `HotplugEvents` 改成 typealias | 摄像头 S5 和音频 S4 共用同一套计时器；`CameraInput.HotplugEvents` 名字保留，`switcher-input-probe` 不用改 |
| 提案 014（第二轮） | 契约 `Input.swift` + `Contracts014Tests` + CONTRACTS.md；`Common/InputChannelMap.swift`；`AudioDeviceInput` / `DeckLinkInput` 从 case 取映射；App 两行编译跟改 | 见 §1.5 |
| 纯音频输入的口径（第二轮） | 契约 `Input.videoSlot` 注释、CONTRACTS.md §2.4 / §3 | 见 §1.6 |

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

### 1.2 回调里为什么一行 `for i in 0..<n` 都没有

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
`AudioCaptureFIFO.swift` 里就地写了注释。**这不是新发现**：W1-B 在 `SwitcherEngine/Engine/Engine.swift` 的挑帧循环上早就记过
（"-Onone 下 Range 的 IndexingIterator 走未特化泛型，每次迭代会堆分配装箱，分配探针抓到的：每拍 32 次 malloc"），本会话在 IOProc 上又撞了一次，
表里是按循环形式拆开量的数。写 Swift 热路径的会话照这一条来就行。

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
- 声道：环的声道数由组装方定（App / headless 现在都是 2）。映射口径只有一份（`InputChannelMap`，§1.5）：默认取设备的前几路；
  单声道设备复制到所有声道；设备声道比环少时复制最后一路（与 `LPCM` 同一口径）；映射从节目文件的 `.audio(deviceUID:channels:)` 取（提案 014），
  `Options.channelMap` 非 nil 时以它为准。
- 采样格式：设备虚拟格式支持 float32（交错 / 非交错都行）、int16、int32；别的格式 → `noSignal` + 文案。
- 状态（没有画面，只由音频决定）：有块 = `live`；设备不在 / 被拔 / 起流失败 / 格式不支持 = `noSignal` + `lastError` 文案
  （会自己好，G4 报告 §8 第 4 条的口径）；麦克风权限被拒 = `error`（不会自己好）。看门狗门限 = max(块时长, 33 ms) × 3 ≥ 100 ms。
- 热插拔：`kAudioHardwarePropertyDevices` / `kAudioHardwarePropertyDefaultInputDevice` 通知 + 设备自己的
  `kAudioDevicePropertyDeviceIsAlive` 通知 + 每秒轮询兜底。断开 → 拆 IOProc、`noSignal` + 文案；同 uid 回来 → 自动重建
  （`rebuilds` 计数），编号和 `InputSettings` 不在这个对象里所以不变。设备中途被别的程序改大了 IO 块（`oversizeBlocks > 0`）
  也按新块大小重建。

### 1.5 提案 014 落地（第二轮，用户批并指定本会话做）

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/Input.swift` | `audio(deviceUID:channels:)`、`decklink(deviceID:connection:channels:)`，`channels: [Int] = []`（构造时不写就是默认，老调用点一个不用改）。`InputSource` 顶上写了"声道映射"一节的口径：空 = 取前几路；比环短时复制最后一项（`[4]` = 单声道话筒插在第 5 路）；多出来的忽略；越界钳到源的范围 |
| 同上（Codable） | P3 的写法是"decklink / ndi 自己解、其余交给内部 Synthesized 枚举"，编码仍是合成的。加了 `channels` 之后编码也要控制（空映射不写键），于是改成**一个 JSON 形态镜像枚举 `Form`，解码 / 编码都走它**：带默认值的参数在镜像里是 Optional，合成 Codable 对 Optional 用 decodeIfPresent / encodeIfPresent，"缺键按默认解、默认不写键"自然成立。**014 之前能表达的值编出来逐字节不变**——P3 的 `testP3_008_*` 键名快照原样通过，docs/api.md 不用动 |
| `SwitcherContractsTests/Contracts014Tests.swift` | 5 条（§2） |
| `docs/CONTRACTS.md` | 标题、变更记录、§2.4 表与两段口径（声道映射、纯音频输入）、§3 速查一条；提案文件标"已落地"并附落地记录 |
| `SwitcherInputs/Common/InputChannelMap.swift`（新） | 映射口径的唯一实现（`requestedChannel` / `sourceChannel` / `clamp` / `requiredSourceChannels`），纯音频设备与 DeckLink 共用，免得两边各写一份漂移 |
| `AudioDeviceInput` / `AudioCaptureFIFO` | `init(config:)` 从 case 取；`Options.channelMap` 非 nil = 调用方显式覆盖（与 008 的 `connection` 同一个判据）；交接区的声道表按 `InputChannelMap` 算（短映射的行为从"缺的取设备最后一路"改成"缺的复制映射最后一项"，与契约口径一致） |
| `DeckLinkInput`（W3-A 的文件，014 点名要改） | `Options.channelMap`（同上）；内嵌音频开的路数 = max(`audioChannels`, 映射用得上的最大下标 + 1)，按 SDK 只认的 2 / 8 / 16 往上取（`embeddedAudioChannels`；要第 6 路时开 2 路拿不到，开 6 路 `EnableAudioInput` 直接失败）；回调里查 init 时算好的表，不碰 Swift 数组 |
| `App/Sources/Settings/InputSettingsPanel.swift` | 两处 `switch` 的模式跟着多一个关联值（2 行，编译跟改）；摘要里显示映射归 W3-E2 |
| `docs/OWNERSHIP.md` | W2-A2 行按用户授权补上上面 7 个文件，备注写明叠在 P3 上、合并顺序与查归属的 `--base` |

**与提案原文的一处出入**：原文"影响谁"写"`InputSource` 的 JSON 快照多两个键"；落地时收紧成**空映射不写键**，语义不变（缺键 = 空 = 取前几路），
老文件和不用映射的新文件逐字节不变，只有用了映射的才多一个 `channels` 键。

### 1.6 纯音频输入进 Program / 多画面的口径（第二轮，用户定）

用户按我的建议定（第一轮报告 §4 第 2 条）：**能被选进 Program / Preview / 叠加，画面黑场，音频照常按每路 AFV 走；多画面里画占位格（名字 + 电平表）**。
写进了契约 `Input.videoSlot` 的注释和 CONTRACTS.md §2.4 / §3。核对了现状：
- 引擎：每拍对每路 `table.slots[number]` 挑帧，没槽或空槽都得 nil（`Engine.swift` 挑帧循环）；渲染器"没帧 → 画黑"（`CompositorPasses` 的输入表）。
  App 的 `InputRuntime.add` 给每路都建一个槽并登记，纯音频那一路永远是空的——效果与"不登记"相同，所以契约注释写成"挑帧恒为 nil"，两种组装都算对。
- 音频：环照常登记进 AudioEngine，AFV 按输入编号走，切到它就出它的声；这部分要等 App 接线（归档单 1-1）。
- 还没做的是两处界面：App 的输入条 / 缩略图占位（归档 1-3）、多画面占位格（归档 2-1）。

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

**第二轮（提案 014）新增的测试**（都不需要硬件；DeckLink 的 Fake 那条需要 SDK 头，本机有）：

| 测试 | 函数 | 数值 | 通过 |
|---|---|---|---|
| 老文件缺键 | `Contracts014Tests.test014_legacyJSONWithoutChannelsDecodesToEmptyMap` | `{"audio":{"deviceUID":…}}` / `{"decklink":{…}}` 解成 `channels: []`；不写 channels 的构造与之相等 | ✅ |
| 空映射不写键 | `…test014_emptyChannelsAreNotWritten_legacyShapeUnchanged` | `{"audio":{"deviceUID":"uid"}}`、`{"decklink":{"deviceID":"peid:1"}}`、带 connection 的都与 014 之前逐字节相同 | ✅ |
| 带映射的形态与往返 | `…test014_channelsAreWrittenAndRoundTrip` | `{"audio":{"channels":[4,5],"deviceUID":…}}`；decklink 带 / 不带 connection；`[]` 与 `null` 都解成默认 | ✅ |
| 其它 case 形态不变 | `…test014_otherCasesShapeUnchanged` | camera / screen（nil 帧率不写键）/ file / image / ndi 逐字节；synthetic 往返；未知键、缺 deviceUID 抛错 | ✅ |
| 节目文件存取 | `…test014_showWithChannelMapsRoundTrips` | `Show.save()` → `Show.load(from:)` 映射不丢；默认映射不写键 | ✅ |
| P3 的键名快照 | `ContractsP3Tests.testP3_008_inputSourceDeckLinkAndNDIParameters` | Codable 换成镜像枚举后原样通过 | ✅ |
| 映射口径 ×4 | `InputChannelMapTests.test014_*` | 空 = 前几路（单声道复制、少了复制最后一路）；`[5, 2]` 反着取；`[4]` → `[4, 4]`；`[1, 2, 3]` 多的忽略；`[9, −3]` 在 4 路源上钳成 `[3, 0]`；`requiredSourceChannels([3, 4, 15], 2) = 5` | ✅ |
| AudioDeviceInput 从 case 取 | `InputChannelMapTests.test014_audioDeviceChannelsComeFromInputSource_explicitOptionsOverride` | case 的 `[4, 5]` 进 `options.channelMap`；显式 Options 盖过 case；老文件 = `[]`；kind 不符抛错 | ✅ |
| 交接区：短映射 / 越界 / 跨 buffer | `AudioCaptureFIFOTests.testIOProc_shortChannelMapRepeatsLastEntry_outOfRangeIsClamped` | 8 路交错设备 `[4]` → 两个平面都是第 5 路；`[20, −1]` → 第 8 路、第 1 路；两个 4 路 buffer 的设备 `[5, 2]` → 第二个 buffer 的第 1 路、第一个 buffer 的第 2 路 | ✅ |
| DeckLink 从 case 取 | `DeckLinkChannelMapTests.test014_deckLinkChannelsComeFromInputSource_explicitOptionsOverride` | 同上口径；008 的 connection 照旧 | ✅ |
| DeckLink 开几路 | `…test014_embeddedAudioChannelCountCoversTheMapAndRoundsUpToWhatTheSDKAccepts` | 默认 2 → 2；`[5, 2]` → 8；`[12]` → 16；`[40]` → 16；`[3, 4, 15]` → 8；`audioChannels = 6` → 8；`audioChannels = 0` → 0 | ✅ |
| DeckLink 对着 Fake 端到端 | `…test014_deckLinkFake_eightChannelEmbeddedAudio_mappedIntoRing` | 映射 `[5, 2]`：Fake 记到 `EnableAudioInput` 开 **8** 路；4 包 8 路 int32（第 k 路 = (k+1)/128）进环，读出左 = **6/128**、右 = **3/128**，首尾样本都对 | ✅ |

**第二轮的全仓库测试**（契约改了 `InputSource`，所以六个包 + 工具 + App 全跑；分支叠在 P3 的 `ca1baa5` 上；2026-09-23 10:00–10:47）。
`make test` 在 SwitcherInputs 这一包撞上一条 NDI 计时断言就停了（逐包跑、遇错即停），后面的包、工具、App 是用同样的命令分开补跑的：

| 包 / 目标 | 结果 |
|---|---|
| SwitcherCore | Render 78、Engine 90、Contracts 73（跳 1，之前就有）：**0 失败** |
| SwitcherInputs | SwitcherInputsTests 55（跳 6：摄像头 4 条——权限 / 外接设备，音频 S4，麦克风被拒路径）、DeckLinkTests 25（跳 3，实卡）：0 失败；NDITests 25（跳 2）：**1 失败**——`testNDI_loopback_senderStops_noSignalWithin3Intervals_restartsRecover` 71.92 ms > 71.67 ms，单独连跑两遍都过（同类的另一条第一轮也红过一次，§5 第 5 条、归档单） |
| SwitcherAudio | 62（跳 2）+ Integration 41（跳 3）：0 失败 |
| SwitcherOutputs | 6 + 25 + 28 + 8（跳 2）+ 7 + 6（跳 1）：0 失败 |
| SwitcherControl | 25（跳 1）+ 3 + 28：0 失败 |
| SwitcherTestKit | 63：0 失败 |
| 工具冒烟 | switcher-headless、frameprobe：通过 |
| App（xcodebuild test） | 54 个：51 过、2 跳（摄像头权限、虚拟摄像头签名）、**1 失败 = `LocalizationTests.testL10n_noHardcodedChineseInUISources`**——39 条全在 W3-C 的 7 个文件（AppDelegate / AuxOutputRuntime / OutputRuntime / SwitcherSession / ExternalOutputMenu / ISOPanel / MultiviewWindowController），与 G4 报告的"39 处"同一条已知红（问题单 G4-w3-app2-localize-w3c-app-strings，归 W3-E2）；本分支改的 `InputSettingsPanel.swift` 不在其中（改的是 `switch` 模式，注释不算字面量） |

`make build` 全绿（六包 + 两个工具 + App）。归属：`scripts/check-ownership.sh w2-inputs-2 --base claude/p3-contracts-phase-2-86a7c4` → 32 个改动文件全在允许范围内；`lint-rules.sh`（禁词 / 版本号 / Package.swift）与 `check-deps.sh` 绿。

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

**按用户第二轮的指示，没做的全部归档成问题单，由检查点汇总后用户统一处理。总表：`reports/issues/W2A2-g5-pending-items.md`**（分级、归属、不做的后果都在里面）。

| # | 没做的 | 为什么 | 归档到 |
|---|---|---|---|
| 1 | `switcher-input-probe audio-device` 的命令行入口 | 探针的 main.swift 不在可改目录里；实现已在 harness，测试跑过 | `W2A2-w2-inputs-probe-audio-device-subcommand.md`（带补丁） |
| 2 | App 接线（`InputFactory` 的 `.audio`）+ Add Input 的声道选择（014）+ 纯音频的输入条占位 | 归 W3-E2（prompt 63 第 7 条） | `W2A2-w3-app-3-audio-device-input-wiring.md`（带补丁与界面口径） |
| 3 | 多画面里纯音频输入的占位格 + 电平表 | 渲染器的目录（W3-B 的），口径本轮才定 | `W2A2-w3-compositor2-multiview-audio-only-cell.md` |
| 4 | headless 接纯音频输入 | `Tools/` 是检查点目录；端到端 A2 要它 | `W2A2-g5-headless-audio-device-input.md`（补丁要点） |
| 5 | S4 热插拔、权限被拒路径、> 2 路真设备映射、DeckLink 实卡映射、端到端 A2（回环线） | 要插拔设备 / 改系统设置 / 接线 / 实卡 | `W2A2-user-manual-hardware-tests.md`（逐条命令与期望值） |
| 6 | NDI 回环测试在整包负载下偶发超阈值 | W3-A 的测试，本会话不能改；阈值归用户 | `W2A2-w3-inputs2-ndi-audio-interval-flaky-under-load.md` |

另外两条是有意不做（不归档）：
- **不做异步重采样跟踪**：设备时钟和输出设备时钟的 ppm 级差由混音器的异步重采样吸收（设计方案 §3.6，W1-D 的活）；本会话只做
  "设备采样率 ≠ 48 kHz"的固定比值转换，和文件 / NDI 输入同一口径。
- **不改设备的 IO 块大小**：`kAudioDevicePropertyBufferFrameSize` 是全设备共享的，改它会影响别的程序（本机都是 512 帧 = 10.7 ms）。

---

## 4. 对契约的疑问

第一轮的三条都有了结论：

1. **提案 014** → 用户批，本会话落地（§1.5）。与原文的唯一出入是"空映射不写键"（原文说快照多两个键），语义不变，老文件逐字节不变。
2. **`videoSlot` 为 nil 的纯音频输入怎么进 Program / 多画面** → 用户按建议定（§1.6），写进契约注释与 CONTRACTS.md。
3. **noSignal / error 口径** → G4 已定、P3 已写进契约，本会话照做（设备不在 / 被拔 / 格式不支持 = noSignal + 文案，权限被拒 = error）。

第二轮新出来的，需要知会（不是等拍板）：

4. **我改了 P3 刚写的 `InputSource` Codable 的实现**（不是签名 / JSON）：从"decklink / ndi 自己解 + Synthesized 兜底"换成一个镜像枚举管两个方向。
   P3 的全部键名快照原样通过，新加的 `Contracts014Tests` 又逐个 case 钉了一遍形态。P3 会话如果还要动 `InputSource`，在这个结构上改。
5. **DeckLink 的 `Options.audioChannels` 语义有一处变化**：以前原样传给 `EnableAudioInput`（设成 6 会直接失败）；现在按 SDK 只认的 2 / 8 / 16 往上取，
   并且声道映射要的路数更多时自动开够。默认 2 的行为不变。

---

## 5. 下一个会话需要知道的坑

1. **W3-E2 接线**：工厂一支 6 行、表单的声道选择、输入条占位、权限文案，全在 `reports/issues/W2A2-w3-app-3-audio-device-input-wiring.md`。
   要点：`AudioDeviceInput(config:audioRing:)`；`audioBlockFrames` 给 1024；`videoSlot` 是 nil，别强制解包；
   App 现有的 `AudioHAL.devices()` 列出来的 uid 就是 Core Audio 的 UID，和 `AudioDeviceInput` 要的一致。

2. **Swift 的 `for i in 0..<n` 在 debug 构建里每轮堆分配一次**（§1.2 的表；W1-B 在 `Engine.swift` 里先记过）。任何"每帧 / 每块零分配"的断言
   如果是在 debug 下跑的，循环得写成 `while`，否则量出来的是循环本身的分配。`-O` 下没有这个问题，所以 release 跑的探针看不出来。
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

5. **NDI 回环测试在重负载下会抖**：两次整包跑各红过一条——`testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned`
   （最大块间隔 25.34 ms > 24.667 ms）、`testNDI_loopback_senderStops_noSignalWithin3Intervals_restartsRecover`（71.92 ms > 71.67 ms）；
   单独跑各两遍都过。不是本会话代码引起的（NDI 那条路没碰），但**整包负载会影响它们，而 `make test` 遇错即停**——撞上一次，
   后面的包和 App 就都没跑（本会话第二轮就是这样，剩下的部分是分开补跑的，见 §2）。归档：`W2A2-w3-inputs2-ndi-audio-interval-flaky-under-load.md`。

6. **`AudioDeviceIOProcID` 的回调签名参数顺序容易写反**：是
   `(deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData)`——
   第 3 个是输入缓冲、第 4 个才是输入时间戳。写反了编译器只会在类型不匹配时报错，顺序对但语义反的话会静默跑错。

7. **没有麦克风权限时 Core Audio 不报错，只给静音**。不能靠 `AudioDeviceStart` 的返回值判权限，
   必须显式查 `AVCaptureDevice.authorizationStatus(for: .audio)`（本会话复用 W2-A 的 `CapturePermission`）。

8. **`HotplugTimer.run` 改成泛型了**（`input: some HotplugMonitorable`）。`CameraInput.HotplugEvents` 保留成
   `InputHotplugEvents` 的 typealias，`switcher-input-probe` 的调用点不用改。新输入想用这套计时器，
   实现 `HotplugMonitorable`（`number` / `state` / `lastError` / `hotplugEvents` / `hotplugDeviceLabel`）即可。

9. **本分支叠在 P3 上**（第二轮）：检查点**先合 P3 再合本分支**；P3 若改写了历史就先把本分支 rebase 到 P3 的最终提交。
   P3 合入 main 之前 `make lint BRANCH=w2-inputs-2` 的归属检查会把 P3 的 74 个文件算进来，用
   `scripts/check-ownership.sh w2-inputs-2 --base claude/p3-contracts-phase-2-86a7c4`（本会话跑过：26 个文件都在允许范围内）。

10. **"缺键按默认解、默认值不写键"的 Codable 写法**：给带默认值的关联值 / 字段做一个镜像类型，里面换成 Optional，交给合成的 Codable
    （它对 Optional 用 decodeIfPresent / encodeIfPresent），外面只做"nil ↔ 默认值"的换算。比手写 `nestedContainer` 省事，
    而且编码与解码同一个结构，不会一边改了另一边忘（`InputSource.Form`）。

11. **DeckLink `EnableAudioInput` 只认 2 / 8 / 16 路**（新卡还有 32 / 64）：别的数直接失败，桥接层会报"这路没有内嵌音频"，看着像信号问题。
    `DeckLinkInput.embeddedAudioChannels` 负责往上取。

12. **zsh 里 `"$REF:Packages/…"` 会被当成修饰符**（`:P` 是取绝对路径），`git show "$P3:Packages/x.swift"` 会拼出一个奇怪的路径报错。
    写成 `"${P3}:Packages/…"` 或直接写分支名。
