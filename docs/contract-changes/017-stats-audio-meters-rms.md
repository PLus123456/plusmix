# 017 `Stats.audio.meters` 加 RMS（`rms_db`）

提出会话 / 分支：W3-B2 / w3-compositor-3（worktree 分支 `claude/w3-compositor-audio-meters-labels-e0dba1`，2026-09-23）
状态：**已落地**（用户 2026-09-24 批："017 批了 … 都顺手做了"；G4 续做合入会话按授权落地：契约 `BusMeter` / `InputMeter` 加 `rmsDb`（缺键 = 空数组），C 热路径每块每声道平方和 → 300 ms 一阶平均的均方（不在回调里开方，Swift 侧 10·log10），`AudioMixer.meters` / `AudioEngine.audioCounters` / `AudioEngineStatus` 带出，渲染器有 RMS 时画"RMS 实心条 + 峰值细线 + 保持线"、没有时照旧，新参考图 `v8-multiview-meters-rms.png`；CONTRACTS.md §2.7、测试标准 §7 同步）

## 改什么

提案 004 的表读数只有峰值类的数：输入 `{"peak_db": [L, R]}`，总线 `{"peak_db", "true_peak_db", "lufs_m", "lufs_s", "lufs_i", "lra"}`。提议两处各加一项 `rms_db`：

```
"meters": {
  "buses":  [ {"bus": "master", "peak_db": [L, R], "rms_db": [L, R], "true_peak_db": [L, R], "lufs_m": x, …}, … ],
  "inputs": { "1": {"peak_db": [L, R], "rms_db": [L, R]}, … }
}
```

| 键 | 类型 | 口径（提议） |
|---|---|---|
| `rms_db` | [L, R] dBFS | 推子后（与 `peak_db` 同一个取样点）的均方根电平，`20·log10(rms)`，下限 −120（`Meters.floorDb`）。积分：一阶指数平均，时间常数 300 ms（VU 表的积分时间，IEC 60268-17），每个混音块更新一次；采样那一刻的值 |

Swift 侧：`Stats.AudioCounters.InputMeter` / `BusMeter` 各加 `public var rmsDb: [Double]`（CodingKey `rms_db`），`init(from:)` 用 `decodeIfPresent`（缺键 = 空数组），`jsonKeys` 加一项。

## 为什么

- prompt 66（W3-B2）交付 2 要求多画面电平表画"峰值与 RMS"。契约里没有 RMS，混音器的表（`AudioMixer.meters`，W1-D 的 C 热路径）也不算它；
  渲染器不能自己算（铁律 4：数只有一份，而且渲染器拿不到音频）。所以 W3-B2 现在只画**峰值 + 1 s 峰值保持**，RMS 做不到。
- 峰值条跳得快、看不出"平均有多响"；RMS 实心条 + 峰值细线是导播台 / 调音台常见的读法。总线的 `lufs_m` 是 K 加权、声道合并的响度（单位 LUFS），
  拿它冒充 RMS 口径不对，输入也没有这一项，所以没有用它凑。

## 影响谁

- **SwitcherContracts**：`Stats.swift` 两个结构各加一个字段 + CodingKeys + `jsonKeys`；`SwitcherContractsTests` 的 jsonKeys 快照与往返用例。
- **SwitcherAudio（W1-D 的目录）**：表的 C 热路径多算一项：每块每声道平方和 → 一阶平均（一次乘加，无锁无分配），进 seqlock 快照；`AudioMixer.meters` 带出。
- **SwitcherAudioIntegration（W2-E）**：`AudioEngine.audioCounters`、`AudioEngineStatus` 填 `rmsDb`。
- **SwitcherRender（W3-B2 之后的合成会话）**：`MultiviewMeterFeed` 多读一项，`CompositorPasses.drawMeterLevels` 改成"RMS 实心条 + 峰值 2 px 线 + 峰值保持线"（一处）；
  参考图 `v8-multiview-meters.png` 要重生成。没有 RMS 的老数据照现在的画法（只画峰值）。
- **App（W3-E2 之后）**：调音台的 `MeterBar` 可以用同一份数画 RMS。
- **docs**：测试标准 §7 的字段列表、CONTRACTS.md §2.7 各加一句。

## 怎么迁移

Stats 不在 Show 里，`Show.schemaVersion` 不动。老 stats.jsonl 缺 `rms_db` → 空数组，渲染器当"没有 RMS"，画法与现在相同；写出总是写全。
