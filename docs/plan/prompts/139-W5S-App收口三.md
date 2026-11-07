## 139 W5-S App 收口三：NDI 发送换源后漏挂音频、底栏推流悬停的路径密钥、选动作面板的叠加"清空"与秒数框溢出（133 / 132 / 129 攒的，G12 2026-10-31 定级分派；G12 快进 main 后开，与 135 / 136 / 138 并行）
分支：`w5-app-closeout-3`（从 G12 快进后的 main 开）。只准动：`App/`，但 `App/Sources/Show/ShowDocuments.swift` 里 inputNumber / outputNumber 那个 catch 归 128、不做。
先读：reports/issues/W2A6-app-ndi-send-input-audio-lost-after-register-retry.md 全文（代码链 1–4、复现步骤、建议改法）；reports/w2-stream-5.md §3 第 4 条（底栏悬停 `BottomBarView.swift:493` 用默认的 `redact(url:)`）；reports/p5-contracts-7.md §3 第 2 / 3 条（命令目录 overlay 的 `input(allowsBlack: false)` 让"选动作"面板没有"清空"项；`ActionPicker.swift:243` 的 `String(Int(rounded))` 对极大值溢出，没验证）；reports/w5-app-closeout-2.md §3 / §4（纯音频 ISO 文件形式、NDI 翻 failed 时状态行提示、统计窗列效果链延迟三条"等用户定"）；docs/KNOWN_ISSUES.md 产品缺陷表这几行；Codex 原用例 reports/codex-bug-audit-20261022-tests/Audit20261022AppTests.swift.txt 的 `testNDI_SourceReplacementMustRestoreAudioAfterRegistrationRetry`。

做（先写红用例再改；用例名带 ID）：
1. **NDI 发送漏挂音频（S1，等用户改口）**：搬 Codex 那条改名 `testW2A6_ndiSendRestoresAudioAfterSourceReplacementHitsRegisterRetry`，被换的输入改成 `stop()` 快的来源（两路合成 PCM 驱动的纯音频输入），先断言 `session.audio.registerRetries` 涨了（真进了重试窗口），再断言 `ndiSenders[n]?.audio?.token != nil`、`audioBlocksSent` 接着涨——先红。改法按问题单：`onRegistered` 里 `followInputAudioSlots` 之后，给在跑、源是 `.input(n)`、`audio == nil` 的 NDI 发送补挂（这时新来源已注册、槽位是新的，不会挂到还在淡出的旧槽上——W5-Q D06 边角的口径）；或 `attachNDI` 对 `.input(m)` 一律建挂件、token 先空着交给 `followInputAudioSlots` 跟上。两种挑一种，另一种写进 §3 为什么不选。
2. **底栏推流悬停（S2）**：`BottomBarView` 的悬停提示与 ▴ 菜单项对每一路看同层 `streamKey` 为空就 `redact(url:publishNameInPath: true)`（与 ShowRedaction 同口径）；用例：密钥栏空 + `rtmp://h/live/KEY` → 悬停 / 菜单里找不到 KEY，密钥栏非空的路径照旧。
3. **选动作面板**（129 §3）：命令目录 overlay 的 `input(allowsBlack: false)` 面板按它出下拉——给面板加"（清空）"= 0 一项（不改命令目录的类型化字段，面板自己加；或告诉用户要改目录归契约会话、写 §4）；`ActionPicker.swift:243` 秒数显示先验证极大值会不会溢出（填 1e30 秒），会就钳到 `DurationLimits.maxTicks` 对应的秒数，与 `OverlaySettingsModel.ticks(seconds:)` 同一个法子；用例各一条。
4. **等用户定的三条**（reports/G12.md §7.1）：定了做、没定写 §3：纯音频 ISO 录成纯音频文件（要改 Recorder，归 Outputs 会话——本路只做 ISO 页副标题跟着改）；NDI 在跑中翻 failed 时状态行提示一句（防 failed / publishing 来回翻刷屏：同一路 60 s 内只提示一次）；统计窗"音频"一节列效果链延迟（只读 Stats `audio.effects`，铁律 4）。
5. App 相关类（NDISendAppTests / NDIBranchRetryAppTests / BottomBarPopupTests / ActionPickerTests / W5RCloseoutTests）+ 新用例；改了的句子写进报告 §5 给 W4-C5（135 若已合入就开问题单）；`make lint BRANCH=w5-app-closeout-3`。

不做：ShowDocuments 的 catch（128）；OverlaySettingsPanel 之外的契约 / 命令目录；Recorder；阈值。
报告 reports/w5-app-closeout-3.md 五段；不 push、不 merge，交 G13（140）。

**G13 追加（2026-11-07）**：已合入 g13（2f78897 → 合并提交 d5c3c9b，第四路、0 冲突）；合入后 App 16 个相关类 91 条 = 90 过 + 1 跳（键盘导航 BLOCKED-系统设置）+ 0 红——`BottomBarSplitTests` 两条第一遍红是同机正在跑包里的 `MediaMTXTests`（两边都用 apiPort 29997，G12 记过的坑），机器安静后单独复跑 6 过 + 1 跳；`W5SCloseoutTests` 8 / 8。KNOWN_ISSUES：S1 NDI 漏挂音频、S2 底栏悬停销号；§3 第 4 条推流设置页地址框仍露路径末段 G13 定 S2 新进缺陷表（归下一个 App 收口会话）；§1 第 7 条 `AppTest.run` 的工装修法记进"G13 合入已修"表。
