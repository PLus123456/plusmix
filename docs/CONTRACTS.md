# SwitcherContracts 契约（P1 冻结；P2 落地提案 001–006，P3 落地提案 007–013，W2-A2 落地提案 014，G4 续做落地 015 / 017 / 019，W3-E2 落地 016，W3-C2 落地 018；P4 收口注释与两条 reducer 规则；P5 落地 023 一 / 024 / 025 / 026 / 027；P5-2 落地 020 / 021 / 022 / 023 二–五与 028 的口径文字；P5-3 落地 026 允许 headphones 与 029；P5-4 落地 030 / 031 与 020 的 T-bar 取消重拷；P5-5 落地 032 与 030 列耳机总线）

代码：`Packages/SwitcherCore/Sources/SwitcherContracts/`（Swift）+ `Sources/SwitcherContracts/C/include/sw_audio_ring.h`（C 布局，target CSwitcherContracts）。
测试：`Packages/SwitcherCore/Tests/SwitcherContractsTests/`。所有包只依赖这里的类型互相见面（依赖方向见 CLAUDE.md）。

**改契约的规矩**：任何公开类型、JSON 字段名、测试图案布局、C 结构布局的改动，先在 `docs/contract-changes/` 写提案，用户批了才改（铁律 1）。
加 case / 加字段也算改（下游的 switch 和快照测试会红）。只有文档注释和实现细节（不改公开签名与 JSON）可以直接改。

**变更记录**：P1 冻结（2026-09）→ 提案 003（W2-C 直接落地：CommandReceipt.applied、MixerSnapshot.publishedAt 等）→ P2（2026-09-18，分支 p2-contracts）：
提案 001 A / 002 / 004 / 005 的 Stats 字段、001 B 的 `AudioBlockConsumer`、`Bus.name`、006 的 `TestPattern.Background.noise`（用户 2026-09-18 批）
→ 提案 011（W3-D 按授权直接落地：兼容层的 lint 例外）→ **P3（2026-09-23，分支 p3-contracts）：提案 007（AudioState 的 alignmentFrames / monitorPoint + 三条口径）、
008（InputSource 的 DeckLink 接口 / NDI 带宽与抖动缓冲）、009（KeyerSettings 口径，只改文档）、010（叠加边框 / 锚点 / PVW 预览 / 滑入方向 + 多画面布局正式字段 + `setOverlayDecoration`）、
012（五条界面命令 + EffectSlot 参数键口径）、013（Stats.display[] + OutputSettings.display），另加每路 AFV 开关 `InputAudioSettings.afv`
与 W3 各报告等拍板的口径（用户 2026-09-22 批）**
→ **提案 014（用户 2026-09-23 批并指定 W2-A2 落地，分支 w2-inputs-2，叠在 P3 之上）：`InputSource.audio` / `.decklink` 的 `channels`（声道映射），
外加纯音频输入（`videoSlot` 为 nil）进 Program / 多画面的口径（W2-A2 报告 §4 第 2 条，同日定）**
→ **提案 018（用户 2026-09-23 批并指定 W3-C2 落地，分支 w3-outputs-3）：`Stats.DisplayEntry.undelivered`（不在呈现 / 发布时没送出去的帧），
`dropped` 的口径收紧成"在呈现 / 发布时没送出去的"，两者不重叠**
→ 提案 015（G4 续做合入会话按授权落地：`DisplayOutputSettings.fallbackToMain` 默认与缺键改 false）、016（W3-E2 落地：`Command.setTransitionParams`，34 个 case）
→ 提案 017（用户 2026-09-24 批，G4 续做合入会话落地：`Stats.audio.meters` 的 `rms_db`）
→ 提案 019（用户 2026-09-27 批，G4 续做合入会话落地：`Stats.EncoderEntry` 的 `output` / `connections`、NDI state 的 failed、reducer 对 addInput / setInputSettings 剥 border 格）
→ **P4（2026-09-27，分支 p4-contracts）：过期注释 / 口径收口；reducer 两条小规则（removeInput 清 Stinger 引用，addOutput / setOutputSettings / loadShow 先搬过渡键）；
搬迁清掉 `border` 效果格与悬空的 Stinger 引用；`validate()` 只查结构、不查引用（用户 2026-09-27 定）。没有加改任何公开类型与 JSON 键**
→ **P5（2026-10-10，分支 p5-contracts）：提案 023 第一节（转场进行中 setPreview / setProgram 拒收，只落契约文字）、024 (b)（`EffectSlot` 键表加 `compressor` / `peakLimiter.ceilingDb`、经典 Q 口径、≤ 16 段 / ≤ 3 格，只改注释与表）、
025（`RecordSettings.armed` / `ownFormat`、`StreamSettings.followFirst` + 旧 extra 键的搬迁函数，不并进 Show.load）、026（`AudioState.monitorSource` + `setMonitorSource`，35 个 case）、027（`OverlayAnimation.defaultFade(for:)` + `MixerState.newShow`，新节目叠加默认淡入 0.5 s）；
020（转场槽 + FTB 时长）/ 021（文件播放控制）/ 022（Stats.encoder 的 uptime_s / disconnects / last_error）/ 023 二–五（container 废弃、effects 只放音频、InputConfig.color、setInputAudio）写成提案待批**。提案文件留在 docs/contract-changes/ 当决策记录。
→ **P5-2（2026-10-11，分支 p5-contracts-2，prompt 108；用户 2026-10-11 批 020 / 021 / 022 / 023 二–五，"请用户定的点"全按提案默认）：
020（`TransitionSlot`、`TransitionState.slots`（恰好 4）/ `currentSlot`、出厂四槽按帧率、搬迁补槽、`setTransitionSlot` / `useTransitionSlot` / `setFTBDuration`）、
021（`InputSettings.playback`、`setPlayback` / `seekPlayback`、restartOnProgram 由 reducer 在换 PGM 那一拍写定位 0）、022（`Stats.encoder[].uptime_s` / `disconnects` / `last_error` / `attempt`、顶层 `video_delay_ms`）、
023 二（`RecordSettings.container` 标废弃、录制来源 PVW / 多画面照录 PGM）/ 三（`effects` 只放音频）/ 四（`InputColor`、`InputConfig.color`、`setInputColor`、layout 键的搬迁函数不并进 Show.load）/ 五（`setInputAudio`）；
Command 35 → 42；028 的口径文字（`tickTime` / `hostTime` = 节目输出时间线、`renderMs` = gpuEnd − program.pts、L1 含 L）**
→ **P5-3（2026-10-12，分支 p5-contracts-3，prompt 110；用户 2026-10-12 定）：026 允许 `monitorSource = headphones`（= 听耳机总线自己；校验器 / reducer 不再拒，文件 / API 全量状态按字面读、"读成 master"的兜底去掉）、
029 没选输入的 Stinger 槽拒收（`TransitionSlot.isStingerWithoutInput`；`useTransitionSlot(start: true)` 对这种槽、`autoTransition` 对这种当前那组：校验器 400、reducer 原样返回；只选中 / T-bar / cut / fade 不变）。
不加字段、不加命令（仍 42 个 case），JSON 形态不变**
→ **P5-4（2026-10-18，分支 p5-contracts-4，prompt 115；用户 2026-10-17 批 030 / 031 与 020 追加）：030（`Stats.audio.effects`：buses[{bus, latency_ms, measured_latency_ms?}] Master / Bus A / Bus B + inputs{n: {latency_ms, measured_latency_ms?}}，集成层从 `AudioEngineStatus` 拷）、
031（`FileSource.rateRange` = 0.1…8、`PlaybackLimits.maxSeekSeconds` = 一周、`MixerStateError.fileRate`；`validate()` / 校验器 / reducer 同一条边界；file 来源缺 rate = 1；`clamped()` 定位秒数钳到一周）、
020 追加（T-bar 拉回 0 取消那一拍也按当前槽重拷）。不加命令（仍 42 个 case）；JSON 只多 audio.effects 一节，别的形态不变**
→ **P5-5（2026-10-24，分支 p5-contracts-5，prompt 123；用户 2026-10-18 定"22 条都按建议"）：032（`InputConfig.numberRange` = 1…16、`MixerStateError.inputNumber`；`validate()` / 校验器的 addInput / reducer 同一条边界——0.1.1 唯一的 S1）、
030 列耳机总线（`EffectsLatency.listedBuses` = `Bus.allCases`，填数 G10 胶水已改）、NDI 的 failed 也指"在跑但连续 10 帧送不出"与推流 last_error 的新写法（118 / G10 胶水的行为，只改文字）。
不加字段、不加命令（仍 42 个 case），JSON 形态不变**

---

## 1. 术语 → 标识符（设计方案 §1.1）

| 术语 | 标识符 | 备注 |
|---|---|---|
| Input（输入） | `InputConfig`（配置）/ `Input` 协议（运行对象）/ `InputKind` / `InputSource` | 编号 1…16（`InputConfig.numberRange`，提案 032），`MixerState.noInput = 0` 表示黑场 |
| Program / PGM | `MixerState.program`（输入编号） | |
| Preview / PVW | `MixerState.preview` | |
| Transition（转场） | `TransitionType` {cut, fade, wipe, zoom, stinger}、`TransitionState` | 只在拍点边界发生；Cut 无中间态 |
| T-bar | `Command.tbar(progress:)`、`TransitionSource.tbar` | |
| FTB | `FadeToBlack`（`MixerState.ftb`）、`Command.ftb(on:)` | |
| Overlay 1–4 | `OverlayState`（`MixerState.overlays`，恰好 4 个）、`Command.overlay(channel:on:input:)` | channel 1–4 |
| Bus（音频总线） | `Bus` {master, busA, busB, headphones}、`BusState`、`BusRouting` | |
| Output（输出） | `OutputState`、`OutputKind` {record, stream, ndi, externalDisplay, virtualCamera, multiview} | 编号从 1 起 |
| Tally | `Tally {program, preview}`、`MixerState.tally(ofInput:)` | 全系统只算这一处 |
| Show（节目文件） | `Show`（schemaVersion = 1） | |
| Tick | `Tick`（Int64）、`TickClockSpec` | |

---

## 2. 类型总表：是什么、谁写、谁读、线程归属

"写"= 产生 / 修改；"读"= 消费。线程：**渲染** = 渲染线程（每拍零分配）、**音频** = 音频实时回调（无锁无分配无 ARC，C）、**输入** = 各输入自己的线程、**状态机** = 持有状态的 actor、**普通** = 任意非实时线程。

### 2.1 时间（Time.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `MachTimebase` | mach 时基 numer/denom；`HostClock.timebase` 进程内读一次 | HostClock | 所有换算 | 任意 |
| `HostTime` | mach_absolute_time 的 tick 数，唯一的时间戳类型（铁律 5） | 入口打戳的人 | 所有人 | 任意，值类型 |
| `HostDuration` | 有符号的 tick 差；`HostTime - HostTime` | 同上 | 同上 | 任意 |
| `Rational` | 整数分子分母，永远约分、分母为正 | — | 时钟、帧率 | 任意 |
| `FrameRate` | 每秒帧数的 Rational；预设 24/25/29.97/30/50/59.94/60；`nominalFramesPerSecond` 四舍五入（59.94 → 60） | 配置 | 时钟、合成源、闪光节奏 | 任意 |
| `Tick` | 拍序号 Int64，第 0 拍在 t0，可为负 | 时钟（W1-B） | 状态机、脚本、Stats | 任意 |
| `TickClockSpec` | {t0, frameDuration}；`time(of:)`、`tick(at:)`、`duration(ofTicks:)` 全是 128 位整数运算 | 引擎启动时 | 时钟、编码 PTS、合成源 | 任意 |

拍点数学：`time(of: n) = t0 + floor(n × p × 10⁹ × denom / (q × numer))`，一次乘除，不累加；`tick(at:)` 是它的严格逆（最大的 n 使 time(of: n) ≤ t）。测试证明 59.94 fps 第 216000 拍误差 0、浮点累加 1 h 差 7 ns / 8 h 差 1.3 µs。

