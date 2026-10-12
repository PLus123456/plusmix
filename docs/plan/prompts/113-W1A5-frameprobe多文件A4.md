## 113 W1-A5 frameprobe 多文件 A4 的半秒平局 + 漏检一条 click（G8b gate4 误报 999.979 ms；现在就能开，小）
分支：w1-testkit-5（从 G8b 合入后的 main 开）。只准动：Packages/SwitcherTestKit/、Tools/frameprobe/、Tests/Fixtures/（同 W1-A 那一行）。
先读：reports/issues/G8b-w1-testkit-frameprobe-a4-halfsecond-click-tie.md（现象、复现、建议）；Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/FrameAnalysis.swift:618–670（`avMulti`）与 `av` 的 click 配对、`ClickEvent` 检测窗；reports/G8.md §4.3 第 10 条、§5 L2 的 A4 行；G8 的产物 `.build/gate4/g8/probe-av-multi.json` / out.mov + out.iso1–4.mov（本机 g8 worktree 里，不入库，可直接重算）；reports/issues/W1B4-w1-testkit-frameprobe-delayed-video-start.md（`--start-tick` 那张）。

交付（先写红测试）：
1. `avMulti`：以第一个文件（PGM）配到的 click 为锚，其他文件取离这个锚最近的 click（容差 ≤ 1 帧）；或统一"闪光之后第一个 click"，平局时各文件一致。用例：造五份合成序列，其中一份 click 整体晚 20 µs、闪光落在半秒 → click 极差 ≈ 0.02 ms 而不是 1 s。
2. 闪光落在半秒的事件（|flash − round(flash)| ≈ 0.5）在 A4 只列不判（A2 本来就按整秒配对过滤）。
3. iso3 第 500 s 的 click 漏检（+20 µs 落到检测窗边上）：看 `ClickEvent` 检测窗的对齐，用例一条。
4. 顺手：`frameprobe av --start-tick` 的说明改成"开录起点已按输出时间线（G8b），默认 0 就对；只在录制中途改了 Master 效果（L 变了）时才要给"；W1B4 那张 frameprobe 问题单末尾写处理结果。
5. 用 G8 的产物重算一遍 A4 写进报告（应 ≈ 0.19 ms）；TestKit / frameprobe 用例全过、`make lint BRANCH=w1-testkit-5`。

不做：阈值；gate4 流程 / 脚本（scripts/ 归检查点，G9 看到 A4 不再红就把 waive 撤了）。
报告 reports/w1-testkit-5.md 五段；不 push、不 merge，做完告诉 G9（prompt 114）。
