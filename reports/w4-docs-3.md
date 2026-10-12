# W4-C3 手册续做：100–102 的几节、两张主窗口截图、命令数 42、兼容层覆盖表（prompt 109，分支 w4-docs-3）

分支：桌面端开的 worktree 分支 `claude/w4-docs-3-manual-4251da`；prompt 里叫 `w4-docs-3`，本地另打同名引用（`git branch -f w4-docs-3 HEAD`）给 `check-ownership.sh` 用，两个名字指同一个提交。
基线 main `22ff4d9`（G8b 续 10-12 之后的 main）。机器：MacBook Pro M5 Max（128 GB），macOS 27.0.1（26A434），Xcode 27.0，Python 3.14.7；同机有 110 / 112 等会话在编译、跑包测试。
不 push、不 merge；做完交给 G9（prompt 114）。

提交（`git log 22ff4d9..w4-docs-3`）：
`2221bfc` 中文手册 → `79ae43a` 英文手册 → `d6e5e53` 兼容层 / Stream Deck / Companion / API 文档 → `002b9d7` README 与测试索引补 G8 → `544b919` make manual →
`86ecb8b` 两张主窗口截图 → `e6ea8d4` make manual → `02086b2` 问题单 → `127fd13` 核对后的修正（对 main 的代码）→ **`bfa6806` 跟 110 + 112 合入后的行为** → **`5e62a8d` 跟 112 第 3 项（监听菜单）** → `0e5c711` 第二轮核对的修正（对 main 的代码）→ **`e4fb0c9` 第二轮核对的修正（110 + 112 那几句）**
→ `bdb6bbc` 本报告 → **`768b78e` 跟 111 合入后的行为（推流鉴权失败就停）** → 本报告补 111。
（加粗的四个提交整体依赖别的分支：前三个依赖 110 + 112，`768b78e` 依赖 111，见 §3 第 1 条。）
40 个文件，+845 / −364（不含本报告）。

## 1. 做了什么

### 1.1 手册（交付 1–4，中英各一份，菜单 / 按钮名逐字照 Localizable.strings）

按 main 22ff4d9 的**代码**写（各会话报告只当线索）：TransitionPanelView / TransitionSlotText / ColumnSplitButton / TBarView / SwitchMenu、InputCellView / InputSettingsPanel、
OutputStatusPanel / OutputButtonSummary / StatusLineFormatter / BottomBarView、OutputPagesViews / StreamAddress、AudioSettingsPanel / EffectChainView / AudioOutputSettings / MixerPanelView、
SwitcherSession（监听同步接线、借 Master）、HotkeyTable / ControlAction / ActionCatalog / ActionPicker、AppController.documentContent，引擎侧 MixerReducer、AudioEngine、sw_mix.c、InputEffects。

