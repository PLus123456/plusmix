# W4-A 长稳与性能基线 —— 报告（分支 w4-soak）

日期 2026-09-27。机器 Apple M5 Max 128 GB · MacBook Pro（Mac17,6）/ **macOS 27.0（26A428）** / Xcode 27.0（27A266a，Swift 6.4），接电源（powermode 2）。
worktree `.claude/worktrees/w4-soak-baseline-56b8ec`；桌面端给的分支 `claude/w4-soak-baseline-56b8ec` 上提交，**`w4-soak` 指向同一提交**（`git branch -f w4-soak HEAD`）。
从 main **da44bec**（G4 第四轮裁定落地之后）开。改动：`scripts/soak/`、`scripts/perf/`、`baselines/`、`reports/`、`Tools/switcher-headless/`（只加参数），
**另有 `Makefile` 末尾 18 行（三个 make 目标）越出归属，单独一个提交 bf11a15，待用户批（§4 第 1 条）**。`make lint BRANCH=w4-soak`：禁词 / 版本号 / 依赖方向 / RT 符号全绿，
归属只报 `Makefile` 一个文件。

**一句话**：三个 make 目标的脚本、判定和 §7 报告都写好了，用它们在本机跑了 1 小时 soak（S1 通过）和三轮 perf（写了 macOS 27 的第一版 L5 基线）。
跑的过程中发现并定位了三件事：**文件输入每循环一圈涨约 0.5 MB**（30 s 片段 = 60 MB/h，今晚 8 小时的 S2 大概率红，归 W2-A，问题单已写）；
**frameprobe 的内存随录像长度线性涨**（1 小时 41 GB，8 小时跑不下来，归 W1-A；soak 已改成按 5 分钟切段分析绕开）；
**L5 的"退步 > 10%"在 V3（0.05 ms 量级）上会误报**（同一份代码第 3 轮对第 2 轮 +13%，要你定怎么判）。8 小时实跑、Instruments Leaks、powermetrics、S4 等你 / 等机器（§3）。

## 1. 做了什么

### 探针与先红（铁律 10 / 铁律 2）

| # | 问题 | 结论 |
|---|---|---|
| 1 | frameprobe 能不能分析 8 小时录像 | 1 分钟录像（3600 帧）`frameprobe av --discontinuities` 4.5 s、峰值 RSS 730 MB（约 800 帧 / 秒）。当时按"整条音轨读成单声道 float 进内存"估 8 小时约 5.5 GB、本机够——**估错了**，内存其实随帧数线性涨，见第 9 条 |
| 2 | 会话 / CI 里能不能跑 Instruments Leaks | **不能**：`DevToolsSecurity -status` = disabled，xctrace 附加进程要当场输管理员密码；非交互时 xctrace 一直挂着、目标进程停在 T 状态（7 分钟没动，手动停了；这期间屏幕上可能弹过一次"开发者工具访问"的密码框，已随进程退出取消）→ leaks.sh 开跑前查它、非交互直接写 BLOCKED；另加 90 s 看门狗 |
| 3 | 摄像头授权在本会话里是什么状态 | 20 行探针（只查 `authorizationStatus`、不请求）：video = **notDetermined**（授权归属于负责进程，本会话 = Claude），audio = authorized。直接跑 `--camera auto` 会在无人时弹系统授权框 → soak.sh 的规则见 §1 交付 1 |
| 4 | "温度环境"不经 sudo 能读到什么 | macOS 27 上 `AppleSmartBattery` 已经没有 Temperature 键（ioreg 全树没有）；`pmset -g therm` 只有告警级别；`ProcessInfo.thermalState` 不要权限 → 编一个 14 行探针（thermal-state.swift）每分钟采；有 sudo 时再加 powermetrics 的 thermal_pressure；室温读不到，留 `--ambient` 给人填 |
| 5 | E4 录像与源怎么对齐 | 源是 10-bit ProRes，signalstats 的 YAVG 是 4 倍刻度（556 ≈ 139 × 4）→ 两边先 `format=yuv420p` 再取逐帧亮度均值、滑动比对；文件输入的锚点让录像第 0 帧就是源第 0 帧（偏移 0）；VMAF 三次运行逐帧相同（91.003） |
| 6 | 文件输入在 headless 收尾时为什么欠载 | 3 分钟冒烟 A1 红：欠载 187 块全在最后一拍之后——文件输入的声音在它自己身上，headless 收尾时它跟视频源一起停，音频引擎等录制封口 / 推流排空还要几秒 → 修 headless（先 `unregisterInput` 再停），判定只看"拍号还在走"的运行段、停机段单列。复跑两段都是 0 |
| 7 | 跑着的时候改脚本会怎样 | 连跑 perf 时我改了 perf-baseline.sh，正在跑的那一轮按旧偏移读错位（bash 边执行边读脚本）→ 四个长脚本开跑先把自己拷到临时目录再 exec；那三轮作废重跑 |
| 8 | 1 小时 soak 的 footprint 为什么一直涨 | 分组对照（G4 + 录制 / + 推流 / + NDI / + 文件，同时 15 分钟）只有文件那组涨；同内容 30 s 与 5 分钟 H.264 片段对照（每小时解码帧数相同、圈数差 10 倍）：30 s 的 60.4 MB/h（R² 0.99），5 分钟的约 6 MB/h → **每重开一次 reader +0.5 MB**，与编码无关 → 问题单给 W2-A |
| 9 | frameprobe 能不能分析 1 小时录像 | 能，但峰值 **41 GB**、12.5 分钟（10 分钟 7.6 GB）——内存随帧数线性涨，8 小时约 360 GB → 问题单给 W1-A；soak 改成按 5 分钟切段逐段跑再合并。切段要 `-avoid_negative_ts disabled`：不关的话第一段两条轨一起挪 +44 ms、AAC priming 的编辑列表丢了，闪光全被判成非整秒；关了之后 6 段整秒配对 1820 对（整条 1823）、偏移全 0.000 ms、不连续 0，与整条分析一致 |

