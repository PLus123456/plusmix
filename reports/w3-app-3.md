# W3-E2 App 合并收口报告（prompt 63，分支 w3-app-3）

分支：桌面端开的 worktree 分支 `claude/w3-app-3-localize-p3-ec0049`；prompt 里叫 `w3-app-3`，本地另打同名引用（`git branch -f w3-app-3 HEAD`）给
`check-ownership.sh` 用（同 W3-E / P3 的做法）。基于 main `4b7a3df`（P3 / W1-A3 / W2-A2 合入、提案 015 落地之后）。前 15 个提交只动了 `App/`，另加本报告、
`docs/contract-changes/016`、两张新问题单（`W3E2-w3-outputs-3-package-status-text-language`、`W3E2-w1-testkit-frameprobe-unpinned-deps-swift-runtime`），
并在三张旧问题单末尾写了处理结果。
**报告交出去之后用户批了提案 016、同意 Package.resolved 入库**（2026-09-23："016 批了，Package.resolved 入库也按你说的做"），本会话接着做了（§1 末两段）：
`App/` 之外动的文件逐个列进了 docs/OWNERSHIP.md 的 `w3-app-3` 行（016 的契约 + reducer + 校验器 / 目录 + 各自测试 + CONTRACTS.md / api.md，三个 Package.resolved）。
机器：MacBook Pro M5 Max，macOS 26.6.2（25G83），Xcode 27.0，接电源；**这次多了一块外接屏 LG ULTRAGEAR（2560×1440，在内置屏上方）**。
同一台机器上同时在跑 W3-B2（w3-compositor-3）与 W3-C2（w3-outputs-3）两个会话，跑测试前都等它们的 swift test / xcodebuild test 停了（§5 第 2 条）。

## 1. 做了什么

