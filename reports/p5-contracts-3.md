# P5-3 报告：契约落地六——提案 026 允许 headphones、029 没选输入的 Stinger 槽拒收（prompt 110，分支 `p5-contracts-3`，2026-10-12）

工作树分支 `claude/p5-contracts-3-proposals-faaa69` = 本地别名 `p5-contracts-3`（lint 前 `git branch -f p5-contracts-3 HEAD`），从 G8b 合入后的 main 22ff4d9 开。
不 push、不 merge：做完交给 G9（prompt 114）合进 main。W5-O（prompt 112）的监听菜单与 Stinger 提示两项可以叠在本分支头上开（lint 加 `--base p5-contracts-3`）。

## 1. 做了什么

用户 2026-10-12 的两条裁定（reports/G8.md §7.1 末）落成契约：026 允许 `monitorSource = headphones`、029 没选输入的 Stinger 槽拒收。两份都先写红用例（用例名带提案号）、看着红了再实现。
**不加字段、不加命令**（仍 42 个 case），JSON 形态不变；App 胶水 0 行（没有新 case，没有穷举点要补；提示文案归 W5-O）。

| 提案 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **026** 允许 headphones（= 听耳机总线自己） | 契约：`AudioState.monitorSource` 四个值都合法，`init(from:)` 按字面读（P5 的 headphones → master 兜底去掉，App 从没写过这个值）、注释改口径；reducer 不再原样返回 headphones（相同值仍 applied = false）；校验器不再 400（并进 `setMonitorMode` 那一行）；CommandCatalog bus 写 0–3（3 = 耳机总线自己）、摘要去掉"无效被拒" → docs/api.md 重生成；**Integration** `syncSnapshotExtras` 把四个值原样交给混音器（`mixer.setMonitorSource(ms)`，2 行，≤ 10 行的额度内）。混音器出口选路 `hp_own = solo_active ‖ monitor_source ≥ HEADPHONES` 本来就是这个口径：独听仍优先，四个值一样 | 07a2df4 | MixerState.swift、Command.swift、MixerReducer.swift、CommandValidator.swift、CommandCatalog.swift、AudioEngine.swift、docs/api.md；Contracts026Tests、ReducerTests、CommandBusTests、CommandCatalogTests、新 IntegrationTests/MonitorSourceHeadphonesTests.swift |
| **029** 没选输入的 Stinger 槽拒收 | 契约加计算属性 `TransitionSlot.isStingerWithoutInput`（type = stinger 且 stinger.input = nil，不进 JSON）——reducer、校验器（以后 W5-O 的提示）共用一条判定；reducer：`useTransitionSlot(slot, start: true)` 遇到这种槽原样返回（不选中、不开始），`autoTransition` 遇到**要执行的当前那组**是这种原样返回，`start: false` / cut / fade / tbar 照旧；校验器同口径 400："转场 n 是 Stinger、还没选输入"（autoTransition 时当前那组不对应槽写"当前转场是 Stinger、还没选输入"），autoTransition 在转场进行中校验器不判（交给 reducer）；`Command` 三处注释（autoTransition / useTransitionSlot / tbar）、CommandCatalog 三条摘要 → docs/api.md 重生成 | 10cb844 | MixerState.swift、Command.swift、MixerReducer.swift、CommandValidator.swift、CommandCatalog.swift、docs/api.md；Contracts020Tests、ReducerTests、CommandBusTests、CommandCatalogTests |
| T-bar 核对（029 第 2 条要求） | reducer 对 `tbar` 不看类型：推一个没选输入的 Stinger 当前那组照收（progress = 推杆位置、source = tbar，到 1 提交、拉回 0 取消）；渲染器 `TransitionRenderer.stingerShowsNewUnder`：round(progress × durationTicks) ≥ max(cutAtTick, 1) 时把底整个换成 PVW、不叠任何东西——推过换底拍对应的那一格画面就整个换成新画面、拉回去又换回；cutAtTick ≥ durationTicks 时推的过程中不换、到 1 提交才换；durationTicks = 0 一推就换。写进 CONTRACTS.md §2.5 转场槽一段与 §8 tbar 行、`Command.tbar` 注释、目录 tbar 摘要；reducer 那半钉在 `test029_autoTransition_…_tbarUnaffected` | 10cb844 / 588f059 | — |
| 文字 | CONTRACTS.md：标题行、变更记录、§2.5（AudioState / TransitionState / TransitionSlot 三行、转场槽一段改一条加一条）、§2.6（Command 行注明 P5-3 不加 case）、§8（autoTransition / tbar / useTransitionSlot / setMonitorSource 四行）；两份提案写状态、提交号、落地记录（029 与正文不同的一处、改回办法）；G8b 误写成新文件的 026 裁定段并回原提案 `026-monitor-source.md`（误写的那份留着、开头一行指回） | 588f059、9af1bf0 | docs/CONTRACTS.md、docs/contract-changes/026-monitor-source.md / 026-monitor-source-in-state.md / 029-…md |

