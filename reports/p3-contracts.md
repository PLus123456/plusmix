# P3 契约落地二报告（分支 p3-contracts，worktree 分支 claude/p3-contracts-phase-2-86a7c4，同一提交）

prompt：docs/plan/prompts/61-P3-契约落地二.md。落地提案 **007 / 008 / 009 / 010 / 012 / 013** 与 **每路 AFV 参与开关**（012 的"顺带的疑问"1），
外加用户 2026-09-22 按 G4 报告 §8 第 4 / 6 条定下的几条口径。基线：main `367bbb9`（G4 合入后）。
提交（`git log main..p3-contracts`）：
`cb85fbe`（契约）→ `f126327`（状态机 / 命令总线 / 渲染器）→ `03e186f`（输入 / 音频 / 输出 / TestKit / headless）→ `5f01249`（App）→ `c73aab2`（测试与 docs/api.md）
→ `2a835bb`（CONTRACTS.md 与六个提案状态）→ `0e2d9cf`（App 测试改用正式字段）→ `e3fa37d`（RenderSlot 注释）→ `44d9144`（过渡键搬迁对脏数据的加固）
→ `d0f6a83` / `d59f993`（TestKit：displays 用例、hostTimeMs 掩码、抖动阈值 0.8 → 1.2 经用户批）→ `ffc727c`（实时渲染器端到端验自动填帧）→ 报告若干。

机器：Apple M5 Max / macOS 26.6.2（25G83）/ Xcode 27。

---

## 1. 做了什么

### 提案 007：`AudioState` 加对齐延迟与监听点 + 三条口径

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/MixerState.swift` | 加 `MonitorPoint`（String / Codable：preDelayLine 默认、postDelayLine）；`AudioState` 加 `alignmentFrames: Int = 2048`（`AudioState.defaultAlignmentFrames`）、`monitorPoint: MonitorPoint = .preDelayLine`，写显式 `init(from:)`（两项 `decodeIfPresent`），加 `jsonKeys` |
| 同上 | B 的三条口径进注释：`OutputState.enabled` 只对 headless 场景文件生效 / App 打开节目时清掉 record / stream 的 enabled；`RecordSettings.directory` 的相对路径（headless 相对进程工作目录、App 相对 `~/Movies/Switcher`） |
| `docs/CONTRACTS.md` §2.5 | 同上三条 + 录制器停止边界（`Recorder.stop(atTick:)` / `setStopTick` / nil 的含义） |
| `SwitcherAudio/Integration/AudioEngineConfiguration.swift` | `monitorPoint` 的类型按模块限定成 `SwitcherAudio.MonitorPoint`（两个模块同名），加 `SwitcherAudio.MonitorPoint.init(_ point: SwitcherContracts.MonitorPoint)` 互转 |
| `App/Sources/Engine/AudioRuntime.swift` | `init(stateMachine:device:audioState:)`：从 Show 取两项填 `AudioEngineConfiguration`；退到空设备时也保留这两项 |
| `Tools/switcher-headless/.../HeadlessRun.swift` | 同上从 `show.audio` 读 |

**Command 不加**（提案原文）：两项改了要重建延迟线，走 `loadShow` / 设置面板。
**headless 没有 `--audio-align` / `--audio-monitor` 这类覆盖参数**（命令行里 `--audio-*` 只有 `--audio-device` 选设备），所以"现有参数保留为覆盖"这一条落到"直接从 show 读"；要加覆盖参数是 W4 的事，不在 P3 范围。

### 提案 008：`InputSource` 的 DeckLink / NDI 参数

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/Input.swift` | 加 `DeckLinkConnection`（sdi / hdmi / opticalSDI / component / composite / sVideo）与 `NDIBandwidth`（highest / lowest / audioOnly）；`case decklink(deviceID:connection:)`、`case ndi(sourceName:bandwidth:jitterBufferFrames:)`；`InputSource` 写显式 `init(from:)` |
| 同上 | `deviceID` 三种格式（`peid:<int64>` / `model:<型号>#<序号>` / 空串）写进 case 注释（W3-A §4 第 3 条） |
| `SwitcherInputs/DeckLink/DeckLinkInput.swift` | `Options.connection` 改成契约类型；`init(config:)` 从 case 取，Options 非 nil 时以 Options 为准；`cfg.connection` 经位集转换 |
| `SwitcherInputs/DeckLink/DeckLinkDevices.swift`（胶水 20 行） | 包里的 `DeckLinkConnection` 是**位集**（一台卡支持哪几个口），加 `init(_ single:)` 与 `supported` 与契约的**单个口**互转 |
| `SwitcherInputs/NDI/NDIInput.swift` | `Bandwidth` 加 `init(_ b: NDIBandwidth)` / `contractValue`；`init(config:)` 从 case 取带宽与抖动缓冲 |
| `App/Sources/Engine/InputFactory.swift` | 不用改（本来就走 `init(config:)`） |
| `Tools/switcher-headless/.../HeadlessRun.swift` | NDI 构造点从 case 取带宽，`--ndi-jitter-frames` 与默认（1）不同才覆盖 |

**`InputSource` 的显式 `init(from:)` 怎么做到"其它 case 一个字节不变"**：只有 `decklink` / `ndi` 自己解（`nestedContainer` + `decodeIfPresent`），其余 case 交给一个字段形态逐字相同的内部 `Synthesized` 枚举的合成解码器。编码仍是合成的（Swift 对枚举的 Optional 关联值用 `encodeIfPresent`，所以 `connection: nil` 不写键）。键名快照在 `ContractsP3Tests.testP3_008_*` 里钉住。

