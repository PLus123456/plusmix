# testW1A_syntheticVideo_jitterIsUniformWithinBound 的 |mean| < 0.8 ms 在本机常红（3 次里 2–3 次）

发现会话 / 分支：P3 / p3-contracts（2026-09-23 跑 `make test` 时）
归属：W1-A（`Packages/SwitcherTestKit/Tests/`）→ 续做会话 **W1-A3 / prompt 62 / 分支 w1-testkit-3**
严重度：中（挡住 `make test` 绿；不是产品缺陷）

## 现象

```
SyntheticSourceTests.swift:105: error: -[SwitcherTestKitTests.SyntheticSourceTests
  testW1A_syntheticVideo_jitterIsUniformWithinBound] : XCTAssertLessThan failed:
  ("0.8480776999999994") is not less than ("0.8")
```

## 确认与 P3 无关

在 **main（367bbb9）** 的干净工作树上跑同一个用例：**3 次 3 次都红**，数值同一量级。
P3 没有动 `SwitcherTestKit/Sources/.../Synthetic/`、`TestPattern`、`Time.swift`，也没有动这个测试文件里的这一条。
在 p3-contracts 上 3 次 2 红 1 绿，只是这条本来就压在线上、随负载摆动。

## 分析

断言是"±3 ms 均匀抖动的均值应接近 0"：

```swift
XCTAssertLessThan(abs(mean), 0.8)
```

`mean` 量的是 `ingress − pts`，里面除了零均值的抖动还有一项**系统性的画帧 + 交付开销**。
同文件 1080p 那条用例打印的是 `ingress − pts 平均 2.172 ms`（没配抖动），说明这项开销真实存在；
640×360 便宜些，实测落在 0.8–0.9 ms，正好压在 0.8 的线上。

样本数 ~180、均匀 ±3 ms 的均值标准误 ≈ 1.73 / √180 ≈ 0.13 ms，所以 0.85 不是噪声，是**偏置 + 噪声**。

## 为什么 P3 没有自己改

**阈值只有用户能改（铁律 9）**：0.8 是这条用例的判据，不是 P3 的东西，也不是"写错了的断言"
（与隔壁 hostTimeMs 那条不同，那条是漏掉了一个本来就成立的掩码，见
`reports/issues/P3-w1-testkit-hosttimems-28bit-mask.md`）。P3 只记录，不动。

## 给 W1-A3 / 用户的两个方向（请拍板）

1. **把偏置扣掉再判**：先跑一遍同配置但 `jitterMs: 0` 的基准，拿它的 mean 当零点，判
   `abs(mean − baselineMean) < 0.8`。这样量的才是"抖动是否零均值"，与机器快慢无关——**P3 倾向这个**。
2. **放宽到 1.0–1.2 ms**：改的是阈值，要用户点头；而且换台慢机器还会再红。

另：这条用例本身的目的（抖动是均匀分布、范围与标准差对、pts 不跟着抖）由同一函数里的另外三条断言
（min ≥ −3、max ≤ 6、std ≈ 1.73 ± 0.4、pts 严格等于拍点）覆盖着，这四条在两个分支上都是绿的。
