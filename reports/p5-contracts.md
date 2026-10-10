# P5 契约落地四报告（分支 p5-contracts，worktree 分支 claude/p5-contracts-phase4-962ed2，同一提交）

prompt：docs/plan/prompts/99-P5-契约落地四.md。从 G7 快进后的 main `93f50d9` 开。
**这一轮分两段**：用户已批的（023 第一节、024 (b)、025、026、027）直接落地；020 / 021 / 022 / 023 二–五按铁律 1 写成提案、**停下来等用户批**（本报告写到停下来那一刻，批了哪份做哪份再续）。
提交（`git log main..p5-contracts`）：`a924952`（023 §1 + 024）→ `b44344f`（025）→ `b85c830`（027）→ `c5b0e16`（026）→ `8e01d40`（四份提案）→ 报告。
机器：Apple M5 Max / macOS 27.0 / Xcode 27；跑测试时同机另有一个会话（prompt 106，midihost-sync-crash）在跑 App 用例，负载 7–8。

---

## 1. 做了什么

### 已批的五项（落地了哪些文件）

| 提案 | 落地 | 文件 |
|---|---|---|
| **023 第一节**（转场进行中 setPreview / setProgram 拒收；用户 2026-10-01 批） | 只落契约文字：CONTRACTS.md §8 两行、§2.5 TransitionState 一句、`Command.swift` 两处注释；CommandCatalog 两条摘要加"转场进行中被拒（applied = false）"→ docs/api.md 重生成（只差那两行）。reducer 已随 W5-E 合入 main，没动 | `Command.swift`、`CommandCatalog.swift`、`docs/CONTRACTS.md`、`docs/api.md`、`023-小口径收口.md`（状态表） |
| **024 (b)**（用户 2026-10-03 批） | `EffectSlot` 注释与 CONTRACTS.md §2.4 键表加 `compressor`（`thresholdDb` −60…0 默认 −20 / `ratio` 1…20 默认 4 / `kneeDb` 0…24 默认 6 / `attackSeconds` 0.0001…0.2 默认 0.005 / `releaseSeconds` 0.01…3 默认 0.1 / `makeupGainDb` 0…24 默认 0；与 dynamicsProcessor 二选一占同一格）、`peakLimiter.ceilingDb`（−20…0 默认 0）、`parametricEQ.q` 经典 Q、一格 ≤ 16 段 / 每总线 ≤ 3 格；三个苹果单元的范围**不在契约里重复**（= `SwitcherAudio.EffectParameterRanges`，表在 reports/w5-audio-bus-effects.md §1.5）；`BusState.effects` / `InputSettings.effects` 的"占位"字样改成现状。没有新类型、不改 JSON | `Input.swift`、`MixerState.swift`、`docs/CONTRACTS.md`、`Contracts024Tests.swift`、`024-dynamics-ratio.md`（落地记录） |
| **025**（用户 2026-10-10 批） | `RecordSettings.armed`（缺键 true）/ `.ownFormat`（缺键 false）、`StreamSettings.followFirst`（缺键 false）：显式 `init(from:)`、写出写全、`jsonKeys`；旧 extra 键搬迁做成 `OutputSettings.migratingLegacyAppFlags()` / `Show.migratingLegacyAppFlags()`（键名常量 `RecordSettings.legacyArmedExtraKey` 等；有键按原值搬、清键、幂等），**不并进 Show.load**（见 §4 第 1 条）；CONTRACTS.md §2.5 加 RecordSettings / StreamSettings 两行 + 一段；docs/api.md 样例多三个键 | `MixerState.swift`、`Show.swift`、`Samples.swift`、`Contracts025Tests.swift`、`docs/CONTRACTS.md`、`docs/api.md`、`025-…md` |
| **027**（用户 2026-10-10 批） | `OverlayAnimation.defaultFadeSeconds = 0.5`、`OverlayAnimation.defaultFade(for: ProgramFormat)`（fade、round(0.5 s × 帧率) 拍：60 / 59.94 → 30、30 / 29.97 → 15、25 → 13、50 → 25、24 → 12）、`MixerState.newShow(format:outputs:)`；`OverlayAnimation()` / `MixerState()` 的无参默认不动；App `ShowDocuments.emptyShow` 改调工厂（App 胶水 8 行；加上 026 的分组 / 动作名 4 行，App 胶水共 12/50） | `MixerState.swift`、`App/Sources/Show/ShowDocuments.swift`、`Contracts027Tests.swift`、`docs/CONTRACTS.md`、`027-…md` |
| **026**（用户 2026-10-10 批） | `AudioState.monitorSource: Bus = .master`（JSON `monitorSource` = Bus.rawValue，缺键 master，写全；文件里 headphones 按 master 读）；`Command.setMonitorSource(bus:)`（**34 → 35 个 case**）；reducer：master / busA / busB 生效、headphones 原样返回、相同值原样返回；校验器也拒 headphones（HTTP 400）；CommandCatalog（参数 `bus`，面向操作员）→ docs/api.md；CONTRACTS.md §2.5 / §2.6 / §8；35 的三处快照（Samples / CommandCatalogTests / APIServerTests） | `MixerState.swift`、`Command.swift`、`MixerReducer.swift`、`CommandCatalog.swift`、`CommandValidator.swift`、六个测试文件、`docs/CONTRACTS.md`、`docs/api.md`、`026-…md` |

