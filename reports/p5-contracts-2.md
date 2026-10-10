# P5-2 报告：契约落地五——提案 020 / 021 / 022 / 023 二–五 + 028 的契约文字（prompt 108，分支 `p5-contracts-2`，2026-10-11）

工作树分支 `claude/p5-contracts-2-eb5042` = 本地别名 `p5-contracts-2`，从 G8a 快进后的 main 30e4659 开。不 push、不 merge：做完由 G8（prompt 107 的会话）合进 main（G8a-2）。

## 1. 做了什么

用户 2026-10-11 批了 020 / 021 / 022 / 023 二–五，没批注，"请用户定的点"每条按提案默认；028 的契约文字、`renderMs` 一行与 L1 口径同日归本会话。全部先写红测试（用例名带提案号）再实现，顺序 022 → 023 → 021 → 020 → 028。

| 提案 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **022** Stats.encoder 的 `uptime_s` / `disconnects` / `last_error` + B1 `attempt` + B2 顶层 `video_delay_ms` | `Stats.EncoderEntry` 四字段（`jsonKeys` 排在 state 之后，缺键 0 / "" / 0，写出写全，init 带默认值）、`Stats.videoDelayMs`（末尾键，缺键 0）；填数：`Recorder`（`RecorderCounters.uptimeSeconds / lastError`，recording / stopping 之外 uptime 0、最近一次 .failed 文案、start 清）、`StreamOutput`（startedAt / lastError：断线原因、连接失败、建传输层失败、放弃；新加 `statsEntry(counters:previous:…)` 快照版）、`StreamCounters.statsEntry` 填 disconnects / attempt（退避期间 = failures + 1，与底栏原读法一致；胶水 4 行）、`NDISender`（`NDISendCounters.startedAt / lastError`：SDK 不在 / initialize / send_create 失败文案；胶水 15 行）、`StatsAssembler` 填 `counters.videoDelayMs` 一行、headless `EncoderStatsSource` 推流改走快照版 statsEntry 其余透传、App `OutputRuntime` 起不来的路把 `failureReason` 填进 `last_error`（胶水 12 行）；`StatsWriter.sanitized` 非有限的 uptime / video_delay 换 0；`StatsSummary.DeliverySummary` 多可选 `uptimeS / disconnects / lastError / lastAttempt`、顶层可选 `videoDelayMs` 序列，老基线缺键解 nil；测试标准 §7 字段表 + 一句含义；键名快照字面量重生成；App 的老 `w2-app-status-line-stats.jsonl` 照读 | 9adf144（文字 9ecc22a） | Stats.swift、RecordingStart.swift、Recorder.swift、StreamOutput.swift、StreamCounters.swift、NDISender.swift、EngineCounters.swift、StatsWriter.swift、StatsSummary.swift、HeadlessRun.swift、OutputRuntime.swift、Samples / CodableTests / StatsP2Tests / Contracts019Tests、Contracts022Tests、headless 的 Contracts022FillTests、测试标准 §7 |
| **023 二** `RecordSettings.container` 标废弃 + 录制来源口径 | `init(from:)` 改 `decodeIfPresent`（缺键 = mov），写出仍写，注释标废弃、不加 `@available`（默认）；录制来源 (a)：preview / multiview 照录 PGM 写进 `OutputSettings.source` 注释与 CONTRACTS.md §2.5，校验器不改 | 51e614e | MixerState.swift、Contracts023Tests |
| **023 三** `effects` 只放音频 | 只改 `InputSettings.effects` / `BusState.effects` 注释 + CONTRACTS.md §2.4 表行 | 51e614e | Input.swift、MixerState.swift |
| **023 四** `InputConfig.color` + `setInputColor` | `InputColor`（六种，= W5-H rawValue）、`InputConfig.color: InputColor?`（显式 `init(from:)`，nil 不写键，`jsonKeys`，`legacyCategoriesLayoutKey`）、命令（输入不存在校验器拒、相同值 applied = false）、`Show.migratingLegacyInputCategories()`（有键按原值搬、认不出 / 不存在的跳过、正式字段已有值的不动、搬完删键、名字键留着、幂等；**不并进 Show.load**，与 025 同一做法）；分类名字按默认 (a) 留 layout | 51e614e | Input.swift、Show.swift、Command.swift、MixerReducer.swift、CommandValidator / Catalog |
| **023 五** `setInputAudio(input:solo:afv:routing:)` | 三参数可选默认 nil（JSON 不写键）；reducer 非 nil 的整体替换该项、全 nil / 全相同状态不变；校验器只查输入；目录三个参数 optional，`routing` 用新字段类型 `CommandFieldType.busRouting`（面向操作员） | 51e614e | 同上 |
| **021** 文件播放控制 | `PlaybackSettings{paused, restartOnProgram, seekSeconds?, seekTick?}`（缺键默认、`{}` 合法、nil 不写键）、`InputSettings.playback`（显式 `init(from:)`、`jsonKeys`、`clamped()` 钳 seekSeconds ≥ 0）、`resetTransientState()` 清定位瞬态；`setPlayback` / `seekPlayback`（kind != file 校验器拒、reducer 同判；负秒数 / 非有限校验器拒）；reducer 四处 PGM 换人按 `restartOnProgram` 写定位 0（cut / setProgram / T-bar 提交 = 那一拍，auto 完成 = **开始拍 + 时长**，逐拍与一步到位等价）；"设循环"不加命令；目录两条（`CommandFieldType.seconds`） | 51e614e | Input.swift、MixerState.swift、Command.swift、MixerReducer.swift、CommandValidator / Catalog、Contracts021Tests、ReducerTests |
| **020** 转场槽 + FTB 时长 | `TransitionSlot`（`count / indexRange / factoryDefaults(for:)`：Fade 0.5 s / Wipe 1 s / Zoom 1 s / Stinger 1 s 按帧率 round 换拍）、`TransitionState.slots`（恰好 4，`validate()` 查）/ `currentSlot`（nil 或 1–4，`validate()` 查）+ 显式 `init(from:)`（缺 slots → []、缺 currentSlot → nil）+ `currentGroup` / `select(slot:)` / `slotIndexMatchingCurrentGroup(preferring:)`；`MixerState.newShow` 按帧率重算四槽、当前那组 = 槽 1；`Show.migratingLegacyKeys()` 补槽（槽 1 = 文件里原来那组，cut 的用 Fade 0.5 s）+ 清槽里悬空的 Stinger 引用；reducer：`setTransitionSlot`（进行中也收、钳位同 016、改当前槽空闲时重拷）、`useTransitionSlot`（进行中拒、start 一拍内原子完成、Stinger 槽没选输入照常开始）、`setFTBDuration`（渐变中 `equivalentStart` 回拨不跳变、0 立即到位）、`completeTransition` 按 currentSlot 幂等重拷（cut / auto 完成 / T-bar 提交都走它）、fade / setTransition / setTransitionParams 执行后 currentSlot = 仍对得上的槽或 nil、removeInput 清四槽引用；校验器：槽号 / Stinger 引用 / FTB 负时长入口拒，**loadShow 先搬迁再 validate**；目录三条（`setTransitionSlot` 归高级，`CommandFieldType.transitionSlot`）；SwitcherRender 没动 | 51e614e | MixerState.swift、Show.swift、Command.swift、MixerReducer.swift、CommandValidator / Catalog、Contracts020Tests、ReducerTests、Contracts016Tests（字面量改成只钉 016 的键） |
| **028** 契约文字 | `RenderedFrame.tickTime` = 节目输出时间线上的时刻（拍点 + Lₙ，严格递增；`program.pts` 仍是拍点）、`renderMs = gpuEnd − program.pts`、`AudioBlockConsumer.hostTime` 同一条线（各来源平移表）、`Stats.PerInput.latencyMs` 注释（L1 含 L）；CONTRACTS.md §3 第一条 / §6 T9 / §7 / §2.7；测试标准 §3 L1 行加一句"videoDelay 下判定扣掉当时的 `video_delay_ms`，阈值数字不动" | 9ecc22a（latencyMs 注释在 9adf144） | Render.swift、Stats.swift、docs/CONTRACTS.md、测试标准 §3 |
| 命令总数 | 35 + 3 + 2 + 1 + 1 = **42**：`Samples`（样例 + caseName + commandCaseCount）、`ContractsP3Tests` / `Contracts026Tests` / `ReducerTests`（表 + allCaseNames）/ `CommandCatalogTests` / `APIServerTests` 的计数，`CommandKind` / `init(of:)` / `operatorFacing` / `fields(for:)` / `entries`，`CommandValidator`，docs/api.md 重生成；App 胶水：`ActionCatalog.group(of:)` + 三个 `CommandFieldType` switch、`ActionPicker` 的表单 switch、两份 strings 的 7 个 `actionPicker.command.<kind>` | 51e614e | — |
| 文档 | CONTRACTS.md 变更记录 + §2.4 / §2.5 / §2.6 / §2.7 / §2.8 / §3 / §6 / §7 / §8 / §9；五份提案的状态改"已落地"+ 落地记录（提交号、与提案正文不同的细节） | 9ecc22a、09aaee7 | docs/CONTRACTS.md、docs/contract-changes/020 / 021 / 022 / 023 / 028 |