**"Options 保留为覆盖"的判据**（写进了注释，有用例）：
- DeckLink 的 `connection` 默认 nil，**非 nil = 调用方显式给了**；
- NDI 的 `bandwidth` / `jitterBufferFrames` 默认值与契约默认相同（highest / 1），只能按"**与 Options() 的默认不同 = 显式给了**"判。

### 提案 009：`KeyerSettings` 口径（只改文档）

四个字段的口径抄进 `Input.swift` 的 `KeyerSettings` 注释与 `docs/CONTRACTS.md` §2.4 的表；类型 / JSON 键 / 默认值一个没动，渲染器也没动。

### 提案 010：叠加装饰 / 滑入方向 / 多画面布局正式字段

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/MixerState.swift` | `OverlayState` 加 `border: OverlayBorder?` / `anchor: OverlayAnchor = .center` / `previewOn: Bool = false`（显式 `init(from:)`）；`OverlayAnimation` 加 `slideFrom: OverlayEdge?`；新增 `OverlayBorder` / `OverlayAnchor`（带 `unitPoint`）/ `OverlayEdge`；`OutputSettings` 加 `multiview: MultiviewLayoutSettings?`，新增 `MultiviewLayoutSettings` / `MultiviewCell` |
| `SwitcherContracts/Command.swift` | **A4：加 `setOverlayDecoration(channel:border:anchor:previewOn:)`** |
| `SwitcherEngine/State/MixerReducer.swift` | `setOverlayDecoration` 分支（通道不在 1–4 拒绝；三项整体替换） |
| `SwitcherRender/Renderer/CompositorPasses.swift` | `OverlayDecoration.border(for:config:)` 正式字段优先、效果格作后备；`encodeOverlays(…, previewPass:)` 按每通道 `previewOn` 过滤；`OverlayRenderer.slideEdge(for:from:)` 与 `placement` 用 `slideFrom` / `anchor` |
| `SwitcherRender/Renderer/MultiviewLayoutTable.swift` | `settings(in:)`、`parse(settings:…)`（正式字段，零分配）、`parseCustom([MultiviewCell])`；原过渡键路径保留作后备，两者共用 `applyPreset` / `reset`；`MultiviewLayout.layoutSettings(in:)` / `placements(settings:…)` |
| `SwitcherRender/Renderer/MetalRenderer.swift`（胶水） | `overlaysInPreview` 的注释改成"全部预览总开关" |
| `Tools/switcher-headless/.../G4Factory.swift` | `multiviewLayout` 返回 `MultiviewLayoutSettings`；`scenarios/g4-show.json` 用 `make-show --preset g4` 重新生成 |

**A4 的决定与理由**：加新命令 `setOverlayDecoration`，不扩 `setOverlay` 的参数——后者会改它已经在用的 JSON 形态（W2-C 的客户端、docs/api.md 的样例都在用）。多画面布局走现有 `setOutputSettings`（整体替换设置，本来就能改 `multiview`）。

**旧 Show 一次性转换的决定与理由**：放在**契约的 `Show.load(from:)` 里**（`Show.migratingLegacyKeys()` + `OutputSettings.migratingLegacyKeys()`），不放 App。理由：App、headless、测试、`Show.migrate` 都经这一个入口，不用各写一份；幂等（正式字段已有值的不动），搬完清旧键，写出只写正式字段。三条搬迁：
- `OutputSettings.extra["layout"]` → `.multiview`（`MultiviewLayoutSettings(legacyValue:)`）；
- `OutputSettings.extra["displayID"] / ["fallbackToMain"]` → `.display`（只有出现过旧键才搬，按旧键原值，不改语义）；
- 某路输入效果链里第一个启用的 `EffectSlot(id: "border")` → **用到这路输入的叠加通道**的 `OverlayState.border`；没有通道用它就不动（渲染器的后备路径还认它）。

### 提案 012 + 每路 AFV 开关

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/Command.swift` | 加 `setMonitorMode` / `setBusEffects` / `setOutputEnabled` / `renameOutput` / `setInputSource`（连同 010 A4 共六条，**27 → 33**） |
| `SwitcherContracts/Input.swift` | `InputAudioSettings` 加 `afv: Bool = true`，写显式 `init(from:)`（全部键 `decodeIfPresent`），加 `jsonKeys` |
| `SwitcherEngine/State/MixerReducer.swift` | 五条新分支：`setOutputEnabled` 对 record / stream **拒绝**；`setInputSource` 只换 source（编号 / 名字 / 设置 / PGM / PVW / 叠加引用全保留）；其余按提案表 |
| `SwitcherEngine/Audio/AudioControlEvent.swift` | `AudioProgramGate.gains`：`!afv \|\| !input.settings.audio.afv` → 1 |
| `SwitcherControl/CommandBus/CommandValidator.swift` | 对应分支（`setOutputEnabled` 对 record / stream 给出理由） |
| `SwitcherControl/CommandBus/CommandCatalog.swift` | `CommandKind` 六个 case + 六条目录；`docs/api.md` 重生成 |
| `SwitcherAudio/Integration/AudioEngine.swift` | `crossfade` / `tbarProgress` 跳过 afv = false 的路（`participatesInAFV`）；`inputAudioSettings` 事件里那一位翻了就 `applyGates()`；`registerInput` / `applyGates` 的兜底也带上这一位 |
| `App/Sources/UI/MixerPanelView.swift` | `setMonitorMode` / `setBusEffects` 改发新命令（不再 `loadShow` 整体替换）；加 `setInputAFV`（走 `setInputSettings`） |
| `App/Sources/Settings/OutputSettingsPanel.swift` | `replace()`（删了重加）换成 `setEnabled` → `setOutputEnabled`、`rename` → `renameOutput` |
| `docs/CONTRACTS.md` §2.4 | C 的 `EffectSlot` id 与参数键表、链顺序 = 处理顺序、`enabled = false` 旁路 |

