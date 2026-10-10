# W2-C3 `MIDIHost.sync` 偶发崩溃修复（"non-escaping closure has escaped"）—— 报告（分支 w2-control-3）

日期 2026-10-10。prompt 106（0.1.x 唯一的 S1 崩溃；G7 之后开单）。机器 Apple M5 Max（18 核 = 6 + 12）/ macOS 27.0.1（26A434）/ Xcode 27.0（27A266a）/ Swift 6.4，接电源（AC，电池 95%）。
worktree `.claude/worktrees/midihost-sync-crash-7400af`，分支 `claude/midihost-sync-crash-7400af`（桌面端自动起的名），从 `main`（93f50d9，G7 快进后）开；
**`w2-control-3` 这个分支名指向同一个 HEAD**（`git branch -f w2-control-3 HEAD`，同 W5-E 先例），`make lint BRANCH=w2-control-3` 与 G8a 合并用它。
提交：`git log main..w2-control-3`（红测试 → 修复 → 报告与问题单）。动的文件：`Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIHost.swift`、
新文件 `Packages/SwitcherControl/Tests/SwitcherControlTests/MIDIHostTests.swift`；所有分支都允许的 `reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md`（末尾追加处理结果）和本报告。
契约、App、别的包、`docs/KNOWN_ISSUES.md`（G8 销号）一个字没动。

## 1. 做了什么

### 1.1 先量：窗口在哪、什么情况下最容易撞上（探针，没入库）

一个约 140 行的 swiftc 程序（`-swift-version 6`，在 scratchpad 里）：把 `MIDIHost` 的线程 / run loop / `sync` **原样照抄**（常驻 `Thread` + `RunLoop` + `Port()` 保活、QoS userInteractive、
`CFRunLoopPerformBlock` + `CFRunLoopWakeUp` + 信号量），再加一份改后的 `sync`；主线程连续 `sync { i }` N 次，另起线程按不同方式给宿主线程"加活"。
每种配置各起 N 个独立进程；`SIGTRAP` 处理函数直接 `_exit(77)`（不留崩溃报告），按退出码数 trap。

| 配置（主线程 sync 次数） | 宿主线程上的"活" | Debug 旧写法 trap | Release（-O）旧写法 | 改后 |
|---|---|---|---|---|
| plain（2000） | 无 | 0 / 5 | — | — |
| slow（2000） | 另一线程每 1–5 ms 塞一个睡 1–5 ms 的块（prompt 的"慢块"） | 1 / 5 | 1 / 5 | — |
| hot（2000） | 另一线程不停塞空块（不限量） | **5 / 5** | **5 / 5** | Debug 0 / 20、Release 0 / 20 |
| hot2（2000） | 两条线程不停塞空块 | 5 / 5 | — | — |
| loadui / loaddef（2000） | 18 条空转线程，QoS userInteractive / default | 1 / 5、0 / 5 | — | — |
| hotload（2000） | hot + 18 条 default 空转 | 3 / 5 | — | — |
| hotlim（2000 / 200） | 不停塞空块、**最多 4 个排着队** | **10 / 10**、3 / 10 | — | 0 / 3（每次 0.02 s） |
| mix（2000 / 200） | hotlim + 每 5–10 ms 塞一个睡 1–5 ms 的慢块（= 用例的做法） | **10 / 10**、4 / 10 | — | 0 / 3（每次 0.04 s） |
| delay（200） | 只在 `done.signal()` 之后让宿主线程再睡 1 ms（模拟刚放行调用方就被抢占） | **10 / 10**（第一次 sync 就崩） | **10 / 10** | **Debug 0 / 10、Release 0 / 10** |

结论：

1. trap 就是 `withoutActuallyEscaping` 收尾处的逃逸检查。Debug 运行时先打印
   `closure argument was escaped in withoutActuallyEscaping block: file …/MIDIHost.swift, line 73`（修前那一行是 `withoutActuallyEscaping` 的右括号）再 trap；
   **Release（-O）照样 trap**（同一个 delay 配置 -O 10 / 10，`-Ounchecked` 0 / 5——这条检查只有 `-Ounchecked` 才去掉），所以正式 App 一样会崩，S1 定级没问题。
