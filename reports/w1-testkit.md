# W1-A 测试工装 —— 报告（分支 w1-testkit）

日期 2026-09-14。机器 Apple M5 Max / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3。
worktree `.claude/worktrees/w1-testkit-synthetic-stats-6414d0`，从 `main`（bdab613，P1 合入后）开。
分支实际名是 harness 给的 `claude/w1-testkit-synthetic-stats-6414d0`；为了跑 `check-ownership.sh`，另打了一个指向同一提交的 `w1-testkit` 引用（`git branch -f w1-testkit HEAD`），报告按 prompt 的分支名叫 `w1-testkit.md`。
提交：`git log main..w1-testkit`，9 个（testkit × 7、frameprobe + 样例 × 1、fixtures README × 1），33 个文件 +7692 行。

`make lint BRANCH=w1-testkit` 绿（禁词 / 版本 / Package.swift / 依赖方向 / 归属 33 个文件全在范围内）；整仓 `make build` 绿；`make test` 绿（六包 + 两工具冒烟 + App xcodebuild test）。SwitcherTestKitTests 49 个测试 75 s（debug；大头见 §5）。

## 1. 做了什么

只动了 `Packages/SwitcherTestKit/`、`Tools/frameprobe/`、`Tests/Fixtures/`。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 SyntheticVideoInput | `Sources/SwitcherTestKit/Synthetic/SyntheticVideoInput.swift`（+ `SyntheticTimeline.swift`、`NV12PixelBufferPool.swift`、`Threading/RealtimeThread.swift`、`Threading/SplitMix64.swift`） | 实现 `Input`，kind = .synthetic；自带 `RealtimeThread`（QoS userInteractive + `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until`）和自己的 `TickClockSpec`（30 / 59.94 / 60，漂移 ppm 量化到 0.001 ppm 后仍是有理数）；每帧从预热的 NV12 / IOSurface 池取缓冲、`TestPattern.draw` 写帧号（= n）/ 时间戳（= pts 毫秒）/ 输入 ID / 闪光，`ingressTime = HostClock.now()` 后 push 进注入的 `FrameSlot`。可配：抖动（±ms 均匀，SplitMix64 可复现）、每 N 帧丢 1、时钟漂移、底色灰度、分辨率。每帧 0 次 malloc（release，malloc_logger 逐次计数，见 §5）。`Generator` 是纯函数，线程和离线素材共用。settings.audio 且注入了环时自带一路音频，共用 t0 |
| 2 SyntheticAudioInput | `Synthetic/SyntheticAudioInput.swift` | `TestSignal` 按 256 帧一块写进注入的 `AudioRing`，块在其末样本时刻"到达"，写入 hostTime = 块首样本时刻；采样率漂移可配；click 周期 = `TestPattern.flashPeriod`，与闪光共用 `SyntheticTimeline.t0`。每块零分配（缓冲与平面指针表 start 时分配一次） |
| 3 StatsWriter / StatsSummary | `Stats/StatsWriter.swift`、`Stats/StatsSummary.swift`（+ `Threading/SPSCQueue.swift`） | `submit` 无锁入 SPSC 队列即返回，写线程被信号量叫醒后 `write(2)` 追加；满了丢并计数；`startSampling(every: 1)` 起采样线程 1 Hz 调 sampler；NaN / inf 换 0 计数。Summary：min / avg / **p99（最近秩：升序第 ceil(0.99N) 个）** / max，累计量取末行 − 首行，§4 阈值判定（V1 V2 V3 V4 A1 E1 S2 S3）输出 §7 表格 markdown，可带上一版本算差 |
| 4 ScenarioRunner | `Scenario/ScenarioRunner.swift` | 引擎每拍回调 `advance(to:)`，到点事件经 `(Tick, Command) -> Void` 发出；同拍按文件顺序；跳过的拍上的事件下次回调补发并计 `lateEvents`；不带时钟 |
| 5 frameprobe | 逻辑：`Probe/{ProbeTypes,MediaReader,ClickDetector,FrameAnalysis,FrameProbe}.swift`；壳：`Tools/frameprobe/Sources/frameprobe/FrameprobeCLI.swift` | 输入 .mov / .mp4（AVAssetReader → BGRA）或 `*.nv12` 目录（`--size WxH`）；子命令 frames / stats（V4 传 `--input-fps 0=30,1=60`、V5）/ switches（V6，`--start-tick`）/ fade（V7，自动或 `--fade-at S --duration D`）/ av（A2 A3；多文件 = A4，按闪光帧 genTimeMs 对齐）；音轨 1 ms 窗口能量找 click，输出样本级时间；JSON 默认、`--markdown` 人读表、`--out` 写文件；另加 `synth` 生成样例 |
| 6 20 秒样例 | `Fixture/SampleMovieWriter.swift`；`Tests/Fixtures/w1a-sample-20s.mov`（439 KB）+ `w1a-sample-20s.expected.json`（快照） | VideoToolbox H.264 直接编合成源的帧 → AVAssetWriter 直通写 .mov；两路 `Generator` 按契约挑帧规则离线合成，第 400 拍 Cut、第 700 拍 Fade 30 拍（NV12 逐字节线性混合）；AAC 128 kbps click 音轨。目标 2 Mbps，图案太简单编码器只用 77 kbps |
| — 测试替身 | `Doubles/TestKitFrameSlot.swift`、`Doubles/TestKitAudioRing.swift` | W1-B / W1-D 的真实现还没有，按契约口径写的替身（互斥锁），只服务 TestKit 自己；音频环头按 `sw_audio_ring.h` 布局真实填写、64 字节对齐 |

