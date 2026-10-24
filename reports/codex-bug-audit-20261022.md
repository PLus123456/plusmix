# 2026-10-22 全仓并行 bug 审查

基准：main `1f9be64`（G10 后）。独立审查树 `/Users/plus/.codex/worktrees/bug-audit-20261022/plusmix`，分支 `codex/bug-audit-20261022`。3 个子 agent 加主审查并行，未修改业务代码、公共契约、既有测试或 main，未 push / merge。新增文件只有审查报告和复现测试。

## 1. 做了什么

覆盖 Core 的 Contracts / Engine / Render，Inputs，Audio，Outputs，Control，TestKit，两项命令行工具、Stream Deck、发布/长稳脚本、App 会话与 UI 接线、CameraExtension。按模块阅读关键实现、追踪跨层调用、对照 G10 已修表与当前 KNOWN_ISSUES，针对候选问题运行隔离探针和真实 App 宿主测试。不是逐行形式化验证，也不表示已排除所有 bug。

严重程度沿用 [测试标准 §6](../docs/testing/测试标准.md)：S0 崩溃/直播中断类，S1 功能错误但节目可继续，S2 有绕过办法的问题。此处 S 级别与分项报告的 P1/P2 审查优先级不同；低概率或极端参数已在触发条件注明，不把条件省略成日常必现。崩溃类按标准字面列 S0，不代表都已在真实播出中发生。

### 新发现汇总（13 项）

| ID | 级别 | 问题与影响 | 证据 |
|---|---|---|---|
| N01 | S0 | 非法帧率 JSON 在解码时直接崩溃，无法返回可捕获错误 | 真实 Show.load 隔离进程；0/负帧率、Int64.min 分母均 SIGTRAP |
| N02 | S0 | 节目 overlays 数量不为 4 时，先触发构造断言，再也到不了 validate | 真实 Show.load，空数组 SIGTRAP；四项对照正常 |
| N03 | S0 | 主 API 接受 Int.max 的 FTB 时长，特定电平反转时 Double→Int 溢出 | API 解码/校验与生产 reducer 分别实测；未跑 HTTP→App 全链 |
| N04 | S0 | 磁盘下限 MB→bytes 可溢出；若超大值已持久化，启动也会再崩 | UI 同款解析/换算子进程 SIGTRAP；设置持久化/启动链静态确认 |
| N05 | S0 | DeckLink 声道映射 Int.max 先加 1 后钳位，启动路径可溢出 | 生产映射函数 SIGTRAP；SDK 启动链静态确认，无真卡验收 |
| N06 | S1 | ISO 切备用目录漏释放旧分支；分支满额时悄悄改录 PGM/Master | 真实 App 回调，停录后残留 1 分支；满额替换为普通 Recorder |
| N07 | S1 | 新建纯音频输入允许 ISO，但收不到视频，最终无录像 | 真实宿主+纯音频合成源，149248音频帧、0视频帧，停止无文件 |
| N08 | S1 | API loadShow 换格式只改状态，实际渲染/时钟仍用旧格式 | App 状态 720p30，实际纹理 1080p、时钟 60fps |
| N09 | S1 | 文件 pause 尚未落实就 resume，播放位置回退并短暂停帧（实测至少0.5秒） | 真实文件输入；30fps+16.7ms 间隔 2 次中 1 次复现，未 App 全链 |
| N10 | S1 | 录像首音频块晚到时写到样本 0，随后才补静音 | 真实 MOV 首非零样本 0，预期 24000；不是整轨持续提前 |
| N11 | S1 | 叠加输入选择“（无）”不能清空，仍保留旧路由 | 真实App设置模型：选择nil后，实际input仍为1 |
| N12 | S1 | WebSocket 新订阅可收到倒序状态，控制面板短暂回退 | 真实 StateFeed 受控交错，sequence=[2,1,2] |
| N13 | S2（工装） | 重签失败仍 exit 0，调用方误认为签名成功 | 临时 App + 不存在身份；原 ad-hoc 签名保留 |

#### N01：帧率解码没有安全拒绝非法数值

