# W2-D4 推流鉴权失败就停、要有提示 —— 报告（分支 w2-stream-4）

日期 2026-10-12。prompt 111（用户 2026-10-12 定"要，而且要有提示"）。机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.0（27A266a）/ Swift 6.4 /
MediaMTX 1.21.0（brew）/ ffmpeg 9.0.1（brew）/ HaishinKit 2.2.5（dc880cb），接电源（AC，电池 95%）。
worktree `.claude/worktrees/w2-stream-auth-stop-f35a11`，分支 `claude/w2-stream-auth-stop-f35a11`（桌面端自动起的名），从 `main`（22ff4d9，G8b 续之后）开；
**`w2-stream-4` 指向同一个 HEAD**（`git branch -f w2-stream-4 HEAD`，同 W5-D / W2-C3 先例），`make lint BRANCH=w2-stream-4` 和 G9 合并都用它。
提交：`git log main..w2-stream-4`（推流包红 → App 红 → 绿 → 一处补漏（红 → 绿）→ App 用例补两句 → 报告与问题单）。动的文件：`Packages/SwitcherOutputs/Sources/Streaming/` 5 个
（StreamTransport / StreamCounters / StreamOutput / HaishinKitTransport / RTMPAdobeAuth）、`Packages/SwitcherOutputs/Tests/StreamingTests/` 5 个（TestSupport / StreamOutputTests / StreamAuthTests /
StreamAuthMediaMTXTests + 新工装 PublishRejectServer）、App 合计 **+42 / −3 = 45 行**（≤ 50；`OutputRuntime.swift` 12、两份 `Localizable.strings` 各 1 行、
`App/Tests/StreamWiringTests.swift` 一条用例 26 行、`App/Tests/TestSupport.swift` 的 MediaMTXHarness 加一个 `environment` 参数 5 行）、
`reports/issues/W2D4-w4-docs-3-stream-auth-stops.md`、本报告。契约、别的包、docs/、HaishinKit、Package.swift 一个字没动。

## 1. 做了什么

### 1.1 先探（铁律 10）：MediaMTX 的查询串鉴权失败怎么回、什么时候回；HaishinKit 接不接得住

探针在 scratchpad（不入库）：StreamingTests 里临时加的 `ZZProbeTests`（直接用 HaishinKit 的 `RTMPConnection` / `RTMPStream` 连开了鉴权的 MediaMTX，
跑完删掉）、`mtxenv/`（MediaMTX 用环境变量开鉴权 + ffmpeg 推）；MediaMTX 源码从 GitHub v1.21.0 读（MIT，只读不抄）。

| 场景（MediaMTX 1.21 `authMethod: internal`，地址 `rtmp://127.0.0.1:端口/s1` + 查询串，发布名空——RTMPTransport 的真实形态） | HaishinKit 2.2.5 看到的 | 耗时（publish 发出到回复） |
|---|---|---|
| `?user=mtxpub&pass=wrong`（8 次） | publish 抛 `RTMPStream.Error.requestFailed`：level `error`、code **`NetStream.Publish.Unauthorized`**、description **`authentication failed`**；随后 MediaMTX 断开（0.5 s 后 `connected = false`） | 1.34 / 2.00 / 2.31 / 1.39 / 1.35 / 0.89 / 1.86 / 2.80 s |
| `?user=nobody&pass=x` | 同上 | 0.90 s |
| 不给账号（2 次） | 第 1 次同上（2.87 s）；**第 2 次 publish 先抛 `requestTimedOut`（3.005 s）**——MediaMTX 日志里它约 4 s 后才写回复（`write: broken pipe`） | 2.87 s / > 3 s |
| `?user=mtxpub&pass=mtx-secret` | `NetStream.Publish.Start` | 0.006 s |

- **为什么时快时慢**：MediaMTX 鉴权失败先等一段**随机时间**再回（`internal/auth/log_and_delay_error.go`：`minPause = 0`、`maxPause = 4 s`，crypto/rand 均匀取），防暴力猜密码。
  HaishinKit 的请求超时固定 `RTMPConnection.defaultRequestTimeout = 3000 ms`（publish 用同一个）——**约四分之一的鉴权失败会先被 HaishinKit 当成超时**，
  拿不到 `Unauthorized`（W5-D 报告 §5 第 5 条"HaishinKit 的 publish 有时先 requestTimedOut"就是这个）。只认"publish 回了 Unauthorized"的话，第一次就停做不到确定。
