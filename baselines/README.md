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