21 个提交（`git log main..w3-app-3`）：前 15 个是 prompt 63 本身（最后两个是本报告与问题单），后 6 个是用户批 016 / Package.resolved 之后做的（本节末两段）。App/ 下 42 个文件，+2.4k / −0.6k 行；App/ 之外 11 个源码 / 测试文件（016）、3 个 Package.resolved、CONTRACTS.md / api.md / OWNERSHIP.md、提案与问题单。

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 W3-C 的 39 处文案本地化；包里的中文在 App 侧查表 | `AppDelegate`、`Engine/AuxOutputRuntime`、`Engine/OutputRuntime`、`Engine/SwitcherSession`、`UI/ExternalOutputMenu`、`UI/MultiviewWindowController`；新 `Engine/OutputStatusText.swift` | 39 处全改 `L(键)`（`menu.output.virtualCamera.*`、`externalMenu.*`、`notice.*`、`aux.*`），两种语言各一份。`SystemExtensionInstaller.describe` / `ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` / `DiskEstimate.describe` 都返回中文，**包不改**：App 按枚举查表，事件只带枚举。`.failed(String)` 带的原因是包拼好的中文，只能原样附上 → 问题单给 W3-C2（§3 第 2 条）。删了 4 个没人引用的旧键。LocalizationTests 五条全绿 |
| 2 切换面板：Wipe 方向 / 软边、Stinger 输入 / 换底拍、时长预设、T-bar | `UI/TransitionPanelView.swift`、新 `UI/TransitionParams.swift` | T-bar 上面一行"T-bar：Wipe ［参数…］"，参数…弹出面板：方向五向、软边 0–0.3、Stinger 输入、换底拍 0…时长。先按 prompt 用 loadShow 整体替换做（要等转场 / 叠加动画 / FTB 全部空闲再发，还会盖掉别的来源的改动），写了提案 016；**016 批了之后改发 `setTransitionParams`**（见本节末），只有转场进行中才延后。时长预设改的本来就是唯一的 durationTicks，五种转场共用；T-bar 按状态里的类型推 |
| 3 每通道 PVW 预览 + 总开关 | `UI/OverlayPanel.swift`、`Settings/PreferencesPanel.swift`、`AppSettings.swift`、`Engine/SwitcherSession.swift` | 叠加面板每通道"PVW 预览"→ `setOverlayDecoration`（P3 的 A4）；偏好设置"PVW 预览全部叠加"→ UserDefaults `overlaysInPreview` → 建 session 时的 `MetalRendererOptions.overlaysInPreview`（渲染器选项 init 定死，换 session 生效，界面写明） |
| 4 ISO 入口二选一 | 新 `Settings/ISORoutes.swift`；删 `UI/ISOPanel.swift` | **留输出设置 › ISO 页**，底栏"ISO…"改成打开它；加的路走 W3-C 的 ISORoutes（编码 / 目录抄 PGM、模板一定带 `{output}`、名字 ISO n），录着的路锁住，页里显示目录 / 余量 / 还能录多久。原来设置页加的路不补 `{output}`，两套入口各算一遍 |
| 5 MIDI 热插拔（W2-C 没修） | 新 `Engine/MIDINotificationAnchor.swift`、`AppController.swift` | 探针证实（§2.3）：CoreMIDI 把全进程的通知派到第一次 MIDIClientCreate 时的 run loop；App 启动时先在**主线程建一个锚客户端**，之后每个 session 的控制器热插拔通知都走主 run loop。包没改 |
| 6-007 对齐延迟 / 监听点 | `Settings/PreferencesPanel.swift`、`AppController.changeShowAudio` | 偏好设置"节目音频"一节（0…24000 帧、步长 256、旁边显示毫秒；延迟线前 / 后），落 `AudioState`；运行期改要重建延迟线，loadShow 不重建音频引擎，所以"应用" = 换 session（同改节目格式；录制 / 推流会停，界面写明） |
| 6-008 DeckLink 接口 / NDI 带宽 / 抖动缓冲 | `UI/AddInputSheet.swift` | DeckLink：DeckLinkDevices 列卡（第一项"第一台有输入的卡" = 空串，契约口径），接口按卡支持的列（卡不在全列）、"不改" = nil；NDI：后台发现源（NDIFinder 1.5 s，没 SDK / 没找到也能手填）、带宽三档、抖动缓冲 0–2 帧。输入设置窗摘要显示当前值 |
| 6-010 叠加装饰 / 多画面布局 | `UI/OverlayPanel.swift`、`Settings/OutputSettingsPanel.swift`、`UI/InputStripView.swift`、`UI/InputCellView.swift` | 叠加：边框（开 / 宽 0–0.05 / 色）、锚点九宫、PVW 预览走 setOverlayDecoration；滑入方向（自动 / 四边）走 setOverlay（顺手修了 setAnimation 每次新建 OverlayAnimation 把 slideFrom 冲掉）。输出设置加"多画面布局"页：预设 + 安全框 + 电平表读写 `OutputSettings.multiview`，自定义格子只读列出（非空时预设置灰，给一个"清掉自定义格子"），没有多画面输出就加一个只承载布局的（source = multiview、**enabled = false**，§4 第 2 条）。**缩略图以前固定按默认布局切格子**，换了布局就切错：改成按当前布局算（`MultiviewLayout.placements`，正式字段优先、过渡键后备，与渲染器同一顺序），布局里没有的路写"不在多画面布局里" |
| 6-012 来源可编辑 + 确认新命令 | `Settings/InputSettingsPanel.swift`、`UI/AddInputSheet.swift` | Add Input 每类参数页抽成 `InputSourceFormView`，输入设置窗"来源"一节复用它，"应用来源"发 `setInputSource`（编号 / 名字 / 设置 / PGM / PVW / 叠加引用都保留，运行表按"编号 + 来源"重建那一路）；删了原来置灰的 DeckLink / NDI 占位控件。确认 `MixerModel.setMonitorMode / setBusEffects`、`OutputSettingsModel` 开关 / 改名已发新命令（看命令日志的用例）；菜单"启用 / 停用虚拟摄像头"也从删了重加改成 setOutputEnabled |
| 6-每路 AFV | `UI/MixerPanelView.swift` | 条子加"跟随视频"开关（默认开，走 setInputSettings），全局开关不变；门控显示改成 dB、读 AudioEngineStatus（afv = false 的路引擎恒给 1 = 0 dB，不在界面另算） |
| 6-013 外部显示正式字段 + Stats.display[] | `Settings/OutputSettingsPanel.swift`、`UI/ExternalOutputMenu.swift`、`AppDelegate.swift`、`Engine/SwitcherSession.swift` | 外部显示页只写 `OutputSettings.display`（不再显式写 `fallbackToMain: false`，015 起就是默认），加"退回主屏"与"启用"（setOutputEnabled）开关；改显示器前先 `migratingLegacyKeys()`，内存里带过渡键的一改就搬进正式字段、清掉旧键。外部输出菜单"关闭 n …（状态）"、虚拟摄像头菜单状态行、输出设置页的状态**只读 Stats.display[]**，不再读 `countersSnapshot` |
| 7 纯音频设备输入 | `Engine/InputFactory.swift`、`UI/AddInputSheet.swift`、`UI/InputCellView.swift`、`UI/InputStripView.swift`、`UI/MixerPanelView.swift` | 工厂 `.audio` 建 `AudioDeviceInput(config:audioRing:)`（生产者块 1024，videoSlot 不解包，帧槽照旧建）；八种都有实现了，删 `InputFactoryError`。Add Input 纯音频页用 `AudioInputDevices.list()`（第一项"系统默认输入" = 空串 uid，显示声道数 / 48 kHz / 传输类型），`observeChanges` 插拔刷新、关表单 stop；设备声道 > 2 时选"前两路 / 选两路 / 单声道一路"（014），DeckLink 同理 1–16 路。摘要"第 5、6 路"。纯音频输入的缩略图格子画话筒 + 名字 + 电平表（读调音台同一份 AudioEngineStatus），设备不在写"等音频设备"不写"无信号"，权限问题照样显示 W2-A2 的文案。Info.plist 早有 NSMicrophoneUsageDescription |

