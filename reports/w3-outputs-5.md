# W3-C4 输出止血：D05 音频环覆盖正在读的块、D12 tee 分支泄漏、D08 NDI 直出 BGRA / UYVY、D09 虚拟摄像头扩展没存 client —— 报告（分支 w3-outputs-5）

日期 2026-10-18。机器 Apple M5 Max / macOS 27.0.1 (26A434) / Xcode 27.1 (27A9275, Swift 6.4)，NDI SDK 6.3.2 在 `/Library/NDI SDK for Apple`。
prompt 118（Codex 2026-10-13 审查 §1.2 D05、§1.3 D08 / D09 / D12；用户 2026-10-17 定）。从 main **358517f**（G9 合入之后）开；
harness 开的分支 `worktree-agent-a084dea82a0342d2f`，另打别名 **`w3-outputs-5`**（`make lint BRANCH=w3-outputs-5` 按它查归属），两者同一个头。
提交：`git log main..w3-outputs-5`，四对"先红后绿"（D05 / D12 / D08 / D09 各一个红提交、一个实现提交）+ 本报告。
改动只在 `Packages/SwitcherOutputs/Sources/{SwitcherOutputs/Support,Streaming/PCMBlockRing.swift,NDISend,ISO}/`、`Packages/SwitcherOutputs/Tests/`、
`CameraExtension/Sources/` 与本报告；App/、Package.swift、project.yml、契约、测试标准、阈值都没碰。同机另有 115 / 119 / 120 会话在跑，跑 Outputs 整包前确认过没有别的 mediamtx。

## 1. 做了什么

每条先按 Codex 写的触发条件写失败用例、跑红、提交，再改实现转绿。

### D05 三个音频环 pop 之后被 push 覆盖（S0）

- **根因**（与 Codex 一致）：`AudioBlockRing`（录制）、`PCMBlockRing`（推流）、NDISender 里的 `PCMRing` 的 `pop` 把槽还给队列，却把槽内指针交给锁外读；
  队列原本满时下一次 push 的尾槽 `(head + count) % capacity` 正好是刚 pop 的那一格——一次 push 就覆盖消费者（录制 writer / 推流音频编码线程 / NDI 发送线程）正在读的块，
  样本是新块的、PTS 还是旧块的。不用等 capacity − 1 次 push，原注释说错了。
- **做法：消费者独占的预分配出口块**（prompt 给的两种之一）。每个环 init 时多分配一块 `channelCount × maxFrames` 的出口块，`pop` 在锁内把最旧那一槽拷进去、再把槽还给队列，
  交出去的是出口块的视图（到下一次 pop 之前有效——`Block` 的注释本来就这么写，现在实现兑现它）。push 从不碰出口块。
  - 不选借出 / 归还：那要改满了的丢块策略（丢新块），录制 / 推流 / NDI 三方的丢块记账口径都得跟着变；而且 Recorder.swift / StreamOutput.swift 不在本会话目录里，出口块方案调用方一行不改。
  - 不分配：出口块 init 时分配，pop / push 都不分配。多出来的拷贝在锁内，一块 256 帧 × 2 声道 ≈ 2 KB；两头都不是实时线程（生产者是集成层的非实时泵，消费者是 writer / 编码 / 发送线程）。
    锁照旧是原来那把 `OSAllocatedUnfairLock`，没加新锁。只许一个消费者（三处都是：writer 串行队列、推流 audioLoop 线程、NDI 发送线程，stop 都等线程退出）。
  - NDI 的 `PCMRing` 原来没有 precondition，保持没有（声道数 0 的配置行为不变）。
- **端到端背压探针**（prompt"顺带 20 s 满队列听测"）：`RecorderBackpressureTests` 用 `AudioBlockRing.consumerStallMicrosecondsForTesting`（只在 DEBUG 构建里有，默认 0）
  让录制器 writer 每次 pop 之后睡 10 ms 才读块 → 消费 ≤ 100 块 / 秒 < 生产 187.5 块 / 秒，环（256 块）约 2.9 s 后满、之后一直满。录 720p60 + LPCM 24 bit：
  声道 0 = 块签名（第 k 块整块 = (k mod 2048 + 1) / 4096，24 bit 精确，读回逐值核），声道 1 = TestSignal（1 kHz −20 dBFS 正弦 + 每秒 click）给人听。
  默认跑 6 s；`SWITCHER_D05_BACKPRESSURE_SECONDS=23` 是满 20 s 那一版。现象见 §2 表末两行与 §5 第 3 条。

