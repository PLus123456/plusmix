# W3-A 输入二期（DeckLink、NDI 接收）—— 报告（分支 w3-inputs2）

日期 2026-09-19。机器 Apple M5 Max（Mac17,6）128 GB / macOS 26.6.2 (25G83) / Xcode 27.0 (27A266a) / Swift 6.4；**电池供电**（94%），load 3.3；
NDI SDK for Apple 6.3.2（/Library/NDI SDK for Apple，libndi 2026-04-13）；**没有 DeckLink SDK（~/SDKs/DeckLink 不存在）、没有 Desktop Video 驱动、没有 DeckLink 硬件**——
但 NDI SDK 的示例目录自带一份 Blackmagic SDK 头文件（`/Library/NDI SDK for Apple/examples/C++/NDIlib_Send_BMD/BMDSDK/Mac/include`，**10.11.2**，含 DeckLinkAPIDispatch.cpp），
本会话用它把 DeckLink 桥接层编出来、跑 Fake 测试（Package.swift 把它作为最后一个备选路径，正式 SDK 装到 ~/SDKs/DeckLink 后自动优先）。
worktree `.claude/worktrees/decklink-ndi-inputs-da4ad2`，桌面端起的分支 `claude/decklink-ndi-inputs-da4ad2` 已改名 `w3-inputs2`（prompt 指定），从 `main`（f1bd1ee）开。
只动了 `Packages/SwitcherInputs/{Package.swift, Sources/NDI/, Sources/DeckLink/, Tests/NDITests/, Tests/DeckLinkTests/}`、`docs/contract-changes/008`、本报告。

## 1. 做了什么

