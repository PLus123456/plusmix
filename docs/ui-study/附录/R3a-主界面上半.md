> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# R3a 主界面上半：顶部工具条、PVW / PGM 标题条、转场列与 ▾ 菜单（图 001、060–068）

读图：001、060、061、062、063、064、065、066、067、068 全部读过（菜单部分用 sips 裁切放大逐项核对）。另为佐证瞄了他区的 002、069、084、141、142，只在括号里引用，不替他区下结论。
界面稿：docs/spec/ui-mock/vMix for Mac.dc.html（下称"界面稿"）的工具条 L67-100、标题栏 L53-65、PVW 标题条 L106-117、转场列 L126-195、PGM 标题条 L198-206、脚本 L466-615。

---

## A. 参考软件：入口与菜单逻辑

### A1 窗口顶部工具条（图 001；各 ▾ 见图 060–063；"Settings" ▾ 的 16 项见图 002，属全局设置区）
标题栏下面一整行，分三组：
- **左组（节目文件）**："Preset" 是纯标签（没有按钮边框，不能点），后面跟 "New" / "Open"▾ / "Save" / "Save As"▾ / "Last"（图 001）。
  - "Open" 是分体按钮。主体截图没演示（推测：弹"打开文件"对话框）。右侧小箭头弹下拉（图 060）：最近文件（只显示文件名，"毕业典礼.vmixZip"、"last.vmix"），分隔线，"Clear"。没有勾选项，也没有灰项。
  - "Save As" 是分体按钮。主体截图没演示（推测：另存为对话框）。小箭头弹下拉，只有一项 "Save As Bundle"（图 061）。推测是把节目和素材打成一个包，最近列表里那个 .vmixZip 就是这种格式（图 060）。
  - "New"、"Save"、"Last" 都是单按钮，截图没演示。推测 "Last" = 打开上次会话，也就是最近列表里的 "last.vmix"（图 060）。
- **中间**："Fullscreen"▾ 分体按钮（图 001）。
  - 小箭头弹下拉，每块显示器一项；本机只有 "Display 1 ▸"（图 062）。子菜单是单选（图 063）："Output"（✓，默认）/ "Preview" / "MultiView" / "MultiView2" / "Replay" / "Mix1" / "Input1" / "Input2"（输入按编号逐个列），中间没有分隔线。
  - 主体截图没演示（推测：在设定的显示器上开 / 关全屏输出）。图 063 截图时全屏并没有开，"Output" 却已经打勾（推测：这个勾表示"这块屏全屏时显示什么"的配置，不表示"正在输出"）。
- **右组**："Pause Inputs" / "Basic" / "Settings"▾ / "?"（图 001）。"Settings" 小箭头弹 16 个设置页（图 002：…"Shortcuts"、"Activators"…"About"）。另外三个截图都没演示（推测依次是：暂停全部输入 / 精简界面 / 帮助）。
- 状态反馈：工具条按钮平时没有状态色（图 001）。"Save As"、"Pause Inputs" 字重偏粗，见 F 节。

### A2 监视器标题条（图 001、068）
- **左 PVW**（橙底）：左端是编号块 "2"，后面是名字 "Blank"；右端三个图标，依次是 RGB 竖条、套叠矩形、齿轮（图 001）。
  - 前两个图标截图没演示（推测：色彩 / 安全框这类显示辅助）。
  - 齿轮按索引描述是直接打开 PVW 那一路的输入设置窗（图 069 的索引，属输入属性区）。
- **右 PGM**（绿底）："1 Blank"，右端只有一个齿轮（图 001）。
  - 齿轮弹下拉（图 068）："Input Settings"（粗体，即默认项），分隔线，"Output"（✓）。
  - 推测："Input Settings" = 打开 PGM 那一路的输入设置；"Output" 是右监视器显示哪路混合的单选，只有一路混合时就只有这一项。
- 单击 / 双击 / 右键监视器画面：截图没演示。

### A3 转场列（图 001，从上到下）
1. **"Quick Play"**：单按钮，字重加粗。截图没演示。推测 = 把 PVW 那一路（视频就从头播放）用默认转场切上 PGM。旁证：输入设置里有 "Automatically Play with Transition"（图 069，属他区）。
2. **"Cut"**：单按钮。
3. **"Fade"▾ / "Merge"▾ / "Wipe"▾ / "Fly"▾**：四个分体转场按钮，按钮上的字 = 当前效果名。
   - 主体单击推测 = 用本按钮的效果和时长执行转场（没演示）。
   - 小箭头弹下拉（图 064–067，见 A4）。
4. **"FTB"**：单按钮，没有 ▾。
5. **"1" "2" "3" "4"**：一排小方块，是叠加通道。推测：把 PVW 那一路叠到第 n 路，已经开着就关。
6. **T-bar**：横向。灰色竖把手停在左端，左端有一小段蓝色填充，轨道白色描边（图 001）。
7. **时钟**：白框黑底。上行 24 小时制带秒 "19:03:45"，下行 12 小时制不带秒 "07:03 下午"（图 001）。

### A4 转场按钮的 ▾ 菜单（图 064 Fade、065 Merge、066 Wipe、067 Fly）
四个菜单的项目完全一样，只有时长数值不同。
- **效果单选列表**，共 22 项，没有图标、没有子菜单、中间不分隔：
  "Fade"、"Zoom"、"Wipe"、"Slide"、"Fly"、"CrossZoom"、"FlyRotate"、"Cube"、"CubeZoom"、"VerticalWipe"、"VerticalSlide"、"Merge"、"WipeReverse"、"SlideReverse"、"VerticalWipeReverse"、"VerticalSlideReverse"、"BarnDoor"、"RollerDoor"、"Stinger 1"、"Stinger 2"、"Stinger 3"、"Stinger 4"。
- 分隔线。
- **"Duration Milliseconds"**：粗体小标题，不能点。
- **数值**：Fade 是 "500"（图 064）；Merge / Wipe / Fly 都是 "1000"（图 065–067）。推测是能直接键入毫秒数的无边框输入框。
- **勾选态**：当前效果在列表里不打勾。放大看左侧勾选栏是空的（图 064），当前效果只靠按钮上的字表达。
- **出厂默认**：Fade 500 / Merge 1000 / Wipe 1000 / Fly 1000（图 001、064–067）。
- 旁证（属他区）：
  - Stinger 1–4 在叠加设置里按编号配置（图 142：Number 下拉 1–4 加 "Stinger 1–4"，另有 "Stinger Input"、"Stinger Cut Point"）。
  - 快捷键函数表里有 "SetTransitionEffect1–4"、"SetTransitionDuration1–4"、"QuickPlay"、"FadeToBlack"、"SetFader"、"CutDirect"（图 084）。可见四个按钮的效果和时长都能被快捷键或外部控制单独改、单独触发。

---

## B. 我们现在的实现

### B1 窗口顶部：没有工具条，对应项都在菜单栏
- **主窗口没有工具条**。窗口只有标题栏（styleMask = titled / closable / miniaturizable / resizable），内容区顶上直接是分栏视图（App/Sources/UI/MainWindowController.swift:68-76、127-133）。
  - 标题平时是 "PlusMix 0.1.0 — 节目名"（App/Sources/UI/MainWindowController.swift:71、185）。
  - 保存 / 另存之后标题被改成代码名 "Switcher 0.1.0 — 节目名"（App/Sources/AppController.swift:264）。
  - 主窗口可以进 macOS 全屏（绿灯，App/Sources/UI/MainWindowController.swift:74）。这是主窗口本身全屏，不是节目输出全屏。
