# W1-A4 frameprobe av 的内存随录像长度线性涨 —— 报告（分支 w1-testkit-4）

日期 2026-09-28。机器 Apple M5 Max 128 GB，macOS 27.0（26A428），Xcode 27.0 / Swift 6.4，接电源，load average 1–2（别的会话零星在跑）。
worktree `.claude/worktrees/w1-testkit-4`，分支 `w1-testkit-4`，从 main `afa0ae6` 开。提交：`git log main..w1-testkit-4`
（红测试 a935107 → 根因修复 ef9fc06 → 自动释放池 361e506 → 本报告）。只动了 `Packages/SwitcherTestKit/` 的三个文件
（`Probe/MediaReader.swift`、`Fixture/SampleMovieWriter.swift`、新测试 `Tests/SwitcherTestKitTests/FrameProbeMemoryTests.swift`）和本报告；
`Tools/frameprobe/` 没改（命令行只解析参数，读文件全在 TestKit），没碰契约、`scripts/soak/`。

**一句话**：根因不是问题单猜的 readVideo 少了自动释放池，而是 `MediaReader.readAudio` 的**多声道分支每解一块就
`samples.reserveCapacity(samples.count + frameCount)`**——Swift 的 `reserveCapacity` 按"刚好够"分配、不按倍数长，于是每块（约 8192 帧）
都把整条样本数组重新分配、整条拷一遍（O(n²)），放掉的旧块也不还给系统。改成读第一块时按轨长一次预留之后：10 分钟录像峰值 RSS
**7591 MB → 173 MB**、56.9 s → 42.2 s；1 小时原片 **约 41 GB / 12.5 min → 795 MB / 246 s**；分析 JSON 与修前逐字节相同。
prompt 要的每帧 `autoreleasepool` 也加了，但实测它对这次的涨没有作用（§1.4）。

---

## 1. 做了什么

### 1.1 先复现、再定位（修前二进制 = main afa0ae6 的 release frameprobe）

录像：W4-A 的 `perf.mov`（1 分钟冒烟，1080p60 H.264 6 Mb/s + AAC 立体声 48 kHz）；`soak10m.mov` = W4-A 1 小时 `soak.mov` 的前 10 分钟
（`ffmpeg -t 600 -c copy -avoid_negative_ts disabled`，36000 帧 + AAC 立体声）；`synth60.mov` = `frameprobe synth --seconds 60`（1080p60，AAC **单声道**）。
峰值用 `/usr/bin/time -l`（maximum resident set size / peak memory footprint）。单位：`/usr/bin/time` 的数按 10^6 字节换算成 MB，
探针和用例打印的 MB 是 2^20 字节。

| 录像 | 子命令 | 峰值 RSS | peak footprint | 耗时 |
|---|---|---|---|---|
| perf.mov 1 分钟 | `av --fps 60 --discontinuities` | 732 MB | 714 MB | 4.3 s |
| perf.mov | `av --fps 60`（不带 `--discontinuities`） | 732 MB | 714 MB | 4.3 s |
| perf.mov | `stats --fps 60` / `frames`（只读画面） | 44 MB | 16 MB | 4.0 / 4.1 s |
| synth60.mov（单声道） | `av --fps 60 --discontinuities` | 55 MB | 37 MB | 4.3 s |
| soak10m.mov 10 分钟 | `av --fps 60 --discontinuities` | **7591 MB**（问题单 7.59 GB） | 7576 MB | 56.9 s |
| soak10m.mov | `stats --fps 60`（只读画面） | 58 MB | 27 MB | 41.6 s |

只读画面不涨、单声道不涨，**立体声 + 读音轨才涨**，和不连续检测无关。再用几个 20 行探针（本会话 scratchpad `probe/`，结论全抄在这里）拆开：

- **audioprobe**：readAudio 同款 AVAssetReader 循环只数块、不存样本：perf.mov 立体声 352 块、平均 8181 帧 / 块，峰值 +1 MB，包不包 `autoreleasepool` 一样 → AVFoundation 解码本身不涨。
- **reserveprobe**（纯 Swift 数组，不碰 AVFoundation，模拟 8192 帧一块的立体声下混）：逐块 `reserveCapacity(count + 8192)`：60 s **+655 MB**、180 s **+2084 MB**、600 s **+7085 MB**，
  循环结束后 footprint 不回落，耗时 0.14 / 1.25 / 15.7 s；只 `append`（按倍数长）：+23 / +81 / +302 MB，0.01 / 0.02 / 0.08 s。和问题单的 0.73 / 7.6 GB 对得上。
