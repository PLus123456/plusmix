# W5-A 目视与弹出报告（prompt 86，分支 w5-app-visual）

分支：桌面端开的 worktree 分支 `claude/w5-app-visual-8e1f3c`；prompt 里叫 `w5-app-visual`，本地另打同名引用（`git branch -f w5-app-visual HEAD`）
给 `check-ownership.sh` 用（同 W3-E4 的做法）。基于 main `25af61f`（App/ 与调研时的 c836cce 相同，03 的量数直接可比）。
机器：MacBook Pro M5 Max，macOS 27.0（26A428），Xcode 27.0，接电源；两块屏：内建 1728×1117 @2×（今天是主屏、在下）+ LG 2560×1440 @1×（在上）。
只动 App/（`make lint BRANCH=w5-app-visual`：35 个改动文件都在允许范围内）+ 本报告 + 一张问题单。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 底栏弹出朝上（E1 / X50 / X63） | `UI/BottomBarPopup.swift`（新）、`UI/ScreenMenu.swift`（新）、`UI/ExternalOutputMenu.swift`、`UI/OverlayPanel.swift`、`UI/MainWindowController.swift` | `BottomBarPopup`：菜单左上角放在按钮坐标 `y = −菜单高 + 1`（NSButton 是翻转坐标），popover 用 `.minY`；叠加面板 `preferredContentSize = 400 × min(640, 窗口内容高 − 120)`（最矮 240），表单 `minWidth 400`、高度可伸缩，宿主视图不再按内容尺寸自己定大小。"显示器 ▸"子菜单拍平：每块屏一段，段标题 = 显示器，输入那一组前面仍有 Aux 说明的小标题。**另外实测发现**：程序改过窗口位置之后马上按视图弹（`popUp(…in: view)`），NSMenu 用的是窗口位置的旧缓存，菜单落在上一次的地方（1440×900 ↔ 1100×700 来回换，第二次弹出的菜单按旧窗口左上角摆，激活 App、置前窗口都不管用）；改成换算到屏幕坐标再弹（`ScreenMenu`，`in: nil`），三处菜单（底栏、T-bar 类型、自定义时长）都走它 |
| 2 转场列排版（03 §1.3 布局表） | `UI/TransitionPanelView.swift`、`UI/TBarView.swift`、`UI/ClockView.swift`、`UI/Theme.swift`、`L10n.swift` | `.leading` + 每行宽 = 列宽 − 16；两档控件（regular 24 / 13 pt、small 20 / 11 pt）；组内 4、组间 8、组标题到控件 2；T-bar 把手与按钮同宽、最小高 60；时钟 56 高、1 pt `Theme.divider` 边框、圆角 6、20 / 11 pt 字、12 小时制 `setLocalizedDateFormatFromTemplate("hmma")`（locale 跟界面语言，`L10n.locale`）；`Theme.setHighlighted` 高亮态标题一律白字（attributedTitle；状态没变不重设，不每帧新建串）。"Overlay"组标题 11 pt（V-07 只做了这一列的部分） |
| 3 转场列最小步（Q01 默认 B 的最小一步；C3 / C5 / X16 / X39 / X40） | `UI/TransitionPanelView.swift`、`UI/HotkeyText.swift`（新）、`AppController.swift` | T-bar 上方那行是按钮 + 菜单：段标题"T-bar 和回车用（只选，不执行）"，列五种类型、当前打勾，选 = 只发 `setTransition(type, 当前时长)`，转场进行中不可选。**按钮上只写"Wipe ▾"**：这一行 134 pt，"T-bar · Stinger ▾"（small 按钮 106.5）加"参数…"（51）放不下，T-bar 的意思写在提示、辅助功能标签（"T-bar 和回车用的转场：Wipe"）和菜单段标题里。类型变了（点 Fade / 菜单 切换 › Fade / API）那一行高亮 1.5 s（accent 底白字）。时长分段第四段：预设时写"…"（提示"自定义时长…"；写全"自定义…"四段要 168 pt），时长不是预设时选中并写实际值（"0.75s"），点它弹菜单：不是预设时第一项"✓ 自定义：0.75 s"，下面"自定义…"打开输入框（秒，0.1–10，按标称帧率换拍，类型不变）。按钮提示从当前快捷键表反查（`HotkeyText`：⌃⌥⇧⌘ 符号、空格 / 回车 / Esc / 方向键），换 session、快捷键编辑器保存时刷新；Fade 不再写死"回车"，T-bar 那一行写"回车：按这里选的转场执行" |
| 4 主窗口分栏与位置（X61 / X45 / X47 / X44） | `UI/MainWindowController.swift`、`AppController.swift`、`UI/PanelWindowController.swift`、`UI/PanelCoordinator.swift`、`Settings/InputSettingsPanel.swift`、`Tests/TestSupport.swift` | delegate `shouldAdjustSizeOfSubview` 对输入条 / 调音台返回 false，分隔条下限 = 转场列最小高；`placeWindow`：先 `setFrameUsingName`，没有存档才 `center()`，再挂存档名。**测试宿主只读存档、不挂存档名**（bundle id 与正式 App 相同、同一个 defaults 域，原来用例改窗口会写回用户真 App 的主窗口位置）。打开节目（`replaceSession` 之后）读回 `mixerPanelVisible` / `multiviewWindowVisible` / `mainWindowFrame`；屏幕外的位置不用，尺寸不小于 minSize。输入设置窗存档名 `InputSettings-<n>`，没存过位置的新窗口错开放在最近那个的右下（24 pt）。`AppTest.freshSession()` 每条用例开头把界面摆回初始样子（全字段夹具会收起调音台、把主窗口搬到 (0, 0)） |
| 5 文案合规与关于面板（P4 / X59 / X62 / V-13 / V-14） | `UI/AboutPanel.swift`（新）、`AppDelegate.swift`、`UI/AudioTransportName.swift`（新）、`UI/AddInputSheet.swift`、两份 `Localizable.strings`、`Tests/VirtualCameraAppTests.swift` | 兼容层标题去掉模块名（两种语言）；法律提示去掉"设计方案 §0、§9.3"，保留"正式发布前还要经律师审阅"（PanelTests 的口径）。关于面板 `orderFrontStandardAboutPanel(options:)`，credits 原句见下；系统那一行版本传空串（探针确认空串就不显示），版本只在 credits 第一行写一次。"查看开源许可"是链接：包内 `Contents/Resources/Licenses/` 存在就指它；开发构建退到从 App 位置往上找到的仓库 `THIRD_PARTY/README.md`；都没有就写"开源许可随正式发布版提供"。NDI® 写在添加输入的类型 / 页标题、输出菜单、输出设置页签、输入设置来源行。V-14 十五处 + 调音台两条提示里的 `Stats.audio` 改成人话；音频设备说明行拆两行，CoreAudio 传输类型四字码（bltn 等 17 种，码表对过 SDK 头文件）翻成"内建 / USB / 蓝牙 / 雷雳…" |
| 6 小逻辑与目视 S3 | `UI/ExternalOutputMenu.swift`、`UI/TransitionPanelView.swift`、`AppDelegate.swift`、`UI/MixerPanelView.swift`、`UI/Theme.swift`、`Settings/PreferencesPanel.swift`、`UI/AddInputSheet.swift` | 外部输出菜单：勾 = enabled，点有的 = `setOutputEnabled` 开关（配置留着），删除是最后一段单独的"删除 n 名字（状态）"，"全部关闭"只关不删、没有开着的路时不列。Overlay 空通道按下用当前 PVW 那一路开（`overlay(ch, on: true, input: pvw)`），关的时候不清空，PVW 是黑场时不开、底栏提示。窗口菜单（和输出菜单）的"调音台 / 多画面"按可见性打 ✓（`validateMenuItem`）。调音台根视图贴顶（V-03）。PVW 绿调暗到白字 4.76:1，电平表绿段另留原亮度（V-06）。偏好设置分辨率 / 帧率 `Text(verbatim:)`、端口 `.number.grouping(.never)`（V-12）。文件 / 图片路径框"未选择文件"占位（V-17）。声像滑块：`PanSliderCell` 自绘一条同色细轨 + 中点刻度，把手仍是系统的（V-27；探针确认系统滑块带刻度也照填强调色、`trackFillColor` 只是换色） |
| 问题单 | `reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md` | 全量里 App 测试宿主偶发崩在 `MIDIHost.sync`（SwitcherControl，见 §2.4） |

