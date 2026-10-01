# W5-B 直播安全与界面说谎报告（prompt 87，分支 w5-app-safety）

分支：桌面端开的 worktree 分支 `claude/w5-app-safety-1b5d00`；prompt 里叫 `w5-app-safety`，本地另打同名引用（`git branch -f w5-app-safety HEAD`）给
`check-ownership.sh` 用（同 W3-E3 / W3-E4 的做法）。基于 main `25af61f`（86 W5-A 还没合入，所以从 main 开；两份 `Localizable.strings` 的冲突按 prompt 留给 G6）。
机器：MacBook Pro M5 Max，macOS 27.0，Xcode 27.0，接电源；本机装了 mediamtx / ffprobe（推流端到端那条真跑）。只动 App/（`make lint BRANCH=w5-app-safety` 全绿）。

提交（`git log 25af61f..HEAD`）：`b4bdf09` 红测试（新 API 只给签名、行为照旧）→ `87e80a8` 实现 → `e0f38a4` 确认框点下就回调（全量查出来的，见 §5 第 1 条）
→ `02aef60` 确认框先还原窗口 / 叫到前台 → 本报告。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 0 确认框公共件 | `UI/Confirmation.swift`（新） | `ConfirmationCenter`：真弹 NSAlert sheet；按钮带"做 / 另一种做法 / 取消"三种语义，破坏性按钮画红字；停止 / 换节目 / 删除这类确认**回车不落在"做"上**（误按回车不会停），Esc = 取消；同一窗口上一问没答完，第二问直接当取消（菜单栏不被 sheet 挡住，问的过程中再按 ⌘N 不会叠出第二个）。只有界面入口用它：快捷键 / MIDI / API 直接发命令，一律不问。测试从 `pending(_:)` 拿到正在问的那个、`respond(_:)` 用按钮的 performClick 回答（与用户点同一条路）。按钮指到自己的 target：**点下那一刻就回调**，120 ms 后再收 sheet（收起动画会占住主线程，§5 第 1 条）；窗口最小化 / App 在后台时先还原、叫到前台（不然退出那一问没人看得见） |
| 1 停止前确认（E11 / X01） | `UI/BottomBarView.swift`、`AppSettings.swift`、`Settings/PreferencesPanel.swift`、`AppController.swift` | 底栏录制 / 推流主体：开始不问；停之前弹"确定停止录制（n 路）？/ 确定停止推流（m 路）？"，正文逐路列"名字：状态"；确认时按当时的快照停（问的过程中 API 停了几路也不会多发）。设置：`AppSettings.confirmBeforeStop`（UserDefaults 键 `confirmBeforeStop`，默认开），偏好设置新一节"操作确认"里的开关，点"应用"生效 |
| 2 换节目 / 换格式前确认，未保存先问（A3 / F5 / X03 / X04，Q67 (a)） | `AppController.swift`、`AppDelegate.swift`、`UI/MainWindowController.swift`、`Settings/PreferencesPanel.swift`、`UI/PanelCoordinator.swift`、`Show/ShowDocuments.swift` | 入口：节目 › 新建（⌘N）/ 打开…（先选文件、选完才问）/ 打开最近 / Finder 双击 / 退出（菜单、⌘Q、**关主窗口**——原来关主窗口 = 直接退出、录制推流一起停）走 `requestNewShow` / `requestOpenShow` / `prepareToQuit`；偏好设置的节目格式"应用"、节目音频"应用"、"应用并重起引擎"走 `confirmEngineRestart`（sheet 挂在偏好设置窗上）。顺序：录制 / 推流在跑 → 先问"新建节目会停止 1 路录制、1 路推流"（打开时写文件名、退出时写"退出会停止…"、换引擎写"换节目格式要重起引擎，会停止…"）；节目有未保存的改动 → 再问"要保存对'名字'的改动吗？"（有文件：保存 / 取消 / 不保存，回车 = 保存；没存过：保存… 弹存储面板，面板取消 = 整个操作取消）。任何一步取消都什么都不动；全部过了才停输出、换 session。窗口用 `isDocumentEdited` 标（口径见下）。**退出不再静默写回已打开的文件**，LastSession 照存（测试宿主写到临时目录，测试宿主也走退出的整条路）。换引擎后**偏好设置窗不关**，格式 / 节目音频几项按新 session 重读（`PreferencesModel.rebind`），状态写"已重起引擎"；其余设置类窗口照旧关（它们的模型绑的是旧 session）。"应用并重起引擎"取消 = 既不应用也不重起 |
| 3 失败的推流路与按钮状态（X02 / L4 / L13 / K11 / X11 / X37 / X38） | `UI/OutputButtonSummary.swift`（新）、`UI/BottomBarView.swift`、`Engine/OutputRuntime.swift`、`Engine/SwitcherSession.swift`、`UI/MainWindowController.swift` | **汇总**：两个主体按钮都按最差的那一路——全在推"● 推流中"（一个目的地）/"● 推流中 n/m"（n = 在推的路数，m = 目的地总数）；有路在重连或首连已失败过 → 橙"推流 · k 路异常"；有路起不来 → 深红；只有一路开着时直接写它的状态（"推流 · 重连中（第 2 次）"）。提示逐路列"名字：状态"，起不来的写原因（"推流 3：起不来 — 不认这种地址：foo://（只支持 rtmp:// rtmps:// srt://）"）。录制同一套（"● 录制中（3 路）"不变，"录制 · 1 路异常"、"录制 · 封口中"）。**state 全走本地化表**（`output.state.stream.*` / `output.state.record.*`），"推流 · idle"这类原样英文不再出现。**首次连接叫"连接中"**（第 1 次之后写"连接中（第 n 次）"），**连上过之后才叫"重连中（第 n 次）"**，n 是真实尝试次数（StreamOutput 的 connecting / backoff 里的 attempt；Stats 里没有，见 §4）。**主体只作用于在跑的路**：都没开 → 全起；开着的里有起不来的 → 只重试那几路（`SwitcherSession.retryFailedOutputs` → `OutputRuntime.retry`），正常的路不停、不问；否则 → 停全部（先确认）。**起不来的原因**写成人话（`stream.error.*`：没有地址 / 不认的 scheme / 地址格式不对 / 没有服务器），记在运行表；**enabled 仍为真时设置变了（地址改对）reconcile 自动重试**（录制同理：目录改了自动重试）；起不来的那一路 Stats.encoder 报 **failed**（原来报 idle，契约 §7 的取值表里本来就有 failed）。**"推流 n 开始"改成连上才提示**：起的时候提示"推流 n 连接中…"，Stats 第一次报 publishing 时提示"推流 n 已开始"。推流页"重连上限"改叫"**重试间隔最长 n s（一直重试）**" |
| 4 在推的路锁住（L12 / X05 / X24），录制页在录提示（K6） | `Settings/OutputSettingsPanel.swift` | 推流页每个目的地抽成 `StreamDestinationSection`：在推的那一段（目标开着、没起不来）地址 / 密钥 / 重试间隔 / 编码 / 分辨率 / 码率 / 关键帧 / 音频码率禁用，写"正在推流：地址、密钥和编码停止后可改。"，"删除目的地"灰掉；模型层也拦（`updateOutput` / `removeOutput` 对在推的路不发命令）。**起不来的那一段不锁**（要能改对地址），写"起不来：原因"+"改好地址 / 密钥会自动重试"，给"重试"与"停用这一路"（停用 = stopStream，起不来的路不再算在跑，底栏主体又能停其余的）。每段顶上一行"状态"（与底栏同一套文字）。地址 / 密钥改成草稿，**回车或离开输入框才提交**（原来每按一个键发一条 setOutputSettings）。录制页：录着的时候页顶橙字"正在录制：改动从下一次开录起生效。" |
| 5 删除输入确认（D9 / X13） | `UI/InputRemoval.swift`（新）、`UI/InputCellView.swift`、`UI/InputStripView.swift` | `InputRemovalImpact.impacts(of:in:)`：在 PGM / PVW / 开着的叠加通道 / Stinger / 正在录它的 ISO 上时先确认，正文逐条写后果（"它在 PGM 上：删掉后 PGM 会变成黑场"……，末尾"删除不能撤销。"）；其余直接删。右键菜单"删除输入 n"前加分隔线。关着的叠加通道里放着它不算（画面上没有它） |
| 6 效果链标"尚未生效"（J1 / X06 / X07 / H2） | `Engine/AudioEffectsSupport.swift`（新）、`UI/MixerPanelView.swift`、`Settings/InputSettingsPanel.swift`、两份 `Localizable.strings` | 常量表 `busEffectsApplied` / `inputEffectsApplied` 现在都是 false（88 / 102 各翻一个）。false 时：总线条按钮只写"效果"（不亮计数，灰字，悬停写原因）；总线效果 sheet 与输入设置效果页顶部橙字"效果尚未作用到声音（本版本）"+ 一句说明。输入设置"效果链"改名"音频效果"（英文 Audio effects）。`mixer.busEffectsHint` 去掉"停用的格旁路"，改成"这条总线的效果链（setBusEffects 整体替换，随节目文件保存）；链的顺序 = 处理顺序。" |
| 7 "其他命令"止血（N4 / X10 / X41） | `Settings/CommandText.swift`（新）、`Settings/HotkeyEditorPanel.swift`、`Settings/MIDIMappingPanel.swift` | 动作下拉只在这一行本来就是其他命令（手里有一条命令）时才列"其他命令"；`Row.action` 改成可选——"其他命令"没有命令就是 nil，**不再兜底成 Cut**，保存时报"第 n 行选了'其他命令'但没有命令：点'编辑 JSON…'填一条"、不写文件。显示改用 `CommandCatalog` 的说明 + 参数摘要（"选下一次转场的类型和时长……（durationTicks: 30, type: wipe）"；英文界面目录没有译文，用命令名）。每行一个"编辑 JSON…"：多行框（`CommandJSONSheet`，快捷键 / MIDI 共用），顶层键是命令名（与 HTTP API 的 command 同一个写法），"应用"时校验，解不出来显示原因、这一行不动；认得出的命令回到对应动作（`{"setPreview":{"input":4}}` → "PVW 选输入 4"）。MIDI 映射面板同样（原来这一类行的下拉显示空白） |
| 8 录制"文件格式"（K5 / X14，Q12 (a)） | `Settings/OutputSettingsPanel.swift` | "容器"下拉与"停止后转 MP4"开关合成一个单选：".mov（边录边存片段，崩溃可恢复）/ .mov，停止后转 .mp4"，只写 `remuxToMP4`，**不写 container**（照读：老节目文件里 container = .mp4 的原样留着，页上说一句"节目文件里的'容器 .mp4'不起作用"） |
| 9 窗口标题（A4 / X42） | `UI/MainWindowController.swift`、`AppController.swift` | `MainWindowController.windowTitle(showName:)` 一处出标题，保存 / 另存之后也是"PlusMix 0.1.0 — 名字"（原来 `write()` 写成代码名"Switcher 0.1.0"）；未保存用 `isDocumentEdited` 标（关闭按钮上的点），不写进标题文字 |
| 10 添加面板满了（X22） | `UI/AddInputSheet.swift` | 没有空号时"添加"置灰、编号下拉禁用，底下红字"本节目的输入已满（16 路）"；确定不加、面板不关 |

