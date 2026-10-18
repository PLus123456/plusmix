# W1-A6 frameprobe 转场拍号按 PTS（Codex T02）+ A4 判定事件缺 click 算不过：报告（分支 w1-testkit-6）

日期 2026-10-18。机器 Apple M5 Max 128 GB，macOS 27.0.1（26A434），Xcode 27.1（27A9275）/ Swift 6.4，接电源；同机另有 115 / 118 / 119 三个会话在跑（load 1.2–3.6）。
worktree `.claude/worktrees/agent-ade2e54e4331eb86f`，分支 `worktree-agent-ade2e54e4331eb86f`，**别名 `w1-testkit-6` 指向同一个提交**（prompt 121 的分支名；
`make lint BRANCH=w1-testkit-6` 按它查 OWNERSHIP），从 main `358517f`（G9 合入后）开。提交：`git log main..w1-testkit-6`
（T02 70c2eab → A4 81c4028 → 问题单 + 本报告）。只动了 `Packages/SwitcherTestKit/`（Probe 下 FrameAnalysis / TransitionCurve / FrameProbe / SelfCheck、
Fixture/SampleMovieWriter、两个测试文件）、`Tools/frameprobe/`（用法文字）、一张问题单和本报告；没碰契约、`scripts/`、`Tests/Fixtures/`（快照不用重录）。

**一句话**：switches / fade 的拍号从"startTick + 数组下标"改成"startTick + round((pts − 第一帧 pts) × fps)"（与 `av` 同一个式子，拍号来源不改），
漏帧单独列（`missingFrames` + `missingFrameCount`）；**拍号用的 fps 不能用容器的 nominalFrameRate**——探针量出它是"样本数 / 时长"，漏了帧就偏低，
而 gate4 的 switches / fade 不带 `--fps`，所以没给 `--fps` 时按相邻帧 pts 差估。A4：判定事件里有文件在锚 ±0.5 s 内没有 click → `passA4 = false`，事件列出缺的文件。
G8 / G9 产物用 release frameprobe 重算：**V6 第 1000 拍 Cut、150 条切换逐字段不变；V7 Fade 0.252 / Wipe 0.042（G8 0.048）/ Zoom 0.003 帧不变；A4 0.1875 ms、passA4 true**。

---

## 1. 做了什么

### 1.1 先复现（红）

- 纯函数用例按"真文件的样子"造帧：漏掉的拍不进数组，`index` 是文件里的序号（漏帧之后比拍号小，MediaReader 就是这么编号的）。
  老代码跑：**5 个用例红 20 处**——第 60 拍的 Cut 报 58（`startTick 1000` 时 1058、Cut 前一拍也漏时 57）；36000 帧第 30000 拍的 Cut 报 29998；
  30 拍 Fade 前漏两帧判 **2.0 帧**偏差（Codex 原话的数）、窗口里再漏一帧 3.0 帧、自动模式 D = 29 / 偏差 0.633；A4 缺 click 时 `passA4` 两处仍 true。
- 真文件：`SampleMovieWriter.Spec.droppedTicks`（新增，默认空、不改别的行为）用 VideoToolbox 写 720p 3 s、漏第 20 / 30 拍、第 100 拍 Cut、第 130 拍 Fade 30。
  老代码：Cut 报第 **98** 拍、Fade 偏差 **2.3125 帧**（> 1 帧，V7 红）。
- SelfCheck 报告里判掉的帧的"拍"也是 startTick + 序号（只进 markdown）：漏一帧之后列成 15–18，应是 16–19。

### 1.2 探针：nominalFrameRate 是"样本数 / 时长"（铁律 10）

scratchpad `fpsprobe/main.swift`（30 行）：AVAssetWriter 写 60 fps H.264、timescale 60000（与 Recorder 同口径：PTS = 拍点），跳过若干拍不写，读回 track：

| 文件 | nominalFrameRate | minFrameDuration | 时长 |
|---|---|---|---|
| 3600 帧全写 | 60.0 | 1/60 | 60.0 s |
| 漏第 20 / 30 拍（3598 帧） | **59.966667** | 1/60 | 60.0 s |
| 漏第 1000–1059 拍（3540 帧） | **59.0** | 1/60 | 60.0 s |
| 1.1 的真文件（178 帧 / 3 s） | **59.333** | — | 3.0 s |

