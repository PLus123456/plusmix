# W2-B 显示路径与主界面骨架（App 一期）报告

分支 `claude/w2-app-display-ui-55bfcd`（桌面端开的 worktree 分支名；prompt 里叫 `w2-app`，本地另打了同名引用 `git branch -f w2-app HEAD` 给 `check-ownership.sh` 用）。
基于 main `2290b4e`（G2 合入后），本会话提交 `d2934c1` … `71cc74e` + 本报告。
机器：MacBook Pro M5 Max，macOS 26.6.2（25G83），Xcode 26.6 / Swift 6.3.3，接电源，只有内置屏（120 Hz ProMotion，没有外接显示器）。
测试期间同一台机器上有另外四个 W2 会话在跑构建和测试（load 2–3）。

## 1. 做了什么

只动了 `App/` 和 `Packages/SwitcherCore/Sources/SwitcherRender/Display/MetalDisplayView*.swift`（两个文件：W1-C 的 `MetalDisplayView.swift` 和新加的 `MetalDisplayView+Multiview.swift`）。**注意 `docs/OWNERSHIP.md` 的 W2-B 行写的是 `Packages/SwitcherCore/Sources/SwitcherRender/MetalDisplayView*`，而 W1-C 把文件放在了 `Display/` 子目录，`check-ownership.sh` 的 bash 模式匹配不上，`make lint` 会把这两个文件标成越界**（详见 §4 第 1 条，改一个 token 就好，我不能动 docs/OWNERSHIP.md）。

