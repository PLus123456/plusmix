# W5-P（prompt 119）App 止血：D04 / K01 / D06 / D16 / D07 + 111 / 112 / W4C3 留下的 App 口径

分支 `w5-app-fixes`（= harness 分支 `worktree-agent-a7648999dcec0eeb9`，worktree `.claude/worktrees/agent-a7648999dcec0eeb9`），从 G9 合入后的 main 358517f 开。
只动了 App/ 和 reports/（本报告 + reports/issues/ 两张单）。不 push、不 merge，交 G10（prompt 122）。
同机并行：115 / 118 / 120 三个会话；整套 App 用例都是等别的 xctest / swift-test / mediamtx / PlusMix 测试宿主都退了才开跑（§6）。

## 1. 做了什么

| 项 | 改了什么 | 提交 |
|---|---|---|
| 0 先写红 | Codex 的四条红用例原样搬进 `App/Tests/DebugAuditTests.swift`（断言不改，函数名 testD04_ / testD06_ / testD16_ / testK01_；D16 自己的 UserDefaults suite 换固定名字、用前先清，§5 第 4 条的约定）。修之前实跑 4 条全红 5 处，与 Codex §2 一致 | d4c2420 |
| 1 **D04** 打开 / 保存错配 | AppController 的换 session 做成串行事务：启动 / 新建 / 打开 / 打开上次退出时的节目 / 换格式 / 换节目音频 / 重起都排队（`enqueueSessionChange`，做法同 SwitcherSession 的 acquireLifecycle：在做标志 + 按先后排的续体，队列空着时在调用方任务里跑），一次一个、后来的不再被丢；读文件 / 取当前节目都在轮到时才做；文档身份（新 `DocumentIdentity`：不变 / 这个文件 / 没文件）在停完旧 session、建新 session 之前提交（中间没有 await），读不出来的打开什么都不改。ShowDocuments 拆出 `read`（只读）与 `adopt`（当前文件 + 最近列表），`load` = 两者合起来。shutdown 不排队（起到一半的照旧当场叫停），排着的作废；启动时轮到 launch 已经有 session（启动过程中 Finder 双击）就不恢复上次的 | a4062a8、15c3193 |
| 2 **K01** 开录覆盖旧录像 | 新 `RecordingPaths.unique`：名字被占（磁盘上有同名 .mov；转封装的路连同名 .mp4；在录 / 在停 / 这一批前面分出去的，按不分大小写的名字比）就依次 `-2`、`-3`……（同 RecordingFallback 的后缀），startRecordings 与切备用目录都过它；永不删旧文件（用户 2026-10-17 定）。Recorder 的库接口（约定覆盖）没动 | 8043bc5、5489416 |
| 3 **D06** ISO 换源定格 | InputRuntime 换来源（`replaceSource`）时这一路的 tee（主槽 + 分支）与引擎注册不换，只换往里推的输入对象：挂在分支上的 ISO 录制（Codex 用例拿着的那个 tap）、Aux 窗口接着收新来源的帧，录制器不断、拍点连续；换源到新来源第一帧之间各槽重复旧帧（per_input dup / tap repeated 记账）。先停旧输入再建新的（SPSC 生产者换人）。新来源不出画面（占位 / 纯音频 / start 当场失败）而旧来源推过帧：主线程推一帧黑（节目尺寸 BGRA），与"空槽画黑"一致。用户 2026-10-17 定：跟着新来源继续录、Recorder 不断。为什么不是 prompt 字面的"OutputRuntime 把 ISO 消费者换到新 tee 分支"见 §3 第 2 条 | dc0d309 |
| 4 **D16** LastSession 相对路径 | `ShowDocuments.autosave` 存档前按当前节目的基准目录把图片 / 视频文件输入的相对路径落成绝对（同打开文件时那条规则）；节目文件照旧相对。启动时从 LastSession 恢复也走这份存档 | 239d114 |
| 5 **D07** 换源重试占编号 | 音频环注册与 30 ms 重试拆成 `AudioInputRegistration`（注册 / 摘除 / 排重试都能换替身），每路一个代次：register、unregister（含还没注册上的）、removeAll（引擎停）各加一次，重试到点核对、不一样就作废；AudioRuntime.stop 先作废再停引擎 | 10ec815 |
| 6 **111 留下的** | 新 `OutputRouteFailure`（reason + stoppedStream）/ `OutputRuntime.routeFailure`：推流对象停在 failed（鉴权）时底栏、▴ 菜单写"失败"（与状态窗同字，用户 2026-10-17 定），点主体照旧重试它，提示"重试起不来 / 失败的路"；推流页状态行"失败：…"，红字分两句（停住的写"改对后点「重试」，光改设置不会自己重试"）；编码详情"（一直重试，鉴权失败除外）"；状态行 `runningEncoders` 不算 failed（W4C3 第 11 条） | 0fa91db |
| 7 **112 留下的** | 格子"转场"在当前那组是没选输入的 Stinger 时先弹这个槽的输入选择（转场列同一个菜单，挂在格子按钮下），一条命令都不发、PVW 不换；当前那组不对应槽时状态行说一句。T-bar：当前槽是这种槽时灰掉（`TBarView.isEnabled`：画淡、不理鼠标、不发 tbar），下面一行橙字"转场 n 是 Stinger、还没选输入"，悬停写为什么。用户 2026-10-17 定 | 807cb85 |
| 8 **W4C3 S3 一批** | 第 1 条"显示日志…"导出最近 10 分钟本程序的系统日志成文本放进诊断文件夹并打开；第 2 条状态窗 / 统计窗 / 多画面窗口转发快捷键；第 3 条输入效果页不显示限幅节（已有的限幅格列进"其他效果（原样保留）"）；第 4 条限幅延迟提示按总线分开、首帧晚"约 3 拍"；第 5 条设置窗 ▶ / ⏸ 认"播完"；第 6 条英文 T-bar 行写短"T1 · Fade 0.5 s ▾"；第 9 条查询串自定义参数名记在本机、换写法按认出的名字去掉；第 12 条三处英文文案；第 13 条 Adobe 摘要看密码空不空、效果链编辑器保住 API 设的顺序；第 14 条 SDK 没编进来的两种横幅"添加"小字；第 15 条在第 6 项里。第 8 条没做（§3） | 893f7a5、49826be、0be7250、7e957e5、dd433ff、b80d6bf、4bed619 |
| 9 问题单 | `reports/issues/W5P-w4-docs-manual-followups.md`（手册要跟着改的 16 处，中英、行号）；`reports/issues/W5P-w2-stream-last-error-enum-text.md`（W4C3 第 8 条剩下的一半，在推流包里） | 393e82a |

