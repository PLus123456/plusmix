> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# R3b 主界面下半：输入条 / 输入卡片 / 底栏 / 状态行及其弹出物（图 001、141–157；入口形态顺带 023、069、104、111、119、123、124、133、134、139）

约定：
- "界面稿" = docs/spec/ui-mock/vMix for Mac.dc.html，行号写成"界面稿:L236"。
- 参考软件的主体按钮（Record / External / Stream / MultiCorder / PlayList）点下去会改现场，截图说明里写了没演示，所以这些"主体 = 起停"一律标（推测）。
- 我们 App 的行号都相对仓库根。

## A. 参考软件：入口与菜单逻辑

### A1 输入条（卡片区上方一行，图 001）

- 位置：左端一排分类标签 + 放大镜；右端"Audio Mixer"开关；中间空。
- 分类标签，从左到右（图 001 放大）：
  - 灰色空白格，没有文字（推测 = 全部 / 未分类）；
  - 红底"视觉s"、绿底"开场视频s"（带文字的彩色标签）；
  - 橙、紫、浅蓝、深蓝四个纯色块（没有文字）；
  - 放大镜按钮（推测点开是搜索框，未截图）。
- 颜色的来历：输入设置 General 页的"Category"一排七个色块：深灰（默认选中）、红、绿、橙、紫、浅蓝、深蓝（图 069），和输入条的七格一一对应；音频总线管理器的筛选表里也有"Red""Green""Orange""Purple""Aqua""Blue""Custom1"…（图 151）。推测：分类按颜色分，起了名字的显示成带字的彩色标签，没起名字的只显示色块；点标签 = 只显示这一类的卡片。起名、筛选的动作本次都没截图。
- "Audio Mixer"：绿底 + 喇叭图标 = 开着，右边显示调音台面板（图 001）。调音台面板左上角有一个图钉按钮（用途未截图）。调音台只占卡片区右边那一块（监视器行下面），不是整列。
- 界面稿（界面稿:L236–257）：分段控件"视觉 / 开场视频 / 全部"（L238–240）+ 四个不可点的色块（L242–247）+ 胶囊形"Search inputs"搜索框（L248–251）+ 右端绿色"Audio Mixer"开关（L253–256）。稿子里点分类只换高亮、不筛选卡片（L578、L616–618）。

### A2 输入卡片（图 001；设置入口见图 069 的索引行）

- 标题条：左边编号块（同色加深）+ 名字。颜色 = Tally：在 PVW 的是橙色（"2 Blank"），在 PGM 的是绿色（"1 Blank"），都不在的推测是深灰（本图两路都占着）。
- 缩略图：单击的动作由输入设置里的"Mouse Click Action"决定，默认"Preview"（图 069）。
- 第一行按钮："Close"｜"Quick Play"（字比别的亮）｜"Cut"｜"Loop"（Blank 输入上是灰的）｜末尾一个空白小格（用途不明）。
  - 语义（推测，未截点击效果）：Close = 删掉这一路；Quick Play = 用快速转场把这一路送上 PGM；Cut = 这一路直切上 PGM；Loop = 媒体循环开关，不适用的输入灰掉。
- 第二行按钮："1""2""3""4"（推测 = 用 Overlay 1–4 叠上 / 撤下这一路）｜"Audio"（Blank 没有声音，灰掉；推测 = 这一路的声音开关）｜显示器图标（用途不明，未截图）｜齿轮（打开这一路的输入设置窗 "Input: 2 Blank"，图 069 索引写"素材卡片右下角齿轮"）。
- 右键菜单：本截图集里没有卡片右键的图，有没有、有什么都不知道。
- 界面稿（界面稿:L260–298）：同样两行——Close / Quick Play / Cut / Loop（灰）；1–4 可点、开着变蓝（L284–287，L555–558 的 assignOv：同一路再点 = 撤）、"Audio"灰字、显示器图标、齿轮（后三个没有点击逻辑）。整张卡加 PVW 橙框 / PGM 绿框，编号块变色（L264–267、L547–548）；卡片点一下 = 选 PVW（L559）；末尾一张虚线"Add Input"占位卡（L295–298）。

### A3 底栏（图 001，从左到右）

统一模式：左边齿轮 = 设置，文字主体 = 起停（推测），右边 ▴ = 向上弹的快捷菜单。External 是例外：它的齿轮弹菜单，不是直接开窗。

| 入口 | 左键主体 | 左侧齿轮 | 右侧 ▴ | 图 |
|---|---|---|---|---|
| "Add Input" ▴ | 开"Input Select"窗：左列输入类型（默认 Video），底部"Number"下拉 + "OK""Cancel" | 无 | 有，箭头朝上；菜单内容未截图（推测是输入类型快捷列表） | 001、023 |
| ⚙ "Record" | 起停录制（推测） | 开"Recording Setup"窗：顶部"1""2"两路、"Output 1"来源下拉、左列格式、左下"WAV File Record"、"OK""Cancel" | 无 | 111 |
| ⚙ "External" | 外部输出开 / 关（推测） | **弹菜单**（见下） | 无 | 119、123 |
| ⚙ "Stream" ▴ | 起停推流（推测） | 开"Streaming Settings"窗：Profile、1–5 路、目的地 / URL / Key、Quality、窗底"Start All""Start 1""View Status""Save and Close" | 向上弹一项"Start All Streams" | 124、133 |
| ⚙ "MultiCorder" | 起停多路录制（推测） | 开"MultiCorder"窗：格式页签、Output 1–4 勾选表、窗内大"Start"按钮 | 无 | 134 |
| ⚙ "PlayList" | 起停播放列表（推测） | 开"PlayList"窗：可用输入 / 列表、Loop 等四个勾选、"Start""Previous""Next""Close" | 无 | 139 |
| "Overlay"（右组，无齿轮） | 开"Overlay Settings"模态窗（A4） | — | — | 141 |
| ≡ | 向上弹工具菜单（A5） | — | — | 146 |
| 柱状图（红黄绿三柱） | 开"Statistics"窗（A6） | — | — | 152 |
| 四宫格 | 开"Shortcuts"小窗（A7） | — | — | 155 |
| 相机 | 系统"另存为"对话框（A8） | — | — | 156 |
| 锁 | 单击锁上 / 解开（A9） | — | — | 157 |

- External 齿轮菜单（图 119，菜单左边与齿轮对齐、向上开）：
  - "Output 2 ▸"、"Output 3 ▸"、"Output 4 ▸"（子菜单是来源，内容归别的 agent，图 120–122）
  - "SRT ▸"（图 119 上没画 ▸；图 123 悬停后出子菜单"1 (Disabled)"…"4 (Disabled)"，全灰）
  - "Output / NDI / SRT Settings"
  - "External Output Settings"
  - 没有分隔线、没有勾选项。
