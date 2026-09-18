归属会话 / 分支：W1-A / w1-testkit（Tools/frameprobe、SwitcherTestKit.FrameProbe 的 `av` 子命令）
发现于：W2-D（w2-stream），StreamingTests.MediaMTXTests.testRTMP_endToEnd_10s_framesContinuousAndAVAligned，main 2290b4e
现象：对 MediaMTX 落盘的推流文件（fMP4，AAC 无 priming 信息、音轨 start_time ≠ 0）`frameprobe av` 报 +64.0 ms（音频超前），
      而 ffmpeg 口径（`ffmpeg -af aresample=first_pts=0` 解 PCM 找 click，闪光帧用 `frameprobe frames` 的 ptsSeconds）是 0.0 ms。
      差的 64 ms = 2112 样本（44.0 ms，AVFoundation 按 AAC-LC 标准 priming 裁掉解码输出的头）+ 20 ms（音轨 start_time，没有补进时间轴）。
      同一份合成信号经 W1-E 录制路径（AVAssetWriter 写了 priming / 编辑列表）时 `av` 是对的，所以是"没有 priming 信息的容器"这一类输入的问题。
复现步骤：`swift test --package-path Packages/SwitcherOutputs --filter MediaMTXTests/testRTMP_endToEnd`（需要 brew 的 mediamtx、ffmpeg 和编好的 frameprobe），
      看打印的 "frameprobe av（AVFoundation 口径）" 与 "A/V（ffmpeg 口径）"；文件在 $TMPDIR/switcher-streaming-tests/rtmp-e2e/mtx1/s1/。
严重级：S2（E8 "重连后 A2 仍达标" 和 G3 的推流 A2 判定会误判 44–64 ms；推流本身是对的）。
建议：
1. `av` 的音频时间轴加上音轨 start_time（`AVAssetTrack` 的 timeRange.start 或 fMP4 的 tfdt），不要假设第一个样本在 0。
2. 加选项 `--aac-priming auto|0|N`：容器没有编辑列表 / priming 时按 ffmpeg 口径（不裁）计算，或把裁掉的 N 样本加回时间轴；默认 auto = 有编辑列表就信 AVFoundation，没有就不裁。
3. 报告里注明两种口径：RTMP / SRT 的行业约定是"第 k 个包的时间戳 = 非裁剪解码器输出的时刻"（ffmpeg 系），W2-D 按这个约定送包。
