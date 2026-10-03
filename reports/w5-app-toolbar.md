# W5-G 工具条、监视器齿轮、菜单栏重排报告（prompt 93，分支 w5-app-toolbar）

分支：`w5-app-toolbar`（worktree `.claude/worktrees/w5-app-toolbar-8bcd08`，worktree 自己的分支名 `claude/w5-app-toolbar-8bcd08`，两个名字指同一个提交）。
**92 没合进 main**（main = `190fe32`），按 prompt"92 没合就从 main 开并写明"本该从 main 开；但交付 1 要用 92 的分体控件与外部显示菜单构造器，所以本分支从 **92 的分支头 `w5-app-bottom-bar` = `70d0cf3`** 开（G7 按 92 → 93 的顺序合即可，93 只在 92 之上加提交）。
只动 App/ + 本报告。`make lint BRANCH=w5-app-toolbar`：禁词 / 版本号 / Package.swift / 依赖方向通过；归属一项相对 main 只多出 `reports/w5-app-bottom-bar.md`（92 的报告，跟着 92 的提交带进来的，不是本会话改的），相对真正的基线 `--base w5-app-bottom-bar` 是"22 个改动文件都在允许范围内"；check-links / check-rt-symbols 通过。
机器：MacBook Pro M5 Max（128 GB），macOS 27.0（26A428），Xcode 27.0（27A266a），接电源；内建屏 + LG ULTRAGEAR（2560×1440）。**跑全量时屏幕是锁着的**（`CGSSessionScreenIsLocked = true`，用户不在机器前），见 §2.4。

