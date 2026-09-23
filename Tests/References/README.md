# Tests/References/ —— 合成引擎参考图

W1-C 用 `scripts/gen-references.sh` 通过离线渲染 API 生成，V8 测试按 PSNR ≥ 40 dB 或 SSIM ≥ 0.98 比对。
首次生成后人工看一眼并写进报告；之后改了参考图必须在报告 / PR 里说明原因。W3-B 扩展了图集（第二节）。

## 怎么生成

```bash
scripts/gen-references.sh
```

它先和现有参考图比一遍（打印每张的 PSNR / SSIM，方便判断是预期变化还是回归），再设 `SWITCHER_GEN_REFERENCES=1`
跑 `SwitcherRenderTests.V8ReferenceTests/testV8_generateOrCompareAllReferences`，把离线渲染结果写成这里的 PNG。
测试代码：`Packages/SwitcherCore/Tests/SwitcherRenderTests/V8ReferenceTests.swift`；
输入图由 `Support/TestImages.swift`（1–4）和 `Support/TestImagesPhase2.swift`（5–8）用代码确定性生成，不依赖外部素材；状态在 `ReferenceStates`。
平时跑 `swift test --package-path Packages/SwitcherCore --filter V8ReferenceTests` 时，实际输出会另存到
`.build/render-test-output/`，方便和这里的图人工对照。

## 固定输入（1920×1080，全部 BGRA）

| 输入 | 内容 |
|---|---|
| 1 | 合成测试图案（契约 `TestPattern`）：水平渐变底、帧号 1234 的两行黑白块、左上红色输入 ID 块（palette[0]）、右上黑色闪光块 |
| 2 | 75% 色条（白 黄 青 绿 品 红 蓝）+ 下 1/4 是 0–255 步 8 的 32 级灰阶 |
| 3 | 带 alpha 的"下三分之一"：上 2/3 透明，下 1/3 蓝→橙渐变条（左右各留 120 px），(200,200)–(620,420) 一块 50% 白 |
| 4 | 8×8 棋盘，四个象限红 / 绿 / 蓝 / 黄（画中画缩放用） |
| 5（W3-B） | 绿幕合成图：肤色 / 蓝 / 白 / 深灰四种前景（大圆盘、圆环、三条斜细条、矩形，边缘 1 px 抗锯齿）按已知 alpha 叠在绿幕 (0,200,60) 上；绿幕带 ±7% / ±5% 的光照渐变和 ±6 的噪声 |
| 6（W3-B） | Stinger 图：左下→右上的斜带，带内不透明（橙→品红渐变）、两侧 60 px 软边，左上 / 右下两角永远透明 |
| 7 / 8（W3-B） | 纯色 + 中心对比块：7 青底 / 深红块，8 黄底 / 深蓝块（叠加顺序用） |

## 一、W1-C 的图集（2026-09-14 首次生成，状态不变）

| 文件 | 状态 | 该长什么样 |
|---|---|---|
| `v8-fixed-pgm.png` | PGM = 1，PVW = 2，Overlay 1 = 输入 3（整幅），Overlay 3 = 输入 4（右下 1/4），FTB 关 | 渐变图案打底；左下有蓝→橙条和 50% 白方块（白方块处底色变亮一半）；右下 1/4 是缩小的棋盘，且盖住渐变条的右端（3 在 1 上面） |
| `v8-fade50-pgm.png` | 同上 + Fade 进度 0.5（1 → 2） | 色条以 50% 透明度盖在渐变图案上，色条变淡；两层叠加仍在最上面 |
| `v8-ftb100-pgm.png` | 同上 + FTB level 1 | 全黑 |
| `v8-preview-pvw.png` | 同固定状态，取 PVW | 输入 2 原样（色条 + 灰阶），没有叠加 |
| `v8-fixed-multiview.png` | 同固定状态，取多画面 | 上半：PVW（绿框，色条）左、PGM（红框，与 v8-fixed-pgm 相同内容）右，**W3-B 起两格左下角各有 "PVW" / "PGM" 标签**；下半 4×2 格：输入 1（红框，在 PGM）、2（绿框，在 PVW）、3（红框，叠加可见）、4（红框，叠加可见），每格左下角白字标签"编号  名字"（含中文），透明区域显示为黑 |