Command 总数：**35**（34 + setMonitorSource）。020 批了再 +3（38）、021 批了 +2（40）、023 四 / 五各 +1。

### 待批的四份提案（docs/contract-changes/）

| 文件 | 要点 | 请用户定的点 |
|---|---|---|
| `020-transition-slots-and-ftb-duration.md` | `TransitionSlot` / `TransitionState.slots`（恰好 4）/ `currentSlot`；`setTransitionSlot`（进行中也收，改当前槽的完成时重拷）、`useTransitionSlot(slot:start:)`（进行中拒）、`setFTBDuration(ticks:)`（渐变中回拨起点不跳变）；旧命令执行后 currentSlot = nil；removeInput 清四槽；搬迁补出厂槽（槽 1 = 原来那组、cut 改 Fade 0.5 s）；loadShow 校验改成先搬迁再 validate；命令 35 → 38 | ① Stinger 槽没选输入时 start:true 照常 / 拒；② 进行中改当前槽：完成时重拷 / 拒；③ FTB 渐变中改时长：回拨 / 拒；④ 三条命令可接受 |
| `021-file-playback-control.md` | `InputSettings.playback{paused, restartOnProgram, seekSeconds?, seekTick?}`（后两个是瞬态）；两条命令 `setPlayback(input:paused:)` / `seekPlayback(input:seconds:)`（从头 = 0；kind != file 拒）；restartOnProgram 由 reducer 在换 PGM 那一拍写定位 0；"设循环"走现有 setInputSource（101 就地改）；组装方按快照变化调 FileInput，不重建 | ① 两条而不是四条；② 要不要 restartOnProgram；③ 循环不加命令 |
| `022-stats-encoder-uptime-disconnects-last-error.md` | `encoder[].uptime_s`（本次运行时长，含重连期）/ `disconnects`（StreamCounters 已有）/ `last_error`（下一次 start 清）；顺带 B1 `attempt`（W5-B §4 第 1 条）、B2 顶层 `video_delay_ms`（prompt 105 交付 4）；StatsSummary 可选字段；测试标准 §7 字段表 | ① 三个字段；② attempt；③ video_delay_ms；④ uptime 口径（含重连期 / 只算在推） |
| `023-小口径收口.md` 二–五 | 二 `container` 标废弃（decodeIfPresent 缺键 .mov、仍写；要不要 `@available` 默认不标）+ 录制来源 PVW / 多画面"照录 PGM 写进口径、不拒"；三 effects 只放音频（只改注释）；四 `InputColor` / `InputConfig.color` + `setInputColor`，名字留 layout（或 Show.categoryNames + 命令，二选一）+ 搬迁函数不并进 Show.load；五 `setInputAudio(input:solo:afv:routing:)` 一条代替三条 | 每节各自批 / 驳；四的 (a)/(b)、二的 (a)/(b)/(c) |

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。

