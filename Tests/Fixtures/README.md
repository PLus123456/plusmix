# Tests/Fixtures/ —— 跨包共用的测试素材

放在仓库根、不属于任何 SwiftPM 包，因为它们跨包共用：W1-A（frameprobe 回归样例，20 秒 H.264）和 W1-E（pattern.mov，10 秒含 click 音轨）产出，W2-A 的文件输入用它们当测试素材。

规矩：每个文件 ≤ 5 MB；`.gitignore` 对 `*.mov` / `*.mp4` 全局忽略，只对本目录放行。测试里定位路径用 `#filePath` 往上找仓库根，不要写绝对路径。

## 文件

| 文件 | 来源 | 内容 |
|---|---|---|
| `w1a-sample-20s.mov`（439 KB） | W1-A，`frameprobe synth --out Tests/Fixtures/w1a-sample-20s.mov --seconds 20 --bitrate 2000000 --audio aac` | 1080p60 20 s H.264（目标 2 Mbps，图案太简单实际 77 kbps）+ AAC 128 kbps 单声道。A = 输入 ID 0、灰 64、60 fps；B = ID 1、灰 192、30 fps（每帧重复两次 = 设计内 50%）。第 400 拍 Cut A→B，第 700 拍 Fade 30 拍 B→A。闪光每 60 帧一次，click 与闪光同刻（t0 = 1 s host time，图案里的 genTimeMs 从 1000 起）。 |
| `w1a-sample-20s.expected.json` | W1-A，`W1A_RECORD_SNAPSHOT=1 swift test --filter FixtureSnapshotTests`（在 Packages/SwitcherTestKit 下）；W1-A2 重录（av 报告加了整秒配对 / 音轨时间轴字段，老字段的值没变） | frameprobe 对上面样例的输出快照：前 130 帧、Cut / Fade 附近的帧、stats / switches / fade / av / 多文件 av。快照测试整数字段精确比，灰度 ±1.5、时间 ±0.1 ms。 |
| `w2d-rtmp-stream-4s.mp4`（2.9 MB） | W1-A2：W2-D `MediaMTXTests.testRTMP_endToEnd_10s_framesContinuousAndAVAligned` 在本机（2026-09-18 13:20）让 MediaMTX 落盘的 fMP4，在顶层 box 边界截到前 4 个分片（ftyp + moov + 4 × moof/mdat，不改任何字节；MediaMTX 每个 part ≈ 1 s、两轨同一个 moof） | 推流落盘文件的代表：**无编辑列表、AAC 无 priming 信息、音轨 tfdt = 960（20 ms）而视频 tfdt = 0**。1080p60 H.264 6 Mbps 225 帧（帧号 0…224，输入 ID 3）+ AAC 48 kHz 双声道 171 包；闪光 0 / 1 / 2 / 3 s，click 1 / 2 / 3 s。AVFoundation 对它把音轨归零又裁 2112 样本，老 frameprobe av 报 +64 ms；修正后 0.000 ms，与 ffmpeg 口径一致（`StreamRecordingProbeTests`，问题单 W2D-w1-testkit-frameprobe-av-on-stream-recordings）。重做：跑一次 W2-D 的用例，取 `$TMPDIR/switcher-streaming-tests/rtmp-e2e/mtx1/s1/*.mp4`，按 reports/w1-testkit-2.md §5 的脚本截断。 |
| `w2a5-rot90-320x240.mov`（2.3 KB） | W2-A5（prompt 117，Codex 审查 D15），ffmpeg 9.0.1 造，命令见下 | 1 s、30 帧（30 fps）H.264 320×240 yuv420p（BT.709 limited），编码方向四色象限：左上红、右上绿、左下蓝、右下白；视频轨带 90° 显示矩阵（ffmpeg `-display_rotation 90`，AVFoundation 读成 `preferredTransform` = (0, −1, 1, 0, 0, 0)，即逆时针 90° 才正）。转正后 240×320，四角 = 左上绿、右上白、左下红、右下蓝（与 AVAssetImageGenerator `appliesPreferredTrackTransform` 的参照一致）。`FileInputW2A5Tests` 的 D15 用例读它。 |

`w2a5-rot90-320x240.mov` 的造法（两步：先编一段正的，再只改显示矩阵、流拷贝）：

```bash
ffmpeg -f lavfi -i "color=c=red:s=160x120:r=30:d=1" -f lavfi -i "color=c=lime:s=160x120:r=30:d=1" \
       -f lavfi -i "color=c=blue:s=160x120:r=30:d=1" -f lavfi -i "color=c=white:s=160x120:r=30:d=1" \
       -filter_complex "[0][1][2][3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0,scale=out_color_matrix=bt709:out_range=limited,format=yuv420p" \
       -c:v libx264 -crf 18 -g 30 -bf 0 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -t 1 upright.mov
ffmpeg -display_rotation 90 -i upright.mov -c copy Tests/Fixtures/w2a5-rot90-320x240.mov
```

180° / 270° / 镜像 / 带平移的手机矩阵（(0, 1, −1, 0, h, 0) 这类）不另放夹具：用例里用 AVAssetWriter（`AVAssetWriterInput.transform`）现场写八种。

对样例跑 frameprobe：

```bash
swift build -c release --package-path Tools/frameprobe && FP=Tools/frameprobe/.build/release/frameprobe && \
$FP stats Tests/Fixtures/w1a-sample-20s.mov --input-fps 0=60,1=30 --markdown && \
$FP switches Tests/Fixtures/w1a-sample-20s.mov --markdown && \
$FP fade Tests/Fixtures/w1a-sample-20s.mov --fade-at 700 --duration 30 --markdown && \
$FP av Tests/Fixtures/w1a-sample-20s.mov --markdown --discontinuities && \
$FP av Tests/Fixtures/w2d-rtmp-stream-4s.mp4 --markdown
```

## W1-A3（2026-09-23）重录

`w1a-sample-20s.expected.json` 因为 frameprobe 加了**解码自证**（`SelfCheck`：帧号行、时间戳行、ID 块、底色、节奏互相印证，
默认开，`--no-self-check` 关）重录了一次，样例文件 `.mov` 本身没动。变化只在第 700 拍那次 Fade 的中间帧：

| 项 | 老（只按契约解码） | 新（自证） |
|---|---|---|
| 帧号读不出 | 1 | 27 |
| 输入 ID 读不出 | 25 | 27 |
| 输入 0 的帧 / 不同帧号 | 872 / 872 | 871 / 871 |
| 输入 1 的帧 / 不同帧号 | 303 / 152 | 302 / 151 |
| Fade 那次切换的中间帧数 / 新 ID 出现的帧 | 25 / 728 | 27 / 729 |
| 闪光 / click / 配上（A2） | 20 / 20 / 20 | 20 / 20 / 20（不变） |

老快照里第 702–714 帧被算成"输入 1 的第 351…357 帧"、第 716–729 帧被算成"输入 0 的第 716…729 帧"——
它们是 Fade 的合成帧，码字块一半落在黑白中间（混合比例 0.18–0.82），现在整帧判成解不出，不再进 V4 / C3 的统计。
闪光位在闪光块本身是纯黑 / 纯白时保留（两路合成源共用 t0，第 720 拍两路同时闪），所以 A2 的 20 对配对一个没少。
