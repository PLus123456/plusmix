# PlusMix 全项目 Debug 审查报告（Codex，2026-10-13）

> **G9 说明（2026-10-17）**：这份报告是用户 2026-10-13 用 Codex 在独立 worktree `~/.codex/worktrees/debug-audit-20261013`（分支 `codex/debug-audit-20261013`）对 main 22ff4d9 做的全项目 debug 审查，原文没提交，G9 原样搬进仓库（只把绝对路径的 Markdown 链接改成代码字，免得 check-links 去解析）。它新增的四条红用例在 `reports/codex-debug-audit-20261013-DebugAuditTests.swift.txt`，119（W5-P）搬进 App/Tests 当"先写红测试"。复现证据 `.build/debug-audit/evidence/` 只在那个 worktree 里、不入库。逐条的定级（按测试标准 §6）、归属（prompt 115–121）与用户 2026-10-17 的裁定见 docs/KNOWN_ISSUES.md 产品缺陷表与 reports/G9.md §7.1。


> 最终报告：本轮全量测试、App 专项回归与推流录像离线复验已完成。发现均注明证据等级与未覆盖范围；本轮未修复业务代码。

审查日期：2026 年 10 月 13 日（Asia/Singapore）。对象：`main` 的 `22ff4d982a21957e202228ffb9ae2bb7d318c372`，产品版本 0.1.0。环境：Apple Silicon arm64、macOS 27.0.1、Xcode 27.0、Swift 6.4。

本轮横跨 App、六个 Swift 包、两个命令行工具、Stream Deck 插件、CameraExtension 和测试脚本。结论是：正常路径测试覆盖较多，但异常参数、输入换源、缓冲区拥塞和状态切换组合仍有会造成崩溃、内容损坏、无声或无画面的缺陷。应先处理崩溃和数据完整性问题，再做发布验收。

报告汇总 **21 项本次新确认问题（17 项产品问题、4 项检查工具问题）和 1 项重新确认的遗留录制覆盖风险**。“新确认”表示在当前已知问题及定向历史检索中未找到同根记录，不表示之前任何分支都未讨论过。另列一个未接产品界面的库级读数问题，不计入这 22 项。

修复优先级：**P1** 为直播或数据完整性高风险，应在发布前修复；**P2** 为有条件触发或有绕过办法的功能问题；**P3** 为低影响库级问题。此处是修复排序，不擅自修改仓库既有 S0–S3 定级。证据分为“实际 App”“生产实现隔离复现”“静态完整调用链”，后两者不能等同于真实设备端到端验收。

## 1. 做了什么与发现

### 1.1 问题总表

