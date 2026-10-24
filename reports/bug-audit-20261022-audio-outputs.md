# 2026-10-22 音频与输出代码审查（main 1f9be64）

## 1. 做了什么

只读审查 Packages/SwitcherAudio、Packages/SwitcherOutputs、CameraExtension 的核心路径（混音命令与环、ConsumerPump、输入/总线效果与延迟、host-clock 重采样、Recorder/VideoEncoder/AudioEncoder、RTMP/SRT 队列与对齐、NDI 转换/直送/缓冲所有权、ISO 分支与起停拍、磁盘监视、外部显示、虚拟摄像头客户端/扩展授权）；在独立审查树新增唯一 Audit20261022 测试，不改业务代码或契约。已对照 docs/KNOWN_ISSUES.md 及 2026-10-13 审查，旧 D01–D17/K01 与当前收口待办不重复列作新发现。

### AO01：首块音频晚于录制起点时，先把声音提前写到文件零点（P2，已实际复现）

- 位置：`Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/Recorder.swift:494–500`（首次 anchor），`:593–599`（PCM PTS 只用 audioFramesAppended）。
- 触发：Recorder 收到的第一块音频 `hostTime > RecordingStart.tickTime`，例如录制开始时来源未就绪/输入被重建，或入口积压丢弃了最早的块。首次块早于起点会裁切，但晚于起点没有补前导静音；首块无论晚多少都从文件样本 0 写入。下一个块才运行 drift 校正，因此静音被补在第一块声音之后。
- 实测：真实 Recorder、VideoToolbox 和 AVAssetWriter 录制 320×240/60fps、1 秒 MOV/LPCM。视频从 t0 开始，音频首块 256 样本为 0.6，时间戳为 t0+0.5 秒，此后为零。ffmpeg 解码首个非零样本 = **0**，应为 **24000 ± 1**；文件音轨总计 **47999** 样本，表面时长基本正常，普通时长检查会漏掉。
- 影响：开录最初一块声音超前，随后出现补静音；若仅有这一块，整个声音位置都错。默认 256 样本块对应约 5.33ms 内容，时间错位取决于首块延迟；不能把它描述为整段音轨持续提前。
- 修复方向：首次 anchor 时同样根据 originNs 和 blockStartNs 保留真实起点；补开头静音（受 stop 边界限制），或正确设置音轨初始 PTS。覆盖第一块早到、晚到、整块越界、只有一块四种情况。
- 证据：`.build/bug-audit-20261022/audio-outputs/recorder-test.log`；`audit20261022-late-first-audio.mov`；`Audit20261022RecorderTests.swift.txt`。对应包测试源码在 `Packages/SwitcherOutputs/Tests/SwitcherOutputsTests/Audit20261022RecorderTests.swift`。

### 待验证并发线索（不计入已确认 bug）

ConsumerPump.runOnce 在锁外持有 Source 并循环 `src.tap.pop`（ConsumerPump.swift:230–237），remove 在另一线程调用 mixer.removeTap（:169–176）。AudioMixer 仅等待实时生产线程应用 detach 后就 `sw_block_queue_destroy`（AudioMixer.swift:335–341），没有等待泵线程停止使用该 tap。Source/AudioBlockTap 的 Swift 强引用不会延长 C queue 内存寿命。静态上存在泵还在消费而 C queue 已释放的交错；尚未做动态并发复现，不能标为已复现崩溃。

## 2. 测试 ID、数值与通过否

| 测试 | 结果 | 说明 |
|---|---|---|
| Audit20261022RecorderTests.testAuditLateFirstAudioMustKeepTimestamp | 失败（1 个预期行为断言） | 首声音样本 0，应为 24000 ± 1；证明 AO01 |
| Audit20261022InputTapTests.testAuditInputTapMustNotFollowReusedSlot | 失败（已知问题的行为断言） | input1/2 先后复用槽0，旧 input1 tap 尾部均值 0.530327737（input2信号0.75，居中声像后），应为静音；已在 KNOWN_ISSUES D06 两边角，不计新增 |

全量现有测试由根 agent 负责，此处未重跑全量。首次输入 tap 探针缺 `.input(number:)` 参数标签导致编译失败，修正探针后才得到上述运行结果；这是探针错误，不是产品编译问题。其最终日志为 `input-tap-test-final.log`。本分项最终 2 条新增诊断用例均编译成功、各失败 1 个预期行为断言；其中只有 AO01 是新问题。

## 3. 没做的和原因

