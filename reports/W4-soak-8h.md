# W4-A 长稳 8h（make soak）：m5max / macOS 27.0

**判定：❌ 未通过**（S1 ✅；S2 ❌；S3 ❌（CPU）；A3 ✅）

生成：2026-09-28 08:52。数据：`.build/soak/8h/`。脚本：scripts/soak/soak.sh → scripts/soak/soak_report.py（判定库 soakjudge.py）。

## 1. 版本 / 机器 / 环境（§7 报告头、§2.8）

| 项 | 值 |
|---|---|
| 提交 | `a3f7165`（claude/w4-soak-baseline-56b8ec，未提交改动 0 个） |
| 机器 | Apple M5 Max · MacBook Pro（Mac17,6）· 18（perflevel0 6 / perflevel1 12） 核 · 128 GB |
| macOS | 27.0（26A428）；Xcode 27.0 Build version 27A266a |
| 起止 | 2026-09-27 23:31:24 → 07:31:24（stats 覆盖 8.00 h；headless 退出码 0） |
| 电源 | 开跑前 AC（电量 90%，适配器 100 W，powermode 2）；逐分钟：AC 480 分钟；整机输入功率 5.6–20.1 W（均值 17.9 W） |
| 温度环境 | thermalState 逐分钟：nominal 480 分钟（开跑前 nominal（ProcessInfo 低电量 0），跑完 nominal）；powermetrics thermal pressure：{'Nominal': 2875}；pmset：Note: No thermal warning level has been recorded Note: No performance warning level has been recorded Note: No CPU power status has been recorded；室温：约 NN °C |
| 负载 | 开跑前 1.19 1.29 1.55 → 跑完 2.81 2.31 2.11；有编译 / 测试进程在跑的分钟数 0（开跑前 / 跑完：无） |
| 工具 | ffmpeg version 9.0.1（libvmaf yes）；MediaMTX v1.21.0；NDI SDK NDI 2026-04-13 git-5396c5f1 v6.3.2.0 |

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
- caffeinate -u -i -d -s -w <headless>；stats.jsonl 每秒一行（28801 行）；每分钟采 RSS / 环境 / MediaMTX；powermetrics 每 10 s 一样，2875 样。

## 3. 判定（§4；每个指标：数值 · 阈值（必须 / 目标）· 通过 · 与上一版本的差）

| 指标 | 数值 | 必须 | 目标 | 通过 | 与上一版本的差 |
|---|---|---|---|---|---|
| S1 长稳 | 97 个 5 分钟窗口，超阈值 0 个（V2 0、A1 0、E1 0）；退出码 0；崩溃报告 0 份；覆盖 28800 / 28799 s | 8 小时每个窗口 V2 ≤ 0.02%、A1 = 0、E1 = 0，无崩溃（硬性） | 24 小时 | ✅ | — |
| V2 全程 | 0 帧 / 1727995 拍（0.0000%） | ≤ 0.02% | 0 | ✅ | —（没有上一版） |
| A1 全程 | 超时 0 + 欠载 0 + 离线不连续 0（frameprobe，click ±1 ms 排除）；流式不连续 0（信息项） | 8 小时 0（硬性） | 0 | ✅ | — |
| E1 全程 | encoder[0] 0，encoder[1] 0，encoder[2] 0，encoder[3] 0（共 0） | 标准负载下 0 | 0 | ✅ | — |
| S2 内存增长 | 60.82 MB/h（预热 30 min 后逐分钟 451 点、拟合 7.50 h，R² 0.955；RSS 995 → 1617 MB，最大 1680）；对照：ps 的 RSS（resident）62.23 MB/h | ≤ 10 MB/h | ≤ 2 MB/h | ❌ | —（没有上一版） |
| S3 CPU | avg 60.1% / p95 62.7% / max 74.9%（进程级，100 = 一个核；没有 threads.log，不按线程归因） | avg ≤ 60% | ≤ 40% | ❌ | —（没有上一版） |
| S3 GPU | avg 25.8% / p95 28.0%（IOKit Device Utilization）；powermetrics GPU avg 49.7% / p95 64.8%，GPU 频率均值 340 MHz（最低 338） | avg ≤ 50% | ≤ 35% | ✅ 达目标 | —（没有上一版） |
| A3 A/V 漂移 | +0.00 ms（整秒配对 13499 对、跨 7.94 h，斜率 0.0000 µs/s） | 8 小时 ≤ 16 ms | ≤ 5 ms | ✅ 达目标 | —（没有上一版） |
| A2（信息项） | 整秒配对最大 0.000 ms、均值 0.000 ms、标准差 0.000 ms | ≤ 16.7 ms | ≤ 5 ms | ✅ | — |
| V1（信息项） | avg 1.944 ms / p99 2.313 ms / max 2.774 ms | avg ≤ 6, p99 ≤ 12 | avg ≤ 4, p99 ≤ 8 | ✅ | —（没有上一版） |
| V3（信息项） | p99 0.032 ms / max 0.144 ms | p99 ≤ 4 | p99 ≤ 2 | ✅ | —（没有上一版） |
| V5 / E5（信息项） | 录像 1728000 帧 / 期望 1728000（差 +0）；视频 28800.000 s、音频 28800.000 s（差 0.0 ms）；ffprobe 解析错误：无 | 1 小时 ≤ 2 帧；轨道差 ≤ 20 ms | 0 | ✅ | — |

