# 034 数值入口加固：帧率 / 尺寸的解码与范围、叠加数组先查结构、时长上限、叠加"清空"、运行中 loadShow 换格式（Codex 2026-10-22 审查 N01 / N02 / N03 / N08 / N11 + 10-24 网络审计 NS01）

提出会话 / 分支：P5-7（prompt 129），分支 `p5-contracts-7`，从 main bf149e2（= g11）开。
状态：**待批**（2026-10-24 写完，停下来问用户；铁律 1）。
来源：reports/codex-bug-audit-20261022.md §1 的 N01 / N02 / N03 / N08 / N11 与"保留线索"；reports/bug-audit-20261022-core-inputs.md CI-01 / CI-02 / CI-03 与"验证到的其他行为"；
reports/bug-audit-20261022-audio-outputs.md AO04；reports/codex-network-security-audit-20261024.md [1]（= N03）；docs/KNOWN_ISSUES.md 产品缺陷表 S0 三行（N01 / N02 / N03）、S1 两行（N08 / N11）。

## 修前的样子（本分支提交 39fb29c 的红用例，日志在会话 scratchpad `logs/red/`）

| 用例 | 修前 |
|---|---|
| `Contracts034Tests.testN01_showLoad_…`（fpsZero / fpsNegative / rationalMin 三份 JSON，Codex 探针原样） | xctest 进程 SIGTRAP：`Time.swift:261: Precondition failed: 帧率必须为正` |
| `Contracts034Tests.testN01_decodeRationalAndFrameRate_…` | SIGTRAP：分母 Int64.min 在约分变号 `d = -d` 溢出 |
| `Contracts034Tests.testN01_screenSourceAndCommandDecode_…`（屏幕输入的 addInput / setInputSource） | SIGTRAP：帧率必须为正——API 在校验器之前就崩 |
| `Contracts034Tests.testN02_showLoad_overlayCountNotFour_…`（overlays0） | SIGTRAP：`MixerState.swift:847: Precondition failed: overlays 必须恰好 4 个` |
| `Contracts034Tests.test034_showLoad_badDimensionsAndHugeFrameRate_refused`（dimensions 宽 −1 高 0、fpsHuge Int64.max/1） | 两份都照读（断言失败 2 处）；后者再 `MixerState.newShow(format:)` 会崩（Codex 实测） |
| `ReducerTests.testN03_ftbMaxDurationSequence_…`（默认状态 ftb(true) → setFTBDuration(Int.max) → ftb(false)） | Int.max 被收，然后 `Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max` |
| `ReducerTests.testN03_reversalWithHugeDurationInState_…`（状态里直接放 Int.max 时长，FTB / 叠加在电平 0 时反转） | 同一个 Fatal error |
| `ReducerTests.testN02_loadShowOverlayCountNotFour_…` | SIGTRAP：overlays 必须恰好 4 个 |
| `ReducerTests.testN08_loadShowWithDifferentFormat_…`（1080p60 → 1080p30 / 720p30 / 720p60 / 1080p59.94） | 四种都被收（断言失败 4 处） |
| `ReducerTests.test034_setOverlayDurationMidAnimation_…`（60 拍 fade 第 30 拍改 120 拍） | 第 31 拍 0.258（倒退；应 0.508），断言失败 6 处 |
| `CommandBusTests.testN03_primaryAPIDurationAboveLimit_…`（Codex 的 `primaryAPIDurationBoundaryDecoder` 改名） | fade / setFTBDuration 的 Int.max 都放行（2 处） |
| App `OverlayClearInputTests.testN11_…`（Codex 的 `testOverlaySelectingNoneMustClearRoute` 改名） | 选"（无）"后 input 仍是 1 |

## 改什么（七条；每条写了建议和备选，用户批了照建议做、改了按改的）

### ① 帧率解码抛错（N01）

- `Rational.init(from:)`：分母 0（原来就拒）、**分子或分母是 `Int64.min`** → 抛 `DecodingError.dataCorrupted`。
  其余的 Int64 取值变号、约分都不会越界，`Int64.min` 正好是"约分 / 变号后超出 Int64"的全部情形（分母为负要变号；分子是它时取倒数 `reciprocal` 也要变号），实现按 Int128 约分再查范围，等价于这一句。
