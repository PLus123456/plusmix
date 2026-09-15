# G2 检查点报告：M0 核心循环集成（分支 g2-m0）

**结论：G2 通过（2026-09-15，用户裁定）。** M0 核心循环——8 路合成源 → 帧槽 → Metal 合成 → NV12 → H.264 → .mov，60 分钟：V2 0、V3 p99 0.068 ms、V4 设计外 0、V5 差 0、E1 0、A1 0；V1 avg 2.0014 ms 超本机 2 ms 参考线 1.4 µs 按参考线精神放行（§6）。V4 曾不过，退回 W1-B 修（到达余量）后复测通过。退回 / 观察单：W1-E（录制封口）、W2-E（A/V 偏移）、W1-C（观察）见 §6。

（本文件是人工写的部分；`make gate2` / `make gate2-1h` 每次运行把 `reports/G2-run-<label>.md` 的自动结果拼到本文件后面生成 `reports/G2.md`。测试标准 §7 模板的六项：版本 / 提交号、机器、场景在下面和自动结果里各有一份；每个指标的数值 · 阈值 · 通过否 · 与上一版本的差在自动结果的表里；文件路径在自动结果的"文件"一节；已知问题与放行说明在 §6。）

## 1. 版本 / 提交号

- 分支 `g2-m0`，从 `main`（`bdab613`，P1 契约冻结后）开；worktree `/Users/plus/plusmix-g2-m0`。
- 版本 0.1.0（project.yml 与 Version.swift 一致，lint 校验）。
- 合入的五个分支（都从 `bdab613` 开，改动文件两两无交集，五次合并零冲突）：

| 顺序 | 分支 | 提交 | 会话 | 合并提交 |
|---|---|---|---|---|
| 1 | `w1-testkit` | `d5b56d5` | W1-A 测试工装 | `a172c30` |
| 2 | `w1-core` | `de62cdc` | W1-B 核心逻辑 | `ef8b3e5` |
| 3 | `w1-compositor` | `0311f32` | W1-C 合成引擎 | `942cea4` |
| 4 | `w1-audio` | `b1ff37f` | W1-D 音频引擎 | `6b3b5db` |
| 5 | `w1-outputs` | `a494d26` | W1-E 编码录制 | `9736336` |
| 6 | `w1-core`（V4 复测版） | `3fe6d29` | W1-B 到达余量（修退回单） | `f694a97` |

- 报告的最终提交号：`git log -1 g2-m0`（本文件与 reports/G2.md 在最后一个提交里；gate 运行用的 headless 是 `7d669e5`，报告生成器修正在 `4de1039`）。

## 2. 机器 / macOS / 电源 / 温度

- MacBook Pro，Apple M5 Max（6P + 12E，40 核 GPU），128 GB；macOS 26.6.2 (25G83)；Xcode 26.6 / Swift 6.3.3；ffmpeg 9.0.1。
- 接电源适配器（`pmset -g batt`：AC Power），无温度 / 性能警告记录（`pmset -g therm`）。室温未记录。
- 环境问题：本会话开始时机器上在跑一个游戏（Cyberpunk 2077，638% CPU，load 6.5），合并 w1-testkit 后第一次 `swift test` 里 8 个合成源实跑测试因唤醒晚 ~100 ms 失败；游戏退出后重跑全绿（见 §4）。10 分钟 gate 在 load 1.8、无其它占 GPU 程序时跑；60 分钟 gate（00:39–01:39）期间用户在用桌面（Chrome、WindowServer），load 3–4，GPU 有 741 s 超过 50%，见 §6 第 8 条。每次运行的 environment.txt 记录跑前 / 跑后负载，60 分钟运行从 01:10 起另有 5 s 一次的 load.log（之后 gate2.sh 自带）。

## 3. 场景

- 节目 `scenarios/m0-show.json` + 场景 `scenarios/m0.json`（内容见 scenarios/README.md；两者由 `switcher-headless make-show / make-scenario` 生成后入库）。
- 命令：`make gate2`（10 分钟）/ `make gate2-1h`（60 分钟）→ `scripts/gate2.sh` → `switcher-headless run … --audio-device null` → frameprobe → summarize → `scripts/gate2-report.py`。

