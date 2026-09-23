# G4 检查点报告：M4 输入二期 + M6 叠加、转场与其它输出（分支 g4）

人工部分。自动部分（每次 `scripts/gate4.sh` 运行一节，加 `scripts/gate4-ndi.sh` 的 NDI 回环 L1 与 `scripts/gate4-matrix.sh` 的编译矩阵）由
`scripts/gate3-report.py --checkpoint G4` 拼在本文件之后成 `reports/G4.md`。会话过程与坑在 `reports/g4-session.md`（分支名 g4 的报告在 APFS 上会和 G4.md 撞文件名，同 G3 的做法）。

## 1. 版本 / 提交号

- 分支 `g4`（harness worktree `.claude/worktrees/g4-checkpoint-merge-b5a2dc`，分支直接改名），从 `main` f1bd1ee（G3 + 五个续做分支 + 等拍板口径合入后）开。版本号 0.1.0 不动（G5 的事）。
- 合入的五个分支（都从 main f1bd1ee 开，各自报告在 reports/w3-*.md），按 prompt 60 的顺序 `--no-ff` 合入：

| 顺序 | 分支 | 顶 | 提交数 | 合并提交 | 冲突 |
|---|---|---|---|---|---|
| 1 | w3-compositor2（W3-B 合成二期） | 4ead186 | 7 | 9093bcc | 无 |
| 2 | w3-inputs2（W3-A 输入二期） | f8e3181 | 7 | 3b744fe | 无 |
| 3 | w3-outputs2（W3-C 输出二期） | c64ed74 | 5 | d896d53 | 无 |
| 4 | w3-control2（W3-D 控制二期） | 54c764a | 8 | 9b745c9 | 无（分支上按用户 2026-09-19 裁定改的 docs/OWNERSHIP.md、scripts/lint-rules.sh 在合并提交里认领） |
| 5 | w3-app2（W3-E 界面二期） | e799f28 | 5 | b60019b | **App/ 8 个文件与 W3-C 冲突**（AppController、AppDelegate、AppSettings、OutputRuntime、SwitcherSession、BottomBarView、MainWindowController、UISmokeTests），解决口径见 §4 |

- 合并之前先做了 G3 交接的第 1、2 条（58def8a）：撤 headless 第 8 步的封口绕法、G3 场景换噪声底纹、gate3-report 的 E2 直接判 / E5 进判定表。第 3 条（App `stopRecording` 简化）W3-C 已在自己分支做了；第 4 条（启动停顿复核）见 §6。
- G4 自己的提交：58def8a（交接 1–2）、99ab031（工装：headless 接图片 / NDI / 兼容层 / tally、g4 场景、frameprobe --blank-ticks、gate4 脚本）、b5e4846 / 81ce204（App 胶水：NDI / DeckLink 输入、兼容层、转场按钮、测试对齐）、5c6b5e7（pycache）、850a456（清单）、以及报告 / 基线的提交。
- 提案编号：W3-A 008、W3-B 009 / 010、W3-D 011（已按用户裁定落地）、W3-E 012，没有撞号，都待批（W3-D 的 011 除外）。

## 2. 机器 / macOS / 电源 / 温度

- Apple M5 Max，18 核，128 GB；macOS 26.6.2 (25G83)；Xcode 27.0 (27A266a, Swift 6.4)；电源适配器、电池 100%。
- 机器负载：合并 / 编译期间 load 2–3，只有桌面端 Claude 在用 CPU；gate 前按 environment.txt 记的 load 为准（见自动结果那节）。
- 五个 W3 分支各自的数字：W3-A、W3-B 在电池供电下测的（各自报告有说明），W3-C / W3-D / W3-E 接电源。G4 的 V1 只与 g3 基线相比（同接电源、同 headless 工装），**但负载不同**（噪声底纹 + 4 路抠像叠加 + 自定义多画面），差值只作参考，不判退步。

## 3. 场景（与 G3 的差别）

- 节目 `scenarios/g4-show.json`（`switcher-headless make-show --preset g4`，同时写出 `g4-stinger.png`）：
  1–8 号同 g3（噪声底纹 ±24，1 号 30 fps 灰 64 +音频进 Master，2 号 60 灰 192 +音频只进 ISO，3 / 4 号 59.94 灰 96 / 128 +音频只进 ISO，5 号 +100 ppm、6 号 −100 ppm、7 号 ±3 ms、8 号 60）；
  **5–8 号开抠像**（契约 `InputSettings.keyer`，默认绿键色：灰噪声源上画面不变，只付 W3-B 抠像着色器的代价——真绿幕的质量看 W3-B 的 IoU 用例与清单第 3 条）；
  **9 号图片输入** = 带 alpha 的 Stinger PNG（下 20% 蓝色横幅 + 橙斜线、两侧立柱，不碰顶部图案行 / 闪光块 / 中心采样区）；
  **Overlay 1–4** = 5 / 6 / 7 / 8 号（左下 / 右下 / 左中 / 右中，fade 15 / slide 20 / zoom 20 / cut，位置避开图案与中心采样区）；
  转场参数 Wipe 左→右软边 0.1、Stinger 9 号第 12 拍换底；输出 = 录制（H.264 6 Mbps + AAC）+ **多画面自定义布局**（`extra["layout"]`：PGM / PVW 上半 + 8 路 4×2，safeArea + meters，提案 010 过渡口径）。
- 场景 `scenarios/g4.json`（`make-scenario --preset g4 --minutes 10`）：前 2 分钟同 g3（1000 Cut、3000 Fade 30、3600–3780 T-bar）；**120 s 起每 5 s 一次转场按 Cut → Fade → Wipe → Zoom → Stinger 轮流**
  （非 Cut 24 拍 = 0.4 s：`setTransition` 在 t − 1、`autoTransition` 在 t，切完 d + 1 拍推 PVW；10 分钟 96 次：Cut 20、Fade 19、Wipe 19、Zoom 19、Stinger 19）；**122.5 s 起每 15 s 翻一路叠加**（1 → 2 → 3 → 4 循环，每路 60 s 翻一次）。
- C 系列客户端：C1 从 t0 + 150 s 起 50 次 cut，相位 **x.7 s**（`--c1-phase 0.7`：0.4 s 的转场已结束、离 5 s 切换点 ≥ 0.4 s），随后 C4 两客户端 × 100 条/s × 60 s；C2 / C3 用整段快照。
- **frameprobe `--blank-ticks`**（G4 新加，TestKit 胶水 16 行 + CLI）：gate4.sh 从场景文件算出每次非 Cut 转场的 [t + 1, t + d]（76 段 1824 拍），stats / switches / frames / av 都把这些帧当作解不出。
  为什么：转场合成帧没有单一输入身份——Wipe / Zoom 时帧号行（32 块 CRC-4 码字）与 ID 块在不同拍翻转、混合行有 1/16 概率解成合法的错号，Fade / 软边 Wipe 的 ID 块是两色混合可能落到第三色附近——
  按输入身份统计的 V4（frameprobe 在播段口径）/ V6 / C3 对它们没有定义。第 t 拍（progress 0 = 纯旧画面，也是整秒闪光帧）保留；V5 总帧数不受影响；**引擎侧 stats.jsonl 的 V4 计数全程照算**。
  正式的修法（frameprobe 三样解码互证 + Wipe / Zoom 进度量法）退 W1-A：reports/issues/G4-w1-testkit-frameprobe-wipe-zoom-progress.md → prompt 62。
  冒烟对照（10 s，Stinger / Wipe / Zoom / Fade 各一次）：不标记时 `switches` 把 Wipe / Zoom 判成 1 帧中间帧的 transition、Stinger 判成 Cut（PNG 没盖住 ID 块），这一次没撞上倒退；标记后四次都是 24 帧中间帧的 transition，Cut 全干净。
