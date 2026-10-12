# 029 没选输入的 Stinger 槽：`useTransitionSlot(start: true)` / `autoTransition` 拒收（改 020 的默认口径，不加字段、不加命令）

提出：G8（prompt 107 / G8b，2026-10-11 从 W5-M 报告 §3 第 3 条 / §4 第 1 条攒出来）。
状态：**用户 2026-10-12 "先按照你的想法来" → G8 定：拒**。落地归下一个契约会话（P5-3，prompt 110）；控制层 / 兼容层 / Stream Deck 的提示归 W5-O（prompt 112，叠在 P5-3 上或等它合入）。

## 改什么

1. **reducer**：`useTransitionSlot(slot, start: true)` 当槽的效果是 Stinger 且 `stinger.input == nil` → 状态原样返回（receipt `applied = false`），不选中、不开始；`start: false`（只选中、用于 T-bar）照常。
2. **`autoTransition`**（回车 / "执行当前转场" / 格子"转场" / 兼容层 Transition1 的旧路）当前槽是这种槽时同口径拒（否则从这条路绕过去还是一次延迟硬切）。`tbar` 不动：Stinger 本来不走 T-bar，现状如何照旧（P5-3 核对一下现在 T-bar 推一个 Stinger 槽是什么行为，写进 CONTRACTS.md）。
3. **校验器**同口径拒（HTTP 400，错误文案"转场 n 是 Stinger、还没选输入"——与 `setMonitorSource(headphones)` 当时的做法一样：不随拍变的条件入口就拒，`testValidator_agreesWithReducer` 两边一致）。
4. 文字：CONTRACTS.md §2.x 转场槽那段、`Command.useTransitionSlot` / `autoTransition` 的注释、CommandCatalog 摘要 → docs/api.md 重生成；`Contracts020Tests` 加两条（start: true 拒 / start: false 照常、autoTransition 拒）、`ReducerTests` 的 everyCommand 表跟上。
5. 契约之外（W5-O）：控制层 `ControlAction.transitionSlot` / `autoTransition` 被拒时给一条 feedback（状态行"转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路"）；兼容层 `Transition n` 对这种槽回 409 NotConfigured（与 `Stinger1` 现状一致）；Stream Deck 按钮按下收到 400 时按 SDK 的 showAlert 闪一下；App 界面三处本来就先弹输入选择（X18），不变。

## 为什么

- 现在（020 默认"reducer 照常开始"）从快捷键 ⌥4 / MIDI 音符 / 兼容层 Transition4 / Stream Deck / API 执行一个没选输入的 Stinger 槽 = 一次**延迟硬切**（横幅没有、换底那一拍直接切）——直播中操作员按错一个键画面就换了、还不知道为什么。
- App 界面三处（转场列主体 / T-bar 行菜单 / 菜单栏"切换 › 转场 n"）W5-M 已按 X18 先弹输入选择、不执行；只有界面拒、别的入口照做，同一个槽在不同入口行为不同。
- 拒在 reducer / 校验器一处，所有入口（含以后新加的）自然一致；代价是 reducer / 校验器各一条判断 + 两条用例。

## 影响谁

SwitcherEngine reducer + CommandValidator（Core）、Contracts020Tests / ReducerTests / CommandBusTests、CONTRACTS.md、docs/api.md（重生成）；SwitcherControl Hotkeys（feedback 文案）、VMixCompat（Transition n → 409）、Tools/streamdeck-plugin（showAlert）——后三样 W5-O；App 不改。

## 怎么迁移

节目文件格式不变、老文件不受影响；只有"槽是 Stinger 但没选输入"这一种配置的行为变（从延迟硬切变成拒收 + 提示）。不批的话：现状（照常开始 = 延迟硬切），界面三处仍先弹选择。