与提案正文不同的一处（写进 029 落地记录、§4 第 1 条请用户看）：**029 的 `autoTransition` 按"要执行的当前那组"判，不只看 currentSlot**。当前槽是这种槽时两者一样；另外 currentSlot = nil、当前那组是 `setTransition(.stinger)` / `setTransitionParams` 直接给的没选输入的 Stinger 时也拒。
只看 currentSlot 的话结果取决于凑不凑巧：`setTransition(stinger, 60)` 在 60 fps 下与出厂槽 4 完全相同（currentSlot 自动对号成 4）→ 拒；`setTransition(stinger, 45)` → 照常一次延迟硬切——正是提案说的"从这条路绕过去"。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。阈值一个没动。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `Contracts026Tests.test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesRoundTrip`（原 `…HeadphonesReadAsMaster`，改名） | 缺键 master、busB 往返、headphones（3）按字面读 / 写 / 节目文件往返、认不出的值（9）报错、g3 / g4 节目照读 | 3 处红（读成 master） | ✅ |
| `Contracts026Tests.test026_setMonitorSourceCommand_jsonShapeAndCaseCount` | wire 形态不变、headphones 合法、命令数 42 | — | ✅ |
| `ReducerTests.test026_setMonitorSource_acceptsAllFourBuses_andSameValueUnchanged`（原 `…rejectsHeadphones…`，改名） | 四条都生效、busB → headphones → master、相同值原样、与监听方式 / 监听点互不影响 | 2 处红 | ✅ |
| `CommandBusTests.testValidator_agreesWithReducer`（026 部分） | headphones 挪进合法 | 1 处红（400） | ✅ |
| `CommandCatalogTests.testCatalog_026_monitorSourceAllFourBuses`（新） | bus 写 0–3、不写"无效"、命令数 42 | 1 处红 | ✅ |
| `MonitorSourceHeadphonesTests.test026_monitorSourceHeadphones_exitIsHeadphonesBus_soloStillWins`（新，Integration） | 1 → Master、2 → A + 耳机、3 → B + 耳机，监听点设延迟线后：状态 headphones（启动推送）与命令改回 headphones 两种情况**耳机出口逐样本 = Bus A + Bus B（= 耳机总线）**、没有只走 Master 的 1 kHz（< −80 dB）、1.5 kHz / 750 Hz 在（> −30 dB）；改 master → 逐样本 = Master；**独听 2 → 逐样本 = Bus A**、750 Hz < −80 dB；关独听回到耳机总线；实时违规 0 | 9 处红（耳机出口仍是 Master、命令被拒） | ✅ |
| `InputEffectsIntegrationTests.testMonitor_monitorSourceFromState_andBorrowMasterWhileSolo`（W1-D3 原有） | master / busA 选路、借 Master | — | ✅（没动它） |
| `Contracts020Tests.test029_isStingerWithoutInput_definition_factorySlot4AndCurrentGroup`（新） | 判定：出厂槽 4 是、带输入的 Stinger / 别的效果不是、时长 / 换底拍无关；当前那组（选中槽 4、setTransition 直接给的）同一条判定 | 加判定前编译不过 | ✅ |
| `Contracts020Tests.test029_noNewFieldsOrCommands_wireShapeUnchanged`（新） | 判定不进 JSON（槽 / TransitionState 键不变）、useTransitionSlot / autoTransition 的 wire 形态不变、命令数 42 | 同上 | ✅ |
| `ReducerTests.test029_useTransitionSlot_stingerWithoutInput_startRefused_selectAllowed`（新） | start: true 原样（不选中、不开始）、已是当前槽也拒、改成 Stinger 的槽 2 也拒（看配置不看槽号）、start: false 照常选中、选了输入照常开始并走完对调、removeInput 清掉后又拒；状态机回执 applied = false、当前槽仍 1 | 7 处红 | ✅ |
| `ReducerTests.test029_autoTransition_currentStingerWithoutInput_refused_tbarUnaffected`（新） | 当前槽是槽 4 拒、setTransition 直接给的（currentSlot = nil）拒、选了输入照常开始；fade / cut 照常（cut 完成按当前槽重拷仍是槽 4）；T-bar 推到一半照收、到 1 提交、拉回 0 取消；状态机回执 applied = false | 4 处红 | ✅ |
| `ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable` | 原"Stinger 槽没选输入照常开始"改成拒；新加 5 行（只选中照常、选了输入照常开始、autoTransition 两种当前那组拒、带输入的照常）；026 那行改成生效 | 026 1 处、029 3 处红 | ✅（42 个 case 都覆盖） |
| `ReducerTests` V6 / V7 三条（`testV6_setPreviewRejectedDuringTransition` / `testV6_setProgramRejectedDuringTransition` / `testV7_autoTransition_wipeZoomStinger_sameProgressRule`） | Wipe / Zoom / Stinger 共用的 auto 转场规则；原来拿没选输入的 Stinger 跑（baseState 的 stinger 没设，与测的东西无关），改成先经 setTransitionParams 给 Stinger 选一路（`stingerReadyState()`），断言没动 | — | ✅ |
| `CommandBusTests.testValidator_agreesWithReducer`（029 部分） | 槽 4 start: true 进非法（两边都拒）、start: false 进合法；autoTransition 在"当前槽 = 槽 4"与"setTransition 直接给的"两种状态下两边都拒、文案分别带槽号 / "当前转场"；同状态下执行别的槽 / T-bar / fade 放行；选了输入放行且 reducer 真开始；T-bar 推到一半时校验器不判、reducer 忽略 | 6 处红 | ✅ |
| `CommandBusTests.testBus_rejectsStructurallyInvalidCommandsWithReason` | 真总线上 `useTransitionSlot(4, start: true)` → CommandRejection、文案"转场 4 是 Stinger、还没选输入"、不占 sequence、状态不变 | 4 处红 | ✅ |
| `CommandCatalogTests.testCatalog_029_stingerWithoutInputRefusalDocumented`（新） | useTransitionSlot / autoTransition 摘要写拒收与 400、去掉"照常开始"；tbar 摘要写明不管；字段不变 | 4 处红 | ✅ |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | docs/api.md 与生成器同步（两次重生成） | — | ✅ |
| 六包全量 / 工具冒烟 / App 全量 / lint | 见 §6 | | 六包 868 用例 = 833 过 + 33 跳 + 2 环境红（复跑都过；33 跳里 10 条是新 worktree 缺 release frameprobe，补跑全过 → 有效 23 跳，= G8b）；工具 2 / 2；App 244 = 239 过 + 4 跳 + 1 撞端口红（复跑过）；lint 全绿 |

