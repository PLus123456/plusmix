# W2-A5 文件输入止血：D13 暂停后定位、D14 片尾开循环、D15 竖屏方向矩阵、D01 底层钳位、positionSeconds —— 报告（分支 w2-inputs-5，prompt 117）

日期 2026-10-18。机器 Apple M5 Max（MacBook Pro），macOS 27.0.1（26A434），Xcode 27.1（27A9275），Swift 6.4，接电源；同机并行 118 / 119 / 121 三个会话（跑 App / 包测试时负载 2–6）。
工作树分支 `worktree-agent-ac41a38a7c5f2130a` = 本地别名 `w2-inputs-5`（每次提交后 `git branch -f w2-inputs-5 HEAD`）。
**叠在 115 上**：从 `p5-contracts-4`（29a64ad，P5-4 做完的分支头，main 358517f 的后代）开，直接用它落地的契约常量 `FileSource.rateRange`（0.1…8）、`PlaybackLimits.maxSeekSeconds`（一周）——
没有"115 没合入先本地定"这一步。G10 要先合 115 再合本分支。不 push、不 merge。

提交（`git log p5-contracts-4..w2-inputs-5`）：红 daf355b → D01 5499605 → D14 / positionSeconds f5219e8 → D13 ceb5228 → D15 9d50632 → 方向提示单放 bd2c6ce → 用例打印 32875c8 → 本报告。
只动了 `Packages/SwitcherInputs/Sources/SwitcherInputs/File/`（FileInput / FileDecoder 改、FileOrientation / PixelRotator 新）、`Packages/SwitcherInputs/Tests/SwitcherInputsTests/`（FileInputW2A5Tests 新、Support 两个写素材的助手加参数）、
`Tests/Fixtures/`（新夹具 + README 一行）和本报告。没碰契约、App、DeckLink / NDI、headless、任何阈值。

**一句话**：五条都先按 Codex 的触发条件在本机复现成红用例（D01 两条是整个 xctest 进程崩），再改实现；14 条新用例全绿，SwitcherInputs 整包 124 条 0 红，
App 里用到 FileInput 的三组 25 条也过。D13 除了 Codex 指的那处，还挖出同根的第二处（推帧线程拿旧快照把新代的首帧当旧代扔掉）；D15 先探针，
合成输出能直接给转正帧但每个 reader 多 100–150 MB、还改像素值，改用 VTPixelRotationSession 自己转（逐字节无损，1080p 每帧 CPU 多 0.18 ms）。

---

## 1. 做了什么

### 1.1 先写红测试（daf355b，实现前实测）

新文件 `FileInputW2A5Tests.swift`。小片段现场用 AVAssetWriter 写（Codex 的素材是 1 s / 30 帧；这里画帧号图案 640×360，320 宽的图案块只有 4 像素、H.264 之后读不稳）；
方向用例用新夹具（§1.6）和现场写的八种矩阵。为了红在行为上而不是编译上，先放了接口桩（FileOrientation 归类一律 nil、FileInfo.orientation 恒 identity、`pauseIsApplied`）。

| Codex 条目 | 触发条件（照他的探针） | 修前实测 |
|---|---|---|
| D13 | 1 s 文件推到第 4 帧，`pause(); seek(toSeconds: 0.5)`，0.4 s 后看 | 画面停在**第 3 帧**、`positionSeconds` **0.1**（Codex 原话 0.1）；`seek → pause` 同样；连"暂停稳定后再 seek"也停在 3、恢复后 `[3,3,3,3,3,3,18,18]`（第二处，§1.3） |
| D14 | 不循环的 1 s 文件，推到第 28 帧再等 10 ms（解码线程已读到尾、放了哨兵），开循环，0.4 s 后看 | 两次都是 **noSignal、pushed 30、loops 0、seeks 0**（与 Codex 两次复现相同）。不等那 10 ms 的话解码线程还没读到尾、走正常循环，用例照样绿——触发条件必须照他的探针写（§5 第 1 条） |
| D15 | 夹具（90° 矩阵、编码 320×240）当文件输入 | 出 **320×240**、四角 RGBW（编码方向原样）；八种矩阵全与参照不符；真渲染器叠用户旋转四种全对不上 |
| D01 速率 | `FileInput(rate: 0)` | **`FileInput.swift:130: Precondition failed: 速率必须为正`**，xctest 进程退出 |
| D01 定位 | `seek(toSeconds: 1e300)` | **`Fatal error: Double value cannot be converted to Int64 because the result would be greater than Int64.max`**，进程退出 |
| positionSeconds（§5 末段，P3） | 不循环的 1 s 文件播完 | noSignal 时读 **0.983**、0.3 s 后 **0.3**（对时长取余还在走） |

