# W1-A2 报告：合成源噪声底纹 + frameprobe 补课（w1-testkit-2）

分支：`w1-testkit-2`（harness 分支 `claude/synthetic-noise-frameprobe-6102b8`，worktree `.claude/worktrees/synthetic-noise-frameprobe-6102b8`），从 main `2fdf52d`（P2 合入后）开，3 个提交（`cf2b508`、`d0028f2`、`35a6188`）。
只动了 `Packages/SwitcherTestKit/`、`Tools/frameprobe/`、`Tests/Fixtures/`；`make lint BRANCH=w1-testkit-2` 全绿（禁词 / 版本 / 依赖方向 / 归属 / rt-symbols）。
机器：M5 Max 128 GB，macOS 26.6.2，Xcode 27.0（Swift 6.4），接电源；量数字时别的会话在跑 `swift test`（load 3–6），实跑类数字有这个背景。

## 1. 做了什么

### 1.1 合成源噪声底纹（prompt 交付 1）

契约 006 已经把 `.noise(level:amplitude:seed:)` 和 CPU 参考实现放进 `TestPattern.draw`，`SyntheticVideoInput` 直接就能画；本会话做的是**成本**：

- **`NoisePatternRenderer`**（`Synthetic/NoisePatternRenderer.swift`，Metal 计算着色器）：一条核画亮度平面（噪声 + 帧号 / 时间戳 / ID / 闪光四样覆盖物，顺序同契约）、一条核画色度平面，写进 IOSurface 背后的 NV12 缓冲，**逐像素与 `TestPattern.draw` 相同**（测试全帧逐字节比，4 个尺寸 × 4 组参数，含 322×180 的奇数宽）。做法：契约的噪声是 SplitMix64，行内第 k 对像素的状态 = 行种子 + (k + 1) × 黄金比常数，每个 GPU 线程独立算自己那两个像素，不用顺序迭代。着色器、管线、limited-range 查表进程共享（第一次用时从源码编译），每个输入自己一条命令队列和一份"IOSurface → 纹理"表（池里 12 个缓冲在 init 时预建）；每帧只 `setBytes` 参数块 + 两次派发 + `waitUntilCompleted`，Swift 侧不分配（Metal 的命令缓冲 / 编码器包在 autoreleasepool 里，与 W1-C 渲染线程同一做法）。
- **`SyntheticVideoInput`**：`init(..., noise: NoiseBackend = .auto)`，`.auto` = 有 Metal 就 GPU 否则 CPU，`.cpu` = 契约参考实现，`.gpu` = 没有 Metal 就抛错；环境变量 `SW_SYNTHETIC_NOISE=cpu|gpu` 能改 `.auto`（headless / gate 不改参数就能 A/B）。init 里预热一帧（第一次真正派发要几毫秒，8 路同时起时 30 fps 那路第 0 帧赶不上第 0 拍，实跑录制文件第 0 帧黑场，预热后正常）。`Counters` 加 `drawCPUSumNs`（生产者线程 CPU 时间，`CLOCK_THREAD_CPUTIME_ID`）和 `gpuBusySumNs`（命令缓冲 GPUStart/End），`meanDrawCPUMs` / `meanGPUBusyMs`；`usesGPUNoise`。`NV12PixelBufferPool.forEachBuffer`（内部）给渲染器预建纹理。
- 为什么上 GPU（数字在 §2.1）：CPU 参考实现 1080p 一帧 1.1 ms（release 背靠背）、按 60 fps 节奏 1.7–4 ms；8 路 G3 场景实跑 CPU 版进程 CPU 65.6%（S3 必须档 ≤ 60% 被测试工装自己撑爆），GPU 版 20.7%（灰底 12.2%）。
- `M0Factory` / `G3Factory` 没动（Tools/ 是检查点目录；G4 改噪声）。E2 的验证用本会话在 scratchpad 里改出来的 g3 噪声 show 跑 headless（§2.2）。

