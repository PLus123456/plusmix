# 已知问题

模板 docs/release/KNOWN_ISSUES-template.md；每次发布由检查点（G5 / G6）更新，发布说明里列出（测试标准 §6 发布门槛第 5 条）。
每条一行，按严重级排（§6：S0 直播中断类、S1 功能错但节目能继续、S2 有绕过办法、S3 外观文案）。"来源"是问题单（reports/issues/）或报告章节；"计划"是归属会话。
S0 / S1 不许出现在已发布版本的表里——这个版本**还没有发**：2026-09-28 G5 判不发（reports/G5.md），**2026-10-02 G6 重判仍不发**（reports/G6.md §7）。
G6 合入第五波止血五路（W5-A 目视与弹出、W5-B 直播安全、W5-C 总线效果链、W5-D 推流鉴权、W5-E 转场守卫）：2026-09-29 界面对照调研查出的 S0 五条（X01–X05）全部修了，
S1 里的 X06 总线那一半、X10、X11、X13 修了，S2 的 X14（界面半）、X19、X25、X30 修了（下面"2026-10-02 第五波止血已修"表，每条有先红后绿的用例）。
仍阻塞 0.1.0 的：新发现的 S1（MIDIHost.sync 偶发崩溃）、8 小时长稳没有在修复后的树上重跑、签名账号；S1 X07（每路效果）与 X08 / X09（Bus A / B 出口）归骨架批次（102 / 97），按 Q68 (a) 同样要在放行前修——**用户 2026-10-03 确认：等 97 / 102 做完再发，不重新定级（X12 同）**。
**2026-10-04 G7 合入第五波骨架七路**（W5-F 底栏、W5-G 工具条与菜单栏、W5-H 输入条与格子、W5-I 输出页、W5-J 设置窗与选动作、W5-K 面板改版、W5-L 其他；reports/G7.md）：UIA 表里 S2 X21（叠加浮层）、W5-B 的副作用（一路永远起不来挡着停）、下表凭据外泄的 ①（底栏提示）修了；S1 X08 的 App 半（音频设备页每条总线选声道 → 建引擎时用）、X12 的输入 / 叠加 / 音频设置窗修了——**X07、X09 的引擎侧、X12 的设置窗那一半仍开着**；新记 S2 两条（设置窗在前快捷键不派发、外部显示路由规则两份并存）。0.1.0 仍不发（reports/G7.md §7）。
**2026-10-10 用户看完 G7 报告**：main 快进到 g7；12 条拍板全部裁定并落进 prompt / 提案 / 归属（reports/G7.md §7.1 末、落地方案 §8.8）——S1 `MIDIHost.sync` 崩溃新开 prompt 106（W2-C3）；X12 残口归 100；推流鉴权"写进查询串"归 101；W5-I 的三个 extra 标记、W5-K 的监听总线与叠加默认淡入升成契约（提案 025–027 已批，P5 落地）；下一个发的版本号 0.1.1（G8 判，prompt 107）。
**2026-10-10 G8a**（reports/G8.md §1.1）：`p5-contracts`（已批的 023§1 / 024 (b) / 025 / 026 / 027 进契约，Command 34 → 35；**020 / 021 / 022 / 023 二–五只有提案、等用户批**，100 / 101 要等它们落地）、`w2-control-3`（S1 `MIDIHost.sync` 崩溃已修——下表销号，移到"2026-10-10 G8a 已修"表）、`w1-core-4`（视频延后 L 的引擎 / 渲染器 / Integration / headless；**App 的三行接线待 G8b**，下表新加一行 S2）合入 `g8`，整仓 make test 后等用户点头快进 main。
**2026-10-11 用户裁定**（看完 reports/G8.md）：main 快进到 g8（f0c33ef）；提案 020 / 021 / 022 / 023 二–五**全批**、按提案默认 → 新 prompt 108（P5-2，`p5-contracts-2`）落地，100 / 101 等它合入；L1 对 videoDelay 的判定扣 `video_delay_ms`（阈值不动）；W1-B4 的 App 接线与开录起点归 G8b 胶水（上表那行 S2 的计划不变）。
**2026-10-11 G8a-2**（reports/G8.md §1.2）：108 P5-2 合入——020 / 021 / 022 / 023 二–五 / 028 文字进 main，Command 42，Stats.encoder 多 uptime_s / disconnects / last_error / attempt、顶层多 video_delay_ms；整仓 830 用例 0 红、App 228 用例 0 红、headless 16 / 16，main 快进（代码树 97b0634）。
**2026-10-11 G8b**（reports/G8.md §1.3 / §4.3 / §7）：100 `w5-transition-slots` → 101 `w5-playback-status` → 102 `w1-audio-3` → 103 `w4-docs-2` 合入（四路 0 冲突），G8 胶水 App 26/50 行（翻 87 / 88 的三条用例、X09 借 Master 接线、W1-B4 的 App 接线三行 + 开录起点按输出时间线）：**S1 X07 / X09、S2 X12 残口 / 监听晚 L / 兼容层 Cut Input 都销号**（下面"2026-10-11 G8b 合入已修"表）；UIA 那张表清空；W4-C2 写手册时对代码查出的两条 S2 与若干 S3 新进产品缺陷表。0.1.1 当时判不发：8 小时长稳没在这棵树上跑、L3 清单（docs/checklists/G8.md）没人跑、签名账号 BLOCKED——阻塞项与归属 reports/G8.md §7。
**2026-10-12 8 小时长稳**（用户终端 `make soak`，树 93bb783 = main，10-11 23:48 → 10-12 07:48）：S1 97 个窗口 0 超阈值、S2 2.46 MB/h、S3 30.4%（不含 NDI SDK 线程）、A3 0、崩溃 0 **全过**（reports/W4-soak-8h.md）——文件循环内存那条 S1 销号（挪进"2026-09-28 发布前已修"表）；0.1.1 还差 L3 清单与签名账号。**同日用户裁定**（reports/G8.md §7.1 末）：没选输入的 Stinger 槽从外部控制执行**拒**（G8 按用户"你定"定，提案 029 → 110 P5-3 + 112 W5-O）；推流鉴权失败**要停、要有提示**（111 W2-D4）；提案 026 **允许 headphones**（110 + 112）；App 续做开成 112 W5-O、手册续做 109 W4-C3、frameprobe A4 113 W1-A5，之后 114 G9 合入并判 0.1.1——下表的"计划"列已改。

## 0.1.0 候选（分支 release/0.1 → main；2026-09-28 G5 判不发；2026-10-02 G6 重判不发，阻塞项与归属见 reports/G6.md §7）