- NDI 回环节目 `scenarios/g4-ndi-show.json`（`make-show --preset g4-ndi`）：1 号 60 fps 噪声 +音频作 PGM，2 号 `ndi(sourceName: "Switcher G4 loop")`（headless 把不含 "(" 的名字按本机发现列表的后缀解析）放 PVW。

## 4. App 合并：W3-C 与 W3-E 的重叠怎么收的

两路都在 App/ 里做了多画面独立窗口、外部显示窗口、输出菜单和 ISO 入口；prompt 54 / W3-E 报告 §3 事先约定"以 W3-C 的运行表为准、保留 W3-E 的菜单与面板"。G4 按此解决：

| 处 | 取舍 | 落点 |
|---|---|---|
| 多画面独立窗口 | W3-C 的 `MultiviewWindowController`（位置进 Show.layout） | 删 W3-E 的 `App/Sources/UI/AuxWindows.swift`（同名类撞名），`PanelCoordinator.showMultiview` 转调 `MainWindowController.toggleMultiviewWindow`，窗口菜单 / 底栏都指向它 |
| 外部显示窗口 | W3-C 的 `ExternalDisplayManager`（包里，跟快照增删、显示器插拔） | 删 W3-E 的 `ExternalDisplayWindowController`（同一文件）；W3-E 输出设置面板的附加键 `display.number` 改成 W3-C 运行表读的 `ExternalDisplaySpec.displayIDKey`（"displayID"），面板加的输出才会开窗口 |
| 外部显示菜单 | W3-C 的（输出菜单 › 外部输出，显示器 × 源，打勾） | W3-E 窗口菜单里那份去掉（键名不同、重复） |
| 输出菜单 | W3-E 六个设置页入口 + W3-C 外部输出子菜单 / 多画面窗口 / 虚拟摄像头子菜单 | `menuNeedsUpdate` 按菜单对象认（标题已本地化）；`NSMenuDelegate` 在类声明上 |
| ISO 入口 | 两个都留：底栏 ISO… 面板（W3-C，含磁盘余量估算）+ 输出设置 › ISO 页（W3-E） | 都发 addOutput / removeOutput；二选一归 W3-E2（prompt 63 第 4 条） |
| 录制按钮 | W3-C 语义（全部录制输出一起起停，"● 录制中（n 路）"） | 文案走 W3-E 的 L10n 键（新加 bottom.recordingMany / recordStateMany） |
| OutputRuntime / SwitcherSession / AppSettings | W3-C 的运行表（ISO、磁盘保护、aux）+ W3-E 的 midiTable / 兼容层键 | 都保留 |
| 测试 | UISmokeTests 取 W3-C 三个按钮断言；PanelTests 多画面 / 外部显示用例改对着 W3-C 的对象；ShortcutAndShowTests 的"NDI 占位"改成 W3-A 的 noSignal 口径 | — |

合并后 App 补的胶水（不属于冲突解决）：InputFactory 接 W3-A 的 NDI / DeckLink（W3-A 报告 §3 第 7 条留的两个 case，清单第 1 条要看的文案就来自它们）、ControlRuntime 按偏好设置起 W3-D 的兼容层、切换面板接通 Wipe / Zoom / Stinger 三个按钮（W3-E 那期置灰等 W3-B）、project.yml 加 SwitcherNDI / SwitcherDeckLink / VMixCompat 产品依赖。

## 5. 归属与胶水账（make lint 的现状）

`scripts/check-ownership.sh g4`（用户 2026-09-22 裁定后全绿）：
- 合并提交里 8 个冲突文件的解决单列（G4 给脚本加的：自动合并结果带冲突标记的文件不计胶水额度，OWNERSHIP 补充规则 5 已写明）。
- Packages/SwitcherTestKit 胶水 30 / 50 行（FrameProbe.Options.blankTicks + 按 pts 算拍）。
- **App/ 胶水 391 行 > 50，用户 2026-09-22 认领**：G4 行把这 13 个文件列成显式 token（不计额度；App/ 其余仍按 ~App/:50）。拆开看：
  - W3-C / W3-E 重叠实现的收口 ≈ 300 行（删 AuxWindows.swift 136、PanelCoordinator 123、PanelTests 35、OutputExtras 6）——prompt 54 / W3-E 报告 §3 指定由 G4 做，不做 App 编不过（同名类）；
  - 接线 ≈ 90 行（ControlRuntime 21、InputFactory 14、AppSettings 10、SwitcherSession 3、TransitionPanelView 20、BottomBarView 6、ShortcutAndShowTests 13、两份 .strings 各 2）。
- `project.yml`：G4 行加了它（只加产品依赖，同 W2-B2 / W3-C 先例），用户 2026-09-22 认领。
- 其余（禁词 / 版本 / Package.swift 约束 / 依赖方向 / 实时符号）见 g4-session.md 的 lint 记录。

## 6. 自动项摘要（数字在后面的自动结果各节；这里只写结论与解释）

### 6.1 L0 / L1（`make test`，2026-09-20 13:00–13:49）

六个包 `swift test`：**579 个用例，0 失败，19 个按环境跳过**——SwitcherCore（Contracts 58 / Engine 86 / Render 72，含 W3-B 的 V6 五种 × 20、V7、V8 22 张参考图、抠像 IoU）、
SwitcherInputs（28 + NDI 20 + DeckLink 17）、SwitcherAudio（62 + 39）、SwitcherOutputs（25 + Streaming 28 + NDISend 8 + ISO 7 + External 6 + VirtualCamera 5）、SwitcherControl（28 + VMixCompat 25 + Tally 3）、SwitcherTestKit 62。
跳过的 19 个都是 BLOCKED（摄像头 TCC ×4、真设备 / A5 ×5、DeckLink 硬件 ×3、NDI 手动 / 无 SDK ×2、NDISend 人工 / 无 SDK ×2、外接屏 L2、C5 人工常驻、老 stats 文件）。W2-D 的 ThrottleProxy 用例这次没抖（问题单 W1E2-w2-stream-throttle-proxy-close-flaky.md 仍留着）。
App `xcodebuild test`：53 个用例，第一次 46 过 / 5 失败 / 2 跳过；四条是合并后的行为变化（录制按钮文案、外部显示关窗口路径、NDI 输入不再是占位、S7 用例受当时负载影响 missed_render 1）改对后单跑全过；
**剩一条 `testL10n_noHardcodedChineseInUISources` 红着**：W3-C 接进 App 的 39 处中文字面量（§3 / prompt 63）。合并后又接通了三个转场按钮，最终一次全量 App 测试的结果见 §6.5。

### 6.2 10 分钟 L2（scenarios/g4.json）

跑了四次（每次一节自动结果，产物 `.build/gate4/10min-run1..3/` 与 `.build/gate4/10min/`）。**除 V2 及其派生的 V4 / V5 之外，V1 / V3 / V6 / V7 / A1–A4 / E1–E3 / C1–C4 四次全过，E5 在工装修正后全过**；
V2 四次都不是 0，每次都对得上 load.log 里同一时刻的桌面 / 系统进程突发（Chrome、WindowServer、tccd / 通讯录同步；桌面上另有 Codex / Clash 在跑）——问题单 reports/issues/G4-w1-core-missed-render-bursts-under-daemon-activity.md，
G3 的三次同类运行是 0，G4 场景多了 4 路抠像叠加 + 自定义多画面 + 噪声底纹（V1 avg 1.78 → 2.0 ms，GPU 21% → 25%），跳拍时刻与叠加 / 转场事件不重合。

