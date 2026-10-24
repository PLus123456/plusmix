# W4-C4 写手册对代码查出的 App 口径缺口（止血七路 115–121 + G10 胶水合入之后）

归属会话 / 分支：App 会话（下一个动 `App/` 的会话；126 W5-Q `w5-app-closeout` 已做完未合入，第 7 条在它的分支上）
发现于：W4-C4（prompt 124，分支 `w4-docs-4`）按 main 2ec2c05 的代码写手册、开三个核对 agent 逐句对代码时（每条我又对过一遍代码）
严重级：都是 S3（界面文字与行为不一致、该有的提示看不到，不伤节目）；手册已照实写，修了告诉文档会话改掉对应的句子

每条：现象 → 代码位置 → 建议改法 → 手册里照实写在哪。

## 1. 正在出画面的输入自己报的提示，界面上哪里都看不到

- 现象：文件输入的方向矩阵不是 90° 整数倍（原样出）、转正失败、速率被钳、定位越界，FileInput 都把一句话放进 `lastError`
  （`Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:279`，提示放在 noteBox / orientationNoteBox，不改 state）。
  但 App 只在格子是**无信号**时显示这一路的 lastError（`App/Sources/UI/InputStripView.swift:222` 只在 `runtime == .noSignal` 时传 detail），
  Stats 里也没有每路的 last_error——播放中的文件输入这几句永远显示不出来。prompt 124 写的"原样出 + 格子第二行提示"在 main 上不成立。
- 建议：live 状态下 lastError 非空时也给格子第二行（或悬停提示）一个位置，至少方向那一句；或者输入设置窗"来源"一节显示它。
  （App 自己的速率框已经钳了，速率那一句从 App 进不来；主要是方向矩阵那一句。）
- 手册：输入.md / en/inputs.md"视频文件"一节"这一版界面上没有提示"。

## 2. NDI® 发送页把所有 failed 都写成"初始化 / 建发送实例失败"

- 现象：118 让 NDI 在跑但连续 10 帧送不出去（`NDISender.failureStreakLimit`）也报 `failed`，原因写进 `last_error` 和系统日志；
  App 的 NDI 发送页状态 `OutputStatusText.ndi`（`App/Sources/Engine/OutputStatusText.swift:62`）对任何 failed 都写
  "起不来：有 NDI SDK，但初始化 / 建发送实例失败（看日志）"，App 里也没有地方显示 `last_error`；翻状态时状态行不提示。
- 建议：failed 时有 `entry.lastError` 就照它写（与推流页一样"失败：<last_error>"），没有才用现在那句。
- 手册：输出.md §3 / en/outputs.md §3 末两条、故障排查 §5 新加的一行。

## 3. 推流 ▴ 菜单的悬停提示，鉴权停下的那一路仍写"起不来"

- 现象：119 把服务器拒绝鉴权停下的推流在底栏、推流页、状态窗都改成"失败"，但底栏推流 ▴ 菜单里那一项的悬停
  `streamMenu.tip.failed`（`App/Sources/UI/BottomBarView.swift:490`）不分两种，仍是"起不来：推流 n 不再重连：…"（英文 "Can't start: …"）。
- 建议：`route.failureStopped` 时用一句"失败：%@"。
- 手册：没写 ▴ 悬停的原文，不用改。

## 4. "起不来"写了两遍

- 现象：`OutputRuntime.failed` 表里存的是整句提示（`notice.streamFailed` = "推流 %d 起不来：%@"，`App/Sources/Engine/OutputRuntime.swift:637` 起 + `recordFailure`），
  推流页 `outputSettings.stream.statusFailed` = "起不来：%@" 再套一层，页上是"起不来：推流 3 起不来：不认这种地址：foo://（…）"；
  底栏悬停同样是"名字：起不来 — 推流 3 起不来：…"。
- 建议：failed 表存原因本身、提示另拼；或者推流页 / 悬停里不再加前缀。注意 Stats 的 `last_error` 现在也是这整句（`EncoderStatsSource`，同文件 :956），改的时候三方一起看。
- 手册：输出.md / en/outputs.md §2"起不来的那一段不锁"那条照实写了两遍的样子；改了要回来删掉括号。

## 5. 推流 / 录制状态窗里，起不来的路也写"失败"

- 现象：状态窗按每行统计建 `OutputRouteStatus(output:entry:)`（`App/Sources/UI/OutputStatusPanel.swift:102`），不带 OutputRuntime 的 failure，
  起不来的路 Stats 是 failed → `routeState` 写"失败"；底栏与推流页写"起不来"，同一路三处用词不一致。
- 建议：状态窗也拿 `OutputRuntime.routeFailure(output:)`（或在统计里分出两种）。
- 手册：输出.md / en/outputs.md 状态窗一节照实写"起不来、失败的都写'失败'"。

## 6. 中文的 Stinger 选输入菜单标题读起来像"选了就执行"

- 现象：`slot.stingerMenu.header` 中文"转场 %d · Stinger：先选一路输入（选了才执行）"，实际选一路只改槽、要再点一次才执行；
  119 已把英文改成 "…choose an input first, then click again to run it"，中文没跟。
- 建议：中文改成"先选一路输入，选好后再点一次才执行"之类。
- 手册：概念.md 引的是界面原文，改了要跟。

## 7.（126 分支 `w5-app-closeout`）ISO 那一路被删的提示一闪就被盖掉

- 现象：`stopForInputRemoved` 发的"ISO 录制 n 停了：输入 m 删掉了（…）"，录像封好口时 `finishRecording` 照常发 `.recordingStopped`，
  状态行随即换成"录制 n 已停：文件名，n 帧 / x s"（`StatusBarView.showNotice` 直接替换）。两句都在系统日志里，但现场看不到为什么停。
- 建议：被删停下的这一种不发 recordingStopped，或两句合成一句。
- 手册：输出.md / en/outputs.md ISO 一节照实写了"随即换成……"（跟 126 的提交）。

## 8. 小事

- `App/Sources/UI/TransitionPanelView.swift:215–216` 的注释写"推 T-bar 照契约……推到顶是一次硬切"；渲染器是推过换底拍的位置
  （出厂 0 = 一推动）就整幅画新画面（`CompositorPasses.swift` 的 `stingerShowsNewUnder`），推到顶只是对调。注释改一下，免得以后照它写文案。
- 123（`p5-contracts-5`）合入后，打开含编号 > 16 的节目会弹 `inputNumber(input: 17)` 枚举原样（`MixerStateError` 不是 LocalizedError；
  126 只给 fileRate 做了人话，见 reports/w5-app-closeout.md §5 第 9 条）。手册（跟 123 的提交）照实写了这一行；G11 若照 OutOfRangeFileRates 补了 catch，告诉文档会话换提示。
