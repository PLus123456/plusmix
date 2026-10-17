# W5-O（prompt 112）App 续做：两条 S2、监听菜单、Stinger 槽拒收的提示、分类颜色、压缩器界面、X51、S3 一批

分支 `w5-app-followups`（= harness 分支 `claude/w5-app-followups-658c92`，worktree `.claude/worktrees/w5-app-followups-658c92`）。
从 G8b 合入后的 main（22ff4d9）开；第 3、4 项要 110 的契约，2026-10-12 中午 **rebase 到 110 的 `p5-contracts-3`（9af1bf0）头上**——整条分支叠在 110 上，
G9 先合 `p5-contracts-3` 再合本分支；归属检查用 `scripts/check-ownership.sh w5-app-followups --base p5-contracts-3`。不 push、不 merge。

## 1. 做了什么

| 项 | 改了什么 | 提交 |
|---|---|---|
| 1 S2 外部显示 Esc = 删输出 | 外部显示窗口里按 Esc 改发 `setOutputEnabled(off)`（原来 `removeOutput`）：窗口收起、显示器 / 来源配置留着，与路由菜单的"关闭"同一条命令，再点源按原配置开回来。设置 › 外部显示 每路底下那颗按钮做的就是删除，字从"关闭这路 / Close"改成**"删除这一路 / Remove This Output"**（与录制页同字、与路由菜单"删除 n …"同口径——两处都不问，与路由菜单一致），只关用这一节顶上的"启用"开关 | 976b365 |
| 2 S2 设置页整份写回存下启动参数 | 新 `AppSettings.save(to:changedFrom:)`：只写与内存里那份不同的键；监听地址 host:port 是一个键，只变了一半时另一半按本机存的（本机没存过 = 默认 127.0.0.1:8765；`--api-listen` 带进来的那一半不跟着存，1abb301 是自查补的这一处）。设置窗的常规 / 音频设备 / 远程控制 / 高级 页与 Tally 页走新的 `AppController.commitSettings`；整份写回的 `updateSettings(_:)` 留给导入 / 恢复默认之后的重读与用例还原（那里要的就是整份）。`--tally-port` 也是启动参数，Tally 页一起改。**安全复核补一道闸**（30667ff）：这次改动"放开"了 API（打开 / 换成非本机地址）、存下来会是"开着 + 非本机 + 没令牌"而内存里（页上）有令牌时，令牌一起存——否则带 `--api-token` 起、页上不提醒没令牌、存下来却是局域网无鉴权 | 976b365、30667ff、1abb301 |
| 3 监听菜单（提案 026） | Master 条"监听"菜单四项单选：Master / Bus A / Bus B / 耳机总线（`.headphones` = 只听每路送耳机的那一条，不再叫"（现在）"）；选了发 `setMonitorSource(bus:)`，勾读快照 `audio.monitorSource`（API 改的也跟上），已经是它就不发（不在状态行冒"命令被忽略"）；`listenToOtherBusSupported` 翻 true；`AudioSettingsRevampTests.testPanels_masterListenAndLoudnessDetails` 改成新口径 | b20f21d |
| 4 Stinger 槽拒收的提示（提案 029） | **控制层**：Hotkeys/ 新 `ControlFeedback`（`stingerWithoutInput(slot:)` / `overlayNeedsPreview(channel:)`），`HotkeyDispatcher.setFeedbackHandler`：命令被总线拒（CommandRejection）且是"执行没选输入的 Stinger"（`useTransitionSlot(start: true)` / 当前那组是这种的 `autoTransition`，判定用契约的 `TransitionSlot.isStingerWithoutInput`）时交给 App；App 状态行"转场 n 是 Stinger、还没选输入——在转场列 ▾ 里选一路"（当前那组不对应槽时"当前转场是 Stinger、还没选输入——…"）；界面命令通道（格子"转场"）被拒也换成这一句。**兼容层**：`Transition n` 对这种槽回 409 `NotConfigured`（与 `Stinger1` 没配好同口径），C5 一条。**Stream Deck**：按下之后怎么回应抽成纯函数 `pressFeedback`（被拒 / 本地错误 → `showAlert` + warn，忽略只记 info），`test/cases.js` 一条。界面三处照旧先弹选择，没动 | ff8c526、b81c2ac、b20f21d |
| 5 分类颜色切 `InputConfig.color` | 格子右键"分类 ▸"发 `setInputColor`；输入条每个快照按各路 `InputConfig.color` 对一遍（刚点的颜色在快照回来前先画上，0.3 s 没回来以快照为准）；删掉一路颜色跟着配置没了（原来 App 自己清 layout 键那段删了）；名字按 023 四 (a) 留 layout `inputCategoryNames`；`ShowDocuments.prepared` 调 `Show.migratingLegacyInputCategories()`——读文件与读 LastSession 都走它（同 101 对 025）；`InputCategories.Color` 换成契约的 `InputColor` | 4d9a090 |
| 6 压缩器简单模式（提案 024 (b)） | 音频设置窗压缩页顶上选"压缩器（阈值 + 比例）"= `compressor` 或"动态处理器（阈值 + 压缩量）"= `dynamicsProcessor`，同一格二选一（编辑器值模型保证链里不会两个都在；API 写进来的第二个动态格原样留在"其他"）；新开默认压缩器；简单模式阈值 / 比例 / 补偿，拐点 / 起音 / 释放在"高级"，范围 = `SwitcherAudio.EffectParameterRanges.table["compressor"]`；"延迟自测"一行读 `compressorMeasuredLatencyFrames`（调音台同一份 50 ms `AudioEngineStatus`，`MixerMeters` 多两张表）；限幅页"天花板"写 `peakLimiter.ceilingDb`（−20…0，0 不写键、老链原样）；输入设置窗的效果节同一套二选一 | b8a29fc |
| 7 X51 | 31 个上游真有的函数名（清单 = docs/ui-study/附录/核对-VF5-动作目录.md §3.2）以精确名字补进 `FunctionCatalog.knownUnimplemented`，回 501；没加前缀族（NDIAnything 这类照旧 400，用例钉住） | 94ff3be |
| 8 S3 一批 | 只改总线声道对算"待应用"（借 Master G8b 起当场生效，不算，见 §3）；导出 / 导入 / 恢复默认补提醒四键 / 电源两键 / Tally 两键 / 兼容层 HTTP 端口，**顺带修声道对**（键表里有、但包的值类型认不出 Data，导不出、导入时又被删——值类型加 `data`，包里写 `{"data": base64}`）；⌃1–⌃4 空通道用 PVW（PVW 也黑场时不发、状态行说转场列同一句）；midi.json 读不出来状态行提示（同 hotkeys.json）；无信号格子第二行写这一路的 `lastError`（App 定只读协议 `InputLastErrorReporting` 让七个输入类回溯遵守，不改契约），全文在悬停提示；NDI® 横幅照 DeckLink 那条写实；低于下限切备用目录提示写"低于下限 n MB"（切换事件带原因）；英文格子转场 / Cut 按标题宽度分（中 / 大档全字；小档两颗放不下，先截 Transition、保住 Cut） | b81c2ac、9c922a6 |
| 9 告诉 109 | 同步单 reports/issues/W5O-w4-docs-3-manual-followups.md（每项给了手册 文件:行号），三次 SendMessage 给"手册续做"会话；109 回话已按九项里涉及手册的几项都改了（w4-docs-3 提交 bfa6806 = 第 1 / 2 / 4 / 5 / 6 / 7 / 8 项、5e62a8d = 第 3 项，报告写明要 110 + 112 一起合、112 不合就 revert 这两个提交） | 8b49854、d38cbf5、d96d18d |