提交（`git log main..HEAD`，按交付拆，每次都单独编过、跑过那一批用例）：
`c5e1a30` 转场列 · `ed2e59f` 底栏弹出 · `edf563f` 主窗口 · `89be1b3` 文案与关于面板 · `f2ba98d` 调音台与对比度 · 本报告。

关于面板 credits 原句（居中、11 pt、次要文字色；最后一行是链接）：

| zh-Hans | en |
|---|---|
| 版本 0.1.0（构建 1） | Version 0.1.0 (build 1) |
| 以 Apache License 2.0 发布 | Released under the Apache License 2.0 |
| NDI® is a registered trademark of Vizrt NDI AB. | NDI® is a registered trademark of Vizrt NDI AB. |
| 查看开源许可 | Open-Source Licenses |

（找不到许可目录时最后一行换成"开源许可随正式发布版提供" / "Open-source licenses ship with release builds"，不带链接。NDI 那句按 NOTICE.md 的要求两种语言都用英文原句。）

## 2. 测试：数值 / 阈值 / 通过否

### 2.1 改前 / 改后尺寸对照（沿用 03 的量法）

量法：1440×900 与 1100×700 两种窗口，x 从转场列左沿量，"可见边"取对齐矩形（推按钮 / 分段控件的对齐矩形就是画出来的边框）；菜单开着时用 CGWindowList 取本进程弹出菜单窗口的边界；
SwiftUI 的排版用 ImageRenderer 渲成位图量（cacheDisplay 截不到 SwiftUI，探针确认）。"改前"有两列：03 调研在 c836cce 上的实测，和本会话用同一套量法在 25af61f（App/ 与 c836cce 相同）上的复量。

