> 本文是 2026-09-28 界面对照调研的**原始记录**（调研 agent 的产出，原样保留、未逐条改正）。核对结果见同目录的"核对-*.md"，正文 docs/ui-study/01–04 以核对后的结论为准。
> 文中 `$SP` / "草稿区" 指调研时的临时目录（裁剪图、巡检截图大多没入库）；"图 NNN" 指用户本机的截图导引 figures/fig-NNN.png（不入库，见 docs/ui-study/README.md）。

# VF3 代码结论核对（R1 / R4 / R6）

- 基线：worktree `vmix-28-guide-menu-ui-c83cd1`，HEAD `c836cce`（2026-09-29）。全程只读，没改仓库、没启动 App、没用浏览器。
- 方法：逐条打开报告引用的行；"没有 / 不读"类结论用全仓 grep 反证（生产代码 = `Packages/*/Sources`、`App/Sources`、`Tools`，不含 Tests）。
- 五处 AppKit 行为用独立小探针验证：NSButton.isFlipped、同名 frameAutosaveName、"先设 autosave 名再 center()"、SwiftUI `.sheet` 挂窗、flipped 按钮上 popover 的 `.maxY`。探针在 macOS 27 / Xcode 27.0 上跑，源码在 `scratchpad/vf3probe/*.swift`。**这些是脚本探针，不是 App 实测**，表里凡是靠探针的都标了。
- SDK 头文件：`xcrun --show-sdk-path`（SDK 27.0）下的 `AudioToolbox.framework/Headers/AudioUnitParameters.h`，下文简称 SDK。R6 引用的行号与这一版一致。
- 判定：✅ 属实（只有行号或措辞要修时写"行号更正 / 措辞"）；⚠️ 部分属实；❌ 不属实；❓ 无法确认。

## 1. 缺陷 / 合规 / 文档不一致

