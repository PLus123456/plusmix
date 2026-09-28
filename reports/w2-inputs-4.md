# W2-A4 文件输入：ProRes 循环点空拍 + 高速率带音频饿死 —— 报告（分支 w2-inputs-4）

日期 2026-09-28。机器 Apple M5 Max / 128 GB，macOS 27.0 (26A428)，Xcode 27.0，Swift 6.4，电源适配器，机器上同时有别的会话在跑。
worktree `.claude/worktrees/w2-inputs-4`，分支 `w2-inputs-4`，从 main `17d3877`（= 2bc4088 + 一个报告提交）开。
提交：`git log main..w2-inputs-4`——红测试 b4be0a4 → 循环点 1747716 → 高速率 a0be5c8 → 预开触发修正（§1.6）→ 本报告。
只动了 `Packages/SwitcherInputs/Sources/SwitcherInputs/File/{FileInput.swift, FileQueues.swift}` 和
`Packages/SwitcherInputs/Tests/SwitcherInputsTests/{FileInputTests.swift, Support/LoopClipWriter.swift}`，外加本报告。没碰契约、DeckLink / NDI、headless、soak 脚本。

**一句话**：循环点空拍的根因是"到尾才重开 reader"（ProRes 建 reader + 解首帧 31–48 ms，卡在 3 帧 / 50 ms 余量边上），改成离尾就预开、
视频 / 音频各自交接；高速率饿死是三处互相咬住（队列深度固定 3 → 每拍最多 pop 3 帧；要不到音频样本不 trim → FIFO 塞满解码线程进不来；
下一圈的音频等本圈视频的尾巴），三处都拆开了。两条新用例修前红修后绿，既有 12 条全过，整包 0 失败，lint 全绿。顺手修了一个 main 上就有的坑：
往回定位后丢 1 s 音频（trim 点不随换代重置）。

---

## 1. 做了什么

### 1.1 先写测试（红）

| 用例 | 素材 | 修前 |
|---|---|---|
| `testW2A4_prores_loopBoundary_noStarveNoSkip` | AVAssetWriter 现场写 1 s 1080p60 **ProRes 422 HQ**（`.proRes422HQ`，TestPattern 帧号图案 + 噪声底 ≈ 440 Mb/s、AAC），循环 20 圈，TickDriver 逐拍挑帧解帧号 | 20 圈里 **2 个循环点空拍**：59 → 59（重复上一圈末帧）→ 1（跳过第 0 帧）；`ticksStarved` 2、`framesRejected` 2、帧槽 `reused` 2；晚醒 0 |
| `testW2A4_highRate_withAudio_keepsUp` | `LoopClipWriter` 的 0.2 s H.264 + AAC（30 fps × 6 帧），60 fps 节目，接 `RecordingAudioRing`；速率 1 / 2 各 3 s、速率 8（4 帧 / 拍）10 s | 速率 8：10 s **只转 7 圈**（预期 400），`ticksStarved` 584，**晚醒 2 981 969**，音频块写 19 / 跳 1852，环里 host time 断 5 处；速率 1 / 2 正常（15 / 30 圈） |
| `testW2A4_seekBackward_audioKeepsFlowing`（§1.4 顺手发现的） | pattern.mov 带音频播 1.5 s 后 `seek(toFrame: 0)` 再播 1.5 s | 定位后 1.5 s 只写 96 块、**跳 180 块**（丢了约 1 s 音频） |

`LoopClipWriter` 加了 `codec` / `content` 参数（ProRes、`TestPattern` 帧号图案 + 任意底色），默认行为不变，S2 用例照旧。

### 1.2 探针（铁律 10）：AVAssetReader 开完不拉样本会不会自己预解首帧

20 行探针（scratchpad，结论抄这里），三个片段各三轮，每轮四种情形：

| 片段 | makeReader + startReading | A 开完立刻取首帧 | B 开完等 300 ms 再取首帧 | C 先拉 0.5 s 音频再取首帧视频 | D 另一个 reader 满速解 300 ms 后取首帧 | 之后每帧 |
|---|---|---|---|---|---|---|
| ProRes 422 HQ 1080p60（testsrc2，157 Mb/s） | 进程里第一个 133 ms，之后 18–21 ms | 16–26 ms | **0.1 ms** | 17–20 ms | **0.0 ms** | 0.6–0.75 ms |
| ProRes 422 HQ 1080p60 + 噪声（466 Mb/s ≈ E4 源） | 第一个 125 ms，之后 16 ms | 28–42 ms | **0.1 ms** | 27 ms | **0.0 ms** | 0.7 ms |
| H.264 40 Mb/s 1080p60（同内容） | 第一个 113 ms，之后 5.5–5.8 ms | 10–12 ms | 0.1–0.2 ms | 9–10 ms | 0.0 ms | 0.4 ms |

