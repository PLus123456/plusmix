# Tests/Fixtures/ —— 跨包共用的测试素材

放在仓库根、不属于任何 SwiftPM 包，因为它们跨包共用：W1-A（frameprobe 回归样例，20 秒 H.264）和 W1-E（pattern.mov，10 秒含 click 音轨）产出，W2-A 的文件输入用它们当测试素材。

规矩：每个文件 ≤ 5 MB；`.gitignore` 对 `*.mov` / `*.mp4` 全局忽略，只对本目录放行。测试里定位路径用 `#filePath` 往上找仓库根，不要写绝对路径。

## 文件

| 文件 | 来源 | 内容 |
|---|---|---|
| `w1a-sample-20s.mov`（439 KB） | W1-A，`frameprobe synth --out Tests/Fixtures/w1a-sample-20s.mov --seconds 20 --bitrate 2000000 --audio aac` | 1080p60 20 s H.264（目标 2 Mbps，图案太简单实际 77 kbps）+ AAC 128 kbps 单声道。A = 输入 ID 0、灰 64、60 fps；B = ID 1、灰 192、30 fps（每帧重复两次 = 设计内 50%）。第 400 拍 Cut A→B，第 700 拍 Fade 30 拍 B→A。闪光每 60 帧一次，click 与闪光同刻（t0 = 1 s host time，图案里的 genTimeMs 从 1000 起）。 |
| `w1a-sample-20s.expected.json` | W1-A，`W1A_RECORD_SNAPSHOT=1 swift test --filter FixtureSnapshotTests`（在 Packages/SwitcherTestKit 下）；W1-A2 重录（av 报告加了整秒配对 / 音轨时间轴字段，老字段的值没变） | frameprobe 对上面样例的输出快照：前 130 帧、Cut / Fade 附近的帧、stats / switches / fade / av / 多文件 av。快照测试整数字段精确比，灰度 ±1.5、时间 ±0.1 ms。 |
| `w2d-rtmp-stream-4s.mp4`（2.9 MB） | W1-A2：W2-D `MediaMTXTests.testRTMP_endToEnd_10s_framesContinuousAndAVAligned` 在本机（2026-09-18 13:20）让 MediaMTX 落盘的 fMP4，在顶层 box 边界截到前 4 个分片（ftyp + moov + 4 × moof/mdat，不改任何字节；MediaMTX 每个 part ≈ 1 s、两轨同一个 moof） | 推流落盘文件的代表：**无编辑列表、AAC 无 priming 信息、音轨 tfdt = 960（20 ms）而视频 tfdt = 0**。1080p60 H.264 6 Mbps 225 帧（帧号 0…224，输入 ID 3）+ AAC 48 kHz 双声道 171 包；闪光 0 / 1 / 2 / 3 s，click 1 / 2 / 3 s。AVFoundation 对它把音轨归零又裁 2112 样本，老 frameprobe av 报 +64 ms；修正后 0.000 ms，与 ffmpeg 口径一致（`StreamRecordingProbeTests`，问题单 W2D-w1-testkit-frameprobe-av-on-stream-recordings）。重做：跑一次 W2-D 的用例，取 `$TMPDIR/switcher-streaming-tests/rtmp-e2e/mtx1/s1/*.mp4`，按 reports/w1-testkit-2.md §5 的脚本截断。 |

对样例跑 frameprobe：

```bash
swift build -c release --package-path Tools/frameprobe && FP=Tools/frameprobe/.build/release/frameprobe && \
$FP stats Tests/Fixtures/w1a-sample-20s.mov --input-fps 0=60,1=30 --markdown && \
$FP switches Tests/Fixtures/w1a-sample-20s.mov --markdown && \
$FP fade Tests/Fixtures/w1a-sample-20s.mov --fade-at 700 --duration 30 --markdown && \
$FP av Tests/Fixtures/w1a-sample-20s.mov --markdown --discontinuities && \
$FP av Tests/Fixtures/w2d-rtmp-stream-4s.mp4 --markdown
```