改了期望的老用例（行为是本分支有意改的，都在提交说明里）：`NDISendAppTests.testNDI_settingsPageNameSourceEnabledTakeEffect`（原来钉着"换来源 = 换新 tee"，改成等新输入对象并断言 tee 不换）、`W5OFollowupTests.testW5O4_stingerSlotRefusalShowsStatusLineNotice`（中间那段原来钉着"格子转场被拒、状态行同一句"，按 10-17 裁定改成"先弹选择、PGM / PVW 不换"）、`LiveSafetyTests`（X38 那句的期望文字）、`StreamWiringTests.testStream_authFailedStopsWithStatusLineNotice`（只加断言：底栏"推流 · 失败"）、`PlaybackStatusTests`（一句断言说明）、三处测试注释（replaceSession 不再被挡掉）。

## 2. 测试 ID：数值 / 阈值 / 通过否

本会话的用例没有带阈值的测试 ID（App 行为用例）；没动任何阈值，没跳过断言。"红"一列是实现之前那一遍的实跑；标"推理"的是用例与修复同一个提交、没单独跑红，写的是旧代码会怎样。

| 用例 | 红（修之前） | 绿（数值） | 通过 |
|---|---|---|---|
| `DebugAuditTests.testD04_overlappingOpenMustNotSaveFirstShowOverSecondFile`（Codex） | session=A、保存目标=B、存完 B 的输入 [1]（2 处） | session=B、目标=B、B 的输入 [2]；连跑 3 遍绿 | ✅ |
| `DebugAuditTests.testD06_isoRecordingMustFollowReplacedInputSource`（Codex） | 换源后 1 s：lastSequence 46→46、forwarded +60、repeated +60 | lastSequence 30→90、forwarded +60、repeated +0 | ✅ |
| `DebugAuditTests.testD16_lastSessionMustPreserveRelativeMediaBase`（Codex） | 恢复后 `~/Movies/PlusMix/asset.png` | 恢复后 = 原节目临时目录下的 asset.png | ✅ |
| `DebugAuditTests.testK01_startRecordingMustPreserveExistingFile`（Codex） | 开录即删、37 字节旧文件读回 nil | 37 字节原样，落到 fixed-2.mov | ✅ |
| `W5PFixesTests.testK01_fixedTemplateRecordedTwiceKeepsBothFiles` | 推理：三次都叫 fixed.mov、后一次删前一次 | fixed.mov（7664 B）→ fixed-2.mov（40 帧）→ fixed-3.mov，第一次内容不变，录两次后目录里正好这两个文件 | ✅ |
| `W5PFixesTests.testK01_quickRestartWhileStoppingGetsNewName` | 推理：封口回调里再起时与在录的去重为空，同名删旧 | 停的命令刚发就再开：fixed.mov（7362 B）→ fixed-2.mov，第一次的文件原样 | ✅ |
| `W5PFixesTests.testK01_remuxTargetWithSameNameIsKept` | 推理：落到 fixed.mov，Remux 先删同名 fixed.mp4 | 只有 fixed.mp4 在时落到 fixed-2.mov、转封装成 fixed-2.mp4，旧 fixed.mp4（29 B）原样 | ✅ |
| `W5PFixesTests.testK01_uniquePathSkipsDiskBatchAndRunningNames` | 新函数（编译红） | 磁盘 / 在录（不分大小写）/ 同批 / 只有同名 .mp4（只拦转封装的路）五种口径 | ✅ |
| `W5PFixesTests.testD06_isoRecordingAcrossSourceChangeStaysContinuous` | 推理：同 Codex 那条（定格到停） | 带音频的 ISO：同一个录制器录到底，143 拍 = 143 帧、音频 114400 = 143 × 800 样本，换源只重复 1 帧，tee / 主槽 / 引擎注册不换 | ✅ |
| `W5PFixesTests.testD06_sourceChangeToBrokenSourceGoesBlackNotFrozen` | 推理：tee 不换之后不推黑会停在旧画面 | 换到不存在的图片：state = error，PGM 读回亮度均值 < 3 | ✅ |
| `W5PFixesTests.testD07_rapidSourceChangesRegisterOnlyLatestRing`（可控计钟 + 16 ms 淡出替身） | 最终 B、重试 11 次（与 Codex 一致；拆分后、加代次之前跑的） | 最终 C、不残留 B、重试 2 次 | ✅ |
| `W5PFixesTests.testD07_unregisterOrStopCancelsPendingRetry` | 删掉的那一路 [1]、停了的 [2] 照样被重试注册上 | 都不注册 | ✅ |
| `W5PFixesTests.testD16_openLastSessionFindsRelativeImageInShowDirectory` | 推理：同 Codex 那条 | 打开 → shutdown → openLastSession：没有文件身份、路径是原目录下的绝对路径、这一路 live，节目文件仍相对 | ✅ |
| `W5PFixesTests.testD04_failedOpenKeepsSaveTargetAndRunningShow` / `testD04_restartQueuedBehindOpenRestartsTheOpenedShow` | 推理：后者原来被重入保护丢掉 | 读不出来：session / 保存目标 / 最近列表都不变；排在打开后面的重起接手 A（输入 [3]）；后者连跑 3 遍绿 | ✅ |
| `W5PCopyTests.testW5P111_authStoppedStreamSaysFailedInBottomBar` / `…StreamingPageSplitsFailureHintByCause` / `…StatusLineIgnoresFailedStreams` | 推理：原来"推流 · 起不来"、红字一句、状态行"0 b/s" | 底栏 / ▴ 菜单"失败"、点 = 重试；页上"失败：…"与两句红字；编码详情新字；只有失败的路时推流码率 —，退避中照旧 0 b/s | ✅ |
| `StreamWiringTests.testStream_authFailedStopsWithStatusLineNotice`（真 MediaMTX，加了断言） | — | 底栏「推流 · 失败」、stoppedStream、提示"重试起不来 / 失败的路" | ✅ |
| `W5PCopyTests.testW5P112_cellTransitionWithUnsetStingerAsksForInputAndSendsNothing` | 提示没写、没弹菜单（接口空壳） | 弹"转场 4 · Stinger：先选一路输入（选了才执行）"、0 条命令、PVW 2 不换；选输入 3 只改槽；再点转场 Stinger 跑完、3 上 PGM、rejected 0 | ✅ |
| `W5PCopyTests.testW5P112_tbarDisabledWhileCurrentSlotIsUnsetStinger` | T-bar 推到顶真的硬切了（PGM 1 → 2）、发了 11 条 tbar | T-bar 灰、橙字"转场 4 是 Stinger、还没选输入"、推不动 0 条命令；换当前槽恢复 | ✅ |
| `W5PCopyTests.testW4C3_1_showLogsExportsRecentSystemLog` / `testW4C3_2_…ForwardHotkeys` | 提示 4 处；三个窗口按空格 handled +0 | 导出 log-*.txt 文件头 `# log show --last 1m`；三个窗口各一次 Cut、handled +1 | ✅ |
| `W5PCopyTests.testW4C3_3_…HidesLimiterSection` / `_4_…ThreeTicks` / `_12_englishCopyMatchesUI` | 17 处（旧行为空壳） | 见用例 | ✅ |
| `W5PCopyTests.testW4C3_5_settingsPlayButtonKnowsPlaybackEnded` | 播完仍"⏸ 暂停"、发 setPlayback(true) | 播完 = ▶、点 = seekPlayback 0；循环不算播完；暂停中照旧取消暂停 | ✅ |
| `W5PCopyTests.testW4C3_6_englishTbarRowFitsWithoutTruncation` | 英文四槽 149–181 pt、中文槽 4（未设）145.5 pt > 134 | 英文 91.5–111 pt、中文 110–134 pt，都 ≤ 134 | ✅ |
| `W5PCopyTests.testW4C3_9_…Remembered…` / `_13_adobeSummaryChecksPassword` / `_13_effectChainEditorKeepsApiOrder` / `_14_…AddNote…` | 6 / 2 / 5 / 3 处 | 见用例 | ✅ |

