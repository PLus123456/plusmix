# W5-H 输入条与格子报告（prompt 94，分支 w5-app-input-strip）

分支：`w5-app-input-strip`（worktree `.claude/worktrees/w5-app-input-strip-bc8951`，worktree 自己的分支名 `claude/w5-app-input-strip-bc8951`，两个名字指同一个提交）。
**92 / 93 都还没合进 main**（main = `190fe32`）：这个 worktree 是从 93 的分支头 `w5-app-toolbar` = `8a13a21`（93 本身叠在 92 的 `70d0cf3` 上）开的，
所以本分支 = 92 + 93 + 本会话；G7 按 92 → 93 → 94 的顺序合即可（94 只在 93 之上加提交）。
只动 App/ + 本报告 + 一张问题单（`reports/issues/W5H-w2-inputs-image-input-no-file-watch.md`）。契约 0 处。
`make lint BRANCH=w5-app-input-strip`：禁词 / 版本号 / Package.swift / 依赖方向通过；归属一项相对 main 只多出 `reports/w5-app-bottom-bar.md`、`reports/w5-app-toolbar.md`（92 / 93 的报告，跟着它们的提交带进来的，不是本会话改的；make 在这一步停下），
相对真正的基线 `scripts/check-ownership.sh w5-app-input-strip --base w5-app-toolbar --include-working-tree` = "21 个改动文件都在允许范围内"；后面两个自动挂的检查手动跑：check-links、check-rt-symbols 通过。
机器：MacBook Pro M5 Max（128 GB），macOS 27.0（26A428），Xcode 27.0（27A266a），接电源；内建屏 + LG ULTRAGEAR（2560×1440），屏幕没锁。