### 1.2 D01 底层：速率钳位、定位先钳再换算（5499605）

- `init` / `rate` setter：`precondition(rate > 0)` 换成 `clampRate`——不在 `FileSource.rateRange` 的钳到两端（±∞ 同理），**NaN 按 1**（没有方向）；`lastError` 一句
  "播放速率 0 不在 0.1–8 之间，按 0.1 播"。提示放单独一格（`noteBox`：不改 state、不算出错；`lastError` = 真错误 ?? 钳位提示 ?? 方向提示），start 不清，下一次合法的速率 / 定位清掉。读 `rate` 得钳后的值。
- `seek(toSeconds:)`：`seekTarget` 先在 Double 里钳到 [0, 时长]（非有限 / 负数 = 0，与 `InputSettings.clamped()` 同口径；时长未知按一周；再兜一道 Int64 / 1e6 的上限）再换 Rational；
  钳完 ≥ 时长仍按**原口径"过尾 = 从头"**（§4 第 1 条）。不在 0…一周的照做、提示一句；在契约范围里只是过了片尾（12.5 s 定位 10 s 文件）不提示。
- `seek(toFrame:)`：帧号先钳到文件帧数（`Int.max` × 帧时长原来在 `Rational.reduced` 的 precondition 崩，同一类）。

### 1.3 D13：新定位的代次优先于旧的暂停请求（ceb5228）

Codex 指的：`pause()` 留下"待落实"，`seek()` 换代 / 改锚点却留着这个标志，推帧线程随后用上一代最后推出的帧覆盖目标。本机复现时多看到两处同根的：

1. **推帧线程拿旧快照把新代的首帧当旧代扔掉**：推帧线程每拍先读 `playback` 快照、再睡到拍点；睡的这段里来了定位，小文件重开 reader + 解首帧只要几 ms，新代的首帧已经进队列——
   原来 `head.generation != p.generation` 就当旧代 pop 掉，定位目标那帧丢了（暂停中就一直重推旧帧；播放中首帧变成目标 + 1）。`testD13_seekWhilePlaying` 把这一处单独还原验过：12 次定位里 1 次首帧 21 而不是 20。
   pattern.mov（1080p、GOP 长）重开慢，原有的"定位 300 首帧是 300"用例碰不上这个窗口。
2. **seek 之后紧跟 pause**：落实暂停时拿的也是上一代推出的帧，位置冻回定位之前。

改法：`seek(toMedia:)` 暂停中就把暂停落在目标上（`pauseApplied = true`，anchorMedia = 目标）；推帧线程只扔比快照**旧**的代、比快照新的留给下一轮；落实暂停只认本代推出的帧（`heldGeneration`），
本代还没推过就冻结在 max(本拍位置, 锚点位置 = 定位目标)；锁里发现期间换了代 / 恢复了就这一拍不出、下一轮按新状态来；暂停中定位后新代首帧比冻结位置还晚（目标早于首帧 pts）照样出它、冻结位置挪过去。
App 不用改：`InputRuntime.syncPlayback` 同一快照先 pause 再 seek，两种顺序结果一样。

### 1.4 D14：等尾时也看循环开关，哨兵处与 setter 同锁判定（f5219e8）

- 解码线程：放结尾哨兵时记 `endMedia`；等尾的循环 5 ms 一看（原来 20 ms、只看换代），循环开了（或推帧线程已许了 `loopResumeEnd`）就接着开下一圈 reader（base = 这一圈结尾，展开位置连续，loops +1，不走定位）。
- 推帧线程：播到哨兵、本拍没有别的帧要出时调 `endDecision`——与 endAction setter **同一把锁**：循环开着 = 作废哨兵、记 `loopResumeEnd`、接着出后面下一圈的帧；否则 `reachedEnd` 置上、按当时的结束动作收尾。
  setter 先 / 这里先两种顺序都自洽，不会再停在"开关开着却 noSignal"；许了之后又关循环，这一圈照接（推帧线程已越过哨兵），下一圈尾再停。