| 报告编号 | 结论（一句话）| 判定 | 依据（文件:行号 + 一句话）| 对正式文档的修改建议 |
|---|---|---|---|---|
| R6-M09 | 录制"容器"选 .mp4 没用，运行时一律写 .mov；手册写 .mp4 可选 | ✅ 行号更正 | 下拉写进 `container`：App/Sources/Settings/OutputSettingsPanel.swift:78、432-434。全仓生产代码没有一处读 `RecordSettings.container`，只剩契约定义 MixerState.swift:434、439-443。文件名永远是 `.mov`：Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/RecordFileNaming.swift:28-29（:7 只是注释）。写文件用 `AVAssetWriter(… fileType: .mov)`：Recorder.swift:389。唯一出 .mp4 的路是停止后转封装：Remux.swift:13-24，开关在 OutputSettingsPanel.swift:455 | 手册行号是 docs/user/输出.md:**22**，不是 :23。英文 docs/user/en/outputs.md:23 同样要改。RecordFileNaming 改引 :28-29 |
| R6-G10 | 录制来源设成 PVW / 多画面时照样录 PGM，不报错 | ✅ | 只有 `source.inputNumber` 走 ISO 分支；其余一律 `consumer = rec`、音轨 `.master`：App/Sources/Engine/OutputRuntime.swift:296-303、353-359。编码器只编 `frame.program`：VTCompressionBackend.swift:173。总线校验和 reducer 都不查录制输出的来源：CommandValidator.swift:47-51、MixerReducer.swift:227-238 | 补一句：界面上设不出这种来源（录制页不给来源下拉，ISO 页只写 `.input(n)`），只会来自 API 或节目文件 |
| R6-M02 / R4-G27 | 总线和每路效果链只有状态、界面能调，引擎不读 | ✅ R4-G27 的"存疑"可以去掉 | AudioEngine.swift:464-477 applySettings 只落增益 / 静音 / 独听 / 声像 / 路由 / 延迟；:479-489 applyBuses 只落增益 / 静音。下面这些在生产代码里零调用，只出现在 Packages/SwitcherAudio/Tests（EffectChainTests / DeviceTests / RealtimeTests）：`installEffect`、`installStandardEffects`、`setEffectEnabled`、`setParametricEQ`、`setDynamics`、`setLimiter`。App/Sources/Engine/AudioRuntime.swift 全文（1-89）没有效果代码。C 混音器的效果槽只在总线上：sw_audio_rt.h:68、sw_mix.c:272、799-800 | 正式文档写成"效果链只存状态，生产代码没有一处装 AU 或设参数"。docs/user/概念.md:78 之外，这几处对外文案也要改：docs/user/en/concepts.md:83；docs/api.md:423（"enabled = false 的格旁路"）；docs/CONTRACTS.md:147；界面提示 App/Resources/zh-Hans.lproj/Localizable.strings:431（"停用的格旁路"）。docs/user/输入.md:96 已经写了"占位"，不用改 |
| R6-B4 / R6-G03 / R6-G04 | 编辑器范围超出苹果 AU：阈值 −60 对 −40，EQ ±24 对 ±20，编辑器 3 段对每总线 1 格单段 | ✅ | EQ 增益 −24…24：App/Sources/Settings/EffectChainView.swift:19，SDK :444-445 是 −20→20。阈值 −60…0：EffectChainView.swift:30，SDK :467-468 是 −40→20。最多 3 段：AudioEffectParams.swift:73、EffectChainView.swift:22-24。包里每条总线只有一格 `kAudioUnitSubType_ParametricEQ`：BusEffectChain.swift:72-78、AudioMixer.swift:21-23。AUParametricEQ 本身是单段：SDK :436-446 | 补一句：多格 EQ 是契约键表允许的（docs/CONTRACTS.md:143 写"一条链可多格 = 多段"），对不上的是契约 / 编辑器和包（一格单段）。Q 0.1–10 在 AU 的 0.1–20 以内，不算超 |
| R6-B2（R6-M01）| 总线效果 sheet 挂在主窗口上，是窗口级模态 | ✅ 探针 | `.sheet(item: $effectsBus)` 挂在主窗口右栏的 MixerView 上：App/Sources/UI/MixerPanelView.swift:257-259；面板装进主窗口：MainWindowController.swift:26、122。探针：NSHostingView 里的 SwiftUI `.sheet` 让宿主窗口 `attachedSheet` 非空、宿主不是 key 窗口，所以 MainWindow.keyDown（MainWindowController.swift:14-17）收不到快捷键 | 保留"未在 App 里目视实测"，可以加"独立探针确认是窗口 sheet" |
| R1-M05 | 偏好设置"应用格式"会换引擎、停录制推流、关设置窗，不确认 | ✅ 措辞 | 调用链：PreferencesPanel.swift:136-142 → AppController.swift:154-160 → ShowDocuments.swift:48-52（录制 / 推流的 enabled 清掉）→ replaceSession :125 → stopSession :145-151。:148 的 `panels.bind(nil)` 在 PanelCoordinator.swift:38-39 关掉偏好设置窗，:132 会再关一次。全程没有 NSAlert | 精确写法："没有确认框，只有表单下一行静态提示'改了要换一个引擎，录制 / 推流会停'"（PreferencesPanel.swift:184 → Localizable.strings:654）。建议④"页头写随节目文件保存"已经做了一半：同一行提示写着"格式存在节目文件里"。另外两处也是不确认就停录制推流："节目音频 › 应用"（:150-158 → AppController.swift:164-171）和"应用并重起引擎"（:161-165 → :174-179），建议一起写进 M05 |
| R1-M06 | 底栏录制 / 推流一按就起停，不确认，也没有开关 | ✅ | 录制 BottomBarView.swift:195-213、推流 216-224，都不确认；偏好设置里也没有相关开关 | — |
| R1-M09 | 磁盘下限 / 备用目录只有启动参数或 UserDefaults，save() 不写，手册却说偏好设置能改 | ✅ 措辞 | 启动参数 AppSettings.swift:8-9、138-139；UserDefaults 在 :115-116 读；save() 在 :144-153，不写这两个键。偏好设置窗里没有这一项（PreferencesPanel.swift:172-250） | "手册说偏好设置能改"只对**下限**成立：docs/user/输出.md:46、故障排查.md:36，英文 en/outputs.md:49、en/troubleshooting.md:36。**备用目录**手册只写了 `--record-fallback`（输出.md:47、故障排查.md:37），与实现一致。正式文档别写成两项都不一致 |
| R1-M13 | 关于面板没有 credits，也没有 NDI® 商标声明；发布文档以为已经写了 | ⚠️ | 属实的部分：AppDelegate.swift:68 调标准面板，不带 options；App/Info.plist 没有 NSHumanReadableCopyright；全仓没有 Credits.*；THIRD_PARTY/NDI/NOTICE.md:8 要求在"关于窗口 / 文档"写声明。不对的部分：docs/release/third-party.md:**14** 是一条规则（"出现 NDI 时写 NDI®，第一次出现带商标声明"），不是"已经写了"；只有 :18（"关于窗口的措辞已按 Brand Guidelines 写"）是误以为已写 | 引用改成"third-party.md:18 误称已写；:14 是规则"。补一个事实：声明原句只在包内 Licenses/NDI/NOTICE.md（scripts/release/archive.sh:141、160 拷进去），界面和用户手册里都没有（见 §4 N2） |
| R1-M15 | App 里兼容层监听地址写死 127.0.0.1，HTTP 端口写死 8088 | ✅ | AppSettings.swift:92-98 只设 enabled 和 tcpPort，host 和 httpPort 用默认值：VMixCompatConfiguration.swift:14、17（:7 = 8088）。App 别处不改它，SwitcherSession.swift:157 原样传入 | 补两处对外文档矛盾：docs/api/vmix-compat.md:16 和 docs/integrations/companion.md:9 都让用户"改成 0.0.0.0"，App 里做不到 |
| R1-M16 | App 不起 SwitcherTally 的 tally 流，手册却列为可用 | ✅ 细节 | ControlRuntime.swift:59-69 没有 tally；App target 的依赖里没有 SwitcherTally（project.yml:82-115），App 源码里也没有 `import SwitcherTally`。手册 docs/user/快捷键.md:78，英文 en/shortcuts.md:82 | headless 也不是默认就起：要带 `--tally-port N`（HeadlessRun.swift:39-40、427-436；HeadlessCLI.swift:29），端口用参数值，8766 只是包内默认（TallyServer.swift:18）。正式文档写"只有 headless 加 --tally-port 时才起" |
| R1-M20 | 音频输出只能选一台设备；耳机只在设备 ≥ 4 声道时映射到 3–4 | ✅ | 偏好设置只有一个设备下拉：PreferencesPanel.swift:193-198。AudioRuntime 不给映射，只有 SW_AUDIO_SILENT 时才改（AudioRuntime.swift:25-30）。映射是 nil 时用 `.standard`：AudioOutputDevice.swift:72。标准映射是 Master 0,1，≥ 4 声道时 HP 2,3，Bus A / B 不出：AudioOutputDevice.swift:22-26 | — |
| R1-M22 | 仓库里没有 beginActivity / IOPMAssertion；手册让用户自己跑 caffeinate | ✅ | 全仓 Swift / C / plist / yml 搜 `beginActivity`、`IOPMAssertion`、`NSAppSleepDisabled`、`LSAppNapIsDisabled`，零命中。caffeinate 在 docs/user/故障排查.md:68 | 补一点：手册给的是 `caffeinate -d -i`（英文 en/troubleshooting.md:69 相同）。W4-A 的结论是"只 -i 不够"，仓库脚本用的是 `-u -i -d -s`（docs/plan/prompts/70-W4A-长稳性能.md:12；scripts/gate4.sh:148），所以手册的参数本身就不够（§4 N5） |
| R1-M04 | 三种提交方式混用；关窗不提示未保存 | ⚠️ | 关窗不提示属实：全仓没有 windowShouldClose；PanelWindowController.swift:46 和子类 InputSettingsPanel.swift:311-314、MIDIMappingPanel.swift:293-297 只做清理。但"输出设置每改一项立即发命令"不全对：NDI 页的名字和分组要回车或点"应用"才发（OutputSettingsPanel.swift:668-679） | 改成"至少四种：输出设置大部分即时生效；NDI 名字 / 分组回车或点应用；偏好设置点应用或应用并重起引擎；快捷键 / MIDI 点保存" |
| R4-M21 | 所有输入设置窗共用一个 autosave 名，同时开几个会叠在一起 | ⚠️ 结论成立，机理写错 | 代码事实属实：InputSettingsPanel.swift:302-303 固定用 "InputSettings"；PanelWindowController.swift:31-32 先 center() 再设名。R4-B2 的机理说"一个 autosave 名只能给一个窗口用，后开的窗口只能停在居中"，与探针不符。macOS 27 探针：同名第二次 `setFrameAutosaveName` 返回 true，不排他；每个新窗口都被还原到**同一个存档位置**，没有存档时都居中。两种情况都完全重叠 | 机理改成"同名不排他，每个新开的输入设置窗都跳到同一存档位置"，注明"独立探针，未在 App 实测" |
| R4-G07 | 输入设置"音频"一节没有"跟随视频"，手册却写有 | ✅ | InputSettingsPanel.swift:243-262 只有增益 / 静音 / 独听 / 声像 / 延迟 / 四总线。afv 开关只在调音台 MixerPanelView.swift:317。手册 docs/user/输入.md:95 | 英文 docs/user/en/inputs.md:117 同样要改 |
| R4-M04 | 调音台"设置…"打开输入设置时停在"基本"或上次那一节，不是"音频" | ✅ | 调用链：MixerPanelView.swift:321 → MainWindowController.swift:151 → PanelCoordinator.swift:61-75。没有"打开哪一节"的参数，窗口已开时只 present。`section` 默认 `.general`：InputSettingsPanel.swift:19 | — |
| R4-M08 | 输入设置的"效果链"一节是音频效果 | ✅ | InputSettingsPanel.swift:208 放的是 EffectChainView，内容是 EQ / 压缩 / 限幅（EffectChainView.swift:9-46）；节名在 Localizable.strings:317 | — |

