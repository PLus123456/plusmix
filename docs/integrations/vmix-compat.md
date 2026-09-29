# 第三方 API 兼容层（VMixCompat）

> **法律说明（先读）。** 这个模块让为 vMix（StudioCoast Pty Ltd 的产品）写的控制面板配置——Companion 的 vMix 模块、
> 各种 Stream Deck / TouchPortal / 平板遥控——不改配置就能控制 PlusMix。它是一个**适配器**：只实现对方公开协议的一个子集，
> 把函数名映射到 PlusMix 自己的命令；和 vMix、StudioCoast 没有任何关系，也不是它的替代品或衍生品。
> 实现时只读了公开的协议文档和 Companion 模块（MIT 许可）的源码来学接口形状，**没有复制任何代码、文案或素材**。
> 设计方案 §0 把"兼容 X 的 API"这类描述性用法列为法律灰区，所以（1）它是独立的 SwiftPM target，不进默认产品；
> （2）**默认关闭**，用户在设置里显式打开（W3-E 的偏好设置页带这段提示）；（3）**发布前问律师**——包括产品文案里能不能出现对方的名字、
> XML 根元素等协议字面量算不算商标使用。代码树里按铁律 6 不出现对方的名字（`scripts/lint-rules.sh` 会拦），
> 唯一的例外是协议规定的 XML 根元素名（提案 [docs/contract-changes/011](../contract-changes/011-lint-exception-compat-protocol-literals.md)，已批：lint 只放行 VMixCompat 目录下带 `lint:allow-protocol-literal` 标记的那一行）。
> 以上不是法律意见。

## 1. 开关、端口、接线

`VMixCompatConfiguration`（`Packages/SwitcherControl/Sources/VMixCompat/`）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | **false** | 总开关。关着时 `VMixCompatServer.start()` 什么都不做，两个端口都不监听（有测试钉着） |
| `host` | 127.0.0.1 | HTTP 与 TCP 共用。库 / headless 可配；**PlusMix App 0.1.0 里固定 127.0.0.1、HTTP 端口固定 8088，偏好设置只能改开关与 TCP 端口**——Companion 在别的机器上时暂时连不上 App 的兼容层（"允许局域网"选项归 prompt 98） |
| `httpEnabled` / `httpPort` | true / 8088 | HTTP 入口 |
| `tcpEnabled` / `tcpPort` | true / 8099 | TCP 文本协议入口 |
| `recordOutput` | nil | StartRecording 等操作哪个录制输出；nil = 编号最小的录制输出 |
| `streamOutput` | nil | StartStreaming 没带 `Value` 时用哪个推流输出；nil = 编号最小的；`Value=k` 选第 k 路（0 起） |
| `reportedVersion` | `SwitcherVersion.current` | XML `<version>` 与 TCP 问候里报的版本——报本产品的版本，不冒充对方 |
| `edition` | Switcher | XML `<edition>`（包内默认值是代码名；产品名 PlusMix 的改名没动包，见 reports/w4-rename.md §3） |

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
| 输入 / 输出不存在 | 404 | `InputNotFound: …` / `OutputNotFound: …` |
| 当前状态做不了（没有录制输出、叠加通道没输入、stinger 没设输入） | 409 | `NotConfigured: …` |
| 对方有、这里没做 | 501 | `NotImplemented: …` |

`GET /api`（不带 `Function`）→ `text/xml` 的状态文档（§4）。

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
| Cut | Input? | `.cut`；带 Input 先 `.setPreview` 再 `.cut`（旧 PGM 进 PVW，与对方一致） |
| Fade / Wipe / Zoom | Duration?（ms，默认 500）、Input? | `.fade(拍)`；Wipe / Zoom = `.setTransition` + `.autoTransition` |
| Stinger1 | | `.setTransition(.stinger)` + `.autoTransition`；没设 stinger 输入 → NotConfigured |
| Transition1 | | `.autoTransition`（按已选类型 / 时长）；Transition2–4 → NotImplemented（只有一个转场槽） |
| SetTransitionEffect1 | Value=Cut/Fade/Wipe/Zoom/Stinger | `.setTransition(type, 当前时长)`；对方的其他效果名 → NotImplemented |
| SetTransitionDuration1 | Value=ms | `.setTransition(当前类型, 拍)` |
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

明确不做（返回 NotImplemented + 文案，`FunctionCatalog.knownUnimplemented` 与前缀族）：对方的其他转场效果（Slide / Fly / Merge / CubeZoom…）、
Transition2–4（提案 020 转场槽落地后由 prompt 100 接上）、Stinger2–8、OverlayInput5–8、OverlayInputNZoom、PreviewOverlayInputN（没有"叠加预览"）、External / MultiCorder / Fullscreen / SRT 输出
（外部显示的开关命令 `setOutputEnabled` 2026-09-23 起已有，映射待定：先要定 External / Fullscreen 各对哪种输出，见 docs/ui-study/02 V14）、Snapshot、SetOutput2–4、AudioAuto（每路 afv 2026-09-23 起已有，但只在全局 AFV 打开时生效，映射有损，暂不映射）、BusXSolo、SendToMaster、
SetGain（内部只有一个增益）、SetVolumeFade、声道混音器、音频插件、Title / List / Replay / PTZ / Browser / VideoCall / VirtualSet / 数据源 / 脚本等整族。
完全不认识的名字返回 UnknownFunction。注意：另有 31 个参考软件里真实存在的函数名现在也被当成"不认识"返回 400，按上面的定义应返回 501（docs/ui-study/02 X51，归 W3-D 系）。

## 7. C5 怎么测

- 自动化：`scripts/apitest/c5-companion.py --tcp-port 8099 --http-port 8088`，像 Companion 一样开三条连接（命令 / SUBSCRIBE ACTS / XML 轮询）
  加一条 SUBSCRIBE TALLY，跑六项：Cut / Fade / Overlay 1 开关 / Record 开关 / Stream 开关 / Tally 反馈（XML、TALLY 命令、TALLY 订阅三处一致），
  每项用 XML 轮询到的状态判定；再附加一项 HTTP。任一失败退出码 1。`VMixCompatTests.testC5_companionRequestSequence_scriptPassesAllSixItems`
  在进程内起兼容层（带拍推进）跑这个脚本。
- 人工（真 Companion）：见 [companion.md](companion.md) §1。没有 headless 参数之前用
  `SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual` 在 8099 / 8088 挂一个带拍推进的兼容层（8 路输入）。

## 8. 已知限制

- XML 里没有"转场进行中"，Companion 的 PGM 反馈在转场那几十帧只亮旧 PGM（TALLY 订阅和外部 tally 流没这个问题）。
- 输入的 `state` 恒 Running、`position` / `duration` 恒 0（快照里没有播放状态；文件输入的播放控制不在本期）。
- 没有鉴权（对方的 TCP 协议也没有）；默认只听 127.0.0.1，开到局域网前想清楚。
- 每条 TCP 连接的推送缓冲 64 条快照，慢客户端丢旧的；ACTS 事件按"上次看到的状态 → 这次"算差，中间被合并的来回不会都发（收敛到最终状态）。
