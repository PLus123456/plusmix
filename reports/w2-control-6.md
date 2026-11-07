# W2-C6 报告：API 状态 / WS 快照 / 命令日志里的推流凭据打码 + `?secrets=1` 要 token（提案 035 已批 A1 的第 ② 步 = Codex 10-24 NS03）（prompt 137，分支 `w2-control-6`，2026-11-07）

工作树 `.claude/worktrees/w2-control-6-073324`，分支 `claude/w2-control-6-073324`，别名 `w2-control-6`（同一个提交）。
136 还没进 main（main = c7d441a），按 prompt 的第二种开法**叠在 `p5-contracts-8` 头 903c0ea 上**（快进过来，没有合并提交）；lint 用 `--base p5-contracts-8`。
不 push、不 merge：交 G13（prompt 140），合入顺序 136 → 137。

## 1. 做了什么

| 提交 | 内容 |
|---|---|
| cd7b3cb | **红用例**：`SwitcherControlTests/NS03StreamCredentialTests`（8 条）+ `App/Tests/W2C6StreamCredentialAppTests`（1 条）；只加让用例编得过的外形：`StateFeed.Counters.secretSnapshots`、`stateResponse(secrets:)`（参数先不起作用） |
| 180cca0 | **实现**：新 `API/StreamCredentialRedaction.swift`（`APIStreamCredentials`）；`StateFeed` 按订阅者给打码 / 原文两份；`APIServer` 的 `?secrets=1` 门槛、log 打码、命令先换回标记再进总线 |
| a99ff8f | **安全复查补一刀**：标记密钥只跟着原来的地址走（换地址 + `"<redacted>"` 密钥 → 400），新用例先红后绿 |
| 24faa71 | `docs/api.md` 重生成（开头一段 + state / command / log / events 各一句） |
| a94788d | App 用例打印这次走的是哪条 `?secrets=1` 分支（有没有 token） |
| （本提交） | 本报告 |

怎么做的：

1. **打码的三处**（`APIStreamCredentials.redacted`）：GET `/api/v1/state` 的 `state`（`StateFeed.stateResponse(secrets:)` 默认打码）、WS `snapshot` 的 `state`（`StateFeed.encode(_:sentAt:secrets:)`）、GET `/api/v1/log`（`CommandLogEntry` 逐条 `redacted`）。
   做法是**改值的拷贝、再走同一个 Codable**，所以键名 / 类型 / 层级与 `MixerState` 天然一致（用例逐层比原文和打码两份 JSON：同样的键、同样的数组长度、同样的值类型，不同的叶子只能是 `*.stream.url` / `*.stream.streamKey`）。
   每个 `StreamSettings`：`streamKey` 非空 → `StreamURLRedaction.marker`、空串照旧；`url` → `StreamURLRedaction.redact(url:publishNameInPath:)`，`publishNameInPath` = 密钥**去首尾空白后**为空（与 `StreamDestination` 判发布名、诊断包 `ShowRedaction` 同口径，见 §4 第 2 条）。
   状态里没有推流设置时原样返回（不拷贝）。命令日志只有 `setOutputSettings` / `addOutput` / `loadShow` 三种带推流设置；`redacted(_ command:)` 的 switch **不写 default**，42 个 case 全列出来——以后新命令带推流设置时编译器会叫人来这里表态（§5）。
   tally / 回执 / hello / stats / 兼容层 XML / Tally 服务没动；输入（`InputSource`）里没有地址类字段（camera / decklink / screen / file / image / ndi / audio / synthetic），不涉及。
2. **往返**（`APIStreamCredentials.restoringMarkers`，`APIServer.submitFromAPI` 在进总线前调；HTTP 单条 / 批量、WS 单条 / 批量四条路都过它）：
   - `setOutputSettings`：`streamKey == marker` 且这一路现在有推流设置 → 换成现在的密钥；`url == 现在的 url 打码后的样子`（用现在的密钥判 `publishNameInPath`，即客户端读到的那个样子）→ 换成现在的 url；
     客户端自己给的值里还带标记（这一路没有 / 没推流设置 / 地址带标记却对不上现在的值，比如快照过期了或改了主机）→ 400；**换回了密钥、地址最后却不是原来那个 → 400**（a99ff8f，§4 第 1 条）。
     "现在的值"取执行到这一条时 `publisher.latest`（与总线校验器同一份；`applyNow` 同步发布快照，所以批量里前一条已生效的也算）。
   - `addOutput` / `loadShow` 里任何推流设置带标记 → 400；不带标记的原文照收。
   - 400 的理由统一是 `推流设置里有打码标记：原文用 ?secrets=1 读`（抛 `CommandRejection`，走现有的 400 / WS error / 批量 index 路径）。总线日志 / reducer / 界面永远看不到标记（用例查了总线日志和状态机）。
