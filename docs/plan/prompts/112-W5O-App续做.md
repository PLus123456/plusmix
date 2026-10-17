## 112 W5-O App 续做：W4-C2 查出的两条 S2、监听菜单接 setMonitorSource（含 headphones）、Stinger 槽拒收的提示、分类颜色切 InputConfig.color、压缩器简单模式界面、X51、若干 S3（2026-10-12 用户定开；1–2、5–8 现在就能开，3–4 等 110）
分支：w5-app-followups（从 G8b 合入后的 main 开；第 3、4 项等 110 `p5-contracts-3` 合入 main 后再做，或叠在它头上、lint 加 `--base p5-contracts-3`）。只准动：App/、Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/、Packages/SwitcherControl/Sources/VMixCompat/、Packages/SwitcherControl/Tests/、Tools/streamdeck-plugin/（同 W5-M 那一行）。体量 L：要并行可拆两路——1 / 2 / 5 / 7 / 8 从 main 开，3 / 4 / 6 叠在 110 上。
先读：docs/KNOWN_ISSUES.md 产品缺陷表 2026-10-11 G8b 新进的几行（每条写了问题单与建议）；reports/issues/W4C2-w5-app-inputs-outputs-gaps-found-by-docs.md、W4C2-w5-app-settings-gaps-found-by-docs.md、W4C2-w5-app-cell-buttons-truncated-in-english.md、W4C2-w5-transition-slots-compat-x51-still-400.md、W1D3-app-monitor-source-and-input-effects-wiring.md；docs/contract-changes/026 末尾"2026-10-12 用户裁定"、029；reports/w5-playback-status.md §3 第 3 条（分类颜色：做法同 025 的搬迁）；reports/p5-contracts-2.md §1 的 023 四（`Show.migratingLegacyInputCategories()`）；reports/w5-transition-slots.md §5（转场列的新接口）。

交付（先写红测试，用例名带编号）：
1. **S2 外部显示 Esc / "关闭这路"= 删输出**（W4C2 inputs/outputs 第 1 条）：Esc 只关窗口 / 把这一路 `enabled = false`（配置留着，与路由菜单的"关闭"一致）；设置页按钮改名"删除这一路"或改成只关；两处确认框口径与路由菜单一致。
2. **S2 设置页整份写回把启动参数存成本机设置**（W4C2 settings 第 2 条）：常规 / 音频设备 / 远程控制 / 高级 页每页只写自己改的键（照 W5-L 即时生效三节的做法），或启动参数单放一层不进 save；用例：带 `--no-api` 起、改一项设置、存下来的 apiEnabled 不被写成关。
3. **监听菜单**（等 110）：`MixerModel.listen(_:)` 发 `setMonitorSource(bus:)`——Master / Bus A / Bus B / 耳机总线四项都能选（"耳机总线"= `.headphones`，不再叫"（现在）"），`listenBus` 读快照 `audio.monitorSource`，`listenToOtherBusSupported` 翻 true；`AudioSettingsRevampTests.testPanels_masterListenAndLoudnessDetails` 改；问题单 W1D3 第 1 条。
4. **Stinger 槽拒收的提示**（等 110；提案 029）：控制层 `ControlAction.transitionSlot` / `autoTransition` 被拒时 feedback 一句"转场 n 是 Stinger、还没选输入——在转场列 ▾ 里选一路"（状态行）；兼容层 `Transition n` 对这种槽回 409 NotConfigured（与 `Stinger1` 一致，C5 用例一条）；Stream Deck 按下收到 400 时 `showAlert`（test/cases.js 一条）。界面三处本来就先弹选择，不动。
5. **分类颜色切 `InputConfig.color`**（提案 023 四的 App 侧）：`Show.migratingLegacyInputCategories()` 在 Show.load 后调一次（同 101 对 025 的做法、读文件与读 LastSession 两处），分类色读写走 `InputConfig.color` / `setInputColor`，名字留 layout；多画面标签色点等归各自会话、不在这里。
6. **压缩器简单模式界面**（提案 024 (b)；问题单 W1D3 第 4 条）：音频设置窗压缩页可选 `compressor`（阈值 / 比例 / 拐点 / 起音 / 释放 / 补偿，范围 = `SwitcherAudio.EffectParameterRanges.table["compressor"]`，与 `dynamicsProcessor` 二选一）、"延迟自测"一行读 `compressorMeasuredLatencyFrames`；限幅页"天花板"滑块写 `peakLimiter.ceilingDb`（−20…0）。
7. **X51**：31 个对方真实存在的函数名补进 `FunctionCatalog.knownUnimplemented`（精确名字，不加前缀族）+ C5 一条 501 断言。
8. **S3 一批**（W4C2 两张单子其余条 + 英文截断）：只改总线声道对 / 借 Master 算进"待应用"；导出 / 导入 / 恢复默认补提醒 / 电源 / Tally / 兼容层 HTTP 端口几键；⌃1–⌃4 对没指定输入的通道用 PVW（与转场列 / 格子一致）；midi.json 读不出在状态行提示；无信号的格子把这一路的 `lastError` 作第二行或悬停提示（从 InputRuntime 带到界面，不改契约）；NDI® 横幅文案照 DeckLink 那条改成"这一版编译时没带 NDI® SDK"；切备用目录的提示区分"低于下限"；英文中档格子 "Transition" 按标题宽分配或换短字。LastSession 的口径（W4C2 settings 第 4 条）用户没定、不动。
9. 每项做完告诉 109（W4-C3）删手册里对应的绕法 / 警告；KNOWN_ISSUES 的行不在本会话目录，G9 销号。`make test-app` 两遍（显示类红了先单独复跑）、`make lint BRANCH=w5-app-followups`（叠在 110 上时加 `--base p5-contracts-3`）。

不做：新功能（播放进度条、推流 ▴ 每行时长那类）；030 效果延迟进 Stats 的界面（等用户 / 契约）；任何阈值。
报告 reports/w5-app-followups.md 五段；不 push、不 merge，做完告诉 G9（prompt 114）。

**G9 追加（2026-10-17）**：已随 G9 进 main（w5-app-followups 7f518cf → 合并提交 c1ef0d8，紧跟 110 合、0 冲突）。§3 用户裁定：第 1 条借 Master 不算待应用——**接受**；第 2 条 MIDI 被拒不提示——**加**，归 116（MIDIController.setFeedbackHandler + ControlRuntime ≤ 30 行）；第 6 条英文小档 "Transition" 截尾——**留着**（S3）；第 7 条格子"转场"遇没选输入的 Stinger——像转场列那样先弹选择、整条不发，归 119；第 8 条 ⇧1–⇧0——归 116；第 9 条 T-bar——App 灰掉并提示，归 119。KNOWN_ISSUES 销号由 G9 做了。