### 产品缺陷

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S2 | 系统守护进程 / 桌面活动突发时渲染线程成串跳拍（10 分钟里 1–11 拍；V2 仍在 0.02% 以内）。W1-B3 定位：突发让整个进程的非实时线程和 GPU 一起停 100 ms 量级，只有实时线程按时醒，是 GPU 侧；已给渲染完成线程挂实时策略并给每次跳拍归因（GPU 晚 / 完成线程晚），在途深度是契约（≤ 2 帧）没动 | 直播机同时跑重桌面任务 | 直播时关掉其它占 GPU / CPU 的程序（测试标准 §2.8） | reports/issues/G4-w1-core-missed-render-bursts-under-daemon-activity.md；reports/w1-core-3.md §4 | 要不要把在途深度提到 4 等 8 小时长稳的 V2 累计定（契约） |
| S3（原记 S2） | 标准负载（8 路合成源 + 摄像头 + 文件 + 录制 + 2 路推流 + NDI 发送）下进程 CPU 合计约 0.6 个核（8 小时均值 60.1%），其中 NDI SDK 自己的发送线程约 0.25 核（没有接收方也压两路）。**用户 2026-10-03 定口径：S3 的 CPU 判定不含 NDI SDK 线程**（测试标准 §3 / §4 S3，阈值 60% 不动），按线程快照扣掉 `ndis:*` 后 9-28 那次是 35.0%、达目标；SDK 线程我们不管、不重写 | 开着 NDI 发送时 | 不需要 NDI 时关掉该输出 | reports/issues/W4A-w2-stream-ndi-send-cpu-share.md；W4A-g5-cpu-multicore-distribution.md | 多核探查项仍到检查点安排；不再是发布判定的变量 |
| S2 | 推流凭据外泄两处（W5-D 之后地址里的 user:pass@ 真的生效了，所以是密码）：②`GET /api/v1/state` 与 WebSocket 全量状态原样带 `streamKey` 与 `url`；③密钥写在地址路径里（`rtmp://h/app/密钥`，密钥栏留空）时原样进诊断包。①底栏推流按钮 / ▴ 菜单的悬停提示 **W5-F 2026-10-03 已修**（只写名字和打过码的地址，`StreamURLRedaction.redact(url:)`；G7 合入） | 用 userinfo / 路径密钥写法的推流；API 开在局域网且没设 token 时同网段任何人 | 密钥填密钥栏；API 只开本机 + token | reports/issues/W5D-w2-control-api-state-exposes-stream-credentials.md、W5D-w4-release-diagnostics-stream-key-in-url-path.md | ② 控制会话 + 提案（API 形态变）；③ W4-B（ShowRedaction 看同层 streamKey 为空 + 路径末段） |
| S3 | 进程里第一次打开节目时连 MIDIServer 冷启动约 0.6 s（**W2-C3 2026-10-10 量到最坏约 4.7 s**：这台机器的 MIDIServer 按需拉起、空闲几分钟退出，赶上它退出 / 重启就是几秒），在主线程上同步等：界面卡一下（节目时钟不再受影响，W3-E6 已把它挪到定 t0 之前） | 每次启动 App 后的第一次打开节目 | — | reports/w3-app-7.md §3；reports/w2-control-3.md §3 第 1 条、§5 第 4 条 | W2-C 系 + App 会话一起（`MIDIController.start` 改异步回报 + App `ControlRuntime` 接回调设 midiError，78 的用例依赖同步 start；做法与估量在 reports/w2-control-3.md §3 第 1 条，包里单方面改不了） |
| S3 | 已存节目里虚拟摄像头输出的 source 字段可能是 PVW / 输入 n，运行时一律送 PGM（页面已写明"送 PGM"，不再可选） | 旧节目文件 | — | reports/w3-app-5.md §3 第 1 条 | 不处理 |
| S3 | SRT 的 passphrase / streamid 里有要转义的字符（空格 & = % + 中文……）就推不上：HaishinKit 手切查询串、值不解码就交给 libsrt | SRT 到开 passphrase 的服务器 | passphrase / streamid 只用字母数字和 - . _ ~ | reports/issues/W5D-w2-stream-srt-passphrase-reserved-chars.md | W2-D 系（SRT 分支解码一次自己设） |
| S3 | HaishinKit 2.2.5 RTMP 鉴权的残口：第三轮服务器回 needauth（挑战过期才会）时 `url.user!` / `salt!` 强制解包崩；另三条毛病（密码不解码、密码错狂连、递归重连竞态）W5-D 已绕开（HaishinKit 永远拿不到带 userinfo 的地址） | 极少 | — | reports/issues/W5D-w4-release-haishinkit-rtmp-authenticator.md | W4-B（上游补丁 / 升依赖） |
| S2 | **外部显示窗口里按 Esc、设置 › 外部显示 每路底下的"关闭这路"都是删掉这一路输出（连同显示器 / 来源的配置）**；路由菜单里同一件事叫"删除 n…"，那里的"关闭"才是只关不删（W4-C2 写手册对代码查出；之前手册与 G4 / G7 清单都写"Esc 关闭窗口"） | 现场在投影 / 副屏窗口上误按 Esc，这块屏的配置就没了，节目没有撤销 | 别在外部显示窗口上按键；用路由菜单的"关闭" | reports/issues/W4C2-w5-app-inputs-outputs-gaps-found-by-docs.md 第 1 条 | **112 W5-O**（第 1 项）：Esc 只关 / `enabled = false`、按钮改名或改成只关；改了告诉 109 删手册里的两处警告 |
| S2 | **常规 / 音频设备 / 远程控制 / 高级 页一改就整份写回本机设置，把启动参数（`--no-api` / `--api-listen` / `--api-token` / `--audio-device` / `--record-min-free-mb` / `--record-fallback`）存成本机设置**（W5-L 只把即时生效的三节改成只写自己的键） | 带启动参数排查问题的人改一下设置，本机的 API 就被存成关着 | 改完设置 `defaults delete com.plusmix.switcher <键>`，或别带参数时改设置 | reports/issues/W4C2-w5-app-settings-gaps-found-by-docs.md 第 2 条 | **112 W5-O**（第 2 项）：每页只写自己改的键，或启动参数单放一层不进 save |
| S3 | W4-C2 写手册对代码查出的其余口径：只改总线声道对不算"待应用"（等下次起引擎才生效）；导出 / 导入 / 恢复默认漏提醒 / 电源 / Tally / 兼容层 HTTP 端口几键；LastSession 只在正常退出时写、"崩溃后恢复"做不到；⌃1–⌃4 对没指定输入的叠加通道开了没画面（转场列 / 格子用 PVW）；midi.json 读不出不提示；无信号的格子不写原因（各输入的 lastError 界面不读）；NDI® 横幅"装好之后这一路会自己好"不成立（编译期开关）；切备用目录提示写"磁盘满"；英文中档格子 "Transition" 截成 "Transiti…" | 读手册 / 排查问题的人 | 手册已照实写（含绕法） | 同上两张问题单 + W4C2-w5-app-cell-buttons-truncated-in-english.md | **112 W5-O**（第 8 项）；改了告诉 109 删掉手册里对应的绕法（LastSession 那条用户没定、不动） |
| S3 | 兼容层 31 个对方真实存在的函数名（NDISelectSourceByName、StreamingSetKey、AutoPlayOn…）仍回 400 UnknownFunction，按兼容层自己的定义应回 501 NotImplemented（X51） | 兼容层客户端看日志 | — | reports/issues/W4C2-w5-transition-slots-compat-x51-still-400.md | **112 W5-O**（第 7 项）：名字补进 `knownUnimplemented` + C5 一条 501 断言 |
| S3 | 耳机"监听"菜单里 Master / Bus A / Bus B 仍灰着：引擎（026，W1-D3）已支持 `setMonitorSource`、耳机出口默认就是 Master，App 的 `MixerModel.listen` 还没接命令、`listenToOtherBusSupported = false`；"耳机总线（现在）"那一项在 026 下没有对应状态（契约不许 monitorSource = headphones） | 想在耳机里听 Bus A / B 的人 | 设置 › 音频设备 把那条总线送到耳机那对声道（≥ 4 声道设备） | reports/issues/W1D3-app-monitor-source-and-input-effects-wiring.md 第 1 条；reports/w1-audio-3.md §4 第 1 条 | **用户 2026-10-12 定 026 允许 headphones** → 110 P5-3（契约 + Integration 一处）；菜单接线 → 112 W5-O（四项都能选，"耳机总线"= headphones） |
| S3 | 每路 / 总线效果链的处理延迟与压缩器实测延迟只在 `AudioEngineStatus`（App 的音频设置窗能读），不进 Stats——API / 状态页看不到，铁律 4 要提案加字段 | API 客户端 | 看 `video_delay_ms`（= Master 链的延迟） | reports/w1-audio-3.md §4 第 5 条、reports/w5-audio-bus-effects.md §4 第 5 条 | 用户 2026-10-12 没定（提案 030 没写）；110 P5-3 不做 |
| S3 | 输入分类颜色仍存 Show.layout：提案 023 四已把 `InputConfig.color` + `setInputColor` + `Show.migratingLegacyInputCategories()` 落进契约（P5-2），App 还没切过去（101 的 prompt 没写这一项） | 多画面标签色点 / API 全量状态里看不到分类色 | — | reports/w5-playback-status.md §3 第 3 条、reports/p5-contracts-2.md §3 | **112 W5-O**（第 5 项，做法同 101 对 025 的搬迁：Show.load 后调一次） |
| S3 | 快捷键 / MIDI / 兼容层 Transition4 / Stream Deck 对**没选输入的 Stinger 槽**照常执行 = 一次延迟硬切（界面上转场列主体 / T-bar 行菜单 / 菜单栏"切换 › 转场 n"三处已按 X18 先弹输入选择）；要不要让控制层 / 兼容层也拒等用户定 | 外部控制误触 | 槽里先选好输入 | reports/w5-transition-slots.md §3 第 3 条 / §4 第 1 条 | **用户 2026-10-12 "按你的想法来"→ G8 定拒**（提案 029：reducer / 校验器对 `useTransitionSlot(start: true)` / `autoTransition` 拒、所有入口一致）→ 110 P5-3 落契约，112 W5-O 做控制层 / 兼容层 409 / Stream Deck 的提示 |
| S3 | 本机存过老 hotkeys.json 的机器 ⌥1–⌥4 仍是"执行当前转场"（W5-J 的旧默认表把它们存成 autoTransition），不自动升级到"执行转场 1–4" | 0.1.0 没发过，只有开发机 | 设置 › 快捷键 › 恢复默认 | reports/w5-transition-slots.md §3 第 2 条 | — |
| S3 | 推流密码错了一直按退避重试（1、2、4…≤ 30 s，每次 3 个连接），每 30 s 打一次服务器；状态面板"最后错误"与事件写清原因、底栏橙色"重连中（第 n 次）" | 密码填错的人 | 看状态面板 | reports/w5-playback-status.md §4 第 1 条（W5-N 倾向 (b) 鉴权失败就停，改动在 SwitcherOutputs） | **用户 2026-10-12 定：要停、而且要有提示** → 111 W2-D4（类型化的鉴权失败原因 → failed 不重试、last_error 原文；App 状态行一句 + 底栏红 + 状态面板事件） |
| S3 | AUPeakLimiter 在输入对齐那一下（延迟线 0 → 1089 帧的相位跳变 + 解除静音）遇到持续过载会"卡"在 −34 dB 不回来；节目里切换带延迟补偿的源时可能撞到，没在真素材上复现 | 开着 Master 限幅 + 持续过载的信号 | 等信号稳定再开限幅 | reports/w1-audio-3.md §5 第 1 条 | W1-D 系 |
| S3（文档） | 手册里转场列 / T-bar 横放 / FTB 时长 / 快捷键 ⌥n / 格子的播放三颗与右键 / 推流录制状态面板 / 时长 / 状态行三项 / 鉴权两种写法 / "每路效果仍未生效" / 兼容层覆盖表 Transition1–4 / docs/api/README.md 第 9 行"34 条命令"（应 42）/ 两张主窗口截图 还是 100–102 之前的写法（103 按裁定 ④ 只做了 86–98 那一段） | 读手册的人 | — | reports/issues/W5M-w4-docs-2-transition-slots-docs.md、W5N-w4-docs-2-playback-status-docs.md；reports/w4-docs-2.md §3 第 1–2 条 | **109 W4-C3**（`w4-docs-3`，独立 prompt；OWNERSHIP 有行） |

