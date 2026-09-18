# W2-B2 App 接线（把 W2 五路真接进主界面）报告

分支 `claude/w2b2-app-wiring-729a22`（桌面端开的 worktree 分支；prompt 里叫 `w2-app-2`，本地另打了同名引用 `git branch -f w2-app-2 HEAD` 给 `check-ownership.sh` 用）。
基于 main `2fdf52d`（P2 契约落地合入后），本会话提交 `9b151b3` … `e1c5a74` + 本报告。
机器：MacBook Pro M5 Max，macOS 26.6.2（25G83），Xcode 27.0（27A266a，Swift 6.4），接电源，只有内置屏；机器 load 2–3。

## 1. 做了什么

只动了 `App/` 和 `project.yml`（后者 4 行，越界，见 §4 第 1 条）。G3 清单末表（docs/checklists/G3.md）的七个接缝全部接上：

| 接缝 | 落在哪 | 行数 | 说明 |
|---|---|---|---|
| 1 `InputFactory` | `App/Sources/Engine/InputFactory.swift`（新）、`InputRuntime.swift`（改）、`AudioRuntime.swift`（新，注册部分） | 121 + 89 + 85 | `.camera / .screen / .file / .image` 用 W2-A 的 `init(config:timing:videoSlot:audioRing:)`；`ProgramTiming(format:t0:)` 引擎 start 前 = 引擎 t0，之后 = "现在之后第 3 拍"（`SwitcherSession.programTiming`，同合成源）；带音频的路（摄像头自带麦克风、屏幕 captureAudio、文件、合成源 audio）建 `CAudioRing` 交给输入并 `audioEngine.registerInput(number:ring:hints:)`（hints.producerBlockFrames：摄像头 1024 / 屏幕 960 / 文件 256 / 合成 256）；合成源的视频时间线提前半帧、click 时间线不提前（`SyntheticPairInput` 包一层，A2 才对）；`PlaceholderInput` 只剩 DeckLink / NDI / 纯音频（W3-A）。同一编号刚摘掉还在淡出时重新注册会撞 `inputAlreadyRegistered`，30 ms 后重试（最多 10 次） |
| 2 命令 / 快捷键 | `Engine/ControlRuntime.swift`（新）、`UI/MainWindowController.swift`、`UI/Shortcuts.swift`（删） | 149 | `SwitcherSession.send` → 一条串行队列 → `CommandBus.submit(_, source: .ui)`（不能每条命令各开一个 Task：抢 sequence 会把 setProgram / setPreview 颠倒）；`MainWindow.keyDown` → `HotkeyDispatcher.handle(KeyCombo(event:))`（用户表 `~/Library/Application Support/Switcher/hotkeys.json`，读不出来提示并退默认表；测试宿主固定默认表）；回执 `applied == false` → 状态行右侧提示"命令被忽略：…"，结构性被拒 → "命令被拒：… — 理由"（4 s 后清掉） |
| 3 API / MIDI | `ControlRuntime.swift`、`App/Sources/AppSettings.swift`（新） | （同上）+ 85 | `StateFeed` + `APIServer`（默认 127.0.0.1:8765；`--api-listen host:port` / `--api-token` / `--no-api` 与 UserDefaults 键 `apiListen` / `apiToken` / `apiEnabled`，设置面板是 W3-E 的，面板做好后改同一组键）；起：feed → API → MIDI（API / MIDI 起不来只提示不算错）；停：API → 输出封口 → 输入 → 引擎 → 音频 → feed。`MIDIController(bus:table:)` 起来即可（用户表 midi.json / 空表） |
| 4 音频 | `Engine/AudioRuntime.swift`、`UI/MixerPanelView.swift` | 85 + 65 改 | 六步同 headless：建（`--audio-device default|null|<名字>` / UserDefaults `audioOutputDevice`；建不起来退空设备并提示）→ 每路 `registerInput` → `addConsumer(录制 / 推流, source: .master)` → `engine.audioStatsProvider = { audioEngine.audioCounters }` → `start(clock: spec)`（引擎 start 之前）/ `stop()`。调音台 Master：读数文字 + A1 从 Stats.audio（1 Hz，提案 004），表的条子每 50 ms 读 `AudioEngineStatus`（Stats.swift 自己写明 UI 高刷新率的表另读这一份） |
| 5 录制 | `Engine/OutputRuntime.swift`（新，录制部分约 200 行）、`UI/BottomBarView.swift` | 438（含推流 + Stats 表）+ 114 改 | 录制按钮 → `startRecord` → `Recorder`（配置来自 Show 的 record 输出，文件名 `RecordSettings.outputURL(showName:outputName:)`，相对目录挂到 ~/Movies/Switcher 下）。起止都是拍：起始拍 = startRecord 生效拍 + 10（总线观察者 `OutputCommandTicks` 记 appliedTick），边界拍 = stopRecord 生效拍 + 10，两头一样长 → 时长 = 两条命令生效拍之差。封口不停引擎：`FrameGate` / `AudioGate` 在边界上关门 → 等含边界的音频块送到（边界 + 对齐延迟 + 2 块 + 6 ms）→ 摘音频消费者 → `stop(atTick:)` → 摘帧消费者。按钮三态从 Stats.encoder[i].state 来（"录制" / "录制 · idle|stopping|failed" / "● 录制中"） |
| 6 推流 | `OutputRuntime.swift`（推流部分约 70 行） | — | 推流按钮 → `StreamOutput(configuration:transportFactory: HaishinKitTransportFactory)`（Show 的 stream 输出），`start()` + 挂帧 / 音频消费者；停 = 摘消费者 + `stopAsync()`。底栏按钮按 Stats.encoder[i].state：publishing → "● 推流中"，connecting / backoff → "推流 · 重连中（第 n 次）"（n = reconnects + 1），其他 → "推流 · <state>"。P2 已落地，state / reconnects 都从 Stats 读，不读 `StreamOutput.counters` |
| 7 Stats | `Engine/StatsHub.swift`（新，替换 `StatsPump.swift`）、`UI/StatusLineFormatter.swift` | 65（−70） | `StatsPublisher(engine:interval: 1)` 是唯一采样线程；三个消费者：`StatsWriter`（`--stats`）、`StateFeed.publish(stats:)`（API）、主线程（状态行 / 调音台）——同一行。`Stats.encoder` 与 outputs 里带编码器的输出同序（`EncoderStatsSource`）：没在跑的报 idle（录制输出照报 disk_free_mb），停了的报 stopped / failed 直到再起。状态行：编码跳帧 / 码率取第一个真在跑的输出，磁盘取第一个报了 disk_free_mb 的（P2 前显示 —） |

