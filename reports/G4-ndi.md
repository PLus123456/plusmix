## NDI 回环 L1（scripts/gate4-ndi.sh，2026-09-20 14:19）

- 做法：headless `--ndi-send "Switcher G4 loop"`（W2-D NDISender 发 PGM + Master 音频）→ 同一进程里 W3-A 的 NDIInput 收「机器名 (Switcher G4 loop)」，抖动缓冲 J = 1 帧，PGM = 1 号合成源（60 fps 噪声底纹 + 音频），PVW = 2 号 NDI 输入；跑 60 s，去掉头 5 s；数字来自 stats.jsonl per_input["2"]（提案 005 的 L1，铁律 4）。
- 口径：W3-A 报告 §1.2——NDI 帧 pts = 到达 − 抖动 + J × 帧间隔，L1 含 J 帧的有意缓冲；判 L1 ≤ 3 + J 帧（W3-A 用例同口径），扣掉 J × T 后对 3 帧的余量另报。

| 指标 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| L1 NDI（每秒均值的平均） | 27.04 ms（1.62 帧；扣 J×T 后 0.62 帧） | ≤ 4 帧（3 + J；目标 ≤ 3） | ✅（目标档也过） |
| L1 NDI（每秒最大值的 p99 / max） | 28.21 / 28.38 ms（1.70 帧） | max ≤ 4 帧 | ✅ |
| NDI 输入 fps（每秒） | min 59.14 / avg 60.01 / max 60.76 | ≈ 60 | ✅ |
| NDI 输入 dup / drop（5 s 后增量） | dup +0，drop +0 | 设计外 0（V4 口径，60 → 60） | ✅ |
| missed_render（全程） | 0 | 0 | ✅ |
| NDI 发送（Stats.encoder 末项） | frames 3547，dropped 0，state publishing | dropped 0 | ✅ |

- 产物：`.build/gate4/ndi/stats.jsonl`、`.build/gate4/ndi/headless.log`（末尾有 NDI 输入 / 发送端的计数：收 / 推 / SDK 丢 / 抖动均值与最大）。
- 结论：**通过**（L1 ≤ 3 + J 帧）。
