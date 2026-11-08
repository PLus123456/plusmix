# W4-C5 手册续做四：129–139 改了的行为进手册 / 集成文档 / API README —— 报告（分支 w4-docs-5）

日期 2026-11-07。prompt 135（G12 写的；G13 §7.1 第 6 条改口：从 G13 快进后的 main 开、一次写全 129–139）。
机器 Apple M5 Max / macOS 27（Darwin 27.0.0）/ Swift 6.4（swift 探针用）。
worktree `.claude/worktrees/w4-docs-5-8a63f5`，harness 分支 `claude/w4-docs-5-8a63f5`，从 main **1886bde**（= g13 头）开；**别名 `w4-docs-5` 指同一个头**
（`git branch -f w4-docs-5 HEAD`；`make lint BRANCH=w4-docs-5` 与 G14 合并都用它）。
136–139 已在 main 里，所以**没有"依赖未合入分支的句子"、没有单独的依赖提交**；随包手册产物最后统一 `make manual`、一个提交。
动的文件全在 W4-C5 的范围里：docs/api/、docs/integrations/、docs/user/（中英）、docs/testing/ 两个 README、docs/release/README.md 一行、README.md、
App/Resources/Help/（产物）、reports/issues/ 五张新单、本报告。代码、契约、docs/spec、docs/plan、docs/KNOWN_ISSUES.md、docs/CONTRACTS.md、docs/api.md（生成物）、
docs/checklists、docs/release 的签名 / 公证内容一个字没动。

## 1. 做了什么

提交（`git log main..w4-docs-5`，按主题小步；核对修正放在主题提交之后、产物之前）：

| 提交 | 内容 |
|---|---|
| 1af81f0 | **docs/api/README.md**：§1 浏览器来源拦截（131）、推流凭据打码与写回规则（137）、局域网明文；§3 两行加打码说明、错误表加 403 两种；§4 WS 同样过来源检查与打码；§6 加 034 数值边界、运行中 loadShow 不换格式、overlay input 0 清空与改时长重锚；起不来那一路 last_error 只写原因；推流 last_error 换成中文概括（132 / 138）；文件暂停没落实就继续 = 取消（133） |
| 080be3b | **集成文档**：兼容层 HTTP 的浏览器来源 403、TCP 一行 64 KiB / 64 条连接 / 没有空闲超时（131）、`allowedOrigins` 字段；Stream Deck 排错两条（host:port 日志、丢弃坏快照）；tally 流不查来源 |
| ddb11e3 | **设置页（中英）**：远程控制三条黄字的条件与原文（130 明文提醒）、API 打码与浏览器来源口径、"只开本机 + token"建议照旧；高级 › 磁盘下限最大 16777216（16 TiB）；`--record-min-free-mb` 同钳 |
| 3abf0d9 | **输出页（中英）**：ISO 纯音频行"纯音频：画面为黑"、ISO 删输入的封口句、磁盘保护表（录制器出错不切、封口句、ISO 画面分支满了不切备用目录、备用目录起不来）、地址框露路径末段（已知问题）、推流页"起不来"只写一遍、鉴权停下"失败：鉴权失败（…）"、▴ 每项悬停（原因 / 打码地址 / 点了做什么）、状态窗"起不来 / 失败"分字与事件格式、最后错误改成中文概括、NDI 失败时发送页"失败：原因"与状态行 60 s 一次的提示 |
| 1bfae74 | **概念 / 快捷键 / 输入页（中英）**：统计窗效果链延迟表（139）、Stinger 菜单标题（130，中文）、叠加"（无）"真的清空与改时长重锚、时长框上限（129）、选动作面板"（清空）"与秒数上限（139）、方向矩阵提示上界面（130）、暂停没落实就继续（133） |
| 320cb91 | **故障排查（中英）**：磁盘四行、推流六行（连接超时（服务器没回）、连接被拒 / 找不到主机、发布被拒、AMF0、起不来、没有地址）、NDI 一行、越界节目打不开（枚举原样）、API 六行（400 / 403 两种 / `<redacted>` / 打码标记 400 / 兼容层 TCP 上限）、诊断包打码；新 **§10 已知问题**（三条，138 / 139 修掉的三条不列）；手册目录说明加"已知问题" |
| 5eba8c6 | README 状态段改成 G13 口径；docs/testing 两个 README 补 G11–G13 三行与两处数字；docs/release/README.md 第 19 行 R11–R14 → R11–R15（prompt 第 8 条） |
| 9c910d2 | 问题单两张（兼容层 TCP 跨协议、打开越界节目的提示是枚举原样） |
| aa2642f | docs/api/examples.md：Companion 按钮表加"叠加关掉并清空输入"（input 0） |
| f5ef759 | 核对修正一（一路、三路查出的 28 处，见 §2.2；提交说明里写成了 27，按条数是一路 13 + 三路 15）+ 问题单"套壳吞解码错误"，兼容层 TCP 那张补 fetch no-cors 写法 |
| 6fc5843 | 核对修正二（二路查出的 12 处）+ 问题单"录制失败几条路最后是封口失败：notRecording"、小文案三条合一张 |
| 4ead438 | `make manual` 重生成 App/Resources/Help/（中英 7 + 7 页 + 2 张图，879.0 KB） |
| （本提交） | 本报告 |

