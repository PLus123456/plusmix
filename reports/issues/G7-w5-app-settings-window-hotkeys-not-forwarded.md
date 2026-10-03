# 设置窗（W5-J 合窗）在前时按键不走快捷键表——X12 的最后一个残口

归属会话 / 分支：App 会话（`App/Sources/Settings/SettingsWindow.swift`，W5-J 的地盘；用户 2026-10-03 定 X12 等 97 / 102 做完再发——97 做完后只剩这一处）
发现于：G7 检查点合入 W5-K 时读 reports/w5-app-panels.md §3 表最后一行（"输出设置 / 偏好设置 / 快捷键编辑器窗在前时的快捷键……留给它们"），对照 W5-J 的 `SettingsWindow.swift`：`PanelWindow.keyHandler` 只接了 `handleRecordingKey`（快捷键页录键用）
现象：
- W5-K 给输入设置 / 叠加设置 / 音频设置三扇窗挂了 `PanelCoordinator.forwardHotkeys`（没被文本框吃掉的按键交给 `session.control.handleKey`），这三扇窗在前时空格 / 数字 / 回车照样切（`PanelsRevampTests` 钉着）。
- W5-J 的设置窗（偏好 / 输出各页 / 快捷键 / MIDI 合成的那一扇）在前时按空格 / 数字什么都不发生——和 02 X12 原来描述的"输入 / 输出 / 偏好设置窗在前时不派发"一样，只是窗变成了一扇。
复现步骤：开节目两路合成源 → ⌘, 打开设置窗停在"常规"→ 按空格 / 数字 2 → PGM / PVW 不变；点回主窗口再按 → 切。
严重级：S2（02 X12 原定 S1 的一半；现场开着设置窗调东西时按键失灵，绕过 = 点回主窗口）。
猜测原因 / 建议改法（两行，不在检查点里做）：`SettingsWindow` 建 PanelWindow 处把
`window.keyHandler = { [weak self] event in self?.handleRecordingKey(event) ?? false }`
改成先录键、不吃再交快捷键表：`{ [weak self] event in (self?.handleRecordingKey(event) ?? false) || (self?.controller.session?.control.handleKey(event) ?? false) }`
（录键中要截键，所以 `handleRecordingKey` 在前；`controller` 是 `SettingsModel` 持有的 AppController，和 PanelCoordinator.forwardHotkeys 同一口径）。补一条用例：设置窗在前按空格 → `hotkeys.counters.handled` +1、PGM 换人；快捷键页录键时按空格 → 录进去、不切。
