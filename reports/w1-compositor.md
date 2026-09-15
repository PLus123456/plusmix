# W1-C 合成引擎（Metal）报告

分支 `claude/w1-compositor-97689f`（桌面端开的 worktree 分支名；prompt 里叫 `w1-compositor`，`check-ownership.sh` 用后者查过：33 个改动文件全在允许范围内）。
基于 main `bdab613`，本会话提交 `b18c998` … `c14ba15`。
机器：MacBook Pro M5 Max（40 核 GPU），macOS 26.6.2（25G83），Xcode 26.6 / Swift 6.3.3，接电源，内置屏 120 Hz ProMotion。

## 1. 做了什么

只动了 `Packages/SwitcherCore/Sources/SwitcherRender/`、`Tests/SwitcherRenderTests/`、`Tests/References/`、`scripts/gen-references.sh`、`Package.swift`（只给 Render 加着色器资源）。

| 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 Renderer | `Renderer/MetalRenderer.swift` | 实现契约 `Renderer`。三重缓冲（`RenderSlot` × 3），CPU 领先 GPU ≤ 2 帧用原子计数（`inflight`）而不是信号量：满了直接返回 `.skipped`，永远不等（T3 测试证明最大在途 = 2）。完成回调在专门线程上 `waitUntilCompleted`（不用 `addCompletedHandler`：每帧的闭包 / block 都是堆分配）。纹理池 = `RenderTargets`（每重 PGM / PVW / 多画面三张 private 纹理 + 预建的 pass 描述）；输入纹理表 `SurfaceTextureTable`；输出缓冲环 `OutputBufferRing`。渲染线程零分配：见 §2 T1 |
| 2 输入纹理 | `Renderer/SurfaceTextureTable.swift`、`Shaders/Compositor.metal` | NV12（r8 + rg8 两平面）、BGRA（bgra8，预乘）、UYVY（`MTLPixelFormatBGRG422`，硬件解包给 (Cr, Y, Cb)）三种，全部 `makeTexture(descriptor:iosurface:plane:)` 零拷贝，按 IOSurfaceID 缓存。**没用 CVMetalTextureCache**，原因见 §5。片段着色器做 YCbCr→RGB：BT.709 / 601 / 2020 三个矩阵，limited / full 两种范围；4:2:0 色度按水平左对齐、垂直居中重建 |
| 3 合成 pass | `Renderer/CompositorPasses.swift` | 严格 §5 顺序：PGM 底（裁切 / fit / 缩放 / 平移 / 旋转 / 翻转，`Placement.swift`）→ 转场（Cut 无中间态；Fade = 新画面按 progress 盖上；Wipe / Zoom / Stinger 留在 `TransitionRenderer.mixAmount` 一个调用点，暂按 Fade）→ Overlay 1→4（预乘 source-over，按 rect 裁剪，静态位置；进出动画只解释 cut / fade，slide / zoom 暂按 fade）→ FTB（叠 alpha = level 的黑）→ PVW → 多画面（上半 PVW 绿框 + PGM 红框，下半 4×2 / 6×3 / 8×4 网格，tally 边框，名字标签） |
| 4 输出 | `Compositor.metal` `rgbToNV12`、`Renderer/OutputBufferRing.swift` | compute kernel 每线程一个 2×2 块，以 `r8Uint` / `rg8Uint` 视图整数写进 IOSurface 背后的 CVPixelBuffer（'420v'，附件标 BT.709），交 `RenderSink`。舍入策略见 §6 |
| 5 计时 | `MetalRenderer.completionLoop`、`Renderer/RenderSignposts.swift` | `gpuStartTime / gpuEndTime`（探针确认与 mach_absolute_time 同时基）换算成 HostTime 填 `RenderedFrame`；每个 pass（frame / pgm / pvw / multiview / nv12 / submit）打 `os_signpost`，subsystem `app.switcher.render`，xctrace 录到的 trace 里能看到 |
| 6 离线渲染 | `Offline/OfflineRenderer.swift`、`scripts/gen-references.sh`、`Tests/References/README.md` | `renderOffline(state:inputs:size:target:)`（prompt 的签名 + 默认参数 target）；`render(state:pixelBuffers:size:)` / `render(state:frames:size:)` 给三种像素格式和自定义 ColorInfo；返回 PGM / PVW / 多画面 CGImage + NV12 CVPixelBuffer。与实时路径共用 `CompositorPasses.encodeFrame`，证明见 §6 |
| 7 显示 | `Display/MetalDisplayView.swift`、`Display/PreviewWindow.swift` | NSView + CAMetalLayer，`NSView.displayLink(target:selector:)`，按所在显示器刷新率把"最新完成的纹理"画到 drawable（同一个命令队列，Metal 追踪读写冲突）；`maxFramesPerSecond` 用 `preferredFrameRateRange`；遮挡 / 隐藏不画；同一帧不重复 blit。`PreviewWindow` 按 1 / 2 / 3 切 PGM / PVW / 多画面，给 headless 的 `--preview` |

