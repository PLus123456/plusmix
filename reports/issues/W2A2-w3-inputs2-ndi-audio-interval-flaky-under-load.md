# W2-A2 → W3-A：NDI 回环的音频块间隔断言在整包负载下偶发超阈值

归属会话 / 分支：W3-A / `w3-inputs2`（`Packages/SwitcherInputs/Tests/NDITests/`，W2-A2 不能改）
发现于：W2-A2 跑 `swift test --package-path Packages/SwitcherInputs`（整包，含 W2-A2 自己 60 s 的 A1 + 一条 user-interactive 的读环线程），2026-09-23，本机 load average 2.9–3.4
现象：`NDITests.NDILoopbackTests.testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned` 失败一次：
`XCTAssertLessThanOrEqual failed: ("25.338875") is greater than ("24.667") - 最大间隔不超过一块 + 抖动`（NDILoopbackTests.swift:326）。
单独跑这一条通过。
复现步骤：`swift test --package-path Packages/SwitcherInputs`（整包），看 NDILoopbackTests 那一条；单独 `--filter testNDI_loopback_audioBlocksIntoRing` 稳过。
严重级：S2（测试偶发红，产品行为没问题；检查点跑 `make test` 可能撞上）
猜测原因：阈值是"一块 + 抖动"（24.667 ms），整包里并发的实时 / 高优先级线程多，NDI 发送 / 接收线程被调度晚 0.7 ms 就过线。
可选的处理：阈值留余量（例如加一个调度余量常数并写明理由），或断言改成 p99 / 次数上限；阈值归属按铁律 9 由用户定。