提交（`git log 70d0cf3..HEAD`）：`d3f84cd` 红灯轮（十条用例 + 新 API 只给签名）→ `f7c7981` 实现 → `d118cb3` 输入条初始高按内容区算（全量第一遍查出来的，§2.4）→ `9d1a4cf` 监视器标题条每个快照先比再拼字 → 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 工具条（A1 / A2 / A5 / A6 / C9 / F2 / M1，Q28） | `UI/MainToolbar.swift`（新）、`UI/SplitBarButton.swift`、`UI/ShowMenu.swift`（新）、`UI/AppMenus.swift`（新）、`UI/MainWindowController.swift`、`AppController.swift` | NSToolbar `.unified` 一行：左"节目"组 新建 ｜ 打开▾ ｜ 保存 ｜ 另存为；正中 外部显示▾（`centeredItemIdentifiers`）；右 录制 / 推流状态 ｜ 设置▾ ｜ ?。**每个按钮的主体都是 nil target 的 AppDelegate selector，和菜单栏那一项同一个**（`newShow(_:)` / `openShow(_:)` / `saveShow(_:)` / `saveShowAs(_:)` / `toggleExternalDisplays(_:)` / `showPreferences(_:)`），点下去是同一段代码——新建 / 打开照样先过 W5-B 的确认（87 报告），用例里两条路弹的是同一问。打开▾ = 打开上次退出时的节目 ─ 最近 10 个（同名带上级目录）─ 清除列表，和"节目 › 打开最近"同一份数据（`ShowDocuments.recentURLs`，同一个 `ShowMenu` 构造）；设置▾ = 设置… ─ 输出设置七页 ─ 快捷键… / MIDI 映射…（96 合窗前设置是几扇窗，这里就是窗 / 页的列表，01a F2"不合并时是窗口列表"），每一项和 App 菜单 / 输出菜单里的那一项标题、selector、页都一样；? = 帮助菜单同一份（`HelpMenu`）。外部显示▾ 是 92 的同一个分体控件（`SplitBarButton`，新加 `placement: .toolbar`：▾ 是下箭头、菜单向下开、左缘对齐整个控件，外框用系统工具条样式）+ 同一个路由菜单构造器（`ExternalOutputMenuBuilder`）；主体 = 全部开 / 关（同底栏主体），开着时字换成强调色（工具条的玻璃外框不画 bezelColor，§5 第 3 条）；一路都没配、也没有第二块屏时从工具条向下弹路由菜单。录制 / 推流状态只显示（`ToolbarOutputStatusView`：底栏两个主体按钮的同一份 `OutputButtonSummary`，铁律 4，不另算；没开写"未录制 / 未推流"、暗；时长等 022 / 101）。不放"暂停输入""精简"（A5 / A6）。全部按钮 `refusesFirstResponder`。没有 session 时节目组以外置灰（工具条项 `autovalidates = false`，自己管）。**工具条那一行算在窗口外框里**：最小窗口改按"内容区仍是原来 1100×700 时那么大"定（`contentMinSize` = 无工具条时 1100×700 的内容区，macOS 27 上外框 1100×720，§5 第 1 条） |
| 2 监视器（B1–B4，Q27） | `UI/MonitorView.swift`、`UI/ExternalOutputMenu.swift`、`UI/MainWindowController.swift` | 标题条右端齿轮（SF Symbols 通用齿轮，无边框白色，`refusesFirstResponder`）= 打开这一路的输入设置：PVW 齿轮开 PVW 那一路、PGM 齿轮直接开 PGM 那一路（Q27 1-(i)，不弹菜单）；黑场 / 那一路不在时灰，提示写"PVW 是黑场，没有可设置的输入"。右键监视器（画面或标题条）= 小菜单"输入设置… / 全屏输出到 ▸"：后者每块屏一项（标题同路由菜单的段标题），勾 = 这块屏正在出这个监视器的画面；点没勾的 = 这块屏改出它（同路由菜单里点源：有输出就换源、没有就加一路、同屏别的路关掉），点有勾的 = 关这块屏（配置留着）——路由菜单的"选源 / 关闭"抽成 `select` / `turnOff` 两处共用。单击 / 双击不绑动作（Q27 2-(i)）。PGM 标题条在 PGM / FTB 字样左边画开着的叠加徽标"通道号 · 输入名"（按通道顺序，读快照 overlays，标题条上的控件、不画进画面；提示"Overlay 1 开着：输入 3「合成 3」"）。参考 PVW 标题条另两个图标不放（Q27 3-(i)）。每个快照先比（编号、名字）与（开着的通道、输入、名字），变了才拼字、改控件 |
| 3 "切换"菜单（O1） | `UI/SwitchMenu.swift`（新）、`UI/MenuKeyColumn.swift`（新）、`UI/HotkeyText.swift`、`UI/TransitionPanelView.swift`、`AppDelegate.swift` | Cut ／ 执行当前转场（类型 · 时长，"执行当前转场（Wipe · 0.5 秒）"）／ ─ ／ 段标题"T-bar 和回车用（只选，不执行）"+ 五种类型 ／ ─ ／ FTB（✓ = 开着）／ Overlay ▸ 1–4（✓ = 开着，标题带输入名，没指定写"Overlay 2（未指定，开 = 用 PVW）"）。五种类型的口径和转场列 T-bar 上方那行的菜单一样（选 = 只发 setTransition、不执行，当前的打勾，转场进行中灰；契约的五种都列、含 Cut，用户 2026-10-03 定），"执行当前转场"按它和当前时长做（为什么不是"点了就执行"，§3 第 4 条）。**右列的键从当前快捷键表反查、只显示**：attributedTitle = "标题\t键"，同一个菜单所有带键的项用同一个右对齐制表位；一个 keyEquivalent 都不设，菜单的 delegate 还让 `menuHasKeyEquivalent` 一律 false——菜单栏先于主窗口 keyDown 截键，认了就和 HotkeyDispatcher 各触发一次（或者把来源从 hotkey 抢成 ui）。反查口径（`HotkeyMatch`）和转场列按钮提示共用一份；Overlay 的开关口径（`OverlayToggle`：空通道用 PVW 那一路开，PVW 也黑场时状态行提示）也和转场列共用。项在建菜单时建好、打开时（menuNeedsUpdate）就地改标题 / 勾 / 右列 |
| 3 App 菜单（O2 / F3，Q48） | `AppDelegate.swift`、`UI/AppMenus.swift`、两份 `Localizable.strings` | "偏好设置…"改叫"设置…"（⌘, 不变）；快捷键… / MIDI 映射… 从"切换"挪到它下面（96 合窗后改成指向设置窗的页）。顺带把同一扇窗的标题与三处提到它的文案也改成"设置"（`prefs.windowTitle`、停止确认的说明"设置 › 操作确认"、叠加 PVW 预览的提示、诊断包 README），不然菜单叫"设置…"、点开的窗叫"偏好设置"；转场列"没有快捷键"的提示原来写"切换 › 快捷键… 里可以设"，改成"PlusMix › 快捷键…" |
| 3 帮助菜单（O3，Q33） | `UI/HelpBook.swift`（新）、`UI/AppMenus.swift`、`AppDelegate.swift` | PlusMix 使用手册 / 快捷键一览 / ─ / 导出诊断包… / 打开诊断文件夹；工具条 ? 弹同一份。使用手册 = 随包 HTML（生成归 103）：找 `Contents/Resources/Help/<界面语言>/index.html`，没有就 `Help/index.html`；都没有 = 灰着、标题"PlusMix 使用手册（手册尚未随包）"（现在就是这样）。快捷键一览 = 按当前表生成一页静态 HTML（按键 / 动作 / 备注，表里的顺序，没有脚本，深浅色跟系统）写到临时目录 `PlusMix-快捷键一览.html`，用默认浏览器打开；改了表再点就是新的 |
| 3 "输入设置…"（O4） | `AppDelegate.swift` | menuNeedsUpdate 里写成"输入 N「名字」设置…"（PVW 上那一路，与 PVW 齿轮同一个对象）；PVW 空时标题回到"输入设置…"并灰着（原来悄悄换成第一路）；⇧⌘I 不变 |
| 3 节目 / 输出菜单（A2 / V-24，01 §5） | `AppDelegate.swift`、`UI/ShowMenu.swift`、`AppController.swift`、`Show/ShowDocuments.swift` | 节目 = 新建 / 打开… / 打开最近 ▸ / **打开上次退出时的节目** / ─ / 保存 / 另存为…。"打开上次退出时的节目"打开退出时自动存的 LastSession（先过换节目的问；和启动时从 LastSession 恢复同一口径：不是文件、保存时要另存，有内容就算未保存；没有这份时灰）。"打开最近"同名文件写"节目.switcher.json — 周三"，上级也同名再往上加一级（最多三级），提示是完整路径；子菜单打开时现建（原来只在新建 / 打开 / 保存之后重建）。输出 = 录制 ▸（= 底栏录制 ▴，92 留给 93 的）/ 推流 ▸ / 外部显示 ▸ / **打开 / 关闭全部外部显示**（= 底栏与工具条的外部显示主体，同一个 selector；标题跟状态：有开着的"关闭全部外部显示"、都关着"打开全部外部显示"、一路都没配而有第二块屏"在副屏上显示 PGM"、都没有就灰）/ 多画面窗口 / 虚拟摄像头 ▸ / ─ / 七个设置页 |
| 全量查出来的 | `UI/MainWindowController.swift`、`UI/Theme.swift` | 输入条初始高原来写成"窗口外框高 − 底栏 − 230"（230 暗含 32 pt 标题栏），加了工具条变成 189；改按内容区算 197，分隔条最大坐标减掉分隔条厚度（同调音台 G6 追加 ③ 的毛病，原来拖到底是 189），两个数挪进 `Theme.inputStripInitialHeight / inputStripMinimumHeight`（§2.4） |

