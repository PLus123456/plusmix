# W5-D 推流地址鉴权：RTMP / RTMPS 地址里的 user:pass@ 传到连接层 —— 报告（分支 w5-stream-auth）

日期 2026-10-01。机器 Apple M5 Max 128 GB / macOS 27.0 (26A428) / Xcode 27.0 (27A266a) / Swift 6.4 / MediaMTX 1.21.0（brew）/ ffmpeg 9.0.1（brew）/ HaishinKit 2.2.5（dc880cb）。电源适配器，室温。
worktree `.claude/worktrees/w5-stream-auth-691357`，分支 `claude/w5-stream-auth-691357`（桌面端自动起的名），从 `main`（25af61f）开；**`w5-stream-auth` 指向同一个 HEAD**（`git branch -f`，同 W2-D 先例），`make lint BRANCH=w5-stream-auth` 和检查点合并都用它。
只动了 `Packages/SwitcherOutputs/Sources/Streaming/`、`Packages/SwitcherOutputs/Tests/StreamingTests/`、`App/Sources/Release/ShowRedaction.swift`、`App/Tests/ReleaseTests.swift`（一条用例）、本报告、`reports/issues/W5D-*`（5 张）。不动契约、界面、Package.swift、HaishinKit。

问题单：`reports/issues/UIA-w2-stream-rtmp-userinfo-dropped.md`（X25 / L10 / V12 的前半）——本会话修完。

## 1. 做了什么

### 1.1 第一步结论（铁律 10 探针）：HaishinKit 带 userinfo 时走 **Adobe 鉴权**（authmod=adobe），不走 llnw；MediaMTX 不认这一套；HaishinKit 自带的那套**不能直接用**

探针都在 scratchpad（不入库）：`authprobe`（SwiftPM 小包，依赖同一版 HaishinKit 2.2.5，直接用 `RTMPConnection` / `SRTConnection`）、`tap.py`（30 行 TCP 抓包代理，把客户端发出的字节按连接存盘）、`urlprobe.swift`（Foundation 的 userinfo 解析）、两份 MediaMTX 配置（`authMethod: internal` + `authInternalUsers`；`srtPublishPassphrase`）。
"Adobe 鉴权的服务器端"本机没有现成的（MediaMTX 不做，见 2），我按 FMS / Wowza 的回话格式（ffmpeg rtmpproto.c 与 HaishinKit 解析它的方式）写了一个独立实现 `AdobeAuthGateway`，探针和测试共用（§1.2 表里"测试工装"一行）。

**1. HaishinKit 2.2.5 读源码**（`RTMPHaishinKit/Sources/RTMP/`）：
- `RTMPConnection.connect(_:)`：按 URL 的 host / port 连 socket；connect 命令的 `app` = 路径 + "?" + 查询串，`tcUrl` = **去掉 userinfo** 的整个地址（`absoluteWithoutAuthenticationString`）——账号密码从来不明文上线。
- `RTMPAuthenticator`：服务器拒绝（`NetConnection.Connect.Rejected`）时看描述：含 `reason=needauth` → 用 salt / challenge / opaque 按 Adobe 公式算应答，地址后面接 `&opaque=…&challenge=…&response=…` 重连；含 `authmod=adobe` → 地址后面接 `authmod=adobe&user=…` 重连；别的 → 失败。**只有 Adobe，没有 llnw（Limelight）**，也不会把 userinfo 换成查询串参数。
- 抓包证实（tap.py）：`rtmp://pub:secret@…/s1` 的 connect 里 tcUrl = `rtmp://127.0.0.1:19351/s1`、app = `s1`，字节里没有 `secret`；`?user=pub&pass=secret` 的写法则 app / tcUrl 都带着查询串明文上线。

**2. MediaMTX 1.21 开鉴权**（`authMethod: internal`，用户 pub / secret 只给 publish）：

