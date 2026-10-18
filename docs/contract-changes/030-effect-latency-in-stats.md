# 030 效果链延迟进 Stats（铁律 4：统计只有一份）

状态：**已批**（用户 2026-10-17 "ABC 按照你说的来"：批，归 P5-4 落地，prompt 115）。提出：reports/w1-audio-3.md §4 第 5 条、reports/w5-audio-bus-effects.md §4 第 5 条；G8 2026-10-12 列为待定（当时只有编号没有文件）；G9 2026-10-17 写成提案。

## 改什么

`Stats.audio`（`AudioCounters`）加一节 `effects`：

```json
"audio": {
  "dropouts": 0, "underruns": 0, "discontinuities": 0, "meters": { … },
  "effects": {
    "buses": [ { "bus": "master", "latency_ms": 5.33, "measured_latency_ms": 0.0 },
               { "bus": "busA",   "latency_ms": 0.0 },
               { "bus": "busB",   "latency_ms": 0.0 } ],
    "inputs": { "3": { "latency_ms": 1.33, "measured_latency_ms": 0.0 } }
  }
}
```

- `buses[].bus`：master / busA / busB（与 `meters.buses[].bus` 同一取值）；`latency_ms` = 这条总线效果链当前的总处理延迟（`AudioEngineStatus.BusEffects.latencyFrames / 采样率 × 1000`，没装效果 = 0）；
  `measured_latency_ms` = 自写压缩器 `compressor` 冲激法自测的延迟（`compressorMeasuredLatencyFrames`），链里没有它就缺键。
- `inputs`：键 = 输入编号的字符串（与 `meters.inputs` 同一写法），只列装了效果的路；值同上（`InputEffects.latencyFrames` / `compressorMeasuredLatencyFrames`）。
- 瞬时值、不累计；由 AudioEngine 的控制线程每次出 Stats 行时从 `AudioEngineStatus` 拷（1 Hz，不进实时线程、不分配热路径）。
- Codable：缺键 = 空（`buses: []`、`inputs: {}`），老文件 / 老读者不受影响；不加命令，命令数仍 42。

## 为什么

- 效果链的处理延迟现在只在 `AudioEngineStatus`（App 的音频设置窗能读，"延迟自测"一行），API / 状态页 / stats.jsonl 看不到；`video_delay_ms` 只等于 Master 链的延迟，Bus A / B 与每路的延迟没有任何对外口径（手册只能写"Bus A / B 不补"）。
- 铁律 4：所有数字进 Stats，UI、API、测试三方读同一个结构。

## 影响谁、怎么迁移

- `AudioCounters`（SwitcherContracts）加嵌套类型 `EffectsLatency` + `jsonKeys`；`docs/CONTRACTS.md` audio 一节；测试标准 §7 的字段行（P5-4 按 G 类口径权限补字段名，阈值不动）；`docs/api/README.md` §5 一行（归 W4-C）。
- 填数：`Packages/SwitcherAudio/Sources/Integration/AudioEngine.swift`（≤ 60 行）；headless / App 的 stats 行把 `AudioCounters` 整个透传，不用改——落地时核对两边 stats.jsonl 真有这一节。
- 读者：App 状态页 / API 客户端想显示再接（不在本提案里）；gate4 / soak 报告脚本不读它。

## 不做

- 不改 `video_delay_ms` 的口径（仍 = 为监听同步把视频延后的毫秒数）。
- 不进 `per_input`（那是视频计数）。

## 2026-10-18 用户裁定：`buses` 也列耳机总线

P5-4 落地时按正文只列 master / busA / busB（reports/p5-contracts-4.md §4 第 1 条）；耳机总线也能装效果（调音台耳机条有"效果"按钮），用户 2026-10-18 定**列进来**：`buses[].bus` 四个值（与 `meters.buses[].bus` 同一取值），改一行常量、JSON 形态不变。填数那一行归 G10 胶水（没做就 123 P5-5 做），本文与 CONTRACTS.md / 测试标准 §7 的文字归 123。
