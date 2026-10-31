# W5-R（prompt 130）App 收口二：磁盘下限溢出、ISO 切备用目录的分支、纯音频 ISO、局域网明文提醒 + W4-C4 的 App 口径缺口 8 条

分支 `w5-app-closeout-2`（= harness 分支 `claude/admiring-merkle-0f3b94`，worktree `.claude/worktrees/admiring-merkle-0f3b94`，两个名字指同一提交），
从 main bf149e2（G11 第二次快进后的头）开。只动了 `App/` 和本报告；没碰 `OverlaySettingsPanel.swift`（129）、`ShowRedaction.swift` / `ReleaseTests.swift`（132）、
`ControlRuntime.swift`（131）、`ShowDocuments` 的 inputNumber / outputNumber catch（128）。不 push、不 merge，交 134 G12。同机并行：129 / 131–133（见 §2 的跑法）。

## 1. 做了什么

| 项 | 改了什么 | 提交 |
|---|---|---|
| **N04**（S0）录制磁盘下限 MB → 字节溢出 | `AppSettings.maxRecordMinimumFreeMB = 16_777_216`（2^24 MB = 16 TiB，字节 2^44；溢出点是 2^44 MB）；`clampMinimumFreeMB` 钳到 0…上限；`recordMinimumFreeBytes` 钳过再乘、`multipliedReportingOverflow` 兜底（溢出当 `UInt64.max`），`AppController.applySettings` 与 `SwitcherSession.init` 两处 `* 1024 * 1024` 换成它。入口全钳：defaults 读、`--record-min-free-mb`、`AppController.updateSettings / commitSettings` 落盘之前（`clampedForSaving`；设置导入 = 写 defaults → `load`（钳）→ `updateSettings`（钳后整份写回），也走这条）、高级页数字框（`ClampedIntegerFormat`：解析时钳，比 `Int` 还长的一串数字按上 / 下限；提交后页上换成钳后的值，已经在上限时再填超的也回到上限）。提示文字补"最大 16777216（16 TiB）"（中英） | 64c7337 |
| **N06**（S1）ISO 切备用目录 | `switchToFallback` 先给 ISO 路开新分支（旧录制器录到边界拍才还，两段要各占一个）；**开不到就不切**：按 `stopForDisk` 停这一路（failed + stopRecord，快照 enabled 回 false），提示 `notice.recordingFallbackNoBranch`"…；备用目录：这一路的画面分支满了（输入 n 每路最多 4 个 ISO / Aux），没有切，已停这一路"，绝不用 PGM / Master 顶替；新录制器起不来时把刚开的分支还回去；旧录制器封口回调里 `releaseBranch`（同 finishRecording） | fe4061f |
| **N07**（S1）纯音频 ISO 没文件 | `InputRuntime.openBranch` 给不出画面的一路（`videoSlot == nil`：纯音频设备、建不出来的占位）开分支时往**新分支**里推一帧黑（D06 的 `pushBlackFrame`，节目尺寸）；ISO 的 tap 每拍重复它（`repeated` 记账），录出来黑画面 + 本路声音。ISO 表纯音频那一行加副标题"纯音频：画面为黑"（`outputSettings.iso.audioOnlyHint`，中英）。**与 prompt 字面不同**：prompt 写"`InputRuntime.add` 往 tee 推一帧黑"，但 ISO 的分支是开录时才开的，`InputFrameTee.addBranch` 给的新分支是空的（不回放旧帧），add 时推进 tee 只进主槽、到不了 ISO——所以改在开分支这一步。主槽不推（PGM / 多画面空槽本来画黑，推了反倒每拍记一次 `per_input.dup`）。同一处也让源是这一路的 NDI 发送 / Aux 窗口拿到黑画面（原来空） | 34fcf4f |
| **NS08**（S2）局域网明文 | `PreferencesModel.apiCleartextWarning`：API 开着且"允许局域网"时（有没有 token 都）在远程控制页多一行黄字"令牌和全部状态走明文 HTTP / WebSocket（没有 TLS），只在可信局域网里开。"（`prefs.remote.cleartextWarning`，中英，用的是 prompt 给的原句）；没设 token 那句照旧 | e20d986 |
| **W4-C4 第 1 条** 播放中的提示 | `InputRuntime.liveNote`：只认文件输入（方向矩阵 / 转正失败 / 速率钳 / 定位越界，FileInput 放进 lastError、不改 state）——别的输入的 lastError 讲无信号原因，出画面后有的类不清（AudioDeviceInput 就不清），不挂；格子缩略图**底边**一行小字（不压画面中间，全文在悬停提示）；输入设置窗"来源"一节"这一路报告：…"（无信号时写 lastError）。**顺带修的**：输入的运行状态 / 原因 / 提示都不在快照里，空闲时快照不变（没有每帧的快照），格子停在上一个快照那一刻——实测新加的文件输入出了画面 2 s 还写着"无信号"；`InputStripView.refreshRuntime` 每行 Stats（1 Hz，`MainWindowController.apply(stats:)`）再对一遍，格子只在变了时重设文字 | 29c349a |
| 第 2 条 NDI failed | `OutputStatusText.ndi`：failed 有 Stats 的 `last_error` 就写"失败：原因"（`ndi.status.failedReason`），没有才用通用那句 | 29c349a |
| 第 3 条 推流 ▴ 悬停 | 推流对象自己停住的（服务器拒绝鉴权）写"已停：鉴权失败（…）：…"（`streamMenu.tip.stopped`），起不来的照旧"起不来：原因" | 29c349a |
| 第 4 条 "起不来"不套两层 | `OutputRuntime.failed` 只存原因（"不认这种地址：foo://（…）"），状态行整句另拼（"推流 3 起不来：…"）；`routeFailure` 停住的推流也只给原因（原来"推流 n 不再重连：…"）；Stats 的 `last_error` 跟着只是原因（与 StreamOutput 自己填的同口径）。"推流 n 没有地址"改成原因 `stream.error.noURL` + 通用的 `notice.streamFailed`（`notice.streamNoURL` 两份表一起删）；ISO 开不到分支、NDI 起不来同样分开存 | 29c349a |
| 第 5 条 三处同字 | `OutputStatusModel.routeFailure`（PanelCoordinator 接 `OutputRuntime.routeFailure`）：状态窗的状态列起不来写"起不来"、停住的写"失败"，与底栏 / 推流页 / 悬停同字（原来只看 Stats，起不来的写"失败"） | 29c349a |
| 第 6 条 Stinger 标题 | 中文 `slot.stingerMenu.header`"转场 %d · Stinger：先选一路输入，选好后再点一次才执行"（英文 119 已改）；三条老用例的期望跟着改 | 29c349a |
| 第 7 条 ISO 删除提示被盖 | 被迫停下的录像（ISO 读的那一路被删、磁盘满 / 低于下限没切、录制器自己出错）封口时发新事件 `recordingStoppedWithReason`，状态行是"<原因>——已封口：文件，n 帧 / x s"一句（`notice.recordingStoppedBecause`），不再被"录制 n 已停"盖掉 | 29c349a |
| 第 8 条 注释 | `TransitionPanelView.updateTbarGuard`：推过换底拍的位置（出厂 cutAtTick 0 = 一推动）就整幅新画面，推到顶只是对调 | 29c349a |

