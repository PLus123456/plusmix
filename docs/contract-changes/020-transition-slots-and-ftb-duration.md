# 020 转场槽（转场 1–4 四个可配置槽）+ FTB 时长命令

提出会话 / 分支：P5（prompt 99）/ `p5-contracts`；来源 docs/ui-study/01a 第 5 节候选 1 / 2、04 Q01（用户按落地方案 §8.5 默认 A）、Q07（默认 (a) 跟当前槽）、Q08（默认 (a) 加命令并进 020）、R3a C 附 3、01-菜单逻辑 §3.3；落地方归 prompt 100（W5-M）
状态：**已落地**（P5-2 / prompt 108，2026-10-11，提交 51e614e；文字 9ecc22a）。原状态：**已批**（用户 2026-10-11 看完 reports/G8.md 后原话"提案 020 / 021 / 022 / 023 二–五落地"，没批注——"请用户定的点"每条按本提案写的默认；落地归 P5-2，prompt 108，分支 `p5-contracts-2`。原状态行：（批了由 P5 落契约 + reducer + 校验器 + 目录 / api.md；界面、快捷键 / MIDI、兼容层、Stream Deck 归 100）

## 改什么

### A. 类型与字段（MixerState.swift）

| 新 / 改 | 定义 | 说明 |
|---|---|---|
| 新 `TransitionSlot` | `{ type: TransitionType, durationTicks: Int, wipe: WipeParams, stinger: StingerParams }`，Hashable / Codable | 一个槽 = 一套完整的"效果 + 时长 + Wipe 参数 + Stinger 参数"，字段与 `TransitionState` 的当前那组一一对应 |
| 新 `TransitionState.slots: [TransitionSlot]` | 恰好 4 个（`MixerState.validate()` 查，新错误 `MixerStateError.transitionSlotCount(Int)`），下标 0–3 = 槽 1–4 | 随节目文件存（槽里有 Stinger 用的输入编号，换节目必须跟着换） |
| 新 `TransitionState.currentSlot: Int?` | 1–4；nil = 当前那组（type / durationTicks / wipe / stinger）是 `setTransition` / `fade` / `setTransitionParams` / API 直接给的，不对应任何槽 | `validate()` 查 nil 或 1…4（`MixerStateError.transitionSlotIndex(Int)`）。T-bar / 回车 / `autoTransition` 用的永远是当前那组，所以"跟当前槽"（Q07 (a)）不需要别的字段 |
| 新 `TransitionSlot.factoryDefaults(for: ProgramFormat) -> [TransitionSlot]` | 1 = Fade 0.5 s、2 = Wipe 1 s（leftToRight、软边 0）、3 = Zoom 1 s、4 = Stinger 1 s（输入 nil、换底拍 0）；秒按帧率换拍（round，60 fps → 30 / 60 / 60 / 60） | 与今天的四个按钮等价，老用户察觉不到变化 |
| `TransitionState.init` 默认 | `slots = factoryDefaults(for: .hd1080p60)`、`currentSlot = 1` | `TransitionState()` 不知道帧率，按 60 fps 给；`MixerState.newShow(format:)`（027 的工厂）按节目帧率重算四个槽 |
| 不变 | `type` / `durationTicks` / `wipe` / `stinger` / `progress` / `source` / `startTick` | 渲染器只看这几个，一个字节不动 |

JSON：`transition` 对象多 `"slots": [ {type, durationTicks, wipe, stinger} × 4 ]` 与 `"currentSlot": 1`（nil 时不写键，合成 Codable 对 Optional 的做法）；`slots` 写出总是写全。

### B. 命令（Command.swift，35 → 38 个 case）

