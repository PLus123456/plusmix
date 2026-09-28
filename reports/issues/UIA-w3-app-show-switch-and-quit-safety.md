# 新建 / 打开 / 换节目格式会不问一声停掉录制推流；新建丢未保存改动，退出却静默覆盖原文件

归属会话 / 分支：App 会话（W3-E 系）；`App/Sources/AppController.swift`、`App/Sources/Settings/PreferencesPanel.swift`、`App/Sources/UI/PanelCoordinator.swift`
发现于：界面对照调研 UIA，提交 c836cce；R3a-M19、R1-M05，核对 VF1 §4 第 5 条、VF3
现象：
1. 节目 › 新建 / 打开：直接换 session，录制、推流一起停，事先不确认（这两个入口以后还要放到窗口工具条上，见 01a-改动总表 A 区）。
2. 偏好设置 › 节目格式 › 应用格式（重起引擎）：同样停掉录制推流、连偏好设置窗自己也被关掉，不确认。
3. 新建 / 打开前不保存也不自动存，当前节目没保存的改动直接丢，也不进 LastSession；而退出时会把当前状态静默写回已打开的节目文件——两条路径的语义相反。docs/user/概念.md:90 只写了"未保存的节目自动存到 LastSession"，没写退出会覆盖原文件。
复现步骤：开录制 → 节目 › 打开… 选另一个节目，录制立刻停；改一个节目不保存 → 节目 › 新建，改动没了；打开 A.switcher.json 改几处不保存 → 退出，A 被覆盖。
严重级：S2
猜测原因：`App/Sources/AppController.swift:121-151`（replaceSession）、`:203-215`（新建 / 打开）、`:111-115`（shutdown 写回 currentURL）、`:154-160`（换格式）；`App/Sources/UI/PanelCoordinator.swift:29-49`（换 session 关掉设置窗）。
建议改法：有录制 / 推流在跑时，新建 / 打开 / 换格式先弹 sheet 说明"会停止 n 路录制、m 路推流"；节目有未保存改动时问"保存 / 不保存 / 取消"（用 window.isDocumentEdited 标出来）；退出时是否写回原文件由用户定（04-待拍板 新增的 Q67），至少和新建 / 打开同一口径。
