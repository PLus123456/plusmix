# W4-A 长稳 8h（make soak）：m5max / macOS 27.0.1

**判定：✅ 通过**（S1 ✅；S2 ✅；S3 ✅；A3 ✅）

生成：2026-10-12 08:24。数据：`.build/soak/8h/`。脚本：scripts/soak/soak.sh → scripts/soak/soak_report.py（判定库 soakjudge.py）。

## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）

| 项 | 值 |
|---|---|
| 提交 | `93bb783`（g8，未提交改动 2 个） |
| 机器 | Apple M5 Max · MacBook Pro（Mac17,6）· 18（perflevel0 6 / perflevel1 12） 核 · 128 GB |
| macOS | 27.0.1（26A434）；Xcode 27.0 Build version 27A266a |
| 起止 | 2026-10-11 23:48:43 → 07:48:43（stats 覆盖 8.00 h；headless 退出码 0） |
| 电源 | 开跑前 AC（电量 95%，适配器 100 W，powermode 2）；逐分钟：AC 480 分钟；整机输入功率 14.7–36.8 W（均值 18.8 W） |
| 温度环境 | thermalState 逐分钟：nominal 480 分钟（开跑前 nominal（ProcessInfo 低电量 0），跑完 nominal）；powermetrics thermal pressure：{'Nominal': 2874}；pmset：Note: No thermal warning level has been recorded Note: No performance warning level has been recorded Note: No CPU power status has been recorded；室温：未记录（--ambient 可写室温，例如 "约 24 °C，空调房"） |
| 负载 | 开跑前 3.50 2.90 2.37 → 跑完 2.27 2.17 2.27；有编译 / 测试进程在跑的分钟数 0（开跑前 / 跑完：无） |
| 工具 | ffmpeg version 9.0.1（libvmaf no）；MediaMTX v1.21.0；NDI SDK NDI 2026-04-13 git-5396c5f1 v6.3.2.0 |

## 2. 场景（标准负载，§3 S1 + prompt 70 第 1 条）

- 节目 `.build/soak/8h/soak-show.json`（headless `make-show --preset soak`）：
  - 输入 1：合成 1 · 30 灰 64±24 +音频
  - 输入 2：合成 2 · 60 灰 192±24 +音频(ISO +100 ppm)
  - 输入 3：合成 3 · 59.94 灰 96±24 +音频(ISO -100 ppm)
  - 输入 4：合成 4 · 59.94 灰 128±24 +音频(ISO +50 ppm)
  - 输入 5：合成 5 · 60 灰 144±24 +100 ppm 抠像
  - 输入 6：合成 6 · 60 灰 160±24 -100 ppm 抠像
  - 输入 7：合成 7 · 60 灰 176±24 ±3 ms 抠像
  - 输入 8：合成 8 · 60 灰 208±24 抠像
  - 输入 9：Stinger PNG（带 alpha）
  - 输入 10：内置摄像头（MacBook Pro的相机）
  - 输入 11：文件（e4-source.mov，循环）
- 场景 `.build/soak/8h/soak.json`（`make-scenario --preset soak`）：每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加（1 摄像头 / 2 文件 / 3、4 抠像合成源），PGM 只轮 1–8 号。
- 命令：`Tools/switcher-headless/.build/out/Products/Release/switcher-headless run --show .build/soak/8h/soak-show.json --script .build/soak/8h/soak.json --duration 28800 --stats .build/soak/8h/stats.jsonl --record .build/soak/8h/soak.mov --audio-device null --ndi-send Switcher soak --stream rtmp://127.0.0.1:19350/s1 --stream rtmp://127.0.0.1:19350/s2`
- 输出：encoder[0] = record「录制」；encoder[1] = ndi「NDI 发送（PGM）」；encoder[2] = stream「推流 s1（本地 MediaMTX）」；encoder[3] = stream「推流 s2（本地 MediaMTX）」
- caffeinate -u -i -d -s -w <headless>；stats.jsonl 每秒一行（28801 行）；每分钟采 RSS / 环境 / MediaMTX；powermetrics 每 10 s 一样，2874 样。

