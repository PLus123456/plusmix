# 已知问题

模板 docs/release/KNOWN_ISSUES-template.md；每次发布由 G5 更新，发布说明里列出（测试标准 §6 发布门槛第 5 条）。
每条一行，按严重级排（§6：S0 直播中断类、S1 功能错但节目能继续、S2 有绕过办法、S3 外观文案）。"来源"是问题单（reports/issues/）或报告章节；"计划"是归属会话。
S0 / S1 不许出现在已发布版本的表里——下面 0.1.0 候选表里还有 S1，所以这个版本**没有发**（reports/G5.md 的判定）。

## 0.1.0 候选（分支 release/0.1，2026-09-28 G5 判定：不发；S1 修完并重跑 8 小时后再判）

### 产品缺陷

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S1 | 视频文件输入**循环播放**时内存每圈涨约 0.5 MB：30 s 片段循环 8 小时涨 480 MB（长稳 S2 实测 60.8 MB/h，门槛 ≤ 10 MB/h）。根因是文件解码线程没有自动释放池，每圈重开的 AVAssetReader 永远不释放 | 用短片段循环长时间直播的节目（台标 / 背景循环） | 用长片段（每圈固定 0.5 MB，5 分钟片段约 6 MB/h）；不循环的文件不受影响；直播中途换节目重开可释放 | reports/issues/W4A-w2-inputs-file-loop-memory-and-prores-starve.md §3 | W2-A（用户 2026-09-28 定必修）；修后重跑 8 小时长稳。**发布阻塞项** |
| S2 | ProRes 422 HQ 这类高码率片段循环时，循环点每圈空一拍（重复上一圈末帧、跳过新一圈第 0 帧），推帧线程大量晚醒 | 循环播放高码率 ProRes 文件 | 转成 H.264 再用（同内容 H.264 两项都是 0） | 同上 §2 | W2-A |
| S2 | 推流每次开始丢前约 1 s 的音频包（46–47 包），画面一帧不丢：推流头一秒有画无声 | RTMP 推流开始时 | 提前几秒起推流再切正式内容 | reports/issues/W4A-w2-stream-ndi-send-cpu-share.md 第 3 条 | W2-D |
| S2 | App 里图片 / 视频文件输入的**相对路径按进程工作目录解析**，不是相对节目文件：从 Finder / Dock 起的 App 打开带相对路径素材的节目（含 Samples/ 三个样例）时那几路显示"图片不存在"、fps = 0，其余照跑；无界面引擎相对节目文件解析，没有这个问题 | 节目文件里写相对路径素材 | 节目里写绝对路径；或在样例目录里用命令行起 App（Samples/README.md 的临时办法） | reports/issues/W4C-app-relative-media-paths.md | App 会话（约 10 行 + 一条用例） |
| S2 | App 打开节目后的第一秒有一次约 400 ms 的停顿：渲染跳拍约 28 拍、到达余量把已注册的输入丢 3 s 左右，之后恢复 | 打开节目后的头 1–4 s | 起好后等几秒再切上直播 | reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md；reports/G4.md §6.5 | W1-B |
| S2 | 系统守护进程 / 桌面活动突发时渲染线程成串跳拍（10 分钟里 1–11 拍；V2 仍在 0.02% 以内） | 直播机同时跑重桌面任务 | 直播时关掉其它占 GPU / CPU 的程序（测试标准 §2.8） | reports/issues/G4-w1-core-missed-render-bursts-under-daemon-activity.md | W1-B / W1-C |
| S2 | App 换过节目（第一个会话的 MIDI 线程停过）之后 MIDI 热插拔通知收不到，之后插的控制器连不上 | 换节目后才插 MIDI 设备 | 先插好 MIDI 设备再打开节目，或重启 App | reports/issues/W3E-w2-control-midi-hotplug-after-restart.md | W2-C |
| S2 | 标准负载（8 路合成源 + 摄像头 + 文件 + 录制 + 2 路推流 + NDI 发送）下进程 CPU 合计约 0.6 个核（8 小时均值 60.1%，门槛 ≤ 60%），其中 NDI SDK 自己的发送线程约 0.25 核（没有接收方也压两路） | 开着 NDI 发送时 | 不需要 NDI 时关掉该输出 | reports/issues/W4A-w2-stream-ndi-send-cpu-share.md；W4A-g5-cpu-multicore-distribution.md | 用户 2026-09-28 定：不阻塞；多核探查项到检查点安排 |
| S3 | 已存节目里虚拟摄像头输出的 source 字段可能是 PVW / 输入 n，运行时一律送 PGM（页面已写明"送 PGM"，不再可选） | 旧节目文件 | — | reports/w3-app-5.md §3 第 1 条 | 不处理 |
| S3 | 底栏状态行的"编码跳帧 / 码率"按输出顺序对号，输出表与 Stats 个数对不上的一瞬退回不分类型 | 增删输出的一瞬 | — | reports/w3-app-5.md §3 第 2 条 | 下一个 App 会话 |