| 编号 | 优先级 | 问题与用户影响 | 证据 |
|---|---|---|---|
| D01 | P1 | 主 API 接受非法文件播放速率或超大定位值，运行时可使整个进程崩溃 | 生产校验器、reducer、时间换算隔离复现 |
| D02 | P1 | 兼容层在空 PVW/PGM 上执行音频动作，强制解包崩溃 | 生产翻译器隔离复现 |
| D03 | P1 | 兼容层超大有限转场时长溢出，整个进程崩溃 | 生产翻译器隔离复现 |
| D04 | P1 | 重叠打开节目会把运行中的节目与保存目标错配，保存覆盖另一份节目 | App 测试宿主实测：A 写入 B 文件 |
| D05 | P1 | 录制、推流、NDI 音频队列满时，新块覆盖消费者正在读的旧块 | 三份生产环实现隔离复现 |
| D06 | P1 | ISO 录制中更换输入来源，后半段继续录旧分支并定格 | App 测试宿主实测：新增 61 拍均重复旧帧 |
| D07 | P2 | 换源等待音频注册重试时再次换源，过期重试可能占住编号、造成持续无声 | 生产方法加时序替身复现；完整 App 未测 |
| D08 | P1 | NDI 直接输出图片、屏幕等 BGRA/UYVY 输入时没有视频，状态仍显示发送中 | 真实像素缓冲转换探针、UI 调用链 |
| D09 | P1 | 虚拟摄像头扩展未保存 sink client，协议启动入口不会开始消费 PGM | Apple SDK 协议与完整调用链；未签名实机验收 |
| D10 | P1 | 自动淡变中途按 Cut，画面立即切完，声音继续旧的长淡变 | 核心事件与音频控制完整调用链 |
| D11 | P2 | FTB 途中修改时长，只改变视频，音频继续旧斜坡 | 生产 reducer 与音频桥隔离复现 |
| D12 | P2 | 同一路的第二个及之后视频分支引用泄漏，重复操作累积内存 | 生产 tee 实现与析构计数探针 |
| D13 | P2 | 连续暂停与定位时，定位目标可能被旧帧覆盖 | 真实文件、生产 FileInput 运行 |
| D14 | P2 | 在片尾预解码窗口开启循环，开关已开但仍停播 | 真实文件运行，两次复现 |
| D15 | P2 | 文件输入忽略方向矩阵，手机竖屏视频可能横置 | 真实解码探针、下游渲染静态核查 |
| D16 | P2 | 打开 LastSession 时丢失原节目目录，相对路径素材恢复到错误位置 | App 真实文档与路径解析方法实测 |
| D17 | P2 | Stream Deck 改连接设置后，旧 socket 回调破坏新连接 | 原 JS 与受控 socket 事件复现 |
| T01 | P1 工装 | 长稳录像分析缺段仍判“全部通过”，漏检异常 | 完整报告脚本运行，构造缺段数据 |
| T02 | P2 工装 | frameprobe 把帧序号当节目拍号，前序漏帧会误报后续正确转场 | 生产分析算法隔离复现 |
| T03 | P2 工装 | 默认 macOS Bash 在 UTF-8 locale 下使实时符号检查脚本异常退出 | 本轮 make lint 实际失败、locale 对照复现 |
| T04 | P2 工装 | 测试缺少工具构建前置，复用陈旧 frameprobe 或跳过必需分析 | 本轮 9 条用例无 JSON 失败、旧 CLI 直接复现 |
| K01 | P1 遗留 | App 录制路径未避让已有文件，固定模板或同秒再录会覆盖旧录像 | App 测试宿主实测：开录即删除同名旧文件 |

### 1.2 崩溃与数据完整性

**D01 主 API 文件参数。** `CommandValidator.swift:41`（Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:41） 对来源变更只检查输入编号，`addInput` 也不校验文件参数；定位只检查有限非负。`rate=0/-1/0.0001/1e300` 都被当前校验器和 reducer 接受。非正速率在 `FileInput.swift:130`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:130） 断言崩溃；极小正数近似成 0 后取倒数崩溃；`seekPlayback(seconds:1e300)` 在限制到文件时长前就进行 Int64 转换并溢出。独立进程观察到 SIGTRAP；没有对用户正在运行的 App 发送这些请求。修复需同时覆盖 API、节目文件和 FileInput 底层转换边界，单修 API 不够。

**D02 兼容层空输入。** 空节目中执行 `Function=Audio&Input=0`，或 `Solo Input=-1` 等动作，`InputReference.swift:15`（Packages/SwitcherControl/Sources/VMixCompat/InputReference.swift:15） 把特殊编号解成 `noInput=0`，随后 `FunctionTranslator.swift:154`（Packages/SwitcherControl/Sources/VMixCompat/FunctionTranslator.swift:154） 对 `state.input(input)!` 强制解包。四组音频动作均在独立进程 SIGTRAP；普通不存在的编号 99 则正常返回错误。应对需要真实输入的命令返回 InputNotFound，并去掉强制解包。

**D03 兼容层时长溢出。** `Fade Duration=1e300`、`SetTransitionDuration1 Value=1e300` 通过有限值检查，却在 `FunctionTranslator.swift:301`（Packages/SwitcherControl/Sources/VMixCompat/FunctionTranslator.swift:301） 转 Int 时崩溃。控制组 500 ms 正常换算为 30 拍，NaN 正常拒绝。修复点是可表达范围检查及可失败整数转换。D02/D03 需要开启默认关闭的兼容服务；D01 可以经主 API 或节目文件触发。

**D04 打开与保存目标错配。** `AppController.swift:512`（App/Sources/AppController.swift:512） 在取得会话替换锁前，先通过 `documents.load` 改写 `currentURL`；`replaceSession:196`（App/Sources/AppController.swift:196） 对重入调用直接返回。A 正在 `await stopSession/start` 时再次打开 B，B 的 URL 可以生效但 B 的 session 被丢弃；随后保存仍运行的 A 就写进 B。修复应把读取、提交文档身份与替换会话作为一个串行事务，拒绝或排队的请求不能提前改保存目标。

