# baselines/ —— 性能基线

每个检查点固定产出 `baselines/<检查点小写>-<机器>.json`，例如 `m0-m5max.json`（G2）、`g3-m5max.json`。
内容：该检查点报告里的关键数字（V1 avg / p99、V3 p99、CPU、GPU、RSS 等），供下一个检查点算"与上一版本的差"，供 W4-A 的 L5 判"无退步"。

字段名与 stats.jsonl（测试标准 §7）一致，不另起名字。字段结构由 W1-A 的 StatsSummary 定，G2 第一次落文件。
这台开发机（M5 Max）远强于目标机（M1 Air 8 GB）：这里的基线只用于本机回归比较，发布前 L5 要在 Air 上另跑一份 `*-m1air.json`。
