# 第三方 API 兼容层

> **法律提示（先读）。** 这个模块模仿 vMix（StudioCoast Pty Ltd 的产品）公开的 HTTP / TCP 控制协议的一个子集，目的只有一个：
> 让你为它配好的 Companion 页面、Stream Deck 配置、平板遥控不改就能控制 PlusMix。PlusMix 与 vMix、StudioCoast 没有任何关系，
> 不是它的替代品或衍生品；实现只参考了公开的协议文档和 Companion 模块（MIT 许可）的源码来学接口形状，没有复制任何代码、文案或素材。
> "兼容 vMix API"这类描述属于法律灰区（[设计方案 §0 / §9.3](../spec/导播台设计方案.md)），所以它是独立模块、**默认关闭**、不进默认产品，
> 正式发布前要请律师看过。本文不是法律意见。产品其他文档、界面文案一律不提对方的名字。

## 开关与端口

| 在哪 | 怎么开 |
|---|---|
| App | 设置 › 远程控制 › 第三方 API 兼容层：勾"启用兼容层（默认关）"，"谁能连"选仅本机 / 允许局域网，TCP 端口默认 8099、HTTP 端口默认 8088，页上显示别的机器该连的地址（带"复制"）；点窗口底部"应用并重起引擎"生效 |
| 无界面引擎 | `switcher-headless run … --compat [--compat-listen 0.0.0.0] [--compat-tcp-port 8099] [--compat-http-port 8088]` |

默认只听 `127.0.0.1`；Companion 在别的机器上时选"允许局域网"（= `0.0.0.0`；headless 用 `--compat-listen 0.0.0.0`）。这个协议本身没有鉴权，开到局域网前想清楚——App 的远程控制页这时会黄字提醒。要监听某个具体地址，在 设置 › 高级 填 host:TCP 端口。
所有经它进来的命令走同一条命令总线（`GET /api/v1/log` 里 `source = "api"`），状态从同一份快照读。

## Companion 里怎么配

Connections 加 "vMix" 类型的连接，Target host = PlusMix 所在机器，TCP port = 8099，API polling 250 ms；连接变绿后按平时的方式配按钮。
按动作分的覆盖表：

| Companion 动作 | 支持 | 说明 |
|---|---|---|
| Transition → Cut / Fade / Wipe / Zoom（带 Duration、可选 Input） | ✅ | 带 Input 时先选到 PVW 再切（旧 PGM 进 PVW）；转场进行中带 Input 的 Cut 回 409 NotConfigured、什么都不做 |
| Transition → Stinger 1 | ✅ | 执行 PlusMix 里第一个选了输入的 Stinger 转场槽；一个都没有（当前那组也没设 Stinger 输入）时 409 NotConfigured |
| Transition → Transition 1–4 / Set transition effect 1–4 / Set transition duration 1–4 | ✅ | 对应 PlusMix 的四个转场槽：Transition n = 执行转场 n（那个槽是没选输入的 Stinger 时 409 NotConfigured）；改效果 / 时长只改那个槽、不执行；效果只认 Cut / Fade / Wipe / Zoom / Stinger，对方的其他效果名返回 NotImplemented |
| Set fader（T-bar） | ✅ | 0–255 映射到推杆 0–1 |
| Input → Preview input / Send input to program / Preview next / previous | ✅ | Input 可以是编号、`0` = 当前 PVW、`-1` = 当前 PGM、XML 里的 key、或整个标题 |
| Input → Set input name | ✅ | |
| Output → Start / Stop / Toggle recording | ✅ | 作用于编号最小的录制输出（可在配置里指定） |
| Output → Start / Stop / Toggle streaming（可选第几路） | ✅ | |
| Fade to black | ✅ | 开关 |
| Audio → Master / Bus A / Bus B / Headphones volume | ✅ | 推子 0–100 按对方的曲线换算成 dB，0 dB 以上顶格 |
| Audio → Input volume / mute (Audio, AudioOn, AudioOff) / solo / balance / bus routing (AudioBus M/A/B) | ✅ | |
| Audio → Master / Bus A / Bus B mute | ✅ | |
| Overlay → Overlay 1–4 toggle / in / out / off / last / all off（带可选 Input） | ✅ | |
| Tally / Status 反馈：Program、Preview、Overlay、Recording、Streaming、FTB | ✅ | 由 XML 轮询 + TALLY / ACTS 订阅驱动；转场进行中 XML 只报旧 PGM（TALLY 订阅正确） |
| Overlay 5–8、Overlay zoom、Preview overlay | ❌ NotImplemented | PlusMix 只有四个叠加通道、没有"叠加预览"概念 |
| Transition 5 起、Stinger 2–8、对方的其他转场效果（Slide / Fly / Merge / CubeZoom …） | ❌ NotImplemented | PlusMix 只有四个转场槽 |
| 文件播放（Play / Pause / Restart / Set position） | ❌ NotImplemented | PlusMix 自己有暂停 / 回到开头（`setPlayback` / `seekPlayback`）和循环（`setInputSource` 改播完动作），兼容层还没映射 |
| External / MultiCorder / Fullscreen / SRT output 开关、Snapshot、SetOutput 2–4 | ❌ NotImplemented | 外部显示的开关命令 setOutputEnabled 2026-09-23 起已有，映射还没做：要先定 External / Fullscreen 各对应哪种输出、同类有多个时用哪一个（docs/ui-study/02 V14） |
| Audio auto（AFV per input）、Bus solo、Send to master、Set gain、Volume fade、声道混音器、音频插件 | ❌ NotImplemented | AFV 在 PlusMix 里是全局开关 + 每路标志（每路 afv 只在全局开关打开时生效），映射有损，暂不映射 |
| Title / List / Replay / PTZ / Browser / Video call / Virtual set / 数据源 / 脚本等整族 | ❌ NotImplemented | 第一版没有这些功能 |

不支持的动作返回明确的错误（HTTP 501 / TCP `FUNCTION ER NotImplemented: …`），Companion 的 Log 里能看到；完全不认识的名字是 UnknownFunction。

## 协议范围

- HTTP：`GET /api/?Function=<名字>&Input=<n>&Duration=<ms>&Value=<v>`；`GET /api` 返回 XML 状态文档。
- TCP（8099）：`FUNCTION` / `TALLY` / `XML` / `ACTS` / `SUBSCRIBE TALLY` / `SUBSCRIBE ACTS` / `PING` / `VERSION` / `QUIT`；`XMLTEXT` 未实现。
- XML `<version>` 报的是 PlusMix 自己的版本，`<edition>` 是 "Switcher"（代码名，包内默认值），不冒充对方。

函数级别的完整映射表、XML 节点、ACTS 事件、错误码和 C5 的测法在 [docs/integrations/vmix-compat.md](../integrations/vmix-compat.md)；
真 Companion 的六项验收（Cut / Fade / Overlay / Record / Stream / Tally）在 [docs/integrations/companion.md §1](../integrations/companion.md#1-用兼容层c5)。
