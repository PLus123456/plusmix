# P5-7 报告：契约落地十——数值入口加固（提案 034；Codex 2026-10-22 审查 N01 / N02 / N03 / N08 / N11 + 10-24 网络审计 NS01）（prompt 129，分支 `p5-contracts-7`，2026-10-24 / 25）

工作树分支 `claude/awesome-solomon-d4a48a` 起点 = main bf149e2（= g11），在工作树里 `git switch -c p5-contracts-7`，之后所有提交都在 `p5-contracts-7` 上；报告提交后 `git branch -f claude/awesome-solomon-d4a48a p5-contracts-7`，两个名字指向同一头，以 `p5-contracts-7` 为准。
不 push、不 merge：做完交 G12（prompt 134）。提案 034 写完停下来问了用户（铁律 1），用户 2026-10-25 全按建议批（见 §4）。

提交：39fb29c 红用例 → d700180 提案（待批）→ 18db9f6 落地 → 1fe2fda 文字 → （本报告）。

## 1. 做了什么

顺序按 prompt：① 先把 reports/codex-bug-audit-20261022-tests/ 里归本路的红用例 / 探针 / JSON 夹具搬成本包用例、看着红；② 写提案 034；③ 停下来问；④ 批了再落地 + 转绿；⑤ 文字；⑥ 整包与 lint；⑦ 本报告。

| 交付 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **红用例**（先红） | Codex 的七份 JSON 原样（逐字节相同）进 `Tests/SwitcherContractsTests/Fixtures/audit-20261022/`；`Contracts034Tests` 五条（N01 三、N02、尺寸 / 超大帧率）、`ReducerTests` 五条（ftbMax 原序列、状态里放 Int.max 时长、loadShow 0 个叠加、loadShow 换格式、叠加中途改时长）、`CommandBusTests.testN03_…`（Codex `primaryAPIDurationBoundaryDecoder` 改名）、App `OverlayClearInputTests.testN11_…`（Codex `testOverlaySelectingNoneMustClearRoute` 改名）。修前的结果见 §2 | 39fb29c | 见左 |
| **提案 034** | 七条按 prompt 的建议值写、各列备选；另把顺带核到的三处（②b 合成源帧率 / 尺寸、⑧ 音频对齐帧数没有上限、App 叠加时长框没有范围）写成"请用户定要不要并进" | d700180 | docs/contract-changes/034-numeric-input-hardening.md |
| **① 解码** | `Rational.init(from:)` 拒分母 0 / 分子或分母 `Int64.min`；`FrameRate.init(from:)` 拒分子 ≤ 0（"帧率必须为正"）。JSON 形态不变，代码构造的 precondition 留着 | 18db9f6 | Time.swift |
| **② / ②b 范围** | `ProgramFormat.sizeRange` = 16…8192、`FrameRate.programRange` = 1…240 fps；`validate()` 查节目格式（`MixerStateError.format`）、屏幕输入帧率与合成源帧率 / 宽高（`.inputFrameRate` / `.inputSize`）；判定放进契约 `InputSource.rangeError(input:)`，validate / reducer / 校验器调同一个函数（031 的文件速率并进去） | 18db9f6 | Time.swift、Video.swift、Input.swift、MixerState.swift、MixerReducer.swift、CommandValidator.swift |
| **③ 结构检查** | `Show.validateStructure()`（叠加恰好 4、槽 4 或空）+ `makeValidatedState()`；Show.load / migrate / 校验器 / reducer 的 loadShow 四处都走它；`MixerState.init` 的 precondition 留着 | 18db9f6 | Show.swift、MixerReducer.swift、CommandValidator.swift |
| **④ 时长上限** | `DurationLimits.maxTicks` = 864 000（+ `tickRange`）；fade / setTransition / setTransitionSlot / setFTBDuration / setOverlay 超上限校验器 400、reducer 原样返回（拒不钳；setTransitionSlot / setOverlay 的负数照旧钳 0）；`validate()` 查四处时长（`.durationTicks`）；第二道：`equivalentStart` 钳到 0…duration 再转 Int、`ramp` 拍差不溢出；出厂槽 / 默认淡入的秒→拍钳住（落地时发现的洞，见 §5 第 1 条） | 18db9f6 | MixerState.swift、MixerReducer.swift、CommandValidator.swift |
| **⑤ 叠加清空** | `overlay(input: 0)` = 清空（nil 仍是不换，不加命令）；校验器放行 0、reducer 置 nil；App 叠加设置"（无）"发 0 | 18db9f6 | MixerReducer.swift、CommandValidator.swift、App/Sources/Settings/OverlaySettingsPanel.swift |
| **⑥ loadShow 换格式** | 校验器 400"节目格式不同（1920×1080@60 → 1280×720@30）：运行中不能换格式，用打开节目 / 重启 headless"、reducer 原样返回；同格式照载 | 18db9f6 | MixerReducer.swift、CommandValidator.swift |
| **⑦ 叠加中途改时长** | setOverlay 改了时长且正在进 / 出 → 按当前进度重锚（与 setFTBDuration 同一做法）；0 = 立即到位；只改位置 / 方式起点不动 | 18db9f6 | MixerReducer.swift |
| **⑧ 对齐帧数** | `AudioState.alignmentRange` = 0…24 000（= App 设置面板）；`validate()` 查（`.alignmentFrames`） | 18db9f6 | MixerState.swift |
| **App 时长框** | `OverlaySettingsModel.ticks(seconds:)` 钳进 0…`DurationLimits.maxTicks`（原来填 20 位数 Double → Int 溢出崩）；用户同意越过"只改（无）那一处" | 18db9f6 | OverlaySettingsPanel.swift |
| **命令目录 / api.md** | fade / setTransition / setTransitionSlot / setFTBDuration / overlay / setOverlay / addInput / setInputSource / loadShow 九条写明边界（文字由校验器的常量生成）→ docs/api.md 重生成（只变这九条，`#### ` 标题 42 个） | 18db9f6 | CommandCatalog.swift、docs/api.md |
| **文字** | CONTRACTS.md：标题 / 变更记录、§2.1（解码）、§2.2（格式范围、运行中不换）、§2.4（来源范围、`rangeError`）、§2.5（validate 列表、新"数值入口"一段、setFTBDuration 那句、AudioState）、§2.6（Command 行、loadShow 两条规则）、§2.8（结构检查）、§3（编号 / 范围）、§8（overlay / loadShow 两行）；034 文末落地记录 | 1fe2fda | docs/CONTRACTS.md、docs/contract-changes/034 |

