
## 2026-10-12 用户裁定：允许 `monitorSource = headphones`

用户 2026-10-12（看完 reports/G8.md §7.1 第 4 条）："允许"。落地归下一个契约会话（P5-3，prompt 110）；App 菜单那一项归 W5-O（prompt 112）。

- 契约：`AudioState.monitorSource` 允许 `.headphones` = **听耳机总线自己**（只听每路 `routing.headphones` 送出的那条，W5-K 菜单里"耳机总线（现在）"那一项、W1-D2 的旧行为）；独听（PFL / AFL）仍优先于 monitorSource，与 master / busA / busB 同口径。reducer / 校验器不再拒 headphones；文件 / API 全量状态里的 `headphones` 按字面读（P5 时"读成 master"的兜底去掉——App 从没写过这个值，没有迁移问题）。
- 引擎：W1-D3 的混音器已支持（`SW_CMD_MONITOR_SOURCE i0 = 3` = 耳机总线自己）；Integration 的 `syncSnapshotExtras` 把 headphones 原样交给混音器（现在是"万一出现按 master"，改掉）。
- 文字 / 用例：CONTRACTS.md §2.5 / §2.6、`Contracts026Tests.test026_audioStateMonitorSource_defaultRoundTripMissingKeyAndHeadphonesReadAsMaster` 改成 headphones 往返、`CommandBusTests` 的校验器用例、CommandCatalog 参数范围 bus 0–3 → docs/api.md 重生成。
- App（W5-O）：`MixerModel.listen(_:)` 发 `setMonitorSource(bus:)`（四项都发得出，"耳机总线"= `.headphones`），`listenBus` 读快照 `audio.monitorSource`，`listenToOtherBusSupported` 翻 true，`AudioSettingsRevampTests.testPanels_masterListenAndLoudnessDetails` 跟着改（问题单 W1D3-app-monitor-source-and-input-effects-wiring 第 1 条）。