### 2.2 视频（Video.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `PixelFormat` | {nv12, bgra, uyvy} ↔ CoreVideo 类型（nv12 按 range 分 '420v'/'420f'） | 输入 | 渲染、编码 | 任意 |
| `ColorInfo` | {primaries, transfer, matrix, range}；默认 `.bt709Limited`（引擎输出永远是它，V9） | 输入 | 渲染、编码 | 任意 |
| `RGB8` / `YCbCr` | 8-bit RGB / BT.709 limited YCbCr 实数；调色板、抠像键色 | 配置、图案 | 图案解码 | 任意 |
| `Frame` | {pixelBuffer, pts, duration, color, inputNumber, sequence, ingressTime}；`@unchecked Sendable`：push 之后像素只读，池回收靠引用计数 | 输入线程 | 渲染（挑帧）、编码（PGM 帧 inputNumber = 0） | 输入 → 渲染 → 消费者 |
| `ProgramFormat` | {width, height, frameRate}；预设 1080p60 / 1080p59.94 / 1080p30 / 720p60 / 2160p30 | Show / 命令 | 引擎、渲染、编码 | 任意 |

`Frame.pts` = 采集时刻换算成 host time（挑帧比它）；`ingressTime` = 进帧槽那一刻（L1 = 编码器入口 − ingressTime）。

### 2.3 帧槽与音频环（Slots.swift + sw_audio_ring.h）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `FrameSlot` 协议 | 每路一个，容量 2–3；`push` / `latest(atOrBefore:)` / `stats`。实现在 SwitcherEngine（W1-B） | 输入线程 push | 渲染线程 latest；分支槽（`SwitcherISO.InputFrameTee.addBranch`）由它唯一的读者 latest（ISO 的 tap、Aux 显示在显示刷新上读） | SPSC（每个槽一个生产者、一个消费者），无锁零分配 |
| `FrameSlotStats` | pushed / consumed / dropped / reused，累计 | 帧槽 | Stats.per_input、测试 | 原子读 |
| `AudioRing` 协议 | 每路一个 SPSC 环，float32 非交错 48 kHz，每块带 host time；`write` / `read` / `availableFrames` / `stats` / `raw`。实现在 SwitcherAudio（W1-D，C） | 输入线程 write | 混音回调经 `raw` 直接读 | SPSC，无锁零分配 |
| `sw_audio_ring`（C） | 环头布局，256 字节，layout_version 1；生产者计数在偏移 128、消费者计数在 192（各占一条缓存线） | W1-D 的实现 | 混音 C 热路径、Swift 包装 | 音频 |
| `AudioFormat` | sampleRate 48000、maxChannels 8、defaultBlockFrames 256 | — | 所有音频代码 | — |

帧槽统计口径（V4 的依据）：`consumed` = latest 返回了帧的次数；`reused` = 返回的是上次同一帧的次数（30 进 60 → reused/consumed = 50%，设计内）；`dropped` = 从未被返回就被淘汰的帧数（槽满被挤、或被更新帧跳过）。
`sw_audio_ring` 的偏移由 `layout.c` 的 `_Static_assert` 和 `LayoutTests` 双重钉死；改布局要升 `SW_AUDIO_RING_LAYOUT_VERSION`。
**注入规则**：输入实现不 new 帧槽 / 环（Inputs 包看不到 SwitcherAudio），init 接收 `any FrameSlot` / `any AudioRing`，由组装方（headless / App / 测试）创建。

### 2.4 输入（Input.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `InputKind` | {camera, decklink, screen, file, image, ndi, audio, synthetic} | 由 `InputSource` 推出 | UI、引擎 | — |
| `InputState` | {live, noSignal, error(message:)}；未 start / 已 stop = noSignal | 输入线程 | UI、引擎 | 实现保证原子 |
| `InputSource` | 每种 kind 的来源参数（设备 ID、路径、屏幕目标、NDI 源名 / 带宽 / 抖动缓冲、DeckLink 设备 ID / 接口 / 声道映射、纯音频设备 UID / 声道映射、合成源设置）；file 的 `rate` 合法范围 `FileSource.rateRange` = 0.1…8、缺键 = 1（提案 031，见下"文件输入的播放控制"） | Show / addInput / setInputSource | 输入实现 | 普通 |
| `DeckLinkConnection` / `NDIBandwidth` | {sdi, hdmi, opticalSDI, component, composite, sVideo} / {highest, lowest, audioOnly}（提案 008） | 同上 | DeckLinkInput / NDIInput 填 `Options` | — |
| `SyntheticSourceSettings` | 合成源：帧率、尺寸、底色、patternID、抖动、丢帧、时钟漂移、音频及其漂移 | Show / 脚本 | TestKit（W1-A） | 普通 |
| `InputSettings` | {crop, transform, audio: `InputAudioSettings`, effects: [`EffectSlot`]（键表见下，**只放音频效果**——023 三；每路的接线归 W1-D3）, keyer: `KeyerSettings`（提案 009）, playback: `PlaybackSettings`（提案 021，缺键默认）}；`clamped()` 钳范围（含 seekSeconds 0…一周：021 钳 ≥ 0，031 加上限） | 状态机（setInputSettings / setInputAudio / setPlayback / seekPlayback） | 渲染（crop/transform/keyer）、混音（audio / effects）、组装方（playback → FileInput） | 从快照读 |
| `InputAudioSettings` | {routing: `BusRouting`, gainDb, muted, solo, pan, delayMs 0–500, afv}（提案 012 顺带项，用户 2026-09-22 批）；solo / afv / routing 单独改走 `setInputAudio`（023 五） | 同上 | 混音（W2-E 转成 C 参数） | 从快照读 |
| `PlaybackSettings` | {paused, restartOnProgram, seekSeconds?, seekTick?}（提案 021）：前两个是目标随文件存，后两个是一次定位请求的瞬态（`resetTransientState` 清、nil 不写键）；只对 `InputSource.file` 有意义 | 状态机（setPlayback / seekPlayback / 换 PGM 时的 restartOnProgram） | 组装方（App InputRuntime / headless 看到 (seekTick, seekSeconds) 变了就 seek 一次，paused 变了就 pause / resume，不重建） | 从快照读 |
| `InputConfig` | {number, name, source, settings, color?（提案 023 四：`InputColor`，nil / 缺键 = 无分类、nil 不写键）}；number 合法范围 `numberRange` = 1…16（提案 032，见下"输入编号的上限"）；`MixerState.inputs` 和 `Show.inputs` 的元素 | 状态机 | 所有人 | 值类型 |
| `InputColor` | {red, orange, yellow, green, blue, purple}（Finder 标签那六种 = W5-H 的 rawValue；023 四）；分类**名字**留在 `Show.layout["inputCategoryNames"]`，契约不解释 | setInputColor / addInput | 多画面标签、Stream Deck、API | — |
| `Input` 协议 | 运行对象：number / name / kind / state / videoSlot / audioRing / start / stop；纯音频输入 videoSlot = nil（口径见下） | 输入实现 | 引擎、UI | start/stop 普通线程 |

每路输入的音频参数只存一份，在 `inputs[i].settings.audio`（prompt 里的 "audio.perInput"）；`AudioState` 里只有总线、AFV 总开关、监听、对齐延迟。

**`InputSource` 的两处格式（提案 008，用户 2026-09-22 确认）**：
- `decklink(deviceID:connection:)`：deviceID = `peid:<BMDDeckLinkPersistentID 十进制>`（卡有该属性时）/ `model:<型号>#<同型号内序号>`（老卡）/ 空串 = 第一台有输入的卡；connection nil = 不改卡上的当前设置。
- `ndi(sourceName:bandwidth:jitterBufferFrames:)`：源名是 `"机器名 (源名)"`；抖动缓冲 0–2 帧，它同时定义这一路的 `Frame.pts`（见 §3）。
两个 case 写出时缺省值不写（connection nil 不写键），老文件缺键按默认解（highest / 1 / nil）；其余 case 的 JSON 形态一个字节没变。

**声道映射 `channels`（提案 014，用户 2026-09-23 批）**：`audio(deviceUID:channels:)`、`decklink(deviceID:connection:channels:)`，默认 `[]`。
值是源的声道下标（从 0 起），环的第 d 路取 `channels[d]`：空 = 取前几路（单声道复制到所有声道、源比环少时复制最后一路）；
比环的声道数短时缺的复制最后一项（`[4]` = 单声道话筒插在第 5 路，两个声道都取它）；多出来的项忽略；越界钳到源的声道范围。
它是采集侧参数（改它 = 重建这一路输入），所以在 `InputSource` 不在 `InputAudioSettings`。空映射写出时不写键（老文件读进来再写出去形态不变），
老文件缺键按 `[]` 解；`Contracts014Tests` 钉住。实现口径的唯一一份在 `SwitcherInputs.InputChannelMap`（纯音频设备与 DeckLink 共用）；
DeckLink 开的内嵌音频路数 = max(`Options.audioChannels`, 映射用得上的最大下标 + 1)，按 SDK 认的 2 / 8 / 16 往上取。
`audio` 的 `deviceUID` = Core Audio 的 `kAudioDevicePropertyDeviceUID`，空串 = 跟随系统默认输入。

**纯音频输入（`InputSource.audio`，`Input.videoSlot` 为 nil；W2-A2 报告 §4 第 2 条，用户 2026-09-23 定）**：引擎对这一路挑帧恒为 nil（组装方不登记帧槽，或登记一个没人推的空槽——App 现在就是后者）；
它照样能被选进 Program / Preview / 叠加，画面按"没帧"画黑场，音频照常按每路 AFV 走（切到它就出它的声）；多画面里它的格子画占位（名字 + 电平表），
不是黑画面。引擎与渲染器的行为满足前两条（没槽 → nil → 画黑）；多画面占位格（深灰底 + 电平表 + 名字，电平表不看 `MultiviewLayoutSettings.meters`）W3-B2 做了，
App 接线 W3-E2 做了（reports/issues/W2A2-w3-compositor2-multiview-audio-only-cell.md、W2A2-w3-app-3-audio-device-input-wiring.md）。

**`InputState` 的 noSignal / error 分界（W3-A 口径，用户 2026-09-22 定）= 会不会自己好**：驱动没装 / 设备不在 / NDI 源还没出现 / 显示器拔了 → `noSignal` + `lastError` 文案（装上、插回、源上线就自己恢复）；SDK 没编进来 / 起流失败 / 权限被拒 → `error(message:)`（不会自己好）。

**`InputAudioSettings.afv`（每路 AFV 参与开关，用户 2026-09-22 批）**：true（默认，老文件缺键也是 true）= 跟随视频，`AudioState.afv` 开时按 PGM 门控、转场时进交叉淡变；false = 门控增益恒 1，一直按自己的推子出声，也不进转场的 from / to（主持人话筒）。全局 `AudioState.afv` 关时所有路都恒 1，这一位不起作用。走 `setInputSettings` 整体替换，或 `setInputAudio(input:solo:afv:routing:)`（提案 023 五，P5-2）单独改：三个参数都可选、nil = 不动（JSON 不写键）、非 nil 整体替换该项，输入不存在拒，全 nil 或全与现状相同 applied = false——快捷键 / MIDI 不用再按快照改一位整体写回（W5-J §4 的竞争从根上去掉）。

**文件输入的播放控制（提案 021，用户 2026-10-11 批，P5-2 落地）**：`InputSettings.playback{paused, restartOnProgram, seekSeconds?, seekTick?}`，缺键 = 默认（播放、不从头、无定位），写出写全、nil 不写键；别的 kind 照存不读。
`setPlayback(input:paused:)` 改目标（相同值 applied = false）；`seekPlayback(input:seconds:)` 记一次定位请求 `(seekTick = 这一拍, seekSeconds = seconds)`（从头播 = 0；同一拍同一位置再发 applied = false）；
两条命令输入不存在 / kind != file / 秒数负、非有限或超过 `PlaybackLimits.maxSeekSeconds`（一周，031）由校验器拒（HTTP 400，reducer 同判）。**切上 PGM 时从头播**：新 PGM 那一路 `restartOnProgram` 时，reducer 在换人那一拍（cut / auto 完成 = 开始拍 + 时长 / T-bar 提交 / setProgram 换成它）写 seekSeconds = 0、seekTick = 那一拍——与手发 seekPlayback(0) 同一条路，组装方不用认第二种信号；换走的那一路、PGM 没变、在 PVW 上预览都不写；暂停中照样定位、仍暂停（两个目标各管各的，要"切上就播"再发 setPlayback(paused: false)）。
reducer 只记状态，真正的 pause / resume / seek 由组装方（App `InputRuntime` / headless）按快照变化交给 FileInput，不重建输入（"从头"的首帧晚 1–2 拍，FileInput 的 seekLead）。"设循环"不加命令：`InputSource.file(endAction: .loop)` 走现有 `setInputSource`，运行表遇到只有 endAction / rate 变了不重建、交给 FileInput 就地改（101）。瞬态 `seekSeconds` / `seekTick` 由 `MixerState.resetTransientState()`（载入节目）清。App 格子按钮 / 输入设置"来源"节、Hotkeys / MIDI 的动作、VMixCompat 的 PlayPause 一族映射各归各的会话。

