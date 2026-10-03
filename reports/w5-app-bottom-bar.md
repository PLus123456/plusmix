# W5-F 底栏三段式报告（prompt 92，分支 w5-app-bottom-bar）

分支：`w5-app-bottom-bar`（worktree `.claude/worktrees/w5-app-bottom-bar`），从 G6 合入后的 main `190fe32` 开。只动 App/ + 本报告（`make lint BRANCH=w5-app-bottom-bar` 全绿：禁词 / 版本号 / Package.swift / 依赖方向 / 归属 / check-links / check-rt-symbols）。
机器：MacBook Pro M5 Max（128 GB），macOS 27.0（26A428），Xcode 27.0，接电源；本机装了 mediamtx（推流 ▴ 的端到端那段真推）。显示器：前两遍全量时只有内建屏，第三遍起 LG ULTRAGEAR（2560×1440，在内建屏上方）接回来了——外部显示主体的两支（没有第二块屏 → 弹菜单；第一块非主屏上开 PGM）都实测到了。

提交（`git log 190fe32..HEAD`）：`d0b8eec` 红灯轮（六条用例 + 新控件，新 API 只给签名、行为照旧）→ `49eb5af` 实现 → `12de2cb` 主体按钮标题 / 提示没变不重设（全量查出来的，§2.5）→ 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 分体控件 | `UI/SplitBarButton.swift`（新） | `SplitBarButton`：⚙（SF Symbols 通用齿轮）｜ 主体 ｜ ▴（上箭头），三段各自可隐藏——没给动作的那段 `isHidden`，NSStackView 不给它排位置，可见的几段挨着排（间距 1 pt）。⚙ / ▴ 的动作是 `.menu { 现建菜单 }` 或 `.perform { … }`；菜单一律 `BottomBarPopup.popUp`（W5-A 的朝上帮助函数：换算到屏幕坐标再弹）。三个按钮 `refusesFirstResponder = true`（C9，键盘导航实测见 §5 第 1 条）；⚙ / ▴ 只有图标，辅助功能名与提示写全（"录制设置 / 录制快捷菜单"）。顺带 `NSMenuItem.action(标题) { 闭包 }`：闭包盒子挂在 representedObject 上跟菜单项同生共死 |
| 2 顺序（E2 / K2） | `UI/BottomBarView.swift` | 两行：上一行 左组 添加输入 ▴ ｜ ⚙ 录制 ▴ ｜ ⚙ 外部显示 ｜ ⚙ 推流 ▴ ｜ ⚙ 多画面，右组 叠加（贴右边 8 pt）；下一行状态行（交付 8）。单独的"ISO…"按钮去掉，ISO 页从录制 ⚙ 菜单进 |
| 3 录制（K1 / K3） | `UI/BottomBarView.swift` | ⚙ 朝上弹"录制设置… / ISO 分路录制…"；主体照旧 PGM + ISO 同一拍一起起停（有意保留）；▴ 每个录制输出一行"名字 · 状态"（`OutputButtonSummary.routeState`，Stats.encoder 按 output 对号；✓ = 在录、横杠 = 开着但没录上 / 起不来、空 = 没开），点 = 只停这一路（先确认，确认框只列这一路）；没开的路灰着（不给中途单独开始，提示写原因）；末尾"全部停止"（先确认） |
| 4 推流（L1 / L2，G6 追加 ① ②） | `UI/BottomBarView.swift`（`StreamMenuRow` 纯函数）、`AppDelegate.swift`、`UI/PanelCoordinator.swift`、`Settings/OutputSettingsPanel.swift`、`Engine/OutputRuntime.swift` | ⚙ = 输出设置 › 推流页；没有目的地时主体不灰，点了打开推流页、焦点放在"添加目的地"的地址框（`requestAddDestinationFocus` → `@FocusState`）；有目的地时主体维持 W5-B 口径。▴ = 全部开始（没开的开、起不来的重试）/ 全部停止（连起不来的那一路一起停，先确认）｜ 每个目的地一项（✓ = 在推，标题"名字 · 状态 · 码率"——码率只在推流中时写；点 = 没开的只开它、在跑的只停它〔先确认〕、起不来的只重试它）｜ 推流设置… / 推流状态…（101 之前都指向推流页）。没有目的地时多一行"添加推流目的地…"。菜单栏"输出 › 推流 ▸"同一份（打开"输出"菜单时按 `bottomBar.streamMenu()` 重建）。菜单与提示里只写目的地名字和**打过码**的地址（`StreamURLRedaction.redact(url:)`）；起不来原因里"地址不认：…"那一种原来带原文，也打码（`OutputRuntime.streamErrorText`） |
| 5 外部显示（M1–M4） | `UI/ExternalOutputMenu.swift`、`UI/MainWindowController.swift`、两份 `Localizable.strings` | ⚙ = 路由菜单，每块屏一段**单选**：这块屏有配置时最上一行"关闭"（setOutputEnabled false，配置留着），下面是源；勾 = 正在输出的源，关着的那一路标"PGM（已关）"；点源：已有输出 = `setOutputSettings` 换源（窗不重开；名字还是菜单起的"屏 · 旧源"就跟着改名）并打开、同屏别的路关掉，没有 = `addOutput`。倒数第二段照旧"删除 n …（状态）/ 关闭全部外部显示"，最后一段"外部显示设置… / NDI® 发送设置…"（M3）。主体 = `ExternalOutputMenuBuilder.toggleAll`：有开着的 → 全部关；都关着 → 全部按原配置开（每块屏一路）；一路都没配 → 第一块非主屏上开 PGM；没有第二块屏 → 底栏从主体弹路由菜单。开着高亮，提示逐路写状态（Stats.display[]）。93 的工具条正中可以直接用 `externalOutputMenu()` / `toggleExternalDisplays()`。M4：底栏、菜单（输出 › 外部显示设置… / 外部显示 ▸）、偏好设置、提示、外部窗口标题都叫"外部显示"（en：External Display） |
| 6 多画面（E3） | `UI/BottomBarView.swift`、`UI/MultiviewWindowController.swift` | ⚙ = 输出设置 › 多画面布局页；主体 = 窗口开 / 关，开着高亮（`onOpenChange`：点窗口自己的关闭按钮也会取消高亮） |
| 7 添加输入（G1 / Q59） | `UI/AddInputHistory.swift`（新）、`UI/MainWindowController.swift`、`UI/AddInputSheet.swift`、`AppDelegate.swift` | 主体（和 ⌘I）= 添加面板停在上次添加用的类型（本机记忆，UserDefaults；第一次是合成测试源）；▴ = 八种类型直达（"摄像头 / 采集卡…"……，面板停在那一页）─「最近添加」（最多 5 个、新的在前、同一来源只留一次，文件 / 图片不在了不列）点 = 不弹面板直接加一路：编号取空号、名字按类型自动取（与面板默认名相同）；输入满了这几项灰、提示"本节目的输入已满"。菜单栏"输入 › 按类型添加 ▸"同一份 |
| 8 状态行（E9 / V-22 / Q45） | `UI/StatusBarView.swift`（新）、`UI/StatusLineFormatter.swift`、`UI/Theme.swift` | 状态行独立成窗口最底一行、全宽（20 pt，顶上 1 pt 分隔线；底栏总高仍 58，主窗口其余布局不动）；左边 Stats 那一行，左右各留 10 pt、两段文字上下居中；格式写短"1080p60 / 1080p59.94"（非 16:9 写"1080×1920p30"）；字段名全走本地化表（中文界面"节目 / 帧率 / 渲染 / GPU / CPU / 丢帧 / 编码跳帧 / 码率 / 磁盘"，原来 fps / render 是英文）；右端是提示文字（强调色，4 s 后清），平时是本机信息"Apple M5 Max · 128 GB"（sysctl 芯片名 + 物理内存，启动时取一次，不进 Stats） |
| G6 追加 ③ | `UI/MainWindowController.swift` | 调音台 340：`setPosition` 与 `constrainMaxCoordinate` 都减掉分隔条厚度（原来 339） |
| 顺带（全量查出来的） | `UI/BottomBarView.swift` | 主体按钮的标题 / 提示没变就不重设（原来每个快照 ≤ 60 Hz 都重设，整窗跟着重新布局，点按钮发命令忽早忽晚，见 §2.5） |
| 顺带（E1 的新冲突） | `UI/BottomBarPopup.swift`（`BottomBarPanel`）、`UI/MainWindowController.swift` | 叠加挪到右组（窗口最右）以后，W5-A 的 NSPopover 以按钮为中心摆，伸出窗口右沿 144 / 174 pt（1440 / 1100 宽，全量第一遍 `BottomBarPopupTests` 红出来的）；NSPopover 没有公开办法挪箭头，换成没有箭头的 `BottomBarPanel`：朝上、贴按钮上沿 4 pt，按钮在窗口右半边时右缘对齐按钮（左半边左缘对齐），再夹进窗口（各留 8 pt）；系统弹出层材质 / 圆角 / 阴影；照 transient：点外面 / Esc 收起，点锚点按钮本身由按钮开关；挂在主窗口当子窗口；不抢键盘焦点；换 session 时收起（模型绑的是旧 session）。97（叠加改独立窗）以后可能就不用了 |

