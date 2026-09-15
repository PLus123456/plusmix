# W2-D 推流与 NDI 发送（SwitcherOutputs 二期）—— 报告（分支 w2-stream）

日期 2026-09-15。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3 / MediaMTX 1.21.0（brew）/ ffmpeg 9.0.1（brew，GPL 构建）/ HaishinKit 2.2.5（dc880cb）。电源适配器，室温。
worktree `.claude/worktrees/w2-stream-output-089d47`，分支 `claude/w2-stream-output-089d47`（桌面端自动起的名），从 `main`（2290b4e）开；
**`w2-stream` 指向同一个 HEAD**（`git branch -f w2-stream`），`make lint BRANCH=w2-stream` 和检查点合并都用它。
只动了 `Packages/SwitcherOutputs/{Package.swift, Sources/Streaming/, Sources/NDISend/, Tests/StreamingTests/, Tests/NDISendTests/}`、`scripts/netem.sh`、`scripts/mediamtx.yml`、本报告、`docs/contract-changes/002`、`reports/issues/W2D-*`。

## 1. 做了什么

### 1.1 第一步结论：HaishinKit 接哪一层 —— **a）它只当连接 + 封装层，我们的编码器输出直接送**

证据（源码 + 探针）：

1. 读 HaishinKit 2.2.5 源码：
   - `RTMPStream.append(_ sampleBuffer: CMSampleBuffer)`（RTMPHaishinKit/RTMP/RTMPStream.swift:726）：`formatDescription.isCompressed == true` 时直接 `RTMPVideoMessage(streamId:timestamp:sampleBuffer:)` → `doOutput` 进连接；只有未压缩帧才进它的 `OutgoingStream`/`VideoCodec`（VTCompressionSession）。
   - `RTMPStream.append(_ audioBuffer: AVAudioBuffer, when:)`（:766）：`AVAudioCompressedBuffer` 直接 `RTMPAudioMessage`；PCM 才进它的 AAC 编码器。
   - `SRTStream.append`（SRTHaishinKit/SRT/SRTStream.swift）：压缩帧直接 `TSWriter.append`（H.264/HEVC → Annex-B + 参数集，AAC → ADTS PES）→ libsrt。
   - AVC 序列头由格式描述里的 avcC 生成（`RTMPVideoMessage(streamId:timestamp:formatDescription:)`），AAC 序列头由 ASBD 生成（`AudioSpecificConfig(formatDescription:)`）。
2. 探针（scratchpad 的 50 行程序：W1-E 的 VideoEncoder H.264 1080p60 4 Mbps + AudioEncoder AAC，推 10 s 到本地 MediaMTX）：
   RTMP 落盘 fMP4 用 frameprobe 解出 **599/600 帧、帧号 0…598 连续、输入 ID 3、0 帧不可解**（第 600 帧被 MediaMTX 录制器丢掉，见 §5），ffprobe 两轨都在。
   → 不经它编码、PTS 是我们的拍点时刻，这条路是通的。
3. SRT 探针一开始连不上（`SRT_REJ_TIMEOUT`），libsrt C 客户端直连也超时。先怀疑应用防火墙（用户放行了 mediamtx 之后仍不通），最后定位是
   **MediaMTX 的 `srtAddress: :8890` 是 IPv6 双栈 UDP socket，IPv4 回环发来的握手它收不到；改成 `0.0.0.0:8890` 立刻就通**（libsrt C 客户端 `connect r=0`，MediaMTX 日志 `[SRT] conn opened … stream ID: publish:srt1`）。
   scripts/mediamtx.yml 和测试的实例启动都已改成显式 IPv4。之后 SRT 端到端：599 帧连续、A/V −1.3 ms（§2）。

不选 b）：它的连接层不是公开 API —— `RTMPConnection.doOutput`、`SRTConnection.send` 是 internal，`NetworkMonitor` 是 package，不 fork 借不到。
不选 c）：brew 的 ffmpeg 9.0.1 是 GPL 构建（依赖 x264 / x265）且没有 libsrt（`-protocols` 里没有 srt），要自己构建并随 App 分发一套 LGPL + libsrt 的动态库（约 20 MB，LGPL 的重链接义务），而 libavformat 同样没有有界发送队列，我们该写的一层一样要写。

**用它之前要知道的五件事（都在 `HaishinKitTransport.swift` / `StreamOutput.swift` 里兜住了）：**