本地化：两份表各加 53 个键、删 3 个（`menu.preferences` → `menu.settings`，`menu.transition.hotkeys / midi` → `menu.settings.hotkeys / midi`），改 5 个值（`prefs.windowTitle`、`confirm.stop.message`、`overlay.previewOnHelp`、`transition.tip.noKeys`、zh 的 `diagnostics.readme`）；新键集中在 `toolbar.*`、`monitor.*`、`menu.switch.*`、`menu.help.*`、`hotkeyList.*`、`menu.show.openLastSession*` / `recentInFolder` / `lastSessionName`、`menu.input.settingsNamed`、`menu.output.recordSubmenu` / `externalOn` / `externalCreate`。

## 2. 每个测试：数值 / 阈值 / 通过否

（功能用例，判据是行为 / 文案逐字相等与几何关系；没有数值阈值。）

### 2.1 本会话的用例（App/Tests/ToolbarMenuTests.swift）

| 交付 | 测试 | 数值 / 看到的 | 判据 | 通过 |
|---|---|---|---|---|
| 1 | `testUI_toolbarItemsMirrorMenuActions` | 主窗口挂着工具条、`.unified`、`.iconOnly`；项依次 [新建, 打开, 保存, 另存为, 弹性空白, 外部显示, 弹性空白, 录制 / 推流状态, 设置, ?]，居中项 = 外部显示；整窗没有含"暂停""精简"的按钮；按钮字 新建 / 打开 / 保存 / 另存为 / 外部显示 / 设置；三个分体按钮有 ▾、没有 ⚙。**六个主体的 selector 与菜单项相同、两边 target 都是 nil**：新建 = 节目 › 新建、打开 = 打开…、保存、另存为 = 另存为…、设置 = App 菜单 设置…、外部显示 = 输出 › 全部开 / 关。打开▾ 含"打开最近"子菜单的每一项（标题 + selector + URL 相同）、打开上次退出时的节目、清除列表；设置▾ 11 项每一项在 App 菜单 / 输出菜单里都有一模一样的（标题 + selector + 页），含 设置… / 快捷键… / MIDI 映射… / 录制设置… / 推流设置… / 外部显示设置…；? 菜单 = 帮助菜单。真点：有改动时工具条"新建"弹"要保存对“工具条”的改动吗？"、取消不换节目，菜单"新建"弹同一问；工具条"保存"写回原文件（文件里输入 = [1]）；外部显示主体（一路装在不存在的显示器上的外部显示输出）→ 全部开、工具条主体字变强调色、底栏主体 bezelColor = 强调色（同一份开关状态）→ 菜单项写"关闭全部外部显示"、点了全部关、配置留着、两边都取消高亮；设置主体 → 设置窗；打开▾ 的最近项 → 不问、打开那个文件（节目名"工具条"、输入 [1]）；拒收 0 | 逐项相等 | ✅ 2.0 s |
| 1 C9 | `testUI_toolbarButtonsRefuseFirstResponder` | 工具条 13 个按钮（新建 / 保存 / 另存为 / ? + 三个分体按钮各三段，含隐藏的 ⚙）+ 两个监视器齿轮全部 refusesFirstResponder、acceptsFirstResponder = false；工具条各项视图里没有漏列的按钮；▾ / ? 的辅助功能名"打开快捷菜单 / 外部显示快捷菜单 / 设置快捷菜单 / 帮助"；每个工具条项、两台监视器走一遍辅助功能树 0 处缺名字（AccessibilityTests 只走内容区，工具条在外面）；点过工具条"保存"后 firstResponder 不是按钮、空格 = Cut（PGM 1 → 2）；拒收 0 | 逐项相等 | ✅ 0.3 s |
| 3 O1 | `testUI_switchMenuShowsHotkeysFromTable` | 菜单行 ["Cut \| 空格", "执行当前转场（Fade · 0.5 秒） \| 回车", ─, "# T-bar 和回车用（只选，不执行）", "Cut", "Fade", "Wipe", "Zoom", "Stinger", ─, "FTB \| F", "Overlay ▸"]，"快捷键… / MIDI 映射…"不在；当前类型 Fade 打勾；Overlay ▸ 四行"Overlay n（未指定，开 = 用 PVW）"；**菜单与子菜单所有项 keyEquivalent 为空**。改表（Cut 空格 → C，加 ⌥1 = Overlay 1 开关）→ 右列 Cut = "C"、执行当前转场仍"回车"、Overlay 1 = "⌥1"、Overlay 2 没有；`NSApp.mainMenu.performKeyEquivalent(C)` = false（菜单不认）；按一次 C → PGM 1 → 2，总线上这段时间的 cut **恰好 1 条、来源 hotkey**，派发器 handled +1，UI 发出的命令数不变（菜单那一路没发）。菜单自己点：选 Wipe → 类型 wipe、不执行（转场不在进行、PGM 不变）、勾跟着换、标题"执行当前转场（Wipe · 0.5 秒）"；执行当前转场 → 转场进行中、此时选类型那几项灰、做完 PGM = 原 PVW；FTB 开 → ✓、再点关 → 没勾；Overlay 1 空通道 → 用 PVW 那一路开、标题"Overlay 1 · 合成 2"、✓、再点关；拒收 0 | 逐项相等 | ✅ 1.7 s |
| 2 B1 / B3 | `testPanels_pvwGearOpensInputSettingsOfPreview` | 齿轮在 PVW 监视器标题条右端（左缘 > 宽 − 40）、不比标题条高（≤ 26）、辅助功能名"PVW 那一路的输入设置"；点 = 开 PVW 那一路（3）的输入设置窗、没开 PGM 那一路（1）；画面区（MetalDisplayView）自己不给菜单、监视器右键菜单 = ["输入设置…", "全屏输出到"]，"输入设置…" = 同一路；"全屏输出到 ▸"每块屏一项（这台机器 2 块）；换一块假显示器喂构造器：没有输出 → addOutput（外部显示、这块屏、来源 PVW），已经在出 PVW 的那块 → ✓、再点 = `setOutputEnabled(false)`（配置留着）；单击 / 双击画面不开任何窗；PVW 黑场 → 齿轮灰、右键"输入设置…"灰；拒收 0 | 逐项相等 | ✅ 0.7 s |
| 2 B2 / B4 | `testPanels_pgmGearOpensInputSettingsOfProgram` | PGM 齿轮辅助功能名"PGM 那一路的输入设置"，点 = 直接开 PGM 那一路（2）的输入设置（不弹菜单）、没开 PVW 那一路；叠加徽标：没开着的 → []；开通道 3（输入 1）与通道 1（输入 3）→ ["1 · 合成 3", "3 · 合成 1"]（按通道顺序、带输入名），PVW 不画；两枚徽标都在标题条里；关通道 1 → ["3 · 合成 1"]；FTB 开着角色那一格"PGM · FTB"；右键"输入设置…" = PGM 那一路；PGM 黑场 → 齿轮灰；拒收 0 | 逐项相等 | ✅ 0.6 s |
| 3 O4 | `testUI_inputSettingsMenuTitleNamesInput` | PVW = 2 时标题"输入 2「合成 2」设置…"、⇧⌘I 还在、可点、开的是 2 不是 1；改名后"输入 2「讲台机位」设置…"；PVW 黑场 → "输入设置…"、灰、点了什么都不开 | 逐字相等 | ✅ 0.5 s |
| 补 A2 / V-24 | `testUI_recentMenuDisambiguatesSameNamesAndOpensLastSession` | `recentTitles` = ["独一份.switcher.json", "节目.switcher.json — 周三", "节目.switcher.json — 周日"]，不重名只写文件名；菜单"打开最近"前三项同上、提示 = 完整路径、representedObject = URL；节目菜单 = [新建, 打开…, 打开最近 ▸, 打开上次退出时的节目, ─, 保存, 另存为…]；没有 LastSession → 灰；有（"上次那一场"、输入 4）→ 打开它：输入 [4]、节目名"上次那一场"、`currentURL` = nil、算未保存 | 逐项相等 | ✅ 0.6 s |
| 补 O2 / F3 | `testUI_appMenuSettingsRenamedAndHotkeysMoved` | App 菜单没有"偏好设置…"；"设置…"是 ⌘,，下面紧跟"快捷键… / MIDI 映射…"，各开各的窗；en"Settings…"；"没有快捷键"的提示里不再写"切换 ›" | 逐项相等 | ✅ 0.3 s |
| 补 O3 / Q33 | `testUI_helpMenuOffersManualAndHotkeyList` | 帮助菜单就是 `NSApp.helpMenu`，我们的项 selector 依次 [showManual:, showHotkeyList:, ─, exportDiagnostics:, showDiagnosticsFolder:]；Resources 里没有 Help/ → 手册灰、标题"PlusMix 使用手册（手册尚未随包）"；有 Help/zh-Hans/index.html → 可点、标题"PlusMix 使用手册"、打开的就是它；只有 Help/index.html → 用它。快捷键一览：临时目录里的 .html，`<title>PlusMix 快捷键一览</title>`，含 空格 / 回车 / ⇧1 / ⌥3 / 台标 / 叠加开关 / Cut，`<tr>` 数 = 表头 + 每条绑定一行，没有 `<script`，备注里的 `<b>&</b>` 转义 | 逐项相等 | ✅ 0.2 s |
| 补 A1 | `testUI_toolbarFitsMinimumWindow` | `contentMinSize` = 1100 × 668（= 没有工具条时 1100×700 窗口的内容区）；最小窗口外框 = `window.minSize` = 1100 × 720，比内容区高 52（工具条那一行）；最小窗口与 1440×900 下工具条十项都在（没有挤进溢出菜单）、外部显示▾ 在正中附近（1440 宽 ±4，1100 宽标题挤占左边、±60） | 逐项相等 | ✅ 0.6 s |

