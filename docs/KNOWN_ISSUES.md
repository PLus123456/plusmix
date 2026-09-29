# 已知问题

模板 docs/release/KNOWN_ISSUES-template.md；每次发布由 G5 更新，发布说明里列出（测试标准 §6 发布门槛第 5 条）。
每条一行，按严重级排（§6：S0 直播中断类、S1 功能错但节目能继续、S2 有绕过办法、S3 外观文案）。"来源"是问题单（reports/issues/）或报告章节；"计划"是归属会话。
S0 / S1 不许出现在已发布版本的表里——0.1.0 候选的 S1（文件输入循环泄漏）2026-09-28 已修、等 8 小时复验；这个版本**还没有发**（reports/G5.md 的判定与阻塞项）。2026-09-29 界面对照调研（docs/ui-study/）又查出 S0 五条、S1 八条（下面第二张表），按 Q68 (a) 在 0.1.0 放行前修。

## 0.1.0 候选（分支 release/0.1，2026-09-28 G5 判定：不发；S1 已修，重跑 8 小时通过后再判）

### 产品缺陷

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S1 → 已修（等 8 小时复验） | 视频文件输入**循环播放**时内存每圈涨约 0.5 MB（长稳 S2 实测 60.8 MB/h，门槛 ≤ 10）。根因：文件解码线程没有自动释放池。**W2-A3 2026-09-28 已修**（解码 / 推帧线程每轮迭代包 `autoreleasepool`）：用例修前 0.465 → 修后 0.017 MB/圈，fileprobe 120 圈 footprint 从 +65.7 MB 变平 | 修前：短片段循环长时间直播的节目 | — | reports/issues/W4A-w2-inputs-file-loop-memory-and-prores-starve.md §3；reports/w2-inputs-3.md | 正式的 S2 值等用户终端重跑 8 小时 `make soak`；通过后从表里删 |
| S2 | 系统守护进程 / 桌面活动突发时渲染线程成串跳拍（10 分钟里 1–11 拍；V2 仍在 0.02% 以内）。W1-B3 定位：突发让整个进程的非实时线程和 GPU 一起停 100 ms 量级，只有实时线程按时醒，是 GPU 侧；已给渲染完成线程挂实时策略并给每次跳拍归因（GPU 晚 / 完成线程晚），在途深度是契约（≤ 2 帧）没动 | 直播机同时跑重桌面任务 | 直播时关掉其它占 GPU / CPU 的程序（测试标准 §2.8） | reports/issues/G4-w1-core-missed-render-bursts-under-daemon-activity.md；reports/w1-core-3.md §4 | 要不要把在途深度提到 4 等 8 小时长稳的 V2 累计定（契约） |
| S2 | 标准负载（8 路合成源 + 摄像头 + 文件 + 录制 + 2 路推流 + NDI 发送）下进程 CPU 合计约 0.6 个核（8 小时均值 60.1%，门槛 ≤ 60%），其中 NDI SDK 自己的发送线程约 0.25 核（没有接收方也压两路） | 开着 NDI 发送时 | 不需要 NDI 时关掉该输出 | reports/issues/W4A-w2-stream-ndi-send-cpu-share.md；W4A-g5-cpu-multicore-distribution.md | 用户 2026-09-28 定：不阻塞；多核探查项到检查点安排 |
| S3 | 进程里第一次打开节目时连 MIDIServer 冷启动约 0.6 s，在主线程上同步等：界面卡一下（节目时钟不再受影响，W3-E6 已把它挪到定 t0 之前） | 每次启动 App 后的第一次打开节目 | — | reports/w3-app-7.md §3 | W2-C（挪到后台线程） |
| S3 | 已存节目里虚拟摄像头输出的 source 字段可能是 PVW / 输入 n，运行时一律送 PGM（页面已写明"送 PGM"，不再可选） | 旧节目文件 | — | reports/w3-app-5.md §3 第 1 条 | 不处理 |

### 界面对照调研（UIA，2026-09-29）查出、尚未修的