结论：拿它乘 pts 等于把漏帧摊到整个文件上（600 s 文件漏 2 帧，第 30000 拍处差 2 拍——用例里钉着）；minFrameDuration 对我们的录像是准的，
但推流落盘的毫秒时间戳（16 / 17 ms 交替）上它是 16 ms → 62.5 fps，也不能用。`l.fps` 在没给 `--fps` 时就是 nominalFrameRate，
gate4.sh 的 `switches` / `fade` 两步恰好不带 `--fps`（其余几步都带）——只把下标换成 `pts × l.fps` 在 gate 里等于没修。

### 1.3 T02：转场落点按 pts 换算的节目拍号，漏帧单独报（70c2eab）

- `FrameAnalysis.programTick` / `programTicks`：tick = startTick + round((pts − 第一帧 pts) × fps)，`av` 的闪光拍号改成调它（同一个式子，行为不变），
  switches / fade 用它判落点。**拍号来源（第一帧 = 第 startTick 拍、帧距均匀）不改**（W1B4 问题单）。
- `FrameAnalysis.programFps`：相邻帧 pts 差里 < 1.5 × 中位数的那些求平均再取倒数（漏帧留下的 2 帧、3 帧空档不进平均）；60 fps 漏 2 帧 → 60（1e-9 内）、
  59.94 → 60000/1001、毫秒时间戳 → 60（1e-3 内）。switches / fade（及 SelfCheck 的报告拍号）：**给了 `--fps` 用给的，没给用它**，不用 `l.fps`。
- `switches`：tick 按 pts；前后帧、中间帧数按数组位置（原来拿 `f.index ± 1` 当数组下标，隐含"序号 = 位置"）；`Switch.missingBetween` = 旧输入最后一帧与新输入第一帧之间漏的拍
  （没漏为 nil；Cut 前一拍漏了时落点只能确定在 (上一帧, tick] 里——标出来，不改 tick 与 cleanCut）；`SwitchesReport.fps / missingFrames（maxEvents 截断）/ missingFrameCount`。
- `fade`：指定模式按拍号找第 s + k 拍那一帧（原来是下标 s + k），第 s 拍漏了方向取它前面最近的一帧，第 s + D 拍漏了取后面最近的；
  自动模式 k = 拍号 − s（s = 第一个混合帧的拍号 − 1）、D = 末拍 − 首拍 + 2（没漏帧时 = 混合帧数 + 1，与改前相同）；漏掉的拍没有样本、不占 k。
  `Fade.missingFrames / missingFrameCount`（指定模式窗口 [s, s + D]，自动模式是混合段前后两个纯色帧之间），`FadeReport.fps / missingFrames / missingFrameCount`（整个文件）。
  顺带：老代码 `--fade-at` 落在第一帧前一拍时 `frames[-1]` 会崩，现在不出 Fade。
- Wipe / Zoom：拍号本来就按 pts（W1-A3，`round(pts × fps)`，与剖面窗口、`--blank-ticks` 同式），只补 `TransitionCurve.missingFrames / missingFrameCount`（窗口 [s, s + D]），
  note 里写"窗口里漏了 n 拍：…"。
- SelfCheck：`Rejection.tick` 改按 pts（`apply` 多一个 `fps` 参数，nil = 按 pts 差估）；只进报告，不影响判定。
- FrameProbe / CLI：switches / fade 传 `options.fps`（不是 `l.fps`）与 `maxEvents`；markdown 写拍号口径（帧率、漏帧拍号），switches 表多一列"中间漏拍"，
  Fade / 曲线行末写窗口里的漏帧；`frameprobe` 用法里写清两组拍号式子与 `--fps` 的取法（wipe / zoom 没给 `--fps` 仍用标称帧率，漏了帧的文件要给）。
- 兼容：新字段全是可选的，**没漏帧时输出与改前逐字段相同**（`Switch.missingBetween` 没漏时是 nil 而不是 0，否则快照里整条 `Switch` 比较会红）——
  `Tests/Fixtures/w1a-sample-20s.expected.json` 照常解码、两条快照用例照过，没重录；G8 / G9 重算逐字段相同（§1.5）。

### 1.4 A4：判定事件里有文件缺 click 算不过（81c4028）

