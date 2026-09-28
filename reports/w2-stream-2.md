# W2-D2 推流开始丢前约 1 s 的音频包 —— 报告（分支 w2-stream-2）

日期 2026-09-28。机器 Apple M5 Max 128 GB / macOS 27.0 (26A428) / Xcode 27.0 (27A266a) / Swift 6.4 / MediaMTX 1.21.0（brew）/ ffmpeg 9.0.1（brew）/ HaishinKit 2.2.5。电源适配器，室温。
worktree `.claude/worktrees/w2-stream-2`，分支 `w2-stream-2`，从 `main`（4357eed = 8760ce5 之上一条报告提交）开。
只动了 `Packages/SwitcherOutputs/Sources/Streaming/{SendQueue,StreamCounters,StreamOutput}.swift`、`Packages/SwitcherOutputs/Tests/StreamingTests/{MediaMTXSupport,MediaMTXTests,SendQueueTests,StreamOutputTests,TestSupport}.swift` 和本报告。不动契约、NDI、录制、headless。

## 1. 做了什么

### 1.1 先把"丢 47 包"查清（结论和问题单里写的不一样）

问题单（`reports/issues/W4A-w2-stream-ndi-send-cpu-share.md` 第 3 条）说 47 包"都在 RTMP 握手完成前"、"头一秒有画无声"。看 8 小时和 1 小时长稳的原始日志（`w4-soak-baseline-56b8ec/.build/soak/{8h,1h}/headless.log`）：

- 两路 RTMP 的 HaishinKit `handshakeDone` 都在推流 start 之后 **2–5 ms**（本机 MediaMTX），远早于音频引擎起动；
- 两次长稳都打印了 `t0 距现在 923 ms` / `922 ms`：headless 的顺序是 **推流 start → …设置 → 音频引擎 start（Master 块立刻开始喂给推流）→ 引擎 start(t0)，视频到 t0 才出第一帧**；
- 47 × 21.33 ms = 1.003 s ≈ 923 ms + 音频引擎起动到打印之间的几十毫秒（1 小时那次 46 包 = 0.98 s）。

所以这 47 包是 **t0 之前那约 1 s 的音频**：那时还没有任何一帧视频，推流必须从第一个关键帧起、音频原点包对齐到它（W2-D 的起步对齐），
这些包没有画面可配、本来就不能送——起步对齐把它们裁掉是对的，错在把它们计进了 `audioDropped`，长稳摘要就写成了"丢 47"。
落盘文件里并没有"有画无声"的一秒：画面和声音都从 t0 那个关键帧开始（修前的 SRT 用例落盘两轨起点 0.0 s / 0.0 s、frameprobe 第一帧帧号 0）。

顺手发现的**真问题**在 App 的顺序上（引擎在跑、音视频一直在流、用户此刻按下"开始"）：握手期间到的帧 / 包今天直接丢——视频计 `droppedDisconnected`（进 E9 的网络丢帧；远端 CDN 握手 0.5–1.5 s 就是 30–90 帧）、音频计 `audioDropped`，落盘从连上那一拍才开始。用代理把本机握手拖到 0.5 s 复现：网络丢帧 29、音频丢包 22、落盘从帧号 29 起（§2 修前数字）。

### 1.2 修法：start 起就缓冲，两轨从同一原点起送，原点之前的不算丢

`SendQueue` 分两种模式（原来只有"没开会话一律丢 / 开了按直播策略"）：

| 模式 | 什么时候 | 视频满了 | 音频满了 |
|---|---|---|---|
| **缓冲** `beginBuffering()` | start() 起还没连上；每次退出发布循环（断线 / 停滞 / 发送失败）之后到重连成功 | 不丢新的：**清空、从下一个关键帧重来**（新来的这帧本身是关键帧就直接收下；清空时当场 `requestKeyframe`，不等两秒后排程的那个）。连上那一刻缓冲里永远是"从关键帧起、最近的这一段"（≤ 容量 1 s） | 丢最旧的一包 |
| **直播** `goLive()` | 连上了（缓冲内容保留，就是要送的第一段） | 原策略：丢新的、之后等关键帧（E9 口径不变） | 丢最旧的一包 |

