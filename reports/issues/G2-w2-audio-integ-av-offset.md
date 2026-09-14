# 录制文件里 click 比闪光晚 18.6 ms（A2 超必须档 16.7 ms；恒定、无漂移）

归属会话 / 分支：W2-E / `w2-audio-integ`（W1-D 报告 §5"给 W2-E 的延迟核算"明确说混音器的 ageSetpoint 延迟由 W2-E 在 A/V 偏移里扣；录制器锚定那一块请 W1-E 确认）
发现于：G2 / 45 s 冒烟跑 + `make gate2` 10 分钟（frameprobe av，数值见 reports/G2-run-10min.md）

## 现象

`frameprobe av`：44 / 44 个闪光都配上 click，偏移（音频超前为正）均值 −18.604 ms、标准差 0.000、最大绝对值 18.604 ms，斜率 0（A3 口径无漂移）。阈值 A2 ≤ 16.67 ms（必须）→ 超 1.9 ms。M0 不判 A2，记录给 G3。

## 分解（推测，待 W2-E 核实）

- 混音器输入槽稳态落后写入位置 target + P/2 + hf + chunk/2 = 512 + 128 + 47 + 16 = 703 帧 = 14.65 ms（W1-D 报告 §5、§6）；
- 合成音频块在其末样本时刻"到达"（W1-A），空设备块粒度 256 帧 = 5.33 ms；
- 录制器把起点后的第一块整块锚到起点（`RecorderCounters.audioDrift` 稳定在 +5.334 ms = 正好一块），即把音频**提前**了 5.33 ms；
- 14.65 + 5.33 + 5.33 − 5.33 ≈ 20 ms，实测 18.6，剩余约 1.4 ms 未解释。

## 复现步骤

`make gate2` 后 `frameprobe av .build/gate2/10min/out.mov --fps 60 --markdown`；或任何带音频的 headless 运行。

## 严重级

S2（A2 必须档不过），G3 判定。

## 建议

W2-E 在混音输出块的 PTS 上扣掉 `InputSlotStats.ageSetpoint`（或对视频加同样延迟）；W1-E 确认录制器首块锚定是否应精确到样本（按块 hostTime 与起点差裁样本，而不是整块对齐）。
