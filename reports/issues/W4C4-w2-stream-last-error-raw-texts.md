# 推流 last_error 仍有底层库的原样文字（G10 胶水 ③ 只去掉了外层枚举名）

归属会话 / 分支：下一个动 `Packages/SwitcherOutputs/Sources/Streaming/` 的推流会话（W2-D 续做）
发现于：W4-C4（prompt 124，分支 `w4-docs-4`）写 docs/api/README.md §6 与手册"最后错误"一条、核对 agent 逐句对代码时
严重级：S3（文案带内部标识 / 英文，不伤节目）

## 现象

G10 胶水 ③ 给 `StreamTransportError` 和发布循环的 `ExitReason` 加了 description，`连接失败：connectFailed("…")` 这种外层写法没有了；
但 `<原因>` 这一段仍有几种程序写法会进 `Stats.encoder[].last_error`、状态窗"最后错误"与系统日志：

| 位置 | 写进去的 | 例子 |
|---|---|---|
| `HaishinKitTransport.swift:165` | 固定英文标识 | `连接失败：publish: requestTimedOut` |
| `HaishinKitTransport.swift:135` / `:152` | 状态码，或 `connect 无状态` / `publish 无状态`；**152 行 publish 回了非成功码时只写状态码、不带 `publish: ` 前缀也不带描述**（与 :221 文档注释"publish 阶段带 publish: "不一致） | `连接失败：<publish 回的状态码>` |
| `HaishinKitTransport.swift:240`、`:273` | 认不出的错误 `"\(error)"`（socket、HaishinKit 自己的枚举） | 视错误而定 |
| `StreamOutput.swift:631` | 发送失败 `.sendFailed("\(error)")` | `断线：发送失败：<HaishinKit 的枚举原样>` |
| `StreamOutput.swift:424` | `建传输层失败：\(error)` | 同上 |

## 建议

- 认不出的错误给一句中文概括 + 原文放日志（last_error 只放概括），或至少把 HaishinKit 常见的几种（超时、连接被拒、DNS）翻成人话；
- 152 行与 135 行一样按 `Self.error(code:description:phase:)` 走，带上描述和 `publish: ` 前缀；
- 改完告诉文档会话：docs/api/README.md §6"推流 last_error 的另外几种"、手册输出页 / outputs"最后错误"那条现在写着"个别是英文标识，例如 `publish: requestTimedOut`"。