| 用例 | 测什么 | 结果 |
|---|---|---|
| `Contracts024Tests.test024_compressorSlotKeysRoundTripAndMatchDocumentedNames` / `test024_peakLimiterCeilingKeyIsOptional` | 文档里的 id / 键名钉成字面量；ceilingDb 可缺 | ✅ |
| `Contracts025Tests.test025_recordAndStreamFlags_defaultsRoundTripMissingKeysAndWriteAll` | jsonKeys、默认值、往返、缺键默认、写全 | ✅ |
| `Contracts025Tests.test025_legacyScenarioShowsDecodeWithDefaults` | g3 / g4 / m0 节目照读、再写再读不变 | ✅ |
| `Contracts025Tests.test025_migratingLegacyAppFlags_movesExtraKeysIntoFields` | 搬迁规则（有键搬、清键、幂等、非 bool 只清、Show 级入口、Show.load 不搬） | ✅ |
| `Contracts027Tests.testContracts_newShowOverlayDefaultsToHalfSecondFade` | 七种帧率的拍数、newShow 四路 fade、无参默认不变、g4 节目动画原样 | ✅ |
| `Contracts026Tests.test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesReadAsMaster` | jsonKeys、默认 master、往返、缺键、写全、headphones → master、越界报错、g3 / g4 照读 | ✅ |
| `Contracts026Tests.test026_setMonitorSourceCommand_jsonShapeAndCaseCount` | 35 个 case、JSON `{"setMonitorSource":{"bus":1}}`、headphones 可表达、4 报错 | ✅ |
| `ReducerTests.test026_setMonitorSource_rejectsHeadphones_andSameValueUnchanged` + `testW1B_reduce_everyCommand_beforeAfterTable` 三行 | master / busA / busB 生效、headphones 拒、相同值原样、与 monitorMode / monitorPoint 互不影响；35 个 case 每个至少一行 | ✅（ReducerTests 21 / 21） |
| `CommandCatalogTests` ×3（含 `testCatalog_generatedMarkdownMatchesCommittedDocsApiMd`） | 35 个 kind、顶层键 = case 名、docs/api.md 与生成器同步 | ✅ 3 / 3 |
| `CommandBusTests.testValidator_agreesWithReducer`（+ 合法 setMonitorSource(busB)、非法 setMonitorSource(headphones)） | 校验器拒的 reducer 也原样返回 | ✅（CommandBusTests 6 / 6） |
| `APIServerTests`（命令目录 35 条） | `GET /api/v1/commands` 35 | ✅ 7 / 7 |
| 原有用例（`testP1_*` / `testP3_*` / `testP4_*` / 014–019） | 改了字面量的三处：`ContractsP3Tests` 的 AudioState.jsonKeys 与命令数 35、`Samples`（025 / 026 非默认值 + 样例） | ✅ |
| SwitcherContractsTests 全包 | 90 个（跳 1 原有） | ✅ 0 红 |
| SwitcherCore 全包（Contracts + Engine + Render） | 288 个（287 过 + 1 跳原有），0 红 | ✅ |
| SwitcherControl 全包 | 69 个（68 过 + 1 跳 C5 人工），0 红 | ✅ |
| SwitcherInputs / SwitcherAudio 全包 | 109（98 过 + 11 跳原有）/ 128（122 过 + 6 跳原有），0 红 | ✅ |
| SwitcherTestKit / SwitcherOutputs 全包 | 71 / 71；121（118 过 + 3 跳人工 / 无 SDK），0 红 | ✅ |
| 工具冒烟 | switcher-headless 0.1.0、frameprobe 0.1.0 | ✅ |
| App 全量 | 228 个：220 过、6 跳、2 红 → 新命令缺动作名（胶水补 2 行后 ActionPickerTests 4 / 4 过）；`testRecord_5sTwoTracksDurationExact` 计时类负载下偶发（0.22 帧），安静时复跑 1 / 1 过 | ✅（两条复跑后 0 红） |
| `make lint BRANCH=p5-contracts` | 禁词 / 版本 / Package / 依赖方向 / 归属（31 个文件，App 胶水 12/50）/ check-links / check-rt-symbols | ✅ |
| `make gate4-run` | 一次 | 待跑（等批完再跑一次，避免跑两次；同机有别的会话在跑重活） |

---

## 3. 没做的和原因

1. **020 / 021 / 022 / 023 二–五没落地**：铁律 1——先写提案停下来问；批了哪份做哪份（建议顺序 022 → 023 → 021 → 020，先小后大；或按 prompt 的 023 → 022 → 021 → 020）。
2. **025 的 App 侧**（OutputLinkage / 推流页改读写字段、Show.load 后搬一次旧键）：用户裁定归 101；契约这边把搬迁函数写好了，101 只要在 Show.load 后调一次 `show.migratingLegacyAppFlags()` 并把读写切到字段。
3. **026 的引擎侧**（设备客户端按 monitorSource 取总线、X09）归 102；App `MixerModel.listenBus` 改走命令归之后的 App 会话；`ControlAction` 的动作表归 100 或之后的控制会话。
4. **docs/api/README.md 第 9 行"34 条命令"**现在过时（35）：docs/api/ 不在 P5 的目录里，且胶水额度只覆盖 Packages / App，没动；请 G8a 或 103 改一个数字。
5. **`OverlaySettingsModel.defaultFadeSeconds`（App）现在没人读**：删它要多动 App 行，留给 101 / G8 顺手清。
6. 027 的"headless 新建节目路径"：headless 没有通用的新建节目路径，m0 / g3 / g4 / soak 工厂都显式给了每路叠加的动画（场景夹具，改了会动基线），没改。
7. **gate4 没跑**：等用户批完、全部落完再跑一次（prompt 要求"一次"）；且写报告时同机 prompt 106 的会话在跑 App 用例（负载 7–8），现在跑数字不可信（G6 / P3 的经验）。

