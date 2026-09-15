# W2-C 控制层一期（命令总线、HTTP / WS API、快捷键、MIDI）—— 报告（分支 w2-control）

日期 2026-09-15。机器 Apple M5 Max 128 GB / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3，电源适配器，室温；同一台机器上另外四个 W2 会话在并行编译（`uptime` 负载 2–3），实跑期间没有游戏。
worktree `.claude/worktrees/w2-control-command-bus-api-8f81c2`，分支 `claude/w2-control-command-bus-api-8f81c2`（桌面端自动起的名），从 `main`（2290b4e）开；
**`w2-control` 这个分支名指向同一个 HEAD**（`git branch -f w2-control`），`make lint BRANCH=w2-control` 和检查点合并都用它。
提交：`git log main..w2-control`（9 个）。动了 `Packages/SwitcherControl/`、`Tools/switcher-headless/`（`--api` 三个参数 + 接线）、`docs/api.md`（生成物）、`scripts/apitest/`、本报告。

## 1. 做了什么

`Packages/SwitcherControl/`：库 target `SwitcherControl`（18 个文件）+ 可执行 target `switcher-apidoc` + 测试 target（26 个测试，5.9 s）。依赖：SwitcherCore 的 Contracts + Engine（状态机）、Hummingbird 2.26 + hummingbird-websocket 2.7（Apache-2.0）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 CommandBus | `CommandBus/CommandBus.swift`、`CommandValidator.swift` | 所有来源（`CommandSource` ui / hotkey / midi / api / script）一个入口：结构校验 → 原子分配全局 sequence → 记 issuedAt（host time）→ `StateMachine.submit(IssuedCommand)` → 回执 `CommandReceipt{sequence, appliedTick}` → 观察者。并发提交时早到的高序号由状态机排队（`.queued`），总线从回执历史取回自己的，两个客户端合起来仍是一个全局顺序。结构性非法（引用不存在的输入 / 输出、kind 不符、通道越界、负时长、编号重复、节目文件不合法）在入口拒绝并给理由——reducer 对这些是静默原样返回，API 用户会误以为成功；随时间变的条件（转场进行中再 fade）不预判，仍交给 reducer。`CommandValidator` 拒绝的命令，`testValidator_agreesWithReducer` 证明 reducer 也一定原样返回 |
| 2 HTTP + WS | `API/APIServer.swift`、`StateFeed.swift`、`APIModels.swift`、`APIServerConfiguration.swift`、`APIJSON.swift` | 端口 **8765**（未注册的高位端口、避开常见直播软件的默认端口、好记；`--api-listen` 可改），默认只监听 127.0.0.1，可配 0.0.0.0；token 鉴权默认关（`Authorization: Bearer` 或 WS 的 `?token=`，401 带 JSON）。`GET /api/v1/state` = version / now / timebase / clock / sequence / tick / tickTime / **MixerState 原样** / tally（每路 {program, preview}）/ stats（最近一行）；`POST /api/v1/command` `{"command": …}`（也接受裸 Command）→ `{sequence, appliedTick, issuedAt, appliedTickTime}`，非法 400 `{"error"}`；`GET /api/v1/commands` 目录；`WS /api/v1/events`：hello → 当前快照 → 之后每次变化一条 **整快照 + 版本号**（sequence / tick / tickTime / sentAt / state / tally），每秒一条 stats；连接上也能发命令（`{"id", "command"}` → receipt / error）。所有应答用同一个 JSONEncoder（键排序、不转义斜杠，和 stats.jsonl 一样），可选字段缺省写 null 不省键 |
| 整快照 vs JSON Patch | 选整快照 | 理由：快照 8 路时约 7.5 KB，本机回环带宽不是问题（C4 满负载 160 条/s ≈ 1.2 MB/s）；整快照幂等、丢一条自愈，客户端不用维护补丁状态机；tally / PGM / PVW 只关心最新值；每拍最多一条（同一拍内多条命令只发最终状态，渲染线程看到的也是每拍一个快照），慢客户端各自 256 条缓冲丢旧的，不拖总线。JSON Patch 省的带宽换来的是客户端复杂度和"漏一条就全错" |
| 状态变化怎么感知 | `StateFeed` | 状态机没有"快照已发布"回调，不轮询：挂 `TickObserver`（每拍 advance 后在状态机线程一次原子 max + 信号量）+ `CommandBusObserver`（每条命令回执前），推送线程醒来等 `preparedTick` 追上再读 `publisher.latest`，对象身份变了才编码一次扇出；250 ms 兜底轮询 |
| 3 快捷键 | `Hotkeys/KeyCombo.swift`、`ControlAction.swift`、`HotkeyTable.swift`、`HotkeyDispatcher.swift` | JSON 表存 `~/Library/Application Support/Switcher/hotkeys.json`（节目文件之外）；组合键文本归一化成 `ctrl+alt+shift+cmd+<键>` 一种写法（别名 / 符号 / 大小写 / 顺序都收敛），冲突检测按它比，读表有冲突默认报错并点名；默认表 = 设计方案 §9.4 / W2-B：数字 PVW（0 = 10 号）、Shift 数字 PGM、空格 Cut、回车 Auto（按已选转场，默认 Fade 30 拍）、F 键 FTB 开关。开关型动作（`ControlAction.toggleFTB / toggleOverlay / toggleMute / toggleRecord / toggleStream / toggleAFV`）按最新快照解析成显式命令再投总线。`KeyCombo(event: NSEvent)`：charactersIgnoringModifiers + keyCode 表，Shift+1 仍是 "1" |
| 4 MIDI | `MIDI/MIDIMapTable.swift`、`MIDIMapper.swift`、`MIDIController.swift`、`VirtualMIDISource.swift` | CoreMIDI（`MIDIClientCreateWithBlock` + `MIDIInputPortCreateWithProtocol` MIDI 1.0 协议，UMP 解析）；映射表 JSON（`midi.json`，同一目录）：CC → tbar / inputGain / busGain（0–127 线性映射到 [minDb, maxDb]），Note 按下 → ControlAction；T-bar 推到一端提交并换向（拉回来是下一次转场，真推杆手感）；learn：下一条 CC / Note 交给回调不派发；热插拔：源增删通知自动连接 / 移除；命令经一条 AsyncStream 顺序提交，CC 不乱序。`VirtualMIDISource` 放正式代码（自测 + 将来 App 的软件推杆） |
| 5 Tally | `StateFeed` / `StateResponse.tally` / `SnapshotMessage.tally` | 每条快照和 GET /state 都带 `{"<输入编号>": {"program", "preview"}}`，由 `MixerState.tallies` 推导（全系统只算这一处），W3-D 的外部 tally / Stream Deck 直接用 |
| 6 headless `--api` | `Tools/switcher-headless`（`--api`、`--api-listen host:port`、`--api-token`） | 先于引擎起（客户端能在第 0 拍前连上）；Stats 只有一份：有 `--stats` 时写文件的采样线程顺手推给 API，否则另起 1 Hz 采样只喂 API；停机先停 API 再停引擎，推送源最后停；汇总行打印总线 / 推送计数 |
| docs/api.md | `CommandBus/CommandCatalog.swift`、`API/APIDocument.swift`、`Sources/switcher-apidoc` | `CommandKind` 用穷举 switch 钉住 27 个 case（契约加 case 这里编译就红），每条一句说明 + 参数 + 用真 JSONEncoder 编出来的样例；`swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`；`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 保证仓库里那份不落后 |
| C 系列客户端 | `scripts/apitest/apitest.py`、`run-c-tests.sh`、`README.md` | 只用 Python 3 标准库（自带 RFC 6455 文本帧客户端；时间戳用 ctypes 调 `mach_absolute_time`，和服务端同一个钟）；`run` 记全部快照 / stats 并发 C1 的 cut、C4 的带序号命令；`evaluate` 对着 `frameprobe frames` 的逐帧输出算 C1–C4 出 Markdown；`scenario` 生成每 5 s 切一次（每 60 s 一次 Fade）的场景；`run-c-tests.sh` 一键 |

`swift test --package-path Packages/SwitcherControl` 26/26 绿（5.9 s）；`make lint BRANCH=w2-control`：禁词 / 版本号 / Package.swift / 依赖方向 / check-rt-symbols 绿，`check-ownership.sh w2-control` 报 4 个文件越界（`docs/api.md`、`scripts/apitest/*`）——都是 prompt 点名要放的位置，见 §4 第 1 条。`make gen build-app`（xcodebuild，App 链接 SwitcherControl 及其远程依赖）绿；`make test-tools`（两个工具冒烟）绿。
每次 `make test-tools` / `run-c-tests.sh` 会在 `Tools/frameprobe/` 生成一个 `Package.resolved`（frameprobe 没有远程依赖，纯本地 pin，不归本会话），我没提交、跑完删掉了。

## 2. 每个测试：数值 / 阈值 / 通过否

### 2.1 C1–C4（headless release + 8 路合成源 + 录制，10 分钟）

跑法：`scripts/apitest/run-c-tests.sh --minutes 10 --label 10min-b`（release 编译；`.build/apitest/10min-b/` 下有 show.json / scenario.json / headless.log / out.mov / stats.jsonl / session.json / frames.json / switches.md / report.md / summary.json，不入库）。
场景：M0 节目（8 路合成源 1080p60，混 30 / 59.94 / 60、±100 ppm、±3 ms 抖动）+ 每 5 s 切一次（每 60 s 一次 Fade 30 拍）+ 录制 H.264 + stats；客户端全程连 WS，前 50 s 每秒发一次 cut（先把 PVW 明确指到另一路，相位避开场景切换点 ≥ 0.4 s），随后 2 个客户端各 100 条/s × 60 s。引擎侧：36000 拍 0 跳拍 0 missed_render，V1 平均 1.875 ms，录制 36000 帧 = 600.000 s。总线：12059 条命令 0 拒绝、538 条在状态机排过队；推送 9227 条快照（12000 条 C4 命令合并成 ≈ 9600 条）。

| 测试 ID | 口径 | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|
| C1 命令延迟 | 客户端发 cut 的 host time → 录制画面里新 PGM 输入 ID 首次出现那一帧的拍点时刻（帧 → 拍按 pts，与 index 一致 36000/36000） | 50 次：min 0.56 / p50 6.18 / mean 7.52 / **max 16.57 ms**；RTT p50 0.298 ms、max 0.506 ms；回执 appliedTick 与画面生效拍相同 50/50 | ≤ 1 拍（16.67 ms）+ 该次 RTT | ✅ 50/50 |
| C2 推送延迟 | 每条快照：收到时刻 − 该快照生效拍的拍点时刻（prompt 口径；负值 = 状态在拍点前已到客户端） | 9228 条：p50 −7.92 / **p99 0.16** / max 0.81 ms | p99 ≤ 50 / ≤ 20 | ✅（两档） |
| C2（纯传输） | 收到时刻 − 服务端序列化时刻 | p50 0.266 / **p99 0.625** / max 1.42 ms | 同上 | ✅ |
| C3 一致性 | 每一帧解出的输入 ID 必须属于 API 在该拍 tally.program == true 的输入集合（转场中 PGM 与 PVW 都算；"该拍的状态" = 最后一条 tick ≤ 帧拍的快照） | 35783 帧比对，**0 不一致**；能用相邻一拍解释的边界帧也是 0；217 帧解不出 ID（9 次 Fade 的混合帧）跳过 | 0 不一致（硬性） | ✅ |
| C4 并发 | 2 客户端 × 100 条/s × 60 s 的 `renameInput(input: i, name: "c<i>-<k>")` | 12000/12000 回执，每客户端 sequence 与 k 同序，合并后 sequence [60, 12059] 无空洞，最终名字 = 各自最后一条，WS 快照 sequence 0 次倒退；RTT p50 0.299 / p99 0.679 / max 4.25 ms | 0 丢失 0 乱序（硬性） | ✅ |

第一次 10 分钟跑（`.build/apitest/10min/`，我在旁边编译时跑的）C2 / C3 / C4 同样通过（C2 p99 −0.75 / 传输 0.69 ms，C3 0 不一致，C4 12000/12000），C1 只有 45/50 能在画面里找到生效拍——另 5 次是场景脚本把 PVW 转到了和 PGM 同一路，cut 在画面上没有变化（测试设计碰撞，不是系统问题）；客户端改成 cut 前先把 PVW 指到另一路后重跑得到上表。

C1 的分布就是"命令随机落在一拍内的哪个位置"：命令落在渲染线程还没消费的最早一拍（rendered + 1），差值均匀分布在 (0, 1 拍)，max 16.57 = 16.67 − 0.1。C2 相对拍点几乎全是负值：命令在拍点前应用并推送，转场进度由状态机在渲染线程要那一拍之前准备好，所以客户端总是先于画面知道状态。

### 2.2 单元测试（`swift test --package-path Packages/SwitcherControl`，debug，26 个）

| 测试 | 函数 | 数值 | 通过 |
|---|---|---|---|
| 总线 sequence / issuedAt / 回执 | `testBus_assignsContiguousSequencesAndIssuedAt`、`testBus_receiptTickIsTheTickThePictureChangesOn` | sequence 1 2 3 连续、issuedAt 落在调用前后、渲染线程已消费第 100 拍时回执 = 101 | ✅ |
| 结构校验 | `testBus_rejectsStructurallyInvalidCommandsWithReason`、`testValidator_agreesWithReducer` | 20 种非法命令全部拒绝且理由含关键词、不占 sequence、状态不变；27 种合法放行；拒绝的 reducer 也原样返回 | ✅ |
| C4 进程内 | `testC4_hundredCommandsPerSecond_twoConcurrentClients_noLossNoReorder` | 2 × 300 条 @100/s：每客户端有序、合并 1…600 无空洞、状态机应用顺序 = sequence 顺序、pending 0 | ✅ |
| 观察者 | `testBus_observerSeesEveryAppliedEntryInOrder` | 5 条按序 | ✅ |
| 目录 / 文档 | `testCatalog_coversEveryCommandCase_andWireKeyIsCaseName`、`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | 27 个 case、JSON 顶层键 = case 名、样例往返、docs/api.md 与生成一致 | ✅ |
| GET state | `testAPI_getState_returnsStateTallyClockAndStats` | 键名与 Codable 一致、tally 三种、stats 灌一行后 GET 解回来 == 同一行 | ✅ |
| POST command | `testAPI_postCommand_receiptAnd400WithReason` | 200 回执（appliedTickTime = 时钟算的）、裸 Command 也行、400 三种（不存在的输入 / 未知命令 / 坏 JSON）、目录 27 条 | ✅ |
| WS 事件 | `testAPI_wsEvents_helloSnapshotStatsReceiptAndTally` | hello → 快照 → 命令后推送（tally 对调）→ 拍推进的转场进度一拍一条（转场中 PVW 的 tally.program 也 true）→ stats → WS 上发命令得 receipt / error | ✅ |
| 鉴权 | `testAPI_tokenAuth_401WithoutToken` | 无 / 错 token 401，对 200；WS `?token=` 通、无 token 连不上 | ✅ |
| C2 进程内 | `testC2_pushLatency_inProcess_p99` | 200 次变化（一半命令、一半拍推进）：传输 p50 0.33 / p99 0.41 / max 0.62 ms | ✅ |
| 慢订阅者 | `testAPI_wsSlowSubscriberDoesNotBlockBus` | 不读 WS 猛发 2000 条：0.34 s 完成，最后收到的是最终状态 | ✅ |
| 快捷键 | 7 个 `testHotkey_*` | 组合键 17 组解析 / 归一化 / 往返、默认表 23 条无冲突、JSON 往返 + 手写表 + 用户文件位置、冲突 2 处点名 + 坏组合键报错、开关型解析、派发（同步 / 异步 / 换表 / 拒绝计数）、NSEvent → KeyCombo 9 组 | ✅ |
| MIDI 映射 | `testMIDI_mapTableJSONRoundTripAndConflicts`、`testMIDI_ccToTbar_flipsDirectionAtEachEnd`、`testMIDI_ccToGains_andNoteToActions`、`testMIDI_umpParsing` | JSON 往返 / 冲突 / 范围检查；T-bar 0 → 127 提交后换向、127 → 0 再提交；推子线性映射；Note Off / 力度 0 不触发；UMP 混合消息类型解析 | ✅ |
| MIDI 虚拟端点 | `testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn` | 起控制器后创建虚拟源 → 自动连上（热插拔）；CC1=64 → tbar 0.504（来源 midi）；CC1=127 提交对调；拉回 64 → 新转场 0.496；到 0 再提交；CC7=127 → 增益 +12 dB；Note 60 → cut，Note Off 无动作；连发 20 个 CC 顺序不乱；learn 捕获 CC9@ch3 不派发；无映射计 ignored；销毁源后列表移除 | ✅（1.3 s） |

## 3. 没做的和原因

1. **MIDI 14-bit CC（MSB/LSB 配对的细分辨率推杆）与 MIDI 输出（把 tally / 状态回灌给控制器的灯）**：一期只做 7-bit 输入；128 级对 T-bar 够用（每级 0.8%）。回灌是 W3-D 的 Stream Deck / 外部 tally 那一路的事。
2. **App 接线**：`SwitcherSession.send`（W2-B）换成 `CommandBus.submit(_, source: .ui)`、主窗口 keyDown 接 `HotkeyDispatcher`、设置里起 `APIServer` / `MIDIController`、状态行采样的那一行 Stats 同时 `feed.publish(stats:)`——按落地方案这些是 G3 的胶水，我没碰 `App/`。接口都是一行调用，见 §5 第 1 条。
3. **0.0.0.0 监听只测了配置解析**（`APIServerConfiguration.parseListen`），没有第二台机器做跨机测试；Hummingbird 绑 0.0.0.0 和绑 127.0.0.1 是同一条路径。
4. **JSON Patch** 没做（选了整快照，理由见 §1）。若将来快照大到几十 KB（几十路输入 + 效果链），可在 WS 上加 `?mode=patch` 协商，客户端结构不变。
5. **C 系列的 60 分钟 / 8 小时版本** 没跑：prompt 要的是 10 分钟；脚本 `--minutes` 可改，evaluate 对 36000 帧用了约 1.5 s，长稳没有障碍。
6. **快捷键 / MIDI 的编辑界面**是 W3-E 的（落地方案第 6 条）。

## 4. 对契约的疑问

1. **OWNERSHIP 越界（请用户或 G3 定）**：prompt 的"只准动"一行只有 `Packages/SwitcherControl/` 和 headless 的 `--api`，但同一份 prompt 的测试要求"WS 客户端脚本放 `scripts/apitest/`"、"docs/api.md 由 Command 枚举生成"。我按 prompt 的交付位置放了（`scripts/apitest/` 3 个文件、`docs/api.md` 1 个），`check-ownership.sh w2-control` 因此报这 4 个文件越界。请在 `docs/OWNERSHIP.md` W2-C 行加 `scripts/apitest/` 和 `docs/api.md` 两个 token（或告诉我挪到 `Packages/SwitcherControl/Scripts/` 之类）。
2. **`IssuedCommand.issuedAt` 的含义**：我按"进总线的时刻"填（服务端 host time），不是客户端发出的时刻——HTTP 请求里没有客户端时间戳，也不该信它。C1 的"客户端记录发 cut 的 host time"由客户端自己记（脚本里 `send`），与 issuedAt 无关。契约注释"C1 = 生效拍点时刻 − issuedAt"因此量的是"服务端收到 → 生效"，比 C1 少一个单程网络延迟（本机 0.15 ms）。是否要在 CONTRACTS.md 里把这句说清（不改类型）。
3. **`CommandReceipt` 没有"状态是否真的变了"**：reducer 对语义上被忽略的命令（转场进行中再 fade、FTB 目标已相同、mute 已是该值）原样返回，API 只能回 200 带 appliedTick，客户端分不清"生效"和"忽略"。要分清得在 `CommandReceipt` 加一个 `applied: Bool`（或 `changed`）——这是契约改动，我没动；如果需要，我写提案。目前结构性错误已在总线入口 400 掉，覆盖了最常见的误用。
4. **状态机没有"快照已发布"的观察点**（SwitcherEngine，W1-B 的包，不是契约）：`TickObserver` 在 advance 之后、发布之前被调，`TransitionEventSink` 只报转场。我用 TickObserver + 总线观察者 + `preparedTick` 追赶拼出来了（§1），能用但绕。建议 W1-B 在 `StateMachine` 加一个 `SnapshotObserver`（发布后在状态机线程调，参数就是 `MixerSnapshot`），App 的主线程分发（W2-B "快照变化经主线程分发"）也能用同一个钩子。
5. **`MixerSnapshot` 没有发布时刻**：C2 的"纯传输"口径用的是推送线程序列化时刻 `sentAt`（比发布晚几十微秒）。若要精确的"状态机发布 → 客户端"，`MixerSnapshot` 加 `publishedAt: HostTime`（契约改动）。现在的数字已经在 1 ms 内，不急。
6. **Stats 的"唯一一份"在 API 这边靠约定**：`StateFeed.publish(stats:)` 只是个入口，谁采样谁灌（headless 是 StatsWriter 的采样闭包）。App 那边 G3 接线时要保证状态行、jsonl、API 是同一次 `engine.makeStats()` 的结果（三处各调一次会把窗口口径搞乱）。要不要在 Engine 里把"每秒一行 + 多个消费者"做成一个正式的 `StatsPublisher`（W1-B 的包），请裁定。
7. **`Tally` 的 JSON 键是输入编号的字符串**（`[Int: Tally]` 经 JSONEncoder 变成 `{"1": …}`），与 `Stats.per_input` 一致；写进 docs/api.md 了。

## 5. 下一个会话需要知道的坑

1. **G3 接 App 的一行调用**：`let bus = CommandBus(stateMachine:)`；UI 发命令 `try await bus.submit(cmd, source: .ui)`；`let feed = StateFeed(stateMachine:) { engine.clock?.spec }; feed.attach(to: bus); await feed.start()`；`APIServer(bus:feed:configuration:)` 的 `start()` 返回时已监听（`boundPort`）；`HotkeyDispatcher(bus:)` 在 keyDown 里 `KeyCombo(event:)` → `handle`（返回 true 就别再传）；`MIDIController(bus:table:).start()`；状态行采样那一行 `feed.publish(stats:)`。停机顺序：API → 引擎 → feed。
2. **Hummingbird 2 的坑**：(a) `Application.run()` 放进 `withThrowingTaskGroup` 和监听信号赛跑会挂死——`group.cancelAll()` 取消不了在等 `task.value` 的子任务，作用域退出要等它。用 `ServiceGroup.triggerGracefulShutdown()` 停（开着 WS 也 < 1 ms），监听成功靠 `onServerRunning` 回调（端口 0 从 `channel.localAddress?.port` 读）。(b) 默认 logger 打 stdout，级别给 `.warning` 否则 headless 输出被刷屏。(c) 第一次 `swift package resolve` 拉 27 个包用了 6 分 43 秒（GitHub 慢），之后编译只要 36 s；App 的 xcodebuild 第一次也要联网解析。
3. **`URLSessionWebSocketTask.receive()` 不能被取消**：拿它和 `Task.sleep` 赛跑做超时会让任务组永远等它；测试里改成一条常驻接收任务 + 队列轮询（`WSClient`），接收时刻在接收任务里打戳（轮询会多 2–3 ms）。
4. **Python 的 `time.monotonic()` 在这台 macOS 26 上不等于 mach_absolute_time**（差约 41.5 小时 = 睡眠时间，尽管 `get_clock_info` 声称 implementation = mach_absolute_time），客户端要和服务端 host time 比只能 ctypes 调 `mach_absolute_time()`。系统 Python 3.9 没有 websockets 包，脚本自带了 RFC 6455 客户端（约 100 行）。
5. **CoreMIDI**：`MIDIClientCreateWithBlock` 的通知块在创建客户端那条线程的 run loop 上派发，后台线程不跑 run loop 就永远收不到热插拔（探针 1 什么都没收到；探针 2 加了 `RunLoop.run` 就全通）；接收块在 CoreMIDI 自己的线程上，与 run loop 无关。通知顺序：添加 = msgObjectAdded(2) 后跟 msgSetupChanged(1)，销毁 = msgObjectRemoved(3) + (1)。这台机器没有任何真 MIDI 设备，所有 MIDI 测试都走虚拟源；真设备的 SysEx / 14-bit 没验过。
6. **JSONEncoder 省略 nil 键**：`frameprobe frames` 的输出里解不出的帧没有 `inputID` 键（不是 null），第一次评估在 Fade 帧上 KeyError；API 报文我改成显式 encode 可选字段（写 null）。合成源画面里烧的是调色板序号 `(编号 − 1) mod 16`，不是输入编号，evaluate 按节目文件映射。
7. **C1 的测试设计碰撞**：场景脚本每次切完把 PVW 推到下一路，客户端自己的 cut 会把这个节奏打乱，最后 PVW == PGM，cut 在画面上没变化；客户端现在 cut 前先 `setPreview` 到另一路。C1 的相位避开场景切换点 ±0.4 s，否则同一拍两次切换分不清是谁的。
8. **`StateFeed` 的每拍观察者跑在状态机线程上**，只做一次原子 max + `DispatchSemaphore.signal`（系统调用），60 次/s；总线观察者在提交方任务上同步调。都不在实时线程上，但别在里面做重活。
9. **C4 满负载时状态机的 `.queued` 很常见**（12000 条里 538 条）：两个客户端的任务在"拿 sequence"和"进 actor"之间被抢占就会颠倒，状态机把它们排好序再应用，总线用 `receipt(forSequence:)` 取回，100 µs 轮询一次。这是设计内行为，不是丢失。
10. **`check-ownership.sh` 用的分支名**：`w2-control` 是我用 `git branch -f` 打在 HEAD 上的引用，之后再提交要重新 `git branch -f w2-control`（或检查点直接用 `claude/w2-control-command-bus-api-8f81c2`）。