其他：`AppSettings`（启动参数 + UserDefaults）、`AddInputSheet` 的占位文案换成权限提示、菜单"切换"列出当前快捷键表、`ShowDocuments.recordDirectory`（测试宿主录到临时目录，不碰 ~/Movies）。

真跑过（Debug，`open -n Switcher.app --args --show <2 路 30 fps 合成源> --stats …`，从 Finder 路径起、真音频设备）：API 在 8765 起来，GET /state 的 stats 带两项 encoder（record idle 报磁盘剩余 1.6 TB、stream idle）、Master −20 dBFS；POST startRecord / stopRecord 录出 242 帧 = 1326 − 1084 拍、两轨 4.033333 s；render 0.9 ms、CPU 56%。stats.jsonl 头 3 s 的丢帧见 §5 第 1 条。

## 2. 测试（`xcodebuild test`，SwitcherTests 25 个：24 过 1 跳，约 80 s；`make lint BRANCH=w2-app-2` 只剩 project.yml 一条越界）

| 测试 | 数值 | 阈值 | 通过 |
|---|---|---|---|
| 现有 14 个 | 全过（快捷键表、占位、状态行字段、冒烟第 12 步按新接线改，见下） | 仍绿 | ✅ |
| 内置摄像头 5 s 内 live、缩略图有画面 `testInputs_builtInCameraLiveWithin5sAndPictureShows` | **BLOCKED-权限**：从 Claude 的 Bash 起的 xcodebuild，责任进程没有摄像头用途说明，系统不弹提示直接拒（`.notDetermined` 停在"等待系统提示"）。解锁：从 Terminal.app 跑 `make test-app`（或 `xcodebuild test -only-testing:SwitcherTests/InputWiringTests`），第一次弹授权点允许；测试自己会等 5 s live、再等 6 s PGM 不黑、看缩略图 blit > 0，并打印 L1 现象（到达余量 / latency_ms / dup / drop） | live ≤ 5 s；画面不黑 | ⏸ |
| pattern.mov 循环，帧号在走 `testInputs_patternMovLoopFrameNumbersAdvance` | PGM 纹理读回解出帧号 8 → 69（1 s 走 61 帧）；Stats.per_input[1].fps ≈ 60；定位到 9.6 s 后 1 s 内回绕到 < 120；音频环已注册 | 1 s 走 40–80 帧 | ✅ |
| 图片每拍刷新 `testInputs_imageRefreshesEveryTick` | PGM 中心像素 = 图片色 (200, 40, 90) ± 12；帧槽 1 s push 61 帧 | 50–70 | ✅ |
| 录 5 s `testRecord_5sTwoTracksDurationExact` | 起 #85 止 #385 = 300 拍，视频 300 帧 / 音频 240000 样本 = 5.0000 s；按钮间隔 5.000 s；ffprobe 无错、两轨，视频 5.0 s / 300 帧、音频 5.0 s；编码 skipped 0；rec.start 花 64–80 ms；停止后按钮回"录制"（另一次运行 301 拍 / 301 帧 / 240800 样本，按钮间隔 5.004 s） | 无错、两轨、5 s ± 1 帧；两轨差 ≤ 20 ms | ✅ |
| API `testAPI_stateMatchesSnapshotAndPostCutSwaps` | GET /state 的 program 1 / preview 2 == 快照，stats 是同一行；POST `{"command":{"cut":{}}}` 200、applied true，快照对调，PGM 纹理里的图案 ID 0 → 1；GET /tally 一致；总线记录来源 api | applied true、画面对调 | ✅ |
| 快捷键空格 `testHotkey_spaceCutsThroughBusAndCounts` | 总线 applied +1，dispatcher handled +1，记录来源 hotkey、命令 cut、applied true；PGM / PVW 对调 | 计数 +1 | ✅ |
| 回执提示 `testFeedback_ignoredAndRejectedCommandsShowNotice` | `ftb(on: false)`（已关）→ "命令被忽略"，bus.ignored 1；`setPreview(9)` → "命令被拒"，bus.rejected 1，状态没变 | — | ✅ |
| 音频引擎起停 20 次 `testAudio_engineStartStop20TimesNoCrashRSSFlat` | 20 轮新建节目（旧引擎 + 音频引擎停、新的起）：不崩，RSS 292 293 293 … 294 MB（热身后 15 轮 +1 MB；另一次运行 212 → 231，热身后 +5 MB） | 不崩；热身后增长 < 40 MB | ✅ |
| Master 表 / FTB `testAudio_masterMeterReadsAndFTBDropsToSilence` | Stats.audio.meters master 峰值 −20.00 dBFS（1 kHz −20 dBFS 合成音频），调音台 "−20.0 dBFS"，条子有电平；FTB 开 → −120（显示 −∞ dBFS）；关 → 回 −20；A1 0 / 0 / 0 | 有读数；FTB → −∞ | ✅ |
| 推流到本地 MediaMTX 10 s `testStream_10sToLocalMediaMTX_framesContinuous` | 测试自己起 mediamtx（RTMP 23935）；连上后 10 s Stats.encoder：publishing、frames 645、dropped 0、skipped 0、reconnects 0；停后按钮回"推流"；frameprobe stats 落盘 645 帧、丢 0（缺口 0）、重复 0、解不出 0 | 帧号连续 | ✅（码率只有 224 kb/s：灰底合成源，E2 不适用，G3 已记） |
| 启动参数 `testSettings_argumentsOverrideDefaults` | 参数覆盖 UserDefaults；`--no-api`；`--api-listen` 打开 API；空 token = 关；设备名解析 | — | ✅ |

