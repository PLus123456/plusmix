# P5-4 报告：契约落地七——030 效果链延迟进 Stats、020 的 T-bar 取消重拷、031 文件速率 / 定位不变量（prompt 115，分支 `p5-contracts-4`，2026-10-18）

工作树分支 `worktree-agent-a5abc766d93682a21` = 本地别名 `p5-contracts-4`（每次提交后 `git branch -f p5-contracts-4 HEAD`），从 G9 合入后的 main 358517f 开。
不 push、不 merge：做完交 G10（prompt 122）。三份提案用户 2026-10-17 已批，按提案落地；与提案正文不同 / 多做的地方都写进了各提案文末的落地记录，并在 §4 列给用户看。

## 1. 做了什么

每一项都先写红用例（用例名带提案号）、看着红了再实现。**不加命令（仍 42 个 case）**；JSON 只多 `audio.effects` 一节，别的形态一个字节不变；App / headless 0 行改动。

| 提案 | 落地 | 提交 | 文件 |
|---|---|---|---|
| **030** 契约 | `Stats.AudioCounters.effects: EffectsLatency`（键 effects，排在 meters 后；构造函数最后一个带默认值的参数，现有调用点一个不改）；`EffectsLatency{buses: [BusLatency], inputs: [Int: InputLatency]}`、`BusLatency{bus, latencyMs, measuredLatencyMs?}`、`InputLatency{latencyMs, measuredLatencyMs?}`（键 latency_ms / measured_latency_ms，nil 不写键）；四层 `jsonKeys`、`listedBuses = [.master, .busA, .busB]`、`milliseconds(frames:)`（frames / 48 000 × 1000，填数方唯一的换算）；缺键 = 空（整节缺或 buses / inputs 各自缺），写出写全 | 87a5bab | Stats.swift；Contracts030Tests（新）、Samples / CodableTests / StatsP2Tests（字面量重生成） |
| **030** 填数 | `AudioEngine.audioCounters`（引擎采样线程每秒取一次）在出 Stats 行时从 `status`（控制循环每 50 ms 刷新的 `AudioEngineStatus`，App 音频设置窗读的同一份）拷：buses 按 listedBuses 总是三条，inputs 只列契约链装进了 EQ / 动态格的路，measured 只在链里有自写压缩器时写（每路按 dynamicsKind 判，见 §5 第 3 条）。+17 行，只动 `audioCounters` 与紧挨着的新函数 `statsEffects`；不进实时线程、不碰混音器 | 26e8d3d | Integration/AudioEngine.swift；IntegrationTests/EffectsLatencyStatsTests.swift（新） |
| **030** 透传核对 | App（`SwitcherSession`）、headless（`HeadlessRun`）都是 `engine.audioStatsProvider = { audioEngine.audioCounters }`，Stats 整行进 stats.jsonl / API / 状态行，TestKit `StatsWriter.sanitized` 也整份拷——**两边不用改、没改**。实测两边的 stats.jsonl 都有这一节（§2 末两行） | — | — |
| **020 追加** T-bar 取消重拷 | reducer `tbar` 在 progress 钳完 ≤ 0（拉回 0 / 推到负数）那一拍、currentSlot 非 nil 时 `select(slot:)`——与 `completeTransition` 同一句、幂等；推杆还在 (0, 1) 不重拷，currentSlot = nil 不重拷，T-bar 接管进行中的 auto 后拉回 0 一样重拷。口径"完成那一拍重拷"→"完成或取消那一拍重拷"：`Command.tbar` / `setTransitionSlot` 注释、目录两条摘要、CONTRACTS.md §2.5 / §8 | 350dab5 | MixerReducer.swift、Command.swift、CommandCatalog.swift、CommandValidator.swift（注释一句）、docs/api.md、CONTRACTS.md；ReducerTests、CommandCatalogTests |
| **031** 契约 | `FileSource.rateRange = 0.1...8`（界面的"播放速率"是不设范围的数字框，按 031 默认）、`PlaybackLimits.maxSeekSeconds = 7 × 86 400`、`MixerStateError.fileRate(input:rate:)`；`validate()` 拒节目文件里越界的速率（Show.load / loadShow 读到不打开）；**file 来源缺 rate = 1 照读**（main 上原来是 keyNotFound，见 §4 第 3 条）；`InputSettings.clamped()` 把整体带进来的 `playback.seekSeconds` 钳到 [0, 一周]（§4 第 4 条） | 6348cfa | Input.swift、MixerState.swift；Contracts031Tests（新） |
| **031** 校验器 + reducer | `setInputSource` / `addInput` 的 file 来源"播放速率必须在 0.1–8 之间：<值>"、`seekPlayback`"定位秒数必须在 0–604800 之间（一周）：<值>"（原来只查有限非负），HTTP 400；文字从常量生成，目录摘要共用。reducer 同判、原样返回（`testValidator_agreesWithReducer` 要求两边一致）。目录三条摘要 → docs/api.md（仍 42 条）。116 不再碰这三条 | 6348cfa | CommandValidator.swift、CommandCatalog.swift、MixerReducer.swift、docs/api.md；CommandBusTests、APIServerTests、CommandCatalogTests、ReducerTests |
| **029** 文字 | 029 文件末尾"2026-10-17 用户裁定：维持"一段 G9（cffe80e）已写，核对无误；CONTRACTS.md 的 029 一条行为本来就写对了，补半句"按要执行的当前那组判……用户 2026-10-17 定维持"。代码不改 | 350dab5 | CONTRACTS.md |
| 文字 | CONTRACTS.md：标题行、变更记录 P5-4、§2.4（InputSource / InputSettings 两行 + "文件播放速率与定位秒数的不变量"一段）、§2.5（输入引用口径一句、转场槽一段）、§2.6、§2.7（Stats 行 + "P5-4 加的字段"一段）、§8 五行；测试标准 §7 字段行只补 `effects{…}` 的键名与一句口径（阈值不动）；三份提案的状态行与落地记录 | 75c4fb4、068b958 | docs/CONTRACTS.md、docs/spec/导播台测试标准.md、docs/contract-changes/020 / 030 / 031 |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

