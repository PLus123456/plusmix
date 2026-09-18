# W1-E2 录制器收尾 / 编码器崩溃（编码录制续做）—— 报告（分支 w1-outputs-2）

日期 2026-09-18 晚–19 凌晨。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 27.0 (27A266a, Swift 6.4) / ffmpeg 9.0.1（brew），电源适配器，桌面端 Claude 全程占 CPU（load 2.3–3.5）。
worktree `.claude/worktrees/recorder-encoder-crash-5bcbfd`，分支 **`w1-outputs-2`**（桌面端起的 `claude/recorder-encoder-crash-5bcbfd` 已改名），从 `main`（2fdf52d，P2 契约落地之后）开。
提交：`git log main..w1-outputs-2`。只动了 `Packages/SwitcherOutputs/Sources/SwitcherOutputs/`、`Packages/SwitcherOutputs/Tests/SwitcherOutputsTests/`、本报告、`reports/issues/W1E2-w2-stream-throttle-proxy-close-flaky.md`。
契约（SwitcherContracts）没碰；`Packages/SwitcherOutputs/Package.resolved` 是 `swift test` 生成的未跟踪文件，没提交（P2 报告提过的坑）。

## 1. 做了什么

| prompt 交付 | 落点 | 做法 |
|---|---|---|
| 1 `drainAudio` 先查边界再查漂移 | `Recording/Recorder.swift` `drainAudio` | 每块先看 `块首 PTS ≥ 边界拍点` → 直接跳过并计入 `audioFramesBeyondStop`，不参与锚定 / 漂移 / 补静音；含边界的块裁到边界（向上取整到样本），裁掉的尾巴也计入越界；补静音的长度另外钳在边界之内。截断之后 `audioFramesAppended` 不再变，所以"期望时刻"也不再变 |
| 2 封口后 `appendPCM` 不再等 200 ms、丢样本计数 | `consumeAudio` / `drainAudio` / `appendPCM` / `finishIfReady` | 音轨封口（writer 音频输入 `markAsFinished`）时置 `audioSealed`（writer 队列）+ `audioSealedAtomic`（入口）。之后到的块：**入口**就分流——PTS ≥ 边界 → `audioFramesBeyondStop`；边界之前的（迟到的）→ `audioFramesDroppedAfterStop`；都不进环、不占 writer 队列、不碰 `appendPCM`。封口那一刻还在环里的由 `drainAudio` 的 sealed 分支只计数。`appendPCM` 里原来那个 200 ms 的等待保留为录制中的安全网，等不到就丢并计 `audioFramesDroppedTimeout`（G2 3-8：以前静默丢） |
| 3 预告停止拍 | `setStopTick(_:) -> Tick?`、`stop(atTick:)` 语义、`Configuration.stopGrace`（默认 250 ms） | 边界 = 一个拍，两轨都由录制器截：tick ≥ 边界的帧只计 `videoFramesBeyondStop`，PTS ≥ 边界拍点的样本只计 `audioFramesBeyondStop`。**`setStopTick` 在边界之前调**，录制照常继续，之后 `stop()`（nil = 用预告的拍）。**`stop(atTick:)` 也可以在边界之前调**：先等 tick = 边界 − 1 的帧（或越界帧）到齐再停编码器，然后等音频写到边界，最多等到 `边界拍点（或此刻，取晚者）+ stopGrace`；到齐立刻封口，不用等宽限到期。`stop(atTick: nil)` 没预告时的边界 = 最后一个已收帧的下一拍（G2 单子建议 2；以前是"此刻"，音频会比视频长）。改边界只在还没按旧边界丢过越界内容时允许；要求的边界早于已写入的帧时 clamp 到最后一帧的下一拍；实际生效的边界在 `RecordingResult.stopTick` |
| 4 `AudioEncoder.finish()` 空喂不崩 | `Encoding/AudioEncoder.swift` | `finish()`：`fifoWrite == 0` 就只置 `finishing`、不 drain（AudioConverter 对空输入也会吐 priming 那几个包，它们的 host time 没 stamp 可依）。另外 `emit` 里预卷包的 `host time − priming` 钳在 0（首块 host time 比 44 ms 还小时也不崩） |
| 5 `EncoderCounters.statsEntry` 补 frames / dropped / disk_free_mb / state | 不用做 | P2 已落地：`RecorderCounters.statsEntry(previous:windowSeconds:state:)` 填 frames = videoFrames、dropped = videoFramesRejected、disk_free_mb、state = `Recorder.State.statsName`；`Recorder.statsEntry` 给 Stats 采样线程用。`testP2_recorder_statsEntryCarriesFramesDiskAndState` 仍绿。`EncoderCounters.statsEntry` 本身保持只填 skipped / bitrate（裸编码器不知道文件 / 传输层，frames 等由持有它的 Recorder / StreamOutput / NDISender 填） |