尚未跑真实多声道设备、签名虚拟摄像头端到端、跨机 NDI 接收；未把源码检查视为这些硬件路径验收。未做利用构造、未改生产代码、未提交。并发线索没有动态复现或故障注入证据，因此保留待验证，不把它作为已确认缺陷或已复现崩溃。

## 4. 对契约的疑问

AO01 可在现有时间戳契约内修复，无需改公开字段。

## 5. 下一个会话需要知道的坑

已知项不重复：ISO 输入槽位复用/删后重建、NDI 大 NV12 裁左上、普通 Cut/Auto 的旧淡变、Auto 中途开 AFV、压缩器状态残留、SRT 保留字符、未签名虚拟摄像头均在 KNOWN_ISSUES。首音频时间戳问题需检查实际音轨样本位置，单纯看音视频时长接近不能发现。

## 6. App 设置与界面追加复核

复核范围扩展到 App/Sources/Settings 与 App/Sources/UI 的设置提交、路由选择、输出跟随、音频设置、输入编辑、面板重绑、时长输入与快捷动作模型；未运行 App 宿主，宿主探针由根 agent 统一运行。

### AO02：全新纯音频输入允许启用 ISO，但永远收不到视频，停止后无录像（P2，静态完整链路）

- UI 可达：`App/Sources/Settings/OutputPagesModel.swift:174–193` 将 `.audio` 仅默认收起，勾“显示全部输入”后会出现可选的 ISO 行，`:214–217` 调用 setISO；`OutputSettingsPanel.swift:249` 和 `ISORoutes.swift:26–33` 不检查有无画面，照常建立来源为该输入的 `.record` 输出。
- 运行链：`App/Sources/Engine/InputFactory.swift:77–84` 的 AudioDeviceInput 没有 videoSlot；`InputRuntime.swift:148–155` 新建的是没人推帧的空槽。`Packages/SwitcherOutputs/Sources/ISO/ISOFrameTap.swift:58–62` 收不到帧直接返回，不会转交录制器。`Recorder.swift:389–396` 仅首视频到达才建 AVAssetWriter；`:643–647` 停止时报告“没有写入任何视频帧”。即使这一路持续有有效音频，也无法产生 ISO 文件。
- 排除备用黑帧：`InputRuntime.swift:188–189` 只有“换来源且旧槽曾推过视频”才补黑帧；新加的纯音频输入、节目加载出来的纯音频输入没有这条路径。PGM/PVW 渲染空槽为黑不等于原始输入 tee 里有黑帧。不能把“从已有视频切到纯音频”的情况与本问题混为一谈。
- 产品依据：`docs/user/输出.md:55–64` 写“每一路输入单独录一个文件”，明确允许展开纯音频并选择录制，且说明 ISO 音轨是本路声音；没有“不支持纯音频”的禁用/提示。当前 KNOWN_ISSUES 未记录此问题。
- 影响：用户为麦克风等纯音频输入勾 ISO，界面允许开始，却直到停止才发现没有录下该路音频。修复可选择为该路线提供持续黑视频帧或实现音频单独写入；若产品不支持，应在设置入口禁用并明确说明，不能保留可开始而必失败的路由。
- 证据等级：本分项为静态完整调用链；根 agent 的宿主探针如有运行结果，应在总报告中另行标注。

### AO03：录制磁盘下限可输入超过 UInt64 字节换算范围的值并使 App 崩溃（P2，独立计算实测 + App 静态调用链）

- 最小触发值：高级设置“录制磁盘下限”输入 **17592186044416 MB（2^44）**，属于合法 Swift Int，界面数值格式也能解析。`PreferencesPanel.swift:681–682`、`:258` 仅 max(0)；属性 didSet（:82）立即提交。
- 失败位置：`App/Sources/AppController.swift:575` 的 `UInt64(max(0, settings.recordMinimumFreeMB)) * 1024 * 1024` 第二次乘法溢出。新建 session 的 `App/Sources/Engine/SwitcherSession.swift:150` 有相同表达式。`AppSettings.swift:173` 的加载及 `:215` 的 CLI 仅做非负处理，不能阻止。
- 实测：独立 Swift 子进程使用 UI 同一个 `IntegerFormatStyle<Int>.number.grouping(.never)` 解析、同一个 max(0) 与乘法表达式。200 MB → 209715200 bytes、17592186044415 MB → 18446744073708503040 bytes，均 exit 0；17592186044416 MB 已解析并通过 clamp，随后 **SIGTRAP，returncode -5**。未运行真实 App 崩溃、未改真实 UserDefaults。
- 持久化链：`AppController.swift:559–561` 先 `save` 再 `applySettings`；`AppSettings.swift:258` 直接写原值到 defaults。如果该值已落盘，后续启动读出它会再次在 session 构造中崩溃。因 UserDefaults 磁盘写入是异步，本分项没有把“首次 UI 崩溃前一定落盘”视作已实测事实。设置导入也没有这一数值上限校验。
- 修复方向：所有写入/加载入口统一拒绝或钳位到业务合理上限；字节换算用 checked multiplication，至少保证 MB ≤ UInt64.max / 1048576，且应用设置前完成验证。
- 证据：`.build/bug-audit-20261022/audio-outputs/Audit20261022DiskLimit.swift`、`disk-limit-probe.json`（记录各输入、成功输出和 returncode；本机 SIGTRAP 的 stderr 为空，没有调用栈）。

