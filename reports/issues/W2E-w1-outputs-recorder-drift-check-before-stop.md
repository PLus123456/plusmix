# Recorder.drainAudio 先查漂移后查 stopTime：边界之后仍有块到达时补静音，且 appendPCM 在 writer 收尾后每 4096 帧等 200 ms

归属会话 / 分支：W1-E / `w1-outputs`（`Recording/Recorder.swift` 的 `drainAudio` / `appendSilence` / `appendPCM`）
发现于：W2-E / 45 s 冒烟跑（scratchpad 里用 W2-E `AudioEngine` 接线的 headless 副本，见 `reports/issues/W2E-g3-headless-audio-engine-wiring.md`），main 2290b4e + w2-audio-integ

## 现象

W2-E 把 Master 块的 PTS 改成"块首 host time − 对齐延迟（42.67 ms）"之后，含边界（最后一拍 + 1）的那块要比 G2 时晚 8 块才到录制器。
`rec.stop(atTick: 边界)` 之后泵线程还在送块（组装方要等 `audioEngine.stop()` 才停），进程 3 分钟没退出，`sample` 显示 writer 队列
100% 在 `drainAudio → appendSilence → appendPCM → usleep`（Recorder.swift:375 / 407）。

机理（读代码）：`drainAudio` 对每块**先**算漂移 `driftNs = blockStart − (origin + appended/rate)`、超过一帧就 `appendSilence(drift × rate)`，
**然后**才看 `stopNs`。边界之后的块：被截到 stopNs 的那块之后 appended 不再增长，后面每来一块 drift 多 5.33 ms，第 4 块起 > 16.7 ms 阈值 →
补静音（appended 越过 stopNs）→ 再往后的块又从头累积……而 writer 已 `finishRequested`，`appendPCM` 每 4096 帧等 400 × 500 µs = 200 ms
超时后静默丢样本（G2 的问题单 `G2-w1-outputs-stop-with-live-audio.md` 已指出不计数）。泵线程 187 块/s 地喂、每块都触发一次 `writerQueue.async { drainAudio() }`，
补静音的长度随墙钟增长，就拖死了。

同样机理的轻症：跑满时 headless 在最后一拍之后过 ~50–150 ms 才调 `stop(atTick:)`，这段时间到达的、PTS 已过边界的块被照常 append，
录制音轨比名义时长多 54–153 ms（G2 报告的"+3745 / +5306 样本"就是它；E5 的"音视频轨道差 ≤ 20 ms"会不过）。

## 复现步骤

W2-E 的 headless 副本去掉"封口前先 `removeConsumer`"那段（补丁在 `W2E-g3-headless-audio-engine-wiring.md`），跑 `--duration 45`；或单元测试：
Recorder 起 → 按拍喂视频到 T → `stop(atTick: T)` → 继续按实时喂 PTS > T 的音频块 5 s → 观察完成回调延迟。

## 严重级

S2（封口挂死；E5 音轨长度）。

## 建议

1. `drainAudio` 里 `stopNs` 的判断放在漂移判断**之前**：`blockStartNs >= stopNs` 的块直接 `continue`，不参与漂移 / 补静音；截断的那块之后不再改 `audioFramesAppended` 的期望。
2. `finishRequested` 之后（或 writer 输入已 markAsFinished）`appendPCM` 立即返回并计数，不再等 200 ms。
3. 边界之前就能知道停止拍的场景（脚本跑满、用户点停止 = 当前拍 + 1），给一个"预告停止拍"的入口（例如 `stop(atTick:)` 允许在边界之前调，
   或 `setStopTick(_:)`），录制器自己截到边界，组装方不用赌时序。W2-E 的 headless 副本现在的做法是：边界的块送到后（边界 + 对齐延迟 + 2 块 + 6 ms）
   先 `audioEngine.removeConsumer(录制器)` 再 `stop(atTick:)`，音轨仍多 ~15–54 ms（取决于摘得多快）。