顺带（都在本会话目录）：`PanelsRevampTests.testAudio_busChannelMapReachesDevice` 的用例隔离问题（W5-K 起就有）：设置模型的异步提交在它 defer 还原之后才落地，把假设备名与 `{master: 0}` 写回测试宿主的本机设置、下一轮起引擎就带着——先关窗、泵主队列再还原（b20f21d）。App 的 `SlotText.isUnsetStinger` 改调契约的 `isStingerWithoutInput`（P5-3 落地记录点名要共用一条判定）。

## 2. 测试 ID：数值 / 阈值 / 通过否

先写红：第 7 项 C5 红 31 × 4 处（全回 400）；第 1 / 2 项四条红 19 处（"下次不带参数起 API 照本机设置开着"读回 false，S2 原样复现）；第 5 项两条红（颜色没进 InputConfig、老 layout 键没搬，App 还在自己清 layout）；第 4 项兼容层一条红 6 处、Stream Deck 整文件导入失败（`pressFeedback` 不存在）；第 6 项与第 8 项大半、第 3 项的新用例引用的接口还不存在，红在编译（`runtimeDetail` / `loadMIDITable` / `compressorKind` / `listenBuses` ……），实现后一起跑——这几条没有单独的"断言红"记录，如实写在这里。第 4 项控制层整合用例在叠 110 之前会在"应被拒"红（校验器还不拒），叠上就绿。