整套 App（`make test-app XCB_FLAGS=`，计数用 xcresulttool；§6 运行记录）：G9 是 263 条，本分支 +31 条 = **294 条**。

- 第 0 遍（02:12）：289 过 + 4 跳 + **1 红** = 我自己的错——设置窗 ▶ / ⏸ 写成 `Button(model.playButtonTitle)`，SwiftUI 无障碍文案的源码扫描（`AccessibilitySourceScanTests`）只认 Button 那一行里直接写 `L(…)`；改回两段 L(…)（7e957e5）。
- 第 1 遍（02:23）：289 过 + 4 跳 + **1 红** = `MeterFeedTests.testMeters_rendererFedEvery50msOnMainThreadFromMixerStatus`（71 ≠ 70，"旧 session 的定时器停了"）：用例在 `Task { restartSession() }` 之前取计数，当时的队列每个事务另起一个 Task、多一跳主线程，停旧 session 之前多喂了一拍表。是本分支的时序变化引起的，不算环境红：队列改成"在做标志 + 续体"（15c3193），那一条连跑 5 遍绿。
- **第 2 遍（02:40）：294 = 290 过 + 4 跳 + 0 红**（`Test-Switcher-2026.10.18_02-40-59-+0800.xcresult`）。
- **第 3 遍（02:58）：294 = 290 过 + 4 跳 + 0 红**（`Test-Switcher-2026.10.18_02-58-28-+0800.xcresult`）。两遍都是别的会话的 xctest / swift-test / mediamtx 都退了才开跑，没有环境红要复跑。
- 4 跳都是老的：键盘导航要用户开系统设置、空闲唤醒探针（SWITCHER_IDLE_PROBE_MINUTES）、内置摄像头 BLOCKED-权限（TCC）、虚拟摄像头 BLOCKED-签名。

