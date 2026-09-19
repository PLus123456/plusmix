# 008 KeyerSettings 四个参数的口径（只改文档注释，不改类型 / JSON）

提出会话 / 分支：W3-B / w3-compositor2（2026-09-19）
状态：**待批**（不改任何公开签名和 JSON 键；批了由契约会话把下面的口径抄进 `Input.swift` 的 `KeyerSettings` 注释和 CONTRACTS.md §2.4。渲染器已按这个口径实现，不等批。）

## 改什么

P1 把 `KeyerSettings { enabled, keyColor: RGB8, tolerance, softness, spillSuppression }` 放进 `InputSettings.keyer` 时标了"占位，W3-B 细化时走契约提案"。
W3-B 实现后发现四个字段够用，**不需要加字段、不需要改类型**，只需要把每个数的意义钉死（UI 的滑杆、API 的文档、别的渲染实现都按同一口径）：

| 字段 | 口径（渲染器 `Compositor.metal` `applyKey` 的实现就是定义） |
|---|---|
| `keyColor` | full-range 8-bit RGB 的键色。渲染器把它按 BT.709 换成色度 (Cb, Cr)（归一化到 −0.5…+0.5），只比色度不比亮度：绿幕上的阴影（同色度、低亮度）也被抠掉，这是设计方案 §5"YCbCr 空间的颜色距离"的第一版取舍 |
| `tolerance` 0–1 | 完全抠掉的色度距离半径 = `tolerance × 0.5`。像素色度到键色色度的欧氏距离 d ≤ 半径 → alpha 0 |
| `softness` 0–1 | 边缘柔化带的宽度 = `softness × 0.25`（色度距离单位）。d 在 [半径, 半径 + 带宽] 内 alpha 用 smoothstep 从 0 升到 1；softness = 0 是硬边 |
| `spillSuppression` 0–1 | 留下来的像素把色度在键色方向上的正分量减掉这个比例（c′ = c − s·max(0, c·k̂)·k̂），亮度不变，所以溢色边缘变成同亮度的灰而不是变暗 |

输出是预乘 alpha（`rgb × alpha`），进现有的 source-over 混合管线；抠像对该输入出现的每一处（PGM 底、转场新画面、叠加、PVW、多画面缩略图）都生效。

## 为什么

- 测试标准 §3 V8 的固定状态写了"抠像开"，W1-C 没做，W3-B 的 V8 扩展要"已知绿幕合成图 → 与已知 alpha 的边缘 IoU ≥ 0.95"。没有口径就没法写参考图、也没法让 W3-E 的设置面板和 API 文档说清楚滑杆是什么意思。
- 四个字段的范围 `InputSettings.clamped()` 已经钳到 0–1，与上表一致。

## 影响谁

无代码影响：SwitcherRender 已按上表实现（`Renderer/CompositorPasses.swift` 填 uniforms，`Shaders/Compositor.metal` 算）；W3-E 做抠像面板时按上表标滑杆；`docs/api.md` 的 setInputSettings 说明可以引用。

## 怎么迁移

不用迁移：类型、JSON 键、默认值（enabled false、键色 (0,255,0)、0.3 / 0.1 / 0.5）都不变。