## 4. 合并记录：每合一个跑了什么、结果

| 步骤 | 合并后跑 | 结果 |
|---|---|---|
| 1 w1-testkit | `make build-packages build-tools`、`make lint`、`swift test` TestKit | 构建绿；lint 红：`check-ownership.sh` 把合进来的 4049 行当成 G2 的胶水（脚本不认识合并提交，见 §5.1）→ 改脚本后绿；TestKit 49 个测试 41 过 8 败（8 个全是合成源实跑的唤醒 / 抖动断言：唤醒晚 101 ms、标准差 28 ms，机器当时被游戏占满，load 6.5）；游戏退出后在第 3 步重跑 49/49 绿 |
| 2 w1-core | `make build-packages`、`make lint`、`swift test` SwitcherCore | 全绿：lint 三项 + check-rt-symbols 通过；SwitcherCore 96 个测试全过（108 s，含 30 s 抖动实跑 p99 < 1 ms） |
| 3 w1-compositor | `make build-packages`、`make lint`、`swift test` SwitcherCore（含 Render 27 个）、重跑 TestKit | 全绿：SwitcherCore 122 个测试全过（224 s，含 V1 30 s 实跑、显示解耦切全屏）；TestKit 49/49（74 s）；lint 绿 |
| 4 w1-audio | `make build-packages`、`make lint`、`swift test` SwitcherAudio | 全绿：52 个测试 50 过 2 跳（跳的是 W1-D 报告里的 BLOCKED-权限：真麦克风 IOProc），183 s；lint 多了 `check-rt-symbols.sh`（自动挂上）也绿 |
| 6 w1-core 复测版（2026-09-15） | `make build-packages build-tools`、`make lint`、`swift test` SwitcherCore | 全绿：SwitcherCore 134 个（比之前多 W1-B 的 12 个 `testV4_*` 到达抖动用例，234 s）；lint 六项绿（归属 26 个文件，含合并提交结算） |
| 5 w1-outputs | `make build-packages build-tools`、`make lint`，然后整仓 `make test`（六包 + 两工具冒烟 + App xcodebuild test）+ `make lint` | 全绿（23:39–23:57，机器空闲）：SwitcherCore 122、SwitcherAudio 52（2 跳，BLOCKED-权限）、SwitcherOutputs 18（431 s，含 E5 20 次、E6 kill -9 10 次）、SwitcherTestKit 49、Inputs / Control 骨架各过；switcher-headless / frameprobe 冒烟过；App `xcodebuild test` 退出 0；`make lint` 六项全绿（禁词、版本、Package.swift、依赖方向、归属 17 个文件、check-rt-symbols） |

接口不一致 / 冲突：五次合并零冲突（改动文件两两无交集）；接口全部按 CONTRACTS.md 对上，没改任何包（§5.4）。

## 5. G2 自己改了什么（只准动的目录：Tools/switcher-headless、scripts、Makefile、scenarios、reports、baselines；各包胶水 ≤ 50 行）

### 5.1 scripts/check-ownership.sh：识别合并提交

原脚本算"merge-base(main, 分支) → 分支顶"的 diff，检查点分支合入 w1-* 后这个 diff 包含全部功能代码，胶水额度必爆。现在分支上有合并提交时沿第一父链逐个提交结算：普通提交算相对父提交的 diff，合并提交算相对 `git merge-tree --write-tree` 自动合并结果的 diff（只剩冲突解决 / 手改）；同一文件多次改动按增删相加。功能分支（无合并提交）行为不变（w1-testkit / w1-core / w1-outputs 三个分支的结果与原脚本一致）。`--include-working-tree` 改为"工作树相对分支顶 + 未跟踪文件"，不再靠 `sort -u` 去重。
docs/OWNERSHIP.md 补充规则 5 的文字（"脚本只看已提交的改动（merge-base → 分支顶）"）需要相应更新一句，docs/ 不在 G2 的目录里，请用户改或授权（§7）。

### 5.2 Tools/switcher-headless：无界面模式