## 2. 每个测试：数值 / 阈值 / 通过否

（功能用例，判据是行为 / 文案逐字相等与几何关系；没有数值阈值。）

### 2.1 本会话的用例（App/Tests/BottomBarSplitTests.swift）

| 交付 | 测试 | 数值 / 看到的 | 判据 | 通过 |
|---|---|---|---|---|
| 1 2 | `testUI_bottomBarButtonsAreSplitAndPopupsOpenUpward` | 左组 x = 添加输入 < 录制 < 外部显示 < 推流 < 多画面，叠加在它们右边、离右沿 ≤ 16；三段可见性 [⚙, 主体, ▴] = 添加输入 [否 是 是]、录制 [是 是 是]、外部显示 [是 是 否]、推流 [是 是 是]、多画面 [是 是 否]；隐藏的段不留洞（段间 ≤ 4 pt）；没有标题含"ISO"的按钮；底栏 16 个 NSButton（5 个分体 × 3 段，含隐藏的段，+ 叠加）全部 refusesFirstResponder、acceptsFirstResponder = false；⚙ / ▴ 的辅助功能名 = "录制设置" / "录制快捷菜单"……；点过录制主体后 firstResponder 不是按钮、空格 = Cut（PGM 1 → 2）；五个弹出菜单（添加输入 ▴、录制 ⚙ / ▴、外部显示 ⚙、推流 ▴）在 1440×900 与 1100×700 下都朝上、整块在窗口里、不用子菜单（第三遍全量时主窗口在 LG 上、菜单真弹出来了，CGWindowList 实测：五个菜单底边都在按钮上沿之上 4 pt、整块在窗口里，例如外部显示 ⚙ 268 × 416、推流 ▴ 148 × 176；前两遍测试宿主不在前台、菜单没真弹，退到和 popUp 同一个定位点算的位置：底边比上沿低 1 pt，判据 ≥ 上沿 − 1）；推流 ⚙ → 推流页、多画面 ⚙ → 多画面布局页；录制 ⚙ 菜单 = ["录制设置…", "ISO 分路录制…"]，分别打开 录制 / ISO 页 | 逐项相等 | ✅ 9.9 s |
| 4 | `testUI_streamMenuListsDestinationsWithState` | 纯函数：在推（6.02 Mb/s）/ 起不来 / 没开三路 → ["主平台 · 推流中 · 6.02 Mb/s", "备用 · 起不来", "推流 3 · 未开"]、勾 [✓, –, 空]、点 [停, 重试, 开]、起不来的提示含原因。端到端：空节目推流主体可点，点了打开推流页、`addDestinationFocusRequests` = 1、firstResponder 是"添加目的地"地址框的字段编辑器；空节目 ▴ 的全部开始 / 全部停止都灰。主平台推本机 MediaMTX（s2）、备用 `foo://alice:hunter2@example.com/live`：▴ 全部开始（不问）→ 主平台 publishing、备用 failed；菜单头两项 [全部开始, 全部停止]，"主平台 · 推流中 · x Mb/s" ✓、"备用 · 起不来" 横杠，有"推流设置… / 推流状态…"；所有标题 / 提示与主体标题 / 提示里没有 alice / hunter2，备用的提示里地址是 `foo://<redacted>@example.com/live`；点备用 = 单路重试（不问、主平台推流对象 `===` 原来的、备用又报了一次原因）；点主平台 = "确定停止推流（1 路）？"、正文只有主平台 → 只停它，备用 enabled 仍为真；再点停了的主平台 = 只开它；全部停止 = "确定停止推流（2 路）？" → 两路都停、起不来的原因清掉；菜单栏 输出 › 推流 ▸ 的标题列表与底栏 ▴ 相同；"推流状态…" → 推流页；拒收 0 | 逐项相等 | ✅ 6.5 s |
| 3 | `testUI_recordMenuStopsSingleRoute` | PGM 录制 + ISO 2 + ISO 3，主体一起起 → ▴ 行 ["录制 · 录制中", "ISO 2 · 录制中", "ISO 3 · 录制中"] 全 ✓、末项"全部停止"、没有带"开始"的项；点 ISO 2 → "确定停止录制（1 路）？"、正文含 ISO 2 → 只 ISO 2 停并封口，PGM / ISO 3 照录、录制器没动；ISO 2 那一行变 "ISO 2 · 未开"、灰、没勾；主体"● 录制中（2 路）"；全部停止 → "确定停止录制（2 路）？" → 都停、全部停止灰、主体"录制"；拒收 0 | 逐项相等 | ✅ 2.5 s |
| 5 | `testUI_externalDisplayBodyTogglesAllKeepingConfig` | 一路都没配点主体：一块屏时（前两遍全量）→ 弹路由菜单、不加输出；两块屏时（第三遍起）→ 在 LG（第一块非主屏）上开一路 PGM、enabled；主屏那一段没配置时没有"关闭"；选 PVW → addOutput、PVW ✓、开窗；选 PGM → 同一个输出 setOutputSettings、同屏只有 1 路、外部窗口对象 `===` 原来的、只有 PGM ✓；关闭 → enabled false、配置在、"关闭" ✓、"PGM（已关）"；再选 PGM → 开；主体 → 全部关（编号与设置都不变、窗口全收、取消高亮）→ 再点全部开（同一批编号）；菜单最后一段 ["外部显示设置…", "NDI® 发送设置…"] 分别打开 外部显示 / NDI 页；菜单标题"外部显示"；zh 表里没有含"外部输出"的值、en 表里没有"external output"；拒收 0 | 逐项相等 | ✅ 1.0 s |
| 7 | `testUI_addInputMenuRecentReAddsWithFreeNumber` | ▴ 头八项 = 面板左栏顺序的八种类型 + "…"；没有最近添加时不列那一段；主体打开面板停在合成测试源 → 加 30 fps 合成源（1 号）；▴ "视频文件…" → 面板停在视频文件页 → 加 Tests/Fixtures/pattern.mov（2 号）；主体再开 = 停在视频文件页；最近添加两项、pattern.mov 在前；删 1 号后点合成源那一项 → 不弹面板、加回 1 号、来源 30 fps、名字"合成 1 · 30"；再点 → 3 号；菜单栏 输入 › 按类型添加 ▸ 与 ▴ 标题相同、"添加输入…"仍是 ⌘I；连记 5 种合成源后最近添加 5 项、不重复；拒收 0 | 逐项相等 | ✅ 2.3 s |
| 8 | `testUI_statusLineIsFullWidthBottomRow` | 1440×900 与 1100×700：状态行 minY = 0、minX = 0、宽 = 内容区宽；五个分体按钮与叠加都在它上面；左字距左沿 = 右字距右沿；两段文字中线 = 状态行中线（±1）、右端不压左边；formatText：1080p60 / 1080p59.94 / 2160p30 / 1080×1920p30；屏上那行以"节目 1080p60  ·  "开头且 = Stats 算出来的整行；字段名 zh ["节目", "帧率", "渲染", "GPU", "CPU", "丢帧", "编码跳帧", "码率", "磁盘"]、en ["Program", "FPS", "Render", "GPU", "CPU", "Dropped", "Enc. skipped", "Bitrate", "Disk"]；右端平时 = "Apple M5 Max · 128 GB"、不在 Stats 的 JSON 里；提示"测试提示"出现、4 s 后回到本机信息、displayedNotice 清空；调音台 340（收起再展开也是 340） | 逐项相等 | ✅ 6.1 s |
| C9 | `testUI_spaceNotEatenByBottomBarButtonsWithKeyboardNavigation` | 系统"键盘导航"关着 → 跳过 | BLOCKED-系统设置（解锁：系统设置 › 键盘 › 键盘导航打开后跑这一条：Tab 走 40 步焦点都不落在底栏按钮上、空格 = Cut） | ⏭ |