改过的旧测试：`testShortcuts_defaultTable` → `testHotkeys_defaultTableResolvesThroughDispatcher`（同一组按键经 `KeyCombo(event:)` + `HotkeyDispatcher` 解析：数字 / Shift 数字 / 空格 / 回车 = autoTransition / F = FTB 开关；⌘ 组合、自动重复、没绑定的键不吃；默认表 23 条）；`testShow_unsupportedInputKindIsPlaceholder` 改用 NDI（摄像头现在走真实现：假 uniqueID = 无信号或权限文案）；`testStatus_formatterFields` 的 encoder 项带 state / disk_free_mb（P2 之后 idle 项不算"在跑"）；冒烟第 12 步真录一段（14 帧）到测试宿主的临时目录。

### 人工检查（docs/checklists/G3.md，用户做；做完把数字填在这里）

前提：`make gen build-app`，打开 `.build/DerivedData/Build/Products/Debug/Switcher.app`（从 Finder / `open` 起才有 TCC 提示；上次打开的节目已清掉，会开一个空节目）。本会话已经把清单里"App 没接 … 的等价做法"都变成了 App 自己的动作。

- [ ] 1.1 启动：主窗口、底栏状态行每秒刷新（fps / render / GPU / CPU / 丢帧 / 编码跳帧 / 码率 / 磁盘——磁盘现在有数：默认录制输出所在卷的剩余）。
- [ ] 1.2 添加输入：合成源（60 fps 带音频）→ 1；内置摄像头 → 2（第一次弹摄像头 + 麦克风授权）；`Tests/Fixtures/pattern.mov` 循环 → 3。三格出画面、tally 边框对。摄像头出画面前的黑屏秒数：____（W2-A 量到 4.2 s，归 W1-B2）。
- [ ] 1.3 键盘 2 → 空格 → 3 → 回车（Fade 30 拍 T-bar 自己走）。命令被忽略时右上角会提示一句（例如转场进行中再按回车）。
- [ ] 1.4 T-bar 拖到 50% 停住 / 到顶对调回弹 / 没到顶停原位。
- [ ] 1.5 F 键 FTB：PGM 渐黑、标题 "PGM · FTB"、**Master 表落到 −∞（读数和条子都落）**；再按一次渐出。
- [ ] 2.1 底栏"录制" → "● 录制中"（Stats 报 recording 那一秒起，≤ 1 s）；拍手 5 次；2 分钟后停 → 按钮回"录制"，右上角提示文件名和帧数。文件在 ~/Movies/Switcher/<节目名>-<日期>-<时间>.mov。
- [ ] 2.2 QuickTime：时长 2:00 ± 1 帧（起止拍 = 两次按钮之间的拍差）、拍手与画面同帧（±1 帧）。
- [ ] 2.3 `ffprobe` 无错、两轨时长差：____ ms（本会话自动测试里 5 s 文件两轨完全相等；W1-E 的"多写 50–150 ms 音频"在 App 里被 AudioGate 挡掉了）。
- [ ] 3.1 `mediamtx scripts/mediamtx.yml`；节目文件里加一路 stream 输出（`"stream": {"url": "rtmp://127.0.0.1:1935/s1"}`，设置面板 W3-E）→ 底栏"推流" → "● 推流中"。
- [ ] 3.2 `ffplay rtmp://127.0.0.1:1935/s1`：帧号在走、闪光每秒一次、延迟 < 2 s：____ s。
- [ ] 3.3 `sudo scripts/netem.sh block 1935 30`：按钮变"推流 · 重连中（第 n 次）"（Stats 里只有 state / reconnects，没有"x s 后"，见 §4 第 3 条），放开后 ≤ 15 s 恢复：____ s，帧号连续。
- [ ] 4 拖窗口 / 全屏 10 s 丢帧不增（自动测试已覆盖内置屏；外接屏 BLOCKED-硬件）。
- [ ] 5 `curl -s http://127.0.0.1:8765/api/v1/state | python3 -m json.tool | grep -E '"program"|"preview"'` 与标题条一致；`curl -s -X POST http://127.0.0.1:8765/api/v1/command -d '{"command":{"cut":{}}}'` 画面立刻对调、applied true；`/api/v1/tally` 对。
- [ ] 6 USB 摄像头拔插 3 次（BLOCKED-硬件 如无）。
- [ ] 7 摄像头延迟感（只记录）：头几秒黑屏 ____ s，挥手延迟感 ____。

