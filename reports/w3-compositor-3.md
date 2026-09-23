# W3-B2 合成三期收尾报告（多画面纯音频格 / 真实电平表 / 名字标签，删提案 010 的过渡读取）

分支 `claude/w3-compositor-audio-meters-labels-e0dba1`（桌面端开的 worktree 分支名；prompt 里叫 `w3-compositor-3`，本地另建了同名分支指向同一提交，
`check-ownership.sh w3-compositor-3` 用它查）。基线 main `4b7a3df`（P3 / W1-A3 / W2-A2 合入之后）。prompt：docs/plan/prompts/66-W3B2-多画面收尾.md。
机器：Apple M5 Max，macOS 26.6.2（25G83），Xcode 27.0（27A266a）/ Swift 6.4，**接电源**（100%）。
同机另有 W3-E2 的会话（worktree `w3-app-3-localize-p3-ec0049`）：16:12–16:14 在跑 xcodebuild、16:20 左右在编 frameprobe，计时数据都标了是否重叠。

提交（`git log main..w3-compositor-3`）：
`d9c6290` 测试的参考状态改走正式字段 → `10ddd6d` 删过渡读取 → `8bb4bde` 纯音频格 + 真实电平表（+ 提案，那时编号 016，后改 017）→ `b568ad4` 名字标签
→ `1a2ca7c` 问题单 → `c193fce` 可选项：输出环按需建 → `bcc9014` V1 诊断开关 → `590f7d9` 提案改号 016 → 017（W3-E2 先占了 016）→ 本报告。

只动了 `Packages/SwitcherCore/Sources/SwitcherRender/`、`Packages/SwitcherCore/Tests/SwitcherRenderTests/`、`Tests/References/`，外加
`docs/contract-changes/017`（提案，待批）、`reports/issues/W3B2-…`（问题单）和本报告。没改契约、没改 Package.swift、没动 App / headless。

---

## 1. 做了什么

| 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 纯音频格 | `MultiviewLayoutTable.parse(state:…)`（`MultiviewCellSpec.audioOnly`）、`CompositorPasses.encodeMultiview` | 不加契约：快照 sequence 变了解析布局时，同一次按 `InputConfig.kind == .audio` 标出纯音频格，渲染线程每帧查格子上的标记（零分配，布局表解析的零分配用例把纯音频状态也加进去了）。纯音频格 = tally 边框照常 + **深灰底 0.15（38/255）** + 电平表（**总是画，不看 `meters` 开关**）+ 左下名字；不画画面——输入表里万一还有这一路的帧（刚从摄像头换成纯音频）也不画。PGM / PVW 格切到纯音频输入时仍按"没帧"画黑（契约 §2.4 的口径不变） |
| 2 真实电平表 | `Renderer/MultiviewMeters.swift`（`MeterScale` / `MultiviewMeterTable` / `MultiviewMeterFeed`）、`CompositorPasses.drawMeter` / `drawMeterLevels`、`MetalRenderer.setMeters`、`OfflineRenderer.setMeters` | 接口与线程约定见 §1.1。输入格读 `meters.inputs[n]`，PGM 格读 master 总线，PVW 格读当前 PVW 那路输入；只有峰值 + 1 s 峰值保持（契约没有 RMS，见 §3 第 1 条、提案 017）；−60…0 dBFS；没数据的输入格就是 W3-B 的占位（逐像素不变），PGM / PVW 格没数据不画 |
| 3 名字标签 | `Renderer/LabelRenderer.swift` | 生成时机与上限见 §1.2。每格左下角名字（PGM / PVW 格 "PGM" / "PVW"）W1-C / W3-B 就有；本会话把切片改成按输入编号分槽、封顶 64，交接改成"渲染线程在帧开头接手"，改名的**下一帧**就是新名字。显示层 `MetalDisplayView(+Multiview)` 不画名字（查过），名字只在渲染器这一处 |
| 4 删过渡读取 | `CompositorPasses`（`OverlayDecoration`）、`MultiviewLayoutTable`、`MetalDisplayView+Multiview` | 边框只读 `OverlayState.border`，布局只读 `OutputSettings.multiview`；删掉的代码与改了的用例见 §1.3 |
| 5 可选：PVW 环按需建 | `Renderer/AuxOutputRings.swift`、`OutputBufferRing`、`MetalRenderer` | **做了**，PVW 和多画面两个环都按需建，见 §1.4 |
| 参考图 | `Tests/References/` 新增 2 张 + README 第三节 | `v8-multiview-audio-only-3x3.png`、`v8-multiview-meters.png`（人工看过，样子见 README）；旧 22 张一张没重生成 |
| 提案 | `docs/contract-changes/017-stats-audio-meters-rms.md` | `Stats.audio.meters` 加 `rms_db`，**待批**（没有改契约） |
| 问题单 | `reports/issues/W3B2-w3-app-3-multiview-meters-thumbnails.md` | 给合并 W3-E2 + W3-B2 的检查点：App / headless 的 `setMeters` 接线；输入条缩略图名字出现两次；两套电平表颜色 |

