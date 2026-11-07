# W2-D6 推流：对端接受 TCP 但不说话时这一路卡在"连接中"、停不掉 —— 报告（分支 w2-stream-6）

日期 2026-11-07。prompt 138（G12 写的；问题单 reports/issues/W2D5-w2-stream-connect-hangs-on-silent-server.md，132 W2-D5 新发现）。
机器 Apple M5 Max / macOS 27.0.1（26A434）/ Xcode 27.2（27B52）/ Swift 6.4.2 / MediaMTX 1.21.0（brew）/ HaishinKit 2.2.5，接电源（AC，电池 100%）。
worktree `.claude/worktrees/w2-stream-timeout-handling-d94ad4`，分支 `claude/w2-stream-timeout-handling-d94ad4`（桌面端起的名），从 `main` = c7d441a（G12 快进后）开；
**`w2-stream-6` 指向同一个 HEAD**（`git branch -f w2-stream-6 HEAD`，同 W2-D4 / W2-D5 先例），`make lint BRANCH=w2-stream-6` 和 G13 合并都用它。
提交 `git log main..w2-stream-6`：红用例（带两个桩）→ 实现 → 问题单"处理结果" + 本报告。
动的文件全在 prompt 给的范围里：`Packages/SwitcherOutputs/Sources/Streaming/` 3 个（StreamOutput / HaishinKitTransport / StreamTransport）、
`Packages/SwitcherOutputs/Tests/StreamingTests/` 2 个（新 SilentServerTests；StreamOutputTests 一行，见 §2 末）、`reports/issues/` 那张单补"处理结果"、本报告。
HaishinKit、契约、App（OutputRuntime 的 10 s 兜底）、docs/、阈值一个字没动。

**开工前的环境事**：Xcode 已升到 27.2，Metal 工具链没装，整包 `swift build` 卡在 SwitcherRender 的 Compositor.metal。经用户同意跑了
`xcodebuild -downloadComponent MetalToolchain`（Metal Toolchain 27B47，839 MB，系统级，所有 worktree 共用）。同机别的会话撞到同样的错就是这个。

## 1. 做了什么

### 1.1 探针（铁律 10）：HaishinKit 2.2.5 的 close() 在各阶段管不管用

问题单说"HaishinKit 的 close 会结束挂着的 connect 续体"。先在只 listen 的端口上量了三种（探针没提交，放在会话 scratchpad 的 W2D6ProbeTests.swift，结论如下）：

| 场景 | close() 的结果 | connect 何时返回 |
|---|---|---|
| `rtmp://`，connect 起后 1 s 关（TCP 早连上、握手挂着，readyState = versionSent） | 正常关 | **立刻**（1.06 s），`requestFailed(NetConnection.Connect.Failed)` |
| `rtmps://`，1 s 关（TLS ClientHello 发出去没人回，socket 还在连） | **抛 invalidState、什么都不做** | **15.06 s**，`connectionTimedOut` |
| `rtmp://`，0 s 关（close 抢在 socket 连上之前） | 抛 invalidState、什么都不做 | **永远不回**（40 s 看门狗杀掉） |

原因（读 HaishinKit 源码）：`RTMPConnection.close()` 第一句 `guard readyState != .uninitialized else { throw invalidState }`，readyState 要等 socket 连上、发 C0C1 时才变；
`RTMPSocket` 的连接超时是写死的 `timeout: UInt64 = 15`——**`RTMPConnection(timeout:)` 根本没传给 socket**（问题单里"只管 TCP 连接那一步"不对，它谁都不管）。
所以问题单建议 1"超时时先 close 再抛"对明文 RTMP 够，**对 RTMPS 不够**（要 15 s），还有一个"close 落在 socket 起来之前就永远挂"的竞态。

### 1.2 改法

1. **`withTimeout(seconds:onTimeout:_:)`**（StreamOutput.swift 末尾）：计时子任务到点抛私有哨兵 `TimeoutElapsed`（和 body 自己抛的 connectTimedOut 分开），
   接住后先 `group.cancelAll()`、再 `await onTimeout?()`、然后抛 `StreamTransportError.connectTimedOut`。仍是任务组（结构化，等 body 结束才返回），
   所以 body 要么理取消、要么理 onTimeout。StreamOutput 传 `{ await transport.close() }`。
