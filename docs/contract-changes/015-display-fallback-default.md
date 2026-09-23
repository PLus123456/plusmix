# 015 `DisplayOutputSettings.fallbackToMain` 的默认值改成 false（与 W3-C 的运行时一致）

提出会话 / 分支：G4 续做合入 / g4（2026-09-23；来源 reports/p3-contracts.md §4 第 2 条）
状态：**已落地**（用户 2026-09-23 批："015 批了 … 你顺手做了"；G4 续做合入会话按授权落地：`MixerState.swift` 默认与缺键都改 false、`ContractsP3Tests.testP3_013_displayEntryAndDisplaySettings` 的两处断言改过来并补一条"显式 true 照解"、`Show.swift` 搬迁注释、docs/CONTRACTS.md §2.5 一句；`ExternalDisplaySpec` 与 App 不用改，App 显式写的 false 现在与默认相同，可由 W3-E2 顺手去掉）

## 改什么

提案 013 给 `OutputSettings.display: DisplayOutputSettings?` 定的默认是 `fallbackToMain: Bool = true`（显示器不在时退回主显示器）。
W3-C 的 `ExternalDisplaySpec` 从 G4 起的运行时默认是 **false**（黑着等显示器回来），P3 落地时为了不改行为让 App 新建输出显式写 false，
结果"节目文件里没有 display 字段"与"有 display 字段但缺 fallbackToMain"两种情况语义不同（前者 false、后者 true）。

改成：
```swift
/// 显示器不在时：false（默认）= 黑着等它回来，不动主显示器；true = 退回主显示器全屏（会盖住操作界面，只在明确要的时候开）。
public var fallbackToMain: Bool = false
```
JSON 不变（缺键按默认解，默认值照写全）；`ExternalDisplaySpec` 不用改；App 面板不用再显式写 false。

## 为什么

- 两处默认值不一致就是隐患：哪天 App 不写显式 false，行为就翻了。
- false 才是对的默认：PGM 外部窗口在显示器拔掉时突然全屏盖住操作者的主屏，比黑着等更糟；要退回主屏的场合让用户显式开。

## 影响谁

SwitcherContracts（一行 + `ContractsP3Tests.testP3_013_displayEntryAndDisplaySettings` 的默认值断言）、docs/CONTRACTS.md §2.5 一句、App `OutputExtras` 可以去掉显式写 false（W3-E2 顺手）、W3-C2 删过渡读取时按新默认。

## 怎么迁移

老文件：缺键按新默认 false 解——与 G4 起的运行时行为一致，没有用户可见的变化；写过 `"fallbackToMain": true` 的文件照旧。`Show.schemaVersion` 不升。