改了的老用例（期望跟着行为改，没有放宽断言）：`TransitionColumnTests` / `W5PCopyTests` / `W5OFollowupTests` 各一处 Stinger 标题原文；
`LiveSafetyTests` / `W5PCopyTests` 里注入的示例原因改成只有原因的新写法（纯格式用例，原样也过，留着会把两层的旧写法当成例子）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

都是 App 行为用例，没有测试标准里的阈值；没动阈值、没跳断言。新用例在 `App/Tests/W5RCloseoutTests.swift`（15 条）。
"红"是改之前那一遍的实跑：N04 / N06 / N07 / NS08 在加了两个不改行为的桩（`ISORow.subtitle = nil`、`apiCleartextWarning = nil`）之后跑；
W4-C4 是实现在前、用例在后——其中第 4 / 5、7 条只用现有接口，另在改之前的源码上跑过（临时文件，没提交）；其余几条用到新接口，红只会是编不过。

| 用例 | 红（修之前） | 绿（数值） | 通过 |
|---|---|---|---|
| `testN04_hugeMinimumFreeFromDefaultsClampsAndSessionBuilds` | 2^44 − 1 读回原值、字节 18446744073708503040；2^44 读回原值后建 session **SIGTRAP**（测试宿主崩，xcodebuild "Restarting after unexpected exit"） | 三个值（2^44 − 1 / 2^44 / Int.max）读回 16777216、建 session 不崩、`minimumFreeBytes` = 17592186044416（2^44）；`--record-min-free-mb Int.max` 同样钳；−5 → 0 | ✅ |
| `testN04_settingsFieldClampsHugeValueAndShowsClampedValue` | 往框里打 17592186044416、失焦 → **SIGTRAP**；而且 commitSettings 先落盘：这个值进了宿主的 defaults，宿主**下一次启动在 bootstrap 就崩**（N04 的"持久化后阻断启动"真复现了一遍） | 框里显示 16777216，内存 / defaults / 跑着的引擎都是钳后的值；已在上限再填超的、填 23 位数字都回到 16777216；750 照常 | ✅ |
| `testN04_importedSettingsPackageClampsMinimumFree` | 同上崩 | 包里 `Int.max` → 16777216，落盘也是 | ✅ |
| `testN06_isoFallbackReleasesOldBranch`（Codex `testS7_ISOFallbackReleasesBothBranches` 改名） | 切完分支数 **2**（应 1）、停后 **1**（应 0） | 切完 1、停后 0（retired 2 = 两个分支都摘了、静默期后释放） | ✅ |
| `testN06_isoFallbackWithBranchesFullStopsInsteadOfRecordingProgram`（Codex `…MustNotSubstituteProgramWhenBranchesFull` 改名，断言按修法改成"不切 + 提示"） | 换成 `consumer=Recorder branchNil=true`，备用目录里录的是 PGM（文件"…-ISO 2.mov"），提示"已切到备用目录"（5 处断言红） | 运行表从不出现别的录制器；enabled 回 false；提示"录制 2：磁盘剩余 0 MB，低于下限 0 MB；备用目录：这一路的画面分支满了（输入 2 每路最多 4 个 ISO / Aux），没有切，已停这一路"（封口后那句"…——已封口：…，21 帧 / 0.35 s"）；原文件照常封口；备用目录空；ISO 那个分支还了（剩用例占的 3 个） | ✅ |
| `testN07_audioOnlyISO_recordsBlackVideoWithAudio`（Codex AO02 宿主用例改名，合成 PCM 替设备、走 ISO 页模型勾选、录 2 s） | forwarded **0** / noFrame **60**，录制器 failed("没有写入任何视频帧")，没有结果（3 处红；与 Codex 宿主实测同） | forwarded 60 / repeated 59 / noFrame 0；**62 帧 = 起止拍差（无洞） / 99200 音频帧 / 2.07 s**（门限 2 ± 0.6 s）；第 1 秒那帧平均亮度 < 0.05（黑） | ✅ |
| `testN07_isoRowForAudioOnlyInputSaysBlackPicture` | 副标题 nil、键缺 | 纯音频行"纯音频：画面为黑"，视频行没有；英文"Audio only: the picture is black" | ✅ |
| `testNS08_lanScopeWarnsCleartextWithOrWithoutToken` | 局域网 + token 时没有任何提醒 | 局域网有 / 无 token 都是那一句；没 token 时那句照旧；仅本机 / API 关着不提醒；英文一句 | ✅ |
| `testW4C4_1_liveFileInputNoteShownOnCellAndInInputSettings` | （新接口，未跑红；改之前实测：同一用例的格子出画面 2 s 还写"无信号"、底边没有提示） | 定位 −1 s → "定位秒数 -1 不在 0–604800（一周）之间，按从头处理"：格子底边一行 + 悬停全文、中间那行空、输入设置窗"这一路报告：…"；合法定位后两处都收起；合成源 liveNote nil | ✅ |
| `testW4C4_2_ndiFailedShowsStatsLastError` | （新键） | "失败：NDI 送不了像素格式 'yuvs'，连续 10 帧没送出"；没 last_error 照旧通用那句；NDI 页那一行同 | ✅ |
| `testW4C4_3_streamMenuTipSaysStoppedForAuthFailure` | （新键） | 停住的"已停：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized"、起不来的"起不来：没有地址" | ✅ |
| `testW4C4_4_5_startFailureSaysCouldNotStartOnceEverywhere`（端到端，`foo://` 推流） | 表里存"推流 3 起不来：不认这种地址…"、底栏悬停"起不来"**两遍**、状态窗写"**失败**"（4 处红） | 表里 / Stats last_error = "不认这种地址：foo://（只支持 rtmp:// rtmps:// srt://）"；状态行"推流 3 起不来：…"一句；底栏悬停"备用：起不来 — …"（一遍）；▴ 悬停"起不来：…"；推流页"起不来：…"；状态窗"起不来"、last_error 同；停用后清 | ✅ |
| `testW4C4_5_statusWindowUsesRouteFailureWording` | （新属性） | 推流页 [失败, 起不来]、录制页 [起不来, 失败]；事件"备用 · 起不来" | ✅ |
| `testW4C4_6_stingerMenuHeaderSaysClickAgain` | — | 中英各一句 | ✅ |
| `testW4C4_7_isoInputRemovedNoticeSurvivesSeal` | 最后一句"录制 2 已停：…ISO 1.mov，35 帧 / 0.58 s"，删除原因被盖（3 处红） | 最后一句"ISO 录制 2 停了：输入 1 删掉了（…）——已封口：…ISO 1.mov，33 帧 / 0.55 s"，状态行显示的就是它；不再单发"录制 2 已停" | ✅ |