- 用户 2026-10-17 对 113 §4 ③ 的裁定（测试标准 §2.3 G9 补的那条）：`MultiFileEvent.missingClickFiles` = 有这个事件的闪光、但锚 ±0.5 s（`maxMatchSeconds`）内没有 click 的文件序号；
  那一格 `clickTimes` 照旧 nil、`clickSpreadMs` 照旧只在剩下的文件里算——**`maxClickSpreadMs` / `maxFlashSpreadMs` / `passA4` 字段名不变，极差数字的口径也不变**。
- 判定事件（非半秒）里有缺的 → `passA4 = false`，`MultiFileAVReport.missingClickEventCount` 计数；半秒事件里缺的照样列在 `missingClickFiles`、不判；±1 帧半秒带宽不变。
- **没有锚的事件**（一个文件都没配上 click）不算"缺 click"、只比闪光，另计 `unanchoredEventCount`（理由与要用户确认的见 §4 第 2 条）。
- note 写"n 个判定事件里有文件在锚 ±0.5 s 内没有 click…A4 不过：#5 缺 [2]…"、没有锚的个数；markdown 表多一列"缺 click"，末行写判定事件里缺 click 的个数与没有锚的个数。

### 1.5 用 G8 / G9 的产物重算（交付 1 末句、交付 2）

g8 worktree 的 `.build/gate4/g8/`、`.build/gate4/g9/` 只读；本分支 `swift build -c release --package-path Tools/frameprobe`，参数与 gate4.sh 那几步相同
（switches / fade 不带 `--fps`；wipe `--at 7800 --duration 24 --wipe-direction leftToRight --fps 60`；zoom `--at 8100 --duration 24 --fps 60`；
av 五个文件 `--fps 60`），输出只进 scratchpad `recompute/`。耗时：单文件四步 G8 127 s / G9 135 s，五文件 av G8 172 s / G9 179 s。

| | G8 原产物 | G8 重算 | G9 原产物 | G9 重算 |
|---|---|---|---|---|
| V6 第 1000 拍 | Cut，文件第 1000 帧，干净 | 同左 | 同左 | 同左 |
| V6 150 条切换（index / tick / pts / from / to / 中间帧 / 混合 / cleanCut） | — | 与原产物 **0 处不同** | — | **0 处不同** |
| V6 Cut 90 次、全部干净 | ✅ | ✅ | ✅ | ✅ |
| 拍号帧率 / 漏帧 | — | 60（pts 估）/ **0 拍** | — | 60 / **0 拍** |
| V7 Fade @3000（29 样本，第 3001 拍起，B→A） | 0.252311 帧 | 0.252311（样本逐个相同） | 0.252311 | 0.252311 |
| V7 Wipe @7800 / Zoom @8100（各 23 样本） | 0.047843 / 0.001986 | 相同 | 0.042160 / 0.002715 | 相同 |
| A4 click 极差（判定口径） | 999.979 ms（G8 跑的是 W1-A5 之前的 avMulti） | **0.1875 ms**（#1） | 0.1875 ms | **0.1875 ms** |
| A4 passA4 / 半秒事件 / 闪光极差 | false / — / 0 | **true** / 10 / 0 | true / 10 / 0 | true / 10 / 0 |
| A4 判定事件里缺 click / 没有锚 | — | **0** / 1（#0） | — | **0** / 1（#0） |

G9 的 600 个事件 click 逐值相同；G8 只有 #491–#500 十个半秒事件里 iso3 那一格变了（W1-A5 已解释的平局，与 113 报告 §1.6 一致）。
**没改过的 `scripts/gate3-report.py`** 在 scratchpad 里拿"G9（G8）的其余产物 + 重算的五个 JSON"出运行报告：两次都 rc 0、"通过"，不带 `--waive`；
V6 / V7 / A4 三行与 reports/G9-run-g9.md 的同一行逐字相同（G8 的 A4 行写 0.187 ms：值是 0.18749999999990、G9 是 0.18750000000012，三位小数舍入的差）。运行报告只在 scratchpad，不入库。

### 1.6 交给 G10 的问题单

reports/issues/W1A6-g10-gate3-report-a4-reads-passA4.md：gate3-report.py 的 A4 只看 `maxClickSpreadMs`（第 366–368 行），
按用户"极差只算剩下的"，缺 click 时这个数不变——裁定到不了 gate 的判定，要加一句 `multi.get("passA4") is not False`；
App 的 ISOAppTests 与 Outputs 的 ISOAlignmentTests 同样只断言两个极差（只读，写给各自的会话）。