## 3. 判定（§4；每个指标：数值 · 阈值（必须 / 目标）· 通过 · 与上一版本的差）

| 指标 | 数值 | 必须 | 目标 | 通过 | 与上一版本的差 |
|---|---|---|---|---|---|
| S1 长稳 | 97 个 5 分钟窗口，超阈值 0 个（V2 0、A1 0、E1 0）；退出码 0；崩溃报告 0 份；覆盖 28800 / 28799 s | 8 小时每个窗口 V2 ≤ 0.02%、A1 = 0、E1 = 0，无崩溃（硬性） | 24 小时 | ✅ | — |
| V2 全程 | 0 帧 / 1727993 拍（0.0000%） | ≤ 0.02% | 0 | ✅ | —（没有上一版） |
| A1 全程 | 超时 0 + 欠载 0 + 离线不连续 0（frameprobe，click ±1 ms 排除）；流式不连续 0（信息项） | 8 小时 0（硬性） | 0 | ✅ | — |
| E1 全程 | encoder[0] 0，encoder[1] 0，encoder[2] 0，encoder[3] 0（共 0） | 标准负载下 0 | 0 | ✅ | — |
| S2 内存增长 | 2.46 MB/h（预热 30 min 后逐分钟 451 点、拟合 7.50 h，R² 0.196；RSS 1043 → 1166 MB，最大 1282）；对照：ps 的 RSS（resident）2.21 MB/h | ≤ 10 MB/h | ≤ 2 MB/h | ✅ | —（没有上一版） |
| S3 CPU（判定口径：不含 NDI SDK 线程（扣掉 ndis:* 26.5 个百分点）） | avg 30.4% | avg ≤ 60% | ≤ 40% | ✅ 达目标 | — |
| S3 CPU（含 NDI SDK 线程的整进程值，信息项） | avg 56.9% / p95 58.7% / max 98.9%（进程级，100 = 一个核；按线程见 §5（首尾快照跨 7.98 h，各线程之和 43.8%）） | avg ≤ 60% | ≤ 40% | 信息 达目标 | —（没有上一版） |
| S3 GPU | avg 26.4% / p95 28.0%（IOKit Device Utilization）；powermetrics GPU avg 48.4% / p95 64.2%，GPU 频率均值 340 MHz（最低 338） | avg ≤ 50% | ≤ 35% | ✅ 达目标 | —（没有上一版） |
| S3 按核（整机、含别的进程；powermetrics 每核 1 − idle − down；信息项） | 18 核合计忙碌 1.74 个核；任一时刻最忙的核均值 25% / p95 27%；P0-Cluster 6 核合计忙 0.45 核、均频 1262 MHz；P1-Cluster 6 核合计忙 0.42 核、均频 1244 MHz；S-Cluster 6 核合计忙 0.87 核、均频 3264 MHz（每核见 §5） | — | — | 信息 | — |
| A3 A/V 漂移 | +0.00 ms（整秒配对 12975 对、跨 7.94 h，斜率 0.0000 µs/s） | 8 小时 ≤ 16 ms | ≤ 5 ms | ✅ 达目标 | —（没有上一版） |
| A2（信息项） | 整秒配对最大 0.000 ms、均值 0.000 ms、标准差 0.000 ms | ≤ 16.7 ms | ≤ 5 ms | ✅ | — |
| V1（信息项） | avg 1.931 ms / p99 2.303 ms / max 2.537 ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | ✅ | —（没有上一版） |
| V3（信息项） | p99 0.032 ms / max 0.148 ms | p99 ≤ 4 | p99 ≤ 2 | ✅ | —（没有上一版） |
| V5 / E5（信息项） | 录像 1728000 帧 / 期望 1728000（差 +0）；视频 28800.000 s、音频 28800.000 s（差 0.0 ms）；ffprobe 解析错误：无 | 1 小时 ≤ 2 帧；轨道差 ≤ 20 ms | 0 | ✅ | — |

## 4. 每 5 分钟窗口（只列超阈值的；全表在 summary.json）

