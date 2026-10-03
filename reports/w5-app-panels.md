# W5-K 面板改版报告（prompt 97，分支 w5-app-panels）

分支：桌面端开的 worktree 分支 `claude/w5-app-panels-594087`；prompt 里叫 `w5-app-panels`，本地另打同名引用（`git branch -f w5-app-panels HEAD`）给
`check-ownership.sh` 用。**基线不是 main，是 93 的分支头 `w5-app-toolbar` = `8a13a21`（92 + 93）**：prompt 写"从 88 与 G6 合入后的 main 开"，
但开工时 92 / 93 都做完了、还没合进 main，而 92 已经动了 97 要改的两处（添加输入的本机记忆 `AddInputHistory`、叠加从 NSPopover 换成 `BottomBarPanel`）；
落地方案 §8.4 的并行依赖序是 92 → 93 / 94 → 95 / 96 / 97 / 98，同批的 94、96 也是叠在 `8a13a21` 上开的。所以 **G7 要先合 92、93 再合本分支**（见 §5 第 1 条）。
机器：MacBook Pro M5 Max（128 GB），macOS 27.0（26A428），Xcode 27.0，接电源；内建屏 + LG ULTRAGEAR。只动 App/ + 本报告 + 两张问题单。

提交（`git log 8a13a21..w5-app-panels`）：`67c6d0d` 红灯轮（八条用例全红：0 过 / 8 败）→ `9cf2f03` 添加输入 → `5724e1e` 输入设置 → `be42914` 叠加设置窗 →
`21d2269` 音频设置窗与调音台 → `3513df6` 音频设备页与总线出口 → `8b2f72b` 目视检查跟改 → `c703481` 面板只在显示的字段变了才重画 → 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 添加输入（G2–G12、V-16、Q57、Q58） | `UI/AddInputSheet.swift`（重写表单模型与各页）、`UI/AddInputSupport.swift`（新）、`UI/AddInputHistory.swift`、`UI/HelpBook.swift`、`UI/InputCellView.swift`、`UI/MainWindowController.swift` | **G2**：第一次停在"摄像头 / 采集卡"（`AddInputHistory.defaultKind`）；记住上次的类型和**每一类上次加的来源**（摄像头 uid / 文件路径 / NDI 源名与带宽 / 音频设备与声道 / 屏幕目标……），面板打开时按它预填各类、切到哪一页都带着；记住的摄像头 / 显示器不在了退到第一个。存 UserDefaults，键用契约的 `InputKind` 名（左栏改顺序不串）。**G3**：左栏分组 设备（摄像头 / 采集卡、DeckLink、音频设备）/ 网络（NDI®）/ 屏幕 / 媒体（视频文件、图片）/ 测试（合成测试源，Q58 挪到最后），每项一个 SF Symbol；底栏 ▴ 与"输入 › 按类型添加 ▸"同序（`Kind.displayOrder`）。**G4**：sheet 可缩放（最小 700×460，挂成 sheet 后 AppKit 把 contentMinSize 清 0，由 `windowWillResize` 兜），关掉时记下尺寸、下次照它开。**G6**：摄像头 / 麦克风 / 屏幕录制权限被拒（denied / restricted）→ 页顶红色横幅 + "打开系统设置…"（直达 `x-apple.systempreferences:…?Privacy_Camera / Privacy_Microphone / Privacy_ScreenCapture`）；NDI® 运行库不在、DeckLink SDK 没编进来 / 驱动没装 → 横幅 + "看说明"（手册还没随包时弹一句说明）；有横幅时"添加"旁边写"加上后先显示错误，授权后（装好后）自动恢复"，照样能加；还没问过（notDetermined）不挂横幅（第一次加系统会问）；回到前台时横幅按新状态重画。系统状态与两个动作走可注入的 `AddInputEnvironment`。**G7**：每页第一行是给操作员看的说明（能接什么、要什么前提）。**G8**：摄像头页用引擎同一个 `CameraFormatNegotiation.choose` 写"将以 1920×1080 · 60 fps 采集（与节目帧率一致）"，对不上标黄并写明"比节目慢，会重复帧 / 比节目快，会丢帧"、分辨率不同写"（缩放到 …）"——本机 MacBook Pro 相机最高 30 fps，目视截图里就是黄的。**G9**：NDI® 页开着每 4 s 重找（找的时候转圈），源用列表、双击直接加（输入设置的"来源"一节双击只选上）。**G10**：屏幕页缩略图网格：显示器随时列，窗口 / 应用列表与截图要屏幕录制权限（ScreenCaptureKit `SCScreenshotManager` 各取一帧 320×180；应用格子画应用图标；没权限画图标）。**G11**：视频 / 图片页"最近用过"各 10 个（新的在前；不在了灰着、写"（不在了）"、不能双击加），单击填入、双击直接加、"清空"。**G12**：选好文件就读信息：视频"H.264 · 1920×1080 · 60 fps · 0:10（· 含透明通道 / · 没有声音）"，图片"PNG · 64×32 · 含透明通道"。**V-16**：音频设备下拉不再写四字码（"MacBook Pro 麦克风（1 声道 · 内建）"，不认识的连接方式不写），说明两行。**Q57**：视频文件页的打开面板收 mp3 / wav / m4a / aac，信息写"纯音频 · AAC · 48 kHz · 2 声道 · 3:20"，加出来的格子按纯音频画（话筒 + 表）；**FileInput 还要求视频轨**（`FileAsset` 抛 `noVideoTrack`），页上写明这一版加上会报错 → 问题单 `W5K-w2-inputs-file-audio-only` |
| 2 输入设置（H1、H3–H9、X55，G6 追加 ①） | `Settings/InputSettingsPanel.swift`（重写视图与模型的一半）、`Settings/InputPreview.swift`（新）、`UI/PanelCoordinator.swift` | **H1**：基本 → 抠像 → 裁切与位置 → 音频 → 音频效果（"效果尚未作用到声音"的横幅照留）→ 来源。**H3**：右栏下方嵌本路画面——`MetalDisplayView` 切多画面纹理这一格（与输入条缩略图同一个 `InputStripView.thumbnailRect`，Q55 不动渲染器，画质是缩略图级），布局 / 路数变了跟着挪；纯音频输入写"没有画面"、不在多画面布局里写原句；标题行"输入 2 · 合成 2 [在 PVW]"（tally 色块）。**H6**：抠像"在画面上取色"→ 十字光标 → 点一下换算到纹理像素（按比例放的黑边不取）→ `PixelSampler.average3x3`（私有纹理先 blit 3×3 到共享纹理再读）→ 一次 setInputSettings 写键色、退出取色。**H5**：滑杆旁可输入的数值框（裁切按 %）、每项复位（↺）、裁切 / 位置 / 音频整组复位、抠像"恢复默认"（开没开不动）、"复制位置 / 粘贴位置"（裁切 + 变换，App 内剪贴板）。**H4**：侧栏底部"从其他输入复制…"：选一路、勾 裁切与位置 / 抠像 / 音频 / 音频效果，一次 setInputSettings。**H7**：名字失焦 / 回车 / 关窗即改名，"应用名字"按钮与键删了；正在编辑时快照不盖掉没提交的字。**H8**："音频延迟补偿（ms）"，说明写明只推迟声音。**H9**：W5-A 已做（存档名带编号 + 错开），没动。**X55**：音频一节"跟随视频（AFV）"开关绑 `InputAudioSettings.afv`（契约默认开），与调音台条子同一份数 |
| 3 叠加设置独立窗（I1–I3 / X21 / Q40） | `Settings/OverlaySettingsPanel.swift`（新，替掉 `UI/OverlayPanel.swift`）、`UI/PanelCoordinator.swift`、`UI/MainWindowController.swift`、`UI/BottomBarPopup.swift`、`UI/TransitionPanelView.swift`、`UI/InputCellView.swift`、`UI/InputStripView.swift`、`UI/SwitchMenu.swift`、`AppDelegate.swift`、`Show/ShowDocuments.swift`、`UI/BottomBarView.swift`（注释） | **I1**：走 PanelCoordinator 的普通窗口（不是 sheet、不是主窗口的子窗口、不挡主窗口），只开一个；顶部 Overlay 1–4 分段只显示当前通道，改一项立即发；入口：底栏"叠加…"（停在上次那一路，换节目回到 1）、转场列 Overlay k 与格子 k 小按钮的右键"叠加设置…"（直达第 k 路）、菜单栏"切换 › Overlay ▸ › 叠加设置…"（规则 5）。92 的 `BottomBarPanel` 与旧 `OverlayPanelController / OverlayPanelView` 只给叠加用，删了。**I2**："整幅 / 画中画"二选一：整幅 = 位置 .full，位置 / 锚点 / 边框几行收起（设置留着）；画中画位置下拉不再混着"整幅"，从整幅切过来放右下 1/4。**I3**：新节目四通道默认淡入 0.5 s（`ShowDocuments.emptyShow` 按节目帧率换拍：60p = 30 拍；不动契约默认值）；面板里时长按秒（悬停写"= n 拍"），0.5 / 1 / 2 s 快捷值。只发 overlay / setOverlay / setOverlayDecoration（同原来） |
| 4 音频设置窗（J2–J7 / X12 / X31 / V-04，G6 追加 ② ③） | `Settings/AudioSettingsPanel.swift`（新）、`UI/MixerPanelView.swift`（视图重写）、`UI/PanelCoordinator.swift`、`UI/MainWindowController.swift` | **J2 / J3**：每条总线条顶部、每路输入条上的齿轮开"音频设置 — Master / 输入 n"（同一条一个，再点 = 置前切页；输入删了窗跟着关）；挂在主窗口上的效果 sheet 删了；总线条"效果 (n)"直达均衡页；输入条"设置…"换成齿轮，右键"输入设置…"仍开整窗。**J4**：左侧分页 常规 / 均衡 / 压缩 / 限幅（只总线）；每页顶部"启用"（"用 X"与"启用"合一：关 = 旁路、参数留着）+ 参数 + 复位（参数回默认、开关不动）；窗左常驻这一条推子后的表（调音台同一份 50 ms 的 `MixerMeters`）。范围沿用 `EffectEditorRanges`、EQ 上限 3 段（新段默认 100 Hz / 1 kHz / 8 kHz）。压缩页按提案 024 (c) 的写实文案过渡："阈值 + 压缩量 + 输出增益"，压缩量就是 AUDynamicsProcessor 的 headroom（"输出最多到 阈值 + 压缩量，这个压缩器没有固定比例"），起音 / 释放 / 扩展比放"高级"；024 (b) 的 `compressor` 落地（P5 契约 + 102 实现）后换简单模式。输入的均衡 / 压缩页挂"效果尚未作用到声音"。**J5**：常规页只读"48 kHz · 立体声"、推子读数、静音（前级增益 / 自动增益不加，有意保留）。**J6 / X31 / V-04**：Master 条常驻最右，Bus A / B / 耳机一组固定在它左边，输入组在最左横向滚动；两组都能收成竖条（默认输入展开、总线收起）；总线条窄成 64 pt，Master + 三条总线 + 竖条放得下 340 pt；表头不折行（标题 / AFV fixedSize、监听分段 labelsHidden）。**J7**：Master 条的"监听"菜单（耳机总线（现在）✓；Master / Bus A / Bus B 灰着、写"要音频引擎支持（下一版）"，入口 `MixerModel.listen(_:)`）→ 问题单 `W5K-w1-audio-monitor-selected-bus`；"i"= 响度详情弹出层（瞬时 / 短期 / 积分 / LRA / 真峰值，读 Stats 1 Hz，静音写 —）。**X12**：音频设置 / 叠加设置 / 输入设置窗在前时，没被文本框吃掉的按键照样走快捷键表（`PanelWindow.keyHandler` → `ControlRuntime.handleKey`） |
| 5 音频设备页与总线出口（J8 / X08 / X09 / V07） | `Settings/AudioOutputSettings.swift`（新）、`Settings/PreferencesPanel.swift`、`AppSettings.swift`、`Engine/AudioRuntime.swift`、`Engine/SwitcherSession.swift`、`UI/MainWindowController.swift`、`UI/MixerPanelView.swift` | 设置 › 音频设备：选设备 + Master / Bus A / Bus B / 耳机各选一对声道或"不输出"；两条总线不共用一对（设备回调散射时后写的盖先写的），选了别人正用的那一对、原来那条改"不输出"并写一句；换设备只去掉这台没有的声道对；"恢复设备默认"；没改过存 nil（跟设备默认，与包里 `BusChannelMap.standard` 同口径）。存本机 `AppSettings.busOutputMap`（UserDefaults JSON）→ `AudioRuntime` 建引擎时换成 `BusChannelMap` 进 `AudioEngineConfiguration.outputChannelMap`（包里已支持同一设备上的映射，不改包），换 session 生效（"应用并重起引擎"，录制 / 推流在跑先问）。2 声道设备：页上与调音台头部写"当前设备没有耳机声道"，给"监听时临时占用 Master 声道"（`AppSettings.borrowMasterForMonitor`，存本机）——**引擎还不会在独听时临时换声道**，页上写明尚未生效 + 问题单。偏好设置原来的"音频输出"一节整节换成这个视图并改名"音频设备"；96 合窗时整节搬进"本机 › 音频设备" |
| 6 全量 / lint | — | 见 §2.3 / §2.4 |

