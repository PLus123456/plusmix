# W5-M 报告：转场槽落地——转场列（含 T-bar 横放）、快捷键 / MIDI 动作、兼容层 Transition1–4、Stream Deck 按钮（prompt 100，分支 `w5-transition-slots`，2026-10-11）

工作树分支 `claude/w5-transition-slots-543812` = 本地别名 `w5-transition-slots`（`git branch -f w5-transition-slots HEAD`），从 G8a-2 快进后的 main 832b3f4 开（提案 020 已由 P5-2 落进契约）。
**101（W5-N）叠在本分支头上开**：小步提交、没有 rebase / 改写。不 push、不 merge。

## 1. 做了什么

先写红测试再实现，三轮红灯（控制层 / 兼容层 ebc657b、App b1b5d31、Stream Deck 先跑红再写），每轮都实跑确认是红的（数字见 §6）。

| 交付 | 落点 | 提交 |
|---|---|---|
| **3 控制层** | `ControlAction.transitionSlot(slot:)`（执行转场 n = `useTransitionSlot(n, start: true)`，一拍内选中并开始）/ `.selectTransitionSlot(slot:)`（选中转场 n、不执行 = `start: false`）；JSON `{"transitionSlot": {"slot": 2}}` / `{"selectTransitionSlot": {"slot": 4}}`；槽号不在 1–4 解析不出、不发；`ControlActionKind` 两个新 case（参数 `slot` 用 `CommandFieldType.transitionSlot`、发 `useTransitionSlot`、归"切换"）。默认表 **⌥1–⌥4 = 执行转场 1–4**，**回车不改**（`autoTransition` 用的当前那组就是当前槽的配置，提案 020 保证）；MIDI 音符走同一个 `resolve`。 | 0847fcb |
| **4 兼容层** | `Transition1–4` → `useTransitionSlot(n, start: true)`；`SetTransitionEffect1–4` / `SetTransitionDuration1–4` → `setTransitionSlot(n, 槽 n 只换效果 / 时长)`（别的字段原样带上；效果名只收 Cut / Fade / Wipe / Zoom / Stinger，上游别的 NotImplemented、没人有的 BadParameter）；从 `knownUnimplemented` 拿掉、`FunctionCatalog.implemented` 加 12 条。顺带：`Stinger1` 改成执行第一个选了输入的 Stinger 槽（Stinger 输入现在设在槽里，原来只看当前那组会一直 NotConfigured），没有这种槽时照旧；XML 状态的 `<transitions>` 改成四个槽各一项（number = 槽号，与 Transition1–4 对得上）。**G6 追加 ① 三选一定 (a)**：转场进行中带 `Input=` 的 `Cut` 回 NotConfigured（409）、一条都不发（问题单 W5E-w3-control2-compat-cut-input-mid-transition 末尾"处理结果"）。 | 0847fcb |
| **1 转场列** | `ColumnSplitButton`（主体 + ▾；右键主体 = 同一份菜单，打开前按当前状态重建）。列 = Cut ｜ 转场 1–4 ｜ FTB（主体 + ▾）｜ Overlay ｜ "T-bar"组 ｜ 时钟。**主体** = `useTransitionSlot(n, start: true)`；按钮上的字 = 槽的效果与时长（"Fade 0.5s""Wipe → 1s""Stinger 未设"，Wipe 带方向箭头）；执行中蓝底；**当前槽左内边距一条常亮的竖条**（主体蓝底时变白）。**Stinger 槽没选输入点主体 = 弹出这个槽的输入选择（段标题"转场 4 · Stinger：先选一路输入（选了才执行）"）、不执行**（X18）。**▾ / 右键** = 效果单选（Cut〔写明"无过渡：T-bar 推到顶才切"，G6 追加 ②〕/ Fade / Zoom / Wipe 五向平铺 / Stinger：输入 ▸）、时长 0.5 / 1 / 2 秒 / 自定义…（不是预设时"✓ 自定义：0.75 秒"）、参数…（软边、Stinger 换底拍，按槽编辑的弹出面板）、用于 T-bar（不执行）、恢复出厂；全是 `setTransitionSlot`（进行中也收），当前项打勾。**FTB** 的 ▾ / 右键 = 0.5 / 1 / 2 秒 / 自定义…（`setFTBDuration`，按标称帧率换拍，不跟随转场时长），提示写出 FTB 时长。**"T-bar"组** = 组标题 + 弹出按钮"转场 2 · Wipe → 1 秒 ▾"（菜单列四个槽、当前打勾、**点了就做**〔2026-10-10 裁定〕、进行中灰）+ **当前槽的时长分段**（Q37 (a)：改它 = `setTransitionSlot(当前槽)`，当前那组不在槽里时 = `setTransition`）+ T-bar；当前槽 / 当前那组被换掉时那一行高亮 1.5 s。参数面板改成按槽编辑（`setTransitionSlot`，不用再等转场结束才发）。 | bfb45ee |
| **2 T-bar 横放** | `TBarView` 重写成横的（Q05 (a)）：左 0 右 1，过 97% 松手提交（发 `tbar(1)`）后 150 ms 回弹到最左，没过停在原位；固定高 28 pt、把手 14 pt 宽、轨道铺满整宽（可见边 = 视图左右边）；加了辅助功能（slider，标签"T-bar"，值 = 位置）。MIDI 推子不经过它，照旧到两端换向。列里多出来的高度给 T-bar 与时钟之间的空白（时钟贴底）。行程 / 精度 / 列高实测见 §2。 | bfb45ee |
| **6 菜单栏"切换"** | Cut ／ 执行当前转场（转场 2 · Wipe → 1 秒）／ ─ ／ **转场 1–4**（标题带效果与时长、当前槽打勾、右列 ⌥n、点了就做〔与转场列主体同一条路，含 X18〕、进行中灰）／ ─ ／ FTB ／ Overlay ▸。W5-G 的五种"只选不执行"类型与 `AppDelegate.pickTransitionType`、`HotkeyMatch.selectType` 撤掉；加 `HotkeyMatch.slot(n)`。 | bfb45ee |
| 3 的界面一半（选动作面板） | "执行转场""选中转场（不执行）"进"切换"组；**槽号控件**改成列出四个槽现在的效果与时长（原来借叠加通道的"1 2 3 4"四段）；**`setInputAudio` 的总线路由补了勾选控件**（"改总线路由"开关 + 四条总线；不勾 = 不动），独听 / AFV 这类**可选开关默认"不改"**（原来默认"开"，不填也会发）；摘要"执行转场 · 转场 3（Zoom 1 秒）"；补 slot / start / ticks / solo / afv / routing / paused / seconds / color 的字段名（P5-2 加命令时没加，表单上露着键名）。 | bfb45ee |
| G7 追加 ③ 格子"转场"按钮 | **定为当前槽**（= 回车 / T-bar / 菜单"执行当前转场"同一个，仍是 `setPreview` + `autoTransition`）；提示改成"按当前转场送上 PGM（转场 2 · Wipe → 1 秒）"。转场中两颗按钮置灰（G6 追加 ④）W5-H 已做、InputStripTests 钉着，没动。 | bfb45ee |
| 2026-10-10 裁定 ② X12 残口 | `SettingsWindow` 的 keyHandler 先录键、不吃再交 `controller.session?.control.handleKey`（问题单 G7-w5-app-settings-window-hotkeys-not-forwarded 末尾"处理结果"）。 | bfb45ee |
| **5 Stream Deck** | 新动作 `com.plusmix.switcher.slot`（设置：转场 1–4、按下 = 执行 / 只选中）：按下 = `useTransitionSlot(slot, start: true / false)`；**颜色跟当前槽**——当前槽蓝（App 的强调色）、它执行中红、别的灰；大字"转场 n"、小字 = 槽的效果与时长（9 个字放不下只写效果，Stinger 没选输入写"未选输入"）；设置页 ui/slot.html、图标（gen-icons.py 深底蓝环）、README 按钮表。 | 1482fb5 |
| 文案 / 文档 | 两份 strings 加 W5-M 一节（中英各 61 条）、改 7 条老文案（"五种转场共用这一个时长"等）、删 13 个没人用的老键。docs/ 不在本会话目录：要改的写成问题单 **W5M-w4-docs-2-transition-slots-docs.md**（给 103：vmix-compat.md 覆盖表、stream-deck.md、手册的 T-bar / FTB 时长 / 快捷键 / 切换菜单 / 截图；API 批量例子那一句给下一个碰 SwitcherControl/API 的会话）。 | 本报告提交 |

