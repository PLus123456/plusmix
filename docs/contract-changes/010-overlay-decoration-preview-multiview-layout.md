# 010 叠加通道的边框 / 锚点 / PVW 预览标志、滑入方向，多画面布局的正式字段

提出会话 / 分支：W3-B / w3-compositor2（2026-09-19）
状态：**待批**。W3-B 用契约里现成的占位字段先把功能做出来（见"过渡做法"），批了之后由契约会话加正式字段，渲染器改读新字段、过渡做法保留一个版本兼容旧 Show。

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