**D05 音频块被覆盖。** `AudioBlockRing.swift:73`（Packages/SwitcherOutputs/Sources/SwitcherOutputs/Support/AudioBlockRing.swift:73）、`PCMBlockRing.swift:75`（Packages/SwitcherOutputs/Sources/Streaming/PCMBlockRing.swift:75） 和 `NDISender.swift:602`（Packages/SwitcherOutputs/Sources/NDISend/NDISender.swift:602） 的 `pop` 释放队列槽，却返回该槽内部指针供锁外读取。队列原本满时，只需一次新 `push` 就覆盖它。容量 2/128/256 都复现样本从 1 变 999、返回的 PTS 仍为 1。当队列积满后，消费者 pop 与新 push 交错且旧块仍在读取时触发，不能仅靠加深队列解决；需要消费者独占的预分配缓冲或明确借出/归还协议。本轮未做完整录制背压听测。

**K01 旧录像覆盖是遗留风险。** `OutputRuntime.swift:363`（App/Sources/Engine/OutputRuntime.swift:363） 只与当前在录的 URL 去重，不检查磁盘已有文件。固定模板 `fixed` 每次得到同一路径；默认时间精度也只有秒。`Recorder.swift:242`（Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/Recorder.swift:242） 会删除旧文件，且删除发生在编码器启动成功之前。Recorder 的库接口本来就约定覆盖，因此应修 App 路径分配层。此风险已经记在 `早期报告:99`（reports/w2-app-2.md:99），不是本次首创发现。建议自动分配唯一文件名，并覆盖快速起停、同名输出与 MP4 转封装的情况。

### 1.3 输入与输出路由

**D06 ISO 换源定格。** `InputRuntime.swift:80`（App/Sources/Engine/InputRuntime.swift:80） 更换来源时停旧输入并重建 tee；`OutputRuntime.swift:240`（App/Sources/Engine/OutputRuntime.swift:240） 对已经在录的输出不更新分支。`ISOFrameTap.swift:58`（Packages/SwitcherOutputs/Sources/ISO/ISOFrameTap.swift:58） 因此每拍重复旧 `lastReturned`，按新的节目拍点继续写入录像，录像时长继续增长。只改同一文件的速率/循环不重建输入，不属于此触发条件。应跟随当前输入换分支并保持 Recorder，或在界面/API 明确拒绝这种操作；当前行为没有提示。

**D07 过期音频重试。** `AudioRuntime.swift:70`（App/Sources/Engine/AudioRuntime.swift:70） 的 30 ms 延迟注册没有代次校验，删除/再次替换也不取消。真实方法加 16 ms 淡出替身的 A→B→C 探针最终注册 B、累计重试 11 次；B 生产者已停止，残留音频耗尽后无声。该探针用 5 ms 间隔，真实 App 快照约 16.7 ms，默认 16 ms 摘除等待、2 ms 控制周期与约 16.7 ms 轮询之间存在可推导的竞争窗口，但真实 App 尚待验证；若下一次轮询前旧输入已摘除，新输入能立即注册，则不触发该故障。补充对照将 C 的请求预约在 16.7 ms：16 ms 摘除组 3/3 最终为 C，18 ms 摘除组 3/3 为过期 B；真实计时器存在延迟，且替身线程模型不同，仍不升级为 App 实测。需要每个输入编号的 generation 和目标校验，stop/unregister 一并失效旧任务。

**D08 NDI 原始输入格式缺口。** 设置页允许选择全部输入。`NDIInputFeed:952`（App/Sources/Engine/OutputRuntime.swift:952） 将原始像素帧直送发送器，而 `NV12ToUYVY.swift:40`（Packages/SwitcherOutputs/Sources/NDISend/NV12ToUYVY.swift:40） 只接受 NV12。图片和默认屏幕输入是 BGRA，NDI 输入常为 UYVY/BGRA。真实像素缓冲探针得到 NV12 accepted、BGRA/UYVY `notNV12`；GPU 分支同样有格式守卫。没有真实接收端回环，格式失败链路已经确定。临时可将该输入放入 PGM 再输出 NDI PGM。正式修复需支持对应格式并把连续转换失败反映到状态。

