# W4-C2 手册与实现再对齐、随包 HTML 手册、快捷键表重排（prompt 103，分支 w4-docs-2）

分支：桌面端开的 worktree 分支 `claude/w4-docs-manual-alignment-048f96`；prompt 里叫 `w4-docs-2`，本地另打同名引用（`git branch -f w4-docs-2 HEAD`）给 `check-ownership.sh` 用，两个名字指同一个提交。
基线 main `93f50d9`（G7 快进后的 main，2026-10-10）。机器：MacBook Pro M5 Max（128 GB），macOS 27.0，Xcode 27.0，Python 3.14.7；同机有别的会话在编译（负载 3–5）。
按 2026-10-10 裁定 ④ 这一轮只做 92–98 那一大段；**100（转场槽 / T-bar 横放）与 101（播放控制 / 推流状态面板）还没合入 main，那两节等它们合入后 rebase 再补**（§3）。

提交（`git log 93f50d9..w4-docs-2`）：`d6570b9` 中文手册重写 → `3b56dd9` 英文同步 → `578eb0b` 组合动作口径 → `3c674fb` 集成 / API / 发布 / 测试索引 / 示例 → `523dcd7` 截图 →
`40b1474` 随包 HTML 手册（脚本 + 产物）→ `2ad92bf` project.yml → `e5a141b` 日志命令全路径 → `3a60f8a` 两轮逐句核对后的手册修正（§2.4）→ `b0d8533` README 一句 → `44d97a3` 五张问题单 → 本报告。

## 1. 做了什么

### 1.1 手册跟实现（交付 1、2、5）

docs/user 中英各页按 86–98 各报告 §1 / §5、问题单 W5I / W5L / W4B2 / UIA-w4-docs 与两份 Localizable.strings 的原文重写（菜单 / 按钮名逐字照 strings，英文照 en.lproj）：

