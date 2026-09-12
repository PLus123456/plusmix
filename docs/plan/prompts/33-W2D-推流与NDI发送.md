## 33 W2-D 推流与 NDI 发送（SwitcherOutputs 二期）
分支：w2-stream。只准动：Packages/SwitcherOutputs/Sources/{Streaming,NDISend}/ 及对应 Tests、scripts/netem.sh、scripts/mediamtx.yml。
先读：设计方案 §8 推流 / NDI 发送两行、§3.4；测试标准 §1 E7–E9、§2.6、§3 对应行。

第一步（最多半天，先出结论再写代码）：HaishinKit 接哪一层。读 HaishinKit 当前版本源码，验证 RTMPStream / SRTStream 能否直接接收已编码的 H.264 / HEVC CMSampleBuffer + AAC（不让它自己再编码）。写一个 50 行探针推到本地 MediaMTX 看能不能播。结论写进 reports/w2-stream.md 第一节，三选一：
  a) 能 → 用它的连接 + 封装层，我们的编码器输出直接送；
  b) 不能但协议层可单独用 → 自己封 FLV / MPEG-TS，只借它的连接；
  c) 都不行 → FFmpeg libavformat（LGPL、动态链接 brew 的 ffmpeg 动态库）做封装 + 协议，写清许可证处理。
  不许选"让 HaishinKit 自己编码"：那样两份编码器，PTS 也不是拍点时刻。

交付：
1. StreamOutput（每个目的地一个实例）：RTMP / RTMPS / SRT；接编码后的样本（编码器实例按目的地设置各自一个，共享同一块 NV12 IOSurface）；独立线程和有界发送队列；断线指数退避重连（1、2、4 … 最长 30 s，可配），重连后关键帧起步；每路统计：帧数、网络丢帧（E9 口径：因发送队列满或连接断而未送出的帧）、码率、重连次数 → Stats.encoder[i]。
2. 多目的地互不影响：一路阻塞不占别人的锁、不共享队列。
3. NDISend（#if canImport(NDI)；SDK 不在时编译成空实现并在 Stats 里标 unavailable）：PGM 必送，任一输入可选；异步发送；NV12 → UYVY 转换用 GPU kernel（没有就 CPU，写清成本）；音频一起。
4. scripts/netem.sh：用 dnctl + pfctl 对指定端口做断网 / 限速 / 丢包 / 延迟，需要 sudo，脚本写好我来跑。
5. scripts/mediamtx.yml：三个 RTMP 路径 + SRT，录制成 fMP4 供 ffprobe / frameprobe。

测试（本地 MediaMTX；netem 的 sudo 部分我手动跑，你给一键脚本 + 判定脚本）：
- E7：3 路推流，封第 2 路 30 秒，第 1、3 路丢帧 = 0（硬性）。
- E8：放开后第 2 路自动重连 10 / 10 成功，耗时 ≤ 15 s（目标 5）；重连后录 30 秒交 frameprobe 验证帧号连续（A2 等 W2-E 合并后在 G3 补）。
- E9：带宽限到码率 70% 跑 5 分钟，软件报告的网络丢帧与 MediaMTX 落盘缺帧数误差 ≤ 5%。
- E2 / E3 在 MediaMTX 落盘文件上复跑（推流路径的码率遵从）。
- NDI：SDK 在的话，NDI Tools 的 Studio Monitor 能看到 PGM 且帧号在走；回环 L1 等 W3-A 收端做好后做。

报告里写：第一步结论和证据；重连状态机图；每路队列深度与延迟的取舍。
