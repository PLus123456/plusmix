# W2-A3 文件输入循环泄漏修复（G5 阻塞项 1，S2）—— 报告（分支 w2-inputs-3）

日期 2026-09-28。机器 Apple M5 Max / 128 GB，macOS 27.0 (26A428)，Xcode 27.0 (27A266a)，Swift 6.4，电源适配器，load average 2.6–2.8（机器上还有别的会话在跑）。
worktree `.claude/worktrees/w2-inputs-3`，分支 `w2-inputs-3`，从 main `e78d4ec`（含 e5cb96d 的 G5 快进与 W4-A 的 `scripts/soak/fileprobe/`）开。
提交：`git log main..w2-inputs-3`（四个：红测试 897d63f → 修复 de94da8 → 类注释 c3081de → 报告 + 问题单）。只动了 `Packages/SwitcherInputs/Sources/SwitcherInputs/{Common/InputThread.swift, File/FileInput.swift}`
和 `Packages/SwitcherInputs/Tests/SwitcherInputsTests/{FileInputTests.swift, Support/TestSupport.swift, Support/LoopClipWriter.swift（新）}`，外加本报告与一张问题单（§3.4）。没碰契约、DeckLink / NDI、headless、soak 脚本。

**一句话**：根因就是问题单 §3 说的那个——`InputThread` 是裸 `pthread_create` 起的线程、没有自动释放池，`copyNextSampleBuffer()` 每调一次 AVFoundation 内部 autorelease 的
reader / track output 就永远多一个引用；`decodeLoop` / `paceLoop` 每轮迭代包进 `autoreleasepool {}` 之后，120 圈的 footprint 从 +65.7 MB 变成平的，
`heap` 里活着的 `AVAssetReader` 从"每圈一个"（11 圈 12 个）变成 1 个。

---

## 1. 做了什么

### 1.1 先写测试（红）：`testS2_fileLoop_noAutoreleaseLeakPerLoop`（`FileInputTests.swift`）

- 素材现场造：`Support/LoopClipWriter.swift` 用 AVAssetWriter 写 320×240 / 30 fps / 6 帧（0.2 s）的 H.264 + 440 Hz 正弦 AAC 立体声（视频 / 音频按时间交错喂，否则
  AVAssetWriter 多路输入会互相等）。不依赖摄像头 / 权限 / ffmpeg，几百毫秒写完。
- `endAction = .loop`、速率 1、接 `RecordingAudioRing`（`keepSamplesUpTo = 0`，只计块不存样本，免得记录本身把 footprint 撑大）——**必须接音频环**：
  `audioRing == nil` 时 `FileReader` 不建音频 track output，泄漏大头（AAC → LPCM 转换器，约 0.5 MB / 个）就不出现。
- 每圈（`fileCountersSnapshot.loops` 变化时）采一次 `phys_footprint`（`task_vm_info`，与 Stats 的 `rss_mb`、fileprobe 同一口径；`TestSupport.ProcessFootprint`），
  预热 10 圈，对第 10–60 圈做最小二乘直线拟合（`TestSupport.linearSlope`），**斜率必须 < 0.1 MB / 圈**。5 圈 / 秒，整条用例 12 s。
- 修前：**0.465 MB / 圈**（第 10 圈 20.2 MB → 第 60 圈 43.3 MB，51 点）→ 红。修后：**0.017 MB / 圈**（15.9 → 17.0 MB）→ 绿。
- 第一版用 1 s 片段 + 速率 8 想跑得快一点，结果 40 s 只转了 3 圈、推帧线程饿死（`ticksStarved` 2360、`audioChunksSkipped` 7437、`lateWakes` 1160 万）——
  那是另一个问题（§3.4、§5），与泄漏无关，改回速率 1 + 0.2 s 片段。

### 1.2 修法：两条循环每轮一个池 + InputThread 兜底

`File/FileInput.swift`：

- `decodeLoop`：`while !thread.isStopRequested { autoreleasepool { …原来的循环体… } }`，闭包里原来的三处 `continue` 改成 `return`。
  每轮的状态（reader、loopBase、videoDone / audioDone、audioPlanes）都还是循环外的局部变量，闭包不逃逸、直接改。
