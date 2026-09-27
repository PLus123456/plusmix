# 多画面参考图在 macOS 27 上不再逐像素相同：名字标签里的中文字形（CoreText 回退字体）变了

归属会话 / 分支：合成（`Packages/SwitcherCore/Sources/SwitcherRender/Renderer/LabelRenderer.swift` 与 `Tests/References/`，W3-B2 / `w3-compositor-3` 的目录，会话已结束）→ 检查点或用户指派
发现于：P4（分支 `p4-contracts`，2026-09-27）跑整仓 `make test`
严重级：S2（渲染逻辑没变；参考图"PSNR ∞"在新系统上不成立，PSNR ≥ 40 dB 的比对照过）

## 现象

- SwitcherRenderTests 三处逐像素断言红：`MultiviewMetersTests.testV8_multiviewMetersFromStats` 第 296 / 300 行（"应与 v8-multiview-custom.png 逐像素相同"），
  `testV8_multiviewMetersWithRMS` 第 266 行（"应与 v8-multiview-meters.png 逐像素相同"）。
- 同一批的 `V8ReferenceTests.compare`（PSNR ≥ 40 dB 或 SSIM ≥ 0.98）都过，但 PSNR 不再是 ∞。实际输出（`.build/render-test-output/`）与参考图逐像素比：

  | 参考图 | 差异像素 | 最大通道差 | PSNR |
  |---|---|---|---|
  | v8-fixed-multiview | 702 | 98 | 60.16 dB |
  | v8-multiview-3x3 | 1027 | 94 | 58.95 dB |
  | v8-multiview-audio-only-3x3 | 1213 | 94 | 58.29 dB |
  | v8-multiview-custom / -meters / -meters-rms | 819 | 82 | 59.49 dB |
  | v8-multiview-pgmpvw2x2 | 700 | 99 | 59.11 dB |
  | PGM / PVW 类 18 张 | 0 | 0 | ∞ |

- 差异图（参考图压暗、差异像素标红）：**全在名字标签的中文字形上**（"摄像机""画中画""绿幕"），拉丁字母（PGM、PVW、Camera 2、Lower Third、Key）一个像素没变。
- **main `67d0f6b` 在同一台机器上复现同样四处红**（临时 detached worktree，2026-09-27 10:0x）；P4 分支与 main 渲染出的 `v8-multiview-meters(-rms).png` 逐像素相同 → 不是 P4 引入。

## 原因

本机 2026-09-25 13:59 从 macOS 26.6.2 升到 macOS 27（26A428），同日装了 Command Line Tools for Xcode 27.0（`softwareupdate --history`）。
这七张参考图是 W3-B / W3-B2 / G4 在 26.6.2 上生成或核过的（G4 §12.1 在 2026-09-24 记的是"24 + 1 张参考图全部 PSNR ∞"）。
`LabelRenderer` 用 `CTFontCreateWithName("Helvetica-Bold")`，中文走 CoreText 的系统回退字体，macOS 27 的回退字形 / 栅格化变了。

## 建议（合成会话 / 用户定；P4 没改：铁律 9 不许改参考图、放宽断言，OWNERSHIP 的 P4 行也写明渲染器与参考图只为 017 动）

1. **字体钉死**：`LabelRenderer` 用随包带的字体（OFL 许可的 CJK 字体子集，许可证进 THIRD_PARTY/）配显式的 cascade list，不走系统回退——参考图从此与系统版本无关。代价是包体积。
2. **在 macOS 27 上重生成七张多画面参考图**（`scripts/gen-references.sh`），`Tests/References/README.md` 记下"生成于哪个 macOS"；以后每次系统升级都可能再来一次，而且 26 与 27 的机器不能共用一套图。
3. 比对时掩掉名字标签区域（标签另有结构断言）——属于放宽断言，要用户批。

## 同一次运行的另一条（环境，不是 P4）

`DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`：2 秒内 display link 回调 0 次、blit 0 次（`SkipCounters` 全 0），main 上一样。
这次**盖子开着、屏幕没锁、内建屏与外接 2560×1440 都在线**，同一个类里的 `testDisplay_windowManipulationDoesNotCauseMissedRenders` 过（预览窗口有 blit）。
G4 §12.1 把它归为"显示器不可见"，但这次显示器是可见的。**同一天第二次整包跑（10:48–10:53，P4 顶 3d2ba59）这条又过了**——偶发，
可能与预览窗口开在哪块屏 / 哪个 Space、当时有没有别的窗口抢前台有关。需要合成会话坐在桌面前复查（窗口落点、`NSView.displayLink` 在 27 上的行为）；
复查前别把它当成代码回归。

## 处理（G4 续做合入会话，2026-09-27）

等用户三选一。检查点的建议：**第 2 条**——在 macOS 27 上 `scripts/gen-references.sh` 重生成七张多画面图、`Tests/References/README.md` 记"生成于 macOS 27.0 (26A428)"，
以后系统升级再来一次就好；第 1 条（随包带 CJK 字体）是产品级改动、要新开合成会话；第 3 条是放宽断言。`Tests/References/` 在 OWNERSHIP 的 G4 行内，批了检查点就做，做完 7 张重新 PSNR ∞。
`testDisplay_maxFrameRateCapsThumbnailBlits` 那条偶发另记在 G4-notes §13。

## 处理结果（G4 续做合入会话，2026-09-27）

用户选 **2**。`scripts/gen-references.sh` 在 macOS 27.0 (26A428) 上重生成（六张走 `V8ReferenceTests`，`v8-multiview-meters-rms.png` 走 `MultiviewMetersTests` 的生成路径），
`Tests/References/README.md` 第四节记了系统版本与"26.x 机器上不再逐像素相同"；SwitcherRenderTests 复跑结果在 reports/G4-notes.md §13.6。
`testDisplay_maxFrameRateCapsThumbnailBlits` 那条偶发未动（第四轮两次全量都过）。