| 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 显示路径 | `SwitcherRender/Display/MetalDisplayView.swift` | 在 W1-C 的版本上补：① **遮挡 / 隐藏 / 滚出可见区时主动 `link.isPaused`**（探针 1：窗口被完全遮住时 `NSView.displayLink` 自己不停，仍 120 Hz 回调，只有最小化 / orderOut 才停；W1-C 只是不画，回调照跑）；② **`maxFramesPerSecond` 加 host time 闸门**（`preferredFrameRateRange` 只有 ProMotion 屏真会降频，固定 60 Hz 外接屏回调仍 60 Hz，只靠它缩略图会画到 60 fps；闸门 = 距上次 blit ≥ 1/fps − 1 ms）；③ `sourceRect`：只画纹理的一块（缩略图用）；④ 每次 blit 打 `os_signpost` 事件（subsystem `app.switcher.display`，`present-pgm` / `present-pvw` / `present-mv`）；⑤ 换屏通知里刷 contentsScale（刷新率由 `NSView.displayLink` 自己跟，Apple 文档：display link 绑定视图所在窗口的显示器）；⑥ `SkipCounters.rateLimited`、`isLinkPaused`、`screenMaximumFramesPerSecond` 给测试看。PGM / PVW 监视器不设上限 = 跟显示器全速（只 blit 新完成的帧，60 fps 节目就是 60） |
| 1 缩略图几何 | `SwitcherRender/Display/MetalDisplayView+Multiview.swift` | `MultiviewLayout`：把 `CompositorPasses.encodeMultiview` 的格子几何（margin、border、4×2 / 6×3 / 8×4）换算成归一化矩形。**输入缩略图 = MetalDisplayView 以 target = .multiview、sourceRect = 对应格子来画**，不给渲染器加"每路纹理"接口（`Renderer/*` 不是本会话的）。App 测试用 `OfflineRenderer` 画一张多画面对着采样，W3-B 改布局这边会红 |
| 2 主窗口 | `App/Sources/UI/MainWindowController.swift` | `MainWindow`（收键盘）+ 两层 `NSSplitView`：外层 = 中列 ｜ 调音台（可收起，`canCollapseSubview`），中列 = 上（PVW ｜ 转场列 ｜ PGM）/ 下（缩略图条）；底栏在 split 外面横贯整宽。深色外观（`NSApp.appearance = darkAqua`） |
| 2 双监 | `UI/MonitorView.swift` | 标题条：编号、名字、角色（PVW / PGM，FTB 开着时 PGM 标 "PGM · FTB"），底色 tally：**PGM 红 / PVW 绿**（广播惯例，落地方案 §7 第 3 条），黑场显示 "— 黑场" |
| 2 转场列 | `UI/TransitionPanelView.swift`、`UI/TBarView.swift`、`UI/ClockView.swift` | Cut / Fade / Wipe / Zoom / Stinger / FTB（Wipe / Zoom / Stinger 置灰，tooltip 写 W3-B）；时长预设 0.5 / 1 / 2 s（按标称帧率换成拍：60 fps → 30 / 60 / 120；发 `setTransition(type: 当前类型, durationTicks:)`）；Overlay 1–4 开关（只改 on，不动通道的输入）；T-bar 自绘（拖动发 `tbar(progress)`，拖动中最多发 0.999，松手 ≥ 0.97 才发 1 = 提交，然后 150 ms 回弹到 0；没到顶停在原位；不拖时跟快照走，auto Fade 时能看到它自己往上走）；时钟 24 h 大字 + 12 h 小字，对齐整秒 |
| 2 缩略图条 | `UI/InputStripView.swift`、`UI/InputCellView.swift` | 横向 `NSScrollView` + `NSStackView`，格子按 `MixerState.inputs` 顺序增删复用；每格：标题条（编号、名字、tally 底色）+ tally 边框、缩略图（多画面格子，≤ 24 fps）、Overlay 1–4 小按钮（高亮 = 该通道开着且用的是这一路；点：开着 → 关，否则把通道指向这一路并打开）、静音；点缩略图 = `setPreview`，Shift 点 = `setProgram`；右键：重命名 / 删除输入；搜索框按编号或名字过滤，回车 / Esc 把焦点还给窗口；非 live 的路在画面上盖状态文案（无信号 / 错误） |
| 2 调音台占位 | `UI/MixerPanelView.swift` | Master 竖推子（−60…+12 dB，发 `busGain(.master)`）、静音（`busMute`）、表（`LevelMeterView`）、A1 计数。**表没有电平可读：Stats 里没有电平字段**（W2-E 的"表读数进 Stats 和快照"要走契约提案），所以只画刻度和 −∞，不在 UI 里另算（铁律 4） |
| 2 底栏 + 状态行 | `UI/BottomBarView.swift`、`UI/StatusLineFormatter.swift` | 添加输入… / 录制 / 推流 / 外部输出 / 多画面 / 叠加…（外部输出、多画面置灰：W3-C / W3-E；叠加… 弹 `OverlayPanelController`：四个通道各选输入 + 开关）。录制按钮发 `startRecord / stopRecord`，文案按快照的 enabled + `Stats.encoder` 是否有编码器在跑分三态："录制" / "录制 · 等编码器"（W2-B 没接 Recorder，G3 接）/ "● 录制中"。状态行 1 Hz，**全部来自 `Stats`**：节目格式（快照）、fps（相邻两行 tick 差 / ts 差）、render ms、GPU %、CPU %、丢帧（missed_render）、编码跳帧、码率、磁盘（—，见 §4） |
| 3 绑定 | `App/Sources/Engine/SwitcherSession.swift` | UI 只拿 `send(Command)` 和两个观察者。**快照分发**：主线程 `Timer` 1/60 s 看一次 `publisher.latest`，指针变了才分发 → 每秒最多 60 次，同一帧内多次变化合并（冒烟测试实测峰值 40 次/s，Fade 进行中每拍都发布也只到 60）。**Stats 1 Hz**：`StatsPump` 在一条 utility 线程上每秒调一次 `engine.makeStats()`，同一个对象送 stats.jsonl（可选）和主线程。命令按发出顺序经一条 `AsyncStream` 串行 `stateMachine.apply`（W2-C 的 CommandBus 合并后换成它，UI 侧不用改） |
| 4 Add Input | `UI/AddInputSheet.swift` | Sheet：左边类型（合成源 / 摄像头·采集卡 / 屏幕 / 视频文件 / 图片），右边表单（合成源：帧率 30 / 59.94 / 60、尺寸、底色灰度、带音频；摄像头：`AVCaptureDevice.DiscoverySession` 列设备；屏幕：`NSScreen` 列显示器；文件 / 图片：路径 + 选择… + 播完动作），底部编号（最小空闲号）+ 名字（留空用默认）。`AddInputModel` 是纯逻辑，可测。只产生 `InputConfig` 发 `addInput` |
| 5 快捷键 | `UI/Shortcuts.swift` | 硬编码表：1–9、0 → `setPreview`（0 = 输入 10），Shift + 数字 → `setProgram`，空格 → `cut`，回车 → `fade(当前时长)`，F → `ftb` 开关；带 ⌘ / ⌃ / ⌥ 的不管，自动重复不触发。在 `MainWindow.keyDown` 生效：文本框有焦点时按键先被字段编辑器吃掉。启动后把第一响应者设成窗口本身，否则 AppKit 默认把焦点给搜索框，数字全进搜索框（第一版就是这么踩的） |
| 6 Show | `App/Sources/Show/ShowDocuments.swift`、`AppController.swift`、`AppDelegate.swift` | 菜单"节目"：新建 ⌘N / 打开… ⌘O / 打开最近（UserDefaults 最近 10 个，清除列表）/ 保存 ⌘S / 另存为… ⇧⌘S；文件格式 `.switcher.json`，读写走 `SwitcherEngine.ShowStore`；节目名 = 文件名；`Show.layout` 存 `mainWindowFrame`、`mixerPanelVisible`。**启动恢复上次**：上次打开 / 保存的文件 → 没有就退出时自动存的 `~/Library/Application Support/Switcher/LastSession.switcher.json` → 再没有就空节目（带一个默认录制输出）。新建 / 打开总是换一个新 session（节目格式可能变，引擎的格式在 init 定死） |
| 7 真跑 | `App/Sources/Engine/InputRuntime.swift`、`StatsPump.swift`、`GPUUtilization.swift` | `SwitcherSession` = `MetalRenderer` + `StateMachine` + `Engine` + 每路 `LockFreeFrameSlot` + `InputFactory`。工厂现在只认合成源（TestKit 的 `SyntheticVideoInput`，t0 对齐节目拍点、提前半个节目帧，同 headless 的 `--input-lead-ms` 默认）；摄像头 / 屏幕 / 文件 / 图片建成 `PlaceholderInput`（state = error，格子上显示"…在 W2-A，合并后可用"），G3 把 W2-A 的工厂接到 `InputFactory` 上即可。GPU 占用抄了 headless 的 IOKit 读法（Tools 不是库，见 §5）。`--show <路径>`、`--stats <路径>` 两个启动参数 |

