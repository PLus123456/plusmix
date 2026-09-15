# W2-A 输入一期（摄像头 / 屏幕 / 文件 / 图片）—— 报告（分支 w2-inputs）

日期 2026-09-15。机器 Apple M5 Max 128 GB / macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3，电源适配器。
**整个会话期间机器不干净**：另外四个 W2 会话（w2-app / w2-control / w2-stream / w2-audio-integ）同时在编译跑测试，load average 2–4。
worktree `.claude/worktrees/w2-inputs-phase-one-2f34b3`，分支 `claude/w2-inputs-phase-one-2f34b3`（桌面端自动起的名），从 `main`（2290b4e）开；
**`w2-inputs` 这个分支名指向同一个 HEAD**（`git branch -f w2-inputs HEAD`），`make lint BRANCH=w2-inputs` 和检查点合并都用它。
提交：`git log main..w2-inputs`（5 个）。只动了 `Packages/SwitcherInputs/`、本报告、`docs/contract-changes/005`（原 002，G3 合并时因与 W2-D 撞号改为 005）。

## 1. 做了什么

全部在 `Packages/SwitcherInputs/`：库 target `SwitcherInputs`（只依赖契约，4 种输入 + 公共件）、`SwitcherInputsHarness`（组装方：真引擎 + 真渲染器 + 真帧槽，量 L1）、
可执行 `switcher-input-probe`、测试 target（27 个测试）、`Scripts/`（TCC 用的 .app 启动器、S5 计时脚本）。共 4.7 k 行 Swift。