- Stream ▴ 菜单（图 133）：只有"Start All Streams"一项，菜单右边与 ▴ 对齐、向上开。本机没有配置目的地，推测配置了之后还会列出单路项。
- 同一模式也用在别处：调音台 Master 条的齿轮开独立窗"Audio Settings - Master"（左列 General / Plugins / EQ / Compressor / Noise Gate，只有一个"Close"，图 104）。
- 设置窗里常带起停按钮：推流设置窗的"Start All""Start 1"、MultiCorder 窗的"Start"、PlayList 窗的"Start"（图 124 / 134 / 139）。
- 三个弹出物（External 齿轮菜单、Stream ▴、≡）全部朝上开，贴着底栏上沿（图 119、133、146）。
- 界面稿（界面稿:L341–396）：顺序和分组相同；Add Input 与 Stream 的小箭头画成朝下的 ▾（L346、L367）；Record 红色底 + 红点（L351–355）；右边五个图标合成一个分段组（L385–395）；这些按钮在稿子里都没有点击逻辑。

### A4 Overlay Settings（图 141–145）

- 形式：独立模态窗，标题"Overlay Settings"，最小化 / 最大化是灰的，底部"OK""Cancel"。一次只编辑一个通道。
- 字段，从上到下（图 141）：
  - "Number:"下拉，默认"1"；展开是"1""2""3""4""Stinger 1""Stinger 2""Stinger 3""Stinger 4"共 8 项（图 142）。
  - "Type:"下拉，默认"Fullscreen"；展开是"Fullscreen""PictureInPicture"（图 143）。
  - "Effect:"下拉，默认"Fade"；展开 19 项："Fade""Zoom""Wipe""Slide""Fly""CrossZoom""FlyRotate""Cube""CubeZoom""VerticalWipe""VerticalSlide""Merge""WipeReverse""SlideReverse""VerticalWipeReverse""VerticalSlideReverse""BarnDoor""RollerDoor""Cut"（图 145）。
  - "Effect Duration:"500，单位固定"Milliseconds"。
  - "Duration:"0，单选"Milliseconds"（选中）/"Frames"，旁注"(0 to disable)"——推测是叠上后多久自动撤下。
  - "Stinger Input:"下拉"None"，Number = 1 时灰。
  - "Stinger Cut Point:"0，单选"Milliseconds"（选中）/"Frames"，"(0 to disable)"，可编辑。
  - "Alpha:"滑杆，默认拉满，数值框 255（只读样式）。
  - "Picture In Picture Location"：Type = Fullscreen 时整块灰（图 141），PictureInPicture 时可用（图 144）。"Zoom"1、"Zoom X"1、"Zoom Y"1、"Pan X"0、"Pan Y"0、"Rotate:"［Z］按钮 + 滑杆 0（推测 Z 按钮切旋转轴），每行一个"Reset"。
  - 右边红框预览，上方一句"To adjust position, drag the red box or hold down shift to resize"：拖红框改位置，按住 Shift 拖改大小。
  - "Border"（同样只在画中画可用）："Colour"（白色块）、"Thickness"0、"Radius"0。
- 窗里没有"用哪一路输入"的字段（推测由卡片 1–4 或转场列 1–4 决定）。

### A5 ≡ 工具菜单（图 146）及三个管理器（图 147–151）

- 位置：底栏右组，"Overlay"右边第一个图标；左键；菜单朝上开，在按钮左上方。
- 菜单项 9 项，每项带图标，没有分隔线、没有勾选、没有灰项：
  1. "Data Sources Manager"
  2. "Triggers Manager"
  3. "Audio Bus Manager"
  4. "vMix Social"
  5. "GT Title Designer"
  6. "vMix Video Tools"
  7. "vMix Media Converter"
  8. "vMix Diagnostics"
  9. "Open Web Controller in Browser"
  第 4–9 项是竞品自家的独立工具 / 服务入口，本次没点开。
- "Data Sources"窗（图 147）：左上"+"；"Table"下拉（空）；"Settings""Delete"（灰）；灰色空表；底部 ⏮ ⏭（上一行 / 下一行）、"Auto Next"+ 5（秒）、"Loop"、⏸、"Update data every"1000（毫秒）。
  - "+"菜单（图 148）："Excel/CSV""Google Sheets""JSON""RSS""Text""XML""ZoomChat" ─分隔线─ "Import""Export""Remove All"。
- "Triggers Manager"（图 149）：只读汇总表，列"Source Input""Trigger""Function""Input""Duration""Delay""Value""Mix"，本机为空；底部"Go To Input Settings"（灰，推测选中一行后可用）。触发器本身在各输入的设置里编辑。
- "Audio Bus Manager"（图 150）：输入 × 总线的路由矩阵；左上筛选下拉默认"All"；列头只有"M"（Master）；本机输入都没有声音，没有行。
  - 筛选项（图 151）："All""Video""List""Camera""NDI""Stream / SRT""Audio""Audio Input""Instant Replay""Web Browser""Video Call""Zoom""Red""Green""Orange""Purple""Aqua""Blue""Custom1"…"Custom6"…（按输入类型、颜色分类、自定义分类，列表有滚动条）。

### A6 Statistics 统计窗（图 152–154）

- 入口：底栏柱状图，左键开独立窗（可最大化）。顶部三个页签（当前页绿底），右下"Refresh""Reset"。
- "Overview"（图 152）：列"Input""Source Dropped""Renderer Dr…"（截断）"Resync""Queue""Video""Audio"。本机只有一行"Output"：0 / 0 / 0 / 0，Video 列"Fullscreen Dropped: 37224 0 430 (32 ms)"。
- "SRT"（图 153）：列"Connection""Duration""Bandwidth (…""Packet Loss…""Total Data""RTT (ms)"，为空。
- "Encoders"（图 154）：列"Name""Source""Audio""Resolution""Codec""FPS""Dropped Frames"；一行"NDI"：FPS 0、Dropped Frames 0。

### A7 Shortcuts 快捷按钮面板（图 155）

- 入口：底栏四宫格，开独立小窗"Shortcuts"。
- 每条快捷键一块瓦片：大字（"渐入""123"，推测是这条快捷键的名字或键名）+ 两行小字（功能"Fade"，对象"Preview"或"1 Blank"）。推测点瓦片 = 执行这条快捷键。
- 底部左"Web Controller"，右"Edit"（索引：通往快捷键配置）。

### A8 截图（图 156）

- 入口：底栏相机图标 → 系统"另存为"对话框。默认目录"文档"，默认文件名"vMix Capture 28 九月 2026 19-38-35.png"（产品名 + Capture + 日期 + 时分秒），类型"PNG (*.png)"。截哪一路图上看不出（推测 PGM）。

### A9 界面锁（图 157）

- 入口：底栏最右的锁。点一下锁上，图标变成合上的金黄色锁；再点解开（索引）。锁上后界面其他部分没有变暗、没有遮罩。锁住拦什么图上看不出（推测是防止误点主界面）。

### A10 状态栏（图 001 最底一行，独立一行，在按钮栏下面）