## 4. 每 5 分钟窗口（只列超阈值的；全表在 summary.json）

97 个窗口全部满足（V2 最大 0 帧 / 窗口，A1 0，E1 0）。

## 5. 输出与输入

| encoder | 输出 | 帧数 | 丢（网络 / 落盘） | 编码 skipped | 重连 | 状态（秒数） | 平均码率 |
|---|---|---|---|---|---|---|---|
| 0 | record「录制」 | 1727995 | 0 | 0 | 0 | recording 28801 | 5.92 Mb/s |
| 1 | ndi「NDI 发送（PGM）」 | 1727995 | 0 | 0 | 0 | publishing 28801 | 1990.56 Mb/s |
| 2 | stream「推流 s1（本地 MediaMTX）」 | 1728000 | 0 | 0 | 0 | publishing 28801 | 6.08 Mb/s |
| 3 | stream「推流 s2（本地 MediaMTX）」 | 1728000 | 0 | 0 | 0 | publishing 28801 | 6.08 Mb/s |

MediaMTX 收到的（每分钟采 API）：s1 平均 6.15 Mb/s，运行中没进字节的分钟 0、未就绪 0 次；s2 平均 6.15 Mb/s，运行中没进字节的分钟 0、未就绪 0 次

| 输入 | 名字 | fps 均值 / 最低 | fps = 0 的秒数 | 重复 dup | 丢弃 drop | L1 最大 |
|---|---|---|---|---|---|---|
| 1 | 合成 1 · 30 灰 64±24 +音频 | 30.00 / 2.99 | 0 | 863998 | 0 | 26.8 ms |
| 2 | 合成 2 · 60 灰 192±24 +音频(ISO +100 ppm) | 60.00 / 5.97 | 0 | 1 | 0 | 27.7 ms |
| 3 | 合成 3 · 59.94 灰 96±24 +音频(ISO -100 ppm) | 59.94 / 5.97 | 0 | 1726 | 0 | 21.5 ms |
| 4 | 合成 4 · 59.94 灰 128±24 +音频(ISO +50 ppm) | 59.94 / 5.97 | 0 | 1726 | 0 | 21.4 ms |
| 5 | 合成 5 · 60 灰 144±24 +100 ppm 抠像 | 60.00 / 5.97 | 0 | 1 | 174 | 25.5 ms |
| 6 | 合成 6 · 60 灰 160±24 -100 ppm 抠像 | 59.99 / 5.97 | 0 | 173 | 0 | 28.6 ms |
| 7 | 合成 7 · 60 灰 176±24 ±3 ms 抠像 | 60.00 / 5.97 | 0 | 1 | 0 | 30.4 ms |
| 8 | 合成 8 · 60 灰 208±24 抠像 | 60.00 / 5.97 | 0 | 1 | 0 | 27.8 ms |
| 9 | Stinger PNG（带 alpha） | 60.00 / 5.97 | 0 | 0 | 2 | 7.8 ms |
| 10 | 内置摄像头（MacBook Pro的相机） | 30.00 / 0.00 | 1 | 864082 | 1 | 45.3 ms |
| 11 | 文件（e4-source.mov，循环） | 59.97 / 5.97 | 0 | 764 | 2 | 16.2 ms |

## 6. 异常与截取的日志（事件前后 5 分钟，重叠的并段）

没有异常事件。

## 7. 数据存放

- stats：`.build/soak/8h/stats.jsonl`；headless（带墙钟时间戳）：`.build/soak/8h/headless.log`；录像：`.build/soak/8h/soak.mov`
- 每分钟采样：`rss.log`、`env.log`、`mtx.log`，每 5 s：`load.log`；powermetrics：`powermetrics.plist`；MediaMTX 日志：`mediamtx.log`
- frameprobe：按 5 分钟分段 `probe-seg/seg*.json`（96 段），合并结果 `probe-av-combined.json`；ffprobe：`ffprobe.json`、`ffprobe-errors.txt`
- 崩溃报告：无；Instruments（S2 的 Leaks）：scripts/soak/leaks.sh 单独跑，见 reports/W4-leaks.md

## 8. 已知问题与放行说明

- 停机段（最后一拍之后 8 行，8 s：录制封口、推流排空、音频引擎最后停）不进判定；这段里欠载 +0、超时 +0（信息）。
- S3 没按线程归因：没有 threads.log（这次运行的 soak.sh 还没有每分钟的 thread-cpu 快照，或 scripts/soak/thread-cpu.swift 没编译成功）。

