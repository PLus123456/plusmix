# 第三方 API 兼容层（VMixCompat）

> **法律说明（先读）。** 这个模块让为 vMix（StudioCoast Pty Ltd 的产品）写的控制面板配置——Companion 的 vMix 模块、
> 各种 Stream Deck / TouchPortal / 平板遥控——不改配置就能控制 PlusMix。它是一个**适配器**：只实现对方公开协议的一个子集，
> 把函数名映射到 PlusMix 自己的命令；和 vMix、StudioCoast 没有任何关系，也不是它的替代品或衍生品。
> 实现时只读了公开的协议文档和 Companion 模块（MIT 许可）的源码来学接口形状，**没有复制任何代码、文案或素材**。
> 设计方案 §0 把"兼容 X 的 API"这类描述性用法列为法律灰区，所以（1）它是独立的 SwiftPM target，不进默认产品；
> （2）**默认关闭**，用户在设置里显式打开（App 的 设置 › 远程控制 带这段提示）；（3）**发布前问律师**——包括产品文案里能不能出现对方的名字、
> XML 根元素等协议字面量算不算商标使用。代码树里按铁律 6 不出现对方的名字（`scripts/lint-rules.sh` 会拦），
> 唯一的例外是协议规定的 XML 根元素名（提案 [docs/contract-changes/011](../contract-changes/011-lint-exception-compat-protocol-literals.md)，已批：lint 只放行 VMixCompat 目录下带 `lint:allow-protocol-literal` 标记的那一行）。
> 以上不是法律意见。

## 1. 开关、端口、接线

`VMixCompatConfiguration`（`Packages/SwitcherControl/Sources/VMixCompat/`）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | **false** | 总开关。关着时 `VMixCompatServer.start()` 什么都不做，两个端口都不监听（有测试钉着） |
| `host` | 127.0.0.1 | HTTP 与 TCP 共用。库 / headless 可配（`--compat-listen`）；**PlusMix App**：设置 › 远程控制 里"仅本机 / 允许局域网"二选一（允许局域网 = 0.0.0.0），要具体地址在 设置 › 高级 填 host:TCP 端口；改了要应用并重起引擎 |
| `httpEnabled` / `httpPort` | true / 8088 | HTTP 入口；App 里 设置 › 远程控制 可改 HTTP 端口 |
| `tcpEnabled` / `tcpPort` | true / 8099 | TCP 文本协议入口 |
| `recordOutput` | nil | StartRecording 等操作哪个录制输出；nil = 编号最小的录制输出 |
| `streamOutput` | nil | StartStreaming 没带 `Value` 时用哪个推流输出；nil = 编号最小的；`Value=k` 选第 k 路（0 起） |
| `reportedVersion` | `SwitcherVersion.current` | XML `<version>` 与 TCP 问候里报的版本——报本产品的版本，不冒充对方 |
| `edition` | Switcher | XML `<edition>`（包内默认值是代码名；产品名 PlusMix 的改名没动包，见 reports/w4-rename.md §3） |
| `allowedOrigins` | `[]` | HTTP 入口放行的浏览器来源（同主 API 的白名单规则，见 [docs/api/README.md §1](../api/README.md)）；空 = 不放任何网页。App 和 headless 这一版都没有入口填它 |

接线（App 与 headless 都一样，都在检查点 / W3-E 做）：

```swift
let compat = VMixCompatServer(bus: commandBus, feed: stateFeed, configuration: config)   // config.enabled 由设置决定
try await compat.start()      // 监听成功后返回；compat.boundTCPPort / boundHTTPPort
…
await compat.stop()           // 关连接、释放端口；顺序：兼容层 → API → 引擎 → StateFeed
```

所有命令走 `CommandBus`（来源 `.api`，`GET /api/v1/log` 里能看到），状态从 `StateFeed` 读同一份快照，表读数从同一份 `Stats` 拿（铁律 4）。
没有引擎时钟（引擎没起）时用节目格式的帧率换算毫秒 ↔ 拍。

## 2. HTTP 入口

`GET /api/?Function=<名字>&Input=<n>&Duration=<ms>&Value=<v>`（也认 `/API/`、无斜杠）。参数名不分大小写，值按查询串规则解码（`%20`、`+` 都当空格）。

