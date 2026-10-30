# W2-D5 推流与录制：Adobe 鉴权 AMF 嵌套上限、脱敏的编码参数名与路径发布名、录制首块音频晚到补静音 —— 报告（分支 w2-stream-5）

日期 2026-10-30 / 31。prompt 132（G11 2026-10-24 排进 128 前；Codex 10-24 网络安全审计 NS04 / NS12 / NS09 + 10-22 审查 N10）。
机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.1（27A9275）/ Swift 6.4 / MediaMTX 1.21.0（brew）/ ffmpeg 9.0.1（brew）/ HaishinKit 2.2.5，接电源（AC，电池 95%）。
worktree `.claude/worktrees/w2-stream-5-d650d6`，分支 `claude/w2-stream-5-d650d6`（桌面端起的名），从 `main` = bf149e2（G11 第二次快进后）开；
**`w2-stream-5` 指向同一个 HEAD**（`git branch -f w2-stream-5 HEAD`，同 W2-D4 先例），`make lint BRANCH=w2-stream-5` 和 G12 合并都用它。
提交 `git log main..w2-stream-5`：NS04 → NS12 / NS09 → NS09 续（安全审查指出的末尾空白）→ N10 → 第 5 条 last_error → 两张新问题单 → 本报告。
动的文件全在 prompt 给的范围里：`Packages/SwitcherOutputs/Sources/Streaming/` 5 个（RTMPAdobeAuth / HaishinKitTransport / StreamURLRedaction / StreamOutput + 新 TransportErrorText）、
`Packages/SwitcherOutputs/Tests/StreamingTests/` 6 个（新 AMF0LimitTests / HostileRTMPServer / StreamURLRedactionTests / TransportErrorTextTests，AdobeAuthGateway 几个小工具改 internal、StreamAuthTests 两条旧期望）、
`Recorder.swift`（只动首块锚定那一段，+7 行）、`Tests/SwitcherOutputsTests/RecorderFirstAudioTests.swift`（新）、`App/Sources/Release/ShowRedaction.swift`、`App/Tests/ReleaseTests.swift`、
`reports/issues/` 两张新单 + W4C4 那张补"处理结果"、本报告。契约、别的包、docs/、HaishinKit、Package.swift 一个字没动。

## 1. 做了什么

### 1.1 NS04：Adobe 鉴权的 AMF0 解析加上限，超上限不再退回交给 HaishinKit

- **复现（修前）**：照 Codex C06-server.py 写了 Swift 版恶意服务端 `StreamingTests/HostileRTMPServer`（握手、读 connect、回 Set Chunk Size 4096 + 一条任意载荷的命令，4096 分块）。
  `_result`(1, null, N 层单元素严格数组)：**debug 构建 100 层走"服务器拒绝"分支、1000 层起 SIGBUS**（signal 10；审计用的是生产 .o，10 万层才崩——Swift 并发的协作线程栈小、debug 帧大）。
  单元用例里 10 万层在主线程上（8 MB 栈）同样把进程打崩。
- **改**（`RTMPAdobeAuth.swift` 的 `RTMPConnectCommand.Reader`）：`value()` 是唯一入口（深度 0），递归走 `value(depth:)`；进容器（对象 0x03 / ECMA 数组 0x08 / 严格数组 0x0A / 类型对象 0x10）
  时深度 + 1，**第 33 层容器就拒**（`maxNestingDepth = 32`，空的也拒——数的是容器层数）→ `Failure.protocolError("AMF0 嵌套过深")`；一条回复**最多 1 万个值**（`maxElements`，每个值算一个，
  名字 / txid 也算）→ `protocolError("AMF0 元素过多")`。取 prompt 建议的 32 / 1 万：真实 `_result` 最深的是状态对象里的 `data`（ECMA 数组），2 层。
