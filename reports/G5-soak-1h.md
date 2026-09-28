# W4-A 长稳 g5-1h（make soak-1h）：m5max / macOS 27.0

**判定：✅ 通过**（S1 ✅；S2 参考；S3 ✅；A3 ✅（外推））

生成：2026-09-28 12:28。数据：`.build/soak/g5-1h/`。脚本：scripts/soak/soak.sh → scripts/soak/soak_report.py（判定库 soakjudge.py）。

## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）

| 项 | 值 |
|---|---|
| 提交 | `b767677`（release/0.1，未提交改动 4 个） |
| 机器 | Apple M5 Max · MacBook Pro（Mac17,6）· 18（perflevel0 6 / perflevel1 12） 核 · 128 GB |
| macOS | 27.0（26A428）；Xcode 27.0 Build version 27A266a |
| 起止 | 2026-09-28 11:23:44 → 12:23:44（stats 覆盖 1.00 h；headless 退出码 0） |
| 电源 | 开跑前 AC（电量 90%，适配器 100 W，powermode 2）；逐分钟：AC 61 分钟；整机输入功率 21.2–42.6 W（均值 26.5 W） |
| 温度环境 | thermalState 逐分钟：nominal 61 分钟（开跑前 nominal（ProcessInfo 低电量 0），跑完 nominal）；powermetrics thermal pressure：未采（无 sudo）；pmset：Note: No thermal warning level has been recorded Note: No performance warning level has been recorded Note: No CPU power status has been recorded；室温：未记录（--ambient 可写室温，例如 "约 24 °C，空调房"） |
| 负载 | 开跑前 5.88 4.41 4.04 → 跑完 3.20 2.75 2.72；有编译 / 测试进程在跑的分钟数 0（开跑前 / 跑完：无） |
| 工具 | ffmpeg version 9.0.1（libvmaf yes）；MediaMTX v1.21.0；NDI SDK NDI 2026-04-13 git-5396c5f1 v6.3.2.0 |

## 2. 场景（标准负载，§3 S1 + prompt 70 第 1 条）

- 节目 `.build/soak/g5-1h/soak-show.json`（headless `make-show --preset soak`）：
  - 输入 1：合成 1 · 30 灰 64±24 +音频
  - 输入 2：合成 2 · 60 灰 192±24 +音频(ISO +100 ppm)
  - 输入 3：合成 3 · 59.94 灰 96±24 +音频(ISO -100 ppm)
  - 输入 4：合成 4 · 59.94 灰 128±24 +音频(ISO +50 ppm)
  - 输入 5：合成 5 · 60 灰 144±24 +100 ppm 抠像
  - 输入 6：合成 6 · 60 灰 160±24 -100 ppm 抠像
  - 输入 7：合成 7 · 60 灰 176±24 ±3 ms 抠像
  - 输入 8：合成 8 · 60 灰 208±24 抠像
  - 输入 9：Stinger PNG（带 alpha）
  - 输入 11：文件（e4-source.mov，循环）
- 场景 `.build/soak/g5-1h/soak.json`（`make-scenario --preset soak`）：每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加（1 摄像头 / 2 文件 / 3、4 抠像合成源），PGM 只轮 1–8 号。
- 命令：`Tools/switcher-headless/.build/out/Products/Release/switcher-headless run --show .build/soak/g5-1h/soak-show.json --script .build/soak/g5-1h/soak.json --duration 3600 --stats .build/soak/g5-1h/stats.jsonl --record .build/soak/g5-1h/soak.mov --audio-device null --ndi-send Switcher soak --stream rtmp://127.0.0.1:19350/s1 --stream rtmp://127.0.0.1:19350/s2`
- 输出：encoder[0] = record「录制」；encoder[1] = ndi「NDI 发送（PGM）」；encoder[2] = stream「推流 s1（本地 MediaMTX）」；encoder[3] = stream「推流 s2（本地 MediaMTX）」
- ⚠️ 非交互环境且摄像头授权未定（没人点授权框）：这次不接摄像头
- caffeinate -u -i -d -s -w <headless>；stats.jsonl 每秒一行（3601 行）；每分钟采 RSS / 环境 / MediaMTX；powermetrics 未采。

## 3. 判定（§4；每个指标：数值 · 阈值（必须 / 目标）· 通过 · 与上一版本的差）