| prompt 交付 | 落点 | 备注 |
|---|---|---|
| 1 CameraInput | `Camera/CameraInput.swift`、`CameraFormatNegotiation.swift`（纯函数）、`CameraDevices.swift`、`CameraPermission.swift`、`HotplugTimer.swift` | AVCaptureSession + VideoDataOutput，请求 '420v'，`alwaysDiscardsLateVideoFrames = true`；格式协商：帧率优先匹配节目帧率 → 分辨率（相同 > 两边都 ≥ 里最小 > 最大）→ 原生 NV12，并把 `activeVideoMin/MaxFrameDuration` 锁到协商帧率；时间戳 `CMSyncConvertTime(pts, from: session.synchronizationClock, to: host)` → `CMClockConvertHostTimeToSystemUnits` → host tick；设备自带麦克风（`device.linkedDevices` 里的音频设备）走 AudioDataOutput，float32 非交错 48 kHz 写环；UVC / 连续互通相机（`.external`）同一路 |
| 2 ScreenInput | `Screen/ScreenInput.swift`、`ScreenTargets.swift` | SCK 三种过滤（display / desktopIndependentWindow / including app）；SCK 给的 IOSurface 缓冲直接 push（零拷贝）；默认 BGRA sRGB（RGB 内容、文字不被 4:2:0 抽色），可选 '420v' BT.709 limited；源比节目大时 SCK 缩到节目框内；帧率 = `source.frameRate ?? 节目帧率`；系统音频 48 kHz、排除本进程；画面不动时用 SCK 的 idle 样本把最后一帧重推（见 §5 第 6 条） |
| 3 FileInput | `File/FileInput.swift`、`FileDecoder.swift`、`FileQueues.swift`、`FileTimeline.swift` | AVAssetReaderTrackOutput（内部 VideoToolbox 硬解，探针 1080p60 H.264 解 2700 fps）；**时钟从属**：全有理数时间线，第 anchorTick 拍显示位置 anchorMedia，每拍前进 一拍秒数 × 速率；推帧线程（time-constraint）每拍醒一次，把"位置 ≤ 本拍"的最新解码帧推进帧槽（多余的计 `framesRejected`），pts = 拍点 − 半个节目帧；预解码 3 帧；循环重开 reader（2 ms）；定位 = 换代，**锚点在目标帧解出来之后才定**（首帧就是第 300 帧，不依赖 GOP）；暂停时每拍以 pts = 拍点 重推停住的帧；结束动作 hold / black / loop 运行中可改；音频 256 帧一块按"样本已发生"写环（混音器年龄设定点才对得上），速率 ≠ 1 线性插值变速；带 alpha（格式描述 `ContainsAlphaChannel` / Depth 32）输出 BGRA，解码器标 `StraightAlpha` 的就地预乘 |
| 4 ImageInput | `Image/ImageInput.swift` | 缩略图接口一次完成解码 + EXIF 转正 + 长边缩放，再按两边收进节目框（不放大、偶数尺寸）；预乘 BGRA、sRGB、IOSurface；拍点线程每拍 push 同一个缓冲，pts = 拍点 |
| 5 通用 | `Common/NoSignalWatchdog.swift`（期望帧间隔 × N，N = 3，定时器周期 = 间隔）、`InputStateBox.swift`（状态 + 转换计数）、`InputThread.swift`（pthread + THREAD_TIME_CONSTRAINT_POLICY + mach_wait_until）、`ProgramTiming.swift`（节目格式 + 拍点时钟，组装方在引擎 start 前定 t0 传给输入）、`LPCM.swift` / `AudioSampleWriter.swift`（任意 LPCM 布局 → float32 非交错 → 环）、`HostTimeConversion.swift`、`PixelBuffers.swift`、`SurfaceTracker.swift` | 热插拔：`AVCaptureDevice.wasDisconnected / wasConnected`（按 uniqueID）+ 每秒轮询兜底；断开拆会话进 noSignal，回来自动重建（`rebuilds` 计数），编号在对象里不变、InputSettings 在 MixerState 里不碰；权限：未授权 → `.error(文案指到系统设置)`，每秒轮询，授权后自动建会话（不用重启） |
| 6 L1 打点 | `Frame.ingressTime` 每种输入都在 push 前一刻填；"引擎送编码器时记差"要在引擎里做，Stats 没字段 → **提案 002**；本会话用 `SwitcherInputsHarness/LatencyFrameSlot.swift`（包一层真帧槽，记第 n 拍用了哪帧）+ `LatencyConsumer`（PGM 消费者 consume 入口打戳）在包外量 | 提案里写了引擎侧算法（就是 harness 这套）；提案编号 G3 合并时由 002 改为 005 |
| 探针 | `Sources/switcher-input-probe/main.swift` | `devices`（设备 / 屏幕目标 / 权限）、`clocks`、`run --input … --seconds N`（真引擎跑，出每路 L1 表）、`hotplug --camera <id> --cycles 20`（S5 计时）、`permission`（S6 观察） |
| TCC | `Scripts/probe-app.sh`、`Scripts/hotplug-timer.sh` | 见 §3 第 1 条：从 Claude / 脚本直接起的进程系统连授权提示都不弹，用只编一次的启动器 .app 经 `open` 起探针 |

统计：每个输入只暴露 `InputCounters`（原子计数：收 / 推 / 拒、音频块、状态转换、重建、见过的 IOSurface 数）和各自的诊断量（时间戳 d 分布、热插拔事件、文件计数），
Stats 仍只读帧槽 / 环的统计（铁律 4）；L1 进 Stats 要提案 005（原 002）。