### 交付（prompt 70）

| 交付 | 落点 | 做法 |
|---|---|---|
| 1 make soak（8 小时） | `scripts/soak/soak.sh`、`soakjudge.py`、`soak_report.py`、`env-snapshot.sh`、`thermal-state.swift`、`camera-auth.swift`；headless 的 soak 预设 | 负载：headless `--preset soak` = G4 节目（8 路噪声底纹合成源、5–8 号抠像、9 号 Stinger PNG、Overlay、多画面自定义布局、五种转场）+ 10 号内置摄像头 + 11 号文件（E4 片段循环）；场景每 30 s 一次转场（Cut / Fade / Wipe / Zoom / Stinger 轮流），每 5 min 翻一路叠加（1 摄像头 / 2 文件 / 3、4 抠像源）；PGM 只轮 1–8 号（摄像头 / 文件右上角亮了会被 frameprobe 当成闪光，A2 / A3 配出假偏移），摄像头 / 文件的声音不进 Master。输出全程开：录制 + 2 路推流（本地 MediaMTX s1 / s2，专用端口、只绑回环）+ NDI 发送。`caffeinate -u -i -d -s -w <headless>`（照 gate4.sh）。stats.jsonl 每秒一行；每分钟采进程 RSS（ps）、电源 / 电量 / 整机输入功率、thermalState、负载、在跑的编译进程、MediaMTX 每路收到的字节；有 sudo 时 powermetrics（10 s 一样）。判定：每 5 分钟窗口 V2 ≤ 0.02%、A1（超时 + 欠载 + frameprobe 离线不连续）= 0、E1（所有编码器 skipped）= 0，外加退出码 0、跑满时长、没有崩溃报告；异常（窗口超阈值、missed_render、欠载、编码跳帧、网络丢帧、重连、状态切换、stats 断档、拍号停走、V1 / V3 尖峰、输入停帧、离线不连续、崩溃）各取前后 5 分钟、重叠并段，截 stats / 带墙钟时间戳的 headless 输出 / 采样日志 / powermetrics 摘要 / `log show` 进 `anomalies/`；结束出 §7 报告 `reports/W4-soak-<标签>.md`。摄像头授权：已授权照用；交互终端里没问过就开跑前当场问；非交互且没问过就不接、报告里写明 |
| 2 make soak-1h | 同上，`--hours 1 --label 1h` | S2 的拟合段只有 30 分钟 → 只作参考；A3 按斜率外推到 8 小时（G3 / G4 同口径）；第一次通过时写 `baselines/soak1h-…json` 供"与上一版本的差" |
| 3 make perf-baseline | `scripts/perf/perf-baseline.sh`、`perfjudge.py`、`perf_report.py`、`make-e4-clip.sh`、`regression.json`；headless 的 perf-e4 预设 | 固定场景 = scenarios/g4-show.json + g4.json 前 5 分钟（`--record --iso-audio 4`，不起 API）→ V1–V3、S3（CPU 进程级 avg / p95；GPU = IOKit avg / p95，有 sudo 时 powermetrics 对照）；E4 = `make-e4-clip.sh` 用 lavfi 现场合成的三段片段（静态 / 慢动 / 高动态各 10 s，ProRes 422 HQ，同版 ffmpeg 逐字节可复现，没有外来素材）→ headless 文件输入 → H.264 6 Mb/s 录制 → 对齐 → libvmaf（另出 PSNR-Y / SSIM，分段），没 libvmaf 退到 PSNR。只和**同机、同 macOS 大版本**的上一版比（`baselines/perf-<机器>-macos<大版本>.json`）；退步 > 10%（E4 另按 §4：VMAF 降 > 1 分）或掉出必须档 → 退出 1。27 上的第一版单独存（本会话写了，见 §2） |
| 4 S2 | soak 报告的 S2 行；`scripts/soak/leaks.sh`、`leaks_report.py` | 每分钟一个 rss_mb（phys_footprint）样本，丢前 30 分钟拟合（MB/h），拟合段 ≥ 1 小时才判（8 小时那次），ps 的 resident 作对照。Leaks：xctrace Leaks 模板跑 soak 负载 30 分钟，导出 schema 名带 leak 的表（不写死表名），解 id / ref，按负责库 / 帧归到 OWNERSHIP 的会话；本会话 BLOCKED-权限（§3） |
| 5 S4 | `scripts/perf/s4-thermal.sh`、`s4_report.py`；perfjudge 的 `s4_timeline` / `s4_verdict` | 机型不是 MacBook Air → 只写 BLOCKED-机型 报告头（`--force` 能在任何机器上走一遍流程）。Air 上：标准负载（G4 节目 + 60 分钟 G4 场景 + 录制）1 小时 + powermetrics 5 s 一样；降频起点 = thermal pressure 不是 Nominal，或任一簇 / GPU 频率比前 5 分钟中位数低 15% 以上；起点之后 V2 ≤ 0.02% = "V2 仍达标"（引擎没有降级策略，只能按这条） |
| 6 8 小时 A3 | soak 报告的 A3 行 | 录像按 5 分钟切段逐段跑 `frameprobe av --discontinuities`（每段给 `--start-tick`，整秒配对仍由 frameprobe 判），`combine_segment_probes` 放回整条时间轴做与 AVStats 相同的统计：跑满 8 小时用斜率 × 首尾间隔，短跑外推；按绝对值判 ≤ 16 ms。8 小时约 45 分钟分析、每段约 4 GB |
| 7 caffeinate / App 测试 / 27 的基线 | 各脚本 | `caffeinate -u -i -d -s -w <pid>` 包 headless；开跑前查 xctest / `xcodebuild test`、全程记在跑的编译进程（env.log 的 busy 列、报告里单列分钟数）；perf 的基线文件名带 macOS 大版本，26.6.2 的 g4-m5max.json 只作参考列 |

