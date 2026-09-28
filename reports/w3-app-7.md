# W3-E6 App 启动顺序：控制层 / 引擎预热挪到定 t0 之前（prompt 84，分支 w3-app-7）

分支 `w3-app-7`，从 main `7f6d73e`（W1-B3 合入后）开，worktree `.claude/worktrees/w3-app-7`。用户 2026-09-28 指派 agent 直接做。
机器：MacBook Pro M5 Max，macOS 27.0（26A428），Xcode 27.0（27A266a），接电源。
只动 App/ + 本报告；包、契约、Tools 一个字节没动（量测时给 App 加过临时探针，量完 `git checkout` 还原，不在任何提交里）。

## 1. 做了什么

| 交付 | 提交 | 落在哪 | 说明 |
|---|---|---|---|
| 1 红测试 | `38fc932` | 新 `Tests/StartupOrderTests.swift`；`Engine/SwitcherSession.swift`（`StartReport` + 起步日志）、`AppController.swift`（`firstStartReport`）、`Engine/ControlRuntime.swift`（`midiColdStartForTesting`） | 三条用例在 main 的顺序上全红（§2.1）；为了读得到数给会话加了起步记录（W1-B3 当时靠临时探针量的那几段），测试宿主里之后的会话要模拟冷启动用一个测试开关 |
| 2 修 | `d8cc852` | `Engine/SwitcherSession.swift`、`Engine/AudioRuntime.swift`、`Tests/StartupOrderTests.swift`（+1 条） | 先预热（控制层 + `engine.warmUp()`）再定 t0；定 t0 之后只剩建输入 + 音频 / 引擎两个 start，后两步在同一个非主线程任务里接着做；warmUp / start / stop 串行，只预热没起的、起到一半的、起失败的都走同一条收尾 |
| 3 / 4 验证 + 报告 | 本提交 | `reports/w3-app-7.md` | `make test-app` 全量、`make lint BRANCH=w3-app-7`、真 App 修前 / 修后第一秒的数（§1.4） |

### 1.1 先量：冷启动慢在哪（临时探针，量完还原）

真 App（Debug，`PlusMix --show <m0 八路合成源、去掉录制输出> --stats … --no-api --audio-device null`，与 W1-B3 同一条命令；main 的顺序），`SwitcherSession.start` 与 `ControlRuntime.start` 里临时打点：

| 运行 | 起法 | 输入 | 控制层 = 推送源 + MIDI | 音频 | 定 t0 之后用掉 | 时钟起晚 | 第 1 行 Stats：jitter_ms / missed_render / drop（30 fps 两路、60 fps 六路） |
|---|---|---|---|---|---|---|---|
| cold1 | 第一次 | 20.6 | 694.1 | 77.1 | 791.7 | **506.8** | 506.86 / 30 / 12, 12, 29 × 6 |
| warm2 | cold1 刚被杀就起 | 19.4 | 686.8 | 77.1 | 783.4 | **495.7** | 495.75 / 29 / 11, 11, 28 × 6 |
| warm3 | 隔 2 s | 20.7 | 108.3 | 55.0 | 184.0 | 0.0 | 0.025 / 0 / 0 |
| a0 | 隔 10 s | 19.0 | 686.0 = 93.6 + **591.7** | 78.2 | 783.2 | **495.7** | 495.75 / 29 / 11, 11, 28 × 6 |
| a1 | a0 刚被杀就起 | 19.6 | 107.7 = 94.7 + 12.8 | 52.1 | 179.4 | 0.0 | 0.023 / 0 / 0 |
| a2 | 隔 3 s | 20.3 | 681.2 = 98.8 + **581.9** | 76.5 | 778.0 | **491.3** | 491.36 / 29 / 11, 11, 28 × 6 |
| a3 | 隔 10 s | 19.9 | 685.5 = 94.9 + **589.9** | 77.4 | 782.8 | **495.6** | 495.68 / 29 / 11, 11, 28 × 6 |
| parentA | 隔 5 s | 19.9 | 682.7 = 92.6 + **589.5** | 76.1 | 778.7 | **491.5** | 491.50 / 29 / 11, 11, 28 × 6 |
| childB | parentA 还在跑时起第二个进程 | 19.4 | 61.4 = 48.8 + 12.4 | 114.1 | 195.0 | 0.0 | 0.011 / 0 / 0 |

