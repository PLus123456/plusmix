# W4-C 文档与样例 —— 报告（分支 w4-docs）

日期 2026-09-27。机器 Apple M5 Max 128 GB / macOS 27.0 / Xcode 27.0 (27A266a, Swift 6.4) / Python 3.14 / mediamtx 1.21 / ffmpeg 9.0.1，电源适配器。
worktree `.claude/worktrees/w4-docs-27c0ce`，分支 **`w4-docs`**（桌面端起的 `claude/w4-docs-27c0ce` 已改名，`check-ownership.sh` 按 OWNERSHIP 表的行查它），从 `main`（da44bec，G4 第四轮裁定落地后）开。
提交：`git log main..w4-docs`（5 个）。只动了 `docs/`（spec/ 与 plan/ 没碰）、`Samples/`、`README.md`、本报告、一张问题单；没有代码改动。`make lint` 全绿（归属 33 个改动文件都在范围内）。

## 1. 做了什么

| prompt 交付 | 落点 | 说明 |
|---|---|---|
| 1 docs/user | `docs/user/{README, 概念, 输入, 输出, 快捷键, 故障排查}.md` + `docs/user/en/{README, concepts, inputs, outputs, shortcuts, troubleshooting}.md` | 中文为主、英文完整版。用词按设计方案 §1.1；输入状态按 W3-A 的 live / noSignal / error 口径，文案照抄包里与 Localizable.strings 里的原句；已知设备表从 W2-A / W2-A2 / W3-A / W3-C2 / W3-E3 报告汇总，DeckLink / UVC 卡明写"未验证"；虚拟摄像头一节写"送 PGM"（用户 2026-09-27 裁定）；NDI 发送写清源名 = "机器名 (输出名)"、分组、SDK 不在 = `unavailable`、SDK 在但起不来 = `failed` |
| 2 docs/api | `docs/api/README.md`（端点 / 鉴权 / 时间戳 / WS 事件 / stats 字段表 / 错误）、`docs/api/examples.md`（curl、Python、Companion）、`docs/api/examples/switcher_client.py`、`docs/api/vmix-compat.md` | stats 字段表按 CONTRACTS.md §2.7（019 落地后的形态）。**命令参考没有复制一份**：`docs/api.md` 由 `switcher-apidoc` 生成且 `CommandCatalogTests` 钉着它与代码一致，本会话核对过生成器输出与它逐字节相同，docs/api/README.md 链接过去（见 §3 第 1 条）。Python 客户端只用标准库（HTTP + 最小 RFC 6455 实现）。Companion 走原生 API 用它自带的 Generic HTTP / Generic WebSocket 模块，不用等专门模块；兼容层页法律提示在最前，覆盖表按 Companion 动作分，函数级映射表留在 W3-D 的 docs/integrations/vmix-compat.md，不重复 |
| 3 Samples | `Samples/{church,classroom,event}/*.switcher.json` + `assets/*.png`，`Samples/tools/make-shows.py`、`make-assets.swift`，`Samples/README.md` | 教会 1080p30：3 机位 + 调音台（不跟随视频）+ 歌词 / 台标图片叠加 + 录制 + 推流（本机 MediaMTX 的 s1）；教室 1080p30：屏幕 + 老师画中画（白边、打开就在）+ 课程标题 + 录制；活动 1080p60：4 机位 + 调音台 + 标题 + PGM 录制 + 4 路 ISO + 多画面（安全框 + 电平表）+ 关着的 NDI。画面全部合成源、素材相对路径，脚本生成（Show 的合成 Codable 缺键就打不开，样板集中比手写稳） |
| 4 docs/testing | `docs/testing/测试标准.md`（公开版）、`README.md`（G2–G5 索引 + 自己跑 + 基线 + 报问题）、`设备兼容性.md`（模板 + 开发机实测）、`en/README.md` | 公开版阈值与 docs/spec 内部版逐条相同（一个没动），去掉会话引用，把 2026-09-19 / 20 / 22 的口径修订并进正文；stats 字段挪成 §7.1 便于引用 |
| 5 README | `README.md` 重写 | 状态、一分钟上手（App 与 headless 各一条能复制的命令）、文档地图、构建 / 测试、目录、贡献（Apache-2.0、DCO 签字、契约提案流程、禁词、设备结果） |
| 6 品牌 | 全部文档 | 对方名字只出现在 `docs/api/vmix-compat.md`（带法律提示）与 W3-D 原有的 docs/integrations 两页；其余文档用"第三方 API 兼容层"；README 里只有模块名 `VMixCompat`（铁律 6 的唯一例外） |
| 7 三条口径 | 输出页、docs/api | 虚拟摄像头"送 PGM"；NDI 三条；stats 表以 CONTRACTS §2.7 为准 |
| 检查工具 | `docs/tools/check-links.py` | 查 docs/ Samples/ README.md 的相对链接与锚点（GitHub 的中文锚点规则）、样例节目文件合法性（JSON、schemaVersion、4 个叠加、4 条总线、图片相对路径存在）。放 docs/tools/ 是归属限制（scripts/ 不归本会话），挂进 make lint 只需 scripts/ 下一个 check-*.sh 调它 |
| 问题单 | `reports/issues/W4C-app-relative-media-paths.md` | App 把图片 / 文件输入的相对路径按进程工作目录解析（headless 相对节目文件），从菜单打开样例时字幕 / 台标两路变占位；约 10 行 App 改动，建议 W3-E4 顺手或 G5 走 App 胶水额度 |