真跑过：`Switcher --show scenarios/m0-show.json`（G2 的 8 路合成源）截图 `App/Tests/Artifacts/w2-app-main-window.png`：PVW 2 / PGM 1，八个格子带 tally 边框，状态行 render 1.74 ms / GPU 31% / 丢帧 0（debug 构建，8 路 1080p CPU 画图案，CPU 106%）。

## 2. 测试（`xcodebuild test`，`SwitcherTests` 14 个全过，约 31 s；`swift test --filter SwitcherRenderTests` 27 个全过）

prompt 只给了四条测试的名字没有编号，函数名带的是描述：

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| **UI 冒烟** `testUI_smoke_launchAddTwoSyntheticsKey2SpaceThenReturnSwapsAfter30Ticks`：启动（测试宿主）→ 走 `AddInputModel` 加两路合成源（60 / 30 fps）→ 等两路 live → 按 2 → 空格 → 按 1 → 回车 | 按 2 后 preview = 2（PVW 标题 "2 合成 2 · 30"）；空格后 **program = 2**、preview = 0；回车后 `transition.type = fade`，**对调恰在 startTick + 30 拍**（最新快照的拍 − startTick = 30，三次运行都是 30）；之后 Shift+2 直切、格子点击 / Shift 点击、格子 Overlay 1（通道 1 → 输入 2、tally 变 PGM）、中列 Overlay 开关、静音、F 开关 FTB、2 s 预设 = 120 拍、Master 推子 −12 dB / 静音、录制按钮三态、推流置灰、调音台收起展开、搜索过滤全过 | program == 2；30 拍后对调 | ✅ |
| 快照分发 ≤ 60 Hz（同上一条里量的） | 整个冒烟过程快照回调峰值 40 次/s（75 次 / 2.3 s） | ≤ 60/s | ✅ |
| T-bar `testUI_tbarDragToTopCommitsAndSpringsBack` | 拖到 0.5 停住（`source = .tbar`，progress 0.5，不对调）；拖到顶 → 对调（1/2 → 2/1）→ 回弹到 0 | 到顶提交后回弹 | ✅ |
| **显示解耦** `testDisplay_dragFullscreenAndScreenMoveDoNotIncreaseMissedRender`：真 App 主窗口 + 真引擎 + 2 路合成源，预热 2 s 取 `Stats.missed_render` 基线，拖动 2 s（每 30 ms 挪一次）、进全屏 2 s、出全屏 2 s，（有第二块屏时挪过去 2 s） | **missed_render 基线 0 → 拖动后 0 → 全屏后 0 → 最终 0**（读的是 1 Hz 的 Stats，不是引擎计数器）；全屏进入成功；PGM 视图两次运行分别 blit 51.2 fps（display link 101 Hz）和 23.8 fps（47 Hz，全屏动画期间 link 暂停 + 机器负载高）| 不增 | ✅；**挪到外接屏：BLOCKED-硬件**（只有内置屏；解锁条件：接任意 HDMI 显示器再跑同一个测试，它会自动把窗口挪过去并打印那块屏的刷新率） |
| **状态行 = stats.jsonl** `testStatus_lineMatchesStatsJsonlSameSecond`：`--stats` 同一条路（`session.startStatsLog`），每收到一行 Stats 记下状态行此刻的文字，5 秒后按 ts 配对 | 5 行全部逐字等于用 jsonl 里 (上一行, 这一行) 重算的文字；从显示文字抠出的 render / 丢帧 / GPU / CPU / fps 与文件字段对上（render ±0.005，fps 由相邻两行 tick 差 / ts 差 ±0.1） | 同一秒一致 | ✅ |
| **缩略图 ≤ 24 fps** `testThumbnail_refreshRateAtMost24fpsWhileMonitorsRunFullSpeed`：2 路，预热 1.5 s，数 4 s | 格子 1 blit 96 次 / 4.0 s = **23.97 fps**（display link 回调 96 次：ProMotion 屏真降到 24 Hz，闸门 0–1 次），格子 2 也 96 次；**PGM 240 次 = 59.9 fps，PVW 240 次 = 59.9 fps**（屏幕 120 Hz，只画新帧） | ≤ 24；监视器全速 | ✅ |
| 缩略图 signpost 统计（xctrace，独立 App 跑 m0 节目 8 路，`Logging` 模板录 10 s，导出 `os-signpost` 表按 subsystem `app.switcher.display` 数） | `present-pgm` 635 次 / 10.57 s = **60.00/s**，`present-pvw` 635 次 = 60.00/s，`present-mv` 2032 次 / 10.54 s = 192.7/s ÷ 8 格 = **24.0/s 每格** | ≤ 24 | ✅ |
| 遮挡停刷 `testThumbnail_pausesWhenWindowIsCovered`：另开一个不透明窗口盖住主窗口 | 被盖住的 1 s 内缩略图 blit 0 次、**display link 回调 0 次（已暂停）**，PGM blit 0 次；移开后 1 s 内 24 次 | 遮挡停刷 | ✅ |
| 多画面格子几何 `testMultiviewLayout_matchesRenderedCells`：1 / 2 / 3 / 8 / 9 / 18 / 19 / 24 路，OfflineRenderer 画多画面，在 `MultiviewLayout.inputCell` 中心采样 = 该路纯色（±6），格子外 2 px = tally 边框色（PGM (230,26,26) / PVW (26,204,26) / 灰 (71,71,71)，±8） | 全部命中 | — | ✅ |
| 快捷键表 `testShortcuts_defaultTable` | 数字 / Shift+数字 / 空格 / 回车（用当前时长）/ F（开关）；⌘ 组合、自动重复、其他键返回 nil | — | ✅ |
| 节目文件 `testShow_newSaveOpenRecentAndAutosave`、`testShow_controllerRoundTripReplacesSession` | 保存 → 打开原样（含 layout）；最近列表最新在前、去重、清除；上次文件；自动保存；经 AppController 写文件 → 新建（session 换、输入 0）→ 打开（输入 2 路重新 live、PGM 2、标题 "Switcher 0.1.0 — round"） | — | ✅ |
| W2-A 之前的占位 `testShow_unsupportedInputKindIsPlaceholder` | 加一路 `.camera` 不崩，运行状态 `.error("camera 输入的实现在 W2-A，合并后可用")`，格子显示名字，删除后注销 | — | ✅ |
| Add Input `testAddInput_modelMakesConfigs`、`testAddInput_sheetPresentsSwitchesKindsAndCancels` | 五种类型都出 `InputConfig`，缺参数抛错，默认名 / 空闲编号；sheet 真弹出（默认编号 2）、五种表单都建得出、取消不加、确定加一路合成源 | — | ✅ |
| W1-C 原有的 `DisplayDecouplingTests`（SwitcherRenderTests） | 仍过：display link 回调从 1088 次 / 9.1 s 降到 717 次（遮挡的 2 s 里回调 0），blit 361 次（39.6 fps），跳过 0；15 fps 上限：2 s 内 blit 30 次 | 同 W1-C | ✅ |