### 2.2 改到的旧用例（判据不动）

| 用例 | 改了什么 |
|---|---|
| `MainWindowLayoutTests.testUI_splitKeepsInputStripMinimum` | "缩到最小 1100×700"改成"缩到 `AppTest.minimumMainWindowSize`"（W5TestSupport 新加，= `window.minSize`）：工具条那一行算在外框里，最小窗口现在是 1100×720，内容区仍是原来 1100×700 时的 668；`setFrame` 不受 minSize 约束（探针），写死 700 会量到用户拖不到的尺寸。判据（输入条 ≥ 190、调音台 ≥ 340、上半区放得下转场列、放回 1440×900 输入条不变）不变。数值：1440×900 输入条 197 / 调音台 340 / 上半区 592；最小窗口 输入条 197 / 调音台 340 / 上半区 412 |
| `TransitionColumnTests.testUI_transitionColumnEdgesAligned` | 同上，"1100×700"改成最小窗口（只改尺寸来源与提示文字）；判据（T-bar ≥ 60、各行左右边对齐）不变。数值：最小窗口列高 412、T-bar 64 |
| `TransitionColumnTests` 一处注释 | "菜单 切换 › Fade"改成"菜单 切换 › 类型"（菜单里没有执行 Fade 的那一项了） |

### 2.3 红灯轮

