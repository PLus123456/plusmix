# 录制"容器 .mp4"选了没用；来源设成 PVW / 多画面时悄悄录成 PGM

归属会话 / 分支：录制会话（W1-E / W3-C 系，`Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/`）+ App 会话（录制页界面）；手册归文档会话
发现于：界面对照调研 UIA，提交 c836cce；R6-M09、R6-G10，核对 VF3 属实
现象：
1. 输出设置 › 录制的"容器 .mov / .mp4"存进 RecordSettings.container，但运行时一律写 .mov；真正出 .mp4 的只有另一个开关"停止后转封装成 MP4"。docs/user/输出.md:22 写 .mp4 可选。
2. 录制输出的来源若是 PVW / 多画面（节目文件或 API 能写进去），运行时照样录 PGM 帧，不报错。
复现步骤：录制页选容器 .mp4、关掉"停止后转封装"，录 10 秒，得到的是 .mov；用 API 把录制输出 source 设成 preview，录出来的是 PGM。
严重级：S2（界面说谎；绕过办法是用"停止后转封装"）
猜测原因：`RecordFileNaming.swift:7`、`:28`（扩展名一期永远 .mov，reports/w1-outputs.md:121 契约疑问 4 当时就挂着）；`Recorder.swift:389`；`App/Sources/Engine/OutputRuntime.swift:296-307`、`:354-359` 与 `VTCompressionBackend.swift:173`（只编 frame.program）。
建议改法：界面把"容器"与"停止后转 MP4"合成一个"文件格式"单选（.mov 边录边存 / .mov 停止后转 .mp4），手册同步；container 字段的收口走小提案（04-待拍板 Q12）；在做 Aux 路由（后续方案 §3.6）之前，reducer 或界面拒收"PVW / 多画面作录制来源"。