| 页 | 改了什么 |
|---|---|
| README / en/README | 目录加"设置"一页；交付 5 那句（"界面按 0.1.x 改版后的样子写；0.1.0 的老界面对照见 docs/ui-study/03"）；帮助菜单打开的就是本手册；版本写 0.1.x、语言在 设置 › 常规 |
| 概念 / concepts | 主窗口整节重写：App 实拍截图（中英各一张）+ 区域表（工具条、监视器齿轮与右键"全屏输出到"、转场列、调音台、输入条、底栏、状态行）；**底栏三段式**（⚙ / 主体 / ▴ 逐个按钮的表，录制 / 推流按最差那一路汇总、连接中 vs 重连中）；**停止前确认**；提醒 / 统计窗 / 界面锁（**界面锁没有默认快捷键**）；菜单栏全表（"偏好设置"→"设置"、"打开上次退出时的节目"、"输入 N「名字」设置…"、切换 / 输出 / 窗口 / 帮助菜单）；转场列按现状写（五个类型按钮点了就做、"Fade ▾"只选、FTB 时长界面改不了）；叠加独立窗（四个入口、整幅 / 画中画、新节目默认淡入 0.5 秒、时长按秒）；音频（**总线效果已生效**及范围、5–35 ms 监听延迟、每路未生效、调音台布局、监听菜单、响度详情、音频设置窗）；节目文件（未保存的点、新建 / 打开 / 退出先问、**退出不再静默写回**、LastSession 与"打开上次退出时的节目"、下次启动的口径）；"转场进行中 PVW / PGM 也被拒" |
| 输入 / inputs | 添加输入面板（分组、第一次停在摄像头、按类记忆、横幅"打开系统设置… / 看说明"、协商结果行、最近用过、文件信息、纯音频文件这一版报错、NDI® 每 4 s 重找 / 双击加、屏幕缩略图网格、图片多选与改了自动换上）；新一节**输入条与格子**（分类标签、搜索 ⌘F、调音台开关、两行按钮逐个、转场中置灰、右键菜单、拖文件进来、占位格、缩略图三档）；**关循环 = 停在最后一帧，要黑场去输入设置"来源"**；输入设置窗（新分节顺序、本路画面与取色、复制 / 粘贴位置、从其他输入复制、名字失焦即改、**跟随视频（AFV）开关**、音频延迟补偿） |
| 输出 / outputs | 输出总览；录制页（文件一节全部录制路共用、**文件格式单选**、参与录制、来源只能 PGM / 输入、按节目格式的默认码率、底栏只起参与的路）；ISO 表（格式 / 目录跟录制 1、PGM 行取消 = 只录 ISO）；磁盘下限与备用目录在 设置 › 高级；推流页（服务预设与哪些会填地址、质量档、编码详情、关键帧按秒、与推流 1 相同、合计上行、开关开着就锁（连接中 / 重连中也算）、起不来不锁 + 重试 / 停用、页底"添加目的地"、**重试间隔最长 n s（一直重试）**、底栏汇总与单路起停）；**推流鉴权**（Adobe user:pass@ vs MediaMTX 等的查询串、SRT passphrase 字符限制、鉴权失败的原因只在系统日志里）；本机先试改成 s1（原来写的 live 路径在仓库的 mediamtx.yml 里推不上）；NDI®；**"外部输出"→"外部显示"**（路由菜单单选、"关闭"只在有配置的屏列、主体全部开关、设置页"每块屏送什么"、**Esc 与"关闭这路"都是删除**）；虚拟摄像头设备名 **PlusMix**（W4B2 问题单）；多画面格子编辑、多画面输出只承载布局 |
| 快捷键 / shortcuts | **按 96 的默认表重排**（31 条：数字 / ⇧数字 / 空格 / 回车 / F / **⌥1–⌥4 执行转场 1–4（这一版 = 执行当前转场）/ ⌃1–⌃4 叠加开关**；录制推流与界面锁不给默认键；⌃1–⌃4 与系统"切换到桌面"同键的提示）；菜单快捷键补 ⇧⌘I / ⌘F / ⌘M / ⌘Q；改表（设置 › 快捷键，行内启用 / 录键 / 动作按钮 / 编辑 JSON… / 复制 / 删除，显式保存）；选动作面板；新动作的 JSON 表（fadeMs、previewAndTransition、recordAll、outputSwitch、busRoute、ui……）；MIDI（CC 只接推杆类、Note 接按钮动作）；tally 在 设置 › Tally、远程控制页 |
| 设置 / settings（新） | 一个"设置"窗：入口、本节目 / 本机两组页、即时生效 vs 待应用 + "应用并重起引擎"、快捷键 / MIDI 要显式保存、导出 / 导入 / 恢复默认（令牌不导出）、各页内容（常规里的提醒 / 操作确认 / 语言 / PVW 预览 / 外部显示层级；音频设备的每条总线选声道与 2 声道设备；远程控制"仅本机 / 允许局域网"与地址行、防火墙询问；Tally；性能与电源 + 仍建议 caffeinate 的场景；更新与诊断；高级）、启动参数表 |
| 故障排查 / troubleshooting | 无信号一节按输入类型列常见原因（格子只写"无信号"）；推流按 连接中 / 重连中 / 起不来 / 鉴权分行；磁盘一节分出备用目录与 ISO 分支用完；磁盘下限去 设置 › 高级；"没有参与录制的路"；防睡眠改成"App 自己拿断言，无人值守合盖 / 锁屏仍跑 caffeinate -u -i -d -s"；开了压缩 / 限幅监听会晚、每路效果未生效、2 声道设备没耳机声道、Bus A / B 选声道；新一节"界面"（界面锁、转场中格子灰、关主窗口 = 退出、手册未随包）；API 节改 设置 › 远程控制 / Tally；日志与诊断加导出诊断包；看日志的命令写全路径 `/usr/bin/log`（§5 第 4 条） |

**改回"已生效 / 属实"的说法**（prompt 要求列出）：