`d3f84cd` 上只跑新用例：**10 条全红、53 处**，红的位置就是各自要验的点：主窗口没有工具条、toolbarStyle 不是 .unified、按钮字是"打开… / 另存为… / 偏好设置…"、输出菜单里没有外部显示全部开 / 关；齿轮不在监视器里、点了不开窗、没有右键菜单、没有徽标；"切换"仍是 [Cut, Fade, FTB, ─, 快捷键…, MIDI 映射…]；"输入设置…"不写是哪一路、PVW 空时仍可点并开了第一路；最近列表同名不分、没有"打开上次退出时的节目"；App 菜单"设置…"下面不是快捷键 / MIDI；帮助菜单只有诊断两项；工具条按钮 0 个。

### 2.4 全量（`make test-app XCB_FLAGS=`，xcresulttool 核过）

| 轮次 | 结果 | 说明 |
|---|---|---|
| 第一遍（`f7c7981`） | 161 条：151 过、4 跳、**6 红** | ① `MainWindowLayoutTests.testUI_splitKeepsInputStripMinimum` 1440×900 输入条 189 < 190——**本会话引起的**：输入条初始高的公式暗含 32 pt 标题栏，工具条那一行是 52 pt，又被少减了分隔条厚度的最大坐标夹到 189；`d118cb3` 修（§1 最后一行），单跑这一类、转场列一类全过。② 五条显示类（下一行）——环境 |
| 第二遍（`d118cb3`） | 161 条：152 过、4 跳、**5 红** | 五条显示类全是"0 帧"：`DisplayDecouplingAppTests.testDisplay_dragFullscreenAndScreenMoveDoNotIncreaseMissedRender`、`ExternalOutputAppTests.testExternal_windowOnDisplay_followsProgram_…`、`ExternalOutputAppTests.testMultiview_windowTogglesPresentsAndSavesFrame`、`ThumbnailRateTests` 两条。**原因：屏幕锁着**（`ioreg` 里 `CGSSessionScreenIsLocked = true`，显示链路不出帧，App 也叫不到前台）。**对照：把基线 `70d0cf3`（92 报告里这五条全绿的那个提交）git archive 到草稿区单独编、同一时刻跑这五条，红得一模一样**（同样的 0 帧、同样的 9 处断言），所以不是本会话的改动 |
| 第三遍（`9d1a4cf`，最终） | **161 条：152 过、4 跳、5 红**（xcresulttool：result Failed / totalTestCount 161 / passed 152 / failed 5 / skipped 4，299 s） | 红的仍是这五条显示类、屏幕仍锁着；本会话的 10 条、改过的两条老用例、ISO A4（三路同拍）、推流到本机 MediaMTX 10 s、录制"起止拍差 = 按钮间隔 ± 1 帧"都过 |

