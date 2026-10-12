# W1-A5 frameprobe 多文件 A4 的半秒平局 + "漏检"一条 click —— 报告（分支 w1-testkit-5）

日期 2026-10-12。机器 Apple M5 Max 128 GB，macOS 27.0.1（26A434），Xcode 27.0（27A266a）/ Swift 6.4，接电源；同机另有会话在跑 App / Contracts 用例（load 2.6–6.8）。
worktree `.claude/worktrees/w1-testkit-frameprobe-halfsec-36ebb6`，分支 `claude/w1-testkit-frameprobe-halfsec-36ebb6`，**别名 `w1-testkit-5` 指向同一个提交**
（prompt 113 的分支名；`make lint BRANCH=w1-testkit-5` 按它查 OWNERSHIP），从 main `22ff4d9`（G8b 续）开。提交：`git log main..w1-testkit-5`
（A4 以锚取 + 半秒只列不判 + 四条用例 e454158 → `--start-tick` 说明 + W1B4 问题单 3806f76 → A4 问题单处理结果 c5447a8 → 半秒判据对称写法 19aaeb8 → 本报告）。
只动了 `Packages/SwitcherTestKit/`（`Probe/FrameAnalysis.swift`、`Probe/FrameProbe.swift`、`FrameAnalysisTests.swift`、`ClickDetectorTests.swift`）、
`Tools/frameprobe/`（用法文字）、两张问题单和本报告；没碰契约、`scripts/`、`Tests/Fixtures/`（快照不用重录）。

**一句话**：G8b gate4 的 A4 999.979 ms 是 `avMulti` 让每个文件各自配"离自己闪光最近的 click"，闪光落在 .5 s 时前后两个整秒 click 是平局，
iso3 晚 20 µs 就配到了前一秒。改成**以第一个配上 click 的文件（PGM）为锚、其他文件取离锚最近的 click**，半秒事件只列不判之后，
用 G8 的原产物重算 A4 = **0.187 ms ✅**（与问题单按整秒配对手算的 0.187、G7 / W1-D3 那轮 gate4 的 0.188 一致），不带 `--waive` 的 gate 报告脚本直接判过。
"iso3 第 500 s 的 click 漏检"查下来**没有漏检**：五个文件都检出 599 个 click，是平局让它没被任何闪光选中。

---

## 1. 做了什么

### 1.1 先复现、再定位

- G8 的产物（g8 worktree 的 `.build/gate4/g8/`，不入库）：`probe-av-multi.json` 里超阈值的只有 #491–#500 十个事件，闪光五个文件都在 xxx.5 s、极差 0；
  click 是 `[k+1, k+1, k+1, k+0.00002, k+1]`。各文件 `perFile` 的配对：PGM 的 490.5 s 闪光配 491（恰好 500 ms 的平局，`nearest` 只在严格更近时取前一个），
  iso3 配 490.00002（499.979 ms，近 20 µs）。G8 按序号对齐事件（10 个闪光帧读不出时间戳行，`genTimeMs` nil → 整体退回 `#i` 键）。
- 合成复现（用例 1）：五份 25 s 的序列，闪光在 0…9 s 整秒、9.5…18.5 s 半秒、19.95…23.95 s，click 在整秒、其中一份整体晚 20 µs；
  **老代码跑这条用例红 22 处，click 极差 999.98 ms**——与 G8 同一个数。

### 1.2 `avMulti`：click 以锚取（交付 1）

- 锚 = 按传入顺序第一个给这个事件配上 click 的文件（gate4.sh 传的第一个就是 PGM `out.mov`），用它自己配的那个 click（与它 `perFile` 里的 A2 配对相同）；
  其他文件取**离锚最近**的 click，窗 ±0.5 s（与 `av` 的 `maxMatchSeconds` 同一个数，新增同名参数）。锚文件没配上时顺延到下一个配上的文件。
- 离锚超过 1 帧的 click **照样进极差**：用例里一份音轨整体晚 30 ms → 报 30 ms、A4 红。没有按 prompt 字面把"容差 ≤ 1 帧"做成筛选（筛掉 = 那一格变 nil，
  极差只在剩下的文件里算，真错位反而被藏掉）；1 帧仍是判定阈值。
- 没选"闪光之后第一个 click"：音频略超前的整秒事件（G8 第 1 s iso3 的 click 在 0.999917 s，比闪光早 83 µs）会被它推到下一秒。
- `perFile[*]` 不变，仍是每个文件自己的 A2 配对（半秒事件里 iso3 在 `perFile` 里还是配到前一秒，那些配对本来就是"非整秒、只报不判"）。

### 1.3 半秒事件只列不判（交付 2）