其他：着色器 `Compositor.metal` 随包走（`resources: [.process(...)]`）—— Xcode 构建（`make build` 的 App）编成 `default.metallib`，`swift build` 只拷源码、`prepare` 时运行时编译一次（M5 Max 0.31 s）；`ShaderLibrary.load` 两条路都试过。多画面名字用 CoreText 在后台线程预渲染成 `texture2d_array` 切片（中文也行），双缓冲、写前等在途帧完成；渲染线程只 blit。

## 2. 测试（`swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests`，27 个全过；整包 76 个全过）

| 测试 ID / 函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| **V8** `testV8_fixedStateMatchesReference`（PGM = 1，Overlay 1 + 3 开，画中画右下 1/4，FTB 关） | PSNR ∞ dB，SSIM 1.0000 | ≥ 40 dB 或 ≥ 0.98 | ✅ |
| V8 `testV8_fade50MatchesReference` | ∞ dB / 1.0000 | 同上 | ✅ |
| V8 `testV8_ftb100MatchesReference` | ∞ dB / 1.0000 | 同上 | ✅ |
| V8 `testV8_previewMatchesReference` | ∞ dB / 1.0000 | 同上 | ✅ |
| V8 `testV8_multiviewMatchesReference`（额外加的一张） | ∞ dB / 1.0000 | 同上 | ✅ |
| V8 结构性检查（不依赖参考图）：`overlay3DrawsAboveOverlay1`、`pictureInPictureLandsInBottomRightQuarter`、`alphaOverlayBlendsInGammaDomain`（0.5·白 + 0.5·底，误差 ≤ 2）、`ftbHalfScalesEveryPixel`（±1.5）、`cropAndTransformPlaceContent`、`missingInputRendersBlack` | 全部逐像素成立 | — | ✅ |
| **V9** `testV9_grayRampAndColorBarsBGRAToNV12_withinOneLevel`（BGRA 输入：75% 色条 7 块 + 灰阶 0–255 步 8 共 32 块，每块中心 16×16 全查） | 亮度最大误差 0，色度最大误差 0 | ≤ 1 | ✅ |
| V9 `testV9_limitedRangeEndpointsExact`（0–255 全部 256 个电平） | 最大误差 0；RGB 0 → Y 16，255 → 235，128 → 126；灰的 Cb/Cr 恒 128 | ≤ 1，范围不拉伸压缩 | ✅ |
| V9 `testV9_nv12RoundTrip_withinOneLevel`（NV12 limited 输入 → RGB → NV12） | 0 / 0 | ≤ 1 | ✅ |
| V9 `testV9_uyvyInputToNV12_withinOneLevel`（UYVY 输入 → RGB → NV12） | 0 / 0 | ≤ 1 | ✅ |
| V9 `testV9_fullRangeNV12Input_mapsIntoLimited`（'420f' 输入 0–255） | 最大误差 0，0 → 16，255 → 235 | ≤ 1 | ✅ |
| V9 `testV9_bt601InputIsConvertedThrough709Output` | 全部 ≤ 2（601 编码本身一次舍入 + 输出一次） | 自定 ≤ 2 | ✅ |
| **V1** `testV1_1080p60EightInputsFourOverlays_renderMs`：1080p60，8 路 1080p NV12（每路 4 个缓冲轮换），PGM + PVW + Fade 50% 进行中 + 4 个 overlay + 多画面全开，30 s，去掉前 60 帧 | **release：平均 2.35 ms，p50 2.18，p99 2.72，最大 2.79**（1741 帧，skipped 0）；debug：平均 2.49，p99 2.96；分解：唤醒延迟 0.01 + 拍点→提交 0.13 + 提交→GPU 开始 0.55 + GPU 执行 1.67 ms；多画面关掉：平均 1.51 ms（GPU 0.98） | 必须：平均 ≤ 6，p99 ≤ 12；目标：≤ 4 / ≤ 8 | ✅（参考线记下） |
| **零分配** `testT1_renderThreadSteadyStateAllocations`：同 V1 负载，预热 2 s 后只在 `render()` 内计数 10 s（600 帧），malloc_logger 钩子只数渲染线程 | **release：SwitcherRender 代码 0 次，全部 Swift 代码 0 次；每帧 11.02 次全在 AGX 驱动内部**（5 × `bindPassiveResource`、3 × render encoder、1 × compute encoder、1 × command buffer、1 × `ResourceGroupUsage`）。debug（-Onone）：Swift 侧 36/帧全是契约 `MixerState.tally(ofInput:)` 的 for-in 装箱，SwitcherRender 0 次 | 稳态 0 次 | ✅（Swift 侧）；Metal 内部的对象分配无法为 0，见 §5 |
| T3 `testT3_cpuNeverLeadsGPUByMoreThanTwoFrames`：4K30、16 路、4 overlay，每 0.5 ms 调一次 render 共 2000 次 | 提交 1118，跳过 882，观察到最大在途 2，完成 1118 = 提交 | 在途 ≤ 2、不阻塞 | ✅ |
| 离线 = 实时 `testOffline_matchesRealtimeBitExact` | NV12 亮度 / 色度平面逐字节相同；PGM 纹理逐像素相同 | 相同 | ✅ |
| V6（渲染侧）`testV6_programChangeTakesEffectNextFrame`：Cut，第 2 拍换号 | 四帧中心 Y = [71, 71, 181, 181]，无混合帧 | 恰好那一拍，无混合 | ✅ |
| `testRenderedFrame_timestampsAreHostTime` | tick / tickTime 原样带回，gpuStart ≥ 拍点，renderMs = gpuEnd − tickTime，program.pts = 拍点 | — | ✅ |
| `testOutputRing_neverHandsOutHeldBuffer` | 消费者持有的缓冲不会再发出；全占时退回池子（fallbackCount 1）而不覆盖 | — | ✅ |
| **显示解耦** `testDisplay_windowManipulationDoesNotCauseMissedRenders`：内置屏 120 Hz 预览窗口 + 60 Hz 假引擎，拖动 2 s、完全遮挡 2 s、进全屏 2 s、出全屏 2 s、改两次大小 | display link 119.5 Hz（1088 次 / 9.1 s），引擎提交 607 拍、**跳过 0**；blit 362 次（39.8 fps，≤ 60：只画新帧，遮挡期间 0 次） | missed_render 不增加 | ✅ |
| 缩略图上限 `testDisplay_maxFrameRateCapsThumbnailBlits`（maxFramesPerSecond = 15） | 2 s 内回调 30 次、blit 30 次 | ≤ 15 fps | ✅ |

