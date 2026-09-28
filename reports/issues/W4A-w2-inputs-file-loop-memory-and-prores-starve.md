# W4-A → W2-A：文件输入循环播放时每圈涨约 0.5 MB（30 s 片段 = 60 MB/h，8 小时 S2 实测 60.8 MB/h 红；根因见 §3：解码线程没有自动释放池，每圈的 AVAssetReader 永远不释放）；ProRes 422 HQ 片段循环点每圈空一拍、推帧线程大量晚醒

**用户 2026-09-28 定：S2 必须修**（"S2 肯定要修"），到检查点安排；修法与验证在 §3 末尾。

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

## 3. 定位结果（2026-09-28，8 小时跑完之后补；结论：FileInput 解码线程没有自动释放池，每圈的 AVAssetReader 永远不释放）

**8 小时确认**（`reports/W4-soak-8h.md`，`.build/soak/8h/`）：S2 = **60.82 MB/h**（预热 30 min 后逐分钟 451 点、拟合 7.5 h，R² 0.955；footprint 995 → 1617 MB），
ps 的 resident 同步涨 62.23 MB/h；文件输入循环 960 圈 → **每圈 0.5 MB**，与 §1 的对照实验一致。判定 ❌（≤ 10 MB/h）。

**按圈，且主要是音频那一路**（5 s 的 H.264 片段，10 分钟 120 圈，每分钟最小 footprint 拟合；`.build/soak/leakhunt3/`）：

| headless 全引擎（单路文件在 PGM 上） | 斜率 | 每圈 |
|---|---|---|
| 5 s A+V | 333.6 MB/h（R² 1.00） | 0.463 MB |
| 5 s A+V + 录制 | 334.4 MB/h | 0.464 MB（录制无关） |
| 5 s 只视频 | 51.5 MB/h（R² 1.00） | 0.071 MB |

**排除渲染器**（`scripts/soak/fileprobe/`：只起 FileInput，LockFreeFrameSlot(3) + CAudioRing(2)，不接引擎 / 渲染器 / 音频引擎；`.build/soak/fileprobe/*.log`，各 120 圈）：

| 变体 | footprint 30 s → 600 s | 每圈 |
|---|---|---|
| A+V 片段，有音频环，另起线程每拍取帧、读空音频环 | 22.7 → 93.5 MB | 0.62 MB |
| A+V 片段，有音频环，没人取帧 / 读环 | 20.9 → 87.5 MB | 0.58 MB |
| A+V 片段，`audioRing = nil`（FileReader 不建音频 track output） | 38.6 → 34.0 MB | **0** |
| 只视频片段 | 15.0 → 27.4 MB | 0.11 MB |

`stop()` 之后 footprint 掉回（93.5 → 51.8 MB）：泄漏的对象在**线程退出时**才释放——这就是自动释放池的行为（TLS 析构时清 pool 页）。

**机制（运行时直接抓到）**：`OBJC_DEBUG_MISSING_POOLS=YES` 跑 fileprobe 45 s（8 圈，A+V）：**10174 条** `Object … of class X autoreleased with no pool in place - just leaking`，
其中 `NSKVONotifying_AVAssetReaderTrackOutput` 5452、`AVAssetReader` 3085，其余是 `__NSSetI` / `__NSCFString` / `NSKeyValueObservance` / `AVCMNotificationDispatcherListenerKey` 等
（只视频片段 30 s：4198 条，同样两个类为主；`.build/soak/fileprobe/missing-pools-*.log`）。
`decodeLoop` 跑在 `InputThread`（`Common/InputThread.swift`，裸 `pthread_create`）上，线程上从来没有 push 过自动释放池；`copyNextSampleBuffer()` 每调一次，
AVFoundation 内部都会 autorelease 一次 reader / track output（KVO 代理），这些引用永远不 release → **每圈的 AVAssetReader 和两个 track output 连同内部解码器状态永远活着**。
音频 track output（AAC → LPCM 的转换器）内部大约 0.5 MB / 个，视频那个约 0.07–0.1 MB，所以"有音轨才明显"、"只视频也在涨"。`SurfaceTracker`、`DecodedAudioFIFO`、帧槽都不是（上面的变体已排除）。

**建议修法**：`decodeLoop` / `paceLoop` 的每次迭代包在 `autoreleasepool { }` 里（或者 `InputThread` 提供"按迭代排水"的入口，所有在 InputThread 上碰 AVFoundation / CoreMedia
对象的输入统一受益——`CameraInput` 若也在自己的 InputThread 上调 AVFoundation，请一并查）。修完的**验证**：

```bash
swift build -c release --package-path scripts/soak/fileprobe
H="$(swift build -c release --package-path Tools/switcher-headless --show-bin-path)/switcher-headless"
ffmpeg -i .build/perf/e4/e4-source.mov -t 5 -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p -c:a aac /tmp/clip5.mov
$H make-show --preset perf-e4 --file /tmp/clip5.mov --out /tmp/f.json
python3 -c "import json; p='/tmp/f.json'; s=json.load(open(p)); s['inputs'][0]['source']['file']['endAction']='loop'; json.dump(s, open(p,'w'))"
OBJC_DEBUG_MISSING_POOLS=YES scripts/soak/fileprobe/.build/release/fileprobe /tmp/f.json 60 --consume 2>&1 | grep -c "no pool in place"   # 应为 0
scripts/soak/fileprobe/.build/release/fileprobe /tmp/f.json 600 --consume    # 120 圈，footprint 应平（现在 +70 MB）
```
之后 `make soak-1h` 的 S2 参考值应 ≤ 10 MB/h（现在 108.9，8 小时 60.8）。

**顺带（8 小时数据）**：第 2 条的 ProRes 循环点空拍 8 小时里 765 / 960 圈，推帧线程晚醒 1142 万次（每秒 397 次；1 小时那次每秒 158 次，随时间变多）；
进程 CPU 均值逐小时 59.0 → 61.4%（+0.37 pt/h）——修完泄漏后看这两条是否还随时间变差。
