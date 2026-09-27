# W3E3 → W3-C3（w3-outputs-4）/ 合并它的检查点：虚拟摄像头设置页能选来源，但输出恒为 PGM

发现于：W3-E3（prompt 68，分支 w3-app-4，2026-09-27），读 SwitcherOutputs 的 NDI / 虚拟摄像头代码时看到；本会话只准动 App/，没改。
严重级：S3（界面与行为不一致；节目不受影响）

## 现象

- 输出设置 › 虚拟摄像头页有"来源"下拉（`OutputSettingsView.virtualCameraTab` 用的是通用的 `sourcePicker`：PGM / PVW / 多画面 / 各输入），
  选了会写进 `OutputState.settings.source`（`OutputSettingsModel.setVirtualCamera(enabled:source:)` → setOutputSettings）。
- 但 `VirtualCameraOutput`（`Packages/SwitcherOutputs/Sources/VirtualCamera/VirtualCameraOutput.swift` 约第 187 行）只发 `frame.program`，
  `AuxOutputRuntime` 建它时也不传来源——选 PVW / 多画面 / 输入 n 都照样出 PGM，界面没有任何提示。

## 两个改法（二选一，归属不同）

1. **包支持来源**（W3-C3 / 输出会话）：`VirtualCameraOutput` 按来源挑 `RenderedFrame.program / preview / multiview`（PVW / 多画面帧由渲染器按状态自动填，
   与 NDISender.consume 同一个挑法）；输入 n 走帧槽分支（App 侧同 NDI 的 ISOFrameTap 接法，W3-E3 报告 §1 第 1 行）。App 的 AuxOutputRuntime 跟着传来源。
2. **界面不给选**（App 会话）：虚拟摄像头页去掉来源下拉、写明"送 PGM"。设计方案里虚拟摄像头拿的是 PGM 帧（§2 数据流"这块 IOSurface 同时交给：编码器队列、NDI 队列、
   虚拟摄像头、录制器"、§3"PGM NV12 IOSurface 派发给每个消费者"）；§8 虚拟摄像头那一行没写来源。

建议 2（小、与设计方案的数据流一致）；要 1 的话先在设计方案 §8 那一行写明可选来源。请检查点 / 用户定。

## 处理（G4 续做合入会话，2026-09-27）

等用户裁定。检查点的建议同上：**第 2 条**（界面不给选、写明"送 PGM"，与设计方案 §2 / §3 的数据流一致），落进 prompt 73（W3-E4）第 1 条；
选第 1 条的话要先改设计方案 §8 那一行、再开输出会话。清单 docs/checklists/G4.md 11-4 记了现状。