| 地址 | ffmpeg 9.0.1 | HaishinKit 2.2.5 |
|---|---|---|
| `rtmp://127.0.0.1:19350/s1`（不给） | `Server error: authentication failed` | connect 成功，publish 回 `NetStream.Publish.Unauthorized`（MediaMTX 故意拖 2.5 s 才回，再晚就是 requestTimedOut） |
| `rtmp://pub:secret@…/s1`（userinfo） | 同上，失败 | 同上，失败 |
| `rtmp://pub:secret@…/s1?authmod=adobe&user=pub`（逼它发挑战） | 失败，MediaMTX 不发 needauth | — |
| `rtmp://…/s1?user=pub&pass=secret`（查询串） | **推上**（`is publishing to path 's1'`） | **推上**（`NetStream.Publish.Start`） |

→ MediaMTX 的 RTMP 鉴权 = connect 一律接受、publish 时看查询串 `user` / `pass`；**不做 Adobe 挑战**，地址里的 user:pass@ 对它没用（哪个客户端都一样，userinfo 根本不上线）。所以"对本地 MediaMTX 开鉴权验证能推上"：**user:pass@ 直推 MediaMTX 推不上，这是 MediaMTX 的规矩，不是我们或 HaishinKit 少了什么**；端到端改成"Adobe 网关验 user:pass@ → 换成 MediaMTX 的查询串转给开了鉴权的 MediaMTX"（§1.3、§2），另一条用查询串直推。

**3. HaishinKit 自带 Adobe 鉴权的实测**（authprobe 对 AdobeAuthGateway，网关后面接开鉴权的 MediaMTX）：

| 场景 | 结果 |
|---|---|
| 正确密码（只含字母数字） | 推上：网关见 3 次 connect（要 adobe → 发挑战 → 验过）；但 21 次里 2 次 `socketErrorOccurred(nil)`（见第 3 条毛病） |
| 用户名带 @（`me%40example.com`） | 推上（`URL.user` 是解码的） |
| 密码带保留字符 `p@ss:w/rd%`（地址里 `p%40ss%3Aw%2Frd%25`） | **正确密码也推不上**，见第 1 条 |
| 密码只含子分隔符和冒号 `a!$&'()*+,;=:b` | **也推不上**：Foundation 把密码里的第二个冒号编码成 %3A |
| 密码错 / 用户名错 | **狂连**，见第 2 条 |
| 只写用户名 / 不写 | 干净失败（noCredential → requestFailed） |

四个毛病（问题单 `reports/issues/W5D-w4-release-haishinkit-rtmp-authenticator.md`）：
1. **算错含转义字符的密码**：`RTMPAuthenticator` 用 `url.password`。Foundation 里 `URL.user` 解码、`URL.password` **不解码**（urlprobe：`rtmp://p%40b:s%3Acr%2Ft@…` → user `p@b`、password `s%3Acr%2Ft`；`URL(string:)` 还会把手敲的 @ 空格 中文 和密码里的第二个 `:` 自动编码）。能用的密码只剩 `[A-Za-z0-9-._~!$&'()*+,;=]`。
2. **密码 / 用户名错时在 connect() 里狂连**：authfailed / nosuchuser 的描述也带 `authmod=adobe`，它又从第 2 轮来、地址越拼越长，**不看 Task 取消**。网关回话前等 0 / 20 / 100 ms（模拟往返）：2 次 / **12.8 s 430 次** / **42.6 s 380 次**，探针给的 30 s 限时拦不住。StreamOutput 的 `withTimeout` 要等子任务结束才返回，所以连接超时拦不住、`stop()` 被拖住——**直接把 userinfo 交给它，输错一次密码就是对服务器连几百次、停推流卡几十秒**。
3. **被拒后递归 connect 与旧连接收尾的竞态**：旧连接的收包循环随后调 `close()`，会关掉新 socket（第 2 条的循环也是撞上它才停）；理论上还能卡死在 continuation 没登记的窗口里。
4. **needauth 分支强制解包** `url.user!` / `url.password!` / `salt!`：地址没写账号、服务器又回 needauth 就崩。

**4. SRT passphrase 对照**（authprobe 的 SRT 模式对 MediaMTX `srtPublishPassphrase`）：

