# Stream Deck 插件

`Tools/streamdeck-plugin/`：官方 SDK（`@elgato/streamdeck`）的插件，对着本地 API（`docs/api.md`）。**按钮 = 命令，按钮颜色 = tally**（PGM 红、PVW 绿）。
另一条路——不装插件、用 Companion——见 [companion.md](companion.md)。

## 安装

前提：PlusMix 的本地 API 打开（默认 127.0.0.1:8765），Stream Deck 软件 6.6+（自带 Node 20），开发机装 Node ≥ 20。

```bash
cd Tools/streamdeck-plugin
npm install                                          # @elgato/streamdeck、ws
npx streamdeck link com.plusmix.switcher.sdPlugin    # 开发：链接进插件目录，Stream Deck 里出现 "PlusMix" 分类
npx streamdeck pack com.plusmix.switcher.sdPlugin    # 发布：出 com.plusmix.switcher.streamDeckPlugin，双击安装
```

第一次拖任一按钮上去，设置面板里填 PlusMix 地址 / 端口 / token（全局设置，所有按钮共用）。连上之后按钮从灰色"未连接"变成各自的颜色。

## 按钮

| 动作 | 设置 | 按下 | 颜色 |
|---|---|---|---|
| Cut | — | PGM / PVW 对调 | 固定 |
| Auto / Fade | 方式（Auto = 按 PlusMix 里已选的转场；Fade + 毫秒） | `autoTransition` 或 `fade` | 转场进行中红 |
| Preview | 输入编号 | 选到 PVW | 这路的 tally：红 PGM / 绿 PVW / 灰；转场中红底绿边 |
| Program | 输入编号 | 直切 PGM（PVW 不变） | 同上 |
| Tally | 输入编号 | 只看；按下 = 选到 PVW | 同上 |
| Overlay | 通道 1–4、输入编号（可空 = 通道当前输入） | 开 / 关 | 可见 = 琥珀色，副标题 = 叠加的输入名 |
| Record | 输出编号（可空 = 编号最小的录制输出） | 录制开关 | 在录 = 红 |
| Stream | 输出编号（可空） | 推流开关 | 在推 = 蓝 |
| Fade to Black | — | FTB 开关 | 黑场 = 黑底白边 |

颜色每次收到快照重画（整快照每拍最多一条），所以多画面、App、Stream Deck 三处的 tally 永远是同一份数据（`MixerState.tallies`）。

## 排错

- 按钮灰色写"未连接"：API 没开、地址端口不对、token 不对。插件日志在 Stream Deck 的插件日志目录（macOS：`~/Library/Logs/ElgatoStreamDeck/com.plusmix.switcher.*.log`）。
- 按下闪警告：命令被拒（输入不存在、没有录制输出）或回执超时；原因在日志。
- 改了代码：`npx streamdeck restart com.plusmix.switcher`。
- 没有 Node 的机器上验证纯逻辑：`scripts/run-jxa.sh`（macOS 自带 JavaScriptCore）。

## 结构与测试

见 `Tools/streamdeck-plugin/README.md`。`lib/tally.js` 是不碰 SDK 的纯函数（快照 → 样式、按下 → 命令、SVG 图），`test/cases.js` 是它的用例，
`npm test`（node --test）或 `scripts/run-jxa.sh` 都能跑；SDK 接线（`bin/plugin.js`）和 WS 客户端（`lib/api-client.js`）要在装了 Stream Deck 的机器上人工验证。
