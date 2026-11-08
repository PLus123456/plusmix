# baselines/ —— 性能基线

每个检查点固定产出 `baselines/<检查点小写>-<机器>.json`，例如 `m0-m5max.json`（G2）、`g3-m5max.json`。
内容：该检查点报告里的关键数字（V1 avg / p99、V3 p99、CPU、GPU、RSS 等），供下一个检查点算"与上一版本的差"，供 W4-A 的 L5 判"无退步"。

字段名与 stats.jsonl（测试标准 §7）一致，不另起名字。字段结构由 W1-A 的 StatsSummary 定，G2 第一次落文件。
这台开发机（M5 Max）远强于目标机（M1 Air 8 GB）：这里的基线只用于本机回归比较，发布前 L5 要在 Air 上另跑一份 `*-m1air.json`。

## 各检查点的基线

| 文件 | 检查点 | 场景 | 与上一版本可比吗 |
|---|---|---|---|
| `m0-m5max.json` | G2 | scenarios/m0-show.json（8 路纯灰底合成源） | — |
| `g3-m5max.json` | G3 | scenarios/g3-show.json（当时还是灰底；Overlay 1 关着，多画面默认布局） | 与 m0 同负载口径，V1 可比 |
| `g4-m5max.json` | G4 | scenarios/g4-show.json（噪声底纹 ±24、5–8 号抠像、Overlay 1–4 轮流开、多画面自定义布局、五种转场） | **与 g3 不可比**：底纹和负载都变了（G3 交接第 2 条、W3-B 报告 §5 第 1 条）。W4-A 的 L5"无退步"从 g4 起算 |
| `g6-m5max.json` | G6（`make gate4-run GATE4_CHECKPOINT=G6 GATE4_PREVIOUS=baselines/g4-m5max.json GATE4_BASELINE=baselines/g6-m5max.json GATE4_LABEL=g6`） | 同 g4（scenarios/g4-show.json + g4.json，第五波止血五路合入后的树 3e7cdae，macOS 27.0） | 与 g4 同场景可比（V1 p99 −0.148 ms、CPU −1.5 个百分点）；g4 是 26.6.2 上的、本机已升 27，跨大版本只作参考 |
| `g7-m5max.json` | G7（`make gate4-run GATE4_CHECKPOINT=G7 GATE4_PREVIOUS=baselines/g6-m5max.json GATE4_BASELINE=baselines/g7-m5max.json GATE4_LABEL=g7`） | 同 g4 / g6（scenarios/g4-show.json + g4.json，第五波骨架七路合入后的树 0137ec9，macOS 27.0） | 与 g6 同场景、同机、同大版本可比（V1 p99 −0.170 ms、V3 −0.017 ms；S3 CPU +6.6 / GPU +13.6 个百分点——引擎 / 渲染 / 音频 / 输出包与 g6 逐字相同（只有 SwitcherControl 变了，L2 场景不走它），差的是机器状态（跑前负载 4.2、Claude 桌面端在跑）） |
| `g8-m5max.json` | G8（`make gate4-run GATE4_CHECKPOINT=G8 GATE4_PREVIOUS=baselines/g7-m5max.json GATE4_BASELINE=baselines/g8-m5max.json GATE4_LABEL=g8`） | 同 g4 / g6 / g7（scenarios/g4-show.json + g4.json，契约后四路 100–103 合入 + G8b 胶水后的树 9815082，macOS 27.0.1） | 与 g7 同场景、同机、同大版本可比（V1 avg +0.227 / p99 +0.126 ms、V3 p99 +0.015 ms、S3 CPU −7.1 / GPU −13.5 个百分点——g7 那次机器在忙，S3 偏高；RSS max +18.5 MB = W1-B4 的 NV12 环 8 → 12 与 W1-D3 每路两格的预分配，S2 看斜率）；A4 自动判定的 ❌ 是 frameprobe 配对平局假象（reports/issues/G8b-w1-testkit-frameprobe-a4-halfsecond-click-tie.md），按整秒配对极差 0.187 ms；运行报告多一行 L1（扣 video_delay_ms） |
| `g9-m5max.json` | G9（`make gate4-run GATE4_CHECKPOINT=G9 GATE4_PREVIOUS=baselines/g8-m5max.json GATE4_BASELINE=baselines/g9-m5max.json GATE4_LABEL=g9`） | 同 g4 / g6 / g7 / g8（scenarios/g4-show.json + g4.json，续做五路 109–113 合入 + G9 胶水后的树 9bf9fe1，macOS 27.0.1 / Xcode 27.1 + Metal 工具链 27A266a） | 与 g8 同场景、同机、同大版本可比（V1 avg +0.004 / p99 +0.005 ms、V3 p99 −0.002 ms、S3 CPU −0.3 / GPU −0.4 个百分点、RSS max +2.4 MB）；A4 这次直接判 0.188 ms（113 的锚配对，不再 waive）；L1 扣 video_delay_ms 那行 avg 0.77 帧 / p99 1.60 帧 |
| `g10-m5max.json` | G10（`make gate4-run GATE4_CHECKPOINT=G10 GATE4_PREVIOUS=baselines/g9-m5max.json GATE4_BASELINE=baselines/g10-m5max.json GATE4_LABEL=g10`） | 同 g4 / g6–g9（scenarios/g4-show.json + g4.json，止血七路 115–121 合入 + G10 胶水后的树 7c0656e，跑在只多文档的 52e83cd 上；macOS 27.0.1 / Xcode 27.1 + Metal 工具链 27A266a） | 与 g9 同场景、同机、同大版本可比，**但桌面不静**：Claude 桌面 App 的会话界面一直在重绘（WindowServer 均值 41.4% CPU，g9 那次 1.2%），整卡 GPU 均值 39.2%（+12.0 个百分点）跟着桌面负载走、不是代码（reports/G10.md §5 L5）；V1 avg −0.359 / p99 −0.395 ms、V3 p99 +0.002 ms、S3 CPU −7.2 个百分点、RSS max +0.7 MB；A4 按 passA4 判 0.208 ms；L1 avg 0.74 帧 / p99 1.27 帧。下一个检查点比 GPU 以 g9 为参照或在静桌面上重跑 |
| `g11-m5max.json` | G11（`make gate4-run GATE4_CHECKPOINT=G11 GATE4_PREVIOUS=baselines/g10-m5max.json GATE4_BASELINE=baselines/g11-m5max.json GATE4_LABEL=g11`） | 同 g4 / g6–g10（收口四路 123–126 合入 + G11 胶水后的树 19616b7；macOS 27.0.1 / Xcode 27.1） | 与 g10 可比但**第 1 次没干净**（桌面活动：V2 7 帧 / V4 设计外 106 / V5 −7；第 2 次 g11b 只剩 V4 设计外 1 帧，基线仍是第 1 次写的；reports/G11.md §5） |
| `g12-m5max.json` | G12（`make gate4-run GATE4_CHECKPOINT=G12 GATE4_PREVIOUS=baselines/g11-m5max.json GATE4_BASELINE=baselines/g12-m5max.json GATE4_LABEL=g12`） | 同 g4 / g6–g11（Codex 修复五路 129–133 合入 + G12 胶水后的树 490dd06；macOS 27.0.1 / Xcode 27.1） | 与 g11 可比：第 1 次 V2 1 帧 / V4 设计外 4（亮度 / 显示代理那一拍）、第 2 次 g12b 自动项全过（V2 0 / V4 设计外 0 / V5 +0）——入库的是 g12b 写的（reports/G12.md §5） |
| `g13-m5max.json` | G13（`make gate4-run GATE4_CHECKPOINT=G13 GATE4_PREVIOUS=baselines/g12-m5max.json GATE4_BASELINE=baselines/g13-m5max.json GATE4_LABEL=g13`） | 同 g4 / g6–g12（续做四路 136–139 合入 + G13 胶水后的树 9049649；macOS 27.0.1 / Xcode 27.2 + Metal 工具链 27.2） | 与 g12 同场景、同机、同大版本可比，第 1 次就干净（V2 0 / V4 设计外 0 / V5 +0 / A4 0.208 ms；V1 avg 2.084 / p99 3.420 ms，p99 比 g12b 高 0.97 ms 仍达目标档；S3 CPU 46.1% / GPU 30.8%；reports/G13.md §5） |
| `g14-m5max.json` | G14（`make gate4-run GATE4_CHECKPOINT=G14 GATE4_PREVIOUS=baselines/g13-m5max.json GATE4_BASELINE=baselines/g14-m5max.json GATE4_LABEL=g14`） | 同 g4 / g6–g13（续做两路 141 / 135 合入后的树 b46b38e——两路不碰包与 App 代码，引擎与 g13 同源；macOS 27.0.1 / Xcode 27.2 + Metal 工具链 27.2） | 与 g13 同场景、同机、同大版本可比，第 1 次就干净（V2 0 / V4 设计外 0 / V5 +0 / A4 0.208 ms；V1 avg 2.009 / p99 2.673 ms = −0.075 / −0.747 ms、V3 p99 0.054 ms、S3 CPU 44.2% / GPU 32.0% = −1.9 / +1.1 pt）；跑的时候两块屏（内建 + LG）都开着、开跑前 fseventsd 刚忙过（负载 3.20）、GPU > 50% 的秒数 0（reports/G14.md §5） |
| `perf-m5max-macos27.json` | W4-A L5（`make perf-baseline`） | scenarios/g4-show.json + g4.json 的前 5 分钟（`--record --iso-audio 4`，不起 API）+ E4 片段（`scripts/perf/make-e4-clip.sh`，sha256 记在 `e4.source_sha256`） | **只与同机、同 macOS 大版本比**（prompt 70 第 7 条）：g4-m5max.json 是 26.6.2 上的，只作参考列；`summary` 段与 G2–G4 同结构，另加 `perf`（V1–V3、S3 的 avg / p95）与 `e4`（VMAF / PSNR-Y / SSIM，分段） |
| `soak8h-<机器>-macos<N>.json`、`soak1h-…` | W4-A L4（`make soak` / `make soak-1h`） | headless `--preset soak`（G4 节目 + 摄像头 + 文件；录制 + 2 路推流 + NDI） | 同标签、同机、同大版本比；存 §7 报告"与上一版本的差"用的几项（V1–V3、S2 斜率、S3、A3），第一次通过时自动写，之后要 `--write-baseline`。**`soak8h-m5max-macos27.json` 2026-10-12 第一次通过时自动写**（树 93bb783，G8b 合入后：S2 2.46 MB/h、S3 30.4% 不含 NDI、A3 0；reports/W4-soak-8h.md） |

### W4-A 的基线规则

- 文件名：`perf-<机器>-macos<大版本>.json`，机器 = 芯片 + Air 标记（`m5max`、`m1air`，`scripts/perf/perfjudge.py` 的 `machine_tag`）。换机器、升 macOS 大版本都会开一个新文件，不和旧的判退步。
- 同系统的第一版只在标准条件下自动写（5 分钟 + E4、机器上没有别的编译 / 测试进程）；已有时只有 `--write-baseline` 才覆盖（§5：每个正式版本的 L5 结果存进仓库）。
- 退步规则在 `scripts/perf/regression.json`（默认照 prompt 70：变坏 > 10% 算退步；E4 另按 §4：VMAF 降 > 1 分）。阈值归用户（铁律 9）。