| 说法 | 以前手册怎么写 | 现在 | 依据 |
|---|---|---|---|
| 总线效果链（参量 EQ / 压缩 / 限幅）作用到声音 | "只能编辑、还没有作用到声音" | **已生效**，写明范围：一格最多 16 段（界面 3 段）、每条总线最多 3 格、关掉的格旁路、5–35 ms 延迟录制 / 推流 / NDI® 已补、本机监听会晚；**每路输入的效果链仍未生效**（102） | W5-C §1.6、G6 |
| 录制磁盘下限在设置里能改 | "0.1.0 的偏好设置窗里没有这一项" | 属实：设置 › 高级（下限 + 备用目录） | W5-J（X53） |
| 输入设置的音频一节有"跟随视频（AFV）" | "开关不在这里，在调音台条子上" | 属实：输入设置 › 音频 › 跟随视频（AFV），与调音台同一份 | W5-K（X55） |
| App 能起只读 tally 流 | "App **不起**这个服务" | 属实：设置 › Tally（默认关） | W5-L（X32） |
| App 里兼容层 / API 能听局域网、兼容层 HTTP 端口可改 | "App 0.1.0 里改不了监听地址" | 属实：设置 › 远程控制 | W5-L（X33） |
| App 自己防睡眠 / App Nap | "App 自己还不会阻止睡眠" | 属实（引擎在跑时两条断言，默认开）；合盖 / 锁屏的无人值守长跑仍建议 caffeinate | W5-L（X34） |
| Bus A / B 有设备出口 | "还没有送到设备声道的入口" | 属实（设置 › 音频设备 每条总线选一对声道，要多声道设备）；2 声道设备上耳机总线仍听不到 | W5-K（X08 App 半） |
| 推流地址里的 user:pass@ 鉴权 | （没写） | 属实（Adobe 鉴权）；自建服务器要查询串 | W5-D、W5-I |
| 停止前确认、未保存先问、退出不静默写回、文件格式单选、"重试间隔最长 n s（一直重试）" | "下一版统一成先询问"/"容器 .mp4 不起作用，下一版并成单选"/"重连上限" | 属实，照现状写 | W5-B |
| 虚拟摄像头设备名 | "仍是代码名 Switcher" | "PlusMix" | G5 改名、W4B2 问题单 |

### 1.2 兼容层文档（交付 3）

- `docs/integrations/vmix-compat.md`、`docs/api/vmix-compat.md`、`docs/integrations/companion.md`：App 里的入口改成 设置 › 远程控制（开关、"仅本机 / 允许局域网"、HTTP 端口、页上的地址），删掉"App 改不了监听地址 / 等 prompt 98"的说法；"不做"的理由（X57：External / Fullscreen 映射待定、AudioAuto 有损）UIA 在 09-29 已按实情改过，这次核对仍成立、没再动。
- **覆盖表里 Transition1–4 / SetTransitionEffect 的映射没改**：那是 100 的实现，没合入（§3）。**X51 的 501 口径也没改**：实现没改（31 个名字仍回 400），文档照实保留那句说明，并写了问题单（§3）。

### 1.3 随包 HTML 手册（交付 4）

- **`docs/tools/build-help.py`**（只用标准库）：`docs/user`（中）→ `App/Resources/Help/zh-Hans/`、`docs/user/en` → `Help/en/`，文件名两种语言相同（index / concepts / inputs / outputs / shortcuts / settings / troubleshooting），另有 `Help/index.html`（选语言）、`Help/style.css`（深浅色跟系统）、`Help/img/`（只拷被引用的图）。
  每页顶部导航 + 语言切换（同名页）；标题锚点复用 `check-links.py` 的 `github_slug`，所以 .md 里的 `#锚点` 原样可用；手册内的链接 → .html，手册外的仓库文件写成"链接文字（仓库：路径）"。
  入口页带 `#ndi` / `#decklink` 两个锚点（添加输入面板横幅的"看说明"打开 `index.html#ndi`），有脚本时直接跳到"输入"页对应一节。
  生成后自检：每个相对 href / src / 锚点都要在产物里找得到、产物里不许有 lint 禁词（产物在 App/ 下，`scripts/lint-rules.sh` 会扫）。输出确定（不写时间戳），文档没变重跑没有 diff；`--check` 只比较不写（给 lint / CI 用）。