`make lint BRANCH=w2-inputs` 绿（禁词 / 版本号 / Package.swift / 依赖方向 / 归属 / RT 符号）；`swift build` 绿；`swift test`（本包）28 个：24 通过、4 XCTSkip（摄像头三个 + S5，权限 / 硬件，下表），约 30 s。摄像头的 L1 由 .app 探针量（表里）。

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherInputs`（debug）。L1 的口径：帧的 `ingressTime`（进帧槽那一刻）→ 该帧出现在编码器输入（引擎把 PGM 帧交给第一个 FrameConsumer 的 consume 入口）；
只算"这一拍第一次用到的帧"（帧率转换的重复不算），忽略引擎起来之前就进槽的帧。节目 1080p60，一帧 = 16.67 ms。

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| 单元：60 fps 节目帧号连续 | `testFile_60fpsProgram_frameNumbersConsecutiveFromZero` | 从锚点拍起 120 拍帧号 0…119 连续；pts = 拍点 − 半帧、ingress < pts；帧槽 reused 0 / dropped 0；解码器见过的 IOSurface ≤ 16；推帧线程饿 0 拍 | 连续、无 dup / drop | ✅ |
| 单元：30 fps 节目每个帧号一次 | `testFile_30fpsProgram_eachFrameNumberAppearsOnce` | 60 拍帧号 0,2,4,…118，每个只出现一次，帧槽 reused 0 / dropped 0（输入自己按拍选帧，多余的 59 帧计 framesRejected） | 每个帧号一次 | ✅ |
| 单元：循环边界 | `testFile_loopBoundary_noSkipNoRepeat` | 定位到 590 后 40 拍：590…599, 0…19，无跳号无重复，跨边界后 pts 相位不变，state 仍 live | 无跳号无重复 | ✅ |
| 单元：定位 | `testFile_seekToFrame300_firstFrameIs300` | 先 0…19，seek(toFrame: 300) 后第一个新帧就是 300，之后 301…；新帧在定位生效拍起 ≤ 3 拍内出现（pattern.mov 关键帧间隔 120，从 240 解到 300 ≈ 25 ms） | 首帧 = 300 | ✅ |
| 单元：暂停 pts 刷新 | `testFile_pausedStillRefreshesPtsEveryTick` | 暂停后 30 拍停在同一帧，每拍都有新 push、pts == 拍点，帧槽 reused 不增；恢复后从停住的帧继续、连续 | 每拍刷新 | ✅ |
| 无信号 | `testNoSignal_fileEndsWithoutLoop_noSignalWithinThreeIntervalsAndLatestNeverBlocks` | 播完不循环：末帧 599 显示期结束的下一拍置 noSignal（≈ 1 个帧间隔，实测 < 3）；之后 latest 每拍仍返回 599（reused）、从不 nil；latest 最大耗时 < 1 ms（实测微秒级） | ≤ 3 个帧间隔；不阻塞 | ✅ |
| 结束动作 black | `testFile_endActionBlack_pushesBlackFrameThenNoSignal` | 末帧之后一帧 NV12 黑场（Y = 16、解不出帧号），然后 noSignal | — | ✅ |
| 速率 | `testFile_rate2_advancesTwoFramesPerTick` | rate 2：40 拍每拍前进 2 帧 | — | ✅ |
| 音频 | `testFile_audioBlocksAlignedToVideoTimeline` | 2.2 s ≈ 400 块 × 256 帧：首块 host time = 播放起点拍点，块与块连续（误差 ≤ 2 tick），host time 单调；click 峰值落在 48000k ± 48 样本（k = 1, 2）；环拒 0 | 与视频同一时间基 | ✅ |
| alpha 素材 | `testFile_alphaSources_outputPremultipliedBGRA` | AVAssetWriter 写的 ProRes 4444（直通口径）与 HEVC alpha（预乘口径）各 30 帧：`hasAlpha` 识别、输出 BGRA、alpha 128 ± 12、预乘后 R 在 100–140（直通没预乘会是 ≈ 233、预乘两次 ≈ 58；见 §5 第 4 条的电平偏移）、B/G < 24 | 输出 BGRA、alpha 正确 | ✅ |
| 文件不存在 | `testFile_missingFile_stateIsErrorWithMessage` | start 抛错，state = error(带路径的文案) | — | ✅ |
| 图片 alpha | `testImage_pngAlphaPreserved_outputsPremultipliedBGRA` | sRGB PNG：左半 alpha 0.5 红 → B0 G0 R128 A128（预乘）、右半不透明绿 → B0 G255 R0 A255，逐字节精确 | 保留 alpha | ✅ |
| 图片缩放 | `testImage_largeImageDownscaledToProgramBounds_keepsAspect` | 4000×3000 → 1440×1080（1080p 节目）；320×240 不放大 | 上限 = 节目分辨率 | ✅ |
| 图片同一帧 | `testImage_sameBufferEveryTick_ptsRefreshedToTick_noReuse` | 60 拍同一个 IOSurface、序号逐拍 +1、pts == 拍点、帧槽 reused 0 | 永远同一帧、pts 每拍刷新 | ✅ |
| 图片不存在 | `testImage_missingFile_stateIsErrorWithMessage` | error(带路径) | — | ✅ |
| 摄像头格式协商 ×6 | `testCameraNegotiation_*` | 内置 30 fps 机在 60 fps 节目 → 1080p@30；1080p 只有 30 而 720p 有 60 → 720p60（帧率优先）；30 fps 节目锁 30 取同尺寸靠前档；59.94 落在 1–60 范围内算匹配；UVC 同尺寸同帧率原生 420v 优先，720p 节目取两边都 ≥ 的最小（1080p），2160p30 精确；只有更高帧率取最近的高档；空表 nil | — | ✅ |
| **L1 文件** | `testL1_fileInput_within2Frames`（真引擎 + Metal 渲染器，6 s） | 359 样本：平均 **11.34 ms（0.68 帧）**，p50 11.36，p99 11.52 ms（0.69 帧），max 13.86 ms（0.83 帧），min 10.92；没帧 0 拍；per_input dup 0 / drop ≤ 3；missed_render 0。release 探针 10 s：11.56 / p99 11.72 / max 13.80 | ≤ 2 帧 | ✅ |
| **L1 屏幕** | `testL1_screenInput_within3Frames`（显示器 1，1728×1117 pt ×2 → 1670×1080 BGRA，8 s） | 458 样本：平均 **19.05 ms（1.14 帧）**，p50 18.98，p99 28.55 ms（1.71 帧），max 28.75 ms（1.72 帧），min 2.58；重复 21 拍（显示器刷新与 60 Hz 拍频 + idle 重推）。release 探针 10 s：19.18 / p99 27.59 / max 28.03；per_input dup 28 / drop 7 | ≤ 3 帧 | ✅ |
| L1 图片（顺带） | 探针 `run --input image:`（10 s） | 599 样本：平均 20.43 ms（1.23 帧），p99 21.86（1.31），max 28.25（1.70）。pts = 拍点 字面实现，引擎到达余量热身后降到 0 才当拍合格，之前晚一拍 | 无阈值 | — |
| **L1 摄像头**（产品配置：引擎到达余量开） | `testL1_cameraInput_within3Frames`；探针 `probe-app.sh run --input camera:0 --seconds 10` ×3 | 内置摄像头 1080p@30 '420v' 进 1080p60：运行 1 平均 **64.71 ms（3.88 帧）**、p99 76.14（4.57）、max 88.78（5.33），且**前 252 拍 latest 返回 nil（黑屏 4.2 s）**、dropped 117 / reused 173；运行 2 平均 41.57（2.49）、p99 63.73（**3.82**）、max 65.23（3.91）；运行 3 平均 60.95（3.66）、p99 83.18（4.99）。到达余量 87–136 ms | ≤ 3 帧 | **❌**。不是输入的延迟，是引擎到达余量的代价：余量 = 16 s 内最大 d（ingress − pts）+ 保护带 ≈ 87–136 ms，摄像头 d 稳态 55 ms，每帧多等 余量 − d；起流第一帧 d 大时初值 2 × d₀ 超过候选表能装的，热身 4 s 内饿死 → 黑屏。**问题单 reports/issues/W2A-w1-core-arrival-pacing-vs-camera-latency.md 退回 W1-B**。xctest 进程仍没权限（责任进程是 claude-code 辅助程序），测试在本会话里 XCTSkip，数字来自 .app 探针 |
| **L1 摄像头**（对照：契约入口 `latest(atOrBefore:)`，`--no-pacing`） | `testL1_cameraInput_contractEntry_within3Frames`；探针同上加 `--no-pacing` | 299 样本：平均 **8.86 ms（0.53 帧）**，p50 7.65，p99 16.97（1.02），max 17.51（1.05）；dup 300（30 进 60 的设计内 50%）、drop 1（引擎起来前的） | ≤ 3 帧 | ✅（这是输入本身的延迟：帧到了下一拍就用） |
| 摄像头时间戳（探针 `clocks --camera 0`，8 s，218 帧） | — | pts 严格 33.33 / 33.34 ms 步进（传感器时钟）；送达间隔 30–35 ms、重负载 24–41；**d = ingress − pts 稳态 54–58 ms**（相机管线固有延迟），每秒 1–3 帧 60–75，第一帧 75，重负载见过 157；`synchronizationClock` == host clock | — | 数据在问题单里 |
| 摄像头真机 | `testCamera_builtIn_deliversNV12FramesWithHostTimestamps` | 探针里等价的检查都过：帧 '420v' IOSurface（distinctSurfaces 2–5）、pts ≤ ingress、采集丢帧 0、8 s 219 帧（29.3 fps）、协商 1920×1080@30（匹配节目帧率 false，正确：内置相机最高 30） | — | ✅（探针）；xctest 本身 XCTSkip（权限，同上） |
| **S6** 权限被拒：不崩、文案清楚 | `testS6_cameraPermissionDenied_startDoesNotCrash_messageIsClear` | 本进程恰好就是"被拒"环境：start 不抛、不崩，5 s 内 state = error，文案：「摄像头权限被拒，且系统没有弹出授权提示：本进程（或启动它的程序）的 Info.plist 没有摄像头用途说明，从终端或带用途说明的 .app 启动，在 系统设置 › 隐私与安全性 › 摄像头 允许后会自动恢复。」；普通拒绝的文案：「摄像头权限被拒。打开 系统设置 › 隐私与安全性 › 摄像头，允许本程序后会自动恢复，不用重启。」；stop 后 noSignal | 不崩、文案清楚 | ✅ |
| **S6** 授权后 10 s 内恢复 | 手动，`Scripts/probe-app.sh permission --camera 0 --seconds 90` | 代码：每 1 s 轮询 `AVCaptureDevice.authorizationStatus`，变成 authorized 就建会话。**步骤**：① 先跑一次上面的命令并在提示里点"不允许"（或在系统设置里关掉 SwitcherInputProbe 的摄像头）→ 日志应打印 `state noSignal → error(...)`；② 90 s 内到 系统设置 › 隐私与安全性 › 摄像头 打开 SwitcherInputProbe；③ 日志应在 ≤ 2 s 内打印 `error → live` 和 "已推 60 帧"，进程不用重启。屏幕录制同理：`permission --screen 0`，在 屏幕录制与系统录音 里打开 | 授权后不重启恢复 ≤ 10 s | **待手动**（会话里没法替用户点系统设置） |
| **S5** 热插拔 20 次 | `testS5_hotplug20Cycles_noCrash_recoversWithin3s_numberKept`；脚本 `Scripts/hotplug-timer.sh <uniqueID> 20` | 代码：`wasDisconnected` → 拆会话、noSignal；`wasConnected`（uniqueID 相同）→ 重建会话 → 首帧 live；恢复时间 = 连接通知 → live。脚本每次提示"请拔掉 / 请插回"，出表：断开→noSignal、连接→live、拔着时长，最后崩溃 0 / 编号是否不变 / 最大与平均恢复时间 | 崩溃 0；恢复 ≤ 3 s；设置保持 | **BLOCKED-硬件**（内置摄像头拔不了；没有外接 USB 摄像头 / UVC 卡）+ 权限（同 L1 摄像头）。设备清单里有一台 iPhone 连续互通相机（`.external`，uniqueID `05D5AC85-…0001`，1080p60），关掉 iPhone 的连续互通 / 走远再回来也能触发连接 / 断开通知，可以拿它跑：`Scripts/hotplug-timer.sh 3 20` |

BLOCKED 汇总：S5、S6 恢复路径——卡在"插拔设备 / 在系统设置里改权限"，代码和工具都在，跑法在表里。摄像头权限用户已在 .app 探针上点了允许，摄像头的数字都是 .app 探针量的；xctest 进程还是没权限（要从 Terminal.app 跑）。
**摄像头 L1 在产品配置下 ❌（2.5–3.9 帧 avg、3.8–5.0 p99），根因在引擎的到达余量，已退单给 W1-B；输入本身 0.53 帧。**

## 3. 没做的和原因

1. **摄像头的 XCTest 在本会话跑不了**（TCC）。责任进程机制：`responsibility_get_pid_responsible_for_pid` 指向 `…/claude-code/2.1.266/claude.app/Contents/MacOS/claude`（`com.anthropic.claude-code`），它的 Info.plist 只有麦克风 / 本地网络 / Apple Events 用途说明，没有摄像头，所以 AVFoundation 不弹提示直接拒。屏幕录制反而在会话中途变成 authorized（应该是别的会话或用户在系统设置里给 Claude 开了），所以屏幕这路量到了。`Scripts/probe-app.sh` 解决方式：启动器 .app 只编一次（cdhash 稳定，TCC 记得住），经 `open` 起真正的探针二进制，子进程继承责任归属——用户在提示里点了允许后，摄像头的所有数字都来自它。
1a. **摄像头 L1 在产品配置下没达标**（见 §2），修法在引擎（W1-B 的 ArrivalPacing），本会话只准动 Inputs，已写问题单。输入侧没有合法的缓解手段：pts 必须是采集时刻（契约 / 设计方案 §3.6），ingressTime 必须是进槽时刻，帧槽容量由组装方定。
2. **headless 加 `--input camera:0`** 没做：`Tools/switcher-headless/` 归 W2-C / G3（OWNERSHIP 表），本会话只准动 `Packages/SwitcherInputs/`。等价物是 `switcher-input-probe run --input …`（同一套引擎 / 渲染器 / 帧槽）；G3 接线时把 harness 里 60 行的组装搬进 headless 即可（`InputEngineHarness.swift`），W2-B 的 App 已留了 `InputFactory` 接缝。
3. **屏幕的窗口 / 应用过滤只做了单元级验证**（SCContentFilter 建得出来、尺寸按 pointPixelScale 算），L1 只量了显示器。
4. **FileInput 的 rate ≠ 1 音频**是线性插值变速（音调随速率变），没有做保持音调的时间拉伸；prompt 没要求。
5. **摄像头的 UVC 采集卡**没有真卡，只能保证走同一路代码（`.external` 设备类型、协商函数对 yuvs / 2vuy 格式的处理有单元测试）。

## 4. 对契约的疑问

1. **提案 005（原 002，G3 改号）**（`docs/contract-changes/005-stats-per-input-latency.md`，待批）：`Stats.per_input` 加 `latency_ms` / `latency_max_ms`。不批的话 L1 只能靠探针 / 测试报，UI / API / 长稳 stats 里没有。
2. **输入怎么拿到节目时钟**：契约的 `Input` 协议没有时钟参数，但四种输入都需要（摄像头按节目帧率协商、屏幕跟节目帧率、文件锚到拍点、图片每拍刷新 pts）。本会话在各自的 init 里收 `ProgramTiming{format, TickClockSpec}`（组装方在引擎 `start(t0:)` 之前定 t0，把同一份给所有输入——headless 现在就是这么算 t0 的）。这是包内类型，不动契约；但如果以后节目格式要热切换（"改它等于重启管线"），输入也得重建。要不要把 `ProgramTiming` 升到契约让 App / headless / TestKit 共用，请拍板。
3. **`Frame.pts` 对文件 / 图片的语义**：契约说 pts 是"采集时刻"。文件帧的 pts 我定为 **拍点 − 半个节目帧**（相位提前量，让带到达余量的引擎入口当拍就合格；30 fps 节目里同样），图片按 prompt 字面是 **拍点**（引擎热身前会晚一拍）。两者的 A/V 关系：文件音频样本的 host time = 该媒体位置的拍点（不带提前量），所以视频在拍点显示、音频在拍点响，对齐。如果希望图片也带提前量（少一拍延迟），改一个默认值即可。
4. **`FileEndAction.black` 的语义**：我实现成"推一帧黑场然后 noSignal"（帧槽保留黑场）。另一种理解是"持续输出黑场且仍算 live"。按 prompt 的无信号测试（播完 → noSignal）选了前者。
5. **屏幕输入静止时的统计口径**：SCK 画面不动只送 idle 样本；我用它重推最后一帧，Stats 里 fps ≈ 节目帧率、dup ≈ 拍频（显示器刷新率 vs 60 Hz）。如果检查点希望静止屏幕在 stats 里就是 fps 0 / dup 满，把 `ScreenInput.Options.refreshWhenIdle` 关掉即可。
6. **InputState 在授权提示等待期间**：用了 `.error("摄像头权限尚未授权：等待系统提示…")` 而不是 noSignal，UI 才有东西可显示；回答后自动改。

## 5. 下一个会话需要知道的坑

1. **macOS 26 上 AVCapture 的时间戳时钟（探针 `probe-syncclock`）**：`AVCaptureSession.synchronizationClock` 在 `startRunning()` 之前是 nil，之后是 `FigClock[HostTimeClock]`，`CFEqual(sync, CMClockGetHostTimeClock()) == true`，`CMSyncConvertTime` 是恒等，`CMClockConvertHostTimeToSystemUnits` 直接给 mach_absolute_time 单位（与 `mach_absolute_time()` 差 13 tick = 0.5 µs，就是两次调用的间隔）。代码仍然每帧走转换（外接 UVC / 未来系统可能不是 host clock）。会话没授权也能 `isRunning == true`，只是没有帧——不能拿 isRunning 判权限。
2. **SCK 的时间戳（探针 `probe-sck`，屏幕录制授权后）**：sample buffer 的 pts 在 host clock 上（离 `CMClockGetTime(host)` 几毫秒），但**可以比"现在"晚 1–3 ms**（它是帧的显示时刻，不是采集时刻），d = now − pts 在 −2.6 … +24 ms。代码把 pts > now 的钳到 now，离现在超过 1 s 的退回帧附件 `displayTime`（mach 单位），再退回 now，都计数。音频块 960 帧（20 ms）、pts 也在 host clock 上、送达晚 ≈ 50–90 ms。
3. **SCK 起流后有一段 ~600 ms 的空窗**：`startCapture` 后送 2–3 帧，然后 600 ms 没有任何样本，之后才稳定按帧间隔送（真帧或 idle）。看门狗会在这段里报一次 noSignal 再回 live；引擎若在空窗里起来，第 0 拍用的是空窗前的旧帧（L1 消费者已忽略 ingress 早于 t0 的帧，否则那一帧算出 645 ms）。
4. **AVAssetReader 解成 BGRA 时 RGB 电平会变**（探针 `probe-alpha`）：ProRes 4444 / HEVC alpha 写进去 255 / 128，解出来 233 / 117（≈ 0.91×，B/G 也多出 2–3），像是走了 BT.709 → sRGB 的转换。**alpha 值不变**。编码器不改 RGB，只给 alpha 模式打标：ProRes 4444 默认 `StraightAlpha`、HEVC alpha 默认 `PremultipliedAlpha`，输入缓冲带 `kCVImageBufferAlphaChannelModeKey` 附件时跟附件走；解出来的缓冲附件照样带，格式描述里有 `ContainsAlphaChannel = 1`、`Depth = 32`、`AlphaChannelMode`。需要精确电平的带 alpha 图形走 PNG（ImageInput 逐字节精确）。
5. **进程里第一个 AVAssetReader 要 85 ms 才 startReading**（之后的 2 ms），加首帧 4 ms；定位到非关键帧要从关键帧解到目标（pattern.mov 60 帧 25 ms）。所以 FileInput 的锚点在目标帧解出来之后才定，start / seek 后 `playbackStartTick` 先是 nil。
5a. **摄像头的 d（ingress − pts）不是抖动，是 55 ms 的固定管线延迟**（内置相机；pts 是传感器时钟，33.33 ms 严格步进），送达抖动本身只有 ±3 ms，重负载下偶发 +20–100 ms 的尖峰。引擎的到达余量把它当抖动全额预留，摄像头就多付 1–3 帧；估计器还按第一帧（最慢的那帧）定初值。细节在问题单。任何"入口打戳 → 引擎挑帧"的新输入（DeckLink、NDI、W3-A）都会遇到同样的事，NDI 的 d 会更大。
6. **`supportsRandomAccess = true` + `timeRange` 到 +∞ 时 reader 会在结尾多给一个 pts = 时长 的样本**（探针 `probe-file3`：601 个）；`FileReader.nextVideo` 过滤 pts ≥ 时长的样本。循环用重开 reader 而不是 random access（后者要先把当前范围读完才能 reset）。每次重开一个 reader 就换一个像素池（IOSurface 换一批，10 s 循环 22 个不同 IOSurface），渲染器纹理表每路 16 项，每圈会建几次纹理。
7. **AVAssetReader 的解码像素池会复用 IOSurface**（探针 `probe-surfaces`：立即放手 5 个、持有 6 帧 11 个），前提是下游放手。测试里把 Frame 存进数组就会让池子一直新建（第一版测试见过 161 个不同 IOSurface）。
8. **暂停位置的归属**：`pause()` 只置标志，位置由推帧线程在下一次醒来时冻结在它最近推出的那一帧上（API 线程读"最近推出"会差一拍，第一版测试恢复后帧号 12,12,13 就是这个原因）。
9. **播放前的帧**：文件 / 图片的锚点钳到 ≥ 第 0 拍——引擎没起来之前推的帧只会被帧槽挤掉（记成 dropped，第一版 L1 测试里 drop 26）。摄像头 / 屏幕的帧到了就推，引擎起来前的那几帧照样会被挤掉，是设计内的。
10. **屏幕 idle 重推别用定时器**：dispatch 定时器与 SCK 相位随机，10 s 里 138 dup + 56 drop；用 SCK 自己按帧间隔送来的 idle 样本重推，只剩拍频（28 / 7）。SCK 的 idle 样本没有 imageBuffer，要从 `SCStreamFrameInfo.status` 判。`CGDisplayPixelsWide` 在 HiDPI 缩放模式下给点数（3456×2234 面板报 1728×1117），像素 = `SCDisplay.width × SCContentFilter.pointPixelScale`。
11. **TCC**：见 §3 第 1 条。另外 `swift test` 起的 xctest 和 bare 二进制拿到的屏幕录制结论可能不一样（同一个责任进程，一个 authorized 一个 −3801，可能是授权在两次之间生效的）；判权限一律用 `CGPreflightScreenCaptureAccess()` / `AVCaptureDevice.authorizationStatus`，别信 isRunning。
12. **main.swift 顶层 + `Task {}` + 信号量 = 死锁**：顶层代码在主 actor 上，`Task {}` 继承主 actor，排在被 `sem.wait()` 卡住的主线程后面；要 `Task.detached`。
13. **文件音频写环的时机决定 A/V 偏移**：混音器（W1-D）就绪时把读位置定在 `write_index − back`、设定点 = 当时的年龄，之后 PI 保持这个年龄——生产者写得越超前，这路音频就越提前（不是按 host time 对齐的）。所以文件音频像真设备一样在"样本已发生"之后才写（每块 5.3 ms），不能一次性把解码好的几百毫秒灌进去；W2-E 做 A2 时如果换成按 stamp 对齐，这条就不再重要。
14. **给 G3 接线**：四种输入的构造都有 `init(config: InputConfig, timing: ProgramTiming, videoSlot:, audioRing:)`，帧槽 / 环由组装方建；`InputEngineHarness` 就是一份可抄的组装代码。W2-B 的 App 留了 `InputFactory` 接缝（reports/w2-app.md）。
15. **摄像头的自带麦克风走 AVCaptureAudioDataOutput 需要麦克风权限**（另一个 TCC 项）；没有就只出视频，`lastError` 记一句，不影响 live。