## 3. 没做的和原因

1. **030 效果链延迟进 Stats**：用户没定（prompt 写明不做）。
2. **App 的监听菜单**（"耳机总线 / Master / Bus A / Bus B"四项都发 `setMonitorSource`、`listenBus` 读快照、`listenToOtherBusSupported` 翻 true、`AudioSettingsRevampTests.testPanels_masterListenAndLoudnessDetails` 跟改）与**控制层 / 兼容层 / Stream Deck 的 029 提示**（`ControlAction` 被拒时一条 feedback、兼容层 `Transition n` 对这种槽回 409 NotConfigured、Stream Deck 收到 400 时 showAlert）：归 W5-O（prompt 112）。现在这几个入口按到没选输入的 Stinger 槽，命令总线回 400（`CommandRejection`，HotkeyDispatcher 记 `rejected`），画面不动，但没有提示。
3. **几处不归本会话、合入后会过时的文字**（给 G9 / 别的会话）：
   - `Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/ControlAction.swift:10` 注释"Stinger 槽没选输入照常执行"（Hotkeys 归 W5-O）；
   - `Packages/SwitcherAudio/Sources/Integration/AudioEngineStatus.swift:142` 注释"master / busA / busB"（本会话只许动 AudioEngine.swift 的那一处）；
   - `docs/KNOWN_ISSUES.md:37` 的 S3"快捷键 / MIDI / 兼容层 Transition4 / Stream Deck 对没选输入的 Stinger 槽照常执行"——契约半已修，提示半等 W5-O；`:34` 监听菜单那条等 W5-O；
   - **L3 清单 `docs/checklists/G8.md:67`**写着"⌥4、兼容层 Transition4、Stream Deck 照常执行"——那是 main（029 之前）的行为；G9 合入 029 之后这三处变成"不执行（400）"，用户若在合入后的树上过清单，这一行的预期要改；`:78` 监听菜单那行等 W5-O；
   - `docs/user/概念.md:165`（及英文版）"监听菜单：这一版耳机里只能听耳机总线"：等 W5-O 接完菜单由 W4-C3（109）改；手册里没有写"没选输入的 Stinger 照常执行"的地方，不用改。
