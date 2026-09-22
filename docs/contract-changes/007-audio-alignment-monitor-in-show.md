# 007 AudioState 加对齐延迟与监听点；CONTRACTS.md 三条口径说明

提出会话 / 分支：G3 / g3（检查点，2026-09-19 合入续做分支时；来源 W2-E 报告 §4 第 1 条、W1-D2 报告 §4 第 2 条、W2-B2 报告 §4 第 2 / 8 条、W1-E2 报告 §5 第 1 条、G2 报告 §7 第 7 条）
状态：**已批**（用户 2026-09-22，按 G4 报告 §8 第 2 条一次批了 007 / 008 / 009 / 010 / 012。G3 2026-09-19 建议批；由契约会话 P3（docs/plan/prompts/61，分支 p3-contracts）落地：A 加两个字段，B 三条口径进 CONTRACTS.md；设置面板归 W3-E2 / prompt 63）。

## A. 改什么（类型）

`AudioState`（MixerState.swift）加两个字段，都带默认值，老 Show 文件 / 老快照缺字段按默认解：

- `alignmentFrames: Int = 2048`：节目音频相对采集的对齐延迟（48 kHz 帧；2048 = 42.67 ms = 现在 `AudioEngineConfiguration.alignmentFrames` 的默认）。它决定"节目音频比视频晚多少"，与视频内部延迟（≈ 3 帧）同量级，要按场合改（低延迟监听 vs 大块生产者）。
- `monitorPoint: MonitorPoint = .preDelayLine`：耳机 / 监听总线取对齐延迟线之前（低延迟监听，默认；W1-D2 的 `SW_CMD_MONITOR_POINT`）还是之后（与节目画面对齐）。`public enum MonitorPoint: String, Codable, Sendable { case preDelayLine, postDelayLine }`。

Command 不加：两项是设置，走 `loadShow` / 设置面板改 Show 后重建音频引擎（运行期改要重建延迟线，W1-D 没做运行期改，也不需要）。就绪目标年龄不进 Show（集成层按 min(确定最小值, alignmentFrames) 推，W1-D2 报告 §4 第 3 条）。

## 为什么

- W2-E §4 第 1 条：`alignmentFrames` 只在 `AudioEngineConfiguration` 里，Show 存不下，用户按场合改不了；A5（≤ 20 ms）与节目对齐的取舍就是这一项。
- W1-D2 §4 第 2 条：监听点同理，它决定"耳机里听到的和画面对不对得上"。

## 影响谁

App（W3-E 设置面板读写；`AudioRuntime` 建引擎时从 Show 取）、headless（现在的 `--audio-*` 参数保留为覆盖，默认从 show 读）、API `/state` 与 StateFeed 快照（多两个字段）、SwitcherContractsTests（Codable 往返 + 键名快照）。W1-D / W2-E 的引擎代码不动。

## B. 文档口径（只改 docs/CONTRACTS.md 的文字，不改类型）

1. **`OutputState.enabled`**：Show 文件里的 enabled 只对 headless 的场景文件生效（t0 起录 / 起推）；App 打开任何节目文件（含退出时自动存的 LastSession）时把 record / stream 的 enabled 清掉，输出只由用户动作（按钮 / 快捷键 / API）起。App 已实现（`ShowDocuments.stoppingOutputs`，G3 2026-09-19，W2-B2 报告 §4 第 2 条）。
2. **`RecordSettings.directory` 的相对路径**：headless 相对进程工作目录；App 相对 `~/Movies/Switcher`（W2-B2 已实现，报告 §4 第 8 条）。写进字段注释。
3. **录制器的停止边界**（消费者一节）：`Recorder.stop(atTick:)` 给拍边界，两轨都由录制器裁到该拍点，越界块只计数不写；边界可以在到达之前预告（`setStopTick`）；nil = 最后一个已收帧的下一拍。W1-E2 已实现（报告 §1 第 3 条）；G2 报告 §7 第 7 条的疑问到此结束。

## 怎么迁移

A 加字段带默认值，老文件原样可解；Stats / Command 不动；契约测试加两个字段的往返与键名快照。B 只是文字。