| # | HaishinKit 的行为 | 我们怎么办 |
|---|---|---|
| 1 | 发送队列无界（`RTMPSocket` 的 `AsyncStream<Data>`）、不丢、无超时；只每秒通过 `StreamBitRateStrategy` 上报一次 `currentQueueBytesOut / totalBytesOut` | `QueueReporter`（我们的 strategy 对象，不改码率）存上报；`StreamOutput` 自带有界 `SendQueue`，用"上报的队列字节 + 上报后交出的字节"做门，门关着就不再交，队列在生产者侧满了按策略丢并计数（E9 口径）；`totalBytesOut` 连续 5 s 不涨判停滞 → 断线重连 |
| 2 | 音视频各自以"第一个样本"为时间 0（`RTMPTimestamp` 两个实例；`TSWriter` 的 `videoTimeStamp / audioTimeStamp`），A/V 相对偏移丢失（最多一个 AAC 包 21.3 ms） | RTMP：音频原点 = 最后一个不晚于关键帧时刻的包，视频 DTS 设成 PTS − 偏移 + 66 ms，它算出的 CTS 恰好 = 偏移，两个原点重合（精确到 1 ms）；TS 的 PTS 以第一帧 PTS 为原点、DTS 不能为负，只能挑最近的包（≤ 10.7 ms）；TSWriter 要两种格式都齐了才写、先到的样本当热身丢掉 → SRTTransport 把原点包先 append 一次热身、扣住视频直到音频格式记下、第一帧视频之后再把原点包真发一次（实测 −1.3 ms = 原点包离关键帧的距离） |
| 3 | 带 DTS 的样本它一律再加 66 ms CTS（`RTMPVideoMessage.ctsOffset = 0.066`，非 public） | DTS = PTS − 期望 CTS + 66 ms；端到端 A/V 测试盯住它，常量变了测试会红 |
| 4 | AAC 序列头从 ASBD 的 `mFormatFlags` 取 object type；W1-E 的格式描述 flags = 0 会被拒 | 自己造 AAC_LC(2) 的 `AVAudioFormat`（`HKAudioBridge`） |
| 5 | 关连接是 `NWConnection.forceCancel()`（RST），内核发送缓冲里的数据丢；`RTMPStream.close()` 要等服务器回 `Unpublish.Success`（MediaMTX 不回 → 等满 requestTimeout 3 s） | stop 时先等上报队列清空、再 linger（默认 1 s，测试 2–3 s）；建流带 `fcPublishName` 走 FMLE 序列（`FCUnpublish` 不等回应） |

还有一个竞态：`RTMPStream` 必须在 `connection.connect()` **之前**建 —— connect 成功后它才同步给已注册的流 `createStream`；反过来 createStream 在流的 init Task 里异步跑，`publish` 抢在前面用 streamId 0 发出去就超时（E7 三路并发时必现，见 §5）。

### 1.2 交付

