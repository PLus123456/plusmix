# frameprobe av 按"第一帧 = 第 startTick 拍、帧距均匀"推拍号：视频延后之后两种文件会把整秒配对判成不在整秒

归属会话 / 分支：W1-A 系列（SwitcherTestKit `Probe/FrameAnalysis.swift`、Tools/frameprobe）
发现于：W1-B4 / `w1-core-4`，2026-10-10，`Tools/switcher-headless` 的 `testA2_videoDelayMode_recordingStaysAligned`
严重级：S3（只影响量法，不影响文件；本会话的用例已按 frameprobe 现有口径绕过）

## 现象

提案 028（用户已批）：补偿方式 videoDelay 下视频的时间戳 = 拍点 + L（Master 效果链延迟）。用 headless 录 12 s（Master 限幅起音 30 ms，`--av-compensation videoDelay`），
`frameprobe av` 的结果：11 个闪光全部配上 click、每一对偏移 0.000–0.021 ms（文件内 A/V 对齐），但 **整秒配对 0 对、"不在整秒" 11 对**。

原因：开录起点仍是拍点 t0（App / headless 的 `RecordingStart(clock:tick:)`，提案 028 第 3 条用户定"只写进报告"），视频第一帧的 PTS = 30 ms，
AVAssetReader 在 0 时刻多读出一帧黑（空 edit：`frameprobe frames` 第 0 帧 pts 0、灰度 0、没有图案；第 1 帧 pts 0.030 才是第 0 拍）。
`FrameAnalysis.av` 用 `pts0 = frames.first.ptsSeconds`（= 0）推拍号：第 k 秒的闪光 pts = k + 0.030 → round((k + 0.03) × 60) = 60k + 2，于是判成不在整秒。

另一种情形（本会话没造文件，按代码推）：**录制中途** L 变了（开 / 关限幅），视频时间戳按每拍 1/4 拍平滑地挪 ΔL，之后的帧距网格整体错开 ΔL；
ΔL > 半帧（8.3 ms）时后面的整秒闪光同样会被判成不在整秒（配对本身仍对齐）。

## 复现步骤

```bash
swift test --package-path Tools/switcher-headless --filter AVCompensationTests/testA2_videoDelayMode_recordingStaysAligned
```
用例里 videoDelay 那一份给了 `FrameProbe.Options.startTick = −round(0.030 × 60) = −2`（frameprobe 文档里"文件不从第 0 拍起时用 --start-tick"的口径），去掉这一行即复现。

## 建议

拍号别只靠 pts 网格：跳过开头没有图案的帧（黑场 / 空 edit）再取 pts0，或者用图案里的帧号 + 输入帧率反推；中途改延后的情形可以按"相邻帧 pts 差 ≈ 1 拍"逐帧累加拍号，
而不是 (pts − pts0) × fps 一次乘出来。要不要做由 W1-A 系列定；做之前，带视频延后的录制文件按上面的 `--start-tick` 量，且别在录制中途改 Master 效果。