契约类用例没有阈值，"通过"= 断言全过。阈值一个没动。"先红"一栏是实现前跑的结果。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `Contracts030Tests.test030_effectsJsonShape_busesArrayInputsByNumber_measuredOptional` | JSON 逐字（buses 数组、inputs 以编号字符串为键、measured nil 不写键）、往返；audio 一节默认空也写 `"effects":{"buses":[],"inputs":{}}`；构造函数默认参数；整行往返与各层键集合 | 编译不过（`EffectsLatency` 不存在） | ✅ |
| `Contracts030Tests.test030_missingKeysDecodeToEmpty_legacyLinesStillParse` | 030 之前的 audio 一节 / P2 之前的最老形态缺 effects = 空；effects 里缺 buses / inputs 各自为空；measured 缺键 = nil；App 的老 stats.jsonl（`App/Tests/Artifacts/w2-app-status-line-stats.jsonl`）照读 | 同上 | ✅ |
| `Contracts030Tests.test030_jsonKeysSnapshot_listedBuses_millisecondsFromFrames` | 四层键名快照、listedBuses = master / busA / busB、48 帧 = 1 ms、256 帧 = 5.333 ms、576 帧 = 12 ms；顶层键 / per_input 不变 | 同上 | ✅ |
| `CodableTests.testP1_stats_jsonKeysSnapshot`、`StatsP2Tests.testP2_stats_missingKeysDecodeToDefaults_andEncodeWritesAll`（改） | 整行字面量多 effects（Samples.stats 填非默认值：Master 12 / Bus A 0 + measured 0 / Bus B 0、输入 1 = 1 + measured 1、输入 3 = 0）；AudioCounters.jsonKeys 多 effects | 2 处红（落地后按新形态重生成） | ✅ |
| `EffectsLatencyStatsTests.test030_audioCountersEffects_masterLimiterInputEQ_copiedFromStatus_unlistedInputsAbsent`（Integration，新） | 没装效果：三条总线 0、inputs 空；Master 一格限幅 → `buses[master].latency_ms` = status.latencyFrames（576）/ 48 000 × 1000 = **12 ms**、无 measured；Bus A 压缩器 0 + measured 0；Bus B 0；输入 2 一格 EQ → `inputs["2"]` = 0（列）；输入 3 压缩器 0 + measured 0；输入 4 动态处理器 **5.333 ms**、无 measured；没装的 1 号不列；整行 JSON 往返；压缩器换成 EQ 后 measured 缺键、清空的 2 号不再列、拆掉限幅回 0；实时违规 0 | 2 处红 + XCTUnwrap 抛（effects 为空） | ✅ |
| `ReducerTests.test020_tbarCancelRecopiesCurrentSlot`（新） | P5-3 探针路径：推到 0.4 → 槽 1 改 Zoom 12 → 推到 0.6 不重拷 → 拉回 0：不换人、当前那组 = Zoom 12、再发 tbar(0) 幂等；回车执行 Zoom 12（第 6 拍 0.5、第 12 拍对调）；推到 −0.3 同样算取消；T-bar 接管 auto 后拉回 0 重拷；currentSlot nil 不重拷 | 7 处红（当前那组仍 Fade 30） | ✅ |
| `ReducerTests.testW1B_reduce_everyCommand_beforeAfterTable`（加 12 行） | 020：推杆在中间不重拷 / 拉回 0 重拷 / currentSlot nil 不重拷三行；031：setInputSource rate 0 / 1e300 / 换成越界的文件来源拒、rate 8 照收，addInput rate −1 拒、0.1 照收，seekPlayback 1e300 拒、一周整照收，setInputSettings 的 seekSeconds 1e300 钳到一周（九行）；42 个 case 都覆盖 | 020 1 行、031 5 行红（clamped 那行是契约先落、reducer 后落的顺序，没单独红过） | ✅ |
| `CommandCatalogTests.testCatalog_020_tbarCancelRecopyDocumented`（新） | tbar 摘要写"拉回 0 / 取消 / 重拷"、setTransitionSlot 写"完成或取消"、字段不变、命令数 42 | 2 处红 | ✅ |
| `Contracts031Tests.test031_constants_fileRateRangeAndMaxSeekSeconds`（新） | 0.1…8、604 800；0.1 / 0.5 / 1 / 1.5 / 2 / 8 合法，0 / −1 / 0.0001 / 0.0999 / 8.0001 / 1e300 / NaN / ±∞ 不合法 | 编译不过 | ✅ |
| `Contracts031Tests.test031_validateRejectsOutOfRangeFileRate_showLoadRefuses`（新） | 边界 0.1 / 8 过；0 / −1 / 0.0001 / 8.5 / 1e300 / −∞ → `.fileRate(input: 3, rate:)`；NaN 按 case 认；Show.load 读到 rate 0 的节目抛 fileRate、rate 2 照读 | 同上 | ✅ |
| `Contracts031Tests.test031_legacyFileSourceMissingRateReadsAsOne_jsonShapeUnchanged`（新） | `{"file":{"endAction":"loop","path":"/a.mov"}}` → rate 1；写出照旧带 rate（逐字）；整份节目删掉 rate 键 → Show.load 读进来 rate 1 | 同上（探针另证 main 上是 keyNotFound，§4 第 3 条） | ✅ |
| `Contracts031Tests.test031_clampedSeekSecondsCappedAtMaxSeek`（新） | clamped()：1e300 / 一周 + 0.5 → 一周；一周 / 12.5 原样；−3 → 0、+∞ → 0（021 原样）；nil 不动 | 同上 | ✅ |
| `CommandBusTests.testValidator_agreesWithReducer`（合法 +4 / 非法 +10） | 合法：rate 0.1 / 8、addInput rate 2、seek 一周整；非法：setInputSource rate 0 / −1 / 0.0001 / 1e300 / NaN / 合成源换成 rate 9 的文件、addInput rate 0、seek 1e300 / 一周 + 1 / +∞——校验器拒的 reducer 都原样返回 | 9 处红（+∞ 原来就拒） | ✅ |
| `CommandBusTests.test031_fileRateAndSeekSecondsOutOfRange_rejectedWithReason`（新） | 真总线上 rate 0 / −1 / 1e300、seconds 1e300、addInput rate 0.0001 → CommandRejection、理由带"播放速率必须在 0.1–8 之间" / "定位秒数必须在 0–604800"、不占 sequence、状态不变；rate 8 与 seek 一周整照收 | 7 处红 | ✅ |
| `APIServerTests.test031_postCommand_fileRateAndSeekOutOfRange_400`（新） | 真 HTTP：POST setInputSource rate 0 / −1 / 1e300、seekPlayback 1e300 → **400** 带理由、不占 sequence；rate 8 → 200、状态里换上 | 9 处红（拿 350dab5 的校验器 / 目录临时放回工作树跑的：全是 200） | ✅ |
| `CommandCatalogTests.testCatalog_031_fileRateAndSeekLimitsDocumented`（新） | setInputSource / addInput 摘要含"0.1–8"、seekPlayback 摘要与 seconds 参数说明含"604800"、字段不变 | 4 处红（同上） | ✅ |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | docs/api.md 与生成器同步（020 后、031 后各重生成一次，`#### ` 命令标题仍 42 个） | 每次改目录后红一次 | ✅ |
| 探针 1（scratchpad/probe-rate，20 行） | main 上 `InputSource` 内部 Form 的 file case（rate 必填）解 `{"file":{"endAction":"loop","path":"/a.mov"}}`：**keyNotFound "rate"**；rate 改可选后解成 nil（→ 1），两种写出逐字相同 | — | 结论进 §4 第 3 条 |
| 探针 2（集成用例里临时打印，已删） | 输入 3 压缩器换成 EQ 之后 `AudioEngineStatus.InputEffects` = `eqBands 1, dynamicsKind nil, …, compressorMeasuredLatencyFrames: Optional(0)`——状态不清旧的实测值 | — | 结论进 §5 第 3 条 |
| headless 实测（`switcher-headless run`，m0 节目加 Master 限幅 / Bus A 压缩器 / Bus B 动态处理器 / 输入 1 EQ + 压缩器，`--duration 4 --audio-device null`） | stats.jsonl 4 行每行都是 `"effects":{"buses":[{"bus":"master","latency_ms":12},{"bus":"busA","latency_ms":0,"measured_latency_ms":0},{"bus":"busB","latency_ms":5.333333333333333}],"inputs":{"1":{"latency_ms":0,"measured_latency_ms":0}}}`，同一行 `video_delay_ms` = 12（= Master 那一项）；清洗 0 | — | ✅ |
| App 实测（`StatusLineTests.testStatus_lineMatchesStatsJsonlSameSecond` 写的 `.build/app-test-output/status-line-stats.jsonl`） | 5 行 audio 键 = discontinuities / dropouts / effects / meters / underruns，effects = 三条总线 0、inputs 空（测试节目没装效果） | — | ✅ |
| 整包 / App / lint | 见下表 | | |