仓库里带的节目先核过：Samples/ 三份、scenarios/ 四份、契约测试的 g4 老节目都是 1920×1080 @ 30 / 60，合成源 1920×1080 @ 30 / 59.94 / 60，时长 ≤ 30 拍，没有屏幕输入；Tests/Fixtures/ 里没有节目文件。全在范围里，钉成 `test034_shippedShowsStillLoad`。
代码里写死的格式也扫过：`ProgramFormat(width:…)` 字面量最小 640×360、最大 3840×2160，帧率 24…60；App 自定义分辨率 320–7680 × 240–4320、帧率七档、屏幕输入帧率是下拉、转场自定义时长 0.1–10 s；别的包的用例没有超上限的时长、没有运行中 loadShow 换格式、没有发 overlay input 0 的。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。"先红"是实现前的结果（日志在本会话 scratchpad `logs/red/`）：Codex 搬来的 12 条（39fb29c）与 App 时长框那条是在本工作树上修之前真跑出来的红；第 ④ 步新加的 034 用例写在实现之后，事后在实现前的树上核过（本节末尾"先红核对"）：用到新常量 / 新 API 的编译不过，只用字面量的那几条按旧代码确实红。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `Contracts034Tests.testN01_showLoad_frameRateZeroNegativeOrInt64MinDenominator_throws` | fpsZero / fpsNegative / rationalMin 三份 Codex JSON → Show.load 抛 DecodingError；valid 对照照读 | **SIGTRAP**（`Time.swift:261: Precondition failed: 帧率必须为正`） | ✅ |
| `Contracts034Tests.testN01_decodeRationalAndFrameRate_illegalValuesThrow` | Rational：分母 0 / Int64.min、分子 Int64.min 六种抛，−3/6、Int64.max/1 照解；FrameRate：0、−30、30/−1、0/1001、1/Int64.min 抛，60000/1001、−60/−1 照解；JSON 形态不变 | **SIGTRAP**（分母 Int64.min 变号溢出） | ✅ |
| `Contracts034Tests.testN01_screenSourceAndCommandDecode_illegalFrameRateThrows` | 屏幕输入的 InputSource / addInput / setInputSource 三种 JSON，帧率 0 / −30 / 分母 Int64.min 都抛，对照照解 | **SIGTRAP**（帧率必须为正） | ✅ |
| `Contracts034Tests.testN02_showLoad_overlayCountNotFour_throwsOverlayCount` | overlays0 → `.overlayCount(0)`、五个叠加 → `.overlayCount(5)`、走 `Show.migrate` 同样 | **SIGTRAP**（`MixerState.swift:847: Precondition failed: overlays 必须恰好 4 个`） | ✅ |
| `Contracts034Tests.test034_showLoad_badDimensionsAndHugeFrameRate_refused` | dimensions / fpsHuge → `.format`；fpsHuge 去掉 slots（020 之前的写法）同样 `.format`、不在搬迁里溢出；`newShow(format: Int64.max fps)` 时长钳到上限不崩 | **2 处断言失败**（两份都照读了；第二段是落地时加的，见 §5 第 1 条） | ✅ |
| `Contracts034Tests.test034_formatRange_constantsAndValidate`（新） | sizeRange / programRange 常量；1、24…60、120、240、239.76 在，0.5、0.999、241、240.001、Int64.max 不在；App 预设与边界格式 validate 过，六种越界 → `.format(格式)` | 编译不过（没有 `sizeRange` / `programRange` / `.format`） | ✅ |
| `Contracts034Tests.test034_inputSourceRanges_screenAndSynthetic`（新） | 屏幕 nil / 1 / 30 / 240 与合成源边界过；屏幕 241 / 0.5、合成源 Int64.max fps / 0 宽 / 9000 高 / 300 fps 负宽 → `.inputFrameRate` / `.inputSize`；文件速率 0 仍 `.fileRate`；别的 kind 恒 nil | 编译不过（没有 `rangeError` / 新 case） | ✅ |
| `Contracts034Tests.test034_durationLimits_validateFourPlaces`（新） | maxTicks = 864000 = 3600 × 240；转场 / 槽 3 / FTB / 叠加 2 各自 0、1、上限过，上限 + 1、Int.max、−1、Int.min → `.durationTicks(值)` | 编译不过（没有 `DurationLimits`） | ✅ |
| `Contracts034Tests.test034_alignmentFrames_validateAndShowLoad`（新，⑧） | 0 / 2048 / 24000 过；24001 / −1 / 2^62 → `.alignmentFrames`；JSON 里写 2^62 的节目 Show.load 不打开 | 编译不过（没有 `alignmentRange`） | ✅ |
| `Contracts034Tests.test034_validateStructure_beforeMakeState`（新，③） | 叠加 0 / 3 / 5 个 → `.overlayCount`（validateStructure 与 makeValidatedState 都抛）；空槽过（搬迁补成 4）、3 个槽 → `.transitionSlotCount(3)`；结构检查只管个数、宽 9000 由 validate 报 `.format`；合法节目 makeValidatedState == makeState | 编译不过（没有 `validateStructure`） | ✅ |
| `Contracts034Tests.test034_shippedShowsStillLoad`（新，护栏） | Samples/ 三份、scenarios/ 四份、g4 老节目、Codex valid 都 Show.load 得了，格式 / 来源 / 时长都在范围里 | 编译不过（同上；护栏，不是红用例） | ✅ |
| `ReducerTests.testN03_ftbMaxDurationSequence_refusedAndNoTrap` | 默认状态 ftb(true) → setFTBDuration(Int.max) 原样返回 → ftb(false) 照常往回走 | **断言失败 + `Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max`** | ✅ |
| `ReducerTests.testN03_reversalWithHugeDurationInState_doesNotTrap` | 状态里直接放 Int.max 的 FTB / 叠加时长，电平 0 时反转不崩、advance 到 1000 拍正常 | **同一个 Fatal error** | ✅ |
| `ReducerTests.testN02_loadShowOverlayCountNotFour_refusedBeforeMakeState` | loadShow 叠加 0 个 / 5 个原样返回 | **SIGTRAP**（overlays 必须恰好 4 个） | ✅ |
| `ReducerTests.testN08_loadShowWithDifferentFormat_refused_sameFormatLoads` | 1080p60 → 1080p30 / 720p30 / 720p60 / 1080p59.94 原样返回；同格式照载 | **4 处断言失败**（都被收了） | ✅ |
| `ReducerTests.test034_setOverlayDurationMidAnimation_reanchorsWithoutGoingBack` | 60 拍 fade 第 30 拍改 120 拍：那一拍 0.5、起点 −30、第 31 拍 61/120；退出动画中改短从 0.5 → 0.25；只改位置起点不动；改 0 立即到位 | **6 处断言失败**（第 31 拍 0.258） | ✅ |
| `ReducerTests.testN11_overlayInputZero_clearsRoute_nilStillKeeps`（新） | input 0 清空、nil 不换、空的再清原样、开着清空 → 开关不动 / 不可见 / tally off、再选一路接上；−1 / 9 仍非法 | 事后核对：同文件里别的新用例用到 `DurationLimits`，整个文件在旧树上编译不过；把"0 = 清空"那一句单拿出来在旧代码上跑——红（`XCTAssertNil failed: "3"`） | ✅ |
| `ReducerTests.test034_durationAboveLimit_refusedByFiveCommands`（新） | 五条命令 上限 + 1 / Int.max 原样返回、= 上限照收、setOverlay / setTransitionSlot 负数钳 0；状态机回执 applied = false | 编译不过（`DurationLimits`） | ✅ |
| `ReducerTests.test034_sourceAndShowRanges_refused`（新） | addInput / setInputSource 屏幕 241 fps、合成源 0 宽、Int64.max fps 原样返回，边界照收；loadShow 的 FTB 超上限 / 叠加负时长 / 对齐帧数 2^62 / 屏幕 241 fps 不载入 | 编译不过（`DurationLimits`） | ✅ |
| `ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable`（加 9 行） | fade / setTransition / setTransitionSlot / setFTBDuration / setOverlay 超上限拒、setFTBDuration = 上限照收、overlay input 0 清空、loadShow 换格式拒、addInput 屏幕 241 fps 拒；42 个 case 仍每个至少一行 | 编译不过（`DurationLimits`） | ✅ |
| `CommandBusTests.testN03_primaryAPIDurationAboveLimit_rejectedAtBoundary` | Codex 原两条（fade / setFTBDuration 的 Int.max 解码得出、校验器要拒）+ 五条命令上限 + 1 的理由逐字、三条命令负数的理由逐字 | **2 处断言失败**（原两条都放行；扩的五条命令单拿出来在旧校验器上跑——setOverlay / setTransitionSlot 的 Int.max、屏幕 241 fps 都放行） | ✅ |
| `CommandBusTests.testN08_loadShowFormatChange_rejectedWithReason`（新） | 真总线：换 720p30 → 理由逐字、59.94 的写法、不占 sequence、格式不变；同格式照载 | 事后核对：文件在旧树上编译不过（`DurationLimits`）；单拿出来在旧校验器上跑——红（换格式的 loadShow 放行） | ✅ |
| `CommandBusTests.testN11_overlayInputZero_passesBusAndClears`（新） | 真总线：input 0 放行并清空、开关不动；nil applied = false；−1 仍"输入 -1 不存在"；0 条被拒 | 事后核对：同上编译不过；单拿出来跑——红（旧校验器回"输入 0 不存在"） | ✅ |
| `CommandBusTests.test034_numericLimits_rejectedWithReason`（新） | 真总线十条理由逐字（屏幕 241 / 0.50 fps、合成源 1000 fps / 0×0、loadShow 叠加 0 个 / 尺寸 −1×0 / 帧率 Int64.max / FTB Int.max / 对齐帧数 2^62 / 输入 1 帧率 300）；不占 sequence、状态不变；边界三条照收 | 编译不过（`DurationLimits`） | ✅ |
| `CommandBusTests.testValidator_agreesWithReducer`（合法 +11 / 非法 +14） | 合法：五条命令 = 上限、两条负数钳 0、overlay input 0 ×2、屏幕 240 fps、合成源边界；非法：超上限 ×6、overlay −1、屏幕 241、合成源 0 宽 / 超大帧率、loadShow 换格式 / 没叠加 / FTB 超长 / 对齐帧数 24001——校验器拒、reducer 原样返回 | 编译不过（`DurationLimits`） | ✅ |
| `CommandCatalog034Tests.testCatalog_034_numericLimitsDocumented`（新文件） | 五条命令写明 864000、overlay 的 input 说明含"0 = 清空"且字段不变、addInput / setInputSource 写明 1–240 与 16–8192（031 / 032 那几句还在）、loadShow 写明"运行中不能换格式"与 makeValidatedState、命令数 42 | **9 处断言失败**（先写用例后改目录） | ✅ |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | docs/api.md 与生成器同步 | 改目录后红一次，重生成后绿 | ✅ |
| App `OverlayClearInputTests.testN11_overlaySettingsSelectingNone_clearsRoute` | 宿主：面板选 1 再选"（无）"，0.5 s 后 input 为 nil、总线 0 条被拒 | **断言失败**（`XCTAssertNil failed: "1"`） | ✅（1.23 s） |
| App `OverlayClearInputTests.test034_overlayDurationSecondsClampedToTickLimit`（新） | 0.5 s → 30 拍；20 位数 / +∞ / 14400 / 14401 s → 864000；−3 / NaN → 0 | **崩**（临时换回旧的 `ticks(seconds:)` 跑：`Fatal error: Double value cannot be converted to Int…`，xcodebuild 报 `Restarting after unexpected exit, crash`），换回修好的版本后绿 | ✅ |
| App `OverlayRevampTests`（三条，回归） | 新节目默认淡入、整幅 / 画中画、菜单入口 | — | ✅ 3 / 3 |