`run`：Show 文件 → StateMachine + MetalRenderer + Engine（W1-B / W1-C）；每路合成源一个 `LockFreeFrameSlot`（容量 3）+ `SyntheticVideoInput`（W1-A，像素池 12），所有路共用 t0 = 节目第 0 拍；带音频的路一个 `CAudioRing` 挂进 `AudioMixer` 槽位（W1-D，参数照 `InputSettings.audio`），输出设备 `--audio-device null`（时间约束线程的假时钟，不出声）或真设备；`Recorder`（W1-E）作 PGM 消费者，Master 块经 `AudioBlockTap` → 泵线程（2 ms 轮询）→ `consumeAudio`；`StatsWriter`（W1-A）1 Hz 调 `Engine.makeStats()`，编码 / 音频 / GPU 三个来源分别从 `RecorderCounters.encoder.statsEntry`、`AudioMixer.audioCounters`、IOKit `AGXAccelerator.PerformanceStatistics["Device Utilization %"]` 灌；场景事件全部预排程到状态机（`schedule(_:at:)`，按拍应用，跳拍也不漏）。启动顺序：音频设备 → 录制（起点第 0 拍）→ 泵 → 输入 → 引擎（`start` 里 prepare 渲染器；t0 = 现在 + 1 s 盖住它）。停止顺序：引擎（时钟停 → 渲染器排空在途帧并派发 → 状态机停）→ 输入 → 录制封口 → 泵 → 音频设备 → stats 关文件。Ctrl-C / SIGTERM 走同一条收尾路径，第二次立即退出。`--preview` 开 W1-C 的 `PreviewWindow`（1 / 2 / 3 切 PGM / PVW / 多画面）。
`make-show` / `make-scenario`：生成 M0 的节目与场景。`summarize`：stats.jsonl → §7 表格（可与基线比）+ 关键数字 JSON，`--write-baseline` 写 baselines 文件（元数据 + W1-A 的 `StatsSummary` 原样）。

### 5.3 探针（铁律 10）

- IOKit 读 GPU 占用：`IOServiceMatching("IOAccelerator")` 下 `AGXAcceleratorG17X` 的 `PerformanceStatistics` 有 `Device Utilization %` / `Renderer Utilization %` / `Tiler Utilization %`，普通用户可读，`IORegistryEntryCreateCFProperties` 一次约 3 ms（改成只读一个属性更快）。用于 `Stats.gpu_pct`（口径：设备级忙碌百分比，与 powermetrics 的 GPU 占用同源但不是同一个采样器；测试标准 §3 S3 写的是 powermetrics，需要 sudo，headless 里做不到）。
- `git merge-tree --write-tree`（git 2.50）对无冲突合并给出与合并提交完全相同的树（diff 为空），是 §5.1 的依据。

### 5.4 各包胶水

0 行。五个包一行没改（`scripts/check-ownership.sh g2-m0` 的结算：g2-m0 相对 main 的自有改动只有 Tools/switcher-headless、scripts、Makefile、scenarios、reports、baselines）。各 W1 报告里说"G2 一起删"的 `Switcher*Skeleton` 别名也没动：App/Tests/SkeletonTests.swift 还读 `SwitcherTestKitSkeleton.contractsVersion`，其余四个别名互相兜着，删掉要同时改 TestKit 与 App（App 不在 G2 目录里），留给 W2-B 换 UI 冒烟测试时一起清。

接口不一致：没有需要改包的。五个包的接口按 CONTRACTS.md 对得上（Engine.registerInput ↔ LockFreeFrameSlot ↔ SyntheticVideoInput 的注入；Renderer.prepare 的 maxInputs = 表容量，W1-B 传 maxInputs + 1，W1-C 按它建表；Recorder 作 FrameConsumer；AudioBlockTap → 泵 → AudioBlockConsumer），组装全在 headless 里。三处"用法上的坑"写成了问题单（§6）。

## 6. 已知问题与放行说明

