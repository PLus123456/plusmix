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

## 7. ⇧1–⇧0（直切 PGM）用实体键盘按不出来——**S2**，影响默认快捷键表

- 现象：默认表里 `shift+1` … `shift+0`（直切 PGM）按实体键盘不触发。`KeyCombo(event:)` 用 `charactersIgnoringModifiers` 当键名，注释写"Shift+1 仍是 '1'"，
  但 AppKit 的 charactersIgnoringModifiers 只忽略 ⇧ **以外**的修饰键：⇧1 得到的是 ⇧ 打出来的字符（美式键盘 `!`；本机拼音输入法下是全角 `！`），组合成 `shift+!`，对不上表里的 `shift+1`。
  ⌥ / ⌃ 被忽略，所以 ⌥1–⌥4、⌃1–⌃4、⌃⌥3 照常；⇧ 加字母得到大写字母、`normalizedKey` 转小写，也照常。手写 JSON 的任何 `shift+数字 / 符号` 都同样按不出来；
  在设置 › 快捷键里"录键"录下的是 `shift+!`，那一行能用（同一个转换）。App 用例都用合成事件、直接给 charactersIgnoringModifiers = "1"，没覆盖到。
- 证据：草稿区探针用 `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 造 kVK_ANSI_1 + ⇧、转 `NSEvent(cgEvent:)`（不投递事件）：`⇧1 → ignoringModifiers="！"`、`⌥1 → "1"`、`⌃1 → "1"`、`⌃⌥4 → "4"`、`⇧A → "A"`。
  **没有在实体键盘上按过**，L3 清单人工确认时请按一次 ⇧2。
- 代码：`Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/KeyCombo.swift` 的 `init?(event:)`。
- 建议：有 ⇧ 且是数字 / 符号键时按 keyCode 取未加 ⇧ 的字符（`kVK_ANSI_0…9` 等键码表，或 `UCKeyTranslate` 不带 shift 再取一次），表里的 `shift+1` 就能对上；加一条用 CGEvent 造真实事件的用例。
- 手册：快捷键 / shortcuts 默认表 ⇧1–⇧0 一行与表下"⇧1–⇧0 在实体键盘上对不上"一条（绕法：逐行重录键）、hotkeys.json 写法一条；示例里原来的 `alt+shift+3`（W4-C2 写的）也按不出来，换成了 `ctrl+alt+3`。

## 8. 推流的"最后错误"与日志带着 Swift 枚举的原样

- 现象：状态窗"最后错误"、`stats.encoder[].last_error`、系统日志写的是 `连接失败：connectFailed("鉴权失败（用户名或密码不对）：…")`——`StreamTransportError` 没有自定义 description，`"\(error)"` 把 case 名和引号一起带出来。
- 代码：`Packages/SwitcherOutputs/Sources/Streaming/StreamOutput.swift:396`、`:403`–`:404`，`StreamTransport.swift:32`–`:37`。
- 建议：给 `StreamTransportError` 加 `CustomStringConvertible`（connectFailed / sendFailed 只取那段字符串），日志与 last_error 都干净；111（W2-D4）正改这一块，可以顺手。
- 手册：输出 / outputs 状态窗"最后错误"一条、鉴权一节、故障排查推流一行照实写了整行的样子。

## 9. 查询串鉴权只认几个固定的参数名

- 现象：鉴权表"用户名参数 / 密码参数"可以改成任意名字（SRS、nginx-rtmp 按回调规矩），写是写进去了；但重新读地址（`StreamAddress.authStyle(of:)`）只认 `user / username / usr` 与 `pass / password / pwd / passwd`：
  用了别的名字，按钮旁写"没有鉴权"、再打开小表停在 Adobe 且框是空的；之后存 Adobe 写法只去掉认得的那几个名字（`OutputPagesModel.setStreamAuth` 的 `.adobe` 分支），自定义名字的账号留在地址里，两种写法并存。
- 代码：`App/Sources/Settings/StreamAddress.swift:29`–`:40`、`App/Sources/Settings/OutputPagesModel.swift:398`–`:402`、`OutputPagesViews.swift:374`–`:384`。
- 建议：把用过的参数名存下来（节目里只有地址：可以按"地址里有两个值都打码的参数"认），或认写法时也认上一次表里用的名字；换写法时按表里的名字去掉。
- 手册：输出 / outputs 鉴权一节"限制"一条。

## 10. T-bar 推到一半改了当前槽、再拉回 0，当前那组不按槽重拷

- 现象：`setTransitionSlot` 改当前槽时只在空闲才拷进当前那组（`MixerReducer` 的 setTransitionSlot 分支），转场进行中改的靠 `completeTransition` 那一拍重拷；
  T-bar 拉回 0 不走 `completeTransition`（`tbar(p < 1)` 只改进度），于是 T-bar 那一行显示新设置，下一次回车 / T-bar 仍按旧设置走，做完那一次才拷上。
- 代码：`Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift`（setTransitionSlot / tbar / completeTransition）。契约文字（提案 020）只写了"完成那一拍重拷"。
- 建议：T-bar 回到 0（进度归零、回到空闲）时也按 currentSlot 重拷一次（幂等），或改契约文字写明这个例外——改 reducer 口径要走提案。
- 手册：概念 / concepts 转场槽一节"例外"一句。

## 11. 状态行把起不来（failed）的推流算成"在跑"

- 现象：状态行"推流"取在跑的路里码率最低的；`StatusLineFormatter.runningEncoders` 只排除 idle / stopped / unavailable，failed 的那一项（`OutputRuntime` 给起不来的路填的）码率 0，于是写"推流 0 b/s"；
  推流 / 录制状态窗把 failed 当没在跑（码率写 —），两处不一致。
- 代码：`App/Sources/UI/StatusLineFormatter.swift:28`–`:31`、`App/Sources/UI/OutputStatusPanel.swift:124`。
- 建议：状态行也排除 failed（或在那一项旁写"起不来"）。
- 手册：概念 / concepts 状态行一条照实写"起不来的推流码率是 0"。

## 12. 几条英文文案与界面 / 行为对不上（只有英文错）

| 键 | 现在 | 问题 |
|---|---|---|
| `slot.stingerMenu.header` | "Transition %d · Stinger: choose an input first (it runs once chosen)" | 读起来像"选了就执行"；实际选输入只改槽、要再点一次主体才执行（中文"选了才执行"没问题）。建议 "…choose an input first, then click again to run it" |
| `outputStatus.showLogsTip` | "…(Help › Open Diagnostics Folder)…" | 英文菜单项叫 "Show Diagnostics Folder"（`menu.help.showDiagnosticsFolder`）；内容不对的问题见第 1 条 |
| `inputSettings.source.fileInPlaceHint` | "…changing only “At End” or “Speed”…" | 表单上的字是 "At end" / "Playback rate"（`addInput.file.endAction` / `addInput.file.rate`） |

## 13. 其余小口径

- **Adobe 写法的按钮摘要**固定写"（密码已设）/ (password set)"，不看密码是不是空的（`OutputPagesViews.swift:382`–`:383`）。
- **界面一改效果链就整条重写**（`EffectChainEditor.slots`，`App/Sources/Settings/AudioEffectParams.swift`）：main 上会丢掉 API 设的 `peakLimiter.ceilingDb`，并把 API 写进来的 `compressor`、第 4 段起的 EQ 挪到链尾——
  总线上链的顺序就是处理顺序，挪出去的 EQ 还可能成了第 4 格、装不上。112（W5-O 第 6 项）之后压缩器与天花板认得了，第 4 段起的 EQ 与别的认不出的格挪到链尾的问题还在（请 112 复核）。
- **Stream Deck 设置面板文案没跟上**：`ui/auto.html:11` 仍写"按 Switcher 里已选的转场（Auto）"、`manifest.json` 的 Auto 提示"按已选转场开始"（现在 = 执行当前转场槽）；
  `ui/slot.html` 的标题与"Switcher 地址"用的是代号 Switcher，不是产品名 PlusMix（`Tools/streamdeck-plugin/` 归 112 的目录）。
- **英文 T-bar 行截尾**见第 6 条；**推流状态窗 / 统计窗不转发按键**见第 2 条。
