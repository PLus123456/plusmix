# W2-A6 输入：DeckLink 声道映射饱和加法（N05）、文件输入暂停没落实就恢复（N09）—— 报告（分支 w2-inputs-6，prompt 133）

日期 2026-10-31。机器 Apple M5 Max（MacBook Pro），macOS 27.0.1（26A434），Xcode 27.1（27A9275），Swift 6.4，接电源；同机有 129–132 并行会话（跑整包时负载见 §2 末）。
工作树分支 `claude/w2-inputs-6-cf30c6` = 本地别名 `w2-inputs-6`（每次提交后 `git branch -f w2-inputs-6 HEAD`），从 G11 快进后的 main（bf149e2）开。不 push、不 merge，交 G12（134）。

提交（`git log main..w2-inputs-6`）：N05 1a95bcc → N09 红用例 0bc346a → N09 修 9d8a27c → 问题单 + 本报告（最后一笔）。
只动了 `Packages/SwitcherInputs/Sources/SwitcherInputs/`（Common/InputChannelMap.swift、File/FileInput.swift）、`Packages/SwitcherInputs/Tests/SwitcherInputsTests/`
（InputChannelMapTests 加一条、FileInputW2A6Tests 新）、`Packages/SwitcherInputs/Tests/DeckLinkTests/DeckLinkChannelMapTests.swift`（只加两条）、reports/issues/ 一张、本报告。
没碰 DeckLink / NDI 源码、契约、App、任何阈值。并行的 129–132 四个分支都没动 SwitcherInputs，G12 合并这一路不会撞。

**一句话**：两条都先照 Codex 的探针在本机复现成红（N05 三条用例让 xctest 进程 SIGTRAP；N09 的数字与 Codex 一样：位置 1.5 → 0、pushed 91 → 92），再改。
N09 照 prompt 原样只改 `resume()` 实测，画面好了但**音频坏了**（推帧线程版本号一变就把音频块序号清零，从旧锚点重数：281 块全跳、最后一块重写）——
所以版本号照 prompt 加，推帧线程改成时间线真变了才重数；另修了同根的两处（暂停没落实时改速率、读位置）。新用例 9 条全绿，Inputs 整包 133 条 0 红（11 跳过，都是权限 / 硬件）；
`make lint BRANCH=w2-inputs-6` 过。
"NDI 换源等音频重试后漏重挂"那条线索不在 NDI/、在 App 的 NDI 发送接线，静态确认确有漏挂，写了问题单（§1.5）。

---

## 1. 做了什么

### 1.1 N05：`requiredSourceChannels` 的 +1 改饱和、结果封顶 64（1a95bcc）

修前实测（本机 DeckLink SDK 是 NDI SDK 示例目录带的 10.11.2 副本，Fake 编得出来、DeckLink 用例真跑不跳过）：三条新用例都让 xctest 进程 **signal 5** 退出。
lldb 看 Fake 那条：崩在 queue `switcher.decklink.session.4`（`start()` → `sessionQueue.async` → `attempt()`）、`InputChannelMap.swift:36`
"Swift runtime failure: arithmetic overflow"——即 Codex 说的启动链：`attempt` 在查驱动 / 枚举设备之前就算 `cfg.audio_channels`，不插卡也崩。
（`DeckLinkInput(config:)` 构造本身不崩：构造时只算 `requestedChannel`，不 +1。）

改法：`requestedChannel(...).addingReportingOverflow(1)`，溢出取 Int.max；`needed` 再封顶 `InputChannelMap.maxSourceChannels = 64`（public 常量，在 SwitcherInputs 里，
不是契约）。越界下标用的时候本来就按契约钳到源的声道范围（`sourceChannel` / `clamp` 没动），这里只决定"源至少开几路"；调用方照旧再钳——DeckLink
`embeddedAudioChannels` 仍按 SDK 认的 2 / 8 / 16 往上取、最多 16，Core Audio 设备按实际声道数（它不调这个函数）。现有用例钉的 `[5,2]→6`、`[4]→5`、`[3,4,15]→5`
都在 64 以内、不变；没有用例钉 `[999]→1000`，所以按 prompt 做了封顶（`[999]` 现在返回 64，DeckLink 那边照旧 16）。