### 2.2 改到新控件上的旧用例（不删断言；三处随 spec 改了判据，逐条列出）

| 用例 | 改了什么 |
|---|---|
| `BottomBarPopupTests.testUI_bottomBarPopupsStayInsideWindow` | 外部显示菜单的锚点从主体换成 ⚙（主体现在是全部开关）；判据不变。第三遍全量实测（两块屏 × 6 路）：外部显示菜单 268 × 608，1100×700 下底边在按钮上沿之上 4 pt、顶边离窗口上沿 37 pt；叠加弹出层判据不变（整块在窗口里、朝上、内容 400 × min(640, 内容高 − 120)），实现从 NSPopover 换成 BottomBarPanel 后 1440×900 是 (x, 底边 = 按钮上沿 + 4, 400, 640)、1100×700 是 (…, 400, 548)，右缘离窗口右沿 8 pt |
| `BottomBarPopupTests.testUI_externalMenuFlatChecksEnabledAndTogglesOutput`、`ExternalOutputAppTests.testExternal_menuListsDisplaysAndSources_marksExisting` | 段数 +1（末尾设置段，M3）；删除段从"最后一段"改成"倒数第二段"；"再点有勾的 PVW = 关（不删）"改成"点'关闭' = 关（不删）"、"再点 = 开同一路"改成"点'PVW（已关）' = 开同一路"（M2 单选；判据 enabled / 配置留着 / 不新增 / 窗口开关都没变），并多断言一条"关着的标（已关）" |
| `UISmokeTests`（第 12 步）、`StreamWiringTests` | **"空节目推流按钮置灰" → "不灰"**（L1 明确要求没有目的地时主体不灰、点了打开推流页）；"ISO 入口按钮可用" → "录制 ⚙ 菜单里有可用的'ISO 分路录制…'"（K2）；外部显示主体可用 |
| `LiveSafetyTests.testUI_stopRecordAsksConfirmation`、`StreamWiringTests` | 原来"等推流按钮变可用"兼当"等底栏看到新目的地"；L1 之后按钮一直可用，全量第一遍点早了（快照还没到，主体当成"没有目的地"去开了推流页）——改成等 `bottomBar.streamDestinations` 里有这一路，其余判据不变 |
| `ISOAppTests.testISO_singleEntry_…` | "底栏 ISO… = 打开 ISO 页"改成"录制 ⚙ › ISO 分路录制… = 打开 ISO 页"，其余断言不变 |
| `StatusLineTests` | 字段名 / 节目格式的期望值改成新口径（E9 / V-22：帧率 / 渲染、1080p60），"屏上那行 = jsonl 同一秒重算"的判据不变 |
| `LocalizationTests`、`ExternalOutputAppTests`（通知） | "PlusMix 外部输出" → "PlusMix 外部显示"、通知里找"外部显示"（M4） |
| 其余（RecordingTests / TransitionColumnTests / LiveSafetyTests 等） | `bar.recordButton` → `bar.record.bodyButton` 之类的机械替换 |
| `AppTest.freshSession` | 每条用例开头清掉添加输入的本机记忆（上次的类型 / 最近添加），不然 PanelTests 加过 NDI 之后 `testAddInput_sheetPresentsSwitchesKindsAndCancels` 会停在 NDI 页 |

