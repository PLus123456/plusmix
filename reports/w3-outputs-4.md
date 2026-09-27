# W3-C3 输出收尾：包里的中文文案、扩展侧回报"已输出"、ISO 估算只出数 —— 报告（分支 w3-outputs-4）

日期 2026-09-27。机器 Apple M5 Max 128 GB / **macOS 27.0 (26A428)**（W3-C2 时是 26.6.2，这台机器之间升级过）/ Xcode 27.0 (27A266a, Swift 6.4)，电源适配器；
内置 Liquid Retina XDR（120 Hz，主屏）+ LG ULTRAGEAR（2560×1440，144 Hz）。
worktree `.claude/worktrees/w3-outputs-4-finish-5f0bbb`；桌面端给的分支 `claude/w3-outputs-4-finish-5f0bbb` 没动，从同一提交另开 **`w3-outputs-4`** 并在上面提交；
从 main **67d0f6b**（G4 第二批续做合入、提案 017 落地之后）开。提交：`git log main..w3-outputs-4`（先写测试 1、实现 3、问题单 1、报告 1）。
改动只在 `Packages/SwitcherOutputs/{Sources,Tests}/{External,ExternalTests,VirtualCamera,VirtualCameraTests,ISO,ISOTests}/`、`CameraExtension/`、
`reports/issues/` 与本报告。App/、Package.swift、契约、测试标准都没碰。`make lint BRANCH=w3-outputs-4` 全绿（禁词 / 版本号 / 依赖方向 / 归属 21 个文件 / RT 符号）。

**合入要带胶水**：`SystemExtensionInstaller.Status.failed` 改成带枚举原因之后，App 有 1 处源码、2 处测试编不过。App/ 不归本会话；
我在本 worktree 里临时打上补丁验证过（没提交），diff 原样写在 `reports/issues/W3C3-app-extension-failure-reason-and-disk-free.md`（必需 33 行 + 可选 6 行）。

## 1. 做了什么

### 探针与"先红"（铁律 10 / 铁律 2）

| # | 问题 | 结论 |
|---|---|---|
| 1 | CMIO 扩展侧"已输出"的 API 在 Swift 里长什么样；进程内（没接 provider 服务）调会怎样 | 与头文件一致：`CMIOExtensionScheduledOutput(sequenceNumber:hostTimeInNanoseconds:)`；`consumeSampleBuffer` 的回调是 `(CMSampleBuffer?, UInt64 序号, DiscontinuityFlags, Bool hasMore, Error?)`；对没接服务的 sink 流调 `notifyScheduledOutputChanged` **不崩、什么也不做**。头文件：notify 的时刻是"这一帧输出的 host time（纳秒）"，主程序的 'sonp' C 回调是 `(序号, 输出 host time, refCon)`，`kCMIOInvalidSequenceNumber = ~0` |
| 2 | 未签名宿主里发系统扩展激活请求，回什么错误（归类用） | 命令行宿主与 SwiftPM 的 xctest 宿主都回 **`OSSystemExtensionErrorDomain` 2 = missingEntitlement**（"Missing entitlement com.apple.developer.system-extension.install"）→ 归 `requirementsNotMet`；App 的 ad-hoc 测试宿主同样（打了胶水的 App 用例实测） |
| 3 | 扫描用例是不是先红 | 扫描器单独编出来对 main（67d0f6b）跑：**47 处**中文字面量——External 14、VirtualCamera 21、ISO 6、CameraExtension 5 + Info.plist 显示名 1 |

### 交付

