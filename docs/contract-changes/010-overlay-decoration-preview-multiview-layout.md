# 010 叠加通道的边框 / 锚点 / PVW 预览标志、滑入方向，多画面布局的正式字段

提出会话 / 分支：W3-B / w3-compositor2（2026-09-19）
状态：**已落地**（p3-contracts，2026-09-23，提交 cb85fbe…c73aab2；过渡键搬迁对脏数据的加固 44d9144）：A1–A3 的正式字段全部加上（`OverlayState.border / anchor / previewOn`、`OverlayAnimation.slideFrom`、`OutputSettings.multiview: MultiviewLayoutSettings?`，`MultiviewCell.source` 复用 `OutputSource`、其中 `.multiview` 被渲染器忽略）。**A4 由 P3 定：加 `Command.setOverlayDecoration(channel:border:anchor:previewOn:)`**——扩 `setOverlay` 的参数会改它已经在用的 JSON 形态；多画面布局走现有 `setOutputSettings`。reducer 规则：通道不在 1–4 拒绝，三项整体替换（相同值 reducer 原样返回，回执 applied = false）。渲染器的两个单一读取点改成正式字段优先、过渡做法（`effects["border"]` / `extra["layout"]`）保留一个版本作后备，两条路径逐像素相同（有用例）；`MetalRendererOptions.overlaysInPreview` 保留为"全部预览"总开关，与每通道 `previewOn` 取或。**旧 Show 的一次性转换由 P3 定：放在契约的 `Show.load` 里（`Show.migratingLegacyKeys()`）**，App / headless / 测试读同一份，幂等、正式字段已有值的不动、搬完清旧键。`scenarios/g4-show.json` 由 `make-show --preset g4` 重新生成（格子 rect 逐位不变）。设置面板归 W3-E2 / prompt 63。
后续：过渡键的后备读取 W3-B2（渲染器的 `OverlayDecoration` / `MultiviewLayoutTable`）与 W3-C2（`ExternalDisplaySpec`）删了，App `OutputExtras.displayNumber` 的一处归 W3-E3（prompt 68 第 6 条）。**P4（2026-09-27，分支 p4-contracts）**：`Show.migratingLegacyKeys()` 搬完把 `border` 效果格一律清掉（没有叠加通道用到的、停用的也清，用户 2026-09-27 定全清）；状态机对 addOutput / setOutputSettings / loadShow 进来的数据也先搬，API 客户端直接带 `extra["layout"]` 的不再静默变成默认布局（W3-B2 报告 §4 第 3 / 4 条）。见 CONTRACTS.md §2.8、reports/p4-contracts.md。

## A. 改什么（类型）

### A1 `OverlayState` 加三个字段（都带默认值，老 Show 缺字段按默认解）

```swift
/// 画中画边框；nil = 不画。
public var border: OverlayBorder? = nil
/// 位置尺寸的锚点：rect 改尺寸时哪个点不动，缩放动画绕它缩（渲染器现在一律绕 rect 中心）。
public var anchor: OverlayAnchor = .center        // enum: topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
/// 在 PVW 里预览这一路叠加（不上 PGM）。on = true 时 PVW 也画（渲染器现在用 MetalRendererOptions.overlaysInPreview 一刀切）。
public var previewOn: Bool = false

public struct OverlayBorder: Hashable, Codable, Sendable {
    /// 边框宽，占节目高的比例（1080p 下 0.006 ≈ 6 px）。
    public var width: Double = 0.006
    /// 颜色。
    public var color: RGB8 = RGB8(red: 255, green: 255, blue: 255)
}
```

### A2 `OverlayAnimation` 加滑入方向

```swift
/// slide 从哪条边进出；nil = 离 rect 最近的边（整幅 rect 一律从底边，下三分之一自然向上滑入）。
public var slideFrom: OverlayEdge? = nil          // enum: left, right, top, bottom
```

### A3 多画面布局进 `OutputSettings`