两处界面上和 prompt 字面不同、照实说：

1. **T-bar 那一行没写"T-bar："前缀**：整行"T-bar：转场 2 · Wipe 1 秒 ▾"在 small 下要 161 pt（实测 fittingSize），这一行只有 134；去掉前缀的"转场 2 · Wipe → 1 秒 ▾"出厂四槽是 121–133 pt，放得下。"T-bar"挪成上面的组标题（与"Overlay"同一样式），读起来仍是"T-bar：转场 2 · Wipe → 1 秒"；自定义时长（"0.75 秒"）这类长的截尾，提示和辅助功能标签写全。
2. **时长分段挪进"T-bar"组**（在弹出按钮和 T-bar 之间）：它现在改的是当前槽，和那一行写的是同一个东西，放在一起不会被当成"所有转场共用"。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

（全量与运行环境见 §6。）

| 用例 | 测什么 | 数值 | 阈值 / 判据 | 结果 |
|---|---|---|---|---|
| `TransitionColumnTests.testUI_transitionSlotMenuConfiguresWithoutExecuting` | ▾ 菜单的 20 项（含段标题、Cut、Wipe 五向、Stinger 子菜单、时长、参数…、用于 T-bar、恢复出厂）、当前项打勾、右键同一份；改转场 2 为 Zoom 2 s 后 `slots[1]` = Zoom 120 拍（Wipe / Stinger 参数原样）、PGM 1 / PVW 2 不变、没开始转场、当前槽仍 1、别的槽不变、UI 只发两条 `setTransitionSlot`；按钮字"Zoom 2s"；Wipe 下 → 上 = 类型 + 方向（"Wipe ↑ 2s"）；Stinger 子菜单选输入 2；用于 T-bar = 当前槽换 2、不执行；恢复出厂回到 Wipe 1 s 且当前那组重拷；点 ▾ 实测弹出位置 | 全对；▾ 菜单（全量第 2 遍测试宿主在前台时量到）(626, 468, 267×464)、主体 (626.5, 932, 109×24)：菜单顶边 = 主体下沿、左缘差 0.5 pt | 断言全过、被拒 0；菜单在主体下方（≤ +1）、左缘 ±2 | ✅ |
| `testUI_transitionSlotBodyExecutesSlot` | 出厂四个按钮字；当前槽标记；点转场 3 = 一条 `useTransitionSlot(3, true)`、Zoom 60 拍、执行中蓝底；进行中点转场 1 被忽略；做完对调、标记移到 3、T-bar 行"转场 3 · Zoom 1 秒"；回车 = 再做一次 Zoom | 全对 | 同左 | ✅ |
| `testUI_tbarFollowsCurrentSlot` | 槽 3 ▾ 里"用于 T-bar"后推 T-bar 到 0.5 = Zoom 的 tbar 转场、推到顶提交、当前槽仍 3；T-bar 行菜单四项与打勾、点"转场 2" = `useTransitionSlot(2, true)`、进行中四项灰；之后 T-bar 推的是 Wipe | 全对 | 同左 | ✅ |
| `testUI_stingerSlotWithoutInputOpensMenuInsteadOfExecuting` | 转场 4（Stinger 没选输入）字"Stinger 未设"、提示"还没选输入"；点主体弹输入选择（段标题 + 两路输入）、不执行、一条命令不发；从这个菜单选输入 2 只改槽；之后点主体执行 Stinger（输入 2） | 全对 | 同左 | ✅ |
| `testUI_ftbDurationMenuWritesTicks` | FTB 菜单五项、0.5 秒打勾；右键同一份；选 1 秒 = `setFTBDuration(60)`、不碰转场槽、不开 FTB；自定义 0.75 秒 = 45 拍、菜单"✓ 自定义：0.75 秒"、提示写 0.75 秒；0 秒不发；FTB 开 / 关按新时长走完 | 60 / 45 拍 | 断言全过 | ✅ |
| `testUI_transitionColumnEdgesAlignedWithSlots` | 86 的对齐断言搬到新列：13 行可见边（Cut、转场 1–4〔主体左到 ▾ 右〕、FTB、Overlay 1–4、T-bar 行、时长、T-bar、把手 0…1、时钟）、两个组标题左 8、两档控件、时钟 56 / 1 pt；1440×900 与最小窗口各量一遍 | 全部 **8…142**（两种窗口）；**列最小高 392**；最小窗口（1100×720）列高 412；T-bar 134×28、**行程 120 pt** | 边差 ≤ 1；**最小高 ≤ 409**；行程 ≥ 60（原来竖放要求 T-bar ≥ 60 高） | ✅ |
| `testUI_tbarHorizontalCommitsPast97PercentAndSpringsBack`（新） | 真鼠标事件拖：0 在最左、1 在最右；拖到 50% 停住；96% 松手不提交；98% 松手提交对调、回弹到 0；挪 1 pt / 0.5 pt 的精度 | 行程 120 pt；**1 pt = 0.833%**（量化后 0.008）；**0.5 pt（Retina 一个像素）= 0.4%**（0.004） | 0.97 提交（TBarView.commitThreshold，没改） | ✅ |
| `testUI_tbarSlotRowHighlightsWhenCurrentSlotChanges`（原 `testUI_tbarTypeRowHighlightsWhenTypeChanges`） | 当前槽被换掉时 T-bar 行高亮（accent 底白字）、过 1.5 s 自己消失 | — | 同左 | ✅ |
| `testUI_transitionDurationSegmentIsCurrentSlot`（原 `testUI_transitionDurationCustomSegment`） | 分段 = 当前槽的时长：选 1 s 只改当前槽（`setTransitionSlot`）、别的槽不动；换当前槽分段跟着；0.75 s 选中"自定义"写"0.75s"、菜单"✓ 自定义：0.75 秒"；自定义 1.5 s = 90 拍；进行中改了这一次照走、做完那一拍重拷 | — | 同左 | ✅ |
| `testUI_transitionTooltipsFromHotkeyTable` | 提示从快捷键表反查：转场 n 写 ⌥n 与"Wipe 左 → 右 · 1 秒"、Cut 空格、FTB F、T-bar 行"回车：执行这里的转场"；换表后跟着变 | — | 同左 | ✅ |
| `testUI_settingsWindowForwardsHotkeys`（X12） | 设置窗在前按空格 = Cut（handled +1）；快捷键页录键中按空格 = 录进去、不切 | — | 同左 | ✅ |
| `testUI_overlayEmptyChannelUsesPreview` / `testUI_highlightedTitlesAreWhite` / `testUI_clockTwelveHourUsesLocalizedTemplate` | 86 留下的三条（槽模型下不变） | — | 同左 | ✅ |
| `TransitionPanelTests` ×3（W3-E2 的三条按槽改写） | 转场 2（Wipe 24 拍）恰 24 拍对调、T-bar 跟它；转场 3 / 4 同一条路；时长分段只改当前槽（转场 1 = 60 拍、转场 3 仍 24 拍）；参数按槽发 `setTransitionSlot`、不 loadShow、不重建输入、叠加动画不被打断、进行中也收且这一次按开始时的参数走完 | 24 / 60 拍 | 同左 | ✅ |
| `ActionPickerTests.testUI_actionPickerTransitionSlotsAndBusRouting`（新） | 两类槽动作在"切换"组、名字 / API 键名 / 预览 / 摘要；槽号选项写四个槽的效果与时长；定位当前动作；setInputAudio 可选参数不填 = 不动、总线路由 JSON 来回、"Master + Bus A" | — | 同左 | ✅ |
| `ToolbarMenuTests.testUI_switchMenuShowsHotkeysFromTable`（改写） | "切换"菜单行：Cut ｜ 执行当前转场（转场 1 · Fade 0.5 秒）回车 ｜ 转场 1–4 带效果与时长、右列 ⌥1–⌥4 ｜ FTB ｜ Overlay；撤掉五种类型；点转场 2 = 一条 `useTransitionSlot(2, true)`、进行中灰；执行当前转场标题跟当前槽 | — | 同左 | ✅ |
| `testHotkeys_optionDigitExecutesSlot`（SwitcherControl） | 默认表 ⌥1–⌥4 = 执行转场 1–4、回车 = autoTransition；⌥3 一条 `useTransitionSlot(3, true)`、当前槽 3 / Zoom 60 拍 / 开始；进行中 ⌥1 被忽略；回车再做转场 3 | — | 同左 | ✅ |
| `TransitionSlotActionTests` 另两条 | 选中不执行（PGM / PVW 不动）、槽号越界解析不出；JSON 往返、缺 slot 报错；MIDI 音符按下 / 松开；目录 | — | 同左 | ✅ |
| `testC5_transition2ExecutesSlot` | Transition1–4 = `useTransitionSlot(n, true)`、在实现表、不在未实现表、不分大小写、回显规范名；Transition5 / 0 NotImplemented | — | 同左 | ✅ |
| `testC5_setTransitionEffect3MapsToSlot` | SetTransitionEffect3 五种名字（不分大小写）只换效果、槽里别的字段原样；上游六种效果名 NotImplemented 且文案点名函数；Sparkle / 缺 Value BadParameter；SetTransitionDuration4 2000 ms = 120 拍、Duration2 750 ms = 45 拍；1–4 在实现表；5 NotImplemented | — | 同左 | ✅ |
| `testC5_cutWithInputDuringTransitionIsRefused`、`HTTPTests.testC5_http_transitionSlotsAndCutDuringTransition`（新） | 转场中 Cut 带 Input 回 409、一条不发；不带 Input 照旧；HTTP 走一遍：Transition2 → "OK Transition2"、Transition3 进行中 "(no change)"、SetTransitionDuration2 进行中也收、完成那一拍重拷、XML 四项、SetTransitionEffect4 Merge 501 | — | 同左 | ✅ |
| 改了期望的老用例 | `ControlActionTests`（⌥n 期望、样本表）、`FunctionTranslatorTests.testC5_transitionSlotAndFader` 与 Stinger1、`StatusXMLTests` 的 transitions 四项、`AccessibilityTests` 参数面板改从槽打开、`PanelTests` 参数两行指明编辑转场 1 | — | 意思照旧，按 prompt 定的新口径改期望；阈值一个没动 | ✅ |
| Stream Deck `test/cases.js` 两条新 | 按下的命令（执行 / 只选中 / 默认 1 / 越界报错 / 没快照照发）、颜色跟当前槽（蓝 / 红 / 灰、不在槽里四个都不亮、老快照只写槽号）、小字（按帧率、9 字规则、未选输入） | node --test 9/9、run-jxa.sh 9/9 | 同左 | ✅ |