**先红核对**（第 ④ 步的用例写在实现之后，所以事后补核）：在 scratchpad 里开临时工作树停在 39fb29c（红用例那一笔、实现之前），把最终的 `Contracts034Tests` / `ReducerTests` / `CommandBusTests` / `CommandCatalog034Tests` 拷进去编译：
`Contracts034Tests` 编译不过（缺 `sizeRange` / `programRange` / `DurationLimits` / `alignmentRange` / `rangeError` / `validateStructure` / `makeValidatedState` / 五个新 `MixerStateError` case，共四十多处），`ReducerTests` 7 处、`CommandBusTests` 10 处 `cannot find 'DurationLimits' in scope`；
`CommandCatalog034Tests` 只用现有接口、能编译，它的红是先写用例后改目录时真跑出来的 9 处。再把这几个文件还原、换上只用字面量写的同样断言（临时文件，没提交）在旧代码上跑：reducer 收下五条命令的 864001 拍（5 处）、收下 241 fps 的屏幕输入、`overlay(input: 0)` 后 input 仍是 3；
校验器放行 setOverlay / setTransitionSlot 的 Int.max 与 241 fps 的屏幕输入（3 处）、放行换格式的 loadShow、把 `overlay(input: 0)` 拒成"输入 0 不存在"——都红。临时工作树用完删了。