**G2 总判定（2026-09-15 复测，W1-B 到达余量合入后的 10 分钟运行）：V4 已修——设计外 0 帧（stats.jsonl 全程与 frameprobe 在播段两个口径都是 0；59.94 两路 dup 36 = 期望 35.9、drop 0，+100 ppm drop 4 = 期望 3.6、−100 ppm dup 4 = 期望 3.6，其余四路 0 / 0）；V2 0、V3 p99 0.061 ms、V5 差 0；只剩 V1 avg 2.107 ms 超本机 2 ms 参考线 0.107 ms**（必须档 ≤ 6 / 目标 ≤ 4 都过）。这 0.1 ms 是环境不是修法：W1-B 自己在同一台机器上跑的 10 分钟（G2 的 frameprobe 在旁边跑分析）V1 avg 1.66 / p99 2.03；本次前 9 分钟逐分钟 2.01–2.06，最后两分钟 2.27 / 2.57 同时 GPU 占用跳到 35% / 51%（桌面在用：WindowServer 30%、桌面端 Claude 两个进程各 20%，Activity Monitor 开着），昨晚干净的 10 分钟逐分钟 1.85–2.01。**60 分钟复测（2026-09-15 09:36–10:36，`G2-run-1h.md`）：V2 0、V3 p99 0.068 ms、V4 设计外 0（两个口径；59.94 两路 dup 216 = 期望 215.7、+100 ppm drop 21 = 21.6、−100 ppm dup 22 = 21.6、30 fps 恰好 50%、7 / 8 号 0 / 0）、V5 216000 − 216000 = 0、E1 0、A1 0、S2 2.02 MB/h、S3 CPU 27.9% / GPU 21.7%；V1 avg 2.0014 ms / p99 2.39 ms——超本机 2 ms 参考线 1.4 µs，§4 必须档（≤ 6 / 12）与目标档（≤ 4 / 8）都过。** 昨晚 60 分钟的 13 次 miss 与 V5 −13 没有再现。环境：整个小时桌面端 Claude 两个进程几乎每个 5 s 采样都在 CPU 前四（两个会话在刷输出），Activity Monitor 开着，GPU > 50% 的秒数 34；昨晚干净的 10 分钟 V1 是 1.93。**用户裁定（2026-09-15）：V1 按参考线精神放行，G2 通过。** 放行说明：参考线是 G2 prompt 加的本机加严值（不是测试标准 §4 的门槛），超出 1.4 µs，必须档（≤ 6 / 12 ms）与目标档（≤ 4 / 8 ms）都过；运行期间桌面端 Claude 两个进程全程占 CPU，昨晚干净环境同负载 1.93 ms。这是本项目第一次个案放行（测试标准 §4：非硬性项可个案放行一次），记在此处；60 分钟自动结果表里该项标 ⚠️ 放行（`scripts/gate2.sh --waive`）。
修前（2026-09-14 23:20 的 10 分钟运行，`G2-run-10min-pre-fix.md`）：V1、V2、V3、V5 全过，V4 不过。按落地方案 §4 G2 的退回规则，V4 退回 W1-B；不个案放行——测试标准 §4 说非硬性项"有充分理由并写入已知问题时可以个案放行一次"，但 G2 prompt 的通过标准写的是"V4 设计外 0"，且超的是必须档（单路最差 0.084% > 0.05%）。**用户裁定（2026-09-15）：V4 退回 W1-B。** 任务已由 G2 会话直接发给 W1-B 会话（问题单 + 验收标准：带到达抖动的漂移生产者测试 testV4_*、零分配测试仍过、在 g2-m0 的 headless 上跑 200 s / 10 min 看 3–6 号输入设计外为 0）；W1-B 交付后由下一个检查点（重跑 `make gate2`）确认。60 分钟 gate 照跑，结果并入本报告。

