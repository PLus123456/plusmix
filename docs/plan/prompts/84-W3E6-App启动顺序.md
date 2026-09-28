## 84 W3-E6 App 启动顺序：把 control.start / engine.warmUp 挪到定 t0 之前（W1-B3 定位的启动第一秒停顿的根治；用户 2026-09-28 指派 agent 直接做）
分支：w3-app-7（从 W1-B3 合入后的 main 开）。只准动：App/。
先读：reports/w1-core-3.md §1（定位）与 §5 第 1 条（改法）、reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md、reports/G4.md §6.5、App/Sources/Engine/SwitcherSession.swift 的 start()。

现象：App 打开节目时先定 t0 = now + 300 ms，之后才 inputs.reconcile（21 ms）→ control.start()（冷启动 686 ms，第二次 57 ms）→ audio.start（54–65 ms）→ engine.start，节目时钟起在 t0 之后 472–477 ms：第一秒 jitter ≈ 470 ms、missed_render 28、到达余量把已注册的路丢 3 s。
交付：
1. 先写红测试（函数名带 ID，例如 `testW3E6_sessionStart_clockNotLateAfterColdStart`）：真 App 会话冷起（第一次 control.start）后读引擎的 `clockStartLag` ≤ 20 ms、头 2 秒 missed_render ≤ 2、各路 drop 0（修前红：起晚 ≈ 470 ms / missed 28）。
2. 修：`SwitcherSession.start` 里 control.start()、audio 引擎起、`engine.warmUp()`（W1-B3 新加的幂等预热）都在定 t0 之前做完，再定 t0 = now + 提前量并 engine.start；停止 / 换节目路径保持对称（warmUp 过没起的引擎 stop 能释放）。
3. `make test-app` 全量 0 失败（空机器；先 `pgrep -fl "xcodebuild .*test"`）；`make lint BRANCH=w3-app-7`。
不做：包与契约。报告 reports/w3-app-7.md（五段）。不 push、不 merge。