### 1.2 N09 红用例（0bc346a）

新文件 `FileInputW2A6Tests.swift`：照 Codex 的探针用真文件 `Tests/Fixtures/w1a-sample-20s.mov`（1080p60 20 s；前 400 帧是 60 fps 的源 A，图案帧号 = 帧序号 = 位置 × 60，
能直接核对画面接没接着走）、只记帧的槽（`RecordingSlot`：push 记数、留最新一帧，latest 不看 pts）。在没改的 FileInput 上实测：

| 用例 | 触发（照 Codex） | 修前实测 |
|---|---|---|
| immediate | 60 fps 节目播到 1.5 s，连着 `pause(); resume()`，两次 | 两次都是位置 1.5 → **0** → 0.5 s 后 0.45；pushed 91 → **92**、帧号 90 → 91；锚点 #0 → #93（Codex：1.5 → 0、至多 +1 帧） |
| 带音频 | 同上 + RecordingAudioRing | 0.5 s 只写 **1** 块、跳 **89** 块（源样本从旧锚点 0 重来，FIFO 早过了那里，全是 `.gone`） |
| 30 fps 轮询间隔 | 30 fps 节目，pause → 隔 1/60 s → resume，同一个输入 10 次 | 推完一帧 0.5–2.5 ms 内动手的 **5 次全没落实**、全部跳回 0.000、0.4 s 只推 1–2 帧（帧号 +2…+4）；后 5 次落实了、正常（两轮一样） |
| 暂停没落实时改速率（同根第二处） | pause → `rate = 2` → resume | 位置 1.5 → **0**、0.5 s 后 0.9、帧号 90 → 91 |
| 对照：落实 100 ms 后恢复 | — | 冻结 1.517（帧 91）→ 恢复 0.5 s 后 1.983（帧 119），对（Codex 1.466 → 1.983） |
| pause → seek → resume（D13 三种顺序） | 立即 / 定位后等 300 ms / 落实后再定位 | 三种都从 5 s 接着播（0.5 s 后 5.45–5.47、帧 328），对 |

30 fps 那条起初用 usleep 错开相位，两轮各只撞上 1 / 10：推帧线程推完一帧马上读一次快照、再睡 20 ms 读下一次，读到暂停请求就落实；
pause 落在推完之后 3.3 ms 以内，下一次读快照才在 16.7 ms 之外，而 usleep(16.7 ms) 在普通线程上常晚几 ms、晚到那次读之后。改成忙等探推帧边沿、忙等计时之后
前五次稳定卡进窗口（见 §5 第 1 条）。

### 1.3 N09 修（9d8a27c）

- **`resume()`**：`pauseApplied` 为真才把锚点拍换成 seekLead 之后的一拍（原来的路径）；没落实只清 `paused`，锚点不动，`version` 照 prompt 加 1。
  推帧线程落实暂停的那把锁里查 `q.paused`，看见已清就落不成（`return true`），下一轮按新快照照原时间线出帧——这一段是现有逻辑，没改。