| # | 问题 | 归属 | 严重级 | 状态 |
|---|---|---|---|---|
| 1 | 输入帧到达相位穿过拍点边界时成串的重复 + 丢弃：10 分钟里 59.94 ×2、±100 ppm ×2 四路设计外共 192 帧，单路最差 0.084%（必须 ≤ 0.05%，G2 要求 0）。根因是挑帧规则按 pts 判合格、按已到达判可用，pts 落在拍点附近时与到达时刻赛跑。 | W1-B | S2 | `reports/issues/G2-w1-core-phase-crossing-dup-drop.md`，退回 → **W1-B 已交付 `3fe6d29`**（到达余量：`latest(forTick:)` = `latest(atOrBefore: t_n − L)`，L 按 ingressTime − pts 自估、只在零代价的拍变动；契约不动；12 个新 `testV4_*` 用例；reports/w1-core.md §1.4），合入 `f694a97`；复测结果见自动结果里的"运行 10min"，修前那次改名 `G2-run-10min-pre-fix.md` 留档 |
| 2 | `Recorder.stop(atTick: nil)` 期间音频还在实时到达时收尾拖成分钟级；`appendPCM` 超时丢样本不计数。headless 已改为传拍边界绕开。 | W1-E | S2 | `reports/issues/G2-w1-outputs-stop-with-live-audio.md`，退回 |
| 3 | A2：click 比闪光晚 16.6–18.5 ms（三次运行分别 18.0 / 18.5 / 16.6，每次运行内恒定、标准差 0、无漂移），在必须档 16.7 ms 边上。混音器输入槽稳态延迟（ageSetpoint 14.65 ms）没有在音频 PTS 上扣掉；每次运行差的 ±1 ms 量级是录制器把起点后的第一块整块锚到起点（块相位 0–5.33 ms 被量化掉）。M0 不判 A2。 | W2-E（延迟核算）/ W1-E（首块锚定） | S2 | `reports/issues/G2-w2-audio-integ-av-offset.md`，给 G3 |
| 4 | frameprobe 在 Fade 的混合帧上：1 帧帧号读不出（CRC）、20 帧 ID 读不出、4 帧 ID 误判成调色板 15（明细二里"ID 15 丢 8990"那行）。混合帧本来就不该解出 ID，`switches` 已把它们识别为 transition，`stats` 没排除。不影响 V4 / V5 判定。 | W1-A | S3 | 只记录，未开单（G3 判 V7 时若碍事再开） |
| 5 | A/V 分析的 59.94 段：契约把 59.94 的闪光周期定为 60 帧 = 1.001 s，它在播时闪光相对整秒逐渐滞后（10 分钟里最多 0.48 s），click 仍在整秒，frameprobe av 的均值 / 最大值 / 斜率被拉偏（均值 −19.0、最大 484.7 ms、斜率 −0.41 ms/s）。gate 报告另算了"整秒闪光"一行。G3 判 A2 时要么只用整数帧率的路，要么 click 也按在播输入的闪光周期走。 | 测试标准 §2.1 / W1-A | S3 | 记录，给 G3 |
| 6 | Stats.encoder 没有帧数 / 丢帧 / 磁盘剩余（提案 001 待批）；gpu_pct 用 IOKit 口径（§7 第 3 条）。 | 契约 | — | 等用户批 |
| 7 | 环境：本会话前 40 分钟机器被游戏占满（load 6.5），第一轮 TestKit 实跑测试假失败；10 分钟 gate 在 load 1.8 时跑。 | — | — | — |
| 8 | （已被 09-15 的复测取代，留档）**修前 60 分钟运行环境不干净**：用户同时在用桌面（Chrome、WindowServer 40–45%，GPU > 50% 的秒数 741 / 3600），另有一个第一次冒烟跑残留的 headless 进程（忽略了 SIGTERM，带实时音频线程 + 2 ms 轮询泵）到 01:09 才被清掉。结果 V2 = 13（全部是渲染器 skipped，两簇：00:55:07–30 共 11 次、01:02:28–33 共 2 次，那几秒 GPU 晚了约 200 ms），V5 = −13（少的正是这 13 拍）；V1 avg 2.22 ms 也超了本机 2 ms 参考线（干净 10 分钟是 1.93）。两簇 miss 与 GPU > 50% 的时段（00:43–00:44、01:22–01:39）不重合，却都落在残留进程存活期内，01:09 杀掉后 30 分钟里桌面 GPU 负载更重也 0 次 miss——归因不了。V2 过 §4 必须档（0.006% ≤ 0.02%）不达目标；**V5 不过（≤ 2 帧）**。这个 V5 / V1 结论不可靠：需要在无人使用、无其它 GPU 程序、无残留进程时重跑 `make gate2-1h` 一次才能下定论（gate2.sh 现在运行期间自带 5 s 负载采样，跑前 `pgrep -x switcher-headless` 确认没有残留）。 | W1-C（观察单）/ 环境 | S3 | `reports/issues/G2-w1-compositor-gpu-preemption-skips.md`；重跑 60 分钟 |
| 9 | 录制音轨样本数比名义时长多：10 分钟 +3745 样本（78 ms），60 分钟 +5306（110 ms）；`RecorderCounters.audioDrift` 5.3 → 10.7 ms。click 相对闪光的偏移在 10 分钟内恒定 −18.0 ms（无漂移），60 分钟的看自动结果里 A2 整秒行。记进 W2-E 问题单，G3 判 A3 时核。 | W1-E / W2-E | S3 | 并入 `G2-w2-audio-integ-av-offset.md` |