V8 参考图第一次生成后我逐张看过（用 Read 看的 PNG）：固定状态那张渐变图案打底、左下蓝→橙条和 50% 白方块、右下 1/4 棋盘且盖住渐变条右端；Fade 50% 色条半透明盖在图案上；FTB 全黑；PVW 是纯色条 + 灰阶；多画面上 PVW（绿框）/ PGM（红框）、下 4×2 格带 tally 色框和"1  摄像机 1 / 2  Camera 2 / 3  Lower Third / 4  PiP 画中画"标签。第一版标签是上下颠倒的（CGBitmapContext 内存行序本来就是顶行在前，我多翻了一次）、输入 3 的透明区在 PNG 里是透明的（BGRA 源走了不混合管线），改掉后重生成；之后 half 精度改动只让多画面那张相对前一版差 70.8 dB，其余四张逐像素不变，重生成锁定当前输出。`Tests/References/README.md` 写了每张该长什么样。

**三种像素格式各自怎么测的**：都是同一套 patch（7 个色条块 + 32 级灰阶），期望值由契约 `TestPattern.ycbcr(r:g:b:)`（double）四舍五入得到。BGRA：`TestImages.colorBarsBuffer` 写 RGB 电平，经 `render(state:pixelBuffers:)`（不经 CGImage，避免 CoreGraphics 色彩转换）→ NV12 输出逐样本比。NV12：`V9ColorTests.fillYCbCr` 直接把期望 YCbCr 码值写进 Y / CbCr 平面 → 输出应等于输入（往返）。UYVY：同样的码值按 [Cb, Y0, Cr, Y1] 打包写进 '2vuy' 缓冲 → 输出比期望。另加 '420f' 全范围输入 0–255 和 BT.601 矩阵输入。真 DeckLink 没有，UYVY 只验证了缓冲格式与着色器解包，硬件时序归 W3-A。

