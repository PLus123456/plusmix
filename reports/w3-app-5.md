# W3-E4 App 收尾三报告（prompt 73，分支 w3-app-5）

分支：桌面端开的 worktree 分支 `claude/w3-app-5-virtual-camera-47bf08`；prompt 里叫 `w3-app-5`，本地另打同名引用（`git branch -f w3-app-5 HEAD`）给
`check-ownership.sh` 用（同 W3-E3 / P4 的做法）。基于 main `da44bec`（G4 第四轮合入之后：提案 019 的契约与包内填数已落地）。
机器：MacBook Pro M5 Max，macOS 27.0（26A428），Xcode 27.0，接电源，本机装了 NDI SDK for Apple（NDI 两类用例都真跑）。
只动 App/（`scripts/check-ownership.sh w3-app-5 --include-working-tree` 全绿）。

## 1. 做了什么

| prompt 交付 | 落在哪 | 说明 |
|---|---|---|
| 1 虚拟摄像头页去掉"来源"下拉、写明送 PGM | `Settings/OutputSettingsPanel.swift`、两份 `Localizable.strings` | `virtualCameraTab` 里的 `sourcePicker` 换成一行只读的"来源：PGM"（`LabeledContent`）+ 一句说明 `outputSettings.vcam.sourceNote`（"固定送 PGM（节目画面），与录制 / 推流 / NDI 拿的是同一块节目帧；来源不可选"，设计方案 §2 第 5 步 / §3 的数据流）。`OutputSettingsModel.setVirtualCamera(enabled:)` 不再带 source：只管开关（setOutputEnabled），没有虚拟摄像头输出时加一个 source = PGM 的。已存节目里带别的 source（PVW）的虚拟摄像头输出：打开节目照样起消费者、收 PGM 帧、命令 0 条被拒；页上开关不改它的 source（`VirtualCameraOutput` 只发 `frame.program`，改不改都一样，留着不动最省事、也不给节目文件凭空写一笔） |
| 2 两处死路径 | `Settings/OutputSettingsPanel.swift`、`Settings/OutputExtras.swift`（注释） | `setExternalDisplay` / `setExternalFallback` 里的 `s = s.migratingLegacyKeys()` 删了，注释改成"状态机里的状态不会带输出的过渡键（P4 起 addOutput / setOutputSettings / loadShow 进 reducer 都先搬迁），这里只改要改的那一项"。App/Sources 里现在没有任何 `migratingLegacyKeys` 调用（用例扫源码盯着） |
| 3 `AppTest.chineseLiteralViolations` 的 `// l10n-exempt` | `Tests/TestSupport.swift` | **二选一选"修成先看标记"**：整行（剥行尾注释之前）含 `l10n-exempt` 就跳过，`exempt` 表里那个永远匹配不到的 "l10n-exempt" 项删掉。理由：给将来确实不是界面文案的中文字面量留一个显式、code review 里看得见的豁免口子，比删掉说明再让人猜强；现在 App/Sources 没人用它，`testL10n_noHardcodedChineseInUISources` 的结果不变 |
| 4 提案 019 的 App 读法与文案 | `Engine/OutputRuntime.swift`、`Engine/OutputStatusText.swift`、`UI/BottomBarView.swift`、`Settings/OutputSettingsPanel.swift`、两份 `Localizable.strings` | `EncoderStatsSource` 的槽位带输出编号，三处 `statsEntry`（`DiskGuard.statsEntry(for:)` / `StreamCounters.statsEntry` / `NDISendCounters.statsEntry`）与两种 idle 项都填 `output:`；`OutputRuntime.encoderEntry(_:forOutput:)` 改成 `entries.first { $0.output == number }`，`outputs:` 参数删掉（底栏 / NDI 页 / 测试三处调用跟改）——两次采样之间输出表变了也对得准（W3-E3 §4 第 2 条的错一拍没了）。NDI 页状态行：publishing 时在帧数后面加"· 接收方 n"（`ndi.status.connections`）；state = failed 新键 `ndi.status.failed`（"起不来：有 NDI SDK，但初始化 / 建发送实例失败（看日志）"），`ndi.status.unavailable` 改成只说 SDK 不在（"不可用：没有 NDI SDK（装 NDI SDK for Apple 后重新编译）"），两种语言各一键、两句分开 |
| 5（可选）源是输入 n 的 NDI 发送分支用完后自动补上 | `Engine/InputRuntime.swift`、`Engine/OutputRuntime.swift`、`Engine/SwitcherSession.swift`、两份 `Localizable.strings` | **做了 prompt 里说的第一种**：`InputRuntime.releaseBranch` 多一个回调 `onBranchReleased(输入编号)`（App 里所有分支——ISO 录制、Aux 窗口、NDI 发送——都经它还）；`OutputRuntime` 挂上时开不出分支就把 `NDIEntry.branchPending` 记下、提示一次（原来的 `notice.ndiBranchUnavailable`，文案末尾改成"那一路空出分支后自动恢复"）；回调来了（挪到下一轮主线程，不在别人的收尾栈里插手）→ `retryPendingNDIBranches(input:)` 给在等的那几路重新开分支 + tap、挂到引擎，成功一路发一个新事件 `.ndiBranchRestored` → 提示"已重新接上、开始送画面"（`notice.ndiBranchRestored`）。摘下（停 / 换源）时清标记；那一路换来源 / 删掉仍由 `reconcileNDI` 摘下重挂，不在重试里管 |

