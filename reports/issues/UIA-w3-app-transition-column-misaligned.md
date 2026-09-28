# 中间转场列没对齐：只有 6 个转场按钮满宽，其余控件挤向右边（用户点名的"中间那块丑、没对齐"）

归属会话 / 分支：App 会话（W3-E 系）；`App/`
发现于：界面对照调研 UIA，提交 c836cce；实测记录 docs/ui-study/03-目视检查.md §1、附录/目视检查-原始记录.md §2
现象（1440×900，x 从列左沿量）：六个转场按钮可见边 8…141；时长分段 28…141（缩进 20）；"Overlay"标签贴右、左边空 25 pt；Overlay 1–4 从 24 起（缩进 16）；"T-bar：Fade"标签随字长漂（Stinger 时左移 12）；T-bar 把手比按钮窄 12；small 控件仍用 13 pt 字；12 行一律间距 6、不分组；时钟 2 pt 白框、显示"12:13 上午"；列最小高 483，1100×700 时只分到 476，T-bar 行被压到 13 pt。FTB 开着时黑字压红底，对比 3.0:1。
复现步骤：开任一节目，看 PVW 与 PGM 之间那一列；把窗口缩到最小 1100×700 再看；按 F 开 FTB 看按钮文字。
严重级：S3
猜测原因：已查实。
- 主因：`App/Sources/UI/TransitionPanelView.swift:98` 的 `stack.alignment = .width`，NSStackView 不支持这个值（读回 0），等于没做横向对齐；只有 `:74-76` 给 6 个按钮设了宽度。
- `:61`、`:65`、`:72` 只改 controlSize 没配 small 字号；`:67`、`:88` 标签 `.center` 无效；`:84`、`:94`、`:99` 三套间距；`:109-110` 最小高；`TBarView.swift:49` 把手 inset；`ClockView.swift:16`、`:24-26`；`Theme.swift:61-64`（contentTintColor 管不到推按钮标题）。
建议改法（原型已实测，所有可见边落在 8…141，列最小高 409）：`.leading` + 每行宽度 = stack.width − 16；两档控件（regular 24 / 13 pt、small 20 / 11 pt）；组内 4、组间 8；把手同宽；时钟 56 高 1 pt 边框、模板 hmma；高亮态白字。完整布局表见 03 §1.3。加一条 App 用例：列内所有可见控件左右边一致（建议名 testUI_transitionColumnEdgesAligned）。
说明：这是只修排版；"转场 1–4 可配置槽"改版（01a-改动总表 C1–C4、04-待拍板 Q01）另算，定了再整列重排。
