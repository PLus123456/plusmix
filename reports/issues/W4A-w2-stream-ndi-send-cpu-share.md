# W4-A → W2-D：标准负载下 NDI SDK 的发送线程占掉 S3 CPU 预算的四成（`ndis:async` 18.9% + `ndis:lowQ` 6.2%，占一个核的 %）；8 小时 S3 CPU 60.1% 超 60% 的线

归属会话 / 分支：W2-D 推流与 NDI 发送（`Packages/SwitcherOutputs/Sources/NDISend/`）；阈值 / 标准负载定义归用户（见末尾"等用户定"）
发现于：W4-A（`w4-soak`，2026-09-28），`make soak`（8 小时，`reports/W4-soak-8h.md`）与带线程采样的 8 分钟对照（`.build/soak/tcpu/threads.log`）
严重级：S1 的形式（L4 的 S3 是发布门槛，8 小时 CPU 均值 60.1% > 60%），但超线只有 0.1 pt、且最大的一块在 SDK 里。
**用户 2026-09-28 定：负载很低，单核 60% 不足为惧，S3 这项意义不大**——不阻塞；但要探查"为什么不分到多核"，见 `reports/issues/W4A-g5-cpu-multicore-distribution.md`（到检查点再安排）。

## 数字

8 小时（`.build/soak/8h/`，负载 = §3 S1 + 摄像头 + 文件）：CPU avg **60.1%** / p95 62.7% / max 74.9%（进程级，100 = 一个核；逐小时 59.0 → 61.4）；
1 小时那次（没接摄像头）54.9%；8 分钟带线程采样的对照（同负载、没摄像头、没 powermetrics）53.2%。

按线程（`scripts/soak/thread-cpu.swift`：proc_pidinfo 的每线程 user + system 时间，首尾快照 7 分钟；`reports` 的 tcpu 报告 §5，各线程之和 49.2%，
与 Stats 的 cpu_pct 差的 4 pt 是第一分钟和已退出的短命线程）：

| 线程（组） | 占一个核 % | 谁的 |
|---|---|---|
| `ndis:async` | **18.9** | NDI SDK 的发送线程（`NDIlib_send_send_video_async_v2` 之后的压缩 / 发送） |
| `ndis:lowQ` | **6.2** | NDI SDK 给低带宽接收方准备的第二路小码流 |
| 无名线程 × 11 | 13.0 | VideoToolbox / AVFoundation / HaishinKit 的 GCD 工作线程、NDI SDK 其余线程（认不出名字） |
| `com.apple.coremedia.mediaprocessor.audiocompression` | 1.3 | AAC 编码（录制 + 2 路推流 + NDI 音频） |
| `switcher.stream.audio.stream1` / `stream2` | 1.2 + 1.2 | 推流音频打包 |
| `switcher.ndisend.Switcher soak` | 1.0 | 我们自己的 NV12 → UYVY 转换 + 交给 SDK（auto 选了 CPU：每帧 0.10 ms） |
| `file-decode-11` / `file-pace-11` | 0.7 + 0.3 | 文件输入 |
| `switcher.program-clock` / `audio-pump` / `audio-control` | 0.7 + 0.5 + 0.4 | 引擎时钟、音频 |
| `switcher.encoder.*` × 3、`formatwriter.qtmovie` | 0.4 × 3 + 0.5 | 编码器交帧、录制封装（编码本身在媒体引擎） |
| `synthetic-video-*` × 8 | 0.2 × 8 | 合成源 |

也就是说：**NDI SDK 自己的两个线程 ≈ 25 pt，我们的 NDI 发送线程 1 pt**；15 分钟分组对照（`.build/soak/leakhunt/`）里"加 NDI 发送"这一项 +21.4 pt，同一个量级。
GPU 那边不是原因：8 小时里 GPU 频率一直在最低档 338 MHz（powermetrics dvfm_states 只有 338 MHz 一档有占用），1080p60 合成对这块 GPU 太轻。

## 请 W2-D 看的

1. SDK 侧有没有更省的发送方式：现在送的是 UYVY（SDK 的原生格式，转换只花 1 pt，这一步没问题）；`ndis:lowQ` 那 6 pt 是 SDK 给"低带宽接收"模式生成的第二路，
   查一下 NDI 6 的 `NDIlib_send_create_v2` / 发送参数里能不能关掉或降频它（没有接收方连着的时候 SDK 是否仍然一直压两路——8 小时里 `connections = 0`）。
2. 如果 SDK 没有开关，把结论写进报告：标准负载下 NDI 发送在 M5 Max 上的固定成本 ≈ 25 pt / 核，这是 S3 阈值和标准负载定义要一起看的事（下面"等用户定"）。
3. 顺带一条同归属的小问题：两路推流每次开始都丢前 46–47 个音频包（约 1 s；1 小时那次 46、8 小时 47，都在 RTMP 握手完成前），视频一帧不丢。
   8 小时 headless 摘要：`音频包 1350014 / 丢 47`。推流的头一秒有画没声；不进 E1（E1 只数视频），报告里只作信息项。

## 等用户定（阈值只有用户能改，W4-A 不动）

- §4 S3 "CPU 平均 ≤ 60%" 按 §7 的口径是一个核的 60%；§3 S1 的标准负载（2 路推流 + 录制 + NDI 全程开）里 NDI SDK 固定占约 25 pt，摄像头再加约 5–7 pt。
  三个选项：(a) 阈值不动，等 W2-D 看 SDK 有没有省的办法，没有就按 §4 末尾"有充分理由并写入已知问题时可以个案放行一次"处理；
  (b) 把 NDI 发送从 S3 的标准负载里拆出来单独记（S3 分"不含 NDI / 含 NDI"两行）；(c) 改阈值。W4-A 建议 (a) + 把这份按线程的表存进基线，退步看 `ndis:*` 之外的那部分。
- 8 小时 CPU 逐小时 +0.37 pt：先等 W2-A 修完文件输入的泄漏（W4A-w2-inputs-file-loop-memory-and-prores-starve §3）再看还爬不爬。
