# W5-L 其他：防睡眠 / App Nap、App 起只读 tally 流、远程控制页、界面内提醒、统计窗、界面锁（prompt 98，分支 w5-app-misc）

分支：worktree 分支 `claude/w5-app-misc-sleep-tally-251547`，本地别名 `w5-app-misc` 指同一提交（`make lint BRANCH=w5-app-misc` 用它）。
**基线是 93 的分支头 `w5-app-toolbar` = 8a13a21（= 92 + 93），不是 main**：prompt 写"从 G6 合入后的 main 开"，但 92 / 93 还没进 main，98 要往 92 的底栏右组加"统计"和锁、
要动 93 改过的监视器标题条；94 / 96 两个并行会话也都叠在 8a13a21 上，G7 按 92 → 93 → … → 98 合，冲突最少。所以本分支相对 main 会多出 92 / 93 的提交与两份报告。
只动 App/ + project.yml（只加 App 对 SwitcherTally 产品的依赖）+ 本报告 + 一张问题单。

机器：MacBook Pro M5 Max（128 GB），macOS 27.0（26A428），Xcode 27.0（27A266a），接电源（95%，不充电）；内建屏 + LG ULTRAGEAR 2560×1440。
本机应用防火墙开着（`socketfilterfw --getglobalstate` = 1），显示器 / 系统睡眠设置都是"永不"（`pmset -g`：displaysleep 0、sleep 0）。
第五波多会话同机：跑用例时 94 / 96 等会话也在编译、跑 App 用例（各节写了当时的负载背景）。

