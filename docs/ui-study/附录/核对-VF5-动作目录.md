> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# VF5 核对 R5（函数目录 / 快捷键 / MIDI / 兼容层 / 标题）

> 只读核对。仓库 worktree `vmix-28-guide-menu-ui-c83cd1` @ c836cce，`git status` 干净。
> 读图：16 张 Select Function 图（084–099）全部按原尺寸读过，其中 084 / 086 / 087 / 088 / 090 / 091 六张放大逐行对；
> 滚动条用 `sips -s format bmp` + 逐像素扫描量（脚本 `$SP/vf5-tmp-sb.py`）。标题图 048 / 054 / 056 / 059 抽看。
> 兼容层判定：把仓库里的 `FunctionCatalog.swift` 原样拷到 `$SP/vf5-tmp-compat/`，配一个照抄 `FunctionTranslator.plan` 按名分流逻辑的 main.swift，用 swiftc 编译后跑 247 个名字。isKnownUpstream 用的是真代码，没有手工复刻。
> 判定：✅ 对 / ⚠️ 大体对但要改措辞、口径或补证据 / ❌ 错 / ❓ 证据不足

## 1. 函数清单

| # | 报告说法 | 判定 | 核对结果 |
|---|---|---|---|
| 1.1 | 图 084 Transition 的 39 行 | ✅ | 逐行一致：19 个效果名（Fade…Cut，顺序与报告 A1 相同）、const_43–46、CutDirect、FadeToBlack、QuickPlay、SetFader、SetTransitionDuration1–4、SetTransitionEffect1–4、Stinger1–4。没有漏抄、错抄或多抄 |
| 1.2 | 图 086 General 9 行 | ✅ | ActivatorRefresh、CallManagerShowHide、KeyPress、SendKeys、SetDynamicValue1–4、Undo。完整，没有滚动条 |
| 1.3 | 图 087 Audio 的 39 行 | ✅ | 23 个有名字的（Audio … BusXSolo）加 16 个 const（162、164、165、167、168、170–172、174、175、182、183、197、199–201），逐行一致 |
| 1.4 | 图 088 Output 31 行 | ✅ | const_464 + 30 个有名字的（Fullscreen … WriteDurationToRecordingLog），放大后拼写逐个一致（StartSRTOutput、SetOutputExternal2、StreamingSetUsername）。没有滚动条 |
| 1.5 | 图 090 Input 的 39 行（加选） | ✅ | 16 个有名字的（ActiveInput … ColourCorrectionReset）+ 23 个 const（264 … 350），一致 |
| 1.6 | 图 091 Overlay 34 行（加选） | ✅ | Move/MultiViewOverlay 4 个、OverlayInput1–4 ×（空 / In / Last / Off / Out / Zoom）24 个、AllOff、PreviewOverlayInput1–4、SetMultiViewOverlay，完整，一致 |
| 1.7 | 其余 10 张（085、089、092–099）的数目和名字 | ✅ | All 39、Title 24、PlayList 5、Scripting 5、Replay 39、NDI 5、PTZ 22、Preset 3、DataSources 9、Browser 8，名字全部对得上 |
| 1.8 | "五类在 39 行处截断" | ✅ | 只有 All / Transition / Audio / Input / Replay 有滚动条，滑块都在顶端（y 66 起）；其余 11 张 x 395–413 上没有滑块。39 行 × 12 px 正好填满列表框 |
| 1.9 | 滑块长度 23 / 394 / 158 / 62 / 111 px | ✅ | 实测分别为 66–88、66–459、66–223、66–127、66–176，与报告逐一相符。⚠️ 小问题：报告的百分比（90 / 36 / 14 / 25 / 5 %）实际是按约 434–440 px 的有效滑道算的（灰底 y 49–516，两端各留 17 px 箭头区，所以是 y 66–499），F 节只写了"列表框 y 47–518"，读者照这个 471 px 去算会得出另一组数。建议把有效滑道长度写明。估算总数误差在 3 % 以内，可以不改 |
| 1.10 | "64 个 const_NNN"及各类分布 | ✅ | 4 + 16 + 1 + 23 + 11 + 1 + 8 = 64，编号段与报告 F 节一致 |
| 1.11 | 311 行可见、247 个有名字 | ✅ | 不含 All 共 311 行，减去 64 个 const 得 247 |
| 1.12 | A1 其余细节 | ✅ | 16 个分类、打开时搜索框里有光标（084）、点过分类后没有光标（086）、"Fade"蓝底、窗口 416×530、只有 ×；图 082 下方的 "Mix" 下拉值为 "1"；类内按字母排、不分大小写（例：ColourCorrectionReset 排在 const_264 前） |

