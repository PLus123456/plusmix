# 006 TestPattern.Background 加噪声底纹（让 E2 在 L2 长跑里可判）

提出会话 / 分支：G3 / g3（检查点；问题单 reports/issues/G3-w1-testkit-synthetic-noise-for-E2.md）
状态：待批

## 改什么

`TestPattern.Background`（TestPattern.swift；Show 文件里合成源的 `background` 字段）现在只有：

```swift
case gray(level: UInt8)
case gradient
```

提议加一个 case：

```swift
/// 灰底 level 上叠零均值噪声（±amplitude，确定性伪随机，seed 决定序列）；帧号 / 时间戳 / 输入 ID / 闪光块区域不加噪声。
case noise(level: UInt8, amplitude: UInt8, seed: UInt64)
```

Codable 形态与现有 case 一致（`{"noise": {"level": 128, "amplitude": 24, "seed": 7}}`）；CPU 参考实现（BGRA 与 NV12 亮度平面）在 `TestPattern` 里，解码规则不变。

## 为什么

- G3 的 10 分钟 L2 运行里 E2（码率遵从）量不出：灰底合成源整段只压出 0.101 Mbps（设定 6 Mbps），VideoToolbox 不会往目标码率填充，
  "误差 98.9%"没有可判的对象；gate3-report 只能标"本场景不适用"、以 W1-E / W2-D 的专项用例（它们用 `PatternFeeder.Texture.noise`，不是合成源）为准。
- 测试标准 §3 的 E2 做法是"录制文件或 MediaMTX 落盘文件用 ffprobe 算"，长稳（S1，W4-A）里也该有 E2；长稳用的是合成源，所以底纹要进合成源的设置，也就是契约里的 `Background`。
- 零均值噪声不改中心区域的灰度均值，V6 / V7（frameprobe 按中心 1/4 区域均值判混合）不受影响；块区域不加噪声，帧号 / ID / 闪光判读不受影响。

## 影响谁

- `TestPattern.swift`（加 case + CPU 参考实现）、`SwitcherContractsTests`（Codable 往返、解码正确性）；
- W1-A2（prompt 44）：`SyntheticVideoInput` 按 settings 画噪声（GPU 或 CPU，成本写报告）；
- G4：`G3Factory` / 后续场景把 8 路改成噪声底纹（振幅 24，与 W2-D 一致），gate 报告去掉 E2 的"不适用"分支；M0 场景不动（G2 基线可比）。

## 怎么迁移

- Show 文件：加 case 不影响老文件（老文件只有 gray / gradient）；schemaVersion 不动。
- 不批的话：E2 继续只由 W1-E / W2-D 的专项用例判，L2 / 长稳报告里 E2 一栏永远"不适用"。
