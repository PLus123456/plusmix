## 44 W1-A2 合成源噪声底纹 + frameprobe 补课（测试工装续做）
分支：w1-testkit-2（从 G3 合入后的 main 开，最好在 P2 之后：噪声底纹要契约 006）。只准动：Packages/SwitcherTestKit/、Tools/frameprobe/、Tests/Fixtures/。
先读：reports/issues/G3-w1-testkit-synthetic-noise-for-E2.md；reports/issues/W2D-w1-testkit-frameprobe-av-on-stream-recordings.md；reports/issues/W2E-g3-pending-changes-checklist.md 的 3-9、3-10；
docs/contract-changes/006；reports/G2.md §7 第 5 条（合成源到达相位）；测试标准 §2.1–2.3、§3 E2 / A1 / A2。

背景：G3 的 10 分钟 L2 运行里 E2 量不出——灰底合成源整段只压出 0.1 Mbps（设定 6 Mbps），gate3-report 只能标"本场景不适用"，以 W1-E / W2-D 的噪声用例为准。
frameprobe 还欠三样：推流落盘文件（无 priming 信息、音轨 start_time ≠ 0）的 A2 偏 44–64 ms；59.94 在播段闪光周期 1.001 s 让 A2 的均值 / 最大值失真（gate 报告现在自己另算整秒配对）；
A1 的第三项（波形不连续，按已知 click 位置排除）只有 W2-E 的 scratchpad 探针能算。

交付：
1. `SyntheticVideoInput` 支持 `.noise(level:amplitude:seed:)` 底纹（006 落地后）：零均值噪声叠在灰底上，帧号 / 时间戳 / ID / 闪光块区域不加噪；GPU 或 CPU 生成都行但每帧成本要写进报告（8 路 1080p60 CPU 画图案已占 24%）；
   中心 1/4 区域的灰度均值 = level ± 1（V6 / V7 不受影响）。`M0Factory` 不动（G2 基线可比），`G3Factory`（Tools/，检查点的）由 G4 改成噪声。
2. `frameprobe av`：音频时间轴加上音轨 start_time；`--aac-priming auto|0|N`（默认 auto：有编辑列表 / priming 信息就信 AVFoundation，没有就不裁）；报告里同时给 AVFoundation 与 ffmpeg 两种口径。
3. `frameprobe av` 的 A2 默认按"闪光落在整秒拍上"的配对判定（另报全部配对与 59.94 在播段的说明）；`passA2` 按整秒配对。
4. `frameprobe av --discontinuities`：搬 W2-E 的 `DiscontinuityDetector.analyze(samples:isExcluded:)`（相邻样本跳变 > 0.5 满幅，按已知 click 位置 ±1 ms 排除），输出计数与位置；这是 A1 第三项的正式离线口径。
5. `StatsSummary`：P2 落地的新列（encoder frames / dropped / state、audio meters、per_input latency）若 P2 没做，这里补。

测试（函数名带 ID）：
- 噪声底纹：解码器对加噪帧的帧号 / ID / 闪光判读 100% 正确；中心均值 = level ± 1；1080p60 H.264 6 Mbps 录 60 s 的平均码率 ≥ 设定的 80%（E2 才有可判对象）。
- `testA2_streamRecordingWithoutPriming_matchesFFmpeg`：用 W2-D 落盘的 fMP4（或自己合成一个无 priming 的 fMP4）两种口径差 ≤ 1 ms。
- `testA2_exactSecondPairing_ignores5994FlashDrift`：60 / 59.94 交替在播的合成文件，整秒配对均值 ≈ 0、全部配对均值明显偏。
- `testA1_discontinuities_excludesKnownClicks`：G3 的 out.mov（或合成）不连续 0，人为插一个 0.6 满幅跳变 → 1。
- `make gate3-run` 之后 reports/G3.md 的 E2 行不再"不适用"（G4 改场景后）。

报告 reports/w1-testkit-2.md：噪声生成的每帧成本、三个 frameprobe 修正的前后数字。