### 未保存判定（isDocumentEdited）的口径

比的是"节目内容"：`AppController.documentContent(_:)` = Show 去掉现场操作与界面摆放之后剩下的部分。

| 不算改动（被规整掉） | 算改动 |
|---|---|
| 界面布局 `Show.layout`（窗口位置、调音台 / 多画面开关） | 输入表：加 / 删 / 改名 / 换来源，每路设置（裁切、变换、推子、静音、独听、声像、路由、延迟、跟随视频、效果、抠像） |
| 节目名（跟文件名走） | 输出表：加 / 删 / 改名 / 改设置，NDI / 外部显示 / 虚拟摄像头 / 多画面的开关（打开节目时会照它们起） |
| 录制 / 推流的 enabled（运行目标；打开文件时本来就清掉） | 转场类型 / 时长 / Wipe / Stinger 参数，FTB 时长 |
| PGM / PVW 选哪路；转场进度 / 来源（auto / T-bar）/ 起始拍 | 叠加通道的位置 / 动画 / 边框 / 锚点 / PVW 预览 |
| FTB 开没开、进度、起始拍 | 四条总线的增益 / 静音 / 效果，AFV，监听方式 |
| 叠加通道开没开、放的哪路输入、动画进度 | 节目格式，节目音频的对齐延迟 / 监听点 |

