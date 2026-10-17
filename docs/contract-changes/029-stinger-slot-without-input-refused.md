# 029 没选输入的 Stinger 槽：`useTransitionSlot(start: true)` / `autoTransition` 拒收（改 020 的默认口径，不加字段、不加命令）

提出：G8（prompt 107 / G8b，2026-10-11 从 W5-M 报告 §3 第 3 条 / §4 第 1 条攒出来）。
状态：**用户 2026-10-12 "先按照你的想法来" → G8 定：拒**；**P5-3（prompt 110）已落地**（见文末落地记录）。控制层 / 兼容层 / Stream Deck 的提示归 W5-O（prompt 112，叠在 P5-3 上或等它合入）。

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

## 落地记录（P5-3 / prompt 110，2026-10-12）

已落地（分支 `p5-contracts-3`，提交 10cb844；CONTRACTS.md 的文字 588f059）。

- **判定只有一条**：契约加计算属性 `TransitionSlot.isStingerWithoutInput`（type = stinger 且 stinger.input = nil；不进 JSON，槽 / TransitionState 的键与命令的 wire 形态都不变）。reducer、校验器共用它；W5-O 的控制层 / 兼容层提示也该用它（App 的 `SlotText.isUnsetStinger` 是同一条判定的界面版）。
- **reducer**：`useTransitionSlot(slot, start: true)` 遇到这种槽原样返回（不选中、不开始，applied = false），看槽的配置不看槽号；`autoTransition` 遇到要执行的当前那组是这种的原样返回；`start: false`、`cut`、`fade`、`tbar` 照旧。
- **校验器**同口径 400：`useTransitionSlot` →"转场 n 是 Stinger、还没选输入"；`autoTransition` → 当前那组对应槽 n 时同一句，不对应任何槽时"当前转场是 Stinger、还没选输入"。两个条件只随命令变（槽的配置 / 空闲时的当前那组），入口就拒；`autoTransition` 在转场进行中校验器不判（本来就由 reducer 忽略，完成那一拍当前那组还可能按槽重拷——那是随拍变的）。
- **T-bar 核对**（写进 CONTRACTS.md §2.5 转场槽一段）：reducer 对 `tbar` 不看类型，推这样的当前那组照收（progress = 推杆位置、source = tbar，到 1 提交、拉回 0 取消）；渲染器 `TransitionRenderer.stingerShowsNewUnder` 在 round(progress × durationTicks) ≥ max(cutAtTick, 1) 时把底整个换成 PVW、不叠任何东西——推过换底拍对应的那一格画面就换成新画面、拉回去又换回；cutAtTick ≥ durationTicks 时推的过程中不换、到 1 提交才换；durationTicks = 0 一推就换。界面上 T-bar 行没有单独拦（X18 只拦"执行"三处），要不要拦是 App 的事（报告 §4）。
- **文字**：`Command` 三处注释（autoTransition / useTransitionSlot / tbar）、`CommandCatalog` 三条摘要 → docs/api.md 重生成（仍 42 条）、CONTRACTS.md 变更记录 / §2.5（TransitionState、TransitionSlot 两行 + 转场槽一段新加一条）/ §2.6 / §8。
- **用例**：`Contracts020Tests.test029_isStingerWithoutInput_definition_factorySlot4AndCurrentGroup` / `test029_noNewFieldsOrCommands_wireShapeUnchanged`（契约测试 target 只依赖 SwitcherContracts、调不到 reducer，所以这两条钉判定与 wire 形态；"start: true 拒 / start: false 照常 / autoTransition 拒"三件事在下面两条 reducer 用例里，含状态机回执 applied = false）；
  `ReducerTests.test029_useTransitionSlot_stingerWithoutInput_startRefused_selectAllowed` / `test029_autoTransition_currentStingerWithoutInput_refused_tbarUnaffected`、`testW1B_reduce_everyCommand_beforeAfterTable` 原来那行"没选输入照常开始"改成拒 + 新加 5 行；`CommandBusTests.testValidator_agreesWithReducer`（槽 4 start: true 挪进非法、start: false 进合法、autoTransition 两种当前那组两边都拒、选了输入放行、进行中校验器不判）+ `testBus_rejectsStructurallyInvalidCommandsWithReason` 一条（400 文案）；`CommandCatalogTests.testCatalog_029_stingerWithoutInputRefusalDocumented`。
- **与正文不同的一处**：正文写"`autoTransition` 当前槽是这种槽时拒"。落地按**要执行的当前那组**判：当前槽是这种槽时两者一样（空闲时 currentSlot = n 一般就有当前那组 = 槽 n；唯一的例外是 T-bar 推到一半改了当前槽、又拉回 0 取消——那时当前那组还是改之前的，见报告 §4，按"要执行的"判正好不出错）；另外 currentSlot = nil、当前那组是 `setTransition(.stinger)` / `setTransitionParams` 直接给的没选输入的 Stinger 时也拒。理由：只看 currentSlot 的话，`setTransition(stinger, 60)` 碰巧与出厂槽 4 相同（currentSlot 自动对号成 4）就拒、`setTransition(stinger, 45)` 就照常延迟硬切——同一件事看时长凑不凑巧，而且正是正文"否则从这条路绕过去还是一次延迟硬切"要堵的路。代价：API 直接 `setTransition(stinger)` + `autoTransition` 又没设输入的老用法也从延迟硬切变成 400（兼容层 `Stinger1` 本来就对这种情况回 NotConfigured，headless 的 g4 / soak 场景 Stinger 都有 9 号输入，不受影响）。要按字面（只看 currentSlot 指的槽）改回：reducer / 校验器各一行，并把覆盖表"当前那组（不对应槽）"那行与 CommandBusTests 的 `legacyStinger` 那组改成放行。
- **顺带**：`ReducerTests` 的 V6 两条（`testV6_setPreviewRejectedDuringTransition` / `testV6_setProgramRejectedDuringTransition`）与 V7 一条（`testV7_autoTransition_wipeZoomStinger_sameProgressRule`）原来用"没选输入的 Stinger"跑 auto 转场（baseState 的 stinger 没设，输入是不是 nil 跟它们测的进度 / 拒收规则无关）；现在先给当前那组的 Stinger 选一路（`stingerReadyState()`，经 setTransitionParams）再跑，断言一条没改。

**2026-10-17 用户裁定：维持**落地时的判法——`autoTransition` 按"要执行的当前那组"判（比正文"当前槽是这种槽"多拒"API 直接 `setTransition(.stinger)` + `autoTransition` 又没设输入"一种，老用法以前是延迟硬切，现在 400）；正文不改、代码不改。
同日另定：T-bar 推这种槽照契约放行、由 App 把 T-bar 灰掉并提示（prompt 119）；MIDI 执行它被拒要提示（prompt 116）；格子"转场"遇它先弹输入选择、整条不发（119）。