- **videoprobe / poolprint**：readVideo 同款循环放在 async 函数里（协作线程）连调 4 次，每次返回后 footprint +6–9 MB、不随次数涨，加不加池一样；
  循环中途 `_objc_autoreleasePoolPrint()` 看本线程攒着的对象：视频第 10 帧与第 1000 帧、音频第 10 块时都是 3 条（加池是 4 条）→
  **macOS 27 上这两个循环每帧 / 每块往调用线程 autorelease 0 个对象**。
- `OBJC_DEBUG_MISSING_POOLS=YES frameprobe av perf.mov`：3689 条，其中 3669 条是 `NSKVONotifying_AVAssetReaderTrackOutput`，约每帧一条、都不在调用线程上
  （videoprobe 4 × 3600 帧：加池 / 不加池都是 14416 条，分布在 6–7 条别的线程上），W2-A3 报告 §5 第 1 条说的就是它，管不着。

**为什么以前没撞上**：TestKit 的样例和 `SampleMovieWriter` 全是单声道，单声道分支用 `append(contentsOf:)`（按倍数长）；录制器 / 推流出来的 AAC 是立体声。
问题单说"整条音轨读成单声道 float 只占 1 小时 0.7 GB，不是主因"是对的——占地方的不是结果数组，是攒它的过程。

### 1.2 红测试 `testW1A4_frameprobeAV_peakFootprintIndependentOfLength`（a935107）

- `SampleMovieWriter.Spec` 加 `audioChannels`（默认 1，老样例逐字节不变——FixtureSnapshot 过）：≥ 2 时每个声道放同一路 `TestSignal`，交错写给 AAC / PCM。
- 用例现场写 60 s / 180 s 两段 640×360、60 fps、立体声 AAC 的合成录像（两段并发写，约 10 s）。画幅不影响涨的那部分；1080p 在 debug 下读一帧约 10 ms
  （全量跑里 RoundTrip 1080p 1200 帧整条 14.8 s），两段 14400 帧光读就要两分多钟，进不了 90 s。
  各跑一次 `FrameProbe.av`（`fps = 60`、`discontinuities = true`，与 `frameprobe av <录像> --fps 60 --discontinuities` 同一入口同一组选项），
  另起一条线程每 1 ms 读 `task_vm_info.phys_footprint` 取峰值（内核的 `ledger_phys_footprint_peak` 是进程一生的，没法按一次调用清零），**断言 180 s 峰值 − 60 s 峰值 < 100 MB**。
  先跑短的再跑长的：放掉的大块不回落，第二次的起点只会更高，这样比是偏严的。
- 旁证三条（修前就过）：`audio.channels == 2`（确实走多声道分支）、`discontinuities.sampleCount == 秒 × 48000`（整条读完）、`av.flashCount == 秒数`（分析照常）。
- 合理增长只有单声道样本（4 B × 48 kHz，1 分钟 11 MB）和逐帧读数（每帧一两百字节）：3 分钟比 1 分钟多约 24 MB。

### 1.3 修根因（ef9fc06）：整条音轨一次预留

`readAudio` 先 `track.load(.timeRange)`，读到第一块（知道采样率）时 `samples.reserveCapacity(expectedSampleCount(...))`（轨长 × 采样率，多留 1 s），
之后单声道 / 多声道都只 `append`；删掉逐块的 `reserveCapacity(count + frameCount)`。预估偏小时 append 照常按倍数长；轨长读不出或超过 2^31 个样本就不预留。
样本值、顺序、计数都不变，分析口径不变。

### 1.4 每帧 / 每块 `autoreleasepool`（361e506，prompt 要求的防护）

`readVideo`（每帧）、`readAudio`（直通读第一个样本 + 主循环每块）、`readRawNV12Directory`（每帧；目录输入的 frames / stats / switches / fade / wipe / zoom 都走它）。
闭包里 `continue` → `return true`、循环外 `repeat { more = autoreleasepool { … } } while more`，`throw` 照常往外抛；`git diff -w` 只多了池和 return。
**实测它不是这次涨的原因**：只加池、不改 reserveCapacity 的实验版红测试照样红（60 s 686.3 MB → 180 s 2135.9 MB，差 1449.6 MB，与修前一样），见 §1.1 的 poolprint。
留着是因为开销每帧几十纳秒，而包声明 macOS 15 起、别的系统版本上 AVFoundation 往调用线程放不放东西没量过，以后在循环里查 `reader.status` 之类也会被罩住。

### 1.5 其它长循环同查

