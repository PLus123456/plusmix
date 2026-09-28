# 底栏"外部输出"菜单与"叠加…"弹出层往下弹，伸出主窗口（用户点名的"菜单超出边框"）

归属会话 / 分支：App 会话（W3-E 系，下一个续做会话）；`App/`
发现于：界面对照调研 UIA（分支 claude/vmix-28-guide-menu-ui-c83cd1），提交 c836cce；实测记录 docs/ui-study/03-目视检查.md §2、docs/ui-study/附录/目视检查-弹出物几何.md
现象：
- "外部输出"菜单在 1440×900 / 1100×700 / 贴屏幕上沿 / 按内建屏铺满四种窗口位置下，每次都伸出主窗口下沿 25 pt、盖住状态行；它的"显示器 ▸"子菜单伸出 228 pt（截图 docs/ui-study/img/外部输出菜单-改前.png、外部输出子菜单-改前.png）。
- "叠加…"弹出层：窗口下方屏幕放得下时（1100×700）整块弹到窗口外，伸出 318 pt；放不下时翻到上方，但内容区只有 320×320、装的是 400×640 的表单，每行标签头一两个字被裁掉（"动画"→"画"、"Overlay 2"→"verlay 2"）（img/叠加弹出层-改前-*.png）。
- 参考软件底栏的菜单都朝上开、贴按钮上沿（竞品截图图 119、133、146）。
复现步骤：窗口 1440×900 居中（下方留出屏幕空间），点底栏"外部输出"；把窗口调成 1100×700 居中，点"叠加…"。
严重级：S2（叠加面板内容被裁、部分标签读不出）；菜单伸出窗口本身 S3
猜测原因：已查实。
- `App/Sources/UI/MainWindowController.swift:297`：`menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)`，NSButton 是翻转坐标（isFlipped == true，探针已确认），y = bounds.height 是按钮下沿。
- 同文件 `:281`：`popover.show(..., preferredEdge: .maxY)`，翻转坐标里 .maxY 也是下沿。
- `App/Sources/UI/OverlayPanel.swift:208-212` 用 NSHostingView 装表单、没设 preferredContentSize；表单在 `:168` 固定 400×640。
建议改法（临时拷贝里原型已实测，见 03 §2.2）：
1. 菜单往上开：`at: NSPoint(x: 0, y: -menu.size.height + 1)`；把"显示器 ▸"子菜单拍平成段标题（只往上开时子菜单仍伸出 147 pt）。
2. 叠加面板：`preferredContentSize = 400 × min(640, 窗口内容高 − 120)`，`preferredEdge = .minY`（翻转坐标里是上沿），表单高度可伸缩。
3. 抽一个底栏弹出的小工具函数，以后的 ▴ 菜单都走它；加一条 App 用例：底栏每个弹出物的 frame 在主窗口 frame 内（建议名 testUI_bottomBarPopupsStayInsideWindow）。
关联：docs/ui-study/01a-改动总表.md E1；docs/ui-study/04-待拍板.md Q03。