### 2.3 红灯轮

`d0b8eec` 上只跑新用例（五个按钮换成 SplitBarButton 的主体、⚙ / ▴ 不挂动作、ISO 按钮还在，菜单 / 历史 / 格式只给空实现）：**6 条全红**——分体三段 14 处（三段可见性、"外部输出"、ISO 按钮、ISO / 叠加按钮不拒焦点、菜单弹不出来）、状态行 26 处（不是最底一行、不对称、"1920×1080 60"、fps / render、本机信息空、调音台 339）、录制 ▴ 3 处、推流 ▴ 3 处后数组越界崩、添加输入 ▴ 2 处、外部显示主体点下去照旧模态弹菜单（卡了 309 s 才回来）；键盘导航那条按 BLOCKED-系统设置 跳过。

### 2.4 全量（`make test-app XCB_FLAGS=`，xcresulttool 核过）

| 轮次 | 结果 | 说明 |
|---|---|---|
| 第一遍（实现、叠加还是 NSPopover） | 151 条：146 过、3 跳、**2 红** | ① `BottomBarPopupTests` 叠加弹出层伸出窗口右沿（叠加挪到右组后 NSPopover 以按钮为中心）→ 换成 BottomBarPanel；② `LiveSafetyTests.testUI_stopRecordAsksConfirmation` 点早了（"等推流按钮可用"在 L1 之后不再等于"底栏看到了目的地"）→ 改等 `streamDestinations`。两处改完、单跑这几个类全过，提交 `49eb5af` |
| 第二遍（`49eb5af`） | 151 条：147 过、3 跳、**1 红** | `RecordingTests.testRecord_5sTwoTracksDurationExact`："起止拍差 = 按钮间隔 ± 1 帧"差 1.02（316 拍 vs 317.02）。不是偶然，见 2.5：查出底栏每个快照都重设按钮标题 / 提示，改成没变不重设 |
| 第三遍（"没变不重设"改完、还没提交时跑的，内容与 `12de2cb` 相同；LG 已接回） | 151 条：146 过、3 跳、**2 红** | `ISOAppTests.testA4_…`（第 3 路晚起 8 拍；单跑两次都绿）、`MainWindowLayoutTests.testUI_mainWindowRestoresSavedFrameInsteadOfCentering`（W5-A 的存档换算看样子跟着"系统焦点窗口在哪块屏"走；本分支单跑 5 次红 1 次、main 单跑 4 次全绿）——都是显示器 / 负载环境，见 §5 第 11 条。本会话的 7 条与改过的旧用例全绿，菜单位置这一遍是实测 |
| 第四遍（`12de2cb`，最终） | **151 条：148 过、3 跳、0 失败**（xcresulttool：result Passed / totalTestCount 151 / passed 148 / failed 0 / skipped 3，288 s） | RecordingTests 317 拍 vs 5.285 s × 60 = 317.1；这一遍主窗口回到内建屏、测试宿主不在前台，菜单位置是按定位点算的（外部显示菜单两块屏 × 6 路 265 × 608，与第三遍实测的 268 × 608 一致） |