- **探针的附带发现 → 传输层也改了**：HaishinKit 2.2.5 自己的 `AMF0Serializer.deserialize` 同样递归无上限（它自己 `RTMPConnection.connect` 也是 **1000 层 SIGBUS**），
  而 `RTMPTransport.connect` 在我们报 `protocolError` 之后原来会把不带 userinfo 的地址**退回交给 HaishinKit 连**——同一个服务器回同样的东西，进程照样没了。
  所以"嵌套过深 / 元素过多"这两种改报 `connectFailed("RTMP 协议错误：AMF0 嵌套过深")`（StreamOutput 照旧退避重试，每次先过我们的解析），**不再退回**；
  别的 protocolError（类型不认、越界……）照旧退回。临时去掉这个分支，传输层用例就是进程崩溃（验过）。
- **没修的那半边**：不带账号的 RTMP 直接走 HaishinKit，它的解析器还能被打崩；带账号的在 Adobe 鉴权通过之后，连接本身也是 HaishinKit 的。要改 HaishinKit（W4-B），
  写了问题单 `reports/issues/W2D5-w4-release-haishinkit-amf0-unbounded-recursion.md`，留一条 BLOCKED-SDK 用例等它。
- RTMPS 共用 `RTMPConnectProbe` / `RTMPConnectCommand.reply`（只是连接换 TLS），按 prompt 靠解析器单元用例覆盖，没另搭 TLS 服务器。

### 1.2 NS12：脱敏按解码后的参数名比名单

`StreamURLRedaction.redactQuery`：参数名先 `removingPercentEncoding`（解不开按原文）再小写比 `secretQueryParams`；打码只换值，参数名和不打码的项照原文留着。
App 地址框的还原（`StreamAddress.unmaskedQuery`）按原文参数名配对、只看值是不是记号，`pa%73s=•••` 照样换回原值，不受影响（App 侧没有依赖旧行为的用例，查过）。

### 1.3 NS09：诊断包在密钥栏空时遮住 RTMP 地址末段的发布名

- `StreamURLRedaction.redact(url:marker:publishNameInPath:)`（新参数默认 false）：true 且协议是 rtmp / rtmps（不分大小写）、路径 ≥ 2 段 → 最后一段换成标记。
  **拆法跟 StreamDestination 一致**：它对**去掉首尾空白之后**的地址用 `URLComponents.path`（解码后）以 / 拆、空段不算——所以 `%2F` 也是分隔；这里在原文上找"含最后一个解码段的那个原文段"
  整段换掉（`a%2Fb` 整段算，只多盖、不漏），后面解码出来全是 / 的原文段跳过；userinfo 先换成标记再拆路径（密码里没转义的 / 已经不在了）。
- `ShowRedaction.redact(json:)`：处理一个字典时看同层的 `streamKey`（不分大小写），**是空的（只有空白也算，StreamDestination 先去空白）**就给 url 传 true；
  没有同层 streamKey 的 url（不是推流设置）不动路径。日志 / 错误文字 / 地址框 / 底栏悬停照旧默认 false。
- **安全审查补的一处**：提交后自动安全审查指出 `rtmp://h/live/KEY/ `（末尾 / 加空白或换行）时 StreamDestination 先 trim、认 KEY 是发布名，而第一版在原文上拆、把末尾空白当成最后一段——
  KEY 照样泄露。改成路径只到"去掉首尾空白后的内容末尾"（空白按 `CharacterSet.whitespacesAndNewlines`，与 trim 同一套），并加了**差分用例**：
  5 种开头 × 17 种路径 × 11 种结尾 = 935 种写法逐条交给 StreamDestination，它认出发布名的 880 种在结果里原文、解码后都不剩；对第一版红 555 处。

### 1.4 N10：录制首块音频晚于起点时先补前导静音再锚定