提交（`git log 8a13a21..HEAD`）：`183e2bb` 红灯轮（十条用例 + 新 API 只给签名）→ `55d7f33` 实现 → `cab881d` 输入条贴着格子 + 约束冲突（全量第一遍查出来的，§2.3）→ 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 格子两行按钮（D4 / D6 / D7 / Q26 (a)） | `UI/InputCellView.swift` | **第一行** ×（Q06 (a)：在 PGM / PVW / 开着的叠加 / Stinger / ISO 录制上先确认、其余直接删，87 的 `requestRemoval` 原样）｜ 转场 ｜ Cut ｜ 循环；**第二行** Overlay 1–4 ｜ 静音 ｜ ⚙。"转场" = 已在 PVW 上只发 `autoTransition`，否则 `setPreview(n)` + `autoTransition`（按转场列当前那组类型 / 时长，Q39）；"Cut" = `setProgram(n)`（直切，不经过 PVW）。**转场进行中**（快照 `transition.isActive`，T-bar 推到一半也算，90 报告 §5 第 1 条）两颗都灰、提示"转场进行中：等这次转场做完再切"；动作函数里再判一次（绕过置灰直接发动作也不发命令）；点缩略图 / Shift 点同样不发、状态行写"转场进行中：等这次转场做完再改 PVW / PGM"。PGM 上那一路两颗也灰（"已经在 PGM 上"：转到自己没意义）。提示里写当前那组："按已选转场送上 PGM（Fade · 0.5 秒）"，Cut 型写"（Cut）"。"循环"只对文件输入亮，开着高亮；点 = `setInputSource` 只改结束动作（开 loop / 关 holdLastFrame），非文件输入灰着写"只对视频文件输入"。"静音"对没有声音的输入（图片、不采声音的屏幕、无声合成源）灰着、提示写原因（D7）。⚙ = 这一路的输入设置，提示"输入设置（也可右键）"（D6）。全部按钮 `refusesFirstResponder`（空格仍是 Cut）。Shift 点击保留。快照里配置没变就不重设字 / 提示（92 的坑） |
| 1 循环不重建 | `Engine/InputRuntime.swift` | `reconcile` 认出"同一文件、同一速率、只差结束动作"：改在跑着的 `FileInput.endAction` 上（包里本来就是运行中可改的），`Entry.config` 就地换成新的，**不注销 / 不重建**，播放位置接着走。路径或速率变了照旧重建 |
| 1 格子高 / 缩略图条最小高 / V-23 | `UI/InputCellView.swift`、`UI/InputStripView.swift`、`UI/MainWindowController.swift`、`UI/Theme.swift` | 缩略图框的高 = 宽 × 裁切后那块（纹理像素）的高宽比（V-23：上下不再留黑边；1080p 默认布局 200 宽时 93 pt，原来 112.5）；所有格子取最高的那个（默认布局各格一样，自定义布局里扁的几格左右留边），不高于 16:9。**多出来的一行按钮（+18）基本被省下的黑边抵掉**：格子 20 + 93 + 3 + 16 + 2 + 16 + 3 = 153，"中"档输入条最小高 195（原来写死 190），贴着格子的高 197（= 原来的初始高）。最小高由输入条按格子算（`InputStripView.minimumHeight`），主窗口的分隔条上限、最小高约束、最小窗口都按它：中 / 小档在 W5-G 定的内容区 668（外框 1100×720）里放得下，**最小窗口没变**；大档（221）放不下时最小窗口跟着长高 |
| 2 右键菜单补齐（D8） | `UI/InputCellView.swift` | 送到 PVW ／ Cut 到 PGM ／ 按已选转场送上 PGM（Fade · 0.5 秒）／ Overlay ▸ 1–4（✓ = 这一路开在这个通道上）／ 分类 ▸ 无 + 六色（✓ 当前，起过名写名字）／ 静音（✓；无声输入灰、提示原因）─ 设置… ／ 换来源…（提示"直接打开输入设置的“来源”一节；换来源会重建这一路（文件从头播）"，点了开输入设置窗并停在"来源"一节）／ 重命名… ─ 删除输入 n（87 的条件确认）。前三项与格子按钮同一口径（转场中灰、已在 PGM 上的 Cut / 转场灰、已在 PVW 上的"送到 PVW"灰） |
| 3 输入条（D1 / D2 / D3 / D10 / G13） | `UI/InputStripView.swift`、`UI/InputCategories.swift`（新）、`UI/AddInputPlaceholderView.swift`（新）、`UI/MainWindowController.swift`、`AppDelegate.swift`、`AppController.swift` | 头一行：输入 ｜ **全部 + 六色**（Finder 标签那一套：红 / 橙 / 黄 / 绿 / 蓝 / 紫；没起名是 18 pt 色块，起了名写名字，选中白框）｜ 搜索框（常驻，窄窗口时先变窄，≥ 120）……右端 **"调音台"开关**。点分类 = 只显示这一类，**与搜索叠加**；再点一次已选的 = 回到全部；右键色块 = 改名… / 清除名字（sheet 里一个文本框，空 = 回到颜色名）。格子标题条上编号后面画一个分类色点（白边，压在红 / 绿 tally 底上也看得见）。**分类存 Show.layout**（Q14 默认：023 落地前先放这里，键名见 §4），算节目内容（改了标未保存，`AppController.documentContent` 不剥这两个键），删掉一路时它的分类跟着清。"调音台"开关 = 与"窗口 › 调音台"**同一个 nil target selector**（`toggleMixer(_:)`），开着高亮，拖分隔条收起 / 拉出也跟着亮灭。**⌘F** = "输入 › 搜索输入"，焦点进搜索框（回车 / Esc 照旧还给窗口）。末尾**虚线"＋ 添加输入"占位格**（和格子一样大，单击 = 底栏"添加输入"主体同一个入口，停在上次的类型；提示"添加输入（⌘I）"）；空节目时它是唯一一格，框里多一行"也可以把视频 / 图片文件拖到这里"（V-09）；搜索 / 分类把格子全筛掉时它也在。**拖放**：视频（movie / video 类型）/ 图片文件拖到输入条或占位格 = 直接加一路，编号依次取空号、名字用文件名、不弹面板，视频 = 文件输入（循环、1 倍速，同添加面板默认）、图片 = 图片输入；拖进来时整条描蓝边；不认得的文件跳过、状态行"跳过 1 个不是视频 / 图片的文件：说明.txt"；全是不认得的 = 不接（光标不变"+"）；号用满停下提示；也记进"最近添加" |
| 4 图片（G14） | `UI/AddInputSheet.swift`、`Engine/ImageFileWatcher.swift`（新）、`Engine/InputRuntime.swift` | 添加面板图片页的浏览面板**允许多选**：第一张进路径框，其余记下来，路径框下写"已选 3 张：每张加一路，名字用文件名"，名字框灰着（"按文件名"）；确定 = 每张一路（第一张用选的编号，其余依次取空号；空号不够全加就一路都不加、面板不关、写原因）；手改路径框 = 回到单张。图片页说明加了"可以一次选多张…文件在外面改了会自动换上——做字幕 / 台标：在图片软件里改好存盘，画面跟着变"。**改了自动换上**：`SwitcherInputs` 的 `ImageInput` 只在 start() 解码一次、自己不监视（问题单给 W2-A 系）；App 用 `DispatchSource` 盯解析后的路径（write / extend / attrib / delete / rename / link / revoke；改名盖过去 = 按路径重开；文件不在每 0.25 s 看一眼；一阵事件合成一次；ImageIO 看文件完整才换），变了让运行表对**同一个输入对象** stop 再 start（按同一条路径重新解码），帧槽 / 引擎注册 / ISO 分支都不动，PGM 停在上一帧、下一拍换上、不闪黑 |
| 5 缩略图三档（D11） | `UI/InputStripPreferences.swift`（新）、`UI/InputStripView.swift`、`AppDelegate.swift` | 小 160 / 中 200 / 大 256 宽，存本机（UserDefaults `inputThumbnailSize`）。入口：输入条空白处右键"缩略图大小 ▸"、菜单栏"窗口 › 输入缩略图 ▸"（同一份，当前打勾）。01a D11 建议放设置"节目格式与显示"页，设置体系归 96（W5-J），这里先放这两处。换大小 = 输入条贴回格子的高 |
| 顺手 | `UI/MainWindowController.swift`、`UI/InputStripView.swift` | ① 窗口缩小时输入条保持原高（W5-A 的设计）；**上半区因此放不下转场列、而输入条比最小高高**（被拖高过、大档换回中档）时，分隔条先把输入条退回最小高（原来差额全给上半区，转场列被压扁，§2.3）。② W5-G 报告 §5 第 9 条的**启动约束冲突修掉了**：分隔视图里输入条 / 调音台给初始 frame、输入条最小高约束 999（分隔视图直接设 frame，真正守最小高的是分隔条上限、最小窗口与 `updateInputStripMinimum`）、格子底边不钉死；先挪分隔条再改最小高约束。日志里的约束冲突 6 → 0 |