- **节目文件：菜单栏"节目"**（App/Sources/AppDelegate.swift:78-88）。依次是：新建 ⌘N、打开… ⌘O、打开最近 ▸、分隔线、保存 ⌘S、另存为… ⇧⌘S。
  - "打开最近"（App/Sources/AppDelegate.swift:170-185）：列文件名，悬停显示全路径；分隔线后是"清除列表"。没有记录时只有一项灰的"（无）"。最多 10 条（App/Sources/Show/ShowDocuments.swift:12、80-92）。
  - 新建 / 打开：直接换 session，不问要不要保存，也不看是否在录制 / 推流。旧 session 连输出一起停掉（App/Sources/AppController.swift:121-151、203-229）。
  - 保存：已有文件就写回，否则走另存为（App/Sources/AppController.swift:232-239）。另存为用 NSSavePanel，扩展名 .switcher.json（App/Sources/AppController.swift:241-252；App/Sources/Show/ShowDocuments.swift:11）。
  - "上次"：没有手动入口。启动时先恢复上次打开的文件，没有就恢复退出时自动存的 LastSession（App/Sources/AppController.swift:92-117；App/Sources/Show/ShowDocuments.swift:95-111）。
  - 打包另存：没有。
- **"Fullscreen▾" 的对应物**：底栏"外部输出"按钮（App/Sources/UI/BottomBarView.swift:43、55-56、227），以及菜单"输出 › 外部输出 ▸"（App/Sources/AppDelegate.swift:125-128、260-268）。两处用同一个 ExternalOutputMenuBuilder（App/Sources/UI/ExternalOutputMenu.swift:47-91）。
  - 每块显示器一项"名字（宽×高 Hz[，主屏]）▸"。子菜单依次是：PGM / PVW / 多画面 / 分隔线 / 小标题"Aux = 原始画面（抠像 / 裁切 / 变换不生效）"/ 各路"输入 n 名字"（App/Sources/UI/ExternalOutputMenu.swift:55-73）。
  - 勾 = 已有这块屏配这个源的外部显示输出。点一下 = 没有就加上（开），有就删掉（关）（App/Sources/UI/ExternalOutputMenu.swift:104-111）。
  - 同一块屏可以同时勾好几个源，每个源各开一个全屏窗口，叠在一起（管理器按一个输出一个窗口，Packages/SwitcherOutputs/Sources/External/ExternalDisplayManager.swift:6、73-84）。
  - 子菜单下面还有"关闭 n 名字（状态）"和"关闭全部外部输出"（App/Sources/UI/ExternalOutputMenu.swift:75-89）。
  - 没有"一键开 / 关"的主体按钮，也没有"默认全屏显示器"。
- **"Pause Inputs"、"Basic"**：没有。
- **"Settings" 的对应物，散在四处**：
  - App 菜单"偏好设置… ⌘,"（App/Sources/AppDelegate.swift:71），一个窗口九段：节目格式 / 本地 API / 音频输出 / 节目音频 / PVW 预览 / 外部输出 / 兼容层 / 语言 / 更新（App/Sources/Settings/PreferencesPanel.swift:173-229）；
  - "输出"菜单七个设置页（App/Sources/AppDelegate.swift:118-123）；
  - "切换"菜单的"快捷键…"、"MIDI 映射…"（App/Sources/AppDelegate.swift:110-111）；
  - "输入"菜单的"输入设置… ⇧⌘I"（App/Sources/AppDelegate.swift:102）。
- **"?" 的对应物**：帮助菜单只有"导出诊断包…"、"打开诊断文件夹"两项（App/Sources/AppDelegate.swift:154-158），没有手册入口。

### B2 监视器标题条（App/Sources/UI/MonitorView.swift）
- **内容**：标题条高 26（App/Sources/UI/Theme.swift:24）。左边是编号和名字，右端是角色字 "PVW" / "PGM"；FTB 开着时显示 "PGM · FTB"；黑场时编号显示"—"、名字显示"黑场"（App/Sources/UI/MonitorView.swift:10-13、21-22、53-67）。
- **底色**：PVW 绿、PGM 红（App/Sources/UI/Theme.swift:13-16，落地方案 §1.3 第 3 条定的广播惯例）。
- **交互**：没有图标、没有齿轮、没有右键菜单。MonitorView 和 MetalDisplayView 都不处理鼠标，单击 / 双击 / 右键监视器都没有反应（App/Sources/UI/MonitorView.swift 全文；Packages/SwitcherCore/Sources/SwitcherRender/Display/MetalDisplayView.swift 里没有 mouse / menu 处理）。
- **等价入口在别处**：
  - PVW 那一路的设置：菜单"输入 › 输入设置… ⇧⌘I"；PVW 为空时打开第一路（App/Sources/AppDelegate.swift:197-203）。
  - PGM 那一路的设置：只能在缩略图格子上右键 › "设置…"（App/Sources/UI/InputCellView.swift:184-190）。
- **显示源**：PGM 监视器固定显示 PGM（App/Sources/UI/MonitorView.swift:19）。

### B3 转场列（App/Sources/UI/TransitionPanelView.swift，列宽 150，App/Sources/UI/Theme.swift:27）
- **从上到下**（App/Sources/UI/TransitionPanelView.swift:95-96）：Cut、Fade、Wipe、Zoom、Stinger、FTB、时长分段"0.5s｜1s｜2s"、小标题"Overlay"、1 2 3 4、一行"T-bar：<类型>  [参数…]"、竖 T-bar、时钟。
- **触发方式**：全部是左键单击；没有 ▾，没有右键菜单，没有双击。

| 控件 | 发什么（位置） | 说明 |
|---|---|---|
| Cut | `cut`（App/Sources/UI/TransitionPanelView.swift:151） | |
| Fade | `fade(durationTicks: 当前时长)`（App/Sources/UI/TransitionPanelView.swift:153） | reducer 会顺手把"下一次转场"的类型改成 fade，再开始转场（Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:81-85） |
| Wipe / Zoom / Stinger | `setTransition(类型, 当前时长)` + `autoTransition`，两条命令（App/Sources/UI/TransitionPanelView.swift:156-160） | |
| FTB | `ftb(on: !当前)`（App/Sources/UI/TransitionPanelView.swift:162） | |
| 时长分段 | `setTransition(当前类型, 秒 × 标称帧率)`（App/Sources/UI/TransitionPanelView.swift:164-168） | 改的是唯一的 durationTicks，五种转场共用 |
| 参数… | 向右弹出层：Wipe 方向五向、软边 0–0.3；Stinger 输入、换底拍。发 `setTransitionParams`，转场进行中先挂起不发（App/Sources/UI/TransitionPanelView.swift:180-192；App/Sources/UI/TransitionParams.swift:10-63、66-96） | |
| Overlay 1–4 | `overlay(ch, on: !on, input: nil)`（App/Sources/UI/TransitionPanelView.swift:194-198） | 只开关，不换输入。给通道选输入要到缩略图格子上的 1–4 小按钮（App/Sources/UI/InputCellView.swift:225-233）或底栏"叠加…" |

- **状态反馈**：
  - Fade / Wipe / Zoom / Stinger 只在"这个类型正在转场"时变蓝（App/Sources/UI/TransitionPanelView.swift:123-126）。平时看不出选中的是哪种，只能看 T-bar 上方那行"T-bar：Wipe"（App/Sources/UI/TransitionPanelView.swift:139）。
  - FTB 开着时变暗红（App/Sources/UI/TransitionPanelView.swift:122）。
  - 时长和三档预设都对不上时（比如节目文件里写的是 45 拍），分段控件一段都不选，也不显示实际值（App/Sources/UI/TransitionPanelView.swift:127-132）。
  - Overlay 开着时变蓝；悬停提示通道用的是哪一路，或"还没指定输入"（App/Sources/UI/TransitionPanelView.swift:133-137）。
- **提示文字是写死的**：Cut "空格"、Fade "回车"、FTB "F"（App/Sources/UI/TransitionPanelView.swift:77-79）。可默认表里回车绑的是 `autoTransition`（按当前选中的类型走），不是 Fade（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift:66-68）。用户改了快捷键表，提示也不会跟着变。
- **契约**：
  - 只有一组"下一次转场"：`TransitionState.type / durationTicks / wipe / stinger`（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:47-79）。
  - `TransitionType` = cut / fade / wipe / zoom / stinger（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:5-8）。
  - 这一组随节目文件保存（Packages/SwitcherCore/Sources/SwitcherContracts/Show.swift:3-31 的 MixerSettings.transition）。