lint：`make lint BRANCH=w5-app-fixes` 在 C locale 与 zh_CN.UTF-8 下都全绿（禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 46 个文件（含本报告）在范围 / Help 18 个文件一致 / 链接 200 个 Markdown / RT 符号）。

## 3. 没做的和原因

1. **W4C3 第 8 条（推流"最后错误"连不上 / 断线那一半带 Swift 枚举原样）**：改法在 `Packages/SwitcherOutputs/Sources/Streaming/StreamOutput.swift` / `StreamTransport.swift`（`StreamTransportError` 加 CustomStringConvertible），不在 119 的 App/，也不在 118 的目录。App 不能在界面上另洗一份（状态窗、API、stats.jsonl 读同一个 last_error，铁律 4）。问题单 `reports/issues/W5P-w2-stream-last-error-enum-text.md`，归下一个推流会话。
2. **D06 没按 prompt 字面"OutputRuntime 把在录的 ISO 消费者换到新 tee 分支"做**：`ISOFrameTap.branch` 是 let、在包里（118 的目录）；换一个新 tap 的话，Codex 用例拿着的旧 tap 不再涨（断言不许改）。App 里唯一能让同一个 tap 收到新帧的做法是这一路的 tee 不随来源换（§1 第 3 项）。行为上满足 prompt 要的四样（Recorder 不断、拍点连续、换源间隙按 dup 记账、不定格到底），附带 Aux 窗口也跟着新来源走；NDI 输入源照旧摘下重挂一个分支（重挂只差一拍，可以以后删掉）。
3. **D06 没覆盖的边角**：① 录着 ISO 时把这一路**删掉再加同编号**：新的一路是新 tee，旧 tap 停在没人推的分支上（与原来一样定格），这不是"换来源"，没动；② ISO 的音轨挂在混音器槽位上（按编号在 addConsumer 时解析一次），换源时旧环摘、新环注册，按 LIFO 拿回的通常是同一个槽，用例实测两轨等长；但那几十毫秒里正好有别的路注册的话会换槽、ISO 音轨跟错——没做（要改 OutputRuntime 在注册完成后重挂音频消费者，牵涉 pump 的同源 tap 共享），记在 §5。
4. **D07 没在真 App 里复现那个 16.7 ms 的竞争窗口**：按 prompt 用可控计钟替身做（Codex 也只做了替身，报告 §3 写明"真实 App 尚待验证"）。
5. **T-bar 只在界面上拦**：MIDI 推子（`MIDIMapper.TBarMapper`，116 的目录）与 API 的 `tbar(progress:)` 照契约推没选输入的 Stinger 仍是硬切。要不要在契约里一并拒，见 §4 第 2 条。
6. **"credentialsRequired 也停"维持**（prompt 第 6 项点名）：没改，W2-D4 的行为原样。
7. **KNOWN_ISSUES / 手册**：不在本会话目录。G10 销号的行：D04 / D06 / D07 / D16 / K01、"W4C3 其余 14 条"里的第 1–6、9、11–15 条（第 7 条 → 116、第 8 条 → 推流会话、第 10 条 → 契约 / reducer、第 13 条的 Stream Deck → 116）、"111 留下的"底栏那一半、"112 留下的"格子与 T-bar 两条；`ToolbarMenuTests.testUI_recentMenuDisambiguatesSameNamesAndOpensLastSession` 那条环境红（G9 怀疑是 D04 的重入保护）重入保护没了，可以从环境红名单拿掉。手册要改的 16 处在 `reports/issues/W5P-w4-docs-manual-followups.md`。
8. **目视只看了转场列**：临时用例用 `AppTest.screenshot`（cacheDisplay）截了转场列三张（中文 / 英文当前槽 = 没选输入的 Stinger、英文槽 2），T-bar 灰、橙字两行、"T4 · Stinger ▾" / "T2 · Wipe → 1 s ▾" 都放得下，截完把用例删了；格子按钮、推流页红字、状态窗按钮没截图（用例按文字断言）。