与提案正文不同的四处细节（都写进了各提案的落地记录）：
1. 020 `currentSlot` 的默认是"自动对号"（当前那组与某槽相同就是那个槽，否则 nil），不是写死 1：`TransitionState(type: .cut, durationTicks: 0)` 这种裸状态（Inputs harness、headless soak 工厂）写死 1 的话第一次 cut 完成就会被重拷成 Fade 0.5 s。
2. 020 搬迁遇到原来是 cut 的文件：槽 1 = Fade 0.5 s（提案写的），但 currentSlot = nil、当前那组仍是 cut（提案写 1），读进来行为不变。
3. 020 老命令执行后 currentSlot = 仍对得上的槽（优先原来那个）、对不上才 nil（提案写"= nil"）：`setTransition(fade, 30)` 之后槽 1 的高亮不该灭。
4. 021 `seekPlayback` 负秒数 reducer 不钳 0、原样返回（提案 B 表写 `max(0, s)`）：校验器拒负数，而 `testValidator_agreesWithReducer` 钉死"校验器拒的 reducer 必原样返回"；`setInputSettings` 整体带进来的负值仍由 `clamped()` 钳 0。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。阈值数字一个没动（测试标准只改了 §7 字段表与 §3 L1 行的一句口径）。

| 用例 | 测什么 | 结果 |
|---|---|---|
| `Contracts022Tests` ×3 | EncoderEntry 四字段 + 顶层 video_delay_ms 的 jsonKeys / 字面量 / 缺键 / 写全 / init 默认值；App 的老 stats.jsonl 照读 | ✅ |
| headless `Contracts022FillTests` ×5 | RecorderCounters / StreamCounters（connecting(n) = n、退避 = failures + 1、其余 0）/ NDISendCounters 的 statsEntry；NDISender 干跑起一次（有 SDK publishing、没 SDK unavailable + last_error）；StatsSummary 新字段 + 老摘要解 nil + 空文件 nil + StatsWriter 把 NaN / inf 换 0 | ✅ 5 / 5 |
| `Contracts023Tests` ×4 | 二：container 缺键 mov、mp4 照读照写、写全；四：六种颜色、nil 不写键、认不出的报错、命令形态、layout 键搬迁（搬 / 跳 / 不覆盖 / 删键 / 名字留 / 幂等 / Show.load 不搬）；五：全 nil 只写 input、部分键、老节目照读 | ✅ |
| `Contracts021Tests` ×3 | PlaybackSettings / InputSettings 的 jsonKeys、默认、`{}`、021 之前的 InputSettings 缺键、写全、clamped；瞬态由 resetTransientState / makeState 清、目标留；老节目照读；两条命令形态 | ✅ |
| `Contracts020Tests` ×6 | 出厂四槽按帧率（60 / 59.94 / 30 / 25 / 24）、TransitionState 默认与自动对号、newShow 重算；select / currentGroup / 对号（含 preferring）；JSON 形态（slots 写全、currentSlot nil 不写、020 之前的 JSON 裸解码 []）；validate 两条不变量；搬迁（非 cut 槽 1 = 原来那组、按帧率补、cut → nil、悬空 Stinger 清、g3 / g4 / m0 / g4-ndi 照读、3 个槽的文件读不进）；三条命令形态 + 命令数 42 | ✅ |
| `ReducerTests.test020_*` ×6 | 进行中改当前槽完成那一拍重拷（auto / T-bar 提交 / cut 幂等、空闲马上重拷）；useTransitionSlot 原子完成（cut / 时长 0 立即对调、只选中、相同原样）；老命令后 currentSlot 对号；removeInput 清四槽；setFTBDuration 渐变中回拨（起点 90、电平连续、0 立即到位、相同原样）；loadShow 先搬迁再 validate（3 个槽的被拒） | ✅ |
| `ReducerTests.test021_restartOnProgram_*` | cut / auto 完成（开始拍 + 时长，逐拍 = 一步到位）/ T-bar 提交 / setProgram 写定位 0；换走的、PGM 没变、推到一半、restartOnProgram = false、非文件输入不写；暂停中仍暂停；手发 seekPlayback 同一条路 | ✅ |
| `ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable` | 42 个 case 每个至少一行：新加 020 共 16 行、021 共 10 行、023 共 9 行；老行补上 currentSlot 的变化 | ✅（ReducerTests 28 / 28） |
| `CommandBusTests.testValidator_agreesWithReducer` | 合法 +14（含 020 之前的节目 loadShow）、非法 +13（槽号、Stinger 引用、FTB 负、非文件 / 不存在、负秒 / NaN） | ✅（6 / 6） |
| `CommandCatalogTests` ×3 | 42 个 kind、顶层键 = case 名、七条的字段描述、operatorFacing、docs/api.md 与生成器同步 | ✅ |
| `APIServerTests` | `GET /api/v1/commands` 42 | ✅（Control 全包 42 用例 0 红：VMixCompat 6、Tally 3、SwitcherControlTests 25 + 1 跳 C5 人工） |
| 原有用例改了字面量的 | `CodableTests.testP1_stats_jsonKeysSnapshot` / `testP1_show_roundTrip`（makeState 清定位瞬态）、`StatsP2Tests`、`Contracts019Tests`、`ContractsP3Tests` / `Contracts026Tests` 的 42、`Contracts016Tests` 只钉 016 的键 | ✅ |
| SwitcherCore 全包 | Render 101 + Engine 115 + Contracts 106（1 跳原有），0 红 | ✅ |
| SwitcherControl 全包 | 42（1 跳原有），0 红 | ✅ |
| SwitcherInputs / SwitcherAudio / SwitcherOutputs / SwitcherTestKit 全包 | Inputs 109（11 跳）、Audio 136（7 跳）、Outputs 122（14 跳，**1 红 = `StreamingTests.ThrottleProxyTests.testBlockStopsForwardingAndCloses`**，KNOWN_ISSUES 第 128 行列着的已知时序红，有问题单 reports/issues/W1E2-w2-stream-throttle-proxy-close-flaky.md；单独复跑 3 遍 1 过 2 红，与本会话无关——本会话没动限速代理）、TestKit 71；其余 0 红 | ✅（1 条已知红） |
| 工具冒烟 / headless | switcher-headless 0.1.0、frameprobe 0.1.0；headless `SoakPresetTests` 14 / 14、`Contracts022FillTests` 5 / 5 | ✅ |
| App `make gen && make test-app` | **228 用例：223 过、4 跳、1 红 = `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions`（"菜单项：全部关（配置留着）"：点菜单"关闭全部外部显示"后 3 s 内 output 7 没变成 enabled = false）**；单独复跑仍红；**在干净的 main 30e4659 工作树上单独跑同一个类同样红**（10 用例 9 过 1 红、同一断言），所以不是本分支的回归，是本机今天的环境 / 时序问题（G8a 2026-10-11 凌晨两遍全量都绿）；问题单 reports/issues/P52-app-toolbar-toggle-external-off-red-on-main.md | ✅（1 条与本分支无关的红） |
| `make lint BRANCH=p5-contracts-2` | 禁词 / 版本 0.1.0 / Package 约束 / 依赖方向（8 包）/ 归属（47 个文件都在范围内；胶水 App 47/50、SwitcherOutputs 20/50）/ check-links（178 个 Markdown）/ check-rt-symbols | ✅ |
| gate4 | 不跑（prompt：G8b 一次） | — |