| 指标 | 数值 | 必须 | 目标 | 通过 | 与上一版本的差 |
|---|---|---|---|---|---|
| S1 长稳 | 13 个 5 分钟窗口，超阈值 0 个（V2 0、A1 0、E1 0）；退出码 0；崩溃报告 0 份；覆盖 3600 / 3599 s | 1 小时每个窗口 V2 ≤ 0.02%、A1 = 0、E1 = 0，无崩溃（硬性） | 24 小时 | ✅ | — |
| V2 全程 | 0 帧 / 215994 拍（0.0000%） | ≤ 0.02% | 0 | ✅ | —（没有上一版） |
| A1 全程 | 超时 0 + 欠载 0 + 离线不连续 0（frameprobe，click ±1 ms 排除）；流式不连续 0（信息项） | 1 小时 0（硬性） | 0 | ✅ | — |
| E1 全程 | encoder[0] 0，encoder[1] 0，encoder[2] 0，encoder[3] 0（共 0） | 标准负载下 0 | 0 | ✅ | — |
| S2 内存增长 | 86.97 MB/h（预热 30 min 后逐分钟 31 点、拟合 0.50 h，R² 0.351；RSS 998 → 1081 MB，最大 1143）；对照：ps 的 RSS（resident）5.14 MB/h | ≤ 10 MB/h | ≤ 2 MB/h | ⚠️ 参考值已超 10 MB/h（拟合段不足 1 h，不判；8 小时那次判） | —（没有上一版） |
| S3 CPU | avg 54.6% / p95 57.5% / max 63.0%（进程级，100 = 一个核；按线程见 §5（首尾快照跨 0.97 h，各线程之和 44.1%）） | avg ≤ 60% | ≤ 40% | ✅ | —（没有上一版） |
| S3 GPU | avg 29.1% / p95 34.0%（IOKit Device Utilization）；powermetrics 未采（无 sudo） | avg ≤ 50% | ≤ 35% | ✅ 达目标 | —（没有上一版） |
| A3 A/V 漂移 | +0.00 ms（整秒配对 939 对、跨 0.94 h，斜率 0.0000 µs/s；只跑了 0.94 h：斜率 × 8 h 外推） | 8 小时 ≤ 16 ms | ≤ 5 ms | ✅ 达目标 | —（没有上一版） |
| A2（信息项） | 整秒配对最大 0.000 ms、均值 0.000 ms、标准差 0.000 ms | ≤ 16.7 ms | ≤ 5 ms | ✅ | — |
| V1（信息项） | avg 1.752 ms / p99 2.188 ms / max 2.972 ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | ✅ | —（没有上一版） |
| V3（信息项） | p99 0.040 ms / max 0.195 ms | p99 ≤ 4 | p99 ≤ 2 | ✅ | —（没有上一版） |
| V5 / E5（信息项） | 录像 216000 帧 / 期望 216000（差 +0）；视频 3600.000 s、音频 3600.000 s（差 0.0 ms）；ffprobe 解析错误：无 | 1 小时 ≤ 2 帧；轨道差 ≤ 20 ms | 0 | ✅ | — |

## 4. 每 5 分钟窗口（只列超阈值的；全表在 summary.json）

13 个窗口全部满足（V2 最大 0 帧 / 窗口，A1 0，E1 0）。

## 5. 输出与输入

| encoder | 输出 | 帧数 | 丢（网络 / 落盘） | 编码 skipped | 重连 | 状态（秒数） | 平均码率 |
|---|---|---|---|---|---|---|---|
| 0 | record「录制」 | 215995 | 0 | 0 | 0 | recording 3601 | 6.01 Mb/s |
| 1 | ndi「NDI 发送（PGM）」 | 215995 | 0 | 0 | 0 | publishing 3601 | 1990.10 Mb/s |
| 2 | stream「推流 s1（本地 MediaMTX）」 | 216000 | 0 | 0 | 0 | publishing 3601 | 6.17 Mb/s |
| 3 | stream「推流 s2（本地 MediaMTX）」 | 216000 | 0 | 0 | 0 | publishing 3601 | 6.17 Mb/s |

MediaMTX 收到的（每分钟采 API）：s1 平均 6.24 Mb/s，运行中没进字节的分钟 0、未就绪 0 次；s2 平均 6.23 Mb/s，运行中没进字节的分钟 0、未就绪 0 次