**文件播放速率与定位秒数的不变量（提案 031，用户 2026-10-17 批，P5-4 落地；Codex 审查 D01：越界的值在 FileInput 的 precondition / 取倒数 / Int64 换算上整个进程崩）**：两个常量三处共用——
`FileSource.rateRange` = 0.1…8（界面的"播放速率"控件没有自己的范围——App 的添加输入 / 输入设置里是不设范围的数字框——按 031 默认；W2-A4 实测 8 倍速带音频不饿）、`PlaybackLimits.maxSeekSeconds` = 7 × 86 400 = 604 800 秒（一周；文件本身的时长再由 FileInput 钳）。
非有限数、负数、越界都算非法（`ClosedRange.contains` 对 NaN / ±∞ 给 false）：
- 节目文件：`MixerState.validate()` 对 file 来源的 rate 不在范围抛 `MixerStateError.fileRate(input:rate:)`（Show.load / loadShow 先搬迁再 validate，读到不打开，与别的不变量同一处理）；
- API：`CommandValidator` 对 `setInputSource` / `addInput` 的 file 来源"播放速率必须在 0.1–8 之间"、`seekPlayback`"定位秒数必须在 0–604800 之间（一周）"（HTTP 400），reducer 同判、原样返回；
  `setInputSettings` / `addInput` 整体带进来的 `playback.seekSeconds` 由 `clamped()` 钳到 [0, 一周]（不拒，与 021 钳负数同一做法）；
- FileInput（117）：`precondition(rate > 0)` 改成钳进 `rateRange` + `lastError`，seek 先用 Double 钳到 [0, 时长] 再换整数——117 合入之前直接构造 FileInput 的路径仍会崩。
老文件 file 来源缺 `rate` 键 = 1 照读（P5-4 之前缺键直接 keyNotFound、整份节目读不进来；写出照旧总是写 rate，JSON 形态不变）。

**输入编号的上限（提案 032，用户 2026-10-18 批，P5-5 落地；W2-C4 查出的 S1：主 API 加一路 2^62 号输入后，开着兼容层时 TALLY 串按最大编号 `reserveCapacity` 分配失败崩、XML 按 1…最大编号写占位卡死）**：
`InputConfig.numberRange` = 1…16（App"添加输入满 16 路"、引擎默认 `maxInputs`）。同一条边界两处共用——
- 节目文件：`MixerState.validate()` 对编号超过 16 的输入抛 `MixerStateError.inputNumber(input:)`（0 / 负数照旧 `reservedInputNumber`；Show.load / loadShow 先搬迁再 validate，读到不打开，与别的不变量同一处理）；
- API：`CommandValidator` 对 `addInput` 的编号不在 1…16"输入编号必须在 1–16 之间：<n>"（HTTP 400，原来的"必须 ≥ 1"并进这一句），reducer 同判、原样返回；按编号取输入的命令照旧"输入 n 不存在"（越界的编号进不了状态）。
解码不拒（编号仍是一个整数，JSON 形态不变）；兼容层 TALLY / XML、App / headless 的 `Engine(maxInputs: max(16, 最大编号))` 等按编号分配的读者从此最多 16。引用（叠加 / Stinger / 多画面格子 / 输出来源里写的编号）不查，照旧按"没有这路"处理。

**输入分类颜色（提案 023 四，用户 2026-10-11 批，P5-2 落地）**：`InputConfig.color: InputColor?`（nil / 缺键 = 无分类，nil 不写键）；`setInputColor(input:color:)`（nil = 清掉；输入不存在拒；相同值 applied = false）；`addInput` 带的照收；`removeInput` 删掉这一路就没了（编号再给别的输入用不继承）。
分类名字按 (a) 留在 `Show.layout["inputCategoryNames"]`（名字只是界面标签，API / Stream Deck / 多画面要的是颜色；要 API 也能改名再升 (b) `Show.categoryNames` + 命令）。W5-H 存的 `Show.layout["inputCategories"]`（`{"<编号>": "<颜色>"}`）由 `Show.migratingLegacyInputCategories()` 搬进各路 `color`（有键按原值搬、认不出的颜色 / 不存在的编号跳过、正式字段已有值的不动、搬完删键、幂等），**不并进 `Show.load` / `migratingLegacyKeys()`**（与 025 同一做法：现在的 App 还在读写 layout 键，App 切换时在 Show.load 后调一次，归 100 之后的 App 会话或 G8 胶水）。多画面标签画色点（渲染器读 `InputConfig.color`）、Stream Deck 按钮颜色归各自的会话；VMixCompat 不映射。

**`KeyerSettings` 四个参数的口径（提案 009；渲染器 `Compositor.metal` 的 `applyKey` 是定义）**：

| 字段 | 口径 |
|---|---|
| `keyColor` | full-range 8-bit RGB 的键色。渲染器按 BT.709 换成色度 (Cb, Cr)（归一化到 −0.5…+0.5），**只比色度不比亮度**：绿幕上的阴影（同色度、低亮度）也被抠掉（设计方案 §5 的第一版取舍） |
| `tolerance` 0–1 | 完全抠掉的色度距离半径 = `tolerance × 0.5`；像素色度到键色色度的欧氏距离 d ≤ 半径 → alpha 0 |
| `softness` 0–1 | 边缘柔化带宽 = `softness × 0.25`（色度距离单位）；d ∈ [半径, 半径 + 带宽] 时 alpha 用 smoothstep 从 0 升到 1；0 = 硬边 |
| `spillSuppression` 0–1 | 留下来的像素把色度在键色方向上的正分量减掉这个比例（c′ = c − s·max(0, c·k̂)·k̂），亮度不变，溢色边缘变同亮度的灰而不是变暗；键色是灰（无色度方向）时不做 |

输出是预乘 alpha（`rgb × alpha`），进 source-over 混合管线；抠像对该输入出现的每一处（PGM 底、转场新画面、叠加、PVW、多画面缩略图）都生效。

**`EffectSlot` 的 id 与参数键（提案 012 C；设计方案 §7 用苹果 ParametricEQ / DynamicsProcessor / PeakLimiter，与 `SwitcherAudio.BusEffectChain` 的三个 setter 一一对应；提案 024 (b) 加自写压缩器 `compressor` 与 `peakLimiter.ceilingDb`，用户 2026-10-03 批、P5 落契约、C 实现归 W1-D3 / prompt 102）**：

| id | params（全部 number；三个苹果单元的范围 = 引擎钳位 `SwitcherAudio.EffectParameterRanges`，表在 reports/w5-audio-bus-effects.md §1.5，契约不重复；024 新加的键范围与默认值在这里定） |
|---|---|
| `parametricEQ` | `centerHz`、`q`、`gainDb`（一条链里连续多格 = 多段，≤ 16，见下） |
| `dynamicsProcessor` | `thresholdDb`、`headroomDb`、`expansionRatio`、`attackSeconds`、`releaseSeconds`、`overallGainDb`（苹果 AUDynamicsProcessor，没有固定比例；024 之后是"高级"项） |
| `compressor` | `thresholdDb`（−60…0 dBFS，默认 −20）、`ratio`（1…20，默认 4，n:1）、`kneeDb`（0…24，默认 6；0 = 硬拐点）、`attackSeconds`（0.0001…0.2，默认 0.005）、`releaseSeconds`（0.01…3，默认 0.1）、`makeupGainDb`（0…24，默认 0）。自写 C 压缩器（024 (b)）：不用前瞻、组延迟按设计 0 帧，装格 / 改参数时用冲激法量实际延迟、量到的进 A/V 对齐（024"批后的附加要求"）；与 `dynamicsProcessor` 二选一占同一格 |
| `peakLimiter` | `attackSeconds`、`decaySeconds`、`preGainDb`，另加可选 `ceilingDb`（−20…0 dBFS，默认 0）：AUPeakLimiter 的天花板固定 0 dBFS，实现为同一格内限幅之后的输出增益（C 侧渲染完乘一个系数，无分配、不多占格），替掉 W5-C "预增益 +x、总线增益 −x" 的表达法（024 顺带 (2)） |

`parametricEQ.q` 的口径（024 顺带 (1)，用户 2026-10-03 定"按 G6 的建议"）：**经典 Q**——带宽 = 增益为峰值一半（dB）处的上下边频之比，BW = 2/ln2 · asinh(1/(2q)) 倍频程（q = √2 → 1 oct）；
AUNBandEQ 的带宽参数就是这个定义（设计方案 §7 原来对的 AUParametricEQ 的 Q 随增益变，不是这个口径；W5-C 之前 EQ 从没生效过，没有老行为要兼容）。
**一个 EQ 格（AUNBandEQ）最多 16 段**：连续的 `parametricEQ` 格合成一格；**每条总线最多 3 格**（被别的效果隔开的 EQ 另占一格），超出的不装。
链的顺序 = 处理顺序；`enabled = false` 的格旁路。`InputSettings.effects`（每路）与 `BusState.effects`（每总线）同一套；总线那一半 W5-C 起生效，每路的归 W1-D3。认不出的 id / 键实现跳过，不报错。
视频效果格由合成会话定义，目前没有：`border`（画中画边框）是提案 010 落地前的过渡做法，正式字段是 `OverlayState.border`；渲染器读它的后备 W3-B2 删了，
`Show.load` 的搬迁把启用的那格搬进用到这路输入的叠加通道，然后把所有 `border` 格清掉（P4，见 §2.8）。