### B4 T-bar（App/Sources/UI/TBarView.swift）
- **方向与外形**：竖向，0 在底、1 在顶（App/Sources/UI/TBarView.swift:1-2、41-55）；五条刻度，把手占满列宽（App/Sources/UI/TBarView.swift:46-50、59-80）。高度至少 120，纵向可以伸缩（App/Sources/UI/TransitionPanelView.swift:109、112）。
- **拖动**：拖动中最多发到 0.999。松手时 ≥ 0.97 就发 1（= 提交），然后 150 ms 回弹到底；没到顶就停在原位（App/Sources/UI/TBarView.swift:18、108-147）。点轨道任意位置，把手直接跳过去（App/Sources/UI/TBarView.swift:84-96）。不拖的时候跟着快照走（App/Sources/UI/TBarView.swift:34-37）。这套行为和界面稿一样：稿子松手时 > 0.97 就提交并归零（界面稿 L471-473、505-509）。
- **推哪种转场**：推状态里的 `transition.type`，也就是最近一次点过的转场或最近一次 setTransition 选的类型（用户手册同口径：docs/user/概念.md:60-61）。
- **MIDI 推子手感不同**：推到一端就提交并换向，不回弹（Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIMapper.swift:60-75）。

### B5 时钟（App/Sources/UI/ClockView.swift）
- 内容：上行 24 小时制 "HH:mm:ss"，22 pt 白字；下行 12 小时制 "hh:mm a"，12 pt 灰字，按系统区域显示上午 / 下午或 AM / PM（App/Sources/UI/ClockView.swift:6-7、9-18）。
- 外观：黑底、2 px 白边（App/Sources/UI/ClockView.swift:24-26）；按整秒对齐刷新（App/Sources/UI/ClockView.swift:45-60）；定高 64（App/Sources/UI/TransitionPanelView.swift:110）。
- 没有交互。和参考的内容、外观一致（图 001）。

### B6 菜单栏"切换"（App/Sources/AppDelegate.swift:105-112、204-214）
- 菜单项："Cut"、"Fade"、"FTB"（三项都不显示快捷键），分隔线，"快捷键…"、"MIDI 映射…"。
- "Fade" 发 `fade(当前时长)`，同样会把 T-bar 推的类型改成 Fade。
- 没有 Wipe / Zoom / Stinger 项，也没有"按当前转场执行"。

### B7 快捷键 / MIDI / API 能怎么触发转场
- **默认快捷键表**（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift:56-70）：数字 → PVW；Shift+数字 → PGM；空格 → Cut；回车 → `autoTransition`；F → FTB 开关。
- **一键只能做一件事**：一个键或一个 MIDI 音符只能绑一个 ControlAction（一条命令或一个开关，Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/ControlAction.swift:7-15）。快捷键编辑器里和转场有关的动作只有 Cut / 按已选转场 / Fade(拍数)（App/Sources/Settings/HotkeyEditorPanel.swift:11-12）。一键 Wipe / Zoom / Stinger 要两条命令，所以做不到。
- **兼容层（VMixCompat）**：只把 "Transition1 / SetTransitionEffect1 / SetTransitionDuration1" 接到这唯一一组上。"Transition2–4"、"SetTransitionEffect2–4"、"SetTransitionDuration2–4"、"QuickPlay" 和 Merge 等效果名都返回未实现（Packages/SwitcherControl/Sources/VMixCompat/FunctionCatalog.swift:21-28、84-98）。

---

## C. 菜单逻辑差异与改法

