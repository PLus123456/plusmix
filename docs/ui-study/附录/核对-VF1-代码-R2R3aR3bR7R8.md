> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# VF1 代码结论核对（R2 / R3a / R3b / R7 / R8）

树 = c836cce（worktree vmix-28-guide-menu-ui-c83cd1，只读）。行号都相对仓库根。
方法：逐条读代码。另在 scratchpad/vf1/ 跑了两个 20 行 AppKit 探针（不碰仓库、不起 App）：`NSButton.isFlipped == true`；键盘导航关着时，让按钮当第一响应者再送空格，事件仍落到窗口 keyDown、按钮没触发。
判定：✅ 属实　⚠️ 部分属实　❌ 不属实　❓ 无法确认。✅ 行里的"小修"是行号或措辞问题，不影响结论。

## 1. 缺陷类结论

| 报告编号 | 结论（一句话） | 判定 | 依据（文件:行号 + 一句话） | 对正式文档的修改建议 |
|---|---|---|---|---|
| R8-S18 | 每路 EQ / 压缩：界面能编辑，音频引擎不读 | ✅ | AudioEngine.swift:464-477 的 applySettings 只落增益 / 静音 / 独听 / 声像 / 路由 / 延迟；rec.settings 是 InputAudioSettings，`InputSettings.effects`（Input.swift:391）进不了音频引擎。C 混音器的 sw_input_slot 没有效果格（sw_mix_internal.h:54-90），效果格只在总线上（:91-108）。另查了 AudioRuntime.swift（只配设备、对齐延迟、监听点）、Tools/switcher-headless、SwitcherTestKit，都没有别的路径往混音器装效果 | 结论照写。小修：R8 把 MixerPanelView.swift:129 当"界面"证据不对。那是 `MixerModel.setInputEffects`，只有 App/Tests/MixerPanelTests.swift:47 调它，调音台条子上没有每路效果按钮。界面证据只留 InputSettingsPanel.swift:88、208（效果链页） |
| R8-S19 | 四条总线的效果链：界面能编辑，引擎不读 | ✅ | AudioEngine.swift:372-374 收到 .buses 后调 applyBuses（479-489），只设 gain / mute，不看 `bs.effects`。installEffect / installStandardEffects（BusEffectChain.swift:83、112）全仓只有 SwitcherAudio 的测试在调（EffectChainTests、DeviceTests、RealtimeTests）。界面在 MixerPanelView.swift:148-152、355、364-386。reports/w3-app2.md:56 自己写着"音频引擎暂不读效果"，docs/user/概念.md:78 却按已生效写。C 端每条总线 EQ / 动态 / 限幅各 1 格（sw_audio_rt.h:68），界面允许 3 段 EQ（AudioEffectParams.swift:73） | 结论照写。效果 sheet 的说明（Localizable.strings:431）也没写"未生效"，可以一起列进修改项 |
| R7-M02 | 一路 failed 后 enabled 仍为真；再按底栏"推流"会把正常的几路一起停掉 | ✅ | OutputRuntime.swift:222-234：failed 只在 enabled 变 false 时清，failed 还在就不重起。BottomBarView.swift:216-224：只要有一路 enabled，就对所有 enabled 的路发 stopStream。口径要写准：App 里推流的 failed 只来自"起不来"（没有地址、scheme 不认、StreamOutput 建不起来，OutputRuntime.swift:512-532）。断网的路重连不限次数（App 不传 reconnect，StreamOutput.swift:97-98 默认 maxAttempts = nil），一直停在 connecting / backoff，不会变 failed | 正式文档把 failed 写成"起不来的那一路（地址缺或不认）"，不要写成"断线后放弃"。另补一句：在推流页把地址改对之后也不会自动重试（被 failed 挡着），要先停再起 |
| R7-M10 / G07 | RTMP 地址里的 user:pass@ 被丢 | ✅ | StreamDestination.swift:54-60 新建 URLComponents 拼 connectURL，只拷 scheme / host / port / path / query；HaishinKitTransport.swift:109、184 连的就是 connectURL。SRT 分支用 `c = comps`（:69），userinfo 保留，不受影响 | 照写，限定为"RTMP / RTMPS" |
| R7-M12 | 推流页每按一个键发一次 setOutputSettings；在推的路改参数不生效也不提示；删除在推的路不确认 | ✅ | 地址 TextField 和密钥 SecureField 直接绑 text（OutputSettingsPanel.swift:528-529），经 updateOutput 每变一次就发（:93-100）。reconcile 对在跑的推流只看 enabled（OutputRuntime.swift:233-234），不比较设置；页上没有提示。"删除目的地"直接 removeOutput（:542、:102-105），运行表随即 stopStream（OutputRuntime.swift:220）。对照：ISO 页正在录的路会锁住（:513）；NDI 页的名字 / 分组要回车或点"应用"才发（:668-679） | 小修："每按一个键"只对地址和密钥成立。码率、音频码率是带 format 的数字框，回车或失焦才提交；Stepper 每点一下发一次 |
| R7-M15 | ISO 路创建时抄一次 PGM 的编码 / 目录，之后不跟；ISO 页余量按 PGM 目录算 | ✅ | ISORoutes.swift:24-33 只在创建时复制。录制页只改 recordOutput（source == .program 的第一条，OutputSettingsPanel.swift:124-140、496-502）。余量估算的目录取 PGM（ISORoutes.swift:38），码率却按全部录制路相加（:41） | 行号小修：钉住"创建时抄"的测试在 App/Tests/ISOAppTests.swift:118-119（报告写 117-118） |
| R7-M04 | 底栏推流文案只看第一路；"n 路"是目的地总数；第一次连接也显示"重连中（第 1 次）"；其余 state 原样显示英文"推流 · failed" | ⚠️ | 前三点属实：用的是 streams.first（BottomBarView.swift:145）和 streams.count（:150）；connecting 时显示 reconnects + 1 = 1（:151-152）。第四点：原样显示英文属实（:153-154，Localizable.strings:177），但 App 里推流到不了 failed（重连不限次数，见 R7-M02）。用户实际会看到的是起不来那一路的"推流 · idle"：没进 streams 表的输出在 Stats 里报 idle（OutputRuntime.swift:742、837-838） | 例子换成"推流 · idle"（起不来时）。再补：括号里的 n 不是尝试次数（见 §4 第 3 条） |
| R8-S34 | 录制 / 推流没有逐路统计；状态行的"码率"可能是录制的；没有时长 | ✅ | StatusLineFormatter.swift:26-33 取第一个在跑的非 NDI 项。encoder[] 与 outputs 同序，默认节目里录制是输出 1，所以录制和推流同时开时显示的是录制码率；标签只写"码率"（Localizable.strings:687）。全 App 找不到时长 | 照写 |
| R3a-M19 | 新建 / 打开不确认，直接停掉录制和推流 | ✅ | AppDelegate.swift:187-192 → AppController.newShow / openShow（:203-215）→ replaceSession → stopSession（:125、145-151）→ SwitcherSession.stop → outputs.stopAll（SwitcherSession.swift:290）。整条路径没有任何 NSAlert | 照写。另补：没保存的改动也直接丢（见 §4 第 5 条） |
| R3a-M20 / R8-U02 | 另存为之后窗口标题变成代码名"Switcher" | ✅ | AppController.swift:264 在 write() 里写 `"Switcher \(SwitcherVersion.current) — \(s.name)"`。write() 由另存为和已有文件时的"保存"（:232-235）共用，所以普通保存也会触发。MainWindowController.swift:71、181、185 用的是 ProductName.display；W4-D 改名只改了这三处（reports/w4-rename.md:21），漏了 :264 | 写成"保存或另存为之后"。R8-U02 只说"另存为后"，范围偏窄 |
| R3a-M08 | Fade 按钮提示写"回车"，默认表里回车是 autoTransition | ✅ | TransitionPanelView.swift:78 写死 `fadeButton.toolTip = L("key.return")`（值为"回车"，Localizable.strings:350）；HotkeyTable.swift:67 把 return 绑到 .autoTransition（:66 是空格 → Cut）。提示不查快捷键表 | 照写 |
| R3a-M09 | 点 Fade 会把下一次转场的类型改成 Fade | ✅ | MixerReducer.swift:81-85：`.fade` 先写 type = .fade 再 startAuto。按钮（TransitionPanelView.swift:153）和菜单（AppDelegate.swift:205-208）都发 .fade。之后界面上只有 T-bar 标签变成"T-bar：Fade"（:139），没有别的提示 | 照写 |
| R3a-M28 | 主窗口按钮都没设 refusesFirstResponder（推测：键盘导航下空格会按到按钮） | ✅（代码事实）／❓（推测） | 全仓只有 TBarView.swift:31 覆盖了 acceptsFirstResponder = false；Theme.button / toggleButton（Theme.swift:46-60）都不设。MainWindow 只在 keyDown 截键（MainWindowController.swift:14-17），keyDown 在响应链末端。推测部分：探针里键盘导航关着，按钮当第一响应者时空格仍落到窗口 keyDown、按钮没触发。键盘导航开着的情况要改系统设置，没测 | 正式文档只写代码事实，推测部分标"未实测"，不能写成已确认的缺陷 |
| R3b-M14 | 转场进行中 setPreview 不被拒、会换掉正在进来的画面；autoTransition 被拒 | ✅ | MixerReducer.swift:97-99 的 autoTransition 有 `guard !isActive`，100-102 的 setPreview 没有；CommandValidator.swift:24-25 只查引用。渲染器每帧按 state.preview 取新画面（CompositorPasses.swift:266） | 照写。另补：setProgram 同样不拦（:103-105），见 §4 第 8 条 |
| R3b-M15 | 运行中改 setInputSource 会重建这一路，文件从头播 | ✅ | InputRuntime.swift:43-49：source 一变就 remove 再 add；新建的 FileInput 从加载那一刻起按节目时钟走 | 小修：同一格前半句"循环只能在添加时选"和后半句矛盾。输入设置 › 来源也能改结束动作，只是会重建 |
| R3b-M07 | 叠加 popover 是 transient，点主窗口任何地方就关 | ✅ | MainWindowController.swift:278-281 设了 `popover.behavior = .transient`；OverlayPanel.swift:116-169 每改一项立即发命令 | 照写 |
| R2-M09 / G24 | 16 个号用满后，添加面板照样能点"添加"，命令被拒后只在底栏提示；上限 max(16, 最大编号) 在开节目时定死 | ✅ | 上限：SwitcherSession.swift:134-135 设 `maxInputs: max(16, maxNumber)`，Engine.swift:101 在 init 里定容量。面板：没有空号时 AddInputSheet.swift:225-228 返回 maxInputs（即 16），freeNumbers 为空（:316-321）；"添加"按钮没有禁用条件（:720），confirm 发出 addInput 后就关面板（:756-760）。拒绝：CommandValidator.swift:45 以"输入 16 已存在"拒掉 → ControlRuntime.swift:154-155 → 底栏提示（SwitcherSession.swift:163） | 照写 |
| R2-G14 | 视频文件输入不收纯音频文件；打开面板只列视频类型 | ✅ | FileDecoder.swift:36、41、70：没有视频轨就抛"文件里没有视频轨"。AddInputSheet.swift:684 的 allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie] | 照写。路径框可以手填，但手填的纯音频文件照样报错 |
| R8-S13 | FTB 时长没有命令也没有界面；docs/user/概念.md:63 说"默认与转场相同"，实际是两个独立值 | ⚠️ | 前半属实：Command.swift 里只有 ftb(on:)（:27），reducer 只收开 / 关（MixerReducer.swift:115-124），App 里没有一处写 ftb.durationTicks。后半不成立：文档原句是"FTB 有自己的时长（默认与转场相同）"，已经说了是独立值；两个默认值也确实相同，TransitionState 和 FadeToBlack 都默认 30 拍（MixerState.swift:70、95） | 不要列为"文档与实现不一致"。可以改成"文档没写界面改不了，只能改节目文件或用 loadShow" |
| R8-S23 | 耳机总线只在输出设备 ≥ 4 声道时才映射到第 3 / 4 声道 | ✅ | AudioOutputDevice.swift:22-26 的 BusChannelMap.standard 写的是 `headphones: outputChannels >= 4 ? (2, 3) : nil`；AudioRuntime.swift:24-31 不设 outputChannelMap（只有 SW_AUDIO_SILENT 时置空） | 照写 |
| R8-S25 | 录制下限 / 备用目录只有启动参数，docs/user/输出.md:46 却写偏好设置可改 | ⚠️ | 文档与界面不符属实：偏好设置窗九节里没有这一项（PreferencesPanel.swift:173-229）。"只有启动参数"不准：AppSettings 也读 UserDefaults 的 recordFallbackDirectory / recordMinimumFreeMB 两个键（AppSettings.swift:10、51-52、115-116），用 `defaults write` 就能改 | 改成"只有启动参数和 UserDefaults 键，偏好设置窗里没有" |
| R8-S40 | App 不起 TallyServer，只有 headless 有 --tally-port，文档却按 App 有写 | ⚠️ | 代码部分属实：ControlRuntime.swift:59-69 不建 tally，App 的依赖表里连 SwitcherTally 都没有（project.yml:82-112）；headless 在 HeadlessRun.swift:427-431 起。文档部分只对一半：docs/user/快捷键.md:78 在用户手册里介绍 tally 流，确实是按 App 有写的；docs/integrations/tally.md:17 只写了 TallyServer 模块的默认地址 0.0.0.0:8766 和接线代码，没说 App 会起（也没说只有 headless 有），属于漏写，不是写错 | tally.md 那一条改成"没写明谁起它（App 不起，headless 用 --tally-port）" |
| R8-S50 | mixerPanelVisible / multiviewWindowVisible 写了不读 | ✅ | 写入在 AppController.swift:284、286，全仓没有读取。只有多画面窗口位置会恢复（MainWindowController.swift:192 → MultiviewWindowController.swift:111） | 补一句：mainWindowFrame（AppController.swift:282）也是写了不读。主窗口位置走 setFrameAutosaveName（MainWindowController.swift:76），按机器记，不跟节目走 |
| R8-S35 | 快捷键编辑器只能建 11 种动作；选"其他"新建会变成 Cut | ✅ | ActionKind 是 11 种加 other（HotkeyEditorPanel.swift:12）；Picker 列出全部，包括"其他"（:196-198）；kind == .other 而 other 为 nil 时 action = `.command(other ?? .cut)`（:77）；新行默认就是 Cut（:106） | 照写 |

