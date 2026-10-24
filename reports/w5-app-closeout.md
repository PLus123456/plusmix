# W5-Q（prompt 126）App 收口：老节目越界速率的提示 / 竖拍文件信息 / D06 两个边角 / 030 的界面展示

分支 `w5-app-closeout`（= harness 分支 `claude/brave-tharp-63fca8`，worktree `.claude/worktrees/brave-tharp-63fca8`，两个名字指同一提交），
从 main 2ec2c05 开（G10 快进后的 1f9be64 + 一个只加 reports/ 审计存档的提交；`git merge-base --is-ancestor 1f9be64 HEAD` 成立）。
只动了 App/ 和本报告。不 push、不 merge，交 127 G11。同机并行：123 / 124 / 125（全量那两遍时 125 在跑音频包的用例，§6）。

prompt 126 的 G10 追加：交付 1 的速率数字框钳位（`AddInputModel.clampedFileRate`）与交付 5（`ISOAppTests` 断言 `passA4 == true`）G10 胶水已做，本会话**没有重做**；
交付 1 只做"打开含越界速率的老节目时提示"。

## 1. 做了什么

| 项 | 改了什么 | 提交 |
|---|---|---|
| 0 先写红 | 新 `App/Tests/W5QCloseoutTests.swift` 9 条（W5Q1 ×3、W5Q2、D06 ×2、030 ×3）。为了编得过、在运行时按真实行为红，先加了不改行为的接缝：`AppController.lastPresentedError`（测试宿主不弹窗，用例看它）、启动恢复抽成 `AppController.restoreAtLaunch`（原样 `try?`，纯搬家）、`ShowDocuments.readAutosave`（`loadAutosave` 改成 `try?` 它）、030 三个读数的桩。修之前实跑 9 条全红（§2 红一列） | 2d6fc13 |
| 1 **老节目越界速率**（裁定 #2 (c) 剩下的一半） | `ShowDocuments` 读文件 / 读 LastSession 时把契约的 `MixerStateError.fileRate`（只带第一路、枚举原样）换成 `OutOfRangeFileRates`：不校验地再解一遍，越界的几路连名字一起列——"输入 3（片头）的播放速率 10 超出 0.1–8；输入 5（慢放）的播放速率 0.05 超出 0.1–8。这一版的播放速率只收 0.1–8 倍，越界的老节目不打开：用文本编辑器把节目文件里这几路的 "rate" 改到范围内再打开。"（数按 %g 写，与 FileInput 钳速率的提示同一写法）。`presentError` 用 `LocalizedError.errorDescription`（别的错照旧原样）。三条路都不再静默：节目 › 打开（D04 事务里原有的错误路径，跑着的节目 / 保存目标不变）；节目 › 打开上次退出时的节目（原来 `loadAutosave` 的 `try?` 吞掉、点了没反应）；启动恢复（上次的文件 → LastSession → 空节目，原来两处 `try?` 静默退；现在每份打不开的提示一句、照旧往下退）。老节目**不钳、照旧不打开**（裁定是 (c) 不是 (b)） | c94e6e9 |
| 2 **竖拍文件信息**（117 §3） | `MediaFileInfo.loadMovie` 的尺寸那一段：先写转正后的尺寸（FileInput 出帧的尺寸），宽高互换的片子把编码尺寸放括号——"H.264 · 240×320（编码 320×240） · 30 fps · 0:01 · 没有声音"。包里的 `FileInfo` 只能从打开了的 FileInput 拿（memberwise init 不公开、没有探测入口），所以用同一个公开归类 `FileOrientation(transform:)` 判 `swapsAxes`，编码尺寸改取格式描述（`CMVideoFormatDescriptionGetDimensions`，与 `FileInfo.width / height` 同一来源；原来是 naturalSize）。认不出的方向矩阵（任意角度）FileInput 按原样出，摘要也只写编码尺寸；没有方向矩阵的片子照旧一个尺寸 | 6d57e88 |
| 3 **D06 边角一**：录着 ISO 删掉这一路再加同编号 | `OutputRuntime.reconcile` 每次看一眼：ISO 录制开分支的那个 tee（`RecordEntry.sourceTee`，attach 时记下）已经不是这一路现在的 tee（删了；删了又加同编号也是新 tee）→ `stopForInputRemoved`：录制器停在 removeInput 的生效拍（`OutputCommandTicks` 新记 removeInput 的 appliedTick；主线程看到快照之前已经录进去的一两拍撤不回，Recorder 按已收帧往后取整，实测 +3 拍），提示"ISO 录制 2 停了：输入 1 删掉了（停在删除那一拍；再加同编号的输入不会接着录，要录再开一次）"；同 `stopForDisk` 置 failed、发 stopRecord 让快照关掉——新的一路不接旧录制器，也不按"仍 enabled"自动再起一个录新的一路。原来旧录制器挂在没人推的分支上每拍重复最后一帧、定格到手动停 | e7e27aa |
| 3 **D06 边角二**：换源瞬间别的路注册 | ISO 音轨（与源是输入 n 的 NDI 发送的音频）挂在泵的 `.input(n)` 上；泵按来源共享一个 tap、加第一个消费者时把编号换成混音器槽位、之后不换（包里的口径）。换源时新环若落到别的槽位，tap 还在旧槽位上、录到占了它的别人。现在音频消费者包成 `OutputRuntime.AudioAttachment`（录制 / NDI 的 `audioToken` 换成它，推流照旧只挂 Master），`AudioInputRegistration` 每注册上一路回调 `onRegistered`，`followInputAudioSlots` 对一遍：这一路现在的槽位与挂上时的不同 → 这一路的消费者全部摘下（泵里这个来源没人要了才摘旧 tap），注册着就按现在的槽位重挂；此刻没注册（换源重试中 / 新来源没有声音）就先空着——录制器按时间轴补静音，不录别人。槽位没变（最常见：换源后按后进先出拿回原来那个）什么都不动 | e7e27aa |
| 4 **030 的界面展示**（裁定 #1 之后） | 读 Stats 的 `audio.effects`（1 Hz，与 stats.jsonl / API 同一份；铁律 4）：音频设置窗常规页加"效果链延迟"（这条链已打开格的延迟之和，一位小数；没收到 Stats 写 —，Stats 不列的输入写"0 ms（没装效果）"），压缩页"延迟自测"改读 `measured_latency_ms`（帧数按 48 kHz 从毫秒换回，原来那句话不变："延迟自测：0 帧（0.00 ms）——压缩器不用前瞻，按设计是 0"）；`PanelCoordinator` 每行 Stats 喂开着的音频设置窗、开窗先给最近一行。推流 / 录制状态窗底部"视频延后"上面加一行"效果链延迟：Master 12.0 ms · Bus A 0.0 ms（压缩器实测 0.00 ms） · Bus B 0.0 ms · 耳机 0.0 ms · 输入 3 话筒 0.0 ms（压缩器实测 0.00 ms）"——总线列几条看 Stats 本身（G10 胶水起是四条，不靠 `listedBuses`），装了效果的每路一项、名字从快照对号。`MixerMeters` 删掉两份压缩器延迟的拷贝（不再读 `AudioEngineStatus` 的这一项；电平表照旧读 50 ms 那一份） | 18f1d24 |