W5R 15 条在合并前最后一遍一起跑：15 / 15 过（15.6 s）。

整套 App（xcodebuild test，不带 -quiet；计数取 `xcrun xcresulttool get test-results summary`）：G11 的 305 条 + 本分支 15 条 = **320 条**。

| 遍 | 时间 | 结果 | 红的那几条 | 判定 |
|---|---|---|---|---|
| 1 | 10-25 00:00–00:08（负载 ≈ 3，129 / 132 / 133 同机） | 320 = **313 过 + 4 跳 + 3 红** | `DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger`（卡住 300 ms / 遮住 1.2 s 都记了 0 帧）、`ThumbnailRateTests.testThumbnail_pausesWhenWindowIsCovered`（露出来 0 帧）、`ThumbnailRateTests.testThumbnail_refreshRateAtMost24fpsWhileMonitorsRunFullSpeed`（缩略图 0 fps） | 显示类、要桌面可见（KNOWN_ISSUES 环境红名单、`plusmix-shared-machine-runs`）。单独复跑这两类：DisplayLedger 自己的守卫跳过——"PGM 监视器 1.5 s 只画了 0 帧：窗口不可见（锁屏 / 别的 Space）"；ThumbnailRate 两条照红，**连本分支没碰的 PGM / PVW 监视器也是 0.0 fps**——测试宿主的窗口不在屏幕上（屏幕没锁、显示器开着，最前面是 Claude，宿主窗口不在当前 Space）。**BLOCKED-环境**：G12 在桌面可见时复跑这三条 |