| 运行 | 时间 | 结果 | V2 | 说明 |
|---|---|---|---|---|
| run1 | 09-20 14:04–14:17 | 16 / 19 | 2（Chrome 55% + 26%） | 三个失败查明是工装 / 环境：默认绿键把 7 号的黄绿 ID 块抠掉（frameprobe 认不出输入 7）、2 次漏帧后 `--blank-ticks` 按文件序号标偏（假"丢弃"60 帧）、headless 引擎停后才 `stop(atTick:)`（音轨多 49 ms）；三处都改了再跑 |
| run2 | 09-20 14:29–14:39 | 17 / 19 | 1（WindowServer 42%、Chrome） | E5 0.0 ms、输入 7 认得出、frameprobe 在播段干净；V4 的引擎侧 10 帧 / frameprobe 2 帧全由那 1 拍派生 |
| run3 | 09-20 23:54–00:05 | 15 / 19 | 11（tccd 38%、peopled、AddressBookManager，12 s 内） | V4 183 / 11 帧、V5 −11 全由这 11 拍派生；§4 必须档 V2 ≤ 0.02% 这次也不过（0.031%） |
| run4 | 09-21 00:19–00:29 | **19 / 19 ✅（代表运行）** | 0 | V5 0、V4 两个口径 0、E5 0.0 ms、A2 max 0.48 ms、C1–C4 全过；V1 avg 2.15 ms（G2 的 2 ms 本机线是 M0 灰底负载定的，G4 起只作参考，必须档 ≤ 6 / 目标 ≤ 4 都过；见下） |

**结论**：run4 全部自动项通过，是本次的代表运行，基线 `baselines/g4-m5max.json` 取它。run1–3 的 V2 跳拍都是"整个进程被系统 / 桌面活动拖住时渲染器 skipped"（三次 V3 都 ≤ 0.05 ms，时钟没晚醒；跳拍秒的 render_ms 均值 3.7–5.4 ms，负载没超），
每一次派生出的 V4 / V5 差值都能逐帧对上跳拍数；**没有放行、没有改阈值**，四次都原样列在自动结果里，跳拍的归因单退 W1-B / W1-C。
G4 起两处口径（测试标准 §3 V4 已写；用户 2026-09-22 确认）：frameprobe 在播段的 +1 帧相位余量按每个连续在播段各算一次（同一路每次回到 PGM 相位重新起算；run4 的 59.94 路在播 5 段 5 次 dup，按单段口径会多出 1 帧假设计外）；
V1 的"本机参考线 2 ms"是 G2 按 M0 灰底负载定的，G4 负载多了 4 路抠像叠加 + 自定义多画面 + 噪声底纹（W3-B 在测试工装里量到抠像 +1 ms GPU），gate4 报告里只作参考不进总判定，
**W4-A 的 L5"无退步"以 g4-m5max.json 为基线**（用户 2026-09-22 确认，测试标准修订行已注明）。与 g3 基线比：V1 avg +0.37 ms（1.78 → 2.15）、GPU 21% → 31%、CPU 持平（含 apitest 客户端）。

### 6.3 NDI 回环 L1（reports/G4-ndi.md）

第一次 missed_render 11（NDI 发现放在算 t0 之后吃掉了 lead，引擎起晚）→ 挪到 t0 之前重跑：L1 均值 27.04 ms = 1.62 帧（扣 J = 1 帧的抖动缓冲后 0.62 帧）、max 1.70 帧，fps 60.01，dup / drop 0，missed_render 0，发送端 dropped 0 → **通过**（≤ 3 + J，目标档也过）。与 W3-A 报告 §1.2 的 J = 1 数字（1.75 / 1.97 帧）一致。

### 6.4 编译矩阵（reports/G4-matrix.md）

A（都在）/ B（只有 NDI）/ C（都不在）三种配置 `swift build` + NDITests / DeckLinkTests 各 37 个用例 0 失败（跳过 5 / 12 / 20 = 对应配置下的 BLOCKED-SDK / 硬件用例，"无 SDK 行为"用例在 B / C 里真跑）→ **通过**。

### 6.5 App 全量测试与启动停顿复核

- **启动停顿复核**（交接第 4 条，reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md 末尾）：真 App 打开两路 30 fps 合成源，第一秒 jitter 467 ms / missed_render 28（停顿还在，比 W2-B2 的 377 ms 更长），
  但 **per_input drop 停在第一秒的 12、第二秒起只有设计内的 dup +30/s、L1 8.7 ms**——W1-B2 修的"停顿后一两个窗口内恢复"成立，单子的引擎侧部分可以关；停顿本身归 App / 显示路径 / 首帧管线预热（W2-B / W3-E2 / W1-C），已写进单子。
- **App 全量测试**（最后一次，09-21 00:43，接线与测试修正之后）：53 个用例 **51 过、1 失败、1 跳过**——失败的是 `testL10n_noHardcodedChineseInUISources`（W3-C 接进 App 的 39 处中文字面量，
  reports/issues/G4-w3-app2-localize-w3c-app-strings.md → prompt 63），跳过的是内置摄像头用例（BLOCKED-权限：从 Terminal.app 跑 `make test-app` 才有 TCC）。W3-C 的 A4 / S7 / 外部显示 / 虚拟摄像头、W3-E 的 26 个面板用例 / Show 往返 / 无障碍 / 调音台 / 快捷键 / MIDI、W2-B2 的录制 / 推流 / API 全过。

## 7. BLOCKED 清单及解锁条件

| 项 | 来源 | 状态 | 解锁条件 |
|---|---|---|---|
| DeckLink L1 / L2 / S5、真卡上的校准残差 / 格式检测 / 热插拔 | W3-A | BLOCKED-硬件 | UltraStudio / Mini Recorder + Desktop Video 驱动 + 任意 SDI / HDMI 源；正式 SDK 解压到 ~/SDKs/DeckLink 后重编（现在编的是 NDI SDK 示例目录里的 10.11.2 头） |
| 外部显示 L2（秒表法）、多画面窗口拖到外接屏 | W3-C | BLOCKED-硬件 | HDMI 显示器（+ 摄像头 + 毫秒秒表） |
| 虚拟摄像头激活、FaceTime 可见、L1 | W3-C | BLOCKED-签名 | Team ID（`DEVELOPMENT_TEAM=… make gen`，权限表自动切换）+ 从 /Applications 运行 + 系统设置允许扩展；`systemextensionsctl developer on` 在 26.6.2 要关 SIP，不走 |
| C5 真 Companion 六项 | W3-D | BLOCKED-人工 | 装 Bitfocus Companion；服务端 = App 偏好设置开关 或 headless `--compat`；自动化版 c5-companion.py 已过 |
| Stream Deck 插件端到端 | W3-D | BLOCKED-硬件 | Node ≥ 20.5 + Stream Deck 软件 / 硬件；纯逻辑 JXA 已过 |
| 慢 U 盘的 S7 | W3-C | BLOCKED-硬件 | 外置盘 |
| 摄像头 / 屏幕录制授权相关的 App 测试 | W2-B2 起 | BLOCKED-权限 | 从 Terminal.app 跑 `make test-app` |
| A5 监听延迟（真回环） | W1-D2 | BLOCKED-硬件 | 音频接口线回环 |
| E7–E9 | W2-D / G3 | 沿用 G3 结果 | W3 五路没动推流；重跑要 `sudo scripts/netem.sh serve` + `make gate3-net` |
| 纯音频设备输入 | W3-E 的 Add Input 有页、没有运行实现 | 未实现 | 需要 Core Audio 输入 → 环的 `AudioDeviceInput`，归属待定（W3-A 范围外） |