## 2. 测试 ID：数值 / 阈值 / 通过否

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `FrameAnalysisTests.testV6_T02_cutTickFromPts_droppedFramesBeforeDoNotShiftIt`（交付 1） | 老代码：tick 58 / 1058 / 57；新：第 60 拍（文件第 58 帧）、startTick 1000 → 1060、漏帧 [20, 30] 共 2；Cut 前一拍也漏 → 仍 60、仍是 Cut、`missingBetween` 1；maxEvents 2 截断列表、数量 3；没漏帧的文件 tick = 下标、字段与改前相同 | V6：恰好第 n 拍 | ✅ |
| `FrameAnalysisTests.testV6_T02_tickRateFromPtsDeltas_notSampleCountOverDuration`（交付 1） | 老代码：第 30000 拍报 29998；新：pts 估 60（1e-9 内）→ 30000；"样本数 / 时长" 59.9967 → 29998（不用它的理由钉住）；毫秒时间戳估 60（1e-3）→ 30000；59.94 → 60000/1001、第 3000 拍；单帧退回 60 | 同上 | ✅ |
| `FrameAnalysisTests.testV7_T02_fadeTicksFromPts_droppedFramesBeforeAndInside`（交付 1） | 老代码：2.0 帧 / 3.0 帧 / 自动 D 29、0.633 帧；新：前面漏两帧 **0 偏差**、29 样本、第 41 拍起（文件第 39 帧）；窗口漏第 50 拍 → 28 样本、0 偏差、`missingFrames` [50]；自动模式 D 30、0 偏差；s + 1 漏 → 第 42 拍起 0 偏差；s 漏 → 方向仍 A→B；`--fade-at -1` 不出 Fade（老代码崩） | V7：≤ 1 帧 | ✅ |
| `FrameAnalysisTests.testV7_T02_wipeZoomCurve_droppedFrameInWindowListed`（交付 1） | Wipe / Zoom 各 22 样本（第 50 拍漏）、0 偏差、`missingFrames` [50]、note 写"漏了 1 拍：50"；第 s + D 拍漏 → 量不了、note 写明是漏帧 | V7：≤ 1 帧 | ✅ |
| `TransitionProbeTests.testV6_V7_T02_droppedFramesInRecording_transitionsLandOnPtsTicks`（交付 1，真文件，不给 `--fps`） | 老代码：Cut 第 98 拍、Fade 2.3125 帧；新：Cut **第 100 拍**（文件第 98 帧）干净、漏帧 [20, 30]、拍号帧率 60（容器 nominalFrameRate 59.333）；Fade 第 131 拍起 29 样本、最大偏差 **0.328 帧**、窗口里 0 漏 | V6 恰好第 n 拍；V7 ≤ 1 帧 | ✅ |
| `TransitionProbeTests.testV4_mismatchedIdAndFrameNumberIsRejectedByRhythm`（加一段） | SelfCheck 判掉的四帧报告拍号：老代码 15–18 / 115–118；新 16–19 / 116–119（前面漏了第 5 拍） | — | ✅ |
| `FrameAnalysisTests.testA4_avMulti_fileMissingClickInJudgedEvent_failsA4`（交付 2） | 老代码：passA4 两处 true；新：第 5 s [2] 缺 → `passA4` **false**、`missingClickFiles` [2]、`missingClickEventCount` 1、那一格 nil、极差 0.02 ms（剩下四个文件）、markdown "缺 click" 列 [2]、A4 ❌；半秒事件缺 → 列 [1]、不判、true；五个文件都缺第 7 s → 无锚、不算缺、`unanchoredEventCount` 1、true；锚文件整条音轨没有 → 15 个判定事件缺、false；都不缺 → 0 / 0 / true | A4 ≤ 1 帧且判定事件不缺 click | ✅ |
| 老用例：FrameAnalysisTests 19 条、FixtureSnapshotTests 2 条（快照没重录）、RoundTripTests 1 条 | 全过 | — | ✅ |
| TestKit 全量 `swift test --package-path Packages/SwitcherTestKit`（最终代码 81c4028） | **81 个用例 = 81 过、0 跳、0 失败**（原 75 + 本会话 6），413.9 s；最长的 TransitionProbeTests 147.9 s（多了一条 5 s 的真文件用例） | 0 失败 | ✅ |
| frameprobe 冒烟（`make test-tools` 同一判法：debug 编出、无参数跑、输出含版本） | `frameprobe 0.1.0`；release 版 `--version` 同 | 输出含版本 | ✅ |
| `swift build --build-tests --package-path Tools/switcher-headless`（它的用例调 `FrameProbe.frames` / `av`） | 编过（新参数都有默认值，源码兼容） | 编过 | ✅ |
| 重算 V6（G8 / G9） | 第 1000 拍 Cut、150 条切换逐字段不变、0 漏帧 | 恰好第 1000 拍、所有 Cut 干净 | ✅ |
| 重算 V7（G8 / G9） | Fade 0.252 / Wipe 0.048、0.042 / Zoom 0.002、0.003 帧，逐样本不变 | ≤ 1 帧 | ✅ |
| 重算 A4（G8 / G9） | 0.1875 ms、passA4 true、缺 click 0、无锚 1 | ≤ 1 帧；目标 ≤ 1 ms | ✅（目标也达到） |
| `scripts/gate3-report.py`（没改）判 G9 / G8 产物 + 重算 JSON | rc 0 / rc 0，"通过"，不带 `--waive` | — | ✅ |
| `make lint BRANCH=w1-testkit-6`（C 与 `LC_ALL=zh_CN.UTF-8` 各一遍） | lint-rules（禁词 / 版本号 / Package.swift）、check-deps（8 个包）、check-ownership（10 个改动文件都在 W1-A6 允许范围内：8 个代码 / 测试 + 本报告 + 问题单）、check-help、check-links（200 个 Markdown）、check-rt-symbols 全绿 | 全绿 | ✅ |