状态行对照（截图 `App/Tests/Artifacts/w2-app-status-line.png` 是最后一行 ts = 1789444765.634192 时的底栏；jsonl 五行留在 `App/Tests/Artifacts/w2-app-status-line-stats.jsonl`）：

| ts | tick | render_ms | missed_render | gpu_pct | cpu_pct | 状态行显示 |
|---|---|---|---|---|---|---|
| 1789444761.631799 | 42 | 1.3851 | 0 | 0 | 59.11 | 节目 1920×1080 60 · fps — · render 1.39 ms · GPU 0% · CPU 59% · 丢帧 0 · 编码跳帧 — · 码率 — · 磁盘 — |
| 1789444762.633356 | 102 | 1.1405 | 0 | 0 | 66.83 | … fps 59.9 · render 1.14 ms · GPU 0% · CPU 67% · 丢帧 0 … |
| 1789444763.63434 | 162 | 1.2932 | 0 | 0 | 68.51 | … fps 59.9 · render 1.29 ms · GPU 0% · CPU 69% · 丢帧 0 … |
| 1789444764.6324 | 222 | 1.1389 | 0 | 0 | 67.51 | … fps 60.1 · render 1.14 ms · GPU 0% · CPU 68% · 丢帧 0 … |
| 1789444765.634192 | 282 | 1.1578 | 0 | 0 | 67.23 | … fps 59.9 · render 1.16 ms · GPU 0% · CPU 67% · 丢帧 0 …（截图） |

