# 026 耳机听哪条总线进状态：`AudioState.monitorSource` + 命令 `setMonitorSource(bus:)`

提出会话 / 分支：W5-K（prompt 97，`w5-app-panels`；reports/w5-app-panels.md §4 第 1 条），G7 检查点转述（reports/G7.md §7.1 第 6 条）；本文件由 G7 按用户 2026-10-10 的裁定写成决策记录
状态：**已批**（用户 2026-10-10："升正式字段"）；**2026-10-12 用户允许 headphones，P5-3 已落地**（见文末两段）。契约由 P5（prompt 99）落地；引擎侧（设备客户端按它取总线送耳机、X09 借 Master 声道）归 102（W1-D3）；App 的 `MixerModel.listenBus` 改走命令 / 读快照归 102 之后的 App 会话或 G8 胶水（≤ 50 行）

## 改什么

- `AudioState` 加 `monitorSource: Bus = .master`（JSON 键 `monitorSource`；缺键 = master；写出总是写全）：耳机 / 监听总线上听的是哪条总线（master / busA / busB）。`headphones` 自己无效，reducer 拒收（receipt applied = false）。独听（PFL / AFL，`monitorMode` + 每路 solo）仍优先于 monitorSource，同现状。
- `Command` 加 `setMonitorSource(bus: Bus)`（命令数 +1，键名快照更新；API / 快捷键 / MIDI 的动作表随之多一项——`ControlAction` 归 100 或之后的控制会话）。
- docs/CONTRACTS.md §2.5 / §2.6 / §8 各一行；docs/api.md 重生成。

## 为什么

W5-K 的音频设置窗已有"监听 Master / Bus A / B"（灰着，引擎不支持）。只放在 App 里的话 API / 快捷键 / MIDI / 控制面板切不了；X09（2 声道设备上耳机总线没声、独听听不到）的引擎侧修法也要知道听哪条总线（W5-K §4 第 1 条、问题单 W5K-w1-audio-monitor-selected-bus）。

## 影响谁

SwitcherContracts（字段、命令、测试、CONTRACTS.md、api.md）；SwitcherEngine reducer（记状态、拒收 headphones；ReducerTests）；SwitcherAudio Integration / 设备客户端（102：按 monitorSource 取总线送耳机）；App（`MixerModel.listenBus` → 发命令、读快照）；VMixCompat 不映射。

## 怎么迁移

不升 schemaVersion；老 Show / 老快照缺键 = master，与现状（耳机听 Master）一致。

## 落地记录（P5 / prompt 99，2026-10-10）

契约已落地（分支 `p5-contracts`）：`AudioState.monitorSource: Bus = .master`（JSON 键 `monitorSource`，值 = Bus.rawValue，缺键 master，写出总是写全；文件 / API 全量状态里出现 headphones 的按 master 读，认不出的值照 Bus 的解码规则报错）；
`Command.setMonitorSource(bus:)`（34 → 35 个 case，JSON `{"setMonitorSource":{"bus":1}}`）；reducer：master / busA / busB 生效、headphones 原样返回、相同值原样返回；
校验器也拒 headphones（HTTP 400，与 setOutputEnabled 对录制 / 推流输出的做法一样——不随拍变的条件入口就拒，`testValidator_agreesWithReducer` 两边一致）；
CommandCatalog / api.md（参数 bus 0–2，面板上 headphones 该灰掉）；CONTRACTS.md §2.5 / §2.6 / §8。
用例 `Contracts026Tests`、`ReducerTests.test026_setMonitorSource_rejectsHeadphones_andSameValueUnchanged` + 覆盖表三行、CommandCatalogTests / APIServerTests 的 35、CommandBusTests 的合法 / 非法各一条。
引擎侧（设备客户端按它取总线送耳机、X09 借 Master 声道）归 102；App 的 `MixerModel.listenBus` 改走命令 / 读快照归 102 之后的 App 会话或 G8 胶水；`ControlAction` 的动作表归 100 或之后的控制会话；VMixCompat 不映射。`Show.schemaVersion` 不升。

## 2026-10-12 用户裁定：允许 `monitorSource = headphones`

（G8b 2026-10-12 把这一段写进了新文件 `026-monitor-source-in-state.md`，本该追加在这里；P5-3 原样并过来，那份文件留着当记录。）