本地化：两份表各加 66 个键（`cell.*` 按钮 / 提示 / 右键、`category.*`、`strip.*`、`menu.input.find`、`menu.window.thumbnailSize`、`addInput.image.multi` / `addInput.error.notEnoughNumbers` / `addInput.name.byFile`、`list.separator`），改 1 个值（`addInput.image.hint`）。

## 2. 每个测试：数值 / 阈值 / 通过否

（功能用例，判据是行为 / 文案逐字相等与几何关系；没有数值阈值。全在 `App/Tests/InputStripTests.swift`。）

### 2.1 prompt 的六个测试 ID

| 测试 | 数值 / 看到的 | 判据 | 通过 |
|---|---|---|---|
| `testUI_inputCellButtonsRespectTransitionGuard` | 三路合成源、PGM 1 / PVW 2、Fade 120 拍。每格两行：第一行 [×, 转场, Cut, 循环]、第二行 [1, 2, 3, 4, 静音, ⚙]，都在格子里、同一行同高、从左到右不重叠、第一行在上，全部不抢焦点；⚙ 辅助功能名"输入 n 的设置"、提示"输入设置（也可右键）"；PGM 上的 1 号转场 / Cut 灰、提示"已经在 PGM 上"；3 号提示"按已选转场送上 PGM（Fade · 2 秒）" / "直切到 PGM（不经过 PVW）"。点 3 号"转场"：总线上新命令 = [setPreview(3), autoTransition]、来源都是 ui，转场开始。**转场中**：三格的转场 / Cut 全灰、提示"转场进行中：等这次转场做完再切"；每格 performClick 两颗 + 绕过置灰直接发动作 + Shift 点 / 点缩略图 → `commandsSent` 不变、总线上 0 条 ui 命令、状态行"转场进行中：等这次转场做完再改 PVW / PGM"；右键前三项也灰。做完 PGM 3 / PVW 1，按钮回来（3 号在 PGM 上那两颗仍灰）；2 号 Cut → 总线 [setProgram(2)]、PVW 仍 1。× ：哪儿都没用的 3 号直接删不问，PVW 上的 1 号先问（说明里有"PVW"），取消不删 | 逐项相等 | ✅ 2.9 s |
| `testUI_inputCellLoopToggleDoesNotRebuildInput` | Tests/Fixtures/pattern.mov（循环）+ 一路合成源：文件那格循环亮、高亮，合成源那格灰、提示"只对视频文件输入"。关循环 → 快照来源 = `.file(同一路径, holdLastFrame, 1)`；**输入对象与帧槽的 ObjectIdentifier 不变**、跑着的 FileInput.endAction = holdLastFrame、不高亮；PGM 帧号 12 → 49（Δ 37，没从头播），播放位置 0.217 → 0.833 s。再开 → loop、对象仍不变。换路径（setInputSource 到另一个文件）→ 重建（对象变了） | 逐项相等；帧号接着走（Δ ∈ 20…120） | ✅ 1.2 s |
| `testUI_categoryFilterHidesOtherInputs` | 四路。标签 [全部, 红色, 橙色, 黄色, 绿色, 蓝色, 紫色]、默认全部。格子右键"分类 ▸"[无, 红色…紫色]：1、3 红，2 蓝 → 色点、✓；`layout["inputCategories"]` = {1: red, 2: blue, 3: red}；标未保存。点红 → [1, 3]；再搜"3" → [3]；清搜索 → [1, 3]；点蓝 → [2]；点全部 → [1, 2, 3, 4]；红点两次 → 回到全部。右键红色标签 [改名…]；改名"机位" → 标签写"机位"、辅助功能名"红色 · 机位"、`layout["inputCategoryNames"]` = {red: 机位}、分类 ▸ 里写"机位"、右键多了"清除名字"。存盘 → 重新打开：1、3 红、名字还在、点红 = [1, 3]。删 3 号 → 分类表里没了它、筛选剩 [1] | 逐项相等 | ✅ 1.6 s |
| `testUI_dropVideoFileAddsInputWithFreeNumber` | 已有 1、2、4。只拖 .txt → 不接（[]）。拖 [pattern.mov, 台标.png, 说明.txt] → 接（copy）、整条高亮、放下返回 true、高亮收回；**3 = "pattern.mov"、`.file(路径, loop, 1)`；5 = "台标.png"、`.image(路径)`**；不弹添加面板；状态行"跳过 1 个不是视频 / 图片的文件：说明.txt"；3、5 都 live；最近添加的第一项是那张图。拖到占位格上 → 6 = 同一张图 | 逐项相等 | ✅ 0.5 s |
| `testUI_emptyShowShowsAddPlaceholder` | 空节目：条里只有占位格；"＋ 添加输入"、小字"也可以把视频 / 图片文件拖到这里"、提示"添加输入（⌘I）"、辅助功能名"添加输入"、虚线框；在条里看得见、宽 200（同格子）。点 → 添加面板弹出（取消）。加两路后占位格在最后、小字收起；搜索把格子全筛掉时占位格仍在 | 逐项相等 | ✅ 0.6 s |
| `testUI_imageInputReloadsWhenFileChanges` | 1280×720 红图上 PGM。**原子替换**（replaceItemAt）成蓝图 → 99 ms 后 PGM 中心是蓝的；**原地覆盖**（截断再写）成绿图 → 72 ms 后是绿的；输入对象 / 帧槽的 ObjectIdentifier 都没变、快照来源没变、仍 live。删掉这一路 → `watchedImagePaths` = [] | 逐项相等；2 s 内换上（实测 < 0.1 s） | ✅ 0.7 s |

