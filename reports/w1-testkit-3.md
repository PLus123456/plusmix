# W1-A3 报告：frameprobe 认出转场合成帧 + Wipe / Zoom 的进度量法

分支 `w1-testkit-3`（从 G4 合入后的 main `367bbb9` 开）。只动了 `Packages/SwitcherTestKit/`、`Tools/frameprobe/`、`Tests/Fixtures/`
（外加各分支都允许的 `reports/w1-testkit-3.md`、`reports/issues/`）。prompt 62；问题单 `reports/issues/G4-w1-testkit-frameprobe-wipe-zoom-progress.md`。

## 1 做了什么

### 1.1 解码自证（`SwitcherTestKit/Probe/PatternProbe.swift`、`SelfCheck.swift`）

frameprobe 以前只按契约 `TestPattern.decode` 读四样东西，值本身对不对没人管；转场合成帧的码字有 1/16 的概率
CRC 侥幸通过（问题单第 2 条），ID 块的混合色还可能正好落在第三种调色板色上。现在每帧多读三样证据，
连同底色和跨帧的节奏一共五条，任何一条不合就把**整帧**判成解不出（帧号 / ID / 时间戳置 nil，灰度保留）：

| # | 判据 | 抓的是什么 | 默认阈值 |
|---|---|---|---|
| 1 | 齐全：两行 CRC 都对 + ID 离调色板色 ≤ 阈值 | 契约本来就有的一关 | 契约 24；自证再收到 12（`--id-tolerance`） |
| 2 | 码字块纯度：64 个块都得是纯黑（16）/ 纯白（235） | Fade 中段、擦边压在码字行上的 Wipe —— CRC 的 1/16 漏网率在这里补上 | 离黑 / 白 ≤ 40 |
| 3 | ID 块四象限一致 | 擦边正扫过 ID 块的那几帧 | 两两距离 ≤ 12 |
| 4 | 底色一致：中心采样区 = ID 邻域条 = 该 ID 的标称灰度（众数） | Fade 混出第三色（调色板有五对颜色的中点正好是第三色，光看颜色躲不开）、Zoom 盖住中心 | 差 ≤ 5 级（`--self-check-gray-tolerance`） |
| 5 | 节奏：(帧号, 时间戳) 落在该输入自己的直线上 | "旧 ID + 新帧号"（擦边先扫过码字行、后扫过 ID 块） | 残差 ≤ 3 ms（`--rhythm-tolerance-ms`） |

另有一项**只报不判**：时间轴（时间戳 − 1000 × pts 对 pts 线性拟合后的残差，> 250 ms 计数）。冻结的输入会在这里露头，
但那正是 V4 要报的重复帧，判掉反而把真问题藏了。

闪光位单独处理：闪光块**自己**是纯黑 / 纯白就保留（两路合成源共用 t0 时常常同时闪），A2 的配对不因为转场丢掉。

`--no-self-check` 回到老口径；`--blank-ticks` 原样保留（两种口径下都还在），gate4 默认不再需要它（§2.2 的对照）。

### 1.2 Wipe / Zoom 的进度量法（`Probe/ScanProfile.swift`、`Probe/TransitionCurve.swift`）

新子命令 `frameprobe wipe --at S --duration D [--wipe-direction …]` 和 `frameprobe zoom --at S --duration D`，
输出与 `fade` 同形的曲线偏差报告（逐拍 progress / 期望 / 偏差帧数 / 最大偏差 / 单调 / passV7）。

- 只对 [S, S + D] 这 D + 1 帧算灰度剖面（`ScanProfile`：每列在 ID 块下缘以下的平均灰度、每行在码字行右侧的平均灰度、
  每列在中心行带上的平均灰度），全片每帧都算会让 10 分钟的文件慢一倍。
- 每一拍的剖面先用转场两端的两帧归一化：**ν = (这一拍 − 第 S 拍) / (第 S + D 拍 − 第 S 拍)**。
  不用知道两路的标称灰度；压在取样带上的叠加（PiP、边框）在分子分母里各出现一次，自动约掉。