提交（`git log 8a13a21..HEAD`）：`6858002` 红灯轮（八条用例 + 新 API 只给签名）→ `8b40244` 实现 → `b9e16d4` 即时生效只写自己的键、菜单栏"窗口"加两项、R7 还原 token
→ `f9f1dd6` 目视核对后的两处（锁按钮"已锁定"、地址行不截断）→ `d43979c` 测试宿主启动时不读存下来的 API token → 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 防睡眠 / App Nap（P1，Q47） | `Engine/EngineActivity.swift`（新）、`AppController.swift`、`Settings/PowerSettings.swift`（新） | 引擎**起好之后** `ProcessInfo.beginActivity([.userInitiated, .latencyCritical, .idleSystemSleepDisabled])`，**停了之后** endActivity（`stopSession` 里 `old.stop()` 之后；换节目的间隙也放一下）。显示器那一条 `.idleDisplaySleepDisabled` 是另一个 activity、另一个开关，默认也阻止。探针（§5 第 1 条）：macOS 27 上前者落成一条 `PreventUserIdleSystemSleep`、后者 `PreventUserIdleDisplaySleep`，名字就是 reason，end 后都放掉；`EngineActivity.processAssertions()` 读 `IOPMCopyAssertionsByProcess`（= `pmset -g assertions` 那份数据），设置页的现状行与用例都读它。设置"性能与电源"：两个开关（即时生效）+ 一行现状 + 只读机型（IODeviceTree 的 product-name + hw.model）/ 芯片 / 内存 / GPU（Metal 设备名 + AGXAccelerator 的 gpu-core-count）/ 系统 |
| 2 只读 tally 流（P2 / X32，Q46） | `Engine/ControlRuntime.swift`、`Engine/SwitcherSession.swift`、`AppSettings.swift`、`Settings/TallySettings.swift`（新）、project.yml | 与 headless `--tally-port` 同一套接法：`TallyPublisher(stateMachine:clock:)` 挂状态机的快照观察者 + `TallyServer`（WS /tally、GET /tally）。起在 API / 兼容层 / MIDI 之后；**停机顺序 tally → API → 引擎**（`SwitcherSession.teardownLocked` 先 `control.stopTally()` 再 `stopAPI()`，`stopSequence` 记下来给用例核对）。运行中开 / 关 / 换端口走 `ControlRuntime.setTally`（串行对齐"想要的配置 × 现在能不能起"，开关连点不会留下孤儿服务），不用重起引擎。设置 › Tally：开关（默认关）、端口（没单独设 = API 端口 + 1，即 8766）、只读地址 WS / HTTP 两行带"复制"（按真在听的地址写：0.0.0.0 → 本机局域网地址，主网卡排第一）、连接数（WS 订阅数，每秒刷）。打开即听 0.0.0.0（Q46）。启动参数 `--tally-port <N>` 与 headless 同名 |
| 3 远程控制页（P3 / X33） | `Settings/RemoteControlSettings.swift`（新）、`Settings/PreferencesPanel.swift`、`AppSettings.swift` | 本地 API 与兼容层各"仅本机 / 允许局域网"分段选择（代替自由填 host；局域网 = 0.0.0.0，原来就写了具体本机地址的原样留着）；下面只读显示 `http://<本机局域网 IP>:<端口>`（兼容层另有 `…/api` 与 TCP 地址）带"复制"，多块网卡时列出其余地址，找不到局域网地址时写明；API 允许局域网又没设 token、兼容层允许局域网（它没有鉴权）时黄字提醒。兼容层的监听地址与 HTTP 端口进设置（键 `compatLayerHost` / `compatLayerHTTPPort`，原来写死 127.0.0.1 / 8088）。改动照旧走"应用 / 应用并重起引擎"。本机局域网地址：getifaddrs 里开着、在跑、不是回环 / 点对点隧道（VPN 的 utun）、不是 169.254 的 IPv4，SCDynamicStore 的 PrimaryInterface 排第一 |
| 4 界面内提醒（N02，Q50） | `UI/Reminders.swift`（新）、`UI/StatusBarView.swift`、`UI/MonitorView.swift`、`UI/MainWindowController.swift`、`Settings/ReminderSettingsPage.swift`（新） | 主窗口最底一行（状态行）右侧的琥珀色提醒条，有提醒才出现，几条用"·"连起来：没在录 / 推满 n 分钟（默认关，n 默认 5，从引擎起或最后一路停下那一刻算）、FTB 开着满 10 秒、Master 峰值持续 30 秒低于 −50 dBFS（只在"有一路带声音的输入（Stats 表读数里有它）、送 Master、没静音"时判，纯画面节目 / 都静音了不报）。PGM 标题条 FTB 时"PGM · FTB"垫黑底慢闪（图层透明度动画，渲染服务器做）。计时是纯逻辑 `ReminderTracker`（单调时钟），主窗口每个快照 / 每行 Stats / 每秒喂一次，字变了才动状态行。设置 › 提醒每条一个开关，即时生效。不叠进多画面、不改契约 |
| 5 统计窗（E5 / N15，Q42 / Q44） | `UI/StatsWindow.swift`（新）、`UI/PanelCoordinator.swift`、`UI/BottomBarView.swift` | 底栏右组"统计"开只读窗（菜单"窗口 › 统计"同一个）。五节：输入（fps / 重复帧 / 丢帧 / 延迟 / 最大延迟）、渲染（render_ms / missed_render / jitter / GPU / CPU / 内存）、输出（按 `EncoderEntry.output` 对上名字 / 类型 / 来源；状态与底栏 ▴ 同一套文案；帧数 / 编码跳帧 / 丢帧 / 码率 / 重连）、显示（Stats.display[]）、音频（超时 / 欠载 / 不连续 / Master 峰值 / 短期响度）。全读 session 那一行 1 Hz Stats（铁律 4）。"重置"只在窗里记基线、显示累计 − 基线（速率量原样）；换了 session（拍号或 missed_render 变小）基线作废；同一 session 里某一项从头来（删了又加同号输入）那一项按 0 当基线 |
| 6 界面锁（E8 / N04，Q43） | `UI/MainWindowController.swift`（`MainWindow.sendEvent`）、`UI/BottomBarView.swift`、`AppDelegate.swift` | 底栏最右的锁（右组 叠加 ｜ 统计 ｜ 锁）。锁着时 `MainWindow.sendEvent` 拦鼠标按下 / 抬起 / 拖动（左右中键）与滚轮：命中内容区（监视器、转场列、输入条、调音台、底栏）或工具条上的控件就拦，锁按钮本身、红绿灯、标题栏空白（拖窗口）不拦；移动 / 悬停不拦。被拦下一次点击时状态行提示"界面已锁定：点底栏最右的锁解锁；快捷键照常"。键盘（快捷键）、菜单栏、MIDI、API 不经过这里，照常；设置 / 统计 / 输出设置等独立窗口是别的窗口，不受影响。锁着时按钮金色高亮 + 闭合的锁 +"已锁定"（窗口不在前台时系统不画底色，靠字认，§5 第 5 条）。菜单"窗口 › 锁定界面"同一个开关（锁着打勾；菜单栏不受锁影响，从这里也能解锁） |
| 规则 5（W5-G：主窗口里的动作菜单栏里都还在） | `AppDelegate.swift` | "窗口"菜单加"统计"与"锁定界面" |
| 7 全量 / lint | — | 见 §2 |