### 2.2 补充用例

| 交付 | 测试 | 数值 / 看到的 | 通过 |
|---|---|---|---|
| D8 | `testUI_inputCellContextMenuComplete` | 2 号（PVW 上、无声合成源）右键 = [送到 PVW, Cut 到 PGM, 按已选转场送上 PGM（Fade · 0.5 秒）, Overlay, 分类, 静音, ─, 设置…, 换来源…, 重命名…, ─, 删除输入 2]；换来源的提示逐字；静音灰、提示"这一路没有声音（合成源没开音频）"，格子上的静音按钮同样；Overlay ▸ 2 开 → 通道 2 = 输入 2、✓，再点关；1 号（PGM 上）Cut 灰；1 号送到 PVW → PVW 1；2 号 Cut 到 PGM → PGM 2；类型改 Cut 后标题"按已选转场送上 PGM（Cut）"，点了 PGM 1；换来源… → 输入设置窗停在"来源"一节；"删除"前是分隔线、在最后 | ✅ 0.5 s |
| D11 | `testUI_thumbnailSizeThreeStepsPersist` | 右键 [小, 中, 大]、默认中 ✓；三档格子宽 [160, 200, 256]、输入条最小高 [176, 195, 221]，占位格同宽，齿轮在可见区；UserDefaults 存 small / medium / large；大档缩到最小窗口：输入条 ≥ 最小高、上半区放得下转场列；换回中档：输入条 = 最小高 + 2、最小内容区回到 668；"窗口 › 输入缩略图 ▸"同一份、勾跟着 | ✅ 1.1 s |
| 顺手 | `testUI_stripGivesBackHeightWhenWindowShrinks` | 1440×900 把输入条拖到 300，缩到最小窗口：输入条 201（最小 195）、上半区 408（= 转场列最小高）。修之前同样的情形（大档换回中档后输入条 221）上半区 388 | ✅ |
| G14 | `testUI_addImagePanelMultiSelectAddsOnePerFile` | 已有 2 号；图片页多选 3 张 → 路径框 = 第一张、"已选 3 张：每张加一路，名字用文件名"；确定 → 1、3、4 号 = 片头.png / 台标.png / 字幕条.png；图片页说明里有"字幕" | ✅ 0.7 s |
| D2 / D3 / V-23 | `testUI_stripMixerToggleFindShortcutAndCroppedThumbnail` | "调音台"开关 action = 窗口菜单"调音台"的 action、两边 target 都 nil、不抢焦点、开着 = 强调色；点 → 收起、不高亮；从菜单点 → 拉出、开关跟着高亮；在输入条右端（右缘 −8）。"输入 › 搜索输入" ⌘F，点了焦点进搜索框。缩略图框 200 × 93，高宽比 = 裁切后那块的 0.4632（±0.01），比 16:9 的框矮 | ✅ 0.6 s |

