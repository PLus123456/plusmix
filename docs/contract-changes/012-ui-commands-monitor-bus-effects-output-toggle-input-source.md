# 012 界面二期缺的几条命令：监听点、总线效果链、非录制输出的开关 / 改名、换输入来源；效果参数键名口径

提出会话 / 分支：W3-E / w3-app2（2026-09-19，做设置面板与调音台时发现）
状态：**已落地**（p3-contracts，2026-09-23，提交 cb85fbe…c73aab2）：A 的四个 case 与 B 的 `setInputSource` 都加了（Command 27 → 33，连同提案 010 A4 的 setOverlayDecoration），reducer / `CommandValidator` / `CommandCatalog` 与 `docs/api.md` 同步；C 的效果参数键表进 CONTRACTS.md §2.4。App 三处调用改完（`MixerModel.setMonitorMode` / `setBusEffects`、`OutputSettingsModel` 的开关与改名），W3-C 的运行表本来就按 `enabled` 起停，改开关后不再走删除 + 重加。"输入设置窗来源一节可编辑"归 W3-E2 / prompt 63。**"顺带的疑问" 1（每路 AFV 参与开关）用户 2026-09-22 第二轮批了**，一并落地：`InputAudioSettings.afv: Bool = true`，`AudioProgramGate.gains` 与 `AudioEngine` 的交叉淡变 / T-bar 门控都读它，走 `setInputSettings`、不加新命令。2 由 008 覆盖。

## 改什么

### A. `Command` 加 4 个 case（Command.swift；CommandValidator / MixerReducer 各加对应分支）

| case | 做什么 | reducer 规则 |
|---|---|---|
| `.setMonitorMode(mode: MonitorMode)` | 耳机监听点 PFL / AFL | `s.audio.monitorMode = mode`；相同则 applied = false |
| `.setBusEffects(bus: Bus, effects: [EffectSlot])` | 整体替换一条总线的效果链 | 总线不存在拒绝；`s.audio.buses[i].effects = effects` |
| `.setOutputEnabled(output: Int, on: Bool)` | NDI / 外部显示 / 虚拟摄像头 / 多画面输出的目标开关 | kind 是 record / stream 时拒绝（它们走 startRecord / startStream，语义与起止拍绑定）；相同则 applied = false |
| `.renameOutput(output: Int, name: String)` | 改输出显示名 | 输出不存在拒绝 |

### B. `Command` 再加 1 个 case（可以单独批 / 驳）

| case | 做什么 | reducer 规则 |
|---|---|---|
| `.setInputSource(input: Int, source: InputSource)` | 换一路输入的来源（文件路径 / 播完动作 / 屏幕目标 / 帧率 / 系统音频 / NDI 源名……），编号、名字、设置、PGM / PVW / 叠加引用全部保留 | 输入不存在拒绝；`s.inputs[i].source = source`（kind 可以变：契约说 kind 由 source 推出，不另存） |

App 的 `InputRuntime.reconcile` 已经按"编号 + 来源变了就重建输入"工作，命令落地后不用改。

### C. 文档口径（只改 docs/CONTRACTS.md，不改类型）

`EffectSlot` 的 id 与参数键（设计方案 §7 用苹果 ParametricEQ / DynamicsProcessor / PeakLimiter；与 SwitcherAudio.BusEffectChain 的三个 setter 一一对应，App 的 `AudioEffectParams` 已按这套写）：

| id | params（全部 number） |
|---|---|
| `parametricEQ` | `centerHz`、`q`、`gainDb`（一条链可多格 = 多段） |
| `dynamicsProcessor` | `thresholdDb`、`headroomDb`、`expansionRatio`、`attackSeconds`、`releaseSeconds`、`overallGainDb` |
| `peakLimiter` | `attackSeconds`、`decaySeconds`、`preGainDb` |

链的顺序 = 处理顺序；`enabled = false` 的格旁路。`InputSettings.effects`（每路）与 `BusState.effects`（每总线）同一套。

## 为什么

