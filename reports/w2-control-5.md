# W2-C5（prompt 131）控制层安全与顺序：浏览器来源拦截（NS02 / NS05）、兼容层 TCP 上限（NS07）、新订阅快照顺序（N12）、Stream Deck 畸形快照与日志 token（NS10 / NS11）、提案 035（NS03，待批）

分支 `w2-control-5`（worktree `.claude/worktrees/nostalgic-austin-2633fe`；harness 给的分支 `claude/nostalgic-austin-2633fe` 已挪到同一头当别名），从 G11 快进后的 main bf149e2 开。
不 push、不 merge，交 G12（prompt 134）。机器：Apple M5 Max，macOS 27.0.1，Xcode 27.1（Swift 6.4），Node 26.9.0；同机并行 129 / 130（各自 worktree）。

## 1. 做了什么

先把 Codex 的现象写成用例看着红（dd5dae4），再逐条改；每条一个提交。

| 项 | 改了什么 | 提交 |
|---|---|---|
| 红用例 | `SwitcherControlTests/StateFeedOrderTests`（Codex 的 N12 用例原样搬来改名 `testN12_…`，另加"同 sequence 新拍照发"守门）、`BrowserRequestGuardTests`（照 probe.py 的原始握手；URLSession 不带浏览器的两个头、也拿不到被拒升级的状态码，所以写了 `RawWSClient`）、`VMixCompatTests/CompatBrowserOriginTests`（NS05）、`CompatTCPLimitTests`（NS07）、Stream Deck `test/cases.js` 三条 + `test/plugin-log.test.js`。只加了让用例编得过的外形（两个 `allowedOrigins`、`maxLineBytes` / `maxConnections`、两个计数），没有行为。`LineClient` 设 `SO_NOSIGPIPE`（服务端在用例还在发的时候断开，不能让 SIGPIPE 带走 xctest） | dd5dae4 |
| 1 NS02 / NS05 来源拦截 | 新 `BrowserRequestGuard`（SwitcherControl/API，公开，兼容层借用）：规则在 `BrowserOriginPolicy`——带 `Origin` 只看白名单（不分大小写、去结尾 / 与默认端口；`null` 永远不算）；不带 `Origin` 时 `Sec-Fetch-Site` 只放 `none`，`same-origin` 只在 Host 是 IP 字面量 / localhost 时放（见下一行），别的拦；两个都不带 = 不是浏览器，放。主 API 两个路由器（HTTP + WS 升级）都装、**装在 token 之前**（token 可能被嵌进网页，配了也照拦）→ `403 {"error":"forbidden-origin"}`；兼容层 HTTP 同一个中间件 → `403 text/plain "Forbidden"`（XML 状态一起拦）。`APIServerConfiguration.allowedOrigins` / `VMixCompatConfiguration.allowedOrigins` 默认空 | af340a8 |
| 1′ DNS 重绑定 | 自动安全复查点出来、本会话写用例实测：网页把自己的域名改解析到 127.0.0.1 之后，它的 GET 在浏览器看来是同源、不带 Origin、只带 `Sec-Fetch-Site: same-origin`——按 prompt 写的"none / same-origin 都放"，兼容层的 `GET /api?Function=Cut` 照样切节目、主 API 的 state / log 照样读得到（用例在原规则上红：200、program 1 → 2）。两个服务都不出网页，真同源只可能是地址栏里用本机地址开的页面：`same-origin` 只在 Host（HTTP/1.1 的 authority）是 IPv4 / [IPv6] / localhost / *.localhost 时放（.local 不算） | 9757700 |
| 2 NS07 TCP 上限 | `CompatTCPServer.maxLineBytes = 64 KiB`：一行（不含 \r\n）超过——一次带着换行到的、或迟迟不换行的半行（多留一个 \r 的位置）——记一行 warning、计数 `tcpLinesTooLong`、断开这条连接；`maxConnections = 64`：计数挪到接连接的循环里同步加（原来在每条连接自己的任务里加，第 65 条进来时前面的可能还没记上），满了这一条不发问候直接关、计数 `tcpConnectionsRefused`、记 notice（默认级别不打印，免得被刷屏）。不加空闲超时 | 651f8f1 |
| 3 N12 快照顺序 | `StateFeed` 订阅者表从"流"改成"流 + 最后发出的快照键 (sequence, tick)"：`subscribe()` 补发时登记键，`fanOut` 带快照键、比订阅者已收到的**旧**才跳过；键相同的照发（不经总线的 `apply` / 每拍观察者注入 / headless 场景的 `schedule` 可以在同一拍、同一 sequence 再发布一次不同的状态），同 sequence 的新拍照发。Stats / 回执不带键 | f725c41 |
| 4 提案 035 | `docs/contract-changes/035-api-state-stream-credentials.md`，**待批，没落**（§4） | f4c87a5 |
| 5 NS10 / NS11 Stream Deck | `SwitcherClient.handle`：`state.inputs` / `outputs` 有就得是对象数组（元素是 null / 数字同样会在 find / filter 里抛），不是就丢掉这条、记一行、`snapshot` 不变；没有这两个键的精简快照照收（tally.js 本来按空表算，D17 用例就是这种）。`emit` 包 try/catch：监听回调抛的异常只记一行 log，事件照常往下走（断开回调里抛也照样排重连）。日志：`connected` 只写新加的 `client.endpoint`（host:port），出错日志过新加的 `redactToken`（整项去掉 `token=` 查询项） | 60253d8 |
| 6 docs/api.md | 鉴权那一段加一句来源规则（`APIDocument` 改一句、重生成，`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 过；命令目录没变，仍 42 条） | 899cf3e、18e6aa5 |
| 7 App 用例 | `App/Tests/W2C5BrowserOriginAppTests.swift`（只加用例）：设置默认两个白名单都空；App 实际起的 API 对带 Origin 的 GET state / 跨站 POST cut 回 403、PGM 不变、总线上没有 api 来源的 cut，不带头的照旧 200。`ControlRuntime.swift` 没改（默认就是空白名单，设置页不加项） | 51a9e4f |

探针（铁律 10，结论都已进代码注释 / 用例）：

- **哪些客户端带浏览器的两个头**：本机起一个只抓请求头的服务，URLSession 的 `webSocketTask` 与 `dataTask` 两个都不带；Node 26 自带的 WebSocket（undici）只带 `sec-fetch-mode: websocket`、Node `fetch` 只带 `sec-fetch-mode: cors`，`Origin` / `Sec-Fetch-Site` 都不带；插件用的 `ws` 8.18.0（npm 包原文 lib/websocket.js:779–783）只在传了 `origin` 选项时才写 `Origin`，`plugin.js` 没传。`URLRequest` 能自己写这两个头（用例就这么造浏览器请求）。兼容层的 C5 Companion 脚本（python urllib + socket）整包跑时照过。
- **被拒的 WS 升级回什么**：hummingbird-websocket 2.7.0 的 `HTTP1WebSocketUpgradeChannel` 在 WS 路由器回的不是 200 时一律走 `writeFailedUpgrade`，写死 `400 Bad Request` + `Connection: close`，路由器中间件回的 401 / 403 不转发；`Value.upgradeResult` 是 internal，包一层也接不住。所以浏览器的 WS 握手被拒时看到的是 **400**（按同一段代码，原来配 token 时没 token 的握手也是 400，现有用例只断言连不上），普通 HTTP 才是 403。用例打印的四种来源头都是 400。
- **Host 在哪**：swift-nio-extras 的 `HTTPFields(_:splitCookie:)` 把第一个 Host 头挪进 `HTTPRequest.authority`、从头表里删掉，所以中间件读 `request.head.authority`。Hummingbird 只再导出 `HTTPFields` / `HTTPRequest` / `HTTPResponse`，没有 `HTTPField`，`Sec-Fetch-Site` 按规范名在头表里找（不为它加依赖）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

本会话没有带阈值的测试 ID（都是行为用例），没动任何阈值；64 KiB / 64 条是 prompt 给的上限参数，不是测试阈值。"修前"是改实现之前同一条用例的结果。

| 用例 | 断言的东西 | 修前 | 修后 |
|---|---|---|---|
| `StateFeedOrderTests.testN12_newSubscriberNeverReceivesOlderSnapshotAfterCurrent` | Codex 的交错（clockProvider 卡住推送线程编码第 1 条、第 2 条之后订阅、放行）：新订阅收到的 sequence 单调、开头是 2、一条 1 都没有 | 红：`[2, 1, 2]` | 过：`[2, 2]`（第二个 2 是推送线程补推的同一条，键相同照发） |
| `StateFeedOrderTests.testN12_sameSequenceNewerTickStillSent` | 命令（seq 1）之后转场三拍（tick 12 / 14 / 16，seq 不变）都发：`0@0, 1@0, 1@12, 1@14, 1@16` | 过（守门：只比 sequence 的改法会红） | 过 |
| `BrowserRequestGuardTests.testNS02_originPolicy_rules` | 规则表：不带头放；none 放；same-origin 只在 IP / localhost 的 Host 放（`rebind.attacker.invalid`、`studio.local`、`127.0.0.1.attacker.invalid`、`1.2.3.256`、`[evil.example]` 都拦）；cross-site / same-site / 拼起来的重复头拦；带 Origin 只看白名单，`null` 写进白名单也不算；规范化（大小写、结尾 /、默认端口） | （新类型，改后写） | 过 |
| `BrowserRequestGuardTests.testNS02_wsUpgradeFromForeignOrigin_refusedWithoutSnapshot_plainClientStillUpgrades` | `Origin: https://attacker.invalid` / `Origin: null` / `Sec-Fetch-Site: cross-site` / 两个都带的握手：不是 101、4xx、收不到 hello / 快照、不订阅、补发的 setPreview 进不了总线；不带头的 101 + hello + 快照、setPreview 生效 | 红：四种都 101 + hello，setPreview 生效（preview 4、总线 4 条） | 过：四种都 400 |
| `BrowserRequestGuardTests.testNS02_crossSiteCommandAndState_403_stateUnchanged` | 六种浏览器头（cross-site、same-site、外来 Origin、两个都带、`null`、带本机 Origin 的 same-origin POST）× POST command 与 GET state / tally / commands / log → 403 `forbidden-origin`、不漏状态、总线 0 条；不带头 / none / same-origin（Host 本机）的 GET 200，不带头的 POST 200 生效 | 红：全 200，总线进了 6 条 | 过 |
| `BrowserRequestGuardTests.testNS02_allowlistedOrigin_passesHTTPAndWS_othersStillRefused` | 白名单（`HTTP://Panel.Local:8080/`、`https://ops.example:443`、`null`）：`http://panel.local:8080` / `https://ops.example` 的跨站 POST 200、WS 101 + hello；`attacker`、`null`、端口不同、scheme 不同的 POST 403、WS 不升级 | 红：白名单外的也 200 / 101 | 过 |
| `BrowserRequestGuardTests.testNS02_tokenConfigured_foreignOriginStillRefused` | 配 token：带对的 token + 外来 Origin 的 WS 不升级；Bearer 对 + cross-site 的 POST 403 `forbidden-origin`；没 token + 外来 Origin 先报 403（不是 401）；不带来源头的照旧按 token（对 200、没有 401） | 红：101 + hello、200、401 | 过 |
| `BrowserRequestGuardTests.testNS02_dnsRebindingSameOriginGet_403` | Host `rebind.attacker.invalid` + `same-origin` 的 GET state / log → 403、不漏状态；Host `127.0.0.1` / `localhost` 的 200；不带 Sec-Fetch-Site 的不看 Host | 红（原规则）：200 并带出状态 | 过 |
| `CompatBrowserOriginTests.testNS05_foreignOriginFunctionCut_403_programUnchanged` | 五种浏览器头 × `Function=Cut` 与 XML 状态 → 403 `text/plain` "Forbidden"；program 仍 1、总线 0 条、`functions` 0、`xmlServed` 0；none 的 XML 200，不带头的 Cut 200 生效 | 红：200 OK Cut，program 变了 | 过 |
| `CompatBrowserOriginTests.testNS05_dnsRebindingSameOriginFunctionCut_403` | Host `rebind.attacker.invalid` + `same-origin` 的 `GET /api/?Function=Cut` → `HTTP/1.1 403 Forbidden`、Cut 不执行；Host 本机的 200、生效 | 红（原规则）：200 OK，program 1 → 2 | 过 |
| `CompatBrowserOriginTests.testNS05_allowlistedOriginPasses_othersStillRefused` | 白名单 `http://companion.local:8000` 的跨站 Cut 200；端口不同的 403 | 红：都 200 | 过 |
| `CompatTCPLimitTests.testNS07_lineOverLimit_closesConnection_serverKeepsServing` | 刚好 64 KiB 的行（PING + 空白）照常；65 KiB 不带换行 → 断开；64 KiB + 1 带换行 → 断开、不当命令；`tcpLinesTooLong` = 2；新连接问候 + PING 照常；别的连接照常 | 红：两条都不断开（5 s 超时）、计数 0 | 过（日志 `tcp line longer than 65536 bytes (66560 so far)` / `(65537 so far)`） |
| `CompatTCPLimitTests.testNS07_connectionLimit_extraConnectionClosed_slotFreedAfterClose` | 开满 64 条都有问候、`tcpConnectionsOpen` = 64；第 65 条连得上但没问候、被关、`tcpConnectionsRefused` = 1；已有的 PING 照常；关一条后 open = 63、新连接有问候 | 红：第 65 条照发问候、open 永远到不了 63 | 过 |
| `CompatTCPLimitTests.testNS07_idleTallySubscriberStillReceivesPushes` | SUBSCRIBE TALLY 后静默 2 s，Cut 推 `TALLY OK 2100`、PING 照常（不加空闲超时） | 过（守门） | 过 |
| Stream Deck `NS10（Codex 10-24 审计）：state.inputs / outputs 不是数组…` | 六种畸形（inputs `{}`、outputs `{}`、inputs `"abc"`、outputs `5`、inputs `[null]`、outputs `[1]`）丢掉、各记一行、快照停在 5、不重画；之后合法的 7 照收重画；没有两个键的 8 照收 | 红：`TypeError: inputs.find is not a function` | 过 |
| Stream Deck `NS10：快照 / 断开的回调抛异常不带走进程…` | 快照回调抛 → 记一行、快照照收；断开回调抛 → 记一行、照样排 2 s 重连 | 红：`Error: 重画炸了` 冒出 | 过 |
| Stream Deck `NS11（Codex 10-24 审计）：日志里没有 token…` | `client.url` 照带 `?token=`；`client.endpoint` = `10.0.0.5:8765`；出错日志里没有 token 原文 / 编码后的 token / `token=`；`redactToken` 八种写法 | 红：`endpoint` undefined | 过 |
| Stream Deck `NS11：plugin.js 的日志不写 client.url…`（node 专用） | `plugin.js` 里每个 `logger.*(` 调用都不含 `client.url`，连上那句写 `client.endpoint` | 红 | 过 |
| `W2C5BrowserOriginAppTests.testNS02_appSettingsDefault_noBrowserOriginAllowed` | App 设置的 API / 兼容层配置白名单都空 | （改后写；App 源码没改，默认值来自包里） | 过 |
| `W2C5BrowserOriginAppTests.testNS02_appAPI_refusesBrowserOrigin_plainClientStillWorks` | App 实际起的 API：带 Origin 的 GET state 403 `forbidden-origin`、不带 state；cross-site 的 POST cut 403、PGM 仍 1、总线上没有 api 来源的 cut；不带头的 GET 200 | （改后写） | 过 |