## 2. 检查项：数值 / 阈值 / 通过否

本会话没有测试标准里的指标 ID；prompt 的三条检查逐条如下。

| 检查 | 怎么验的 | 结果 | 通过 |
|---|---|---|---|
| 每个文档里的命令能复制执行 | 逐条对着本机跑：`make gen build-app`；headless 跑三个样例各 3 s（`--audio-device null --stats`）；`docs/api/examples.md` 里 curl 的 state / tally / command / 批量 / commands / log 六条，`switcher_client.py` 的 state / preview / cut / cmd / watch 五个子命令（对着 headless `--api`）；`mediamtx scripts/mediamtx.yml` + App 起推流；`python3 docs/tools/check-links.py`；`Samples/tools/make-shows.py`、`swift Samples/tools/make-assets.swift`；`log show` 一条 | 全部按文档原文执行成功。要硬件 / SDK / 签名 / 第三方软件的没跑（DeckLink、虚拟摄像头激活、真 Companion 界面步骤、Stream Deck），文档里这些步骤照 W3-A / W3-C / W3-D 报告与清单写 | ✅（能跑的部分） |
| 样例 Show 在 App 里打开无错误 | headless：三个文件 `run --duration 3` 各跑满 90 / 90（1080p30）与 180 / 180（1080p60）拍，missed_render 0，图片路 pushed 90 / 91；App：`Switcher --show <样例> --audio-device null --api-listen 127.0.0.1:8799`，`GET /api/v1/state` 读回输入表 / 输出表 / PGM PVW 与文件一致，stats tick 在走、missed_render 0、每路 fps ≈ 30 / 60（含两路图片）；教会样例再 `POST startStream` → MediaMTX `s1` ready、10 s 收 5.8 MB，encoder state publishing 4.27 Mb/s，`stopStream` 后正常 | 从样例目录启动全部无错。**从别的工作目录（含 Finder 起的 App 菜单打开）图片输入 fps = 0、格子显示"图片不存在：assets/lyrics.png"**，其余照跑——App 的相对路径解析问题，问题单见 §1；Samples/README.md 写了临时办法 | ✅ / ⚠️（图片路等 App 修） |
| 链接检查脚本绿 | `python3 docs/tools/check-links.py` | 97 个 Markdown（docs/ 全部含 plan / spec / integrations、Samples/、README.md）相对链接与锚点全部可解析；三个样例节目文件合法 | ✅ |
| `make lint` | lint-rules / check-deps / check-ownership w4-docs / check-rt-symbols | 全绿，归属 33 个改动文件都在允许范围内 | ✅ |
| docs/api.md 是否过期 | `swift run switcher-apidoc` 输出与 docs/api.md diff | 逐字节相同 | ✅ |

## 3. 没做的和原因

1. **docs/api/ 里没有再放一份"从 Command 枚举生成的命令参考"文件**：它已经存在（`docs/api.md`，W2-C 的生成物，有测试钉住），再复制到 docs/api/commands.md 就是两份没人钉的生成物；docs/api/README.md 第一张表就链接它并写明生成命令。要挪进 docs/api/ 的话要同时改 `CommandCatalogTests` 的路径、生成器注释、OWNERSHIP 的 W2-C / P4 行和十几处报告引用——超出本会话目录，留给检查点决定。
2. **英文版只做了 docs/user 全套 + docs/testing 概览**（prompt 只对 docs/user 要求双语）；docs/api、Samples、测试标准全文是中文，英文页链接到中文时都标了 "(Chinese)"。
3. **没有写原生 API 的 Companion 模块**（W3-D 的 companion.md §2 本来就定为"只写文档"）；示例给的是用 Companion 自带 Generic HTTP / WebSocket 模块的配法，能立刻用。
4. **设备兼容性表只有开发机上的实测行**：内置摄像头、连续互通相机、四个音频设备、NDI 回环、内置屏 + LG 外接屏、MediaMTX；DeckLink、UVC 采集卡没有硬件，表里明写未验证。
5. **check-links 没挂进 make lint**：scripts/ 不归本会话（OWNERSHIP 补充规则 4 要求放 scripts/ 才自动挂）。检查点加一个 `scripts/check-links.sh`（`exec python3 docs/tools/check-links.py "$@"`）即可。
6. **App 的相对路径问题没修**（App/ 不归本会话）：问题单里写了改法与用例；修好后删 Samples/README.md 的"App 修好前的临时办法"一段。
7. 需要硬件 / SDK / 签名 / 第三方软件的文档步骤没有实际执行（DeckLink 添加、虚拟摄像头激活与 FaceTime 可见、真 Companion / Stream Deck 的界面步骤、RTMPS 推流）；写法以各会话报告与 docs/checklists 为准。
8. 素材图只做了三张（歌词、台标、两张课程 / 活动标题），没做 Stinger 动画素材（W3-B 报告 §3 第 2 条：动画 stinger 要"转场开始时从头播"，引擎未做）。

