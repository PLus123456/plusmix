# W5-S App 收口三（prompt 139，分支 `w5-app-closeout-3`）

分支：worktree 分支 `claude/w5-app-closeout-3-8f9a92`，别名 `w5-app-closeout-3` 指向同一提交（lint / check-ownership 用别名）。从 G12 快进后的 main（c7d441a）开，
只动了 `App/`（10 个文件，check-ownership 绿）。不 push、不 merge，交 G13（140）。

## 1. 做了什么

**用户 2026-11-07 定的三条（reports/G12.md §7.1 第 4 / 5 / 6 条，开工时 AskUserQuestion 问的）**：第 4 条纯音频 ISO = **(a) 维持黑画面**（本路不动 ISO 页副标题、不动 Recorder）；
第 6 条 NDI 在跑中翻 failed = **加，同一路 60 s 一次**；第 5 条统计窗列效果链延迟 = **列**（G12 的建议是"不列"，用户选了"列"）。

1. **W2A6 NDI 发送换源撞音频注册重试后漏挂音频（S1）——动态复现了，修了。**
   - 复现：133 静态确认的链（问题单代码链 1–4）原样出现：`registerRetries` +1、这路 NDI 的 `audio` 一直 nil、音频块 21 → 21 不再涨。
   - **复现要的"stop() 快的来源"不能用 TestKit 的 `SyntheticAudioInput`**：探针实测它的 `stop()` 用了 **140 ms**（等实时线程睡到下一块的到点时刻），
     比混音器摘除淡出（removalFadeBlocks 3 × 256 帧 ≈ 16 ms）慢得多——旧槽早摘掉了，新来源当场注册上，`registerRetries` = 0、问题看不见
     （Codex 宿主探针用的视频合成源 retries = 0、音频块照涨，多半同理——视频合成源的 stop() 没单独量）。用例里自写了一个 `stop()` 只 cancel 定时器、立即返回的合成 PCM 纯音频源
     （`W5SFastStopAudioInput`：DispatchSourceTimer 每 256 帧补写、host time = 起点 + 样本数 / 48 kHz），像设备 / 文件输入那样快，换源必撞重试。
   - 改法（问题单建议 1）：`OutputRuntime` 的 `registration.onRegistered` 在 `followInputAudioSlots()` 之后调 `attachMissingNDIAudio(input: n)`——
     给在跑（phase == .running）、源是 `.input(n)`、还没有音频挂件的 NDI 发送补挂 `.input(number: n)`。这时新来源已经注册上、槽位是新的，挂不到还在淡出的旧槽上（W5-Q D06 边角的口径）。
     起 / 停进行中的不动（起完 `attachNDI` 按那时的注册表挂；停的不要了）；纯视频来源（图片等，永远不注册）走不到，与原来一样不发音频块。另一种做法为什么不选见 §3 第 1 条。
2. **W2D5 底栏推流 ▴ 菜单项悬停露路径密钥（S2）——修了。** `StreamMenuRow.rows` 的悬停提示对每一路看同层 `streamKey`：空着（只有空白也算）就
   `StreamURLRedaction.redact(url:publishNameInPath: true)`，RTMP / RTMPS 路径 ≥ 2 段时末段换成 `<redacted>`；判法抽成 `ShowRedaction.keyIsInPath(streamKey:)`，
   诊断包（`ShowRedaction.redact(json:)`）与菜单同一处。密钥栏非空的那一路末段是应用名 / 子路径，照原样。底栏推流按钮自己的悬停（`OutputButtonSummary`）不含地址，没动；
   菜单栏"输出 › 推流 ▸"是同一个菜单。