## 2. 每个测试：数值 / 阈值 / 通过否

49 个全过，没有 BLOCKED。prompt "测试"一节的五条：

| prompt 要求 | 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| 1080p H.264 2 Mbps 往返 1200 帧解码率 100% | `testW1A_h264RoundTrip_1080p2Mbps_1200frames_100pct` | 1200/1200 四项（帧号、时间戳、ID、闪光）全对；底色灰度误差最大 1.0 级；文件 166 KB；编码 3.2 s | 100% | ✅ |
| 720p 4 Mbps 也过 | `testW1A_h264RoundTrip_720p4Mbps_100pct` | 1200/1200；灰度误差最大 0.67 | 100% | ✅ |
| click：合成音轨 100 个全找到，误差 ≤ 0.05 ms | `testW1A_clickDetector_100clicksClean_allFoundExact` | 100/100，样本序号与 `clickSampleIndex(k)` 完全相等，误差 0 ms | ≤ 0.05 ms | ✅ |
| 加 −40 dB 白噪声仍 100% | `testW1A_clickDetector_100clicksWithMinus40dBNoise_allFound` | 100/100，误差 0 ms（高斯 RMS 0.01） | 100% | ✅ |
| 合成源 60 fps 10 s：帧号连续、时间戳单调、pushed = 600 ± 1 | `testW1A_syntheticVideo_60fps10s_continuousMonotonic_pushed600` | pushed 600、帧号 0…599 连续且 = 画面帧号、pts 严格递增且 = 拍点、ingress 非递减；唤醒延迟平均 17–48 µs、最大 33 µs（整机并行跑测试时见过一次 7.4 ms）；1080p 画帧 2.1 ms（debug） | 600 ± 1；唤醒平均 < 0.5 ms | ✅ |
| 5% 人为丢帧 → frameprobe stats 报出 = 设定值 ± 0.5% | `testV4_syntheticVideo_dropEvery20_frameprobeStatsReports5pct` | droppedByDesign 30；stats 报 29/599 = **4.84%**（最后一个缺口在末帧之后看不见）；缺口 `18→20 缺 1` | 5% ± 0.5% | ✅ |
| StatsSummary 手写 jsonl，p99 最近秩法与手算一致 | `testW1A_statsSummary_handWrittenJsonlMatchesHandCalculation`、`testW1A_statsSummary_percentileNearestRank` | 5 行 render_ms {3, 5, 4, 6.5, 2.5}：avg 4.2、p99 = 第 ceil(4.95)=5 个 = 6.5、max 6.5；100 个 1…100 的 p99 = 99；[4,1,3,2] 的 p50 = 2（不插值） | 与手算一致 | ✅ |
| frameprobe 对样例快照 | `testW1A_frameprobe_fixtureSnapshot`、`testW1A_fixture_factsMatchSpec` | 与 `w1a-sample-20s.expected.json` 一致（整数精确，灰度 ±1.5、时间 ±0.1 ms）；样例上 V4 A 0 丢 0 重、B 重复 49.8%（设计内 50%）、V5 差 0、V6 第 400 拍干净 Cut、V7 29 个混合帧最大偏差 0.33 帧、A2 20/20 配上偏移 0.000 ms、A4 极差 0 | — | ✅ |