**性能采集环境**：接电源，未关其它程序（有几个别的 Claude 会话在同机跑测试；V1 的数字在这种"脏"环境下测的，纯净环境只会更好）。Instruments：`.build/render-test-output/t1-allocations.trace`（16 MB，未入库；重录命令见 §5）。

## 3. 没做的和原因

- **Wipe / Zoom / Stinger、Overlay 的 slide / zoom 动画**：prompt 说留接口，W3-B 填。接口就是 `TransitionRenderer.mixAmount` 和 `OverlayRenderer.opacity` 两个函数（各一个调用点），现在退化成 Fade。
- **抠像**：测试标准 §3 V8 写了"抠像开"，但本会话 prompt 的 V8 没提，`KeyerSettings` 也是占位（契约注明 W3-B 细化时走提案）。没做。
- **PVW 的预览叠加层**：§5 第 5 步是"可选"，没做。
- **Mipmap 下采样**：设计方案 §5 说"第一版下采样用 mipmap + 双线性"。IOSurface 包出来的纹理不能建 mip，要每帧先拷贝一份再 generateMipmaps。我用的是目标像素足迹内 taps×taps（≤ 4×4）的盒式超采样，效果等价、不多一趟拷贝；缩略图 / 画中画走 half 精度（1:1 路径仍是 float，保证 V9 电平误差 0）。这是实现细节，不是契约，但和设计方案的文字不一致，记在这里。
- **多画面的 PVW / 多画面 NV12 输出**：`RenderedFrame.preview / multiview` 为 nil（契约允许第一版为 nil）。外部显示 / NDI 要它们时再加两趟 compute。
- **Instruments 的分配数据没法用命令行导出**：这版 Xcode 的 `xctrace export` 不认 Allocations 的表，只能在 Instruments 界面里看。报告里的分配数字来自 `MallocProbe`（挂的正是 Instruments 用的 `malloc_logger` 钩子，只数渲染线程、只数分配，回溯用 `backtrace()` 抓、事后 `dladdr` 归类）。trace 文件录了一份放 `.build/render-test-output/`，打开就能看同一负载的 Allocations 轨道。
- **`make test` 整体没跑**（App 的 `xcodebuild test` 会弹窗且和别的会话抢机器），跑了 `make build`（六个包 + 两个工具 + App 全过，App 构建里 SwitcherRender 的 bundle 含 `default.metallib`）和 SwitcherCore 整包 `swift test`（76 个全过）、`lint-rules.sh`、`check-deps.sh`、`check-ownership.sh w1-compositor --include-working-tree` 全绿。

