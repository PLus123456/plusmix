# 001 Stats.encoder 的录制字段 + AudioBlockConsumer 协议

提出会话 / 分支：W1-E / w1-outputs（worktree 分支 claude/w1-outputs-6d38c6）
状态：**已批**（用户 2026-09-18，按 G3 报告 §7 第 2 条：A、B 都批）。由契约会话 P2（docs/plan/prompts/41）落地。
落地：**已落地**（P2，2026-09-18，分支 p2-contracts）。A：`Stats.EncoderEntry` 加 frames / dropped / disk_free_mb（与 002 的 reconnects / state 一起），填数方 `RecorderCounters.statsEntry` / `Recorder.statsEntry`；
B：`SwitcherContracts.AudioBlockConsumer`（Render.swift，签名逐字不动），SwitcherOutputs 的那份删掉，`SwitcherAudioIntegration.AudioBlockConsuming` 改 typealias，headless 的空扩展删掉。见 reports/p2-contracts.md。

## 改什么

### A. `Stats.EncoderEntry` 加字段（Stats.swift、测试标准 §7 的 stats.jsonl 行）

现在：`encoder[{skipped, bitrate}]`。
提议：`encoder[{skipped, bitrate, frames, dropped, disk_free_mb}]`

| 键 | 类型 | 口径 |
|---|---|---|
| `frames` | UInt64 累计 | 写进文件 / 送上网络的视频帧数（Recorder：`RecorderCounters.videoFrames`；推流：已发送帧数） |
| `dropped` | UInt64 累计 | 编码之后、落地之前丢的帧：writer 不接（`videoFramesRejected`）+ 推流发送队列满（W2-D 的 E9 网络丢帧口径） |
| `disk_free_mb` | Double | 录制目录所在卷的剩余 MB；非录制输出写 0 |

W1-E 的 prompt 要求"Stats：帧数、丢帧、码率、磁盘剩余"，而契约冻结的 §7 行只有 skipped / bitrate（P1 报告第 3 节也指出推流字段同样缺）。
W2-D 还会要 `reconnects`（重连次数）；如果批这条，建议一起加，免得两次提案：`reconnects` UInt64 累计。

### B. `AudioBlockConsumer` 协议升到 SwitcherContracts（Render.swift 旁边）

现在只在 SwitcherOutputs 里：

```swift
public protocol AudioBlockConsumer: AnyObject {
    var consumerName: String { get }
    func consumeAudio(planes: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frameCount: Int, hostTime: HostTime)
}
```

与 `FrameConsumer` 对称：Master 混音块的消费者（录制、推流、NDI 发送）。`hostTime` 是块首样本的 host time（与 `AudioRing.write` 同一口径）。
调用方是**非实时**的泵线程（把混音回调写进 SPSC 环的块搬出来），实现必须立即返回、只拷进自己的有界缓冲。

## 为什么

- A：铁律 4 要求所有数字进 Stats，UI / API / 测试三方读同一个结构。现在录制的帧数、丢帧、磁盘剩余只能从 `RecorderCounters` 读，
  引擎汇总 Stats 时没地方放；S7（磁盘满只停录制并提示）和 E9（网络丢帧计数）的判定都要读它们。
- B：音频块从混音器到输出的接口现在没有契约。W2-E（音频集成，改 SwitcherEngine/Audio* 和 SwitcherAudio/Integration）看不到 SwitcherOutputs，
  只能靠组装方（headless / App）写胶水把环里的块喂给每个录制 / 推流对象；协议进契约后 W2-E 可以直接依 `[any AudioBlockConsumer]` 派发。

## 影响谁

- A：`Stats.swift`（加字段 + CodingKeys + jsonKeys）、`SwitcherContractsTests` 的 `stats_jsonKeysSnapshot`（字面量要更新）、
  W1-A 的 StatsWriter / StatsSummary（多三列）、W1-B 的 Stats 汇总（从 `RecorderCounters` / `EncoderCounters` 填）、W2-D 推流。
  jsonl 老文件：新字段缺失时解码要给默认 0（`decodeIfPresent`），否则 G2 之前录的 stats 读不回来。
- B：SwitcherContracts 加一个协议；SwitcherOutputs 删掉自己那份（同名同签名，rebase 时直接删）；W2-E、W2-D、headless 用它。

## 怎么迁移

- Show 文件 schemaVersion 不动（Stats 不在 Show 里）。
- stats.jsonl：新字段 `decodeIfPresent` 默认 0；写出时总是写全。基线表（baselines/）不受影响。
- 不批 A 的话：W1-E 的数字留在 `RecorderCounters` / `EncoderCounters`，引擎只把 skipped / bitrate 汇总进 Stats，帧数 / 丢帧 / 磁盘走 API 的另一条只读路径 —— 这就违反"三方读同一个结构"，需要你拍板。
- 不批 B 的话：组装方各自写泵；W2-E 的 prompt 里加一句"把 Master 块派发给输出层的泵由 headless / App 提供"。