另外几处顺带的修正（原因见 §5 第 2 条）：
- 设置里即时生效的三节（性能与电源 / Tally / 提醒）走 `AppController.updateSettings(_:saving:)`，只写这一节自己的键（`AppSettings.savePower / saveTally / saveReminders`）。整份写回（原来"应用"按钮的路子）会把启动参数带进来的值（`--api-token`、`--no-api`……）顺手存成本机设置。"应用"按钮的老路没动。
- `ReleaseTests.testR7_…`：用 defer 还原它改的内存设置（API token）。
- 测试宿主启动时不读 defaults 里存下来的 API token（`AppDelegate`，只在测试宿主里）：各 worktree 共用的测试 suite 会被别的分支的用例写进 token。
- 92 的老断言"叠加贴右边（右组）"按 98 规定的新右组（叠加 ｜ 统计 ｜ 锁）改成"右组从左到右、整组贴右边"，"按钮都在状态行上面"那条检查把两个新按钮加进去（只加强，没删断言）。

## 2. 测试 ID：数值 / 阈值 / 通过否

用例都在 `App/Tests/W5LMiscTests.swift`（工具在 `W5LTestSupport.swift`）。红灯轮（6858002）这八条全红、原因都是功能没做；实现之后全绿。

| 测试 | 量什么 | 结果 | 通过 |
|---|---|---|---|
| `testApp_engineRunningHoldsActivityAssertion` | 引擎起 → 本进程挂着 `PreventUserIdleSystemSleep "PlusMix engine running: no idle sleep, no App Nap"` 与 `PreventUserIdleDisplaySleep "…no display sleep"`；"性能与电源"两个开关各自即时放 / 拿、存本机设置；拨开关不把内存里的启动参数值写进 defaults；停引擎 → 两条都放掉；再起 → 又拿上 | 都成立（0.8 s） | ✅ |
| `testTally_appServesReadOnlyStream` | 默认关、默认端口 8766 = API + 1、打开听 0.0.0.0；打开 → WS 先收 `hello` 再收当前 `tally` 帧（PGM 1 / PVW 2），连接数 1，Cut 后来一帧 program = 2，GET /tally 200；换节目：旧 session `stopSequence == [.tally, .api, .engine]`、旧端口不再听、新 session 照开关再起、页上地址跟着换；关掉 → 停、端口不监听、连接数 0 | 都成立（2.3 s） | ✅ |
| `testPanels_remoteControlPageShowsReachableAddress` | 仅本机：页上地址 = `http://127.0.0.1:<真绑的端口>`，照着 GET /api/v1/state 得 200；允许局域网：host 0.0.0.0、地址的 IP ∈ 本机局域网地址（与 App 分开算的 getifaddrs）、其余地址也列出、没 token 黄字、设了 token 不报；兼容层同样二选一、HTTP 端口 18088、TCP 地址、黄字；应用后 defaults 与 `AppSettings.load` 读回的配置用上地址与端口；测试宿主跑着的设置仍只听本机；复制（私有剪贴板） | 都成立（0.3 s；本机局域网地址 172.30.1.13 en8 主网卡、172.30.1.90 en0） | ✅ |
| `testUI_reminderShowsWhenFTBOnForTenSeconds` | FTB 开 → PGM 标题条色块立刻亮；5 s 时不提醒；满 10 s 提醒条出现、写着 FTB、在主窗口里；设置里关掉这一条立刻消失、存本机设置，开回来又出现；FTB 关 → 提醒消失、色块灭 | 都成立（11.3 s） | ✅ |
| `testUI_statsWindowResetKeepsStatsCumulative` | 30 fps 合成源进 60p：底栏"统计"开窗、输入行名字 / fps≈30 / dup 在涨；推流那一路按 output 对上名字"推流 · 测试" / 类型推流 / 来源 PGM；有显示（monitor）与音频节；重置后窗里 dup = 0，之后 = 当前累计 − 基线，session 的 Stats 累计值照涨、API GET /state 的 dup 没被清零；再点 = 同一个窗；菜单"窗口 › 统计"同一个窗 | 都成立（3.6 s） | ✅ |
| `testUI_interfaceLockBlocksClicksNotHotkeys` | 锁在底栏最右；点锁 → 锁上、高亮、"已锁定"、辅助功能名"解锁界面"；Cut 按钮的合成点击被 `MainWindow.sendEvent` 拦下（按下 / 抬起两个，PGM 没变），状态行提示带"锁"；输入格子 / T-bar / 调音台 / 两个监视器 / 底栏录制 / 统计 / 叠加 / 工具条"新建"的左右中键按下都拦；锁按钮本身与鼠标移动不拦；空格（快捷键）、菜单栏 Cut、API POST cut 照常（MIDI 一段：虚拟源连上就跑 Note 61 → Cut）；输出设置是独立窗口；再点锁 → 解开、不拦、不高亮；菜单"窗口 › 锁定界面"同一个开关、锁着打勾 | 都成立（0.7 s） | ✅ |
| `testUI_reminderTrackerRules`（纯逻辑） | Master −60 dBFS：29 s 不报、30 s 报，回 −20 立刻消；静音 / 没有带声音的输入不判；关掉这一条不报；FTB 9.9 s / 10 s；没在录 / 推默认关，开了 5 分钟门限从引擎起 / 最后一路停下算，在录不报；引擎停了全不报 | 都成立 | ✅ |
| `testUI_statsBaselineSubtractsOnlyCumulativeFields`（纯逻辑） | 累计量减基线、速率量原样、重置后才有的输入基线按 0、输出名字按编号对、显示 / 音频减基线、换 session 基线作废不出负数 | 都成立 | ✅ |
| `testW5L_idleWakeLatencyProbe`（按环境变量开） | 报告用的空闲复测（§2.2）；平时 XCTSkip | 平时跳过 | —（测量用） |