| 输入 | 名字 | fps 均值 / 最低 | fps = 0 的秒数 | 重复 dup | 丢弃 drop | L1 最大 |
|---|---|---|---|---|---|---|
| 1 | 合成 1 · 30 灰 64±24 +音频 | 29.99 / 2.98 | 0 | 107997 | 0 | 34.1 ms |
| 2 | 合成 2 · 60 灰 192±24 +音频(ISO +100 ppm) | 59.98 / 5.97 | 0 | 1 | 0 | 34.4 ms |
| 3 | 合成 3 · 59.94 灰 96±24 +音频(ISO -100 ppm) | 59.92 / 5.97 | 0 | 216 | 0 | 39.4 ms |
| 4 | 合成 4 · 59.94 灰 128±24 +音频(ISO +50 ppm) | 59.92 / 5.97 | 0 | 216 | 0 | 39.4 ms |
| 5 | 合成 5 · 60 灰 144±24 +100 ppm 抠像 | 59.99 / 5.97 | 0 | 1 | 22 | 42.7 ms |
| 6 | 合成 6 · 60 灰 160±24 -100 ppm 抠像 | 59.98 / 5.97 | 0 | 22 | 0 | 43.1 ms |
| 7 | 合成 7 · 60 灰 176±24 ±3 ms 抠像 | 59.98 / 5.97 | 0 | 1 | 0 | 34.1 ms |
| 8 | 合成 8 · 60 灰 208±24 抠像 | 59.98 / 5.97 | 0 | 1 | 0 | 34.4 ms |
| 9 | Stinger PNG（带 alpha） | 59.98 / 5.97 | 0 | 0 | 2 | 28.9 ms |
| 11 | 文件（e4-source.mov，循环） | 59.96 / 5.97 | 0 | 98 | 2 | 37.2 ms |

S3 按线程（threads.log 首尾快照 11:24:43 → 12:22:50，每线程 user + system 增量 / 墙钟；同 cpu_pct 的口径，100 = 一个核；按线程名分组，共 46 组，列前 20；无名线程 = VideoToolbox / AVFoundation / NDI SDK / HaishinKit / GCD 的工作线程）：

| 线程（组） | 线程数 | CPU 秒 | 占一个核 % |
|---|---|---|---|
| `ndis:async` | 1 | 673 | 19.3% |
| `（无名：系统 / SDK / GCD 线程）` | 11 | 253 | 7.3% |
| `ndis:lowQ` | 1 | 220 | 6.3% |
| `com.apple.coremedia.mediaprocessor.audiocompression` | 1 | 45 | 1.3% |
| `switcher.stream.audio.stream1` | 1 | 44 | 1.3% |
| `switcher.stream.audio.stream2` | 1 | 44 | 1.3% |
| `switcher.ndisend.Switcher soak` | 1 | 34 | 1.0% |
| `file-decode-11` | 1 | 27 | 0.8% |
| `switcher.program-clock` | 1 | 25 | 0.7% |
| `switcher.audio-pump` | 1 | 17 | 0.5% |
| `com.apple.coremedia.formatwriter.qtmovie` | 1 | 16 | 0.5% |
| `switcher.encoder.stream1.video` | 1 | 15 | 0.4% |
| `switcher.encoder.stream2.video` | 1 | 15 | 0.4% |
| `switcher.encoder.record` | 1 | 14 | 0.4% |
| `switcher.audio-control` | 1 | 13 | 0.4% |
| `file-pace-11` | 1 | 9 | 0.3% |
| `synthetic-video-8` | 1 | 6 | 0.2% |
| `synthetic-video-2` | 1 | 6 | 0.2% |
| `synthetic-video-3` | 1 | 6 | 0.2% |
| `synthetic-video-4` | 1 | 6 | 0.2% |
| **合计** | | | **44.1%** |

## 6. 异常与截取的日志（事件前后 5 分钟，重叠的并段）

没有异常事件。

## 7. 数据存放

- stats：`.build/soak/g5-1h/stats.jsonl`；headless（带墙钟时间戳）：`.build/soak/g5-1h/headless.log`；录像：`.build/soak/g5-1h/soak.mov`
- 每分钟采样：`rss.log`、`env.log`、`mtx.log`，每 5 s：`load.log`；powermetrics：`powermetrics.plist`（没有）；MediaMTX 日志：`mediamtx.log`
- frameprobe：按 5 分钟分段 `probe-seg/seg*.json`（12 段），合并结果 `probe-av-combined.json`；ffprobe：`ffprobe.json`、`ffprobe-errors.txt`
- 崩溃报告：无；Instruments（S2 的 Leaks）：scripts/soak/leaks.sh 单独跑，见 reports/W4-leaks.md

## 8. 已知问题与放行说明

- 停机段（最后一拍之后 8 行，8 s：录制封口、推流排空、音频引擎最后停）不进判定；这段里欠载 +0、超时 +0（信息）。
- powermetrics 没采（没有 sudo）：GPU 按 §3 S3 的正式口径（IOKit）判，频率 / thermal pressure 缺。
- S2 在这次运行里只作参考：预热 30 分钟之后的拟合段不足 1 小时（§3 S2 的判定用 8 小时那次）。
- A3 按整秒配对斜率外推到 8 小时（与 G3 / G4 的 10 分钟外推同口径）；正式值用 8 小时那次。
- 非交互环境且摄像头授权未定（没人点授权框）：这次不接摄像头