| 命令 | 规则（reducer）| 校验器（入口 400） |
|---|---|---|
| `setTransitionSlot(slot: Int, config: TransitionSlot)` | 只改槽 `slots[slot − 1]`；**转场进行中也收**（只是改配置）；`durationTicks` 钳 ≥ 0、`wipe.softness` 钳 0–1、`stinger.cutAtTick` 钳 ≥ 0（与 016 同口径）；改的若正好是 `currentSlot` 且**没在转场**，当前那组同时按槽重拷（T-bar / 回车马上用新配置）；若正在转场，进行中的那一次按开始时的参数走完，**完成那一拍把当前那组按槽重拷一次**（`completeTransition` 在 currentSlot 非 nil 时总是重拷，幂等）；相同配置原样返回（applied = false） | slot 不在 1…4；`config.stinger.input` 非 nil 且不存在 |
| `useTransitionSlot(slot: Int, start: Bool)` | 把槽拷进当前那组、`currentSlot = slot`；`start = true` 同时开始 auto 转场（类型 cut 或时长 0 = 原子对调，与 `autoTransition` 同口径），一拍内原子完成，代替 UI 现在一次发两三条命令；`start = false` 只选中（T-bar / 回车用）；**转场进行中被拒**（与 setTransition / autoTransition 同口径）；start = false 且槽已是当前槽、当前那组与槽相同 → 原样返回 | slot 不在 1…4 |
| `setFTBDuration(ticks: Int)` | `ftb.durationTicks = ticks`（存拍，界面按秒填、按节目帧率换算）；FTB 渐变**进行中**时按"当前电平对应的起点"回拨 `ftb.startTick`（reducer 已有的 `equivalentStart`），电平从当前值按新时长继续走、不跳变；相同值原样返回 | ticks < 0 |
| 原有 `fade` / `setTransition` / `setTransitionParams` | 语义不变，执行后 `currentSlot = nil`（当前那组不再对应任何槽；R3a C 附 3） | 不变 |
| 原有 `autoTransition` / `tbar` / `cut` / `ftb` | 不变（用当前那组 / 现有 `ftb.durationTicks`） | 不变 |
| 原有 `removeInput` | 清引用的规则扩到 4 个槽：`slots[k].stinger.input == input` 的置 nil（当前那组照旧） | 不变 |

Stinger 槽没选输入时 `useTransitionSlot(slot, start: true)`：reducer 照常开始（与现在 `setTransition(.stinger)` + `autoTransition` 的行为一致，渲染器对 nil 输入不叠任何东西），界面按 X18 拦在前面（点主体 = 打开 ▾ 停在输入选择），不在契约里另做规则——要 reducer 拒请在批注里说明。

### C. 搬迁与校验

- `Show.migratingLegacyKeys()`（Show.load / loadShow 共用）：文件缺 `slots`（020 之前写的）→ 按 `mixer.format` 补出厂四槽，**槽 1 换成文件里原来那组**（type / durationTicks / wipe / stinger；原来是 cut 的改用 Fade 0.5 s），`currentSlot = 1`；缺 `currentSlot` 但有 `slots` → nil；四个槽里指向不存在输入的 `stinger.input` 置 nil（P4 清当前那组悬空引用的规则扩到槽）。幂等。
- `TransitionState.init(from:)`：缺 `slots` 解成 `[]`、缺 `currentSlot` 解成 nil，由搬迁补齐；`validate()` 要求恰好 4 个，所以没经搬迁的状态进不了状态机（`CommandValidator` 对 loadShow 先 `validate`，与 P4 一样"校验器与 reducer 判得一致"——loadShow 的校验改成**先搬迁再 validate**，否则老节目会被 400 拒；P4 报告 §5 第 3 条预告过这件事）。
- `MixerState.validate()` 两条新不变量（见 A）。

### D. 文档 / 目录

CONTRACTS.md §2.5（TransitionState / TransitionSlot 行、搬迁一节）、§2.6（命令数 38）、§8（三行）；CommandCatalog 三条（`setTransitionSlot` / `useTransitionSlot` 面向操作员，`config` 是结构体 → `setTransitionSlot` 归"高级：手写 JSON"）；docs/api.md 重生成；`ControlAction` 的"执行转场 n""选中转场 n（不执行）"归 100。

## 为什么