| 编号 | 参考行为（图号） | 我们现状（文件:行号） | 差异类型 | 建议改法（我们自己的说法） | 要改契约？ | 工作量 S/M/L | 优先级 P0/P1/P2 | 归属目录 |
|---|---|---|---|---|---|---|---|---|
| R3a-M01 | 窗口里有一条顶部工具条，节目文件 / 全屏 / 设置 / 帮助都摆在操作员眼前（图 001；界面稿 L67-100 同样有） | 主窗口没有工具条，这些都在菜单栏（App/Sources/UI/MainWindowController.swift:68-76、127-133；App/Sources/AppDelegate.swift:78-88） | 缺入口 | 加 NSToolbar（见附 1）：左组 新建 / 打开▾ / 保存 / 另存为▾；居中 全屏输出▾；右组 设置▾ / 帮助。菜单栏原有项全部保留 | 否 | M | P1 | App/Sources/UI/MainWindowController.swift（新增工具条文件） |
| R3a-M02 | 四个转场按钮各自带"效果 + 时长"，按钮上的字 = 当前效果；出厂 Fade 500 / Merge 1000 / Wipe 1000 / Fly 1000（图 001、064–067） | 固定 Fade / Wipe / Zoom / Stinger 四个类型按钮，外加 Cut、FTB；按钮就是类型，换不了（App/Sources/UI/TransitionPanelView.swift:15-20、38-43、95-96） | 同名不同义 | 改成"转场 1–4"四个可配置槽，外加固定的 Cut、FTB。每个槽存：效果、时长、Wipe 参数、Stinger 参数。出厂 1 = Fade 0.5 秒、2 = Wipe 1 秒、3 = Zoom 1 秒、4 = Stinger 1 秒，和今天四个按钮等价，老用户不受影响（附 2） | 是：提案，TransitionState 加 4 个槽和两条命令（附 3）；不批就走附 3 的过渡做法 | L | P0 | App/Sources/UI/TransitionPanelView.swift；Packages/SwitcherCore/Sources/SwitcherContracts/（提案）；Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift |
| R3a-M03 | 每个转场按钮右侧有 ▾：点 ▾ 弹出该按钮的效果单选和时长输入，点主体执行（图 064–067） | 没有 ▾，也没有右键菜单。想换类型只能点另一个按钮，而一点就执行；参数藏在 T-bar 旁的"参数…"弹出层里（App/Sources/UI/TransitionPanelView.swift:90-94、180-192） | 缺入口 | 每个槽做成"主体 + ▾"两段；点 ▾ 和右键主体弹同一个菜单：效果单选（✓ 当前）/ 时长 / 参数…（菜单树见附 2）。在菜单里改只改配置，不执行 | 同 M02 | M | P0 | App/Sources/UI/TransitionPanelView.swift、App/Sources/UI/TransitionParams.swift |
| R3a-M04 | 时长按按钮分开存（Fade 500，其余 1000），在菜单里键入毫秒（图 064–067） | 只有一个共用时长，三档分段控件；改它等于改所有类型（App/Sources/UI/TransitionPanelView.swift:33、164-168；Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:58） | 默认值不同 | 时长放进槽里：▾ 里 0.5 / 1 / 2 秒单选 +"自定义…"（小弹出层，输秒或帧，按标称帧率换成拍）。当前值不在预设里时显示"✓ 自定义：0.75 秒"。列里的分段控件要么改成"当前槽的时长"，要么删掉（E4） | 同 M02 | S（在 M02 之上） | P0 | App/Sources/UI/TransitionPanelView.swift |
| R3a-M05 | 效果列表平铺 22 项，反向 / 竖向变体和 Stinger 1–4 都各占一项（图 064） | 类型只有 fade / wipe / zoom / stinger（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:6-8）；Wipe 方向藏在"参数…"里（App/Sources/UI/TransitionParams.swift:20、71-78） | 层级不同 | ▾ 效果列表只列我们有的：Fade、Zoom，Wipe 的五个方向平铺成五项（左→右 / 右→左 / 上→下 / 下→上 / 对角，一次点选），Stinger 显示所选输入名或"未设"。参考有、我们没有的效果不占位，列进 D 节 | 否（方向已在契约里） | S | P1 | App/Sources/UI/TransitionPanelView.swift |
| R3a-M06 | 截图看不出 T-bar 用哪个按钮的效果（推测：固定用第 1 个转场按钮） | T-bar 推"当前选中的类型"，也就是最近一次点过的转场；按钮上不标，只在 T-bar 上方写一行字（App/Sources/UI/TransitionPanelView.swift:139；docs/user/概念.md:61） | 状态反馈不同 | 保留"跟当前槽走"：当前槽 = 最近执行过的槽，或在 ▾ 里点"用于 T-bar（不执行）"选中的槽。在这个槽的按钮上加常亮标记，T-bar 上方写"T-bar：转场 2 · Wipe 1 秒"。三种口径见 E3 | 同 M02（契约里记"当前那组来自哪个槽"） | S | P1 | App/Sources/UI/TransitionPanelView.swift、App/Sources/UI/TBarView.swift |
| R3a-M07 | 四个转场按钮的效果、时长、执行都能被快捷键或外部控制单独调用（图 084 的 "SetTransitionEffect1–4"、"SetTransitionDuration1–4"，属他区） | 一个键只能发一条命令，Wipe / Zoom / Stinger 要两条，所以快捷键 / MIDI 做不到一键；编辑器里只有 Cut / 按已选转场 / Fade(拍)（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/ControlAction.swift:7-15；App/Sources/Settings/HotkeyEditorPanel.swift:11-12）；兼容层 Transition2–4 未实现（Packages/SwitcherControl/Sources/VMixCompat/FunctionCatalog.swift:93-98） | 缺入口 | 随槽提案加两类动作："执行转场 n"、"选中转场 n（不执行）"。快捷键编辑器、MIDI 音符、API、Stream Deck，以及兼容层的 Transition1–4 / SetTransitionEffect1–4 / SetTransitionDuration1–4 都接上。默认表建议 ⌥1–⌥4 = 执行转场 1–4（我们自己的表）；回车仍然是"执行当前槽" | 是（同 M02 的提案） | M | P1 | Packages/SwitcherControl/Sources/SwitcherControl/（Hotkeys、MIDI、CommandBus）、Packages/SwitcherControl/Sources/VMixCompat/；App/Sources/Settings/HotkeyEditorPanel.swift |
| R3a-M08 | —（参考没有提示文字可比） | Fade 按钮提示写"回车"，但回车绑的是"按当前选中的转场"：选过 Wipe 之后按回车走的是 Wipe。提示是写死的，改了快捷键表也不变（App/Sources/UI/TransitionPanelView.swift:77-79；Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift:66-68） | 状态反馈不同 | 提示文字按当前快捷键表反查生成，没绑键就不写；Fade 上的"回车"去掉，"回车"写到当前槽的提示上 | 否 | S | P1 | App/Sources/UI/TransitionPanelView.swift |
| R3a-M09 | 点某个转场按钮只影响它自己（推测） | 点 Fade 按钮，或菜单"切换 › Fade"，会把"下一次转场"改成 Fade（`fade` 命令，Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:81-85）；T-bar 和回车随之变成 Fade，界面不提示（App/Sources/UI/TransitionPanelView.swift:153；App/Sources/AppDelegate.swift:205-208） | 同名不同义 | 槽模型下统一成"执行槽 n"，这个问题随之消失。槽落地之前，至少让 T-bar 上方那行字在类型被改时有明显变化（闪一下，或写"已改为 Fade"） | 否（槽落地后由 M02 解决） | S | P1 | App/Sources/UI/TransitionPanelView.swift、App/Sources/AppDelegate.swift |
| R3a-M10 | 列首有 "Quick Play"（推测：PVW 那一路从头播放，并用默认转场切上 PGM；图 001，旁证图 069） | 没有对应物。最接近的是回车 / Fade，但它们不管播放；文件输入没有播放控制命令（Packages/SwitcherCore/Sources/SwitcherContracts/Command.swift 里没有；Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:278-317 有 pause / resume / seek，但没接出来） | 缺入口 | v1 不放这个按钮。等后续方案 §2.5 媒体播放器落地，再加"播放并切上"（= 从入点播放 PVW 那一路 + 执行转场 1）。界面稿里它只是一次 220 ms 的快速混合（界面稿 L603），槽模型下配一个"Fade 0.2 秒"的槽就等价（E5） | 是（做 §2.5 时再提） | M | P2 | —（后续） |
| R3a-M11 | 列里的 "1–4"（推测：把 PVW 那一路叠到第 n 路，已开则关；界面稿就是这个语义，toggleOv 用的是 PVW，界面稿 L529-531） | 只开关通道，不换输入；通道没指定输入时开了也看不到画面（App/Sources/UI/TransitionPanelView.swift:136、194-198） | 同名不同义 | 改成：通道已指定输入 → 只开关；没指定 → 用 PVW 那一路打开；⌥点 → 换成 PVW 那一路并打开。悬停提示"n · 输入名"保留（E7） | 否（`overlay(ch, on, input:)` 已经支持） | S | P1 | App/Sources/UI/TransitionPanelView.swift |
| R3a-M12 | PVW 标题条右端有 RGB 条 / 套叠矩形 / 齿轮三个图标；齿轮 = 打开 PVW 那一路的输入设置（图 001；图 069 索引） | 标题条只有编号 / 名字 / 角色字，没有图标和齿轮；PVW 那一路的设置在菜单"输入 › 输入设置… ⇧⌘I"（App/Sources/UI/MonitorView.swift:10-13、28-44；App/Sources/AppDelegate.swift:197-203） | 缺入口 | PVW 标题条右端加一个齿轮：单击直接打开 PVW 那一路的输入设置（和 ⇧⌘I 同一个动作）。另两个图标对应的功能我们没有（D-G20），不放 | 否 | S | P1 | App/Sources/UI/MonitorView.swift |
| R3a-M13 | PGM 标题条只有齿轮，点开菜单："Input Settings"（粗体默认）/ 分隔线 / "Output"（✓）（图 068） | 没有齿轮，也没有菜单；PGM 那一路的设置只能从缩略图右键"设置…"进（App/Sources/UI/InputCellView.swift:184-190） | 缺入口 | PGM 标题条右端加齿轮，点开菜单："输入设置…（输入 n 名字）"（默认项）/ 分隔线 /"全屏输出到 ▸"（显示器列表，等于在"全屏输出▾"里选 PGM）。显示源单选不放：我们只有一路 PGM（D-G21） | 否 | S | P2 | App/Sources/UI/MonitorView.swift |
| R3a-M14 | 截图没演示点监视器会怎样 | 单击 / 双击 / 右键监视器都没反应（App/Sources/UI/MonitorView.swift；MetalDisplayView 不处理鼠标） | 缺入口 | 右键监视器 = 弹出和齿轮同一个菜单（mac 习惯）；单击不绑动作，防误触；双击 PVW = 打开输入设置（可选） | 否 | S | P2 | App/Sources/UI/MonitorView.swift |
| R3a-M15 | "Fullscreen"▾：主体开 / 关全屏（推测）；▾ 里每块屏"Display 1 ▸"再单选源，勾 = 这块屏全屏时显示什么（图 062–063） | 入口在底栏"外部输出"和菜单"输出 › 外部输出 ▸"。勾 = 已经开着；点一下 = 开或关这一对（显示器, 源）；同一块屏可以勾多个源，各开一个窗口叠在一起；没有一键开关的主体（App/Sources/UI/ExternalOutputMenu.swift:55-73、104-111；Packages/SwitcherOutputs/Sources/External/ExternalDisplayManager.swift:6、73-84） | 触发方式不同 | 工具条放"全屏输出▾"：主体 = 开 / 关"默认屏 × 默认源"（默认 = 上次用的；第一次用 = 非主屏 + PGM）。▾ 复用 ExternalOutputMenuBuilder，但每块屏的源改成单选：选别的源 = 发 setOutputSettings 换源，不再叠第二个窗口；每块屏加一项"关闭"；正在输出的屏标"● 输出中"。菜单"输出 › 外部输出"用同一个菜单 | 否 | M | P1 | App/Sources/UI/ExternalOutputMenu.swift、App/Sources/UI/MainWindowController.swift |
| R3a-M16 | "Open"▾ = 最近文件（只显示文件名）+ 分隔线 +"Clear"（图 060） | 有，在菜单"节目 › 打开最近 ▸"，内容一样：文件名、悬停显示全路径、"清除列表"（App/Sources/AppDelegate.swift:81-83、170-185） | 层级不同 | 工具条"打开▾"：主体 = 打开…；▾ = 同一份最近列表 +"清除列表"（再加 M18 的"打开上次退出时的节目"）。两处共用 rebuildRecentMenu 的数据 | 否 | S | P2 | App/Sources/AppDelegate.swift、工具条 |
| R3a-M17 | "Save As"▾ = "Save As Bundle"（图 061） | 没有打包另存（App/Sources/AppController.swift:241-252） | 缺入口 | 工具条"另存为"先只放主体。"打包另存（节目 + 素材）…"列为 D-G11，功能做出来之前不放灰掉的空项 | 否 | S（入口）/ L（功能） | P2 | App/Sources/AppController.swift、App/Sources/Show/ShowDocuments.swift |
| R3a-M18 | "Last"（推测：打开上次会话 "last.vmix"，图 060） | 启动时自动恢复，没有手动入口（App/Sources/AppController.swift:92-108；App/Sources/Show/ShowDocuments.swift:103-111） | 缺入口 | 不单独占一个按钮；在"打开▾"和"节目"菜单里加"打开上次退出时的节目"（读 LastSession） | 否 | S | P2 | App/Sources/AppController.swift、App/Sources/AppDelegate.swift |
| R3a-M19 | 截图没演示 "New" / "Open" 会不会先确认 | 新建 / 打开不问任何问题：直接停掉旧 session（录制、推流一起停）再换（App/Sources/AppController.swift:121-151、203-215） | 状态反馈不同 | 工具条上线前先做：有录制或推流在跑时弹 sheet 二次确认（说明"会停止录制 / 推流"）；节目有文件且和上次保存的不一样时，问要不要先保存 | 否 | S | P1（放工具条的前置条件） | App/Sources/AppController.swift |
| R3a-M20 | 标题栏只显示产品名和版本（图 001） | 保存 / 另存后标题被写成代码名"Switcher 0.1.0 — 名字"，和启动时的"PlusMix …"对不上（App/Sources/AppController.swift:264 对比 App/Sources/UI/MainWindowController.swift:71、185） | 状态反馈不同 | 这一行改用 ProductName.display；保留界面稿"产品 — 节目名"的格式 | 否 | S | P1 | App/Sources/AppController.swift |
| R3a-M21 | "Settings"▾ 下面是 16 个设置页，"Shortcuts"、"Activators" 也在里面（图 002，属他区） | 设置散在四处：App 菜单偏好设置 ⌘,、"输出"菜单七页、"切换"菜单里的快捷键 / MIDI、"输入"菜单里的输入设置（App/Sources/AppDelegate.swift:71、102、110-111、118-123） | 层级不同 | 工具条"设置▾"：主体 = 偏好设置…（⌘,）；▾ = 偏好设置… / 分隔线 / 录制… ISO… 推流… 外部输出… NDI… 虚拟摄像头… 多画面布局… / 分隔线 / 快捷键… / MIDI 映射…。菜单栏原位置都保留 | 否 | S | P2 | App/Sources/UI/（工具条） |
| R3a-M22 | 快捷键和外设映射在全局设置下面（图 002 的 "Shortcuts"、"Activators"） | "快捷键…"、"MIDI 映射…"挂在"切换"菜单下（App/Sources/AppDelegate.swift:110-111） | 层级不同 | 移出"切换"菜单，放到 App 菜单"偏好设置…"下面两项（或做成偏好设置窗口的两个页签），工具条"设置▾"里也放。理由：它们管的是全部动作（音频、录制、推流都在里面），存在节目文件之外（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift:107-108），不属于"切换"操作 | 否 | S | P2 | App/Sources/AppDelegate.swift |
| R3a-M23 | 参考是 Windows，转场按钮就是操作员的主入口，菜单栏里没有对应项 | "切换"菜单只有 Cut / Fade / FTB，不显示快捷键；没有 Wipe / Zoom / Stinger，也没有"执行当前转场"（App/Sources/AppDelegate.swift:105-112） | 缺入口 | 重排"切换"菜单（附 4）：Cut / 执行当前转场（写出槽名）/ 分隔线 / 转场 1–4（标题带效果和时长）/ 分隔线 / FTB（勾 = 开着）/ Overlay 1–4 ▸（勾 = 开着）。菜单标题里显示当前快捷键表的键（menuNeedsUpdate 时反查，只显示、不绑定） | 否 | S | P1 | App/Sources/AppDelegate.swift |
| R3a-M24 | "?"（推测：帮助） | 帮助菜单只有诊断两项（App/Sources/AppDelegate.swift:154-158） | 缺入口 | 工具条"?"弹帮助菜单：用户手册（打开 docs/user 对应页或应用内帮助）/ 快捷键一览（按当前表生成）/ 导出诊断包… | 否 | S | P2 | App/Sources/AppDelegate.swift |
| R3a-M25 | T-bar 横放，在叠加 1–4 和时钟之间（图 001；界面稿也是横的，还标了"预览 … 输出"，界面稿 L173-181） | 竖放，0 在底、1 在顶；高度至少 120，还吃掉列里剩下的全部高度（App/Sources/UI/TBarView.swift:1-2、41-55；App/Sources/UI/TransitionPanelView.swift:109、112） | 触发方式不同 | 改横放：左 = 0、右 = 1，松手时到 97% 就提交，然后回弹到左。和界面稿一致，也给 4 个槽腾出高度（E8） | 否 | M | P2 | App/Sources/UI/TBarView.swift |
| R3a-M26 | —（参考的 FTB 没有 ▾，图 001） | FTB 时长只存在节目文件里，界面上改不了（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:85-101；App 里没有任何地方写 ftb.durationTicks） | 缺入口 | FTB 右键菜单：时长 0.5 / 1 / 2 秒 / 自定义…。需要一条改 FTB 时长的命令，可以并进槽提案（E11） | 是（目前没有改 ftb.durationTicks 的命令） | S | P2 | Packages/SwitcherCore/Sources/SwitcherContracts/（提案）、App/Sources/UI/TransitionPanelView.swift |
| R3a-M27 | PVW 橙、PGM 绿（图 001） | PVW 绿、PGM 红（App/Sources/UI/Theme.swift:13-16） | 状态反馈不同 | 不改。落地方案 §1.3 第 3 条已经定了用广播惯例，这里只作记录 | 否 | — | P2 | — |
| R3a-M28 | —（参考未见） | 主窗口的按钮都没设 refusesFirstResponder，全仓只有 T-bar 拒绝焦点（App/Sources/UI/TBarView.swift:31）。推测（没实测）：打开系统"键盘导航"后，Tab 到某个按钮再按空格，按下的是这个按钮，而不是 Cut | 状态反馈不同 | 工具条和转场列的按钮统一设 `refusesFirstResponder = true`（新建、打开尤其要设），保证空格 / 回车永远走快捷键表 | 否 | S | P1 | App/Sources/UI/ |