### D12 tee 分支泄漏（S2）

- `InputFrameTee.addBranch` 每试一格 CAS 都 `passRetained`、失败的不 release：第 n 个分支多留 n − 1 个强引用，满额失败的申请留 4 个；
  removeBranch / reclaimRetired / deinit 只放装上的那一次 → 这些分支槽（可能拿着末帧像素缓冲）永远不销毁。
- 改成循环外 retain 一次：装上了引用归格子，四格都占着就当场 release。
- 为了数析构：`LockFreeFrameSlot` 是 final 类，数不了 deinit，`InputFrameTee` 加了一个 internal 的分支槽工厂 `init(primary:makeBranchSlot:)`（public 的 `init(primary:)` 仍是 `LockFreeFrameSlot(capacity:)`），
  测试换成记弱引用的 `SlotTracker`。

### D08 NDI 直出 BGRA / UYVY 没画面（S1）

- `NDISender.VideoRoute`：按像素格式分路，放在 `sendVideo` 里、在转换方式之前，所以 gpu / cpu / auto 三种一样放开（prompt 的"GPU 分支同样的格式守卫放开"）——
  - NV12（'420v' / '420f'，引擎的 PGM / PVW / 多画面和 NV12 的输入）：照旧转 UYVY（GPU / CPU）；
  - UYVY（CoreVideo '2vuy'，字节序 Cb Y0 Cr Y1 = NDI 的 UYVY）、BGRA：**不转、不拷**，按帧的原尺寸与行距直接交给 `NDIlib_send_send_video_async_v2`（FourCC UYVY / BGRA）；
  - 别的格式送不了（契约 `PixelFormat` 只有 nv12 / bgra / uyvy 三种，输入只出这三种，用例核过三种两种 range 都不是 unsupported）。
- NDI 异步发送要求内存保持到下一个同步点：直送的输入缓冲**锁着只读、留着引用**到下一次 send_video_async 返回之后才解锁放掉（同一缓冲连送两拍锁计数 2 → 1，照样平衡），
  stop 里 `send_video_async(nil)` + destroy 之后放最后一帧。NV12 的双缓冲照旧。
- **连续送不出去 → Stats failed**：没送出去的帧（转换失败 / 直送缓冲锁不住 / 像素格式送不了）照旧计 `conversionFailures`；
  连续 `NDISender.failureStreakLimit = 10` 帧 → `NDISendCounters.sendFailing = true` → `statsEntry` 的 state = "failed"、uptime_s 0、last_error 写像素格式
  （例："NDI 送不了像素格式 'yuvs'（只认 NV12 / UYVY / BGRA），连续 10 帧没送出"；文案只在翻状态那一帧拼，失败的每帧本身不拼串）；
  送出去一帧就回到 publishing，last_error 留到下一次 start（022 口径）；start 清 sendFailing 与连败计数。App 不动：底栏 / 状态面板本来就显示 failed + last_error。
- 顺手修同一条路上的一处：CPU 转换原来按**节目尺寸**写、行距 = 节目宽 × 2，源是比节目小的 NV12 输入时送出去的是节目尺寸、右边 / 下边是上一帧的残留；
  改成与 GPU 版一样按帧尺寸（不超过节目尺寸）、行距紧排（用例核了 CPU / GPU 逐字节相同）。比节目大的 NV12 输入仍裁左上（两版本来都这样，§3）。

### D09 虚拟摄像头扩展没存 client（S1）

- 探针（铁律 10）：本机 SDK `MacOSX27.0.sdk` 的 `CMIOExtensionStream.h` 里 `CMIOExtensionStreamSource` 协议的起停入口是 `authorizedToStartStreamForClient:`（带 client）
  → `startStreamAndReturnError:` / `stopStreamAndReturnError:`（不带 client），**没有**带 client 的 startStream；`CMIOExtensionClient` 是 `NSObject<NSCopying>`、init 不开放，
  有 `clientID`（NSUUID）。所以获准的 client 只能在授权回调里记下。
