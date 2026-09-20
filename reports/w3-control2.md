# W3-D 控制二期（第三方 API 兼容层、Stream Deck 插件、外部 tally 基础）—— 报告（分支 w3-control2）

日期 2026-09-19。机器 Apple M5 Max / macOS 26.6.2 / Xcode 27.0 / Swift 6.4，电源适配器，室温；同机有别的会话在并行编译（`uptime` 负载 2–3）。
worktree `.claude/worktrees/w3-control2-vmix-tally-2c1f6d`，分支 `claude/w3-control2-vmix-tally-2c1f6d`（桌面端自动起的名），从 `main`（f1bd1ee）开；
**`w3-control2` 这个分支名指向同一个 HEAD**（`git branch -f w3-control2`），`make lint BRANCH=w3-control2` 和检查点合并用它。
提交：`git log main..w3-control2`。动了 `Packages/SwitcherControl/{Package.swift, Sources/VMixCompat/, Sources/Tally/, Tests/VMixCompatTests/, Tests/TallyTests/}`、
`Tools/streamdeck-plugin/`、`docs/integrations/`、`docs/contract-changes/011`、本报告、`scripts/apitest/c5-companion.py`；另按用户 2026-09-19 的裁定（"这两个按照你的想法来"）动了本会话目录之外的两个文件：`docs/OWNERSHIP.md`（W3-D 行加 `scripts/apitest/`，§4 第 1 条）和 `scripts/lint-rules.sh`（提案 011 的受控例外，§4 第 2 条）。

## 1. 做了什么