### 2.1 全量与 lint

- `make test-app`（`b9e16d4`，23:22，机器上没有别的测试进程，负载 2.6）：**170 条，164 过 / 6 跳 / 0 失败**（`xcrun xcresulttool get test-results summary`）。6 条跳过：
  键盘导航（BLOCKED-系统设置，92 的）、内建摄像头（BLOCKED-权限）、虚拟摄像头出帧（BLOCKED-签名）、本会话的空闲复测（按环境变量开）、
  ISO A4 与推流 10 s 两条（BLOCKED-工具：新 worktree 没编 release frameprobe）——`swift build -c release --package-path Tools/frameprobe` 之后单独补跑这两条：
  **A4 13.8 s 过、推流 10 s 17.3 s 过**（当时另有一个会话在跑，负载 5.7）。
- 在这之前的一遍全量（23:15，`8b40244` + 未提交的菜单项，开跑时另一个会话的测试宿主也在跑）红了两条，都是本会话的用例、都是 API 401：根因与修法见 §5 第 2 条，修法就在 `b9e16d4` 里。
- `f9f1dd6`（目视核对后改了地址行与锁按钮）之后补跑受影响的类：InterfaceLock / RemoteControlPage / BottomBarSplit / Localization / Accessibility / CopyCompliance，
  全过（BottomBarSplit 的 `testUI_statusLineIsFullWidthBottomRow` 第一遍偶发红一次，单独重跑两遍都绿，原因见 §5 第 9 条）。最终全量见 §2.3。
