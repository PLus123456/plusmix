# 021 文件输入的播放控制：播放 / 暂停 / 定位（从头 = 定位 0）+ 每路"切上 PGM 时从头播"

提出会话 / 分支：P5（prompt 99）/ `p5-contracts`；来源 docs/ui-study/01a 第 5 节候选 3、D5、04 Q11（用户按落地方案 §8.5 默认 (a) v1 最小集）、R8-E3、R7-E4；接线归 prompt 101（W5-N）
状态：**待批**（批了由 P5 落契约 + reducer + 校验器 + 目录 / api.md；FileInput 接线、格子按钮、就地改结束动作归 101）

## 改什么

### A. 字段（Input.swift）

`InputSettings` 加 `playback: PlaybackSettings`（非 Optional，缺键 = 默认，写出总是写全；只对 `InputSource.file` 有意义，别的 kind 照存不读）：

| 字段 | 含义 | 默认 |
|---|---|---|
| `paused: Bool` | 目标：是否暂停（true = 画面停在最近推出的那一帧、每拍重推；false = 播放） | false |
| `restartOnProgram: Bool` | 这一路**切上 PGM 时从头播**（Cut / auto 转场完成 / T-bar 提交 / setProgram 换成它的那一拍，reducer 记一次"定位 0"）；在 PVW 上预览时不动 | false |
| `seekSeconds: Double?` | 最近一次定位请求的目标位置（秒，从文件头算；0 = 从头） | nil |
| `seekTick: Tick?` | 那次定位请求落在哪一拍（reducer 的 tick）；与 `seekSeconds` 一起构成"一次请求"，组装方（App InputRuntime / headless）看到 (seekTick, seekSeconds) 变了就对 FileInput 做一次 `seek`，做完不改状态 | nil |

`seekSeconds` / `seekTick` 是瞬态：`MixerState.resetTransientState()`（载入节目时）清成 nil，与转场进度同口径；`paused` / `restartOnProgram` 是目标，随文件存。
`InputSettings.clamped()` 顺带：`seekSeconds` 钳 ≥ 0（上限由 FileInput 按文件时长钳，契约不知道时长）。

### B. 命令（Command.swift，+2：35 → 37；与 020 一起批则 → 40）

| 命令 | 规则（reducer）| 校验器（入口 400） |
|---|---|---|
| `setPlayback(input: Int, paused: Bool)` | `inputs[i].settings.playback.paused = paused`；相同值原样返回 | 输入不存在；`kind != .file`（"输入 n 不是文件输入"） |
| `seekPlayback(input: Int, seconds: Double)` | `playback.seekSeconds = max(0, seconds)`、`playback.seekTick = tick`（从头播 = seconds 0；目录样例就是它）；同一拍同一位置再发原样返回 | 输入不存在；`kind != .file`；seconds 负 / 非有限 |
| 原有 `cut` / `autoTransition`（完成）/ `tbar`（提交）/ `setProgram` | 新 PGM 那一路若 `restartOnProgram`，reducer 在同一拍写 `seekSeconds = 0`、`seekTick = tick`（与手发 `seekPlayback(0)` 同一条路，组装方不用认第二种信号） | 不变 |
| 原有 `setInputSettings` | 整体替换照旧（`playback` 跟着换；`seekTick` 是瞬态，带进来的照收） | 不变 |

"设循环" **不加命令**：循环是 `InputSource.file(endAction: .loop)`，走现有 `setInputSource`；运行表遇到"只有 endAction / rate 变了"不重建、交给 FileInput 就地改（prompt 101 的交付 1，引擎接口现成）。
"播放列表 / 播完切回 / 转场时自动播、离开 PGM 自动暂停"不在这里（后续方案 §2.5，Q16）。

### C. 组装方（不在契约里，写明口径）

- App `InputRuntime` / headless：每个快照比上一个，`paused` 变了 → `FileInput.pause()` / `resume()`；(seekTick, seekSeconds) 变了 → `FileInput.seek(toSeconds:)`；都不重建输入。从头播 = seek(0)（FileInput 的 seek 把目标帧解出来、seekLead 之后的第一拍生效，之前帧槽里还是旧帧——"从头"的首帧晚 1–2 拍，写进手册）。
- 暂停中切上 PGM 且 `restartOnProgram`：定位到 0 但仍暂停（两个目标各管各的）；要"切上就播"再发 `setPlayback(paused: false)`——101 的格子按钮可以一键发两条（同一拍）。
- 纯音频文件（W5-K 问题单）：同一套命令，FileInput 支持了就能用。