```swift
/// 多画面布局（kind = multiview 的输出用；nil = 默认布局）。
public var multiview: MultiviewLayoutSettings? = nil

public struct MultiviewLayoutSettings: Hashable, Codable, Sendable {
    /// 预设名："pgmPvw+grid"（默认，= W1-C 的布局：下半按路数 4×2 / 6×3 / 8×4）、"pgmPvw+4x2"、"pgmPvw+2x2"、"3x3"、"4x4"；custom 非空时忽略。
    public var preset: String = "pgmPvw+grid"
    /// 自定义格子：source = program / preview / input(n)，rect 归一化。
    public var custom: [MultiviewCell] = []
    /// PGM / PVW 格画安全框（EBU R95：动作安全 3.5%，字幕安全 5%）。
    public var safeArea: Bool = false
    /// 输入格右侧画电平表占位条。
    public var meters: Bool = false
}
public struct MultiviewCell: Hashable, Codable, Sendable {
    public var source: OutputSource      // 复用现有 enum：program / preview / input(number:)；multiview 无效
    public var rect: NormalizedRect
}
```

### A4 `Command`

不加。边框 / 锚点 / previewOn 走现有 `setOverlay(channel:rect:animation:)` 的扩展参数不合适（会改 JSON 形态），建议加一条 `setOverlayDecoration(channel:border:anchor:previewOn:)`；多画面布局走现有 `setOutputSettings`。这一条由契约会话定。

## 为什么

- W3-B prompt 交付 1："位置 / 尺寸 / 锚点、进出动画（切入、淡入、滑入、缩放）、画中画（任一输入，带边框）、每通道独立开关、PVW 里可预览"。`OverlayState` 只有 rect / on / animProgress / animation，**锚点、边框、PVW 预览标志、滑入方向**都没有地方放。
- 交付 4："多画面：可配置布局（2×2 缩略 + PGM / PVW 大格、3×3、自定义 JSON）"。`OutputState`（kind = multiview）只有 `extra: [String: JSONValue]` 占位。

## 过渡做法（W3-B 已实现，不改契约）

| 需要 | 现在放哪 | 渲染器怎么读 |
|---|---|---|
| 画中画边框 | 该输入的 `InputSettings.effects` 里一格 `EffectSlot(id: "border", params: ["width": 0.006, "color": [255, 255, 255]])`（契约说效果格的定义由合成会话给） | 输入被当叠加画时，rect 外扩 width（占节目高比例）画纯色框；PGM / PVW 整幅时不画 |
| 锚点 | 无 | 缩放动画绕 rect 中心 |
| PVW 预览 | `MetalRendererOptions.overlaysInPreview`（`OfflineRenderer.options` 同名） | true 时 PVW 画所有 `isVisible` 的叠加（与 PGM 同一套）；默认 false，`v8-preview-pvw.png` 不变 |
| 滑入方向 | 无 | 离 rect 最近的边；整幅 rect 从底边 |
| 多画面布局 | `OutputState(kind: .multiview).settings.extra["layout"]`：字符串预设名（pgmPvw+grid / pgmPvw+4x2 / pgmPvw+2x2 / 3x3 / 4x4），或对象 `{"preset": "3x3", "safeArea": true, "meters": true}`，或对象 `{"cells": [{"source": "program" \| "preview" \| 3, "rect": {x, y, width, height}}], "safeArea": true, "meters": true}` | 快照 sequence 变了才解析一次，解析进预分配的定长表（渲染线程零分配）；认不出 / 没有合法格子退回默认布局。App 用 `MultiviewLayout.placements(layout:inputs:width:height:)` 拿任意布局的格子几何 |

批了之后：渲染器优先读正式字段，`extra["layout"]` / `effects["border"]` 保留一个版本作后备。

## 影响谁

SwitcherContracts（加字段 + Codable 往返 / 键名快照测试）、SwitcherEngine（`setOverlayDecoration` 的 reduce，若加命令）、SwitcherRender（改读字段，W3-B 留了单一读取点：`OverlayDecoration.resolve` 和 `MultiviewLayoutTable.parse`）、App W3-E（设置面板）、docs/api.md。Show 的 schemaVersion 不用升：全部带默认值。

## 怎么迁移

老 Show 缺字段按默认解；`extra["layout"]` 和 `effects["border"]` 由 App 打开旧文件时转成正式字段（一次性），转换代码放契约会话或 W3-E。