`StreamOutput`：`start()` 即 `beginBuffering()`（编码器起来之前）；连上 `goLive()`（不再 `beginSession()` + `requestKeyframe()`）；退出发布循环 `beginBuffering()` 并要一个关键帧，重连复用同一套；起步对齐逻辑不变（队头关键帧 + 关键帧时刻之后的音频包到齐 → 选原点包 → dtsOffset / nearest）。

**计数口径（写清楚，报告和长稳读数按这个）**：推流的原点 = 第一次连上后送出的第一个关键帧，两轨从它同一时刻起送。
- 原点之前编码器就交出、没成为推流内容的帧 / 包记新字段 **`videoBeforeStart` / `audioBeforeStart`**：握手比缓冲长时缓冲重来清掉的、起步对齐裁掉的原点之前的音频（headless 那 47 包）、连上前 stop 时剩下的。不进 `networkDropped` / `audioDropped`。
- 第一次连上之后，同样的事就是损失：断线 / 退避 / 重连期间缓冲重来清掉的 → `droppedDisconnected`（音频 → `audioDropped`）；断线那一刻队列里没送出的 → `discardedOnDisconnect`；重连起步对齐裁掉的音频 → `audioDropped`。
- 恒等式：`framesReceived == framesSent + (networkDropped − lostInTransport) + videoBeforeStart + queueDepth`；`audioPacketsReceived == audioPacketsSent + audioDropped + audioBeforeStart + audioQueueDepth`。
- `Stats.EncoderEntry`（契约）不动：`dropped` 仍 = `networkDropped`。

行为上的变化：
- App 的顺序下，本机 / 近端（握手 < 1 s）：落盘从按下"开始"那一拍起，一帧一包不丢，连上后把缓冲一口气送出（≤ 1 s 内容的突发）。
- 握手 > 1 s：送的是最近的一段（从关键帧起、连续、不夹旧内容、不留空洞），更早的记"开始之前"。
- 重连：断线判定 → 缓冲从关键帧重来 → 退避 → 连上后把缓冲里最近的 ≤ 1 s 接上。短于缓冲的断线（逻辑版 0.3 s vs 0.5 s）内容不丢、重连后紧接断线前（缺口 1–3 拍）。E8 真网络的判定要 9 s，缓冲每秒重来一次，重连后从最近的关键帧接上。
- 缓冲期间每秒多一个关键帧（清空时要的），只在没连上的时候发生；连上后 GOP 回到排程（E3 落盘关键帧 0、120、240 … 间隔恰好 120 不变）。