基准什么时候定：新建、打开文件、启动时打开上次的文件 → 新 session 起好时的内容；启动时从 LastSession 恢复的、没存成文件的节目 → 和空节目比（有内容就算未保存）；
节目格式 / 节目音频 / 重起引擎（同一个节目换引擎）→ 沿用原来的（换了的格式本身就是一处改动）；保存 / 另存写成了 → 刚存的内容。
推子算改动是有意的：节目文件常被当模板反复用（Q67 的理由），宁可多问一句也不丢；嫌问得多，口径就在 `documentContent` 一处改。

### X01–X05 修前 / 修后的复现对照

| 编号 | 修前（main 25af61f） | 修后（本分支） | 钉住的用例 |
|---|---|---|---|
| X01 | 录制中再点底栏"录制"→ PGM 与全部 ISO 立即停，不问；推流同理 | 弹"确定停止录制（n 路）？"，取消照录，点"停止录制"才停；回车不落在"停止"上；偏好设置 › 操作确认可关；快捷键 / MIDI / API 停不问 | `testUI_stopRecordAsksConfirmation`、`testHotkeys_stopRecordNeverAsks` |
| X02 | 两个目的地、第二个地址不认 → 点"推流"→ 第一路在推、第二路起不来，按钮只看第一路（或"推流 · idle"）；改对地址没反应；再点"推流"两路一起停 | 按钮"推流 · 1 路异常"（深红），提示写原因与"点一下：重试起不来的路"；点主体只重试第二路，第一路的推流对象不变、不问；推流页把地址改对 → 自动重试、起来；都在跑了再点主体才是停（先确认）。Stats 里起不来的那一路报 failed | `testUI_streamRetryDoesNotStopHealthyRoutes`、`testUI_streamButtonAggregatesWorstState`、`testUI_streamStateTextLocalized` |
| X03 | 录制推流中按 ⌘N / 打开…→ 直接停；没保存的改动直接丢 | 先问"新建节目会停止 1 路录制、1 路推流"（打开写文件名），再问保存 / 不保存 / 取消；任何一步取消都不动；没在跑、没改动直接换 | `testUI_newShowWhileLiveAsksConfirmation` |
| X04 | 推流中 ⌘, → 改帧率 → 应用格式 → 推流停、偏好设置窗关，没有确认；"应用并重起引擎"连提示都没有 | 三个按钮都先问（sheet 挂在偏好设置窗上），取消 = 不换；换完窗口不关、格式几项按新 session 重读 | `testUI_applyFormatKeepsPreferencesWindowOpen` |
| X05 | 推流中在推流页点正在推的那一段"删除目的地"→ 断流 | 在推的那一段地址 / 密钥 / 编码禁用、"删除目的地"灰掉、写"停止后可改"；模型层也拦；停了才能删；起不来的那一段不锁 | `testUI_streamingDestinationLockedWhileLive` |
| X30（顺带） | 打开 a.switcher.json → 临时改几路 → 退出 → a 被静默改写 | 退出先问保存；"不保存"= 原文件字节不变，LastSession 照存；"保存"才写回 | `testShow_quitDoesNotOverwriteOpenedFileSilently` |

