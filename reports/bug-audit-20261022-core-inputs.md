# 2026-10-22 Core / Inputs bug 审查

基准：`main` / `1f9be64`。审查树：`/Users/plus/.codex/worktrees/bug-audit-20261022/plusmix`，分支 `codex/bug-audit-20261022`。本报告只做审查与隔离探针，没有改生产源码、契约或既有测试，没有提交。根 agent 负责整仓测试与最终去重。

## 1. 做了什么

读过 `CLAUDE.md`、通用前言、`docs/KNOWN_ISSUES.md` 的产品表与 G10 已修表、2026-10-13 debug 审查。重点核查 Contracts 的解码/校验、Engine 的状态推进/时长/发布与帧环、Render 的缓冲复用/几何/格式入口、Inputs 的文件时间线/暂停定位/队列、图像/屏幕/摄像头生命周期与格式协商、NDI 时钟映射、DeckLink 声道配置入口。重点按调用链和隔离运行验证可疑点；没有把所有源码逐行审完或做过所有硬件验收。

### CI-01 — P1：非法帧率 JSON 在解码阶段触发进程断言/整数溢出

- 位置：`Packages/SwitcherCore/Sources/SwitcherContracts/Time.swift:235–239`、`:169`、`:295`、`:261`。
- 最小触发：有效节目 JSON 中 `mixer.format.frameRate` 替换为 `{"numerator":0,"denominator":1}`，或负 numerator；另一独立分支为 `{"numerator":1,"denominator":-9223372036854775808}`。
- 结果：`Show.load` 独立进程分别 SIGTRAP（returncode -5）；零/负帧率打印“帧率必须为正”，极小分母在 `d = -d` 溢出。不是可捕获的解码错误。帧率还存在于 `InputSource.screen.frameRate`，因此正常 JSONDecoder 解码的 addInput / setInputSource 也可在 CommandValidator 之前触发。
- 根因：`Rational.init(from:)` 只拒绝分母 0，之后调用不支持 Int64.min 归一化的非 throwing init；`FrameRate.init(from:)` 调用带正值 precondition 的 init。
- 影响：打开损坏节目文件、API 收到这些字段都会终止承载引擎的进程。
- 反证：有效 60fps 节目对照正常加载、退出 0。没有把非法输入当成必须支持的格式；应拒绝并返回错误，而非崩溃。
- 建议：在 Codable 层做可抛错的域检查；约分/变号使用 Int128 并在转换回 Int64 前验证表示范围。正帧率还应明确允许范围，防止超大但为正的值流向时钟与 UI 整数换算。
- 证据：生产 Contracts 全部原始 Swift 源编成独立 dylib 后运行，`Audit20261022-rationalMin.json/log`、`fpsZero.json/log`、`fpsNegative.json/log`。

### CI-02 — P1：节目叠加数组长度错误在 validate 之前崩溃

- 位置：`Packages/SwitcherCore/Sources/SwitcherContracts/Show.swift:91–94`、`:116–117`；`MixerState.swift:845`。
- 最小触发：有效节目 JSON 的 `mixer.overlays=[]`，调用 `Show.load(from:)`。
- 结果：独立进程 SIGTRAP，报“overlays 必须恰好 4 个”。`MixerStateError.overlayCount` 原本可表达该错误，却来不及运行。
- 根因：`Show.load → show.makeState → MixerState.init` 先断言，再调用 `validate`。`CommandValidator.loadShow` 与 reducer 的 loadShow 用同一顺序，API 也可达。
- 影响：一份可解码但数组缺项/多项的节目文件可以终止 App。`try/catch` 无法兜住 precondition。
- 建议：在 `makeState` 进入断言之前校验 Show 结构，或提供可抛错的构造/校验入口；保留对不可信 JSON 的报错路径。
- 反证：四项对照可加载；这与 CI-01 是不同字段、不同检查点，单修帧率仍会触发。
- 证据：原始 Contracts 运行，`Audit20261022-overlays0.json/log`。

### CI-03 — P1：主 API 接受 Int.max 的渐变时长，FTB 反转可以崩溃