`Recorder.drainAudio` 首块（`!audioAnchored`）原来只处理"早于起点要裁"；现在 `blockStartNs > originNs` 先
`appendSilence(frames: round((blockStartNs − originNs) × 48000 / 1e9))`，受停止边界限制（`min(…, (stopNs − originNs) × rate / 1e9)`，同漂移分支的写法），再锚定。
不算漂移校正（`audioCorrections` 不加；之后的块按样本数正好接上，漂移 ≈ 0）。**首块整块越过停止边界**的照旧在前面那句 `blockStartNs >= stopNs` 只计越界、不写、也不补静音——
与"边界已知时入口直接丢"的同一块结果一致（补到边界的话两条路结果就不一样了）；这种情况音轨里一个样本都没有，ffprobe 正常、视频照常。Recorder 别的段没动。

### 1.5 第 5 条（有余力，S3）：last_error 里底层库的原样文字 → 中文概括，原文进日志

先探（铁律 10）——macOS 27 / HaishinKit 2.2.5 上常见失败实际抛的：端口没人听 `socketErrorOccurred(Optional(POSIXErrorCode(rawValue: 61): Connection refused))`（0.01 s）、
域名解析不了 `socketErrorOccurred(Optional(-65554: NoSuchRecord))`（0.02 s）、SRT 没人听 `failedToConnect(SRTHaishinKit.SRTRejectReason.timeout)`（3.0 s），原样进 last_error。
新增 `TransportErrorText`：认得的给一句中文（连接被拒 / 找不到主机 / 超时 / 网络不通 / 被重置 / 断开 / TLS / 请求超时 / SRT 拒绝原因），认不出的"未知错误"，
原文（打过码）记一条 notice（`switcher.streaming` / `Transport`）。服务器回了状态的照留状态码与描述，前面加"服务器拒绝连接：" / "发布被拒："（原来 publish 阶段是英文 `publish: `、
没状态时 `connect 无状态`）；鉴权失败那句不变（App 的 StreamWiringTests 按它断言，不是我能动的文件）。顺手改了一处说错的：地址里写了账号、只是 Adobe 前两轮退回了，
原来照搬 credentialsRequired 的"地址里没写"，现在"服务器还要 Adobe 鉴权（这次前两轮没走完，稍后重试）"。
**文字表和要文档会话（W4-C5）跟的几处**写在 `reports/issues/W4C4-w2-stream-last-error-raw-texts.md` 末尾（docs/api/README.md §6、docs/user/输出.md、docs/user/en/outputs.md 的"最后错误"那条
现在还写着"开始推的阶段前面带 `publish: `""例如 `连接失败：publish: requestTimedOut`"）。CONTRACTS.md 的口径（"连接失败：<原因>……或传输层回的那一句"）不用改。

### 1.6 新发现（没修，等用户定）：对端接受 TCP 但不说话时，推流一直卡在"连接中"、停不掉

给第 5 条做探针时撞到：本机只 listen 不回话的端口，`rtmp://` 连上之后 **StreamOutput 一直 `connecting(1)`（3 s 连接超时不起作用）、`stop()` 20 s 不返回**；
传输层单测 `withTimeout(4) { connect() }` 25 s 不返回，rtmps 拖到 15 s。原因：HaishinKit 的 connect 把续体存起来等服务器回握手，握手没有超时、也不理外层取消
（它的 `close()` 才会结束那个续体）；我们的 `withTimeout` 用任务组，超时之后要等 body 子任务结束；stop 等发送 Task。App 里这一路停不掉也起不来、换节目 / 退出白等 10 s 兜底并泄漏。
不在 prompt 132 的范围，写了 `reports/issues/W2D5-w2-stream-connect-hangs-on-silent-server.md`（建议 S1，附原因、改法、探针）；改法都在 Streaming/ 里，要不要在本分支顺手修等用户定。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`swift test --package-path Packages/SwitcherOutputs --filter '<Target>.<Class>'`（debug）；App：`make gen` 后
`xcodebuild -project Switcher.xcodeproj -scheme Switcher -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test-without-building -only-testing:SwitcherTests/ReleaseTests`。
"红"一列是先写用例、实现之前那一遍的实跑结果（解析器 / 脱敏 / Recorder 先只加常量或空参数让它编过，再跑）。阈值：prompt 给的（32 / 1 万、24000 ± 1）照用，别的是本会话为新用例定的断言，不是测试标准的阈值。