改了的老用例：`W5OFollowupTests.testW5O6_compressorPageSimpleModeAndLimiterCeiling` 原来从 `MixerMeters.busCompressorLatencyFrames / inputCompressorLatencyFrames` 读"延迟自测"，改成读 `session.stats` 的 `audio.effects` 与 `compressorSelfTestText`——断言不变（Stats 里有实测值、按设计 0 帧、那一行等于 `L("audioSettings.compressor.latency", 0, 0.0)`、动态处理器不显示），等待从"50 ms 状态"变成"下一行 Stats"（≤ 5 s 里等）。

目视（临时截图用例，看完删了）：音频设置窗 Master 常规页"效果链延迟 12.0 ms"、输入 3 常规页"0.0 ms"、Bus A 压缩页"延迟自测：0 帧（0.00 ms）"；状态窗那一行在"视频延后 12 ms"上方，900 宽一行放得下。

## 2. 测试 ID：数值 / 阈值 / 通过否

本会话的用例都是 App 行为用例，没有测试标准里的阈值；没动任何阈值、没跳过断言。"红"是实现之前那一遍的实跑（scratchpad `results/red1`，D06 边角二改过用例后在修之前的代码上另跑了 `red3b`）。

| 用例（`W5QCloseoutTests`） | 红（修之前） | 绿（数值） | 通过 |
|---|---|---|---|
| `testW5Q1_openShowWithOutOfRangeRatePromptsInUIWording` | 弹的是 `fileRate(input: 3, rate: 10.0)`（只说第一路、枚举原样；4 处断言红） | 上下文"打开 旧节目.switcher.json"、正文"输入 3（片头）的播放速率 10 超出 0.1–8；输入 5（慢放）的播放速率 0.05 超出 0.1–8。这一版……"；跑着的节目、保存目标不变 | ✅ |
| `testW5Q1_openLastSessionWithOutOfRangeRateIsNotSilent` | 没有任何提示（`try?` 吞掉），什么都不发生 | 上下文"打开 上次退出时的节目"，正文同上；跑着的节目不变 | ✅ |
| `testW5Q1_restoreAtLaunchWithOutOfRangeRatePromptsEachAndFallsBack` | 两份都打不开时提示 `[]`、静默退到空节目 | 两份各提示一句（上次的文件 → LastSession）、返回 nil（空节目）；LastSession 换成好的：提示一句、恢复 LastSession（untitled、输入 [1]） | ✅ |
| `testW5Q2_portraitFileInfoShowsDisplaySizeWithCodedSizeInParentheses` | "H.264 · 320×240 · 30 fps · 0:01 · 没有声音" | "H.264 · 240×320（编码 320×240） · 30 fps · 0:01 · 没有声音"；同一文件加成一路后 FileInput.info：display 240×320、编码 320×240，逐项对上 | ✅ |
| `testD06_isoInputRemovedThenReAddedStopsRecorderAtDeletionTick` | 删掉之后 8 s 内旧录制器一直不停（定格到手动停） | 删除拍 #49、文件止于 #52（+3 拍；用例上限 6 拍 = 0.1 s）、起 #10、42 帧 = 起止拍差（无洞）；提示"ISO 录制 2 停了：输入 1 删掉了……"；录制目标回 false；再加同编号后 0.5 s 不再起录制器、新 tee 分支数 0；rejected 0 | ✅ |
| `testD06_isoAudioFollowsInputNumberWhenAnotherInputTakesItsSlot` | 输入 1 槽位 0 → 1、静音的输入 2 拿到 0；ISO 尾段（停前 0.9–0.15 s）RMS **0.0**（录到输入 2） | 同样的槽位变化；尾段 RMS **0.0795**（输入 1 的 1 kHz −20 dBFS 正弦，两声道平均）；开头对照 0.034–0.039；两轨等长（±800 样本）；同一个录制器录到底。门限 0.01（静音是 0） | ✅ |
| `test030_audioSettingsRowsReadStatsEffects` | 延迟自测停在"还没量到"、效果链延迟 —（6 处） | Bus A 实测 0.5 ms → "延迟自测：24 帧（0.50 ms）……"、效果链延迟 0.5 ms；Master 12.0 ms（没装压缩器不显示那一行）；输入 3 1.3 ms、实测 0 帧；没装效果的输入 1"0 ms（没装效果）" | ✅ |
| `test030_outputStatusListsEffectLatencies` | 没有这一行（nil） | "效果链延迟：Master 12.0 ms · Bus A 0.5 ms（压缩器实测 0.50 ms） · Bus B 5.3 ms · 耳机 0.0 ms · 输入 3 话筒 1.3 ms（压缩器实测 0.00 ms） · 输入 4 背景 0.0 ms"；effects 缺键（老 stats）不显示 | ✅ |
| `test030_effectLatencyShownFromSessionStats`（真引擎） | 延迟自测"还没量到"、状态窗 nil | Bus A 装压缩器、Master 一格限幅：延迟自测 = `session.stats` 里 Bus A 的 measured_latency_ms（0 帧）、状态窗那一行含 Master 的 latency_ms（12.0 ms）；rejected 0 | ✅ |
| `W5OFollowupTests.testW5O6_compressorPageSimpleModeAndLimiterCeiling`（改读 Stats） | — | Master / 输入 1 的实测都是 0 帧，那一行与原来同一句话 | ✅ |