### 1.1 电平表数据通道：接口与线程约定

```swift
// SwitcherRender.MetalRenderer（实时）
public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now())
// SwitcherRender.OfflineRenderer（离线出图 / 测试；不判过期，用固定 time 结果可复现）
public func setMeters(_ meters: Stats.AudioCounters.Meters?, at time: HostTime = HostClock.now())
```

- **写端**：组装方在**非实时线程**调（主线程、Stats 汇总线程都行）；不许在音频实时回调里调（它分配、拿锁）。多条线程同时调按一把锁串行，渲染线程从不拿这把锁。
  写端把 `Stats.AudioCounters.Meters` 换成定长表：编号最小的 **64 路输入** + master 总线，每路 `(峰值 L, 峰值 R, 保持 L, 保持 R)`（dBFS，非有限数当 −120，
  单声道 `[x]` 两边都是 x，空数组当没有这一路），顺手算**峰值保持**（每个声道：新峰值 ≥ 保持值、或保持值定下已满 1 s → 换成新峰值；按 `time` 算），
  写进自己手里那块缓冲，一次原子交换发布。`nil` = 清掉（多画面退回占位；保持从头算）。
- **读端**：渲染线程每帧开头一次原子读；有新发布的再一次原子交换接手（只在 `options.multiview` 开时读）。零分配、不等、不锁（测过：`setMeters` 100 次期间渲染线程 0 分配，§2）。
- **为什么三块不是两块**：纯双缓冲下写端要复用读端刚放下的那块，就得先确认读端读完了（要么等、要么 seqlock 重读）；三块（写端一块、读端一块、交接一块）两边都不等，
  写端连写几次读端只拿最新那次。prompt 说的"固定大小的双缓冲表"语义不变，多出来的第三块是交接位。
- **过期**：实时路径 `拍点时刻 − 喂数时刻 > 3 s` 就当没有表（输入格退回占位、PGM / PVW 格不画），免得音频停了表冻在最后一个值；headless 1 Hz 喂，留 3 次余量。
- **频率**：1 Hz（每次 Stats 发布）就能用，但 1 Hz 下峰值保持基本等于当前值（下一个读数正好 1 s 后到）。想让表活一点，App 按调音台同一份 `AudioEngineStatus`（50 ms）
  拼一份同形态的 Meters 喂即可——渲染器不在乎频率。
- **画法**（`drawMeter`）：暗条（70% 黑，= W3-B 占位）→ 两个声道的峰值条（条区 = 暗条收 1 px，左右各一半、中间 1 px 缝；**< −18 dBFS 绿、−18…−6 黄、≥ −6 红**）
  → 保持线（1080p 下 2 px，颜色按它所在的分段）→ 四道刻度（表高 1/5…4/5 = −48 / −36 / −24 / −12 dBFS，= W3-B 占位的位置）。没有读数时调用序列与 W3-B 的占位完全相同，
  所以"没给表"逐像素等于 `v8-multiview-custom.png`（测过）。颜色分段是本会话定的：设计方案 §7 只写了"表：峰值 + 真峰值 + 响度"，**没有颜色表**（§4 第 2 条等拍板）。
- **调用点不在本会话**：App（W3-E2 已做完没合并，归合并它的检查点或 App 续做会话）、headless（检查点：`HeadlessRun` 每秒拿到 Stats 后加一行 `renderer.setMeters(stats.audio.meters)`）。接法写进了问题单。

### 1.2 名字纹理：生成时机与上限

- **生成时机**：渲染线程每帧 `noteSnapshot`，快照 sequence 变了才叫醒标签线程（`switcher.render.labels`，QoS userInitiated，**不再像 W3-B 那样先睡 20 ms 攒变化**）。
  标签线程按新状态解析一份布局表，算出"看得见的输入 → 槽 → 文字"；和渲染线程正在用的那套一样（例如只切了 PGM）就什么都不做；
  不一样就在渲染线程不用的那套上**只重画文字变了的切片**（CoreText → 512×48 BGRA 预乘 → `replace(region:)`），放进交接字，渲染线程**下一帧开头**接手。
  实测 60 fps：改名的快照第 91 拍第一次被渲染，标签线程在那一拍的拍点后 0.77–2.08 ms（debug）/ 0.90 ms（release）交接，**第 92 拍**的多画面 NV12 与离线渲染新名字逐字节相同。