不做的（G2 规矩）：以上 1–3 都是功能改动，没在检查点里修。

## 7. 对契约 / 流程的疑问（G2 自己的；五个 W1 报告各自 §4 的条目原样有效，这里不重抄）

1. **docs/OWNERSHIP.md 补充规则 5** 写的是"脚本只看已提交的改动（merge-base(main, 分支) → 分支顶）"，`check-ownership.sh` 现在对含合并提交的分支按第一父链逐提交结算（§5.1）。docs/ 不在 G2 目录里，请用户把这一句改成"功能分支：merge-base → 分支顶；检查点分支：沿第一父链逐提交，合并提交只算相对自动合并结果的手改"，或授权 G2 改。
2. **提案 001（W1-E）仍待批**。G2 没有绕过它：Stats.encoder 只有 skipped / bitrate，录制的帧数 / 丢帧 / 磁盘剩余只在 headless 收尾摘要里打印（来自 `RecorderCounters`），不在 stats.jsonl 里。批了之后 headless 的 `EncoderStatsSource` 加三个字段即可。B 部分（`AudioBlockConsumer` 升契约）G2 不需要（headless 直接 import SwitcherOutputs），W2-E 需要。
3. **`Stats.gpu_pct` 的来源**：测试标准 §3 S3 写 powermetrics（要 root，headless 里做不到）；G2 用 IOKit 的 `Device Utilization %`（设备级忙碌百分比，同一硬件计数器的另一个读法，不用 sudo）。请确认可以作为 S3 的 GPU 口径；不行的话 gate 脚本里加一步 `sudo powermetrics` 由用户自己跑。
4. **V3 的口径**：stats.jsonl 的 jitter_ms 是 W1-B 填的"渲染线程唤醒时刻 − 理想拍点"（窗口最大值），G2 按它判 V3；W1-B 另留的 `takeDispatchJitterMax()`（GPU 完成回调时刻 − 拍点）没接进 Stats（铁律 4 不许另算）。哪个算 V3 请拍板（W1-B 报告 §4 第 1 条）。
5. **合成源的到达相位**：测试标准 §2.1 的合成源没有规定"帧相对拍点提前多少到达"，而这直接决定 V4（问题单 `G2-w1-core-phase-crossing-dup-drop.md`）。G2 定的默认值是提前半个节目帧（`--input-lead-ms`），音频不提前。建议写进测试标准 §2.1（或 W4-A 的长稳场景说明），否则各检查点的 V4 不可比。
6. **V4 "设计外 = 0" 的判法**：StatsSummary 按平均帧率算设计内比例，±100 ppm 的路在有限时长里天然有 ±1 帧的取整；G2 报告里另按精确速率核算（ceil(K·|1−r/P|) + 1 帧相位余量）。两种口径都列了，请定哪种进 §4。
7. **录制封口的边界**：`Recorder.stop(atTick:)` 的 nil 语义（"此刻"）在音频实时到达时会拖死（问题单 `G2-w1-outputs-stop-with-live-audio.md`）。建议契约层面（CONTRACTS.md §7 消费者一节）写明"停止要给拍边界，音频裁到该拍"。

## 8. 人工检查（用户做，落地方案 §4 G2）