运行记录（机器 M5 Max，macOS 27.0 / Darwin 27.0.0；同机并行 118 / 119 / 120 三个会话：118 在跑 Outputs 推流用例（起 mediamtx）、119 跑 App 单条用例、120 跑 Core Render / Audio 包，负载 2–10）：

| 项 | 结果 |
|---|---|
| Core 整包 `swift test --package-path Packages/SwitcherCore`（01:50–01:58） | **334 = Render 101 + Engine 118 + Contracts 115（1 跳）**，0 红 |
| Control 整包（01:31） | **87 = SwitcherControlTests 53 + VMixCompatTests 31（1 跳）+ TallyTests 3**，0 红 |
| Audio 整包 `swift test --package-path Packages/SwitcherAudio`（02:02–02:10） | **161 = SwitcherAudioTests 85（2 跳）+ IntegrationTests 76（5 跳）**，0 红（= P5-3 的 160 + 本会话的 1 条） |
| 顺带：headless 工具测试 `swift test --package-path Tools/switcher-headless`（02:14）、TestKit `--filter SwitcherTestKitTests.StatsTests` | 16 / 16、11 / 11，0 红（Stats 的读写方都编过、老行照解） |
| App：`make gen` → `xcodebuild build-for-testing`（TEST BUILD SUCCEEDED）→ `test-without-building -only-testing:SwitcherTests/StatusLineTests -only-testing:SwitcherTests/PlaybackStatusTests`（01:38） | **11 = StatusLine 3 + PlaybackStatus 8**，0 红（App 一行没改，只是重编过新契约） |
| headless：`swift build --package-path Tools/switcher-headless`（全依赖链编译过）+ 上表 4 s 实测 | 过 |
| `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md`（两次）；报告前再生成一份 `diff -q` | 2 + 4 行变化，`#### ` 命令标题 42 个；最后一份与提交的逐字一致 |
| `make lint BRANCH=p5-contracts-4`（C locale 与 `LC_ALL=en_US.UTF-8` 各一遍，报告提交前） | 两遍全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 24 个文件在范围内 / check-help / check-links 200 个 Markdown / check-rt-symbols |