- `FrameRate.init(from:)`：解出的有理数分子 ≤ 0 → 抛"帧率必须为正"（约分后分母恒正，所以 −60/−1 = 60 照收）。
- **JSON 形态不变**。代码里直接构造的 `Rational(_:_:)` / `FrameRate(_:)` 的 precondition 留着（那是写错代码，不是数据）。
- 结果：节目文件读到这种帧率 Show.load 抛错（App 走现有的"打开失败"提示 `presentError(…, context: error.open)`，不打开）；API 的命令 JSON（addInput / setInputSource 的屏幕 / 合成源帧率、loadShow 的节目格式）解码失败 → 现有的 400"命令 JSON 无法解析：帧率必须为正"（APIServer 的解码错误分支，131 的目录，不用改）。

### ② 尺寸 / 帧率的范围进 validate（N01 后半 + "验证到的其他行为"）

- 常量 `ProgramFormat.sizeRange: ClosedRange<Int> = 16...8192`（宽、高各自）；`FrameRate.programRange: ClosedRange<Rational> = 1...240`（按 `framesPerSecond` 比，59.94 = 60000/1001 在里面，1/2 不在）。
- `MixerState.validate()`：节目格式不在范围 → 新 `MixerStateError.format(ProgramFormat)`；每路 `.screen(frameRate:)` 给了帧率且不在范围 → 新 `.inputFrameRate(input:)`（nil = 跟节目帧率，不查）。
- 校验器：addInput / setInputSource 的屏幕帧率越界 → 400"帧率必须在 1–240 之间：<帧率>"；loadShow 的节目格式越界 → 同一句 / "节目尺寸必须在 16–8192 之间：<宽>×<高>"（别的不变量错误照旧"节目文件不合法：<错误>"）。reducer 同判、原样返回（`testValidator_agreesWithReducer`）。
- 为什么这两个数：8192 盖住 DCI 8K（8192×4320）和竖屏（1080×1920），Metal 纹理上限 16384 之内；240 fps 是高帧率屏幕 / 采集卡的上限、也让 ④ 的拍数上限有意义；16 只是挡掉 0 / 负数 / 1 像素这种算不出东西的值。
  App 自己的格式选项全在里面（自定义分辨率 320–7680 × 240–4320 取偶、帧率 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60；屏幕输入帧率是下拉），仓库里 8 份节目都是 1920×1080 @ 30 / 60（合成源 30 / 59.94 / 60）。
- **备选**：契约直接用 App 的范围（320–7680 × 240–4320、偶数、帧率只认那七档）——更严，API / headless 想跑 8K 或 120 fps 就进不来；建议不用。
- **附带 ②b（prompt 没列，请用户定）**：合成源 `.synthetic(settings:)` 的 `frameRate` / `width` / `height` 用同一组范围（→ `.inputFrameRate(input:)` / 新 `.inputSize(input:)`，校验器同判）。合成源经 API addInput 和 App 的"测试图案"都能进来，Int64.max 帧率的合成源同样进 TestKit 的时钟换算；①已经挡掉 0 / 负数，剩下的是超大正数与非法尺寸。**建议一起做**（改动几行，同一个函数里）。

### ③ Show 的结构检查放在 makeState 之前（N02）

- 新 `Show.validateStructure() throws`：叠加恰好 4 个（否则 `MixerStateError.overlayCount(n)`）、转场槽恰好 4 个或空（空的由搬迁补齐；否则 `.transitionSlotCount(n)`）。
- 新 `Show.makeValidatedState() throws -> MixerState` = `validateStructure()` + `makeState()` + `validate()`。四处一律走它：`Show.load`（当前版本）、`Show.migrate`、`CommandValidator` 的 loadShow、reducer 的 loadShow（都是先 `migratingLegacyKeys()` 再它）。
- `makeState()` 签名不变（App / headless / TestKit 拿代码建的节目调它）；`MixerState.init` 的 precondition 留着（写错代码，不是数据）。
- 结果：0 个 / 5 个叠加的节目 Show.load 抛 `.overlayCount`（这个错误终于到得了），API loadShow 400"节目文件不合法：overlayCount(0)"，直接发给状态机的 loadShow 原样返回。

### ④ 时长上限（N03 / NS01）

- 常量 `DurationLimits.maxTicks: Int = 864_000`（= 1 小时 @ 240 fps；**按拍不按秒**，60 fps 下 4 小时、30 fps 下 8 小时）。和兼容层 D03 已有的"毫秒参数 ≤ 1 小时"对得上：兼容层在 240 fps 下换出来最多正好 864 000 拍（`CompatHardeningTests` 钉着）。
- 命令：fade / setTransition / setTransitionSlot / setFTBDuration / setOverlay 的时长 > 上限 → 校验器 400"时长必须在 0–864000 拍之间：<n>"、reducer 原样返回。**上限是拒、不是钳**（钳了 API 客户端拿到 200 却不是自己给的值）。
  负数照旧：fade / setTransition / setFTBDuration 原来就拒，文案并进同一句（032 把"必须 ≥ 1"并进范围句的先例）；setTransitionSlot / setOverlay 原来把负数钳成 0，保持。
