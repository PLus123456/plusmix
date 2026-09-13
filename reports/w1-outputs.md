# W1-E 编码与录制（SwitcherOutputs 一期）—— 报告（分支 w1-outputs）

日期 2026-09-14。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3 / ffmpeg 9.0.1（brew），电源适配器，室温。
worktree `.claude/worktrees/w1-outputs-6d38c6`，分支 `claude/w1-outputs-6d38c6`（桌面端自动起的名），从 `main`（bdab613）开；
**`w1-outputs` 这个分支名指向同一个 HEAD**（`git branch -f w1-outputs`），`make lint BRANCH=w1-outputs` 和检查点合并都用它。
提交：`git log main..w1-outputs`。只动了 `Packages/SwitcherOutputs/`、`Tests/Fixtures/pattern.mov`、本报告、`docs/contract-changes/001`。

## 1. 做了什么

全部在 `Packages/SwitcherOutputs/`：库 target `SwitcherOutputs`（17 个文件）+ 可执行 target `switcher-record-probe` + 测试 target（7 个文件，18 个测试）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 VideoEncoder | `Encoding/VideoEncoder.swift`（FrameConsumer：有界队列 `Support/BoundedFrameQueue` 深度 2–3 + 自己的线程）、`Encoding/VTCompressionBackend.swift`（VTCompressionSession）、`Encoding/VideoEncoderBackend.swift`（后端协议，测试用可控后端证明 E1 精确）、`Encoding/EncodedVideoSample.swift` | RealTime 开、AllowFrameReordering 关、MaxKeyFrameInterval、AverageBitRate + DataRateLimits[1.5 × 码率 / 8 字节, 1 s]；输入 NV12 IOSurface；PTS = `RenderedFrame.tickTime`（纳秒 CMTime）；满了丢最旧并 skipped += 1；输出 `EncodedVideoSample{CMSampleBuffer, tick, tickTime, isKeyframe, byteCount, encodeLatency, outputTime}` 回调；多个编码器 consume 同一个 RenderedFrame 只加引用计数（ISO 测试 4 路共享） |
| 2 AudioEncoder | `Encoding/AudioEncoder.swift` | AudioConverter AAC-LC，输入非交错 float32 块 + 块首 host time（stamp 环插值出每包 PTS）；恒定码率模式（默认 LongTermAverage 对正弦只出 26 kbps）；priming 2112 帧暴露为 `primingFrames`，前 3 包标 `isPreroll`；`Encoding/AudioBlockConsumer.swift` 协议 |
| 3 Recorder | `Recording/Recorder.swift`、`Recording/RecordingStart.swift`（起点 / 结果 / 计数）、`Recording/Remux.swift`（AVAssetExportSession passthrough → .mp4，失败留 .mov） | .mov + movieFragmentInterval 1 s；视频轨 = 编码器压缩样本直通（`sourceFormatHint` = 第一帧格式描述），PTS = 拍点时刻 − 起点，换到轨道 timescale（60 fps → 60000，一帧恰好 1000 单位；59.94 → 1001）；音频轨 = PCM 块喂 writer 自编 AAC / 写 LPCM 24-bit，第一块按样本裁到起点、末块裁到停止拍点；ProRes 422 / 422HQ / 4444 走 VT 硬件（`appleproreshw`）；ISO = 多个 Recorder 用同一个 `RecordingStart{tick, tickTime}` 启动；`stop(atTick:)` 给精确边界；计数 `RecorderCounters{videoFrames, videoFramesRejected, audioFrames, audioBlocksDropped, audioDrift, audioCorrections, diskFreeBytes, encoder}` |
| 4 磁盘错误 | `Recorder.fail(_:)` | append 失败 / writer.status == failed / 剩余空间低于下限 → cancelWriting、停本编码器、状态 `.failed(message)`；其他 Recorder 各自独立（测试：录到 12 MB 小盘写满，健康的一路 720/720 帧） |
| 5 测试喂料 | `Feeding/PatternFeeder.swift`（TestPattern → NV12 池，`realTime` 按 mach_wait_until 拍点喂 / `fastest` 带背压）、`Feeding/SignalFeeder.swift`（TestSignal 按块喂，增量到某时刻） | 标记区之外可铺有界白噪声（`texture: .noise(amplitude:seed:)`，8 张预生成平面轮换 + 随机行偏移）让码率控制真正工作；标记区不碰，图案照样解码（素材测试证明） |
| 文件命名 | `Recording/RecordFileNaming.swift` | 契约 `RecordSettings.fileNamePattern` 的 {show} {date} {time} {output} 展开成 .mov 路径（组装方给 Recorder 配 url 用），非法字符换 - |
| 命令行 | `Sources/switcher-record-probe/main.swift` | `record --out --seconds [--fps --codec --bitrate --keyint --audio --texture --remux --pacing]`；E6 的子进程；`fixture` 生成素材；逐秒打印 skipped / 队列 / 延迟 / 帧数 / 音频漂移 / 磁盘 |
| pattern.mov | `Tests/Fixtures/pattern.mov`（196 KB） | 10 s 1080p60 H.264 纯图案（帧号 = 拍、输入 ID 0、闪光每 60 拍）+ AAC click 音轨；`FixtureTests` 解前 120 帧验证帧号 / ID / 闪光 / PTS，解音轨验证 click 在每个整秒 ±1 ms |