| 测试 | 数值（绿） | 红（实现前） | 阈值 / 断言 | 通过 |
|---|---|---|---|---|
| `AMF0LimitTests.testNS04_reply_nestingDepthLimit` | 32 层（严格数组 / 对象）照旧解析；33 层四种容器、第三 / 第四个值两个位置、第 33 层是空数组都报 `AMF0 嵌套过深`；10 万层严格数组 / 对象各一次，合计 < 0.07 s | 33 层全部"没抛错"，10 万层在主线程 SIGBUS（进程崩） | 32 过 33 拒；超上限 < 1 s | ✅ |
| `AMF0LimitTests.testNS04_reply_elementBudget` | 正好 1 万个值过、1 万零 1 个拒（`AMF0 元素过多`）；1 万多个键的对象拒；16 MB 的 null 在预算处停（< 1 s）；声称 40 亿元素只有两字节 → `AMF0 越界` | 三处"没抛错"，16 MB 的 null 解了 1.98 s | 1 万；< 1 s | ✅ |
| `AMF0LimitTests.testNS04_reply_realRepliesStillParse` | 测试网关拼的 `_result` / `_error`、Wowza 风格（状态对象带 data、命令对象嵌 4 层）照旧；onBWDone → nil | 绿（守护） | 照旧 | ✅ |
| `AMF0LimitTests.testNS04_adobeAuth_deepReplyOverLoopback_protocolErrorAndProcessSurvives` | 本机回环 100 / 1000 / 10 万层 → `RTMP 协议错误：AMF0 嵌套过深`，三次合计 0.03 s，服务器各只见 1 条连接 | 进程崩（1000 层起 SIGBUS） | 协议错误、< 3 s、进程在 | ✅ |
| `AMF0LimitTests.testNS04_adobeAuth_fourLevelSuccessOverLoopback_stillAccepted` | 第 1 轮回 Success（命令对象嵌 4 层）→ authorize 原样返回地址 | 绿（守护） | 照旧 | ✅ |
| `AMF0LimitTests.testNS04_rtmpTransport_deepReply_failsWithoutHaishinKitFallback` | 带账号的 RTMPTransport 推到回 10 万层的服务器 → `connectFailed("RTMP 协议错误：AMF0 嵌套过深")`，0.36 s，服务器只见我们那 1 条连接 | 进程崩；只修解析器、不改退回 → HaishinKit 把进程打崩 | 不退回 HaishinKit、进程在 | ✅ |
| `AMF0LimitTests.testNS04_haishinKitOwnParser_deepReply` | XCTSkip **BLOCKED-SDK**（HaishinKit 2.2.5 的 AMF0 解析递归无上限；探针 1000 层 SIGBUS）；解锁 = W4-B 给 HaishinKit 打补丁 / 升级，去掉 guard | — | — | ⏭ |
| `StreamURLRedactionTests.testNS12_encodedSecretParamNamesAreRedacted` | pass / pa%73s / %70ass / PASS / Pa%53s / %50%41%53%53 / pass%77ord / %74oken / stream%69d 都打码，`?user=alice&pa%73s=x` 输出里没有 x，非密钥项（含编码）原样，`pa%zzs` 不崩，文字 / 地址框记号同 | 7 种编码写法不打码、`=x` 原样 | 都打码 | ✅ |
| `StreamURLRedactionTests.testNS09_publishNameInPathRedacted` | rtmp / rtmps / 大写协议 / 末尾 / / 空段 / 首尾空白 / 末尾 / 加空白或换行 / 制表符 / 解析不了的 userinfo / %2F 三种 → 末段打码；只有一段、没路径、SRT、不是地址、默认 false → 路径不动 | 末段全部原样 | 见左 | ✅ |
| `StreamURLRedactionTests.testNS09_publishNameMatchesStreamDestinationSplit` | 6 种写法逐条对 StreamDestination 的 streamName：结果里原文、解码后都不剩，主机和 app 在 | 6 种都泄露 | 同左 | ✅ |
| `StreamURLRedactionTests.testNS09_publishNameRedaction_differentialAgainstStreamDestination` | 935 种写法里 StreamDestination 认出发布名的 880 种全部遮住 | 对第一版（没去末尾空白）红 555 处 | > 400 种、0 泄露 | ✅ |
| `RecorderFirstAudioTests.testN10_lateFirstAudioKeepsTimestamp`（Codex 的 `Audit20261022RecorderTests` 搬来改名，喂法照旧） | 解码首个非零样本 **24000**，`audioCorrections` 0，音轨 48064 | 首个非零样本 **0**，`audioCorrections` 1，音轨 48063 | 24000 ± 1 | ✅ |
| `RecorderFirstAudioTests.testN10_lateFirstAudioKeepsTimestamp_aac` | 首个响样本 23999 | 0 | 24000 ± 1024（一个 AAC 帧） | ✅ |
| `RecorderFirstAudioTests.testN10_singleLateBlockOnly` | 首个非零 24000，音轨 / audioFrames 24256 | 0；256 | 24000 ± 1；24256 ± 1 | ✅ |
| `RecorderFirstAudioTests.testN10_lateFirstBlockStraddlingStop_paddedAndTrimmedToBoundary` | 首个非零 47952，音轨 48000，越界 208 | 0；音轨 48 | 47952 ± 1；48000 ± 1 | ✅ |
| `RecorderFirstAudioTests.testN10_earlyFirstAudioStillTrimmedToOrigin` | 起点前 100 个样本裁掉，0.6 在 11932，音轨 48000 | 绿（守护） | 11932 ± 1 | ✅ |
| `RecorderFirstAudioTests.testN10_firstAudioBlockBeyondStop` | audioFrames 0、越界 256、视频 60 帧 1 s、ffprobe 正常 | 绿（守护） | 不补静音 | ✅ |
| `TransportErrorTextTests.testW4C4_summaryOfCommonErrors` | 21 种错误 → 中文概括（表见问题单） | 全是程序写法 | 等于表 | ✅ |
| `TransportErrorTextTests.testW4C4_serverStatusTexts` | `发布被拒：…` / `服务器拒绝连接：…`（地址打码）/ 鉴权那句不变 / `发布：服务器没回（请求超时）` | `publish: …`、原样 | 等于期望 | ✅ |
| `TransportErrorTextTests.testW4C4_connectFailuresArePlainChinese` | 真连：没人听的端口（带 / 不带账号）`连接被拒（…）`、`.invalid` 域名 `找不到主机（域名解析失败）`、SRT `SRT 连接超时（服务器没回）` | 原样 socketErrorOccurred / failedToConnect | 等于期望、无程序写法 | ✅ |
| `TransportErrorTextTests.testW4C4_streamOutputLastErrorIsPlainChinese` | `连接失败：连接被拒（这个地址和端口上没有服务器在听）` | `连接失败：socketErrorOccurred(Optional(POSIXErrorCode(…` | 等于期望 | ✅ |
| App `ReleaseTests.testR7_diagnosticBundleContainsRequiredFilesWithoutSecrets`（补"整条地址 + 密钥栏空"与"密钥栏非空、两段路径"两路） | zip 里所有文本文件都没有路径密钥；show JSON 里那一路 = `rtmp://127.0.0.1:1935/live/<redacted>`、密钥栏仍空；密钥栏非空那一路 `…/live/sub` 原样 | show.switcher.json 泄露路径密钥（只有它，日志里没有） | 0 泄露 | ✅ 2.3 s |
| App `ReleaseTests.testNS09_showRedactionHidesPublishNameInPathWhenKeyEmpty` | 6 路：空 / 空白密钥栏的末段打码，非空 / 一段 / SRT / 非推流设置的 url 路径原样，6 个密钥都不剩 | 3 个路径密钥泄露 | 0 泄露 | ✅ |
| App `ReleaseTests.testNS12_showRedactionHidesEncodedSecretParamNames` | `pa%73s` / `%70ass` / `PASS` 都打码，节目 JSON 里没有密码 | 绿——红那一遍只撤了 ShowRedaction，推流包的修复已经在了，所以这条没红过 | 0 泄露 | ✅ |
| App `ReleaseTests` 其余（R8 / R9 / R10 / redactionHidesURLUserinfo / W4D） | 照旧 | — | — | ✅ |
| 整包 `swift test --package-path Packages/SwitcherOutputs`（debug，2026-10-31 00:35–01:02，同机没有别的测试在跑） | 6 个 target 共 178 条：**161 过、16 跳、1 红**。VirtualCamera 19（跳 1）、SwitcherOutputsTests 35、StreamingTests 77（跳 10、红 1）、NDISend 17（跳 2）、ISO 15（跳 1）、External 15（跳 2）。**红的那条 = `StreamingTests.ThrottleProxyTests.testBlockStopsForwardingAndCloses`**（测试工装自测，已知间歇红：问题单 W1E2-w2-stream-throttle-proxy-close-flaky、KNOWN_ISSUES 测试与工具那节，P5-2 / W3-C3 / G8 都撞过；工装和用例本分支都没动；单独复跑 3 次：过 / 过 / 红） | — | 0 新红 | ✅（1 条已知间歇红） |
| 上面跳过的 10 条补跑：新 worktree 没编 release 版 frameprobe（BLOCKED-工具）。`swift build -c release --package-path Tools/frameprobe` 之后单独跑 `MediaMTXTests` / `StreamAuthMediaMTXTests` / `ISOAlignmentTests`（MediaMTX 1.21.0，01:06–01:19） | **14 条全过**：MediaMTXTests 8（E2E3 68 s、E7 78 s、E8 171 s、E9 337 s、RTMP / SRT 端到端、W2D2 两条）、StreamAuthMediaMTXTests 5（含查询串密码错第一次就停）、ISO A4 1；剩下 6 条跳的是 BLOCKED-签名 1、BLOCKED-硬件 2、BLOCKED-SDK 1（本会话 NS04 的 HaishinKit 那条）、NDI 按环境跳 2 | — | 照旧 | ✅ |
| `make lint BRANCH=w2-stream-5` | lint-rules（禁词 / 版本号 / Package.swift）、check-deps（8 个包）、check-ownership（18 个改动文件都在允许范围；报告提交后 19 个）、check-help、check-links（215 个 Markdown）、check-rt-symbols 全过，退出码 0 | — | 0 | ✅ |