- **交接字**（一个 `Atomic<UInt64>`）：`待接手(套)` / `在第 f 帧接手(套)`。渲染线程用一次比较交换把前者换成后者，标签线程用一次交换收回——同一套不会既被接手又被收回，
  接手的帧号和套号一起可见。标签线程要写另一套之前只等"第 f 帧之前的帧"在 GPU 上完成（一般早就完成了，最多等 2 s 防 GPU 卡死）；交出去没被接手的（多画面关了 / 引擎停了）直接收回重画。
  W3-B 的做法（等"当时已提交的所有帧"完成、按发布下标换套）理论上还有一个窗口：渲染线程在帧中途读到的那套可能被紧接着的第二次更新改写；新做法没有这个窗口。
- **上限**：每套最多 **64 个输入槽**（= 多画面布局表的格数上限，看得见的输入不会更多）+ "PGM" / "PVW" 两片；512×48×4 = 96 KB 一片，封顶 66 片 ≈ 6.3 MB 一套、两套 ≈ 12.7 MB。
  实际按输入表容量建（引擎 `maxInputs` 默认 16 → 渲染器 17 → 19 片 ≈ 1.8 MB 一套）。W3-B 是"切片下标 = 输入编号、切片数 = 输入表容量 + 2"，节目里编号给到 100 就是 103 片 ≈ 9.9 MB 一套，编号再大线性涨。
- **槽的分配**：只给多画面布局里看得见的输入（输入格去重、按格子顺序、状态里有这一路的才算）；上一套里已有槽的输入留在原槽（改名只重画一片），看不见的腾出槽，新出现的占第一个空槽。
  渲染线程按编号线性查槽（≤ 64 次比较），零分配。
- **显示层**：`MetalDisplayView` / `MetalDisplayView+Multiview` 只贴多画面纹理的一块，不另画名字——名字只有渲染器这一处，不用统一。App 输入条的标题栏另有名字（视频区外），
  而缩略图切的是含名字条的整个内框，所以输入条上名字会出现两次（main 与 `w3-app-3` 都是）；这是 App 的事，写进了问题单。

### 1.3 删过渡读取：删了什么、哪些用例改了

删掉：`OverlayDecoration.border(for: InputConfig?)`（效果格 "border" 的后备）、`EffectIDs`、`MultiviewLayoutTable.parse(layout:…)` 与 JSON 版 `parseCustom`、
公开 API `MultiviewLayout.layoutValue(in:)` / `MultiviewLayout.placements(layout:inputs:width:height:)`（仓库里没有别的调用方：App / Outputs 只用 `inputCell` / `monitorCell` / `grid`，改前 grep 过）。
`OverlayDecoration.border(for:)` 现在只看 `OverlayState.border`；`MultiviewLayoutTable.parse(state:…)` 只看 `settings.multiview`。`Show.load` 的搬迁留在契约里，没动。

| 用例 | 原来验什么 | 现在验什么 |
|---|---|---|
| `testP3_borderOfficialFieldMatchesEffectSlotPixelForPixel` → **`testP3_borderReadsOnlyOfficialFieldLegacyEffectSlotIgnored`** | 正式字段与效果格逐像素相同、正式字段优先 | 每组对照都留着，期望从"与效果格画的相同"换成：只有效果格（白边 / 红边 0.02）= 与没有边框逐像素相同；两边都给 = 与只给正式字段逐像素相同（红边像素在）；解析层 border 为 nil 不回落；宽度钳 0–0.1 |
| `testP3_officialMultiviewFieldMatchesLegacyExtraKey` → **`testP3_multiviewReadsOnlyOfficialFieldLegacyExtraKeyIgnored`** | 前一半：五个预设 + 自定义格子两条路径逐字 / 逐像素相同 | 前一半改成：只有过渡键（五个预设名、对象写法、自定义格子）时 `layoutSettings` 为 nil、格子表 = 默认布局、safeArea / meters 不起作用、渲染 = 默认布局逐像素；正式字段写法与 `Show.load` 搬迁结果逐位相同、渲染不是默认布局；两边都给只按正式字段。后一半（multiview 格忽略、非法格忽略、64 格截断）原样 |
| `testV8_pipBorderDrawnFromEffectSlot` → **`testV8_pipBorderDrawnFromOfficialField`**（W3-B） | 效果格画边框 | 同样的像素断言改用正式字段；解析断言改用 `resolve` |
| `testMultiview_defaultLayoutUnchangedAndUsedAsFallback`、`testV8_multiviewPreset_pgmPvw2x2` / `_3x3`、`testV8_multiviewCustomJSONLayout`、`testMultiview_safeAreaAndMeterPlaceholders`、`testMultiview_tallyBordersFollowState` | JSON 过渡键写布局 | 写法换成正式字段，断言不变；`CustomJSONLayout` 里"缺 rect 的格子"换成等价的"空 rect 的格子"，另加一条越界钳位的数值断言 |
| `testMultiview_layoutTableParseDoesNotAllocate` | 四种布局解析零分配 | 加了"只有过渡键"和纯音频两种状态，仍 0 分配 |
| `testMultiview_labelsIncludeProgramAndPreview` | `LabelPainter.wantedTexts` | 标签 API 换成 `LabelPainter.contents`（按槽），断言同义 |

