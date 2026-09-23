# W3-C 接进 App 的文案还是字面量，W3-E 的本地化扫描测试报 39 处

归属会话 / 分支：W3-E 续做（w3-app2 → 建议新开 `w3-app-3`，见 docs/plan/prompts/55）；文案在 W3-C 写的 App 文件里
发现于：G4 检查点合并 w3-outputs2 + w3-app2 后跑 `make test-app`（2026-09-20）

## 现象

`LocalizationTests.testL10n_noHardcodedChineseInUISources`（W3-E：App/Sources 里不许有写死的中文文案）失败，列出 39 处，全在 W3-C 的文件或
G4 合并冲突块里保留下来的 W3-C 菜单文案：

| 文件 | 处数 | 内容 |
|---|---|---|
| AppDelegate.swift | 9 | 输出菜单的虚拟摄像头子菜单（"虚拟摄像头"、"启用 / 停用虚拟摄像头输出"、"安装 / 激活扩展…"、"卸载扩展"、"查询扩展状态"、"状态：未知"）、菜单打开时的状态行、虚拟摄像头输出名 |
| AuxOutputRuntime.swift | 5 | 虚拟摄像头状态文案（"未启用" / "未启动" / "找不到虚拟摄像头设备…" 等） |
| ExternalOutputMenu.swift | 6 | 外部输出菜单（"外部输出"、"（没有显示器）"、输出名 "<显示器> · <源>"、状态行） |
| ISOPanel.swift | 6 | ISO 选路面板（标题、目录、剩余空间、"还能录 …"、ISO 输出名） |
| MultiviewWindowController.swift | 1 | 窗口标题 "多画面" |
| OutputRuntime.swift | 6 | 录制失败 / 磁盘低 / 切备用目录 / ISO 分支用完等提示 |
| SwitcherSession.swift | 6 | 输出事件 → 状态行提示（磁盘低、切备用、外部输出状态、虚拟摄像头起停 / 扩展状态） |

同一次合并里 G4 为底栏录制按钮的多路文案加了两个键（`bottom.recordingMany` / `bottom.recordStateMany`，两种语言各两行），其余没动：
39 处 ≈ 39 个键 × 2 个语言文件 + 代码改动，超过检查点 App/ 的胶水额度，也不是接线。

## 要做的

1. 上表 39 处改成 `L("键")`，键按 W3-E 的命名（`menu.output.virtualCamera.*`、`aux.*`、`externalMenu.*`、`isoPanel.*`、`notice.*`），
   `App/Resources/{zh-Hans,en}.lproj/Localizable.strings` 各加一份（`testL10n_bothLanguagesHaveSameKeysAndNoEmptyValues` 要两边键集合相同）。
2. `SystemExtensionInstaller.describe` / `ExternalDisplayManager.describe`（SwitcherOutputs 包里）返回的是中文文案，进了状态行；包不该管语言，
   建议它们返回枚举 / 英文标识，App 侧查表。这条动到 W3-C 的包，写在这里等 W3-C 认领或由续做会话按胶水额度处理。
3. 跑 `make test-app`：LocalizationTests 四条全绿。

## 处理结果（W3-E2 / w3-app-3，2026-09-23）

- 第 1 条：39 处全改 `L(键)`，两种语言各一份（`menu.output.virtualCamera.*`、`externalMenu.*`、`notice.*`、`aux.*`）；LocalizationTests 五条全绿（多了一条 `testL10n_packageStatusesLookedUpInApp`）。
- 第 2 条：包没改。App 按枚举查表（`App/Sources/Engine/OutputStatusText.swift`；`DiskEstimate.describe` 的替代在 `ISORoutes.remainingText`），事件只带枚举；
  包里剩下拼好的中文（`.failed` 原因、外部显示窗口标题）另开问题单 `W3E2-w3-outputs-3-package-status-text-language.md` 给 W3-C2。
- 第 3 条：见 reports/w3-app-3.md §2。