- **推帧线程的音频块序号**（prompt 没写、实测必须改）：按 prompt 原样只改 `resume()` 跑带音频那条，画面好了（1.5 → 2.1、帧号 90 → 128），但
  音频 **跳 281 块、第 282 块 host time 步进 0（同一块写了两遍）**，after 快照里 lateWakes = 36（追 281 块、每轮 8 块 ≈ 35 轮）。原因：推帧线程看见 `version` 变了一律 `chunkIndex = 0`，
  块序号是从锚点数的，锚点没变却清零 → 新块从旧锚点那一刻数起：之前的块全成 `.gone`（跳过，每轮 8 块、醒来时刻在过去所以每轮记一次晚醒），
  最后写过的那块的样本还在 FIFO 里（trim 只丢到它前 2 个样本）、又写一遍。改成 `chunkTimeline`：时间线（锚点拍 / 锚点位置 / 速率 / 一拍秒数）
  真变了才清零。时间线不变而版本变的只有暂停请求和"没落实就取消"；时间线变而版本不变的只有推帧线程自己落实暂停（以及暂停中定位后挪冻结位置），
  那时 `paused` 为真、音频不出，恢复时重锚、版本 +1、时间线必然变 → 清零。`nextTick = nil`、`audioStalled = false` 照旧每次版本变都做。
- **暂停请求本身仍 +1 版本**（没按"取消不 +1、暂停也不 +1"那条路改）：推帧线程靠它把 `nextTick` 清掉、马上回到当前拍落实暂停（60 fps 下请求后 ≤ 1 拍、
  30 fps 下 ≤ 20 ms 落实）。拿掉的话要等到下一拍才落实（按读快照的时机推算，没实测），60 fps 每次暂停都晚一拍、"没落实"的窗口在 App 的 16.7 ms 轮询下几乎每次都撞上——
  有了取消路径那也是对的，但改了暂停的快慢，属于"文件输入别的行为"，不动。
- **同根两处**（都是"`paused` = 位置已冻结"的老假设，请求挂着时并不成立）：
  - `rate` setter：原来 `if !p.paused` 才按时间线重算锚点位置，请求挂着时留着旧锚点位置（开播就是 0）、只换锚点拍和速率；之后推帧线程落实暂停会覆盖锚点（没事），
    但若接着来的是没落实的恢复（现在 = 取消请求），就接着这条错线播 → 回到旧锚点。App 的 `InputRuntime.reconcile` 先改速率再 `applyPlayback`，
    "上一轮刚 pause、这一轮改速率 + resume"就是这个顺序。改成 `paused && pauseApplied` 才算冻结。
  - `positionSeconds`：原来 `paused` 就读锚点位置，请求挂着的那一下读到旧锚点（修前 immediate 用例里 1.5 → 0.0）。同样改成 `paused && pauseApplied`。
    App 不读它（只有 App/Tests/InputStripTests 和包内用例读），属于读数口径，一并改了是因为"没落实 = 时间线照走"要三处一致。
- 修后：新 6 条全过（数字见 §2）；连跑三遍都过，每遍 30 fps 那条都是 5 / 10 走取消路径。FileInputTests 16 + FileInputW2A5Tests 14 全过（D13 / D14 / 暂停每拍刷新 pts /
  音频对齐 / 往回定位音频不断都在里面）。
- 用例的几条位置断言改成和实测墙钟比（`HostClock` 量 sleep 前后），不和名义的 500 ms 比：按 prompt 原样那一轮里有一次 usleep(500 ms) 实际睡了 0.617 s（同机别的会话在跑）。

### 1.4 用例

| 文件 | 用例 | 说明 |
|---|---|---|
| InputChannelMapTests | `testN05_requiredSourceChannels_hugeIndexSaturatesAndCaps` | `[Int.max]` / `[Int.max−1]` / `[0, Int.max]` / `[Int.max, 3]`（环一路）→ 64；`[999]` 对照 → 64；64 边界；负下标 → 0；用的时候照旧钳到 15 / 0 |
| DeckLinkChannelMapTests（只加） | `testN05_embeddedAudioChannels_intMaxMapSaturatesTo16` | 纯计算，不要 SDK：→ 16，`requested: 0` 照旧 0 |
| 同上 | `testN05_deckLinkFake_intMaxChannelMap_startOpens16ChannelsAndClampsToLast` | 从 InputSource 取 `[Int.max]`、对着 Fake start：会话建起来、内嵌音频开 16 路，喂两包 16 路音频，环两路都 = 第 16 路（16/128）。无 SDK 时 XCTSkip（BLOCKED-SDK），构造那段照跑 |
| FileInputW2A6Tests（新） | 6 条 `testN09_…` | 见 §1.2 表 |

