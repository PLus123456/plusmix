# W3-B 合成二期报告（叠加、抠像、Wipe / Zoom / Stinger、多画面）

分支 `claude/w3-compositor2-a505b2`（桌面端开的 worktree 分支名；prompt 里叫 `w3-compositor2`，本地另建了同名分支指向同一提交，`check-ownership.sh w3-compositor2` 用它查）。
基于 main `f1bd1ee`（G3 合入后）。
机器：MacBook Pro M5 Max（40 核 GPU），macOS 26.6.2（25G83），Xcode 27.0（27A266a）/ Swift 6.4，内置屏 120 Hz。
**本会话的性能数字是在电池供电（100%）下测的**（W1-C 和 G3 都接着电源），见 §2 的 V1 说明。

## 1. 做了什么

只动了 `Packages/SwitcherCore/Sources/SwitcherRender/`、`Tests/SwitcherRenderTests/`、`Tests/References/`，外加两份契约提案（`docs/contract-changes/009`、`010`）和本报告。没改 Package.swift、没改契约。

| 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 Overlay 1–4 | `Renderer/CompositorPasses.swift`（`encodeOverlays`、`OverlayRenderer`、`OverlayDecoration`） | 位置 / 尺寸按契约 `rect`；进出动画按 `animation.kind` 解释 `animProgress`（进度由 W1-B 的状态机按拍推）：cut = p > 0 全显，fade = 不透明度 p，slide = 从离 rect 最近的边平移进来（并列时底 > 顶 > 左 > 右，整幅 rect 从底边——下三分之一自然向上滑入），zoom = 绕 rect 中心缩放到 p 倍。画中画任一输入；边框来自该输入效果链里的 `EffectSlot(id: "border", params: {width, color})`（提案 010 的过渡做法）。每通道独立（只看自己的 on / animProgress）。PVW 预览：`MetalRendererOptions.overlaysInPreview`（离线同名属性）打开时 PVW 画同一套叠加，默认关。锚点：契约没有字段，缩放一律绕中心，进提案 010 |
| 2 抠像 | `Shaders/Compositor.metal`（`applyKey`）、`CompositorPasses.Keyer` | 提案 009 的口径：BT.709 (Cb, Cr) 平面上到键色的距离，半径 = tolerance × 0.5 内全透，柔化带宽 = softness × 0.25 用 smoothstep，留下的像素减掉色度在键色方向的正分量（× spillSuppression），亮度不变，输出预乘。对该输入出现的每一处生效（PGM 底、转场新画面、叠加、PVW、多画面缩略图）；下采样路径逐采样点抠。参数就是契约里现成的 `InputSettings.keyer`，**不需要加字段**，提案 009 只是把四个数的意义钉死 |
| 3 转场 | `CompositorPasses.encodeTransition`、`TransitionRenderer`、`Compositor.metal`（`wipeAlpha`） | 全部只读快照的 `progress`（状态机只在拍点边界推进；Cut 仍是原子换号，渲染器永远只画底）。Wipe：五个方向 + 软边，新画面整幅画上，片段按自己在目标里的位置算遮罩（硬边 step / 软边 smoothstep，擦边位置 = 进度）。Zoom：新画面绕画面中心按进度缩放（尺度 = 进度），输入自己的平移按同一比例缩。Stinger：`stinger.input` 整幅带 alpha 叠在最上（§5 顺序里在叠加之下），底在 stinger 第 max(cutAtTick, 1) 拍换成新画面（第 0 拍是应用命令的那一拍，什么都不叠；cutAtTick ≥ 时长时过渡期间不换，完成时由状态机对调）。切向黑场（preview = 0）三种都按进度压黑 |
| 4 多画面 | `Renderer/MultiviewLayoutTable.swift`、`Display/MetalDisplayView+Multiview.swift`、`CompositorPasses.encodeMultiview` | 布局来自 kind = multiview 的输出的 `settings.extra["layout"]`（提案 010 过渡做法）：预设 `pgmPvw+grid`（默认，= W1-C 几何）/ `pgmPvw+4x2` / `pgmPvw+2x2` / `3x3` / `4x4`，或对象 `{"preset", "safeArea", "meters"}`，或自定义 `{"cells": [{"source": "program" \| "preview" \| n, "rect": {…}}], …}`。每格 tally 边框 + 名字（PGM / PVW 格也有标签，LabelSet 末尾多两个固定切片）+ 可选安全框（EBU R95：3.5% 动作安全、5% 字幕安全）+ 可选电平表占位（右侧暗条 + 四道刻度；真实电平在 Stats 里，铁律 4，这里只画位置）。解析只在快照 sequence 变了时做一次，进 64 格的定长表，渲染线程零分配（测试用 malloc 钩子证明）。App 的 `MultiviewLayout.inputCell / monitorCell` 几何一个字节没变，新加 `placements(layout:inputs:width:height:)` 给任意布局的格子 |
| 4′ 多画面 / PVW 作为一帧送出去 | `MetalRenderer`（`previewOutput` / `multiviewOutput`）、`OfflineRenderer` | 打开后各多一个 NV12 输出环和一趟 RGB→NV12（三张画面共用一个 compute encoder），`RenderedFrame.preview / multiview` 非 nil，PTS = 拍点时刻；外部显示 / 独立窗口本来就走 `MetalDisplayView(target: .multiview)` 的纹理路径，NDI（W3-C）拿 `RenderedFrame.multiview` 即可。默认关，V1 基线不受影响。离线渲染总是产三份 NV12（`OfflineRenderResult.previewNV12 / multiviewNV12`），实时与离线逐字节相同（AuxOutputTests） |
| 5 参考图集 | `Tests/References/`（17 张新图 + 重生成 1 张）、README | 每张为什么这样见 README 第二节；W1-C 的 fixed / fade50 / ftb100 / preview 四张逐像素不变（PSNR ∞），`v8-fixed-multiview` 只因 PGM / PVW 两块新标签重生成（对旧图 PSNR 31.6 dB / SSIM 0.994） |