两组可选 target（各自 = 一个 C / C++ 封装 target + 一个 Swift target + 一个测试 target，产品 `SwitcherNDI`、`SwitcherDeckLink`），共 3.75 k 行源码 + 1.56 k 行测试。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 DeckLinkInput | `Sources/DeckLink/CSwitcherDeckLink/`（C++：`sw_decklink_bridge.cpp` 会话 / `sw_decklink_devices.cpp` 枚举 + 热插拔 / `sw_decklink_fake.cpp` Fake / `sw_decklink_calibrator.cpp` 校准器 / `sw_decklink_dispatch.cpp` 包含 SDK 的 Dispatch.cpp / `sw_decklink_info.cpp`；对 Swift 只暴露 `include/sw_decklink.h` 这份 C API）、`Sources/DeckLink/{DeckLinkInput, DeckLinkDevices, SwitcherDeckLink}.swift` | 桥接是 C++（不是 ObjC++）：SDK 的 COM 接口是纯 C++，CoreVideo / CoreFoundation 都有 C API，用不上 ObjC。**设备枚举**：IDeckLinkIterator，持久 ID `peid:<BMDDeckLinkPersistentID>`（没有该属性的卡 `model:<型号>#<序号>`），输入接口位集、是否支持格式检测。**格式自动检测**：`EnableVideoInput(初始模式, 8-bit YUV, bmdVideoInputEnableFormatDetection)`（卡不支持时退回不带检测的 Enable 并报文案）；`VideoInputFormatChanged` 里 Pause → Enable(新模式, 按 `bmdDetectedVideoInputRGB444` 选 BGRA 否则 8-bit YUV, 仍带检测) → Flush → Start → 报 `format_changed`；只有模式 / 场序 / 色彩空间真变了才重开。**帧**：`VideoInputFrameArrived` 里 UYVY / BGRA 拷进 CVPixelBufferPool（IOSurface、Metal 可用，上限 8 块）的缓冲，行距相同一次 memcpy，否则逐行；`bmdFrameHasNoInputSource` 的帧不拷、只在变化时报 `signal_changed`。**时间戳**：见 §1.1。**内嵌音频**：`EnableAudioInput(48 kHz, int16 / int32, 2–16 声道)`，回调里交错 → float32 平面（scratch 复用），首样本时刻 = 包的流时间 + (同一回调里视频帧的硬件时间 − 流时间) 再校准；Swift 侧按环的声道数映射后 `ring.write`。**无信号**：帧带 no-source 标志 → noSignal（帧槽保留最后一帧）+ 看门狗兜底（N = 3 个帧间隔一次回调都没有 → noSignal，并查设备是否还在列表里）。**热插拔**：IDeckLinkDiscovery 通知（进程内一个订阅表）+ 每秒轮询兜底；拔 → 关会话、noSignal、文案；同持久 ID 回来 → 自动重开（`rebuilds` 计数），编号 / InputSettings 不在对象里所以不变。驱动没装 → noSignal + 指到 Desktop Video 的文案；设备不在 → noSignal + 列出已连接的设备，等它来 |
| 2 NDIInput | `Sources/NDI/CSwitcherNDI/`（C：`sw_ndi.h` / `sw_ndi.c`，SDK 头只在 .c 里包含）、`Sources/NDI/{NDIInput, NDIFinder, NDIClockMap, NDIInputSupport, SwitcherNDI}.swift` | **源发现** `NDIFinder`（NDIlib_find_create_v2，show_local_sources = true）：列表 / 按名找 / 等变化。**接收**：`NDIlib_recv_create_v3` 色彩格式 `UYVY_BGRA`（无 alpha 给 UYVY → '2vuy'，有 alpha 给 BGRA → 32BGRA，按预乘交给渲染器）、带宽 highest / lowest / audioOnly、allow_video_fields = false；一条接收线程 `capture_v3(timeout = 一个帧间隔)`，帧拷进池（IOSurface）后立刻 `free_video`。**到达即打 host time**：arrival = capture 返回那一刻；**抖动缓冲**（1–2 帧可配，默认 1）：`pts = arrival − jitter + J × 帧间隔`，jitter 来自发送端时间戳（§1.2），ingress = push 前一刻。**音频** FLTP 平面 → 环（声道映射：多的丢、单声道复制、少的复制最后一路），非 48 kHz 线性重采样；块首 = `arrival − jitter − 块时长 + J × 帧间隔`（与视频同一映射）。**tally 回传** `setTally(_:)` → 接收线程 `NDIlib_recv_set_tally`，重连后再发。**无信号**：连续 N（3）个帧间隔没视频帧 → noSignal（audioOnly 按音频算）。**源消失 / 回来**：不 live 时每 500 ms 查发现器，源出现或地址变了 `recv_connect`；实测同名重开由 SDK 自己按名重连（我们的重连 0 次） |
| 3 InputSettings 扩展 | `docs/contract-changes/008-input-source-decklink-ndi-params.md`（待批） | 提议放 `InputSource` 关联值：`decklink(deviceID:, connection:)`、`ndi(sourceName:, bandwidth:, jitterBufferFrames:)`，理由见提案。落地前三项在包内 `DeckLinkInput.Options.connection` / `NDIInput.Options.{bandwidth, jitterBufferFrames}`，组装方给 |
| 编译开关 | `Package.swift` | NDI：`NDI_SDK_DIR`（默认 /Library/NDI SDK for Apple）有 `include/Processing.NDI.Lib.h` 才把 SDK 编进 CSwitcherNDI（-I、-lndi、rpath）。DeckLink：`DECKLINK_SDK_DIR`（设了只看它；设成不存在的路径 = 明确关掉）→ `~/SDKs/DeckLink`（支持 `<dir>/include` 或 `<dir>/Mac/include`）→ NDI SDK 示例自带副本；要 `DeckLinkAPI.h` + `DeckLinkAPIDispatch.cpp` 都在。两者都不在时对应 target 编成空实现（`isSDKAvailable == false`，`start()` 抛错并把 state 置成带文案的 error），不是"不编译"——这样组装方（App / headless）不用条件编译就能链接。`cxxLanguageStandard: .cxx17` 是包级设置，只影响本会话的 C++ target |
| 为什么是 C 封装而不是像 W2-D 那样挂系统库模块 `NDI` | `Package.swift` 头注释 | App 同时链接 SwitcherOutputs（`SwitcherNDISend` 带系统库 target `NDI`）和本包：SwiftPM 不许包图里两个 target 同名，clang 也不许同一份 SDK 头出现在两个模块里（`import NDI` 不是 `internal import`，客户端编译时会把两个模块都载入）。所以 SDK 头只在 `sw_ndi.c` 里包含，Swift 只见 `sw_ndi.h`。DeckLink 同理只暴露 C API |

### 1.1 DeckLink 时间戳校准方法与残差（prompt 报告项）

