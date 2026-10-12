# W4-C3 写手册对代码查出的 App 口径缺口（100–102 合入之后的那几节）

归属会话 / 分支：App 会话（下一个动 `App/` 的会话；112 W5-O 若还开着可以顺手，否则下一张 App 续做）
发现于：W4-C3（prompt 109，分支 `w4-docs-3`）按 main 22ff4d9 的代码写手册 100–102 那几节、开核对 agent 逐句对代码时
严重级：都是 S3（文案与行为不一致、按钮不起作用但不伤节目）；手册已照实写（含绕法），修了告诉文档会话删掉对应的绕法

每条：现象 → 代码位置 → 建议改法 → 手册里照实写在哪。

## 1. 推流 / 录制状态窗的"显示日志…"打开的文件夹里没有日志

- 现象：按钮的悬停提示写"打开诊断文件夹（帮助 › 打开诊断文件夹），推流 / 录制的日志在里面"，实际打开的 `~/Library/Application Support/PlusMix/Diagnostics`
  只有 MetricKit 交来的崩溃 / 卡死 / CPU / 磁盘负载（`crash-….json` 等）；推流 / 录制模块打的日志只在系统日志（`/usr/bin/log show --predicate 'process == "PlusMix"'`）。
- 代码：`App/Sources/UI/OutputStatusPanel.swift`（`showLogs` = `DiagnosticsExport.revealFolder()`）、`App/Sources/Release/DiagnosticBundle.swift:260`、
  `CrashDiagnostics.swift`（目录内容）；两份 strings 的 `outputStatus.showLogsTip`。
- 建议：要么按钮改成"在控制台里看…"（打开 Console 并带上 `process == "PlusMix"` 的过滤，或把最近 10 分钟的系统日志导出成文本打开），要么提示改成实情（"诊断文件夹：崩溃 / 卡死记录；推流 / 录制日志在系统日志里"）。
- 手册：docs/user/输出.md、en/outputs.md 状态窗一节"显示日志…"那一条；故障排查 §9。

## 2. 推流 / 录制状态窗、统计窗、多画面窗口在前时快捷键不派发

- 现象：X12 修完之后，主窗口、设置窗、输入 / 叠加 / 音频设置窗在前时按空格 / 数字照常切；但 101 新加的推流 / 录制状态窗、W5-L 的统计窗、多画面独立窗口在前时按键不走快捷键表。
  状态窗是直播中盯着看的窗，开着它按空格不切是 X12 同一类问题。
- 代码：`App/Sources/UI/PanelCoordinator.swift` 的 `showOutputStatus(_:)` 没调 `forwardHotkeys(w)`（输入设置 / 叠加 / 音频设置窗调了）；
  `StatsWindowController`（`App/Sources/UI/StatsWindow.swift`，PanelWindowController 子类）同样没接；`MultiviewWindowController` 的窗口不是 `PanelWindow`，没有 keyHandler。
- 建议：状态窗与统计窗建好后 `forwardHotkeys(w)`（一行）；多画面窗口换成能拦键的窗口或在 keyDown 转给 `session.control.handleKey`。补一条用例（状态窗在前按空格 = Cut）。
- 手册：docs/user/快捷键.md 开头两句、输出.md 状态窗一节末条、故障排查"按快捷键没反应"一行（中英各一份）。

## 3. 输入设置 › 音频效果 里给每路的"限幅器"一节不起作用

- 现象：102 起每路只装 EQ + 一个动态格，`peakLimiter` 每路不装（`InputEffectPlan.parse`，只记一次日志）；但输入设置窗的"音频效果"一节用的是总线也用的 `EffectChainView`，
  仍有"限幅器 / 用限幅"那一节，勾上、调参数都存进节目、听不出变化（调音台这一路的音频设置窗倒是只有 常规 / 均衡 / 压缩 三页，两处不一致）。