另外（合并遗留，顺手收掉）：输出设置 › 虚拟摄像头页原来另有一个 `VirtualCameraSupport`，按 `<bundle id>.camera` 猜扩展 ID（实际是
`com.example.switcher.camera-extension`），**查 / 装的根本不是那个扩展**；删掉，改用 session 的 `SystemExtensionInstaller`（与菜单同一个，AuxOutputRuntime 扇出状态）。
三处过时提示改成实情（抠像"渲染由 W3-B 做"、兼容层"合入前只保存设置"、NDI 发送"App 接线在 W3-C"——App 里的 NDI 发送其实还没接，§3 第 3 条）。

**提案 016 落地**（用户批之后，4 个提交：`6193f56` 契约 + reducer、`e41eeb4` 校验器 / 命令目录 / api.md、`91c9322` App，外加本报告的更新）：
`Command.setTransitionParams(wipe:stinger:)`，reducer 按提案五条——转场进行中（auto 或 T-bar 推到一半）拒、stinger.input 非 nil 须存在（0 也拒）、softness 钳 0–1、
cutAtTick 钳 ≥ 0（不钳上限）、相同值原样返回；校验器只查引用（HTTP 400"Stinger 用的输入 n 不存在"），与 reducer 一致；`CommandKind` / 目录插在 setTransition 后面，
docs/api.md 重生成（34 条）；CONTRACTS.md §2.5 / §2.6 / §8 / §9 同步。只加命令不加字段，Show.schemaVersion 不升，老命令 / 老状态 JSON 逐字节不变。
App 的 `TransitionParamsModel` 改发新命令：叠加进出动画、FTB 渐变进行中照发、不打断；只在转场进行中先显示在面板上、转场结束再发；发出后别的来源抢先起了转场（会被拒）的，转场结束后补发。

**Package.resolved 入库**（`7a7a63a`）：`Packages/SwitcherOutputs/`、`Packages/SwitcherTestKit/`、`Tools/frameprobe/` 三个，版本与已跟踪的 `Tools/switcher-headless/Package.resolved` 同一套
（swift-collections 1.6.0、swift-crypto 4.5.2、swift-nio 2.102.0……）。从零编的 frameprobe 不再引用 `_swift_initBorrow`，本 worktree 自己编的 debug / release 都能起（§2.2 两条原来红的用例用它跑过）。

## 2. 每个测试：数值 / 阈值 / 通过否

### 2.1 prompt 点名的测试与本会话新增的用例（都看快照字段 / 命令日志，不看画面）