## 4. 对契约的疑问

1. **Renderer 协议本身没改**，实现按 CONTRACTS.md §7 的调用链做。与 W1-B 可能的分歧（等 G2 对）：
   - `render` 返回 `.skipped` 的三种情况：在途 ≥ 2、输出环拿不到缓冲（消费者全扣着，实际会退回池子分配，不会 skip）、Metal 建不出命令缓冲区。引擎一律记 missed_render 即可。
   - 完成回调线程是渲染器自己的线程（`switcher.render.completion`，QoS user-interactive），每帧一次 `waitUntilCompleted`；`RenderSink.renderer(_:didComplete:)` 在它上面被调，必须立即返回（契约已这么写）。
   - `RenderedFrame.program.ingressTime` 我填的是 gpuEnd（PGM 帧"进帧槽"的等价时刻）；`sequence` 是渲染器的帧序号（不是 tick）。契约没规定，W1-E 算 L1 时用 `ingressTime` 就行。
2. **`RenderInputTable` 填表后渲染器要 retain 帧到 GPU 完成**（契约写了"渲染器要留的东西自己 retain"），已做（`RenderSlot.heldFrames`）。引擎那边不需要为此多做什么。
3. **输出缓冲环的容量与消费者队列深度的关系**：环 8 个，在途 ≤ 2，所以所有消费者同时持有的 PGM 帧总数 ≤ 5 才不会退回池子分配（退回不是错，只是那一帧多 6 次 CoreVideo 分配）。W1-E 的编码器每路持有 2–3 帧 × 3 路就超了。建议 G2 接线时按 `MetalRendererOptions.outputRingSize ≥ maxInflight + Σ 消费者队列深度 + 1` 配（每个 1080p NV12 缓冲 3 MB）。要不要把这个数放进 Show / 契约由你定。
4. **`MixerSnapshot` 的发布频率**：标签线程按 `snapshot.sequence` 判断名字有没有可能变（不比对象标识），所以引擎每拍发布新快照对象没关系；但如果引擎在没有命令时也递增 sequence，标签线程会每拍醒一次做一遍字符串比较（不重画）。契约说 sequence = 最后一条命令的序号，按这个语义没问题。
5. **`Stats.gpu_pct`**：渲染器能给每帧的 GPU 执行时长（gpuEnd − gpuStart），但 `gpu_pct` 口径（powermetrics 的 GPU 占用）不是它。我没往 Stats 里塞任何字段（铁律 4）；render_ms 由引擎从 `RenderedFrame.renderMs` 汇总。

## 5. 下一个会话需要知道的坑