| prompt 交付 | 落点 | 说明 |
|---|---|---|
| 1 兼容层（VMixCompat，独立 target，默认关） | `Sources/VMixCompat/`（13 个文件） | `VMixCompatConfiguration.enabled` 默认 **false**，关着时 `start()` 不监听任何端口（测试钉着）。HTTP `GET /api/?Function=…`（也认 `/API`、结尾斜杠）与 `GET /api` 的 XML 状态（默认 8088）；TCP 文本协议（默认 8099）：FUNCTION / TALLY / XML / ACTS / SUBSCRIBE·UNSUBSCRIBE TALLY·ACTS / PING / VERSION / QUIT，XMLTEXT 明确 NotImplemented。函数名 → `[Command]` 的映射表（`FunctionTranslator`，纯函数）做了 Companion 模块用到的子集：prompt 点名的 22 个全在，另加 Wipe / Zoom / Stinger1 / Transition1 / SetTransitionEffect1 / SetTransitionDuration1 / SetFader / CutDirect / PreviewInputNext·Previous / SetInputName / StartStop* / SetBusA·BVolume / SetHeadphonesVolume / SetVolume / AudioBus* / Solo* / SetBalance / MasterAudio* / BusA·BAudio* / BusXAudio* / OverlayInputN In·Out·Off·Last / OverlayInputAllOff，共 70 个名字（`FunctionCatalog.implemented`）。未实现的分两档：对方有的返回 `NotImplemented`（HTTP 501）+ 点名的文案，完全不认识的 `UnknownFunction`（400）；参数问题 `BadParameter`（400）、`InputNotFound / OutputNotFound`（404）、`NotConfigured`（409）。所有命令走 `CommandBus`（来源 `.api`），状态和表读数从 `StateFeed` / `Stats` 读同一份（铁律 4） |
| XML 状态 | `StatusXML.swift` | 节点集合按 Companion 模块 `data.ts` 的硬性要求（version / edition / inputs / overlays / preview / active / fadeToBlack / transitions / recording / external / streaming(channelN) / playList / multiCorder / fullscreen / audio），**输入位置 = 编号**（它用 `inputs[编号 − 1]` 找），编号有空洞补 Blank 占位；`key` 是由编号生成的稳定 GUID，`Input=` 参数四种写法（编号 / 0 = PVW / -1 = PGM / GUID / 标题）都认；`volume` 按对方的曲线（幅度 = (推子/100)⁴）；表读数来自 `Stats.audio.meters`。长度头含结尾 CRLF（对方协议规定，Companion 按它切） |
| TALLY / ACTS | `TallyDigits.swift`、`Activators.swift` | TALLY 串只看 `MixerState.tally(ofInput:)`（转场中 PVW 也是 1）；ACTS 查询 31 个名字，事件由前后状态差推出（PGM / PVW → 叠加 → Recording / Streaming / External / FTB → 每路输入音频 → 总线），每条连接自己订阅快照流（`SnapshotWatcher`，最新 64 条，慢的丢旧） |
| TCP 服务端 | `CompatTCPServer.swift` | swift-nio `NIOAsyncChannel`：每连接一个会话，读方按 **UTF-8 字节**切行（Swift 把 `"\r\n"` 当一个字符，`firstIndex(of: "\n")` 找不到——踩过），推方跑订阅；粘包、只有 `\n`、三条并发连接都测了 |
| 2 Stream Deck（二选一做完整） | `Tools/streamdeck-plugin/` | 官方 SDK（`@elgato/streamdeck` ^2，Node 20，Stream Deck 6.6+）插件，对着本地 API（WS `/api/v1/events` 收整快照，连接上发命令等回执）。9 个动作：cut / auto·fade / preview / program / tally / overlay / record / stream / ftb；**按钮颜色 = tally**（PGM 红、PVW 绿、转场中红底绿边、叠加琥珀、录制红、推流蓝、FTB 黑底白边），每次快照重画。纯逻辑（快照 → 样式、按下 → 命令、SVG 图、base64）在 `lib/tally.js`，`test/cases.js` 7 组断言 `npm test` 或 `scripts/run-jxa.sh`（macOS 自带 JavaScriptCore）都能跑。Companion 原生模块只写文档（`docs/integrations/companion.md` §2：结构、动作 / 反馈对应表） |
| 3 Tally 输出基础 | `Sources/Tally/`（`SwitcherTally` 独立 target，3 个文件） | `TallyPublisher`（SnapshotObserver → 只在 tally 内容变化时出一帧 → 扇出，订阅者各自缓冲 64）+ `TallyServer`（Hummingbird：WS `/tally` hello → 当前帧 → 变化帧 + 心跳；`GET /tally` 轮询）。`TallyFrame` = program / preview / transitionActive / ftb / recording / streaming / 每路 {number, name, program, preview} / 录制推流输出开关；第二版 TSL 直接用它（tally.md 写了怎么做） |
| C5 自动化 | `scripts/apitest/c5-companion.py` | 标准库；像 Companion 一样开三条连接（命令 / SUBSCRIBE ACTS / 每 250 ms 轮询 XML）加一条 SUBSCRIBE TALLY，六项逐个判定，另附 HTTP 一项；退出码 = 结果。`testC5_companionRequestSequence_scriptPassesAllSixItems` 在进程内起兼容层（带拍推进）跑它 |
| 人工 C5 的临时入口 | `testC5_manualCompanionSession_servesWhenRequested` | 没有 headless 参数之前：`SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual` 在 8099 / 8088 挂一个 8 路输入、带拍推进的兼容层，Companion 连 127.0.0.1 |
| 文档 | `docs/integrations/{README, vmix-compat, companion, stream-deck, tally}.md` | 法律说明在 vmix-compat.md 顶部；函数覆盖表、错误码、协议细节、Companion 六项的配法、tally 流格式 |

`swift test --package-path Packages/SwitcherControl`：**56/56 绿**（VMixCompatTests 25，含 1 个人工用的 skip；TallyTests 3；原有 SwitcherControlTests 28），约 11 s。
`scripts/lint-rules.sh`：**绿**（提案 011 落地后：XML 根元素字面量那一行带 `lint:allow-protocol-literal` 标记被放行；两个反例——标记放在别的目录、VMixCompat 目录下没标记的行——都仍被拦，跑过），版本号 / Package.swift 约束绿；`scripts/check-deps.sh` 绿（新 target 只依赖 SwitcherCore 与第三方）；`scripts/check-rt-symbols.sh` 绿；
`scripts/check-ownership.sh w3-control2` 只报用户授权改的两个文件 `docs/OWNERSHIP.md` 和 `scripts/lint-rules.sh`（都不在任何功能会话的行里，G4 合并时按提交信息认领，同 W2-C 先例）。`swift build --package-path Tools/switcher-headless` 绿（Package.swift 改了依赖声明后下游仍能解析；`Package.resolved` 没变）。