2. **`RTMPTransport.connect` 能被取消也能被 close() 打断**（HaishinKitTransport.swift）：
   - 整个连接过程（建流 → Adobe 鉴权 → HaishinKit connect → publish → 等迟到的 publish 回复）放进一个子 Task（`connectSteps`），`connect()` 等它；
     调用方被取消（withTimeout 的 cancelAll）、别的 Task 调 `close()`，都转成取消这个子 Task。Adobe 鉴权、等迟到回复的状态流本来就理取消。
   - **HaishinKit 那一次 `connection.connect` 放进一个能"放手"的 Task**（`haishinKitConnect` + `HaishinKitConnectCall`）：结果经一个只用一次的交接对象交回来；
     等的那一方被取消就立刻抛 CancellationError 返回、不等它；那个 Task 交给收尾 `closeUntilReturned`：每 0.2 s `connection.close()` 一次，
     直到 HaishinKit 的 connect 自己返回（明文 RTMP 第一次关就回；RTMPS 在 TLS 阶段关不掉，等它自己 15 s 的 socket 超时），晚到的成功也关掉作废；
     30 s 还没回就记一条错误日志不再管（只剩 HaishinKit 自己的一个竞态会这样，见 §5）。`RTMPTransport.pendingHaishinKitConnects` 记着还没返回的个数，用例看它回 0。
   - `stream` 挪进锁（`Lifecycle`：closed / connecting / stream）：close 现在会和 connect / send 并发。connect 进行中被 close → 抛 `connectFailed("传输层已关闭")`；
     publish 刚成功、close 已经来过 → 这条流不留。
   - **偏离 prompt 的地方**：prompt 说"仍是结构化并发、不漏 Task"。StreamOutput 这一层是（withTimeout 任务组、等 connect 返回），但 HaishinKit 那一次调用
     **必须**能放手——RTMPS 的 TLS 阶段它既不理取消也不理 close，结构化地等就是等 15 s，做不到"连接超时 + 1 s"。所以这一个调用是非结构化的，
     有界（最长 HaishinKit 自己的 15 s）、有人收尾、有计数可查。这是唯一的非结构化部分。
3. **`SRTTransport` 的 `stream` 同样进锁**：stop 的 close 现在可能和 SRT 的 connect 并发（原来只在发送 Task 里顺序调）。SRT 的 connect 有 libsrt 自己的超时（没人听 3 s 报错），没另做放手。
4. **StreamOutput 的 stop**：连接期间传输层放进 `connecting` 格子（`Mutex<(any StreamTransport)?>`）。发送 Task 放进格子时在同一把锁里看 `stopRequested`（已经在停就不连）；
   `beginStop()` 在置 `stopRequested` 之后从格子里拿走它、`Task { await transport.close() }`；发送 Task 连接这一步结束时从格子里拿回——拿不回 = stop 正在关它，
   不管连没连上都按停收尾（不发布、last_error 不写）。两边经同一把锁，总有一边看见对方。
   **没有 cancel 发送 Task**（prompt 给的另一条路）：查了 publishLoop——linger 的 `try? await Task.sleep` 在已取消的 Task 里立刻返回，HaishinKit 关连接是 forceCancel，
   内核发送缓冲里的尾巴会丢；waitWake 的计时 Task 也会乱。发布中的 stop 照旧走排空 + linger，格子那时是空的，不受影响。退避中的 stop 本来就由 sleepUnlessStopped 每 ≤ 100 ms 看一次。
5. **文字**：`StreamTransportError.connectTimedOut` 的描述从"连接超时"改成 **"连接超时（服务器没回）"**（prompt ②），last_error = "连接失败：连接超时（服务器没回）"，
   和 SRT 的"SRT 连接超时（服务器没回）"一个口径。G10 那条钉旧文字的断言跟着改了（§2 末）。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

跑法：`perl -e 'alarm N; exec @ARGV' swift test --skip-build --package-path Packages/SwitcherOutputs --filter 'StreamingTests.SilentServerTests'`（debug）；每条用例内部也有看门狗
（挂住的操作放在 detached Task / 后台线程、有限时等，超时就红，不陪着挂）；每次跑完 `ps -axo pid,etime,comm | awk '$3 ~ /xctest/'` 查孤儿——都没有。
"红"一列是先写用例、只加两个桩（withTimeout 的 onTimeout 参数不用、计数恒 0）让它编过的那一遍实跑：6 条 19 处红。阈值是 prompt 138 给的（超时 + 1 s、stop 2 s）。

