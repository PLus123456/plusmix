# Tests/Fixtures/ —— 跨包共用的测试素材

放在仓库根、不属于任何 SwiftPM 包，因为它们跨包共用：W1-A（frameprobe 回归样例，20 秒 H.264）和 W1-E（pattern.mov，10 秒含 click 音轨）产出，W2-A 的文件输入用它们当测试素材。

规矩：每个文件 ≤ 5 MB；`.gitignore` 对 `*.mov` / `*.mp4` 全局忽略，只对本目录放行。测试里定位路径用 `#filePath` 往上找仓库根，不要写绝对路径。

## 文件

| 文件 | 来源 | 内容 |
|---|---|---|
| `w1a-sample-20s.mov`（439 KB） | W1-A，`frameprobe synth --out Tests/Fixtures/w1a-sample-20s.mov --seconds 20 --bitrate 2000000 --audio aac` | 1080p60 20 s H.264（目标 2 Mbps，图案太简单实际 77 kbps）+ AAC 128 kbps 单声道。A = 输入 ID 0、灰 64、60 fps；B = ID 1、灰 192、30 fps（每帧重复两次 = 设计内 50%）。第 400 拍 Cut A→B，第 700 拍 Fade 30 拍 B→A。闪光每 60 帧一次，click 与闪光同刻（t0 = 1 s host time，图案里的 genTimeMs 从 1000 起）。 |
| `w1a-sample-20s.expected.json` | W1-A，`W1A_RECORD_SNAPSHOT=1 swift test --filter FixtureSnapshotTests`（在 Packages/SwitcherTestKit 下） | frameprobe 对上面样例的输出快照：前 130 帧、Cut / Fade 附近的帧、stats / switches / fade / av / 多文件 av。快照测试整数字段精确比，灰度 ±1.5、时间 ±0.1 ms。 |

对样例跑 frameprobe：

```bash
swift build -c release --package-path Tools/frameprobe && FP=Tools/frameprobe/.build/release/frameprobe && \
$FP stats Tests/Fixtures/w1a-sample-20s.mov --input-fps 0=60,1=30 --markdown && \
$FP switches Tests/Fixtures/w1a-sample-20s.mov --markdown && \
$FP fade Tests/Fixtures/w1a-sample-20s.mov --fade-at 700 --duration 30 --markdown && \
$FP av Tests/Fixtures/w1a-sample-20s.mov --markdown
```