整包与其余：

- `swift test --package-path Packages/SwitcherControl`（最后一笔代码之后）：SwitcherControlTests 69、VMixCompatTests 43（1 跳：`testC5_manualCompanionSession_servesWhenRequested`，人工 C5 用、要设 `SWITCHER_COMPAT_SERVE_SECONDS`，原来就跳）、TallyTests 3——0 失败。现有 `APIServerTests`（含 `testAPI_tokenAuth_401WithoutToken`、`testC2_pushLatency_inProcess_p99`）、`HTTPTests`、`C5CompanionScriptTests.testC5_companionRequestSequence_scriptPassesAllSixItems`、`Compat032RegressionTests` 一条没动、全绿。
- Stream Deck：`node --test test/` 15 / 15（原 11 + 新 4），`scripts/run-jxa.sh` 14 / 14（plugin-log 那条只在 node 跑）。
- App：`make gen` 之后 `xcodebuild test -only-testing:SwitcherTests/ControlWiringTests -only-testing:SwitcherTests/AppSettingsTests -only-testing:SwitcherTests/W2C5BrowserOriginAppTests`，xcresult 计数 6 过 / 0 败 / 0 跳（ControlWiringTests 3、AppSettingsTests 1、新的 2）；运行时警告 7 条都是 `TestSupport.swift` 里等待 / 泵事件的老毛病（QoS 优先级反转），不是新用例的。整套 App 没跑（只动了一个新用例文件，App 源码没改）。
- `make lint BRANCH=w2-control-5`：禁词 / 版本号 / Package.swift / 依赖方向 / ownership（改动文件都在允许范围内）/ check-help / check-links / check-rt-symbols 全过。

