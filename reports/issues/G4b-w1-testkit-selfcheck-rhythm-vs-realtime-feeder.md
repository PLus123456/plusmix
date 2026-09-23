# frameprobe 自证解码的"节奏"一票（残差 ≤ 3 ms）把实时喂送的图案帧判成解不出：推流测试 4 条红

归属会话 / 分支：W1-A（`Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/SelfCheck.swift`，W1-A3 / prompt 62 加的自证）；喂送器在 W2-D 的 `Packages/SwitcherOutputs/Sources/SwitcherOutputs/Feeding/PatternFeeder.swift`
发现于：G4 第二批续做合入（2026-09-23）跑全量 `make test`：`StreamingTests.MediaMTXTests` 的 `testRTMP_endToEnd_10s_framesContinuousAndAVAligned` / `testSRT_endToEnd_10s_framesContinuous` / `testE7_threeStreams_blockSecondFor30s_othersDropZero` / `testE8_reconnectTenTimes_within15s_framesContinuousAfterReconnect` 都在"帧号连续 / 解不出 = 0"上红。
严重级：S2（测试口径，产品行为没问题；`make test` 在 SwitcherOutputs 这一包就停）

## 现象

RTMP 10 s 落盘 599 帧，frameprobe（W1-A3 之后、自证默认开）：**帧号读不出 37、输入 ID 读不出 37，自证判掉 37 条全是 `rhythm`**，残差 3.2–3.8 ms（阈值 3 ms）；
于是输入 3 的帧数 562、丢弃 36、缺口 31。同一个文件 `--no-self-check`：599 帧、不同帧号 599、重复 0、丢弃 0、倒退 0——传输是干净的。
第一次全量（2026-09-23 12:10）这几条是绿的：那时 `Tools/frameprobe/.build/release/frameprobe` 还是 W1-A3 之前编的二进制；gate4 g4b 重编之后才现形。

## 原因

自证的"节奏"判据（SelfCheck.swift：`(帧号, 时间戳)` 落在该输入自己的直线上、残差 ≤ `rhythmToleranceMs = 3.0`）是按引擎节拍的合成源（`SyntheticVideoInput`，时间戳 = 时间线上的拍点）定的。
PatternFeeder 烧进画面的时间戳是 `makeFrame(tick:tickTime:now:)` 的 `now`（实际生成时刻，默认 `HostClock.now()`；`TestPattern.Content(frameNumber: tick, hostTime: now, …)`），不是拍点 `tickTime`；实时喂送时线程唤醒有毫秒级抖动，(帧号, 时间戳) 就偏离直线几毫秒——这正是 W1-A3 用来抓“旧 ID + 新帧号”合成帧的那一票。
这一票的本意是抓 Wipe 时"旧 ID + 新帧号"的合成帧；单路、无转场的推流测试用不上它。

## 检查点的处理（本次合入）

`Packages/SwitcherOutputs/Tests/StreamingTests/MediaMTXSupport.swift` 的 `Frameprobe.stats` 加 `--no-self-check`（传输口径：只看帧号连续、不重不丢），注释写明原因。
不是放宽阈值：同一文件老口径 0 丢 0 重，自证只是选错了口径。

## 建议（W1-A 定）

1. 节奏判据的阈值或改成"按该路残差分布自适应"（SelfCheck 里已有 `max(rhythmToleranceMs, 4 × 中位数 + 2)` 那一步，但最终仍用固定 3 ms 判）；
2. 或者 PatternFeeder 烧拍点时间戳（W2-D 的文件），让实时喂送的帧也满足节奏；
3. 或者 frameprobe 给"单路传输"一个明确的口径开关（`--transport`），gate 与推流测试都用它。
G5 的 E7–E9 重跑用的是 headless（合成源按拍点烧），不受影响；但 gate3-net.sh 如果直接 frameprobe MediaMTX 的录像，同样要带 `--no-self-check` 或等 W1-A 修。