## 2. 每个测试：数值 / 阈值 / 通过否

| 测试 ID | 口径 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| C5 兼容层（自动化） | `scripts/apitest/c5-companion.py` 对进程内兼容层（带拍推进，4 路输入）：Cut / Fade(500 ms) / Overlay 1 开→关→In→Off / Record 开关 / Stream 开关 / Tally 反馈（XML、TALLY 命令、TALLY 订阅三处一致）+ HTTP 附加项 | 6/6 通过（+HTTP 通过），1.7 s；三条连接、XML 轮询 > 5 次、ACTS 事件全部收到 | 六项全部通过 | ✅ |
| C5 兼容层（真 Companion） | 用户装 Companion 后配一页按钮对着 8099 逐个按 | — | 六项全部通过 | **BLOCKED-人工**：本机没装 Companion，也没有 headless 的兼容层参数（G4 接线，§5 第 1 条）；解锁：装 Companion，按 docs/integrations/companion.md §1 配，服务端用 headless 参数或 `testC5_manual` 常驻模式 |
| C5 未实现函数返回错误 | `testC5_unimplementedFunctionsReturnExplicitErrors`、`testC5_tcp_functionsChangeStateAndReportErrors`、`testC5_http_xmlStatusAndFunctions` | 9 个对方函数 → NotImplemented（501）且文案点名；未知 → UnknownFunction（400）；输入不存在 → 404；参数越界 → 400；TCP 上 `FUNCTION ER <码>: <文案>` | 不静默 | ✅ |
| C3 口径：XML 状态里 tally 与快照一致 | `testC3_tallyDigitsAndXMLAgreeWithSnapshotTallies`（空闲 / 转场中 / 叠加可见 / PGM==PVW / FTB 五种状态）、`testC3_xmlStructure_matchesSnapshot`、`testC3_xmlReflectsOutputsOverlaysTransitionAndAudio`、`testC3_gapsInInputNumbersGetBlankPlaceholders` | TALLY 数字与 `MixerState.tally` 逐路相等 0 不一致；XML 的 active / preview / overlays 推出的 PGM 集合 ⊆ 快照 tally.program，唯一差别是转场中的 PVW（XML 没有"转场中"字段，TALLY 串有） | 0 不一致 | ✅ |
| 兼容层关闭时端口不监听 | `testC5_disabledLayerListensOnNoPort` | `enabled` 默认 false；start 后 isRunning false、两个端口 connect 都 ECONNREFUSED；打开后监听、只开 TCP 时 HTTP 端口仍拒绝；stop 后端口释放 | 不监听 | ✅ |
| TCP 协议 | `testC5_tcp_greetingPingVersionTallyXMLAndQuit`、`…subscribeTallyPushesOnChange`、`…subscribeActsEventsAndQueries`、`…threeConnectionsLikeCompanion` | 问候 / PING / VERSION / TALLY / XML 长度含 CRLF / 粘包 / 只 `\n` / 未知命令 / QUIT 关连接；TALLY 订阅只在变化时推（改名、增益不推；转场中 0110，完成 0210）；ACTS 12 种事件 + 10 种查询；三连接 + 200 ms Fade 在 2 s 内对调 | — | ✅ |
| HTTP | `testC5_http_xmlStatusAndFunctions`、`…onlyHTTPWhenTCPDisabled` | 4 种路径写法都 200 text/xml；函数 200 `OK <名字>[ (no change)]`；参数名不分大小写；按名字选输入；501 / 400 / 404；`/nope` 404 | — | ✅ |
| 映射表 | `FunctionTranslatorTests` 10 个 | 解析（百分号、+、大小写）、切换、PVW / PGM、转场槽 / 推杆、叠加 12 种情况、录制 / 推流（含多路推流 Value 与配置指定）、FTB、音量曲线往返 1e-6、音频开关 / 路由 / 独听 / 声像 / 改名、未实现 / 未知 | — | ✅ |
| Tally 流 | `testTally_frameDerivedFromSnapshot`、`…publisherEmitsOnlyWhenTallyChanges`、`…wsStreamHelloFrameUpdatesAndPolling` | 帧与 `MixerState.tallies` 逐路相等；增益变化不出帧、改名 / 录制 / 转场出帧；WS hello → 帧 → 变化帧、1 s 心跳、GET 与最近一帧一致；不读的慢订阅者下 1000 条命令 < 5 s；断开退订 | — | ✅ |
| Stream Deck 纯逻辑 | `Tools/streamdeck-plugin/test/cases.js` 7 组（`scripts/run-jxa.sh`） | tallyFor / outputOf / fpsFrom / keyStyle 16 种情况 / commandFor 16 种 / SVG 转义·截断·base64 / 报文分类 | — | ✅（JXA） |
| Stream Deck 插件端到端 | 装进 Stream Deck 软件点按钮 | — | 按钮 = 命令、颜色 = tally | **BLOCKED-硬件**：本机没有 Node、没有 Stream Deck 软件 / 硬件；解锁：`npm install && npx streamdeck link …`（docs/integrations/stream-deck.md） |

