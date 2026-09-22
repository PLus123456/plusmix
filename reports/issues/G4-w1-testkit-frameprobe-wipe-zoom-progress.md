# frameprobe 没有 Wipe / Zoom / Stinger 的转场进度量法，也判不出转场合成帧的输入身份

归属会话 / 分支：W1-A（w1-testkit；frameprobe 与 FrameAnalysis 在 Packages/SwitcherTestKit/Sources/SwitcherTestKit/Probe/）
发现于：G4 检查点合并 W3-B 后设计 g4 场景时（2026-09-20）；W3-B 报告 §3 第 4 条已经点名

## 现象

1. `frameprobe fade` 只会量 Fade（中心灰度按线性曲线混合）。Wipe 的中心灰度在擦边过中心时翻转、Zoom 的中心灰度是新画面的中心，
   两者的进度都不能从中心灰度反推；V7 对 Wipe / Zoom 的"曲线误差 ≤ 1 帧"目前只有 W3-B 在渲染侧的单元测试（整幅覆盖率 / 边位置 / 中心行宽度）在判，
   headless 场景（L2）里量不了。
2. 转场合成帧（Wipe / Zoom / Stinger 期间、Fade 的中间段）的图案解码不可靠：
   - 帧号行是 32 个块的 28 位 + CRC-4 码字。Wipe 时擦边扫过帧号行，一部分块来自新画面、一部分来自旧画面，拼出来的码字有 1/16 的概率 CRC 合法
     → 一个既不是新也不是旧的帧号，`stats` 会记成 drop gap 或帧号倒退（V4 判据之一）。
   - Wipe / Zoom 时帧号行与 ID 块在不同的拍翻转（例如 topToBottom：帧号行在第 1 拍换成新画面、ID 块在第 3 拍才换），中间那几帧是"旧 ID + 新帧号"，
     同样被算成 drop / 倒退。
   - Fade / 软边 Wipe 的 ID 块是两种调色板颜色的混合：混合点离第三种颜色 < 24（半个最小调色板距离）时会被解成第三路 → C3 的严格不一致（硬性）。
   G4 的冒烟录像（Stinger / Wipe / Zoom / Fade 各一次，10 s）里 `switches` 把 Wipe / Zoom 判成 1 帧中间帧的 "transition"、Stinger 判成 "cut"
   （PNG 没盖住 ID 块，换底那一拍看起来就是 Cut），没撞上倒退；10 分钟 76 次转场里撞上是迟早的事。

## G4 的处理（工装侧，不是修法）

`frameprobe --blank-ticks a-b,…`（FrameProbe.Options.blankTicks，G4 在 TestKit 里加的 16 行胶水）：把给定拍的帧当作解不出（帧号 / ID / 时间戳置 nil、闪光置 false）。
gate4.sh 从场景文件算出每次非 Cut 转场的 [t + 1, t + d]（第 t 拍是 progress 0 的纯旧画面，也是整秒闪光帧，保留），stats / switches / frames / av 都带上。
V5 总帧数不受影响；V4 的引擎侧计数（stats.jsonl per_input dup / drop）全程照算，只是 frameprobe 在播段那一口径不统计合成帧。

## 建议（给 W1-A / W1-A3）

1. 让 frameprobe 自己认出合成帧而不是靠外部给拍段：帧号行、时间戳行、ID 块三样解码结果互相印证（帧号与时间戳来自同一输入才可信；
   任一 CRC 失败或 ID 距离 > 阈值就整帧判 nil），Wipe 的"半新半旧"码字大多会被时间戳行的不一致抓住。
2. Wipe 的进度：按方向在垂直于擦边的方向上找灰度阶跃的位置（软边取 50% 点），进度 = 位置 / 画面尺寸；Zoom 的进度：中心行上新画面（灰度 B）的宽度 / 画面宽。
   两者都用 A = 64、B = 192 两路，与 Fade 同一套 --gray-a / --gray-b。gate 侧再把 g4 场景里的 Wipe / Zoom 拍段交给它判 V7。
3. Stinger：静态 PNG 的 Stinger = "第 cutAtTick 拍的 Cut"，`switches` 已能判干净；动画 stinger（文件输入）落地后再看。
