# W2-C 控制层一期（命令总线、HTTP / WS API、快捷键、MIDI）—— 报告（分支 w2-control）

日期 2026-09-15。机器 Apple M5 Max 128 GB / macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3，电源适配器，室温；同一台机器上另外四个 W2 会话在并行编译（`uptime` 负载 2–3），实跑期间没有游戏。
worktree `.claude/worktrees/w2-control-command-bus-api-8f81c2`，分支 `claude/w2-control-command-bus-api-8f81c2`（桌面端自动起的名），从 `main`（2290b4e）开；
**`w2-control` 这个分支名指向同一个 HEAD**（`git branch -f w2-control`），`make lint BRANCH=w2-control` 和检查点合并都用它。
提交：`git log main..w2-control`。动了 `Packages/SwitcherControl/`、`Tools/switcher-headless/`（`--api` 三个参数 + 接线）、`docs/api.md`（生成物）、`scripts/apitest/`、本报告、`docs/contract-changes/003`；另按用户 2026-09-15 的两条指示动了本会话目录之外的：`docs/OWNERSHIP.md` W2-C 行（见 §4 第 1 条），以及 **提案 003 的落地**——`Packages/SwitcherCore/Sources/SwitcherContracts/{Command,MixerState}.swift`、`Packages/SwitcherCore/Sources/SwitcherEngine/{State/StateMachine.swift,Engine/StatsPublisher.swift,SwitcherEngine.swift}`、`Packages/SwitcherCore/Tests/{SwitcherContractsTests/{CodableTests,StateTests}.swift,SwitcherEngineTests/Proposal003Tests.swift}`、`docs/CONTRACTS.md`（见 §4 第 2–6 条）。

## 1. 做了什么

