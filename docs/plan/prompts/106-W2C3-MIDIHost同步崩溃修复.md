## 106 W2-C3 `MIDIHost.sync` 偶发崩溃修复："non-escaping closure has escaped"（0.1.x 唯一的 S1 崩溃；G7 之后随时可开，2026-10-10 开单）
分支：w2-control-3（从 G7 快进后的 main 开）。只准动：Packages/SwitcherControl/Sources/SwitcherControl/MIDI/、Packages/SwitcherControl/Tests/SwitcherControlTests/。
先读：reports/issues/W5A-w2-control-midihost-sync-escaping-crash.md（现象、两份 .ips 的栈、原因、两种改法）；Packages/SwitcherControl/Sources/SwitcherControl/MIDI/MIDIHost.swift:62-75；reports/w2-control-2.md（78：宿主线程 run loop 的来历、热插拔用例怎么写）；docs/KNOWN_ISSUES.md 产品缺陷表第一行；reports/G7.md §5.1（第 3 轮全量又崩一次的记录）。

背景：`MIDIHost.sync` 把非逃逸闭包经 `withoutActuallyEscaping` 塞给宿主线程的 run loop，块里先 `done.signal()` 再释放闭包；调用方被放行后立刻离开 `withoutActuallyEscaping`，宿主线程上的块还没释放，运行时判闭包逃逸直接 trap。起停 session（新建 / 打开节目、改格式、退出、测试宿主的 freshSession）都走这条路，机器忙时更易出：W5-A / W5-B 的测试宿主 2026-10-01 各崩一次，G7 第 3 轮全量又崩一次（`~/Library/Logs/DiagnosticReports/PlusMix-2026-10-04-010946.ips`）。正式 App 崩了就是整个导播台退出，S1，0.1.1 放行的第一条阻塞。

交付（先写红测试；函数名带 ID）：
1. 压力用例 `testC_midiHostSync_stressNoTrap`：宿主线程塞一个慢块（睡 1–5 ms），主线程连续 `sync` 2000 次 + `MIDIController.start()` / `stop()` 200 次，Debug 构建不 trap；修前先跑出复现概率写进报告（跑 N 次红几次），修后同样跑法 0 次。
2. 改法任选问题单的一种：(a) `sync` 的参数改成 `@escaping @Sendable () -> T`、去掉 `withoutActuallyEscaping`（调用方同步等结果，逃逸与否无差别；调用处都在本包）；(b) 保留非逃逸签名，闭包放进可清空的盒子，块里取出跑完、清空盒子（闭包最后一个引用在 signal 之前放掉）再 `done.signal()`。返回值、线程归属、热插拔行为（78 的用例）不变。
3. 顺带（可不做，做了写报告）：进程里第一次打开节目时 MIDIServer 冷启动约 0.6 s 在主线程同步等（KNOWN_ISSUES S3，W2-C）——≤ 50 行能挪到宿主线程异步连接、连上再回报就做，否则写明不做。
4. SwitcherControl 全包 `swift test` 绿；`make test-app` 全量一轮里 freshSession 起停那几条不再崩（崩溃报告目录里没有新的 PlusMix .ips）；`make lint BRANCH=w2-control-3`。
5. 报告 reports/w2-control-3.md 五段；KNOWN_ISSUES 那一行由 G8 销号。

不做：MIDI 映射 / 动作（100 的）；契约；别的包。要在 100 之前合入（100 也动 SwitcherControl/MIDI/），G8a 顺手合。