97 个窗口全部满足（V2 最大 0 帧 / 窗口，A1 0，E1 0）。

## 5. 输出与输入

| encoder | 输出 | 帧数 | 丢（网络 / 落盘） | 编码 skipped | 重连 | 状态（秒数） | 平均码率 |
|---|---|---|---|---|---|---|---|
| 0 | record「录制」 | 1727994 | 0 | 0 | 0 | recording 28801 | 5.86 Mb/s |
| 1 | ndi「NDI 发送（PGM）」 | 1727993 | 0 | 0 | 0 | publishing 28801 | 1990.63 Mb/s |
| 2 | stream「推流 s1（本地 MediaMTX）」 | 1728000 | 0 | 0 | 0 | publishing 28801 | 6.02 Mb/s |
| 3 | stream「推流 s2（本地 MediaMTX）」 | 1728000 | 0 | 0 | 0 | publishing 28801 | 6.02 Mb/s |

MediaMTX 收到的（每分钟采 API）：s1 平均 6.09 Mb/s，运行中没进字节的分钟 0、未就绪 0 次；s2 平均 6.09 Mb/s，运行中没进字节的分钟 0、未就绪 0 次

| 输入 | 名字 | fps 均值 / 最低 | fps = 0 的秒数 | 重复 dup | 丢弃 drop | L1 最大（已扣 video_delay_ms） |
|---|---|---|---|---|---|---|
| 1 | 合成 1 · 30 灰 64±24 +音频 | 30.00 / 4.00 | 0 | 863997 | 0 | 25.8 ms |
| 2 | 合成 2 · 60 灰 192±24 +音频(ISO +100 ppm) | 60.00 / 7.00 | 0 | 1 | 0 | 28.3 ms |
| 3 | 合成 3 · 59.94 灰 96±24 +音频(ISO -100 ppm) | 59.94 / 7.00 | 0 | 1726 | 0 | 28.8 ms |
| 4 | 合成 4 · 59.94 灰 128±24 +音频(ISO +50 ppm) | 59.94 / 7.00 | 0 | 1726 | 0 | 28.8 ms |
| 5 | 合成 5 · 60 灰 144±24 +100 ppm 抠像 | 60.00 / 7.00 | 0 | 3 | 176 | 28.7 ms |
| 6 | 合成 6 · 60 灰 160±24 -100 ppm 抠像 | 59.99 / 7.00 | 0 | 173 | 0 | 28.1 ms |
| 7 | 合成 7 · 60 灰 176±24 ±3 ms 抠像 | 60.00 / 7.00 | 0 | 1 | 0 | 30.8 ms |
| 8 | 合成 8 · 60 灰 208±24 抠像 | 60.00 / 7.00 | 0 | 1 | 0 | 28.3 ms |
| 9 | Stinger PNG（带 alpha） | 60.00 / 7.00 | 0 | 0 | 2 | 18.8 ms |
| 10 | 内置摄像头（MacBook Pro的相机） | 30.00 / 5.00 | 0 | 864092 | 0 | 39.1 ms |
| 11 | 文件（e4-source.mov，循环） | 60.00 / 7.00 | 0 | 0 | 4 | 27.1 ms |

S3 按线程（threads.log 首尾快照 23:49:42 → 07:48:38，每线程 user + system 增量 / 墙钟；同 cpu_pct 的口径，100 = 一个核；按线程名分组，共 48 组，列前 20；无名线程 = VideoToolbox / AVFoundation / NDI SDK / HaishinKit / GCD 的工作线程）：