headless 只加了参数（`Tools/switcher-headless/`，已有参数与预设行为不变）：`--stream <地址>`（可多次，W2-D 的 StreamOutput，第 i 个对节目里第 i 个推流输出，Stats.encoder 排在录制 / ISO / NDI 之后）；
`run` 接节目里的摄像头（只接画面、不开麦克风）/ 文件输入（相对路径相对节目文件；收尾时先从音频引擎摘掉再停）；`make-show --preset soak|perf-e4`（`--camera auto|none|<uniqueID>`、`--file`）、`make-scenario --preset soak`；
新增 `switcher-headlessTests`（9 条；`swift test --package-path Tools/switcher-headless`，make test 不跑工具用例）。

### 8 小时跑完之后（2026-09-28 上午）

- 8 小时结果（§2 第一张表）：S1 / A3 过，**S2 60.8 MB/h 与 S3 CPU 60.1% 红**。两项都定位了：
  - S2 → `reports/issues/W4A-w2-inputs-file-loop-memory-and-prores-starve.md` §3：FileInput 的解码线程（裸 pthread）没有自动释放池，每圈重开的 AVAssetReader 永远不释放；
    用 `OBJC_DEBUG_MISSING_POOLS=YES` 抓到 45 s 里 10174 个对象"just leaking"。复现 / 验证工具 `scripts/soak/fileprobe/`（只起 FileInput 的 SwiftPM 包，不接引擎）。
  - S3 → `reports/issues/W4A-w2-stream-ndi-send-cpu-share.md`：按线程拆，NDI SDK 自己的两个线程占 25 pt（一个核的 %），我们的 NDI 线程 1 pt；阈值 / 标准负载怎么处理等你定（§4 第 5 条）。
- 报告脚本修了一个判定漏洞：总判定原来只看 S1 / S2 / A3，**S3 红了顶行不显示、退出码还是 0**（§5 L4 明写 S1、S2、S3、A3）；现在 `soakjudge.s3_verdict` / `overall_verdict` 判，8 小时报告已重出，加了 5 条用例。
- soak.sh 每分钟多采一份每线程 CPU 时间（`scripts/soak/thread-cpu.swift`：proc_pidinfo，不要 sudo / task port），报告 §5 出"S3 按线程"表，3 条用例；以后 S3 红了直接看是谁的。
- `--ambient "约 NN °C"` 这种没换的占位符按未记录处理（8 小时那次原样记进了报告头）。
- 用户看完报告问"为什么不分到多核、一核有难 n 核围观吗"：`cpu_pct` 的 60% 是进程各线程合计 0.6 个核，不是某个核 60%。用 8 小时的 powermetrics 按核算
  （忙 = 1 − idle − down）：整机合计 1.55 个核忙、任一时刻最忙的核均值 26%；按线程最重的一条峰值 20%。数据、口径与探查项写在
  `reports/issues/W4A-g5-cpu-multicore-distribution.md`（到检查点安排）；报告从此多两张表：按线程（threads.log，现在带 pri / policy）、按核（powermetrics）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 1 小时 soak（`make soak-1h`，本会话 19:28–20:28；报告 `reports/W4-soak-1h.md`，数据 `.build/soak/1h/`）

负载按 §1 交付 1，**但本会话里没接摄像头**（授权未决、不弹框）、没有 powermetrics（无 sudo）；开跑时另一个会话刚编译完（负载 6.1），跑的这一小时里 env.log 没记到编译进程。

