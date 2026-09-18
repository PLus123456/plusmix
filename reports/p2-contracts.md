# P2 契约落地报告（分支 p2-contracts，worktree 分支 claude/contract-implementation-280194，同一提交）

prompt：docs/plan/prompts/41-P2-契约落地.md。落地提案 001（A + B）、002、004、005；006 状态"待批"，本会话未做（见 §3）。
基线：main 3c7b88d（G3 合入后）。提交：f2b8f4d（契约）→ 0412ada（填数方 + 文档）→ 报告提交 = 分支顶（`git log main..p2-contracts`）。

## 1. 做了什么

### 提案 001 A + 002：`Stats.EncoderEntry` 加 frames / dropped / disk_free_mb / reconnects / state

| 文件 | 改动 |
|---|---|
| `Packages/SwitcherCore/Sources/SwitcherContracts/Stats.swift` | `EncoderEntry` 加五个字段（init 带默认值，老调用点不用改）；`CodingKeys` / `jsonKeys` 同步；`init(from:)` 对新键 `decodeIfPresent`（0 / "idle"）；文档注释写全口径 |
| `Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/RecordingStart.swift` | `RecorderCounters.statsEntry(previous:windowSeconds:state:)`：frames = videoFrames、dropped = videoFramesRejected、disk_free_mb = diskFreeBytes / 2^20、reconnects 0 |
| `Packages/SwitcherOutputs/Sources/SwitcherOutputs/Recording/Recorder.swift` | `Recorder.State.statsName`（idle / recording / stopping / stopped / failed）、`Recorder.statsEntry(previous:windowSeconds:)` |
| `Packages/SwitcherOutputs/Sources/Streaming/StreamCounters.swift`（胶水 8 行） | `statsEntry` 填 frames = framesSent、dropped = networkDropped（E9）、reconnects、state = state.name；`StreamOutput.statsEntry` 注释同步 |
| `Packages/SwitcherOutputs/Sources/NDISend/NDISender.swift` | `NDISendCounters.statsEntry(…, running:)` 填 frames = framesSent、dropped = skipped、state = unavailable ? "unavailable" : (running ? "publishing" : "idle")；`NDISender.statsEntry` 传 isRunning |
| `Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift` | `EncoderStatsSource` 改用 `RecorderCounters.statsEntry`（上一次快照存 RecorderCounters） |

`EncoderCounters.statsEntry`（Support/，没动）仍只填 skipped / bitrate，新字段取默认值——它不知道录制器的帧数 / 磁盘 / 状态，prompt 里写的"EncoderCounters.statsEntry（Recorder：…）"按"录制器那一项"落在 `RecorderCounters` / `Recorder` 上。

### 提案 001 B：`AudioBlockConsumer` 升契约

| 文件 | 改动 |
|---|---|
| `Packages/SwitcherCore/Sources/SwitcherContracts/Render.swift` | 加 `AudioBlockConsumer`（签名逐字 = W1-E 原版），文件头的调用链加音频一行 |
| `Packages/SwitcherOutputs/Sources/SwitcherOutputs/Encoding/AudioBlockConsumer.swift` | 删除（Recorder / StreamOutput / NDISender / SignalFeeder / 测试都 import SwitcherContracts，直接见契约那份） |
| `Packages/SwitcherAudio/Sources/Integration/AudioBlockConsuming.swift` | `public typealias AudioBlockConsuming = AudioBlockConsumer`（W2-E 时期的代码与测试照常编译） |
| `Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift` | 删 `extension Recorder: AudioBlockConsuming {}` |

### 提案 004：`Stats.AudioCounters` 加 discontinuities / meters

| 文件 | 改动 |
|---|---|
| `Stats.swift` | `AudioCounters` 加 `discontinuities`、`meters`；嵌套 `Meters{buses, inputs}`、`BusMeter{bus, peak_db, true_peak_db, lufs_m, lufs_s, lufs_i, lra}`、`InputMeter{peak_db}`（键名照提案）；`Meters.floorDb = −120`、`decibels(fromLinear:)`、`loudness(_:)` 两个钳位助手 |
| `Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift` | `Bus.name`（master / busA / busB / headphones，与 `BusRouting` 的 JSON 键一致）+ `Bus(name:)`，给 `bus` 字段用 |
| `Packages/SwitcherAudio/Sources/Integration/AudioEngine.swift` | `audioCounters` 填 discontinuities（`ConsumerPump.discontinuities`）与 meters（`AudioMixer.meters` → 契约结构，槽位表换算成输入编号；dB / LUFS 钳到 −120，静音总线不再是 libebur128 的 −inf） |
| `Packages/SwitcherTestKit/Sources/SwitcherTestKit/Stats/StatsWriter.swift` | `sanitized` 覆盖新字段：表里的非有限值 → −120，其余 → 0，不丢行 |

