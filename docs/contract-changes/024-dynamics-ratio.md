# 024 压缩器的"比例"：AUDynamicsProcessor 没有固定比例，简单模式的"阈值 + 比例 + 输出增益"换算不准

提出会话 / 分支：W5-C（prompt 88）/ `w5-audio-bus-effects`

## 改什么

`EffectSlot` 键表（docs/CONTRACTS.md §2.4，`Packages/SwitcherCore/Sources/SwitcherContracts/Input.swift` 的 EffectSlot 注释）三选一：

| 选项 | 契约 | 引擎 | 界面 |
|---|---|---|---|
| (a) `dynamicsProcessor` 加 `ratio`（number，1…20；有它时不看 `headroomDb`） | 加一个可选键 | AUDynamicsProcessor 做不到，同一个 id 底下要换成自写压缩器（C，实时线程） | 简单模式"阈值 + 比例 + 输出增益" |
| (b) 新 id `compressor`：`thresholdDb`、`ratio`、`kneeDb`、`attackSeconds`、`releaseSeconds`、`makeupGainDb` | 加一个 id 和键表 | 自写 C 压缩器（前瞻 0，不加延迟），`dynamicsProcessor` 保留为"苹果 AU（高级）" | 简单模式用 `compressor`，高级里还能选 `dynamicsProcessor` |
| (c) 不改契约 | — | 不动 | 简单模式给"阈值 + **压缩量** + 输出增益"，压缩量 = headroom，文案写实："输出不超过阈值 + 压缩量"；或给"约 R:1"按下表换 headroom，标"约" |

(c) 的近似表（W5-C 探针，阈值 −20 dB、1 kHz 正弦、输入在阈值上 0…20 dB，每 1 dB 一点，headroom 0.1…40 按 3% 步进搜）：

| 想要的比例 | 最合适的 headroom | 与硬拐点 R:1 的最大偏差 | 偏差最大处 |
|---|---|---|---|
| 1.5:1 | 16.1 dB | 1.81 dB | 阈值上 7 dB |
| 2:1 | 9.5 dB | 2.04 dB | 阈值上 6 dB |
| 3:1 | 5.1 dB | 1.87 dB | 阈值上 5 dB |
| 4:1 | 3.4 dB | 1.61 dB | 阈值上 4 dB |
| 6:1 | 1.9 dB | 1.24 dB | 阈值上 3 dB |
| 10:1 | 0.9 dB | 0.84 dB | 阈值上 20 dB |
| 20:1 | 0.25 dB | 0.47 dB | 阈值上 20 dB |

（和 6 dB 软拐点的 R:1 比，偏差几乎一样。）

## 为什么

docs/ui-study/04-待拍板.md Q61 要压缩器简单模式"阈值 + 比例 + 输出增益"，比例在 App 侧换算成 DynamicsProcessor 的 Headroom，"先写探针量换算，换算不准就提案加 ratio 键"。W5-C 探针（reports/w5-audio-bus-effects.md §1.4）：

- 头文件 AudioUnitParameters.h 自己写着 "the dynamics processor does not have fixed compression ratios. Instead, HeadRoom adjusts the amount of compression … The compression ratio is automatically adjusted to not exceed Threshold + HeadRoom"；
- 实测静态曲线是"阈值以上渐近到阈值 + headroom"（与阈值无关，平移即可）：headroom 5 时输入在阈值上 2 / 4 / 6 / 10 / 20 dB → 输出在阈值上 2.00 / 3.15 / 3.72 / 4.28 / 4.74 dB，局部比例从阈值处约 1:1 一路涨到 ∞:1；
- 常用的 2:1–4:1 在最合适的 headroom 下仍差 1.6–2.0 dB，偏差落在操作员最常用的阈值上 4–7 dB 一段。只有 ≥ 10:1（接近限幅）才 < 1 dB。

所以 W5-C 没有做比例滑块（不硬凑），界面仍是原来的六个参数，只把范围收进 AU 的范围。

## 影响谁

- (a) / (b)：SwitcherContracts（键表注释、CONTRACTS.md §2.4、docs/api.md 的 setBusEffects 说明）、SwitcherAudio（自写压缩器动 C 热路径，要过 A7：离线 10 分钟 + 真设备 1 分钟、check-rt-symbols）、Integration（BusEffectPlan 解析新键 / id）、App（EffectChainView 简单模式、AudioEffectParams）、手册。prompt 102（每路效果格）若也自写压缩器，可以与总线共用一份 C 实现。
- (c)：只有 App（界面改版 prompt 97 / W5-K 时做）与手册。

## 怎么迁移

(a) / (b) 都是新增键 / id：老节目没有 `ratio` 就是现在的行为，不升 schemaVersion。(c) 不涉及。

## 顺带要定的两处口径（不改字段，只补注释）

1. `parametricEQ.q` 的口径：W5-C 按经典 Q 实现——带宽 = 增益为峰值一半（dB）处的上下边频之比，BW = 2/ln2 · asinh(1/(2q)) 倍频程（q = √2 → 1 oct）；
   AUNBandEQ 的带宽参数就是这个定义。原来设计方案 §7 写的 AUParametricEQ 的 Q 不是这个口径（实测 Q = 1、+12 dB 时半增益带宽 2.12 oct、+6 dB 时 2.42 oct，随增益变）。
   建议 CONTRACTS.md §2.4 写进去；另注"一个 EQ 格（AUNBandEQ）最多 16 段，连续的 parametricEQ 格合成一格；每条总线最多 3 格（被别的效果隔开的 EQ 另占一格），超出的不装"。
2. `peakLimiter` 没有天花板键：AUPeakLimiter 的天花板固定 0 dBFS。要 −1 dBTP 这类天花板，现在用"预增益 +x、限幅之后的总线增益 −x"表达（W5-C 的 `testA_busEffects_limiterHoldsCeiling` 就这么测 −6 dB 天花板）。
   要不要加 `ceilingDb`（需要限幅之后再一级增益：多占一格，或改 C）请一并定。

## 建议

先 (c)（不改契约，界面改版时写实文案），(b) 进 0.1.x 与 102 一起排。

状态：待批