| prompt 交付 | 落点 | 做法 |
|---|---|---|
| 1 包里给人看的中文收口 | `VirtualCamera/SystemExtensionInstaller.swift` | `Status.failed(String)` → **`.failed(Failure)`**：`Failure.reason` 是枚举（extensionNotFound / requirementsNotMet / canceled / superseded / other，按 OSSystemExtensionError 的码归类），另带系统给的 `domain` / `code` / `detail`（NSError.localizedDescription，系统按用户语言本地化，可原样附在查表文案后面）；`isSigningBlocked` = 前两种。`describe(_:)` 与 `developerModeHint` 没人调，删了（提示挪进类型注释与 CameraExtension/README） |
| | `VirtualCamera/CMIOSinkStreamClient.swift`、`VirtualCameraOutput.swift` | `CMIOSinkStreamClient.Error` 去掉中文 `description`，只剩枚举（`Hashable, Sendable`）；`Counters.lastError: String?` → **`lastFailure: ConnectionFailure?`**（`.open(客户端错误)` / `.openOther(调试描述)` / `.sinkStalled(frames:)`） |
| | `External/ExternalDisplayWindow.swift`、`ExternalDisplayManager.swift` | 窗口标题 **`windowTitle`**（默认 ASCII `defaultWindowTitle` = "Switcher External Output"），可由组装方传入；管理器的 `windowTitle` 下发给现有与以后开的窗口。`ExternalDisplayManager.describe` / `ExternalDisplaySpec.describe` 没人调，删了 |
| | `External/AuxInputPresenter.swift`、`AuxShaders.swift`、`AuxInputView.swift` | Aux 占位的默认文案 "无信号" → **"No signal"**（App 本来就按 `input.noSignal` 传）；着色器源码也是字符串字面量，里面的注释 / `static_assert` 改英文（中文说明留在 Swift 注释里），precondition / 报错 / NSLog / fatalError 改英文。改后 Aux 仍对渲染器逐像素相同 |
| | `VirtualCamera/Shared/VirtualCameraConstants.swift`、`CameraExtension/` | 流名 "Switcher 节目 / 输入" → "Switcher Program / Switcher Program Sink"（没人按名字找流）；扩展日志改英文；Info.plist 的 `CFBundleDisplayName`（系统设置里看得见）→ "Switcher Virtual Camera" |
| | 扫描用例 `VirtualCameraTests/SourceLanguageTests.swift` | 与 App 的 `LocalizationTests` 同法（找字符串字面量里的 CJK），但**不留豁免**：日志 / 断言行、多行字符串、原始字符串、插值里套的字面量、`\u{…}` 转义都算，块注释（可嵌套）与字符串里的 `//` 分得清；CameraExtension 下的 plist 字符串值也扫。扫描器先对 17 行样例自检 |
| 2 扩展侧回报"已输出" | `CameraExtension/Sources/CameraExtensionProvider.swift` 的 `consumeNext` | 接住 `sampleBufferSequenceNumber`；`sourceStream.stream.send` 之后 `sinkStream.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(序号, 此刻))`——时刻按头文件用发出去那一刻（不是 PTS）；序号是 `UInt64.max`（没挂上）的不回报；扩展自己丢的帧不回报（跳号就是记账）。xcodebuild 编过扩展 target |
| | `VirtualCamera/VirtualCameraSink.swift`（主程序侧守卫） | W3-C2 的 'sonp' 记账不变（相邻序号差 − 1 = 扩展丢的），加一道守卫：sink **排队之前** `ScheduledOutputTracker.noteSent` 记下这一帧的序号（`CMIOSinkStreamClient.send` 里做）；回报的序号不是本连接排过的（invalid / 比排过的都大 / 新连接还没排过帧时到的旧连接回报）只记 **`unmatched`**（`SinkOutputReport.unmatched`、`Counters.extensionUnmatched`），不算输出也不算丢——CMIO 桥万一没把序号原样带过去，Stats 的 dropped 不会冒出上亿的数，第一次签名跑通时一眼看得出。dropped 的口径没动（仍 = 本端队列满 + 排不进 sink + 扩展丢的，W3-C2 / 提案 018） |
| 3 ISO 磁盘余量估算 | `ISO/DiskGuard.swift` 的 `DiskEstimate` | `describe(seconds:)` 删了，只剩数：`bytesPerSecond`（字节 / 秒）、`remainingSeconds`（秒；没有码率 = +inf）。"还能录多久"的文案 App 已有（`ISORoutes.remainingText`） |
| | `DiskGuard.classify` | 归因词表里的"磁盘""写入失败"是在匹配 W1-E 录制器**给人看的中文失败文案**（系统描述也随用户语言变），删掉；只认与语言无关的磁盘错误码（-11807 / POSIX 28 / 640）+ 系统英文说法 + 剩余空间。录制器**自己按下限停的**改由新的 `classify(recorder:message:freeBytes:)` 按它的读数认（设了下限、它比下限之前记下的 `diskFreeBytes` 低于下限 → 磁盘），`failureCause(of:)` 与 `RecordingDiskMonitor` 都走它。**行为变化**：空间充足、又没有磁盘错误码的写失败从 disk 变 other（拔盘时剩余空间量出来是 0，仍归 disk） |
| | `Recorder.freeBytes` 非启动卷问题（W3-C 报告 §4 第 4 条，W1-E 还没修） | ISO 侧兜住：`DiskGuard.diskFreeBytes(of:counters:)` / **`DiskGuard.statsEntry(for:counters:previous:windowSeconds:)`**——录制器自己的读数是 0 时用 `DiskGuard.freeBytes` 重新量，其余字段与 `RecorderCounters.statsEntry` 逐字段相同。App 的 `OutputRuntime` 换成调它是一行（问题单的可选项 6）；W1-E 修好之后读数不再是 0，这里原样用，不必撤 |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'ExternalTests|VirtualCameraTests|ISOTests'`（debug，10:11–10:13；frameprobe 先 `swift build -c release` 编好）。
机器上**有别的会话在跑**（1 分钟负载 9.2 → 6.4），显示统计类用例照样全过。三个 target 合计 37 个用例：**36 过、1 跳（L2 人工）、0 失败**。
SwitcherOutputs 的另外三个 test target（SwitcherOutputsTests / StreamingTests / NDISendTests）不 import 本会话动的三个模块（grep 核过），只编过（`swift build --build-tests`）没重跑。

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| 包源码中文字面量（prompt 点名） | `SourceLanguageTests.testL10n_packageSourcesHaveNoChineseLiterals` | 四个目录 22 个 Swift 文件 + 1 个 plist：**0 处**（main 上 47 处）；每个目录都确认有源文件（路径写错不会空跑通过）；5 ms | 0 处 | ✅ |
| （附加）扫描器自检 | `testL10n_scannerFindsChineseInLiteralsNotInComments` | 17 行样例里 9 个含中文的字面量全抓到、行号对；行注释 / 嵌套块注释 / 文档注释 / 字符串里的 `//` / 插值里的字面量 / `\u{4E2D}` / `#"…"#` 与 `##"…"##` / 多行串 / 没闭合的块注释都对 | — | ✅ |
| 扩展回报记账（prompt 点名） | `VirtualCameraTests.testVirtualCamera_extensionReportsViaSonp_sequenceGapsBecomeDropped` | 假扩展按 CameraExtension 的做法读样本上的序号、经注册在 sink 上的 'sonp' C 回调回报、自己丢的不回报。**同步**：61 帧、扩展丢 6（序号 9…59）→ framesOutput 55、droppedExtension 6、Stats dropped 6、frames 61、undelivered 0、publishing；**异步**（扩展自己的队列上回）：101 帧里丢 10 → 回报 (91, 10)，下一次送帧时计数 dropped 10、framesOutput 91–92（最后一帧的回报可能在路上）；**重连**：新连接序号从 0，旧连接迟到的回报与 invalid 回报 → unmatched 2、dropped 仍 10；Stats dropped = countersSnapshot 三项之和。整段：送 114、输出 104、扩展丢 10、对不上 2 | 跳号 = 扩展丢的帧；对不上的回报不进 dropped | ✅ |
| 'sonp' 守卫 | `testVirtualCamera_scheduledOutputNotificationsCountExtensionDrops`（改：先 noteSent） | W3-C2 的全部断言照旧；另加：invalid 序号、比本连接排过的大、新连接还没排过帧时到的回报 → unmatched 1 / 2 / 3，没挂序号的帧不抬高"排过的最大序号" | — | ✅ |
| DiskEstimate 纯数字（prompt 点名） | `ISOTests.TeeTapPlannerTests.testS7_diskEstimateReturnsNumbersOnly` | H.264 8 Mbps + AAC 160 k = 1 020 000 B/s；只视频 HEVC 20 Mbps = 2 500 000；只 AAC 192 k = 24 000；都没有 = 0；PCM 48 k × 2 / 8 声道 × 24 bit = 288 000 / 1 152 000（与码率设置无关）；(剩余 − 保留) / B/s = 100 s；保留 ≥ 剩余 → 0；没码率 → +inf；8 TB → 7 843 137.25 s；PGM + 4 路 ISO 相加 = 3 850 000 | 只出数 | ✅ |
| 归因（改） | `testS7_fallbackURL_and_classifyByErrorCodeAndFreeSpace` | -11807 / POSIX 28 / 640 / "not enough space" → disk（空间 10 GB 也是）；剩余 < 64 MB 的写失败 → disk；编码器起不来 → other；**空间充足、无磁盘码的写失败 → other**（行为变化）；卷不在 → 剩余 0 | — | ✅ |
| 录制器按自己的下限停 = 磁盘 | `RecorderDiskTests.testS7_recorderStoppedByItsOwnMinimumIsDisk_withoutReadingMessageText` | 真 Recorder（下限设成 UInt64.max）起步即停，文案"磁盘剩余 1 539 655 178 659 字节，低于下限 …"（W1-E 的）；启动卷空间充足、光看文案 + 空间认不出 → `failureCause` = disk；监视器报 `.failed(cause: .disk)` 一次、文案原样转给组装方；下限 0 的录制器照常按错误码归 | 不靠中文文案 | ✅ |
| 在跑录制器的 disk_free_mb | `RecorderDiskTests.testS7_runningRecorderDiskFreeFallsBackToDiskGuard_nonBootVolume` | 50 MB HFS+ 镜像上起录制器：**录制器自己读 0**（`Recorder.freeBytes`），`DiskGuard.statsEntry` 给 **48.8 MB**（DiskGuard 量 51 163 136 B），其余字段与 `RecorderCounters.statsEntry` 相同；启动卷上录制器读数非 0 → 原样用；没起过的录制器也量得出 | 非启动卷不报 0 | ✅ |
| S7（W3-C 老用例，跟着看归因） | `DiskProtectionTests.testS7_recordToFull50MBImage_…` | 1 号第 242 拍收到下限事件、停在 243 拍，文件 243 帧完整；2 号写满，失败文案"音频写入失败：…Code=-11807 "磁盘已满"…NSPOSIXErrorDomain Code=28…"——**按错误码归 disk**（不再需要中文字样），下一拍在备用目录重起；正常那路帧数 = 拍数、跳帧 0；替身帧数不减；先低空间（t + 2.00 s）后下限 / 失败 | 只停录制；切备用目录 | ✅ |
| A4（W3-C 老用例） | `ISOAlignmentTests.testA4_…` | 5 个文件各 600 帧 / 480 000 样本、首帧 PTS 0；10 个事件闪光 / click 极差最大 0.0 ms；喂帧晚点 0 | ≤ 16.67 ms（目标 ≤ 1 ms） | ✅ |
| 安装器状态映射（改） | `VirtualCameraTests.testInstaller_statusMapping` | 码 → 原因：extensionNotFound；codeSignatureInvalid / validationFailed / missingEntitlement / unsupportedParentBundleLocation / forbiddenBySystemPolicy → requirementsNotMet（isSigningBlocked）；取消 / 替代；authorizationRequired → needsUserApproval；unknown / 缺标识 / 重复 / 类别不认识 / 别的域 → other；域 / 码 / 系统描述原样带着 | — | ✅ |
| 未签名宿主激活（改） | `testInstaller_activateInUnsignedHost_failsWithSigningReason` | requesting → failed(requirementsNotMet, OSSystemExtensionErrorDomain 2, "Missing entitlement com.apple.developer.system-extension.install") | 签名那一类 | ✅ |
| 没有设备（改） | `testOutput_noDevice_searchingRetriesAndDropsWithoutBlocking` | 60 帧全丢、找设备 7 次、consume p99 0.014 ms、`lastFailure == .open(.deviceNotFound)` | — | ✅ |
| 假 sink 全路（W3-C2，改一条断言） | `testVirtualCamera_fakeSinkPublishing_framesDroppedAndStates` | W3-C2 断言照旧；起流失败时 `lastFailure == .open(.startFailed(-1))` | — | ✅ |
| 窗口标题 | `ExternalTests.ExternalDisplayTests.testL10n_windowTitleDefaultsToASCIIAndIsInjectable` | 默认 "Switcher External Output"（ASCII）；管理器换标题 → 现有窗口跟着换、以后开的也用它；直接建窗口也能传 | — | ✅ |
| Aux 占位（改） | `AuxInputTests.testAux_noSignalDrawsPlaceholder` | 默认文案 "No signal"；测试照 App 传"无信号"：中间亮像素 2579、左下名字条 772、其余 0；可换成别的文案 | — | ✅ |
| Aux 全分辨率（W3-C2，着色器注释改英文后复核） | `testAux_inputWindowDrawsFullResolutionFrame` / `testAux_uyvyInputMatchesRenderer` | BGRA / NV12 / 随机色度 NV12 / UYVY 对渲染器 **0 / 2 073 600** 像素不同 | 逐像素 = 渲染器 | ✅ |
| 显示类 Stats（W3-C2 老用例） | `DisplayStatsTests` 4 个 | 内置屏 PGM 10 s 606 帧（60.0 fps）dropped 0、Aux 602 帧（59.9 fps）dropped 0，拔掉 2.02 s undelivered 121 / 122；240 fps → 120 Hz 覆盖计数 PGM 240 / Aux 241；外接屏 LG 144 Hz PGM 59.9 fps / Aux 59.8 fps dropped 0；层级选项 | 同 W3-C2 | ✅ |
| 其余 External / ISO / VirtualCamera 老用例 | 14 个（External 6、ISO 4、VirtualCamera 4） | 全过（`testP3_013_specRoundTrips…` 删了对已删 `describe` 的一句断言） | — | ✅ |
| 外接屏 L2 秒表法 | `testL2_externalDisplayStopwatch_manual` | — | UVC ≤ 150 ms | **BLOCKED-硬件（人工）**，同 W3-C2 |
| 真扩展的回报 | — | — | — | **BLOCKED-签名**（Team ID + /Applications）；第一次签名跑通时看什么在 §3 第 2 条 |