跳过的 3 条都与 main 相同或是本会话按设计跳过的：内置摄像头 BLOCKED-权限、虚拟摄像头出画 BLOCKED-签名、键盘导航 BLOCKED-系统设置（§2.1 最后一行）。release frameprobe 先编好了，ISO A4 / 推流端到端是真跑的。

### 2.5 RecordingTests 的"按钮间隔 ± 1 帧"：查到的原因与修后数值

这条量的是"点开始 → 点停止（确认框弹出来那一刻）"的墙钟间隔 × 60 和录到的起止拍差之差，判据 ≤ 1 帧（阈值不动）。点按钮的 `performClick` 会先画高亮再发命令，主线程上排队的布局越多，命令发得越晚、越忽早忽晚。

| 树 | 样本（拍差 vs 间隔 × 60 之差） | 间隔 | 红 |
|---|---|---|---|
| main `190fe32`（git archive 到草稿区单独编，同一台空机器） | +0.50、+0.98、−0.32、+0.68、+0.56 | 5.317–5.325 s | 0 / 5 |
| 本分支 `49eb5af` | −1.02（第二遍全量）、+0.98、+1.64、−0.24、−0.18、+1.12、+0.18、+1.00、+1.06 | 5.284–5.317 s | 5 / 9 |
| 本分支 + 标题 / 提示没变不重设 | −0.24、−0.24、−0.06、+0.70、−0.18 | 5.101–5.105 s | 0 / 5 |