**D09 虚拟摄像头接线。** `CameraExtensionProvider.swift:302`（CameraExtension/Sources/CameraExtensionProvider.swift:302） 的授权回调不保存 client，协议入口 `startStream()` 又传 nil；内部只有 client 非空才启动 `consumeNext`。另写的 `startStream(for:)` 不属于本机 Apple `CMIOExtensionStreamSource` 协议，系统不会通过该协议调用它。此问题独立于现有“尚未签名无法安装”的限制。应从授权回调保存获准 client，并按真实协议启动/停止消费；修复后仍必须在正式签名环境验收，不以本轮静态证明替代设备测试。

**D12 分支泄漏。** `InputFrameTee.swift:65`（Packages/SwitcherOutputs/Sources/ISO/InputFrameTee.swift:65） 每次尝试 CAS 都执行 `passRetained`，失败时没有 release。已有分支后再开 ISO/NDI/Aux 时出现；回收只释放成功安装的一次引用。真实 tee 加析构计数替身：primary、4 分支和一次满额失败申请共创建 6 个槽，释放后只销毁 2 个。真实槽还可能持有末帧像素缓冲，本轮没有测泄漏字节速率。应平衡失败 CAS 的 retain，并加 weak/deinit 回归。

### 1.4 转场与文件播放

**D10 Auto 中 Cut。** `StateMachine.swift:260`（Packages/SwitcherCore/Sources/SwitcherEngine/State/StateMachine.swift:260） 将提前切完归为 completed；`AudioEngine.swift:497`（Packages/SwitcherAudio/Sources/Integration/AudioEngine.swift:497） 对 auto 的 completed 仅清除活动标记，不中止 C 侧已设定的长 crossfade。开启 AFV，10 秒 Auto 在第 1 秒按 Cut，视频立即对调，音频仍可能按原斜坡继续约 9 秒。此项由两份模块的完整调用链交叉确认，未做最终音轨采样。需要区分自然完成与强制完成，后者显式取消或替换旧 crossfade，并按对齐时刻短淡收口。

**D11 FTB 改时长。** `AudioStateBridge.swift:121`（Packages/SwitcherCore/Sources/SwitcherEngine/Audio/AudioStateBridge.swift:121） 只比较 `ftb.on`，遗漏持续时间/起始拍变化。120 拍渐黑走到 30 拍后改为 30 拍，真实 reducer/bridge 探针得到音频事件为空；到第 60 拍视频全黑，旧音频斜坡仍在中途。应在目标斜坡发生变化时同步声音，覆盖缩短、拉长、归零与反向淡回。

**D13 暂停后立即定位。** `FileInput.swift:319`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:319） 的 pause 留下未落实的暂停；`304 行`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:304） 的 seek 改变代次/锚点却保留暂停标志，pacer 稍后在 `627 行`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:627） 仍以旧 held 帧覆盖定位目标。真实 1 秒视频中，目标 0.5 秒，0.4 秒后仍停在 0.1 秒。App 同一快照会先 pause 再 seek，路径可达。临时绕过是暂停稳定后再定位；修复应让新定位代次优先于旧暂停请求。

**D14 片尾打开循环。** 解码器预先 EOF 后只等待 generation；`endAction setter:178`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileInput.swift:178） 却只在实际播放的 `reachedEnd` 已经为真时才重启。在收到 30 帧、实际只推到 28 帧的窗口内打开循环，两次实测均变为 `noSignal`，最终 30 帧、loops=0、seeks=0。应让 EOF 等待响应循环模式变化。临时可再按从头播放，或关闭再打开循环。

**D15 旋转信息丢失。** `FileDecoder.swift:57`（Packages/SwitcherInputs/Sources/SwitcherInputs/File/FileDecoder.swift:57） 不读取 `preferredTransform`，原始解码帧直接交渲染；后者只应用用户输入设置的变换。带 90° 矩阵的 320×240 MOV 仍按 320×240 像素输出。已进一步核查 SurfaceTextureTable、CompositorPasses 和 Placement：直接包装原始宽高，只应用用户设置的旋转，没有读取媒体方向矩阵或处理方向附件。尚未进行 App 画面目视验证。应读取并应用方向/平移矩阵，覆盖 90/180/270°；目前可先转码转正或手动旋转缩放。

**D16 LastSession 相对素材路径。** `ShowDocuments.swift:115`（App/Sources/Show/ShowDocuments.swift:115） 自动保存时保留相对路径，却不保存原节目基准目录；`AppController.swift:394`（App/Sources/AppController.swift:394） 恢复后 `startNew` 清掉文件身份，于是路径解析回默认 Movies/PlusMix。它不同于已修复的“正常打开节目相对 cwd 解析”问题。应在保存恢复快照时固定素材路径，或同时保存恢复所需的基准目录。