| | RTMP / RTMPS 的 user:pass@（Adobe） | SRT 的 `?passphrase=` |
|---|---|---|
| 写在哪 | 地址 userinfo；StreamDestination 保留到 connectURL（本会话） | 地址查询串；StreamDestination 的 SRT 分支原样（没动） |
| 上线吗 | 不上线：服务器给 salt / challenge，客户端回 MD5 应答（拿到一次往返能离线猜弱密码）；媒体不加密，要加密得 RTMPS | 不上线：libsrt 用 PBKDF2 派生密钥、握手里交换包好的 AES 会话密钥；**媒体整路 AES 加密** |
| 不对时 | 服务器回 Rejected + reason=authfailed / nosuchuser | 握手被拒：MediaMTX 日志 `invalid passphrase` / `passphrase not provided by client`，HaishinKit `failedToConnect(peer)` |
| 本机实测 | 见第 3 点 | 字母数字的正确 passphrase 连上；错的 / 没给的被拒 |
| 坑 | HaishinKit 的 `URL.password` 不解码（第 1 条） | **同一类坑**：HaishinKit `SRTSocketURL` 手切查询串、值不解码就交给 libsrt，转义过的 `pass%20word%261%3D2Z` 被当成字面值 → `invalid passphrase`（问题单 `W5D-w2-stream-srt-passphrase-reserved-chars.md`，SRT 分支按 prompt 不动） |

### 1.2 怎么做的：user:pass@ 留在地址里，Adobe 前两轮我们自己做，HaishinKit 只拿不带 userinfo 的地址

选法：直接交给 HaishinKit 有第 1–3 条（尤其第 2 条，输错密码就是事故）；fork / 给 HaishinKit 打补丁要动 Package.swift 和依赖策略（W4-B 的事，也不在本会话的目录里）；所以在 `Sources/Streaming/` 里绕开——它看不到 userinfo，`RTMPAuthenticator` 在 authfailed / nosuchuser 时只会抛 noCredential、不会重连（第 2、3 条不再触发），算应答用我们解码后的密码（第 1 条）。根上的修法写进问题单给 W4-B（上游补丁之后可以删掉 RTMPAdobeAuth）。