| 测试 ID | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|
| S1（1 小时） | 13 个 5 分钟窗口全部满足：V2 0 / 215 995 拍、A1 超时 0 + 欠载 0 + 离线不连续 0、E1 四个编码器全 0；退出 0、无崩溃报告、stats 覆盖 3600 / 3599 s；没有任何异常事件 | 每窗 V2 ≤ 0.02%、A1 = 0、E1 = 0，无崩溃（8 小时硬性） | ✅（1 小时版） |
| S2（1 小时，参考） | rss_mb（phys_footprint）预热后拟合 **108.9 MB/h**（R² 0.39，秒级 ±60 MB 起伏）；每分钟最小值 908 → 964 MB / 55 min ≈ **60 MB/h**；ps 的 resident 4.5 MB/h。定位：文件输入每圈 +0.5 MB（§1 探针 8、问题单 W4A-w2-inputs-file-loop-memory-and-prores-starve） | ≤ 10 MB/h / ≤ 2 | ⚠️ 只作参考（拟合段 30 min），**照这个趋势 8 小时那次会红** |
| S3 CPU | avg 54.9% / p95 57.1% / max 60.7%（进程级，100 = 一个核） | avg ≤ 60% / ≤ 40% | ✅ |
| S3 GPU | IOKit avg 26.4% / p95 37.0%；powermetrics BLOCKED-sudo | avg ≤ 50% / ≤ 35% | ✅ 达目标 |
| A3（外推） | 整秒配对 1823 对、跨 1.00 h，斜率 0.0000 µs/s × 8 h = **0.00 ms**；A2 最大 0.000 ms | 8 h ≤ 16 ms / ≤ 5 | ✅ 达目标 |
| V1 / V3（信息） | V1 avg 1.744 / p99 2.344 ms；V3 p99 0.035 / max 0.122 ms | avg ≤ 6、p99 ≤ 12 / p99 ≤ 4 | ✅ |
| V5 / E5（信息） | 录像 216 000 / 216 000 帧，视频 3600.000 s、音频 3600.000 s，ffprobe 无错误 | 1 h ≤ 2 帧；轨道差 ≤ 20 ms | ✅ |
| 输出 | 录制 / 推流 s1 / s2 / NDI：丢 0、重连 0、状态全程 recording / publishing；MediaMTX 两路都收到 6.2 Mb/s、运行中没断 | — | ✅ |
| 文件输入（信息） | 120 圈里"解码没跟上" 98 拍（每次重复一帧、跳一帧），推帧线程晚醒 569 514 次——ProRes 片段特有（同内容 H.264 两项都是 0），问题单同上 | — | 记为缺陷 |

### L5（`make perf-baseline`，三轮，报告 `reports/W4-perf-m5max-macos27.md`，基线 `baselines/perf-m5max-macos27.json` 取 run2）

| 测试 ID | run1 | **run2（基线）** | run3 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|---|
| V1 avg / p99 | 1.944 / 2.477 ms | **1.980 / 2.497 ms** | 1.925 / 2.520 ms | ≤ 6 / 12 ms（≤ 4 / 8） | ✅ 达目标 |
| V2 | 0 | **0 / 17 939 拍** | 1（中途有编译） | ≤ 0.02% | ✅ |
| V3 p99 / max | 0.049 / 0.088 ms | **0.047 / 0.110 ms** | 0.053 / 0.132 ms | p99 ≤ 4（≤ 2） | ✅ 达目标 |
| S3 CPU avg / p95 | 45.9 / 53.3% | **49.1 / 55.6%** | 44.2 / 53.4% | avg ≤ 60%（≤ 40%） | ✅ |
| S3 GPU avg / p95（IOKit） | 29.7 / 32.0% | **30.2 / 32.0%** | 27.6 / 32.0% | avg ≤ 50%（≤ 35%） | ✅ 达目标 |
| S3 GPU（powermetrics） | — | — | — | — | BLOCKED-sudo |
| E4 VMAF（静态 / 慢动 / 高动态） | 91.003 | **91.003（93.22 / 93.62 / 86.17），PSNR-Y 39.75 dB，SSIM 0.9913** | 91.003 | 相对上一版不降 > 1 分；绝对值写入基线 | ✅（第一版） |
| L5 退步判定 | 开头有编译，不写基线 | 同系统第一版，写入 | 对 run2 判 **V3 +13% 退步 → 退出 1**（同一份代码） | 退步 > 10% 非零退出 | 见 §4 第 2 条 |

g4-m5max.json（26.6.2、10 分钟、带 API 客户端）只作参考列：V1 2.149 / 2.644 ms、V3 p99 0.091 ms、CPU 50.7%、GPU 30.5%。

### 其余