整包与工具（prompt 第 4 条；机器 Apple M5 Max，macOS 27.0.1（26A434），Xcode 27.1 / Swift 6.4，交流电；开跑时负载 0.8，同一时段别的会话在不在跑没核）：

| 项 | 结果 |
|---|---|
| Core 整包 `swift test --package-path Packages/SwitcherCore`（树 1fe2fda，00:23:18 起 8 分 39 秒） | **371 = Render 101 + Engine 140 + Contracts 130（1 跳：`StatsP2Tests.testP2_stats_oldGateFilesParse`，原来就跳）**；**1 红：`SwitcherRenderTests.DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`**——那 2 秒 display link 一次都没回调（`blit 0 次`、SkipCounters 全 0，窗口没上屏 / 被盖住），显示类用例；**单独复跑两次都过**（30 次回调、30 次 blit，上限 34、下限 10）。本路没碰 SwitcherRender 一行（`git diff bf149e2 -- Packages/SwitcherCore/Sources/SwitcherRender Packages/SwitcherCore/Tests/SwitcherRenderTests` 为空），记为环境红 |
| Control 整包 `swift test --package-path Packages/SwitcherControl`（同一棵树，16 秒） | **106 = SwitcherControlTests 66 + VMixCompatTests 37（1 跳：手动的 Companion 会话）+ TallyTests 3**，0 红 |
| App：`xcodebuild … test -only-testing:SwitcherTests/OverlayClearInputTests -only-testing:SwitcherTests/OverlayRevampTests`（先 `make gen`） | **5 / 5 过**（N11 1.23 s、时长框钳位、OverlayRevampTests 三条），TEST SUCCEEDED |
| `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` | 只变 9 条命令的说明（fade / setTransition / setTransitionSlot / setFTBDuration / overlay / setOverlay / addInput / setInputSource / loadShow）；`#### ` 命令标题 42 个 |
| `make lint BRANCH=p5-contracts-7`（`LC_ALL=C` 与 `LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8` 各一遍，报告提交前） | 两遍都 exit 0：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 24 个改动文件都在范围内 / check-links 216 个 Markdown、Samples 节目文件合法 / check-rt-symbols |