其余测试（按 ID）：

| 测试 | 数值 | 通过 |
|---|---|---|
| `testV4_stats_30fpsSourceIn60fpsProgram_isDesignInternal` | 重复 50.0% = 设计内 50%，设计外 0，V4 ✅ | ✅ |
| `testV4_stats_dropEvery20_reports5pct` | 29/599 = 4.84%，设计外 4.84% > 0.05% → V4 ❌（应判失败） | ✅ |
| `testV4_stats_wrapAround28bitIsNotADrop` | 2²⁸ 回绕算正常，倒退 0 | ✅ |
| `testV4_stats_offAirGapIsNotADrop` | 切走再切回的那段不算丢帧；段内真丢仍报 | ✅ |
| `testV5_stats_missingOutputFramesShowInDelta` | 100 帧跨 110 帧时长 → 差 −10 | ✅ |
| `testV6_switches_cleanCutAndMixedCutDistinguished` | 干净 Cut / 后一帧混合的 Cut / 过渡三种分开；tick = startTick + index | ✅ |
| `testV7_fade_linearRampHasZeroDeviation` | 30 拍线性 29 个混合帧偏差 0，D 推断 = 30 | ✅ |
| `testV7_fade_twoFrameLagFailsThreshold_andReverseDirection` | 指定模式滞后 2 帧 → 偏差 2 ❌；自动模式看不见滞后（文档写明）；不给 D 时按 28 推断偏差 1.8 | ✅ |
| `testV7_fade_explicitModeAlsoCatchesNonLinearCurve` | ease 曲线最大偏差 7.5 帧 | ✅ |
| `testA2_av_offsetSignAndStats` | 视频晚 2 ms → 偏移 +2 ms（音频超前为正）；连续两帧闪光只算一个事件 | ✅ |
| `testA3_av_driftShowsAsSlope` | 音频慢 100 ppm → 斜率 −0.1 ms/s，99 s 漂 −9.9 ms | ✅ |
| `testA2_av_noClickWithinHalfSecondIsUnmatched` | 0.5 s 内没 click 不配 | ✅ |
| `testA4_avMulti_alignsEventsByGenTime` | 三个文件时间线原点差 8 ms → 极差 8 ms ≤ 16.7 ✅；差 20 ms ❌ | ✅ |
| `testW1A_clickDetector_5994AndDriftStillExact` | 59.94 + 100 ppm：第 1 个 click 在样本 48053，100/100 误差 0 | ✅ |
| `testW1A_clickDetector_toneAndNoiseOnly_noFalsePositive` | −40 dB 与 −12 dB 噪声下 0 误报 | ✅ |
| `testW1A_clickDetector_startOffsetAndHoldOff` | 50 ms holdOff、startSeconds 加到时间上 | ✅ |
| `testW1A_syntheticVideo_jitterIsUniformWithinBound` | ±3 ms：ingress − pts 均值 0.44、标准差 1.75（理论 1.73）、范围 −2.6 … 3.4 ms；pts 本身不抖 | ✅ |
| `testW1A_generator_driftFlashAndDropArithmetic` | +100 ppm 600 帧 = 10 s / 1.0001；59.94 第 60 帧 1.001 s 闪光；click 与闪光同刻差 < 半个样本 | ✅ |
| `testW1A_syntheticAudio_blocks256_timestampsAndClicks` | 块 = 256、读回首帧 host time = t0、click 在样本 0 / 48000、late 0、拒绝 0 | ✅ |
| `testW1A_syntheticVideoWithAudio_flashAndClickShareT0` | 视频 + 音频（50 ppm）同 t0：三个闪光帧与 click 差 < 半个样本；环里 click 在 0 / 48002 / 96005 | ✅ |
| `testW1A_syntheticVideo_stateStartStopRestart` | noSignal → live → noSignal，可重启 | ✅ |
| `testW1A_pool_returnsNilBeyondThresholdAndRecycles` | 4 个全占返回 nil；释放后复用；IOSurface 背后、2 平面 | ✅ |
| `testW1A_h264RoundTrip_5994fpsTimescale` | 59.94 的第 60 帧 pts = 1.001 s；PCM 音轨 click 在 0 / 48048 / 96096；A2 0.000 ms | ✅ |
| `testW1A_rawNV12Directory_readsBackExactly` | 30 帧原始 NV12 目录读回帧号 / ID / 灰度（71 → 64、181 → 192）/ 闪光全对；尺寸给错报错 | ✅ |
| `testW1A_statsWriter_linesRoundTripThroughFile` | 5 行写读相等，追加模式 6 行 | ✅ |
| `testW1A_statsWriter_submitNeverBlocks_dropsWhenQueueFull` | 2000 次 submit < 200 ms，写 + 丢 = 2000，文件行数 = 写入数 | ✅ |
| `testW1A_statsWriter_samplingAt1HzUsesSamplerOnWriterSide` | 20 Hz 采样 0.5 s 得 7–12 行且有序 | ✅ |
| `testW1A_statsWriter_nonFiniteValuesSanitizedToZero` | NaN / inf → 0，计数 1 | ✅ |
| `testW1A_statsSummary_verdictsFollowSection4Thresholds` | V1 ✅ 达目标、V2 0.034% ❌、V3 ✅、V4 ✅、A1 ✅、E1 ✅、S2 3.6 MB/h ✅ 不达目标、S3 ✅ 不达目标；markdown 含 ✅ ❌ 与"−1.000 ms"的版本差 | ✅ |
| `testW1A_statsSummary_loadFromFileAndEmpty` | 空文件全 nil | ✅ |
| `testW1A_scenarioRunner_*`（3 个） | 负拍事件首次回调补发、同拍按文件顺序、不重发、跳拍补发计迟到、JSON 文件加载 | ✅ |
| `testW1A_frameSlotDouble_*`、`testW1A_audioRingDouble_layoutAndWriteRead`、`testW1A_spscQueue_pushPopAcrossThreads`、`testW1A_splitMix64_deterministicAndBounded` | 替身语义按契约 §2.3；SPSC 10 万元素跨线程无丢；环头偏移 / 对齐 | ✅ |