### 1.2 frameprobe av（prompt 交付 2 / 3 / 4）

- **音轨时间轴**（问题单 W2D-w1-testkit-frameprobe-av-on-stream-recordings）。探针（§5 第 1 条）证实：AVFoundation 对**没有编辑列表的分片文件**把每条轨各自归零（音轨 tfdt 960 = 20 ms 直接丢掉；两条轨的 tfdt 各加 1 s 它仍报 0 / 0），又对 AAC 自己合成一条 2112 样本的 priming 剪裁（直通样本带 `TrimDurationAtStart = 2112`，`AVAssetTrack.segments` 是 `src 0.044 → tgt 0`）却不挪时间轴。新加 `MP4Index`（只读 box 头：trak 的 tkhd / mdhd / hdlr / stsd / edts.elst，每条轨第一个 moof 的 tfdt；不读 mdat，GB 级文件几十次 seek），`MediaReader.readAudio` 多返回直通样本的编码类型和裁掉的样本数，`FrameProbe.load` 算 `AudioTimeline`：**音轨起点 = AVFoundation 解码起点 + (音轨 tfdt − 视频 tfdt) + 加回的 priming 样本 / 采样率**。`--aac-priming auto|0|N`：auto = 有编辑列表信 AVFoundation（它按 elst 裁并挪，是对的），没有就按 ffmpeg 口径把裁掉的加回；0 = 只加容器偏移；N = 加回 N 样本。报告（JSON `audio.timeline` + `timelines`，markdown 首行和"两种口径"一行）同时给 **AVFoundation 原生**与 **ffmpeg 口径**（`aresample=first_pts=0`、不裁 priming = RTMP / SRT 约定"第 k 个包的时间戳 = 非裁剪解码器输出的时刻"，W2-D 按它送包）的整秒配对均值 / 最大值，注明采用了哪个。
- **A2 按整秒拍配对**（W2-E 清单 3-10、G2 报告第 5 条）。每个配对带 `tick`（= `--start-tick` + round((pts − 第一帧 pts) × fps)）和 `onSecondTick`（拍号是标称整数帧率的倍数；59.94 节目 = 60 的倍数 = 1.001 k s，与其 click 周期一致）。`AVReport` 加 `onSecond: AVStats`（count / 均值 / 标准差 / 最大 / 斜率 / 漂移）、`offSecondCount`、`programFps`、`startTick`、`note`；**`passA2` = 整秒配对最大绝对值 ≤ 1 帧**；老的六个"全部配对"字段保留（gate3-report.py 在读 `pairs[].offsetMs` / `meanMs`），markdown 标"只报不判"。多文件（A4）逐文件报告同样改。
- **`--discontinuities`**（W2-E 清单 3-9）：`FrameAnalysis.discontinuities` 搬 W2-E `DiscontinuityDetector.analyze` 的离线口径——相邻样本跳变 > 0.5 满幅，跳入 / 跳出落在任一 click 窗口 [起点 − 1 ms, 起点 + 1 ms + 1 ms] 内的不算（click 位置来自 `ClickDetector`）——输出计数、位置（前 maxEvents 条）、排除掉的跳变数、`passA1`。挂在 `frameprobe av`（音轨已经解出来了）。计的是"跳变"次数：一次台阶 = 1，单个样本毛刺 = 2（进 / 出），与 W2-E 一致。
- CLI：`av [--start-tick N] [--aac-priming auto|0|N] [--discontinuities] [--click-margin-ms 1]`。
- 素材：`Tests/Fixtures/w2d-rtmp-stream-4s.mp4`（2.9 MB）= W2-D 用例让 MediaMTX 落盘的真文件在顶层 box 边界截到前 4 个分片（不改字节，§5 有脚本）；`w1a-sample-20s.expected.json` 重录（只增字段，老值不变）。

### 1.3 StatsSummary（prompt 交付 5）