跳过的 4 条：内置摄像头 BLOCKED-权限、虚拟摄像头出画 BLOCKED-签名、键盘导航 BLOCKED-系统设置（92 留下的那条，系统设置归用户）——这三条与 92 相同；第四条 `DisplayLedgerAppTests.testDisplayStats_monitorAndMultiviewWindowDroppedFromLedger` 是屏幕锁着时它自己跳过（窗口没上屏）。release frameprobe 先编好了，ISO A4 / 推流端到端 / 录制"按钮间隔 ± 1 帧"都是真跑的、都过。

**还欠的**：那五条显示类要在屏幕解锁、主窗口没被盖住的时候再跑一次（解锁后单跑约 40 s）：

```bash
xcodebuild -project Switcher.xcodeproj -scheme Switcher -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test-without-building -only-testing:SwitcherTests/DisplayDecouplingAppTests -only-testing:SwitcherTests/ExternalOutputAppTests -only-testing:SwitcherTests/ThumbnailRateTests -only-testing:SwitcherTests/DisplayLedgerAppTests
```

## 3. 没做的和原因

1. **"全量 0 失败"这一条没达成**：五条显示类在屏幕锁着时没法出帧（§2.4，基线同样红），要解锁后补跑；其余 156 条全过或按原因跳过。
2. **prompt 写明不做的**：录制 / 推流时长（101，工具条状态只写状态）、设置窗合并（96：设置▾ 现在列的是几扇窗与输出设置的页，快捷键… / MIDI 映射… 先挂在 App 菜单"设置…"下面，96 合窗后改指设置窗的页）、随包手册文件（103：菜单项与打开逻辑在，找不到就灰着写"手册尚未随包"）、契约。
3. **最小窗口从 1100×700 变成 1100×720（外框）**：`.unified` 工具条那一行在 macOS 27 上 52 pt，没有工具条时标题栏 32 pt（探针：none 32 / unified 52 / unifiedCompact 40 / expanded 68）。1100×700 外框下内容区只剩 648，而转场列最小 408 + 分隔条 1 + 输入条 190 + 底栏 58 = 657，放不下（输入条或 T-bar 会被压）。按 prompt 用了 `.unified`，所以把最小窗口定成"内容区仍是 668"——**这是一处用户能感觉到的变化，请你定**：要保住 1100×700 的外框，可以换 `.unifiedCompact`（40 pt，内容区 660 ≥ 657，一行代码，工具条按钮会小一号），代价是和 Q28 写的 `.unified` 不一致。
4. **"切换"里的五种类型是"选 T-bar 和回车用哪种（不执行）"，不是"点了就做这种转场"**：prompt 只写"五种类型（槽落地前列类型，100 改成槽）"。两种都说得通，选前者的理由：五种里有 Cut，若"点了就执行"，菜单里就有两个一模一样的 Cut；"执行当前转场"要有一个改"当前"的地方（转场列里是 T-bar 上方那行的菜单，口径相同，用户 2026-10-03 定那里列 Cut）；菜单栏也因此有了 C3 说的"只选不执行"入口。代价：菜单栏里"做一次 Wipe"要两步（选 Wipe → 执行当前转场；快捷键 / 转场列按钮仍是一步）。100 把这一段换成"转场 1–4"时，若定成"点了执行这个槽"，改 `SwitchMenuController` 里这五项的 action 即可。
5. **外部显示全部开 / 关没给快捷键**（01a M1 的备注提过 ⌥⌘F）：prompt 没要，Q29 的默认表也没列，没加。
6. **工具条"打开▾"的"打包另存"、"上次"按钮**：A2 写明打包另存做出来前不放、"上次"并进打开▾，照做。
7. **窄窗口时标题被截**：1100 宽时窗口标题显示成"PlusMix 0.1.0 —…"（工具条项把标题区挤窄了），1440 宽完整。节目名还在 Dock / 窗口菜单 / 关闭按钮的未保存点上，没有另外处理。