## 4. 对契约的疑问

没改契约（SwitcherContracts 一个字没动）。几处要你定的：

1. **换来源时 PGM 的样子变了**（D06 的副作用）：tee 不随来源换之后，PGM 上这一路在新来源第一帧到之前停在旧来源的最后一帧（原来是一下黑，持续时间 = 新来源起来的时间）；换到起不来的来源 / 纯音频设备照旧画黑（主线程推一帧黑）；起来之后才没信号的（设备晚到、NDI 源不在）停在最后一帧，同来源中途断掉。per_input 的 dup 会记上换源那几拍。你 10-17 定的是 ISO 的口径，PGM 这一半是跟着来的——要保留"换源闪一下黑"请说（那样 ISO 与 PGM 换源那几拍就不一样）。
2. **T-bar 推没选输入的 Stinger**：029 只拒 `autoTransition` / `useTransitionSlot(start: true)`，`tbar(progress:)` 照收、推到顶是一次硬切。界面已经拦（§1 第 7 项），MIDI 推子与 API 没拦。要不要让 029 把 tbar 也拒了（校验器 + reducer，SwitcherControl / SwitcherEngine）——要的话是新提案，归 115 那一类契约会话。
3. **查询串鉴权的自定义参数名记在本机**（W4C3 第 9 条）：节目文件只有地址，名字没进节目（不加字段）；换一台机器打开要在鉴权表里重新填一次参数名。要随节目走的话得给 `StreamSettings` 加字段 = 契约提案。
4. 录制文件名的同批撞名原来加 `.<输出号>.mov`，现在统一成 `-2`、`-3`（与磁盘撞名、切备用目录一套后缀）。ISO 的模板本来就带 `{output}`、录制 1 以外的 PGM 录制自动带 `-{output}`，同批撞名只在手改模板时出现；不是契约，只记一句。