- **大小与生成时间**（3a60f8a 核对修正之后）：18 个文件，**737.6 KB**（HTML 270.6 KB + CSS 2.4 KB + 两张截图 464.5 KB；磁盘占用 768 KB）；生成 **0.05–0.08 s**（连跑三次 0.08 / 0.05 / 0.05 s，重跑无 diff）。中文 7 页、英文 7 页。
- **project.yml**（用户 2026-10-10 定，本会话一条）：`App/Resources/Help` 写成 folder reference（`type: folder`）。**另外在原来的 `App/Resources` 那一条上加了 `excludes: [Help]`**——只加 folder reference 时 XcodeGen 仍经 `App/Resources` 把 Help 下的文件一个个加进 Copy Bundle Resources（pbxproj 里三条"index.html in Resources"，拷进包时撞名），所以这两处要一起改；共 +4 行，详见 §5 第 2 条。
  `make build-app` 通过，`PlusMix.app/Contents/Resources/Help/` 下有 `zh-Hans/index.html`、`en/index.html`、`img/`、`style.css`、`index.html`。
- **`make help` 的 Makefile 一行（给 G8 挂）**：Makefile 里**已经有一个 `help:` 目标**（打印 make 用法），所以建议用新名字：

```make
manual:   ## 随包 HTML 手册：docs/user（中英）→ App/Resources/Help/
	python3 docs/tools/build-help.py
```

  并在 `.PHONY` 里加 `manual`、`help:` 的用法里加一行 `make manual`。一定要叫 `make help` 的话就把现在的用法目标改名（例如 `make usage`）。
  另建议挂一个检查（补充规则 4，名字以 check- 开头会被 make lint 自动带上）：`scripts/check-help.sh` 一行 `exec python3 "$(dirname "$0")/../docs/tools/build-help.py" --check`——改了 docs/user 忘了重生成，lint 就红。scripts/ 与 Makefile 不在本会话目录，没加。

### 1.4 其他

- `docs/api/README.md`：App 入口改成 设置 › 远程控制；applied = false 加"转场进行中的 setPreview / setProgram"；新 §6"几条命令的现行口径"（转场中拒收、setBusEffects 已生效的分组 / 3 格 / q 口径 / 钳位范围 / 延迟补偿、每路效果未生效、起不来报 failed）——`docs/api.md` 是生成物不能手改，问题单给 P5（§3）。`docs/api/examples.md:138` 加转场中拒收与批量 `[setPreview, cut]` 的结果。
- `docs/integrations/tally.md`：谁起 tally 流（App 设置 › Tally / headless `--tally-port`）。
- `Samples/README.md` §4：教会样例推到 `rtmp://127.0.0.1:1935/s1`、密钥空（原来写 live/church，仓库的 mediamtx.yml 只开 s1–s3）。
- `README.md`：状态行（0.1.x 改版、G2–G7、还没有发布版）与用例数（G7：777 / 228）；`docs/testing/README.md` 与 en 版补 G5–G7 三行。
- `docs/release/`（diagnostics / signing / third-party）三处"偏好设置 → 更新"与关于面板的过时说法。`docs/KNOWN_ISSUES.md` 文档那一行改成"86–98 已改完、100 / 101 两节待补"。
- 问题单 5 张：X51 与 docs/api.md 两张见 §3，英文格子截断见 §5 第 7 条，§2.4 核对时查出的 App 行为缺口两张。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

文档会话没有测试 ID；交付 6 的判据逐条如下（全部在本机实跑）。

### 2.1 lint 与链接

