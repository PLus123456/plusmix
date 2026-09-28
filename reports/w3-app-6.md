# W3-E5 App：素材相对路径、状态行按输出编号、LastSession 跟配置目录（prompt 79，分支 w3-app-6）

分支 `w3-app-6`，从 main `4c43fd4`（W2-C2 合入后的跟改）开，worktree `.claude/worktrees/w3-app-6`。用户 2026-09-28 指派 agent 直接做。
机器：MacBook Pro M5 Max，macOS 27.0（26A428），Xcode 27.0（27A266a），接电源，本机装了 NDI SDK for Apple。
只动 App/ 与 Samples/README.md（只删"App 修好前的临时办法"一段）+ 本报告；`scripts/check-ownership.sh w3-app-6` 全绿。

## 1. 做了什么

| 交付 | 提交 | 落在哪 | 说明 |
|---|---|---|---|
| 1 素材相对路径相对节目文件 | `6386187` | `Engine/InputRuntime.swift`、`Engine/SwitcherSession.swift`、`Show/ShowDocuments.swift`、`AppController.swift`、`Tests/InputWiringTests.swift`、`Samples/README.md` | `InputRuntime.resolvingMediaPaths(_:against:)`：图片 / 视频文件输入的非 `/` 开头路径挂到基准目录下（与 headless `HeadlessRun` 第 1 步同一条规则：`path.hasPrefix("/") ? path : base/path`），绝对路径与别的来源原样；只在 `add()` 调 `factory.makeInput` 前改交给输入对象的那份配置，运行表的 `Entry.config`、快照、节目文件仍是相对路径（reconcile 比较 source 也不受影响）。基准 `InputRuntime.mediaBaseDirectory` 由 `SwitcherSession.init(…, mediaBaseDirectory:)` 给，`AppController.replaceSession` 传 `ShowDocuments.mediaBaseDirectory` = `currentURL` 所在目录，节目没保存过（新建 / 从 LastSession 恢复）退到默认录制目录 `~/Movies/PlusMix`（与 `OutputRuntime.startRecordings` 对相对录制目录的口径一致）。`AppController.write(_:to:)`（保存 / 另存）之后把 session 的基准换成新位置：只影响之后建的输入，已在跑的路不重建（素材要跟着搬，Samples/README.md §2 已写）。`DefaultInputFactory` 没动（issue 给的两个位置里选了 InputRuntime，工厂仍是纯"配置 → 对象"）。Samples/README.md 删掉"App 修好前的临时办法"一段（含从样例目录起 App 的命令） |
| 2 状态行按输出编号对号 | `ab73cee` | `UI/StatusLineFormatter.swift`、`UI/BottomBarView.swift`、`Tests/StatusLineTests.swift` | `StatusLineFormatter.activeEncoder(in:kinds:)` / `fields` / `line` 的 `kinds` 从 `[OutputKind]?`（与 encoder 同序、个数要对得上）改成 `[Int: OutputKind]?`（输出编号 → 类型）：在跑的项里先找按 `EncoderEntry.output` 查到类型是录制 / 推流的，都没有才退到第一个在跑的（NDI，或表里没有的编号——输出刚删、这行 Stats 还是上一秒的）；nil 仍是不分类型。`BottomBarView.apply(stats:)` 从快照建 `[number: kind]`（`uniquingKeysWith` 取先出现的，保险）。W3-E3 的旧断言改成按编号给类型，语义不变；"个数对不上 = 不分类型"那条变成"表里没有录制 / 推流的编号 = 退到第一个在跑的" |
| 3 LastSession 路径 + 删 MIDI 锚 + 旧注释 | `9bcc832` | `Show/ShowDocuments.swift`、`AppController.swift`、`Settings/HotkeyEditorPanel.swift`、`Engine/ControlRuntime.swift`、`Release/CrashDiagnostics.swift`、删 `Engine/MIDINotificationAnchor.swift`、`Tests/ControlEditorTests.swift`、`Tests/ShortcutAndShowTests.swift` | `ShowDocuments.autosaveURL` = `UserConfig.directory.appending(path: "LastSession.\(fileExtension)")`（`import SwitcherControl`），与 hotkeys.json / midi.json / Diagnostics/ 同在 `~/Library/Application Support/PlusMix`；0.1.0 没发布过，老位置不迁移。四处注释里的 `Application Support/Switcher` 改成 PlusMix。**MIDINotificationAnchor 二选一选"删"**：W2-C2 起包里的 `MIDIHost` 在进程级常驻线程上先建了永不销毁的锚客户端，控制器的客户端 / 输入口 / 通知处理都在那条线程上，App 再留一个主线程锚只是同一件事的第二份解释 + 第二个 CoreMIDI 客户端（留着也能跑：第一个客户端在主线程、通知落主 run loop，控制器再跳回宿主线程），删了之后热插拔只有一个归属（包），出问题只查一处。一起改：`AppController.init` 不再 `install()`（注释改成指向 MIDIHost 与守门用例），`ControlEditorTests:83` 的 `isInstalled` 断言删掉、注释改写；守门用例 `testMIDI_hotplugAfterShowReplaced_newSourceConnects` 原样留着，删锚后照过（§2） |