| 页 | 改了什么 |
|---|---|
| 概念 / concepts | 新 **转场槽** 一节（出厂四槽表、当前槽与蓝条、改槽只改设置且进行中也收、秒按标称帧率换拍、老节目补槽规则）；**转场列**整节重写（Cut ｜ 转场 1–4 主体 + ▾ ｜ FTB 主体 + ▾ ｜ Overlay ｜ "T-bar"组 = 弹出按钮 + 当前槽时长分段 + 横放 T-bar ｜ 时钟；▾ / 右键菜单逐项；Stinger 槽没选输入；T-bar 左 0 右 1、过 97% 松手提交回弹、没过停住；当前那组对不上槽时的样子）；FTB 时长可改；菜单栏"切换"= Cut ／ 执行当前转场 ／ 转场 1–4（点了就做）／ FTB ／ Overlay ▸；底栏 / 工具条带时长（"● 录制 01:02:05""● 推流 00:10:00（2/3）"，读 uptime_s、多路取最长、推流含重连期）、录制 ▴ 末尾"录制状态…"、推流 ▴"推流状态…"开状态窗；**状态行三项**"编码滞后跳帧 · 录制 · 推流"；音频：**每路效果已生效**（每路 EQ ≤ 16 段 + 一个动态格、顺序固定 EQ → 动态、每路不装限幅）、两种压缩器与 `compressor` 的起音 / 释放口径、**监听同步**（画面同样延后、状态窗"视频延后 n ms"、录制从输出时间线 0 起、只按 Master）、**耳机出口 = 监听来源**（默认 Master，独听时独听的路）、**2 声道设备借 Master 声道**（当场生效）、监听菜单（main 上灰着，`5e62a8d` 起按 112 的四项写）；未保存判定（换当前槽也算、暂停 / 定位不算） |
| 输入 / inputs | 视频文件新一节 **播放**（⏮ / ▶⏸ / 🔁 表、关循环 = 停在末帧、播完再开循环当场接着循环、**切上 PGM 时从头播**与首帧晚约 3 拍、暂停不算未保存、对应命令与选动作面板）；只改"播完 / 播放速率"当场生效不重建；格子第一行 × ｜ 转场 ｜ Cut ｜ ⏮ ｜ ▶⏸ ｜ 🔁（"转场"= 当前槽）与右键多四项；输入设置"音频效果"一行（已生效、限幅那一节对每路无效）、"来源"一行（当场生效、播放一节） |
| 输出 / outputs | 录制页 / ISO 页的"录制状态…"、时长列、▴ 行带时长；新一节 **推流 / 录制状态窗**（五个入口、两页的列、最后错误、事件记录与 1 Hz 口径、窗口关着也记、"视频延后 n ms"、"显示日志…"的实情、窗口在前不转发按键）；底栏推流时长；**鉴权"写法"二选一**整节重写（Adobe / 查询串、参数名可改与限制、互斥、打码名单与"会显示明文"提醒、选错写法的后果、开关开着时锁）；地址框打码范围 |
| 快捷键 / shortcuts | 默认表 ⌥1–⌥4 = 执行转场 1–4、回车 = 当前槽；哪些窗在前时转发按键（设置窗已转发，X12 那句删掉；统计窗 / 状态窗 / 多画面窗口不转发）；老 hotkeys.json 不升级的绕法；选动作面板"执行转场 / 选中转场（不执行）"、槽号控件、`setInputAudio` 的"不改 / 开 / 关"与总线路由勾选；hotkeys.json 样例与动作表加 `transitionSlot` / `selectTransitionSlot`；Stream Deck 一句 |
| 设置 / settings | 音频设备页：耳机那一对声道平时放 Master、借 Master 声道已生效（"引擎支持后生效"删掉） |
| 故障排查 / troubleshooting | 推流鉴权几行（写法选错、最后错误、断线经过看状态窗）；画面与声音几行（监听同步让画面晚、Bus A / B 不补、每路效果听不出变化的真正原因、耳机里是 Master、独听比画面早、2 声道借 Master）；界面几行（快捷键不派发的窗、Stinger 槽弹列表、T-bar 回弹、⌥n 不分槽）；诊断文件夹 |
| README | 快速上手第 3 步（回车 = 当前槽、⌥2）、目录描述 |

### 1.2 兼容层 / 集成 / API（交付 5）

- `docs/integrations/vmix-compat.md`：§6 覆盖表按 W5M 问题单第 1 条——Cut 带 Input 转场中 409、Stinger1 = 第一个选了输入的 Stinger 槽、Transition1–4 = `useTransitionSlot(n, true)`（进行中 "(no change)"）、SetTransitionEffect1–4 / SetTransitionDuration1–4 = 只改槽；"明确不做"删 Transition2–4、加文件播放；§4 XML `<transitions>` 四项；§8 限制按实情（position / duration / loop 恒定值、Blank 占位 Paused）。
- `docs/api/vmix-compat.md`（Companion 动作覆盖表）同步；`docs/integrations/stream-deck.md` 按钮表加 **Transition 1–4**（设置、按下、颜色、小字）；`docs/integrations/companion.md` 原生模块骨架加转场槽命令与 currentSlot 反馈。
- `docs/api/README.md`：第 9 行 **34 → 42**（`docs/api.md` 生成物数过是 42 条）；§3 批量在转场中的结果；§5 stats 表加 `uptime_s / disconnects / last_error / attempt` 与顶层 `video_delay_ms`；§6 现行口径（转场槽、文件播放、每路效果已生效、`compressor`、监听同步按视频延后补、`setMonitorSource`、起不来的路看 `last_error`）。
- `docs/api/examples.md`：批量例子旁加 W5M 问题单第 4 条那一句、加"执行转场槽 2"一例、Companion 表两行。`docs/api.md` 是生成物，W5M 第 4 条的另一半（APIDocument.swift 的批量例子）不在本会话目录（§3）。