## 5. 下一个会话需要知道的坑

1. **换 session 全部排队**（D04）：`replaceSession(show:)` / `newShow` / `openShow` / `openLastSession` / `restartSession` / `changeProgramFormat` / `changeShowAudio` / `launch` 都进 `enqueueSessionChange`，body 里只能调 `performReplace`（再排队会等自己、死锁）。`shutdown()` 不排队（照旧当场叫停起到一半的），之后排着的作废、再发的照常。用例里"等启动时的 replaceSession 完成，否则会被 replacing 挡掉"那类注释已经改了：现在不会丢，只是排在后面。
2. **`ShowDocuments.load(from:)` 仍然会把 url 当成当前文件**（read + adopt）：用例里拿它读回文件会顺手改掉 currentURL、之后的保存写到那里去；只读用 `read(from:)`。
3. **每路输入的 tee 不随来源换**（D06）：`InputRuntime.Entry.tee / slot` 在 setInputSource 之后是同一个对象（NDISendAppTests 改过期望）；换源先 `stop()` 旧输入再建新的，别反过来（同一个 SPSC 槽两个生产者）。删掉再加同编号才是新 tee。
4. **音频注册的接缝**：`AudioRuntime.registration`（`AudioInputRegistration`），`registerRetries` 现在是它的计数；要测时序就用 `init(register:unregister:schedule:)` 换替身（W5PFixesTests 里的 ManualClock / FadingRegistrar）。
5. **`OutputRouteFailure`**：用字符串字面量写 = 运行表起不来那种；推流对象停在 failed 的是 `stoppedStream = true`（`OutputRuntime.routeFailure(output:)`）。`failureReason(output:)` 照旧给原因字符串。
6. **TBarView.isEnabled**：关着时 `simulateDrag` 也不动；当前那组是没选输入的 Stinger 时转场列每个快照都把它关掉。格子"转场"那条路会弹**模态菜单**：用例里点它一定要包在 `AppTest.measurePoppedMenu` 里（0.5 s 后 cancelTracking），否则用例卡住——W5OFollowupTests.testW5O4 没改之前在全量里卡了 114 s。
7. **SwiftUI 无障碍源码扫描**（AccessibilitySourceScanTests）：Button 那一行里要直接看得到 `L(`，`Button(model.xxxTitle)` 这种算违例；要么两段 L(…)，要么同一窗里有 `.accessibilityLabel(`。
8. **RecordingPaths 不分大小写比名字**：同一批里 "ISO-A" 与 "iso-a" 也算撞；切备用目录也过一遍。
9. **效果链编辑器记着读进来时的位置**：`EffectChainEditor` 多了私有的 layout，两个内容相同、来历不同的编辑器 `==` 可能不等（比 `slots` 别比编辑器本身）；第二个限幅格进 `others`。
10. **查询串鉴权的名字记忆**在 `UserDefaults` 的 `streamAuthQueryParams`（测试宿主是测试 suite）；用例要自己的 suite 用固定名字、用前用后清（本会话 `plusmix.w5p.streamauth`、`plusmix.audit.autosave`）。
11. **"显示日志…"** 跑 `/usr/bin/log show --last 10m`，几秒；测试里别真点按钮（模型的 `showLogs` 换掉），用 `DiagnosticsExport.writeRecentLog` 写到临时目录。
12. 同机并行：118 的 StreamingTests 起的 mediamtx（21950 起的端口）、别的 worktree 的 xctest 在跑时，本会话都等它们退了再跑整套（草稿区 `waitquiet.py` 按进程参数里的 worktree 名认）；显示类用例照旧怕窗口被盖住。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0），Xcode 27.1；同机并行 115 / 118 / 120。

