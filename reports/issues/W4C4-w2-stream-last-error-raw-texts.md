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

## 处理结果（W2-D5，prompt 132 第 5 条，分支 `w2-stream-5`）

底层库的错误改成一句中文概括（`Packages/SwitcherOutputs/Sources/Streaming/TransportErrorText.swift`），原文（打过码）只进系统日志
（subsystem `switcher.streaming`、category `Transport`，一条 notice：`[rtmp connect] <概括>；原文：<原文>`）。服务器回了状态的照留状态码与描述。
用例 `StreamingTests/TransportErrorTextTests`。现在 last_error 的几种（"连接失败：" / "断线：发送失败：" 是 StreamOutput 加的，没变）：

| 情形 | 原来 | 现在 |
|---|---|---|
| 端口没人听 | `连接失败：socketErrorOccurred(Optional(POSIXErrorCode(rawValue: 61): Connection refused))` | `连接失败：连接被拒（这个地址和端口上没有服务器在听）` |
| 域名解析不了 | `连接失败：socketErrorOccurred(Optional(-65554: NoSuchRecord))` | `连接失败：找不到主机（域名解析失败）` |
| 其它网络层 | 原样 | `连接超时（服务器没响应）` / `网络不通` / `连接被服务器重置` / `连接断开了` / `TLS 握手失败` / `网络错误（POSIX <号>）` / `网络错误` |
| SRT 没人听 / 被拒 | `连接失败：failedToConnect(SRTHaishinKit.SRTRejectReason.timeout)` | `连接失败：SRT 连接超时（服务器没回）`；`SRT 被拒（passphrase 不对）` / `SRT 被拒（passphrase 一边有一边没有）` / `SRT 被服务器拒绝` / `SRT 连接被关闭` / `SRT 连接失败（拒绝原因 <号>）` |
| connect 被拒（不是鉴权） | `连接失败：<状态码> <描述>` | `连接失败：服务器拒绝连接：<状态码> <描述>` |
| publish 被拒（不是鉴权） | `连接失败：publish: <状态码> <描述>`；152 行那条只有状态码 | `连接失败：发布被拒：<状态码> <描述>`（152 行也走同一个函数、带描述；不过 HaishinKit 2.2.5 的 publish 只在回 Publish.Start 时才返回、其余都抛 requestFailed，那一行实际走不到） |
| publish 超时 | `连接失败：publish: requestTimedOut` | `连接失败：发布：服务器没回（请求超时）` |
| publish 回复来晚了 | `连接失败：publish: 服务器 3000 ms 之后才回 NetStream.Publish.Start` | `连接失败：发布：服务器 3000 ms 之后才回 NetStream.Publish.Start，这条连接作废、重连` |
| 回复里没有状态 | `连接失败：connect 无状态` / `publish 无状态` | `连接失败：服务器回的 connect 里没有状态` / `连接失败：发布：服务器回的 publish 里没有状态` |
| 带账号、Adobe 前两轮退回了、服务器还在要 adobe | `连接失败：鉴权失败（服务器要用户名和密码，地址里没写）：…`（地址里明明写了） | `连接失败：服务器还要 Adobe 鉴权（这次前两轮没走完，稍后重试）：<状态码> <描述>` |
| 发送失败 | `断线：发送失败：retime` / HaishinKit 枚举原样 | `断线：发送失败：视频样本改时间戳失败` / 概括 |
| 鉴权失败（W2-D4） | `鉴权失败（…）：<状态码> <描述>` | 不变 |

**要文档会话（W4-C5）跟**：docs/api/README.md §6"推流 last_error 的另外几种"、docs/user/输出.md 与 docs/user/en/outputs.md"最后错误"那条现在写着
"开始推的阶段多数前面带 `publish: `""个别是英文标识，例如 `连接失败：publish: requestTimedOut`"——改成上表（`publish: ` 没有了，换成"发布被拒：" / "发布："）。