## 3. 没做的和原因

- **提案 035（NS03 推流凭据打码）没落**：改的是 API 对外的形态，写完提案停下来问用户；本会话结束时还没批（见 §4）。批了 A2 可以在本分支接着做；批 A1 要等 132 合入、契约会话把 `StreamURLRedaction` 搬进 SwitcherContracts 之后。
- **浏览器的 WS 握手被拒回 400 不是 prompt 写的 403**：hummingbird-websocket 2.7.0 写死（§1 探针）。不升级、不订阅、命令进不了总线这几条都做到了；要 403 只能改库或另包一层 NIO 管线，不值得。
- **prompt 的"same-origin 放"收紧了**：Host 不是 IP / localhost 的 same-origin 拦（DNS 重绑定，§1 第 1′ 行）。比 prompt 严，legit 用法（这两个服务不出网页）没有损失；用户要原样放回只要把 `BrowserOriginPolicy.allows` 里那一个 case 改回 `true`。
- **白名单来源的浏览器 HTTP 没配 CORS**：白名单里的网页走 WS 完全能用；走 HTTP 时 JSON POST 要过预检（OPTIONS 现在 404）、读应答要 `Access-Control-Allow-Origin`，都没做。默认白名单空、App 设置里也没这一项，现在没人用得上；真有网页面板时再做（W2-C 系）。
- **白名单没有设置入口**：prompt 说设置页不加项；App 设置 / headless 命令行都传不进非空白名单，要用得上得有人加（App 设置页一项 + headless `--api-allow-origin` 之类）。
- **残余风险**：不带 Fetch Metadata 的老浏览器（2023 年以前的 Safari、2019 年以前的 Chrome 之类）的 `<img src=…/api?Function=Cut>` 两个头都没有，拦不住；本产品要 macOS 15+，系统自带浏览器都带。没为它给上游协议加 token（Companion 模块不会带）。
- **Tally 服务（SwitcherTally，开着时默认听 0.0.0.0）没装来源拦截**：只读、没有命令、没有推流设置，不在 131 的范围；要不要统一由下一个 W2-C 会话定。
- **Stream Deck 客户端没另加"旧快照不收"**：N12 在服务端修了；客户端按 (sequence, tick) 滤旧要处理服务端重启后 sequence 归零，prompt 没要，没做。
- NS08 明文 / TLS（不归本路）、MIDI、CommandBus/（129）都没碰。