| 项 | 结果 | 判据 | 通过 |
|---|---|---|---|
| `make lint BRANCH=w4-docs-2`（44d97a3） | 禁词（含 App/Resources/Help 的产物）/ 版本号 / Package.swift / 依赖方向通过；**check-ownership：55 个改动文件都在允许范围内**（加上本报告 56 个）；check-links：175 个 Markdown 的相对链接与锚点都能解析；check-rt-symbols 通过 | 全绿 | ✅ |
| `python3 docs/tools/build-help.py` 自检 | 产物里每个相对链接 / 图片 / 锚点都解析得到，禁词 0 | 0 处问题 | ✅ |
| `python3 docs/tools/build-help.py --check` | `App/Resources/Help 与 docs/user 一致（18 个文件，737.6 KB）` | 一致 | ✅ |
| 浏览器看产物（内置浏览器，127.0.0.1 起静态服务） | 中英目录页、概念页长表、英文 hotkeys.json 代码块排版正常；`zh-Hans/index.html#ndi` 直接跳到 `inputs.html#ndi-接收`，标题不被顶栏挡住 | 目视 | ✅ |

### 2.2 App 构建与随包

| 项 | 结果 | 通过 |
|---|---|---|
| `make gen` + `make build-app`（本分支的 project.yml） | BUILD SUCCEEDED，0 error | ✅ |
| `ls PlusMix.app/Contents/Resources/Help/` | `en/`（7 页）、`zh-Hans/`（7 页）、`img/`、`index.html`、`style.css`——`zh-Hans/index.html`、`en/index.html` 都在（裁定 ① 的验收） | ✅ |
| pbxproj | 只有一条 `Help in Resources`（folder reference），没有单个的 index.html 资源 | ✅ |
| 与手册 / 资源相关的 App 用例（`make test-app XCB_FLAGS="-only-testing:…"`：ToolbarMenuTests 的帮助菜单、PanelsRevampTests 的添加输入横幅、LocalizationTests、ReleaseTests） | xcresulttool：Passed，15 条 15 过、0 败、0 跳。全量没跑：本会话只动了资源与 project.yml，同机别的会话在跑 App 用例（显示类会互相挤红） | ✅ |

### 2.3 文档里的命令能复制执行、样例能打开

| 命令 / 操作（出处） | 结果 | 通过 |
|---|---|---|
| `make gen build-app && open …/PlusMix.app`（README、手册） | 编过（见 2.2）；App 用编出来的二进制直接起（下一行），`open` 那半只核对了路径存在 | ✅ |
| 三个样例 Show 在 App 里打开（交付 6）：`PlusMix --show Samples/<x>/<x>.switcher.json --audio-device null --api-listen 127.0.0.1:8799`，读 `GET /api/v1/state` | church：6 路（4 合成 + 2 图片）全部 30.0 fps；classroom：3 路 29.9 fps、叠加 1 开着；event：6 路 60 fps；三个都 missed_render 0、日志里没有错误行；图片是相对路径，说明 W3-E5 的相对路径解析在 App 里成立 | ✅ |
| 本机推流（输出 › 本机先试、Samples §4）：`mediamtx scripts/mediamtx.yml` + App 打开 church、API `startStream 2` + `ffprobe rtmp://127.0.0.1:1935/s1` | 推上：h264 1920×1080 30 fps + aac；encoder[2] publishing 4.93 Mb/s；状态行提示顺序"推流 2 连接中…"→"推流 2 已开始"（与手册写的一致） | ✅ |
| `swift build -c release --package-path Tools/switcher-headless && … run --show Samples/event/event.switcher.json --duration 30 --audio-device null --stats /tmp/stats.jsonl`（README） | 编过（62 s），跑满 30 s，stats.jsonl 30 行、missed_render 0 | ✅ |
| `python3 Samples/tools/make-shows.py`（Samples §5） | 重生成三个节目文件，`git status` 无变化 | ✅ |
| 手册里的 hotkeys.json / midi.json 样例（中英共 4 段） | 用 `SwitcherControl` 的 `HotkeyTable.load` / `MIDIMapTable.load` 真解（草稿区探针）：4 段全过，10 条里 1 条停用；默认表 31 条、冲突 0、⌥1–⌥4 = autoTransition、⌃1–⌃4 = toggleOverlay，与手册一致 | ✅ |
| `log show --predicate 'process == "PlusMix"' --last 10m --style compact`（故障排查） | **原样跑不通**：非交互的 zsh 里 `log` 是内建命令，报 `too many arguments`（终端里能用只因 /etc/zshrc 有 `disable log`）→ 改成 `/usr/bin/log show …`，实跑有输出 | ✅（改后） |
| `python3 docs/tools/build-help.py`（本会话新加） | 见 2.1 | ✅ |