## 3. 没做的和原因

1. **App 端到端的 N08**（Codex `testAPI_LoadShowMustKeepActualAndAdvertisedFormatConsistent`）：按 reports/codex-bug-audit-20261022-tests/README 归 G12 胶水、改成"400 + 格式不变"。App 的 `session.send` 走 ControlRuntime → 控制总线 → 校验器，所以本分支合入后那条宿主用例按原样会红在"等 state.format 变成 720p30"上——要改写，不是产品问题。
2. **命令目录里 overlay 的类型化字段没改**（`input(allowsBlack: false)`）：App"选动作"面板照旧不给"清空"选项（说明文字写了 0 = 清空）。要不要给面板加归 App 会话。
3. **顺带看到、没改的**：App"选动作"面板的秒数显示 `String(Int(rounded))`（ActionPicker.swift:243）对极大值同样会 Double → Int 溢出（没验证）；别的数值字段（编码码率 / 关键帧间隔 / 输出宽高、录制分片秒数、重连上限、NDI 抖动缓冲……）没逐个查。都不在本会话目录 / 范围里。
4. 没跑：gate4 / perf / soak（prompt 不让跑）；Inputs / Outputs / Audio / TestKit 整包、App 全量、headless 工具测试（不在 prompt 第 4 条里）。新契约加的是常量、`MixerStateError` 的五个 case、两个 Show 方法、一个 InputSource 方法：包外用到 `MixerStateError` 的只有 App 的 ShowDocuments（`catch MixerStateError.fileRate`，不是穷举 switch）和本路校验器里带 default 的 switch——grep 过，加 case 不会让别的包编译不过。