- 播完之后再开循环仍走 W5-N 的"当场从头"（seek 0，seeks +1），用例照旧。

### 1.5 positionSeconds（f5219e8）

`reachedEnd`（推帧线程已收尾）或位置已过 `endMedia`（解码线程放了哨兵、推帧线程还没收尾的那一拍）都返回**时长**、之后不变；循环中照旧对时长取余。App 现在没有读者（Codex 原话），库接口修正。

### 1.6 D15：先探针，再用 VTPixelRotationSession 转正（9d50632、bd2c6ce）

**夹具** `Tests/Fixtures/w2a5-rot90-320x240.mov`（2 302 字节，README 写了两条 ffmpeg 命令）：1 s 30 帧 H.264 320×240 BT.709 limited，编码方向四色象限（左上红 / 右上绿 / 左下蓝 / 右下白），
`ffmpeg -display_rotation 90` 只改显示矩阵、流拷贝。AVFoundation 读成 `preferredTransform` = (0, −1, 1, 0, 0, 0)（逆时针 90° 才正、不带平移）；手机竖拍是 (0, 1, −1, 0, h, 0)（顺时针 90°、带平移），用例里另写。

**探针（铁律 10，scratchpad 的 probe1–5，结论如下）**：

1. 能不能直接给转正帧：`AVAssetReaderVideoCompositionOutput` + `AVMutableVideoComposition.videoComposition(withPropertiesOf:)`——**能**：renderSize 240×320、四角与 AVAssetImageGenerator（`appliesPreferredTrackTransform`）参照一致、
   30 帧、pts 与源轨相同（`sourceTrackIDForFrameTiming` = 1，跟源轨走，不按 frameDuration 重采样）。VTPixelRotationSession 把 track output 的帧逆时针转 90° 也得同样四角。
2. 代价（满速读完全部帧、手上留 3 帧像推帧线程那样，每种读法单独一个进程跑两遍取第二遍；CPU = getrusage 用户 + 系统，内存 = phys_footprint 峰值）：

| 素材（带 90° 矩阵） | A 不转（现状） | B track + VTPixelRotation（池化） | C 合成输出 | D track + vImage |
|---|---|---|---|---|
| 1080p60 H.264 600 帧 → NV12 | 0.13 ms / 帧，11.8 MB | **0.31 ms，25.3 MB** | 0.22 ms，**158.4 MB** | 0.21 ms，24.0 MB |
| 1080p ProRes 422 HQ 10 bit 300 帧 → NV12 | 0.16，17.3 | 0.27，29.3 | 0.25，167.2 | 0.24，29.6 |
| 4K60 H.264 180 帧 → NV12 | 0.30，58.0 | 0.58，107.8 | 0.45，249.5 | 0.68，106.0 |
| 1080p H.264 → BGRA | 0.25，23.8 | 0.29，55.8 | 0.22，196.1 | 0.57，55.8 |

   第一帧逐字节比：NV12 H.264 三种转法 Y 平面 2 073 600 字节**全同**；BGRA 源 B = D、**C 与它们差 6 072 073 / 8 294 400 字节（最大差 52）**；10 bit ProRes → NV12 B = D、**C 差 1 774 925 / 2 073 600（最大差 2）**——合成输出过了它自己的色彩转换。
3. 选择：**不用合成输出**（每个 reader 多 100–150 MB，循环点两个 reader 并存还要翻倍——W2-A4 正是为了不常驻双 reader 才只在离尾那一小段并存；而且改像素值）；
   vImage 与 VT 都无损，vImage 在 1080p NV12 更省 0.1 ms，但 BGRA / 4K 反而更费、八种方向要自己拆平面与翻转；**选 VTPixelRotationSession**（一次调用管旋转 + 水平 / 垂直翻）。
4. 八种轴对齐矩阵（AVAssetWriterInput.transform 现场写）对着参照找 VT 参数：恒等 → 0；(0,1,−1,0,h,0) → CW90；(−1,0,0,−1,w,h) → 180；(0,−1,1,0,0,w) → CCW90；
   (−1,0,0,1) → 0 + 水平翻；(1,0,0,−1) → 0 + 垂直翻；(0,1,1,0) → CW90 + 水平翻；(0,−1,−1,0) → CW90 + 垂直翻。**VT 先转再翻**。
