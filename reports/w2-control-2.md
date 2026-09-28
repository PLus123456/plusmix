# W2-C2 MIDI 热插拔在换过节目之后失效 + 控制包里的产品名跟改 —— 报告（分支 w2-control-2）

日期 2026-09-28。机器 Apple M5 Max / macOS 27.0 (26A428) / Xcode 27.0 / Swift 6.4，电源适配器。worktree `.claude/worktrees/w2-control-2`，
从 `main`（97dc5e3，= f8fabbf + 一条会话报告提交）开。提交 `git log main..w2-control-2`（5 条功能 + 本报告）。
动的文件：`Packages/SwitcherControl/Sources/SwitcherControl/MIDI/{MIDIHost.swift（新）, MIDIController.swift, VirtualMIDISource.swift, MIDIMapTable.swift（一行注释）}`、
`Hotkeys/HotkeyTable.swift`（只有 UserConfig 的目录名与两行注释）、`API/APIServer.swift`（只有 serverName）、
`Tests/SwitcherControlTests/{MIDITests, APIServerTests, HotkeyTests}.swift`。没动契约、VMixCompat、Tally、CommandBus、App。
这台机器没有真 MIDI 设备，所有 MIDI 用例走正式代码里的 `VirtualMIDISource`。

## 1. 做了什么

### 1.1 探针：CoreMIDI 的通知到底派到哪条 run loop（铁律 10）

一个 100 行的 swiftc 程序（`-swift-version 5 -framework CoreMIDI`，在 scratchpad 里，没入库；核心逻辑见下），两种模式，虚拟源都在一条没有 run loop 的线程上建 / 销毁（像 XCTest 的 async 测试线程）：

- **seq（复现测试顺序）**：线程 T1 建客户端 A（带通知块）→ 销毁 A、T1 退出 → T2 建 B、跑 run loop → 建虚拟源、销毁 → 销毁 B、T2 退出 → T3 建 C…… → T4 建 D……
  **结果：B / C / D 一条通知都没收到**（added / removed 都没有），哪怕它们各自的线程 run loop 一直在跑。
- **anchor（本会话的方案）**：常驻线程 H 先建一个永不销毁的锚客户端 Z；B / C / D 都在 H 上建 / 销毁；最后再在另一条 run loop 线程 T9 建 E、在没有 run loop 的线程建 F。
  **结果：所有客户端（Z / B / C / D / E / F）的 added / removed 全部收到，回调线程全是 H**——包括 E（建在 T9 上）和 F（建在没有 run loop 的线程上）。

结论：CoreMIDI 把进程里**所有**客户端的通知派到"进程里第一次 `MIDIClientCreate` 时的那条 run loop"上（和文档一致），之后建的客户端不管建在哪都用它；
那条线程退出后通知就丢。修前的红测试第 1 轮（同一实例停了再起）碰巧过、第 2 轮只丢删通知、第 3 轮全丢——是新线程有时复用了旧线程的 run loop 对象，靠不住。

```swift
// 探针核心：LoopThread = 一条跑着 RunLoop 的线程（Port() 保活，sync 用 CFRunLoopPerformBlock + 信号量）
func makeClient(_ name: String) -> MIDIClientRef {
    var c = MIDIClientRef()
    MIDIClientCreateWithBlock(name as CFString, &c) { n in
        guard n.pointee.messageID == .msgObjectAdded || n.pointee.messageID == .msgObjectRemoved else { return }
        let x = n.withMemoryRebound(to: MIDIObjectAddRemoveNotification.self, capacity: 1) { $0.pointee }
        if x.childType == .source { print("通知 → \(name): \(n.pointee.messageID.rawValue) 于 \(Thread.current.name ?? "?")") }
    }
    return c
}
// seq：T1: A → dispose → T1 退出；for n in B C D { Tn: makeClient(n); 别的线程建虚拟源、0.5 s 后销毁；Tn: dispose；Tn 退出 }
// anchor：H: 锚；for n in B C D { H: makeClient(n); 别的线程建虚拟源、销毁；H: dispose }；再 T9: E、无 run loop 线程: F、建 / 销毁虚拟源
```

### 1.2 修法：进程级的 `MIDIHost`（`MIDI/MIDIHost.swift`）

- 一条常驻线程 `switcher.midi`（QoS userInteractive）+ 它的 run loop（`Port()` 保活，跑到进程结束）+ 一个永不销毁的锚客户端 `"PlusMix MIDI anchor"`（不带业务，只把整个进程的通知 run loop 钉在这条线程上）。
  `static let shared` 第一次用时起（`MIDIController.start()` / `VirtualMIDISource.init` 都会先碰它），所以进程里第一个 CoreMIDI 客户端就是锚。