## 3. 没做的和原因

1. **docs/ 的同步**（vmix-compat.md 覆盖表、stream-deck.md、手册、截图）：不在本会话目录，写成问题单 W5M-w4-docs-2-transition-slots-docs.md 给 103（prompt 103 写着"100 / 101 合入后 rebase 一次"）。API 批量例子那一句（W5E 问题单的 HTTP 那半）在 `SwitcherControl/API/APIDocument.swift`，也不在本会话目录，同一张单子里写了。
2. **用户已存的 hotkeys.json 不自动升级**：W5-J 默认表把 ⌥1–⌥4 存成 `autoTransition`，存过表的机器上 ⌥n 仍是"执行当前转场"（能用，只是不分槽）；设置 › 快捷键"恢复默认"就换成新表。本机 `~/Library/Application Support/PlusMix/` 下没有 hotkeys.json（0.1.0 没发过），没写迁移。
3. **快捷键 / MIDI / 兼容层 / Stream Deck 对"没选输入的 Stinger 槽"照常执行**（契约默认：reducer 照常开始，结果是一次延迟硬切），只有屏幕上的按钮（转场列主体、T-bar 行菜单、菜单栏"切换 › 转场 n"）按 X18 先弹输入选择。外部控制没有地方弹菜单；要它们也拒，见 §4 第 1 条。
4. **ControlAction 的 inputAFV / busRoute / solo 与兼容层 AudioBus / Solo / SetBalance 仍按快照整体写回 `setInputSettings`**：P5-2 加了 `setInputAudio`（不会盖掉别处的改动），换过去是"控制层动作补齐"那类活，prompt 100 没点名，没动（P5-2 报告 §3 第 4 条也列着"100 之后"）。
5. **0.1.1 的放行、gate4**：G8b 的事（本会话没碰引擎 / 渲染 / 录制，gate4 指标不受影响）。