- `paceLoop`：同样包法，闭包返回 Bool（`continue` → `return true`，`if thread.isStopRequested { break }` → `return false`），循环外 `if !keepGoing { break }`。
  这条线程现在只碰帧槽 / 环 / 原子计数，不调 ObjC 框架（`git diff -w` 看得出除了缩进只改了这几行）；包上是让以后加进来的 CoreMedia / AVFoundation 调用也按轮排水。
- 池的 push / pop 是线程局部页操作，没有锁、没有日志、没有系统调用；两条线程本来就允许锁和分配（设计方案 §3.2 说的热路径是渲染 / 音频线程）。热路径规则不变。

`Common/InputThread.swift`：`run()` 里 `autoreleasepool { work?(self) }` 给整个线程体套一个池（零散的 ObjC 调用——出错文案、格式描述查询——不再是 "no pool in place"，
线程退出时排水），类注释写明**"循环里碰 ObjC 框架的输入必须自己把每轮迭代包进 autoreleasepool {}"**。

**为什么选"循环里包"而不是"给 InputThread 加按迭代排水的入口"**：InputThread 的 body 是一整个循环的闭包，"按迭代排水"要么改成 `body` 每轮被调一次
（FileInput 两条循环的局部状态都得搬进对象里，改动大、容易引入行为差异），要么就是再包一层 `autoreleasepool` 的语法糖——排水点离 AVFoundation 调用越近越看得懂，
所以直接写在循环里；线程级的池留在 InputThread 里兜底。两者加起来每个用 InputThread 的输入都受益：零散调用有池，循环按轮的规矩写在类注释里。

### 1.3 顺手查了其他 InputThread 用户（只读，没改）

| 输入 | InputThread 循环体 | 调 ObjC 框架？ |
|---|---|---|
| `ImageInput.run` | `slot.push` / 原子计数 / `sleep` | 否（图片解码在 `start()` 的调用线程） |
| `AudioDeviceInput.pumpLoop` | `AudioCaptureBuffer.drain`（C 交接区）/ `AudioRateConverter.convert`（AudioConverter C API）/ 环 write / `Mutex` | 否 |
| `CameraInput` / `ScreenInput` | 没有 InputThread；帧回调在自己的 DispatchQueue（GCD 每块都排水）；`NoSignalWatchdog` 是 DispatchSourceTimer | — |
| `NDIInput.loop`（Sources/NDI，本会话不准动） | SDK C 调用 + `handleVideo` / `handleAudio`（CVPixelBuffer 是 CF，不走 autorelease） | 看代码没有；InputThread.run() 的兜底池现在也罩着它 |
| DeckLink（Sources/DeckLink，不准动） | 没用 InputThread（C++ 桥接回调） | — |

### 1.4 验证（`scripts/soak/fileprobe`，只起 FileInput：LockFreeFrameSlot(3) + CAudioRing(2)，`--consume`；片段 = e4-source.mov 截 5 s 转 H.264 40 Mb/s + AAC，`endAction = loop`）

修前二进制 = 提交 897d63f（只加了测试）编的 fileprobe，修后 = de94da8。原始日志在本会话 scratchpad（`…/scratchpad/w2a3/`），关键数字全部抄在这里。

**(a) `OBJC_DEBUG_MISSING_POOLS=YES fileprobe f.json 60 --consume 2>&1 | grep -c "no pool in place"`**

| | 总数 | 其中我们线程上的（lldb 按线程归因，30 s） | 类名分布 |
|---|---|---|---|
| 修前 | **13 433** | `file-decode-1` 1011 条（AVAssetReader 4086 + 部分 track output + `__NSSetI` / `NSKeyValueObservance` 等） | `NSKVONotifying_AVAssetReaderTrackOutput` 7256、`AVAssetReader` 4086、`__NSSetI` 441、`OS_os_log` 212… |
| 修后 | **7 383** | **0**（`file-decode-1` / `file-pace-1` 一条都没有） | `NSKVONotifying_AVAssetReaderTrackOutput` 7254，其余 < 60 |