| 项 | 改前（03 · c836cce） | 改前（本会话复量 · 25af61f） | 改后 |
|---|---|---|---|
| 六个转场按钮 | 8…141 | 8…142 | 8…142 |
| 时长分段 | 28…141，small 控件配 13 pt 字 | 28…142 | 8…142，small 20 pt / 11 pt |
| "Overlay"标题 | 文字 103…138（居中贴右） | — | 组标题左 8，11 pt |
| Overlay 1–4 | 24…141 | 24…142 | 8…142，间距 4 |
| T-bar 那一行 | 标签文字 27…84，随字长漂 | 标签 23…87 + 参数… 91…142 | 类型菜单 + 参数… 8…142 |
| T-bar 把手 | 14…135 | 14…136（视图 8…142、把手左右各缩 6） | 8…142 |
| 时钟 | 8…141，2 pt 白框，"12:13 上午" | 8…142 | 8…142，1 pt 分隔线色框，"下午5:01" |
| 列最小高 | 483 | 483 | **408**（阈值 ≤ 409） |
| 1100×700 时 T-bar | 13 pt | 120（列只分到 466 < 483，其余行被挤） | **64**（列 412；阈值 ≥ 60） |
| 输入条（1440×900 → 1100×700） | 1100×700 时 133 | 190 → 143 | **197 → 197**，放回 1440×900 仍 197 |
| 调音台宽 | 216 / 282 | 339 → 259 | **339 → 339**（1 pt 是分隔条，见 §5） |
| 外部输出菜单 | 两块屏：伸出窗口下沿 25 pt，显示器子菜单再伸 228 pt | 复量时只接了一块屏：顶层菜单 330×34，从按钮下沿往下挂，伸出窗口下沿 1 pt | 拍平 265×549（两块屏 × 6 路），**底边在按钮上沿之上 4 pt、离窗口下沿 56 pt**；1440 → 1100 → 1440 来回换后再弹仍是 4 / 56 |
| 叠加弹出层 | 1100×700 整块弹到窗口外 318 pt；放不下时翻上去但内容 320×320、标签被裁 | 内容 320×320 | 1440×900：弹出层 426×666、内容 400×640；1100×700：426×574、内容 400×548；**都朝上、整块在窗口内** |
| T-bar 类型菜单 | （没有） | （没有） | 在按钮正下方、左缘对齐，菜单顶边 = 按钮下沿 |
| PVW 标题条白字对比度 | 3.5:1 | 3.49:1 | **4.76:1**（PGM 5.06:1；阈值 ≥ 4.5） |
| 调音台内容第一行（340×800） | 上下各空约 250 | y = 212 | **y = 10**（阈值 ≤ 16） |