**W3-C 的运行表验证**：`ExternalDisplayManager.reconcile` 与 `AuxOutputRuntime.reconcile`（虚拟摄像头）本来就按 `enabled` 增删，改用 `setOutputEnabled` 之后运行表看到的是"同一个输出的 enabled 翻转"而不是"删除 + 同编号重加"，外部显示窗口不再闪一下（`ExternalDisplayTests.testManager_reconcile*` 覆盖了增删改路径）。
**NDI 发送在 App 里还没接线**（`OutputRuntime` 的 `.ndi` 分支只给 Stats 占一个 `.idle`，注释写着"W3-A 的输入之后"），所以这一条现在只对外部显示与虚拟摄像头成立；NDI 发送接线时按 `enabled` 起停即可。

### 提案 013：显示类输出进 Stats + 外部显示设置正式字段

| 文件 | 改动 |
|---|---|
| `SwitcherContracts/Stats.swift` | 加 `display: [DisplayEntry]`（output / kind / frames / dropped / state），`Stats` 写显式 `init(from:)`（`display` 缺键 = 空数组），`jsonKeys` / `DisplayEntry.kinds` / `.states` |
| `SwitcherContracts/MixerState.swift` | 加 `DisplayOutputSettings`（displayID? / fallbackToMain = true）、`OutputSettings.display` |
| `SwitcherEngine/Engine/Engine.swift`、`EngineCounters.swift`（胶水） | `displayStatsProvider` + `StatsAssembler.make(… display: …)` |
| `SwitcherOutputs/External/ExternalDisplayManager.swift` | `statsEntries`：每个窗口一项，frames = `MetalDisplayView.presentedFrames`，state showing → presenting、waitingForDisplay / fallbackToMain → noDisplay |
| `SwitcherOutputs/External/ExternalDisplaySpec.swift` | 读：正式字段优先、过渡键作后备；写：只写正式字段并清旧键 |
| `SwitcherOutputs/VirtualCamera/VirtualCameraOutput.swift` | `statsEntry(output:)`：frames = framesSent，dropped = 队列满 + 无设备 + sink 三项之和，idle / searching → waitingExtension / connected → publishing / stopped |
| `SwitcherTestKit/Stats/StatsSummary.swift` | 加 `displays: [DisplaySummary]?`（按 output + kind 分组） |
| `App/Sources/Engine/AuxOutputRuntime.swift` | `statsEntries`（外部显示 + 虚拟摄像头 + 界面注册的两项）、`uiDisplayEntries` |
| `App/Sources/Engine/StatsHub.swift` | `Mutex<[DisplayEntry]>` 盒子 + `engine.displayStatsProvider`；`update(displays:)` |
| `App/Sources/UI/MainWindowController.swift`（胶水） | 注册 monitor（output 0）与 multiviewWindow 两项 |
| `App/Sources/Settings/OutputExtras.swift` | `displayNumber(of:)` 正式字段优先；删掉 `displayNumber` / `multiviewLayout` 两个键常量 |
| `Tools/switcher-headless` | 不设 provider = 空数组 |

**013 的最终形态 = 提案原样，没有微调**。两处实现上的取舍写在 §3。

### W3 各报告等拍板的口径（只改注释 / CONTRACTS.md，渲染器一处例外）

| 口径 | 落在哪 |
|---|---|
| W3-A §4 第 2 条：网络源 `Frame.pts` = 到达 − 抖动 + J × 帧间隔，音频块同加 | `Video.swift` 的 `Frame.pts` 注释 + CONTRACTS §3（与文件输入的"拍点 − 半帧"并列） |
| W3-A §4 第 4 条：noSignal / error 的分界 = 会不会自己好 | `Input.swift` 的 `InputState` 注释 + CONTRACTS §2.4 |
| W3-A §4 第 3 条：`deviceID` 三种格式 | `InputSource.decklink` 注释 + CONTRACTS §2.4 |
| W3-B §4 第 3 条：`cutAtTick` 0 与 1 等价、≥ durationTicks = 完成时换 | `StingerParams.cutAtTick` 注释 + CONTRACTS §2.5 |
| W3-B §4 第 4 条：`OutputSource.multiview` 在自定义格子里被忽略 | `OutputSource` / `MultiviewCell` 注释 + 渲染器 `parseCustom` 真忽略（有用例） |
| W3-B §4 第 5 条：`RenderedFrame.preview / multiview` 按状态自动填 | `Render.swift` 注释 + CONTRACTS §3 + `CompositorPasses.wants(_:in:)` / `MetalRenderer` 取或 |

---

## 2. 每个测试 ID 的数值 / 阈值 / 通过否

（P3 不动任何阈值，也不跑性能指标；下面是本会话新增 / 受影响的用例。`make test` 与 `make gate4-run` 的整体结果在 §2.4 / §2.5。）

### 2.1 `SwitcherContractsTests`（新增 `ContractsP3Tests`，10 个用例）