全部在 `Packages/SwitcherOutputs/`：target `SwitcherStreaming`（Sources/Streaming，9 个文件）、`SwitcherNDISend`（Sources/NDISend，3 个文件 + CNDI 模块映射）、测试 target `StreamingTests`（8 个文件 33 个测试）、`NDISendTests`（5 个测试）。Package.swift 只加了这些 target、它们的产品和 HaishinKit 依赖（`exact: "2.2.5"`）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 StreamOutput | `Streaming/StreamOutput.swift` | 每个目的地一个实例；FrameConsumer（自己的 VideoEncoder，深度 3，多路共享同一块 NV12 IOSurface）+ AudioBlockConsumer（自己的 AudioEncoder，音频编码线程）；`SendQueue`（视频 1 s 帧数 + 音频 256 包）；发送 Task 按 DTS / 包首时刻交错送；退避重连 1、2、4 … ≤ `StreamSettings.reconnectMaxSeconds`（`ReconnectPolicy`），重连后 `requestKeyframe` 且队列在关键帧前一律丢；`StreamCounters`：帧数、网络丢帧（五个分项）、字节 / 码率、重连次数、断线次数、重连耗时、状态；`statsEntry` → `Stats.encoder[i]`（skipped = 本路编码器 E1，bitrate = 窗口内交出字节 × 8 / 秒） |
| 协议 | `Streaming/StreamDestination.swift`、`HaishinKitTransport.swift` | rtmp / rtmps / srt 由 url scheme 定；`StreamSettings.streamKey` 是 RTMP 发布名或 SRT streamid；RTMP onMetaData 补尺寸 / 帧率 / 码率 / 编码（它对压缩输入只写 duration） |
| 2 互不影响 | 结构保证 | 每路自己的编码器、队列、Task、连接对象；没有共享锁或共享队列。E7 逻辑版：一路传输层完全停滞时另两路 0 丢帧，`consume` p99 < 0.1 ms |
| 3 NDISend | `NDISend/NDISender.swift`、`NV12ToUYVY.swift` | `#if canImport(NDI)`：Package.swift 探测 `/Library/NDI SDK for Apple`（`NDI_SDK_DIR` 可改）才挂系统库 target `NDI`（shim.h 在没有 -I 时退到绝对路径，因为 clang 模块会在测试 / App 导入时重建）；没有 SDK → 空实现：`start()` 不抛、`unavailable = true`、帧照收直接丢。**用户会话中途装了 SDK**：真发路径编译通过，`NDIlib_send_send_video_async_v2`（UYVY，双缓冲）+ `NDIlib_send_send_audio_v3`（FLTP）5 s 真发 300 帧 0 跳帧（§2）。转换：Metal compute kernel（源码内嵌，运行时编译一次，输出到共享内存 MTLBuffer）/ CPU 逐行；两者逐字节相同。**选法 `Configuration.Conversion`：auto（默认）/ gpu / cpu**，`setConversion` 运行时可切，Show 文件用 `OutputSettings.extra["ndi.conversion"]`；auto = 第一帧和之后每 300 帧（5 s）把同一帧两种方法各转一次、便宜 30% 以上就切（负载变了会自己换），探测值 `lastCPUProbeMs / lastGPUProbeMs` 和 `autoSwitches` 在计数里。PGM 必送，PVW / 多画面从 RenderedFrame 挑，输入画面由引擎 `send(frame:)` 喂 |
| 4 netem.sh | `scripts/netem.sh` | dnctl + pfctl，锚点 `com.apple/switcher-netem`（不改 /etc/pf.conf）；block / limit / loss / delay / shape / clear / status；`serve` 代理模式（sudo 起一次，测试进程写请求文件）；语法用 `pfctl -n` 验过，规则没在 root 下实际装过（我没有 sudo） |
| 5 mediamtx.yml | `scripts/mediamtx.yml` | RTMP 1935 + SRT 8890 + API 9997，path s1 / s2 / s3 / srt1，fMP4 落盘 1 s part；三个实例用 MTX_* 环境变量改端口（头部有命令）；关掉 MoQ（它默认占 8892/8893） |
| 无 sudo 的损伤 | `Tests/StreamingTests/ThrottleProxy.swift` | 用户态 TCP 代理：黑洞（不转发不断开）/ 令牌桶限速；SWITCHER_NETEM 没设时 E7 / E8 / E9 用它，设了走 dummynet |

### 1.3 重连状态机

```
                 start()
                    │
                    ▼
   ┌──────── connecting(n) ────────┐  transport.connect() 超时 connectTimeoutSeconds（默认 5）
   │ 成功                            │ 失败
   ▼                                 ▼
publishing ◄────────────────── backoff(n, delay(n))   delay = min(1 × 2^(n−1), reconnectMaxSeconds)：1、2、4、8、16、30、30…
   │  beginSession：清队列、只收关键帧起；requestKeyframe    n = 连续失败次数（连上归零）；超过 maxAttempts → failed
   │  起步对齐：等关键帧 + 关键帧时刻之后的音频包（≤ audioStartWaitMs 250）
   │  按 DTS / 包首时刻交错送；门：inFlight ≥ maxInFlightBytes 就不交
   │
   ├─ stall：totalBytesOut 连续 stallSeconds(5) 不涨且 inFlight > 0
   ├─ disconnected：transport.isConnected() == false
   ├─ sendFailed
   │        └──► endSession（队列里的帧 → discardedOnDisconnect；估算传输层未发出 → lostInTransport）
   │             transport.close()；disconnects += 1；n = 1 → backoff(1, 1 s) → connecting(2) …
   │             重连成功：reconnects += 1，lastReconnectSeconds = 断线判定到连上的秒数
   └─ stop()：编码器 flush → 尾巴进队列 → stopRequested → 队列空 → 等上报队列清空（≤ drainSeconds）→ linger → close → stopped
```

断线期间到达的帧：`droppedDisconnected`（队列不接收）；重连后到第一个关键帧之前的帧：`droppedWaitingKeyframe`。五个分项之和 = `networkDropped`（E9 口径）。

### 1.4 每路队列深度与延迟的取舍