`Packages/SwitcherControl/`：库 target `SwitcherControl`（18 个文件）+ 可执行 target `switcher-apidoc` + 测试 target（28 个测试，5.9 s）。依赖：SwitcherCore 的 Contracts + Engine（状态机）、Hummingbird 2.26 + hummingbird-websocket 2.7（Apache-2.0）。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 CommandBus | `CommandBus/CommandBus.swift`、`CommandValidator.swift` | 所有来源（`CommandSource` ui / hotkey / midi / api / script）一个入口：结构校验 → 原子分配全局 sequence → 记 issuedAt（host time）→ `StateMachine.submit(IssuedCommand)` → 回执 `CommandReceipt{sequence, appliedTick}` → 观察者。并发提交时早到的高序号由状态机排队（`.queued`），总线从回执历史取回自己的，两个客户端合起来仍是一个全局顺序。结构性非法（引用不存在的输入 / 输出、kind 不符、通道越界、负时长、编号重复、节目文件不合法）在入口拒绝并给理由——reducer 对这些是静默原样返回，API 用户会误以为成功；随时间变的条件（转场进行中再 fade）不预判，仍交给 reducer。`CommandValidator` 拒绝的命令，`testValidator_agreesWithReducer` 证明 reducer 也一定原样返回 |
| 2 HTTP + WS | `API/APIServer.swift`、`StateFeed.swift`、`APIModels.swift`、`APIServerConfiguration.swift`、`APIJSON.swift` | 端口 **8765**（未注册的高位端口、避开常见直播软件的默认端口、好记；`--api-listen` 可改），默认只监听 127.0.0.1，可配 0.0.0.0；token 鉴权默认关（`Authorization: Bearer` 或 WS 的 `?token=`，401 带 JSON）。`GET /api/v1/state` = version / now / timebase / clock / sequence / tick / tickTime / publishedAt / **MixerState 原样** / tally（每路 {program, preview}）/ stats（最近一行）；`POST /api/v1/command` `{"command": …}`（也接受裸 Command）→ `{sequence, appliedTick, applied, issuedAt, appliedTickTime}`（`applied == false` = 状态机按规则忽略了它，提案 003），非法 400 `{"error"}`；**批量** `{"commands": [...]}` 顺序执行、sequence 连续，第 index 条被拒 400 带已生效的回执；`GET /api/v1/commands` 目录；`GET /api/v1/log?limit=` 最近走过总线的命令（来源 / 拍 / 耗时，诊断用）；`GET /api/v1/tally` 给外部 tally 轮询的小应答；`WS /api/v1/events`：hello → 当前快照 → 之后每次变化一条 **整快照 + 版本号**（sequence / tick / tickTime / publishedAt / sentAt / state / tally），每秒一条 stats；连接上也能发命令（`{"id", "command"}` → receipt / error，`{"id", "commands"}` → receipts）。所有应答用同一个 JSONEncoder（键排序、不转义斜杠，和 stats.jsonl 一样），可选字段缺省写 null 不省键 |
| 整快照 vs JSON Patch | 选整快照 | 理由：快照 8 路时约 7.5 KB，本机回环带宽不是问题（C4 满负载 160 条/s ≈ 1.2 MB/s）；整快照幂等、丢一条自愈，客户端不用维护补丁状态机；tally / PGM / PVW 只关心最新值；每拍最多一条（同一拍内多条命令只发最终状态，渲染线程看到的也是每拍一个快照），慢客户端各自 256 条缓冲丢旧的，不拖总线。JSON Patch 省的带宽换来的是客户端复杂度和"漏一条就全错" |
| 状态变化怎么感知 | `StateFeed` | 挂状态机的 `SnapshotObserver`（提案 003 §D1，已落地）：每次 publish 之后在状态机线程一次信号量 signal，推送线程醒来读 `publisher.latest`，对象身份变了才编码一次扇出；250 ms 兜底轮询。（一开始是 TickObserver + 总线观察者 + preparedTick 追赶拼的，落地 003 后删掉了） |
| 3 快捷键 | `Hotkeys/KeyCombo.swift`、`ControlAction.swift`、`HotkeyTable.swift`、`HotkeyDispatcher.swift` | JSON 表存 `~/Library/Application Support/Switcher/hotkeys.json`（节目文件之外）；组合键文本归一化成 `ctrl+alt+shift+cmd+<键>` 一种写法（别名 / 符号 / 大小写 / 顺序都收敛），冲突检测按它比，读表有冲突默认报错并点名；默认表 = 设计方案 §9.4 / W2-B：数字 PVW（0 = 10 号）、Shift 数字 PGM、空格 Cut、回车 Auto（按已选转场，默认 Fade 30 拍）、F 键 FTB 开关。开关型动作（`ControlAction.toggleFTB / toggleOverlay / toggleMute / toggleRecord / toggleStream / toggleAFV`）按最新快照解析成显式命令再投总线。`KeyCombo(event: NSEvent)`：charactersIgnoringModifiers + keyCode 表，Shift+1 仍是 "1" |
| 4 MIDI | `MIDI/MIDIMapTable.swift`、`MIDIMapper.swift`、`MIDIController.swift`、`VirtualMIDISource.swift` | CoreMIDI（`MIDIClientCreateWithBlock` + `MIDIInputPortCreateWithProtocol` MIDI 1.0 协议，UMP 解析）；映射表 JSON（`midi.json`，同一目录）：CC → tbar / inputGain / busGain（0–127 线性映射到 [minDb, maxDb]），**14-bit CC**（`cc14`：控制器 n 收 MSB、n + 32 收 LSB，合成 0–16383，推杆 16384 级；MSB 到了先按粗值动、LSB 到了按细值动，显式映射的 LSB 号仍当普通 CC），Note 按下 → ControlAction；T-bar 推到一端提交并换向（拉回来是下一次转场，真推杆手感）；learn：下一条 CC / Note 交给回调不派发；热插拔：源增删通知自动连接 / 移除；命令经一条 AsyncStream 顺序提交，CC 不乱序。`VirtualMIDISource` 放正式代码（自测 + 将来 App 的软件推杆） |
| 5 Tally | `StateFeed` / `StateResponse.tally` / `SnapshotMessage.tally` | 每条快照和 GET /state 都带 `{"<输入编号>": {"program", "preview"}}`，由 `MixerState.tallies` 推导（全系统只算这一处），W3-D 的外部 tally / Stream Deck 直接用 |
| 6 headless `--api` | `Tools/switcher-headless`（`--api`、`--api-listen host:port`、`--api-token`） | 先于引擎起（客户端能在第 0 拍前连上）；Stats 只有一份：`StatsPublisher`（提案 003 §D2，SwitcherEngine）是唯一的采样线程，`StatsWriter.submit` 和 `StateFeed.publish(stats:)` 都是它的消费者，拿到同一行；停机先停 API 再停引擎，采样停了再关文件，推送源最后停；汇总行打印总线 / 推送计数 |
| docs/api.md | `CommandBus/CommandCatalog.swift`、`API/APIDocument.swift`、`Sources/switcher-apidoc` | `CommandKind` 用穷举 switch 钉住 27 个 case（契约加 case 这里编译就红），每条一句说明 + 参数 + 用真 JSONEncoder 编出来的样例；`swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`；`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 保证仓库里那份不落后 |
| C 系列客户端 | `scripts/apitest/apitest.py`、`run-c-tests.sh`、`README.md` | 只用 Python 3 标准库（自带 RFC 6455 文本帧客户端；时间戳用 ctypes 调 `mach_absolute_time`，和服务端同一个钟）；`run` 记全部快照 / stats 并发 C1 的 cut、C4 的带序号命令；`evaluate` 对着 `frameprobe frames` 的逐帧输出算 C1–C4 出 Markdown；`scenario` 生成每 5 s 切一次（每 60 s 一次 Fade）的场景；`run-c-tests.sh` 一键 |

`swift test --package-path Packages/SwitcherControl` 28/28 绿（6 s）；`swift test --package-path Packages/SwitcherCore` 138/138 绿（含提案 003 的 4 个新测试，约 4 分钟）；`make lint BRANCH=w2-control`：禁词 / 版本号 / Package.swift / 依赖方向 / check-rt-symbols 绿，`check-ownership.sh w2-control` 报的越界文件全是用户指示的两件事（`docs/OWNERSHIP.md` 一行；提案 003 落地改的 SwitcherCore 与 CONTRACTS.md），G3 合并时按提交信息认领即可。`make gen build-app`（xcodebuild，App 链接 SwitcherControl 及其远程依赖）绿；`make test-tools`（两个工具冒烟）绿。
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
| 提案 003（SwitcherEngineTests） | `testP003_receiptApplied_falseWhenReducerIgnoresCommand`、`testP003_snapshotPublishedAt_isSetAtPublishAndMonotonic`、`testP003_snapshotObserver_calledAfterEveryPublish_withTheSameObjectAsLatest`、`testP003_statsPublisher_oneRowPerInterval_fanOutAndLatest` | mute 已是该值 / 转场中再 fade → applied false（回执历史、本地 apply、排队后连带应用的都对）；publishedAt 落在发布前后、单调；观察者每次发布都被调、参数 === latest、在 `switcher.state-machine` 线程、摘掉后不再来、跨多拍一次 prepare 只发布一次；StatsPublisher 50 ms 周期 6–7 行、两个消费者拿到同一行、latest / rows / sampleNow / 重复 start-stop | ✅ |
| 目录 / 文档 | `testCatalog_coversEveryCommandCase_andWireKeyIsCaseName`、`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | 27 个 case、JSON 顶层键 = case 名、样例往返、docs/api.md 与生成一致 | ✅ |
| GET state | `testAPI_getState_returnsStateTallyClockAndStats` | 键名与 Codable 一致、tally 三种、stats 灌一行后 GET 解回来 == 同一行 | ✅ |
| POST command | `testAPI_postCommand_receiptAnd400WithReason` | 200 回执（appliedTickTime = 时钟算的）、裸 Command 也行、400 三种（不存在的输入 / 未知命令 / 坏 JSON）、目录 27 条 | ✅ |
| WS 事件 | `testAPI_wsEvents_helloSnapshotStatsReceiptAndTally` | hello → 快照 → 命令后推送（tally 对调）→ 拍推进的转场进度一拍一条（转场中 PVW 的 tally.program 也 true）→ stats → WS 上发命令得 receipt / error | ✅ |
| 鉴权 | `testAPI_tokenAuth_401WithoutToken` | 无 / 错 token 401，对 200；WS `?token=` 通、无 token 连不上 | ✅ |
| 批量 / 日志 / tally | `testAPI_batchCommands_logAndTally` | 3 条批量 sequence 1 2 3 顺序生效；中途一条非法 → 400 index 1 + 1 条回执、前面生效后面不执行、不占 sequence；空数组 400；`/log?limit=2` 最近两条带来源 / 拍；`/tally` program / preview / 每路；WS 批量 → `receipts` | ✅ |
| C2 进程内 | `testC2_pushLatency_inProcess_p99` | 200 次变化（一半命令、一半拍推进）：传输 p50 0.54 / p99 1.11 ms；状态机发布 → 收到 p50 0.55 / p99 1.13 / max 1.22 ms（提案 003 的 publishedAt 口径；机器在并行编译） | ✅ |
| 慢订阅者 | `testAPI_wsSlowSubscriberDoesNotBlockBus` | 不读 WS 猛发 2000 条：0.34 s 完成，最后收到的是最终状态 | ✅ |
| 快捷键 | 7 个 `testHotkey_*` | 组合键 17 组解析 / 归一化 / 往返、默认表 23 条无冲突、JSON 往返 + 手写表 + 用户文件位置、冲突 2 处点名 + 坏组合键报错、开关型解析、派发（同步 / 异步 / 换表 / 拒绝计数）、NSEvent → KeyCombo 9 组 | ✅ |
| MIDI 映射 | `testMIDI_mapTableJSONRoundTripAndConflicts`、`testMIDI_ccToTbar_flipsDirectionAtEachEnd`、`testMIDI_ccToGains_andNoteToActions`、`testMIDI_cc14_fineTbarAndGain`、`testMIDI_umpParsing` | JSON 往返 / 冲突 / 范围检查；T-bar 0 → 127 提交后换向、127 → 0 再提交；推子线性映射；14-bit：MSB 64 → 8192/16383、LSB 100 → 8292/16383、16383 提交换向、无 MSB 的 LSB 当 MSB = 0、显式映射的 LSB 号优先当普通 CC、MSB 号 0–31 范围检查；Note Off / 力度 0 不触发；UMP 混合消息类型解析 | ✅ |
| MIDI 虚拟端点 | `testMIDI_virtualSource_hotPlug_ccToTbar_noteToCommand_learn` | 起控制器后创建虚拟源 → 自动连上（热插拔）；CC1=64 → tbar 0.504（来源 midi）；CC1=127 提交对调；拉回 64 → 新转场 0.496；到 0 再提交；CC7=127 → 增益 +12 dB；Note 60 → cut，Note Off 无动作；连发 20 个 CC 顺序不乱；learn 捕获 CC9@ch3 不派发；无映射计 ignored；销毁源后列表移除 | ✅（1.3 s） |