## 2. P0 / P1 条目

已在 §1 核过的不重复列：R3a-M08 / M09 / M19 / M20 / M28，R3b-M07 / M14，R7-M02 / M04 / M12 / M15。

| 报告编号 | 结论（我们现状，一句话） | 判定 | 依据（文件:行号 + 一句话） | 对正式文档的修改建议 |
|---|---|---|---|---|
| R2-M01（P1） | 底栏"添加输入…"是普通按钮，只有一个动作 | ✅ | BottomBarView.swift:40 用 Theme.button 建普通按钮，:51 只挂一个 action，:193 的处理函数只开面板；界面稿 L343-347 画的是分体按钮 | 照写 |
| R2-M02（P1） | 输入条没有"添加输入"占位卡；空节目时输入条一片空白；不能拖文件加输入 | ✅ | InputStripView.swift:84-116 只按 state.inputs 建格子；ShowDocuments.swift:34-41 的空节目没有输入；全仓没有 registerForDraggedTypes / onDrop | 照写 |
| R2-M05（P1） | 默认选中"合成测试源"且排第一；每次打开都是新表单 | ✅ | AddInputSheet.swift:18 把 synthetic 排第一，:55 默认 .synthetic；MainWindowController.swift:260 每次新建 controller；测试在 ShortcutAndShowTests.swift:358 钉住默认值 | 照写 |
| R2-M10（P1） | 前置条件不满足时只有页内灰色小字，照样能点"添加" | ✅ | 摄像头权限 AddInputSheet.swift:396-400、551；屏幕权限只有固定一句 :602；没有 DeckLink 卡 :571；NDI 不可用 :437；"添加"按钮没有禁用条件（:720）；docs/KNOWN_ISSUES.md:45 | 照写 |
| R3a-M01（P1） | 主窗口没有工具条，对应功能都在菜单栏 | ✅ | MainWindowController.swift:68-76 只有标题栏，全 App 没有 NSToolbar；节目菜单在 AppDelegate.swift:78-88 | 照写 |
| R3a-M02（P0） | 转场按钮固定为 Fade / Wipe / Zoom / Stinger 加 Cut、FTB，按钮就是类型，改不了 | ✅ | TransitionPanelView.swift:15-20、38-43、95-96 | 照写 |
| R3a-M03（P0） | 转场按钮没有 ▾ 也没有右键；想换类型只能点另一个按钮，一点就执行；参数藏在"参数…"弹出层里 | ✅ | 按钮只挂 action；参数弹出层在 :180-192；"T-bar：… 参数…"那一行在 :90-94 | 照写 |
| R3a-M04（P0） | 只有一个共用时长和三档分段，改了等于改所有类型 | ✅ | :33 预设为 [0.5, 1, 2]；:164-168 发 setTransition(当前类型, 秒 × 标称帧率)；契约里只有一个 durationTicks（MixerState.swift:58） | 照写 |
| R3a-M05（P1） | 转场类型只有 fade / wipe / zoom / stinger；Wipe 方向藏在"参数…"里 | ✅ | TransitionType 见 MixerState.swift:6-8（另有 cut）；方向在 TransitionParams.swift:20、71-78 | 照写 |
| R3a-M06（P1） | T-bar 推"当前选中的类型"，按钮上不标，只在 T-bar 上方写一行字 | ✅ | TransitionPanelView.swift:139；docs/user/概念.md:61 | 照写 |
| R3a-M07（P1） | 一个键只能绑一条命令；编辑器里转场类动作只有 Cut / 按已选转场 / Fade(拍)；兼容层 Transition2–4 未实现 | ✅ | ControlAction.swift:7-15；HotkeyEditorPanel.swift:12；兼容层把 Transition2–4 等列在 knownUnimplemented（FunctionCatalog.swift:96-98） | 照写 |
| R3a-M11（P1） | 转场列 Overlay 1–4 只开关、不换输入；通道没指定输入时开了也看不到画面 | ✅ | TransitionPanelView.swift:194-198 发 `input: nil`；:136 是悬停提示；reducer（:133-143）照样把 on 翻成 true，但没有输入画不出来 | 照写 |
| R3a-M12（P1） | PVW 标题条没有图标和齿轮；监视器不响应鼠标 | ✅ | MonitorView.swift:10-13、28-44 只有三个 label；MonitorView 和 MetalDisplayView 都没有 mouse / menu 处理；输入设置入口在 AppDelegate.swift:197-203 | 照写 |
| R3a-M15（P1） | 外部输出菜单"勾 = 已经开着"；点一下 = 开或关这一对（屏, 源）；同一块屏可以叠多个窗口 | ⚠️ | "勾 = 已经开着"不准：勾看的是这对（屏, 源）的外部显示输出存不存在（ExternalOutputMenu.swift:65 调 existingOutput），不看 enabled。在输出设置 › 外部显示里把"开"关掉（OutputSettingsPanel.swift:565）以后，菜单里仍然打勾，再点一次会删掉整条配置（:106-107）。其余属实：:55-73、104-111；一个输出一个窗口（ExternalDisplayManager.swift:6、66-86） | "勾"改成"已有这对（屏, 源）的输出（不管开没开）" |
| R3a-M23（P1） | "切换"菜单只有 Cut / Fade / FTB，不显示快捷键，没有 Wipe / Zoom / Stinger 和"执行当前转场" | ✅ | AppDelegate.swift:105-112，三项的 keyEquivalent 都是 "" | 照写 |
| R3b-M01（P0） | 底栏的外部输出菜单和叠加 popover 都往按钮下方（窗口外）开 | ✅ | MainWindowController.swift:297 在 (0, bounds.height) 处 popUp；:281 用 preferredEdge .maxY；探针确认 NSButton.isFlipped == true，所以 bounds.height 就是按钮底边。屏幕放不下时 AppKit 怎么挪没实测（报告已标推测） | 照写 |
| R3b-M02（P1） | "外部输出"主体直接弹"显示器 × 来源"菜单，选中 = 加一路，再选 = 删，没有开关 | ✅ | BottomBarView.swift:227；ExternalOutputMenu.swift:104-120 | 照写 |
| R3b-M03（P1） | 录制只有主体起停；录制设置只能从菜单栏进 | ⚠️ | 主体起停属实（BottomBarView.swift:195-213）。"只能从菜单栏"不准：底栏"ISO…"打开的是同一个输出设置窗（MainWindowController.swift:149），左栏可以切到"录制"页（OutputSettingsPanel.swift:360）。准确说法是底栏没有直达入口 | 改成"底栏没有直达入口（只能 ISO… → 左栏切页，或走菜单）" |
| R3b-M04（P1） | 推流只有主体全起 / 全停；没有目的地时按钮变灰，只能去菜单栏添加 | ⚠️ | 全起全停和没有目的地时变灰都属实（BottomBarView.swift:161-166、216-224）。"只能去菜单栏添加"同 R3b-M03：从 ISO… 进去再切到"推流"页也行 | 同上 |
| R3b-M12（P1） | 调音台开关只有 窗口 › 调音台 和拖分隔条 | ✅ | AppDelegate.swift:148、220；MainWindowController.swift:313-328 | 照写 |
| R3b-M16（P1） | 某一路的输入设置只有格子右键"设置…"和 输入 › 输入设置… 两个入口 | ⚠️ | 漏了调音台条子上的"设置…"（MixerPanelView.swift:321，每一路都能开）。报告 B2 自己列了这一项，C 表这一格没写 | 补上这第三个入口 |
| R3b-M21（P1） | 没有统计窗，只有底栏一行状态行 | ✅ | BottomBarView.swift:101-112；StatusLineFormatter.swift:35-56；调音台底部另有 A1 计数（MixerPanelView.swift:79、251） | 照写 |
| R7-M01（P0） | "推流"按钮上没有设置入口，只能走菜单栏；没有目的地时按钮变灰 | ⚠️ | 按钮上没有设置入口、变灰都属实（BottomBarView.swift:161-165），提示文案也只指向菜单（Localizable.strings:165）。"只能走菜单栏"不准，理由同 R3b-M03 | 改成"底栏没有直达入口" |
| R7-M03（P1） | 推流页没有起停，也没有状态行 | ✅ | OutputSettingsPanel.swift:524-557 里都没有；外部显示页（:573）和 NDI 页（:689）有状态行；OutputStatusText.swift:13-69 里也没有推流的文案函数 | 照写 |
| R7-M06（P1） | 只有地址文本框，协议看 scheme | ✅ | OutputSettingsPanel.swift:546；StreamDestination.swift:37 | 照写 |
| R7-M07（P1） | 编码参数平铺在每个目的地的一节里 | ✅ | OutputSettingsPanel.swift:530-541 | 照写 |
| R7-M08（P1） | 关键帧按帧计，默认 120 帧 | ✅ | MixerState.swift:396、401；OutputSettingsPanel.swift:538-540；Localizable.strings:517 | 照写 |
| R7-M11（P1） | 没有推流状态窗，各路状态只有 API 看得全 | ✅ | docs/api.md:29 列了 stats.encoder[]；App 里没有状态窗 | 照写 |
| R7-M13（P1） | 底栏"ISO…"在录制和推流之间，点了打开 ISO 页，起停跟着录制走 | ✅ | BottomBarView.swift:46、66；MainWindowController.swift:149 | 照写 |
| R7-M14（P1） | ISO 页每路一个开关，页底一段估算，所有输入都列出来 | ✅ | OutputSettingsPanel.swift:506-520 用 ForEach(model.state.inputs)，纯音频和图片输入也在里面 | 照写 |
| R8-U01（P1） | 没有录制 / 推流时长，底栏只写"● 录制中" | ✅ | BottomBarView.swift:126-129；全 App 没有时长 | 照写 |
| R8-U14（P1） | 转场按钮没有下拉，参数集中在一个"参数…"弹出层 | ✅ | TransitionPanelView.swift:38-47、180-192 | 照写 |
| R8-U15（P1） | 转场列 Overlay 按钮只翻 on、不换输入；通道没指定输入时按了无效，只给提示 | ⚠️ | "只翻 on、不换输入"属实（:194-198）。"按了无效、只给提示"不准：命令被收下，on 变成 true，按钮变蓝（reducer :133-143；TransitionPanelView.swift:135），只是没有输入画不出来。那句"提示"是悬停 tooltip（:136），不是按下后的反馈 | 改成"按下后通道记为开、按钮变蓝，但没有画面"。R8-S14 里同一句也照此改 |
| R8-U24（P1） | 循环只能在输入设置 › 来源里改再"应用"，这一路会重建；引擎能在运行中改，契约没有命令 | ✅ | InputSettingsPanel.swift:276-293；FileInput.swift:171-175；Command.swift 的 34 个 case 里没有播放类命令 | 照写 |
| R8-U29（P1） | 总线条子上没有"送耳机监听"，也没有信息按钮 | ✅ | MixerPanelView.swift:335-360：总线条子只有名字、表、推子、增益、LUFS、静音、效果 | 照写 |
| R8-U33（P1） | "推流"一键全开 / 全关，没有 ▾ 也没有齿轮 | ✅ | BottomBarView.swift:42、216-224 | 照写 |