[Time.swift:295](../Packages/SwitcherCore/Sources/SwitcherContracts/Time.swift#L295) 的 Codable 调到含 precondition 的 FrameRate 构造；[Rational 解码:238](../Packages/SwitcherCore/Sources/SwitcherContracts/Time.swift#L238) 仅拒绝分母 0，Int64.min 归一化变号会溢出。有效节目里的帧率换成 0/1、负值或分母 Int64.min 后，Show.load 子进程分别 SIGTRAP。屏幕输入 frameRate 也使用同一解码类型，命令校验器无法拦住解码阶段断言。应在解码层抛错，数值归一化检查表示范围。CI-01 记录输入与对照。

#### N02：叠加数组先构造、后校验

[Show.swift:116](../Packages/SwitcherCore/Sources/SwitcherContracts/Show.swift#L116) 调用 makeState 后才 validate；[MixerState.swift:845](../Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift#L845) 要求恰好四项并 precondition。`overlays=[]` 是可解码 JSON，但直接崩溃；现有 overlayCount 错误分支来不及运行。loadShow 校验器同样先 makeState。需要在不可信数据进入断言构造前校验。这与 N01 是独立字段及检查点，单修其中一项不会修复另一项。

#### N03：主 API 的 tick 时长未限制可安全计算的范围

[CommandValidator.swift:45](../Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift#L45) 接受 Int.max；[MixerReducer.swift:76](../Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift#L76) 反转时将 `progressed * Double(duration)` 转回 Int，progressed=1 时 Double(Int.max) 已舍入到 2^63，触发崩溃。实测序列为默认状态 ftb(true)→setFTBDuration(Int.max)→ftb(false)，直接 reducer 不 advance，电平仍为 0。StateMachine 同拍按序应用命令的代码支持此状态可达，但未跑真实 HTTP/App 崩溃。兼容层 D03 已修的毫秒 Double 解析是另一条路径，不能据此认为主 API ticks 安全。统一时长范围，并保护加减和转换。

#### N04：磁盘下限数值换算溢出，持久化后可阻断启动

[AppController.swift:575](../App/Sources/AppController.swift#L575) 与 [SwitcherSession.swift:150](../App/Sources/Engine/SwitcherSession.swift#L150) 使用 `UInt64(max(0, MB)) * 1024 * 1024`。最小溢出输入 17592186044416 MB（2^44）可被 UI 同款 Int 格式解析；隔离进程 SIGTRAP。前一数值 17592186044415 正常。commitSettings 先 save 后 apply；若值已落盘，启动加载仍无上限校验。没有改用户真实 defaults，也没有证明首次崩溃前异步落盘必然完成。应在保存/加载时统一验证，并使用安全换算。

#### N05：DeckLink 计算所需声道时提前溢出

[InputChannelMap.swift:33](../Packages/SwitcherInputs/Sources/SwitcherInputs/Common/InputChannelMap.swift#L33) 对原始 channels.max 做 +1；[DeckLinkInput.swift:261](../Packages/SwitcherInputs/Sources/DeckLink/DeckLinkInput.swift#L261) 随后才封顶 16。生产函数 channels=[Int.max] 子进程 SIGTRAP，[999] 对照正常。App 提供 audioRing、SDK 已编入时，计算发生在驱动/设备检查前；无 SDK 路径会提前 unavailable，不触发。未接真卡或通过 App 启动。应在加法前钳位/饱和处理，保留契约的越界映射安全降级行为。

#### N06：ISO 备用目录切换丢失资源和路由约束

[OutputRuntime.swift:598](../App/Sources/Engine/OutputRuntime.swift#L598) 的旧录像停止回调只移除视频/音频消费者，没有 releaseBranch。下一段又在 :610 申请分支；最多四分支占满时返回 nil，[attach:460](../App/Sources/Engine/OutputRuntime.swift#L460) 因而使用普通 Recorder 与 Master 音频源。

真实 App 探针以独立临时目录录 input2、PGM=input1，通过 DiskMonitor 原有 onEvent 回调注入一次低空间事件（未填满真实磁盘）：正常切换停止后 branchCount=1，应为0；额外占满三分支时，替代消费者为普通 Recorder、branch=nil，原配置仍写 input2。后者是实际接线错误，测试没有逐帧分析备用文件内容。两种表现归同一备用切换生命周期问题计一项。应在边界正确交接/回收分支；失败时保留 ISO 源约束并报错，不能静默走 PGM。

#### N07：纯音频 ISO 无法产出文件

[OutputPagesModel.swift:189](../App/Sources/Settings/OutputPagesModel.swift#L189) 允许“显示全部输入”后勾纯音频 ISO；手册明确列出该流程。新 .audio 来源没有视频生产者，InputRuntime 新建空帧槽；只有替换旧视频源时才额外推黑帧。[ISOFrameTap.swift:58](../Packages/SwitcherOutputs/Sources/ISO/ISOFrameTap.swift#L58) 收不到帧便返回，Recorder 从未创建 writer，停止时“没有写入任何视频帧”。需要持续黑帧或音频独立录制支持，或明确拒绝不支持路由。追加测试使用合成 PCM 驱动纯音频工厂，避免设备权限；真实宿主实测 sourceFrames=149248、inputSlotPushed=0、ISO forwarded=0、noFrame=60、audioTokenNil=false，停止报“没有写入任何视频帧”、fileExists=false、lastResults=nil。所有启动/挂载/停止清理断言通过，只在应有录制结果处失败。

#### N08：loadShow 格式状态与实际管线不一致

[SwitcherSession.swift:337](../App/Sources/Engine/SwitcherSession.swift#L337) 只协调输入、输出和播放；Session.format、Engine 时钟与渲染器在构造时固定。真实 App 向同一个 session 发送合法 `.loadShow`（1080p60→720p30），接受后 state.format=720p30，但 session.format=1080p60、读回纹理1920×1080、clock.frameRate=60。状态/API报告与实际输出不符，按新格式计算的时长也可能偏离。应由会话重建路径统一加载，或明确拒绝运行中格式变更；不要只改 snapshot。

#### N09：尚未落实的暂停被恢复错误重锚

[FileInput.swift:402](../Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift#L402) 的 resume 无条件改 anchorTick，pauseApplied=false 时 anchorMedia 仍是旧锚点。真实20秒素材在1.5s立即 pause/resume 回到0，0.5s至多多一帧；等100ms再resume的对照正常。用App轮询间隔16.7ms时，60fps八次正常、30fps两次一次复现，说明依赖相位。旧D13修的是pause/seek覆盖定位，本次是pause/resume未落实，触发和修复点不同。应取消未落实暂停并保留时间线，或原子冻结当前位置。未做App宿主完整点击复现。

#### N10：首音频块时间戳晚于开录点时丢掉前导静音

[Recorder.swift:494](../Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/Recorder.swift#L494) 首块只处理早于起点的裁切，没有晚于起点的补静音。实际录制1秒LPCM MOV，首块256样本值0.6、PTS=t0+0.5s；解码首非零样本为0，应为24000±1。后续块才做drift校正，于是补静音出现在首块之后。总长47999样本近似正常，时长测试会漏。只证明首块内容错位，不是整条音轨持续提前。

#### N11：叠加“（无）”映射到了“保持原输入”命令

[OverlaySettingsPanel.swift:88](../App/Sources/Settings/OverlaySettingsPanel.swift#L88) 对nil发送overlay(input:nil)，而[Reducer:201](../Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift#L201)的nil语义是保留路由。清空选项没有实际效果，开启的旧画面仍会显示。不能直接改nil语义，否则开关快捷动作也会清路由；需要明确清除命令/语义，或修UI入口。真实宿主通过面板model.setInput选1、再选nil，0.5秒后state.overlays[0].input仍为1，清除断言失败。

#### N12：订阅补发与旧快照扇出之间缺少顺序保证

[StateFeed.swift:123](../Packages/SwitcherControl/Sources/SwitcherControl/API/StateFeed.swift#L123) 补发最新快照，[:162](../Packages/SwitcherControl/Sources/SwitcherControl/API/StateFeed.swift#L162) 编码在订阅锁外。编码旧快照暂停期间加入的新订阅，会先拿最新2再收到旧1，随后回到2。生产类注入点受控交错实测[2,1,2]；现有Stream Deck客户端直接覆盖状态，没有滤旧。影响短暂回退和窗口内toggle目标，不声称永久失步。修复需兼顾同sequence不同tick动画快照。

#### N13：签名脚本吞掉重签错误

[sign.sh:36](../scripts/release/sign.sh#L36) 默认分支使用 `|| true`，verbose分支也不检查失败；下一条verify只验证已有签名。临时测试App先ad-hoc签，再指定不存在身份，打印no identity found但exit0且原签名仍有效。完整公证流水线可能后续拒绝，不能声称最终发行必然放行。立即传播codesign失败并检查请求身份。

### 已知问题与未确认项（不计入13项）

对照 [KNOWN_ISSUES](../docs/KNOWN_ISSUES.md) 和 [上一轮审查](codex-debug-audit-20261013.md)：

- 上轮D01–D17/K01已在G10销号，本轮没有把它们重新计数。N03不同于旧D03兼容层解析，N09不同于旧D13暂停定位。
- 输入编号无上限：已有S1，提案032 / prompt123待处理。
- ISO删后重加定格、音频tap槽复用：已知D06边角。额外音频探针实测旧input1 tap收到新input2的声音（尾部均值0.530327737），补强已有证据，不算新问题。
- 普通Cut/Auto旧淡变、Auto中途开AFV、末拍Cut分类、压缩器latency残留：已知收口四条，归125。
- API/WS推流凭据、诊断URL路径、SRT保留字符、MIDI冷启动、中文输入法标点、NV12大画面NDI裁左上、非正交文件矩阵等已有条目，本轮未重复归新，也未逐项重新实机验收。
- 本轮App全量唯一失败的 `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions` 已在KNOWN_ISSUES“测试与工具”记录；本轮单独复跑通过，归已知偶发项，未掩盖整轮失败。
- A4全部无click的unanchored事件不算缺：用户2026-10-18已裁定，按现有口径；不是新bug。
- 长稳无probe或无配对时A3为null但overall_pass为true：G9报告和单测已记录的判定口径，归已知验收风险。之前排查过程中的疑似新工装问题，经追溯后排除；没有否定历史真实长稳结果。

保留线索：ConsumerPump移除tap时C队列生命周期可能与泵消费交错（未动态复现）；NDI换源等待音频重试后是否漏重挂（当前宿主探针通过，registerRetries=0，音频块193→381，未命中重试）；叠加动画中途改时长进度倒退（reducer行为实测，但产品连续性要求尚未确认）。负尺寸/极大正帧率进入下游的其他路径未完整验证。均不加入已确认数量。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

全部3个子agent完成，交叉复核完成；所有已启动测试进程结束。机器为 Apple Silicon / macOS 27.0.1 / Xcode 27.1 / Swift 6.4。

| 验证 | 数值 / 结果 |
|---|---|
| `make lint` | exit 0，禁词/版本/依赖/手册/206个文档链接/实时符号检查通过 |
| 两项工具冒烟 | switcher-headless、frameprobe 均编译并启动通过；测试前已重新编译release frameprobe |
| SwitcherCore | 346项，345通过、1跳过、0失败 |
| SwitcherInputs | 124项，115通过、9跳过、0失败 |
| SwitcherAudio | 178项，171通过、7跳过、0失败 |
| SwitcherOutputs | 157项，153通过、4跳过、0失败 |
| SwitcherControl | 97项，96通过、1跳过、0失败 |
| SwitcherTestKit | 82项全部通过 |
| 六包合计 | **984项：962通过、22跳过、0失败** |
| App全量（重新生成工程后） | **296项：291通过、4跳过、1失败**；失败方法为 `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions`，3个断言失败 |
| 上述菜单用例单独复跑 | **1项通过，0失败，exit 0**；属于KNOWN_ISSUES已记录的响应链/焦点时序偶发项，未列新增 |
| 已有 Python 工具测试 | soak 35 + perf 22 = **57通过** |
| 已有 Stream Deck 测试 | **11通过** |
| 新增App诊断测试 | **6项：5失败、1通过、0跳过，9个失败断言**；均针对预期正确行为，无修改生产实现；通过的是未命中重试窗口的NDI换源探针 |
| 新增Control诊断测试 | **2项、3个失败断言**：快照倒序1个、主API接受极大时长2个 |
| 新增Recorder诊断测试 | **1项失败、1个断言**：首非零样本0，应为24000±1 |
| 新增Audio tap诊断测试 | **1项失败、1个断言**：复现已知槽位复用，不计新增 |
| 隔离数值/文件/签名探针 | N01–N05/N09/N13的数值、对照及限制见各分项报告；不是用户运行中的App崩溃 |

既有测试没有修改阈值或断言。新增XCTest合计10项、9项失败/1项通过、14个失败断言（其中1项复现的是已知音频tap问题）；这些红色用例就是本轮缺陷证据，不与主树既有基线混算。

**首轮构建问题保留：**最初`make test`六包和工具完成，但App因主树旧的生成工程未包含`SinkStreamState.swift`而编译失败，整体exit 2。随后执行`make gen`（只更新忽略的生成工程）和`make test-app`，完成上述296项；该轮因已知菜单用例失败而exit 2，Xcode test exit 65。之后仅复跑该失败方法，exit 0。不把最初`make test`写成全绿，也未重复六包测试掩盖结果。主树与审查树业务源码均未修改。

22项包测试跳过涉及：旧gate数据不存在、权限拒绝分支前置状态不符、USB/DeckLink热插拔与回环硬件、真音频设备测量开关、签名扩展、外部NDI/人工Companion、无SDK分支在已安装SDK机器上不适用。App4项跳过为系统键盘导航未开、空闲唤醒测量未启用、宿主摄像头未授权、虚拟摄像头缺正式签名；不是4项通过。

App诊断结果：`app/probes.xcresult`（4项、3失败/1通过、7断言失败）与`app/probes-extra.xcresult`（2项、2失败、2断言失败），各自summary JSON和导出的StandardOutputAndStandardError.txt保留实际计数。App全量原始xcresult为主树`.build/DerivedData/Logs/Test/Test-Switcher-2026.10.22_23-22-52-+0800.xcresult`；菜单复跑为主树`.build/bug-audit-20261022/toolbar-retest.xcresult`。


主树全量日志：`/Users/plus/plusmix/.build/bug-audit-20261022/make-test-full.log` 与 `make-lint-full.log`。审查树证据根：`.build/bug-audit-20261022/`。新增测试写“正确行为应如此”的断言，因此当前生产代码应红；它们与未改主树的既有测试结果分开统计。

分项完整测试ID、命令及数值：[Core/Inputs](bug-audit-20261022-core-inputs.md)、[Audio/Outputs](bug-audit-20261022-audio-outputs.md)、[Control/Tools](bug-audit-20261022-control-tools.md)。

## 3. 没做的和原因

没有修改业务代码；本轮目标是找出并汇总bug。没有8小时长稳、性能门禁、真实DeckLink/UVC/多声道设备、跨机NDI、正式签名/公证与虚拟摄像头安装验收；这些依赖专用负载、硬件或账户，源码扫描和单元测试不能代替。没有宣称所有代码逐行审完或不存在其他问题。所有故障探针使用隔离进程、临时文件/测试宿主；没有向用户运行中的App发送异常请求。

## 4. 对契约的疑问

未改公共契约。帧率/尺寸与各类时长的允许范围需统一明确；清空overlay路由需兼顾nil现有“保持”语义；loadShow是否允许改变运行格式需由App与API统一行为。这里只指出待修设计边界，未自行批准或落地契约变更。

## 5. 下一个会话需要知道的坑

- 审查探针故意保留红断言，可作为修复起点；不要把它们混入主树后再声称现有基线退化。
- 原始证据多数位于被git忽略的`.build`；归档工作树前保留日志/JSON/xcresult。主报告及三个分项报告永久记录关键数值与证据限制。
- App测试共享部分临时目录，StreamingTests共享端口；全量与追加宿主探针应错开。不能用并行产生的互扰判产品bug。
- Swift6.4不能直接import旧Swift6.3.3缓存；独立探针已从生产源重新编译。首次沙箱缓存权限错误不计产品失败。
- 修复优先顺序：数据入口崩溃保护与ISO录制正确性，再解决状态/管线一致、文件播放竞态、时间戳与控制顺序，最后修复工装错误传播；现有已知S1仍需收口。