提交见 `git log main..HEAD`（每条交付一个提交，最后一个是本报告）。

## 2. 每个测试：数值 / 阈值 / 通过否

### 2.1 本会话的用例（先写用例再实现；红灯轮见 2.2）

| 交付 | 测试 | 数值 | 判据 | 通过 |
|---|---|---|---|---|
| 1 | `InputWiringTests.testW3E5_relativeMediaPathResolvesAgainstShowFile` | 纯规则：`assets/logo.png` → `/tmp/节目目录/assets/logo.png`，文件输入的 endAction / rate 原样，绝对路径 / 合成源原样，没保存过的 `ShowDocuments.mediaBaseDirectory` = `~/Movies/PlusMix`；经 App：节目在临时目录 A、640×360 纯色 PNG 在 A/assets/、进程 cwd 改到 B（cwd 下确认没有 assets/logo.png）→ 打开后 `documents.mediaBaseDirectory` = `session.mediaBaseDirectory` = A、输入 1 **state = live**、Stats `per_input[1].fps > 0`、PGM 中心 = 图片颜色 (30, 180, 220)；快照与 `makeShow()` 仍是 `.image(path: "assets/logo.png")`；另存到 B 后文件里仍是相对路径、基准变成 B、输入 1 仍 live（不重建）；被拒命令 0 | live、fps > 0、相对路径原样 | ✅ 1.6 s |
| 2 | `StatusLineTests.testW3E5_statusLinePicksEncoderByOutputNumber` | 输出表 [1 录制, 2 推流, 3 NDI]，一行顺序颠倒的 Stats [NDI(3) publishing 1990 Mb/s, 录制(1) recording 6 Mb/s, 推流(2) idle] → activeEncoder.output = 1、字段 ["2", "6.00 Mb/s"]；录制 / 推流都在跑取 Stats 里先出现的（[NDI, 推流, 录制] → 4.00 Mb/s；[录制, NDI, 推流] → 6.00 Mb/s）；只有 NDI 在发（不管排哪）→ 1990.00 Mb/s；都不在跑 → —；不给类型 → 第一个在跑的（NDI）；过期编号 9（表里没有）在跑 + 录制在跑 → 录制；过期编号 + NDI → 退到第一个在跑的（9）；端到端 `BottomBarView.apply(state:)` + `apply(stats:)` 两行 → 状态行含「编码跳帧 2  ·  码率 6.00 Mb/s」，录制停了含「编码跳帧 1  ·  码率 1990.00 Mb/s」 | 逐项相等 | ✅ 0.005 s |
| 3 | `ShortcutAndShowTests.testW3E5_lastSessionLivesInUserConfigDirectory` | `autosaveURL` == `UserConfig.directory/LastSession.switcher.json`；所在目录 == hotkeys.json / midi.json / `CrashDiagnosticsStore.defaultDirectory` 的所在目录；目录名 PlusMix、路径里没有 "Switcher" 段；扫 App/Sources 所有 .swift：`Application Support/Switcher` 与 `MIDINotificationAnchor` 0 处；`Engine/MIDINotificationAnchor.swift` 不存在 | 逐项相等、0 处 | ✅ 0.02 s |
| 3（守门） | `ControlEditorTests.testMIDI_hotplugAfterShowReplaced_newSourceConnects`（原有，删了 `isInstalled` 断言） | 删锚后：换两次节目、之后建的虚拟源 5 s 内连上，销毁后消失 | 连上 / 消失 | ✅ 0.96–1.15 s（两轮） |