- `CameraExtension/Sources/SinkStreamState.swift`（新）：sink 的起停状态机，纯逻辑、对 client 泛型、不 import CoreMediaIO——授权回调记下获准的 client（被拒的不记、不顶掉之前获准的）；
  `start()` 用它开一轮（新的一代），没有获准的 client 返回 nil；`stop()` / `disconnect(id:)`（按 clientID 认，NSCopying 的对象未必是同一个）/ 不 stop 再 start 都换代，
  `consumeSampleBuffer` 的回调先看开链时的代次，不是当前的就不转发、不再续——任何时候只有一条链在读（原来 stop 再 start 有两条链抢着读、乱序发出去的窗口）。
- `CameraExtensionProvider.swift`：`authorizedToStartStream(for:)` 签名校验照旧、获准的记进状态机；`startStream()` sink 方向用记下的 client 起 `consumeNext(from:generation:)`，
  没有获准的 client 就抛 `CameraExtensionError.noAuthorizedSinkClient`（主程序的 `CMIODeviceStartStream` 失败，不再"起了但从不消费"）；`stopStream()` / provider 的 `disconnect(from:)` 停这一轮、
  还有人读 source 就回到占位画面；**删掉协议外的 `startStream(for:)`**；source / sink 起停拆成 `startSource / stopSource / startSink / stopSink`（占位画面接管不变）；
  `@preconcurrency import CoreMediaIO`（`CMIOExtensionClient` 没标 Sendable，续链的回调要捕获它；原来两条 Sendable 警告，现在 0）。
- 状态机怎么进测试：扩展 target 只在 Xcode 工程里（project.yml 按目录收 `CameraExtension/Sources`，新文件自动带上），SwiftPM 的测试编不到它；
  `Packages/SwitcherOutputs/Tests/VirtualCameraTests/SinkStreamState.swift` 是指向 `../../../../CameraExtension/Sources/SinkStreamState.swift` 的**符号链接**（git mode 120000，仓库里第一个），
  VirtualCameraTests 把它编进来测。先在 scratchpad 里写了个两文件的小包探过：SwiftPM 6.4 能编包根之外的链接目标。
- `make gen` 后 `xcodebuild -target SwitcherCameraExtension clean build`（ad-hoc）通过，arm64 + x86_64，0 警告。实机验收仍 BLOCKED-签名（§2 末行、§5 第 6 条写了签名环境要验什么）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：先 `swift build -c release --package-path Tools/frameprobe`，再 `swift test --package-path Packages/SwitcherOutputs`（debug，01:42–02:11，同机另有两个会话在跑 Audio / Core 的包测试）。
**整包 156 个用例 = 152 过 + 4 跳 + 0 红**（VirtualCameraTests 19 / 1 跳、SwitcherOutputsTests 29、StreamingTests 61、NDISendTests 17 / 2 跳、ISOTests 15、ExternalTests 15 / 1 跳），
其中本会话新加 27 条（main 上是 129 条）。四个跳过：D09 签名环境端到端（BLOCKED-签名，新）、NDI Studio Monitor 人工真发、"SDK 不在"空实现（本机有 SDK）、外部显示 L2 人工秒表——后三个原来就跳。
`scripts/check-rt-symbols.sh`：CSwitcherAudioRT 4 个目标文件无禁用符号（本会话没动 C 热路径）。扩展 target 见 §1。
`make lint BRANCH=w3-outputs-5`：C 与 UTF-8 两种 locale 都全绿（禁词 / 版本号 / Package.swift / 依赖方向 / 归属 15 个文件 / 手册 / 链接 / RT 符号）。
`swift build --package-path Tools/switcher-headless` 编过。App 没重编（同机 119 在跑 App 的 xcodebuild，没去抢）：包的公开接口只加不改——`InputFrameTee(primary:)` 签名不变（App 唯一的调用点 InputRuntime.swift:147）、`NDISendCounters` 多一个 `sendFailing`、`NDISender` 多 `VideoRoute` / `failureStreakLimit` / `pixelFormatName`，G10 合入时 App 照常编。

D05 / D12 / D08 / D09 是 Codex 审查的缺陷编号，A1 = 测试标准的音频断裂指标；这些用例没有测试标准里的数值阈值，判据是"读到的块就是它自己 / 槽全部销毁 / 帧送出去"，按 0 容忍写。