- Wipe：沿擦除方向找 ν 从 1 掉到 0 的那条边，判据用**最大似然的阶跃位置**（让 Σ_左(2ν − 1) 最大的切点），
  再在那一格里线性插到 50% 点。软边（`1 − smoothstep(e − s/2, e + s/2, f)`）在 f = e 处正好 0.5，所以 50% 点就是擦边位置，
  与软边宽度无关。对角方向按取样窗口里的覆盖面积二分反推。
- Zoom：中心行带上新画面的宽度 / 画面宽。左右两条边各在自己那半边找；某条边落在被 PiP 盖住的一段里（两侧可用取样点相隔 > 8 px）
  就只用另一条边按"居中"翻倍（g4 第 9600 拍那次 Zoom 的左边界从第 12 拍起就压在 Overlay 3 下面）。

配套：`SampleMovieWriter` 加了 `.wipe(tick:durationTicks:direction:softness:)` / `.zoom(tick:durationTicks:)` 两种事件
（NV12 上的 CPU 合成，遮罩公式与 `Compositor.metal` 的 `wipeAlpha` 逐字一致），CLI 是 `synth --wipe T:D:dir[:softness]` / `--zoom T:D`。

### 1.3 Stinger 的判定说明

静态 PNG 的 Stinger 在 `switches` 里就是**第 cutAtTick 拍的一次 Cut**（g4 实测：第 9900 拍发 Stinger、cutAtTick = 12
→ `switches` 第 9912 拍一条 `cut`，`cleanCut` 为真）。判据写进了 `FrameAnalysis.switches` 的文档：
叠层在**解码区**（帧号行、时间戳行、ID 块、中心采样区、ID 邻域条）上必须是透明的——G4Factory 的 PNG 就是按这个画的
（只占下 20% 与左右两侧）。叠层盖住解码区的话那几帧会被自证判成解不出，`switches` 里就变成一次 `betweenFrames > 0` 的 transition。
动画 stinger（文件输入）落地后再看。

## 2 测试