| 测试 ID | 数值 | 通过 |
|---|---|---|
| **S1（8 小时，`make soak`，用户终端 2026-09-27 23:31 → 28 07:31，`reports/W4-soak-8h.md`）** | 97 个 5 分钟窗口 0 超（V2 0 / 1727995 拍，A1 0，E1 0）；退出码 0，崩溃 0；录制 / NDI / 2 路推流各 172.8 万帧一帧不丢；V5 1728000 / 1728000 | ✅ |
| S2（8 小时） | **60.82 MB/h**（预热后 451 点、7.5 h，R² 0.955；footprint 995 → 1617 MB；ps resident 62.2 MB/h）/ ≤ 10 | ❌（根因见 §1、issue W4A-w2-inputs…§3） |
| S3 CPU（8 小时） | **avg 60.1%** / p95 62.7% / max 74.9%（100 = 一核；逐小时 59.0 → 61.4）/ ≤ 60 | ❌（归因见 issue W4A-w2-stream-ndi-send-cpu-share） |
| S3 GPU（8 小时） | avg 25.8% / p95 28.0%（IOKit，正式口径）/ ≤ 50；powermetrics 49.7% / 64.8%，频率 8 小时全在最低档 338 MHz（dvfm_states 只有这一档有占用） | ✅ 达目标（口径疑问见 §4 第 6 条） |
| A3（8 小时） | +0.00 ms（整秒配对 13499 对、跨 7.94 h；A2 max 0.000）/ ≤ 16 | ✅ 达目标 |
| S3 按线程（8 分钟对照 `.build/soak/tcpu/`，同负载无摄像头） | `ndis:async` 18.9 + `ndis:lowQ` 6.2 + 无名 SDK / 系统线程 13.0 + AAC 1.3 + 推流音频 2.4 + 我们的 NDI 1.0 + 文件 1.0 + 引擎 / 音频 1.6 + 编码器交帧 1.7 + 合成源 1.6 = 49.2（cpu_pct 53.2） | 信息 |
| S2 · Instruments Leaks 30 分钟 | BLOCKED-权限（开发者工具访问没开，非交互附加不上）；解锁：终端里跑 `scripts/soak/leaks.sh` 输一次管理员密码，或 `DevToolsSecurity -enable` | BLOCKED |
| S4 | BLOCKED-机型（MacBook Pro 有风扇）；`scripts/perf/s4-thermal.sh` 在本机只写报告头 `reports/W4-s4-m5max.md`；解锁：借 M1 Air | BLOCKED |
| 单元：headless 预设（`swift test --package-path Tools/switcher-headless`） | 9 / 9 过（soak 节目 8 合成 + 摄像头 + 文件、输出编号、叠加换成摄像头 / 文件、每 30 s 切换、每 5 min 翻叠加、PGM 只轮 1–8、perf-e4） | ✅ |
| 单元：`python3 -B -m unittest discover -s scripts/perf -p 'test_*.py'` | 20 / 20 过（百分位、V1–V3 / S3 口径、10% 规则、基线为 0、floor、同机同大版本选基线、机型标记、powermetrics plist 解析、E4 对齐与分段 VMAF、S4 降频判定） | ✅ |
| 单元：`python3 -B -m unittest discover -s scripts/soak -p 'test_*.py'` | 34 / 34 过（shell 脚本里 `$变量` 后不许紧跟非 ASCII、窗口切分与累计相减、V2 / A1 / E1 窗口判定、离线不连续落窗、运行段 / 停机段、拍号停走、事件与并段、崩溃 / 短跑、每分钟 RSS、S2 预热后拟合与参考、S3 必须 / 目标档与总判定含 S3、线程快照解析与首尾归因、A3 满 8 h 与外推、分段合并、Leaks 导出解析） | ✅ |


## 3. 没做的和原因

- **8 小时的 S2 / S3 红着，没有为了让它过动任何东西**：S2 是 W2-A 的泄漏（每圈 0.5 MB × 960 圈，预测 60、实测 60.8 MB/h），S3 是 NDI SDK 的固定成本 + 摄像头；
  soak 的负载、阈值、文件片段都照 prompt 原样。修好 W2-A 之后要**重跑 8 小时**才有正式的 S2 值；8 小时不通过所以没写 `baselines/soak8h-*.json`（失败的跑不当基线）。
- **8 小时报告头的室温是 "约 NN °C"**：命令里的占位符没换就跑了；environment.txt 已经记下、报告我没手改（自动生成物）。下次给实际值或去掉 `--ambient`。
- **摄像头那一路的 CPU 份额是推出来的**（8 小时 60.1 − 1 小时 54.9 ≈ 5 pt，两次的其它条件一样）：带线程采样的对照在 Claude 会话里接不上摄像头（TCC 未决），
  下次你在终端里跑 `make soak-1h`，threads.log 会把摄像头的线程直接列出来。
- **CPU 逐小时 +0.37 pt 没有解释**：8 小时 59.0 → 61.4；等 W2-A 修完泄漏再看是否还爬（issue 里写了）。
- **Instruments Leaks 30 分钟**：BLOCKED-权限（§1 探针 2）。解锁：在自己的终端里跑 `scripts/soak/leaks.sh`（附加时输一次管理员密码），或先 `DevToolsSecurity -enable`；
  跑完出 `reports/W4-leaks.md`。导出解析是按 xctrace export 的 id / ref 结构写的、用造的样例测过，**没见过这台机器真实的 Leaks 表**——第一次跑要看一眼报告里的"全部表"与列名。