P2 已做：`EncoderSummary.delivery`（frames / dropped / reconnects / disk_free_mb / state）、`InputSummary.latency`（L1 序列 + 全程最大）、`audioDiscontinuities`、`masterMeters`（Master 峰值 / 真峰值 / LUFS 序列），markdown 的 E1 / A1 行带出来。核对了 `summarize` 对本会话 stats.jsonl 的输出，没有要补的。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherTestKit`（62 个，debug 约 3 分钟；E2 用例 60 s 实跑，`SW_E2_SECONDS=5` 可缩短）；成本数字用 `swift test -c release --package-path Packages/SwitcherTestKit --filter NoiseBackgroundTests`。

### 2.1 噪声底纹

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testW1A2_noise_decodeIsExact_andCenterMeanIsLevel`：(128, 24) / (64, 24) / (192, 24) / (128, 63) 各 40 帧，CPU 参考实现与 GPU 各一遍 | 帧号 / 时间戳 / ID / 闪光 320 帧全对；中心 1/4 区域均值离 level 最远 **0.303** | 100%；level ± 1 | ✅ |
| `testW1A2_noiseGPU_matchesContractDrawPixelExact`：1920×1080 / 1280×720 / 640×360 / 322×180 × 4 组（seed 7 / 0 / 2⁶⁴−1 / 12345，含 level 250 截断、振幅 63、闪光开关、ID 0…15） | 亮度 + 色度平面逐字节 **0 处不同**；`noiseValue` 参考定义抽查一致；非噪声底色 / BGRA 缓冲返回 false | 逐像素相同 | ✅ |
| `testW1A2_syntheticVideo_noiseGPU_3s_allFramesDecodable`：1080p60 真跑 3 s（GPU）+ 360p60 1 s（CPU 对照） | 180 / 60 帧全解出、帧号连续、late 0、饿 0 | — | ✅ |
| `testE2_noiseSource_1080p60_6Mbps_60s_averageBitrateAtLeast80pct`：噪声源（GPU）→ W1-E `Recorder`（真 VT、实时模式、6 Mbps、GOP 120、无音轨）60 s | 3600 帧 45,002,489 字节，**6.000 Mbps = 100.0% 设定**（灰底同路径 0.098 Mbps）；skipped 0；录出来的帧 100% 可解、V4 重复 / 丢弃 0、60 个闪光帧、中心均值 128 ± 2（经 H.264） | ≥ 80% 设定 | ✅ |

每帧成本（`testW1A2_noise_costPerFrame`，release，1080p NV12；"60 fps 节奏"= 每帧后 usleep 16 ms 的普通线程）：

| 路径 | 线程 CPU / 帧 | 墙钟 / 帧 | GPU 忙 / 帧 |
|---|---|---|---|
| 灰底（契约 CPU）背靠背 | 0.054 ms | 0.055 ms | — |
| 噪声 CPU 参考实现 背靠背 | **1.103 ms** | 1.105 ms | — |
| 噪声 CPU 参考实现 60 fps 节奏 | **1.692 ms**（scratchpad 探针里同条件量到 4.1 ms：睡醒后核和时钟没拉上来） | 1.694 ms | — |
| 噪声 GPU 背靠背 | 0.008 ms | 0.300 ms | 0.126 ms |
| 噪声 GPU 60 fps 节奏 | **0.042 ms** | 0.839 ms（含等 GPU 醒来） | 0.130 ms |
| 合成源真跑 1080p60 3 s（GPU，实时线程） | 0.027 ms | 0.756 ms | 0.127 ms |

8 路 1080p60 折算：CPU 参考实现 480 帧/s × 1.1–1.7 ms = **53–81% 一个核**（实跑 65.6%，下表）；GPU 版 CPU 480 × 0.04 = 2%，GPU 480 × 0.13 = 6%。GPU 版的墙钟 0.8 ms 只是生产者线程等 GPU 醒来（阻塞不占 CPU），ingress 比灰底晚 0.7 ms，远在 headless 半帧提前量（8.3 ms）之内。