| 测试 | 数值（绿） | 红（实现前） | 阈值 / 断言 | 通过 |
|---|---|---|---|---|
| ① `SilentServerTests.testW2D6_rtmpTransport_silentServer_connectTimesOutWithinTimeoutPlusOne` | 连接超时 3 s：`withTimeout(3, onTimeout: close)` **3.10 s**、只靠取消 **3.18 s**，都是 `connectTimedOut`"连接超时（服务器没回）"；HaishinKit 那一次 connect 关一次就回（计数 2 s 内回 0）；对端两条 TCP 都已关 | 两种都 12 s 看门狗到点没返回；对端 2 条连接还开着 | 超时 + 1 s 内（< 4.0 s、≥ 2.9 s） | ✅ |
| ① `…rtmpsTransport_silentServer_connectTimesOutWithinTimeoutPlusOne`（同一种端口，不另搭 TLS） | **3.16 s / 3.04 s**；被放手的 HaishinKit connect 在它 15 s 超时后收完（计数 17 s 内回 0），对端连接都已关 | 两种都 12 s 没返回（修前要 15 s） | 同上 | ✅ 18.3 s |
| ④ `…rtmpTransport_closeDuringConnect_bothReturnPromptly`（stop 的传输层那一半） | rtmp / rtmps × close 落在 0 s / 1 s：close **≤ 1 ms** 返回，connect 在 close 之后 **≤ 1 ms** 抛"传输层已关闭"；计数 17 s 内回 0，对端连接都已关 | rtmp 0 s、rtmps 0 s / 1 s 三种 connect 5 s 没返回（只有 rtmp 1 s 原来就管用）；对端 3 条还开着 | < 0.5 s（本会话定的断言） | ✅ 16.2 s |
| ② `…streamOutput_silentServer_backsOffWithChineseLastError`（生产路径：真 VT 编码器 + HaishinKit，连接超时 3 s） | connecting(1) → 3 s 后 **backoff(1, 1 s)**、last_error = **"连接失败：连接超时（服务器没回）"** → 第 2 次连接 → **backoff(2, 2 s)**；connectAttempts 2、reconnects 0；退避中 stop < 2 s、state = stopped；对端两条都已关 | 一直 `connecting(1)`、last_error 空、connectAttempts 1；退避中的 stop 5 s 没返回（其实是连接中） | 进退避、计数涨、中文 last_error | ✅ 9.3 s |
| ③ `…streamOutput_stopWhileConnecting_rtmp_returnsWithin2s`（同步 stop()，连接超时 5 s、stop 落在握手挂着的第 1.5 s） | stop() **0.001 s**；state = stopped、isRunning false、last_error 空（停不是错误）、connectAttempts 1；HaishinKit connect 2 s 内收完；对端连接已关 | 8 s 看门狗到点、state 停在 stopping | < 2 s | ✅ |
| ③ `…streamOutput_stopAsyncWhileConnecting_rtmps_returnsWithin2s`（App 用的 stopAsync()） | stopAsync() **0.002 s**；同上；HaishinKit 那一次在后台等满它的 15 s 收尾（计数 17 s 内回 0），之后对端连接已关 | 8 s 没返回、state = stopping | < 2 s | ✅ 16.9 s |
| 上面 6 条第二遍（整包回归里，12:28–12:44） | ① RTMP 3.16 / 3.19 s、RTMPS 3.20 / 3.13 s；④ 四种都 ≤ 1 ms；② 照样 backoff(1) → backoff(2)；③ stop() 0.001 s、stopAsync() 0.002 s | — | 同上 | ✅ |
| 回归：整包 `swift test --package-path Packages/SwitcherOutputs --skip 'MediaMTXTests\|StreamAuthMediaMTXTests'`（debug，12:28–12:44；同机另一个会话在跑 App 测试，MediaMTX 两类挪到后面单独跑，见下两行） | 6 个 target 共 **171 条：164 过、6 跳、1 红**。StreamingTests **70 / 70**（含新 6 条；StreamOutputTests 15、StreamAuthTests 13、AMF0LimitTests 6（跳 1 BLOCKED-SDK）、SendQueue 5、TransportErrorText 4、PCMBlockRing 4、StreamURLRedaction 4、ReconnectPolicy 2、ThrottleProxy 2），SwitcherOutputsTests 35、NDISend 17（跳 2）、ISO 15（A4 跑了）、External 15（跳 2 BLOCKED-硬件）、VirtualCamera 19（跳 1、**红 1**）。**红的那条 = `VirtualCameraTests.testOutput_noDevice_searchingRetriesAndDropsWithoutBlocking`：环境**——它枚举本机所有 CMIO 设备、断言"普通摄像头没有 sink 方向的流"，本机装着的一个第三方虚拟摄像头有 sink 流（`普通摄像头没有 sink 方向的流：<那个设备>`）；VirtualCamera 的代码和用例本分支都没碰 | — | 0 新红 | ✅（1 条环境红） |
| 回归：`StreamAuthMediaMTXTests`（MediaMTX 1.21.0，端口 21950 / 30050，不和 App 撞；12:57） | **5 / 5 过**：Adobe userinfo + MediaMTX 鉴权 10 s 帧连续、MediaMTX 不认 userinfo、查询串账号 10 s 帧连续、**查询串密码错第一次就停（111 的状态机）**、userinfo 推给不鉴权的服务器照常发布 | — | 照旧 | ✅ |
| 回归：`MediaMTXTests` 8 条（等另一个会话的 App 测试跑完、机器安静之后，13:01–13:13；release frameprobe 先编好） | **8 / 8 过**：RTMP / SRT 端到端、W2D2 两条、E2E3（E2 10 s 窗最大误差 0.14%）、**E7 第 1、3 路网络丢帧 0 / 0，第 2 路放开后 8.02 s 重连**（connectAttempts 5）、**E8 10 / 10，放开后 0.05–1.13 s**（断线判定 9.0–10.1 s）、E9 误差 0.00% | — | E7 / E8 ≤ 15 s（目标 5）；E9 ≤ 5% | ✅ |
| `make lint BRANCH=w2-stream-6` | lint-rules（禁词 / 版本号 / Package.swift）、check-deps（8 个包）、check-ownership（5 个已提交改动文件 + 工作区共 7 个都在允许范围）、check-help、check-links（224 个 Markdown）、check-rt-symbols 全过，退出码 0 | — | 0 | ✅ |