### 2.5 状态（MixerState.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `MixerState` | 不可变快照：format, inputs, program, preview, transition, ftb, overlays[4], audio, outputs；`validate()`（只查结构不变量，不查引用，见下）、`tally(ofInput:)`、`tallies` | 状态机（reduce / advance） | 渲染（每拍一次）、音频、UI、API、录制 | 值类型；经 `MixerSnapshot` 发布 |
| `MixerSnapshot` | final class {state, sequence, tick, publishedAt}，不可变；状态机用原子指针交换发布；`publishedAt` = 发布时刻 host time（提案 003 §B，C2 从它算） | 状态机 | 渲染、音频、控制 | 读方只 retain，不进 actor |
| `TransitionState` | {type, durationTicks, progress 0–1, source auto/tbar, startTick, wipe, stinger, slots[4]: [`TransitionSlot`], currentSlot 1–4 或 nil}（slots / currentSlot 是提案 020）；空闲时 type/duration 就是"下一次转场"的选择（= 当前那组）；wipe / stinger 由 `setTransitionParams` 改（提案 016，转场进行中被拒）；进行中（isActive：auto 从应用命令那一拍到对调前一拍、T-bar 推杆在 (0, 1)）拒收 fade / setTransition / setTransitionParams / autoTransition / setPreview / setProgram / useTransitionSlot，cut（立即完成）与 tbar（接管）照收（提案 023），setTransitionSlot 照收（只改槽）；`stinger.input` 在 removeInput 删掉那一路时置 nil（P4，020 扩到四个槽）；`currentGroup` / `select(slot:)` / `slotIndexMatchingCurrentGroup(preferring:)` 是当前那组与槽之间的拷贝 / 对号工具；当前那组是没选输入的 Stinger 时 autoTransition 拒收（提案 029，见下"转场槽"） | 状态机 | 渲染（只看当前那组，一个字节不动） | — |
| `TransitionSlot` | {type, durationTicks, wipe, stinger}（提案 020）：一个槽 = 一套完整的效果 + 时长 + Wipe + Stinger 参数；`count = 4`、`indexRange = 1...4`；`factoryDefaults(for: format)` = 1 Fade 0.5 s / 2 Wipe 1 s（leftToRight、软边 0）/ 3 Zoom 1 s / 4 Stinger 1 s（输入 nil、换底拍 0），秒按帧率 round 换拍（60 / 59.94 → 30 / 60 / 60 / 60，30 → 15 / 30 / 30 / 30，25 → 13 / 25 / 25 / 25）；`isStingerWithoutInput` = type 是 stinger 且 stinger.input 是 nil（提案 029：这种槽不执行，计算属性、不进 JSON） | setTransitionSlot / 搬迁 / newShow | 状态机（useTransitionSlot 拷进当前那组）、界面 / Stream Deck 按槽显示 | — |
| `FadeToBlack` | {on 目标, durationTicks, level 当前黑比例, startTick} | 状态机 | 渲染、音频（可选淡出 Master） | — |
| `OverlayState` | {input?, on 目标, rect, animProgress 0–1, animation, startTick, border?, anchor, previewOn}（提案 010）；`isVisible` | 状态机 | 渲染 | — |
| `OverlayAnimation` | {kind, durationTicks, slideFrom?}（提案 010：slideFrom nil = 离 rect 最近的边）；`OverlayAnimation()` = cut 0 拍不变；**新节目**四路叠加默认 = `OverlayAnimation.defaultFade(for: format)` = fade、round(0.5 s × 帧率) 拍（提案 027，用户 2026-10-10 批）：`MixerState.newShow(format:outputs:)` 建出来就是它，App 的 emptyShow 也调它；老文件的 animation 照读 | 状态机 | 渲染 | — |
| `OverlayBorder` / `OverlayAnchor` / `OverlayEdge` | {width 占节目高的比例（渲染器钳 0–0.1，界面只给到 0.05，更宽的只能从 API / 节目文件给）, color} / 九宫格锚点 / {left, right, top, bottom}（提案 010） | 同上 | 渲染 | — |
| `AudioState` | {buses[4] 顺序 = Bus.allCases, afv 总开关, monitorMode, alignmentFrames = 2048, monitorPoint（提案 007）, monitorSource（提案 026：耳机 / 监听总线上听哪条总线，master 默认 / busA / busB / headphones；headphones = 听耳机总线自己，只听每路 routing.headphones 送出的那些（用户 2026-10-12 允许，P5-3；P5 时判无效、命令被拒、文件里读成 master）；缺键 master，四个值按字面读写；独听仍优先，四个值同一口径；混音器按它选耳机出口，W1-D3 `SW_CMD_MONITOR_SOURCE`）} | 状态机 | 混音、UI | — |
| `MonitorPoint` | {preDelayLine（默认）, postDelayLine}：耳机 / 监听总线取对齐延迟线之前还是之后（提案 007） | Show / 设置面板 | 集成层填 `AudioEngineConfiguration` | — |
| `OutputState` | {number, kind, name, enabled 目标, settings: `OutputSettings`}；kind = multiview 的 enabled = 要不要把多画面 NV12 送给下游，布局与它无关（见下） | 状态机 | 输出实现、UI | — |
| `OutputSettings` | {source, video?, audio?, record?, stream?, multiview?（010）, display?（013）, extra（各输出会话的附加项，NDI 的 ndi.groups / ndi.conversion 在用）}；录制输出的 source 只认 program / input(n)，写进来的 preview / multiview **照录 PGM**、校验器不拒（023 二 (a)） | Show / 命令 | 编码、录制、推流、多画面、外部显示 | — |
| `RecordSettings` | {directory, fileNamePattern, container（**废弃**，023 二：运行时从不读、文件一律 .mov，缺键 = mov、写出仍写、不加 @available；要 .mp4 用 remuxToMP4）, fragmentIntervalSeconds, remuxToMP4, armed（025，缺键 true）, ownFormat（025，缺键 false）}；armed = 参与"全部录制"，ownFormat = ISO 路用自己的编码参数而不跟主录制 | Show / setOutputSettings | 录制器、App 底栏 / 录制页（OutputLinkage） | — |
| `StreamSettings` | {url, streamKey, reconnectMaxSeconds, followFirst（025，缺键 false）}；followFirst = 编码参数跟编号最小的 stream 输出（地址 / 密钥 / 重连上限不跟） | Show / setOutputSettings | 推流、App 推流页（OutputLinkage） | — |
| `MultiviewLayoutSettings` / `MultiviewCell` | {preset, custom[], safeArea, meters} / {source, rect}（提案 010；`OutputSource.multiview` 作格子源无效，渲染器忽略）；meters = 画真实电平（`Stats.audio.meters` 经 `setMeters` 喂进渲染器：输入格画该路、PGM 格 = Master、PVW 格 = 当前 PVW 那路），纯音频输入格总是画、不看它 | Show / setOutputSettings | 渲染（多画面） | 解析只在快照 sequence 变化时做 |
| `DisplayOutputSettings` | {displayID?（CGDirectDisplayID；nil = 主显示器）, fallbackToMain（默认 false = 显示器不在时黑着等、不动主屏；提案 013 定 true，015 改 false 与运行时一致）} | Show / setOutputSettings | 外部显示运行表 | — |
| `Tally` | {program, preview}，由快照推导 | 契约代码 | UI、API、多画面、外部 tally | — |

progress 的意义：新画面（= preview 输入）盖在旧画面上的比例。auto 转场第 s 拍应用命令，第 s + k 拍 progress = k / durationTicks，到 1 时状态机对调 program/preview 并回空闲（W1-B）。运行时统计（帧数、丢帧、码率）**不在** OutputState 里，在 Stats（铁律 4）。

`StingerParams.cutAtTick`（W3-B 口径，用户 2026-09-22 定）：第 s 拍应用命令时 progress = 0（渲染器什么都不叠），第 s + 1 拍才是 stinger 第一帧，所以 **cutAtTick 0 与 1 等价**；cutAtTick ≥ durationTicks 等于"完成时换"。`TransitionRenderer.stingerShowsNewUnder` 是定义。

**输入引用的口径（P4，用户 2026-09-27 定）**：状态里四处引用输入编号——`program`、`preview`、`overlays[k].input`、`transition.stinger.input`。removeInput 把前两个置 0（黑场）、后两个置 nil；
`validate()` 只查结构不变量（叠加恰好 4 个、总线顺序、输入编号在 1…16（032）且不重复、输出编号不重复、转场槽 4 个，外加 031 的一条取值：file 来源的速率在 `FileSource.rateRange` 里），**不查引用**，渲染器对不存在的输入按"没有这路"画（跳过）。
P4 之前 removeInput 不清 Stinger 引用，那时存下的节目文件里的悬空编号由搬迁清掉（§2.8）；引用存在与否在命令入口由 `CommandValidator` 查（setTransitionParams / overlay / setPreview……）。

**转场槽（提案 020，用户 2026-10-11 批，P5-2 落地；"请用户定的点"按提案默认）**：`TransitionState.slots` 恰好 4 个（`validate()` 查，`MixerStateError.transitionSlotCount`）、`currentSlot` nil 或 1…4（`transitionSlotIndex`）；
currentSlot = 当前那组（type / durationTicks / wipe / stinger）对应哪个槽，nil = `setTransition` / `fade` / `setTransitionParams` / API 直接给的、不对应任何槽。T-bar / 回车 / `autoTransition` 用的永远是当前那组，所以"跟当前槽"不需要别的字段；渲染器只看当前那组。
- `setTransitionSlot(slot:config:)`：只改 `slots[slot − 1]`，**转场进行中也收**；durationTicks 钳 ≥ 0、softness 钳 0–1、cutAtTick 钳 ≥ 0（与 016 同口径）；slot 不在 1…4、stinger.input 指向不存在的输入由校验器拒；改的若正好是 currentSlot 且空闲，当前那组同时重拷；进行中的那一次按开始时的参数走完，**完成或取消那一拍重拷**（完成：`completeTransition` 在 currentSlot 非 nil 时总是按槽重拷，幂等，cut / T-bar 提交同样走它；取消：T-bar 拉回 0 那一拍 reducer 的 `tbar` 同一句重拷——020 追加，用户 2026-10-17 定、P5-4 落地，原来取消不重拷、下一次回车执行改之前的配置）；currentSlot = nil 时两处都不重拷；相同配置 applied = false。
- `useTransitionSlot(slot:start:)`：把槽拷进当前那组、currentSlot = slot；start = true 同时开始 auto 转场（cut 或时长 0 = 原子对调），一拍内原子完成，代替 UI 一次发三条；start = false 只选中；转场进行中被拒；start = false 且已是当前槽、当前那组与槽相同 → applied = false。**start = true 而槽是没选输入的 Stinger 时拒收**（提案 029，下一条；020 原来是照常开始）。
- **没选输入的 Stinger 不执行（提案 029，用户 2026-10-12 定，P5-3 落地）**：判定只有一条 `TransitionSlot.isStingerWithoutInput`（type = stinger 且 stinger.input = nil；出厂槽 4 就是）。
  `useTransitionSlot(slot, start: true)` 遇到这种槽、`autoTransition` 遇到要执行的当前那组是这种（当前槽是这种槽，**或 setTransition / setTransitionParams 直接给的、currentSlot = nil 的也算**——否则从这条路绕过去还是一次延迟硬切；按"要执行的当前那组"判比提案正文"当前槽是这种槽"多拒这一种，用户 2026-10-17 定维持）：
  校验器 HTTP 400（文案"转场 n 是 Stinger、还没选输入"，当前那组不对应槽时"当前转场是 Stinger、还没选输入"）、reducer 原样返回（applied = false；不选中、不开始）。
  这两个条件只随命令变（槽的配置 / 空闲时的当前那组），所以入口就拒（与 `setOutputEnabled` 对录制 / 推流输出的做法一样），`testValidator_agreesWithReducer` 两边一致；autoTransition 在转场**进行中**校验器不判（本来就由 reducer 忽略，完成或取消那一拍当前那组还可能按槽重拷）。
  不受影响：`useTransitionSlot(start: false)`（只选中，之后 T-bar 用）、`cut`（原子对调，不看类型）、`fade`（总是 Fade）、`tbar`。**T-bar 推这样的当前那组（P5-3 核对）**：reducer 照收（progress = 推杆位置、source = tbar，到 1 提交、拉回 0 取消，与别的类型同一条路）；
  渲染器（`TransitionRenderer.stingerShowsNewUnder`）在 round(progress × durationTicks) ≥ max(cutAtTick, 1) 时把底换成 PVW、不叠任何东西——即推过换底拍对应的那一格画面就整个换成新画面，拉回去又换回旧的；cutAtTick ≥ durationTicks 时推的过程中不换、到 1 提交才换；durationTicks = 0 时一推就换。
  控制层 / 兼容层 / Stream Deck 的提示（feedback、Transition n → 409、showAlert）归 W5-O（prompt 112）；App 界面三处本来就先弹输入选择（X18），不变。
- `setFTBDuration(ticks:)`：`ftb.durationTicks = ticks`（存拍，界面按秒填）；FTB 渐变**进行中**按"当前电平对应的起点"回拨 startTick（`equivalentStart`），电平从当前值按新时长继续走、不跳变，0 = 立即到位；相同值 applied = false；ticks < 0 校验器拒；不并进 `ftb(on:)`（W2-C 客户端在用它的 JSON 形态）。
- 原有 fade / setTransition / setTransitionParams 语义不变，执行后 currentSlot = 当前那组仍对得上的槽（优先原来那个），对不上任何槽 → nil（R3a C 附 3 的"不再对应任何槽"）；`removeInput` 清引用的规则扩到四个槽。
- 默认与搬迁：`TransitionState()` 不知道帧率，slots = 60 fps 的出厂四槽、currentSlot 自动对号（fade 30 = 槽 1；`TransitionState(type: .cut, durationTicks: 0)` 这种裸状态 = nil）；`MixerState.newShow(format:)` 按节目帧率重算四槽、当前那组 = 槽 1（Fade 0.5 s）；`MixerState()` / `MixerState(format:)` 仍是 60 fps 出厂槽。020 之前的文件 / API 节目缺 slots → 裸解码 `[]`、`Show.migratingLegacyKeys()` 补齐（§2.8），`validate()` 要求恰好 4 个所以没经搬迁的进不了状态机；**loadShow 的校验器改成先搬迁再 validate**（否则老节目会被 400 拒，P4 报告 §5 第 3 条预告过）。
- 界面（转场列、"切换"菜单、T-bar 行、格子"转场"按钮、FTB 右键）、Hotkeys / MIDI 的 `ControlAction`（执行 / 选中转场 n，默认表 ⌥1–⌥4）、VMixCompat 的 Transition1–4 / SetTransitionEffect1–4 / SetTransitionDuration1–4、Stream Deck 转场按钮归 100；SwitcherRender 不改。