顺带：
- **测试宿主的 UserDefaults suite 按构建位置分开**（`AppController.testDefaultsSuite` = `com.plusmix.switcher.tests.<构建路径的 FNV-1a>`）：原来所有 worktree 共用一个 suite，
  同时跑 App 测试时别的会话的 `freshSession` 清"添加输入的本机记忆"会把这边正在用的键清掉——第一遍跑 `testPanels_addInputRemembersLastTypeAndDevice` 时实测：上次的类型、最近文件读回来是空的
  （那时 94 / 95 两个会话正在跑 App 测试）。
- 面板模型只在自己显示的字段变了才重画（音频设置窗看总线与这一路、叠加设置窗不看 animProgress / startTick、调音台只看输入表与音频状态、输入设置窗 config 没变不重设）：
  转场 / 叠加淡入淡出期间快照每拍都变，W5-F 实测主窗口每帧重设控件会拖慢点击与确认框。
- 目视检查：临时用例把各窗口打开、停 3.5 s，shell 里 `screencapture -l<窗口号>` 截真窗口（添加输入三页、输入设置三节、叠加设置、音频设置两页、偏好设置、调音台两种收法、音频设备页两种设备），
  看出两处跟改（显示器格子副标题重复写分辨率、那一节标题叫"音频输出"）；临时用例没入库。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

