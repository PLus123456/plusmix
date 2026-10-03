# W5L → W4-C2（prompt 103）：手册与集成文档跟着 98 改

来源：W5-L（prompt 98，分支 w5-app-misc）。98 只准动 App/ 与 project.yml，下面这些文档里的说法 98 落地后不再成立，归 103（W4-C2 手册再对齐）改。
原来的"实现归 98"一栏见 reports/issues/UIA-w4-docs-manual-vs-implementation.md（X32 / X33 / X34）。

## 1. tally 流（X32）

- `docs/integrations/tally.md:17`："0.1.0 里只有 `switcher-headless --tally-port 8766` 会起 TallyServer，PlusMix App 不起"——98 起 App 也能起：
  **设置 › Tally** 一个开关（默认关）、端口（默认 = API 端口 + 1，即 8766）、页上两行只读地址（`ws://<本机局域网 IP>:<端口>/tally`、`http://…/tally`）带"复制"、连接数（WS 订阅数）。
  开关与端口即时生效，不用重起引擎；打开即听 `0.0.0.0`（局域网）。启动参数 `--tally-port <N>` 与 headless 同名（给了就开）。
  停机顺序 tally → API → 引擎。macOS 防火墙开着时第一次打开会弹"允许传入连接"，要点允许。
- `docs/user/快捷键.md:78`、`docs/user/en/shortcuts.md:82`："App **不起**这个服务……App 内的开关归 prompt 98"——改成上面的入口。

## 2. 兼容层 / API 的监听地址（X33）

- `docs/api/vmix-compat.md:16`、`docs/integrations/companion.md:9`："PlusMix App 0.1.0 里改不了监听地址——固定 127.0.0.1、HTTP 端口固定 8088"——98 起
  **设置 › 远程控制**：本地 API 与兼容层各"仅本机 / 允许局域网"二选一（允许局域网 = 听 0.0.0.0），兼容层的 HTTP 端口可改（默认 8088）、TCP 端口照旧；
  页上只读显示别的机器该连的地址（`http://<本机局域网 IP>:<端口>`，兼容层另有 `…/api` 与 TCP 地址）带"复制"；API 允许局域网又没设 token、兼容层允许局域网（它没有鉴权）时黄字提醒。
  改动照旧走"应用 / 应用并重起引擎"（下次起引擎生效）。Companion 在另一台机器上：兼容层选"允许局域网"、应用并重起引擎、把页上的地址填进 Companion。
- 新的本机设置键（`defaults` 里能看到）：`compatLayerHost`、`compatLayerHTTPPort`、`tallyEnabled`、`tallyPort`、`preventSleepWhileRunning`、
  `preventDisplaySleepWhileRunning`、`reminderNotLive` / `reminderNotLiveMinutes` / `reminderFTB` / `reminderLowAudio`。

## 3. 防睡眠 / App Nap（X34）

- `docs/user/故障排查.md:68`、`docs/user/en/troubleshooting.md:69`："App 自己还不会阻止睡眠 / App Nap，prompt 98 加"——98 起引擎在跑时 App 自己拿两条电源断言
  （设置"性能与电源"：阻止系统睡眠与 App Nap、阻止显示器休眠，默认都开）。建议改成：平常用 App 不用再跑 caffeinate；**无人值守、要合盖或锁屏的长跑仍用 `caffeinate -u -i -d -s`**——
  App 挡不住合盖 / 手动锁屏，ProcessInfo 也给不了 caffeinate `-u` 那条"声明用户在用"的 UserIsActive 断言；reports/w5-app-misc.md §2.2 的复测在"用户空闲但显示器亮着、没锁屏"时
  有没有断言都没有拖慢，G4 记的拖慢条件（合盖 + 显示器睡 + 会话锁）这次没有复现。

## 4. 新界面（手册新增）

- 主窗口提醒条（状态行右侧，琥珀色）：没在录 / 推满 n 分钟（默认关）、FTB 开着满 10 秒、Master 有声源时持续 30 秒低于 −50 dBFS；PGM 标题条 FTB 时垫黑底慢闪；设置 › 提醒 每条可关。
- 统计窗：底栏右组"统计"或菜单"窗口 › 统计"；五节（输入 / 渲染 / 输出 / 显示 / 音频）读同一行 Stats；"重置"只在窗里从 0 算起，stats.jsonl / API 照旧累计。
- 界面锁：底栏最右的锁或菜单"窗口 › 锁定界面"；锁着时主窗口里的鼠标点击（含工具条）不生效，快捷键 / MIDI / API / 菜单栏照常，设置等独立窗口不锁。