方法（设计方案 §3.6 "回调给的参考时间加上入口时的 host time 校准"，一阶滤波）：
- 每次 `VideoInputFrameArrived` 入口背靠背读 `mach_absolute_time()`（→ host_now，ns）和 `IDeckLinkInput::GetHardwareReferenceClock(timeScale = 10⁹)`（→ hw_now，ns）。
- o_k = host_now − hw_now 是两个钟的瞬时差；一阶低通 o ← o + (o_k − o) / 2^shift，shift 默认 5（α = 1/32，τ = 32 帧 ≈ 0.5 s @ 60 fps）；第一个样本直接采用。
- 帧的采集时刻 pts = `GetHardwareReferenceTimestamp(10⁹)` + o；音频包首 = `GetPacketTime`（流时间）+ (帧硬件时间 − 帧流时间) + o。设备没有硬件参考钟（`GetHardwareReferenceClock` 返回失败）时 pts = 入口时刻、音频 = 入口 − 包时长，Stats 里 `hasHardwareClock = false` 并报一条文案。
- 残差 r_k = o_k − o（滤波前）反映两次读钟之间的抢占 / 调度抖动；`sw_decklink_calibrator` 记最大绝对值和 RMS，`DeckLinkInput.deckLinkCounters` 里能读。

残差实测（只有 Fake：假设备的硬件钟 = host − 常数，在 emit 前一刻由测试设定，所以量到的是"设钟 → 桥接层读钟"这段的抖动，量级与真卡上"卡打戳 → 回调读钟"相同）：
40 帧后偏移与真值差 **2.8 µs**，残差最大 **5.2 µs**，RMS **3.0 µs**（debug 构建）。纯数学：阶跃后 5τ（160 帧）内收敛到 < 10 µs；±20 µs 均匀抖动经 1/32 低通后偏差 < 6 µs（3σ ≈ 4.5 µs）。
**真卡上的残差 BLOCKED-硬件**：有卡时跑 `DeckLinkHardwareTests.testL1_deckLinkInput_within3Frames`，它打印偏移 / 残差最大 / RMS。

### 1.2 NDI 抖动缓冲深度与延迟的实测关系（prompt 报告项）

抖动的定义（`NDIClockMap`）：每帧带发送端 SDK 打的提交时刻 ts（100 ns，发送端系统钟）；收到时背靠背读本机墙钟（CLOCK_REALTIME）和 host time，
d_k = 墙钟 − ts = 传输时间 + 两机钟差；基线 m = 最近 1–2 s 内 d 的最小值（两个 1 s 块轮换）；jitter_k = d_k − m ≥ 0。钟差不用知道（只看 d 的变化）；
|d_k − m| > 1 s 视为对时跳变，基线重置；时间戳缺失 → jitter 0。pts = arrival − jitter + J × T。这样走最快路径到的帧 pts 比到达晚 J 帧，
晚到的帧 pts 相应提前——引擎按 pts ≤ 拍点挑帧，J 帧的缓冲吸收 ≤ J 帧的抖动；引擎自己的到达余量（W1-B2）看到 d = ingress − pts = jitter − J×T，
只在网络比缓冲还差时才再加余量，不会重复付。音频块同一映射同样 + J×T，A/V 相对关系不变。

实测（本机回环 1080p60 UYVY，测试自己的发送端 → NDIInput → 真引擎 + Metal 渲染器 + 真帧槽，`testNDI_loopback_L1_vsJitterBufferDepth_report`，每档 5 s；电池供电、load 3.3）：

| J（帧） | L1 平均 | p50 | p99 | max | 抖动均值 / 最大 | d = ingress − pts 均值 | dup / drop / 没帧拍 |
|---|---|---|---|---|---|---|---|
| 0 | 12.14 ms（0.73 帧）| 12.03 | 14.21（0.85）| 15.10（0.91）| 0.19 / 0.35 ms | +0.27 ms | 0 / 0 / 1 |
| 1（默认）| 29.14 ms（1.75 帧）| 28.72 | 32.84（1.97）| 33.36（2.00）| 0.06 / 0.19 ms | −16.49 ms | 0 / 0 / 2 |
| 2 | 45.85 ms（2.75 帧）| 45.82 | 47.33（2.84）| 47.64（2.86）| 0.10 / 0.20 ms | −33.14 ms | 0 / 0 / 3 |