没有跑第二遍全量：132 / 133 同机还在跑推流 / 录制的用例，App 里带 MediaMTX 固定端口的用例（BottomBarSplit / StreamWiring / OutputPages 的 L3 等）第二遍会和它们撞端口（坑见 `plusmix-shared-machine-runs`）。
第一遍里它们都过了；本分支改到的几处（推流起不来 / 鉴权停住 / ISO / 磁盘 / 输入条 / 设置窗 / 状态窗）对应的老用例类全在这一遍里过了：
DiskProtectionAppTests 3 / ISOAppTests 2 / OutputPagesTests 11 / RemoteControlPageTests 1 / SettingsWindowTests 5 / LiveSafetyTests 11 / StreamWiringTests 2 / W5PCopyTests 16 /
W5QCloseoutTests 9 / W5OFollowupTests 17 / TransitionColumnTests 14 / InputStripTests 11 / LocalizationTests 8（键两份表一致、没有没人用的键）/ W5RCloseoutTests 15，都是 0 红 0 跳。

跳过的 4 条都是老的：键盘导航 BLOCKED-系统设置、空闲唤醒探针（要 `SWITCHER_IDLE_PROBE_MINUTES`）、虚拟摄像头 BLOCKED-签名、内置摄像头 BLOCKED-权限（TCC）。