### 解码鲁棒性极限（prompt 要求写的）

`frameprobe synth --noise N --bitrate B` 扫描，每档 5 s 300 帧无切换，四项（帧号、时间戳、ID、闪光）全对才算对。

- **硬件 H.264 编码器（默认）对码率旋钮有下限**：1080p 纯图案不管目标多低都出 ~110 kbps（目标 2 Mbps 时 75 kbps），软件编码器下限更高（130 kbps）。图案只有几十个色块变化，靠压码率压不坏。
- 加均匀噪声后码率才随目标走（±16 噪声下 2 Mbps 目标实际 1.4 Mbps；≤ 100 kbps 目标实际 82–110 kbps）。
- **640×360 及以上（块 ≥ 10 px）：所有组合 300/300**，包括 1080p ±64 噪声 100 kbps 目标（实际 183 kbps）、640×360 ±48 噪声 37 kbps。
- **只有 320×180（块 4 px、采样区 2×2）开始失败**：±16 噪声 200 / 100 kbps 各错 1 帧（先坏的是每帧都变的时间戳行），±32 噪声 100 kbps 错 2 帧、50 kbps 错 13 帧（帧号错 3、时间戳错 10）。

| 分辨率 | 噪声 | 目标 kbps | 实际 kbps | 帧号对 | ID 对 | 闪光对 | 四项全对 |
|---|---|---|---|---|---|---|---|
| 1920×1080 | ±0 | 2000 / 500 / 200 / 100 / 50 | 75 / 84 / 97 / 110 / 110 | 300 | 300 | 300 | 300 |
| 1920×1080 | ±16 | 2000 / 1000 / 500 / 250 / 100 | 1414 / 701 / 357 / 181 / 88 | 300 | 300 | 300 | 300 |
| 1920×1080 | ±32 | 1000 / 500 / 250 / 100 | 711 / 349 / 174 / 82 | 300 | 300 | 300 | 300 |
| 1920×1080 | ±48 | 1000 / 250 / 100 | 705 / 175 / 104 | 300 | 300 | 300 | 300 |
| 1920×1080 | ±64 | 1000 / 100 | 703 / 183 | 300 | 300 | 300 | 300 |
| 1920×1080 软件编码 | ±0 | 500 / 100 / 50 / 20 | 138 / 132 / 131 / 130 | 300 | 300 | 300 | 300 |
| 1920×1080 软件编码 | ±16 | 1000 / 500 / 250 / 100 | 1243 / 961 / 958 / 958 | 300 | 300 | 300 | 300 |
| 1280×720 | ±16 | 1000 / 500 / 250 / 100 | 710 / 350 / 175 / 81 | 300 | 300 | 300 | 300 |
| 1280×720 | ±48 | 1000 / 250 / 100 | 703 / 175 / 89 | 300 | 300 | 300 | 300 |
| 640×360 | ±0 | 500 / 250 / 100 / 50 | 61 / 61 / 48 / 37 | 300 | 300 | 300 | 300 |
| 640×360 | ±16 / ±32 / ±48 | 500 / 100 / 50 | 350 / 70 / 35 | 300 | 300 | 300 | 300 |
| 320×180 | ±0 | 200 / 100 / 50 | 34 / 34 / 34 | 300 | 300 | 300 | 300 |
| 320×180 | ±16 | 200 / 100 / 50 | 139 / 70 / 35 | 300 / 300 / 300 | 300 | 300 | **299 / 299 / 300** |
| 320×180 | ±32 | 200 / 100 / 50 | 140 / 70 / 35 | 300 / 298 / 297 | 300 | 300 | **300 / 298 / 287** |