测试工装：`ReferenceStates.withMultiviewLayout` 改写正式字段（旧写法留作 `withLegacyExtraLayout`），`customLayout` 改成 `MultiviewLayoutSettings` 常量（旧 JSON 留作 `customLayoutLegacyJSON`，
有断言钉住两者逐位相同），`pipBorder()` 与 V1 / T1 的 `LoadStates` 边框改走 `OverlayState.border`。**先改写法、过渡读取还在的时候跑一遍（22 张 PSNR ∞），再删读取（仍然 22 张 PSNR ∞）**，所以参考图一张没重生成。

### 1.4 可选项：PVW（和多画面）输出环按需建——做了

- P3 为了"状态里有要 PVW / 多画面帧的输出就自动填 `RenderedFrame`"，在 prepare 里把两个 NV12 环都建好（prepare 时没有状态、渲染线程又不许分配）。
- 现在：`options.previewOutput` / `multiviewOutput`（强制开）照旧在 prepare 里建；否则渲染线程第一次看到状态要它时只置一个请求位、敲一下信号量（零分配），
  后台线程 `switcher.render.aux` 建环、用 `AtomicLazyReference` 发布，渲染线程下一帧起拿来用；**建好就不拆**（直到下次 prepare / shutdown）。`multiview = false` 时多画面环永远不建。
- 环里每个缓冲的 NV12 目标纹理也在建环时包好（`OutputBufferRing` 给了 device 就预包；PGM 的环也是），渲染线程不再在第一次用到时建纹理。纹理表只剩输入：V1 负载 64 张（原来 80）。
- 实测（`testAux_previewRingBuiltOnDemandOffRenderThread`，debug 与 release 各一次）：第 61 拍状态第一次要 PVW，**第 62 拍起每帧都有 PVW**；后台建环 1 次、常驻 23 MB；
  多画面环没建；第 40–120 拍渲染线程 SwitcherRender 代码 0 次分配、建缓冲 / 包 IOSurface 纹理相关的分配 0 次。
- 省下的内存：没有 PVW / 多画面帧输出的节目（App 的多画面窗口走纹理、不走 NV12，所以常见情况就是这样）两个环都不建，1080p / ringSize 8 共约 **50 MB**（每个 24.9 MB），4K 约 200 MB。
- **"在状态线程建"做不到**：渲染器看不到引擎的状态线程（`Renderer` 协议只有 prepare / render / shutdown，快照只在 render 里递进来），要在状态线程建就得改协议或让组装方另调接口。
  这里的后台线程是渲染器里离"状态变化"最近的地方：渲染线程看到新快照的那一帧就叫醒它。代价是状态第一次要 PVW 的那一拍没有 PVW 帧（契约允许 nil），实测只差 1 拍。

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

`swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests`（debug）：**91 个用例 0 失败**（W3-B / P3 的 79 个 + 本会话 12 个），见 §7 的运行记录。

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| **V8** `testV8_multiviewAudioOnlyCellPlaceholder`（新参考图 `v8-multiview-audio-only-3x3`） | 参考图 PSNR ∞ / SSIM 1.0000；纯音频格三处取样 = 38 ± 1（深灰，不是黑；输入表里给了它 stinger 图的帧也没画）；电平表暗条 ≈ 11、1/5 处刻度 > 100；左下标签条 ≈ 17、有白字 > 200；**meters = false** 时输入 7 格同一位置仍是青色内容（没有表），纯音频格有表；meters = true 时输入 7 格出现暗条、纯音频格逐像素不变（每 7 px 取样）；给它 −10 dBFS 读数后条中段绿、0.78 处黄 | PSNR ∞（prompt）/ 测试标准 ≥ 40 dB 或 ≥ 0.98 | ✅ |
| **V8** `testV8_multiviewMetersFromStats`（新参考图 `v8-multiview-meters`） | 参考图 PSNR ∞；**没给表 → 与 `v8-multiview-custom.png` 逐字节相同**；喂过再 `setMeters(nil)` → 又逐字节相同；三路电平：输入 1（−3 / −5）顶进红区、R 条顶之上是暗条；输入 3（−14 / −16）黄；输入 4（−33 / −40）绿 + 0.65 处保持线、条与线之间是暗条；输入 2 / 5 没读数 = 占位逐像素；PGM 格（Master −9 / −10）黄、条顶之上 = 画面 × 0.3；PVW 格（输入 2 没读数）不画；meters 关时读数不起作用 | 同上 | ✅ |
| `testMultiview_meterTableUpdateDoesNotAllocateOnRenderThread` | `setMeters` 100 次（每 5 ms）都落在第 60–150 拍的计数窗口里，渲染线程接手新表 37–41 次；**SwitcherRender 代码 0 次**；全部 Swift 代码：debug 2184 次（全是契约 `MixerState.tally(ofInput:)` 的 -Onone 装箱，与 T1 debug 的已知现象相同），**release 0 次** | 0（release 全部 Swift 0） | ✅ |
| 名字标签 `testMultiview_labelRenameShowsNextFrameWithoutRenderThreadAllocation` | 60 fps，第 91 拍第一次用改名的快照；标签线程在拍点后 0.77 / 2.08 ms（debug 两次）、0.90 ms（release）交接；**第 92 拍多画面 NV12 = 离线渲染新名字逐字节**，第 91 拍是新旧之一；第 60–120 拍 SwitcherRender 0 次分配，全部 Swift：debug 2928（同上，契约 tally）、release 0 | 下一帧更新；0 分配 | ✅ |
| `testMultiview_labelSlotsKeyedByInputNumberCappedAt64` | 默认布局 8 路占 8 槽；3×3 只给看得见的 1–7、改名不换槽、看不见的腾槽；新输入占第一个空槽；状态里没有的编号不占槽；70 路 × 64 格 → 64 槽；`LabelSet(inputSlots: 1000)` 只建 66 片 | — | ✅ |
| `testMultiview_labelHandshakeTakesBackUnadoptedSetAndWaitsForInflightFrames` | 画好交出、第 10 帧接手；改名时第 10 帧之前的帧没完成就不写另一套（0.2 s 内不交接），完成后交接；交出去没被接手时再改名 → 收回同一套重画；名字没变的快照不交接 | — | ✅ |
| `testP3_borderReadsOnlyOfficialFieldLegacyEffectSlotIgnored`（原 `…MatchesEffectSlotPixelForPixel`） | 见 §1.3 | — | ✅ |
| `testP3_multiviewReadsOnlyOfficialFieldLegacyExtraKeyIgnored`（原 `…MatchesLegacyExtraKey`） | 七种过渡键写法 → 默认布局逐像素；其余见 §1.3 | — | ✅ |
| V8 参考图全集 `testV8_generateOrCompareAllReferences` | **24 张全部 PSNR ∞ / SSIM 1.0000**（旧 22 张没重生成 + 新 2 张） | ≥ 40 dB 或 ≥ 0.98 | ✅ |
| `testMultiview_audioOnlyFlagsFollowSnapshot`、`testMultiview_meterScaleAndColorSegments`、`testMultiview_meterFeedHoldCapacityClearAndStaleness`、`testMultiview_realtimeMetersMatchOffline` | 标记跟快照走（PGM / PVW 格不算）；刻度钳位与分段边界（−18 起黄、−6 起红）；保持 1 s 各声道独立、单声道 / 空 / 非有限、64 路截断、连写只取最新、3 s 过期、清掉后保持从头算；实时（带表 + 纯音频格）与离线多画面 NV12 逐字节相同 | — | ✅ |
| `testAux_previewRingBuiltOnDemandOffRenderThread`（可选项） | prepare 后两个环都没建；第 61 拍请求 → 第 62 拍起每帧有 PVW；多画面环不建；建环 1 次、23 MB；渲染线程 SwitcherRender 0 次、建环 / 包纹理 0 次（debug、release 各一次） | 0 分配 | ✅ |
| `testAux_forcedOutputsBuildAtPrepareAndMultiviewOffNeverBuilds` | 强制开 → prepare 里建好（后台建环 0 次）；`multiview = false` 时状态要也不建、不填 | — | ✅ |
| **T1** `testT1_renderThreadSteadyStateAllocations`（release，标准负载，600 帧） | 共 8414 次（每帧 14.02），**SwitcherRender 0、全部 Swift 0**，其余全在 AGX 驱动 / IOGPU；纹理表预热 64 张、输出环退回 0 次。**main（4b7a3df）同一测试也是 8414 次**（从 `git archive main` 的副本跑的）——W3-B 报告的每帧 12 次到 14 次是 P3 自动填多画面 NV12 之后就有的，不是本分支加的 | SwitcherRender 0；release 全部 Swift 0 | ✅ |
| **V1** `testV1_1080p60EightInputsFourOverlays_renderMs`（release，30 s，去前 60 帧；标准负载 = W3-B 的：8 路 + 4 叠加抠像 + 自定义多画面，电平表占位） | 三轮平均 **2.595 / 2.321 / 2.235 ms**，p99 3.563 / 2.868 / 5.243（第三轮与 W3-E2 编 frameprobe 重叠），最大 ≤ 11.2，skipped 0；GPU 执行 1.57–1.74 ms | 必须：平均 ≤ 6、p99 ≤ 12；目标 ≤ 4 / ≤ 8 | ✅（必须 / 目标都过） |
| V1 诊断 `SWITCHER_V1_METERS=1`（同一负载 + 另一条线程按 20 Hz 喂真实读数：5 个输入格 + PGM 格画真实电平） | 五轮平均 2.196 / 2.249 / 2.362 / 2.050 / 2.072 ms，p99 2.862 / **7.048** / 2.655 / 2.546 / 2.458；GPU 执行 1.48–1.52 ms（不比占位高）；**第二轮（16:18:22）出现 1 次 skipped、最大 17.2 ms，V1 用例里"标准负载下不该跳拍"那条断言红了**；其余四轮 skipped 0 | 同上 + skipped 0 | ⚠️ 5 轮里 1 轮红（见下） |
| V1 对照 `SWITCHER_V1_LEGACY_LOAD=1`（W1-C 的负载） | 两轮 2.297 / 1.979 ms，p99 3.663 / 2.556 | — | — |