- [ ] QuickTime 打开 `.build/gate2/10min/out.mov`：帧号块在走、输入色块每 30 s 随 Cut 变化、5:00 处一次 Fade、闪光每秒一次（右上角）。
- [ ] `tail -f .build/gate2/10min/stats.jsonl`：每秒一行、字段齐（ts、tick、render_ms、missed_render、jitter_ms、per_input、encoder、audio、rss_mb、cpu_pct、gpu_pct）。
- [ ] `--preview` 窗口画面与文件一致（G2 已验证窗口能开、12 s 跑满 720 拍退出 0；画面对不对要人眼看）：`.build/release/switcher-headless run --show scenarios/m0-show.json --script scenarios/m0.json --duration 60 --preview --audio-device null`（二进制路径：`swift build -c release --package-path Tools/switcher-headless --show-bin-path`）。
- [ ] 活动监视器看 10 分钟内存平（stats.jsonl 的 rss_mb 一列也能看）。
- [ ] `make gate2-1h` 跑 60 分钟版，结果自动并入 reports/G2.md。

## 9. 下一个会话需要知道的坑

- **合成源的帧相位**：`SyntheticVideoInput` 的 pts = 时间线 t0 + n × T；t0 和节目 t0 相同时每一帧都贴着拍点，任何到达抖动都会变成 dup / drop（±3 ms 抖动的路一半重复一半丢）。组装方要给视频时间线一个提前量（headless 默认半个节目帧，`--input-lead-ms`），音频 click 的时间线不提前。`Generator` 用的是 `SyntheticTimeline.frameRate` 而不是 `settings.frameRate`，每路要各建自己的时间线。
- **录制封口传拍边界**：`recorder.stop(atTick: 最后一拍 + 1)`，先 `engine.stop()`（渲染器会把在途帧派发完）再封口，封口期间音频源 / 泵 / 设备继续跑，封口完成后再停它们；视频源在 `engine.stop()` 之后立刻停（否则满槽被挤，dropped 多算）。用 `stop(atTick: nil)` 会拖成分钟级（问题单）。
- **Recorder 的入口环只有 256 块（1.4 s）**，writer 要等第一个压缩视频样本才建；录制器要在引擎起之前最后才 start，`--lead-ms` 别开太大。
- **`Engine.start` 里才 `renderer.prepare`**（着色器编译 + 纹理池），t0 要留 ≥ 0.5 s（headless 默认 1 s，摘要里打印"t0 距现在"，负数就是起晚了会跳拍）。
- **`ProgramClock.isRunning` 跑完 lastTick 后仍是 true**（线程对象不清空）；判结束用 `ticksDispatched + ticksSkipped >= 总拍数`。`NativeThread.join` 只能有一个调用方（`joined` 标志不是线程安全的），Ctrl-C 处理里别再 `clock.stop()`，设标志让主流程统一 `engine.stop()`。
- **状态机的 `schedule(_:at:)` 可以在 start 之前批量排程**（场景脚本），按拍应用，跳过的拍也逐拍走；`TickObserver` 的 isolated 参数形式也能用，但没必要。
- **`AudioBlockTap` 没有唤醒机制**，泵线程只能轮询（2 ms `usleep`，普通线程有 ms 级合并，64 块 ≈ 340 ms 余量够）。
- **`--audio-device default` 会从扬声器放 1 kHz −20 dBFS 正弦 + click**；自动化一律 `null`。
- **debug 构建的 headless CPU ≈ 110%**（8 路 1080p 合成源在 CPU 上画图案，每路一条实时线程）；S3 的 CPU 数含这部分测试工装开销，release 下低得多；gate 一律 release（`make gate2` 自己编）。
- **frameprobe debug 版慢 6 倍**（2700 帧 30 s），gate 脚本用 release。
- **IOKit GPU 占用**：`IORegistryEntryCreateCFProperty(service, "PerformanceStatistics")` 只读一个属性，别用 `CreateCFProperties` 全拷（3 ms）。
- **Bash 工具的 shell 是 zsh**：`$b:reports` 会被当成 `:r` 修饰符，写 `${b}:reports`；`rm -f dir/*` 没匹配会报错中断 `&&` 链。
- **机器负载**：跑实跑类测试和 gate 前先 `pgrep -x Cyberpunk2077` / `uptime`（gate2.sh 会打警告并记进 environment.txt）。
- **`check-ownership.sh` 对检查点分支**：只算自己的手改；`--include-working-tree` 现在是"工作树相对分支顶"。
