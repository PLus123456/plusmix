## 130 W5-R App 收口二：磁盘下限溢出、ISO 切备用目录的分支、纯音频 ISO、局域网明文提醒 + W4-C4 的 App 口径缺口（Codex 2026-10-22 审查 N04 / N06 / N07 + 10-24 审计 NS08；G11 2026-10-24 排进 128 前）
分支：`w5-app-closeout-2`（从 G11 快进后的 main 开；与 129 / 131–133 并行）。只准动：`App/`，但**别碰** `App/Sources/Settings/OverlaySettingsPanel.swift`（129 接 N11）、`App/Sources/Release/ShowRedaction.swift` 与 `App/Tests/ReleaseTests.swift`（132 改）、`App/Sources/Engine/ControlRuntime.swift`（131 可能传新配置）；`App/Sources/Show/ShowDocuments.swift` 里 inputNumber / outputNumber 那个 catch 归 128，不做。
先读：reports/codex-bug-audit-20261022.md §1 的 N04 / N06 / N07 / N08 / N11；reports/bug-audit-20261022-audio-outputs.md AO02 / AO03 + 末尾"根审查追加的宿主运行结果"；reports/codex-network-security-audit-20261024.md [8]；红用例 reports/codex-bug-audit-20261022-tests/Audit20261022AppTests.swift.txt（`testS7_ISOFallbackReleasesBothBranches` / `testS7_ISOFallbackMustNotSubstituteProgramWhenBranchesFull` = N06；另两条归 129 / G12）、Audit20261022AudioISOTests.swift.txt（N07 宿主用例）、Audit20261022DiskLimit.swift.txt + disk-limit-probe.json（N04 换算探针）；reports/issues/W4C4-w5-app-gaps-found-by-docs.md；docs/KNOWN_ISSUES.md 产品缺陷表这几行。

现象（Codex 在 main 1f9be64 实测；g11 树这几处没变）：
- N04：高级设置"录制磁盘下限"填 17592186044416 MB（2^44）→ `UInt64(MB) * 1024 * 1024` 第二次乘法溢出 SIGTRAP（`AppController.applySettings` 与 `SwitcherSession.init` 两处同一式子）；17592186044415 正常。commitSettings 先 save 再 apply，值落了盘下次启动建 session 再崩；defaults 读取 / `--record-min-free-mb` / 设置导入都只 max(0)。
- N06：ISO 录制切备用目录（低空间事件）：`switchToFallback` 里旧录制器的封口回调只摘帧 / 音频消费者，没 `releaseBranch`（finishRecording 那条路有）；下一段又 `openBranch`，这一路 4 个分支占满时拿到 nil，`attach` 退成普通 Recorder + Master 音频——配置写着录 input2，实际录的是 PGM，没提示。
- N07：勾"显示全部输入"后纯音频输入能勾 ISO（手册也写能录），但 AudioDeviceInput 没有 videoSlot、空槽没人推帧，ISOFrameTap 收不到帧直接返回，Recorder 从没建 writer，停止时"没有写入任何视频帧"、没文件（宿主实测 sourceFrames 149248 / inputSlotPushed 0 / forwarded 0 / noFrame 60）；只有"换源且旧槽推过帧"才补黑帧（D06）。
- NS08：允许局域网 + token 时，token 在 `ws://…?token=` 查询串、状态全文明文；设置页黄字只提"没设 token"。

做（先写红用例再改；用例名带 ID `testN04_…`）：
1. **N04**：`AppSettings.maxRecordMinimumFreeMB`（建议 16_777_216 = 16 TiB；溢出点是 2^44 MB，余量够）；defaults 读、`--record-min-free-mb`、PreferencesPanel 数字框（formatter 上限 + 失焦钳）、设置导入、`commitSettings` 之前统一钳到 0…上限；MB → 字节只在一处算（`AppSettings.recordMinimumFreeBytes`，钳过之后乘、再用 `multipliedReportingOverflow` 兜底），两处 `* 1024 * 1024` 都换成它。用例：17592186044415 / 17592186044416 / Int.max 三个值走 defaults → 建 session 不 trap、读回值 ≤ 上限；设置窗填超了显示钳后的值。
2. **N06**：`switchToFallback` 先开新分支，开不到（nil）就**不切**——走 stopForDisk 一类的失败路径（提示 `notice.recordingFallbackNoBranch`："备用目录：这一路的画面分支满了，没有切"，中英两份 strings），绝不用 PGM / Master 顶替 ISO 来源；旧录制器的封口回调里 `releaseBranch(old.branch, input: n)`（同 finishRecording）；切成功后这一路的分支计数回到切之前。Codex 那两条搬进 App/Tests 改名 `testN06_…`（沿用它的 DiskMonitor.onEvent 注入法与临时目录），一条验分支计数、一条验满额不顶替。
3. **N07**：新加 / 节目载入的输入没有 videoSlot（纯音频设备）时 `InputRuntime.add` 往这一路的 tee 推一帧黑（`pushBlackFrame`，D06 用的那个），ISO 的 tap 每拍重复它（`repeated` 记账）→ 录出来是黑画面 + 本路声音；输出页 ISO 行副标题写"纯音频：画面为黑"（`outputSettings.iso.audioOnlyHint`，中英）。Codex `Audit20261022AudioISOTests` 搬进 App/Tests 改名 `testN07_audioOnlyISO_recordsBlackVideoWithAudio`（合成 PCM 替设备、2 s、文件存在、audioFrames > 0、视频帧数 ≈ 2 s × 帧率）。备选（录纯音频文件、没有视频轨）要改 Recorder，归 Outputs 会话，写进报告 §4 让用户选、本路不做。
4. **NS08**：远程控制页"允许局域网"的黄字加一句"令牌和全部状态走明文 HTTP / WebSocket（没有 TLS），只在可信局域网里开"，中英 strings；手册那句归 W4-C5。
5. **W4-C4 的 App 口径缺口 8 条**（reports/issues/W4C4-w5-app-gaps-found-by-docs.md；做完 1–4 再做，做不完写 §3）：播放中输入自己报的 lastError 在输入条 / 输入设置里能看到；NDI 发送页 failed 显示 Stats 的 last_error；推流 ▴ 悬停对鉴权停下的写"已停：鉴权失败"；"起不来"不套两层；状态窗 / 推流页 / 悬停三处用词统一；中文 Stinger 菜单标题改"（没选输入时不执行）"；ISO 那一路被删的提示别被"录制 n 已停"盖掉（合成一句或排队）；`TransitionPanelView` 注释改对。每条一条用例或截图说明；改了句子的写进报告 §5 给 W4-C5。
6. App 相关类（DiskProtectionAppTests / ISOAppTests / OutputPagesTests / 远程控制相关）+ 新用例；`make lint BRANCH=w5-app-closeout-2`。

不做：N08（129 在校验器拒；App 端到端用例 G12 翻）、N11 的接线（129）；统计窗列效果链延迟（等用户定）；ShowDocuments 的 catch（128）；任何阈值。
报告 reports/w5-app-closeout-2.md 五段；不 push、不 merge，交 G12（134）。
