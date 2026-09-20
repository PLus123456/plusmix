## 56 W1-A3 frameprobe 认出转场合成帧 + Wipe / Zoom 的进度量法（测试工装续做）
分支：w1-testkit-3（从 G4 合入后的 main 开）。只准动：Packages/SwitcherTestKit/、Tools/frameprobe/、Tests/Fixtures/。
先读：reports/issues/G4-w1-testkit-frameprobe-wipe-zoom-progress.md；reports/w3-compositor2.md §3 第 4 条、§2 的 V7 量法；测试标准 §2.3、§3 V4 / V6 / V7；
scripts/gate4.sh 里 `--blank-ticks` 那段（G4 的临时做法）。

背景：G4 场景里 Wipe / Zoom / Stinger 与 Fade 轮流，frameprobe 对转场中间帧判不出输入身份（帧号行与 ID 块在不同拍翻转、混合色、CRC-4 有 1/16 概率放过错号），
G4 只能让 gate 从场景文件算出转场拍段交给 `frameprobe --blank-ticks` 当作解不出；V7 对 Wipe / Zoom 只有 W3-B 渲染侧的单元测试在判，L2 场景里量不了。

交付：
1. 解码自证：帧号行、时间戳行、ID 块三样互相印证（帧号与时间戳的生成时刻要吻合同一输入的节奏；任一 CRC 失败或 ID 距离超阈值就整帧 nil），
   Wipe 的半新半旧码字、Fade 的第三色误判都不再进 V4 / C3 的统计；`--blank-ticks` 保留但 gate4 默认不再需要它（跑一次 g4 场景对照：标记与不标记结果一致）。
2. `frameprobe wipe` / `frameprobe zoom`（或 `fade` 加 `--kind`）：Wipe 按方向找灰度阶跃位置（软边取 50% 点）算进度，Zoom 用中心行上新画面宽度算进度；
   输出与 `fade` 同形的曲线偏差报告；gate4.sh 接上（g4 场景里每种各取一次）。
3. Stinger：静态 PNG 的 Stinger 在 `switches` 里就是第 cutAtTick 拍的 Cut，加一个"透明区只有叠层"的判定说明即可。

测试（函数名带 ID）：
- `testV4_wipeCompositeFramesDoNotCountAsDrops`：合成一段 leftToRight / topToBottom 硬边 Wipe（frameprobe synth 加 `--wipe T:D:dir`），
  stats 的 drop / backward 为 0、undecodable = 转场中间帧数。
- `testV7_wipeProgressCurveWithinOneFrame`、`testV7_zoomProgressCurveWithinOneFrame`：合成文件上偏差 ≤ 1 帧（与 W3-B 渲染侧同口径）。
- `testC3_fadeBlendNeverDecodesAsThirdInput`：16 色两两 Fade 的合成块，nil 或两端之一，永不解成第三色。

报告 reports/w1-testkit-3.md：三样印证的漏判 / 误判率、g4 场景标记前后的对照。
