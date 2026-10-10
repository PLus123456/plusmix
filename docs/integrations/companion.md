# Bitfocus Companion

两条路：**用 Companion 自带的模块对着兼容层**（第一天就能用现成配置，C5 的口径）；或者**为原生 API 写一个 Companion 模块**（本期只写文档，见 §2）。

## 1. 用兼容层（C5）

1. 打开兼容层：App 的 设置 › 远程控制 › 第三方 API 兼容层（勾"启用兼容层（默认关）"、应用并重起引擎），或 headless 的兼容层参数（G4 接线）；不起 App 也可以用
   `SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual`（8 路合成输入，PGM 1 / PVW 2，带拍推进）。
   兼容层默认只听 127.0.0.1。Companion 在另一台机器上时：App 的 设置 › 远程控制 里兼容层选"允许局域网"（= 听 0.0.0.0）、应用并重起引擎，把页上显示的 TCP / HTTP 地址填进 Companion（兼容层没有鉴权，只在可信的网络里这样做）；headless 用 `--compat-listen 0.0.0.0`。
2. Companion → Connections → 加 "StudioCoast: vMix"（模块作者的命名，这里只是选它）：Target host = 127.0.0.1，TCP port = 8099，API Polling Interval 250 ms。
   连接状态应变绿；Log 里能看到 `Connected Function Socket` 等。它会开三条 TCP 连接、每 3 s PING、每 250 ms 要一次 XML、订阅 ACTS。
3. 配一页按钮（六项，测试标准 §4 C5）：

| # | 按钮 | Companion 动作 | 反馈 | 通过标准 |
|---|---|---|---|---|
| 1 | Cut | Transition → Transition Mix：Cut | — | PGM / PVW 对调，多画面 / App 的 tally 色跟着变 |
| 2 | Fade | Transition Mix：Fade，Duration 500 | — | 500 ms 淡变后对调 |
| 3 | Overlay 1 | Overlay → Functions：Overlay Toggle on Program，Overlay 1，Input 3 | Tally → Overlay state（Overlay 1） | 按一下上、再按一下下；按钮色跟着 |
| 4 | Record | Output → Recording：StartStopRecording | General → Status：recording | 录制开关；按钮红 |
| 5 | Stream | Output → Streaming：StartStopStreaming | General → Status：streaming | 推流开关；按钮亮 |
| 6 | Tally | 输入 1–4 各一个：Input → Preview Input | Tally → Preview state / Program state | PVW 绿、PGM 红，与 App 一致 |

   顺手可加：Send Input to Program（CutDirect）、Set Fader（T-bar）、Audio → Input Mute、Master Volume、FadeToBlack；Custom Command 里任何未实现的函数会在 Log 里看到 `FUNCTION ER NotImplemented: …`。
4. 自动化版本：`scripts/apitest/c5-companion.py`（同一序列，退出码 = 结果）。

模块的解析要求（兼容层已按它们做）：XML 必须以 `<vmix>` 开头 `</vmix>` 结尾、长度含 CRLF；必须有 version / edition / audio / recording / streaming … 节点；
输入按 `inputs[编号 − 1]` 找，所以编号必须连续（有空洞就补 Blank 占位）；`PING` 要回 `PING OK PONG`。

## 2. 走原生 API 的 Companion 模块（骨架，本期只写文档）

如果不想经过兼容层（或者要用只有原生 API 才有的功能：T-bar 进度、批量命令、每秒 Stats、转场类型），写一个 Companion 模块对着
`docs/api.md`。Companion 模块是 Node 包、MIT 许可，用 `@companion-module/base`；放在本仓库外（`companion-module-switcher`），这里只记结构：

```
companion-module-switcher/
├── companion/manifest.json     id "switcher"、runtime node22、entrypoint dist/index.js
├── src/index.ts                InstanceBase：init / configUpdated / destroy
├── src/config.ts               host（默认 127.0.0.1）、port（8765）、token
├── src/api.ts                  WS 客户端：/api/v1/events 收 hello / snapshot / stats；连接上发 {"id", "command"} 拿 receipt
├── src/actions.ts              动作 → Command JSON
├── src/feedbacks.ts            反馈：读最近一条 snapshot
├── src/variables.ts            变量：pgm / pvw / 每路名字 / 转场进度 / recording / streaming / stats 里的几项
└── src/presets.ts              预设按钮
```

| 动作 | 命令 |
|---|---|
| Cut / Auto | `{"cut":{}}` / `{"autoTransition":{}}` |
| Fade（时长 ms） | `{"fade":{"durationTicks": round(ms/1000 × fps)}}`，fps 从 hello 的 `clock.frameDuration` 算 |
| 选转场 | `{"setTransition":{"type":"wipe","durationTicks":30}}` |
| Preview / Program | `{"setPreview":{"input":n}}` / `{"setProgram":{"input":n}}` |
| T-bar | `{"tbar":{"progress":p}}`（0–1；推到 1 提交） |
| Overlay | `{"overlay":{"channel":k,"on":true,"input":n}}` |
| FTB | `{"ftb":{"on":true}}` |
| 录制 / 推流 | `{"startRecord":{"output":n}}` … |
| 音频 | `{"mute":{"input":n,"on":true}}`、`{"audioGain":{"input":n,"dB":-6}}`、`{"busGain":{"bus":0,"dB":0}}` |
| 批量（同一次请求顺序执行） | `{"id":1,"commands":[…]}` |

| 反馈 | 数据 |
|---|---|
| 输入在 PGM / PVW | `snapshot.tally["n"].program / .preview`（转场中 PVW 也是 program，与画面一致） |
| 叠加 k 可见 | `snapshot.state.overlays[k-1]`：`input != null && (on || animProgress > 0)` |
| 录制 / 推流中 | `snapshot.state.outputs[].enabled`（kind record / stream） |
| FTB | `snapshot.state.ftb.on` |
| 转场中 | `snapshot.state.transition.startTick != null || progress > 0` |

要点：整快照每拍最多一条、幂等，模块只需保存最近一条；断线重连后第一条就是当前状态；命令回执里 `applied == false` 表示状态机按规则忽略了（已是目标状态），不是错误。
Stream Deck 插件（[stream-deck.md](stream-deck.md)）的 `lib/tally.js` 已经把"快照 → 颜色"和"按下 → 命令"写成纯函数，Companion 模块可以直接搬。