## 4. 对契约的疑问

没有改契约，也没有要停下来的提案：工具条与菜单栏的动作全是现成命令（cut / autoTransition / setTransition / ftb / overlay / setOutputEnabled / setOutputSettings / addOutput / renameOutput）与现成的面板入口。一点给后面参考：工具条右组的录制 / 推流状态与底栏主体同一份汇总（`OutputButtonSummary`，读 Stats.encoder + 运行表），时长按铁律 4 仍应进 Stats（022 的 uptime），不要在工具条上按起始拍自己推算。

## 5. 下一个会话需要知道的坑

1. **工具条那一行算在窗口外框里**：`.unified` 在 macOS 27 上 52 pt（没有工具条 32 pt）。主窗口现在用 `contentMinSize`（= 没有工具条时 1100×700 的内容区 668）定最小尺寸，外框最小 1100×720。**`NSWindow.setFrame` 不受 minSize / contentMinSize 约束**（探针：设了 724 的 minSize 再 setFrame 700，窗口照样是 700），所以测"最小窗口时布局还在"的用例要用 `AppTest.minimumMainWindowSize`，别再写死 700。工具条要在 `placeWindow`（按存档摆）**之前**挂上：反过来挂，系统保内容区、外框长高 20，每次启动都高一截。凡是按"窗口外框高"推算内容区的地方都会偏 20 pt（输入条初始高就是这么红的，§2.4）。
2. **菜单项设了 attributedTitle 之后 `item.title` 也变成"标题\t键"**（探针）：按标题找项一律用 `MenuKeyColumn.title(of:)`；改 `MenuKeyColumn.apply` 时同一个菜单的项要一起设（右对齐制表位按整个菜单最长的标题与键算）。"切换"菜单的 delegate 是 `SwitchMenuController`（不是 AppDelegate），`menuHasKeyEquivalent` 一律 false；别给这几项加 keyEquivalent。
3. **工具条按钮是系统的玻璃外框**：`bezelColor` 不画；窗口不在前台时系统把按钮里的字和图标都压暗（图标会被压成灰的），只有带颜色的 attributedTitle 保得住（截图核对）。所以工具条"外部显示"开着用强调色的字（`SplitBarButton.setIndicator`），没用底栏那种填色。顺带看到：**底栏的 bezelColor 高亮（录制红、外部显示蓝）在窗口不在前台时也不画**，只剩"● 录制中"这类字还在——92 的设计，本会话没动，94 / 97 动底栏时可以考虑。
4. **sheet 挂在主窗口上时系统把整条工具条置灰**，`performClick` 点上去什么都不做（用例里点"保存"之前要等确认框收起：`window.attachedSheet == nil`）。
5. **工具条 / 菜单栏的动作都是 nil target 的 AppDelegate selector**（`AppDelegate` 里这些方法都改成 internal、带 sender），工具条按钮挂同一个 selector 就和菜单项"同一个动作"。**别用系统标准动作的名字**（`cut:` / `copy:` / `showHelp:` 之类）：nil target 的动作先走响应链，文本框有焦点时会被它接走——"切换 › Cut"的动作叫 `transitionCut:` 就是这个原因。工具条项 `autovalidates = false`，灰不灰由 `MainToolbar.setSessionAvailable` 管。
6. **测试宿主叫不到前台、也截不了自己的窗**：屏幕没锁时 `NSApp.activate` 也抢不过当前前台的 App（协作式激活），屏幕锁着时更不行；测试宿主没有屏幕录制权限，从它里面调 `screencapture` 什么都不写。要看主窗口长什么样：让用例把窗口号写进一个文件、停几秒，从 shell 里 `screencapture -x -o -l<窗口号>`（本会话这么截的，截到的是"不在前台"的样子）。
7. **屏幕锁着时显示类用例全是 0 帧**（`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`），`DisplayLedgerAppTests` 那条会自己跳过。跑全量前先看一眼；红了先拿基线同一时刻对照（本会话把 `70d0cf3` git archive 到草稿区单独编，`make gen` + `build-for-testing` 约 4 分钟）。
8. **测试宿主的"最近打开"列表跨用例、跨 worktree 共用**（UserDefaults suite `com.plusmix.switcher.tests`）：同名文件会让标题带上目录名，断言最近列表标题的用例开头先 `controller.documents.clearRecents()`。
9. **启动时就有 5 条约束冲突**（`InputStripView.height == 0` 的自动尺寸约束 vs `≥ 190`，分隔视图还没排的时候）：基线 `70d0cf3` 一模一样，不是本会话引起的，没动；属于输入条（94）的地盘，顺手可以修。
10. **随包手册的约定（给 103 / G7）**：App 找 `Contents/Resources/Help/<lproj 名>/index.html`（`zh-Hans`、`en`），没有就 `Help/index.html`。**XcodeGen 会把 `App/Resources/Help/` 下的文件当普通资源一个个加进 Copy Bundle Resources**（探针：在草稿区的副本里放 Help/zh-Hans/index.html 与 Help/en/index.html 再 `xcodegen generate`，pbxproj 里是两条"index.html in Resources"），拷进包时目录层级没了、两个 index.html 撞名（撞名的报错没编出来验证）。所以 `App/Resources/Help/` 要在 project.yml 里另写成 folder reference（`type: folder`）。project.yml 不在本会话目录，103 的"只准动"里也没有它（有 App/Resources/Help/）——要 G7 或认领 project.yml 的会话加那一行。
11. **手册要跟着改（不在本会话目录，给 103 / G7）**：docs/user/快捷键.md:21、:49 与 en/shortcuts.md:22、:52（"切换 › 快捷键… / MIDI 映射…"→"PlusMix › 快捷键… / MIDI 映射…"，菜单"切换"现在的样子）、:17（菜单快捷键里的"⌘, 偏好设置"→"设置"）；docs/user 里另有 10 个文件写"偏好设置 / Preferences"（如 概念.md:72、故障排查.md:79、en/concepts.md:77、en/README.md:40、en/shortcuts.md:84），设置窗现在叫"设置"；工具条一节（按钮、打开▾ / 设置▾ / ? 的内容、外部显示主体）、监视器齿轮与右键、帮助菜单的两项、"打开上次退出时的节目"、"输入 N「名字」设置…"、输出菜单的"录制 ▸ / 全部外部显示开关"都没写进手册。
12. **两份 Localizable.strings 又动了**（§1 末尾）：94–98 也改这两个文件，G7 合并时按键解冲突；`menu.preferences` / `menu.transition.hotkeys` / `menu.transition.midi` 三个键已删（改名），别的分支若还引用会在 `testL10n_everyKeyUsedInSourcesExists` 红。
