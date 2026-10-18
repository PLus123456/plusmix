# W2-C4（prompt 116）控制层止血：D02 / D03 兼容层崩溃、⇧1–⇧0 实体键盘、MIDI 的 029 提示、D17 Stream Deck 重配 + 文案

分支 `w2-control-4`（= harness 分支 `worktree-agent-a84a572d9b82a2312`，worktree `.claude/worktrees/agent-a84a572d9b82a2312`），从 G9 合入后的 main 358517f 开。
不 push、不 merge，交 G10（prompt 122）。机器：M5 Max，macOS 27.0.1，Xcode 27.1（Swift 6.4），Node 26.9.0；同机并行 117 / 119 / 121。

## 1. 做了什么

每条先按 Codex 审查 / 问题单的触发条件写用例复现（红），再改实现。

| 项 | 改了什么 | 提交 |
|---|---|---|
| 1 D02 兼容层空输入 | `InputReference.resolve` 只解成一路**存在的**输入：`Input=0` / `-1`（当前 PVW / PGM）是黑场、或指着已经不在的输入（`MixerState.validate` 不查引用）一律 `InputNotFound`，文案点明"当前 PVW / PGM 落空"；所有按 Input 取输入的函数都走它（FunctionTranslator 过了一遍：Cut / Fade / Wipe / Zoom / PreviewInput / SetPreviewInput / ActiveInput / CutDirect / SetInputName / SetVolume / Audio* / AudioBus* / Solo* / SetBalance / OverlayInput*）。翻译器与 ACTS 里的 `state.input(x)!` 换成"找不到即抛"的 `inputConfig` / `requireInput`，叠加 / 槽下标加越界判断：**VMixCompat 里不再有强制解包**（grep `!` 只剩注释） | 82bbe91 |
| 2 D03 兼容层时长溢出 | 毫秒参数（Fade / Wipe / Zoom 的 `Duration`、`SetTransitionDuration1–4` 的 `Value`）只收有限、0 ≤ v ≤ 3 600 000 的数，换拍用 `Int(exactly:)`，越界 / 非数 / 无穷 → `BadParameter`（400），文案给出可收范围。**顺带**（同一种转换的反方向，过 VMixCompat 时查出来）：XML 状态把槽的拍数换毫秒原来也是 `Int(…)`，主 API 的 `setTransitionSlot` 只拒负数，超大 `durationTicks` 让 Companion 每 250 ms 的 XML 轮询一连上就崩——改成封顶在 Int.max | 82bbe91 |
| 3 ⇧1–⇧0 | `KeyCombo(event:)` 带 ⇧ 且键码是数字行 / 美式符号键（kVK_ANSI_0…9、`- = [ ] \ ; ' , . /` 与 `` ` ``）时按键码表取不加 ⇧ 的字符，与布局 / 输入法无关。文本解析与 `init(key:modifiers:)` 把带 ⇧ 的符号写法规范成它所在的键（美式 `!@#$%^&*()_+{}\|:"<>?~`、全角写法、拼音另外打出的 `¥ … — 「 」 《 》`）：录键录下的旧 `shift+!` 读进来是 `shift+1`、照样能用、写回是新写法；不带 ⇧ 的不动。旧行规范化后与表里原来那行 `shift+1` 撞了：留录下的那行（原来按得出来的是它）、停用撞上的行——在 `HotkeyTable` 解码时做，hotkeys.json 与 App 的设置导出包（先解码整包、再编码回来交给 load 查）走同一条路；两条都是旧写法的照旧报冲突 | 2b1696e、499ea2b |
| 4 MIDI 的 029 提示 | `MIDIController.setFeedbackHandler`（照 `HotkeyDispatcher`，同一个 `ControlFeedback`、同一套判定）：派发 Task 里命令被总线拒时按拒的那一刻的快照走 `ControlAction.rejectionFeedback`（`.stingerWithoutInput(slot:)`），音符解析不出时走 `unresolvedFeedback`（`.overlayNeedsPreview`，与 ⌃n 同一句，接收线程上同步调）；别的拒绝只记计数。`MIDIMapper.noteAction(for:)` 给它用。App `ControlRuntime` 让快捷键与 MIDI 共用同一个回主线程的反馈闭包（+6 / −4 行，只动反馈那一段）→ 状态行"转场 n 是 Stinger、还没选输入——在转场列 ▾ 里选一路" | eaf6d2d、6edec27 |
| 5 D17 Stream Deck 重配 | 先做可测改法（行为不变，单独跑过 node / JXA 10/10）：`api-client.js` 不再 import `ws`，WebSocket 构造函数与计时器由调用方给（`plugin.js` 给 `ws` 的；用例给假 socket / 假计时器），`run-jxa.sh` 把它也拼进 JXA 包（垫一个只有 on / emit 的 EventEmitter）。再修：`open()` 的 open / message / error / close 回调先认连接（`this.ws === 这条 socket`），不是当前这条就什么都不做；`close()` 把发在这条连接上还没回执的命令作废（它后到的 close 不再管它们）；`reconfigure` 清掉旧那台的快照与时钟。"没连上"报错与断开日志用产品名 | e9d2631 |
| 5′ W4C3 第 13 条 | `ui/auto.html` 的选项改"执行当前转场槽（Auto）"、`manifest.json` 的 Auto 提示"执行当前转场槽，或指定时长的 Fade"；问题单点名的是 `ui/slot.html` 的标题与"地址"，但六个面板是同一块全局"地址"设置（W4-D 改名时没动 `ui/`），一起把标题、"地址"、connection.html 的说明换成 PlusMix（手册早就写"设置面板里填 PlusMix 地址"）；UUID / 目录名 / npm 包名仍是代码名 | bdc601c |
| 6 校验 | `swift test --package-path Packages/SwitcherControl` 整包；`node --test test/` + `scripts/run-jxa.sh`；`make lint BRANCH=w2-control-4`（C 与 UTF-8 两种 locale）；`switcher-apidoc` 重生成与 `docs/api.md` 逐字一致、仍 42 条（兼容层函数描述在 VMixCompat 的 FunctionCatalog，没改，也不进 api.md），所以 `docs/api.md` 没动 | — |