### C 附 1　工具条（回答问题 1）
- **放哪**：用 NSToolbar 挂在主窗口标题栏（`window.toolbar`）。
  - `toolbarStyle = .unified`：标题和工具条合成一行，比界面稿的两行省下约 38 pt 给监视器。要严格照界面稿做成两行，就用 `.expanded`。
  - 内容区不用动：分栏视图会自然落到工具条下方，App/Sources/UI/MainWindowController.swift:129-133 的顶部约束不用改。
- **从左到右放什么**：
  1. **"节目"组**：用 NSToolbarItemGroup 做成分段样式（对应界面稿 L70-80），依次是 新建 ｜ 打开▾ ｜ 保存 ｜ 另存为。
     - 打开▾：主体 = 打开…；▾ = 最近 10 个（文件名，悬停显示全路径）/ 分隔线 / 打开上次退出时的节目 / 清除列表。
     - 另存为：打包另存做出来之前只放主体，不带 ▾。
     - 不单独放"上次"按钮，并进打开▾。
  2. **居中"全屏输出▾"**：用 `centeredItemIdentifiers` 居中，行为见 M15。
  3. **右组**：录制状态点（可选；界面稿把 REC 放在标题栏，L61-64）/ 设置▾（M21）/ 帮助 ?（M24）。
  4. **不放"暂停输入"、"精简"**：我们没有对应功能（D-G17、G18），放上去只能是灰按钮。
  - 分体按钮用 NSMenuToolbarItem 做：设了 action 时，点主体执行动作，点 ▾ 出菜单。
