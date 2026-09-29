## 90 W5-E 转场进行中拒收 setPreview / setProgram（Q66 默认 (a)；第五波 · 止血；用户 2026-09-29 批开）
分支：w5-core-transition-guard（从 main 开）。只准动：Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift、Packages/SwitcherCore/Tests/SwitcherEngineTests/ReducerTests.swift；提案文件 docs/contract-changes/（所有分支都允许）。
先读：reports/issues/UIA-w1-core-preview-program-change-mid-transition.md；docs/ui-study/04-待拍板.md Q66；MixerReducer.swift:97-105（autoTransition 有 `guard !s.transition.isActive`，setPreview / setProgram 没有）；Packages/SwitcherCore/Sources/SwitcherRender/Renderer/CompositorPasses.swift:246-256（转场中按当前 program / preview 画）；docs/CONTRACTS.md 里 Command 的 reducer 规则表；测试标准 §1 V6。

背景：Fade / Wipe / Zoom / Stinger 进行中按数字键或点缩略图会把正在切进来的画面换掉，Shift + 点会换掉正在切出去的底图，PGM 上是可见跳变。用户 2026-09-29 按 04 的建议定 (a)：转场中拒收这两条命令，与 autoTransition / fade / setTransition 同一口径（applied = false，API 客户端收到"被拒"）。

交付：
1. reducer：`.setPreview` / `.setProgram` 在 `s.transition.isActive` 时原样返回 state（不改任何字段）；T-bar 手动转场推到一半算不算 active，按现有 isActive 的定义写清楚；不包含就补进去并说明。
2. 契约语义那一句不自己改 docs/CONTRACTS.md：写 docs/contract-changes/023-小口径收口.md 的"转场进行中 setPreview / setProgram 拒收"一节（这份提案还会由 99 P5 装进 container 废弃 / effects 口径 / InputConfig.color 三项；文件不存在就建、存在就追加），然后停下来问用户。
3. 报告里给 App 的提示：格子上以后的"转场 / Cut"按钮（94）和 Shift 点击在转场中应置灰或提示"转场进行中"，reducer 已兜底。

测试（函数名带 ID）：`testV6_setPreviewRejectedDuringTransition`（Fade 30 拍进行到第 10 拍发 setPreview(3)，快照 preview 仍是 2、转场结束后 program == 2）、`testV6_setProgramRejectedDuringTransition`、`testV6_setPreviewAcceptedAfterTransitionCompletes`、`testV6_tbarPartialCountsAsActive`（若口径如此）；ReducerTests 与 SwitcherEngine 全包 `swift test` 绿；`make gate4-run` 一次 V6 仍过。
不做：选项 (b)"收下延后生效"（要契约字段）、渲染器、App。报告 reports/w5-core-transition-guard.md（五段）。不 push、不 merge。