另一轮（同一测试上一次跑）：J = 0 10.78 / p99 11.34 / max 11.69 ms；J = 1 28.88 / 29.65 / 29.77；J = 2 45.09 / 46.97 / 52.85（那轮见过一次 3.87 ms 的抖动尖峰）。
**结论**：每加一帧缓冲 L1 恰好多 ≈ 16.7 ms（与 pts 口径一致，引擎没有重复加余量）；本机回环的网络抖动只有 0.1–0.4 ms，J = 0 就够，
J = 1 是给真实局域网留的（同一交换机下 NDI 抖动通常 1–5 ms；跨交换机 / Wi-Fi 会到几十 ms，那时该用 J = 2 或更大——提案 008 把它放进节目文件）。
J = 0 的 0.73 帧是"到达 → 下一拍被挑 → 渲染 → 交给消费者"的固有量（同 W2-A 摄像头契约入口的 0.53 帧 + 拍点相位）。

`make lint BRANCH=w3-inputs2`、编译矩阵、全包 swift test 的结果见 §2 末尾。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherInputs --filter 'NDITests|DeckLinkTests'`（debug；NDI 回环那组约 80 s，其余 5 s）。

### 2.1 NDI（SDK 在，真跑）

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| NDI 回环：帧号连续 | `testNDI_loopback_uyvy_framesContinuous_formatAndTimestamps`（1080p60 UYVY 4 s，契约入口，不起引擎）| 推 242 帧，全部 UYVY 1080p、格式 "1920x1080 UYVY 60/1 p"；稳态每帧都解得出帧号，**缺号 0、倒退 0、连续重复 0**（帧号 113…344）；pts 单调、平均间隔 16.67 ms；d = ingress − pts 均值 −16.53（= 抖动 − J×T，J = 1）、最大 −16.21、最小 −16.59 ms；抖动均值 0.04 / 最大 0.09 ms；SDK 丢 0、格式不支持 0、池耗尽 0 | 连续 | ✅（第一轮见过一次连续重复 (282, 282) 伴随一次 68 ms 的接收停顿，第二轮没复现；测试对"缺号"硬性 0、"连续重复"≤ 2 并打印邻域，见 §5 第 4 条）|
| **NDI 回环 L1 ≤ 3 帧 + 抖动缓冲** | `testNDI_loopback_L1_within3FramesPlusJitterBuffer_framesContinuous`（真引擎 + Metal 渲染器 + 真帧槽，J = 1，8 s，发送端从第 0 拍起发）| 478 样本：平均 **30.75 ms（1.84 帧）**，p50 30.76，p99 **32.88 ms（1.97 帧）**，max 33.39 ms（2.00 帧），min 27.72；没帧 2 拍（起流）、重复 0 拍；per_input dup 0 / **drop 0** / latency_ms 30.74 / latency_max_ms 33.39（引擎自己算的 L1 与 harness 一致）；missed_render 0；引擎每拍挑到的新帧帧号跳号 0 | ≤ 3 + 1 帧 | ✅（目标档 ≤ 2 + 1 也过）|
| NDI 抖动缓冲深度 vs 延迟（报告项）| `testNDI_loopback_L1_vsJitterBufferDepth_report` | §1.2 的表：J = 0 / 1 / 2 → p99 0.85 / 1.97 / 2.84 帧 | p99 ≤ 3 + J | ✅ |
| **关掉发送端 → noSignal 在 3 个帧间隔内** | `testNDI_loopback_senderStops_noSignalWithin3Intervals_restartsRecover`（720p60）| 最后一帧 ingress → noSignal **70.2 ms**（另一轮 66.3；门限 3 × 16.67 = 50 ms，检查粒度 = 一次 capture 超时 ≤ 1 帧，所以落在 50–67 ms + 线程唤醒）；文案 "NDI 源 … 没有新帧（超过 3 个帧间隔）"；恢复送帧 → 自动回 live | ≤ 3 个帧间隔（+ 检查粒度）| ✅ |
| **重开自动恢复** | 同上第 3 段：`NDIlib_send_destroy` 让源从网络上消失 → noSignal；1 s 后同名重建发送端（新端口）| 源消失后 noSignal；重建后 **117 ms** 回 live（另一轮 120 ms），之后继续收帧；SDK 自己按名重连（我们的 `recv_connect` 重连 0 次、源变化事件 1）| 自动恢复 | ✅ |
| tally 回传 | `testNDI_loopback_tallyReachesSender` | PGM 到发送端 **10 ms**（另一轮 6 ms）；PVW、灭都对 | — | ✅ |
| BGRA（alpha）路径 | `testNDI_loopback_bgraWithAlpha_receivesBGRA_alphaPreserved`（720p60，下半 alpha 128 预乘）| 收到 BGRA、color sRGBFull；下半 A **128**（精确）、RGB 61–63（送 64，SpeedHQ 有损）；上半 A 255、RGB 125–127（送 128）；帧号解得出 | 收 BGRA、alpha 保留 | ✅ |
| 音频进环 | `testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned`（3 s，TestSignal）| 182 块 145 600 帧，每块 800 ± 1，重采样 0、拒 0；块首 host time 单调、平均间隔 16.667 ms（± 0.3）、最大间隔 < 一块 + 8 ms；正弦 RMS = 0.1/√2、click 峰值 1.00、两声道同内容；click 3 个 | 与视频同一时基 | ✅ |
| 源发现 | `testNDI_discovery_findsLocalSender` | 本机源 "PLUSDEMACBOOK-PRO.LOCAL (…)" @ 127.0.0.1:59xx 在 ≈ 1.5–3 s 内出现 | ≤ 8 s | ✅ |
| 抖动缓冲数学 ×6、重采样 ×2（无 SDK 也跑）| `NDIClockMapTests.testNDI_clockMap_*`、`testNDI_resampler_*` | 恒定传输 → 抖动 0、晚 3 ms 的帧抖动 3 ms；钟差 2 h 无关；传输永久多 10 ms → ≤ 2 s 基线跟上；更快的帧立刻成新基线；跳 5 s → 重置 1 次；44.1k → 48k 1 s 出 48000 ± 1 帧、与理想正弦最大误差 < 0.02、块边界连续 | — | ✅ |
| 无 SDK 行为 | `NDIUnavailableTests.testNDI_withoutSDK_*` | 本机有 SDK → XCTSkip；在"都不在"配置下真跑（§2.3） | 不崩、文案清楚、start 抛错 | ✅（矩阵 C）|
| W2-D 真发送端 → 本输入 | `testNDI_loopback_externalSource_manual`（设 `SWITCHER_NDI_LOOP_SOURCE`）| 本会话没跑（要另开终端跑 W2-D 的 `testLiveSend`，且 SwitcherOutputs 一编要拉 HaishinKit）；本测试的发送端走的是同一个 SDK 发送 API + 同样的 UYVY 测试图案，收端逻辑与发送方无关。**留给 G4 的 "NDI 回环 L1"**：headless / App 里 NDISender(PGM) → NDIInput 即可 | — | 未跑（手动项）|

### 2.2 DeckLink（SDK 头 10.11.2 副本，Fake 真跑；硬件 BLOCKED）

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| Fake 路径 1：帧到达 | `testDeckLink_fake_frameArrival_copiesPixels_calibratesTimestamp_poolReuses` | 1080p UYVY 40 帧：像素逐字节相同、序号 1…40、`calibrated = 1`、pts = 到达 − 一帧（± 0.2 ms 内）、帧时长 = 1001/60000 s；校准偏移离真值 2.8 µs、残差最大 5.2 µs、RMS 3.0 µs；signal_changed(1) 恰好一次；见过的 IOSurface ≤ 8（池复用）；起流参数：SetCallback、EnableVideoInput('Hp59' = 列表第一个, '2vuy', 带格式检测)、StartStreams 各 1 次 | — | ✅ |
| Fake 路径 1'：无硬件钟 | `testDeckLink_fake_frameArrival_withoutHardwareClock_fallsBackToArrival` | `calibrated = 0`、pts = 到达、`has_hardware_clock = 0`、报了文案 | — | ✅ |
| **Fake 路径 2：格式变更** | `testDeckLink_fake_formatChange_reopensWithDetectedModeAndPixelFormat` | 检测到 720p60 RGB444：Pause 1 → EnableVideoInput('hp60', 'BGRA', 带检测) → Flush 1 → Start（累计 2）；format_changed 报 1280×720 60000/1000 BGRA progressive；同模式只换色彩空间 → 再重开成 '2vuy'；events = 0 且像素格式没变 → 不重开；之后的 720p 帧按新格式交付；format_changes 2、reopen_failures 0 | — | ✅ |
| **Fake 路径 3：无信号** | `testDeckLink_fake_noInputSource_signalLostOnce_noFrames_recovers` | 10 帧 no-source：signal_changed 序列 [1, 0]（只报一次）、不交付、frames_no_source 10；信号回来 → [1, 0, 1] | — | ✅ |
| Fake 音频 | `testDeckLink_fake_audio_int32AndInt16_toFloatPlanes_timeFromStreamClock` | int32 / int16 交错 → 两路 float 平面（0.5 / −0.5 精确到 1e-6 / 1e-4）；包首 host time = 帧硬件时刻 − 16.67 ms（流时间差）± 50 µs；EnableAudioInput(48000, 32 / 16, 2) | — | ✅ |
| Fake 停 / 关 | `testDeckLink_fake_stopDisablesStreamsAndClearsCallback` | StopStreams 1、DisableVideo 1、DisableAudio 1、回调摘掉、停后帧不再交付 | — | ✅ |
| Swift 层状态机 | `testDeckLink_input_overFake_stateMachine_framesToSlot_audioToRing_watchdog` | 起流后 noSignal + "等待信号"；6 帧 → live、帧进槽（inputNumber 4、UYVY、bt709Limited、d = ingress − pts ≈ 一帧）、6 块音频 4800 帧（int32 1<<29 → 0.25）；no-source 帧 → noSignal + "无信号" 文案 → 好帧 → live；格式变更 → currentFormat 1280×720@60；**看门狗**：无回调 → noSignal 用时 **56.8 ms**（门限 50 ms + 定时器周期一帧）；回调回来 → live；stop 后 noSignal、回调摘掉 | — | ✅ |
| 校准器数学 ×3（无 SDK 也跑）| `DeckLinkCalibratorTests.testDeckLink_calibrator_*` | 第一个样本直接采用；残差 32 000 → 偏移 +1 000（1/32），负残差对称；阶跃 1 ms 后 5τ 内 < 10 µs；±20 µs 均匀抖动 2000 样本后偏差 < 6 µs、残差 RMS ≈ 11.5 µs | — | ✅ |
| 无硬件行为 | `DeckLinkHardwareTests.testDeckLink_noHardware_enumerationEmpty_inputNoSignalWithClearMessage` | 枚举 0 台；`start()` 不抛、state = **noSignal**（等设备），文案 "没有找到 DeckLink 驱动：安装 Blackmagic Desktop Video（/Library/Frameworks/DeckLinkAPI.framework）后重试，不用重启本程序"；轮询一轮不崩；stop 后 noSignal | 不崩、文案清楚 | ✅ |
| **L1 DeckLink** | `testL1_deckLinkInput_within3Frames`（真卡 + 真引擎，代码在）| — | ≤ 3 帧 | **BLOCKED-硬件**：解锁 = Mini Recorder / UltraStudio + Desktop Video 驱动 + 任意 SDI / HDMI 信号源；有了直接 `swift test --filter DeckLinkHardwareTests`，它打印 L1 和校准残差 |
| **L2 DeckLink** | `testL2_deckLink_endToEnd_manual` | — | SDI ≤ 100 ms 含设备 | **BLOCKED-硬件**：同上 + 外部显示 / HDMI 回环采集，按测试标准 §3 人工跑 |
| **S5 热插拔 20 次** | `testS5_deckLink_hotplug20Cycles`（`SWITCHER_DECKLINK_HOTPLUG_CYCLES=20`，按提示拔插，记恢复时间）| — | 崩溃 0、恢复 ≤ 3 s、设置保持 | **BLOCKED-硬件**：同上（Thunderbolt / USB 的 DeckLink 可拔插；PCIe 卡不适用）|

### 2.3 编译矩阵 + 全包测试 + lint

（本节由后台跑完后补：[A] 默认"都在"全包 swift test；[B] 只有 NDI；[C] 都不在；[D] make build；[E] make lint）

## 3. 没做的和原因

1. **DeckLink 的 L1 / L2 / S5 全部 BLOCKED-硬件**，桥接层从没对着真驱动跑过：这台机器没有 Desktop Video、没有卡。已验证的只有 Fake（同一组 COM 接口、同一段桥接代码）和"无驱动时不崩 + 文案"。真卡上要看的：`GetHardwareReferenceClock` 是否支持（不支持就退到到达时刻）、格式检测回调后重开的时序、`bmdFrameHasNoInputSource` 的实际节奏、热插拔通知有没有来。
2. **SDK 头是 10.11.2（2018）的副本，不是正式安装的 SDK**：代码对 10.11 与 ≥ 11.0 的差异只处理了 `IDeckLinkAttributes → IDeckLinkProfileAttributes`（按 `BLACKMAGIC_DECKLINK_API_VERSION` 宏选）。刻意没用 11.0 改了签名的 `DoesSupportVideoMode`（格式检测让它没必要）。用户装了正式 SDK（12.x / 14.x）到 ~/SDKs/DeckLink 后要重编一次看有没有别的改名——`sw_decklink_bridge.cpp` 用到的接口列在文件头。
3. **W2-D 真发送端 → 本输入的回环没在本会话跑**（§2.1 最后一行），G4 的 "NDI 回环 L1" 项用 headless / App 组装即可；`NDIInput` 与 `NDISender` 的对接只差组装方两行（`InputFactory` 的 `case .ndi`）。
4. **NDI 交错源**：`allow_video_fields = false`，交错源由 SDK 给整帧（按帧率），没有做场分离 / 反交错；没有交错源可测。`NDIlib_recv_color_format_UYVY_BGRA` 下 SDK 不会给 P216 / PA16 等 16-bit 格式，所以只处理 UYVY / BGRA / BGRX，别的计 `framesUnsupported`。
5. **非 48 kHz 音频用线性插值**（不做保音调 / 高阶滤波），NDI 几乎总是 48 kHz，这是兜底；单元测试只证明长度 / 连续 / 1 kHz 误差 < 0.02。
6. **NDI 带宽 lowest 只做了参数**，没有专门的测试（SDK 给低分辨率流，收端逻辑一样）。
7. **headless / App 接线**不在本会话目录里：`Tools/switcher-headless`、`App/Sources/Engine/InputFactory.swift`（W2-B2 留的 `case .decklink, .ndi, .audio: throw unsupported`）归 G4 / W3-E。构造签名与 W2-A 四种输入一致：`init(config:timing:videoSlot:audioRing:options:)`；DeckLink 要 `SwitcherDeckLink` 产品、NDI 要 `SwitcherNDI` 产品（project.yml 加两条产品依赖）。
8. **NDI 的 alpha 约定**：按预乘交给渲染器（渲染器约定预乘）。回环测试证明 SDK 不动 RGB / A（送什么收什么），但"别的发送端送的 BGRA 是预乘还是直通"我没找到 SDK 头里的说明（`grep -i premultipl` 为空）；NDI 文档的惯例是预乘。有第三方 alpha 源时看一眼边缘。

## 4. 对契约的疑问

1. **提案 008（待批）**：`InputSource.decklink` 加 `connection`，`.ndi` 加 `bandwidth` 与 `jitterBufferFrames`，都带默认值、老文件缺键按默认解（合成 Codable 对缺键会报错，落地时要显式写 `init(from:)`）。不批的话三项留在包内 Options，节目文件记不住。
2. **`Frame.pts` 对 NDI 的语义**：契约说 pts = "采集时刻换算成 host time"。NDI 收端拿不到采集时刻（发送端时间戳是"提交"时刻，且是另一台机器的钟），本会话定为 **pts = 到达 − 抖动 + J × 帧间隔**（§1.2）：走最快路径到的帧 pts 比到达晚 J 帧。这是把设计方案 §3.6 的"小抖动缓冲"用 pts 表达——唯一不会和引擎到达余量重复付延迟的做法（在输入里扣着帧不推、推时打"真实"pts 的话，引擎的余量估计器会把扣的时间当成 d 再加一遍）。与 W2-A 文件输入的 "pts = 拍点 − 半帧" 同一性质，请拍板是否接受；音频块 hostTime 同样加了 J×T（否则 A/V 差 J 帧）。
3. **DeckLink 的 `deviceID` 格式**（契约注释 "W3-A 定具体格式"）：`peid:<BMDDeckLinkPersistentID 的十进制>`；没有该属性的老卡 `model:<型号>#<同型号内序号>`；空串 = 第一台有输入的卡。`DeckLinkDeviceInfo.persistentID` 就是它，App 的设备列表直接存。
4. **`InputState` 在"驱动没装 / 设备不在 / 源不在"时用 noSignal 还是 error**：本会话都用 **noSignal + lastError 文案**（它们都会自动恢复：驱动装好、设备插上、源出现），只有"SDK 没编进来"和"起流失败"用 error。与 W2-A 的摄像头（权限被拒 = error）口径不同，理由是权限被拒不会自己好，这几样会。请拍板。
5. **DeckLink 内嵌音频声道数**：`Options.audioChannels` 默认 2，卡给 2–16；环的声道数由组装方定（现在 App / headless 都是 2）。要用 SDI 的 8 / 16 路时环得建大，或者在这里做"选哪两路"——契约没有"输入声道映射"的地方。

