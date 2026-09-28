# 主窗口分栏按比例缩放把输入条 / 调音台挤到下限以下；窗口位置与布局状态存了不读

归属会话 / 分支：App 会话（W3-E 系）；`App/Sources/UI/MainWindowController.swift`、`App/Sources/AppController.swift`、`App/Sources/Settings/InputSettingsPanel.swift`
发现于：界面对照调研 UIA，提交 c836cce；目视检查 V-02，核对 VF3 §4（N1，探针验证）、VF1 §4 第 6 条、R8-S50、R4-M21
现象：
1. 窗口缩小时分栏按比例缩放：1100×700 下输入条只剩 133 pt（声明 ≥ 190），头行和格子按钮被切；调音台宽 216 / 282（声明最小 340）；日志里 14 条约束冲突（截图 docs/ui-study/img/主窗口-改前-1100x700.png）。
2. 主窗口每次启动都回到屏幕正中，只记住了大小（设了 autosave 名后紧接着又 center()）。
3. Show.layout 里写的 mainWindowFrame、mixerPanelVisible、multiviewWindowVisible 三个键写了不读：打开节目不恢复调音台显隐和多画面窗口开关。
4. 所有输入的设置窗共用一个 autosave 名，同时开几路时每个新窗口都跳到同一个存档位置、叠在一起。
复现步骤：把窗口拖到最小；把窗口挪到屏幕左上角、退出、再开；收起调音台、保存、重开节目；连续打开 1、2、3 号的输入设置。
严重级：S2（1：最小窗口下格子按钮点不到）；2–4 为 S3
猜测原因：`MainWindowController.swift:108-125`、`:137-138`（子视图是 frame 管理，holding priority 不生效）；`:76` 与 `:80`；`AppController.swift:279-288`（只写）与 `MainWindowController.swift:192`（只恢复多画面窗口位置）；`App/Sources/UI/PanelWindowController.swift:31-32`、`InputSettingsPanel.swift:302-303`。
建议改法：分栏改用 NSSplitViewController，或 delegate `shouldAdjustSizeOfSubview` 对输入条 / 调音台返回 false（原型实测 1100×700 时输入条 197、调音台 339，img/主窗口-原型-1100x700.png）；去掉 :80 的 center()（只在没有存档时居中）；打开节目时读回这几个键；输入设置窗 autosave 名带编号。