截图核对（screencapture，主窗口挪到没被盖住的 LG 屏、只截本 App 的窗口区域，草稿区，不入库）：转场列、两种尺寸的外部输出菜单与叠加面板、自定义时长 0.75 s、关于面板都与上表一致；
T-bar 那一行最初写"T-bar · Fade ▾"被截成"T-bar · Fad…"，就是看截图发现的，改成"Fade ▾"后再截一次放得下。
测试宿主不在前台时 AppKit 不画 bezelColor（FTB 开着、T-bar 行高亮在截图里都看不出），这两样由用例按属性断言（底色 = Theme.ftbActive / accent、标题前景 = 白）。

### 2.2 本会话的用例（App/Tests/，函数名带 ID；先写用例、在旧代码上量出改前、再实现）

| 交付 | 测试 | 数值 | 判据 | 通过 |
|---|---|---|---|---|
| 1 | `BottomBarPopupTests.testUI_bottomBarPopupsStayInsideWindow` | 见 2.1：菜单（实测）与叠加弹出层（本进程窗口）都在主窗口里、朝上；不用子菜单；叠加内容 400 × min(640, 内容高 − 120) | 弹出物 frame ⊂ 主窗口 frame（±0.5）；底边 ≥ 按钮上沿 − 1；内容宽 = 400、高 = 公式（±0.5） | ✅ |
| 6-1 | `BottomBarPopupTests.testUI_externalMenuFlatChecksEnabledAndTogglesOutput` | 段数 = 屏数、段首是显示器段标题；点 PVW 加 → ✓、有窗口；再点 → enabled false、窗口收起、输出还在、无 ✓；再点 → 同一个编号重新开；"删除 n …"带 Stats 的状态；"全部关闭"只关不删、没有开着的路时不列；删除 → removeOutput；被拒 0 | 同左 | ✅ |
| 2 | `TransitionColumnTests.testUI_transitionColumnEdgesAligned` | 11 行左右边 8…142（两种窗口）；组标题左 8；控件档 / 字号；时钟 56、1 pt、分隔线色；最小高 408；1100×700 T-bar 64 | 边差 ≤ 1；最小高 ≤ 409；T-bar ≥ 60 | ✅ |
| 3 | `TransitionColumnTests.testUI_tbarTypeMenuSelectsWithoutExecuting` | 菜单五项、Fade 打勾；选 Wipe 后快照 type = wipe，program 1 / preview 2 / 时长 30 不变，UI 命令只有一条 `setTransition(wipe, 30)`；点那一行实测菜单在按钮下方、左缘对齐；回车走 Wipe；转场中菜单项全灰；被拒 0 | 同左 | ✅ |
| 3 | `TransitionColumnTests.testUI_tbarTypeRowHighlightsWhenTypeChanges` | API 改 Wipe → 高亮、1.5 s 后消失；点 Fade → 类型变 Fade、那一行 accent 底白字 | 同左 | ✅ |
| 3 | `TransitionColumnTests.testUI_transitionDurationCustomSegment` | 四段；45 拍 → 选中第四段、写"0.75s"，菜单"✓ 自定义：0.75 s"+"自定义…"；输入 1.5 s → 90 拍、类型不变；输入 0 不发；回到 1 s 预设 → 第四段回"…"、菜单没有打勾项 | 同左 | ✅ |
| 3 | `TransitionColumnTests.testUI_transitionTooltipsFromHotkeyTable` | 默认表：Cut"快捷键：空格"、Fade"没有快捷键"、T-bar 行"回车：按这里选的转场执行"、FTB"快捷键：F"；换表（⇧C → Cut、回车 → Fade、⌥1 → Overlay 1）后提示跟着变 | 同左 | ✅ |
| 6（C6） | `TransitionColumnTests.testUI_overlayEmptyChannelUsesPreview` | 空通道 3 按下 → on、input = PVW 2；关 → input 仍 2；已指定的通道换了 PVW 也不跟；PVW 黑场时通道 4 不开、底栏提示含"Overlay 4"；被拒 0 | 同左 | ✅ |
| 2（V-05） | `TransitionColumnTests.testUI_highlightedTitlesAreWhite` | FTB / 静音 / 录制高亮时标题前景 = 白，取消后回系统色；白字压 FTB 红 8.4:1 | 白；≥ 4.5 | ✅ |
| 2（V-08） | `TransitionColumnTests.testUI_clockTwelveHourUsesLocalizedTemplate` | zh-Hans 下格式 "ah:mm"（= hmma 模板） | 等于模板结果、上下午在前 | ✅ |
| 4 | `MainWindowLayoutTests.testUI_splitKeepsInputStripMinimum` | 1440×900 → 1100×700 → 1440×900：输入条 197 / 197 / 197，调音台 339 / 339 / 339 | 输入条 ≥ 190；调音台 ≥ 340 − 1；上半区放得下转场列；放回去输入条不变 | ✅ |
| 4 | `MainWindowLayoutTests.testShow_layoutKeysRestoredOnOpen` | 打开 {调音台收起, 多画面开, 主窗口 1200×760@(40,30)} → 三样都恢复，存回去同值；屏幕外的 mainWindowFrame 不用、其余照恢复 | 同左（位置 ±1） | ✅ |
| 4（X45） | `MainWindowLayoutTests.testUI_mainWindowRestoresSavedFrameInsteadOfCentering` | 有存档 → 按存档摆；没存档 → 居中；只读模式不挂存档名；测试宿主主窗口没挂存档名；正式名仍 SwitcherMainWindow | 同左 | ✅ |
| 4（X44） | `MainWindowLayoutTests.testUI_inputSettingsWindowsHaveDistinctAutosaveNames` | 存档名 InputSettings-1 / -2；两个窗口原点不同 | 同左 | ✅ |
| 6（V-31） | `MainWindowLayoutTests.testUI_windowMenuChecksMixerAndMultiview` | 调音台开 ✓ / 多画面关；切换后反过来 | 同左 | ✅ |
| 5 | `CopyComplianceTests.testL10n_noModuleNameInUserStrings` | 两份 .strings 含模块名 token 的键 0 个；标题两种语言 | = 0 | ✅ |
| 5 | `CopyComplianceTests.testL10n_ndiTrademarkInAboutCredits` | 两种语言 credits 都有 NDI® 原句、Apache License 2.0、版本、"查看开源许可"链接（开发构建指向仓库 THIRD_PARTY/README.md，文件存在）；假包有 Licenses/ 时指它；都没有时不给链接；options 的 credits / applicationName；App 菜单"关于"走 `showAbout(_:)` | 同左 | ✅ |
| 5 | `CopyComplianceTests.testL10n_ndiTrademarkOnFirstUse` | 5 个键两种语言都有 NDI® | 同左 | ✅ |
| 5（V-14） | `CopyComplianceTests.testL10n_noDevJargonInUserStrings` | 19 个术语 token（§、BLOCKED、AVCaptureDevice、ParametricEQ、DynamicsProcessor、PeakLimiter、--api-listen、--api-token、--audio-device、AppleLanguages、环形缓冲、ring buffer、audio ring、时钟从属、scheme、CMIO、Team ID、Contents/Library、bltn）命中 0 | = 0 | ✅ |
| 5（V-14 / V-16） | `CopyComplianceTests.testL10n_audioTransportTypeTranslated` | bltn → 内建 / Built-in，usb → USB，blue → 蓝牙，virt → 虚拟设备，thun → Thunderbolt；"????"、不认识的 → 不写 | 同左 | ✅ |
| 6（V-03） | `VisualDetailTests.testUI_mixerContentTopAligned` | 340×800 渲染第一行内容 y = 10 | ≤ 16 | ✅ |
| 6（V-06） | `VisualDetailTests.testUI_tallyTitleBarsContrast` | PVW 4.76、PGM 5.06 | ≥ 4.5 | ✅ |
| 6（V-12） | `VisualDetailTests.testUI_preferencesNumbersNotGrouped` | "1920×1080"、"8098"、en_US 下"65535"；源码里没有 `format: .number)` / `Text("\(` | 同左 | ✅ |
| 6（V-17） | `VisualDetailTests.testUI_addInputEmptyPathShowsPlaceholder` | 真 sheet 里文件 / 图片两页各 1 个可编辑框带"未选择文件"占位 | = 1 | ✅ |
| 6（V-27） | `VisualDetailTests.testUI_panSliderCenterTickNoFill` | 每路一个 PanSliderCell 滑块、−1…1、有辅助功能标签；直接画轨道：把手在 +0.5 时中点左右同色、中点刻度比轨道亮 | 同左 | ✅ |