## 8. 等用户定的（2026-09-22 两轮裁定后全部有了结论）

1. **已定（2026-09-22）**：§5 的两条归属——App/ 收口 + 接线的 13 个文件由用户认领、列进 OWNERSHIP 的 G4 行；project.yml 进 G4 行。`make lint BRANCH=g4` 全绿。
2. **已批（2026-09-22）**：提案 007 / 008 / 009 / 010 / 012 一次批了（011 早已落地），由一次契约会话 P3 落地（prompt 61，分支 p3-contracts，从 G4 合入后的 main 开），顺序 007 → 010 → 012 → 008 → 009；
   续做 prompt 改号：W1-A3 = 62（不依赖 P3，可并行）、W3-E2 = 63（从 P3 合入后的 main 开，四个提案留给界面的项都写进去了）。012"顺带的疑问"1（每路 AFV 参与开关）**同日第二轮批了**：`InputAudioSettings.afv: Bool = true`，加进 P3（prompt 61 第 4 条），界面归 W3-E2。
3. **已确认（2026-09-22）**：§6.2 的两处口径——frameprobe 在播段 +1 帧相位余量按每个连续在播段各算（测试标准 §3 V4）；V1 的 2 ms 本机参考线自 G4 起只作参考、W4-A 的 L5 以 baselines/g4-m5max.json 为基线（测试标准修订行已注明）。
4. **已定（2026-09-22，用户"4–8 也都做"，按 G4 建议）**：W3-A 报告 §4 第 2 / 4 条两条口径接受——NDI 的 pts = 到达 − 抖动 + J × 帧间隔（音频块同加 J × T）；驱动 / 设备 / 源不在用 noSignal + 文案、不会自己好的才是 error；连 deviceID 格式（§4 第 3 条）一起由 P3 写进契约注释与 CONTRACTS（prompt 61 第 5 / 7 条）。
5. **已定（2026-09-22，用户"4–8 也都做"，按 G4 建议）**：W3-C 报告 §4——显示类输出进 Stats（`display[]`）+ 显示器 ID 正式字段（`OutputSettings.display`）→ 提案 013（已批，P3 落地，填数方 External / VirtualCamera / App StatsHub）；Aux 全分辨率由 SwitcherOutputs 自己画输入帧、不动渲染器 → 新会话 W3-C2（prompt 65，分支 w3-outputs-3，从 P3 后开）。
6. **已定（2026-09-22，用户"4–8 也都做"，按 G4 建议）**：W3-B 报告 §4 第 3 / 4 / 5 条——Stinger cutAtTick 的两句进注释；OutputSource.multiview 在自定义格子里被忽略写进注释；RenderedFrame.preview / multiview 改成"状态里有 enabled 且 source = preview / multiview 的输出就自动填"，MetalRendererOptions 保留为强制开——都在 P3（渲染器一行走胶水，prompt 61 第 7 条）。
7. **已定（2026-09-22，用户"4–8 也都做"，按 G4 建议）**：W3-D 报告 §4 第 4 / 5 条——`reportedVersion` 继续报本产品版本；Stream Deck 插件 UUID 随 W4-B 定正式 bundle id 域名时一起换（prompt 71 第 6 条，OWNERSHIP W4-B 行加了 Tools/streamdeck-plugin/），不等 G5。
8. **已定（2026-09-22，用户"4–8 也都做"，按 G4 建议）**：纯音频设备输入归新会话 W2-A2（prompt 64，分支 w2-inputs-2，SwitcherInputs 里实现 AudioDeviceInput + 设备列表 + harness），App 接线归 W3-E2（prompt 63 第 7 条）。

## 9. 给下一个会话的坑

（见 reports/g4-session.md §5；这里只列影响下一个检查点的：）
- `Tools/frameprobe/Package.resolved`、`Packages/SwitcherOutputs/Package.resolved`、`Packages/SwitcherTestKit/Package.resolved` 是 swift build 生成物，`git add -A` 会带进去；`Packages/SwitcherControl/Package.resolved` 是**已跟踪**的但 xcodebuild 会改它，提交前 `git checkout`。
- `scripts/*.py` 跑一次会生成 `scripts/__pycache__/`（.gitignore 已加）。
- g4 场景的 V4 有两个口径：frameprobe 在播段口径排除了转场中间拍（--blank-ticks），引擎侧 stats.jsonl 全程；两者都要 0。
- G4 基线 `baselines/g4-m5max.json` 与 g3 不可比（噪声底纹 + 新负载）；W4-A 的 L5 从 g4 起算。
- **macOS 自带 bash 3.2 在 `set -u` 下把空数组的 `"${arr[@]}"` 当未定义变量**：gate4.sh 改成默认不带 `--blank-ticks` 后第一次跑在 frameprobe 那一步炸掉（10 分钟白跑一半——运行产物还在，`--skip-run --no-build` 能只重做后半段）。空数组一律写 `${arr[@]+"${arr[@]}"}`。
- **frameprobe 自证解码（W1-A3）让全片扫描慢了**：36000 帧的文件一次 `stats` / `frames` / `av` 各约 3–4 分钟（1080p，release，M5 Max），gate4.sh 的后半段（5 次全片扫描 + wipe / zoom）要 15–20 分钟，整条 gate4 约半小时；后台跑、盯日志的 GATE4_EXIT。
- **P3 的夹具 `Tests/SwitcherContractsTests/Fixtures/g4-show-before-p3.json` 与 `scenarios/g4-show.json` 是绑着的**（`testP3_oldShowFilesStillLoadWithSameSemantics` 逐字段比 inputs / overlays / audio / multiview）：改 g4 节目的任何一路输入，夹具要同步改，否则 SwitcherContractsTests 红。

## 10. 续做分支合入（2026-09-23，G4 会话续做；用户："都完事了，你检查一下，之后再合一下"）

三个续做分支都从 G4 合入后的 main（367bbb9）开，检查后按依赖顺序 `--no-ff` 合进 g4，再由 g4 快进到 main：

| 顺序 | 分支 | 顶 | 提交数 | 报告 | 合并 | 检查结论 |
|---|---|---|---|---|---|---|
| 1 | p3-contracts（P3，prompt 61） | 0d7334b | 22 | reports/p3-contracts.md | b914b23，无冲突 | 六提案 + 每路 AFV 全落地；614 个包用例全绿、gate4 p3c 19 / 19、lint 全绿；改过一处测试内阈值（抖动均值 0.8 → 1.2 ms，用户 2026-09-23 批）、测试标准 §7 加 display[]（用户让 P3 直接加） |
| 2 | w1-testkit-3（W1-A3，prompt 62） | 69bea5c | 7 | reports/w1-testkit-3.md | 2c86e74，只有 docs/OWNERSHIP.md 相邻两行（P3 行 / W1-A3 行各自加了测试标准 token）冲突，两行各取各的 | frameprobe 自证解码 + Wipe / Zoom 量法；68 个用例全绿；测试标准 §2.1 三条口径（用户批）；gate4.sh 没接（scripts/ 不归它）→ 本次接上 |
| 3 | w2-inputs-2（W2-A2，prompt 64） | 4114cb5 | 19（其中 12 个是叠在下面的 P3 ca1baa5） | reports/w2-inputs-2.md | 3c79e23，无冲突 | AudioDeviceInput + 提案 014（用户批并指定 W2-A2 落地）；本包 49 个用例 0 失败；没做的全归档成问题单（W2A2-g5-pending-items） |

