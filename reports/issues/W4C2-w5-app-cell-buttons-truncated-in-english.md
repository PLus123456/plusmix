# 英文界面下输入格子的"Transition"按钮被截成"Transiti…"

归属会话 / 分支：App 界面会话（W5-H 系，`App/Sources/UI/InputCellView.swift`）；下一个动输入条的会话顺手
发现于：W4-C2（prompt 103，分支 `w4-docs-2`，App 编自 2ad92bf 的树），给英文手册截主窗口时
现象：英文界面、缩略图"中"档（格子宽 200）下，格子第一行 `× | Transition | Cut | Loop` 里"Transition"显示成"Transiti…"（截图 docs/user/img/main-window-en.jpg 下半部）；中文"转场"不截。"小"档（160）会更挤。
复现步骤：`PlusMix.app/Contents/MacOS/PlusMix --show Samples/event/event.switcher.json -AppleLanguages "(en)"`，看输入条的格子。
严重级：S3（目视）
建议：按钮行按标题实际宽度分配（Transition 比 Cut / Loop 宽），或英文用短一点的字（例如"Take"）；改了英文文案的话手册 en/inputs.md 的格子表要跟着改。