| 线程（组） | 线程数 | CPU 秒 | 占一个核 % |
|---|---|---|---|
| `ndis:async` | 1 | 5750 | 20.0% |
| `（无名：系统 / SDK / GCD 线程）` | 13 | 2084 | 7.3% |
| `ndis:lowQ` | 1 | 1868 | 6.5% |
| `switcher.stream.audio.stream1` | 1 | 357 | 1.2% |
| `switcher.stream.audio.stream2` | 1 | 352 | 1.2% |
| `switcher.ndisend.Switcher soak` | 1 | 270 | 0.9% |
| `switcher.program-clock` | 1 | 230 | 0.8% |
| `com.apple.coremedia.mediaprocessor.audiocompression` | 1 | 222 | 0.8% |
| `file-decode-11` | 1 | 186 | 0.6% |
| `switcher.audio-pump` | 1 | 118 | 0.4% |
| `switcher.encoder.stream2.video` | 1 | 104 | 0.4% |
| `switcher.encoder.stream1.video` | 1 | 104 | 0.4% |
| `switcher.encoder.record` | 1 | 101 | 0.4% |
| `com.apple.coremedia.formatwriter.qtmovie` | 1 | 92 | 0.3% |
| `switcher.audio-control` | 1 | 88 | 0.3% |
| `file-pace-11` | 1 | 74 | 0.3% |
| `synthetic-video-8` | 1 | 52 | 0.2% |
| `synthetic-video-2` | 1 | 51 | 0.2% |
| `synthetic-video-4` | 1 | 47 | 0.2% |
| `synthetic-video-3` | 1 | 47 | 0.2% |
| **合计** | | | **43.8%** |

S3 按核（powermetrics 每个核的忙时比 = 1 − idle − down，整机口径、含别的进程；进程的 cpu_pct 是各线程之和、按上面的线程表分摊在这些核上）：

| 核 | 簇 | 忙时比均值 | p95 | 平均频率 |
|---|---|---|---|---|
| cpu0 | P0-Cluster | 13.5% | 26.5% | 1277 MHz |
| cpu1 | P0-Cluster | 10.6% | 21.3% | 1265 MHz |
| cpu2 | P0-Cluster | 8.1% | 16.2% | 1258 MHz |
| cpu3 | P0-Cluster | 5.8% | 11.8% | 1256 MHz |
| cpu4 | P0-Cluster | 4.1% | 8.3% | 1257 MHz |
| cpu5 | P0-Cluster | 2.9% | 6.1% | 1257 MHz |
| cpu6 | P1-Cluster | 12.4% | 26.0% | 1255 MHz |
| cpu7 | P1-Cluster | 9.9% | 21.0% | 1248 MHz |
| cpu8 | P1-Cluster | 7.6% | 15.9% | 1242 MHz |
| cpu9 | P1-Cluster | 5.5% | 11.6% | 1238 MHz |
| cpu10 | P1-Cluster | 3.8% | 8.1% | 1239 MHz |
| cpu11 | P1-Cluster | 2.6% | 5.7% | 1241 MHz |
| cpu12 | S-Cluster | 24.8% | 25.7% | 3207 MHz |
| cpu13 | S-Cluster | 21.5% | 22.7% | 3240 MHz |
| cpu14 | S-Cluster | 17.8% | 18.8% | 3252 MHz |
| cpu15 | S-Cluster | 11.4% | 12.3% | 3269 MHz |
| cpu16 | S-Cluster | 7.7% | 8.5% | 3285 MHz |
| cpu17 | S-Cluster | 3.9% | 4.6% | 3333 MHz |

## 6. 异常与截取的日志（事件前后 5 分钟，重叠的并段）

没有异常事件。

## 7. 数据存放

- stats：`.build/soak/8h/stats.jsonl`；headless（带墙钟时间戳）：`.build/soak/8h/headless.log`；录像：`.build/soak/8h/soak.mov`
- 每分钟采样：`rss.log`、`env.log`、`mtx.log`，每 5 s：`load.log`；powermetrics：`powermetrics.plist`；MediaMTX 日志：`mediamtx.log`
- frameprobe：按 5 分钟分段 `probe-seg/seg*.json`（96 段），合并结果 `probe-av-combined.json`；ffprobe：`ffprobe.json`、`ffprobe-errors.txt`
- 崩溃报告：无；Instruments（S2 的 Leaks）：scripts/soak/leaks.sh 单独跑，见 reports/W4-leaks.md

## 8. 已知问题与放行说明

- 停机段（最后一拍之后 8 行，8 s：录制封口、推流排空、音频引擎最后停）不进判定；这段里欠载 +0、超时 +0（信息）。