**关于那一轮 skipped**：一帧 GPU 完成拖到拍点后 17.2 ms，下一拍在途满了跳过——这正是 `reports/issues/G2-w1-compositor-gpu-preemption-skips.md` 记的现象（GPU 被抢占 / 完成线程被饿时孤立的跳拍）。
同一诊断负载另外四轮 0 跳拍，真实电平表的 GPU 执行时间（1.48–1.52 ms）和 CPU 编码时间（拍点→提交 0.09–0.22 ms）都不比占位高，没有证据指向电平表；但也没法证明与它无关，所以照实记为"5 轮 1 红"。
默认的 V1（不喂表）三轮都过。建议 G5 用 headless 场景（喂 `setMeters`）在安静的机器上重量一次。

其他：`make lint BRANCH=w3-compositor-3` 的三项（禁词 / 版本号 / Package.swift 约束、依赖方向、目录归属：含本报告 25 个改动文件都在允许范围内）全绿。
六个包的 `swift test`、两个工具的冒烟、`make build`（含 App）见 §7。

---

## 3. 没做的和原因

1. **RMS 做不到**：prompt 要"峰值与 RMS"，但契约 `Stats.AudioCounters` 的输入只有 `peak_db`、总线只有峰值 / 真峰值 / 响度，混音器（`AudioMixer.meters`）也不算 RMS；
   渲染器不能自己算（铁律 4）。写了提案 **017**（`rms_db`，300 ms 一阶平均，影响 Contracts / SwitcherAudio C 热路径 / Integration / 渲染器一处画法），**等你批**，没有动契约。
   现在只画峰值 + 峰值保持；总线的 `lufs_m` 口径不同（K 加权、声道合并、单位 LUFS），没有拿它冒充 RMS。
2. **`setMeters` 的调用点**：按 prompt 不做（App 归 W3-E2——它已做完没合并，所以落到合并它的检查点或 App 续做会话；headless 归检查点）；接口、线程约定和一行接法写在 §1.1 和问题单里。
3. **"在状态线程建环"**：渲染器看不到状态线程（§1.4），放在渲染器自己的后台线程。
4. **电平表颜色分段**：设计方案 §7 没有颜色表，本会话按常见的广播表定了 −18 / −6 两个分段点（−6 与 App 调音台 MeterBar 的红线同一处），等拍板（§4 第 2 条）。
5. **App 的输入条缩略图**：main 上按默认布局几何切多画面（多画面输出换了布局就切错；W3-E2 的分支 `w3-app-3` 已改成按布局切）、名字出现两次（两个分支都是）——
   都在 App/，写进问题单（W3-E2 已经做完没合并，所以归合并这两个分支的检查点），没动。纯音频输入的缩略图 W3-E2 是藏掉显示视图、画 App 自己的占位，和渲染器的纯音频格不会叠在一起。
6. **`make test-app`**（App 的 xcodebuild test 会弹窗抢屏幕）没跑；`make build` 里的 App 编译跑了（§7）。

---

## 4. 对契约的疑问

1. **提案 017（RMS）**：批不批？批了之后渲染器改一处画法（RMS 实心条 + 峰值 2 px 线 + 保持线），`v8-multiview-meters.png` 重生成。
2. **电平表的刻度与颜色、PVW 格读哪一路**：本会话定的是 −60…0 dBFS 线性、< −18 绿 / −18…−6 黄 / ≥ −6 红；PGM 格 = master 总线，PVW 格 = 当前 PVW 那路输入的读数（不是耳机总线）。
   这不是契约字段，但 App 里已经有两套：调音台的 MeterBar（W3-E：两段、−6 以上红）、`w3-app-3` 纯音频缩略图的 `NSLevelIndicator`（−6 警告、约 −1.8 危险），
   和多画面这套（−18 黄、−6 红）最好统一。建议在设计方案 §7 补一张表，三处照着改。