D2 统计表的内部核算：15 类的有 / 部分 / 无 / 已映射 / ［键］逐类重算，与报告的 58 / 34 / 155 / 47 / 16 完全一致；"读法"一段的 104 + 12 + 39 = 155 也对。

## 2. 有无判断（抽 40 行，重点抽"无"和"有"）

| # | D2 行 | 报告 | 判定 | 证据 / 说明 |
|---|---|---|---|---|
| 1 | Transition · Fade | 有［键］ | ✅ | Command.swift:13；Localizable.strings:261 "Fade（拍数）" |
| 2 | Transition · Slide / SlideReverse | 无 | ✅ | TransitionType 只有 cut / fade / wipe / zoom / stinger（MixerState.swift:6–7）；slide 只是叠加的进出动画（MixerState.swift:128–130） |
| 3 | Transition · VerticalWipe / …Reverse / WipeReverse | 部分 | ✅ | WipeDirection 有 rightToLeft / topToBottom / bottomToTop（MixerState.swift:16–17） |
| 4 | Transition · CutDirect | 有［键：直切 PGM］ | ✅ | Command.swift:24；HotkeyEditorPanel.swift:12 |
| 5 | Transition · QuickPlay | 部分 | ✅ | 补一句：HTTP API 的批量 `{"commands":[…]}` 一个请求就能发 setPreview + autoTransition（docs/api.md:51），只有快捷键做不到 |
| 6 | Transition · SetFader | 有（MIDI CC → T-bar） | ✅ | Command.swift:26；MIDIMappingPanel.swift:16 |
| 7 | Transition · SetTransitionDuration2–4 | 无 | ✅ | TransitionState 只有一个槽 |
| 8 | Transition · SetTransitionEffect1 | 有 | ✅ | setTransition(type, d)，只有 5 种类型 |
| 9 | Transition · Stinger1 | 有 | ✅ | setTransition(stinger) + autoTransition；输入经 setTransitionParams 设 |
| 10 | Transition · Stinger2–4 | 无 | ✅ | StingerParams 只有一组（MixerState.swift:33–43） |
| 11 | General · ActivatorRefresh | 无 | ✅ | 仓库里没有 MIDI 输出代码（MIDISend、MIDIOutputPort 都搜不到）。补充：兼容层自己有 ACTS 推送（Activators.swift:62 `events(from:to:)`），在兼容层里"重推全部 ACTS"可以做，不必等 MIDI 回灯 |
| 12 | General · SendKeys | 无 | ✅ | 没有 CGEvent 发键代码 |
| 13 | General · Undo | 无 | ✅ | 没有 UndoManager；菜单里的"撤销"走的是响应链的 `undo:`（AppDelegate.swift:91） |
| 14 | Audio · Audio | 有［键：静音开关］ | ✅ | ControlAction.swift:11、26–28 |
| 15 | Audio · AudioAuto / On / Off | 部分 | ✅ | 每路有 `afv`（Input.swift:296–300），但全局 AFV 关着时这一位不起作用 |
| 16 | Audio · AudioBus / On / Off | 有 | ✅ | setInputSettings 改 routing。小注：只有 M / A / B；参考软件的总线更多（兼容层文档 ACTS 写了 "BusA–GSolo"），Value 取其他总线时做不到 |
| 17 | Audio · AudioMixerShowHide | 部分 | ✅ | 窗口 › 调音台（AppDelegate.swift:148）不是命令 |
| 18 | Audio · AudioPluginShow | 无 | ⚠️ | 按 #17 的同一口径应算"部分"：输入设置有"效果链"一节（InputSettingsPanel.swift:13），调音台能直接打开输入设置（MainWindowController.swift:151），只是没有命令 |
| 19 | Audio · BusA / B / XAudioOff | 有 | ✅ | busMute（Command.swift:42） |
| 20 | Audio · BusXSendToMaster | 无 | ✅ | BusState 只有 bus / gainDb / muted / effects（MixerState.swift:290–297） |
| 21 | Audio · BusXSolo | 无 | ✅ | 同上；兼容层 ACTS 的总线独听恒为 0 |
| 22 | Output · Fullscreen / On / Off | 有 | ✅ | setOutputEnabled 管 externalDisplay（Command.swift:56–59） |
| 23 | Output · SetOutput2 / 3 / 4 | 有（整体替换） | ✅ | OutputSettings.source（MixerState.swift:542）。"输出 2" 对应我们哪个编号要另定规则 |
| 24 | Output · SetOutputExternal2 | 有 | ❓ | 要看 External 2 对应哪种输出。虚拟摄像头"送的是 PGM（不可选来源）"（docs/user/输出.md:93）；对应外部显示或 NDI 才算"有"。#26 那行又把 External 算到虚拟摄像头上，两行的口径互相打架 |
| 25 | Output · Snapshot / SnapshotInput | 无 | ✅ | App、Control、Outputs 里都没有 JPEG / PNG 编码（CGImageDestination、pngData 都搜不到）；HTTP 只有 state / commands / log / tally / command / events 几个路由（APIServer.swift:100–166） |
| 26 | Output · Start / Stop / StartStopExternal | 有 | ⚠️ | 应为"部分"：OutputKind 没有采集卡 / SDI 输出（MixerState.swift:367，输出包里也搜不到 DeckLink 输出），报告自己写的"送采集卡"那半做不到，只覆盖虚拟摄像头、外部显示和 NDI |
| 27 | Output · Start / Stop / StartStopMultiCorder | 部分（"逐个 startRecord，没有一键"） | ⚠️ | "部分"没错，理由不准。底栏"录制"本来就一键起停全部录制输出，含 ISO，而且在同一拍（BottomBarView.swift:195–211；docs/user/输出.md:8）。真正缺的是"只起停 ISO"，以及快捷键 / 命令层的"全部录制输出"动作。R5-G09 的"ISO 一键：部分（逐个 startRecord）"要一起改 |
| 28 | Output · Start / Stop / StartStopRecording | 有［键］ | ✅ | ControlAction.swift:12、29–31 |
| 29 | Output · StreamingSetKey / URL | 有（整体替换） | ✅ | StreamSettings 有 url 和 streamKey（MixerState.swift:450–458） |
| 30 | Output · WriteDurationToRecordingLog | 无 | ✅ | 输出包里没有 marker / chapter |
| 31 | Title · SetText | 无 | ✅ | InputKind 没有标题类（Input.swift:4–5）；搜不到 CATextLayer / CARenderer |
| 32 | Title · Start / Stop / PauseCountdown | 无 | ✅ | ClockView 只是给操作员看的时钟（ClockView.swift:1），没有倒计时 |
| 33 | Title · SetImage | 部分 | ✅ | setInputSource(.image)；路径不变就不重建（见 §5） |
| 34 | Input · AddInput | 有（只有 API） | ✅ | Command.swift:68 |
| 35 | Input · AutoPlayOn / Off、AutoRestartOn / Off | 无 | ✅ | 命令层和状态层都没有。补充：FileInput 自己已有 `pause()`、`resume()`、`seek()`（FileInput.swift:278–317），只是 App 没接，所以 §2.5 的成本比"无"看起来低 |
| 36 | Input · ColourCorrectionAuto / Reset | 无 | ✅ | EffectSlot 只有三种音频效果，原文写"视频效果格…目前没有"（CONTRACTS.md:139–149） |
| 37 | Overlay · OverlayInput1–4Last | 有［键］ | ✅ | toggleOverlay（ControlAction.swift:23–25） |
| 38 | Overlay · OverlayInput1–4Off | 部分 | ✅ | 这行本身没问题，但 R5-G04 写的是"立即关：无"，两处口径要统一 |
| 39 | Overlay · PreviewOverlayInput1–4 | 无 | ✅ | previewOn 只把已经可见的叠加也画进 PVW（CompositorPasses.swift:320–321；`isDrawable` 在 586 行，要求 isVisible && animProgress > 0），名字一样，意思不一样 |
| 40 | NDI · NDISelectSourceByName | 有 | ✅ | setInputSource(.ndi(sourceName:))，编号和引用保留（Command.swift:71–73） |