其他：`DrawUniforms` 112 → 144 字节（加 keyer / wipe / targetSize，两边 static_assert）；下采样路径的 half 累加逐位保持 W1-C 的写法（否则画中画 / 缩略图的参考图会差 ±1）；`LabelSet.init(device:inputSlices:)` 语义变了（内部多两个切片）。

## 2. 测试（`swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests`）

新加 5 个测试文件 36 个用例 + V8 参考图 10 个用例；连同 W1-C 的 27 个，SwitcherRenderTests 共 72 个，全过（debug）。release 只跑 V1 / T1（报告数字）。

| 测试 ID / 函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| **V6** `testV6_cutLandsOnExactTick_20runs`（时长 / 起始拍确定性随机 20 组） | 20/20：第 n 拍起全是新输入，之前全是旧输入，逐像素 Y ∈ {71, 181}，无混合帧 | 恰好第 n 拍，无混合帧（硬性） | ✅ |
| V6 `testV6_fadeFirstMixedFrameAtNextTickCompletesAtDuration_20runs` | 20/20：命令拍（progress 0）纯旧、第 s + 1 拍起混合、第 s + d 拍起纯新、覆盖率单调 | 同上口径（auto 转场的"新输入出现"= s + 1，完成 = s + d） | ✅ |
| V6 `testV6_wipeFirstMixedFrameAtNextTickCompletesAtDuration_20runs`（五向 × 硬 / 软边随机） | 20/20 | 同上 | ✅ |
| V6 `testV6_zoomFirstMixedFrameAtNextTickCompletesAtDuration_20runs` | 20/20 | 同上 | ✅ |
| V6 `testV6_stingerUnderLayerCutsAtConfiguredTick_20runs`（cutAtTick 0 … d + 1 随机，含越界） | 20/20：透明角落恰在第 s + max(c, 1) 拍（c ≥ d 时第 s + d 拍）从 71 变 181，带子区域过渡期间是 stinger 颜色 | 底恰在指定拍换 | ✅ |
| **V7** `testV7_fadeProgressCurveWithinOneFrame`（30 拍） | 最大 0.182 帧，单调 | ≤ 1 帧 | ✅ |
| V7 `testV7_wipeProgressCurveWithinOneFrame`（五向 × 软边 0 / 0.1，30 拍） | 硬边：左右 0.016、上下 0.000、对角 0.000 帧；软边 0.1：左右 0.015、上下 0.017、对角 0.205 帧；全部单调 | ≤ 1 帧 | ✅ |
| V7 `testV7_zoomProgressCurveWithinOneFrame`（30 拍） | 最大 0.031 帧，单调 | ≤ 1 帧 | ✅ |
| V7 `testV7_tbarMappingWipeAndZoom`（25 / 50 / 75%） | Wipe 0.2500 / 0.5000 / 0.7500，Zoom 0.2500 / 0.5000 / 0.7500，误差 0.00% | ≤ 2%（目标 1%） | ✅ |
| **V8** 参考图 22 张 `testV8_generateOrCompareAllReferences`（W1-C 5 张 + 本会话 17 张） | 全部 PSNR ∞ / SSIM 1.0000（刚生成） | ≥ 40 dB 或 ≥ 0.98 | ✅ |
| V8 结构性（不依赖参考图）`testV8_overlayOrder_channel1BelowChannel3WhenOverlapping`、`testV8_pipPositionFollowsRect`（4 个位置）、`testV8_pipBorderDrawnFromEffectSlot`、`testV8_slideAndZoomAnimationsRender`、`testV8_wipe50EachDirectionRevealsExpectedHalf`、`testV8_zoom50NewPictureIsCenteredHalfSize`、`testV8_stingerMidpointShowsNewUnderAndStingerOnTop`、`testV8_multiviewPreset_pgmPvw2x2` / `_3x3`、`testV8_multiviewCustomJSONLayout` | 全部逐像素成立 | — | ✅ |
| **V8 抠像** `testV8_keyerGreenScreenEdgeIoUAtLeast095`（绿幕合成图：光照 ±7% / ±5% + 噪声 ±6；前景圆盘 / 圆环 / 三条 14 px 斜条 / 矩形，1 px 抗锯齿边；alpha 由黑底 / 白底两次渲染反推） | 掩膜（α ≥ 0.5）IoU **0.9919**；边带（参考边缘 ±3 px 内）IoU 0.9188；抠出 437625 px 对参考 434069 px（胖 0.8%，边缘约 0.3 px）；背景全透、前景颜色逐电平保留 | ≥ 0.95 | ✅ |
| 抠像 `testKeyer_spillSuppressionRemovesKeyHueFromEdges` | 白前景边缘像素（参考 α 0.4–0.7）的 G − (R+B)/2：spill 0 → 72.8，spill 1 → 0.1 | 自定：spill 1 < 3 且 < 1/3 | ✅ |
| 抠像 `testKeyer_softnessAndToleranceBehaveMonotonically` | 中间 alpha 像素数 softness 0 → 0，0.6 → 3220；容差 0 留下 > 50% 背景；容差 1 只剩蓝圆环（< 5%） | 自定 | ✅ |
| 抠像 `testKeyer_disabledLeavesPixelsUntouched`、`testKeyer_appliesAsProgramPreviewAndInMultiview` | 关掉逐像素等于无 keyer；PGM / PVW / 缩略图里背景都是黑 | — | ✅ |
| 叠加 `testOverlay_animationPlacementRules`（纯函数）、`testOverlay_previewShowsOverlaysWhenOptionOn`、`testOverlay_channelsAreIndependent` | 全部成立 | — | ✅ |
| 多画面 `testMultiview_defaultLayoutUnchangedAndUsedAsFallback`（认不出的布局 = 无布局逐像素一致；placements = inputCell / monitorCell 逐位相等）、`testMultiview_safeAreaAndMeterPlaceholders`、`testMultiview_tallyBordersFollowState`、`testMultiview_labelsIncludeProgramAndPreview` | 全部成立 | — | ✅ |
| 多画面零分配 `testMultiview_layoutTableParseDoesNotAllocate`（malloc 钩子，四种布局各解析 5 次） | 20 次解析共 45 次分配，**SwitcherRender 代码 0 次**（其余是测试自己的循环 / 数组） | 0 | ✅ |
| 多画面 / PVW 帧 `testAux_previewAndMultiviewFramesMatchOfflineWhenEnabled`、`testAux_disabledByDefault` | 实时 `RenderedFrame.preview / multiview` 的 NV12 两个平面与离线逐字节相同；默认 nil | — | ✅ |
| **V1** `testV1_1080p60EightInputsFourOverlays_renderMs`，新标准负载：8 路 1080p NV12 + PGM + PVW + Fade 50% + 4 个叠加（5–8 路，**四路都开抠像**，两路带边框）+ **自定义多画面（安全框 + 电平表占位）**，30 s，去掉前 60 帧，release | **首次（缩略图逐采样点抠像）：平均 3.638 ms，p50 3.673，p99 6.345，最大 9.415；GPU 执行 2.92 ms**（同一时段旧负载 2.069 / GPU 1.40；关抠像 2.089 / GPU 1.27；默认多画面 3.560 / GPU 3.09 → 增量全是抠像）。改成缩略图滤波后抠一次后：平均 3.425，p99 4.786，GPU 3.19（此时同机已有 W3-C 的编码测试 + xcodebuild 在跑，见下一行）；1741 帧，skipped 0，纹理表建 80 次，输出环退回 0 次 | 必须：平均 ≤ 6，p99 ≤ 12；目标 ≤ 4 / ≤ 8 | ✅（必须 / 目标都过） |
| V1 同一测试、W1-C 的旧负载（`SWITCHER_V1_LEGACY_LOAD=1`：无抠像 / 边框 / 布局），同一次开机、同样电池供电 | 安静时段：平均 2.069 ms，p50 2.024，p99 3.858，最大 6.662；GPU 执行 1.40 ms。之后同机有 W3-C 会话的 xctest（VideoToolbox 编码）+ xcodebuild 在跑，三轮交错各 20 s：旧负载 4.219 / 3.300 / 3.761，新负载 3.826 / 3.510 / 4.040，新负载 + 默认多画面 3.026 / 2.895 / 4.433（平均 ms，最好的一轮：旧 3.300、新 3.510、新 + 默认多画面 2.895） | 同上 | ✅ |
| **零分配** `testT1_renderThreadSteadyStateAllocations`，新标准负载，预热 2 s 后 10 s（600 帧），release | 600 帧共 7212 次分配（每帧 12.02），**SwitcherRender 代码 0 次，全部 Swift 代码 0 次**，其余在 AGX 驱动 / IOGPU 内部：每帧 5 × bindPassiveResource、3 × render encoder、1 × compute encoder、1 × 命令缓冲区、1 × ResourceGroupUsage、1 × IOGPUMetalCommandBufferStorageAllocResourceAtIndex（比 W1-C 多的那 1 次是 IOGPU 的命令缓冲存储，与 uniforms 变大有关，不在 Swift 里）；纹理表预热建 80 张，输出环退回 0 次；debug（-Onone）下 Swift 侧 10818 次全是契约 tally / for-in 装箱，SwitcherRender 仍 0 次 | SwitcherRender 代码 0 次；release 下全部 Swift 代码 0 次 | ✅ |
| 零分配（Instruments） | 同一负载在 `xcrun xctrace record --template Allocations` 下跑 10 s（`SWITCHER_T1_INSTRUMENTS=1`，测试不装自己的钩子），trace 存在 `.build/render-test-output/w3b-t1-allocations.trace`（16 MB，不入库；重录命令见 §6）。这版 Xcode 27 的 `xctrace export` 仍导不出 Allocations 表（查询结果为空，与 W1-C 报告 §3 同一现象），Allocations 轨道要在 Instruments 界面里按线程 `fake-engine.render` 过滤看；数字以上一行 MallocProbe 为准——它挂的就是 Instruments 用的 `malloc_logger` 钩子 | 同上 | ✅（trace 已录；导出受限，见左） |
| W1-C 的其余用例（V9 六个、T3、离线 = 实时逐字节、输出环、时间戳、V6 渲染侧、显示解耦两个） | 全过，数值口径不变 | — | ✅ |