## 5. 下一个会话需要知道的坑

1. **SwiftPM 的清单会随环境变量重新求值**（`swift package dump-package` 验证过：`NDI_SDK_DIR=/nonexistent` 时 define 变 0），编译矩阵直接切环境变量就行，不用 make clean；但 Xcode 的集成可能缓存（W2-D 的经验），改了 SDK 路径要 `make clean`。
2. **两个包都包 NDI SDK 但不能共用一个模块**（§1 表最后一行）。以后谁再要 NDI（W3-C 的外部输出？）也走 C 封装，别再声明 `NDI` 系统库 target。
3. **NDI 同名源重开由 SDK 自己按名重连**（117–120 ms），我们的发现器兜底只在源换了名字 / 地址且 SDK 没跟上时起作用；`NDIInput.ndiCounters.reconnects` 为 0 是正常的。
4. **NDI 回环见过一次连续重复的帧号 (282, 282) 伴随一次 68 ms 的接收停顿**（第一轮 `testNDI_loopback_uyvy_*`，之后两轮没复现）：`sdkVideoDropped` 是 0，怀疑是 SDK 在收端停顿后把最后一帧重给了一次（或者发送端线程被抢占）。测试现在对"缺号 / 倒退"硬性 0、"连续重复"≤ 2 并打印邻域（帧号、序号、Δpts、Δingress、d）；再撞上时把那段贴到问题单。
5. **NDI 的 `timestamp` 是发送端系统钟的 100 ns 值**，两机钟差可达任意大；`NDIClockMap` 只用 d 的**变化**，所以不怕钟差，但发送端**对时跳变**会触发一次基线重置（那帧及之后 1–2 s 抖动估计从 0 起）。同一进程内的回环钟差 = 0。
6. **debug 构建下逐字节填 4 MB 的 Swift 循环要十几毫秒**：Fake 测试里"设硬件钟 → emit"之间不能夹这种事，否则量到的残差是测试自己的耗时（第一版就是这么错的）。发送端的 NV12 → UYVY 打包放在 C 里（`sw_ndi_pack_uyvy_from_nv12`），TestPattern 的灰底填充是按行 `update(repeating:)`，debug 下每帧几百微秒，够 60 fps。
7. **CVPixelBufferPool 要给上限**（`kCVPixelBufferPoolAllocationThresholdKey`）：测试把 Frame 存进数组时池会一直长；上限 8 到了返回 `kCVReturnWouldExceedAllocationThreshold`，计 `framesPoolExhausted`。渲染器纹理表每路 16 项，8 块够。
8. **DeckLink 看门狗超时后帧恢复时桥接层不会再发 `signal_changed`**（它眼里信号没断过），Swift 层的 `onVideo` 自己把状态拉回 live——改状态机时别删这一句。
9. **DeckLink 的 `sw_decklink_hotplug_subscribe` 装的是进程级 IDeckLinkDiscovery**，SDK 在安装时会对每台已连接的设备补发一次 Arrived；`onHotplug` 对 `session != nil` 的 arrived 不动。多路 DeckLink 输入共用一个订阅表。
10. **Fake 的 `GetHardwareReferenceClock(scale)` 换算用 `__int128`**：纳秒级的时钟值（uptime ≈ 1e14 ns）× 10⁹ 会溢出 int64；真驱动内部怎么算是它的事，但我们请求的 timeScale 是 10⁹，读出来直接是 ns。
11. **`sw_decklink_session_stop()` 不在持锁时调 SDK 的流控制**：先置 running = false（回调看到就退出）再 `StopStreams()`（它等回调线程退出），然后再摘回调 / Disable。反过来会死锁。格式变更回调里的 Pause/Enable/Flush/Start 是在持锁 + 驱动线程上做的，与 stop 并发时靠 SDK 内部串行。
12. **NDI 发送端测试助手 `TestNDISender`** 在 `Tests/NDITests/Support/`，按拍点时钟实时送测试图案（帧号 = 拍号）、UYVY / BGRA、可选 TestSignal 音频；G4 / W3-C 想要一个不依赖 SwitcherOutputs 的 NDI 源时可以抄它。
13. **`InputThread(period:)` 给发送端线程挂了 time-constraint 策略**，60 fps 送 1080p 晚点 0；不挂的话普通线程唤醒晚 1–7 ms（W1-A / W1-B 的经验）。
14. **电池供电下跑的**：本报告所有延迟数字都是 M5 Max 电池模式 + 另有会话在跑（load 3.3）的结果，插电空闲机器只会更好。