- `Tools/frameprobe`：frames / stats / switches / fade / wipe / zoom / av 全走 `FrameProbe.load` → `MediaReader`（已改），CLI 自己没有逐帧循环，不用改。
- `synth`（`SampleMovieWriter.write`）：`frameprobe synth` 1080p 20 s 与 120 s 峰值 footprint 都是 67 MB，不涨，没改。
- 目录输入：300 帧 1080p NV12 目录 `frames` 峰值 footprint 9.7 MB，不涨（池照样加了）。
- `MP4Index.scan`：只读 box 头、最多 4096 个分片，不是逐帧循环，没改。`SelfCheck` / `FrameAnalysis` / `ClickDetector` 都是纯 Swift，不分配样本大小的数组。
- 同样写法在别的包还有两处（只读查过，**不是问题**）：SwitcherInputs `Common/LPCM.swift:45`、SwitcherAudio `Integration/HostClockResampler.swift:122` 也是 `reserveCapacity(count + n)`，
  但调用方每块先 `removeAll(keepingCapacity: true)` / `removeFirst`，容量留着，稳态下是空操作。

### 1.6 验证（修后二进制 = 361e506 的 release frameprobe）

| 录像 | 修前 峰值 RSS / 耗时 | 修后 峰值 RSS / footprint / 耗时 | 输出对照 |
|---|---|---|---|
| perf.mov 1 分钟 | 731 MB / 4.2 s | **45 MB** / 27 MB / 4.3 s | `av --discontinuities` 的 JSON 与 Markdown、`stats`、`frames` 的 JSON 逐字节相同（59 对整秒配对、偏移 0.000 ms、不连续 0、2880000 样本） |
| soak10m.mov 10 分钟 | **7591 MB / 56.9 s** | **172.5 MB** / 154.9 MB / **42.2 s** | `av --discontinuities` 的 JSON 逐字节相同 |
| soak.mov 1 小时（W4-A 原片 2.77 GB） | 约 41 GB / 约 12.5 min（问题单） | **795 MB** / 771 MB / **245.7 s** | 与 W4-A 修前整条跑出来的 `.build/soak/1h/probe-av.json` 逐字节相同（整秒配对 1823 对） |
| synth60.mov（单声道） | — | — | `av --discontinuities` JSON 逐字节相同 |
| 300 帧 NV12 目录 | — | — | `stats` JSON 逐字节相同 |

修后剩下的量基本就是单声道 float 样本（1 小时 172.8M 个 × 4 B = 691 MB）+ 逐帧读数，仍按长度线性，但斜率约 0.2 MB/s
（10 分钟 → 1 小时：172.5 → 795 MB；其中样本 0.19 MB/s），修前约 12 MB/s。
10 分钟少掉的 15 s 就是那 O(n²) 的拷贝。

---

## 2. 测试 ID

| 测试 | 修前 | 修后 | 阈值 | 通过否 |
|---|---|---|---|---|
| `testW1A4_frameprobeAV_peakFootprintIndependentOfLength`（180 s 峰值 − 60 s 峰值） | **1449.3 MB**（60 s 682.7 MB，调用前 16.8 MB；180 s 2132.0 MB，调用前已 670.0 MB）；只加池的实验版 1449.6 MB | **33.2 MB**（全量跑：60 s 48.7 MB、180 s 81.9 MB）；单独跑 32.1–35.9 MB | < 100 MB | 修前红 → 修后绿 |
| 同一用例耗时（debug，含现场写两段录像约 10 s） | 34.0 s | 30.4 s | ≤ 90 s（prompt） | 过 |
| 同一用例旁证：立体声 / 样本整条读完 / 每秒一次闪光 | 过 | 过 | 等式 | 过 |
| `swift test --package-path Packages/SwitcherTestKit`（修后全量，debug） | — | **71 条（main 70 + 本会话 1）0 失败 0 跳过**（410 s） | — | 过 |
| `swift test --package-path Tools/frameprobe` | — | 没有测试 target（`no tests found`；逻辑都在 TestKit 里测） | — | — |
| `make test-tools`（两个工具冒烟） | — | `frameprobe 0.1.0`、`switcher-headless 0.1.0` | 输出版本 | 过 |
| `make lint BRANCH=w1-testkit-4` | — | 禁词 / 版本号 / Package.swift / 依赖方向 / 归属（3 个文件在允许范围内）/ 实时符号全绿 | — | 过 |
| 10 分钟录像 `/usr/bin/time -l frameprobe av --fps 60 --discontinuities` | 7591 MB、56.9 s | 172.5 MB、42.2 s | 报告项，无硬阈值 | — |