**V1 相对 baselines/g3 的增幅**：g3 基线（`baselines/g3-m5max.json`，headless 10 分钟、接电源、8 路合成源、4 个叠加关着、多画面开）render_ms 平均 1.777 / p99 2.039 ms。新负载安静时段 3.638 ms 对 1.777 是 **+105%**（p99 6.345 对 2.039，+211%），旧负载 2.069 对 1.777 是 +16%（同一渲染器代码、不同工装）。 两个数不是同一工装（headless 引擎 + 真合成源 vs 测试里的假引擎 + 轮换缓冲）、也不是同一负载（基线的叠加都关着），可比的是上面同一工装下新旧负载的差：**安静时段 +76%（3.638 对 2.069），全部是抠像：关抠像 2.089 ≈ 旧负载**。原因是四路叠加输入（每路 0.3 × 0.3 画面，2×2 taps）逐采样点抠像 + 多画面里抠像输入的缩略图 4×4 taps 逐采样点抠像，在 60 fps 节奏下 GPU 时钟很低（W1-C 报告 §5 的现象），每像素 4–16 次抠像 ≈ 1.5 ms；half 精度不省（3.876）。已把缩略图改成滤波后抠一次（画中画仍逐采样点，边缘干净）；改完只能在同机有别的会话跑测试时量（交错三轮最好的一轮：旧 3.300 / 新 3.510 / 新 + 默认多画面 2.895，噪声 ± 0.5 ms 以上），拿不到干净的第二组数。**要按 50% 判，需要 G4 在安静的机器上用 headless 场景重量**（§5 第 1 条）；就目前的数据，抠像开 4 路画中画的代价约 +1 ms GPU，V1 目标档（≤ 4 ms）仍然过。真正的 G4 回归请用 headless 场景跑（见 §5 第 1 条）。