## 3. 抽查

优先抽了"我们多出的"和"已有"两类，共 30 条。

| 报告编号 | 结论（一句话） | 判定 | 依据（文件:行号 + 一句话） | 对正式文档的修改建议 |
|---|---|---|---|---|
| R2-M04（多出的） | ⌘I 同时挂在菜单和底栏按钮上，但不会弹两个面板 | ✅ | presentAddInput 有 `addInputSheet == nil` 守卫（MainWindowController.swift:259） | 照写 |
| R2-M16（默认值不同） | 文件里的透明通道自动识别，不用勾选 | ✅ | FileDecoder.swift:82-84；FileInput.swift:27 | 照写 |
| R2-M19（多出的） | 添加时就能填名字，空着用默认名 | ✅ | AddInputSheet.swift:156-168、715 | 照写 |
| R2-M22（多出的） | 输入设置 › 来源可以换类型和设备，编号、名字、设置、各处引用都保留 | ✅ | InputSettingsPanel.swift:276-293；MixerReducer.swift:221-224 | 写"多出的"时要带上一句：换来源会重建这一路（R3b-M15） |
| R2-M23（多出的） | 屏幕输入多了"某个应用"、帧率、系统音频 | ✅ | AddInputSheet.swift:575-604 | 照写 |
| R2-M24（多出的） | 音频设备第一项是"系统默认输入"，超过 2 声道可以选取哪几路 | ✅ | AddInputSheet.swift:359-367、665-680 | 照写 |
| R2-M25（多出的） | 添加时就能选播完动作和播放速率 | ✅ | AddInputSheet.swift:616-628 | 照写 |
| R2-G05（有） | NDI（搜一次、最多等 1.5 s，加手填）和屏幕 / 窗口 / 应用采集都有 | ✅ | AddInputSheet.swift:422-441、640-663、575-604 | 照写 |
| R3a-G06（有） | Wipe 有五个方向 | ✅ | MixerState.swift:16-18；TransitionParams.swift:20 | 照写 |
| R3a-G10（有） | 有最近文件列表和"清除列表"，最多 10 条 | ✅ | AppDelegate.swift:81-83、170-185；ShowDocuments.swift:12、84-92 | 照写 |
| R3a-B4（已有行为） | T-bar 松手到 0.97 就提交，150 ms 回弹；拖动中最多发 0.999 | ✅ | TBarView.swift:18、108-147、120-126 | 照写 |
| R3a-B5（已有） | 时钟上行 24 小时制、下行 12 小时制，黑底白边 | ✅ | ClockView.swift:6-18、24-26 | 照写 |
| R3a-M13（P2） | PGM 那一路的设置只能从缩略图右键"设置…"进 | ⚠️ | 调音台条子上的"设置…"（MixerPanelView.swift:321）也能打开任一路，包括 PGM 那一路 | 去掉"只能" |
| R3b-M10（多出的） | 叠加面板里有"输入"下拉、"显示"开关、锚点、PVW 预览 | ✅ | OverlayPanel.swift:124-128、152-156 | 照写 |
| R3b-M13（触发方式不同） | 搜索框常驻，宽 220 pt，编号全等或名字包含就算匹配；回车 / Esc 把焦点还给窗口 | ✅ | InputStripView.swift:30-38、62、171-178；InputCellView.swift:176-181 | 照写 |
| R3b-M17 | 格子上的"静音"一直能点，静音时红底 | ✅ | InputCellView.swift:40-41、129、240-242 | 照写 |
| R3b-M19（多出的） | 格子右键有设置… / 重命名… / 删除，删除不确认 | ✅ | InputCellView.swift:184-190、213 | 照写 |
| R3b-M27（多出的） | 底栏"多画面"按钮开关多画面窗口 | ✅ | BottomBarView.swift:44、228；MainWindowController.swift:301-308 | 照写 |
| R3b-M09 | 叠加动画默认切入、0 拍；面板里按拍调，步长 5 | ✅ | MixerState.swift:147；OverlayPanel.swift:143-145 | 照写 |
| R3b-G20（部分） | 每路条子上能选送哪几条总线 | ✅ | Input.swift:243-251；调音台每路条子的 M / A / B / H 开关（MixerPanelView.swift:312-313） | 照写 |
| R3b-G24（有） | 帮助菜单里有导出诊断包、打开诊断文件夹 | ✅ | AppDelegate.swift:154-158 | 照写 |
| R7-M18（多出的） | 每路有"重连上限 1–300 s" | ✅ | OutputSettingsPanel.swift:530-532 | 可以照写，但要说明这是两次重试之间最长等多久，不是放弃上限（见 §4 第 2 条） |
| R7-B5（已有） | ISO 的音轨取该路推子后、AFV 前 | ✅ | OutputRuntime.swift:353-357、363 | 照写 |
| R7-G20（部分） | 有 .mp4 容器、片段 .mov（可恢复）、停止后转 MP4 | ✅ | MixerState.swift:423-447；OutputSettingsPanel.swift:432-434、452-455 | 照写 |
| R8-S09（部分） | PVW / PGM 监视器和多画面格子上没有"无信号"提示 | ✅ | MonitorView.swift:53-67 只看快照；SwitcherRender 里没有画"无信号"的代码；只有输入格子会写（InputCellView.swift:159-171） | 照写 |
| R8-S10（已做） | Shift + 点缩略图 = 直切 PGM；默认键是数字、Shift + 数字、空格、回车、F | ✅ | InputCellView.swift:215-223；HotkeyTable.swift:58-68 | 照写 |
| R8-S17（已做） | 每路延迟补偿 0–500 ms | ✅ | InputSettingsPanel.swift:250-253；AudioEngine.swift:468 | 照写 |
| R8-S22（部分） | 界面只显示各总线的短期 LUFS；docs/user/概念.md:82 按界面有写 | ⚠️ | 代码部分属实：MixerPanelView.swift:47、351 只用 shortTermLUFS，Stats.swift:249-267 里有全套数值。文档部分偏重：:82 原句"表：峰值 / RMS / 真峰值 / 响度（EBU R128：瞬时 / 短时 / 积分 / LRA）"讲的是表会算什么，没说界面上看得到，属于没写清，不算写错 | 改成"文档没说明积分响度 / LRA / 真峰值只在 API 和 stats.jsonl 里" |
| R8-S39（已做） | 兼容层默认关、只听本机、只有 TCP 端口可设 | ✅ | AppSettings.swift:65、91-98；VMixCompatConfiguration.swift:14 默认 host 为 127.0.0.1；PreferencesPanel.swift:217-222 | 照写 |
| R8-S43（已做） | PVW 预览叠加有总开关和每通道开关，总开关要换 session 才生效 | ✅ | PreferencesPanel.swift:209-212；OverlayPanel.swift:155；AppSettings.swift:82-86 | 照写 |