## 2. 每条交付对应核对了哪处代码

文档会话没有测试 ID；这里按 prompt 135 的交付逐条写"写进了哪、对过哪处代码"，§2.2 是核对 agent 的结果，§2.3 是工具检查。
代码都是 main 1886bde 上的（本分支没动代码）。

### 2.1 交付 → 文档位置 → 对过的代码

| 交付 | 写进了哪（中英同改的只写中文名） | 对过的代码 / 资料 |
|---|---|---|
| 1 来源拦截与 allowedOrigins（131） | api/README §1 / §3 / §4、api/vmix-compat、integrations/vmix-compat §1 §2 §8、stream-deck、tally、设置 › 远程控制、故障排查 §8 | `BrowserRequestGuard.swift`（规则、规范化、Host 判定）、`APIServer.swift:52–70`（先来源后 token、WS 400）、`CompatHTTPServer.swift:33`、`APIServerConfiguration` / `VMixCompatConfiguration`（默认空）、`HeadlessCLI.swift`（没有参数）、hummingbird-websocket 升级失败一律 400 |
| 2 兼容层上限（131） | integrations/vmix-compat §3、api/vmix-compat、故障排查 §8 | `CompatTCPServer.swift:12–18 / 57–58 / 115–147`（64 KiB 不含 \r\n、半行、warning、64 条、notice 级拒连）、`VMixCompatConfiguration.logLevel = .warning`、swift-log 默认 stderr；Stream Deck `api-client.js:136`、`plugin.js:72–74` |
| 3 叠加 0 / 数值范围（129，034） | api/README §3 §6、api/examples、概念 › 叠加通道、快捷键 › 选动作面板、故障排查 §7 §8 | `CommandValidator.swift:95–136`（文案原文）、`MixerReducer.swift:210–226`（input 0 / null / on）、`CompositorPasses`（没有输入不画）、`OverlaySettingsPanel.swift:88–128`、`CommandEnvelope`（帧率解码错误与套壳吞错误）、`AppController.presentError` + `ShowDocuments.load`（打开失败走枚举原样；swift 探针确认 DecodingError / 枚举的实际文字） |
| 4 纯音频 ISO / 磁盘下限 / 明文提醒 / 输出页口径（130） | 输出 › ISO / 磁盘保护 / 推流 / 状态窗 / NDI、设置 › 远程控制 / 高级 / 启动参数、概念（Stinger 标题）、输入（方向提示）、故障排查 §3 §4 §5 | `OutputPagesModel.swift:156–198`、`OutputRuntime.swift`（`stopForInputRemoved` / `stopForDisk` / `switchToFallback` / `finishRecording` / `handleDisk` / `recordFailure` / `routeFailure` / `noteStats` / `NDIFailingNotices`）、`SwitcherSession.handle(outputEvent:)`、`OutputSettingsPanel.streamStatus`、`OutputStatusPanel.swift:71–183`、`OutputButtonSummary.routeState`、`OutputStatusText.swift:63`、`AppSettings.clampMinimumFreeMB`、`PreferencesPanel.swift:200–214`、`InputRuntime.liveNote`、`InputSettingsPanel.sourceNote`、两份 Localizable.strings 逐 key |
| 5 推流 last_error 中文（132） | api/README §6、输出 › 状态窗最后错误、故障排查 §4 §9 | `TransportErrorText.swift`（每句原文）、`StreamTransport.swift:62–72`、`StreamOutput.swift:410–480`（失败路径、建传输层失败照常重试）、`HaishinKitTransport.swift:150–216`（Adobe 只自己解析前两轮、publish 超时后等状态流）、HaishinKit `RTMPStream.status` 从不 finish、`RTMPAdobeAuth.swift:33`、`ShowRedaction.swift`（诊断包末段 / `pa%73s`） |
| 6 035 打码（136 / 137，已全部落地） | api/README §1 §3 §4、设置 › 远程控制、故障排查 §8 | `StreamCredentialRedaction.swift`（三处、写回五条规则、400 原文）、`APIServer.swift:110–160 / 285–300`（`?secrets=1` 只认 1、没 token 任何路由 403）、契约 `StreamURLRedaction.swift:9–22`（名单、路径 ≥ 2 段才遮发布名）、`APIDocument.swift:19–20` |
| 7 已知问题（138 / 139 修的三条不列） | 故障排查 §10、输出 › 地址 | KNOWN_ISSUES 产品缺陷表第 43 / 44 / 51 行（还开着）与 G13 已修表；`HaishinKitTransport.swift:158–185`；`OutputPagesViews` / `StreamAddress.masked` |
| 8 docs/release/README.md R15 | 第 19 行 | `scripts/release/tests/test-r15-sign-propagates-failure.sh`、`run.sh` 按文件名全跑 |
| 138 推流对端不说话 | api/README §6、输出 › 最后错误、故障排查 §4 | `StreamOutput.swift:26–29 / 449–480 / 706–724`（`withTimeout` 到点关传输层、抛 connectTimedOut）、`ReconnectPolicy.delay`、`connectTimeoutSeconds` 默认 5 且 App / headless 都不传 |
| 139 App 收口三 | 概念 › 统计窗、输出 › ▴ / NDI、快捷键 › 选动作面板、故障排查 §5 | `StatsWindow.swift:71–161 / 351–360`、`BottomBarView.swift:478–505`、`ShowRedaction.keyIsInPath`、`ActionCatalog.swift:325–358`、`ActionPicker.swift:101–102 / 210`、`OutputRuntime.noteStats` + `NDIFailingNotices`；"NDI 换源后没声音要关开"一类绕法手册里本来就没有（grep 过） |
| 133 暂停口径 | api/README §6、输入 › 播放 | `FileInput.swift:396–419`（pause / resume / pauseApplied）、`InputCellView.playPressed`（按快照的 paused 发）、`InputRuntime` 轮询转发 |
| 顺手 | README 状态段、docs/testing 两个 README 的 G11–G13 | reports/G11.md / G12.md / G13.md 的 §5 / §7 |