## 4. 对契约的疑问

没有需要改契约的地方。三条备忘：

1. `Stats.EncoderEntry.output` 在 App 里目前是 0（填法归 W3-E4，G4-notes §13.6）：文档按契约写"0 = 填数方没给"，并在 API 文档提醒读的一方按 `output` 对号；W3-E4 落地后文档不用改。
2. `InputSource.file / .image` 的 `path` 相对路径口径契约注释没写（headless 相对节目文件、App 相对进程 cwd）。建议在 Input.swift 的文档注释里补一句"相对路径相对节目文件所在目录"——只改注释不改 JSON，不需要提案；与问题单一起处理最顺手。
3. NDI 发送的分组 / 转换方式走 `OutputSettings.extra["ndi.groups"]` / `["ndi.conversion"]`（App 级约定，不在契约里）；用户手册按 App 的现状写，若将来正式化成字段，输出页那两行要跟着改。

## 5. 下一个会话需要知道的坑

1. **分支名**：桌面端 worktree 起的是 `claude/w4-docs-27c0ce`，`check-ownership.sh` 按 OWNERSHIP 表精确匹配分支名，不改名 `make lint` 直接红——本会话 `git branch -m w4-docs`。合并时用 `w4-docs`。
2. **验证 App 打开节目不用点界面**：`Switcher.app/Contents/MacOS/Switcher --show <文件> --audio-device null --api-listen 127.0.0.1:8799 --stats <jsonl>` 从 Bash 起，再 `GET /api/v1/state` 读输入表 / stats（每路 fps、missed_render），`POST /api/v1/command` 起停推流录制；从 Bash 起的进程没有摄像头 / 屏幕 TCC，样例只用合成源与图片所以不受影响。App 的 cwd 决定相对路径怎么解析（问题单）。
3. **MediaMTX 只收配置里声明的路径**：仓库的 `scripts/mediamtx.yml` 只有 s1 / s2 / s3 / srt1，brew 装的默认配置同样拒绝未声明路径（`path 'live/church' is not configured`），所以教会样例的推流地址是 `rtmp://127.0.0.1:1935/s1`、密钥留空（与 G3 清单一致）；换平台才填密钥。
4. headless 只接合成源 / 图片 / NDI / 纯音频设备（`HeadlessRun.swift` 的 `default: throw`），摄像头 / 屏幕 / 文件输入的节目只能在 App 里验；样例因此全用合成源代替摄像头与屏幕，README 写了换法。
5. 1080p30 的节目格式在引擎 / App 里都正常（教会、教室样例），转场与叠加动画的拍数要按 30 fps 换算（15 拍 = 0.5 s）。
6. `swift Samples/tools/make-assets.swift` 是脚本模式，第一次编译约 15 s；文字用 PingFang SC，没有该字体的机器退到系统字体。PNG 用 ImageIO 写，重跑字节可能不同，diff 时看图不看字节。
7. check-links 的锚点算法：小写、去标点、空格换 `-`、中文保留（GitHub 规则）；标题里带括号 / 点号时锚点里没有它们（`7.1 统计字段 stats.jsonl` → `#71-统计字段-statsjsonl`）。它扫 docs/ 全部（含 plan / spec / integrations），别的会话写坏链接也会被它抓到——现状 97 个文件全绿。
8. `switcher_client.py watch` 打印的"收到 − 拍点"常是负几毫秒：命令在下一拍生效、快照早于那一拍到达，这是 C2 口径的正常现象（判 ≤ 50 ms）；文档里写明了，别当 bug。
9. `docs/api.md` 本会话核对过与生成器一致；以后契约加命令时按 `swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md` 重生成，`CommandCatalogTests` 会红提醒。
10. 图片 / 叠加素材的位置：字幕条 0.78–0.95 倍高、台标 0.08–0.16 倍高，避开合成源顶部的帧号 / 时间戳 / ID 块、右上闪光块和中心采样区（测试标准 §2.1 的保护带口径）；换真摄像头就没有这个顾虑。