- **哪些留在菜单栏**：全部都留。mac 的规矩是工具条上每个动作在菜单栏里都要有。具体是：
  - "节目"菜单：原有各项不变，再加一项"打开上次退出时的节目"；
  - "输出 › 外部输出 ▸"：和"全屏输出▾"用同一个菜单；
  - App 菜单"偏好设置…"；
  - "帮助"菜单。
- **快捷键怎么挂**：快捷键挂在菜单项上，工具条本身不带快捷键。
  - ⌘N / ⌘O / ⌘S / ⇧⌘S / ⌘, 不变。
  - "全屏输出 开 / 关"建议用 ⌥⌘F，避开系统"进入全屏"的 ⌃⌘F；主窗口自己全屏仍用绿灯。
  - 工具条按钮全部 `refusesFirstResponder`（M28）。
  - 没有 session 时，"节目"组以外的按钮都置灰。
- **前置条件**：先做 M19（新建 / 打开在录制推流中二次确认），再把"新建"、"打开"放到眼前。

### C 附 2　转场列与槽（回答问题 2、3、5）
- **按钮（从上到下）**：Cut / 转场 1 / 转场 2 / 转场 3 / 转场 4 / FTB / Overlay 1–4 / T-bar（上方一行写"T-bar：转场 n · 效果 时长"）/ 时钟。
  - 去掉：固定的 Fade / Wipe / Zoom / Stinger 按钮；列里的"参数…"（挪进槽菜单）。
  - 时长分段控件怎么处理见 E4。
  - 不放 Quick Play（E5）。
- **每个槽存什么**：
  - 效果：fade / wipe / zoom / stinger，不含 cut（Cut 有自己的固定按钮）；
  - 时长：按拍存，和 TransitionState 同一口径，界面按标称帧率显示成秒；
  - Wipe 参数：方向、软边；
  - Stinger 参数：输入、换底拍。
  - 出厂配置：1 = Fade 0.5 秒；2 = Wipe 1 秒 左→右；3 = Zoom 1 秒；4 = Stinger 1 秒（未选输入）。
- **外观和反馈**：
  - 主体写效果名（Wipe 带方向箭头，如"Wipe →"），旁边小字写时长（如"0.5s"）。
  - 执行中变蓝。
  - T-bar / 回车当前用的那个槽，加常亮细边或一个小点。
  - Stinger 槽没选输入时主体显示"Stinger（未设）"。这时点主体 = 打开 ▾ 菜单并停在输入选择上，不执行。否则执行出来就是一次延迟硬切，因为渲染器在没有 stinger 输入时只按换底拍换底（Packages/SwitcherCore/Sources/SwitcherRender/Renderer/CompositorPasses.swift:295-306）。
- **怎么触发**：
  - 主体单击 = 执行这个槽，PVW → PGM；转场进行中再点就忽略（和今天一样）。
  - 点 ▾，或在主体上右键 = 弹出菜单。菜单里的改动只改配置，不执行。
- **▾ 菜单树**（我们的说法）：
```
效果
✓ Fade
  Zoom
  Wipe  左 → 右
  Wipe  右 → 左
  Wipe  上 → 下
  Wipe  下 → 上
  Wipe  对角
  Stinger：输入 4 片头.mov        ← 没选时写"Stinger（选输入…）"，带 ▸ 子菜单列出各路输入
────────────
时长
✓ 0.5 秒
  1 秒
  2 秒
  自定义…                         ← 当前值不是预设时，这一行显示"✓ 自定义：0.75 秒"
────────────
参数…                             ← 软边、Stinger 换底拍：沿用现有 TransitionParamsView，改成按槽编辑
用于 T-bar（不执行）               ← 打勾 = 当前 T-bar / 回车用的就是这个槽
恢复出厂
```
  效果组和时长组都是单选打勾。参考的菜单不打勾，只能看按钮上的字（图 064）；我们按 mac 习惯打勾。
- **T-bar 跟哪个槽**：跟"当前槽"，也就是最近执行过的槽，或在菜单里点"用于 T-bar"选中的槽；回车也按这个口径。新节目默认当前槽是槽 1。其他口径见 E3。
- **状态存哪**：随节目文件存。槽里有 stinger 用的输入编号，换节目时必须跟着换。建议进契约，见附 3。
- **快捷键 / MIDI**：回车 = 执行当前槽。新增两类动作"执行转场 n"、"选中转场 n（不执行）"。默认表建议 ⌥1–⌥4 = 执行转场 1–4（E12）。MIDI 音符用同一套动作。API 加两条新命令。兼容层解除 Transition1–4 / SetTransitionEffect1–4 / SetTransitionDuration1–4 的"未实现"，接到槽上（Packages/SwitcherControl/Sources/VMixCompat/FunctionCatalog.swift:25-27、96-98）。
- **Overlay 1–4、T-bar、时钟**：Overlay 1–4 见 M11，T-bar 见 M25；时钟不改，已经和图 001 一致（B5）。

### C 附 3　契约提案要点（docs/contract-changes/ 下一个空号是 020；按铁律 1，用户批了之后由 P 会话落地）
- **新类型和字段**：
  - `TransitionSlot { type: TransitionType, durationTicks: Int, wipe: WipeParams, stinger: StingerParams }`；
  - `TransitionState.slots: [TransitionSlot]`：恰好 4 个，不变量和 overlays 一样；
  - `TransitionState.currentSlot: Int?`：当前那组 type / durationTicks / wipe / stinger 来自哪个槽；nil = 由 setTransition / fade / API 直接给的。
- **新命令**：
  - `setTransitionSlot(slot:, config:)`：只改槽。转场进行中也接收；进行中改的若正好是当前槽，转场完成时再把当前那组按槽重拷一次（细节由提案定）。
  - `useTransitionSlot(slot:, start: Bool)`：把槽拷进当前那组；`start = true` 时同时开始 auto 转场，一拍内原子完成，代替 UI 现在一次发两三条命令的做法。转场进行中会被拒，口径和 setTransition / autoTransition 一样。
  - 原有的 `fade` / `setTransition` / `autoTransition` / `setTransitionParams` 都保留，语义不变，执行后把 currentSlot 置为 nil。
- **旧节目文件怎么读**：缺 `slots` 时补上出厂 4 个槽。槽 1 用文件里原来那组（原来是 cut 时改用 Fade），并令 currentSlot = 1。removeInput 清 stinger 引用、`migratingLegacyKeys` 清悬空编号这两条规则，都扩到 4 个槽。
- **影响面**：
  - SwitcherContracts 和 CONTRACTS.md；
  - reducer；
  - CommandCatalog、Validator、api.md（命令数 34 → 36）；
  - 快捷键 / MIDI 动作和快捷键编辑器；
  - 兼容层（VMixCompat）；
  - Stream Deck 插件按钮（Tools/streamdeck-plugin，可以晚点做）；
  - App 转场列。