## 3. 没做的和原因

1. **Companion 原生模块**：prompt 说二选一做完整、另一个写文档；做完整的是 Stream Deck 插件，Companion 模块只有 `companion.md` §2 的骨架文档（结构、动作 / 反馈对应表、要点）。Companion 模块是 Node 包，本仓库归属里也没有它的目录。
2. **headless / App 接线**：`Tools/switcher-headless/` 和 `App/` 不在本会话目录里。headless 加兼容层 / tally 参数是 G4 的胶水（§5 第 1 条给了现成的片段，≈ 30 行）；设置里的开关 + 法律提示文案是 W3-E（prompt 54 第 7 条）。
3. **TSL UMD**：prompt 写明第二版；`tally.md` 记了怎么从 `TallyFrame` 生成。
4. **XMLTEXT（XPath 取单值）**：Companion 不用；返回 NotImplemented 并提示拿 XML 自己解析。
5. **对方的其他函数族**：转场效果（Slide / Fly / Merge…只做 Cut / Fade / Wipe / Zoom / Stinger）、Transition2–4、OverlayInput5–8 / Zoom / PreviewOverlay、External / MultiCorder / Fullscreen / SRT 输出（本产品的外部输出没有开关命令）、AudioAuto（AFV 是全局的，语义不同）、SetGain（只有一个增益）、声道混音器 / 插件 / Title / List / Replay / PTZ / VideoCall 等——都返回 NotImplemented + 文案，清单在 vmix-compat.md §6。
6. **XML 里的"转场中"**：对方的 XML 没有这个字段，Companion 的 PGM 反馈在转场那几十帧只亮旧 PGM；TALLY 订阅、ACTS、外部 tally 流都正确（C3 测试把这一差别钉成唯一允许的差别）。
7. **Stream Deck 插件没在真机上跑过**：本机没有 Node（不想擅自 `brew install`）、没有 Stream Deck 软件。SDK 接线按 `@elgato/streamdeck` 2.x 的公开 API 写（`SingletonAction` 子类 + `manifestId` 字段、`streamDeck.actions.registerAction`、`settings.getGlobalSettings`），纯逻辑在 JXA 里验过；接线层需要用户在装了 Stream Deck 的机器上 `npm install` 后验证。
8. **鉴权**：对方的 TCP 协议没有鉴权，HTTP 的可选 basic auth 也没做；默认只听 127.0.0.1。

## 4. 对契约的疑问 / 等拍板