---

## 4. 对契约的疑问

1. **025 的搬迁为什么不并进 `Show.load`**：并进去的话，025 之前的 App（读写 extra 键）打开节目时旧键被清、字段读不到 → 101 切换之前"取消参与录制"的状态会丢；提案"怎么迁移"一节写的是"App 在 Show.load 后搬一次"，所以做成独立函数、由 101 调。**101 切换完之后建议下一次契约会话把它并进 `migratingLegacyKeys()`**（API loadShow / addOutput 带旧键的也就一致了）。023 第四节的分类搬迁同一做法。
2. **026 校验器也拒 headphones**：决策记录只写了"reducer 拒收（applied = false）"；校验器拒是按 `setOutputEnabled` 对录制 / 推流输出的先例（不随拍变的条件入口就拒、给理由），API 客户端会看到 400 而不是 200 + applied = false。不想要 400 就把校验器那一行去掉（`testValidator_agreesWithReducer` 的非法表同步删）。
3. **026 的 `AudioState.monitorSource` 解码时把 headphones 归一成 master**：不想要这个归一（照存、让引擎去兜）也行，一行。
4. **024 的 `compressor` 键范围与默认值是 P5 定的**（提案只说"写进键表"）：−60…0 / 1…20 / 0…24 / 0.0001…0.2 / 0.01…3 / 0…24，默认 −20 / 4 / 6 / 0.005 / 0.1 / 0。102 做 C 实现时觉得不合适请改提案 024 的落地记录与键表（同一处）。
5. **020 / 021 / 022 / 023 各自"请用户定的点"**见提案末尾。
6. `CommandReceipt` 带被拒原因（W5-E §4 第 2 条）：只记不提；`attempt` 与 `video_delay_ms` 随 022 一并问。

---

## 5. 下一个会话需要知道的坑

1. **`make lint` 要显式给分支名**（同 P3 / P4）：`git branch -f p5-contracts HEAD && make lint BRANCH=p5-contracts`。
2. **`swift test --filter` 的 `|` 不是交替**：`--filter 'A|B'` 只跑到 A（或一个都不跑并报 "No matching test cases"），`\|` 也不行；一个 filter 一个类（`SwitcherControlTests.CommandCatalogTests`），多个类就循环跑。
3. **加 Command case 要改的地方（026 走了一遍）**：`Command.swift`、`Samples.swift`（样例 + caseName + commandCaseCount）、`ContractsP3Tests`（34 → 35 两处）、`ReducerTests`（表 + allCaseNames + caseName）、`MixerReducer`、`CommandCatalog`（CommandKind + init(of:) + fields + operatorFacing + entries）、`CommandValidator`、`CommandCatalogTests` / `APIServerTests` 的计数、`CommandBusTests` 的合法 / 非法表、CONTRACTS.md §2.6 / §8、docs/api.md 重生成（`swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`）、docs/api/README.md 的"N 条命令"（不在契约目录里）。App 的 `ActionCatalog.group(of: CommandKind)` **也是穷举 switch**（本会话第一次 `make test-app` 就红在这里，补一行 App 胶水），`operatorFacing` 与 `fields(for:)` 同理；找所有穷举点要 `grep -rn '\.setMonitorMode'`（任意一个现有 case 名，**不要**带 `case ` 前缀——多 case 一行的 `case .a, .b, .setMonitorMode:` 匹配不到）。
4. **加字段要改的地方**：显式 `init(from:)` + `jsonKeys` + 对应 `testP*_jsonKeys` 字面量 + `Samples` 填非默认值 + docs/api.md（样例里会多出键）。`RecordSettings` / `StreamSettings` 现在有显式 `init(from:)`，再加字段别忘了。
5. **`MixerState.newShow(format:)` 是新节目的入口**，`MixerState()` / `MixerState(format:)` 仍是裸状态（叠加 cut 0 拍）；要"新节目默认值"的地方（App emptyShow、以后 API 的"新建节目"）调前者。020 批了之后 newShow 还要按帧率重算四个转场槽。
6. 同机别的会话在跑 App 用例 / gate4 时，计时类用例与 gate4 的数字不可信（P3 §5 第 9 条、G6 的经验）；开跑前 `ps -axo comm,%cpu` 看一眼（`pgrep -f` 会匹配到自己）。
7. Contracts 包的测试里 `Fixtures/` 目录与 `repoRoot`（`#filePath` 上五级）是读 `scenarios/*.json` 的写法，025 / 026 / 027 的老文件用例都这么读。