| 情况 | 状态码 | 正文（text/plain） |
|---|---|---|
| 成功 | 200 | `OK <名字>`；命令全被状态机忽略（已是目标状态）时 `OK <名字> (no change)` |
| 参数缺失 / 越界 / 不认识的函数 | 400 | `BadParameter: …` / `UnknownFunction: …` |
| 输入 / 输出不存在（含 `Input=0` / `-1` 落在黑场或已删的输入上，见 §6 表下） | 404 | `InputNotFound: …` / `OutputNotFound: …` |
| 当前状态做不了（没有录制输出、叠加通道没输入、stinger 没设输入） | 409 | `NotConfigured: …` |
| 对方有、这里没做 | 501 | `NotImplemented: …` |
| 浏览器发来的（带 `Origin` 而不在 `allowedOrigins`；或不带 `Origin`、`Sec-Fetch-Site` 不是 `none`——`same-origin` 只在 Host 是 IP / localhost 时放） | 403 | `Forbidden`，什么都不执行 |

`GET /api`（不带 `Function`）→ `text/xml` 的状态文档（§4）；浏览器来源同样 403。
来源检查防的是"网页让浏览器替它发请求"（`<img src="http://127.0.0.1:8088/api?Function=Cut">` 这类）：Companion、curl、脚本不带这两个头，不受影响；在浏览器地址栏里直接打开 `http://127.0.0.1:8088/api` 照旧能看 XML。

## 3. TCP 入口（默认 8099）

所有消息 UTF-8、`\r\n` 结尾（只发 `\n` 也认）。连上先收 `VERSION OK <版本>`。

| 请求 | 应答 |
|---|---|
| `FUNCTION <名字> [key=value&…]` | `FUNCTION OK <名字>[ (no change)]` / `FUNCTION ER <错误码>: <文案>` |
| `TALLY` | `TALLY OK 0121…`：每个输入位置一位，0 关 / 1 PGM / 2 PVW（位置 = 编号，缺的编号是 0） |
| `XML` | `XML <长度>\r\n<文档>\r\n`（长度含结尾的 CRLF，对方协议的约定，Companion 按它切） |
| `XMLTEXT <xpath>` | `XMLTEXT ER NotImplemented: …`（没做 XPath；拿 XML 自己解析） |
| `ACTS <激活器> [输入号]` | `ACTS OK <激活器> [输入号] <值>`（布尔 1/0，音量 0–1 浮点）；不认识 `ACTS ER UnknownActivator: …` |
| `SUBSCRIBE TALLY` / `UNSUBSCRIBE TALLY` | `SUBSCRIBE OK TALLY` 后立刻一条当前 `TALLY OK …`；之后每次 tally 变化推一条 |
| `SUBSCRIBE ACTS` / `UNSUBSCRIBE ACTS` | `SUBSCRIBE OK ACTS`；之后每次状态变化推 `ACTS OK …`（§5 的事件） |
| `PING` | `PING OK PONG`（Companion 每 3 s 发一次） |
| `VERSION` | `VERSION OK <版本>` |
| `QUIT` | `QUIT OK Bye`，然后关连接 |
| 其他 | `<命令> ER UnknownCommand: <命令>` |

一个包里多条命令（粘包）按行拆开逐条应答；三条以上并发连接互不干扰（Companion 开三条：命令、激活器订阅、每 250 ms 轮询 XML）。

上限：一行最长 64 KiB（不含结尾的 `\r\n`；还没等到换行的半行同样算），超了这条连接被断开、日志记一行 warning；同时最多 64 条连接，满了之后新连接连上就被关掉（没有 `VERSION OK` 问候、日志记一行）；没有空闲超时——只订阅 TALLY / ACTS、不发命令的客户端一直挂着没问题。

## 4. XML 状态文档

节点集合按 Companion 模块解析代码的硬性要求来（少一个它就崩）：`version`、`edition`、`inputs`、`overlays`、`preview`、`active`、`fadeToBlack`、
`transitions`、`recording`、`external`、`streaming`（每路推流一个 `channelN` 属性）、`playList`、`multiCorder`、`fullscreen`、`audio`（`master` / `busA` / `busB`）。