测试宿主（同样的临时探针）：启动时那个会话（空节目）控制层 609.3 ms（推送源 12.1 + **MIDI 586.7** + API 约 9）、音频 69.8 ms、定 t0 之后用掉 679 ms、**起晚 405.2 ms**；
之后在同一进程里换的两个 8 路会话：控制层 90.4 / 11.8 ms（MIDI **0.2 ms**）、音频 0.1 ms、起晚 0。

- **control.start 的冷启动 = MIDI 那一步**：`MIDIHost.shared` 第一次在进程里建锚客户端、连 MIDIServer，582–592 ms，而且是在主线程上同步等（`MIDIHost.sync`）。推送源 10–99 ms，API（端口 0）约 9 ms。
- **冷热是系统级的**：只有"进程里第一个 CoreMIDI 客户端、且当时没有别的进程连着 MIDIServer"才冷；刚退出一个 PlusMix 马上再起有时是热的（a1），另一个 PlusMix 正在跑时起的进程一定是热的（childB）。
  测试宿主的 MIDIHost 锚客户端常驻，所以**测试宿主里只有启动时那个会话是真冷的**，之后换的会话、甚至从测试宿主起的子进程都是热的——这决定了用例怎么写（§1.2）。
- W1-B3 那张表（控制层 686 / 57 ms）的"第二次热"就是这个现象；按 main 的顺序，冷的那几次起晚 = 定 t0 之后用掉的 − 300 ms + 引擎自己的十几 ms，missed_render = ⌊起晚 / 16.7⌋，与 W1-B3 的公式一致。

### 1.2 用例（交付 1，先红）

都在 `App/Tests/StartupOrderTests.swift`，写成同步用例（`Task { … }` + 轮询盒子，ReleaseTests.R7 的写法），没有 async 测试体：

1. **`testW3E6_sessionStart_clockNotLateAfterColdStart`**（prompt 指定的那条）：`AppController.replaceSession` 起 m0 那 8 路合成源（30 fps 两路、一路带音频，60 fps 六路，主窗口绑着），
   control.start 的冷启动用 `ControlRuntime.midiColdStartForTesting = 0.58 s` 在 MIDI 那一步之前同步卡住主线程（与 `MIDIHost.shared` 第一次建锚客户端同样是阻塞，所以用 `usleep` 不用 await），
   其余全是真的。读引擎的 `clockStartLag` ≤ 20 ms，Stats 第 2 行（起引擎后 ≈ 2 s，missed_render / drop 都是累计值）的 missed_render ≤ 2、8 路 drop 全 0。
   为什么要模拟：测试宿主里只有启动时那个会话赶得上真冷启动（§1.1），之后的会话、子进程都是热的，按 main 的顺序热的会话定 t0 之后只用掉 110 ms 左右，不会红。
2. **`testW3E6_launchSession_realColdStart_clockNotLate`**：真冷启动——测试宿主启动时那个会话（`AppController.launch` → `replaceSession`，进程里第一次 control.start）的起步记录
   （`AppController.firstStartReport`），`clockStartLagMs` ≤ 20。别的进程正连着 MIDIServer 时启动会话本来就是热的，修前也可能不红；修后冷热都该准时。
3. **`testW3E6_stopDuringStart_leavesNothingRunning`**：停与起对称——`replaceSession` 刚把新会话建出来（start 正在起控制层）就 `controller.shutdown()`（退出 App 的路径）：
   两边都应返回、控制器没有新错误；会话的时钟没起、引擎没在跑、预热过的渲染器放掉了（`preparedFormat` / `sink` 为 nil）、音频引擎 / 控制层 / MIDI / API 都停了、输入一个不剩。