### 2.2 8 路真管线（scratchpad 的 g3 噪声 show：8 路底色各自的灰度 + 振幅 24，seed = 输入号；`scenarios/g3.json` 前 90 s；release headless，`--audio-device null`，去掉前 5 s）

| | 灰底（scenarios/g3-show.json） | 噪声 · GPU（默认） | 噪声 · CPU（`SW_SYNTHETIC_NOISE=cpu`） |
|---|---|---|---|
| 进程 CPU（S3，100 = 一个核） | 12.2%（max 14.0） | **20.7%**（max 30.8） | **65.6%**（max 78.9）—— 超 S3 必须档 60% |
| GPU（IOKit） | 15.6%（max 21） | 26.1%（max 48） | 9.8%（max 20） |
| V1 avg | 1.224 ms | 1.345 ms | 1.444 ms |
| V2 / V3 max | 0 / 0.026 ms | 0 / 0.093 ms | 0 / 0.036 ms |
| 8 路 late / 饿 / 设计外 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| 录制码率（整段） | 0.097 Mbps | **6.002 Mbps** | 5.989 Mbps |
| E2 10 s 滑窗误差（gate3-report 同一算法） | 98.4%（"不适用"） | **max 1.34%、avg 0.33%** | — |
| E2 1 s 峰值 | 0.035× | **1.082×** | — |
| E3 关键帧间隔 | 120 精确 | 120 精确 | 120 精确 |

E2 阈值：必须 ≤ 10% / ≤ 1.5×，目标 ≤ 5% / ≤ 1.2× → 噪声版两档都过，L2 长跑里 E2 从此有可判对象。噪声版录制文件的其他读数：V5 5400 − 5400 = 0；V4 30 fps 路设计内 50.000%、设计外 0；V6 Cut 干净；V7 Fade 最大偏差 0.55 帧 ✅；A2 整秒配对 23 对 0.000 ms ✅（全部配对 89 对均值 12.4 ms —— 59.94 在播段）；A1 第三项 0（排除 180 次 click 跳变）。帧号 / ID 读不出的帧（59 / 206）全在 Fade（3003–3027）和 T-bar（3600–3779）的混合帧里，与灰底运行相同（G2 报告第 4 条，不是噪声引起的）。