| 用例 | 断言的东西 | 结果 |
|---|---|---|
| `W5OFollowupTests.testW5O1_escOnExternalWindowOnlyTurnsOutputOff` | Esc → enabled false、窗口收起、settings / name 原样；路由菜单勾在"关闭"、来源写"（已关）"；开回来同屏同源 | 过 |
| `testW5O1_externalSettingsButtonSaysDelete` | 中英"删除这一路 / Remove This Output"，老键 `outputSettings.external.close` 两张表都没了 | 过 |
| `testW5O2_settingsPagesDoNotPersistLaunchArguments` | 带 `--no-api --api-token --audio-device --record-min-free-mb --record-fallback --tally-port` 起，五页各改一项：存下的键 = 原有两个 + 改的那几个；apiEnabled 仍是本机的 true、令牌 / 设备 / 下限 / 备用目录 / tally 端口都没写；内存里启动参数照样生效 | 过 |
| `testW5O2_saveChangedKeysKeepsStoredHalfOfListenAddress` | host:port 只变一半另一半按本机存；tally 端口不跟着存；放开到局域网时令牌一起存（安全闸）、改别的项令牌不存；整份写回照旧 | 过 |
| `testW5O3_listenMenuSendsSetMonitorSourceIncludingHeadphones` | 四项 / 标题；busA → busB → headphones → master 每次快照与 `AudioEngineStatus.monitorSource` 都跟上；API 改的勾跟上；再选当前项不发；rejected 0 | 过 |
| `testW5O4_stingerSlotRefusalShowsStatusLineNotice` | ⌥4（出厂槽 4）→ 状态行原文、没执行；当前槽选成 4 后格子"转场"同一句、PGM 不换；选了输入后执行 | 过 |
| `testW5O5_categoryColorLivesInInputConfig` | 右键分类 → `InputConfig.color`、layout 无旧键、算未保存；API `/api/v1/state` 里 `color: "red"`、没分类不写键；外部 `setInputColor` 格子跟上；"无"清掉；名字在 layout；删了再加同编号不继承 | 过 |
| `testW5O5_legacyLayoutCategoriesMigrateOnLoad` | LastSession（另一个 ShowDocuments）与打开文件两条路都搬：颜色 [red, nil, purple]、认不出的 / 不存在的跳过、名字键留、刚打开不算未保存 | 过 |
| `testW5O6_compressorPageSimpleModeAndLimiterCeiling` | 范围 = 引擎表；启用 = compressor + 契约默认参数；改比例 / 阈值 / 补偿进链；延迟自测 0 帧（总线与每路都读到）；二选一换种类链里只剩一个；复位不动开关；天花板 −1.5 进 peakLimiter；rejected 0 | 过（延迟自测 = 0 帧，按设计 0） |
| `testW5O6_effectChainEditorRoundTripsCompressorAndCeiling` | 往返不丢、钳进范围、两个动态格第二个进"其他"、换种类带开关 | 过 |
| `testW5O8_busChannelPairChangeIsPendingRestart` | 改声道对 → 待应用；改回跑着的那份 → 不待应用；借 Master 当场落到引擎、不待应用 | 过 |
| `testW5O8_settingsTransferCoversRemindersPowerTallyCompatPortAndBusMap` | 十个键在键表；导出包里有提醒 / 电源 / tally 端口 / HTTP 端口 / 声道对；恢复默认回默认；导入回来 | 过 |
| `testW5O8_ctrlNumberOnEmptyOverlayUsesPreview` | ⌃1 空通道 = PVW 那一路开、再按关；PVW 黑场时 ⌃2 不开、状态行 = 转场列那一句 | 过 |
| `testW5O8_unreadableMIDITableIsReported` | 没文件 = 空表不提示；坏 JSON = 空表 + 提示带路径；好表照读 | 过 |
| `testW5O8_noSignalCellShowsInputLastError` | 无信号 + 原因 → "无信号\n原因"、悬停全文；没原因只写无信号；真 NDI 找不到源（本机有 SDK）格子写"…NDI 源…" | 过 |
| `testW5O8_ndiBannerSaysBuildHasNoSDK` | 中英横幅写编译期、不再许诺"自己好" | 过 |
| `testW5O8_englishMediumCellTransitionTitleFits` | 英文中 / 大档 Transition、Cut 都不截；小档 Cut 全字 | 过（中档 Transition / Cut 全字、小档 Cut 全字，截图看过） |
| `DiskProtectionAppTests.testW5O8_belowMinimumFallbackNoticeSaysBelowMinimum` | 50 MB 小镜像 + 默认下限 200 MB + 备用目录 → 切过去，提示含"低于下限 200 MB"、不含"磁盘满" | 过 |
| `FunctionTranslatorTests.testC5_x51_upstreamFunctionNamesReturnNotImplemented` | 31 个精确名字 501 + 文案点名 + 不分大小写；编造的 NDI / Auto / Streaming… 开头仍 400 | 过 |
| `FunctionTranslatorTests.testC5_transitionStingerSlotWithoutInputIsNotConfigured` | Transition4（出厂）409 `NotConfigured: Transition4…`；选了输入照常；别的效果照旧 | 过 |
| `HotkeyTests.testW5O8_toggleOverlayEmptyChannelUsesPreview` | resolve 三种情形 + PVW 黑场不发 + 派发器反馈（同步 / 异步两条入口） | 过 |
| `HotkeyTests.testW5O4_stingerSlotWithoutInputRejectedWithFeedback` | ⌥4 / 回车被校验器拒（"转场 4 是 Stinger"）→ 反馈带槽号；别的拒绝不说；选了输入照常执行 | 过（要 110） |
| Stream Deck `cases.js` "pressFeedback（W5-O / 提案 029）…" | 被拒 → alert + warn；忽略 → info；成功不响 | 过（node 10/10、JXA 10/10） |
| 改了期望的老用例 | `PanelTests.testPanels_externalDisplayMenuAndWindowLifecycle`（关窗口 = 关这一路）、`InputStripTests.testUI_categoryFilterHidesOtherInputs`（颜色读 InputConfig）、`AudioSettingsRevampTests` 两条（压缩新开默认 compressor 再换动态处理器；监听四项）、`AudioEffectsTests.testAudioEffects_editorRangesWithinEngineClamp`（12 → 19 项）、`HotkeyTests.testHotkey_toggleActionsResolveAgainstState`（空通道 = PVW）、`FunctionTranslatorTests.testC5_transition2ExecutesSlot`（4 号回 409）、`PanelsRevampTests.testAudio_busChannelMapReachesDevice`（只改还原顺序） | 都过 |