- 字段："1440p59.94"（绿字，节目格式）｜"EX"（含义不明）｜"FPS: 60"｜"Render Time: 3 ms"｜"GPU Mem: 0 %"｜"CPU vMix: 3 %"（本进程）｜"Total: 40 %"（推测整机 CPU）。
- 数值会变：图 023 里 FPS 是 85，图 146 里 CPU 6 %、Total 42 %。
- 界面稿（界面稿:L398–408）：同样的字段，右端多一段"Apple M3 Max · 36 GB"。

## B. 我们现在的实现

### B1 输入条（InputStripView）

- 顶行：左边标题"输入"（App/Sources/UI/InputStripView.swift:39、58–59），后面一个常驻搜索框，宽 220 pt，占位"搜索输入（编号或名字）"（InputStripView.swift:30–38、60–62；App/Resources/zh-Hans.lproj/Localizable.strings:692）。
  - 匹配规则：编号完全相等，或名字包含关键字（App/Sources/UI/InputCellView.swift:176–181）。
  - 回车 / Esc 把焦点还给主窗口（数字键又变回快捷键），Esc 同时清空（InputStripView.swift:171–178）。
- 没有分类标签、没有颜色块。契约里也没有分类字段：InputConfig 只有编号、名字、来源、设置（Packages/SwitcherCore/Sources/SwitcherContracts/Input.swift:427–435）。
- 没有"调音台"开关。调音台的开 / 收只有两处：窗口 › 调音台（App/Sources/AppDelegate.swift:148、220 → App/Sources/UI/MainWindowController.swift:313–320），和拖分隔条收起（MainWindowController.swift:326–328）。显隐状态存在 ShowLayout 的"mixerPanelVisible"里（App/Sources/AppController.swift:284）。
  - 调音台是整列，从窗口顶一直到底栏上沿（MainWindowController.swift:117–126）。
  - 调音台头部只有"调音台"标题、AFV 开关、AFL / PFL（App/Sources/UI/MixerPanelView.swift:262–278），没有收起按钮。
- 卡片一行横向滚动（InputStripView.swift:41–53），没有"添加输入"占位卡。

### B2 输入格子（InputCellView）

- 标题条：编号 + 名字。颜色 PGM 红 / PVW 绿 / 其余灰，另加 2 pt 同色边框（InputCellView.swift:118–125；App/Sources/UI/Theme.swift:1、13–18）。这是有意的：落地方案 §1.3 第 3 条、§7 第 3 条定了按广播惯例 PGM 红、PVW 绿（docs/plan/导播台落地方案.md:36、215）。
- 点缩略图或标题条 = setPreview；按住 Shift 点 = setProgram 直切（InputCellView.swift:215–223）。只在悬停提示里说明（Localizable.strings:196）。
- 底行按钮：Overlay 1–4 四个小按钮 + "静音"（InputCellView.swift:34–41、76–79）。
  - 按 k：这一路正占着 Overlay k 且开着 → 关掉；否则把 Overlay k 换成这一路并打开（InputCellView.swift:225–233）。亮 = 通道开着且用的是这一路（L126–128）。
  - 静音：翻转 mute（L240–242），静音时红底（L129）。这一路本来没有声音时也照样可点，不灰掉。
- 右键菜单："设置…"（开这一路的输入设置窗）、"重命名…"（sheet 输入框）、"删除输入 n"（直接 removeInput，不确认）（InputCellView.swift:183–213；Localizable.strings:190–192）。
- 没有的：Close / 转场 / Cut / 循环按钮、齿轮、显示器图标。
- 格子中间的状态文字（无信号 / 错误 / 不在多画面布局里）和纯音频输入的占位（InputCellView.swift:20–25、157–171）。
- 输入设置的其他入口：输入 › 输入设置…（⇧⌘I，只开 PVW 上那一路，AppDelegate.swift:102、198–203）；调音台条子上的"设置…"（MixerPanelView.swift:321）。

### B3 底栏（BottomBarView）

- 高 58 pt：上面一排按钮，下面一行状态行（Theme.swift:29；App/Sources/UI/BottomBarView.swift:77–87）。
- 按钮顺序：添加输入… / 录制 / ISO… / 推流 / 外部输出 / 多画面 / 叠加…（BottomBarView.swift:66），全是普通圆角按钮，没有齿轮、没有小箭头。按钮右边是提示文字，4 秒自动清掉（L84–86、182–189）。
- 逐个：
  - "添加输入…"（⌘I，L63–64）→ presentAddInput：主窗口 sheet（MainWindowController.swift:258–268），左列八种类型、右边参数页、底部编号 + 名字（App/Sources/UI/AddInputSheet.swift:1–2）。菜单栏 输入 › 添加输入… 是同一入口（AppDelegate.swift:101、196）。
  - "录制" → recordPressed：有任何一路录制在录就全停，否则全部录制输出（PGM + ISO 路）同一拍起；节目里一个录制输出都没有时，先加一个默认的再起（BottomBarView.swift:195–213）。文案：录制 / ● 录制中 / ● 录制中（n 路）/ 录制 · <状态>（L119–142；Localizable.strings:168–173）。录制设置只在菜单栏 输出 › 录制设置…（AppDelegate.swift:118–123）。
  - "ISO…" → 开输出设置窗的 ISO 页（BottomBarView.swift:229；MainWindowController.swift:149；App/Sources/UI/PanelCoordinator.swift:78）。ISO 没有自己的起停，跟"录制"一起。
  - "推流" → streamPressed：有在推的就全停，否则全部目的地一起起（BottomBarView.swift:216–224）。文案：推流 / ● 推流中 / 推流 · 重连中（第 n 次）/ 推流 · <状态>（L143–160）。节目里没有推流目的地时按钮灰掉，悬停提示去 输出 › 推流设置… 里添加（L161–166；Localizable.strings:165）。
  - "外部输出" → presentExternalMenu（BottomBarView.swift:227；MainWindowController.swift:147、295–298）弹菜单：
    - 每块显示器一个子菜单，标题带分辨率 / 刷新率 /（主屏）；子菜单里是 PGM / PVW / 多画面 ─ Aux 说明 ─ 各路输入，已开的打勾；选一项 = addOutput，再选同一项 = removeOutput（App/Sources/UI/ExternalOutputMenu.swift:47–74、104–111）。
    - 已有外部输出时，下面加"关闭 n 名字（状态）"若干项和"关闭全部外部输出"（ExternalOutputMenu.swift:75–90、113–120）。
    - 同一个菜单也挂在菜单栏 输出 › 外部输出 ▸（AppDelegate.swift:125–128、260–264）。
    - 主体没有开关语义。
  - "多画面" → 开 / 关多画面独立窗口（BottomBarView.swift:228；MainWindowController.swift:301–308）。
  - "叠加…" → presentOverlayPanel：NSPopover，behavior = .transient（点别处就关），再点按钮也是关（MainWindowController.swift:270–284）。内容见 B4。