## 3. 没做的和原因

1. **App 界面与接线**（100 / 101 / G8b）：转场列 / "切换"菜单 / T-bar 行 / FTB 右键发 `useTransitionSlot` / `setTransitionSlot` / `setFTBDuration`，格子 ▶ / ⏸ / ⟲ 发 `setPlayback` / `seekPlayback`，`InputCategories` 切到 `InputConfig.color` 并在 Show.load 后调一次 `show.migratingLegacyInputCategories()`，底栏 / 推流页 / 状态面板改读 `uptime_s` / `disconnects` / `last_error` / `attempt`。App 胶水只做了穷举点 + 动作名 + `last_error`（47/50 行，再加就超额度）。
2. **`ActionPicker` 对 `CommandFieldType.busRouting` 出的是空视图**（`setInputAudio.routing` 的四个勾选）、`transitionSlot` 借用叠加通道的四段控件：控件归 100；`ActionCatalog.jsonObject` 对 routing 返回 nil（可选，不填 = 不动），表单能发 solo / afv。
3. **FileInput 的播放接线**（101）：reducer 只记状态；组装方按快照变化调 `pause / resume / seek`。headless 的输入都是合成源，`setPlayback` / `seekPlayback` 只记状态。
4. **026 的引擎侧**（102）、**Hotkeys / MIDI 的 `ControlAction`**（执行 / 选中转场 n、播放 / 暂停 / 从头、toggleSolo 之类，100 之后）、**VMixCompat**（Transition1–4 / SetTransitionEffect / PlayPause 一族，100 / 兼容层会话）、**Stream Deck**（100 之后）。
5. **docs/api/README.md 的"N 条命令"**仍写着旧数（docs/api/ 不在本会话目录，103 改；docs/api.md 本身已重生成）；docs/user 的转场 / FTB 时长 / 分类 / 播放控制文字归 103。
6. **gate4 报告脚本的 L1 判定扣 `video_delay_ms`**：scripts/ 不在本会话目录，归 G8b（用户裁定）。`StatsSummary` 没有 L1 判定，不用改。
7. **录制起止按节目输出时间线开录**（App `OutputRuntime` 两处 + headless `HeadlessRun` 两处 + `AVCompensationTests` 去掉 startTick = −2 的变通）归 G8b 胶水（用户 2026-10-11 裁定第 4 条）。
8. **gate4 没跑**（prompt：G8b 一次）。