整包 / 全量（运行记录见 §6）：SwitcherControl 81 过 + 1 跳（人工 C5）；Stream Deck node 10/10、JXA 10/10；`make test-app` 第 1 遍 262 = 254 过 + 6 跳 + 2 红（同机干扰，静机复跑都过）、第 2 遍 262 = 256 过 + 6 跳 + 0 红；lint 全绿（归属按 `--base p5-contracts-3`）。
阈值：本会话没有带阈值的测试 ID（App 行为用例），没动任何阈值。

## 3. 没做的和原因

1. **借 Master 不算"待应用"**（prompt 第 8 项写"只改总线声道对 / 借 Master 算进'待应用'"）：W4-C2 那张单子对着 G8b 之前的代码写；G8b 胶水已经让借 Master 当场落到跑着的引擎（`AudioEngine.borrowMasterForMonitor` 任意线程可设），算成"要重起引擎才生效"就是说谎。只把声道对算进去，用例钉住"借 Master 当场生效、不待应用"。要改口径请说。
2. **MIDI 音符执行没选输入的 Stinger 被拒时不提示**：MIDI 派发在 `SwitcherControl/MIDI/`，不在本会话目录（只准 Hotkeys/）；被拒照常（校验器在总线上，所有来源一样），只是没有状态行那句。要提示的话给 MIDIController 加同样的 `setFeedbackHandler`（照 HotkeyDispatcher，十来行）。
3. **LastSession 口径**（W4C2 settings 第 4 条）：prompt 写明用户没定、不动。
4. **多画面标签色点 / Stream Deck 按钮颜色读 `InputConfig.color`**：prompt 写明归各自会话。
5. **030 效果延迟进 Stats**：prompt 写明不做；压缩页的"延迟自测"读的是 App 能拿到的 `AudioEngineStatus`。
6. **英文小档（160）"Transition" 仍截**：两颗按钮在 60 pt 里放不下（Transition 要 58、Cut 要 29），按 prompt 选了"按标题宽分配"、没换短字；小档先截 Transition 保住 Cut，按钮有悬停提示。要全字只能换字（例如 "Auto"），英文手册的格子表要跟着改。
7. **格子"转场"在当前那组是没选输入的 Stinger 时**：它发的是 setPreview + autoTransition 两条，setPreview 照常生效、autoTransition 被拒（状态行说清楚）——PVW 会换成点的那一路但不转场。prompt 说界面三处不动，格子不在三处里，没加拦截；要像转场列那样先弹选择是一处界面改动（几行），请定。
8. **109 顺带报的 ⇧1–⇧0 实体键盘对不上**（`KeyCombo(event:)` 用 `charactersIgnoringModifiers`，⇧1 得到 "!"；reports/issues/W4C3-w5-app-gaps-found-by-docs.md 第 7 条，S2，在 Hotkeys/）：不在 112 的交付里，没改、没扩范围，交给用户 / G9 定归属。
9. **T-bar 推一个没选输入的 Stinger 当前那组**（110 报告 §4：照收，推过换底拍画面就换）：要不要在界面上拦是 App 的事，prompt 没写，没动。
10. KNOWN_ISSUES 的行不在本会话目录，G9 销号（S2 两条、监听菜单、Stinger 槽、X51、分类颜色、S3 一批）。