W3-B 对第一节的改动：只有 `v8-fixed-multiview.png` 重生成（加了 PGM / PVW 标签，其余像素不变；重生成前对旧图 PSNR 31.6 dB / SSIM 0.994）。另外四张逐像素不变（PSNR ∞）。

## 二、W3-B 的图集（2026-09-19 首次生成，M5 Max，macOS 26.6.2，提交见 reports/w3-compositor2.md）

除非注明，状态都从 `fixed8()`（= 固定状态 + 8 路输入）出发。

| 文件 | 状态 | 该长什么样 |
|---|---|---|
| `v8-overlay-order-pgm.png` | Overlay 1 = 输入 7 画中画 (0.3, 0.3, 0.4, 0.4)，Overlay 3 = 输入 8 画中画 (0.5, 0.5, 0.4, 0.4) | 两个画中画重叠，重叠处是 8（黄底）：通道号大的在上面 |
| `v8-pip-border-pgm.png` | Overlay 1 关；Overlay 3 = 输入 4 在左上 (0.05, 0.05, 0.3, 0.3)，白边 0.006（W3-B 写在输入 4 效果链的 `border` 格里，W3-B2 起状态改用正式字段 `OverlayState.border`，图没重生成） | 左上的棋盘画中画外面一圈约 6 px 的白边；画面其余是输入 1 |
| `v8-keyer-pgm.png` | 只开 Overlay 2 = 输入 5（绿幕合成图）整幅；输入 5 抠像开（键色 (0,200,60)，容差 0.15，柔化 0.1，溢色 0.5） | 绿幕全部透掉露出输入 1 的渐变图案；肤色圆盘、蓝圆环、白斜条、深灰矩形留下，边缘干净、不带绿边 |
| `v8-wipe50-l2r-pgm.png` … `-r2l` / `-t2b` / `-b2t` / `-diag` | Wipe 进度 0.5（1 → 2），硬边 | 新画面（色条 + 灰阶）占左半 / 右半 / 上半 / 下半 / 左上三角，其余是输入 1；边是一条直线；两层叠加仍在最上面 |
| `v8-wipe50-l2r-soft-pgm.png` | 同左→右 + 软边 0.2 | 中线两侧各约 10% 宽度的渐变过渡，最左是纯色条、最右是纯图案 |
| `v8-zoom50-pgm.png` | Zoom 进度 0.5 | 色条画面缩到一半大小、居中，四周是输入 1 |
| `v8-stinger-mid-pgm.png` | Stinger：输入 6，30 拍，第 15 拍换底，进度 0.5 | 底已经是输入 2（色条）；斜带（橙→品红）从左下压到右上，带外两角露出色条 |
| `v8-overlay-slide50-pgm.png` | Overlay 1 = 输入 3，slide，animProgress 0.5 | 下三分之一整幅画布从底边上来一半：只看得到输入 3 的上半（透明 + 50% 白方块落在下半），橙蓝条还在画外 |
| `v8-overlay-zoom50-pgm.png` | Overlay 3 = 输入 4 右下 1/4，zoom，animProgress 0.5 | 画中画绕自己中心缩到一半（占右下 1/4 的中央 1/4） |
| `v8-preview-overlays-pvw.png` | `overlaysInPreview = true`，取 PVW | 输入 2 上叠着与 PGM 同一套叠加（下三分之一 + 右下棋盘） |
| `v8-multiview-pgmpvw2x2.png` | 多画面输出的布局 = 预设 "pgmPvw+2x2"（W3-B 写在过渡键 extra["layout"]，W3-B2 起状态改用正式字段 `settings.multiview`，图没重生成；下两张同） | 上半同默认；下半 2×2 四个大格：输入 1–4 |
| `v8-multiview-3x3.png` | "3x3" | 九宫格：PGM（红框，"PGM"）、PVW（绿框，"PVW"）、输入 1–7；输入 8 不在 |
| `v8-multiview-custom.png` | 自定义：PGM 占左上 70%（安全框开：3.5% / 5% 两圈细线），右列 PVW + 输入 3 / 4，底行输入 1 / 2 / 5；电平表占位开 | 大 PGM 格里两圈白线；每个输入格右侧一条带四道刻度的暗条；输入 5 是没抠像的绿幕图 |