- 位置：`Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:76–79`，`CommandValidator.swift:45–46`。
- 最小触发序列：默认状态在第 1 拍 `.ftb(on:true)`；第 2 拍 `.setFTBDuration(ticks:Int.max)`；紧接第 3 拍 `.ftb(on:false)`。这是直接调用 reducer 的隔离序列，没有自动调用 advance，当前电平仍为 0；不是 StateMachine/API 端到端实测。同一拍内依次处理这些命令可达同一电平条件，是代码静态推导。
- 结果：生产 reducer 隔离进程 SIGTRAP（测试仅覆盖上述未 advance 的状态），`Double value cannot be converted to Int because ... greater than Int.max`。原始校验器允许 `setFTBDuration(Int.max)`；Control agent 交叉核对 HTTP JSON Int64/Int 路径可达。
- 根因：反转计算 `progressed * Double(duration)`；progressed=1 时 `Double(Int.max)` 四舍五入成 2^63，回转 Int 溢出。主 API 只检查负时长，没有上限。
- 影响：通过 API/节目参数给极大时长后操作 FTB 会终止进程。上次 D03 修的是兼容层 Double 秒数换算，这次是主 API 原生 ticks 值，不是同一已修路径。
- 反证：把 FTB 已走到电平 1 再向下反转时 progressed=0，不会触发，因此探针保留了准确状态序列。没有声称任何方向/任意时刻都崩。
- 建议：给所有 tick 时长统一安全范围（FTB / fade / transition slot / overlay），在 API、Show 校验和 reducer 统一校验；时长与 Tick 加减及 Double→Int 转换仍做防溢出。`StateMachine.completion` 的 `start + durationTicks` 也需要同批检查，后者本次只静态定位、未单独实测。
- 证据：`Audit20261022ReducerMain.swift`、`Audit20261022-ftbMax.log`。没有请求运行中的 API/App。

### CI-04 — P2：暂停尚未落实就恢复，文件时间线退回旧锚点并定格

- 位置：`Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:402–409`（resume）；暂停请求 `:392–397`；推帧线程稍后冻结位置 `:744` 起。
- 最小触发：真实视频已播放一段时间，`pause()` 之后、推帧线程将 `pauseApplied` 置 true 之前调用 `resume()`。
- 实测：真实 `Tests/Fixtures/w1a-sample-20s.mov`，60fps 节目播放到 1.5s / pushed=91；立即 pause/resume 后位置回 0，随后 0.5s pushed 最多到 92 后不再增加。重复两次一致。等待暂停落实 100ms 再 resume 的对照位置 1.466→1.983，pushed=99→129，正常。
- 与 App 的相关性：`SwitcherSession.swift:238–242` 每 1/60s poll，`InputRuntime.swift:129–132` 将 paused 变更转为直接 pause/resume。探针将两次调用间隔改为 1/60s：60fps 8 次对照没复现；30fps 节目两次中一次在 2.933s→0、pushed=90 后连续 0.5s 不变，另一次正常。说明窗口依赖帧相位，不能把双调用所有情形视为失败。**尚未 App 宿主端到端复现**；同一轮 poll 中被合并的暂停/恢复不会触发。
- 根因：`pause()` 只置请求标志，原 `anchorMedia` 尚未换成当前媒体位置；`resume()` 无条件把 anchorTick 换成未来拍，继续使用旧 anchorMedia。解码器没有换代/回跳，队首仍在旧播放点之后，因而新时间线要重新追赶旧队列。
- 建议：`resume` 对 `pauseApplied=false` 单独处理（取消尚未落实的暂停请求、保持原时间线，或先原子冻结当前播放位置）；覆盖立即恢复、间隔一轮 App poll、30/60fps 与暂停定位组合。
- 证据：真实生产 Inputs 全部原始 Swift 源编成独立 dylib，注入只记录帧的槽；保存的 FileMain 为最终版本（后续 poll16 测试等待 pushed≥90，最初 immediate/applied 测试等待 position≥1.5s），不能声称早期日志来自最终源文件逐字节版本；`Audit20261022FileMain.swift`、`Audit20261022-file-immediate.log`、`-applied.log`、`-poll16.log`、`-poll16-phase.log`。首次沙箱内 AVFoundation 未产帧，已弃用那轮数据；上面数据全部来自解除沙箱后的独立探针。未连接摄像头/麦克风。

### CI-05 — P1：DeckLink 超大声道映射先加 1 再钳位，输入启动可溢出

