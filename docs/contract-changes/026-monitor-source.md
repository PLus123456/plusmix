# 026 耳机听哪条总线进状态：`AudioState.monitorSource` + 命令 `setMonitorSource(bus:)`

提出会话 / 分支：W5-K（prompt 97，`w5-app-panels`；reports/w5-app-panels.md §4 第 1 条），G7 检查点转述（reports/G7.md §7.1 第 6 条）；本文件由 G7 按用户 2026-10-10 的裁定写成决策记录
状态：**已批**（用户 2026-10-10："升正式字段"）。契约由 P5（prompt 99）落地；引擎侧（设备客户端按它取总线送耳机、X09 借 Master 声道）归 102（W1-D3）；App 的 `MixerModel.listenBus` 改走命令 / 读快照归 102 之后的 App 会话或 G8 胶水（≤ 50 行）

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