跑 App 之前 `defaults export com.plusmix.switcher` 存了用户的本机设置，跑完 `defaults import` 导回、逐项比对一致；`~/Library/Application Support/PlusMix/LastSession.switcher.json` 逐字节没变（App 用 kill 结束，不走退出那条写 LastSession 的路）。

### 2.4 事后核对（手册逐句对代码）

写完后开了两个核对 agent，对着 main 93f50d9 的**代码**与两份 Localizable.strings 逐句查中英各页（不看各会话报告的说法）；每一条我再对代码复核一遍才改。结论：**第一轮 23 处、第二轮 22 处（17 处不符 + 5 处漏写），加上写的过程中自己查出的 6 处，都是照报告 / 问题单写、与最终代码不符的**，全部按代码改了（3a60f8a，前面零散的几处在 578eb0b、e5a141b），实现本身该改的记成问题单。

| 轮次 / 页 | 查出并改正的（要点） |
|---|---|
| 写的过程中 | 组合动作"前一条被拒"其实只有抛出的拒绝会停（578eb0b）；鉴权失败的原因只在系统日志；API README 的 `audio.effects` → `settings.effects`；英文页引的提示与 en.lproj 逐字对齐；README / 测试索引的锚点 #8 → #9；`log` → `/usr/bin/log`（e5a141b） |
| 第一轮：概念 / 设置 / 快捷键 | 大缩略图档最小窗口会变高；"推流状态…"打开推流页；停止确认框列出要停的路；"隐藏 PlusMix / 退出 PlusMix"；编辑菜单一行（节目没有撤销）；输出菜单开关项的几种标题；Wipe 柔边界面 0–0.3、API 收 0–1；`mixer.ftb.durationTicks`；调音台条子与输入设置的范围不同；节目文件的字段在 `mixer` 下；**LastSession 只在正常退出时写、启动开的是上次打开 / 保存的文件**；底栏录制 / 外部显示的 ⚙ 是菜单；节目格式 / 节目音频没应用就丢；**只改声道对不算待应用**；导出 / 恢复默认不含的键；**常规 / 音频设备 / 远程控制 / 高级 页一改就把启动参数存成本机设置**；⌃n 不换输入（通道空着开了没画面）；"n 处冲突"；选动作面板的输入写法；MIDI 默认表是空的、读不出静默退空表 |
| 第二轮：输入 / 输出 / 故障排查 | **无信号的格子只写"无信号"**（各输入的 lastError 界面不读，原来引的"设备已断开…""网络上找不到 NDI 源…"看不到）；SDK 没编进来是 error、横幅里只有"DeckLink 驱动没装"会自愈；**图片后来放到位会自己换上、视频文件不会**；只改"播完"不重建；缩略图统一高度；输入设置窗 tally 在标题行、来源能换类型；搜索框 Esc 清筛选；**推流开关开着就锁（连接中 / 重连中也锁），改鉴权先关**；"● 推流中"只在只有一个目的地时；视频号 / 抖音 / 快手重开显示成自定义；鉴权小表"清除"只清框、"保存"才生效；**外部显示窗口 Esc 与"关闭这路"都是删掉这一路**；多画面输出没有开关、只承载布局；新加的 NDI® 发送一建就开；推流 API state 在 connecting / backoff 之间来回；低于下限有备用目录时切过去（提示仍写"磁盘满"）；ISO 分支用完的真实提示；新节目 AFV 总开关默认关；对齐延迟 / 监听点要"应用并重起引擎"；诊断文件夹是崩溃 / 卡死记录不是导出的包；只有引擎的提示进系统日志；手册缺失多半是工程旧了（`make gen`）；英文页里只有中文的引擎文案改成"中文原文 + 英文注" |