- 输入 `<input key number type title shortTitle state position duration loop muted volume balance solo audiobusses meterF1 meterF2>标题</input>`。
  **位置 = 编号**（Companion 用 `inputs[编号 − 1]` 找输入），编号有空洞时补 `type="Blank"` 的占位。`key` 是由编号生成的稳定 GUID
  （`00000000-0000-4000-8000-000000000003`），`Input=` 参数可以回传它。`type` 按输入类型映射：摄像头 / 采集卡 → Capture、屏幕 → Desktop、
  文件 → Video、图片 → Image、NDI、Audio、合成源 → Colour。`state` 恒 Running（快照里没有输入的运行状态）。
- `volume` 是幅度百分比：100 = 0 dB，`SetVolume Value` 是推子 0–100，幅度 = (推子/100)⁴（对方的曲线，Companion 按它算增减）。内部增益 0 dB 以上表示不了，顶格 100。
- `meterF1 / meterF2` 来自 `Stats.audio.meters`（1 Hz 的那一份），没有就是 0。
- 叠加 `<overlay number="k">输入</overlay>` 只在通道可见（开着或退出动画未完）时写输入，否则空元素。
- 转场 `<transitions>` 是四个转场槽各一项：`<transition number="n" effect="Wipe" duration="1000" />`，`number` = 槽号（与 Transition1–4 对得上），`effect` / `duration` = 槽的效果与毫秒。
- `active` / `preview` 就是快照的 PGM / PVW。**转场进行中 PVW 也算在 PGM 上**（C3 口径）——TALLY 串和 ACTS 反映这一点，XML 没有"转场中"字段，
  只能靠 `active`，这是与快照 tally 的唯一差别（`testC3_tallyDigitsAndXMLAgreeWithSnapshotTallies` 钉着）。

## 5. ACTS（激活器）

查询与事件的名字：`Input`、`InputPreview`（不带输入号 = 当前那路）、`Overlay1–4`、`Recording`、`Streaming`、`External`、`FadeToBlack`、
`MasterVolume`、`MasterAudio`（1 = 有声）、`MasterHeadphones`、`BusA/BVolume`、`BusA/BAudio`、`BusA–GSolo`（恒 0，没有总线独听）、
`InputAudio`、`InputVolume`、`InputSolo`、`InputPlaying`（恒 1）、`InputMasterAudio`、`InputBusAAudio`、`InputBusBAudio`。
事件顺序固定：PGM / PVW（先旧的 0 再新的 1）→ 叠加 → Recording / Streaming / External / FadeToBlack → 每路输入的音频 → 总线。

## 6. 函数覆盖表

实现表在 `FunctionCatalog.implemented`（测试钉着 prompt 点名的子集都在）。名字不分大小写（Companion 发 `MasterAudioON` 大写）。

