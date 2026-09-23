# W2-A2 → W3-A：NDI 回环的两条计时断言在整包负载下偶发超阈值

归属会话 / 分支：W3-A / `w3-inputs2`（`Packages/SwitcherInputs/Tests/NDITests/`，W2-A2 不能改）
发现于：W2-A2 跑 `swift test --package-path Packages/SwitcherInputs`（整包，含 W2-A2 自己 60 s 的 A1 + 一条 user-interactive 的读环线程），2026-09-23，本机 load average 2.9–3.4
现象：两次整包跑各红了一条，都是超阈值不到 1 ms，单独跑都过：
1. 第一轮（`swift test --package-path Packages/SwitcherInputs`）：`testNDI_loopback_audioBlocksIntoRing_timestampsMonotonicAndAligned`
   `XCTAssertLessThanOrEqual failed: ("25.338875") is greater than ("24.667") - 最大间隔不超过一块 + 抖动`（NDILoopbackTests.swift:326）。
2. 第二轮（`make test`，分支叠在 P3 上之后）：`testNDI_loopback_senderStops_noSignalWithin3Intervals_restartsRecover`
   `XCTAssertLessThanOrEqual failed: ("71.918375") is greater than ("71.666664") - noSignal 应在 3 个帧间隔内（+ 一次 capture 超时的粒度）`（NDILoopbackTests.swift:214）。
   `make test` 逐包跑、遇错即停，这一条红了后面的 Audio / Outputs / Control / TestKit / 工具 / App 就都没跑——**检查点跑 `make test` 撞上它会整轮白跑**。
单独跑：两条各连跑两遍都过（4.3 / 4.3 s、6.7 / 5.9 s）。W2-A2 没有碰 NDI 的代码（P3 改过 `NDIInput.init(config:)` 取带宽 / 抖动缓冲，与计时无关）。
复现步骤：`swift test --package-path Packages/SwitcherInputs`（整包，负载来自同包的 60 s A1、Fake DeckLink、真摄像头 / 屏幕 L1 等），看 NDILoopbackTests；
单独 `--filter 'testNDI_loopback_audioBlocksIntoRing|testNDI_loopback_senderStops'` 稳过。
严重级：S2（测试偶发红，产品行为没问题；检查点跑 `make test` 可能撞上）
猜测原因：两条的阈值都贴着理论值（"一块 + 抖动" 24.667 ms；"3 个帧间隔 + 一次 capture 超时" 71.667 ms），整包里并发的实时 / 高优先级线程多，
NDI 发送 / 接收线程或看门狗定时器被调度晚 0.25–0.7 ms 就过线。W3-A 报告里第二条单跑是 70.2 / 66.3 ms，离阈值本来就只有 1.5 ms。
可选的处理：阈值留余量（例如加一个调度余量常数并写明理由），或断言改成 p99 / 次数上限；阈值归属按铁律 9 由用户定。
