## 65 W3-C2 Aux 输入的全分辨率画面 + 显示类输出 Stats 填数复核（输出续做）
分支：w3-outputs-3（从 P3 / prompt 61 合入后的 main 开——要读 013 的 `Stats.display[]` / `OutputSettings.display`）。只准动：Packages/SwitcherOutputs/Sources/External/、Packages/SwitcherOutputs/Tests/ExternalTests/、
Packages/SwitcherOutputs/Sources/VirtualCamera/、Packages/SwitcherOutputs/Tests/VirtualCameraTests/。
先读：reports/w3-outputs2.md §3 第 1 / 5 / 6 条、§4 第 1 / 2 / 5 条；reports/p3-contracts.md §3 第 3 条、§4 第 1 / 2 条；docs/contract-changes/015；reports/G4.md §8 第 5 条（用户 2026-09-22 裁定）；docs/contract-changes/013；reports/p3-contracts.md（013 的填数落到了哪一步）；docs/CONTRACTS.md §2.3（帧槽的读入口）。

裁定（G4 拟、用户 2026-09-22 批）：**Aux 全分辨率由本包自己画输入帧**——外部显示选"输入 n"时用 CVMetalTextureCache 直接画该路帧槽里的最新帧（NV12 / BGRA 两种像素格式，色彩换算与渲染器同一套系数），
不再用多画面纹理里它的格子；不加 `RenderedFrame` 字段、不给渲染线程加每路全分辨率目标（渲染线程零分配与 V1 预算优先）。抠像 / 裁切 / 变换在 Aux 上不生效，文案上注明"Aux = 原始画面"。

交付：
1. `ExternalDisplayManager`：source = input(n) 的窗口每次显示刷新用帧槽的契约读入口取该输入最新帧（不走引擎的 `latest(forTick:)`，不动到达余量的统计），全幅画到窗口；输入无信号时画占位（与多画面格子同一套文案）；
   主线程不做像素工作，纹理缓存按输入编号预建、换输入时重建。
2. `Stats.display[]` 的填数复核（013）：P3 若只填了 frames / state，补 dropped（没赶上显示刷新的帧 = 引擎给了新帧但两次刷新间被覆盖的次数）与 noDisplay / waitingExtension 细分状态；虚拟摄像头的 dropped 从扩展的丢弃计数来（BLOCKED-签名时写清楚怎么读）。
3. 外部显示窗口的层级（W3-C §3 第 5 条）：加"主屏上开时不盖住主界面"的选项（`OutputSettings.display` 之外的包内选项，默认行为不变）。
4. 删过渡键后备读取（P3 报告 §4 第 1 条）：`ExternalDisplaySpec` 只读 `OutputSettings.display`，不再看 `extra["displayID"]` / `["fallbackToMain"]`（`Show.load` 已把旧键搬进正式字段）；P3 的 `testP3_013_specRoundTripsThroughOfficialDisplayField` 里"过渡键作后备"那一半改成"旧键被忽略"。
   `fallbackToMain` 的默认值（契约 true、W3-C 运行时 false，P3 报告 §4 第 2 条）以提案 015 的结论为准，落地前保持 App 显式写 false。

测试（函数名带 ID）：
- `testAux_inputWindowDrawsFullResolutionFrame`：离屏——1080p 合成源 → 外部显示纹理逐像素 = 输入帧（不是缩略格子）；NV12 与 BGRA 各一次；
- `testAux_noSignalDrawsPlaceholder`；
- `testStats_displayEntriesCountPresentedFrames`：10 s 内 frames 单调递增、dropped 0（无负载）、state = presenting；拔显示器（模拟：目标显示器 ID 不存在）→ noDisplay；
- 外接屏上的 L2（BLOCKED-硬件，人工步骤写进 docs/checklists 的下一版）。

不做：渲染器改动（W1-C / W3-B 的地盘）、虚拟摄像头激活（BLOCKED-签名不变）、界面（63）。
报告 reports/w3-outputs-3.md。