5. VT 自己会把源缓冲的附件（alpha 模式、色彩、色度位置）抄到目标（probe4）；'420v' / '420f' / BGRA、偶数与奇数宽高（1919×1079）八种参数全返回 0（probe5）。

**改法**：
- `FileOrientation(transform:)`：只看 (a, b, c, d) 的符号（相对最大项 1e-3 以内算 0，容浮点噪声与缩放），平移不看（转正后的帧本来从 (0, 0) 起）；任意角度 / 退化 / 非有限 = nil → 按编码方向原样出、`lastError` 提示一句。
- `PixelRotator`：每个 FileAsset（每次 start）一个 VT 会话 + 一个 IOSurface / Metal 兼容的池，跨 reader 共用（循环 / 定位重开 reader 不换池，渲染器纹理表认得住），只在解码线程用；
  附件照抄、删 clean aperture / 像素宽高比 / 色度位置；转不了的帧原样出、计数、`lastError` 提示。
- `FileAsset` 读 `preferredTransform`；`FileInfo` 加 `orientation` / `displayWidth` / `displayHeight`（`width` / `height` 仍是编码尺寸）；`FileReader.nextVideo` 出转正后的帧；面计数记池里的缓冲；黑场按转正后的宽高建。
- 用户在输入设置里设的旋转：FileInput 不碰 InputSettings，渲染器拿到的已是正的帧，用户旋转自然叠在转正之后——用例用真渲染器（OfflineRenderer，与实时路径同一个合成 pass）验。
- 方向提示单放一格（bd2c6ce）：合法的定位 / 改速率不再把"矩阵认不出 / 转正失败"那句清掉。

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

都是行为用例，没有测试标准里的阈值；"阈值"一栏写断言口径。修前 = daf355b 上实测（§1.1）。