2. 窗口：CFRunLoop 跑块是"调块 → 立刻 `Block_release`"，块捕获的 `escapable` 要到 `Block_release` 时才放掉；块里最后一句是 `done.signal()`。
   调用方被放行后只要抢在宿主线程走到 `Block_release` 之前离开 `withoutActuallyEscaping`，检查就看到闭包还被块牵着。
3. 两条路都会抢到（另一个机制探针在 trap 时记下调用方走的是哪条，hot 下 6 次 trap：3 次"没进内核睡、`wait` 直接返回"、3 次"睡过被叫醒"；slow 下 2 次 trap 都是"睡过被叫醒"）：
   - 宿主线程醒着（正在处理别的块）：`CFRunLoopWakeUp` 对醒着的 run loop 几乎不花时间，块在调用方刚进 / 还没进 `wait` 时就跑完，两边在不同核上同时往前跑，各自只差几百纳秒；
   - 调用方在内核里睡着：正常情况下唤醒要几微秒，宿主线程早释放完了；但宿主线程在 signal 系统调用返回时被抢占 / 被中断耽搁一下，调用方就赢。机器忙时更容易（问题单记的 W5-A / W5-B 那两次崩，负载均值都在 6 左右）。
4. 只加 CPU 负载（loadui / loaddef）几乎撞不上；**"宿主线程醒着"才是最有效的放大器**。只塞慢块（prompt 原样）比不加强一点，但不够当红测试。
5. 用 delay 配置把窗口人为拉到 1 ms：旧写法每次必崩，新写法 0 次——改后与宿主线程什么时候被调度、什么时候释放块无关（见 1.3）。

### 1.2 红测试 `testC_midiHostSync_stressNoTrap`（新文件 `MIDIHostTests.swift`）

- 主线程上（同步用例，XCTest 在主线程跑）：先断言在宿主线程上 `sync` 自己直接跑（`host.sync { host.sync { host.isCurrent } }`，不等自己）。
- 噪声 `MIDIHostNoise`（同文件，测试专用）：一条 userInteractive 线程不停塞空块、最多 4 个排着队（让宿主线程几乎不睡；有界是因为不限量时队列无限长，sync 的块排在后面要等很久——探针里 slow + 不限量 hot 十分钟没跑完）；
  一条线程每 5–10 ms 塞一个睡 1–5 ms 的慢块（prompt 的做法）。`stop()` 等两条线程退出、再 `sync {}` 一次把已塞的块排空，之后宿主线程上没有本用例的东西。
- 主线程连续 `sync` 2000 次，每次返回 `(i * 7, host.isCurrent)`：返回值都对、都在宿主线程上跑（数错的个数，最后断言 0）。
- 再起停 `MIDIController` 200 次（每 10 轮换一个全新的控制器 = 换节目，其余同一个实例停了再起），每轮断言 start 后在跑、stop 后停了；第 0 轮起不来按"CoreMIDI 不可用"跳过（同 MIDITests 的惯例，见 §5 第 3 条），之后的轮起不来记失败。
- 最后断言噪声确实加上了（慢块、空块计数都 > 0）。
- 放新文件而不是 `MIDITests.swift`：100 号会话也要动 MIDI 用例，少撞一处。

**修前**（`swift test --skip-build --filter SwitcherControlTests.MIDIHostTests/testC_midiHostSync_stressNoTrap`，独立进程连跑 10 遍；开跑前 1 分钟负载 2.6、跑完时 9.5）：
**10 遍红 9 遍**，9 遍都是 `exited with unexpected signal code 5`，日志里是上面那句 `closure argument was escaped … MIDIHost.swift, line 73`，栈 `MIDIHost.sync<A>(_:) ← MIDIHostTests.testC_midiHostSync_stressNoTrap() + 744`（2000 次 sync 那一段，还没走到起停）；
1 遍过（0.118 s）。9 份崩溃报告是 `~/Library/Logs/DiagnosticReports/xctest-2026-10-10-2115{18,18.000,19,20,27,28,29,30,31}.ips`（不是 PlusMix 的）。