3. **P57 选动作面板（129 §3 第 2 / 3 条）——两条都做了。**
   - 叠加命令（`command.overlay`）的输入下拉加"（清空）"= 0（034 ⑤：input 0 = 清空这个通道的输入）。**命令目录的类型化字段没改**（仍是 `input(allowsBlack: false)`、可选）：
     面板自己认这一处（`ActionCatalog.zeroClearsInput(entry, field)` = overlay 命令的 input 格），一句话摘要写"清空"、不写"黑场"（按目录拼出来应是"叠加设为开 / 关 · 通道 1 · 开 · 清空"；用例只断言含"清空"、不含"黑场"）。
     下拉选项抽成 `ActionPickerModel.inputChoices(for:)`，视图照它出、用例直接读；别的 `allowsBlack: false` 下拉（setInputAudio 等）不加，setPreview 照旧"黑场"。
   - 秒数溢出：**先验证了，会溢出**——`ActionText.seconds` 的 `String(Int(rounded))` 和 `ActionCatalog.jsonValue` 的 `Int((秒 × 帧率).rounded())` / `Int((秒 × 1000).rounded())`
     对 1e30 秒都 trap（"Double value cannot be converted to Int because the result would be greater than Int.max"，测试宿主崩）。改：表单写回走 `setSeconds`，
     按格的类型钳（`ActionCatalog.clampedSeconds`）——按拍的（durationTicks）到 `DurationLimits.maxTicks ÷ 节目帧率`（60 fps 下 14 400 秒），
     秒 → 拍用 `ActionCatalog.ticks(seconds:frameRate:)`，与 `OverlaySettingsModel.ticks(seconds:)` / 契约出厂转场槽同一个法子（先在 Double 上比上限再转 Int）；
     毫秒的（fadeMs）到 **1 小时**（= maxTicks @ 240 fps；fadeMs 按毫秒存、不跟帧率走，钳到这里任何合法帧率下换出来都 ≤ maxTicks，兼容层毫秒上限 D03 也是 1 小时）；
     定位秒数（seekPlayback 的 `.seconds`）到 `PlaybackLimits.maxSeekSeconds`；负数 / NaN → 0。拼 JSON 时再钳一次（表单之外进来的值）；
     显示对 Int 装不下的值按 `%g` 写（热键表 JSON 里手写的 `seekPlayback(seconds: 1e30)`：seekPlayback 是面向操作员的命令，摘要走 `ActionText.seconds`，按代码路径修前打开快捷键页同样会崩——红用例崩在更前面那一句，这条没单独跑修前）。
4. **G12 §7.1 第 6 条：NDI 发送在跑中翻 failed 时状态行提示。** `OutputRuntime.noteStats` 对在跑的 NDI 发送看 Stats.encoder 里它那一行的 state：
   上一行不是 failed、这一行是 failed 才算翻（第一行就是 failed 也算）；同一路离上次提示不到 60 s 不再提示（D08 送成一帧就回 publishing，来回翻会刷屏）；
   这一路停了就忘掉（再起是新的一次）。原因用这一行的 `last_error`（铁律 4：发送页、API、状态行读同一行）："NDI 发送 n 出错：<last_error>"，没有原因时
   "NDI 发送 n 出错（原因见输出设置的 NDI 页）"。逻辑在 `NDIFailingNotices`（纯值类型，用例直接测），节流钟 `noticeUptime` 可换替身；事件复用 `.ndiFailed`。
   起不来（start 抛错）的那一句"NDI 发送 n 起不来：…"照旧，不走这里。
5. **G12 §7.1 第 5 条：统计窗"音频"一节列效果链延迟。** 音频那张表下面多一张"效果链延迟"：名字 / 延迟 / 压缩器实测；总线按 Stats 列的顺序（`listedBuses` = 四条，
   没装效果的写 0.0 ms）、输入按编号（名字从快照对号，删了的写"输入 n（已删）"）；延迟一位小数、压缩器实测两位、没有压缩器写"—"（同推流 / 录制状态窗那一行）。
   数原样来自 `Stats.audio.effects`（铁律 4），瞬时值、不受"重置"影响；没有效果链数据（老 Stats / 引擎没起）写"没有"。
6. 用例：新建 `App/Tests/W5SCloseoutTests.swift`（8 条，见 §2）。提交按"红用例 → 每条修法一个提交"分开（`Localizable.strings` 按 hunk 分进各自的提交）。
7. **顺带修了一个测试工装的挂死（不在 prompt 里，但不修 App 全量跑不完）**：`AppTest.run`（`App/Tests/TestSupport.swift`，ffprobe / frameprobe 都走它）原来两根管道、
   先读 stdout 到 EOF 再读 stderr。xctest 给宿主设了 `OS_ACTIVITY_DT_MODE`（os_log 镜像到 stderr），子进程继承；macOS 27 上 frameprobe 读音轨时 AudioAnalytics 刷
   720 行 `[carc] Message send exceeds rate-limit threshold…`，stderr ≈ 127 KB（`OS_ACTIVITY_DT_MODE=YES` 下手跑实测），超过 64 KB 管道缓冲，frameprobe 卡在 `_os_log_impl` 的 write 上
   （sample 实测），我们卡在等 stdout 的 EOF 上——`ISOAppTests` 的 A4 挂 30 分钟。stderr 改写临时文件（不会写满），stdout 照旧用管道；改后 A4 过。
   G13 跑 gate4 / App 全量前要有这个提交，否则 A4 会挂住整轮（不报红，只是不动）。