- `sync(_:)`（`CFRunLoopPerformBlock` + `CFRunLoopWakeUp` + 信号量，已在宿主线程上就直接跑、避免等自己）/ `async(_:)`（已在宿主线程上直接跑、保持通知先后顺序）。
- `MIDIController`：不再自带线程。`start()` 在宿主线程上建客户端 + 输入口、枚举现有源；`stop()` 在宿主线程上断开源、销毁**自己的**输入口和客户端（返回时已完成），宿主线程和锚不动。
  通知块只把指针里的内容抄成 `MIDINotice`（sourceAdded / sourceRemoved / setupChanged）再 `MIDIHost.shared.async` 回宿主线程处理——App 若在此之前已在主线程建过锚（`MIDINotificationAnchor`），通知落主线程，跳一次线程后行为一样。
  `client` / `port` 只在宿主线程上读写；停了之后才到的通知（`client == 0`）丢掉。
- 派发不变：CoreMIDI 接收线程解析 → `AsyncStream` → 一条常驻 `Task` 顺序 `submit`，CC 不乱序（既有 `testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn` 的 20 连发顺序断言照过）。
  顺手把 continuation / Task 收进一个 `Mutex` 保护的 `pipeline`（原来是裸 `var`，接收线程读、start / stop 写）。回调里没有日志。
- `VirtualMIDISource`：客户端 / 端点在宿主线程上建 / 销毁（保证锚先于它；`disposed` 改原子量）。
- 三个类型的 `@unchecked Sendable` 理由都写在声明上：`MIDIHost` 的字段只在 init 里写一次、跨线程只通过 sync / async 送 `@Sendable` 闭包；`MIDIController` 的 `client` / `port` 只在宿主线程上碰、其余在 Mutex / Atomic；`VirtualMIDISource` 的 ref 在 init 里写一次。

### 1.3 产品名跟改（issue W4D 第 2 条；0.1.0 没发布过、不做迁移）

| 在哪 | 原来 | 现在 |
|---|---|---|
| `UserConfig.directory`（`Hotkeys/HotkeyTable.swift`） | `~/Library/Application Support/Switcher` | `~/Library/Application Support/PlusMix`（hotkeys.json / midi.json 跟着；App 的 Diagnostics/ 用的是它，自动跟） |
| `MIDIController.init` 默认 `clientName` | `"Switcher"`（输入口 `"Switcher 输入"`） | `"PlusMix"`（输入口 `"PlusMix 输入"`） |
| `APIServer` 的 Hummingbird `serverName`（响应头 `Server:`） | `Switcher` | `PlusMix` |

用例跟改：`testMIDI_mapTableJSONRoundTripAndConflicts` 的默认路径断言；新用例 `testW2C2_productName_userConfigDirAndMIDIClientName`（目录尾段、两张表的默认路径挂在它下面、默认 clientName）；
`testAPI_getState_returnsStateTallyClockAndStats` 加了 `Server: PlusMix` 的断言。改前这三处 5 个断言全红（值都是 "Switcher"）。

### 1.4 顺手

`testHotkey_dispatcherSendsCommandsThroughBus` 整包跑时红过一次（`program` 仍是 3）：它用 `bus.lastSequence == 5` 当"已生效"，但总线在分配 sequence 时就把计数加一了、状态机可能还没应用。
改成等 `recentEntries().count == 5`（回执之后才追加）。与 MIDI 无关，是原有用例的时序问题；连跑 6 次稳定。单独一个提交。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

`swift test --package-path Packages/SwitcherControl`（debug）：**SwitcherControlTests 30 / TallyTests 3 / VMixCompatTests 25（1 跳过 = 原有的 C5 人工项 `testC5_manualCompanionSession_servesWhenRequested`）= 58 个用例 0 失败**，12.3 s。
`make lint BRANCH=w2-control-2`：禁词 / 版本号 0.1.0 / Package.swift 约束 / 依赖方向（8 个包）/ 归属（9 个改动文件都在允许范围内）/ check-rt-symbols 全绿。