GPU 0% 是真读到的：`Device Utilization %` 是全机的设备级占用，2 路合成源 + 空闲的那一秒确实 0；独立 App 跑 8 路时 31%。

探针（铁律 10，`NSView.displayLink` 在 macOS 26 上的实际行为，20 行程序，结论进了 MetalDisplayView 的文件头注释）：

| 情况 | 回调 |
|---|---|
| 内置 120 Hz 屏默认 | 120.5 Hz |
| `preferredFrameRateRange` 24 | 24.0 Hz（ProMotion 真降频） |
| `preferredFrameRateRange` 60 | 60.0 Hz |
| 窗口最小化 | 0（自己停） |
| 被另一个窗口完全盖住 | **120.5 Hz（不停）**，`occlusionState` 已不含 `.visible` |
| `orderOut` | 0 |

固定 60 Hz 外接屏上 `preferredFrameRateRange` 是否生效没法测（BLOCKED-硬件）；按 Apple 文档它只是"偏好"，所以加了 host time 闸门兜底，闸门在 120 Hz 屏上验证过（`rateLimited` 计数 0–1 次，说明 ProMotion 已把回调降到 24 Hz，闸门几乎不用出手）。

## 3. 没做的和原因

- **摄像头 / 屏幕 / 文件 / 图片真跑**：实现在 W2-A（`SwitcherInputs`，并行会话，main 上还是骨架）。App 侧留了 `InputFactory` 接缝，这些输入现在是占位（画黑 + 文案）。G3 合并顺序里 w2-app 最后，接线是几行胶水。
- **录制 / 推流真跑**：`startRecord` / `startStream` 只改快照；`Recorder`（W1-E）和推流（W2-D）的接线归 G3 / W3-C。按钮文案按 `Stats.encoder` 说明现状，不假装在录。
- **音频**：没起混音器和输出设备（W2-E 集成）。Master 推子 / 静音只改快照；表没有电平字段可读。
- **外部输出窗口、多画面窗口、设置面板、每路音频条子、Wipe / Zoom / Stinger**：prompt 明确不做（W3）。
- **Add Input 完整版**（窗口 / 应用过滤、设备属性、文件浏览记忆）：W3-E。
- **快捷键配置化**：W2-C。
- **Add Input sheet 的截图**：`cacheDisplay` 截不到 AppKit 里 SwiftUI 底的控件（按钮 / 弹出菜单在 `_NSCoreHostingView` 里画），`CGWindowListCreateImage` 在 macOS 26 SDK 里已 unavailable，ScreenCaptureKit 要屏幕录制授权，`osascript` 发 ⌘I 要辅助功能授权（挂住了，已杀）。主窗口截图是用 shell 的 `screencapture -l<窗口号>` 截的。
- **挪到外接屏**：没有第二块显示器，测试代码写好了，接上就跑。