- `validate()` 查节目里四处时长在 0…上限：`transition.durationTicks`、`transition.slots[].durationTicks`、`ftb.durationTicks`、`overlays[].animation.durationTicks` → 新 `MixerStateError.durationTicks(Int)`。
  负数也拒：App / 命令写不出负时长（reducer 拒或钳），只有手改的文件会有；**备选**是文件里只查上限、负数照读（reducer 本来把 ≤ 0 当"立即到位"）——建议两头都查，与命令那一侧的文案一致。
- 第二道（不靠第一道也不溢出）：reducer 的 `equivalentStart` 先把拍数钳到 0…duration 再转 Int；`ramp` 的拍差用不溢出的减法。直接拿代码造出时长 Int.max 的状态（脚本 / 测试）也不崩。
- **备选**：按秒限（1 小时 × 当前帧率）——上限随格式变，校验器要看状态里的帧率，兼容层已经按毫秒限了；建议按拍。

### ⑤ 叠加"清空"（N11）

- `overlay(channel:on:input: 0)` = **清掉这一路的输入**（`MixerState.noInput`，与 `setPreview(0)` / `setProgram(0)` 的"0 = 无"一致）；`input: nil` 仍是"不换"（`testV7_overlay` 钉着、快捷键 / 兼容层 / Stream Deck 的开关都靠它）；负数仍拒。
  校验器放行 0（原来"输入 0 不存在"）、reducer 置 nil；开关照 `on` 走，与清空互不影响。**不加命令（仍 42 条）**，JSON 形态不变（input 原来就是可选整数）。
- 面板接线：叠加设置的"（无）"发 `input: 0`（`OverlaySettingsModel.setInput` 一行）。
- 行为说明（写进手册）：开着的通道清空，画面立刻没有（没有退出动画——`isVisible` 要有输入）；想淡出就先关再清。
- 谁会发 0：查过 App 的格子按钮 / 转场列开关、Hotkeys / MIDI 的 `ControlAction`、兼容层 `OverlayInput<N>`（`InputReference.resolve` 对 0 回 InputNotFound）、Stream Deck（`num()` 把 0 当没填）——都不会发 0；以前 API 发 0 拿 400，以后是清空。
- **备选 (a)**：新命令 `clearOverlayInput(channel:)`（43 条；命令目录 / api.md / 兼容层要不要映射另说）。语义更显眼，代价是多一条命令、多一份 wire 形态；建议不用。

### ⑥ 运行中 loadShow 不许换格式（N08）

- 校验器 / reducer：loadShow 的节目（搬迁后）`mixer.format` ≠ 当前 `format` → 400"节目格式不同（1920×1080@60 → 1280×720@30）：运行中不能换格式，用打开节目 / 重启 headless"、reducer 原样返回。同格式照载。
- 为什么拒：Engine 时钟、渲染器、App 的 `session.format` 都在构造时定死，loadShow 只换了状态（Codex App 实测：状态 720p30、纹理 1920×1080、时钟 60 fps）。App 的"打开节目"走 `performReplace` 重建 session、不经 loadShow；headless 从文件起；仓库里没有别处发 loadShow（只有 API 客户端）。
- **备选**：App 收到换格式的 loadShow 就重建 session——会停掉在录 / 在推的输出，而且 API 一句话就能把直播停了；建议拒。
- App 端到端那条（Codex `testAPI_LoadShowMustKeepActualAndAdvertisedFormatConsistent`）按 README 归 G12 胶水，改成"400 + 格式不变"。

### ⑦ 叠加动画进行中改时长：按当前进度重锚

- reducer 的 setOverlay：通道正在进 / 出（`startTick` 非 nil）且时长变了 → 照 FTB（020 的 setFTBDuration）用 `equivalentStart` 按当前进度重锚：改的那一拍进度不变、之后按新时长继续；新时长 0 = 立即到位；时长没变（只改位置 / 方式）起点不动。
  原来沿用旧起点，60 → 120 拍时进度从 0.5 掉到 0.258（Codex 列在"验证到的其他行为"里、等产品口径；FTB 同场景早就重锚了）。

## 为什么