**`RecordSettings.container` 与录制来源（提案 023 二，用户 2026-10-11 批，P5-2 落地）**：`container`（mov / mp4）**废弃**——运行时从不读它、文件一律写 .mov，要 .mp4 用 `remuxToMP4`（停止后转封装，失败保留 .mov），两者表达同一件事；字段与枚举留着（删了是破坏性 wire 变更），缺键 = mov、写出仍写、不加 `@available`（App 的 OutputSettingsPanel 还读它给"写着 .mp4 又没开转封装"的提示）。录制输出的 `source` 只认 program / input(n)：从 API / 节目文件写进来的 preview / multiview 按 program 录（录制器的来源选择只认这两种），校验器不拒（(a)）；界面上录制来源只给 PGM / 某路输入。

**多画面输出的 enabled（W3-E2 报告 §4 第 2 条）**：kind = multiview 的输出的 enabled = 要不要把多画面 NV12 送给下游——enabled 且 `settings.source` = `.multiview` 时渲染器每拍多转一次 NV12 填 `RenderedFrame.multiview`（§3）；
多画面**布局**取第一个 kind = multiview 的输出的 `settings.multiview`，与 enabled 无关。App 新建的那个只承载布局、enabled = false；`scenarios/g4-show.json` 里那个是 enabled 的（headless 每拍多转一次，没有下游）。

`OutputState.enabled` 的口径（提案 007 B 第 1 条）：节目文件里的 enabled **只对 headless 的场景文件生效**（t0 起录 / 起推）；App 打开任何节目文件（含退出时自动存的 LastSession）时把 record / stream 的 enabled 清掉，这两类输出只由用户动作（按钮 / 快捷键 / API）起（App 的 `ShowDocuments.stoppingOutputs`）。record / stream 的 enabled 由 startRecord / startStream 置，其余 kind 由 `setOutputEnabled` 置（提案 012）。

`RecordSettings.directory` 的相对路径（提案 007 B 第 2 条）：headless 相对进程工作目录；App 相对 `~/Movies/PlusMix`（W4-D 改名前是 `~/Movies/Switcher`；`MixerState.swift` 里 `RecordSettings.directory` 的注释还写着旧名，等下一次契约会话顺手改）。

**W5-I 的三个 App 层标记升正式字段（提案 025，用户 2026-10-10 批，P5 落地）**：`RecordSettings.armed`（缺键 true）/ `RecordSettings.ownFormat`（缺键 false）/ `StreamSettings.followFirst`（缺键 false），写出总是写全；
025 之前 App 放在 `OutputSettings.extra` 的 `app.record.armed` / `app.record.ownFormat` / `app.stream.followFirst` 由 `OutputSettings.migratingLegacyAppFlags()`（`Show.migratingLegacyAppFlags()` 对每个输出各做一次）搬进字段并清键，
**不在 `Show.load` / `migratingLegacyKeys()` 里自动调**：App 在 Show.load 后调一次、读写切到字段（归 101 / W5-N），之后可以并进 `migratingLegacyKeys()`。headless / API 的"全部录制"要认 armed 归控制会话；VMixCompat 不映射。`Show.schemaVersion` 不升。

录制器的停止边界（提案 007 B 第 3 条）：`Recorder.stop(atTick:)` 给拍边界，两轨都由录制器裁到该拍点，越界块只计数不写；边界可以在到达之前预告（`setStopTick`）；nil = 最后一个已收帧的下一拍。

### 2.6 命令（Command.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `Command` | 枚举，42 个 case（对照见 §8；P3 按提案 010 / 012 从 27 加到 33，W3-E2 按提案 016 加 setTransitionParams，P5 按提案 026 加 setMonitorSource，P5-2 按提案 020 加 setTransitionSlot / useTransitionSlot / setFTBDuration、021 加 setPlayback / seekPlayback、023 四 / 五加 setInputColor / setInputAudio；P5-3 不加 case：026 的 setMonitorSource 起 headphones 合法、029 的 useTransitionSlot(start: true) / autoTransition 对没选输入的 Stinger 拒收；P5-4 不加 case：031 的文件速率 / 定位上限入口拒、020 的 T-bar 取消重拷）；JSON 形态 `{"fade":{"durationTicks":30}}`、`{"cut":{}}`；可选参数 nil 不写键（`setInputAudio` / `setInputColor`） | UI、快捷键、MIDI、API、脚本 | 状态机 | 普通 |
| `IssuedCommand` | {sequence, issuedAt, command}：命令总线（W2-C）加信封；`issuedAt` = 命令进总线的时刻（服务端 host time，不是客户端发出时刻；提案 003 §C） | 命令总线 | 状态机（按 sequence 严格顺序） | 普通 |
| `CommandReceipt` | {sequence, appliedTick, applied}；`applied` = 状态真的变了（false = reducer 按规则忽略了它，提案 003 §A；结构性非法的在总线入口就被拒，到不了回执） | 状态机 | 总线、API | 普通 |
| `MixerReducing` 协议 | `reduce(state, command, at tick)`、`advance(state, to tick)`，纯函数，实现在 W1-B | W1-B | 状态机、Control 的测试 | 纯函数 |

### 2.7 统计（Stats.swift）

| 类型 | 是什么 | 谁写 | 谁读 | 线程 |
|---|---|---|---|---|
| `Stats` | 测试标准 §7 那一行，键名逐字：ts, tick, render_ms, missed_render, jitter_ms, per_input{fps,dup,drop,latency_ms,latency_max_ms}, encoder[{output,skipped,bitrate,frames,dropped,disk_free_mb,reconnects,connections,state,uptime_s,disconnects,last_error,attempt}]（output / connections 是 019；uptime_s / disconnects / last_error / attempt 是 022）, display[{output,kind,frames,dropped,undelivered,state}]（P3 提案 013，undelivered 是 018）, audio{dropouts,underruns,discontinuities,meters{buses[{bus,peak_db,rms_db,true_peak_db,lufs_m,lufs_s,lufs_i,lra}],inputs{n:{peak_db,rms_db}}},effects{buses[{bus,latency_ms,measured_latency_ms}],inputs{n:{latency_ms,measured_latency_ms}}}}, rss_mb, cpu_pct, gpu_pct, video_delay_ms（022 B2）（P2 按提案 001 / 002 / 004 / 005 扩，2026-09-18；rms_db 是 017，2026-09-24；022 是 P5-2，2026-10-11；audio.effects 是 030，P5-4，2026-10-18） | 引擎每秒汇总一次（W1-B）：encoder[] 由各输出的 `statsEntry` 填（`Recorder` / `StreamOutput` / `NDISender`），audio 由 `AudioEngine.audioCounters` 填（W2-E 集成层；effects 从 `AudioEngineStatus` 拷，030），per_input 的 L1 由引擎填（W1-B2）；写 jsonl 的是 TestKit（W1-A） | UI 状态行、API、StatsSummary | 汇总在普通线程；来源计数是原子量 |

口径：`render_ms` = 窗口内"拍点时刻 → GPU 完成"平均 ms（V1）；`jitter_ms` = 窗口内 |派发时刻 − 理想拍点| 最大值（V3）；计数类（missed_render, dup, drop, skipped, dropouts, underruns, frames, dropped, reconnects, discontinuities）全是自启动累计，相邻两行相减得窗口增量；`fps` = 窗口内该输入 push 帧数 / 秒；`bitrate` = 窗口平均 bit/s；`ts` = Unix 秒。`Stats.jsonLine()` / `parse(line:)` 是唯一的编解码入口。

P2 加的字段（口径全文在 Stats.swift 的文档注释）：
- `per_input[n].latency_ms` / `latency_max_ms`（提案 005）：窗口内 L1（帧交给第一个 FrameConsumer 的时刻 − 该帧 `Frame.ingressTime`）的平均 / 最大 ms，只算每拍第一次用到的帧，窗口内没样本写 0；引擎侧算法归 W1-B2（prompt 42），之前引擎写 0。定义不变、但含视频延后（提案 028 第 4 条）：videoDelay 补偿下"交给第一个 FrameConsumer 的那一刻"在延后之后，L1 含当时的 L（开着压缩 / 限幅时多 5–35 ms）；**判定 L1 时扣掉同一行的顶层 `video_delay_ms`，阈值数字不动**（用户 2026-10-11 定；gate4 报告脚本的判定归 G8b）。
- `encoder[i].frames`（001）：写进文件 / 交给传输层的帧数累计；`dropped`（001）：编码之后、落地之前丢的帧累计（录制 = writer 不接的 `videoFramesRejected`；推流 = E9 网络丢帧 `networkDropped`；NDI = 队列满丢的帧），与编码前的 E1 `skipped` 是两回事；`disk_free_mb`（001）：录制目录所在卷剩余 MB（2^20 字节，与 rss_mb 同口径），非录制输出 0；`reconnects`（002）：推流重连成功次数累计，录制 / NDI 0；`state`（002）：推流 idle / connecting / publishing / backoff / stopping / stopped / failed，NDI publishing / idle / unavailable（SDK 不在）/ failed（SDK 在但 initialize / send_create 失败，019；**或在跑但连续 10 帧（`NDISender.failureStreakLimit`）没送出去**——像素格式送不了、NV12 → UYVY 转换失败、直送的缓冲锁不住，last_error 写像素格式与原因，送出去一帧就回 publishing；D08 / 118，用户 2026-10-18 裁定 #10 只补文字、取值集合不变。另：BGRA 的输入按 BGRX（不透明）送，本仓库的 BGRA 是预乘 alpha、NDI 的 BGRA 要非预乘，下游拿不到 alpha——裁定 #11、G10 胶水），录制 idle / recording / stopping / stopped / failed；`output`（019）：这一项对应的输出在 MixerState.outputs 里的编号（与 display[].output 同口径，0 = 填数方没给 / 不在输出表里，如 headless 的 ISO 音轨），读的一方按它对号、不再靠数组顺序；`connections`（019）：NDI 当前接收方数，推流 / 录制 0。
- `audio.discontinuities`（004）：A1 第三项，Master 消费者流上相邻样本跳变 > 0.5 满幅的次数累计（集成层泵线程的流式检测，合成信号的 click 按平台启发式排除；正式判定用离线口径）；`audio.meters`（004）：采样那一刻的表读数，`buses` 顺序 = `Bus.allCases`（`bus` = `Bus.name`：master / busA / busB / headphones），`inputs` 键 = 输入编号；峰值 / 真峰值 dBFS / dBTP、响度 LUFS、LRA LU，dB / LUFS 下限 −120（`Stats.AudioCounters.Meters.floorDb`，静音也钳到它，JSON 写不了 −inf），来源只有 `AudioMixer.meters`。
- 兼容：老 stats.jsonl 缺这些键时解码给 0 / "idle" / 空（`decodeIfPresent`），写出总是写全；Show 文件不受影响（Stats 不在 Show 里）。

P3 加的字段（提案 013）：
- `display[i]`：显示类输出（没有编码器的那些）各一项，无固定顺序，按 `output` / `kind` 认。`output` = `MixerState.outputs` 里的编号，主界面监视器不是输出、用 0；
  `kind` ∈ {externalDisplay, virtualCamera, multiviewWindow, monitor}；`frames` = 已呈现 / 已送出帧数累计；`dropped` = 没赶上显示刷新 / 被扩展丢弃的帧数累计；
  `state` ∈ {idle, presenting, noDisplay, waitingExtension, publishing, stopped, failed}。
  填数方：`ExternalDisplayManager.statsEntries`、`VirtualCameraOutput.statsEntry(output:)`、App 的 `MetalDisplayView.presentedFrames`（monitor / multiviewWindow）；
  汇总的是 App `StatsHub` → `Engine.displayStatsProvider`；headless 没有显示类输出，写空数组。
  老文件缺 `display` 键 = 空数组。`StatsSummary.displays` 是它的汇总（P3 之前的基线文件里没有这个键，解出来是 nil）。