统计：每个对象只暴露原子计数（`EncoderCounters` / `RecorderCounters`），`EncoderCounters.statsEntry(previous:windowSeconds:)` 直接给 `Stats.encoder[i]`（skipped 累计、bitrate = Δbytes × 8 / 秒）。帧数 / 丢帧 / 磁盘剩余在契约的 Stats 里没有位置 → 提案 001。

`make lint BRANCH=w1-outputs` 绿（禁词 / 版本号 / Package.swift / 依赖方向 / 归属 26 个文件）；`make build-packages build-tools` 绿；`swift test`（本包）18/18 绿，约 7 分钟（下表）。

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs`（debug）。输出文件在 `$TMPDIR/switcher-outputs-tests/`（`SWITCHER_TEST_OUTPUT` 可改）。
"实时" = 按拍点 mach_wait_until 喂；"尽快" = 不等拍点、编码队列满就等（背压），文件只看 PTS。

| 测试 ID | 测试函数 | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|
| E1 精确值 | `testE1_skippedCountIsExactWithGatedBackend` | 可控后端、每轮 push 2 帧放行 1 帧、200 轮：深度 2 → skipped 198，深度 3 → 197，= rounds − D；恒等式 pushed = submitted + skipped + 队列 在每轮后成立；被丢的永远是最旧帧（编出的 tick 严格递增） | 精确等于理论值 | ✅ |
| E1 不阻塞 | `testE1_producerNeverBlocksWhenConsumerStalls` | 消费者完全堵死，push 1000 帧：skipped 996（= 1000 − 3 − 1），push 耗时 p50 0.7 µs / p99 6 µs / max 24 µs | p99 < 0.1 ms | ✅ |
| E1 真编码器 | `testE1_realEncoderOverfeed_accountingHoldsAndPushNeverBlocks` | 1080p60 帧按 2×（120 fps）实时喂 8 s：pushed 960 = encoded 960 + skipped 0，push p99 6 µs；按 4×（240 fps）：pushed 1920 = encoded 1899 + skipped 21，push p99 9 µs、max 0.12 ms；flush 后 submitted = encoded + droppedByEncoder + failed | 计数恒等、p99 < 0.1 ms | ✅（2× 时 M5 Max 的硬件编码器跟得上，理论值就是 0；4× 才跟不上） |
| E1 标准负载 | `testE2…`、`testISO…`（1 路 60 s、4 路 30 s 实时） | skipped 全为 0 | 0 | ✅ |
| E2 | `testE2_bitrateCompliance_h264_6Mbps_1080p60_60s` | H.264 6 Mbps 1080p60 实时 60 s（±24 噪声底）：总平均 6.004 Mbps；10 s 滑窗平均误差最大 0.57%；1 s 峰值 1.067× | ≤ 10% / ≤ 5%；≤ 1.5× / ≤ 1.2× | ✅（两档都过） |
| E2（HEVC，顺带） | 从 `e3-hevc.mov` 统计 | 20 s：平均 6.025 Mbps，10 s 窗误差 1.12%，1 s 峰值 1.233×（首关键帧大） | 同上 | ✅ 必须档；峰值差目标档 0.03 |
| E3 | `testE3_keyframeInterval120_h264AndHEVC` + E2 文件 | H.264 20 s 与 60 s、HEVC 20 s：全部间隔恰好 120 | ≤ ±1 帧 / 精确 | ✅（精确） |
| E5 | `testE5_normalStop20Times_fileIntegrity` | 20 次（30–3597 拍，种子 2026，16 次 AAC 4 次 LPCM，尽快喂）：ffprobe 全部无错、nb_frames = 拍数、视频时长误差全部 0.000 帧、音视频轨时长差 ≤ 0.02 ms、两轨起点 0 | 无错；≤ 1 帧；≤ 20 ms | ✅ |
| E6 | `testE6_kill9TenTimes_playableLossUnder2s` | 子进程实时录 30 s，起点后 2–12 s 随机 kill -9 × 10：损失 0.029 / 0.804 / 0.201 / 0.585 / 0.148 / 0.526 / 0.477 / 0.801 / 0.111 / 0.097 s，最大 0.804 s、平均 0.378 s；每个截断 .mov 转封装出的 .mp4 ffprobe 无错且帧数与 .mov 相同 | ≤ 2 s / ≤ 1 s | ✅（两档都过） |
| ISO | `testISO_fourRecorders30s_sameFirstPTSAndFrameCount` | 4 路 1080p60 H.264 同一 RecordingStart 实时 30 s：首帧 PTS 全部 0.0、帧数全部 1800、视频 / 音频时长全部 30.0 s、跳帧 0、编码延迟 max 24.8–28.4 ms、喂帧晚点 0 | 首帧 PTS 相同、总帧数相同 | ✅ |
| 磁盘错误 | `testDiskWriteFailure_stopsOnlyThisRecorder` | 20 Mbps 录到 hdiutil 12 MB HFS+ 小盘：297 帧后 AVFoundation -11807"磁盘已满"（POSIX 28）→ 状态 failed；同时录的健康一路 720/720 帧、跳帧 0、ffprobe 无错；失败后的 stop 返回 failure 不挂 | 只停本录制 | ✅ |
| ProRes | `testProRes422_hardware_writesPlayableMov` | 5 s 尽快喂：300 帧、182 MB、codec prores、LPCM 24-bit 音轨、`appleproreshw.422`、编码延迟 max 3.3 ms | 可播放、硬件 | ✅ |
| 转封装 | `testRemuxToMP4_afterNormalStop` | 5 s → .mp4：300 帧、5.000 s 两轨、.mov 保留 | 能播 | ✅ |
| 音视频同源 | `testAudioClicksLandOnFlashTicks` | 解码音轨：5 个 click 峰值都在整秒 ± 48 样本内 | ≤ 1 ms | ✅ |
| AudioEncoder | `testAudioEncoder_packetCadenceAndHostTimePTS` | 3 s 增量喂：finish 前 140–142 包，finish 后 143 包 = ceil((144000 + 2112) / 1024)；包 k 首样本 = 1024k − 2112；包 host time 与首样本时刻差 ≤ 1 µs；恒定码率 160 kbps → 60 KB ± 15% | — | ✅ |
| 延迟 | `testLatency_h264VersusHEVC_1080p60` | 见第 1.2 节 | 报告项 | ✅ |
| VT 属性 | `testVTProperties_allAcceptedForH264AndHEVC_rateControlRejectedForProRes` | 见第 1.1 节 | 报告项 | ✅ |
| 生命周期 | `testLifecycle_consumeOutsideRunIsNoop_stopIsIdempotent` | start 前 / stop 后的帧不计数；两个线程同时 stop 都返回 | — | ✅ |
| 文件命名 | `testRecordSettings_outputURL_expandsPatternAndSanitizes` | 模板展开、/ 与 : 替换、空名 → untitled、已带 .mov 不重复加 | — | ✅ |
| 素材 | `testFixture_patternMov_decodesFrameNumbersAndHasClicks` | 600 帧 / 10.000 s / 1920×1080 / 196 KB；前 120 帧帧号 = 序号、ID 0、闪光只在 0 / 60、PTS = n/60；10 个 click 在整秒 ± 1 ms | — | ✅ |

BLOCKED：无（ffprobe 在）。

### 1.1 VT 属性实际生效情况（macOS 26.6.2，VTSessionSetProperty 返回值 + VTSessionCopyProperty 回读）

| 属性 | H.264（ave.avc） | HEVC（ave.hevc） | ProRes 422（appleproreshw.422） |
|---|---|---|---|
| RealTime | 0，回读 1 | 0，回读 1 | 0，回读 1 |
| AllowFrameReordering=false | 0，回读 0 | 0，回读 0 | **-12900 不支持** |
| MaxKeyFrameInterval=120 | 0，回读 120 | 0，回读 120 | -12900 |
| MaxKeyFrameIntervalDuration=0 | 0，回读 0 | 0，回读 0 | -12900 |
| AverageBitRate | 0，回读一致 | 0 | -12900 |
| DataRateLimits [bytes, 1] | 0，回读一致 | 0 | -12900 |
| ExpectedFrameRate | 0 | 0 | 0 |
| ProfileLevel | 0（H264_High_AutoLevel） | 0（HEVC_Main_AutoLevel） | -12900 |
| H264EntropyMode=CABAC | 0 | — | — |
| ColorPrimaries / TransferFunction / YCbCrMatrix 709 | 0 | 0 | 0 |
| ConstantBitRate（没用，只探） | 0 | 0 | -12900 |
| PrioritizeEncodingSpeedOverQuality / MaximizePowerEfficiency / AllowTemporalCompression / Quality（只探） | 0 | 0 | 前者 set -12900 但回读 1；后三者 -12900 |

结论：H.264 / HEVC 上没有被忽略的 key（全部回读一致）；ProRes 拒绝一切码率 / GOP / profile 类属性，`VTCompressionBackend` 对 ProRes 只设 RealTime / ExpectedFrameRate / 色彩。
HEVC 还多暴露 `RelaxAverageBitRateTarget`、`StrictKeyFrameInterval` 等（完整 key 列表在探针输出，没用到）。
硬件：三种 codec `UsingHardwareAcceleratedVideoEncoder` 都是 1；ProRes 硬件直接吃 NV12（420v），不用先转 422。

**码率控制的取舍（探针，1080p60 H.264 6 Mbps，±24 噪声底，15 s）**：只设 AverageBitRate → 10 s 窗误差 4.1% 但 1 s 峰 1.67×（首关键帧 462 KB）；
AverageBitRate + DataRateLimits[1.0×, 1 s] → 平均欠 30%（4.2 Mbps）；1.2× → 欠 16%；**1.5× → 误差 1.5%、峰 1.18**（选它，`dataRateLimitFactor` 可调）；ConstantBitRate → 2.5%、1.20。
HEVC：DRL 1.5× → 2.4% / 1.38；CBR → 5.9% / 1.69。

### 1.2 实测编码延迟（EncodeFrame 调用 → 输出回调，1080p60 实时喂，600 帧）

| 内容 | H.264 | HEVC |
|---|---|---|
| ±24 噪声底（测试 `testLatency`） | p50 3.81 ms · p99 3.96 ms · max 16.35 ms（首帧 3.76） | p50 4.25 ms · p99 4.44 ms · max 17.79 ms |
| 纯图案 / 静态灰（探针） | p50 10.2 ms · p99 10.4 ms · max 20.6 ms | p50 10.9 ms · p99 11.2 ms · max 22.5 ms |
| 饱和喂（不等拍点，探针） | p50 44 ms（VT 内部排队；EncodeFrame 调用本身阻塞 6 ms = 背压） | p50 47 ms |
| ProRes 422（尽快喂） | max 3.3 ms；探针 p50 2.6 ms | — |

静态内容比噪声内容延迟高 6 ms 这点反直觉但两边都稳定复现（推测是码率控制在极低码率下的节拍），先记着。
吞吐（1080p，EncodeFrame 背压下）：H.264 ~171 fps、HEVC ~167 fps、ProRes 422 ~775 fps、422HQ ~771、4444 ~367；E1 4× 测试里编码器实际吃下 240 fps 只丢 21 帧。
EncodeFrame 调用耗时：60 fps 时 p50 80–350 µs、p99 ~500 µs、**首帧 20–30 ms**、饱和时 6 ms —— 所以它只能在编码器自己的线程上调（T7），派发线程只入队。

### 1.3 探针结论（rule 10，代码在会话 scratchpad，结论在这里）

1. **AVAssetWriter 的 AAC 直通不可用于精确对齐**：AudioConverter 出的包直通给 writer 时，writer 按自己的 AAC 2112 样本 priming 模型处理（前插 3 个包、elst 跳 960 样本）；试了 7 种 PTS / TrimDurationAtStart 约定，
   只有"PTS0 = −4224、不带 trim"让解码后的 click 落在 0，但尾部又短 2160 样本；其余 5 种把音频推迟 44 ms 或 20 ms。→ 录制音轨改为 PCM 喂 writer 自编 AAC：click 精确在 0、时长精确（探针 6，测试 `testAudioClicksLandOnFlashTicks`、E5）。
   `AudioEncoder` 因此只给推流（W2-D）用，Recorder 不用它。
2. **AVAssetWriter 忽略音频 PTS 的间隙 / 抖动**：PCM 块 PTS 抖动 ±100 样本、甚至 +100 ms 跳变，writer 都按样本计数连续打包，不插静音、不留缝。
   所以录制音轨的时间轴 = 第一块按 host time 裁到起点 + 之后样本计数；`RecorderCounters.audioDrift` 监控块 host time 与样本时间轴的偏差，超过阈值（默认一帧，可关）插静音 / 丢样本硬校正并计数。
3. **movieFragmentInterval 的文件结构**：写入中是 `ftyp wide mdat moov (wide mdat moof)*`，finishWriting 时整理成普通 `moov`（无 moof）。kill -9 后最后一个未封口的 mdat 丢掉，损失 ≤ 1 s（E6）。
4. **AVAssetExportSession passthrough → .mp4** 对完整文件和截断的碎片文件都能转（E6 每次都验证），macOS 15 起的 `export(to:as:)` 可用。
5. **AudioConverter 码率模式**：默认 LongTermAverage，`kAudioCodecPropertyBitRateControlMode` 设 Constant 后正弦从 26 kbps 变 162 kbps；模式必须在码率之前设（Variable 模式会把码率重置成 128000）。
6. **纯白噪声不能当 E2 内容**：每像素均匀随机的画面在 QP 封顶也要 163 Mbps，编码器压不到任何码率；±24 有界噪声（`texture: .noise(amplitude: 24)`）才是"码率控制真正工作"的负载。静态图案只有 0.05 Mbps。

## 3. 没做的和原因

- **`Stats.encoder` 的帧数 / 丢帧 / 磁盘剩余**：契约冻结的 §7 行只有 skipped / bitrate，没直接改；数字在 `RecorderCounters` / `EncoderCounters`，提案 `docs/contract-changes/001`。
- **音频 A3 级别的漂移处理**（设备时钟 ±ppm 拉到 host 时钟）：那是混音器异步重采样的事（设计方案 §3.6，W2-E）。Recorder 只做监控 + 安全网硬校正（默认阈值一帧；`audioResync: .off` 可关只监控）。这次测试里的音频全是精确 host time 的合成信号，漂移恒为 0，校正从未触发。
- **E1 的"4K + 3 路极限负载"**（测试标准 §3 E1 第二句）：需要合成引擎和 stats.jsonl，G2 / W4-A 做；这里用 4× 喂帧 + 可控后端证明计数正确增长和精确值。
- **推流 / NDI / 外部显示 / 虚拟摄像头**：W2-D / W3-C。
- **HEVC 的 E2 只顺带统计**（prompt 只要求 H.264）：峰值 1.233× 过必须档、差目标档 0.03（首关键帧）；要压到 1.2 以下得给 HEVC 单独调 DRL 倍数或首帧 QP，留给 W2-D 一起看。
- **测试跑一遍 7 分钟**（E5 20 次 165 s、E6 77 s、E2 62 s、ISO 33 s、磁盘 16–26 s）：prompt 规定的次数和时长，没缩。要快速迭代可以 `--filter`。

## 4. 对契约的疑问（提案 001 里有细节）

1. **`Stats.EncoderEntry` 加 `frames` / `dropped` / `disk_free_mb`**（W2-D 大概还要 `reconnects`）？不加的话 S7 / E9 的判定没地方读，违反"三方读同一个结构"。
2. **`AudioBlockConsumer` 协议是否升到 SwitcherContracts**，与 `FrameConsumer` 对称？现在在 SwitcherOutputs 里，W2-E 看不到，Master 块的派发只能由组装方写胶水。
3. `RenderedFrame.tickTime` 作为 PTS 的单位：我把它换成纳秒 CMTime（timescale 1e9）给 VT。契约没规定 CMTime 形态，`HostTime.cmTime` 在 `Support/HostTimeCM.swift`；如果 W2-D 或 headless 需要，建议这个扩展进契约（不改公开类型，只加扩展）。
4. `Recorder.Configuration` 直接吃契约的 `VideoEncodeSettings` / `AudioEncodeSettings` / `ProgramFormat`，但 `RecordSettings{directory, fileNamePattern, container, fragmentIntervalSeconds, remuxToMP4}` 里的 `container = .mp4` 我没有实现"直接写 MP4"（一期只写 .mov，可选转封装；设计方案决策 7）。`container` 的语义建议改成"停止后的最终容器"，或者删掉这个 case。
5. `VideoEncodeSettings` 没有"码率控制模式 / DataRateLimits 倍数"字段；我放在 `VideoEncoder.Configuration.dataRateLimitFactor`（默认 1.5）。要让 Show 文件可配就得进契约；一期不需要。

## 5. 下一个会话需要知道的坑

- **VT 输出回调的参数顺序**：`VTCompressionOutputCallback = (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer)`，第一个是会话 refcon、第二个才是每帧的 refcon。写反了会在回调里解引用 nil 崩（探针 2 踩过）。
- **EncodeFrame 不是"投递"**：60 fps 下每次 80–350 µs、首帧 20–30 ms、饱和时阻塞 6 ms（背压）。只能在编码线程调；`consume` 只入队（T7）。
- **E1 的容量是 D + 1**：编码线程一有帧就取走卡在后端里，队列深度 D 之外还有 1 帧在途；理论值要按 D + 1 算（`testE1_skippedCountIsExactWithGatedBackend` 的推导）。
- **实时喂之前先把慢的初始化做完**：噪声平面预生成在 debug 下要几百毫秒；E2 第一次跑 skipped 27 就是因为测试场景先定 t0 再建喂料器，前 150 拍成批涌入把队列挤爆 —— 这是编码滞后跳帧应有的行为，改的是测试顺序。引擎侧同理：启动后要等编码器热身（首帧 20–30 ms）再算正式拍点。
- **AVAssetWriter 压缩直通需要 `sourceFormatHint`**，而格式描述只有编好第一帧才有 → writer 在第一个压缩样本到达时才建；之前到的音频块留在入口环（256 块 = 1.4 s @ 256 帧）。
- **AAC 直通的 writer 模型见 1.3 第 1 条**；W2-D 自己封 FLV / TS 时用 `EncodedAudioPacket.firstFrameIndex`（含 −2112 的 priming 偏移）和 `isPreroll`，别把 writer 的 elst 逻辑搬过去。
- **writer 不给音频留缝**（1.3 第 2 条）：任何时钟漂移必须在混音器里重采样掉；`RecorderCounters.audioDrift` 是 W2-E 验收 A3 时该盯的数。
- **HEVC 的关键帧很小**（噪声底下 1.4–3 KB，P 帧反而大）—— 这是 `ave.hevc` 的行为，不是 bug；E3 按 `NotSync` 附件判关键帧和 ffprobe 的 `K` 标志一致。
- **ffprobe 对截断的碎片 .mov**：`nb_frames` 只反映初始 moov（1 s），要 `-count_frames` 的 `nb_read_frames` 才是可播放帧数（`FFprobe.probe(countFrames: true)`）。
- **AudioConverter 的 Swift 桥接**：非交错输入的回调里 ABL 有 channelCount 个 buffer，`UnsafeMutableAudioBufferListPointer` 下标写；输入不够时返回自定义非零错误（我用 'nmor'），转换器保留内部状态下次接着来；finishing 时返回 0 包 + noErr 让它吐尾巴。
- **`Synchronization.Atomic` 放在类里必须是 `let`**，且含它的类要 `@unchecked Sendable`（裸指针成员）；`OSAllocatedUnfairLock` 是 Sendable 的无分配锁，队列用它。
- **hdiutil 小盘测试**留下的挂载点在测试失败时可能没卸：`hdiutil detach $TMPDIR/switcher-outputs-tests/tiny-volume -force`。
- **SwitcherTestKit 的 P0 骨架仍引用 `SwitcherOutputsSkeleton`**，我留了一个 deprecated 别名保证 G2 合并顺序无关；W1-A 删掉那边之后这里可以删。
- 测试的 `swift test` 会把 `switcher-record-probe` 一起编（测试 target 依赖它），E6 用 `Bundle(for:).bundleURL` 的父目录找它。