| 测试 ID | 修前 | 修后（最后一轮） | 断言口径 | 通过 |
|---|---|---|---|---|
| `testD13_pauseThenSeekBeforePauseApplied_holdsAtSeekTarget` | 三种顺序都停在第 3 帧、位置 0.1 | 三种顺序 0.4 s 后都在**第 15 帧**、位置 0.5、仍暂停、live；0.15 s 后仍 15；恢复后从 15 接着播 | 帧号 = 15、位置 ±半帧 | ❌ → ✅ |
| `testD13_seekWhilePlaying_fastReopen_firstNewFrameIsTargetEveryTime` | （§1.3 第 1 处单独还原：12 次里 1 次首帧 21≠20） | 12 / 12 次首个新帧号 = 目标 | 每次都等于目标 | ❌ → ✅ |
| `testD14_loopEnabledWhileDecoderAtEOFButPacerNotYet_keepsLooping` | 两次 noSignal、pushed 30、loops 0 | 2 次尝试卡进窗口 2 次；每次开循环时 received 30 / pushed 28（解码线程已放哨兵），0.4 s 后 **live、pushed 40、loops 1、seeks 0、没跟上 0**，中途没进过 noSignal，帧号 mod 30 不跳 | 见左 | ❌ → ✅ |
| `testD14_loopToggledOnThenOffInWindow_stillEndsAtLastFrame` | 位置 0.083 / 0.1（其余已对） | 照旧停在 29、noSignal、位置 1.0；再开循环从头（seeks 1） | 见左 | ❌ → ✅ |
| `testD14_loopEnabledInWindow_withAudio_audioContinues`（修后加） | — | 环块 282、跳 0、host time 不连续 0、loops 1、seeks 0 | 块数 ≥ 1.4 s 的量、不连续 0 | ✅ |
| `testW2A5_positionSeconds_afterNonLoopEnd_staysAtDuration` | 0.983 → 0.3 | hold / black 播完 = 1.0，0.3 s 后仍 1.0；循环的 30 次采样都在 [0, 1) | 1e-9 | ❌ → ✅ |
| `testD01_outOfRangeRate_clampedIntoRateRange_withLastError` | 进程崩（precondition） | 0 / −1 / 1e-4 / −∞ → 0.1，1e300 / +∞ / 8.0001 → 8，NaN → 1，都有提示；0.1 / 1 / 1.5 / 8 无提示；1e300 起播每拍前进 **8** 帧、提示还在；setter 0 / 1e-4 → 0.1，改回 2 提示清掉、每拍 2 帧 | 见左 | 崩 → ✅ |
| `testD01_hugeOrNonFiniteSeek_clampedBeforeConversion_noOverflow` | 进程崩（Double → Int64） | 1e300 / +∞ / NaN / −5 / 一周 + 1 / 12.5 都不崩、都从第 0 帧、计数照记、提示只给契约外的五个；`seek(toFrame: Int.max)` 从头；之后 5 s = 第 300 帧、提示清掉 | 见左 | 崩 → ✅ |
| `testD15_rotatedFixture_outputsUpright240x320_matchingAVFoundation` | 320×240、RGBW | **240×320、四角 GWRB** = 参照；orientation rotate270；两圈后仍转正、面数 **7**（修前不转时 23） | 尺寸 / 四角 = 参照、面数 ≤ 16 | ❌ → ✅ |
| `testD15_allEightAxisAlignedTransforms_matchAVFoundationReference` | 8 种全不符 | 8 种尺寸与四角都 = 参照，参照两两不同 | 见左 | ❌ → ✅ |
| `testD15_userRotationStacksOnTopOfOrientation_notAppliedTwice` | 4 种全不符 | 用户旋转 0 / 90 / 180 / 270：FileInput 的帧与"参照图 + 同一旋转"画出来四角、外框都一致，四种两两不同 | 见左 | ❌ → ✅ |
| `testD15_rotatedAlphaSources_uprightAndPremultipliedOnce`（修后加） | — | ProRes 4444 / HEVC alpha 带 90° 矩阵：240×320、BGRA、只预乘一次（R 在 100–140） | 同 `testFile_alphaSources_outputPremultipliedBGRA` | ✅ |
| `testD15_nonAxisAlignedTransform_passesThroughWithNote`（修后加） | — | 45° 矩阵按编码方向原样出（320×240、RGBW）、提示"方向矩阵…"，合法定位 / 改速率后仍在 | 见左 | ✅ |
| `testD15_orientationFromPreferredTransform_classification` | 桩全 nil | 八种、带缩放、浮点噪声认对；45° / 退化 / NaN = nil；swapsAxes 四个 | 见左 | ❌ → ✅ |
| 既有 `FileInputTests` 16 条 | 16 / 16 | 16 / 16（含两条解码计时用例 60 fps 连续、8 倍速带音频；W2A4 ProRes 循环点见 §5 第 9 条） | 各自原阈值 | ✅ |

运行记录：

| 项 | 结果 |
|---|---|
| 基线（29a64ad，改之前）`swift test --package-path Packages/SwitcherInputs` | 110 = SwitcherInputsTests 60（6 跳）+ NDITests 25（2 跳）+ DeckLinkTests 25（3 跳），0 红 |
| 整包（bd2c6ce，03:05–03:10，机器空闲：负载 1.9） | **124 = SwitcherInputsTests 74（6 跳）+ NDITests 25（2 跳）+ DeckLinkTests 25（3 跳），113 过 + 11 跳 + 0 红**；跳的全是原有 BLOCKED-硬件 / SDK / 权限项 |
| 整包（最终代码 32875c8，03:19–03:24，负载 1.0） | **124 = 113 过 + 11 跳 + 0 红**（同上）；顺带的数：S2 循环斜率 −0.053 MB / 圈；W2A4 速率 8 十秒 401 圈、没跟上 0、晚醒 0、音频跳 0；ProRes 循环 20 圈断点 0 / 没跟上 0 / reused 0；往回定位跳 0 |
| App：`make gen` → `xcodebuild build-for-testing`（TEST BUILD SUCCEEDED）→ `test-without-building -only-testing:SwitcherTests/PlaybackStatusTests -only-testing:SwitcherTests/InputStripTests -only-testing:SwitcherTests/InputWiringTests` | **25 = 24 过 + 1 跳（摄像头权限 BLOCKED-权限）+ 0 红**（xcresult summary）；App 一行没改，只是用新的 SwitcherInputs 重编 |
| `make lint BRANCH=w2-inputs-5` | 归属一步按 main 算，把 115 的 25 个文件报越界后停（预期，prompt 已说明）；其余各项单独跑 ↓ |
| `scripts/lint-rules.sh` / `check-deps.sh` / **`check-ownership.sh w2-inputs-5 --base p5-contracts-4`** / `check-help.sh` / `check-links.sh` / `check-rt-symbols.sh`，C locale 与 `LC_ALL=en_US.UTF-8` 各一遍 | 两遍全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / **归属 9 个改动文件都在范围内**（加上本报告 10 个）/ 手册 18 个文件一致 / 200 个 Markdown 链接 / 实时符号 4 个目标文件 |