- 没有的：多路录制的单独起停、播放列表、≡ 工具菜单、统计、快捷按钮、截图、锁。工具类入口散在菜单栏：切换 › 快捷键… / MIDI 映射…（AppDelegate.swift:105–112），帮助 › 导出诊断包… / 打开诊断文件夹（AppDelegate.swift:154–158），输出 › 七个设置页（AppDelegate.swift:115–123）。

弹出方向（从代码看到的事实；目视实测归另一个 agent）：
- 外部输出菜单：`menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)`（MainWindowController.swift:297），anchor = 外部输出按钮。NSButton.isFlipped == true，y = bounds.height 是按钮的**底边**：菜单左上角贴着按钮左下角，向下展开。底栏是窗口最底下的视图（MainWindowController.swift:133–136），所以菜单从窗口下沿往窗外长；屏幕下方放不下时由 AppKit 挪位置（推测是往上平移、盖住按钮）。
- 叠加面板：`popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)`（MainWindowController.swift:281），anchor = 叠加按钮。在翻转坐标里 .maxY 也是按钮的**底边**，所以首选在按钮下方弹出（窗口外），内容 400×640（App/Sources/UI/OverlayPanel.swift:168）；下方放不下时 NSPopover 自己换边（推测）。
- 参考的三个底栏弹出物全部朝上开（图 119、133、146），和我们相反。
- 其余底栏入口不是就近浮层：添加输入是窗口 sheet；ISO… 开输出设置窗；多画面开独立窗口。

### B4 叠加面板（OverlayPanel.swift）

- 形式：底栏"叠加…"弹出的 popover，SwiftUI Form，400×640，Overlay 1–4 四节上下全列出来（OverlayPanel.swift:116–169）。每改一项立刻发命令，没有确定 / 取消。
- 每个通道：
  - "输入"下拉：（无）/ 各路输入（L124–127）。选输入不改开关（L46–48）。
  - "显示"开关（L128）。
  - "位置"下拉：整幅 / 左上 / 右上 / 左下 / 右下 1/4 / 下三分之一 / 自定义（L10–31、129–131）；选自定义时出 X / Y / 宽 / 高四个数字框（L132–139）。
  - "动画"：切入 / 淡入 / 滑入 / 缩放（L38、140–142）；"时长 n 拍"步进器，0–600，步长 5（L143–145）；选滑入时出"从哪条边滑入"：自动 / 左 / 右 / 上 / 下（L146–151）。
  - "锚点"九宫（L152–154）、"PVW 预览"（L155–156）、"边框"开关 + 宽（按 1080p 的 px 显示）+ 颜色（L157–163）。
- 发的命令：overlay / setOverlay / setOverlayDecoration（OverlayPanel.swift:1–4；Packages/SwitcherCore/Sources/SwitcherContracts/Command.swift:31–36）。
- 契约里 OverlayState 只有 input / on / rect / animProgress / animation / startTick / border / anchor / previewOn（Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:206–239）；动画只有 cut / fade / slide / zoom（MixerState.swift:128–130）；默认 cut、0 拍（MixerState.swift:147），新节目也没改这个默认（App/Sources/Show/ShowDocuments.swift:35–41）；边框只有宽和颜色（MixerState.swift:168–180）。没有透明度、旋转、自动撤下时长、圆角、叠加用 Stinger。
- 转场列的 Overlay 1–4 只翻开关、不换输入（App/Sources/UI/TransitionPanelView.swift:1–4、194–197）；某路还没指定输入时，悬停提示"在缩略图格子上点 k"（TransitionPanelView.swift:136；Localizable.strings:696）。

### B5 状态行（StatusLineFormatter + BottomBarView）

- 位置：底栏里按钮下面那一行（BottomBarView.swift:26、81–83），1 Hz，读 Stats（L101–112）；第一行出来前显示"等待第一行 Stats…"（L88）。
- 字段（App/Sources/UI/StatusLineFormatter.swift:35–56，用"  ·  "连起来，L71–73）：
  - "节目 1920×1080 60"（格式：宽×高 + 帧率）
  - "fps 60.0"（相邻两行的 tick 差 / ts 差）
  - "render 1.93 ms"
  - "GPU 12%"（GPU 利用率）
  - "CPU 35%"（本进程，100 = 一个核）
  - "丢帧 n"（missed_render）
  - "编码跳帧 n"、"码率 x Mb/s"（先找在跑的录制 / 推流，都没在跑才看 NDI）
  - "磁盘 x GB"
- 数据只有一份：StatsHub 每秒一行，同时给 stats.jsonl、API 和主线程（App/Sources/Engine/StatsHub.swift:1–3、27–38）；字段定义见 Packages/SwitcherCore/Sources/SwitcherContracts/Stats.swift:27–51、92–146、149–193。界面上除了状态行和调音台底部的 A1 计数，没有别的地方看 Stats，没有统计窗口。

### B6 快捷键

- 只有编辑器：切换 › 快捷键… 开"快捷键"窗，760×520，一行一条：组合键 / 录键 / 动作 / 参数 / 备注 / 删除，底部"加一条""恢复默认表""保存"（App/Sources/Settings/HotkeyEditorPanel.swift:183–232；AppDelegate.swift:110、213）。
- 没有"点一下就执行"的快捷按钮面板。现成可复用的：ControlAction.resolve(in:)（Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/ControlAction.swift:17）、HotkeyEditorModel.describe（HotkeyEditorPanel.swift:168–173）。

### B7 截图 / 界面锁

- 两样都没有。可用的底子：DisplayFrameSource.latestDisplayFrame(for:) 能拿到最新的 PGM 纹理（Packages/SwitcherCore/Sources/SwitcherRender/Renderer/MetalRenderer.swift:55–60）。

## C. 菜单逻辑差异与改法

工作量口径：S ≤ 半天，M 1–3 天，L > 3 天。标"不改"的行是记录有意的差别。