### 界面对照调研（UIA，2026-09-29）查出、尚未修的

来源 docs/ui-study/02-功能缺口.md §1（63 条，编号 X01–X63）与 reports/issues/UIA-*.md；这里只列 S0 / S1 与影响发布判定的 S2，级别是调研的判断、X01–X05 的 S0 由用户按 04 Q68 (a) 定。"计划"是 docs/plan/prompts/ 里的 prompt 号（落地方案 §8）。
**2026-10-02 G6 按第五波止血结果更新**：修了的挪到下面"2026-10-02 第五波止血已修"表，这里只剩归骨架 / 契约批次的。**2026-10-04 G7 按骨架七路再更新**：X21、W5-B 副作用挪到"2026-10-04 第五波骨架已修"表；X08 / X12 / X15 改写成做了一半的实情。 **2026-10-11 G8b 之后这张表清空**：X07（102）、X08 / X09（97 App 半 + 102 引擎侧 + G8b 借 Master 接线；X08 的 ≥ 4 声道实听仍 BLOCKED-硬件）、X12 设置窗（100）、X14 / X15 的契约半（P5-2 的 023 二）都挪到下面"2026-10-11 G8b 合入已修"表；手册的续做记在上面产品缺陷表的 S3（文档）行。

（表已清空，2026-10-11 G8b。）

目视问题（docs/ui-study/03-目视检查.md 的 34 条）：用户点名的两处（转场列、底栏菜单）与 03 §3 里 prompt 86 点名的 S3（V-03 / V-05 / V-06 / V-08 / V-12 / V-14 / V-16 / V-17 / V-27）W5-A 已修；
其余（V-01 监视器 16:9、V-04 表头折行、V-07 全局暗灰、V-09 / V-10 空状态、V-11、V-15 长路径、V-18 / V-19 菜单用词、V-20、V-21、V-22 状态行、V-24、V-25、V-28、V-29、V-30）归 92–97 的改版（reports/w5-app-visual.md §3）——**2026-10-04 G7 合入后各报告 §1 标了编号的都算改了**（V-04 / V-07 97、V-09 / V-23 94、V-15 95、V-12 96、V-22 / V-24 92 / 93……），G7 没有逐条目视复核，留在 docs/checklists/G7.md §1 第 5 条由人工打勾。

### 2026-10-11 G8b 合入（W5-M 转场槽 / W5-N 播放控制与状态面板 / W1-D3 每路效果与监听来源 / W4-C2 手册 + G8b 胶水）已修（不再出现在上表；每条有先红后绿的用例，用例在各分支报告 §2、G8b 胶水的在 reports/G8.md §4.3）