归属：三个分支相对各自基线都在允许范围内（W2-A2 相对 P3 的 ca1baa5 查：32 个文件都在 OWNERSHIP W2-A2 行里，行里多出的 7 个文件是用户批 014 时给的）；
P3 / W1-A3 各自把 `docs/spec/导播台测试标准.md` `docs/OWNERSHIP.md` 加进自己那行并写明是用户让改的，合并后 `make lint BRANCH=g4` 对合并提交只算手改，全绿（见 §10.3）。

### 10.1 合并后检查点做的胶水与工装（G4 目录内；Inputs 包 18 行胶水）

| 事 | 来源 | 落点 |
|---|---|---|
| gate4.sh 接 W1-A3：frameprobe 自证默认开、不再带 `--blank-ticks`（`--legacy-blank-ticks` 回老口径）；V7 加 `frameprobe wipe / zoom`（场景里第一次 Wipe / Zoom，方向从节目文件取）；gate3-report.py 的 V7 行合并判 Fade / Wipe / Zoom ≤ 1 帧，说明段改写 | W1-A3 报告 §3 第 1 条 | scripts/gate4.sh、scripts/gate3-report.py |
| g4 节目 5 / 6 号的 ID 改成无红分量的调色板 9（深绿）/ 15（蓝绿）：溢色抑制 0.5 把品红 / 金的 ID 块拉离标称色 40 > 24，这两路在播全程解不出 | W1-A3 问题单 W1A3-g4-keyer-spill-breaks-pattern-id | G4Factory + 重生成 scenarios/g4-show.json（与 P3 版只差两个 patternID） |
| headless 接纯音频设备输入（`.audio` → AudioDeviceInput，环注册进音频引擎，producerBlockFrames 1024；有设备音频时录制 / NDI 发送照带；`--iso-audio` 仍只取合成源）。冒烟：g3 节目加一路内置麦克风 `{"audio":{"deviceUID":"BuiltInMicrophoneDevice"}}` 跑 3 s 并录制——日志「纯音频输入 9「麦克风」：Core Audio 设备，环 2 声道」，音频 838 块 dropouts 0 / underruns 0，文件 h264 + aac 各 3.000 s，stats 里 9 号 per_input 全 0（没有视频，符合口径） | W2-A2 问题单 W2A2-g5-headless-audio-device-input | Tools/switcher-headless/HeadlessRun.swift |
| `switcher-input-probe audio-device` 子命令入口（实现在 W2-A2 的 harness 里，差 18 行接线） | W2-A2 问题单 W2A2-w2-inputs-probe-audio-device-subcommand | Packages/SwitcherInputs/Sources/switcher-input-probe/main.swift（胶水 18 / 50） |
| 新 prompt 66 W3-B2（多画面纯音频格 / 真实电平表 / 名字标签、删 010 过渡读取，可选 PVW 环按需）+ OWNERSHIP 行 | W2-A2 问题单 W2A2-w3-compositor2-multiview-audio-only-cell、P3 报告 §4 第 1 条 / §5 第 1 条 | docs/plan/prompts/66、docs/OWNERSHIP.md |
| prompt 63 补 W2-A2 的接线细节 / 014 声道选择 / 纯音频输入条占位；prompt 65 补删 External 过渡读取 | W2-A2 问题单 W2A2-w3-app-3-audio-device-input-wiring、P3 报告 §4 第 1–2 条 | docs/plan/prompts/63、65 |
| 提案 015（`fallbackToMain` 默认 true → false，与 W3-C 运行时一致）**待批** | P3 报告 §4 第 2 条 | docs/contract-changes/015 |
| 清单 §9：W2-A2 的六项人工 / 硬件项 | W2-A2 问题单 W2A2-user-manual-hardware-tests | docs/checklists/G4.md |

### 10.2 测试（合并后 + 胶水后，`make test` 全量，2026-09-23 12:10–13:00，机器上没有别的会话）

| 步骤 | 结果 |
|---|---|
| 六个包 `swift test` | **655 个用例 0 失败、21 跳过**：SwitcherCore 79 / 90 / 73（跳 1）、SwitcherInputs 55（跳 6）/ 25（跳 2）/ 25（跳 3）、SwitcherAudio 62（跳 2）/ 41（跳 3）、SwitcherOutputs 6 / 25 / 28 / 8（跳 2）/ 7 / 6（跳 1）、SwitcherControl 25（跳 1）/ 3 / 28、SwitcherTestKit 69。跳过的都是原有的 BLOCKED-硬件 / 权限 / 手动项。W2-A2 报告说的两条 NDI 回环计时断言这次没红（机器空着）。 |
| 第一次全量在 SwitcherContracts 红了一条 | `ContractsP3Tests.testP3_oldShowFilesStillLoadWithSameSemantics`：它把改写前的 g4 节目夹具搬迁后与现在的 `scenarios/g4-show.json` 逐字段比，本次把 5 / 6 号的 patternID 改成 9 / 15 后 inputs 不再相等。夹具（P3 的 `Tests/SwitcherContractsTests/Fixtures/g4-show-before-p3.json`）同步补两行 patternID（Core 包胶水 2 行），用例的语义（旧键搬迁 = 新文件）不变；单跑 10 / 10，再全量 0 失败。 |
| 两个工具冒烟 | 通过 |
| App `xcodebuild test` | 只有 `LocalizationTests.testL10n_noHardcodedChineseInUISources` 一条红（W3-C 的 39 处文案，G4 / P3 / W2-A2 都带着它放行，归 W3-E2 / prompt 63）；`MAKETEST_EXIT=2` 就是它 |
| `make build` 全量 | 六包 + 两工具 + App 全部编过（Xcode 27 swiftbuild 那四行 "exit code 0 but produced no further output" 是已知噪声） |

### 10.3 gate4（合并后一次 10 分钟，标签 g4b，2026-09-23 13:02–13:12 跑、13:12–13:30 出报告；自证口径 + 新 ID + 多画面真渲染；机器上没有别的会话）

`scripts/gate4.sh --minutes 10 --label g4b --baseline baselines/g4-m5max.json`（不写基线）→ **19 / 19 ✅**（reports/G4-run-g4b.md，产物 `.build/gate4/g4b/`）。
第一遍在 frameprobe 那一步炸了（bash 3.2 + `set -u` 的空数组，§9），运行产物完好，修好后 `--skip-run --no-build` 只重做后半段。