**D17 Stream Deck 连接重配。** `api-client.js:52`（Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:52） 的旧 socket close 回调无条件清空 `this.ws`。修改 host/port/token 后，新 socket 已打开，旧 close 仍把状态设为断开；发送 Cut 得到未连接，随后创建第三连接，第二连接未关闭。原 JS 加受控事件顺序复现，未操作真实 Stream Deck。应按连接身份或 generation 过滤旧事件。

### 1.5 测试工具为什么可能误判

**T01 长稳缺段仍放行。** `soak_report.py:150`（scripts/soak/soak_report.py:150） 只合并成功片段，缺段仅记文末备注；总判定未将完整性纳入失败条件。构造 8 小时、96 段而只保留首尾 2 段，原脚本实际退出 0、overall_pass=true、A3 pass=true，仍显示四项全通过。缺的 94 段中发生什么都没有验证。应检查片段完整性、有效覆盖率和 A3 是否可判定。本轮使用的是明确构造的测试数据；仓库现有 `真实 8 小时报告`（reports/W4-soak-8h.md:144） 记录 96 段和 12975 对，没有缺段提示，**本发现不推翻那次运行结果**。

**T02 转场拍号误报。** `FrameAnalysis.swift:234`（Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/FrameAnalysis.swift:234） 把数组 index 当 tick，Fade 分析同样按数组下标取拍。生产算法探针中，正确的第 60 拍 Cut，仅在更早第 20/30 拍删两帧，就报 tick=58，而按 PTS 换算的节目拍仍为 60；正确的 30 拍 Fade 被判 2 帧偏差。应按 PTS 计算节目拍，分别报告缺帧与转场偏差。这不是已知 A4 半秒配对歧义，也不是动态视频延后导致整体拍号变化。

**T03 lint 的 locale 缺陷。** 本轮 `make lint` 实际在 `check-rt-symbols.sh:87`（scripts/check-rt-symbols.sh:87） 退出，原因是 `$target（$config）` 紧邻全角字符，在 macOS `/bin/bash` 3.2 的 UTF-8 locale 下被错误解析为扩展变量名，触发 `set -u`。LC_ALL=C 的同一检查通过，4 个目标文件没有禁用符号；因此它不是已发现实时线程违规。应使用 `${target}（${config}）` 一类明确边界写法，并测试 C 与 UTF-8 两种环境。

**T04 测试在构建工具之前调用旧工具。** `Makefile:70`（Makefile:70） 的 `make test` 先执行 test-packages，再执行 test-tools；前者已经有依赖 frameprobe 的用例。`MediaMTXSupport.swift:29`（Packages/SwitcherOutputs/Tests/StreamingTests/MediaMTXSupport.swift:29） 等测试辅助代码仅看现有文件是否可执行，不确认它与当前源码一致。本次直接选中了 9 月 13 日的旧 CLI：对真实录像运行 stats/frames 都退出 0，却只输出版本号，导致 9 条推流用例“没有 JSON 输出”；干净目录则可能跳过这些必需分析。这些包测试运行时，工具还未由这一入口及时重建，不能把 9 条失败直接计为推流产品故障。应在依赖工具的包测试前构建工具、传递实际产物路径，并验证 CLI 能力。SwiftPM 对已编译包会维护兼容目录链接，因此本报告不将“硬编码路径必然不兼容新版 SwiftPM”列作独立结论。工具构建后自动刷新了兼容链接。用当前工具复验原 10 个录像，帧分析全部通过；4 组 A/V 及相关场景的首帧/时间戳后续离线断言也通过。E7 后半段活体计数/重连时刻与 Adobe 网关字节断言无法离线恢复，所以保留原始 9 条失败，不把它们改记为完整通过。

### 1.6 已有清单仍未完成的事项

以下来自当前 `KNOWN_ISSUES.md`（docs/KNOWN_ISSUES.md），经相关代码路径抽查仍属未完成范围；不重复计为本次新发现：API/WS 全量状态包含推流凭据、诊断包路径密钥脱敏缺口；错误推流凭据持续退避重试；外部显示 Esc/“关闭这路”实际删除配置；部分设置页把启动参数持久化；耳机监听来源菜单、输入分类颜色正式字段尚未接线；外部控制执行未选素材的 Stinger 槽；SRT 保留字符问题；设置导入导出遗漏项、播放/状态相关手册滞后。