## 2. P0 / P1 条目（C 节"我们现状"一列）

| 报告编号 | 优先级 | 判定 | 核对说明（正确行号 / 修正）|
|---|---|---|---|
| R1-M01 | P1 | ⚠️ | 顶部没有工具条，属实（MainWindowController.swift:127-136）；菜单入口的行号都对（AppDelegate.swift:71、110-111、115-123）。但"没有设置入口，只能走菜单栏"不准：底栏"ISO…"直接打开输出设置窗（BottomBarView.swift:46、229 → MainWindowController.swift:149），R1 自己的 B1 表也列了这一条。改成"主窗口只有底栏 ISO… 一个设置入口，而且只落在 ISO 页；偏好设置 / 快捷键 / MIDI 只能走菜单栏" |
| R1-M02 | P1 | ✅ | 四个窗口和行号都对：PreferencesPanel.swift:172-250（9 节）、OutputSettingsPanel.swift:358-367、HotkeyEditorPanel.swift:183-223、MIDIMappingPanel.swift:183-245。换 session 时全关：PanelCoordinator.swift:29-49 |
| R1-M03 | P1 | ✅ | AppDelegate.swift:118-123 是 7 项直达；:110-111 的快捷键 / MIDI 挂在"切换"菜单 |
| R1-M04 | P1 | ⚠️ | 见 §1 |
| R1-M05 | P1 | ✅ | 见 §1。关窗的精确路径是 AppController.swift:125 → :148 → PanelCoordinator.swift:38-39；页上已有静态提示 |
| R1-M06 | P0 | ✅ | 见 §1 |
| R1-M09 | P1 | ✅ | 见 §1。手册不一致只涉及下限 |
| R1-M13 | P1 | ⚠️ | 见 §1。third-party.md:14 不是"以为已写" |
| R1-M15 | P1 | ✅ | 见 §1 |
| R1-M16 | P1 | ✅ | 见 §1。headless 要加 --tally-port |
| R1-M20 | P1 | ✅ | 见 §1 |
| R1-M22 | P1 | ✅ | 见 §1 |
| R4-M01 | P1 | ✅ | 卡片底行只有 Overlay 1–4 和静音：InputCellView.swift:76；右键菜单 :183-192；悬停提示不提右键：Localizable.strings:196 |
| R4-M02 | P1 | ✅ | MonitorView.swift:10-27 的标题条只有编号 / 名字 / 角色三个标签；⇧⌘I 在 AppDelegate.swift:102、197-203 |
| R4-M04 | P1 | ✅ | 见 §1 |
| R4-M08 | P1 | ✅ | 见 §1 |
| R4-M09 | P1 | ✅ | InputSettingsPanel.swift:186-195 只有侧栏和 Form，没有画面。建议里引的复用做法确实存在：InputCellView.swift:137-141（`display.sourceRect`） |
| R4-M12 | P1 | ✅ | 只有 `ColorPicker`：InputSettingsPanel.swift:267 |
| R6-M01 | P1 | ✅ | MixerPanelView.swift:355 是"效果 (n)"，257-259 是 sheet，363-386 是 420×520 的内容和"完成"按钮。"主窗口不能切换"见 §1 的探针 |
| R6-M02 | P0 | ✅ | 见 §1 |
| R6-M07 | P1 | ⚠️ | 底栏没有齿轮，属实（BottomBarView.swift:40-46、66）。"录制设置只能从菜单栏进"说过了：底栏"ISO…"打开的就是同一个输出设置窗，侧栏点"录制"就到。准确说法是"底栏没有直达录制页的入口" |
| R6-M09 | P1 | ✅ | 见 §1。手册行号是 :22 |
| R6-M13 | P1 | ✅ 探针 | MainWindowController.swift:295-298 用 `popUp(positioning: nil, at: (0, anchor.bounds.height), in: anchor)`。探针确认 NSButton.isFlipped == true，所以 y = bounds.height 是按钮底边，菜单往下展开 |
| R6-M14 | P1 | ✅ | 一级是显示器，子菜单里每个来源独立打勾，点一下加或删：ExternalOutputMenu.swift:52-74、104-111。按输出号建窗，不按屏去重：ExternalDisplayManager.swift:62-88 |
| R6-M15 | P1 | ⚠️ | 菜单里确实没有设置入口（ExternalOutputMenu.swift:47-91）。"外部显示设置页只能从菜单栏进"和 R6-M07 同一个问题：从底栏"ISO…"进同一个窗口，也能切到"外部显示"页。改成"没有直达外部显示页的非菜单入口" |