提交见 `git log main..HEAD`（每条交付一个提交，最后一个是本报告）。

## 2. 每个测试：数值 / 阈值 / 通过否

### 2.1 本会话的用例（函数名带交付编号 W3E4_n；先写用例再实现，红灯轮见 2.2）

| 交付 | 测试 | 数值 | 判据 | 通过 |
|---|---|---|---|---|
| 1 | `VirtualCameraAppTests.testW3E4_1_virtualCameraPageSendsPGM_noSourcePicker_savedShowWithOtherSourceStillPGM` | 源码里 `virtualCameraTab` 无 `Picker(` / `sourcePicker(`、有 `outputSettings.vcam.sourceNote` + `source.program`；两种语言的说明都含 "PGM"、英文无中文；页上开 → 输出 source = PGM、消费者起来；关 → 命令日志里没有 setOutputSettings；**存一份 source = PVW 的虚拟摄像头输出的节目打开：消费者起来，1.5 s 收 74 帧**，Stats.display[] 有这路（waitingExtension），0 条命令被拒，页上关 / 开后 source 仍是 PVW | 收帧 > 60（60 fps × 1.5 s 留余量）、被拒 0 | ✅ 2.0 s |
| 2 | `PanelTests.testW3E4_2_externalDisplayPageWritesOnlyTheChangedField_noLegacyMigrationInApp` | App/Sources 里 `migratingLegacyKeys` 调用 0 处；故意带过渡键的模型状态：改显示器 / 退回 / 来源发出的三条 setOutputSettings 只改那一项、extra 三个键原样；端到端 API addOutput 带过渡键 → 页面拿到的状态 display = (3, fallbackToMain true)、extra = [:] | 0 处调用；extra 原样；页面状态无旧键 | ✅ 0.3 s |
| 3 | `LocalizationTests.testW3E4_3_l10nExemptMarkerHonoredBeforeStrippingComments` | 9 行样例（两处裸中文、一处带 `// l10n-exempt`、注释 / NSLog / 整行注释 / 多行字符串各一）→ 只报第 1、9 行 | 恰好那两行 | ✅ |
| 4 | `EncoderStatsLookupTests.testW3E4_4_encoderEntriesCarryOutputNumber_lookupByOutput_ndiConnectionsAndFailedText` | 纯函数按编号对号（含"输出 1 刚删、encoder 还有三项"的过期行）；活的：录制 1 + 推流 + NDI（不开）→ `encoder.map(\.output)` = [1, 2, 3]、三项 idle、录制项 disk_free_mb > 0、推流项 0；删录制 → 下一行 [2, 3]，过期行按编号对推流仍是它自己；NDI 页给一行顺序颠倒的 Stats → 状态行「发送中 · 1200 帧 · 接收方 2」、「发送中 · 1300 帧 · 接收方 0（队列丢 1）」；四个 state 两种语言各有文案、互不相同、英文无中文，unavailable 含"装"+"SDK"/ "install"+"SDK"，failed 含"日志"/"log" 且不含"装"/"install" | 逐项相等 | ✅ 2.3 s |
| 4（有 SDK） | `NDISendAppTests.testNDI_sendLoopbackReceivesPGM_statsEncoderFromSender`（加了 019 断言） | `e.output` = 输出编号 2；回环输入连上后 **Stats.encoder.connections = 1**，NDI 页状态行 = 同一行 Stats 的文案「发送中 · 220 帧 · 接收方 1」；原有断言照过（回环落后 PGM 1–2 帧、码率 1963 Mb/s、dropped = skipped = 0） | connections ≥ 1；状态行 = OutputStatusText.ndi(同一行) | ✅ 4.9 s |
| 5（可选） | `NDIBranchRetryAppTests.testW3E4_5_ndiInputSourceBranchExhausted_noticeOnce_reattachesWhenBranchReturned` | 占满输入 2 的 4 个分支再加源 = 输入 2 的 NDI 发送：sender running、无 tap、`branchPending`；**提示 1 次**；切 PGM + 改转换方式后仍 1 次、sender 同一个；还 1 个分支 → 5 s 内接上、**转发 31 帧**（等到 > 30 就停）、分支数回到 4、"重新接上"提示 1 次；删输出后分支数 = 3、全还掉 = 0；被拒 0 | 提示恰 1 + 1 次；转发 > 30；分支数 4 / 3 / 0 | ✅ 1.8 s |

