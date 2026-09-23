## 68 W3-E3 App 收尾：NDI 发送接线、Aux 文案与主屏层级开关、显示类窗口的丢帧记账、电平表统一（界面续做）
分支：w3-app-4（从 G4 第二批续做合入后的 main 开；P4 若已合入更好，不依赖）。只准动：App/。
先读：reports/w3-app-3.md §3 第 3 条、§4、§5；reports/issues/W3C2-app-aux-wiring.md §3 / §5；reports/issues/W3B2-w3-app-3-multiview-meters-thumbnails.md；reports/w3-compositor-3.md §1.1（setMeters 的线程与频率）、§4 第 2 条；
reports/w3-outputs2.md §1（NDI 发送在包里的接口）与 reports/w2-stream.md（NDISender）；reports/G4.md §11（检查点接了哪些、留了哪些）。

背景：G4 第二批合入时检查点只接了最小胶水——Aux 三根线、1 Hz 的 `setMeters`、虚拟摄像头文案读 undelivered、外部输出测试第 3 步；界面上的事与更活的喂法留给本会话。App 里 NDI 发送从 W3-C 起一直没接（`OutputRuntime` 的 `.ndi` 只给 Stats 占 idle）。

交付：
1. **NDI 发送接线**：`OutputRuntime` 的 kind = ndi 输出按 `enabled` 起停 `NDISender`（PGM / PVW / 多画面 / 输入 n 按 `source`；PVW / 多画面帧由渲染器按状态自动填、开头可能缺一两帧），Stats.encoder 那一项由 sender 的 `statsEntry` 填；输出设置 NDI 页的名字 / 源 / 开关生效；`--ndi-send` 在 headless 的做法可参考。
2. **Aux 文案与主屏层级**：外部输出菜单 / 外部显示设置页"输入 n"加"Aux = 原始画面（抠像 / 裁切 / 变换不生效）"说明；偏好设置加"外部输出在主屏上不盖住主界面"开关 → `ExternalDisplayManager.mainScreenLayering`（UserDefaults 键自定，不进 OutputSettings）。
3. **监视器 / 多画面窗口的 dropped 走 `DisplayFrameLedger`**（W3-C2 提供的记账源，夹在渲染器与 `MetalDisplayView` 之间）：`MainWindowController.displayStatsEntries` 不再用 noDrawable 近似；窗口收起 / 被遮住时 `breakRun()`；多画面窗口关着 = 不报或 idle。
4. **电平表**：50 ms 一份 `Stats.AudioCounters.Meters`（按调音台同一份 `AudioEngineStatus` 拼）喂 `renderer.setMeters`，替掉检查点的 1 Hz；三处电平表（调音台 MeterBar、纯音频缩略图 NSLevelIndicator、多画面）的颜色分段统一成用户定的那套（默认按 W3-B2 的 −18 黄 / −6 红，用户改了就按用户的）。
5. **缩略图名字出现两次**：缩略图切掉内框底部的名字条（高 = 格高 × 14%，≤ 画面高 × 3.5%）或标题条不重复名字，二选一并写明。
6. **删 App 侧过渡键后备**：`OutputExtras.displayNumber(of:)` 不再读 `extra["displayID"]`（包与契约都已不读）。
7. **UISmokeTests 那条 61 / 60 的偶发**：按用户选的做法改（(a) 冒烟开头清零计数、只量本条；(b) 按 Timer 触发序号数）；用户没选就默认 (a) 并写明。

测试（函数名带 ID）：NDI 发送在本机回环收到 PGM（有 SDK 时；没有则 XCTSkip BLOCKED-SDK）；主屏层级开关落到 `mainScreenLayering`；`displayStatsEntries` 的 dropped 与 ledger 同源；`setMeters` 50 ms 喂数时渲染线程仍零分配（渲染器已有用例，这里只验调用频率与线程）；缩略图不再有两处名字（像素扫描名字条区域）。
不做：包与契约（P4 / W3-C3）、CameraExtension。
报告 reports/w3-app-4.md。
