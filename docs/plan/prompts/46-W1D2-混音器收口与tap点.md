## 46 W1-D2 混音器收口 / 就绪年龄 / 耳机与 ISO tap 点（音频引擎续做）
分支：w1-audio-2（从 G3 合入后的 main 开）。只准动：Packages/SwitcherAudio/Sources/SwitcherAudio/、Packages/SwitcherAudio/Sources/CSwitcherAudioRT/、Packages/SwitcherAudio/Tests/SwitcherAudioTests/，
以及 Packages/SwitcherAudio/Sources/Integration/ 里对应的一两行跟改（W2-E 报告 §4 列的：`crossfade(durationFrames:)`、`maintainAlignment` 只补残差、ISO tap 来源、耳机不走对齐）。
先读：reports/issues/W2E-w1-audio-crossfade-tail-block-duration-monitor.md；reports/issues/W2E-g3-pending-changes-checklist.md 的 3-1…3-5 与第四节；reports/w2-audio-integ.md §4 第 1、3、4 条；
设计方案 §3.5、§7；测试标准 A5 / A7。热路径规则不变：回调内无锁、无分配、无日志、无系统调用，C 写，`check-rt-symbols` 必须绿。

背景：W2-E 集成时发现五件事都在 W1-D 的 C 混音器里：交叉淡变只收整块时长（尾巴 0.5–0.9 dB）、走满时写的 afv 被最后一个曲线样本覆盖（Cut 后 −44 dB 尾巴）、就绪年龄有 [0, 256) 帧随机相位、
耳机总线也经过对齐延迟线（A5 ≤ 20 ms 与节目对齐二选一）、输入 tap 在 AFV 增益之后（AFV 开着时非 PGM 的 ISO 音轨静音）。

交付：
1. `SW_CMD_CROSSFADE` 收帧数（或另加帧数命令）；Swift 端 `crossfade(from:to:durationFrames:startHostTime:)`；Integration 的 `durationBlocks:` 改 `durationFrames:`。
2. 淡变走满时 afv 写 0 / 1 不再被 `sw_process_input` 的最后一个曲线样本覆盖（最后一个样本 p 用 (elapsed + i + 1) / dur，或把"走满 → 写 afv"移到之后）。
3. `SW_CMD_ATTACH_INPUT` 带"目标年龄"：就绪时从 host_time − 目标年龄 对应的帧起消费；Integration 的 `maintainAlignment` 只补残差。
4. 耳机总线可绕过对齐延迟线（延迟线前 / 后可选，默认前 = 低延迟监听）；Integration 里耳机不走对齐，A5 脚本改回默认对齐配置。
5. 输入 tap 加"推子后、AFV 前"来源（ISO 音轨用）；Integration 的 ISO tap 换来源。

测试（函数名带 ID，SwitcherAudioTests + IntegrationTests 里对应用例的判据收紧）：
- AFV Fade 30 拍逐块电平与 cos / sin 曲线误差 ≤ 0.5 dB 一直判到 −40 dB（现在只能判到 −20 dB）；Cut 之后 from 路下一块起严格为 0。
- 就绪年龄 = 目标 ± 1 块（10 次重就绪）；对齐延迟线残差 ≤ 1 块。
- A5：有回环硬件时 `testA5_monitorLatency_loopback` 在默认对齐配置下 ≤ 20 ms（目标 12）；没有硬件 XCTSkip 注明 BLOCKED-硬件。
- ISO tap：AFV 开、非 PGM 路的 ISO 音轨有信号，且含推子增益 / 静音。
- A7：W1-D 的 10 分钟离线 + 真设备 1 分钟实时用例 0 违规；`scripts/check-rt-symbols.sh` 绿；SwitcherAudio 全包 `swift test` 绿（含 W2-E 的 35 个）。

不做：效果链、每路 AFV 开关（契约没有；要的话写提案）。
报告 reports/w1-audio-2.md：每条的前后数字、C 侧改了哪些命令。