### D. 文档 / 目录

CONTRACTS.md §2.4（InputSettings 行、PlaybackSettings 一段）、§2.6（命令数）、§8（两行）；CommandCatalog 两条（面向操作员；`seekPlayback` 的 `seconds` 用现有 `.fraction` 之外的新字段类型 `.seconds` 或按 `.durationMs` 的做法——目录里加一个 `CommandFieldType.seconds`，App 的选动作面板按它出"秒"输入框，归 100 / 101）；docs/api.md 重生成。

## 为什么

- 开场视频从头播每场都用，现在只能删了重加这一路（FileInput 早有 pause / resume / seek，`FileInput.swift:276-326`；契约没命令、界面没入口；01a D5、R8-U24）。
- reducer 只记状态、真正的播放动作由组装方交给 FileInput：reducer 保持纯函数（不碰输入对象），命令照常有回执 / 进日志 / 能从场景脚本重放；"定位"这种一次性动作用 (seekTick, seekSeconds) 表达成状态，组装方按变化触发，避免给状态机加"副作用通道"。
- "切上 PGM 时从头播"放 reducer 而不是组装方：PGM 换人的拍点只有 reducer 知道（auto 转场完成那一拍），放组装方要自己比两个快照的 program，多一份逻辑。
- 为什么两条命令而不是四条（播放 / 暂停 / 从头 / 定位）：播放 / 暂停是同一个目标的两个值（与 `mute(on:)` 同样的做法），从头 = 定位 0；命令数少两条、规则表少两行。

## 影响谁

| 谁 | 改什么 | 归谁 |
|---|---|---|
| SwitcherContracts + 测试 | A 的类型与 `init(from:)`、`resetTransientState`、`clamped()`、Command 两条、键名快照、老文件照读 | P5 |
| SwitcherEngine reducer + ReducerTests | B 的规则（含 restartOnProgram 在四处 PGM 换人时写定位） | P5 |
| SwitcherControl CommandBus + 测试、docs/api.md | 两条命令（kind != file 拒）、`CommandFieldType.seconds`、命令数快照 | P5 |
| SwitcherInputs `File/`、App `InputRuntime` | 按 C 接线：paused / seek 不重建；endAction / rate 就地改 | 101 |
| App 格子（▶ / ⏸ / ⟲ / 循环）、输入设置"来源"节 | 发 `setPlayback` / `seekPlayback(0)` / `setInputSource`；"切上 PGM 时从头播"开关走 `setInputSettings` | 101 |
| Hotkeys / MIDI | 要不要给"播放 / 暂停 / 从头"动作，归之后的控制会话（`ControlAction` 加三项） | 100 之后 |
| VMixCompat | 上游有 PlayPause / Play / Pause / Restart 一族，映射归兼容层会话（不在本提案） | W3-D 系 |
| headless | 场景脚本可以直接写这两条命令；不接 FileInput 的话只是记状态（headless 的输入都是合成源，不受影响） | — |
| 渲染 / 音频 | 不改 | — |

## 怎么迁移

- `Show.schemaVersion` 不升：老文件缺 `playback` = 默认（播放、不从头、无定位）；写出带 `playback`。021 之前的程序读新文件：忽略多出来的键。
- API 客户端：`inputs[i].settings` 多一个 `playback` 对象；`setInputSettings` 整体替换时不写它 = 默认（照 `InputAudioSettings` 缺键的做法）。
- 不批的话：Q11 (b)——只做"循环"开关（101 的就地改 endAction），播放 / 暂停 / 从头仍没有。

## 请用户定的点

1. 两条命令（`setPlayback` / `seekPlayback`）而不是四条——可接受？
2. `restartOnProgram` 作为可选每路字段要不要带（Q11 (a) 里的"+ 可选每路'切上 PGM 时从头播'开关"）；带的话按 B 的规则由 reducer 在换人那一拍写定位。
3. "设循环"不加命令、走 `setInputSource`（101 做就地改）——可接受？
