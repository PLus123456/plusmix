# W4-A → W1-A：frameprobe av 的内存随录像帧数线性涨（约 210 KB / 帧），1 小时录像 41 GB，8 小时的 A3 分析不下来

归属会话 / 分支：W1-A 测试工装（`Packages/SwitcherTestKit/`、`Tools/frameprobe/`）
发现于：W4-A（`w4-soak`，2026-09-27），`make soak-1h` 跑完分析录像时；场景 `.build/soak/1h/soak-show.json`（headless `--preset soak`），提交 af2414f 起的 headless
严重级：S2（有绕过：W4-A 的 soak 已改成按 5 分钟切段逐段跑再合并；但任何对长录像直接跑 frameprobe 的人都会撞上，8 GB 的机器上 10 分钟录像就要 7.6 GB）

## 现象

`frameprobe av <录像> --fps 60 --discontinuities`（release 编译），同一套 1080p60 H.264 6 Mb/s + AAC 录像：

| 录像 | 帧数 | 峰值 RSS（`/usr/bin/time -l` 的 maximum resident） | 耗时 |
|---|---|---|---|
| 1 分钟（`.build/perf/smoke/perf.mov`） | 3 600 | 0.73 GB | 4.5 s |
| 10 分钟（1 小时录像切出的 6 段，每段） | 36 000 | **7.59 GB** | 44–53 s |
| 1 小时（`.build/soak/1h/soak.mov`） | 216 000 | **约 41 GB**（ps 每 20 s 采一次，12 分钟里从 23 GB 单调涨到 41 GB） | 约 12.5 min |

≈ 210 KB / 帧，和时长成正比；8 小时（172.8 万帧）约 360 GB，本机 128 GB 跑不下来。整条音轨读成单声道 float 只占 1 小时 0.7 GB，不是主因。

## 猜测原因

`MediaReader.readVideo` 的循环（`while let sb = output.copyNextSampleBuffer() { … }`）在一个 async 函数里跑满整条文件、中间没有 `autoreleasepool {}`：
AVFoundation / CoreVideo 在取样本、映射 BGRA 像素缓冲时产生的自动释放对象要等函数返回才释放（每帧 1920×1080×4 ≈ 8 MB 的 BGRA 缓冲本身大概率是池里复用的，
但每帧还有 CMSampleBuffer / 附件字典 / IOSurface 映射之类的小对象）。`readAudio` 同样的循环。建议：循环体包 `autoreleasepool`，
再量一次 10 分钟录像的峰值（预期应与帧数无关、几百 MB）。`frames` / `readings` 两个数组每帧几十到一两百字节，不是这个量级。

## 复现

```bash
swift build -c release --package-path Tools/frameprobe
/usr/bin/time -l "$(swift build -c release --package-path Tools/frameprobe --show-bin-path)/frameprobe" av <任意 10 分钟以上的录像> --fps 60 --discontinuities --out /tmp/p.json
```

## W4-A 这边的绕行（修好之后可以撤）

`scripts/soak/soak.sh` 第 6 步：`ffmpeg -c copy -avoid_negative_ts disabled -f segment -segment_time 300` 切成 5 分钟一段（第一段必须关 `avoid_negative_ts`，
否则两条轨一起挪 +44 ms、AAC priming 的编辑列表没了，这一段的闪光全被判成非整秒），每段 `frameprobe av --start-tick <段起点 × 60>`，
`scripts/soak/soakjudge.py` 的 `combine_segment_probes` 把各段的整秒配对放回整条时间轴拟合。1 小时录像上验证：6 段整秒配对 1820 对（整条 1823），
偏移全 0.000 ms、不连续 0，与整条分析一致。