| 测试 ID | 测试函数 | 修前（红） | 修后 | 判据 | 通过 |
|---|---|---|---|---|---|
| D05 / A1 录制环 | `SwitcherOutputsTests.AudioBlockRingTests.testD05_A1_fullRingPopThenPush_poppedBlockKeepsSamplesAndPTS` | 容量 2 / 128 / 256 都读到第 999 块的样本、PTS 仍 1 | 读到第 1 块、PTS 1、帧数 4、这次 push 不丢 | 样本 = 自己那块 | ✅ |
| 同上 | `…testD05_A1_interleavedPopPushOnFullRing_everyBlockIntact_dropAndUnderrunAccounting` | 第 0 轮就读到后来的块（容量 2 读到第 3 块，128 读到 129…） | 满队列 pop / push 交错 3 × 容量 轮每块完整；不 pop 连推 5 块 → dropped 5、push 返回 true、丢的正好是最旧 5 块；空环 pop = nil、深度 0、之后照常 | 丢块 / 欠载记账精确 | ✅ |
| 同上 | `…testD05_A1_concurrentFastProducerSlowConsumer_noTornBlocks` | 0.4 s：推 49 954、丢 30 273、收 19 681，**读错 19 659** | 推 39 576、丢 22 683、收 16 893、读错 0；推 = 收 + 丢；dropped 与环一致 | 读错 0 | ✅ |
| D05 / A1 推流环 | `StreamingTests.PCMBlockRingTests`（同上三条 + `testD05_monoInputReplicatedToStereo`） | 999 / 交错同上；并发读错 19 674 / 19 693 | 全对；并发读错 0（推 46 512、丢 27 864、收 18 648）；单声道进立体声照旧复制 | 同上 | ✅ |
| D05 / A1 NDI 环 | `NDISendTests.PCMRingTests`（同上三条） | 999 / 交错同上；并发读错 19 689 / 19 708 | 全对；并发读错 0（推 48 057、丢 29 435、收 18 622）；满了 push 返回 true 5 次（NDISender 计 audioBlocksDropped） | 同上 | ✅ |
| D05 / A1 端到端（默认 6 s） | `SwitcherOutputsTests.RecorderBackpressureTests.testD05_A1_recorderBackpressure_recordedBlocksWholeOrDropped` | 整块 692 里 **229 块错位**（写的是约 256 块之后的样本，最大差 259 块）、48 处重复 / 倒退；环满丢 433 | 整块 691、跳号 434（= 丢块）、补静音 96 段共 2314.7 ms、错位 0（最大差 3 块 = 录制器一帧的校正容差内）、不整块 0、重复 0；6.5 s | 错位 / 混块 / 重复 0 | ✅ |
| D05 / A1 端到端满 20 s（`SWITCHER_D05_BACKPRESSURE_SECONDS=23`） | 同上 | 喂 4313 块：环满丢 2342；写进去 1971 块里 **1269 块错位**、278 处重复 / 倒退；补静音 510 段 12.49 s；正弦相邻样本跳变 > 0.04 共 653 处 | 喂 4313 块：环满丢 2361；写进去 1952 整块、跳号 2361 = 丢块、错位 / 不整块 / 重复 0；补静音 519 段共 12.59 s（= 2361 × 5.333 ms），最长 42.7 ms；跳变 458 处；视频 1380 帧（writer 不接 0）、音频 23.00 s | 同上 | ✅ |
| D12 析构计数 | `ISOTests.TeeLifetimeTests.testD12_teeReleaseDestroysAllSixSlots_primaryFourBranchesAndRejectedRequest` | primary + 4 分支 + 1 次满额失败 = 6 个槽，tee 释放后**还活着 4 个**（第 2–4 分支 + 失败申请），第二个分支 weak 非 nil | 6 个全部销毁、两个分支 weak 都 nil、tee 自身释放 | 存活 0 | ✅ |
| 同上 | `…testD12_rejectedRequestReleasesItsSlotImmediately` | 每次满额失败多活一个（6 / 7 / 8） | 三次失败之后仍只活 primary + 4 分支 | 存活 5 | ✅ |
| 同上 | `…testD12_repeatedOpenCloseOfLaterBranches_slotsReclaimedAfterGrace` | 第 0 轮回收之后还活着 5 个 | 20 轮开关第 2–4 分支、过回收期之后只剩 primary + 常驻分支（2） | 存活 2 | ✅ |
| 同上 | `…testD12_retiredBranchLivesThroughGraceThenDies_deinitReleasesRetired` | 摘下的第二个分支回收后仍活着、deinit 后还剩 1 | 回收期内活着、过了就销毁、deinit 一并放 retired 表 | 存活 0 | ✅ |
| D08 三种像素缓冲 | `NDISendTests.NDIDirectFormatTests.testD08_threePixelFormats_oneFrameEach_allSentInEveryConversionMode` | gpu / cpu / auto 都只送出 NV12 那一帧，另两帧 conversionFailures 2 | NV12 1920×1080 / UYVY 1280×720 / BGRA 1600×900 各一帧：收到 = 送出 = 3、失败 0、跳 0、state publishing（干跑） | 计数与 state | ✅ |
| D08 连续送不出去 | `…testD08_unsupportedPixelFormatStreak_marksFailedWithFormat_thenRecovers` | 'yuvs' 30 帧之后 state 仍 publishing、last_error 空、uptime 照涨 | 3 帧不翻；30 帧 → failed、uptime_s 0、last_error 带 'yuvs'；一帧 BGRA → publishing、last_error 留着；再 start 清 | failed + 像素格式 | ✅ |
| D08 分路表 | `…testD08_videoRouteByPixelFormat_andFormatNames` | （新接口） | '420v' / '420f' 转、'2vuy' / 'BGRA' 直送、yuvs / ARGB / RGBA / v210 送不了；契约三种两种 range 都送得了；名字 BGRA / 2vuy / 420v / yuvs / 0x00000020 | — | ✅ |
| D08 小尺寸 NV12 | `…testD08_nv12SmallerThanProgram_cpuAndGpuConvertAtFrameSize` | CPU 版送 1920×1080（行距 3840，右下残留） | CPU / GPU 都 1280×720、行距 2560、逐字节相同 | — | ✅ |
| D08 真接收端回环 | `…testD08_realReceiverLoopback_UYVY_BGRA_NV12` | NV12 收到；UYVY / BGRA 10 s 内一帧都没有（发送端 conversionFailures 772） | 同进程 NDI 接收端（SDK C 接口，BGRX_BGRA）：UYVY 收到 1280×720、中心 RGB (195, 148, 118) / 期望 (195.5, 148.1, 118.0)；BGRA 收到 1600×900（FourCC BGRA）、(215, 158, 41) / (220, 160, 40)；NV12 收到 1920×1080、(83, 100, 123) / (83.5, 99.5, 123.2)；失败 0、state publishing；整条 1.5 s | 原尺寸、色差 ≤ 14 | ✅ |
| D09 授权 → 起流 | `VirtualCameraTests.SinkStreamStateTests.testD09_authorizedClientIsWhatStartStreamConsumes` | （原实现：授权不存、startStream 传 nil） | 获准的 client 就是 start 消费的那个、这一代要续 | — | ✅ |
| 同上 | `…testD09_noAuthorizedClient_startFails_rejectedClientNotStored` | — | 没授权 / 被拒 → start nil（扩展抛错）；被拒的不顶掉之前获准的 | — | ✅ |
| 同上 | `…testD09_stopEndsSession_oldConsumeChainStops` | — | stop 后旧代不续、重复 stop 无事、再 start 是新一代 | — | ✅ |
| 同上 | `…testD09_restartWithoutStop_onlyNewestChainContinues_usesLatestAuthorizedClient` | — | 不 stop 再 start：只剩新链、用最近获准的 client；授权本身不打断在跑的一轮 | — | ✅ |
| 同上 | `…testD09_disconnectByClientID_stopsAndForgets_othersIgnored` | — | 按 clientID（另一个 UUID 对象）认出正在消费的 client → 停并忘掉；别的 client 断开无事；只授权没起流的断开清记录 | — | ✅ |
| D09 接线（静态核 + SDK 探针） | `…testD09_extensionWiredToSDKProtocol_noStartStreamForClient` | 红：扩展源码有 `startStream(for`、`client: nil`、没走 SinkStreamState | 都没有了；`startStream() throws` / `stopStream() throws` / 授权回调在；SDK 头文件协议里有 start / stopStreamAndReturnError、authorizedToStartStreamForClient，没有 startStreamForClient | — | ✅ |
| D09 签名环境端到端 | `…testD09_signedExtension_consumesPGMFromSinkClient` | — | XCTSkip **BLOCKED-签名**（系统扩展要 Apple 签发的证书 + App 在 /Applications）；解锁条件与要验的步骤见 §5 第 6 条 | — | 跳 |
| 回归 | 包源码中文字面量 `SourceLanguageTests`（扫 CameraExtension / ISO 等） | — | 0 处（新文件与改动的日志 / 错误都是 ASCII） | 0 | ✅ |