### 提案 005：`Stats.PerInput` 加 latency_ms / latency_max_ms（只加字段，默认 0）

| 文件 | 改动 |
|---|---|
| `Stats.swift` | `PerInput` 加两个字段（init 默认 0，`decodeIfPresent`）；引擎侧算法与填数归 W1-B2（prompt 42），`EngineCounters` 现在构造的 PerInput 自然带 0 |

### TestKit 汇总与 headless summarize

| 文件 | 改动 |
|---|---|
| `Packages/SwitcherTestKit/Sources/SwitcherTestKit/Stats/StatsSummary.swift` | 全部新汇总是**可选字段**（老基线 baselines/*.json 没这些键，解码为 nil，`summarize --baseline` 不断）：`EncoderSummary.delivery{frames, dropped, reconnects（末行 − 首行）, diskFreeMb 序列, lastState, states}`、`InputSummary.latency{ms 序列, maxMs}`、`audioDiscontinuities`、`masterMeters{peakDb, truePeakDb, lufsM, lufsS 序列; lufsI, lra 末行}`。A1 判定不变（超时 + 欠载），值里附"不连续 N（流式检测，信息项）"；E1 备注里附每个编码器的帧 / 丢 / 状态 |
| `Tools/switcher-headless/Sources/switcher-headless/Summarize.swift` | `--json` 的 key 多 encoder_frames / encoder_dropped / encoder_reconnects / audio_discontinuities / master_peak_db_max / master_true_peak_db_max / master_lufs_s_min / master_lufs_s_max / master_lufs_i / l1_avg_ms_max / l1_max_ms |
| `Tools/switcher-headless/Package.resolved` | SwiftPM 解析时把 W2-D 引入的 HaishinKit 2.2.5 / Logboard 2.6.0 钉进来（任何构建都会写这份，之前是过期的） |

### 文档

- `docs/CONTRACTS.md`：头部加变更记录；§2.7 的 Stats 行与口径段按新字段重写（含 state 取值表、dB / LUFS 下限、兼容规则）；§7 加音频调用链与 `AudioBlockConsumer` 条目；§2.9 标题列出四个协议。
- `docs/contract-changes/001 / 002 / 004 / 005`：各加一行"落地：已落地（P2，2026-09-18）…"，提案正文不动。006 仍是"待批"。

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 测试 | 数值 | 阈值 / 预期 | 通过 |
|---|---|---|---|
| `testP2_stats_newFieldsRoundTrip`（SwitcherContractsTests） | Samples.stats 每个新字段非默认值，jsonLine → parse 与 JSONEncoder/Decoder 两条路往返相等 | 相等 | ✅ |
| `testP2_stats_missingKeysDecodeToDefaults_andEncodeWritesAll` | 老形态一行解码：latency 0、frames / dropped / disk / reconnects 0、state "idle"、discontinuities 0、meters 空；再写出时四节的键集合 == 各自 jsonKeys，整行字面量与预期逐字相等 | 缺键给默认、写出写全 | ✅ |
| `testP2_stats_metersJsonShape` | BusMeter / InputMeter / Meters 的 JSON 字面量与提案 004 逐字一致；`Bus.name` 可逆；`decibels(fromLinear:)` 0 → −120、1 → 0、1e-9 → −120；`loudness` −inf / NaN → −120 | 逐字 | ✅ |
| `testP2_stats_oldGateFilesParse` | 嵌入的 G2 / G3 老行 + 本机 `.build/gate2`、`.build/gate3` 下 4 个老 stats.jsonl（G2 10 min 600 行、G2 1 h 3600 行、G3 10 min 600 行、G3 run1 601 行，共 5401 行）每行 `parse(line:)` | 全部解析 | ✅（5401 / 5401） |
| `testP1_stats_jsonKeysSnapshot`（字面量更新） | 新快照字面量 + 三节 jsonKeys 数组 | 逐字 | ✅ |
| `testP2_audioBlockConsumer_isAContractProtocol` | 契约协议可实现、可按 `any AudioBlockConsumer` 派发，planes / channelCount / frameCount / hostTime 原样到达 | — | ✅ |
| `testP2_recorder_statsEntryCarriesFramesDiskAndState`（SwitcherOutputsTests） | idle → start 后 state "recording"、frames / dropped / reconnects 0、disk_free_mb > 200 → 一帧没写就 stop → "failed" | 状态映射 | ✅ |
| `testP2_streamOutput_statsEntryCarriesFramesDropsReconnectsAndState`（StreamingTests，假传输层） | idle → publishing → 喂 1 s → stop：frames = framesSent（> 0）、dropped = networkDropped、reconnects、state "stopped"、disk_free_mb 0 | 与 StreamCounters 一致 | ✅ |
| NDISendTests `testDryRunPipeline_boundedQueueAndCounters`（加断言） | 本机有 NDI SDK：干跑时 state "publishing"，stop 后 "idle"，frames = framesSent | 提案 002 | ✅ |
| NDISendTests `testUnavailableWithoutSDK_emptyImplementation`（加断言） | 无 SDK 机器：state "unavailable"、frames 0 | 提案 002 | 本机 SDK 在，XCTSkip（原有行为） |
| `testP2_audioCounters_carryMetersAndDiscontinuities`（IntegrationTests，离线台） | dropouts / underruns / discontinuities 与 `status` 同源；buses 顺序 = Bus.allCases；Master 峰值 > −30 dBFS 且与 status 一致（1e-9）；LUFS 瞬时 > −60；所有表值有限且 ≥ −120；inputs 键 = {1, 2}，AFV 门控的 2 号 < −90 dBFS；整行 JSON 往返 | — | ✅ |
| `testP2_statsSummary_newFieldsAndOldBaselineDecode`（SwitcherTestKitTests） | 3 行手写样本：delivery.frames 120 / dropped 1 / lastState "stopped" / states {recording 2, stopped 1} / diskFreeMb min 998 max 1000；latency.ms avg 32 max 34、maxMs 50；audioDiscontinuities 1；masterMeters peak min −10 max −6、truePeak max −5.5、lufsM min −20 max −18、lufsS max −19、lufsI −21、lra 3；A1 值含"不连续 1"；去掉新键的老基线 JSON 解码为 nil；−inf 表值清洗成 −120、NaN 延迟 / inf 磁盘清洗成 0 且能写出 | 手算 | ✅ |
| `make lint`（BRANCH=p2-contracts） | 禁词 / 版本 / Package 约束 / 依赖方向 / 归属 30 个文件在范围内，胶水 SwitcherAudio 22、SwitcherOutputs 43、SwitcherTestKit 36（各 ≤ 50）/ rt-symbols | 全绿 | ✅ |
| `make test`（六个包 + 两个工具冒烟 + App xcodebuild test） | 退出码 0（2026-09-18 11:2x–12:07）：SwitcherCore 153（Contracts 53 / Engine 73 / Render 27）、Inputs 28（4 跳）、Audio 88（SwitcherAudioTests 52（2 跳）+ IntegrationTests 36（3 跳））、Outputs 55（SwitcherOutputsTests 28（4 跳）+ StreamingTests 19 + NDISendTests 8（2 跳））、Control 28、TestKit 50；headless / frameprobe 冒烟输出 0.1.0；App `xcodebuild test` 通过（-quiet，只打印失败）。日志里唯一的 error 字样是 SwiftPM 拉 hummingbird 缓存的网络警告 | 全绿 | ✅ |
| `make gate3-run` 的 stats.jsonl（实际跑 `scripts/gate3.sh --minutes 10 --label 10min`，= 该目标去掉 `--write-baseline`） | 12:08 起，脚本结论「G3 自动项全部满足」（V1 avg 1.926 / p99 2.053 ms，V2 0，V3 p99 0.037 ms，V4 0，V6 / V7 / A1–A4 / E1 / E3 / E5 / C1–C4 全过，E2 本场景不适用同 G3）。stats.jsonl 601 行：5 个 encoder 条目（PGM + 4 路 ISO 录制器）frames 首行 9 → 末行 36000，相邻行 3000 / 3000 对严格递增，每秒增量 51–62；state 600 行 recording、末行按封口顺序 stopped / stopping / recording（最后一行采在收尾中）；dropped / skipped / reconnects 全 0；disk_free_mb ≈ 1 650 000；audio.meters.buses = [master, busA, busB, headphones]，master peak_db −20.00 dBFS（合成源 −20 dBFS 测试音，601 行无一行 −120）、lufs_m −18.5 / lufs_s −19.3 / lufs_i −19.3、true_peak −20.00，busA / busB / headphones 全 −120；inputs 键 1–4，峰值都 −20 dBFS；discontinuities 0；per_input 五个键齐全，latency_ms / latency_max_ms 共 4808 条全 0；整文件无非有限值。summarize `--json` 新 key 有值：encoder_frames 179955（= 5 × (36000 − 9)）、encoder_dropped 0、master_peak_db_max −20.00、master_lufs_i −19.34、l1_* 0。S2 行 13.24 MB/h 标 ❌ 但注明「不足 1 h 整段拟合仅供参考」，不在自动判定项里（对比见 §5） | encoder[].frames 逐秒增长、encoder[].state 有值、audio.meters.buses[0].peak_db ≠ −120、per_input[n].latency_ms 存在（W1-B2 前为 0） | ✅ |

## 3. 没做的和原因

- **提案 006（合成源噪声底纹）**：文件状态"待批"，prompt 写"006 若批"，本会话没动 `TestPattern`。批了之后是 `TestPattern.Background` 加 `.noise(level:amplitude:seed:)` + CPU 参考实现 + Codable 往返测试（帧号 / 时间戳 / ID / 闪光块区域不加噪声），一个短会话的量；合成源实现归 W1-A2（prompt 44）。
- **提案 005 的引擎侧**（`Engine` / `EngineCounters` / `StatsAssembler` 算 L1）：归 W1-B2（prompt 42），本会话只加字段；因此 gate3 的 `per_input[n].latency_ms` 全是 0。
- **StatsSummary 没加 L1 的判定行**：数字都是 0 时会得到假"通过"，等 W1-B2 填了数再由 W1-A2 / G4 加（§4 阈值按输入类型分别报，还要节目帧时长换算）。
- **A1 判定没把 discontinuities 加进和里**：prompt 要求不改阈值 / 判定；流式计数是平台启发式（合成信号的 click 按启发式排除），正式口径是离线检测（G3 报告 §10 A1 行），所以只放进值里当信息项。
- **App 没动**：`App/Sources/UI/StatusLineFormatter.swift` 第 26 行的注释还写着"提案 001 待批"，底栏也还没显示 state / frames——归 W2-B2（prompt 43）。App 的 `StatsPump` / `StatusLineTests` 用旧 init，带默认值照常编译。
- **测试标准 §7 的字段行**（docs/spec/ 不归本会话）：见 §4 末尾，请用户同步。

## 4. 对契约的疑问

1. **录制的 state 值 "recording"**：提案 002 的取值表是推流状态机的节点（idle / connecting / publishing / backoff / stopping / stopped / failed / unavailable），没有录制进行中的词；prompt 41 写"state 按录制状态"，我加了 `recording`（`finished` → `stopped`，`failed` → `failed`）。若希望闭集不变，把 `Recorder.State.statsName` 的 `.recording` 改成 `"publishing"` 一行即可。
2. **NDI 的 `dropped = skipped`**：按提案 002 逐字落地——NDI 没有编码器，队列满丢的帧既是 E1 的 skipped 也是"落地之前丢的"，同一事件计两次。如果不想双计，可改成 `conversionFailures`。
3. **新增的公开小件**（都在 SwitcherContracts）：`Bus.name` / `Bus(name:)`（提案 004 的 `bus` 是字符串，得有个来源）、`Stats.AudioCounters.Meters.floorDb / decibels(fromLinear:) / loudness(_:)`（把"下限 −120、−inf 不进 JSON"钉在契约里，填数方与清洗方共用）。都是加法，没有提案文件；不想要的话删掉后 AudioEngine / StatsWriter 各改两行。
4. **LUFS 静音钳到 −120**：提案 004 只写了峰值的下限；libebur128 对静音给 −inf，JSON 写不了，所以 LUFS / LRA 也钳到 −120。
5. **`disk_free_mb` 用 2^20 字节**（与 `rss_mb` 的 phys_footprint / 1_048_576 同口径），提案没写明进制。
6. **`state` 保持 String 而不是枚举**：照提案；CONTRACTS.md §2.7 列了三类输出各自的取值。

**测试标准 §7 需要用户同步的行**（docs/spec/导播台测试标准.md，第 305 行附近）：

> stats.jsonl 每行字段：ts、tick、render_ms、missed_render、jitter_ms、per_input{fps, dup, drop}、encoder[{skipped, bitrate}]、audio{dropouts, underruns}、rss_mb、cpu_pct、gpu_pct。

改为：

> stats.jsonl 每行字段：ts、tick、render_ms、missed_render、jitter_ms、per_input{fps, dup, drop, latency_ms, latency_max_ms}、encoder[{skipped, bitrate, frames, dropped, disk_free_mb, reconnects, state}]、audio{dropouts, underruns, discontinuities, meters{buses[{bus, peak_db, true_peak_db, lufs_m, lufs_s, lufs_i, lra}], inputs{n: {peak_db}}}}、rss_mb、cpu_pct、gpu_pct（P2 按提案 001 / 002 / 004 / 005 扩，2026-09-18；老文件缺键按 0 / "idle" / 空读）。

（§1 的 A1 定义"超时 + 欠载 + 不连续"现在三项都在 Stats 里；L1 有字段但引擎填数在 W1-B2。）

## 5. 下一个会话需要知道的坑

- **要 rebase 的分支**：没有。`git branch --no-merged main` 只有本会话的两个引用（同一提交）；W1 / W2 各功能分支和 g2 / g3 都已在 main 里。续做分支（w1-core-2 / w2-app-2 / w1-testkit-2 / w1-outputs-2 / w1-audio-2）还没开，等 p2 合入 main 后从 main 开即可，不用 rebase；其中 W1-B2（005 引擎侧）、W1-A2（006 落地后）、W2-B2（底栏显示 state / frames / 表）直接用这里的字段。
- **S2 对比（每秒拷一份表没引入内存增长）**：本次 10 分钟 RSS 816 → 833 MB（13.24 MB/h，整段拟合）；G3 的两次 10 分钟是 818 → 839 MB（68.56 MB/h）和 820 → 834 MB（50.77 MB/h）。都是「不足 1 h 仅供参考」，正式 S2 归 W4-A 的 1 h / 8 h。
- **`swift test` 会在 `Packages/SwitcherOutputs/`、`Packages/SwitcherTestKit/` 生成未跟踪的 `Package.resolved`**（仓库只跟踪 SwitcherControl 与 headless 的）；`check-ownership.sh --include-working-tree` 会把它们按行数算成胶水，提交前别 `git add -A` 把它们带进去（我第一次就撞上了）。
- **`make gate3-run` 会重写 `reports/G3-run-10min.md` / `reports/G3.md` 并写 `baselines/g3-m5max.json`**：本会话只用它验字段，跑的是 `scripts/gate3.sh --minutes 10 --label 10min`（不带 `--write-baseline`），跑完把 reports/ 的两份改动还原了，数据留在本 worktree `.build/gate3/10min/`。
- **老 stats.jsonl 兼容测试**默认扫本 worktree 的 `.build/gate2`、`.build/gate3`；新 worktree 没有这些目录时只验嵌入的两行并 XCTSkip。我从 `/Users/plus/plusmix-g2-m0/.build/gate2/{10min,1h}` 和 `wonderful-fermi-40fe5f/.build/gate3/{10min,10min-run1}` 各拷了一份到本 worktree（不入库）。
- **`EncoderCounters.statsEntry` 仍是"基础项"**（state 恒 "idle"、frames 0）：别拿裸编码器的它当输出项，录制 / 推流 / NDI 各自有带数的版本。
- **`AudioEngine.audioCounters` 现在每次都拷一份表**（`sw_mix_ctx_copy_meters` seqlock + 槽位表加锁）：1 Hz 的 Stats 采样线程用没问题，别在更高频率的路径上调它，UI 的表继续读 `meters` / `status`。
- **StatsSummary 的新汇总都是 Optional**：`summarize --baseline` 读老基线时它们是 nil；写新基线时才有。判定表（verdicts）没有新行，G4 比较老基线不受影响。
- `Tools/switcher-headless/Package.resolved` 这次被更新（HaishinKit / Logboard 的钉），以后构建不会再改它。