lint：`make lint BRANCH=w5-app-closeout-2` rc 0（禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 25 个改动文件在范围 / Help 18 个文件一致 / 链接 215 个 Markdown / RT 符号）；
报告提交后在 C 与 zh_CN.UTF-8 两种 locale 下各跑一遍：都是 rc 0，归属 26 个改动文件（含本报告）在范围。

## 3. 没做的和原因

1. **纯音频 ISO 录"纯音频文件"（没有视频轨）**：要改 Recorder（没有视频时也建 writer、只带音轨），归 Outputs 会话；本路按 prompt 只做"黑画面 + 本路声音"。两条路的取舍在 §4 请用户定。
2. **NDI 在跑中翻成 failed 时的状态行提示**：问题单第 2 条顺带提到"翻状态时状态行不提示"，prompt 130 第 5 条只要发送页显示 last_error；没加（加的话要防它在 failed / publishing 之间来回翻时刷屏，等用户要不要）。
3. **W4-C4 第 8 条后半（打开含编号 > 16 的节目弹 `inputNumber(input: 17)` 原样）**：ShowDocuments 的 catch 归 128，按 prompt 不做。
4. **统计窗列效果链延迟**、**N08 / N11**、**TLS / WSS**、任何阈值：按 prompt 不做。
5. **手册**：一句没动（`App/Resources/Help` 是 `make manual` 的产物、归文档会话）；要改的句子列在 §5。

## 4. 对契约的疑问

- 没改契约。
- **纯音频输入的 ISO 录成什么（请用户选）**：(a) 本路现在的做法——黑画面 + 本路声音，文件照常是 .mov（H.264 / HEVC + AAC），和别的 ISO 一样能直接拖进剪辑软件对轨，代价是一条没用的黑视频轨（码率很低）；
  (b) 纯音频文件（只有音轨，例如 .m4a / 只有 AAC 的 .mov），要改 Recorder（没有视频帧也建 writer、`RecordingResult.videoFrames` 允许 0、帧号 / 起止拍改按音频块算），
  归 Outputs 会话，ISO 页的副标题跟着改。两者对 A4 / 多路对齐的影响：(a) 起止拍与别的 ISO 同一网格，(b) 要单独核对音频起点。选 (b) 的话本路推黑帧那一处可以留着（Aux / NDI 输入源也用得上）。
- Stats `encoder[].last_error` 的文字口径（022：最近一次错误的文案）：起不来的录制 / 推流原来是状态行那整句（"推流 3 起不来：不认这种地址…"），现在只是原因；字段名与取值集合没变，只是文字更短——API 用户若按文字匹配会受影响（应该没有）。

## 5. 下一个会话需要知道的坑

**给文档会话（W4-C5）：改了的句子 / 行为，手册里要跟的地方**