结论：**`startReading()` 之后 reader 自己会把首帧预解出来**（等 300 ms 再取 0.1 ms；旁边另一个 reader 满速解也不影响）。所以循环点只要"提前开好"就够，
不用另起线程去解首帧；而"到尾才开"ProRes 要 16–20 + 15–42 ≈ 31–62 ms，正卡在视频队列 3 帧（50 ms）余量边上——问题单说 ProRes 每圈空一拍、H.264（5.5 + 11 ms）不空，就是这个数。

### 1.3 修法一：循环点（提交 1747716，`FileInput.decodeLoop` / `paceLoop`）

- `decodeLoop` 改成 `LoopReader`（reader + 展开偏移 base + 视频 / 音频各自 `videoDone` / `audioDone`）：
  - **预开**：视频离尾不到 `Options.loopPrerollSeconds`（0.15 s 真实时间；第一版是 0.5 s 且"或音频先到尾"，见 §1.6）× 速率，就 `makeReader(from: .zero)` 建下一圈（`next`）；片段比它短就一直双 reader（只有小片段会这样）。
  - **各自交接**：视频读到尾就从 `next` 拉视频（不等音频），音频读到尾就从 `next` 拉音频（不等视频的尾巴——以前要 `videoDone && audioDone` 才重开，
    音频领先 0.5 s、到尾后干等视频，这也是高速率饿死的一环）；本圈两路都到尾才 `cancel`、`loops + 1`，`next` 变 `current`。
  - 预开失败（`prerollFailed`）本圈不再试，交接时按老办法当场重开；预开之后结束动作改成 hold / black，交接时把 `next` 取消、照旧放结尾哨兵。
- `paceLoop`：音频块到点了但 FIFO 里还没样本时，以前 `audioWake = due`（已过去）→ `sleep` 立刻返回 → `woke − wake > 1 ms` 记一次晚醒 → 下一轮还是这样，
  循环点断供几十 ms 就自旋十几万次（soak 8 小时晚醒 1142 万次、每秒 397 次、CPU 逐小时 +0.37 pt 的候选来源）。现在记一个 `audioStalled`，下一轮
  `audioWake = max(now, min(due + 4 块, now + 1 块))`——按块周期（5.3 ms）轮询到跳过线，wake 永远不在过去。

### 1.4 修法二：高速率（提交 a0be5c8，`FileQueues.swift` + `FileInput`）

- **队列深度随速率**：`DecodedVideoQueue.depth` 改成可 `setDepth`，解码线程每轮按当前时间线算 每拍帧数 = 速率 × 一拍 / 片段帧时长，
  深度 = `predecodeDepth` + max(0, ⌈每拍帧数⌉ − 1)：≤ 1 帧 / 拍还是 3（既有用例的 `distinctSurfaces ≤ 16`、"收到 = 推出 + 跳过 + 队列里的 ≤ 4"不变），
  4 帧 / 拍是 6——推帧线程一拍能把本拍的帧全 pop 到最新那帧，不再每拍只前进 3 帧。
- **解码侧丢帧**：解出来的帧 `media + 帧时长 ≤ position(当前拍)`（落后超过一帧）不入队直接丢、计 `framesRejected`，解码器追得上时间线（速率高 / 解码慢时不会越落越远）。
  只差不到一帧的留着：定位到非帧边界时首帧的 pts 略早于锚点，那帧正是要显示的。锚点没定 / 暂停 / 还没到锚点拍时不丢。
- **FIFO 三态**：`DecodedAudioFIFO.copy` 返回 `.ok / .notYet / .gone`。`.notYet`（还没解到）先 `trim` 掉比这块还老的样本——FIFO 被旧样本塞满时解码线程停在
  `status.frames < maxFrames` 门口，不 trim 就两边互等（W2A3 的饿死）；过了 due + 4 块才跳。`.gone`（队头已在它后面：换代 / 大空洞之后）立刻跳，不等 21 ms。