新增计数（`RecorderCounters`，值快照，`Recorder.counters`）：`videoFramesBeyondStop`、`audioFramesBeyondStop`（按设计不进文件的）、`audioFramesDroppedAfterStop`（本该进文件、封口后才到的，> 0 = 组装方送得比 `stopGrace` 还晚）、`audioFramesDroppedTimeout`（writer 不接丢的）。都在 SwitcherOutputs 自己的结构里，Stats 契约没加字段（见 §4）。

测试工装（`Tests/SwitcherOutputsTests/TestSupport.swift`）：`LaggedAudioPump` —— 自己的线程每 5 ms 把"到 now − lag 为止应当产出"的样本按 256 帧块喂给消费者，块 PTS = 块首时刻但晚 60 ms 才送到，和 AudioEngine 的对齐延迟 2048 帧 + 一块 + 泵周期（约 50–60 ms）一个样子；`StopOutcome` 记 stop 的完成时刻（封口耗时的测法）。

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs`（debug，整包三个测试 target）。输出文件在 `$TMPDIR/switcher-outputs-tests/`。

| 测试 ID | 测试函数 | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|
| E5 停止边界 | `testE5_recorderStopBoundary_audioTrackWithin1Block` | 实时喂视频 300 拍到 T = 5 s，音频由泵晚 60 ms 送；`stop(atTick: T)` 在含边界的音频块到之前调，泵继续送 PTS > T 的块 5 s：**封口 85–86 ms**；视频 5.0000 s / 音频 5.0000 s（差 0.04 ms）；越界样本 236 415–236 927（只计数），封口后丢 0，硬校正 0，环丢块 0 | 封口 ≤ 1 s；音轨 = 名义 ± 1 块（5.33 ms） | ✅ |
| E5 预告停止拍 | `testE5_announcedStopTick_beforeBoundary` | 边界 T = 6 s，T − 2 s 时 `setStopTick(T)`，视频越过边界再喂 1 s、泵一直跑，之后 `stop()`（nil）：封口 7–9 ms；视频 6.0000 s / 音频 6.0000 s，**两轨差 0.00 ms**；越界帧 60 / 越界样本 44 544–44 800，封口后丢 0，硬校正 0；解码音轨 6 个 click 都在整秒 ± 48 样本内 | 差 ≤ 20 ms / ≤ 1 帧（16.67 ms）；越界块 0 个进文件 | ✅（两档都过） |
| E5 边界前 stop | `testE5_stopBeforeBoundary_waitsForFramesUpToBoundary` | 边界 120 拍，在第 90 拍（边界前 0.5 s）调 `stop(atTick: 120)`，视频继续喂到 150：封口在边界拍点后 71–77 ms 完成（不是宽限到期的 250 ms）；视频 2.0000 s / 音频 2.0000 s（差 0.00 ms）；越界帧 30，封口后丢 0 | 视频恰好 = 边界拍数；封口 ≤ 边界 + 0.5 s | ✅ |
| stop(nil) 边界 | `testStop_nilBoundaryIsLastConsumedFramePlusOne` | 尽快喂 120 拍 + 音频恰到 T，`stop()` 后再送 31 块（PTS ≥ T）：边界 = 120、视频 120 帧、音频恰 96000 样本、越界样本 7936 = 31 × 256、封口后丢 0；封口后再送一块边界之前的迟到样本：不写、不崩、`audioFramesDroppedAfterStop` = 256，状态 finished | — | ✅ |
| E5（原） | `testE5_normalStop20Times_fileIntegrity` | 20 次（30–3597 拍，种子 2026，16 次 AAC 4 次 LPCM，尽快喂）：ffprobe 全部无错、nb_frames = 拍数、视频时长误差全部 0.000 帧、音视频轨时长差 19 次 0.02 ms / 1 次 0.00 ms、两轨起点 0（与 W1-E 时逐字相同） | 无错；≤ 1 帧；≤ 20 ms | ✅ |
| E6 | `testE6_kill9TenTimes_playableLossUnder2s` | 子进程实时录 30 s，起点后 2–12 s 随机 kill -9 × 10：损失 0.026 / 0.803 / 0.195 / 0.577 / 0.152 / 0.521 / 0.477 / 0.801 / 0.109 / 0.099 s，最大 0.803 s、平均 0.376 s；每个截断 .mov 转封装出的 .mp4 ffprobe 无错、帧数与 .mov 相同（W1-E 时 0.804 / 0.378） | ≤ 2 s / ≤ 1 s | ✅（两档都过） |
| E2 | `testE2_bitrateCompliance_h264_6Mbps_1080p60_60s` | H.264 6 Mbps 1080p60 实时 60 s（噪声底）：总平均 6.000 Mbps；10 s 滑窗平均误差最大 0.55%；1 s 峰值 1.056×；skipped 0，喂帧晚点 0；关键帧间隔全部 120（W1-E 时 0.57% / 1.067×） | ≤ 10% / ≤ 5%；≤ 1.5× / ≤ 1.2× | ✅（两档都过） |
| E3 | `testE3_keyframeInterval120_h264AndHEVC` | H.264 与 HEVC 各 20 s：9 个间隔全部恰好 120，首帧关键帧 | ≤ ±1 帧 | ✅（精确） |
| E1 真编码器过喂（原测试，加档） | `testE1_realEncoderOverfeed_accountingHoldsAndPushNeverBlocks` | 2× / 4× / **8×**（新加）实时过喂 8 s：2× pushed 960 = encoded 960，4× pushed 1920 = encoded 1920（skipped 0——这台机器现在 240 fps 跟得上），8× pushed 3840 = encoded 2369–2374 + skipped 1466–1471（连跑 3 次），恒等式全部成立，push p99 4–7 µs；"一定跟不上"的断言挪到 8× | 恒等式；p99 < 0.1 ms；最高倍速 skipped > 0 | ✅ |
| AudioEncoder 空 finish | `testAudioEncoder_finishWithoutInput_doesNotCrash` | 没喂过块 `finish()` 两次：不崩、0 包、`framesIn` 0；finish 后再喂 256 帧不收 | 不崩 | ✅ |
| AudioEncoder 钳位 | `testAudioEncoder_prerollHostTimeClampedAtZero` | 首块 host time = 1 ms（< priming 44 ms），喂 1024 帧 finish：4 包，host time [0, 0, 0, 21 ms]，包 k 首样本 = 1024k − 2112 | 不崩、预卷包 ≤ 首块时刻 | ✅ |
| 其余（P2 / E1 / ISO / 磁盘 / ProRes / 转封装 / click / 命名 / 素材 / AudioEncoder 原测试；Streaming、NDISend） | 整包 `swift test` 跑了两遍 + SwitcherOutputsTests 第三遍 | **第 1 遍**（实现提交 8f138f2 之前的工作树）：SwitcherOutputsTests 25 / 25 绿（727 s，其中 E5 20 次 452 s——机器上另有会话在编译，W1-E 时 165 s）；NDISendTests 8（2 跳过：人工 Studio Monitor、"无 SDK"用例）绿；StreamingTests 28 个：4 跳过（BLOCKED-工具：本 worktree 没编 release frameprobe，E7 / E8 / RTMP / SRT 端到端要它；E2E3 60 s 与 E9 343 s 过）、1 个失败 `ThrottleProxyTests.testBlockStopsForwardingAndCloses`（W2-D 的代理工装，纯套接字、与本会话无关；单独连跑 3 次过 2 次，问题单 `reports/issues/W1E2-w2-stream-throttle-proxy-close-flaky.md`）。**第 2 遍**（8f138f2）：StreamingTests 28（4 跳过）全绿、NDISendTests 8（2 跳过）全绿；SwitcherOutputsTests 24 / 25——`testE1_realEncoderOverfeed` 4× 这次 skipped 0，"4 倍速一定跟不上"的断言抖了（第 1 遍 skipped 1，W1-E 时 21），与录制器无关，改法见上一行（提交 f1cd766）。**第 3 遍**（f1cd766，只跑 SwitcherOutputsTests）：24 / 25：E1 过喂（含新加的 8×）、E5 × 4、E6、E2、E3、AudioEncoder 等全过；**唯一失败 `testISO_fourRecorders30s`**——第 3 / 4 路 skipped 157 / 158（帧数 1643 / 1642），跑这 33 s 时另一个会话（w1-core-2）正在同一台机器上跑 10 分钟 gate3（release headless + 5 个录制器，`VTEncoderXPCService` 同时在为它编码），4 路 1080p60 = 240 fps 正好是这台机器硬件编码器的吞吐边界（上一行 4× 过喂的结论），被抢就跳帧；等它的 headless 退出后单独重跑 ISO：4 路全部 1800 帧、跳帧 0、编码延迟 max 30.7–33.9 ms（W1-E 时 24.8–28.4）。第 1、2 遍整包跑时 ISO 都过 | — | ✅（三遍里本会话目录的 25 个测试没有一个失败与录制器 / 编码器改动有关：两次失败一次是硬件假设、一次是别的会话抢硬件编码器） |

BLOCKED：无。

## 3. 没做的和原因

- **`stop` 之后不能再把边界提前**（例如预告了很远的边界又想"现在就停"）：`stop` 只接受一次，`.stopping` 期间再调返回 `notRecording`。现在的组装方（headless / App 的停止按钮 = 当前拍 + 1）都用不到；要的话在 `stop` 里允许 `.stopping` 时把边界往前挪并叫醒等待即可（十几行），没做是不想在没有用例的情况下加语义。
- **改了 W1-E 的一个老测试**（`testE1_realEncoderOverfeed…`，在本会话目录里）：加 8× 一档，"一定跟不上"的断言从 4× 挪到最高倍速。这不是放宽阈值——2× / 4× 的恒等式与 push p99 断言原样，只是"240 fps 一定超过硬件编码器"这个硬件假设在这台机器上已不成立（4× 现在 0–1 帧），8× 连跑 3 次 skipped 1466–1471 稳定。
- **`audioFramesDroppedTimeout` 没有测试能稳定触发**：writer 两个输入都是 `expectsMediaDataInRealTime`，正常永远 ready；计数放着给 Stats / 排障看。
- **`stop(atTick: nil)` 没预告时仍是"最后一帧的下一拍"而不是"此刻"**：G2 单子的字面（"nil = 此刻起不再收帧"）改了，因为"此刻"必然让音频比视频长半块到一块。以前唯一用 nil 的地方是 headless 的旧版本和测试里"一帧没写就 stop"的用例，行为没变（起始拍、失败）。

## 4. 对契约的疑问

1. 新增的四个计数（越界帧 / 越界样本 / 封口后丢样本 / writer 超时丢样本）只在 `RecorderCounters`，**没进 Stats.encoder**：提案 001 的 `dropped` 定义是"编码之后、落地之前丢的视频帧"，音频样本不是帧，硬塞进去口径会乱。真要在 stats.jsonl 里看到"录制音频丢了多少"，得加字段（`audio_dropped` 之类）——我倾向不加：`audioFramesDroppedAfterStop > 0` 只会在组装方送晚了的时候出现，是排障项不是指标；A1 看的是混音器输出的不连续，与录制器入口无关。要加的话再写提案。
2. `AudioBlockConsumer` 协议（P2 已升契约）没有"块的 PTS 已越过某个时刻就别再送"的反向通道，所以越界块由每个消费者自己在入口丢（本会话的做法）。够用，不建议改协议。

## 5. 下一个会话需要知道的坑

- **给 G4 / 组装方**：`Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift` 第 8 步"等含边界的块到（边界 + 对齐延迟 + 2 块 + 6 ms）→ `audioEngine.removeConsumer` → `rec.stop(atTick:)`"的绕法**可以撤**：引擎停了之后直接 `rec.stop(atTick: boundary)`（帧都到了，录制器自己等音频到边界，最多 250 ms；实测 60 ms 延迟的泵 85 ms 封口），`removeConsumer` 放到 `audioEngine.stop()` 前后都行（封口后到的块只计数）。ISO 录制器同样。**G4 gate 里 E5 应按 ≤ 20 ms 判**（本会话文件级两轨差 0.00–0.04 ms）。跑满的场合也可以更早：最后一拍派完时 `rec.setStopTick(lastTick + 1)`，但注意跳拍——引擎的 `lastTick` 可能小于 `totalTicks − 1`，预告 `totalTicks` 会让音频比视频多几帧；所以用 `engine.counters.lastTick + 1`、在引擎停后调 `stop(atTick:)` 是最省事的（等价于现在，只是去掉等待和摘消费者）。
- **`stopGrace` 从边界拍点起算**（边界之前调 stop 的场景），边界之后才调的从此刻起算。只有边界之前的帧 / 音频还没到齐才真的等，所以尽快喂的测试（时间轴在墙钟前面十几秒）不受影响。第一版写成 `min(边界, 此刻) + 宽限`，边界前 0.5 s 调 stop 时宽限在边界之前就到期、少录 14 帧——`testE5_stopBeforeBoundary` 抓到的。
- **越界的判定在两处必须同口径**：入口按 host tick（`stopTimeTicksAtomic`）、writer 队列按纳秒（`stopTime.nanoseconds`），都是"块首 ≥ 边界拍点"；含边界的块只会被 writer 队列裁。`consume` / `consumeAudio` 在 `.finished` 状态也继续计越界（组装方封口后没马上摘消费者时计数才对得上），`.failed` 不计。
- **音频"到边界"的判定留了一个样本的容差**：`SignalFeeder.flush(upToSample: sampleIndex(at: 边界))` 向下取整，最后一块的末尾比边界拍点早不到一个样本；不留容差 stop 会白等 250 ms。
- **`finishIfReady` 先清 `finishRequested` 再 `drainAudio()`**，否则 drainAudio 末尾的"到边界就封口"会递归回来。
- **`DispatchSemaphore` 用作 stop 的叫醒**只 signal 不配对 wait 没问题（值只增不减，deinit 不会因为"低于初值"崩）；`consume` 只在越界帧和边界前一拍才 signal。
- `swift test` 整包一遍约 24 分钟（SwitcherOutputsTests 12 + StreamingTests 12，后者含 E9 的 5 分钟限速；机器空闲时 W1-E 的 18 个是 7 分钟）。新测试只加了约 24 s（三条实时的 E5 边界测试 5 + 7 + 3 s 加 ffprobe）；StreamingTests 里 4 个端到端要先 `swift build -c release --package-path Tools/frameprobe`，否则 XCTSkip。
- **并行会话共用一个硬件编码器**：这台机器 1080p H.264 的吞吐约 240–300 fps，`testISO_fourRecorders30s`（4 路 60 fps）和 E1 过喂测试都贴着这条线；别的会话在跑 gate3（headless 5 个录制器）时它们会跳帧。跑本包测试前 `pgrep -fl 'Release/switcher-headless'` 看一眼，正像 G2 提醒过的 `pgrep -x Cyberpunk2077`。
- 磁盘错误测试的 hdiutil 小盘失败时可能留挂载点：`hdiutil detach $TMPDIR/switcher-outputs-tests/tiny-volume -force`（W1-E 报告说过）。