## 2. 每个测试：数值 / 阈值 / 通过否

（功能用例，判据是行为与文案逐字相等；没有数值阈值。红灯轮见 2.2，全量见 2.3。时间是第二遍全量里的。）

### 2.1 本会话的用例（App/Tests/LiveSafetyTests.swift、HonestUITests.swift、ShortcutAndShowTests.swift）

| 交付 | 测试 | 数值 / 看到的 | 判据 | 通过 |
|---|---|---|---|---|
| 1 | `testUI_stopRecordAsksConfirmation` | 开始录制 / 推流不问（pending = nil）；停：sheet 挂在主窗口上，标题"确定停止录制（1 路）？"、停止按钮是破坏性的、回车不落在它上面；确认前快照 enabled 仍为真；取消 = 照录；确定 = 点下那一刻 commandsSent + 1、随后封口；推流"确定停止推流（1 路）？"同口径；偏好设置开关默认开、关掉后写进 UserDefaults、一按就停不问；`askedCount[.stopRecord]` 恰 +2 | 逐项相等 | ✅ 4.1 s |
| 1 | `testHotkeys_stopRecordNeverAsks`（守门） | 快捷键 r（toggleRecord 1）开 / 停、`POST /api/v1/command {"stopRecord":{"output":1}}`、MIDI Note 60（toggleRecord 1，虚拟源）开 / 停：都直接生效，`askedCount[.stopRecord]` 不变 | 一次都不问 | ✅ 0.9 s |
| 2 | `testUI_newShowWhileLiveAsksConfirmation` | 加输入 / 推流目的地后 `isDocumentEdited` 与 `window.isDocumentEdited` 都为真；录制 + 推流在跑时 `requestNewShow`：标题"新建节目会停止 1 路录制、1 路推流"，取消 = session 不换、录制推流不停；确定 → 保存那一问（"要保存对'未命名'的改动吗？"，按钮 保存… / 取消 / 不保存，回车 = 保存），取消 = 仍不动；确定 + 不保存 → 新 session、0 路输入、旧录制已封口、edited 归零；没在跑没改动 → 直接新建，两种问的计数都不变；`requestOpenShow`：标题"打开'另一个.switcher.json'会停止 1 路录制" | 逐项相等 | ✅ 5.4 s |
| 2 | `testShow_quitDoesNotOverwriteOpenedFileSilently` | 存成"模板.switcher.json"后 edited = false；加一路 + 改名后 edited = true；`prepareToQuit`：标题"要保存对'模板'的改动吗？"、按钮 保存 / 取消 / 不保存；取消 → false；不保存 → true，`shutdown` 之后**原文件字节不变**，LastSession（测试宿主在临时目录）有 2 路、改过的名字；重新打开 → 加一路 → 退出选"保存" → 文件里输入是 [1, 5]、edited 归零；没改动退出不问 | 字节相等；计数不变 | ✅ 1.9 s |
| 2 | `testUI_applyFormatKeepsPreferencesWindowOpen` | 录制在跑：节目格式"应用"→ 标题"换节目格式要重起引擎，会停止 1 路录制"，sheet 挂在偏好设置窗上；取消 = 不换不停；确定 → 新 session 720p60，**偏好设置窗还是同一个、还开着**，formatWidth = 1280，状态"已重起引擎"，再点不换；节目音频"应用"/"应用并重起引擎"标题"改节目音频要重起引擎…"/"重起引擎会停止 1 路录制"，取消不动；不在跑时"应用并重起引擎"不问、直接换、窗口照开 | 逐项相等 | ✅ 4.0 s |
| 3 | `testUI_streamButtonAggregatesWorstState`（纯函数） | 没开"推流"；一个目的地"● 推流中"；三个两个在推"● 推流中 2/3"、全推"3/3"；首连第 1 次不算异常"● 推流中 1/2"；一路在重连"推流 · 1 路异常"橙，提示含"推流 3：重连中（第 2 次）"；一路起不来"推流 · 1 路异常"深红，提示含原因与"点一下：重试起不来的路"；重连 + 起不来"2 路异常"红；单路"推流 · 连接中 / 连接中（第 3 次）/ 重连中（第 1 次）/ 重连中（第 3 次）/ 起不来"；录制"● 录制中（3 路）"、"录制 · 1 路异常"带原因 | 逐字相等、颜色 = Theme.outputWarning / outputError | ✅ |
| 3 | `testUI_streamRetryDoesNotStopHealthyRoutes` | 2 号连本机关着的端口（一直连接中 / 退避）、3 号 `foo://`：起不来原因"推流 3 起不来：不认这种地址：foo://（只支持 rtmp:// rtmps:// srt://）"（不再是 `unsupportedScheme("foo")`）；Stats.encoder[3].state = failed；按钮"…异常"、severity error、提示含原因；提示里有"推流 2 连接中…"、没有"已开始"；点主体：不问、2 号的推流对象 `===` 原来那个、两路 enabled 仍为真、3 号又报了一次原因；setOutputSettings 把 3 号地址改对 → 自动重试、起来、原因清空、2 号仍是原对象；都在跑了点主体 → "确定停止推流（2 路）？"→ 全停 | 逐项相等 | ✅ 2.5 s |
| 3 | `testUI_streamStateTextLocalized` | 推流 7 个 state × 单路 / 多路、录制 5 个 state：按钮与提示里没有原样的英文 state 词（整词）、没有缺键；"录制 · 封口中"、"推流 · 正在停"；"重试间隔最长 30 s（一直重试）"；"推流 2 连接中…"/"推流 2 已开始"；英文界面同样、按钮里没有中文，"Stream · Connecting" | 逐字相等 | ✅ |
| 3（端到端） | `StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous`（加了 X37 断言、停先确认） | 连上后提示顺序 ["推流 2 连接中…", "推流 2 已开始"]；停："确定停止推流（1 路）？"；10 s 645 帧、Stats publishing、frameprobe 661 帧丢 0 重复 0 | 原判据不变 | ✅ 17.2 s |
| 4 | `testUI_streamingDestinationLockedWhileLive` | 没在推：能改，地址 / 密钥经 `commitStreamAddress` 一次提交；在推：锁住、说明"正在推流：地址、密钥和编码停止后可改。"，改地址 / 改码率 / 删除**一条命令都没发**、没断流；停了能删；起不来的路（空地址）不锁、状态"起不来：推流 n 没有地址"，"停用这一路"后 enabled = false、原因清空；录着时录制页"正在录制：改动从下一次开录起生效。"，停了消失 | 发出命令 = [] | ✅ 1.1 s |
| 5 | `testUI_deleteInputOnProgramAsksConfirmation` | 右键菜单 [设置…, 重命名…, ─, 删除输入 1]；哪儿都没用的 3 号直接删；PGM 上的 1 号："删除输入 1 · 合成 1？"、正文含"PGM 会变成黑场"，取消不删，确定后删、PGM = 0；口径表：PGM / PVW / 开着的叠加 3 / Stinger / 正在录的 ISO 各对上，关着的叠加通道里放着的不算，PGM + PVW 两条都列 | 逐项相等 | ✅ 1.5 s |
| 6 | `testUI_effectChainMarkedNotEffectiveUntilSupported` | 两个常量都是 false；总线按钮"效果"（接上之后"效果 (2)"）；加了一格限幅也不亮计数；总线 sheet 与输入设置效果页横幅"效果尚未作用到声音（本版本）"；分组名"音频效果" / "Audio effects"；两种语言的 `mixer.busEffectsHint` 都没有"旁路 / bypass" | 逐字相等 | ✅ |
| 7 | `testHotkeys_otherCommandNotRewrittenToCut` | 其他命令那一行列"其他命令"，Cut 行、新加的行不列；说明含 CommandCatalog 的 setTransition 说明与"wipe""30"，不含 `setTransition(type:`；改走再改回命令还在；没有命令的"其他命令"：action = nil、保存失败、提示"第 3 行选了'其他命令'但没有命令：点'编辑 JSON…'填一条"、不写文件；JSON：`{"nope":{}}` 与"不是 JSON"不改这一行，`{"setPreview":{"input":4}}` 回到"PVW 选输入"，`{"setAFV":{"on":true}}` 成为其他命令；存回去 g = setTransition、h = Cut、j = setAFV；MIDI 面板同一套（下拉列"其他命令"、同一句说明、JSON 写进去） | 逐项相等 | ✅ |
| 8 | `testPanels_recordFormatChoiceWritesRemuxOnly` | 两个选项".mov（边录边存片段，崩溃可恢复）/ .mov，停止后转 .mp4"；切换只改 remuxToMP4、container 保持 .mov；老节目 container = .mp4：格式仍 .mov、页上说一句不起作用，再切到"转 .mp4"后 container 仍是 .mp4、发出的每条 setOutputSettings 里都是 .mp4 | 逐项相等 | ✅ 0.4 s |
| 9 | `testUI_windowTitleUsesProductNameAfterSave` | 新建"PlusMix 0.1.0 — 未命名"；加输入后 isDocumentEdited；存成"周日礼拜"→ 标题"PlusMix 0.1.0 — 周日礼拜"、不含 Switcher、edited 归零；setPreview + Cut 不算改动；改名算；⌘S 写回、标题不变、edited 归零、文件里是新名字 | 逐字相等 | ✅ 0.7 s |
| 10 | `ShortcutAndShowTests.testUI_addInputFullShowDisablesAdd` | 16 路占满：isFull、canAdd = false、"本节目的输入已满（16 路）"；sheet 确定不加；空出一个号照常（默认 16）；英文"This show already has the maximum of 16 inputs" | 逐项相等 | ✅ |