- **powermetrics**：8 小时那次采到了（用户给的 sudo；2875 样，168 MB plist），键名与预写的一致（gpu.idle_ratio / freq_hz / dvfm_states、thermal_pressure），解析没出错；
  perf-baseline 那三轮仍是没 sudo 的（GPU 只有 IOKit）。Claude 会话里仍 BLOCKED-sudo。
- **摄像头这一路**：8 小时那次接上了（`camera_auth=authorized`，收 863899 帧、30 fps、到达延迟均值 58 ms），Claude 会话里仍是授权未决不接。
- **S4**：BLOCKED-机型（这台是有风扇的 MacBook Pro）。脚本写好了、本机走过 BLOCKED 分支；`--force` 在本机把整条流程跑一遍需要 sudo（没有），没跑。解锁：借到 M1 Air。
- **Makefile 的三个目标**：越出归属，单独提交（bf11a15）、`make lint` 的归属检查因此报红 1 个文件——批不批见 §4 第 1 条。

## 4. 对契约的疑问 / 要用户定的

没有契约变更（SwitcherContracts、JSON 字段、测试图案都没碰）。要你定的：

1. **Makefile 归属**：prompt 70 点名要 `make soak` / `make soak-1h` / `make perf-baseline`，W4-B 的 nightly 也按这两个目标调，但 OWNERSHIP 的 W4-A 行没有 `Makefile`。
   我只在末尾加了一块（18 行、三个目标转调脚本、`SOAK_ARGS` / `PERF_ARGS` 透传），单独一个提交。批的话请检查点在 W4-A 行补 `Makefile`（同 W3-E3 的 project.yml 先例）；不批就撤掉 bf11a15，脚本直接跑。
2. **L5 的"退步 > 10%"在小量上会误报**：同一份代码连跑三轮（run1 开头有别的会话在编译，run3 中途有，run2 全程干净）：

   | | run1 | run2（写成基线） | run3 | 三轮极差 / 中位数 |
   |---|---|---|---|---|
   | V1 avg / p99（ms） | 1.944 / 2.477 | 1.980 / 2.497 | 1.925 / 2.520 | 2.9% / 1.7% |
   | V2 | 0 | 0 | 1 | — |
   | V3 p99（ms） | 0.049 | 0.047 | 0.053 | **13%**（6 µs） |
   | CPU avg / p95（%） | 45.9 / 53.3 | 49.1 / 55.6 | 44.2 / 53.4 | **11%** / 4% |
   | GPU avg / p95（%） | 29.7 / 32.0 | 30.2 / 32.0 | 27.6 / 32.0 | 8.8% / 0 |
   | E4 VMAF | 91.003 | 91.003 | 91.003 | 0 |

   run3 对 run2 按规则判了"V3 退步 13%"、退出 1——同一份代码。几种办法（按我的倾向排）：
   (a) 给 V3 p99 加绝对下限（比如变坏不到 0.1 ms 不算；必须档是 4 ms、目标 2 ms），CPU / GPU 加 5 / 3 个百分点的下限——`regression.json` 里每项一个 `floor`，脚本已支持，默认没填；
   (b) 每晚跑三轮取中位数再比（多 15 分钟）；(c) V3 不走 10% 规则、只按必须 / 目标档判。阈值是你的（铁律 9），我没改默认值。
   另：V2 的基线是 0 时比例算不出，脚本按必须档（≤ 0.02%）判、在说明列写明——这也是我的解释，你看行不行。
3. **每晚 1 小时那次的 S2 只作参考**：预热 30 分钟后只剩 30 分钟可拟合，噪声大；判定留给 8 小时那次（§3 S2 本来就是"长稳期间"）。A3 在 1 小时里按斜率外推到 8 小时判（G3 / G4 的口径）。
4. （信息）NDI 发送那一项的 `encoder[].bitrate` 是未压缩 UYVY 的码率（约 1.9 Gb/s），soak 报告的输出表里原样列了；字段口径是 019 定的，只提一句免得看报告的人吓一跳。
5. **S3 CPU 的 60% 线和 §3 S1 的标准负载在这个 NDI SDK 上是紧张的**：8 小时 60.1%（超 0.1 pt），按线程拆 NDI SDK 自己的线程 25 pt、无名 SDK / 系统线程 13 pt、摄像头约 5 pt，
   我们自己所有线程加起来约 10 pt（issue W4A-w2-stream-ndi-send-cpu-share 有整表）。三个选项：(a) 阈值不动，W2-D 查 SDK 有没有省的办法（`ndis:lowQ` 那 6 pt 是给低带宽接收方的第二路），
   没有就按 §4 末尾"个案放行一次"写进已知问题；(b) S3 拆成"不含 NDI / 含 NDI"两行记；(c) 改阈值。我建议 (a)，并把按线程的表存进基线、退步只看 `ndis:*` 之外的部分。阈值是你的。