| 原级别 | 编号 | 现象 | 修在 | 用例 | 报告 |
|---|---|---|---|---|---|
| S1 | X07 | **每路输入**的音频效果链界面能调、引擎不读 | C 混音器每路两格（EQ ≤ 16 段 + 动态格，重采样后、延迟线前，效果延迟从该路对齐延迟里扣、总线时间线不动）、`InputEffectsController` 映射、预建 64 个 AU 0.8 ms；App `AudioEffectsSupport.inputEffectsApplied = true`、"效果尚未作用到声音"横幅消失（W1-D3；G8b 翻 87 / 88 钉着它的三条用例） | `InputEffectsTests` ×13、`InputEffectsIntegrationTests` ×9（`testA_inputEffects_eqChangesResponse` +12.000 dB / 别的路 −0.000、`bypassIsTransparent` 逐样本相同、`addRemoveInputNoDropout` 100 次 0 掉）、A7 离线 600 s / 真设备 60 s 0 违规、check-rt-symbols；App `HonestUITests` / `AudioEffectsTests` / `AudioSettingsRevampTests` | reports/w1-audio-3.md |
| S1 | X09 | 2 声道设备上耳机总线没声、独听 / PFL 听不到；"监听时临时占用 Master 声道"开关标尚未生效 | 引擎：提案 026 的 `setMonitorSource`（耳机出口 = 所选总线，默认 Master；有独听时听独听的）+ `borrowMasterForMonitor`（开着且有独听时 Master 出口放耳机总线，录制 / 推流拿的 Master 消费者流不受影响）（W1-D3）；App：建 session 与设置页改开关时都设 `AudioEngine.borrowMasterForMonitor`、"引擎支持后生效"那句撤掉（G8b 胶水）。"监听 Master / Bus A / B"菜单项的接线是 J7 功能，归 App 会话（上表 S3） | `testMonitor_monitorSourceSelectsBusForHeadphoneOutput` / `testMonitor_borrowMasterChannelsWhileSolo`（Master 出口上 0 号 1 kHz < −80 dB、消费者队列仍有）/ 集成 `testMonitor_monitorSourceFromState_andBorrowMasterWhileSolo`；App `AudioDeviceRevampTests` | reports/w1-audio-3.md §1.3；reports/G8.md §4.3 |
| S2 | X12（设置窗） | 设置窗（W5-J）在前时快捷键不派发 | `SettingsWindow` 的 keyHandler 先录键、不吃再交 `controller.session?.control.handleKey`（W5-M，2026-10-10 裁定 ⑦） | `TransitionColumnTests.testUI_settingsWindowForwardsHotkeys`（设置窗在前按空格 = Cut；快捷键页录键中按空格 = 录进去、不切） | reports/w5-transition-slots.md |
| S2 | — | App 里扬声器 / 耳机监听比画面晚 L（开着 Master 压缩 / 限幅时 5–35 ms）；开录起点是拍点、L > 0 时视频轨从 L 开始（AVFoundation 在 0…L 读出一帧黑） | W1-B4 的 App 接线三行一起接（渲染器 `videoDelayHeadroom` / `displayDelayHistory`、`renderer.displayDelayProvider`（弱捕获）、`audio.engine.videoDelay = engine`，session 收尾解开引用环）+ App / headless 的 `RecordingStart` 改成拍点 + 当时的视频延后（提案 028 第 3 条；headless 等 Master 效果链装好确认再读 `videoDelayTarget`）（G8b 胶水） | headless `AVCompensationTests.testA2_videoDelayMode_recordingStaysAligned`（videoDelay 11 对整秒配对 0.000 ms、不在整秒 0、**视频轨从 0 起**，去掉了 `--start-tick −2` 的变通）、App `AudioWiringTests.testAudio_engineStartStop20TimesNoCrashRSSFlat`（接线不成环：20 轮 RSS 325 → 327 MB）；监听同步的人耳项在 docs/checklists/G8.md §9 | reports/G8.md §4.3 |
| S2 | — | 兼容层 `Cut Input=n`（及 HTTP 批量 `[setPreview(n), cut]`）在转场进行中落不到 n | 定口径 (a)：转场进行中带 Input 的 Cut 回 409 NotConfigured、一条都不发；不带 Input 照旧做完当前转场（W5-M，G6 追加 ①） | `testC5_cutWithInputDuringTransitionIsRefused`、`HTTPTests.testC5_http_transitionSlotsAndCutDuringTransition` | reports/w5-transition-slots.md |
| S3 | — | 外部显示"每块屏一路"的规则两份实现并存 | 菜单的 `ExternalOutputMenuBuilder` 改成转调 `ExternalDisplayRouting`（净 −34 行）（W5-N，2026-10-10 裁定 ④ 顺带） | 原有两组用例照过 | reports/w5-playback-status.md |
| S2 | X14 / X15（契约半） | 录制 `container` 字段有效但没人读；录制来源 PVW / 多画面照录 PGM | 提案 023 二：`container` 标废弃（缺键 = mov、照读照写、不加 @available）；录制来源按 (a) 写进口径（source 只认 program / input(n)，preview / multiview 按 program 录）、校验器不拒（P5-2） | `Contracts023Tests.test023_2_*` | reports/p5-contracts-2.md |
| S3 | X18 | Stinger 槽没选输入时点转场按钮 = 一次延迟硬切 | 转场列主体 / T-bar 行菜单 / 菜单栏"切换 › 转场 n"先弹这个槽的输入选择、不执行（W5-M）；快捷键 / MIDI / 兼容层 / Stream Deck 仍照契约默认执行（上表 S3，等用户定） | `testUI_stingerSlotWithoutInputOpensMenuInsteadOfExecuting` | reports/w5-transition-slots.md |
| S3 | X28 | 状态行两个输出都开时只看得到录制的码率 | "编码滞后跳帧 n · 录制 x · 推流 y"分开写、多路给码率最低的那一路（退避中的推流码率 0 就是它）、跳帧给最多的（W5-N） | `testUI_statusLineSeparatesRecordAndStreamBitrate`、`StatusLineTests` | reports/w5-playback-status.md |
| 功能 | 01a C1–C4 / C7 / C8 / N6 / O1；Q01 (A) / Q05 (a) / Q07 / Q29 / Q37 | 转场槽：转场列按槽（主体 + ▾、当前槽蓝条、Stinger 未选输入先弹选择）、T-bar 横放（97% 提交回弹、行程 120 pt）、FTB 时长、菜单栏"切换 › 转场 1–4"点了就做、⌥1–⌥4 = 执行转场 n、兼容层 Transition1–4 / SetTransitionEffect1–4 / SetTransitionDuration1–4 / Stinger1、Stream Deck 槽按钮（颜色跟当前槽）、选动作面板的槽动作与 `setInputAudio` 总线路由勾选 | W5-M（提案 020，P5-2 落契约） | `TransitionColumnTests` ×14、`TransitionPanelTests` ×3、`ActionPickerTests`、SwitcherControl `TransitionSlotActionTests` ×3 / `testHotkeys_optionDigitExecutesSlot`、VMixCompat `testC5_transition2ExecutesSlot` / `testC5_setTransitionEffect3MapsToSlot` 等、Stream Deck `node --test` 9 / 9 | reports/w5-transition-slots.md |
| 功能 | 01a D5 / L11 / E10 / K3 / K9；02 V04 / V11；2026-10-10 裁定 ① ② ③ | 文件播放控制（格子 ⏮ ▶⏸ 🔁、右键"切上 PGM 时从头播"、来源一节改播完 / 速率当场生效、播完再开循环当场接着循环）、推流 / 录制状态面板（读 Stats.encoder 四字段 + `video_delay_ms`、事件记录）、底栏 / 工具条 / 录制 ▴ / ISO 表的时长（读 uptime_s、不在 App 里计时）、推流鉴权"写法"二选一（查询串，打码）、025 字段的 App 侧（读写走字段、Show.load 后搬旧 extra 键）、36 个无人用的 strings 键清掉 + 反向检查用例 | W5-N（提案 021 / 022 / 025） | `PlaybackStatusTests` ×8（第 0 帧晚 3 拍）、`FileInputTests.testInput_fileEndActionChangesInPlace`、`OutputPagesTests`、`LocalizationTests.testL10n_everyKeyInTableIsReferenced` | reports/w5-playback-status.md |
| 功能 | 提案 024 (b) / 026；G6 追加 ①–⑥ | 自写 C 压缩器 `compressor`（Giannoulis 静态曲线 ±0.008 dB、0 组延迟、冲激法自测、与 dynamicsProcessor 二选一占同一格）、`peakLimiter.ceilingDb`、监听来源 / 借 Master（上面 X09 行） | W1-D3 | `testA_compressor_ratioCurveWithinHalfDb` / `measuredLatencyEqualsReported` / `attackReleaseTimeConstants` / `sharedImplementationOnBusSlot`、`testA2_compressor_latencyCompensated`、`testA_busEffects_limiterCeilingDb` | reports/w1-audio-3.md |
| S3（文档） | X30 X32–X34 X53 的手册半；02 X53–X57 | 手册与实现对不上；手册不随包 | docs/user 中英按 86–98 全部重写并两轮逐句对代码核对（45 处改正）、设置页新增、随包 HTML 手册（`docs/tools/build-help.py` → `App/Resources/Help/`，帮助 › PlusMix 使用手册不再灰、添加输入横幅"看说明"直达）、快捷键表按 96 重排、兼容层 / tally / 样例 / 发布文档定点修正（W4-C2）；`make manual` + `scripts/check-help.sh`（G8b） | check-links 180 个 Markdown、`build-help.py --check`、App 帮助菜单 / 横幅 / 本地化 / Release 15 条、三个样例 Show 在 App 里打开 | reports/w4-docs-2.md |