改了断言 / 调用的旧用例：`StatusLineTests.testStatus_formatterFields` 的 W3-E3 段（`kinds` 改成 `[1: .ndi, 2: .record]`、entries 带 `output:`）；`ControlEditorTests` 两处注释。

### 2.2 红灯轮（证明用例抓得到老行为）

实现写完后把三处临时退回老行为（`InputRuntime.add` 把 `config` 原样交给工厂；`activeEncoder` 用"按编号排序的类型表与 encoder 按顺序 zip"的老算法；
`autosaveURL` 拼回 `Application Support/Switcher/…`），只跑这三条：**3 / 3 红，15 处断言失败，红的位置就是各自要验的点**——
1：`state = error("图片不存在：assets/logo.png")`、`per_input[1].fps = 0.0`、PGM 中心 (0, 0, 0)；2：`activeEncoder.output` = 3（NDI）、字段 ["1", "1990.00 Mb/s"]、底栏状态行「编码跳帧 1 · 码率 1990.00 Mb/s」；
3：`…/Application Support/Switcher/LastSession.switcher.json`、目录名 "Switcher"。之后按备份原样恢复（`grep RED-ROUND` 0 处），再跑 4 条（三条 + 守门）全绿。
交付 1 / 2 的用例引入新 API（`resolvingMediaPaths`、`mediaBaseDirectory`、`kinds: [Int: OutputKind]`），退回 main 是编不过，所以红灯轮退的是行为、不是 API。

### 2.3 全量 `make test-app`（每轮开跑前 `pgrep -fl "xcodebuild .*test"` 都查过没有别的会话在跑 App 测试）

`make test-app` 带 `-quiet` 不打用例行，计数从 `.build/DerivedData/Logs/Test/*.xcresult` 用 `xcrun xcresulttool get test-results summary / tests` 读。
上一轮 W3-E4 的 App 全量 86 个；之后 W3-C3 / W2-C2 等合入 main 又加了几条，本会话 +3（W3E5 三条）= **95 个**。

| 轮 | 时间（测试段） | 结果 | 说明 |
|---|---|---|---|
| 1 | 17:52:09–17:55:50（220 s），负载 2.9 | 95 个：92 过、**1 失败**、2 跳 | 失败 `ThumbnailRateTests.testThumbnail_refreshRateAtMost24fpsWhileMonitorsRunFullSpeed`：缩略图 0 fps、**PGM / PVW 监视器也 0 fps**——整个主窗口的 display link 没在跑，就是 memory 里记的"显示类测试窗口被盖住就红"；这一轮摄像头用例在等系统的摄像头权限提示（跳过、BLOCKED-权限），那个系统对话框大概率就是盖住主窗口的东西。单独复跑该类：2 / 2 过（缩略图 23.99 fps、PGM / PVW 60.0 fps） |
| 2 | 17:56:52–18:00:26（214 s），负载 1.7 | 95 个：93 过、**1 失败**、1 跳 | 摄像头权限这一轮已经有了（`testInputs_builtInCameraLiveWithin5sAndPictureShows` 真跑、过），只剩虚拟摄像头 L1 一条 BLOCKED-签名。失败 `StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous`：Stats 侧 publishing、dropped 0、skipped 0，都过；**MediaMTX 落盘文件**经 frameprobe 有 1 个缺口、123 帧——传输 / 落盘那一侧的事（memory："frameprobe 自证不能用于实时喂送 / 传输类录像"），与本会话改的输入路径 / 状态行 / 自动保存无关。单独复跑见第 3 轮前 |
| 3 | 18:01:54–18:05:27（213 s），负载 1.8 | **95 个：94 过、0 失败、1 跳**（`make test-app` 退出码 0） | 开跑前先单独复跑第 2 轮红的 `StreamWiringTests`：过（落盘 639 帧、缺口 0、重复 0、解不出 0，16.9 s）。这一轮唯一跳过的是虚拟摄像头 L1（BLOCKED-签名）；摄像头用例真跑、过。xcresult：`.build/DerivedData/Logs/Test/Test-Switcher-2026.09.28_18-01-54-+0800.xcresult` |