W3-C2 加的字段（提案 018）：
- `display[i].undelivered`：输出拿到（或该拿到）、但因为当时不在呈现 / 发布而没送出去的帧数累计——虚拟摄像头 = 扩展没装 / 没连上期间收到就丢掉的，
  外部显示 = 窗口收起（目标显示器不在）/ 被遮住期间当前源出了、窗口没画的（换源那段不算）。与 `dropped` 不重叠：`dropped` 只算在呈现 / 发布时没送出去的
  （显示类 = 两次刷新之间被覆盖；虚拟摄像头 = 连上之后本端队列满 + 排不进 sink + 扩展收了没输出）。显示类一段时间里 frames + dropped + undelivered ≈ 当前源出的新帧。
  填数方：`VirtualCameraOutput.statsEntry`（= `countersSnapshot.droppedNoDevice`）、`ExternalDisplayManager.statsEntries`（`DisplayFrameLedger` / `AuxInputPresenter`）；
  App 的 monitor / multiviewWindow 两项不填就是 0。缺键 = 0（013 的老条目照解），写出总是写全；`StatsSummary.DisplaySummary.undelivered` 同算法（末行 − 首行）。

G4 续做落地的字段（提案 017，用户 2026-09-24 批）：
- `audio.meters.buses[].rms_db` / `inputs{n}.rms_db`：推子后（与 peak_db 同一取样点）的均方根电平 dBFS，[L, R]，20·log10(rms)、下限 −120（`Meters.floorDb`）；
  300 ms 一阶指数平均（IEC 60268-17 的 VU 积分时间）、每个混音块更新、采样那一刻的值。C 热路径只累平方和与一阶平均（不开方、不进 libm），开方与 dB 换算在 Swift 侧（`AudioEngine.statsMeters`）。
  缺键 = 空数组 = 没有 RMS（017 之前的文件），读表的只画峰值；写出总是写全。多画面电平表有 RMS 时画"RMS 实心条 + 峰值细线 + 保持线"。

G4 续做落地的字段（提案 019，用户 2026-09-27 批）：
- `encoder[].output`：与 display[].output 同口径的输出编号，jsonKeys 里排最前；缺键 = 0。填数：包里各 `statsEntry` 多一个 `output:` 参数（默认 0），组装方（App OutputRuntime、headless）给编号——headless 的 PGM 录制器 = 节目里第一个 record 输出、NDI = 第一个 ndi 输出、ISO 音轨 0；App 的填法归 W3-E4。
- `encoder[].connections`：NDI 当前接收方数（`NDISendCounters.connections`），推流 / 录制 0；缺键 = 0。
- NDI 的 `state` 多一个 `failed`：SDK 在但 `NDIlib_initialize` / `NDIlib_send_create` 失败（`NDISendCounters.startFailed`，下一次 start 清）；`unavailable` 仍只表示 SDK 不在。
  118 起 failed 也指"在跑但连续 10 帧没送出去"（`sendFailing`，送出去一帧回 publishing；见上 P2 那一条），P5-5 补的文字。
- reducer（019 D）：addInput / setInputSettings 带进来的 `EffectSlot(id: "border")` 剥掉（`MixerReducer.strippingLegacyBorder`），与 Show.load 的搬迁同口径；校验器不改。

P5-2 加的字段（提案 022，用户 2026-10-11 批；"请用户定的点"按默认：三字段 + B1 attempt + B2 video_delay_ms，uptime 含重连期）：
- `encoder[].uptime_s`：这一路**本次运行**的时长（秒）= 采样那一刻 − `start()` 成功那一刻（host time 差）；推流含握手 / 退避 / 重连期间（"运行着"就算，与 state 一起看）；idle / stopped / failed 写 0。填数：`Recorder`（`RecorderCounters.uptimeSeconds`，recording / stopping 之外 0）、`StreamOutput`（自己记 startedAt，`statsEntry(counters:previous:…)` 让组装方用同一份快照）、`NDISender`（`NDISendCounters.startedAt`，publishing 之外 0）。
- `encoder[].disconnects`：推流连上之后掉线 / 停滞被判断线的次数，自启动累计（`StreamCounters.disconnects`，早就在数、只是没进 Stats）；录制 / NDI 0。与 `reconnects` 的区别：reconnects 只记成功连回来的，断了没连回来的只有它能看出来。
- `encoder[].last_error`：最近一次错误的文案，空串 = 没出过错，**下一次 `start()` 清**（与 019 的 NDI startFailed 同口径）。推流 = 最近一次断线原因（`断线：连接断开` / `断线：发送停滞` / `断线：发送失败：<原因>`）/ 连接失败（`连接失败：<原因>`，如"连接超时""没连上"或传输层回的那一句）/ 鉴权失败（`鉴权失败（…）：<服务器回的状态>`，W2-D4：第一次就停在 failed）/ 建传输层失败（`建传输层失败：…`）的原因——只写原因本身、不带 Swift 枚举原样（G10 胶水 ③ 之前是 `断线：disconnected / stalled / sendFailed(…)`、`连接失败：connectFailed("…")`）；录制 = `State.failed(String)` 的文案（磁盘不足、编码器起不来、writer 失败、没写入任何视频帧……）；NDI = SDK 不在（编译时没探测到）/ NDIlib_initialize 失败 / NDIlib_send_create 失败，或连续送不出去那一次的像素格式与原因（"NDI 送不了像素格式 'yuvs'（只认 NV12 / UYVY / BGRA），连续 10 帧没送出"，118；恢复送出后留着、下一次 start 清）；起不来的路（`start()` 抛错、Stats 报 failed）由组装方填（App `OutputRuntime` 把 `failureReason` 填进去，P5-2 胶水；headless 透传）。
- `encoder[].attempt`（B1）：推流**这一轮**连接是第几次尝试，从 1 起：`connecting(n)` = n，退避期间 = 即将进行的那一次 = failures + 1（与 App 底栏"连接中 / 重连中（第 n 次）"原来的读法一致，底栏从此读它——铁律 4）；在推 / 空闲 / 停止 / failed = 0；录制 / NDI 0。
- 顶层 `video_delay_ms`（B2 / 提案 028）：采样那一刻为监听同步把视频延后的毫秒数 L（W1-B4：按 Master 效果链的实测延迟延后派发；audioPTS 补偿、没有效果、或组装方没接视频延后时 0）；瞬时值不累计；引擎 `EngineCounters.videoDelayMs` → `StatsAssembler` 填。
- 缺键 = 0 / 0 / "" / 0 / 0，写出总是写全；`Stats.EncoderEntry.init` 四个参数带默认值（现有调用点不改）；`StatsWriter.sanitized` 把非有限的 uptime_s / video_delay_ms 换 0；`StatsSummary.DeliverySummary` 多可选 `uptimeS`（末行）/ `disconnects`（末行 − 首行）/ `lastError`（最后一个非空）/ `lastAttempt`（末行），顶层多可选 `videoDelayMs`（序列），老基线缺键解 nil。界面改读归 101。

P5-4 加的字段（提案 030，用户 2026-10-17 批，字段定稿）：
- `audio.effects`：采样那一刻效果链的处理延迟，瞬时值不累计。`buses[]` = 四条总线 Master / Bus A / Bus B / 耳机各一项（`Stats.AudioCounters.EffectsLatency.listedBuses` = `Bus.allCases`，顺序即写出顺序，按 `bus` 认；`bus` = `Bus.name`，与 `meters.buses[].bus` 同一写法；
  耳机总线也能装效果——调音台耳机条的"效果"——030 正文没列，用户 2026-10-18 裁定 #1 定列：填数 G10 胶水、常量与文字 P5-5，JSON 形态不变），
  `latency_ms` = 这条总线已打开的格的延迟之和（`AudioEngineStatus.BusEffects.latencyFrames` / 48 000 × 1000，`EffectsLatency.milliseconds(frames:)` 是唯一的换算），没装效果 / 格都关着 = 0；
  `measured_latency_ms` = 链里装着自写压缩器 `compressor` 时它冲激法自测的延迟（按设计 0，≠ 自报时按量到的记；格关着也写），链里没有它就缺键。
  `inputs{n}` 只列装了效果的路（契约链里至少有一格装进了这一路的 EQ / 动态格；格关着也列、延迟 0），值同上（`InputEffects.latencyFrames`；measured 只在动态格是压缩器时写）。
  延迟值的来处：NBandEQ 0、DynamicsProcessor 256 帧（5.33 ms）、PeakLimiter = 起音（默认 12 ms）、压缩器 = 实测；总线的由泵补到消费者流的 PTS 上（W5-C；Master 的在 videoDelay 补偿下改成把视频延后，`video_delay_ms` 口径不变），每路的从这一路的对齐延迟线里扣（W1-D3）。
- 填数：`AudioEngine.audioCounters`（引擎每秒取一次）在出 Stats 行时从状态快照 `AudioEngineStatus` 拷（控制循环每 50 ms 刷新；App 音频设置窗的"延迟自测"读的也是这份）——不进实时线程、不碰混音器；App / headless 把 `AudioCounters` 整个透传，不用改。
- 缺键 = 空（`buses: []`、`inputs: {}`），写出总是写全（没有音频引擎的组装方写空）；不加命令、不进 `per_input`、顶层键不变。App 状态页 / API 客户端的展示归以后的会话；gate4 / soak 报告脚本不读它。

### 2.8 文件与脚本（Show.swift、Scenario.swift）

| 类型 | 是什么 | 谁写 | 谁读 |
|---|---|---|---|
| `Show` | {schemaVersion = 1, name, inputs, mixer: `MixerSettings`, audio, outputs, layout: `ShowLayout`}；`save()` / `load(from:)` / `migrate(from:schemaVersion:)` 占位 | App、命令 loadShow | 引擎启动、App |
| `MixerSettings` | Show 里的切换部分 = MixerState 去掉 inputs/audio/outputs | `Show(name:state:)` | `makeState()` |
| `ShowLayout` | 界面布局，`[String: JSONValue]` 原样存取，契约不解释 | App（W2-B / W3-E） | App |
| `Scenario` | {durationTicks, events: [{tick, command}]}；`sortedEvents` | 测试脚本 | ScenarioRunner（W1-A） |
| `JSONValue` | 占位字段用的通用 JSON | — | — |

`Show ↔ MixerState`：`Show(name:state:layout:)` 和 `show.makeState()`；makeState 清瞬态（进度、startTick），目标值直接到位。

过渡键的一次性搬迁（提案 010 / 013，P3 落地，P4 收口）：`Show.load(from:)` 解完就调 `migratingLegacyKeys()`，把 `OutputSettings.extra["layout"]` 搬进 `.multiview`、
`extra["displayID"]` / `["fallbackToMain"]` 搬进 `.display`、某路输入效果链里第一个启用的 `EffectSlot(id: "border")` 搬进用到这路输入、还没有边框的叠加通道的 `OverlayState.border`，
搬完清掉旧键；幂等，正式字段已有值的不动。放在契约里是为了 App / headless / 测试读同一份。P4 起另外三条：
- 搬完之后 `border` 格**一律清掉**：没有叠加通道用到的、停用的、通道已有正式边框而没搬的都算——读它的后备 W3-B2 删了，留着是没人读的死数据（用户 2026-09-27 定全清；
  停用格里的宽度 / 颜色随之丢掉，新模型里"关着的边框"就是 `border = nil`）；
- `transition.stinger.input` 指向不存在的输入的置 nil：P4 之前 removeInput 不清它，那时存下的文件里可能有（不清的话 App 改 Wipe 参数会被总线以"Stinger 输入不存在"拒）；
- 状态机对 loadShow（整份 `Show.migratingLegacyKeys()`）与 addOutput / setOutputSettings（`OutputSettings.migratingLegacyKeys()`）进来的数据也先搬：
  API 客户端直接带旧键的与读文件结果一致，状态机里的状态不会再有输出的过渡键。搬迁不碰 `validate()` 查的结构，`CommandValidator` 不用改。
  没收的一处：setInputSettings / addInput 带进来的 `border` 效果格不搬也不清（没有叠加通道的上下文），存盘再读时清掉（reports/p4-contracts.md §4 第 1 条）。