改了的旧用例（行为变了，用户点的路径也跟着变）：`RecordingTests` / `UISmokeTests` / `ISOAppTests` / `StreamWiringTests` 里点底栏停止之后都要在确认框上点"停止"（`AppTest.waitForConfirmation` + `AppTest.answer(.confirm)`）；
`RecordingTests` 的"按钮间隔"改量到点"停止录制"那一刻（stopRecord 在那时才发），判据（起止拍差 = 按钮间隔 ± 1 帧）不变：第二遍全量 318 拍 vs 5.287 s × 60 = 317.2 拍。`AppTest.freshSession` 先收掉上一条没答完的确认框。

### 2.2 红灯轮（先写用例、新 API 只给签名、行为照旧）

`b4bdf09` 上只跑新用例：**15 条里 14 条红**，红的位置就是各自要验的点（停录制没弹确认、"推流 3 起不来：unsupportedScheme(\"foo\")"、菜单项没有分隔线、换格式没弹确认、`isDocumentEdited` 恒 false、文件格式标题是 rawValue……）。
`testHotkeys_stopRecordNeverAsks` 本来就绿：它守的是"快捷键 / MIDI / API 停录制不弹"，加了确认之后也必须保持绿（守门用例）。

### 2.3 全量（`make test-app XCB_FLAGS=`，去掉 -quiet 好逐条计数；xcresulttool 核过）