| 测试 | 数值 | 阈值 / 判据 | 通过 |
|---|---|---|---|
| LocalizationTests 五条（原四条 + 新 `testL10n_packageStatusesLookedUpInApp`） | App/Sources 写死中文 0 处（原 39）；两种语言键集合相同、占位符一致；源码用到的键都在表里；包的每个枚举值 / Stats.display 每个 state 两种语言都有文案、英文里无中文 | 全 0 违规 | ✅ |
| `testPanels_openChangeOneItemSnapshotFieldChanges` 加的六条：Wipe 参数（上→下 + 软边 0.2）、Stinger 参数（2 号 + 第 12 拍）、通道 1 PVW 预览、通道 1 边框（0.01 + 红）、对齐延迟 4096 + 延迟线后（换 session，看新快照与 `AudioEngine.configuration`）、NDI 带宽最低 + 抖动缓冲 2 帧（Add Input） | 另加锚点 + 从左滑入一条；整表 35 条 3.6–4.9 s | 每条 3 s 内（对齐延迟那条 20 s）快照字段变了 | ✅ |
| `TransitionPanelTests.testTransitionButtons_wipeSwapsAfter24Ticks_tbarKeepsType` | 点 Wipe 后 `transition.type == .wipe`，完成拍 − 起始拍 = **24**；T-bar 推到 0.5 时类型仍 wipe、到顶对调；Zoom / Stinger 两按钮同路各 24 拍 | = 24 拍、对调 | ✅ |
| `testTransitionDurationPreset_appliesToAllTypes` | 选 1 s 预设后 Zoom 60 拍、Fade 60 拍 | = 60 | ✅ |
| `testTransitionParams_setTransitionParams_deferredOnlyWhileTransitionActive`（016 之后改写，原 `…replaceViaLoadShow…`） | 软边 0.9 → 钳 0.3、换底拍 999 → 钳 30，输入对象不变；面板快照过时时发参数，别的来源刚改的 Master −6 dB **保留**；240 拍的叠加淡入进行中改软边 → 立刻生效、叠加动画没被打断；转场中改的等转场完成才发、转场照常对调；命令日志里 ≥ 5 条 setTransitionParams **全部 applied**、没有 loadShow。**反证**：对着旧实现（loadShow）跑红 5 处（Master 被盖回 0 dB、叠加动画挡住参数、日志里是 loadShow） | — | ✅ |
| 016 契约：`Contracts016Tests` 三条 | JSON 形态 `{"setTransitionParams":{"stinger":{"cutAtTick":12,"input":9},"wipe":{"direction":"topToBottom","softness":0.2}}}`；stinger 没设输入不写 input 键；提案正文样例能解、往返不变；setTransition 与 TransitionState 的 JSON 逐字节不变、schemaVersion 仍 1 | 逐字节 | ✅ |
| 016 reducer：`ReducerTests.test016_setTransitionParams_rejectedWhileActive_appliesAfterwards` + 覆盖表 6 行 | auto 转场中 / T-bar 推到 0.4 时原样返回；转场按原参数走完（PGM = 2）后再发生效、只动 wipe / stinger；相同值原样返回；cutAtTick 500 不钳；表：生效、软边 1.5 → 1 / −0.3 → 0、换底拍 −4 → 0、stinger 输入 9 与 0 拒、T-bar 中拒；覆盖表 34 个 case 每个至少一行 | — | ✅ |
| 016 命令总线：`testValidator_agreesWithReducer`（加 4 条）、`CommandCatalogTests`、`APIServerTests`（目录 34 条） | 合法两条放行、非法两条（输入 9 / 0）拒且 reducer 也原样返回；每个 kind 有样例、JSON 顶层键 = case 名、docs/api.md 与生成器一致；GET /api/v1/commands 34 条 | — | ✅ |
| `InputWiringTests.testInputSettings_sourceEditSetsInputSource_keepsReferences_rebuildsRuntime` | 合成源 → pattern.mov：编号 [1, 2]、名字、叠加通道 1 引用、PGM / PVW 都没变；命令日志里是 setInputSource、没有 removeInput；运行对象换成 FileInput 且 live | — | ✅ |
| `MixerPanelTests.testMixer_perInputAFVToggle_gateStaysUnityAfterProgramCutsAway` | 1 号关跟随视频、PGM 从 1 切到 2 后 `AudioEngineStatus` 里 1 号 afvGain = **1**，跟随视频的 3 号 = 0、PGM 上的 2 号 = 1；条子显示"AFV 0 dB"/"AFV −∞ dB"；再打开 1 号回到 0 | 看数不听声 | ✅ |
| `PanelTests.testPanels_externalDisplayPageWritesFormalDisplayFields` | 新加一路 `display == DisplayOutputSettings(displayID: 主屏)`、extra 空；带过渡键的内存状态改显示器后 `display.displayID` 变了、extra 里没有 displayID / fallbackToMain 键；退回主屏开关写正式字段；启用开关 = setOutputEnabled、窗口收起设置留着 | — | ✅ |
| `PanelTests.testPanels_p3RewiredCallsUseNewCommands` | 日志里有 setMonitorMode / setBusEffects / setOutputEnabled / renameOutput，没有 loadShow、没有 removeOutput | — | ✅ |
| `PanelTests.testPanels_preferencesOverlaysInPreviewTakesEffectOnNextSession` | 跑着的 session 不变；换 session 后 `renderer.options.overlaysInPreview == true`；关掉再换回 false | — | ✅ |
| `ISOAppTests.testISO_singleEntry_bottomBarOpensSettingsTab_templateCarriesOutput` | 底栏 ISO… 打开输出设置 ISO 页；加的路名字 ISO 2、模板带 `{output}`（PGM 的没有也补）、码率 / 目录抄 PGM；录着锁住删不掉，停了能删 | — | ✅ |
| `ControlEditorTests.testMIDI_hotplugAfterShowReplaced_newSourceConnects` | 换两次节目后建虚拟源 5 s 内连上、销毁后消失；**去掉锚时同一条红 2 处**（锚没建 / 5 s 内 sources = []） | — | ✅ |
| `InputWiringTests.testInputs_audioDeviceInputWiredAsAudioOnly` | 工厂建的是 AudioDeviceInput、videoSlot nil、块 1024、环已注册；格子是纯音频占位、不显示"无信号"；能进 PGM。单跑那次宿主还没麦克风授权（W2-A2 的"尚未授权"那句 error，格子照样显示它）；全量那次已授权，**live（MacBook Pro麦克风）** | — | ✅ |
| `MultiviewSettingsTests` 两条 | 3×3 + 安全框 + 电平表落进 `settings.multiview`、extra 不写 layout、输出 enabled = false；缩略图 1 号的格子 = 3×3 布局的内框（与默认不同）；自定义格子只读两行、2 号缩略图"不在多画面布局里"、清掉后恢复；只带过渡键 `extra["layout"] = "3x3"` 的内存状态缩略图也按 3×3 | — | ✅ |
| Add Input 模型 / 表单：`testAddInput_modelMakesConfigs`（改）、`testAddInput_modelRoundTripsExistingSources`、`testAddInput_channelMapChoices`、`testAddInput_formDeviceListsHaveDefaultEntries` | 空串 DeckLink ID / 空串 uid 按契约口径合法；008 / 014 字段；11 种来源从表单填回再出来逐字段相同；声道三段式与摘要"第 5、6 路"/"channels 5, 6"；纯音频第一项"系统默认输入"、插拔订阅在 close 时摘掉；DeckLink 第一项"第一台有输入的卡"、卡不在接口全列、内嵌音频 16 路 | — | ✅ |
| `VirtualCameraAppTests` 两条（改） | 菜单状态行 / `session.virtualCameraStatusText` 读 Stats.display[]（state waitingExtension → "找不到虚拟摄像头设备…已丢 N 帧"）；设置页的扩展 ID = `VirtualCameraConstants.extensionBundleIdentifier`、状态跟着同一个安装器 | — | ✅ |
| `ExternalOutputAppTests.testExternal_menuListsDisplaysAndSources_marksExisting`（改） | "关闭 n …（状态）"= `OutputStatusText.display(Stats.display[] 那一项)`，含"显示中" | — | ✅ |
| 无障碍 `testAccessibility_allPanelControlsHaveLabels` / `swiftUIControlsDeclareLabels` | 新加的转场参数弹出面板、多画面布局页、来源一节、叠加面板新控件都在遍历 / 源码扫描里，缺 label 0 | 0 | ✅ |