3. **要原文**：`grantsSecrets(request)` = 配了 token **且** 查询串 `secrets=1`（只认 1，别的值照旧打码）。配了 token 时门槛就是现有的 `TokenAuthMiddleware`；
   没配 token 时两个路由器都多装一个 `SecretsRequireTokenMiddleware`（装在来源检查之后）：带 `?secrets=1` 的请求一律 `403 {"error":"secrets-require-token"}`，WS 握手被拒（hummingbird-websocket 把非 200 一律写成 400、不升级、不订阅，W2-C5 探过）。路由里再判一次 token 兜底。
4. **StateFeed 另编原文**：`Subscriber` 多一个 `secrets`；`subscribe(secrets:)` 补发时按它编；推送线程每条快照先编打码那份，再看订阅表里有没有 `secrets` 的订阅者——**有才另编原文**（状态里没有推流设置时直接复用打码那份），`Counters.secretSnapshots` 记另编了几次。
   `fanOut(text, raw:, snapshot:)`：原文只给 `secrets` 订阅者、打码的只给其余的；`raw == nil` 而某个订阅者要原文 = 它在"看订阅表"之后才订上，它订阅时补发的快照不比这条旧（`publisher.latest` 只往前走），跳过它不漏东西、也不会把打码那份塞给它。Stats / 回执不带键，照旧所有人都发。
5. **文档**：`APIDocument` 开头鉴权段后加一段（打码规则、`?secrets=1` 只认 1、没 token 403、WS 不升级），state / POST command（往返规则、换地址要给密钥原文）/ log / events 各一句；
   密钥类参数名单不手抄，从契约的 `StreamURLRedaction.secretQueryParams` 排序插进去。重生成 `docs/api.md`，`CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` 过；命令目录没变（仍 42 条），样例形状不变。

探针（铁律 10）：没有新的系统 API 行为要验。WS 被拒握手的状态码沿用 W2-C5 的结论（400），本会话用例打印实测 `NS03 没 token 的 ?secrets=1 WS 握手应答 = 400`。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

功能用例没有阈值，"通过" = 断言全过。日志在会话 scratchpad `logs/`（red.log / green1.log / control-all2.log / app-test1–3.log / lint.log）。