| 轮次 | 结果 | 说明 |
|---|---|---|
| 第一遍（`87e80a8`） | 114 条：108 过、4 跳、**2 红** | ① `RecordingTests` 起止拍差 333 vs 按钮间隔 317.4 拍——查出确认框的回调要等 sheet 收起动画、而动画占住主线程（§5 第 1 条），`e0f38a4` 修掉；② `DisplayLedgerAppTests` 多画面窗口 1 s 内 0 帧（显示类，窗口被别的会话盖住时会红），单独复跑过；跳过的 4 条里 ISO A4 / 推流端到端是这个 worktree 还没编 release frameprobe（BLOCKED-工具，§5 第 3 条），编好后补跑都过 |
| 第二遍（`e0f38a4` + 窗口还原那一行，空机器） | **114 条：112 过、2 跳、0 失败**（xcresulttool：totalTestCount 114 / passed 112 / failed 0 / skipped 2），238 s | 跳过的两条：内置摄像头 BLOCKED-权限（从 Claude 的 Bash 起 xcodebuild 系统直接拒）、虚拟摄像头出画 BLOCKED-签名（ad-hoc 签名装不了系统扩展）——与 main 上一样 |

ISO A4 在第一遍补跑时红过一次（两路 ISO 各跳 84 帧，当时另一个会话在编译），空机器上连跑三次 + 第二遍全量都是三路 517–519 帧、跳帧 0，判为负载，不是本会话引入的。
`make lint BRANCH=w5-app-safety`：禁词 / 版本号 / Package.swift / 依赖方向 / 归属（33 个改动文件都在 App/ 与本报告）/ check-links / check-rt-symbols 全绿。