### 1.3 截图（交付 6）

- 两张主窗口截图中英各一，**活动样例**、1440×900、PGM 1 / PVW 2、当前槽 = 转场 1（`docs/user/img/main-window-{zh,en}.jpg`，240 / 246 KB，JPEG q90）。新图里能看到按槽的转场列（四个槽按钮、当前槽蓝条、FTB ▾、"T-bar"组、横放 T-bar）与格子第一行的 ⏮ ▶⏸ 🔁。
- 做法同 reports/w4-docs-2.md §5 第 5 条：`defaults export com.plusmix.switcher` 备份 → 在草稿区放活动样例副本（`layout.mainWindowFrame = "{{120, 60}, {1440, 900}}"`，英文版把输入 / 输出名换成英文）→
  直接执行 `PlusMix.app/Contents/MacOS/PlusMix --show <副本> --audio-device null --api-listen 127.0.0.1:8797 -AppleLanguages "(zh-Hans)" / "(en)" -ApplePersistenceIgnoreState YES` → 等 API 通、再等 6 s →
  CGWindowList 找窗口号 → `screencapture -x -o -l<号>` → `sips -Z 1440` → `kill` → `defaults import`。导回后与备份**逐键相同**（plistlib 比过），`LastSession.switcher.json` 没动（还是 10-11 那份）。
- 状态窗、鉴权表两张没拍（§3 第 4 条）。

### 1.4 make manual、lint、核对（交付 7）

- `make manual` 重生成 `App/Resources/Help/`：18 个文件，815.1 KB（中英各 7 页 + 两张图 + index / css；跟 111 之前是 806.8 KB）；`build-help.py --check` 0.05–0.06 s。
- 核对：写完开两个 agent 逐句对代码（中文 7 页约 300 处事实；英文 6 页 + 兼容层 / Stream Deck / Companion / API 约 400 句），每条我再对代码复核后改（`127fd13`）；`bfa6806` 之后第二轮再开一个 agent 核两个新提交（172 行），复核后改在 `0e5c711` / `e4fb0c9`；跟 111 的 `768b78e` 第三轮一个 agent 对 111 的代码核（§2.4）。
- 写手册时与核对时查出的实现缺口写成问题单 **`reports/issues/W4C3-w5-app-gaps-found-by-docs.md`**（15 条；第 7 条 **⇧1–⇧0 直切 PGM 用实体键盘对不上**是 S2，其余 S3；第 15 条只在 111 合入后成立）。

### 1.5 与并行会话的同步（prompt："109–113 并行，别的会话修了什么告诉你再删绕法"）

112（W5-O，分支 `w5-app-followups`，写报告时 = d96d18d、叠在 110 的 `p5-contracts-3` = 9af1bf0 上）发来三次通知与同步单 `reports/issues/W5O-w4-docs-3-manual-followups.md`（在它的 worktree 里）。每一项都对它的代码（提交 976b365 / 94ff3be 即同步单里的 03f4d25 / 18d5b45 rebase 后、ff8c526、b81c2ac、b8a29fc、4d9a090、30667ff、b20f21d、9c922a6）与 110 的 10cb844 / 07a2df4 核过再写：

