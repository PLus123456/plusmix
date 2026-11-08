# W4-C5 写手册时查出的三处小文案缺口（英文界面的"起不来"两种译法、文件输入的提示只有中文、last_error 中英混着）

归属会话 / 分支：各条单列（App 会话 W5 系 / 输入会话 W2-A 系 / 推流会话 W2-D 系）
发现于：W4-C5（prompt 135，分支 `w4-docs-5`）写中英手册、对 en.lproj 原文引用时
严重级：都是 S3（文案，不伤节目）

手册都照现状写了（引原文、英文页注明哪些是中文），修了告诉文档会话把注明删掉。

## 1. 英文界面里"起不来"两种译法（App，W5 系）

中文都是"起不来"；英文 `streamMenu.tip.failed` = "Can't start: %@"（底栏推流 ▴ 每一项的悬停），而 `outputSettings.stream.statusFailed` = "Couldn't start: %@"（推流页那一段）、
`output.state.startFailed` = "Couldn't start"（底栏 / 状态窗 / 工具条的状态字）。同一个状态两种说法，英文手册 outputs.md 只好分别引。
建议 `streamMenu.tip.failed` 改成 "Couldn't start: %@"（App/Resources/en.lproj/Localizable.strings 一行）；`recordMenu.tip.failed` 同查。

## 2. 文件输入自己报的提示只有中文（SwitcherInputs，W2-A 系）

130 起播放中文件输入的提示上界面（格子缩略图底边、输入设置窗"这一路报告：…"），但这几句是包里写死的中文：
`FileDecoder.swift:124–126`（"视频方向矩阵 (…) 不是 90° 的整数倍，按编码方向原样出" / "建不出转正用的 VTPixelRotationSession…"）、`FileInput.swift`（"转正失败 n 帧…"、速率 / 定位越界那两句）。
英文界面上照样是中文（en/inputs.md 已注明 "these notes are in Chinese"）。建议包里只出类型化的原因（枚举 + 数值），文字归 App 按界面语言拼（W3-C3 / 设计方案里"给人看的文字归组装方"的口径）。

## 3. `stats.encoder[].last_error` 里两种语言混着（App + 推流，W5 / W2-D）

起不来那一路的 `last_error` 是 App 按界面语言取的（英文界面下 `No URL`、`Unsupported address: foo:// (…)`，OutputRuntime.swift:779 / :404–411），
而推流模块自己写的"连接失败：… / 断线：… / 鉴权失败（…）"永远是中文（StreamOutput / TransportErrorText / HaishinKitTransport）。API 客户端读同一个字段会碰到两种语言。
docs/api/README.md §6 已经写明。要统一的话得先定口径（last_error 是给人看的句子还是机器可读的原因码），属于 W2-D + App 一起的事，不急。