整套 App（`make test-app`；`-quiet` 吞用例行，计数用 `xcrun xcresulttool get test-results summary`）：G10 是 296 条，本分支 +9 条 = **305 条**。

| 遍 | 时间 / 结果包 | 结果 | 红的那条 | 判定 |
|---|---|---|---|---|
| 1 | 14:28 `Test-Switcher-2026.10.24_14-28-20-+0800` | 305 = 300 过 + 4 跳 + **1 红** | `ToolbarMenuTests.testUI_toolbarItemsMirrorMenuActions`："关闭全部外部显示"3 s 内没生效 | KNOWN_ISSUES 环境红名单原文就是这一句（P5-2 时在干净 main 上也红过，疑似测试宿主协作式激活下不在前台）；单独复跑 `ToolbarMenuTests` 10 / 10 过。外部显示那条路本分支没碰 |
| 2 | 14:36 `Test-Switcher-2026.10.24_14-36-58-+0800` | 305 = **302 过 + 3 跳 + 0 红** | — | ✅ |
| 3 | 14:44 `Test-Switcher-2026.10.24_14-44-27-+0800` | 305 = 301 过 + 3 跳 + **1 红** | `RecordingTests.testRecord_5sTwoTracksDurationExact`：起止拍差 318 vs 按钮间隔 316.68 拍，差 1.32 帧 > 1 | 计时类、负载下 ±1 帧过线（G7 §10 第 8 条、G8 §10 第 3 条记过）；当时 125 的音频包实时用例在跑（负载 3.4）。单独复跑 1 / 1 过（318 拍 vs 318.4） |
| 4 | 14:55 `Test-Switcher-2026.10.24_14-55-01-+0800`（等 125 那一轮音频包用例退了才开，负载 ≈ 1） | 305 = **302 过 + 3 跳 + 0 红** | — | ✅ |