发布工程还受签名/公证、Sparkle 配置、macOS 15/26 兼容验收和 L3 人工清单限制。先前 MIDIHost 崩溃、文件循环内存增长已在现有记录中修复，本报告没有把它们重新列成未修产品 bug。

## 2. 测试结果与证据

原始 `make test` 已完成，退出码为 **2**：现有 XCTest 共 **1105 项，1068 通过、28 跳过、9 失败**。9 条失败集中在 T04 的工具前置问题，不能直接视为 9 个推流产品缺陷；也没有把离线补验改记为原测试通过。另行执行的 4 条新增 App 回归全部复现目标问题，共 5 个失败断言。

| 检查 | 本次结果 | 说明 |
|---|---|---|
| 六包 swift test | 861 项：828 通过、24 跳过、9 失败 | 9 条失败均为 T04 的旧 frameprobe 无 JSON；未修改阈值或断言 |
| 两个工具构建与版本冒烟 | 2/2 通过 | make test-tools；frameprobe 构建后自动刷新兼容链接 |
| App 现有 xcodebuild test | 244 项：240 通过、4 跳过、0 失败 | xcresult 确认 Passed；跳过原因见下文 |
| 新增 App 回归探针 | 4 项：0 通过、0 跳过、4 失败 | 5 个失败断言，确认 D04/D06/D16/K01；xcodebuild 退出 65 |
| 旧工具失败的录像离线补验 | 10 个文件全部通过帧断言 | 4 组音视频/首帧/时间戳断言也通过；2 条用例的活体/网关断言未补验 |
| make lint | 失败 | T03；其前的禁词、版本、包约束、依赖方向、手册与链接检查已通过 |
| 完整 make lint（LC_ALL=C） | 通过 | 临时绕过 T03；所有默认检查完成 |
| 实时符号检查 LC_ALL=C | 通过 | 4 个目标文件，0 禁用/未审计符号 |
| Python 长稳/泄漏脚本现有单测 | 35/35 通过 | 不能覆盖新构造的缺段场景 |
| Python 性能判定现有单测 | 22/22 通过 | scripts/perf |
| Stream Deck 现有单测 | 9/9 通过 | 不包含旧 socket close 的重配竞态 |

六包计数（“总数”包含跳过）：

| 包 | 总数 | 通过 | 跳过 | 失败 |
|---|---:|---:|---:|---:|
| SwitcherCore | 322 | 321 | 1 | 0 |
| SwitcherInputs | 110 | 98 | 12 | 0 |
| SwitcherAudio | 159 | 152 | 7 | 0 |
| SwitcherOutputs | 122 | 110 | 3 | 9 |
| SwitcherControl | 77 | 76 | 1 | 0 |
| SwitcherTestKit | 71 | 71 | 0 | 0 |

原始全量日志：`make-test-full.log`（.build/debug-audit-20261013/make-test-full.log）、`lint-full.log`（.build/debug-audit-20261013/lint-full.log）。首次受沙盒限制无法写编译缓存的尝试单独保留，没有计成产品编译失败；后续测试在正常系统权限下运行。

新增 App 探针：`DebugAuditTests.swift`（（审查 worktree）App/Tests/DebugAuditTests.swift）。探针只用临时节目/录制文件验证覆盖风险，不触碰用户已有节目或录像。

| 新增 App 回归 | 期望行为 | 实际观测 |
|---|---|---|
| D04 重叠打开 A/B 后保存 | 运行节目和保存目标保持配对，B 保留输入 `[2]` | session 为 A，保存目标为 B；保存后 B 的输入变成 `[1]`，两项断言失败 |
| D06 ISO 录制中换源 | 换源后输出继续得到新帧 | 1 秒窗口内 forwarded 增加 61、repeated 增加 61，lastSequence 保持 45 |
| D16 LastSession 相对路径恢复 | 素材仍指向原节目目录中的 asset.png | 恢复后解析为 `/Users/plus/Movies/PlusMix/asset.png`，原路径在临时节目目录 |
| K01 已有同名录像时开录 | 自动换名或拒绝，旧内容保持不变 | 录制已启动，原 37 字节文件此时不存在，尚未生成新录像内容 |