## 3. 没做的和原因

- **摄像头的自动测试没在本会话跑过**（BLOCKED-权限，见 §2）；代码路径与文件 / 图片相同（同一个工厂、同一个 InputRuntime），差的只是 TCC。
- **设置面板 / 每路音频条子 / 输入设置窗 / 推流设置**：W3-E（prompt 明说不做）。API 端口 / token / 音频设备 / 推流地址现在分别靠启动参数 + UserDefaults 键、节目文件。
- **Wipe / Zoom / Stinger**：W3-B。
- **屏幕输入没有专门的自动测试**：需要屏幕录制授权（和摄像头一样在 Claude 的 Bash 下拿不到），工厂里接法与摄像头相同，用户人工检查时加一路屏幕即可。
- **推流断网重连的 App 级自动测试**：W2-D 的 E8 已经在 StreamingTests 里覆盖（同一个 StreamOutput 对象），App 只是把状态显示出来；清单 3.3 人工看。
- **摄像头到达余量**：不在 App 里关（prompt 第 8 条），现象记进 §5 第 1 条和 `reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md`。

## 4. 对契约 / 规则的疑问

1. **`project.yml` 越界（4 行）**：App 目标原来只链接 `SwitcherAudio` / `SwitcherOutputs` 两个产品，`AudioEngine` 在 `SwitcherAudioIntegration`、`StreamOutput` 在 `SwitcherStreaming`，不加 `product:` 依赖就 import 不到（Xcode 只编被链接的产品，SwiftPM 不会顺带把同一个包的其他 library 暴露给 App）。接缝 4、6 没有别的办法，所以直接改了；`make lint BRANCH=w2-app-2` 只剩这一条。**请用户裁定**：给 W2-B2 行加 `project.yml`（像 W3-C 那样"只加产品依赖"），或由检查点认领。
2. **`OutputState.enabled` 在打开节目时的语义**：契约写"true = 应该在跑"，本会话按字面做——打开一个保存时正在录制 / 推流的节目（包括退出时自动存的 LastSession）会**立刻开始录制 / 推流**（崩溃恢复的语义）。scenarios/m0-show.json、g3-show.json 都是 `enabled: true` + 目录 "."，在 App 里打开会马上录到 ~/Movies/Switcher/./。如果希望"打开节目不自动起输出"，应在 App 打开时把 enabled 清掉（App 一行）或在契约里说明，请用户定。
3. **推流重连的"x s 后"**：Stats.encoder[i] 只有 `state`（backoff）和 `reconnects`，退避秒数 / 第几次尝试只在 `StreamOutput.counters.state` 的关联值里。按铁律 4 底栏只显示 "重连中（第 n 次）"（n = reconnects + 1）。要显示"x s 后"得给 Stats 加字段（提案），本会话没提。
4. **`Stats.encoder` 里没在跑的输出**：契约说"与 outputs 里带编码器的输出同序"，所以 idle 的输出也占一项（skipped 0 / bitrate 0 / state idle；录制输出照报 disk_free_mb 让状态行有磁盘数）。P2 前的 headless 只报在跑的录制器。若检查点觉得 idle 项不该出现，改 `EncoderStatsSource.rebuildStats` 一处即可。
5. **录制起止拍的提前量 10 拍（167 ms）**：`Recorder.start` 里 VT 会话创建 + PrepareToEncodeFrames 实测 64–80 ms，而 W1-E 的 `VideoEncoder` 在 start 完成前收到的帧**静默丢掉、不计 skipped**（第一版用 3 拍提前量就丢了第 1 帧）。要么 W1-E2 让 start 之前的帧排队（或至少计数），要么这个提前量留着。停止也用同样的提前量，时长 = 两次命令生效拍之差，按钮间隔 ± 1 拍。
6. **`AudioGate`**：录制器在 `stop(atTick:)` 之前收到的音频块整块写进去（stopTime 未定），headless 的封口顺序会多出 2 块 + 6 ms 的音频（G3 记的 E5 24–169 ms 有一部分是它）。App 在录制器前面按 host time 裁块（跨边界的块截短），两轨完全相等。这是组装方的活，不改 W1-E。**W1-E2 已在并行会话里做完（2026-09-19，分支 `w1-outputs-2`，未合并）**：录制器自己截两轨、`stop(atTick:)` 可在边界前调、越界块入口就丢。合并后 App 的 `OutputRuntime.stopRecording` 可以简化成"命令生效就 `rec.stop(atTick: 边界)`"、去掉等音频块 + 先摘消费者那段（约 15 行）；两扇门留着也不碍事（它们只挡录制器本来就会丢的东西）。本会话按 main（2fdf52d）的 Recorder 接，没有用 W1-E2 的新接口。
7. **调音台的条子读 `AudioEngineStatus`（50 ms）而不是 Stats（1 Hz）**：Stats.swift 自己写明"UI 高刷新率的表另读"，读数文字和 A1 仍从 Stats 来（同一来源 `AudioMixer.meters`）。
8. **相对录制目录**：headless 的 "." 是相对仓库根，App 从 Finder 起 cwd 是 /；App 把相对目录挂到 ~/Movies/Switcher 下。要不要在契约 `RecordSettings.directory` 上写明"相对路径相对什么"，请用户定。

