# 2026-10-22 控制层与测试、发布工具审查

基准 main `1f9be64`；审查树 `/Users/plus/.codex/worktrees/bug-audit-20261022/plusmix`，分支 `codex/bug-audit-20261022`。本分项使用 Swift 6.4 / Xcode 默认工具链；中文交流。未修业务、未修改公共契约、未提交。

## 1. 做了什么

审查 `Packages/SwitcherControl` 的命令入口、HTTP / WebSocket、MIDI、兼容层、Tally，`Packages/SwitcherTestKit` 的分析与场景执行，headless 接线、Stream Deck、长稳与发布脚本。先读 CLAUDE、通用前言、KNOWN_ISSUES、2026-10-13 审查；对可疑工装行为追到 G9 / prompt 121 的后续裁定，排除了两条貌似缺陷的既定行为。

### CT01 · P2：新 WebSocket 订阅会先收到新状态，随后被旧状态覆盖

位置：`Packages/SwitcherControl/Sources/SwitcherControl/API/StateFeed.swift:123` 与 `:162–167`。

`loop()` 在订阅表锁外取旧快照并编码；这期间状态机可以再发布新快照，`subscribe()` 从 publisher 读取新快照、补发并把订阅者加入表。旧编码随后 `fanOut` 会向刚加入的订阅者发送旧快照。订阅表锁仅防漏，不保证版本单调。

**真实类受控交错复现**：令第 1 条状态变更进入推送线程，在 `clockProvider`（生产公开注入点，编码时调用）暂停该线程；第 2 条状态变更完成后订阅，再释放推送线程。收到的 snapshot sequence 为 **`[2, 1, 2]`**，单调断言失败。未改 `StateFeed` 实现、未构造替代状态机。

影响：API / Stream Deck 的新连接可能短暂显示过期 PGM / PVW / 开关状态。当前 `SwitcherClient.handle`（`Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:103`）直接替换快照，没有旧版本过滤，快照驱动的 toggle 可以在这个窗口使用过期目标值。之后新快照会再纠正，不能表述为必然永久失步。建议在订阅和扇出之间统一版本顺序，或对每个订阅保留已发送的 `(sequence, tick)` 下界；不能只按 sequence 忽略同 sequence 的动画拍更新。

证据：`Packages/SwitcherControl/Tests/SwitcherControlTests/Audit20261022ControlTests.swift` 的 `testAudit20261022_newSubscriberNeverReceivesOlderSnapshotAfterCurrent`；`.build/bug-audit-20261022/control-tools/control-probes.log`。

### CT02 · P2：重签失败可返回成功，并保留原 ad-hoc 签名

位置：`scripts/release/sign.sh:36–37`。

脚本只开 `set -uo pipefail`，没有检查重签命令退出码。默认分支的 `codesign ... | grep ... || true` 显式吞错，verbose 分支的失败也没有退出。随后 `codesign --verify --strict` 只验证磁盘上的现有签名有效，并不证明已用请求的身份、runtime 与 timestamp 参数重签。

**实测**：在隔离目录复制 `/usr/bin/true` 创建最小测试 App，先 ad-hoc 签名，再执行 `sign.sh <测试 App> --identity 'Audit20261022 definitely missing identity'`。codesign 报 `no identity found`，整个脚本仍 **退出 0**，输出 `完成：Signature=adhoc TeamIdentifier=not set`，磁盘签名也仍为 ad-hoc。

影响：对有效的已有 App 重签时，证书名错误、证书不可访问等失败可被脚本当作成功，调用方得到错误完成信号。这里只证明签名脚本的失效返回；未声称完整 archive / 公证流水线一定放行此产物，因为后面的公证或封条校验可能再次拒绝。应保留实际 codesign 退出码并立即失败，再按请求身份校验结果。

证据：`.build/bug-audit-20261022/control-tools/sign-invalid-identity.json`；可独立重跑 `python3 .build/bug-audit-20261022/control-tools/reproduce-sign.py`。测试只修改临时构造的 App。

### 交叉证据：核心巨大转场时长溢出可以从主 API 到达

此条由核心分项归档，**不重复计数**。真实 `CommandEnvelope.decode` 分别解析 `{"fade":{"durationTicks":9223372036854775807}}` 与 `{"setFTBDuration":{"ticks":9223372036854775807}}` 成功；`CommandValidator.reason` 都返回 nil。入口 `CommandValidator.swift:28–31,45–46` 只拒负值；`APIServer.swift:116–129,139` 会把解码成功的命令交给总线。回归中两个“应拒绝”断言失败，核心分项负责后续真实 reducer 崩溃复现。