### AO04：叠加输入选“（无）”无法清除当前路由（P2，静态完整链路）

- 触发：叠加设置中已给某通道选择一个输入，再在“输入”下拉选择“（无）”。`App/Sources/Settings/OverlaySettingsPanel.swift:217–218` 将 tag 0 转为 nil，调用 `setInput`；`:88–89` 发 `.overlay(channel:..., on:旧值, input:nil)`。
- 运行语义：`Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:199–204` 只有 input 非 nil 才替换路由；nil 的契约含义是“不换输入”，现有 `ReducerTests.swift:362` 明确验证这一点。UI 没有另发清除动作，也没有更新本地 input。因此“（无）”不能取消既有输入。
- 影响：显示中的叠加仍继续播出旧画面；关着的通道也仍记着旧路由，下次打开会重新播出它。该选项看似能取消输入但实际无效，不是单纯文案/外观问题。
- 修复方向：不要把 nil（保持原路由）用作清除。应提供明确的清除输入语义并由 UI 使用，或在当前契约下移除已绑定通道的虚假清除入口，同时提供清楚的关闭动作。不能直接改 nil 语义，否则现有 setOn/热键路径会失效。
- 证据等级：本分项未运行 App 宿主；静态 UI→命令→Reducer 链完整，根 agent 可用宿主验证。检索当前 KNOWN_ISSUES、旧审查与相关实现报告未发现已知条目。

追加结果不改变前述包测试计数：AO01 是本分项唯一包级动态录像复现；AO03 为独立数值子进程复现，AO02/AO04 待总报告合并根 agent 的宿主结果。ConsumerPump 并发线索仍为未动态验证，不应算已复现崩溃。

### AO02 宿主探针交付（尚未在本分项运行）

新增 `App/Tests/Audit20261022AudioISOTests.swift`，用 SyntheticAudioInput + CAudioRing 替换设备采集但保持无视频，走真实 SwitcherSession/InputRuntime/AudioRuntime/ISOFrameTap/Recorder。由真实 OutputSettingsModel 展开纯音频并勾选 ISO，等混音器 primed，录 2 秒后停。用例期望 lastResults、落盘文件及 audioFrames > 0，打印源音频计数、输入槽计数、ISO forwarded/noFrame、录制器音频丢块与停止错误。本 agent 只编写，根 agent 统一编译运行；不能把尚未运行用例列作已复现。结束在 defer 中等待独立 session.stop 完成后删除唯一临时目录，不修改宿主已有 session。


### 根审查追加的宿主运行结果（2026-10-22 23:19）

AO02 的 `Audit20261022AudioISOTests` 已由根审查编译运行：sourceFrames=149248、inputSlotPushed=0、ISO forwarded=0、noFrame=60、audioTokenNil=false、recorderAudioBlocksDropped=119；停止结果 failed("没有写入任何视频帧")、fileExists=false、lastResults=nil。启动/音频primed/ISO挂载/停机清理断言均过，唯一预期行为失败为缺少 RecordingResult。升级为真实宿主运行链复现，输入设备以无视频的合成PCM替代，不代表真实麦克风硬件验收。

AO04 的 `Audit20261022AppTests.testOverlaySelectingNoneMustClearRoute` 同轮运行：面板模型选1后再选nil，实际 input=1，XCTAssertNil失败。两项追加测试共2测试/2失败断言/0跳；结果位于 `.build/bug-audit-20261022/app/probes-extra.xcresult`、`probes-extra-summary.json`，完整宿主日志位于 `extra-diagnostics`。
