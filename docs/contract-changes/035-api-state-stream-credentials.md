# 035 API 对外的状态里推流凭据打码：streamKey 换标记、url 打码，要原文带 token 加 `?secrets=1`（Codex 10-24 审计 NS03 = W5D 问题单 ②）

提出会话 / 分支：131 W2-C5（`w2-control-5`）
状态：**已批方案 A1**（用户 2026-10-25 在 131 会话里批，原话与落地顺序见文末"裁定"）；**还没落**——要等 132 合入，131 分支不落这一条
来源：reports/issues/W5D-w2-control-api-state-exposes-stream-credentials.md；reports/codex-network-security-audit-20261024.md [3]（NS03，medium）；
docs/KNOWN_ISSUES.md"推流凭据外泄两处"一行的 ②（③ 诊断包那一处归 132 W2-D5）。

## 现状

- `GET /api/v1/state` 与 WS `snapshot` 原样嵌入 `MixerState`：`outputs[].settings.stream.url` 与 `streamKey` 都是原文。W5-D 之后地址里的 `user:pass@` 真的生效（是密码），
  SRT 的 `?passphrase=` / `?streamid=`、MediaMTX 的 `?user=&pass=` 也都在 url 里；密钥栏空时 RTMP 的发布名（= 密钥）在路径末段。
- 本会话查出的第三处：`GET /api/v1/log` 回最近走过总线的命令原文——`setOutputSettings` / `addOutput` / `loadShow` 的参数里带同样的 url / streamKey（App 设置页改推流也走总线，会进这个日志）。
- 谁能读：能连上 API 的任何客户端。NS02 修好之后（本分支）网页读不到了，剩下的是同机进程、局域网（API 开 0.0.0.0 且没 token 时同网段任何人）、拿到 token 的面板 / 脚本。
- 谁要读原文：仓库里没有。App 在进程里直接读状态；Stream Deck 插件只看 `outputs[].kind / number / name / enabled`；兼容层 XML 只有推流开没开；API 上没有任何一方用 `setOutputSettings` / `/api/v1/log` 往返推流设置。

## 改什么（建议 = 方案 A：原地打码，JSON 形态不变）

1. **打码的范围**：API 对外的三处——`GET /api/v1/state` 的 `state`、WS `snapshot` 的 `state`、`GET /api/v1/log` 里带推流设置的命令（`setOutputSettings` / `addOutput` / `loadShow`）。
   tally / 回执 / hello / stats / 兼容层 XML / Tally 服务没有推流设置，不涉及。节目文件、App 界面、状态机里的值都不变（只改 API 怎么写出去）。
2. **每个 `StreamSettings` 怎么打**：
   - `streamKey` 非空 → `"<redacted>"`（`StreamURLRedaction.marker`）；空串照旧空串（客户端靠它知道"没填密钥"）。
   - `url` → `StreamURLRedaction.redact(url:publishNameInPath: streamKey.isEmpty)`：userinfo 整段换标记、像密钥的查询参数值换标记（132 修完之后参数名先解百分号再比）、
     密钥栏空时 RTMP / RTMPS 路径末段（发布名）换标记（132 的 NS09 选项）；scheme / 主机 / 端口 / 其余路径保留。**与诊断包同一份名单、同一份代码**。
   - 别的字段一律不动；键名、类型、层级都与 `MixerState` 的 Codable 一致（docs/api.md 的样例不用改形状）。
3. **往返**：API（HTTP / WS）收到的 `setOutputSettings`，`stream.streamKey == "<redacted>"` = 保留这一路现在的密钥；`stream.url` 等于"现在的 url 打码之后的样子" = 保留现在的 url。
   在 API 层换回原值再进总线（总线日志、reducer、界面永远看不到标记）。`addOutput` / `loadShow` 里出现标记（没有"现在的值"可保留）→ 400
   "推流设置里有打码标记：原文用 ?secrets=1 读"，免得把标记当密钥存下去。契约文字（CONTRACTS.md 的 API 一节）加一句说明这条往返规则；reducer 不改。
4. **要原文**：`GET /api/v1/state?secrets=1`、`WS /api/v1/events?secrets=1`、`GET /api/v1/log?secrets=1` 给原文，**只在配了 token 时**（请求已经过 token 中间件）；
   没配 token（包括只开本机）→ `403 {"error": "secrets-require-token"}`，WS 不升级。不带 `secrets` 的照旧打码。
5. **名单放哪**（SwitcherControl 按依赖方向不能 import SwitcherOutputs，设计方案 §11 / scripts/check-deps.sh）：
   - **A1（建议）**：`StreamURLRedaction`（只用 Foundation 的纯字符串函数）搬进 SwitcherContracts；SwitcherStreaming 留 `public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction`，
     现有调用点（推流日志、App 的 ShowRedaction / 底栏提示）一行不改。**要等 132 W2-D5 合入之后再搬**（132 正在改这个文件：NS12 解百分号、NS09 路径末段选项），由契约会话（P5 系）搬、本路 rebase 后接上。
   - A2（不动契约）：`APIServer` 多一个注入参数 `redactStreamURL: @Sendable (String, _ publishNameInPath: Bool) -> String`，App（ControlRuntime）与 headless 传 `StreamURLRedaction.redact`；
     没注入时退到更保守的本地规则（只留 `scheme://host:port`）。缺点：两条代码路径、headless 要另一个会话接线。