- 转场槽是外部控制要能点名的状态：快捷键 / MIDI / API / 兼容层（Transition1–4、SetTransitionEffect1–4、SetTransitionDuration1–4）/ Stream Deck 都要按槽触发、按槽改配置，按单状态机的规矩该进契约（设计方案 §12 决策 3）；先走 A′（存 Show.layout）再转正，节目文件格式要改两次（04 Q01 建议 A，用户按 §8.5 默认 A）。
- 一拍内原子完成：现在 UI 点一个效果 = 同一轮发 setTransitionParams + setTransition + autoTransition 三条，中间两拍的快照是"参数变了但没开始"，API 观察者与 tally 都能看见；`useTransitionSlot` 一条做完。
- 同一种效果能有不同时长（"Fade 0.5 s"和"Fade 2 s"并存）、最多四套 Stinger；删输入时 reducer 统一清掉槽里的 Stinger 引用（A′ 要 App 自己清）。
- FTB 时长（Q08 (a)）：契约里有 `ftb.durationTicks` 却没有改它的命令，界面、快捷键、API 都改不了，手册"默认与转场相同"是错的（docs/user/概念.md:63）；"慢渐黑 + 快切"要并存，所以不跟随转场时长（Q08 (b) 不选）。

## 影响谁

| 谁 | 改什么 | 归谁 |
|---|---|---|
| SwitcherContracts + 测试 | A / C 的类型、搬迁、`validate()`、Command 三条、键名快照、老文件（g3 / g4 / m0 节目）照读 | P5 |
| SwitcherEngine reducer + ReducerTests | B 的规则、`completeTransition` 重拷、removeInput 扩到槽 | P5 |
| SwitcherControl CommandBus（目录 / 校验器）+ 测试、docs/api.md | 三条命令；loadShow 校验先搬迁；命令数 38 的三处快照 | P5 |
| SwitcherRender | **不改**：只看当前那组 | — |
| App 转场列、"切换"菜单、T-bar 行、格子"转场"按钮 | 点主体 = `useTransitionSlot(n, start: true)`，▾ = `setTransitionSlot`，"用于 T-bar" = `useTransitionSlot(n, start: false)`，FTB 右键 = `setFTBDuration` | 100 |
| Hotkeys / MIDI（`ControlAction`）| "执行转场 n""选中转场 n"两类动作，默认表 ⌥1–⌥4 | 100 |
| VMixCompat | Transition1–4 / SetTransitionEffect1–4 / SetTransitionDuration1–4 从 knownUnimplemented 拿掉、接到槽；转场中 `Cut Input=n` 的口径（W5-E 问题单）一并定 | 100 |
| Stream Deck 插件 | 转场 1–4 按钮，颜色跟当前槽 | 100 |
| headless / 场景脚本 | 不改：m0 / g3 / g4 / soak 工厂建的节目经搬迁补出厂槽（槽 1 = 工厂里的那组）；`scenarios/*.json` 的事件只用 cut / fade / setTransition / autoTransition / tbar | — |
| 文档 | docs/user/概念.md:61–63（转场 / FTB 时长）、docs/api/README.md 的"34 条命令" | 103 |

## 怎么迁移

- `Show.schemaVersion` 不升：新字段都有默认；老文件缺 `slots` / `currentSlot` 按 C 搬迁，读进来就是"出厂四槽 + 槽 1 = 原来那组"；写出带 `slots`。
- 020 之前的程序读 020 之后的文件：合成 Codable 忽略多出来的键，照读（它不认识槽，仍按当前那组工作）。
- API 客户端：`GET /state` 的 `transition` 多两个键；原有命令语义不变（多了"执行后 currentSlot = nil"）。直接写 `transition.slots` 的只有 loadShow / setTransitionSlot。
- 不批的话：按 Q01 A′ 过渡——槽存 `Show.layout["transitionSlots"]`、App 自己发三条命令（代价见 04 Q01），FTB 时长仍只能改节目文件。

## 请用户定的点（默认按上表，批注里改哪条改哪条）

1. `useTransitionSlot` 的 Stinger 槽没选输入：reducer 照常开始（默认）还是拒收？
2. 进行中改当前槽：完成那一拍重拷（默认）还是直接拒收？
3. `setFTBDuration` 在 FTB 渐变中：回拨起点不跳变（默认）还是拒收？
4. 命令数 35 → 38（三条）。若嫌多，`setFTBDuration` 可以并进 `ftb(on:durationTicks:)`——但那会改 `ftb` 的 JSON 形态（W2-C 客户端在用），不建议。

## 落地记录（P5-2 / prompt 108，2026-10-11，提交 51e614e）

按 A / B / C / D 落了，四个"请用户定的点"全按默认（Stinger 槽没选输入照常开始；进行中改当前槽完成那一拍重拷；FTB 渐变中回拨不跳变；三条命令不并进 ftb）。与提案正文不同的三处（都是落地时才看清的细节，不改语义）：