| 编号 | 参考行为（图号） | 我们现状（文件:行号） | 差异类型 | 建议改法（我们自己的说法） | 要改契约？ | 工作量 S/M/L | 优先级 P0/P1/P2 | 归属目录 |
|---|---|---|---|---|---|---|---|---|
| R3b-M01 | 底栏弹出物全部朝上开：外部齿轮菜单贴齿轮左边向上（图 119），推流 ▴ 贴 ▴ 右边向上（图 133），≡ 向上（图 146） | 外部输出菜单定位点是翻转按钮的底边，向下开（MainWindowController.swift:297）；叠加 popover 的 preferredEdge .maxY 在翻转按钮上也是底边（MainWindowController.swift:281）；两者都往窗口外长 | 默认值不同（弹出方向） | 底栏所有菜单和浮层一律朝上：菜单的定位点取按钮顶边再往上一个菜单高（翻转坐标 y = −菜单高）；popover 用 .minY（翻转坐标里是顶边）；抽成一个帮助函数，以后加的 ▴ 菜单都走它 | 否 | S | P0 | App/Sources/UI（MainWindowController） |
| R3b-M02 | 外部：主体 = 开关（推测），齿轮 = 路由 + 设置入口菜单（图 119、123） | 主体直接弹"显示器 × 来源"菜单，选中 = 加一路输出，再选 = 删掉（BottomBarView.swift:227；ExternalOutputMenu.swift:47–120），没有开关 | 同名不同义 | 拆成"⚙ + 外部输出"：⚙ 向上弹现有菜单，末尾加"外部输出设置…"（开输出设置窗的外部页）；主体 = 全部外部显示输出开 / 关（setOutputEnabled，配置保留，开着高亮）；一路外部输出都没有时，主体等同 ⚙。见 E-1 | 否（setOutputEnabled 已有，Command.swift:59） | M | P1 | App/Sources/UI |
| R3b-M03 | 录制左边齿轮 → 录制设置窗（图 111） | 只有主体起停（BottomBarView.swift:195–213）；录制设置只在菜单栏 输出 › 录制设置…（AppDelegate.swift:118–123） | 缺入口 | "录制"左边加 ⚙，开输出设置窗的录制页（PanelCoordinator.showOutputSettings(tab: .record)） | 否 | S | P1 | App/Sources/UI |
| R3b-M04 | 推流：⚙ → 推流设置窗（图 124）；▴ → 向上的"Start All Streams"（图 133） | 只有主体（全起 / 全停，BottomBarView.swift:216–224）；没有目的地时按钮灰掉，只能去菜单栏添加（L161–166） | 缺入口 | 加 ⚙（开推流页）和朝上的 ▴：全部开始 / 全部停止 ─ 每个目的地一项"n 名字"（在推的打勾，点 = 单路起停）；没有目的地时主体不灰，点了开推流页 | 否 | S | P1 | App/Sources/UI |
| R3b-M05 | 多路录制是单独的"⚙ + 起停"，和主录制分开（图 134） | "ISO…"只开 ISO 设置页（BottomBarView.swift:229）；ISO 随"录制"同一拍起停（L195–213） | 层级不同 | 去掉单独的"ISO…"，把"ISO 分路录制…"放进录制 ⚙（录制 ⚙ 向上弹：录制设置… / ISO 分路录制…）；录制按钮继续显示路数（已有"● 录制中（n 路）"）。见 E-2 | 否 | S | P2 | App/Sources/UI |
| R3b-M06 | 添加输入右边有 ▴ 快捷菜单（图 001；菜单内容未截图） | 只有主体开 sheet（MainWindowController.swift:258–268）+ ⌘I | 缺入口 | 加朝上的 ▴：列出八种输入类型，点哪项就开添加输入 sheet 并预选那一类 | 否 | S | P2 | App/Sources/UI |
| R3b-M07 | 叠加设置是独立模态窗，一次编辑一个通道（"Number"选 1–4 / Stinger 1–4），"OK""Cancel"（图 141、142） | popover，四个通道上下全列，.transient：点主窗口任何地方（比如格子上的 1–4）就关，改一项立刻生效（MainWindowController.swift:270–284；OverlayPanel.swift:116–169） | 层级不同 | 改成独立的非模态"叠加设置"窗（走 PanelCoordinator，和其他设置窗一样）：顶部 Overlay 1–4 分段选通道，只显示当前通道；保持即时生效，不加确定 / 取消；转场列 Overlay k 和格子 k 的右键加"叠加设置…"，直接打开到第 k 路。见 E-3 | 否 | M | P1 | App/Sources/UI、App/Sources/Settings |
| R3b-M08 | Type 二选一"全屏 / 画中画"；全屏时画中画位置和边框整块灰（图 141、143、144） | "位置"一个下拉里混着整幅 / 四角 / 下三分之一 / 自定义，边框开关一直能点（OverlayPanel.swift:129–139、157–163） | 层级不同 | 顶上加"整幅 / 画中画"二选一；整幅时位置、锚点、边框收起；画中画时出位置预设 + 数字框 + 边框 | 否 | S | P2 | App/Sources/UI |
| R3b-M09 | 新叠加默认 Fade、500 毫秒，时长按毫秒填（图 141） | 默认切入、0 拍（MixerState.swift:147）；面板里是"时长 n 拍"，步长 5（OverlayPanel.swift:143–145） | 默认值不同 | 新节目四个通道默认"淡入 0.5 s"（在 App 的 emptyShow 里给，按节目帧率换算成拍，ShowDocuments.swift:35–41）；面板里时长按秒显示、悬停提示写拍数，给 0.5 / 1 / 2 s 三个快捷值（和转场列一样） | 否（不动契约默认值；要改 OverlayAnimation 的默认值才需提案） | S | P2 | App/Sources/Show、App/Sources/UI |
| R3b-M10 | 设置窗里不选输入，也没有锚点 / PVW 预览（图 141、144） | 面板里有"输入"下拉、"显示"开关、"锚点"、"PVW 预览"（OverlayPanel.swift:124–128、152–156） | 我们多出的 | 保留（比参考直观）；"输入"下拉和格子 1–4 同一口径（选了输入不自动打开，现在就是这样） | 否 | S（不改） | P2 | App/Sources/UI |
| R3b-M11 | 输入条左端分类标签 + 色块，按分类筛卡片（图 001；分类在输入设置里选，图 069） | 只有"输入"标题 + 搜索框（InputStripView.swift:39、54–66）；契约没有分类字段（Input.swift:427–435） | 缺入口 | 输入条左端加"全部 + 六色"标签：点 = 只显示这一色的格子（和搜索叠加）；右键标签 = 改名；格子右键加"分类 ▸"（六色 + 无）；分类数据先放 ShowLayout（Show.swift:33–37）。见 E-4 | 否（放 ShowLayout）；放进 InputConfig 则要提案 | M | P2 | App/Sources/UI、App/Sources/Show |
| R3b-M12 | 输入条右端"Audio Mixer"开关，绿 = 开（图 001） | 只有 窗口 › 调音台和拖分隔条（AppDelegate.swift:148、220；MainWindowController.swift:313–328） | 缺入口 | 输入条顶行右端加"调音台"开关按钮（开着高亮），和 窗口 › 调音台 同一个动作 | 否 | S | P1 | App/Sources/UI |
| R3b-M13 | 放大镜图标（推测点开才出搜索框，图 001） | 搜索框常驻，220 pt，编号 / 名字匹配（InputStripView.swift:30–38；InputCellView.swift:176–181） | 触发方式不同 | 保留常驻搜索框（mac 习惯，少点一下）；加 ⌘F 聚焦搜索框 | 否 | S | P2 | App/Sources/UI |
| R3b-M14 | 卡片第一行"Close""Quick Play""Cut""Loop"都是看得见的按钮（图 001） | Cut 藏在 Shift 点（InputCellView.swift:215–223），删除藏在右键（L183–190、213），没有"按已选转场送上 PGM" | 缺入口 | 格子加一行：删除（×；这一路在 PGM / PVW / 叠加上时先确认）/ 转场（按转场列当前的类型和时长把这一路送上 PGM：setPreview + autoTransition）/ Cut（setProgram）/ 循环（见 M15）；Shift 点保留。注意：转场进行中 setPreview 不被拒、会换掉正在进来的画面，autoTransition 被拒（Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:97–102），所以"转场"按钮要先看 transition 是否在进行，进行中就不发。见 E-5、E-6 | 否（两条现有命令按顺序发） | M | P1 | App/Sources/UI |
| R3b-M15 | "Loop"按钮，不适用的输入灰掉（图 001） | 循环只能在添加时选（FileEndAction，Input.swift:33–35、112）；运行中改来源会重建输入，文件从头播（App/Sources/Engine/InputRuntime.swift:43–49） | 缺入口 | 视频文件格子上加"循环"开关，发 setInputSource 只改 endAction；运行表遇到"只有 endAction 变了"不重建，交给文件输入就地改结束动作；非文件输入灰掉 | 否（setInputSource 已有） | M | P2 | App/Sources/Engine、Packages/SwitcherInputs（W2-A 系） |
| R3b-M16 | 卡片右下角齿轮 → 这一路的输入设置窗（图 001；图 069 索引） | 只有右键"设置…"（InputCellView.swift:183–192）和 输入 › 输入设置…（只开 PVW 那一路，AppDelegate.swift:198–203） | 缺入口 | 格子底行最右加 ⚙，开这一路的输入设置窗 | 否 | S | P1 | App/Sources/UI |
| R3b-M17 | "Audio"按钮，没有声音的输入灰掉（图 001） | "静音"一直能点，静音时红底（InputCellView.swift:40–41、129、240–242） | 状态反馈不同 | 保留"静音"的意思（和调音台一致）；这一路没有声音（图片、不采声音的屏幕、不带声音的合成源）时灰掉，悬停说明原因 | 否 | S | P2 | App/Sources/UI |
| R3b-M18 | 标题条 PVW 橙、PGM 绿（图 001） | PGM 红、PVW 绿，外加 2 pt 边框（InputCellView.swift:123–125；Theme.swift:1、13–16） | 默认值不同 | 保持现状，不改回：落地方案 §1.3 第 3 条、§7 第 3 条已定广播惯例（docs/plan/导播台落地方案.md:36、215） | 否 | S（不改） | P2 | App/Sources/UI |
| R3b-M19 | 卡片右键菜单：截图集里没有，内容未知 | 设置… / 重命名… / 删除输入 n（不确认）（InputCellView.swift:183–213） | 我们多出的 | 补齐常用动作：送 PVW / Cut 到 PGM / 按已选转场送上 PGM / Overlay 1–4 ▸ / 分类 ▸ / 静音 ─ 设置… / 重命名… / 删除…（在 PGM / PVW / 叠加上时确认）。见 E-10 | 否 | S | P2 | App/Sources/UI |
| R3b-M20 | ≡ 工具菜单：数据源 / 触发器 / 音频总线管理器、几个独立工具、浏览器控制器（图 146） | 这类入口在菜单栏：切换 › 快捷键… / MIDI 映射…，帮助 › 导出诊断包…（AppDelegate.swift:105–112、154–158） | 层级不同 | 底栏右端加 ≡，朝上弹"工具"菜单：快捷键… / MIDI 映射… / 统计… / 快捷按钮… / 总线路由… ─ 导出诊断包…；以后的数据源、触发器也挂这里；菜单栏原样保留 | 否 | S | P2 | App/Sources/UI |
| R3b-M21 | 柱状图 → 统计窗：Overview / SRT / Encoders 三页，"Refresh""Reset"（图 152–154） | 只有底栏一行状态行（BottomBarView.swift:101–112；StatusLineFormatter.swift:35–56） | 缺入口 | 底栏右端加"统计"按钮，开只读窗口：每路输入（fps / 重复 / 丢 / 延迟）、渲染（render / 丢帧 / 抖动）、每个输出（按 EncoderEntry.output 对上快照里的名字、类型、来源、分辨率、编码，显示帧数 / 跳帧 / 丢帧 / 码率 / 状态）、显示类（display[]）、音频（dropouts / underruns / discontinuities）；"重置"= 界面记一个基线再相减（Stats 累计值不回退）。见 E-9 | 否（SRT 页要的 RTT / 丢包需提案，见 D-G14） | M | P1 | App/Sources/UI |
| R3b-M22 | 四宫格 → 快捷按钮面板：每条快捷键一块瓦片，点 = 执行，"Edit"→ 快捷键配置（图 155） | 只有快捷键编辑器（表格），没有可点的按钮面板（HotkeyEditorPanel.swift:183–232） | 缺入口 | 底栏加"快捷按钮"：小窗把快捷键表每条画成一块瓦片（大字 = 备注，没有备注用组合键；小字 = 动作描述，HotkeyEditorModel.describe），点 = 按当前快照解析后发命令（ControlAction.resolve），"编辑…"开快捷键窗 | 否 | M | P2 | App/Sources/UI、App/Sources/Settings |
| R3b-M23 | 相机 → 另存为 PNG，默认"产品名 Capture 日期 时间.png"（图 156） | 没有 | 缺入口 | 底栏加"截图"：把当前 PGM 一帧存成 PNG（DisplayFrameSource.latestDisplayFrame(for: .program) 拷到 CPU）；存盘面板默认"PlusMix 截图 <日期 时间>.png"，记住上次目录 | 否 | M | P2 | App/Sources/UI |
| R3b-M24 | 锁：点一下锁上（图标变金黄），再点解开（图 157） | 没有 | 缺入口 | 底栏最右加"锁定界面"开关：锁着时主窗口的鼠标点击不生效（锁按钮本身除外），快捷键 / MIDI / API 照常；锁着时按钮高亮。见 E-8 | 否 | S | P2 | App/Sources/UI |
| R3b-M25 | 状态栏独立一行，在按钮栏下面；格式简写"1440p59.94"（绿字）；字段 FPS / Render Time / GPU Mem / CPU / Total（图 001） | 状态行塞在底栏按钮下面（BottomBarView.swift:77–87）；格式写成"节目 1920×1080 60"；字段见 StatusLineFormatter.swift:35–56 | 层级不同 | 状态行独立成窗口最底一行（全宽），格式简写成"1080p60""1080p59.94"；字段不变（我们的丢帧 / 编码跳帧 / 码率 / 磁盘比参考的更有用）；提示文字挪到状态行右端 | 否（只改排版）；加整机 CPU / GPU 显存要提案，见 E-7 | S | P2 | App/Sources/UI |
| R3b-M26 | 底栏顺序：添加 · 录制 · 外部 · 推流 · 多路录制 · 播放列表……右组 叠加 + ≡ / 统计 / 快捷按钮 / 截图 / 锁（图 001） | 添加输入… · 录制 · ISO… · 推流 · 外部输出 · 多画面 · 叠加…，全挤在左边（BottomBarView.swift:66） | 层级不同 | 左组：添加输入 ▴ ｜ ⚙ 录制 ｜ ⚙ 外部输出 ｜ ⚙ 推流 ▴ ｜ ⚙ 多画面；右组：叠加 ｜ ≡ 统计 快捷按钮 截图 锁 | 否 | S | P2 | App/Sources/UI |
| R3b-M27 | 底栏没有多画面按钮（图 001） | "多画面"开 / 关多画面窗口（BottomBarView.swift:228） | 我们多出的 | 保留，并套同一模式：⚙ = 多画面布局页，主体 = 多画面窗口开 / 关（开着高亮） | 否 | S | P2 | App/Sources/UI |
| R3b-M28 | 界面稿：卡片条末尾一张虚线"Add Input"占位卡（界面稿:L295–298）；参考没有（图 001） | 没有（InputStripView.swift:41–53） | 缺入口 | 卡片条末尾加虚线占位格，点 = 添加输入 sheet；没有输入时它就是空状态提示 | 否 | S | P2 | App/Sources/UI |