原因：`BottomBarView.updateButtons` 每个快照（≤ 60 Hz）都把录制 / 推流主体的标题与提示重设一遍（W5-B 起就是这样），重设标题会冲掉高亮的白字 attributedTitle、按钮重算尺寸、整窗在下一次画之前重新布局；本会话又多了外部显示主体的提示每次重设、分体按钮多了两层 NSStackView，抖动大到过线。改成"没变不重设"之后不光过线，**点"停止"到确认框挂上从约 0.30 s（main 约 0.32 s）降到约 0.10 s**——主线程不再被每帧的布局占着（W5-B 报告 §5 第 1 条记的"打开动画在测试里等 attachedSheet 也要 ~0.29 s"，从这组数看大半是这个，不是动画本身）。

### 2.6 每个 ⚙ / ▴（和主体）打开的是哪个窗 / 哪一页

| 控件 | ⚙ | 主体 | ▴ |
|---|---|---|---|
| 添加输入 | —（参考也没有齿轮） | 添加输入面板（主窗口 sheet），停在上次添加用的类型（第一次 = 合成测试源）；⌘I 同一个入口 | 朝上菜单：八种类型（点 = 添加输入面板直达那一页）─「最近添加」最多 5 项（点 = 不弹面板，直接加一路）；= 菜单栏 输入 › 按类型添加 ▸ |
| 录制 | 朝上菜单：录制设置… → **输出设置窗 › 录制**；ISO 分路录制… → **输出设置窗 › ISO 分路** | 不开窗：PGM + 全部 ISO 同一拍起 / 停（停先确认） | 朝上菜单：每个录制输出一行（点 = 只停这一路，先确认）─ 全部停止（先确认） |
| 外部显示 | 朝上菜单：每块屏一段单选（关闭 / PGM / PVW / 多画面 / 输入 n）─ 删除 n … / 关闭全部外部显示 ─ 外部显示设置… → **输出设置窗 › 外部显示**；NDI® 发送设置… → **输出设置窗 › NDI® 发送**；= 菜单栏 输出 › 外部显示 ▸ | 不开窗：全部外部显示开 / 关（配置留着）；一路都没配 → 第一块非主屏上开 PGM 的全屏窗；没有第二块屏 → 弹 ⚙ 那个菜单 | — |
| 推流 | **输出设置窗 › 推流**（直接打开，不弹菜单） | 不开窗：都没开 → 全起；有起不来的 → 只重试它们；否则停全部（先确认）。没有目的地 → **输出设置窗 › 推流**，焦点在"添加目的地"的地址框 | 朝上菜单：全部开始 / 全部停止 ─ 每个目的地（点 = 只起停 / 重试这一路）─ 推流设置… → **推流页**；推流状态… → **推流页**（101 的状态面板做好之前）；= 菜单栏 输出 › 推流 ▸ |
| 多画面 | **输出设置窗 › 多画面布局**（直接打开） | 多画面独立窗口开 / 关（开着高亮） | — |
| 叠加（右组） | — | 叠加面板（BottomBarPanel，朝上、右缘对齐按钮、整块在窗口里；97 改独立窗） | — |

## 3. 没做的和原因

- **录制 / 推流时长（E10）、推流状态面板（L11）**：prompt 写明等 022 / 101；"推流状态…"现在打开推流页。
- **工具条（93）、设置页内容（95）、菜单栏重排（93）**：本会话只在菜单栏加了"输出 › 推流 ▸"和"输入 › 按类型添加 ▸"两个点名的子菜单、把"外部输出"改名；"输出"菜单其余排法留给 93（01 §5 的"录制 ▸"也是 93 的）。
- **外部显示每块屏的"关闭"只在这块屏有配置时列**（M2 原文是"最上'关闭'"）：两块屏 × 6 路输入时这个菜单实测 608 pt 高（第三遍全量，加了末尾设置段之后），最小窗口 1100×700 里顶边离窗口上沿只剩 37 pt；每块屏都列"关闭"要再加 2 行（约 48 pt），就顶出窗口约 11 pt（E1 与 `testUI_bottomBarPopupsStayInsideWindow` 都要求整块在窗口里）。没有配置的屏本来就没东西可关（不打勾也表示"这块屏没出画面"）。要无条件列"关闭"，得先给这个菜单省出高度（比如每块屏的 Aux 说明行只留一行），请用户定。
- **菜单真实位置只有第三遍全量量到**：测试宿主不在前台时 NSMenu 不真弹（W5-A 报告也记过），前两遍和单跑时位置断言退到"和 popUp 同一个定位点算出来的位置"（BottomBarPopup.menuFrameInScreen，输出标"（按定位点算）"）；第三遍主窗口在 LG 上、菜单真弹了（输出标"（实测）"）。叠加面板是本进程窗口，量的是真 frame。
- **键盘导航开着时的实测**：系统设置归用户（我不能改系统设置），进程内三种办法都打不开 AppKit 的键盘导航（§5 第 1 条）；结论按探针 + AppKit 的规则写，留了一条开了键盘导航就会跑的用例。
- **V-22 的"偶尔显示 GPU 0%"**：是 GPU 利用率采样（Engine/GPUUtilization）的事，不是排版；本会话没碰。
- **右组其余几项（≡ 工具 / 统计 / 快捷按钮 / 截图 / 锁，E4–E8）**：不在本 prompt（98 等）。
- **手册**：docs/user 不在本会话目录，要改的行列在 §5 第 9 条给 103。

