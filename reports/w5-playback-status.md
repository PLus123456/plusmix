# W5-N 报告：文件播放控制、推流 / 录制状态面板、录制 / 推流时长、状态行分开写码率（prompt 101，分支 `w5-playback-status`，2026-10-11）

工作树 `.claude/worktrees/w5-playback-status`，分支 `w5-playback-status`，**叠在 100 的分支 `w5-transition-slots`（4d5d2a2）头上开**（用户 2026-10-10 定），小步提交、没有 rebase / 改写；
100 的分支没动（还是 4d5d2a2），G8b 按 100 → 101 合入时 101 已含 100 全部提交，两边都动的文件不会冲突。不 push、不 merge。
提案 021 / 022 / 025 已随 G8a / G8a-2 进 main（prompt 末尾两段追加），本会话只用契约、没改契约。

## 1. 做了什么

先写红测试再实现：SwitcherInputs 一条（d0ee299 红 → 32aa65b 绿）、App 七条（b6f0591 红：76 处断言全红在各自要验的点上 → cf38b82 绿），每轮都实跑确认（数字见 §6）。

| 交付 | 落点 | 提交 |
|---|---|---|
| **1 文件播放控制**（D5 / V04，提案 021） | **格子第一行** × ｜ 转场 ｜ Cut ｜ **⏮ ｜ ▶/⏸ ｜ 🔁**：后三颗只对文件输入亮（别的输入灰着，提示"只对视频 / 音频文件输入"）。⏮ = `seekPlayback(0)`（暂停中就停在第一帧，定位与暂停各管各的）；▶/⏸ = `setPlayback`（播着显示 ⏸，暂停中显示 ▶ 并高亮——画面是停住的；**播完不循环时 ▶ = 从头播**）；🔁 = 原来那颗"循环"开关（G7 追加 ③：没做第二个入口，只是从字换成图标，见下 1.）。右键（文件输入才有）多四项：播放 / 暂停、回到开头、循环（勾）、**切上 PGM 时从头播**（勾 = `restartOnProgram`，整份 `setInputSettings` 只翻这一项）。**运行表**（`InputRuntime`）：快照里 `settings.playback.paused` 与已对上的不同 → `FileInput.pause / resume`；`(seekTick, seekSeconds)` 是新的一次请求 → `seek(toSeconds:)`（⏮ 与"切上 PGM 时从头播"走同一条路：reducer 在换 PGM 那一拍写定位 0，运行表照做）；不重建这一路；还没 start 的路记下、start 之后再对（`FileInput.start` 会清暂停）；建对象那一刻已经在的定位请求不做（那是给上一个对象的，换文件后不该跳到旧位置）。`SwitcherSession.pollSnapshot` 看到任何一路的 playback 变了就调 `applyPlayback`。**结束动作 / 速率**：路径没变、只差这两样都就地改（原来只认结束动作）。**输入设置 › 来源**：文件输入只改"播完 / 播放速率"当场发 `setInputSource`、不用点"应用来源"（运行表就地改、接着播），换文件照旧等"应用来源"；说明里写明；下面加"播放"一节（▶ / ⏸、⏮ 回到开头、切上 PGM 时从头播）。`InputSettingsModel.update` 整份替换时播放目标与定位请求以快照为准、只带上表单能改的 restartOnProgram（格子 / 快捷键 / API 随时在改暂停，表单那份可能旧了）。**FileInput**（File/ 目录，只动控制面）：播完之后（停在末帧 / 黑场）把结束动作改成循环 = 当场从头接着循环（推帧线程收尾时记 `reachedEnd`，start / seek 清）——不改的话解码线程停在尾巴上等换代，开循环什么也不会发生。**未保存判定**不算暂停 / 定位（现场操作），算 restartOnProgram（设置）。 | 32aa65b、cf38b82 |
| **2 推流 / 录制状态面板**（L11 / V11，Q13 (a)） | 新 `OutputStatusPanel.swift`：一个窗两页（推流 / 录制）。推流页每个目的地一行：名称 / 状态 / 码率 / 丢帧 / 重连 / **时长** / **断线** / **最后错误**；录制页：名称 / 状态 / 时长 / 码率 / 帧数 / 丢帧 / 剩余空间 / 最后错误——**数全读 Stats.encoder**（022 的 `uptime_s / disconnects / last_error / attempt`），最后错误原样显示推流模块打的那一行（G6 追加 ①：鉴权失败的三种文字直接出现在这里）。下面**事件记录**：相邻两行 Stats 里同一路的状态文字变了才记一条（连接中 → 推流中 → **断开：原因** → 重连中（第 n 次）→ **重连上** / 已停止 / 失败：原因），时间 = 那一行的 `ts`；只做显示、不计数；1 Hz 采样，一秒内来回的看不到（窗里写明）。模型由 `PanelCoordinator` 每行 Stats 都喂（**窗口关着也记**），换 session 清空。底部"视频延后 n ms"读 `Stats.video_delay_ms`（G8a 追加），"显示日志…" = 帮助 › 打开诊断文件夹。入口：底栏推流 ▴ 的"推流状态…"（**原来指向推流页，G7 追加 ②**）、录制 ▴ 末尾新加"录制状态…"、推流页顶上"推流状态…"、录制页"录制状态…"；菜单栏"输出 › 推流 ▸"与底栏 ▴ 是同一份菜单。 | cf38b82 |
| **3 时长**（E10） | 底栏录制 / 推流主体在录 / 在推时写"**● 录制 01:02:05**""● 录制 00:14:22（3 路）""● 推流 00:10:00（2/3）"（英文"● REC / ● LIVE"）：时长 = `Stats.encoder[].uptime_s`（多路取最长那一路；推流含重连期，022 的默认口径），**不在 App 里计时**（没有新 Stats 字就不变，用例钉了）；等宽数字（每秒变也不挤动别的按钮）。工具条右组是同一份汇总（`OutputButtonSummary`），同样带时长。录制 ▴ 每个在录的行"名字 · 录制中 · 01:02:05"；ISO 页表多一列"时长"（在录写 hh:mm:ss，没在录写 —）。`durationText` 一处定义（向下取整到秒、超过一天小时照写、负数 / 非有限按 0）。 | cf38b82 |
| G6 追加 ② | 底栏 / 推流页 / 统计窗的"连接中 / 重连中（第 n 次）"改读 **Stats 的 `attempt`**（022 B1），`OutputRuntime.streamConnectAttempt` 删掉；运行表只再给"起不来的原因"（`routeDetail` → `routeFailure`）。`OutputRouteStatus(output:entry:failure:)` 一个构造：state / frames / attempt / uptime 全从同一项 Stats 来。 | cf38b82 |
| **4 状态行**（X28） | "编码跳帧 n · 码率 x"换成"**编码滞后跳帧 n · 录制 x · 推流 y**"：录制 / 推流分开写（原来只取第一个在跑的，两个都开时推流码率看不到），**多路各给码率最低的那一路**（退避中的推流码率 0，它就是最差的）；跳帧给录制 / 推流里最多的那一路；标签按实际含义写"编码滞后跳帧"（E1：编码跟不上、编码之前跳过的帧，累计——不冒充设计方案 §10 的"编码器占用"）。NDI 的原始码率不进这两项；只有 NDI 在发时跳帧才看它。不给输出类型时按 state 认（recording = 录制，publishing = 推流）。 | cf38b82 |
| 2026-10-10 裁定 ① 推流鉴权两种写法 | 鉴权表加"写法"单选：**Adobe（user:pass@）** / **查询串（?user=&pass=）**，查询串的两个参数名可改、默认 MediaMTX 的 user / pass。`StreamAddress.withQueryCredentials` 写进 query（值按 RFC 3986 非保留字符以外全编码）、**不碰 userinfo**；两种写法互斥（写一种时另一种的账号去掉，用户名空 = 两种都去掉）；按地址认回写法（`authStyle(of:)`）。**地址框打码**直接用推流包的 `StreamURLRedaction.redact(url:marker: "•••")`——userinfo 与 query 里名单内参数（user / pass / password / key / token / secret / passphrase / streamid…）的值，名单就是日志 / 诊断包那一份；编辑时打码的值原样留着就换回原值（userinfo 和 query 各自换）。参数名不在名单里时表上提醒"会显示明文"。说明文字写清哪类服务器用哪种（Adobe：Wowza / Nimble / FMS / 部分 CDN；查询串：MediaMTX / SRS / nginx-rtmp）。节目只存整条地址，没加字段 / extra 键。地址框下面一行"鉴权（查询串）：用户 xxx"。 | cf38b82 |
| 2026-10-10 裁定 ② | 格子循环的提示写明"关掉 = 播完停在最后一帧；要黑场去输入设置 › 来源"；没存"关之前是什么"。 | cf38b82 |
| 2026-10-10 裁定 ③ / G8a 025 | `OutputLinkage` / 录制页 / 推流页读写都走 `RecordSettings.armed / .ownFormat`、`StreamSettings.followFirst`，extra 键常量删掉；**文件一节跟录制 1 时每路自己的两个标记不跟**（025 把它们放进了 RecordSettings，原来整份拷 RecordSettings 会把录制 1 的 armed 抄给每一路；`sharedRecordFile` 回到默认、`expectedRecordSettings` 换回这一路自己的）。`ShowDocuments.prepared` = 清录制 / 推流开关 + `Show.migratingLegacyAppFlags()`（**读文件与读 LastSession 两处都走它**，搬完删键）；W5-I 的用例改读字段。 | cf38b82、87055f3 |
| G8a 追加 | `OverlaySettingsModel.defaultFadeSeconds` 删掉（没人读）。 | cf38b82 |
| 2026-10-10 裁定 ④ 顺带两项 | ① 外部显示路由合成一份：菜单的 `select / turnOff / outputs / autoName / sources` 改成转调 `ExternalDisplayRouting`（净 −34 行）。② 96 的 `MachineInfo`（没人用）删掉；两份表同步删 36 个 App/Sources 里没人用的键；`LocalizationTests.testL10n_everyKeyInTableIsReferenced` 反向检查（动态拼的键按前缀放行）。两张问题单末尾写了处理结果。 | da8f768 |
| 文案 | 两份 strings 加 W5-N 一节（中英各 73 条），改 1 条（循环的提示），删本会话换掉的 9 个旧键 + 顺带清的 36 个。docs/ 不在本会话目录：手册 / API 文档要改的点写成问题单 `reports/issues/W5N-w4-docs-2-playback-status-docs.md` 给 103。 | cf38b82、da8f768 |

