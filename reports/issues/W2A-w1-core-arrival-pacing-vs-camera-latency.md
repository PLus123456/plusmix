# 到达余量（ArrivalPacing）对高延迟源（摄像头）：多付 1–3 帧延迟，起流时可能黑屏 4 s

归属会话 / 分支：W1-B / w1-core（`Packages/SwitcherCore/Sources/SwitcherEngine/Slots/ArrivalPacing.swift`、`LockFreeFrameSlot.latest(forTick:)`）
发现于：W2-A（w2-inputs，claude/w2-inputs-phase-one-2f34b3），`switcher-input-probe run --input camera:0`（真引擎 + Metal 渲染器 + LockFreeFrameSlot），2026-09-15，main 2290b4e 上的引擎

## 现象

内置摄像头（MacBook Pro 相机，1080p@30 '420v'）进 1080p60 节目，L1（ingressTime → PGM 消费者 consume 入口）：

| 引擎入口 | L1 平均 | p99 | max | 帧槽 | 到达余量 |
|---|---|---|---|---|---|
| `latest(forTick:)`（默认，到达余量开）运行 1 | 64.71 ms（**3.88 帧**） | 76.14（4.57） | 88.78（5.33） | pushed 293 / consumed 348 / **dropped 117 / reused 173**；**前 252 拍 latest 返回 nil（黑屏 4.2 s）** | 136.22 ms（窗口最大 d 157.56） |
| 同上，运行 2 | 41.57（2.49） | 63.73（**3.82**） | 65.23（3.91） | dropped 11 / reused 299 | 86.87（窗口最大 d 74.67） |
| 同上，运行 3 | 60.95（3.66） | 83.18（4.99） | 83.58（5.01） | dropped 0 / reused 298 | 107.01（窗口最大 d 92.18） |
| `latest(atOrBefore:)`（`PacingOptions.enabled = false`） | **8.86 ms（0.53 帧）** | 16.97（1.02） | 17.51（1.05） | dropped 1 / reused 300（30 进 60 的设计内 50%） | — |

阈值：L1 ≤ 3 帧（测试标准 §4；W2-A 摄像头 ≤ 3）。同一台机器、同一段时间、同一个输入实现，只差引擎入口。机器负载 2–3（另外四个 W2 会话在编译）。

摄像头的到达延迟 d = ingressTime − pts（`switcher-input-probe clocks --camera 0`，8 s）：pts 严格 33.33 ms 步进（传感器时钟），
d 稳态 54–58 ms（相机管线固有延迟），每秒有 1–3 帧 60–75 ms（送达抖动），起流第一帧 75 ms，重负载下见过 157 ms。

## 复现步骤

```bash
cd Packages/SwitcherInputs
Scripts/probe-app.sh run --input camera:0 --seconds 10              # 到达余量开（默认）
Scripts/probe-app.sh run --input camera:0 --seconds 10 --no-pacing  # 对照
Scripts/probe-app.sh clocks --camera 0 --seconds 8                   # d 的逐帧分布
```
（`probe-app.sh` 把探针包成 .app 跑，为的是摄像头权限；第一次要点允许。）

## 严重级

S1：摄像头是产品的主输入类型；默认配置下 L1 p99 超阈值 1–2 帧，起流时可能黑屏数秒。

## 猜测原因（读了 ArrivalPacing.swift）

余量 L 的设计目标是"合格的帧一定已经在槽里"（L ≥ 到达延迟 + 抖动），它对 d ≈ 0 ± 抖动 的源（合成源、文件）是对的：
不加余量就会与拍点赛跑。但摄像头的 d 是 55 ms 的**固定管线延迟 + 几毫秒抖动**，帧永远在它合格之后很久才到：

1. **延迟**：L = 16 s 窗口内 d 的最大值 + 1 ms + 15%。每帧要等 L − d 才合格，稳态 ≈ 20–50 ms，一次送达尖峰（d 90–157）会把 L 顶高并保持 8 块 × 60 帧 = 16 s。
   而对这种源，不带余量的挑帧不会赛跑：帧到槽时 pts 早已 ≤ 拍点，后到的帧 pts 也一定更大，只会"到了下一拍就用"，没有 dup / drop 对
   （对照运行 dropped 1，那是引擎起来前的）。也就是说余量对 d ≫ 抖动 的源只有代价没有收益。
2. **起流黑屏**：初值 = max(floor, 2 × d₀ + 1 ms)，d₀ 是第一帧的 d——摄像头第一帧总是最慢的（75 ms，重负载 157）→ 初值 151–315 ms，
   再被结构上限 min(500, 最早到达 + (capacity − 1) × 帧长) = d₀ + 66.7 钳到 142–224 ms。之后的帧 d ≈ 55–82，要等 L − d ≈ 87–142 ms = 2.6–4.3 个帧长
   才合格，而候选表只有 3 格：帧还没合格就被后面的帧挤掉（dropped），`pick` 永远没有可返回的帧、`lastReturned` 也一直是 nil → 返回 nil
   （黑场）。热身期（2 块 = 120 帧 = 4 s）内不许降余量，所以黑屏正好 4.2 s（运行 1 的 252 拍），热身结束"降 2"之后才出画。
   结构上限用的是**最早到达**（窗口最小 d），保证的是 d = d_min 的帧恰好等 (capacity − 1) 个帧长，但 d > d_min 的帧等得更久
   ——初始化时窗口里只有 d₀ 一个样本，d₀ 又偏大，上限就失效了。
3. **抖动 / 丢帧对**：上限 = d_min + 66.7 有时低于 d_max（运行 1：136 < 157），d 大于上限的帧算"迟到"，一次迟到 = 一次 dup；
   运行 1 六秒里 dropped 117 / reused 173（40% 的拍），是 V4 口径的设计外重复 / 丢弃。

可能的修法（W1-B 定）：初值用 d₀ + 保护带而不是 2 × d₀；候选表挤掉"从未返回"的帧时立即把余量降到让最新帧此刻合格（饿死保护，热身期也允许）；
估计器用短窗口分位数或指数衰减代替 16 s 最大值，或者按"d 的中位数 ≫ 抖动"识别高延迟源、把余量定为 抖动跨度 而不是 d 本身。
W2-A 的 `Packages/SwitcherInputs/Sources/SwitcherInputsHarness/` 可以直接当复现工装（`InputEngineHarness` + `LatencyFrameSlot`）。