| 112 / 110 的项 | 手册怎么改 | 在哪个提交 |
|---|---|---|
| 1 外部显示 Esc 只关不删、按钮改名"删除这一路" | 输出 / outputs 外部显示一节两处警告改回"Esc 关闭这一路（配置留着）"、按钮名换新字 | `2221bfc` / `79ae43a`（与 100–102 的改动在同一提交里） |
| 2 设置页只写改了的键；放开到局域网时令牌一起存 | 设置 / settings"启动参数"一段：警告删掉，写"只存改了的那一项"+ 监听地址半改 + 令牌例外 | 前半 `2221bfc` / `79ae43a`，令牌例外在 `bfa6806` |
| 7 X51：31 个名字回 501 | vmix-compat.md 删"31 个回 400"那句、把这 31 个名字并进"明确不做 = 501" | `d6e5e53` |
| 4（+ 110 的 029）没选输入的 Stinger 槽拒收 | 概念 / 快捷键 / 故障排查 / 兼容层 / Stream Deck / API 各处：界面三处先弹输入选择，其余入口被拒（状态行一句 / 409 / 闪警告 / 400 / MIDI 不提示），只选中与 T-bar 照常 | `bfa6806` |
| 110 的 026 | `setMonitorSource` 可以是耳机总线自己 | `bfa6806` |
| 5 分类颜色进 InputConfig.color | 输入 / inputs 分类一条 | `bfa6806` |
| 6 压缩器简单模式、限幅天花板 | 概念 / concepts 音频与音频设置窗表、输入设置"音频效果"、API README | `bfa6806` |
| 8 声道对算待应用、导出导入补键、⌃n 空通道用 PVW、midi.json 读不出提示、无信号第二行写原因、NDI® 横幅、低于下限切备用目录提示、英文格子按标题宽分 | 设置 / 快捷键 / 概念 / 输入 / 故障排查（中英） | `bfa6806` |
| 3 监听菜单四项（Master / Bus A / Bus B / 耳机总线，发 setMonitorSource，勾跟快照） | 概念 / concepts"耳机出口""监听菜单"、设置音频设备一句、故障排查一行 | `5e62a8d` |

111（W2-D4，分支 `w2-stream-4` = worktree 分支 `claude/w2-stream-auth-stop-f35a11` = **506a0ff**；代码最后一次改在 0dd3e4a，之后两个提交只加一条 App 用例、报告与同步单）没发消息，
在它的 worktree 里留了同步单 `reports/issues/W2D4-w4-docs-3-stream-auth-stops.md`（给 109）。对 0dd3e4a 的代码（506a0ff 的代码与它相同；StreamOutput.run、HaishinKitTransport、RTMPAdobeAuth、StreamTransport、OutputRuntime.noteStats / failureReason、
OutputButtonSummary、OutputStatusPanel、推流页 OutputPagesViews / OutputSettingsPanel）核过再写：

| 111 的行为 | 手册怎么改 | 在哪个提交 |
|---|---|---|
| 服务器拒绝鉴权（Adobe authfailed / nosuchuser、要 Adobe 而地址里没账号、publish 回 `NetStream.Publish.Unauthorized`、llnw）被拒那一次就停在 failed（`attempt` 0），第一次连接、重连都一样；连不上 / 断线照旧一直重试 | 输出 / outputs"重连"一条加例外、"推流鉴权"一节整条重写（状态行那句、底栏深红"推流 · 起不来"与悬停、推流页"起不来：…"不锁、状态窗"失败"与事件、API 字段、三种原因开头、改对后点重试、MediaMTX 两种写法、认不出的拒绝） | `768b78e` |
| last_error 是干净的"鉴权失败（…）：服务器原文"（原来是 `连接失败：connectFailed("鉴权失败…")`） | 状态窗"最后错误"一条的例子换成新的，连不上那一种留作"带程序写法"的例子；故障排查三行改成按开头认 | `768b78e` |
| 停下的那一路按"起不来"显示：推流页那段不锁、有"重试"，但**改地址 / 账号不自动重试**（还在运行表里，`reconcile` 不管） | 输出 / outputs"起不来的那一段不锁"一条补这一种的例外；页上红字"改好会自动重试"对它不成立 → 问题单第 15 条 | `768b78e` |
| App 里推流的 `uptime_s` / `last_error` 原来一直是 0 / 空（`EncoderStatsSource` 没用 `StreamOutput.statsEntry`，111 §4 / §5 第 3 条；headless 一直对），111 补上 | 不用改字：手册这几句本来就按"有"写（底栏 / 工具条 / 标题的推流时长、状态窗推流页"时长 / 最后错误"两列与"断开：原因"事件、故障排查"想知道断过几次"一行）——**它们也要 111 合入才成立**，见 §3 第 1 条 | （`2221bfc` / `79ae43a` / `d6e5e53` 里） |
| API：被拒停下的路要 `stopStream` 再 `startStream` 才重起（两条要隔开：App 按 60 Hz 看快照、只在 `outputs` 变了时 reconcile，紧挨着发看不到中间那一下）；`attempt` failed 时 0 | API README §6 加一条（先 stop、等 `stats.encoder[]` 里不再是 failed 再 start）、§5 `attempt` 补"failed 时 0" | `768b78e` |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

