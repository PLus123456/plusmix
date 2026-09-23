# 016 加一条命令 `setTransitionParams(wipe:stinger:)`：改 Wipe / Stinger 参数不再整体替换节目状态

提出会话 / 分支：W3-E2 / `w3-app-3`（2026-09-23；prompt 63 交付第 2 条："现有命令只有 setTransition(type:durationTicks:)，这两组参数目前只能 loadShow 整体替换——
先按替换做并写清楚；若嫌不妥，写提案加 setTransitionParams"。prompt 原文写的编号是 013，但 013 已是显示类输出那条，顺延到 016）
状态：**待批**

## 改什么

`Command`（Command.swift）加一个 case，reducer / `CommandValidator` / `CommandCatalog` / `docs/api.md` 各加对应分支：

```swift
/// 改 Wipe / Stinger 参数（TransitionState.wipe / .stinger，整体替换这两组）。转场进行中也可以改：下一次转场起生效，
/// 进行中的那一次仍按开始时的参数走（渲染器每拍读快照，所以 reducer 在 isActive 时拒绝，与 setTransition 同一口径）。
case setTransitionParams(wipe: WipeParams, stinger: StingerParams)
```

| reducer 规则 | |
|---|---|
| `s.transition.isActive` | 拒绝（与 `setTransition` 一致：进行中的转场不换参数） |
| `stinger.input` 不是 nil 且不存在 | 拒绝（与 overlay / setPreview 的引用校验一致） |
| `wipe.softness` | 钳到 0–1（渲染器的定义域；界面自己再限 0–0.3） |
| `stinger.cutAtTick` | 钳到 ≥ 0（≥ durationTicks 的语义是"完成时换"，不钳上限） |
| 与现值相同 | 原样返回（回执 applied = false） |

JSON：`{"setTransitionParams":{"wipe":{"direction":"topToBottom","softness":0.2},"stinger":{"input":9,"cutAtTick":12}}}`。

## 为什么

现在（W3-E2 已实现）的做法是 App 拿自己手里的最新快照、换掉这两组、发 `loadShow`（`App/Sources/UI/TransitionParams.swift`）。能用，但有三个毛病：

1. **会盖掉别人的改动**：快照到命令进状态机之间（≤ 1/60 s 的轮询 + 命令队列），API / MIDI / 快捷键 / 兼容层改的任何东西（切 PGM、开叠加、推子……）
   都会被这次整体替换改回去。直播中 Companion 按一下 Cut、同时导播在面板上拖软边，就可能丢掉那次 Cut。
2. **`loadShow` 会 `resetTransientState`**：转场、叠加进出动画、FTB 渐变都会被直接打到终点（转场是作废、不对调）。App 现在只能等全部空闲再发，
   面板上"等当前动画结束后生效"——参数改了却不能马上生效，用户会困惑。
3. **API 客户端没法改这两组参数**，除非也整体替换节目状态（同样的两个毛病，还要自己拼整个 Show）。

`TransitionState.wipe` / `.stinger` 是契约里的正式字段（W3-B 用），有界面、有 API 需求，就该有对应的命令（同提案 012 对 monitorMode / 总线效果链的理由）。

## 影响谁

- SwitcherContracts：Command 一个 case + 编解码快照（`Command` 33 → 34）；`CommandKind` / 目录；docs/api.md 重生成。
- SwitcherEngine：MixerReducer 一个分支（约 8 行）。
- SwitcherControl：CommandValidator 一个分支（stinger.input 引用校验）；HotkeyEditor / MIDI 的 ControlAction 不用改。
- App（W3-E 系列）：`TransitionParamsModel.flushIfIdle` 改发新命令、去掉"等空闲"那段（约 −15 行）；`TransitionPanelTests` 的延后用例改成"转场中改被拒、结束后再发"。
- headless / 场景文件：新 case 可选，旧场景不受影响；W3-D 兼容层不受影响（它的 Wipe / Stinger 协议项现在就没有）。
- 若 P3 报告 §4 第 4 条的建议（叠加类命令合并成整体替换的 `setOverlaySettings`）哪天做，转场这边也可以一并收成 `setTransitionSettings(TransitionSettings)`；
  那是破坏性的 wire format 变更，本提案只加一条、不动现有的。

## 怎么迁移

只加命令，不加字段：`Show.schemaVersion` 不升，老 JSON 命令原样可解。不批的话 App 继续用 loadShow 整体替换（上面三条毛病照旧，已写进 reports/w3-app-3.md §3）。