4. **`testW3E6_warmedButNotStartedSession_stopReleasesEngineAndControl`**（随修一起加：测的是新接口 `SwitcherSession.warmUp()`，main 上编不过，没有红灯轮）：
   `warmUp()` 之后 stage = warm、渲染器 prepare 过、引擎是渲染器的 sink、控制层起了、时钟没起、t0 = 0、输入没建；`stop()` 两次之后全部放掉。

### 1.3 修（交付 2）

`SwitcherSession`（`App/Sources/Engine/SwitcherSession.swift`）：

- **起分两段**。`warmUp()`：`control.start()`（推送源 / API / MIDI）→ `engine.warmUp()`（渲染器 prepare + 首帧空渲染、状态机线程、第 0 拍快照），与节目时钟无关、幂等。
  `start(leadMilliseconds:)`：没预热先预热 → **定 t0 = now + 提前量（300 ms，没改）** → `inputs.reconcile`（输入按 t0 建时间线：合成源的 `SyntheticTimeline(t0:)`、其他输入的 `ProgramTiming`，只能在定 t0 之后）
  → 音频引擎 `start(clock:)` → 引擎 `start(t0:)` → 输入 start → Stats 采样 → 输出 / Aux 按快照起 → 快照轮询。
- **定 t0 之后不回主线程**：音频引擎与引擎的两个 start 放进同一个 `@concurrent nonisolated static func startClock`，接着做、中间不 await 主线程；
  主线程这时再忙（启动时建窗口 / 首次布局、测试宿主开跑用例）也拖不动时钟。音频引擎起不来仍不算错（带回原因、回主线程提示，同原来）。
  为此 `AudioRuntime.start(clock:)` 改成 `nonisolated`（它只转调 `AudioEngine.start`）。
- **停与起对称**：warmUp / start / stop 用一把主线程上的"生命周期锁"串行（continuation 排队、交接时不放锁）；阶段 `stage`：idle → warm → running（`isRunning` 改成由它算）。
  `stop()` 先置 `stopRequested` 再排队：进行中的 start 在**定 t0 之前的检查点**看到它就不起时钟、正常返回；排着的 stop 再按原来的停顺序收
  （API → 输出 → Aux → Stats → 输入 → 引擎 → 音频引擎 → 推送源；`engine.stop()` 放掉只预热没起的渲染器与状态机线程，每一步对没起的部分是空操作）。
  已经定了 t0 的 start 就等它起完再停。`warmUp()` / `start()` 失败时自己走同一条收尾再抛，调用方（`AppController.replaceSession` 的 catch）不用再停。
  换节目仍是 `replaceSession` 先 `await stopSession()`（旧会话停干净、API 端口放掉）再建新会话，新会话的 control.start 现在在预热里、仍在旧会话停完之后。
- **起步记录**（交付 1 加的诊断，修后各段按新顺序记）：`SwitcherSession.startReport` + 每次起打一行日志，例如修后真 App 冷启动：
  `节目起步：控制层 681.2 ms、引擎预热 75.5 ms、输入 21.7 ms、音频 0.1 ms、引擎 start 4.2 ms；定 t0 之后用掉 21.9 ms（提前量 300 ms），时钟起晚 0.0 ms`。
  `AppController.firstStartReport` 存进程里第一次起好的那份（冷启动只在它身上）。都是诊断量，不进 Stats（`clock_start_lag_ms` 进 stats.jsonl 是契约，§4）。

### 1.4 真 App：修前 / 修后第一秒（交付 3 要记的数）

同一条命令（m0 八路、`--no-api --audio-device null`、Debug），每次起完 5 s 后 SIGKILL，读 stats.jsonl 第 1 行（起引擎后约 1 s，覆盖 t0 前后第一秒）与起步日志：