另外整族抽查：PTZ、Browser、DataSources、PlayList、Scripting、Replay 判"无"都成立（全仓库 Swift 里搜不到 PTZ、VISCA、WKWebView、Playlist、DataSource、JavaScriptCore；Replay 只在兼容层测试里出现）。

结论：40 行里 ✅ 36、⚠️ 3（#18、#26、#27）、❓ 1（#24）、❌ 0。没有发现"已经有的被报成没有"，只有 #18 这一处口径不一致；夸大的只有 #26 这一处。

## 3. 兼容层

| # | 报告说法 | 判定 | 核对结果 |
|---|---|---|---|
| 3.1 | 可见函数里映射了 47 个 | ✅ | 真 FunctionCatalog 编译后跑出来：映射 47 / 501 169 / 400 31，逐类数目也和 D2 一致（Transition 10、Audio 9、Output 6、Input 1、Overlay 21） |
| 3.2 | 31 个真实函数名返回 400 UnknownFunction 而不是 501 | ✅ | 清单完全一致：ActivatorRefresh、AudioChannelMatrixApplyPreset、AudioMixerShowHide、StreamingSet×4、ChangeCountdown、ResumeRender、SuspendCountdown、AutoPause/Play/Restart 族 12 个、ColourCorrection×2、MoveMultiViewOverlay、NDI×4、LastPreset、OpenPreset。状态码映射在 VMixCompatConfiguration.swift:68–74；HTTP（CompatHTTPServer.swift:80、85）和 TCP（CompatTCPServer.swift:149）都经 VMixCompatServer.swift:206 进 plan，中间没有预过滤。代码自己把 unknownFunction 定义为"上游也没有这个名字"（VMixCompatConfiguration.swift:49），所以这 31 个按代码自己的定义也是判错了 |
| 3.3 | "AudioAuto 与 Fullscreen / External 不映射的理由过时" | ⚠️ | 只对了一半。① docs/integrations/vmix-compat.md:129–130 写于 2026-09-19（0c55a2a），每路 afv 和 setOutputEnabled 是 2026-09-23（cb85fbe）才进契约的，两条理由确实过时 ✅。② docs/api/vmix-compat.md 报告没有引。这份写于 2026-09-28（fc19bd4），第 42 行 External / Fullscreen 的理由"没有对应的开关命令"同样过时，要补引用；第 43 行 AudioAuto 的理由已经改成"全局开关 + 每路标志，语义不同"，这个理由现在仍然成立：每路 afv 只在全局 AFV 开时起作用（Input.swift:296–299），把 AudioAuto 映射到 setInputSettings(afv) 是有损的。报告 B4、R5-G25、E5 说"两条都过时"并把这个映射当成直接可做，要改 |
| 3.4 | 修法："加前缀 NDI / Streaming / Auto / ColourCorrection 等" | ⚠️ | 不建议加前缀。现有前缀族本来就把编造的名字判成 501：实测 SetFoo、StopTheWorld、KeyboardSmash、PlayDoom、BusStop 都返回 NotImplemented（"上游有"）。再加 Auto、NDI 前缀，会让 AutoAnything、NDIAnything 也变成 501。应该把这 31 个精确名补进 knownUnimplemented |
| 3.5 | "错误码改回 501" | ⚠️ | 措辞问题：它们从来没有返回过 501，应写"改成 501" |
| 3.6 | 补映射 Fullscreen / External → setOutputEnabled | ⚠️ | 报告漏了一个设计点：兼容层的 ACTS `External` 和 XML `<external>` 已经按外部显示算（Activators.swift:33、82；StatusXML.swift:53–55），XML 的 `<fullscreen>` 写死为 False（StatusXML.swift:62）。Fullscreen 和 External 各对应哪种输出、多个同类输出时用哪一个（参考 recordOutput 那样的配置项），都得先定下来，而且要和 XML / ACTS 保持一致 |
| 3.7 | （报告没提）改映射会碰到的用例 | ⚠️ | FunctionTranslatorTests.swift:239 的 C5 用例把 StartExternal、SetOutput2、AudioAuto 钉成 NotImplemented。补映射时要同步改这条用例，以及两份兼容层文档（integrations:128–131、api:41–43） |
| 3.8 | 行号引用 | ✅ | FunctionCatalog.swift:18–82 / 91–125 / 128–134、FunctionTranslator.swift:18–180 / 165–167 / 176–179 / 258–271、docs/integrations/vmix-compat.md:3–11 / 128–131 都对得上 |

