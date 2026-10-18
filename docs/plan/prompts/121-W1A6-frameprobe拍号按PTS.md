## 121 W1-A6 frameprobe 转场拍号按 PTS 算 + A4 缺 click 判不过（Codex T02 + 用户 2026-10-17 对 113 的裁定；G9 合入后现在就能开，小）
分支：w1-testkit-6（从 G9 合入后的 main 开）。只准动：Packages/SwitcherTestKit/、Tools/frameprobe/、Tests/Fixtures/。
先读：reports/codex-debug-audit-20261013.md §1.5 T02（数组下标当拍号：正确的第 60 拍 Cut，前面第 20 / 30 拍各删一帧就报 tick 58；30 拍 Fade 被判 2 帧偏差）；Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/FrameAnalysis.swift:234 与 Fade / Wipe / Zoom 的分析；reports/w1-testkit-5.md §3 第 2 条 / §4（缺 click 的口径——用户定：判定事件里有文件缺 click = A4 不过；±1 帧带宽维持）、§5 第 2–4 条（锚、perFile 与 events 别混、按序号对齐的退路）；docs/spec/导播台测试标准.md §2.3（G9 已按裁定补了多文件 A4 的口径一条）；reports/issues/W1B4-w1-testkit-frameprobe-delayed-video-start.md（拍号来源 (pts − pts0) × fps 不改的理由：只改转场分析用数组下标那一半）。

交付（先写红测试）：
1. **T02**：Cut / Fade / Wipe / Zoom 分析按 PTS 换算的节目拍号判转场落点，缺帧单独报（`missingFrames` 列表 + 数量），不再把数组 index 当 tick。用例：正确的第 60 拍 Cut，前面第 20 / 30 拍各删一帧 → 仍报 tick 60 + 缺 2 帧；30 拍 Fade 删帧后仍 0 偏差。gate4 / G8 的产物重算一遍（V6 / V7 数字不变，报告写）。
2. **A4 缺 click**：判定事件里某个文件在锚 ±0.5 s 内没有 click → `passA4 = false`、事件列出哪个文件缺（原来那一格 nil、极差只算剩下的）；半秒事件照旧只列不判；`gate3-report.py` 读的字段名不变。用例一条。
3. `swift test --package-path Packages/SwitcherTestKit`、frameprobe 用例、`make lint BRANCH=w1-testkit-6`。

不做：拍号来源（pts0 / 逐帧累加）的改法；阈值；gate 脚本（归 G10）。
报告 reports/w1-testkit-6.md 五段；不 push、不 merge，做完交 G10（prompt 122）。

**G9 追加（2026-10-18）**：Opus 5.5 子代理做完、未合并——`w1-testkit-6` = 8e96883，报告 reports/w1-testkit-6.md，等 G10（122）合入。用户 2026-10-18 裁定（reports/G9.md §7.4 表）：§4 四条裁定：全无 click 的事件不算缺、Cut 前一拍漏帧只标 + 报漏帧、V7 只判有样本的拍——维持；缺闪光算 A4 不过——G10 胶水（TestKit ≤ 30 行）。gate3-report.py 看 passA4 归 G10（问题单 W1A6-g10-gate3-report-a4-reads-passA4）。