## 3. 没做的和原因

1. **HaishinKit 自己的 AMF0 解析**（不带账号的 RTMP、鉴权之后的连接）：要改 HaishinKit，prompt 写明"HaishinKit 升级（W4-B）"不做；问题单 W2D5-w4-release-haishinkit-amf0-unbounded-recursion + BLOCKED-SDK 用例。
2. **对端不说话时推流卡死**（§1.6）：新发现，不在范围；问题单 W2D5-w2-stream-connect-hangs-on-silent-server，等用户定修不修、谁修。
3. RTMPS 没另搭 TLS 服务器做端到端（prompt 说靠单元测试）。
4. 别处显示推流地址的口径没动（不是我的文件 / 不在 prompt 里）：底栏推流按钮的悬停提示（`App/Sources/UI/BottomBarView.swift:493`）用默认的 `redact(url:)`，
   **密钥栏空、密钥写在地址末段时悬停会显示密钥**（屏幕共享时可见）；API 状态的 url 打码是 131 W2-C5（提案 035）的事——两处要遮发布名都可以看同层 streamKey 传 `publishNameInPath: true`。
5. 最小客户端分块重组没有内存预算（每个块流最多攒到 24 位长度上限 16 MB）：只随实际收到的字节涨、受鉴权超时限制，不是放大，没动。
6. App 那条 NS12 用例没有"先红"（见 §2）。