- **渲染线程每拍要包 `autoreleasepool`**（W1-B）：Metal 的 `makeCommandBuffer` / `make…Encoder` 返回 autoreleased 对象，线程不 drain 的话自动释放池每几百帧新开一页（malloc）并且无限长。`MetalRenderer.render` 内部已包了一层，引擎线程自己的循环也包一层更稳（pop 只释放不分配，线程热页会被 objc 缓存复用）。
- **-Onone 下 Swift 的 for-in 会分配**：`for x in array` / `for i in range` 走未特化的 `IndexingIterator`，每次迭代装箱；契约里的 `MixerState.input(_:)`（`first(where:)`）和 `tally(ofInput:)` 也一样。热路径我全改成下标 while 循环；调用契约的 `tally` 在 debug 下每帧 36 次分配、release 为 0。零分配的结论以 release 为准（`swift test -c release`）。
- **ObjC 字符串属性也会分配**：`commandBuffer.label = "switcher.frame"` 每帧一次 NSString 桥接（14 字节超出 tagged pointer），`"RGB→NV12"`（非 ASCII）同理；≤ 9 字节 ASCII 的字面量是 tagged pointer 不分配。
- **`malloc_logger` 钩子里不能碰 Swift 全局 var**：debug 下每次访问走 `swift_beginAccess`，它第一次在某线程用 TLS 时会 malloc → 钩子递归 → SIGBUS。状态放裸指针后面就好（`MallocProbe`）。另一个会话（引擎那边的 `AllocBacktraces`）的崩溃报告显示撞了同一个坑（懒初始化全局数组在钩子里触发 `dispatch_once` + malloc）。
- **CVMetalTextureCache / CVPixelBufferPool 都不是零分配**：探针实测 `CVMetalTextureCacheCreateTextureFromImage` 每次 3 个对象（CVMetalTexture、字典、CFData），`CVPixelBufferPoolCreatePixelBuffer` 每次约 6 次（新建 CVPixelBuffer 对象和附件字典，池子回收的只是 IOSurface）。所以输入侧按 IOSurfaceID 记 `makeTexture(iosurface:)` 的结果，输出侧预建 CVPixelBuffer 环、按 `CFGetRetainCount` 判断空闲（基线在 init 里用同一段 `@inline(never)` 代码量出来，不猜编译器）。W2-A 的输入实现要用池子（IOSurface 反复出现才能命中表）；每路池深 ≤ 8，否则 `SurfaceTextureTable` 会淘汰重建（容量 = maxInputs × 16 + 环 × 2 + 8）。
- **Metal 每帧的对象分配去不掉**：命令缓冲区、编码器都是一次性对象（release 下每帧 11 次，全在 AGXMetal 内部）。要再省只能把 PGM / PVW / 多画面合成一张 atlas 纹理、一个 render encoder 画完（省 2 个编码器 ≈ 4 次），我没做。`commandBufferWithUnretainedReferences` 比默认的 retained 少一大截（探针里 retained 模式每帧多约 20 次 IOGPU 资源表分配）。
- **60 fps 节奏下 GPU 时钟很低**：同一段 8 个 1/4 缩略图 4×4 taps 的绘制，背靠背跑 0.36 ms，每帧歇 14 ms 就 1.24 ms（half 精度 0.41 ms）。所以 render_ms 的 GPU 部分（1.67 ms）不代表满载能力，负载上去时钟会跟上；比较两次改动的 GPU 耗时必须在同样的节奏下测。
- **`gpuStartTime / gpuEndTime` 是 CACurrentMediaTime 时基（mach_absolute_time 换算的秒）**，探针确认与 `mach_absolute_time` 差 0.011 ms 内；`HostTime(nanoseconds:)` 直接换算。
- **UYVY 用 `MTLPixelFormatBGRG422`**：'2vuy' 的 IOSurface 直接包成这个格式，着色器拿到 (Cr, Y, Cb, 1)，每个像素自己的 Y、色度按对复制；探针写入 [Cb 40, Y0 100, Cr 200, Y1 150] 读回 (200,100,40) / (200,150,40)。宽必须是偶数，只能 clamp_to_edge。
- **CGBitmapContext 内存第 0 行就是顶行**（CG 坐标原点在左下只是坐标系的事），画完直接 `replace` 进纹理，别翻转。
- **测试进程里的窗口要跑 NSApp 事件循环**才会更新 `occlusionState`（只泵 RunLoop 不行）；`toggleFullScreen` 要 `collectionBehavior` 含 `.fullScreenPrimary`。`DisplayDecouplingTests` 会真的把窗口切全屏 4 秒，跑测试时别惊讶。
- **`swift build` 不编 .metal**：只把源码拷进 bundle；`ShaderLibrary.load` 先试 `makeDefaultLibrary(bundle:)`（Xcode 构建有），没有就读源码运行时编译（0.31 s，`mathMode = .safe`）。改着色器不用改任何 Swift。
- **BGRA 源永远走混合管线**：源可能带 alpha，用不混合的管线会把 alpha 0 写进输出纹理（PNG 里透明、多画面里发白）。NV12 / UYVY 的 alpha 恒 1 才走不混合。
- **W3-B 加转场时**：`CompositorPasses.encodeProgram` 里转场只有一个调用点（`TransitionRenderer.mixAmount`），Wipe 需要遮罩纹理、Zoom 需要给 `Placement.fill` 传插值后的 transform、Stinger 需要一路带 alpha 的输入叠在最上面——都在 `encodeProgram` 里加分支，不用动实时 / 离线两条路径的代码（它们只调 `encodeFrame`）。参考图重生成用 `scripts/gen-references.sh`，它会先打印和旧图的 PSNR。
- Instruments 重录：`SWITCHER_T1_INSTRUMENTS=1 SWITCHER_T1_SECONDS=10 xcrun xctrace record --template Allocations --output x.trace --time-limit 16s --launch -- /Applications/Xcode.app/Contents/Developer/usr/bin/xctest -XCTest 'SwitcherRenderTests.RealtimeRendererTests/testT1_renderThreadSteadyStateAllocations' Packages/SwitcherCore/.build/release/SwitcherCorePackageTests.xctest`（先 `swift test -c release --filter testOutputRing` 把 release 测试包编出来；`SWITCHER_T1_INSTRUMENTS=1` 让测试不装自己的 malloc 钩子，否则和 Instruments 抢 `malloc_logger`）。