- `make lint BRANCH=w5-app-misc`：禁词 / 版本号 / Package.swift / 依赖方向通过；归属一项相对 main 只多出 `reports/w5-app-bottom-bar.md`、`reports/w5-app-toolbar.md`
  （92 / 93 的报告，跟着基线带进来的，不是本会话改的），相对真正的基线 `scripts/check-ownership.sh w5-app-misc --base w5-app-toolbar`："改动文件都在允许范围内"；
  check-links、check-rt-symbols 通过（make 在归属那一项停了，这两项手动补跑）。

### 2.2 activity 断言对"用户空闲时实时线程被拖慢"的复测（10 分钟 gate 对比）

做法：`IdleWakeProbeTests.testW5L_idleWakeLatencyProbe`（平时跳过）在测试宿主里打开 `scenarios/g4-show.json`（gate4 同一个节目：8 路噪声合成源、5–8 号抠像、叠加、
9 号 Stinger 图、多画面自定义布局），每 5 s 切一次，跑 10 分钟，量合成源生产者线程的唤醒延迟（`SyntheticVideoInput.Counters`，就是 G4 记"唤醒 max 9–18 ms"的那个量）、
迟到帧、Stats 的 missed_render / jitter_ms / 每路 drop；同时每秒记 HIDIdleTime（用户多久没碰键鼠）与会话锁屏状态。模式 `none` = 两条断言都不拿，`activity` = 默认（两条都拿）。
命令：`TEST_RUNNER_SWITCHER_IDLE_PROBE_MINUTES=10 TEST_RUNNER_SWITCHER_IDLE_PROBE_MODE=none xcodebuild … test-without-building -only-testing:SwitcherTests/IdleWakeProbeTests`，
结果 JSON 在 `.build/app-test-output/idle-probe-<模式>-<时间>.json`（不入库）。不用 caffeinate。

| 运行（2026-10-03 / 04） | 电源断言 | 用户空闲 HIDIdleTime 最小 / 最大 | 锁屏 | 生产者唤醒 max（8 路里最大） | 迟到帧 | missed_render | jitter_ms max / p99 | 设计外丢帧 | 负载（起 → 止） |
|---|---|---|---|---|---|---|---|---|---|
| none-1 23:44–23:55 | 无 | 0.02 s / 501 s（第 2 分钟起离开） | 否 | 0.164 ms | 0 | 0 | 0.124 / 0.035 ms | 0（5 号丢 3 = +100 ppm 漂移设计内） | 2.6 → 2.0 |
| activity 23:55–00:05 | 两条（`pmset` 看得到） | 0.02 s / 660 s（中途动过一次） | 否 | 0.178 ms | 0 | 0 | 0.085 / 0.038 ms | 0（同上） | 2.0 → 4.8 |
| none-2 00:05–00:15 | 无 | 0.12 s / 541 s（几乎全程空闲） | 否 | 0.143 ms | 0 | 0 | 0.112 / 0.057 ms | 0（同上） | 4.8 → 4.6 |
| 对照：G4 g4c / g4d（headless，reports/G4.md §11.3） | 无 | 用户不在 | 合盖、只剩外接屏、会话锁着、显示器在睡 | 9–18 ms | 每路 3–5 | g4d 1 | — | 8–25 帧 | — |
| 对照：G4 g4e | caffeinate -u -i -d -s | 同上 | 同上 | 0.05–0.11 ms | 0 | 0 | — | 0 | — |