没跑：gate4 / perf-baseline / make soak（prompt 不让跑，同机有三个会话）；别的包（只依赖 SwitcherInputs 的是 App / headless / TestKit 的 harness，App 的三组跑了）。

---

## 3. 没做的和原因

1. **docs/KNOWN_ISSUES.md 的 D13 / D14 / D15 三行、D01 的 FileInput 那一半**：docs/ 不在本会话目录，留给 G10 销号（D01 那行：115 修了 API / 节目文件、本分支修了 FileInput 底层，合起来可以整行销）。
2. **App 的"添加输入"文件信息摘要**（`MediaFileInfo.loadMovie` 读 `naturalSize`）：竖拍的片子仍写编码尺寸（1920×1080），实际出帧是 1080×1920。App 不在本会话目录，归 App 会话（一行：按 `preferredTransform` 换宽高，或读 `FileInfo.displayWidth / displayHeight`）。
   `switcher-input-probe` 打印的 `info.width×height` 也是编码尺寸（Sources/switcher-input-probe 不在目录里）。
3. **任意角度（非 90° 整数倍）的方向矩阵不支持**：按编码方向原样出 + 提示。真实素材里基本没有；要支持得走 Metal 或合成输出，不值得。
4. **D14 的接续对重素材的余量没量**：窗口里开循环时解码线程才开下一圈 reader，1080p ProRes 进程里第一个 reader 要 113–133 ms（W2-A4 §5 第 1 条），可能比剩下的几帧长——
   结果是几拍"没跟上"（帧槽重复末帧、`ticksStarved` 计数），不会再进 noSignal。用例是 640×360 H.264（接续 0 拍没跟上）。
5. **W2-A4 §3 第 3 条（反方向：预开下一圈之后把循环改成停在末帧，hold 停在下一圈第 2 帧）没动**：不是这张 prompt 的条目，行为与 main 相同。
6. **定位过尾（≥ 时长）仍是"从头"**：沿用原口径，没改成"停在末帧"——见 §4 第 1 条，要用户定。
7. 探针程序没入库（scratchpad 的 probe1–5），结论在 §1.6；复现：ffmpeg 两条命令造片子，`swiftc -O` 编 20–100 行的探针，按表里四种读法各单独一个进程跑。

---

## 4. 对契约的疑问

1. **定位过尾怎么算**（要你定）：提案 031 写"文件本身的时长再由 FileInput 钳"。本分支按 prompt "先用 Double 钳到 [0, duration]"，钳完 ≥ 时长**沿用原来的"过尾 = 从头"**（`seek(toSeconds:)` 原注释"钳到 [0, 时长)"、`seek(toFrame:)` 同一条），
   所以 1e300、+∞ 和"10 s 文件定位 12.5 s"都是从第 0 帧播。若"钳"的本意是"停在末帧 / 按结束动作收尾"，改成 `target = 时长 − 一帧` 一行，用例那几处期望跟着改。建议维持（循环素材过尾 = 下一圈开头，最自然；hold 素材过尾停在末帧也说得通，两种都行）。
2. **NaN 速率按 1**（只告知）：契约说非有限 = 非法，API / 节目文件都拒；FileInput 底层收到 NaN 没有"往哪边钳"，按正常速度 1 播并提示。±∞ 按两端。
3. **`lastError` 多了非致命提示**（只告知）：钳位提示、方向提示在没有真错误时也从 `lastError` 出来；App 只在无信号格子第二行读它（W5-O），所以一段钳过速率的文件播完停在末帧时，格子会写"播放速率 … 按 0.1 播"。
   115 之后 App / 节目文件写不出越界速率，实际只有直连 FileInput 的地方看得到。要分开的话 `Input` 协议外再加一个只读属性，App 会话决定。