核对出的实现缺口（文档只能照实写、附绕法）：`reports/issues/W4C2-w5-app-settings-gaps-found-by-docs.md`（6 条，S2 一条：启动参数被存成本机设置）、`reports/issues/W4C2-w5-app-inputs-outputs-gaps-found-by-docs.md`（4 条，S2 一条：外部显示 Esc / "关闭这路"直接删输出）。
README / en/README 两页短，没有交给 agent 逐句查（我自己对过）；docs/ 下手册以外的文档只做了 §1.2 / §1.4 的定点修改，没有逐句核对。
修正之后重跑：build-help.py 自检与 `--check`、check-links（175）、`make lint` 全绿（§2.1）。

## 3. 没做的和原因

1. **转场槽与 T-bar 横放（100）、文件播放控制与推流状态面板 / 时长（101）、鉴权"写法"二选一（101）**：没合入 main，按裁定 ④ 等合入后 rebase 一次再补。在那之前手册按现状写：转场列是五个类型按钮（点了就做）+"Fade ▾"（只选），"切换"菜单的五种类型只选不执行，⌥1–⌥4 = 执行当前转场，"推流状态…"打开推流页，鉴权只有 Adobe 那一种、查询串自己写进地址。
   补的时候要改：概念 / concepts 的转场列与"切换"菜单（裁定 ② 第 1 条：转场项点了就做、槽 ▾ 里"用于 T-bar"才是只选）、FTB 右键时长、快捷键表 ⌥n = 转场 n、兼容层覆盖表 Transition1–4 / SetTransitionEffect1–4、输入 / 输出的播放控制与状态面板、推流鉴权一节、快捷键 / shortcuts 开头"设置窗在前时这一版不转发按键"（X12 残口归 100，修了就删这句）、**两张主窗口截图重拍**（转场列和 T-bar 的样子会变）。
2. **每路输入的效果链（102）**：没合入，手册照写"尚未作用到声音"。
3. **X51（31 个函数名回 400）**：实现没改，也没有哪个 prompt 认领；文档照实，问题单 `reports/issues/W4C2-w5-transition-slots-compat-x51-still-400.md`（建议 100 顺手）。
4. **`docs/api.md` 的 setBusEffects / setPreview / setProgram 说明**：生成物、有测试钉着，要改 `CommandCatalog`（P5 目录）；口径先写在 `docs/api/README.md` §6，问题单 `reports/issues/W4C2-p5-docs-api-setbuseffects-and-transition-guard-text.md`。
5. **截图只拍了主窗口**（中英各一张）。docs/user 原来没有截图，prompt 的"重拍"不适用；设置窗等其他截图没加——100 合入后主窗口还要重拍，先不铺开。
6. **Makefile 的 `make manual`（或 `make help`）与 `scripts/check-help.sh`**：不在本会话目录，给 G8 的写法在 §1.3。
7. 规格（docs/spec）、计划（docs/plan）按 prompt 不动；`CHANGELOG.md` 归 G5 类会话，没动。
8. **检查点清单 `docs/checklists/G4.md`（:15、:20、:60）、`G7.md`（:57、:59）**的验收项写着"格子显示 没有找到 DeckLink 驱动… / 网络上找不到 NDI 源…"和"Esc 关闭"，与实现不符（§2.4）。那是检查点的记录，本会话没改；G8 若照抄 G7 的清单要先看 `W4C2-w5-app-inputs-outputs-gaps-found-by-docs.md`。

## 4. 对契约的疑问

没有改契约，也没有要停下来的提案。几点给后面参考：
1. 提案 025（W5-I 的三个 `extra` 标记升正式字段，已批）落地后，"参与录制""与推流 1 相同"在界面上不变，手册不用改；API / headless 也认"参与录制"之后，手册里"底栏只起参与的路"那句可以扩成"全部录制都只起参与的路"——P5 / 101 合入后补时核对。
2. 提案 027（新节目叠加默认淡入 0.5 s 进契约默认值，已批）落地后，概念 / concepts"只是 App 新建节目时的默认值；API / 无界面引擎建的节目默认切入"那句要删。
3. CONTRACTS.md §2.4 没写 `parametricEQ.q` 是经典 Q、每条总线最多 3 格（W5-C §4 第 1、2 条，已在提案 024"顺带"里）；API README §6 先按实现写了。