## 3. 没做的和原因

1. **MIDI 输出（把 tally / 状态回灌给控制器的灯）**：没做，是 W3-D 的 Stream Deck / 外部 tally 那一路的事。14-bit CC 已补（用户要求功能尽量完整后加的）。
2. **App 接线**：`SwitcherSession.send`（W2-B）换成 `CommandBus.submit(_, source: .ui)`、主窗口 keyDown 接 `HotkeyDispatcher`、设置里起 `APIServer` / `MIDIController`、状态行采样的那一行 Stats 同时 `feed.publish(stats:)`——按落地方案这些是 G3 的胶水，我没碰 `App/`。接口都是一行调用，见 §5 第 1 条。
3. **0.0.0.0 监听只测了配置解析**（`APIServerConfiguration.parseListen`），没有第二台机器做跨机测试；Hummingbird 绑 0.0.0.0 和绑 127.0.0.1 是同一条路径。
4. **JSON Patch** 没做（选了整快照，理由见 §1）。若将来快照大到几十 KB（几十路输入 + 效果链），可在 WS 上加 `?mode=patch` 协商，客户端结构不变。
5. **C 系列的 60 分钟 / 8 小时版本** 没跑：prompt 要的是 10 分钟；脚本 `--minutes` 可改，evaluate 对 36000 帧用了约 1.5 s，长稳没有障碍。
6. **快捷键 / MIDI 的编辑界面**是 W3-E 的（落地方案第 6 条）。