3. **契约里三处注释过期**（契约会话改，本会话没动）：
   - `Show.migratingLegacyKeys()` 的注释"没有叠加通道用这路输入时不动（渲染器的后备路径还认它）"——后备已经删了；
   - `docs/CONTRACTS.md` §2.4 末尾"渲染器保留读它一个版本作后备"——同上；
   - `MultiviewLayoutSettings.meters` 的注释"输入格右侧画电平表占位条"——现在是真实电平，PGM / PVW 格有读数也画，纯音频格不看这个开关。
   另外：搬迁时"没有叠加通道用到的 border 效果格"原样留着，后备删了之后它是死数据（以后把这路放进叠加也不会有边框）。要不要搬迁时换个去处或清掉，请契约会话定。
4. **过渡键从 API 进来**：`addOutput` / `setOutputSettings` 直接带 `extra["layout"]` 的客户端（没经过 `Show.load`）现在会静默得到默认布局。
   建议状态机（reducer）对这两条命令也跑一次 `OutputSettings.migratingLegacyKeys()`，或命令校验拒绝带旧键的命令（W3-D / 契约会话）。

---

## 5. 下一个会话需要知道的坑

1. **"没给表 = W3-B 的占位，逐像素"靠 `drawMeter` 的调用序列**：暗条 →（有读数才画条和保持线）→ 四道刻度，几何都从 `meterStrip` 来。改画法时 levels == nil 那条路径的调用序列不能变，否则 `v8-multiview-custom` 等参考图会变。
   PGM / PVW 格没读数时**不画**表（W3-B 起这两格就没有占位条）——`v8-multiview-custom` 依赖这一点。
2. **峰值保持在写端算**，按 `setMeters` 的 `time`；1 Hz 喂时保持线基本看不出来。离线渲染用固定 `time`，参考图可复现；实时路径 3 s 没喂新数就当没有表。
3. **标签切片下标不再是输入编号**：用 `LabelSet.slice(forInput:)`；PGM / PVW 是 `programSlice` / `previewSlice`（= 槽数、槽数 + 1）。
   `LabelRenderer.acquire(frame:)` 每帧调一次、在编码之前、`frame` = 这一帧要提交的序号（跳拍时同一序号会被下一帧复用，没关系）。
4. **"改名下一帧生效"是个延迟断言**：标签线程要在 16.7 ms 内画完交接（实测 < 2.1 ms）。机器极忙、标签线程被饿时这条用例可能红——那是调度问题，不是阈值问题。
5. **输出环按需建**：状态第一次要 PVW / 多画面帧的那一拍没有这一路帧（`RenderedFrame.preview / .multiview` 为 nil），消费者（NDI 的 PVW / 多画面发送、外部显示）要能接受开头缺一两帧；
   建好不拆。新建 `OutputBufferRing` 要给 `device` 才会预包纹理，不给就回到"第一次用时在渲染线程建纹理"。
6. **只生成新参考图**：`SWITCHER_GEN_REFERENCES=1 swift test --package-path Packages/SwitcherCore --filter <新用例>`。`scripts/gen-references.sh` 默认重写全部 24 张（像素不变但 PNG 字节可能变）。
   `MultiviewMetersTests` 里跟旧图比用的是只读的 `assertEqualsReference`，生成模式下不会改写旧图。`V8ReferenceTests.compare` 改成了 static（别的测试类也用），共用离线渲染器，结束时 `setMeters(nil)`。
7. **release 下跑测试要用 `swift test -c release`**：`swift build -c release --build-tests` 编不过 `@testable import`（没开 testability），SwitcherContractsTests 第一个报错。
8. **V1 诊断开关** `SWITCHER_V1_METERS=1`：另一条线程按 20 Hz 喂表；默认负载仍是 W3-B 的占位表，与 W3-B / P3 的数字可比。
9. **同机别的会话**：计时前照 P3 报告 §5 第 9 条先看一眼 `pgrep`；本会话的 V1 第三轮与 W3-E2 编 frameprobe 重叠（p99 5.2 ms），在表里标了。
10. **新 worktree 跑 TestKit / frameprobe 会死在 dyld `_swift_initBorrow`**：这两个没有入库的 Package.resolved，swift-collections 解到 1.7.0。
    本地绕法 `swift package --package-path Packages/SwitcherTestKit resolve swift-collections --version 1.6.0`（frameprobe 同理），跑完删掉生成的 Package.resolved；正式修法 W3-C2 记在它的问题单里。
11. **提案编号先查别的分支**：同一天从同一个 main 开的会话会撞号（本会话的 RMS 提案原来也写 016，与 W3-E2 撞了）。写之前 `git ls-tree --name-only <分支> docs/contract-changes/` 看一眼 w3-* 分支。

---

## 6. 复现