- 位置：`Packages/SwitcherInputs/Sources/SwitcherInputs/Common/InputChannelMap.swift:33`，调用链 `DeckLinkInput.swift:185`、`:261–263`。
- 最小触发：DeckLink InputSource 的 `channels:[9223372036854775807]`，App 常规注入 2 声道 audioRing 后启动。
- 证据级别：生产 `requiredSourceChannels(map:[Int.max],destinationChannels:2)` 独立进程 SIGTRAP；`[999]` 对照返回 1000。App/API/DeckLink 生命周期到该函数的可达性为静态确认，未启动真实卡或 App。
- 根因：契约明确越界映射应钳到源声道范围，然而计算最低采集声道数时先对原始映射 `+1`，导致 Int.max 溢出；`embeddedAudioChannels` 后面的 16 路封顶来不及。
- 边界：需编译时 SDK 可用（无 SDK 时 start 直接抛 unavailable）；无需已接真卡，因为 `attempt` 在检查 `isDriverPresent` 与设备枚举前先算 `cfg.audio_channels`。App `InputFactory.swift:67–71` 默认提供 audioRing，主 API 与 `MixerState.validate` 不检查该 source 参数。
- 建议：在 `requiredSourceChannels` 进行饱和加法，或在 DeckLink 的映射需求计算前按最大源声道 16 钳位；按契约保留越界值安全降级的行为。
- 证据：`Audit20261022ChannelMain.swift`、`Audit20261022-channel-max.log`、`-999.log`。没有把音频设备的普通 clamp 路径误判为同样崩溃。

### 已交根 agent 合并的跨层发现

- **运行中 loadShow 改 format 只换状态**：生产 CommandValidator 接受 60→30fps，reducer 返回新 30fps 格式。`Engine`、`MetalRenderer`、App `SwitcherSession` 的时钟/格式在构造/prepare 时固定；App poll 未重建。原始校验器+reducer 探针 `loadFormat` 已证明接受，App 层由根 agent 继续验证，避免两份独立问题。

### 验证到的其他行为，暂不列主缺陷

- **叠加动画中途改时长会倒退**：60 拍 fade 在第 30 拍 opacity=0.5，setOverlay 改为 120 拍后第 31 拍变 0.258333。代码 `MixerReducer.swift:216–221` 沿用旧 startTick，不按当前进度重锚；`ftb` 同操作已有重锚逻辑。纯 reducer 已实测，但未确认产品是否要求叠加设置在进行中连续生效，留作明确行为项，不能冒充视觉实测。
- **节目尺寸与超大正帧率缺少域验证**：`Show.load` 对 width=-1/height=0 成功；frameRate=Int64.max/1 可解码，但 `MixerState.newShow(format:)` 在默认动画/槽时长换算阶段 SIGTRAP。这支持 CI-01 的格式校验建议，尚未测 App 打开这两份文件的完整路径，未单列新崩溃项。
- `InputThread`/`NativeThread` 超长 UTF-8 名字用 byte prefix 强制 String 解包有理论崩溃，但产品实际传入的名字为固定 ASCII + 编号，未找到用户可达路径，未报告为产品缺陷。
- `SPSCOverwriteRing(capacity:1)` 满队列标记存在歧义，但产品生产调用未发现 depth=1，未做并发复现，未报告为产品缺陷。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 探针 ID | 期望/判断 | 运行结果 | 结论 |
|---|---|---|---|
| CI01-valid | 有效节目正常加载 | exit 0 | 对照通过 |
| CI01-zero / negative | 非法数据抛错、不终止进程 | 两者 SIGTRAP -5 | 确认缺陷 |
| CI01-min-denominator | 不可表示的有理数抛错、不溢出 | SIGTRAP -5 | 确认缺陷 |
| CI02-overlays0 | 抛 overlayCount 错误 | precondition SIGTRAP -5 | 确认缺陷 |
| CI03-ftbMax | 拒绝时长或安全处理反转 | 校验接受、reducer SIGTRAP -5 | 确认缺陷 |
| CI04-immediate | 播放位置连续、继续出帧 | 1.5→0；0.5s 至多 +1 帧，两次一致 | 确认缺陷 |
| CI04-applied | 暂停落实后恢复正常 | 1.466→1.983；+30 帧 | 反证对照通过 |
| CI04-poll16-60 | 16.7ms 间隔 | 8 次正常 | 不能声称必现 |
| CI04-poll16-30 | 16.7ms 间隔 | 2 次中 1 次 2.933→0、0.5s +0 帧 | 窗口可达；App未实测 |
| CI05-mapMax | 越界映射安全钳位 | SIGTRAP -5；999对照 exit0 | 函数级确认，链路静态 |
| format-load | 验证是否拒不同格式 | accepted，state frameRate=30 | 交根 agent 跨层确认 |
| overlay-duration | 检查修改前后进度 | 0.5→0.258333 | 行为确认，产品口径待定 |

所有探针预期故障只发生在自行创建的独立进程，没有给用户 App 发送畸形请求；没有修改测试阈值。主 agent 在主仓执行的全量测试结果不由本报告代写。

实际执行的构建/运行方式（路径为当时真实路径）：