| | 次数 | 控制层 | 定 t0 之后用掉 | clockStartLag | 第 1 行 jitter_ms | missed_render | drop（30 fps / 60 fps） |
|---|---|---|---|---|---|---|---|
| 修前（main 的顺序，冷的六次：cold1 / warm2 / a0 / a2 / a3 / parentA） | 6 | 681–694 ms | 778–792 ms | **491.3–506.8 ms** | **491.4–506.9** | **29–30** | **11–12 / 28–29** |
| 修前（热的三次：warm3 / a1 / childB） | 3 | 61–108 ms | 179–195 ms | 0.0 | 0.011–0.025 | 0 | 0 / 0 |
| **修后**（f1 / f2 / f3，每次隔 8 s，都是冷的） | 3 | 630.2 / 681.2 / 680.8 ms（在定 t0 之前） | 21.1 / 21.9 / 21.6 ms | **0.0** | **0.023–0.027** | **0** | **0 / 0** |
| **修后**，API 开着（`--api-listen 127.0.0.1:0` 代替 `--no-api`，即 App 的默认配置） | 1 | 692.5 ms（在定 t0 之前） | 21.4 ms | **0.0** | **0.023** | **0** | **0 / 0** |

修后第 2、3 行也全是 missed 0、drop 0、jitter ≤ 0.028 ms。预热 68–131 ms 也在定 t0 之前（渲染器 prepare + 首帧空渲染 + 状态机线程；这些段都是主线程上量的墙钟时间，
含 await 之后回主线程的等待，App 刚起时主线程在建窗口，所以比 W1-B3 在引擎里量的 prepare 2 ms 长）。
第 1 行各路 fps：修后 22.7 / 44.4（统计窗口从起引擎算起，那时离 t0 还有约 280 ms，源到 t0 才出第一帧）；修前冷的那几次是 45 / 90（时钟起晚时合成源从 t0 起积压的帧一起补推进来，
大多随即被 3 格帧槽挤掉 = 那一行的 drop）。第 2 行起两边都是 30.0 / 60.0。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

### 2.1 本会话的用例（修前 = 交付 1 的提交 `38fc932` 上跑，即 main 的顺序；修后 = `d8cc852`）

| 测试 ID | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|
| `testW3E6_sessionStart_clockNotLateAfterColdStart` | clockStartLag **444.8 ms**（控制层 623.7 = 模拟 580 + 真 44、输入 19.2、音频 89.4，定 t0 之后用掉 732.3 ms）；Stats 第 2 行 missed_render **26**、drop 1:**11** 2:**11** 3–8:**26**；第 1 行 jitter_ms 444.88 | clockStartLag **0.0 ms**（单跑 / 全量各一次）；第 2 行 missed_render **0**、8 路 drop **全 0**；jitter_ms 0.020–0.028；控制层 670.6 / 633.6 ms 与预热在定 t0 之前，定 t0 之后用掉 40.7 / 29.6 ms | lag ≤ 20 ms、头 2 秒 missed ≤ 2、各路 drop 0 | ✅ |
| `testW3E6_launchSession_realColdStart_clockNotLate` | clockStartLag **395.6 ms**（测试宿主启动时的真冷启动：控制层 600.6、音频 71.6，定 t0 之后用掉 672.2 ms） | **0.0 ms**（单跑 / 全量：控制层 613.9 / 634.7 ms、预热 74.6 / 131.5 ms 都在定 t0 之前，定 t0 之后用掉 0.19 / 0.15 ms） | ≤ 20 ms | ✅ |
| `testW3E6_stopDuringStart_leavesNothingRunning` | **11 处断言红**：会话 / 引擎在跑、时钟起了、渲染器 prepare 着（1080p60）、sink 在、音频引擎 / 控制层 / MIDI / API 在跑、输入 [1] 建着并注册在引擎上 | 全过（0.31 / 0.37 s）；控制器没有新错误 | 全部停掉、不算错误 | ✅ |
| `testW3E6_warmedButNotStartedSession_stopReleasesEngineAndControl` | —（测新接口 `warmUp()`，main 上编不过，没有红灯轮） | 全过（0.023–0.026 s）：预热后 stage = warm、渲染器 prepare 过、控制层起了、没时钟、t0 = 0、没输入；两次 stop 后全放掉 | 预热 / 停的状态逐项 | ✅ |