按新行为改了的旧用例（断言意图不变）：`TransitionPanelTests`（T-bar 那一行的文字 → "Wipe ▾"）、`ExternalOutputAppTests.testExternal_menuListsDisplaysAndSources_marksExisting` /
`AuxLayeringAppTests.testAux_rawPictureNoteInExternalMenuAndSettingsPages` / `PanelTests.testPanels_externalDisplayMenuAndWindowLifecycle`（按拍平后的段取，"再点 = 删"改成"再点 = 关，删除项 = 删"）、
`VirtualCameraAppTests.testVirtualCamera_extensionActivationInAdHocSignedApp_reportsBlocked`（状态文字原来断言含"BLOCKED-签名"，这正是 V-14 要拿掉的开发术语；改成含"正式签名"，"界面要说清是签名挡住了"的意图不变）。
测试工具：`W5TestSupport.swift`（新）；`TestSupport.swift` 只在 freshSession 里加一行界面复位。`AppTest.addSynthetics` 的灰度 `UInt8(64 + 32 × n)` 在 6 路时溢出崩溃，新写 `addSyntheticInputs` 用，原函数没动。

### 2.3 红灯（证明用例抓得到老行为）

用例里的新 API（`tbarTypeButton`、`activeBottomMenu`、`placeWindow`、`AboutPanel`…）在旧代码上编不过，所以先用同一套量法写了一条临时量尺寸的用例（不入库），在 25af61f 上跑出 2.1 的"改前（复量）"一列：
时长左边 28、Overlay 左边 24（判据 ±1 → 红）、最小高 483（> 409 → 红）、1100×700 输入条 143 / 调音台 259（< 190 / < 339 → 红）、叠加内容 320×320（≠ 400 → 红）、菜单伸出窗口下沿（→ 红）、PVW 3.49（< 4.5 → 红）、调音台第一行 212（> 16 → 红）。
开发中真红过两次，都是用例抓到的：1100×700 实测菜单落在上一次窗口的位置（→ `ScreenMenu`）；类型菜单顶边压住按钮 3 pt（菜单窗口比给的位置高约 5 pt 的上内边距 → 往下多给 5）。