## 4. 对契约 / 规则的疑问

1. **`docs/OWNERSHIP.md` W2-B 行的路径 token 对不上实际文件**：表里是 `Packages/SwitcherCore/Sources/SwitcherRender/MetalDisplayView*`，W1-C 把文件放在 `SwitcherRender/Display/MetalDisplayView.swift`；`check-ownership.sh` 用 bash `[[ == ]]` 匹配（`*` 能跨 `/` 但要求前缀逐字相同），所以 `make lint BRANCH=w2-app` 报这两个文件越界（其余 34 个改动文件都在 `App/`）。prompt 明说 W1-C 的显示视图允许在此完善，我按 prompt 做了。**请把那个 token 改成 `Packages/SwitcherCore/Sources/SwitcherRender/Display/MetalDisplayView*`**（P0 补充规则说"不同意就改这里"，但 docs/ 不在我的允许路径里，我没改）。改完 lint 全绿：禁词 / 版本号 / Package 约束 / 依赖方向都过。
2. **状态行的"磁盘剩余"和"编码占用"**：`Stats.encoder` 只有 `skipped / bitrate`，没有磁盘剩余（提案 001 的 `disk_free_mb` 待批）也没有编码器占用。按铁律 4 我没在 UI 里另算（`FileManager` 一行就能拿到磁盘剩余，但那就是"各自另算"），显示 "—"。001 批了之后状态行加一个字段即可。"编码占用"建议就用 E1 的 skipped + 码率（现在显示的），要真正的编码器忙碌度得给 Stats 加字段。
3. **调音台的表读 Stats**：Stats 没有电平 / 响度字段。W2-E 的 prompt 写"表读数进 Stats 和快照"，那会是一次契约提案（建议 `audio` 一节加 `master_peak_dbfs`、`master_lufs` 或每总线一组）；批了之后 `MixerPanelView.apply(stats:)` 一行接上。
4. **输入缩略图靠切多画面纹理**：`DisplayFrameSource` 只给 PGM / PVW / 多画面三张，没有每路输入的纹理；`Renderer/*` 不是本会话的。副作用：缩略图里带着渲染器烧进多画面格子的名字标签（截图里每格左下角的 "1 合成 1 · 30 +音频"），和格子标题条重复；且缩略图分辨率 = 多画面格子（1080p 下 470×262）。W3-B / W3-E 若想要干净的缩略图，可给 `DisplayFrameSource` 加 `latestDisplayFrame(forInput:)`（渲染器已按 IOSurface 缓存输入纹理，`RenderSlot.heldFrames` 就是这一拍用过的帧）；这是 SwitcherRender 内部接口，不是契约。
5. **`Command.tbar` 到 1 才提交**：T-bar 拖到顶但还没松手时状态是 0.999（画面上等于完成），松手才发 1。若希望"到顶即提交"（不等松手），只需把拖动中的上限去掉——但那样拖到顶再往回拉会已经对调过。我按 prompt 的"到顶提交后回弹"理解成松手提交。
6. **合成源时间线**：App 里新加的路 t0 = 引擎的"现在之后第 3 拍"− 半个节目帧（同 headless 的默认 lead），不是引擎的 t0；否则 `SyntheticVideoInput` 从 t0 追帧会先狂产几千帧。这是 App 的组装细节，不改契约。
7. **`SwitcherTestKitSkeleton`**：P0 的 `App/Tests/SkeletonTests.swift` 已删（被 UI 冒烟替换），TestKit 那段占位（W1-A 注释里说"W2-B 换成 UI 冒烟测试后整段删除"）可以删了——归 W1-A / 检查点，我没动 TestKit。

