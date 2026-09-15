# Recorder.stop(atTick: nil) 期间音频仍在到达时收尾拖成分钟级，且 appendPCM 超时丢样本不计数

归属会话 / 分支：W1-E / `w1-outputs`（`Recording/Recorder.swift`）
发现于：G2 / 45 s 冒烟跑（headless 提交 `0bb31fe` 之前的版本：封口用 `stop(atTick: nil)`，封口期间泵线程继续把 Master 块喂给 `consumeAudio`）

## 现象

时钟跑完 2700 拍后进程 5 分钟没退出。`sample` 显示 writer 队列 100% 时间在 `drainAudio → appendSilence → appendPCM → usleep`：
- `stop(atTick: nil)` 的 stopTime = 此刻，比最后一个视频帧末尾晚了收尾那几百毫秒；这段音频超前于已结束的视频轨，AVAssetWriter 的音频输入不再 ready；
- `appendPCM` 等 200 ms（400 × 500 µs）后 `guard ain.isReadyForMoreMediaData else { return }` **静默丢掉这批样本，不计任何数**；
- 每块都等 200 ms，入口环（256 块 ≈ 1.4 s）溢出丢最旧块 → 下一块 hostTime 与样本时间轴的偏差超过一帧 → `audioResync` 补静音 → 静音按 1024 帧一段各等 200 ms → 越拖越长。
stats.jsonl 里同时看到 `audio.underruns` 从 0 跳到 188（那是组装方先停了音频源、混音器还在跑，与本单无关，headless 已改停止顺序）。

## 复现步骤

单元测试：起 Recorder（有音轨），按拍喂视频到 T，然后继续按实时喂音频到 T + 2 s，再 `stop(atTick: nil)`；观察完成回调延迟与 `RecorderCounters`（没有任何计数反映丢掉的样本）。
或把 headless 的封口改回 `stop(atTick: nil)`（`HeadlessRun.swift` 第 8 步）并保持泵线程运行。

## 严重级

S2：组装方按 API 字面用（"nil = 此刻起不再收帧"）会挂死；样本被丢没有计数，A1 / E5 看不见。

## 建议

1. `appendPCM` / `appendVideo` 超时放弃时计数（`RecorderCounters` 加 `audioSamplesDropped`，或并进 `audioBlocksDropped`），并考虑把 200 ms 的等待改成"不等，直接丢并计数"（writer 两个输入都是 expectsMediaDataInRealTime）。
2. `stop(atTick: nil)` 的 stopTime 用最后一个已写视频帧的末尾，或在 `.stopping` 状态丢弃晚于它的音频；文档写明"封口边界要传拍"。
3. G2 的 headless 已改为 `stop(atTick: 最后一拍 + 1)`（`0bb31fe`），封口 < 1 s，问题不再触发；此单只是让 API 不再有这个坑。