4. **FileInfo 加了三个成员**（`orientation` / `displayWidth` / `displayHeight`；SwitcherInputs 自己的公开类型，不是 SwitcherContracts，不走契约流程）：`width` / `height` 保持编码尺寸不变语义。
5. **Frame 没有方向字段**，所以在输入这边把像素转正（多一次搬运：1080p NV12 每帧 CPU +0.18 ms、内存 +13 MB 左右）。若将来要零拷贝（渲染器按矩阵采样），得给 `Frame` 加方向——那是契约变更，要提案；现在的代价不值得。

---

## 5. 下一个会话需要知道的坑

1. **D14 的触发条件要照 Codex 的探针写**：推到第 28 帧后再等 10 ms。不等的话解码线程还没读到尾（它要等推帧线程 pop 出空位才去读、读到 nil 才知道到尾），开关落在"读到尾之前"，走的是正常循环——
   旧代码上用例也是绿的。修后用例另用 internal 的 `decoderParkedAtEnd`（= 解码线程已放哨兵）确认真卡进了窗口。
2. **推帧线程的出队循环别再用 `!=` 判旧代**：快照是睡之前读的，比快照新的代必须留给下一轮（`<` 扔、`>` break）。小文件（重开 reader + 解首帧几 ms）才碰得上，pattern.mov 碰不上——写定位相关用例用小片段。
3. **刚进 live 就 `slot.latest(atOrBefore: now)` 会拿到 nil**：第一帧的 pts 在 pushLead（2 ms）之后，要等它到点（用例里的 `currentFrame` 轮询）。
4. **VT 先转再翻**；VT 自己会抄附件，PixelRotator 仍显式抄一遍、删 clean aperture / 像素宽高比 / 色度位置。'420f'、奇数宽高都收。
5. **`FileInfo.width / height` 是编码尺寸**，出帧尺寸看 `displayWidth / displayHeight`（黑场帧已改用它）。
6. **面计数（distinctSurfaces）**：转正的片子记的是 PixelRotator 池里的缓冲，跨循环稳定（夹具两圈 7 个）；不转的片子每圈新 reader 带新池，循环越多面数越多（同一夹具不转时两圈 23 个）——
   main 上就这样，渲染器纹理表每路 16 项，长循环的小片子会不停换纹理。没在本会话改。
7. **ffmpeg `-display_rotation 90` 打的是 (0, −1, 1, 0, 0, 0)**（逆时针 90°、没有平移）；手机竖拍是 (0, 1, −1, 0, h, 0)（顺时针 90°、带平移）。两种用例都有。造方向素材最省事的是 AVAssetWriterInput.transform（用例的 LoopClipWriter / AlphaMovieWriter 都加了 `transform:` 参数）。
8. **从 8 倍速切回低速的头几拍解码线程在追**（新锚点位置按 8 倍速往前算了两拍、比解码位置领先），帧号会差一两帧——main 上就这样，与钳位无关；D01 用例从锚点后第 10 拍起看。
9. **环境红**：`FileInputTests.testW2A4_prores_loopBoundary_noStarveNoSkip` 在同机另一个 xctest 占满一核时红过一次（20 圈里 1 个循环点空拍），循环路径本次没改，单独复跑绿（没跟上 0 / 跳帧 0 / reused 0）。
   KNOWN_ISSUES"测试与工具"的环境红名单目前只列 60 fps 连续、8 倍速带音频两条，建议 G10 把这条也加上（1080p ProRes 422 HQ 解码同样吃核）。
10. **G10 合并顺序**：先合 115（p5-contracts-4），再合本分支（叠在 29a64ad 上，`git merge-base` = 29a64ad）。本分支只动 SwitcherInputs 的 File/ 与它的测试、Tests/Fixtures，与 118 / 119 / 121 的目录不重叠；
    归属检查用 `--base p5-contracts-4`，`make lint BRANCH=w2-inputs-5` 按 main 算会把 115 的 25 个文件报越界。
11. 会话工具：`swift test --filter` 可以给多个（取并集），`--skip testD01` 能排掉会崩进程的；隔离 worktree 里带变量循环 / heredoc 的 Bash 会被拒，写成 scratchpad 脚本再跑；共用 scratchpad 的临时文件放 `w2a5/`。
