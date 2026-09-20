# scenarios/ —— 场景脚本与节目文件

switcher-headless 用 `--show <节目文件>` 装配输入 / 混音 / 输出，用 `--script <场景>` 按 tick 发命令。
场景格式是 SwitcherContracts 里的 `Scenario`（P1 定义）：`{ durationTicks, events: [ { tick, command } ] }`，
command 的 JSON 形状与 `Command` 枚举的 Codable 一致（例如 `{"cut":{}}`、`{"fade":{"durationTicks":30}}`、`{"setPreview":{"input":3}}`）。
节目文件是 `Show`（schemaVersion 1）。

## 现有文件（G2 起）

| 文件 | 生成命令 | 内容 |
|---|---|---|
| `m0-show.json` | `switcher-headless make-show --out scenarios/m0-show.json` | M0 标准负载：1080p60，8 路合成源（1、2 号 30 fps，3、4 号 59.94，5–8 号 60；5 号 +100 ppm、6 号 −100 ppm 时钟漂移，7 号 ±3 ms 抖动；1 号带合成音频 click），PGM 1 / PVW 2，默认转场 Fade 30 拍，一路录制输出（H.264 6 Mbps + AAC） |
| `m0.json` | `switcher-headless make-scenario --out scenarios/m0.json`（默认 60 分钟） | 每 30 s 切一次（第 k 次在第 k × 1800 拍）：k 是 10 的倍数（每 5 分钟）用 Fade 30 拍，其余 Cut；切完 1 拍（Fade 后 31 拍）把 PVW 推到下一路，PGM 按 1 → 2 → … → 8 → 1 循环。`--duration 600` 只跑前 10 分钟（19 次 Cut + 5:00 处 1 次 Fade） |

两个文件都是工具生成后入库的；改了生成逻辑（Tools/switcher-headless/Sources/switcher-headless/Factories.swift）要重新生成并在对应检查点报告里说明，否则基线不可比。
## G3 起

| 文件 | 生成命令 | 内容 |
|---|---|---|
| `g3-show.json` | `switcher-headless make-show --preset g3 --out scenarios/g3-show.json` | 1080p60，8 路合成源：1 号 30 fps 灰 64 +音频（进 Master）、2 号 60 灰 192 +音频（+100 ppm，只进 ISO）、3 / 4 号 59.94 灰 96 / 128 +音频（−100 / +50 ppm，只进 ISO）、5 号 +100 ppm、6 号 −100 ppm、7 号 ±3 ms、8 号 60；Overlay 1 = 8 号右下角 28% 画中画；一路录制 |
| `g3.json` | `switcher-headless make-scenario --preset g3 --minutes 10 --out scenarios/g3.json` | 第 1000 拍 Cut（V6）、第 3000 拍 Fade 30（V7）、3600 / 3660 / 3720 拍 T-bar 25 / 50 / 75%（各 60 拍）、3780 拍提交；120 s 起每 5 s Cut（PVW 跟着推到下一路）；122.5 s 起每 30 s 开关 Overlay 1。C 系列客户端从 150 s 起插自己的 cut |

生成逻辑在 `Tools/switcher-headless/Sources/switcher-headless/Factories.swift` 的 `G3Factory`。之后 G4 / W4-A 各加自己的场景。

**G4 起 `g3-show.json` 的八路底纹换成灰底 + 噪声 ±24**（`background: {"noise": {"level": 原灰度, "amplitude": 24, "seed": 输入号}}`，提案 006 / W1-A2 落地，
G3 交接第 2 条）：纯灰底压不出设定码率，E2 在长跑里没有可判对象。名义灰度不变（V6 / V7 的中心均值 ≈ level），但 GPU / CPU 占用比灰底高，
**与 `baselines/g3-m5max.json` 的 S3 不可比**；M0 / G2 的文件保留灰底。

## G4 起

| 文件 | 生成命令 | 内容 |
|---|---|---|
| `g4-show.json` + `g4-stinger.png` | `switcher-headless make-show --preset g4 --out scenarios/g4-show.json`（PNG 写在同目录） | 1080p60；1–8 号同 g3（噪声底纹），**5–8 号开抠像**（契约 `keyer`，默认绿键色：灰噪声上画面不变，只付着色器代价；真绿幕在 docs/checklists/G4.md 人工看）；**9 号图片输入** = 带 alpha 的 Stinger PNG（路径相对节目文件；图形只在下 20% 和左右两侧，不碰测试图案 / 闪光块 / 中心采样区）；**Overlay 1–4** = 5 / 6 / 7 / 8 号，位置左下 / 右下 / 左中 / 右中，动画 fade 15 / slide 20 / zoom 20 / cut；转场参数 Wipe 左→右软边 0.1、Stinger 9 号第 12 拍换底；输出 = 录制 + **多画面自定义布局**（`extra["layout"]`：PGM / PVW 上半 + 8 路 4×2，safeArea + meters，提案 010 过渡口径） |
| `g4.json` | `switcher-headless make-scenario --preset g4 --minutes 10 --out scenarios/g4.json` | 前 2 分钟同 g3（1000 Cut、3000 Fade 30、3600–3780 T-bar）；**120 s 起每 5 s 一次转场按 Cut → Fade → Wipe → Zoom → Stinger 轮流**（非 Cut 24 拍 = 0.4 s：`setTransition` 在 t − 1、`autoTransition` 在 t，切完 d + 1 拍推 PVW）；**122.5 s 起每 15 s 翻一路叠加**（1 → 2 → 3 → 4 循环）。C 系列客户端从 150 s 起在 x.7 s 相位插 cut（gate4.sh `--c1-phase 0.7`）。gate4.sh 把每次非 Cut 转场的 [t + 1, t + d] 拍交给 `frameprobe --blank-ticks`（合成帧没有单一输入身份） |
| `g4-ndi-show.json` | `switcher-headless make-show --preset g4-ndi --out scenarios/g4-ndi-show.json [--ndi-name "Switcher G4 loop"]` | NDI 回环 L1（scripts/gate4-ndi.sh）：1 号 60 fps 噪声 +音频 作 PGM，2 号 `ndi(sourceName:)` = headless `--ndi-send` 的发送端名（不含 "(" 时按本机发现列表的后缀解析），放 PVW |

生成逻辑在 `Tools/switcher-headless/Sources/switcher-headless/G4Factory.swift`。
