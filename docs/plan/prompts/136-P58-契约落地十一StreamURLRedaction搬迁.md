## 136 P5-8 契约落地十一：`StreamURLRedaction` 搬进 SwitcherContracts（提案 035 已批 A1 的第 ① 步；G12 2026-10-31 写的；G12 快进 main 后开，与 135 / 138 / 139 并行）
分支：`p5-contracts-8`（从 G12 快进后的 main 开；**128 P5-6 等用户定了之后叠在本分支头上开、或等 G13 合入本路后从 main 开**——两路都动 SwitcherContracts 与 CONTRACTS.md）。只准动：`Packages/SwitcherCore/Sources/SwitcherContracts/`、`Packages/SwitcherCore/Tests/SwitcherContractsTests/`、`docs/CONTRACTS.md`、`docs/contract-changes/035-api-state-stream-credentials.md`（文末加落地记录）、`Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift`（只留 typealias）、`Packages/SwitcherOutputs/Tests/StreamingTests/StreamURLRedactionTests.swift`（只改 import / 放一条"搬前搬后逐字相同"的用例）。
先读：docs/contract-changes/035-api-state-stream-credentials.md（改什么 §5 A1、裁定三步）；reports/w2-control-5.md §4 第 1 条；reports/w2-stream-5.md §1.3 / §1.4（NS12 参数名解百分号、NS09 `publishNameInPath` 的拆法——与 `StreamDestination` 同一份：先 trim 首尾空白再按解码后的路径拆）；`Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift` 现在的全文（132 合入后的版本）。

做（先写用例再搬）：
1. **用例**：`Packages/SwitcherCore/Tests/SwitcherContractsTests/Contracts035Tests.swift`——把 StreamingTests 里 `StreamURLRedactionTests` 的全部输入（NS12 的编码参数名、NS09 的 935 种写法差分里挑代表、userinfo、SRT、不是地址的字符串）按现在的输出写成期望；先红（Contracts 里还没有这个类型）。
2. **搬**：`StreamURLRedaction` 整个文件原样搬进 SwitcherContracts（只用 Foundation；`marker` / `secretQueryParams` / `redact(url:marker:publishNameInPath:)` / 地址框记号那几个公开接口名字、签名、默认值一个不改）；`Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift` 只留 `public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction`；推流日志、App 的 ShowRedaction / 底栏提示 / 诊断包的调用点一行不改、编得过。
3. **CONTRACTS.md** API 一节加一句往返规则（提案正文第 3 条）："对外状态与命令日志里的推流凭据打码（`streamKey` → `<redacted>`，`url` 的 userinfo / 密钥类查询参数 / 密钥栏空时的路径末段换标记）；`setOutputSettings` 收到打码值 = 保留原值；`addOutput` / `loadShow` 带标记 → 400；原文要 `?secrets=1` + token"——**写成"137 落地后生效"**，别让读者以为现在已经打码。
4. 提案 035 文末加"落地记录（第 ① 步）"：搬了什么、哪些调用点没动、用例名。
5. Core 整包 + Outputs 的 StreamingTests（`StreamURLRedactionTests` 照旧全绿）+ App `ReleaseTests`（诊断包那几条经 typealias）；`scripts/check-deps.sh`（Contracts 不许 import 别的包）；`make lint BRANCH=p5-contracts-8`。

不做：API 打码本身（137）；别的契约；命令数不变 42；阈值。
报告 reports/p5-contracts-8.md 五段；不 push、不 merge，交 G13（140）。