**App 这边**（不归本会话；胶水临时打上、验证完已撤，没提交）：`make gen` + xcodebuild build 通过（扩展 target 一起编过）；
`LocalizationTests` 5 / 5、`VirtualCameraAppTests` 2 过 1 跳（L1 BLOCKED-签名）、`StatusLineTests` 2 / 2、`DiskProtectionAppTests` 2 / 2、
`ISOAppTests` 1 过 1 跳（当时 frameprobe 还没编，BLOCKED-工具）。App 的激活失败文案实测："失败：签名 / 权限 / 位置不满足，要带 Team ID 签名、从 /Applications 运行（BLOCKED-签名）（Missing entitlement com.apple.developer.system-extension.install）"。
**不打胶水**时 xcodebuild build 报 1 处（`OutputStatusText.swift:22`：`Failure` 不是 `CVarArg`）。

## 3. 没做的和原因

1. **App 接线**：安装器失败原因的查表（必需，不改 App 编不过）、窗口标题本地化与在跑录制器的 disk_free_mb（可选）都在 App/，不归本会话。
   验证过的 diff 在问题单 `W3C3-app-extension-failure-reason-and-disk-free.md`，合并检查点按胶水额度照抄即可（必需 33 行、可选 6 行，按增 + 删计）。
   W3-E3（w3-app-4）与本会话同时从 67d0f6b 开，看不到这里的改动，没法由它做。