| 函数 | 参数 | 映射 |
|---|---|---|
| Cut | Input? | `.cut`；带 Input 先 `.setPreview` 再 `.cut`（旧 PGM 进 PVW，与对方一致）。**转场进行中（T-bar 推到一半也算）带 Input → 409 NotConfigured、一条都不发**（这时 PVW 改不了，`.cut` 会把正在进行的那次做完、落不到点名的那一路）；不带 Input 照旧把当前转场做完（PVW 是黑场时就把黑场切上去）。`Input=0` 而 PVW 是黑场 → 404 InputNotFound、一条都不发（原来会把黑场切上去） |
| Fade / Wipe / Zoom | Duration?（ms，默认 500；只收 0–3 600 000，见下）、Input? | `.fade(拍)`；Wipe / Zoom = `.setTransition` + `.autoTransition`（改的是当前那组，之后它可能对不上任何转场槽）。`Input=` 同样要落到一路存在的输入（404 的规矩同 Cut）；但转场进行中带 Input **不回 409**：`.setPreview` 与 `.fade` / `.autoTransition` 都被状态机忽略，回 `OK Fade (no change)` 这样的成功、什么都没变 |
| Stinger1 | | 执行**第一个选了输入的 Stinger 转场槽**（`.useTransitionSlot(k, start: true)`）；没有这种槽时用当前那组的 stinger 输入（`.setTransition(.stinger)` + `.autoTransition`）；都没有 → NotConfigured |
| Transition1–4 | | `.useTransitionSlot(n, start: true)`：执行转场 n（一拍内选中并开始，之后 T-bar / 回车也用它）；转场进行中 → `OK TransitionN (no change)`。转场 n 是没选输入的 Stinger 槽 → 409 NotConfigured（"…is a Stinger with no input; pick an input for it first"，与 Stinger1 没配好同口径），一条都不发。Transition5 起 → NotImplemented |
| SetTransitionEffect1–4 | Value=Cut/Fade/Wipe/Zoom/Stinger（不分大小写） | `.setTransitionSlot(n, 槽 n 只换效果)`：时长、Wipe 方向 / 软边、Stinger 输入 / 换底拍原样带上；只改设置、不执行，转场进行中也收（进行中的那一次照原样走完）。对方的其他效果名 → NotImplemented，谁都没有的名字 → BadParameter |
| SetTransitionDuration1–4 | Value=ms（0–3 600 000） | `.setTransitionSlot(n, 槽 n 只换时长)`：毫秒按节目帧率换拍（2000 ms @60 = 120 拍）；只改设置、不执行 |
| SetFader | Value=0–255 | `.tbar(v/255)` |
| PreviewInput / SetPreviewInput | Input | `.setPreview` |
| ActiveInput / CutDirect | Input | `.setProgram`（直切，PVW 不变；Companion 的 Send Input to Program 发 CutDirect） |
| PreviewInputNext / Previous | | PVW 上下一路（回绕） |
| SetInputName | Input、Value | `.renameInput` |
| StartRecording / StopRecording / StartStopRecording | | `.startRecord` / `.stopRecord`（配置指定或编号最小的录制输出） |
| StartStreaming / StopStreaming / StartStopStreaming | Value?（第几路，0 起） | `.startStream` / `.stopStream` |
| FadeToBlack | | `.ftb(on: !当前)` |
| SetMasterVolume / SetBusAVolume / SetBusBVolume / SetHeadphonesVolume | Value=0–100 | `.busGain(dB)`（曲线见 §4） |
| SetVolume | Input、Value=0–100 | `.audioGain` |
| Audio / AudioOn / AudioOff | Input | `.mute(on:)`（Audio = 开关） |
| AudioBus / AudioBusOn / AudioBusOff | Input、Value=M/A/B | 路由开关（`.setInputSettings`） |
| Solo / SoloOn / SoloOff、SetBalance（Value −1…1） | Input | 独听 / 声像（`.setInputSettings`） |
| MasterAudio / MasterAudioOn / MasterAudioOff、BusAAudio…、BusBAudio…、BusXAudio… (Value=A/B) | | `.busMute` |
| OverlayInput1–4 | Input? | 开关：同一路已开着 → 关；否则开并换成 Input；不带 Input 用通道当前输入开关（没有 → NotConfigured） |
| OverlayInput1–4In / Out / Off / Last | Input?（In） | 开 / 关 / 关 / 用通道当前输入开关 |
| OverlayInputAllOff | | 关掉开着的通道 |

`Input=` 的四种写法都认：编号、`0` = 当前 PVW、`-1` = 当前 PGM、XML 里的 `key`、整个标题（区分大小写）。
**永远要落到一路存在的输入上**：编号不存在（含 `-2` 这类别的负数）、key / 标题对不上，或 `0` / `-1` 时 PVW / PGM 是黑场、或指着一路已经删掉的输入，一律 404 `InputNotFound`、一条命令都不发——
所有带 Input 的函数都这样（Cut / Fade / Wipe / Zoom、PreviewInput、ActiveInput / CutDirect、SetInputName、SetVolume、Audio* / AudioBus*、Solo*、SetBalance、OverlayInput*）。正文说明是哪一种（`input 7 does not exist`、`Input=0 is the current preview, which is empty (black)`）。
切黑场用不带 Input 的 Cut（PVW 是黑场时）。