（功能用例，判据是行为 / 文案逐字相等与状态；没有数值阈值。）

### 2.1 prompt 列的八条（`App/Tests/PanelsRevampTests.swift`）

| 测试 | 看到的 | 判据 | 通过 |
|---|---|---|---|
| `testPanels_addInputRemembersLastTypeAndDevice` | 左栏顺序 [摄像头, DeckLink, 音频设备, NDI®, 屏幕, 视频文件, 图片, 合成测试源]、分组 [设备, 网络, 屏幕, 媒体, 测试]、测试组只有合成测试源、八个图标本机 SF Symbols 都有；第一次打开 `kind == .camera`；加 pattern.mov → 再开停在视频文件、路径带着、最近文件 = [pattern.mov]；加 NDI「演播室 (PGM)」带宽最低 → 再开停在 NDI、源名与带宽带着、编号 3；切回视频文件页路径还在；取消不加；同一个 UserDefaults 重读：lastKind = ndi、lastSource(.file) / (.ndi) 逐字段相等、recentFiles = [pattern.mov]；`fill(from:)` 填一类不动别类、不换当前页；拒收 0 | 逐项相等 | ✅ |
| `testPanels_addInputPermissionBannerOffersSystemSettings` | 注入：摄像头 / 麦克风 denied、屏幕录制 false、NDI 不在、DeckLink 驱动没装：摄像头页横幅标题含"摄像头"、按钮"打开系统设置…"、点了打开 `…?Privacy_Camera`；音频 → Privacy_Microphone；屏幕 → Privacy_ScreenCapture；NDI / DeckLink → "看说明"（DeckLink 标题含"驱动"）；"添加"旁"加上后先显示错误，授权后自动恢复"、照样能加；合成源 / 文件页没有横幅；都正常时没有；notDetermined 不挂 | 逐项相等 | ✅ |
| `testPanels_inputSettingsShowsLivePreviewFromMultiview` | 两路合成源（灰 40 / 200）：2 号的预览格子 = 输入条缩略图那一格、target 多画面、来源是本 session 的渲染器；读回多画面纹理这一格中间 60% 平均亮度 > 120（2 号）；删 1 号 → 布局重排、预览格子跟着挪到新位置且仍是 2 号的画面；tally "" → "在 PVW" → Cut 后"在 PGM"；窗口在屏上时 3 s 内出帧 > 5 | 纹理非空且随快照变化 | ✅ |
| `testPanels_keyerPickColorFromPreview` | 取色器：8×8 纹理上 (4, 3) 的 3×3 平均 = (90, 60, 40)、角上 (0, 0) 只平均落在纹理里的 4 个 = (90, 10, 5)；端到端：纯色 PNG (30, 200, 60) 图片输入 → 抠像 › 在画面上取色 → 点预览容器正中（真的 mouseDown 换算）→ 取到 ≈ (30, 200, 60)（各 ±12 内）→ 快照里键色 = 取到的、取完退出取色；不在取色状态点预览不改键色 | 3×3 平均、写进 keyer.keyColor | ✅ |
| `testPanels_overlayWindowStaysOpenWhileSwitching` | 底栏"叠加…"→ 叠加设置窗（独立：sheetParent / parent 都是 nil，主窗口没挂 sheet，可关可缩）；点格子 2 的"1"→ 叠加 1 = 输入 2 开着、窗还开着；主窗口变 key、空格 Cut → 窗还开着；只有一个窗；切到通道 3 改输入与"1 秒"→ 60 拍；整幅 ↔ 画中画；转场列 Overlay 2 / 格子 4 的右键"叠加设置…"→ 同一个窗切到 2 / 4；拒收 0 | 开着窗点格子的 1 不关 | ✅ |
| `testPanels_busAudioWindowDoesNotStealHotkeys` | Master 齿轮 → "音频设置 — Master"独立窗（不是 sheet，主窗口没挂东西），再开是同一个窗；它是 key 窗口时按空格 → PGM 1 → 2（Cut）；主窗口按空格 → 回到 1，音频设置窗还开着；输入 1 的齿轮 → "音频设置 — 输入 1"另一扇；分页：总线 [常规, 均衡, 压缩, 限幅]、输入 [常规, 均衡, 压缩] | 开着音频设置窗按空格仍 Cut | ✅ |
| `testAudio_busChannelMapReachesDevice` | 注入两台设备：8 声道 → 声道对 [不输出, 1/2, 3/4, 5/6, 7/8]；Bus A → 3/4（下标 2）、无耳机提示；应用 → `AppSettings.busOutputMap.busA == 2` 且 UserDefaults 读得回来；重起引擎 → `AudioEngineConfiguration.outputChannelMap` 的 busA = (2, 3)、master = (0, 1)、整个 map = 设置换算出来的；2 声道设备 → "当前设备没有耳机声道"、给"监听时临时占用 Master 声道"、声道对 [不输出, 1/2]、Bus A 退回不输出；调音台 `headphonesHint(2, …)` 同一句，`setOutputInfo(2, …)` 后表头出现、空设备不提示 | map 对应、2 声道提示出现 | ✅ |
| `testPanels_inputAFVToggleWritesAudioSettings` | 输入设置 › 音频的"跟随视频（AFV）"绑定：默认开（契约默认）→ 关 → 快照 afv = false、调音台条子同一份 → 开 → true；文案"跟随视频（AFV）"、"音频延迟补偿（ms）" | 写进 InputAudioSettings.afv | ✅ |