## 4. 对契约的疑问

1. **035 等用户定**（docs/contract-changes/035-api-state-stream-credentials.md）：建议方案 A（原地打码、JSON 形态不变；`?secrets=1` 要配 token；带标记的 `setOutputSettings` = 保留原值），名单放哪二选一——A1 搬进 SwitcherContracts（等 132 合入）/ A2 由 App 与 headless 注入；备选 B（换 DTO）、C（只写文档）。提案里补了 prompt 没提到的第三处泄露：`GET /api/v1/log` 回的命令原文（`setOutputSettings` / `addOutput` / `loadShow`）带同样的 url / streamKey。
2. `APIServerConfiguration.allowedOrigins` / `VMixCompatConfiguration.allowedOrigins` 是 SwitcherControl / VMixCompat 的公开配置，不是 SwitcherContracts，没走提案；`VMixCompatServer.Counters` 多两个计数（`tcpConnectionsRefused` / `tcpLinesTooLong`）同理。`APIServerConfiguration.init` 的新参数放在最后、带默认值，App / headless 的调用不用改。
3. 新的 API 应答（403 `forbidden-origin`、浏览器 WS 握手 400）写进了 docs/api.md；要不要进 CONTRACTS.md 的 API 一节由契约会话定。

## 5. 下一个会话需要知道的坑