6. **GPU 占用的两个计数器对不上**：§3 S3 写 IOKit 的 `Device Utilization %` "与 powermetrics 同一计数器"，8 小时第一次并排量：IOKit 25.8% / powermetrics 活跃比 49.7%，差一倍；
   而且 GPU 频率 8 小时全在最低档 338 MHz（`dvfm_states` 里 486–1578 MHz 各档占用全是 0），两个数都是"最低频下的忙时比"，按频率折算真正用掉的算力只有个位数百分比。
   判定按标准的正式口径（IOKit）；建议 §3 S3 那句"同一计数器"改掉，并在报告里同时列频率（soak 报告已经这么列）。改标准是你的事。
7. **8 小时 S2 / S3 红了要不要重跑**：S2 必须等 W2-A 修完再跑 8 小时才有正式值；S3 只差 0.1 pt、在运行间起伏（1 小时 54.9、8 分钟对照 53.2、8 小时 60.1）之内，
   等第 5 条定了再说。两项都不是 soak 脚本的问题，脚本这边能判、能归因、能截日志，已经验证过。
8. **用户 2026-09-28 裁定**（看完 8 小时报告）：(a) S2 肯定要修（W2-A，单子 §3 有修法与验证）；(b) 负载很低、单核 60% 不足为惧，S3 意义不大、不阻塞；
   (c) 但要探查"为什么不分到多核"——`cpu_pct` 的 60% 是进程所有线程加起来 0.6 个核、不是某个核在 60%（按线程最大的一条 `ndis:async` 峰值 20%，
   按核 8 小时里最忙的核也只有百分之十几，见 `reports/issues/W4A-g5-cpu-multicore-distribution.md` 的数据），多核的探查项写在那张单子里；
   (d) 这些都到检查点（G5）再往下安排。第 5 条的三个选项因此不用现在定。

## 5. 下一个会话需要知道的坑