2. **扩展侧回报的真机验证 BLOCKED-签名**。第一次签名跑通时（`DEVELOPMENT_TEAM=<TeamID> make gen`、App 放 /Applications、激活扩展、开虚拟摄像头输出），
   看 `VirtualCameraOutput.countersSnapshot`：`extensionReports == true`；`framesOutput` 跟着 `framesSent` 涨（不涨 = CMIO 桥没把 notify 转给 'sonp'，
   换扩展自定义属性回报计数）；`extensionUnmatched == 0`（在涨 = 桥改了 / 丢了序号，dropped 不可信，看扩展日志里的 `sampleBufferSequenceNumber`）；
   `droppedExtension` 平时 0，扩展里临时每 10 帧不 send 不 notify 时每秒涨 6。步骤同时写进了 issue W3C2-camera-extension-scheduled-output 末节。
3. **扩展显示名的本地化**：`CFBundleDisplayName` 只改成 ASCII；要中英两份得给扩展 target 加 InfoPlist.strings（project.yml 不归本会话），等 W4-B 定 bundle id 时一起。
4. **`Recorder.freeBytes` 本身没修**（W1-E 的文件）：ISO 侧兜底 + App 一行可选接线；W1-E 那三行（issue W3C-w1-outputs-recorder-freebytes-nonboot-volume）仍建议做，做了之后兜底自然不起作用。
   `DiskProtectionTests` 里"`Recorder.freeBytes` 在镜像上是 0"那句断言是在记录这个问题，W1-E 修好时它会红，改成断言非 0 即可。