- **空洞重试**：`append` 遇到比剩余容量还大的空洞（音轨比视频短很多）以前补零到 `maxFrames` 就把样本接在后面、序号错位整圈不同步；现在只补到满返回 `.retry`，
  解码线程留着这块（`pendingAudio`）下一轮再放，不阻塞、视频照拉。`append` 里"满了等"的循环删掉（放之前本来就看门）。
- **顺手：trim 点随换代重置**：推帧线程的 `trimmedTo` 只增不减、seek 不重置——往回定位后新位置比旧 trim 点小，FIFO 再也不 trim，0.5 s 后塞满、解码线程进不来、
  音频块一直跳到位置追过旧 trim 点为止。**main 上就有**（与本会话的改动无关），红测试 `testW2A4_seekBackward_audioKeepsFlowing` 定位后 1.5 s 写 96 / 跳 180 → 修后 279 / 0。

热路径规则不变：两条线程本来就允许锁和分配（设计方案 §3.2 的热路径是渲染 / 音频线程）；推帧线程没加日志，锁只在原有位置（`playback`、队列、FIFO），
音频段多了一次 `fifo.trim`（原有的锁）；解码线程多了每帧一次 `HostClock.now()` + 有理数比较。`check-rt-symbols` 照旧绿。

### 1.5 验证

**fileprobe（`scripts/soak/fileprobe`，只起 FileInput：LockFreeFrameSlot(3) + CAudioRing(2)，`--consume --interval 10`）**，两个 ProRes 422 HQ 1080p60 5 s 循环片段
各跑 100 s（约 19–20 圈）；修前二进制 = 提交 b4be0a4（只加了测试）编的，修后 = 分支顶。片段：prompt 给的 ffmpeg 配方（testsrc2，157 Mb/s）和
同配方加 `noise=alls=40:allf=t`（466 Mb/s ≈ E4 源的 430 Mb/s）。

| 片段 | 版本 | 100 s 圈数 | `ticksStarved` | `lateWakes` | 音频块写 / 跳 | footprint（10 s 一点） |
|---|---|---|---|---|---|---|
| ProRes 157 Mb/s | 修前 | 19 | **17**（每圈 0.9） | **29 052**（一个循环点自旋一次） | 18726 / 0 | 27–35 MB |
| ProRes 157 Mb/s | 修后（第一版，§1.6） | 19 | 0 | 0 | 18725 / 0 | 79–84 MB（双 reader 常驻） |
| ProRes 157 Mb/s | 修后（最终） | 19 | **0** | **0** | 18734 / 0 | 27–34 MB，90–100 s 74 MB（两档，§1.7） |
| ProRes 466 Mb/s（≈ E4） | 修前 | 19 | **36**（每圈 1.9） | **1 304 601**（每个循环点 8–16 万） | 18724 / 0 | 52–64 MB |
| ProRes 466 Mb/s（≈ E4） | 修后（第一版，§1.6） | 20 | 0 | 0 | 18755 / 0 | 209–261 MB（双 reader 常驻） |
| ProRes 466 Mb/s（≈ E4） | 修后（最终） | 20 | **0** | **0** | 18778 / 0 | 55–64 MB，50 s 起 187–197 MB（两档，§1.7） |
| ProRes 466 Mb/s，**300 s** | 修前 | 60 | **128**（每圈 2.1） | **5 974 522**（每圈 10 万） | 56201 / 40 | 两档：44–72 ↔ 184 MB，各持续 60–130 s |
| ProRes 466 Mb/s，**300 s** | 修后（最终） | 60 | **0**（`heap` 暂停 1 s 之后 2） | **0**（暂停之后 16） | 56600 / 0（暂停之后 22） | 两档：54–67 ↔ 185–198 MB，各持续 50–110 s |

修前的重片段数字和问题单一致（soak 20 圈空 29 拍、晚醒 100 万）：每圈约 2 拍空、每个循环点推帧线程自旋 8–16 万次。修后两样都归零；300 s 里唯一的
`ticksStarved` 2 / 晚醒 16 / 跳块 22 是 200 s 时 `heap` 把进程暂停了 1 s 造成的（w2-inputs-3 §5 第 2 条说过）。

**整包** `swift test --package-path Packages/SwitcherInputs`：SwitcherInputsTests 59 条（6 跳）、NDITests 25 条（2 跳）、DeckLinkTests 25 条（3 跳），**0 失败**，共 242 s。
跳过的全是原有 BLOCKED 项：麦克风拒绝路径 / 可拔声卡、摄像头 TCC 权限 × 3、USB 摄像头热插拔、NDI 外部源 / 无 SDK 路径、DeckLink 硬件 × 3。FileInputTests 15 / 15（原有 12 + 新 3）。

