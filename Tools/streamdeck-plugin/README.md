# PlusMix 的 Stream Deck 插件

对着 PlusMix（代码名 Switcher：插件 UUID / 目录名 / npm 包名仍用它）的本地 API（`docs/api.md`：WS `/api/v1/events` 收整快照 + tally，连接上发命令）做的官方 SDK 插件：
**按钮 = 命令，按钮颜色 = tally**（PGM 红、PVW 绿，转场中红底绿边）。用法与安装见 [docs/integrations/stream-deck.md](../../docs/integrations/stream-deck.md)。

```
Tools/streamdeck-plugin/
├── com.plusmix.switcher.sdPlugin/    Stream Deck 加载的插件目录
│   ├── manifest.json                 10 个动作：cut / auto / slot（转场 1–4）/ preview / program / tally / overlay / record / stream / ftb
│   ├── bin/plugin.js                 入口：@elgato/streamdeck（官方 SDK）+ 本地 API 客户端；每次快照重画所有可见按钮
│   ├── lib/api-client.js             WS 客户端：快照缓存、时钟、发命令等回执、断线 2 s 重连；改连接设置时旧 socket 后到的事件不碰新连接（WebSocket 由 plugin.js 注入）
│   ├── lib/tally.js                  纯函数：快照 → 按钮样式（颜色 / 文字 / SVG）、按下 → Command JSON
│   ├── ui/*.html                     设置面板（sdpi-components v4）：输入编号 / 叠加通道 / 输出编号 / 转场时长 / 转场槽 + 全局的地址 / 端口 / token
│   └── imgs/                         PNG 图标（scripts/gen-icons.py 生成）
├── test/cases.js                     断言用例：tally.js 的纯函数 + api-client.js 的受控事件顺序（假 socket / 假计时器）；test/tally.test.js 用 node --test 跑
├── scripts/run-jxa.sh                没有 Node 时用 macOS 自带的 JavaScriptCore 跑同一批用例
├── scripts/gen-icons.py              重新生成图标
└── package.json                      依赖 @elgato/streamdeck ^2、ws ^8；脚本 test / link / restart / pack / validate
```

## 开发

需要 Node.js ≥ 20（Stream Deck 6.6+ 自带 Node 20 运行插件；开发机装一个）和官方 CLI：

```bash
npm install                      # 拉 @elgato/streamdeck 与 ws
npm test                         # lib/tally.js 与 lib/api-client.js 的单元测试（不用装依赖也能跑）
npx streamdeck link com.plusmix.switcher.sdPlugin    # 把插件目录链进 Stream Deck 的插件文件夹
npx streamdeck restart com.plusmix.switcher          # 改完代码重启插件
npx streamdeck validate com.plusmix.switcher.sdPlugin
npx streamdeck pack com.plusmix.switcher.sdPlugin    # 出 .streamDeckPlugin 安装包
```

没有 Node 的机器：`scripts/run-jxa.sh` 用 osascript 跑同一批断言（纯函数 + 客户端的事件顺序；测不了 SDK 接线）。

## 按钮

| 动作 | 按下 | 颜色 |
|---|---|---|
| Cut | `cut` | 固定 |
| Auto / Fade | `autoTransition`（= 执行当前转场槽），或设置成 Fade + 时长 → `fade(durationTicks)`（毫秒按 hello 里的帧率换算） | 转场进行中变红 |
| Transition 1–4 | `useTransitionSlot(slot, start: true)`：执行转场 n（选中并开始）；设置成"只选中"时 `start: false`（之后 T-bar 和回车用它） | 跟当前槽：当前槽蓝、它执行中红、别的灰；小字 = 槽的效果与时长（"Wipe → 1s"，Stinger 没选输入写"未选输入"） |
| Preview | `setPreview(input)` | 这路的 tally：红 = PGM、绿 = PVW、灰 = 都不在 |
| Program | `setProgram(input)`（直切，PVW 不变） | 同上 |
| Tally | 只显示；按下 = `setPreview(input)` | 同上 |
| Overlay | `overlay(channel, on: !on[, input])` | 可见 = 琥珀色 |
| Record | `startRecord / stopRecord(output)`（不填编号 = 编号最小的录制输出） | 在录 = 红 |
| Stream | `startStream / stopStream(output)` | 在推 = 蓝 |
| Fade to Black | `ftb(on: !on)` | 黑场 = 黑底白边 |

未连上 Switcher 时按钮灰底并写"未连接"；命令被拒（输入不存在等）按钮闪警告，原因在插件日志（`~/Library/Logs/ElgatoStreamDeck/` 或 Stream Deck 的日志目录里 `com.plusmix.switcher.*.log`）。
