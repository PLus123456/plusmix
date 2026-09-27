# 019 `Stats.EncoderEntry` 加输出编号 `output` 与接收方数 `connections`；NDI 的 state 多一个 `failed`；（附）reducer 对 addInput / setInputSettings 带来的 `border` 效果格

提出会话 / 分支：G4 续做合入会话（g4，2026-09-27）。来源：reports/w3-app-4.md §4 第 2 / 3 条（W3-E3）、reports/p4-contracts.md §4 第 1 条（P4）。
状态：**待批**（A / B / C / D 四条可以分开批；批了建议由 main 快进后的下一轮检查点顺手落地，或新开契约会话 P5——本轮 App 胶水额度已用 42 / 50，落不下 App 那几行）。

## 改什么

### A. `Stats.EncoderEntry` 加 `output`（JSON 键 `output`；缺键 = 0；写出总写）

- 与 `DisplayEntry.output`（013）同口径：`MixerState.outputs` 的编号；0 = 填数方还没跟上 / 不知道。
- `jsonKeys = ["output", "skipped", "bitrate", "frames", "dropped", "disk_free_mb", "reconnects", "state"]`（display[] 也是 output 在最前）；
  `init(... output: Int = 0 ...)` 默认 0，现有调用点照编；显式 `init(from:)` 里 `decodeIfPresent ?? 0`。
- 测试标准 §7 那一行 `encoder[{...}]` 加 output（测试标准由用户改或授权）。

### B. `Stats.EncoderEntry` 加 `connections`（JSON 键 `connections`；缺键 = 0；写出总写）

- NDI = 当前接收方数（`NDISendCounters.connections`，NDIlib_send_get_no_connections 的值）；推流 / 录制写 0。
- 位置在 `reconnects` 之后、`state` 之前。

### C. NDI 的 `state` 多一个允许值 `failed`

- SDK 在、但 `NDIlib_initialize` / `send_create` 失败时写 `failed`（W3-E3 §4 第 3 条：现在与"SDK 不在"一起标 unavailable，界面分不开"装 SDK"与"看日志"两个动作）。
- `unavailable` 仍只表示 SDK 不在。键与类型不变，只是 CONTRACTS.md §2.7 那句与 `Stats.swift` 注释里的值表多一个。

### D.（不是 JSON 变更；P4 §4 第 1 条）reducer 对 `addInput` / `setInputSettings` 带来的 `EffectSlot(id: "border")`

- 现状：原样存进状态、渲染器不读、下次 `Show.load` 才清掉。P4 让 Show.load / loadShow / addOutput / setOutputSettings 都搬迁并清 border 格，只剩这两条命令的入口没处理。
- 提议：reducer 对这两条命令也剥掉 border 格（没有叠加通道的上下文就不搬、直接清；`border` 这个 id 已被搬迁永久占用，P4 §5 第 4 条）；`CommandValidator` 不改；各一条用例。
- 另一条路：校验器拒（改 API 行为，客户端收到错误）。今天没有客户端这么写，两条路都不动现有用例。

## 为什么

- A：App 找某个输出在 encoder[] 里的那一项靠"与 outputs 里带编码器的输出同序"（`OutputRuntime.encoderEntry`），输出表在两次采样之间变了会错一拍（W3-E3 §4 第 2 条）；
  API 客户端同样只能按顺序猜。display[] 从 013 起就带 output，encoder[] 是 Stats 里唯一还靠顺序对号的数组。
- B：铁律 4——NDI 页要显示"几个接收方"，这个数今天只在 `NDISendCounters` 里，Stats / API 看不到；界面不许绕过 Stats 去读对象（W3-E3 §3 第 1 条因此没做）。
- C：一个值混了两种事，界面上的提示要分开写才有用。
- D：P4 把"状态里不会再有过渡键 / 死数据"做到了三处，剩这一个入口口径不齐。

## 考虑过的别的做法

- A 改成按编号的字典 `encoder{n: {...}}`：更直接，但是破坏性 wire 变更，所有读 stats.jsonl 的工具（frameprobe summarize、gate 报告、apitest、TestKit StatsSummary）都要改；加一个键最省。
- B 放进 NDI 自己的一节 `ndi[]`：多一个数组只为一个数，不值。
- C 加 `EncoderEntry.error` 字符串：包不管语言，错误文字该由界面查表；state 一个值够用，具体原因留在 `NDISender` 对象上给日志。

## 影响谁

| 谁 | 改什么 |
|---|---|
| SwitcherContracts `Stats.swift` + SwitcherContractsTests | A / B 字段、默认参数、`init(from:)` 缺键 0、`jsonKeys`；C 注释；CodableTests / StatsP2Tests 的 jsonKeys 快照、Samples 往返加两个键 |
| docs/CONTRACTS.md §2.7、测试标准 §7 | encoder[] 字段列表加 output / connections，NDI state 值表加 failed |
| SwitcherOutputs | `RecorderCounters.statsEntry` / `StreamOutput.statsEntry` / `NDISender.statsEntry` 加 `output:` 参数（默认 0）；`NDISender` 填 connections、起不来时 state = failed（W2-D 的目录，几行） |
| App `OutputRuntime` / NDI 页 | 填 output；`encoderEntry(for:)` 改按 output 找；NDI 页显示接收方数、failed 的文案（两种语言各一键）——放 prompt 73（W3-E4） |
| Tools/switcher-headless | statsEntry 调用点填 output（录制 / 推流 / `--ndi-send`） |
| SwitcherEngine `MixerReducer` + ReducerTests（D） | addInput / setInputSettings 剥 border 格；两条用例 |
| TestKit `StatsSummary`、gate 报告 | 不必改（按位置聚合仍成立）；有 output 之后 gate 报告可以按编号列 |

## 怎么迁移

- 缺键 = 0：老 stats.jsonl 照读；老写法的 `EncoderEntry(...)` 靠默认参数照编。
- 读 encoder[] 的现有代码不用改；想按编号找的改用 output。
- D 不影响任何节目文件，只影响运行时 API 客户端带 border 格的 addInput / setInputSettings（今天没有）。

## 成本

契约 + 测试约 40 行；填数三处 + headless 约 20 行；App 约 30 行（含 NDI 页两条文案）；D 约 25 行。`Show.schemaVersion` 不升。
