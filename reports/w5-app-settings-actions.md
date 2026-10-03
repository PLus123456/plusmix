# W5-J 设置体系合窗 + 共用"选动作"面板 + 控制层可绑动作补齐（prompt 96，分支 w5-app-settings-actions）

分支：`w5-app-settings-actions`（worktree `.claude/worktrees/w5-app-settings-actions-ee8dce`，worktree 自己的分支名 `claude/w5-app-settings-actions-ee8dce`，两个名字指同一个提交）。
**基线不是 main**：prompt 写"从 G6 合入后的 main 开"，但交付 1 要"⌘, / 工具条设置▾ / 各 ⚙ 打开同一个窗的对应页"，工具条（93）与底栏各 ⚙（92）都还没合进 main（main = `190fe32`），
所以照 93 的先例从 **93 的分支头 `w5-app-toolbar` = `8a13a21`**（含 92）开——94 / 97 / 98 也都叠在这个头上，只有 95 是从 main 开的。G7 按 92 → 93 →（94 / 95 / 96 / 97 / 98）合；它们与本分支在 App/ 的冲突见 §5 第 1 条。
机器：MacBook Pro M5 Max（128 GB），macOS 27.0，Xcode 27.0，接电源；第五波几个会话同机并行（97 的 App 用例和我的错开跑）。

提交（`git log 8a13a21..HEAD`）：
`15dc66a` 红灯轮（控制层：用例 + 新 API 只给签名）→ `f9a099b` 控制层实现 → `c36df63` **第一步：入口整理**（设置的入口一律走 `showSettings(page:)`）→
`2a5b8e1` **第二步：合窗** + 共用选动作面板（代码与用例；文案待补）→ `41e34db` 中英文案、用例时序修正 → 本报告。

## 1. 做了什么

**合窗做到了第二步（两步都做完）**：第一步（入口整理）单独提交在 `c36df63`；第二步（偏好设置 / 输出设置 / 快捷键 / MIDI 合成一个带侧栏的"设置"窗）在 `2a5b8e1` + `41e34db`。