## 2. 每个测试 ID

| 测试 | 修前 | 修后 / 阈值 | 通过否 |
|---|---|---|---|
| `W5SCloseoutTests.testW2A6_ndiSendRestoresAudioAfterSourceReplacementHitsRegisterRetry` | `registerRetries` +1（进了重试窗口）、NDI `audio` = nil、音频块 21 → 21（1.3 s 不涨）——**红**（3 处断言） | `registerRetries` +1、token 在、挂的是 `.input(1)`、音频块 79 → 267（1 s +188） | ✅ |
| `W5SCloseoutTests.testW2D5_streamMenuTooltipHidesPathKeyWhenKeyFieldEmpty` | 悬停写 `rtmp://h/live/KEYW5S2` 等三路密钥——**红**（10 处断言） | 四路：`rtmp://h/live/<redacted>`、`rtmps://h:443/app/<redacted>`、`rtmp://h/live/sub`（密钥栏非空照原样）、`rtmp://<redacted>@h/live/<redacted>`；真 ▴ 菜单项同 | ✅ |
| `W5SCloseoutTests.testP57_actionTextSecondsAndBuildDoNotTrapOnHugeSeconds` | `Int(1e30)` **trap、测试宿主崩** | 显示 "1e+30 秒" / "inf 秒"；按拍格 1e30 → 864 000 拍；fadeMs → 3 600 000 ms | ✅ |
| `W5SCloseoutTests.testP57_actionPickerSecondsFieldClampsHugeValue` | （新接口 `setSeconds`，修前编译不过） | 按拍 1e30 → 14 400 s（60 fps）、−3 / NaN → 0、2.5 照常；fadeMs → 3 600 s；定位 → 604 800 s | ✅ |
| `W5SCloseoutTests.testP57_overlayCommandPickerOffersClearOption` | （新接口 `inputChoices`，修前编译不过；面板上本来就没有 0） | 前两项 "不换输入" / "（清空）"(0)；拼出 `overlay(channel: 1, on: true, input: 0)`；摘要有"清空"无"黑场"；存下的动作定位回来；setInputAudio 无 0、setPreview 仍"黑场" | ✅ |
| `W5SCloseoutTests.testG12_6_ndiFailingNoticeOncePer60Seconds`（纯逻辑） | 新 | 翻才提示、60 s 内不重复、各路分开、forget 后重新算 | ✅ |
| `W5SCloseoutTests.testG12_6_ndiFailingWhileRunningShowsStatusNoticeThrottled`（真 NDI 发送 + 喂 Stats 行 + 替身钟） | 新 | 第一次翻 1 句、+10 s 再翻 0 句、+61 s 再翻第 2 句（无原因那一句） | ✅ |
| `W5SCloseoutTests.testG12_5_statsWindowListsEffectChainLatency` | 新 | 6 行名字 / 延迟 / 实测逐字对上；重置不动；空 effects → 空表 | ✅ |
| prompt 第 5 条的 App 相关类 + 被改动波及的类：NDISendAppTests / NDIBranchRetryAppTests / BottomBarPopupTests / ActionPickerTests / W5RCloseoutTests / W5SCloseoutTests / BottomBarSplitTests / LocalizationTests / CopyComplianceTests / ReleaseTests / W5QCloseoutTests / W5LMiscTests / OverlayClearInputTests / ControlEditorTests / EncoderStatsLookupTests / OutputPagesTests | — | **87 条：86 过、1 跳、0 红**（跳的是已知的 BLOCKED-系统设置 `testUI_spaceNotEatenByBottomBarButtonsWithKeyboardNavigation`） | ✅ |
| App 全量（`xcodebuild test-without-building`，SW_AUDIO_SILENT=1，12:23–13:01，同机另有一个会话在跑 StreamingTests） | — | **335 条：329 过、4 跳、2 红**（xcresult summary）。跳的 4 条都是已知的：键盘导航（BLOCKED-系统设置）、IdleWakeProbe（测量用例，要设环境变量）、内建摄像头（BLOCKED-权限）、虚拟摄像头出口（BLOCKED-签名）。红的 2 条见下两行，都不是本路改动引起的 | 见下 |
| ↳ `ISOAppTests.testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame` | 全量里**挂了 30 分钟**（frameprobe 子进程 0% CPU），我杀掉 frameprobe 后才红；单独复跑又挂 | 根因是测试工装 `AppTest.run` 的管道互等（§1 第 7 条），修了以后 ISOAppTests 两条都过 | ✅（修工装后） |
| ↳ `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` | 全量里红在"菜单项：全部关外部显示"3 s 内没关掉（显示类、外部显示路，与本路改动无关） | 单独复跑过（2.2 s） | ✅（单独复跑） |
| 改工装后复跑：用到 `AppTest.run` / ffprobe / frameprobe 的类（DiskProtectionAppTests / ISOAppTests / RecordingTests / ReleaseTests / StreamWiringTests）+ W5R / W5S | — | 39 条 38 过、1 红：`RecordingTests.testRecord_5sTwoTracksDurationExact` 红在"起止拍差 = 按钮间隔 ± 1 帧"（321 拍 vs 319.3，差 1.7 帧）；它量的是两次点按钮之间的墙钟，停在确认框收起之后才发命令——跟在 ISO 等类后面跑时主线程忙就超（3 次里 2 次），**单独跑过、全量里也过**；不经过 `AppTest.run` 的计时段，与本路改动无关 | ⚠️ 已知类型的计时抖动 |
| `make lint BRANCH=w5-app-closeout-3` | — | lint-rules（禁词 / 版本号 / Package.swift）、check-deps（8 个包）、check-ownership（App 下 10 个改动文件都在允许范围，报告提交后 11 个）、check-help、check-links（224 个 Markdown）、check-rt-symbols 全过 | ✅ |

