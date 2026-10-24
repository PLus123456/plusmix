# 测试

直播软件的质量只有三件事：**不掉帧、不失步、不崩**。PlusMix 把它们变成能量、能自动跑、能跨版本比的指标，测法和阈值全部公开，
每次检查点的报告也入库——你可以自己跑一遍，也可以对照报告决定这个版本值不值得上场。English summary: [en/](en/README.md).

| 文档 | 内容 |
|---|---|
| [测试标准（公开版）](测试标准.md) | 指标定义（V 视频 / A 音频 / E 编码录制推流 / L 延迟 / S 稳定性 / C 控制接口）、测试信号与工装、每个指标的测法、必须 / 目标两档阈值、测试层级、缺陷分级与发布门槛、`stats.jsonl` 字段 |
| [设备兼容性](设备兼容性.md) | 已验证的设备与提交模板（型号、固件、macOS、通过项） |
| 本页 §2 | 每次检查点（G2 → G10）报告的索引 |

内部版本（含各会话的口径讨论与修订记录）在 [docs/spec/导播台测试标准.md](../spec/导播台测试标准.md)；两者阈值相同，公开版只是去掉了内部引用。**阈值只有项目维护者能改**，任何会话不得为了让测试通过放宽阈值。

## 1. 自己跑

```bash
make test
```

六个包的单元 / 组件测试 + 两个命令行工具冒烟 + App 的 `xcodebuild test`（G10 时：六包 984 个用例、App 296 个；DeckLink 实卡、外接屏、签名相关的用例没有条件时 `XCTSkip` 并注明 BLOCKED-硬件 / BLOCKED-SDK / BLOCKED-签名）。

10 分钟的集成场景（L2：V1–V7、A1–A4、E1–E3、E5、C1–C4，出报告 `reports/G4-run-10min.md`）：

```bash
make gate4
```

跑之前机器上不要有别的占 GPU 的程序、接电源；`make gate4-1h` 是 60 分钟版，`make gate4-ndi` 是 NDI 回环的内部延迟，`make gate4-matrix` 是三种 SDK 配置的编译矩阵。
推流的 E7–E9 要网络损伤：另一个终端 `sudo scripts/netem.sh serve`，再 `make gate3-net`。

分析一个录制文件（帧号、切换、A/V 偏移）：

```bash
swift build -c release --package-path Tools/frameprobe && Tools/frameprobe/.build/release/frameprobe stats Tests/Fixtures/w1a-sample-20s.mov --input-fps 0=60,1=30 --markdown
```

