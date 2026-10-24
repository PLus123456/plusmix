# P5-5 报告：契约落地八——032 输入编号上限（0.1.1 唯一的 S1）、030 列耳机总线、NDI failed / last_error 的契约文字、031 / 029 落地核对（prompt 123，分支 `p5-contracts-5`，2026-10-24）

工作树分支 `claude/vigorous-hugle-10ab64` = 本地别名 `p5-contracts-5`（提交后 `git branch -f p5-contracts-5 HEAD`），从 G10 快进后的 main 开：起点 2ec2c05 = 1f9be64 + 一个只往 reports/ 加审计文件的提交（`git merge-base --is-ancestor 1f9be64 HEAD` 过）。
不 push、不 merge：做完交 G11（prompt 127）。提案 032 用户 2026-10-18 已批"按建议"，本会话写成提案文件记决定、没有停下来问；030 列耳机总线、NDI failed 只补文字也是同日的裁定 #1 / #10。

## 1. 做了什么

每一项都先写红用例（用例名带提案号）、看着红了再实现。**不加命令（仍 42 个 case）、不加字段，JSON 形态一个字节不变**；App / headless / AudioEngine.swift 0 行改动（G10 胶水已经做了 030 的填数，交付 1 只剩契约那半）。

| 交付 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **3. 032 输入编号上限**（S1） | 契约常量 `InputConfig.numberRange = 1...16`（= App"添加输入满 16 路"、引擎默认 `maxInputs`）；`MixerStateError.inputNumber(input:)`，`validate()` 在"≥ 1"之后、"不重复"之前查上限（0 / 负数照旧 `reservedInputNumber`）；Show.load / loadShow 读到越界编号不打开。reducer 的 addInput 用同一常量（原来 `number > 0`），校验器 addInput 越界 400"输入编号必须在 1–16 之间：<n>"（原来的"必须 ≥ 1"并进这一句，文字由 `CommandValidator.inputNumberRangeText` 从常量生成）；按编号取输入的命令照旧"输入 n 不存在"（越界的编号进不了状态）。命令目录 addInput 写明 1–16 → docs/api.md 重生成（只变两行，`#### ` 命令标题仍 42 个）。提案文件 032（改什么 / 为什么 / 影响谁 / 怎么迁移 / 落地记录） | 518dab2 | Input.swift、MixerState.swift、MixerReducer.swift、CommandValidator.swift、CommandCatalog.swift、docs/api.md、docs/contract-changes/032-input-number-range.md；用例见 §2 |
| **3. 兼容层确认**（116 报告 §3 的触发条件） | 同一套状态机 + 总线上起主 API 和兼容层，**修前的树**：主 API POST addInput 2^62 → 200、状态里留下 `4611686018427387904`，兼容层 TCP `TALLY` → `Fatal error: failed to allocate 4611686018427387952 bytes of memory with alignment 8`（xctest 进程被杀）；**修后**：2^62 / Int.max / 17 → 400 带理由，绕过校验器直接发给状态机 → reducer 不收，`TALLY OK 1200`、TCP `XML` 与 HTTP `/api` 都照常应答（2056 字节）。兼容层代码没改。两条都是临时探针（VMixCompatTests 不在本会话目录，跑完删了）；回归用例全文写进问题单交 W2-C 系 / G11 | — | reports/issues/P55-w2-control-vmixcompat-huge-input-number-test.md |
| **1. 030 列耳机总线** | `EffectsLatency.listedBuses = Bus.allCases`（原来三条，与 G10 胶水 ① 之后的四条填数对不上）、`BusLatency.bus` 取值注释加 headphones；集成测试加一句"填数的 bus 列表 = listedBuses 的名字"，以后两边谁单独改了都会红 | b9b87ff | Stats.swift、Contracts030Tests、Samples、CodableTests、IntegrationTests/EffectsLatencyStatsTests |
| **2. NDI failed 的含义** | `EncoderEntry.state` 注释：NDI failed 也指"在跑但连续 `NDISender.failureStreakLimit` = 10 帧没送出去"（像素格式送不了 / NV12 → UYVY 转换失败 / 直送缓冲锁不住，送出去一帧回 publishing）；`lastError` 注释：NDI 连续送不出时写像素格式与原因、推流的例子换成 G10 胶水 ③ 之后的写法。取值集合不变、不加字段、不另写提案（裁定 #10）。CONTRACTS.md 同一句旁边写了 BGRA 按 BGRX 送（裁定 #11、G10 胶水 ②） | b9b87ff（注释）、1df7f85（文字） | Stats.swift、docs/CONTRACTS.md |
| **文字** | CONTRACTS.md：标题行与变更记录 P5-5 一段；§1 / §2.4 / §3 / §8 写输入编号 1…16；§2.4 新加"输入编号的上限（提案 032）"一段；§2.5 validate 那句；§2.7 NDI failed + BGRX、encoder[].last_error（推流 `断线：连接断开 / 发送停滞 / 发送失败：<原因>`、`连接失败：<原因>`、鉴权失败、建传输层失败；NDI 连续送不出）、audio.effects 四条总线。测试标准 §7 字段行两处（audio.effects 四条总线、NDI failed 后半句），**阈值一个没动** | 1df7f85 | docs/CONTRACTS.md、docs/spec/导播台测试标准.md |
| **4. 落地记录** | 030 文末加"耳机总线"一段（填数 G10、常量 P5-5、用例、EQ 那一条为什么没另加）；031 文末加核对表（定位过尾 = 从头 / 缺 rate 读 1 / setInputSettings 定位钳一周各在哪、哪条用例钉着；App 数字框 G10 胶水 ⑤ 已做；老节目越界速率的提示归 126）；029 文末加核对（"不连 T-bar 拒"那段 G9 已写、与代码一致）。三份文件原有的 10-18 裁定段都在，没改动 | 1df7f85 | docs/contract-changes/029 / 030 / 031 |