---

## 6. 运行记录

| 什么 | 命令 | 提交 / 时间 | 结果 |
|---|---|---|---|
| Contracts 全包（每落一项跑一次） | `swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests` | a924952 … c5b0e16，20:5x–21:2x | 84 → 87 → 88 → 90 个，0 红（跳 1 原有） |
| Reducer | `--filter ReducerTests` | c5b0e16 | 21 / 21 |
| Control 三类 | `--filter SwitcherControlTests.{CommandCatalogTests,CommandBusTests,APIServerTests}` 各一次 | c5b0e16 | 3 / 6 / 7 全过 |
| lint | `git branch -f p5-contracts HEAD && make lint BRANCH=p5-contracts` | 8e01d40，21:30 | 全绿（28 个文件、App 胶水 8/50） |
| SwitcherCore 全包 | `caffeinate -i swift test --package-path Packages/SwitcherCore` | 8e01d40，21:31–21:39 | 三个 xctest（Render / Engine / Contracts）全过：288 个 = 287 过 + 1 跳（原有），0 红（参考图用例按 G6 改 PSNR 后在 27 上也绿） |
| SwitcherControl 全包 | `caffeinate -i swift test --package-path Packages/SwitcherControl` | 8e01d40，21:31 | 三个 xctest（VMixCompat / Tally / SwitcherControl）全过：69 个 = 68 过 + 1 跳（C5 人工），0 红 |
| SwitcherInputs 全包 | `caffeinate -i swift test --package-path Packages/SwitcherInputs` | 8e01d40，21:3x | 109 个 = 98 过 + 11 跳（原有 BLOCKED-硬件 / SDK），0 红 |
| SwitcherAudio 全包 | 同上 | 8e01d40，21:4x | 128 个 = 122 过 + 6 跳（原有 BLOCKED-硬件 / 人工），0 红 |
| SwitcherTestKit 全包 | 同上 | 8e01d40，21:4x–22:0x | 71 / 71 过（含唤醒延迟那条计时用例，同机当时还有别的会话在跑 App 用例） |
| SwitcherOutputs 全包 | 同上 | 8e01d40，21:5x–22:22 | 六个 xctest 全过：121 个 = 118 过 + 3 跳（NDI 人工 / 无 SDK、外部显示人工），0 红；MediaMTX E2/E3/E7/E8/E9 与 ISO A4 都跑了 |

**六包汇总（8e01d40 / c87ae1f）**：786 个用例 = 764 过 + 22 跳（全是原有 BLOCKED / 人工项）+ **0 红**；工具冒烟 2 / 2；App 228 个（220 过、6 跳、2 红——一条补胶水后过、一条安静时复跑过）；lint 全绿。
| 工具冒烟 | `caffeinate -i make test-tools` | c87ae1f，21:4x–21:50 | switcher-headless 0.1.0、frameprobe 0.1.0（两个工具都编过：headless 构造 AudioState / RecordSettings / StreamSettings 的地方不用改） |
| App 第一轮 | `make gen && make test-app` | 8e01d40，21:40 | **编译红**：`App/Sources/Settings/ActionCatalog.swift:121` 穷举 `CommandKind` 的 switch 缺 `.setMonitorSource`（App 胶水 +1 行） |
| App 第二轮 | `make test-app` → `xcrun xcresulttool get test-results summary --path .build/DerivedData/Logs/Test/Test-Switcher-2026.10.10_21-41-40-+0800.xcresult` | 21:41–21:47（同机 prompt 106 的 App 用例也在跑，本机还在跑四包串行） | 228 个：220 过、6 跳、**2 红**——`ActionPickerTests.testUI_actionPickerListsOnlyOperatorCommandsByDefault`（新命令缺 `actionPicker.command.setMonitorSource` 的动作名，App 胶水 +2 行 strings）；`RecordingTests.testRecord_5sTwoTracksDurationExact`（起止拍差 318 vs 316.78，超 1 帧 0.22 帧：计时类、与契约无关，负载下偶发，待安静时单独复跑） |
| App ActionPickerTests 复跑 | `xcodebuild … -only-testing:SwitcherTests/ActionPickerTests` | c87ae1f，21:48 | 4 / 4 过 |
| App RecordingTests 复跑 | `xcodebuild … -only-testing:SwitcherTests/RecordingTests/testRecord_5sTwoTracksDurationExact` | c87ae1f，22:10（负载 2.2，只剩本会话的 Outputs 在跑） | 1 / 1 过——第二轮那条红是负载偶发 |