| 交付 | 落点 | 说明 |
|---|---|---|
| 1 保留 user / password、转义一次 | `StreamDestination.swift` | RTMP / RTMPS 的 `connectURL` 带上 user:pass@：先解码再交给 URLComponents 编码 = **只转义一次**（已转义的不会成 `%2540`；手敲的 @ 空格 中文转一次；字面 `%` 成 `%25`；子分隔符原样）。新增 `credentials`（解码后的用户名 / 密码，只写用户名时密码为空串）和 `connectURLWithoutCredentials`。查询串改成 `percentEncodedQuery` 原样带（原来解码再编码会把 `%26` 变成 `&`，"流名 / 查询串不变"）。解析失败的错误里带打过码的地址（App 会把错误原文 NSLog 并显示）。SRT 分支不动。 |
| Adobe 前两轮 | `RTMPAdobeAuth.swift`（新） | 一个只会"简单握手 + connect + 读到 txid 1 的回复"的最小 RTMP 客户端（Network.framework，rtmps 走 TLS；收包按 RTMP 规范处理 fmt 0–3、扩展时间戳、Set Chunk Size、多块流交错）。第 1 轮不带参数：被接受 → 服务器 connect 阶段不要鉴权（MediaMTX 也是），原地址交给 HaishinKit；回 authmod=adobe → 第 2 轮报用户名拿 salt / challenge / opaque（nosuchuser → 直接报"用户名不对"）；用**解码后的**用户名密码按 ffmpeg 同一公式算应答，拼 `authmod=adobe&user=…&challenge=…&response=…&opaque=…`（有原查询串就用 & 接，app / tcUrl 都带，同 ffmpeg）交给 HaishinKit 连第三轮。服务器要 llnw → 报"不支持"。**不是 Adobe 那套 / 我们的最小客户端没看懂 / 超时 → 退回改之前的做法**（不带 userinfo 的原地址交给 HaishinKit），所以对不做 Adobe 的服务器不会比改之前差。超时和 Task 取消都是 cancel 掉连接，1 s 内返回。connect 字段与 FMLE / ffmpeg 发布端一样（app、type=nonprivate、flashVer=HaishinKit 的、tcUrl）。 |
| 接到传输层 | `HaishinKitTransport.swift` | `RTMPTransport.connect()`：交给 `RTMPConnection.connect` 的永远是 `connectURLWithoutCredentials`（或它 + 第三轮参数）；地址有 credentials 才先跑 `RTMPAdobeAuth`。服务器拒绝时错误写成 "鉴权失败（用户名或密码不对）：<code> <description>" 或 "<code> <description>"，不再是整个 RTMPResponse 的 dump。 |
| 2 脱敏 | `StreamURLRedaction.swift`（新，public）、`App/Sources/Release/ShowRedaction.swift` | 一份口径给日志 / 错误 / 诊断包：userinfo 整段换成 `<redacted>`（authority 里最后一个 @ 之前；解析不了的地址保守地到整串最后一个 @），查询串里 `passphrase key token password secret streamid auth user pass pwd response` 的值换成标记，scheme / 主机 / 端口 / 路径保留。`redact(text:)` 处理一段文字里的每个地址。ShowRedaction 的 url 打码改为调用它（名单从 App 挪到推流包，多了 `response`：Adobe 应答配上 salt 能离线猜密码）。 |
| 日志里不打印带 userinfo 的地址 | `HaishinKitTransport.swift`、`StreamDestination.swift` | 推流包自己从不打印 connectURL（`StreamDestination.description` 本来就是 `rtmp://host:port/…`）；会带地址进日志的只有错误文字——HaishinKit 的 `unsupportedCommand(地址)`、SRT 的 `unsupportedUri(地址)`、我们的 `invalidURL(地址)`——RTMP / SRT 的连接错误和解析错误进 `StreamTransportError` / 日志前都过 `StreamURLRedaction.redact(text:)`。HaishinKit 自己的日志（Logboard，info 级）只打连接状态，不打地址；trace 级会打整条 connect 命令（app 带查询串），别在正式包里开。 |
| 3 推流页"鉴权…" | — | 归 95（W5-I），本会话没碰界面。地址里写了就生效（Adobe 服务器），见 §5 给 95 的话。 |
| 测试工装 | `Tests/StreamingTests/AdobeAuthGateway.swift`（新）、`MediaMTXSupport.swift` | AdobeAuthGateway：独立实现的 Adobe 服务器端（CryptoKit 算 MD5、自己解 AMF0，与 RTMPAdobeAuth 不共享代码），回话前先发 Window Ack / Set Peer Bandwidth / Set Chunk Size 4096（跟真服务器一样），可调回话延迟模拟往返；没有上游时验过回 Success，有上游时把 connect 的 Adobe 参数换成 MediaMTX 的 `user=&pass=` 转过去。`MediaMTXInstance` 加 `extraConfig`（接在 scripts/mediamtx.yml 后面的 YAML，开鉴权用；scripts/ 不在本会话目录，没改）。 |

### 1.3 越界发现（问题单，没改）

| 问题单 | 归属 | 严重级 |
|---|---|---|
| `W5D-w5-app-bottom-bar-stream-tooltip-shows-credentials.md`：底栏推流按钮的悬停提示原样显示地址（`BottomBarView.swift:159`），现在含明文密码 | W5-F（92）/ 止血归 W5-B | S2 |
| `W5D-w2-control-api-state-exposes-stream-credentials.md`：`GET /api/v1/state` / WS 全量状态原样带 streamKey 与 url | 控制会话；改字段走提案 | S2 |
| `W5D-w4-release-diagnostics-stream-key-in-url-path.md`：密钥写在地址路径里（rtmp://h/app/密钥）时原样进诊断包（ShowRedaction "路径保留"） | W4-B | S2 |
| `W5D-w2-stream-srt-passphrase-reserved-chars.md`：SRT passphrase / streamid 有要转义的字符就推不上 | 推流（W2-D 系） | S3 |
| `W5D-w4-release-haishinkit-rtmp-authenticator.md`：HaishinKit 的四个毛病，上游补丁 | W4-B | S3（已绕开，第 4 条残留） |

## 2. 每个测试：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'StreamingTests'`（debug；MediaMTX 端到端要 brew 的 mediamtx、ffmpeg 和 `swift build -c release --package-path Tools/frameprobe`，没有就 XCTSkip BLOCKED-工具）；
App：`make gen && make test-app`（或 xcodebuild `-only-testing:SwitcherTests/ReleaseTests`）。端口：MediaMTX 21950 / 28950 / 30050，网关 19461–19470。