## 3. 抽查

| # | 报告编号 / 位置 | 报告说法 | 判定 | 依据 |
|---|---|---|---|---|
| S1 | R1-B2「Remember Window Position」；R1-G09、R1-B2「Start Maximised」里的"窗口大小位置自动记"同理 | 有：主窗口 setFrameAutosaveName（MainWindowController.swift:76），各设置窗也记（PanelWindowController.swift:32） | ⚠️ 探针 | 主窗口在 :76 设名之后，:80 又调了 `window.center()`。探针复现同一顺序：还原出来的位置被居中覆盖，存档也被改写成居中位置，**只记住了大小，位置每次都居中**。输入设置窗共用一个名字（R4-M21）。真正各记各位置的只有输出设置 / 偏好设置 / 快捷键 / MIDI 四个窗 |
| S2 | R1-B2 Language | 有（PreferencesPanel.swift:223-228，重开生效） | ✅ | apply 写 AppleLanguages：:126-130；提示在 Localizable.strings:658 |
| S3 | R1-B2 Automatically Mix Audio | 有，位置不同 | ✅ | MixerPanelView.swift:266 是 AFV 总开关，:317 是每路"跟随视频" |
| S4 | R1-B2 总是显示所有总线按钮 | 有 | ✅ | MixerPanelView.swift:311-314，按 Bus.allCases 常显 M / A / B / H |
| S5 | R1-B2 Filename Format + 示例 | 有 | ✅ | OutputSettingsPanel.swift:450-451；示例在 :148-151，用的是同一个 outputURL |
| S6 | R1-B2 Send Support Report | 有，本地导出、不上传 | ✅ | AppDelegate.swift:155、236；PreferencesPanel.swift:239；DiagnosticBundle.swift 里没有网络代码 |
| S7 | R1-B2 Check for updates on startup | 有 | ✅ 注意 | 开关只在配了 Sparkle 更新源的构建里出现（PreferencesPanel.swift:231-237）。开发 / ad-hoc 构建按钮灰掉，菜单项只弹一句说明（AppDelegate.swift:225-234） |
| S8 | R1-B2 5 个布局块 | 有，档位不同 | ✅ | OutputSettingsPanel.swift:391-396；5 个预设名在 Localizable.strings:524-528 |
| S9 | R1-B2 FTB 提醒 | 部分：FTB 按钮开着时变色（Theme.swift:21），多画面上没有 | ⚠️ 依据不全 | 按钮高亮在 TransitionPanelView.swift:122，Theme.swift:21 只是颜色常量。报告漏了一处：FTB 开着时 PGM 监视器标题显示"PGM · FTB"（MonitorView.swift:62-63）。"多画面上没有"属实：渲染器只把 PGM 压黑（CompositorPasses.swift:256-257），不写字 |
| S10 | R1-B2 输入旁的电平表 | 部分：只有纯音频输入的格子画表 | ✅ | InputStripView.swift:158-161 只给 isAudioOnly 的格子；InputCellView.swift:151-155 |
| S11 | R1-B2 控制台启用 / 即插即用 | 部分：MIDI 自动监听所有设备，不能关 | ✅ | ControlRuntime.swift:95-102 无条件 `midi.start()`；偏好设置里没有开关 |
| S12 | R1-B2 Start Fullscreen / Start External Output | 部分：固定行为，外部显示 / NDI / 虚拟摄像头随节目恢复 | ✅ | ShowDocuments.swift:48-52 只清 record / stream 的 enabled |
| S13 | R1-B2 Master Frame Rate / Output Size | 部分：7 档 / 3 档 | ✅ | PreferencesPanel.swift:25-26、174-182 |
| S14 | R4-G06 镜像 | 有 | ✅ | InputSettingsPanel.swift:236-237；Input.swift:225-228 |
| S15 | R4-B3 抠像默认值 | 默认关、键色纯绿、0.3 / 0.1 / 0.5 | ✅ | Input.swift:372-373 |
| S16 | R4-G09 点击动作 | 部分：固定点选 PVW、Shift 点直切 | ✅ | InputCellView.swift:215-223 |
| S17 | R4-B3 画面比例 | 部分：一律按比例留黑边 | ✅ | Placement.swift:45-58 |
| S18 | R4-G10 只读信号信息 | 部分 | ✅ | InputSettingsPanel.swift:157-180 只有配置摘要；Stats.swift:54-67 每路只有 fps / dup / drop / 延迟，没有分辨率 |
| S19 | R4-B1 第 2 行 | ⇧⌘I，PVW 空时不声不响开第一路 | ✅ | AppDelegate.swift:102（大写 "I" 即 ⇧⌘I）、198-203 |
| S20 | R6-G17 崩溃可恢复 | 有，形式不同 | ✅ | Recorder.swift:389-393 是 `.mov` 加 movieFragmentInterval；默认 1 s 在 MixerState.swift:439-440 |
| S21 | R6-G27 虚拟视频设备 | 有，固定送 PGM | ✅ | OutputSettingsPanel.swift:627-644、282-291 |
| S22 | R6-B6 推流 | 不看 source，固定 PGM + Master | ✅ | OutputRuntime.swift:512-541；音频 `.master` 在 :537 |
| S23 | R6-B1 推子 | −60…+12，拉到底 = −96 | ✅ | MixerPanelView.swift:69、120-123；Input.swift:305 |
| S24 | R6-M16（P2） | 没有一键开 / 关全部外部显示，只能到设置页逐路关 | ⚠️ | 外部输出菜单里有逐路的"关闭 n …"和"关闭全部外部输出"（ExternalOutputMenu.swift:75-89、113-120），R6 自己的 B6 节也写了。这两项发的是 removeOutput，会把输出删掉、设置不留。准确说法是"能一键关（等于删），不能保留设置地一键停 / 再开" |