## 3. 没做的和原因

- **底栏三段式、▴ 单路起停、推流状态面板**：prompt 明说归 92 / 101，本会话只让主体不误伤。所以推流有一路**一直**起不来时，点主体永远是"重试它"、停不了正常的那几路——出路在推流页那一段："停用这一路"或把地址改对（会自动重试）；底栏提示里写了"点一下 = 重试起不来的路"。
- **录制主体没做"有起不来的路就只重试"**：prompt 第 3 条只对推流这么要求；录制若也这样，起不来的 ISO 路（比如分支用完）会让主体再也停不了 PGM 录制，而录制页没有逐路停用的入口。现在录制主体 = 停全部开着的（先确认，确认框里逐路写状态，起不来的那一路也写着），起不来的录制路改了设置（目录）会自动重试、停了再开也会重试。
- **输入设置"音频效果"没挪位置、没另开音频设置窗**：H2 只要求改名；挪到"音频"后面 / 并进"音频"是 97（W5-K 面板改版）的事。
- **效果链接线**（88 总线、102 每路）：本会话只标"尚未生效"；接上时把 `AudioEffectsSupport` 里对应的常量翻成 true，横幅和灰掉的计数自动消失。
- **契约里 container 标废弃**：界面已不写（照读），契约那半在提案 023（P5，prompt 99）。
- **文档**：手册 / API 文档 / CONTRACTS 里按 0.1.0 行为写的那几句不在本会话目录，列在 §5 第 9 条给 103 / G6。
- **删除输入的撤销**（01a N34）：没做，删之前问一声是本会话的止血。
- 未保存判定**不**看窗口布局、也不看推流页里还没提交（没按回车、没离开输入框）的地址草稿——草稿不在节目状态里。

## 4. 对契约的疑问

本会话没有改契约，也没有需要停下来的提案；下面几条给 P5（prompt 99）与 88 参考：

1. **Stats.encoder 没有"连接尝试次数"**：底栏"连接中 / 重连中（第 n 次）"的 n 读 StreamOutput 状态机里的 attempt（App 运行表 `OutputRuntime.streamConnectAttempt`），API / stats.jsonl 看不到同一个数；"首连 / 重连"的区分用的是 Stats 里的 frames > 0（连上过）。按铁律 4 这个数应该进 Stats：建议 022 顺手加（`StreamCounters.connectAttempts` 已有累计值；按钮要的是"这一轮重连的第几次"，可以叫 `attempt`，0 = 没在连）。不加不影响功能。
2. **起不来的录制 / 推流路 Stats.encoder 报 failed**（原来报 idle）：取值在测试标准 §7 / `EncoderEntry.state` 注释的列表里，不是契约改动；但 API 客户端会看到这个变化。原因文字现在只在 App 运行表里，022 的 `last_error` 落地后可以由 App 把同一句填进去，API 也就看得到原因了。
3. **RecordSettings.container**：界面不再写，照读；契约"标废弃（照读不写）"在提案 023。
4. **"enabled = false 的格旁路"**：`CommandCatalog` 里 setBusEffects 的说明（docs/api.md 由它生成）与 docs/CONTRACTS.md:147 还是这句，效果没接之前不成立；不在本会话目录，88 接总线时一起看（接上之后这句就对了）。

## 5. 下一个会话需要知道的坑