各项在 `Packages/SwitcherTestKit/Tests/SwitcherTestKitTests/TransitionProbeTests.swift`；素材是当场合成的 720p60 H.264
（2.5 s，A = ID 0 灰 64 60 fps，B = ID 1 灰 192 30 fps，第 60 拍起 24 拍转场）。

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testV4_wipeCompositeFramesDoNotCountAsDrops` | leftToRight / topToBottom 硬边各一段：两路 **丢弃 0、倒退 0**；解不出 14 帧（第 61–74 拍），与解码区被擦边切开的拍逐个对上 | 丢弃 / 倒退 = 0 | ✅ |
| `testV7_wipeProgressCurveWithinOneFrame` | 四个直线方向 × 软边 0 / 0.1：最大偏差（左→右 / 右→左 / 上→下 / 下→上，各硬边 / 软边 0.1）0.006 / 0.013、0.006 / 0.012、0.000 / 0.014、0.000 / 0.015 帧，全部单调 | ≤ 1 帧 | ✅ |
| `testV7_zoomProgressCurveWithinOneFrame` | 最大偏差 0.013 帧，单调 | ≤ 1 帧 | ✅ |
| `testC3_fadeBlendNeverDecodesAsThirdInput` | 16 色两两（120 对）× 19 个混合比例 × 两种情形（异码字 / 同码字）= 4320 个混合帧，**解成第三路 0 个**；两端的纯色帧一帧没误杀 | 0 次 | ✅ |
| `testV4_mismatchedIdAndFrameNumberIsRejectedByRhythm` | 合成 4 帧"旧 ID + 新帧号"，全部按 rhythm 判掉，其余 32 帧不误杀 | 4 / 4 | ✅ |
| `testW1A3_patternProbeMatchesContractDecode` | 自证读数与契约 `TestPattern.decode` 在纯帧上逐字段相同（3 个 ID × 3 组帧号）；纯帧的块纯度 ≤ 0.01、四象限 ≤ 0.01、ID 距离 ≤ 1.5 | 逐字段相等 | ✅ |
| `FixtureSnapshotTests`（重录） | 见 §2.1 | — | ✅ |

全量：`swift test --package-path Packages/SwitcherTestKit` **68 个用例 0 失败**（419 s，机器上同时有别的会话在跑测试）；
`make lint`（禁词 / 版本号 / Package.swift 约束 + 依赖方向 + 目录归属 + 实时符号审计）四项全过，归属检查 16 个文件都在允许范围内。

### 2.1 回归样例快照重录（`Tests/Fixtures/w1a-sample-20s.expected.json`）

样例 `.mov` 没动，只重录快照（`W1A_RECORD_SNAPSHOT=1`），差别全在第 700 拍那次 Fade 的中间帧，明细写进了
`Tests/Fixtures/README.md`：帧号读不出 1 → 27，ID 读不出 25 → 27，输入 0 的帧 872 → 871、输入 1 的 303 → 302，
Fade 那次切换的中间帧 25 → 27、新 ID 出现的帧 728 → 729。**闪光 / click / 配上仍然是 20 / 20 / 20**（闪光块纯白时保留闪光位）。
老快照里第 702–714 帧被算成"输入 1 的第 351…357 帧"、716–729 帧被算成"输入 0 的第 716…729 帧"——正是要清掉的那类合成帧。

### 2.2 g4 场景对照（自证 vs `--blank-ticks`）

L2 的 g4 节目 / 场景跑 175 s（10500 拍，转场 13 次：Cut 3、Fade 3、Wipe 2、Zoom 2、Stinger 2、T-bar 1；
`switcher-headless run --show scenarios/g4-show.json --script scenarios/g4.json --duration 175 --record`，
录制 10500 帧、编码 skipped 0）。同一个文件四种口径：

| 口径 | 总帧 | V5 差 | 帧号读不出 | ID 读不出 | 各路帧数（ID 0,1,2,3,6,7） | 丢弃 | **倒退** | 干净 Cut（V6） |
|---|---|---|---|---|---|---|---|---|
| A 老口径 `--no-self-check --blank-ticks` | 10500 | 0 | 249 | 973 | 2149,5974,576,276,276,276 | 0 | 0 | ✅ 3 条 |
| B **自证，不标记** | 10500 | 0 | 909 | 909 | 2160,5987,588,288,281,287 | 0 | 0 | ✅ 4 条 |
| C 自证 + 标记 | 10500 | 0 | 975 | 975 | 2148,5973,576,276,276,276 | 0 | 0 | ✅ |
| D 两样都不开 | 10500 | 0 | 65 | 832 | 2163,5990,617,288,285,321 | 0 | **1** ❌ | ✅ |

- **D 那一次帧号倒退就是问题单说的"迟早会撞上"**：175 s 13 次转场就撞上了一次（ID 2，Wipe 的半新半旧码字 CRC 侥幸通过）。
  自证（B）和标记（A）都没有。这是这次改动最直接的证据。
- **判定一致**：V4（丢弃 / 倒退 / 设计外比例）、V5（总帧数差 0）、V6（`allCutsClean` 为真）在 A / B / C 三种口径下结论相同。
  数值上 B 比 A 多认出 11–13 帧 / 路：Wipe 走到 progress ≥ 0.625 之后解码区（码字行、ID 块、中心采样区、ID 邻域）整幅都是新画面，
  自证认它是新输入的帧，而 `--blank-ticks` 把整段都抹掉。这些帧的帧号与新输入的序列连着，不产生缺口。
- **B 比 A 多一条 Cut**：第 9912 拍那次 Stinger 的换底（cutAtTick = 12）。`--blank-ticks` 把 Stinger 整段抹掉，这条 Cut 就没了；
  自证保留了它（判据见 §1.3）。
- **A2 也一致**：`frameprobe av` 两种口径下整秒配对都是 **149 对、均值 0.000 ms、最大 0.000 ms、A2 ✅**；
  自证口径多留了 3 个闪光（173 → 176，配上 172 → 175），全部落在非整秒（23 → 26，只报不判）——
  转场中间帧的闪光块本身是纯黑 / 纯白时闪光位保留，多出来的就是这几个。
- 自证判掉的 909 帧按理由：`incomplete` 845、`background` 58、`blend` 6、`rhythm` 0、`unanchored` 0。
  逐拍核对：**每一帧要么落在转场中间拍里，要么落在第 8412–9015 拍**——后者是 5、6 号在播的那一段，
  它们的 ID 块被抠像的溢色抑制改了色（见 §3 和 `reports/issues/W1A3-g4-keyer-spill-breaks-pattern-id.md`），两种口径下都解不出。
- 每路的节奏拟合（自证顺带给的）对得很准：ID 0 = 33.3333 ms/帧（30 fps）、ID 1 / 6 / 7 = 16.6667（60 fps）、
  ID 2 / 3 = 16.6833（59.94），**最大残差 0.33–0.50 ms**（阈值 3 ms），时间轴离群 0 帧。

### 2.3 漏判 / 误判率（同一个 g4 录像，逐帧核对）

**误判（好帧被判成解不出）：0**。10500 帧里判掉 909 帧，逐拍核对下来只有两类：
转场窗口里的帧（含 T-bar 命令拍 3600），和第 8412–9015 拍那 578 帧（5、6 号的 ID 块被抠像溢色抑制改了色，两种口径下都解不出，§3 与问题单）。
窗口之外、8412–9015 之外，一帧都没有。C3 用例里 4800 个纯色帧也一个没误杀。

**漏判（合成帧仍被算成某一路）：359 个真合成帧里 28 个（7.8%）**，分布如下：

| 转场 | 中间帧 | 仍解出输入 | 是什么 |
|---|---|---|---|
| Fade @3000（30 拍） | 29 | 2 | 混合比例 < 0.18 的头尾两帧（画面 ≥ 82% 是那一路） |
| Fade @7500 / @9000（24 拍） | 23 / 23 | 0 / 4 | 同上 |
| Wipe @7800 / @9300（24 拍） | 23 / 23 | 9 / 9 | progress ≥ 0.625 之后，解码区整幅都是新画面 |
| Zoom @8100 / @9600（24 拍） | 23 / 23 | 2 / 1 | 头一两帧，新画面还只是中心一小块 |
| T-bar 3600–3780（按住 25 / 50 / 75%） | 180 | 1 | 命令拍 3600 |
| Stinger @8400 / @9900（24 拍） | 23 / 23 | 11 / 23 | **不算漏判**：叠层只盖画面一部分，底下就是一路输入，第 cutAtTick 拍换底（§1.3） |

这 28 帧全部落在两端之一（从没解成第三路），帧号与那一路的序列连着，所以 V4 的丢弃 / 倒退仍是 0，
C3 也不算不一致（转场进行中 `tally.program` 同时含 PGM 与 PVW 两路，契约 `MixerState.tally(ofInput:)`）。

### 2.4 L2 场景里的 V7（问题单第 1 条，原来量不了）

| 转场 | 量到的最大偏差 | 阈值 | 通过 |
|---|---|---|---|
| 第 7800 拍 Wipe leftToRight 软边 0.1（24 拍） | 0.044 帧 | ≤ 1 帧 | ✅ |
| 第 9300 拍 Wipe leftToRight 软边 0.1（24 拍） | 0.213 帧 | ≤ 1 帧 | ✅ |
| 第 8100 拍 Zoom（24 拍） | 0.002 帧 | ≤ 1 帧 | ✅ |
| 第 9600 拍 Zoom（24 拍） | 0.000 帧 | ≤ 1 帧 | ✅ |

四次都是 23 个样本（第 S + 1 … S + D − 1 拍每拍一个）、单调。与 W3-B 渲染侧同口径（第 s + k 拍 progress = k / D，偏差换算成帧）。

## 3 没做的和原因

1. **gate4.sh 没接**（prompt 第 2 条的最后半句）。`scripts/` 不在本会话的"只准动"里（docs/OWNERSHIP.md 第 46 行只给了
   `Packages/SwitcherTestKit/` `Tools/frameprobe/` `Tests/Fixtures/`），铁律 1 不许越界。要接的三处写在这里，G5（或任何拿 `scripts/` 的会话）照抄即可：
   ```bash
   # 1) 去掉 stats / switches / frames / av 的 bt=(--blank-ticks …)：自证默认开，不再需要（对照见 §2.5）
   #    想留一手的话保留变量、只在 --waive 时才带上
   # 2) V7 补两条（场景文件里第一次 Wipe / Zoom 的拍号与时长，python 那段已经在算转场窗口了）
   "$frameprobe" wipe "$movie" --at "$wipe_tick" --duration "$wipe_d" --wipe-direction leftToRight --fps "$program_fps" \
       --out "$out_dir/probe-wipe.json" --markdown > "$out_dir/probe-wipe.md"
   "$frameprobe" zoom "$movie" --at "$zoom_tick" --duration "$zoom_d" --fps "$program_fps" \
       --out "$out_dir/probe-zoom.json" --markdown > "$out_dir/probe-zoom.md"
   # 3) gate3-report.py 的 V7 行读 probe-wipe.json / probe-zoom.json 的 curve.passV7、curve.maxDeviationFrames
   #    （与 probe-fade.json 的 fade.allPassV7 / maxDeviationFrames 同形）
   ```
2. **对角 Wipe 只有面积反推，没有实测样例**。g4 用的是 leftToRight，四个直线方向都有用例；对角按取样窗口里的覆盖面积二分反推
   （渲染侧 W3-B 也是这么判的），本会话没合成对角素材跑一遍。要补的话 `synth --wipe T:D:diagonal` 已经能生成。
3. **动画 Stinger（文件输入）没量**。静态 PNG 的判定说明见 §1.3；动画 stinger 落地后 `switches` 里会是什么样还没定义。
4. **10 分钟全长对照没跑**。跑的是 175 s（10500 拍，13 次转场），覆盖了 Wipe / Zoom / Stinger / Fade / T-bar 各至少两次。
   跑全长 10 分钟（36000 拍、76 次转场）要 10 分钟 + 9 次 frameprobe（每次 ~1 分钟），留给 G5 的正式跑。

## 4 对契约的疑问（**用户 2026-09-23 三条全批，已写进测试标准 §2.1**）

三条都是口径不是阈值，落点在 `docs/spec/导播台测试标准.md` §2.1 新增的两条："输入 ID 的解码阈值与它的边界"（第 1、2 条）和"解码区与它的保护带"（第 3 条）。`docs/OWNERSHIP.md` 的 W1-A3 行同时记下这次授权（本会话原本没有 docs/spec 与本文件的归属，不记 check-ownership 会红）。

原文留档：

1. **调色板的五对中点撞色**（不是要改，是要记下来）：`TestPattern.palette` 里 0 + 2 = 8、1 + 2 = 15、7 + 9 = 15、2 + 3 = 7、0 + 9 = 11
   的中点与第三种颜色的距离 < 0.4（全在 t ≈ 0.5），两两之间的最小距离 56.6 一点也帮不上忙。
   所以"混合色不许解成第三路"（C3 硬性）不可能只靠颜色判据达成，必须靠底色 + 码字块纯度这两票。
   这条现在写在 `SelfCheck` 的文档里；要不要在契约的 `TestPattern` 注释里也点一句，请裁定（**不需要改代码**）。
2. **ID 块的判据阈值**：契约 `paletteIndex(nearestTo:)` 是"离最近色 ≤ 24（最小距离的一半）"，自证再收到 12。
   收紧的理由：第三色能被读出来的混合比例从 [0.29, 0.71] 收到 [0.39, 0.61]，两侧都落在底色与纯度两条判据之内。
   实测纯帧的 ID 距离 ≤ 1.5（H.264 720p 4 Mbps）、g4 录像上也远小于 12，没有误杀。这是 frameprobe 侧的阈值，**没动契约**。
3. **ID 邻域条这块背景**：自证新用了一块以前没人用的区域（ID 块正下方，1080p 上 x ∈ [16, 272]、y ∈ [192, 224]，
   即 0.178–0.207 倍高）。测试图案的规格只说"其余画面是底色"，没说这块归谁；g4 的叠加与 Stinger PNG 正好都避开了它
   （PNG 的左立柱从 0.22 倍高起，余量 14 px）。要不要把"图案区以下、0.22 倍高以上这条横带不许被叠加占用"写进测试标准 §2.1，请裁定。

## 5 下一个会话要知道的坑

1. **自证默认开**。老口径用 `--no-self-check`。跑 gate 时如果某路的帧数突然掉一大截，先看 `stats` 输出里的
   `selfCheck.byReason` 和 `fits`（每路的每帧 ms / 最大残差 / 标称灰度 / 判掉数），一眼能看出是"真的解不出"还是"阈值卡太紧"。
2. **抠像的溢色抑制会改 ID 块的颜色**：g4 的 5、6 号（调色板 4 品红 / 5 金，红分量最高）在播时 ID 块被拉成 (180, 18, 249)，
   离标称色 40 > 契约阈值 24，两种口径下都解不出 → 这两路对 V4 / C3 零覆盖。问题单
   `reports/issues/W1A3-g4-keyer-spill-breaks-pattern-id.md`，改一行 `patternID` 就能绕开（G4Factory，属检查点会话）。
3. **PiP 压在取样带上会把 Wipe / Zoom 的边量偏**：两端归一化能约掉叠加，但叠加占掉大半个取样带的那几列，ν 的噪声被放大
   （g4 第 9300 拍那次 Wipe 的第 270 列，对比度只剩 8.7，实测偏差 19.7 帧）。现在的做法是对比度门限跟着中位数走
   （`max(8, 0.35 × 中位对比度)`）+ 最大似然阶跃位置；Zoom 的边落在被盖住的一段里就只用另一条边翻倍。
   再加叠加时先看 `curve.samples[].usable`（参与判定的列 / 行数），掉得厉害就说明取样带被占了。
4. **`--blank-ticks` 会把 Stinger 的那次 Cut 一起抹掉**（§2.2），所以别再默认带它。
5. **frameprobe 的一次全片扫描现在贵一点**：每帧多读 ID 块四象限 + ID 邻域条（1080p 约 +6% 采样量），
   10500 帧的文件一次 `stats` 约 1 分钟（release，M5 Max，机器上还有别的会话在跑测试）。灰度剖面只对 `--at`/`--duration`
   圈出来的那 D + 1 帧算，不影响全片扫描。
6. **`testC3_fadeBlendNeverDecodesAsThirdInput` 要跑 ~2 分钟**（120 对 × 2 情形 × 19 个比例，每帧要画两幅再混一次）。
   debug 下最慢的一个用例，`swift test --filter TransitionProbeTests` 时心里有数。
7. **两路输入的 t0 / 帧率 / 漂移完全一样时，节奏那一票判不出来**（headless 里所有合成源共用 videoT0，例如 g4 的 3、4 号都是 59.94 无漂移）。
   那种情况下两路的帧号本来就一样，V4 不受影响；但如果将来要靠节奏区分同款两路，得给它们不同的 t0。

## 6 顺手修的一处老问题（本会话目录内）

`SyntheticSourceTests.testW1A_syntheticVideo_60fps10s_continuousMonotonic_pushed600` 第 60 行把图案里的时间戳
与 `UInt32(truncatingIfNeeded: pts.ns / 1e6)` 比，没有按契约掩到 28 位。host time 从开机起算，**开机超过 2²⁸ ms（3.1 天）**
之后两边就差一个 2²⁸（本机开机 7 天，600 帧全红：1205118 vs 269640574）。这与本次改动无关，
是"测试写得不对 + 机器开机够久"才现形的老问题，已按契约加上 `& TestPattern.dataMask`，8 个用例全绿。