给 W4-C5（docs/api/README.md 与手册）：

- **来源规则**：带 `Origin` 而不在 `allowedOrigins`（默认空，`null` 永远不算）→ 403；不带 `Origin` 时 `Sec-Fetch-Site` 只放 `none`（地址栏直接打开），`same-origin` 只在 Host 是 IP / localhost 时放，`cross-site` / `same-site` 拦；两个都不带（Stream Deck、Companion、curl、Python / Node 脚本、URLSession）放。先查来源再查 token。主 API → `403 {"error":"forbidden-origin"}`，浏览器的 WS 握手 → 400、不升级；兼容层 HTTP → `403 text/plain "Forbidden"`（含不带参数的 XML 状态）。TCP 8099 不涉及。
- **结果就是**：在浏览器地址栏里直接打开 `http://127.0.0.1:8765/api/v1/state` / `http://127.0.0.1:8088/api` 照旧能看；网页（包括用户自己写的网页面板）不在白名单里就连不上，白名单目前没有设置入口。
- **兼容层 TCP 上限**：一行最长 64 KiB（不含 \r\n），超了这条连接被断开（日志一行 warning）；同时最多 64 条连接，满了新连接连上即被关、没有 `VERSION OK` 问候；没有空闲超时（只订阅 TALLY 不发命令的客户端一直挂着没问题）。
- **035**：没批之前 API 状态与命令日志照旧带推流密钥原文，手册里"API 只开本机 + 设 token"的提醒照旧。
- Stream Deck：收到格式不对的快照会丢掉并记一行"快照格式不对…"；日志里连上那句只写 host:port。