## 3. 没做的和原因

- **拍号来源（pts0 / 逐帧累加）不改**（prompt 不做项、W1B4 问题单）。因此现在有两组式子：`av` / `switches` / `fade` / SelfCheck 报告 = round((pts − 第一帧 pts) × fps)，
  `wipe` / `zoom` / 剖面窗口 / `--blank-ticks` = round(pts × fps)（W1-A3 起就是）。第一帧 pts = 0 时两组相同——录制文件都是（G8 / G9 实测 36000 帧 pts0 = 0、拍号 = 下标）；
  要统一得连剖面窗口一起改（解码前就要知道 pts0），那是"拍号来源"那一半，没动。
- **wipe / zoom / av / stats 没给 `--fps` 时仍用容器标称帧率**（`l.fps`）。漏了帧的文件上它偏低（§1.2）：av 的整秒判定、stats 的 V5 期望帧数（= 时长 × 标称 = 样本数，
  会把漏帧藏掉）、wipe / zoom 的剖面窗口都会受影响。gate4 / gate3 / soak / MediaMTX / ISO 用例里这几步都带 `--fps`，不受影响；改默认值会动 V5 等别的口径，不在 T02 里，写进 §5 第 1 条。
- **A4 事件对齐的"按序号"退路没改**（W1-A5 §5 第 4 条）：有闪光帧读不出时间戳行时所有文件按 `#i` 对齐，某个文件丢了一个闪光帧就整体错位。
  按 pts 拍号当退路键是 T02 的同类改法，但 prompt 只点了 Cut / Fade / Wipe / Zoom，没做；现在缺闪光的文件不算"缺 click"（那个文件根本没有这个事件），见 §4 第 4 条。
- 没跑 gate4 / perf-baseline / soak（同机有三个会话，prompt 明说不跑）；Outputs 的 ISOAlignmentTests、headless 的 AVCompensationTests 没跑——它们读的字段数值不变
  （A4 极差口径不变、av 的拍号式子没变），headless 只验了编译。
- `scripts/`（gate3-report.py）、docs/KNOWN_ISSUES.md、测试标准没动：归 G10 / 用户（§5 第 3、4 条，问题单）。

## 4. 对契约的疑问