来源 docs/ui-study/02-功能缺口.md §1（63 条，编号 X01–X63）与 reports/issues/UIA-*.md；这里只列 S0 / S1 与影响发布判定的 S2，级别是调研的判断、X01–X05 的 S0 由用户按 04 Q68 (a) 定。"计划"是 docs/plan/prompts/ 里的 prompt 号（落地方案 §8）。

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S0 | 底栏"录制""推流"再按一次就把所有路一起停掉，不确认（X01） | 直播中误触 | 小心 | UIA-w3-app-stream-button-state-and-retry | 87 W5-B |
| S0 | 一路推流起不来（没地址 / 地址不认）时仍算"在跑"：再点"推流"不是重试，而是把正常在推的几路一起停掉；改对地址也不重试（X02） | 多目的地推流 | 全停再全起 | 同上 | 87 |
| S0 | 节目 › 新建 / 打开直接停掉录制推流、丢未保存改动，不问（X03）；偏好设置的三个"应用"直接换引擎、停录制推流、关设置窗（X04） | 直播中误触 | 直播中别碰 | UIA-w3-app-show-switch-and-quit-safety | 87 |
| S0 | 推流页删除正在推的目的地不确认、立即断流（X05） | 直播中改设置 | 先停再删 | 02 X05 | 87 |
| S1 | 总线与每路的音频效果链界面能调、"效果 (n)"会亮，但音频引擎不读，声音不变；手册 / API 文档按已生效写（X06 / X07） | 所有用 EQ / 压缩 / 限幅的节目 | 外部调音台处理 | UIA-w2-audio-effect-chains-not-applied | 87 标"尚未生效" → 88 接总线 → 102 每路 |
| S1 | Bus A / B 没有任何出口（不送设备声道、不进录制 / NDI®）；2 声道输出设备上耳机总线没声，独听 / PFL / AFL 都听不到（X08 / X09） | 返送、耳机监听 | 用 ≥ 4 声道的接口 | 02 X08、X09 | 97 W5-K |
| S1 | 快捷键编辑器把一行切到"其他命令"再保存，静默变成 Cut（X10） | 编辑过快捷键的用户 | 手写 hotkeys.json | UIA-w3-app-hotkey-editor-other-command-becomes-cut | 87 |
| S1 | 底栏推流 / 录制状态文字不可信：只看第一路、重连次数不是尝试次数、英文原样（X11）；效果 sheet 开着时快捷键失灵（X12）；删除输入不确认、删 PGM 即黑场（X13） | 现场 | — | 02 X11–X13 | 87、97 |
| S2 | 转场进行中按数字键 / 点缩略图会换掉正在切的画面（X19；语义已定：拒收） | 用 Fade / Wipe 的节目 | 转场中别按 | UIA-w1-core-preview-program-change-mid-transition | 90 W5-E |
| S2 | 录制"容器 .mp4"选了没用（X14）；录制 / 推流 source 设成 PVW / 多画面照录 PGM（X15）；RTMP 地址里的 user:pass@ 被丢（X25）；退出静默写回已打开的节目文件（X30） | 见各条 | .mp4 用"停止后转封装"；鉴权服务器换入口 | UIA-w1-outputs-record-container-and-source、UIA-w2-stream-rtmp-userinfo-dropped | 87、89、99 |
| S3（发布合规） | 关于面板没有 NDI® 商标声明与开源许可入口；偏好设置里出现竞品模块名"VMixCompat"（X59 / X62） | 发布 | — | UIA-w3-app-ui-copy-compliance | 86 W5-A；lint 规则 91 G6 |
| S3 | 用户手册与实现对不上的九处（磁盘下限、tally 流、重连口径、caffeinate 参数、效果链、容器、跟随视频位置、退出口径、兼容层地址）——**2026-09-29 已按实情改文档**，实现变了再改回 | 读手册的人 | — | UIA-w4-docs-manual-vs-implementation | 103 W4-C2 |

目视问题（转场列没对齐、底栏菜单伸出窗口、最小窗口下格子按钮点不到等 34 条）见 docs/ui-study/03-目视检查.md，归 86。

### 2026-09-28 发布前已修（不再出现在上表；每条有先红后绿的用例）

| 原级别 | 现象 | 修在 | 报告 |
|---|---|---|---|
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

- 几条依赖窗口 / 时序的用例在机器忙或窗口被盖住时偶发红，单独重跑都过：`DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`、`ExternalTests` 的 `DisplayStatsTests`、App 的 S7 两条与 `ThumbnailRateTests`、NDI 回环两条计时断言、`ThrottleProxyTests`。
- 七张多画面参考图是 macOS 27 的中文字形，26.x 机器上按 PSNR ≥ 40 dB 看（reports/issues/P4-w3-compositor-multiview-cjk-labels-macos27.md）。
- L5 的"退步 > 10%"规则在 V3（微秒量级）与 CPU / GPU 上会因运行间起伏误报，绝对下限（`scripts/perf/regression.json` 的 `floor`）等用户定（reports/w4-soak.md §4 第 2 条）。
- 长稳 / 性能脚本在 Claude 会话（非交互）里不接摄像头、不采 powermetrics、Instruments Leaks 附加不上；在用户终端里跑才是完整负载（reports/w4-soak.md §3）。