### 2026-10-10 G8a 合入（P5 契约落地四 / W2-C3 / W1-B4）已修（不再出现在上表；每条有先红后绿的用例）

| 原级别 | 编号 | 现象 | 修在 | 用例 | 报告 |
|---|---|---|---|---|---|
| S1 | — | `MIDIHost.sync` 偶发崩溃（Swift 运行时 "non-escaping closure has escaped"）：闭包交给宿主线程的 run loop 块里先 `done.signal()`，块被释放前调用方已离开 `withoutActuallyEscaping`，Debug / Release 都 trap；App 起停 session（新建 / 打开节目、改格式、退出）都走它 | 闭包放进私有 `SyncCall`，CF 块只捕获它，宿主线程跑完先清掉闭包再 signal；`sync` 签名与四个调用处一字不动（W2-C3，问题单的改法 (b)） | `MIDIHostTests.testC_midiHostSync_stressNoTrap`（修前独立进程 10 遍红 9，修后 30 遍 0；W2-C3 自己 Control 全包 ×3、App 全量 ×2 0 崩）；G8a：P5 合入那一轮还没合它时 Control 全包就崩了一次（`xctest-2026-10-10-232027.ips`），合入后 Control 全包 ×3 0 崩、整仓 make test 的 App 全量 + App 第 2 遍（共 448 个用例次）0 崩——加上 W2-C3 自己的 2 轮 = G7 §7 要的"连跑 3 轮不再出现" | reports/w2-control-3.md |

### 2026-10-04 第五波骨架（G7 合入 W5-F…W5-L）已修（不再出现在上表；每条有先红后绿的用例，用例在各分支报告 §2）

| 原级别 | 编号 | 现象 | 修在 | 用例 | 报告 |
|---|---|---|---|---|---|
| S2 | X21 | "叠加…"是 transient 浮层，点主窗口就关 | 独立非模态叠加设置窗，四个入口（底栏、转场列 / 格子 Overlay 右键、切换 › Overlay ▸ › 叠加设置…），只开一个；整幅 / 画中画二选一、时长按秒、新节目默认淡入 0.5 s（W5-K） | `OverlayRevampTests` | reports/w5-app-panels.md |
| S2 | — | W5-B 的副作用：推流一路永远起不来时底栏主体只会"重试它"、停不了正常的路 | ▴ 每个目的地一项单路起停 + "全部停止"（先确认）；主体口径不变（W5-F） | `BottomBarSplitTests` | reports/w5-app-bottom-bar.md |
| S2 | 凭据① | 底栏推流提示原样显示地址含密码 | 菜单与提示只写名字 + 打码地址（`StreamURLRedaction.redact(url:)`）（W5-F） | `BottomBarSplitTests` | 同上 |
| S1（App 半） | X08 | Bus A / B 没有出口 | 设置 › 音频设备 每条总线选声道对 → 建引擎时进 `outputChannelMap`；两条总线不共用一对；"恢复设备默认"（W5-K） | `AudioSettingsRevampTests` | reports/w5-app-panels.md |
| S1（三扇窗） | X12 | 输入 / 叠加 / 音频设置窗在前时快捷键失灵 | `PanelWindow.keyHandler` → 快捷键表（`forwardHotkeys`）（W5-K）；设置窗那一半仍开着 | `PanelsRevampTests` | 同上 |
| S2 | X33 | 远程控制监听地址只能手填，不知道别的机器连哪 | 远程控制页：API / 兼容层各"仅本机 / 允许局域网" + 可访问地址与复制、没 token 黄字、兼容层 HTTP 端口可改（W5-L） | `W5LMiscTests.testPanels_remoteControlPageShowsReachableAddress` | reports/w5-app-misc.md |
| v1 缺口 | X32 | App 不起 tally 流 | 设置 › Tally：WS /tally + GET /tally，默认关、端口 = API + 1，停机顺序 tally → API → 引擎（W5-L） | `testTally_appServesReadOnlyStream` | 同上 |
| 建议 | N02 / P1 / E5 / E8 | 界面内提醒、防睡眠 / App Nap、统计窗、界面锁 | 状态行提醒条 + PGM · FTB 慢闪；引擎运行时 `beginActivity`（两条电源断言）；只读统计窗（重置只记基线）；底栏最右的锁拦主窗口点击、快捷键 / 菜单 / API 照常（W5-L） | `W5LMiscTests` ×6 | 同上 |
| 功能 | 01a A / B / O | 工具条、监视器齿轮与右键、菜单栏重排（"切换"只选不执行、帮助、"打开上次退出时的节目"） | W5-G | `ToolbarMenuTests` ×10 | reports/w5-app-toolbar.md |
| 功能 | 01a D / G13 / G14 / D11 | 格子两行按钮与右键、分类、搜索、占位格、拖放、图片多选与改了自动换上、缩略图三档 | W5-H | `InputStripTests` ×10 | reports/w5-app-input-strip.md |
| 功能 | 01a F8 / F9 / K4 / K6–K10 / L3 / L5–L10 / L12 / M5 / M7 | 输出总览、录制输出列表与参与录制、ISO 表、推流服务预设 / 质量 / 鉴权 / 合计上行、外部显示每屏单选、多画面格子编辑 | W5-I | `OutputPagesTests` ×11 | reports/w5-app-output-pages.md |
| 功能 | 01a F1 / F4–F7 / N1–N3 / N5 / Q29 | 一个"设置"窗（侧栏两组、即时生效、待应用、导出 / 导入 / 恢复默认、高级页）、选动作面板、默认键表 ⌥1–⌥4 / ⌃1–⌃4、控制层可绑动作 | W5-J | `SettingsWindowTests` ×5、`ActionPickerTests`、SwitcherControl `ControlActionTests` | reports/w5-app-settings-actions.md |
| 功能 | 01a G2–G12 / H1 / H3–H9 / J2–J8 | 添加输入面板（分组、记忆、横幅、最近文件、文件信息）、输入设置窗（分节、本路画面、取色、复位、复制）、音频设置窗与调音台重排、音频设备页 | W5-K | `AddInputRevampTests` / `InputSettingsRevampTests` / `AudioSettingsRevampTests` / `PanelsRevampTests` | reports/w5-app-panels.md |