## 为什么

- NS03 / W5D ②：能读 API 状态的客户端都能拿到推流密钥和地址里的密码（W5-D 之后是真密码）；设 token 只能挡没 token 的读者，挡不住拿到 token 的面板 / 脚本——而它们都用不着原文。
- 选"原地打码"而不是换 DTO：JSON 形态不变，现有客户端（Stream Deck、Companion 走兼容层不读这些）零改动，docs/api.md 只加说明不改样例；
  往返规则让"读 → 改别的字段 → 整个写回"的客户端不会把标记写进去。
- 选"与诊断包同一份名单"：两份名单早晚分叉（132 正在改的 NS12 / NS09 就是例子），API 漏掉的就是诊断包修过的。

## 备选（请用户挑）

- **B：换 DTO**——对外状态里 `streamKey` 换成 `hasStreamKey: Bool`、url 打码。形态变了：docs/api.md 样例改、按 `MixerState` 解 API 状态的客户端要改；
  `setOutputSettings` 要有"不带 streamKey = 保留"的语义，等于改 `Command` 的解码（契约更大）。不建议。
- **C：不改，只写文档**——"API 只开本机 + 设 token"。NS02 修好之后网页读不到了，但同机进程 / 局域网 / 拿到 token 的客户端照样读得到原文。不建议。

## 影响谁

- SwitcherControl（本路 W2-C 系）：APIModels（对外状态 / 日志条目的打码编码）、StateFeed（`?secrets=1` 的订阅者另编一份原文，没人要就不编）、APIServer（`secrets` 参数、往返换回原值、`addOutput` / `loadShow` 带标记 400）+ 用例。
- SwitcherContracts（A1）：多一个公开类型 `StreamURLRedaction`（从 SwitcherStreaming 搬来）+ CONTRACTS.md 一句往返规则——契约会话做。
- SwitcherOutputs / Streaming（A1）：原文件换成 typealias；与 132 排先后（132 先合）。
- App：ShowRedaction / 底栏提示经 typealias 不用改；A2 才要 ControlRuntime 接线（≤ 20 行）。
- docs/api.md：重生成（state / events / log 三节各加一句"推流凭据打码、`?secrets=1` 要 token"）；手册与 docs/api/README.md 交 W4-C 系。
- Stream Deck / Companion / 兼容层 / Tally：不用改。

## 怎么迁移

- 节目文件：不涉及（存盘的状态不变，只改 API 写出去的样子），schemaVersion 不升。
- 外部脚本：读 API 状态拿推流密钥 / 地址密码的（仓库里没有）改用 `?secrets=1` + token；往返写回的不用改（标记 = 保留原值）。

## 批了之后的用例（先红后绿）

- GET state / WS snapshot / GET log 里找不到测试密钥、userinfo 里的密码、`pass=` 的值、密钥栏空时路径里的发布名；键名与 `MixerState` 的 `jsonKeys` 一致。
- 配了 token：`?secrets=1` 三处都给原文；没配 token：`?secrets=1` → 403 `secrets-require-token`，WS 不升级。
- `setOutputSettings` 带标记往返：密钥 / 地址保留原值，别的字段照改；`addOutput` 带标记 → 400，状态不变。

## 裁定（用户 2026-10-25，131 会话）

原话："035 批方案 A1：等 132 合入后，由契约会话把 StreamURLRedaction 搬进 SwitcherContracts（SwitcherStreaming 留 typealias），再由 W2-C 系把 API 状态 / WS 快照 / 命令日志按提案打码，?secrets=1 要配 token。"

落地顺序（三步，前一步合进 main 才开下一步）：

1. **132 W2-D5 合入**（G12）：`StreamURLRedaction` 先在原地带上 NS12（参数名解百分号）与 NS09（`publishNameInPath`）的新口径。
2. **契约会话（P5 系）**：`StreamURLRedaction` 原样搬进 SwitcherContracts（只用 Foundation），SwitcherStreaming 留 `public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction`，
   推流日志、App 的 ShowRedaction / 底栏提示等调用点不改；CONTRACTS.md 的 API 一节加"对外状态与命令日志里推流凭据打码；`setOutputSettings` 收到打码值 = 保留原值"一句；用例证明搬迁前后打码结果逐字相同。
3. **W2-C 系**：按正文"改什么"第 1–4 条落 API 打码（APIModels / StateFeed / APIServer），用例照"批了之后的用例"；docs/api.md 重生成。KNOWN_ISSUES"推流凭据外泄两处"的 ② 到这一步销号。

正文里没单独问到的细节（没配 token 时 `?secrets=1` 回 `403 secrets-require-token`、WS 不升级；`addOutput` / `loadShow` 带标记回 400；打码只改 API 写出去的样子、节目文件与界面不变）按正文的建议做。
131（`w2-control-5`）只记下这次裁定，不落代码；三步的 prompt 由 G12（134）或之后的排期会话写。