### 2.2 全量 `xcodebuild test`（SwitcherTests）

2026-09-23 16:12–16:15（178 s），开跑前等到机器上 30 s 没有别的会话的 swift test / xcodebuild test / gate（W3-B2 的包测试刚跑完），内置屏当前 Space 是桌面（出帧类用例能跑）：

| 结果 | 数 | 说明 |
|---|---|---|
| 通过 | 68 | 27 个类；含本会话新增 / 改的全部用例 |
| 跳过 | 1 | `testL1_virtualCameraEgress_requiresSignedExtension`：BLOCKED-签名（解锁：Team ID 签名 + /Applications + 系统设置允许扩展） |
| 失败 | 2 | `ISOAppTests.testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame`、`StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous`：**都是 frameprobe 子进程起不来**（`dyld: Symbol not found: _swift_initBorrow`，见 §5 第 12 条），断言本身没走到。录制本身没问题：A4 那条三个文件同一起始拍 #99 / 同一边界拍 #598、各 499 帧、跳帧 0 |

换成 G4 worktree 里那份能跑的 frameprobe（同一份源码，main 4b7a3df；本分支没动 Tools/）只重跑这两条：**都过**——
A4（App）8 个事件，闪光极差最大 **0.0 ms**、click 极差最大 **0.02 ms**（阈值 ≤ 16.67 ms，目标 ≤ 1 ms）；推流 10 s 到本机 MediaMTX 644 帧，丢 0、重复 0、解不出 0。
所以按用例本身算：**71 个，70 过、1 跳（BLOCKED-签名）、0 失败**。

全量里顺手记下的数（与 G4 同量级）：外部窗口 59.8 fps（3.2 s 内 blit 193 次），拖主窗口期间 missed_render 0 → 0；缩略图 23.22 fps、PGM / PVW 59.7 fps；
内置摄像头 0.80 s live；**纯音频输入这次是 live（"MacBook Pro麦克风"）**——之前单跑时宿主还没有麦克风授权（"尚未授权"那句 error），这次 TCC 已允许，live 路径也走到了；
虚拟摄像头 searching、已丢 104 帧（没装扩展，符合预期）；本地化表 690 条。