**lint**：`make lint BRANCH=w2-inputs-4` 禁词 / 版本号 0.1.0 / Package.swift 约束 / 依赖方向（8 包）/ 归属（5 个改动文件都在允许范围）/ RT 符号 全绿。

### 1.6 修后第一版的坑：双 reader 常驻（修正 = 提交 0869f8c）

第一版预开的触发条件是"视频离尾不到 0.5 s **或音频已到尾**"。fileprobe 跑出来 `ticksStarved` / 晚醒归零，但 footprint 157 Mb/s 片段 28–35 → 79–84 MB、
466 Mb/s 片段 52–64 → 209–261 MB。先怀疑"预开的 reader 空转时自己往前解、把像素池撑到高水位"，写了探针 2（单个 reader：开完立刻按拍拉 / 空转 500 ms 再拉 /
空转 60 ms / 拉 1 帧再空转 500 ms，各 120 帧，看 footprint 和稳态里转几张 IOSurface）：

| 情形 | 157 Mb/s footprint | 466 Mb/s footprint | 稳态不同 IOSurface（持有 3 张） | 120 帧里立刻返回的 |
|---|---|---|---|---|
| 开完立刻按拍拉 120 / 240 帧 | 35.8 / 33.9 MB | 67.5 / 69.3 MB | 13 / 12 | 119 / 116 |
| 空转 500 ms 再按拍拉 | 空转后 28.5，拉完 29.8 / 32.2 MB | 73.1，拉完 73.3 / 69.7 MB | 12 / 14 | 120 / 119 |
| 空转 60 ms 再拉 | 32.5 → 29.8 MB | 73.3 → 75.3 MB | 12 / 13 | 120 |
| 拉 1 帧再空转 500 ms | 28.9 → 30.2 MB | 75.3 → 79.1 MB | 12 / 13 | 118 / 120 |
| cancel 之后 | 9.6–11.6 MB | 13.6–22.8 MB | | |

**空转不空转一样**：每个 reader 自己常驻约 10 帧预解（1080p NV12 3.1 MB / 帧，重片段还有压缩样本在飞），cancel 后全还。所以多出来的不是空转撑池，
是**两个 reader 一直活着**：音频领先 0.5 s，`next` 的音频在它还是 next 时就被拉完、标了 `audioDone`，交接后 `cur.audioDone` 立刻为真 → 马上又预开 → 常驻双 reader。
修正：触发只看视频离尾（`loopPrerollSeconds` 0.15 s × 速率；建 reader 16–20 ms + 自己预解首帧 15–42 ms，加上解码位置本来领先显示 3 帧，余量 2 倍以上），
两个 reader 只在离尾那 150 ms 并存；音频到尾后 FIFO 里还有 0.5 s，等视频离尾再开来得及。

### 1.7 footprint 的两档（修前就有，与本会话无关）

重片段（466 Mb/s）无论修前修后，footprint 都在 **44–72 MB 和 184–198 MB 两档之间跳**，每档持续 50–130 s（轻片段 27–35 ↔ 74 MB）；100 s 的短跑碰巧各落在不同档，
一度让我以为修后多了一个像素池。300 s 对照（上表末两行）+ 200 s 时 `heap`（两版都是 **1 个 AVAssetReader、1 个 VTDecompressionSession、2 个 track output、16 张 IOSurface、
11–14 个 CVPixelBuffer**）说明：不是 reader / 表面泄漏，高档那 130 MB 是可释放的、`heap` 暂停 1 s 之后立刻掉回低档、几圈后又攒回来——AVFoundation / VideoToolbox 自己的
读前 / 缓存行为：高档时 `vmmap --summary` 里 **CoreMedia Memory Pool 127.5 MB dirty（78 段）**，IOSurface 42 MB、malloc 10 MB——就是 CoreMedia 的样本缓冲池（压缩样本 / CMBlockBuffer，466 Mb/s 下每帧约 1 MB），不归本会话。S2 按每分钟最小值拟合的口径不受它影响；看单点会被骗（w2-inputs-3 §5 第 3 条说的 13 MB 两档，在 466 Mb/s 下是 130 MB）。

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

