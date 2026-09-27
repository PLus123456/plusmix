## 73 W3-E4 App 收尾三：第三批合入后剩下的几处 App 小活（视 2026-09-27 的裁定删减；可与 W4 三路并行）
分支：w3-app-5（从 G4 第三批续做合入后的 main 开）。只准动：App/。
先读：reports/w3-app-4.md §3 / §4 / §5；reports/p4-contracts.md §3 第 5 条；issues W3E3-virtual-camera-source-picker-ignored、P4-w3-app-4-legacy-layout-thumbnail-test 的"顺带"一节；提案 019（若批）。

背景：W3-E3 做完 NDI 发送接线 / 层级开关 / 记账 / 电平表之后，还剩几处一两个用例大小的活：一处界面与行为不一致（虚拟摄像头页的来源下拉）、两处死路径、一个测试辅助的小 bug，
以及提案 019 若批之后 App 要跟的读法与文案。都太小，不值得再开一个整期，合成一个短会话。

交付（按裁定删减，每条一个用例）：
1. **虚拟摄像头页的"来源"下拉**（issue W3E3-virtual-camera-source-picker-ignored）：按裁定——选 (2) 就去掉下拉、页面写明"送 PGM"（设计方案 §2 / §3 的数据流）；选 (1) 的话等输出会话把 `VirtualCameraOutput` 改成按来源挑帧之后再接线（不在本会话）。
2. `OutputSettingsPanel` 的 `setExternalDisplay` / `setExternalFallback` 里两处 `migratingLegacyKeys()` 与第 221 行注释：P4 之后状态里不会再有输出的过渡键（addOutput / setOutputSettings / loadShow 都先搬迁），这两处是死路径，删掉（P4 报告 §3 第 5 条、§5 第 5 条）。
3. `AppTest.chineseLiteralViolations` 的 `// l10n-exempt` 标记：先剥注释再找标记，所以从来不起作用（reports/w3-outputs-4.md §5 第 6 条）——修成先看标记，或者删掉那句说明；二选一写明。
4. 提案 019 若批：`OutputRuntime.encoderEntry(for:)` 改按 `Stats.EncoderEntry.output` 找（不再按顺序对号，W3-E3 §4 第 2 条的错一拍就没了）；NDI 页显示接收方数（`connections`）；state = failed 的文案（两种语言各一键，与 unavailable 分开：一个是"装 SDK"、一个是"看日志"）。
5. （可选）源是输入 n 的 NDI 发送在那一路分支用完时只提示一次、之后空出来也不补（W3-E3 §3 第 2 条）：InputRuntime 还分支时通知一次、sender 重新要分支；不做就把"关开一次"的提示写进状态行。

测试（函数名带 ID）：1–4 各一条；全量 `make test-app` 在空机器上跑两轮（先 `pgrep -fl "xcodebuild .*test"` 确认没有别的会话在跑 App 测试）。
不做：包与契约（019 的契约与填数由检查点或 P5 落地）、CameraExtension。
报告 reports/w3-app-5.md。