4. **gate4 / perf 没跑**：本会话只改了 reducer 两条拒收与一个音频选路入口，g4 / soak 场景的 Stinger 都有 9 号输入（`G4Factory.stingerInput`），monitorSource 不进场景；放 G9 一次跑。

## 4. 对契约的疑问

1. **029 的 `autoTransition` 按"要执行的当前那组"判**（§1 末、029 落地记录）：比正文"当前槽是这种槽"多拒一种情况——API 直接 `setTransition(.stinger)` + `autoTransition` 又没设输入（老用法，以前是延迟硬切，现在 400"当前转场是 Stinger、还没选输入"）。兼容层 `Stinger1` 本来就对这种情况回 NotConfigured，g4 / soak 场景都带输入，不受影响。要按字面只看 currentSlot：reducer / 校验器各一行，覆盖表"当前那组（不对应槽）"那行与 CommandBusTests 的 `legacyStinger` 那组改成放行。建议维持。
2. **020 留下的一个缺口（本会话没改，探针核实过）**：T-bar 推到一半时 `setTransitionSlot` 改了当前槽（进行中只改槽，"完成那一拍重拷"），之后**拉回 0 取消**——取消不是完成，当前那组不重拷：currentSlot 仍是 n、当前那组还是改之前的，下一次回车执行的是**旧配置**（探针：槽 1 改成 Zoom 12 后拉回 0，回车执行 Fade 30），那次完成后才重拷。029 按"要执行的当前那组"判，在这条路上不会误拒 / 漏拒；但旧配置多执行一次本身像个 bug。修法一行：reducer 的 `tbar` 在 progress 回到 0 时按 currentSlot 重拷（与 completeTransition 同一句，幂等）。改的是 020 的口径（"完成那一拍重拷"→"完成或取消那一拍"），请用户定要不要、归哪个契约会话。
3. **T-bar 推没选输入的 Stinger**（029 不管 T-bar，§1 第 3 行的核对结果）：推过换底拍那一格就是一次硬切（不叠东西）。界面上 T-bar 行没有单独拦（X18 只拦"执行"三处）；要不要在选中这种槽后把 T-bar 灰掉 / 提示，是 App 的事（W5-O 或之后），契约这边不用动。
4. 顺带：026 的 headphones 在独听时与 master / busA / busB 同口径（独听优先），这是混音器原有的行为、用户裁定原文也这么写；没有别的疑问。

## 5. 下一个会话需要知道的坑

1. **W5-O 叠在本分支上开的话**：lint 加 `--base p5-contracts-3`；本分支 App 胶水 0 行，W5-O 的 App 额度不受影响。控制层提示用契约的 `TransitionSlot.isStingerWithoutInput`（App 里的 `SlotText.isUnsetStinger` 是同一条判定），别再写第三份。
2. **`autoTransition` 现在会被校验器 400**（以前只会 applied = false）：`HotkeyDispatcher` / MIDI / 兼容层 / Stream Deck 发回车类命令时要处理 `CommandRejection`（现在是记 `rejected`、没有提示）。兼容层 `Transition n` 收到总线拒绝时回什么，W5-O 定成 409 NotConfigured。
   **两条命令连发的会"一半生效"**：`ControlAction.previewAndTransition`（= `setPreview(n)` + `autoTransition`）、App 输入条 / 格子"转场"那种先 setPreview 再 autoTransition 的，当前那组是没选输入的 Stinger 时 PVW 照换、转场 400——W5-O 做提示时可以先用 `state.transition.currentGroup.isStingerWithoutInput` 判、整条不发（与兼容层 `Cut Input=` 在转场中整条不发同一个思路）。