修后剩下的 7 383 条**不在我们的线程上**：3 658 / 30 s 在 AVFoundation 自己的 `com.apple.coremedia.assetreader` 串行队列（`figAssetReaderSampleBufferDidBecomeAvailable`
→ CFNotificationCenter 回调里 autorelease 了 track output，GCD workloop 线程那一刻没有池——Apple 框架内部、每个样本一次、修前修后都是这个数），110 条在 fileprobe
自己的主线程（`main.swift` 顶层用 `JSONSerialization` 解节目文件；Swift 命令行的主线程也没有池，W4-A 的目录、不归我改，一次性、不随圈涨），另有 ~20 条在
`URLAssetWorkQueue` / `CommonURLAssetTrackNotificationQueue`（打开文件时一次性）。**所以 prompt 里"应为 0"这条按字面没达到，按意义达到了**：我们线程上是 0，
剩下的都是 Apple 队列上的、且不会攒内存——(c) 的 `heap` 计数直接证明。归因脚本见 §5 第 1 条。

**(b) `fileprobe f.json 600 --consume`（120 圈，每 30 s 一行；footprint MB）**

| 时刻 | 30 s / 5 圈 | 120 s / 23 圈 | 301 s / 60 圈 | 450 s / 90 圈 | 601 s / 120 圈 | 直线拟合（20 点） | stop() 后 |
|---|---|---|---|---|---|---|---|
| 修前 | 21.7 | 29.3 | 60.2 | 73.8 | **87.4** | **0.547 MB / 圈 = 394.5 MB/h** | 53.9 |
| 修后 | 19.7 | 16.8 | 32.6 | 32.7 | **32.7** | 0.095 MB / 圈（见下） | 14.4 |

修前 +65.7 MB / 115 圈，与问题单的 22.7 → 93.5 一致。修后曲线是**两档**：19–20 MB（30–120 s、330–420 s）和 32.5–33 MB（150–301 s、450–601 s），
之间来回跳（各档内 ±0.2 MB 平），跳的是解码器像素池 / IOSurface 那一级的 13 MB（≈ 4 张 1080p NV12），修前曲线上同样叠着这 13 MB 的起伏
（301 s 60.2 → 330 s 49.4）。所以 20 个点的直线拟合 0.095 MB / 圈是被"首点在低档、尾点在高档"拉出来的，**不是按圈涨**：每档的最小值前后一样（19.7 / 18.1、32.5 / 32.7），
按问题单 / soak 的口径（每分钟取最小值再拟合）是平的；20 分钟、每 10 s 一点的加长版见 (d)。

**(c) `heap <pid>`（不用 sudo，直接数活着的对象；会把进程暂停一下，别在计时用的那次跑里做）**

| | AVAssetReader | AVAssetReaderInternal | NSKVONotifying_AVAssetReaderTrackOutput | AVAssetReaderTrackOutputInternal | acv2::AudioConverterV2 | VTDecompressionSession |
|---|---|---|---|---|---|---|
| 修前，60 s / 11 圈 | **12** | 12 | **24** | 24 | 14 | 1 |
| 修后，80 s / 15 圈 | **1** | 1 | **2** | 2 | 3 | 1 |

修前每圈留一个 reader + 两个 track output + 一个 AudioConverter（就是那 0.5 MB）；修后只有当前这一套。这也说明 (a) 里 Apple 队列上那 7 千条 "MISSING POOLS"
没有攒住 track output（否则修后也该是 30 个）。VTDecompressionSession 一直只有 1 个——视频那 0.07–0.1 MB / 圈是 track output + 格式描述那一级，不是解码会话。

**(d) 加长：`fileprobe f.json 1200 --consume --interval 10`（240 圈，每 10 s 一点）**

120 个点、239 圈（两次 `heap` 暂停造成的 `lateWakes` 17 838 / 跳块 37 / 环 overruns 21 504 与 footprint 无关，见 §5 第 2 条）：

| 10 s / 1 圈 | 60 s / 11 圈 | 360 s / 71 圈 | 600 s / 119 圈 | 900 s / 179 圈 | 1200 s / 239 圈 | 全程最小 / 最大 | stop() 后 |
|---|---|---|---|---|---|---|---|
| 21.1 | 19.3 | 18.5 | 21.2 | 20.0 | **20.0** | 15.0 / 39.5 | 14.0 |

