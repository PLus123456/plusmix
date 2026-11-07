# 录制写满 / 写入失败 / 录制器出错之后，状态行最后是"录制 n 封口失败：notRecording"；录制器出错那一路开关还开着、改设置也不重试

归属会话 / 分支：下一个 App 会话（W5 系；`App/Sources/Engine/OutputRuntime.swift`）
发现于：W4-C5（prompt 135，分支 `w4-docs-5`）的核对 agent 核对输出页"停下的那一路封好口时……——已封口"一句时，我对代码复核过
严重级：S3（文案误导 + 一个恢复路径的边角，不伤节目；已写的片段照留）

## 现象一：只有"低于下限"和"ISO 那一路被删"拿得到"——已封口"

130 W5-R 的口径是"ISO 那一路被删 / 磁盘下限 / 录制器出错的封口句'<原因>——已封口：…'"（reports/w5-app-closeout-2.md §5 表），但实际只有两条路走得到：

- `recordingStoppedWithReason` 要 `finishRecording` 拿到 `.success`，也就是 `Recorder.stop(atTick:)` 被调时录制器还在 `.recording`。
- 低于下限：App 把录制器自己的 `minimumFreeBytes` 设成 0（OutputRuntime.swift:474），由 `RecordingDiskMonitor` 在录制器还在录时报 `.belowMinimum` → `stopForDisk` → 正常封口 ✅。ISO 删输入同理 ✅。
- 写满 / 写入失败 / 录制器出错：监视器只在录制器**已经** `.failed` 时才报 `.failed` 事件（DiskGuard.swift:210–215），之后 `stopForDisk`（:631–642）或 cause other 那一段（:607–614）
  对已失败的录制器调 `stop(atTick:)`，它当场回 `.failure(.notRecording)`（Recorder.swift:276、289–291）→ `finishRecording` 走失败分支（:580–581，不看 `stopNotice`）
  → 状态行 `notice.recordingFinishFailed`："录制 n 封口失败：notRecording"（英文 "Recording n failed to finalize: notRecording"）——`Recorder.Error` 没有 description，枚举名直接上了界面。
- 由写满触发的"…；备用目录：这一路的画面分支满了…"与"…；备用目录也起不来：…"结局一样。

用户看到的是先"录制 n：磁盘满（…）"，下一轮主线程就被"封口失败：notRecording"盖掉；故障排查原来把"封口失败"解释成"停止时写索引失败"，碰上这种会误导。
手册现在照实写了（输出 › 磁盘保护、故障排查 §3，中英：只有低于下限 / 删输入接"——已封口"，另几种随后是"封口失败：notRecording"、已知问题）。

## 现象二：录制器出错（cause other）那一路开关还开着，改设置不重试

`handleDisk` 的 `.failed(cause: .other)` 分支（OutputRuntime.swift:607–614）只 `fail(output:reason:notice:)` + stop，**没发 `stopRecord`、没记 `failedSettings`**：

- 快照里这一路 `enabled` 仍为真，`failed` 表里有原因 → Stats 报 failed、底栏 / ISO 页 / 状态窗显示红色"起不来"（OutputButtonSummary.swift:104–107）；
- `retryAfterSettingsChange`（:321–326）要 `failedSettings`，所以改设置不会自动重试；只能在录制 ▴ 里点它"只停这一路"，下次开录再一起开。
- 对比：低于下限、写满两条（`stopForDisk`）都发 `stopRecord`，开关会关掉。

## 建议

1. 已失败的录制器不要再走 `stop(atTick:)` 拿 `notRecording`：`stopForDisk` / cause other 那一段看 `entry.recorder.state` 是 `.failed` 时直接按"已封口（失败前的片段）"收尾，
   或在 `finishRecording` 的失败分支里认 `Recorder.Error.notRecording` + 有 `stopNotice` 时发 `recordingStoppedWithReason`（帧数 / 时长取 `counters`），文案写"<原因>——已停，失败前的片段已留在：文件名"。
2. cause other 那一段与 `stopForDisk` 对齐：发 `stopRecord`（开关回关），或记 `failedSettings` 让改设置能重试——二选一，先定口径。
3. 用例：DiskProtectionAppTests 加"写满、没设备用目录"与"录制器非磁盘出错"两条，断言状态行最后一句不含 `notRecording`、开关状态与口径一致。
4. 修了告诉文档会话：输出 › 磁盘保护与故障排查 §3 那几句（"已知问题"）改掉。