- N01 / N02 / N03 是 S0：手改 / 损坏的节目文件、或能发 API 命令的人，一条数据就让承载引擎的进程 SIGTRAP，try / catch 兜不住。修法的共同点：**不可信数据在进带 precondition 的构造 / 会溢出的换算之前就被拒**，并且 API（校验器）、节目文件（Show.load / validate）、状态机（reducer）三处判同一件事——单修一处，另外两条路还能把同样的数据带进来（031 / 032 同一个思路）。
- N08 / N11 是 S1：状态说的和实际画面不一致（格式）、界面上的选项没效果（清空）。
- ⑦ 是同一个 reducer 里的连续性小账，FTB 早就这么做了，顺手对齐。

## 影响谁、怎么迁移

- **契约**：常量 `ProgramFormat.sizeRange`、`FrameRate.programRange`、`DurationLimits.maxTicks`；`MixerStateError` 加 `format` / `inputFrameRate` / `durationTicks`（②b 再加 `inputSize`）；`Show.validateStructure()` / `makeValidatedState()`；Rational / FrameRate 解码多两条拒绝。
  **JSON 形态一个字节不变、不加命令（仍 42；选 (a) 就是 43）**、`Show.schemaVersion` 不升。
- **老节目文件**：帧率 ≤ 0 / Int64.min、尺寸或帧率越界、时长越界、叠加不是 4 个的读进来抛错、不打开（与别的不变量同一处理）。仓库带的 8 份（Samples/ 三份、scenarios/ 四份、契约测试的 g4 老节目）全在范围里，钉一条 `test034_shippedShowsStillLoad`。
- **App**：`OverlaySettingsPanel` 的"（无）"一行（本会话做）；App 端到端的 N08 用例归 G12；别的 App 代码不用改（格式选项、转场自定义时长 0.1–10 s 都在范围里）。
- **headless / TestKit / 兼容层 / Stream Deck**：不用改（兼容层的 1 小时上限在 240 fps 下正好 = 864 000 拍）。别的包的用例查过：没有超上限的时长、没有运行中 loadShow 换格式、没有发 overlay input 0 的。
- **控制层**：`CommandValidator` 加判定与文案；`CommandCatalog` 的 fade / setTransition / setTransitionSlot / setFTBDuration / setOverlay / overlay / addInput / setInputSource / loadShow 摘要写明边界 → docs/api.md 重生成。
- **128 P5-6**（输出编号上限）等本条合入后再开（同样改校验器 / validate）。
- **文档会话（W4-C5）**：报告 §5 列行为变化（叠加"（无）"真的清空、清空开着的通道没有退出动画、运行中 loadShow 换格式被拒、各类上限的 400 文案）。

## 不做

- 输出编号上限（128）；任何阈值；131 的 APIServer / StateFeed；App 别的文件。
- 奇数宽高：NV12 4:2:0 / H.264 一般要偶数，App 的自定义分辨率已经取偶；契约要不要要求偶数没有证据（没见到奇数崩），不在本提案。
- 别的数值字段没逐个查（编码码率 / 关键帧间隔 / 输出宽高、录制分片秒数、重连上限、NDI 抖动缓冲……）；`TickClockSpec` 的 frameDuration 只出现在引擎自己写的统计里，不是输入。

## 顺带发现、请用户定要不要并进本条

1. **②b 合成源的帧率 / 尺寸**（见 ②）。建议并进。
2. **⑧ 音频对齐帧数 `AudioState.alignmentFrames`**：节目文件里没有上限，App 打开节目起 session 时 AudioEngine 算 `Int64((Double(alignmentFrames) × hostTicksPerFrame).rounded())`（AudioEngine.swift:136），2^62 这种值直接 Int64 溢出 SIGTRAP（静态确认，没跑）。
   App 的设置面板自己限在 0–24000（`PreferencesModel.alignmentRange`）。建议并进：常量 `AudioState.alignmentRange = 0...24_000`、`validate()` 查 → 新 `MixerStateError.alignmentFrames(Int)`；没有命令改它，所以只有 Show.load / loadShow 这一侧。
3. **App 叠加设置的"时长（秒）"数字框没有范围**：`OverlaySettingsModel.ticks(seconds:)` 是 `Int((seconds × 帧率).rounded())`，填一个 20 位数就 Double → Int 溢出、App 崩（静态确认，没跑）；④ 落地后填几万秒会被总线 400 拒、面板还显示自己算的值。
   这个文件本会话只许动"（无）"那一处，130 W5-R 也排除了它。建议并进本会话：把秒数钳到 0…`DurationLimits.maxTicks` 对应的秒数（一两行），否则开问题单交下一个 App 会话。