仓库里带的节目先核了编号（交付 3 "先 grep Samples 与 Tests/Fixtures 核实"）：Samples/ 三份 1…6、scenarios/ 四份 1…9、契约测试的 P3 之前的 g4 老节目 1…9；Tests/Fixtures/ 里只有 .mov 和 frameprobe 的期望 JSON、没有节目文件。全部在范围里，钉成了 `Contracts032Tests.test032_shippedShowsWithinRange_stillLoad`。
代码里写死的编号也扫过：`InputConfig(number:)` 的字面量最大 9；headless 的工厂最大 11（soak 的文件输入）；超过 16 的只有 Render 的 `MultiviewLabelTests`（70 路）与 App 的 `ThumbnailCropTests` / `MultiviewLayoutTests`（19 / 24 路），它们直接给渲染器 / OfflineRenderer 一个内存里的状态、不经 validate / reducer，不受影响。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。"先红"一栏是实现前、只改了用例时跑的结果（日志在本会话 scratchpad `logs/red/`；032 的契约用例编译不过，按 P5-4 的做法先把那个文件挪开跑别的、再放回来编译）。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `Contracts032Tests.test032_numberRange_oneToSixteen`（新） | 1…16；下限 = noInput + 1；1 / 2 / 8 / 16 在、0 / −1 / 17 / 99 / 2^62 / Int.max / Int.min 不在 | 编译不过（`InputConfig` 没有 `numberRange`） | ✅ |
| `Contracts032Tests.test032_validateRejectsInputNumberAboveRange_showLoadRefuses`（新） | 16 过；17 / 99 / 2^62 / Int.max → `.inputNumber(input:)`；0 / −1 / Int.min 仍 `.reservedInputNumber`；Show.load 读到 17 号不打开、16 号照读；JSON 里直接写 2^62 的节目同样不打开 | 编译不过（`MixerStateError` 没有 `inputNumber`） | ✅ |
| `Contracts032Tests.test032_shippedShowsWithinRange_stillLoad`（新） | Samples/ 三份、scenarios/ 四份、契约测试 g4 老节目都 Show.load 得了、编号都在 1…16 | 同上（不是红用例，是"032 不让现有节目打不开"的护栏） | ✅ |
| `Contracts032Tests.test032_wireShapeUnchanged`（新） | InputConfig 键不变、写出形态不变；单路 InputConfig 解码不拒 2^62（越界在 validate 里报） | 同上 | ✅ |
| `ReducerTests.test032_addInputAndLoadShow_inputNumberAboveRangeRefused`（新） | addInput 17 / 99 / 2^62 / Int.max 原样返回、16 照收且 validate 过；loadShow 带 17 号不载入、16 号载入；状态机回执 applied = false、状态不变 | **7 处红**（四个越界编号都加进去了、loadShow 17 号载入了、回执 applied = true、状态里有 2^62） | ✅ |
| `ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable`（加 3 行） | addInput 16 照收、17 拒、2^62 拒；42 个 case 仍每个至少一行 | 2 处红（17、2^62） | ✅ |
| `CommandBusTests.testValidator_agreesWithReducer`（合法 +2 / 非法 +8） | 合法：addInput 16、loadShow 带 16 号；非法：addInput 17 / 2^62 / Int.max、loadShow 带 17 号（校验器拒 + reducer 原样返回），setInputSource 17 / setPreview 2^62 / removeInput Int.max / audioGain 17（原来就是"不存在"，钉住） | 8 处红（前四条各 2 处） | ✅ |
| `CommandBusTests.test032_inputNumberAboveRange_rejectedWithReason`（新） | 真总线：addInput 17 / 2^62 / Int.max / −5 → 理由"输入编号必须在 1–16 之间：<n>"，loadShow 17 号 →"节目文件不合法"，setInputSource 17 / setPreview 2^62 / removeInput Int.max →"不存在"；不占 sequence、状态不变；加满 5…16 后 17 号仍拒、最终 1…16 且 validate 过 | **11 处红**（越界的都放行了，连带 17 号进了状态之后 setInputSource 17 也放行） | ✅ |
| `APIServerTests.test032_postCommand_inputNumberAboveRange_400`（新） | 真 HTTP：POST addInput 2^62 / 17 → **400** 带理由、不占 sequence；16 → 200；GET state 的编号 = [1, 2, 3, 4, 16] | **6 处红**：修前两条都是 200，状态 = `[1, 2, 3, 4, 16, 17, 4611686018427387904]`（W2-C4 的触发条件原样） | ✅ |
| `CommandCatalogTests.testCatalog_032_inputNumberRangeDocumented`（新） | addInput 摘要含"1–16"与"032"、config 参数说明含"1–16"、字段不变、命令数 42 | 2 处红 | ✅ |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | docs/api.md 与生成器同步 | 改目录后红一次，重生成后绿 | ✅ |
| `Contracts030Tests.test030_jsonKeysSnapshot_listedBuses_millisecondsFromFrames`（改） | listedBuses = `Bus.allCases`、名字 = master / busA / busB / headphones | **2 处红**（三条 ≠ 四条） | ✅ |
| `Contracts030Tests.test030_effectsJsonShape_busesArrayInputsByNumber_measuredOptional`（改） | 样例 buses 补耳机那一项，JSON 逐字 | — （样例数据，不是产品改动） | ✅ |
| `CodableTests.testP1_stats_jsonKeysSnapshot`（改） | `Samples.effects()` 补耳机 5.5 ms 一项，整行字面量跟着改 | — （同上，样例与字面量一起改） | ✅ |
| `IntegrationTests.EffectsLatencyStatsTests.test030_…`（加一句） | 引擎填出来的 `buses.map(\.bus)` = `listedBuses.map(\.name)` | **1 处红**（填数四条 ≠ 常量三条，G10 留下的不一致） | ✅ |
| 兼容层探针（临时，没提交；全文在问题单） | 修后：主 API 2^62 / Int.max / 17 → 400；reducer 不收；TCP TALLY / XML、HTTP /api 照常 | 修前的树（独立 detached worktree，跑完删了）：POST 200 → TALLY 时 `Fatal error: failed to allocate 4611686018427387952 bytes` | ✅（修后 0.026 s） |