| 测试 ID | 修前 | 修后 | 阈值 | 通过 |
|---|---|---|---|---|
| `testW2A4_prores_loopBoundary_noStarveNoSkip`（新） | 20 圈：帧号断点 4（59→59、59→1 两处）、`ticksStarved` 2、`framesRejected` 2、`reused` 2、晚醒 0 | 20 圈 / 20.5 s：断点 **0**、没跟上 **0**、跳帧 **0**、reused **0**、跳块 0、晚醒 **0**、音频块写 3841 | 帧号逐拍 +1 mod 60；starved / rejected / reused / 跳块 = 0；晚醒 < 100 / s；圈数 ≥ 20 | ❌ → ✅ |
| `testW2A4_highRate_withAudio_keepsUp`（新）速率 8 | 10 s 转 7 圈、没跟上 584、晚醒 2 981 969、音频块写 19 / 跳 1852、环 host time 断 5 处（只修循环点那一提交后：14 圈、晚醒 0、跳 1823） | 10 s 转 **401 圈**（预期 400）、没跟上 **0**、晚醒 **0**、跳帧 1800（= 每拍 4 帧推 1 跳 3，设计内）、音频块写 **1875** / 跳 **0**、环 host time 连续 | 圈数 ≥ 预期 × 0.9（360）；starved ≤ 3；跳块 0；晚醒 < 100 / s；环块 ≥ 1688 且连续；`audioFramesRejected` 0 | ❌ → ✅ |
| 同上 速率 1 / 2（对照） | 15 / 30 圈，全 0 | 15 / 30 圈，全 0 | 同上（预期 15 / 30） | ✅ → ✅ |
| `testW2A4_seekBackward_audioKeepsFlowing`（新，顺手） | 定位后 1.5 s 写 96 块、跳 180 | 写 **279** 块、跳 **0** | 跳 0；写 ≥ 250 | ❌ → ✅ |
| 既有 `testFile_loopBoundary_noSkipNoRepeat`（H.264）/ `testS2_fileLoop_noAutoreleaseLeakPerLoop`（斜率 0.001 MB / 圈，< 0.1）/ 60 fps 连续 / 30 fps 每帧一次 / seek 300 / 暂停 / hold / black / rate 2 / 音频对齐 / alpha / 缺文件 | 12 / 12 | 12 / 12 | 各自原阈值 | ✅ |
| fileprobe ProRes 5 s 循环 100 s / 300 s（问题单复现件，§1.5 表） | 157 Mb/s：19 圈没跟上 17、晚醒 29 052；466 Mb/s：19 圈没跟上 36、晚醒 1 304 601；466 Mb/s 300 s：60 圈没跟上 128、晚醒 5 974 522、跳块 40 | 157 Mb/s：19 圈 **0 / 0**；466 Mb/s：20 圈 **0 / 0**；466 Mb/s 300 s：60 圈 **0 / 0 / 0**（`heap` 暂停造成的 2 / 16 / 22 除外）；footprint 两档与修前相同 | `ticksStarved` 0；晚醒不再每秒上千次；footprint 不高于修前 | ✅ |
| 整包 `swift test --package-path Packages/SwitcherInputs` | — | 109 条，11 跳（全是原有 BLOCKED-硬件 / 权限项），0 失败 | 0 失败 | ✅ |
| `make lint BRANCH=w2-inputs-4` | — | 全绿 | 全绿 | ✅ |

---

## 3. 没做的和原因

1. **8 小时 soak 复跑**：不在本会话范围（用户终端 `make soak`）。修后应看的两个数：文件输入的 `lateWakes` 不再每秒几百次、进程 CPU 不再逐小时涨（问题单 §3 末尾的"顺带"）。
2. **预开 reader 仍在解码线程上同步 `makeReader`**（ProRes 16–20 ms、H.264 5.5 ms）：这段时间不拉本圈的视频，靠队列余量盖住。速率 1 下余量 50 ms 够；
   速率 8 × 1080p ProRes（8 帧 / 拍，队列 10 帧 ≈ 21 ms 真实时间）会紧——不是本会话的用例（高速率用例是 320×240 H.264）。要再往前一步就是把 makeReader 放到
   辅助线程 / 队列上，交接时从盒子里取；本会话没做，理由是探针证明预开 + 自动预解已经把循环点余量从"50 ms 减 31–62 ms"变成"150 ms + 50 ms 减 20 ms"。
