# 推流"最后错误"连不上 / 断线那一半仍带 Swift 枚举原样（W4C3 第 8 条剩下的一半）

归属会话 / 分支：下一个动 `Packages/SwitcherOutputs/Sources/Streaming/` 的推流会话（W2-D 续做）；不在 119（只准动 App/）、也不在 118（w3-outputs-5 只准动 Streaming/PCMBlockRing.swift）
发现于：W4-C3（prompt 109）写手册时；W5-P（prompt 119）的交付第 8 条列了它，但改法在包里，119 没做
严重级：S3（文案带内部名字，不伤节目）

现象：服务器拒绝鉴权那一种 111 之后已经是干净的一句；连不上 / 断线照旧是 `连接失败：connectFailed("…")` / `断线：sendFailed("…")`——
`StreamTransportError` 没有自定义 description，`StreamOutput` 里 `"\(error)"` 把 case 名和引号一起带进 `Stats.encoder[].last_error`、状态窗"最后错误"与系统日志。

代码：`Packages/SwitcherOutputs/Sources/Streaming/StreamOutput.swift`（拼 `连接失败：` / `断线：` 的那几行）、`StreamTransport.swift`（`StreamTransportError`）。

建议：`StreamTransportError` 加 `CustomStringConvertible`（connectFailed / sendFailed 只取那段字符串），日志与 last_error 一起干净。
App 不能自己在界面上洗这句：状态窗、API、stats.jsonl 读的是同一个 `last_error`（铁律 4），界面另写一份就两处不一致。

手册：输出 / outputs 状态窗"最后错误"一条拿连不上当带枚举原样的例子，修了要改（reports/issues/W5P-w4-docs-manual-followups.md 末段）。
