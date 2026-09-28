# 转场进行中改 PVW / PGM 不被拦：正在切换的画面被中途换掉（口径待用户定）

归属会话 / 分支：核心会话（W1-B 系，`Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift`）；口径若写进契约说明（docs/CONTRACTS.md）走提案
发现于：界面对照调研 UIA，提交 c836cce；R3b-M14、核对 VF1 §4 第 8 条，调研会话复核属实
现象：Fade / Wipe / Zoom / Stinger 进行中，按数字键或点缩略图（setPreview）会把正在切进来的画面换成另一路；Shift + 点缩略图（setProgram）会把正在切出去的底图换掉。PGM 上表现为转场中途画面跳变。
复现步骤：1 号在 PGM、2 号在 PVW，按回车做 2 秒 Fade，1 秒时按 3。
严重级：S2（直播画面可见的跳变；操作员在转场中按数字键很常见）——前提是这不是有意的设计，请用户定口径
猜测原因：`MixerReducer.swift:99-104`：setPreview / setProgram 没有 `!s.transition.isActive` 保护，而 fade / setTransition / setTransitionParams / autoTransition 都有；渲染器转场中按当前 program 画底、按当前 preview 画切入画面（`Packages/SwitcherCore/Sources/SwitcherRender/Renderer/CompositorPasses.swift:246-256`）。
建议：先请用户在三种口径里选（04-待拍板 新增的 Q66）：(a) 转场中拒收 setPreview / setProgram（最像硬件台，最安全）；(b) 收下但转场按开始时的两路走完，完成后再生效（要多记两个字段，契约）；(c) 维持现状并写进手册。选 (a) 只改 reducer 两行 + 用例；格子上的"转场 / Cut"按钮也要按同一口径判断。
