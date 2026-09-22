# 系统守护进程 / 桌面活动突发时渲染器成串 skipped（10 分钟里 1–11 拍），G3 时同类运行是 0

归属会话 / 分支：W1-B（w1-core：ProgramClock / Engine 的跳拍与渲染派发）与 W1-C（w1-compositor：MetalRenderer 的 maxInflight / 完成线程）——先由 W1-B 定位是 CPU 侧没被调度还是 GPU 侧积压
发现于：G4 检查点，scenarios/g4.json 10 分钟 L2，2026-09-20/21 三次运行（reports/G4-run-10min-run1/2/3.md；产物 .build/gate4/10min-run{1,2,3}/）

## 现象

| 运行 | missed_render | 时刻 / 拍 | 同一时刻 load.log 的进程 | 派生的 V4 / V5 |
|---|---|---|---|---|
| run1 14:04 | 2 | 拍 33970、34030（相邻两秒各 1） | Chrome 55% + 26% | 引擎侧设计外 19 帧 |
| run2 14:29 | 1 | 拍 24609 | WindowServer 42%、Chrome 8.5% | 引擎侧 10 帧、frameprobe 2 帧 |
| run3 23:54 | 11 | 拍 32297 / 32416（+4）/ 32896（+2）/ 33017 / 33256（+3），12 s 内 | tccd 14% → 38%、peopled、callservicesd、AddressBookManager 19%；桌面另有 Codex / Clash / Chrome | 引擎侧 183 帧、frameprobe 11 帧、V5 −11 |

- 三次的 V3（时钟唤醒抖动）p99 都 ≤ 0.05 ms、max ≤ 0.13 ms：**时钟线程没晚醒**，是"下一拍到了上一帧还没提交"——`renderSkipped`（headless 收尾摘要"渲染器 skipped 11"，"跳拍 0"）。
- 跳拍那几秒 render_ms 的每秒均值 3.7–5.4 ms（平时 2.0），GPU 占用 26% 没变，CPU 占用 47–57% 没变；一次 +4 = 约 70 ms 内提交不出帧。
- G3 的三次 10 分钟运行（09-15 / 09-18 / 09-19 复核）V2 都是 0，同一台机器；G2 的 60 分钟运行有 13 帧 skipped 两簇（reports/G2.md §6 第 8 条，当时也归因不了）。
- 负载差别：g4 场景多了 4 路抠像叠加 + 自定义多画面 + 噪声底纹（V1 avg 1.78 → 2.0 ms，GPU 21% → 25%），但跳拍时刻和这些无关（叠加开关在 x2.5 s，跳拍在整数秒附近、与守护进程突发对齐）。

## 复现

`scripts/gate4.sh --minutes 10`（或任何 headless 10 分钟运行）期间在桌面上正常使用（开 Chrome 页、触发 TCC 弹窗 / 通讯录同步），看 stats.jsonl 的 missed_render 增量与 load.log。
产物：`.build/gate4/10min-run3/{stats.jsonl,load.log,headless.log}`（跳拍最多的一次）。

## 严重级

S2（测试标准 §6：功能可用、指标偶发不达标）——§4 必须档 V2 ≤ 0.02% 在 run3 是 0.031%（不过），run1 / run2 过；G3 起的"10 分钟内 0"本机线三次都不过。
8 小时长稳（W4-A，S1 硬性）里这种突发不可避免，得知道它是不是会累积成 A/V 问题（V4 的派生 dup / drop 表明每次跳拍每路 60 fps 输入丢 1 帧、之后 dup 3 帧才追回）。

## 猜测原因（给 W1-B / W1-C）

1. 渲染线程是 time-constraint 策略，但 `renderer(_:didComplete:)` 的完成线程（`waitUntilCompleted`）和派发给消费者的线程不是；tccd / WindowServer 突发时完成线程晚被调度，`maxInflight = 2` 的信号量把渲染线程卡住 → 下一拍 skipped。
   看法：给完成线程也挂实时策略，或 skipped 时记下"卡在哪个信号量 / 等了多久"（`EngineCounters` 加 skip 原因分类：GPU 未完成 / 信号量 / 输入表），报告才能归因。
2. 每次跳拍后各路 60 fps 输入 dup 3 帧才追回（run1 每路 dup 3 / drop 2）——跳拍后的到达余量或候选表恢复比预期慢 1–2 拍，W1-B2 的"停顿后一两个窗口内恢复"在这种 1–4 拍的小停顿上可以再看一眼。
3. 与 reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md（真 App 启动 377 ms 停顿）是同一类：整个进程被系统拖住时引擎的行为。

## G4 的处理

不放行、不改阈值：reports/G4.md 把 run2（1 拍）作为本次的代表运行，V2 / V4 按实际标 ❌，环境写清；等用户定是否按"个案放行"处理，或等 W1-B 归因后重跑。
