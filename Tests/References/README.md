# Tests/References/ —— 合成引擎参考图

W1-C 用 `scripts/gen-references.sh` 通过离线渲染 API 生成，V8 测试按 PSNR ≥ 40 dB 或 SSIM ≥ 0.98 比对。
首次生成后人工看一眼并写进报告；之后改了参考图必须在报告 / PR 里说明原因。W3-B 加新转场时在这里加图。

## 怎么生成

```bash
scripts/gen-references.sh
```

它先和现有参考图比一遍（打印每张的 PSNR / SSIM，方便判断是预期变化还是回归），再设 `SWITCHER_GEN_REFERENCES=1`
跑 `SwitcherRenderTests.V8ReferenceTests/testV8_generateOrCompareAllReferences`，把离线渲染结果写成这里的 PNG。
测试代码：`Packages/SwitcherCore/Tests/SwitcherRenderTests/V8ReferenceTests.swift`；
输入图由 `Support/TestImages.swift` 用代码确定性生成，不依赖外部素材；状态在 `ReferenceStates`。
平时跑 `swift test --package-path Packages/SwitcherCore --filter V8ReferenceTests` 时，实际输出会另存到
`.build/render-test-output/`，方便和这里的图人工对照。

## 固定输入（1920×1080，全部 BGRA）

| 输入 | 内容 |
|---|---|
| 1 | 合成测试图案（契约 `TestPattern`）：水平渐变底、帧号 1234 的两行黑白块、左上红色输入 ID 块（palette[0]）、右上黑色闪光块 |
| 2 | 75% 色条（白 黄 青 绿 品 红 蓝）+ 下 1/4 是 0–255 步 8 的 32 级灰阶 |
| 3 | 带 alpha 的"下三分之一"：上 2/3 透明，下 1/3 蓝→橙渐变条（左右各留 120 px），(200,200)–(620,420) 一块 50% 白 |
| 4 | 8×8 棋盘，四个象限红 / 绿 / 蓝 / 黄（画中画缩放用） |

## 图集（第一次生成：2026-09-14，M5 Max，macOS 26.6.2，提交见 reports/w1-compositor.md）

| 文件 | 状态 | 该长什么样 |
|---|---|---|
| `v8-fixed-pgm.png` | PGM = 1，PVW = 2，Overlay 1 = 输入 3（整幅），Overlay 3 = 输入 4（右下 1/4），FTB 关 | 渐变图案打底；左下有蓝→橙条和 50% 白方块（白方块处底色变亮一半）；右下 1/4 是缩小的棋盘，且盖住渐变条的右端（3 在 1 上面） |
| `v8-fade50-pgm.png` | 同上 + Fade 进度 0.5（1 → 2） | 色条以 50% 透明度盖在渐变图案上，色条变淡；两层叠加仍在最上面 |
| `v8-ftb100-pgm.png` | 同上 + FTB level 1 | 全黑 |
| `v8-preview-pvw.png` | 同固定状态，取 PVW | 输入 2 原样（色条 + 灰阶），没有叠加 |
| `v8-fixed-multiview.png` | 同固定状态，取多画面 | 上半：PVW（绿框，色条）左、PGM（红框，与 v8-fixed-pgm 相同内容）右；下半 4×2 格：输入 1（红框，在 PGM）、2（绿框，在 PVW）、3（红框，叠加可见）、4（红框，叠加可见），每格左下角白字标签"编号  名字"（含中文），透明区域显示为黑 |

多画面里的文字用 CoreText（Helvetica-Bold 30 px）预渲染，系统字体渲染在不同 macOS 版本上可能差一两个像素；
文字只占画面很小一部分，PSNR 阈值留有余量。要是某次升级后只有 multiview 一张掉到 40 dB 以下，先看是不是字体渲染变了。
