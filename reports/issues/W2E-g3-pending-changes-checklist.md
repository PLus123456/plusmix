# W2-E 留给验收（G3）决定的修改清单

归属会话 / 分支：W2-E / `w2-audio-integ`（harness 分支 `claude/w2-audio-integ-00e60c`），main 2290b4e 起
发现于：W2-E 全程；每一条的证据在 `reports/w2-audio-integ.md` 或对应问题单 / 提案里，这里只列"要不要改、谁改、不改会怎样"，由验收对话决定。
分级：**必须** = 不做 W2-E 的交付在合并后跑不起来或指标回退；**建议** = 有指标 / 规则依据但可以推后；**可选** = 设计取舍，看用户。

## 一、合并 W2-E 时的接线（G3 自己的目录，各包 0 行）

| # | 改什么 | 为什么 | 归属 | 分级 | 不改的后果 | 详情 |
|---|---|---|---|---|---|---|
| 1-1 | `Tools/switcher-headless` 换用 `SwitcherAudioIntegration.AudioEngine`：删 `AudioPump.swift`，`HeadlessRun.swift` / `HeadlessCLI.swift` 按补丁改（149 行 diff），`Package.swift` 加产品 `SwitcherAudioIntegration` | G2 的 headless 自己 attach 环、自建泵，块 PTS 没扣混音器年龄，A2 = −16.6…−18.5 ms；换成 AudioEngine 后 A2 = 0.000 ms（10 min 空设备）/ −0.017 ms（10 min 真设备），A3 真设备 60 min 斜率 × 8 h 0.20 ms | G3（`Tools/` 是检查点目录） | 必须 | gate 里 A2 继续不过；AFV / FTB / 监听 / 真设备重采样全都不在 headless 路径上 | `W2E-g3-headless-audio-engine-wiring.md`（含完整补丁和 7 条接线要点） |
| 1-2 | headless 里加一行 `extension Recorder: AudioBlockConsuming {}` | 集成层的消费者协议与 W1-E 的 `AudioBlockConsumer` 逐字同签名，空扩展即可接上；提案 001 B 批了之后这行删掉 | G3 | 必须（与 1-1 一起） | 编不过 | 同上 |
| 1-3 | headless 封口顺序：引擎停 → 等含边界的音频块送到（边界 + 对齐延迟 + 2 块 + 6 ms）→ `audioEngine.removeConsumer(录制器)` → `rec.stop(atTick:)` → `audioEngine.stop()` | W1-E 的录制器先查漂移后查 stopTime，边界之后还在送块会补静音拖死（45 s 冒烟跑封口卡 3 分钟） | G3 | 必须（补丁里已含） | 跑满时封口挂死 | `W2E-w1-outputs-recorder-drift-check-before-stop.md` |
| 1-4 | `SW_AUDIO_SILENT=1` → `outputChannelMap = BusChannelMap(master: nil)`（真设备不出声、Master 照常录）；`--iso-audio N`（A4 用的 ISO 音轨录制器） | 长跑 / A4 要用；不是产品功能 | G3 | 建议 | 真设备 gate 会从扬声器放 10 分钟正弦 + click；A4 文件级测不了 | 补丁里已含 |
| 1-5 | App 接线（`SwitcherSession`）：同 headless 的 6 步（建 AudioEngine → 每路 `registerInput(number:ring:hints:)` → `addConsumer(录制器, source: .master)` → `engine.audioStatsProvider = { audioEngine.audioCounters }` → `start(clock:)` / `stop()`；调音台表读 `audioEngine.status` 或 `meters`） | W2-B 的报告说录制按钮 / 调音台表都等接线 | G3（`App/` 胶水 ≤ 50 行）或 W3-E | 建议 | App 没声音、没表 | 要点同 `W2E-g3-headless-audio-engine-wiring.md` |
| 1-6 | gate2：A2 判定继续用"整秒闪光"口径（`scripts/gate2-report.py` 已是）；可选把文件级不连续检测（`a1check` 的 30 行）挂进 gate 当 A1 第三项 | 59.94 在播段的闪光周期 1.001 s 是已知假象（G2 第 5 条）；A1 = 超时 + 欠载 + 不连续三项 | G3 | 可选 | A1 第三项只能手工核 | 报告 §2 A1 |

## 二、契约提案（用户拍板）