文档会话没有测试 ID；交付 7 的判据与本会话自己加的核对逐条如下（全部本机实跑）。

### 2.1 lint 与生成物

| 项 | 结果 | 判据 | 通过 |
|---|---|---|---|
| `make lint BRANCH=w4-docs-3`（最后一次在 `768b78e` 上、报告改动未提交时，退出码 0） | 禁词（含 App/Resources/Help 产物）/ 版本 0.1.0 / Package 约束 / 依赖方向 8 包通过；**check-ownership：41 个改动文件都在允许范围内**（含本报告与问题单）；check-help：`App/Resources/Help 与 docs/user 一致（18 个文件，815.1 KB）`；check-links：189 个 Markdown 的相对链接与锚点都能解析；check-rt-symbols 通过 | 全绿 | ✅ |
| `python3 docs/tools/build-help.py --check` 连跑三次 | 0.06 / 0.05 / 0.05 s，一致 | 一致 | ✅ |
| 内置浏览器看产物（127.0.0.1 起静态服务） | `zh-Hans/concepts.html#转场列` 三层嵌套列表正常、锚点直达；`en/outputs.html#stream--recording-status-window` 表格与列表正常 | 目视 | ✅ |

### 2.2 App 构建与截图

| 项 | 结果 | 通过 |
|---|---|---|
| `make gen` + `make build-app`（本 worktree） | BUILD SUCCEEDED；`PlusMix.app/Contents/Resources/Help/` 有 `en/`、`zh-Hans/`、`img/`、`index.html`、`style.css` | ✅ |
| 两次截图运行的 API 状态 | 两次都是 PGM 1 / PVW 2、currentSlot 1、槽 = [fade 30, wipe 60, zoom 60, stinger 60]（活动样例没有槽，打开时按出厂补、转场 1 = 文件里那组 Fade 30 拍） | ✅ |
| 本机设置不受影响 | 两次 `defaults import` 之后 `defaults export` 与备份逐键相同；`lastShow` 没指向草稿区；`LastSession.switcher.json` 时间戳不变 | ✅ |

### 2.3 文档里的样例能用

| 项 | 结果 | 通过 |
|---|---|---|
| 快捷键 / shortcuts 的 hotkeys.json、midi.json 样例（中英共 4 段） | 草稿区探针包（依赖 Packages/SwitcherControl）用 `HotkeyTable.load` / `MIDIMapTable.load` 真解：4 段都过；`alt+2` → `useTransitionSlot(2, true)`、`ctrl+alt+4` → `useTransitionSlot(4, false)`；默认表 31 条、冲突 0、⌥1–⌥4 = `transitionSlot(1…4)`、回车 = `autoTransition` | ✅ |
| 组合键能不能按出来（新加的核对） | CGEvent → NSEvent 探针（不投递事件）：`⌥1 → "1"`、`⌃1 → "1"`、`⌃⌥3 → "3"`、`⌃⌥4 → "4"`、`⇧A → "A"`，**`⇧1 → "！"`（拼音输入法；美式键盘是 "!"）、`⌥⇧4 → "¥"`**——样例原来的 `alt+shift+3` / `alt+shift+4` 按不出来，换成 `ctrl+alt+3` / `ctrl+alt+4`；默认表 ⇧1–⇧0 同样按不出来（问题单第 7 条） | ✅（样例改后） |
| `docs/api.md` 命令数 | `#### ` 命令标题 42 个（切换 12、叠加 3、音频 9、输出 6、输入表 8、输出表 3、节目 1） | ✅ |

### 2.4 逐句对代码核对