1. **OWNERSHIP：`scripts/apitest/` 进 W3-D 行（用户 2026-09-19 批："这两个按照你的想法来"，已落地）**：prompt 的测试段写明 TCP 客户端脚本放 `scripts/apitest/`，但 W3-D 的归属行原来没有它（W2-C 当时同样的情况，用户 2026-09-15 裁定加进归属行）。我给 `docs/OWNERSHIP.md` 的 W3-D 行加了 `scripts/apitest/` token 和备注（同时补了 Package.swift 只许加两个 target 的备注），单独一个提交；`docs/OWNERSHIP.md` 本身不在任何功能会话的行里，G4 合并时按提交信息认领。
2. **lint 禁词例外（提案 011，用户 2026-09-19 批，已落地）**：XML 根元素名是对方协议规定的，Companion 靠 `startsWith('<…>')` 识别文档，没法改名；`StatusXML.rootElement` 写字面量（唯一一处，测试引用常量），用字符串拼接绕过 lint 是自欺欺人。落地方式：`scripts/lint-rules.sh` 加例外 2——只放行 `Packages/SwitcherControl/Sources/VMixCompat/` 下、同一行带 `lint:allow-protocol-literal` 标记的行，标记出现在别的目录不算数；该常量行加了标记。反例验证过：标记放到 `Sources/Tally/` 仍拦、VMixCompat 目录下没标记的字面量仍拦。这不是契约变更，放 docs/contract-changes/ 是因为它是决策记录。**编号 011 是按本机所有分支已用到 010 取的**，若 W3-C / W3-E 也用了 011，G4 合并时改号（提案文件名、vmix-compat.md 的链接、StatusXML.swift 和 lint-rules.sh 注释里的编号一起改）。
3. **不改契约**：本会话没有改 SwitcherContracts 的需求。用到的都是现成的：`MixerState.tallies`（tally 的唯一算法）、`Command` 27 个 case、`Stats.audio.meters`（提案 004）、`TickClockSpec.frameRate`。
4. **`reportedVersion` 报的是本产品版本（0.1.0）而不是对方的版本号**：Companion 模块只用主版本号 ≥ 27 决定要不要解析色彩校正 / 位置节点（我们不输出），其他动作不看版本；如果将来某个客户端按版本号拒绝连接，再考虑——冒充对方版本号是法律上更不想碰的事。
5. **Stream Deck 插件 UUID 用了 `com.plusmix.switcher`**（仓库名反写）：发布前要不要换成正式域名，随 G5 的版本号一起定。

## 5. 下一个会话需要知道的坑

1. **G4 接 headless 的胶水**（≤ 50 行，都在 `Tools/switcher-headless/Sources/switcher-headless/`）：
   - `HeadlessCLI.swift`：加参数 `--compat`（默认关）、`--compat-listen host`（默认 127.0.0.1）、`--compat-tcp-port N`（8099）、`--compat-http-port N`（8088）、`--tally-port N`（给了才起，默认不起）；参数名里**不能带对方的名字**（`Tools/` 在 lint 扫描范围内，`VMixCompat` 这个 token 可以）。
   - `HeadlessRun.swift`：`import VMixCompat`、`import SwitcherTally`；
     ```swift
     var cfg = VMixCompatConfiguration(); cfg.enabled = options.compat; cfg.host = …; cfg.tcpPort = …; cfg.httpPort = …
     let compat = VMixCompatServer(bus: bus, feed: feed, configuration: cfg)          // 与 APIServer 同一个 bus / feed
     let tallyPublisher = TallyPublisher(stateMachine: stateMachine) { engine.clock?.spec }
     let tally = options.tallyPort.map { TallyServer(publisher: tallyPublisher, configuration: .init(host: "0.0.0.0", port: $0)) }
     // 起：feed.start() 之后 → try await compat.start()（enabled 为 false 时是空操作）；await tallyPublisher.start(); try await tally?.start()
     // 停：await compat.stop(); await tally?.stop(); await tallyPublisher.stop()，然后再停 API / 引擎 / feed（顺序同 API：先停入口再停引擎）
     ```
     汇总行可以打印 `compat.counters`（functions / functionErrors / tcpConnectionsAccepted / xmlServed / tallyEvents / actsEvents）和 `tallyPublisher.counters`。
   - App（W3-E）：`ControlRuntime` 里同样两行；偏好设置加"第三方 API 兼容层"开关（默认关）+ 法律提示文案（vmix-compat.md 顶部那段的短版）+ 两个端口；tally 端口开关。