5. **CameraExtension 里原有的一条 Swift 6 警告没动**：`consumeNext` 递归调用捕获非 Sendable 的 `CMIOExtensionClient`（第 202 行，W3-C 起就在），与本会话改动无关。
6. **`consumeNext` 的递归取帧**：sink 里暂时没帧时 `consumeSampleBuffer` 的回调是等到有帧才回，还是立刻回 nil（那样会空转）——没签名的扩展验不了，W3-C 起的写法没改；第一次签名跑通时顺便看扩展进程的 CPU。

## 4. 对契约的疑问

本会话没有新的契约疑问（改的都是 SwitcherOutputs 三个模块自己的公开类型，没碰 SwitcherContracts / JSON 字段 / 测试图案）。
W3-C2 报告 §4 还挂着两条：`FrameSlot.latest(atOrBefore:)` 的线程注释（P4 的事）；测试标准 §7 的 display[] 字段表没写 `undelivered`（等用户）。

## 5. 下一个会话需要知道的坑

1. **合入本分支 App 就编不过，除非同时打问题单里的胶水**（`OutputStatusText` 1 处 + `LocalizationTests` / `VirtualCameraAppTests` 各 1 处）。diff 对 67d0f6b + 本分支 `git apply --check` 干净。
2. **SwitcherOutputs 这三个目录与 CameraExtension/ 的字符串字面量里不许有中文**，日志 / 断言 / 着色器源码也不例外（`SourceLanguageTests` 会红）。注释随便写中文；
   给人看的文字给枚举让 App 查表，非有不可的用 ASCII 并留注入口（窗口标题、占位文案就是这么做的）。Metal 着色器源码是 Swift 字符串，里面的注释也算。