## 4. 对契约的疑问

没有改契约，也没有要停下来的提案：单路起停 startRecord / stopRecord / startStream / stopStream、setOutputEnabled / setOutputSettings / renameOutput / addOutput 都是现成的。两点给后面参考：
1. **时长（E10）**：底栏和 ▴ 里都没写时长；按铁律 4 应该进 Stats（022 的 uptime），不要 App 自己按起始拍推算。
2. **"主屏"的口径**：外部显示"第一块非主屏"用的是 SwitcherExternal 的 `ExternalDisplays.all()`，它的 `isMain` = `NSScreen.main`（有键盘焦点窗口的那块屏），不是"带菜单栏的那块"。PlusMix 主窗口在哪块屏，哪块就是"主屏"，正好是"别把 PGM 盖在操作员自己的屏上"的意思；要改成菜单栏那块屏是包内的事，不涉及契约。

## 5. 下一个会话需要知道的坑

1. **C9 键盘导航实测结论**（探针在草稿区，`swiftc` 编 20 行 AppKit 程序，一扇窗一个按钮、窗口 keyDown 记账）：
   - 系统"键盘导航"现在是关的（`defaults read -g AppleKeyboardUIMode` 没这个键）。关着时：Tab 不会落在按钮上（`canBecomeKeyView` = false）、鼠标点按钮焦点也不留在按钮上，**连程序硬塞 `makeFirstResponder(按钮)` 之后按空格，按钮都不动作、空格落到窗口 keyDown**——也就是说关着的时候空格本来就不会被按钮吃掉，refusesFirstResponder 防的是开着的情况。
   - 想在进程里打开键盘导航，三种办法 AppKit 都不认：参数域 `-AppleKeyboardUIMode 2`、`NSApplication` 子类覆写 `isFullKeyboardAccessEnabled`（属性变 true 了，但 `canBecomeKeyView` 仍 false）、`CFFIXED_USER_HOME` 指向写了 `AppleKeyboardUIMode = 2` 的假家目录。AppKit 直接读系统全局设置；改系统设置是用户的事，本会话没改。
   - 能确认的：`refusesFirstResponder = true` 之后 `acceptsFirstResponder` = false（探针与 `testUI_bottomBarButtonsAreSplitAndPopupsOpenUpward` 都量了），AppKit 的 Tab 键视图环只收 `acceptsFirstResponder` 为真的视图，所以开着键盘导航时 Tab 跳过底栏按钮、空格回到快捷键表。**注意 `makeFirstResponder` 不看 `refusesFirstResponder`**（程序硬塞照样进去），以后别在代码里把焦点塞给底栏按钮。
   - 要真测：系统设置 › 键盘 › 打开"键盘导航"，跑 `-only-testing:SwitcherTests/BottomBarSplitTests/testUI_spaceNotEatenByBottomBarButtonsWithKeyboardNavigation`（关着时它按 BLOCKED-系统设置 跳过），测完关回去。
