# 转场槽落地后要改的文档（docs/ 不在 W5-M 的目录）

归属会话 / 分支：**103 W4-C2 / `w4-docs-2`**（docs/integrations、docs/user、docs/api；prompt 103 写着"100 / 101 合入后 rebase 一次"）。
API 文档那一句（下面第 4 条）的代码一半在 `Packages/SwitcherControl/Sources/SwitcherControl/API/APIDocument.swift`，归下一个碰 SwitcherControl/API 的会话。
发现于：W5-M（prompt 100，分支 `w5-transition-slots`）落地转场槽时对照现有文档。严重级：S3（文档与实现不一致；有的条目现在写的是"落地后由 prompt 100 接上"）。

## 1. docs/integrations/vmix-compat.md §6 函数覆盖表（prompt 100 交付 4 点名"C5 用例与覆盖表同步"）

实现以 `FunctionCatalog.implemented` 与 `FunctionTranslator` 为准（`swift test --package-path Packages/SwitcherControl --filter VMixCompatTests` 钉着）：

| 函数 | 现在的映射（W5-M 起） |
|---|---|
| Cut | 不变；**转场进行中带 Input → NotConfigured（409），一条都不发**（问题单 W5E-w3-control2-compat-cut-input-mid-transition 的 (a)）；不带 Input 照旧做完当前转场 |
| Stinger1 | **执行第一个选了输入的 Stinger 转场槽**（`useTransitionSlot(k, start: true)`）；没有这种槽时照旧用当前那组的 stinger 输入（`setTransition(.stinger)` + `autoTransition`）；都没有 → NotConfigured |
| Transition1–4 | **`useTransitionSlot(n, start: true)`**：执行转场 n（一拍内选中并开始，之后 T-bar / 回车也用它）；转场进行中再发 → "(no change)"（原来 Transition1 = autoTransition、2–4 NotImplemented） |
| SetTransitionEffect1–4 | Value=Cut/Fade/Wipe/Zoom/Stinger → **`setTransitionSlot(n, 槽 n 的配置只换效果)`**（时长 / Wipe 参数 / Stinger 参数原样带上）；对方的其他效果名 → NotImplemented，谁都没有的名字 → BadParameter |
| SetTransitionDuration1–4 | Value=ms → **`setTransitionSlot(n, 槽 n 的配置只换时长)`**（毫秒按帧率换拍） |

"明确不做"那段删掉 "Transition2–4（提案 020 转场槽落地后由 prompt 100 接上）"。XML 状态的 `<transitions>`（§ 状态文档那节若有描述）现在是**四项**，`number` = 槽号、`effect` / `duration` = 槽的效果与毫秒（原来只有一项 = 当前那组）。

## 2. docs/integrations/stream-deck.md 的按钮表

加一行"Transition 1–4"：设置 = 转场 1–4 + 按下（执行 / 只选中）；按下 = `useTransitionSlot(slot, start: true / false)`；颜色跟当前槽——当前槽蓝、它执行中红、别的灰；
小字 = 槽的效果与时长（"Wipe → 1s"，放不下 9 个字只写效果，Stinger 没选输入写"未选输入"）。动作数 9 → 10（Tools/streamdeck-plugin/README.md 已改）。
Auto / Fade 那一行的 Auto 现在 = 执行当前转场槽。

## 3. docs/user（手册）

- 概念.md:61（T-bar）：T-bar **横放**（左 0 右 1，过 97% 松手提交后回弹，没过停在原位），推的是**当前槽**（T-bar 上方那行写着"转场 2 · Wipe → 1 秒"）；MIDI 推子照旧到两端换向。
- 概念.md:63（FTB）：FTB 时长**能改了**：FTB 的 ▾ 或右键 → 0.5 / 1 / 2 秒 / 自定义…（存拍、按节目帧率换算；不跟随转场时长）。"0.1.0 的界面上改不了……提案 020 落地后可改"这句删掉。
- 转场列：Cut ｜ 转场 1–4（每个"主体 + ▾"：点主体 = 执行这个槽；▾ 或右键 = 效果（含 Cut、Wipe 五个方向、Stinger 选输入）/ 时长 / 参数… / 用于 T-bar（不执行）/ 恢复出厂，只改设置不执行）｜ FTB（主体 + ▾）；
  出厂四槽 1 Fade 0.5 秒、2 Wipe 1 秒、3 Zoom 1 秒、4 Stinger 1 秒（没选输入）；Stinger 槽没选输入时点主体先弹输入选择、不执行；当前槽按钮左边有一条常亮的蓝条；
  "T-bar"组 = 当前槽的弹出菜单（列四个槽，点了就执行）+ 当前槽的时长分段 + T-bar。截图要重拍（docs/ui-study/img/改后/ 也是旧的）。
- 快捷键.md：默认表 **⌥1–⌥4 = 执行转场 1–4**（原来写的是"执行当前转场"）、回车 = 执行当前转场（当前槽）；可绑的动作多了"执行转场 n""选中转场 n（不执行）"（选动作面板"切换"组），MIDI 音符同一套。
- 菜单栏"切换"：Cut ／ 执行当前转场（转场 2 · Wipe → 1 秒）／ 转场 1–4（标题带效果与时长，点了就做）／ FTB ／ Overlay ▸——原来的五种"只选不执行"类型没了。
- 兼容层：§1 的覆盖表同步到用户手册里提到兼容层的地方（如果有）。

## 4. API 文档的批量例子（问题单 W5E-w3-control2-compat-cut-input-mid-transition 的 HTTP 那半）

`APIDocument.swift:60` / docs/api.md:51 拿 `{"commands": [setPreview(n), cut]}` 当批量例子：例子旁加一句"转场进行中 setPreview 被拒（applied = false），cut 会把正在进行的那次做完，看回执"。
docs/api.md 是 `switcher-apidoc` 生成的，要改 APIDocument.swift 再重生成。