- **接得住**：`RTMPStream.status` 是一条无界缓冲的 `AsyncStream<RTMPStatus>`，每条 onStatus（不管 publish 的 continuation 是否已经超时收场）都会 yield 进去。
  所以 publish 之前先订阅，超时之后接着从这里等那条迟到的回复（总时长仍由 StreamOutput 的连接超时 5 s 管）。推流期间服务器几乎不再发 onStatus，留着不读也攒不下几条。
  注意 `status` 的 getter 每次新建一条流、替换掉上一条的 continuation：**整个对象只能有一个订阅者**（我们只在 connect 里订阅一次）。
- **附带发现（"应用 + 密钥"写法的 3 s）**：发布名非空时 RTMPTransport 给 `RTMPStream` 设了 `fcPublishName`（FMLE 序列），HaishinKit 的 connect 要等 releaseStream / FCPublish 的回复，
  MediaMTX 两个都不回 → **每次 connect 先白等 3 s**（探针第一版 3.0–3.1 s）。加上 MediaMTX 随机 0–4 s，publish 回复有约一半概率落在 5 s 连接超时之外（见 §3 第 3 条）。
- **MediaMTX 能只用环境变量开鉴权**：`MTX_AUTHINTERNALUSERS_0_USER / _PASS / _PERMISSIONS_0_ACTION=publish`、`MTX_AUTHINTERNALUSERS_1_USER=any / _IPS=127.0.0.1 / _PERMISSIONS_0_ACTION=api`
  （ffmpeg：错的 / 没给 → `Server error: authentication failed`，对的 → 推上；本机 API 200）。App 用例靠它，不用另写配置文件。

### 1.2 交付