## 4. 发现的新问题

| # | 问题 | 依据 | 建议 / 归属 |
|---|---|---|---|
| N1 | 主窗口位置不记，每次启动都居中，只记住大小 | MainWindowController.swift:76 设 autosave 名之后，:80 又 `window.center()`。探针复现同一顺序：还原的位置被覆盖，存档被改写成居中位置。PanelWindowController.swift:31-32 的顺序（先 center 再设名）是对的 | 把 center() 挪到设名之前，或只在没有存档时 center。R1 里的"记窗口位置 = 有"要改（S1）。**未在 App 实测** |
| N2 | NDI® 商标写法不合规的范围比"关于面板"大 | 界面文案里含 "NDI" 的行：zh-Hans 21 行、en 22 行，没有一处写 NDI®。docs/user（中英）也没有 NDI® 和商标声明。要求来自 THIRD_PARTY/NDI/NOTICE.md:8 和 docs/release/third-party.md:14（"出现 NDI 时写 NDI®，第一次出现带商标声明"）。原句只在包内的 Licenses/NDI/NOTICE.md | 并进 R1-M13 一起定。具体写法请用户或律师按 Brand Guidelines 定（我们没看原文） |
| N3 | 把效果链写成"已经生效"的对外说法不止手册一处 | docs/api.md:421-423；docs/CONTRACTS.md:147；界面提示 Localizable.strings:431（"停用的格旁路"）；docs/user/en/concepts.md:83 | 并进 R6-M02 的"接好之前先改文案" |
| N4 | 兼容层文档让用户把监听地址改成 0.0.0.0，App 里改不了 | docs/api/vmix-compat.md:16；docs/integrations/companion.md:9；AppSettings.swift:92-98 | 并进 R1-M15 |
| N5 | 手册给的 caffeinate 参数不够 | docs/user/故障排查.md:68 和 en/troubleshooting.md:69 写 `caffeinate -d -i`。W4-A 的结论是要加 `-u`（70-W4A-长稳性能.md:12），仓库脚本都用 `-u -i -d -s`（scripts/gate4.sh:148、scripts/perf/perf-baseline.sh:123） | 在 M22 落地之前，先把手册改成 `-u -i -d -s` |
| N6 | 底栏"叠加…"的弹出框也优先往下弹 | MainWindowController.swift:281 用 `preferredEdge: .maxY`，锚点是底栏的 NSButton（flipped）。探针：flipped 按钮上的 `.maxY` 让 popover 出在按钮**下方**，下方放不下时系统才翻上去 | 和 R6-M13 同一个根源，并进"底栏弹出统一往上"。**未在 App 实测** |
| N7 | 英文手册有同样的不一致，三份报告只引了中文 | en/outputs.md:23（.mp4）；en/outputs.md:49、en/troubleshooting.md:36（下限可在偏好设置改）；en/inputs.md:117（跟随视频）；en/shortcuts.md:82（tally）；en/concepts.md:83（总线效果） | 正式文档的"改手册"清单把中英两套都列上 |
| N8 | 改名后的残留（低） | MixerState.swift:429 注释写"App 相对 `~/Movies/Switcher`"，实际 App 默认目录是 ~/Movies/PlusMix（ShowDocuments.swift:28-32；相对目录的挂载在 OutputRuntime.swift:284-288）。THIRD_PARTY/NDI/NOTICE.md:7 写 `Switcher.app/...`，发布包叫 PlusMix.app（third-party.md:3） | 契约注释由契约会话改；NOTICE 由 W4-B 改 |