| 测试 | 验什么 | 结果 |
|---|---|---|
| `testP3_007_audioStateAlignmentAndMonitorPoint` | 默认 2048 / preDelayLine；往返；老快照缺键按默认解；写出写全 | ✅ |
| `testP3_008_inputSourceDeckLinkAndNDIParameters` | 新形态往返与 JSON 快照；`{"ndi":{"sourceName":"x"}}` → highest / 1；`{"decklink":{"deviceID":"…"}}` → connection nil 且写回不带键；camera / screen / file / image / audio 五个 case 的 JSON 逐字不变；未知键仍抛错 | ✅ |
| `testP3_inputAudioSettingsAFVDefaultsToTrue` | 没有 afv 键的老文件 → true 且等于默认值；往返；写出写全；`clamped()` 不碰它 | ✅ |
| `testP3_010_overlayDecorationAndMultiviewFields` | `OverlayState` / `OverlayAnimation` / `MultiviewLayoutSettings` 的 `jsonKeys`、默认值、老叠加缺键按默认解、往返；`{"safeArea":true}` 这种缺键对象也能解 | ✅ |
| `testP3_010_overlayAnchorUnitPoints` | 九个锚点的归一化位置 | ✅ |
| `testP3_013_displayEntryAndDisplaySettings` | `DisplayEntry` / `DisplayOutputSettings` 的键名与 JSON 快照、缺键默认值 | ✅ |
| `testP3_012_commandCaseCountAndJsonShapes` | 33 个 case 各有样例；六条新命令的 JSON 形态快照；`setOverlay` 的老形态逐字不变 | ✅ |
| `testP3_oldShowFilesStillLoadWithSameSemantics` | `scenarios/g3-show.json` 与改写前的 `g4-show.json`（存进 `Tests/SwitcherContractsTests/Fixtures/g4-show-before-p3.json`）都能解；后者的 `extra["layout"]` 搬进正式字段后 **10 个格子逐个相同**，且与改写后的 `g4-show.json` 的 `multiview` 字段**完全相等**；inputs / overlays / audio 也都相同 | ✅ |
| `testP3_migratingLegacyKeysIsIdempotentAndPrefersOfficialFields` | 三条搬迁 + 幂等 + 正式字段优先 + 没有叠加用到该输入时效果格留着 | ✅ |
| `testP3_oldStatsLinesStillParse` | 老 stats.jsonl 每行仍能 `parse(line:)` 且 `display == []` | ✅ **17 份文件、12 067 行全部可解**（`App/Tests/Artifacts/` 里留档的 1 份 + G2/G3/G4 跑过的 16 份，从别的 worktree 的 `.build/gate*/` 拷进本工作树的 `.build/gate*/`，不入库） |

原有用例里改了字面量的三处：`testP1_stats_jsonKeysSnapshot`（顶层键加 `display`、整行字面量重生成）、`testP2_stats_missingKeysDecodeToDefaults_andEncodeWritesAll`（老行解出 `display == []`、写出带 `"display":[]`）、`Samples`（每个新字段都填非默认值，六条新命令各加样例，`commandCaseCount` 27 → 33）。

### 2.2 `SwitcherEngineTests` / `SwitcherAudio` IntegrationTests

| 测试 | 验什么 | 结果 |
|---|---|---|
| `ReducerTests` 覆盖表 | 六条新命令各至少一行（生效 / 拒绝）；`covered.count == 33` | ✅ |
| `testP3_setInputSource_keepsNumberNameSettingsAndReferences` | 换来源后编号 / 名字 / 设置 / PGM / PVW / 叠加引用不变；对照 `removeInput` 会清引用 | ✅ |
| `testP3_newCommands_sameValueLeavesStateUnchanged` | 五条命令给相同值时状态原样（回执 applied = false 的依据） | ✅ |
| `testA_afvPerInputOffKeepsGainOne`（纯函数） | afv = false 的路：空闲 / PGM 切走 / 转场中 / 自己在 PGM 上都 = 1；全局关时全部 1 | ✅ |
| `testA_afvPerInputChangeEmitsInputAudioSettings` | 改那一位会发 `inputAudioSettings` 事件 | ✅ |
| `testA_afvPerInputOffKeepsGainOne`（真混音器，IntegrationTests） | `AudioEngineStatus.afvGain` 恒 1；转场 500 ms 内逐块 RMS 不动（容差 5%）；全局 AFV 关 / 开两种 | ✅ |
| `testA_afvPerInputToggleAtRuntime` | 运行中经 `setInputSettings` 翻那一位，门控增益立刻跟着变 | ✅ |

### 2.3 `SwitcherRenderTests` / 输入 / 输出 / 控制

| 测试 | 验什么 | 结果 |
|---|---|---|
| `testP3_borderOfficialFieldMatchesEffectSlotPixelForPixel` | 正式字段与效果格给同一边框时**逐像素相同**（默认白边与红边 0.02 两组）；正式字段优先；宽度钳到 0–0.1 | ✅ |
| `testP3_previewOnShowsOnlyThatChannel` | 一路都没开 → PVW 纯输入；只开通道 1 / 只开通道 3 各只出现那一路；总开关 = 两路都开 previewOn（逐像素相同）；PGM 不受影响 | ✅ |
| `testP3_slideFromEachEdge` | 四条边的位置逐个对（精度 1e-9）、尺寸不变；不给时仍是"最近的边" | ✅ |
| `testP3_zoomAnchor` | center（默认）/ topLeft / bottomRight 的缩放中心；progress = 1 时九个锚点都回原 rect | ✅ |
| `testP3_officialMultiviewFieldMatchesLegacyExtraKey` | 五个预设 + 自定义格子两条路径**格子表逐字相同**、渲染**逐像素相同**；正式字段优先；`.multiview` 格忽略；编号 < 1 / 空 rect 忽略；超 64 格截断 | ✅ |
| `testP3_renderedFramePreviewAndMultiviewFollowOutputs` | `CompositorPasses.wants` 的六种组合（enabled / source / kind） | ✅ |
| `testMultiview_layoutTableParseDoesNotAllocate` | 把正式字段那条路径也加进去，20 次解析 **SwitcherRender 自身 0 次分配** | ✅ |
| `V8ReferenceTests` 全部 | 参考图不变（本会话没改任何默认渲染行为） | ✅ 72 个渲染用例全绿 |
| `DeckLinkSourceParametersTests`（5 个，不要硬件） | 从 case 取 Options、老文件 connection nil、Options 覆盖 case、位集互转、kind 不符抛错 | ✅ |
| `NDISourceParametersTests`（5 个，不要 SDK） | 同上（带宽 / 抖动缓冲）；`{"ndi":{"sourceName":"x"}}` → highest / 1 | ✅ |
| `testP3_013_specRoundTripsThroughOfficialDisplayField` | 写只写正式字段、读正式字段优先、过渡键作后备、"什么都没有"时与 P3 之前同义 | ✅ |
| `ExternalDisplayTests.testManager_reconcile…`（扩了 statsEntries 段） | 每窗口一项、按编号升序、state 在 013 列表内、frames 随呈现递增且与 `presentedFrames` 同源、关窗后为空 | ✅ |
| `testP3_013_virtualCameraStatsEntry` | idle / waitingExtension / stopped 三种状态、dropped 与 `countersSnapshot` 同源、frames = framesSent | ✅（publishing / frames 递增要签名的扩展，见 §3） |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | `docs/api.md` 与生成器同步（33 条） | ✅ |