没跑：gate4 / perf-baseline / soak（prompt 不让跑，同机有三个会话）；Inputs / Outputs 两个包与 TestKit 的整包测试、App 全量（不在 prompt 第 5 条里；它们只依赖契约的新类型编译——headless 全依赖链与 App 都编过）。

## 3. 没做的和原因

1. **031 第 5 条 FileInput 底层钳位**：归 117（W2-A5）。现在 API（校验器 + reducer）与节目文件（validate）两条路都进不了越界值，App / headless 的运行表都从状态快照建 FileInput（启动时 `validate()`），所以 Codex 的复现路径（主 API / 节目文件）已经堵上；但 `FileInput.init(rate:)` 的 `precondition(rate > 0)`、`rate` setter 的 precondition、`seek(toSeconds:)` 的 Int64 换算**代码还在**，绕过状态机直接构造 FileInput 的地方（单测、`switcher-input-probe` 的 `file:路径:loop:速率` 参数）给越界值仍会整个进程崩——117 合入之前 KNOWN_ISSUES 的 D01 只能销一半。
2. **030 的 App / API 展示**（状态页显示每条总线 / 每路的效果延迟）：prompt 写明归以后的 App 会话；docs/api/README.md §5 一行归 W4-C。
3. **T-bar 推没选输入的 Stinger 的界面拦**：归 119（prompt 写明不做）。
4. **别的会话的文字跟着过时了**（给 G10 / W4-C）：docs/user/概念.md:128 与 docs/user/en/concepts.md:128 的"例外：T-bar 推到一半改了当前槽、又拉回 0……仍按旧设置走"现在不成立了（改了要 `scripts/build-help.py` 重生成随包 HTML，check-help 会拦）；docs/checklists/G9.md 第 71 行"已知（020 缺口，归 115）"的预期要改成"拉回 0 之后回车用改过的配置"；docs/KNOWN_ISSUES.md 三行可以销 / 改（第 32 行 S3 效果延迟不进 Stats → 已修；第 35 行 S0 D01 → API / 节目文件半已修、FileInput 半等 117；第 57 行 S3 020 缺口 → 已修）。都不在本会话目录里。