**两遍 0 红：第 2 遍与第 4 遍**（第 1、3 遍各一条名单里的环境红，都单独复跑过；没为它们改任何用例）。

跳过的都是老的：键盘导航 BLOCKED-系统设置、空闲唤醒探针（要 `SWITCHER_IDLE_PROBE_MINUTES`）、虚拟摄像头 BLOCKED-签名；第 1 遍多跳一条内置摄像头 BLOCKED-权限（TCC 还没授权），第 2 遍起有了权限、跑过了。

## 3. 没做的和原因

1. **交付 1 的数字框钳位、交付 5（ISOAppTests 看 passA4）**：G10 胶水已做（reports/G10.md §4.3 ⑤ / ④），按 prompt 126 的 G10 追加没有重做。
2. **老节目不钳**：裁定 #2 选的是 (c)（App 数字框钳）不是 (b)（读文件时钳进范围），所以越界的老节目照旧打不开，本会话只把"打不开"说清楚。
   要能打开得改 `Show.migratingLegacyKeys()`（契约，归 P5 系），本会话不碰。
3. **启动恢复的提示范围比 prompt 宽一点**：上次的文件 / LastSession 读不出来，原来不论什么原因都静默往下退；现在**任何**读不出来都提示一句再往下退
   （不只越界速率——坏 JSON、读不了的文件同样提示）。理由：同一条 `try?`，只为速率开口子反而怪；行为上只是多一个提示框，恢复顺序不变。
4. **统计窗（底栏"统计"）没加效果链延迟**：prompt 写的是"音频设置窗 / 状态窗"，状态窗按本仓库的叫法是推流 / 录制状态窗（底部本来就有"视频延后 n ms"，效果链延迟放在它上面一行）。
   统计窗的"音频"一节要不要也列，看用户 / 下一张 App prompt。
5. **D06 边角一：同一个 16 ms 轮询里删了又加同编号、来源一模一样**：快照合并后输入表的编号 + 来源都没变，`InputRuntime` 不重建这一路（同一个 tee、同一个输入对象），
   运行时根本没有"删除"，ISO 照旧接着录。没改（要改得让 InputRuntime 认快照之外的事件，牵涉面大，而且接着录也是对的画面）。
6. **D06 边角二的第二种撞法没有单独的用例**：新环注册正好落在旧槽位 detach 之后、实时线程确认回收之前（这时空闲表里没有旧槽位，新环直接拿到别的槽位，不需要别的路插进来）。
   窗口只有一两个混音块，用例撞不准；修法对两种撞法是同一条（`followInputAudioSlots` 在这一路自己注册上来时也对一遍），用例覆盖的是"别的路插进来"那一种。
7. **源是输入 n 的 NDI 发送**：重挂对它同样生效（同一个 `.input(n)` 来源必须整组摘下才会换 tap），但没有单独的 NDI 用例（本机没有真接收端时 NDI 用例只看发送侧计数，判不出音频来自哪一路）。
8. **手册**：不在本会话目录。手册可能要跟的五处写在共享笔记 `126-w5-app-closeout-ui-changes.md`（给并行的 124 W4-C4 / 127 G11），§5 第 7 条也列了。

## 4. 对契约的疑问

没有要改契约的地方，下面两条是给包里的建议，不挡合入：

1. **泵的 `.input(n)` 只在第一个消费者加进去时把编号换成槽位**（W1-D 系，`ConsumerPump.add`）：组装方在换源 / 重注册之后要自己把整组消费者摘下重挂，
   App 现在这么做了（D06 边角二）。headless（`HeadlessRun`）没有换源，不受影响。若音频包让泵按编号每块解析槽位（或注册时自己迁 tap），App 这一段可以删——归下一张音频会话看值不值。