### 2.3 全量（`make test-app XCB_FLAGS=`，xcresulttool 核过）

| 轮次 | 结果 | 说明 |
|---|---|---|
| 第一遍（`55d7f33`，22:46–22:51） | 171 条：166 过、3 跳、**2 红** | ① `MainWindowLayoutTests.testUI_splitKeepsInputStripMinimum`：最小窗口上半区 388 < 转场列 407.5——**本会话引起的**：前面 `InputStripTests` 的三档用例大档换回中档后，输入条留在 221 高（窗口缩放时输入条保持原高是 W5-A 的设计），缩到最小窗口差额全落在上半区。这也是产品问题（用户把输入条拖高再缩窗口一样），`cab881d` 修：换大小贴回格子的高 + 上半区放不下时先收输入条（§1 顺手 ①，补了一条用例）。② `RecordingTests.testRecord_5sTwoTracksDurationExact`：起止拍差 318 vs 按钮间隔 316.7 拍（差 1.29 > 1 帧）——当时另一个会话在编译（`swift-build` + 12 个 `swift-frontend`，负载 12），92 报告记过这条在负载高时红（±1 帧）；单独复跑见下一行 |
| 第二遍（`cab881d`，22:56–23:01，机器安静、负载 ~3） | **172 条：169 过、3 跳、0 红**（xcresulttool：result Passed / totalTestCount 172 / passed 169 / failed 0 / skipped 3，313 s）；整个日志里约束冲突 0 条 | 上一遍红的两条都过：`testUI_splitKeepsInputStripMinimum`（1440×900 输入条 197 / 调音台 340 / 上半区 592；最小窗口 1100×720 输入条 197 / 上半区 412，与 93 报告的数一样）、`testRecord_5sTwoTracksDurationExact`（录制起止 = 按钮间隔 ± 1 帧，没改它）；ISO A4（三路同拍）12.7 s 过 |