| 测试 ID | 测试函数 | 数值 | 阈值 | 通过 |
|---|---|---|---|---|
| **指定 1** | `StreamDestinationTests.testE_streamDestination_keepsUserinfoInConnectURL` | `rtmp://u:p@live.example.com/app` + 密钥 → connect 地址 `rtmp://u:p@live.example.com/app`、发布名 = 密钥、1935；没有密钥时 `rtmp://u:p@h:1936/live/name?token=t&x=1` → `rtmp://u:p@h:1936/live?token=t&x=1` + 发布名 `name`；`?token=a%26b&x=1` 一个字节不变；RTMPS 同（443）；单段路径；只写用户名；`description` 不含 @；没写 userinfo 的照旧；SRT 原样 | 字符串全等 | ✅ |
| **指定 2** | `…testE_streamDestination_escapesReservedCharsOnce` | 已转义 `me%40example.com:p%40ss%3Aw%2Frd%25` 原样一次、URLComponents 解一次 = `p@ss:w/rd%`、不含 `%2540`；手敲 `p@ss w密` → `p%40ss%20w%E5%AF%86`；字面 `%41` → `%2541`；子分隔符 `a!$&'()*+,;=b` 原样；用户名里的冒号 → `%3A`、密码里的 → `%3A`，解出来是原文 | 全等 | ✅ |
| **指定 3** | `ReleaseTests.testRelease_redactionHidesURLUserinfo`（App） | 修前（旧 ShowRedaction）7 处断言红：`rtmp://u:p@…` 原样、节目 JSON 里原样有 `rtmp://Pub-User-5d1e:Pw-Secret-8c3a@ingest.example.com:1936/live`；修后 userinfo 整段（已转义的、没转义的 @、只有用户名的）→ `<redacted>`，主机端口路径保留，去密钥的节目仍能 `Show.load`、账号密码原文都不出现 | 全等 / 不出现 | ✅ |
| **端到端（指定）** | `StreamAuthMediaMTXTests.testE_streamAuth_adobeUserinfo_mediamtxAuth_10s_framesContinuous` | 地址 `rtmp://pub:p%40ss%3Aw%2Frd%25%20%E5%AF%86@网关/s1`，网关后面是开鉴权的 MediaMTX：送出 **600/600**、网络丢帧 0、重连 0、编码跳帧 0；落盘 **599 帧**（MediaMTX 录制器丢最后一帧，同 W2-D）、缺口 0、重复 0、不可解 0；网关正好 3 次 connect（要 adobe → 挑战 → 通过）；三次的字节里没有密码原文、也没有 `p%40ss`；tcUrl 不带 @ | 帧号连续 | ✅ |
| 端到端 | `…testE_streamAuth_mediamtxQueryCredentials_10s_framesContinuous` | `?user=mtxpub&pass=mtx-secret` 直推开鉴权的 MediaMTX：600/600、**599 帧**、0 / 0 / 0 | 帧号连续 | ✅ |
| 端到端 | `…testE_streamAuth_userinfoToServerWithoutConnectAuth_publishes` | MediaMTX 不开鉴权、地址带 user:pass@：第 1 轮被接受、HaishinKit 拿不带 userinfo 的地址；360/360、**359 帧**、0 / 0 / 0 | 帧号连续 | ✅ |
| 记录 | `…testE_streamAuth_mediamtxIgnoresUserinfo_documented` | 开鉴权、只写 user:pass@：6 s 内没进 publishing（MediaMTX 不认）、连接尝试 ≥ 1、`stop()` < 6 s | — | ✅ |
| 狂连回归 | `StreamAuthTests.testE_rtmpTransport_wrongPasswordFailsFastWithoutReconnectStorm` | 网关回话前等 20 ms、密码错：**1.10 s** 失败，错误 `鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected … reason=authfailed`；网关**正好 3 次** connect，之后 1 s 没有再连 | 对照 HaishinKit 自带：12.8 s 430 次 | ✅ |
| 狂连回归 | `…testE_streamOutput_wrongPassword_backsOffAndStopsPromptly` | 真编码器 + StreamOutput，密码错跑 2.5 s（按退避 1 s、2 s 重试）：网关的连接数 ≤ 3 × StreamOutput 的尝试次数、从没通过；`stop()` < 2 s | — | ✅ |
| 前两轮 | `…testE_rtmpAdobeAuth_negotiatesWithDecodedPassword` | 密码 `p@ss:w/rd% 密`：3 次 connect、第三轮 `NetConnection.Connect.Success`；三次字节里没有原文和 `p%40ss` | — | ✅ |
| 前两轮 | `…testE_rtmpAdobeAuth_appendsToExistingQuery` | `rtmp://…/live?foo=1&authmod=adobe&user=pub&challenge=…`；第 1 轮的 app 是 `live?foo=1` | — | ✅ |
| 前两轮 | `…testE_rtmpAdobeAuth_noSuchUserFailsAtSecondRound` | 2 次 connect 后 `badCredentials` | — | ✅ |
| 前两轮 | `…testE_rtmpAdobeAuth_cancellationReturnsPromptly` | 服务器 30 s 不回话：取消后 **0.31 s** 返回 | < 1 s | ✅ |
| 公式 | `…testE_adobeResponse_matchesReferenceVector` | 与 Python hashlib 独立算的参考值一致（有 opaque / 只有 challenge / 非 ASCII 密码）；测试网关的另一份实现也一致 | 全等 | ✅ |
| 解析 | `…testE_adobeDescriptionParsing` | salt `Ab+/c==`、`o=` 原样不解码 | — | ✅ |
| 脱敏 | `…testE_streamURLRedaction_hidesUserinfoAndSecretParams` | userinfo 整段（含没转义的 @、解析不了的地址）、passphrase / token / user / response 打码；错误文字里的 RTMP / SRT 地址都打码 | — | ✅ |
| 脱敏 | `StreamDestinationTests.testE_streamDestination_errorsDoNotCarryUserinfo` | 解析失败 / scheme 不认的错误里没有密码 | — | ✅ |