用户 2026-10-12（看完 reports/G8.md §7.1 第 4 条）："允许"。落地归下一个契约会话（P5-3，prompt 110）；App 菜单那一项归 W5-O（prompt 112）。

- 契约：`AudioState.monitorSource` 允许 `.headphones` = **听耳机总线自己**（只听每路 `routing.headphones` 送出的那条，W5-K 菜单里"耳机总线（现在）"那一项、W1-D2 的旧行为）；独听（PFL / AFL）仍优先于 monitorSource，与 master / busA / busB 同口径。reducer / 校验器不再拒 headphones；文件 / API 全量状态里的 `headphones` 按字面读（P5 时"读成 master"的兜底去掉——App 从没写过这个值，没有迁移问题）。
- 引擎：W1-D3 的混音器已支持（`SW_CMD_MONITOR_SOURCE i0 = 3` = 耳机总线自己）；Integration 的 `syncSnapshotExtras` 把 headphones 原样交给混音器（现在是"万一出现按 master"，改掉）。
- 文字 / 用例：CONTRACTS.md §2.5 / §2.6、`Contracts026Tests.test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesReadAsMaster` 改成 headphones 往返、`CommandBusTests` 的校验器用例、CommandCatalog 参数范围 bus 0–3 → docs/api.md 重生成。
- App（W5-O）：`MixerModel.listen(_:)` 发 `setMonitorSource(bus:)`（四项都发得出，"耳机总线"= `.headphones`），`listenBus` 读快照 `audio.monitorSource`，`listenToOtherBusSupported` 翻 true，`AudioSettingsRevampTests.testPanels_masterListenAndLoudnessDetails` 跟着改（问题单 W1D3-app-monitor-source-and-input-effects-wiring 第 1 条）。

## 落地记录（P5-3 / prompt 110，2026-10-12）

已落地（分支 `p5-contracts-3`，提交 07a2df4；CONTRACTS.md 的文字 588f059）。

- **契约**：`AudioState.monitorSource` 四个值都合法，`init(from:)` 按字面读（去掉 P5 的 headphones → master）；`AudioState.monitorSource` / `Command.setMonitorSource` 的注释改口径（headphones = 听耳机总线自己，只听每路 `routing.headphones` 送出的那些；独听仍优先，四个值同一口径）。
- **reducer** 不再对 headphones 原样返回（相同值仍原样返回、applied = false）；**校验器**不再 400（并进 `setMonitorMode` 那一行放行）；**CommandCatalog** 的 bus 写"0 = master, 1 = busA, 2 = busB, 3 = headphones（耳机总线自己）"、摘要去掉"无效被拒" → docs/api.md 重生成（命令数 42 不变）。
- **Integration**：`AudioEngine.syncSnapshotExtras` 把四个值原样交给混音器（`mixer.setMonitorSource(ms)`，原来"万一出现按 master"；2 行）。混音器出口选路 `hp_own = solo_active || monitor_source ≥ HEADPHONES` 本来就是这个口径，独听时总是独听的路，不用改。
- **用例**（先红后绿）：`Contracts026Tests.test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesRoundTrip`（原 `…HeadphonesReadAsMaster` 改名：headphones 读写往返、节目文件往返）；`ReducerTests.test026_setMonitorSource_acceptsAllFourBuses_andSameValueUnchanged`（原 `…rejectsHeadphones…` 改名）+ 覆盖表那行改成生效；`CommandBusTests.testValidator_agreesWithReducer`（headphones 挪进合法）；`CommandCatalogTests.testCatalog_026_monitorSourceAllFourBuses`；新集成用例 `MonitorSourceHeadphonesTests.test026_monitorSourceHeadphones_exitIsHeadphonesBus_soloStillWins`——1 → Master、2 → Bus A + 耳机、3 → Bus B + 耳机，监听点设在延迟线后：状态 headphones（启动那次推送）与命令改回 headphones 两种情况耳机出口逐样本 = Bus A + Bus B（= 耳机总线），独听 2 时 = Bus A（独听优先），改 master 时 = Master。
- **没做**（不在本会话）：App 菜单"耳机总线"一项发 `setMonitorSource(.headphones)`、`listenBus` 读快照、`listenToOtherBusSupported` 翻 true（W5-O，prompt 112）；`AudioEngineStatus.monitorSource` 的注释还写"master / busA / busB"（Integration 的那个文件不在本会话的十行里，留给下一个 Integration 会话顺手改）。