## 5. 下一个会话需要知道的坑

1. **改了 docs/user 一定要重跑 `python3 docs/tools/build-help.py`**，否则包里的手册是旧的；`--check` 能查出来（建议挂进 lint，§1.3）。docs/user 里**加新页**要在脚本的 `LANGS[...]["files"]` 与 `PAGES`、`nav` 里登记，不登记生成时直接报错（不悄悄漏页）。
2. **project.yml 的 folder reference 要和 `App/Resources` 那一条的 `excludes: [Help]` 一起**：只加 folder reference，XcodeGen 会把 Help 下的文件再按单个资源加一遍（pbxproj 里三条"index.html in Resources"），拷进包时目录层级没了、撞名。用户的裁定写的是"只加 folder reference 一条"，这多出来的 `excludes` 两行是它能用的必要条件，请检查点复核。
3. **产物在 App/ 下，lint 的禁词会扫到**：docs/user 里不能按文件名链到兼容层文档（路径里有对方的名字），链 docs/api/README.md；脚本自检会先报。
4. **`log show` 在脚本 / 非交互 zsh 里跑不通**（`log` 是 zsh 内建命令；终端里能用只因 /etc/zshrc 有 `disable log`）：文档里写 `/usr/bin/log`。
5. **跑 App 截图 / 验证不碰用户的状态**：测试宿主模式（`XCTestConfigurationFilePath`）会把界面语言钉成中文，截英文图用不了；本会话的做法：`defaults export com.plusmix.switcher 备份.plist` → 直接执行 `PlusMix.app/Contents/MacOS/PlusMix --show <节目> --audio-device null --api-listen 127.0.0.1:8799 -AppleLanguages "(en)" -ApplePersistenceIgnoreState YES` → 用 CGWindowList 找窗口号（草稿区 20 行 Swift）→ `screencapture -x -o -l<窗口号>` → `kill` 结束（不走退出、不写 LastSession）→ `defaults import` 导回。
   窗口尺寸靠节目文件 `layout.mainWindowFrame = "{{120, 60}, {1440, 900}}"` 钉住；Retina 上截出来是 2×，`sips -Z 1440` 缩回 1×；合成源的噪声底纹让 PNG 一张 540 KB，存 JPEG q90（约 240 KB，字照样清楚）。从 shell 起的 App 不在前台，工具条按钮是"非活动窗口"的暗色——没去抢前台（会打扰用户和别的会话的界面用例）。
6. **MediaMTX 在仓库根目录起会写 `mediamtx-recordings/`**（配置里 `record: yes`），根目录 .gitignore 没有它；本会话在草稿区起的。手册照实写了这一句；要不要进 .gitignore 归检查点。
7. **英文界面格子上的"Transition"被截成"Transiti…"**（中档缩略图）：问题单 `reports/issues/W4C2-w5-app-cell-buttons-truncated-in-english.md`。
8. **写手册要对代码，不能只照各会话的报告 / 问题单**：§2.4 两轮核对查出的 45 处，大半是报告里的说法与最终代码不一致（例如无信号的原因、锁的范围、Esc 的行为）。补 100 / 101 那两节时照样开核对 agent 逐句对代码。
9. **引擎 / 输入包的文案只有中文**（格子上的 error 原因、推流日志、Stream Deck 插件的"未连接"）：英文手册引用时写"中文原文（英文注）"，别写成看着像界面原文的英文；App 自己的文案以 en.lproj 为准逐字引。
10. 100 / 101 合入后 rebase 本分支再补那两节时：`build-help.py` 重跑、两张截图重拍（同 §5 第 5 条的办法，节目用活动示例），`make lint BRANCH=w4-docs-2` 前记得 `git branch -f w4-docs-2 HEAD`。
