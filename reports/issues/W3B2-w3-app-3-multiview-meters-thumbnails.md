# W3-B2 → App（W3-E2）：多画面电平表的 setMeters 接线；输入条缩略图与多画面格子的几处重叠

归属会话 / 分支：App/（W3-E2 / `w3-app-3`，prompt 63）；headless 的 `setMeters` 调用点归检查点（G5 或 W3-E2 之后的合入会话）
发现于：W3-B2（分支 `w3-compositor-3`，2026-09-23），只读 App 代码时看到，本会话没有动 App/
严重级：S3（外观 / 接线；节目不受影响）

## 1. 多画面的真实电平表要组装方喂数（本会话的接口）

渲染器拿不到音频，表读数得由组装方递进来（铁律 4：数只来自 `Stats.audio.meters`）：

```swift
// MetalRenderer（SwitcherRender）
public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now())
```

- **线程**：非实时线程（主线程、Stats 汇总线程都行）；不许在音频实时回调里调（它分配、拿锁）。渲染线程每帧零分配地读，写端从不阻塞渲染线程。
- **频率**：每次 Stats 发布（1 Hz）就能用；想让表活一点，App 可以按调音台同一份 `AudioEngineStatus`（50 ms）拼一份同形态的
  `Stats.AudioCounters.Meters`（`inputs[n].peakDb`、`buses` 里 bus = "master" 的 `peakDb`）再喂。峰值保持 1 s 按 `time` 算。
- **过期**：超过 3 s 没喂新数，多画面当没有读数（输入格退回占位暗条、PGM / PVW 格不画表）；音频引擎停了请显式 `setMeters(nil)`。
- **读哪一项**：输入格 = `inputs[n].peak_db`；PGM 格 = master 总线；PVW 格 = 当前 PVW 那路输入的 `inputs[n]`。只用峰值（契约没有 RMS，提案 016 待批）。
- headless：`HeadlessRun` 每秒拿到 `Stats` 之后加一行 `renderer.setMeters(stats.audio.meters)` 即可（多画面环 / NDI 多画面输出才看得到）。

## 2. 输入条缩略图按"默认布局"的几何切多画面纹理，多画面输出换了布局就切错

`InputCellView.setThumbnail` 用 `MultiviewLayout.inputCell(index:inputCount:…)`——那是默认布局（pgmPvw+grid）的几何。
W3-B 起多画面输出可以配预设 / 自定义格子（提案 010 的正式字段 `OutputSettings.multiview`），渲染器按配置画进同一张纹理，
这时缩略图切到的是别的格子（或半个 PGM）。另外默认布局最多 32 格，第 33 路起 `inputCell` 返回 nil，缩略图退回整张多画面。
建议：按 `MultiviewLayout.placements(settings: MultiviewLayout.layoutSettings(in: state), inputs:…, width:…, height:…)` 找这一路的格子
（`source == .input(number: n)` 的 `inner`）；布局里没有这一路的，缩略图画占位。要让缩略图与多画面布局脱钩，得渲染器另画一张缩略图纹理（改渲染器，另开单）。

## 3. 名字会出现两次；纯音频格的占位已经在纹理里

- 多画面纹理里每个输入格左下角都有渲染器画的名字条（W1-C 起就有）。缩略图切的是整个内框，所以输入条上"标题条里的名字 + 缩略图里的名字条"会各出现一次。
  要么缩略图切掉内框底部的名字条（高 = 格高 × 14%，≤ 画面高 × 3.5%，见 `CompositorPasses.drawCellLabel`），要么标题条不再重复名字——W3-E2 定。
- prompt 63 第 7 条"输入条 / 缩略图里纯音频输入画占位（名字 + 电平表 + 话筒图标）"：渲染器的多画面格子对纯音频输入已经画了
  深灰底 + 名字 + 电平表（W3-B2 交付 1），缩略图切过来就是它；App 只需要补话筒图标（别再叠一条电平表或"无信号"）。