跳过的（都是原有的）：`testInputs_builtInCameraLiveWithin5sAndPictureShows`（BLOCKED-权限：测试宿主没有摄像头权限，只在第 1 轮跳；第 2 轮起测试宿主有了摄像头权限就真跑——
权限是系统对话框给的，不是本会话改了什么）、`testL1_virtualCameraEgress_requiresSignedExtension`（BLOCKED-签名：解锁 = Team ID 签名 + /Applications + 允许扩展）。
三条 W3E5 用例与守门用例三轮都过；第 1 / 2 轮各红一条显示类 / 传输类用例、单独复跑与第 3 轮全量都过，是环境（窗口被盖 / MediaMTX 落盘）不是代码，没改任何阈值或断言。

LocalizationTests 全过：本会话没有新文案（三条交付都不加界面文字，两份 Localizable.strings 没动），`testL10n_noHardcodedChineseInUISources` 等照过。
release 版 frameprobe 已编（本 worktree `swift build -c release --package-path Tools/frameprobe`，46.8 s），ISO A4 / 推流那几条真跑了、没有 BLOCKED-工具 的跳过。

### 2.4 lint / 链接

- `make lint BRANCH=w3-app-6`：禁词 / 版本号 0.1.0 / Package.swift 约束、依赖方向（8 个包）、归属（15 个改动文件都在 App/ 与 Samples/README.md）、`check-rt-symbols` 全绿。
- `python3 docs/tools/check-links.py`：119 个 Markdown 的相对链接与锚点都能解析，Samples 节目文件合法（Samples/README.md 删段之后）。

## 3. 没做的和原因

1. **另存到别的目录不重建已在跑的输入**：基准目录换了只影响之后建的路。已在跑的路仍用打开时解析出的绝对路径，直到下次打开；节目文件里是相对路径，
   所以"另存为"到别处再打开要素材跟着搬（Samples/README.md §2 早就这么写）。要"另存时自动复制 assets/"是另一件事（用户没要）。
2. **`~` 不展开**：与 headless 同一条规则只认 `/` 开头是绝对路径；`~/x.png` 会被当相对路径挂到节目目录下。headless 也这样，两边一致；要展开得两边一起改（Tools 不归本会话）。
3. **相对录制目录仍挂到 `~/Movies/PlusMix`**（`OutputRuntime.startRecordings` 第 285 行，W3-C 定的口径），没改成相对节目文件：Samples/README.md §2 写的就是这个口径，两种相对路径基准不同是文档化的既定行为。
4. **docs 里的旧配置目录没改**（不归本会话，prompt 83 / W4-B2 行）：`docs/user/概念.md:90`、`docs/user/快捷键.md:25 / :57`、`docs/user/en/concepts.md:98`、`docs/user/en/shortcuts.md:28 / :60`、
   `docs/release/diagnostics.md:7`、`docs/checklists/G3.md:60` 仍写 `~/Library/Application Support/Switcher/…`，改成 PlusMix 即可（LastSession 那两行现在是对的目录名之外还对上了文件名）。
