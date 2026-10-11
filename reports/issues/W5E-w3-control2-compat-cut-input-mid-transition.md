# 兼容层 `Cut Input=n` 在转场进行中落不到 n 号：setPreview 被拒、cut 把正在进行的那次做完

归属会话 / 分支：兼容层（W3-D / `w3-control2` 写的 `Packages/SwitcherControl/Sources/VMixCompat/FunctionTranslator.swift`；第五波里 VMixCompat 归 W5-M / `w5-transition-slots`，prompt 100）。
HTTP 批量的文档那半归 API 文档的会话（`Packages/SwitcherControl/Sources/SwitcherControl/API/APIDocument.swift` / docs/api.md）。
发现于：W5-E（prompt 90，分支 `w5-core-transition-guard`）实现"转场进行中拒收 setPreview / setProgram"（Q66 (a)，用户 2026-09-29 定；契约文字见 docs/contract-changes/023-小口径收口.md 第一节）时顺查调用方。
不是 W5-E 引入的 bug，是规则变了之后组合命令的结果跟着变；口径归兼容层的会话定，W5-E 不动兼容层。

现象：
- 兼容层 `Cut` 带 `Input=n` 翻译成 `[setPreview(n), cut]`（FunctionTranslator.swift:25-29）。空闲时结果 = PGM n，与原意一致。
  转场进行中：setPreview(n) 被 reducer 拒（applied = false），cut 把**正在进行的那次**转场立即做完，PGM 落在原来那次转场的目标上，不是 n；
  函数回 "Cut"（有一条命令生效），客户端以为切到了 n。W5-E 之前：setPreview(n) 先把切进来的画面换成 n（PGM 上跳一下），cut 后 PGM = n。
- `Fade` / `Wipe` / `Zoom` 带 `Input=n`（setPreview + fade 或 setTransition + autoTransition）：转场中整组被拒，回 "Fade (no change)" 之类，行为一致、没问题。
- HTTP 批量 `{"commands": [setPreview(n), cut]}`（APIDocument.swift:60 / docs/api.md:51 拿它当批量的例子）同理：回执 [applied false, applied true]，PGM 不是 n。客户端看回执能发现，但例子没提。

复现步骤（规则合入后）：
1. 1 号 PGM、2 号 PVW，发 `Fade` Duration=2000（或回车）。
2. 1 秒内发兼容层 `Cut` Input=3。
3. 期望（原意）：PGM = 3；实际：PGM = 2（Fade 被提前做完），回 "Cut"。

严重级：暂定 S2（有绕过办法：转场结束后再发，或先发 Cut、再发 ActiveInput n；只在"转场进行中再点名切某一路"时出现，画面不跳，回执 / 快照能看出来）。
但结果是"PGM 上不是点名的那一路"，按测试标准 §6 字面的"切换错误"也可能被算 S1 / S0——由检查点（G6）或用户定。这是 W5-E 的规则带出来的变化（之前 PGM 会是 n），所以 W5-E 报告 §5 和交给用户的问题里都写了。

建议（任选其一，归兼容层定）：
- (a) FunctionTranslator 拿到 `state.transition.isActive` 为真、且带了 `Input` 时直接回错误（例如 `ER transition in progress`），不发半截命令；
- (b) 转场中改翻译成 `[cut, setProgram(n)]`：cut 先做完当前转场，setProgram 再硬切到 n（同一拍应用时画面直接是 n；但会多一条 cut 事件，AFV 看到两次切换）；
- (c) 维持现状，在 docs/api/vmix-compat.md 与 docs/integrations/vmix-compat.md 写明"转场进行中 Cut 带 Input 只会做完当前转场"。
HTTP 批量那半：APIDocument / docs/api.md 的批量例子旁加一句"转场进行中 setPreview 被拒，看回执"即可。

## 处理结果（W5-M / prompt 100，分支 `w5-transition-slots`，2026-10-11）

三选一定 **(a)**：转场进行中（`state.transition.isActive`，T-bar 推到一半也算）带 `Input=` 的 `Cut` 直接回 `NotConfigured`（HTTP 409，TCP `FUNCTION ER NotConfigured: Cut: a transition is in progress; …`），**一条命令都不发**；不带 Input 的 `Cut` 照旧把当前转场做完；空闲时照旧"先放 PVW 再切"。
`Input=` 引用不存在的输入仍先报 `InputNotFound`。没选 (b)：多一次 cut 事件、AFV / tally 会看到两次切换，录像里可能闪一帧中间画面；没选 (c)：回 OK 而 PGM 不是点名的那一路，客户端察觉不到。
`Fade / Wipe / Zoom` 带 Input 在转场中整组被状态机忽略、回 "(no change)"，没有半截执行，维持现状。
代码：`Packages/SwitcherControl/Sources/VMixCompat/FunctionTranslator.swift`（`case "cut"`）；用例：`FunctionTranslatorTests.testC5_cutWithInputDuringTransitionIsRefused`、`HTTPTests.testC5_http_transitionSlotsAndCutDuringTransition`（Fade 进行中发 `Cut&Input=3` → 409、总线序号不变、Wipe 做完 PGM = 原 PVW）。
**还剩 HTTP 批量那半**：`Packages/SwitcherControl/Sources/SwitcherControl/API/APIDocument.swift` 与 docs/api.md 的批量例子旁加一句"转场进行中 setPreview 被拒，看回执"——API/ 与 docs/ 都不在 W5-M 的目录，留给下一个碰 API 文档的会话（docs 部分并进 W5M-w4-docs-2-transition-slots-docs.md）。
