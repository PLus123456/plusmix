# GPU 被桌面抢占 100–200 ms 时渲染器连续 skipped；计数分不清"GPU 晚"和"完成线程被饿"

归属会话 / 分支：W1-C / `w1-compositor`（`MetalRenderer.render` 的在途计数与 `completionLoop`），观察性质，S3
发现于：G2 / `make gate2-1h`（60 分钟，release，环境不干净：用户同时在用桌面，Chrome + WindowServer 占 GPU，见 reports/G2-run-1h.md）

## 现象

60 分钟里 missed_render = 13，全部是渲染器 `.skipped`（时钟跳拍 0），集中在两簇：00:55:07–00:55:30 共 11 次（其中一秒内 6 次）、01:02:28–01:02:33 共 2 次。对应秒的 render_ms 窗口平均 3.4–6.28 ms（平时 2.2），说明那一秒里有帧的 gpuEnd 比拍点晚了约 200 ms —— GPU 本身完成晚了，不是完成线程没来得及减在途计数。同一时段 IOKit 的 GPU 占用只有 10–13%（秒平均）。快照过期（状态机线程超过 1 ms 没准备好）19 次、慢消费者调用 2 次，说明同一时段 CPU 侧线程调度也有毫秒级抖动。10 分钟干净运行（GPU > 50% 的秒数 0）missed_render = 0。

**时间相关性（归因线索，不是结论）**：整个 60 分钟里 GPU > 50% 的时段是 00:43–00:44（30 s）和 01:22–01:39（用户在用桌面，Chrome + WindowServer），两簇 miss（00:55、01:02）都不在其中；反而 01:24–01:39 GPU 持续 60% 时 0 次 miss。两簇 miss 都发生在一个残留进程存活期间：第一次冒烟跑卡住的旧 switcher-headless（带一条时间约束实时线程的空音频设备 + 2 ms 轮询泵 + 卡在 usleep 循环的 writer 队列）到 01:09 才被 SIGKILL，之后 30 分钟 0 次 miss。所以更像"某个未知的系统 / 进程事件让 GPU 停了 200 ms"，而不是桌面 GPU 抢占；无法复现前不下结论，建议在干净机器上重跑 60 分钟。

设计上这是预期行为（CPU 领先 GPU ≤ 2 帧，GPU 晚就跳拍记 V2），但有两点值得 W1-C 看：

1. **计数口径**：`.skipped` 既可能是 GPU 真晚，也可能是完成线程（普通 user-interactive 线程，`waitUntilCompleted` 后才减在途计数）被调度延迟 > 2 帧。现在只能靠 render_ms 侧推。建议 `RenderedFrame` / 渲染器计数里分开记"gpuEnd − submit"和"完成线程处理时刻 − gpuEnd"，Stats 之外的诊断计数即可（不改契约）。
2. **完成线程的优先级**：它决定在途计数何时释放；桌面重负载下若它被饿，会把本来能渲染的拍也跳掉。要不要给它挂时间约束策略（像时钟线程那样），或至少量一下它的唤醒延迟分布，请 W1-C 评估。

## 复现步骤

`make gate2-1h` 时同时在机器上开浏览器看视频 / 拖窗口；或用 `--duration 300` 的 headless 配合任何占 GPU 的程序。看 stats.jsonl 的 missed_render 增量时刻与 load.log。

## 严重级

S3（观察；V2 60 fps 每小时 13 帧 = 0.006%，在必须档 0.02% 内，但 V5 因此少 13 帧）。