3. **`swift test --filter` 写 `Target.Class` 或 `Target.Class/method`**（P5 / P5-2 §5 第 2 条仍成立）。本会话的定向命令都在 §6。
4. **Integration 用例逐样本比较**：耳机总线默认取延迟线**前**的信号（低延迟监听），与 Bus A / B（延迟线后）不在同一时刻，要逐样本比得把 `AudioEngineConfiguration.monitorPoint` 设成 `.postDelayLine`；数组比较别用 `XCTAssertEqual`（失败时把几万个样本全打出来），用 `MonitorSourceHeadphonesTests.sampleDiff`；单频点 DFT 旁证要窗口内各频率与差频都是整数个周期（本用例 96 块 = 24 576 帧配 1 k / 1.5 k / 750 Hz）。
5. **G8b 的 026 裁定段写成了新文件** `026-monitor-source-in-state.md`：已并回 `026-monitor-source.md`；以后追加提案段落先 `ls docs/contract-changes/ | grep ^NNN` 找原文件。
6. **G9 合入后 L3 清单 G8.md 第 67 行的预期变了**（§3 第 3 条）：⌥4 / Transition4 / Stream Deck 对没选输入的 Stinger 槽从"照常执行"变成"不执行"；提示要等 W5-O。
7. **给 G9 判 L4 能不能沿用 2026-10-12 的 8 小时**（prompt 114 第 4 条）：本分支没动引擎与音频热路径——SwitcherEngine 只改了 reducer 两条拒收（状态机线程的纯函数）；SwitcherAudio 只改了 Integration `syncSnapshotExtras` 的 2 行（控制线程 / start，把 monitorSource 原样交给混音器的命令队列），混音器 C 代码（`CSwitcherAudioRT`）一行没动，`check-rt-symbols` 过；SwitcherRender、Inputs、Outputs 没动。soak 场景 monitorSource 恒 master、Stinger 都带 9 号输入，跑出来的路径与 93bb783 相同。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0）。同机并行：109 / 111 / 112 / 113 四个会话（113 在自己的 worktree 跑 TestKit），`mediaanalysisd` 常驻一核，负载 3–9（编 App 的那一分钟到 16）。