改了断言 / 调用的旧用例：`PanelTests` 三处 `setVirtualCamera(enabled:)`（去掉 source 参数）与外部显示页用例的注释；`NDISendAppTests` 的 `encoderEntry` 辅助改两参签名。

### 2.2 红灯轮（证明用例抓得到老行为）

实现写完后把交付 2 / 3 / 4-文案 临时退回 main 的版本（两处 `migratingLegacyKeys()` 放回、`TestSupport.swift` / `OutputStatusText.swift` checkout），只跑这三条：
**3 / 3 红**，红的位置就是各自要验的点——2：源码扫描报 `OutputSettingsPanel.swift:224 / :237`、三条命令的 extra 少了两个旧键；3：`Sample.swift:2 "豁免的中文"` 被报出来；
4：状态行没有"接收方"、failed 两种语言都原样回显 "failed"。交付 1 / 5 引入新 API（`setVirtualCamera(enabled:)`、`branchPending`、`onBranchReleased`），退回去是编不过，不必再演。
退回的文件之后按备份原样恢复，`git diff --stat` 与退回前一致。

### 2.3 定向轮（实现后，第一次跑）

`xcodebuild test -only-testing:` 上面 5 条 + 它们所在的类 + `StatusLineTests` + `AccessibilitySourceScanTests`：**20 个用例 19 过 1 跳（L1 虚拟摄像头出口 BLOCKED-签名，原有）、0 失败**，23 s；本地化 718 条（+4 键）。

### 2.4 全量 `make test-app` 两轮（开跑前 `pgrep -fl "xcodebuild .*test"` 都查过没有别的会话在跑 App 测试）

`make test-app` 的 xcodebuild 带 `-quiet`，"Test Case … passed" 一行都不打，退出码 0 只说明没有失败；计数从 `.build/DerivedData/Logs/Test/*.xcresult` 用
`xcrun xcresulttool get test-results summary` 读（§5 第 8 条）。

| 次 | 时间 | 结果 | 说明 |
|---|---|---|---|
| 1 | 18:36:49–18:40:24（测试段 214 s） | **86 个：84 过、2 跳、0 失败** | 红灯轮之后用 `cp` 恢复的两个源文件重编，xcodebuild 各报一行 "the following command failed with exit code 0 but produced no further output"（swift-build 的假报错，产物正常、测试照跑）；机器空（负载 2.7） |
| 2 | 18:41:46–18:45:20（测试段 213 s） | **86 个：84 过、2 跳、0 失败** | 同机 W4-B 会话在它的 worktree 里跑 `xcodebuild -resolvePackageDependencies`（不是测试、不重）；负载 1.5 |

跳过的两条两轮相同、都是原有的：`testInputs_builtInCameraLiveWithin5sAndPictureShows`（BLOCKED-权限：测试宿主没有摄像头权限，解锁 = 系统设置里给它摄像头权限）、
`testL1_virtualCameraEgress_requiresSignedExtension`（BLOCKED-签名：解锁 = Team ID 签名 + /Applications + 允许扩展）。
release 版 frameprobe 已编（本 worktree 钉版本的 Package.resolved），ISO A4 / 推流 10 s 那几条这两轮都真跑了、没有 BLOCKED-工具的跳过。
上一轮 W3-E3 的 App 全量是 81 个；本会话 +5（W3E4_1–5）= 86。

### 2.5 lint

`git branch -f w3-app-5 HEAD && make lint BRANCH=w3-app-5`：禁词 / 版本号 / Package.swift 约束、依赖方向（8 个包）、归属（16 个文件都在 App/）、`check-rt-symbols` 全绿。

## 3. 没做的和原因

