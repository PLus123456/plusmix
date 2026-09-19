归属会话 / 分支：W2-D / w2-stream（`Packages/SwitcherOutputs/Tests/StreamingTests/ThrottleProxyTests.swift`、`ThrottleProxy.swift`）
发现于：W1-E2（w1-outputs-2）整包 `swift test`，main 2fdf52d + w1-outputs-2 8f138f2，机器有其他会话在编译（load 3）
现象：`ThrottleProxyTests.testBlockStopsForwardingAndCloses` 间歇失败："放开后旧连接应当已被代理关掉"（`XCTAssertTrue(failed)`，
      ThrottleProxyTests.swift:105）。整包跑 1 次失败；单独 `swift test --filter ThrottleProxyTests` 连跑 3 次：过、失败、过。
      同一 bundle 的其他测试（testRateLimitPaces、StreamOutputTests、MediaMTXTests 的 E2E3 / E9）都过；与 W1-E2 改的 Recorder / AudioEncoder 无关（代理是纯套接字）。
复现步骤：`swift test --package-path Packages/SwitcherOutputs --filter ThrottleProxyTests` 多跑几次。
严重级：S3（只是工装测试抖动；E7 / E8 用的封端口路径不受影响，那两个在 gate3-net 里靠 netem）。
猜测原因：测试放开（`proxy.blocked = false`）后只等 0.3 s，再用 50 × 20 ms 的非阻塞 write 探旧连接是否被关；代理关旧连接走的是它自己的线程 /
      run loop，机器忙时 1.3 s 内可能还没关到（或关了但本端发送缓冲仍未满、write 没报 EPIPE）。改法：等 `proxy` 暴露"已关的连接数"再断言，
      或把探测窗口拉长到几秒并用 `poll(POLLHUP)` 判断，而不是靠 write 出错。