结论给以后压码率的人：720p 以上随便压，图案不是瓶颈；要测 480p 以下的流才需要担心，届时先用 `synth --noise 32` 造素材验一下。

## 3. 没做的和原因

- **真的 FrameSlot / AudioRing** 没做（归 W1-B / W1-D）。TestKit 里的是互斥锁替身，只给自己的测试和素材生成用；合成源本身只认协议，注入真实现即可。
- **Stats 的"来源"**（render_ms、missed_render 等）没做：那是引擎（W1-B）每秒汇总的事，TestKit 只管把 `Stats` 写盘和读盘汇总。`StatsWriter.startSampling` 调的 sampler 由组装方给。
- **T-bar 的 V7 映射**没有专门子命令：`frames` 已给每帧灰度，比例 = (gray − 64) / 128 直接算；等 W1-B / G3 定了脚本推杆的时刻再决定要不要加 `--at` 的静态版本。
- **V6 的"恰好第 n 拍"**只能报"输出第几帧 / pts"，换算成拍要 `--start-tick`（输出第 0 帧对应哪一拍）——录制文件的时间线原点该等于哪一拍是 W1-E 的约定，见 §4。
- 8 小时 / 1 小时长跑没跑（工装会话，没有引擎）；StatsSummary 的 S2 预热逻辑（≥ 1 h 丢前 30 min）只有单元测试。
- **合成源的零分配只在 release 下量了**（malloc_logger）；debug 下 Swift 会在引用计数检查处多 retain 一次，池按 init 时量到的基准判断空闲，两种构建都能跑，但 debug 的分配次数没数。