## 2. 测试 ID、数值与结果

| 测试 | 期望 / 阈值 | 实测 | 判定 |
|---|---|---|---|
| Audit20261022 新订阅 snapshot | 版本单调 | `[2,1,2]` | 失败，确认 CT01 |
| Audit20261022 主 API duration 解码 | 会溢出的时长应在入口拒绝 | 两条 Int.max 命令均 decoded、rejection=nil | 两个断言失败，补核心证据 |
| Audit20261022 无效签名身份 | 非零退出 | 退出 0，旧 ad-hoc 签名保留 | 失败，确认 CT02 |
| 现有 `scripts/soak/test_*.py` | 0 失败 | 35 / 35 通过 | 通过 |
| 现有 `scripts/perf/test_*.py` | 0 失败 | 22 / 22 通过 | 通过 |
| Stream Deck `node --test Tools/streamdeck-plugin/test/` | 0 失败 | 11 / 11 通过 | 通过 |

Swift 探针共 **2 个测试、3 个失败断言**（预期行为断言，未改变生产代码、未放宽阈值）。运行命令：

```sh
swift test --package-path Packages/SwitcherControl --scratch-path .build/bug-audit-20261022/control-tools/swift-build --filter Audit20261022ControlTests
```

全仓 `make test` / `make lint` 由主审查任务统一运行，本分项未重复占用其构建目录。

## 3. 没做的和原因

没有重跑 8 小时长稳，没有真实 Stream Deck / Companion、跨机器网络设备、正式 Developer ID / 公证账户验收。没有把 CommandBus 的极高并发有界回执历史猜测升级为缺陷，没有把 headless 静态接线直接表述为 App 故障，也没有以低频模拟推断 MIDI 真实设备故障。

**排除 / 既有口径：**

- A4 两文件都有整秒闪光、全部无 click，生产 `FrameAnalysis.avMulti` 实测 `passA4=true`、`unanchoredEventCount=3`。进一步核查 `docs/plan/prompts/121-W1A6-frameprobe拍号按PTS.md:13` 与 `reports/G9.md:214`，用户 2026-10-18 明确裁定“全无 click 的事件不算缺，维持”。因此 **不是本轮新增 bug**。证据保留在 `.build/bug-audit-20261022/control-tools/frameanalysis-zero-clicks.json`，使用未改生产 `FrameAnalysis.swift` 与同字段的轻量事件承载类型编译。
- 完整 8h 构造 stats，完全无 probe；或 96/96 段 JSON 齐全但全部零配对，两种情况 `soak_report.py` 均退出 0、`overall_pass=true`、`a3.pass=null`。`reports/G9.md:55` 已记录 None 为不可判、总判定放行，现有单测也特意保证此行为。**按已记录口径，不冒充新 bug**；发布验收仍须人工确认 A3 是通过而非 null。证据 `.build/bug-audit-20261022/control-tools/{missing-probe,empty-segments}-result.json`。这些是构造数据，不否定真实历史长稳结果。
- 输入编号无上限、API / WS 推流凭据暴露、SRT 保留字符，均为既有问题，未重复计数。兼容层固定 InputPlaying / position / loop 是手册明确列出的未实现范围，未报成新 bug。

## 4. 对契约的疑问

本轮不改契约。CT01 可在实现层维持当前状态消息结构并确保顺序；CT02 可在脚本层正确传播失败。巨大时长的允许范围由核心报告提出，不能在本分项私自改变公共常量或 JSON。

长稳“不可判也返回成功”已有历史口径；如希望脚本的 `overall_pass` 直接承担正式发布门槛，需要单独统一完整 8h 与短跑 / 跳过 probe 的判定，而不是本轮擅自更改阈值。

## 5. 下个会话需要知道的坑

- 新增 Swift 探针故意保持红色，只位于独立审查树；修复时可以转为回归用例。
- StateFeed 的时序测试通过可注入 clock 回调扩大真实竞争窗口，证明顺序缺口；未声称测得自然复现频率。
- `sign.sh` 的 `--verbose` 也不能靠没有 `|| true` 就判定安全，因为脚本未开 `-e` 且调用后仍继续验证旧签名。
- 本轮 `swift test` 默认 Swift 6.4 使用新的 `swift-build/out/Products/Debug` 布局；老主树某些缓存是 Swift 6.3.3，不能直接 import 给新 swiftc。所有正式控制探针使用本轮独立构建产物。
- 证据在 `.build/bug-audit-20261022/control-tools/`；清理工作树前保留报告、探针源与 JSON / 日志。