| # | 改什么 | 为什么 | 归属 | 分级 | 不批的后果 | 详情 |
|---|---|---|---|---|---|---|
| 2-1 | 提案 004：`Stats.audio` 加 `discontinuities`（A1 第三项）与 `meters`（四总线峰值 / 真峰值 / LUFS，每路峰值） | 铁律 4 三方读同一个结构；W2-B 调音台"读 Stats"；W2-C 与 SwitcherAudio 同层，看不到 `AudioEngineStatus` | 用户 → P1 / 契约会话改，W1-A（StatsWriter / Summary）、W2-E（填字段）跟改 | 建议 | 表只在 `AudioEngineStatus`（App 能 import 直接读，API 要另开只读路径）；A1 第三项在报告里手填 | `docs/contract-changes/004-stats-audio-meters-and-discontinuities.md` |
| 2-2 | 提案 001 B：`AudioBlockConsumer` 升契约 | 集成层与 W1-E 各自一份同签名协议，靠空扩展对上 | 用户；批后 W2-E 把 `AudioBlockConsuming` 改成 typealias（一行） | 建议 | 每个组装方多写一行扩展 | `docs/contract-changes/001-…`（W1-E 提的） |
| 2-3 | 对齐延迟 `alignmentFrames`（默认 2048 = 42.67 ms）要不要进 `AudioState` / Show（新提案，未写） | 它决定"节目音频比采集晚多少"、扬声器与 PGM 画面的对时；现在只是 `AudioEngineConfiguration` 的一项，按场合改要改代码 | 用户 | 可选 | 低延迟监听 vs 大块生产者只能改配置不能存节目文件 | 报告 §4 第 1 条 |
| 2-4 | 每路 AFV 开关（`InputAudioSettings.afv`）要不要加 | 契约只有全局 `AudioState.afv`：开 = 只有 PGM（转场中 PGM + PVW 交叉）可闻，叠加通道不门控 | 用户 | 可选 | 想让某路（如解说麦）不跟画面，只能关 AFV 手推 | 报告 §3；W1-D 报告 §4 第 4 条同问 |
| 2-5 | 提案编号撞号：W2-A、W2-D 各自用了 002，W2-E 改成了 004（留 003） | 并行会话各自递增 | G3 合并时统一编号 | 必须（只是改文件名 / 标题） | 目录里两个 002 | — |

## 三、退回原会话的修改（问题单已写；验收决定现在改还是记入已知问题）

### W1-D `w1-audio`（`CSwitcherAudioRT/sw_mix.c`、`AudioMixer.swift`）

| # | 改什么 | 为什么 / 证据 | 分级 | 不改的后果 | W2-E 侧跟改 |
|---|---|---|---|---|---|
| 3-1 | `SW_CMD_CROSSFADE` 收帧数（现在只收整块） | 30 拍 = 500 ms → 94 块 = 501.33 ms（+0.27%），尾部 tan(θ)·dθ 放大：≥ −20 dB 的块最大 0.36 dB，−20…−40 dB 尾巴最大 0.84 dB（prompt 的 ≤ 0.5 dB 只能按 −20 dB 以上判） | 建议 | AFV 曲线尾巴 0.5–0.9 dB（听不见） | `crossfade(durationFrames:)` 一行 |
| 3-2 | `sw_xfade_block` 走满时写的 `afv = 0 / 1` 被 `sw_process_input` 用最后一个曲线样本覆盖 | Cut 之后 from 路留 −44 dB、τ 3 ms 的尾巴（块 1 RMS 7.8e-4 → 块 3 2.3e-5）；"Cut 后严格为 0"不成立 | 建议 | 听不见；判据里已留出 | 无 |
| 3-3 | `SW_CMD_ATTACH_INPUT` 加"目标年龄"参数：就绪时从 `host_time − 目标年龄` 对应的帧起消费（现在从 `write_index − back` 起，年龄 = 703 + 相位 [0, 256) 帧，每次随机） | 各路年龄天然一致，W2-E 的对齐延迟线只剩残差；就绪不再有随机相位；也是 3-4 的前提 | 建议 | W2-E 现在靠就绪后读 `ageSetpoint` 再设延迟线，多一次 8 ms 的轮询与一条延迟线（已验证正确） | 对齐延迟改为只补残差 |
| 3-4 | 耳机分支能绕过延迟线（或延迟线前 / 后可选） | 对齐延迟（42.67 ms）一并进了 Headphones 总线，A5（麦克风到耳机 ≤ 20 ms）与节目对齐二选一；A5 现在 BLOCKED-硬件，脚本用"对齐 0 + 目标 1 块 + buffer 128"的低延迟配置才能过 | 建议（A5 解锁前不急） | A5 达标时节目不对齐，或反之 | HP 不走对齐 |
| 3-5 | 输入 tap 加"推子后、AFV 前"的来源 | 现在的输入 tap 在 AFV 增益之后，AFV 开着时非 PGM 路的 ISO 音轨是静音 | 建议（W3-C 做视频 ISO 前） | ISO 只能在 AFV 关时用 | ISO tap 换来源 |