## 4. 对契约的疑问

**用户在 034 上各定了什么**（2026-10-25，AskUserQuestion 的四问，全选建议）：

| 条 | 用户定的 | 备选（没选） |
|---|---|---|
| ① 帧率解码抛错 | 按建议：分母 0 / Int64.min / 帧率 ≤ 0 解码就抛 | — |
| ② 尺寸 / 帧率范围 | 按建议：宽高各 16…8192、帧率 1…240 fps | 契约用 App 的范围（320–7680 × 240–4320、偶数、七档帧率） |
| ③ 结构检查在 makeState 之前 | 按建议 | — |
| ④ 时长上限 | 按建议：864 000 拍、拒不钳、节目文件里 0…864 000 两头都查 | 文件里只查上限、负数照读 |
| ⑤ 叠加清空 | `input: 0` = 清空、不加命令（仍 42 条） | 新命令 `clearOverlayInput(channel:)`（43 条） |
| ⑥ 运行中 loadShow 换格式 | 拒收 400 | App 收到就重建 session（会停掉在录在推的） |
| ⑦ 叠加中途改时长 | 按建议：按当前进度重锚 | — |
| 附带 ②b 合成源范围 | 并进 | 写问题单交别的会话 |
| 附带 ⑧ 对齐帧数 0…24 000 | 并进 | 同上 |
| 附带 App 叠加时长框钳位 | 并进（越过 OWNERSHIP"只改（无）那一处"） | 同上 |