## 4. 对契约的疑问

1. 没有要改契约的地方。用到的都是已落地的：`setMonitorSource`（026，含 P5-3 的 headphones）、029 的 `TransitionSlot.isStingerWithoutInput` 与校验器文案、023 四的 `InputConfig.color` / `setInputColor` / `Show.migratingLegacyInputCategories()`、024 (b) 的 `compressor` / `peakLimiter.ceilingDb` 键表。
2. 各输入的 `lastError` 不在契约的 `Input` 协议里，App 用一个只读协议让七个输入类回溯遵守（`InputRuntime.swift`）。以后要让 API / Stats 也能读到"无信号的原因"（例如 `/api/v1/state` 的 inputStates 带一句），得提案把它进契约；现在只是界面用，没提。
3. `ControlFeedback` 是 SwitcherControl 的公开类型（Hotkeys/），不是 SwitcherContracts——只在控制层与 App 之间传，没进 wire format。

## 5. 下一个会话需要知道的坑

1. **本分支叠在 `p5-contracts-3`（9af1bf0）上**：G9 先合 110 再合本分支（merge-base 就是 9af1bf0）；`make lint BRANCH=w5-app-followups` 的归属一项按 main 算会把 110 的 17 个文件报越界，用 `scripts/check-ownership.sh w5-app-followups --base p5-contracts-3`（41 个文件都在范围内）。109 的 w4-docs-3 有一个提交（bfa6806）专写 110 + 112 合入后的行为，三路要一起合。
2. **设置的两种写法**：设置窗（常规 / 音频设备 / 远程控制 / 高级 / Tally）走 `AppController.commitSettings`（只写变了的键）；导入 / 恢复默认后的重读、用例还原走 `updateSettings(_:)`（整份）。新加设置项要在 `AppSettings.save(to:changedFrom:)` 里加一行（整份写回也走它，`old == nil`）。比较的基准是内存里的 `controller.settings`——测试宿主的 `applyTestHostOverrides` 会把 API 端口 / 地址 / tally 端口改成 0 / 127.0.0.1，所以测试宿主里这几项"变没变"按改过之后的值算。
3. **测试宿主的本机设置会被异步提交写脏**：设置窗的音频设备模型经 `receive(on: main)` 异步提交，用例在 defer / teardown 里还原之前要先关窗、`AppTest.pump(seconds: 0.1)`，不然还原在前、提交在后（本分支修了 PanelsRevampTests 那一处；看到"跑着的 session 带着奇怪的声道对 / 设备"先查 `defaults read com.plusmix.switcher.tests.<hash> audioBusOutputMap`）。
4. 用例里要自己的 UserDefaults suite 时用固定名字、用前用后 `removePersistentDomain`：UUID 名会在 ~/Library/Preferences 留一堆小 plist。
5. 分类颜色现在只在 `InputConfig.color`：输入条每个快照对一遍，界面别再往 layout 写颜色；`InputCategories.Color` = `InputColor`（界面叫法 / 画色在 `extension InputColor`）。
6. 压缩页：编辑器值模型 `EffectChainEditor` 多了 `compressor` 与 `setDynamicsKind`，`dynamics.present` 与 `compressor.present` 互斥——别直接把两个都置 true（`slots` 只会写 compressor，另一个丢）。
7. 控制层反馈：`HotkeyDispatcher.setFeedbackHandler` 在解析不出时同步调、被拒时在派发 Task 里调；App 的 `ControlRuntime` 一律切回主线程。`ControlAction.rejectionFeedback(for:in:)` 只认 029 那一种，别的拒绝照旧"命令被拒：…"。
8. 同机并行：111（`w2-stream-auth-stop`）跑 MediaMTX 推流用例时自己起一个 mediamtx 占同样的端口，App 的推流用例（BottomBarSplitTests 推流菜单、StreamingApp 那几条）会一直退避重连而红，等它停了再单独复跑；Chrome 盖住屏幕时多画面 / 外部显示的帧数用例 0 帧必红。Claude 的 Bash 里 shell 的 `sleep` 被拦，等东西用 python 的 `time.sleep`。
9. 目视检查：临时用例开窗、把窗口号写进草稿区、`screencapture -l<号> -o -x`（窗口被 Chrome 盖住也截得到），用完删用例。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0）。同机并行：109（手册）、110（契约，跑包测试）、111（推流鉴权，跑 MediaMTX 用例）、113（frameprobe）；负载 2.5–4.7。