**E7 放开后的重连从 2.03 s 变成 8.02 s**（W2-D 报告里代理版 E7 是 2.03 s）：这是连接超时真正生效 + 指数退避的结果，不是回归——原来封住期间那一次连接一直挂到放开、
代理放开时把它关掉 → 退避 2 s → 连上；现在每 5 s 超时一次（connectAttempts 5），退避升到 4、8 s，放开时正在 8 s 的退避里。仍在 E8 的硬阈值 15 s 内，
但超过了"目标 5 s"；封得更久（> 约 45 s）时退避会到 16 s，放开后最坏要等完这一档。要不要为"连接超时"另定退避节奏（比如不升档或封顶更低）是策略 / 阈值的事，
本分支没动，交用户定。E8（每次封 10 s）放开时那次连接还挂着，和原来一样快。dummynet 版（SYN 被丢）本机没 sudo 没跑，预计同样变慢。

**改了一条旧用例的期望文字**：`StreamOutputTests.testG10_lastErrorIsPlainTextForConnectFailureAndDisconnect` 末尾钉着 `"\(StreamTransportError.connectTimedOut)" == "连接超时"`，
改成"连接超时（服务器没回）"——这是 prompt ② 要的文字变化，不是放宽断言；这条用例别的断言没动。

## 3. 没做的和原因

1. **HaishinKit 升级 / 打补丁**（W4-B）：`RTMPConnection(timeout:)` 没传给 socket、TLS 阶段 close 不起作用、下面那个竞态，根子都在它那里；按 prompt 不动。
   副作用：RTMPS 对端不回 TLS 时，**被放手的那一次 HaishinKit connect（和它的 socket）在后台最多再活 15 s**（我们这边已经报超时 / 停完了）。
   退避重试期间每次尝试都会这样，同一时刻最多两三个（3 s 超时 + 1、2、4… s 退避 vs 15 s）。
2. **publish 请求在途时 stop / 超时最多等 3 s**：HaishinKit 的 `RTMPStream.publish` 不理取消，有它自己 3 s 的请求超时；落在这一段的 stop 或连接超时要等它到点
   （有界，改之前也一样）。prompt ③ 的 2 s 针对的是握手挂着的那段，这段没另做放手。
3. **SRT 连接中的 stop**：SRT 的 connect 有 libsrt 自己的超时（没人听 3 s），stop 落在这段最多等它；close 能不能提前打断 SRT 的 connect 没探（不在范围，问题单里 SRT 正常）。
4. App（OutputRuntime 的 10 s 兜底）、NDI、阈值：按 prompt 不做。
5. 故障排查文档：不是我的目录，交文档会话（§5）。

## 4. 对契约的疑问

没有要改的。`withTimeout`、`StreamTransport.close()` 的文档注释、`RTMPTransport.pendingHaishinKitConnects` 都在推流包（SwitcherStreaming）里，不是 SwitcherContracts；
last_error 只改了文字内容（字段名不变）。CONTRACTS.md 的口径"连接失败：<原因>（如"连接超时""没连上"或传输层回的那一句）"仍然对（现在是"连接超时（服务器没回）"）；
SwitcherContracts/Stats.swift 第 131 行注释里的例子"连接失败：连接超时"是举例，没跟着改（不是我能动的文件，也不影响任何东西）。