3. **`DiskGuard.classify` 不再认中文字样**：空间充足、又没有磁盘错误码的写失败现在归 other（以前"写入失败"四个字就归 disk，App 会因此切备用目录）。
   录制器自己按下限停的走 `classify(recorder:…)`——只给文案、不给录制器的调用方（目前没有）认不出这一类。
4. **`VirtualCameraSink` 的实现要在排队之前调 `tracker.noteSent`**（如果它自己持有 `ScheduledOutputTracker`），否则所有回报都是 unmatched；测试里的 `FakeExtensionSink` 是范本。
5. `VirtualCameraConstants` 的流名改了（ASCII），扩展要重新编、重新激活，系统里看到的名字才会变；主程序按设备 UID 与流方向找，不按名字。
6. App 的 `AppTest.chineseLiteralViolations` 写着"`// l10n-exempt` 行不算"，但它先剥掉 `//` 注释再找这个标记，所以这个豁免标记实际不起作用（目前 App 也没人用它）。归 App，顺手记一笔。
7. **这台机器已经是 macOS 27.0 (26A428)**，本会话的两个探针都在 27.0 上跑；W3-C2 记的 26.6.2 上 swift-collections 1.7.0 的 dyld 崩（`_swift_initBorrow`）在 27.0 上是否还在没验（锁文件模板照旧会拷，`make gen` 不受影响）。
8. 显示统计类用例这次在负载 6–9 下也过了，但 W3-C2 §2 记过负载 8.6 时 PGM 窗口 10 s 记了 29 个 dropped 的情况；看到红先看负载。