跳过的 3 条与 93 相同：内置摄像头 BLOCKED-权限、虚拟摄像头出画 BLOCKED-签名、键盘导航 BLOCKED-系统设置（92 留下的那条，系统设置归用户）。release frameprobe 先编好了，ISO A4 / 推流端到端 / 录制"按钮间隔 ± 1 帧"都是真跑的。

### 2.4 红灯轮

`183e2bb` 上只跑新用例：**十条全红**，红在各自要验的点上：按钮行是空的、右键菜单只有三项、分类标签 0 个、拖放不接、占位格不在条里、改了图片画面不变、循环开关把这一路重建了（帧号 8 → 160，跳了）、调音台开关没有动作、缩略图大小菜单是空的、图片面板不能多选。

## 3. 没做的和原因

1. **prompt 写明不做的**：播放 / 暂停 / 从头（101，等提案 021）、分类进契约（023 的 color 一节，P5 落地）、包（ImageInput 自己监视文件 → 问题单 `W5H-w2-inputs-image-input-no-file-watch`）。
2. **缩略图大小没放进设置页**：01a D11 建议放"节目格式与显示"页，设置体系归 96（W5-J 合窗）；现在入口是输入条右键与"窗口 › 输入缩略图 ▸"，96 合窗时可以挪进去（`InputStripPreferences` 一处读写）。
3. **关循环 = 停在最后一帧**：循环是开关，结束动作有三种（loop / holdLastFrame / black）；原来是 black 的那一路开了循环再关，回到的是 holdLastFrame 而不是 black（要回到黑场去输入设置"来源"一节改）。没记"关循环之前是什么"：那要么存进配置（契约）要么存 layout，都不值。
4. **图片换上的代价**（问题单里写全了）：解码在主线程（与"加一路图片"同一条路，1080p PNG 几毫秒，4K 大图更久）；stop → start 之间状态短暂是 noSignal，碰上快照格子会闪一下"无信号"（≤ 1 拍）；图片输入建的时候文件就不在（占位输入）的，文件后来出现不会自动建（要"应用来源"）。包里做 `reload()`（后台解码好再原子换缓冲）就都没了。
5. **真拖放的命中测试没测**：AppKit 不让合成真的拖动会话，用例用 NSDraggingInfo 替身直接调输入条 / 占位格的拖放方法；"拖到格子上（缩略图 / 按钮上方）也算拖到输入条"靠 AppKit 沿父视图找注册了类型的视图，格子自己没注册。人工清单项：从 Finder 拖一个 .mov 到格子上、到占位格上、到空白处。
6. **数字键 / Shift + 数字在转场中**：90 报告建议状态行提示一句；那条走 HotkeyDispatcher（SwitcherControl），不在本会话目录。格子上的点击已提示。
7. **分类只在 App 里**：API / 多画面标签 / 兼容层 / Stream Deck 都看不到分类，要等 023。
8. **"全量 0 失败"**：达成（§2.3 第二遍 172 条 0 红）；第一遍的录制 ±1 帧红是别的会话同时编译时的负载，第二遍安静时过。

## 4. 对契约的疑问

没有改契约。给 **023（P5，InputConfig.color）的迁移说明**——分类现在存 Show.layout 的两个键（`InputCategories.Keys`）：

```json
"layout": {
  "inputCategories":     { "1": "red", "3": "red", "2": "blue" },
  "inputCategoryNames":  { "red": "机位" }
}
```

- `inputCategories`：键 = 输入编号（十进制字符串），值 = 颜色，取值 `red` / `orange` / `yellow` / `green` / `blue` / `purple`（Finder 标签那六种）；没分类的编号不写。
- `inputCategoryNames`：键 = 颜色，值 = 名字（非空）；只写起过名的。
- 两个键没内容时整个键不写。认不出的条目读的时候跳过。
- 迁移建议：`InputConfig.color`（可选，同上六个取值）= `inputCategories[编号]`；**分类名字是节目级的**（"红色 = 机位"对所有输入一样），不该放进每路 InputConfig——建议 023 另给 Show 一个可选的 `categoryNames`（或留在 layout 里不迁）；迁完 App 读新字段、旧 layout 键在 `Show.load` 搬一次后删掉（与 W3-B2 搬 `extra["layout"]` 同一个做法）。改分类那时就成了一条命令（现在是 App 直接改 `session.layout`，不过总线、API 看不到）。

## 5. 下一个会话需要知道的坑

