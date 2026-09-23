# W3-C2 Aux 全分辨率 + 显示类输出 Stats 填数复核 —— 报告（分支 w3-outputs-3）

日期 2026-09-23。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 27.0 (27A266a, Swift 6.4)，电源适配器。
**本机现在接着两块屏**：内置 Liquid Retina XDR（1728×1117 pt @2x，120 Hz，主屏 id 1）+ LG ULTRAGEAR（2560×1440 @1x，144 Hz，id 5）——W3-C 时只有内置屏，
所以"挪到外接屏"这一项这次能自动测了（L2 秒表法仍是人工）。
worktree `.claude/worktrees/w3-outputs-aux-stats-dd95ab`，桌面端给的分支 `claude/w3-outputs-aux-stats-dd95ab` 没动，另从同一提交开了 **`w3-outputs-3`** 并在上面提交；
从 main **4b7a3df**（P3 / W1-A3 / W2-A2 合入、提案 015 落地之后）开。提交：`git log main..w3-outputs-3`（代码 3 个、问题单 2 个、报告 3 个）。
改动只在 `Packages/SwitcherOutputs/{Sources,Tests}/{External,ExternalTests,VirtualCamera,VirtualCameraTests}/`、本报告与 `reports/issues/`；
契约、渲染器、App、CameraExtension、Package.swift 都没碰。`make lint BRANCH=w3-outputs-3` 全绿（禁词 / 版本号 / 依赖方向 / 归属 / RT 符号）。

## 1. 做了什么

### 探针与实验（铁律 10，写正式代码之前）

| # | 问题 | 结论 |
|---|---|---|
| 1 | CVMetalTextureCache 能不能直接包本仓库出现的三种输入格式的 IOSurface 平面 | 能：BGRA → `bgra8Unorm`、NV12（'420v' / '420f'）→ Y `r8Unorm` 1920×1080 + CbCr `rg8Unorm` 960×540、UYVY（'2vuy'）→ `bgrg422`，全部 `kCVReturnSuccess`；NV12 两个平面包一次 **2.2 µs** |
| 2 | 小着色器运行时编译要多久 | 进程里第一次 **82 ms** → 放后台预编（`AuxPipeline.prepare`），窗口在编好之前不取帧 |
| 3 | CMIO 的样本序号 API 在 Swift 里能不能用 | `CMIOSampleBuffer.h` 不在 CoreMediaIO 的 Swift 模块里（伞头文件只收 CMIOExtension.h / CMIOHardware.h），但 C 函数照样导出：`dlsym(RTLD_DEFAULT, "CMIOSampleBufferSetSequenceNumber")` 取得到，设了之后样本附件里是 `com.apple.cmio.buffer_attachment.sequence_number`，读回一致 |
| 4 | 低于 normal 一级的窗口能不能稳定垫在普通窗口下面；orderOut 时遮挡通知 / display link 怎么走 | 层级 normal − 1 的无边框全屏窗口在 `orderedWindows` 里始终排在普通窗口后面，自己成 key 也不翻上来；`orderOut` 会发 `didChangeOcclusionStateNotification`（hidden）且 `NSView.displayLink` 回调停（1 s 0 次），`orderFront` 发 visible、回调恢复 120 次 / s |
| 5 | Aux 着色器与渲染器"同一套系数"能不能做到逐像素相同 | **渲染器实际跑的是构建时编好的 `default.metallib`**（swift build 与 Xcode 都把 Compositor.metal 编进 SwitcherRender 的资源包，Metal 编译器默认 fast-math；`RenderResources` 里"运行时编译、`.safe`"那条只是没有 metallib 时的后备，注释过时）。同一份 ycbcrToRGB / fetch 按 `.safe` 编，在一张随机色度的 1080p NV12 帧上与渲染器有 **12 / 2 073 600** 像素差 1 LSB（均匀散在 x / y 奇偶四类里，是单精度求值顺序落在舍入边界上，不是采样位置）；按 **`.fast` / `.relaxed` 编逐像素相等** → Aux 用 `.fast`（issue W3C2-render-metallib-math-mode 给渲染器的主人） |

### 交付

