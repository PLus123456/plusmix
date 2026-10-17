# 030 效果链延迟进 Stats（铁律 4：统计只有一份）

状态：**已落地**（P5-4 / prompt 115，2026-10-18，分支 `p5-contracts-4`：契约 87a5bab、填数 26e8d3d、文字 75c4fb4；见文末落地记录）。原状态：**已批**（用户 2026-10-17 "ABC 按照你说的来"：批，归 P5-4 落地，prompt 115）。提出：reports/w1-audio-3.md §4 第 5 条、reports/w5-audio-bus-effects.md §4 第 5 条；G8 2026-10-12 列为待定（当时只有编号没有文件）；G9 2026-10-17 写成提案。

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

## 落地记录（P5-4 / prompt 115，2026-10-18）

分支 `p5-contracts-4`：契约 87a5bab、填数 26e8d3d、CONTRACTS.md / 测试标准 §7 的文字 75c4fb4。按正文落了，键名、形态与上面的示例一致；细化 / 与正文不同的三处在最后。

- **契约**（Stats.swift）：`Stats.AudioCounters.effects: EffectsLatency`（JSON 键 effects，排在 meters 之后；构造函数最后一个带默认值的参数，现有调用点一个不改）；
  `EffectsLatency{buses: [BusLatency], inputs: [Int: InputLatency]}`、`BusLatency{bus, latencyMs, measuredLatencyMs?}`、`InputLatency{latencyMs, measuredLatencyMs?}`（键 latency_ms / measured_latency_ms，nil 不写键）；
  四个层级各有 `jsonKeys`（AudioCounters 的末尾加 effects）、`listedBuses = [.master, .busA, .busB]`、`milliseconds(frames:)`（frames / `AudioFormat.sampleRate` × 1000，填数方唯一的换算）；缺键 = 空（effects 整节缺、或 buses / inputs 各自缺），写出写全。
- **填数**（AudioEngine.swift +17 行，只动 `audioCounters` 和紧挨着的新函数 `statsEffects`）：`audioCounters`（引擎采样线程每秒取一次）从 `status`（控制循环每 50 ms 刷新的 `AudioEngineStatus`，App 音频设置窗读的同一份）拷；
  buses 按 listedBuses 总是三条（`BusEffects.latencyFrames`；measured = `compressorMeasuredLatencyFrames`）；inputs 只列 `eqBands > 0 || dynamicsKind != nil` 的路（`InputEffects.latencyFrames`；measured 只在 `dynamicsKind == .compressor` 时给）。不进实时线程、不碰混音器。
- **透传核对**：App（`SwitcherSession`）与 headless（`HeadlessRun`）都是 `engine.audioStatsProvider = { audioEngine.audioCounters }`，Stats 整行进 stats.jsonl / API / 状态行；TestKit `StatsWriter.sanitized` 也是整份拷，不丢这一节——两边都没改。
  实测（reports/p5-contracts-4.md §2）：headless 4 s（m0 节目加 Master 限幅 / Bus A 压缩器 / Bus B 动态处理器 / 输入 1 EQ + 压缩器）的 stats.jsonl 每行都是
  `"effects":{"buses":[{"bus":"master","latency_ms":12},{"bus":"busA","latency_ms":0,"measured_latency_ms":0},{"bus":"busB","latency_ms":5.333333333333333}],"inputs":{"1":{"latency_ms":0,"measured_latency_ms":0}}}`（同一行 video_delay_ms = 12 = Master 那一项）；App 的 `StatusLineTests` 写出的 stats.jsonl 每行也有这一节（没装效果：三条总线 0、inputs 空）。
- **用例**：`Contracts030Tests` 3 条（JSON 形态逐字、缺键 = 空 + App 的老 stats.jsonl 照读、键名快照 / listedBuses / 帧 → 毫秒）、`IntegrationTests.EffectsLatencyStatsTests.test030_audioCountersEffects_masterLimiterInputEQ_copiedFromStatus_unlistedInputsAbsent`
  （Master 一格限幅 → `buses[master].latency_ms` = `status.latencyFrames / 48 000 × 1000` = 12 ms；输入 2 一格 EQ → `inputs["2"]` = 0；没装的 1 号不列；Bus A 压缩器、输入 3 压缩器写 measured 0、输入 4 动态处理器 5.333 ms 不写 measured；压缩器换成 EQ 后 measured 缺键）、`CodableTests` / `StatsP2Tests` 的整行字面量重生成。
- **细化 / 与正文不同**：
  1. "只列装了效果的路"落成"契约链里至少有一格装进了这一路的 EQ / 动态格（格关着也列、延迟 0）"——prompt 的用例"某一路装一格 EQ → inputs["n"]"要求列，而 EQ 的延迟本来就是 0，所以按"装了"不按"延迟 > 0"判；链里只有认不出 / 装不上的格（每路的 peakLimiter 之类）不算装了。
  2. 每路的 measured 按 dynamicsKind 判：探针证实 `AudioEngineStatus.InputEffects.compressorMeasuredLatencyFrames` 在压缩器换成别的之后仍是上一次的值（W1-D3 的 `InputEffectsController` 不清旧值；本会话只许动出 Stats 那一处，没改），照拷会在"链里没有它"时多写一个 measured。总线的跟着装着的格走，没有这个问题。
  3. 耳机总线按正文不列；但它也有效果链（App 调音台耳机条有"效果"按钮，混音器四条总线都能装），它的延迟目前没有对外口径——要列就是 `listedBuses` 加一项、JSON 形态不变（报告 §4 请用户定）。
- 没做：App 状态页 / API 的展示（以后的 App 会话）；docs/api/README.md §5 一行（归 W4-C）。