## 4. 对契约的疑问（用户 2026-09-15 已裁定："按照你的想法来，功能越丰富越完善越好"）

1. **OWNERSHIP 越界**：prompt 的"只准动"一行只有 `Packages/SwitcherControl/` 和 headless 的 `--api`，但同一份 prompt 的测试要求"WS 客户端脚本放 `scripts/apitest/`"、"docs/api.md 由 Command 枚举生成"。**用户裁定加进 W2-C 行**，我已改 `docs/OWNERSHIP.md`（加 `scripts/apitest/` `docs/api.md` 两个 token，备注写明来历），单独一个提交 `OWNERSHIP：W2-C 行加 …`。改完 `check-ownership.sh w2-control` 只剩 `docs/OWNERSHIP.md` 本身一个文件越界（它不在任何功能会话的行里）；G3 合并时按提交信息认领。
2. **`IssuedCommand.issuedAt` 的含义**：按"进总线的时刻"（服务端 host time）。→ 提案 003 §C，**已落地**：Command.swift 注释 + CONTRACTS.md §2.6 / §3。
3. **`CommandReceipt` 没有"状态是否真的变了"**：→ 提案 003 §A，**已落地**：`CommandReceipt.applied: Bool`（默认 true；老 JSON 缺键当 true），状态机 `applyNow` 用 `current != before` 填，排队后连带应用的也对；API / WS 回执、`/log`、总线计数 `ignored` 都带。
4. **状态机没有"快照已发布"的观察点**：→ 提案 003 §D1，**已落地**：`StateMachine.SnapshotObserver` + `add/removeSnapshotObserver`，`publish()` 后在状态机线程同步调；`StateFeed` 只挂它（删掉了 TickObserver + 总线观察者 + preparedTick 追赶）。App 主线程分发（W2-B）合并后也可以挂它。
5. **`MixerSnapshot` 没有发布时刻**：→ 提案 003 §B，**已落地**：`publishedAt`（默认构造时刻，状态机发布时打）；`SnapshotMessage` / `GET /state` 带上，apitest 的 C2 多一列"状态机发布 → 客户端"。
6. **Stats 的"唯一一份"靠约定**：→ 提案 003 §D2，**已落地**：`SwitcherEngine.StatsPublisher`（`mach_wait_until` 定时的采样线程，`addConsumer` 扇出，`latest` / `sampleNow`），headless 的 StatsWriter 与 API 都是它的消费者。App 的状态行 G3 接线时也挂上去即可。
7. **`Tally` 的 JSON 键是输入编号的字符串**（`[Int: Tally]` 经 JSONEncoder 变成 `{"1": …}`），与 `Stats.per_input` 一致；写进 docs/api.md 了。不用改。