热路径：改动全在编码器回调线程 / 发送 Task；`consume` / `consumeAudio` 路径没动（E7 逻辑版 consume p99 < 0.1 ms 照过）。缓冲清空是一秒最多一次的环清零，在编码器回调线程上。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'StreamingTests.*'`（debug；MediaMTX 集成用例要 brew 的 mediamtx / ffmpeg 和 release 版 frameprobe：`swift build -c release --package-path Tools/frameprobe`）。输出在 `$TMPDIR/switcher-streaming-tests/<用例>/`。损伤来源：用户态代理（没设 SWITCHER_NETEM）。

### 2.1 本会话的新用例（修前 → 修后）

| 测试 ID | 用例 | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|---|
| W2-D2 RTMP（App 顺序） | `MediaMTXTests.testW2D2_streamStart_noAudioDroppedBeforeFirstVideo`：start() 后立刻按拍喂、不等 publishing；代理上行 3 KB/s 让握手在 tick 29–33（≈ 0.5 s）完成 | 网络丢帧 **29**（断线期间 28 + 等关键帧 1）、音频丢包 **22**、送出 571 / 600、落盘 570 帧从帧号 29 起、第一个能配对的闪光在 0.516 s | 网络丢帧 **0**、音频丢包 **0**、开始之前 0 / 0、送出 600 / 600、落盘 599 帧从**帧号 0** 起、缺口 0、两轨起点差 20 ms、第一秒音频 RMS 0.100、A/V 0.0 ms（9 对） | audioDropped = 0、networkDropped = 0、落盘从第 0 拍起、两轨起点差 ≤ 1 包（21.3 ms）、第一秒有音频、A/V ≤ 2 ms | ✅ |
| W2-D2 SRT（headless 顺序） | `MediaMTXTests.testW2D2_srtStart_noAudioDroppedBeforeFirstVideo`：音频从 t0 − 1.0027 s 起喂（188 块），视频从 t0 | 音频丢包 **47**（= 长稳的数字）、落盘从帧号 0 起、两轨起点 0.0 / 0.0 s（修前落盘就没有"有画无声"） | 音频丢包 **0**、`audioBeforeStart` **47**、网络丢帧 0、落盘 599 帧从帧号 0 起、两轨起点 0.0 / 0.0 s、第一秒音频 RMS 0.100、A/V −1.3 ms（9 对） | audioDropped = 0、audioBeforeStart ∈ [44, 50]、A/V ≤ 12.7 ms（最近包） | ✅ |
| W2-D2 逻辑版（App 顺序） | `StreamOutputTests.testW2D2_bufferDuringConnect_sendsFromFirstFrameNoDrops`：假传输层 connect 0.35 s，缓冲 0.5 s | 网络丢帧 21、音频丢包 16、从 tick 21 起送 | 90 / 90 送出、丢 0 / 0、从 **tick 0**（关键帧）起、序列连续、音频原点 = 关键帧时刻 − dtsOffset | 同左 | ✅ |
| W2-D2 逻辑版（headless 顺序） | `StreamOutputTests.testW2D2_audioLeadingVideoByOneSecond_notCountedDropped` | 音频丢包 47 | 音频丢包 0、`audioBeforeStart` 47、恒等式成立 | 同左 | ✅ |
| W2-D2 慢握手 | `StreamOutputTests.testW2D2_slowConnect_bufferRestartsAtKeyframe_continuousAfterConnect`：connect 1.2 s > 缓冲 0.5 s | （新） | 收到 150、送出 88（从 tick 62 关键帧起、连续）、开始之前 62 帧 / 48 包、网络丢帧 0、音频丢包 0、缓冲里最旧的帧 ≤ 0.5 s | 同左 | ✅ |
| 缓冲策略 | `SendQueueTests.testW2D2_bufferingRestartsAtKeyframeWhenFull` | （新） | 缓冲满清空从关键帧重来 / 新来是关键帧就收下 / 转直播内容保留按直播策略丢新的 / 回缓冲返回清掉数 | — | ✅ |

### 2.2 改了口径的既有用例

| 用例 | 改了什么 | 修后 | 通过 |
|---|---|---|---|
| E8 逻辑版 `testE8_reconnectWithBackoffAndKeyframeFirst` | 原断言"断线到重连之间的帧记为网络丢帧"（> 0）改为：断线 0.3 s 短于缓冲 0.5 s，重连后紧接断线前（缺口 1–3 拍），网络丢帧 = 缺口 − 1，开始之前 0 | 重连后第一帧关键帧、reconnects 1、attempts 3、退避 0.25–1 s 不变 | ✅ |
| 起步对齐 `testStartAlignment_dtsOffset` | "原点之前的包被丢（audioDropped > 0）"改为 audioDropped == 0 且 audioBeforeStart > 0 | dtsOffset ∈ [0, 21.3 ms)、恒定、包间隔连续不变 | ✅ |
| `SendQueueTests` 四条 | `beginSession()` → `beginBuffering()` + `goLive()`（直播语义不变）；音频满用例加缓冲模式的返回值 | — | ✅ |

### 2.3 MediaMTX 六条 + 其余（修后复跑）

| 测试 ID | 用例 | 修后数值 | 阈值 | 通过 |
|---|---|---|---|---|
| RTMP 端到端 + A2 | `testRTMP_endToEnd_10s_framesContinuousAndAVAligned` | 600 / 600、落盘 599 帧缺口 0 重复 0 不可解 0、A/V 0.0 ms（9 对）、开始之前 0 / 0 | A2 ≤ 2 ms（目标档 5） | ✅ |
| SRT 端到端 | `testSRT_endToEnd_10s_framesContinuous` | 600 / 600、落盘 599 帧缺口 0、A/V −1.3 ms | ≤ 12.7 ms | ✅ |
| E2 / E3 | `testE2E3_rtmp_60s_bitrateAndKeyframeIntervalOnRecording` | 总平均 1.000×、10 s 窗最大误差 0.15%、1 s 峰值 1.017×；关键帧 0、120、240 … 间隔恰好 120 | ≤ 10% / 5%；≤ 1.5× / 1.2×；±1 帧 / 精确 | ✅（两档） |
| E7 | `testE7_threeStreams_blockSecondFor30s_othersDropZero` | 三路 1080p60 6 Mbps 60 s，t=10 s 封第 2 路 30 s：第 1、3 路网络丢帧 **0 / 0**、音频丢包 0 / 0、送出 3600 / 3600、落盘 3599 / 3599 缺口 0、编码器 skipped 0；第 2 路 t=19 s 判断线（9 s）、放开后 **2.02 s** 重连（断线到连上 22.4 s）、送出 1892、网络丢帧 1831（断线期间缓冲重来 1485 + 等关键帧 160 + 断线丢弃 60 + 传输层估算 123 + 队列满 3）、音频丢包 1337、开始之前 0 / 0 | 其他路 0（硬性）；放开后 ≤ 15 s | ✅ |
| E8 | `testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect` | 封 10 s / 放 10 次：**10 / 10** 重连成功，放开后 0.06–0.23 s（第 5 次 1.12 s：判定用了 10.1 s、落进下一档退避），断线判定 9.0–10.1 s，断线到连上 1.03 s；最后一段落盘 1830 帧、缺口 0、不可解 0（重连后从缓冲里的关键帧接上）；10 次断线累计：网络丢帧 5355（缓冲重来 2167 + 等关键帧 1347 + 传输层估算 1221 + 断线丢弃 600 + 队列满 20）、**音频丢包 3259（≈ 326 / 次：断线那 ~10 s 里没塞进 ≤ 1 s 桥接缓冲的部分，与视频同一段）、开始之前 0 / 0**、送出 5586 / 9720、音频恒等式 4334 + 3259 + 0 = 7593 成立 | 10 / 10 ≤ 15 s（目标 5）；重连后帧号连续 | ✅（两档） |
| E9 | `testE9_bandwidth70pct_5min_dropCountWithin5pct` | 6 Mbps + 160 kbps 限到 4312 kbit/s（70%）5 分钟：收到 18000，落盘 12610（+1 = 12611 送出），缺 5389，软件报告 **5389，误差 0.00%**（等关键帧 5305、队列满 84；断线 0）；音频 14062 / 14062 丢 0、开始之前 0 / 0——直播模式的策略没动 | ≤ 5% / ≤ 1% | ✅（两档） |

整包 `swift test --package-path Packages/SwitcherOutputs`（修后，2026-09-28 16:33–17:00）：六个 xctest 包 **105 用例 = 101 过 / 0 失败 / 4 跳过**——VirtualCameraTests 12 / SwitcherOutputsTests 25 / StreamingTests 34（含本会话新增 6 条）/ NDISendTests 9（跳 2：`testLiveSend_studioMonitor_manual` 要设 SWITCHER_NDI_LIVE_SECONDS、`testUnavailableWithoutSDK` 本机有 SDK）/ ISOTests 10 / ExternalTests 15（跳 2：BLOCKED-硬件，本机只有内置屏）。四个跳过都是原有的，Streaming 之外的 target 没被牵连。

`make lint BRANCH=w2-stream-2`：**全绿**（禁词 / 版本号 0.1.0 / Package.swift 约束 / 依赖方向 8 个包 / 归属 8 个改动文件都在范围内 / CSwitcherAudioRT 符号审计）。

## 3. 没做的和原因

- **headless 的摘要行**（`推流 n：… 音频包 X / 丢 Y`）只打印 `audioDropped`，修后长稳会显示"丢 0"，那 47 包在 `audioBeforeStart` 里但没打印——headless 不在本会话目录，建议 W4-A / headless 归属会话把 `videoBeforeStart / audioBeforeStart` 加进摘要（一行）。
- **headless 音频引擎比视频早起 ~1 s** 本身没动（`--lead-ms` 与音频引擎 start 的先后是 headless 的事）：现在它只是"开始之前"的 47 包，不再是丢包。要让 headless 也 0 开始之前，得把 `audioEngine.start` 挪到 t0 附近或让推流在 t0 才开始收音频，不值得。
- **dummynet（sudo）版 E7 / E8 / E9** 没跑（没有 sudo）；判定逻辑同一份，代理版全过。
- **App 的推流面板**是否显示 `videoBeforeStart / audioBeforeStart`：契约没这两个字段（`Stats.EncoderEntry` 只有 dropped），本会话不改契约；只在 `StreamCounters` 里（UI 可直接读 `StreamOutput.counters`）。
- 原点之前的两个 AAC 包不送 → 解码器前 44 ms 是热身，落盘文件第 0 拍的 click 测不到（配对从第 60 拍起）；这是 W2-D 起步对齐的既有取舍（RTMP 的 preroll = 0），A2 的整秒配对不受影响，没动。
- 缓冲期间每秒多要一个关键帧：只在没连上的时候，对 E2 / E3 无影响；但如果有人拿"编码器 keyframes 计数"当 E3 看，断线时段会多算，报告里写明。

## 4. 对契约的疑问

1. `Stats.EncoderEntry` 要不要加 `before_start`（视频 / 音频各一）？现在 UI / API / stats.jsonl 只看得到 `dropped = networkDropped`，"开始之前"只在 `StreamCounters`。我倾向不加：它不是质量指标，只是为了让 `received == sent + dropped + before_start` 对得上；需要的话走 docs/contract-changes/。
2. `AudioBlockConsumer`（提案 001 B）签名没动。

## 5. 下一个会话需要知道的坑

- **frameprobe `frames` 子命令也要 `--no-self-check`**：实时喂送的文件第一帧没有"节奏"可投票，自证会把它判成解不出（frameNumber = nil），`stats` 早就关了自证、`frames` 没有——本会话在工装里补上（同一问题单 `G4b-w1-testkit-selfcheck-rhythm-vs-realtime-feeder`）。
- **Atomic<Bool> 不能被闭包按值捕获**（`~Copyable`："borrowed and cannot be consumed"）：要在编码器回调闭包里读的标志放进已捕获的类对象（`AtomicStreamCounters.published`）。
- **用代理限速拖慢 RTMP 握手**：`ThrottleProxy` 的令牌桶在第一次 read 时就算好整个等待（C0+C1 1537 B @ 3 KB/s ≈ 0.5 s），之后解除限速不缩短这次等待；解除要赶在握手其余往返之前（tick 24），否则连上后的突发会被限住。要拖更久别用更低的速率（C2 又要等一次），改 `Task.sleep` 型的假传输层。
- **AAC 原点之前的两个包不送 → 落盘第 0 拍的 click 测不到**：判"第一秒有音频"用 [0.1, 1.0) s 的 RMS（正弦 −20 dBFS ≈ 0.071，这里 0.100 因为 click 也在窗里），别用第 0 拍配对。
- **FakeTransport 的 `connectDelaySeconds` 要小于 `makeForTest` 的 `connectTimeout`（默认 1 s）**，否则连接超时 → 退避重试，永远连不上。
- E8 逻辑版的缺口 1–3 拍：断线那一刻队列里已排在非关键帧后面的 0–2 帧是真损失（要关键帧之前编出来的），断言按缺口算，不是硬性 0。
- SRT 本机连上只要 10–80 ms；MediaMTX 仍要显式绑 IPv4（沿用）。