- 代码：`App/Sources/Settings/EffectChainView.swift`（限幅那一节不分总线 / 输入）、`App/Sources/Settings/InputSettingsPanel.swift`（`case .effects` 用它）；
  引擎侧口径 `Packages/SwitcherAudio/Sources/Integration/` 的 `InputEffectPlan`（reports/w1-audio-3.md §1.1）。
- 建议：`EffectChainView` 加一个"有没有限幅"的参数，输入设置窗不显示限幅那一节（已有的 `peakLimiter` 格原样留在链里、列进"其他效果（原样保留）"）；或在那一节写明"每路不装限幅，只有总线有"。
- 手册：概念 › 音频"每路输入"一条、输入 › 每路输入的设置"音频效果"一行、故障排查"调了某一路的音频效果，听不出变化"一行。

## 4. 几处界面文案在 100–102 / G8b 之后不对了

| 文案（键） | 现在写的 | 实际 | 建议 |
|---|---|---|---|
| `audioSettings.limiter.latencyHint`（音频设置窗 › 限幅） | "……耳机 / 扬声器监听会晚这么多" | G8b 接了 W1-B4 之后 Master 的效果延迟由画面一起延后来对齐，Master 的监听不再晚于画面；只有 Bus A / B 自己的延迟没补 | 按总线分开写：Master 页写"画面同样延后（状态窗写着视频延后 n ms）"，Bus A / B 页保留原句 |
| `cell.menu.restartOnProgram.tip`、`inputSettings.playback.hint` | "首帧晚 1–2 拍" | W5-N 在 App 里实测 3 拍（⏮ 与切上 PGM 两轮都是 3，reports/w5-playback-status.md §2：引擎 seekLead 1–2 拍 + 快照轮询到运行表） | 改成"首帧晚几拍（约 3 拍）"，或把运行表那一段省掉 |
| `mixer.listen.headphones` / `mixer.listenHelp` | "耳机总线（现在）"打勾、"耳机里只能听耳机总线" | 026 落地后耳机出口平时是 Master、独听时才是耳机总线 | 已在 KNOWN_ISSUES（S3，110 / 112 接监听菜单），这里不重开，只记一句 |

## 5. 输入设置 › 来源 › 播放 的"▶ / ⏸"不认"播完了"

- 现象：格子上的 ▶⏸ 在文件播完（不循环、停在末帧 / 黑场）时显示 ▶、点了 = 从头播（`seekPlayback(0)`）；输入设置窗"播放"一节的按钮只看 `paused`：
  播完时仍写"⏸ 暂停"，点了发 `setPlayback(paused: true)`，再点"▶ 播放"也只是取消暂停、画面不动——要从头播只能点"⏮ 回到开头"。
- 代码：`App/Sources/Settings/InputSettingsPanel.swift`（播放一节的按钮与 `togglePaused()`）对比 `App/Sources/UI/InputCellView.swift` 的 `hasEnded` / `playPressed()`。
- 建议：设置窗那一颗与格子同一口径（播完 = ▶，点 = 从头播），或直接复用格子的判断。
- 手册：没有单独写（手册里"播放"一节按格子的口径写，设置窗一句"同格子上的按钮"）——修了就真的同了。

## 6. 英文界面：转场列"T-bar"那一行出厂就截尾

- 现象：英文界面 T-bar 组第一行显示"Transition 1 · Fade 0.5…"（W5-M 量过：这一行 134 pt，中文出厂四槽 121–133 pt 放得下；英文"Transition n · …"放不下）；
  悬停提示与辅助功能标签是全的。和格子上"Transition"截成"Transit…"（W4C2-w5-app-cell-buttons-truncated-in-english.md，KNOWN_ISSUES S3）同一类。
- 建议：英文这一行写短（"T1 · Fade 0.5 s ▾"，或只写效果与时长、槽号靠左边的竖条），或这一行让出组标题的宽度。
- 手册：en/concepts.md T-bar 组一条照实写了截尾。
