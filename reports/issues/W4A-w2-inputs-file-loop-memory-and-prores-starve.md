# W4-A → W2-A：文件输入循环播放时每圈涨约 0.5 MB（30 s 片段 = 60 MB/h，8 小时 S2 过不了）；ProRes 422 HQ 片段循环点每圈空一拍、推帧线程大量晚醒

归属会话 / 分支：W2-A 输入（`Packages/SwitcherInputs/Sources/SwitcherInputs/File/`；若按下面"怎么排除渲染器"证明 FileInput 自身不涨，则转 W1-C / W3-B 的渲染器）
发现于：W4-A（`w4-soak`，2026-09-27），`make soak-1h`（`.build/soak/1h/`）与本单里的对照实验（`.build/soak/leakhunt/`、`.build/soak/leakhunt2/`）；headless 提交 af2414f 之后
严重级：
- 第 1 条 **S1**（功能能继续，但内存无界增长；L4 的 S2 ≤ 10 MB/h 是发布门槛，8 小时 soak 用 30 s 循环的片段会红）
- 第 2 条 S2（ProRes 循环片段每圈卡一下；H.264 没有这个问题，有绕过）

## 1. 每圈 +0.5 MB（phys_footprint），与编码无关

**现象**：`make soak-1h`（负载含 11 号文件输入：30 s 的 ProRes 片段循环）里 Stats 的 `rss_mb`（phys_footprint）每分钟最小值从 908 → 964 MB / 55 分钟，
约 **60 MB/h**；预热后拟合 108.9 MB/h（被秒级 ±60 MB 起伏拉高）。同一时间 ps 的 resident 只涨 4.5 MB/h——涨的是记在 footprint 账上、不在常驻页里的内存。

**分组对照**（四组同时跑 15 分钟，每分钟取最小值拟合，丢前 2 分钟；`.build/soak/leakhunt/<组>/stats.jsonl`）：

| 组 | 负载 | 斜率 |
|---|---|---|
| base | G4 的 9 路输入 + 多画面 + 录制 | 1.4 MB/h（810 MB 平） |
| streams | base + 2 路推流（本地 MediaMTX） | 平（822 MB） |
| ndi | base + NDI 发送 | 3.9 MB/h（834–835 MB） |
| **file** | base + 11 号文件（30 s ProRes 循环） | **40.7 MB/h**（875 → 883，起伏大） |

**分离"按圈"还是"按帧"**（三组同时跑 10 分钟，单路文件输入在 PGM 上 + 录制，`endAction = loop`；`.build/soak/leakhunt2/`）：

| 片段 | 10 分钟圈数 | 每分钟最小 footprint（MB） | 斜率 |
|---|---|---|---|
| H.264 40 Mb/s，30 s | 20 | 495 495 496 497 498 499 500 501 502 503 | **60.4 MB/h（R² 0.99）= 每圈 0.5 MB** |
| 同内容 H.264，5 分钟 | 2 | 495 495 495 495 495 496 496 496 497 497 | 约 6 MB/h |
| ProRes 422 HQ，30 s（E4 源） | 20 | 546 543 545 554 553 556 550 556 552 557 | 23–52 MB/h（起伏大） |

解出来的帧数三组一样（每小时 21.6 万），差别只在圈数 → **每重开一次 reader 留下约 0.5 MB**。8 小时里 30 s 片段循环 960 圈 ≈ 480 MB。

**猜测原因（可选）**：`decodeLoop` 每圈 `r.cancel()` 后 `asset.makeReader(from: .zero)`，每圈换一个 AVAssetReader（和一批新的 IOSurface——W2-A 报告 §5 第 6 条）。
0.5 MB 远小于一个 1080p 表面（NV12 约 3 MB），不像是有人攥着旧表面，更像每个 reader 留下的小对象（reader / track output / 解码会话的元数据、音频 FIFO 的缓冲……）。
`SurfaceTracker` 有 64 个的上限，不是它。**怎么排除渲染器**：FileInput 直接推进一个 TestKit 帧槽、不接引擎跑 20 圈，看进程 footprint；
不涨就转渲染器（按 IOSurface 建纹理的缓存，W1-C / W3-B）。

## 2. ProRes 422 HQ 片段：循环点空一拍、推帧线程晚醒

| 片段（单路，10 分钟，20 圈） | 解码没跟上（ticksStarved） | 跳过（framesRejected） | 帧槽 reused | 推帧线程晚醒 > 1 ms（lateWakes） |
|---|---|---|---|---|
| ProRes 422 HQ 30 s（约 430 Mb/s） | **29** | 29 | 27 | **1 037 998** |
| H.264 40 Mb/s 30 s（同内容） | 0 | 0 | 0 | 0 |

soak-1h（ProRes 片段，120 圈）：解码没跟上 98 拍、跳过 98、reused 98，晚醒 569 514。
`testFile_loopBoundary_noSkipNoRepeat` 用的是 H.264，所以没看到。猜测：`decodeLoop` 要等视频和音频都读到文件尾才重开 reader，视频只领先 3 帧（约 50 ms），
ProRes HQ 下"重开 + 解出新一圈第 0 帧"赶不上这 50 ms，推帧线程在循环点空一拍（重复上一圈末帧），下一拍两帧都到、第 0 帧被跳过。
晚醒的次数（每秒上千次）说明推帧线程在这种片段上一直在"醒得晚"的状态里转，值得一起看。

## 复现

```bash
swift build -c release --package-path Tools/switcher-headless
H="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
scripts/perf/make-e4-clip.sh                                  # .build/perf/e4/e4-source.mov（ProRes 422 HQ，30 s）
$H make-show --preset perf-e4 --file .build/perf/e4/e4-source.mov --out /tmp/f.json
python3 -c "import json; p='/tmp/f.json'; s=json.load(open(p)); s['inputs'][0]['source']['file']['endAction']='loop'; json.dump(s, open(p,'w'))"
$H run --show /tmp/f.json --duration 600 --stats /tmp/f.jsonl --record /tmp/f.mov --audio-device null
# 看 /tmp/f.jsonl 的 rss_mb 每分钟最小值；headless 结束时打印的"输入 1（file）"一行有 解码没跟上 / 跳过 / 晚醒
```
H.264 对照片段：`ffmpeg -i .build/perf/e4/e4-source.mov -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p -c:a aac clip30.mov`。