## 3. 没做的和原因

- **叠加锚点、PVW 逐通道预览标志、滑入方向字段、画中画边框的正式字段、多画面布局的正式字段**：契约没有，写在提案 010；渲染器用过渡做法（缩放绕中心；`overlaysInPreview` 一刀切；最近的边；效果格 `border`；`extra["layout"]`）。批了之后渲染器改读正式字段（读取点各只有一处：`OverlayDecoration.border`、`MultiviewLayout.layoutValue`、`OverlayRenderer.slideEdge`）。
- **Stinger 文件输入的触发**：渲染器每拍只画 stinger 输入当前的帧；"转场开始时从头播"是文件输入（W2-A / W3-A）和状态机的事，本会话看不到也不该动。现在用一张静态带 alpha 的图当 stinger 也能工作（就是一个延迟 Cut + 一层图）。要真正的动画 stinger，需要引擎在 `autoTransition` 时对 stinger 输入发"从头播"（建议进 W3-A 或 G4 的接线清单）。
- **电平表占位只是占位**：格子右侧的暗条 + 刻度，没有电平。渲染器拿不到 Stats.audio.meters（也不该另算，铁律 4）；接真实电平要么 G4 / W3-E 把表值塞进快照（契约改动），要么外部显示窗口在 UI 层叠。
- **frameprobe 对 Wipe / Zoom 的进度量法**：frameprobe 的 V7 用画面中心灰度（G3 报告 §5），对 Wipe / Zoom 没意义（中心在 50% 时翻转）。本会话的 V7 在渲染侧用整幅覆盖率（Wipe 直线方向）/ 面积反推边位置（对角）/ 中心行宽度（Zoom）量；headless 场景里要测这两种转场的 V7，frameprobe 要加对应量法（W1-A 的目录，写进 §5）。
- **`make test` 整体没跑**（App 的 `xcodebuild test` 会弹窗抢屏幕）；跑了 SwitcherCore 整包 `swift test`、`make build`（六个包 + switcher-headless 都过，App 的 `xcodebuild build` 过；`Tools/frameprobe` 因为这台机器当时拉不到 GitHub 的 swift-system 没编成——网络问题，与本会话无关）、`make lint`（见下）。App 那边采多画面几何的测试（`App/Tests/MultiviewLayoutTests`）依赖的 `inputCell / monitorCell` 逐位没变，默认布局渲染除标签外逐像素没变。
- **多画面 4x4 只到 14 路、自定义最多 64 格**：定长表的容量；再大的布局没有需求。