NDI 相关的用例这台机器有 NDI SDK（/Library/NDI SDK for Apple），全跑了。W2A6 用例没有 SDK 时只测挂件那半（sender 是空实现、不计音频块）。

## 3. 没做的和原因

1. **NDI 补挂的另一种做法没选**：`attachNDI` 对 `.input(m)` 一律建挂件、token 先空着交给 `followInputAudioSlots`。重试窗口里 `slot(forInput:)` 还是旧槽
   （removing 状态的那条记录还在 `slots[n]` 里），`attachAudio` 会当场 `addConsumer` 挂到旧槽的 tap 上、`inputAudioSlots[n]` 记成旧槽号；新来源按后进先出拿回
   同一个槽号时 `followInputAudioSlots` 看"槽位没变"就不重挂，消费者留在被 detach 的那个 tap 上——要另外区分"槽号同、tap 已换"，比补挂复杂，还会把淡出中的旧声音送进 NDI。
2. **纯音频 ISO**：用户选 (a) 维持，ISO 页副标题（"纯音频：画面为黑"）与 Recorder 都没动。
3. **ShowDocuments 的 inputNumber / outputNumber catch**：归 128，没碰。
4. **推流设置页的地址框**（`OutputPagesViews` 的 `draftURL = StreamAddress.masked(url)`，不在焦点时显示）同样用默认的 `redact(url:)`：密钥栏空、密钥写在地址末段时末段照原样显示。
   prompt 只点了底栏，没改：`StreamAddress.masked` / `unmasked` 是"编辑时打码、存的时候换回原值"一对，只处理 userinfo 与查询串，要遮路径末段得给 `unmasked` 加路径那一段
   （用户改了别的段、末段还是 ••• 时换回原值），不是一行的事。屏幕共享时设置页开着就能看到——建议 G13 定级（与底栏那条同类，S2），排进下一个 App 会话。
5. **命令目录的 overlay 字段**仍是 `input(allowsBlack: false)`：面板自己加了"（清空）"，API 的命令目录（`/api/v1/commands` 之类读 CommandCatalog 的地方）照旧不会告诉调用方 0 = 清空，
   只有说明文字写着。要类型化（比如 `input(zero: .clear)`）是 SwitcherControl 的 CommandCatalog，归 W2-C / 契约会话，见 §4。
6. 没跑：gate4 / perf / soak / 六个包（本路只动 App）。

## 4. 对契约的疑问

- 没改契约（SwitcherContracts 一行没动；CommandCatalog 也没动）。
- 可选的后续（不挡本路）：命令目录给 overlay 的 input 一个"0 = 清空"的类型化写法，面板就不用自己认 `zeroClearsInput` 这一处；要的话归 W2-C（CommandCatalog 在 SwitcherControl），
  CommandCatalogTests 那两条字面断言要跟着改。

## 5. 下一个会话需要知道的坑

- **`SyntheticAudioInput.stop()` 不快**（本机实测 140 ms，换源时整个主线程等它）：要测"旧来源 stop() 比混音器摘除淡出快"的路径，用 `W5SCloseoutTests` 里的 `W5SFastStopAudioInput`
  （或照它写）。拿合成源测注册重试，`registerRetries` 一直是 0，测的是另一条路。