### 2.2 全量 `make test-app`（开跑前 `pgrep -fl "xcodebuild .*test"` 查过没有别的会话在跑）

| 轮 | 时间 | 结果 | 说明 |
|---|---|---|---|
| 1 | 20:10:56–20:14:41（测试段 224 s） | **99 个：97 过、0 失败、2 跳**；`make test-app` 退出码 0 | 计数从 `.build/DerivedData/Logs/Test/Test-Switcher-2026.09.28_20-10-56-+0800.xcresult` 用 `xcrun xcresulttool get test-results summary` 读（W3-E5 的 95 个 + 本会话 4 个） |

- 跳过的两个都是原有的：`testInputs_builtInCameraLiveWithin5sAndPictureShows`（BLOCKED-权限：新 worktree 的测试宿主还没有摄像头权限，系统在弹授权提示）、
  `testL1_virtualCameraEgress_requiresSignedExtension`（BLOCKED-签名：解锁 = Team ID 签名 + 从 /Applications 运行 + 允许扩展）。
- 这一轮全量里起了 98 次会话（每个用例换节目都会起），起步日志里 **clockStartLag 全是 0.0**，定 t0 之后用掉最多 29.6 ms（8 路那条）、中位 0.1 ms；启动时那个会话控制层 634.7 ms、预热 131.5 ms，都在定 t0 之前。
- 显示类 / 推流类 / S7 这些以前偶尔环境红的用例这一轮都过了；没改任何阈值或断言。

### 2.3 lint

`make lint BRANCH=w3-app-7`：退出码 0——禁词 / 版本号 0.1.0 / Package.swift 约束、依赖方向（8 个包）、归属（5 个改动文件都在 App/；本报告提交后是 6 个，都在允许范围）、`check-rt-symbols` 全绿。

## 3. 没做的和原因

1. **音频引擎的 start 仍在定 t0 之后**（prompt 把"audio 引擎起"也列在定 t0 之前）：`AudioEngine.start(clock:)` 要节目时钟的 `TickClockSpec`（AFV / 转场事件按它把拍换成 host time，
   与引擎必须是同一个 t0），不改 SwitcherAudio 的接口就只能在定 t0 之后调；headless 也是这个顺序。W1-B3 §5 第 1 条给的改法也是"warmUp → 定 t0 → audio.start(clock:) → engine.start"。
   现在它与引擎 start 在同一个非主线程任务里、不回主线程，修后实测 0.1–0.2 ms（修前在主线程上 await，墙钟 52–114 ms，含回主线程的等待）。音频设备本身在 `AudioRuntime.init`（会话建的时候）就建好了。
2. **建输入仍在定 t0 之后**：输入按 t0 建时间线（合成源 `SyntheticTimeline(t0:)`，其余 `init(config:timing:…)` 收 `ProgramTiming`），不能提前。8 路合成源 19–41 ms；
   摄像头 / 屏幕 / 文件 / NDI / DeckLink 的 init 在定 t0 之后花多少没量（摄像头要 TCC、DeckLink 要硬件）——节目里这类输入多、建得慢时会再吃提前量，起步日志的"定 t0 之后用掉 X ms"能直接看出来（§5 第 2 条）。
3. **提前量没改**（prompt：提前量本身不改），仍是 300 ms。
4. **control.start 的冷启动仍在主线程上同步等 MIDI ≈ 0.6 s**（`MIDIHost.sync`，SwitcherControl 的设计）：现在在定 t0 之前，不再拖时钟，但 App 刚起窗口时界面会有这 0.6 s 不响应。
   要挪到后台得改 SwitcherControl（W2-C 的包），不在本会话范围。