## 5. 统计

| 节 | 条数 | ✅ | ⚠️ | ❌ | ❓ |
|---|---|---|---|---|---|
| 1 缺陷 / 合规 / 文档不一致 | 18 | 15 | 3（R1-M13、R1-M04、R4-M21） | 0 | 0 |
| 2 P0 / P1 | 25 | 20 | 5（R1-M01、R1-M04、R1-M13、R6-M07、R6-M15） | 0 | 0 |
| 3 抽查 | 24 | 21 | 3（S1 记窗口位置、S9 FTB 提醒、S24 R6-M16） | 0 | 0 |
| **去重合计**（§2 有 14 条与 §1 重复） | **53** | **44** | **9** | **0** | **0** |

- 属实但要改行号或措辞的：
  - R6-M09：手册在 输出.md:22；RecordFileNaming 引 :28-29。
  - R1-M05：页上已有静态提示；"节目音频 › 应用"和"应用并重起引擎"同样不确认。
  - R1-M09：手册只对下限说了偏好设置能改。
  - R1-M16：headless 要带 `--tally-port`。
  - R6-G10：补一句"界面上设不出这种来源"。
  - R4-G27："存疑"可以去掉。
- 靠独立探针的判定（不是 App 实测）：R6-B2 / R6-M01、R6-M13、R4-M21、S1、N1、N6。