另用临时用例（量完删了，没入库）分开量各段在 XCTest 里的修前复现率，各 10 个进程：

| 临时用例 | 修前 trap |
|---|---|
| 没有噪声 + sync 2000 次 | 0 / 10 |
| 只塞慢块 + sync 2000 次（prompt 原样） | 2 / 10 |
| 没有噪声 + 起停控制器 200 次 | 0 / 10（另 2 遍 `MIDIClientCreate` -304，见 §5 第 3 条） |
| 只塞慢块 + 起停 200 次 | 0 / 10 |
| 整套噪声 + 起停 200 次（App 真实路径） | 1 / 10 |
| **整套噪声 + sync 2000 次 + 起停 200 次（入库的用例）** | **9 / 10** |

### 1.3 修法：问题单改法 (b)——闭包在放行调用方之前放掉（`MIDI/MIDIHost.swift`）

```swift
func sync<T: Sendable>(_ body: @Sendable () -> T) -> T {
    if isCurrent { return body() }
    return withoutActuallyEscaping(body) { escapable in
        let call = SyncCall(escapable)                       // 闭包只存在 SyncCall 里
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { call.run() }   // 块只捕获 SyncCall
        CFRunLoopWakeUp(runLoop)
        return call.wait()
    }
}
// SyncCall.run()（宿主线程）：result = body?() → body = nil → done.signal()，顺序不能换
```

- 块被 run loop 晚些释放时只放掉对 `SyncCall` 的引用，闭包在 signal 之前已经清掉，调用方什么时候醒、宿主线程什么时候被调度都不影响检查。
- 签名不变（非逃逸、`@Sendable`、`T: Sendable`），四个调用处（`MIDIController.start` / `stop`、`VirtualMIDISource.init` / `dispose`）一字没动；
  返回值（含 `T` 本身是可选的 `MIDIError?`）、在宿主线程上跑、在宿主线程上 `sync` 自己直接跑，这些行为不变；`async` 没动（本来就是逃逸闭包，不过检查）。
- `SyncCall` 是 `MIDIHost` 里的私有类，`@unchecked Sendable` 的理由写在声明上：`body` 调用方 init 写、宿主线程读并清空，`result` 宿主线程写、调用方 `wait` 返回后读，前后由入队（CF 内部加锁）和信号量隔开。
- `Mutex` 不用了，去掉 `import Synchronization`。
- **没选 (a)**（参数改 `@escaping`、去掉 `withoutActuallyEscaping`）：它也能消掉这个 trap，但逃逸闭包仍要等块被释放才放掉捕获的东西，`{ self.tearDownOnHost() }` 里 self 的最后一次 release 会晚于调用方返回、落在宿主线程上；
  `MIDIController.deinit { stop() }` 这条路现在走不到（起着的控制器被派发 Task 强引用），将来谁把那里改成弱引用，就是 "deallocated with non-zero retain count" 或悬空引用。(b) 两样都没有，而且不动调用方。
- 改后 Release 也验过：delay 配置（signal 之后宿主线程再睡 1 ms）-O 编译 0 / 10，说明优化没有把"清掉闭包"挪到 signal 之后。

### 1.4 验证

- 同一条用例**修后同样跑法 30 遍 0 次 trap**（30 / 30 过；负载 2.7–3.5）。耗时 24 遍 0.10–0.18 s、2 遍约 0.67 s、4 遍约 4.7 s——慢的几遍都慢在用例开头第一次碰 `MIDIHost.shared`
  （建锚客户端 = 进程里第一次连 MIDIServer），见 §5 第 4 条。
