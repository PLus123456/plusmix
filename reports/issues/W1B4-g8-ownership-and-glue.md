# W1-B4 合入时要检查点（G8）补的四件事：OWNERSHIP 一行、App 接线三行、Stats 一行、提案 028 的契约文字

归属会话 / 分支：G8 检查点（prompt 107；OWNERSHIP 与 App 胶水）+ P5（prompt 99，Stats 字段与契约文字）
发现于：W1-B4 / `w1-core-4`（harness 分支 `claude/w1-core-4-listen-sync-5e151a`），2026-10-10
严重级：S2（不补的话 App 里监听仍不同步；不会出现文件错位，见第 2 条）

## 1. docs/OWNERSHIP.md 的 W1-B4 行要加四个文件（用户 2026-10-10 在本会话里批的扩范围）

`make lint BRANCH=w1-core-4` 的 check-ownership 对下面四个文件报越界（其余 lint 全绿）。它们是用户在本会话里批的：
显示延后扩到 SwitcherRender（"扩到 SwitcherRender（推荐）"）、ISOFrameTap 那一行本会话改（"本会话改（推荐）"），见 docs/contract-changes/028 末尾的状态段。

- `Packages/SwitcherCore/Sources/SwitcherRender/Renderer/MetalRenderer.swift`
- `Packages/SwitcherCore/Tests/SwitcherRenderTests/DisplayDelayTests.swift`
- `Packages/SwitcherOutputs/Sources/ISO/ISOFrameTap.swift`
- `Packages/SwitcherOutputs/Tests/ISOTests/VideoDelayISOTapTests.swift`

建议：W1-B4 行"只准动"一列加上这四个路径（一行改动）。本会话没有改 OWNERSHIP.md、也没有绕过检查。

## 2. App 接线（三行，归检查点胶水或 97）

不接的话 App 维持 W5-C 的行为：音频引擎默认是 videoDelay，但没接视频引擎时按 audioPTS 走（Master PTS 照旧前移），**录制 / 推流 / NDI 不会错位**，
只是扬声器 / 耳机监听仍比画面晚 L（开了压缩 / 限幅时 5–35 ms）。接法（App 建引擎 / 渲染器 / 音频引擎的地方）：

```swift
// 建 MetalRenderer 时（App/Sources/AppSettings.swift:134 附近的 MetalRendererOptions）
o.videoDelayHeadroom = EngineOptions().videoDelay.maxDelay   // 35 ms：NV12 输出环加深 4 个（延迟队列扣着的帧）
o.displayDelayHistory = true                                 // 监视器 / 外部显示 / 多画面跟着延后：多留 3 格合成目标（1080p ≈ 75 MB）
// 引擎、渲染器、音频引擎都建好之后
renderer.displayDelayProvider = { [engine] in engine.videoDelayApplied }
audio.engine.videoDelay = engine                              // Master 效果链的实测延迟 → 引擎
```

另外开录起点建议改到节目输出时间线（提案 028 第 3 条用户定"只写进报告"，所以本会话没改）：
`App/Sources/Engine/OutputRuntime.swift:373 / 576` 的 `RecordingStart(clock: clock, tick: startTick)` 改成
`RecordingStart(tick: startTick, tickTime: clock.time(of: startTick) + engine.videoDelayApplied)`；不改的话开录那一刻 L > 0 时视频轨从 L 开始
（AVFoundation 在 0…L 读出一帧黑），两轨首尾各错 L（文件内 A/V 仍对齐；E5"音视频轨道差 ≤ 20 ms"在 L > 20 ms 时会看到）。headless 同理（`HeadlessRun.swift:449–450`）。

## 3. Stats 的 `video_delay_ms`（P5 的提案 022 顺带 B2）

P5 开了顶层字段之后，`Packages/SwitcherCore/Sources/SwitcherEngine/Engine/EngineCounters.swift` 的 `StatsAssembler.make` 里填
`videoDelayMs: counters.videoDelayMs` 一行（数就在 `EngineCounters.videoDelayMs`，= 最近派发的那一帧的 Lₙ）。字段没开之前本会话不碰契约。

## 4. 提案 028 的契约文字

用户 2026-10-10 批了口径（docs/contract-changes/028-video-delay-output-timeline.md）。要落的是文字与一行实现，不加字段：
Render.swift 的 `RenderedFrame.tickTime` / `AudioBlockConsumer.hostTime` 注释、`RenderedFrame.renderMs` 改成 `gpuEnd − program.pts`、
Stats.swift 的 `latencyMs` 注释（L1 含 L）、CONTRACTS.md §3 第一条 / §7 / §2.7。归 P5（若已收尾则下一个契约会话）。