### 2.4 `make test-app` 全量（124 条）

先 `pgrep -fl "xcodebuild .*test"` 确认没有别的测试在跑再开；但 87 号会话（w5-app-safety）一直在同时编译 / 跑它自己的测试，机器负载均值 5–7。

| 次 | 代码 | 结果 | 红的 | 原因与复跑 |
|---|---|---|---|---|
| 1 | 中途版本 | 117 过 / 4 跳 / 3 红 | `DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger`、`testUI_bottomBarPopupsStayInsideWindow`、虚拟摄像头那条 | 第 1 条：显示视图 0 帧——今天主屏是内建屏、被别的 App 的窗口整块盖住（见 §5），干净的 main 在同一环境下 `ExternalOutputAppTests` 的两条显示类用例也是 0 帧，已复现；第 2 条 → 发现菜单落旧位置，改了；第 3 条 → 改断言 |
| 2 | 定稿 `f2ba98d` | 117 过 / 4 跳 / 3 红 | `ShortcutAndShowTests.testShow_controllerRoundTripReplacesSession`（**测试宿主崩溃**）、`DiskProtectionAppTests` 两条 S7（missed_render 9 / 16 ≠ 0） | 崩溃在 SwitcherControl 的 `MIDIHost.sync`（见下）；S7 两条是负载下的渲染抖动。三条单独复跑全绿 |
| 3 | 定稿 | 119 过 / 4 跳 / 1 红 | `testShow_ndiInputWithoutSourceWaitsAsNoSignal`（测试宿主崩溃） | 同一个 `MIDIHost.sync` 崩溃（这次在 stop 那条路上） |
| 4 | 定稿 | **121 过 / 3 跳 / 0 红**（`Test-Switcher-2026.10.01_17-42-55`） | — | 负载均值降到 2.8，这次没碰上崩溃 |