## 4. 对契约的疑问

1. **没选输入的 Stinger 槽从外部控制执行**（§3 第 3 条）：提案 020 "请用户定的点"第 1 条按默认"reducer 照常开始"批了，界面按 X18 拦；快捷键 / MIDI / 兼容层 / Stream Deck 没有界面可拦，现在照常执行（延迟硬切）。兼容层的 `Stinger1` 本来就对"没配好"回 NotConfigured；要 `Transition4` / ⌥4 也这样，得在控制层 / 兼容层各加一条判断（不改契约），或改 reducer 拒（改契约口径）。请用户定要不要。
2. **`currentSlot` = nil 时界面怎么写**：当前那组是 API / 节目文件直接给的、对不上任何槽时，T-bar 行写"Fade 0.75 秒 ▾"（不写槽号）、四个槽都不亮、时长分段改当前那组（`setTransition`，进行中不发）。P5-2 的"老命令后对号"已让大多数情况能对上槽，这条只是记下口径。
3. 槽号越界（不在 1–4）的 `ControlAction` 解析为空、不进总线（"解析不出"计数 +1），与引用不存在的输入同口径；校验器本来也会拒，结果一样。

## 5. 下一个会话需要知道的坑

1. **T-bar 横放后高度固定 28 pt**：列里多出来的高度给 T-bar 与时钟之间的空白（时钟贴底），不再给 T-bar；老的"T-bar ≥ 60 高"不再适用，对齐用例改成"行程 ≥ 60 pt"（实测 120）。竖放时行程随窗口变（行程 = T-bar 高 − 30）：最小窗口 34 pt（86 实测 T-bar 64 高）、1440×900 约 215 pt（按 86 的布局表推算 T-bar ≈ 245 高）；横放恒为 120 pt——小窗口手推精度好了 3.5 倍，大窗口比原来短（1 pt ≈ 0.83%，原来约 0.47%）。用户若更看重大窗口下的手感，Q05 当时的 (b) 竖放仍可回退（只动 TBarView 与列布局）。
2. **ColumnSplitButton 的右键菜单是常驻的一份**（`bodyButton.menu`，delegate 在打开前把 `makeMenu()` 的项搬过来）：测试里要先 `menu.delegate?.menuNeedsUpdate?(menu)` 才有项；▾ 每次现建。菜单项的 `representedObject` 存的是"改哪一处"（SlotChange），发的时候按**最新快照**里的槽改，不是菜单建那一刻的整份配置——菜单开着时别处改了时长 / 参数不会被盖回去。
3. **转场列不在转场中置灰**：槽主体 / T-bar 行 / "用于 T-bar"都是一条原子命令，进行中状态机自己忽略；只有 T-bar 行菜单项和"用于 T-bar"按状态灰着（诚实）。格子上的"转场 / Cut"是 setPreview + 转场两条，进行中必须灰（W5-H 做的，别改回去）。
4. **参数面板现在按槽编辑**（`TransitionParamsModel.slot`，默认 1；`showSlotParams(slot:)` 设它）：别的用例直接用 `transitionPanel.params` 时先设 `slot`（PanelTests 改了）。`setTransitionSlot` 进行中也收，所以不再有"挂着等转场结束才发"的 pending 逻辑，pending 只表示"发出去了、快照还没回来"（1 s 没回来放弃）。
5. **`HotkeyMatch.selectType` / `AppDelegate.pickTransitionType` / `TransitionPanelView.tbarTypeButton` 等都删了**：101 叠在本分支上，若有地方还引用老名字会编不过；转场列的新接口是 `slotButtons` / `ftbSplit` / `tbarSlotButton` / `slotMenu(slot:)` / `tbarSlotMenu()` / `ftbMenu()` / `executeSlot(_:)`。
6. **选动作面板的可选开关默认"不改"**（`ActionCatalog.defaults` 对 optional 的 `.onOff` 不给值）：`setInputAudio` 的独听 / AFV 以前默认"开"、不填也会发；带可选开关的新命令照这个口径。
7. 文字工具 `SlotText`（App/Sources/UI/TransitionSlotText.swift）是按钮 / 菜单 / 提示 / 选动作面板 / 格子提示的唯一来源：秒数按**标称帧率**（59.94 → 60，与时长分段同一口径），按钮写"0.5s"、菜单写"0.5 秒"。
8. 本会话量 T-bar 精度用的是直接调 `mouseDown / mouseDragged / mouseUp`（合成 NSEvent），不经窗口派发——锁界面（W5-L）拦的是窗口 sendEvent，这条用例不受影响。