### 2.4 `make test`

| 步骤 | 结果 |
|---|---|
| `make test-packages`（六个包） | 待最终重跑一次填数（见下：第一次跑时 SwitcherTestKit 有两条与 P3 无关的红，修 / 放宽之后单独跑到 63 用例全绿；前五个包在第一次跑里就已经全过——Makefile 是 `|| exit 1`，跑到第六个包就说明前五个没失败） |
| `make test-tools`（两个工具冒烟） | **绿**（exit 0；switcher-headless 0.1.0、frameprobe 都编得出、跑得起、打印自己的版本号） |
| `make test-app`（`xcodebuild test`） | **一条红，与 P3 无关**：`LocalizationTests.testL10n_noHardcodedChineseInUISources`，列出 **39 处**写死的中文文案，与 `reports/G4.md` §6.5 记的 **39 处逐条相同**（AppDelegate 9 / OutputRuntime 6 / SwitcherSession 6 / ExternalOutputMenu 6 / ISOPanel 6 / AuxOutputRuntime 5 / MultiviewWindowController 1）。**P3 一处没加**（新写的字符串全是 ASCII：`"monitor"` / `"presenting"` 之类），P3 动过的 `AuxOutputRuntime.swift` / `SwitcherSession.swift` 两个文件条数也与 G4 时相同。归 **W3-E2 / prompt 63**（`reports/issues/G4-w3-app2-localize-w3c-app-strings.md`），G4 也是带着这一条放行的 |

**跑的过程中撞到两条 TestKit 的红，都确认与 P3 无关（在 main 上复现），处理见下**：

| 用例 | 现象 | 在 main 上 | P3 的处理 |
|---|---|---|---|
| `SyntheticSourceTests.testW1A_syntheticVideo_60fps10s_continuousMonotonic_pushed600` | 600 帧每帧一条，解出的 `hostTimeMs` 与 `pts.nanoseconds / 1e6` **差正好 2^28** | 601 条，同样红 | 测试漏了 `& TestPattern.dataMask`（图案数据字是 28 位，同包 `NoiseBackgroundTests` 写对了）。机器连续唤醒超过 2^28 ms ≈ 3.1 天就整片红（本机唤醒 3.16 天）。**按胶水额度改了那一行**（断言语义没变，补上本来就成立的前提），问题单 `reports/issues/P3-w1-testkit-hosttimems-28bit-mask.md` 退回 W1-A3 |
| `SyntheticSourceTests.testW1A_syntheticVideo_jitterIsUniformWithinBound` | `abs(mean) < 0.8` 实测 0.85–0.86 | **3 次 3 次红** | 这是**阈值**，P3 不自己动（铁律 9）。问了用户，**2026-09-23 批了放宽到 1.2 ms**，已改并注明；问题单 `reports/issues/P3-w1-testkit-jitter-mean-bound.md` 里另记了"先跑一遍 jitterMs = 0 当零点、判 `abs(mean − 基准)`"这个与机器快慢无关的做法，留给 W1-A3 |

### 2.5 gate4（10 分钟 G4 场景；用户 2026-09-23 定的跑法：`scripts/gate4.sh --label p3* --baseline baselines/g4-m5max.json`，不写基线，跑完还原 `reports/G4.md`、删掉 `reports/G4-run-p3*.md`）

`make gate4-run` 会用 `--write-baseline` 覆盖 `baselines/g4-m5max.json` 并重写 `reports/G4.md`，P3 不该动这两样，所以按上面的办法跑。
**结论：第三次 p3c 19 / 19 ✅（代表运行）**。前两次的红都是环境：这台机器上当时还有别的会话在干活（09:58 看到 W2-A2 的 worktree `w2-inputs-audio-device-2ef9a9` 在跑 `make test`；p3b 期间 load 4.4–5.0、WindowServer 29–45%、"Claude" 进程 7–16%）。
p3c 开跑时机器是空的（load_before 1.66），但半分钟后 W2-A2 又起了一轮测试（10:07:32 起，先 SwitcherCore / Inputs / Audio，10:12 起 SwitcherOutputs），与 p3c 的 10 分钟场景**整段重叠**——
p3c 仍然 19 / 19、每路"迟到"只有 1 次。所以不是"有别的会话就一定红"，p3b 那 10 分钟的拖累更重（它的每路迟到 6–13 次，代码与 p3c 只差报告文字）。