每分钟最小值（丢第 0 分钟，20 点）：18.5 17.4 33.0 32.9 18.4 17.3 33.3 33.2 21.3 18.7 17.4 33.2 33.2 20.0 18.7 15.0 33.2 33.2 19.9 20.0 →
**拟合 −0.3 MB/h**（120 点原始直线拟合 0.010 MB / 圈 = 6.9 MB/h，同样被两档起伏左右）。**平的**——239 圈修前会是 +130 MB。

**(e) 整包 `swift test --package-path Packages/SwitcherInputs`**：SwitcherInputsTests 56 条（6 跳）、NDITests 25 条（2 跳）、DeckLinkTests 25 条（3 跳），**0 失败**，共 197 s。跳过的全是原有的 BLOCKED 项：DeckLink 三条（硬件）、NDI 两条（外部源 / 无 SDK 路径）、摄像头三条（TCC 权限 notDetermined）、音频设备两条（可拔声卡 / 撤销麦克风权限）。FileInputTests 12 条全过（含新用例 12.0 s）。临时探针类 `ZZRateProbeTests`（§3.4）用 `--skip` 排除后跑的，跑完已删。

**(f) `make lint BRANCH=w2-inputs-3`**：禁词 / 版本号 / Package.swift 约束 / 依赖方向 / 归属（5 个改动文件都在允许范围）/ RT 符号 全绿。

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 测试 ID | 数值 | 阈值 | 通过 |
|---|---|---|---|
| `testS2_fileLoop_noAutoreleaseLeakPerLoop`（新，S2 单元级） | 修前 **0.465 MB / 圈**（20.2 → 43.3 MB，第 10–60 圈）；修后 **0.017 MB / 圈**（15.9 → 17.0 MB） | < 0.1 MB / 圈 | 修前 ❌ → 修后 ✅ |
| S2 复现件 fileprobe 600 s / 120 圈（问题单 §3 的验证命令） | 修前 21.7 → 87.4 MB（0.547 MB / 圈）；修后 19.7 → 32.7 MB，各档最小值前后持平（19.7 / 18.1、32.5 / 32.7） | "应平"（测试标准 §4 S2 ≤ 10 MB/h 要在 `make soak` 里判，本会话不跑） | 修前 ❌ → 修后 ✅（20 分钟 / 239 圈加长版：每分钟最小值拟合 −0.3 MB/h，尾点 20.0 MB = 首点，§1.4 (d)） |
| `OBJC_DEBUG_MISSING_POOLS` 60 s 计数 | 修前 13 433（我们线程 1011 / 30 s）；修后 7 383（我们线程 **0**，全在 Apple 队列 + fileprobe 主线程） | 问题单写"应为 0" | 我们线程 ✅；总数不为 0 的原因见 §1.4 (a)，不是泄漏（§1.4 (c)） |
| `heap` 活 reader 数 | 修前 12 / 11 圈；修后 1 / 15 圈 | 应为 1（当前那个） | ✅ |
| 原有 FileInputTests 10 条 + 整包 | FileInputTests 12 / 12 过（原有 11 条 + 新 1 条）；整包 106 条，11 跳（全是原有 BLOCKED-硬件 / 权限项），0 失败 | 0 失败 | ✅ |
| S2 8 小时（L4） | 没跑（用户终端 `make soak`） | ≤ 10 MB/h | BLOCKED-流程（用户触发） |
| ProRes 循环点空拍 / 晚醒（问题单 §2，非必做） | 修后复测 100 s：3 圈 `ticksStarved` 7、`lateWakes` 454 926、footprint 85–90 MB 平 | 0 / — | ❌ 未修（§3.1） |

---

## 3. 没做的和原因

### 3.1 ProRes 422 HQ 循环点空拍与推帧线程晚醒（问题单 §2）——没修，留给 W2-A 下一轮

修完泄漏后用 fileprobe 跑 e4-source.mov（ProRes 422 HQ 30 s，`loop`）100 s：圈 1 之后 `ticksStarved` 2、圈 2 之后 5、圈 3 之后 7；`lateWakes` 每过一个循环点
跳 13–19 万（137 081 → 326 188 → 454 926）；footprint 84.8 / 86.0 / 56.9 / 85.8 / 90.3 MB（同样的两档起伏，没有按圈涨）。**与泄漏无关、修后原样**。读代码看到的机制，
留给下一个会话：