- 判据：**闪光离锚 click 在半秒 ±1 帧内**（闪光与锚 click 的间隔 d 满足 |d − 0.5 s| ≤ 1 帧）；一个文件都没配上 click 时按离最近的整秒算——60 fps 节目、从第 0 拍起的文件就是
  prompt 写的 |flash − round(flash)| ≈ 0.5。用锚的偏移而不是拍号算，是因为平局是相对 click 网格的：59.94 节目（click 周期 1.001 s）或 click 来自 59.94 的路时，
  按拍号的"半秒"会对不上真正的平局点。
- `MultiFileEvent` 加 `anchorFile`、`halfSecond`；`MultiFileAVReport` 的 `maxFlashSpreadMs` / `maxClickSpreadMs` / `passA4` **只看判定事件**
  （gate3-report.py 与 ISO 两组用例读的就是这两个字段，字段名不变），另加 `allEventsMaxFlashSpreadMs` / `allEventsMaxClickSpreadMs`（含半秒、只报不判）、
  `halfSecondEventCount`、`note`。全是可选字段：老 JSON / `Tests/Fixtures/w1a-sample-20s.expected.json` 照常解码，快照没重录。
  没有可判的事件（全是半秒）时 `passA4` = nil，与"一个整秒配对都没有"时 `passA2` = nil 同口径。
- markdown：表多"锚""判定"两列（`●` / `半秒，只列`），末行写判定事件数与半秒事件数，有半秒事件时附 note。

### 1.4 "iso3 第 500 s 的 click 漏检"（交付 3）

- 20 行探针（scratchpad `clickprobe/`：只读音轨 → `FrameProbe.audioTimeline` 同一口径修正 → 同一个 `ClickDetector`，五个文件 3 s 跑完）：
  **五个文件都是 599 个 click，按整秒一一对应、谁也不缺**（首个都在 1 s，第 0 s 那个五个文件都没有，G7 也是 600 / 599，老现象）；
  iso3 第 500 s 那个在 **500.000021 s（样本 24000001，峰值 1.12）**。
- 问题单里的"592 个 vs 593 个"数的是配对里**用到的**不同 click：老口径下 499.5 s 的闪光配了更近 20 µs 的 499.000021、500.95 s 的配了 501.000021，
  500.000021 没被任何闪光选中；`perFile[*].clickCount` 五个文件本来就都是 599。以锚取之后 iso3 用到的 592 → 593，与别的文件一样。
- `ClickDetector` 是逐样本滑的 1 ms（48 样本）能量窗，没有按整秒或按 48 样本对齐切的窗口，+20 µs（1 个样本）落不到"窗边"上。没改检测代码；
  加一条用例钉住：click 起点在 48 样本网格的 48 个相位上都按样本精确找到。

### 1.5 `--start-tick` 说明 + W1B4 问题单（交付 4）

- `frameprobe av` 用法：`--start-tick N` 改成"文件第一帧的节目拍，默认 0。开录起点已按节目输出时间线（G8b），开着 Master 效果录的文件也从第 0 拍起，
  默认 0 就对；只在录制中途改了 Master 效果（L 变了：之后的拍号整体错开 ΔL，给了也只对改了之后那段有效）时才要给"，另留一句
  "文件本来就不从第 0 拍起（推流落盘从关键帧起录、soak 切段）照旧给第一帧的拍号"（soak.sh 每段都在用，不能写成只有 L 变了才要）。
  `av` 那行顺带写上 A4 的新取法。`FrameAnalysis.av` 的 `startTick` 注释同口径。
- reports/issues/W1B4-w1-testkit-frameprobe-delayed-video-start.md 末尾写了处理结果：起点那一半已由 G8b 胶水（9533369）在源头修掉；
  拍号推法（跳过开头黑帧 / 逐帧累加）这次不改，理由见 §3。

### 1.6 用 G8 的产物重算 A4（交付 5）

命令与 gate4.sh 那一步相同（G8 跑的是默认口径：自证解码开、不带 `--blank-ticks`）：
`Tools/frameprobe/.build/release/frameprobe av out.mov out.iso1.mov out.iso2.mov out.iso3.mov out.iso4.mov --fps 60.0`，release；最终代码（19aaeb8）2 分 35 秒，
与改判据写法之前那一遍（e454158，2 分 51 秒）的 `multi` / `perFile` 逐字段相同。

| | G8 原 JSON（老 avMulti） | 本分支重算 |
|---|---|---|
| 事件 | 600（`#i` 键） | 600（同一组键、闪光逐值相同） |
| click 极差最大（A4 判定口径） | **999.979 ms**（#491–#500） | **0.187 ms**（#1：[2] +0.104 ms、[3] −0.083 ms） |
| 闪光极差最大 | 0.000 | 0.000 |
| 半秒事件（只列不判） | — | 10 个，#491–#500（闪光 490.5…499.5 s），含它们的 click 极差最大 0.187 ms（这 10 个各 0.021 ms） |
| 锚 | — | [0] PGM 599 个事件；#0（0 s，五个文件都没有 click）无锚 |
| passA4 | false | **true** |
| iso3 用到的不同 click | 592 | 593（与别的文件一样；检出数五个都是 599） |

