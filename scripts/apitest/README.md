# scripts/apitest —— C 系列（控制接口）测试客户端

- `apitest.py`：只用 Python 3 标准库的客户端（自带 RFC 6455 文本帧实现；时间戳用 ctypes 调 `mach_absolute_time`，与服务端 host time 同一个钟）。
  子命令：`run`（连 WS 记录快照 / stats，按计划发 C1 的 cut 与 C4 的带序号命令）、`evaluate`（对着 frameprobe 的逐帧输出算 C1–C4，出 Markdown）、`scenario`（生成每 5 s 切一次的场景）。
- `run-c-tests.sh`：一键：编 release → make-show → 场景 → headless `--api --record --stats` → 客户端 → frameprobe → 评估。产物在 `.build/apitest/<label>/`（不入库）。

口径（测试标准 §1 C1–C4、§3 对应行）：
- C1：客户端记下发 cut 的 host time，画面上新 PGM 输入 ID 首次出现的那一帧的拍点时刻减它；≤ 1 拍 + 该次 RTT。50 次。
- C2：每条快照 `收到时刻 − 该快照生效拍的拍点时刻` 的 p99 ≤ 50 ms（目标 20）；另报 `收到时刻 − 服务端序列化时刻`（纯传输）。
- C3：录制文件每一帧解出的输入 ID 必须属于 API 在该拍 tally.program == true 的输入集合（转场中 PGM 与 PVW 都算）；0 不一致。能用相邻一拍解释的单独计数。
- C4：每客户端每秒 100 条 `renameInput(input: i, name: "c<i>-<k>")` 持续 60 s，两客户端并发：每条有回执、sequence 与 k 同序、合并后无空洞、最终状态名字 = 最后一条、WS 快照 sequence 不倒退。