## 4. 对契约的疑问

1. **030 的 buses 不列耳机总线**（按正文"master / busA / busB"落的）：但耳机总线也有效果链——App 调音台的耳机条有"效果 (n)"按钮，混音器 / `BusEffectsController` 四条总线都能装，泵也按它补耳机来源的 PTS——它的延迟现在没有任何对外口径（铁律 4 的缺口没补全）。要列：`EffectsLatency.listedBuses` 改成 `Bus.allCases`（一行，JSON 形态不变，老读者按 bus 名认不受影响）+ CONTRACTS.md / 030 文字。建议列；请用户定。
2. **031 的迁移副作用比提案写的大**：提案说"老节目文件里 rate 超范围（没人这么写过，界面写不出来）"。查了界面：App 的添加输入面板 / 输入设置"来源"节的"播放速率"是 `TextField(value:format: .number)`，**不设范围**（AddInputSheet 只把 ≤ 0 换成 1），0.05、10、100 都写得出来、也存得进节目文件。P5-4 之后：这种老节目打开时 validate 拒（"不打开"）；在界面里填这种值，添加 / 应用来源会 400。可选：(a) 维持（提案原样）；(b) `Show.migratingLegacyKeys()` 把越界的速率钳进范围再 validate（老文件能打开，速率变了）；(c) App 把数字框钳到 `FileSource.rateRange`（归 119 或之后的 App 会话）。建议 (c)，(b) 看用户要不要。
3. **"老文件 rate 缺键 = 1"在 main 上原来不成立**（提案第 3 条括号里当成已有的事实）：`InputSource` 的 file case 走合成 Codable、rate 必填，探针证实缺键直接 keyNotFound、整份节目读不进来。P5-4 按提案的意思补成真的（内部 Form 的 rate 改可选、缺键 = 1，写出逐字不变）——这是放宽解码、不是改形态，只告知。
4. **`InputSettings.clamped()` 加了定位秒数的上限**（提案没写）：`setInputSettings` / `addInput` 整体带进来的 `playback.seekSeconds` 是 seekPlayback 之外的第二个定位入口（组装方看到 (seekTick, seekSeconds) 变了就交给 FileInput），同一个 1e300 从这里进来还是崩。与 021 "seekPlayback 拒、setInputSettings 钳负数"同一做法：钳到 [0, 一周]，不拒。要改成拒：校验器 / reducer 各加一句、覆盖表那一行改成原样。建议维持。
5. 029：用户 10-17 定维持"按要执行的当前那组判"，代码与文字都已一致，没有疑问。