## 5. 下一个会话需要知道的坑

1. **layer-backed 视图里 `draw(_:)` 用 `dirtyRect.fill()` 会把邻居也涂了**：第一版 `PanelView` 这么写，PGM 标题条的红色盖住了整个 PVW + 转场列（frame 全对，画出来不对）。改成 `wantsLayer + layer.backgroundColor` 就好。App 里所有纯色块都走图层背景色。
2. **AppKit 默认把第一响应者给窗口里第一个能编辑的控件（搜索框）**，数字快捷键全进搜索框。启动后 `window.makeFirstResponder(nil)`，搜索框回车 / Esc 归还焦点。
3. **合成的 `NSEvent` 鼠标事件经 `window.sendEvent` / `NSApp.postEvent` 都不会派发到视图**（AppKit 只认系统事件；键盘事件经 `window.sendEvent` 可以）。测试里自己做 `hitTest` + `mouseDown/mouseUp`。
4. **观察者别放字典**：遍历顺序不定，测试对照状态行时偶尔先于窗口更新读到上一秒的文字；按登记顺序回调。
5. **`NSView.displayLink` 遮挡不停**（探针 1）：要省 CPU 必须自己 `isPaused`；`NSWindow.didChangeOcclusionStateNotification` 只在事件循环真跑时才来（测试要 `NSApp.nextEvent` 泵事件，`RunLoop.run` 不够，W1-C 也这么写）。
6. **`CGWindowListCreateImage` 在 macOS 26 SDK 是 unavailable**，截图只能 ScreenCaptureKit（要授权）或 shell 的 `screencapture`；`bitmapImageRepForCachingDisplay` 截不到 Metal 图层和 SwiftUI 底的 AppKit 控件。
7. **GPU 占用**：`App/Sources/Engine/GPUUtilization.swift` 和 `Tools/switcher-headless/.../GPUUtilization.swift` 是同一份代码（Tools 不是库），建议检查点挪进 TestKit 或 Engine 让两边共用。
8. **Stats 只能有一个采样点**：`engine.makeStats()` 的窗口 = 上次调用到这次，UI 和 jsonl 必须共用同一次调用（`StatsPump`）。W2-C 的 API 若也要每秒 Stats，请从这个泵拿，别再调 `makeStats`。
9. **debug 构建下 8 路 1080p 合成源 CPU 106%**（每路每帧 CPU 画图案），release 约四分之一（G2 headless 24%）。真摄像头（W2-A）不画图案，没这个开销。
10. `xcodebuild test` 的宿主就是 App 本身：`AppDelegate.isTestHost`（`XCTestConfigurationFilePath` 或能找到 `XCTestCase` 类）时不恢复上次节目、不弹错误框、UserDefaults 用独立 suite。测试用 `AppTest.freshSession()` 每个用例换一个空节目。
11. `TEST_RUNNER_SWITCHER_HOLD=<秒>` 能让 Add Input sheet 停一会儿（给外部截图用）；xcodebuild 会把 `TEST_RUNNER_` 前缀的环境变量传给测试宿主。
12. `--show <路径>` 直接开节目文件，`--stats <路径>` 写 stats.jsonl；`scenarios/m0-show.json` 能直接打开（8 路合成源）。