- SwitcherControl 全包 `swift test` 连跑 3 遍：每遍 **70 个用例 = SwitcherControlTests 42（新增 1）+ TallyTests 3 + VMixCompatTests 25；69 过、1 跳（原有的 C5 人工项）、0 红**；
  MIDI 相关（第 1 遍）：78 的 `testW2C2_midiHotplug_survivesControllerRestart` 1.75 s、`testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn` 0.72 s；本会话的压力用例三遍 0.711 / 0.710 / 0.728 s
  （整包里它按类名排在 MIDITests 前面，进程里第一次建 `MIDIHost` 的冷启动算在它头上，单跑只要 0.12 s）。
- App 全量（`make gen` 后 `make test-app`，Debug；先编了 release frameprobe，ISO / 推流那几条真跑）：见下面 §1.5。
- `make lint BRANCH=w2-control-3`：禁词 / 版本号 0.1.0 / Package.swift 约束 / 依赖方向 8 个包 / 归属（修复提交时 2 个改动文件、加上报告与问题单后 4 个，都在允许范围内）/ check-links 173 个 Markdown / check-rt-symbols 全绿。

### 1.5 App 全量（prompt 交付 4）

| 轮 | 时间 | 用例 / 过 / 跳 / 红（xcresult） | 崩溃 | 红在哪、怎么判 |
|---|---|---|---|---|
| 1 | 21:28:01–21:34:54（`Test-Switcher-2026.10.10_21-28-01-+0800.xcresult`） | **228 / 221 / 4 / 3** | **0**：`~/Library/Logs/DiagnosticReports` 里最新的 PlusMix 报告仍是 G7 那份 `PlusMix-2026-10-04-010946.ips`（跑的时候挂了监视，没有新的） | 3 条红全在 `ToolbarMenuTests`：`testUI_helpMenuOffersManualAndHotkeyList`（帮助菜单打开的 URL 是 nil）、`testUI_inputSettingsMenuTitleNamesInput`（"开的是 PVW 那一路"）、`testUI_recentMenuDisambiguatesSameNamesAndOpensLastSession`（等了 15 s，"打开了上次退出时的节目"等 5 处）。同时段 w4-docs-manual-alignment 会话每隔几秒起一个 PlusMix 截文档图（它的 `winid` 截图工具在同一时段留了 3 份崩溃报告），菜单 / 窗口焦点被抢；`test-without-building -only-testing` 单独复跑这 3 条 **3 / 3 过**（0.45–0.52 s）。与 MIDI 无关，按同机干扰记 |
| 2 | 21:36:13–21:42:17（`Test-Switcher-2026.10.10_21-36-13-+0800.xcresult`） | **228 / 225 / 3 / 0** | **0**（同上，没有新的 PlusMix 报告） | 第 1 轮红的 3 条这轮都过（0.16 / 0.46 / 0.52 s）；w4-docs 会话这时已不在起 PlusMix。内建摄像头那条这轮真跑过了（3 s，权限此时已允许），所以只跳 3 条 |