- **过渡做法（提案不批时）**：
  - 槽配置存在 `Show.layout["transitionSlots"]`：ShowLayout 的内容契约不解释，由 App 自己定键（Packages/SwitcherCore/Sources/SwitcherContracts/Show.swift:33-38）。
  - 点一个槽 = 按需发 `setTransitionParams`，再发 `setTransition` + `autoTransition`。这几条在主线程同一轮发出，按 sequence 顺序应用。
  - 代价：快捷键 / MIDI / API / 兼容层都够不着槽 2–4；删掉某一路输入时，槽里的 stinger 编号要 App 自己清。

### C 附 4　"切换"菜单重排（回答问题 6）
```
切换
  Cut                                   空格
  执行当前转场（转场 2 · Wipe → 1 秒）     回车
  ──
  转场 1：Fade 0.5 秒                    ⌥1
  转场 2：Wipe → 1 秒                    ⌥2
  转场 3：Zoom 1 秒                      ⌥3
  转场 4：Stinger（未设）                 ⌥4
  ──
  FTB                                   F     （勾 = 开着）
  Overlay ▸  1 / 2 / 3 / 4                     （勾 = 开着，标题带输入名）
```
- 右侧那一列键是从当前快捷键表反查出来的，只显示，不另外绑定：写进标题文字，或在 menuNeedsUpdate 里生成；不给 NSMenuItem 设 keyEquivalent，免得和 HotkeyDispatcher 各触发一次。
- "快捷键…"、"MIDI 映射…"移出（M22）。"切换"菜单只放现场要按的操作。

### C 附 5　控件尺寸事实（给视觉 agent 参考，没有量像素）
- **我们的转场列**：
  - 固定宽 150（App/Sources/UI/Theme.swift:27），内边距 8、间距 6（App/Sources/UI/TransitionPanelView.swift:98-100）。
  - 六个主按钮是 `.rounded` 样式、`.regular` 尺寸，宽度约束 134（App/Sources/UI/Theme.swift:46-52；App/Sources/UI/TransitionPanelView.swift:74-76）。`.rounded` 的高度由控件尺寸定死，拉不高。
  - 时长分段、"参数…"、Overlay 1–4 都是 `.small`（App/Sources/UI/TransitionPanelView.swift:61、65、72）。
  - "Overlay"小标题和"T-bar："那一行是 10 pt（App/Sources/UI/TransitionPanelView.swift:24、87）。
  - T-bar 至少 120 高且纵向可伸缩，时钟定高 64（App/Sources/UI/TransitionPanelView.swift:109-112）。
  - 结果：同一列里 regular / small 两档混用，两行 10 pt 标签夹在按钮之间。
- **界面稿**：列宽 128；按钮高 31、间距 7；Overlay 块高 26；时长块高 22（界面稿 L127-186）。

---

## D. 功能缺口

| 编号 | 功能 | 参考（图号） | 我们有没有（有 / 部分 / 无 + 证据） | 范围归类 | 建议 |
|---|---|---|---|---|---|
| R3a-G01 | 四个可配置转场按钮：效果 + 时长 + 参数，带 ▾ 菜单 | 图 001、064–067 | 部分：只有一组"下一次转场"加固定按钮（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:54-68；App/Sources/UI/TransitionPanelView.swift:95-96） | v1 应有（设计方案 §1.2；转场集合不变，只改入口模型） | 走附 3 的提案，界面按附 2 |
| R3a-G02 | 每个按钮单独设时长，按毫秒自由输入 | 图 064–067 | 部分：界面只有三档预设（App/Sources/UI/TransitionPanelView.swift:33）；API 和节目文件可以给任意拍数 | v1 应有（§1.2） | 槽菜单里放预设 + 自定义… |
| R3a-G03 | "Merge"（前后画面合并变形） | 图 064–067 | 无：TransitionType 只有 cut / fade / wipe / zoom / stinger（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:6-8）；落地方案 §1.3 第 2 条定了"按规格"，界面稿里的 Merge 不做 | 未规划（规格没提；后续方案 §6.2 的着色器插件可以承载） | 不进 v1 |
| R3a-G04 | "Slide"、"VerticalSlide"、"SlideReverse"、"VerticalSlideReverse"（推入类） | 图 064 | 无 | 未规划（后续方案 §6.2 可承载） | 不进 v1 |
| R3a-G05 | "Fly"、"FlyRotate"、"CrossZoom"、"Cube"、"CubeZoom"（立体 / 缩放类） | 图 064 | 无 | 未规划（后续方案 §6.2 可承载） | 不进 v1 |
| R3a-G06 | Wipe 的反向 / 竖向变体（"WipeReverse"、"VerticalWipe"、"VerticalWipeReverse"） | 图 064 | 有：Wipe 方向五向（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:16-18；App/Sources/UI/TransitionParams.swift:20） | v1 应有（§1.2） | 在槽菜单里把方向平铺（M05） |
| R3a-G07 | "BarnDoor"、"RollerDoor"（开门类） | 图 064 | 无 | 未规划 | 以后可以做成 Wipe 的形状参数 |
| R3a-G08 | Stinger 1–4：四套 stinger，在叠加设置里按编号配置 | 图 064、142（142 属他区） | 部分：只有一套 StingerParams（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:33-45） | v1 应有（§1.1 列了 Stinger） | 槽模型下每个槽自带 stinger 参数，最多就有四套 |
| R3a-G09 | Quick Play（推测：播放 + 默认转场） | 图 001（旁证 069） | 无：Command 里没有播放控制；FileInput 的 pause / resume / seek 没接出来（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:278-317） | 后续方案 §2.5 | 等 §2.5 落地后做"播放并切上" |
| R3a-G10 | 最近文件列表 + 清除 | 图 060 | 有：菜单"节目 › 打开最近"（App/Sources/AppDelegate.swift:81-83、170-185） | v1 应有（W2-B prompt 第 6 条） | 工具条的"打开▾"复用这份列表 |
| R3a-G11 | 打包另存（节目 + 素材打成一个包） | 图 061（包的格式见 060） | 无（App/Sources/AppController.swift:241-252） | 未规划 | 想做就单独立项；素材现在按节目文件所在目录的相对路径找（App/Sources/Show/ShowDocuments.swift:72-76），打包要把这些路径改写 |
| R3a-G12 | 手动"打开上次会话" | 图 001、060 | 部分：启动时自动恢复，没有手动入口（App/Sources/AppController.swift:92-108） | 未规划 | 在"打开▾"和"节目"菜单加一项（M18） |
| R3a-G13 | 一键全屏输出，并按显示器单选源 | 图 062–063 | 部分：有外部输出菜单，但没有一键主体，也不是单选（App/Sources/UI/ExternalOutputMenu.swift:47-111） | v1 应有（§1.2"第二屏全屏输出"） | M15 |
| R3a-G14 | 第二个多画面（"MultiView2"）可以作全屏源 | 图 063 | 无：只有一个多画面 | 后续方案 §3.6 | — |
| R3a-G15 | 回放（"Replay"）可以作全屏源 | 图 063 | 无 | v1 明确不做（§1.3 回放）/ 后续方案 §3.4 | — |
| R3a-G16 | 额外混合（"Mix1"）可以作全屏源 | 图 063 | 无：只有一路 PGM | v1 明确不做（§1.3 多画布）/ 后续方案 §3.5（推测最接近） | — |
| R3a-G17 | "Pause Inputs"（推测：暂停全部输入） | 图 001 | 无 | 未规划 | 不放，等功能定义清楚再说 |
| R3a-G18 | "Basic"（推测：精简界面） | 图 001 | 无 | 未规划 | 不放 |
| R3a-G19 | "?" 帮助入口 | 图 001 | 部分：帮助菜单只有诊断两项（App/Sources/AppDelegate.swift:154-158） | 后续方案 §8.2（文档） | 加"用户手册"、"快捷键一览"（M24） |
| R3a-G20 | PVW 标题条上的 RGB 条 / 套叠矩形两个图标（推测：色彩 / 安全框类显示辅助） | 图 001 | 无：监视器上没有安全框之类（多画面布局里有 safeArea，但那是多画面的，不是监视器的） | 未规划（安全框在后续方案 §3.6 里对多画面提过） | 不放，等功能有了再加图标 |
| R3a-G21 | PGM 监视器可选显示哪路混合（"Output ✓"） | 图 068 | 无：只有一路 PGM | 后续方案 §3.5（多画布 / 多路混合时才有意义） | — |
| R3a-G22 | 界面上能改 FTB 时长 | —（参考截图里 FTB 没有 ▾） | 部分：state.ftb.durationTicks 存在节目文件里，没有命令、没有界面 | v1 应有（§1.2 FTB） | M26 |
| R3a-G23 | 快捷键 / MIDI 一键执行 Wipe / Zoom / Stinger，并能单独改某个按钮的效果和时长 | 图 084（属他区） | 无：一个键只能绑一条命令，编辑器里只有 Cut / 按已选转场 / Fade(拍)（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/ControlAction.swift:7-15；App/Sources/Settings/HotkeyEditorPanel.swift:11-12） | v1 应有（§9.4 快捷键可配置） | 跟着槽提案一起做（M07） |