```sh
# 第一次试图链接主仓缓存失败：旧缓存 Swift6.3.3 与当前 Swift6.4 不兼容，exit1；未拿这次作为测试结果。
# 之后从审查树原始源编译，以下四组 swiftc 均最终 exit0：
swiftc -swift-version 6 -parse-as-library -emit-module -emit-library -module-name SwitcherContracts -module-cache-path /tmp/Audit20261022ModuleCache -I /Users/plus/plusmix/Packages/SwitcherCore/.build/arm64-apple-macosx/debug/CSwitcherContracts.build Packages/SwitcherCore/Sources/SwitcherContracts/*.swift -emit-module-path /tmp/SwitcherContracts.swiftmodule -o /tmp/libSwitcherContracts.dylib
swiftc -swift-version 6 -parse-as-library -emit-module -emit-library -module-name SwitcherInputs -module-cache-path /tmp/Audit20261022ModuleCache -I /tmp -I /Users/plus/plusmix/Packages/SwitcherCore/.build/arm64-apple-macosx/debug/CSwitcherContracts.build -L /tmp -lSwitcherContracts Packages/SwitcherInputs/Sources/SwitcherInputs/*/*.swift Packages/SwitcherInputs/Sources/SwitcherInputs/SwitcherInputs.swift -emit-module-path /tmp/SwitcherInputs.swiftmodule -o /tmp/libSwitcherInputs.dylib
# Core/Reducer/File/Channel 的 Main 使用 -parse-as-library、相同 -module-cache-path/-I/-L 编译；
# Reducer 还直接纳入生产 MixerReducer.swift 与 CommandValidator.swift，File/Channel 链接 -lSwitcherInputs。
/tmp/Audit20261022CoreProbe valid
/tmp/Audit20261022CoreProbe rationalMin
/tmp/Audit20261022CoreProbe fpsZero
/tmp/Audit20261022CoreProbe fpsNegative
/tmp/Audit20261022CoreProbe overlays0
/tmp/Audit20261022CoreProbe dimensions
/tmp/Audit20261022CoreProbe fpsHuge
/tmp/Audit20261022ReducerProbe ftbMax
/tmp/Audit20261022ReducerProbe overlayDuration
/tmp/Audit20261022ReducerProbe loadFormat
/tmp/Audit20261022FileProbe immediate
/tmp/Audit20261022FileProbe applied
/tmp/Audit20261022FileProbe poll16
/tmp/Audit20261022FileProbe poll16_phase5
/tmp/Audit20261022FileProbe poll16_30
/tmp/Audit20261022ChannelProbe 999
/tmp/Audit20261022ChannelProbe max
```

运行由 Python `subprocess.run(..., capture_output=True)` 收集 stdout/stderr 与 returncode；SIGTRAP 用 Python 的 `-5` 记录。表内重复次数来自已完成记录，收尾阶段没有再执行新探针。进程 stderr 对某些整数溢出为空（例如 rationalMin/channelMax），因此日志是空文件，退出码只有工具执行记录与本报告表格，不补造堆栈。

## 3. 没做的和原因

没有更改业务代码或契约；当前请求是全面找 bug，修复由后续明确安排。没有另跑全量/App测试，避免和主 agent 争用全局端口/测试宿主；隔离探针编译器为当前 Swift 6.4（旧主仓缓存是 Swift6.3.3，无法直接 import，故重新从审查树源码编小 dylib）。没有新增包内 XCTest。

BLOCKED-硬件：真实 DeckLink/UVC/外部 NDI 源/多通道音频设备、屏幕授权与热插拔恢复；相关结论只给静态检查范围，不能声称设备验收通过。GPU/显示实时性与长稳不能和整仓测试同时测，本次没有制造负载测性能阈值。

## 4. 对契约的疑问

未修改契约。需后续明确 ProgramFormat 的有效尺寸/帧率和各时长的上限，统一 Codable/API/Show/reducer 的报错语义。现有契约已明确声道映射越界钳位，CI-05 修防溢出不需要改变公开行为。叠加动画进行中改时长是否连续生效需明确产品预期，暂不当成确认主缺陷。

## 5. 下一个会话需要知道的坑

证据目录为本审查树 `.build/bug-audit-20261022/core-inputs/`，包含探针源、输入 JSON、日志；这些构建证据被 `.gitignore` 忽略，不会自然进入提交。报告是唯一新增的跟踪候选文件。多个探针故意使子进程 SIGTRAP，因此进程错误日志属复现证据，不是正在运行的 App 崩溃。

没有重新把已知的输入编号无上限、D06 ISO 删除重加、音频连切/AFV边角、NV12 NDI大图裁切、短片循环纹理表换纹理、任意角度方向矩阵等列作新发现。CI-04 与旧 D13 共用暂停区，但旧 D13 是 pause/seek 覆盖定位；此次是 pause/resume 未落实导致重新锚定，两者触发和修复点不同。