（"生产者唤醒 max"是那一路从起来以来的最大值，含开头 3 s 的起步；迟到 / missed / 丢帧是 10 分钟里的增量。App 里多了主界面、缩略图、调音台的绘制，所以底数比 headless 的 g4e 略高。）

**结论（照实说）**：这三轮都干净，有没有断言没有差别——**这台机器在"用户空闲（最长 11 分钟）但显示器亮着、会话没锁、没合盖"的条件下根本不出现 G4 那种 10–18 ms 的拖慢**，
所以本次复测**没能复现** g4c / g4d 的条件，也就证明不了 App 的断言能不能替代 caffeinate。能确定的：
- 拖慢不是"HID 空闲"本身触发的（none-2 用户空闲 9 分钟照样 0.14 ms），G4 那次的条件是合盖 + 显示器睡 + 会话锁；
- App 的 `PreventUserIdleDisplaySleep` 在显示器休眠不是"永不"的机器上会挡住"用户空闲 → 显示器睡"这一条（本机 `pmset` 的 displaysleep 是 0，验证不了；改它要 sudo / 系统设置，不归本会话）；
- 合盖、手动锁屏 App 挡不住，ProcessInfo 也给不了 caffeinate `-u` 那条 UserIsActive——**无人值守、要合盖或锁屏的长跑仍建议 `caffeinate -u -i -d -s`**（写进了给 103 的问题单）。
  要真正复测 g4c / g4d 那种条件得有人配合合盖 / 锁屏或改显示器休眠时间，留给用户决定要不要做（命令同上，模式 none / activity 各跑一次）。

### 2.3 最终全量

最终代码（`d43979c`，本报告前一个提交）上 `make test-app`（00:24–00:30，没有别的测试进程，负载 3.3–3.8，用户不在、焦点窗口在上方的 LG 屏）：
**170 条，164 过 / 4 跳 / 2 红**。4 条跳过都是环境阻塞：键盘导航（BLOCKED-系统设置）、内建摄像头（BLOCKED-权限）、虚拟摄像头出帧（BLOCKED-签名）、本会话的空闲复测（按环境变量开）；
frameprobe 编好之后 ISO A4 与推流 10 s 都在全量里真跑、都过。两条红都判环境，不是本会话的改动：

| 用例 | 现象 | 判断 |
|---|---|---|
| `MainWindowLayoutTests.testUI_mainWindowRestoresSavedFrameInsteadOfCentering` | 还原到 (−352, 1320) 而不是 (20, 110)：00:16 与 00:24 两遍全量、中间单独跑一次，三次都红 | 用例按 `NSScreen.screens[0]`（内建屏）算存档位置，AppKit 还原时看的是系统焦点所在的屏；20 行探针：此刻 `NSScreen.main` = LG 屏 (−398, 1117, 2560×1440)，`screens[0]` = 内建屏。92 报告 §5 记过同一个偶发（"跟系统焦点窗口在哪块屏"）；本会话没碰窗口摆放，23:22 那遍全量它是绿的 |
| `RecordingTests.testRecord_5sTwoTracksDurationExact` | 起止拍差 = 按钮间隔 +1.017 帧（阈值 ±1；00:16 那遍 +1.157） | 单独连跑 5 次都过：−0.32 / +0.80 / −0.14 / +0.86 / +0.44 帧。92 报告记过它对主线程负载敏感；本会话没加按帧的主线程工作（提醒字变了才动状态行，锁没锁时第一句就返回），全量时机器上有别的会话在编译（负载 3.7–4.0） |

00:16 那遍全量另红过两条连 API 的用例（ControlWiring / LiveSafety，401）：共用的测试 defaults 里又被别的分支写回了 R7 的 token，修法见 §5 第 2 条，修完单独补跑都过。

## 3. 没做的和原因