### 1.5 顺手核的线索：NDI 换源等音频重试后漏重挂（问题单 `reports/issues/W2A6-app-ndi-send-input-audio-lost-after-register-retry.md`）

Codex 的 `testNDI_SourceReplacementMustRestoreAudioAfterRegistrationRetry` 看的是 **NDI 发送**（输出源 = 输入 1）在输入 1 换来源之后的音频，代码在
`App/Sources/Engine/OutputRuntime.swift`，不在 W3-A 的 NDI 输入里。静态读下来确有漏挂：换源时 `InputRuntime.replaceSource` 先注销再注册，混音器里旧槽还在淡出（≈ 16 ms）
→ 新注册撞 `inputAlreadyRegistered`、30 ms 后重试；同一轮 `outputs.reconcile` → `reconcileNDI` 摘下重挂，`attachNDI` 只看此刻 `registeredInputs` 有没有这一路，
没有就**不建音频挂件**；重试成功后的 `onRegistered → followInputAudioSlots` 只跟 `inputAudio` 里已有的挂件，NDI 这路不在里面 → 之后一直没声音，要关开这路输出才回来。
ISO 换源不摘不挂、挂件一直在，所以没这个问题。Codex 当时没命中是因为他换的是合成源（`stop()` 要等一帧，比淡出慢，重试根本没发生，registerRetries = 0）。
按测试标准 §6 字面 S1；建议改法（`onRegistered` 里给 `audio == nil` 的 NDI 发送补挂）和确定性复现办法写在单子里。没动态复现（App 用例不归本路）。

---

## 2. 每个测试 ID：数值 / 阈值 / 通过否

N05 / N09 在测试标准里没有指标阈值；下表"阈值"是用例自己的断言。