- **A1 / A2**：`AudioState.monitorMode` 与 `BusState.effects` 在契约里是可变字段（设计方案 §7 "监听：耳机总线可选 PFL / AFL"、"效果用苹果自带的 AudioUnit"），
  但 `Command` 里音频只有 audioGain / mute / busGain / busMute / setAFV。W3-E prompt 第 4 条要求调音台有"监听选择（PFL / AFL）"和"效果链（EQ / 压缩 / 限幅参数）"。
  现在 App 用 `.loadShow(show: 当前状态改一项)` 整体替换（`MixerModel.setMonitorMode` / `setBusEffects`），能用但转场进行中会被 `resetTransientState` 打断，
  且 API 客户端做同样的事也只能整体替换。
- **A3 / A4**：`OutputState.enabled` 对 record / stream 由 startRecord / startStream 置，其他 kind（ndi / externalDisplay / virtualCamera / multiview）没有任何命令能改；
  `OutputState.name` 也没有命令能改。W3-E 的 NDI 发送 / 虚拟摄像头开关现在做成"removeOutput + addOutput（同编号，enabled 翻转）"（`OutputSettingsModel.replace`），
  运行表会经历一次"消失 → 再出现"（外部显示窗口会闪一下；W3-C 的 NDI / 虚拟摄像头运行表也会停一下再起）。
- **B**：输入设置窗的"来源"一节只能只读：没有 `setInputSource`，换文件的播完动作 / 屏幕帧率都要 `removeInput + addInput`，而 `removeInput` 会把 PGM / PVW / 叠加里对它的引用清掉（reducer 规则），
  直播中不可接受。W3-A 的 DeckLink 输入口 / NDI 带宽模式提案落地后同样需要这条（改的是 source 里的参数）。
- **C**：效果参数键名两边（App 写、W1-D 接线时读）要一致，现在只在 App 代码注释里，写进 CONTRACTS.md 才算契约。

## 影响谁

- SwitcherContracts（Command 5 个 case + JSON 键）、SwitcherContractsTests（Command 27 → 32 个 case 的编解码快照 / 目录测试 `CommandCatalog`）。
- SwitcherEngine（MixerReducer 分支）、SwitcherControl（CommandValidator、CommandCatalog、API 文档 `docs/api.md` 重生成、HotkeyEditor / MIDI 的 ControlAction 不用改）。
- App（W3-E）：`MixerModel.setMonitorMode` / `setBusEffects` 改发新命令（各 1 行）；`OutputSettingsModel.replace` 换成 `setOutputEnabled` / `renameOutput`；输入设置窗"来源"一节可编辑。
- W3-C（NDI / 虚拟摄像头运行表按 `enabled` 起停，不再看到删除 / 重加）、W3-D（兼容层的 OverlayInputNOff 之类不受影响）。
- headless / 场景文件：新 case 可选，旧场景不受影响。

## 怎么迁移

- Show 文件 schemaVersion 不变（只加命令，不加字段）。
- 老 JSON 命令原样可解；新 case 的 JSON 形态与现有一致（`{"setMonitorMode":{"mode":"pfl"}}`、`{"setBusEffects":{"bus":0,"effects":[…]}}`、
  `{"setOutputEnabled":{"output":3,"on":true}}`、`{"renameOutput":{"output":3,"name":"…"}}`、`{"setInputSource":{"input":1,"source":{…}}}`）。
- 落地后 App 三处改动共约 10 行；提案 007（对齐延迟 / 监听点进 Show）若同时批，`setMonitorMode` 改的仍是 `AudioState.monitorMode`，与 007 的 `monitorPoint`（延迟线前 / 后）是两个不同的项，互不影响。

## 顺带的疑问（不在本提案范围，请一并拍板）

1. **每路 AFV 参与开关**：prompt 写"每路条子（…AFV 开关）"，契约里 AFV 只有全局 `AudioState.afv`（设计方案 §7 也是全局），音频引擎按 PGM 门控所有输入。
   常见需求是"主持人话筒不跟随视频"。若要，就是 `InputAudioSettings.afv: Bool = true`（true = 参与门控）+ AudioEngine 读它；W3-E 现在只做了全局开关 + 每路显示当前门控增益。
2. **W3-A 的 DeckLink / NDI 特有项**（输入口 / 连接类型、视频格式；带宽模式、tally 回传）：W3-E 的输入设置窗留了禁用的控件和说明，W3-A 的提案批了之后再接。