- **没有契约改动**：SwitcherContracts 一行没动；frameprobe 的报告 JSON 是 TestKit 自己的输出格式，只加了可选字段（`fps`、`missingFrames`、`missingFrameCount`、
  `missingBetween`、`missingClickFiles`、`missingClickEventCount`、`unanchoredEventCount`），老字段名一个没改。语义变的：`Switch.tick`、`FadeSample.tick`、`Fade.startTick`、
  `SelfCheck.Rejection.tick` 从"startTick + 序号"变成按 pts（没漏帧时数值相同）；`passA4` 多一个不过的条件。
- 口径（测试标准只有用户能改），请用户定：
  1. **Cut 前一拍漏了**（`missingBetween` 不为 nil）：现在只标出来，落点照报新画面第一帧、`cleanCut` 照判。真正换过去的那一拍可能就是漏掉的那拍，V6"恰好第 n 拍"其实没法确认——
     要不要在这种情况下判 V6 不过（或"不可判"）？G8 / G9 没有这种事件。
  2. **没有锚的事件不算"缺 click"**（`unanchoredEventCount`）：用户裁定的字面是"判定事件里有文件缺 click"，五个文件都没配上 click 算不算？我按 prompt 的
     "某个文件在锚 ±0.5 s 内没有 click"理解为要有锚才谈得上缺。**按"算"的话 G8 / G9 的 A4 都会翻红**：第 0 s 的 click 五个文件都没检出（G7 起的老现象，W1-A5 §3 第 4 条），
     那个事件没有锚。
  3. **Fade / Wipe / Zoom 窗口里漏帧**：V7 只在有样本的拍上判、漏的拍单独列，不判不过。要不要"窗口里有漏帧 = V7 不可判 / 不过"？
  4. **A4 缺闪光**：某个文件没有这个事件的闪光（`flashTimes` 那一格 nil）时闪光极差也只在剩下的文件里算，与改前相同——用户的裁定只说了 click，要不要同样算 A4 不过？

## 5. 下一个会话需要知道的坑

1. **AVFoundation 的 nominalFrameRate = 样本数 / 时长**（§1.2 探针）：漏了帧的文件它就偏低，frameprobe 没给 `--fps` 的那几步（wipe / zoom / av / stats）都按它走。
   switches / fade 现在不靠它（按 pts 差估），别的步骤**一律带 `--fps`**；`stats` 不带 `--fps` 时 V5 的期望帧数 = 样本数，漏帧会被藏掉。
2. **两组拍号式子**（§3 第 1 条）：第一帧 pts ≠ 0 的文件上 switches / fade / av 与 wipe / zoom / `--blank-ticks` 差 round(pts0 × fps) 拍。现在的录像都从 0 起，遇到再说。
3. **给 G10（prompt 122）**：① gate3-report.py 的 A4 加 `passA4 is not False`（问题单），不加的话缺 click 照样判过；字段名都没变，加了对老 JSON 也对。
   ② docs/KNOWN_ISSUES.md 第 197 行（"判定事件里缺 click 算不过归 121"）与第 198 行（Codex T02）可以销号进"G10 已修"表。③ 合入只动 TestKit / frameprobe，
   App / Outputs / headless 读的字段与数值不变；合入后先 `swift build -c release --package-path Tools/frameprobe`（T04）。
4. 造测试帧时**漏掉的帧要重新编号**（`index` = 文件里的位置），否则 `index` 碰巧等于拍号，老代码的 bug 测不出来——`FrameAnalysisTests.program(ticks:drop:)` 就是这么造的；
   真文件用 `SampleMovieWriter.Spec.droppedTicks`。
5. **快照用例整条比较 `Switch`**（FixtureSnapshotTests 的 `XCTAssertEqual(e.switches.switches, a.switches.switches)`）：往 `Switch` 加字段时"没有可报的"必须是 nil，
   写 0 就得重录快照。
6. `swift test --filter` 可以写多次（OR），`|` 交替不行：`--filter 'SwitcherTestKitTests.FrameAnalysisTests/testV6_T02' --filter '…/testV7_T02'`。
7. G8 / G9 的产物在 g8 worktree 的 `.build/gate4/g8/`、`g9/`（各 2.2 GB，只读）；release 单文件一步约 30 s、五文件 av 约 3 分钟。gate3-report.py 可以在 scratchpad 里
   拿符号链接拼的目录 + 换掉的 probe JSON 重判（`--checkpoint G4 --notes reports/G4-notes.md`，报告写 scratchpad），不用重跑 gate。