## 4. 对契约的疑问

没有要改的。`StreamURLRedaction.redact(url:marker:publishNameInPath:)` 是推流包（SwitcherStreaming）的公开函数，不是 SwitcherContracts；last_error 只改了文字内容（字段名不变），
CONTRACTS.md 对它的口径"连接失败：<原因>（如"连接超时""没连上"或传输层回的那一句）"仍然对。

## 5. 下一个会话需要知道的坑

- **debug 构建 1000 层就 SIGBUS**（我们的解析器和 HaishinKit 都是）：异步代码跑在 Swift 并发的协作线程上，栈小、debug 帧大；审计用生产 .o 是 10 万层。测 AMF 深度别只试 100 层。
- **HaishinKit 的 connect 不理取消**，`withTimeout`（任务组）会陪着挂住——别指望外层超时 / cancel 能把它带出来，只有 `RTMPConnection.close()` 能结束挂着的续体（§1.6、问题单）。
  写"连上了 TCP 但对端不说话"的用例：只 `listen` 不 `accept` 的端口就行（内核替它完成三次握手）。
- **卡死类探针跑完要查 `ps` 清残留**：`perl -e 'alarm …'` 看门狗只杀得掉 `swift test`，挂住的 xctest 子进程被过继给 launchd 接着挂（本会话撞到一个挂了 40 分钟的，PID 只能按命令行认）。
- 新 worktree 跑 Outputs 整包前先 `swift build -c release --package-path Tools/frameprobe`，不然 MediaMTX 端到端 9 条 + ISO A4 全按 BLOCKED-工具跳过（G5 记过；整包照样"绿"，容易漏看）。
- 恶意 / 定制回复的 RTMP 服务器：`StreamingTests/HostileRTMPServer`（`reply: (txid) -> 载荷`，有严格数组 / 对象的深嵌套生成器）。AMF0LimitTests 用 19471–19476、TransportErrorTextTests 用 19495–19497，别撞。
- 脱敏的"路径末段"必须和 StreamDestination 同一个拆法：它先 **trim 首尾空白**再按**解码后的**路径拆（%2F 也分段）——在原文上拆很容易差一点，改了跑一遍差分用例。
- ffmpeg 把立体声下混成单声道是两路各乘 1/√2 再加：两声道同值 0.6 解出来是 0.85（判"有没有声音"的阈值别设在 0.8）。
- Recorder 的音频块在 writer 建好之前留在环里（容量 256 块）；**块被处理时边界知不知道取决于 writer 队列排得快慢**：Codex 那条（先喂视频再送音频再停）总长是 48000 还是 48064
  看时序（Codex 实跑 47999、这里 48063，修前），所以那条只断言首样本位置；要卡边界就"先送音频、setStopTick、再喂视频"（RecorderFirstAudioTests 的 audioBeforeVideo）。
- 首块的前导静音不计 `audioCorrections`；首块整块越过边界不补静音、音轨为空（ffprobe 正常）。
- `swift test --filter 'StreamingTests.(A|B|C)'`（带括号的正则交替）一次跑几个类能用，本会话实测一次 43 条。
- 新 worktree 跑 App 用例前先 `make gen`；`xcodebuild … build-for-testing` 首次几分钟，之后增量编 + `test-without-building -only-testing:SwitcherTests/ReleaseTests` 都很快（R7 本身 2–3 s）。
- 提交信息里有中文引号，走 `git commit -F -`（heredoc），别用 -m（G11 的坑）。
- G12 销号：KNOWN_ISSUES 的 S2（NS04）——我们的解析器那半边销，HaishinKit 那半边换成新问题单；S3（NS12）销；S2"推流凭据外泄两处"的 ③（NS09）销（② 看 131）；
  S1（N10）销；S3"推流 last_error 仍有底层库的原样文字"销（文档跟 W4-C5）；新增两行（§1.6 卡死、HaishinKit AMF0）等用户定级。
