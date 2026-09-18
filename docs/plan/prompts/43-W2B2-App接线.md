## 43 W2-B2 App 接线（把 W2 五路真接进主界面）
分支：w2-app-2（从 G3 合入后的 main 开）。只准动：App/。
先读：docs/checklists/G3.md 末表"App 接线状态"（七个接缝，约 170 行）；reports/w2-app.md §5（接缝、坑）；reports/w2-control.md §5 第 1 条（一行调用）；
reports/issues/W2E-g3-headless-audio-engine-wiring.md（接线要点 1–7）；Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift（同一套接线的命令行版，照着搬）；
reports/w2-inputs.md §5 第 14 条（四种输入的 `init(config:timing:videoSlot:audioRing:)`）；reports/w2-stream.md §1.2、§5（StreamOutput 配置、RTMPStream 先建再 connect）。

背景：W2-B 一期只接了合成源，摄像头 / 文件 / 录制 / 推流 / 音频 / API 都留了接缝；G3 的 50 行胶水额度接不下，用户 2026-09-18 定由本会话做。

交付（每条先写测试再接）：
1. `InputFactory`：`.camera` / `.screen` / `.file` / `.image` 用 SwitcherInputs 的四种输入（`ProgramTiming(format:t0:)` 在引擎 start 前定、新加的路用"现在之后第 3 拍"，同合成源）；带音频的输入建 `CAudioRing` 交给输入并注册进 AudioEngine；`PlaceholderInput` 只剩未知类型。
2. 命令：`SwitcherSession.send` → `CommandBus.submit(_, source: .ui)`；主窗口 keyDown → `HotkeyDispatcher.handle(KeyCombo(event:))`（用户表 ~/Library/Application Support/Switcher/hotkeys.json，没有就默认表；W2-B 的硬编码表删掉）；回执 `applied == false` 时状态行提示一下。
3. API：`StateFeed` + `APIServer`（默认 127.0.0.1:8765，设置里可关、可改端口 / token；停机顺序 API → 引擎 → feed）；MIDI：`MIDIController(bus:table:)` 起来即可，映射编辑是 W3-E。
4. 音频：`AudioEngine`（六步同 headless：建 → 每路 `registerInput(number:ring:hints:)` → `addConsumer(录制器, source: .master)` → `engine.audioStatsProvider = { audioEngine.audioCounters }` → `start(clock:)` / `stop()`）；
   `--audio-device` 对应设置里的输出设备选择（默认系统默认设备）；调音台 Master 表读 `audioEngine.status`（50 ms）或 Stats（P2 落地后）。
5. 录制：录制按钮 → `Recorder`（配置来自 Show 的 record 输出；封口顺序同 headless：引擎不停，等含边界的块送到 → 摘消费者 → `stop(atTick:)`；W1-E2 修好后改回先 stop）；文件名按 `RecordSettings.fileNamePattern`；`Stats.encoder` 三态文案已在。
6. 推流：推流按钮 → `StreamOutput`（Show 的 stream 输出；`HaishinKitTransportFactory`；重连状态进底栏；P2 前 `state` 只能从 `StreamOutput.counters` 读，写清楚）。
7. Stats：`StatsPublisher` 替换 `StatsPump`（提案 003 D2：状态行、stats.jsonl、API 同一行）。
8. 摄像头到达余量不在 App 里关（W1-B2 修引擎）；App 只把 L1 现象记进报告。

测试（xcodebuild test；摄像头 / 麦克风要 TCC——从 Terminal.app 跑，或没权限时 XCTSkip 注明 BLOCKED-权限）：
- 现有 14 个仍绿。
- 加内置摄像头 → 5 s 内 live、缩略图有画面；加 Tests/Fixtures/pattern.mov（循环）→ 帧号在走（读多画面纹理或 frameprobe 录一段）；加图片 → 同一帧每拍刷新。
- 录 5 s → 文件 ffprobe 无错、两轨、时长 5 s ± 1 帧；停止后按钮回"录制"。
- API：GET /state 的 program / preview == 快照；POST cut 后画面对调、回执 applied true；快捷键空格 → 总线计数 +1。
- 音频引擎起停 20 次不崩不漏（RSS 平）；Master 表有读数；FTB 时 Master 落到 −∞。
- 推流到本地 MediaMTX 10 s → 落盘帧号连续（用 frameprobe；scripts/mediamtx.yml）。

然后按 docs/checklists/G3.md 逐条做人工检查（用户做，结果写进报告 §2）。
不做：设置面板 / 每路音频条子 / 输入设置窗（W3-E）；Wipe / Zoom / Stinger（W3-B）。
报告 reports/w2-app-2.md：每个接缝的行数、人工检查表、坑。