| 运行 | 时间 | 19 项 | 没过的 | 说明 |
|---|---|---|---|---|
| p3 | 09:21–09:31（提交 d59f993） | 16 / 19 | V2 9 帧、V4 109 帧（引擎侧精确核算）、V5 −9 | V2 两次跳拍（拍 34271 +4、35291 +5），那两秒 render_ms 3.84 / 5.13 ms、CPU 28–30%、GPU 20–22%（都**低于**全程均值）；V3 max 0.099 ms（时钟没晚醒）。与 G4 run1–3 的记录同一个样子（G4：跳拍秒 render_ms 3.7–5.4 ms、V3 ≤ 0.05 ms，查明是"进程被系统 / 桌面活动拖住"）。V4 / V5 全由这 9 拍派生 |
| **p3c** | **10:07–10:17（提交 2dea1d5）** | **19 / 19 ✅** | — | **代表运行**。V2 0、V4 两个口径 0（引擎侧精确核算 0 / frameprobe 在播段 0；平均帧率口径最大 0.0111%）、V5 +0。每路"迟到"1 次；输入 5 drop 4 ≈ 设计内 3.6（+100 ppm × 36000 拍），与 G4 run4 的 3 同一回事。S3 CPU 31.4% / GPU 24.0%（达目标）。S2 46.6 MB/h 仍红（见下，G4 也红） |
| p3b | 09:32–09:42（提交 ca1baa5） | 18 / 19 | V4 13 帧（引擎侧精确核算；§4 必须档的平均帧率口径 0.0306% ≤ 0.05% ✅；frameprobe 在播段 0 ✅） | V2 **0**、V5 **0**。V4 的 13 帧里 11 帧是**输入 5** 的 drop（外加 8 次 reused，设计内约 3.6 / 0）。输入 5 是 **+100 ppm** 的合成源，相位每 166 s 扫过一次拍点边界，**一到就晚就变成 drop + dup**。晚到来自**所有输入**都有的生产者晚醒：p3b 每路"迟到" 6–13 次、唤醒延迟最大 0.06–3.37 ms；**G4 run4（main）每路迟到 0、唤醒最大 ≤ 0.15 ms**。输入 1 / 2 / 7 / 8 与叠加、多画面都无关也一样晚到——这是生产者线程的 CPU 调度，P3 没碰；其它输入的相位离边界远（60 fps 整）或方向相反（59.94 / −100 ppm 只会 dup），晚到只是等一等。main 上 G4 的四次运行里输入 5 的 drop 也一直比别的输入多（3 / 6 / 6 / 20） |

**第 7 条要求记录的 V1 变化**（节目里有 enabled 的多画面输出，所以 headless 从 P3 起每拍多做一次多画面 NV12 转换）：

| | render_ms avg | p99 | max | 进程 CPU | GPU |
|---|---|---|---|---|---|
| G4 run4（main，代表运行） | 2.149 | 2.652 | 2.717 | 50.7% | 30.5% |
| P3 p3 | 2.077 | 2.559 | 5.126（跳拍那秒） | 53.9% | 27.2% |
| P3 p3b | 1.942 | 2.590 | 3.573 | 63.0% | 28.4% |
| **P3 p3c（代表）** | **1.820** | **2.385** | **2.827** | **31.4%** | **24.0%** |

**V1 没有可见的退步**：三次都比 G4 的代表运行低（代表运行 p3c：avg −0.33 ms、p99 −0.27 ms），前两次落在 G4 自己四次运行的散布里（avg 1.936–2.149）。原因是多画面纹理本来每拍就在画（`options.multiview` 默认开），P3 只是多了一个 1080p → NV12 的 compute dispatch，塞在已经开着的那个 compute encoder 里。多画面真的在转——`testP3_renderedFrameAutoFilledFromStateWithDefaultOptions` 用默认选项的实时渲染器验过。
进程 CPU 在 p3 与 p3b 之间差 9 个点，代码只差一个报告提交，所以是环境（性能核被别的会话占着、线程落到能效核上，同样的活要更多 CPU 秒；与上面的晚醒是同一件事）。P3 每拍在 CPU 上多出来的只有两个短循环（`CompositorPasses.wants`、PVW 叠加遍历的早退）和一次纹理表查找。

S2（内存增长）三次 88.2 / 72.3 / 46.6 MB/h，G4 run4 是 79.9 MB/h，**G4 也是红的**（10 分钟不足 1 h，整段拟合仅供参考；8 小时实跑归 W4-A），不在 19 项里；
S3 的 CPU 在 p3b 是 63.0%（线 60%），原因同上，p3c 回到 31.4%。
运行产物在 `.build/gate4/p3{,b,c}/`（不入库）：stats.jsonl、out.mov + 4 路 ISO、frameprobe / ffprobe / apitest 的 JSON、load.log、environment.txt。

---

## 3. 没做的和原因