**还想请用户 / 后面的会话定的**：
1. **奇数宽高**：NV12 4:2:0 / H.264 一般要偶数，App 的自定义分辨率已经取偶；契约没要求偶数（没证据说奇数会崩）。要不要加，需要先有人在渲染 / 编码那边验一次奇数尺寸。
2. **OWNERSHIP 的 P5-7 行**写的是"OverlaySettingsPanel 只改'（无）'那一处、App/Tests 只加 N11 那条"，实际按用户批的附带项多改了 `ticks(seconds:)`、多加了一条钳位用例；docs/OWNERSHIP.md 不在本会话目录，G12 合入时顺手改那一行的备注即可（路径本来就在允许范围里，check-ownership 是绿的）。

## 5. 下一个会话需要知道的坑

1. **搬迁在 validate 之前跑**：`Show.load` 是先 `migratingLegacyKeys()` 再查，搬迁里任何按文件数值做的算术都在校验之前。这次就有一处：没有 `slots` 的老文件补出厂槽时按帧率换拍，Int64.max 帧率在这里先溢出——改成钳住了（`clampedTicks`，私有函数）。以后往搬迁里加按数值算的东西，先想越界值。
2. **"拒"与"钳"两种口径并存**：时长上限是拒（400 / 原样返回），但 setTransitionSlot / setOverlay 的负数照旧钳 0、`InputSettings.clamped()` 照旧钳；`testValidator_agreesWithReducer` 只保证"校验器拒的 reducer 一定原样返回"，钳的那半要各自的用例钉。
3. **解码失败的 400 文案**来自 APIServer 的现有分支（"命令 JSON 无法解析：帧率必须为正"），不是校验器；API 层的用例归 131（APIServerTests 不在本会话目录），本路没加 HTTP 用例。
4. **`InputSource.rangeError(input:)` 是三处共用的判定**：以后给来源加新的数值约束，加在这一个函数里，validate / reducer / 校验器自动一致；校验器只按错误种类出文案（`sourceReason`）。
5. **给文档会话（W4-C5）的行为变化**（手册要跟）：
   - 叠加设置的"输入"选"（无）"现在真的清掉这一路的输入；开着的通道清空时画面**立刻**没有（没有退出动画），想淡出先关再清。
   - API：`overlay` 的 `input: 0` = 清空、`null` = 不换（以前 0 回 400"输入 0 不存在"）。
   - API：运行中 `loadShow` 的节目格式（宽高 / 帧率）和当前不同 → 400"节目格式不同（…）：运行中不能换格式，用打开节目 / 重启 headless"；换格式请用 App 的"打开节目"或重启 headless。
   - API：fade / setTransition / setTransitionSlot / setFTBDuration / setOverlay 的时长上限 864 000 拍（60 fps 下 4 小时），超了 400"时长必须在 0–864000 拍之间：<n>"；fade / setTransition / setFTBDuration 的负数也是这一句（以前"转场时长不能为负" / "FTB 时长不能为负"）。
   - API：addInput / setInputSource 的屏幕输入帧率、合成源帧率须在 1–240 fps，合成源宽高须在 16–8192，否则 400；帧率写 0 / 负数在 JSON 解码时就 400"命令 JSON 无法解析：帧率必须为正"。
   - 节目文件：格式宽高 16–8192、帧率 1–240 fps、四处时长 0–864 000 拍、音频对齐帧数 0–24 000、叠加恰好 4 个，越界的文件打不开（App 走现有的"打开失败"提示，文案是错误原样）。
   - 叠加的淡入 / 滑入进行中改时长，进度从当前位置按新时长接着走（以前会往回跳）。
   - App 叠加设置的"时长（秒）"填超大的数，按上限（60 fps 下 14 400 秒）算，不再让 App 崩。
6. 跑 App 单条用例：`xcodebuild … -derivedDataPath .build/DerivedData test -only-testing:SwitcherTests/OverlayClearInputTests`（先 `make gen`）；这台机器上新工作树第一次编 App 约 1 分钟（DerivedData 在工作树的 .build 里）。