第 1 轮的 4 条跳过与 G7 相同：键盘导航（BLOCKED-系统设置）、空闲复测（设环境变量才跑）、内建摄像头（BLOCKED-权限）、虚拟摄像头出帧（BLOCKED-签名）；第 2 轮内建摄像头那条没跳。
起停 session 的用例（各用例开头的 `AppTest.freshSession` → `replaceSession` → `ControlRuntime.stopAPI` / `start` → `MIDIController.stop` / `start` → `MIDIHost.sync`）全部跑完、没有一次 trap。
修前这条崩溃在全量里时有时无（W5-A 定稿的 3 轮全量里 2 轮被它打断、W5-B 1 次、G6 五轮 0 次、G7 约 12 轮 1 次），所以 App 全量 0 崩只是旁证；能下结论的是 §1.2 的压力用例（9 / 10 → 0 / 30）和 §1.1 的确定性对照（delay 配置 10 / 10 → 0 / 10）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 测试 ID | 口径 | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|---|
| `testC_midiHostSync_stressNoTrap`（新） | 噪声（≤ 4 个空块排队 + 每 5–10 ms 一个睡 1–5 ms 的慢块）下主线程 sync 2000 次 + 起停 MIDIController 200 次，Debug 构建；独立进程逐遍跑 | **10 遍 trap 9 遍**（都在 `MIDIHost.swift:73`） | **30 遍 0 次**；整包 3 遍也过 | trap 0 次；返回值 / 执行线程错 0；起停状态错 0 | ✅ |
| `testW2C2_midiHotplug_survivesControllerRestart`（78，既有） | 三轮起停后热插拔、CC / Note / learn | ✅ | ✅ 整包 3 遍都过（第 1 遍 1.75 s） | 增删通知各 ≤ 5 s | ✅ |
| `testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn`（既有） | 热插拔、CC → tbar、20 连发顺序、learn、拔掉 | ✅ | ✅ 整包 3 遍都过（第 1 遍 0.72 s） | — | ✅ |
| SwitcherControl 其余既有用例（Control 41 / Tally 3 / VMixCompat 25） | — | — | 全过（1 跳 = C5 人工项，原样） | — | ✅ |
| App 全量 `make test-app`（freshSession 起停那几条 + 崩溃报告目录） | 228 个用例，大多开头 freshSession 起停一次 | 偶发（W5-A 3 轮崩 2 轮、G6 5 轮 0、G7 约 12 轮 1） | 第 1 轮 221 过 / 4 跳 / 3 红（同机干扰，单独复跑 3 / 3 过）、第 2 轮 **225 过 / 3 跳 / 0 红**；两轮 **0 崩、没有新的 PlusMix .ips** | 无新的 PlusMix .ips | ✅ |

## 3. 没做的和原因

1. **交付 3（进程里第一次打开节目时 MIDIServer 冷启动约 0.6 s 在主线程同步等，KNOWN_ISSUES S3）：没做。** 这 0.6 s 就是进程里第一次 `MIDIClientCreate`（`MIDIHost.init` 建锚客户端时 `ready.wait()`，
   再加 `start()` 里的 `sync`）。要让主线程不等，`MIDIController.start()` 必须变成"排到宿主线程上做、连上再回报"，也就是从"同步抛错"改成"异步回调"：
   - App 的 `ControlRuntime.start()` 现在靠 `try midi.start()` 同步设 `midiError` / 出"MIDI 起不来"提示，得改成接回调、回主线程再设——App/ 不在本会话目录；只改包的话 App 那边起不来就再也没有提示，是倒退。
   - 78 的热插拔用例（prompt 要求行为不变）依赖"`start()` 返回时现有源已经枚举完"：`let before = controller.sources.count` 紧跟在 `start()` 后面当基线，异步起的话基线可能是 0、断言 `before + 1` 会在有别的源时红。
   - 所以包里单方面改既达不到效果、又要动 78 的用例语义；按 prompt"否则写明不做"。建议做法（下一个碰 MIDI 的会话 + App 会话一起，估计包 30–40 行、App 15 行左右）：
     ① `MIDIHost.init` 拿到 run loop 就返回，锚客户端改在宿主线程进 run loop 之前建（所有客户端都在宿主线程上排队建，锚仍是进程里第一个）；`anchor` / `anchorStatus` 只在包内用于诊断，改成宿主线程上读；
     ② 新增 `MIDIController.start(onReady: @escaping @Sendable (MIDIError?) -> Void)`：`started` 立刻置位、`setUpOnHost` 用 `MIDIHost.async` 排队，做完在宿主线程上回调；失败时复位 `started`、收掉派发 Task；
        同步的 `start()` 保留给需要"返回即就绪"的地方（78 的热插拔用例拿 `start()` 之后的源个数当基线）；
     ③ App 的 `ControlRuntime.start()` 改调 ②，回调里回主线程设 `midiError` 并 `notify`；`StartupOrderTests` 的 `midiColdStartForTesting` 要跟着挪进异步路径（不然模拟的还是同步卡顿）。
     起停竞争（异步起还没做完就 stop）天然没问题：`stop()` 的 `sync` 排在 setUp 后面，宿主线程上串行。