| 测试 | 数值（修后） | 阈值（断言） | 通过否 |
|---|---|---|---|
| testN05_requiredSourceChannels_hugeIndexSaturatesAndCaps | `[Int.max]` → 64、`[999]` → 64、`[63]` → 64、`[62]` → 63、负下标 → 0；修前 SIGTRAP | 不 trap，等于封顶值 / 边界值 | 过 |
| testN05_embeddedAudioChannels_intMaxMapSaturatesTo16 | 16；修前 SIGTRAP | = 16 | 过 |
| testN05_deckLinkFake_intMaxChannelMap_startOpens16ChannelsAndClampsToLast | rebuilds 1、`last_audio_channels` 16、环 L/R = 0.125 / 0.125；修前 SIGTRAP（会话队列） | 会话建起、16 路、两路 = 16/128 | 过（SDK 在，真跑） |
| testN09_pauseThenImmediateResume_cancelsRequest_timelineAndFramesContinue | 两次都是 1.5 → 请求挂着 1.5 → 恢复 1.5 → 0.51 s 后 2.0；pushed 91 → 122；帧号 90 → 121；锚点不变 | 锚点不变；位置 ≥ 动手前；位置增量 = 墙钟 ± 0.03 s；0.5 s pushed ≥ 25、帧号 ≥ 25 | 过 |
| testN09_control_resumeAfterPauseApplied_continuesFromFrozenFrame | 冻结 1.517（帧 91），恢复 0.500 s 后 1.983（帧 119） | 暂停中不动；恢复后重锚；增量 ∈ [墙钟 − 0.1, 墙钟 + 1/60]；帧号 ≥ 24 | 过 |
| testN09_30fpsProgram_appPollInterval_tenCycles_neverJumpsBack | 没落实 5 / 10（推完 0.5–2.5 ms 动手）：0.4 s 观察窗走 0.433 s、帧号 +26…+28；落实的 5 次走 0.367–0.400 s（恢复重锚停 1–2 拍）、帧号 +22…+26 | 没落实的锚点不动、不往回跳；每次 0.4 s 走 ≥ 0.3 s、帧号 ≥ 18；没落实 ≥ 1 次 | 过（连跑 4 遍） |
| testN09_pauseSeekResume_D13Order_playsFromSeekTarget | 三种都在定锚 0.50 s 后 5.45–5.47、帧 328 | 暂停中停在 5 s / 第 300 帧；增量 ∈ [墙钟 − 0.1, 墙钟 + 1/60]；帧号 ≥ 324 且 ≈ 位置 × 60 ± 2 | 过 |
| testN09_rateChangeWhilePauseUnapplied_thenResume_positionContinues | 1.5 → 恢复 1.467 → 0.507 s 后 2.467；帧号 90 → 150 | 恢复 ≥ 动手前 − 0.06；增量 ∈ [2 × 墙钟 − 0.1, 2 × 墙钟 + 2/60]；帧号 ≥ 50 | 过 |
| testN09_pauseThenImmediateResume_withAudio_chunksStayContiguous | 动手前 281 块，0.5 s 后 375 块；写 94、跳 0；host time 首尾相接 | 无断点（步进 = 256 / 48000 s ± 2 ticks）；跳块 0；写 ≥ 80 | 过 |
| 已有：FileInputTests（16）+ FileInputW2A5Tests（14） | 30 条 0 红 | 原断言 | 过 |
| 已有：InputChannelMapTests 其余 5 + DeckLinkChannelMapTests 其余 3 | 0 红 | 原断言 | 过 |
| SwitcherInputs 整包（`swift test`，提交 9d8a27c） | 133 条：SwitcherInputsTests 81（6 跳）+ NDITests 25（2 跳）+ DeckLinkTests 27（3 跳），**0 失败**，4 分 49 秒；FileInputTests 两条解码计时用例这次也过了，没用上单独复跑 | 0 失败 | 过 |
| `make lint BRANCH=w2-inputs-6` | exit 0：禁词 / 版本 0.1.0 / Package.swift / 依赖方向 8 包 / 归属（5 个改动文件都在允许范围）/ 手册 / 215 个 Markdown 链接 / 实时符号 | exit 0 | 过 |

整包 11 条跳过（与改动无关，都是环境）：BLOCKED-权限（TCC）3 条——内置摄像头出帧、L1 摄像头两条（这个进程的责任进程没有相机用途说明，系统不弹提示，从 Terminal.app 跑才行）；
麦克风拒绝分支 1 条（本进程已有麦克风权限，前置状态不符）；BLOCKED-硬件 6 条——USB 摄像头热插拔、可拔的 USB 声卡、DeckLink L1 / L2 / 热插拔、外部 NDI 源（manual）；
"没装 NDI SDK"分支 1 条（本机装了，不适用）。总数比 Codex 在 1f9be64 上的 124 条多 9 条 = 本路新加的 9 条。
跑整包时负载 1.1–1.6（`uptime`；最忙的是 coreaudiod / WindowServer / Claude 自己，各 < 5 % CPU）。

---

## 3. 没做的和原因

- **NDI 发送端漏挂音频**：不在本路目录（App/Sources/Engine/OutputRuntime.swift），按 prompt 写问题单不修，也没写 App 用例动态复现。
- **App 宿主端到端（格子点暂停 / 恢复、App 60 Hz 轮询转发）没跑**：App 用例不归本路；包内用 1/60 s 间隔、按相位卡窗口的用例代替（Codex 也没做 App 全链）。
- **真 DeckLink 卡**：BLOCKED-硬件。启动链用 Fake IDeckLinkInput 走到了 `attempt()`；`isDriverPresent` / 设备枚举那一段（真卡路径）在 `cfg.audio_channels` 之后，算法同一个函数。
- 解码线程的 `shouldDrop` 在"暂停请求挂着"时也不丢晚帧（`!p.paused`）：只是优化，取消之后下一轮就照常丢，不影响 N09，没改。