---

## E. 需要用户拍板的问题

1. **转场按钮模型（这次改动最大）**
   - 选项：
     - A：改成"转场 1–4"四个可配置槽，加固定的 Cut / FTB；
     - B：保持固定的 Fade / Wipe / Zoom / Stinger，只给每个按钮加 ▾，在里面设时长和参数。
   - 倾向 A，理由：
     - 落地方案 §1.3 第 2 条定的是"效果集合按规格"；A 不加任何规格外的效果，只改入口模型。
     - A 的出厂配置和今天四个按钮等价，老用户察觉不到变化。
     - B 下同一种效果只能有一个时长（"Fade 0.5 秒"和"Fade 2 秒"没法并存），也凑不出四套 Stinger。
   - 注意：当年 W2-B prompt 写的是"Merge / Fly / Quick Play 按钮不做"（docs/plan/prompts/31-W2B-显示与主界面.md:3）。A 仍然不做这三个，但按钮从"固定类型"变成了"可配置槽"，需要用户明确认可。
2. **槽的配置存哪**
   - 选项：
     - 契约提案（附 3），**倾向这个**；
     - App 自己存进 Show.layout 过渡。
   - 理由：
     - 快捷键 / MIDI / API / 兼容层都要能按槽触发、按槽改配置；参考的函数表就是 1–4 各一套（图 084）。
     - 一拍内原子完成。
     - 删掉某一路输入时，reducer 可以统一清掉 stinger 引用。
3. **T-bar 和回车跟哪个槽**
   - 选项：
     - (a) 跟"当前槽"，也就是最近执行的或手动选中的槽；
     - (b) 永远跟槽 1（推测的参考做法）；
     - (c) 显式"武装"一个槽，执行别的槽不改变武装。
   - 倾向 (a)：它延续今天"下一次转场"的语义，手册口径不用改，契约改动也最小；配合 M06 的常亮标记和 T-bar 上方那行字，操作员随时看得到。
   - (b) 最可预期但不灵活。(c) 贴近硬件台（AUTO 和 T-bar 共用选定样式），但契约里要多一套"执行中"字段。
4. **列里的时长分段控件（0.5s｜1s｜2s）**
   - 倾向保留，改成"当前槽的时长"：界面稿里有这一行（L182-186），临场改时长也最快。
   - 另一个选项是删掉，时长只在 ▾ 里改，和参考一致。
5. **Quick Play**
   - 倾向 v1 不放：我们没有媒体播放控制。等后续方案 §2.5 落地后，做成"播放并切上"。
   - 如果只要界面稿里"快速混合"的意思，配一个 Fade 0.2 秒的槽就够了，不用单独占一个按钮。
6. **工具条的具体做法**
   - 倾向 NSToolbar（`.unified`，一行）。
   - 不放"暂停输入"、"精简"。
   - "上次"并进打开▾。
   - 右端放不放录制状态点：界面稿放在标题栏，可以不放。
   - 如果坚持界面稿的两行外观，就用 `.expanded`。
7. **列里 Overlay 1–4 的语义**
   - 倾向：已指定输入的通道只开关；没指定的，用 PVW 那一路打开；⌥点 = 换成 PVW 那一路并打开。
   - 另一个选项是完全照界面稿，"每次都用 PVW"。缺点是会冲掉在缩略图格子上指定好的台标通道。
8. **T-bar 横放还是竖放**
   - 倾向横放：和界面稿、参考一致，也给 4 个槽腾出高度。
   - 屏幕上的 T-bar 保留"提交后回弹"：鼠标推杆没有物理位置，改成换向的话，下一次要从右往左推，不直观。MIDI 推子继续换向（Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIMapper.swift:60-75）。
   - W2-B 当初选竖放的理由是"更像硬件、给时钟留位置"（reports/w2-app.md:123），需要用户决定推翻还是维持。
9. **监视器齿轮里放什么**
   - 倾向：PVW 的齿轮直接打开输入设置；PGM 的齿轮弹菜单"输入设置… / 全屏输出到 ▸"。
   - PVW 另外两个图标不做。
10. **快捷键…、MIDI 映射… 挪到哪**
    - 倾向放 App 菜单"偏好设置…"下面，工具条"设置▾"里也放。
    - 另一个选项是并进偏好设置窗口做成页签，改动大一些。
11. **FTB 时长要不要做界面入口**
    - 要做就得加一条命令。倾向并进槽提案一起加，界面放在 FTB 的右键菜单里。
12. **默认快捷键**
    - 建议 ⌥1–⌥4 = 执行转场 1–4，回车 = 执行当前槽。这是我们自己的表，没有照抄参考；键位请用户定。

---

## F. 读图备注

- **图 001**：PVW 标题条上的 RGB 竖条和套叠矩形两个图标，没有任何一张图演示点开后的效果，作用只能推测（色彩 / 安全框类）。输入设置窗预览区右侧也有同样两个图标（图 069，属他区），同样没有演示。
- **图 001 等**："Quick Play"、"Save As"、"Pause Inputs" 的字看上去比别的按钮粗，每张图都这样，推测只是字体渲染或强调，不是状态。
- **图 064–067**：
  - 当前效果在菜单里没有勾，我放大检查过左侧勾选栏（图 064）。
  - "500" / "1000" 所在位置看不出输入框边框，只能推测可以编辑。
  - 四张图的效果列表逐项核对过，完全相同，都是 22 项。
- **图 068**："Input Settings" 是粗体，按 Windows 惯例是默认项（推测：双击时触发的就是它）。"Output" 打勾；有多路混合时会多出哪些项，截图里看不到。
- **图 062 / 063**：
  - 本机只有一块显示器，有多块时下拉的样子看不到。
  - "Output" 打勾时全屏并没有开，所以我推测这个勾表示"配置"，不表示"正在输出"，没有反证。
  - "Fullscreen" 主体点下去的效果没演示。
- **图 060**："last.vmix" 和 "Last" 按钮的关系是推测的。".vmixZip" 就是 "Save As Bundle" 的产物，这一点也是推测。
- **没演示的按钮**：New / Save / Last / Pause Inputs / Basic / "?" 的主体单击，以及四个转场按钮的主体单击，截图都没演示；A 节里它们的行为都标了"推测"。
- **图 001**：T-bar 往哪边推、推完会不会回弹，截图里看不出来；时钟也没有演示任何交互。
- 索引和图都对得上，没有发现描述和图不符的地方。