| 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 第一步：入口整理（Q04 (a)） | `App/Sources/Settings/SettingsPage.swift`（新）、`UI/PanelCoordinator.swift`、`AppDelegate.swift` | 92 / 93 已经把各 ⚙ 和工具条"设置▾"指到现有的窗；这一步把它们收成一个入口 `PanelCoordinator.showSettings(page:)`（`SettingsPage`：本节目 = 节目格式 / 输出各页 / 节目音频，本机 = 常规 / 音频设备 / 远程控制 / Tally / 快捷键 / MIDI / 性能与电源 / 更新与诊断 / 高级）。⌘, 与工具条"设置"主体 = **回到上次那一页**（本机记忆 `SettingsLastPage`，没开过 = 常规）。合窗只换这一处 |
| 1 第二步：合窗（F1 / F4–F7、X29） | `Settings/SettingsWindow.swift`（新）、`Settings/PreferencesPanel.swift`（重写成各页）、`Settings/SettingsTransfer.swift`（新）、`UI/PanelCoordinator.swift`、`UI/AppMenus.swift`、`Settings/OutputSettingsPanel.swift`（只加 `showsTabList`、删窗口类）、`AppController.swift`、`AppSettings.swift`、`UI/Confirmation.swift` | 一个窗（标题"设置"）：左侧栏两组"本节目 / 本机"，页头写页名 + 存在哪（"本节目 · 随节目文件保存：另存、换节目时跟着节目走" / "本机 · 存在这台 Mac 上，所有节目共用"）。**提交方式统一即时生效**：本机的项改了就写 UserDefaults（AppSettings 同一组键）、换给 AppController，运行时能改的（外部显示层级、磁盘下限、备用目录）同时落到跑着的 session；要换引擎才用得上的（节目格式、节目音频、音频设备、本地 API、兼容层、PVW 预览全部叠加）记成**待应用**（= 想要的 ≠ 跑着的 session 用的，改回去就不算），页底写"有 n 项待应用：…"，项旁标"需重起引擎"，"应用并重起引擎"一次用上（一个新 session：格式 / 节目音频 / 本机设置一起），录制 / 推流在跑先确认（87 的 `confirmEngineRestart`，sheet 挂设置窗）。**快捷键 / MIDI 有没存的改动时关窗或切页先问 保存 / 放弃 / 取消**（存不了 = 不关、不切，错误写在表下面）。**换引擎时窗不关只重绑**：输出页换成新 session 的模型（页不变）、格式 / 节目音频重读、MIDI 的 learn / 来源换到新的控制器、快捷键表没改过就重读。**高级页**：录制磁盘下限（`recordMinimumFreeMB`，即时，跑着的引擎下一次开录起用）、备用录制目录（`recordFallbackDirectory`，即时，选择… / 清除）、本地 API 与兼容层监听地址（host:port，写错不存、红字说明；兼容层地址是新键 `compatLayerHost`，HTTP 端口仍固定 8088，98 做"仅本机 / 允许局域网"）。**底部** 导出设置… / 导入设置… / 恢复默认：一个 JSON 包 = 本机级 UserDefaults 键 + 快捷键表 + MIDI 表；访问令牌不导出；导入先列出"会覆盖：本机设置 n 项、快捷键表（m 条）、MIDI 映射（k 条）"再问；恢复默认只动本机级（令牌一并清掉），不动节目、不换引擎。**分辨率**加 2560×1440 与"自定义…"（宽 × 高两个框，取偶数、320×240 … 7680×4320）。数字框一律不加千分位。远程控制页（开关、令牌、当前监听只读、"改监听地址…（高级）"）、Tally 页、性能与电源页（只读机型 / 芯片 / GPU / 内存 / 系统）照实写现在有什么（开关是 98 的事）。**菜单**：工具条设置▾ = 设置… ─ 按侧栏顺序分组的全部页（段标题 本节目 / 本机）；App 菜单 设置… ⌘, / 快捷键… / MIDI 映射… / **所有设置页 ▸**（与设置▾ 同一批项）；输出菜单的设置页、底栏各 ⚙ 都打开同一个窗的那一页。老入口 `showPreferences()` / `showOutputSettings(tab:)` / `showHotkeyEditor()` / `showMIDIMapping()` 与 `preferencesWindow` 等属性照用：返回设置窗里那一页的句柄（`SettingsPageHandle`：model + 同一个 window，对象固定、`===` 比得住），所以老用例和 95 / 97 / 98 的用例不用改调用 |
| 2 共用"选动作"面板（N1 / N3 / N5，Q51–Q53） | `Settings/ActionCatalog.swift`（新）、`Settings/ActionPicker.swift`（新）、`Settings/HotkeyEditorPanel.swift`、`Settings/MIDIMappingPanel.swift`、`UI/HotkeyText.swift` | 快捷键表 / MIDI 映射每行的动作位置是一个按钮（一句话摘要："选进 PVW · 输入 1「合成 1」""叠加开关 · 通道 2"），点开 popover：顶部搜索（打开即获焦点，跨组搜动作名 / 说明 / API 键名）、左栏分组（切换 / 叠加 / 音频 / 输出 / 输入 / 节目 / 界面 / 全部 / 最近用过；MIDI CC 只有"推杆类"）、右栏我们自己的动作名 + 一行说明（命令 = `CommandCatalog` 的 summary；中文界面）+ 小字 API 键名（组合动作写出会发哪几条："previewAndTransition → setPreview + autoTransition"）、下方按类型化参数生成的表单与"按下时会发什么"（按当前快照解析，组合动作一行一条，就是进总线的那几条）。表单：输入 = "编号 · 名字"下拉 + 当前 PVW / 当前 PGM；时长按秒（0.5 / 1 / 2 + 自定义）；通道 1–4 分段；输出按类型过滤；总线四选一；开 / 关两段、开 / 关 / 切换三段。填好的值拼成那条动作的 JSON、用包里的 Codable 解——表单与 hotkeys.json / API 同一个写法。打开时定位到这一行现在的动作（参数也读回来）。**整条替换 / 增删类默认不列**，勾"显示整条替换类（高级）"或选"高级：手写 JSON…"（存之前校验）；按拍存的旧 Fade 只在它就是当前动作时列。快捷键表与 MIDI 表加**搜索框、复制行（键 / 触发空着）、每行"启用"勾**；新加的行没有动作，存之前要选（不兜底成任何命令，X10 的口径）；MIDI 存之前查"动作合不合触发"（Note 接按钮动作、CC 接推杆类）。87 的"其他命令"并进"高级"组 |
| 2 界面动作（Q53） | `Engine/ControlRuntime.swift`、`UI/MainWindowController.swift` | 显示 / 隐藏调音台、多画面窗口开 / 关、多画面窗口全屏：进快捷键表 / MIDI 音符（`ControlAction.ui(name:)`），派发器 / MIDI 控制器交给 App 设的 handler、回主线程由主窗口做，不进命令总线、不进 CommandCatalog |
| 3 控制层（N2，SwitcherControl） | `Hotkeys/ControlAction.swift`、`Hotkeys/ControlActionCatalog.swift`（新）、`Hotkeys/HotkeyDispatcher.swift`、`Hotkeys/HotkeyTable.swift`、`MIDI/MIDIMapTable.swift`、`MIDI/MIDIMapper.swift`、`MIDI/MIDIController.swift`、`CommandBus/CommandCatalog.swift`（只加描述） | `ControlAction` 补：输出开关（单路 `outputSwitch`、一类 `outputKindSwitch`：NDI® / 外部显示 / 虚拟摄像头 / 多画面）、`recordAll`（PGM + ISO 同一次发 = 同一拍起停）/ `recordISO`、`streamAll`、`inputAFV` / `busRoute` / `solo`（按快照改一位、整体写回 `setInputSettings`，没变不发）、`busMuteSwitch`、`overlaysOff`、`previewAndTransition`（setPreview → autoTransition）、`overlayInput`（一条 overlay 带 input）、`fadeMs`（Q52）、`ui`。开关类都带 `SwitchMode` 开 / 关 / 切换；输入可写 `"preview"` / `"program"`（`InputRef`，按下时解析）。**`resolve` 返回命令数组**；`HotkeyDispatcher` / `MIDIController` 在同一个任务里按顺序 submit，**前一条被拒就不发后面的**（不然 setPreview 失败后 autoTransition 会把原来的 PVW 推上去）。`HotkeyDispatcher.handleAllAndWait` 给每一条回执。每行 `enabled`（停用的不派发、不参与冲突）。JSON **只加新键**：旧的 `{"toggleMute":{"input":2}}` 照读（整数 = 编号）、写回仍是整数；`enabled` 只在停用时写。`CommandCatalog` 每条命令加类型化参数描述（格式见下），`CommandKind.operatorFacing` 标出整条替换 / 增删类；`ControlActionKind` 给每种动作同样的描述（参数、能发哪些命令、分组）。默认表按 Q29 补键（见下） |