## 4. 对契约的疑问

0. **编号**：W3-A 的分支先占了 008（`008-input-source-decklink-ndi-params.md`），本会话的两份提案从 008 / 009 改号成 **009（抠像口径）/ 010（叠加装饰 / 多画面布局）**；早期提交信息里还写着 008 / 009，以文件名为准。
1. **提案 009（抠像口径）**：不改类型，只把四个数的意义写进注释。建议批；批了之后契约会话把 §A 的表抄进 `KeyerSettings` 的注释和 CONTRACTS.md §2.4。
2. **提案 010（叠加装饰 / PVW 预览 / 滑入方向 / 多画面布局）**：需要新字段。W3-E 做设置面板之前批比较好，否则 UI 只能照过渡做法写 `extra["layout"]` 和效果格，以后再迁。
3. **Stinger 的"第 0 拍"**：契约 `StingerParams.cutAtTick` 的注释是"在 stinger 的第几拍换底"。按状态机口径第 s 拍应用命令时 progress = 0（渲染器什么都不叠），第 s + 1 拍才是 stinger 的第一帧，所以 cutAtTick 0 和 1 等价、cutAtTick ≥ durationTicks 等于"完成时换"。建议把这两句补进注释（本报告 §1 已写，`TransitionRenderer.stingerShowsNewUnder` 是定义）。
4. **`OutputSource.multiview` 出现在多画面自定义格子里**：渲染器忽略（格子不能套自己）。契约不用改，注释可以提一句。
5. **`RenderedFrame.preview / multiview` 的填充条件**：契约允许 nil；现在由 `MetalRendererOptions.previewOutput / multiviewOutput` 决定，不看 `MixerState.outputs`。要不要改成"状态里有 enabled 的 NDI / 外部显示输出且 source 是 preview / multiview 时自动开"，由 G4 接线时定（渲染器侧改一行）。