```bash
swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests                          # 全部，debug，约 6 分钟
swift test --package-path Packages/SwitcherCore --filter 'MultiviewMetersTests|MultiviewLabelTests|AuxRingOnDemandTests'
swift test -c release --package-path Packages/SwitcherCore --filter 'testV1_|testT1_'                 # V1 / T1 的报告数字
SWITCHER_V1_METERS=1 swift test -c release --package-path Packages/SwitcherCore --filter testV1_       # 喂真实电平表的 V1
SWITCHER_V1_LEGACY_LOAD=1 swift test -c release --package-path Packages/SwitcherCore --filter testV1_  # W1-C 的负载
SWITCHER_GEN_REFERENCES=1 swift test --package-path Packages/SwitcherCore --filter 'testV8_multiviewAudioOnlyCellPlaceholder|testV8_multiviewMetersFromStats'   # 只重生成本会话的两张
```

## 7. 运行记录

机器：Apple M5 Max / macOS 26.6.2（25G83）/ Xcode 27.0（27A266a）/ Swift 6.4，接电源；开机 7 天。本分支顶 `183a0cf`（报告提交之前），全部在本 worktree 里跑。

| 时间 | 做了什么 | 结果 |
|---|---|---|
| 13:49 | 基线：main 上 `SwitcherRenderTests`（debug） | 79 个 0 失败、22 张 PSNR ∞ |
| 14:39–14:44 | 标签那一步之后的全量 `SwitcherRenderTests`（debug） | 89 个 0 失败（320 s） |
| 16:13–16:14 | release 零分配五条（T1、表、标签、Aux、布局解析）；同一时段 W3-E2 在跑 xcodebuild（零分配是计数，不受影响） | 5 个 0 失败，全部 Swift 0 次 |
| 16:14–16:15 | T1（release）在 `git archive main` 的副本上跑 | 8414 次 / 600 帧，与本分支相同 |
| 16:16–16:19 | V1（release）六轮：W1-C 负载、标准、喂表、标准、喂表、W1-C 负载（机器安静） | 见 §2；喂表第二轮 1 次跳拍 |
| 16:19–16:21 | V1 再跑四轮：喂表、标准、喂表、喂表（第二、三轮与 W3-E2 编 frameprobe 重叠） | 见 §2；0 跳拍 |
| 16:22–17:07 | 六个包 `swift test`（逐包，失败了也往下跑）、`make test-tools`、`make build`（含 App 的 xcodebuild） | 见下 |
| 17:08–17:16 | TestKit 与 frameprobe 把 swift-collections 钉回 1.6.0 之后重跑 | 69 个 0 失败；两个工具冒烟都过 |

六个包（debug）：

| 包 | 用例 | 失败 | 说明 |
|---|---|---|---|
| SwitcherCore | 254（Contracts 73 跳 1、Engine 90、**Render 91**） | 0 | |
| SwitcherInputs | 105（跳 11：硬件 / SDK） | 0 | |
| SwitcherAudio | 103（跳 5） | 0 | |
| SwitcherOutputs | 80（跳 8） | **1** | `StreamingTests.ThrottleProxyTests.testBlockStopsForwardingAndCloses`（第 105 行"放开后旧连接应当已被代理关掉"）——就是 `reports/issues/W1E2-w2-stream-throttle-proxy-close-flaky.md` 记的那条间歇失败；StreamingTests 不依赖 SwitcherRender，本分支也没动 SwitcherOutputs / 契约。单独重跑三次：过、红、红（同时在跑 Control 的用例）。依赖渲染器的 ExternalTests 6 个 0 失败 |
| SwitcherControl | 56（跳 1） | 0 | |
| SwitcherTestKit | 69 | 0 | 第一次跑 dlopen 失败（`Symbol not found: _swift_initBorrow`）：新 worktree 里 SwitcherTestKit / frameprobe 没有入库的 Package.resolved，swift-collections 解到 1.7.0，macOS 26.6.2 的运行时没有这个符号（W3-C2 记过的环境问题）。把这两个未跟踪的 Package.resolved 钉回 1.6.0 重跑就过了，跑完删掉了，没有入库 |

合计 667 个（= 上次检查点的 655 + 本会话新加的 12），失败 1 个（上面那条已知的间歇失败）。
`make test-tools`：switcher-headless 冒烟过；frameprobe 第一次同样死在 `_swift_initBorrow`，钉版本后冒烟过（输出 `frameprobe 0.1.0`）。
`make build`：六个包 + 两个工具 + App（xcodebuild）都编过，退出码 0；日志里四处 "the following command failed with exit code 0 but produced no further output" 是 Xcode 27 构建系统对带警告文件的提示，不是失败。
`make lint BRANCH=w3-compositor-3` 的三个脚本：禁词 / 版本号 / Package.swift 约束过，依赖方向过，归属含本报告 25 个改动文件都在允许范围内。
`make test-app` 没跑（App 的 xcodebuild test 会开窗口抢屏幕，W3-B / P3 也没在功能会话里跑）。
