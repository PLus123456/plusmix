# scenarios/ —— 场景脚本与节目文件

switcher-headless 用 `--show <节目文件>` 装配输入 / 混音 / 输出，用 `--script <场景>` 按 tick 发命令。
场景格式是 SwitcherContracts 里的 `Scenario`（P1 定义）：`{ durationTicks, events: [ { tick, command } ] }`，
command 的 JSON 形状与 `Command` 枚举的 Codable 一致（例如 `{"cut":{}}`、`{"fade":{"durationTicks":30}}`、`{"setPreview":{"input":3}}`）。
节目文件是 `Show`（schemaVersion 1）。

## 现有文件（G2 起）

| 文件 | 生成命令 | 内容 |
|---|---|---|
| `m0-show.json` | `switcher-headless make-show --out scenarios/m0-show.json` | M0 标准负载：1080p60，8 路合成源（1、2 号 30 fps，3、4 号 59.94，5–8 号 60；5 号 +100 ppm、6 号 −100 ppm 时钟漂移，7 号 ±3 ms 抖动；1 号带合成音频 click），PGM 1 / PVW 2，默认转场 Fade 30 拍，一路录制输出（H.264 6 Mbps + AAC） |
| `m0.json` | `switcher-headless make-scenario --out scenarios/m0.json`（默认 60 分钟） | 每 30 s 切一次（第 k 次在第 k × 1800 拍）：k 是 10 的倍数（每 5 分钟）用 Fade 30 拍，其余 Cut；切完 1 拍（Fade 后 31 拍）把 PVW 推到下一路，PGM 按 1 → 2 → … → 8 → 1 循环。`--duration 600` 只跑前 10 分钟（19 次 Cut + 5:00 处 1 次 Fade） |

两个文件都是工具生成后入库的；改了生成逻辑（Tools/switcher-headless/Sources/switcher-headless/Factories.swift）要重新生成并在对应检查点报告里说明，否则基线不可比。
之后 G3 / G4 / W4-A 各加自己的场景。