**落地提案 003 时本会话越界改的文件**（用户 2026-09-15 指示"提案 003 你直接落地吧，改契约和状态机"）：`Packages/SwitcherCore/Sources/SwitcherContracts/Command.swift`、`MixerState.swift`；`Packages/SwitcherCore/Sources/SwitcherEngine/State/StateMachine.swift`、`Engine/StatsPublisher.swift`（新）、`SwitcherEngine.swift`（文件一览）；`Packages/SwitcherCore/Tests/SwitcherContractsTests/CodableTests.swift`、`StateTests.swift`、`SwitcherEngineTests/Proposal003Tests.swift`（新）；`docs/CONTRACTS.md`。都是加字段 / 加类型 / 加钩子，带默认值，其他 W2 分支合并不需要改代码；只有钉回执 JSON 字面量或直接比较 `CommandReceipt` 相等的测试会红（本仓库只有 CodableTests 一处，已改）。

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
11. **批量命令不保证同一拍**：`{"commands": [...]}` 只保证顺序和 sequence 连续；两条命令之间拍可能翻过去（ISO 录制"同一拍发多条"要靠状态机的 `schedule(_:at:)`，那是场景脚本的路径，API 没暴露）。要"同一拍"语义得在状态机加一条"原子批量"入口（W1-B），提案 003 没包含，需要时再提。
12. **SwiftPM 的陈旧构建描述**：在依赖包（SwitcherCore）里新增源文件（StatsPublisher.swift）后，下游包（Tools/switcher-headless）的增量构建重编了 SwitcherEngine 却没把新文件算进去（`cannot find type 'StatsPublisher'`，.o 都没生成）——`.build/arm64-apple-macosx/debug/description.json` 没重算。删掉它（或 `swift package clean`）再 build 就好。App 的 xcodebuild 走自己的 DerivedData，不受影响。
13. **`DispatchSemaphore.wait(timeout:)` 在低 QoS 线程上会被定时器合并拖晚 30 ms 以上**（StatsPublisher 第一版 50 ms 周期量到 80 ms）；要准的周期用 `mach_wait_until`（绝对时刻），停机响应靠每 50 ms 醒一次看标志。1 Hz 的 stats 行实测间隔 0.996–1.006 s。
14. **14-bit CC 的手感**：MSB 到时按粗值先动一次、LSB 到时再动一次，推杆一格会发两条 tbar 命令（都在同一拍内被合并成一个快照，画面没有抖动）；不发 LSB 的设备退化成 7-bit 行为。