| prompt 交付 | 落点 | 做法 |
|---|---|---|
| 1 Aux 全分辨率 | `External/AuxShaders.swift`（着色器源码 + 管线缓存）、`AuxInputPresenter.swift`（取帧 / 包纹理 / 编码 / 占位 / 记账，窗口与离屏测试共用）、`AuxInputView.swift`（CAMetalLayer + `NSView.displayLink`）、`ExternalDisplayWindow` / `ExternalDisplayManager` 接线 | source = 输入 n 的窗口里 `displayView`（MetalDisplayView）收起、`auxView` 出来。每次显示刷新：**帧槽的契约读入口 `latest(atOrBefore: 此刻)`** 从组装方给的帧槽取该路最新帧（`AuxFrameTap`：App 里 = `InputRuntime.openBranch` → `InputFrameTee` 的一个分支，窗口是它唯一的读者；不走引擎的 `latest(forTick:)`，不碰主槽、不动到达余量），CVMetalTextureCache 零拷贝包成纹理，着色器按渲染器同一套系数换算（BT.709 / 601 / 2020、limited / full、4:2:0 色度左对齐、线性采样、1:1 与放大走 float、缩小按 Placement 的 taps 做盒式滤波），按比例铺满 drawable。NV12 / BGRA 之外顺手支持 UYVY（DeckLink 的 8 位 4:2:2，同一套换算）。**抠像 / 裁切 / 变换不生效 = 原始画面**（写在 `ExternalDisplaySpec` / 窗口 / presenter 的注释里；界面文案归 App，见 §3）。**纹理缓存按输入编号预建**（attach 时建，不等第一帧），**换输入时重建**（同一路改名不重建）。**无信号画占位**：帧槽里从没有帧、组装方给的运行状态是 noSignal / error、或（没给运行状态时）帧断了超过 3 个帧间隔（与输入 NoSignalWatchdog 同一个 N，下限 50 ms）→ 黑底 + 中间"无信号"（error 时是输入报的文案）+ 左下"编号  名字"（多画面格子名字条的格式）；文字在后台队列用 CoreText 栅格化，好了补画一次，画过就不重画。**主线程不做像素工作**：每次刷新只取帧、包纹理、编码一次绘制（release 中位 9.8 µs、p99 19.4 µs，见 §2 末），像素换算在 GPU。渲染线程完全不参与（没加 `RenderedFrame` 字段、没加每路全分辨率目标）。组装方怎么接：issue W3C2-app-aux-wiring（约 10 行胶水） |
| 2 `Stats.display[]` 复核 | `External/DisplayFrameLedger.swift`、`ExternalDisplayManager.statsEntries`、`ExternalDisplayWindow.presentedFrames / droppedFrames`；`VirtualCamera/VirtualCameraSink.swift`（`VirtualCameraSink` 协议、`ScheduledOutputTracker`、`CMIOSequenceNumber`）、`CMIOSinkStreamClient`、`VirtualCameraOutput` | **外部显示的 dropped**：P3 只算"拿不到 drawable"。改成 prompt 的口径"引擎给了新帧但两次刷新间被覆盖的次数"：PGM / PVW / 多画面由 `DisplayFrameLedger` 夹在渲染器与 MetalDisplayView 之间转发 `latestDisplayFrame`，按渲染器完成帧版本号在两次呈现之间跳过的个数记（MetalDisplayView 与渲染器都不用改）；Aux 由 presenter 按帧槽分支两次刷新之间的 `FrameSlotStats.dropped` 增量 + 取了没画出去又被新帧顶掉的记。**窗口收起 / 被遮住 / 换源 / 占位期间不记**（那是没在呈现，不是没赶上）。frames = 窗口累计呈现（两种视图相加、换源不清零、占位不算）。state 的 presenting / noDisplay 复核无误保持。**虚拟摄像头**：dropped 按契约注释改成"被扩展丢弃"——连着的时候本端队列满 + 排不进 sink（扩展没及时取）+ **扩展收了没输出的（从扩展来：每帧挂 CMIO 序号，扩展输出后 `notifyScheduledOutputChanged`，本进程在 sink stream 上注册 'sonp' 回调，序号跳号 = 扩展丢的）**；扩展没装时丢的不再进 Stats（仍在 `countersSnapshot.droppedNoDevice`）。state：找不到设备 / 刚掉线 = waitingExtension，设备在但起不来 = **failed**；连上后连续一秒排不进 sink 就关掉重找（以前会一直停在 publishing）。扩展侧那一行 BLOCKED-签名 + 不归本会话，issue W3C2-camera-extension-scheduled-output 写了怎么加、怎么验 |
| 3 主屏层级选项 | `ExternalDisplayWindow.MainScreenLayering`、`ExternalDisplayManager.mainScreenLayering` | 包内选项（不进 `OutputSettings.display`）。`.front` = 默认，行为不变（普通层级、orderFront）；`.behindInterface` = 窗口落在主屏（带菜单栏那块）时层级 normal − 1，主界面和别的窗口永远在它上面、点它也不翻上来；外接屏不受影响。App 的偏好开关归界面（issue） |
| 4 删过渡键后备读取 | `ExternalDisplaySpec.init(settings:)` | 只读 `OutputSettings.display`，没有就是 `DisplayOutputSettings()` 的默认（主屏、`fallbackToMain = false`，提案 015 已落地，两边默认一致）；`extra["displayID" / "fallbackToMain"]` 一律忽略。写出照旧只写正式字段、顺手清旧键。`displayIDKey / fallbackKey` 常量留着——App 的 `OutputExtras.displayNumber(of:)` 还在用它们作后备（P3 报告 §4 第 1 条：W4 / G5 一起删）。P3 的 `testP3_013_specRoundTripsThroughOfficialDisplayField` 后半改成"旧键被忽略" |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'ExternalTests|VirtualCameraTests'`（debug，最后一次 16:09–16:10，机器上没有别的会话在跑测试：
ExternalTests 14 个 1 跳 0 失败 47.8 s、VirtualCameraTests 9 个 0 失败 1.7 s）。开窗的用例会在两块屏上开全屏窗口几秒。

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| Aux 全分辨率（prompt 点名） | `AuxInputTests.testAux_inputWindowDrawsFullResolutionFrame` | 离屏 1920×1080 BGRA8 目标（= drawable 格式），1080p 合成源（契约 TestPattern，噪声底纹 ±60，每个像素都不同）：**BGRA** 对输入字节 0 差、对渲染器 PGM 0 差；**NV12** 对渲染器 **0 / 2 073 600** 像素不同、对 CPU 参考公式 0；另加一张**随机色度的 NV12**（逼出 4:2:0 插值的 0.25 / 0.5 / 0.75 各种权重）对渲染器 0 差、对 CPU 双精度参考 13 像素差 1 LSB；三张帧的帧号 / 输入 ID 在画出来的 1080p 上都解得出。对照组是 `OfflineRenderer`（与实时路径同一个 CompositorPasses）对同一帧的 PGM | 逐像素 = 输入帧（BGRA 字节相等；YCbCr 输入 = 渲染器同一套系数的换算） | ✅ |
| （附加）UYVY | `testAux_uyvyInputMatchesRenderer` | 对渲染器 0 差 | 同上 | ✅ |
| 无信号占位（prompt 点名） | `AuxInputTests.testAux_noSignalDrawsPlaceholder` | 帧槽空 → 占位（先黑底，文字后台好了补画一次，之后不重画）：中间亮像素 2580、左下名字条 775、其余 0；"无信号" / "2  机位二"；来帧 → 画帧（字节相等）；帧断 40 ms 仍是最后一帧、60 ms（> 3 × 16.7）回到占位（与第一次逐字节相同）；运行状态 noSignal → 不画帧；error → 占位中间换成错误文案；文案可换（No signal）；没有帧槽 → 占位 | 画占位、与多画面格子同一套文案 | ✅ |
| （附加）纹理缓存 | `testAux_textureCacheRebuiltOnInputSwitch` | attach 即建（按输入编号），同一路改名不重建，换输入重建，detach 释放 | 预建 / 换输入重建 | ✅ |
| 显示类 Stats（prompt 点名） | `DisplayStatsTests.testStats_displayEntriesCountPresentedFrames` | 内置屏 120 Hz，节目 60 fps：**PGM 窗口 10 s 呈现 600 帧（60.0 fps）dropped 0**，**Aux 窗口 10 s 606 帧（60.0 fps）dropped 0**；每 100 ms 采样 frames / dropped 单调、每秒都在涨、state 全是 presenting；目标显示器 ID 改成不存在（模拟拔掉）→ **noDisplay**、frames 停、dropped 仍 0；改回来 → presenting、继续呈现、**拔插空档不记丢帧** | 10 s 内 frames 单调递增、dropped 0（无负载）、presenting；拔显示器 → noDisplay | ✅ |
| （附加）dropped 口径本身 | `testStats_droppedCountsFramesOverwrittenBetweenRefreshes` | 源比刷新快（240 fps → 120 Hz）：PGM 2 s 新版本 483、呈现 241、dropped 241；Aux 推 480、呈现 240、dropped 240——**呈现 + 丢 = 新帧**（差 ≤ 2，是首尾在路上的） | 被覆盖的都记上、不多记 | ✅ |
| 主屏层级 | `testWindow_mainScreenLayeringOption_keepsInterfaceOnTop` | 默认 `.front`：层级 normal、（宿主是前台时）盖在替身界面上面；`.behindInterface`：层级 normal − 1，界面在上、自己成 key 也不翻上来、仍全屏可见；外接屏上的窗口仍 normal；切回 `.front` 恢复 | 默认行为不变 / 选项不盖住主界面 | ✅（默认的前后次序只在宿主是前台 App 时核，见 §5 第 3 条） |
| 外接屏（硬件这次在） | `testExternal_realSecondDisplay_pgmAndAuxPresentWithoutDrops` | LG 144 Hz：PGM **59.9 fps dropped 0**、Aux **59.9 fps dropped 0**，窗口 = 那块屏的 frame，Aux 的 drawable = **2560×1440**（整块屏的像素，不是格子） | 按那块屏刷新、全分辨率、不掉帧 | ✅ |
| 过渡键 | `ExternalDisplayTests.testP3_013_specRoundTripsThroughOfficialDisplayField` | 正式字段往返；**旧键被忽略**（只有 extra 时 = 主屏 / 不退回）；有正式字段只看正式字段；写出清旧键；缺省 fallbackToMain = `DisplayOutputSettings()` 的默认（false，015） | — | ✅ |
| W3-C 的老用例 | `ExternalDisplayTests` 其余 4 个 | 窗口盖满屏、59.7 fps blit、换源、Esc；插拔等待 / 退主屏；管理器增删多窗口（Aux 窗口开 / 还分支）；显示器列表 | — | ✅ |
| 外接屏 L2 秒表法 | `testL2_externalDisplayStopwatch_manual` | — | UVC ≤ 150 ms（扣设备 ≤ 3 帧） | **BLOCKED-硬件（人工）**：屏有了，缺的是摄像头 + 手机毫秒秒表 + 1/1000 s 快门拍照读数；步骤见 issue W3C2-checklist-external-display-manual §1（给检查点抄进 docs/checklists 的下一版） |
| 虚拟摄像头 Stats | `VirtualCameraTests.testP3_013_virtualCameraStatsEntry`（改了口径） | 没设备：10 帧全进 `droppedNoDevice`，Stats 的 dropped = 0、frames 0、state waitingExtension；dropped = 队列满 + sink + 扩展三项 | 契约注释："被扩展丢弃的帧数" | ✅ |
| 虚拟摄像头连上之后（以前 0 覆盖） | `testVirtualCamera_fakeSinkPublishing_framesDroppedAndStates` | 假 sink：publishing、frames = 30、序号 0…29 连续挂在样本上；sink 满 5 帧 → dropped 5、序号不跳；扩展回报（输出 28、跳号 2）→ dropped 7、framesOutput 28；连续 8 帧排不进 → 关掉重找、waitingExtension、之后丢的不进 dropped；起流失败 → failed；恢复 → publishing、新连接序号从 0 | — | ✅ |
| 扩展丢帧记账 | `testVirtualCamera_scheduledOutputNotificationsCountExtensionDrops` | 走注册给 CMIO 的同一个 C 回调：序号 0,1,2,5,6 → 输出 5 丢 2；重复 / 倒退不算丢；新连接不和旧连接比；第一条通知之前的序号算丢；refCon 为空不崩 | — | ✅ |
| CMIO 序号 | `testVirtualCamera_sequenceNumberRoundTripsOnSampleBuffer` | 默认 invalid；设 41 / 42 读回一致；本机用的是 C 函数（不是附件键后备） | — | ✅ |
| 虚拟摄像头老用例 | 其余 5 个 | 没设备 60 帧全丢、重试 6 次、consume p99 0.008 ms；未签名宿主激活报 BLOCKED-签名 | — | ✅ |
| 虚拟摄像头真扩展的 publishing / 扩展回报 | — | — | — | **BLOCKED-签名**（Team ID + /Applications）；扩展侧还差 `notifyScheduledOutputChanged` 一行（issue 里有代码和验证步骤） |

**主线程开销（交付 1 "主线程不做像素工作"的数字）**：离屏循环 600 次（1080p NV12 → 3456×2234 目标，= 内置屏全屏 drawable），每次 取帧 + 包纹理 + 编码 + 提交：
release **中位 9.8 µs、p99 19.4 µs、最大 49.5 µs**（debug 11.4 / 20.8 / 33.7 µs）；GPU 那一帧另计。临时测量，没留成用例。

**App 这边**（不归本会话，编过 + 跑了两个相关类看影响；`make gen && make build-app` 通过）：
`VirtualCameraAppTests` 2 过 1 跳（L1 BLOCKED-签名）；`ExternalOutputAppTests`：菜单用例过；窗口用例的 PGM 部分过（60.1 fps、missed_render 0 → 0），
**第 3 步 Aux 断言（61–62 行，"输入 2 = 多画面第 2 格"）按裁定必红**——App 还没接帧槽分支、断言也还是 G4 的写法，接线与新断言在 issue W3C2-app-aux-wiring；
`testMultiview_windowTogglesPresentsAndSavesFrame` 红（0 帧），与本分支无关：诊断输出 `occl false / active false / linkPaused true / callbacks 0`——测试宿主不是前台 App，
多画面窗口被别的 App 的窗口盖住，MetalDisplayView 按规矩暂停（§5 第 3 条）。

## 3. 没做的和原因

1. **App 接线**（`aux.external.auxFrames` / `inputStateProvider` / `noSignalText`）和 `ExternalOutputAppTests` 第 3 步的跟改：App/ 不归本会话。**不接的话 Aux 窗口画"无信号"占位**（没有帧槽可读），不再是 G4 那个缩略格子。issue W3C2-app-aux-wiring 有 10 行胶水与新断言，合并检查点按胶水额度做即可。
2. **"Aux = 原始画面"的界面文案、主屏层级的偏好开关**：界面归 App（W3-E2 之后的界面会话）；包里的注释与选项已备好（同一张 issue §3）。
3. **虚拟摄像头的扩展侧回报**：CameraExtension/ 不归本会话，激活 BLOCKED-签名。主程序侧（序号、'sonp' 注册、记账、Stats）做完并用 C 回调测了；'sonp' 在扩展背后的 CMIO 桥上是否照样转发没法在本机验（issue 写了第一次签名跑通时怎么看、桥不转发时的退路）。
4. **外接屏 L2 秒表法**：要摄像头 + 秒表 + 高速快门，人工；**真插拔**也要人拔线。步骤写在 issue W3C2-checklist-external-display-manual，docs/checklists/ 不归本会话，由检查点抄进下一版。
5. **监视器 / 多画面窗口两项的 dropped**：它们在 App（MainWindowController 填，仍是 P3 的 noDrawable 近似）。`DisplayFrameLedger` 是公开的、夹在任何 MetalDisplayView 与渲染器之间都能用，接法写在 App 那张 issue §4。多画面窗口的 noDisplay 复核结论：它是不绑显示器的普通窗口，不需要这个状态。
6. **`Package.swift` 没动**：所以着色器是源码字符串、运行时编译（后台预编，约 80 ms 一次），没法用 .metal 资源。
7. 渲染器的注释过时（default.metallib 是 fast-math）只写了 issue，没动 SwitcherRender。

## 4. 对契约的疑问

1. **`FrameSlot.latest(atOrBefore:)` 的线程注释**写的是"只能由渲染线程调"。G4 的裁定让 Aux 在显示刷新（主线程）上用这个入口读 InputFrameTee 的**分支槽**——那个槽的唯一读者就是这个窗口，SPSC 仍然成立，ISO 的 tap 也是同样用法。建议下一个契约会话把注释改成"单消费者：引擎的渲染线程，或分支槽的唯一读者（ISO / Aux）"（只改注释，不动签名）。
2. **虚拟摄像头 dropped 的口径改了**：P3 把"扩展没装时丢的"也算进 dropped，本会话按 `DisplayEntry` 的注释（"被扩展丢弃的帧数"）改成只算连上之后的三项，没装时的丢帧靠 state = waitingExtension 表达、数字留在 `countersSnapshot.droppedNoDevice`。契约没改（口径本来就是这么写的），请确认；若希望 Stats 里也看得到"没连上期间丢了多少"，要加字段（提案）。
3. **Aux 窗口的输入无信号时 state 仍是 presenting**（窗口在呈现，画的是占位；frames 不涨）。`DisplayEntry.states` 里没有"源无信号"，输入的健康在 `per_input` 里有。觉得需要细分再提。

## 5. 下一个会话需要知道的坑

1. **App 不接三根线，Aux 就是"无信号"**（§3 第 1 条）。`AuxFrameTap` 的两个闭包是 `@MainActor`；关分支要把 `any FrameSlot` 转回 `LockFreeFrameSlot` 再 `InputRuntime.releaseBranch`。每个 Aux 窗口占该路 InputFrameTee 的一个分支（每路 4 个，与 ISO 共用），开不到就画占位、下次快照变了再试。
2. **新 worktree 的 App 起不来（dyld `_swift_initBorrow`）**：`make gen` 生成的 Xcode 工作区会把 swift-collections 解到上游刚发的 1.7.0，它用的运行时符号 macOS 26.6.2 没有；入库的 Package.resolved 与其他 worktree 都是 1.6.0。绕法与正式修法见 issue W3C2-g5-swift-collections-1.7-dyld-crash（拷一份 1.6.0 的工作区 Package.resolved、清 `.build/DerivedData/SourcePackages` 再 resolve）。包级 `swift test` 不受影响。
3. **macOS 14 起的协作式激活让"窗口前后次序"类用例看运气**：测试宿主不是前台 App 时，新窗口 orderFront 排到哪由系统定，被别的 App 盖住的窗口 MetalDisplayView / AuxInputView 会按规矩暂停。本分支的层级用例因此只在宿主真是前台时核默认次序；App 的 `testMultiview_windowTogglesPresentsAndSavesFrame` 今天在本机就是这样红的。跑这类用例前把别的 App 的窗口从主屏挪开或让测试宿主成前台。
4. **Aux 着色器的数学模式要跟渲染器走**：现在是 `.fast`（渲染器实际用的 default.metallib）。渲染器哪天改了换算或数学模式，`testAux_inputWindowDrawsFullResolutionFrame` 的色度噪声那张会红，把 `AuxShaders.swift` 跟着改。
5. **占位文字是后台栅格化的**：离屏测试要先 `nextDraw` 一次（触发栅格化、先画黑底），转事件循环等 `placeholderReady`，再画一次才带字；窗口里下一次刷新自然补上。
6. **"帧断 = 无信号"按到达时刻算**（没给运行状态时）：debug 下逐像素对照一次就要几百毫秒，测试要么给 `inputState = .live`，要么按那一帧的到达时刻传 `now`。
7. **两块屏时 `NSScreen.main` 会跟着 key window 跑到外接屏**：本分支的 dropped 口径用例在全量里跑时"主屏"一度是 144 Hz 的 LG。要绑定内置屏用 `NSScreen.screens.first`。
8. `ExternalDisplayWindow` 新增的公开面：`auxView`、`presentedFrames` / `droppedFrames`（Stats 用它们，别再直接读 `displayView.presentedFrames`）、`auxFrames`、`inputStateProvider`、`noSignalText`、`mainScreenLayering`；`Status` 的三个 case 没变（App 里的 switch 不受影响）。`VirtualCameraOutput.State` 的四个 case 也没变，"failed" 是从最近一次打开失败的原因推的。
9. `swift build` 会在 `Packages/SwitcherOutputs/` 生成未跟踪的 `Package.resolved`，别提交（本会话每次都删了）。
10. **与 W3-E2（w3-app-3，本会话收尾时已完成、未合并）的一处语义交叉**：W3-E2 的 `OutputStatusText.virtualCamera` 在 waitingExtension 时写"已丢 n 帧"、n 取 Stats 的 dropped；
    本分支改了口径（扩展没装时丢的不进 dropped），合并后这句恒为 0。两边测试都不红，改文案即可（issue W3C2-app-aux-wiring §4）。
    W3-E2 也改了 `AuxOutputRuntime` / `SwitcherSession` / `ExternalOutputAppTests`，Aux 接线的片段照样适用，放在它改过的 `SwitcherSession` 里建好 `aux` 之后。