| 轮次 | 范围 | 查出 | 处理 |
|---|---|---|---|
| 第一轮 A（中文） | 7 页约 165 行新增 / 改动、约 300 处事实，对 main 的代码与 zh-Hans 字串表；03f4d25 的三处对它的代码 | 明确不符 10 处、不完整 10 处、代码 / 文案缺口 9 条 | 逐条对代码复核后改（`127fd13`）；缺口进问题单 |
| 第一轮 B（英文 + 集成 / API） | 约 210 行、约 400 句，对 main 的代码与 en.lproj；03f4d25 / 18d5b45 的几句对它们的代码 | 必改 7 处、建议补 7 处、新缺口 8 条 | 同上 |
| 第二轮（`127fd13` 与 `bfa6806` 的新句子，前者对 main、后者对 d38cbf5 的代码；中英一致性抽查约 40 对） | 172 行（127fd13 78 行、bfa6806 94 行） | 实质不符 5 处、小问题 3 处、中英不一致 2 处，另 App 文案矛盾 1 条 | 复核后改：对 main 的在 `0e5c711`，110 + 112 那几句在 `e4fb0c9`；两处只在 revert `bfa6806` 时才会回来的句子写进 §3 第 1 条；文案矛盾进问题单第 14 条 |
| 第三轮（`768b78e` 提交前，对 111 的 0dd3e4a 与 main 的 App 代码；中英对照） | 5 个文档约 76 行 | 实质不符 2 处（`stopStream` / `startStream` 紧挨着发 App 看不到中间那一下、不重起；SRS / nginx-rtmp 回调拒绝不在"第一次就停"里）、小问题 5 处（带 Adobe 账号遇 llnw 时冒号后不是服务器原文；"几个目的地"应为"开着几路"；MediaMTX 的触发条件是发布名不空、平均约两次才停；鉴权小表"开着锁着"与新内容矛盾；红字只有前半句不成立） | 逐条对代码复核后改完才提交（`768b78e`）；英文界面原文与中英一致性无问题 |

两轮里改正的要点：状态窗的事件不带鉴权失败原因（只有"最后错误"有）；"最后错误"整行是 `连接失败：connectFailed("鉴权失败…")`；查询串只认几个参数名；监听菜单"耳机总线（现在）"那一项不打勾；
Stinger 没选输入是"画面第 1 拍就硬切、状态机等满时长才对调"而不是"延迟硬切"；压缩器起音 / 释放与"63%"的关系看超阈值多少、不看比例；`peakLimiter.ceilingDb`；延迟上限"最多约 35 ms"（限幅起音可到 1 ms、自写压缩器 0）；
耳机总线有独听时只有独听的路；耳机出口 = 监听来源；独听"与画面对齐"只在 Master 没效果时成立；T-bar 推到一半改槽再拉回 0 的例外；T-bar 行高亮条件；状态行 failed = "推流 0 b/s"；
"显示日志…"是在 Finder 里选中；currentSlot 对不上时快照里缺键；Stream Deck 的动作名是 "Transition 1–4"；XML 的 Blank 占位是 Paused；循环走 `setInputSource`；⇧ 数字快捷键与样例；
第二轮又改：只有 Adobe 写法会出"鉴权失败"（查询串写法是 `NetStream.Publish.Unauthorized` 或超时）、"鉴权方式不支持"就是 llnw；"35 ms"只对一格动态 + 一格限幅成立；Stinger 硬切在换底拍那一拍（出厂 0 才是第 1 拍）；延迟自测装格和改参数都量；菜单项原文"Stinger（选输入…）"；中英 ⌃n、格子宽度两处对齐。

## 3. 没做的和原因

1. **`bfa6806`、`5e62a8d`、`e4fb0c9` 三个提交整体描述的是 110 + 112 合入后的行为，`768b78e` 描述的是 111 合入后的行为**（§1.5 两张表）：G9 要 110（`p5-contracts-3`）→ 112（`w5-app-followups`，已叠在 110 上）→ 111（`w2-stream-4` = 506a0ff）→ 109 一起合。
   **111 不合时**：`git revert 768b78e` 后 `make manual`；另外 App 里推流的时长 / 最后错误在 main 上是 0 / 空（§1.5 第二张表第 4 行），手册里那几句（底栏 / 工具条 / 标题的推流时长、状态窗推流页"时长 / 最后错误"两列与"断开：原因"事件、故障排查"想知道断过几次"那一行的"为什么"）
   要么进 KNOWN_ISSUES、要么 G9 把 111 里 `EncoderStatsSource` 那一行（`s.statsEntry(counters:…)`，App/Sources/Engine/OutputRuntime.swift）单独拿进来——后者是 1 行胶水。
   **112 不合时**：`git revert e4fb0c9 5e62a8d bfa6806` 后 `make manual`（产物要按 revert 后的 docs/user 重生成），并把前面提交里 112 第 1 / 2 / 7 项的几句改回 main 的说法：
   `docs/user/输出.md` 与 `en/outputs.md` 外部显示一节的"删除这一路 / Remove This Output"按钮与 Esc 两句、`docs/user/设置.md` 与 `en/settings.md`"启动参数"一段、`docs/integrations/vmix-compat.md` §6"明确不做"末尾 31 个名字那句与"完全不认识的名字返回 UnknownFunction（400）"。
   main 的说法在 `22ff4d9` 的同一位置（G9 拿 `git show 22ff4d9:<文件>` 对着改即可）。revert 之后会回来两句第二轮查出的不准确写法，一起改掉：概念 / concepts Stinger 一条里"这段时间 tally、AFV 按旧的走"→"这段时间 tally 两路都算 PGM、AFV 按满时长交叉淡变、别的切换被挡（Cut 可以立即做完）"；
   限幅那一条"界面上改一次限幅会把它清回 0"→"在界面上改这条总线的任何一项都会把它清回 0"（main 的音频设置窗整条重发 setBusEffects）。