详情：`W2E-w1-audio-crossfade-tail-block-duration-monitor.md`。
**3-1…3-5 已由 W1-D2（`w1-audio-2`，2026-09-19）全部做完，含第四节里对应的四条 W2-E 侧跟改**（`durationFrames:`、`maintainAlignment` 只补 alignment − 确定年龄、耳机不走对齐 + A5 脚本、ISO tap 换来源）；数字见 `reports/w1-audio-2.md`。

### W1-E `w1-outputs`（`Recording/Recorder.swift`）

| # | 改什么 | 为什么 / 证据 | 分级 | 不改的后果 | W2-E 侧跟改 |
|---|---|---|---|---|---|
| 3-6 | `drainAudio` 把 `stopNs` 判断放到漂移判断之前；`finishRequested` 后 `appendPCM` 立即返回并计数 | 边界之后还在到达的块触发补静音，补的长度随墙钟增长，`appendPCM` 每 4096 帧等 200 ms 超时 → 封口拖死 3 分钟（45 s 冒烟跑） | 必须（否则只能靠 1-3 的绕法） | 任何组装方在封口后多送几块就挂 | 1-3 的绕法可以撤 |
| 3-7 | 给"预告停止拍"入口（`stop(atTick:)` 允许在边界之前调，或 `setStopTick`） | 最后一拍到 `stop(atTick:)` 之间到达的越界块被照常写进去：音轨比名义时长多 54–102 ms（10 min 空设备 +4910 样本、真设备 +1681、60 min +3519；G2 的 +3745 / +5306 同源）；E5"两轨差 ≤ 20 ms"不过 | 建议（E5 是 G3 判的） | E5 不过；A2 / A3 不受影响（偏移恒定） | headless 可以在知道最后一拍时提前调 |
| 3-8 | （G2 已提）`appendPCM` 超时丢样本计数 | `G2-w1-outputs-stop-with-live-audio.md` | 建议 | 丢样本不可见 | 无 |

详情：`W2E-w1-outputs-recorder-drift-check-before-stop.md`。

### W1-A `w1-testkit`（frameprobe / TestKit）

| # | 改什么 | 为什么 | 分级 | 不改的后果 |
|---|---|---|---|---|
| 3-9 | 把 `DiscontinuityDetector.analyze`（按已知 click 位置排除的离线口径，30 行）搬进 frameprobe（`frameprobe av --discontinuities` 之类），或直接收编 scratchpad 的 `a1check` | prompt 要求不连续检测器在 frameprobe / TestKit；那两个不是 W2-E 目录，现在在集成层 + scratchpad 探针 | 建议 | A1 第三项文件级只能靠 W2-E 的探针 |
| 3-10 | `frameprobe av` 的 A2 判定默认按"闪光落在整秒拍上"的配对（或 click 也按在播输入的闪光周期走） | 59.94 在播段的 1.001 s 周期把均值 / 最大值拉偏（G2 第 5 条），gate2-report.py 已另算一行，frameprobe 自己的 passA2 仍是 ❌ | 建议 | 每次都要人看两行 |

## 四、W2-E 自己层里等上面决定之后再改的（都是一两行）

| 前置 | W2-E 改什么 |
|---|---|
| 2-2 批 | `AudioBlockConsuming` → `typealias AudioBlockConsuming = AudioBlockConsumer` |
| 2-1 批 | `AudioEngine.audioCounters` 填 `discontinuities` / `meters`（数据已在 `AudioEngineStatus`） |
| 3-1 做 | `crossfade(durationBlocks:)` → `durationFrames:` |
| 3-3 做 | `maintainAlignment` 只补残差（年龄 > 目标的部分） |
| 3-4 做 | 耳机不走对齐；A5 脚本改回默认对齐 |
| 3-5 做 | ISO tap 来源换"推子后 AFV 前" |
| 2-3 批 | `alignmentFrames` 从状态 / Show 读 |

## 五、环境与流程

| # | 事 | 说明 |
|---|---|---|
| 5-1 | 2026-09-15 14:43 本机 Xcode 换成 27.0（Swift 6.4） | W2-E 的全部构建 / 测试在换之前用 Xcode 26.6 / Swift 6.3.3 跑完；G3 合并前确认工具链（CLAUDE.md / 记忆写的是 26.6），换了就整仓 `make test` 再跑一遍 |
| 5-2 | 长跑素材不入库 | `scratchpad/run-null10 / real10 / real60 / a4`（out.mov、stats.jsonl、av.md / av.json）与 `a2-headless`（打补丁的 headless 副本）、`a1check` 都在会话 scratchpad，可能被清；G3 要复核就按 1-1 的补丁重建 headless，跑 `make gate2` 即得 A2 |
| 5-3 | 真设备用例会把系统默认输出设备设成 48 kHz、buffer 256 | W1-D `AudioOutputDevice.start` 的行为；跑 `SW_AUDIO_REAL_DEVICE=1` 时别改默认设备、别开会 |