| 测试 ID | 口径 | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|---|
| `testW2C2_midiHotplug_survivesControllerRestart` | 三轮：第 1 轮同一实例起 → 停 → 再起，第 2 / 3 轮换全新控制器；每轮建虚拟源要连上、CC1=64 → tbar 64/127、CC1=127 提交对调、Note 60 → cut、learn 捕获 CC9@ch3 不派发、销毁后从列表移除 | 15 处断言失败：第 1 轮碰巧过，第 2 轮删通知丢（源留在列表里），第 3 轮增删都收不到、CC / Note / learn 全无；31.9 s（都在等 5 s 超时） | 三轮全过，**1.79 s**（整包里）；单跑连续 5 次 1.8 / 1.8 / 2.4 / 3.4 / 3.4 s 全过 | 增删通知各 ≤ 5 s；命令 / learn ≤ 5 s | ✅ |
| `testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn`（既有） | 起控制器后建虚拟源热插拔连上、CC → tbar 换向、推子、Note、20 连发顺序、learn、ignored、销毁移除 | ✅ 1.30 s | ✅ 1.33 s | — | ✅ |
| `testMIDI_mapTableJSONRoundTripAndConflicts` / `_ccToTbar_flipsDirectionAtEachEnd` / `_ccToGains_andNoteToActions` / `_cc14_fineTbarAndGain` / `_umpParsing`（既有） | 纯函数 | ✅ | ✅（第一个的默认路径断言改成 `Application Support/PlusMix/midi.json`） | — | ✅ |
| `testW2C2_productName_userConfigDirAndMIDIClientName`（新） | `UserConfig.directory` 尾段 = PlusMix、以 `Library/Application Support/PlusMix` 结尾；`HotkeyTable.defaultFileURL` / `MIDIMapTable.defaultFileURL` = 目录下的 hotkeys.json / midi.json；默认 `clientName` = PlusMix | 3 处断言 "Switcher" | ✅ | — | ✅ |
| `testAPI_getState_returnsStateTallyClockAndStats`（既有 + 1 断言） | 响应头 `Server` = PlusMix | `Server: Switcher` | ✅ | — | ✅ |
| `testHotkey_dispatcherSendsCommandsThroughBus`（既有，改等待条件） | 异步入口等回执进日志 | 整包跑红过 1 次（时序） | 单跑 6 次 + 整包全过 | — | ✅ |
| 其余 Control / Tally / VMixCompat 既有用例 | — | — | 全过 | — | ✅ |
| App `ControlEditorTests`（只读 App/，验证 App 侧的锚 + 本修法共存） | `testMIDI_hotplugAfterShowReplaced_newSourceConnects` 等 3 条 | — | 3 / 3 过（1.21 s）；细节见 §5 末尾 | ≤ 5 s | ✅ |

## 3. 没做的和原因

1. **App 侧的旧目录 / 锚客户端**：不在本会话范围（只读 App/），归 W3-E5，调用点列在 §5 第 2 条。
2. **`Tally/TallyServer.swift` 第 71 行、`VMixCompat/CompatHTTPServer.swift` 第 37 行的 `serverName: "Switcher"`，`VMixCompat/VMixCompatConfiguration.swift` 第 28 行 `edition = "Switcher"`**：
   同样是用户看得到的名字，但 OWNERSHIP 的 w2-control-2 行只准动 `API/APIServer.swift` 的 serverName；Tally / VMixCompat 归 W3-D（issue W4D 第 3 条）。
3. **文档里的旧路径**（issue W4D 第 2 条列的）：`docs/user/概念.md:90`、`快捷键.md:25 / 57`、`en/concepts.md:98`、`en/shortcuts.md:28 / 60`、`docs/release/diagnostics.md:7` 仍写 `Application Support/Switcher`，归 W4-C / W4-D 跟；`docs/plan/prompts/43` 与 `docs/checklists/G3.md` 是历史记录不改。
4. **真设备**：这台机器没有任何 MIDI 硬件，USB 设备的插拔走的是同一条 `msgObjectAdded / Removed` 通知路径（探针里虚拟源和真设备对 CoreMIDI 一样），但没在真设备上验过。
5. **映射表格式、契约**：prompt 明说不做。

## 4. 对契约的疑问

没有。`SwitcherContracts` 没动；`MIDIController` / `VirtualMIDISource` 的公开 API 没变（`MIDIHost` 是包内部类型）。
两个改名的默认值（`clientName`、`UserConfig.directory`）是行为变化不是签名变化，App 编译不受影响。

## 5. 下一个会话需要知道的坑

1. **App 的 `MIDINotificationAnchor` 现在可以删，也可以留**：留着 = 进程第一个客户端在主线程、通知落主 run loop，控制器把它跳回宿主线程处理，行为一样；
   删了 = 包里的 `MIDIHost` 锚接管。删的时候一起改：`App/Sources/Engine/MIDINotificationAnchor.swift`（整个文件）、`App/Sources/AppController.swift:43`（`MIDINotificationAnchor.install()`）、
   `App/Tests/ControlEditorTests.swift:83`（`XCTAssertTrue(MIDINotificationAnchor.isInstalled …)`，那条用例 `testMIDI_hotplugAfterShowReplaced_newSourceConnects` 本身留着当守门）。
   本会话跑了 App 的 `ControlEditorTests`（`make gen` + `xcodebuild test -only-testing:SwitcherTests/ControlEditorTests`，App/ 没改），结果见本节末尾的"App 验证"。