| 项 | 结果 |
|---|---|
| 026 红：`swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests.Contracts026Tests` / `--filter SwitcherEngineTests.ReducerTests`；Control `--filter SwitcherControlTests.CommandBusTests` / `CommandCatalogTests`；Audio `--filter IntegrationTests.MonitorSourceHeadphonesTests`（10:4x） | 3 / 3 / 1 / 3 / 9 处红（Catalog 那时 026 / 029 合在一条里：026 那处 1 + 029 两处，随后拆成 `testCatalog_026_…` / `testCatalog_029_…` 两条，让 026 单独成提交；第一版集成用例用 `XCTAssertEqual` 比数组，失败时打出几十万字，改成 `sampleDiff`） |
| 026 绿：同上 + Contracts 整个 target、W1-D3 的 `InputEffectsIntegrationTests/testMonitor_monitorSourceFromState_andBorrowMasterWhileSolo` | Contracts 106（1 跳）/ Reducer 28 / CommandBus 6 / Catalog 4 / 新集成 1 / W1-D3 监听 1，0 红 → 提交 07a2df4 |
| 029 红（先只加契约判定 `isStingerWithoutInput`，不改行为）：`Contracts020Tests` / `ReducerTests` / `CommandBusTests` / `CommandCatalogTests` | 8 / 8 过（判定本身）；Reducer 30 条 14 处红；CommandBus 10 处红；Catalog 4 处红 |
| 029 绿：Core `--filter SwitcherContractsTests` / `--filter SwitcherEngineTests`；Control 全包 | Contracts 108（1 跳）/ Engine 117 / Control 79（1 跳），0 红 → 提交 10cb844 |
| `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`（两次：026 后、029 后） | 4 行 + 6 行变化；`#### ` 命令标题仍 42 个 |
| 探针 scratchpad/probe-tbar-cancel（20 行可执行包，路径依赖本分支 SwitcherCore） | 证实 §4 第 2 条：T-bar 推到 0.4 改槽 1 = Zoom 12、拉回 0 → currentSlot 1、当前那组仍 Fade 30、回车执行 Fade 30；同一路径把槽 1 改成没选输入的 Stinger，回车照常执行 Fade（029 按要执行的那组判，不误拒） |
| `git branch -f p5-contracts-3 HEAD && make lint BRANCH=p5-contracts-3`（9af1bf0；报告提交后再跑一遍） | 两遍都全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 17 个文件（第二遍加上本报告 18 个）都在范围内 / check-help / check-links 189 个 Markdown / check-rt-symbols |
| 六包 `swift test`（串行 10:56–11:51，同机 113 跑 TestKit、111 跑 Outputs、112 跑 App，负载 3–9） | **868 用例**：Core 326（Render 101 **1 红**、Engine 117、Contracts 108 / 1 跳）、Inputs 110（11 跳，NDI **1 红**）、Audio 160（7 跳）、Outputs 122（13 跳）、Control 79（1 跳）、TestKit 71——0 红的四个包 + 两条与本分支无关的环境类红（下两行）；= G8b 的 861 + 本会话新加的 7 条 |
| 红 1：`SwitcherRenderTests.DisplayDecouplingTests/testDisplay_maxFrameRateCapsThumbnailBlits`（缩略图 2 s 内 blit 0 次，要 > 10） | 显示类（要窗口在屏上、display link 回调才 blit）；跑的时候同机四个会话都在跑（11:00 前后还看到一个别的会话刚起就退的 PlusMix），具体是什么盖住了窗口没查到。本分支没动 SwitcherRender。单独复跑：12:19 机器安静时 `--filter SwitcherRenderTests.DisplayDecouplingTests` 2 / 2 过（缩略图 2 s 内 display link 回调 30 次、blit 30 次，在 10–34 之间）——环境红 |
| 红 2：`NDITests.NDILoopbackTests/testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned`（最大块间隔 27.43 ms > 26.667 ms） | 本机 NDI 回环的计时余量，负载 7–9 时超了 0.77 ms。本分支没动 SwitcherInputs。单独复跑：12:20 `--filter NDITests.NDILoopbackTests` 10 条（1 跳）0 红，这条 4.5 s 过——环境红 |
| 跳过数 33（G8b 23）：多出来的 10 条 = `MediaMTXTests` ×6、`StreamAuthMediaMTXTests` ×3、`ISOAlignmentTests.testA4_…` ×1，原因"BLOCKED-工具：没有编好的 release frameprobe"（新 worktree 没编过） | `swift build -c release --package-path Tools/frameprobe` 后等 111 的 Outputs 跑完（推流用例抢 MediaMTX 端口）单独补跑：12:20–12:34 `--filter StreamingTests.MediaMTXTests` 8 / 8、`StreamingTests.StreamAuthMediaMTXTests` 4 / 4、`ISOTests.ISOAlignmentTests` 1 / 1，原来跳过的 10 条全过；**有效跳过数 23，与 G8b 相同** |
| `make test-tools` | switcher-headless 0.1.0、frameprobe 0.1.0 |
| `make gen && make test-app` | `make gen`、`xcodebuild build-for-testing`（不加 -quiet，2102 个编译步骤，TEST BUILD SUCCEEDED）、`make test-app XCB_FLAGS=`（11:56–12:02）：**244 = 239 过 + 4 跳 + 1 红**（`xcrun xcresulttool get test-results summary --path .build/DerivedData/Logs/Test/Test-Switcher-2026.10.12_11-56-04-+0800.xcresult`）。红 = `BottomBarSplitTests.testUI_streamMenuListsDestinationsWithState`（"主平台在推"等不到、停在"连接中（第 6 次）"）：这条用例的 MediaMTX 用 `apiPort: 29997`，同一时刻 111 在跑的 Outputs `MediaMTXTests` 起三个实例用 `apiPort: 29997 + i`——**两个会话抢同一个 API 端口**，App 这边的 MediaMTX 起不来。12:18 机器安静时 `xcodebuild test-without-building -only-testing:SwitcherTests/BottomBarSplitTests` 7 = 6 过 + 1 跳（系统键盘导航那条 BLOCKED）0 红，这条 6.5 s 过。App 没有一行改动，本分支只换了契约口径；App 全量只跑了一轮 + 红的那个类单独复跑 |

提交：07a2df4（026）→ 10cb844（029）→ 588f059（CONTRACTS.md）→ 9af1bf0（提案落地记录）→ 本报告。
