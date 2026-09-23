# W2-A2 → 渲染器（多画面）：纯音频输入的格子画占位 + 电平表

归属会话 / 分支：多画面渲染在 `Packages/SwitcherCore/Sources/SwitcherRender/`（W3-B / `w3-compositor2` 的目录，会话已结束）→ 检查点指派
发现于：W2-A2（分支 `w2-inputs-2`，2026-09-23）；口径由用户同日定（W2-A2 报告 §4 第 2 条），已写进契约 `Input.videoSlot` 注释与 CONTRACTS.md §2.4
现象：纯音频输入（`InputSource.audio`）没有画面，引擎挑帧恒为 nil。多画面里它的格子现在和"没帧的视频输入"一样画黑，
看不出这一路是"本来就没画面、声音正常"还是"摄像头掉了"。
复现步骤：节目里加一路 `.audio(deviceUID: "BuiltInMicrophoneDevice")`，多画面预设 3×3 → 它的格子是黑的。
严重级：S3（外观；节目不受影响）

## 要的样子（用户定）

- 纯音频输入的格子画**占位**：深灰底（不是黑）+ 名字 + 电平表，不画"无信号"那种样子；
- 电平表对纯音频输入**总是画**（它是这一格唯一的内容），不受 `MultiviewLayoutSettings.meters` 开关影响；其它输入仍按开关。

## 做法提示

- 判断"纯音频"不需要新契约：渲染线程每拍拿到的 `MixerSnapshot.state.inputs` 里有 `InputConfig.kind`（`.audio`）。按输入编号先算一张
  "哪些编号是纯音频"的小表（快照变了才重算），渲染线程查表，别在每拍里遍历数组分配（T1：渲染线程每帧零分配）。
- `CompositorPasses.drawMeterPlaceholder` 现在只画电平表的位置（注释："真实电平在 Stats.audio.meters 里，第一版这里只画位置"）。
  真实电平是所有格子共用的另一件事（要把 `Stats.audio.meters.inputs` 以不分配的方式递给渲染器）；这张单子只要求纯音频的格子先有占位 + 电平表位置，
  真实电平跟着多画面电平表的正式实现一起来。
- 名字：多画面现在有没有画名字要看显示层（`MetalDisplayView+Multiview`）；有就沿用，没有就和"多画面加名字标签"一起做。