## 5. 下一个会话需要知道的坑

1. **V1 回归请用 headless 场景跑**：G4 合入后把 g3 场景（或新场景）的 show 里 4 个叠加打开、5–8 路 `keyer.enabled = true`、多画面输出 `extra["layout"]` 设成自定义布局，对 baselines/g3 比 render_ms；本会话只能在测试工装里比（§2）。
2. **改了 `DrawUniforms`**：加字段必须两边（`ShaderTypes.swift`、`Compositor.metal`）同步，16 字节对齐的字段放在 16 的倍数偏移上，最后 `expectedStride` / `static_assert` 改成新大小。现在 144。
3. **下采样路径的 half 累加别动**：改成 float 累加会让画中画 / 多画面缩略图逐像素差 ±1，所有多画面参考图都要重生成。抠像在每个采样点上用 float 算再转回 half，不影响不抠像的路径。
4. **多画面默认布局的几何是 App 的契约**：`MultiviewLayout.inputCell / monitorCell`（Double）和渲染表（Float）用同一份泛型 `MultiviewGeometry`，1080p / 720p / 4K 下两边逐位相等；非默认布局用 `placements`。改默认几何 = 改 App 缩略图接线 + 重生成 v8-fixed-multiview。
5. **参考图里 `v8-fixed-multiview` 的 PGM / PVW 标签**：多画面每格都有名字了，包括 PGM / PVW 格。要是以后想让默认布局不带这两块标签，重生成一张即可。
6. **`OfflineRenderer.overlaysInPreview` 是实例属性**：V8ReferenceTests 共用一个离线渲染器，`compare` 用 defer 复位；别的测试类各自建自己的。
7. **合成测试图（`TestImagesPhase2`）在 debug 下生成慢**（绿幕图约 40 s），已缓存成静态常量，一个测试进程只算一次；别在用例里改参数重算。
8. **stinger 输入没帧时**：退化成"第 cutAtTick 拍换底的延迟 Cut"，不崩；`OfflineRenderer` 的输入表容量已把 `stinger.input` 算进去。
9. **Zoom 转场下输入自己的 offset**：按尺度一起缩（`offsetScale`），否则缩小的新画面会"漂"出去。
10. **抠像 + NV12 源**：`drawInput` 一旦抠像就走混合管线（alpha < 1），NV12 / UYVY 源也一样；不抠像时仍走不混合管线，V9 电平不受影响。
11. **电池供电下的数字**：会话全程电池供电（100% → 90%），且从 14:36 起同机有 W3-C 会话的 xctest（VideoToolbox 编码）和一个 xcodebuild 在跑。V1 的绝对值不能和 W1-C / G3 的接电源数字直接比；同一时段旧负载 vs 新负载的差才有意义，而且噪声 ± 0.5 ms 以上（旧负载三轮 3.3–4.2）。零分配的计数不受影响。

## 6. 复现

```bash
swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests                   # 全部，debug，约 5 分钟
swift test -c release --package-path Packages/SwitcherCore --filter 'testV1|testT1'            # V1 / T1 的报告数字
SWITCHER_V1_LEGACY_LOAD=1 swift test -c release --package-path Packages/SwitcherCore --filter testV1   # W1-C 的旧负载
scripts/gen-references.sh                                                                      # 重生成参考图（先打印和旧图的 PSNR）
```