### 发布工程（不是产品缺陷，但这份候选构建有）

| 级别 | 现象 | 影响范围 | 绕过办法 | 来源 | 计划 |
|---|---|---|---|---|---|
| S1（发布） | 没有 Apple Developer Program 账号：构建只能 ad-hoc 签名——Gatekeeper 拦（"无法验证开发者"）、公证 / staple / spctl 不通过、虚拟摄像头扩展装不上、Sparkle 不能装更新 | 所有用户 | 右键 → 打开能起；虚拟摄像头 / 自动更新在正式签名前用不了 | reports/w4-release.md §2 BLOCKED 表；docs/release/signing.md | 用户：注册账号 + Team ID + Developer ID 证书 + notarytool 凭据 → `DEVELOPMENT_TEAM=… make archive` → docs/release/checklist-first-signed-run.md。**发布阻塞项** |
| S1（发布） | bundle id 仍是占位 `com.example.switcher`（Stream Deck 插件 UUID 是 `com.plusmix.switcher`，两边不一致）；发布后不能改 | 发布身份 | — | docs/release/bundle-id.md | 用户定域名 → 检查点跑 `scripts/release/set-bundle-id.sh <前缀>` 一次提交。**发布阻塞项** |
| S2 | Sparkle 更新源 / 公钥未配置（`SPARKLE_FEED_URL` / `SPARKLE_PUBLIC_ED_KEY` 为空）：这份构建不会检查更新，偏好设置里写"未配置" | 所有用户 | 手动下载新版本 | docs/release/sparkle.md | 随远程仓库与 bundle id 一起定 |
| S2 | 依赖钉在 swift-collections 1.6.0（1.7.0 要 Swift 6.4 运行时，macOS 15 / 26 上一起就崩）；本版本只在 macOS 27.0 上验证过，15 / 26.x 没有机器验（BLOCKED-机器） | macOS 15 / 26 用户 | — | docs/release/dependencies.md；reports/issues/W3C2-g5-swift-collections-1.7-dyld-crash.md | 借一台 26.x / 15 机器各起一次 App 与 frameprobe |

### 硬件 / 环境限制（不是缺陷，但用户会撞到）

- 只有 Apple Silicon 构建；最低系统 macOS 15；本版本的全部测试在 M5 Max / macOS 27.0 上跑，阈值按 M1 Air 8 GB 定但没有 Air 可验（S4 热降频 BLOCKED-机型）。
- 虚拟摄像头需要 App 放在 /Applications 并在系统设置里允许扩展（macOS 的系统扩展规则）；ad-hoc 构建装不上（见上表）。
- 屏幕录制没有 usage key，第一次用屏幕输入要在"系统设置 → 隐私与安全性 → 屏幕与系统音频录制"里手动授权；摄像头 / 麦克风授权归属于启动 App 的那个进程（从终端起就是终端）。
- 从源码编译且没装 NDI SDK for Apple 的机器：NDI 输入 / 输出标 `unavailable`；发布包随包 libndi.dylib（THIRD_PARTY/NDI/）。
- 真设备上没验过的：DeckLink（只有 SDK 模拟设备）、UVC 采集卡、USB 摄像头、多于 2 路的 USB 音频接口 / 聚合设备、另一台机器发的 NDI 源、A5 监听延迟回环、真 Companion / Stream Deck 硬件——docs/testing/设备兼容性.md 只有开发机的行，用户手册里这些接法按各会话报告写。

### 测试与工具（不影响产品，影响谁跑测试）

- `frameprobe av` 的内存随录像长度线性涨（1 小时录像 41 GB）：长稳脚本已按 5 分钟切段绕过；别对长录像直接跑（reports/issues/W4A-w1-testkit-frameprobe-memory-grows-with-length.md，W1-A）。
- 几条依赖窗口 / 时序的用例在机器忙或窗口被盖住时偶发红，单独重跑都过：`DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`、`ExternalTests` 的 `DisplayStatsTests`、App 的 S7 两条与 `ThumbnailRateTests`、NDI 回环两条计时断言、`ThrottleProxyTests`。
- 七张多画面参考图是 macOS 27 的中文字形，26.x 机器上按 PSNR ≥ 40 dB 看（reports/issues/P4-w3-compositor-multiview-cjk-labels-macos27.md）。
- L5 的"退步 > 10%"规则在 V3（微秒量级）与 CPU / GPU 上会因运行间起伏误报，绝对下限（`scripts/perf/regression.json` 的 `floor`）等用户定（reports/w4-soak.md §4 第 2 条）。
- 长稳 / 性能脚本在 Claude 会话（非交互）里不接摄像头、不采 powermetrics、Instruments Leaks 附加不上；在用户终端里跑才是完整负载（reports/w4-soak.md §3）。