**StreamingTests 全量**（50 个用例：原有 34 + 本会话 16）。这台机器同时有 4 个 W5 会话在跑（转场守卫 W5-E、目视 W5-A、直播安全 W5-B、音频总线 W5-C），三遍的结果和原因都写在这：

| 哪一遍 | 时间 | 结果 | 红的原因（证据） |
|---|---|---|---|
| 全量第 1 遍 | 17:03–17:11 | 45 / 50 | **并行会话撞端口**：W5-E（worktree w5-core-transition-guard-e2ff9a）17:05–17:15 也在跑 StreamingTests，MediaMTX / 代理端口是写死的（21935…、31950…）。E9 `bind/listen 31950: errno 48`；RTMP e2e 与 W2D2-RTMP 的 MediaMTX 日志里有不认识的连接 `closing existing publisher` 把我们踢掉（落盘 3 个 / 2 个文件）；E8 `没有录制文件`（第二个 MediaMTX 绑不上端口，就绪检查被对方的 API 应答，流推进了对方的实例）；ThrottleProxyTests 同理。本会话新加的用例端口不重（21950 / 30050 / 1946x–19470），全过 |
| 全量第 2 遍 | 17:30–17:44 | **49 / 50** | E7：第 1、3 路网络丢帧 0，但第 3 路编码器 E1 跳帧 29（用例自己的说明：喂帧线程被卡过，不是网络问题）；那一分钟另一个会话的 App xcodebuild 正在编译（17:38 起、占满核）。没有外来的 StreamingTests（后台每 10 s 查一次进程） |
| E7 单独重跑 | 17:46 | ✅ | 第 1、3 路 3600 / 3600、网络丢帧 0、落盘 3599 帧 0 缺口；第 2 路放开后 2.02 s 重连 |

App：`xcodebuild … test -only-testing:SwitcherTests/ReleaseTests` → **6 / 6**（R7 真导出诊断包、R8 原有期望、R9、R10、W4-D 改名、新用例）；App 全量没跑（只改了 ShowRedaction，调用它的只有 DiagnosticBundle，R7 覆盖；这次构建把 App 全部 target 都编过了）。
`make lint BRANCH=w5-stream-auth`：禁词 / 版本号 / Package.swift / 依赖方向（8 个包）/ 归属（16 个改动文件，加上本报告 17 个）/ 链接（163 个 Markdown）/ RT 符号，全过。