探针（铁律 10，⇧ 那一条）：`CGEvent(keyboardEventSource: .privateState, virtualKey:, keyDown:)` 造事件、`NSEvent(cgEvent:)` 转，**不投递**；输入源只读（TIS）。本机当前输入源 `com.apple.inputmethod.SCIM.ITABC`（键盘布局 `com.apple.keylayout.PinyinKeyboard`）：
- ⇧1–⇧0 的 `charactersIgnoringModifiers` = `！ @ # ¥ % …… & * （ ）`；⇧ 符号键 = `—— + 「 」 ｜ ： " 《 》 ？ ～`；⇧A = `A`；⌥1 / ⌃1 / ⌃⌥4 = 数字本身；小键盘 ⇧1 = `1`。
- **⇧1 的 `！` 是 U+FF01，落在 `KeyCombo(event:)` 原来"≥ U+F700 当功能键私有码点不收"的那一段里，原来直接给 nil**：拼音输入法下 ⇧1 / ⇧9 / ⇧0 与 ⇧\ / ⇧; / ⇧/ / ⇧`（全角 `！（）｜：？～`）连组合键都没有（设置里录不了，按了也不派发），不只是"对不上"；别的 ⇧ 数字组合成 `shift+@`、`shift+¥`、`shift+…` 这类。
- `characters(byApplyingModifiers: [])`（= UCKeyTranslate 不带 ⇧）对数字给 ASCII 数字，但对 `[ ] \ ; , . `` ` `` 给的是拼音布局的全角 / 中文标点（`【 】 、 ； ， 。 ·`），所以选键码表、不选 UCKeyTranslate：键名永远是 JSON 里人写的 ASCII，美式 / 拼音一样。

## 2. 测试 ID：数值 / 阈值 / 通过否

本会话没有带阈值的测试 ID（都是行为用例），没动任何阈值；3 600 000 ms 是 prompt 给的参数可收范围，不是测试阈值。"红"一栏是改实现之前同一条用例的结果（单独 `--filter` 跑，崩溃的那几条 xctest 进程以 signal 5 退出）。

| 用例 | 断言的东西 | 修前（红） | 修后 |
|---|---|---|---|
| `CompatHardeningTests.testD02_inputZeroOrMinusOneOnEmptyPreviewOrProgramIsInputNotFound` | 三种落空状态（空节目 / PVW·PGM 黑场 / 悬空编号）× 25 个按 Input 取输入的函数 × Input = 0 / −1 / 99 → `InputNotFound`、HTTP 404、文案点明 PVW / PGM；审查原样四条 + `Audio Input=99`；PVW / PGM 是真输入时 0 / −1 照旧解成它；不带 Input 的 Cut / Fade 照旧 | 118 处断言失败，然后 `FunctionTranslator.swift:159: Fatal error: Unexpectedly found nil` → signal 5 | 过 |
| `CompatHardeningTests.testD02_http_tcp_emptyShowAudioFunctionsAnswerInputNotFound` | 真服务、空节目：HTTP 9 个请求（四组音频动作 + SetVolume + `Audio&Input=99`）都 404 `InputNotFound:`、一条命令不进总线；TCP `FUNCTION Audio Input=0` → `FUNCTION ER InputNotFound:`、PING 照答；`GET /api` 200；functionErrors = 10 | 第一条请求 signal 5（`FunctionTranslator.swift:159`） | 过 |
| `CompatHardeningTests.testD03_durationMillisecondsMustBeRepresentable` | 500 ms = 30 拍、0 ms = 0、上限 3 600 000 ms = 216 000 拍、`1e3` 照收；12 种坏值（`3600000.6` `3600001` `-1` `-0.6` `nan` `NaN` `inf` `-inf` `1e309` `1e300` `9.3e18` `abc`）× 7 个函数 → `BadParameter`、400、文案含可收范围；240 fps 上限 = 864 000 拍不溢出 | 105 处断言失败，然后 `Double value cannot be converted to Int because the result would be greater than Int.max` → signal 5 | 过 |
| `CompatHardeningTests.testD03_http_hugeDurationAnswersBadParameter` | 真服务：`Fade&Duration=1e300` / `SetTransitionDuration1&Value=1e300` / `Wipe&Duration=1e300` / NaN / −1 都 400 `BadParameter:`、一条命令不进总线、槽 1 时长没变；控制组 `SetTransitionDuration1&Value=500` 200、XML 写 500 | 第一条请求 signal 5 | 过 |
| `CompatHardeningTests.testD03_statusXMLSaturatesHugeSlotDuration` | 槽时长 Int.max / Int.max ÷ 16（换毫秒才越界）→ XML `duration` 封顶 Int.max、文档照常生成；90 拍 @60 = 1500 ms；没有槽时写当前那组也封顶 | signal 5（同上 Int 转换） | 过 |
| `ShiftKeyComboTests.testW2C4_shiftDigitFromRealKeyboardEventMatchesDefaultTable` | **真键盘事件**（CGEvent，本机拼音输入法）⇧1–⇧0 → `shift+1…0` → 默认表直切 PGM 1–10；⌥⇧ / ⌃⇧ 数字；⇧ + 11 个符号键 → 美式不加 ⇧ 的名字；不带 ⇧ / ⌥ / ⌃ 数字、⇧ 字母、小键盘 ⇧1 照旧 | 51 处（⇧1 组合成 nil、⇧2 = `shift+@`……） | 过 |
| `ShiftKeyComboTests.testW2C4_shiftKeysSameUnderUSAndPinyinInput` | 同一键码、美式 / 拼音 / "数字要按 ⇧"布局三套字符（合成事件）→ 同一个组合键；符号键美式 / 拼音两套 | 42 处 | 过 |
| `ShiftKeyComboTests.testW2C4_legacyShiftedSymbolSpellingsNormalize` | 38 种旧写法（含 `⇧!`、`Shift+@`、全角、拼音的 `¥ … — 「 」 《 》`、`alt+shift+#`、`ctrl+shift+！`）规范成新写法；`init(key:modifiers:)` 同口径；不带 ⇧ 的 `!` / `alt+(` 不动；旧表 `shift+！` 读进来 = `shift+1`、写回新写法、真 ⇧1 事件派发到它 | 83 处 | 过 |
| `ShiftKeyComboTests.testW2C4_legacyShiftRowCollidingWithDefaultRowKeepsRecordedRow` | 默认行 `shift+1` + 录下的 `shift+!` → 不报冲突、⇧1 = 录下的那行、默认行停用、别的行不动；包在别的结构里解码（设置导出包）同一个结果、编码回来再 load 不报冲突；两条都是旧写法 → 照旧报冲突（allowConflicts 能读） | 3 处 | 过 |
| `MIDIFeedbackTests.testW2C4_midiNoteRunningStingerSlotWithoutInputGivesFeedback` | 虚拟源真 CoreMIDI 发 Note On 执行转场 4（出厂 Stinger 没选输入）→ 反馈 `[.stingerWithoutInput(slot: 4)]`、rejected 1、PGM / PVW 不动、没执行；选中槽 4 后执行当前槽同一句；输入不存在的拒绝不说；叠加空通道 + PVW 黑场 → `.overlayNeedsPreview(1)` 且一条不发；Note Off 不响；选了输入照常执行 | 7 处（先接空壳 `setFeedbackHandler`：被拒计数 1、反馈为空） | 过 |
| App `W2C4ControlFeedbackTests.testW2C4_midiStingerSlotRefusalShowsStatusLineNotice` | App 测试宿主、虚拟 MIDI 源发 Note On 执行转场 4 → `session.lastNotice` 与底栏状态行 = "转场 4 是 Stinger、还没选输入——在转场列 ▾ 里选一路"、被拒计数 +1、没执行、PGM / PVW 不动 | 2 处（状态行 nil、底栏空；被拒 / PGM 不动那几条本来就过） | 过 |
| Stream Deck `cases.js`"SwitcherClient 改连接设置（W2-C4 / D17）…" | 旧 socket 后到的快照 / 出错 / close 一概不碰新连接（不收快照、不记日志、不当成断开、不排重连、不作废新连接的命令）；Cut 发到第二条；再 `open()` 不出现第三条、任何时候只有一条开着；旧连接没回执的命令作废、旧快照清掉；改 token 第二条关掉、第三条起来同样不受第二条后到的 close 影响；当前连接自己断了照旧 disconnected + 2 s 后只重连一条 | node 11 中 1 红、JXA "1 failed"（第一处"旧连接上没回执的命令作废"）；另用同一套假 socket 跑审查的顺序（草稿区脚本）：旧 close 后 connected=false / ws=null / 排了重连、"没连上"、`open()` 后 3 条 socket、第二条没关——与审查一致 | 过 |