| 环节 | 深度（默认） | 加的延迟 | 为什么 |
|---|---|---|---|
| VideoEncoder 有界队列 | 3 帧 | 正常 0（编码器 4–10 ms 内取走）；VT 饱和时 ≤ 3 帧 | W1-E 的 E1 设计：满了丢最旧计 skipped |
| SendQueue 视频 | 1 s 的帧数（60） | 正常 0（传输层 append 立即返回）；拥塞时最多 1 s，然后丢新的直到下一个关键帧 | 丢新不丢旧：队列里的 GOP 完整可解码，送出去的每一帧都能解 → E9 的落盘缺帧恰好等于我们数的（实测误差 0.00%）。深度再大只会让拥塞时的延迟更大，不会少丢 |
| SendQueue 音频 | 256 包（5.5 s） | 0 | 音频只占码率 2–3%，正常永远满不了；满了 = 连接早死了 |
| 门 maxInFlightBytes | 2 s 码率（6 Mbps → 1.5 MB） | 拥塞时传输层 + 内核缓冲里最多约 2 s + 1 s（上报每秒一次，最坏晚 1 s 关门） | HaishinKit 只每秒报一次队列；门太小会在正常抖动时误关（每秒上报之间已交出的字节按"没发出"算） |
| 停滞判定 stallSeconds | 5 s | 断线到判定：内核 / NW 缓冲填满（6 Mbps 约 3–4 s）+ 5 s ≈ 9 s（E7 / E8 实测 9.0–9.1 s） | 小于 3 s 会把 TCP 正常的 RTO 抖动当断线；E8 要求的是放开后 ≤ 15 s，判定慢一点不影响 |
| 起步对齐 audioStartWaitMs | 250 ms | 起步最多多等 250 ms（正常 21 ms：等关键帧之后的那个 AAC 包） | 没音频的流 250 ms 后按无音频起步 |
| stop 的 drain + linger | 3 s + 1 s | 只影响 stop | HaishinKit forceCancel 会丢内核缓冲；E9 落盘计数要靠它 |

端到端（不拥塞）：拍点 → 编码 4–10 ms → 队列 0 → HaishinKit 分块 + NW 写 < 1 ms → 网络。拥塞时上限 ≈ 1 s（队列）+ 3 s（门 + 上报滞后）+ 内核缓冲。要更低延迟：把门降到 1 s、队列降到 0.5 s，代价是同样带宽下丢帧更早（更"直播"，同类软件常见的 700 ms 队列就是这个取舍）。

### 1.5 A/V 时间戳口径（测 A2 的人必读）

推流没有容器级 priming 信息（FLV / TS 都没有），AAC 的 2112 样本编码延迟只能按行业约定处理：**第 k 个包的时间戳 = 非裁剪解码器输出该包的时刻**（ffmpeg 系解码器、几乎所有 CDN 转码链的约定）。W1-E 的 `EncodedAudioPacket.hostTime` 就是这个口径（`firstFrame = 1024k − 2112`），前两个全在输入之前的包（`isPreroll`）不送。
用 ffmpeg 解落盘文件（`-af aresample=first_pts=0` 补上音轨起始偏移）找 click，闪光帧用 frameprobe frames 的 PTS：**RTMP 端到端偏移 0.0 ms**（`AVOffsetFFmpeg`，MediaMTXTests）。
而 `frameprobe av` 对同一个文件报 +64.0 ms：AVFoundation 解码时按标准 priming 裁掉 2112 样本（44.0 ms）、且没有把音轨 start_time（20 ms，MediaMTX 从第一个关键帧起录、之前的音频包丢掉）算进时间轴。录制路径（AVAssetWriter 写了 priming）不受影响。单子：`reports/issues/W2D-w1-testkit-frameprobe-av-on-stream-recordings.md`。