| 指标 | g4b | G4 run4（基线） | 说明 |
|---|---|---|---|
| V1 avg / p99 | 2.094 / 2.859 ms | 2.149 / 2.652 ms | P3 起 headless 每拍多一次多画面 NV12 转换（W3-B §4 第 5 条落地），avg 反而低 0.055 ms，p99 高 0.2 ms，都在 G4 四次运行的散布里；必须档 / 目标档都过 |
| V2 / V5 | 0 / +0 | 0 / +0 | — |
| V3 p99 / max | 0.043 / 0.143 ms | 0.091 / 0.121 ms | — |
| V4 | 精确核算 0 / frameprobe 在播段 0 / 倒退 0（平均帧率口径最大 0.0111%） | 0 / 0 / 0 | **自证口径**：不再用 `--blank-ticks`，解不出 ID 的 1273 帧全是转场中间帧（C3 比对 34727 帧、不一致 0）；5 / 6 号换 ID 后在播段都能认出来 |
| V6 | 第 1000 拍 Cut 干净；全程 **90** 次 Cut 不干净 0 | 64 次 | 多出来的 26 次 = 19 次 Stinger 的第 cutAtTick 拍换底（自证口径下 Stinger 的 Cut 保留，W1-A3 §2.2）+ Wipe / Zoom 完成拍 |
| V7 | Fade 0.493 帧；**Wipe @7800 leftToRight 0.071 帧、Zoom @8100 0.002 帧**（各 23 个样本，单调）；T-bar 最大映射误差 0.33% | Fade 0.467 帧；Wipe / Zoom 量不了 | 新增两条来自 W1-A3 的 `frameprobe wipe / zoom` |
| A1–A4 | 0；整秒 199 对最大 0.000 ms；漂移 0.00 ms/8h；A4 极差 0.208 ms | 同量级 | — |
| E1 / E2 / E3 / E5 | 0；6.002 Mbps 误差 1.61%；GOP 120 精确；时长差 0、音视频差 0.0 ms | 同 | — |
| C1–C4 | 50 / 50，mean 6.69 ms；C2 p99 1.8 ms；C3 0 不一致；C4 12000 / 12000 | 同 | — |
| S2 / S3 | 90.1 MB/h（10 分钟外推，仅参考，G4 也红）；CPU 51.2% / GPU 28.4% | 79.9 MB/h；50.7% / 30.5% | S2 归 W4-A 的 8 小时实跑 |

**基线不动**：`baselines/g4-m5max.json` 仍是 G4 run4。合并后的 V1 / V3 / S3 都在 G4 四次运行的散布里，没有退步也没有值得换基线的改善；W4-A 的 L5 继续以它为基线（多画面真渲染的代价已经在 g4b 里量过，没有可见变化）。

### 10.4 等用户的（2026-09-23 第二轮全部有了结论）

1. **NDI 回环两条计时断言的余量——已定（用户 2026-09-23 "NDI 那两条加余量，你顺手做了"）**：`NDILoopbackTests` 加 `schedulingMarginMs = 2.0` 并写明理由（阈值贴着理论值 24.667 / 71.667 ms，整包负载下调度晚 0.25–0.7 ms 就过线，单跑稳过；余量只盖调度抖动，不改被测行为的口径），两条断言各 + 2 ms。
2. **提案 015——已批并落地（同上）**：`DisplayOutputSettings.fallbackToMain` 默认与缺键都改成 false，与 `ExternalDisplaySpec` 从 G4 起的运行时一致；P3 的两处断言改过来、补一条"显式 true 照解"；CONTRACTS.md §2.5 一句；App 显式写的 false 现在等于默认，W3-E2 可顺手去掉。
3. W2-A2 问题单 4-1…4-5 的硬件 / 手动项（清单 §9）——仍是人工。

## 11. 第二批续做合入（2026-09-23，G4 会话续；用户："那三个都完事，你检查一下"）

三个分支都从 main 4b7a3df 开，`git merge-tree` 试算三路依次合并无冲突，按 W3-E2 → W3-C2 → W3-B2 `--no-ff` 合进 g4：

| 顺序 | 分支 | 顶 | 提交 | 报告 | 合并 | 检查结论 |
|---|---|---|---|---|---|---|
| 1 | w3-app-3（W3-E2，prompt 63） | 6d26ab0 | 21 | reports/w3-app-3.md | 64b043b | 63 的七条全做（39 处文案、转场参数控件、每通道 PVW / 边框 / 锚点、多画面布局页、007 / 008 / 012 / 013 / 014 接进界面、纯音频输入、MIDI 锚、ISO 单入口）；**提案 016 setTransitionParams 用户批并由它落地（Command 34 个）**；Outputs / TestKit / frameprobe 的 Package.resolved 钉版本入库（用户批）；App 71 个用例 70 过 1 跳、包测试 / lint 全绿；App/ 之外的文件逐个列进其 OWNERSHIP 行 |
| 2 | w3-outputs-3（W3-C2，prompt 65） | da10561 | 12 | reports/w3-outputs-3.md | 9524142 | Aux 全分辨率（本包自己画，BGRA / NV12 / UYVY 对渲染器 0 差）、dropped 口径 = 两次刷新间被覆盖、虚拟摄像头记账 + CMIO 序号、主屏层级选项、删过渡键读取；**提案 018 undelivered 用户批并由它落地**；ExternalTests 14 / VirtualCameraTests 9 全过；外接屏这次在，PGM / Aux 60 fps dropped 0 |
| 3 | w3-compositor-3（W3-B2，prompt 66） | 2ac7038 | 10 | reports/w3-compositor-3.md | f5b8afe | 纯音频格、setMeters 真实电平表（三块交接、渲染线程零分配）、名字标签 64 槽下一帧生效、删 010 过渡读取（用例改成"旧键被忽略"）、PVW / 多画面环按需建（省 50 MB）；91 个渲染用例全过、24 张参考图 PSNR ∞；提案 017（RMS）**待批** |

归属：三个分支的越界文件都是用户批的（016 / 018 / Package.resolved），各自写进了自己的 OWNERSHIP 行；W3-B2 25 个文件全在行内。

### 11.1 合并后检查点做的胶水（App/ 与 Tools / scripts / docs）

| 事 | 来源 | 落点 |
|---|---|---|
| Aux 三根线（帧槽分支开 / 还、输入状态、无信号文案）；`ExternalOutputAppTests` 第 3 步改按新行为（Aux 画输入 2 的全分辨率帧，不再是多画面第 2 格） | issue W3C2-app-aux-wiring §1 / §2 | App SwitcherSession.swift、App/Tests/ExternalOutputAppTests.swift |
| 虚拟摄像头 waitingExtension 那句的帧数改读 `undelivered`（018） | issue W3C2-app-aux-wiring §4 | App OutputStatusText.swift |
| 多画面真实电平表的喂数：App 在 StatsHub 消费者里 1 Hz `renderer.setMeters`，headless 在 StatsPublisher 消费者里同样一行；50 ms 的喂法归 W3-E3 | issue W3B2-w3-app-3-multiview-meters-thumbnails §1 | App SwitcherSession.swift、Tools/switcher-headless/HeadlessRun.swift |
| 测试标准 §7 的 display[] 字段表加 `undelivered`（018，口径权限） | W3-C2 报告 §4 第 2 条 | docs/spec/导播台测试标准.md |
| `make gen` 从入库模板 `scripts/xcode-workspace-Package.resolved` 拷工作区 Package.resolved（swift-collections 钉 1.6.0；新 worktree 不再 dyld 崩） | issues W3C2-g5-swift-collections-1.7-dyld-crash、W3E2-w1-testkit-frameprobe-unpinned-deps-swift-runtime | Makefile、scripts/ |
| 清单 §1 / §2 / §4 三处过时文字更正；§10 外接屏 / 多画面人工项 | W3-E2 报告 §3 第 5 条、issue W3C2-checklist-external-display-manual | docs/checklists/G4.md |
| 新 prompt 67 P4（017 若批 + 注释 / 口径 + reducer 两条小规则）、68 W3-E3（NDI 发送接线、Aux 文案 / 层级开关、显示窗口丢帧记账、电平表统一）、69 W3-C3（包内中文、扩展侧回报、ISO 估算）+ OWNERSHIP 三行；prompt 71 加依赖钉版本一条 | 三份报告的 §3 / §4 与问题单 | docs/plan/prompts/、docs/OWNERSHIP.md |