2. **112 写报告时还在做**：之后若再改手册涉及的行为，按同步单（它的 worktree 里 `reports/issues/W5O-w4-docs-3-manual-followups.md`）续改；本会话核到 d96d18d 为止（其中 9c922a6 只改英文小档格子的截断顺序，手册"小档仍可能截"那句照样成立）。
3. **111（W2-D4）的几处已跟上**（`768b78e`，§1.5 第二张表）。111 交用户定的三条（它的报告 §4）若改了，手册跟着改：底栏这一种改写"失败"→ 输出 / outputs 鉴权一节与故障排查推流鉴权一行的"推流 · 起不来"；
   "服务器要账号、地址里没写"不停 → 鉴权一节"原因看开头"一条与故障排查那一行删掉；"应用 + 密钥"推 MediaMTX 修成第一次就停 → 鉴权一节 MediaMTX 那一条。
4. **状态窗、鉴权表两张截图没拍**："若放得进手册也拍"——这两扇窗只能从菜单 / 按钮打开，本会话的进程没有辅助功能权限（`AXIsProcessTrusted() = false`），不能用脚本点菜单；不想用 computer-use 抢用户桌面（同机别的会话在跑）。要拍就请用户点开、或在 G9 的 L3 清单 §12"把看过的窗口各截一张"一起拍。
5. **英文截图里格子的 "Transition" 是截成 "Transit…" 的样子**（main 的样子）；112 第 8 项改成按标题宽度分（小档放不下时先截 Transition、保住 Cut）之后中档不再截，手册文字按合入后写。G9 合入后想要一致可以按 §1.3 的办法重拍（几分钟）。
6. **`docs/api.md` 的批量例子那一句**（W5M 问题单第 4 条的另一半）：生成物，要改 `Packages/SwitcherControl/Sources/SwitcherControl/API/APIDocument.swift` 再 `switcher-apidoc` 重生成，不在本会话目录；docs/api/README.md 与 examples.md 已写。
7. **`docs/KNOWN_ISSUES.md` 没改**：文档那一行（S3"手册里转场列……还是 100–102 之前的写法"）与 112 修掉的几行，按惯例由 G9 合入时销号；新问题单 W4C3 的 15 条（⇧ 数字一条 S2）请 G9 定要不要进表；111 合入后"推流密码错了一直按退避重试"那一行（111 报告说可挪进已修）的手册部分已由 `768b78e` 跟上。
8. **`docs/checklists/G8.md`** 里几条写着"手册还是 100–102 之前的写法"、"Stinger 外部入口照常执行"、"压缩页仍是 024 (c) 的写法"等，合入 110 / 112 / 109 之后都过时了；清单归检查点，没动，G9 写 L3 清单时请对照。
9. 规格（docs/spec）、计划（docs/plan）、`CHANGELOG.md`（G9 类）、`docs/ui-study/img/改后/` 按 prompt 不动。

## 4. 对契约的疑问

