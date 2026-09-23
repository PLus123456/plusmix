# SyntheticSourceTests 的 hostTimeMs 断言没掩 28 位：机器连续唤醒超过 3.1 天就整片红

发现会话 / 分支：P3 / p3-contracts（2026-09-23 跑 `make test` 时）
归属：W1-A（`Packages/SwitcherTestKit/Tests/`）→ 续做会话 **W1-A3 / prompt 62 / 分支 w1-testkit-3**
严重度：中（不是产品缺陷，是测试的断言写错；但会让 `make test` 在任何一台开机久的机器上红，挡住所有会话与检查点）

## 现象

```
SyntheticSourceTests.swift:60: error: -[SwitcherTestKitTests.SyntheticSourceTests
  testW1A_syntheticVideo_60fps10s_continuousMonotonic_pushed600] : XCTAssertEqual failed:
  ("Optional(4665815)") is not equal to ("Optional(273101271)")
```
600 帧每帧一条，共 600 个 failure。

## 原因

`TestPattern.Content` 的数据字是 **28 位**（`TestPattern.dataBits = 28`、`dataMask = (1 << 28) - 1`），
构造器里 `self.hostTimeMs = hostTimeMs & TestPattern.dataMask`，所以烧进画面、解回来的是低 28 位。

`SyntheticSourceTests.swift:60` 原来是：

```swift
XCTAssertEqual(r.decoded.hostTimeMs, UInt32(truncatingIfNeeded: r.pts.nanoseconds / 1_000_000))
```

右边是完整 32 位，没有 `& TestPattern.dataMask`。两边差**正好 2^28 = 268435456**
（273101271 − 4665815 = 268435456），一掩就相等。

触发条件：`mach_absolute_time` 换算成毫秒 > 2^28 ms，即**机器连续唤醒（不含睡眠）约 3.107 天**之后。
本机当时 uptime 7.11 天、唤醒时间约 3.16 天，所以整片红；重启就好，所以之前的会话没撞上。

同一个包里 `NoiseBackgroundTests.swift:47` 是**写对的**：`XCTAssertEqual(d.hostTimeMs, (n * 16 + 1000) & TestPattern.dataMask)`。

## P3 做了什么

按胶水额度改了那一行（加 `& TestPattern.dataMask` 并写注释），`SwitcherTestKit` 胶水用量 3 行 / 50。
**没有改 `TestPattern`**（测试图案布局是契约，铁律 1 / 9），也没有放宽任何阈值——
断言的语义没变，只是补上"图案只有 28 位"这个本来就成立的前提。

## 留给 W1-A3 的两件事

1. **复核这条改法**：如果 W1-A 本意是"要验完整的 32 位毫秒"，那该改的是图案的字段宽度（= 契约变更，要写提案），
   而不是测试。P3 认为图案 28 位是有意设计（`/// 生成时刻的毫秒数，28 位`），所以改测试。
2. **frameprobe 的 `genTimeMs` 可能有同一个坑**：`Probe/ProbeTypes.swift:33` 把 `decoded.hostTimeMs` 原样当
   `genTimeMs` 用。如果哪个分析拿它做**跨帧相减**，一次长跑正好跨过 2^28 ms 的回绕点（唤醒 3.1 天、6.2 天……）
   就会算出一个 −2^28 的跳变。A/V 与 V4 的口径请顺手看一眼要不要按 28 位环形相减。

## 后续（2026-09-23，P3 收尾时）

- **W1-A3（w1-testkit-3）同一天独立踩到并修了同一行**，代码与 P3 的一样（`& TestPattern.dataMask`），只有注释不同。
  P3 把自己那三行改成与 W1-A3 **逐字相同**（提交里写了），检查点合并时两边是同一处改动，git 自动合掉——
  用 `git merge-tree` 试过：P3 → + w2-inputs-2 → + w1-testkit-3 依次合，全部无冲突。
- 上面"留给 W1-A3 的两件事"第 2 条（frameprobe 的 `genTimeMs`）查过了：`FrameAnalysis` 只在 A4 多文件对齐里把它当**事件键**用
  （容差内相等算同一事件），不拿它做跨帧相减，所以跨过 2^28 回绕点不会把同一事件拆开、也不会把两个事件并起来。**不用改**。
- 因此这张单子**可以关**；留着当记录。