| 项 | 结果 |
|---|---|
| 红灯轮：Codex 四条（01:08，修之前） | 4 条 5 处红（`Test-Switcher-2026.10.18_01-08-42`） |
| 红灯轮：D07 两条（01:27，拆出 AudioInputRegistration、还没加代次） | 2 条红：最终 B、重试 11 次；删掉 / 停了之后仍注册 |
| 红灯轮：112 两条、W4C3 第 1–6 / 9 / 12–14 条 | 见 §2 红一列（各自实现前一遍） |
| 定向回归（每项做完） | DebugAudit / W5PFixes / W5PCopy 与 Recording / ISO / DiskProtection / ToolbarMenu / StartupOrder / ShowRoundTrip / LiveSafety / NDISend / NDIBranchRetry / InputWiring / InputStrip / PlaybackStatus / AudioWiring / MixerPanel / TransitionColumn / TransitionPanel / Localization / OutputPages / AudioEffects / AudioSettingsRevamp / InputSettingsRevamp / PanelsRevamp / AddInputRevamp / MainWindowLayout / VisualDetail / MeterFeed / Panel / AuxLayering / ShortcutAndShow / StreamWiring（MediaMTX 鉴权那条）：0 红 |
| `make test-app` 第 0 遍（02:12） | 294 = 289 过 + 4 跳 + 1 红（无障碍源码扫描，我的错，7e957e5 修） |
| `make test-app` 第 1 遍（02:23） | 294 = 289 过 + 4 跳 + 1 红（MeterFeed 时序，本分支队列多一跳引起，15c3193 修；那条连跑 5 遍绿） |
| `make test-app` 第 2 遍（02:40） | **294 = 290 过 + 4 跳 + 0 红**（`.build/DerivedData/Logs/Test/Test-Switcher-2026.10.18_02-40-59-+0800.xcresult`） |
| `make test-app` 第 3 遍（02:58） | **294 = 290 过 + 4 跳 + 0 红**（`Test-Switcher-2026.10.18_02-58-28-+0800.xcresult`） |
| 目视（03:09） | 转场列三张截图（草稿区，不入库）：T-bar 灰 + 橙字两行；英文 "T4 · Stinger ▾"、"T2 · Wipe → 1 s ▾" |
| lint | C locale / zh_CN.UTF-8 两遍全绿 |