1. **输入条的最小高不再是常量**：`InputStripView.minimumHeight` = 头一行 30 + 上下留白 12 + 格子高（标题条 20 + 缩略图框 + 两行按钮 40）；"中"档 195、贴着格子的高 197（= W5-A 的初始高），小 176、大 221。`Theme.inputStripMinimumHeight` 删了；别再写死 190。最小窗口在中 / 小档仍是 W5-G 定的内容区 668（外框 1100×720），大档会长高。
2. **缩略图框高跟布局走**：按裁切后的比例算、所有格子取最高（`InputStripView.relayoutThumbnails`）。默认布局 ≤ 8 路 4×2、9 路起 6×3，格子比例不同，所以路数跨过 8 / 18 时缩略图框高、输入条最小高会变几 pt（`onMinimumHeightChange` 已接好）。
3. **测试串味**：缩略图大小是本机记忆、输入条高度留在窗口里——前一条用例换了大档，后面量最小窗口的用例就红（§2.3）。`AppTest.freshSession` 现在会 `stripPreferences.reset()` 并 `setThumbnailSize(.medium)`（贴回 197）；往后加改输入条高度的用例，收尾也要还原。
4. **分类数据不在快照里**：存 `session.layout`（`MainWindowController.storeCategories`），不是命令、不进总线；改了靠 `onDocumentContentChanged` 让 AppController 重算未保存，`AppController.documentContent` 只留 layout 里这两个键。换 session 时**先设 `inputStrip.categories` 再挂快照观察者**（观察者一挂上就回调，反过来会把旧节目的分类按新输入表清理后写进新节目）。
5. **静音按钮对无声输入是灰的**：老用例里点合成源静音的要用带音频的源（`AppTest.syntheticConfig(number:audio: true)`；`AddInputModel.syntheticAudio` 默认 false）。本会话改了两条：`UISmokeTests` 第 1 步 2 号带音频、`TransitionColumnTests.testUI_highlightedTitlesAreWhite` 加一路带音频的 3 号来点（判据都没动）；`LiveSafetyTests.testUI_deleteInputOnProgramAsksConfirmation` 的右键菜单结构改成"删除在最后、前面是分隔线、一共两条分隔线"。
6. **格子右键菜单从 `contextMenu()` 来**（`menu(for:)` 只是转一下）：测试直接调它；菜单项是闭包项（`NSMenuItem.action`，`autoenablesItems = false`），触发用 `item.target?.perform(item.action, with: item)`。
7. **转场中挡命令看的是快照**（≤ 60 Hz）：快照落后一帧时按下去，命令照发、reducer 拒（applied = false），不会跳画面——就是没有"转场进行中"的提示。
8. **拖放用例的替身**：`DropInfo`（InputStripTests.swift 末尾）实现 NSDraggingInfo 要写成 `@preconcurrency NSDraggingInfo`（Swift 6 下这个协议不是 MainActor 的）。
9. **`xcodebuild … -quiet` 偶发**一行 `error: the following command failed with exit code 0 but produced no further output`、不编（本会话碰到两次，都是 `make gen` 之后 / 别的会话在编的时候）；去掉 `-quiet` 重跑一次就 `TEST BUILD SUCCEEDED`。
10. **两份 Localizable.strings 又动了**（+66 键、改 1 个值）：95–98 也改这两个文件，G7 合并时按键解冲突。本会话跑的时候同机已有 `w5-app-settings-actions`（96，也开在 8a13a21）与 `w5-app-misc`（98）两个分支，都动 App/；96 合窗时缩略图大小可以挪进设置页（§3 第 2 条）。
11. **启动约束冲突现在是 0**：分隔视图里输入条 / 调音台的初始 frame 别改回 `.zero`，输入条最小高约束是 999 不是 required（注释写了为什么）；往输入条里加东西时先挪分隔条再改高度相关的约束。
12. **手册要跟着改（不在本会话目录，给 103 / G7）**：docs/user 里输入条与格子的部分——两行按钮各是什么、转场中为什么是灰的、循环开关、静音灰的原因、⚙、右键菜单、分类标签（点 = 筛选、右键改名）、调音台开关、⌘F、"＋ 添加输入"占位格、拖文件进来、图片多选与改了自动换上、"窗口 › 输入缩略图 ▸"；en 同步。
