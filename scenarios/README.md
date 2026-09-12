# scenarios/ —— 场景脚本

switcher-headless 用 `--script <文件>` 按 tick 发命令，格式是 SwitcherContracts 里的 `Scenario`（P1 定义）：
`{ durationTicks, events: [ { tick, command } ] }`，command 的 JSON 形状与 `Command` 枚举的 Codable 一致。

第一个文件 `m0.json` 由 G2 写：每 30 秒 Cut 一次、每 5 分钟 Fade 一次，跑 10 分钟 / 60 分钟。之后 G3 / G4 / W4-A 各加自己的。
改场景要在对应检查点报告里说明，否则基线不可比。