### 2026-10-02 第五波止血（G6 合入 W5-A…W5-E）已修（不再出现在上表；每条有先红后绿的用例，用例在各分支报告 §2）

| 原级别 | 编号 | 现象 | 修在 | 用例 | 报告 |
|---|---|---|---|---|---|
| S0 | X01 | 底栏"录制""推流"再按一次把所有路一起停掉、不确认 | 停止前 NSAlert sheet"确定停止录制（n 路）？"（逐路列状态；回车不落在"停止"上、Esc 取消；偏好设置 › 操作确认 可关；快捷键 / MIDI / API 一律不问）（W5-B） | `LiveSafetyTests.testUI_stopRecordAsksConfirmation`、`testHotkeys_stopRecordNeverAsks` | reports/w5-app-safety.md |
| S0 | X02 | 起不来的推流路仍算"在跑"，再点"推流"把正常的几路一起停；改对地址不重试 | 按钮按最差一路汇总（"● 推流中 n/m" / 橙"k 路异常" / 深红）、主体只重试起不来的路、设置改对自动重试、Stats.encoder 报 failed、原因写成人话（W5-B） | `testUI_streamRetryDoesNotStopHealthyRoutes`、`testUI_streamButtonAggregatesWorstState`、`testUI_streamStateTextLocalized` | 同上 |
| S0 | X03 | 新建 / 打开节目直接停录制推流、丢未保存改动 | 先问"会停止 n 路录制、m 路推流"、再问保存 / 不保存 / 取消（Q67 (a)），任何一步取消都不动；关主窗口 = 退出那一问；`isDocumentEdited` 按"节目内容"判（W5-B） | `testUI_newShowWhileLiveAsksConfirmation` | 同上 |
| S0 | X04 | 偏好设置三个"应用"直接换引擎、停录制推流、关窗 | 三个都先问（sheet 挂在偏好设置窗上）；换完窗口不关、按新 session 重读（W5-B） | `testUI_applyFormatKeepsPreferencesWindowOpen` | 同上 |
| S0 | X05 | 推流页删除正在推的目的地不确认、立即断流 | 在推的那一段地址 / 密钥 / 编码禁用、"删除目的地"灰掉；模型层也拦；起不来的那一段不锁（W5-B） | `testUI_streamingDestinationLockedWhileLive` | 同上 |
| S1 | X06 | **总线**效果链界面能调、引擎不读 | W5-C 接进混音器：连续 parametricEQ 合成一个 AUNBandEQ 格（≤ 16 段）、压缩 / 限幅各一格，换格先关再等实时线程确认，处理延迟在泵里补到音频 PTS；W5-B 的"尚未生效"标签对总线撤掉（`busEffectsApplied = true`，G6 合并时按 W5-C §5 第 8 条翻 87 的用例） | `BusEffectsTests.testA_busEffects_eqChangesResponse` / `limiterHoldsCeiling` / `bypassIsTransparent` / `topologyChangeNoDropout` 等 15 条、`EffectChainTests` 14 条、App `AudioEffectsTests` ×4、`HonestUITests.testUI_effectChainMarkedNotEffectiveUntilSupported`（总线半翻成已生效） | reports/w5-audio-bus-effects.md |
| S1 | X10 | 快捷键编辑器把"其他命令"静默存成 Cut | 不再兜底；"其他命令"没有命令时保存报错不写文件；每行"编辑 JSON…"（快捷键 / MIDI 共用）（W5-B） | `testHotkeys_otherCommandNotRewrittenToCut` | reports/w5-app-safety.md |
| S1 | X11 | 底栏推流 / 录制状态文字不可信（只看第一路、重连次数不对、英文原样） | 状态全走本地化表；"连接中（第 n 次）"/"重连中（第 n 次）"按真实尝试次数、连上过才叫重连；"推流 n 已开始"连上才提示（W5-B） | `testUI_streamStateTextLocalized`、`StreamWiringTests.testStream_10sToLocalMediaMTX_framesContinuous`（X37 断言） | 同上 |
| S1 | X13 | 删除输入不确认、删 PGM 即黑场 | 在 PGM / PVW / 开着的叠加 / Stinger / 正在录的 ISO 上时先确认并逐条写后果（W5-B） | `testUI_deleteInputOnProgramAsksConfirmation` | 同上 |
| S2 | X19 | 转场进行中 setPreview / setProgram 不拦 | reducer 对 `transition.isActive` 原样返回（回执 applied = false）；T-bar 推到一半算进行中；契约文字提案 023 第一节已批、P5 落地（W5-E） | `ReducerTests.testV6_setPreviewRejectedDuringTransition` / `testV6_setProgramRejectedDuringTransition` / `testV6_setPreviewAcceptedAfterTransitionCompletes` / `testV6_tbarPartialCountsAsActive`；`APIServerTests.testAPI_wsEvents_…`（API 层同口径） | reports/w5-core-transition-guard.md |
| S2 | X25 | RTMP / RTMPS 地址里的 user:pass@ 被丢 | StreamDestination 保留 userinfo（只转义一次）；Adobe（FMLE 兼容）鉴权前两轮自己做，HaishinKit 只拿不带 userinfo 的地址（它自带那套输错密码会狂连）；日志 / 错误 / 诊断包打码（W5-D） | `StreamDestinationTests.testE_streamDestination_keepsUserinfoInConnectURL` / `escapesReservedCharsOnce`、`StreamAuthMediaMTXTests` ×4、`StreamAuthTests` ×8、App `ReleaseTests.testRelease_redactionHidesURLUserinfo` | reports/w5-stream-auth.md |
| S2 | X14（界面半） | 录制"容器 .mp4"选了没用 | "容器"下拉与"停止后转 MP4"合成一个单选、只写 `remuxToMP4`、`container` 照读不写（契约半归 023）（W5-B） | `PanelTests.testPanels_recordFormatChoiceWritesRemuxOnly` | reports/w5-app-safety.md |
| S2 | X30 | 退出静默写回已打开的节目文件 | 退出先问保存；"不保存"原文件字节不变、LastSession 照存（W5-B） | `testShow_quitDoesNotOverwriteOpenedFileSilently` | 同上 |
| S2 | X20 | 外部显示菜单勾不看开关、再点删配置、"关闭"= 删除 | 勾 = enabled、再点 = 关（配置留着）、删除单独一段、"全部关闭"只关不删（W5-A） | `BottomBarPopupTests.testUI_externalMenuFlatChecksEnabledAndTogglesOutput` | reports/w5-app-visual.md |
| S2 | X22 | 16 个编号用满后"添加"照样能点 | 满了置灰 + 红字提示（W5-B） | `ShortcutAndShowTests.testUI_addInputFullShowDisablesAdd` | reports/w5-app-safety.md |
| S3 | X42 | 保存后窗口标题变代码名 | 一处出标题"PlusMix 0.1.0 — 名字"，未保存用关闭按钮上的点标（W5-B） | `testUI_windowTitleUsesProductNameAfterSave` | 同上 |
| S3 合规 | X59 X62 | 关于面板没有 NDI® 声明与开源许可入口；偏好设置里出现竞品模块名 | 关于面板 credits（版本 / Apache 2.0 / NDI® 原句 / "查看开源许可"链接）、NDI® 五处首次出现；兼容层标题去掉模块名（W5-A）；`scripts/lint-rules.sh` 对 *.lproj/*.strings 不再放行模块名 token（G6） | `CopyComplianceTests` ×5；`make lint` | reports/w5-app-visual.md |
| S3 | 目视 | 转场列没对齐、底栏菜单 / 叠加层伸出窗口、分栏挤输入条 / 调音台、主窗口位置不记、输入设置窗重叠、PVW 对比度、调音台不贴顶、数字分组、声像滑块填充等 | W5-A（prompt 86 点名的全部） | `TransitionColumnTests` ×8、`BottomBarPopupTests` ×2、`MainWindowLayoutTests` ×5、`VisualDetailTests` ×5 | 同上 |

### 2026-09-28 发布前已修（不再出现在上表；每条有先红后绿的用例）

| 原级别 | 现象 | 修在 | 报告 |
|---|---|---|---|
| S1 | 视频文件输入**循环播放**时内存每圈涨约 0.5 MB（W4-A 长稳 S2 实测 60.8 MB/h，门槛 ≤ 10）：文件解码线程没有自动释放池 | 解码 / 推帧线程每轮迭代包 `autoreleasepool`（W2-A3）：用例修前 0.465 → 修后 0.017 MB/圈；**2026-10-12 用户终端 8 小时长稳复验通过：S2 2.46 MB/h（RSS 1043 → 1166 MB，文件 + 摄像头 + 8 路合成 + 录制 + NDI + 两路推流）**，这条到此销号 | reports/w2-inputs-3.md；reports/W4-soak-8h.md；reports/G8.md §5 L4 |
| S2 | ProRes 等重片段循环点每圈空一拍、推帧线程晚醒自旋 | 离尾预开下一圈 reader、音频断供按周期轮询（W2-A4） | reports/w2-inputs-4.md |
| S2 | 文件输入带音频、高速率（≥ 4 帧/拍）推帧线程饿死 | 队列深度随速率、解码侧丢落后帧、FIFO 三态不阻塞（W2-A4） | reports/w2-inputs-4.md |
| S2 | 推流开始时握手期间的帧 / 包直接丢、落盘从连上那一拍才开始；长稳那 47 包是音频引擎早起 1 s 被起步对齐裁掉、错在计进 audioDropped | start 起就缓冲、两轨从第一个送出的关键帧同一原点起送（W2-D2） | reports/w2-stream-2.md |
| S2 | App 素材相对路径按进程工作目录解析（Finder 起的 App 打开样例字幕 / 台标变占位） | 相对节目文件所在目录解析，节目文件仍存相对路径（W3-E5） | reports/w3-app-6.md |
| S2 | App 打开节目后第一秒约 470 ms 停顿、missed_render 28、已注册的路丢 3 s | 根因是先定 t0 再冷启动控制层（MIDIServer 686 ms）：引擎加 warmUp / clockStartLag（W1-B3），App 预热完再定 t0（W3-E6）；冷启动 clockStartLag 500 ms → 0 | reports/w1-core-3.md、reports/w3-app-7.md |
| S2 | 换过节目之后 MIDI 热插拔通知收不到 | CoreMIDI 通知放到进程级常驻线程 + 永不销毁的锚客户端（W2-C2） | reports/w2-control-2.md |
| S3 | 底栏状态行"编码跳帧 / 码率"按输出顺序对号 | 按 encoder[].output 查输出类型（W3-E5） | reports/w3-app-6.md |
| 工具 | frameprobe av 内存随录像长度线性涨（1 小时 41 GB） | 根因是多声道音频每块 reserveCapacity 的 O(n²) 重拷；10 分钟 7.6 GB → 172 MB（W1-A4） | reports/w1-testkit-4.md |

### 发布工程（不是产品缺陷，但这份候选构建有）

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S1（发布） | 没有 Apple Developer Program 账号：构建只能 ad-hoc 签名——Gatekeeper 拦（"无法验证开发者"）、公证 / staple / spctl 不通过、虚拟摄像头扩展装不上、Sparkle 不能装更新 | 所有用户 | 第一次打开被拦后到 系统设置 › 隐私与安全性 › 底部"仍要打开"（macOS 15 起右键 → 打开对未公证的 App 不再管用）；虚拟摄像头 / 自动更新在正式签名前用不了 | reports/w4-release.md §2 BLOCKED 表；docs/release/signing.md | 用户：注册账号 + Team ID + Developer ID 证书 + notarytool 凭据 → `DEVELOPMENT_TEAM=… make archive` → docs/release/checklist-first-signed-run.md。**发布阻塞项** |
| — | bundle id 已定为 `com.plusmix.switcher`（用户 2026-09-28 定前缀 com.plusmix，G5 用 set-bundle-id.sh 切换；Stream Deck 插件 UUID 与之一致）；产品名定为 PlusMix，改名归 W4-D（prompt 75），发布前完成 | 发布身份 | — | docs/release/bundle-id.md | 已解决（bundle id）/ W4-D（改名） |
| S2 | Sparkle 更新源 / 公钥未配置（`SPARKLE_FEED_URL` / `SPARKLE_PUBLIC_ED_KEY` 为空）：这份构建不会检查更新，偏好设置里写"未配置" | 所有用户 | 手动下载新版本 | docs/release/sparkle.md | 随远程仓库与 bundle id 一起定 |
| S2 | 依赖钉在 swift-collections 1.6.0（1.7.0 要 Swift 6.4 运行时，macOS 15 / 26 上一起就崩）；本版本只在 macOS 27.0 上验证过，15 / 26.x 没有机器验（BLOCKED-机器） | macOS 15 / 26 用户 | — | docs/release/dependencies.md；reports/issues/W3C2-g5-swift-collections-1.7-dyld-crash.md | 借一台 26.x / 15 机器各起一次 App 与 frameprobe |

### 硬件 / 环境限制（不是缺陷，但用户会撞到）

- 只有 Apple Silicon 构建；最低系统 macOS 15；本版本的全部测试在 M5 Max / macOS 27.0 上跑，阈值按 M1 Air 8 GB 定但没有 Air 可验（S4 热降频 BLOCKED-机型）。
- 虚拟摄像头需要 App 放在 /Applications 并在系统设置里允许扩展（macOS 的系统扩展规则）；ad-hoc 构建装不上（见上表）。
- 屏幕录制没有 usage key，第一次用屏幕输入要在"系统设置 → 隐私与安全性 → 屏幕与系统音频录制"里手动授权；摄像头 / 麦克风授权归属于启动 App 的那个进程（从终端起就是终端）。
- 从源码编译且没装 NDI SDK for Apple 的机器：NDI 输入 / 输出标 `unavailable`；发布包随包 libndi.dylib（THIRD_PARTY/NDI/）。
- 真设备上没验过的：DeckLink（只有 SDK 模拟设备）、UVC 采集卡、USB 摄像头、多于 2 路的 USB 音频接口 / 聚合设备、另一台机器发的 NDI 源、A5 监听延迟回环、真 Companion / Stream Deck 硬件——docs/testing/设备兼容性.md 只有开发机的行，用户手册里这些接法按各会话报告写。

### 测试与工具（不影响产品，影响谁跑测试）

- 几条依赖窗口 / 时序的用例在机器忙或窗口被盖住时偶发红，单独重跑都过：`DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`、`ExternalTests` 的 `DisplayStatsTests`、App 的 S7 两条与 `ThumbnailRateTests`、NDI 回环两条计时断言、`ThrottleProxyTests`；`ToolbarMenuTests.testUI_inputSettingsMenuTitleNamesInput`（G8a 整仓那一轮 `performActionForItem` 之后没开出输入设置窗、红一次，单独复跑与第二遍全量都绿）与同类的 `testUI_toolbarItemsMirrorMenuActions`（P5-2 2026-10-11 02:4x 在本分支和干净 main 上都红、同一断言"关闭全部外部显示"3 s 内没生效；reports/issues/P52-app-toolbar-toggle-external-off-red-on-main.md）——两条都是菜单动作走响应链之后没落地、换个时段又绿，怀疑测试宿主在协作式激活下不是前台（G7 §10 第 12 条）；归 App 会话查，reports/G8.md §10 第 7 条。
- 七张多画面参考图是 macOS 27 的中文字形，26.x 机器上按 PSNR ≥ 40 dB 看（reports/issues/P4-w3-compositor-multiview-cjk-labels-macos27.md）。
- L5 的"退步 > 10%"规则在 V3（微秒量级）与 CPU / GPU 上会因运行间起伏误报，绝对下限（`scripts/perf/regression.json` 的 `floor`）等用户定（reports/w4-soak.md §4 第 2 条）。
- 长稳 / 性能脚本在 Claude 会话（非交互）里不接摄像头、不采 powermetrics、Instruments Leaks 附加不上；在用户终端里跑才是完整负载（reports/w4-soak.md §3）。
- ~~`MultiviewMetersTests` 两条"逐像素相同"2026-10-01 起在本机红~~ **已解（2026-10-03）**：用户定改成与 `V8ReferenceTests.compare` 同一套 PSNR ≥ 40 dB / SSIM ≥ 0.98 判法（G6 改 `assertEqualsReference`，参考图没动），两条在 26A428 上 50.8 / 51.7 dB 绿。以后系统字体资源变化只影响名字标签几个像素，不再红。
- **StreamingTests 的 MediaMTX / 代理端口与 `$TMPDIR/switcher-streaming-tests/` 输出目录是写死、共用的**：几个会话同机并行跑会互相踢掉（`errno 48`、`closing existing publisher`、录制目录被对方删）；要错开跑或给端口 / 目录加进程号偏移（reports/issues/G6-w2-stream-streamingtests-shared-ports-and-output-dir.md）。App 测试宿主的 UserDefaults suite（`com.plusmix.switcher.tests`）与 `$TMPDIR/switcher-tests/` 同理（reports/w5-app-safety.md §5 第 2 条）。
- App 测试宿主的 UserDefaults suite 2026-10-03 起**按构建路径分开**（W5-K，`AppController.testDefaultsSuite` = `com.plusmix.switcher.tests.<hash>`），测试宿主启动时不读存下来的 API token、R7 用 defer 还原（W5-L）：G7 第 1 轮（只合了 92）还撞上旧 suite 里别的 worktree 留下的 `apiToken`（两条 401，`defaults delete com.plusmix.switcher.tests apiToken` 后过），98 合入后源头没了；`$TMPDIR/switcher-tests/` 仍共用。
- `xcodebuild … -quiet` 偶发只报一行 `error: the following command failed with exit code 0 but produced no further output`、不编（W5-H / W5-J 都撞过，`make gen` 之后或别的会话在编时）；去掉 -quiet 重跑一次就过。
- `MainWindowLayoutTests.testUI_mainWindowRestoresSavedFrameInsteadOfCentering` 在系统焦点窗口落在外接屏上时必红（存档按 NSScreen.main 换算，W5-F §5 第 11 条、W5-L §2.3）；`NDITests.NDILoopbackTests` 的 pts 单调断言在 SDK 重复送一帧时红（G7 第 5 轮一次、单独复跑一次红一次绿）——先单独复跑再判。
- gate4 要在没有别的引擎 / xctest / xcodebuild 的机器上跑才作数（两个引擎并行 V1 推到 10 ms 以上、V2 丢上千帧；V6 的判定要求第 1000 拍之前没丢过帧）；查"别的引擎"用 `ps -axo comm= | grep '/switcher-headless$'`，别用 `pgrep -f`（等待脚本的命令行里也带这几个字）。`scripts/gate4.sh --checkpoint G6` 起运行报告不再改写 reports/G4.md 与 g4 基线（G6）。
- 显示类用例（SwitcherRender `DisplayDecouplingTests`、Outputs `ExternalTests.DisplayStatsTests`、App `DisplayLedgerAppTests` / `ThumbnailRateTests` / S7 两条）在屏幕锁定、窗口被别的 App 整块盖住、机器忙时红，单独重跑都过（W5-A / W5-B / W5-C 报告 §5）。
- 带视频延后的录像：**G8b 起 App / headless 的开录起点按节目输出时间线**（拍点 + 当时的 L），录出来的文件第一帧 = 第 0 拍、视频轨从 0 起，`frameprobe av` 按默认 `--start-tick 0` 就对（W1-B4 时要给 `−round(L × fps)` 的变通已去掉）；录制中途改 Master 效果（L 变了）之后 frameprobe 的拍号仍会整体错开 ΔL（> 半帧时整秒判定失效，配对本身仍对齐；reports/issues/W1B4-w1-testkit-frameprobe-delayed-video-start.md，归 W1-A 系）。headless 的起点要等音频引擎把 Master 效果链装好、确认之后才读得到 L（`videoDelayTarget`），HeadlessRun 最多等到 t0 − 150 ms。
- `SwitcherInputsTests.FileInputTests` 的两条解码计时用例（`testFile_60fpsProgram_frameNumbersConsecutiveFromZero`：60 进 60 帧号连续、推帧线程不该被解码器饿；`testW2A4_highRate_withAudio_keepsUp`：8 倍速带音频饿 ≤ 3 拍）在桌面忙（Photos / WindowServer / Spotlight 抢核）时偶发红：G8b 2026-10-11 六遍里两遍各红一条、单独复跑都绿（reports/G8.md §5 L1）；先单独复跑再判，跑 gate4 / perf 前的 `ps` 也看桌面进程。
- frameprobe 多文件 A4（`avMulti`）在闪光落在半秒的事件上（59.94 fps 源在 PGM 时）各文件各自配"最近的 click"，几十微秒的差（±100 ppm 的消费者流）就配到不同的秒、报 1 s 极差——G8b 的 gate4 误报 999.979 ms，按整秒配对五个文件实际 0.187 ms；问题单 reports/issues/G8b-w1-testkit-frameprobe-a4-halfsecond-click-tie.md（W1-A 系）；修好前看到 A4 ❌ 先自己按整秒配对算一遍，gate4 用 `--waive 'A4 多文件对齐=…'` 重出报告；修归 **113 W1-A5**（`w1-testkit-5`）。
- `make lint` 2026-10-11 起多一条 `scripts/check-help.sh`（`docs/tools/build-help.py --check`）：改了 docs/user 没跑 `make manual` 重生成 App/Resources/Help 就红（产物入库，project.yml 的 Help folder reference 把整个目录带进包）。
- L1 内部延迟的判定**扣掉同一行 stats 的 `video_delay_ms`**（测试标准 §3，用户 2026-10-11 定，阈值 ≤ 3 帧不动；G8b 改）：gate4 运行报告多一行"L1 内部延迟（扣视频延后）"（avg 与每秒最大值的 p99 都 ≤ 3 帧，可 `--waive`，原来运行报告里没有 L1 行、只有 NDI 回环那条判）、`scripts/gate4-ndi.sh` 与长稳报告同口径、`switcher-headless summarize` 的 key 多 `l1_net_avg_ms_max` / `l1_net_max_ms` / `video_delay_ms_avg` / `video_delay_ms_max`。gate4 / perf 场景不带 Master 效果，L = 0，数字不变。