0. **macOS 的 /bin/bash 3.2 在 UTF-8 locale 下会把 `$变量` 后面紧跟的中文 / 全角标点的首字节并进变量名**：`"跑 $label（…"` 在 `set -u` 下直接
   "label�: unbound variable" 退出。会话里的 Bash 工具没设 LANG（C locale），**所有验证都测不出来**；用户在自己的终端里第一次跑 `make soak` 就断在
   env-snapshot.sh / make-e4-clip.sh（2026-09-27 晚，已修：16 处全改成 `${name}`，并在中文 UTF-8 locale 下把 soak / perf 整条实跑过）。
   `scripts/soak/test_soakjudge.py` 的 `test_S1_shellScriptsBraceVariablesBeforeNonASCII` 扫 scripts/soak、scripts/perf 的脚本防回归；
   别的目录写中文的 bash 脚本也要注意（验证时加 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8`）。机型也别从 `system_profiler` 的文字标签里抠，用 `-json`。
1. **别在脚本跑着的时候改它**：bash 边执行边按偏移读脚本，中途改文件（编辑、`git pull`、合并）会让正在跑的那一轮读到错位的行。soak / perf-baseline / leaks / s4-thermal 现在开跑先把自己拷到 `$TMPDIR` 再 exec 拷贝；
   新写的长脚本照这个做（`SWITCHER_SCRIPT_COPY` 那几行）。
2. **摄像头授权归属于"负责进程"**：在终端里跑就是那个终端 App，在 Claude 里跑就是 Claude，CI 里是 runner。非交互且授权未决时 soak 不接摄像头（不弹框），报告 §2 会有 ⚠️。
3. **开发者工具访问没开时 Instruments 附加会挂住**：xctrace 不报错、目标进程停在 T 状态、一直等管理员密码；leaks.sh 有前置检查和 90 s 看门狗，别的地方用 xctrace 也要防这个。
4. **soak 的文件输入是 ProRes 422 HQ（约 430 Mb/s 的 E4 源）**：这种片段会让文件输入每圈在循环点空一拍、推帧线程大量晚醒（H.264 没有，问题单给 W2-A）；
   报告的输入表里 11 号的 dup 就是这个，不是引擎挑帧的问题。
5. **headless 收尾顺序**：带自身音频的输入（文件）要先从音频引擎摘掉再停，否则音频引擎等录制封口 / 推流排空的那几秒全记成欠载；以后给 headless 接别的"自己带声音"的输入（摄像头麦克风、DeckLink）照这个做。
   soak 的判定只看运行段（拍号第一次到达最终值的那一行为止），停机段单列不判。
6. **BSD 的 `seq 1 0` 会倒着数出 `1 0`**：计数循环用 while。
7. **E4 片段**：1.7 GB 的 ProRes 422 HQ（高动态段有逐帧噪声，约 430 Mb/s），放在 `.build/perf/e4/`，第一次生成约 35 s。同一版 ffmpeg 逐字节相同，sha256 进基线；
   换了 ffmpeg 片段就变，E4 不与上一版判退步（报告里写明）。
8. **别的会话在编译时量出来的 perf 不能当基线**：env-snapshot 会列出在跑的 swift-frontend / xcodebuild / xctest；perf 第一版基线只在没有这些进程时才自动写。
   锁屏的动态壁纸也在用 VideoToolbox 解码（VTDecoderXPCService 3–4%），报告的"占 CPU 前几名"里看得到。
9. **MediaMTX 端口**：soak 用 19350 / 19997 / 18890，leaks 用 19351 / 19998 / 18891，只绑 127.0.0.1（不触发防火墙提示），避开 W2-D 测试的端口。
10. **frameprobe 别对整条长录像跑**：内存随帧数线性涨（10 分钟 7.6 GB、1 小时 41 GB），soak 按 5 分钟切段；切段必须 `-avoid_negative_ts disabled`，
    否则第一段丢了 AAC priming 的编辑列表、两条轨一起挪 44 ms，拍号全偏、整秒配对一个都没有（偏移本身不受影响，所以看 A2 是看不出来的）。
11. **切段后第一段 t = 0 那一对闪光 / click 会配上（晚 7 个样本，−0.146 ms）**，整条分析时它是没配上的：只是起点瞬态，对 1 小时的外推约 0.004 ms、
    8 小时约 0.0001 ms；6 分钟冒烟会被它拉出 0.37 ms 的"漂移"——短跑的 A3 外推别当真。
12. **别用宽匹配的 pkill 停测试进程**：本会话一度用 `pkill -f "caffeinate -u -i -d -s -w"` 收拾自己的实验，这会连别的会话 gate 脚本里同样参数的 caffeinate 一起停掉（当时查过没有别人在跑）。按 PID 停。
13. **`( … ) &` 里的 `$(run …)` 起的进程不是当前 shell 的子进程**，`wait` 会直接返回（本会话一次对照实验因此把 MediaMTX 提前关了）；要 wait 就在当前 shell 里 `&` 并记 `$!`。
14. **`read -t 60 -p`**：soak / perf 在终端里问"要不要采 powermetrics"，60 s 不答当作不采——人走开了不会卡在密码提示上。sudo 票据在开跑前拿到后保活到 powermetrics 启动。
15. **裸 pthread 上调 AVFoundation / CoreMedia 会"autoreleased with no pool in place - just leaking"**：`InputThread` 这种 `pthread_create` 起的线程没有自动释放池，
    `copyNextSampleBuffer()` 每调一次 AVFoundation 内部 autorelease 的 reader / track output 就永远多一个引用，线程退出才释放（所以短测试看不出、stop() 之后 footprint 掉回）。
    **查这类泄漏最快的办法**：`OBJC_DEBUG_MISSING_POOLS=YES <程序>`，运行时逐个打印类名，不用 Instruments、不用 sudo（本会话 45 s 就抓到 10174 条）。
    渲染 / 音频线程按铁律 3 不碰 ObjC 对象没这个问题；输入线程（文件、摄像头、DeckLink、NDI 接收）都要看。
16. **判定项要对着 §5 的 L4 / L5 那一行逐个核**：soak 的总判定漏了 S3 一整天没人发现，直到 8 小时 CPU 刚好 60.1%。`overall_verdict` 现在有用例锁住四项。
17. **S3 红了先看 threads.log**：`scripts/soak/thread-cpu.swift <pid>` 随时能对任何自己用户的进程用（proc_pidinfo，不要 task port，DevToolsSecurity 关着也行）；
    引擎的线程都有名字（`switcher.*`、`file-decode-N`、`synthetic-video-N`），SDK / 系统的没有（VideoToolbox、AVFoundation、HaishinKit 的 GCD 线程），NDI SDK 的叫 `ndis:async` / `ndis:lowQ`。
18. **powermetrics 的 GPU "占用"是当前频率下的忙时比**：看 `gpu.dvfm_states` 各档的 `used_ratio` 才知道跑在哪一档；最低档 338 MHz 上 50% 忙 ≈ 满频的 10%。别拿它和 IOKit 的数互相验证，两个口径都不是"用了多少算力"。
19. **`scripts/soak/fileprobe/` 是个独立的 SwiftPM 包**（path 依赖 Core / Inputs / Audio，只起 FileInput），`.build/` 已被 .gitignore 的通配盖住；`make build` / `make test` 不碰它，
    W2-A 验证修复时 `swift build -c release --package-path scripts/soak/fileprobe`。

## 8 小时怎么跑（已跑过一次；W2-A 修完泄漏后重跑）

```bash
make soak SOAK_ARGS='--powermetrics on --ambient "约 24 °C"'
```

室温换成实际值（占位符 `NN` 会被当成没给）；开跑前问一次 sudo 密码（powermetrics），摄像头没授权过会弹系统授权框（点允许）；之后无人值守。
跑完（约 8 小时 + frameprobe 约 40 分钟）看 `reports/W4-soak-8h.md`；改了判定脚本想重出报告：`scripts/soak/soak.sh --skip-run --no-build --hours 8 --label 8h`。
`.build/soak/8h/` 里 21.5 GB 的录像和 168 MB 的 powermetrics.plist 是这次的原始数据，要不要留由你定。
Leaks（不必和 soak 同一晚，30 分钟）：

```bash
scripts/soak/leaks.sh
```