- **文档**：`docs/integrations/tally.md`、`docs/user/快捷键.md` / en、`docs/api/vmix-compat.md`、`docs/integrations/companion.md`、`docs/user/故障排查.md` / en 里"App 不起 tally 流""App 里改不了监听地址""App 自己不防睡眠，归 prompt 98"这几句 98 落地后不再成立；docs/ 不在本会话目录，写了问题单
  `reports/issues/W5L-w4-docs-2-tally-remote-sleep-manual.md` 给 103（W4-C2）。新加的本机设置键也列在里面。
- **手机网页 tally**（后续方案 §5.3）、**多画面上的提醒**（要渲染器支持）、**契约**：prompt 写明不做。
- **设置窗合窗**归 96：本会话的四节各写成独立的 SwiftUI 视图（`RemoteControlSection`、`TallySettingsSection`、`PowerSettingsSection`、`ReminderSettingsSection`），
  现在挂在老的长表单里；96 合窗时整节挂进"远程控制 / Tally / 性能与电源 /（常规里的）提醒"几页即可。远程控制一节改的是 PreferencesModel 里原有的 API / 兼容层字段（走"应用"），另三节各有自己的模型、即时生效。
- **≡ 工具菜单（E4）、快捷按钮（E6）、截图（E7）**：不在 98（底栏右组按 01 §3.5 预留的顺序是 叠加 ｜ ≡ ｜ 统计 ｜ 快捷按钮 ｜ 截图 ｜ 锁，本会话只放了统计和锁）。
- **锁的快捷键**：没给默认键（Q29 默认键位表归 96；给锁一个全局键容易误按）。
- **监听局域网时 macOS 防火墙的"允许传入连接"框**：正式 App 第一次打开 tally 或"允许局域网"会弹一次（每个签名身份一次），是系统行为；测试宿主一律只听本机，所以这一步没有自动化用例。

## 4. 对契约的疑问

没有改契约、没有提案。两点记录：
- 统计窗"按 `EncoderEntry.output` 对上名字"对编号 0 的项（不在输出表里的，例如 ISO 音轨）只能按"第几个编号 0"跟基线对，名字写"不在输出表里"；019 之后填数方都给了编号，目前 App 里实际看到的都有编号。
- `TallyServerConfiguration` 的相等比较包含心跳间隔与日志级别：App 只改 host / port，没有影响；以后若在设置里开放心跳，换值也会触发重起服务（这是想要的）。

## 5. 下一个会话需要知道的坑

1. **beginActivity 在 macOS 27 上落成什么（探针，scratchpad 里 20 行）**：`[.userInitiated, .latencyCritical, .idleSystemSleepDisabled]` → 本进程一条
   `PreventUserIdleSystemSleep`（名字 = reason）；另起一个 `[.idleDisplaySleepDisabled]` → `PreventUserIdleDisplaySleep`；两个选项并进一个 activity 也是这两条同名断言；
   endActivity 立刻放掉。对照 `caffeinate -u -i -d -s` 是四条：PreventUserIdleSystemSleep / PreventUserIdleDisplaySleep / PreventSystemSleep / **UserIsActive**——
   后两条 ProcessInfo 给不了（`-s` 只在接电时管合盖睡眠，`-u` 是"声明用户在用"，会把关着的显示器点亮）。App Nap 没有公开 API 可查，用例只能核对 activity 拿着、电源断言在。
2. **测试宿主的设置会串**（这次红过两条）：`ReleaseTests` R7 在内存里给 API 设 token 不还原，排在它后面（类名字母序在 R 之后）的用例起的引擎都要 token，不带就 401——已用 defer 还原。
   更要紧的是 `AppController.updateSettings(_:)` 整份写回 defaults：本会话最初几条用例的收尾走它，把 R7 留在内存里的 token 写进了**各 worktree 共用**的
   `com.plusmix.switcher.tests`（2026-10-03 23:17 已 `defaults delete … apiToken` 删掉）；即时生效的三节已改成只写自己的键。可不到一小时它又被别的分支
   （还带着 R7 不还原 + 整份写回的老毛病）写了回来（10-04 00:22 又删了一次），所以测试宿主启动时干脆不读存下来的 token（`d43979c`）；G7 合了本分支的 R7 修法之后源头就没了。那个 suite 里还有别人留下的
   `compatLayerEnabled = 1` / `compatLayerPort = 8098`（PanelTests 的"兼容层开关"用例开了不关）：所有测试宿主的会话都会起兼容层，两个 worktree 同时跑 App 用例会抢 8098 / 8088（只在日志里报"起不来"，不红用例）。