## 6. 运行记录

机器：M5 Max，macOS 27.0（Darwin 27.0.0）。本会话开工时同机没有别的会话在跑重活（`ps -axo comm` 看过，负载 2.5–3.5）。

| 项 | 结果 |
|---|---|
| 红灯轮（控制层 / 兼容层）`swift test --package-path Packages/SwitcherControl` | SwitcherControlTests 45 条 35 处断言红（TransitionSlotActionTests 3 条 25 处 + 已有用例按新口径改的期望）；VMixCompatTests：testC5_transition2ExecutesSlot / setTransitionEffect3MapsToSlot / cutWithInputDuringTransitionIsRefused / cutAndFade（Stinger1）/ http 四条红 |
| 实现后同一命令 | SwitcherControlTests 45、VMixCompat 29（1 跳 = C5 人工）、Tally 3，**0 红** |
| 红灯轮（App）`xcodebuild test -only-testing:` TransitionColumnTests / TransitionPanelTests / ActionPickerTests / ToolbarMenuTests 切换菜单 | 17 条里 TransitionColumnTests 新的 11 条与 TransitionPanelTests 3 条红、ActionPicker 2 条红、切换菜单那条取槽项越界崩（xctest 自动重启后继续） |
| 实现后同一组 | 23 / 23 过（首轮） |
| Stream Deck 红灯 / 实现后 | 新用例先红（`slotSublabel` 不存在，整文件导入失败）；实现后 `node --test test/` 9/9、`scripts/run-jxa.sh` 9/9（中途改了一处我写错的期望："Fade 0.75s" 是 10 个字，按 9 字规则只写效果） |
| 目视（临时用例渲列、不入库） | 1440×900 空闲 / 当前槽 2 / 执行转场 3 + FTB 开 / 最小窗口四张，可见边与两档控件、常亮小条、蓝底白条、红底 FTB、T-bar 行高亮都对（截图在草稿区，没入库） |
| `make test-app` 第 1 遍（12:00） | 235 条 = 227 过、6 跳、**2 红**：InputStripTests 的 transitionGuard / contextMenuComplete 断言老文案"按已选转场送上 PGM（Fade · 2 秒）"——G7 追加 ③ 定成当前槽后括号里写当前槽，改期望（bdd5c3b），单跑 InputStripTests 11/11 |
| `make test-app` 第 2 遍（12:08） | **235 条 = 229 过、6 跳、0 红**（`xcrun xcresulttool get test-results summary --path .build/DerivedData/Logs/Test/Test-Switcher-2026.10.11_12-08-30-+0800.xcresult`）；6 跳：键盘导航没开（C9）、摄像头权限、虚拟摄像头签名、空闲探针（要设环境变量）、ISO A4 / 推流 10 s 两条缺 release frameprobe |
| 补编 `swift build -c release --package-path Tools/frameprobe` 后单跑 ISO A4 / 推流 10 s | 2 / 2 过（负载 5.4，同机当时别的会话也在编） |
| `make lint BRANCH=w5-transition-slots`（报告与问题单提交之后） | 全绿：禁词 / 版本 0.1.0 / Package 约束 / 依赖方向 8 包 / 归属 48 个文件都在范围内（App/、SwitcherControl 的 Hotkeys / VMixCompat / Tests、Tools/streamdeck-plugin、本报告、reports/issues/ 三张）/ check-links 178 个 Markdown / check-rt-symbols |

App 用例数 228 → 235：TransitionColumnTests 8 → 14（86 的四条按槽改写 + 新七条，另三条不变）、ActionPickerTests +1；TransitionPanelTests 3 条按槽改写、数不变。