## 3. 没做的和原因

1. **D09 实机验收**：BLOCKED-签名（Team ID 证书 + `/Applications`；`systemextensionsctl developer on` 要关 SIP）。能单元测的状态机与接线做了，签名环境要验的步骤写在 §5 第 6 条。
2. **"听测"没有人耳听**：会话里听不了；用声道 1（1 kHz 正弦）的静音段 / 相位跳变当听感代理量，录像留在本机会话临时目录（会被清，要留请拷走）
   `/private/tmp/claude-501/-Users-plus-plusmix--claude-worktrees-g8-contract-merge-main-1bd20d/2ab16232-635a-4756-ad1a-5debdbcffd78/scratchpad/d05-out-before/d05-backpressure-23s.mov`（修前）与同目录下 `d05-out-after/d05-backpressure-23s.mov`（修后）；
   要听开右声道（左声道是块签名的直流台阶）。重录：`SWITCHER_D05_BACKPRESSURE_SECONDS=23 SWITCHER_TEST_OUTPUT=<目录> swift test --package-path Packages/SwitcherOutputs --filter SwitcherOutputsTests.RecorderBackpressureTests`。
3. **比节目大的 NV12 输入仍裁左上**（CPU / GPU 两版本来都这样）：prompt 说 NV12 走现有转换，没改；NDI SDK 原生认 NV12，以后可以让 NV12 的"输入 n"也直送原尺寸（§5 第 4 条）。
4. **BGRA 的 alpha 口径没改**：按 prompt 直送 FourCC BGRA（NDI 保留 alpha）；与本仓库"BGRA = 预乘"的约定有出入，交用户定（§4 第 2 条）。
5. 按 prompt 不做：K01 / D06（App，119）、HaishinKit 升级、SRT passphrase 转义、任何阈值。KNOWN_ISSUES 的 D05 / D08 / D09 / D12 四行销号归 G10（docs/ 不在本会话目录里）。