## 6. 布局与 ui-mock 的差异清单

只借了布局和交互，没借品牌（文案里没有竞品名，`make lint` 禁词过）。

| ui-mock | 本期 | 理由 |
|---|---|---|
| 顶部工具条：Preset / New / Open / Save / Save As / Last / Fullscreen / Pause Inputs / Basic / Settings | 没有工具条；新建 / 打开 / 打开最近 / 保存 / 另存为在菜单"节目"，全屏用窗口标准按钮（`fullScreenPrimary`） | 一期骨架先做菜单，Pause Inputs / Basic / Settings 是设置面板的事（W3-E） |
| PVW 标题橙、PGM 标题绿 | **PVW 绿、PGM 红** | 广播惯例，落地方案 §7 第 3 条 |
| 标题条右侧色板 / 监视器 / 齿轮图标 | 只有编号、名字、PVW / PGM 角色字 | 输入设置在 W3-E |
| 转场列：Quick Play / Cut / Fade / Merge / Wipe / Fly / FTB，每个带下拉 | Cut / Fade / Wipe / Zoom / Stinger / FTB，无下拉；Wipe / Zoom / Stinger 置灰 | 设计方案 §1.1 的转场集合；Merge / Fly / Quick Play 不做 |
| 转场时长预设、Overlay 1–4 在转场列 | 同（0.5 / 1 / 2 s 分段控件；Overlay 1–4 小按钮） | — |
| T-bar 横向、在转场列底部 | 竖向、占转场列中段（0 底 → 1 顶） | 竖推杆更像硬件切换台，也给时钟留位置；方向固定 0 → 1（契约 progress 语义），提交后回弹 |
| 时钟 24 h + 12 h（"下午"） | 同（12 h 用系统区域格式，显示 AM/PM 或 上午/下午） | — |
| 输入条上方分类标签（视觉 / 开场视频 / 全部 + 色块） | 只有搜索框 | 分类 / 颜色标签是 W3-E 的输入管理 |
| 每格：Close / Quick Play / Cut / Loop 一行 + 1–4 + Audio + 监视器 / 齿轮 | 每格：Overlay 1–4 + 静音；右键：重命名 / 删除 | prompt 只要 1–4 和静音；删除放右键（稿子的 Close） |
| 右侧：OUTPUTS / INPUTS 竖标签、Master 推子 + 表 + 耳机旋钮 | Master 推子 + 表 + 静音 + A1 计数；面板可收起 | 每路条子、耳机监听在 W3-E / W2-E |
| 底栏：Add Input / Record / External / Stream / MultiCorder / PlayList / Overlay + 各自齿轮 | 添加输入 / 录制 / 推流 / 外部输出 / 多画面 / 叠加；无齿轮 | MultiCorder ≈ ISO 录制（W3-C 的 ISO），PlayList 不在第一版；设置齿轮 W3-E |
| 状态行：1440p59.94 EX FPS 60 Render Time 1 ms GPU Mem 3% CPU 2% Total 19% | 节目 1920×1080 60 · fps · render ms · GPU % · CPU % · 丢帧 · 编码跳帧 · 码率 · 磁盘 | 全部读 Stats（铁律 4）；GPU 显示的是设备占用不是显存 |
| 浅色 / 系统外观 | 强制深色（`darkAqua`） | 导播台在暗环境用；监视器四周不能亮 |
| Input Select 对话框：左列 20 多种类型、右侧文件列表、底部 Number + OK / Cancel | 左列 5 种（合成源 / 摄像头 / 屏幕 / 文件 / 图片）、右侧按类型的表单、底部编号 + 名字 + 取消 / 添加 | 最小版；完整版 W3-E |