## 4. 对契约的疑问

1. **020 的三处细节与提案正文不同**（§1 末尾 1–3 条）：currentSlot 自动对号、cut 文件搬迁 currentSlot = nil、老命令后 currentSlot 对号而不是一律 nil。都是"老用户 / 老脚本察觉不到变化"这一条推出来的；要改回提案字面各一行。
2. **021 `seekPlayback` 负秒数 reducer 原样返回**（§1 第 4 条）：要"钳 0"就得同时放宽校验器（否则 `testValidator_agreesWithReducer` 红），建议维持。
3. **022 `attempt` 在退避期间 = failures + 1**（即将进行的那一次），不是 `backoff(attempt:)` 枚举里的数：与 App 底栏原来的读法一致、与 connecting(n) 连续。要按枚举字面就改 `StreamCounters.statsEntry` 一行。
4. **023 四的搬迁"正式字段已有值的不动"**（提案只说"有键按原值搬"）：按 010 / 013 的做法；App 切换（100 之后）时 color 都还是 nil，两种做法结果相同。
5. **`TransitionState.init` 的 `slots` 默认 = 60 fps 的出厂四槽**（它不知道帧率）：`MixerState(format: .hd1080p30)` 这种裸状态的槽是 30 / 60 / 60 / 60 拍，`newShow(format:)` 才按帧率重算——与 027 的叠加默认同一取舍。App 的 emptyShow 已走 newShow。
6. **`newShow(format:)` 的当前那组改成 = 槽 1（Fade 0.5 s）**：60 / 59.94 fps 下仍是 fade 30，与以前相同；30 fps 的新节目默认转场从 fade 30 变成 fade 15（0.5 s）。
7. 顺带：`CommandFieldType` 加了 `transitionSlot` / `seconds` / `busRouting` 三个 case（目录是 Control 包，不是 SwitcherContracts；App 的三个 switch 已补）。