## 4. 发现的新问题（核对时顺带看到、报告里没写的）

1. **推流起不来时底栏显示"推流 · idle"，而且改对了也不重试。** 没有地址、scheme 不认、StreamOutput 建不起来时，这一路记进 failed，Stats 里报 idle（OutputRuntime.swift:512-532、742），按钮显示英文原样的"推流 · idle"。failed 只在 enabled 变 false 时才清（:222-225），所以在推流页把地址改对也不会自动重试，必须先停再起。
2. **"重连上限"不是放弃上限。** App 里推流重连不限次数：App 不传 reconnect，默认策略 maxAttempts = nil（StreamOutput.swift:97-98；ReconnectPolicy.swift）。推流页的"重连上限 %.0f s"（Localizable.strings:562）其实是两次重试之间最长等多久，容易被理解成"超过就放弃"。docs/user/输出.md:60 写的"上限默认 30 s"同样含糊。
3. **"重连中（第 n 次）"的 n 不是尝试次数。** 按钮上的 n = reconnects + 1（BottomBarView.swift:152），而 reconnects 只在重连**成功**后才加一（StreamOutput.swift:388-389）。所以一直连不上的目的地永远显示"第 1 次"；成功重连过 k 次的路，之后每次断线都一直显示"第 k+1 次"。另外 docs/user/输出.md:63 说是"状态行显示"这句话，实际显示在底栏推流按钮上，状态行（StatusLineFormatter.swift）里没有推流状态。
4. **录制按钮也原样显示英文状态。** 格式是"录制 · %@"，填的是 idle / stopping / failed（BottomBarView.swift:130-132；Localizable.strings:169-171；Recorder.swift:106-109）。和 R7-M04 是同一类问题，本地化时应一起改。
5. **新建 / 打开会丢改动，退出却会静默覆盖原文件。** 新建 / 打开前不保存也不 autosave（AppController.swift:203-215），当前节目没保存的改动直接丢，也不进 LastSession。退出时却会把当前状态静默写回已打开的节目文件（AppController.swift:112-115）。两条路径语义不一致；docs/user/概念.md:90 只写了"未保存的节目自动存到 LastSession"，没写退出会覆盖原文件。
6. **mainWindowFrame 写了不读。** 它也写进了 Show.layout（AppController.swift:282），但从来不读；主窗口位置走的是 setFrameAutosaveName（MainWindowController.swift:76）。R8-S50 只列了另外两个键。
7. **外部输出菜单的勾不看开关。** 勾只看这条输出存不存在（ExternalOutputMenu.swift:65），不看 enabled。在输出设置里关掉某一路外部显示（OutputSettingsPanel.swift:565）后菜单仍然打勾；在菜单里再点一次，删掉的是整条配置（:106-107），不是把它打开。
8. **转场进行中 setProgram 也不拦。** reducer 在 MixerReducer.swift:103-105 没有检查转场状态，渲染器每帧按 state.program 画底（CompositorPasses.swift:246-248），所以转场中 Shift + 点缩略图会换掉正在出去的旧画面。R3b-M14 只提了 setPreview。
9. **API / 快捷键能加超出引擎容量的输入，加了也不跑。** 校验器和 reducer 都只查编号 ≥ 1 且不重复（CommandValidator.swift:43-46；MixerReducer.swift:207-212），所以能加出比如 17 号（容量 16）。格子会出现，但运行表只打一行日志、不接这一路（InputRuntime.swift:55-58），格子上没有任何提示。添加面板只列容量内的号，所以只有 API / 快捷键 / 节目文件这几条路会碰到。
10. **窗口标题问题的来历。** W4-D 改名时主窗口的三处标题都改了（reports/w4-rename.md:21），漏了 AppController.swift:264，这就是 R3a-M20 的来源。写修复单时可以注明这是漏改的回归。
11. **（小）MIDI 映射面板显示不出"其他"动作。** 一行 Note 动作如果是"其他"命令（从文件读来的），动作 Picker 的选项里已经把"其他"滤掉了（MIDIMappingPanel.swift:264-270），当前值不在列表里，显示为空。

## 5. 统计

| 节 | 条数 | ✅ 属实 | ⚠️ 部分属实 | ❌ 不属实 | ❓ 无法确认 |
|---|---|---|---|---|---|
| 1 缺陷类 | 24 | 20 | 4（R7-M04、R8-S13、R8-S25、R8-S40） | 0 | 0（R3a-M28 的推测部分单记 ❓） |
| 2 P0 / P1 | 36 | 30 | 6（R3a-M15、R3b-M03、R3b-M04、R3b-M16、R7-M01、R8-U15） | 0 | 0 |
| 3 抽查 | 30 | 28 | 2（R3a-M13、R8-S22） | 0 | 0 |
| 合计 | 90 | 78 | 12 | 0 | 0（另有 1 处推测 ❓） |

✅ 行里只需改行号或措辞的：R8-S18（界面证据换成 InputSettingsPanel.swift:208）、R7-M12（"每按一个键"只对地址 / 密钥成立）、R7-M15（测试行号是 118-119）、R3a-M20 / R8-U02（普通保存也会触发）、R3b-M15（"循环只能在添加时选"与后半句矛盾）、R8-S50（mainWindowFrame 也没读）。R8-S14 的"按了无效"与 R8-U15 同句，一起改。