## 4. 对契约的疑问

1. **CVPixelBufferPool 做不到零分配**（macOS 26 实测）：`CVPixelBufferPoolCreatePixelBuffer` 每取一次都新建 CVPixelBuffer 对象（5 次 malloc + 5 次 free），池只回收 IOSurface。Frame 的注释"池回收靠 CVPixelBufferPool 的引用计数"在语义上仍对，但**渲染线程 / 输入线程凡是用 CVPixelBufferPool 出帧的都不是零分配**——W1-C 的 NV12 输出 IOSurface、W2-A 的摄像头拷贝路径要注意。TestKit 的做法：自持 N 个 `CVPixelBufferCreate` 的对象，`CFGetRetainCount` 回到基准即复用（整条每帧路径 0 malloc）。要不要把这个做法写进契约注释（不改签名），请定。
2. **合成源的图案时间戳 = pts（拍点时刻）而不是画完那一刻**。测试标准 L1 说"合成源帧里有生成时间戳，编码器入口再打一次戳，差值就是 L1"，CONTRACTS.md §2.2 又说"L1 = 编码器入口 − ingressTime"。两者差一个"抖动 + 画帧时间"（1080p debug 2.1 ms）。我按 pts 写（对应真设备的采集时刻），`ingressTime` 另打；哪个算 L1 请拍板，frameprobe 的 `genTimeMs` 两种都能配合。
3. **录制文件时间线原点**：frameprobe 把输出第 i 帧算成拍 `startTick + i`。如果 W1-E 的 `AVAssetWriter.startSession(atSourceTime:)` 用拍点时刻减 t0（即文件 0 s = 第 0 拍），G2 就不用传 `--start-tick`。建议写进 W1-E 的约定。
4. **`Stats.jitter_ms` 是窗口最大值**，StatsSummary 的"V3 p99"是各秒最大值的 p99，比测试标准 §1 的逐帧 p99 严。判定按它做了，报告里已注明；要逐帧 p99 得引擎在 Stats 之外另给序列（铁律 4 不允许），或者契约给 jitter 加 p99 字段。
5. **`TestPattern.draw` 内部的两元素数组字面量**（`for (row, word) in [(0, …), (1, …)]`）release 下 0 malloc（600 次 draw 计数为 0），不需要改；只是 debug 下会分配，写在这里备查。
6. `SyntheticSourceSettings.patternID == nil` 时我取 `(number − 1) mod 16`（契约注释写的），`patternID` 给了就用给的——两路合成源 number 不同但 patternID 相同时 frameprobe 分不开，属使用者责任。
7. AVAssetReader 解 H.264 → BGRA 后灰底读到 63–65 / 191（写入 limited Y 71 / 181，硬件编码器把 71 编成了 72），偏差 ≤ 1 级，V7 用标称 64 / 192 算比例最大偏差 0.33 帧，不影响判定；**V9 色彩测试别用 BGRA 输出读电平**，用 NV12 输出直接读 Y。

## 5. 下一个会话需要知道的坑