| 手册位置（中文；英文 en/ 同节） | 现在手册怎么写 | 改成什么 |
|---|---|---|
| `docs/user/设置.md:109`（高级 › 磁盘下限）/ `:124`（`--record-min-free-mb`） | 默认 200 | 加"最大 16777216（16 TiB），填超了按最大存" |
| `docs/user/设置.md:78`（远程控制黄字） | 只写"允许局域网又没设 token…黄字提醒" | 允许局域网时（有没有 token）都多一句"令牌和全部状态走明文 HTTP / WebSocket（没有 TLS），只在可信局域网里开。"（NS08 手册那句本来就归 W4-C5） |
| `docs/user/输出.md:60–66`（ISO 表 / 纯音频） | 纯音频能勾 ISO（但实际没有文件） | 纯音频输入的 ISO 录黑画面 + 本路声音；表里那一行副标题"纯音频：画面为黑" |
| `docs/user/输出.md:67`（ISO 那一路被删） | 状态行"ISO 录制 n 停了：…"，随即换成"录制 n 已停：…" | 封口后状态行是一句"ISO 录制 n 停了：输入 m 删掉了（…）——已封口：文件，n 帧 / x s"（磁盘满 / 低于下限没切、录制器出错停下也是"<原因>——已封口：…"） |
| `docs/user/输出.md:78–79`（磁盘表） | 设了备用目录就切过去 | ISO 路要再开一个画面分支才切得过去：这一路 4 个分支（ISO / Aux / 源是它的 NDI）都占着时**不切**，停这一路，提示"…；备用目录：这一路的画面分支满了（输入 n 每路最多 4 个 ISO / Aux），没有切，已停这一路"（原来悄悄改录 PGM） |
| `docs/user/输出.md:103`（推流页"起不来"一段） | 例子"推流 3 没有地址"；手册注明了"起不来"写两遍的样子 | 页上是"起不来：没有地址""起不来：不认这种地址：foo://（…）"，**只写一遍**——删掉写两遍的括号；状态行是"推流 3 起不来：没有地址"（原来"推流 3 没有地址"） |
| `docs/user/输出.md:104`（鉴权停下） | "失败：推流 n 不再重连：鉴权失败（…）：…" | "失败：鉴权失败（…）：…"（不再带"推流 n 不再重连："） |
| `docs/user/输出.md:158`（底栏悬停） | "名字：失败 — 推流 n 不再重连：鉴权失败（…）：…" | "名字：失败 — 鉴权失败（…）：…"；▴ 菜单那一项悬停"已停：鉴权失败（…）：…"（手册原来没写 ▴ 悬停原文，可不加） |
| `docs/user/输出.md:126`（状态窗） | "起不来、失败的都写'失败'" | 起不来的写"起不来"、停住 / 失败的写"失败"，与底栏 / 推流页同字；事件"名字 · 起不来：原因" |
| `docs/user/输出.md:200` + `故障排查.md:75`（NDI failed） | 发送页一律"起不来：……初始化 / 建发送实例失败（看日志）"，原因只在 API 的 last_error | 发送页有原因就写"失败：<last_error>"（例如"失败：NDI 送不了像素格式…，连续 10 帧没送出"），没有才是原来那句；状态行照旧不提示（§3 第 2 条） |
| `docs/user/输入.md:87`（任意角度方向矩阵）及"视频文件"一节 | "这一版界面上没有提示" | 播放中格子缩略图底边一行小字写那一句（悬停全文），输入设置窗"来源"一节"这一路报告：…"；速率被钳 / 定位越界那几句同样显示 |
| `docs/user/概念.md:139`（Stinger 选输入菜单标题） | "转场 4 · Stinger：先选一路输入（选了才执行）" | "转场 4 · Stinger：先选一路输入，选好后再点一次才执行" |
| `docs/api/README.md:127`（起不来的路的 last_error） | 原因在 last_error | 仍对；文字现在只是原因（不带"推流 n 起不来："前缀），可加一例 |

**别的坑**

1. **N04 的红会毒化测试宿主**：设置窗那条在修之前跑，会把 2^44 存进宿主的 defaults（`com.plusmix.switcher.tests.<按构建位置的哈希>`），宿主之后每次启动都崩在 bootstrap（xcodebuild 报 "Early unexpected exit, operation never finished bootstrapping"）。修好以后宿主带着这个值也能起（读回 16777216），但 16 TiB 的下限会让本 worktree 后面的录制用例一开录就"低于下限"停掉——红跑完要 `defaults delete com.plusmix.switcher.tests.<hash> recordMinimumFreeMB`（哈希 = 宿主 bundlePath 的 FNV-1a，base36；本 worktree 是 `19ade20t55zyl`）。在别的 worktree 复现红时同样要清。
2. **快照不是每帧都来**：`SwitcherSession.pollSnapshot` 只在状态机发了新快照（命令生效、转场 / 叠加动画中）时通知；空闲时几秒不变。界面上读输入对象自己状态的东西（格子的无信号 / 原因 / 提示）原来只跟快照走，会停在旧样子；现在格子每行 Stats 再对一遍。别的面板若也读运行状态（输入设置窗"播完"、底栏），照这个口径看是不是只跟快照。
3. **`setOutputEnabled` 对推流 / 录制不生效**（reducer 拒，要用 start / stopStream / Record）——写用例时踩过。
4. **文件输入改速率触发 lastError 的路不好用来测**：钳到 8 倍速，解码追不上，这一路一会儿就无信号了；定位越界（`seek(toSeconds: -1)`，按从头处理、照常播）稳。
5. Codex 的 AO02 用例原文用的是 1f9be64 的 `RecordEntry.audioToken`，现在是 `entry.audio?.token`（W5-Q 改成 `AudioAttachment`）。
6. 新 worktree 先 `make gen` 再编；加了新测试文件也要再 `make gen`（XcodeGen 不会自己看见）。