读取方：渲染器（W3-B2）与 `ExternalDisplaySpec`（W3-C2）已经只读正式字段；App 的 `OutputExtras.displayNumber` 在 main 上还留着 `extra["displayID"]` 的后备，W3-E3（prompt 68 第 6 条，w3-app-4）已删、待合并。
`Show.schemaVersion` 不升：新字段全部带默认值，008 与 `InputAudioSettings.afv` 靠 `decodeIfPresent`。
P5-2 起 `migratingLegacyKeys()` 多一条（提案 020）：文件没有 `transition.slots`（020 之前写的，裸解码为空数组）→ 按 `mixer.format` 补出厂四槽，槽 1 换成文件里原来那组（type / durationTicks / wipe / stinger；原来是 cut 的槽 1 用 Fade 0.5 s），currentSlot = 当前那组对得上的槽（原来那组进了槽 1 就是 1；cut 对不上任何槽 → nil，当前那组仍是 cut、行为不变）；有 slots 没 currentSlot 的照 nil；四个槽里指向不存在输入的 `stinger.input` 置 nil（P4 清当前那组的规则扩到槽）；幂等。`scenarios/*-show.json` 读进来就是"出厂四槽 + 槽 1 = 工厂里的那组"；文件里 slots 不是 4 个（且非空）由 `validate()` 拒。
另有两个**不并进** `Show.load` 的搬迁函数（App 在 Show.load 后各调一次、读写切到字段，之后可以并进来）：025 的 `Show.migratingLegacyAppFlags()`（§2.5）与 023 四的 `Show.migratingLegacyInputCategories()`（`layout["inputCategories"]` → 各路 `InputConfig.color`，§2.4）。

### 2.9 渲染 / 消费者协议（Render.swift：Renderer、RenderSink、FrameConsumer、AudioBlockConsumer）见 §7。

### 2.10 测试工装（TestPattern.swift、TestSignal.swift）见 §4、§5。

---

## 3. 关键口径速查

- **时间戳**：只有 host time。所有帧、音频块入口换算；编码 PTS = `RenderedFrame.tickTime` = 这一拍在**节目输出时间线**上的时刻 = 理想拍点 + 这一帧的视频延后 Lₙ（提案 028，用户 2026-10-10 批：videoDelay 补偿下 L = Master 效果链的实测延迟；audioPTS 补偿、没有效果、或组装方没接视频延后时 L = 0，就是拍点——决策 10 的口径不变）；tickTime 严格递增，`program.pts` / `preview.pts` / `multiview.pts` 仍是理想拍点（画面内容的时刻），`tickTime − program.pts` = Lₙ；音频块 `hostTime` 在同一条线上（§7）。API / tally 的 `tickTime`（StateFeed / TallyFrame）不变，仍是状态变化那一拍的拍点（C1 / C2 量的是状态，不是输出）。
  拿不到真正采集时刻的源（用户 2026-09-22 定）：**网络源（NDI 之类）** `Frame.pts` = 到达 − 本帧抖动 + J × 帧间隔（J = `InputSource.ndi` 的 `jitterBufferFrames`），
  同一路的音频块 hostTime 同加 J × 帧间隔；**文件输入** pts = 拍点 − 半帧（W2-A）。
- **挑帧**：渲染线程每拍对每路 `latest(atOrBefore: 拍点时刻)`，30 进 60 自然重复、59.94 进 60 每 1000 拍重复一次，没有别的机制。
- **切换**：`reduce` 只在拍点边界应用；Cut 原子换号。每拍先 `advance` 再 `reduce` 该拍命令，命令按 sequence 严格顺序。
- **C1 的两种口径**：`生效拍点时刻 − IssuedCommand.issuedAt` 是"服务端收到 → 生效"；客户端口径（客户端发出 → 画面生效）由客户端自己记发送时刻（scripts/apitest），多一个单程网络延迟。
- **音频块**：`AudioRing.write` 的 hostTime 是块首帧时刻；混音输出块的首样本 host time 作音频 PTS，与视频同一时基。
- **编号**：输入 / 输出编号从 1 起，0 = 无；输入编号最大 16（`InputConfig.numberRange`，提案 032）；overlay channel 1–4；`Bus.rawValue` = `AudioState.buses` 下标。
- **范围**：tbar/progress 0–1；pan −1…1；gainDb −96…+24；delayMs 0–500；crop 各边 0–1 且对边之和 ≤ 1（`InputSettings.clamped()`）。
- **无信号**：`InputState.noSignal`，帧槽保留最后一帧；渲染不阻塞。noSignal 与 error 的分界见 §2.4（会不会自己好）。
- **纯音频输入**：没有帧槽，能切进 Program（画黑、音频按 AFV 走），多画面画占位格 + 电平表（§2.4，用户 2026-09-23 定）；声道映射口径见 §2.4 提案 014。
- **PVW / 多画面出不出 NV12**（用户 2026-09-22 定）：状态里有 enabled 的输出、其 `settings.source` 是 `.preview` / `.multiview` 时 `RenderedFrame.preview` / `.multiview` 自动填；
  `MetalRendererOptions.previewOutput` / `multiviewOutput` 保留为强制开的覆盖（取或）。kind = multiview 的输出的 enabled 就是这个意思（要不要把多画面 NV12 送给下游），
  多画面布局取第一个 kind = multiview 的输出、与 enabled 无关（§2.5）。
- **PVW 画不画叠加**：每通道的 `OverlayState.previewOn`，与渲染器的"全部预览"总开关 `MetalRendererOptions.overlaysInPreview` 取或。

---

## 4. 测试图案 `TestPattern`（CPU 参考实现，BGRA 与 NV12 都能写能读）

以 1920×1080 定义，其他尺寸每个坐标按 `v × width / 1920` 向下取偶（`Geometry`；4:2:0 色度永远对齐）。

| 元素 | 位置（1080p） | 编码 |
|---|---|---|
| 行 1 帧号 | y = 16，x = 16 起 32 个 32×32 块 | 32 位码字 = 28 位数据 ≪ 4 ∣ CRC-4；块 0（最左）= 最高位；白 = 1 |
| 行 2 时间戳 | y = 64，同上 | 生成时 host time 的毫秒 mod 2²⁸ |
| 输入 ID | (16, 112) 64×64 纯色 | 16 色 `palette[inputID]`，两两 BT.709 limited YCbCr 距离 ≥ 48（实测最小 56.6），不含纯黑、纯白和任何灰 |
| 闪光 | 右上 (1840, 16) 64×64 | `isFlashTick`: tick % 整数帧率 == 0 → 全白，否则全黑（59.94 → 每 60 拍 = 1.001 s） |
| 底色 | 其余 | `.gray(level)`（full-range RGB 电平；V7 用 64/192，NV12 写成 limited Y 71/181）、`.gradient`，或 `.noise(level:amplitude:seed:)`（提案 006，P2 落地）：灰底叠零均值均匀噪声 ±amplitude，三通道同值、NV12 只动亮度，确定性伪随机（seed + 帧号 + 行 + 列，`TestPattern.noiseValue` 是逐像素参考定义），帧号变了噪声就变；四样东西盖在噪声上面，解码规则不变；中心 1/4 区域均值 = level ± 0.25。JSON `{"noise":{"level":128,"amplitude":24,"seed":7}}` |

解码：每块取中心一半区域（1080p 下 16×16）均值，limited Y > 128 记 1；CRC 不对返回 nil；输入 ID 取最近调色板色，距离 > 24 返回 nil；全黑 / 全白 / 纯灰画面三项都是 nil。
CRC-4：多项式 x⁴+x+1，初值 0xF，MSB 先，无反射无 xorout（`crc4`）。任意单块翻转都能发现；全 0 / 全 1 码字都无效。

**与测试标准 §2.1 的唯一偏离**：帧号 16 块 12 位 → 32 块 28 位。12 位 68 秒回绕，8 小时长稳会歧义；28 位 60 fps 下 51 天。这是 P1 唯一允许偏离测试标准的地方（落地方案 §1.3 第 4 条）。

测试证明：码字层 10 万随机值往返恒等；单块翻转 5000 × 32 位全部捕获；图像层 1080p BGRA 1500 帧 + NV12 600 帧 + 720p/2160p/640×360/1366×768 各 100 帧往返恒等；高斯模糊 σ = 1.5 + 4:2:0 + ±10 噪声后 60 帧 100% 正确。
噪声底纹（P2）：|n| ≤ amplitude、三通道同值、n = 0 的比例 = 1/(2A+1)（均匀）、同 seed + 帧号逐字节相同、帧号或 seed 变了即独立、块区域逐像素等于纯灰渲染、解码与纯灰相同、NV12 亮度 = limitedLuma(BGRA 灰值) 且色度全 128、退化后 20 帧 100% 正确。

## 5. 合成音频 `TestSignal`

1 kHz 正弦 −20 dBFS（峰值 0.1）；第 k 个 click 落在 host time t0 + k × clickPeriod（clickPeriod = `TestPattern.flashPeriod(frameRate:)`，与闪光共用 t0），持续 48 样本（1 ms），窗口内样本置 +1.0（满幅，不与正弦相加）。
采样率漂移：样本 i 的 host time = t0 + i / (48000 × (1 + ppm/10⁶))；click 样本序号 = round(k × period × 有效采样率)。
`render(into:frameCount:startingAt:)` 无状态，任意分块结果相同；`sampleIndex(at:)` 给合成源算"现在该产到第几个样本"。

---

## 6. 线程规则检查表（复审时逐条对，来源设计方案 §3.2、§3.5）

| # | 规则 | 契约里怎么落 | 谁负责证明 |
|---|---|---|---|
| T1 | 渲染线程每帧零分配 | `Renderer.render` 只收值类型 / 预分配的 `RenderInputTable` / `MixerSnapshot` 引用；无闭包参数 | W1-C（Instruments 10 s 0 分配） |
| T2 | 渲染线程不等 drawable | `Renderer` 只画离屏纹理；显示由 `MetalDisplayView` 的 displayLink 自己 blit | W1-C |
| T3 | CPU 领先 GPU ≤ 2 帧 | `render` 返回 `.skipped` 时引擎记 missed_render，不阻塞 | W1-C / W1-B |
| T4 | 音频回调无锁无分配无日志无系统调用无 ARC | 混音只碰 `sw_audio_ring` 裸指针与 C 参数；Swift `AudioRing` 协议只在写端 / 离线工装用 | W1-D（check-rt-symbols） |
| T5 | 跨线程只用 SPSC 环与原子量 | `FrameSlot` / `AudioRing` 都是 SPSC；统计结构是原子读的快照 | W1-B / W1-D |
| T6 | 状态只读快照，靠原子指针交换 | `MixerSnapshot` 不可变 final class；渲染 / 音频线程不进 actor | W1-B |
| T7 | 消费者不拖渲染线程 | `FrameConsumer.consume` 必须立即返回，自己的有界队列满了丢自己的 | W1-E |
| T8 | 入口打 host time 戳 | `Frame.pts` / `ingressTime`、`AudioRing.write(hostTime:)` | 每个输入会话 |
| T9 | 编码 PTS 用拍点时刻 | `RenderedFrame.tickTime`（028：= 拍点 + 视频延后 L，L = 0 时就是拍点） | W1-E |
| T10 | 统计只有一份 | 所有数字进 `Stats`，UI / API / 测试读它 | 所有会话 |

---

## 7. Renderer 与 FrameConsumer 协议草案

每拍调用链（引擎 W1-B 驱动）：

```
时钟到期 tick n（拍点时刻 t_n）
  → 引擎读最新 MixerSnapshot（原子指针）
  → 引擎对每路输入 videoSlot.latest(atOrBefore: t_n) 填进 RenderInputTable（预分配，下标 = 输入编号）
  → renderer.render(tick: n, at: t_n, snapshot:, inputs:) -> .submitted | .skipped
       渲染线程内，零分配；按 §5 顺序：PGM 底 → 转场混合 → Overlay 1→4 → FTB → PVW → 多画面 → RGB→NV12 写 IOSurface
  → GPU 完成回调：sink.renderer(_, didComplete: RenderedFrame{tick, tickTime, program(NV12, pts = t_n), preview?, multiview?, submitTime, gpuStart, gpuEnd})
  → 引擎（RenderSink）：更新 Stats（render_ms、jitter）→ 对每个 FrameConsumer 调 consume(frame)（立即返回，各自入队）

音频（与视频并行，提案 001 B）：
混音回调（实时线程）→ 消费者 SPSC 环 → AudioEngine 的泵线程（W2-E，非实时；PTS = 块首 − 对齐延迟 ± 补偿方式的平移（028），真设备重采样到 host 时钟）
  → 对每个 AudioBlockConsumer 调 consumeAudio(planes:channelCount:frameCount:hostTime:)（立即返回，各自入队）
```