- **`mach_wait_until` 在普通线程上平均晚醒 2.8 ms、最大 4.2 ms**（macOS 26 / M5 Max，QoS userInteractive 也一样，定时器合并）；给线程设 `THREAD_TIME_CONSTRAINT_POLICY` 后平均 13 µs、最大 58 µs。`RealtimeThread.applyTimeConstraintPolicy` 就是这段代码，**W1-B 的节目时钟线程必须这么做**，否则 V3 抖动直接超 4 ms 阈值。
- **CVPixelBufferPool 每取一次 5 次 malloc**（见 §4 第 1 条），预热无用；`NV12PixelBufferPool` 是替代做法。IOSurface 内存懒映射：不预先 memset 一遍，第一帧画进去缺页 12 ms。
- **非实时 AVAssetWriter 两条轨要交错喂**：只喂视频、音频最后一次性写，视频输入很快 `isReadyForMoreMediaData = false`，VT 回调里死等 → 每帧超时 2 s → 会话报 `kVTSessionMalfunctionErr`（−17691）。`SampleMovieWriter.Sink` 每帧把音频写到 pts + 1 s。
- **视频轨 `mediaTimeScale` 要设成帧率分子的倍数**（59.94 → 60000），不然 .mov 默认 600 时标把 1001/60000 四舍五入，第 60 帧读回 1.0017 s 而不是 1.001。W1-E 录制同理。
- **AVAssetReader 解 AAC 已把编码延迟（priming）扣掉**：样例里 click 与闪光偏移 0.000 ms，不用自己修 2112 样本。
- **硬件 H.264 编码器码率有下限**（1080p 纯图案 ~110 kbps），别指望用 `AverageBitRate` 把图案压坏；要压就 `synth --noise`。
- **`Mutex<Void>.withLock` 的闭包要写 `{ _ in }`**；`Synchronization.Atomic` 只能是 `let`。
- **debug 与 release 的 `CFGetRetainCount` 差 1**（debug 下 `_withUnsafeGuaranteedRef` 仍多 retain），任何按引用计数判空闲的代码都要在运行时量基准，别写死 1。
- **`App/Tests/SkeletonTests.swift` 读 `SwitcherTestKitSkeleton.contractsVersion`**，所以 TestKit 留了这一个成员；W1-B 等删各自的 `*Skeleton` 时先查 App/Tests 有没有引用（目前只引用了 TestKit 的）。W2-B 换 UI 冒烟测试后把它删掉。
- **frameprobe `stats` 按"在播段"算缺口**：节目输出里某路切走再切回来，中间不算它丢帧；ISO 单路文件不受影响。V4 的设计内 / 设计外要传 `--input-fps`，不传只报实测。
- **`fade` 自动模式量不出整体滞后**（晚 2 拍开始看起来就是晚 2 拍开始），V6 / V7 的"恰好第 n 拍"要用 `--fade-at S --duration D` 指定模式；容差默认 2 级（D = 30 相邻帧差 4.3 级，6 会吃掉头尾帧）。
- **测试时长**：SwitcherTestKitTests 75 s（debug）——两条 10 s 的真跑、click 三条各 3 s（4.8 M 样本 debug 渲染）、两次 1200 帧编码往返各 8–15 s、样例解码 12 s（两个快照测试共用一次）。想快就把秒数改小，别改阈值。
- `frameprobe` 的 release 二进制：`swift build -c release --package-path Tools/frameprobe`，1200 帧 1080p 解码 + 分析约 2 s；debug 慢 6 倍。
- **像素池大小**：W1-B 报告说引擎侧每路最多同时引用 8 帧，`SyntheticVideoInput` 的 `poolBuffers` 默认改成 12（8 + 在画 1 + 下游 3）；不够时那帧跳过并计 `counters.poolStarved`，G2 集成时看这个计数是不是 0。
- 本会话没有 W1-B 的帧槽，`Tests/Fixtures/w1a-sample-20s.mov` 的 Cut / Fade 是离线合成的"参考答案"，G2 拿引擎真录一份后用同一套子命令比。
