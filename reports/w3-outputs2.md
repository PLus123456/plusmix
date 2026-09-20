# W3-C 输出二期（外部显示、虚拟摄像头、ISO 与磁盘保护）—— 报告（分支 w3-outputs2）

日期 2026-09-19。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 27.0 (27A266a, Swift 6.4) / XcodeGen 2.46 / ffmpeg 9.0.1 / mediamtx 1.21（brew），电源适配器，桌面端 Claude 全程占 CPU。
worktree `.claude/worktrees/w3-outputs2-ea3903`，分支 **`w3-outputs2`**（桌面端起的 `claude/w3-outputs2-ea3903` 已改名），从 `main`（f1bd1ee，G3 合入之后）开。
提交：`git log main..w3-outputs2`。改动只在 `Packages/SwitcherOutputs/{Package.swift, Sources/{External,ISO,VirtualCamera}, Tests/{ExternalTests,ISOTests,VirtualCameraTests}}`、`CameraExtension/`、`App/`、`project.yml`、本报告和 `reports/issues/`；契约（SwitcherContracts）没碰。
`Packages/SwitcherOutputs/Package.resolved`、`Tools/frameprobe/Package.resolved` 是 swift build 生成的未跟踪文件，没提交（P2 / W1-E2 报告提过的坑）。

本机条件：只有内置屏（外接屏 BLOCKED-硬件）；`security find-identity -p codesigning` 0 个身份、DEVELOPMENT_TEAM 空（签名 BLOCKED-签名）；SIP 开着。

## 1. 做了什么

### 探针（铁律 10，写正式代码之前）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 1080p H.264 的 VTCompressionSession（imageBufferAttributes NV12）能否直接吃别的尺寸 / 格式（ISO 每路输入各异） | 1920×1080 NV12 / BGRA、1280×720 BGRA / NV12、3840×2160 NV12、1920×1080 UYVY、640×360 NV12 full-range 全部 `VTCompressionSessionEncodeFrame` = 0 且出样本 → VT 内部转换 + 缩放，ISO 路不用自己转 |
| 2 | CoreMediaIO 客户端 C API 在 Swift 6 上枚举设备 / 流 | 能；本机 4 个摄像头（内置 / 桌上视角 / iPhone 连续互通），流方向都是 1（设备 → 进程）。所以 sink stream = 方向 0 |
| 3 | `volumeAvailableCapacityForImportantUsage`（`Recorder.freeBytes` 用的键）在小镜像上 | HFS+ / APFS 50 MB 镜像都给 **0**（`volumeAvailableCapacity` / `systemFreeSize` 给 51 MB）→ W1-E 的 Recorder 录到镜像 / 非启动卷立刻按"低于下限"失败，问题单 `reports/issues/W3C-w1-outputs-recorder-freebytes-nonboot-volume.md` |
| 4 | `systemextensionsctl developer on` 在 macOS 26.6.2 上是否要求关 SIP | 要：直接打印 `At this time, this tool cannot be used if System Integrity Protection is enabled`。替代路径见 §3 |
| 5 | ad-hoc 签名 + `com.apple.developer.system-extension.install` 权限能否构建 | 不能：Xcode 拒绝（"has entitlements that require signing with a development certificate"）。App 的权限表按 DEVELOPMENT_TEAM 自动切换（project.yml：`$(SWITCHER_ENTITLEMENTS_$(DEVELOPMENT_TEAM:default=adhoc):default=App/Switcher-signed.entitlements)`，两种情况 `-showBuildSettings` 验证过） |
| 6 | 未签名进程里发 `OSSystemExtensionRequest.activationRequest` | 立刻回 `Missing entitlement com.apple.developer.system-extension.install`（swift test 进程）；ad-hoc 签的 App 测试宿主里的结果见 §2 |

### 交付