跳过的都是老的 BLOCKED：两条要 release 版 frameprobe（BLOCKED-工具；新 worktree 没编）、扩展签名（BLOCKED-签名）；前三次还多一条摄像头权限（BLOCKED-权限，第 4 次授权在、真跑过了）。
之后 `swift build -c release --package-path Tools/frameprobe` 编好、单独补跑那两条：`ISOAppTests.testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame` ✅（13 s）、
`StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous` ✅（10 s 644 帧、丢 0）。合起来定稿是 123 / 124 绿，剩 1 条 BLOCKED-签名。

**"全量 0 失败"做到了一次（第 4 次），但不稳**：定稿的另外两次全量都被 `MIDIHost.sync` 的竞态崩溃打断（崩在哪条用例是随机的，被打断的用例单独复跑是绿的）。崩溃在 `Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIHost.swift:62-75`：
`withoutActuallyEscaping` 包着闭包交给宿主线程的 run loop，块里 `done.signal()` 之后调用方立刻离开 `withoutActuallyEscaping`，而 run loop 还没释放那个块，运行时判"非逃逸闭包逃逸了"直接 trap。
同一天 87 号会话的测试宿主也崩在同一处（它的栈里是它改过的 `replaceSession(show:baseline:)`），与本会话的改动无关；这个包不在本会话可改范围，问题单 `reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md`（S1：正式 App 新建 / 打开节目、改格式、退出时走同一条路）。

`make lint BRANCH=w5-app-visual`：禁词 / 版本号 / Package.swift 约束、依赖方向（8 个包）、归属（35 个文件都在 App/）、check-links（163 个 Markdown）、check-rt-symbols 全绿。

## 3. 没做的和原因

- **窗口标题保存后变代码名（A4 / X42）**：先读清单里有 A4，但交付在 87 号（W5-B 第 9 条），本会话没动 `AppController.swift:264` 那一行。
- **V-07 的全局部分**（`Theme.dimText` 提到 0.68、底栏提示蓝字）：交付 6 点名的 S3 里没有它；本会话只把转场列的组标题提到 11 pt。暗灰全局变亮影响所有面板，留给各面板改版（92–97）一起看。
- 03 §3 里其它没点名的 S3（V-01 监视器 16:9、V-04 调音台表头折行、V-09 / V-10 空状态、V-11 快捷键编辑器表头、V-15 长路径、V-18 / V-19 菜单用词与缺项、V-20 外部输出 ▾、V-21 弹出层半透明、V-22 状态行、V-24 最近列表同名、V-25 应用按钮位置、V-28 删除确认、V-29 合成源表单、V-30 键色标签）：不在交付 6 的列表里，且多数归 87 / 92–97 的改版。
- **关于面板"查看开源许可"的点击**：没在用例里真点（会打开 Finder / 编辑器）；断言了链接属性和目标文件存在。包内 `Licenses/` 只在 `make archive` 出的发布包里有，开发构建走仓库的 THIRD_PARTY/README.md。
- **lint 扫 .strings 时不放行模块名 token**：规则归 P0 / 检查点（`scripts/` 不在本会话范围）；本会话用 `testL10n_noModuleNameInUserStrings` 补上同一个检查。
- **手册里的 NDI®**：docs/user 归 W4-C 系，本会话只改界面文案。
- **"全量 0 失败"稳定复现**：第 4 次全量 0 失败，但包里的崩溃让它时红时绿（见 2.4），问题单交控制会话。

## 4. 对契约的疑问

没有改契约。T-bar 类型菜单只发已有的 `setTransition`，Overlay 空通道用已有的 `overlay(channel:on:input:)`，外部输出开关用已有的 `setOutputEnabled`。

一个给用户的界面问题（不涉及契约）：类型菜单按契约列了五种，含 **Cut**。T-bar 推 Cut 时中间没有过渡（推到顶才切）；要不要从菜单里拿掉 Cut，请用户定（转场槽 100 号改版时一起定也行）。

## 5. 下一个会话需要知道的坑