## 4. 编辑器缺陷

| # | 报告说法 | 判定 | 核对结果 |
|---|---|---|---|
| 4.1 | 快捷键编辑器把某行切到"其他命令"后，保存时会悄悄存成 Cut（HotkeyEditorPanel.swift:54、77） | ✅ 行为属实 / ⚠️ 引用不准 | 成因链是这样的：Picker 直接绑 `$row.kind`（196），不经过 `set(action:)`；非"其他"行的 `other` 在 47 行已被清成 nil；取 `action` 时 77 行兜底成 `.cut`。54 行是从 JSON 读入时把 kind 置成 other 的地方，不是成因，引用应改为 "47、77、196"。补两点：① 只有"原本不是其他命令"的行会中招，从 JSON 读进来的"其他"行切走再切回，原命令还在（Picker 不清 `other`）；② 没有用例覆盖，ControlEditorTests.swift:72–76 只测了行和 ControlAction 的往返 |
| 4.2 | MIDI 面板里这种行的下拉显示空白（MIDIMappingPanel.swift:270） | ✅ | 264 行把动作转成 Row，kind = other；270 行把 other 从选项里滤掉，选中值没有对应的 tag，所以显示空白。旁边也不显示命令内容（快捷键编辑器至少会显示原始描述）。只要不去动这个下拉，保存时数据不会丢 |
| 4.3 | 快捷键编辑器 12 种动作 | ✅ | ActionKind 12 个 case（HotkeyEditorPanel.swift:12），文案在 Localizable.strings:259–271 |
| 4.4 | MIDI 11 种 | ✅ | 就是 12 种去掉 other（270）。小注：这是 Note 触发下的离散动作；MIDI 另外还有 T-bar / 输入增益 / 总线增益三种连续动作（MIDIMappingPanel.swift:16）。B2 写的"T-bar / 输入增益 / 总线增益 / 动作 / 命令"容易被读成 5 项，实际是 4 项，第 4 项的标题叫"动作 / 命令"（Localizable.strings:397） |
| 4.5 | Fade 参数单位是拍 | ✅ | `fade(durationTicks:)`；标签 "Fade（拍数）"、"拍数"（Localizable.strings:261、277）；兼容层才把毫秒换成拍（FunctionTranslator.swift:258–271） |
| 4.6 | B1、B2 的其余细节 | ✅ | 窗口 760×520 可缩放（HotkeyEditorPanel.swift:231；PanelWindowController.swift:23）；MIDI 窗口 820×520（MIDIMappingPanel.swift:290）；两个菜单项挂在"切换"下且没有快捷键（AppDelegate.swift:110–111）；偏好设置里没有入口（PreferencesPanel 搜不到 hotkey / midi）；默认表 23 行（HotkeyTable.swift:56–70；ControlEditorTests.swift:67）；一个组合键只发一条命令（HotkeyDispatcher.swift:38–42）；App 没有用 CommandCatalog（App/Sources 里搜不到） |