1. **任何界面**（设置面板里的对齐延迟 / 监听点、Add Input 的接口 / 带宽 / 抖动缓冲、叠加边框与锚点、多画面布局编辑器、每路 AFV 开关的条子、输入设置窗"来源"一节可编辑）→ W3-E2 / prompt 63。P3 只把命令与字段准备好，`MixerModel.setInputAFV` 已经写好留给界面调。
2. **frameprobe** → W1-A3 / prompt 62；**纯音频设备输入** → W2-A2 / prompt 64；**Aux 全分辨率** → W3-C2 / prompt 65。
3. **013 的 `dropped` 只算"拿不到 drawable"那一种**：`MetalDisplayView.SkipCounters` 里另外四项（不可见、没有新帧、版本相同、被帧率闸门拦下）都不是"丢帧"，算进去会虚高。`multiviewWindow` 也没有独立的 noDisplay 细分（它是可拖动的普通窗口，不绑定显示器）。两条都由 **W3-C2（prompt 65）复核**。
4. **虚拟摄像头的 `publishing` / frames 递增没有真数据**：要签名的系统扩展装上并激活（BLOCKED-签名，解锁条件 = Team ID 签名 + /Applications）。用例里写了"若 state == .connected 则 …"的分支，装上之后自然覆盖。
5. **headless 没有加 `--audio-align` / `--audio-monitor` 覆盖参数**：现有命令行里没有这两项（`--audio-*` 只有 `--audio-device`），提案也没要求新增；直接从 show 读。要加属于新功能。
6. **`Tests/Fixtures/` 没动**：改写前的 `g4-show.json` 存进了 `Packages/SwitcherCore/Tests/SwitcherContractsTests/Fixtures/`（P3 认领的目录），没有往 W1-A3 的 `Tests/Fixtures/` 里放。
7. **没有动任何引擎 / 混音器 / 渲染逻辑**，除了 W3-B §4 第 5 条那条裁定要求的填充条件（见 §5 第 1 条的代价说明）。
8. **改过一处阈值，是用户当场批的**：`testW1A_syntheticVideo_jitterIsUniformWithinBound` 的 `abs(mean) < 0.8` → `1.2`（2026-09-23）。它在 main 上就红（3/3），与 P3 无关；P3 没有自己动，是问过之后才改的（铁律 9）。同一条用例里另外四条断言（min / max / std / pts 严格等于拍点）两个分支上都绿，没碰。
9. **App 的本地化那条红没修**：39 处写死的中文文案全在 W3-C 接进 App 的文件里，归 W3-E2 / prompt 63，G4 也是带着它放行的。

---

## 4. 对契约的疑问

1. **`OutputSettings` 的过渡键还要留多久**。`extra["layout"]` / `["displayID"]` / `["fallbackToMain"]` 与 `effects["border"]` 这三处"后备读取"按提案写的是"保留一个版本"。`Show.load` 已经会把它们搬走，所以在正常路径上读不到了；后备只对"没经过 `Show.load` 的内存状态"（例如 API 直接 `addOutput` 一个带 `extra["layout"]` 的输出）有意义。建议 **W4 或 G5 删掉后备路径**，届时把 `MultiviewLayoutTable.parse(layout:)`、`OverlayDecoration.border(for config:)`、`ExternalDisplaySpec` 的 extra 分支、`OutputExtras` 的后备一起删。
2. **`DisplayOutputSettings.fallbackToMain` 的默认值与 W3-C 的行为不一致**：契约默认 true（提案 013 原文），W3-C 的 `ExternalDisplaySpec` 默认 false。P3 的处理是——搬迁只在出现过旧键时才写、按旧键原值；App 面板新建输出时**显式写 false**，保持 G4 的行为。所以现在"节目文件里没有 display 字段"与"有 display 字段且 fallbackToMain 缺省"两种情况语义不同（前者 false、后者 true）。要统一的话是改 `ExternalDisplaySpec` 的默认（会改已有行为），请在 W3-E2 做面板开关时一并拍板。
3. **`Stats.display[]` 的 `output` 对界面视图用 0**：主界面监视器与多画面窗口都不是输出表里的输出，两项都是 `output: 0`，靠 `kind` 区分。如果以后要区分"哪个监视器"（PGM / PVW 两个视图），得另加字段或约定（例如 PVW 用 −1）。目前只填 PGM 监视器一项。
4. **`Command` 33 个 case 已经不小**。`setOverlay` / `setOverlayDecoration` 两条都是"改叠加通道的设置"，将来如果还要加（例如抠像单独的命令），建议一次性改成 `setOverlaySettings(channel:settings:)` 整体替换（像 `setInputSettings` 那样），而不是继续按字段加 case——那会是一次破坏性的 wire format 变更，要走提案。

---

## 5. 下一个会话需要知道的坑

1. **两个输出环现在总是建好**（`MetalRenderer.prepare`）。W3-B 报告说"渲染器侧改一行"，但"状态里有 enabled 的输出就填"这件事要在 `render()` 里判，而 `prepare()` 时还没有状态、渲染线程又不许分配，所以 PVW 环无条件建、多画面环只受 `options.multiview` 管。**代价是 1080p / ringSize 8 下多约 25 MB 常驻**（PVW 那个环；多画面环本来在 `options.multiview` 开时也不一定建，现在建了）。`options.previewOutput` / `multiviewOutput` 现在只影响"强制填"，不再影响"建不建环"。要省这块内存得让引擎在 `prepare` 之后、第一帧之前把状态告诉渲染器（改 `Renderer` 协议 = 改契约）。
2. **两处同名类型**，跨模块用的地方要写模块名：
   - `SwitcherContracts.MonitorPoint`（String / Codable，Show 里存的）vs `SwitcherAudio.MonitorPoint`（Int32，对应 C 的 `sw_monitor_point`）；转换用 `SwitcherAudio.MonitorPoint.init(_:)`。
   - `SwitcherContracts.DeckLinkConnection`（单个口）vs `SwitcherDeckLink.DeckLinkConnection`（位集，"卡支持哪几个口"）；转换用 `SwitcherDeckLink.DeckLinkConnection.init(_:)` 与 `.supported`。
   已经撞到并修好的调用点：`AudioEngineConfiguration` / `AudioEngineStatus` / `MixerTapAndAgeTests` / `AlignmentTests` / `DeckLinkHardwareTests`。新写代码时直接写模块名最省事。
