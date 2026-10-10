# 027 新节目叠加动画的默认值统一成淡入 0.5 s（进契约默认值，不只在 App 的 emptyShow 里写）

提出会话 / 分支：W5-K（prompt 97，`w5-app-panels`；reports/w5-app-panels.md §4 第 3 条），G7 检查点转述（reports/G7.md §7.1 第 6 条）；本文件由 G7 按用户 2026-10-10 的裁定写成决策记录
状态：**已批**（用户 2026-10-10："升正式字段"——统一进契约默认值）。由 P5（prompt 99）落地；App 的 emptyShow 改调契约工厂（≤ 50 行，P5 的 App 胶水或 101）

## 改什么

现状：契约 `OverlayAnimation()` = cut、0 拍（`OverlayState.init` 的默认）；App 新建节目（emptyShow）另给四路叠加写 fade 0.5 s（按节目帧率换算成拍）；API / headless 建的节目仍是 cut。

改成：**新建节目（`MixerState` 按 `ProgramFormat` 建默认状态）时四路叠加的默认动画 = fade，时长 = round(0.5 s × 节目帧率) 拍**。`OverlayAnimation()` 这个无参默认不知道帧率，保持 cut 0 拍不变；另加 `OverlayAnimation.defaultFade(for: ProgramFormat)`（或等价的静态工厂）供 `MixerState.init(format:…)` 与 App 共用。落法细节由 P5 定；docs/CONTRACTS.md §2.5 写明"新节目默认淡入 0.5 s；老文件照读"。

## 为什么

同一个产品从 App、API、headless 建出来的新节目叠加行为应一致（W5-K §4 第 3 条，I3 原文"不动契约默认值"由用户 2026-10-10 改成"统一进契约"）。

## 影响谁

SwitcherContracts（MixerState 默认 overlays、工厂、测试 `testContracts_newShowOverlayDefaultsToHalfSecondFade`）；App 的 emptyShow 改调契约工厂；headless 新建节目路径；渲染 / 多画面不变。

## 怎么迁移

不升 schemaVersion；已存文件里的 animation 照读不变；只影响新建的节目。