1. **虚拟摄像头输出的 source 字段不清理**：已存节目里带 PVW / 输入 n 的 source 原样留着（运行时只看 kind 与 enabled，`VirtualCameraOutput(format:)` 也没有来源参数）。要"洗"成 PGM 就得在打开节目时发 setOutputSettings 或改 Show.load 的搬迁（契约），prompt 只要"照样当 PGM、不报错"，不多做。
2. **状态行的"编码跳帧 / 码率先看录制 / 推流"仍按顺序给类型**（`BottomBarView.apply(stats:)` 给 `StatusLineFormatter` 的 `kinds` 是"与 encoder 同序的输出类型"，个数对不上就退回不分类型）：019 之后可以改成按 `output` 查类型，但这条不在 prompt 的四条里，且个数对不上时的退路本来就有；留给下一个 App 会话（§5 第 3 条）。
3. **第 5 条的"分支重试"只覆盖 App 里经 `InputRuntime.releaseBranch` 还回来的分支**——ISO 录制停、Aux 窗口关、别的 NDI 发送摘下都是这条路；包里没有别的地方直接碰 `InputFrameTee.removeBranch`（InputFrameTee 归 SwitcherISO，App 之外只有测试用）。

## 4. 对契约的疑问

1. 没有新的契约变更请求。019 的 App 侧读法按提案落地：`output` 缺键 = 0 的老 stats.jsonl 行在 App 里对不到任何输出（App 只读自己实时的 Stats，不读老文件，所以没影响）；API 客户端按 `output` 对号即可。
2. `Stats.EncoderEntry` 的 NDI state 值表（publishing / idle / unavailable / failed）只写在 `Stats.swift` 注释与 CONTRACTS.md §2.7，契约里没有像 `DisplayEntry.states` 那样的常量数组，App 的文案覆盖用例只能自己列这四个值（`EncoderStatsLookupTests`）。要不要给 EncoderEntry 也加一个 `ndiStates` 常量方便各方对表，请契约会话看着办（不急、不影响功能）。

## 5. 下一个会话需要知道的坑

1. `OutputRuntime.encoderEntry(_:forOutput:)` 没有 `outputs:` 参数了：别的分支若还在调老签名（`forOutput:outputs:`），合并时改成两参即可（语义只是从"按顺序"到"按编号"）。
2. `OutputSettingsModel.setVirtualCamera(enabled:)` 不带 source；`sourcePicker` / `sourceChoices` / `sourceNote` 仍在（外部显示页、NDI 页用）。
3. 状态行的 `kinds`（W3-E3）仍按顺序对号（§3 第 2 条）；想改就在 `BottomBarView.apply(stats:)` 里按 `stats.encoder.map(\.output)` 查 `state.outputs` 的 kind，`StatusLineFormatter.activeEncoder` 的参数形态可以顺手改成 `[Int: OutputKind]`。
4. `InputRuntime.onBranchReleased` 是单个闭包、由 `OutputRuntime.init` 设，谁再想听"分支还回来"要改成数组扇出（同 `AuxOutputRuntime.observeExtensionStatus` 的做法），别直接覆盖。回调在还分支的调用栈上同步发，OutputRuntime 那头已经挪到下一轮主线程。
5. `// l10n-exempt` 现在真的起作用了：App/Sources 里任何一行带这几个字都不会被 `testL10n_noHardcodedChineseInUISources` 扫到，code review 时留意新出现的标记。
6. 两个会话同时跑 App 测试会互相踩（W3-E2 §5 第 2 条、W3-E3 §5 第 2 条）：本会话每轮开跑前 `pgrep -fl "xcodebuild .*test"` 都查了。
7. NDI 的两条回环 / 设置页用例与本会话的 `NDISendAppTests` 增补都要本机 NDI SDK；`NDIBranchRetryAppTests` 不要 SDK（分支 / tap 是 App 侧接线，没 SDK 时 sender 是空实现、tap 的转发计数照走）。
8. **`make test-app` 的输出看不出跑了几个用例**：Makefile 给 xcodebuild 加了 `-quiet`，"Test Case … passed / skipped" 与 "Executed N tests" 都不打，只剩警告；退出码 0 = 没有失败，
   计数要从 `.build/DerivedData/Logs/Test/Test-Switcher-<时间>.xcresult` 读：`xcrun xcresulttool get test-results summary --path <bundle>`（总数 / 过 / 失败 / 跳），
   `… get test-results tests --path <bundle>` 能列到每条的结果与 XCTSkip 的原因（注意读过之后 bundle 的 mtime 会变，别再按 `ls -t` 取"最新"）。要看用例逐行输出就别用 make，直接 `xcodebuild … test`（不带 -quiet）。
   另：源文件刚改过（内容 / mtime）紧接着编，Xcode 27 的 swift-build 会对那几个 SwiftCompile 各报一行 `error: the following command failed with exit code 0 but produced no further output`——
   假报错，产物正常、测试照跑、退出码仍是 0（G4 也记过 "Xcode 27 swiftbuild"）。我一开始把这两样叠在一起判成"测试静默中止"，白跑了一轮才去读 xcresult。日志留在本会话 scratchpad（不入库）。
