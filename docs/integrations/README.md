# docs/integrations —— 对接外部控制面板与 tally 设备（W3-D）

| 文件 | 内容 |
|---|---|
| [vmix-compat.md](vmix-compat.md) | 第三方 API 兼容层（`VMixCompat` target，默认关）：**法律说明在顶部**、开关与端口、HTTP / TCP 协议子集、函数覆盖表、错误码、C5 的做法 |
| [companion.md](companion.md) | Bitfocus Companion：用它自带的模块对着兼容层（C5 六项的配法）；以及走原生 API 的 Companion 模块骨架（本期只写文档） |
| [stream-deck.md](stream-deck.md) | Stream Deck 官方 SDK 插件（`Tools/streamdeck-plugin`）：安装、按钮、颜色、排错 |
| [tally.md](tally.md) | 外部 tally：WebSocket JSON tally 流（`SwitcherTally` target）、GET 轮询、报文格式、第二版 TSL 的打算 |

相关：本地 API 的完整命令参考在 [../api.md](../api.md)；设计方案 §9（控制层与 API）、§0（法律灰区）。
