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

---

## G3 复核与裁定（2026-09-15，检查点会话；用户授权检查点定夺）

读了 `ArrivalPacing.swift`、`LockFreeFrameSlot.latest(forTick:)`、设计方案 §3.2 / §3.6 和 W2-A 的三次实测之后的结论。

### 1. 归属与性质

- 输入侧没问题（契约入口对照 0.53 帧）。**归 W1-B（w1-core）修**，不改契约（`FrameSlot.latest(atOrBefore:)` 语义不动，引擎入口 `latest(forTick:)` 仍是引擎内部接口），不改测试图案 / 阈值。
- 到达余量的理论是对的：要让"合格的帧一定已在槽里"，余量 L 必须 ≥ 窗口内最大到达延迟 d_max，代价 = d_max − d_k。对合成源 / 文件 / 屏幕（d ≈ 0 ± 几 ms）代价是几毫秒，
  对摄像头它等于"送达抖动跨度"——本来也只有 15–20 ms（一个节目帧上下）。**现在多付的 1–3 帧不是理论代价，是三处实现缺陷**：初值、结构上限、估计器窗口把孤立尖峰当成稳态。
- 检查点不在胶水里把摄像头的到达余量关掉：那是挑帧策略不是接线；关掉的对照数字 W2-A 已经量了（0.53 帧）。修好之前 App 里摄像头会多 1–3 帧、起流可能黑 4 s，
  写进 G3 已知问题与 docs/checklists/G3.md 第 7 条。

### 2. 要求 W1-B 改的（验收按第 3 条）

1. **初值**：`initialFactor × d₀` 把第一帧（相机管线里总是最慢的那帧）翻倍，再被"用单样本窗口算的结构上限"钳到 d₀ + 66.7 ms，稳态帧（d ≈ 55）要等 2.6–4.3 个帧长才合格，
   候选表 3 格装不下 → 全部被挤掉 → `pick` 返回 nil → 黑屏到热身结束（4.2 s）。改成：初值 = d₀ + 保护带（不乘 2；合成源那种 d ≤ 0 的仍走 `initialFloor`）。
2. **饿死保护，热身期也生效**：候选表满、最旧候选仍不合格、且这一拍没有可返回的帧时，立即把余量降到"让最旧候选此刻恰好合格"（零代价：那帧本来就要被挤掉，
   降余量只是把一次 drop 换成一次正常返回）。任何情况下 `latest(forTick:)` 在槽里有帧时不得返回 nil。
3. **余量的动态上限 = 窗口最小到达延迟 + 一个节目帧 + 保护带**（替换现在的结构上限 min(500 ms, d_min + (capacity − 1) × 输入帧长)）。这就是硬件帧同步器的
   "最多缓一帧"：任何源的到达余量代价 ≤ 1 个节目帧；比这更晚的帧按现有"迟到"路径处理（花一次 dup、不丢帧、不再抬余量）。合成源 ±3 ms 抖动远小于一帧，
   V4 仍是 0；NDI 一类抖动超过一帧的源按设计方案 §3.6 在输入侧自带抖动缓冲，不是帧槽的事。
4. **保护带的比例部分按抖动跨度算**（`guardRelative × (窗口 d_max − d_min)`），不按 d_max 的绝对值算（现在对 55 ms 的相机白付 8 ms；对 d < 0 的合成源两种算法本来就相同）。
5. 估计器窗口现在是 8 块 × 60 帧（30 fps 源 = 16 s），一个 100 ms 尖峰把余量顶高 16 s。有了第 3 条的上限这已不影响延迟，但窗口最大值仍会让余量在上限处贴着不下来；
   建议改成按时间定长的块（例如 8 × 2 s）或对超过上限的样本不计入窗口最大值。取舍 W1-B 定。
6. 可选：`Engine.registerInput(number:slot:pacing:)` 允许组装方按输入类型给 `PacingOptions`（摄像头 / DeckLink 之类"自由跑"的源可以直接关），
   默认值仍按上面的规则自适应。不是本次必需。

### 3. 验收标准（W1-B 报告里要有这些数）

- 内置摄像头（1080p@30 '420v' 进 1080p60）产品配置（到达余量开）：`Packages/SwitcherInputs/Scripts/probe-app.sh run --input camera:0 --seconds 10` × 3 次，
  **L1 avg ≤ 1.5 帧、p99 ≤ 2 帧、max ≤ 2.5 帧**；起流后第一帧到达 ≤ 2 拍内出画（`latest` 返回 nil 的拍数 ≤ 2）；dropped ≤ 2（引擎起来前的）。
- 对照 `--no-pacing` 仍 ≈ 0.53 帧（输入侧不变）。
- `make gate2`（M0 合成源 10 分钟）与 `make gate3-run`（G3 场景）V4 设计外仍为 0，V1 / V3 不变。
- SwitcherEngineTests 里加对应用例（高延迟源：d = 55 ± 3 ms 的模拟输入，热身期黑屏 0 拍、稳态余量 ≤ d_min + 1 帧 + 保护带；孤立 100 ms 尖峰只花一次 dup）。