红灯轮（`67c6d0d`，新 API 只给签名、行为照旧）：八条全红（0 过 / 8 败，xcresult 计数）。

### 2.2 本会话加的其余用例

| 文件 / 用例 | 看到的 | 通过 |
|---|---|---|
| `AddInputRevampTests.testPanels_addInputSheetResizableAndRemembersSize` | 可缩放、缩不到 700×460 以下（windowWillResize）、第一次 820×560、改成 980×640 关掉 → 本机记下 → 再开 980×640 | ✅ |
| `…testPanels_addInputCameraNegotiationFlagsFrameRateMismatch` | 1–60 fps 的卡在 60p / 59.94p 节目："将以 1920×1080 · 60 / 59.94 fps 采集（与节目帧率一致）"；只有 30 fps → 标黄"…节目是 60 fps，比节目慢，会重复帧"；只有 120 fps 的 720p → "…比节目快，会丢帧（缩放到 1920×1080）"；没报格式不写 | ✅ |
| `…testPanels_addInputNDIPageRefreshesAndDoubleClickAdds` | 进页就找、源按名字排、"找到 2 个源"；间隔 0.2 s 时 3 s 内找了 ≥ 3 次；双击 = 直接加；离开 NDI 页就不再找；输入设置的"来源"一节双击只选上 | ✅ |
| `…testPanels_addInputRecentFilesAndFileInfo` | 记 12 个只留 10 个、新的在前、删掉的那个照列且 exists = false、不能双击加；单击填入、双击加；视频图片各记各的；清空；pattern.mov 信息"H.264 · 1920×1080 · 60 fps · 0:10"；PNG"PNG · 64×32 · 含透明通道"；不在的"文件不在了" | ✅ |
| `…testPanels_addInputAcceptsAudioFilesShownAsAudioOnly` | 四种扩展名认、打开面板收 mp3 / wav / m4a / movie；2 s 的 wav："纯音频 · PCM · 48 kHz · 2 声道 · 0:02"；.wav 的文件输入格子 isAudioOnly、.mov 不是；页上说明带问题单号 | ✅ |
| `…testPanels_addInputAudioDeviceLineHasNoFourCC` | "MacBook Pro 麦克风（1 声道 · 内建）""声卡（2 声道 · USB）""虚拟（2 声道）"；本机设备下拉里没有 bltn / usb / ???? | ✅ |
| `InputSettingsRevampTests.testPanels_inputSettingsSectionsOrderedByUse` | 六节顺序与标题；"音频延迟补偿"中英；"应用名字"键删了 | ✅ |
| `…testPanels_inputSettingsCopyFromOtherInput` | 来源下拉 = 别的输入；勾 裁切与位置 + 抠像 → 一次 setInputSettings、没勾的不动；再抄 音频 + 音频效果 | ✅ |
| `…testPanels_inputSettingsResetsAndPositionClipboard` | 1 号复制位置 → 2 号粘贴（裁切 + 变换相等）；复位裁切不动位置；复位位置；抠像恢复默认 = `KeyerSettings(enabled: true)`；音频整组复位只动增益 / 声像 / 延迟 | ✅ |
| `…testPanels_inputSettingsNameCommitsOnFocusLoss` | 编辑中快照不盖字、还没提交；失焦提交；关窗也提交 | ✅ |
| `…testPanels_inputPreviewClickMapsIntoLetterboxedPicture` | 2:1 的格子放进 300×300：正中 (0.5, 0.5)、上下黑边各 75 不取、角点 (0, 0) / (1, 1) | ✅ |
| `OverlayRevampTests.testPanels_newShowOverlaysDefaultHalfSecondFade` | 新节目四通道 = 淡入 30 拍（60p）；30p 时 15 拍 = 0.5 s、1 s = 30 拍；59.94p 0.5 s = 30 拍；悬停"= 30 拍（按节目帧率换算）"；快捷值"0.5 秒 / 1 秒 / 2 秒"；新建后不算未保存 | ✅ |
| `…testPanels_overlayModeFullscreenOrPictureInPicture` | 默认整幅；画中画放右下 1/4；预设 / 边框；回整幅 = .full、边框设置留着；关了再从底栏开停在上次那一路 | ✅ |
| `…testPanels_overlaySettingsReachableFromMenuBar` | "切换 › Overlay ▸"最后一项"叠加设置…"、能点、打开窗 | ✅ |
| `AudioSettingsRevampTests.testPanels_audioSettingsPagesEnableAndReset` | Master：均衡启用 = 一段、加一段改增益、关 = 两段都旁路参数留着、复位只回参数；压缩启用 / 改阈值 / 关（enabled = false、参数留着）/ 复位；限幅启用；输入 1：三页、横幅"效果尚未作用到声音（本版本）"、改动走 setInputSettings 只换效果链 | ✅ |
| `…testPanels_audioSettingsGeneralPageAndPostFaderMeter` | "48 kHz · 立体声"、推子 −6 dB 读数跟快照；窗左表 = 调音台同一份读数（Master / 输入 1）；再点齿轮同一个窗并切页；没有的输入不开窗；删了输入窗跟着关 | ✅ |
| `…testPanels_mixerLayoutMasterPinnedGroupsCollapsible` | 默认输入展开、总线收起；Master + 三条总线 + 竖条 ≤ 340 pt；表头在 216 / 340 宽时高 ≤ 32 pt（不折行） | ✅ |
| `…testPanels_masterListenAndLoudnessDetails` | 听 Master 返回 false、仍是耳机总线；响度五行"−21.0 / −23.0 / −24.5 LUFS、5.2 LU、−1.2 dBTP"，静音总线写 — | ✅ |
| `AudioDeviceRevampTests.testAudio_busOutputMapStoredLocallyAndFitsDevice` | standard 与包里同口径；fitting；让位（耳机让给 Bus B）；换 2 声道设备去掉 3/4 以上；恢复默认存 nil；空设备只有"不输出"；AppSettings ↔ UserDefaults 往返、nil 删键；`AudioRuntime(device: .null, busOutputMap:)` 的配置 map = (0,1)/(2,3) | ✅ |