2. **`FileInfo` 没有公开的探测入口**（W2-A 系，`FileAsset` 是 internal、`FileInfo` 的 memberwise init 不公开）：App 的文件信息摘要只能用同一个公开归类
   `FileOrientation(transform:)` 自己判宽高互换，口径靠用例（W5Q2 拿真 FileInput 的 `info` 逐项对）钉住。若 SwitcherInputs 给一个 `FileInput.probe(path:) -> FileInfo`，摘要可以直接读它。

## 5. 下一个会话需要知道的坑

1. **换源时音频通常直接拿回原槽位**：合成源新输入对象建出来要十几毫秒，比摘除淡出（3 块 ≈ 16 ms）还长，`replaceSource` 里的新环注册多半当场成功、按后进先出拿回原来那个槽位，
   根本不走 30 ms 重试（我第一版用例以为会撞上淡出，`retries` 一直是 0）。要稳定复现"换槽位"得先单独 `AudioRuntime.unregister` 把窗口拉开（W5Q 的 D06 边角二就是这么做的）。
2. **别把一路输入的旧环直接再注册**：摘下期间生产者照写、没人读，环里是过期的数据，重注册之后混音器那一路一直是静音（我第二版用例这样做，尾段 RMS 0.0 不是修法的问题）。
   要新环就走真的换源（setInputSource），replaceSource 会建新输入、新环。
3. **"源码里写死中文"的扫描**（`LocalizationTests.testL10n_noHardcodedChineseInUISources`）只放过 NSLog / print 等那一行：把中文当参数传进自己的函数（如 `label: "录制 \(n)"`）也算违例。
   日志里要写对象名就用 `consumerName`。新键要在 App/Sources 里字面出现（`testL10n_everyKeyInTableIsReferenced`），两份表的占位符一致。
4. **SwiftUI 面板截图**：`AppTest.screenshot`（cacheDisplay）对推流 / 录制状态窗出白图；测试宿主里 `screencapture -l` 不出文件（没有屏幕录制授权）；
   用 SwiftUI 的 `ImageRenderer` 离屏渲染那个 View 能看到字（分段控件 / 菜单画成占位）。音频设置窗用 cacheDisplay 正常。
5. **`presentError` 现在用 `LocalizedError.errorDescription`**：抛给界面的错要是带人话的就实现 `LocalizedError`（如 `OutOfRangeFileRates`），别的错照旧 `"\(error)"`。
   测试宿主不弹窗，看 `AppController.lastPresentedError`（上下文, 正文）。
6. **`MixerMeters` 没有压缩器延迟了**：音频设置窗的"延迟自测"与"效果链延迟"读 `AudioSettingsModel.apply(stats:)` 喂进来的 Stats（PanelCoordinator 每行喂、开窗先给最近一行）；
   用例里等它要等下一行 Stats（1 Hz），别等 50 ms 的表。
7. **手册（124 / G11）**：老节目越界速率的提示（三条路）、竖拍摘要"240×320（编码 320×240）"、ISO 那一路被删时的提示与"再加同编号不接着录"、
   音频设置窗常规页"效果链延迟"、状态窗"效果链延迟"那一行；`docs/user/概念.md:194` 的"延迟自测：0 帧（0.00 ms）"写法仍对。
8. **G11 合入**：本分支只动 App/（13 个文件，+690 / −66 左右，含 377 行新用例）与本报告；新测试文件 `W5QCloseoutTests.swift`，合入后先 `make gen`。
   `OutputRuntime` 的 `RecordEntry` / `NDIEntry` 的 `audioToken` 换成了 `audio: AudioAttachment?`——别的分支若也动这两处会冲突（123–125 不碰 App/ 的这几处）。
9. **123 的提案 032 合入之后**（共享笔记 `123-p5-contracts-5.md`）：节目文件里有 > 16 的输入编号，契约 validate 抛新的 `MixerStateError.inputNumber(input:)`、不打开——
   App 的打开 / LastSession / 启动恢复会把它原样弹出来（`inputNumber(input: 17)`），与本分支修掉的 `fileRate(…)` 同一类问题。main 上还没有这个 case，本分支编不进去；
   G11 合入 123 之后可按 `OutOfRangeFileRates` 同一做法在 `ShowDocuments.load` 加一个 catch（≤ 15 行，App 胶水额度内）。123 笔记里"新输出编号 = 最大 + 1 在 Int.max 时溢出崩"那四处本分支没碰。