## 4. 对契约的疑问

1. **NDI 的 `state = failed` / `last_error` 含义扩了**（prompt 定的：连续送不出去 → failed + 像素格式）：字段、取值集合都没变，但 `Stats.swift` 的注释（EncoderEntry.state / lastError 两处）与
   `docs/CONTRACTS.md` 的 encoder[] 说明（019 / 022 那几段）现在写的是"NDI failed = SDK 在但 initialize / send_create 失败""NDI last_error = SDK 不在 / initialize / send_create 失败的文案"。
   建议契约会话（P5-4 / G10）补一句"或在跑但连续 `NDISender.failureStreakLimit` 帧没送出去（D08，last_error 写像素格式）"，只改文字。要不要另写提案请用户定；本会话没动 SwitcherContracts。
2. **BGRA 直送的 alpha**：本仓库的 BGRA 是预乘 alpha（Compositor.metal 头注释；ImageInput 用 premultipliedFirst 画），NDI SDK 文档写 BGRA "not pre-multiplied"。
   现在按 FourCC BGRA 直送：不透明的源没有区别；半透明的边（PNG 的抗锯齿边、阴影）到下游会比应有的暗；alpha 字节没意义的源（DeckLink 的 RGB 采集，没硬件没验）下游可能当透明。
   另一个选择是一律按 BGRX（当不透明）送——一行改动，代价是下游拿不到 alpha（不能在下游抠 PNG 角标）。请用户定用哪种。
3. 连续多少帧算"连续送不出去"prompt 没给数，取了 10 帧（60 fps 约 0.17 s；偶尔一两帧 GPU 纹理建不出来不翻状态）。它不是测试标准里的阈值，是实现常量 `NDISender.failureStreakLimit`；要改口径请用户说。