和 prompt 字面不同的两处，照实说：

1. **"循环"从字变成图标（🔁），⟲ 用的是 ⏮**：最小格子 160 pt，第一行要放 × / 转场 / Cut / ⏮ / ▶⏸ / 循环六颗；实测 mini 按钮里"转场""循环"两个字的固有宽 36 pt、图标 24–28 pt，六颗里只要有三颗是字就放不下（转场会被截成"转…"），所以播放三颗都做成 20 pt 图标，转场 / Cut 平分剩下的（实测见 §2）。⟲（arrow.counterclockwise）和循环的 🔁 都是转圈箭头、挨着放分不清，"回到开头"用媒体播放里通用的 ⏮（backward.end.fill）。辅助功能名与提示都写全（"输入 1 回到开头 / 暂停 / 循环"）。
2. **"切上 PGM 时从头播"的首帧不在切换那一拍**：契约（021）本来就写"首帧晚 1–2 拍（FileInput 的 seekLead）"；App 里还多一段"快照 60 Hz 轮询到运行表"，实测见 §2。切上去的那几拍 PGM 上是这一路原来停着的那帧（暂停 / 预览时的位置），然后跳到第 0 帧。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

（全量与运行环境见 §6。prompt 没给数值阈值的条目按"逐项相等"判。）

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `FileInputTests.testInput_fileEndActionChangesInPlace`（SwitcherInputs） | pattern.mov（1080p60 10 s，帧号 = 帧序号）循环中**运行中**改成停在末帧、定位到 590：播到 599 停住、noSignal、最后 5 拍帧槽都是 599、没回到 < 590；**播完之后**开循环：从第 0 帧起、20 拍帧号逐一连续、回到 live；运行中改速率 2：新锚点之后 20 拍每拍 +2；`seeks` = 2（那次定位 + 播完开循环的从头，没有别的重开）。同一个对象、同一个帧槽。修前红在第 ② 步（一直停在 599）| 逐项相等 | ✅ 1.46 s |
| `testUI_fileCellPlayPauseRestart`（prompt 点名） | 文件输入 + 合成源：第一行六颗 × / 转场 / Cut / ⏮ / ▶⏸ / 🔁，后三颗只对文件亮、全部不抢焦点，合成源的灰着写"只对视频 / 音频文件输入"。**⏸**：总线上恰好一条 ui 来源的 `setPlayback(1, paused: true)`、跑着的 FileInput `isPaused`、按钮变 ▶ 并高亮；之后 0.5 s 从输入的分支槽**逐帧**看：30–31 帧（≈ 每拍一帧，**pts 每拍刷新**、相邻 pts 差 ≤ 2 拍且递增）、**帧号只有一个**（五轮里是 19 或 20，停在哪一帧看点的时机）。**▶**：接着走、第一帧 ≥ 停住的那帧（不是从头）。**⏮**：`seekSeconds` = 0，往回跳之后的**首帧帧号 0**。右键有播放 / 暂停、回到开头、循环、切上 PGM 时从头播（合成源没有）；勾"切上 PGM 时从头播"→ `restartOnProgram`；切到 2 再切回 1 → **首帧帧号 0**。**输入对象从头到尾是同一个**。第 0 帧比请求那一拍晚：⏮ **3 拍**、切上 PGM **3 拍**（换算成引擎时钟的拍号，两轮都是 3）| 逐项相等 | ✅ 4.1–4.2 s |
| `testUI_fileSourceEndActionAndRateChangeInPlace` | 输入设置来源一节：表单里改速率 2 → 当场发 `setInputSource`、跑着的 FileInput.rate = 2、"应用来源"不用点（sourceChanged = false）；改播完 = 黑场 → endAction 就地改；输入对象不换；说明里写"不重建"；改路径 → 等点应用，点了才重建 | 逐项相等 | ✅ 0.75 s |
| `testUI_fileCellButtonsFitSmallestCell` | 第一行六颗的宽：160 pt 格子 **[22, 30, 30, 20, 20, 20]**、200 pt [22, 50, 50, 20, 20, 20]、256 pt [22, 78, 78, 20, 20, 20]；"转场""Cut"按钮宽 ≥ 字宽 + 6（字宽 19.9 / 17.0）；最后一颗不出格子、相邻不重叠 | 我定的放得下标准 | ✅ |
| `testUI_streamStatusPanelReadsStatsUptime`（prompt 点名） | 喂一行 `uptime_s = 65` 的 Stats → 那一行"时长" **00:01:05**；码率 5.90 Mb/s、丢帧 3、重连 1、断线 2、最后错误原样（"鉴权失败（用户名或密码不对）：… reason=authfailed"）；第 1 次连接写"连接中"（attempt 读 Stats）；没开的路写"未开"、时长 —；`video_delay_ms = 40` → "视频延后 40 ms"；录制页：时长 01:02:05、帧数 7200、剩余 200.0 GB。事件（相邻五行 Stats 推出）："主平台 · 推流中""备用 · 连接中""备用 · 推流中""备用 · 断开：连接断了：connection reset by peer""备用 · 重连中（第 1 次）""备用 · 重连上"，时间 = 各行 ts（1000 / 1000 / 1001 / 1005 / 1006 / 1008）；录制页事件"录制 · 录制中"。底栏推流 ▴"推流状态…"开面板（窗名"推流 / 录制状态"，停推流页）、录制 ▴"录制状态…"停录制页、推流页的按钮也开；"显示日志…"接到诊断文件夹 | 逐项相等 | ✅ 0.04 s |
| `testUI_recordButtonShowsDurationFromStats`（prompt 点名） | 底栏：`uptime_s` 3725.6 → "**● 录制 01:02:05**"（向下取整）、推流 600.2 → "● 推流 00:10:00"；下一行 3726.6 → 01:02:06；**没有新 Stats 等 1.2 s 字不变**（不在 App 里计时）；工具条同一份；三路录制（65 / 64.9 / 64.8 s）→"● 录制 00:01:05（3 路）"、两个在推一个没开 →"● 推流 25:00:01（2/3）"（超过一天不绕回）；录制 ▴ 三行"录制 · 录制中 · 00:01:05""ISO 1 · 录制中 · 00:01:04"…；ISO 表"时长"列 PGM 行 00:01:05、输入行 = 它的 ISO 路 00:01:04、停了写 —。**最小窗口宽 1100 pt、最长两颗标题**（"● 录制 10:00:00（3 路）"240 pt、推流 236 pt）：左组到 864 pt、右组从 925 pt 起（≥ 16 pt 的约束），字没被压缩 | 逐项相等；左右组间距 ≥ 16 pt（底栏原有约束） | ✅ 1.27 s |
| `testUI_statusLineSeparatesRecordAndStreamBitrate`（prompt 点名） | 字段 = 节目 / 帧率 / 渲染 / GPU / CPU / 丢帧 / **编码滞后跳帧 / 录制 / 推流** / 磁盘；录制 18.00 Mb/s、推流两个在推（5.90 / 2.10）给**最差的 2.10 Mb/s**、跳帧给最多的 5；NDI 1990 Mb/s 不进；只录不推：推流 —；退避中的推流（码率 0）算在跑 → "0 b/s"；底栏同一行 Stats 同样的字 | 逐项相等 | ✅ 0.01 s |
| `testPanels_streamAuthQueryStringWritesQueryAndMasks`（裁定 ① 点名） | `rtmp://media.local:1935/live?app=1` 写查询串（user / pass）→ `…?app=1&user=op&pass=p%40ss%20w`（不碰 userinfo、推流包认得、按地址认回查询串写法、读出原文 "p@ss w"）；地址框 `…?app=1&user=•••&pass=•••`；token / key / passphrase / secret 也打码；打码段原样留着 = 原值、改了主机照样保住、自己写了新用户名照用；换参数名（username / password）旧的去掉；换回 Adobe → `rtmp://op:x1@…?app=1`；用户名空 = 两种都去掉；两段说明分别提 Wowza / MediaMTX / nginx-rtmp；extra 里没多东西 | 逐项相等 | ✅ |
| `testPanels_025_showLoadMigratesLegacyAppFlags`（裁定 ③） | 存一份带三个旧 extra 键的节目 → `ShowDocuments.load`：armed = false / ownFormat = true / followFirst = true 搬进字段、**所有输出的 extra 都空了**；`armedRecords` 只有 ISO、ownFormat 的 ISO 不跟录制 1、备用跟推流 1；录制页 / 推流页写也走字段、extra 不出现旧键；新建第 2 个目的地 followFirst = true | 逐项相等 | ✅ |
| `LocalizationTests.testL10n_everyKeyInTableIsReferenced`（顺带，新） | 表里 1677 键都在 App/Sources 里以字面串出现或是动态拼键前缀的展开（删 36 个之后）；认出动态前缀 > 10 个 | 0 个孤儿键 | ✅ |
| 改了期望的旧用例（新口径带出来的，没有放宽断言） | `StatusLineTests` 两条（X28：三项、按 output 编号对号的意思不变、顺序不再影响）、`LiveSafetyTests`（按钮汇总：带时长；等录制起来认 `AppTest.isRunningTitle`）、`RecordingTests` / `UISmokeTests` / `StreamWiringTests` / `ISOAppTests`（等"● 录制 / 推流 hh:mm:ss"）、`BottomBarSplitTests`（录制 ▴ 行带时长、末尾多"录制状态…"、"推流状态…"开面板、状态行字段名中英）、`InputStripTests` 两条（第一行后三颗是图标、灰着的提示）、`OutputPagesTests`（W5-I 的用例改读 025 字段；"查询串里的 user 不打码"按裁定 ① 改成打码）| 原断言的意思不变 | ✅ |
| SwitcherInputs 全包 `swift test` | SwitcherInputsTests 60（6 跳）、NDITests 25（2 跳）、DeckLinkTests 25（3 跳），**0 红**（跳的都是原有的 BLOCKED-硬件 / SDK） | 0 失败 | ✅ |
| `make test-app` 全量 | **第 2 轮 244 条 = 240 过 + 4 跳 + 0 红**（xcresult `Test-Switcher-2026.10.11_13-53-11`）；跳的 4 条：键盘导航（系统设置没开）、空闲唤醒探针（人工项）、内置摄像头（BLOCKED-权限：摄像头授权在等待，第 1 轮是过的）、虚拟摄像头（BLOCKED-签名）。第 1 轮 243 条 = 237 过 + 3 跳 + 3 红，红的见 §6 | 0 失败 | ✅ |
| lint | 禁词 / 版本 0.1.0 / Package 约束、依赖方向（8 包）、**归属（`--base w5-transition-slots`：47 个文件都在范围内）**、check-links（178 个 Markdown）、check-rt-symbols 全过。`make lint BRANCH=w5-playback-status`（基线 main）的归属一段会把 100 的 43 个文件也算进来、报越界——叠分支就该按 prompt 写的 `--base`（G7 记过的坑） | 全绿 | ✅ |