给 G12（134）：

- 合入顺序与冲突：本分支动了 `docs/api.md` 的开头一段（鉴权那一句后面加一行）；129 改命令目录后也会重生成 docs/api.md——不同段落，git 合得上，**合完以后再跑一次 `switcher-apidoc` 比对**（`testCatalog_generatedMarkdownMatchesCommittedDocsApiMd`）。`APIServer.swift` / `StateFeed.swift` 129 不碰。App 只加了一个新用例文件，与 130 不重叠；合完要 `make gen`。
- `CompatCore.noteConnectionOpened()` 换成了 `openConnection(limit:)`（计数挪到接连接的循环里），别的分支没有调用点。
- 被拒的 WS 握手是 400：别按 403 写断言（hummingbird-websocket 升版本时值得复查一次，若它开始转发路由器的状态码，用例里的 `(400..<500)` 照样成立）。
- 用 URLSession 造浏览器请求时 Origin / Sec-Fetch-Site 能写、Host 不能写（DNS 重绑定的用例走原始 socket：`RawWSClient.httpGet` / VMixCompat 的 `LineClient`）。
- KNOWN_ISSUES 里 N12 / NS02 / NS05 / NS07 / NS10 / NS11 六行可以销号（NS03 ② 等 035）；NS02 的定级改口、035 的方案由用户定。