1. **空拍**：`decodeLoop` 要 `videoDone && audioDone` 才重开 reader；音频 FIFO 领先 0.5 s、视频队列只领先 3 帧（50 ms），所以视频到尾时音频早就到尾，
   重开就在视频到尾的那一刻——"建 reader + startReading + 解出新一圈第 0 帧"要在 50 ms 内完成，ProRes HQ 1080p60（430 Mb/s）做不到，H.264 40 Mb/s 做得到
   （600 s 两次跑 `ticksStarved` 都是 0）。修法方向：视频离尾还剩 N 帧时就把下一圈的 reader 开好、把第 0 帧解进队列（两个 reader 短暂并存，多一套 IOSurface）。
2. **晚醒 / 自旋**：循环点上 FIFO 断供时，`paceLoop` 的音频块 `due` 已过、`copy` 失败、又没到 `due + 4 块` 的跳过线，于是 `break` 出音频循环 → 下一轮
   `audioWake = due`（在过去）→ `sleep(until:)` 立刻返回 → `woke - wake > 1 ms` 记一次晚醒 → 如此自旋直到跳过线（每块 21 ms）。每个循环点自旋几十 ms，
   `lateWakes` 就多十几万；这也是 8 小时里"晚醒每秒 397 次、CPU 逐小时 +0.37 pt"的候选来源之一（自旋期间这条 time-constraint 线程满占一个核）。
   修法方向：`audioWake` 取 `max(due, min(due + 4 块, now + 1 块))`——过期的块按 5 ms 轮询而不是自旋；但这改推帧时序，要连着 1 一起做、用 W2-A 的音频对齐用例守住。

### 3.2 8 小时 `make soak` —— 用户在自己的终端触发（prompt 明说）。修后 `make soak-1h` 的 S2 参考值应 ≤ 10 MB/h（现在的 1 小时值 108.9、8 小时 60.8）。

### 3.3 fileprobe 主线程的 110 条 "MISSING POOLS" —— `scripts/soak/fileprobe/Sources/fileprobe/main.swift` 是 W4-A 的目录；它顶层代码在主线程没有池，
`JSONSerialization` 那一下会打出来。一次性、不随圈涨，只是让 `grep -c` 的总数不可能为 0。W4-A 若愿意，`main.swift` 的解析那段包一个 `autoreleasepool {}` 就没了。

### 3.4 速率 × 片段帧率 / 节目帧率 > 3 时推帧线程饿死（本会话写测试时撞到的，没修）

临时探针（每配置 8 s，320×240 H.264 + AAC，60 fps 节目，跑完已删）：

| 片段 | 速率 | 音频环 | 每拍前进（片段帧） | 8 s 圈数 | ticksStarved | lateWakes | 音频块写 / 跳 |
|---|---|---|---|---|---|---|---|
| 30 fps × 30 帧 | 8 | 有 | 4 | **3** | **433** | **2 221 655** | 59 / **1413** |
| 60 fps × 60 帧 | 4 | 有 | 4 | **2** | **416** | **2 210 452** | 84 / **1399** |
| 30 fps × 30 帧 | 8 | 无 | 4 | 47 | 1 | 0 | — |
| 30 fps × 30 帧 | 6 | 有 | 3 | 47 | 3 | 503 439 | 1268 / 218 |
| 60 fps × 60 帧 | 3 | 有 | 3 | 23 | 2 | 229 555 | 1382 / 107 |
| 30 fps × 30 帧 | 4 | 有 | 2 | 31 | 0 | 0 | 1489 / 0 |

4 帧 / 拍 + 音频 = 饿死，3 帧 / 拍 勉强（跳块 + 自旋），≤ 2 帧 / 拍 正常。机制：推帧线程每拍最多 pop 约 `predecodeDepth`（3）帧，时间线跑得比解码快时
下一圈的音频被本圈的视频尾巴挡住（重开 reader 要 `videoDone && audioDone`），推帧线程按时间线要不到样本就跳块、**跳块不 trim**，FIFO 满、解码线程卡在 `append`、
要的样本序号一路跑远——两边互等。不在本会话范围（不是自动释放池的事），已写成问题单 `reports/issues/W2A3-w2-inputs-file-high-rate-audio-starves.md`
（机制、修法建议、复现），归 W2-A。