整包 / 全量：
- `swift test --package-path Packages/SwitcherControl`：93 = 92 过 + 1 跳（`C5CompanionScriptTests.testC5_manualCompanionSession_servesWhenRequested`，人工 C5，要设 `SWITCHER_COMPAT_SERVE_SECONDS`）+ 0 红（SwitcherControlTests 54、VMixCompatTests 36、TallyTests 3；G9 时 83，新加 10 条）。
- Stream Deck：`node --test test/` 11/11、`scripts/run-jxa.sh` 11/11；`node --check` 过 `plugin.js` / `api-client.js`（没装依赖，跑不了 SDK 接线）。
- App（只跑本会话那一条 + 控制层相关类；等另一个 worktree 的 App 测试（xcodebuild + PlusMix 测试宿主）跑完、机器上没有别的 xcodebuild / 测试宿主时跑）：37 = 37 过——W2C4ControlFeedbackTests 1、ActionPickerTests 5、ControlEditorTests 3、ControlWiringTests 3、ShortcutAndShowTests 10、StartupOrderTests 4，单条：ToolbarMenuTests 两条快捷键菜单、TransitionColumnTests 两条、InterfaceLockTests、LiveSafetyTests.testHotkeys_stopRecordNeverAsks、W5OFollowupTests 的 W5O4 / W5O8 两条、SettingsWindowTests 的快捷键关窗 / 导出导入两条。计数来自 xcresult。**没跑 App 全量**（prompt：119 在跑全量，G10 合入后跑）。
- `make lint BRANCH=w2-control-4`：全绿（禁词 / 版本号 / Package.swift / 依赖方向 / 归属 26 个文件都在范围内 / 随包手册 / 链接 / 实时符号），C 与 UTF-8 两种 locale 各一遍。