| prompt 交付 | 落点 | 做法 |
|---|---|---|
| 1 ExternalDisplayOutput | `Sources/External/`：`ExternalDisplaySpec`、`DisplayInfo` / `ExternalDisplays`、`ExternalDisplayWindow`、`ExternalDisplayManager`；App `AuxOutputRuntime` + `UI/ExternalOutputMenu.swift` | 一个 `kind = .externalDisplay` 的输出 = 一块显示器上的无边框全屏 NSWindow + `MetalDisplayView`（W1-C / W2-B 的显示视图，自己的 display link，渲染线程不碰 drawable）。源 = `settings.source`：PGM / PVW / 多画面直接对应 target；`.input(n)`（Aux）取多画面纹理里它的格子（`MultiviewLayout.inputCell`）。显示器 ID 和"不在时退主屏"放 `settings.extra["displayID" / "fallbackToMain"]`（契约给的占位，不改契约）。插拔：管理器观察 `didChangeScreenParametersNotification` → 每个窗口重新找目标屏：不在就收起（或退主屏），回来放回去。多窗口：管理器按快照增删（键 = 输出编号）。菜单：底栏"外部输出" / 菜单栏"输出 → 外部输出"= 显示器 × 源，选中 = addOutput，已有打勾，再选 = removeOutput；Esc 也走 removeOutput |
| 2 虚拟摄像头 | `CameraExtension/Sources/`（provider / 设备 / 双流 / 占位画面）、`CameraExtension/{Info.plist, CameraExtension.entitlements}`、project.yml target `SwitcherCameraExtension`（type system-extension，嵌到 Contents/Library/SystemExtensions）、`Sources/VirtualCamera/`：`Shared/VirtualCameraConstants`（两边共用）、`CMIOSinkStreamClient`、`VirtualCameraOutput`、`SystemExtensionInstaller`；App `AuxOutputRuntime` + 菜单"输出 → 虚拟摄像头" | 扩展：一个设备两条流，source 给 FaceTime / QuickTime 读（1080p NV12，帧率跟送进来的帧），sink 给主程序写（`authorizedToStartStream` 按 client.signingID 前缀）；sink 收到的帧原样 `send` 到 source（不拷像素，hostTime = 帧的 PTS = 拍点 host time）；没人送时 30 fps 占位画面（深灰 + 移动白条）。主程序：`VirtualCameraOutput` 是 PGM 帧消费者（有界队列 + 自己的线程；NV12 IOSurface 包成 CMSampleBuffer，PTS = 拍点），经 CoreMediaIO 客户端 API 找设备的 sink stream（方向 0）→ `CMIOStreamCopyBufferQueue` + `CMSimpleQueueEnqueue`；找不到设备每秒重试、期间丢帧计数。`SystemExtensionInstaller` 做激活 / 卸载 / 查询，状态映射到文案（缺权限 / 签名 / 位置 → BLOCKED-签名）。开关 = 加 / 删 `kind = .virtualCamera` 的输出 |
| 3 ISO 分路 | `Sources/ISO/`：`InputFrameTee`、`ISOFrameTap`、`SharedTickPlanner`；App `InputRuntime`（tee）、`OutputRuntime`（ISO 路 / 一批共用起止拍）、`UI/ISOPanel.swift`（选路 + 余量） | 一路 ISO = 契约里 `kind = .record、source = .input(n)` 的输出（CONTRACTS §8 "ISO = 同一拍发多条"）。视频从哪来：输入拿到的帧槽是 `InputFrameTee`（主槽给引擎，分支给 ISO）；`ISOFrameTap` 每拍在分支上按契约规则 `latest(atOrBefore: 拍点)` 挑该路的帧，换上这一拍的 tick / 拍点交给该路的 Recorder → ISO 文件与 PGM 同一拍点网格、PTS 共用；30 fps 输入同一帧录两次（与 PGM 一样）。音轨挂 `AudioTapSource.input(number:)`（推子后、AFV 前，G3 定）。同一拍起：一次 reconcile 里新开的录制输出是一批，共用 `max(现在 + 2, 最晚生效拍 + 10 + 每多一路 3 拍)`，rec.start 并发做；后来的路上一批的拍还在未来 ≥ 6 拍就沿用。同一拍停：边界 = 生效拍 + 10，命令生效就 `rec.stop(atTick:)`（W1-E2 语义，撤了 W2-B2 的 FrameGate / AudioGate 和等音频块的那段 = G4 交接第 3 条）。UI：底栏"ISO…"面板每路输入一个开关（= 加 / 删 ISO 输出），显示录制目录、剩余空间、按所有录制路码率之和估的"还能录多久"；底栏"录制"对全部录制输出一起发 startRecord / stopRecord |
| 4 磁盘保护（S7） | `Sources/ISO/DiskGuard.swift`：`DiskGuard`（归因 / `freeBytes`）、`DiskEstimate`、`RecordingFallback`、`RecordingDiskMonitor`；App `OutputRuntime.handleDisk`、`AppSettings`（`--record-fallback` / `--record-min-free-mb`，UserDefaults 同名键） | 停录制的是 Recorder 自己（写失败 → `.failed`，只影响本路）；监视器每秒看每路剩余空间（自己算，非启动卷也对）：跌破 1 GB 提示；跌破下限（默认 200 MB）或写满 → 有备用目录就在下一拍把那一路切到备用目录继续录（S7 目标档），否则只停那一路并发 `stopRecord` 让快照一致 + 状态行提示。推流 / 渲染不在这条链上 |
| 5 多画面独立窗口 | App `UI/MultiviewWindowController.swift`（底栏"多画面" / 菜单"窗口 → 多画面"），位置存 `Show.layout["multiviewWindowFrame"]` | `MetalDisplayView(target: .multiview)`，16:9，可拖到任何屏 / 全屏 |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'ISOTests|ExternalTests|VirtualCameraTests'`（debug，三个新 target 共 18 个用例，约 1 分钟）；
App 级 `xcodebuild test -only-testing:SwitcherTests/{ExternalOutputAppTests,ISOAppTests,DiskProtectionAppTests,VirtualCameraAppTests}`（9 个用例，约 1 分钟）；
整个 App 测试 target（老测试 + 新测试）见 §2.1。输出文件在 `$TMPDIR/switcher-iso-tests/`、`$TMPDIR/switcher-tests/`。

| 测试 ID | 测试函数 | 数值 | 阈值（必须 / 目标） | 通过 |
|---|---|---|---|---|
| **A4** 多文件对齐（包级） | `ISOTests.testA4_fourVideoISORoutesPlusPGM_sameEventWithin1Frame` | 720p60 实时 10 s：PGM + 4 路视频 ISO（经 InputFrameTee → ISOFrameTap → Recorder，第 4 路 30 fps）+ 各自的 click 音轨；5 个文件都 600 帧、首帧 PTS 0、跳帧 0、编码延迟 max 30.8–34.2 ms；frameprobe av 多文件 10 个事件：**闪光极差最大 0.000 ms、click 极差最大 0.000 ms**；30 fps 那路每拍都有输出、300 拍重复、60 fps 的路 0 重复；喂帧晚点 0 | ≤ 1 帧（16.67 ms）/ ≤ 1 ms | ✅（两档都过） |
| **A4**（App 级） | `ISOAppTests.testA4_app_isoRoutesSharedStartAndStop_filesAlignWithin1Frame` | 真引擎 1080p60，三路合成源（60 / 30 / 60 fps，带音频）；ISO 面板加 1、2 号的 ISO 路 → 底栏录制按钮一起起停：三个录制器**同一起始拍 #95、同一边界拍 #595**，各 500 帧 / 400000 样本、两轨、跳帧 0，rec.start 三路并发批耗时 48.1 ms；8 个事件闪光 / click 极差最大 **0.0 / 0.0 ms** | 同上 | ✅ |
| **S7** 磁盘满（包级） | `ISOTests.testS7_recordToFull50MBImage_onlyThoseRecordersStop_streamCountUnchanged_fallbackRestarts` | `hdiutil create -size 50m` HFS+ 镜像；两路 40 Mbps 噪声录到它、一路 6 Mbps 录正常目录、一个只数帧的推流替身同吃 960 拍（16 s）：1 号在 t + 3.9 s 收到监视器"低于下限 12 MB"事件后按下一拍停，文件完整（237 帧 = 停止拍）；2 号 t + 6.4 s 真写满（`AVFoundationErrorDomain -11807 磁盘已满 / ENOSPC`）→ `.failed`，归因 disk，失败事件之后下一拍在备用目录重起、录完剩下的 575 拍，文件 ffprobe 无错；正常目录那路 960 帧跳帧 0、替身 960 帧（推流帧数不减）；两路小盘都先报低空间（t + 2.0 s）再报下限 / 失败，正常那路没有事件 | 只停录制并提示；推流不受影响 / 自动切备用目录 | ✅（两档都过；渲染在 App 级看） |
| **S7**（App 级 a：低于下限只停） | `DiskProtectionAppTests.testS7_lowSpaceStopsOnlyRecording_streamAndRenderUnaffected` | 50 MB APFS 镜像作录制目录（默认下限 200 MB）+ 真推流到本机 MediaMTX：起录制后 1 s 内监视器报下限 → 只停这一路（发 stopRecord，快照 enabled 回 false，failed 清掉）、状态行提示"磁盘剩余 47 MB，低于下限 200 MB"；之后 3 s 推流帧数 88 → 268、状态 publishing，**missed_render 0 → 0** | 同上 | ✅ |
| **S7**（App 级 b：写满切备用） | `DiskProtectionAppTests.testS7_diskFullSwitchesToFallbackDirectory_recordingContinues` | 下限 0 + 备用目录，40 Mbps 噪声：约 10 s 写满 → 下一拍切到备用目录继续录（提示"磁盘满，已切到备用目录"），enabled 仍 true，停后结果是备用文件、≥ 2 s、ffprobe 无错；missed_render 不增 | 目标档 | ✅ |
| 虚拟摄像头：QuickTime / FaceTime 可见、帧号在走 | `VirtualCameraAppTests.testVirtualCamera_extensionActivationInAdHocSignedApp_reportsBlocked`（激活路径） | 扩展已嵌进 Switcher.app（`Contents/Library/SystemExtensions/com.example.switcher.camera-extension.systemextension`，ad-hoc 签，SYSX，CMIOExtensionMachServiceName = `<TeamID>com.example.switcher.camera`）；ad-hoc 宿主里 `activate()` 立刻回 `Missing entitlement com.apple.developer.system-extension.install`，安装器文案带 BLOCKED-签名，状态行提示 | 能选到、帧号在走 | **BLOCKED-签名**：解锁 = Team ID（`DEVELOPMENT_TEAM=<TeamID> make gen`，权限表自动换成 Switcher-signed.entitlements）+ 从 /Applications 运行 + 菜单"输出 → 虚拟摄像头 → 安装 / 激活扩展"，系统设置里允许，再在 FaceTime 里选 "Switcher" |
| 虚拟摄像头：主程序侧 | `VirtualCameraTests`（5）+ `VirtualCameraAppTests.testVirtualCamera_outputToggleStartsConsumer…` | 帧 → CMSampleBuffer 同一个 IOSurface、PTS = 拍点、格式描述按（格式, 尺寸）缓存；没设备：状态 searching、60 帧全部丢并计数、1 s 内按 200 ms 重试 6 次、consume p99 0.015 ms、stop 干净；App 里加 / 删 `.virtualCamera` 输出起停消费者，2 s 收 121 帧、找设备 2 次、missed_render 不增；本机 CMIO 设备 3 个（内置 / 桌上视角 / Metadata Camera），都没有 sink 方向的流 | — | ✅ |
| 虚拟摄像头：L1 到出口 ≤ 3 帧 | `VirtualCameraAppTests.testL1_virtualCameraEgress_requiresSignedExtension` | — | ≤ 3 帧 | **BLOCKED-签名**（同上；解锁后第二个进程 AVCaptureSession 选 Switcher 摄像头抓帧、frameprobe 解帧号与 stats.jsonl 的 tick 对照） |
| 外部显示：全屏 PGM、拖主窗口不掉帧 | `ExternalOutputAppTests.testExternal_windowOnDisplay_followsProgram_dragMainWindowNoMissedRender_auxInput_closeByCommand` | 主屏（120 Hz）上全屏窗口：3.2 s blit 194 次 = **59.9 fps**（每个节目帧一次）；拖主窗口 2 s + 全程 **missed_render 0 → 0**；Aux 输入 2 → 多画面第 2 格；节目文件带着输出（displayID / source）；删输出关窗口；命令 0 拒绝 | 不掉帧 | ✅（外接屏部分 BLOCKED-硬件） |
| 外部显示：窗口 / 插拔 / 多窗口（包级） | `ExternalTests`（6） | 窗口盖满指定屏、59.7 fps blit（display link 300 次 / 2 s = 120 Hz）；换源即时；Esc 请求关闭；显示器不在 → 收起等待 / 退主屏 → 回来放回；管理器按输出表增删多窗口、显示器参数变化通知到每个窗口；设置经 OutputSettings.extra JSON 往返 | — | ✅ |
| 外部显示：L2 秒表法 5 次 | `ExternalTests.testL2_externalDisplayStopwatch_manual` | — | UVC ≤ 150 ms（扣设备 ≤ 3 帧） | **BLOCKED-硬件**：本机只有内置屏。解锁：接 HDMI 显示器 + 摄像头 + 手机毫秒秒表；步骤：外部输出菜单选那块屏 · PGM，摄像头对着秒表，1/1000 s 快门同框拍秒表与显示器，读差，5 次取中位数，另拍一次摄像头直连显示器作扣除 |
| 多画面独立窗口 | `ExternalOutputAppTests.testMultiview_windowTogglesPresentsAndSavesFrame` | 底栏按钮开 / 关，1 s 内 blit > 30 次，位置进 Show.layout（`multiviewWindowFrame` / `multiviewWindowVisible`） | — | ✅ |
| 单元：分流器 / tap / 起停规划 / 估算 / 归因 | `ISOTests.TeeTapPlannerTests`（5） | tee push（主槽 + 4 分支）p99 0.0008 ms；分支摘掉后不再收、静默期回收；tap 按契约规则挑帧 / 重复 / 无帧计数；同一批共用拍、后来的路在未来 ≥ 6 拍内沿用、过了另起；估算 / 备用路径 / 归因文案 | push 微秒级 | ✅ |

BLOCKED 汇总：虚拟摄像头激活与 L1（BLOCKED-签名，代码已编译并嵌入）、外接屏 L2 与"挪到外接屏"（BLOCKED-硬件）。慢 U 盘（S7 第二种）没有外置盘，没测。

### 2.1 老测试有没有回归

- **整个 App 测试 target**（`xcodebuild test`，36 个用例，133 s）：34 过、2 跳过（内置摄像头 TCC、虚拟摄像头 L1 BLOCKED-签名）、2 失败——都是 W2-B `UISmokeTests` 里"外部输出 / 多画面按钮置灰（W3-C / W3-E 再做）"的旧断言，本会话把两个按钮接通了，断言改成"可用"（不是放宽阈值，是行为按 prompt 变了）；改后 `UISmokeTests` + `ExternalOutputAppTests` 重跑 5 / 5 过。W2-B2 的 `RecordingTests`（5 s 两轨时长精确、起止拍差 = 按钮间隔 ± 1 帧）在改成"命令生效即 rec.stop"之后仍过；`StreamWiringTests`（MediaMTX 10 s 落盘帧号连续）过。
- **SwitcherOutputs 整包 `swift test`**（六个 target，debug，共约 26 分钟，机器上没有别的 headless 在跑）：`SwitcherOutputsTests`（W1-E / W1-E2 的 25 个：E1 / E2 / E3 / E5 × 4 / E6 / ISO / 磁盘 / ProRes / 转封装 / click / AudioEncoder 等）全过；`StreamingTests` 28 个全过（本 worktree 编了 release frameprobe，W1-E2 时跳过的 4 个端到端这次也跑了；含 E9 的 5 分钟限速，720 s）；`NDISendTests` 8 个（2 跳过：人工 Studio Monitor、"无 SDK"用例）过；新加的 `ISOTests` 7、`ExternalTests` 6（1 跳过 L2）、`VirtualCameraTests` 5 全过。W1-E2 报告 §5 提醒的 `testISO_fourRecorders30s`（4 路 1080p60 贴着硬件编码器吞吐）这次也过。
- App 级 A4 第二次跑（修了测试里"启动时 replaceSession 还没完成就再调一次会被 `replacing` 挡掉"的竞争之后）：起始拍 #94、批 rec.start 49.5 ms、闪光极差 0.0 ms、click 极差 0.02 ms。

## 3. 没做的和原因

1. **Aux 输入的全分辨率画面**：外部显示选"输入 n"时画的是多画面纹理里它的格子（1080p 多画面里约 470×260），不是该路的原始分辨率。全分辨率要渲染器每拍给每路一张纹理（或 Aux 合成目标），那是 SwitcherRender（W1-C / W3-B）的地盘；也可以在本包用 CVMetalTextureCache 直接画分支槽里的输入帧（NV12 / BGRA / UYVY 各写一套着色器，约 200 行），本会话没做。写进 §4 请裁定归属。
2. **虚拟摄像头的激活、FaceTime 可见性、L1**：BLOCKED-签名（§2）。扩展的 provider / 流 / 占位画面逻辑只编译过、没在系统里跑过；`consumeSampleBuffer` / `send` 的调用形态照 CMIOExtension 的头文件写，签名后第一次跑要看 `log stream --predicate 'subsystem == "app.switcher.camera-extension"'`。
3. **`systemextensionsctl developer on`**：macOS 26.6.2 要求关 SIP（探针 4），没做；替代路径写在 `SystemExtensionInstaller.developerModeHint` 和 CameraExtension/README.md。
4. **ISO 路的音轨在输入没注册音频时不带**（文件只有视频轨）；PGM 录制的口径不变。
5. **外部显示窗口的层级是 normal**：在主屏上开会盖住主界面（Esc 关；测试里就是这么用的）。外接屏上无所谓。要"永远在最上层"再改 level。
6. **Stats 里没有外部显示 / 虚拟摄像头的项**（§4 第 1 条），它们的帧数只在各自对象的计数里（`MetalDisplayView.presentedFrames`、`VirtualCameraOutput.countersSnapshot`，菜单的状态行读后者）。
7. **慢 U 盘的 S7**：没有外置盘。

## 4. 对契约的疑问

1. **外部显示 / 虚拟摄像头的统计不在 Stats 里**：`Stats.encoder[]` 的定义是"带编码器的输出（record / stream / ndi）"，显示类输出没有位置。铁律 4 说所有数字进 Stats，但 W2-B 的显示视图（`presentedFrames`）也在 Stats 之外，本会话沿用同一做法。要进的话得加字段（例如 `outputs[{kind, frames, dropped, state}]`），请定。
2. **显示器 ID 放 `OutputSettings.extra["displayID"]`（数字）/ `["fallbackToMain"]`（布尔）**：用的是契约给各输出会话的占位字段，没改类型；键名写在 `ExternalDisplaySpec.displayIDKey / fallbackKey`。如果希望它是正式字段（`OutputSettings.display: DisplaySettings?`），写提案再迁。
3. **ISO 路 = `kind: .record, source: .input(n)` 的输出**：按 CONTRACTS §8 "ISO = 同一拍发多条 startRecord" 的字面做，没加 kind；`Stats.encoder` 里每路 ISO 各占一项（与 outputs 同序），状态行"● 录制中（n 路）"。
4. **`Recorder.freeBytes` 在非启动卷上是 0**（问题单 `reports/issues/W3C-w1-outputs-recorder-freebytes-nonboot-volume.md`）：本会话在 App 里把 `Recorder.minimumFreeBytes` 设 0、下限由 `RecordingDiskMonitor` 管，idle 录制输出的 `disk_free_mb` 改用 `DiskGuard.freeBytes`；**在跑的录制器报的 `disk_free_mb` 仍是 Recorder 算的**（非启动卷上 0），等 W1-E 那三行修好自然对。建议 G4 按胶水额度直接修。
5. **Aux 全分辨率归谁**（§3 第 1 条）：渲染器出每路纹理（W3-B 的 Aux 合成目标）还是本包自己画输入帧，请定。

## 5. 下一个会话需要知道的坑

1. **ad-hoc 签名 + 受限权限 = Xcode 拒绝构建**（探针 5）：`com.apple.developer.system-extension.install` 只能在有 Team ID 时进权限表。project.yml 用 `$(SWITCHER_ENTITLEMENTS_$(DEVELOPMENT_TEAM:default=adhoc):default=App/Switcher-signed.entitlements)` 自动切（`-showBuildSettings` 两种情况都验过）；W4-B 做正式签名时把 bundle ID（`com.example.switcher` / `.camera-extension`）和 `VirtualCameraConstants` / Info.plist 的 mach service 名一起改。
2. **`volumeAvailableCapacityForImportantUsage` 在磁盘镜像上是 0**（探针 3）；测录制 / 磁盘一律用 `DiskGuard.freeBytes`。hdiutil 小盘失败时可能留挂载点：`hdiutil detach $TMPDIR/switcher-iso-tests/s7-tiny-volume -force`、`$TMPDIR/switcher-tests/s7/{a,b}-volume`。
3. **同一拍起多路的 rec.start 是并发的**（`DispatchGroup`，主线程等最多 5 s）：三路 48 ms；串行的话每路 64–80 ms，5 路会超过 lead。批的起始拍带每多一路 + 3 拍的余量，`lastStartCost` 可看。
4. **`OutputRuntime.stopRecording` 已按 G4 交接第 3 条简化**：命令生效就 `rec.stop(atTick: 边界)`，FrameGate / AudioGate 删了；G4 / W3-E 不用再做。边界仍 = 生效拍 + 10（与起点对称，时长 = 两条命令生效拍之差），批内共用。
5. **`InputFrameTee` 的分支最多 4 个 / 路**（ISO + Aux 共用额度；现在只有 ISO 用），摘下的分支延迟 1 s 释放（输入线程可能正拿着 push）。输入工厂的 `slot` 参数已改成 `any FrameSlot`（输入实现本来就收 `any FrameSlot`）。
6. **外部显示 / 虚拟摄像头的开关都是加 / 删输出**（没有 start/stop 命令；`enabled` 只有 addOutput 能设）；`ShowDocuments.stoppingOutputs` 只清 record / stream 的 enabled，所以节目文件里的外部显示输出打开就恢复窗口——这是想要的。
7. **ISO 路的文件名模板要带 `{output}`**（`ISORoutes.makeISOOutput` 自动加），否则同一秒起的几路同名；OutputRuntime 另有兜底（同名加编号）。
8. **MediaMTX 测试路径只配了 s1 / s2 / s3**（scripts/mediamtx.yml），推别的 path 会被 "path not configured" 拒（S7(a) 第一版踩的）。
9. **测试输出别用 `| head`**：xcodebuild test 被 SIGPIPE 掐断后面的用例就不跑了；写进 `.build/*.log` 再 grep。
10. 老 App 测试改了 `session.outputs.recorders[n]` 的类型（`RecordEntry` 多了 `consumer / branch / url / onFallback`，少了 `gate / audioGate`）；`OutputRuntime.init` 多了 `inputs:`。