2. **Swift 的 `"\r\n"` 是一个 Character**：`String.firstIndex(of: "\n")` 在 CRLF 文本里永远找不到。行协议按 UTF-8 字节切（`[UInt8].firstIndex(of: 0x0A)`），测试里的 `LineClient` 用 Data 切也是这个原因。
3. **Hummingbird 的路由把结尾斜杠归一**：同时注册 `/api` 和 `/api/` 会在起服务时 `Fatal error: GET already has a handler`（进程直接崩，不是抛错）；只注册 `/api` 就同时接住两种写法。
4. **Companion 模块的硬性要求**（都有测试钉着，改 XML 前先看 `StatusXMLTests`）：XML 正文必须以根元素开头结尾（不能有前导空白）、长度含结尾 CRLF；`version` / `edition` / `audio` / `recording` / `streaming` / `fadeToBlack` / `external` / `playList` / `multiCorder` / `fullscreen` / `preview` / `active` 缺一个它的解析就抛异常；输入按 `inputs[编号 − 1]` 找；`PING` 要回 `PING OK PONG`；它连上会问 `ACTS BusASolo … BusGSolo`。
5. **SwiftPM 拉包**：这个 worktree 第一次 `swift build` 要从 GitHub 拉 27 个包，本机当时 GitHub 时断时续（`LibreSSL SSL_ERROR_SYSCALL` / `HTTP2 framing layer`），`swift build --skip-update`（已标记弃用但还能用）能用本机缓存继续。`Package.resolved` 加了 swift-nio 直接依赖后没有变化（它本来就在图里，版本 2.102.0）。
6. **NIO 侧**：`ServerBootstrap.bind(host:port:) { NIOAsyncChannel(wrappingChannelSynchronously:) }` + 外层 `withThrowingDiscardingTaskGroup` + 连接内 `executeThenClose`；`stop()` 靠取消接受任务，连接任务随任务组一起取消，测试里 stop 后端口立刻可重绑（`so_reuseaddr`）。`NIOAsyncChannelOutboundWriter` 从两个任务写（应答 + 推送）没出过乱序。
7. **推送的合并语义**：每条 TCP 连接和每个 tally 订阅者各自缓冲最新 64 条快照 / 帧，慢客户端丢旧的；ACTS 事件按"上次看到的状态 → 这次"算差，被合并掉的来回不会都发（收敛到最终状态）。C4 满负载（每秒 200 条命令）时 XML 轮询客户端不受影响（每次要 XML 都是当下的快照）。
8. **人工 C5 的常驻模式**是测试函数（`testC5_manual…`，环境变量触发），没有引擎、只有拍推进，所以 Fade 会走完但画面不存在；G4 接了 headless 参数后用 headless（有真画面，C3 的 frameprobe 也能对）。
9. **Stream Deck 插件**：`manifest.json` 的 `Nodejs.Version` 只能是 "20" 或 "24"；SDK 2.x 的 npm 包要求 node ≥ 20.5.1；`UserTitleEnabled: false` 是因为图上的字由插件画（SVG data URI，`setImage`），用户标题会盖在上面。没有 `npm install` 之前 `bin/plugin.js` 起不来（`@elgato/streamdeck`、`ws` 都不在仓库里）。
10. **Stream Deck 的图标**是 `scripts/gen-icons.py` 用标准库写的 PNG（纯色块，没有文字），运行时按钮图由 SVG 盖掉；要换视觉直接改脚本重生成。