### 2.3 改到新入口上的旧用例（不删断言；随 spec 改了判据的逐条列出）

| 用例 | 改了什么 |
|---|---|
| `ShortcutAndShowTests.testAddInput_sheetPresentsSwitchesKindsAndCancels` | **"第一次停在合成测试源" → "停在摄像头 / 采集卡"**（G2 / Q58，01a G2 原文"钉默认值的两条测试跟着改"）；"确定 = 加一路合成源"前先切到合成测试源（测试机不加摄像头） |
| `BottomBarSplitTests.testUI_addInputMenuRecentReAddsWithFreeNumber`（92） | 同上一条：主体第一次停在摄像头、先切到合成测试源再加；▴ 的八种类型按 `displayOrder`（和左栏同序，判据"与面板左栏同一顺序"没变） |
| `BottomBarPopupTests.testUI_bottomBarPopupsStayInsideWindow`（叠加那一段） | **"叠加弹出层整块在窗口里、朝上、400 × min(640, …)" → "叠加按钮开独立的叠加设置窗（不是主窗口子窗口、不是 sheet）"**：I1 / X21 把弹出层换成了窗口，底栏没有弹出层了；外部显示菜单那一段判据不变 |
| `PanelTests.testPanels_openChangeOneItemSnapshotFieldChanges`（叠加四条） | 入口从 `presentOverlayPanel` / `overlayPanelController` 换成底栏按钮 → `panels.overlaySettingsWindow.model`，改的项与判据不变 |
| `AccessibilityTests.testAccessibility_allPanelControlsHaveLabels` | "叠加面板"换成"叠加设置窗"四个通道各查一遍，另加"音频设置 · Master / 输入 1" |
| `ToolbarMenuTests.testUI_switchMenuShowsHotkeysFromTable`（93） | "切换 › Overlay ▸"的行多两行"—""叠加设置…"（规则 5：主窗口里放了的入口菜单栏里都还在） |

