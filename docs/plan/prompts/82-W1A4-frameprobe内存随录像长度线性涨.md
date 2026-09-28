## 82 W1-A4 frameprobe av 的内存随录像帧数线性涨（用户 2026-09-28 指派 agent 直接做）
分支：w1-testkit-4（从 main 开）。只准动：Packages/SwitcherTestKit/、Tools/frameprobe/。
先读：reports/issues/W4A-w1-testkit-frameprobe-memory-grows-with-length.md、reports/w4-soak.md §5 第 10 条。

交付：
1. 先写红测试：对一段 ≥ 1 分钟的合成录像（现场用 TestKit 的合成源 + AVAssetWriter 造）跑 `frameprobe av --discontinuities` 等价的 API，峰值 phys_footprint 与帧数无关（例如 1 分钟与 3 分钟峰值之差 < 100 MB）；修前红（约 210 KB / 帧）。
2. 修：`MediaReader.readVideo` / `readAudio` 的循环体包 `autoreleasepool`（每帧一次），其余按需释放；命令行工具的其它长循环同查。
3. 验证：`/usr/bin/time -l` 跑 10 分钟录像峰值 RSS（修前 7.6 GB）写进报告；TestKit + frameprobe 全部用例过；`make lint BRANCH=w1-testkit-4`。
修好之后 scripts/soak/soak.sh 的 5 分钟切段可以撤，但那是 W4-A 的目录，报告里提一句即可。报告 reports/w1-testkit-4.md。不 push、不 merge。
