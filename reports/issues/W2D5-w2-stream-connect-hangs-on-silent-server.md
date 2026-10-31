# 推流：对端接受 TCP 但不说话时，StreamOutput 一直停在"连接中"，连接超时不起作用、stop 永远回不来

归属会话 / 分支：W2-D 推流（`Packages/SwitcherOutputs/Sources/Streaming/`，下一个推流续做会话；W2-D5 发现，没修——不在 prompt 132 的范围；用户 2026-10-31 定：W2-D5 不修，交 G12（134）定级、排续做会话）
发现于：W2-D5（prompt 132，分支 `w2-stream-5`）给 last_error 做探针时，main bf149e2 / g11 树
严重级：建议 S1（功能错，节目能继续；用户可改口）——不是整个 App 卡死（App 用 stopAsync，主线程不堵），但这一路推流卡住、停不掉也起不来

## 现象（本机实测，macOS 27 / HaishinKit 2.2.5）

本机起一个只 `listen`、从不 `accept` 也不回任何字节的 TCP 端口（内核替它完成 TCP 三次握手），`rtmp://127.0.0.1:<端口>/live/k`、连接超时 3 s：

| 时刻 | StreamOutput.state | connect_attempts | last_error |
|---|---|---|---|
| 2 / 4 / 6 / 8 s | `connecting(1)` | 1 | 空 |
| 之后在后台线程调 `stop()` | 20 s 没返回，state = `stopping` | | |

传输层单测：`withTimeout(seconds: 4) { try await RTMPTransport.connect() }` 25 s 没返回；`rtmps://` 连同一个端口要 15 s（Network.framework 的 TLS 超时）才回"连接超时"——4 s 的超时同样没按时生效。
端口没人听 / 域名解析不了 / SRT 没人听都正常（立刻或 3 s 报错），只有"连上了 TCP、对端不说话"这一种。

## 原因

1. HaishinKit 2.2.5 `RTMPConnection.connect`（RTMPConnection.swift:336–356）：`withCheckedThrowingContinuation` 里起一个非结构化 `Task` 去连 socket、发 C0C1，
   续体存进 `operations[connectTransactionId]` 等服务器回握手 / connect 的 `_result`；**握手和 connect 命令都没有超时**（`RTMPConnection(timeout:)` 只管 TCP 连接那一步），
   **也不理外层 Task 的取消**。对端不回话就一直挂着，直到 socket 断开或有人调 `close()`（close 会把这个续体以 `requestFailed(Connect.Failed)` 结束，探针确认）。
2. 我们的 `withTimeout`（StreamOutput.swift 末尾）用 `withThrowingTaskGroup`：超时那个子任务抛错后，组要**等所有子任务结束**才返回——body 那个子任务不理取消，
   于是 withTimeout 跟着一直挂着，`StreamOutput.run()` 的连接超时形同虚设。
3. `stop()` / `stopAsync()` 置 stopRequested、等发送 Task 结束；发送 Task 正卡在 2 里，所以 stop 也回不来。

## 影响（App）

- 这一路一直显示"连接中（第 1 次）"，不退避、不重试、last_error 空（看不出原因）；
- 点停（OutputRuntime.stopStream → stopAsync）：条目永远停在 stopping，`streams[n]` 不清，这一路再也起不来（直到换节目）；
- 换节目 / 退出（OutputRuntime.stopAll）：等满 10 s 兜底才放弃，丢下的 StreamOutput、它的 HaishinKit 连接和发送 Task 泄漏。
- 现实里的触发：地址指到了一个"接 TCP 但等对方先说话"的服务、负载均衡 / 防火墙替死后端接了连接、连接刚建好网络就断了（等到 TCP 重传超时，几分钟）。

## 建议改法（都在 Streaming/ 里）

1. `withTimeout` 超时时先关掉传输层再抛：给它加一个 `onTimeout` 回调，StreamOutput 传 `{ await transport.close() }`；HaishinKit 的 close 会结束挂着的 connect 续体，
   body 子任务随之返回，组也就返回了（仍是结构化并发，不漏 Task）。publish 阶段原来就靠取消结束状态流，不受影响。
2. stop 要及时：发送 Task 连接期间记下当前的传输层，`beginStop()` 里异步 `close()` 它（或 cancel 发送 Task，要先确认 publishLoop / 退避的取消语义）。
3. 用例：StreamingTests 加一个"只 listen 不说话"的端口（W2-D5 的探针，见下），断言 ① connect 在连接超时 + 1 s 内报"连接超时"、② StreamOutput 进退避、
   ③ connecting 期间 stop() 2 s 内返回；RTMPS 同样（不另搭 TLS：连同一个端口，TLS 握手同样挂着）。

探针（W2-D5 写的、没提交；放进 StreamingTests 就能跑）：

```swift
let silent = socket(AF_INET, SOCK_STREAM, 0)
var one: Int32 = 1
setsockopt(silent, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
var addr = AdobeAuthGateway.loopback(port: 19493)
_ = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(silent, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
listen(silent, 4)                       // 只 listen：内核完成三次握手，没人 accept、没人回字节
defer { close(silent) }
let o = try StreamScene().makeOutput(name: "probe-silent", url: "rtmp://127.0.0.1:19493/live/k", connectTimeout: 3)
try o.start()
Thread.sleep(forTimeInterval: 8)        // state 一直是 connecting(1)
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async { o.stop(); done.signal() }
XCTAssertEqual(done.wait(timeout: .now() + 20), .success)   // 现在是 .timedOut
```