### 2.4 收尾全量与 lint

| 项 | 结果 |
|---|---|
| `make test-app` 第一遍（23:27，`Test-Switcher-2026.10.03_23-27-02`，4 分 50 秒；同机 98 的测试宿主也在跑） | 188 条：182 过、1 红、5 跳。红的是 `DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger`（显示类，"PGM 监视器 0 帧 > 20"——窗口被别的会话的测试宿主盖住时就红，坑见以往报告），**单独复跑 1 / 1 过**（9 s）。跳过的 5 条：键盘导航那条 BLOCKED-系统设置（92）、摄像头 BLOCKED-权限、虚拟摄像头 BLOCKED-签名，另两条（ISO A4、推流到 MediaMTX）是这个 worktree 还没编 release frameprobe——编好之后单独跑 **2 / 2 过**（13 s / 17 s） |
| `make test-app` 第二遍（23:34，`Test-Switcher-2026.10.03_23-34-54`，5 分 16 秒；release frameprobe 已编好；98 的测试宿主中途起来） | 188 条：184 过、2 红、2 跳（键盘导航 BLOCKED-系统设置、虚拟摄像头 BLOCKED-签名；摄像头那条这一遍没跳、过了）。红的两条都是环境类、和第一遍不是同一条：`ExternalOutputAppTests.testMultiview_windowTogglesPresentsAndSavesFrame`（多画面窗口 0 帧——显示类，窗口被盖住就红）、`StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous`（推流停在 backoff——同机别的会话也起 MediaMTX 时抢端口，G6 起的同机并行记录里写过）；**两个类单独复跑全过**（ExternalOutputAppTests 3 / 3、StreamWiringTests 1 / 1，推流 17 s） |
| `make test-app` 第三遍（00:06，`Test-Switcher-2026.10.04_00-06-37`，5 分 13 秒；想等机器安静 60 s 再跑，等了 25 分钟同机 96 / 98 一直有测试在跑，到点照跑） | 188 条：185 过、1 红、2 跳（同上两条 BLOCKED）。红的那条显示"Crash: PlusMix"、记在 `VisualDetailTests.testUI_panSliderCenterTickNoFill` 名下：崩溃报告 `PlusMix-2026-10-04-001143.ips` 是**已知 S1 `MIDIHost.sync` "non-escaping closure has escaped"**（`freshSession` → 新建节目 → `ControlRuntime.start` → `MIDIController.start` → `MIDIHost.sync`，问题单 `W5A-w2-control-midihost-sync-escaping-crash`，归 W2-C 系，G6 列为 0.1.0 阻塞项），和本分支的改动无关；`VisualDetailTests` 单独复跑 5 / 5 过（声像滑块那条 0.34 s）。同一时段另两份 PlusMix 崩溃报告（23:45、23:46）是 96 的测试宿主（它的 xcresult 时间对得上），不是本分支的 |
| 结论 | 三遍全量每遍都有 1–2 条红，**每一条都是环境类或已知崩溃、换了不同的用例、单独复跑全过**；本分支改到的用例（§2.1–2.3）三遍都是绿的。没能拿到一遍"0 红"的全量：同机 94–98 几个会话整晚都在跑 App 测试（显示类窗口被盖、MediaMTX 端口），外加 MIDIHost 那个已知崩溃 |
| `make lint BRANCH=w5-app-panels` | 禁词 / 版本号 / Package.swift / 依赖方向 / check-links（167 个 Markdown）/ check-rt-symbols 全绿；**归属相对 main 红**：只因为 92 / 93 的两份报告（`reports/w5-app-bottom-bar.md`、`reports/w5-app-toolbar.md`）在本分支的历史里；`scripts/check-ownership.sh w5-app-panels --base 8a13a21` = **41 个改动文件都在允许范围内**（App/、本报告、两张问题单）。92 / 93 合进 main 之后照常 `make lint BRANCH=w5-app-panels` |