## D. 功能缺口

| 编号 | 功能 | 参考（图号） | 我们有没有（有 / 部分 / 无 + 证据） | 范围归类 | 建议 |
|---|---|---|---|---|---|
| R3b-G01 | 叠加通道用 Stinger（Stinger 1–4 当叠加） | 图 142 | 无：Stinger 只用在转场（MixerState.swift:33），OverlayState 没有这一项（MixerState.swift:206–239） | 未规划（规格没提） | 不做；真要做走提案 |
| R3b-G02 | 叠加进出效果 19 种 | 图 145 | 部分：切入 / 淡入 / 滑入（可选四条边）/ 缩放（MixerState.swift:128–135；OverlayPanel.swift:38） | 未规划（规格没提） | 现有的够用；最多补一个"擦除"（复用转场 Wipe），要加枚举值，走提案 |
| R3b-G03 | 叠上后自动撤下（"Duration"，0 = 不撤） | 图 141 | 无 | 未规划（规格没提） | 下三分之一常用，P2；OverlayState 要加字段，走提案 |
| R3b-G04 | 叠加透明度（"Alpha"0–255） | 图 141 | 无（OverlayState 没有透明度，MixerState.swift:206–239） | 未规划（规格没提） | P2；走提案 |
| R3b-G05 | 画中画旋转、横纵分别缩放 | 图 144 | 部分：rect 管缩放和平移；旋转只有输入级变换（Input.swift:216–228） | 未规划（规格没提） | 用输入级变换代替，不加 |
| R3b-G06 | 在预览里拖框定位（按住 Shift 改大小） | 图 141、144 | 无（只有数字框，OverlayPanel.swift:132–139） | 未规划（规格没提） | 叠加设置窗里加一块 16:9 小画布拖框改 rect；只动 App，P2 |
| R3b-G07 | 边框圆角 | 图 141 | 部分：边框宽和颜色（MixerState.swift:168–180） | 未规划（规格没提） | P2；提案 + 渲染器 |
| R3b-G08 | 输入分类（颜色 + 名字）和按分类筛选 | 图 001、069、151 | 无（Input.swift:427–435） | 未规划（规格没提） | 见 R3b-M11、E-4 |
| R3b-G09 | 卡片上的循环开关 | 图 001 | 部分：添加时可选循环（Input.swift:33–35、112），运行中改会重建输入（InputRuntime.swift:43–49） | v1 应有（设计方案 §1.2 视频文件输入）；播放器控制另见后续方案 §2.5 | 见 R3b-M15 |
| R3b-G10 | 卡片上"用快速转场送上 PGM" | 图 001 | 部分：autoTransition 命令（Command.swift:21）、快捷键动作"按已选转场执行"（Localizable.strings:259），格子上没有 | v1 应有（设计方案 §1.2 切换） | 见 R3b-M14、E-5 |
| R3b-G11 | 播放列表 | 图 139（入口）、图 001 底栏 | 无 | 后续方案 §2.5 | 底栏先不放按钮，等 2.5 |
| R3b-G12 | 多路录制（单独起停、格式页、Output 1–4 勾选） | 图 134 | 部分：ISO 分路录制随录制同一拍起停（BottomBarView.swift:195–213；docs/user/输出.md:27、31） | v1 应有（设计方案 §1.2 可 ISO 分路录） | 保持同拍起停，入口见 R3b-M05、E-2 |
| R3b-G13 | 统计窗口（每路 / 编码器 / 刷新 / 重置） | 图 152、154 | 部分：状态行 + stats.jsonl + API（StatusLineFormatter.swift:35–56；Stats.swift:27–51） | 未规划（设计方案 §10 只写了状态行） | 数据现成，只动 App，见 R3b-M21 |
| R3b-G14 | SRT 连接统计（时长 / 带宽 / 丢包 / 总量 / RTT） | 图 153 | 无：encoder[] 没有这些字段（Stats.swift:92–146） | 未规划（规格没提） | 推流走 SRT 时有用；要改 Stats，走提案，P2 |
| R3b-G15 | 快捷按钮面板 | 图 155 | 无（只有编辑器，HotkeyEditorPanel.swift:183–232） | 未规划（规格没提） | 见 R3b-M22 |
| R3b-G16 | PGM 截图存 PNG | 图 156 | 无 | 未规划（规格没提） | 见 R3b-M23 |
| R3b-G17 | 界面锁 | 图 157 | 无 | 未规划（规格没提） | 见 R3b-M24、E-8 |
| R3b-G18 | 数据源管理器（表格 / 在线表格 / JSON / RSS / 文本 / XML，自动下一行、轮询间隔） | 图 147、148 | 无 | 后续方案 §2.6 | 等 2.6（依赖 3.1 标题设计器）；入口将来放 ≡ |
| R3b-G19 | 触发器管理器（全部输入的触发器汇总表） | 图 149 | 无 | 后续方案 §5.4 | 等 5.4；入口将来放 ≡ |
| R3b-G20 | 音频总线路由矩阵（输入 × 总线，按类型 / 颜色筛） | 图 150、151 | 部分：每路条子里有总线送出（Input.swift:243–251 BusRouting；MixerPanelView 条子） | v1 应有（设计方案 §1.2 四条总线）；更多总线见后续方案 §4.1 | 矩阵视图只动 App（setInputSettings），P2；入口放 ≡ |
| R3b-G21 | 社交媒体工具 | 图 146 第 4 项 | 无 | 竞品自家服务或插件 | 不做 |
| R3b-G22 | 标题设计器 | 图 146 第 5 项 | 无 | v1 明确不做（§1.3）；后续方案 §3.1 | 不做 |
| R3b-G23 | 视频工具 / 媒体转换器 | 图 146 第 6、7 项 | 无 | 竞品自家服务或插件 | 不做 |
| R3b-G24 | 诊断工具 | 图 146 第 8 项 | 有：帮助 › 导出诊断包… / 打开诊断文件夹（AppDelegate.swift:154–158） | 后续方案 §8.1（已做） | 入口可以在 ≡ 里再放一份 |
| R3b-G25 | 在浏览器打开 Web 控制器（菜单项 + 快捷按钮面板里的按钮） | 图 146 第 9 项、图 155 | 无（只有 HTTP / WS API，docs/api.md） | 后续方案 §5.3 | 等 5.3 |
| R3b-G26 | 推流"全部开始"及单路起停快捷项 | 图 133 | 部分：主体全起全停（BottomBarView.swift:216–224），单路只能在设置里 | v1 应有（设计方案 §1.2 多目的地推流） | 见 R3b-M04 |
| R3b-G27 | 状态栏的整机 CPU、GPU 显存 | 图 001 | 无：Stats 只有进程 cpu_pct 和 GPU 利用率 gpu_pct（Stats.swift:46–51） | 未规划（规格没提） | 不加，见 E-7 |
| R3b-G28 | 添加输入 ▴ 快捷菜单 | 图 001 | 无 | 未规划（规格没提） | 见 R3b-M06 |
| R3b-G29 | 卡片上的显示器图标 | 图 001 | 无 | 未规划（规格没提，用途不明） | 先弄清用途（见 F）再定 |