2. **推流主体不再置灰**：以前用"按钮变可用"当"底栏已经看到这个目的地"的用例会点早（快照还没到，主体当成"没有目的地"去开推流页）。等 `bottomBar.streamDestinations`。
3. **叠加面板不是 NSPopover 了**（BottomBarPanel）：不会因为"别的窗口被程序打开"之类的事自己收起，只在点外面 / Esc / 再点叠加按钮 / 换 session 时收；`hidesOnDeactivate = false`（NSPanel 默认切到别的 App 就藏起来，测试宿主在后台时会一直是"没显示"）。用例里开了叠加面板、后面又要它关着的，记得再调一次 `presentOverlayPanel` 收掉。97 改独立窗时把它换掉就行。
4. **添加输入的本机记忆**存在 UserDefaults 的 `addInputLastKind` / `addInputRecentSources`；测试宿主的 suite（`com.plusmix.switcher.tests`）是所有 worktree 共用的，`AppTest.freshSession` 每条用例开头 `addInputHistory.reset()`。正式 App 写在 `com.plusmix.switcher` 域。
5. **MediaMTX 的测试配置（scripts/mediamtx.yml）只开了 s1 / s2 / s3 / srt1 四个路径**，推流码要空（路径 = app 名）；推到别的路径时 RTMP 握手能过、connect 3 s 超时、一直"连接中"。
6. **外部显示菜单的段**：每块屏一段（有配置时段里第一行"关闭"）、有外部显示输出时倒数第二段是删除 / 全部关闭、**最后一段永远是"外部显示设置… / NDI® 发送设置…"**。`AppTest.menuSections(menu).last` 不再是删除段（`dropLast().last` 才是）。同屏只认一路：`ExternalOutputMenuBuilder.primaryOutput(on:in:)`（开着的优先），displayID 为 nil 的老输出算在主屏上。
7. **93 接工具条正中"外部显示▾"**：直接用 `MainWindowController.externalOutputMenu()`（菜单）和 `toggleExternalDisplays()`（主体），开关状态读快照里 externalDisplay 输出的 enabled；推流 ▴ 的菜单是 `bottomBar.streamMenu()`，添加输入的是 `addInputMenu()`。菜单栏"输入"菜单现在有 delegate（menuNeedsUpdate 里重建"按类型添加"）。
8. **两份 Localizable.strings**：新加 42 个键（`addInputMenu.*`、`recordMenu.*`、`streamMenu.*`、`bottom.gear.a11y` / `bottom.menu.a11y` / `bottom.addInput.name` / `bottom.addInputTip` / `bottom.externalTip.*`、`externalMenu.off*`、`menu.input.addByType`、`menu.output.streamSubmenu`、`output.state.on`、`status.fps` / `render` / `gpu` / `cpu` / `machine`），删了 `bottom.externalTip`，改了 11 个值（`aux.external.windowTitle`、`bottom.external`、`bottom.multiviewTip`、`bottom.noStreamOutputTip`、`externalMenu.closeAll`、`menu.output.external`〔"外部显示设置…"〕、`menu.output.ndi`〔"NDI® 发送设置…"〕、`notice.externalDisplay`、`outputSettings.multiview.hint`、`prefs.external.behindInterface`、`prefs.external.title`）。93–98 也改这两个文件，G7 合并时按键解冲突。
9. **手册要跟着改**（不在本会话目录，给 103 / G7）：docs/user/概念.md:31 与 en/concepts.md:32 的底栏示意（现在是两行：按钮行 + 状态行，没有"ISO…"，"外部输出"→"外部显示"）、:36（状态行字段名：帧率 / 渲染）；docs/user/输出.md:3、:31（"或底栏 ISO…"→"或底栏 ⚙ 录制 › ISO 分路录制…"）、:63（推流按钮状态与 ▴ 的单路起停）、:82–84（第 4 节"外部输出"→"外部显示"，⚙ 单选菜单 + 主体全部开关）、:11、:117–118，docs/user/README.md:15，docs/user/输入.md:122；en/outputs.md:3、:33 与 en 版里的 "external output"。docs/KNOWN_ISSUES.md 里 W5-D 的"底栏推流提示显示明文地址"（reports/issues/W5D-w5-app-bottom-bar-stream-tooltip-shows-credentials.md）可以标已修：提示与 ▴ 里只有名字和打过码的地址。
10. **底栏 / 任何每帧都会刷新的控件，值没变就别重设**：NSButton 重设 title 会冲掉 attributedTitle、重算尺寸、整窗下一次画之前重新布局；≤ 60 Hz 的快照里这样做，`performClick`（先画高亮再发命令）和确认框都会被拖慢、忽快忽慢（§2.5：点"停止"到确认框挂上 0.30 s → 0.10 s，RecordingTests 那条从 5 / 9 红到 0 / 5）。93 / 94 / 97 往主窗口加每帧刷新的东西时照这个做。
11. **显示器排布会让两条老用例时红时绿**：今天 LG 中途接回来（在内建屏上方）。`MainWindowLayoutTests.testUI_mainWindowRestoresSavedFrameInsteadOfCentering`（W5-A）存档用的是一扇没上屏的窗，看样子 AppKit 存 / 读这种存档时按当时的"主屏"（NSScreen.main，跟着系统焦点窗口走）换算（推测，没细查），别的 App 的焦点窗口在 LG 上时它会落到 (−352, 1320)、判红；本分支单跑 5 次红 1 次、main 单跑 4 次全绿，与本会话的改动无关（没碰窗口摆放）。ISO A4（三路同拍）在第三遍全量里第 3 路晚起 8 拍、单跑两次都绿，是负载 / 显示器重排时的老坑（G6 报告、W5-B 报告都记过）。`ExternalOutputAppTests` 判"外接屏"的口径和外部显示主体的"第一块非主屏"不一样，两块屏时它照样打印"外接屏 BLOCKED-硬件（只有内置屏）"。
