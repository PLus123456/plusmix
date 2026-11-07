# StreamingTests 的 `ThrottleProxyTests.testBlockStopsForwardingAndCloses` 2026-11-07 起本机几乎必红（放开后旧连接 1 s 内没被判死）

归属会话 / 分支：W2-D 推流系（`Packages/SwitcherOutputs/Tests/StreamingTests/ThrottleProxy.swift` / `ThrottleProxyTests.swift` 是 E7 / E8 用的用户态限速代理与它自己的用例）
发现于：G13（prompt 140，分支 `g13`）2026-11-07 Outputs 整包 + 单独复跑
严重级：工装（不影响产品；E7 / E8 / E9 真场景同一天都过：E7 三路封 30 s 其余丢 0、E8 10 / 10、E9 误差 0.00%）

## 现象

- g13 树（9049649）：Outputs 整包里红 1 次（同机 App build-for-testing 在跑），之后机器安静时单独复跑 **5 / 5 红**（1.51–1.57 s）。断言 `ThrottleProxyTests.swift:105`"放开后旧连接应当已被代理关掉"：`proxy.blocked = false` 后 0.3 s + 50 × 20 ms 内，客户端非阻塞 `write` 一直没拿到 EPIPE / ECONNRESET。前两条断言（封住后发送缓冲填满、`bytesForwarded == 0`）都过，`testRateLimitPaces` 都过。
- **未动过这两个文件的 main c7d441a**（detached worktree，同一台机器同一时刻）：`swift test --filter ThrottleProxyTests` 连跑 3 次 = **过 / 红 / 红**（0.31 s / 1.66 s / 1.55 s）。所以不是 136–139 的回归，是用例对内核 TCP 行为的时序假设在本机今天不成立（放开时代理对两端 `shutdown(SHUT_RDWR)`，客户端要靠对端 RST 才能在 1 s 内写失败；端口 41003 / 41004 写死，连跑时上一轮的套接字还在收尾也可能有关——第一次过、之后红的样子像这个）。
- 138 W2-D6 同日 12:28–12:44 的整包里它过了（reports/w2-stream-6.md §2），G12 整包也过（"这次没抖"）；KNOWN_ISSUES"测试与工具"第一条早就把 `ThrottleProxyTests` 列在偶发红名单里。

## 建议

- 断言改成"放开后旧连接**最终**被关"（等到 EPIPE / ECONNRESET 或读到 EOF，上限 3–5 s），或在代理放开时对旧连接 `close()` 而不只 `shutdown`，再 `SO_LINGER` 0 让对端立刻收 RST；端口改成临时端口（bind 0 再读回）避免连跑撞上一轮的 TIME_WAIT。
- 这条红不挡 0.1.1（工装），但每次全量都要人工复跑一次说明一遍，早改早省事。

## 处理结果

（W2-D 会话填）