几条读结果时要知道的（全文在[测试标准 §2.3](测试标准.md#23-frameprobe分析工具)）：

- `switches` / `fade` 的转场落点按 PTS 换算成节目拍号，文件里漏了帧时后面的落点不挪，漏掉的拍单独列在 `missingFrames` / `missingFrameCount`（每条切换另有 `missingBetween`）；它们的帧率只认 `--fps`，没给就按相邻帧的 PTS 差估。
- `av` / `wipe` / `zoom` / `stats` 没给 `--fps` 时用容器的标称帧率，漏了帧的文件上它偏低：量这种文件一律带 `--fps 60`（或节目的帧率）。
- 多文件 `av`（A4）：某个判定事件里有文件缺 click 或缺闪光，`passA4` 就是 false——只看 `maxClickSpreadMs` / `maxFlashSpreadMs` 会漏掉这种情况（缺的那一格不进极差）。

## 2. 检查点报告

每个里程碑合并后由一个检查点会话跑门槛测试、写报告（[测试标准 §7](测试标准.md#7-报告模板)的固定字段）。数据文件（stats.jsonl、录像）不入库，报告里写本机路径。

| 检查点 | 日期 | 范围 | 结论 | 报告 |
|---|---|---|---|---|
| G2 | 2026-09-15 | M0 核心循环：8 路合成源 → 帧槽 → Metal 合成 → NV12 → H.264 → .mov，10 分钟 + 60 分钟 | **通过**（含 1 项按参考线精神放行）；V4 曾不过，退回修到达余量后复测通过 | [reports/G2.md](../../reports/G2.md)、[G2-notes](../../reports/G2-notes.md)、[10min](../../reports/G2-run-10min.md) / [1h](../../reports/G2-run-1h.md) |
| G3 | 2026-09-18 | M1 切换 + M2 音频 + M3 输出 + M5 控制：V6 / V7、A1–A4 / A6 / A7、E1–E3、C1–C4，E7–E9 网络损伤 | **通过**：19 项自动判定 18 通过、E2 本场景不适用（专项用例通过）；E7 / E8 / E9 3 / 3 通过 | [reports/G3.md](../../reports/G3.md)、[G3-notes](../../reports/G3-notes.md)、[G3-net](../../reports/G3-net.md)、[人工清单](../checklists/G3.md) |
| G4 | 2026-09-20 → 09-27 | M4 输入二期（DeckLink / NDI / 纯音频）+ M6 叠加、五种转场、抠像、多画面、外部输出、虚拟摄像头、ISO；四轮续做合入 | **自动项通过**（最近一次 g4g：20 项 ✅，V1 avg 2.06 ms、V2 0、V4 设计外 0、A2 0.000 ms、A4 0.208 ms、C1 50 / 50）；人工项与 BLOCKED 项见清单 | [reports/G4.md](../../reports/G4.md)、[G4-notes](../../reports/G4-notes.md)、[G4-ndi](../../reports/G4-ndi.md)、[G4-matrix](../../reports/G4-matrix.md)、[人工清单](../checklists/G4.md) |
| G5 | 2026-09-28 | 发布门槛：8 小时长稳（S1–S3）、设备矩阵 L3、性能回归 L5、已知问题列表 | **0.1.0 不发**：L4 8 小时 S2 红（文件输入泄漏，已修待复验）、L3 有一条 S1 且设备矩阵缺一半、公证 / 更新源 BLOCKED-账号 | [reports/G5.md](../../reports/G5.md) |
| G6 | 2026-10-02 | 第五波止血五路（目视、直播安全、总线效果、推流鉴权、转场中拒收）合入、0.1.0 重判 | **0.1.0 仍不发**；L2 自动项 20 / 20，六包 766 用例、App 144 用例 | [reports/G6.md](../../reports/G6.md) |
| G7 | 2026-10-04 → 10-10 | 第五波骨架七路（底栏、工具条、输入条、输出页、设置窗、面板、防睡眠 / tally / 远程控制 / 提醒 / 统计 / 锁）合入 | **0.1.0 不发，也不建议发 0.1.1**（MIDIHost.sync 崩溃、8 小时复验、签名等）；L0 / L1 六包 777 用例、App 228 用例 0 红，L2 20 / 20 | [reports/G7.md](../../reports/G7.md) |
| G8 | 2026-10-10 → 10-12 | 契约落地（转场槽、文件播放、状态统计）+ MIDIHost 崩溃修复 + 监听同步合入（G8a），再合转场槽界面、播放控制与推流 / 录制状态窗、每路音频效果、随包手册（G8b） | **0.1.1 还不发**：只差 L3 人工清单与签名公证；8 小时长稳 10-12 复验通过（S2 2.46 MB/h）；六包 861 用例 0 产品红（1 条桌面忙时的计时用例环境红）、App 244 用例 0 红，gate4 自动项全过、性能无退步 | [reports/G8.md](../../reports/G8.md)、[人工清单](../checklists/G8.md) |
| G9 | 2026-10-17 → 10-18 | 续做五路（契约三、App 续做、推流鉴权停、frameprobe A4 半秒、手册续做二）合入；外部 debug 审查 22 条进已知问题 | **0.1.1 不发**：审查查出 S0 / S1（文件参数崩、兼容层崩、音频环覆盖、保存写错文件、开录删旧录像等），止血七路排上；六包 883 用例 0 红、App 263 用例 0 产品红，gate4 自动项全过、A4 不再豁免 | [reports/G9.md](../../reports/G9.md)、[人工清单](../checklists/G9.md) |
| G10 | 2026-10-19 | 止血七路（契约四、文件输入、控制层、输出、核心音频收口、frameprobe 拍号、App 止血）+ 胶水七条合入 | **0.1.1 不发**：唯一的 S1 是"输入编号没有上限"（排到下一批），L3 人工清单与 8 小时长稳没跑；六包 984 用例 0 红、App 两遍 296 用例 0 红，gate4 自动项全过、性能无退步 | [reports/G10.md](../../reports/G10.md)、[人工清单](../checklists/G10.md) |

每个功能会话也有自己的报告（`reports/<分支>.md`，五段固定格式），退回的问题单在 [reports/issues/](../../reports/issues/)。

## 3. 基线

`baselines/*.json` 是每个检查点在参考机（Apple M5 Max，接电源）上的 L5 数字；下一版本与它比，退步超过 10% 阻塞合并。
参考机上的绝对值（例如 V1 平均 2 ms）不是阈值，只是参考线；阈值在测试标准 §4，按 M1 MacBook Air 8 GB 定。

## 4. 报问题

附上：PlusMix 版本 / 提交号、机型与 macOS、`stats.jsonl`（`--stats` 或 API 的 `stats`）、能复现的节目文件（去掉推流密钥），能用无界面引擎复现最好（[故障排查 §9](../user/故障排查.md#9-日志与诊断)）。