---

## 3. 没做的和原因

- **`scripts/soak/soak.sh` 第 6 步的 5 分钟切段现在可以撤**（归 W4-A，本会话不动）：1 小时原片整条跑 246 s、795 MB，结果与 W4-A 修前整条那份逐字节相同；
  按修后斜率外推 8 小时约 33 min、峰值约 6 GB（样本 5.5 GB + 逐帧读数），本机 128 GB 够。撤的时候 `-avoid_negative_ts disabled`、
  `combine_segment_probes`、"切段后第一段 t = 0 那一对会配上"（w4-soak 报告 §5 第 10、11 条）这几件事一起没了。8 小时整条本会话没实跑（`.build/soak/8h/soak.mov` 21.5 GB，约半小时），留给 W4-A 撤切段时顺手验。
- **音轨仍然整条存成单声道 float**（0.69 GB / 小时）：`ClickDetector` 与不连续检测要整条样本，改成流式要动 `FrameProbe.Loaded.samples`（公开字段）和 `FrameAnalysis` 的接口，
  超出本会话；8 GB 的机器跑 8 小时录像仍然紧（约 6 GB）。
- `readVideo` 的 `frames` / `readings` 没按帧率预留：按倍数长、每帧一两百字节，10 分钟几 MB；按标称帧率预估在 VFR 文件上可能离谱，收益小，没做。
- 没给 `frameprobe synth` 加 `--channels`：用例直接用 `Spec.audioChannels`，命令行不需要；要造立体声样例可以用 ffmpeg 或以后再加。

## 4. 对契约的疑问

无。没碰 SwitcherContracts；frameprobe 的 JSON / Markdown 输出格式与数值不变（§1.6 逐字节对照）。`SampleMovieWriter.Spec.audioChannels` 是 TestKit 自己的类型，默认 1。

## 5. 下一个会话需要知道的坑

1. **Swift 的 `Array.reserveCapacity(n)` 不按倍数长**：循环里 `reserveCapacity(count + k)` 是 O(n²) 拷贝；而且 macOS 27 上放掉的大块不让 phys_footprint 回落，
   看起来就是"内存随长度线性涨"（本案 10 分钟 7.6 GB）。要么循环外按总量预留一次，要么干脆只 `append`。别的包那两处同写法稳态下是空操作（§1.5），新写的别再这么写。
   复现只要十几行：
   ```swift
   var samples: [Float] = []
   for _ in 0..<(seconds * 48000 / 8192) {
       samples.reserveCapacity(samples.count + 8192)          // 去掉这行：600 s 从 +7085 MB 变成 +302 MB
       for _ in 0..<8192 { samples.append(0.25) }
   }
   ```
2. **查内存涨先分段量，别先猜 autorelease**：`frameprobe stats`（只读画面）vs `av`（加读音轨）、单声道 vs 立体声，四次 `/usr/bin/time -l` 就定位了。
   `OBJC_DEBUG_MISSING_POOLS` 在 AVFoundation 上永远不是 0（它自己的线程上约每帧一条），条数不能单独当证据；要看调用线程攒了多少，用 `_objc_autoreleasePoolPrint()`
   （`@_silgen_name("_objc_autoreleasePoolPrint") func _objc_autoreleasePoolPrint()`，打印到 stderr，数 "releases pending"）。
3. **同一进程里连跑两次比峰值**：第一次放掉的内存不回落（红测试修前第二次调用前已经 670 MB），所以先跑短的再跑长的；比"涨了多少"（峰值 − 调用前）会低估。
4. **测 frameprobe 内存要用立体声录像**：`SampleMovieWriter.Spec.audioChannels = 2`；TestKit 别的样例都是单声道，走的是另一条分支。
5. **`/usr/bin/time -l` 同时给 maximum resident set size 和 peak memory footprint**，后者就是 phys_footprint 的峰值（与用例、Stats 的 rss_mb 同一口径）。
6. 工具坑：桌面端 Write / Edit 可能拒绝写别的 worktree（prompt 提醒过），本会话全程用 python / heredoc 写文件；Bash 工具不让 `sleep N; …` 串着等，用 `run_in_background` + `until` 循环——
   **但别用 `pgrep -f "<命令行片段>"` 当等待条件**，等待脚本自己的命令行里就有这个片段，会一直匹配到自己、永远等不完；按 PID 等（`while kill -0 $PID; do sleep 2; done`）。
   `swift test --filter` 写 `Module.Class/method`。