逐事件对照：只有 #491–#500 这 10 个事件里 iso3 那一格变了（k − 1 + 0.00002 → k + 0.00002，极差 999.979 → 0.021 ms），其余 590 个事件 click 逐值相同。
**不带 `--waive`** 的 `scripts/gate3-report.py`（没改）在 scratchpad 里拿新 JSON 加 G8 其余产物出 G8 的运行报告：rc 0、"通过"，
A4 行"5 个文件（PGM + ISO 音轨），600 个事件：click 时刻极差最大 0.187 ms，闪光极差最大 0.000 ms ✅"。运行报告与拼好的整份都只在 scratchpad，不入库。

另：用本分支 release frameprobe 跑了 Outputs 包的 `ISOTests.ISOAlignmentTests/testA4_fourVideoISORoutesPlusPGM_sameEventWithin1Frame`（只跑不改，
它调 `Tools/frameprobe/.build/release/frameprobe av` 多文件）：判定事件 10 个、半秒 0 个，闪光 / click 极差 0.000 / 0.000 ms，过。

## 2. 测试 ID：数值 / 阈值 / 通过否

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `FrameAnalysisTests.testA4_avMulti_halfSecondTie_clicksFollowFirstFileAnchor`（交付 1） | 老代码：22 处失败，click 极差 999.98 ms；新：25 个事件每个 0.0208 ms、最大 0.02 ms、锚全是 [0]；锚文件没 click → 顺延到 [1]、极差仍 0.02；一份音轨整体晚 30 ms → 30 ms、A4 红 | A4 ≤ 1 帧（16.67 ms） | ✅ |
| `FrameAnalysisTests.testA4_avMulti_halfSecondEvents_listedNotJudged`（交付 2） | 半秒事件上晚 30 ms：判定口径 0.02 ms、含半秒 30 ms、A4 ✅、10 个半秒、markdown 有"半秒"；同样 30 ms 落在整秒事件 → 30 ms、A4 ❌；半秒的边：离锚 0.5 s − 1 帧算半秒、− 2 帧就判；全半秒 → passA4 nil；窗 1 s 缺 click 离锚 0.7 s 不算半秒（旧写法红，19aaeb8） | 同上 | ✅ |
| `FrameAnalysisTests.testA4_avMulti_clickAfterHalfSecondRun_isUsedNotMissed`（交付 3） | 老口径 iso3 用到 24 个不同 click、缺 19.00002 s（= G8 第 500 s）；新：五个文件 25 个 click 各用一次 | — | ✅ |
| `ClickDetectorTests.testA4_clickDetector_clickOneSampleLate_foundAtEveryWindowPhase`（交付 3） | 48 个相位 × 3 个 click 全部按样本精确找到、峰值 1（改动前也过：检测本来就没毛病，这条是钉住结论的哨兵） | 样本级 | ✅ |
| `FrameAnalysisTests.testA4_avMulti_alignsEventsByGenTime`（老用例） | 时间线原点 0 / +5 / −3 ms → 闪光 / click 极差 8 ms、A4 ✅；+20 ms → ❌，与改前相同 | 同上 | ✅ |
| `FixtureSnapshotTests` 两条（老快照） | 新字段可选，老 expected.json 照常解码；同一文件两份 → 极差 0、A4 ✅ | — | ✅ |
| TestKit 全量 `swift test --package-path Packages/SwitcherTestKit`（最终代码 19aaeb8） | 75 个用例 = 75 过、0 跳、0 失败（原 71 + 本会话 4），414.8 s；判据改对称写法之前（3806f76）那一遍也是 75 / 75、416.5 s | 0 失败 | ✅ |
| frameprobe 冒烟（`make test-tools` 同一判法） | `frameprobe 0.1.0` | 输出含版本 | ✅ |
| A4 重算（G8 产物，§1.6） | 0.187 ms（老 999.979） | ≤ 1 帧；目标 ≤ 1 ms | ✅（目标也达到） |
| `ISOAlignmentTests.testA4_fourVideoISORoutesPlusPGM_sameEventWithin1Frame`（Outputs，只跑） | 0.000 / 0.000 ms，10 个判定事件 | ≤ 1 帧 | ✅ |
| `make lint BRANCH=w1-testkit-5` | lint-rules（禁词 / 版本号 / Package.swift）、check-deps、check-ownership（8 个改动文件都在 W1-A5 允许范围内）、check-help、check-links、check-rt-symbols 全绿 | 全绿 | ✅ |

## 3. 没做的和原因

