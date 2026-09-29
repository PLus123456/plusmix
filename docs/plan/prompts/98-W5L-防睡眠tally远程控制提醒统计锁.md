## 98 W5-L 其他：防睡眠 / App Nap、App 起只读 tally 流、远程控制页、界面内提醒、统计窗、界面锁（第五波 · 骨架；G6 之后开）
分支：w5-app-misc（从 G6 合入后的 main 开）。只准动：App/、project.yml（只加 App 对 SwitcherTally 产品的依赖，同 W2-B2 / W3-C / W3-E3 先例）。
先读：01a P1、P2、P3、E5、E8；02 N01、N02、N04、N15、X32、X33、X34；04 Q46（默认：设置 › Tally 一个开关默认关、端口、只读地址两行、连接数；App 链 SwitcherTally）、Q47（默认开：引擎运行时阻止系统睡眠与 App Nap；显示器休眠另一个开关默认也阻止）、Q50（提醒只在主窗口里做：没在录、FTB 开着、音量持续过低）、Q42–Q44（统计窗、界面锁进；"重置"= 界面记基线；锁只锁主窗口鼠标）、Q45；docs/integrations/tally.md；Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift:427-436（headless 怎么起 TallyServer）；reports/w4-soak.md（空闲时实时线程被拖慢的实测）；docs/plan/prompts/70-W4A-长稳性能.md 第 7 条。

交付（每条先写红测试；函数名带 ID）：
1. **防睡眠 / App Nap**（P1）：引擎运行时 `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason:)`，停引擎 endActivity；显示器休眠（`.idleDisplaySleepDisabled`）单独开关，默认也阻止；设置"性能与电源"页放两个开关 + 只读机型 / GPU。
2. **只读 tally 流**（P2 / X32）：设置 › Tally：开关（默认关）、端口（默认 API 端口 + 1）、只读地址 WS / HTTP 两行带"复制"、连接数；开 = App 起 `TallyServer`（与 headless 同一套接法，挂 StatePublisher），关 = 停；停机顺序 tally → API → 引擎。project.yml 加 SwitcherTally 产品依赖。
3. **远程控制页**（P3 / X33）：本地 API 与兼容层各"仅本机 / 允许局域网"二选一（代替自由填 host），下面只读显示 http://<本机局域网 IP>:<端口> 带"复制"；允许局域网又没设 token 时黄字提醒；兼容层加 HTTP 端口可改（AppSettings 现在写死 8088 / 127.0.0.1）。
4. **界面内提醒**（N02）：主窗口里的提醒条（不改契约、不叠进多画面）：录制 / 推流都没开且引擎跑了 n 分钟（默认关，可开）、FTB 开着（PGM 标题条已有"PGM · FTB"，加闪烁或色块）、Master 电平持续 30 s 低于 −50 dBFS；每条可在设置里关。
5. **统计窗**（E5 / N15）：底栏"统计"（92 留了位置）开只读窗：每路输入（fps / 重复 / 丢帧 / 延迟）、渲染、每个输出（按 EncoderEntry.output 对上名字 / 类型 / 来源，帧数 / 跳帧 / 丢帧 / 码率 / 状态）、显示、音频；"重置"只在界面记基线相减，Stats 累计值不动。
6. **界面锁**（E8 / N04）：底栏最右"锁定界面"：锁着时主窗口的鼠标点击不生效（锁按钮除外），快捷键 / MIDI / API / 菜单栏照常，独立窗口不锁；锁着时按钮高亮。
7. `make test-app` 全量 0 失败；`make lint BRANCH=w5-app-misc`。

测试：`testApp_engineRunningHoldsActivityAssertion`（引擎起 → 进程有对应 activity；停 → 释放）、`testTally_appServesReadOnlyStream`（开关打开后 ws://127.0.0.1:<port>/tally 收到 hello + tally 帧；关掉后端口不监听）、`testPanels_remoteControlPageShowsReachableAddress`、`testUI_reminderShowsWhenFTBOnForTenSeconds`、`testUI_statsWindowResetKeepsStatsCumulative`、`testUI_interfaceLockBlocksClicksNotHotkeys`。
不做：手机网页 tally（后续方案 §5.3）、多画面上的提醒（要渲染器）、契约。
报告 reports/w5-app-misc.md（五段）：activity 断言对 W4-A 长稳空闲拖慢的复测数字（10 分钟 gate 对比）。不 push、不 merge。