### 3.5 没给 `InputThread` 改 body 签名（"按迭代排水的入口"）—— 理由在 §1.2；如果检查点或 W2-A 更想要统一入口，改法是 `init(body:)` 之外加一个
`init(step:)`（每轮 `autoreleasepool { step(self) }`，返回 false 退出），FileInput 两条循环再搬状态；本会话不做。

---

## 4. 对契约的疑问

没有。没动 SwitcherContracts、JSON 字段、测试图案；`InputThread` 是 SwitcherInputs 的内部类型（public，但只有本包和 NDI / DeckLink target 用），API 没变。

---

## 5. 下一个会话需要知道的坑

1. **`OBJC_DEBUG_MISSING_POOLS=YES` 的总数永远不会是 0**：Apple 自己的 `com.apple.coremedia.assetreader` 队列每个样本打一条（macOS 27.0），fileprobe 主线程还有 110 条。
   要看"是不是我们线程"，用 lldb 按线程归因（不停下，只计数）；脚本 20 行，贴在这里以免下次再写：

   ```python
   # nopool_attr.py —— lldb: command script import nopool_attr.py; breakpoint set -n objc_autoreleaseNoPool; breakpoint command add -F nopool_attr.cb 1
   import lldb, collections, os
   hist = collections.Counter()
   def cb(frame, bp_loc, internal_dict):
       t = frame.GetThread()
       hist["thread=%s queue=%s" % (t.GetName() or "-", t.GetQueueName() or "-")] += 1
       return False                                   # 不停
   def dump(debugger, command, result, internal_dict):
       for k, v in hist.most_common(): print("%7d  %s" % (v, k))
   def __lldb_init_module(debugger, internal_dict):
       debugger.HandleCommand("command script add -f nopool_attr.dump nopool_dump")
   ```
   跑法：`lldb --batch -o "settings set target.env-vars OBJC_DEBUG_MISSING_POOLS=YES" -o "command script import nopool_attr.py" -o "breakpoint set -n objc_autoreleaseNoPool" -o "breakpoint command add -F nopool_attr.cb 1" -o "process launch -- f.json 30 --consume" -o nopool_dump -- fileprobe`。
   断点让进程慢 3–4 倍（这次跑出 `ticksStarved` 15、`lateWakes` 3512），只看归因、别看计时。
2. **`heap <pid>` 不用 sudo 就能数活着的 ObjC / CF / C++ 对象**（同一用户、SwiftPM 编的普通二进制），是证明"每圈留一个 reader"最直接的办法——但它会把目标进程
   暂停约 1 s，推帧线程醒来时一堆块过期：这次 20 分钟那趟跑里 `lateWakes` 17 823、`audioChunksSkipped` 37、环 overruns 21 504 全是两次 `heap` 造成的。
   要计时就别 heap 同一个进程。
3. **footprint 有 13 MB 的两档起伏**（19–20 ↔ 32–33 MB，解码器像素池那一级，1080p H.264 循环时几分钟换一次档），单点比较会被骗；按问题单口径
   取每分钟最小值再拟合，或者像新用例那样按圈采样后直线拟合并且只信 ≥ 40 个点。
4. **`autoreleasepool { }` 包循环体的写法**：闭包里不能 `continue` / `break`，`continue` → `return`，`break` → 让闭包返回 Bool、循环外 `if !keepGoing { break }`；
   循环外的局部 `var` 在非逃逸闭包里可以直接改，不用搬进对象。`git diff -w` 看实际改动。
5. **速率上限**：见 §3.4 / 问题单。写高速率的文件用例前先算 `rate × 片段 fps / 节目 fps` 是否 ≤ 3（`predecodeDepth`）。
6. **本会话工具的坑**：桌面端的 Write / Edit 工具拒绝写别的 worktree（hook），只能用 Bash heredoc 写文件；zsh 里 `timeout` 命令不存在（用 lldb 的 `process launch` + 程序自己的秒数参数）；
   `swift test --filter` 要写 `Module.Class/method`；`--skip ZZ…` 可以把临时探针类跳掉。
7. **ProRes 循环点两件事（§3.1）没修**，机制与修法方向写在那一节；8 小时重跑后若 `lateWakes` 仍每秒几百次、CPU 仍逐小时涨，先怀疑那个自旋。