2. **App 侧写死旧目录的调用点（W3-E5 跟）**：
   - `App/Sources/Show/ShowDocuments.swift:94–98` `autosaveURL`：自己拼了 `Application Support/Switcher/LastSession.switcher.json`（注释里写明是等包改了一起换）→ 改成 `UserConfig.directory.appending(path: "LastSession.\(fileExtension)")` 最省事，不然 LastSession 和 hotkeys.json / midi.json / Diagnostics/ 会分在两个目录。
   - 只是注释：`App/Sources/AppController.swift:22`、`App/Sources/Settings/HotkeyEditorPanel.swift:2`、`App/Sources/Engine/ControlRuntime.swift:2`、`App/Sources/Release/CrashDiagnostics.swift:2`（代码用 `UserConfig.directory`，自动跟）。
   - `App/Sources/Release/CrashDiagnostics.swift:16` `defaultDirectory = UserConfig.directory.appending(path: "Diagnostics")`：自动变成 `~/Library/Application Support/PlusMix/Diagnostics`，"帮助 → 打开诊断文件夹"跟着变；docs/release/diagnostics.md 要改（§3 第 3 条）。
   - 测试宿主的配置目录是临时目录（`AppController.init` 的 `switcher-tests/config`），不受影响。
3. **`MIDIHost.sync` 会阻塞调用线程**（通常 < 1 ms）：`MIDIController.start()` / `stop()`、`VirtualMIDISource.init` / `dispose()` 都走它。App 在主线程调没问题（宿主线程不会反过来等主线程）；
   别在宿主线程的回调里再去等主线程。在宿主线程上调 `sync` 会直接执行（不会等自己），所以 `deinit { stop() }` 在任何线程上都安全。
4. **`MIDIClientDispose` 别在通知回调里做**：现在通知块只抄内容、跳回宿主线程再处理，`stop()` 的销毁也在宿主线程上排队执行，天然不会在回调里销毁。改这段时保持这个结构。
5. **宿主线程不退出**：进程级单例，`swift test` / App 进程结束时随进程消失；没有 `stop`。要"彻底不用 MIDI"只需要所有控制器 `stop()`，宿主空转（run loop 睡着，不占 CPU）。
6. **锚客户端名 `"PlusMix MIDI anchor"` 用户看不到**：CoreMIDI 客户端不出现在 Audio MIDI 设置里，只有端点（输入口 / 虚拟源）会；输入口名现在是 `"PlusMix 输入"`。
7. **测试里等命令生效要等回执，不要等 `bus.lastSequence`**（§1.4）：`lastSequence` 在分配 sequence 时就变，状态机可能还没应用；`recentEntries()` 是回执之后才追加的。MIDI 用例里的 `lastSequence >= n` 后面紧跟的 `await stateMachine.state` 有同样的理论窗口，但 MIDI 派发 Task 是顺序 submit、`submit` 返回前状态已应用，几十次跑没撞过；要改也是同一招。
8. **`Port()` 保活 run loop** 沿用了原来的写法（`RunLoop.current.add(Port(), forMode: .default)`），没有它 `RunLoop.run(mode:before:)` 会因为没有输入源立即返回、线程空转。CoreMIDI 自己会往这条 run loop 加通知源，但那是在第一个客户端建好之后。
9. **`swift test --filter` 写 `Module.Class/method`**（memory 里的坑，仍成立）；整包 12 s，MIDI 两条端点用例各 1.3 / 1.8 s，其余毫秒级。

### App 验证（App/ 未改，只跑）

`make gen` + `xcodebuild test -only-testing:SwitcherTests/ControlEditorTests`（App 的锚 `MIDINotificationAnchor` 仍在，与包里的 `MIDIHost` 共存）：
`testMIDI_hotplugAfterShowReplaced_newSourceConnects`（换两次节目后建虚拟源 5 s 内连上、销毁后消失）✅ 1.21 s、`testMIDIMapping_learnFromVirtualSourceAndSave` ✅ 0.23 s、
`testHotkeyEditor_addBindingConflictSaveApplyAndRecord` ✅ 0.55 s——3 / 3 过，`** TEST SUCCEEDED **`。App 整包（86 用例）没跑，App/ 没改、公开 API 没变。