## 3. 没做的和原因

1. **D01**（主 API 的 rate / seek 校验）：115 在 CommandBus/ 做，没碰 CommandBus/。
2. **手册**：`docs/user/快捷键.md` / `en/shortcuts.md` 里"⇧1–⇧0 在实体键盘上对不上（绕法：逐行重录键）"那条与 hotkeys.json 写法一条该删 / 改，归 W4-C；`docs/integrations/vmix-compat.md` 第 127 行"`0` = 当前 PVW、`-1` = 当前 PGM"要补"PVW / PGM 是黑场（或指着已删的输入）时回 404 InputNotFound"，Fade / Wipe / Zoom 的 Duration 与 SetTransitionDuration1–4 的 Value 要写"0…3 600 000 ms，超出 400 BadParameter"——docs/ 不在本会话目录。KNOWN_ISSUES 的 D02 / D03 / D17 / ⇧1–⇧0 四行与"112 留下的"那一行的 MIDI 部分销号归 G10。
3. **没在实体键盘上按过**：CGEvent 真事件用例只覆盖本机当前输入源（拼音）；美式那一套是合成事件（键码相同、字符按美式），**没有切系统输入源去造美式 CGEvent**（会改用户正在用的系统设置）。L3 清单人工确认时请在美式与拼音下各按一次 ⇧2（问题单第 7 条原话）。Stream Deck 同样没碰真设备，只有受控事件顺序。
4. **过 VMixCompat 时看到、没修的**（不在交付里，要定口径）：输入编号没有上限（`addInput` 只查 ≥ 1、不重复），主 API 加一路编号很大的输入（例如 2⁶²）之后，兼容层的 TALLY 串 `reserveCapacity(最大编号)`、XML 按 1…最大编号逐个写占位——开着兼容层就是分配失败崩 / 卡死。修法二选一：校验器给输入编号定上限（CommandBus/ 归 115 / 契约，`Input` 编号范围算不算契约要用户定）；或兼容层只写到某个上限（会改 TALLY / XML 的形状，上游客户端按位置取）。没写红用例（不修就不留一条必红的）。
5. **拼音输入法下不带 ⇧ 的标点键**：`, . ; [ ] \ ` `` ` `` 打出 `， 。 ； 【 】 、 ·`（`，` `；` 还落在 ≥ U+F700 那一段、给 nil），绑 `[` / `,` 这类键的行在拼音下按不出来；默认表没有这种键，prompt 只管 ⇧，没扩范围。要修就是"符号键不带 ⇧ 也按键码取"，会改法语 / 德语这类布局下不带 ⇧ 的键名，请定。
6. `VMixCompatConfiguration.edition = "Switcher"`（W4D 问题单第 3 条，兼容层 XML `<edition>`）在本会话目录里，但 prompt 没列，没动。

## 4. 对契约的疑问

1. 没有要改契约的地方：SwitcherContracts 一个字没动。新增的公开 API 都在 SwitcherControl：`MIDIController.setFeedbackHandler(_:)`、`MIDIMapper.noteAction(for:)`；`HotkeyTable` 改成手写 `init(from:)`（JSON 键名 `version` / `bindings` 不变）。`ControlFeedback` 本来就是 SwitcherControl 的类型、不进 wire format。
2. **prompt 写的状态码与现有口径不一致，按现有的来了，请确认**：D02 写"→ 400 InputNotFound"，但兼容层 `InputNotFound` 一直是 HTTP **404**（`CompatErrorCode.httpStatus`、`docs/integrations/vmix-compat.md` 的错误表、`testC5_unimplementedFunctionsReturnExplicitErrors` 都钉着），审查的控制组 `Audio Input=99` 也是 404——所以 0 / −1 落空也回 404 `InputNotFound`。D03 写"→ 400 BadValue"，兼容层没有 BadValue 这个码，用的是现有的 `BadParameter`（400）。要统一成 400 / 新码请说。
3. **Input=0 / −1 落空对切换类函数的口径**：prompt 说"所有按 Input 取输入的函数"，照做了——PVW 黑场时 `Cut Input=0` / `Fade Input=0` / `ActiveInput Input=0` 现在回 404，原来是"把黑场放进 PVW 再切"（= 不带 Input 的 Cut）。审查说切换类"可单独保留黑场语义"；不带 Input 的 Cut / Fade 照旧能把黑场切上去。要给切换类留黑场语义请说（几行）。
4. **旧 ⇧ 写法撞键时停用默认行**：读进来时自动把撞上的那行（例如默认 `shift+1` 直切 PGM 1）停用、留用户录下的那行——不改文件，用户在设置里保存时那行会存成 `"enabled": false`。另一种做法是报冲突让用户自己选（但 App 读不进整张表会退回默认表），按"录下的行照样能用"选了前者，请确认。

## 5. 下一个会话需要知道的坑

1. **⇧ 的键名现在一律是"不加 ⇧ 的那个键"**：事件（键码表）、JSON 解析、`KeyCombo(key:modifiers:)` 三处同口径；写新用例 / 默认键时写 `shift+1`、`shift+=`，别写 `shift+!` / `shift++`（读进来也会变成前者）。非美式布局（法语、德语）⇧ + **符号键**拿到的是美式键位的名字（录键与派发一致，能用），但那些布局上**以前**录下的 ⇧ 符号行可能对不上、要重录（例如法语 `shift++` 规范成 `shift+=`，而那个键现在给 `shift+/`）；⇧ + 数字在所有布局上都是 `shift+数字`。
2. **CGEvent 用例依赖本机当前输入源**：拼音下走的是全角那条路、美式下走 `!` 那条路，两种都必须过；不投递事件、不要辅助功能授权。别在用例里切系统输入源。
3. `HotkeyTable` 现在手写 `init(from:)`：以后加存储属性要同时加 `CodingKeys` 和这里的解码。撞键处理在解码时做，`load` 只查版本与冲突。
4. 兼容层 `Input=` 现在保证解成存在的输入，翻译器里拿配置用 `ctx.inputConfig(_:)`，别再写 `state.input(x)!`；毫秒参数一律走 `ctx.durationTicks`（范围常量 `FunctionTranslator.durationMillisecondsRange`）。
5. **Stream Deck**：`api-client.js` 不再 import `ws`，`new SwitcherClient({ WebSocket })` 由 `plugin.js` 传——不传的话 `open()` 里构造失败、只会每 2 s 静默重试。`cases.js` 的用例在 JXA 里跑（没有事件循环、没有 setTimeout），一律同步断言，Promise 的结果不要等；`run-jxa.sh` 现在把 tally.js、api-client.js、cases.js 三个拼在一起，新加的 lib 文件要 import 别的东西得在它前面垫上。
6. MIDI 反馈两个入口：被拒在派发 Task 里（任意线程）、解析不出在 CoreMIDI 接收线程上同步调；App 的 `ControlRuntime` 快捷键与 MIDI 共用一个闭包、都 `DispatchQueue.main.async` 回主线程。
7. 同机：本会话跑 App 用例前等了另一个 worktree 的 App 测试（xcodebuild + PlusMix 测试宿主）跑完，跑的时候只有别的会话的包测试（TestKit / Inputs）在跑；兼容层用例用端口 0（系统分配），不撞端口。Bash 里带 `for` 变量 / 复杂 heredoc 的命令在隔离 worktree 里会被拒，脚本写进草稿区 `w2c4/` 再跑（runtests.sh / apptest.sh 在那里）。