整包与工具（prompt 123 第 5 条；机器 Apple M5 Max，macOS 27.0.1（26A434）/ Darwin 27.0.0，交流电；同机并行 124 / 125 / 126 三个会话，负载见各行）：

| 项 | 结果 |
|---|---|
| Core 整包 `swift test --package-path Packages/SwitcherCore`（树 1df7f85，14:08 起 521 s，开跑时负载 4.9） | **351 = Render 101 + Engine 131 + Contracts 119（1 跳：`StatsP2Tests.testP2_stats_oldGateFilesParse`，原来就跳）**，0 红 |
| Control 整包 `swift test --package-path Packages/SwitcherControl`（同一棵树，17 s） | **100 = SwitcherControlTests 61 + VMixCompatTests 36（1 跳：手动的 Companion 会话）+ TallyTests 3**，0 红（临时探针没在树里） |
| Audio 整包 `swift test --package-path Packages/SwitcherAudio`（同一棵树，453 s，开跑时负载 2.1） | **178 = SwitcherAudioTests 88（2 跳：真设备）+ IntegrationTests 90（5 跳：真设备 / 回环）**，0 红 |
| `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` | 只变 addInput 两行；`#### ` 命令标题 42 个 |
| `make lint BRANCH=p5-contracts-5`（C locale 与 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8` 各一遍；报告提交前一轮、提交后又一轮） | 全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 23 个改动文件（报告提交后 24 个）都在范围内 / check-help 18 文件 / check-links 207 个 Markdown、Samples 节目文件合法 / check-rt-symbols |

没跑：gate4 / perf / soak（prompt 不让跑，同机有三个会话）；Inputs / Outputs / TestKit 整包、App 全量、headless 工具测试（不在 prompt 第 5 条里；新契约只加了一个常量和一个枚举 case，包外没有对 `MixerStateError` 的穷举 switch，grep 过）。

## 3. 没做的和原因

1. **VMixCompatTests 那条回归用例没进代码**：VMixCompat 不在本会话目录（prompt 原话"用例若要进那边写进报告给 G 类会话或 W2-C 系"）。用例全文、修前 / 修后结果在 reports/issues/P55-w2-control-vmixcompat-huge-input-number-test.md，原样放进 `CompatHardeningTests.swift` 就能用（修前的树上它会带走 xctest 进程）。
2. **prompt 交付 1 的"Integration 用例：耳机总线装一格 EQ"**：G10 胶水 ① 已经在同一条集成用例里装了耳机条一格限幅（12 ms，能看出确实拷到了耳机那一条；一格 EQ 的延迟是 0、与没装分不出来），本会话只补了"填数 = listedBuses"那一句，没另加 EQ 版。
3. **AudioEngine.swift 没碰**：G10 胶水做了填数（`statsEffects` 按 `Bus.allCases`），prompt 只许"G10 没做的话"才碰；它的文档注释里"契约的 listedBuses 与文字归 123"现在过时了（只是一句注释），留给下一个碰这个文件的音频会话（125 W1-D4 也在改 SwitcherAudio，免得撞）。
4. **030 的 App / API 展示**（126）、**KNOWN_ISSUES 的 S1"输入编号没有上限"销号**（G11 合入后做，docs/KNOWN_ISSUES.md 不在本会话目录）、**手册**（124）都不在本会话。
5. **App 打开越界编号老节目时的提示**：走现有"节目文件不合法"那一路（`SwitcherSession` / ShowDocuments 的 `validate()` 报错原样显示，和 031 的越界速率一样）；App 写不出超过 16 的编号，这种文件只可能来自 API / 手改，没另做文案。

## 4. 对契约的疑问

1. **输出编号同样没有上限，而且 App 有一处会溢出崩**（032 之外新发现，没修，请用户定）：`addOutput` 的校验器 / reducer 只查"> 0、不重复"，主 API 或节目文件可以放一个编号 `Int.max` 的输出；App 有四处"新输出编号 = 最大输出编号 + 1"（底栏"录制"在节目里没有录制输出时 `BottomBarView`、菜单栏虚拟摄像头开关 `AppDelegate`、外部显示路由 `ExternalOutputMenu.makeOutput`、输出设置页 `OutputSettingsPanel.nextOutputNumber`），遇到 `Int.max` 时 `+ 1` 整数溢出、进程直接 trap。
   与输入编号是同一类（要 API / 手改文件才进得来、一进来就崩），按 032 的定级应记 S1。可选：(a) 写提案 033 给输出编号也定上限（比如 1…64，`MixerState.validate()` + 校验器 addOutput + reducer，同 032 的做法）；(b) 只在 App 里改成"在 1…上限里找最小空号"、找不到就提示（App 几行，归 126 或之后的 App 会话），契约不动；(c) 维持。**建议 (a)**（与 032 同一处堵住，headless / API 客户端也受益），要 (b) 也可以两个都做。本会话没写提案（prompt 写明"不做：别的提案"）。
2. **032 的边界 16 是否以后要随引擎放大**：现在 App / 引擎 / 契约三处都是 16（`Engine(maxInputs:)` 的默认值、App `max(16, 最大编号)`）。将来要支持更多路，改的是这个常量 + 提案（`OfflineRenderer` / 兼容层都按最大编号分配，常量放大到几百仍安全，放到上万要再看 TALLY / XML 的体积）。没有疑问，只是记一句。
3. 030 / NDI failed：按裁定只改了常量和文字，没有疑问。

## 5. 下一个会话需要知道的坑

1. **G11 合并顺序**：本分支动了 `ReducerTests.swift`（加 3 行表 + 1 个用例）、`IntegrationTests/EffectsLatencyStatsTests.swift`（加 1 行）——125 W1-D4 的目录（`SwitcherEngineTests/`、整个 `SwitcherAudio/`）也包含这两个文件，合并时若撞了是相邻行、两边都留。CONTRACTS.md / 提案文件只有本分支改。
2. **校验器的 addInput 文案变了**：0 / 负数原来是"输入编号必须 ≥ 1：<n>"，现在和越界一样"输入编号必须在 1–16 之间：<n>"。仓库里没有用例或代码按旧文案匹配（grep 过；`testBus_rejectsStructurallyInvalidCommandsWithReason` 按"编号"关键字匹配，照过）；App 状态行显示的是总线给的原文。
3. **`MixerStateError` 多了一个 case**：包外没有穷举 switch（grep 过 App / Tools / 各包 Sources）；以后谁要按 case 给用户文案，记得 `inputNumber(input:)` 与 `reservedInputNumber` 的分工（前者只管 > 16）。
4. **兼容层探针要用 `CompatFixture` 的同一条总线起 `APIServer`**（`APIServer(bus: f.bus, feed: f.feed, …)`），这样"主 API 发命令 → 兼容层读快照"是同一个状态机；macOS 没有 `timeout` 命令，修前那种会崩 / 卡的探针用 `perl -e 'alarm N; exec @ARGV' swift test …` 包一层。
5. **修前的树另起 detached worktree 跑**（`git worktree add --detach <scratchpad>/prefix-wt HEAD`，跑完 `git worktree remove --force`）——不要在本工作树里 stash（stash 栈是所有工作树共用的）。冷编 SwitcherControl 约 1 分钟。
6. 新工作树第一次 `swift build --build-tests`：Core 10 s / Control 43 s / Audio 11 s（本机）；`swift test --filter` 可以写多个 `--filter`（取并集），`|` 仍不是交替。