`make lint BRANCH=w2-stream` 绿（禁词 / 版本号 / Package.swift / 依赖方向 8 个包 / 归属 23 个文件 / RT 符号）。`swift build` 六个包通过（HaishinKit 只被 SwitcherOutputs 的两个新 target 拉进来，`SwitcherOutputs` 产品本身不变）。

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'StreamingTests|NDISendTests'`（debug）。MediaMTX 集成测试要 brew 的 mediamtx、ffmpeg 和编好的 frameprobe（`swift build -c release --package-path Tools/frameprobe`）。
输出文件在 `$TMPDIR/switcher-streaming-tests/`（`SWITCHER_TEST_OUTPUT` 可改），每个测试一个子目录，MediaMTX 日志和录制都在里面。
损伤来源：默认用户态代理（不需要 sudo）；`sudo -v && SWITCHER_NETEM=sudo swift test …` 走 dummynet（**这部分我没跑，需要你跑**，判定逻辑同一份）。

| 测试 ID | 测试函数 | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|
| E7（真网络，代理黑洞） | `MediaMTXTests.testE7_threeStreams_blockSecondFor30s_othersDropZero` | 三路 1080p60 6 Mbps 推三个 MediaMTX 实例 60 s，t=10 s 封第 2 路 30 s：第 1、3 路 networkDropped **0 / 0**，送出 3600 / 3600，落盘 3599 / 3599（MediaMTX 丢最后一帧）、缺口 0、不可解 0、编码器 skipped 0；第 2 路 t=19 s 判断线（9 s）、放开后 **2.03 s** 重连、送出 1854、网络丢帧 1873（断线期间 1523 + 关键帧前 160 + 断线丢弃 60 + 传输层估算 127 + 队列满 3） | 其他路 0（硬性） | ✅ |
| E7（逻辑版） | `StreamOutputTests.testE7_stalledTransportDoesNotAffectSiblings` | 假传输层完全停滞 4 s：邻路 0 丢帧、240/240 送出；停滞路收到 = 交出 + 未交出，传输层估算 = 交出数；三路 consume p99 < 0.1 ms | 0；p99 < 0.1 ms | ✅ |
| E8（真网络，代理黑洞） | `MediaMTXTests.testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect` | 封 10 s / 放 10 次：**10 / 10** 重连成功，放开后 0.05–0.10 s（断线判定 9.0–9.1 s + 退避 1 s 恰好落在放开时刻）；断线到连上 1.02 s；最后一次重连后再推 30 s，落盘最后一段 1829 帧、缺口 0、不可解 0 | 10 次全部 ≤ 15 s / ≤ 5 s；重连后 A2 | ✅（两档）；A2 用 ffmpeg 口径的端到端 0.0 ms 代替（frameprobe av 有偏置，见 §1.5；G3 补） |
| E8（逻辑版） | `StreamOutputTests.testE8_reconnectWithBackoffAndKeyframeFirst`、`testReconnectGivesUpAfterMaxAttempts` | 断开 → 退避 0.1 s 失败 → 0.2 s 成功：重连后第一帧是关键帧、reconnects 1、attempts 3、每个传输层对象都关掉；maxAttempts 3 → failed | — | ✅ |
| E9（真网络，代理限速） | `MediaMTXTests.testE9_bandwidth70pct_5min_dropCountWithin5pct` | 6 Mbps + 160 kbps 限到 4312 kbit/s（70%）5 分钟：收到 18000，落盘 12653（+1 = 12654 送出），缺 5346，软件报告 **5346，误差 0.00%**；分项：等关键帧 5262、队列满 84；断线 0；送出比例 70.3% | ≤ 5% / ≤ 1% | ✅（两档） |
| E9（逻辑版） | `StreamOutputTests.testE9_throttledTransport_dropAccountingExact` | 假传输层 70% 排空 5 s：收到 = 送出 + 丢帧（精确）、每个缺口后第一帧是关键帧、不误判停滞 | 精确 | ✅ |
| E2 / E3（推流路径） | `MediaMTXTests.testE2E3_rtmp_60s_bitrateAndKeyframeIntervalOnRecording` | MediaMTX 落盘 60 s：总平均 1.001×，10 s 滑窗最大误差 **0.61%**，1 s 峰值 **1.050×**；关键帧 0、120、240 …，间隔全部恰好 120 | ≤ 10% / ≤ 5%；≤ 1.5× / ≤ 1.2×；≤ ±1 帧 / 精确 | ✅（两档都过；精确） |
| RTMP 端到端 + A2 | `MediaMTXTests.testRTMP_endToEnd_10s_framesContinuousAndAVAligned` | 599 帧（0…598）、缺口 0、重复 0、不可解 0；A/V（ffmpeg 口径）**0.0 ms**（9 对）；frameprobe av 报 64.0 ms（偏置，§1.5） | A2 ≤ 16.7 ms / ≤ 5 ms | ✅（两档） |
| 起步对齐 | `StreamOutputTests.testStartAlignment_dtsOffset` / `_nearestPacketWithPreroll`、`SendQueueTests.testAlignAudio` | dtsOffset ∈ [0, 21.3 ms)、整段恒定、原点之前的包不送、包间隔连续；nearest 模式 preroll 1 个、原点离关键帧 ≤ 10.7 ms | — | ✅ |
| 队列策略 | `SendQueueTests`（4） | 未开会话一律丢；起步只收关键帧；满了丢新的、之后非关键帧一律丢到下一个关键帧、队列里的原样保留；音频满丢最旧 | — | ✅ |
| 退避 / 地址 | `ReconnectPolicyTests`（2）、`StreamDestinationTests`（5） | 1、2、4、8、16、30、30；上限 / 次数可配；rtmp app+key、rtmps 端口、MediaMTX 单段路径、srt streamid | — | ✅ |
| 停止排空 / 生命周期 | `testStopDrainsQueue`、`testLifecycle` | 停前喂的帧全部送出、每个传输层都关掉；重复 start 抛、重复 stop 安全、stop 后不计数 | — | ✅ |
| 代理工装 | `ThrottleProxyTests`（2） | 限速 500 KB/s 送 4 MB 用 8.16 s（497 KB/s）；封住后写端 EAGAIN、放开后旧连接被关 | — | ✅ |
| SRT 端到端 | `MediaMTXTests.testSRT_endToEnd_10s_framesContinuous` | MediaMTX 绑 IPv4 后：599 帧（0…598）、缺口 0、不可解 0、网络丢帧 0；A/V（ffmpeg 口径）**−1.3 ms**（= 原点包 P2 在关键帧前 1.33 ms） | A2 ≤ 16.7 ms / ≤ 5 ms；nearest 对齐上限 10.7 ms | ✅（两档） |
| NDI 真发 | `NDISendTests.testLiveSend_studioMonitor_manual` | SDK 装上后：`NDIlib_initialize` / `send_create` 成功，1080p60 实时喂 5 s：300 帧全部送出、跳帧 0、转换失败 0、音频 934 块、`unavailable = false`；**用户开 Studio Monitor 看 30 s：帧号块每帧在变、闪光块每秒亮一次**（"Studio Monitor 能看到 PGM 且帧号在走"） | 送出 = 喂入、跳帧 0；人眼确认 | ✅ |
| NDI 转换器 | `NDISendTests.testNV12ToUYVY_cpuMatchesFormula` / `_gpuMatchesCPU_bytewise` | CPU 输出符合公式；GPU 与 CPU 输出逐字节相同（公式帧 + 含噪声的测试图案 1080p）；双缓冲返回不同缓冲 | — | ✅ |
| NDI 转换成本（报告项） | `testConversionCost_1080p_report` | 1080p：debug 构建 CPU p50 **5.28 ms** / max 5.69 ms，GPU（含等待完成）p50 **0.26 ms** / max 4.32 ms（首帧含编译）；**release 构建 CPU p50 0.09 ms / max 0.29 ms，GPU p50 0.25 ms / max 4.25 ms**（机器空闲时测的；GPU 路径的成本是提交 + 同步等待，合成器排满 GPU 队列时会变长） | — | ✅（所以默认 auto，见下一行） |
| NDI 转换可选 / auto | `testConversionSelectable_runtimeSwitchAndExtraKey`、`testAutoConversion_probesBothAndPicksCheaper` | gpu / cpu 立即生效、`setConversion` 下一帧生效、`extra["ndi.conversion"]` 解析（缺省 / 不认识 = auto）；auto 探测值两边都 > 0 且与当前选择自洽：debug 下选 GPU（CPU 5.3 ms vs GPU 0.6 ms），release 下第一帧就切到 CPU（0.19 vs 1.03 ms，autoSwitches 1） | — | ✅ |
| NDI 空实现 / 干跑 | `testUnavailableWithoutSDK_emptyImplementation`、`testDryRunPipeline_boundedQueueAndCounters` | unavailable = true、帧照收不计 skipped、statsEntry 全 0；干跑 240 帧 + 20 块音频：收到 = 送出 + skipped、consume p99 < 0.2 ms | — | ✅ |
| E8（dummynet，用户跑） | 同上，`SWITCHER_NETEM=broker`（`sudo scripts/netem.sh serve`） | pf `block drop` 封 10 s × 10：**10 / 10** 重连，放开后 0.00–0.60 s；断线判定 9.0–9.9 s；最后一段 1818 帧、缺口 0、不可解 0 | 10 次全部 ≤ 15 s / ≤ 5 s | ✅（两档） |
| E9（dummynet，用户跑） | 同上 | dummynet 管道 4312 kbit/s 5 分钟：收到 18000，落盘 12556（+1），缺 5443，软件报告 **5443，误差 0.00%**；断线 0 | ≤ 5% / ≤ 1% | ✅（两档） |
| E7（dummynet，用户跑） | 同上 | pf `block drop` 封第 2 路 30 s：第 1、3 路网络丢帧 **0 / 0**、编码器跳帧 0 / 0、送出 3600 / 3600、落盘 3599 / 3599、缺口 0；第 2 路 t=18 s 判断线、放开后 **0.57 s** 重连、网络丢帧 1807。（第一次跑第 1、2 路各 8 帧 E1 跳帧是工装在喂帧线程上等代理回话造成的，改成后台调用后重跑干净） | 其他路 0（硬性） | ✅ |

计时：StreamingTests + NDISendTests 一遍约 15 分钟（E9 5.7 分钟、E8 2.9 分钟、E7 1.3 分钟、E2/E3 1.1 分钟，其余 < 1 分钟）。

## 3. 没做的和原因

- 两种损伤的差别：pf 封端口时新连接的 SYN 被丢（连接超时 5 s 才失败），代理版内核会完成握手再由 RTMP 握手超时兜住，重连节奏可能差一个退避档（dummynet 版 E7 放开后 0.57 s，代理版 2.03 s）。
- **SRT 的 E2 / E3、E7–E9**：SRT 端到端已通（§2），损伤测试只做了 RTMP；SRT 的网络丢帧口径还要加 libsrt 的 `pktSndDrop`（发送端超时丢包，`SRTConnection.performanceData`），现在只算我们自己队列的丢帧。
- **NDI 转换器默认**：用户裁定"做成可选的"（低负载下 CPU 便宜不代表高负载也是）→ 默认 auto（定期两种都试、用便宜的），gpu / cpu 可强制、运行时可切。auto 的探测只在空闲机器上验证过自洽，高负载下的实际切换行为等 G3 / W4-A 的长稳看。
- NDI 也能直接收 NV12（`NDIlib_FourCC_video_type_NV12`，SDK 内部转），prompt 要求 UYVY 我就做了 UYVY；如果想省这一步可以直接送 NV12，GPU kernel 保留。回环 L1 等 W3-A 的收端。
- **重连后的 A2 用 frameprobe av 判**：frameprobe 对无 priming 信息的 fMP4 有 44 ms + 起始偏移的偏置（§1.5，单子退给 W1-A）；本会话用 ffmpeg 口径在端到端测试里测到 0.0 ms，E8 之后的那段只验了帧号连续。G3 等 frameprobe 修好后补。
- **Stats.encoder[i] 的帧数 / 网络丢帧 / 重连次数 / 状态**：契约只有 skipped / bitrate，没直接改；数字在 `StreamOutput.counters`（`StreamCounters`）和 `NDISender.countersSnapshot`，提案 `docs/contract-changes/002`（在 001 之上加 `reconnects`、`state`）。
- **HEVC 推流、RTMPS**：HaishinKit 的 enhanced-RTMP HEVC 路径（`hvc1` fourcc）和 TLS（`rtmps` → `NWParameters.tls`）都在，`StreamDestination` 也解析，但本地 MediaMTX 没配 TLS，HEVC 没跑。
- **SRT 的精确起步对齐**：TS 的原点只能是第一帧 PTS，要精确到 1 ms 需要"在指定拍点强制关键帧"（`VideoEncoder.requestKeyframe(atTick:)`，W1-E 的目录，我不能加）：60 fps 与 48 kHz/1024 每 32 拍重合一次，等 ≤ 533 ms 就能把误差压到 0.33 ms。现在 ≤ 10.7 ms（A2 必须档过、目标档不过）。
- **HaishinKit 的 Logboard 日志**（每次连接十几行 Info 到 stdout）：关它要 `import Logboard`（HaishinKit 的依赖，我们的 target 没声明），没加。
- **Package.resolved 没提交**（不在我的目录清单里；HaishinKit 用 `exact: "2.2.5"`，Logboard 2.6.x 由它锁）。检查点合并时如果要锁 Logboard 版本，把 `Packages/SwitcherOutputs/Package.resolved` 加进去即可。
- **测试一遍 15 分钟**：E9 5 分钟、E8 10 次封放是 prompt 规定的，没缩。快速迭代用 `--filter`。

## 4. 对契约的疑问

1. **提案 002 已批**（用户 2026-09-15；`docs/contract-changes/002-stats-encoder-stream-fields.md`；W2-A、W2-E 各自也写了一个 002，编号撞了，G3 合并时按主题重排即可）：`Stats.EncoderEntry` 在 001 的 `frames / dropped / disk_free_mb` 之上加 `reconnects` 和 `state`。契约会话落地后，`StreamCounters.statsEntry` 加四行（映射写在它的注释里：frames = framesSent、dropped = networkDropped、reconnects、state = `StreamState.name`），NDI 的 state = unavailable ? "unavailable" : "publishing"。
2. **001 B（`AudioBlockConsumer` 升契约）**：StreamOutput 和 NDISender 都实现了它，赞成；签名别动。
3. `StreamSettings` 只有 url / streamKey / reconnectMaxSeconds：连接超时、队列深度、门、停滞秒数现在在 `StreamOutput.Configuration.QueuePolicy`（组装方给）。要让 Show 文件可配就得进契约或放 `OutputSettings.extra`；一期不需要。
4. `OutputSource.input(n)` 对 NDI：RenderedFrame 里没有输入画面，`NDISender.consume` 对 `.input` 不动，靠引擎用 `send(frame:)` 从该输入的帧槽喂。这是不是 G3 接线时可接受的形态？

## 5. 下一个会话需要知道的坑

- **RTMPStream 先建再 connect**（§1.1 末）；`RTMPConnection(requestTimeout:)` 别调低于 3 s：三路并发起步时 createStream / publish 的往返在负载下会超过 1 s，超时 = 连接失败 + 退避，还会把编码器队列挤爆（E1 skipped 上百）。
- **MediaMTX 的三个行为**：录制器丢每个文件的最后一帧（要下一帧才知道时长）；从第一个关键帧起录、之前的音频包丢掉（所以文件里音轨 start_time ≠ 0，判 A2 要补）；发布者 10 s 没数据就 `i/o timeout` 踢掉 —— 测试里三路要**并行** stop，串行 stop 会让后停的那路被踢、多计一次 disconnect。
- **AVFoundation 解 AAC 会裁 2112 样本 priming**，推流落盘文件没有 priming 信息 → `frameprobe av` 偏 44 ms + 起始偏移；ffmpeg 系不裁。判 A2 用 `AVOffsetFFmpeg` 或等 W1-A 修 frameprobe。
- **VT 的 H.264 样本 DTS 是 invalid**（无 B 帧）；HaishinKit 看到有效 DTS 就加 66 ms CTS（`RTMPVideoMessage.ctsOffset`），我们靠这个常量对齐。它是 internal 常量，升级 HaishinKit 后跑 `testRTMP_endToEnd_10s_framesContinuousAndAVAligned`。
- **MediaMTX 会把 CTS 吸收进 PTS 再自己重算 DTS = PTS**（落盘 pts == dts），别拿落盘文件的 DTS 反推我们送的 DTS。
- **HaishinKit 的 `NetworkMonitor` 每秒一份**：门和停滞判定的时间分辨率是 1 s；`totalBytesOut` 是写进 socket 的字节（内核缓冲不算），封端口后要先把内核 + NW 缓冲填满（6 Mbps 约 3–4 s）才开始停滞计时。
- **MediaMTX 的 SRT 要显式绑 IPv4**（`srtAddress: 0.0.0.0:8890`）：`:8890` 是 IPv6 双栈 UDP，IPv4 回环的握手收不到（TCP 双栈没这问题）。以后 W3-A 做 SRT / NDI 收端时同理先看 socket 是 IPv4 还是双栈。应用防火墙放行 mediamtx 对本机回环不是必要条件（用户放行后仍不通，绑 IPv4 才通），从别的机器推进来时才需要。
- 一个 ad-hoc 签名的 C 程序监听双栈 UDP 收不到 IPv4 回环包、而 python3 能收 —— 这个现象我先归给了防火墙，现在看更可能也是双栈 + IPv4-mapped 地址的事；没再深究，写在这里免得下次又绕路。
- **NDI SDK 的 clang 模块**会在每个导入 SwitcherNDISend 的 target（测试、App）编译时重建，`-Xcc -I` 只加在 SwitcherNDISend 自己身上不够 → `CNDI/shim.h` 用 `__has_include` 退到 SDK 默认安装位置的绝对路径。
- **AudioEncoder.finish() 在没喂过任何块时会崩**（负 host time），StreamOutput 用 `framesIn > 0` 绕开；单子 `reports/issues/W2D-w1-outputs-audioencoder-finish-empty.md`。
- **三路 1080p60 H.264 + 噪声内容**：连接稳定时 VT 编码器 skipped 0（E7 60 s）；起步阶段连接反复失败时 skipped 会上百 —— 先把连接问题排掉再看 E1。**喂帧线程被卡 0.3 s 以上（哪怕是测试工装自己在等 sudo 回话）也会把深度 3 的编码器队列挤爆**：任何在拍点回调里做的事都不能阻塞。
- `Synchronization.Mutex` / `Atomic` 放在类里必须是 `let`；`AsyncStream(bufferingPolicy: .bufferingNewest(1))` 当唤醒信号很好用（yield 线程安全、不阻塞）。
- 发送 Task 的 `waitWake` 用一个定时 Task 补唤醒，被真唤醒时取消它；不要用 `withTaskGroup` 竞速（每帧建组开销大）。
- **ThrottleProxy 的令牌桶**：睡掉的时间不能再记入令牌，否则限速是名义值的 1.7 倍（第一版就是这么错的）。
- `Package.swift` 在清单里探测 NDI SDK 路径（`FileManager`），`swift package dump-package` / check-deps 没问题；但 Xcode 的 SwiftPM 集成对清单里读环境变量可能缓存，改了 `NDI_SDK_DIR` 要 `make clean`。
