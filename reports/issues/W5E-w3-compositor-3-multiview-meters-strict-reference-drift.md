# MultiviewMetersTests 两条"逐像素相同"在本机红：2026-09-27 重生成的多画面参考图与现在的渲染差 PSNR ≈ 51 dB（main 上同样红，与 W5-E 无关）

归属会话 / 分支：多画面电平表用例（W3-B2 / `w3-compositor-3` 写的 `Packages/SwitcherCore/Tests/SwitcherRenderTests/MultiviewMetersTests.swift`）；
参考图是 G4 检查点按用户 2026-09-27 的裁定在 macOS 27 上重生成的（提交 1c13457，七张多画面图）。要不要再重生成、或者这两处改用 PSNR 判，归用户定（参考图 / 阈值只有用户能改）。
发现于：W5-E（prompt 90，分支 `w5-core-transition-guard`）2026-10-01 跑 SwitcherCore 全包。W5-E 只改了 SwitcherEngine 的 reducer，SwitcherRenderTests 只链接 SwitcherRender，碰不到；
为了确认，另起一个干净的 main（25af61f，detached worktree）只跑 `--filter SwitcherRenderTests.MultiviewMetersTests`：**同样两条红、同样三处断言**。

现象：
- `testV8_multiviewMetersFromStats`：MultiviewMetersTests.swift:296、:300"应与 v8-multiview-custom.png 逐像素相同"失败（同一用例里 PSNR 判的 `V8ReferenceTests.compare("v8-multiview-meters")` 过）。
- `testV8_multiviewMetersWithRMS`：:266"应与 v8-multiview-meters.png 逐像素相同"失败。
- 同一次（main 上）PSNR 输出：v8-multiview-meters 51.73 dB、v8-multiview-meters-rms 51.73 dB、v8-multiview-audio-only-3x3 50.83 dB（SSIM 0.9999–1.0000）；
  这几张 9-27 重生成后应是 ∞。PSNR 判的那些用例（`testV8_multiviewMatchesReference`、`testV8_multiviewLayoutsMatchReference` 等）都过，红的只有用 `bm.bgra == ref.bgra` 判的两条。
- SwitcherCore 全包：Render 97 个用例 95 过 2 红；Engine 100 / 100；Contracts 82 个 81 过 1 跳（原有）。
- 机器：Apple M5 Max，macOS 27.0（26A428），2026-10-01。

复现步骤：`swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests.MultiviewMetersTests`（任何 25af61f 之后的树）。

严重级：S3（只差名字标签的字形，产品渲染逻辑没变；但 `make test` 因此红，G6 判全量时会撞上）。

差在哪（拿 `.build/render-test-output/` 的实际输出与 `Tests/References/` 逐像素比，scratchpad 里的纯 Python PNG 比对）：
- v8-multiview-meters 与不画表的占位图 v8-multiview-custom **差得一模一样**：2214 个像素、最大通道差 118、包围盒 x 39–1487 / y 723–1068，集中在几个格子底部——电平表不是原因；
- 其余多画面图同样只差一小块：v8-multiview-3x3 2537 像素、v8-fixed-multiview 1734 像素（包围盒 y 770–793，一条窄带）、v8-multiview-pgmpvw2x2 1717 像素——都在名字标签的位置。
- 9-28 G5 在 release/0.1 上跑 SwitcherCore 时这组还是绿的（Render 代码与今天的 main 相同：9-27 重生成之后 main 上动 SwitcherRender 的只有 W1-B3 两个提交，G5 那次已经包含）；
  系统版本号也没变（9-25 升 macOS 27 时记的是 26A428，今天 `sw_vers` 还是 26A428）。

猜测原因：名字标签的中文字形又变了（`LabelRenderer` 走 CoreText 系统回退字体，见 macOS 26 → 27 那次：差异全在中文标签、PSNR 58–60）——系统版本号没变，可能是字体资源单独更新过，没查实。
建议：用户定是在当前系统上 `scripts/gen-references.sh` 重生成这几张（换一次字体资源就会再红一次），还是把这两处"逐像素相同"改成与 `V8ReferenceTests.compare` 同一套 PSNR 判法，或者随包钉一个标签字体。