| 项 | 结果 |
|---|---|
| 红灯轮（X51）`swift test --package-path Packages/SwitcherControl --filter …testC5_x51…` | 31 个名字 × 4 处红（全 400） |
| 红灯轮（第 1 / 2 项）`xcodebuild test -only-testing:SwitcherTests/W5OFollowupTests` | 4 条 19 处红 |
| 红灯轮（第 5 项） | 2 条红（颜色 [nil, nil, nil]、layout 旧键还在） |
| 红灯轮（兼容层 409） | 1 条 6 处红 |
| 红灯轮（Stream Deck） | `node --test` 整文件导入失败 |
| SwitcherControl 整包（叠 110 之后） | 81 过 + 1 跳（C5 人工），0 红 |
| Stream Deck | `node --test test/` 10/10，`scripts/run-jxa.sh` 10/10，`node --check bin/plugin.js` 过 |
| App 定向回归（每项做完） | W5OFollowupTests 17 + SettingsWindow / RemoteControl / Tally / Panel / LiveSafety / AuxLayering / AudioSettingsRevamp / OutputPages / Localization / InputStrip / ShowRoundTrip / PanelsRevamp / TransitionColumn / MixerPanel / DiskProtection / PlaybackStatus 的相关类：0 红（多画面 0 帧那条除外，见下） |
| `make test-app` 第 1 遍（11:48，同机 110 在跑它的 App 全量、111 在跑 MediaMTX 推流用例，负载 4.6–7.3） | 262 条 = 254 过 + 6 跳 + **2 红**（`xcrun xcresulttool get test-results summary --path .build/DerivedData/Logs/Test/Test-Switcher-2026.10.12_11-48-29-+0800.xcresult`）：`RecordingTests.testRecord_5sTwoTracksDurationExact`（起止拍差与按钮间隔差 1.27 帧 > 1，机器忙时的老毛病）、`BottomBarSplitTests.testUI_streamMenuListsDestinationsWithState`（主平台一直 backoff：111 的测试自己起了一个 mediamtx 占着同样的端口）。6 跳 = 键盘导航没开（C9）、摄像头权限、虚拟摄像头签名、空闲探针、ISO A4 / 推流 10 s 缺 release frameprobe |
| 机器静下来后（12:02，没有别的 PlusMix / xctest / mediamtx，负载 3.2）单独复跑 | 上面两条 + W5OFollowupTests 17 + RemoteControlPageTests + PanelTests：28 条 0 红 |
| `make test-app` 第 2 遍（12:03，同机没有别的 App / 推流用例） | **262 条 = 256 过 + 6 跳 + 0 红**（`.build/DerivedData/Logs/Test/Test-Switcher-2026.10.12_12-03-53-+0800.xcresult`）；6 跳同第 1 遍。App 用例数 244（G8b）→ 262：W5OFollowupTests 17 + DiskProtectionAppTests 1 |
| lint（`lint-rules` / `check-deps` / `check-ownership --base p5-contracts-3` / `check-help` / `check-links` / `check-rt-symbols`） | 全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 41 个文件（加本报告 42 个）都在范围 / Help 18 个文件一致 / 189 个 Markdown / RT 符号。`make lint BRANCH=w5-app-followups` 的归属一项按 main 算报 58 个文件越界——多出来的 17 个是 110 的（本分支叠在它上面），按 `--base` 算是干净的 |
| 目视 | 压缩页（类型 + 阈值 / 比例 / 补偿 + 延迟自测 0 帧）、限幅页天花板、无信号格子第二行、英文中档 / 小档格子：截图看过（草稿区，不入库） |
