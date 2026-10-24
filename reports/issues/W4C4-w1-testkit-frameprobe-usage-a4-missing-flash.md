# frameprobe 的用法说明没跟上 A4"缺闪光算不过"，内部版测试标准 §2.3 少了拍号按 PTS 那一条

归属会话 / 分支：用法文字归下一个动 `Tools/frameprobe/` 的 TestKit 会话（W1-A 续做）；测试标准内部版归维护 docs/spec/ 的会话（检查点或用户）
发现于：W4-C4（prompt 124，分支 `w4-docs-4`）写公开版 docs/testing/测试标准.md §2.3 时
严重级：S3（说明文字，不影响判定）

## 1. `frameprobe av` 的用法只写了缺 click

`Tools/frameprobe/Sources/frameprobe/FrameprobeCLI.swift` 的 usage：`av … 多个文件比较同一事件（A4：click 以第一个文件 / PGM 配上的为锚，
闪光落在半秒的事件只列不判，判定事件里有文件在锚 ±0.5 s 内没有 click 算不过）`。G10 胶水 ⑥ 起判定事件里有文件**缺闪光**也算不过
（`missingFlashFiles` / `missingFlashEventCount`，`FrameAnalysis.swift:726`、`:751`），usage 没写；
"click 以第一个文件 / PGM 配上的为锚"也不准——锚是按传入顺序**第一个配上 click 的文件**（同文件 :718 注释与 790 行 `firstIndex`），PGM 没配上时会落到下一个文件。

建议 usage 改成"……锚 = 按顺序第一个配上 click 的文件（gate4 里通常是 PGM）……判定事件里有文件缺 click 或缺闪光算不过"。

## 2. 内部版测试标准 §2.3 没有 121 的拍号口径

公开版 docs/testing/测试标准.md §2.3 本会话补了"拍号按 PTS 算、漏帧单独报（missingFrames / missingBetween）、av / wipe / zoom / stats 没给 `--fps` 用标称帧率"一条，
并把多文件 A4（含缺闪光）写全；docs/spec/导播台测试标准.md §2.3 只有 G9 补的多文件 A4 那条（还写着"缺 click 判不过归 W1-A6"，没有缺闪光）。
两份说好"阈值相同、公开版只是去掉内部引用"，现在公开版的工具说明比内部版多，内部版要补（不在本会话目录 docs/spec/）。