- **frameprobe 拍号推法不改**（W1B4 问题单的建议：跳过开头没图案的帧再取 pts0 / 按相邻帧 pts 差逐帧累加拍号）：起点那一半 G8b 已在源头修掉；
  剩下的"录制中途 L 变了"只在手动开 / 关 Master 效果时出现，gate4 / perf 不带效果；逐帧累加会改所有 `av` 结果的拍号来源（A2 / A3 整秒判定、soak 每段的
  `--start-tick` 都靠现在的 (pts − pts0) × fps），要做该单独开、带 gate4 / soak 新旧对照。说明里写了中途改 L 时怎么量（分段、后一段给 `--start-tick`）。
- **"某个文件在锚附近没有 click"不判红**：那一格是 nil，极差在剩下的文件里算——与改前"那个文件没配上就是 nil"同一口径，没借这次改判定口径。
  要不要把"判定事件里有文件缺 click"算 A4 不过，是口径问题，留给用户（§4）。
- 没动 `scripts/`（gate4 / gate3-report.py 不用改）、docs/KNOWN_ISSUES.md、docs/testing/、测试标准——归 G9 / W4-C3 / 用户（§5 第 1 条）。
- 第 0 s 的 click 五个文件都没检出（闪光 600、click 599，G7 也是）：五个文件一致、对 A4 没有影响，没查。

## 4. 对契约的疑问

- 没有契约改动：SwitcherContracts 一行没动；frameprobe 的报告 JSON 是 TestKit 自己的输出格式（W1-A2 加 `onSecond` 等字段是同一先例），只加了可选字段，
  老字段名不变。语义上 `maxFlashSpreadMs` / `maxClickSpreadMs` / `passA4` 从"全部事件"变成"判定事件（不含半秒）"，这是 prompt 113 交付 2 定的。
- 口径（不是契约，测试标准只有用户能改）：① 测试标准 §2.3 只写了 A2 / A3 按整秒配对判；A4 的"半秒事件（闪光离锚 click 在半秒 ±1 帧内）只列不判"
  与"click 以第一个文件为锚"现在只写在 frameprobe 的注释 / 用法 / 本报告里，要不要像 A2 那样补进 §2.3，请用户定（G3 时 A2 的整秒口径是检查点按用户授权补的）。
  ② "±1 帧"这个带宽是本会话定的（平局只在各文件 click 差不到 1 帧时才会翻转，1 帧又是 A4 阈值）；③ 判定事件里有文件缺 click 算不算不过（§3 第 2 条）。

## 5. 下一个会话需要知道的坑

1. **给 G9（prompt 114）**：合入后 gate4 的 A4 不用再 `--waive`，gate3-report.py 不用改（读的 `maxClickSpreadMs` 就是判定口径）；
   docs/KNOWN_ISSUES.md"测试与工具"里 G8b 加的 A4 平局那条可以销号，`--start-tick` 那条可以补"frameprobe 说明已改、拍号推法不改（W1-A5）"；两张问题单末尾都写了处理结果。
   合入只动 TestKit / frameprobe，App / Outputs 的 ISO 用例读的字段不变。
2. **A4 传文件的顺序有意义**：第一个配上 click 的文件是锚，gate4.sh / ISO 两组用例都把 PGM 放第一个。别拿 `perFile[*].pairs` 的 click 去算 A4——
   那是各文件自己的 A2 配对，半秒事件里还是各配各的。
3. `maxClickSpreadMs` 不含半秒事件；要看全部用 `allEventsMaxClickSpreadMs`，markdown 末尾的 note 也写着。
4. **事件对齐会整体退回按序号**：只要有一个闪光帧读不出时间戳行（genTimeMs nil），所有文件都按 `#i` 对齐（G8 有 10 个这样的帧）。
   ISO 文件录的是 PGM 画面、闪光数一样所以没事；以后要是比的文件闪光数不同（某个文件丢了一帧闪光），`#i` 会整体错位、报一串 1 s 的闪光极差——那不是 A4 的平局。
5. **"click 数不一样"先分清是检出数（`perFile[*].clickCount`）还是配对用到的数**。查 click 用只读音轨的探针最快（3 s 跑完五个 600 s 文件，
   `MediaReader.readAudio` + `FrameProbe.audioTimeline(… mode: .auto)` + `ClickDetector.detect`，20 行），整条 `frameprobe av` 要解 36000 帧画面。
6. G8 的产物在 g8 worktree 的 `.build/gate4/g8/`（2.2 GB，不入库）；5 × 600 s 的 `av` 多文件 release 约 3 分钟，别用 debug 版。
7. 同机有别的会话在跑 App / Contracts 用例时，TestKit 全量照样 0 失败（最长的 TransitionProbeTests 148 s、带 60 s E2 录制的 NoiseBackgroundTests 118 s），没撞到计时类红。