5. **没用子进程测真冷启动**：从测试宿主起的子进程也是热的（测试宿主一直连着 MIDIServer，§1.1 的 childB），而且不是测试宿主的 App 会往真实 UserDefaults 写 recentShows / lastShow。
   所以真冷启动只读测试宿主启动时那个会话（用例 2），其余用模拟开关。
6. `clock_start_lag_ms` 没进 stats.jsonl（契约，W1-B3 §4 第 3 条）；App 这边只有 `StartReport` 与起步日志。

## 4. 对契约的疑问

无。用到的 `Engine.warmUp()` / `Engine.clockStartLag` 是 SwitcherEngine 的公开接口，不是契约。
W1-B3 §4 第 3 条（stats.jsonl 加 `clock_start_lag_ms`，让 gate / 状态行也看得到"起晚"）仍待用户裁；修后 App 冷启动起晚为 0，这一条的迫切性小了。

## 5. 下一个会话需要知道的坑

1. **冷启动只在"进程里第一个 CoreMIDI 客户端、且没有别的进程连着 MIDIServer"时出现**（582–592 ms）。测试宿主里只有启动时那个会话是冷的，之后的会话、从测试宿主起的子进程都是热的（0.2 / 12 ms）；
   要在之后的会话上测冷启动用 `ControlRuntime.midiColdStartForTesting`（静态、主线程上同步 `usleep`——async 上下文里 `Thread.sleep` 编不过；用完在 `defer` 里清掉）。
   手工量真 App 时，每次起之间隔几秒、且别开着别的 MIDI 程序，不然量到的是热的。
2. **起步日志**：每次起会话打一行 `节目起步：控制层 … ms、引擎预热 … ms、输入 … ms、音频 … ms、引擎 start … ms；定 t0 之后用掉 … ms（提前量 300 ms），时钟起晚 … ms`（NSLog，`--stats` 起的 App 在 stderr 里）。
   "定 t0 之后用掉"接近 300 ms 就是节目里的输入建得太慢（§3 第 2 条）；以后量启动不用再加临时探针。
3. **SwitcherSession 的接口变了**：`isRunning` 改成由 `stage`（idle / warm / running）算；新增 `warmUp()`；`start()` 在有 stop 排队时会**正常返回但不在跑**（只在退出 App 时第一个会话还在起这种情况，控制器那时已经把 session 置 nil 了），
   调用方要看 `isRunning`；`warmUp()` / `start()` 失败会自己收尾（stage 回 idle），不用再 stop。`AudioRuntime.start(clock:)` 现在是 `nonisolated`。
4. **`@concurrent` 要 Swift 6.2（Xcode 26）起**：`project.yml` 的 xcodeVersion 是 26.0，够；工程是 Swift 6 语言模式、没开 NonisolatedNonsendingByDefault，本来 `nonisolated async` 就不在主线程跑，写上是防以后开了那个开关。
5. **量真 App 会写真实的 UserDefaults**：`--show` 打开节目会写 `com.plusmix.switcher` 的 `lastShow` / `recentShows`；本会话量之前 `defaults export`、量完 `defaults import` 还原，
   每次用 SIGKILL 停（Cmd-Q 会走 shutdown，往 `~/Library/Application Support/PlusMix/LastSession.switcher.json` 自动保存）。
   还原到的状态里 `lastShow` 仍指向 W1-B3 量测时留下的 `…/worktrees/w1-core-3/scenarios/m0-show.json`（不是本会话写的，没动）。
6. 这几条用例跑的时候 XCTest 的 Thread Performance Checker 会打"User-initiated 线程在等没有 QoS 的线程"的警告，调用栈是 `SyntheticAudioInput.stop → RealtimeThread.stop`（TestKit，停带音频的合成源时 join），原来就有，不是失败。
7. 用例 2（启动会话）修前红不红取决于测试宿主启动那一刻 MIDIServer 冷不冷：本机修前测试宿主起了两次（红灯轮 395.6 ms、之前的探针 405.2 ms）都是冷的。修后冷热都过。
