# 写手册时对着代码查出来的几处 App 行为缺口（设置窗、LastSession、快捷键开叠加、MIDI 表）

归属会话 / 分支：App 会话（W5-J / W5-L 系：`App/Sources/Settings/`、`App/Sources/AppController.swift`、`App/Sources/Show/ShowDocuments.swift`）；第 5 条是 SwitcherControl（W5-J 系）。哪一路顺手由检查点定
发现于：W4-C2（prompt 103，分支 `w4-docs-2`）写 设置 / 概念 / 快捷键 三页时，核对 agent 对着 main 93f50d9 的代码逐句查出；手册已经照现状写（含绕法），这里记实现上要不要改
现象：
1. **只改总线声道对不算"待应用"**：`PreferencesModel.refreshPending`（Settings/PreferencesPanel.swift:338 一带）只比 `audioDevice`，不比 `busOutputMap`。设置 › 音频设备 只改声道对时"应用并重起引擎"是灰的，
   改动已写进 UserDefaults，要等下次起引擎（新建 / 打开 / 重开 App）才生效。建议把 `busOutputMap` / `borrowMasterForMonitor` 与跑着的 session 用的比一下，算进 `.audioDevice`。
2. **整份写回会把启动参数存成本机设置**：`PreferencesModel.commit()`（:236-258）→ `AppController.updateSettings(_:)`（:475-476）→ `AppSettings.save(to:)` 写全部键，内存里的值含启动参数带进来的
   `--no-api` / `--api-listen` / `--api-token` / `--audio-device` / `--record-min-free-mb` / `--record-fallback`。W5-L 只把"即时生效的三节"改成了只写自己的键（AppController.swift:465 的注释说了原因），常规 / 音频设备 / 远程控制 / 高级 页仍走整份写回。
   建议照 W5-L 的做法：每页只写自己改的键，或者启动参数单独放一层、不进 save。
3. **导出 / 导入 / 恢复默认漏了几项本机设置**：`SettingsTransfer.keys`（Settings/SettingsTransfer.swift:90-98）没有提醒（`reminderNotLive*` / `reminderFTB` / `reminderLowAudio`）、
   性能与电源（`preventSleepWhileRunning` / `preventDisplaySleepWhileRunning`）、Tally（`tallyEnabled` / `tallyPort`）、兼容层 HTTP 端口（`compatLayerHTTPPort`）。G7 合并时只补了 W5-K 的两个键。
4. **LastSession 只在正常退出时写**（`AppController.shutdown` 是唯一的 `documents.autosave` 调用，AppController.swift:179），而"要保存…"那一问的说明（`confirm.save.messageQuit`）写的是"存一份到 LastSession（崩溃后恢复用）"——崩溃时来不及写，"崩溃后恢复"做不到。
   另：`lastShow` 在打开 / 保存时记下、新建与"打开上次退出时的节目"都不清（ShowDocuments.swift:76、:95），启动优先开它（AppController.swift:164-171），所以"新建 → 没保存就退出"下次启动开的是之前那个文件。手册照现状写了；要不要改成"上次是新节目就恢复 LastSession"请定。
5. **快捷键 ⌃1–⌃4 开空通道不用 PVW**：默认表的 `toggleOverlay(channel:)` 解析成 `overlay(on, input: nil)`（SwitcherControl/Hotkeys/ControlAction.swift:114-116），通道没指定输入时开了没画面；
   转场列与"切换"菜单的按钮会用 PVW 那一路开（TransitionPanelView.swift:442-449，按钮提示还写着快捷键）。两边口径不一，手册照实写了差别。
6. **midi.json 读不出来时不提示**：`MIDIMapTable.loadUserTableOrDefault()` 静默退成空表（MIDIMapTable.swift:193-195），hotkeys.json 读不出来会在状态行提示（AppController.swift:85-91）。
复现步骤：各条按上面的文件:行读代码；1 / 2 可在 App 里直接复现（只改声道对看底部按钮；带 `--no-api` 起 App、在 设置 › 常规 改任一项、退出后 `defaults read com.plusmix.switcher apiEnabled`）。
严重级：S3（1、3、4、5、6）；S2（2：带启动参数排查问题的人改一下设置，本机的 API 就被存成关着）
建议：见各条；改了实现告诉文档会话把手册里对应的绕法删掉（设置 / settings 的音频设备、导出、启动参数三处，概念 / concepts 的 LastSession 与叠加两处，快捷键 / shortcuts 的 ⌃n 与 MIDI 两处）。