### 2.2 核对 agent（照 W4-C3 / W4-C4 的做法，三路只读、并行）

| 路 | 范围 | 报的 | 我复核后改的 | 没改的 |
|---|---|---|---|---|
| 一 | api/README、集成文档、设置页 | 11 条 + 顺带 2 条（WS 握手 token 错是 400；兼容层 TCP 跨协议） | 全改：publish 超时那句走不到（HaishinKit 状态流从不 finish，5 s 整体超时）、App 界面不是原文、套 {"command"} 吞解码错误（另开问题单）、兼容层拒连日志 notice 级默认不记 + swift-log 写 stderr、api/vmix-compat 漏 same-origin、tally 帧不只 PGM / PVW、黄字按原文引、淡出要等动画走完、"不往回跳"、起不来那几句跟界面语言、`--record-min-free-mb` 非整数忽略、401 行补 WS 400 | — |
| 二 | 输出页 | 7 条 + 可选 5 条 | 全改（publish 超时那句与一路重复）：封口句只对低于下限 / ISO 删输入成立，写满 / 写入失败 / 录制器出错随后是"录制 n 封口失败：notRecording"（实现缺口，另开问题单）、写满的归类条件（磁盘满错误码 / 剩余 < 64 MB / 卷被拔）、录制器非磁盘出错那一路开关仍开着显示"起不来"且改设置不重试（同一张问题单）、备用目录约 2 拍后接上 + 写满时有不到 1 s 的空档、纯音频 ISO 格式跟录制 1、连接超时括注范围；可选五条（低于下限切备用目录的提示原文、中文"就改为"、状态行例子里是输出编号、NDI 提示停开后重新计时、事件"断开：<最后错误>"与第一次见到就起不来的只写"起不来"）也改了 | — |
| 三 | 概念 / 快捷键 / 输入 / 故障排查 / README / 测试索引 | 16 条 | 改了 15 条：手点两下赶不上取消那一拍（只有脚本 / API / MIDI 走得到）、越界速率 / 定位的提示播放中看不到、§10 HaishinKit 那条（只有 Adobe 前两轮自己解析、查询串写法整条走 HaishinKit）、README"G2–G13 通过"（G11 gate4 没干净）与"L3 再跑"（从没人跑过）、G12 那三条 S1 的来历、选动作面板那一项的名字"叠加设为开 / 关"、只开一路时"推流 · 起不来"、"（无）"不动开关、备用目录不存在会先建、403 兼容层是纯文本 + 地址栏要带 ?token=、G11 第 2 次 gate4 不归环境、连接超时固定 5 s、"开服务器或改地址"、"不是数按 0"删掉、G13 行补 GPU 判环境 | §10 不加输出编号上限那条 S1（放行前必须修掉；README 状态段写了） |