## 4. 对契约的疑问

- 契约（`InputSource` 顶上"声道映射"）只说"越界的下标钳到源的声道范围里"，没说 `channels` 的值有没有上限；主 API / `MixerState.validate` 也不查它，
  所以 `[Int.max]` 能一路进到 DeckLink 的启动路径。本路按 prompt 只在采集侧兜住（饱和 + 封顶 64，行为不变）。要不要让校验器拒收离谱的下标（例如 ≥ 64，
  或 DeckLink ≥ 16）是契约 / 校验器的事（129 / 128 那一路），这里不提提案，只把问题留给用户定。
- `InputChannelMap.maxSourceChannels = 64` 是 SwitcherInputs 的 public 常量、不是契约；64 是 prompt 的建议值，比 DeckLink 的 16 和环的 8 路（`AudioFormat.maxChannels`）都大，
  只用来封顶"源至少开几路"。以后 Core Audio 设备要用这个函数算开几路时（现在不用），超过 64 路的设备（MADI / Dante 类）会被封在 64，到时再看。

## 5. 下一个会话需要知道的坑

1. **"暂停没落实"的窗口有多大，看推帧线程什么时候读快照**：推完一帧马上读一次；下一拍离得比 20 ms 远（30 fps）就先睡 20 ms 再读一次。读到暂停请求时
   `version` 变了 → `nextTick = nil` → 回到当前拍（它的醒点已过）当场落实。所以 60 fps 下请求后 ≤ 1 拍落实、App 16.7 ms 轮询基本撞不上（Codex 八次都没撞上）；
   30 fps 下只有推完之后 3.3 ms 以内 pause 的会撞上（随便哪个相位约一成）。要卡窗口：忙等探推帧边沿（`slot.pushed` 变了），隔 0.5–2.5 ms 再 pause，
   间隔也要忙等——普通线程的 usleep 常晚几 ms，晚到下一次读快照之后就落实了（usleep 版本两轮各 1 / 10）。
2. **`chunkIndex` 是"按 `chunkTimeline` 写过几块"**，别再改回"版本变就清零"：只改 `resume()` 的话取消暂停后音频从旧锚点重数（实测跳 281 块 + 一块重写 + 36 次晚醒）。
   时间线不经版本变化而改动只发生在推帧线程自己落实暂停 / 暂停中挪冻结位置，那时音频不出，恢复必然重锚。
3. **暂停请求仍要 +1 版本**：它让推帧线程当场落实暂停；拿掉会让每次暂停晚一拍落实（见 §1.3）。
4. "请求挂着"时 `isPaused` 为真、`pauseIsApplied` 为假，读位置 / 改速率都按还在播算；要看"真的停住了"用 `pauseIsApplied`（包内 internal）。
5. **w1a-sample-20s.mov 的帧号**：前 400 帧（0–6.65 s）= 帧序号；第 400 拍 Cut 到源 B（30 fps，帧号 = 序号 / 2）。用帧号核对的用例要留在 6.6 s 以内
   （30 fps 那条起播 0.3 s、10 次 × 0.4 s 观察窗，做完约 4.6 s）。
6. DeckLink 的 Fake 用例在本机真跑：Package.swift 找不到 `~/SDKs/DeckLink` 就用 NDI SDK 示例目录里的 BMDSDK 10.11.2 副本。没装 NDI SDK 的机器上 Fake 那条 N05 跳过（BLOCKED-SDK），
   纯计算那条照跑。
7. N05 修前崩在 DeckLink 会话队列上、不在测试线程上，`swift test` 只报"exited with unexpected signal code 5"、没有堆栈；用
   `xcrun lldb --batch -o run -- xctest -XCTest <Class>/<method> <xctest 包>` 能看到停在哪个队列、哪一行。