## 3. 没做的和原因

| 项 | 原因 / 去向 |
|---|---|
| 耳机里听所选总线（J7 的引擎侧）、2 声道设备上"独听时临时占用 Master 声道" | prompt 不做项（监听所选总线的引擎侧）；`AudioOutputDevice.busMap` 建设备时定死、设备回调里没有"按有没有独听切换"。界面与 App 入口做了（Master 条监听菜单、`MixerModel.listen`、音频设备页的选项与"尚未生效"），引擎侧写了问题单 `W5K-w1-audio-monitor-selected-bus`（设备客户端两个原子量的改法） |
| 纯音频文件真的出声（Q57） | FileInput 要求视频轨（FileDecoder.swift:70 `noVideoTrack`），不是本会话的包：问题单 `W5K-w2-inputs-file-audio-only`；App 侧收文件、按纯音频格子画、页上写明 |
| 压缩简单模式"阈值 + 比例 + 输出增益" | 提案 024 批的是 (b)：新 id `compressor`（契约 P5 / 99、实现 W1-D3 / 102）；之前按 (c) 写实文案过渡（压缩量 = headroom）。`compressor` 进契约后音频设置窗压缩页换比例滑块 |
| 噪声门、插件页（J4） | 要新键（提案 023 与后续方案），prompt 写明"（噪声门、插件等 023 与后续方案）" |
| 每路效果格（102） | prompt 不做项；输入的均衡 / 压缩页照挂"尚未生效" |
| 积分响度复位（V08） | "复位要不要进命令待定"（02 V08）；响度详情先只读 |
| 合成"设置"窗（F1） | 96（W5-J）的活；"音频设备"一节先放在偏好设置里，视图与模型（`AudioOutputSettingsSection` / `AudioOutputSettingsModel`）自成一体，96 合窗时整节搬 |
| 输出设置 / 偏好设置 / 快捷键编辑器窗在前时的快捷键 | X12 的后半（"设置类窗口在前时按键不切"）；本会话只给自己的三扇窗（输入设置、叠加设置、音频设置）挂了转发，输出设置是 95、偏好设置 / 快捷键是 96 正在改的窗，快捷键编辑器录键时本来就要截键——同一个 `PanelCoordinator.forwardHotkeys` 一行就能挂，留给它们 |
| G13（拖文件进来直接加）、G14（图片多选 / 改了 PNG 自动换） | 不在本会话的 G2–G12 范围 |
| 输入设置窗的"单路预览"高清画面 | Q55 定先裁多画面纹理（缩略图级）；做调色时再给渲染器加单路目标 |
| 手册（docs/user） | 归 103：需要改的段落见 §5 第 10 条 |

## 4. 对契约的疑问

1. **"耳机里听哪条总线"要不要进状态 / API**：现在只在 App 里（`MixerModel.listenBus`，引擎不支持时不换）。引擎支持之后，若要 API / 快捷键 / 控制面板也能切，应进 `AudioState`（如 `monitorSource: Bus`）+ 一条命令（`setMonitorSource`），要提案；只做本机界面的话不用。
2. **总线出口（BusOutputMap）是本机偏好，不进节目文件**：同一个节目换一台机器（声卡不同）声道对不上，所以存 UserDefaults（与音频设备选择同一级）。若以后要"节目自带出口"，那是契约（Show 里加字段）。
3. **新节目叠加默认淡入 0.5 s 只在 App 的 emptyShow 里写**（I3 原文"不动契约默认值"）：API / headless 建的节目、契约的 `OverlayAnimation()` 默认仍是切入 0 拍。要统一就改契约默认值（提案）。
4. **响度详情读 Stats 的 `lufs_m / lufs_s / lufs_i / lra / true_peak_db`**（提案 004 的字段），没有新增；积分复位（V08）若要做是一条新命令。