**016 / Package.resolved 之后（HEAD `f65b1a1`，frameprobe 用本 worktree 钉版本后自己编的）又跑了两次全量**，都是等机器上 30 s 没有别的会话的测试之后开跑：

| 次 | 时间 | 结果 | 说明 |
|---|---|---|---|
| 1 | 17:16–17:19（176 s） | 71 个：68 过、2 跳、**1 失败** | 失败的是 `UISmokeTests.testUI_smoke_launch…`：`maxSnapshotsPerSecond` 61 > 60（§5 第 13 条：这个数是整个测试宿主生命周期里、按事件锚定的 1 s 窗口数出来的最大值，60 Hz 轮询下窗口起点那次晚几毫秒就能数到 61；上一轮全量 56、单跑 40、与新的转场参数用例同宿主跑两次 43 / 44，都过）。跳过的除 BLOCKED-签名外多一条内置摄像头 **BLOCKED-权限**（这轮 TCC 的摄像头 / 麦克风授权都回到"尚未授权"，§5 第 14 条），纯音频那条照旧按"权限问题照样显示"的路径过 |
| 2 | 17:23–17:26（173 s） | **71 个：70 过、1 跳（BLOCKED-签名）、0 失败** | 冒烟那条峰值 **60/s**（贴线）；摄像头 live 0.84 s；纯音频 live（"MacBook Pro麦克风"） |

两次都过、原来红的两条：**A4（App）闪光极差 0.0 ms、click 极差 0.02 ms**（阈值 ≤ 16.67 ms）；**推流 10 s 到本机 MediaMTX 643 帧，丢 0、重复 0、解不出 0**（第 1 次 745 帧，同样 0 / 0 / 0）——
frameprobe 用的就是本 worktree 从钉好的 Package.resolved 编出来的，不再借 G4 worktree 那份。新的 `testTransitionParams_setTransitionParams_deferredOnlyWhileTransitionActive` 两次都过（约 1.1 s）。
第 2 次的读数：外部窗口 60.1 fps、missed_render 0 → 0；缩略图 23.98 fps、PGM / PVW 60.2 fps；显示解耦 PGM blit 53.1 fps、missed_render 全程 0；本地化 690 条。
这两轮外接屏没接（"外接屏 BLOCKED-硬件（只有内置屏）"），所以没有外接屏上的读数。

### 2.4 016 之后的包测试（`swift test`）

| 包 | 结果 |
|---|---|
| SwitcherCore（Render 79 / Engine 91 / Contracts 76 三个测试包） | 245 过、1 跳（原有的）、0 失败 |
| SwitcherControl（SwitcherControlTests 28 / VMixCompatTests 25 / TallyTests 3） | 55 过、1 跳（原有的）、0 失败 |
| SwitcherInputs / SwitcherAudio / SwitcherOutputs / SwitcherTestKit / switcher-headless / frameprobe | `swift build` 都过（这几个不穷举 Command；编完三个入库的 Package.resolved 一个字节没变） |

`make lint BRANCH=w3-app-3`：禁词 / 版本号 / Package.swift 约束、依赖方向（8 个包）、归属（66 个改动文件都在允许范围内）、实时符号全绿。

### 2.3 探针

- **CoreMIDI 通知派到哪条 run loop**（scratchpad `midiprobe/probe.swift`，约 30 行）：线程 1 建客户端、跑 0.3 s run loop 后退出并销毁；线程 2 建客户端、跑 run loop；主线程建虚拟源、跑主 run loop 3 s。
  不建锚：客户端 2 收到 `msgObjectAdded` **0 次**；先在主线程建一个锚客户端：客户端 2 收到 **1 次，回调线程 = main**（锚也收到 1 次）。
  结论：通知由"进程里第一次 MIDIClientCreate 时的 run loop"派发，与 W3E 问题单的推断一致；主线程锚可行。
- **测试宿主的窗口可见性**（临时用例，没提交）：本会话中途有一段时间 Claude 桌面端全屏占着内置屏的当前 Space，测试宿主的主窗口 `isOnActiveSpace = false`、
  `occlusionState` 不含 `.visible`、display link 暂停 → **所有 MetalDisplayView 的 presentedFrames 都是 0**，出帧类用例红（外部窗口 blit 0 次）。不是代码问题，见 §5 第 1 条。

## 3. 没做的和原因