## 5. 下一个会话需要知道的坑

1. **App 胶水 47/50**：本分支之上再动 App 任何一行就超额度，100 / 101 要从这头开（叠分支、lint 加 `--base p5-contracts-2`）或等 G8a-2 合进 main。
2. **`swift test --filter` 的 `|` 不是交替**（P5 §5 第 2 条仍成立）：`--filter 'SoakPresetTests|Contracts022FillTests'` 只跑到前一个；一个 filter 一个类。
3. **加 Command case 要改的地方**比 P5 §5 第 3 条又多三处：`Contracts026Tests` 里也钉了命令数、`ReducerTests` 的表驱动对转场类命令要补 `currentSlot` 的期望（老命令执行后会变）、`CommandCatalogTests.testCatalog_typedFieldsMatchExampleKeysAndWholeReplaceIsAdvanced` 要求样例 JSON 的键都有描述且 `operatorFacing == !hasJSON && !destructive`——带结构体参数的命令只能归高级。
4. **`completeTransition` 现在带 tick**（`completeTransition(&s, at:)`）：auto 完成传的是"开始拍 + 时长"不是 advance 的目标拍（021 的 seekTick 要逐拍 = 一步到位）；再加"换 PGM 那一拍"的副作用都放 `completeTransition` / `setProgram` 两处。
5. **`TransitionState` 的 JSON 形态变了**（多 slots / currentSlot）：钉 TransitionState 字面量的用例只剩 `Contracts020Tests`；别的包 / App 若有 MixerState JSON 字面量要跟着改（本会话跑的六包 + App 没有撞到）。
6. **`Stats(ts:…)` 构造函数末尾多了 `videoDelayMs: Double = 0`、`EncoderEntry` 多了四个带默认值的参数**：旧调用点不用改；写字面量快照的用例要重生成（CodableTests / StatsP2Tests / Contracts019Tests 这次都改了）。
7. **headless 的 `Contracts022FillTests` 构造 `NDISender(dryRun: true)` 会建 Metal 转换器**：没有 GPU 的环境会退到 CPU，用例不依赖 SDK 在不在（两种结果都断言）。
8. **`make lint` 会等 `swift package dump-package` 拿到包的锁**：与同一包的 `swift test` 并跑时 lint 挂着不动直到测试结束（本会话等了 Audio 包 ~10 min），不是卡死。
9. **gate4 没跑**；G8b 跑的时候 `video_delay_ms` 在 gate4 场景（不带效果）恒 0，L1 判定扣它没有数字会变。
10. **App 的 `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` 今天在 main 上也红**（§2 / §6）：点"关闭全部外部显示"后 output 7 的 enabled 3 s 内不变；不是本分支的事，但 G8a-2 合并时全量 App 会看到它，先按问题单 P52-app-toolbar-toggle-external-off-red-on-main 对（G8a 时同一机器两遍都绿，怀疑是本机当天的显示 / 窗口状态或共用的测试宿主 defaults）。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0）；同机当时没有别的会话在跑重活（`ps -axo comm,%cpu` 看过）。