## 5. 下一个会话需要知道的坑

1. **G7 合并顺序与冲突**：本分支叠在 93 头 `8a13a21` 上，先合 92、93 再合本分支（94、96 也叠在同一个头上）。`make lint BRANCH=w5-app-panels`（相对 main）在 92 / 93 合进 main 之前会因为它们的两份报告红（越界的只有 `reports/w5-app-bottom-bar.md`、`reports/w5-app-toolbar.md`），
   合之前查归属用 `scripts/check-ownership.sh w5-app-panels --base 8a13a21`（41 个文件都在允许范围内）。和同批几路最可能撞的文件：
   `UI/InputCellView.swift` / `UI/InputStripView.swift`（94 输入条与格子：本分支只加了 Overlay 小按钮的右键菜单——挂在每个小按钮的 `NSButton.menu` 上，与 94 改成 `contextMenu()` 的格子右键菜单互不相干，94 若重建了这排小按钮，把 `OverlaySettingsMenu.make` 那一行挂回去——
   以及 `onOverlaySettings` 透传、纯音频文件算 isAudioOnly）、
   `Settings/PreferencesPanel.swift` / `AppSettings.swift` / `AppDelegate.swift`（96 合窗、98 加键：本分支把音频一节整节换成 `AudioOutputSettingsSection`、加两个键、加 `showOverlaySettings(_:)` 动作）、
   `UI/PanelCoordinator.swift`、`UI/MainWindowController.swift`（几路都会加接线：本分支是追加，冲突按"两边都留"）、两份 `Localizable.strings`（两边的键都留）。
2. **测试宿主的 UserDefaults suite 现在每个构建位置一个**（`com.plusmix.switcher.tests.<hash>`）：以前几个会话同时跑 App 测试会互相清键，现在不会了；`$TMPDIR/switcher-tests/`（录制目录、hotkeys.json 所在的 config）仍是共用的。
   `PanelTests` 里读 `persistentDomain(forName: AppController.testDefaultsSuite)` 的那条照用常量，不受影响。
3. **sheet 的 contentMinSize 挂上去就被清 0**（探针：挂成 sheet 之后 styleMask 多了 docModal、contentMinSize / minSize 都是 0）：添加面板的最小尺寸靠 `windowWillResize` 兜。
4. **SwiftUI 控件 label 的源码扫描只看控件那一行和下两行**：`Button { } label: { 图标 }` 的 `.accessibilityLabel(` 要紧跟在下一行（放第四行就算缺 label）。
5. **`EffectChainEditor(slots:)` 每次重建、EQ 段的 `id`（UUID）不稳定**：按 id 找段的绑定会失效，音频设置窗按下标绑（越界读 0、写不动）。
6. **Swift 6：Timer 的 block 参数不能送进 `MainActor.assumeIsolated`**（"sending 'timer' risks causing data races"）：在闭包外判断、再 `timer.invalidate()`。
7. **快照在转场 / 叠加动画期间每拍都来**：新加的面板模型都先比"自己显示的那部分"再发布（音频设置、叠加设置、调音台、输入设置的 config）；以后往面板里加要读快照的字段，记得加进比较。
8. **全量里偶尔有一条显示"Crash: PlusMix"**：先看 `~/Library/Logs/DiagnosticReports/PlusMix-*.ips` 的触发帧——`MIDIHost.sync` 那个是已知 S1（W2-C 系），崩在哪条用例名下只是那一刻正好在 freshSession；
   报告里的路径是匿名的，按 procLaunch 时间去对各 worktree 的 `.build/DerivedData/Logs/Test/*.xcresult` 名字认是谁的测试宿主（同机几个会话的崩溃报告混在一个目录里）。
9. **本机 MacBook Pro 相机最高 30 fps**：添加输入的摄像头页在 60p 节目下是黄的"会重复帧"——是对的，不是 bug；测试机上没有屏幕录制权限，屏幕页在测试宿主里总挂横幅、只列显示器。
10. **给 103（手册）的改动**：`docs/user/输入.md`（添加输入：第一次停在摄像头、分组、横幅、最近文件、纯音频文件这一版会报错；输入设置：分节顺序、本路画面与取色、复制粘贴位置、从其他输入复制、跟随视频、"音频延迟补偿"）、
   叠加一节（独立窗、四个入口、整幅 / 画中画、默认淡入 0.5 s、时长按秒）、音频一节（音频设置窗与分页、压缩量 = 阈值 + 压缩量的写法、调音台布局与收起、监听菜单与响度详情、设置 › 音频设备 每条总线选声道、2 声道设备的提示）；英文手册同步。
   手册"输入设置表说音频一节有跟随视频（AFV）"（X55）现在属实了。