### 1.1 CommandCatalog 参数描述的格式

只加描述、不加命令。`CommandDoc.fields: [CommandField]`（与已有的 `parameters` 同名同序，由 `CommandCatalog.fields(for:)` 的穷举 switch 给出，契约加命令这里编译就红）：

```swift
public struct CommandField { var name: String; var type: CommandFieldType; var optional: Bool }   // name = JSON 键
public enum CommandFieldType {
    case input(allowsBlack: Bool)     // 输入编号（"编号 · 名字"下拉；allowsBlack = 0 表示黑场）
    case inputRef                     // 输入：编号或"当前 PVW / 当前 PGM"（只在快捷键 / MIDI 动作里）
    case overlayChannel               // 1–4
    case output(kinds: [OutputKind])  // 输出编号，只列这几类（空 = 任何一类）
    case outputKind(kinds: [OutputKind])
    case bus                          // 0 master / 1 busA / 2 busB / 3 headphones
    case onOff                        // Bool
    case switchMode                   // "on" / "off" / "toggle"
    case durationTicks                // 拍（界面按秒、按节目帧率换算）
    case durationMs                   // 毫秒（界面按秒）
    case transitionType               // cut / fade / wipe / zoom / stinger
    case fraction                     // 0–1
    case decibels(min: Double, max: Double)
    case text
    case choice([String])             // 固定取值（rawValue）
    case json(String)                 // 结构体整体（InputSettings / OutputSettings / Show / 效果链 / Wipe·Stinger 参数……）：只能手写 JSON
}
extension CommandKind { public var operatorFacing: Bool }   // false：setTransitionParams setOverlay setOverlayDecoration setBusEffects
                                                            // setInputSettings addInput removeInput setInputSource addOutput removeOutput setOutputSettings loadShow
```