| 用例 | 测什么 | 先红 | 结果 |
|---|---|---|---|
| `testNS03_getState_redactsStreamCredentials_shapeUnchanged` | 五路推流（密钥栏有值 / userinfo / `?user=&pass=` / 密钥栏空的 YouTube 发布名 / SRT streamid+passphrase）：GET state 里 9 个秘密字符串一个都找不到；`stream` 键 = `StreamSettings.jsonKeys`、`settings` 键 ⊆ `OutputSettings.jsonKeys`；打码前后整棵 state 形状一致；状态机里还是原文；`stateResponse()` 默认打码、`secrets: true` 原文 | 红 | ✅ |
| `testNS03_wsSnapshot_redacted_noRawEncodingWithoutSecretsSubscriber` | WS 补发与推送的快照都打码、形状一致；没有要原文的订阅者时 `secretSnapshots == 0` | 红（编译外形后） | ✅ |
| `testNS03_getLog_redactsStreamSettingsInCommands` | 界面来源（`.ui`）的 addOutput / setOutputSettings / loadShow 原文进总线日志，GET log 打码；打码后的命令仍能解成 `Command`、别的字段原样；`?limit` 照旧 | 红 | ✅ |
| `testNS03_secretsWithoutToken_403_wsNotUpgraded` | 没 token：state / log 带 `?secrets=1` → 403 `secrets-require-token`、不漏状态；`secrets=0` / `secrets=true` / 不带 → 200 打码；WS `?secrets=1` 握手 400、不升级、不订阅；不带的 WS 照旧 101 + 打码快照 | 红 | ✅（握手实测 400） |
| `testNS03_secretsWithToken_rawInStateLogAndWS` | 配 token：`?secrets=1`（头里或查询串的 token）三处原文、= 状态机里的值；不带 secrets 打码；token 错 / 没带先 401；WS 一个要原文一个不要同时订阅，推送各拿各的、同一个 sequence；要原文的断开后不再另编 | 红 | ✅ |
| `testNS03_setOutputSettingsWithMarkers_keepsOriginals_appliesOtherFields` | GET state 拿打码 settings（前提：确实带标记）改重连上限 / followFirst / 码率写回，五路的密钥 / 地址都保留原值、别的照改；总线日志里是换回后的命令；新密钥 + 打码地址 = 地址换回、密钥用新的；WS 与批量同样换回 | 第一次跑是**绿**的（还没打码时写回的本来就是原文，测不到东西）→ 补了"写回的 settings 带标记"这条前提再提交；补的前提在实现前必红，但没有单独再跑一遍红 | ✅ |
| `testNS03_setOutputSettingsWithUnmatchedMarker_400_stateUnchanged` | 地址带标记但主机改了、过期快照的地址、录制输出收到标记密钥、不存在的输出 → 400 + 统一理由，状态不变、没进总线 | 红 | ✅ |
| `testNS03_markerKeyWithChangedURL_400_keyNeverFollowsToNewDestination` | 换地址 + 标记密钥（干净新地址 / 去掉 userinfo / 密钥栏空那路 / SRT / 只差一个斜杠）→ 400、状态不变；地址原文 + 标记密钥照旧保留 | 红（五条都 200，密钥跟去了新地址） | ✅ |
| `testNS03_addOutputAndLoadShowWithMarker_400_stateUnchanged` | addOutput（标记密钥 / 地址 userinfo 标记 / 路径标记）、loadShow（读打码状态存的节目）→ 400；批量第 2 条带标记 → 400 index 1、第 1 条生效；WS → error；原文的 addOutput 照收 | 红 | ✅ |
| App `W2C6StreamCredentialAppTests.testNS03_appAPI_redactsStreamCredentials_secretsNeedToken_roundTripKeepsOriginals` | App 实际起的 API（本机这次没配 token）：GET state / log 打码、`?secrets=1` → 403、打码 settings 写回保留原值、addOutput 带标记 400、界面状态不变 | **没单独跑红**（同样的断言在包里先红过） | ✅ 0.48 s |
| **Control 整包** `swift test --package-path Packages/SwitcherControl` | 三个 target | — | ✅ SwitcherControlTests 83（含新 9 条）/ VMixCompatTests 43（1 skip = 既有的人工 C5 常驻用例）/ TallyTests 3，0 失败 |
| `CommandCatalogTests.testCatalog_generatedMarkdownMatchesCommittedDocsApiMd` | 重生成的 docs/api.md 与生成器一致 | — | ✅ |
| `APIServerTests.testC2_pushLatency_inProcess_p99`（整包里顺带） | C2 进程内（多了一次打码拷贝） | — | transport p99 **1.46 ms** / 阈值 50 ms ✅；状态机发布 → 收到 p99 1.49 ms |
| Stream Deck `node --test`（Tools/streamdeck-plugin） | 插件不读密钥 | — | ✅ 16 / 16 |
| App 碰 API 的用例类（`-only-testing`）：ControlWiring 3、LiveSafety 11、LoadShowFormatGuard 1、StartupOrder 4、W2C5BrowserOrigin 2、W2C6 1、W5OFollowup 17；RemoteControlPage 1、StatsWindow 2、InterfaceLock 1 | 打码不影响别的 App 用例 | — | ✅ 43 / 43，0 失败 0 跳（`make gen` + build-for-testing 之后；跑之前等别的会话的 App 测试跑完——两个测试宿主会抢 8765） |
| `make lint BRANCH='w2-control-6 --base p5-contracts-8'`（`LC_ALL=en_US.UTF-8`） | 禁词 / 版本号 / Package.swift / check-deps / check-ownership（7 个改动文件都在允许范围）/ check-help / check-links / check-rt-symbols | — | ✅ 全绿 |

## 3. 没做的和原因

1. **CONTRACTS.md 里"137 落地后生效、现在 API 还是原文"的字样**（标题变更记录 P5-8 那条、§2.5 `StreamSettings` 行、§2.11 表格行与正文、§3 速查）不在本会话归属：G13 合入时翻成现在时（P5-8 报告 §4 第 2 条也提过）；§4 第 1 条若用户批，§2.11 的往返句要补"换地址时密钥要给原文"。
2. **KNOWN_ISSUES"推流凭据外泄"②销号**：不在归属，交 G13。
3. **手册 / docs/api/README.md**：交文档会话（W4-C 系），要改的地方见 §5。
4. App 三处注释还写"推流包的 StreamURLRedaction"（P5-8 报告 §3 第 2 条）：App/Sources 不在本会话归属，没动。
5. 带标记被 API 层拒掉的命令不进总线，所以**不计入** `CommandBus.Counters.rejected`（那个计数只数总线校验器拒的）。觉得要算再说。
6. 没跑整个 App 套件（三百多条、显示类用例要屏幕安静），只跑了碰 API 的 10 个类 43 条；没跑 `make test` 全仓（只改了 SwitcherControl 的 API 目录，别的包不依赖它）。
7. 没改阈值、没加命令、没动契约、节目文件 / 界面 / 兼容层不变。

## 4. 对契约的疑问