3. **`InputSource` 现在有显式 `init(from:)`**：以后**再加 case 必须同时改 `Synthesized` 那个内部枚举**，否则新 case 解不出来（会落到 `synthesizedDecoding` 里抛 `DataCorrupted`）。同理 `AudioState` / `OverlayState` / `OverlayAnimation` / `InputAudioSettings` / `Stats` / `MultiviewLayoutSettings` / `DisplayOutputSettings` 都写了显式 `init(from:)`，**加字段要同时改 `init(from:)` 和 `jsonKeys`**（`jsonKeys` 有用例钉住，漏了会红）。
4. **自定义多画面格子的像素算式必须"先转 Float 再乘"**（`Float(x) * w`，不是 `Float(x * Double(w))`）：两条解析路径的浮点舍入要逐位一致，否则 `testP3_officialMultiviewFieldMatchesLegacyExtraKey` 会在第 4 个格子上差 3e-8。
5. **`check-ownership` 是逐提交结算的**：同一个文件先加后删会**两次都算进胶水额度**。本会话一开始把 `MetalRenderer.wants` 写在 `MetalRenderer.swift` 里（胶水 68/50 超额），挪到 `CompositorPasses.swift` 之后如果直接再提交一次，额度会变成 107 行而不是 43 行——只能 `git reset --soft` 重做提交，让每个文件只被动一次。**改胶水文件前先想清楚放哪**。
6. **`make lint` 要显式给分支名**：worktree 的分支是 `claude/p3-contracts-phase-2-86a7c4`，OWNERSHIP 里是 `p3-contracts`，所以要 `git branch -f p3-contracts HEAD` 再 `make lint BRANCH=p3-contracts`。
7. **`swift build` 会在没有 `Package.resolved` 的包里生成一个**（SwitcherOutputs / SwitcherTestKit / frameprobe）。仓库只跟踪 SwitcherControl 与 switcher-headless 两份，所以跑完测试工作树里会多出三个未跟踪文件；本会话把它们删掉了，别误提交。
8. **需要 rebase 的分支**：此时可能已经开着的 **w1-testkit-3（W1-A3，prompt 62）** 与 **w2-inputs-2（W2-A2，prompt 64）**——两者都从 G4 合入后的 main 开，与 P3 没有文件重叠，但都 `import SwitcherContracts`：
   - w1-testkit-3 动 `Packages/SwitcherTestKit/` 与 `Tools/frameprobe/`，P3 动了 `SwitcherTestKit/Sources/.../Stats/StatsSummary.swift`（加 `displays`），rebase 时可能在这一个文件上冲突；
   - w2-inputs-2 动 `SwitcherInputs/`，P3 动了 `DeckLinkInput.swift` / `NDIInput.swift` / `DeckLinkDevices.swift`；纯音频设备输入不碰这三个，但新写的 `AudioDeviceInput` 如果 `switch config.source` 要补 `decklink` / `ndi` 的新关联值。
   **w3-app-3（W3-E2，prompt 63）与 w3-outputs-3（W3-C2，prompt 65）按计划从 P3 合入后的 main 开**，不用 rebase。
   本会话结束时看到 W2-A2 已经开着（worktree `w2-inputs-audio-device-2ef9a9`，在跑 `make test`）。
9. **同一台机器上别的会话在跑重活时，gate4 与计时类用例的数字不可信**。本会话两次 gate4 的红（p3 的跳拍、p3b 输入 5 的 drop）、TestKit 抖动用例的偏置，都是生产者线程晚醒 / 落到能效核的样子。**开跑之前先看一眼**：
   `for p in $(pgrep -f "make test|gate[0-9]|swift-test|switcher-headless run"); do lsof -a -p $p -d cwd -Fn | sed -n 's/^n//p'; done`——
   有别的 worktree 的就等它跑完。两个会话同时 `make test` 会互相拖慢，计时类用例在两边都可能红（本会话看到 W2-A2 的 `make test` 先起，就把自己的停了）。
10. **`TestPattern` 的数据字只有 28 位**：`hostTimeMs` 与 `frameNumber` 都被 `dataMask` 掩过。拿解出来的毫秒字段与 host time 比，要一起 `& TestPattern.dataMask`，
    否则机器**连续唤醒**（不含睡眠）超过 2^28 ms ≈ 3.1 天就红，重启又好——很难复现。frameprobe 的 `genTimeMs` 跨帧相减也要按 28 位环形算（问题单里写了）。
11. **后台跑 `make … | grep …` 时，任务通知里的 exit code 是管道最后一段的**，不是 make 的——本会话第一次 `make test-packages` 通知"exit code 0"，日志末尾其实是 `make: *** [test-packages] Error 1`。看结果要翻日志，别看通知。
    另外 **`until ! pgrep -qf "make test"; do …` 这种等待循环会匹配到它自己所在的 shell**（那个 shell 的命令行里就有 "make test"），永远等不完；要写成 `pgrep -qf "[m]ake test"`。

---

## 6. 测试标准 §7 需要同步的字段行（由用户改）

`docs/spec/导播台测试标准.md` §7 的 stats.jsonl 字段表里加一行（提案 013）：

```
display[]  显示类输出（外部显示窗口、虚拟摄像头、多画面窗口、主界面监视器）各一项，无固定顺序，按 output + kind 认。
           output = MixerState.outputs 里的编号（主界面监视器不是输出，用 0）；
           kind = externalDisplay / virtualCamera / multiviewWindow / monitor；
           frames = 已呈现 / 已送出帧数，累计；dropped = 没赶上显示刷新 / 被扩展丢弃的帧数，累计；
           state = idle / presenting / noDisplay / waitingExtension / publishing / stopped / failed。
           老文件缺这个键 = 空数组。
```

顶层键的顺序：`ts, tick, render_ms, missed_render, jitter_ms, per_input, encoder, display, audio, rss_mb, cpu_pct, gpu_pct`（`display` 插在 `encoder` 与 `audio` 之间）。

---

## 7. 运行记录

待填。