例：`setPreview` = `[input: .input(allowsBlack: true)]`；`overlay` = `[channel: .overlayChannel, on: .onOff, input: .input(allowsBlack: false) 可空]`；`setOutputEnabled` = `[output: .output([ndi, externalDisplay, virtualCamera, multiview]), on: .onOff]`；`audioGain` = `[input, dB: .decibels(−96, 24)]`；`setMonitorMode` = `[mode: .choice(["afl","pfl"])]`。规则（用例钉着）：面向操作员 ⇔ 参数里没有 `.json` 且不是删除。`ControlActionKind.fields / emits / group` 同一套类型（例：`busRoute` = `[input: .inputRef, bus: .bus, mode: .switchMode]`，emits `[setInputSettings]`）。`docs/api.md` 由 `APIDocument` 生成，它不读新字段，没变（`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 绿）。

### 1.2 新默认快捷键表（给 103 改手册：docs/user/快捷键.md、en/shortcuts.md）

| 键 | 动作 | 备注 |
|---|---|---|
| 1 … 9、0 | 选进 PVW 1 … 10 | 不变 |
| ⇧1 … ⇧0 | 直切 PGM 1 … 10 | 不变 |
| 空格 | Cut | 不变 |
| 回车 | 执行当前转场 | 不变 |
| F | FTB 开关 | 不变 |
| **⌥1 … ⌥4** | **执行转场 1 … 4**（转场槽 100 落地前 = 执行当前转场，与回车相同） | 新（Q29） |
| **⌃1 … ⌃4** | **叠加 1 … 4 开关** | 新（Q29） |
| 录制 / 推流 | **不给默认键** | Q29：快捷键一律不弹确认，误按一个键就停录 |

共 31 条（原 23）。"切换"菜单右列与转场列提示照实写，修饰键相同的连号写成"⌥1–⌥4"（"执行当前转场 | 回车、⌥1–⌥4"）；100 把 ⌥n 改绑"转场 n"后回车那一行就只剩回车。

### 1.3 默认键位与系统占用的实测（本机，macOS 27.0）

- 用 SkyLight 的只读查询（`CGSGetSymbolicHotKeyValue` / `CGSIsSymbolicHotKeyEnabled`，草稿区 20 行探针，不改任何设置）枚举系统符号快捷键 0–399：**⌃1–⌃4 = 系统"切换到桌面 1–4"（118–121），默认关着**；⌃⌥1–⌃⌥4（128–131）也关着；**⌥1–⌥4 没有任何系统快捷键用**。用户的 `com.apple.symbolichotkeys` 里只改过 ⌃空格 / ⌃⌥空格 / ⌘空格 / ⌘⌥空格。
- 结论：两组键在这台机器上都不被系统拿走；但用户若在 系统设置 › 键盘 › 键盘快捷键 › 调度中心 里打开"切换到桌面 n"，⌃1–⌃4 会先被系统截走——快捷键页顶上写了这句提示，默认表注释也写了。
- 测不了的：别的 App 注册的全局快捷键（`RegisterEventHotKey`）没法枚举；想用真 HID 事件试，测试进程没有发事件的权限（`CGPreflightPostEventAccess() == false`）。⌥ + 数字在文本框里会打出 ¡™£¢，主窗口没有焦点框时 `KeyCombo(event:)` 取 `charactersIgnoringModifiers` = 数字，不受影响（与 ⇧数字同一条路）。
- 对一遍参考的默认表：参考软件的快捷键页（截图 017）只有用户自己加的两行（F、Q 绑 Fade），没有内置的 ⌥ 数字 / ⌃ 数字键，撞不上；它的"Templates"（预置表）里有什么没截到。

## 2. 每个测试：数值 / 阈值 / 通过否

（功能用例，判据是行为 / 文案逐字相等；没有数值阈值。）

### 2.1 prompt 点名的用例

| 测试 | 看到的 | 通过 |
|---|---|---|
| `testPanels_settingsWindowOpensRequestedPage`（App） | ⌘,（没开过）→ 常规；App 菜单 快捷键… / MIDI 映射… → 对应页；⌘, 再按 → 上次那一页（MIDI）；工具条设置主体 → 上次那一页；设置▾ 与输出菜单的 7 个输出页、快捷键… / MIDI 映射… / 设置…；底栏 录制 ⚙ 两项、推流 ⚙、多画面 ⚙、外部显示 ⚙ 菜单末两项；推流主体（没有目的地）；App 菜单"所有设置页"的 20 页逐个点——**每一次都是同一个设置窗、侧栏选中的就是那一页**；窗标题"设置"、侧栏两组 9 + 9 页、页头存储说明逐字；设置▾ 的页 = App 菜单"所有设置页" | ✅ |
| `testPanels_settingsUnsavedHotkeysAskOnClose`（App） | 没改过直接关；改了没存 → 关窗先问（标题"快捷键有没保存的改动"，按钮 保存 / 取消 / 放弃改动，问在设置窗上）；取消 = 窗在、改动在；切页同样问、取消留在原页；放弃 = 关窗、再开是存过的表、派发器没变；保存 = 写文件、换给派发器、关窗；冲突存不了 = 不关、错误在表下；MIDI 页同一条规则（"MIDI 映射有没保存的改动"，放弃 = 切过去） | ✅ |
| `testPanels_advancedPageWritesRecordMinimumFree`（App） | 750 → UserDefaults `recordMinimumFreeMB` = 750、`controller.settings` = 750、跑着的 session `minimumFreeBytes` = 750 MiB、不算待应用、下次启动读得回；−5 → 存 0；备用目录即时写 / 清空删键、session 跟着变；API 监听 `0.0.0.0:9876` 存、记成待应用；`nope:99999` 报错不存；兼容层 `0.0.0.0:8100` 写 `compatLayerHost` / `compatLayerPort`；1500 显示"1500" | ✅ |
| `testHotkeys_compoundActionEmitsCommandsInOrder`（SwitcherControl） | "选进 PVW 并转场"解析成 `[setPreview(3), autoTransition]`；同步入口两条回执序号连续、日志里两条按顺序、来源 hotkey、推 4 拍后 PGM = 3 / PVW = 1；异步入口同样连续；输入不存在 = 一条都不发；逐条提交的口径：前一条被拒（抛 CommandRejection）后一条不发、不占序号 | ✅ |
| `testHotkeys_millisecondFadeConvertsByCurrentFrameRate`（SwitcherControl） | 1000 ms：30p = 30 拍、60p = 60、59.94p = 60、25p = 25、29.97p = 30；500 ms @30p = 15；0 = 0、负数钳 0；真走总线：30p 与 60p 下转场时长 ÷ 帧率 = 1.000 s；JSON 键 `fadeMs` / `durationMs` 往返 | ✅ |
| `testHotkeys_legacyTickFadeStillLoads`（SwitcherControl） | 旧表（按拍 Fade、整数输入、没有 enabled 键）照读；按拍的照拍数发（60p 下 0.5 s）；存回不改写旧动作、不多写 enabled、整数输入仍是整数；MIDI 旧表同样 | ✅ |
| `testUI_actionPickerListsOnlyOperatorCommandsByDefault`（App） | 9 个分组；"全部"里没有任何 `operatorFacing == false` 的命令（Q51 点名的五条都不在）、按拍 Fade 不在、毫秒 Fade / 高级 JSON / 界面动作在、推杆类不在；`setPreview` 名"选进 PVW"、说明 = CommandCatalog summary、API 键名 `setPreview`；组合动作 API 键名写出两条；每项都有名字和说明；分组、跨组搜索；勾"显示整条替换类"才列出（标高级、从样例起步）；MIDI CC 只有推杆类三项 | ✅ |
| `testHotkeys_defaultTableHasNoRecordOrStreamKeys`（SwitcherControl） | 31 条、无冲突；没有任何一条绑录制 / 推流（含解析后会发 start/stop 的）；⌥1–⌥4 = 执行当前转场、⌃1–⌃4 = 叠加开关；原有键不变；每条有备注 | ✅ |

### 2.2 本会话另加的用例

| 测试 | 看到的 | 通过 |
|---|---|---|
| `ControlActionTests.testHotkeys_switchActionsResolveAgainstState` | 输出单路 / 一类开关、全部录制（同拍一批）/ 只 ISO、推流全部、每路 AFV / 路由 / 独听（整体写回、没变不发）、总线静音、叠加全关 / 换输入并开、当前 PVW / PGM、黑场解析不出、界面动作不发命令 | ✅ |
| `ControlActionTests.testHotkeys_newActionsJSONRoundTrip` | 16 种新动作 JSON 往返、mode 缺省 = 切换、"preview" / "program"、认不出的值报错、MIDI 同样 | ✅ |
| `ControlActionTests.testHotkeys_disabledBindingIsIgnoredAndDoesNotConflict` | 停用的行不派发、不算冲突、只写 `"enabled": false`；MIDI 同样 | ✅ |
| `ControlActionTests.testMIDI_noteCompoundActionResolvesInOrder` | 音符绑组合动作按顺序、松开不发、老的单条入口给第一条 | ✅ |
| `ControlActionTests.testHotkeys_actionKindsDescribeFieldsLikeJSON` | 每种动作的参数描述 = JSON 那一层的键、能发的命令、分组 | ✅ |
| `ControlActionTests.testHotkeys_uiActionGoesToHandlerNotBus` | 界面动作交给 handler、不进总线、不算解析不出 | ✅ |
| `CommandCatalogTests.testCatalog_typedFieldsMatchExampleKeysAndWholeReplaceIsAdvanced` | 34 条命令的类型化描述与参数说明同名同序、是样例 JSON 的键；面向操作员 ⇔ 无 json 参数且不是删除 | ✅ |
| `SettingsWindowTests.testPanels_settingsWindowRebindsAcrossEngineRestart` | 2560×1440 在预设里；改格式 → 待应用 [节目格式]，再改 PVW 全部叠加 → "有 2 项待应用：节目格式、PVW 预览全部叠加"，改回去就不算；自定义 1000×600；应用并重起 → 换 session、输入带过去、**窗不关、页不变**、待应用清空、输出页的命令落到新 session；推流在跑 → 先问（挂设置窗）、取消不换、仍待应用 | ✅ |
| `SettingsWindowTests.testPanels_settingsExportImportAndRestoreDefaults` | 导出包里有本机键、两张表，没有令牌、没有节目内容；恢复默认先问、本机设置 / 两张表回默认、页面读回、节目不动；导入先列"快捷键表（32 条）""MIDI 映射（1 条）"再问、写回且表也写文件；坏文件报错不改 | ✅ |
| `ActionPickerTests.testUI_actionPickerBuildsActionsFromTypedFields` | 表单 → 动作（选进 PVW 并转场 / Fade 0.75 s = 750 ms / 叠加换输入 / 输出开关只列四类 / 总线静音 / setTransition 2 s = 120 拍 / 界面动作）、预览逐条、解析不出照实写、打开时定位并读回参数、旧 Fade 原样拼回、最近用过、MIDI CC / 音符 | ✅ |
| `ActionPickerTests.testUI_hotkeyTableSearchDuplicateAndEnable` | 行上摘要、搜索（键 / 摘要 / 备注）、复制行（插下面、键空着、空键存不了）、停用存进表且不派发、停用不冲突启用就冲突、放弃改动、新行要选动作才存 | ✅ |
| `ActionPickerTests.testHotkeys_uiActionTogglesMixerFromKeyboard` | 绑 M = 显示 / 隐藏调音台：按两次收起再展开，命令总线序号不动；认不出的名字只提示 | ✅ |

### 2.3 改到的旧用例（判据不动）

| 用例 | 改了什么 |
|---|---|
| `HotkeyTests.testHotkey_toggleActionsResolveAgainstState` | `resolve` 返回数组：期望值包一层 `[]`，解析不出 = `[]` |
| `HotkeyTests.testHotkey_defaultTableMatchesDesignAndHasNoConflicts`、`ControlEditorTests`（两处）、`ShortcutAndShowTests` | 默认表 23 条 → 31 条（Q29 补的 8 条） |
| `ToolbarMenuTests.testUI_switchMenuShowsHotkeysFromTable` | 右列期望值跟着默认表：执行当前转场"回车、⌥1–⌥4"、Overlay n 有"⌃n"；原来"给 Overlay 1 加一个 ⌥1"（现在 ⌥1 已被默认表占用、会冲突）改成"把 Overlay 1 从 ⌃1 换成 ⌥⇧1"，判据（右列跟着表变）不变 |
| `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` | 工具条"设置"主体打开的是"上次那一页"（⌘, 同一个动作），断言改成"设置窗开着、停在 currentSettingsPage"；"设置▾ = 菜单栏同一批项"把 App 菜单"所有设置页"子菜单算进来 |
| `TransitionColumnTests.testUI_transitionTooltipsFromHotkeyTable` | T-bar 那一行的提示期望值"回车、⌥1–⌥4：按这里选的转场执行"；追加的 ⌥1 → ⌥⇧1（同上，避开默认表），并先删掉默认的 ⌃1 |
| `HonestUITests.testHotkeys_otherCommandNotRewrittenToCut`（87） | 平铺下拉连同"其他命令"那一项没了（N4：并进高级组），按新面板改写，逐条对应：读进来的命令原样在行里；人话显示、整条替换类用命令目录说明；**打开面板看一眼再关不丢命令、原样拼回**（对应"改成别的再改回来命令还在"）；新行没有动作就存不了、报"第 4 行还没选动作…"、不写文件、绝不兜底成 Cut；高级 JSON 解不出拼不出动作；"编辑 JSON…"校验过才写、认得出的命令回到对应的动作；原样存回；MIDI 同一句、同一项 |

### 2.4 全量

- SwitcherControl 全包 `swift test`：SwitcherControlTests **41 条 0 失败**、VMixCompatTests 25 条（1 跳，原来就跳）0 失败、TallyTests 3 条 0 失败。
- `make test-app`：见 §2.5（全量跑完后填）。
- `make lint BRANCH=w5-app-settings-actions`：禁词 / 版本号 / Package.swift / 依赖方向通过；**归属一项相对 main 多出 `reports/w5-app-bottom-bar.md`、`reports/w5-app-toolbar.md`**（92 / 93 的报告，叠放带进来的，与 93 当时同样情况），`scripts/check-ownership.sh w5-app-settings-actions --base w5-app-toolbar` = "38 个改动文件都在允许范围内"；check-links、check-rt-symbols 通过。

## 3. 没做的和原因

1. **E6 快捷按钮小窗**（prompt 写"可选"）：没做。动作目录 / `ActionText` 已经能给每条绑定出"大字备注 + 小字动作"，做瓦片窗只差界面。
2. **E4 底栏 ≡ 工具菜单**（prompt 写"≡ 缓做"）：没做。
3. **转场槽动作**（100）、**随包手册**（103）、契约：按 prompt 不做。⌥1–⌥4 现在绑"执行当前转场"，100 改成"转场 n"。
4. **"节目音频"仍是两项（对齐延迟、监听点）**，**音频设备页只有设备**：每条总线选声道是 97（J8）的事；**Tally、性能与电源页只放说明 / 只读信息**：开关是 98 的事。远程控制页的监听地址只读、要改去"高级"——98 换成"仅本机 / 允许局域网"。
5. **旧键没全删**：`prefs.*` 与 `*.windowTitle` 这些现在没人用的文案键留着（95 / 97 / 98 是从 main 开的，可能还在用；留着不影响用例），只删了只有旧的平铺下拉用的 `hotkeys.action.*` / `hotkeys.arg.*` / `midi.minDb` 等。G7 合完可以统一清。
6. **ISO 页"还能录多久"的余量**按设置窗打开时的磁盘下限算；高级页改了下限之后要换一次 session（或重开设置窗）才跟上。只影响估算文字。

## 4. 对契约的疑问

没有改契约，也没有提案：新动作全是 App / 控制层的东西（`ControlAction`、hotkeys.json / midi.json 的新键），命令一条没加；`CommandCatalog` 只加描述。一点给 P5 / G7 参考：每路跟随视频、总线路由、独听没有单独的命令，快捷键只能按快照改一位后 `setInputSettings` 整体写回——快照和应用之间别处改了同一路的设置会被盖掉（概率很低，和输入设置窗同一个口径）。要彻底就加细粒度命令（契约变更，不在本会话）。

## 5. 下一个会话需要知道的坑

1. **G7 合并**：本分支叠在 93（含 92）上；94 / 97 / 98 也叠在 93 头上，95 从 main 开。它们都会动 `PreferencesPanel.swift` / `OutputSettingsPanel.swift` / `PanelCoordinator.swift` / `AppSettings.swift` / 两份 strings：偏好设置的长表单在本分支已拆成页（`ShowFormatPage` … `AdvancedPage`），**97 的"音频设备"一节（每条总线选声道，新键 `AppSettings.busOutputMap`）搬进 `AudioDevicePage`，`busOutputMap` 还要加进 `SettingsTransfer.keys`（导出 / 导入 / 恢复默认）**；98 的远程控制 / Tally / 性能页替换本分支的占位页；95 给 `OutputSettingsModel.Tab` 加的页（如"输出总览"）会自动出现在设置窗侧栏和设置▾（`SettingsPage.pages` 按 `Tab.allCases`），但 `OutputSettingsView` 的 body 在本分支多了 `showsTabList` 分支，95 改 body 时会冲突。97 把测试宿主的 defaults suite 改成按构建路径分开（`AppController.testDefaultsSuite`），`SettingsTransfer` 用的就是这个常量，合并后不用改。老入口 `showOutputSettings(tab:).model` 等保持不变，各分支的用例不用改调用。
2. **确认框收起前 `performClose` 什么都不做**（sheet 还挂着）：设置窗用例每答完一问先等 `window.attachedSheet == nil`。
3. **测试宿主里 `AppController.settings` 会被改回 API 端口 0、空音频设备**（`applyTestHostOverrides`），所以"待应用"按 PreferencesModel 自己的值和 `session.settings` 比，不按 `controller.settings` 比；UserDefaults 里存的是用户填的值。
4. **`@Published` 属性的 didSet 里别给自己赋值**：磁盘下限的负数在 commit 里钳、页上的框也钳。
5. **`SettingsPageHandle` 的闭包不能叫 `get`**（`var model: Model { get(owner) }` 会被当成 getter 关键字）。
6. **新文件要 `make gen`** 才进工程（不然 `cannot find … in scope`），第一次 `xcodebuild -quiet build-for-testing` 有时只报"failed with exit code 0 but produced no further output"，不带 -quiet 再编一遍就过（Xcode 27 的毛病，记忆里有）。
7. **快捷键表的右列 / 提示**按"所有启用的绑定"列，修饰键相同的连号数字（≥ 3 个）合成"⌥1–⌥4"（`HotkeyText.keys`）。
8. 手册要跟着改（103）：§1.2 的默认表；"偏好设置 / 输出设置 / 快捷键 / MIDI 映射 四扇窗"→ 一个"设置"窗（侧栏两组、页底"应用并重起引擎"、导出 / 导入 / 恢复默认、高级页）；快捷键 / MIDI 的"选动作"面板、搜索 / 复制 / 启用；毫秒 Fade 与旧的按拍 Fade；界面动作；手册里"磁盘下限在偏好设置能改"现在属实（设置 › 高级）。