1. **AppKit sheet 的收起动画（`endSheet`）把主线程整个占住 ~0.27 s**：期间 Timer（含 common 模式的）、主队列、主线程上的 Task 一概不跑（探针：endSheet 前后 Timer 0 次、MainActor Task 在它返回后才跑；打开动画在测试里等 `attachedSheet` 也要 ~0.29 s）。NSAlert 自己的 completion 在动画之后才回来——"停止录制"点下去晚 15 帧才停（第一遍全量 `RecordingTests` 红的原因）。`ConfirmationCenter` 现在把按钮指到自己的 target：点下就回调，`dismissDelay`（120 ms）后再收 sheet，留给命令进总线、下一次快照分发让运行表按生效拍定起止拍。以后谁在 sheet 回调里做时间敏感的事（录制起止），记住这一条。
2. **测试宿主的 UserDefaults suite（`com.plusmix.switcher.tests`）和临时目录 `$TMPDIR/switcher-tests/` 是所有 worktree 的测试宿主共用的**：几个会话同时跑 App 测试会互相写（confirmBeforeStop、apiListen、LastSession、录制目录），全量要在空机器上跑（先 `pgrep -fl "xcodebuild .*test"`，本会话跑之前另外两个会话正在跑）。别的会话在编译时 ISO A4 会跳帧（本会话见过一次 84 帧）。
3. **新 worktree 先 `swift build -c release --package-path Tools/frameprobe`**，不然 ISO A4 与推流端到端两条直接 BLOCKED-工具 跳过，"0 失败"看着像全过了。
4. **关主窗口 = 退出那一问**（`MainWindowController.windowShouldClose` → `NSApp.terminate`，窗口先不关）。测试里别对主窗口 `performClose`：测试宿主会真的走退出、答完就退进程。
5. **`ConfirmationCenter` 同一个窗口一次只问一个**，第二问直接当"取消"（响一声）。用例收尾 / 开头要 `AppTest.dismissConfirmations()`（`freshSession` 已经先调了），不然上一条留下的 sheet 让下一条的 sheet 排队。
6. **底栏停止默认要确认**：新写的用例点了底栏停止要在确认框上点"停止"（`AppTest.waitForConfirmation(.stopRecord)` + `AppTest.answer(.confirm)`），或者在用例里 `controller.settings.confirmBeforeStop = false`、defer 打开。快捷键 / API / MIDI 路径不受影响。
7. **`HotkeyEditorModel.Row.action` 现在是可选的**（"其他命令"没有命令时为 nil，不再兜底成 Cut）；读它的地方要处理 nil（MIDI 面板已改）。
8. **两份 Localizable.strings 都改了**：新键按字母序插在主区里（不是追加在末尾），删了 5 个不再用的键（`bottom.streamReconnecting`、`bottom.recordStateTip`、`outputSettings.record.container`、`outputSettings.record.remux`、`hotkeys.action.otherCommand`），改了 `bottom.streamingMany`（占位符从 1 个 %d 变 2 个）、`notice.streamStarted`、`outputSettings.stream.reconnect`、`outputSettings.record.hint`、`mixer.busEffectsHint`、`inputSettings.section.effects` 的值。86 也改这两个文件，G6 合并时按键解冲突（两边的键都留）。
9. **文档跟着改**（不在本会话目录，给 103 / G6）：docs/user/概念.md:35（"效果链"→"音频效果"）、:91 与 docs/user/en/concepts.md:99（退出口径：现在先问、不再静默写回，LastSession 照存）、docs/user/输出.md:22 与 en/outputs.md:23（文件格式已合成一个单选）、docs/user/输出.md:60 与 docs/user/en/outputs.md:63（推流页那一项现在叫"重试间隔最长 n s（一直重试）"/"Max retry interval"）；docs/KNOWN_ISSUES.md 的 UIA 表第 25–28 行（X01–X05）、第 29 行的界面部分（X06 / X07）、第 31 行（X10）、第 32 行（X11 / X13）、第 34 行里的 X14 / X30 可以按本报告改状态；docs/api.md 若写了"起不来报 idle"也要改（§4 第 2 条）。
10. 推流页一段一段的地址 / 密钥草稿是 `StreamDestinationSection` 的 `@State`，按输出编号认身份；回车或离开输入框才提交，直接关窗口时没提交的草稿会丢（`.onChange(of: focus)` 不保证在窗口关掉时触发）。
11. 未保存判定每次快照分发（≤ 60 Hz）都算一遍 `documentContent(session.makeShow())` 再比较——十几路输入的节目是微秒级；以后输入上限放到 64（Q33）时留意一下。