D04/D06/K01 使用 App 测试宿主和实际会话；D16 在同一测试宿主调用真实文档与路径解析方法，按恢复入口的顺序验证，不等同于点菜单的 UI 端到端测试。详见 `四项测试结果摘要`（（审查 worktree）.build/debug-audit/app-audit-summary.json）、`关键原始输出`（（审查 worktree）.build/debug-audit/app-audit-observations.txt） 和 `构建测试日志`（（审查 worktree）.build/debug-audit/app-audit.log）。

现有 App 的 4 项跳过分别是：系统 Keyboard Navigation 未开启；未设置选择性空闲唤醒测量参数 `SWITCHER_IDLE_PROBE_MINUTES`；相机 TCC 权限未授予；虚拟摄像头缺少 Team ID/签名证书。原始结果见 `现有 App 测试摘要`（.build/debug-audit-20261013/app-existing-summary.json）。其中还记录了 321 条 QoS 优先级倒置运行警告，多处堆栈指向测试等待辅助代码；仅列为后续性能排查线索，没有计成 321 个产品 bug。

推流补验使用当前构建的 frameprobe 分析同一次运行的录像，没有重做 5 分钟网络场景，也没有改断言。RTMP A/V 最大偏差 0 ms、SRT 1.333 ms，均符合原阈值。详见 `离线补验明细`（（审查 worktree）.build/debug-audit/evidence/control-tools/streaming-offline-recheck.md）。两条未能完整补验的是 E7 的后续活体状态和 Adobe 鉴权网关字节检查；其余 7 条失败点后的硬性离线断言已补验。

分项完整证据（含复现源代码、命令、输出及反证复核）：

- `核心与输入审查`（（审查 worktree）.build/debug-audit/evidence/core-inputs/findings.md）
- `音频与输出审查`（（审查 worktree）.build/debug-audit/evidence/audio-outputs/findings.md）
- `控制与工具审查`（（审查 worktree）.build/debug-audit/evidence/control-tools/findings.md）

## 3. 没做的和原因

本轮是诊断与汇报，**没有修业务代码，没有推送、合并或更改公共契约**。主工作树既有的 `vmix-28-guide.zip` 未改动。审查报告和新增回归探针放在独立的 `codex/debug-audit-20261013` 工作树。

没有重新跑 8 小时长稳，也没有将已有 8 小时报告当作本轮测试结果。没有做专门安全扫描、ThreadSanitizer 并发压力、跨机 NDI/真实 Stream Deck、DeckLink 真卡、多声道设备实听，以及正式签名虚拟摄像头端到端验收。D09 必须在有 Team ID/证书的环境复验；D07 需要补真实 App 重试窗口测试；D05 需要补满队列端到端音频采样；D10 需要补实际录制音轨断言。

源码审查与有限测试不能证明已经找到所有 bug。本报告对尚未确认的并发猜测不作确定缺陷结论，低覆盖硬件路径也不标成通过。

## 4. 对契约的疑问

此次不需要用户先改契约才能开始处理崩溃、引用计数、文件错写和漏检问题。实现应首先满足现有安全失败及同源状态要求。

修复时需要明确两个产品行为并补回归：录制中的输入来源变更，是保持文件连续并跟随新来源，还是拒绝变更；遇到已存在录像文件，是自动递增文件名还是明确提示并拒绝。当前都不应静默丢数据。若后续方案涉及公开类型、JSON 字段或事件形态变化，再按仓库流程写契约提案；本轮没有代替用户作此变更。

## 5. 下一个会话需要知道的坑

建议按三批处理：先修 D01–D06 与 K01 的崩溃/数据风险；随后处理输出接线 D08/D09、音画同步 D10/D11 及文件控制边界；同时修 T01–T04，确保回归结果可信。D07 的真实时序验证和 D12 的释放断言也应进入回归，不能只依赖长稳正常负载。

每个修复先使用报告中的触发条件建立失败回归，再修改对应实现。不要为了得到绿灯放宽 V6/V7 或 A3 阈值：T01/T02 错在检测完整性与时间基准，应修分析工具。

低优先级补充：`FileInput.positionSeconds` 在非循环 EOF 后仍对时长取余并继续变化。本次实测 1 秒文件停止出帧后读数为 0.5333 秒。当前 App 没有消费者、仅测试使用该属性，故只作为 P3 库接口问题，不能描述成“当前 UI 播放进度错”。

复现证据位于审查工作树 `.build/debug-audit/evidence`，属于本机生成物。保留该目录后再清理/归档工作树；需要跨机器复现时先携带探针源码、输出和小型素材。