5. **`Stats.EncoderEntry.output = 0` 的项**（老 stats.jsonl 行、或没填编号的项）在状态行里对不到任何输出，按"表里没有的编号"处理：只在没有对得上号的录制 / 推流在跑时才会显示它。App 只读自己实时的 Stats（三处 statsEntry 都填了编号，W3-E4），所以实际不会出现。

## 4. 对契约的疑问

没有新的契约变更请求。`InputSource.image(path:)` / `.file(path:…)` 里存相对路径、由宿主按各自的基准解析，是既有口径（headless 早就这样），本会话只是让 App 与它一致；
"相对路径的基准是节目文件所在目录"这一句现在只写在 Samples/README.md §2 与代码注释里，要不要进 CONTRACTS.md §2.x（`InputSource` 的说明）请契约会话看着办。

## 5. 下一个会话需要知道的坑

1. **`SwitcherSession.init` 多了 `mediaBaseDirectory: URL? = nil`**（尾参数、有默认值）：别的分支直接 `SwitcherSession(show:…)` 的调用不用改；测试里 `AppTest.freshSession()` 走 `newShow` → 基准 = `~/Movies/PlusMix`。
   要让某个 session 用别的基准：`session.mediaBaseDirectory = …`（setter 直通 `InputRuntime`），只对之后 `add` 的输入生效。
2. **`StatusLineFormatter.activeEncoder / fields / line` 的 `kinds` 现在是 `[Int: OutputKind]?`**：别的分支若还传 `[OutputKind]`（数组）编不过，改成 `[输出编号: 类型]` 即可（BottomBarView 的建法一行）。
3. **`MIDINotificationAnchor` 没了**：App 里任何地方再引用它编不过；热插拔归包里的 `MIDIHost`（internal，App 引用不到，也不需要）。守门用例仍在 `ControlEditorTests`。
4. **测试写的是真的 LastSession**：`ShortcutAndShowTests.testShow_newSaveOpenRecentAndAutosave` / `testShow_openedFileDoesNotAutoStartOutputs` 调 `docs.autosave(show)`，
   `autosaveURL` 是 static、不分测试宿主，所以跑 App 测试会往本机 `~/Library/Application Support/PlusMix/LastSession.switcher.json` 写一个测试节目（改之前写的是 …/Switcher/，同样的事）。
   真 App 启动先看"上次文件"（真实 UserDefaults，测试宿主是独立 suite），只有没有上次文件时才读 LastSession，所以影响是"开发机上第一次起 App 可能恢复出测试节目"。
   要断掉：给 `ShowDocuments` 加一个实例级 `autosaveURL`（测试宿主指到 `switcher-tests/config/`），两条旧用例改用实例的；本会话没做（prompt 指定的是 static 那一行）。
5. **cwd 敏感的用例**：`testW3E5_relativeMediaPathResolvesAgainstShowFile` 把进程 cwd 改到临时目录 B、`defer` 里改回；用例中途崩了 cwd 就留在 B（下一条用例若用相对路径会受影响——App 测试里没有别的用相对路径的）。
6. **`make test-app` 的输出看不出跑了几个用例**（W3-E4 §5 第 8 条仍成立）：计数从 xcresult 读；读过之后 bundle 的 mtime 会变，别再按 `ls -t` 取"最新"。
   本会话第一次跑定向用例时 `-only-testing:SwitcherTests/ShortcutAndShowTests` 列出的 8 条里没有新用例——python 往文件末尾追加时落进了同文件第二个类 `AddInputSheetTests` 里；
   往有多个类的测试文件里加用例先 `grep -n '^final class'`。
7. 与别的未合并分支的关系：本分支只改 App/ 与 Samples/README.md；`w4-release`（W4-B）、`w4-docs`、`w4-soak` 都不碰这些文件（`git merge-tree` 没试，W4-B 有 20 个文件越界待认领，合并时留意 `AppController.swift` 是否同时被它改）。