### 2.3 frameprobe

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testA2_streamRecordingWithoutPriming_matchesFFmpeg`（`w2d-rtmp-stream-4s.mp4`：分片、无 elst、音轨 tfdt 960、AVFoundation 裁 2112） | 修正 = 20 + 44 = **64.000 ms**；整秒配对 3 对 **0.000 ms**（修正前 / AVFoundation 原生 **+64.000**，`--aac-priming 0` **+44.000**，`2112` = auto）；ffmpeg 独立解码逐对 0.000 / 0.000 / 0.000 → 两种口径差 **0.000 ms**；A1 第三项 0 | 差 ≤ 1 ms | ✅ |
| `testA2_recordedFileWithEditList_correctionIsZero`（录制路径 `w1a-sample-20s.mov`） | elst media_time 2112、修正 0、两种口径相同，20 对 |偏移| < 0.5 ms | 不受影响 | ✅ |
| `testA2_exactSecondPairing_ignores5994FlashDrift`（30 s 360p 合成：A 60 fps，B 59.94，600 拍 Cut→B、1500 拍 Cut→A，click 每整秒） | 整秒配对 **15 对均值 0.000 ms**；全部配对 30 对均值 **12.778 ms、最大 33.333 ms**；B 段每个配对晚 ≈ k ms（+ 挑帧量化 ≤ 1 帧）；passA2 ✅、note 有 | 整秒 ≈ 0、全部明显偏 | ✅ |
| `testA2_av_onSecondPairs_exclude5994DriftAndDriveVerdict`（纯函数：40 s，10–29 s 59.94 在播） | 整秒 20 对 −0.500 ms（斜率 0），全部 40 对 +13.25 ms；不给 `--start-tick` 时从第 37 拍起的文件整秒配对 0 个 / passA2 nil，给了 → 19 对 ✅；59.94 节目整秒 = 60 的倍数，20 / 20 | — | ✅ |
| `testA1_discontinuities_excludesKnownClicks`（纯函数，TestSignal 5 s） | 干净信号 0（排除 9 次：5 个 click 进 / 出，样本 0 上的 click 没有"进"）；1.5 s 起 +0.6 台阶 → **1**，位置 72000 = 1.5000 s；+0.45 → 0；click 前 0.6 ms 的毛刺 → 0（排除），前 2 ms → 2（进 / 出） | 0 / 1 | ✅ |
| `testA1_discontinuities_aacFileZero_andInjectedJumpIsFound`（`w1a-sample-20s.mov`） | 0（排除 39 次）；12.3456 s 插台阶 → 1，位置对 | 0 / 1 | ✅ |
| `testW1A2_mp4Index_readsTracksEditListsAndFirstFragmentTimes` | 分片文件：avc1 90000 tfdt 0 / mp4a 48000 tfdt 960、无 elst、1 个 moof 就够；录制 .mov：非分片、elst [0] / [2112]；非 MP4 → nil | — | ✅ |
| `FixtureSnapshotTests`（重录快照） | 老字段值不变（diff 只有新增的 tick / onSecondTick / onSecond / timeline），整秒 20 / 非整秒 0、修正 0 | — | ✅ |

前后数字（prompt 要求）：

| 文件 | 修正前 frameprobe av | 修正后 |
|---|---|---|
| W2-D RTMP 落盘（`rtmp-e2e/…/2026-09-18_13-20-34-044013.mp4`，10 s；fixture 是它的前 4 s） | 9 对均值 **+64.000 ms**、A2 ❌ | 整秒 9 对 **0.000 ms**、A2 ✅；AVFoundation 原生 64.000、ffmpeg 口径 0.000 |
| ffmpeg 推流经 MediaMTX 落盘（§5 第 4 条，视频 tfdt 0.044、音轨 0） | 0.000 ms（两个 44 ms 恰好抵消） | 0.000 ms（容器偏移 −44 + 加回 44 = 0；两种口径都 0） |
| G3 十分钟 `out.mov`（P2 的 gate 运行，`contract-implementation-280194/.build/gate3/10min/`） | 599 对均值 **20.339 ms、标准差 157.7、最大 500.000 ms、斜率 −0.1096 ms/s（A3 × 8 h = −65.5 ms）、A2 ❌**（gate 报告另算整秒行才 ✅） | 整秒 **379 对 0.000 / 0.000 / 0.000 ms、斜率 0.0000**、A2 ✅；全部配对那行照报（只报不判）；不连续 **0**（排除 1200 次 = 600 个 click × 2，与 W2-E 的 a1check 一致）；64 s |

### 2.4 全量与 lint

- `swift test --package-path Packages/SwitcherTestKit`：**62 / 62 通过**（debug，180 s，E2 用 10 s 跑的一次；60 s 版在 release 里过）。
- `make lint BRANCH=w1-testkit-2` 全绿；`make test-tools` 冒烟通过（frameprobe / switcher-headless 0.1.0）。
- 没有跑整仓 `make test`（别的包没动；P2 今天在同一 main 上跑过全绿），检查点合并时照常跑。
- `make gate3-run` 之后 G3.md 的 E2 行不再"不适用"：**BLOCKED-G4**（G3Factory / gate3-report.py 在 Tools/ 与 scripts/，检查点目录）。用 scratchpad 的噪声 show 已经证明 gate 同一算法能判出 1.34% / 1.082×（§2.2）。

## 3. 没做的和原因

- `G3Factory` 改噪声、gate3-report.py 去"不适用"分支：不是本会话目录（prompt 也写了归 G4）。改法一行：每路 `background: .noise(level: 原灰度, amplitude: 24, seed: 输入号)`；V7 的 64 / 192 配振幅 24 已验证中心均值 ± 0.3。
- `M0Factory` 按 prompt 不动。
- CPU 参考实现没有另写优化版：SplitMix64 每对像素 4 次 64 位乘，NEON 没有 64 位乘法，标量已接近吞吐极限（1.1 ms ≈ 1 ns / 对）；改算法要动契约。
- `frameprobe av` 只在 `av` 子命令里做不连续检测，没有单独的音频子命令（prompt 只要求这个）。
- 测试里 ffmpeg 口径的独立对照依赖 brew 的 ffmpeg（`/opt/homebrew/bin/ffmpeg`，与 W2-D 一样），没有就 XCTSkip 那一段（frameprobe 自己的三处断言仍跑）。

## 4. 对契约的疑问

1. **A2 的判据到底是"最大绝对值"还是"均值"**：测试标准 §1 A2 说报均值 / 标准差 / 最大绝对值，§4 写"绝对值 ≤ 1 帧"；frameprobe 的 `passA2` 一直按最大绝对值（现在是整秒配对的），gate3-report.py 按 |均值|。两者在 G3 文件上都过，但口径不同，请定一个写进 §4（建议最大绝对值，更严）。
2. **推流落盘文件的 A2 口径**建议写进测试标准 §3 A2 / E8：判 MediaMTX 落盘文件按 ffmpeg 口径（RTMP / SRT 约定：第 k 个包的时间戳 = 非裁剪解码器输出的时刻），frameprobe 默认已是；AVFoundation 原生口径只作对照。
3. **"整秒拍"的定义**建议写进 §2.3：闪光帧的节目拍号是标称整数帧率的倍数（60 fps → 整秒；59.94 → 1.001 k s，与该帧率的 click 周期一致）；不从第 0 拍起的文件要给 `--start-tick`。这依赖 §2.1 里"合成音频 click 跟节目帧率的闪光周期走"——G3 场景的 click 来自 1 号（30 fps）输入、周期 1 s，59.94 输入在播时闪光按 1.001 s，所以只报不判；如果以后音频来自 59.94 的路，反过来 60 fps 段会被判为非整秒——到时要么规定 click 一律按节目帧率，要么 frameprobe 加"按 click 周期配对"的选项。
4. **`Stats.audio.discontinuities`（流式启发式）与 frameprobe 的离线口径**：两者都叫"不连续"，A1 第三项应以离线口径为准（StatsSummary 已标"信息项"），建议测试标准 §7 的字段说明写清楚。
5. **噪声底纹的 GPU 成本会进 S3 的 GPU 项**（8 路 + 编码 6 Mbps：GPU 15.6% → 26.1%，目标档 ≤ 35% 仍过）。其中约 6 个百分点是噪声核，其余是编码器真的在编 6 Mbps 和合成器采样不可压缩纹理；这是测试工装的开销，与灰底基线不可比，G4 的基线要重打（同 G2 基线保留灰底的 M0）。

## 5. 下一个会话需要知道的坑

1. **AVFoundation 对分片 MP4 的时间轴**（探针 `scratchpad/probe1`，20 行）：没有编辑列表时每条轨的第一个样本都归零（`timeRange.start` 0、直通与解码 PTS 都从 0 起），tfdt 完全不用；AAC 轨它自己合成 2112 样本的 priming 剪裁（`segments` 报 `src 0.044 → tgt 0`，直通首样本 `TrimDurationAtStart = 2112`），解码输出总数 = 包数 × 1024 − 2112；容器里逐包的时长（MediaMTX 按 RTMP 毫秒时间戳写成 1008 / 1056）它也不看，一律按 1024 堆。有 elst 的文件（AVAssetWriter 的录制 / 样例）全对。
2. **MediaMTX 落盘**：视频 tfdt 一律 0（从第一个关键帧起录），音轨 tfdt = 关键帧后第一个音频包（W1-E 发的第一个非预滚包是 k = 3 → 960 样本 = 20 ms，不是 MediaMTX 丢包）；每个 part ≈ 1 s，两轨在同一个 moof 里；没有 mfra / elst。
3. **造不出"MediaMTX 式"的样例**：`ffmpeg -c copy -use_editlist 0 -movflags frag_keyframe+empty_moov` 会把音轨的正起始偏移丢掉（两轨都归零），`-output_ts_offset` 也一样；所以 fixture 是真文件在顶层 box 边界截断的（不改字节）。脚本（Python，标准库）：读顶层 box 列表，`cut = 第 5 个 moof 的偏移`，写 `data[:cut]`：
   ```python
   import struct; data = open(src, 'rb').read(); off = 0; moofs = []
   while off + 8 <= len(data):
       size, typ = struct.unpack('>I4s', data[off:off+8]); size = struct.unpack('>Q', data[off+8:off+16])[0] if size == 1 else (len(data) - off if size == 0 else size)
       if typ == b'moof': moofs.append(off)
       off += size
   open(dst, 'wb').write(data[:moofs[4]])
   ```
4. **ffmpeg 推流经 MediaMTX 落盘的文件是另一种形状**：ffmpeg 把 .mov 的 elst 换算成"音轨第一个包在 −44 ms"，flv 要非负就整体平移 → 视频 tfdt 0.044、音轨 0；老 frameprobe 在这种文件上刚好对（AVFoundation 丢掉视频的 44 ms、又裁掉音轨 44 ms，两下抵消），别拿它当"没问题"的证据。修正后容器偏移 −44 + 加回 44 = 0，两种口径都是 0。
5. **Metal 首次派发要预热**：新队列的第一个命令缓冲、管线定型、IOSurface 纹理首次写入合起来几毫秒，8 路同时 start 时 30 fps 那路第 0 帧赶不上第 0 拍（录制文件第 0 帧黑场，`frameprobe frames` 一眼能看到）；`SyntheticVideoInput.init` 里画一帧丢掉就好。任何组装方另建 `NoisePatternRenderer` 也要这么做。
6. **debug 构建下 CPU 参考实现 1080p 一帧 48 ms**，跟不上 60 fps；测试里要 CPU 对照就用 360p（5 ms）。release 才是 1.1 ms。GPU 版 debug / release 都是 0.13 ms GPU。
7. **GPU 时间受时钟状态影响**：背靠背 200 帧后核 0.07 ms（scratchpad 探针），测试里 70 帧 0.126 ms；报告里以 0.13 ms 计。
8. **混合帧解不出帧号 / ID 是老现象**（G2 报告第 4 条）：G3 场景 90 s 里 Fade 25 帧 + T-bar 180 帧的 ID 读不出、50% 混合的 57 帧帧号 CRC 不过，灰底与噪声完全一样。
9. **`swift test` 会生成未跟踪的 `Packages/SwitcherTestKit/Package.resolved`、`Tools/frameprobe/Package.resolved`**（P2 也撞过），别 `git add -A` 仓库根。
10. 用例开关：`SW_E2_SECONDS=5` 缩短 E2 实跑；`SW_SYNTHETIC_NOISE=cpu|gpu` 强制噪声路径；`W1A_RECORD_SNAPSHOT=1` 重录快照（这次只增字段）。
11. 实跑素材（不入库）在本会话 scratchpad：`headless-noise/`（90 s 噪声 GPU：out.mov、stats.jsonl、log.txt、frames.json、packets-v.csv、g3-noise-show.json）、`headless-gray/`、`headless-noise-cpu/`、`headless-noise2/`（预热后 30 s）、`g3-av.json`（G3 十分钟 av + 不连续）、`probe1/`（AVFoundation 探针）、`bench/`（Metal 核探针）、`mtx/`（ffmpeg 推流落盘）。G4 复核直接 `make gate3-run`（G3Factory 改噪声后）。