## 3. 没做的和原因

1. **纯音频文件输入**（G7 追加 ④，问题单 W5K-w2-inputs-file-audio-only）：101 的目录许可写明 File/ 只做播放命令接线与就地改结束动作 / 速率、**不动解码路径**；支持纯音频要改 `FileAsset.init`、`decodeLoop` 和 `paceLoop` 的锚点（现在等视频首帧才定锚点），都在解码 / 推帧路径上。问题单末尾写了原因，仍归 W2-A 系。格子的三颗按钮对这类输入是亮的（来源是 .file），但这一路本身是 error，按了没效果。
2. **"鉴权失败就停"**（G6 追加 ①）：没改。推流的重试策略在 `StreamOutput`（SwitcherOutputs，不在本会话目录），而且它报鉴权失败只有文字、没有类型化的原因——App 要做只能按文字匹配"鉴权失败"，不干净。现在的样子：状态面板"最后错误"原样显示那一行、事件里每次断开 / 重连都有一条，底栏是橙色"重连中（第 n 次）"。要不要停、怎么停见 §4 第 1 条。
3. **分类颜色切到 `InputConfig.color`**（023 第四节的 App 侧，P5-2 报告 §3 第 1 条把它和 100 / 101 / G8b 列在一起）：101 的 prompt 没写这一项，没做；`InputCategories` 仍存 Show.layout。归 G8b 或下一个 App 会话（`show.migratingLegacyInputCategories()` 在 Show.load 后调一次，做法同本会话的 025）。
4. **推流 ▴ 每一行没加时长**：prompt 只要录制 ▴（"ISO 表与录制 ▴ 的时长列同源"）；推流的时长在主体按钮和状态面板里有。要加是一行（`StreamMenuRow` 标题），W5-F 钉的那几条期望要跟着改。
5. **文件播放的位置条 / 拖动定位**：不在交付里（D5 只要 ▶ / ⏸ / ⟲ / 循环），`seekPlayback` 本身支持任意秒数，界面上以后要做进度条直接发它。播放列表归后续方案 §2.5（prompt 写明不做）。
6. **docs/**：手册与 API 文档要改的点写成问题单 `reports/issues/W5N-w4-docs-2-playback-status-docs.md` 给 103（格子三颗按钮与右键、切上 PGM 时从头播、输入设置的播放一节、状态面板、时长、状态行、推流鉴权两种写法；截图要重拍）。
7. **状态面板的事件记录不跨 session 留存**：换节目 / 重新起引擎就清空（只属于这一场）；也不写进诊断包（那是"显示日志…"那一份日志文件的事）。要留存得另定写到哪。

## 4. 对契约的疑问 / 要你拍板的

没有要改契约的地方（021 / 022 / 025 的字段与命令都够用）。几处请你看一下：

1. **鉴权失败要不要停**（G6 追加 ①，随状态面板一起定）：
   - (a) 维持现状：一直按退避重试（1、2、4…≤ 30 s，每次 3 个连接），状态面板 / 事件写清原因；
   - (b) **鉴权失败就停**：`StreamOutput` 把"服务器拒绝鉴权"（authfailed / nosuchuser / 不支持的鉴权方式）分出一个类型化的原因，第一次就进 failed、`last_error` 写那一行，不再重试；App 底栏变红"失败"、点主体 = 重试（W5-B 的口径），面板 / 事件照显示；改动在 SwitcherOutputs（W2-D 系），App 不用改；
   - (c) 鉴权失败重试 n 次再停。
   我倾向 (b)：密码错了重试只会每 30 s 打一次服务器、挡住真正的问题，操作员要的是"红了、写着为什么"。选了就给推流会话开问题单。
2. **"切上 PGM 时从头播"的首帧晚 3 拍**：021 的契约文字写"首帧晚 1–2 拍（FileInput 的 seekLead）"，App 里实测 3 拍（⏮ 也是 3 拍）——多出来的是快照 60 Hz 轮询到运行表那一段（≤ 1 拍）加锚点取整。这 3 拍里 PGM 上是这一路原来停着的那一帧，然后跳到第 0 帧。要做到"切上去那一拍就是第 0 帧"得提前准备（例如勾了"切上 PGM 时从头播"的那一路在 PVW 上就先停在第 0 帧），那是后续方案 §2.5"转场时自动播"一类的事。3 拍能不能接受？
3. **我自己定的几处口径**：
   - 播完（停在末帧 / 黑场）之后再开循环 = 当场从头接着循环（FileInput 里改的，不开的话按了没反应）；
   - 时长多路取最长那一路；状态行"最差那一路"= 码率最低的那一路（退避中的推流码率 0 就是它）；跳帧取最多的；
   - 推流鉴权两种写法互斥：保存一种时另一种的账号去掉（地址里两头都带会让服务器两种鉴权都走）；参数名不在打码名单里只提醒、不拦；
   - 英文界面的时长写"● REC 01:02:05 / ● LIVE 00:10:00"。
4. **025 的搬迁可以并进 `Show.load` 了**：P5 报告 §4 第 1 条说"101 切换完之后建议下一次契约会话把 `migratingLegacyAppFlags` 并进 `migratingLegacyKeys()`"（这样 API loadShow / addOutput 带旧键的也一致）。App 现在读写都走字段、旧键在 `ShowDocuments.prepared` 里搬，提前并进去也不会丢东西。归下一个契约会话。

## 5. 下一个会话需要知道的坑

1. **App 用例里要逐帧看某一路的画面**：别在主线程上轮询——主线程要 pump 事件循环快照才落到运行表（暂停 / 定位都在那儿生效），轮询会把它堵住。本会话的做法：`session.inputs.openBranch(input:)` 开一个分支槽，另起一条线程当它唯一的消费者（`SlotSampler`，在 PlaybackStatusTests.swift 末尾），按 sequence 去重、当场解帧号、不持有 Frame。
2. **FileInput 定位期间不推帧**（等目标帧解出来才定锚点，帧槽保留旧帧）：采样时"点之后的第一帧"可能直接就是第 0 帧，要把点之前的最后一帧也算进比较窗口，才看得到"往回跳"。
3. **`programTiming()` 给新输入的时钟以"现在 + 3 拍"为 0 拍**：输入那边的拍号和引擎（reducer 的 tick、`seekTick`）不是一套编号，只有时间网格相同；要比"晚几拍"用 `session.engine.clock?.spec` 换算（本会话第一版直接相减得出 −136 拍）。
4. **SwiftUI 按钮的标题要直接写 `L("…")`**：`AccessibilitySourceScanTests` 只认字面键，`Button(SomeType.title)` 会被当成没有标题（本会话全量第 1 轮红在这）。
5. **`LocalizationTests.testL10n_everyKeyInTableIsReferenced`（新）**：表里的键要么在 App/Sources 里以字面串出现，要么是 `L("前缀.\(…)")` 动态拼键的展开；只在测试里用、源码里不用的键会红。加键时两份表一起加，删功能时一起删。
6. **底栏 / 工具条的录制 / 推流标题现在每秒变**（"● 录制 00:00:03"）：等"录制起来了"的用例别再比 "● 录制中"，用 `AppTest.isRunningTitle(title, "● 录制", suffix: "（3 路）")`。按钮用等宽数字，宽度不抖；`BottomBarView.show` 仍是"没变不重设"。
7. **"第几次连接"读 Stats 的 attempt（1 Hz）**：原来读运行表、点了马上变；现在跟着下一行 Stats 变（最多晚 1 s）。`OutputRuntime.streamConnectAttempt` 删了；起不来的原因仍问运行表（`routeFailure`）。
8. **`InputSettingsModel.update` 整份替换时播放目标以快照为准**：表单只改得到 `restartOnProgram`；要在设置窗里改暂停 / 定位走 `togglePaused()` / `restartPlayback()`（发 setPlayback / seekPlayback）。
9. **025 之后 `RecordSettings` 里有每路自己的 armed / ownFormat**：任何"把录制 1 的 RecordSettings 抄给别的路"的地方都要换回那一路自己的两个标记（`OutputLinkage.sharedRecordFile` 已回到默认、`expectedRecordSettings` 换回本路的）。
10. **未保存判定不算暂停 / 定位**（`AppController.documentContent` 把 paused / seekSeconds / seekTick 清掉再比），算 restartOnProgram。
11. **显示类用例看屏幕排布**：`ExternalOutputAppTests` 的外部窗口 / 多画面两条在 Claude 应用铺满内置屏、测试宿主的窗被挡住时窗口 0 帧、必红（本会话第 1 轮全量时过、后来连红两次，屏幕没锁没睡，`CGWindowListCopyWindowInfo` 看到前台只有 Claude 一个窗）；先单独复跑、确认屏幕上能看到测试宿主的窗。`ToolbarMenuTests` 的两条菜单用例（帮助菜单、输入设置菜单）第 1 轮全量各红一次、单独复跑绿——G8 §7 第 4 条记的同一件事。
12. **沙箱对"cd + 复杂管道"的命令会拒**：Bash 里改文件的长脚本先写进 scratchpad 再 `python3 脚本 worktree根` 跑；`cd` 进子目录会改掉会话的主目录（用子 shell 或绝对路径）。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0）；同机没有别的会话在跑重活（开跑前看过 `ps -axo comm,%cpu`、负载 2.9–3.2）；内置屏 1728×1117 + 外接 2560 宽一块。新 worktree 先 `make gen`、`make build-app` 热缓存，并编了 release frameprobe（ISO A4 / 推流 10 s 两条要它）。

| 时间 | 命令 / 范围 | 结果 |
|---|---|---|
| 12:5x | `swift test --package-path Packages/SwitcherInputs --filter SwitcherInputsTests.FileInputTests/testInput_fileEndActionChangesInPlace`（实现前） | **红**：第 ② 步（播完开循环）一直 599，其余两步过 → d0ee299 |
| 13:0x | 同上（实现后） | 1 / 1 过 → 32aa65b |
| 13:12 | `xcodebuild test -only-testing:SwitcherTests/PlaybackStatusTests`（桩） | **7 条全红、76 处断言、0 意外**，红在各自要验的点上 → b6f0591 |
| 13:2x | 同上（实现后，三轮） | 第 1 轮 6 / 7（播放那条采样在主线程上、漏了第 0 帧）→ 采样挪到独立线程 → 第 2 轮 6 / 7（定位期间不推帧，比较窗口要带上点之前那一帧）→ 第 3 轮 **7 / 7** → cf38b82 |
| 13:3x | 受影响的 13 个类（LiveSafety / Recording / UISmoke / ISOApp / BottomBarSplit / InputStrip / OutputPages / StatusLine / Localization / CopyCompliance / Accessibility / StreamWiring / PlaybackStatus） | 69 条：65 过 + 3 跳 + 1 红（OutputPages 钉的"查询串里的 user 不打码"，按裁定 ① 改期望）→ 87055f3 |
| 13:37–13:44 | **`make test-app` 全量第 1 轮** | **243 条 = 237 过 + 3 跳 + 3 红**：`AccessibilitySourceScanTests`（状态面板按钮标题不是字面键，已修）、`ToolbarMenuTests` 两条菜单用例（已知偶发，单独复跑绿） |
| 13:4x | 定向：PlaybackStatus / Localization / AccessibilitySourceScan / ToolbarMenu / ExternalOutputApp / BottomBarPopup / OutputPages / SettingsWindow / W5LMisc | 48 条：44 过 + 4 处断言红，全在 `ExternalOutputAppTests` 两条显示类用例（窗口 0 帧，§5 第 11 条）；ToolbarMenuTests 10 / 10 过 |
| 13:4x | PlaybackStatus + ExternalOutputApp | PlaybackStatus 8 / 8（第 0 帧晚 3 拍）；ExternalOutputApp 仍是那两条显示类（屏幕排布） |
| 13:48–13:52 | `swift test --package-path Packages/SwitcherInputs` | 60 + 25 + 25 = 110 条，11 跳，**0 红** |
| 13:53 | lint 各段（`make lint` 的 lint-rules / check-deps / check-links / check-rt-symbols + `check-ownership.sh w5-playback-status --base w5-transition-slots --include-working-tree`） | 全过；归属 47 个文件在范围内 |
| 13:53–13:59 | **`make test-app` 全量第 2 轮**（da8f768 + 本报告） | **244 条 = 240 过 + 4 跳 + 0 红**（第 1 轮之后只多了 `testL10n_everyKeyInTableIsReferenced` 一条）；`ExternalOutputAppTests` 这轮屏幕排布允许、过了；第 0 帧晚 3 拍、格子与底栏的量值同 §2 |

提交（`git log w5-transition-slots..w5-playback-status`）：d0ee299（SwitcherInputs 红）→ 32aa65b（FileInput 播完开循环）→ b6f0591（App 红 + 桩）→ cf38b82（实现）→ 87055f3（旧用例改期望）→ da8f768（顺带两项 + 补的用例 + 问题单）→ 本报告。