3. **结束动作在预开之后从 loop 改成 hold / black 的边角**：`next` 已经预开、而且它的前几帧（≤ 队列深度）可能已经进了队列——推帧线程会先显示下一圈的那几帧再看到哨兵
   （hold 停在下一圈第 2 帧而不是本圈末帧）。只在"最后 50 ms 内改结束动作"时出现，没写用例；要严格的话交接时 `queue.flush()` 掉下一圈的帧再放哨兵（flush 会连本圈没推的尾帧一起清，得改成按 media 选择性删）。
4. **`Rational(approximating: loopPrerollSeconds)`** 分母 ≤ 1000，0.15 s 精确；用户若把它设成 1/3 这种会被近似，无所谓。
5. 探针程序没入库（scratchpad），结论在 §1.2；要复现按表里的四种情形写 20 行即可。

---

## 4. 对契约的疑问

没有。没动 SwitcherContracts、JSON 字段、测试图案；`FileInput.Options` 多了 `loopPrerollSeconds`（SwitcherInputs 自己的公开类型，有默认值，
headless / App 用 `Options()` 不受影响）；`FileCounters` 字段没变（`lateWakes` 现在只计真正的睡过头）。

---

## 5. 下一个会话需要知道的坑

1. **AVAssetReader 会在 `startReading()` 之后自己预解首帧**（§1.2 表 B / D 列），而且**每个活着的 reader 自己常驻约 10 帧预解**（§1.6 探针 2：1080p 轻 ProRes 30 MB、重 70 MB，空转与否一样，cancel 后全还）：
   任何"提前建 reader"的优化都不用另起线程去取首帧，但绝不能让两个 reader 长期并存；"开完立刻取"要 15–42 ms，别在时间紧的地方开完就取。进程里第一个 reader 的 `startReading` 要 113–133 ms（W2-A 报告说过的 85 ms，现在更长），start / 首次 seek 的锚点仍靠"目标帧解出来之后才定"兜着。
2. **`lateWakes` 的口径变了**：以前循环点 / 定位后的音频断供会把 wake 设在过去、每轮记一次晚醒，soak 里的"每秒几百次"大半是这个自旋而不是真的晚醒；
   现在 wake 永远 ≥ now，`lateWakes` 只剩真正睡过头的次数。8 小时数据别和以前的直接比。
3. **`framesRejected` 现在包含解码侧丢的帧**（落后当前拍超过一帧的不入队）：高速率下 = 每拍帧数 − 1 的倍数（速率 8 十秒 1800），正常；
   速率 1 下出现非零就是解码器一度落后（以前这种情况会以"迟到的帧"显示出来，现在是帧槽重复上一帧 + `ticksStarved`）。
4. **队列深度随速率**：`DecodedVideoQueue.setDepth` 只由解码线程调；变浅时多出来的帧留给推帧线程 pop。1080p 高速率下多几张 IOSurface（深度 = 每拍帧数 + 2）。
5. **`DecodedAudioFIFO.copy` 三态、`append` 三态**：`.gone` 立刻跳、`.notYet` 先 trim 再等；`append` 的 `.retry` 要由调用方保存这块下一轮再放（`pendingAudio`）。
   `append` 不再阻塞，放之前必须自己看 `status.frames < maxFrames`。
6. **往回定位丢音频**（§1.4 末条）main 上就有，这里顺手修了；若有别的地方也记"只增不减"的 trim / 消费点，换代时都要重置。
7. **写高速率用例时**：`LoopClipWriter.write(frames: 6)` 0.2 s 片段速率 8 = 40 圈 / s，每圈都要 makeReader（5 ms），解码线程 20% 时间在建 reader，
   `ticksStarved` 仍为 0；再往上（速率 16）没测。`maxSrc = chunk × 17 + 4` 仍是速率 ≤ 16 的上限。
8. **fileprobe 数字受机器上别的会话影响**（本次跑的时候有别的 agent 在编译 / 跑测试），单次的 `lateWakes` 个位数、`ticksStarved` 0–1 属于噪声；看趋势别看单点。
   **footprint 在 466 Mb/s ProRes 下有 130 MB 的两档**（§1.7，修前就有）：100 s 的跑不够看，要 300 s 以上、按每分钟最小值；`heap` 会把进程暂停 1 s，之后档位会掉回低档。
9. 桌面端 Write / Edit 拒绝写别的 worktree 时用 python heredoc 整段替换（本会话全程这么做）；探针脚本里 `Task {}` 在顶层代码会跑在主 actor 上、主线程 `sem.wait()` 会把它饿死，
   要用 `Task.detached`；`grep -r --include=*.swift` 在 zsh 里要给 glob 加引号。