多画面里的文字用 CoreText（Helvetica-Bold 30 px）预渲染，系统字体渲染在不同 macOS 版本上可能差一两个像素；
文字只占画面很小一部分，PSNR 阈值留有余量。要是某次升级后只有 multiview 几张掉到 40 dB 以下，先看是不是字体渲染变了。

## 三、W3-B2 的图集（2026-09-23 首次生成，M5 Max，macOS 26.6.2，提交见 reports/w3-compositor-3.md）

W3-B2 删了渲染器对提案 010 过渡键（`extra["layout"]`、效果格 `border`）的读取，上面第一、二节所有状态都已改走正式字段；
改写法之前和之后各跑一遍，22 张图全部 PSNR ∞，一张没重生成。本节两张是新加的（结构性检查在 `MultiviewMetersTests`）：

| 文件 | 状态 | 该长什么样 |
|---|---|---|
| `v8-multiview-audio-only-3x3.png` | 3×3 预设（meters 关），`fixed8()` 的输入 6 换成纯音频设备 `.audio(deviceUID: "BuiltInMicrophoneDevice")`、名字"话筒 Mic"（输入表里照样给它 stinger 图的帧） | 第三行中间一格是深灰底（38），右侧一条带四道刻度的暗条（没有读数 = 占位），左下"6  话筒 Mic"；不画 stinger 图。其余输入格没有电平表（meters 关） |
| `v8-multiview-meters.png` | 同 `v8-multiview-custom` 的状态 + 两次 `setMeters`：t0 时输入 4 = −21 / −27，t0 + 0.5 s 时输入 1 = −3 / −5、3 = −14 / −16、4 = −33 / −40，Master = −9 / −10 | 输入 1 两根条顶进红区；输入 3 顶在黄区；输入 4 绿条，上方 0.65 / 0.55 处各一道 2 px 绿线（峰值保持，1 s 内不回落）；输入 2、5 没有读数 = 占位暗条；PGM 格右侧一条 40 px 宽的表（Master，顶在黄区）；PVW 格（输入 2，没有读数）不画表。没给表时与 `v8-multiview-custom` 逐像素相同 |
| `v8-multiview-meters-rms.png` | 新（G4 续做合入 2026-09-24，提案 017；`SWITCHER_GEN_REFERENCES=1` 只跑 `testV8_multiviewMetersWithRMS` 生成，人工看过） | 同一组读数再带 RMS（= 峰值 − 9 dB）。实心条只到 RMS（输入 1 到 0.8 黄区顶、输入 3 到 0.583 绿、输入 4 到 0.3），峰值变成 2 px 细线（输入 1 在 0.95 / 0.917 红，输入 4 在 0.45 绿），保持线照旧（输入 4 的 0.65 / 0.55）；PGM 格 Master 同一画法。没有 rms_db 的老数据仍画 `v8-multiview-meters.png` 那样的实心峰值条（用例 `testV8_multiviewMetersWithRMS` 两张都比）。 |

电平表的刻度与颜色（设计方案 §7 没有给颜色表，本会话定的，报告 §4 等用户拍板）：−60…0 dBFS 线性，< −18 绿、−18…−6 黄、≥ −6 红；
四道刻度在表高 1/5…4/5（−48 / −36 / −24 / −12 dBFS），与 W3-B 的占位同一位置。