1. **（请用户定）往返比提案字面严一档**：提案 035 第 3 条写的是"`streamKey == "<redacted>"` = 保留这一路现在的密钥"、"`url` 等于打码样子 = 保留现在的 url"，两条各自独立。
   照字面做，`{url: 别人的服务器, streamKey: "<redacted>"}` 会被收下：密钥换回原值、地址换成新的，下次开推原密钥就推到了那台服务器——没配 token 时任何连得上 API 的进程都能这么做，等于绕过 `?secrets=1` / `secrets-require-token` 把密钥拿走（提交后的自动安全复查点出来的，用例 `testNS03_markerKeyWithChangedURL_…` 实测照字面五种改法都 200 且密钥跟过去了）。
   现在的做法：**标记密钥换回之后，地址最后不是原来那个就 400**（理由同一句）；换地址就得连密钥原文一起给（有 token 的客户端用 `?secrets=1` 读）。"读 → 改别的 → 整个写回"、"新密钥 + 打码地址"不受影响。
   批了就请契约会话在 CONTRACTS.md §2.11 往返句、提案 035 文末各补一句；不批（要字面）就删 a99ff8f 那一段判断与那条用例。
2. `publishNameInPath` 用"密钥去首尾空白后为空"判，提案写的是 `streamKey.isEmpty`：只会多打（密钥栏只有空格时 `StreamDestination` 也把路径末段当发布名推出去，诊断包 `ShowRedaction` 早就这么判）。`streamKey` 本身只有空白时照"非空 → 标记"。
3. 没配 token 时 `SecretsRequireTokenMiddleware` 对**任何路由**的 `?secrets=1` 都回 403（含 POST command / tally / commands），不只三处——规则一句话说得清；`secrets` 只认 `1`，`secrets=true` 之类照旧 200 打码（安全的方向）。
4. P5-8 报告 §4 第 1 条的几个边角（标记里带 `/ ? #`、尾空白算值的一部分等）：API 用默认标记 `<redacted>`，不受影响。

## 5. 下一个会话需要知道的坑

给文档会话（W4-C 系）——手册 / docs/api/README.md 里"API 状态带原文"改成"打码，要原文配 token 加 `?secrets=1`"：

- `docs/api/README.md` 第 15–18 行（App / headless 的 API 开法与鉴权）加一句：`state` / WS `snapshot` / `log` 里推流 `streamKey` 非空写成 `<redacted>`（空串照旧）、`url` 里 userinfo / 密钥类参数值 / 密钥栏空时的发布名打码；要原文 `?secrets=1` + token；第 55 行状态码表加一行 `403 secrets-require-token`（没配 token 而请求带了 `?secrets=1`；WebSocket 是握手 400、不升级）。
- 写回规则：打码的 settings 原样写回 `setOutputSettings` = 密钥 / 地址保留原值；**换地址时密钥要给原文**（给标记 → 400）；`addOutput` / `loadShow` 带标记 → 400 "推流设置里有打码标记：原文用 ?secrets=1 读"。
- `docs/user/设置.md` 远程控制那页（与 en/settings.md）若有"API 能读到推流密钥 / 只开本机 + token"的提醒，改成上面的口径（"API 只开本机"的建议本身照旧有用：API 能改任何状态）。Stream Deck / Companion 不受影响，不用写。

给 G13（140）：

- 合入顺序 136（`p5-contracts-8`）→ 137（本分支，快进叠在 903c0ea 上，没有合并提交）。合完 `make gen`（App 多一个用例文件）；check-ownership 对 main 比时本分支会带上 136 的文件，用 `--base p5-contracts-8` 或等 136 先进 main。
- CONTRACTS.md 五处"137 落地后生效"翻现在时；KNOWN_ISSUES ② 销号；§4 第 1 条等用户定。
- **新命令带推流设置时**：`StreamCredentialRedaction.swift` 的 `redacted(_ command:)` switch 没有 default，加了 case 编不过——把它加进"原样返回"那一串，或（真带 `StreamSettings` 时）照前三条打码，**同时**在 `restoringMarkers` 里决定写回规则（那个 switch 有 default，不会提醒）。检查点胶水几行的事。
- WS 被拒的握手是 400（hummingbird-websocket 写死），别按 403 断言。

通用：

- App 测试和别的会话的 App 测试同时跑会抢 API 端口 8765（后起的那个 `apiServer` 起不来、用例 XCTFail "API 应已起"），先 `ps -axo comm | grep -E 'xcodebuild|xctest'` 看安静了再跑。
- App 用例按测试宿主的 API 有没有 token 分两种期望（别的用例可能把 token 写进共用设置，W5-L 的坑），日志里打印了这次走哪条。
- `StateFeed.subscribe(secrets:)` / `stateResponse(secrets:)` 默认打码：进程内谁直接调它们也拿到打码版，要原文自己传 true（仓库里目前只有 APIServer 调）。