2. **`docs/KNOWN_ISSUES.md` 产品缺陷表第一行**：prompt 说由 G8 销号，没动。问题单末尾追加了处理结果。
3. **真 MIDI 设备**：这台机器没有 MIDI 硬件（`MIDIGetNumberOfSources()` = 0），起停压力用的是真 CoreMIDI 客户端 / 输入口，热插拔走 `VirtualMIDISource`，与 78 相同。

## 4. 对契约的疑问

没有。`SwitcherContracts` 没动；`MIDIHost` 是包内类型，`MIDIController` / `VirtualMIDISource` 的公开 API 与行为都没变。

## 5. 下一个会话需要知道的坑

1. **`withoutActuallyEscaping` + 跨线程**：把 `escapable` 交给别的线程时，别的线程必须在**放行调用方之前**放掉对它的最后一个引用。直接让 CF / GCD 的块捕获 `escapable`、块里最后一句 signal，
   就是这次的崩溃——块要等返回之后才被释放，而调用方随时会走；Debug、Release 都 trap。全仓库只有 `MIDIHost.sync` 这一处用 `withoutActuallyEscaping`（`grep` 过 Packages / App / Tools / CameraExtension）。
2. **复现要让宿主线程醒着**：只加 CPU 负载或只塞慢块很难撞上（§1.1、§1.2 的表）；改 `MIDIHost` 的人想验证竞态，用 `MIDIHostNoise` 那种"有界地不停塞空块"。不限量地塞会让队列无限长、sync 等很久（探针里十分钟没跑完）。
3. **`MIDIClientCreate` 偶尔整进程回 -304（MIG_BAD_ARGUMENTS）**：量复现率时连着起了上百个测试进程，专门记轮次的临时用例 15 个进程里 1 个从第 0 轮起 200 轮全是 -304、其余 14 个一次没有；
   另有 2 个进程在起停时碰到 -304（那个临时用例碰到第一次就停，没记是第几轮）。这台机器的 MIDIServer 是按需拉起的（21:27 没有 MIDI 客户端时 `ps` 里没有它，App 用例一跑又起来了），
   推测是进程连上它的时候它正在退出——一个进程一旦这样就整段不可用，和起停快慢无关（同样的循环在别的进程里 200 轮全过）。
   所以压力用例第 0 轮起不来按"CoreMIDI 不可用"跳过（sync 那段已经跑完、照常判）；连着狂起测试进程时会碰到，正常整包跑一个进程只连一次，没碰到过。
4. **进程里第一次连 MIDIServer 有时远不止 0.6 s**：整包里压力用例 0.7 s、单跑通常 0.12 s，差的就是它（`MIDIHostTests` 按类名排在 `MIDITests` 前面，第一次建 `MIDIHost` 的锚客户端算在它头上）。
   修后单跑 30 遍里 2 遍 0.67 s、**4 遍 4.7 s**（量 -304 时也见过 3.6 / 4.6 s）；MIDIServer 在跑时，一个新进程第一次 `MIDIClientCreate` 只要 11–14 ms（探针 18 次）。
   这台机器 MIDIServer 按需拉起、空闲几分钟就退出，推测几秒的那几遍是赶上它正在退出 / 重新拉起。做 KNOWN_ISSUES S3（冷启动挪后台，§3 第 1 条）的会话要按"最坏几秒"设计，不能当 0.6 s 的小卡顿。
5. **`swift test --filter` 写 `Module.Class/method`**（如 `SwitcherControlTests.MIDIHostTests/testC_midiHostSync_stressNoTrap`）；修前红的那几遍在 `~/Library/Logs/DiagnosticReports/` 留了 9 份 `xctest-2026-10-10-2115*.ips`，不是 App 的。
6. **`sync` 仍然阻塞调用线程**（通常 < 1 ms；进程里第一次 0.6 s 起、最坏几秒，见 §3 第 1 条、本节第 4 条），别在宿主线程的回调里反过来等主线程（78 报告 §5 第 3 条，仍成立）。
