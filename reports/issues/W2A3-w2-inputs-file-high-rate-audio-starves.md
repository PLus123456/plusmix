# W2-A3 → W2-A：文件输入带音频时，速率 × 片段帧率 / 节目帧率 ≥ 3 就饿死（4 帧 / 拍：8 s 只转 2–3 圈、推帧线程自旋 220 万次晚醒；3 帧 / 拍：勉强能转但音频块大量跳过）

归属会话 / 分支：W2-A 输入（`Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift`、`FileQueues.swift`）
发现于：W2-A3（`w2-inputs-3`，2026-09-28）——写 S2 循环泄漏用例时想用速率 8 把圈数跑快一点，结果 40 s 只转了 3 圈
严重级：S2（有绕过办法：速率 × 片段 fps / 节目 fps ≤ 2 时一切正常；`FileInput.paceLoop` 里 `maxSrc = chunk * 17 + 4 // 速率 ≤ 16` 写的上限远高于实际能跑的）

## 现象（临时探针，每个配置跑 8 s；320×240 H.264 + AAC 片段，60 fps 节目，`LockFreeFrameSlot(3)` + `RecordingAudioRing`）

| 片段 | 速率 | 音频环 | 每拍前进（片段帧） | 8 s 圈数 | ticksStarved | lateWakes | 音频块写 / 跳 | 判 |
|---|---|---|---|---|---|---|---|---|
| 30 fps × 30 帧 | 8 | 有 | 4 | **3** | **433** | **2 221 655** | 59 / **1413** | 饿死 |
| 60 fps × 60 帧 | 4 | 有 | 4 | **2** | **416** | **2 210 452** | 84 / **1399** | 饿死 |
| 30 fps × 30 帧 | 8 | **无** | 4 | 47 | 1 | 0 | — | 能转（圈速 5.9 / s，低于速率要求的 8 / s，见机制 1） |
| 30 fps × 30 帧 | 6 | 有 | 3 | 47 | 3 | 503 439 | 1268 / 218 | 勉强：音频跳块、推帧线程自旋 |
| 60 fps × 60 帧 | 3 | 有 | 3 | 23 | 2 | 229 555 | 1382 / 107 | 同上 |
| 30 fps × 30 帧 | 4 | 有 | 2 | 31 | 0 | 0 | 1489 / 0 | 正常 |

已有用例 `testFile_rate2_advancesTwoFramesPerTick`（60 fps 片段、速率 2、无音频环 = 2 帧 / 拍）在正常区里，所以没发现。

## 机制（读代码，没改）

1. **视频消费封顶在约 `predecodeDepth`（3）帧 / 拍**：`paceLoop` 每拍 `while let head = queue.peek()` 把 media ≤ 位置的帧一口气 pop 完，队列深度 3、
   解码线程要等 pop 之后才补，一拍里通常只 pop 到 3 帧。时间线每拍前进 4 帧时，解码位置就一直落后于时间线，圈速 = 3 × 60 / 片段 fps（探针里 5.9 圈 / s < 8）。
   没有音频时只是"播不到速率那么快"，不死。
2. **有音频时死锁**：`decodeLoop` 要 `videoDone && audioDone` 才重开 reader，下一圈的音频被本圈的视频尾巴挡住，音频供给也封顶在圈速 × 时长；推帧线程的音频块
   按时间线（真实时间 × 速率）要样本，`DecodedAudioFIFO.copy` 拿不到 → 过 `due + 4 块` 就 `audioChunksSkipped += 1; chunkIndex += 1` **但不 trim**；
   FIFO（24000 帧）被旧样本占满、解码线程卡在 `fifo.append` 的 `while planes[0].count >= maxFrames` 等 trim，而 trim 只在 copy 成功时发生 → 要的样本序号一路跑远、
   永远不会再落进 FIFO 的窗口 → 两边互等：解码线程不出帧（ticksStarved 每拍 +1）、推帧线程每块过期都立刻返回（`audioWake = due` 在过去 → `sleep` 立刻返回 → lateWakes 自旋）。
3. 3 帧 / 拍是临界：视频刚好跟得上，偶尔一两拍落后就触发一轮跳块 + 自旋，能自己恢复。

## 修法建议（W2-A）

- 解死锁（小改，`paceLoop` 音频段）：跳过一块时也 `fifo.trim(before: firstIndex - 2)`，让解码线程能继续填；或者 `DecodedAudioFIFO.append` 在满且"队头比要的还老"时自己丢队头。
- 恢复吞吐（`decodeLoop`）：解码线程知道时间线，解出来的帧 media 已经落后于当前位置超过一帧时不入队直接丢（计 `framesRejected`），reader 才能追上时间线；
  或者 `predecodeDepth` 随速率放大（`ceil(rate × 片段 fps / 节目 fps) + 1`），代价是多几张 IOSurface。
- 自旋（与问题单 W4A-…-prores-starve §2 的"晚醒"同源）：`audioWake` 过期时按 `min(due + 4 块, now + 1 块)` 轮询，不要立刻返回。
- 补用例：`testFile_rate4_60fpsClipWithAudio_noStarve`（4 帧 / 拍 + 音频环，8 s 内圈数 ≥ 速率 × 8 / 时长 × 0.9、`ticksStarved` 0、`audioChunksSkipped` 0）；
  W2-A3 的 `LoopClipWriter` 能现场造任意 fps / 帧数的 H.264 + AAC 片段。

## 复现

`Packages/SwitcherInputs/Tests/SwitcherInputsTests/` 里写一个临时用例：`LoopClipWriter.write(to:url, fps: 30, frames: 30)`，
`FileInput(…, endAction: .loop, rate: 8, timing: ProgramTiming(format: .hd1080p60, …), videoSlot: LockFreeFrameSlot(capacity: 3), audioRing: RecordingAudioRing(channelCount: 2))`，
`start()` 后睡 8 s 看 `fileCountersSnapshot`（loops / ticksStarved / lateWakes / audioChunksSkipped）。W2-A3 报告 §3.4 有同一张表。