## 5. 下一个会话需要知道的坑

1. **仓库里第一个符号链接**：`Packages/SwitcherOutputs/Tests/VirtualCameraTests/SinkStreamState.swift` → `CameraExtension/Sources/SinkStreamState.swift`。
   挪 / 改名扩展里那个文件要一起改链接；拷工作树别用不跟链接的工具。SourceLanguageTests 只扫原文件（CameraExtension/ 下），链接所在的 Tests/ 不扫。
2. **`AudioBlockRing.consumerStallMicrosecondsForTesting` 是进程级开关**（只在 DEBUG 里有）：只有背压探针设它、用完置 0；XCTest 默认串行跑，别把这条和别的录制用例并行。
   `swift test -c release` 时这条 XCTSkip。默认 6 s 那一版已进整包；满 20 s 的要手动 `SWITCHER_D05_BACKPRESSURE_SECONDS=23`（约 24 s）。
3. **满队列的听感**（修后，23 s 录像的数）：环满之后整块丢（计 audioBlocksDropped）。丢的累计不到一帧（16.7 ms）时录制器直接拼接下一块——正弦上一声"咔"（相邻样本跳变 458 处，其中约 46 处是测试信号 click 自身的两条边）；
   超过一帧就按 audioResync 补静音对齐 PTS（519 段、最长 42.7 ms、共 12.6 s，占 23 s 的一半多）。听起来是一段一段断开的正弦夹着咔哒声，A/V 仍对齐（音轨 23.00 s、视频 1380 帧）；
   修前同样的条件下还有 64% 的块是约 1.37 s 之后的声音（错位 1269 块）。另：按代码 drainAudio 一口气排到环空为止，持续背压时 writer 队列里的视频样本排在它后面（这次 writer 没拒视频帧、文件完整；录制器在持续背压下的调度归 W1-E 留意）。
4. **NDI 直送**：UYVY / BGRA 输入帧按原尺寸送（比节目小不放大、比节目大不裁）；直送的那一帧锁着、留着引用到下一帧送出去，所以输入的缓冲池会被多占一个。
   NV12 的"输入 n"仍转 UYVY、比节目大的裁左上（§3 第 3 条）——以后想改可以让 NV12 也直送（NDI 原生认 NV12，FourCC NV12、p_data = Y 平面、要求 CbCr 平面紧跟 Y 平面，IOSurface 的两平面不一定相邻，要先探）。
5. **NDI 真接收端回环用例**要本机 NDI 发现（mDNS）能找到同进程的源：有 SDK 但发现不了时 15 s 后**红**（不是跳）；同机别的会话也开 NDI 源不影响（源名带 pid）。
6. **D09 签名环境要验什么**（`DEVELOPMENT_TEAM=… make gen`、App 放 /Applications、激活扩展之后）：
   (a) 主程序开虚拟摄像头输出，Console 里 `app.switcher.camera-extension` 没有 "sink startStream without an authorized client"，主程序的 VirtualCameraOutput 进 publishing、frames 在涨、'sonp' 回报不跳号；
   (b) QuickTime → 新建影片录制 → 摄像头选 PlusMix：是 PGM，不是深灰底 + 移动白条的占位画面；
   (c) 主程序里停 / 开虚拟摄像头几次：画面接着来、不乱序、'sonp' 序号连续（不会两条链抢着读）；
   (d) QuickTime 开着时退出主程序：约一秒内回到占位画面（disconnect 路径）；再开主程序又是 PGM；
   (e) 非 PlusMix 签名的进程写 sink 被拒（可选）。startStream 现在在没有获准 client 时会抛错——要是 (a) 里主程序起流失败、Console 有那条错误，说明系统没先调授权回调，回来看 SinkStreamState。
7. 跑 Outputs 整包前先 `swift build -c release --package-path Tools/frameprobe`；整包这次 29 分钟（StreamingTests 865 s、录制 761 s），MediaMTX 用例与 `$TMPDIR/switcher-streaming-tests/` 是写死共用的，跑之前看 `ps -axo comm` 有没有别的 mediamtx / xctest。
8. 本 worktree 跑过 `make gen`（Switcher.xcodeproj 不入库）和 `xcodebuild -target SwitcherCameraExtension`（产物在 `.build/xcb-ext/`，不入库）。