1. **`currentSlot` 的默认不是写死 1，而是"自动对号"**：`TransitionState.init` 不给 currentSlot 时 = 当前那组与某个槽相同就是那个槽，否则 nil。`TransitionState()`（fade 30）= 槽 1，与提案相同；
   但 `TransitionState(type: .cut, durationTicks: 0)` 这种裸状态（SwitcherInputs 的 harness、headless 的 soak 工厂都在用）= nil——写死 1 的话第一次 cut 完成就会把当前那组重拷成 Fade 0.5 s，脚本从此不再 cut。
2. **搬迁遇到原来是 cut 的文件**：槽 1 用 Fade 0.5 s（提案写的），但 currentSlot = nil、当前那组仍是 cut（提案写 1）。理由同上：读进来就"察觉不到变化"。非 cut 的文件槽 1 = 原来那组、currentSlot = 1，与提案相同。
3. **老命令执行后 currentSlot**：提案写"执行后 = nil"；落成"= 当前那组仍对得上的槽（优先原来那个），对不上任何槽才 nil"——`setTransition(fade, 30)` 之后槽 1 的高亮不该灭。`fade` / `setTransition` / `setTransitionParams` 三条都这么做。

其余逐条：`TransitionSlot{type, durationTicks, wipe, stinger}` + `count / indexRange / factoryDefaults(for:)`（秒按帧率 round 换拍，与叠加默认淡入同一算法）+ `jsonKeys`；
`TransitionState.slots / currentSlot` + 显式 `init(from:)`（缺 slots → []、缺 currentSlot → nil）+ `currentGroup` / `select(slot:)` / `slotIndexMatchingCurrentGroup(preferring:)`；
`MixerStateError.transitionSlotCount / transitionSlotIndex`，`validate()` 两条不变量；`MixerState.newShow(format:)` 按帧率重算四槽、当前那组 = 槽 1；
`Show.migratingLegacyKeys()` 补槽 + 清槽里悬空的 Stinger 引用；reducer：`setTransitionSlot`（进行中也收、钳位同 016、改当前槽空闲时重拷）、`useTransitionSlot`（进行中拒、start 一拍内原子完成）、
`setFTBDuration`（渐变中 `equivalentStart` 回拨、0 立即到位）、`completeTransition` 按 currentSlot 幂等重拷（cut / auto 完成 / T-bar 提交都走它）、`removeInput` 清四个槽的引用；
校验器：槽号 1…4、Stinger 引用、FTB 负时长入口就拒，**loadShow 改成先 `migratingLegacyKeys()` 再 validate**；目录三条（`setTransitionSlot` 归"高级：手写 JSON"，`CommandFieldType.transitionSlot` 四段）→ docs/api.md；
CONTRACTS.md §2.5 / §2.6 / §2.8 / §8；Samples 的四槽非默认值；`test016_existingShapesUnchanged` 改成只钉 016 当时那几个键（TransitionState 的 JSON 多了 slots / currentSlot）。
用例：`Contracts020Tests`（6 条）、`ReducerTests.test020_*`（6 条）+ 覆盖表 20 行、CommandBusTests 合法 / 非法各 6 条、CommandCatalogTests 字段描述。
界面 / 快捷键 / 兼容层 / Stream Deck 归 100；SwitcherRender 没动一个字节。

## 2026-10-17 用户裁定：T-bar 拉回 0 取消也重拷（P5-4 落地，prompt 115）

P5-3 探针核实的缺口（reports/p5-contracts-3.md §4 第 2 条）：T-bar 推到一半时 `setTransitionSlot` 改了当前槽（进行中只改槽），之后拉回 0 **取消**——取消不走 `completeTransition`、当前那组不重拷，下一次回车执行的是改之前的旧配置（探针：槽 1 改成 Zoom 12 拍后拉回 0，回车执行 Fade 30）。
用户 2026-10-17 定：**修**。reducer 的 `tbar` 在 progress 回到 0（取消）那一拍按 currentSlot 重拷当前那组（与 completeTransition 同一句，幂等）；本提案与 CONTRACTS.md §2.5 的口径从"完成那一拍重拷"改成"**完成或取消那一拍重拷**"。不加字段、不加命令。
