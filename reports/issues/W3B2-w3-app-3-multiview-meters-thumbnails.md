# W3-B2 → App / 检查点：多画面电平表的 setMeters 接线；输入条缩略图与多画面格子的重叠

归属会话 / 分支：App/ 与 headless 的接线——W3-E2（`w3-app-3`，prompt 63）已经做完、没合并，所以归**合并 W3-E2 + W3-B2 的检查点**（或它指派的 App 续做会话）
发现于：W3-B2（分支 `w3-compositor-3`，2026-09-23），只读 App 代码（main 与 `w3-app-3` 两边都看了）时记下，本会话没有动 App/
严重级：S3（外观 / 接线；节目不受影响）

## 1. 多画面的真实电平表要组装方喂数（本会话的接口，W3-E2 那时还没有）

渲染器拿不到音频，表读数得由组装方递进来（铁律 4：数只来自 `Stats.audio.meters`）：

```swift
// MetalRenderer（SwitcherRender）
public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now())
```

- **线程**：非实时线程（主线程、Stats 汇总线程都行）；不许在音频实时回调里调（它分配、拿锁）。渲染线程每帧零分配地读，写端从不阻塞渲染线程。
- **频率**：每次 Stats 发布（1 Hz）就能用；想让表活一点，App 可以按调音台同一份 `AudioEngineStatus`（50 ms）拼一份同形态的
  `Stats.AudioCounters.Meters`（`inputs[n].peakDb`、`buses` 里 bus = "master" 的 `peakDb`）再喂。峰值保持 1 s 按 `time` 算。
- **过期**：超过 3 s 没喂新数，多画面当没有读数（输入格退回占位暗条、PGM / PVW 格不画表）；音频引擎停了请显式 `setMeters(nil)`。
- **读哪一项**：输入格 = `inputs[n].peak_db`；PGM 格 = master 总线；PVW 格 = 当前 PVW 那路输入的 `inputs[n]`。只用峰值（契约没有 RMS，提案 017 待批）。
- App：`w3-app-3` 里调音台的 50 ms 表定时器已经把 `AudioEngineStatus` 的峰值转给 `InputStripView.applyAudioLevels`（纯音频格子用），
  同一处拼一份 Meters 调渲染器的 `setMeters` 即可。
- headless：`HeadlessRun` 每秒拿到 `Stats` 之后加一行 `renderer.setMeters(stats.audio.meters)` 即可（多画面环 / NDI 多画面输出才看得到）。

## 2. 输入条缩略图（main 上的样子；`w3-app-3` 已改）

- main 的 `InputCellView.setThumbnail` 用默认布局几何（`MultiviewLayout.inputCell`），多画面输出换了布局就切错格子。**`w3-app-3` 已改成按当前布局算好的内框**
  （`setThumbnail(rect:)`，`MultiviewSettingsTests` 有用例），合入后这一条就没了。
- 名字出现两次：多画面纹理里每个输入格左下角都有渲染器画的名字条（W1-C 起就有），缩略图切的是整个内框，输入条上"标题条里的名字 + 缩略图里的名字条"各一次。
  两个分支都还是这样。要么缩略图切掉内框底部的名字条（高 = 格高 × 14%，≤ 画面高 × 3.5%，见 `CompositorPasses.drawCellLabel`），要么标题条不重复名字——App 那边定。
- 纯音频输入：`w3-app-3` 把缩略图的显示视图藏起来、画 App 自己的占位（话筒 + 名字 + `NSLevelIndicator`），不切多画面格子——和渲染器的纯音频格（深灰底 + 名字 + 电平表，
  只出现在多画面窗口 / 多画面输出里）不会叠在一起，不用改。只是两处表的颜色分段不一样：App 的 `NSLevelIndicator` 警告 0.9（−6 dBFS）/ 危险 0.97（约 −1.8 dBFS），
  渲染器是 −18 起黄、−6 起红（本会话定的，设计方案 §7 没有颜色表）。统一成哪一套等用户拍板（W3-B2 报告 §4 第 2 条）。

## 处理结果（W3-E3 / w3-app-4，2026-09-27，报告 `reports/w3-app-4.md`）

- §1 电平表喂数：G4 检查点先接了 1 Hz（Stats 消费者里 `renderer.setMeters(stats.audio.meters)`），本会话换成 50 ms：session 的 `AudioMeterFeed` 每拍读一次 AudioEngineStatus，
  同一份拼成 Meters（含 017 的 rmsDb）喂渲染器、再交给调音台 / 纯音频缩略图；1 Hz 那条撤了。`MeterFeedTests`（19 Hz、全在主线程；停喂 3.6 s 多画面表退回占位 = 没有别的喂数方）。
- §2 名字出现两次：选"缩略图切掉内框底部的名字条"（标题条保留编号 + 名字 + tally 色）。几何与 `CompositorPasses.drawCellLabel` 同一个 Float 算式，再多切 2 px。
  `ThumbnailCropTests`（离线渲染 7 种布局 / 分辨率 44 路，缩略图区域 0 个名字条像素，名字条那几行扫得到白字）。
- §2 颜色分段：检查点 2026-09-24 已统一成设计方案 §7；本会话把调音台 MeterBar 改成"RMS 实心条 + 峰值细线"（017）。