## E. 需要用户拍板的问题

1. **外部输出按钮的意思**（R3b-M02）。(a) 主体 = 外部显示输出开 / 关，⚙ = 现在这个菜单；(b) 维持主体直接弹菜单。倾向 (a)：和录制、推流一个模式；现场"先把外部屏黑掉、再恢复"一下就能做到；现在的菜单选中 = 加输出、再选 = 删输出，关掉就丢配置，开关用 setOutputEnabled 能保留配置。
2. **ISO 放哪**（R3b-M05）。(a) 并进录制 ⚙ 的菜单，去掉单独的"ISO…"；(b) 学参考单独做"⚙ + ISO 起停"。倾向 (a)：PGM 和 ISO 同一拍起步是我们刻意做的（docs/user/输出.md:27），单独起停会让起点对不齐。
3. **叠加设置的形态**（R3b-M07）。(a) 独立非模态窗 + 通道选择，即时生效；(b) 保留 popover，只改朝上、改成一次一个通道。倾向 (a)：popover 是 transient，点一下格子的 1–4 或转场列就关了，边切边调做不到；独立窗也和我们其他设置窗一致。
4. **输入分类数据放哪**（R3b-M11）。(a) 放 ShowLayout（契约写明原样存取、键由 App 定，不改契约）；(b) InputConfig 加 category（提案，API / Stream Deck 能读到）。倾向先 (a)，等控制面板要按分类过滤了再提案。
5. **格子上的"转场"按钮用哪种转场**（R3b-M14）。(a) 按转场列当前选的类型和时长（autoTransition）；(b) 另设一个固定的短 Fade。倾向 (a)：落地方案 §7 第 2 条已定不做单独的快速转场类型（docs/plan/导播台落地方案.md:214）；按钮文案用"转场"，悬停写"按已选转场送上 PGM"。
6. **格子按钮的密度**（R3b-M14–M17）。(a) 两行常显；(b) 悬停才显示。倾向 (a)：藏起来就看不到叠加 / 静音的状态。代价是格子高出约 22 pt，缩略图条的最小高度（MainWindowController.swift:137，190 pt）要跟着调。
7. **状态行要不要加整机 CPU / GPU 显存**（R3b-M25、G27）。倾向不加：要改 Stats（提案）；我们已有 GPU 利用率、进程 CPU、丢帧，更直接。
8. **界面锁锁什么**（R3b-M24）。倾向只锁主窗口的鼠标（锁按钮本身除外），键盘快捷键、MIDI、API、菜单栏照常，独立窗口不锁。另一种是连快捷键一起锁，但现场容易被误以为程序坏了。
9. **统计窗的"重置"**（R3b-M21）。倾向在界面记一个基线再相减，stats.jsonl 和 API 不受影响（Stats 的累计值单调不减）；不做引擎侧清零。
10. **删除输入要不要确认**（R3b-M14、M19）。倾向：这一路在 PGM / PVW / 叠加 / Stinger 上时确认（删了 PGM 会变黑场，Command.swift:69），其余直接删。