E7 / E8 / E9 / RTMP e2e / W2D2 的地址都不带 userinfo，走的是和改之前一样的路（`connectURLWithoutCredentials` = 原来的 `connectURL`）。**结论：每个用例在最终代码上都至少通过了一遍；没能在一台没人用的机器上拿到一遍完整的 50 / 50**——G6 合入时请在安静的机器上整跑一遍。

## 3. 没做的和原因

1. **推流页"鉴权…"输入框**：归 95（W5-I），本会话不碰界面。给它的话见 §5。
2. **没对真的 Adobe 鉴权服务器（Wowza / FMS / Nimble / 要鉴权的 CDN 入口）推过**：本机只有我写的 AdobeAuthGateway。它和 RTMPAdobeAuth 不共享代码（各自解 AMF0、各自算 MD5），公式另有一份 Python hashlib 算的参考值钉住（testE_adobeResponse_matchesReferenceVector），
   回话格式按 ffmpeg rtmpproto.c / HaishinKit RTMPAuthenticator 解析的样子写——但终归是"我理解的服务器"。解锁：有 Wowza（试用版即可）/ Nimble 的人在推流页填 rtmp://用户:密码@主机/应用 推一次，服务器日志里应是三次连接（要 adobe → 发挑战 → 通过）。
3. **RTMPS 的前两轮没有端到端测过**：本机没有带受信证书的 RTMPS 服务器（MediaMTX 能开 rtmps，但自签证书我们的客户端和 HaishinKit 都会按系统信任拒掉）。代码路径是 `NWParameters.tls`（系统信任 + SNI），与 HaishinKit 的 RTMPS 同一套。解锁：mkcert 装本机信任的证书 + MediaMTX `rtmpEncryption` + 网关加 TLS，或真的 RTMPS + Adobe 入口。
4. **llnw（Limelight）鉴权**：HaishinKit 也没有；服务器要它时报"鉴权方式不支持"。现在还用它的入口很少，要的话照 Adobe 那样在 RTMPAdobeAuth 里加一种（按协议自己写，不抄 GPL 代码）。
5. **没把 user:pass@ 自动换成 MediaMTX 式的 ?user=&pass=**：那等于对每个服务器都把密码明文放进 connect 命令；MediaMTX / SRS / nginx-rtmp 这类自建服务器按它们自己的规矩写查询串就行（MediaMTX 的已测，§2）。要不要在 95 的对话框里给"写进查询串"这个选项，由 95 / 用户定。
6. **密码错时 StreamOutput 仍按退避一直重试**（每次尝试 3 个连接，间隔 1、2、4…≤ 30 s）：没有改成"鉴权失败就停"。行为变了要和 W5-B / W5-N（状态面板）一起定；现在的错误文字已经能区分（§5 第 3 条）。
7. **HaishinKit 第 4 条毛病的残口**（第三轮服务器回 needauth 时它强制解包崩溃）：只在挑战过期这种少见情况下发生，要在 HaishinKit 里修，问题单给 W4-B。
8. 越界发现写成 5 张问题单（§1.3），都没改。

## 4. 对契约的疑问

没改契约。`StreamSettings` 仍只有 `url` / `streamKey`：账号密码放在 url 的 userinfo 里（95 写回 url），推流包解析，不需要新字段。两个以后可能要提案的点：
- 如果想让"用户名 / 密码"成为独立字段（界面好打码、API 和诊断包好整段去掉），要改 `StreamSettings`（Show JSON 字段）——走 docs/contract-changes/。现在的做法不需要。
- 控制 API 的全量状态原样带推流密钥和 url（问题单 `W5D-w2-control-api-state-exposes-stream-credentials.md`）：如果改成在 API 里打码，`MixerState` 在 API 里的形态就变了，也要提案。

## 5. 下一个会话需要知道的坑