第一轮三路共报 41 条（一路、二路各报了一次 publish 超时那句，去重 40 条），改了 39 条，和 W4-C4 一样大半是"把报告 / 代码注释 / 单测里的说法当成了行为"——"发布：服务器没回（请求超时）"只在单测里直接调出来过，
"App 界面仍是原文"抄自代码注释，"连点两下就能取消暂停"是没顺着界面的发命令路径走。核对 agent 的结论我都自己对了一遍代码才改（publish 超时、Adobe 轮次、
套壳解码、swift-log 默认输出、tally 帧字段、选动作面板名字、overlay reducer 都复核过）。

### 2.3 工具检查

| 检查 | 结果 |
|---|---|
| `python3 docs/tools/build-help.py --check` | "App/Resources/Help 与 docs/user 一致（18 个文件，879.0 KB）"（4ead438 之后，产物已提交） |
| `scripts/check-links.sh` | 通过：227 个 Markdown 的相对链接与锚点都能解析，Samples 节目文件合法 |
| `make lint BRANCH=w4-docs-5`（别名已挪到头上） | 退出码 0：禁词 / 版本号 0.1.0 / Package.swift、依赖方向 8 个包、check-ownership（43 个改动文件都在允许范围内；加上本报告 44 个）、check-help、check-links、check-rt-symbols 全过 |
| swift 探针（铁律 10：提示框里 DecodingError / MixerStateError 的实际文字） | Swift 6.4：`DecodingError.dataCorrupted: Data was corrupted. Path: mixer. Debug description: 帧率必须为正`；枚举是 `durationTicks(900000)` / `overlayCount(0)` / `inputFrameRate(input: 3)`；都不是 LocalizedError。探针在会话 scratchpad（`probe/probe.swift`），没进仓库 |

## 3. 没做的和原因

1. **docs/CONTRACTS.md 的五处"137 落地后生效"时态**没翻：契约文字归契约会话（问题单 G13-p5-contracts-6-contracts-md-035-present-tense.md → 128）。在它翻之前，CONTRACTS.md §2.11 说"现在 API 还是原文"、docs/api/README.md 说已打码，两处不一致（README 是对的）。
2. **docs/KNOWN_ISSUES.md** 没动（G 会话的文件）：本会话五张新问题单要不要进表由 G14 定；§10 只写表里还开着的三条，指向全表。
3. **截图没重拍**：129–139 没改主窗口的默认样子（格子底边那行小字只在文件输入有方向提示时出现、效果链延迟表在统计窗里），docs/user/img 两张照旧。
4. `scripts/release/release.mk` 第 8 行注释仍写"R1–R6、R11–R14"：scripts 不在本会话目录，交 141 W4-B3 / G14 顺手（一行）。
5. 没跑 App 全量 / gate4（prompt 要求；同机可能有别的会话）。本会话也没改代码，不需要。
6. §10 没列 S1"输出编号没有上限"：要 API 或手改文件才进得来，而且放行前必须修掉（128）；README 状态段写了。
7. G13 §7.1 第 2 条（API 往返比 035 字面严一档）还没定：文档照**现在的代码**写（标记密钥 + 换地址 → 400），见 §4 第 1 条。

