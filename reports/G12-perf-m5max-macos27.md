# W4-A L5 性能基线：m5max / macOS 27.0.1（make perf-baseline，g12）

**判定：✅ 无退步**

生成：2026-10-31 13:38。数据：`.build/perf/g12/`（stats.jsonl、headless.log、load.log、powermetrics.plist、e4/）。脚本：scripts/perf/perf-baseline.sh → scripts/perf/perf_report.py。

## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）

| 项 | 值 |
|---|---|
| 提交 | `73eadfd`（g12，未提交改动 3 个） |
| 机器 | Apple M5 Max · MacBook Pro（Mac17,6）· 18（perflevel0 6 / perflevel1 12） 核 · 128 GB |
| macOS | 27.0.1（26A434）；Xcode 27.1 Build version 27A9275；swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) |
| 电源 | AC（电量 95%，适配器 100 W）；powermode 2（0 自动 / 1 低电量 / 2 高性能） |
| 温度环境 | thermalState 开跑前 nominal（ProcessInfo 低电量 0） / 跑完 nominal；Note: No thermal warning level has been recorded Note: No performance warning level has been recorded Note: No CPU power status has been recorded；powermetrics thermal pressure 未采（无 sudo）；室温 未记录（--ambient 可写室温，例如 "约 24 °C，空调房"） |
| 负载 | 开跑前 2.99 2.69 2.44 → 跑完 1.63 1.98 2.17；占 CPU 前几名：4.7%coreaudiod; 3.5%Claude; 1.4%Claude; 1.1%searchpartyd; 1.0%syspolicyd;  |
| 在跑的编译 / 测试进程 | 无 |
| 工具 | ffmpeg version 9.0.1（libvmaf yes）；MediaMTX v1.21.0；NDI SDK NDI 2026-04-13 git-5396c5f1 v6.3.2.0 |

## 2. 场景

- V1–V3 / S3：`scenarios/g4-show.json` + `scenarios/g4.json` 的前 5 分钟（300 行 stats，17939 拍），`--record --iso-audio 4 --audio-device null`，不起 API；caffeinate -u -i -d -s 包住 headless。
- E4：`scripts/perf/make-e4-clip.sh` 的片段（1800 帧 1080p60 ProRes 422 HQ，sha256 `1832603ae085ab3a`，ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers；段：static 0–599、slow 600–1199、high 1200–1799） → headless 文件输入（`--preset perf-e4`）→ H.264 6 Mb/s 录制 → 录像第 0 帧对源第 0 帧 → libvmaf vmaf_v0.6.1（另出 PSNR-Y / SSIM）。

## 3. 判定（§4 必须档 / 目标档）

| 指标 | 数值 | 必须 | 目标 | 通过 |
|---|---|---|---|---|
| V1 渲染耗时 | avg 2.039 ms / p99 2.485 ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | ✅ 达目标 |
| V2 渲染滞后丢帧 | 0 帧 / 17939 拍（0.0000%） | ≤ 0.0200% | 0 | ✅ 达目标 |
| V3 抖动 | p99 0.052 ms / max 0.061 ms | p99 ≤ 4 | p99 ≤ 2 | ✅ 达目标 |
| S3 CPU（进程，100 = 一个核） | avg 47.3% / p95 53.8% | avg ≤ 60% | avg ≤ 40% | ✅ |
| S3 GPU（IOKit Device Utilization） | avg 27.1% / p95 30.0% | avg ≤ 50% | avg ≤ 35% | ✅ 达目标 |
| S3 GPU（powermetrics，对照） | 未采：没有 sudo | — | — | — |
| E4 编码画质 | VMAF 均值 91.00（调和 90.76，5% 分位 82.92，最低 69.73）；PSNR-Y 39.75 dB；SSIM 0.9913；分段：static 93.22（最低 81.96，PSNR-Y 42.44 dB）；slow 93.62（最低 91.83，PSNR-Y 41.81 dB）；high 86.15（最低 69.73，PSNR-Y 34.99 dB）；编码 skipped 0、missed_render 0 | 相对上一版本 VMAF 不降 > 1 分；绝对值按片源标定写入基线 | 不降 | ✅ |

## 4. 与同系统上一版基线比（L5：退步 > 10% 非零退出；E4 另按 VMAF 降 > 1 分）

上一版：`baselines/perf-m5max-macos27.json`（提交 af2414f，2026-09-27T11:29:17Z，macOS 27.0）。

| 指标 | 本次 | 上一版 | 差 | 退步 | 说明 |
|---|---|---|---|---|---|
| V1 渲染耗时 avg | 2.039 ms | 1.980 ms | +3.0% | ✅ |  |
| V1 渲染耗时 p99 | 2.485 ms | 2.497 ms | -0.5% | ✅ |  |
| V2 渲染滞后丢帧比例 | 0.0000% | 0.0000% | — | ✅ | 基线为 0，比例算不出，按必须档（≤ 0.0200%）判 |
| V3 抖动 p99 | 0.052 ms | 0.047 ms | +10.1% | ✅ | 变坏 10.1% > 10%（绝对变坏 0.004791 ≤ 下限 0.1，不算退步：regression.json） |
| S3 CPU avg | 47.3% | 49.1% | -3.7% | ✅ |  |
| S3 CPU p95 | 53.8% | 55.6% | -3.1% | ✅ |  |
| S3 GPU avg（IOKit） | 27.1% | 30.2% | -10.1% | ✅ |  |
| S3 GPU p95（IOKit） | 30.0% | 32.0% | -6.2% | ✅ |  |
| E4 VMAF 均值 | 90.996 | 91.003 | -0.0% | ✅ |  |
| E4 PSNR-Y | 39.75 dB | 39.75 dB | -0.0% | ✅ |  |

## 5. 参考：`baselines/g4-m5max.json`（G4，macOS 26.6.2，scenarios/g4.json 10 分钟、带 API 客户端；不同系统 / 不同时长，只列不判）

| 量 | 本次 | 参考 |
|---|---|---|
| V1 avg / p99 | 2.039 / 2.485 ms | 2.149 / 2.644 ms |
| V3 p99 / max | 0.052 / 0.061 ms | 0.091 / 0.121 ms |
| CPU avg | 47.3% | 50.7% |
| GPU avg | 27.1% | 30.5% |
| V2 | 0 | 0 |

## 6. 数据存放

- stats：`.build/perf/g12/stats.jsonl`（300 行）；headless：`.build/perf/g12/headless.log`；负载：`.build/perf/g12/load.log`；录制：`.build/perf/g12/perf.mov`
- powermetrics：`.build/perf/g12/powermetrics.plist`（没有）
- E4：`.build/perf/g12/e4/`（e4.mov、vmaf.json、rec-yavg.txt / src-yavg.txt、alignment.txt）；源片段 `.build/perf/e4/e4-source.mov`

## 7. 已知问题与放行说明

- GPU 的 powermetrics 对照没采（没有 sudo）；GPU 按 §3 S3 的正式口径（IOKit）判。

