# W4-A L5 性能基线：m5max / macOS 27.0（make perf-baseline，g7）

**判定：❌ 退步：S3 CPU p95；退步：S3 GPU avg（IOKit）；退步：S3 GPU p95（IOKit）**

生成：2026-10-04 04:28。数据：`.build/perf/g7/`（stats.jsonl、headless.log、load.log、powermetrics.plist、e4/）。脚本：scripts/perf/perf-baseline.sh → scripts/perf/perf_report.py。

## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）

| 项 | 值 |
|---|---|
| 提交 | `0137ec9`（g7，未提交改动 17 个） |
| 机器 | Apple M5 Max · MacBook Pro（Mac17,6）· 18（perflevel0 6 / perflevel1 12） 核 · 128 GB |
| macOS | 27.0（26A428）；Xcode 27.0 Build version 27A266a；swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) |
| 电源 | AC（电量 95%，适配器 100 W）；powermode 2（0 自动 / 1 低电量 / 2 高性能） |
| 温度环境 | thermalState 开跑前 nominal（ProcessInfo 低电量 0） / 跑完 nominal；Note: No thermal warning level has been recorded Note: No performance warning level has been recorded Note: No CPU power status has been recorded；powermetrics thermal pressure 未采（无 sudo）；室温 未记录（--ambient 可写室温，例如 "约 24 °C，空调房"） |
| 负载 | 开跑前 4.45 5.11 4.84 → 跑完 3.82 4.62 4.71；占 CPU 前几名：103.1%dasd; 34.2%WindowServer; 28.6%launchd; 21.4%PerfPowerServices; 11.3%appstoreagent;  |
| 在跑的编译 / 测试进程 | 无 |
| 工具 | ffmpeg version 9.0.1（libvmaf yes）；MediaMTX v1.21.0；NDI SDK NDI 2026-04-13 git-5396c5f1 v6.3.2.0 |

## 2. 场景

- V1–V3 / S3：`scenarios/g4-show.json` + `scenarios/g4.json` 的前 5 分钟（300 行 stats，17940 拍），`--record --iso-audio 4 --audio-device null`，不起 API；caffeinate -u -i -d -s 包住 headless。
- E4：`scripts/perf/make-e4-clip.sh` 的片段（1800 帧 1080p60 ProRes 422 HQ，sha256 `1832603ae085ab3a`，ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers；段：static 0–599、slow 600–1199、high 1200–1799） → headless 文件输入（`--preset perf-e4`）→ H.264 6 Mb/s 录制 → 录像第 0 帧对源第 0 帧 → libvmaf vmaf_v0.6.1（另出 PSNR-Y / SSIM）。

## 3. 判定（§4 必须档 / 目标档）

| 指标 | 数值 | 必须 | 目标 | 通过 |
|---|---|---|---|---|
| V1 渲染耗时 | avg 1.685 ms / p99 2.047 ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | ✅ 达目标 |
| V2 渲染滞后丢帧 | 0 帧 / 17940 拍（0.0000%） | ≤ 0.0200% | 0 | ✅ 达目标 |
| V3 抖动 | p99 0.030 ms / max 0.071 ms | p99 ≤ 4 | p99 ≤ 2 | ✅ 达目标 |
| S3 CPU（进程，100 = 一个核） | avg 53.4% / p95 62.6% | avg ≤ 60% | avg ≤ 40% | ✅ |
| S3 GPU（IOKit Device Utilization） | avg 41.9% / p95 45.0% | avg ≤ 50% | avg ≤ 35% | ✅ |
| S3 GPU（powermetrics，对照） | 未采：没有 sudo | — | — | — |
| E4 编码画质 | VMAF 均值 91.01（调和 90.78，5% 分位 83.11，最低 69.73）；PSNR-Y 39.75 dB；SSIM 0.9913；分段：static 93.22（最低 81.96，PSNR-Y 42.44 dB）；slow 93.62（最低 91.83，PSNR-Y 41.82 dB）；high 86.20（最低 69.73，PSNR-Y 34.99 dB）；编码 skipped 0、missed_render 0 | 相对上一版本 VMAF 不降 > 1 分；绝对值按片源标定写入基线 | 不降 | ✅ |

## 4. 与同系统上一版基线比（L5：退步 > 10% 非零退出；E4 另按 VMAF 降 > 1 分）

上一版：`baselines/perf-m5max-macos27.json`（提交 af2414f，2026-09-27T11:29:17Z，macOS 27.0）。

| 指标 | 本次 | 上一版 | 差 | 退步 | 说明 |
|---|---|---|---|---|---|
| V1 渲染耗时 avg | 1.685 ms | 1.980 ms | -14.9% | ✅ |  |
| V1 渲染耗时 p99 | 2.047 ms | 2.497 ms | -18.0% | ✅ |  |
| V2 渲染滞后丢帧比例 | 0.0000% | 0.0000% | — | ✅ | 基线为 0，比例算不出，按必须档（≤ 0.0200%）判 |
| V3 抖动 p99 | 0.030 ms | 0.047 ms | -36.8% | ✅ |  |
| S3 CPU avg | 53.4% | 49.1% | +8.9% | ✅ |  |
| S3 CPU p95 | 62.6% | 55.6% | +12.6% | ❌ | 变坏 12.6% > 10% |
| S3 GPU avg（IOKit） | 41.9% | 30.2% | +38.9% | ❌ | 变坏 38.9% > 10% |
| S3 GPU p95（IOKit） | 45.0% | 32.0% | +40.6% | ❌ | 变坏 40.6% > 10% |
| E4 VMAF 均值 | 91.014 | 91.003 | +0.0% | ✅ |  |
| E4 PSNR-Y | 39.75 dB | 39.75 dB | +0.0% | ✅ |  |

## 5. 参考：`baselines/g4-m5max.json`（G4，macOS 26.6.2，scenarios/g4.json 10 分钟、带 API 客户端；不同系统 / 不同时长，只列不判）

| 量 | 本次 | 参考 |
|---|---|---|
| V1 avg / p99 | 1.685 / 2.047 ms | 2.149 / 2.644 ms |
| V3 p99 / max | 0.030 / 0.071 ms | 0.091 / 0.121 ms |
| CPU avg | 53.4% | 50.7% |
| GPU avg | 41.9% | 30.5% |
| V2 | 0 | 0 |

## 6. 数据存放

- stats：`.build/perf/g7/stats.jsonl`（300 行）；headless：`.build/perf/g7/headless.log`；负载：`.build/perf/g7/load.log`；录制：`.build/perf/g7/perf.mov`
- powermetrics：`.build/perf/g7/powermetrics.plist`（没有）
- E4：`.build/perf/g7/e4/`（e4.mov、vmaf.json、rec-yavg.txt / src-yavg.txt、alignment.txt）；源片段 `.build/perf/e4/e4-source.mov`

## 7. 已知问题与放行说明

- GPU 的 powermetrics 对照没采（没有 sudo）；GPU 按 §3 S3 的正式口径（IOKit）判。