## 5. 下一个会话需要知道的坑

1. **真 App 启动时一次 377 ms 停顿 → 引擎到达余量把节目里已有的路丢 3 s**（`reports/issues/W2B2-w1-core-startup-stall-pacing-drops.md`）：stats.jsonl 第一行 jitter_ms 377、missed_render 22，之后 3 s 两路 30 fps 合成源 dup 0 / drop +30/s（全部被帧槽淘汰、PGM 黑），第 3 s 起正常。测试宿主（引擎先起、输入后加）只丢头一秒的 14 帧。归 W1-B2（余量初值 / 停顿后恢复）；停顿本身没查到底（怀疑首次建窗口 / Metal 管线编译）。
2. **W1-E `VideoEncoder` 在 `start()` 完成前静默丢帧**（见 §4 第 5 条）：任何"先定起始拍再 start 录制器"的组装都要给 VT 会话创建留 ≥ 100 ms。
3. **`Recorder` 在 `stop` 之前不裁音频**（§4 第 6 条），组装方要自己裁；`stop(atTick:)` 前必须先摘音频消费者（W2E-w1-outputs-recorder-drift-check-before-stop 那个单子在 main 上仍在；W1-E2 分支已修，合并时 `OutputRuntime.stopRecording` 按 §4 第 6 条简化）。
4. **`open` 起的 App 不继承 shell 环境变量**：`SW_AUDIO_SILENT=1 open …` 没用，真设备会出声；测试宿主已固定空设备（`SWITCHER_TEST_AUDIO=default` 才用真设备）。
5. **XcodeGen 生成的工程按目录收文件**：加了新测试文件后要 `make gen` 再 `xcodebuild`，否则新文件不在 target 里（第一次跑只执行了 14 个）。
6. **xcodebuild 会改 `Packages/SwitcherControl/Package.resolved`**（把 HaishinKit / Logboard 的 pin 写进去，那是 App 工作区解析的副作用），`swift build` 也会生成未跟踪的 `Tools/frameprobe/Package.resolved`；提交前 `git checkout -- Packages/SwitcherControl/Package.resolved`，别 `git add -A`。
7. **UI 命令必须串行进总线**：每条 `send` 各开一个 Task 去 `bus.submit` 会抢 sequence，`setProgram(1)` + `setPreview(2)` 可能反过来生效；`ControlRuntime` 用一条 AsyncStream 顺序提交。快捷键 / MIDI / API 各自的顺序由它们自己保证。
8. **`AudioEngine.registerInput` 撞 `inputAlreadyRegistered`**：摘掉的槽位要等 3 块（16 ms）淡出后才由控制循环 detach，换来源重建同编号输入时立刻注册会撞，`AudioRuntime.register` 30 ms 后重试。
9. **摄像头 / 屏幕 / 麦克风的 TCC**：xcodebuild 从 Claude 的 Bash 起 = 责任进程没有用途说明 → 系统直接拒（`.notDetermined` 永远停在"等待系统提示"）；测试里判 `.error` 文案含"权限"就 XCTSkip。从 Terminal.app 或 Finder 起的 App 才会弹。
10. **测试宿主的设置覆盖**：`AppController.settings` 的 didSet 里套测试宿主固定项（API 端口 0、空设备）；第一版 AppDelegate 载入参数后把它们盖掉了——测试在 8765 起 API、还从扬声器放了 1 kHz。
11. **状态行提示是另一个标签**（`noticeLabel`，右上角），不改状态行文字，`testStatus_lineMatchesStatsJsonlSameSecond` 的逐字比对不受影响。
12. `Stats.encoder[i].state` 是 1 Hz 采样，停止推流的那一秒可能读到 "stopping"；按钮文案按最新一行走，停完下一秒回 "推流"。
13. 录制文件名里的时间是本地时间（`RecordSettings.outputURL`），同一秒内起两次会同名覆盖（Recorder 会 removeItem）。
14. 这台机器的 `AVCaptureDevice.default(.builtInWideAngleCamera)` 存在；`AddInputModel.cameras()` 走 DiscoverySession（内置 + external + continuityCamera）。