**毫秒参数**（Fade / Wipe / Zoom 的 `Duration`、SetTransitionDuration1–4 的 `Value`）只收有限、0–3 600 000（1 小时）之间的数：越界、负数、非数、无穷都回 400 `BadParameter`，正文写可收的范围（`Fade: Duration must be a number of milliseconds within 0…3600000 (got 1e300)`），一条都不发。
主 API 设下的超大槽时长在 XML 的 `<transition duration>` 里封顶成 Int 的最大值，不会让 XML 轮询出错。

明确不做（返回 NotImplemented + 文案，`FunctionCatalog.knownUnimplemented` 与前缀族）：对方的其他转场效果（Slide / Fly / Merge / CubeZoom…）、
Transition5 起、Stinger2–8、文件播放（Play / Pause / PlayPause / Restart / SetPosition：PlusMix 有 `setPlayback` / `seekPlayback`，映射还没做）、OverlayInput5–8、OverlayInputNZoom、PreviewOverlayInputN（没有"叠加预览"）、External / MultiCorder / Fullscreen / SRT 输出
（外部显示的开关命令 `setOutputEnabled` 2026-09-23 起已有，映射待定：先要定 External / Fullscreen 各对哪种输出，见 docs/ui-study/02 V14）、Snapshot、SetOutput2–4、AudioAuto（每路 afv 2026-09-23 起已有，但只在全局 AFV 打开时生效，映射有损，暂不映射）、BusXSolo、SendToMaster、
SetGain（内部只有一个增益）、SetVolumeFade、声道混音器、音频插件、Title / List / Replay / PTZ / Browser / VideoCall / VirtualSet / 数据源 / 脚本等整族，
以及前缀族盖不住的 31 个具体名字（推流设置 StreamingSetKey / URL / Username / Password、AutoPlay / AutoPause / AutoRestart 一族、NDISelectSourceByName / ByIndex、NDIStart / StopRecording、OpenPreset / LastPreset、ActivatorRefresh 等，只认精确名字）。
完全不认识的名字返回 UnknownFunction（400）。

## 7. C5 怎么测

- 自动化：`scripts/apitest/c5-companion.py --tcp-port 8099 --http-port 8088`，像 Companion 一样开三条连接（命令 / SUBSCRIBE ACTS / XML 轮询）
  加一条 SUBSCRIBE TALLY，跑六项：Cut / Fade / Overlay 1 开关 / Record 开关 / Stream 开关 / Tally 反馈（XML、TALLY 命令、TALLY 订阅三处一致），
  每项用 XML 轮询到的状态判定；再附加一项 HTTP。任一失败退出码 1。`VMixCompatTests.testC5_companionRequestSequence_scriptPassesAllSixItems`
  在进程内起兼容层（带拍推进）跑这个脚本。
- 人工（真 Companion）：见 [companion.md](companion.md) §1。没有 headless 参数之前用
  `SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual` 在 8099 / 8088 挂一个带拍推进的兼容层（8 路输入）。

## 8. 已知限制

- XML 里没有"转场进行中"，Companion 的 PGM 反馈在转场那几十帧只亮旧 PGM（TALLY 订阅和外部 tally 流没这个问题）。
- 输入的 `state` 恒 Running（编号空洞处补的 Blank 占位写 Paused）、`position` / `duration` 恒 0、`loop` 恒 False：兼容层没映射文件播放（PlusMix 自己有暂停 / 回到开头 / 循环，见[用户手册 · 输入](../user/输入.md#播放)；对方的 Play / Pause / Restart / SetPosition 回 NotImplemented）。
- 没有鉴权（对方的 TCP 协议也没有）；默认只听 127.0.0.1，开到局域网前想清楚。HTTP 入口挡浏览器来源（§2），TCP 入口不查来源（它不是 HTTP，没有这两个头可查）。
- 白名单 `allowedOrigins` 这一版没有设置入口：自己写的网页面板连不上 HTTP 入口（走 TCP 或主 API 的非浏览器客户端不受影响）。
- 每条 TCP 连接的推送缓冲 64 条快照，慢客户端丢旧的；ACTS 事件按"上次看到的状态 → 这次"算差，中间被合并的来回不会都发（收敛到最终状态）。