| 项 | 结果 |
|---|---|
| `swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests`（022 落地后） | 93 用例 1 跳 0 红 |
| `swift test --package-path Tools/switcher-headless --filter Contracts022FillTests` | 5 / 5 |
| `swift test --package-path Packages/SwitcherCore --filter SwitcherEngineTests.ReducerTests` | 28 / 28 |
| `swift test --package-path Packages/SwitcherCore --filter SwitcherContractsTests`（020 / 021 / 023 落地后） | 106 用例 1 跳 0 红（第一遍 2 红：`testP1_show_roundTrip` 要按 makeState 清定位瞬态比、g4 的槽 1 带着 Wipe 软边 0.1 / Stinger 9——改期望） |
| `swift test --package-path Packages/SwitcherControl --filter CommandCatalogTests / CommandBusTests` | 3 / 3、6 / 6（第一遍 2 红：docs/api.md 没重生成、seekPlayback 负秒数两边不一致——reducer 改成同判） |
| `swift test --package-path Packages/SwitcherCore`（全包） | Render 101、Engine 115、Contracts 106（1 跳）；0 红 |
| `swift test --package-path Packages/SwitcherControl`（全包） | VMixCompat 6、Tally 3、SwitcherControlTests 25 + 1 跳 = 42（计数行按 xctest 分三段，最后一段 42 是合计）；0 红 |
| `swift test` SwitcherInputs / SwitcherAudio / SwitcherOutputs / SwitcherTestKit（串行，02:0x–02:4x） | Inputs 59 + 25 + 25 = 109（11 跳）0 红；Audio 72 + 64 = 136（7 跳）0 红；Outputs 12 + 25 + 50 + 9 + 11 + 15 = 122（14 跳）**1 红**（ThrottleProxy，已知）；TestKit 71 / 71 |
| `swift test --package-path Packages/SwitcherOutputs --filter ThrottleProxyTests` ×3（单独复跑） | 过 / 红 / 红（同一断言"放开后旧连接应当已被代理关掉"）——与 W1E2 问题单描述一致 |
| headless `--filter 'SoakPresetTests|Contracts022FillTests'`（这次 `|` 居然匹配到 14 个）、`--filter Contracts022FillTests`、`make test-tools` | 14 / 14、5 / 5；两个工具冒烟通过 |
| `make gen && make build-app && make test-app`（02:3x–02:5x，期间没跑别的） | 228 用例 223 过 4 跳 1 红（ToolbarMenuTests）；`xcrun xcresulttool get test-results summary --path .build/DerivedData/Logs/Test/Test-Switcher-2026.10.11_02-47-26-+0800.xcresult` |
| `xcodebuild test -only-testing:SwitcherTests/ToolbarMenuTests`（本分支单独复跑） | 10 用例 9 过 1 红（同一条） |
| 同一条在干净 main 30e4659 的临时工作树上（`git worktree add` 到 scratchpad、`make gen`、`-only-testing:SwitcherTests/ToolbarMenuTests`，跑完已删） | 10 用例 9 过 1 红（同一断言）——**main 今天也红**，不算本分支 |
| `git branch -f p5-contracts-2 HEAD && make lint BRANCH=p5-contracts-2` | 全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 47 个文件（胶水 App 47/50：两份 strings +7 / OutputRuntime +6−6 / ActionCatalog +10−5 / ActionPicker +3−3；SwitcherOutputs 20/50：NDISender +15−1 / StreamCounters +3−1）/ check-links 178 个 Markdown / check-rt-symbols |
| `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` | 重生成（+202 行：七条命令 + 样例里多出的键） |

提交：9adf144（022）→ 51e614e（020 / 021 / 023 二–五）→ 9ecc22a（028 文字 + CONTRACTS.md / 测试标准）→ 09aaee7（提案落地记录）→ 本报告 + 问题单。