## 5. 标题

| # | 报告说法 | 判定 | 核对结果 |
|---|---|---|---|
| 5.1 | 图片只解码一次（ImageInput.swift:8） | ✅ | 8–10 行的注释写明"一次解码…之后帧槽里永远是同一帧"；文件里没有 reload、修改时间、DispatchSource、FSEvents 之类的逻辑 |
| 5.2 | 同一路径的文件改了不会重载（InputRuntime.swift:43–46） | ✅ | 46 行只在 `source` 不等时才删掉重建；路径不变，source 就相等。补充一点，能加强 R5-M07 的理由：现在要让改过的 PNG 生效，只能换一个路径再"应用来源"；另一条路"应用并重起引擎"（AppController.swift:173–178）会用 `stoppingOutputs` 停掉全部输出，直播中用不了 |
| 5.3 | 添加输入一次只能选一个文件 | ✅ | AddInputSheet.swift:683–685 设了 `allowsMultipleSelection = false`，图片和视频共用这一个函数；App 里也没有拖放入口（搜不到 registerForDraggedTypes、onDrop） |
| 5.4 | Add Input 只有 8 种来源，没有标题 | ✅ | AddInputSheet.swift:17–18；Input.swift:4–5 |
| 5.5 | 下三分之一预设、叠加动画、输入格子上的 1–4 按钮 | ✅ | OverlayPanel.swift:23（0 / 0.75 / 1 / 0.25）；MixerState.swift:128–130；InputCellView.swift:225–233 |
| 5.6 | 标题图 048–059 的描述 | ✅ | 12 个页签，MultiView / Legacy / All 字色偏浅；每页 3×3、带滚动条；MultiView 页 2 个（MultiViewHD、MultiViewHD2）；Recent 页 1 个（Timer Right Red）；GT Timer 页的时刻互不相同（05:38:44、05:37:26、05:37:06、05:36:30 PM）；底栏有 Number "1" / OK / Cancel，顶部有路径框和 Browse |

