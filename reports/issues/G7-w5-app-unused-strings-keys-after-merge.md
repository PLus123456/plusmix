# 骨架七路合并后两份 Localizable.strings 里有一批没人用的旧键

归属会话 / 分支：App 会话（任何一个在 App/ 上开工的会话顺手做；W5-J 报告 §3 第 5 条本来写"G7 合完可以统一清"）
发现于：G7 检查点合并后（两份表 866 → 1593 键；l10n 自检只查"源码引用的键都在表里"，没有反向查）
现象：
- W5-J 把偏好设置拆成页、W5-K 换掉叠加弹出层 / 效果 sheet / 添加面板各页说明、W5-L 换掉 API / 兼容层两节之后，`prefs.*`、`*.windowTitle`、`overlay.*`（旧弹出层）、`hotkeys.action.*` 里一部分键没人引用了；W5-J 当时故意没删（95 / 97 / 98 可能还在用）。
- 不影响用例（`LocalizationTests` 只要求键集一致、引用的键存在），只是表越来越长、翻译要维护两倍的无用条目。
复现步骤：`python3 -c` 把 App/Sources + App/Tests 里 `L("…")` 的字面键与两份表的键做差集（G7 的 l10n-scan.py 加一个反向模式即可）。
严重级：S3（整洁）。
建议：合并后一次性删（两份表同步删），`LocalizationTests` 加一条"表里的键都被引用"的反向检查（动态拼的键 `L("addInput.kind.\(rawValue)")` 这类按前缀放行）。G7 没做：检查点不改文案表。

## 处理结果（W5-N / prompt 101，分支 `w5-playback-status`，2026-10-11，2026-10-10 裁定 ④ 的"顺带"）

- 删了 96（W5-J）`PreferencesPanel.swift` 里没人用的 `enum MachineInfo`（98 的 `PowerMachineInfo` 才是在用的那份）和它带的 `import Metal`。
- 两份表同步删了 36 个 App/Sources 里没人用的键（`prefs.*` 7 个、`*.windowTitle` 4 个、`outputSettings.*` 9 个、`settings.performance.*` 8 个、`addInput.field / screen.*` 5 个、
  `settings.remote.listening` / `settings.tally.*` 3 个；清单在本分支 87055f3 之后那个提交的 diff 里）。另外 W5-N 自己换掉的 9 个旧键（"● 录制中"之类）在 W5-N 的实现提交里删了。
- `LocalizationTests.testL10n_everyKeyInTableIsReferenced`：表里的键要么在 App/Sources 里以字面串出现（`L("…")`、三目、数组都算），要么是某个
  动态拼键 `L("前缀.\(…)")` 的展开（按前缀放行）；`AppTest.localizationReferences(in:)` 在 TestSupport 里。以后合并留下的孤儿键会在这条红。