## F. 读图备注

- 图 001：卡片第一行"Loop"后面的空白小格、第二行的显示器图标，用途都看不出（没有点开的图）。
- 图 001：状态栏"EX"含义不明；"1440p59.94"是绿字，是否随状态变色看不出。
- 图 023：状态栏 FPS 是 85，其他图都是 60，说明 FPS 是实测值，口径不明。
- 图 001、146：输入条最左那个灰色空白格没有字，推测是"全部 / 未分类"；分类标签怎么起名、点了是不是筛选，都没截到。
- 图 119：SRT 这一项在这张图上没画 ▸；图 123 悬停之后才看到子菜单（1–4 都是 Disabled）。
- 图 147：底部"Seconds""Update data every … Milliseconds"的字和背景几乎同色，按排版推断。
- 图 150：只看到"M"一列，其他总线列推测是因为没开启而不显示。
- 图 151：列表里有的项是黑色粗体、有的是灰色细体，推测是字体渲染差异，不是灰掉；列表在"Custom6"处被截断。
- 图 152：只有"Output"一行（两路 Blank 没有行）；"Renderer Dr…"列名被截断；Video 列"Fullscreen Dropped: 37224 0 430 (32 ms)"三个数各指什么看不出。
- 图 153：列名"Bandwidth (…""Packet Loss…"被截断，看不到单位。
- 图 155：瓦片大字"渐入""123"推测是用户给快捷键起的名字或键名；点瓦片的效果没截。
- 图 156：鼠标停在锁图标上（锁在悬停高亮），不在相机上；按索引和默认文件名里的"Capture"认定是相机的截图功能；截的是哪一路看不出。
- 图 157：锁上后界面其他部分没有可见变化，锁住拦什么看不出。
- 图 141–145：只截了窗口本身，看不到它在主窗口的哪个位置弹出。
- 以下没有截图，A 节里相关语义都标了（推测）：Add Input ▴ 的菜单、卡片右键菜单、Record / External / Stream / MultiCorder / PlayList 主体按钮点下去的效果（截图说明：没演示会改现场的动作）。
- 界面稿和参考的出入：稿子的小箭头朝下 ▾（界面稿:L346、L367），参考是朝上 ▴，菜单也朝上开（图 119、133、146）；稿子的分类是分段控件加四个不可点的色块，点了只换高亮不筛选（界面稿:L237–247、L578、L616–618）。