- `Renderer`：`sink`（设置一次）、`prepare(format:maxInputs:)`（建池，允许分配）、`render(...)`、`shutdown()`。W1-C 实现；与 W1-B 有分歧写进各自报告。
- `RenderSink`：引擎实现；在 GPU 回调线程被调，只做派发和统计。
- `FrameConsumer`：`consumerName`、`consume(_:)`。W1-E 的编码器 / 录制器实现；每个消费者自己的线程和有界队列（深度 2–3），满了丢最旧并 `Stats.encoder[i].skipped += 1`。
- `AudioBlockConsumer`（提案 001 B，P2 落地）：`consumerName`、`consumeAudio(planes:channelCount:frameCount:hostTime:)`，与 FrameConsumer 对称的混音块消费者，
  Recorder / StreamOutput / NDISender 实现，签名逐字 = W1-E 原版；`SwitcherAudioIntegration.AudioBlockConsuming` 是它的 typealias。
  在集成层的非实时泵线程上被调，必须立即返回、只拷进自己的有界缓冲，永远不在音频实时回调里直接调（铁律 3）；
  `planes` = channelCount 个非交错 float32（48 kHz）平面，`hostTime` = 块首样本**在节目输出时间线上的时刻**（提案 028，与 `RenderedFrame.tickTime` 同一条线）= 内容被采集的时刻 + L：
  集成层按对齐延迟修正到采集时刻，再按补偿方式平移——videoDelay 下 Master 块 = 块首 − 对齐延迟（**不再前移**，内容经 Master 效果链本来就晚 L_m）、Bus A / B / 耳机 = 块首 − 对齐延迟 − L_bus + L_m、输入（ISO `.input` / `.inputProgram`）= 块首 − 对齐延迟 + L_m；
  audioPTS 下（W5-C 现状）各来源 = 块首 − 对齐延迟 − 各自效果链的延迟，L = 0。两种方式由一处开关互斥，不会双重补偿；L 变了非 Master 来源按差值拼接（变大丢、变小补静音），Master 不拼接；PTS 直接用，与视频同一时基。
- `RenderedFrame.renderMs` = gpuEnd − program.pts（V1 口径：拍点 → GPU 完成；028 改成按 program.pts 取拍点——延后过的帧 tickTime = 拍点 + Lₙ，用它会读出负数；L = 0 时与以前逐值相同）。
- 按内容时刻挑输入帧的消费者（ISO 录制的 `ISOFrameTap`）比 `program.pts`、打戳用 `tickTime`（028，W1-B4 已改）；录制起止按节目输出时间线开录（`RecordingStart(tick:tickTime: 拍点 + 当前延后)`）归 G8b 胶水。
- 显示窗口不走 FrameConsumer：`MetalDisplayView` 直接从渲染器拿"最新完成的纹理"。

---

## 8. Command ↔ 设计方案 §9.1

| §9.1 | 契约 case | 备注 |
|---|---|---|
| cut | `.cut` | PGM/PVW 原子对调 |
| fade(duration) | `.fade(durationTicks:)` | = setTransition(.fade, d) + autoTransition |
| — | `.setTransition(type:durationTicks:)`、`.autoTransition` | 加的：Wipe/Zoom/Stinger 和 T-bar 需要"选类型"与"开始"分开；当前那组是没选输入的 Stinger 时 autoTransition 拒收（提案 029，P5-3） |
| — | `.setTransitionParams(wipe:stinger:)` | 加的（提案 016）：Wipe 方向 / 软边、Stinger 输入 / 换底拍两组整体替换；转场进行中被拒，softness 钳 0–1、cutAtTick 钳 ≥ 0；之前只能 loadShow 整体替换（会盖掉别人的改动、打断进行中的动画） |
| setPreview(input) | `.setPreview(input:)` | 转场进行中（`TransitionState.isActive`）被拒（提案 023）：渲染器按当前的 program / preview 画两路，中途换掉是 PGM 跳变 |
| setProgram(input) | `.setProgram(input:)` | 硬切 PGM，PVW 不变；转场进行中被拒（提案 023） |
| tbar(progress) | `.tbar(progress:)` | 到 1 提交、拉回 0 取消，两处都按 currentSlot 重拷当前那组（取消那半是 020 追加，用户 2026-10-17，P5-4）；没选输入的 Stinger 照推（029 不管 T-bar，画面口径见 §2.5 转场槽） |
| ftb | `.ftb(on:)` | 显式开关，脚本可重放；时长走 setFTBDuration |
| — | `.setTransitionSlot(slot:config:)` | 加的（提案 020，P5-2）：改转场槽 1–4 之一（`TransitionSlot` 整体替换），进行中也收；改当前槽：空闲时当前那组同时重拷、进行中的完成或取消（T-bar 拉回 0）那一拍重拷；钳位同 016；槽号 / Stinger 引用由校验器拒；相同配置 applied = false |
| — | `.useTransitionSlot(slot:start:)` | 加的（提案 020）：把槽拷进当前那组、currentSlot = slot；start = true 同时开始 auto 转场（一拍内原子完成，cut / 时长 0 = 立即对调）；start = true 而槽是没选输入的 Stinger 被拒（提案 029，P5-3：校验器 400、reducer 原样返回）；start = false 只选中；转场进行中被拒；已是当前槽且相同 applied = false |
| — | `.setFTBDuration(ticks:)` | 加的（提案 020）：`ftb.durationTicks`；渐变进行中回拨起点不跳变、0 立即到位；相同值 applied = false；负数校验器拒；不并进 ftb |
| overlay(n, on, input) | `.overlay(channel:on:input:)` | input nil = 不换输入 |
| — | `.setOverlay(channel:rect:animation:)` | 加的：W3-B 位置 / 动画 |
| — | `.setOverlayDecoration(channel:border:anchor:previewOn:)` | 加的（提案 010 A4，P3 定）：边框 / 锚点 / PVW 预览；与 setOverlay 分开是为了不改它的 JSON 形态 |
| audioGain(input, dB) | `.audioGain(input:dB:)` | |
| mute | `.mute(input:on:)` | |
| — | `.busGain(bus:dB:)`、`.busMute(bus:on:)`、`.setAFV(on:)` | 加的：Master 推子（W2-B）、AFV 总开关（每路的在 `InputAudioSettings.afv`，走 setInputSettings） |
| — | `.setMonitorMode(mode:)`、`.setBusEffects(bus:effects:)` | 加的（提案 012）：调音台的 PFL / AFL 与总线效果链；监听**点**（延迟线前 / 后）是 `AudioState.monitorPoint`，走 Show，不是命令 |
| — | `.setMonitorSource(bus:)` | 加的（提案 026，P5）：耳机 / 监听总线上听哪条总线（master / busA / busB / headphones），写 `AudioState.monitorSource`；P5-3 起四条都合法，headphones = 听耳机总线自己（用户 2026-10-12 允许；P5 时校验器 400、reducer 原样返回）；相同值 applied = false；独听仍优先 |
| — | `.setInputAudio(input:solo:afv:routing:)` | 加的（提案 023 五，P5-2）：一路的独听 / AFV 参与 / 总线路由，三个参数可选、nil = 不动（JSON 不写键）、非 nil 整体替换该项；输入不存在拒；全 nil 或全与现状相同 applied = false。替代"按快照改一位后 setInputSettings 整体写回" |
| startRecord / stopRecord | `.startRecord(output:)` / `.stopRecord(output:)` | output = 录制输出编号；ISO = 同一拍发多条 |
| startStream(dest) / stopStream | `.startStream(output:)` / `.stopStream(output:)` | dest = 编号为 output 的 stream 输出，url/key 在其设置里 |
| — | `.setOutputEnabled(output:on:)`、`.renameOutput(output:name:)` | 加的（提案 012）：ndi / externalDisplay / virtualCamera / multiview 的目标开关与改名；record / stream 的 setOutputEnabled 被拒（起停与拍绑定）；multiview 的开关 = 要不要把多画面 NV12 送给下游，布局与它无关 |
| setInputSetting(...) | `.setInputSettings(input:settings:)` | 整体替换，reducer 先 clamped() |
| — | `.renameInput(input:name:)` | 加的 |
| addInput / removeInput | `.addInput(config:)` / `.removeInput(input:)` | addInput 的编号不在 1–16（提案 032）、file 来源速率不在 0.1–8（提案 031）校验器拒（reducer 同判）；removeInput 把 PGM / PVW 用它的置 0、叠加与 Stinger 对它的引用置 nil（Stinger 是 P4 加的） |
| — | `.setInputSource(input:source:)` | 加的（提案 012）：换来源，编号 / 名字 / 设置 / PGM / PVW / 叠加引用全保留（removeInput 会清引用，直播中不能用）；"设循环"也走它（endAction: .loop，运行表就地改不重建，101）；file 来源速率不在 0.1–8 校验器拒（提案 031，reducer 同判） |
| — | `.setPlayback(input:paused:)` | 加的（提案 021，P5-2）：文件输入播放 / 暂停（`settings.playback.paused`）；输入不存在 / kind != file 校验器拒；相同值 applied = false |
| — | `.seekPlayback(input:seconds:)` | 加的（提案 021）：文件输入定位（0 = 从头播），记一次定位请求 (seekTick = 这一拍, seekSeconds)，组装方交给 FileInput；kind != file / 秒数负、非有限或超过一周（604 800，提案 031）校验器拒（reducer 同判）；同一拍同一位置再发 applied = false。"切上 PGM 时从头播"是每路 `playback.restartOnProgram`，reducer 在换人那一拍写同一种定位 |
| — | `.setInputColor(input:color:)` | 加的（提案 023 四，P5-2）：改一路的分类颜色（`InputColor`），nil = 清掉；输入不存在拒；相同值 applied = false；分类名字留在 Show.layout |
| — | `.addOutput(config:)` / `.removeOutput(output:)` / `.setOutputSettings(output:settings:)` | 加的：输出表要能改；addOutput / setOutputSettings 进来的设置先搬过渡键（P4，同 Show.load） |
| loadShow | `.loadShow(show:)` | 整体替换状态；先按 Show.load 同一套规则搬迁（P4），`validate()` 不过的被拒 |

每条命令在总线上加信封 `IssuedCommand{sequence, issuedAt}`（prompt 的"每条命令带 sequence 和 issuedAt"）；`Scenario` 和 HTTP API 只有 `Command`。

---

## 9. 与 prompt / 设计方案的偏离（G1 复审请逐条看）

1. **Command 与信封分离**：`Command` 是纯操作枚举，`IssuedCommand` 带 sequence / issuedAt。原因：场景脚本和 API 请求里没有 host time；reduce 签名按 prompt 收 `Command`。
2. **MixerState 多了 `format` 和 `inputs`**：addInput / removeInput / setInputSettings 要能在 reduce 里落地，渲染每拍要读裁切变换。相应地 `Show.mixer` 只是切换部分（`MixerSettings`），避免 inputs/audio/outputs 在 Show 里存两份。
3. **每路输入音频参数存在 `InputSettings.audio`**，`AudioState` 没有 perInput（只存一份）。
4. **`ftb` 是结构不是 Bool**：`FadeToBlack{on, durationTicks, level}`，因为 §5 第 4 步是"乘一个黑色比例"，需要进度。
5. **命令比 §9.1 多 17 个**（按 §8 的对照表数，34 − 17；P1 写的 14 是 27 减 §9.1 那一行的 13 个示例，P3 加了 6 个没跟着改。setTransition、autoTransition、setOverlay、busGain、busMute、setAFV、renameInput、addOutput/removeOutput/setOutputSettings，
   P3 按提案 010 / 012 加的 setOverlayDecoration、setMonitorMode、setBusEffects、setOutputEnabled、renameOutput、setInputSource，
   以及 W3-E2 按提案 016 加的 setTransitionParams）：都是 W2/W3 prompt 里已经写明要做的事。P5 按提案 026 加 setMonitorSource（35），P5-2 按提案 020 / 021 / 023 再加 7 条
   （setTransitionSlot / useTransitionSlot / setFTBDuration / setPlayback / seekPlayback / setInputColor / setInputAudio，用户 2026-10-11 批）：共 42。
6. **`InputState.error(message:)` 带标签**、`ColorInfo` 多了 `matrix`：JSON 可读性 / 601 摄像头。
7. **`RGB8`、`ShowLayout` 的命名**：`RGBColor` 与 ApplicationServices（QuickDraw）的同名类型冲突，`Layout` 与 SwiftUI 冲突，改名避开。
8. **C 结构不用 `_Alignas(64)`**：Swift 不导入过度对齐的结构；用显式 padding，分配方负责 64 字节对齐。
9. **Stats.render_ms / jitter_ms 是窗口平均 / 窗口最大值**（一个数），每帧 p99 由 W1-C 在测试内直接测。