3. **合成鼠标事件**：`window.sendEvent(mouseDown)` + `sendEvent(mouseUp)` 对 NSButton 是真的会点下去的（红灯轮里没锁时 Cut 真被点了）；UISmokeTests 注释里"合成事件不派发到视图"说的是自定义视图 / 窗口不在前台时的情形。
   锁的用例因此能端到端看"点击没生效"，另用 `MainWindow.blocksForLock` 逐个视图核对命中判定。
4. **测试宿主一律只听本机**：本机应用防火墙开着，进程第一次听 0.0.0.0 会弹"允许传入连接"框，无人值守的用例会卡住。`applyTestHostOverrides` 把 API / 兼容层 / tally 的地址都改回 127.0.0.1、tally 端口给 0；
   设置里存的照存，远程控制页与 Tally 页的用例核对的是存下来的值与页上的地址。正式 App 第一次打开"允许局域网"或 tally 会弹一次这个框。
5. **窗口不在前台时系统不画按钮的 bezelColor**：测试宿主永远不在前台，截图里底栏的高亮都看不出（93 记过工具条同样的现象）。锁按钮因此锁着时另写"已锁定"；以后在主窗口加"开着 / 锁着"类状态，别只靠底色。
6. **grouped Form 里的 LabeledContent 对半分**，右边的长内容会被截成"…"（地址里的端口看不到）；地址行改成 HStack（标签 + Spacer + `fixedSize()` 的地址 + 复制）。
7. **给测试宿主传环境变量**：`TEST_RUNNER_<名字>=值 xcodebuild test …`，宿主里读到的是去掉前缀的 `<名字>`（空闲复测就靠它，§2.2 的命令）。
8. **新 worktree**：先 `swift build -c release --package-path Tools/frameprobe`，不然 ISO A4 与推流 10 s 两条 BLOCKED-工具跳过；新加的测试文件要 `make gen` 才进工程（临时截图用例撞过）。
9. **偶发**：`BottomBarSplitTests.testUI_statusLineIsFullWidthBottomRow` 等状态行提示 4 s 过期时，前一条用例（外部显示开 / 关）留下的外部显示窗口状态变化会再来一条"外部显示 2：显示中（显示器 4）"把提示续上，
   等不到回到本机信息；只在接着第二块屏、而且另有会话在跑时撞到一次，单独重跑两遍都绿。不是本会话的改动，没动这条用例。
10. **两条判环境的红**（§2.3）：`MainWindowLayoutTests` 的存档位置跟系统焦点在哪块屏走（用户把焦点留在外接屏时必红）；`RecordingTests` 的 ±1 帧在机器忙时会刚好过线。全量红了先单独复跑再判。
11. **G7 合并注意**：两份 Localizable.strings 的新键是一整块（`/* W5-L（98）… */`，放在 W4-B 那段之前），按键合即可；PreferencesView 里原来的"本地 API"与"兼容层"两节换成了 `RemoteControlSection`，
    96 合窗后要把四节挂到对应页；`AppDelegate` 的"窗口"菜单加了两项；底栏右组改成 NSStackView（叠加 ｜ 统计 ｜ 锁）；`MainWindow` 加了 `sendEvent` 覆写；
    `AppController.settings` 的 didSet 现在会顺手落实"别睡"、提醒设置与 tally（任何给 `controller.settings` 赋值的地方——包括用例——都会触发）。