## 5. 下一个会话需要知道的坑

- **给文档会话（W4-C5 / 135 之后的手册续做）**：故障排查里"推流一直'连接中'不动"那一条改成：**对端接了连接但不回话时，连接超时（App 默认 5 s）到点报
  "连接失败：连接超时（服务器没回）"、按退避（1、2、4… s，上限 = 重连上限）重试；连接中点停立刻停下**。输出页"最后错误"的例子 `连接失败：连接超时`
  换成 `连接失败：连接超时（服务器没回）`（docs/user/输出.md 第 128 行、docs/user/en/outputs.md 第 131 行、docs/api/README.md 第 130 行）。
- **给 G13（140）**：KNOWN_ISSUES 那行 S1"推流连'接 TCP 不说话'的对端时这一路卡死"可以销号（换节目 / 退出也不再等满 10 s 兜底：stopAsync 立刻回）；
  §3.1 的"RTMPS 被放手的 HaishinKit connect 后台再活最多 15 s"和 §5 末那个竞态如要记，归 W4-B（HaishinKit）。
- **HaishinKit 2.2.5 的 `RTMPConnection(timeout:)` 不管 socket**：RTMPSocket 的连接超时写死 15 s；它的 close() 在 socket 连上之前（readyState = uninitialized）抛 invalidState、什么都不做。
  别指望"超时时 close"在 TLS 阶段或 TCP 连上之前起作用——要么放手，要么等 15 s。
- **HaishinKit 还剩一个竞态（没修，W4-B）**：close 正好落在它内部 Task 置 `readyState = .versionSent`、`await socket.send(C0C1)` 与登记续体
  `operations[connectTransactionId]` 之间（微秒级）——close 找不到续体，之后登记的续体再没人收、那次 connect 永远不回。我们这边照样及时返回（已放手），
  收尾 30 s 后不再关它、记一条错误日志，`pendingHaishinKitConnects` 会停在 1。只在 TCP 正好在连接超时那一刻连上时可能撞上。
- **`pendingHaishinKitConnects` 是进程级计数**：同一进程里前一条用例放手的 RTMPS connect 会在之后 15 s 内还算着。SilentServerTests 每条结尾都等它回 0；
  新写用例要断言它，先等它回 0 再开始。
- **ThrottleProxy 的 E7（封 30 s）放开后的重连会变慢**：原来封住期间那一次连接一直挂到放开（代理放开时把它关掉 → 退避 2 s → 连上，约 2 s）；
  现在每 5 s 超时一次、退避升到 4、8 s，放开时多半正在退避里，要等完这一段。实测见 §2（硬阈值 15 s，目标 5 s）。E8（每次封 10 s）放开时那次连接还挂着，和原来一样。
- **只 listen 不 accept 的端口**就是"连上了 TCP、对端不说话"（内核替它完成三次握手）：`SilentServerTests.swift` 里的 `SilentServer`，`openConnections()` 把排队的连接接出来、
  数还开着的（读到 EOF / 被重置 = 客户端关了）。BSD 上接出来的连接继承 O_NONBLOCK，要改回阻塞才能按 SO_RCVTIMEO 等。
- **卡死类用例的看门狗要放在用例里面**：`perl -e 'alarm N'` 只杀得掉 swift test，挂住的 xctest 会被过继给 launchd 接着挂（W2-D5 记过）。
  SilentServerTests 的 `runAsync(limit:)` / `stopWithWatchdog(_:limit:)`：挂住就返回 nil、用例红，进程照常结束；tearDown 里的 stop 也走看门狗。
  本会话每次跑完查 `ps -axo pid,etime,comm | awk '$3 ~ /xctest/'`，都没有孤儿（`pgrep -f` 会匹配到自己的 shell，别用）。
- **XCTAssertNotNil(runAsync { … })** 这种写法 T 会被推成 Any（XCTAssertNotNil 的参数是 `Any?`）、编不过 Sendable：先赋给带类型的 let。
- 端口：SilentServerTests 用 19501–19506；AMF0LimitTests 19471–19476、StreamAuthTests 19466–19469、TransportErrorTextTests 19495–19497。
  包里的 MediaMTXTests 和 App 的 BottomBarSplitTests 都用 apiPort 29997（G12 记过）：同机有会话在跑 App 测试时别跑包里的 MediaMTX 用例。
- 新 worktree：Xcode 27.2 要装 Metal 工具链才编得过（见开头）；跑 MediaMTX 用例前先 `swift build -c release --package-path Tools/frameprobe`。
