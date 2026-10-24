# Codex 2026-10-22 审查的红用例与探针（原样归档；G11 2026-10-24 从 Codex 的审查树 `/Users/plus/.codex/worktrees/bug-audit-20261022/plusmix` 抄来）

来源：reports/codex-bug-audit-20261022.md（主报告）与三份分项报告；审查树上这些文件没提交（`??`），`.build/` 里的探针源更会被清掉，所以抄一份进仓库。
后缀加 `.txt` 是不让它们被当成源码编译 / 扫禁词；修复会话把对应文件搬回原目录、去掉 `.txt`、用例名改成带 ID（`testN0x_…`），先看着红再改绿。
对应关系（N 号 = 主报告 §1 的表；修哪张 prompt 见 docs/KNOWN_ISSUES.md 产品缺陷表的"计划"列）：

| 文件 | 原来的位置 | 条目 | 修复会话 |
|---|---|---|---|
| Audit20261022AppTests.swift.txt | App/Tests/ | `testS7_ISOFallbackReleasesBothBranches` / `testS7_ISOFallbackMustNotSubstituteProgramWhenBranchesFull` = N06；`testOverlaySelectingNoneMustClearRoute` = N11；`testAPI_LoadShowMustKeepActualAndAdvertisedFormatConsistent` = N08；`testNDI_SourceReplacementMustRestoreAudioAfterRegistrationRetry` = 保留线索（当时过了） | 130 W5-R（N06）；129 P5-7（N11 接线）；G12 胶水（N08：改成"400 + 格式不变"）；133 看一眼线索 |
| Audit20261022AudioISOTests.swift.txt | App/Tests/ | `testAudioOnlyISOSelectedInSettingsMustProduceRecording` = N07（合成 PCM 替设备、真 SwitcherSession） | 130 W5-R |
| Audit20261022ControlTests.swift.txt | Packages/SwitcherControl/Tests/SwitcherControlTests/ | `testAudit20261022_newSubscriberNeverReceivesOlderSnapshotAfterCurrent` = N12（clockProvider 暂停推送线程的交错）；`testAudit20261022_primaryAPIDurationBoundaryDecoder` = N03（Int.max 时长解码成功、校验器放行） | 131 W2-C5（N12）；129 P5-7（N03） |
| Audit20261022RecorderTests.swift.txt | Packages/SwitcherOutputs/Tests/SwitcherOutputsTests/ | `testAuditLateFirstAudioMustKeepTimestamp` = N10（真录 1 s，首个非零样本应在 24000 ± 1） | 132 W2-D5 |
| Audit20261022InputTapTests.swift.txt | Packages/SwitcherAudio/Tests/IntegrationTests/ | 已知 D06 边角的复现（旧 input1 tap 收到 input2 的声音），不计新增；G11 合入 126 后再跑一次看是否仍红 | W1-D 系（不在本批） |
| Audit20261022CoreMain.swift.txt + Audit20261022-{valid,fpsZero,fpsNegative,rationalMin,overlays0,dimensions,fpsHuge}.json | 独立探针（把 Contracts 源编成 dylib 后 `Show.load` 这些 JSON） | N01（fpsZero / fpsNegative / rationalMin）、N02（overlays0）、"验证到的其他行为"（dimensions 能加载、fpsHuge 解码过 newShow 崩）；valid 是对照 | 129 P5-7：七份 JSON 原样当 `Contracts034Tests` 的夹具 |
| Audit20261022ReducerMain.swift.txt | 独立探针（直接调 MixerReducer + CommandValidator） | N03 ftbMax 序列（ftb(true) → setFTBDuration(Int.max) → ftb(false)）、overlayDuration（中途改时长 0.5 → 0.258）、loadFormat（校验器 / reducer 接受换格式） | 129 P5-7 |
| Audit20261022FileMain.swift.txt | 独立探针（真 FileInput + 只记帧的槽） | N09 immediate / applied / poll16 / poll16_30 | 133 W2-A6 |
| Audit20261022ChannelMain.swift.txt | 独立探针 | N05 `requiredSourceChannels(map:[Int.max],…)` SIGTRAP、`[999]` → 1000 | 133 W2-A6 |
| Audit20261022DiskLimit.swift.txt + disk-limit-probe.json | 独立探针（UI 同款格式解析 + max(0) + `* 1024 * 1024`） | N04：17592186044415 过、17592186044416 SIGTRAP | 130 W5-R |
| reproduce-sign.py.txt + sign-invalid-identity.json | `python3 reproduce-sign.py`（临时 App 先 ad-hoc、再给不存在的身份） | N13：sign.sh 退出 0、原签名保留 | 134 G12（scripts/ 是检查点的） |
| Audit20261022FrameAnalysis.swift.txt | 独立探针 | A4 全无 click 的事件（用户 2026-10-18 裁定不算缺）——不是 bug，留作口径证据 | — |

跑法与当时的数字见各分项报告 §2；探针用的编译命令在 reports/bug-audit-20261022-core-inputs.md §2。