### 11.2 测试（合并后 + 胶水后，2026-09-23 17:5x–19:0x；机器合盖、只剩 LG 外接屏且显示器在睡 / 锁屏——见下）

| 步骤 | 结果 |
|---|---|
| `make build` 全量 | 第一遍 App 编不过：W3-E2 的 `InputStripView` / `MultiviewLayoutTests` 用了 W3-B2 删掉的 `MultiviewLayout.layoutValue(in:)` / `placements(layout:)`（两个分支各自绿、合起来红的语义冲突）。按 W3-B2 的裁定改成只读正式字段、过渡键用例改成"被忽略"（App 胶水 10 行），再编全绿 |
| 六个包 `swift test` | **677 个用例 0 失败、21 跳过**（`make test` 在 SwitcherOutputs 停了一次，剩下的包分开补跑）：SwitcherCore 91 / 91 / 78（跳 1）、SwitcherInputs 55（跳 6）/ 25（跳 2）/ 25（跳 3）、SwitcherAudio 62（跳 2）/ 41（跳 3）、SwitcherOutputs 9 / 25 / 28 / 8（跳 2）/ 7 / 14（跳 2，见下）、SwitcherControl 25（跳 1）/ 3 / 28、SwitcherTestKit 70 |
| SwitcherOutputs `StreamingTests.MediaMTXTests` 4 条第一遍红 | RTMP / SRT / E7 / E8 都在"帧号连续 / 解不出 = 0"上红：**W1-A3 自证解码的"节奏"一票**把实时喂送（`PatternFeeder` 烧的是生成时刻 `now`，带毫秒级抖动）的 37 / 599 帧按残差 3.2–3.8 ms > 3 ms 判成解不出、算成丢帧；同一文件关掉自证 599 帧 0 丢 0 重。12:10 那次全量之所以绿，是当时 `Tools/frameprobe/.build/release/frameprobe` 还是 W1-A3 之前编的。检查点把推流测试的 frameprobe 调用改成传输口径 `--no-self-check`（Outputs 包胶水 5 行，注释写明），重跑 4 条全过（RTMP 599 帧 0 丢 0 重 0 解不出、E7 81.7 s、E8 全部重连）；问题单 `reports/issues/G4b-w1-testkit-selfcheck-rhythm-vs-realtime-feeder.md` 退 W1-A |
| SwitcherOutputs `ExternalTests` 14 条里 4 条红（37 处断言） | 全是"0 帧 / 0 fps / display link 回调 0 次"。**环境**：机器合盖（`AppleClamshellState = Yes`）、只剩 LG 外接屏且显示器在睡 / 会话锁着——一个 20 行 AppKit 探针在当前 Space 开全屏窗口 1.5 s 内 display link 0 次回调，`caffeinate -u` 唤醒后的一瞬间 216 次、几秒后又 0；W3-C2 17:20 在同一份代码上 14 条全过。这 4 条与 App 的出帧类用例要等桌面可见时再跑（命令见 §11.4） |
| 两个工具冒烟 | 通过 |
| headless 60 s 录制 + frameprobe（为排查推流那 4 条做的对照） | 3600 帧、自证判掉 0、丢 0 重 0——W3-B2 的输出环 / 预包纹理改动没有弄坏 PGM 帧 |
| App `xcodebuild test`（gate 之后 20:18 带 caffeinate 跑了一次全量） | 出帧类 7 条红全是 0 帧（`DisplayDecouplingAppTests` 拖窗、`ExternalOutputAppTests` 外部窗口 / 多画面窗口、`ThumbnailRateTests` ×2）——与 ExternalTests 同一环境原因（锁屏 / 显示器不可见，W3-E2 报告 §5 第 1 条）；**一条真红并已修**：W3-E2 新加的 `testL10n_packageStatusesLookedUpInApp` 里虚拟摄像头 waitingExtension 的样例还按 `dropped: 7` 期望"已丢 7 帧"，018 之后这句读 `undelivered`（W3-C2 问题单 §4 点名的交叉）——样例改成 `undelivered: 7`，LocalizationTests 5 / 5 绿。其余用例（W3-E2 自己分支上 71 个 70 过 1 跳）本次只改了两条断言（Aux 第 3 步、过渡键缩略图）和 `InputStripView` 10 行 |

### 11.3 gate4（合并后的 10 分钟运行：g4c / g4d / g4e；渲染器多了名字标签 / 电平表 / 按需建环，契约多了 016 / 018；headless 每秒喂电平表）

机器状态：合盖、只剩外接屏、会话锁着、用户不在——macOS 在这种"空闲 + 接电"下跑后台任务（load.log 里 `assistantd` 35%、`VTDecoderXPCService` 36% 各持续数分钟），与 G4 run1–3 / P3 p3b 记过的"进程被系统活动拖住"是同一类环境。

| 运行 | 时间 | 自动项 | 没过的 | 归因 |
|---|---|---|---|---|
| g4c | 19:0x–19:24（跑 10 min + 报告 20 min） | 17 / 19 | V4 精确核算设计外 25 帧（frameprobe 在播段 0）；A4 click 极差 999.979 ms | V4：各路生产者线程晚醒（"唤醒 max 17 ms"、每路迟到 3–5 次），输入 5（+100 ppm）drop 8 ≈ 设计内 3.6 + 4——环境；**A4：frameprobe 多文件对齐的平局缺陷**（闪光正落 x.500 s，iso3 的 click 晚 20 µs 就配到前一个 click；iso3 里 491.001 s 的 click 明明在），问题单 G4b-w1-testkit-a4-click-pairing-tie-at-half-second |
| g4d | 19:27–19:51 | 17 / 19 | V2 1 帧（拍 20050，那秒 render 3.08 ms / GPU 21% / CPU 53%，都低于均值 → 渲染线程晚醒）；V4 设计外 8 帧 | 同一类环境（输入 6 唤醒 max 18.5 ms）；A4 这次 0.188 ms（平局同向） |
| **g4e** | **19:5x–20:16** | **19 / 19 ✅（代表运行）** | — | 用 `caffeinate -u -i -d -s` 包住整条 gate（声明用户活跃 + 禁止空闲 / 显示器 / 系统睡眠）：各路生产者**迟到 0、唤醒 max 0.05–0.11 ms**（g4c / g4d 是 9–18 ms），V2 0、V4 两个口径 0、V5 +0、A4 0.208 ms；`assistantd` 仍在跑（33%），所以拖住线程的不是它的 CPU，是用户"空闲"时的电源 / 定时器策略。V1 avg 2.038 / p99 2.511 ms（三次里最好），S3 CPU 55.1% / GPU 28.7% |

**结论**：合并后的代表运行是 g4e（19 / 19）；g4c / g4d 的红是用户不在时的环境（生产者线程唤醒晚 10–18 ms）和一处工具平局缺陷，不是本批代码的问题。**gate4.sh 从此自动用 `caffeinate -u -i -d -s -w <headless pid>` 护住运行段**（§11.1 表外的一条小胶水），无人值守时也能拿到干净数据。