- **NSMenu 按视图弹会落在旧位置**：程序 `setFrame` 改了窗口位置以后马上 `popUp(positioning:at:in: view)`，菜单按窗口位置的旧缓存摆（BottomBarPopupTests 实测：1440↔1100 来回换，第二次按旧窗口左上角摆；激活 App、窗口置前都不管用；等几秒又对了）。一律走 `ScreenMenu`（换算到屏幕坐标、`in: nil`）。底栏以后的 ▴ 菜单用 `BottomBarPopup.popUp`。
- **菜单窗口比给的位置偏约 4–5 pt**：朝上开（`y = −高 + 1`）实测底边在按钮上沿之上 4 pt；朝下开要往下多给 5，菜单顶边才贴着下沿（`ScreenMenu.popUpBelow`）。
- **cacheDisplay 截不到 SwiftUI 的内容**（探针：红块截不到）；量 SwiftUI 的排版用 `ImageRenderer`（平台控件渲成占位，但位置对）；AppKit 控件用对齐矩形量。真图用 shell 里的 `screencapture`：**按窗口号 `-l` 截**，按区域 `-R` 截会把别的 App 的窗口一起截进来。
- **测试宿主不在前台时 AppKit 不画 bezelColor**，高亮态（FTB 红底、T-bar 行高亮）截图里看不出，用属性断言。
- **NSSlider 带刻度在 macOS 27 照样填强调色**，`trackFillColor` 只是换色（左段仍比右段亮）；要"不填充"得自绘轨道（`PanSliderCell`）。现有 `AppTest.isOwnRepresentable` 只认原生 NSSlider / NSSliderCell，换了 cell 的滑块那一层由 NSSlider 本身的标签检查覆盖。
- **两块屏的排布今天变了**：内建屏变成主屏（menu bar 在它上面）、LG 在它上方，用户真 App 的主窗口存档在内建屏上；内建屏被别的 App 的窗口铺满时，测试宿主的主窗口 / 外部显示窗口 / 多画面窗口都被盖住，显示类用例出帧为 0（干净的 main 同样红）。显示类用例红了先看屏幕状态再单独复跑。屏上还挂着别的 App 的系统授权对话框（不是本 App 的，没碰）。
- **并行会话同时跑 App 测试**会共用 `com.plusmix.switcher` / `com.plusmix.switcher.tests` 两个 defaults 域和屏幕；全量前 `pgrep -f "Xcode.app/Contents/Developer/usr/bin/xcodebuild"` 看一眼，`lsof -a -p <pid> -d cwd` 能看出是哪个 worktree 的。
- **测试宿主的主窗口只读存档**：`MainWindowController.placeWindow(…, saving: false)`；输入设置窗的 `InputSettings-<n>` 存档还是会写进正式 App 的域（同老行为：全量里开过输入设置窗的用例都会写，本会话自己的用例跑完删了自己的）。
  合入之前的老代码跑测试仍会写回主窗口存档：今天用户真 App 的 `NSWindow Frame SwitcherMainWindow` 已被改成内建屏居中（`144 136 1440 932`，原来在 LG 上），87 号与本会话的 main 对照跑都是老代码。
- **新 worktree 跑全量前先 `swift build -c release --package-path Tools/frameprobe`**，不然 ISO A4 和推流那两条按 BLOCKED-工具跳过。
- **`AppTest.addSynthetics` 最多 5 路**（6 路灰度溢出崩溃）；要 6 路以上用 `addSyntheticInputs`。
- **调音台 339 不是 340**：分隔条 1 pt 算在了调音台里（`setPosition(宽 − 340)` 与 `constrainMaxCoordinate` 都没减分隔条），老代码就是 339，原型实测也是 339；用例判据写的是 ≥ 340 − 1。92 号重排底栏时可以顺手减掉分隔条。
- **转场列高度预算**：最小高 408，1100×700 时列能分到 412；100 号（转场槽）往列里加行要重新算，或者按 03 的建议把转场按钮排成 2×3。
- **字符串冲突**：87 号同时在改两份 Localizable.strings（OWNERSHIP 已注明冲突留给 G6）；本会话删了 `externalMenu.close` / `closeWithStatus`，新增 `externalMenu.remove*`、`transition.*`、`about.*`、`audio.transport.*` 等 43 个键，改了 26 个键的值（英文 25 个：`effects.eq.title` 的英文本来就没带类名）。