- NDI 翻 failed 的提示复用 `.ndiFailed` 事件（SwitcherSession 只 `notify(message)`）；用例换了 `session.outputs.noticeUptime` 要在 defer 里换回来（宿主 session 跨用例共用）。
  这台机器 NDI 发送在测试里不会自己翻 failed，接线用例是把造好的 Stats 行喂给 `noteStats`；真 Stats 每秒照样进来（报 publishing），不影响判断。
- 统计窗效果链表的总线行永远是四条（`EffectsLatency.listedBuses = Bus.allCases`，没装效果写 0.0 ms），不是"装了效果的才列"。
- 叠加命令摘要的"清空"在 `ActionText.summary` 里按 `zeroClearsInput` 特判；`ActionText.value(field, .input(.number(0)), …)` 单独调照旧写"黑场"（它不知道是哪条命令）。
- 秒数框的上限按**当前节目帧率**算（按拍的格）：60 fps 下 4 小时、240 fps 下 1 小时；同一条热键在 60 fps 节目里存了 4 小时、换到 240 fps 节目上，拼出来的 fade 会被校验器 400（不会崩）。
- 一个文件里几处改动要分进不同提交：`git diff -U0 -- <文件>` 按 `@@` 切、挑 hunk、`git apply --cached --unidiff-zero -`（交互式 `git add -p` 在这里用不了）。
- 别名分支要在 lint 前挪到 HEAD（`git branch -f w5-app-closeout-3 HEAD`），不然 check-ownership 报"相对 main 没有改动"、看着是绿的。
- **App 用例里起子进程一律走 `AppTest.run`**（stderr 已经写文件）；自己再写 `Process` + 两根 `Pipe` 顺序读，在 macOS 27 的测试宿主里会被 os_log 刷屏写满管道互等。
  看到 App 用例"不报红、就是不动"，先 `ps` 找 frameprobe / ffprobe 子进程、`sample <pid>` 看是不是卡在 write 上。
- `RecordingTests.testRecord_5sTwoTracksDurationExact`、`ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` 在同机有别的会话 / 跟在重的类后面跑时会偶发红，先单独复跑。
- 新 worktree 跑 App 用例前先 `make gen`（新加的测试文件靠它进工程）；`build-for-testing` 首次几分钟，之后增量 + `test-without-building -only-testing:SwitcherTests/<类>` 很快。

**给文档会话（W4-C5）：改了的句子 / 行为，手册里要跟的地方**（135 没合入 main，按 prompt 写在这里，没开问题单）

| 手册位置（中文；英文 en/ 同节） | 现在手册怎么写 | 改成什么 |
|---|---|---|
| `docs/user/概念.md:70–71`（统计窗五节） | 音频（回调超时 / 欠载 / 不连续、Master 峰值、短期响度） | 后面加"；下面一张效果链延迟表：每条总线、每路输入的处理延迟（一位小数）与压缩器实测（两位），瞬时值，'重置'不动它" |
| `docs/user/输出.md:200`（NDI 连续送不出去报 failed） | 原因在 API `last_error`、系统日志里 | 加"状态行同时提示一句'NDI 发送 n 出错：<原因>'（同一路 60 秒内只提示一次，failed / 在发之间来回翻不刷屏）" |
| `docs/user/快捷键.md:47`（选动作面板的表单） | 输入 = 下拉 …；时长按秒（0.5 / 1 / 2 + 自定义） | 加"叠加命令的输入多一项'（清空）'（= 0，清掉这个通道的输入）"；"自定义秒数填超了按上限存：按拍的时长 = 864 000 拍对应的秒数（60 fps 下 4 小时），按毫秒的 Fade 1 小时，文件定位 7 天" |
| `docs/user/输出.md:92`（地址打码）/ `:112–114`（▴ 每个目的地一项） | 地址里的 `user:pass@` 和像口令的查询参数打码 | ▴ 里每一项的悬停提示写着这一路的地址：加"密钥栏空着、密钥直接写在 RTMP 地址末段时，末段也换成 <redacted>"（推流页的地址框还没这样遮，见本报告 §3 第 4 条） |
| NDI 发送（源 = 输入 n）换源 | 手册没写"换源后没声音要关开" | 不用改（修好的是缺陷；若 KNOWN_ISSUES / 故障排查里写了这条绕过办法，G13 销号时删掉） |