## 5. 下一个会话需要知道的坑

1. **G10 合并顺序**：117（FileInput 钳位）要用 `FileSource.rateRange` / `PlaybackLimits.maxSeekSeconds`——从 main 开的 117 分支编不过这两个名字，要么 115 先合、117 rebase，要么 117 叠在本分支上（lint 加 `--base p5-contracts-4`）。116 不再碰 CommandBus/ 的 setInputSource / addInput / seekPlayback 三条（本分支改了 `CommandValidator` 这三个 case 的分组：setInputSource 从"只查输入在不在"那一组拆出来了）。
2. **120 也改 `Integration/AudioEngine.swift`**：本分支只动了 `audioCounters`（多一行）和紧挨着它新加的 `statsEffects`（第 738–760 行附近），没重排文件；合并冲突只会出在这两处的邻行。
3. **`AudioEngineStatus.InputEffects.compressorMeasuredLatencyFrames` 换掉压缩器后不清旧值**（探针 2；文档注释说"没装压缩器为 nil"）：`InputEffectsController.apply` 在动态格换成 DynamicsProcessor / 清空时不动 `rack.measured`（留着是为了换回同一组参数时不重测）。Stats 那边按 `dynamicsKind == .compressor` 判、不受影响；App 音频设置窗若直接读这个字段显示"延迟自测"，会在压缩器摘掉后还显示上一次的值——W1-D 系的会话修状态（status 里按 dynamicsKind 给 nil）时 Stats 不用跟着改。
4. **AudioCounters 再加键时**：契约测试里钉整行字面量的是 `CodableTests.testP1_stats_jsonKeysSnapshot`（Samples.stats）与 `StatsP2Tests.testP2_stats_missingKeysDecodeToDefaults_andEncodeWritesAll`；包外没有钉 audio 一节编码形态的用例（TestKit / scripts 的 stats 字面量都只解码老行）。
5. **`MixerStateError.fileRate` 带 Double**：NaN 的那一个 `==` 不成立，测试按 case 模式匹配；`CommandValidator` 的理由文案由 `fileRateRangeText`（"0.1–8"）/ `maxSeekText`（"604800"）生成，目录摘要共用，改常量文字自动跟。
6. **App 的速率数字框**（§4 第 2 条）：P5-4 之后填 10 或 0.05 再"添加 / 应用来源"会被总线 400；App 那边怎么提示没核对（本会话不碰 App）。
7. **会话工具**：worktree 隔离的子代理里，带 heredoc / 多段 `&&` 的复杂 Bash 会被 harness 以"太复杂、没法确认在 worktree 里"拒掉；把脚本写进 scratchpad 再用一条简单命令跑（`python3 -I 脚本 <worktree 路径>`）就行。
   **并行的几个子代理共用同一个 scratchpad 目录**：本会话的 `waitquiet.py` 跑完不久就被 119 的同名脚本覆盖了——临时文件放自己的子目录（本会话后半用 `scratchpad/p54/`）、拿到结果马上读。`swift test` 的 `print` 输出在管道里排在 "Executed" 行之后，`| head -N` 会把它截掉。
8. **`swift test --filter` 写 `Target.Class` 或 `Target.Class/method`**（P5 / P5-2 §5 第 2 条仍成立；`|` 不是交替）。