1. ~~Wipe / Stinger 参数没有正式命令~~：提案 016 已批并落地（§1 末）。没顺手做的一条见 §4 第 1 条（removeInput 不清 stinger 引用）。
2. **SwitcherOutputs 里剩下的中文**（`SystemExtensionInstaller.status(for:)` 的 `.failed` 原因、外部显示窗口标题 "Switcher 外部输出"、CMIOSinkStreamClient 的错误描述）：包不归本会话，
   写了问题单 `reports/issues/W3E2-w3-outputs-3-package-status-text-language.md`（归 W3-C2 / w3-outputs-3；ISO 那一处 `DiskEstimate.describe` 不在 W3-C2 的归属行里，请检查点定）。
3. **App 里的 NDI 发送仍没接线**（`OutputRuntime` 的 `.ndi` 只给 Stats 占 idle，P3 报告 §1 已记）：不在 prompt 63 范围；设置页提示改成了实情。
4. **纯音频输入的人工项**（W2-A2 清单 §9 那几条：多路接口上选第 5、6 路、插拔、系统默认输入切换）没做：本机只有内置麦克风（1 声道），声道选择只在模型 / 表单层测了；live 路径在全量里走到了（§2.2）。
5. **docs/checklists/G4.md 第 1 / 2 / 4 条的文字过时**（"纯音频设备 → 不支持的输入类型""PVW 默认不画叠加、需求记到提案 010""切换面板还没有这些参数的控件，归 W3-E2"）：清单归检查点，请检查点改。
6. 自定义多画面格子的编辑器（prompt 明确不做）。

## 4. 对契约的疑问

1. **`removeInput` 不清 `transition.stinger.input`**（提案 016 之外发现的，没动）：删掉 stinger 用的那一路后引用悬空，`MixerState.validate()` 也不查它；
   overlay 的输入引用在 removeInput 里会清。016 之后 `setTransitionParams` 会拒不存在的 stinger 输入，所以悬空的只能来自"先设再删"。
   建议 reducer 的 removeInput 顺手把它置 nil（与 overlay 同口径），要不要做、归谁（W1-B 的 reducer）请用户定。
2. **kind = multiview 的输出的 `enabled` 语义没写清**：渲染器取第一个 kind = multiview 输出的布局**不看 enabled**；而 enabled 且 `source = multiview` 会让渲染器每拍多转一次 NV12（`CompositorPasses.wants`），
   App 里这个 NV12 没有下游。g4-show.json 里那一个是 enabled 的（headless 每拍多转一次，P3 报告 §5 第 1 条记过代价）。App 新建的只承载布局、enabled = false。
   建议在契约注释里写明"多画面输出的 enabled = 要不要把多画面 NV12 送给下游（NDI 之类），布局与它无关"。
3. `OverlayBorder.width` 契约写"渲染器钳到 0–0.1"，界面只给 0–0.05（1080p 下 54 px，再宽就不像边框了），API 仍可给到 0.1。不需要改契约，记一笔。

## 5. 下一个会话需要知道的坑

1. **测试宿主的窗口不在当前 Space 时，所有出帧类用例都读到 0 帧**：MetalDisplayView 在窗口被遮挡 / 不在当前 Space 时暂停 display link（W2-B 的设计）。
   本会话中途用户把 Claude 桌面端全屏在内置屏上，测试宿主开的窗口落在别的 Space → `ExternalOutputAppTests` 的帧率 / 多画面窗口刷新、`ThumbnailRateTests`、`DisplayDecouplingAppTests` 之类一律 0 帧而红。
   **跑 `make test-app` 前先退出全屏 / 切到桌面 Space**；判别法：日志里"外部显示（App）：… blit 0 次"，或临时打印主窗口的 `isOnActiveSpace`。
2. **两个会话同时跑 App 测试会互相踩**：测试宿主共用 UserDefaults suite `com.example.switcher.tests` 与 `/tmp/switcher-tests/`（`AppController.init` 会删 config 目录）。
   开跑前查别的 worktree 有没有 `xcodebuild … test`（`for p in $(pgrep -f "[x]codebuild .*test"); do lsof -a -p $p -d cwd -Fn; done`）。
3. 本机现在有外接屏（LG ULTRAGEAR，在内置屏上方）。PanelTests 的"外部显示页"用例刻意用一个不存在的显示器 ID + 关着的输出，免得在外接屏上全屏盖住人；
   "加一路 PVW 到主屏"那几条照旧会在主屏上开全屏窗口（G4 起就这样），跑测试时会盖住操作界面几秒。