## 6. 统计与需要改的条目

**统计**：共核 72 条（§1 12 条、§2 40 行、§3 8 条、§4 6 条、§5 6 条，§4.1 按 ⚠️ 计）：

| | ✅ | ⚠️ | ❓ | ❌ |
|---|---|---|---|---|
| §1 函数清单 | 12 | 0（1.9 附一条口径说明，不影响数值） | 0 | 0 |
| §2 有无判断 | 36 | 3 | 1 | 0 |
| §3 兼容层 | 3 | 5 | 0 | 0 |
| §4 编辑器缺陷 | 5 | 1 | 0 | 0 |
| §5 标题 | 6 | 0 | 0 | 0 |
| 合计 | 62 | 9 | 1 | 0 |

核心数字全部复现：311 / 247 / 64、五类截断、滑块像素、47 / 169 / 31、12 / 11 种动作。没有 ❌。

**R5 需要改的条目**（按影响排序）：

1. **D2「Start / Stop / StartStopExternal」有 → 部分**：没有采集卡 / SDI 输出（MixerState.swift:367），只覆盖虚拟摄像头、外部显示和 NDI。统计随之变为 Output 有 20→17、部分 7→10。
2. **D2「AudioPluginShow」无 → 部分**：与 AudioMixerShowHide 同一口径（输入设置 › 效果链，调音台可以直接进）。统计变为 Audio 部分 11→12、无 3→2。1、2 两条合计后总数为 **有 55 / 部分 38 / 无 154**（仍是 247）；"读法"一段里的"音频 3"改成 2、"剩下 39 个"改成 38。
3. **D2「SetOutputExternal2」补条件**：虚拟摄像头只送 PGM（docs/user/输出.md:93），只有 External 2 对应外部显示或 NDI 时才算"有"；和第 1 条对 External 的解释统一。
4. **D2「MultiCorder」和 R5-G09 改理由**：底栏"录制"已经一键起停全部录制输出（含 ISO，同一拍；BottomBarView.swift:195–211），缺的是"只起停 ISO"和快捷键层的"全部录制"。
5. **B4 / R5-G25 / E5 的"两条理由都过时"改成分文档说**：integrations 文档两条都过时；api 文档第 42 行（External）也过时，要补引用；第 43 行（AudioAuto）已改成"全局 + 每路，语义不同"，这个理由仍成立。AudioAuto → afv 要注明"只在全局 AFV 开时生效"，或者一并决定映射时是否顺带打开全局 AFV。
6. **R5-G25 的修法改为精确名**：不要加 Auto / NDI / Streaming / ColourCorrection 前缀，前缀族已经把 SetFoo、StopTheWorld 之类判成 501；"改回 501"改成"改成 501"。
7. **R5-G25 / E5 补两个坑**：① C5 用例 FunctionTranslatorTests.swift:239 钉着 StartExternal / SetOutput2 / AudioAuto = NotImplemented；② 兼容层 XML / ACTS 已把 External 当外部显示，`<fullscreen>` 写死 False（StatusXML.swift:53–62；Activators.swift:33、82），要先定 Fullscreen 和 External 各对哪种输出、同类有多个时用哪个。
8. **B1 / R5-M04 的行号**："HotkeyEditorPanel.swift:54、77" 改成 "47、77、196"，并注明"没有用例覆盖"。
9. **R5-G04 与 D2 口径统一**："立即关"一处写"无"，一处写"部分"。
10. **R5-M07 / B5 补一句**：现在让改过的 PNG 生效只能换路径；"重起引擎"会停掉全部输出（AppController.swift:173–178）。
11. 可选：AutoPlay / AutoRestart 行注明 FileInput 已有 pause / resume / seek（FileInput.swift:278–317）；ActivatorRefresh 行注明兼容层 ACTS 可以"重推全部"（Activators.swift:62）；F 节写明有效滑道长度约 434 px（y 66–499）；B2 的"动作 / 命令"注明是一个选项。
