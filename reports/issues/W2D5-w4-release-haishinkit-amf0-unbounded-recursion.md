# HaishinKit 2.2.5 自己的 AMF0 解析递归无上限：任何 RTMP 服务器回一条深嵌套的命令就能把推流进程打崩

归属会话 / 分支：W4-B 发布工程（管 HaishinKit 的版本 / 补丁；prompt 132 写明"HaishinKit 升级（W4-B）"不归 W2-D5）
发现于：W2-D5（prompt 132，分支 `w2-stream-5`）修 NS04 时的探针，main bf149e2 / g11 树
严重级：建议与 NS04 同级 S2（推到恶意 / 被劫持的服务端；可改口）

## 现象

NS04（Codex 10-24 审计 [4]）说的是我们自己的 Adobe 鉴权最小客户端：已在 W2-D5 修了（嵌套 32 层 / 元素 1 万上限）。但 HaishinKit 2.2.5 的
`AMF0Serializer.deserialize()`（RTMPHaishinKit/Sources/AMF/AMF0Serializer.swift:127–330）同样递归、无深度上限：严格数组 / 对象 / ECMA 数组都会递归进去。
`RTMPCommandMessage.init`（RTMPMessage.swift:189–205）解每一条命令消息：第三个值按 AMFObject 读（不是对象就整条丢掉，但对象里面的值照样递归），
第四个值起走通用的 `deserialize() -> (any Sendable)?`。

W2-D5 探针（debug 构建，HostileRTMPServer 回 `_result`(txid, null, <N 层单元素严格数组>)，直接 `RTMPConnection(timeout: 5).connect("rtmp://127.0.0.1:…/s1")`）：

| N | 结果 |
|---|---|
| 100 | connect 返回（status 为空） |
| 1000 | 进程 SIGBUS（signal 10） |
| 10 000 / 100 000 | 同上 |

release 构建帧小一些、要的层数更多，但一条 RTMP 消息最长 16 MB（约 330 万层），一定够。

## 影响

- **不带账号的 RTMP 地址**（绝大多数用法）直接走 HaishinKit：服务器在 connect 的 `_result`、createStream / publish 的回复、推流期间任何一条 `onStatus` 里塞深嵌套，推流进程就没了。
- 带账号（user:pass@）的：W2-D5 已经让"我们的解析器报嵌套过深 / 元素过多"时**不再退回**交给 HaishinKit 连（否则同一条回复会在 HaishinKit 里再崩一次，探针确认），
  connect 阶段护住了；但 Adobe 鉴权通过之后，连接本身还是 HaishinKit 的，之后的消息照样能打崩。
- AMF3（消息类型 17 的命令）的 `AMF3Serializer` 没看，估计同样。

## 建议改法

给 HaishinKit 打补丁（或换到修了的版本）：`AMF0Serializer` / `AMF3Serializer` 的递归带深度（建议同我们的 32）+ 元素预算，超了抛 `AMFSerializerError.deserialize`
（`RTMPCommandMessage.init` 已经把它变成"整条消息丢掉"）。补丁怎么管（vendored fork / patch 文件 / 上游 PR）是 W4-B 的事；LICENSE 是 BSD-3，可以改。

验收：`StreamingTests/AMF0LimitTests.testNS04_haishinKitOwnParser_deepReply` 现在是 `XCTSkip("BLOCKED-SDK…")`，修了之后去掉那个 guard 就能跑
（没修时去掉会把整个测试进程打崩，单独跑：`SWITCHER_PROBE_HK_AMF=1 swift test --filter AMF0LimitTests/testNS04_haishinKitOwnParser_deepReply`）。
恶意服务器：`StreamingTests/HostileRTMPServer.swift`（照 Codex C06-server.py 改写，可以回任意命令载荷）。