没有改契约，也没有要停下来的提案。几点给后面参考：
1. **T-bar 推到一半改了当前槽、再拉回 0，当前那组不按槽重拷**（问题单第 10 条）：提案 020 只写了"完成那一拍重拷"。要在 reducer 里让"T-bar 回到 0"也重拷，是转场口径的改动，请走提案；手册照实写了这个例外。
2. 029（110）对 T-bar 推没选输入的 Stinger 槽照常放行（推过换底拍的位置画面就换、推到顶才对调），这是 110 的定稿；手册照写。要连 T-bar 也拦，同样走提案。
3. 效果延迟进 Stats（提案 030，用户 10-12 没定）：手册只用 `video_delay_ms`（= Master 链的延迟）说事，Bus A / B 与每路的延迟界面 / API 看不到，照实写了"Bus A / B 不补"。

## 5. 下一个会话需要知道的坑

1. **改了 docs/user 一定 `make manual`**，`make lint` 的 check-help 会查；产物 18 个文件入库。docs/user 加新页要在 `docs/tools/build-help.py` 的 `LANGS` / `PAGES` / `nav` 里登记。
2. **写手册要对代码**，各会话报告、问题单、同步单都只当线索：本轮第一遍两个 agent 仍查出 17 处不符 + 17 处不完整（例如状态窗事件、last_error 的整行、监听菜单不打勾、Stinger "延迟硬切"的说法），大半是"按报告的说法写"。每条 agent 的结论我也再对一遍代码才改。
3. **并行会话修了东西、通知你删绕法时**：先对它分支的代码（它的同步单写的提交号可能被 rebase 过——112 的 03f4d25 / 18d5b45 rebase 后是 976b365 / 94ff3be，按分支头 `git show <分支头>:<路径>` 读最稳），
   再把依赖未合入分支的改动**放进单独的提交**（本会话的 `bfa6806` / `5e62a8d` / `e4fb0c9` / `768b78e`，只碰依赖那几行；对 main 的修正另成提交、不碰那几行），报告里列清哪些句子依赖哪一路，G9 好整提交 revert。
4. **快捷键样例别写 `shift+数字 / 符号`**：KeyCombo 用 charactersIgnoringModifiers，⇧1 是 "!" 不是 "1"（问题单第 7 条）；⌥ / ⌃ 组合与 ⇧ 字母没问题。验样例：草稿区建一个依赖 `Packages/SwitcherControl` 的小包，`HotkeyTable.load` / `MIDIMapTable.load` 真解；验"按不按得出来"：`CGEvent(keyboardEventSource:virtualKey:keyDown:)` + flags 转 `NSEvent(cgEvent:)` 看 `charactersIgnoringModifiers`（不投递事件，不打扰桌面）。
5. **隔离截图**（§1.3）：不要用测试宿主（会钉中文）；`defaults export` / `import` 包住整次运行，导回后用 plistlib 比一遍备份；`--api-listen` 用别人不用的端口（本会话 8797）；从 shell 起的 App 不在前台，工具条是非活动窗口的暗色，没去抢前台。
   本会话进程 `AXIsProcessTrusted() = false`，菜单里才打得开的窗（状态窗、鉴权表、设置窗各页）拍不了。
6. 英文界面里**几处一定截尾**：T-bar 那一行（"Transition 1 · Fade 0.5…"，出厂就截）、格子"Transition"（main 上中档截成 "Transit…"，112 后只在小档）。英文 `slot.stingerMenu.header` 的 "(it runs once chosen)" 读起来像"选了就执行"，手册里引原文、后面写清"再点一次才执行"。
7. 引擎 / 推流模块的文案只有中文（格子第二行的原因、最后错误、日志）：英文手册写"中文原文（英文注）"；"最后错误"里连不上 / 断线那几种带 `connectFailed("…")` 这样的程序写法（问题单第 8 条），111 之后鉴权失败那一种是干净的"鉴权失败（…）：服务器原文"。
8. **App 里推流的统计和 headless 不是同一处填的**：App 走 `App/Sources/Engine/OutputRuntime.swift` 的 `EncoderStatsSource`，headless 走自己的；main 上 App 那份漏了 `uptime_s` / `last_error`（111 补上）。写"统计里有什么"时两边都要看，别只看 `StreamOutput.statsEntry`——本会话前两轮核对都没发现这一处。
9. 同机并行：截图时看 `ps -axo comm` 有没有别的会话在跑 App 用例（本会话截图时只有 110 的 SwitcherEngineTests 包测试，不冲突）。
