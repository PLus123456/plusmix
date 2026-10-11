# App `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` 2026-10-11 在 main 上也红：点"关闭全部外部显示"后 output 7 的 enabled 3 s 内不变

发现会话：P5-2（prompt 108，分支 `p5-contracts-2`，2026-10-11 02:4x）。归属：App 会话 / G8a-2 合并时复核（App/Tests 不在 P5-2 目录里，且不是 P5-2 的回归）。

## 现象

`App/Tests/ToolbarMenuTests.swift:190`：
```
XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(7)?.enabled == false }, "菜单项：全部关（配置留着）")
```
前一步工具条主体 `bar.external.bodyButton.performClick` 把 7 号（phantom 外部显示输出，displayID 0x7EAD0001）开成 enabled = true 过了，`refresh(output)` 后的菜单项标题"关闭全部外部显示"也对；
`perform(output, toggle)`（`menu.performActionForItem` → 响应链 → `AppDelegate.toggleExternalDisplays(_:)` → `MainWindowController.toggleExternalDisplays()` → `ExternalOutputMenuBuilder.toggleAll` 的 turnedOff 分支 → `setOutputEnabled(7, false)`）之后 3 s 内 enabled 没变 false。
同一用例后面的几条断言（`!bar.isExternalHighlighted`、字色不是强调色）**没有**一起红，所以要么命令后来才生效（> 3 s），要么高亮不看这个状态——没查到底。

## 证据

| 跑法 | 结果 |
|---|---|
| 本分支 `make test-app`（228 用例） | 223 过 4 跳 **1 红**（就这一条） |
| 本分支 `xcodebuild test -only-testing:SwitcherTests/ToolbarMenuTests` | 10 用例 9 过 **1 红**（同一断言） |
| **干净 main 30e4659** 的临时工作树（`git worktree add` 到 scratchpad、`make gen`、同一条 `-only-testing`） | 10 用例 9 过 **1 红**（同一断言） |
| G8a 2026-10-11 凌晨（reports/G8.md §4.1）在同一台机器上的两遍 App 全量 | 0 红 |

本分支对 App 的改动只有：`ActionCatalog` 的穷举分组 / 三个 `CommandFieldType` switch、`ActionPicker` 的表单 switch、两份 strings 加 7 个动作名、`OutputRuntime` 起不来的路把原因填进 `last_error`（`Source.failed(directory:reason:)`，条件等价）——都不在这条路上；包侧 `setOutputEnabled` 的 reducer / 校验器一个字没动。
docs/KNOWN_ISSUES.md 第 128 行列的 ToolbarMenuTests 偶发红是另一条（`testUI_inputSettingsMenuTitleNamesInput`）。

## 怀疑

1. 本机当天的显示 / 窗口状态（显示类用例被盖住 / 锁屏就红的那一类；`ExternalDisplays.all()` 只有一块主屏 2560×1440）；
2. 共用的测试宿主 defaults（reports/w5-app-panels / w5-app-misc 都撞过：跨 worktree 共用、被别的会话写过值）——main 工作树与本分支同一台机器同一份 defaults；
3. `perform(output, toggle)` 走响应链时 key window / first responder 不在主窗口（前面刚收起 sheet、保存、开过设置窗）——但同一机器 G8a 时过了。

## 建议

G8a-2 合并时在安静的机器上（锁屏之前、没有别的会话）再跑一遍 App 全量；仍红就按 1–3 排：先 `defaults delete` 测试宿主的 suite 再跑、再看 `AppTest.delegate.validateMenuItem(toggle)` 之后 `controller.windowController.toggleExternalDisplays()` 的返回值与 `ControlRuntime.onFeedback` 有没有 `.ignored / .rejected`。
