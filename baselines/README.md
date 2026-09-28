# baselines/ —— 性能基线

每个检查点固定产出 `baselines/<检查点小写>-<机器>.json`，例如 `m0-m5max.json`（G2）、`g3-m5max.json`。
内容：该检查点报告里的关键数字（V1 avg / p99、V3 p99、CPU、GPU、RSS 等），供下一个检查点算"与上一版本的差"，供 W4-A 的 L5 判"无退步"。

字段名与 stats.jsonl（测试标准 §7）一致，不另起名字。字段结构由 W1-A 的 StatsSummary 定，G2 第一次落文件。
这台开发机（M5 Max）远强于目标机（M1 Air 8 GB）：这里的基线只用于本机回归比较，发布前 L5 要在 Air 上另跑一份 `*-m1air.json`。

## 各检查点的基线

| 文件 | 检查点 | 场景 | 与上一版本可比吗 |
|---|---|---|---|
| `m0-m5max.json` | G2 | scenarios/m0-show.json（8 路纯灰底合成源） | — |
| `g3-m5max.json` | G3 | scenarios/g3-show.json（当时还是灰底；Overlay 1 关着，多画面默认布局） | 与 m0 同负载口径，V1 可比 |
| `g4-m5max.json` | G4 | scenarios/g4-show.json（噪声底纹 ±24、5–8 号抠像、Overlay 1–4 轮流开、多画面自定义布局、五种转场） | **与 g3 不可比**：底纹和负载都变了（G3 交接第 2 条、W3-B 报告 §5 第 1 条）。W4-A 的 L5"无退步"从 g4 起算 |
| `perf-m5max-macos27.json` | W4-A L5（`make perf-baseline`） | scenarios/g4-show.json + g4.json 的前 5 分钟（`--record --iso-audio 4`，不起 API）+ E4 片段（`scripts/perf/make-e4-clip.sh`，sha256 记在 `e4.source_sha256`） | **只与同机、同 macOS 大版本比**（prompt 70 第 7 条）：g4-m5max.json 是 26.6.2 上的，只作参考列；`summary` 段与 G2–G4 同结构，另加 `perf`（V1–V3、S3 的 avg / p95）与 `e4`（VMAF / PSNR-Y / SSIM，分段） |
| `soak8h-<机器>-macos<N>.json`、`soak1h-…` | W4-A L4（`make soak` / `make soak-1h`） | headless `--preset soak`（G4 节目 + 摄像头 + 文件；录制 + 2 路推流 + NDI） | 同标签、同机、同大版本比；存 §7 报告"与上一版本的差"用的几项（V1–V3、S2 斜率、S3、A3），第一次通过时自动写，之后要 `--write-baseline` |

### W4-A 的基线规则

- 文件名：`perf-<机器>-macos<大版本>.json`，机器 = 芯片 + Air 标记（`m5max`、`m1air`，`scripts/perf/perfjudge.py` 的 `machine_tag`）。换机器、升 macOS 大版本都会开一个新文件，不和旧的判退步。
- 同系统的第一版只在标准条件下自动写（5 分钟 + E4、机器上没有别的编译 / 测试进程）；已有时只有 `--write-baseline` 才覆盖（§5：每个正式版本的 L5 结果存进仓库）。
- 退步规则在 `scripts/perf/regression.json`（默认照 prompt 70：变坏 > 10% 算退步；E4 另按 §4：VMAF 降 > 1 分）。阈值归用户（铁律 9）。