1. **HaishinKit 永远不能拿到带 userinfo 的地址**。`RTMPTransport` 交给 `RTMPConnection.connect` 的是 `connectURLWithoutCredentials`（或它 + 第三轮参数）。以后谁顺手改成 `destination.connectURL`，输错一次密码就是几百次重连、`stop()` 卡几十秒——`StreamAuthTests.testE_rtmpTransport_wrongPasswordFailsFastWithoutReconnectStorm` 会红。HaishinKit 上游修好之前别删 RTMPAdobeAuth。
2. **Foundation 的 userinfo**：`URL.user` 解码、`URL.password` 不解码；`URL(string:)` 会自动编码手敲的 @ 空格 中文，以及密码里的第二个 `:`。要原文用 `URLComponents.user / .password` 或 `URL.password(percentEncoded: false)`；推流包里用 `StreamDestination.credentials`。
3. **给 95（W5-I）"鉴权…"**：
   - 写回 url 用 `URLComponents` 的 `user` / `password` setter（自动只转义一次），别手拼；读出来用 `StreamDestination(settings:).credentials`。
   - 文案说清用途：这是 Adobe（FMLE 兼容）鉴权，Wowza / Nimble / FMS 和一部分 CDN 入口用；MediaMTX / SRS / nginx-rtmp 一类自建服务器要的是地址后面的查询串（MediaMTX：`?user=…&pass=…`），填在"鉴权…"里对它们没用——我们这边不会报错（connect 第 1 轮就被接受，退回不带账号连），会在 publish 时被服务器拒（`NetStream.Publish.Unauthorized`）。
   - 地址框里会显示 user:pass@：建议打码显示；底栏悬停提示原样显示地址（问题单）。
   - 错误文字：密码错 → `鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected … reason=authfailed`；用户名错 → `鉴权失败：用户名不对（服务器回 nosuchuser）`；要 llnw → `鉴权方式不支持：…`。状态面板（101 W5-N）可以直接显示 `StreamOutput` 打的那行。
   - SRT 的 passphrase 只用字母数字和 - . _ ~（问题单），对话框里可以提示。
4. **MediaMTX 连上后约 3 s 才认出两轨开始录**（之前的帧照样从头录进去）：端到端测试推不到 3 s 就停，它一个文件都不写（本会话 2 s 的用例因此改成 6 s）。
5. **MediaMTX 开鉴权**要给本机匿名 `api` 权限，不然 `MediaMTXInstance` 等 API 起来会超时（`StreamAuthMediaMTXTests.authConfig`）。它对鉴权失败故意拖 2.5 s 才回，HaishinKit 的 publish 有时先 requestTimedOut。
6. **`StreamURLRedaction.secretQueryParams` 是日志和诊断包共用的一份**，加名字两边都生效；`user` 在名单里，日志里的 `?user=…` 也打码（排障时看不到用户名是故意的）。诊断包那份原来在 `ShowRedaction.secretQueryParams`，已删掉、改为直接调用推流包的。
7. **AdobeAuthGateway**：回话前发 Set Chunk Size 4096（客户端要按它拆块）；验过之后转上游时不发这些（否则客户端对上游块大小的理解会乱）。HaishinKit 的握手要 S0S1S2 一次到齐（它等 S2 的头几个字节到了才发 C2），网关是一次写完的。
8. HaishinKit 的日志（Logboard，info 级）打到 stdout，只有连接状态；trace 级会打整条 connect 命令（app 里有查询串，MediaMTX 式的 `pass=` 就在里面），别在正式包里开。
9. 本会话的端口：网关 19461–19470，MediaMTX 21950 / 28950 / 30050；探针用过的 19350 / 18890 / 19997、18891 / 19998 已关。
10. **几个会话同时跑 StreamingTests 会互相打架**：MediaMTX / 代理端口是写死的（21935…、31935…、41002…），输出目录 `$TMPDIR/switcher-streaming-tests/<用例>` 也是共用的，而 `startInstances` 开头先 `removeItem` 掉它——后起的 MediaMTX 绑不上端口、就绪检查被别人的 API 应答、流推进别人的实例，录制目录还会被对方删掉。本会话第 1 遍 5 个红就是这么来的（§2）。要么错开跑（G6 / 合入前），要么以后给端口和输出目录加进程号偏移（输出目录已经能用 `SWITCHER_TEST_OUTPUT` 改，端口还不行）。