| 交付 | 落点 | 说明 |
|---|---|---|
| 1 类型化的鉴权失败原因 | `StreamTransport.swift` | 新 `StreamAuthFailure`（`badCredentials` / `noSuchUser` / `publishUnauthorized` / `credentialsRequired` / `unsupportedMethod`，带 `summary`："鉴权失败（用户名或密码不对）"等）；`StreamTransportError` 加 `authenticationFailed(StreamAuthFailure, message:)`，message = "鉴权失败（…）：<服务器回的状态码与描述>"（打码、不带密码）。 |
| 传输层认出来 | `HaishinKitTransport.swift`、`RTMPAdobeAuth.swift` | 只看协议字段：`RTMPTransport.authFailure(code:description:)`——`NetStream.Publish.Unauthorized` → publishUnauthorized；`NetConnection.Connect.Rejected` + 描述里 `reason=authfailed` / `nosuchuser` → badCredentials / noSuchUser，`authmod=llnw` → unsupportedMethod，只有 `authmod=adobe` 没有 reason（服务器要账号、地址里没写）→ credentialsRequired；别的 → nil（照旧 connectFailed）。Adobe 前两轮（RTMPAdobeAuth）的 nosuchuser / authfailed / llnw 直接带类型抛（`Failure.badCredentials(StreamAuthFailure, 服务器原文)`）。HaishinKit 的 `RTMPConnection.Error.requestFailed` 与 `RTMPStream.Error.requestFailed` 都走 `transportError` → `error(code:description:phase:)`，原来的 `describe` 只认前一种（publish 被拒时 last_error 是整个 `RTMPResponse` 的 dump）。**publish 先订阅状态流、`requestTimedOut` 之后接着等迟到的回复**（§1.1）。 |
| StreamOutput 第一次就停 | `StreamOutput.swift`、`StreamCounters.swift` | `connect` 抛 `authenticationFailed` → `failed(message)`、不退避，`last_error = message`，新 `failure: StreamFailure?` = `.authentication(原因)`（超过尝试次数 = `.retriesExhausted`，start 清）；`Stats.encoder[].attempt` 在 failed 时本来就是 0。别的错误（连不上 / 断线 / 停滞）照旧退避。 |
| failed 之后的收尾 | `StreamOutput.swift` | ① **收帧的门**：停在 failed 后不再收帧 / 音频块（原来编码器照收，`droppedNotAccepting` 记进 droppedDisconnected，丢帧计数按帧率涨——原来只有设了 maxAttempts 才会走到 failed，App 不设，所以没人碰到过）；② 会话已关时编码器里出来的几帧 / 几包按"连上过没有"记（没连上过 = `videoBeforeStart` / `audioBeforeStart`，不算网络丢帧）；③ failed 之后 `stop()` 收尾成 **stopped**（原来留在 `stopping`：发布循环已经退出，beginStop 置的 stopping 没人改回来）；④ `start()` 清 `failure`、开门，改对之后重新 start 照常连。 |
| 3 App 提示（≤ 50 行） | `App/Sources/Engine/OutputRuntime.swift`、两份 strings | `noteStats`：Stats 报 failed、且推流对象的 `failure` 是 `.authentication` → 状态行 `notice.streamAuthFailed`"推流 %d 鉴权失败（用户名或密码不对），已停止：在推流页改对后点底栏「推流」重试"一次（英文 "Stream %d authentication failed (wrong user name or password) and stopped: fix it on the Streaming page, then click “Stream” in the bottom bar to retry"）；不支持的鉴权方式（改密码没用）写原因（`failureReason` 那句"推流 n 不再重连：…"）。**核对时补的一行**：`EncoderStatsSource` 的推流项原来用 `StreamCounters.statsEntry`，**不带 022 的 `last_error` / `uptime_s`**——状态面板事件"失败：原因"只剩"失败"、底栏 / 工具条的推流时长恒为 00:00:00（W5-N 的用例喂的是合成 Stats，没碰到）；改用 `StreamOutput.statsEntry(counters:…)`。 |
| 核对底栏 / 状态面板 | — | 底栏：**深红**（severity error）✅，但字是"**推流 · 起不来**"而不是 prompt 写的"失败"（见 §4 第 1 条）；悬停"推流：起不来 — 推流 2 不再重连：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"+"点一下：重试起不来的路…"；点主体 = `retry` → 停掉这一路、按新设置起新对象。状态面板：状态"失败"、最后错误 = 原文、事件"推流 · 失败：鉴权失败（用户名或密码不对）：…" ✅（补了上面那一行之后）。 |
| 4 手册 | `reports/issues/W2D4-w4-docs-3-stream-auth-stops.md` | 给 109（W4-C3）：`输出.md:91/100/116/117`、`故障排查.md:55/58/59/60` 和英文对应行，逐条写了现在的行为与文字。 |

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter 'StreamingTests'`（debug；MediaMTX 端到端要 brew 的 mediamtx / ffmpeg 和 `swift build -c release --package-path Tools/frameprobe`，
没有就 XCTSkip BLOCKED-工具）；App：`make gen` 后 `xcodebuild … test -only-testing:SwitcherTests/…`。prompt 没给新的测试 ID，函数名沿用推流用例的 `testE_` / `testW2D4_` 前缀。
"红"一列是先写用例、实现之前那一遍的实跑结果（提交 133d58f / a929adc / 0dd3e4a 之前）。

| 测试 | 数值（绿） | 红（实现前） | 阈值 | 通过 |
|---|---|---|---|---|
| **交付 2（Adobe 密码错）** `StreamAuthTests.testE_streamOutput_adobeWrongPassword_failsFirstTimeNoRetry`（真编码器 + HaishinKit + AdobeAuthGateway） | ≈ 1 s 进 failed；之后照喂 10 s 帧：网关**正好 3 次**连接 `[要 adobe, 发挑战, authfailed]`、`connectAttempts` 1、`failure = .authentication(.badCredentials)`；Stats `state` failed、`attempt` 0、`dropped` 0；failed 之后收帧 0；`last_error` = `鉴权失败（用户名或密码不对）：NetConnection.Connect.Rejected [ AccessManager.Reject ] : [ authmod=adobe ] : ?reason=authfailed&opaque=…`，不含密码；`stop()` < 2 s、stopped | 5 s 时 `backoff(3, 4.0s)`，12 s 里 4 次尝试 = 12 个连接；`last_error` = `连接失败：connectFailed("鉴权失败（…）…")`；failed 之后收 552 帧 | 第一次就停、10 s 0 次重连 | ✅ 12.2 s |
| **交付 2（查询串密码错）** `StreamAuthMediaMTXTests.testE_streamAuth_mediamtxQueryWrongPassword_failsFirstTimeNoRetry`（开鉴权的 MediaMTX） | 1.94 s / 2.63 s（两遍）进 failed；之后照喂 10 s：`connectAttempts` 1、**MediaMTX 日志只有 1 个连接**；`failure = .authentication(.publishUnauthorized)`；Stats failed / `attempt` 0 / `dropped` 0；`last_error` = `鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed`；stopped；改对密码的新对象推上、`last_error` 空 | 6 s 时 `connecting(3)`，4 次尝试 / 4 个连接；`last_error` 是整个 `RTMPResponse` 的 dump；failed 之后收 459 帧 | 同上 | ✅ 15.6 s |
| `StreamAuthTests.testE_rtmpTransport_latePublishUnauthorizedStillAuthFailure`（PublishRejectServer，publish 后 3.5 s 才回） | `authenticationFailed(.publishUnauthorized, "鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed")`，3.53 s；1 个连接 1 次 publish | 3.04 s `connectFailed("publish: requestTimedOut")` | > 3.4 s 收到且认成鉴权失败 | ✅ |
| `StreamAuthTests.testE_rtmpStatus_classifiesAuthFailures` | 8 种状态 → 原因（authfailed / nosuchuser / Publish.Unauthorized / 只 authmod=adobe / llnw / 三种不是鉴权）+ 4 条转成的错误（鉴权类带原文、BadName → `publish: …`、文字里的地址打码） | 桩返回 nil：9 处断言红 | 全等 | ✅ |
| `StreamAuthTests.testE_rtmpTransport_adobeDemand_withoutCredentialsStops_withCredentialsFallbackRetries` | 没写账号 → `credentialsRequired`，文字 `鉴权失败（服务器要用户名和密码，地址里没写）：NetConnection.Connect.Rejected [ AccessManager.Reject ] : [ code=403 need auth; authmod=adobe ] : `；写了账号、前两轮超时退回 → `connectFailed`（含 authmod=adobe、不含密码） | 第二半被当成 credentialsRequired | 全等 | ✅ 2.6 s |
| `StreamOutputTests.testW2D4_authFailureFailsFirstTimeWithoutBackoff`（假传输层） | 1 个传输层、`connectAttempts` 1、已关；`failed(原文)`、`failure` 类型化；Stats failed / `last_error` 原文 / `attempt` 0 / `uptime_s` 0；failed 后照喂 1 s 收帧 / 收音频块不变、`networkDropped` 0；对照路（一般连接失败）≥ 3 次重试、不进 failed | 10 次尝试、`backoff(10, 0.4s)`、`last_error` = `连接失败：authenticationFailed(…)`、failed 后收 60 帧 / 43 包 | 第一次就停、别的错误照旧退避 | ✅ 1.2 s |
| `StreamOutputTests.testW2D4_stopAfterAuthFailureThenRestartConnects` | stop → **stopped**；`last_error` 留到下一次 start；再 start：`failure` nil、连上、`last_error` 空、照常送帧、共 2 个传输层 | 3 个传输层（按退避重试成功）、`last_error` 是 `连接失败：…` | 全等 | ✅ 0.8 s |
| **交付 3（App）** `StreamWiringTests.testStream_authFailedStopsWithStatusLineNotice` | 状态行 = `推流 2 鉴权失败（用户名或密码不对），已停止：在推流页改对后点底栏「推流」重试`；Stats 那一项 failed / `last_error` 原文 / `attempt` 0；状态面板事件 `推流 · 失败：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed`；底栏 severity error；只连 1 次 | 状态行停在"推流 2 连接中…"；Stats 的 `last_error` 是空串 | 全等 | ✅ 4.4 s |
| 现有鉴权用例 | `StreamAuthTests` 原 9 条、`StreamAuthMediaMTXTests` 原 4 条全过；`testE_streamOutput_wrongPassword_backsOffAndStopsPromptly`（名字是 W5-D 起的）照过：现在第一次就停，"网关连接数 ≤ 3 × 尝试次数"= 3 ≤ 3、`stop()` < 2 s；`testE_streamAuth_mediamtxIgnoresUserinfo_documented` 照过（MediaMTX 回 Unauthorized → 第一次就停，6 s 内没进 publishing、`stop()` < 6 s） | — | 照过 | ✅ |
| `ThrottleProxyTests`（KNOWN_ISSUES 的偶发红，先单独复跑） | 单独连跑 3 遍：`testBlockStopsForwardingAndCloses` 0.31 s ×3、`testRateLimitPaces` 8.1–8.2 s ×3，全绿；全量里也绿 | — | — | ✅ |
| **StreamingTests 全量** | **57 / 57**（原 50 + 新 7），862 s（11:44–11:59，P5-3 的 SwitcherOutputs 一段跑完之后、它在跑 SwitcherControl 时）；E2/E3 60 s、E7 三路封第 2 路 30 s、E8 十次重连、E9 70% 带宽 5 min、RTMP / SRT 端到端、W2D2 两条都过 | — | 0 失败 | ✅ |
| **App 全量** | xcresulttool：**245 = 241 过 + 4 跳 + 0 红**（G8b 是 244，多的 1 条是本会话的；跳过的 4 条照旧：键盘导航要用户开系统设置、空闲唤醒探针、内置摄像头 BLOCKED-权限、虚拟摄像头 BLOCKED-签名），12:10–12:17，别的 worktree 的 xcodebuild / 测试宿主都退了才开跑。顺带看到 `testStream_10sToLocalMediaMTX_framesContinuous` 打出来的推流 Stats 现在有 `uptimeS: 10.75`（原来 App 里恒为 0）；新用例打出底栏「推流 · 起不来」、面板事件 `["推流 · 连接中", "推流 · 失败：鉴权失败（用户名或密码不对）：NetStream.Publish.Unauthorized authentication failed"]` | — | 0 红 | ✅ |
| headless（同样用 `StreamOutput`） | `swift test --package-path Tools/switcher-headless` **16 / 16**（Contracts022FillTests 5 条照过：`StreamState.failed("x")` 等没改）；冒烟 `switcher-headless 0.1.0` | — | — | ✅ |
| `make lint BRANCH=w2-stream-4` | 禁词 / 版本号 / Package.swift / 依赖方向（8 个包）/ 归属 / check-help / check-links / RT 符号全过 | — | — | ✅ |

**运行记录（同机并行）**：这一轮同时在跑的有 P5-3（110，`make test` 六包 + App）、W1-A5（113，SwitcherTestKit）、W5-O（112，App 定向用例）。
推流用例与 P5-3 的 SwitcherOutputs 一段共用写死的 MediaMTX / 网关端口和 `$TMPDIR/switcher-streaming-tests`，本会话的 MediaMTX 用例与全量都等它那一段的 xctest 退出才跑；
只有 11:2x 跑 `StreamAuthTests`（网关端口 19461–19469，24 s）那一次可能和 P5-3 的 SwitcherOutputs xctest 开头重叠——本会话那一遍 13 / 13 绿；P5-3 那边如果 `StreamAuthTests` 有
`bind/listen … errno 48`，是这次重叠，不是代码问题。App 用例等别的 worktree 的 xcodebuild / 测试宿主都退了才跑（两个测试宿主同时开会互相抢焦点）。

## 3. 没做的和原因

1. **底栏写"起不来"不是"失败"**：prompt 交付 3 说底栏"本来就深红'失败'"。实测深红对、字是"推流 · 起不来"：`OutputButtonSummary.routeState` 先看运行表给的原因，
   `OutputRuntime.failureReason` 对停在 failed 的推流对象也返回原因（W5-B 这么做是为了让"点主体 = 重试起不来的路"把它算进去），于是显示 `output.state.startFailed`。
   要显示"失败"得改 `OutputButtonSummary`（不在本会话的四个 App 文件里），而让 `failureReason` 对它返回 nil 会把"点主体重试"变成"停全部"——没动，交 §4 第 1 条定。
2. **改对地址不会自动重试这一种**：W5-B 的"设置改对自动重试"只对运行表里"起不来"（没地址 / 地址不认 / 建不起来）的路生效；鉴权失败的推流对象还在 `streams` 表里，
   改地址不触发重启，要点底栏主体（提示原文就这么说）。prompt 写"App'设置改对自动重试'那条路不变"，按字面没扩展；要改对就自动重试，归 App 会话。
3. **"应用 + 密钥"写法推 MediaMTX 时不一定第一次就停**：HaishinKit 每次 connect 先白等 3 s（MediaMTX 不回 releaseStream / FCPublish，§1.1），再加 MediaMTX 随机 0–4 s，
   publish 的回复约一半落在 5 s 连接超时外——那一次按连接失败退避（1 s），下一次大概率认出来停下（期望约 2 次尝试）。MediaMTX 惯用的"只写路径、密钥留空"
   （仓库 `scripts/mediamtx.yml`、手册、用例都是这种）第一次就停。根上要么改 fcPublishName 的取舍（关流不等 Unpublish.Success 是当初选它的原因）、要么放宽连接超时——
   都改变别的推流行为 / 是阈值类的事，没做；记在 §5 第 2 条。
4. **服务器断开但不回状态的拒绝认不出**：nginx-rtmp 的 on_publish 回调拒绝、SRS 的 http hook 拒绝都是直接断开、不发 onStatus，没有类型化的信号，照旧按"连不上"退避。
   SRT 的 passphrase 不对（HaishinKit 只给 `failedToConnect(peer)`）同样照旧退避；SRT passphrase 转义按 prompt 不做（另一张问题单 W5D-w2-stream-srt-passphrase-reserved-chars）。
5. **没对真的 Adobe 服务器（Wowza / Nimble / FMS）验**：和 W5-D 一样只有本机的 AdobeAuthGateway（独立实现）和新的 PublishRejectServer。authfailed / nosuchuser 的描述格式按 ffmpeg / HaishinKit 的解析写。
6. **手册**：docs/ 不在本会话目录，问题单 `reports/issues/W2D4-w4-docs-3-stream-auth-stops.md` 给 109（W4-C3）。推流页编码详情的界面文案"重试间隔最长 n s（一直重试）"
   在鉴权失败时不再成立——那是 App 的另一个键，按"App 只做提示那一句"没改，写在同一张单的"顺带"里。
7. HaishinKit 升级（W4-B）、任何阈值：按 prompt 不做。

## 4. 对契约的疑问

没改契约。新类型 `StreamAuthFailure` / `StreamFailure`、`StreamTransportError.authenticationFailed`、`StreamOutput.failure` 都在推流包（SwitcherStreaming）里，不是 SwitcherContracts。
`Stats.encoder[]` 的字段没变：`state` 的 failed 本来就在取值表里；`last_error` / `uptime_s` 是 022 的字段——**App 跑的推流原来这两项一直是空 / 0**（`EncoderStatsSource` 没用
`StreamOutput.statsEntry`，headless 一直是对的），本会话补上之后 API / stats.jsonl 的读者会看到 App 里的推流也有原因和时长了。要你拍板的：

1. **底栏这一种写"起不来"还是"失败"**（§3 第 1 条）。状态面板那边写"失败"，两处不一致。我倾向改成"失败"（鉴权失败不是"起不来"，而且 prompt 也是这么期待的），
   改法在 `OutputButtonSummary.routeState`：运行表原因来自停在 failed 的推流对象时按 Stats 的 failed 显示——归 App 会话（112 W5-O 正在跑，或之后的 App 续做）。
2. **"服务器要账号、地址里没写"（credentialsRequired）也第一次就停**——prompt 列的四种里没有它，我按"再试也一样、重试白打服务器"归进来（文字单独写"鉴权失败（服务器要用户名和密码，地址里没写）"）；
   写了账号、只是我们的前两轮退回时不停（§1.2）。不想停的话删 `authFailure` 里那一行即可。
3. "应用 + 密钥"推 MediaMTX 不保证第一次就停（§3 第 3 条）能不能接受。

## 5. 下一个会话需要知道的坑

1. **MediaMTX 鉴权失败随机等 0–4 s 才回**，HaishinKit 的 publish 请求 3 s 超时。`RTMPTransport.connect` 在 publish **之前**订阅 `RTMPStream.status`，超时后接着等；
   `status` 的 getter 每次新建一条流、替换掉旧的 continuation——别在别处再读 `s.status`，否则这里收不到。测这条路用 `PublishRejectServer`（publish 后按设定延迟回 onStatus）。
2. **发布名非空（"应用 + 密钥"）时每次 connect 先白等 3 s**（fcPublishName → releaseStream / FCPublish 等回复，MediaMTX 不回）。本机 MediaMTX 用例、App 用例都用"只写路径、密钥留空"，
   别图省事用 `AppTest.streamOutput(number:url:)`（它带密钥 "k"），那样鉴权失败要等 3 + 0–4 s，可能超过 5 s 连接超时。
3. **App 的推流 Stats 现在带 `uptime_s` / `last_error`**：底栏 / 工具条的"● 推流 00:00:12"原来在 App 里恒为 00:00:00，现在会走；比标题的用例照 W5-N 的规矩用 `AppTest.isRunningTitle`。
4. **停在 failed 的 StreamOutput**：收帧的门关着（`consume` 直接返回）、编码器会话和音频线程还在，等 `stop()` 收；`stop()` 之后是 stopped（原来卡在 stopping）。
   会话关着时编码器吐出来的帧 / 包按"连上过没有"记（`countNotSent`），没连上过不算网络丢帧。App 的"重试"是停掉旧对象、按新设置起新对象，不是在旧对象上再 start。
5. **鉴权失败的文字现在统一是"鉴权失败（…）：<服务器原文>"**：Adobe 用户名错原来是"鉴权失败：用户名不对（服务器回 nosuchuser）"、要 llnw 原来是"鉴权方式不支持：…"，都改了
   （原文照留在冒号后面）。App 里没有按这些文字匹配的代码（查过）；手册引用的旧文字见问题单。
6. 端口：AdobeAuthGateway 新用 19467、19469，PublishRejectServer 19468；StreamAuthMediaMTXTests 新用例沿用 21950 / 28950 / 30050；App 用例用 MediaMTXHarness 默认的 23935 / 28893 / 29993 + `MTX_AUTHINTERNALUSERS_*`。
7. `swift test --filter 'StreamingTests.PolicyTests'` 什么也匹配不到：PolicyTests.swift 里的类叫 `ReconnectPolicyTests` / `StreamDestinationTests`。
8. 同机并行：本会话跑推流用例时 P5-3（110）在跑 `make test`，它的 SwitcherOutputs 一段和本会话的 StreamingTests 共用写死的端口与 `$TMPDIR/switcher-streaming-tests`（各自开头先删目录），
   本会话的 MediaMTX 用例与全量都等它那一段跑完才跑（§2 运行记录）。等别的会话的进程时，按进程参数里的 worktree 路径认（xctest / 测试宿主的可执行路径带 worktree），
   别靠 `swift-test` 进程的 cwd（本会话第一版等待脚本用 lsof 认 cwd，一次都没认出来）。

**给 G9（prompt 114）**：合入 `w2-stream-4`（`git log main..w2-stream-4`）。App 侧 5 个文件与 W5-O（112，`App/` 全目录）可能相邻改动：两份 `Localizable.strings` 在
`notice.streamConnecting` 前插了一行 `notice.streamAuthFailed`、`OutputRuntime.swift` 的 `StreamEntry` / `noteStats` / `EncoderStatsSource` 三处、`App/Tests/TestSupport.swift` 的
`MediaMTXHarness.init` 多一个 `environment` 参数（默认空，老调用不用改）、`StreamWiringTests.swift` 末尾一条用例。合入后 KNOWN_ISSUES 产品缺陷表"推流密码错了一直按退避重试"那行可以挪进已修
（手册那几处等 109 按问题单改）；§4 三条待你拍板。