## 4. 对契约的疑问

1. **137 的往返规则比提案 035 字面严一档、用户还没定**（G13 §7.1 第 2 条）：docs/api/README.md §1 写的是现在的行为——"换地址时密钥要给原文，密钥给标记而地址变了回 400"；
   故障排查 §8（中英）"setOutputSettings 回 400…"那一行同。要是用户不批（照字面），W2-C 删掉那段判断之后，这两处要改回"标记 = 保留原密钥，地址照收"，并且该写一句风险提示。
2. CONTRACTS.md §2.11 的时态（见 §3 第 1 条）。除此之外没有要改的契约——文档只描述行为。

## 5. 下一个会话需要知道的坑

1. **写手册要对代码，代码注释和单测也不算行为**：本轮第一遍仍被核对查出 40 处（改了 39）。新坑是三种来源：代码注释（"App 界面仍是原文"）、只在单测里调得出来的分支
   （"发布：服务器没回（请求超时）"——生产路径被 5 s 整体超时截走）、没顺着界面发命令的路径推理（格子 ▶ 按快照里的 paused 发，手点两下赶不上"取消暂停"那一拍）。
2. **check-help 比的是工作区**：`make manual` 之后不提交，`make lint` 照样绿（本会话中途就是这样）。交之前 `git status` 看 App/Resources/Help 有没有改动没提交。
3. 套在 `{"command": …}` 里的命令解不开时，API 回的是"Invalid number of keys found, expected one."（真原因被吞，问题单 W4C5-w2-control-command-wrapper-masks-decode-errors）——写 API 例子 / 测 400 文案时用裸命令写法。
4. 打码的"发布名"只在 RTMP / RTMPS 路径 ≥ 2 段、密钥栏去空白后为空时遮：`rtmp://127.0.0.1:1935/s1` 的 s1 不遮（MediaMTX 的单段写法本来就不是密钥）。
5. 兼容层的日志走 swift-log、默认写标准错误：App 从 Finder 起时看不到，headless 在终端里看得到；兼容层默认级别 warning，notice 级的（比如连接数满了拒连）不记。
6. zsh：`echo =====` 报"= not found"；`grep --include=*.swift` 要加引号；ugrep 的 `\|` 交替里写 `**` 会报 empty subexpression。macOS 没有 `timeout` 命令。
7. Swift 6.4 上 `"\(decodingError)"` 是 "DecodingError.dataCorrupted: Data was corrupted. Path: …. Debug description: …"，不是老的 `dataCorrupted(Swift.DecodingError.Context(…))`。
8. 别名分支要在 lint 前挪到 HEAD（`git branch -f w4-docs-5 HEAD`），不然 check-ownership 报"相对 main 没有改动"、看着是绿的。
9. reports/issues/ 五张新单（都是写文档时查出的实现缺口，KNOWN_ISSUES 里没有）：`W4C5-w2-control-compat-tcp-cross-protocol-post`（兼容层 TCP 疑似可被网页跨协议 POST 打到，W2-C；静态确认解析器遇到 HTTP 头不断开，浏览器侧没验，建议按 NS02 同类定）、`W4C5-w2-control-command-wrapper-masks-decode-errors`（套壳吞解码错误，W2-C，S3）、`W4C5-app-recording-failed-paths-notrecording`（录制写满 / 出错后"封口失败：notRecording"、录制器出错那一路开关不关，App，S3）、`W4C5-app-show-open-raw-mixerstate-errors`（打开越界节目的提示是枚举原样，App，S3）、`W4C5-w5-app-gaps-found-by-docs`（英文"Can't / Couldn't start"、文件输入提示只有中文、last_error 中英混着，S3）。