4. **ExternalOutputMenuBuilder 只有最后建的那个活着**（MainWindowController 只留一个，菜单项的 target 是它）：测试里建了新菜单之后，旧菜单的项点了没反应。
5. 两处同名类型在 App 里也撞到：`AddInputSheet.swift` 引了 SwitcherDeckLink（位集 `DeckLinkConnection`）→ 契约的单个口一律写 `SwitcherContracts.DeckLinkConnection`；
   `PreferencesPanel.swift` 引了 SwitcherAudio → 契约的 `MonitorPoint` 写 `SwitcherContracts.MonitorPoint`（P3 报告 §5 第 2 条同一个坑）。
6. `AddInputFormModel` 建的时候挂了 Core Audio 设备插拔订阅，**用完要 `close()`**（sheet 关、输入设置窗关都调了；别处新用它记得调）。
7. 文案里的计数一律 `Int(clamping:)` 配 `%ld`（`UInt64` 直接当 CVarArg 配 `%d` 在 64 位上只读低 32 位）；LocalizationTests 的占位符比对认 `%ld`。
   SwiftUI 的 `Text("\(x)")` 走本地化插值（Xcode 27 报 deprecated），纯数字 / 枚举描述用 `Text(verbatim:)`。
8. 加 / 删 App 源文件后要 `make gen`（XcodeGen），否则 xcodebuild 报"Build input file cannot be found"。
9. `Packages/SwitcherControl/Package.resolved` 每次 xcodebuild 都会被改，提交前 `git checkout`；**`Packages/SwitcherOutputs/`、`Packages/SwitcherTestKit/`、`Tools/frameprobe/` 的 Package.resolved 现在入库了**（用户批，§1 末），别删、别 `swift package update`（G4 报告 §9"生成物别提交"对它们不再适用）。
10. 转场参数**只在转场进行中（含 T-bar 推到一半）不发**（`TransitionParamsModel.isPending`；reducer 会拒 setTransitionParams），测试里要等转场结束再看快照；叠加动画 / FTB 渐变不挡。
    `isPending` 在快照回来之前一直是 true（发出去了也是），判"已发"看快照或命令日志。
11. `make lint` 要显式给分支名：`git branch -f w3-app-3 HEAD && make lint BRANCH=w3-app-3`（worktree 分支名与 OWNERSHIP 里的不同）。
12. **没钉版本编出来的 frameprobe 在本机起不来**（`dyld: Symbol not found: _swift_initBorrow`）：不跟踪 `Package.resolved` 时从零解析浮到 swift-collections 1.7.0、
    swift-crypto 5.0.0、swift-nio 2.103.0……，编出的二进制要 Swift 6.4 运行时，macOS 26.6.2 没有。**已修**：三个 Package.resolved 入库（第 9 条），钉到 headless 那套版本。
    别的分支若还是 main 4b7a3df 的老样子（没有这三个文件），新 worktree 里照样会撞上——合并本分支之前可以先拷 `Tools/switcher-headless/Package.resolved` 过去再编。
    升依赖另做（W4-A / W4-B），升完在 macOS 15 / 26 各起一次 frameprobe / App。问题单 `reports/issues/W3E2-w1-testkit-frameprobe-unpinned-deps-swift-runtime.md` 已写处理结果。
13. **`UISmokeTests` 最后那条"快照分发每秒最多 60 次"会偶发红在 61**（本会话 016 之后的第 1 次全量）：`MainWindowController.maxSnapshotsPerSecond` 是**整个测试宿主进程**的最大值
    （窗口控制器跨用例共用，从不清零），前面跑过的任何用例都算；窗口以"上一个窗口满 1 s 后的第一次回调"为起点，60 Hz 的轮询 Timer 只会晚不会早，起点那次晚了 δ，
    60 个周期后那次准点到，就是 61 次落在 1 s − δ 里——**分发本身仍是每次 Timer 触发至多一次**（另有注册观察者时立即回调的那一次，换 session 时会多出来）。实测：单跑 40、与新转场参数用例同宿主 43 / 44、打印了这个数的三轮全量 56 / 61 / 60。
    按铁律 9 没动这条用例和阈值；要稳可以（a）冒烟开头把计数清零、只量本条用例，或（b）按 Timer 的触发序号数而不是按墙钟窗口数，改哪样请用户定。
14. **TCC 的摄像头 / 麦克风授权会在会话之间被重置**：别的会话重编 App（同一 bundle ID、换了签名）之后，测试宿主的授权回到"尚未授权"，内置摄像头那条 XCTSkip（BLOCKED-权限），
    纯音频那条走"权限问题照样显示"的分支。本会话第 1、2 次全量之间又恢复了（没查是弹窗被允许了还是别的会话又用原来的签名重编），判别看日志里"摄像头权限尚未授权"。
