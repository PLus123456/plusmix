# 外部显示"每块屏一路"的规则有两份实现（W5-F 的菜单 / W5-I 的设置页）

归属会话 / 分支：App 会话（`App/Sources/UI/ExternalOutputMenu.swift` 的 `ExternalOutputMenuBuilder`（W5-F）与 `App/Sources/Settings/ExternalDisplayRouting.swift`（W5-I））
发现于：G7 检查点合入 W5-I 时（reports/w5-app-output-pages.md §3 第 1 条、§5 第 1 条第 3 点：95 从 main 开、拿不到 92 的函数，于是把规则抄了一份）
现象：
- 两份都实现"每块屏的那一路 = 开着的优先、否则编号最小；选源 = 那一路换源并打开、同屏别的开着的路关掉；没有那一路 = addOutput「显示器 · 源」；关闭 = 只关不删"，逐条相同、各有用例（`BottomBarPopupTests` / `ExternalOutputAppTests` 与 `OutputPagesTests.testPanels_M5_externalPagePerScreenSingleSelect`）。
- 以后改规则（比如用户定"每块屏无条件列关闭"、或主屏口径从 NSScreen.main 改成菜单栏那块屏）要改两处、两套用例。
复现步骤：—（代码结构问题，行为一致）。
严重级：S3（维护）。
建议改法：菜单改调 `ExternalDisplayRouting`（W5-I 的建议，≤ 50 行）：`ExternalOutputMenuBuilder.primaryOutput / select / turnOff / toggleAll` 换成转调 `ExternalDisplayRouting.pick / off / primary`，菜单只负责拼项；两套用例都留（一套测菜单结构、一套测规则）。G7 没做：检查点不写功能，且不是放行阻塞。