**没有退步的证据**（三次都稳定，且都好于或等于 g4b）：V1 avg 2.068–2.120 / p99 2.558 ms（g4b 2.094 / 2.859）、V3 p99 ≤ 0.044 ms、V4 frameprobe 在播段 0、V5 |Δ| ≤ 1、V6 90 次 Cut 全干净、V7 Fade ≤ 0.55 帧 / Wipe ≤ 0.05 / Zoom ≤ 0.01、A1–A3 0、E1–E3 / E5 全过、C1–C4 全过、S3 CPU 50–55% / GPU 23–26%。
W3-B2 的渲染器改动（标签线程、电平表三块交接、按需建环）没有让 V1 / V2 / V3 变差；headless 每秒 `setMeters` 也没有。**基线不动**。

### 11.4 等用户的

0. **桌面可见（解锁、当前 Space 不是全屏 App）时补跑两组出帧类测试**（本次锁屏跑不了，gate 之后又试了一次仍是 0 帧）：`swift test --package-path Packages/SwitcherOutputs --filter ExternalTests`（约 1 分钟，会在屏上开全屏窗口几秒）和 `make test-app`（约 3 分钟）。预期 ExternalTests 14 个 2 跳 0 失败、App 只剩已知的 UISmokeTests 偶发；红了就是本次合并的问题，回报我。
1. **提案 017**（Stats.audio.meters 加 rms_db；批了由 P4 / prompt 67 落地，混音器 C 热路径要多算一项）。
2. **电平表颜色分段统一**：W3-B2 定的 −18 黄 / −6 红（广播常见）vs 调音台 MeterBar（−6 红两段）vs 纯音频缩略图 NSLevelIndicator（−6 / −1.8）。建议采用 W3-B2 那套并补进设计方案 §7（设计方案不归检查点），W3-E3 照改。
3. **UISmokeTests"每秒最多 60 次快照分发"偶发 61**（W3-E2 §5 第 13 条）：(a) 冒烟开头清零、只量本条；(b) 按 Timer 触发序号数。建议 (a)，W3-E3 做。
4. `removeInput` 清 stinger 引用、API 进来的旧键先搬迁——两条 reducer 小规则建议做，已写进 P4（prompt 67 第 3 条），不同意就划掉。
5. **两张退 W1-A 的工具口径单**（不等拍板，知会）：`G4b-w1-testkit-selfcheck-rhythm-vs-realtime-feeder`（自证的节奏一票把实时喂送的图案帧判掉——推流测试改用 `--no-self-check` 传输口径）；`G4b-w1-testkit-a4-click-pairing-tie-at-half-second`（A4 多文件对齐在闪光落 x.500 s 时平局打法不一致 → 999.98 ms 假红，g4c 撞上）。W1-A 下一次续做一起收。

## 12. 第三轮（2026-09-24）：提案 017 落地、电平表三处统一、UISmoke 计数改法（用户："017 批了，电平表按你说的，UISmoke 用 (a)，都顺手做了"）

| 事 | 落点 | 说明 |
|---|---|---|
| **017 RMS** 契约 | `SwitcherContracts/Stats.swift`：`BusMeter` / `InputMeter` 加 `rmsDb`（`rms_db`，显式 `init(from:)`、缺键 = 空数组、写出总写全）、`jsonKeys` 加一项；`Contracts017Tests`（新）+ StatsP2Tests / CodableTests / Samples 的字面量跟改 | 老 stats.jsonl 缺键解成 []，读表的照只有峰值画 |
| 017 C 热路径 | `sw_audio_rt.h` 两个表结构加 `mean_square`；`sw_mix_internal.h` 输入槽 / 总线加 `rms_sq` 状态；`sw_mix.c` 输入推子循环与总线增益循环各多两次乘加（平方和），块尾一步一阶平均 `alpha = frames / (0.3 s · sr)`（不进 libm，不用 expf / sqrtf；`check-rt-symbols` 审计清单不变），快照拷进 `mean_square`；`SW_CMD_RESET_METERS` 也清它 | 开方与 dB 换算在 Swift 侧（`AudioMixer.BusMeter/InputMeter.rmsDb`），回调里只有乘加 |
| 017 集成层 / 渲染器 | `AudioEngine.statsMeters` 填 `rmsDb`，`AudioEngineStatus.InputStatus/BusStatus` 加 `rmsDb`；渲染器 `MultiviewMeterTable` 多存 (RMS L, R)（NaN = 没有），`drawMeterLevels` 有 RMS 时画"RMS 实心条 + 峰值 2 px 细线 + 保持线"、没有时与 W3-B2 相同；新参考图 `Tests/References/v8-multiview-meters-rms.png`（`v8-multiview-meters.png` 不重生成，两张都比） | headless / App 的 `setMeters` 喂的是整份 Stats.audio.meters，自然带上 rms_db |
| **电平表三处统一**（设计方案 §7 新增一条口径） | 调音台 `MeterBar` 改三段色（< −18 绿、−18…−6 黄、≥ −6 红）；纯音频缩略图 `NSLevelIndicator` 的 warning / critical 改 0.7 / 0.9（= −18 / −6）；多画面本来就是这套 | 用户授权改设计方案（不归检查点的文件，OWNERSHIP G4 行记了） |
| **UISmoke 61 / 60 → (a)** | `MainWindowController.resetSnapshotRateStats()`；`UISmokeTests` 开头清零，只量本条用例 | 阈值 60 没动 |
| 文档 | CONTRACTS.md §2.7、测试标准 §7 字段表加 rms_db、提案 017 状态、prompt 67（017 不用做了）/ 68（电平表与 UISmoke 已做）、Tests/References/README | |

### 12.1 测试

| 步骤 | 结果 |
|---|---|
| SwitcherContractsTests | 79 个用例 0 失败（1 跳过原有）；含 Contracts017Tests |
| SwitcherAudio MeterTests + IntegrationTests 的表用例 | MeterTests 15 / 0（新 `test017_rmsIsPeakMinus3dBForSine_settlesWith300msTimeConstant`：正弦 RMS = 峰值 − 3.01 dB ± 0.1、右声道 −120、静音后 300 ms 掉 4.34 ± 0.5 dB）；`testP2_audioCounters_carryMetersAndDiscontinuities` / `testMonitor_busAndInputParametersFromState` 过 |
| SwitcherRenderTests | 93 个：92 过、1 失败 = `DisplayDecouplingTests.testDisplay_maxFrameRateCapsThumbnailBlits`（blit 0 次：显示器仍不可见，与 §11.2 同一环境原因）；新 `testV8_multiviewMetersWithRMS`（参考图 PSNR ∞ + 结构断言）、`testMultiview_meterFeedCarriesRMS` 过，24 + 1 张参考图全部 PSNR ∞，零分配用例照过 |
| App（UISmokeTests / MixerPanelTests / LocalizationTests / MultiviewLayoutTests / InputWiringTests 五个类，`caffeinate` 下） | 15 过 1 失败：唯一红的是 `InputWiringTests.testInputs_builtInCameraLiveWithin5sAndPictureShows`（"缩略图格子应在画"——合盖、内置摄像头与窗口都不可见，环境，与 §11.2 同类）；UISmoke 两条过，清零后本条的快照分发峰值 39 / s；`testMixer_perInputAFVToggle…` / `testMixer_stripsMetersAndCommands` 过（MeterBar 改三段色没影响读数断言） |
| lint | 禁词 / 版本 / Package.swift 约束、依赖方向、实时符号审计（清单不变）、归属（App 胶水 24 / 50）全绿 |