## 6. prompt 要求写进报告的三件事

**RGB → NV12 kernel 的舍入策略**（`Compositor.metal` `rgbToNV12`）：输入是 PGM 纹理的 8-bit unorm（读出来是 k/255 的 float32）。Y' = 0.2126 R' + 0.7152 G' + 0.0722 B'，Y = 16 + 219·Y'；色度先把 2×2 块四个像素的 RGB 求平均再转（线性运算可交换，等于平均 Cb/Cr），Cb = 128 + 224·(B'−Y')/1.8556，Cr = 128 + 224·(R'−Y')/1.5748；先钳到合法范围（Y 16–235，C 16–240），再 `round()`（四舍五入，.5 远离 0，和 Swift 的 `.rounded()` 一致），以整数写进 `r8Uint` / `rg8Uint` 视图——不经过 float→unorm 的转换，所以没有第二次舍入。灰阶不存在恰好 .5 的平局（146v ≡ 85 mod 170 无解）；色度的 float32 与 CPU double 之差约 1e-5，只在离 .5 极近时可能差 1，V9 实测 0。超出 16–235 的电平（超白 / 超黑）会被 8-bit BGRA 工作纹理钳掉，这是决策 6 工作格式的固有性质，第二版换 float16 线性中间纹理时消失。

**离线渲染与实时路径共用同一函数的证明**：仓库里只有一处编码合成 pass —— `CompositorPasses.encodeFrame(state:inputs:slot:context:commandBuffer:outputLuma:outputChroma:multiview:)`。`MetalRenderer.renderInsidePool`（实时）和 `OfflineRenderer.render(state:frames:size:)`（离线）都只调它，区别仅在目标纹理（三重缓冲的一重 vs 离线 session 的一套）、命令缓冲区（unretained vs 默认）和等待方式（完成线程 vs `waitUntilCompleted`）。`grep -n "encodeFrame(" Packages/SwitcherCore/Sources/SwitcherRender -r` 只有这两个调用点。运行时证据：`testOffline_matchesRealtimeBitExact` 用同一状态、同一组 BGRA 像素缓冲分别走两条路径，NV12 两个平面逐字节相同、PGM 纹理逐像素相同。

**三种像素格式各自怎么测的**：见 §2 表下方那段。

## 7. 复现

```bash
swift test --package-path Packages/SwitcherCore --filter SwitcherRenderTests            # 全部 27 个，约 2 分钟（含 V1 30 s、T1 13 s、显示 14 s）
swift test -c release --package-path Packages/SwitcherCore --filter RealtimeRendererTests  # V1 / T1 的报告数字用 release
scripts/gen-references.sh                                                                  # 重生成参考图（会先打印和旧图的 PSNR）
SWITCHER_V1_SECONDS=8 SWITCHER_V1_NO_MULTIVIEW=1 swift test -c release --package-path Packages/SwitcherCore --filter testV1   # 诊断：多画面占多少
```
